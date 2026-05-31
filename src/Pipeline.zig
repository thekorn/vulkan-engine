const std = @import("std");
const c = @import("c.zig").c;
const Device = @import("Device.zig");
const Model = @import("Model.zig");

const checkSuccess = @import("utils.zig").checkSuccess;

// Module-level storage so PipelineConfigInfo can safely hold pointers into it
// after defaultPipelineConfigInfo() returns. Putting these on the function's
// stack made `pDynamicStates` dangle, which manifested as Vulkan seeing
// VK_DYNAMIC_STATE_VIEWPORT (value 0) in both slots.
const default_dynamic_state_enables = [_]c.VkDynamicState{
    c.VK_DYNAMIC_STATE_VIEWPORT,
    c.VK_DYNAMIC_STATE_SCISSOR,
};

// Module-level storage backing the default binding/attribute description
// slices in `PipelineConfigInfo`. Mirrors the upstream tutorial's change
// to move these descriptions out of `Pipeline::createGraphicsPipeline`
// and into `PipelineConfigInfo` so render systems can override them
// (e.g. the point-light system uses empty arrays because it generates
// its vertices procedurally from `gl_VertexIndex`).
const default_binding_descriptions = Model.Vertex.getBindingDescriptions();
const default_attribute_descriptions = Model.Vertex.getAttributeDescriptions();

const Self = @This();
alloc: std.mem.Allocator,
device: *Device,
graphicsPipeline: ?c.VkPipeline,
vertShaderModule: c.VkShaderModule,
fragShaderModule: c.VkShaderModule,

pub const PipelineConfigInfo = struct {
    /// Vertex input binding descriptions. Defaults to `Model.Vertex`'s
    /// single binding via `defaultPipelineConfigInfo`; render systems
    /// that draw without vertex buffers (e.g. the point-light billboard
    /// generated from `gl_VertexIndex`) override this with `&.{}`.
    bindingDescriptions: []const c.VkVertexInputBindingDescription = &.{},
    /// Vertex input attribute descriptions; same defaulting rules as
    /// `bindingDescriptions`.
    attributeDescriptions: []const c.VkVertexInputAttributeDescription = &.{},
    viewportInfo: c.VkPipelineViewportStateCreateInfo,
    inputAssemblyInfo: c.VkPipelineInputAssemblyStateCreateInfo,
    rasterizationInfo: c.VkPipelineRasterizationStateCreateInfo,
    multisampleInfo: c.VkPipelineMultisampleStateCreateInfo,
    colorBlendAttachment: c.VkPipelineColorBlendAttachmentState,
    colorBlendInfo: c.VkPipelineColorBlendStateCreateInfo,
    depthStencilInfo: c.VkPipelineDepthStencilStateCreateInfo,
    dynamicStateEnables: []const c.VkDynamicState,
    dynamicStateInfo: c.VkPipelineDynamicStateCreateInfo,
    pipelineLayout: c.VkPipelineLayout = null,
    renderPass: c.VkRenderPass = null,
    subpass: u32 = 0,
};

pub fn init(alloc: std.mem.Allocator, device: *Device, fragShader: []const u8, vertShader: []const u8, configInfo: PipelineConfigInfo) !*Self {
    std.log.scoped(.pipeline).info("frag shader len: {d}", .{fragShader.len});
    std.log.scoped(.pipeline).info("vert shader len: {d}", .{vertShader.len});

    // The pipeline layout and render pass are owned externally and supplied
    // via configInfo. Failing to provide them is a programming error.
    std.debug.assert(configInfo.pipelineLayout != null);
    std.debug.assert(configInfo.renderPass != null);

    // Take a local mutable copy and re-point `colorBlendInfo.pAttachments`
    // at our local `colorBlendAttachment`. The default produced by
    // `defaultPipelineConfigInfo` captures the address of a stack-local
    // in that helper, which is dangling by the time we get here. This
    // also ensures any post-default mutations (e.g.
    // `enableAlphaBlending`) actually reach `vkCreateGraphicsPipelines`.
    var localConfig = configInfo;
    localConfig.colorBlendInfo.pAttachments = &localConfig.colorBlendAttachment;

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

    // Pull the binding/attribute descriptions from the caller-supplied
    // config. The point-light system supplies empty slices because it
    // generates its vertices procedurally from `gl_VertexIndex`.
    const bindingDescriptions = localConfig.bindingDescriptions;
    const attributeDescriptions = localConfig.attributeDescriptions;

    const vertexInputInfo: c.VkPipelineVertexInputStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = @intCast(bindingDescriptions.len),
        .pVertexBindingDescriptions = if (bindingDescriptions.len == 0) null else bindingDescriptions.ptr,
        .vertexAttributeDescriptionCount = @intCast(attributeDescriptions.len),
        .pVertexAttributeDescriptions = if (attributeDescriptions.len == 0) null else attributeDescriptions.ptr,
    };

    const pipelineInfo: c.VkGraphicsPipelineCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2,
        .pStages = &shaderStages,
        .pVertexInputState = &vertexInputInfo,
        .pInputAssemblyState = &localConfig.inputAssemblyInfo,
        .pViewportState = &localConfig.viewportInfo,
        .pRasterizationState = &localConfig.rasterizationInfo,
        .pMultisampleState = &localConfig.multisampleInfo,
        .pDepthStencilState = &localConfig.depthStencilInfo,
        .pColorBlendState = &localConfig.colorBlendInfo,
        .pDynamicState = &localConfig.dynamicStateInfo,
        .layout = localConfig.pipelineLayout,
        .renderPass = localConfig.renderPass,
        .subpass = localConfig.subpass,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    // SAFETY: written by vkCreateGraphicsPipelines below before any read.
    var graphicsPipeline: c.VkPipeline = undefined;

    try checkSuccess(c.vkCreateGraphicsPipelines(device.globalDevice, null, 1, &pipelineInfo, null, &graphicsPipeline));

    const self = try alloc.create(Self);
    self.* = .{
        .alloc = alloc,
        .device = device,
        .graphicsPipeline = graphicsPipeline,
        .vertShaderModule = vertShaderModule,
        .fragShaderModule = fragShaderModule,
    };
    return self;
}

