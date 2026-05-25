const std = @import("std");
const c = @import("c.zig").c;
const Device = @import("Device.zig");
const Window = @import("Window.zig");
const Vulkan = @import("Vulkan.zig");
const checkSuccess = @import("utils.zig").checkSuccess;

pub const MAX_FRAMES_IN_FLIGHT = 2;

const Self = @This();
swapChainFramebuffers: []c.VkFramebuffer,
renderPass: c.VkRenderPass,
swapChainImageViews: []c.VkImageView,
swapChainImages: []c.VkImage,
swapChainImageFormat: c.VkFormat,
swapChainDepthFormat: c.VkFormat,
swapChainExtent: c.VkExtent2D,

depthImages: []c.VkImage,
depthImageMemories: []c.VkDeviceMemory,
depthImageViews: []c.VkImageView,

device: *Device,
windowExtent: c.VkExtent2D,

swapChain: c.VkSwapchainKHR,

imageAvailableSemaphores: []c.VkSemaphore,
renderFinishedSemaphores: []c.VkSemaphore,
inFlightFences: []c.VkFence,
imagesInFlight: []c.VkFence,
currentFrame: usize = 0,

pub fn init(alloc: std.mem.Allocator, device: *Device, extent: c.VkExtent2D, prevSwapChain: ?*Self) !Self {
    const createSwapChainResult = try createSwapChain(alloc, device, extent, prevSwapChain);
    const swapChainImageViews = try createImageViews(alloc, device, createSwapChainResult.images, createSwapChainResult.format);
    const renderPass = try createRenderPass(device, createSwapChainResult.format);
    const depthResourcesResult = try createDepthResources(alloc, device, createSwapChainResult);
    const swapChainFramebuffers = try createFramebuffers(
        alloc,
        device,
        createSwapChainResult,
        swapChainImageViews,
        depthResourcesResult.depthImageViews,
        renderPass,
    );
    const createSyncObjectsResult = try createSyncObjects(alloc, device, createSwapChainResult);

    return .{
        .swapChainFramebuffers = swapChainFramebuffers,
        .renderPass = renderPass,
        .swapChainImageViews = swapChainImageViews,
        .swapChainImages = createSwapChainResult.images,
        .swapChainImageFormat = createSwapChainResult.format,
        .swapChainDepthFormat = depthResourcesResult.swapChainDepthFormat,
        .swapChainExtent = createSwapChainResult.extent,

        .depthImages = depthResourcesResult.depthImages,
        .depthImageMemories = depthResourcesResult.depthImageMemories,
        .depthImageViews = depthResourcesResult.depthImageViews,

        .device = device,
        .windowExtent = extent,

        .swapChain = createSwapChainResult.swapChain,

        .imageAvailableSemaphores = createSyncObjectsResult.imageAvailableSemaphores,
        .renderFinishedSemaphores = createSyncObjectsResult.renderFinishedSemaphores,
        .inFlightFences = createSyncObjectsResult.inFlightFences,
        .imagesInFlight = createSyncObjectsResult.imagesInFlight,
    };
}

pub fn deinit(self: *Self) void {
    // Wait for the device to become idle so the GPU isn't using any of
    // the resources we're about to tear down. Without this, the
    // validation layers (rightfully) complain on shutdown.
    _ = c.vkDeviceWaitIdle(self.device.globalDevice);

    // Framebuffers reference the image views, so destroy them first.
    for (self.swapChainFramebuffers) |framebuffer| {
        c.vkDestroyFramebuffer(self.device.globalDevice, framebuffer, null);
    }

    // Destroy the swapchain image views. The underlying VkImages are
    // owned by the swapchain itself and MUST NOT be destroyed manually
    // with vkDestroyImage — vkDestroySwapchainKHR takes care of them.
    for (self.swapChainImageViews) |view| {
        c.vkDestroyImageView(self.device.globalDevice, view, null);
    }

    // Depth resources are user-owned: destroy view, image, and free memory.
    for (self.depthImages, 0..) |image, i| {
        c.vkDestroyImageView(self.device.globalDevice, self.depthImageViews[i], null);
        c.vkDestroyImage(self.device.globalDevice, image, null);
        c.vkFreeMemory(self.device.globalDevice, self.depthImageMemories[i], null);
    }

    // Render pass can be destroyed once nothing references it.
    c.vkDestroyRenderPass(self.device.globalDevice, self.renderPass, null);

    // Sync primitives.
    // renderFinishedSemaphores has one entry per swapchain image (see
    // createSyncObjects), while imageAvailableSemaphores and inFlightFences
    // are sized to MAX_FRAMES_IN_FLIGHT.
    for (self.renderFinishedSemaphores) |sem| {
        c.vkDestroySemaphore(self.device.globalDevice, sem, null);
    }
    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        c.vkDestroySemaphore(self.device.globalDevice, self.imageAvailableSemaphores[i], null);
        c.vkDestroyFence(self.device.globalDevice, self.inFlightFences[i], null);
    }

    // Finally, destroy the swapchain itself, which also destroys the
    // VkImages it owns (i.e. self.swapChainImages).
    if (self.swapChain != null) {
        c.vkDestroySwapchainKHR(self.device.globalDevice, self.swapChain, null);
        self.swapChain = null;
    }
}

