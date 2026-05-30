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