pub fn deinit(self: *Self) void {
    c.vkDestroyShaderModule(self.device.globalDevice, self.vertShaderModule, null);
    c.vkDestroyShaderModule(self.device.globalDevice, self.fragShaderModule, null);
    if (self.graphicsPipeline) |pipeline| {
        c.vkDestroyPipeline(self.device.globalDevice, pipeline, null);
    }
    std.log.scoped(.pipeline).info("deinit done", .{});
    self.alloc.destroy(self);
}

pub fn bind(self: *Self, commandBuffer: c.VkCommandBuffer) void {
    c.vkCmdBindPipeline(commandBuffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.graphicsPipeline orelse unreachable);
}

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

    return .{
        .viewportInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .pViewports = null,
            .scissorCount = 1,
            .pScissors = null,
        },
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

        .dynamicStateEnables = &default_dynamic_state_enables,
        .dynamicStateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = default_dynamic_state_enables.len,
            .pDynamicStates = &default_dynamic_state_enables,
            .flags = 0,
        },

        .bindingDescriptions = &default_binding_descriptions,
        .attributeDescriptions = &default_attribute_descriptions,
    };
}

/// Mutates `configInfo.colorBlendAttachment` to enable the standard
/// "source over" alpha blending used by the point-light billboards.
/// Mirrors `LvePipeline::enableAlphaBlending` from the upstream
/// tutorial 27.
pub fn enableAlphaBlending(configInfo: *PipelineConfigInfo) void {
    configInfo.colorBlendAttachment.blendEnable = c.VK_TRUE;
    configInfo.colorBlendAttachment.colorWriteMask =
        c.VK_COLOR_COMPONENT_R_BIT |
        c.VK_COLOR_COMPONENT_G_BIT |
        c.VK_COLOR_COMPONENT_B_BIT |
        c.VK_COLOR_COMPONENT_A_BIT;
    configInfo.colorBlendAttachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA;
    configInfo.colorBlendAttachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    configInfo.colorBlendAttachment.colorBlendOp = c.VK_BLEND_OP_ADD;
    configInfo.colorBlendAttachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
    configInfo.colorBlendAttachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO;
    configInfo.colorBlendAttachment.alphaBlendOp = c.VK_BLEND_OP_ADD;
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

    // SAFETY: written by vkCreatePipelineLayout below before any read.
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

    // SAFETY: written by vkCreateRenderPass below before any read.
    var renderPass: c.VkRenderPass = undefined;
    try checkSuccess(c.vkCreateRenderPass(device.globalDevice, &renderPassInfo, null, &renderPass));
    return renderPass;
}

test "defaultPipelineConfigInfo input assembly uses triangle list without restart" {
    const config = defaultPipelineConfigInfo();

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
    const config = defaultPipelineConfigInfo();

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
    const config = defaultPipelineConfigInfo();

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
    const config = defaultPipelineConfigInfo();

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
    const config = defaultPipelineConfigInfo();

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
    const config = defaultPipelineConfigInfo();

    try std.testing.expect(config.pipelineLayout == null);
    try std.testing.expect(config.renderPass == null);
    try std.testing.expectEqual(@as(u32, 0), config.subpass);
}

