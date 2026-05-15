const std = @import("std");
const c = @import("c.zig").c;
const Device = @import("Device.zig");
const Model = @import("Model.zig");

const checkSuccess = @import("utils.zig").checkSuccess;

const Self = @This();
device: *Device,
graphicsPipeline: ?c.VkPipeline,
vertShaderModule: c.VkShaderModule,
fragShaderModule: c.VkShaderModule,

const PipelineConfigInfo = struct {
    viewportInfo: c.VkPipelineViewportStateCreateInfo,
    inputAssemblyInfo: c.VkPipelineInputAssemblyStateCreateInfo,
    rasterizationInfo: c.VkPipelineRasterizationStateCreateInfo,
    multisampleInfo: c.VkPipelineMultisampleStateCreateInfo,
    colorBlendAttachment: c.VkPipelineColorBlendAttachmentState,
    colorBlendInfo: c.VkPipelineColorBlendStateCreateInfo,
    depthStencilInfo: c.VkPipelineDepthStencilStateCreateInfo,
    dynamicStateEnables: []c.VkDynamicState,
    dynamicStateInfo: c.VkPipelineDynamicStateCreateInfo,
    pipelineLayout: c.VkPipelineLayout = null,
    renderPass: c.VkRenderPass = null,
    subpass: u32 = 0,
};

pub fn init(device: *Device, fragShader: []const u8, vertShader: []const u8, configInfo: PipelineConfigInfo) !Self {
    std.log.scoped(.pipeline).info("frag shader len: {d}", .{fragShader.len});
    std.log.scoped(.pipeline).info("vert shader len: {d}", .{vertShader.len});

    // The pipeline layout and render pass are owned externally and supplied
    // via configInfo. Failing to provide them is a programming error.
    std.debug.assert(configInfo.pipelineLayout != null);
    std.debug.assert(configInfo.renderPass != null);

    const vertShaderModule = try createShaderModule(device, vertShader);
    const fragShaderModule = try createShaderModule(device, fragShader);

    const shaderStages = [2]c.VkPipelineShaderStageCreateInfo{
        .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
            .module = vertShaderModule,
            .pName = "main",
            .flags = 0,
            .pSpecializationInfo = null,
            .pNext = null,
        },
        .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = fragShaderModule,
            .pName = "main",
            .flags = 0,
            .pSpecializationInfo = null,
            .pNext = null,
        },
    };

    const bindingDescriptions = Model.Vertex.getBindingDescriptions();
    const attributeDescriptions = Model.Vertex.getAttributeDescriptions();

    const vertexInputInfo: c.VkPipelineVertexInputStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = bindingDescriptions.len,
        .pVertexBindingDescriptions = &bindingDescriptions,
        .vertexAttributeDescriptionCount = attributeDescriptions.len,
        .pVertexAttributeDescriptions = &attributeDescriptions,
    };

    const pipelineInfo: c.VkGraphicsPipelineCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2,
        .pStages = &shaderStages,
        .pVertexInputState = &vertexInputInfo,
        .pInputAssemblyState = &configInfo.inputAssemblyInfo,
        .pViewportState = &configInfo.viewportInfo,
        .pRasterizationState = &configInfo.rasterizationInfo,
        .pMultisampleState = &configInfo.multisampleInfo,
        .pDepthStencilState = &configInfo.depthStencilInfo,
        .pColorBlendState = &configInfo.colorBlendInfo,
        .pDynamicState = &configInfo.dynamicStateInfo,
        .layout = configInfo.pipelineLayout,
        .renderPass = configInfo.renderPass,
        .subpass = configInfo.subpass,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    var graphicsPipeline: c.VkPipeline = undefined;

    try checkSuccess(c.vkCreateGraphicsPipelines(device.globalDevice, null, 1, &pipelineInfo, null, &graphicsPipeline));

    return .{
        .device = device,
        .graphicsPipeline = graphicsPipeline,
        .vertShaderModule = vertShaderModule,
        .fragShaderModule = fragShaderModule,
    };
}