pub fn getImageCount(self: *Self) usize {
    return self.swapChainImages.len;
}

pub fn compareSwapFormats(self: *const Self, other: *const Self) bool {
    return self.swapChainImageFormat == other.swapChainImageFormat and
        self.swapChainDepthFormat == other.swapChainDepthFormat;
}

pub fn getFrameBuffer(self: *Self, index: usize) c.VkFramebuffer {
    return self.swapChainFramebuffers[index];
}

pub fn getImageView(self: *Self, index: usize) c.VkImageView {
    return self.swapChainImageViews[index];
}

pub fn width(self: *Self) i32 {
    return @intCast(self.swapChainExtent.width);
}
pub fn height(self: *Self) i32 {
    return @intCast(self.swapChainExtent.height);
}

pub fn extentAspectRatio(self: *Self) f32 {
    const w: f32 = @floatFromInt(self.width());
    const h: f32 = @floatFromInt(self.height());
    return w / h;
}

pub fn findDepthFormat(device: *Device) !c.VkFormat {
    const candidates: []const c.VkFormat = &.{ c.VK_FORMAT_D32_SFLOAT, c.VK_FORMAT_D32_SFLOAT_S8_UINT, c.VK_FORMAT_D24_UNORM_S8_UINT };
    return device.findSupportedFormat(
        candidates,
        c.VK_IMAGE_TILING_OPTIMAL,
        c.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT,
    );
}

pub fn acquireNextImage(self: *Self, imageIndex: *u32) !c.VkResult {
    try checkSuccess(c.vkWaitForFences(
        self.device.globalDevice,
        1,
        &self.inFlightFences[self.currentFrame],
        c.VK_TRUE,
        std.math.maxInt(u64),
    ));

    return c.vkAcquireNextImageKHR(
        self.device.globalDevice,
        self.swapChain,
        std.math.maxInt(u64),
        self.imageAvailableSemaphores[self.currentFrame], // must be a not signaled semaphore
        null,
        imageIndex,
    );
}

pub fn submitCommandBuffers(self: *Self, buffers: *c.VkCommandBuffer, imageIndex: *u32) !c.VkResult {
    if (self.imagesInFlight[imageIndex.*] != null) {
        _ = c.vkWaitForFences(self.device.globalDevice, 1, &self.imagesInFlight[imageIndex.*], c.VK_TRUE, std.math.maxInt(u64));
    }
    self.imagesInFlight[imageIndex.*] = self.inFlightFences[self.currentFrame];

    // The render-finished semaphore is keyed by the *image index*, not the
    // frame index. vkQueuePresentKHR waits on this semaphore but does not
    // un-signal it, so reusing one based on `currentFrame` (range
    // MAX_FRAMES_IN_FLIGHT) breaks when the swapchain has more images than
    // frames in flight (e.g. 3 images on MoltenVK). See
    // https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html
    var signalSemaphores: [1]c.VkSemaphore = .{self.renderFinishedSemaphores[imageIndex.*]};
    var waitSemaphores: [1]c.VkSemaphore = .{self.imageAvailableSemaphores[self.currentFrame]};
    var waitDstStageMask: [1]c.VkPipelineStageFlags = .{c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};

    const submitInfo: c.VkSubmitInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &waitSemaphores,
        .pWaitDstStageMask = &waitDstStageMask,
        .commandBufferCount = 1,
        .pCommandBuffers = buffers,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &signalSemaphores,
    };

    _ = c.vkResetFences(self.device.globalDevice, 1, &self.inFlightFences[self.currentFrame]);
    try checkSuccess(c.vkQueueSubmit(self.device.graphicsQueue, 1, &submitInfo, self.inFlightFences[self.currentFrame]));

    var swapChains: [1]c.VkSwapchainKHR = .{self.swapChain};
    const presentInfo: c.VkPresentInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &signalSemaphores,
        .swapchainCount = 1,
        .pSwapchains = &swapChains,
        .pImageIndices = imageIndex,
    };
    const result = c.vkQueuePresentKHR(self.device.presentQueue, &presentInfo);
    self.currentFrame = (self.currentFrame + 1) % MAX_FRAMES_IN_FLIGHT;
    return result;
}

