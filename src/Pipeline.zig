const std = @import("std");
const c = @import("c.zig").c;
const Device = @import("Device.zig");

const checkSuccess = @import("utils.zig").checkSuccess;

const Self = @This();
device: *Device,
graphicsPipeline: ?c.VkPipeline,
vertShaderModule: c.VkShaderModule,
fragShaderModule: c.VkShaderModule,

const PipelineConfigInfo = struct {
    viewport: c.VkViewport,
    scissor: c.VkRect2D,
    viewportInfo: c.VkPipelineViewportStateCreateInfo,
    inputAssemblyInfo: c.VkPipelineInputAssemblyStateCreateInfo,
    rasterizationInfo: c.VkPipelineRasterizationStateCreateInfo,
    multisampleInfo: c.VkPipelineMultisampleStateCreateInfo,
    colorBlendAttachment: c.VkPipelineColorBlendAttachmentState,
    colorBlendInfo: c.VkPipelineColorBlendStateCreateInfo,
    depthStencilInfo: c.VkPipelineDepthStencilStateCreateInfo,
    pipelineLayout: c.VkPipelineLayout = null,
    renderPass: c.VkRenderPass = null,
    subpass: u32 = 0,
};

pub fn init(device: *Device, fragShader: []const u8, vertShader: []const u8, configInfo: PipelineConfigInfo) !Self {
    std.log.scoped(.pipeline).info("frag shader len: {d}", .{fragShader.len});
    std.log.scoped(.pipeline).info("vert shader len: {d}", .{vertShader.len});

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

    const vertexInputInfo: c.VkPipelineVertexInputStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = null,
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = null,
    };

    const pipelineInfo: c.VkGraphicsPipelineCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2,
        .pStages = &shaderStages,
        .pVertexInputState = &vertexInputInfo,
        .pInputAssemblyState = &configInfo.inputAssemblyInfo,
        .pViewportState = &configInfo.viewportInfo,
        .pRasterizationState = &configInfo.rasterizationInfo,
        .pDepthStencilState = &configInfo.depthStencilInfo,
        .pColorBlendState = &configInfo.colorBlendInfo,
        .pDynamicState = null,
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
    _ = self;
}

// see: https://pastebin.com/EmsJWHzb
pub fn defaultPipelineConfigInfo(width: i32, height: i32) PipelineConfigInfo {
    const viewport: c.VkViewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };
    const scissor: c.VkRect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = @intCast(width), .height = @intCast(height) },
    };

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
        .viewport = viewport,
        .scissor = scissor,
        .viewportInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .pViewports = &viewport,
            .scissorCount = 1,
            .pScissors = &scissor,
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
    };
}

fn createShaderModule(device: *Device, shaderCode: []const u8) !c.VkShaderModule {
    return device.createShaderModule(shaderCode);
}
