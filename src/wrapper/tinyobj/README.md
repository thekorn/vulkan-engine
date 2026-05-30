# `tinyobj_loader_c_impl` — single-TU compile of tinyobjloader-c

This directory exists to compile the
[tinyobjloader-c](https://github.com/syoyo/tinyobjloader-c) header-only
library into the executable.

`tinyobj_loader_c.h` is an stb-style single-header library: exactly one
translation unit must define `TINYOBJ_LOADER_C_IMPLEMENTATION` before
including the header so the parser implementation is emitted there.
[`tinyobj_loader_c_impl.c`](tinyobj_loader_c_impl.c) does exactly that
and nothing else.

The header itself is **not** vendored in this repository. It is fetched
from upstream via `build.zig.zon`:

```zig
.dependencies = .{
    .tinyobjloader_c = .{
        .url  = "https://github.com/syoyo/tinyobjloader-c/archive/<commit>.tar.gz",
        .hash = "...",
    },
},
```

and `build.zig` adds the dependency's root as an include path so this
`.c` file can resolve `#include "tinyobj_loader_c.h"`. The Zig side
(`src/c.zig`) does the same — `@cInclude("tinyobj_loader_c.h")` —
which lets `Model.zig` call the library's C API directly without a
hand-written wrapper.

## Why no wrapper anymore?

The previous version of this engine used the C++
[`tinyobjloader`](https://github.com/tinyobjloader/tinyobjloader)
library through a hand-written `extern "C"` shim, because the Zig
`@cImport` builtin only translates C, not C++. tinyobjloader-c removes that
constraint entirely: it is a pure C99 library, so `@cImport` can read
its header directly. The "wrapper" here is therefore reduced to a
one-line stub that triggers the header's implementation block.

## TODO: collapse the `.c` stub into `src/c.zig`

The natural next step is to drop this `.c` file entirely and let
`@cImport` emit the implementation too, by moving the
`TINYOBJ_LOADER_C_IMPLEMENTATION` define into a dedicated `@cImport`
const in `src/c.zig`:

```zig
pub const tinyobj = @cImport({
    @cDefine("TINYOBJ_LOADER_C_IMPLEMENTATION", {});
    @cInclude("tinyobj_loader_c.h");
});
```

That removes the `addCSourceFile` wiring from `build.zig`, the
`src/wrapper/tinyobj/` directory and the manual `.c` translation unit,
leaving tinyobjloader-c as a pure header-on-include-path dependency.

**Currently blocked by a Zig 0.16 compiler bug.** When translate-c
processes the implementation it emits patterns like:

```zig
material.*.ambient[@as(usize, @intCast(i))] = 0.0;
command.*.f[@as(c_int, 0)] = f[@as(c_int, 0)];
```

…against `[*c]`-typed pointers, and the compiler then complains:

```
error: expected type '[3]f32', found 'comptime_float'
error: expected type '[16]T', found 'T'
```

i.e. for a `[*c]M` pointer `m`, the compiler treats `m.*.array_field[i]`
as the whole array instead of an element. Minimal repro outside
tinyobj:

```zig
const M = extern struct { ambient: [3]f32 = .{0,0,0} };
fn initM(m: [*c]M) callconv(.c) void {
    var i: c_int = 0;
    m.*.ambient[@as(usize, @intCast(i))] = 0.0;  // <- rejected
    _ = &i;
}
```

The exact same expression compiles on a regular `*M` pointer or a
local `M`. Until this is fixed upstream in Zig (or worked around by
post-processing the translate-c output), the parser implementation has
to live in this `.c` stub so it is compiled by the C frontend instead
of going through translate-c.
