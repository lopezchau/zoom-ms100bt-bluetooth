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
 * Knobs: Buzz, Twang, Strings, Decay, Key (0–11 = C–B), Raga (0 Bilawal, 1 Kafi, 2 Bhairav), Mix.
 */
#include "../common/zdl_fx.h"

#ifndef SITAR_AUDIO_FUNC
#define SITAR_AUDIO_FUNC Fx_SFX_Sitar
#endif

#define ST_MAGIC     0x53495432u   /* 'SIT2' */
#define ST_STRINGS   11
#define ST_LINE      512u          /* samples per string line (≥ 44100 / 261.6 Hz with margin) */
#define ST_LINE_MASK (ST_LINE - 1u)
#define JW_LEN       128u          /* jawari delay lines (≤ 2.9 ms) */
#define JW_MASK      (JW_LEN - 1u)

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
    int32_t  key, raga;
    uint32_t wp;                 /* shared write position of the string lines */
    uint32_t jp;                 /* write position of the jawari lines */
    float    delay[ST_STRINGS];
    float    damp[ST_STRINGS];
    float    lowLp;              /* removes the guitar's low end (sitars are thin) */
    float    env;                /* note envelope (normalizes the displacement) */
    float    twEnv;              /* twang envelope: instant attack, ~200 ms glide */
    float    peak;               /* recent attack peak, for the twang ratio */
    float    svLow, svBand;      /* twang filter */
    float    bodyLow, bodyBand;  /* fixed nasal resonance (~2.6 kHz) */
    float    exA, exB;           /* exciter high-pass states */
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
    if (linesBase + (uintptr_t)(ST_STRINGS * ST_LINE) * 4u > arenaEnd) return;
    float *lines = (float *)linesBase;

    int s;
    uint32_t n;
    if (st->magic != ST_MAGIC) {
        st->magic = ST_MAGIC;
        st->cleared = 0u;
        st->key = -1;
        st->raga = -1;
        st->wp = 0u;
        st->jp = 0u;
        for (s = 0; s < ST_STRINGS; s++) { st->damp[s] = 0.0f; st->delay[s] = 200.0f; }
        for (n = 0; n < JW_LEN; n++) { st->jawLead[n] = 0.0f; st->jawSym[n] = 0.0f; }
        st->lowLp = 0.0f;
        st->env = 0.0f;
        st->twEnv = 0.0f;
        st->peak = 0.0f;
        st->svLow = 0.0f; st->svBand = 0.0f;
        st->bodyLow = 0.0f; st->bodyBand = 0.0f;
        st->exA = 0.0f; st->exB = 0.0f;
    }
    if (st->cleared < (uint32_t)(ST_STRINGS * ST_LINE)) {
        uint32_t e = st->cleared + 2048u;
        if (e > (uint32_t)(ST_STRINGS * ST_LINE)) e = (uint32_t)(ST_STRINGS * ST_LINE);
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

    int i;
    for (i = 0; i < 8; i++) {
        float inL = fx[i];
        float inR = fx[i + 8];
        float in = 0.5f * (inL + inR);

        /* Thin the guitar: high-pass ~180 Hz. */
        lowLp += 0.025f * (in - lowLp);
        float str = in - lowLp;
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
        float fc = 700.0f + 3300.0f * ratio * ratio;
        float f = 6.2831853f * fc * (1.0f / 44100.0f);
        svLow += f * svBand;
        float svHigh = lead - svLow - 0.18f * svBand;
        svBand += f * svHigh;

        /* Fixed nasal resonance of the gourd/bridge, ~2.6 kHz. */
        bodyLow += 0.37f * bodyBand;
        float bodyHigh = lead - bodyLow - 0.5f * bodyBand;
        bodyBand += 0.37f * bodyHigh;

        float voice = (lead + twang * 0.9f * svBand + 0.35f * bodyBand) * trim;

        /* --- taraf: sympathetic strings, with their own jawari --- */
        float exc = 0.25f * voice;
        float symL = 0.0f, symR = 0.0f;
        for (s = 0; s < ST_STRINGS; s++) {
            float *line = lines + s * ST_LINE;
            float past = st_tap(line, wp, st->delay[s], ST_LINE_MASK);
            float dmp = st->damp[s] + loopLp * (past - st->damp[s]);
            st->damp[s] = dmp;
            line[wp] = exc + feedback * dmp;
            if (s & 1) symR += dmp; else symL += dmp;
        }
        wp = (wp + 1u) & ST_LINE_MASK;
        float sym = symL + symR;
        st->jawSym[jp] = sym;
        float symContact = zdl_clamp(-sym * 8.0f, 0.0f, 1.0f);
        float symJaw = st_tap(st->jawSym, jp, 1.5f + 20.0f * symContact, JW_MASK);
        float shimmer = 0.5f * (sym + symJaw) + 0.6f * (sym - symJaw);
        jp = (jp + 1u) & JW_MASK;

        float spreadL = 0.6f * zdl_softclip(2.0f * (0.7f * shimmer + 0.6f * symL));
        float spreadR = 0.6f * zdl_softclip(2.0f * (0.7f * shimmer + 0.6f * symR));
        float wetL = voice + strings * spreadL;
        float wetR = voice + strings * spreadR;
        fx[i] = inL + mix * (wetL - inL);
        fx[i + 8] = inR + mix * (wetR - inR);
    }

    st->wp = wp; st->jp = jp;
    st->lowLp = lowLp; st->env = env; st->twEnv = twEnv; st->peak = peak;
    st->svLow = svLow; st->svBand = svBand; st->bodyLow = bodyLow; st->bodyBand = bodyBand;
    st->exA = exA; st->exB = exB;
}
