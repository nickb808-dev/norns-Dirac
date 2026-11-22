// NoetherUGen.cpp — the canonical ER-301 Noether looper engine as a scsynth plugin.
//
// A WRAPPER, like DiracUGen.cpp, and built on the same lessons (read that
// file's header first). It contains no DSP: engine/Noether.{h,cpp} is
// vendored verbatim from the ER-301 repo `noether`, and every seam trick -
// the phase-matched cut, the tail-into-head blend, the shadow-head jumps, the
// record ramps, the speed glide - lives there and arrives here unchanged.
//
// What this file adds:
//
// 1. THE LOOP BUFFER IS A SERVER BUFFER. On the ER-301 it is a pool sample
//    created from Lua; here sclang allocates a stereo Buffer (and a second
//    one of the same size for undo) and passes their bufnums. The od::Sample
//    views are rebuilt from the SndBufs EVERY block, never trusted across
//    blocks, and setSample() / setUndoSample() are called only when what they
//    point at changes - setSample() resets the looper to EMPTY.
//
// 2. PER-SAMPLE INLETS ARE COPIED. Noether reads six inlets per sample (the
//    two audio inputs and the Rec / Dub / Undo / Clk triggers; verified
//    against Noether.cpp - everything else is buffer()[0]). Each is copied into
//    a private block first, because scsynth may hand this unit an OUT buffer
//    that aliases one of its IN wires (DiracUGen.cpp, "NEVER point the engine
//    at an audio-rate IN(i) directly" - that bug silenced Dirac on the norns).
//
// 3. CLEAR is a trigger input: clearLoop() + zeroBuffer(), the ER-301 menu's
//    "Clear loop", both of which only set flags the audio thread honours.
//
// 4. DISPLAY DATA for the Reel, sent to sclang ~30 Hz:
//
//    /noether_viz [state, loopLen, pos, write, loop0, speed, detent, sections,
//                  armed, canUndo, restoring, cap, then kEnvBins envelope]
//
//    The envelope is the ER-301 Reel's (NoetherReel.h updateEnvelope):
//    kEnvBins peak bins over the loop, recomputed incrementally - a bounded
//    number of bins per frame, strided reads, only the bins the head crossed
//    while overdubbing - and soft-curved into [0, 1). On the ER-301 that ran
//    in the display's draw(); here it runs on the audio thread at display
//    rate, which the budget (12 bins x <= 512 reads, 30 times a second) makes
//    negligible.
#include "SC_PlugIn.h"

#include <Noether.h>
#include <od/objects/Object.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <new>

static InterfaceTable *ft;

// ─── input map ───────────────────────────────────────────────────────────────
// The engine's registration order (Noether::Noether), the option after it,
// then the wrapper's own. Noether.sc MUST match (tools/check-ugen-names.sh).
enum {
    kInL = 0, kInR, kRec, kDub, kStop, kUndo, kClk,
    kSpeed, kVoct, kExt, kBars, kSos, kDry, kLevel,
    kNumInlets,
    // od::Option, 1-based: 1 = free, 2 = sync
    kOptSync = kNumInlets,
    // server buffer numbers (< 0 = none): the loop, and its undo twin
    kBuf, kUndoBuf,
    // a rising edge clears the loop
    kClear,
    kNumInputs
};

static inline bool isPerSampleInlet(int i)
{
    return i == kInL || i == kInR || i == kRec || i == kDub || i == kUndo || i == kClk;
}
static inline int fanSlot(int i)
{
    switch (i) {
        case kInL: return 0; case kInR: return 1; case kRec: return 2;
        case kDub: return 3; case kUndo: return 4; case kClk: return 5;
        default: return -1;
    }
}
static constexpr int kNumFan = 6;

static constexpr int kVizHz      = 30;
static constexpr int kEnvBins    = 96;    // NoetherReel::kBins
static constexpr int kBinsPerViz = 12;    // NoetherReel::kBinsPerDraw
static constexpr int kMaxStride  = 512;   // NoetherReel::kMaxStride
static constexpr int kVizHeader  = 12;

// NAME IS LOAD-BEARING: DefineDtorUnit registers this struct's name, and
// Noether.sc asks the server for a UGen by its class name.
struct Noether : public Unit {
    noether::Noether *engine;
    bool              live;
    float            *fanBuf[kNumFan];

    od::Sample        loop, undo;
    const float      *loopData, *undoData;
    int               loopFrames, undoFrames, loopCh, undoCh;
    bool              loopOn, undoOn;

