/* Apple arm64/x86_64 encoder-only configuration. No decoder, assembler or SIMD
 * overrides: the portable upstream C encoder selects its own safe fallbacks. */
#ifndef SIMO_LAME_CONFIG_H
#define SIMO_LAME_CONFIG_H
/* Xcode Debug defines DEBUG for every C target. Upstream uses it for
 * per-MPEG-frame diagnostic logging; keep normal encoder diagnostics instead. */
#ifdef DEBUG
#undef DEBUG
#endif
#include <stdint.h>
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;
typedef long double ieee854_float80_t;
#define STDC_HEADERS 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_MEMCPY 1
#define HAVE_STRCHR 1
#define SIZEOF_SHORT __SIZEOF_SHORT__
#define SIZEOF_INT __SIZEOF_INT__
#define SIZEOF_LONG __SIZEOF_LONG__
#define SIZEOF_LONG_LONG __SIZEOF_LONG_LONG__
#define SIZEOF_FLOAT __SIZEOF_FLOAT__
#define SIZEOF_DOUBLE __SIZEOF_DOUBLE__
#define PACKAGE "lame"
#define VERSION "4.0"
#endif