pub fn deinit(self: *Self) void {
    c.vkDestroyShaderModule(self.device.globalDevice, self.vertShaderModule, null);
    c.vkDestroyShaderModule(self.device.globalDevice, self.fragShaderModule, null);
    if (self.graphicsPipeline) |pipeline| {
        c.vkDestroyPipeline(self.device.globalDevice, pipeline, null);
    }
    std.log.scoped(.pipeline).info("deinit done", .{});
}

pub fn bind(self: *Self, commandBuffer: c.VkCommandBuffer) void {
    c.vkCmdBindPipeline(commandBuffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.graphicsPipeline orelse unreachable);
}

// see: https://pastebin.com/EmsJWHzb
pub fn defaultPipelineConfigInfo() PipelineConfigInfo {
    const colorBlendAttachment: c.VkPipelineColorBlendAttachmentState = .{
        .blendEnable = c.VK_FALSE,
        .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE, // Optional
        .dstColorBlendFactor = c.VK_BLEND_FACTOR_ZERO, // Optional
        .colorBlendOp = c.VK_BLEND_OP_ADD, // Optional
        .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE, // Optional
        .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO, // Optional
        .alphaBlendOp = c.VK_BLEND_OP_ADD, // Optional
        .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
    };

    const dynamicStateEnables = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };

    return .{
        .inputAssemblyInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = c.VK_FALSE,
        },
        .rasterizationInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .depthClampEnable = c.VK_FALSE,
            .rasterizerDiscardEnable = c.VK_FALSE,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .lineWidth = 1.0,
            .cullMode = c.VK_CULL_MODE_NONE,
            .frontFace = c.VK_FRONT_FACE_CLOCKWISE,
            .depthBiasEnable = c.VK_FALSE,
            .depthBiasConstantFactor = 0.0, //Optional
            .depthBiasClamp = 0.0, //Optional
            .depthBiasSlopeFactor = 0.0, //Optional
        },
        .multisampleInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = c.VK_FALSE,
            .minSampleShading = 1.0, //Optional
            .pSampleMask = null, //Optional
            .alphaToCoverageEnable = c.VK_FALSE, //Optional
            .alphaToOneEnable = c.VK_FALSE, //Optional
        },
        .colorBlendAttachment = colorBlendAttachment,
        .colorBlendInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = c.VK_FALSE,
            .logicOp = c.VK_LOGIC_OP_COPY, //Optional
            .attachmentCount = 1,
            .pAttachments = &colorBlendAttachment,
            .blendConstants = [_]f32{ 0.0, 0.0, 0.0, 0.0 }, //Optional
        },

        .depthStencilInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .depthTestEnable = c.VK_TRUE,
            .depthWriteEnable = c.VK_TRUE,
            .depthCompareOp = c.VK_COMPARE_OP_LESS,
            .depthBoundsTestEnable = c.VK_FALSE,
            .minDepthBounds = 0.0, //Optional
            .maxDepthBounds = 1.0, //Optional
            .stencilTestEnable = c.VK_FALSE,
            .front = .{}, //Optional
            .back = .{}, //Optional
        },

        .dynamicStateEnables = dynamicStateEnables[0..],
        .dynamicStateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = dynamicStateEnables.len,
            .pDynamicStates = &dynamicStateEnables,
            .flag = 0,
        },
    };
}

fn createShaderModule(device: *Device, shaderCode: []const u8) !c.VkShaderModule {
    return device.createShaderModule(shaderCode);
}

fn createPipelineLayout(device: *Device) !c.VkPipelineLayout {
    const pipelineLayoutInfo: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 0,
        .pSetLayouts = null,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
        .pNext = null,
        .flags = 0,
    };

    var pipelineLayout: c.VkPipelineLayout = undefined;
    try checkSuccess(c.vkCreatePipelineLayout(device.globalDevice, &pipelineLayoutInfo, null, &pipelineLayout));
    return pipelineLayout;
}

