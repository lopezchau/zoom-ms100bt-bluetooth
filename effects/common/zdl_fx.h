/*
 * zdl_fx.h — write one C file that builds both as a ZOOM MultiStomp effect (TI C6000 DSP)
 * and as a host library for WAV previews on a Mac (define ZDL_HOST).
 *
 * Runtime contract (community research, see docs/CUSTOM-EFFECTS.md):
 *   ctx[1]  float *params   params[0] = on/off (1.0/0.0), params[5..] = knobs, normalized 0..1
 *   ctx[3]  arena descriptor: desc[0] = base, desc[1] = end of this instance's persistent memory
 *   ctx[5]  float *fx        16 floats per call: 8 left samples then 8 right samples (44.1 kHz).
 *                            Read the input from it and write the output back in place.
 *   ctx[11] / ctx[12]        "magic" words the firmware expects to be copied on every call.
 *
 * Rules that keep the DSP from freezing (from the community's SAFE-DSP-RULES):
 *   no division or modulo (use zdl_recip / power-of-two masks), no libm, no double,
 *   no switch, no static/const arrays used by the audio code, no malloc/.bss,
 *   every helper ALWAYS inlined, big state only in the arena, file ≤ 32 KB.
 */
#ifndef ZDL_FX_H
#define ZDL_FX_H

#include <stdint.h>

#ifdef ZDL_HOST
typedef uintptr_t zdl_word;
#define ZDL_AUDIO_FUNCTION(f)
#define ZDL_ALWAYS_INLINE(f)
#else
typedef unsigned int zdl_word;
#define ZDL_PRAGMA(x) _Pragma(#x)
#define ZDL_AUDIO_FUNCTION(f) ZDL_PRAGMA(CODE_SECTION(f, ".audio"))
#define ZDL_ALWAYS_INLINE(f) ZDL_PRAGMA(FUNC_ALWAYS_INLINE(f))
#endif

#define ZDL_PTR(type, w) ((type)(uintptr_t)(w))

/* Entry boilerplate: binds `params` and `fx`, performs the magic copy. */
#define ZDL_BEGIN(ctx)                                                              \
    float *params = ZDL_PTR(float *, (ctx)[1]);                                     \
    float *fx = ZDL_PTR(float *, (ctx)[5]);                                         \
    do {                                                                            \
        zdl_word *magicSrc_ = ZDL_PTR(zdl_word *, (ctx)[12]);                       \
        zdl_word *magicDst_ = ZDL_PTR(zdl_word *, *ZDL_PTR(zdl_word *, (ctx)[11])); \
        *magicDst_ = *magicSrc_;                                                    \
    } while (0)

/* Binds `arenaBase` / `arenaEnd` (uintptr_t) to this instance's memory, or returns (dry). */
#define ZDL_ARENA(ctx)                                                              \
    volatile zdl_word *desc_ = ZDL_PTR(volatile zdl_word *, (ctx)[3]);               \
    if (!desc_) return;                                                             \
    uintptr_t arenaBase = (uintptr_t)desc_[0];                                      \
    uintptr_t arenaEnd = (uintptr_t)desc_[1];                                       \
    if (arenaBase == 0u || arenaEnd <= arenaBase || (arenaBase & 3u) != 0u) return

ZDL_ALWAYS_INLINE(zdl_clamp)
static inline float zdl_clamp(float x, float lo, float hi)
{
    if (!(x >= lo)) return lo;   /* also catches NaN */
    if (x > hi) return hi;
    return x;
}

/* Knob value as 0..1. Shared handlers deliver 0..1; some paths deliver 0..100. */
ZDL_ALWAYS_INLINE(zdl_knob)
static inline float zdl_knob(float raw, float fallback)
{
    if (!(raw >= 0.0f && raw <= 100.0f)) return zdl_clamp(fallback, 0.0f, 1.0f);
    if (raw <= 1.0f) return raw;
    return zdl_clamp(raw * 0.01f, 0.0f, 1.0f);
}

/* 1/x for x > 0 without a divide instruction (bit trick + 3 Newton steps, ~1e-7 relative). */
ZDL_ALWAYS_INLINE(zdl_recip)
static inline float zdl_recip(float x)
{
    union { float f; uint32_t u; } v;
    v.f = x;
    v.u = 0x7EF311C7u - v.u;
    float r = v.f;
    r = r * (2.0f - x * r);
    r = r * (2.0f - x * r);
    r = r * (2.0f - x * r);
    return r;
}

/* Smooth saturation for feedback loops: cubic soft clip, |output| ≤ 2/3 · limit. */
ZDL_ALWAYS_INLINE(zdl_softclip)
static inline float zdl_softclip(float x)
{
    x = zdl_clamp(x, -1.0f, 1.0f);
    return x - 0.33333333f * x * x * x;
}

/* xorshift32 random numbers. */
ZDL_ALWAYS_INLINE(zdl_rand)
static inline uint32_t zdl_rand(uint32_t *s)
{
    uint32_t x = *s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *s = x;
    return x;
}

#endif