const CreateSwapChainResult = struct {
    format: c.VkFormat,
    extent: c.VkExtent2D,
    images: []c.VkImage,
    swapChain: c.VkSwapchainKHR,
};

fn createSwapChain(alloc: std.mem.Allocator, device: *Device, windowExtent: c.VkExtent2D, prevSwapChain: ?*Self) !CreateSwapChainResult {
    var swapChain: c.VkSwapchainKHR = undefined;
    var swapChainSupport = try device.getSwapChainSupport();

    const surfaceFormat = chooseSwapSurfaceFormat(&swapChainSupport.formats);
    const presentMode = chooseSwapPresentMode(&swapChainSupport.presentModes);
    const extent = chooseSwapExtent(&swapChainSupport.capabilities, windowExtent);

    var imageCount = swapChainSupport.capabilities.minImageCount + 1;
    if (swapChainSupport.capabilities.maxImageCount > 0 and
        imageCount > swapChainSupport.capabilities.maxImageCount)
    {
        imageCount = swapChainSupport.capabilities.maxImageCount;
    }

    var createInfo = c.VkSwapchainCreateInfoKHR{
        .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = device.surface,
        .minImageCount = imageCount,
        .imageFormat = surfaceFormat.format,
        .imageColorSpace = surfaceFormat.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .preTransform = swapChainSupport.capabilities.currentTransform,
        .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = presentMode,
        .clipped = c.VK_TRUE,
        .oldSwapchain = if (prevSwapChain) |sc| sc.swapChain else null,
    };

    const indices = try Vulkan.findQueueFamilies(alloc, device.physicalDevice, device.surface);
    var queueFamilyIndices: [2]u32 = .{ indices.graphicsFamily.?, indices.presentFamily.? };

    if (indices.graphicsFamily != indices.presentFamily) {
        createInfo.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
        createInfo.queueFamilyIndexCount = 2;
        createInfo.pQueueFamilyIndices = &queueFamilyIndices;
    } else {
        createInfo.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        createInfo.queueFamilyIndexCount = 0; // Optional
        createInfo.pQueueFamilyIndices = null; // Optional
    }

    try checkSuccess(c.vkCreateSwapchainKHR(device.globalDevice, &createInfo, null, &swapChain));

    // we only specified a minimum number of images in the swap chain, so the implementation is
    // allowed to create a swap chain with more. That's why we'll first query the final number of
    // images with vkGetSwapchainImagesKHR, then resize the container and finally call it again to
    // retrieve the handles.
    try checkSuccess(c.vkGetSwapchainImagesKHR(device.globalDevice, swapChain, &imageCount, null));

    const swapChainImages = try alloc.alloc(c.VkImage, imageCount);
    try checkSuccess(c.vkGetSwapchainImagesKHR(device.globalDevice, swapChain, &imageCount, swapChainImages.ptr));

    return CreateSwapChainResult{
        .format = surfaceFormat.format,
        .extent = extent,
        .images = swapChainImages,
        .swapChain = swapChain,
    };
}
fn createImageViews(
    alloc: std.mem.Allocator,
    device: *Device,
    swapChainImages: []c.VkImage,
    swapChainImageFormat: c.VkFormat,
) ![]c.VkImageView {
    var swapChainImageViews = try alloc.alloc(c.VkImageView, swapChainImages.len);
    for (swapChainImages, 0..) |image, i| {
        const viewInfo = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = swapChainImageFormat,
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        try checkSuccess(c.vkCreateImageView(device.globalDevice, &viewInfo, null, &swapChainImageViews[i]));
    }
    return swapChainImageViews;
}

const CreateDepthResourcesResult = struct {
    swapChainDepthFormat: c.VkFormat,
    depthImages: []c.VkImage,
    depthImageMemories: []c.VkDeviceMemory,
    depthImageViews: []c.VkImageView,
};

