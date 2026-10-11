/*
 * MemProbe — tells you, by ear, how much persistent memory (ctx[3] arena) the pedal gives
 * one effect instance. Turn it on and count:
 *   long low beeps (440 Hz, 0.4 s)  = hundreds of KB
 *   short high beeps (880 Hz, 0.12 s) = tens of KB
 * then a 2 s pause, and the pattern repeats. Example: 2 long + 5 short = 250–259 KB.
 * A single very long low tone means the arena is missing.  Dry signal passes unchanged.
 */
#include "../common/zdl_fx.h"

#ifndef MEMPROBE_AUDIO_FUNC
#define MEMPROBE_AUDIO_FUNC Fx_DLY_MemProbe
#endif

ZDL_AUDIO_FUNCTION(MEMPROBE_AUDIO_FUNC)
void MEMPROBE_AUDIO_FUNC(zdl_word *ctx)
{
    ZDL_BEGIN(ctx);
    if (params[0] < 0.5f) return;

    /* State lives in the first bytes of the arena; without an arena we cannot keep a clock. */
    volatile zdl_word *desc = ZDL_PTR(volatile zdl_word *, ctx[3]);
    uintptr_t base = desc ? (uintptr_t)desc[0] : 0u;
    uintptr_t end = desc ? (uintptr_t)desc[1] : 0u;
    if (base == 0u || end <= base || (base & 3u) != 0u) return;

    uint32_t *st = (uint32_t *)base;      /* st[0] magic, st[1] sample clock, st[2] hundreds, st[3] tens */
    float *ph = (float *)(base + 16u);   /* oscillator phase */
    if (st[0] != 0x4D454D31u) {
        uint32_t kb = (uint32_t)((end - base) >> 10);
        uint32_t h = 0u;
        while (kb >= 100u) { kb -= 100u; h++; }
        uint32_t t = 0u;
        while (kb >= 10u) { kb -= 10u; t++; }
        st[0] = 0x4D454D31u; st[1] = 0u; st[2] = h; st[3] = t; *ph = 0.0f;
    }
    uint32_t hundreds = st[2], tens = st[3];
    uint32_t clock = st[1];
    float phase = *ph;

    /* Timeline in samples: each long beep slot 0.7 s (0.4 on), each short slot 0.3 s (0.12 on),
     * a 1 s gap between the groups and 2 s at the end. */
    uint32_t longSlot = 30870u, longOn = 17640u, shortSlot = 13230u, shortOn = 5292u;
    uint32_t partA = hundreds * longSlot;
    uint32_t gap = 44100u;
    uint32_t partB = tens * shortSlot;
    uint32_t cycle = partA + gap + partB + 88200u;

    int i;
    for (i = 0; i < 8; i++) {
        uint32_t c = clock;
        float freq = 0.0f;
        if (c < partA) {
            uint32_t k = c;
            while (k >= longSlot) k -= longSlot;
            if (k < longOn) freq = 440.0f;
        } else if (c >= partA + gap && c < partA + gap + partB) {
            uint32_t k = c - partA - gap;
            while (k >= shortSlot) k -= shortSlot;
            if (k < shortOn) freq = 880.0f;
        }
        float tone = 0.0f;
        if (freq > 0.0f) {
            phase += freq * (1.0f / 44100.0f);
            if (phase >= 1.0f) phase -= 1.0f;
            /* triangle wave: no sin() needed */
            float tri = phase < 0.5f ? 4.0f * phase - 1.0f : 3.0f - 4.0f * phase;
            tone = 0.25f * tri;
        }
        fx[i] += tone;
        fx[i + 8] += tone;
        clock++;
        if (clock >= cycle) clock = 0u;
    }
    st[1] = clock;
    *ph = phase;
}
