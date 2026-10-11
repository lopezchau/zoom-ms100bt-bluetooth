/*
 * Sitar — makes a guitar sound like a sitar on the ZOOM MS-100BT.
 *
 *  1. Jawari. A sitar string vibrates against a wide curved bridge; the closer it swings to the
 *     bridge, the shorter its effective length. Physical models (Välimäki et al.) render this as a
 *     very short delay whose length is driven by the string's own displacement. Mixed with the
 *     direct signal it becomes a comb filter whose notches move inside every cycle and drift as the
 *     note decays: the sweeping "zing" of the sitar. The displacement is normalized by the note's
 *     envelope so the effect does not depend on how hard you pick, only on where the note is in its life.
 *  2. Twang. A resonant band-pass jumps up on each pick attack and glides down over ~200 ms.
 *  3. Taraf. 11 sympathetic strings (filtered comb resonators) tuned to a raga in the chosen key,
 *     excited by the jawari voice and passed through their own jawari; odd strings left, even right.
 *
 *  4. Detune. The voice wavers a few cents at 1–6 Hz, irregularly, as measured on a real sitar
 *     recording (≈ 6 cents at 2.3 Hz); left and right waver differently, so they also beat.
 *
 * Knobs: Buzz, Twang, Strings, Decay, Key (0–11 = C–B), Raga (0 Bilawal, 1 Kafi, 2 Bhairav), Detune, Mix.
 */
#include "../common/zdl_fx.h"

#ifndef SITAR_AUDIO_FUNC
#define SITAR_AUDIO_FUNC Fx_SFX_Sitar
#endif

#define ST_MAGIC     0x53495433u   /* 'SIT3' */
#define ST_STRINGS   11
#define ST_LINE      512u          /* samples per string line (≥ 44100 / 261.6 Hz with margin) */
#define ST_LINE_MASK (ST_LINE - 1u)
#define JW_LEN       128u          /* jawari delay lines (≤ 2.9 ms) */
#define JW_MASK      (JW_LEN - 1u)
#define DT_LEN       1024u         /* detune delay line (23 ms) */
#define DT_MASK      (DT_LEN - 1u)

#ifndef ST_HALO_GAIN
#define ST_HALO_GAIN 0.33f           /* halo ≈ −14 dB under the notes at Strings 50, like a real recording (Kiravani: −11…−17 dB) */
#endif

#define SLOT_BUZZ    5
#define SLOT_TWANG   6
#define SLOT_STRINGS 7
#define SLOT_DECAY   8
#define SLOT_KEY     9
#define SLOT_RAGA    10
#define SLOT_DETUNE  11
#define SLOT_MIX     12

typedef struct {
    uint32_t magic;
    uint32_t cleared;
    int32_t  key, raga;
    uint32_t wp;                 /* shared write position of the string lines */
    uint32_t jp;                 /* write position of the jawari lines */
    float    delay[ST_STRINGS];
    float    damp[ST_STRINGS];
    float    wgt[ST_STRINGS];    /* drone strings (Sa, Pa) ring louder, as in real recordings */
    float    lowLp;              /* removes the guitar's low end (sitars are thin) */
    float    env;                /* note envelope (normalizes the displacement) */
    float    twEnv;              /* twang envelope: instant attack, ~200 ms glide */
    float    peak;               /* recent attack peak, for the twang ratio */
    float    svLow, svBand;      /* twang filter */
    float    bodyLow, bodyBand;  /* fixed nasal resonance (~2.6 kHz) */
    float    exA, exB;           /* exciter high-pass states */
    float    lowLp2;             /* second high-pass stage */
    float    topA, topB;         /* gentle low-pass ~3 kHz (a sitar has little energy above 2 kHz) */
    float    excLp;              /* removes DC before it reaches the resonators */
    float    dcxL, dcyL, dcxR, dcyR;   /* output DC blockers */
    float    lfo1, lfo2, lfo3;   /* detune LFO phases (-1..1) */
    uint32_t dp;                 /* detune line write position */
    float    jawLead[JW_LEN];
    float    jawSym[JW_LEN];
} SitarState;