fn createDepthResources(alloc: std.mem.Allocator, device: *Device, createSwapChainResult: CreateSwapChainResult) !CreateDepthResourcesResult {
    const depthFormat = try findDepthFormat(device);
    const swapChainExtent = createSwapChainResult.extent;

    const depthImages = try alloc.alloc(c.VkImage, createSwapChainResult.images.len);
    const depthImageMemories = try alloc.alloc(c.VkDeviceMemory, createSwapChainResult.images.len);
    var depthImageViews = try alloc.alloc(c.VkImageView, createSwapChainResult.images.len);

    for (0..createSwapChainResult.images.len) |i| {
        var imageInfo = c.VkImageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .extent = .{
                .width = swapChainExtent.width,
                .height = swapChainExtent.height,
                .depth = 1,
            },
            .mipLevels = 1,
            .arrayLayers = 1,
            .format = depthFormat,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .flags = 0,
        };

        try device.createImageWithInfo(&imageInfo, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &depthImages[i], &depthImageMemories[i]);

        const viewInfo = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = depthImages[i],
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = depthFormat,
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        try checkSuccess(c.vkCreateImageView(device.globalDevice, &viewInfo, null, &depthImageViews[i]));
    }
    return .{
        .swapChainDepthFormat = depthFormat,
        .depthImages = depthImages,
        .depthImageMemories = depthImageMemories,
        .depthImageViews = depthImageViews,
    };
}

fn createRenderPass(device: *Device, swapChainImageFormat: c.VkFormat) !c.VkRenderPass {
    const depthAttachment = c.VkAttachmentDescription{
        .format = try findDepthFormat(device),
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };

    const depthAttachmentRef = c.VkAttachmentReference{
        .attachment = 1,
        .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };

    const colorAttachment = c.VkAttachmentDescription{
        .format = swapChainImageFormat,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };

    const colorAttachmentRef = c.VkAttachmentReference{
        .attachment = 0,
        .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    const subpass = c.VkSubpassDescription{
        .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &colorAttachmentRef,
        .pDepthStencilAttachment = &depthAttachmentRef,
    };

    const dependency = c.VkSubpassDependency{
        .dstSubpass = 0,
        .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        .srcSubpass = c.VK_SUBPASS_EXTERNAL,
        .srcAccessMask = 0,
        .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
    };

    const attachments = [_]c.VkAttachmentDescription{ colorAttachment, depthAttachment };
    const renderPassInfo = c.VkRenderPassCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = attachments.len,
        .pAttachments = &attachments,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };

    var renderPass: c.VkRenderPass = undefined;

    try checkSuccess(c.vkCreateRenderPass(device.globalDevice, &renderPassInfo, null, &renderPass));
    return renderPass;
}

const CreateSyncObjectsResult = struct {
    imageAvailableSemaphores: []c.VkSemaphore,
    renderFinishedSemaphores: []c.VkSemaphore,
    inFlightFences: []c.VkFence,
    imagesInFlight: []c.VkFence,
};

fn createSyncObjects(
    alloc: std.mem.Allocator,
    device: *Device,
    createSwapChainResult: CreateSwapChainResult,
) !CreateSyncObjectsResult {
    var imageAvailableSemaphores = try alloc.alloc(c.VkSemaphore, MAX_FRAMES_IN_FLIGHT);
    // One render-finished semaphore per swapchain image (not per frame in
    // flight). vkQueuePresentKHR waits on this semaphore but does not
    // un-signal it, so it must be uniquely associated with the swapchain
    // image whose presentation it gates. Indexing by `currentFrame` (range
    // MAX_FRAMES_IN_FLIGHT) breaks when the swapchain has more images than
    // frames in flight.
    var renderFinishedSemaphores = try alloc.alloc(c.VkSemaphore, createSwapChainResult.images.len);
    var inFlightFences = try alloc.alloc(c.VkFence, MAX_FRAMES_IN_FLIGHT);
    const imagesInFlight = try alloc.alloc(c.VkFence, createSwapChainResult.images.len);
    // The swapchain may contain more images than MAX_FRAMES_IN_FLIGHT (e.g. 3
    // on MoltenVK). Every slot must start as VK_NULL_HANDLE, otherwise
    // submitCommandBuffers will read uninitialized memory and pass a bogus
    // fence handle to vkWaitForFences, which crashes the driver.
    @memset(imagesInFlight, null);

    const semaphoreInfo = c.VkSemaphoreCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    };

    const fenceInfo = c.VkFenceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        try checkSuccess(c.vkCreateSemaphore(device.globalDevice, &semaphoreInfo, null, &imageAvailableSemaphores[i]));
        try checkSuccess(c.vkCreateFence(device.globalDevice, &fenceInfo, null, &inFlightFences[i]));
    }
    for (0..renderFinishedSemaphores.len) |i| {
        try checkSuccess(c.vkCreateSemaphore(device.globalDevice, &semaphoreInfo, null, &renderFinishedSemaphores[i]));
    }
    return .{
        .imageAvailableSemaphores = imageAvailableSemaphores,
        .renderFinishedSemaphores = renderFinishedSemaphores,
        .inFlightFences = inFlightFences,
        .imagesInFlight = imagesInFlight,
    };
}

