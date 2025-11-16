const c = @import("c.zig").c;
const Device = @import("Device.zig");
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

pub fn init(device: *Device, windowExtent: c.VKExtent2D) !Self {
    const createSwapChainResult = try createSwapChain(device);
    const swapChainImageViews = try createImageViews(createSwapChainResult.images);
    const renderPass = try createRenderPass(device);
    createDepthResources();
    createFramebuffers();
    createSyncObjects();

    return .{
        .swapChainFramebuffers = undefined,
        .renderPass = renderPass,
        .swapChainImageViews = swapChainImageViews,
        .swapChainImages = createSwapChainResult.images,
        .swapChainImageFormat = createSwapChainResult.format,
        .swapChainExtent = createSwapChainResult.extend,

        .depthImages = undefined,
        .depthImageMemorys = undefined,
        .depthImageViews = undefined,

        .device = device,
        .windowExtent = windowExtent,

        .swapChain = undefined,

        .imageAvailableSemaphores = undefined,
        .renderFinishedSemaphores = undefined,
        .inFlightFences = undefined,
        .imagesInFlight = undefined,
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
          .{c.VK_FORMAT_D32_SFLOAT, c.VK_FORMAT_D32_SFLOAT_S8_UINT, c.VK_FORMAT_D24_UNORM_S8_UINT},
          c.VK_IMAGE_TILING_OPTIMAL,
          c.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT);
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
    images: []c.VkImage
};

fn createSwapChain(device: *Device) !CreateSwapChainResult {
    const swapChainSupport = device.getSwapChainSupport();

    const surfaceFormat = chooseSwapSurfaceFormat(swapChainSupport.formats);
    const presentMode = chooseSwapPresentMode(swapChainSupport.presentModes);
    const extent = chooseSwapExtent(swapChainSupport.capabilities);

    var imageCount = swapChainSupport.capabilities.minImageCount + 1;
    if (swapChainSupport.capabilities.maxImageCount > 0 and
        imageCount > swapChainSupport.capabilities.maxImageCount) {
      imageCount = swapChainSupport.capabilities.maxImageCount;
    }

    var createInfo = VkSwapchainCreateInfoKHR{
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
        .clipped = true,
        .oldSwapchain = null
    };

    const indices = device.findPhysicalQueueFamilies();
    const queueFamilyIndices: [2]usize = .{indices.graphicsFamily, indices.presentFamily};

    if (indices.graphicsFamily != indices.presentFamily) {
      createInfo.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
      createInfo.queueFamilyIndexCount = 2;
      createInfo.pQueueFamilyIndices = queueFamilyIndices;
    } else {
      createInfo.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
      createInfo.queueFamilyIndexCount = 0;      // Optional
      createInfo.pQueueFamilyIndices = null;  // Optional
    }

    try checksuccess(c.vkCreateSwapchainKHR(device.globalDevice, &createInfo, null, &swapChain));

    // we only specified a minimum number of images in the swap chain, so the implementation is
    // allowed to create a swap chain with more. That's why we'll first query the final number of
    // images with vkGetSwapchainImagesKHR, then resize the container and finally call it again to
    // retrieve the handles.
    try checksuccess(c.vkGetSwapchainImagesKHR(device.globalDevice, swapChain, &imageCount, null));

    var swapChainImages = try alloc.alloc(c.VkImage, imageCount);
    try checksuccess(c.vkGetSwapchainImagesKHR(device.globalDevice, swapChain, &imageCount, swapChainImages));

    return CreateSwapChainResult{
        .format = surfaceFormat.format,
        .extend = extent,
        .images = swapChainImages,
    };
}
fn createImageViews(alloc: std.mem.Allocator, swapChainImages: []c.VkImage, swapChainImageFormat: c.VkFormat) ![]c.VkImageView {
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
        }

    };


    try checkSuccess(c.vkCreateImageView(device, &viewInfo, null, &swapChainImageViews[i]));
  }
  return swapChainImageViews;
}
fn createDepthResources(self: *Self) !void {
    _ = self;
}
fn createRenderPass(self: *Self, device: *Device, swapChainImageFormat: c.VkFormat) !c.VkRenderPass {
    const depthAttachment= c.VkAttachmentDescription{
        .format = findDepthFormat(device),
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };


    const  depthAttachmentRef =c.VkAttachmentReference{
        .attachment = 1,
        .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
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


    const attachments = [2]c.VkAttachmentDescription{colorAttachment, depthAttachment};
    const renderPassInfo = c.VkRenderPassCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = attachments.len,
        .pAttachments = attachments,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency
    };

var renderPass: c.VkRenderPass = undefined;

    try checkSuccess(c.vkCreateRenderPass(device.globalDevice, &renderPassInfo, null, &renderPass));
    return renderPass;
}
fn createFramebuffers(self: *Self) !void {
    _ = self;
}
fn createSyncObjects(self: *Self) !void {
    _ = self;
}

// Helper functions
fn chooseSwapSurfaceFormat(availableFormats: *[]c.VkSurfaceFormatKHR) c.VkSurfaceFormatKHR {



    for (availableFormats) |availableFormat| {
        if (availableFormat.format == c.VK_FORMAT_B8G8R8A8_SRGB &&
            availableFormat.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                return availableFormat;
        }
  }

  return availableFormats[0];
}

fn chooseSwapPresentMode(availablePresentModes: *[]c.VkPresentModeKHR) !c.VkPresentModeKHR {
    // TODO: switch
    for (availablePresentModes) |availablePresentMode| {
        if (availablePresentMode == c.VK_PRESENT_MODE_MAILBOX_KHR) {

            std.log.scoped(.swapchain).info("Present mode: Mailbox", .{});
          return availablePresentMode;
        }
      }

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
fn chooseSwapExtent(capabilities: *c.VkSurfaceCapabilitiesKHR) !c.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
      } else {
        const actualExtent:c.VkExtent2D = .{
            width: std.math.max(capabilities.minImageExtent.width, std.math.min(capabilities.maxImageExtent.width, self.windowExtent.width)),
            height: std.math.max(capabilities.minImageExtent.height, std.math.min(capabilities.maxImageExtent.height, self.windowExtent.height)),
        }
        return actualExtent;
      }
}