ZDL_ALWAYS_INLINE(st_semitones)
static inline int st_semitones(int i, int raga)
{
    int s = 0;                                   /* Bilawal: Sa Re Ga Ma Pa Dha Ni Sa' Re' Ga' Pa' */
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

/* Reads a delay line `d` samples (fractional) behind write position `w`. */
ZDL_ALWAYS_INLINE(st_tap)
static inline float st_tap(const float *line, uint32_t w, float d, uint32_t mask)
{
    int di = (int)d;
    float fr = d - (float)di;
    uint32_t r0 = (w - (uint32_t)di) & mask;
    uint32_t r1 = (r0 - 1u) & mask;
    return line[r0] + fr * (line[r1] - line[r0]);
}

ZDL_AUDIO_FUNCTION(SITAR_AUDIO_FUNC)
void SITAR_AUDIO_FUNC(zdl_word *ctx)
{
    ZDL_BEGIN(ctx);
    if (params[0] < 0.5f) return;
    ZDL_ARENA(ctx);

    SitarState *st = (SitarState *)arenaBase;
    uintptr_t linesBase = (arenaBase + sizeof(SitarState) + 7u) & ~(uintptr_t)7u;
    if (linesBase + (uintptr_t)(ST_STRINGS * ST_LINE + DT_LEN) * 4u > arenaEnd) return;
    float *lines = (float *)linesBase;
    float *dtLine = lines + ST_STRINGS * ST_LINE;

    int s;
    uint32_t n;
    if (st->magic != ST_MAGIC) {
        st->magic = ST_MAGIC;
        st->cleared = 0u;
        st->key = -1;
        st->raga = -1;
        st->wp = 0u;
        st->jp = 0u;
        for (s = 0; s < ST_STRINGS; s++) { st->damp[s] = 0.0f; st->delay[s] = 200.0f; st->wgt[s] = 0.35f; }
        for (n = 0; n < JW_LEN; n++) { st->jawLead[n] = 0.0f; st->jawSym[n] = 0.0f; }
        st->lowLp = 0.0f;
        st->env = 0.0f;
        st->twEnv = 0.0f;
        st->peak = 0.0f;
        st->svLow = 0.0f; st->svBand = 0.0f;
        st->bodyLow = 0.0f; st->bodyBand = 0.0f;
        st->exA = 0.0f; st->exB = 0.0f;
        st->lowLp2 = 0.0f; st->excLp = 0.0f; st->topA = 0.0f; st->topB = 0.0f;
        st->dcxL = 0.0f; st->dcyL = 0.0f; st->dcxR = 0.0f; st->dcyR = 0.0f;
        st->lfo1 = 0.0f; st->lfo2 = 0.5f; st->lfo3 = -0.3f; st->dp = 0u;
    }
    if (st->cleared < (uint32_t)(ST_STRINGS * ST_LINE + DT_LEN)) {
        uint32_t e = st->cleared + 2048u;
        if (e > (uint32_t)(ST_STRINGS * ST_LINE + DT_LEN)) e = (uint32_t)(ST_STRINGS * ST_LINE + DT_LEN);
        for (n = st->cleared; n < e; n++) lines[n] = 0.0f;
        st->cleared = e;
        return;
    }

    float buzz = zdl_knob(params[SLOT_BUZZ], 0.7f);
    float twang = zdl_knob(params[SLOT_TWANG], 0.5f);
    float strings = zdl_knob(params[SLOT_STRINGS], 0.5f);
    float decay = zdl_knob(params[SLOT_DECAY], 0.6f);
    int key = (int)(zdl_knob(params[SLOT_KEY], 0.0f) * 100.0f + 0.5f);
    int raga = (int)(zdl_knob(params[SLOT_RAGA], 0.0f) * 100.0f + 0.5f);
    float detune = zdl_knob(params[SLOT_DETUNE], 0.4f);
    float mix = zdl_knob(params[SLOT_MIX], 0.9f);
    if (key > 11) key = 11;
    if (raga > 2) raga = 2;

    if (key != st->key || raga != st->raga) {
        float sa = 261.6256f;
        int k;
        for (k = 0; k < key; k++) sa *= 1.0594631f;
        for (s = 0; s < ST_STRINGS; s++) {
            float f = sa;
            int m = st_semitones(s, raga);
            for (k = 0; k < m; k++) f *= 1.0594631f;
            st->delay[s] = 44100.0f * zdl_recip(f);
            /* Sa (0, 12) and Pa (7, 19) dominate the background of real recordings (Kiravani analysis). */
            st->wgt[s] = (m == 0 || m == 12) ? 1.0f : ((m == 7 || m == 19) ? 0.8f : 0.3f);
        }
        st->key = key;
        st->raga = raga;
    }

    float feedback = 0.96f + 0.034f * decay;
    float loopLp = 0.35f + 0.45f * decay;
    float jawDepth = 6.0f + 34.0f * buzz;          /* samples of length change at full bridge contact */
    float trim = zdl_recip(1.0f + 0.5f * buzz + 0.8f * twang);

    uint32_t wp = st->wp, jp = st->jp;
    float lowLp = st->lowLp, env = st->env, twEnv = st->twEnv, peak = st->peak;
    float svLow = st->svLow, svBand = st->svBand, bodyLow = st->bodyLow, bodyBand = st->bodyBand;
    float exA = st->exA, exB = st->exB;
    float lowLp2 = st->lowLp2, excLp = st->excLp, topA = st->topA, topB = st->topB;
    float dcxL = st->dcxL, dcyL = st->dcyL, dcxR = st->dcxR, dcyR = st->dcyR;
    float lfo1 = st->lfo1, lfo2 = st->lfo2, lfo3 = st->lfo3;
    uint32_t dp = st->dp;
    /* Measured on a real sitar recording: inside each note the pitch wavers ~6 cents (std, range
     * 0.6–24) at 1–6 Hz (median 2.3 Hz), irregularly. A delay swinging ±A samples at rate r shifts
     * pitch by up to A·2πr/fs, so ~16 samples ≈ 6 cents at Detune 40 and ~34 ≈ 13 cents at 100. */
    float dtDepth = 8.0f + 60.0f * detune;
    float dtBlend = zdl_clamp(2.5f * detune, 0.0f, 1.0f);   /* fully wavering from Detune ≈ 40 on */

    int i;
    for (i = 0; i < 8; i++) {
        float inL = fx[i];
        float inR = fx[i + 8];
        float in = 0.5f * (inL + inR);

        /* Thin the guitar: two-stage high-pass ~220 Hz (a sitar has almost nothing below 200 Hz). */
        lowLp += 0.031f * (in - lowLp);
        float hp1 = in - lowLp;
        lowLp2 += 0.031f * (hp1 - lowLp2);
        float str = hp1 - lowLp2;
        float a = str < 0.0f ? -str : str;
        env += (a > env ? 0.08f : 0.0006f) * (a - env);

        /* --- jawari: displacement-driven delay modulation --- */
        float disp = str * zdl_recip(env + 0.0003f);              /* ≈ −1.5 … 1.5 within each cycle */
        float contact = zdl_clamp(-disp, 0.0f, 1.5f);              /* only the bridge side grazes */
        st->jawLead[jp] = str;
        float jd = 1.5f + jawDepth * contact;
        float jaw = st_tap(st->jawLead, jp, jd, JW_MASK);
        float comb = 0.5f * (str + jaw);                           /* moving notches = the sweep */
        float zing = str - jaw;                                    /* the sizzle above them */
        float lead = (1.0f - buzz) * str + buzz * (comb + 0.9f * zing);

        /* --- twang: band-pass that jumps on the attack and glides down --- */
        peak += (a > peak ? 0.5f : 0.00002f) * (a - peak);
        twEnv += (a > twEnv ? 0.5f : 0.00012f) * (a - twEnv);     /* ~190 ms glide */
        float ratio = zdl_clamp(twEnv * zdl_recip(peak + 0.0003f), 0.0f, 1.0f);

        /* --- bridge exciter: the collision makes new high harmonics (rectified displacement,
         *     high-passed ~1.8 kHz twice). It blooms after the attack, as the decaying string
         *     falls into the bridge's contact zone. --- */
        float rect = disp < 0.0f ? -disp : disp;
        exA += 0.23f * (rect - exA);
        float exHp = rect - exA;
        exB += 0.23f * (exHp - exB);
        float bloom = 1.0f - 0.7f * ratio;
        lead += buzz * 2.2f * bloom * (exHp - exB) * env;
        float fc = 600.0f + 1800.0f * ratio * ratio;     /* 2.4 kHz → 600 Hz glide */
        float f = 6.2831853f * fc * (1.0f / 44100.0f);
        svLow += f * svBand;
        float svHigh = lead - svLow - 0.18f * svBand;
        svBand += f * svHigh;

        /* Nasal resonance of the gourd/bridge, ~1.3 kHz (the reference recording peaks at 0.85–1.5 kHz). */
        bodyLow += 0.185f * bodyBand;
        float bodyHigh = lead - bodyLow - 0.35f * bodyBand;
        bodyBand += 0.185f * bodyHigh;

        float raw = (lead + twang * 0.9f * svBand + 0.6f * bodyBand) * trim;
        topA += 0.35f * (raw - topA);                  /* two one-pole stages ≈ 3 kHz, 12 dB/oct */
        topB += 0.35f * (topA - topB);
        float voice = topB;

        /* --- detune: two slowly drifting copies (modulated delays), left and right --- */
        dtLine[dp] = voice;
        lfo1 += 1.7f * 2.0f / 44100.0f; if (lfo1 >= 1.0f) lfo1 -= 2.0f;
        lfo2 += 2.9f * 2.0f / 44100.0f; if (lfo2 >= 1.0f) lfo2 -= 2.0f;
        lfo3 += 0.6f * 2.0f / 44100.0f; if (lfo3 >= 1.0f) lfo3 -= 2.0f;
        float s1 = 4.0f * lfo1 * (1.0f - (lfo1 < 0.0f ? -lfo1 : lfo1));   /* parabolic sines */
        float s2 = 4.0f * lfo2 * (1.0f - (lfo2 < 0.0f ? -lfo2 : lfo2));
        float s3 = 4.0f * lfo3 * (1.0f - (lfo3 < 0.0f ? -lfo3 : lfo3));
        /* Irregular wander: two rates plus a slow common drift, never repeating exactly. */
        float d1 = 80.0f + dtDepth * (0.65f * s1 + 0.35f * s3);
        float d2 = 80.0f + dtDepth * (0.65f * s2 - 0.35f * s3);
        float v1 = st_tap(dtLine, dp, d1, DT_MASK);
        float v2 = st_tap(dtLine, dp, d2, DT_MASK);
        dp = (dp + 1u) & DT_MASK;
        /* The voice itself drifts (not just copies under it); the two drifts beat against each other. */
        float drift = 0.5f * (v1 + v2);
        float detL = voice + dtBlend * (0.75f * v1 + 0.25f * drift - voice);
        float detR = voice + dtBlend * (0.75f * v2 + 0.25f * drift - voice);

        /* --- taraf: sympathetic strings, with their own jawari --- */
        excLp += 0.003f * (voice - excLp);              /* DC blocker (~20 Hz): resonators amplify DC ×50 */
        float exc = 0.08f * (voice - excLp);
        float symL = 0.0f, symR = 0.0f;
        for (s = 0; s < ST_STRINGS; s++) {
            float *line = lines + s * ST_LINE;
            float past = st_tap(line, wp, st->delay[s], ST_LINE_MASK);
            float dmp = st->damp[s] + loopLp * (past - st->damp[s]);
            st->damp[s] = dmp;
            float w = st->wgt[s];
            line[wp] = exc * w + (feedback + (1.0f - feedback) * 0.4f * w) * dmp;   /* drones ring longer */
            if (s & 1) symR += w * dmp; else symL += w * dmp;
        }
        wp = (wp + 1u) & ST_LINE_MASK;
        float sym = symL + symR;
        st->jawSym[jp] = sym;
        float symContact = zdl_clamp(-sym * 8.0f, 0.0f, 1.0f);
        float symJaw = st_tap(st->jawSym, jp, 1.5f + 20.0f * symContact, JW_MASK);
        float shimmer = 0.5f * (sym + symJaw) + 0.6f * (sym - symJaw);
        jp = (jp + 1u) & JW_MASK;

        float spreadL = ST_HALO_GAIN * zdl_softclip(2.0f * (0.7f * shimmer + 0.6f * symL));
        float spreadR = ST_HALO_GAIN * zdl_softclip(2.0f * (0.7f * shimmer + 0.6f * symR));
        float wetL = detL + strings * spreadL;
        float wetR = detR + strings * spreadR;
        /* Output DC blockers (y = x − x₁ + 0.995·y₁). */
        float yL = wetL - dcxL + 0.995f * dcyL; dcxL = wetL; dcyL = yL; wetL = yL;
        float yR = wetR - dcxR + 0.995f * dcyR; dcxR = wetR; dcyR = yR; wetR = yR;
        fx[i] = inL + mix * (wetL - inL);
        fx[i + 8] = inR + mix * (wetR - inR);
    }

    st->wp = wp; st->jp = jp;
    st->lowLp = lowLp; st->env = env; st->twEnv = twEnv; st->peak = peak;
    st->svLow = svLow; st->svBand = svBand; st->bodyLow = bodyLow; st->bodyBand = bodyBand;
    st->exA = exA; st->exB = exB;
    st->lowLp2 = lowLp2; st->excLp = excLp; st->topA = topA; st->topB = topB;
    st->dcxL = dcxL; st->dcyL = dcyL; st->dcxR = dcxR; st->dcyR = dcyR;
    st->lfo1 = lfo1; st->lfo2 = lfo2; st->lfo3 = lfo3; st->dp = dp;
}