test "defaultPipelineConfigInfo viewport state has 1 viewport/scissor with null pointers (dynamic)" {
    const config = defaultPipelineConfigInfo();

    try std.testing.expectEqual(
        @as(c_uint, c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO),
        config.viewportInfo.sType,
    );
    try std.testing.expectEqual(@as(u32, 1), config.viewportInfo.viewportCount);
    try std.testing.expectEqual(@as(u32, 1), config.viewportInfo.scissorCount);
    // Viewport and scissor are supplied via dynamic state, so the static
    // pointers must remain null.
    try std.testing.expect(config.viewportInfo.pViewports == null);
    try std.testing.expect(config.viewportInfo.pScissors == null);
}

test "defaultPipelineConfigInfo dynamic state enables viewport and scissor" {
    const config = defaultPipelineConfigInfo();

    try std.testing.expectEqual(
        @as(c_uint, c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO),
        config.dynamicStateInfo.sType,
    );
    try std.testing.expectEqual(@as(u32, 2), config.dynamicStateInfo.dynamicStateCount);
    try std.testing.expectEqual(@as(usize, 2), config.dynamicStateEnables.len);
    try std.testing.expectEqual(
        @as(c_uint, c.VK_DYNAMIC_STATE_VIEWPORT),
        config.dynamicStateEnables[0],
    );
    try std.testing.expectEqual(
        @as(c_uint, c.VK_DYNAMIC_STATE_SCISSOR),
        config.dynamicStateEnables[1],
    );
    try std.testing.expectEqual(@as(u32, 0), config.dynamicStateInfo.flags);

    // pDynamicStates must point at the module-level array (not a stale stack
    // slot) and the first entry must be VK_DYNAMIC_STATE_VIEWPORT.
    try std.testing.expect(config.dynamicStateInfo.pDynamicStates != null);
    try std.testing.expectEqual(
        @as(c_uint, c.VK_DYNAMIC_STATE_VIEWPORT),
        config.dynamicStateInfo.pDynamicStates[0],
    );
    try std.testing.expectEqual(
        @as(c_uint, c.VK_DYNAMIC_STATE_SCISSOR),
        config.dynamicStateInfo.pDynamicStates[1],
    );
}

test "defaultPipelineConfigInfo color blend attachment factors and ops match defaults" {
    const config = defaultPipelineConfigInfo();

    try std.testing.expectEqual(
        @as(c_uint, c.VK_BLEND_FACTOR_ONE),
        config.colorBlendAttachment.srcColorBlendFactor,
    );
    try std.testing.expectEqual(
        @as(c_uint, c.VK_BLEND_FACTOR_ZERO),
        config.colorBlendAttachment.dstColorBlendFactor,
    );
    try std.testing.expectEqual(
        @as(c_uint, c.VK_BLEND_OP_ADD),
        config.colorBlendAttachment.colorBlendOp,
    );
    try std.testing.expectEqual(
        @as(c_uint, c.VK_BLEND_FACTOR_ONE),
        config.colorBlendAttachment.srcAlphaBlendFactor,
    );
    try std.testing.expectEqual(
        @as(c_uint, c.VK_BLEND_FACTOR_ZERO),
        config.colorBlendAttachment.dstAlphaBlendFactor,
    );
    try std.testing.expectEqual(
        @as(c_uint, c.VK_BLEND_OP_ADD),
        config.colorBlendAttachment.alphaBlendOp,
    );
}

test "Pipeline struct has expected fields and types" {
    const fields = @typeInfo(Self).@"struct".fields;

    try std.testing.expectEqual(@as(usize, 5), fields.len);
    try std.testing.expectEqualStrings("alloc", fields[0].name);
    try std.testing.expectEqual(std.mem.Allocator, fields[0].type);
    try std.testing.expectEqualStrings("device", fields[1].name);
    try std.testing.expectEqual(*Device, fields[1].type);
    try std.testing.expectEqualStrings("graphicsPipeline", fields[2].name);
    try std.testing.expectEqual(?c.VkPipeline, fields[2].type);
    try std.testing.expectEqualStrings("vertShaderModule", fields[3].name);
    try std.testing.expectEqual(c.VkShaderModule, fields[3].type);
    try std.testing.expectEqualStrings("fragShaderModule", fields[4].name);
    try std.testing.expectEqual(c.VkShaderModule, fields[4].type);
}

test "default_dynamic_state_enables is stable across calls (no dangling pointer)" {
    const a = defaultPipelineConfigInfo();
    const b = defaultPipelineConfigInfo();

    // Both configurations must point at the same module-level storage so the
    // pointer captured in dynamicStateInfo.pDynamicStates stays valid after
    // the helper returns.
    try std.testing.expectEqual(
        @intFromPtr(a.dynamicStateInfo.pDynamicStates),
        @intFromPtr(b.dynamicStateInfo.pDynamicStates),
    );
    try std.testing.expectEqual(
        @intFromPtr(&default_dynamic_state_enables),
        @intFromPtr(a.dynamicStateInfo.pDynamicStates),
    );
}