fn createRenderPass(device: *Device) !c.VkRenderPass {
    // Color attachment
    const colorAttachment: c.VkAttachmentDescription = .{
        .format = c.VK_FORMAT_B8G8R8A8_UNORM, // Common format for macOS/MoltenVK
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        .flags = 0,
    };

    const colorAttachmentRef: c.VkAttachmentReference = .{
        .attachment = 0,
        .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    const subpass: c.VkSubpassDescription = .{
        .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &colorAttachmentRef,
        .pInputAttachments = null,
        .pResolveAttachments = null,
        .pDepthStencilAttachment = null,
        .preserveAttachmentCount = 0,
        .pPreserveAttachments = null,
        .flags = 0,
    };

    const dependency: c.VkSubpassDependency = .{
        .srcSubpass = c.VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .dependencyFlags = 0,
    };

    const renderPassInfo: c.VkRenderPassCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &colorAttachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
        .pNext = null,
        .flags = 0,
    };

    var renderPass: c.VkRenderPass = undefined;
    try checkSuccess(c.vkCreateRenderPass(device.globalDevice, &renderPassInfo, null, &renderPass));
    return renderPass;
}

test "defaultPipelineConfigInfo viewport matches given dimensions" {
    const config = defaultPipelineConfigInfo(800, 600);

    try std.testing.expectEqual(@as(f32, 0), config.viewport.x);
    try std.testing.expectEqual(@as(f32, 0), config.viewport.y);
    try std.testing.expectEqual(@as(f32, 800), config.viewport.width);
    try std.testing.expectEqual(@as(f32, 600), config.viewport.height);
    try std.testing.expectEqual(@as(f32, 0.0), config.viewport.minDepth);
    try std.testing.expectEqual(@as(f32, 1.0), config.viewport.maxDepth);
}

test "defaultPipelineConfigInfo scissor matches given dimensions" {
    const config = defaultPipelineConfigInfo(1024, 768);

    try std.testing.expectEqual(@as(i32, 0), config.scissor.offset.x);
    try std.testing.expectEqual(@as(i32, 0), config.scissor.offset.y);
    try std.testing.expectEqual(@as(u32, 1024), config.scissor.extent.width);
    try std.testing.expectEqual(@as(u32, 768), config.scissor.extent.height);
}

test "defaultPipelineConfigInfo input assembly uses triangle list without restart" {
    const config = defaultPipelineConfigInfo(800, 600);

    try std.testing.expectEqual(
        @as(c_uint, c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO),
        config.inputAssemblyInfo.sType,
    );
    try std.testing.expectEqual(
        @as(c_uint, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST),
        config.inputAssemblyInfo.topology,
    );
    try std.testing.expectEqual(
        @as(c.VkBool32, c.VK_FALSE),
        config.inputAssemblyInfo.primitiveRestartEnable,
    );
}

test "defaultPipelineConfigInfo rasterization uses fill, no culling, line width 1.0" {
    const config = defaultPipelineConfigInfo(800, 600);

    try std.testing.expectEqual(
        @as(c_uint, c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO),
        config.rasterizationInfo.sType,
    );
    try std.testing.expectEqual(@as(c.VkBool32, c.VK_FALSE), config.rasterizationInfo.depthClampEnable);
    try std.testing.expectEqual(@as(c.VkBool32, c.VK_FALSE), config.rasterizationInfo.rasterizerDiscardEnable);
    try std.testing.expectEqual(@as(c_uint, c.VK_POLYGON_MODE_FILL), config.rasterizationInfo.polygonMode);
    try std.testing.expectEqual(@as(f32, 1.0), config.rasterizationInfo.lineWidth);
    try std.testing.expectEqual(@as(c_uint, c.VK_CULL_MODE_NONE), config.rasterizationInfo.cullMode);
    try std.testing.expectEqual(@as(c_uint, c.VK_FRONT_FACE_CLOCKWISE), config.rasterizationInfo.frontFace);
    try std.testing.expectEqual(@as(c.VkBool32, c.VK_FALSE), config.rasterizationInfo.depthBiasEnable);
}

