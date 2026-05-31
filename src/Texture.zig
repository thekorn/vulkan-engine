//! GPU texture: `VkImage` + `VkDeviceMemory` + `VkImageView` + `VkSampler`.
//!
//! Mirrors `LveTexture` from the upstream Little Vulkan Engine
//! tutorial (loosely — the upstream version uses stb_image, here the
//! initial asset is a KTX1 file). Owns every Vulkan object it creates;
//! `deinit` destroys them in reverse order.
//!
//! Two constructors:
//!   - `initFromPixels` — upload an already-decoded RGBA8 buffer (used
//!     for the 1×1 default white texture so every renderable object
//!     can share the same descriptor-set layout).
//!   - `initFromKtxBytes` — strict KTX1 parser limited to the exact
//!     asset shape the project ships
//!     (`textures/stonefloor01_color_rgba.ktx`: 2D, single layer/face,
//!     `GL_RGBA8`/`GL_UNSIGNED_BYTE`, native endian). Only mip level 0
//!     is uploaded for now; the sampler is created with `maxLod = 0`.

const std = @import("std");

const c = @import("c.zig").c;
const Buffer = @import("Buffer.zig");
const Device = @import("Device.zig");
const checkSuccess = @import("utils.zig").checkSuccess;

const Self = @This();

device: *Device,
image: c.VkImage = null,
imageMemory: c.VkDeviceMemory = null,
imageView: c.VkImageView = null,
sampler: c.VkSampler = null,
width: u32,
height: u32,
mipLevels: u32 = 1,
format: c.VkFormat = c.VK_FORMAT_R8G8B8A8_UNORM,
layout: c.VkImageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,

/// Upload a decoded RGBA8 pixel buffer into a new device-local image.
/// `pixels.len` must equal `width * height * 4`.
pub fn initFromPixels(
    device: *Device,
    pixels: []const u8,
    width: u32,
    height: u32,
) !Self {
    std.debug.assert(pixels.len == @as(usize, width) * @as(usize, height) * 4);

    var self: Self = .{
        .device = device,
        .width = width,
        .height = height,
    };

    // Staging buffer (host-visible, host-coherent) holds the RGBA pixels
    // until `vkCmdCopyBufferToImage` moves them into the device-local
    // image. Same staging pattern Model.zig uses for vertex/index data.
    var staging = try Buffer.init(
        device,
        pixels.len,
        1,
        c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        1,
    );
    defer staging.deinit();
    try staging.map(c.VK_WHOLE_SIZE, 0);
    staging.writeToBuffer(@ptrCast(pixels.ptr), c.VK_WHOLE_SIZE, 0);

    try self.createImage();
    errdefer self.destroyImage();

    try device.transitionImageLayout(
        self.image,
        c.VK_IMAGE_LAYOUT_UNDEFINED,
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        self.mipLevels,
    );
    self.layout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;

    try device.copyBufferToImage(staging.buffer, self.image, width, height);

    try device.transitionImageLayout(
        self.image,
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        self.mipLevels,
    );
    self.layout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    try self.createImageView();
    errdefer c.vkDestroyImageView(device.globalDevice, self.imageView, null);

    try self.createSampler();

    return self;
}