    float             lastClear;

    int               vizEvery, vizCountdown;
    float             env[kEnvBins];
    unsigned char     envDirty[kEnvBins];
    int               envRev, envLen, envCursor, envPending, envLastPos;
    float             vizMsg[kVizHeader + kEnvBins];
};

static void Noether_next(Noether *unit, int inNumSamples);
static void Noether_Ctor(Noether *unit);
static void Noether_Dtor(Noether *unit);

static inline od::Port *portFor(noether::Noether *d, int i)
{
    switch (i) {
        case kInL:   return &d->mLeftIn;
        case kInR:   return &d->mRightIn;
        case kRec:   return &d->mRecIn;
        case kDub:   return &d->mDubIn;
        case kStop:  return &d->mStopIn;
        case kUndo:  return &d->mUndoIn;
        case kClk:   return &d->mClkIn;
        case kSpeed: return &d->mSpeedIn;
        case kVoct:  return &d->mVoctIn;
        case kExt:   return &d->mExtIn;
        case kBars:  return &d->mBarsIn;
        case kSos:   return &d->mSosIn;
        case kDry:   return &d->mDryIn;
        case kLevel: return &d->mLevelIn;
        default:     return nullptr;
    }
}

static void silence(Noether *unit, int n)
{
    memset(OUT(0), 0, n * sizeof(float));
    memset(OUT(1), 0, n * sizeof(float));
}

void Noether_Ctor(Noether *unit)
{
    unit->engine = nullptr;
    unit->live = false;
    for (int k = 0; k < kNumFan; ++k) unit->fanBuf[k] = nullptr;
    unit->loop = od::Sample();
    unit->undo = od::Sample();
    unit->loopData = unit->undoData = nullptr;
    unit->loopFrames = unit->undoFrames = 0;
    unit->loopCh = unit->undoCh = 0;
    unit->loopOn = unit->undoOn = false;
    unit->lastClear = 0.0f;

    const double blocksPerSec = SAMPLERATE / double(BUFLENGTH > 0 ? BUFLENGTH : 64);
    unit->vizEvery = blocksPerSec / kVizHz >= 1.0 ? int(blocksPerSec / kVizHz) : 1;
    unit->vizCountdown = unit->vizEvery;
    for (int i = 0; i < kEnvBins; ++i) { unit->env[i] = 0.0f; unit->envDirty[i] = 0; }
    unit->envRev = -1; unit->envLen = 0; unit->envCursor = 0; unit->envPending = 0; unit->envLastPos = 0;

    if (BUFLENGTH != FRAMELENGTH) {
        Print("Noether: REFUSING TO RUN. Compiled for a %d-sample block, the\n"
              "         server runs %d. Rebuild with -DFRAMELENGTH=%d.\n",
              (int)FRAMELENGTH, (int)BUFLENGTH, (int)BUFLENGTH);
        SETCALC(Noether_next);
        ClearUnitOutputs(unit, 1);
        return;
    }
    // The engine's time constants assume 48 kHz (Noether::kSampleRate). norns
    // runs at 48 kHz; anything else still works, with every time scaled.
    if (SAMPLERATE != 48000.0)
        Print("Noether: the server runs at %.0f Hz; the engine assumes 48000.\n", (double)SAMPLERATE);

    // One allocation (the 360 kB undo bitmap), here for the same reason
    // Dirac's is: a fresh engine is a clean engine. See DiracUGen.cpp (1).
    unit->engine = new (std::nothrow) noether::Noether(2);
    if (!unit->engine) {
        Print("Noether: out of memory constructing the engine.\n");
        SETCALC(Noether_next);
        ClearUnitOutputs(unit, 1);
        return;
    }
    for (int k = 0; k < kNumFan; ++k) {
        unit->fanBuf[k] = (float *)RTAlloc(unit->mWorld, FRAMELENGTH * sizeof(float));
        if (!unit->fanBuf[k]) {
            Print("Noether: RTAlloc failed. Raise the server's real-time memory (scsynth -m).\n");
            for (int j = 0; j < k; ++j) { RTFree(unit->mWorld, unit->fanBuf[j]); unit->fanBuf[j] = nullptr; }
            delete unit->engine;
            unit->engine = nullptr;
            SETCALC(Noether_next);
            ClearUnitOutputs(unit, 1);
            return;
        }
        memset(unit->fanBuf[k], 0, FRAMELENGTH * sizeof(float));
    }
    unit->live = true;
    SETCALC(Noether_next);
    ClearUnitOutputs(unit, 1);
}

