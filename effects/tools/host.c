/* host.c — runs a ZDL effect compiled for the Mac (-DZDL_HOST) over a WAV file, the way the
 * DSP does: 8-sample blocks (LLLLLLLL RRRRRRRR), params[0] = 1, knobs in params[5..] as 0..1.
 * Usage: host IN.wav OUT.wav ARENA_BYTES TAIL_SECONDS knob1 knob2 … (0..100)
 *        Optional env STOMP="t1,t2,…": toggle the footswitch (params[0]) at those seconds.
 *        Optional env INPUT_GAIN (default 0.5 = −6 dB: test files are mastered hotter than a guitar in the pedal). */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

void EFFECT_ENTRY(uintptr_t *ctx);

static uint32_t rd32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static void wr32(FILE *f, uint32_t v) { fputc(v, f); fputc(v >> 8, f); fputc(v >> 16, f); fputc(v >> 24, f); }
static void wr16(FILE *f, uint32_t v) { fputc(v, f); fputc(v >> 8, f); }

int main(int argc, char **argv)
{
    if (argc < 5) { fprintf(stderr, "usage: host in.wav out.wav arena tail knobs…\n"); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *w = malloc(sz); fread(w, 1, sz, f); fclose(f);
    int ch = 0, bits = 0, rate = 0; unsigned char *data = 0; uint32_t dlen = 0;
    for (long o = 12; o + 8 <= sz;) {
        uint32_t len = rd32(w + o + 4);
        if (!memcmp(w + o, "fmt ", 4)) { ch = w[o + 10] | w[o + 11] << 8; rate = rd32(w + o + 12); bits = w[o + 22] | w[o + 23] << 8; }
        if (!memcmp(w + o, "data", 4)) { data = w + o + 8; dlen = len; }
        o += 8 + len + (len & 1);
    }
    if (!data || bits != 16 || rate != 44100 || ch < 1 || ch > 2) { fprintf(stderr, "need 16-bit 44.1 kHz WAV\n"); return 1; }
    long inFrames = dlen / (2 * ch);
    long frames = inFrames + (long)(atof(argv[4]) * 44100);
    frames = (frames + 7) / 8 * 8;
    float *out = calloc(frames * 2, sizeof(float));

    float inGain = getenv("INPUT_GAIN") ? (float)atof(getenv("INPUT_GAIN")) : 0.5f;   /* −6 dB headroom */
    float params[32] = {0};
    params[0] = 1.0f;
    for (int k = 5; k < argc && k - 5 < 20; k++) params[5 + (k - 5)] = (float)atof(argv[k]) * 0.01f;

    size_t arenaBytes = (size_t)atol(argv[3]);
    void *arena = calloc(1, arenaBytes);
    uintptr_t desc[3] = { (uintptr_t)arena, (uintptr_t)arena + arenaBytes, arenaBytes };
    uintptr_t magicSrc = 0x12345678u, magicDstWord = 0, magicDstPtr = (uintptr_t)&magicDstWord;
    float block[16];
    uintptr_t ctx[16] = {0};
    ctx[1] = (uintptr_t)params; ctx[3] = (uintptr_t)desc; ctx[5] = (uintptr_t)block;
    ctx[11] = (uintptr_t)&magicDstPtr; ctx[12] = (uintptr_t)&magicSrc;

    /* Optional footswitch events. */
    double stomps[64]; int nStomp = 0, nextStomp = 0;
    const char *s = getenv("STOMP");
    while (s && *s && nStomp < 64) { stomps[nStomp++] = atof(s); s = strchr(s, ','); if (s) s++; }

    /* Warm-up: silent blocks so lazy buffer clearing finishes, like a pedal idling before you play. */
    for (int i = 0; i < 4096; i++) { memset(block, 0, sizeof block); EFFECT_ENTRY(ctx); }

    double peak = 0; long bad = 0;
    for (long i = 0; i < frames; i += 8) {
        while (nextStomp < nStomp && i >= (long)(stomps[nextStomp] * 44100)) { params[0] = params[0] > 0.5f ? 0.0f : 1.0f; nextStomp++; }
        for (int k = 0; k < 8; k++) {
            long fr = i + k; float l = 0, r = 0;
            if (fr < inFrames) {
                int16_t *p = (int16_t *)(data + fr * 2 * ch);
                l = inGain * p[0] / 32768.0f; r = ch == 2 ? inGain * p[1] / 32768.0f : l;
            }
            block[k] = l; block[k + 8] = r;
        }
        EFFECT_ENTRY(ctx);
        if (magicDstWord != magicSrc) { fprintf(stderr, "magic words were not copied\n"); return 1; }
        for (int k = 0; k < 8; k++) {
            float l = block[k], r = block[k + 8];
            if (!isfinite(l) || !isfinite(r)) { bad++; l = r = 0; }
            if (fabs(l) > peak) peak = fabs(l);
            if (fabs(r) > peak) peak = fabs(r);
            out[2 * (i + k)] = l; out[2 * (i + k) + 1] = r;
        }
    }
    /* 24-bit output; scaled down only if it would clip. */
    double gain = peak > 0.99 ? 0.99 / peak : 1.0;
    FILE *o = fopen(argv[2], "wb");
    uint32_t bytes = frames * 2 * 3;
    fwrite("RIFF", 1, 4, o); wr32(o, 36 + bytes); fwrite("WAVEfmt ", 1, 8, o);
    wr32(o, 16); wr16(o, 1); wr16(o, 2); wr32(o, 44100); wr32(o, 44100 * 6); wr16(o, 6); wr16(o, 24);
    fwrite("data", 1, 4, o); wr32(o, bytes);
    for (long i = 0; i < frames * 2; i++) {
        int32_t v = (int32_t)lrint(out[i] * gain * 8388607.0);
        fputc(v, o); fputc(v >> 8, o); fputc(v >> 16, o);
    }
    fclose(o);
    printf("peak %.3f%s, non-finite samples %ld\n", peak, peak > 0.99 ? " (output scaled down)" : "", bad);
    return bad ? 3 : 0;
}