/// Parse a KTX1 byte stream and upload mip level 0 into a new
/// device-local image. The parser is intentionally strict: it
/// rejects anything outside the exact asset shape the project ships
/// (2D, single layer, single face, `GL_RGBA8` / `GL_UNSIGNED_BYTE`,
/// native endianness) so corrupt or unexpected assets fail loudly
/// instead of producing garbled pixels.
pub fn initFromKtxBytes(
    device: *Device,
    bytes: []const u8,
) !Self {
    const Header = extern struct {
        identifier: [12]u8,
        endianness: u32,
        glType: u32,
        glTypeSize: u32,
        glFormat: u32,
        glInternalFormat: u32,
        glBaseInternalFormat: u32,
        pixelWidth: u32,
        pixelHeight: u32,
        pixelDepth: u32,
        numberOfArrayElements: u32,
        numberOfFaces: u32,
        numberOfMipmapLevels: u32,
        bytesOfKeyValueData: u32,
    };

    if (bytes.len < @sizeOf(Header)) return error.InvalidKtx;

    // KTX1 identifier: «1 1 1 1» (the 11 chars `«KTX 11»` framed by
    // 0xAB / 0xBB / line-ending magic). Reject anything else.
    const expected_id = [_]u8{
        0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB,
        0x0D, 0x0A, 0x1A, 0x0A,
    };

    // SAFETY: written by the @memcpy below before any read.
    var header: Header = undefined;
    @memcpy(std.mem.asBytes(&header), bytes[0..@sizeOf(Header)]);

    if (!std.mem.eql(u8, &header.identifier, &expected_id)) {
        return error.InvalidKtx;
    }
    // Endianness marker == 0x04030201 means the file was written on a
    // little-endian system, which matches every platform we currently
    // build for. A swapped marker would require byte-swapping the
    // header fields; reject for now.
    if (header.endianness != 0x04030201) return error.UnsupportedKtxEndianness;
    if (header.glType != 0x1401) return error.UnsupportedKtxFormat; // GL_UNSIGNED_BYTE
    if (header.glTypeSize != 1) return error.UnsupportedKtxFormat;
    if (header.glFormat != 0x1908) return error.UnsupportedKtxFormat; // GL_RGBA
    if (header.glInternalFormat != 0x8058) return error.UnsupportedKtxFormat; // GL_RGBA8
    if (header.pixelDepth != 0) return error.UnsupportedKtxFormat;
    if (header.numberOfArrayElements != 0) return error.UnsupportedKtxFormat;
    if (header.numberOfFaces != 1) return error.UnsupportedKtxFormat;
    if (header.pixelWidth == 0 or header.pixelHeight == 0) return error.InvalidKtx;

    // Skip the optional key-value metadata block (orientation, etc.)
    // and then read the first mip-level imageSize + data.
    //
    // Every offset / size computation below is done in checked `usize`
    // arithmetic so that a malformed KTX header (gigantic
    // `bytesOfKeyValueData` / `pixelWidth` / `pixelHeight`) fails with
    // `error.InvalidKtx` instead of trapping in safe builds or
    // wrapping silently in unchecked builds.
    const kv_len: usize = header.bytesOfKeyValueData;
    const mip0_offset = std.math.add(usize, @sizeOf(Header), kv_len) catch
        return error.InvalidKtx;
    const image_size_offset_end = std.math.add(usize, mip0_offset, 4) catch
        return error.InvalidKtx;
    if (image_size_offset_end > bytes.len) return error.InvalidKtx;

    // SAFETY: written by the @memcpy below before any read.
    var image_size: u32 = undefined;
    @memcpy(std.mem.asBytes(&image_size), bytes[mip0_offset..image_size_offset_end]);

    const w: usize = header.pixelWidth;
    const h: usize = header.pixelHeight;
    const wh = std.math.mul(usize, w, h) catch return error.InvalidKtx;
    const expected_size = std.math.mul(usize, wh, 4) catch return error.InvalidKtx;
    if (@as(usize, image_size) != expected_size) return error.InvalidKtx;

    const pixels_start = image_size_offset_end;
    const pixels_end = std.math.add(usize, pixels_start, image_size) catch
        return error.InvalidKtx;
    if (pixels_end > bytes.len) return error.InvalidKtx;

    return initFromPixels(
        device,
        bytes[pixels_start..pixels_end],
        header.pixelWidth,
        header.pixelHeight,
    );
}

pub fn deinit(self: *Self) void {
    if (self.sampler != null) {
        c.vkDestroySampler(self.device.globalDevice, self.sampler, null);
        self.sampler = null;
    }
    if (self.imageView != null) {
        c.vkDestroyImageView(self.device.globalDevice, self.imageView, null);
        self.imageView = null;
    }
    self.destroyImage();
}

fn destroyImage(self: *Self) void {
    if (self.image != null) {
        c.vkDestroyImage(self.device.globalDevice, self.image, null);
        self.image = null;
    }
    if (self.imageMemory != null) {
        c.vkFreeMemory(self.device.globalDevice, self.imageMemory, null);
        self.imageMemory = null;
    }
}

fn createImage(self: *Self) !void {
    var imageInfo: c.VkImageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .extent = .{
            .width = self.width,
            .height = self.height,
            .depth = 1,
        },
        .mipLevels = self.mipLevels,
        .arrayLayers = 1,
        .format = self.format,
        .tiling = c.VK_IMAGE_TILING_OPTIMAL,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .flags = 0,
    };
    try self.device.createImageWithInfo(
        &imageInfo,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        &self.image,
        &self.imageMemory,
    );
}

fn createImageView(self: *Self) !void {
    const viewInfo: c.VkImageViewCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = self.image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = self.format,
        .subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = self.mipLevels,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    try checkSuccess(c.vkCreateImageView(
        self.device.globalDevice,
        &viewInfo,
        null,
        &self.imageView,
    ));
}

