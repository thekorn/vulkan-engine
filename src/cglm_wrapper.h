#ifndef CGLM_WRAPPER_H
#define CGLM_WRAPPER_H

/*
 * Workaround for Zig 0.16's arocc-based @cImport which does not parse
 * the single-underscore GCC form `__attribute((aligned(X)))` that cglm
 * uses in `cglm/types.h`. Map it to the double-underscore form which
 * arocc understands.
 */
#ifndef __attribute
#define __attribute(x) __attribute__(x)
#endif

#include <cglm/cglm.h>

#endif /* CGLM_WRAPPER_H */