void Noether_Dtor(Noether *unit)
{
    for (int k = 0; k < kNumFan; ++k)
        if (unit->fanBuf[k]) RTFree(unit->mWorld, unit->fanBuf[k]);
    if (unit->engine) {
        // detach first, so the engine releases nothing it no longer holds
        unit->engine->setUndoSample(nullptr);
        unit->engine->setSample(nullptr);
    }
    delete unit->engine;
    unit->engine = nullptr;
}

// Fill `s` from server buffer `bufnum` (stereo or mono, >= 1 frame). Returns
// false (and leaves `s` alone) for none / invalid / unallocated.
static bool viewOf(World *w, float fb, od::Sample &s)
{
    if (!w || fb < 0.0f) return false;
    const uint32 bn = uint32(fb);
    if (bn >= w->mNumSndBufs) return false;
    SndBuf *buf = w->mSndBufs + bn;
    LOCK_SNDBUF_SHARED(buf);
    if (!buf->data || buf->frames < 8 || buf->channels < 1 || buf->channels > 2) return false;
    s.mpData           = buf->data;
    s.mSampleCount     = uint32_t(buf->frames);
    s.mSampleLoadCount = uint32_t(buf->frames);
    s.mChannelCount    = uint32_t(buf->channels);
    return true;
}

// The Reel's envelope (NoetherReel::updateEnvelope), over [0, L0).
static void updateEnvelope(Noether *unit, noether::Noether *h, int L0)
{
    const int rev = h->getLoopRev();
    if (rev != unit->envRev || L0 != unit->envLen) {
        unit->envRev = rev; unit->envLen = L0; unit->envCursor = 0; unit->envPending = kEnvBins;
        for (int i = 0; i < kEnvBins; ++i) unit->envDirty[i] = 1;
        unit->envLastPos = h->vizPos();
    }
    if (L0 <= 0) return;
    if (h->getState() == noether::Noether::OVERDUB) {
        const int w = h->vizPos();
        int b0 = int((long)unit->envLastPos * kEnvBins / L0), b1 = int((long)w * kEnvBins / L0);
        if (b0 < 0) b0 = 0;
        if (b0 >= kEnvBins) b0 = kEnvBins - 1;
        if (b1 < 0) b1 = 0;
        if (b1 >= kEnvBins) b1 = kEnvBins - 1;
        int n = b1 - b0; if (n < 0) n += kEnvBins;
        if (n > kEnvBins / 2) n = kEnvBins / 2;
        for (int k = 0; k <= n; ++k) {
            int b = b0 + k; if (b >= kEnvBins) b -= kEnvBins;
            if (!unit->envDirty[b]) { unit->envDirty[b] = 1; ++unit->envPending; }
        }
        unit->envLastPos = w;
    }
    if (unit->envPending <= 0) return;
    const float *d = unit->loop.mpData;
    const int nc = int(unit->loop.mChannelCount);
    const int cap = int(unit->loop.mSampleCount);
    if (!d || L0 > cap) return;
    int budget = kBinsPerViz;
    for (int k = 0; k < kEnvBins && budget > 0; ++k) {
        int b = unit->envCursor + k; if (b >= kEnvBins) b -= kEnvBins;
        if (!unit->envDirty[b]) continue;
        const int s0 = int((long)b * L0 / kEnvBins);
        const int s1 = int((long)(b + 1) * L0 / kEnvBins);
        int span = s1 - s0; if (span < 1) span = 1;
        int stride = span / kMaxStride; if (stride < 1) stride = 1;
        float peak = 0.0f;
        for (int i = s0; i < s1; i += stride) {
            const float *f = d + (size_t)i * nc;
            float v = fabsf(f[0]);
            if (nc > 1) { const float g = fabsf(f[1]); if (g > v) v = g; }
            if (v > peak) peak = v;
        }
        unit->env[b] = peak / (peak + 0.25f);
        unit->envDirty[b] = 0; --unit->envPending; --budget;
        unit->envCursor = (b + 1 >= kEnvBins) ? 0 : b + 1;
    }
}