// Helper functions
fn chooseSwapSurfaceFormat(availableFormats: *[]c.VkSurfaceFormatKHR) c.VkSurfaceFormatKHR {
    for (availableFormats.*) |availableFormat| {
        if (availableFormat.format == c.VK_FORMAT_B8G8R8A8_SRGB and
            availableFormat.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
        {
            return availableFormat;
        }
    }

    return availableFormats.*[0];
}

fn chooseSwapPresentMode(availablePresentModes: *[]c.VkPresentModeKHR) c.VkPresentModeKHR {
    // see: https://youtu.be/IUYH74MqxOA?si=raiLb25OF3AeqPXC&t=518
    for (availablePresentModes.*) |availablePresentMode| {
        if (availablePresentMode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
            std.log.scoped(.swapchain).info("Present mode: Mailbox", .{});
            return availablePresentMode;
        }
    }

    // see above, video describes why this should not be used
    //    for (availablePresentModes.*) |availablePresentMode| {
    //        if (availablePresentMode == c.VK_PRESENT_MODE_IMMEDIATE_KHR) {
    //            std.log.scoped(.swapchain).info("Present mode: Immediate", .{});
    //            return availablePresentMode;
    //        }
    //    }

    std.log.scoped(.swapchain).info("Present mode: V-Sync", .{});
    return c.VK_PRESENT_MODE_FIFO_KHR;
}
fn chooseSwapExtent(capabilities: *c.VkSurfaceCapabilitiesKHR, windowExtent: c.VkExtent2D) c.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    } else {
        const actualExtent: c.VkExtent2D = .{
            .width = @max(
                capabilities.minImageExtent.width,
                @min(capabilities.maxImageExtent.width, windowExtent.width),
            ),
            .height = @max(
                capabilities.minImageExtent.height,
                @min(capabilities.maxImageExtent.height, windowExtent.height),
            ),
        };
        return actualExtent;
    }
}

fn createFramebuffers(
    alloc: std.mem.Allocator,
    device: *Device,
    createSwapChainResult: CreateSwapChainResult,
    swapChainImageViews: []c.VkImageView,
    depthImageViews: []c.VkImageView,
    renderPass: c.VkRenderPass,
) ![]c.VkFramebuffer {
    var swapChainFramebuffers = try alloc.alloc(c.VkFramebuffer, createSwapChainResult.images.len);
    for (0..createSwapChainResult.images.len) |i| {
        const attachments = [2]c.VkImageView{ swapChainImageViews[i], depthImageViews[i] };

        const framebufferInfo = c.VkFramebufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = renderPass,
            .attachmentCount = attachments.len,
            .pAttachments = &attachments,
            .width = createSwapChainResult.extent.width,
            .height = createSwapChainResult.extent.height,
            .layers = 1,
        };

        try checkSuccess(c.vkCreateFramebuffer(device.globalDevice, &framebufferInfo, null, &swapChainFramebuffers[i]));
    }
    return swapChainFramebuffers;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "MAX_FRAMES_IN_FLIGHT is 2" {
    try std.testing.expectEqual(@as(usize, 2), MAX_FRAMES_IN_FLIGHT);
}

