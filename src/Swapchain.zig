const std = @import("std");
const c = @import("c.zig").c;
const Device = @import("Device.zig");
const Window = @import("Window.zig");
const Vulkan = @import("Vulkan.zig");
const checkSuccess = @import("utils.zig").checkSuccess;

const MAX_FRAMES_IN_FLIGHT = 2;

const Self = @This();
swapChainFramebuffers: []c.VkFramebuffer,
renderPass: c.VkRenderPass,
swapChainImageViews: []c.VkImageView,
swapChainImages: []c.VkImage,
swapChainImageFormat: c.VkFormat,
swapChainExtent: c.VkExtent2D,

depthImages: []c.VkImage,
depthImageMemorys: []c.VkDeviceMemory,
depthImageViews: []c.VkImageView,

device: *Device,
windowExtent: c.VkExtent2D,

swapChain: c.VkSwapchainKHR,

imageAvailableSemaphores: []c.VkSemaphore,
renderFinishedSemaphores: []c.VkSemaphore,
inFlightFences: []c.VkFence,
imagesInFlight: []c.VkFence,
currentFrame: usize = 0,

pub fn init(alloc: std.mem.Allocator, device: *Device, window: *Window) !Self {
    const createSwapChainResult = try createSwapChain(alloc, device, window);
    const swapChainImageViews = try createImageViews(alloc, device, createSwapChainResult.images);
    const renderPass = try createRenderPass(device, createSwapChainResult);
    const depthResourcesResult = try createDepthResources(alloc, device, createSwapChainResult);
    const swapChainFramebuffers = try createFramebuffers(
        alloc,
        device,
        createSwapChainResult,
        swapChainImageViews,
        depthResourcesResult.depthImageViews,
    );
    const createSyncObjectsResult = try createSyncObjects(alloc, device, createSwapChainResult);

    return .{
        .swapChainFramebuffers = swapChainFramebuffers,
        .renderPass = renderPass,
        .swapChainImageViews = swapChainImageViews,
        .swapChainImages = createSwapChainResult.images,
        .swapChainImageFormat = createSwapChainResult.format,
        .swapChainExtent = createSwapChainResult.extend,

        .depthImages = depthResourcesResult.depthImages,
        .depthImageMemorys = depthResourcesResult.depthImageMemorys,
        .depthImageViews = depthResourcesResult.depthImageViews,

        .device = device,
        .windowExtent = window.getExtent(),

        .swapChain = createSwapChainResult.swapChain,

        .imageAvailableSemaphores = createSyncObjectsResult.imageAvailableSemaphores,
        .renderFinishedSemaphores = createSyncObjectsResult.renderFinishedSemaphores,
        .inFlightFences = createSyncObjectsResult.inFlightFences,
        .imagesInFlight = createSyncObjectsResult.imagesInFlight,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
    unreachable;
}

pub fn getFrameBuffer(self: *Self, index: usize) c.VkFramebuffer {
    return self.swapChainFramebuffers[index];
}

pub fn getImageView(self: *Self, index: usize) c.VkImageView {
    return self.swapChainImageViews[index];
}

pub fn width(self: *Self) usize {
    return self.swapChainExtent.width;
}
pub fn height(self: *Self) usize {
    return self.swapChainExtent.height;
}

pub fn extentAspectRatio(self: *Self) f32 {
    const w: f32 = @floatFromInt(self.width());
    const h: f32 = @floatFromInt(self.height());
    return w / h;
}

pub fn findDepthFormat(device: *Device) c.VkFormat {
    return device.findSupportedFormat(
        .{ c.VK_FORMAT_D32_SFLOAT, c.VK_FORMAT_D32_SFLOAT_S8_UINT, c.VK_FORMAT_D24_UNORM_S8_UINT },
        c.VK_IMAGE_TILING_OPTIMAL,
        c.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT,
    );
}

pub fn acquireNextImage(self: *Self, index: *usize) !c.VkResult {
    _ = self;
    _ = index;
    return 0;
}

pub fn submitCommandBuffers(self: *Self, buffers: *c.VkCommandBuffer, index: *usize) !c.VkResult {
    _ = self;
    _ = index;
    _ = buffers;
    return 0;
}

const CreateSwapChainResult = struct {
    format: c.VkFormat,
    extend: c.VkExtent2D,
    images: []c.VkImage,
    swapChain: c.VkSwapchainKHR,
};

fn createSwapChain(alloc: std.mem.Allocator, device: *Device, window: *Window) !CreateSwapChainResult {
    var swapChain: c.VkSwapchainKHR = undefined;
    var swapChainSupport = try device.getSwapChainSupport();

    const surfaceFormat = chooseSwapSurfaceFormat(&swapChainSupport.formats);
    const presentMode = chooseSwapPresentMode(&swapChainSupport.presentModes);
    const extent = chooseSwapExtent(&swapChainSupport.capabilities, window.getExtend());

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
        .oldSwapchain = null,
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

    var swapChainImages = try alloc.alloc(c.VkImage, imageCount);
    try checkSuccess(c.vkGetSwapchainImagesKHR(device.globalDevice, swapChain, &imageCount, &swapChainImages));

    return CreateSwapChainResult{
        .format = surfaceFormat.format,
        .extend = extent,
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
    depthImageMemorys: []c.VkDeviceMemory,
    depthImageViews: []c.VkImageView,
};

fn createDepthResources(alloc: std.mem.Allocator, device: *Device, createSwapChainResult: CreateSwapChainResult) !CreateDepthResourcesResult {
    const depthFormat = findDepthFormat(device);
    const swapChainExtent = createSwapChainResult.extend;

    var depthImages = try alloc.alloc(c.VkImage, createSwapChainResult.images.len);
    var depthImageMemorys = try alloc.alloc(c.VkDeviceMemory, createSwapChainResult.images.len);
    var depthImageViews = try alloc.alloc(c.VkImageView, createSwapChainResult.images.len);

    for (0..createSwapChainResult.images.len) |i| {
        const imageInfo = c.VkImageCreateInfo{
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

        device.createImageWithInfo(imageInfo, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &depthImages[i], &depthImageMemorys[i]);

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
        .depthImageMemorys = depthImageMemorys,
        .depthImageViews = depthImageViews,
    };
}

fn createRenderPass(device: *Device, swapChainImageFormat: c.VkFormat) !c.VkRenderPass {
    const depthAttachment = c.VkAttachmentDescription{
        .format = findDepthFormat(device),
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

    const attachments = [2]c.VkAttachmentDescription{ colorAttachment, depthAttachment };
    const renderPassInfo = c.VkRenderPassCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = attachments.len,
        .pAttachments = attachments,
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
    var renderFinishedSemaphores = try alloc.alloc(c.VkSemaphore, MAX_FRAMES_IN_FLIGHT);
    var inFlightFences = try alloc.alloc(c.VkFence, MAX_FRAMES_IN_FLIGHT);
    var imagesInFlight = try alloc.alloc(c.VkFence, createSwapChainResult.images.len);

    const semaphoreInfo = c.VkSemaphoreCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    };

    const fenceInfo = c.VkFenceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        try checkSuccess(c.vkCreateSemaphore(device.globalDevice, &semaphoreInfo, null, &imageAvailableSemaphores[i]));
        try checkSuccess(c.vkCreateSemaphore(device.globalDevice, &semaphoreInfo, null, &renderFinishedSemaphores[i]));
        try checkSuccess(c.vkCreateFence(device.globalDevice, &fenceInfo, null, &inFlightFences[i]));
        imagesInFlight[i] = c.VK_NULL_HANDLE;
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
    // TODO: switch
    for (availablePresentModes.*) |availablePresentMode| {
        if (availablePresentMode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
            std.log.scoped(.swapchain).info("Present mode: Mailbox", .{});
            return availablePresentMode;
        }
    }

    // also commented out upstream
    // for (availablePresentModes) |availablePresentMode| {
    //     if (availablePresentMode == c.VK_PRESENT_MODE_IMMEDIATE_KHR) {
    //
    //         std.log.scoped(.swapchain).info("Present mode: Immediate", .{});
    //       return availablePresentMode;
    //     }
    //   }

    std.log.scoped(.swapchain).info("Present mode: V-Sync", .{});
    return c.VK_PRESENT_MODE_FIFO_KHR;
}
fn chooseSwapExtent(capabilities: *c.VkSurfaceCapabilitiesKHR, windowExtent: c.VkExtent2D) c.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    } else {
        const actualExtent: c.VkExtent2D = .{
            .width = std.math.max(
                capabilities.minImageExtent.width,
                std.math.min(capabilities.maxImageExtent.width, windowExtent.width),
            ),
            .height = std.math.max(
                capabilities.minImageExtent.height,
                std.math.min(capabilities.maxImageExtent.height, windowExtent.height),
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
            .pAttachments = attachments,
            .width = createSwapChainResult.swapChainExtent.width,
            .height = createSwapChainResult.swapChainExtent.height,
            .layers = 1,
        };

        try checkSuccess(c.vkCreateFramebuffer(device.device(), &framebufferInfo, null, &swapChainFramebuffers[i]));
    }
    return swapChainFramebuffers;
}