void Noether_next(Noether *unit, int inNumSamples)
{
    if (!unit->live || !unit->engine) { silence(unit, inNumSamples); return; }
    noether::Noether *d = unit->engine;

    for (int i = 0; i < kNumInlets; ++i) {
        od::Port *p = portFor(d, i);
        if (!p) continue;
        if (isPerSampleInlet(i)) {
            float *b = unit->fanBuf[fanSlot(i)];
            if (INRATE(i) == calc_FullRate) {
                memcpy(b, IN(i), FRAMELENGTH * sizeof(float));
            } else {
                const float v = IN0(i);
                for (int s = 0; s < FRAMELENGTH; ++s) b[s] = v;
            }
            p->point(b);
        } else {
            p->point(const_cast<float *>(IN(i)));
        }
    }

    // ── the buffers ──────────────────────────────────────────────────────────
    World *w = unit->mWorld;
    {
        od::Sample v;
        const bool on = viewOf(w, IN0(kBuf), v);
        const bool changed = on != unit->loopOn
            || (on && (v.mpData != unit->loopData || int(v.mSampleCount) != unit->loopFrames
                       || int(v.mChannelCount) != unit->loopCh));
        if (on) {
            unit->loop.mpData = v.mpData;
            unit->loop.mSampleCount = v.mSampleCount;
            unit->loop.mSampleLoadCount = v.mSampleLoadCount;
            unit->loop.mChannelCount = v.mChannelCount;
        }
        if (changed) {
            d->setSample(on ? &unit->loop : nullptr);
            unit->loopOn = on;
            unit->loopData = on ? v.mpData : nullptr;
            unit->loopFrames = on ? int(v.mSampleCount) : 0;
            unit->loopCh = on ? int(v.mChannelCount) : 0;
        }
    }
    {
        od::Sample v;
        const bool on = viewOf(w, IN0(kUndoBuf), v);
        const bool changed = on != unit->undoOn
            || (on && (v.mpData != unit->undoData || int(v.mSampleCount) != unit->undoFrames
                       || int(v.mChannelCount) != unit->undoCh));
        if (on) {
            unit->undo.mpData = v.mpData;
            unit->undo.mSampleCount = v.mSampleCount;
            unit->undo.mSampleLoadCount = v.mSampleLoadCount;
            unit->undo.mChannelCount = v.mChannelCount;
        }
        if (changed) {
            d->setUndoSample(on ? &unit->undo : nullptr);
            unit->undoOn = on;
            unit->undoData = on ? v.mpData : nullptr;
            unit->undoFrames = on ? int(v.mSampleCount) : 0;
            unit->undoCh = on ? int(v.mChannelCount) : 0;
        }
    }

    {
        const float c = IN0(kClear);
        if (c > 0.0f && unit->lastClear <= 0.0f) { d->clearLoop(); d->zeroBuffer(); }
        unit->lastClear = c;
    }
    {
        int o = int(IN0(kOptSync));
        d->mSyncOpt.set(o == 2 ? 2 : 1);
    }

    d->mLeftOut.point(OUT(0));
    d->mRightOut.point(OUT(1));
    d->process();

    if (--unit->vizCountdown <= 0) {
        unit->vizCountdown = unit->vizEvery;
        const int state = d->getState();
        const int L = d->getLoopSamples();
        const int L0 = (state == noether::Noether::EXTEND) ? d->vizLoop0() : L;
        if (state != noether::Noether::EMPTY && state != noether::Noether::RECORD)
            updateEnvelope(unit, d, L0);
        else
            unit->envRev = -1;
        float *m = unit->vizMsg;
        m[0]  = float(state);
        m[1]  = float(L);
        m[2]  = float(d->vizPos());
        m[3]  = float(d->vizWrite());
        m[4]  = float(L0);
        m[5]  = d->getSpeed();
        m[6]  = float(d->getDetent());
        m[7]  = float(d->getSections());
        m[8]  = float(d->isArmed());
        m[9]  = float(d->canUndo());
        m[10] = float(d->isRestoring());
        m[11] = float(d->vizCapacity());
        memcpy(m + kVizHeader, unit->env, sizeof(unit->env));
        SendNodeReply(&unit->mParent->mNode, -1, "/noether_viz", kVizHeader + kEnvBins, m);
    }

    for (int i = 0; i < kNumInlets; ++i)
        if (od::Port *p = portFor(d, i)) p->point(nullptr);
    d->mLeftOut.point(nullptr);
    d->mRightOut.point(nullptr);
}

PluginLoad(Noether)
{
    ft = inTable;
    DefineDtorUnit(Noether);
}