test "Swapchain has expected fields and types" {
    try std.testing.expectEqual([]c.VkFramebuffer, @FieldType(Self, "swapChainFramebuffers"));
    try std.testing.expectEqual(c.VkRenderPass, @FieldType(Self, "renderPass"));
    try std.testing.expectEqual([]c.VkImageView, @FieldType(Self, "swapChainImageViews"));
    try std.testing.expectEqual([]c.VkImage, @FieldType(Self, "swapChainImages"));
    try std.testing.expectEqual(c.VkFormat, @FieldType(Self, "swapChainImageFormat"));
    try std.testing.expectEqual(c.VkFormat, @FieldType(Self, "swapChainDepthFormat"));
    try std.testing.expectEqual(c.VkExtent2D, @FieldType(Self, "swapChainExtent"));
    try std.testing.expectEqual([]c.VkImage, @FieldType(Self, "depthImages"));
    try std.testing.expectEqual([]c.VkDeviceMemory, @FieldType(Self, "depthImageMemories"));
    try std.testing.expectEqual([]c.VkImageView, @FieldType(Self, "depthImageViews"));
    try std.testing.expectEqual(*Device, @FieldType(Self, "device"));
    try std.testing.expectEqual(c.VkExtent2D, @FieldType(Self, "windowExtent"));
    try std.testing.expectEqual(c.VkSwapchainKHR, @FieldType(Self, "swapChain"));
    try std.testing.expectEqual([]c.VkSemaphore, @FieldType(Self, "imageAvailableSemaphores"));
    try std.testing.expectEqual([]c.VkSemaphore, @FieldType(Self, "renderFinishedSemaphores"));
    try std.testing.expectEqual([]c.VkFence, @FieldType(Self, "inFlightFences"));
    try std.testing.expectEqual([]c.VkFence, @FieldType(Self, "imagesInFlight"));
    try std.testing.expectEqual(usize, @FieldType(Self, "currentFrame"));
}

// Build a minimal Self with only the swapChainExtent fields populated. All
// other fields are left undefined / null because the helpers under test don't
// touch them.
fn makeSelfWithExtent(extent: c.VkExtent2D) Self {
    return Self{
        .swapChainFramebuffers = &.{},
        .renderPass = null,
        .swapChainImageViews = &.{},
        .swapChainImages = &.{},
        .swapChainImageFormat = 0,
        .swapChainDepthFormat = 0,
        .swapChainExtent = extent,
        .depthImages = &.{},
        .depthImageMemories = &.{},
        .depthImageViews = &.{},
        .device = undefined,
        .windowExtent = .{ .width = 0, .height = 0 },
        .swapChain = null,
        .imageAvailableSemaphores = &.{},
        .renderFinishedSemaphores = &.{},
        .inFlightFences = &.{},
        .imagesInFlight = &.{},
    };
}

test "width/height return swapChainExtent dimensions" {
    var self = makeSelfWithExtent(.{ .width = 1280, .height = 720 });
    try std.testing.expectEqual(@as(i32, 1280), self.width());
    try std.testing.expectEqual(@as(i32, 720), self.height());
}

test "extentAspectRatio computes width/height" {
    var self = makeSelfWithExtent(.{ .width = 1600, .height = 800 });
    try std.testing.expectEqual(@as(f32, 2.0), self.extentAspectRatio());
}

test "extentAspectRatio for square extent is 1.0" {
    var self = makeSelfWithExtent(.{ .width = 512, .height = 512 });
    try std.testing.expectEqual(@as(f32, 1.0), self.extentAspectRatio());
}

test "getFrameBuffer returns the framebuffer at the requested index" {
    const fb0: c.VkFramebuffer = @ptrFromInt(0xdead_beef);
    const fb1: c.VkFramebuffer = @ptrFromInt(0xfeed_face);
    var framebuffers = [_]c.VkFramebuffer{ fb0, fb1 };
    var self = makeSelfWithExtent(.{ .width = 1, .height = 1 });
    self.swapChainFramebuffers = framebuffers[0..];

    try std.testing.expectEqual(fb0, self.getFrameBuffer(0));
    try std.testing.expectEqual(fb1, self.getFrameBuffer(1));
}

test "getImageView returns the image view at the requested index" {
    const iv0: c.VkImageView = @ptrFromInt(0x1111);
    const iv1: c.VkImageView = @ptrFromInt(0x2222);
    const iv2: c.VkImageView = @ptrFromInt(0x3333);
    var views = [_]c.VkImageView{ iv0, iv1, iv2 };
    var self = makeSelfWithExtent(.{ .width = 1, .height = 1 });
    self.swapChainImageViews = views[0..];

    try std.testing.expectEqual(iv0, self.getImageView(0));
    try std.testing.expectEqual(iv1, self.getImageView(1));
    try std.testing.expectEqual(iv2, self.getImageView(2));
}

test "compareSwapFormats returns true when image and depth formats match" {
    var a = makeSelfWithExtent(.{ .width = 1, .height = 1 });
    var b = makeSelfWithExtent(.{ .width = 1, .height = 1 });
    a.swapChainImageFormat = c.VK_FORMAT_B8G8R8A8_SRGB;
    a.swapChainDepthFormat = c.VK_FORMAT_D32_SFLOAT;
    b.swapChainImageFormat = c.VK_FORMAT_B8G8R8A8_SRGB;
    b.swapChainDepthFormat = c.VK_FORMAT_D32_SFLOAT;

    try std.testing.expect(a.compareSwapFormats(&b));
    try std.testing.expect(b.compareSwapFormats(&a));
}