fn createSampler(self: *Self) !void {
    // No anisotropic filtering — `samplerAnisotropy` is not enabled in
    // `Vulkan.createLogicalDevice`, and enabling it here without
    // enabling the matching device feature is a validation error.
    const samplerInfo: c.VkSamplerCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = c.VK_FILTER_LINEAR,
        .minFilter = c.VK_FILTER_LINEAR,
        .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .anisotropyEnable = c.VK_FALSE,
        .maxAnisotropy = 1.0,
        .borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = c.VK_FALSE,
        .compareEnable = c.VK_FALSE,
        .compareOp = c.VK_COMPARE_OP_ALWAYS,
        .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR,
        .mipLodBias = 0.0,
        .minLod = 0.0,
        // mip-0-only for now; sampling beyond the base level is a no-op.
        .maxLod = @floatFromInt(self.mipLevels - 1),
    };
    try checkSuccess(c.vkCreateSampler(
        self.device.globalDevice,
        &samplerInfo,
        null,
        &self.sampler,
    ));
}

/// `VkDescriptorImageInfo` covering this texture's view + sampler,
/// matching the `SHADER_READ_ONLY_OPTIMAL` layout the image is left
/// in after `initFromPixels` / `initFromKtxBytes`.
pub fn descriptorInfo(self: *const Self) c.VkDescriptorImageInfo {
    return .{
        .sampler = self.sampler,
        .imageView = self.imageView,
        .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "initFromKtxBytes rejects buffers smaller than the KTX1 header" {
    // SAFETY: the call returns InvalidKtx before touching `device`.
    var device: Device = undefined;
    const bytes: [4]u8 = .{ 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidKtx, initFromKtxBytes(&device, bytes[0..]));
}

test "initFromKtxBytes rejects a wrong identifier" {
    var device: Device = undefined;
    // 64 zero bytes — large enough to span the header but with the
    // wrong magic identifier.
    const bytes: [64]u8 = @splat(0);
    try std.testing.expectError(error.InvalidKtx, initFromKtxBytes(&device, bytes[0..]));
}

test "initFromKtxBytes rejects an unsupported endianness marker" {
    var device: Device = undefined;
    var bytes: [64]u8 = @splat(0);
    const id = [_]u8{ 0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A };
    @memcpy(bytes[0..12], &id);
    // endianness = 0xDEADBEEF (neither native nor swapped 0x04030201).
    bytes[12] = 0xEF;
    bytes[13] = 0xBE;
    bytes[14] = 0xAD;
    bytes[15] = 0xDE;
    try std.testing.expectError(
        error.UnsupportedKtxEndianness,
        initFromKtxBytes(&device, bytes[0..]),
    );
}

test "Texture has expected fields and types" {
    const fields = @typeInfo(Self).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 10), fields.len);
    try std.testing.expectEqual(*Device, @FieldType(Self, "device"));
    try std.testing.expectEqual(c.VkImage, @FieldType(Self, "image"));
    try std.testing.expectEqual(c.VkDeviceMemory, @FieldType(Self, "imageMemory"));
    try std.testing.expectEqual(c.VkImageView, @FieldType(Self, "imageView"));
    try std.testing.expectEqual(c.VkSampler, @FieldType(Self, "sampler"));
    try std.testing.expectEqual(u32, @FieldType(Self, "width"));
    try std.testing.expectEqual(u32, @FieldType(Self, "height"));
    try std.testing.expectEqual(u32, @FieldType(Self, "mipLevels"));
    try std.testing.expectEqual(c.VkFormat, @FieldType(Self, "format"));
    try std.testing.expectEqual(c.VkImageLayout, @FieldType(Self, "layout"));
}

test "deinit on an empty (uninitialized) Texture is a safe no-op" {
    var tex: Self = .{
        .device = @ptrFromInt(0x1000),
        .width = 0,
        .height = 0,
    };
    tex.deinit();
    try std.testing.expectEqual(@as(c.VkImage, null), tex.image);
    try std.testing.expectEqual(@as(c.VkDeviceMemory, null), tex.imageMemory);
    try std.testing.expectEqual(@as(c.VkImageView, null), tex.imageView);
    try std.testing.expectEqual(@as(c.VkSampler, null), tex.sampler);
}

test "descriptorInfo returns sampler/imageView/SHADER_READ_ONLY_OPTIMAL" {
    // Use sentinel pointer values so we can verify the fields are
    // forwarded verbatim into the VkDescriptorImageInfo without needing
    // a live Vulkan context.
    const sampler_handle: c.VkSampler = @ptrFromInt(0xCAFE);
    const view_handle: c.VkImageView = @ptrFromInt(0xBEEF);
    const tex: Self = .{
        .device = @ptrFromInt(0x1000),
        .width = 4,
        .height = 4,
        .sampler = sampler_handle,
        .imageView = view_handle,
    };
    const info = tex.descriptorInfo();
    try std.testing.expectEqual(sampler_handle, info.sampler);
    try std.testing.expectEqual(view_handle, info.imageView);
    try std.testing.expectEqual(
        @as(c.VkImageLayout, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL),
        info.imageLayout,
    );
}

