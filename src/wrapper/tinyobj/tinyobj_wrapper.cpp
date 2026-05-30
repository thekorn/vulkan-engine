// C-ABI wrapper around tinyobjloader. See tinyobj_wrapper.h for the
// public interface. The body mirrors the loop in `lve_model.cpp` from
// the upstream Little Vulkan Engine tutorial:
//
//   https://github.com/blurrypiano/littleVulkanEngine/blob/master/littleVulkanEngine/tutorial/lve_model.cpp

#include "tinyobj_wrapper.h"

// Compile the tinyobjloader implementation into this wrapper translation
// unit. On Linux/Nix the packaged tinyobjloader archive is built with
// libstdc++ while the Zig C++ frontend uses libc++; linking against the
// archive directly can therefore fail with C++ standard-library ABI
// mismatches. Keeping the C++ implementation behind this C-ABI wrapper
// avoids exposing or linking those C++ symbols across library boundaries.
#define TINYOBJLOADER_IMPLEMENTATION
#include <tiny_obj_loader.h>

#include <cstdlib>
#include <cstring>
#include <functional>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

// Mirrors `lve::hashCombine` from the upstream tutorial.
template <typename T>
inline void hash_combine(std::size_t &seed, const T &v) {
    std::hash<T> hasher;
    seed ^= hasher(v) + 0x9e3779b9 + (seed << 6) + (seed >> 2);
}

struct VertexHash {
    std::size_t operator()(const tinyobj_wrapper_vertex &v) const noexcept {
        std::size_t seed = 0;
        for (int i = 0; i < 3; ++i) hash_combine(seed, v.position[i]);
        for (int i = 0; i < 3; ++i) hash_combine(seed, v.color[i]);
        for (int i = 0; i < 3; ++i) hash_combine(seed, v.normal[i]);
        for (int i = 0; i < 2; ++i) hash_combine(seed, v.uv[i]);
        return seed;
    }
};

struct VertexEq {
    bool operator()(const tinyobj_wrapper_vertex &a,
                    const tinyobj_wrapper_vertex &b) const noexcept {
        // Byte-wise equality is safe because we zero-initialize
        // vertices before populating them and the struct has no
        // padding (4-byte floats only).
        return std::memcmp(&a, &b, sizeof(tinyobj_wrapper_vertex)) == 0;
    }
};

// Like POSIX `strdup`, but uses `malloc` so the caller can free the
// result via `std::free` (and thus via `tinyobj_free`).
char *dup_cstr(const std::string &s) {
    char *out = static_cast<char *>(std::malloc(s.size() + 1));
    if (!out) return nullptr;
    std::memcpy(out, s.data(), s.size());
    out[s.size()] = '\0';
    return out;
}

}  // namespace

extern "C" int tinyobj_load_bytes(
    const char *obj_bytes,
    size_t obj_len,
    tinyobj_wrapper_vertex **out_vertices,
    size_t *out_vertices_count,
    uint32_t **out_indices,
    size_t *out_indices_count,
    char **out_error) {
    if (out_vertices) *out_vertices = nullptr;
    if (out_vertices_count) *out_vertices_count = 0;
    if (out_indices) *out_indices = nullptr;
    if (out_indices_count) *out_indices_count = 0;
    if (out_error) *out_error = nullptr;

    tinyobj::attrib_t attrib;
    std::vector<tinyobj::shape_t> shapes;
    std::vector<tinyobj::material_t> materials;
    std::string warn;
    std::string err;

    // The tinyobjloader istream overload reads from any `std::istream`,
    // letting us parse straight out of an in-memory buffer (e.g. data
    // produced by the Zig `@embedFile` builtin) without touching the
    // filesystem.
    std::string input(obj_bytes, obj_len);
    std::istringstream in(input);

    bool ok = tinyobj::LoadObj(&attrib, &shapes, &materials, &warn, &err, &in);
    if (!ok) {
        if (out_error) {
            std::string msg = warn + err;
            *out_error = dup_cstr(msg);
        }
        return 0;
    }

    std::vector<tinyobj_wrapper_vertex> vertices;
    std::vector<uint32_t> indices;
    std::unordered_map<tinyobj_wrapper_vertex, uint32_t, VertexHash, VertexEq> unique_vertices;

    for (const auto &shape : shapes) {
        for (const auto &index : shape.mesh.indices) {
            tinyobj_wrapper_vertex vertex{};

            if (index.vertex_index >= 0) {
                vertex.position[0] = attrib.vertices[3 * index.vertex_index + 0];
                vertex.position[1] = attrib.vertices[3 * index.vertex_index + 1];
                vertex.position[2] = attrib.vertices[3 * index.vertex_index + 2];

                // tinyobjloader stores per-vertex colors in `attrib.colors`
                // (same indexing as `attrib.vertices`) when the OBJ file
                // uses the `v x y z r g b` form, otherwise defaults to
                // white.
                auto color_index = 3 * index.vertex_index + 2;
                if (color_index < static_cast<int>(attrib.colors.size())) {
                    vertex.color[0] = attrib.colors[color_index - 2];
                    vertex.color[1] = attrib.colors[color_index - 1];
                    vertex.color[2] = attrib.colors[color_index - 0];
                } else {
                    vertex.color[0] = 1.0f;
                    vertex.color[1] = 1.0f;
                    vertex.color[2] = 1.0f;
                }
            }

            if (index.normal_index >= 0) {
                vertex.normal[0] = attrib.normals[3 * index.normal_index + 0];
                vertex.normal[1] = attrib.normals[3 * index.normal_index + 1];
                vertex.normal[2] = attrib.normals[3 * index.normal_index + 2];
            }

            if (index.texcoord_index >= 0) {
                vertex.uv[0] = attrib.texcoords[2 * index.texcoord_index + 0];
                vertex.uv[1] = attrib.texcoords[2 * index.texcoord_index + 1];
            }

            auto it = unique_vertices.find(vertex);
            if (it == unique_vertices.end()) {
                uint32_t id = static_cast<uint32_t>(vertices.size());
                unique_vertices.emplace(vertex, id);
                vertices.push_back(vertex);
                indices.push_back(id);
            } else {
                indices.push_back(it->second);
            }
        }
    }

    const size_t vertices_bytes = vertices.size() * sizeof(tinyobj_wrapper_vertex);
    const size_t indices_bytes = indices.size() * sizeof(uint32_t);

    tinyobj_wrapper_vertex *vbuf = nullptr;
    uint32_t *ibuf = nullptr;
    if (vertices_bytes > 0) {
        vbuf = static_cast<tinyobj_wrapper_vertex *>(std::malloc(vertices_bytes));
        if (!vbuf) {
            if (out_error) *out_error = dup_cstr("tinyobj_wrapper: out of memory");
            return 0;
        }
        std::memcpy(vbuf, vertices.data(), vertices_bytes);
    }
    if (indices_bytes > 0) {
        ibuf = static_cast<uint32_t *>(std::malloc(indices_bytes));
        if (!ibuf) {
            std::free(vbuf);
            if (out_error) *out_error = dup_cstr("tinyobj_wrapper: out of memory");
            return 0;
        }
        std::memcpy(ibuf, indices.data(), indices_bytes);
    }

    if (out_vertices) *out_vertices = vbuf;
    if (out_vertices_count) *out_vertices_count = vertices.size();
    if (out_indices) *out_indices = ibuf;
    if (out_indices_count) *out_indices_count = indices.size();
    return 1;
}

extern "C" void tinyobj_free(void *ptr) {
    std::free(ptr);
}