test "compareSwapFormats returns false when image format differs" {
    var a = makeSelfWithExtent(.{ .width = 1, .height = 1 });
    var b = makeSelfWithExtent(.{ .width = 1, .height = 1 });
    a.swapChainImageFormat = c.VK_FORMAT_B8G8R8A8_SRGB;
    a.swapChainDepthFormat = c.VK_FORMAT_D32_SFLOAT;
    b.swapChainImageFormat = c.VK_FORMAT_R8G8B8A8_UNORM;
    b.swapChainDepthFormat = c.VK_FORMAT_D32_SFLOAT;

    try std.testing.expect(!a.compareSwapFormats(&b));
}

test "compareSwapFormats returns false when depth format differs" {
    var a = makeSelfWithExtent(.{ .width = 1, .height = 1 });
    var b = makeSelfWithExtent(.{ .width = 1, .height = 1 });
    a.swapChainImageFormat = c.VK_FORMAT_B8G8R8A8_SRGB;
    a.swapChainDepthFormat = c.VK_FORMAT_D32_SFLOAT;
    b.swapChainImageFormat = c.VK_FORMAT_B8G8R8A8_SRGB;
    b.swapChainDepthFormat = c.VK_FORMAT_D24_UNORM_S8_UINT;

    try std.testing.expect(!a.compareSwapFormats(&b));
}