// ---------------------------------------------------------------------
// KTX1 parser rejection tests
//
// `initFromKtxBytes` validates the header against the exact shape the
// project's assets ship in. Each test below targets one of the
// rejection branches and uses `buildKtxHeader` to seed a baseline
// "would otherwise pass" header so the test only mutates the single
// field under test. None of these tests reach the Vulkan upload path.
// ---------------------------------------------------------------------

const ktx_identifier = [_]u8{
    0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB,
    0x0D, 0x0A, 0x1A, 0x0A,
};

/// Build a 64-byte KTX1 header with valid magic + format fields by
/// default. Callers mutate individual fields before passing the bytes
/// to `initFromKtxBytes`. The order of the `u32`s matches the
/// `Header extern struct` declared inside `initFromKtxBytes`.
fn buildKtxHeader(
    pixel_width: u32,
    pixel_height: u32,
    bytes_of_key_value_data: u32,
) [64]u8 {
    var bytes: [64]u8 = @splat(0);
    @memcpy(bytes[0..12], &ktx_identifier);
    // endianness = 0x04030201 (native little-endian).
    std.mem.writeInt(u32, bytes[12..16], 0x04030201, .little);
    // glType = GL_UNSIGNED_BYTE (0x1401)
    std.mem.writeInt(u32, bytes[16..20], 0x1401, .little);
    // glTypeSize = 1
    std.mem.writeInt(u32, bytes[20..24], 1, .little);
    // glFormat = GL_RGBA (0x1908)
    std.mem.writeInt(u32, bytes[24..28], 0x1908, .little);
    // glInternalFormat = GL_RGBA8 (0x8058)
    std.mem.writeInt(u32, bytes[28..32], 0x8058, .little);
    // glBaseInternalFormat = GL_RGBA (0x1908) — not validated but
    // populated for completeness.
    std.mem.writeInt(u32, bytes[32..36], 0x1908, .little);
    // pixelWidth
    std.mem.writeInt(u32, bytes[36..40], pixel_width, .little);
    // pixelHeight
    std.mem.writeInt(u32, bytes[40..44], pixel_height, .little);
    // pixelDepth = 0 (2D image)
    std.mem.writeInt(u32, bytes[44..48], 0, .little);
    // numberOfArrayElements = 0 (not an array)
    std.mem.writeInt(u32, bytes[48..52], 0, .little);
    // numberOfFaces = 1 (not a cubemap)
    std.mem.writeInt(u32, bytes[52..56], 1, .little);
    // numberOfMipmapLevels = 1
    std.mem.writeInt(u32, bytes[56..60], 1, .little);
    // bytesOfKeyValueData
    std.mem.writeInt(u32, bytes[60..64], bytes_of_key_value_data, .little);
    return bytes;
}

test "initFromKtxBytes rejects an unsupported glType" {
    var device: Device = undefined;
    var bytes = buildKtxHeader(1, 1, 0);
    // glType = GL_UNSIGNED_SHORT (0x1403) — not supported.
    std.mem.writeInt(u32, bytes[16..20], 0x1403, .little);
    try std.testing.expectError(
        error.UnsupportedKtxFormat,
        initFromKtxBytes(&device, bytes[0..]),
    );
}

test "initFromKtxBytes rejects an unsupported glTypeSize" {
    var device: Device = undefined;
    var bytes = buildKtxHeader(1, 1, 0);
    std.mem.writeInt(u32, bytes[20..24], 2, .little);
    try std.testing.expectError(
        error.UnsupportedKtxFormat,
        initFromKtxBytes(&device, bytes[0..]),
    );
}

test "initFromKtxBytes rejects an unsupported glFormat" {
    var device: Device = undefined;
    var bytes = buildKtxHeader(1, 1, 0);
    // GL_RGB (0x1907) instead of GL_RGBA.
    std.mem.writeInt(u32, bytes[24..28], 0x1907, .little);
    try std.testing.expectError(
        error.UnsupportedKtxFormat,
        initFromKtxBytes(&device, bytes[0..]),
    );
}

