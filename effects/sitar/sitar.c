/*
 * Sitar — makes a guitar sound like a sitar on the ZOOM MS-100BT.
 *
 *  1. Jawari buzz: a sitar string grazes its curved bridge on one side of its swing.
 *     The input is high-passed, normalized by its own envelope (so the buzz lives through
 *     the whole note, not only the attack) and flattened asymmetrically on the negative side,
 *     plus a soft odd-harmonic rattle; then the envelope is restored.
 *  2. Twang: a resonant band-pass whose centre jumps up with each pick attack and falls as
 *     the note decays (the nasal "dwang").
 *  3. Taraf: 11 sympathetic strings (filtered comb resonators) tuned to a raga in the chosen
 *     key, excited by the buzzing signal; odd strings left, even strings right.
 *
 * Knobs: Buzz, Twang, Strings, Decay, Key (0–11 = C–B), Raga (0 Bilawal, 1 Kafi, 2 Bhairav), Mix.
 */
#include "../common/zdl_fx.h"

#ifndef SITAR_AUDIO_FUNC
#define SITAR_AUDIO_FUNC Fx_SFX_Sitar
#endif

#define ST_MAGIC     0x53495431u   /* 'SIT1' */
#define ST_STRINGS   11
#define ST_LINE      512u          /* samples per string line (≥ 44100 / 130.8 Hz) */
#define ST_LINE_MASK (ST_LINE - 1u)

#define SLOT_BUZZ    5
#define SLOT_TWANG   6
#define SLOT_STRINGS 7
#define SLOT_DECAY   8
#define SLOT_KEY     9
#define SLOT_RAGA    10
#define SLOT_MIX     11

typedef struct {
    uint32_t magic;
    uint32_t cleared;
    int32_t  key, raga;          /* tuning the strings were last computed for */
    uint32_t wp;                 /* shared write position of all string lines */
    float    delay[ST_STRINGS];  /* string period in samples */
    float    damp[ST_STRINGS];   /* loop low-pass state per string */
    float    lowLp;              /* high-pass helper for the buzz input */
    float    env, envFast;       /* envelopes */
    float    svLow, svBand;      /* twang state-variable filter */
    float    zingLp;             /* brightness high-pass helper */
} SitarState;

/* Semitones above Sa of sympathetic string i (0..10) for a raga. No tables (they would land in
 * .const, which the audio code must not read), so it is a chain of comparisons. */
ZDL_ALWAYS_INLINE(st_semitones)
static inline int st_semitones(int i, int raga)
{
    int s = 0;                                   /* Bilawal (major): Sa Re Ga Ma Pa Dha Ni Sa' Re' Ga' Pa' */
    if (i == 1) s = 2;
    if (i == 2) s = 4;
    if (i == 3) s = 5;
    if (i == 4) s = 7;
    if (i == 5) s = 9;
    if (i == 6) s = 11;
    if (i == 7) s = 12;
    if (i == 8) s = 14;
    if (i == 9) s = 16;
    if (i == 10) s = 19;
    if (raga == 1) {                             /* Kafi: komal Ga and Ni */
        if (i == 2) s = 3;
        if (i == 6) s = 10;
        if (i == 9) s = 15;
    }
    if (raga == 2) {                             /* Bhairav: komal Re and Dha */
        if (i == 1) s = 1;
        if (i == 5) s = 8;
        if (i == 8) s = 13;
    }
    return s;
}