test "defaultPipelineConfigInfo multisample uses 1x sampling" {
    const config = defaultPipelineConfigInfo(800, 600);

    try std.testing.expectEqual(
        @as(c_uint, c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO),
        config.multisampleInfo.sType,
    );
    try std.testing.expectEqual(
        @as(c_uint, c.VK_SAMPLE_COUNT_1_BIT),
        config.multisampleInfo.rasterizationSamples,
    );
    try std.testing.expectEqual(@as(c.VkBool32, c.VK_FALSE), config.multisampleInfo.sampleShadingEnable);
    try std.testing.expectEqual(@as(c.VkBool32, c.VK_FALSE), config.multisampleInfo.alphaToCoverageEnable);
    try std.testing.expectEqual(@as(c.VkBool32, c.VK_FALSE), config.multisampleInfo.alphaToOneEnable);
}

test "defaultPipelineConfigInfo color blending is disabled with all channels writable" {
    const config = defaultPipelineConfigInfo(800, 600);

    try std.testing.expectEqual(@as(c.VkBool32, c.VK_FALSE), config.colorBlendAttachment.blendEnable);
    const expected_mask: c_uint = c.VK_COLOR_COMPONENT_R_BIT |
        c.VK_COLOR_COMPONENT_G_BIT |
        c.VK_COLOR_COMPONENT_B_BIT |
        c.VK_COLOR_COMPONENT_A_BIT;
    try std.testing.expectEqual(expected_mask, config.colorBlendAttachment.colorWriteMask);

    try std.testing.expectEqual(
        @as(c_uint, c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO),
        config.colorBlendInfo.sType,
    );
    try std.testing.expectEqual(@as(c.VkBool32, c.VK_FALSE), config.colorBlendInfo.logicOpEnable);
    try std.testing.expectEqual(@as(c_uint, c.VK_LOGIC_OP_COPY), config.colorBlendInfo.logicOp);
    try std.testing.expectEqual(@as(u32, 1), config.colorBlendInfo.attachmentCount);
    for (config.colorBlendInfo.blendConstants) |bc| {
        try std.testing.expectEqual(@as(f32, 0.0), bc);
    }
}

test "defaultPipelineConfigInfo depth/stencil enables depth test with LESS compare" {
    const config = defaultPipelineConfigInfo(800, 600);

    try std.testing.expectEqual(
        @as(c_uint, c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO),
        config.depthStencilInfo.sType,
    );
    try std.testing.expectEqual(@as(c.VkBool32, c.VK_TRUE), config.depthStencilInfo.depthTestEnable);
    try std.testing.expectEqual(@as(c.VkBool32, c.VK_TRUE), config.depthStencilInfo.depthWriteEnable);
    try std.testing.expectEqual(@as(c_uint, c.VK_COMPARE_OP_LESS), config.depthStencilInfo.depthCompareOp);
    try std.testing.expectEqual(@as(c.VkBool32, c.VK_FALSE), config.depthStencilInfo.depthBoundsTestEnable);
    try std.testing.expectEqual(@as(f32, 0.0), config.depthStencilInfo.minDepthBounds);
    try std.testing.expectEqual(@as(f32, 1.0), config.depthStencilInfo.maxDepthBounds);
    try std.testing.expectEqual(@as(c.VkBool32, c.VK_FALSE), config.depthStencilInfo.stencilTestEnable);
}

test "defaultPipelineConfigInfo defaults pipelineLayout, renderPass and subpass" {
    const config = defaultPipelineConfigInfo(800, 600);

    try std.testing.expect(config.pipelineLayout == null);
    try std.testing.expect(config.renderPass == null);
    try std.testing.expectEqual(@as(u32, 0), config.subpass);
}

test "defaultPipelineConfigInfo handles non-square dimensions" {
    const config = defaultPipelineConfigInfo(1920, 1080);

    try std.testing.expectEqual(@as(f32, 1920), config.viewport.width);
    try std.testing.expectEqual(@as(f32, 1080), config.viewport.height);
    try std.testing.expectEqual(@as(u32, 1920), config.scissor.extent.width);
    try std.testing.expectEqual(@as(u32, 1080), config.scissor.extent.height);
}
