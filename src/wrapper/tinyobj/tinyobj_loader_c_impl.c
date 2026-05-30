/* Compiles the tinyobjloader-c implementation into a single
 * translation unit. The header (vendored via build.zig.zon from
 * https://github.com/syoyo/tinyobjloader-c) is "stb-style"
 * header-only: exactly one .c file must define
 * `TINYOBJ_LOADER_C_IMPLEMENTATION` before including it. The build
 * system (`build.zig`) wires up the include path for this dependency.
 */
#define TINYOBJ_LOADER_C_IMPLEMENTATION
#include "tinyobj_loader_c.h"