ZDL_AUDIO_FUNCTION(SITAR_AUDIO_FUNC)
void SITAR_AUDIO_FUNC(zdl_word *ctx)
{
    ZDL_BEGIN(ctx);
    if (params[0] < 0.5f) return;
    ZDL_ARENA(ctx);

    SitarState *st = (SitarState *)arenaBase;
    uintptr_t linesBase = (arenaBase + sizeof(SitarState) + 7u) & ~(uintptr_t)7u;
    if (linesBase + (uintptr_t)(ST_STRINGS * ST_LINE) * 4u > arenaEnd) return;
    float *lines = (float *)linesBase;

    int s;
    if (st->magic != ST_MAGIC) {
        st->magic = ST_MAGIC;
        st->cleared = 0u;
        st->key = -1;
        st->raga = -1;
        st->wp = 0u;
        for (s = 0; s < ST_STRINGS; s++) { st->damp[s] = 0.0f; st->delay[s] = 200.0f; }
        st->lowLp = 0.0f;
        st->env = 0.0f;
        st->envFast = 0.0f;
        st->svLow = 0.0f;
        st->svBand = 0.0f;
        st->zingLp = 0.0f;
    }
    if (st->cleared < (uint32_t)(ST_STRINGS * ST_LINE)) {
        uint32_t e = st->cleared + 2048u;
        if (e > (uint32_t)(ST_STRINGS * ST_LINE)) e = (uint32_t)(ST_STRINGS * ST_LINE);
        uint32_t i;
        for (i = st->cleared; i < e; i++) lines[i] = 0.0f;
        st->cleared = e;
        return;
    }

    float buzz = zdl_knob(params[SLOT_BUZZ], 0.6f);
    float twang = zdl_knob(params[SLOT_TWANG], 0.5f);
    float strings = zdl_knob(params[SLOT_STRINGS], 0.5f);
    float decay = zdl_knob(params[SLOT_DECAY], 0.6f);
    /* Key and Raga are small integer knobs: the pedal delivers value / 100. */
    int key = (int)(zdl_knob(params[SLOT_KEY], 0.0f) * 100.0f + 0.5f);
    int raga = (int)(zdl_knob(params[SLOT_RAGA], 0.0f) * 100.0f + 0.5f);
    float mix = zdl_knob(params[SLOT_MIX], 0.8f);
    if (key > 11) key = 11;
    if (raga > 2) raga = 2;

    /* Retune the strings only when Key or Raga changes. Sa is in the C4–B4 octave. */
    if (key != st->key || raga != st->raga) {
        float sa = 261.6256f;
        int k;
        for (k = 0; k < key; k++) sa *= 1.0594631f;
        for (s = 0; s < ST_STRINGS; s++) {
            float f = sa;
            int n = st_semitones(s, raga);
            for (k = 0; k < n; k++) f *= 1.0594631f;
            st->delay[s] = 44100.0f * zdl_recip(f);
        }
        st->key = key;
        st->raga = raga;
    }

    float feedback = 0.96f + 0.034f * decay;            /* string sustain (≤ 0.994; the halo limiter stops pile-up) */
    float loopLp = 0.3f + 0.4f * decay;                  /* brighter loop = longer shimmer */
    float drive = 1.0f + 4.0f * buzz;
    float thr = 0.7f - 0.5f * buzz;                      /* where the string meets the bridge */
    float trim = zdl_recip(1.0f + 2.0f * buzz + 0.6f * twang);   /* keep the level close to the dry guitar */

    uint32_t wp = st->wp;
    float lowLp = st->lowLp, env = st->env, envFast = st->envFast;
    float svLow = st->svLow, svBand = st->svBand, zingLp = st->zingLp;

    int i;
    for (i = 0; i < 8; i++) {
        float inL = fx[i];
        float inR = fx[i + 8];
        float in = 0.5f * (inL + inR);

        /* --- jawari buzz --- */
        lowLp += 0.02f * (in - lowLp);                   /* ~140 Hz */
        float hp = in - lowLp;
        float a = hp < 0.0f ? -hp : hp;
        env += (a > env ? 0.05f : 0.0004f) * (a - env);
        envFast += (a > envFast ? 0.3f : 0.002f) * (a - envFast);
        float xn = hp * drive * zdl_recip(env + 0.0005f);   /* level-independent swing */
        float graze = xn < -thr ? -thr + 0.12f * (xn + thr) : xn;   /* flattened on the bridge side */
        float rattle = zdl_softclip(0.5f * xn);
        float shaped = (0.6f * graze + 0.4f * rattle) * env * zdl_recip(drive);
        zingLp += 0.15f * (shaped - zingLp);             /* keep the 1 kHz+ zing */
        float zing = shaped - zingLp;
        float buzzed = hp * (1.0f - 0.4f * buzz) + buzz * (0.9f * shaped + 1.4f * zing);

        /* --- twang: resonant band-pass that follows each attack --- */
        float fc = 400.0f + 2600.0f * zdl_clamp(envFast * 12.0f, 0.0f, 1.0f) * twang;
        float f = 6.2831853f * fc * (1.0f / 44100.0f);   /* 2·sin(π fc/fs) ≈ 2π fc/fs below 3 kHz */
        float q = 0.35f;
        svLow += f * svBand;
        float svHigh = buzzed - svLow - q * svBand;
        svBand += f * svHigh;
        float voice = (buzzed + twang * svBand) * trim;

        /* --- taraf: sympathetic strings --- */
        float exc = 0.2f * voice;
        float symL = 0.0f, symR = 0.0f;
        for (s = 0; s < ST_STRINGS; s++) {
            float *line = lines + s * ST_LINE;
            float d = st->delay[s];
            int di = (int)d;
            float fr = d - (float)di;
            uint32_t r0 = (wp - (uint32_t)di) & ST_LINE_MASK;
            uint32_t r1 = (r0 - 1u) & ST_LINE_MASK;
            float past = line[r0] + fr * (line[r1] - line[r0]);
            float dmp = st->damp[s] + loopLp * (past - st->damp[s]);
            st->damp[s] = dmp;
            line[wp] = exc + feedback * dmp;
            if (s & 1) symR += dmp; else symL += dmp;
        }
        wp = (wp + 1u) & ST_LINE_MASK;

        /* Soft limiter on the string halo: it can never swamp the played note. */
        float wetL = voice + strings * 0.6f * zdl_softclip(2.0f * symL);
        float wetR = voice + strings * 0.6f * zdl_softclip(2.0f * symR);
        fx[i] = inL + mix * (wetL - inL);
        fx[i + 8] = inR + mix * (wetR - inR);
    }

    st->wp = wp;
    st->lowLp = lowLp; st->env = env; st->envFast = envFast;
    st->svLow = svLow; st->svBand = svBand; st->zingLp = zingLp;
}