test "initFromKtxBytes rejects an unsupported glInternalFormat" {
    var device: Device = undefined;
    var bytes = buildKtxHeader(1, 1, 0);
    // GL_RGB8 (0x8051) instead of GL_RGBA8 (0x8058).
    std.mem.writeInt(u32, bytes[28..32], 0x8051, .little);
    try std.testing.expectError(
        error.UnsupportedKtxFormat,
        initFromKtxBytes(&device, bytes[0..]),
    );
}

test "initFromKtxBytes rejects a non-zero pixelDepth (3D image)" {
    var device: Device = undefined;
    var bytes = buildKtxHeader(1, 1, 0);
    std.mem.writeInt(u32, bytes[44..48], 4, .little);
    try std.testing.expectError(
        error.UnsupportedKtxFormat,
        initFromKtxBytes(&device, bytes[0..]),
    );
}

test "initFromKtxBytes rejects array textures" {
    var device: Device = undefined;
    var bytes = buildKtxHeader(1, 1, 0);
    // numberOfArrayElements != 0 → array texture, unsupported.
    std.mem.writeInt(u32, bytes[48..52], 2, .little);
    try std.testing.expectError(
        error.UnsupportedKtxFormat,
        initFromKtxBytes(&device, bytes[0..]),
    );
}

test "initFromKtxBytes rejects cubemap textures (numberOfFaces != 1)" {
    var device: Device = undefined;
    var bytes = buildKtxHeader(1, 1, 0);
    std.mem.writeInt(u32, bytes[52..56], 6, .little);
    try std.testing.expectError(
        error.UnsupportedKtxFormat,
        initFromKtxBytes(&device, bytes[0..]),
    );
}

test "initFromKtxBytes rejects a zero pixelWidth" {
    var device: Device = undefined;
    const bytes = buildKtxHeader(0, 1, 0);
    try std.testing.expectError(
        error.InvalidKtx,
        initFromKtxBytes(&device, bytes[0..]),
    );
}

test "initFromKtxBytes rejects a zero pixelHeight" {
    var device: Device = undefined;
    const bytes = buildKtxHeader(1, 0, 0);
    try std.testing.expectError(
        error.InvalidKtx,
        initFromKtxBytes(&device, bytes[0..]),
    );
}

test "initFromKtxBytes rejects a bytesOfKeyValueData that runs past EOF" {
    var device: Device = undefined;
    // bytesOfKeyValueData much larger than what the buffer can hold, so
    // the mip-0 imageSize slot would land past the end of `bytes`.
    const bytes = buildKtxHeader(1, 1, 1024);
    try std.testing.expectError(
        error.InvalidKtx,
        initFromKtxBytes(&device, bytes[0..]),
    );
}

test "initFromKtxBytes rejects an imageSize that disagrees with pixelWidth*pixelHeight*4" {
    var device: Device = undefined;
    // Header for a 2x2 RGBA8 image (expected imageSize = 16 bytes), plus
    // 4 bytes for the imageSize field and 16 bytes of pixel data.
    var buf: [64 + 4 + 16]u8 = @splat(0);
    const header = buildKtxHeader(2, 2, 0);
    @memcpy(buf[0..64], &header);
    // Write a wrong imageSize (8 instead of 16).
    std.mem.writeInt(u32, buf[64..68], 8, .little);
    try std.testing.expectError(
        error.InvalidKtx,
        initFromKtxBytes(&device, buf[0..]),
    );
}

test "initFromKtxBytes rejects when declared imageSize extends past the buffer" {
    var device: Device = undefined;
    // Header for a 2x2 RGBA8 image but the buffer only carries 8 bytes
    // of pixel data instead of the required 16.
    var buf: [64 + 4 + 8]u8 = @splat(0);
    const header = buildKtxHeader(2, 2, 0);
    @memcpy(buf[0..64], &header);
    // imageSize = 16 matches width*height*4 so the equality check
    // passes, but the slice [pixels_start..pixels_end] would overrun
    // the buffer.
    std.mem.writeInt(u32, buf[64..68], 16, .little);
    try std.testing.expectError(
        error.InvalidKtx,
        initFromKtxBytes(&device, buf[0..]),
    );
}

test "initFromKtxBytes rejects bytesOfKeyValueData causing usize overflow" {
    var device: Device = undefined;
    // Set bytesOfKeyValueData to its max value so
    // `@sizeOf(Header) + kv_len` overflows usize on every platform and
    // the `std.math.add` catch path returns InvalidKtx.
    const bytes = buildKtxHeader(1, 1, std.math.maxInt(u32));
    try std.testing.expectError(
        error.InvalidKtx,
        initFromKtxBytes(&device, bytes[0..]),
    );
}