test "chooseSwapSurfaceFormat picks B8G8R8A8_SRGB / SRGB_NONLINEAR when available" {
    var formats = [_]c.VkSurfaceFormatKHR{
        .{ .format = c.VK_FORMAT_R8G8B8A8_UNORM, .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
        .{ .format = c.VK_FORMAT_B8G8R8A8_SRGB, .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
        .{ .format = c.VK_FORMAT_B8G8R8A8_UNORM, .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
    };
    var slice: []c.VkSurfaceFormatKHR = formats[0..];
    const chosen = chooseSwapSurfaceFormat(&slice);
    try std.testing.expectEqual(@as(c_uint, c.VK_FORMAT_B8G8R8A8_SRGB), chosen.format);
    try std.testing.expectEqual(
        @as(c_uint, c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
        chosen.colorSpace,
    );
}

test "chooseSwapSurfaceFormat falls back to first when preferred not available" {
    var formats = [_]c.VkSurfaceFormatKHR{
        .{ .format = c.VK_FORMAT_R8G8B8A8_UNORM, .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
        .{ .format = c.VK_FORMAT_B8G8R8A8_UNORM, .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
    };
    var slice: []c.VkSurfaceFormatKHR = formats[0..];
    const chosen = chooseSwapSurfaceFormat(&slice);
    try std.testing.expectEqual(@as(c_uint, c.VK_FORMAT_R8G8B8A8_UNORM), chosen.format);
}

test "chooseSwapSurfaceFormat does not match SRGB format with wrong color space" {
    var formats = [_]c.VkSurfaceFormatKHR{
        .{ .format = c.VK_FORMAT_R8G8B8A8_UNORM, .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
        .{ .format = c.VK_FORMAT_B8G8R8A8_SRGB, .colorSpace = c.VK_COLOR_SPACE_DISPLAY_P3_NONLINEAR_EXT },
    };
    var slice: []c.VkSurfaceFormatKHR = formats[0..];
    const chosen = chooseSwapSurfaceFormat(&slice);
    // No element matches both format AND color space, so we should get the
    // first entry as fallback.
    try std.testing.expectEqual(@as(c_uint, c.VK_FORMAT_R8G8B8A8_UNORM), chosen.format);
    try std.testing.expectEqual(
        @as(c_uint, c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
        chosen.colorSpace,
    );
}

test "chooseSwapPresentMode prefers MAILBOX when available" {
    var modes = [_]c.VkPresentModeKHR{
        c.VK_PRESENT_MODE_IMMEDIATE_KHR,
        c.VK_PRESENT_MODE_FIFO_KHR,
        c.VK_PRESENT_MODE_MAILBOX_KHR,
    };
    var slice: []c.VkPresentModeKHR = modes[0..];
    const chosen = chooseSwapPresentMode(&slice);
    try std.testing.expectEqual(@as(c_uint, c.VK_PRESENT_MODE_MAILBOX_KHR), chosen);
}

test "chooseSwapPresentMode falls back to FIFO when MAILBOX is missing" {
    var modes = [_]c.VkPresentModeKHR{
        c.VK_PRESENT_MODE_IMMEDIATE_KHR,
        c.VK_PRESENT_MODE_FIFO_KHR,
    };
    var slice: []c.VkPresentModeKHR = modes[0..];
    const chosen = chooseSwapPresentMode(&slice);
    try std.testing.expectEqual(@as(c_uint, c.VK_PRESENT_MODE_FIFO_KHR), chosen);
}

test "chooseSwapPresentMode falls back to FIFO for an empty list" {
    var modes = [_]c.VkPresentModeKHR{};
    var slice: []c.VkPresentModeKHR = modes[0..];
    const chosen = chooseSwapPresentMode(&slice);
    try std.testing.expectEqual(@as(c_uint, c.VK_PRESENT_MODE_FIFO_KHR), chosen);
}

test "chooseSwapExtent returns currentExtent when not maxInt" {
    var caps = std.mem.zeroes(c.VkSurfaceCapabilitiesKHR);
    caps.currentExtent = .{ .width = 1024, .height = 768 };
    caps.minImageExtent = .{ .width = 1, .height = 1 };
    caps.maxImageExtent = .{ .width = 4096, .height = 4096 };

    const window = c.VkExtent2D{ .width = 800, .height = 600 };
    const extent = chooseSwapExtent(&caps, window);
    try std.testing.expectEqual(@as(u32, 1024), extent.width);
    try std.testing.expectEqual(@as(u32, 768), extent.height);
}

test "chooseSwapExtent clamps windowExtent when currentExtent is maxInt" {
    var caps = std.mem.zeroes(c.VkSurfaceCapabilitiesKHR);
    caps.currentExtent = .{
        .width = std.math.maxInt(u32),
        .height = std.math.maxInt(u32),
    };
    caps.minImageExtent = .{ .width = 100, .height = 100 };
    caps.maxImageExtent = .{ .width = 1920, .height = 1080 };

    // Within range -> unchanged
    {
        const extent = chooseSwapExtent(&caps, .{ .width = 800, .height = 600 });
        try std.testing.expectEqual(@as(u32, 800), extent.width);
        try std.testing.expectEqual(@as(u32, 600), extent.height);
    }

    // Below min -> clamped up
    {
        const extent = chooseSwapExtent(&caps, .{ .width = 50, .height = 50 });
        try std.testing.expectEqual(@as(u32, 100), extent.width);
        try std.testing.expectEqual(@as(u32, 100), extent.height);
    }

    // Above max -> clamped down
    {
        const extent = chooseSwapExtent(&caps, .{ .width = 4000, .height = 4000 });
        try std.testing.expectEqual(@as(u32, 1920), extent.width);
        try std.testing.expectEqual(@as(u32, 1080), extent.height);
    }
}

test "CreateSwapChainResult has the expected shape" {
    try std.testing.expectEqual(c.VkFormat, @FieldType(CreateSwapChainResult, "format"));
    try std.testing.expectEqual(c.VkExtent2D, @FieldType(CreateSwapChainResult, "extent"));
    try std.testing.expectEqual([]c.VkImage, @FieldType(CreateSwapChainResult, "images"));
    try std.testing.expectEqual(c.VkSwapchainKHR, @FieldType(CreateSwapChainResult, "swapChain"));
}

test "CreateDepthResourcesResult has the expected shape" {
    try std.testing.expectEqual(c.VkFormat, @FieldType(CreateDepthResourcesResult, "swapChainDepthFormat"));
    try std.testing.expectEqual([]c.VkImage, @FieldType(CreateDepthResourcesResult, "depthImages"));
    try std.testing.expectEqual([]c.VkDeviceMemory, @FieldType(CreateDepthResourcesResult, "depthImageMemories"));
    try std.testing.expectEqual([]c.VkImageView, @FieldType(CreateDepthResourcesResult, "depthImageViews"));
}

test "CreateSyncObjectsResult has the expected shape" {
    try std.testing.expectEqual([]c.VkSemaphore, @FieldType(CreateSyncObjectsResult, "imageAvailableSemaphores"));
    try std.testing.expectEqual([]c.VkSemaphore, @FieldType(CreateSyncObjectsResult, "renderFinishedSemaphores"));
    try std.testing.expectEqual([]c.VkFence, @FieldType(CreateSyncObjectsResult, "inFlightFences"));
    try std.testing.expectEqual([]c.VkFence, @FieldType(CreateSyncObjectsResult, "imagesInFlight"));
}
