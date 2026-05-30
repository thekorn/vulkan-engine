// C-ABI wrapper around the C++ tinyobjloader library.
//
// The public tinyobjloader API is C++ (std::vector, std::string, ...)
// so it can't be consumed directly from Zig via `@cImport`. This header
// exposes a tiny C interface that lets Zig pass a chunk of OBJ bytes
// in and receive flat arrays of interleaved vertices and 32-bit
// indices back. The wrapper performs the same per-vertex
// deduplication as the C++ tutorial code (mirroring the
// `unordered_map<Vertex, uint32_t>` loop in `lve_model.cpp`).

#ifndef TINYOBJ_WRAPPER_H
#define TINYOBJ_WRAPPER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Interleaved vertex layout matching `Model.Vertex` field-by-field
/// (position, color, normal, uv). The Zig-side `Vertex` may have
/// different alignment/padding due to SIMD vector types, so callers
/// copy field-by-field rather than block-memcpy.
typedef struct tinyobj_wrapper_vertex {
    float position[3];
    float color[3];
    float normal[3];
    float uv[2];
} tinyobj_wrapper_vertex;

/// Parse OBJ data from a memory buffer and return interleaved vertex
/// + 32-bit index arrays. On success returns 1 and fills out the
/// vertex / index pointers (allocated with `malloc`; free them via
/// `tinyobj_free`). On failure returns 0 and, if `out_error` is not
/// NULL, sets `*out_error` to a malloc-allocated NUL-terminated error
/// message that the caller must free with `tinyobj_free`.
///
/// The parser triangulates polygonal faces and deduplicates exactly-
/// matching vertices (same position, color, normal and uv).
int tinyobj_load_bytes(
    const char *obj_bytes,
    size_t obj_len,
    tinyobj_wrapper_vertex **out_vertices,
    size_t *out_vertices_count,
    uint32_t **out_indices,
    size_t *out_indices_count,
    char **out_error);

/// Free a pointer returned by `tinyobj_load_bytes`. Safe to call with
/// NULL.
void tinyobj_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif // TINYOBJ_WRAPPER_H
