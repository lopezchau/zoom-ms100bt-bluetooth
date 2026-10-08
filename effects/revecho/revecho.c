/*
 * RevEcho — reverse echo for the ZOOM MS-100BT (and other ZDL MultiStomps).
 *
 * The input is recorded into a ring buffer. Two read heads play the most recent
 * `Time` of audio backwards, each shaped by a triangular window and offset by half
 * a segment, so their sum is a continuous, click-free reversed stream. The reversed
 * signal is fed back (darkened by a one-pole low-pass) into the recording, so each
 * repeat is reversed again and gets darker.
 *
 * Knobs: Time (0.1 s up to 1.4 s, limited to half the memory the pedal provides), Feedback (0–90 %), Tone (dark–bright), Mix (wet level).
 * The dry signal always passes at unity; Mix adds the echoes on top.
 */
#include "../common/zdl_fx.h"

#ifndef REVECHO_AUDIO_FUNC
#define REVECHO_AUDIO_FUNC Fx_DLY_RevEcho
#endif

#define RE_MAGIC     0x52455631u   /* 'REV1' */
#define RE_MAX_LEN   131072u       /* up to 2.97 s of mono float (512 KB) if the arena allows */
#define RE_MIN_SEG   4410.0f       /* 0.1 s */
#define RE_MAX_SEG   61740.0f      /* 1.4 s */
#define RE_CLEAR_STEP 4096u

#define SLOT_TIME     5
#define SLOT_FEEDBACK 6
#define SLOT_TONE     7
#define SLOT_MIX      8

typedef struct {
    uint32_t magic;
    uint32_t cleared;      /* samples zeroed so far (lazy clear, a chunk per call) */
    uint32_t mask;         /* buffer length - 1 (power of two that fits the arena) */
    uint32_t wp;           /* write position */
    float    segLen;       /* current segment length in samples */
    float    posA, posB;   /* position of each head inside its segment */
    float    lenA, lenB;   /* segment length each head started with */
    float    invA, invB;   /* 1 / segment length */
    uint32_t anchorA, anchorB;  /* write position when each head's segment began */
    float    lp;           /* tone low-pass state */
    float    timeSmooth;   /* smoothed Time knob */
} RevEchoState;

ZDL_AUDIO_FUNCTION(REVECHO_AUDIO_FUNC)
void REVECHO_AUDIO_FUNC(zdl_word *ctx)
{
    ZDL_BEGIN(ctx);
    if (params[0] < 0.5f) return;
    ZDL_ARENA(ctx);

    RevEchoState *st = (RevEchoState *)arenaBase;
    uintptr_t bufBase = (arenaBase + sizeof(RevEchoState) + 7u) & ~(uintptr_t)7u;
    if (bufBase >= arenaEnd) return;
    float *buf = (float *)bufBase;

    if (st->magic != RE_MAGIC) {
        /* Largest power-of-two buffer that fits, at most RE_MAX_LEN, at least 0.4 s. */
        uint32_t avail = (uint32_t)((arenaEnd - bufBase) >> 2);
        uint32_t len = RE_MAX_LEN;
        while (len > avail && len > 16384u) len >>= 1;
        if (len > avail) return;
        st->magic = RE_MAGIC;
        st->cleared = 0u;
        st->mask = len - 1u;
        st->wp = 0u;
        st->segLen = 22050.0f;
        st->posA = 0.0f;
        st->lenA = 22050.0f;
        st->invA = zdl_recip(22050.0f);
        st->anchorA = 0u;
        st->posB = 11025.0f;
        st->lenB = 22050.0f;
        st->invB = st->invA;
        st->anchorB = 0u;
        st->lp = 0.0f;
        st->timeSmooth = 0.5f;
    }

    uint32_t mask = st->mask;
    if (st->cleared <= mask) {
        uint32_t e = st->cleared + RE_CLEAR_STEP;
        if (e > mask + 1u) e = mask + 1u;
        uint32_t i;
        for (i = st->cleared; i < e; i++) buf[i] = 0.0f;
        st->cleared = e;
        return;   /* dry while the buffer is being cleared */
    }

    float time = zdl_knob(params[SLOT_TIME], 0.5f);
    float feedback = 0.9f * zdl_knob(params[SLOT_FEEDBACK], 0.4f);
    float tone = zdl_knob(params[SLOT_TONE], 0.6f);
    float mix = zdl_knob(params[SLOT_MIX], 0.5f);

    /* Knob → segment length. A segment must not exceed half the buffer, otherwise the
     * writer overtakes the region a head is still reading (0.74 s with 256 KB). */
    st->timeSmooth += 0.05f * (time - st->timeSmooth);
    float maxSeg = (float)((mask + 1u) >> 1) - 64.0f;
    if (maxSeg > RE_MAX_SEG) maxSeg = RE_MAX_SEG;
    float seg = RE_MIN_SEG + (maxSeg - RE_MIN_SEG) * st->timeSmooth;
    float lpCoef = 0.04f + 0.9f * tone * tone;

    uint32_t wp = st->wp;
    float posA = st->posA, posB = st->posB;
    float lenA = st->lenA, lenB = st->lenB;
    float invA = st->invA, invB = st->invB;
    uint32_t anchorA = st->anchorA, anchorB = st->anchorB;
    float lp = st->lp;

    int i;
    for (i = 0; i < 8; i++) {
        float inL = fx[i];
        float inR = fx[i + 8];
        float in = 0.5f * (inL + inR);

        /* Each head reads backwards from its anchor; a triangle window fades it in and out. */
        uint32_t ia = (anchorA - 1u - (uint32_t)(int32_t)posA) & mask;
        uint32_t ib = (anchorB - 1u - (uint32_t)(int32_t)posB) & mask;
        float ta = posA * invA;
        float tb = posB * invB;
        float wa = 1.0f - (ta > 0.5f ? 2.0f * ta - 1.0f : 1.0f - 2.0f * ta);
        float wb = 1.0f - (tb > 0.5f ? 2.0f * tb - 1.0f : 1.0f - 2.0f * tb);
        float rev = buf[ia] * wa + buf[ib] * wb;

        lp += lpCoef * (rev - lp);
        buf[wp] = in + feedback * zdl_softclip(lp);
        wp = (wp + 1u) & mask;

        posA += 1.0f;
        if (posA >= lenA) { posA = 0.0f; lenA = seg; invA = zdl_recip(seg); anchorA = wp; }
        posB += 1.0f;
        if (posB >= lenB) { posB = 0.0f; lenB = seg; invB = zdl_recip(seg); anchorB = wp; }

        float wet = mix * lp;
        fx[i] = inL + wet;
        fx[i + 8] = inR + wet;
    }

    st->wp = wp;
    st->posA = posA; st->posB = posB;
    st->lenA = lenA; st->lenB = lenB;
    st->invA = invA; st->invB = invB;
    st->anchorA = anchorA; st->anchorB = anchorB;
    st->lp = lp;
}
