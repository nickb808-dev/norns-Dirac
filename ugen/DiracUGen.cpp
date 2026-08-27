// DiracUGen.cpp — the canonical ER-301 Dirac engine as a scsynth plugin.
//
// This file is a WRAPPER and nothing else. It contains no DSP. Its whole job is
// to hand the vendored engine the four things it expects — an input block, an
// output block, a set of control values, and a stable `this` — using memory and
// lifetimes that scsynth permits. Any change here that alters a sample value is
// a bug by definition; engine/ is upstream (see ENGINE-PROVENANCE.md).
//
// Three things about scsynth shape the design, all of them checked rather than
// assumed:
//
// 1. THE ENGINE ALLOCATES IN ITS CONSTRUCTOR, AND NOWHERE ELSE.
//    Measured: 49 heap allocations totalling 694 KB at construction, and
//    ZERO across 200 process() calls. So the audio path is already RT-safe and
//    needs no help. The constructor is the entire problem, and it cannot be
//    fixed here because the engine holds std::vectors and must not be edited.
//    Solution: construct the objects at PLUGIN LOAD time, when scsynth is
//    booting and no audio is running, and hand them out from a pool. Cost is
//    ~694 KB per slot, paid once, against a server already resident at ~130 MB.
//
// 2. PORT BUFFERS ARE BORROWED, NOT OWNED.
//    IN(n)/OUT(n) point into the graph's wires and may move between calls, so
//    the shim's Ports are re-pointed every block. See norns/od/objects/Object.h.
//
// 3. BLOCK SIZE IS A COMPILE-TIME CONSTANT IN THE ENGINE, AND A RUNTIME
//    SETTING IN THE SERVER. FRAMELENGTH is baked in; scsynth's -z is not. If
//    they disagree the engine reads and writes past the ends of the wires, so
//    this refuses to run rather than corrupting the graph.
#include "SC_PlugIn.h"

#include <Dirac.h>
#include <od/objects/Object.h>

#include <cstdio>
#include <cstring>
#include <new>

static InterfaceTable *ft;

// ─── input map ───────────────────────────────────────────────────────────────
// Order is the engine's own registration order in Dirac::Dirac(), deliberately:
// it is derived from the source rather than invented here, so appending an
// inlet upstream is a mechanical change in one place. Dirac.sc MUST match.
//
// The names are the engine's too — Dirac.sc reproduces them for its argument
// list, and the NRT score generator reads them from here.
enum {
    kIn = 0,   kPlayhead, kRate,     kPosJtr,   kSpread,  kDetune,
    kLevel,    kRevProb,  kPsprd,    kTexture,  kGrains,  kFire,
    kHold,     kSemiShift, kGrainLen, kMix,     kFeedback, kCompress,
    kBinaural, kScale,    kVoct,     kSpeed,    kHeads,   kHeadSpread,
    kHeadTune, kSnap,     kColor,    kTilt,     kTiltSpread, kWindow,
    kNumInlets,
    // Menu options. Ints, 1-based, matching od::OptionControl on the device —
    // the engine compares against literal 1/2/3, so 0 is not a valid value.
    kOptPlayheads = kNumInlets, kOptDiffuse, kOptFreeze,
    kNumInputs
};

// The two inlets the engine reads PER SAMPLE rather than once per block.
// Verified against the source: every other inlet is read only as buffer()[0],
// so pointing it at a 1-float control wire is safe. These two are not, and
// getting this wrong is an out-of-bounds read that would usually not crash —
// it would just sound subtly wrong, which is worse.
static inline bool isAudioRateInlet(int i) { return i == kIn || i == kFire; }

// ─── the pre-built engine pool ───────────────────────────────────────────────
// Built in PluginLoad (scsynth boot), so no Dirac constructor ever runs on the
// audio thread. norns needs exactly one instance; the spare covers a reload
// where the old synth has not yet been freed.
static const int kPoolSize = 2;

struct Pool {
    dirac::Dirac *slot[kPoolSize];
    bool          used[kPoolSize];

    void init() {
        for (int i = 0; i < kPoolSize; ++i) {
            slot[i] = new (std::nothrow) dirac::Dirac();
            used[i] = false;
        }
    }
    // Called from the RT thread, but scsynth processes node creation and
    // destruction on that one thread, so this needs no locking.
    dirac::Dirac *acquire(int *idx) {
        for (int i = 0; i < kPoolSize; ++i) {
            if (!used[i] && slot[i]) { used[i] = true; *idx = i; return slot[i]; }
        }
        *idx = -1;
        return nullptr;
    }
    void release(int idx) {
        if (idx >= 0 && idx < kPoolSize) used[idx] = false;
    }
};
static Pool gPool;

// ─── the unit ────────────────────────────────────────────────────────────────
struct DiracUGen : public Unit {
    dirac::Dirac *engine;
    int           poolIdx;
    bool          live;        // false => refusing to run; output silence
    // Scalar inputs promoted to a full block, for the two per-sample inlets.
    // RTAlloc'd because these ARE created on the audio thread.
    float        *fanBuf[2];
};

static void DiracUGen_next(DiracUGen *unit, int inNumSamples);
static void DiracUGen_Ctor(DiracUGen *unit);
static void DiracUGen_Dtor(DiracUGen *unit);

// Ports, addressed in the same order as the enum. Built per call rather than
// stored: it is a handful of pointer loads and it cannot go stale.
static inline od::Port *portFor(dirac::Dirac *d, int i)
{
    switch (i) {
        case kIn:         return &d->mIn;
        case kPlayhead:   return &d->mPlayheadIn;
        case kRate:       return &d->mRateIn;
        case kPosJtr:     return &d->mPosJtrIn;
        case kSpread:     return &d->mSprdIn;
        case kDetune:     return &d->mDetuneIn;
        case kLevel:      return &d->mLevelIn;
        case kRevProb:    return &d->mRevProbIn;
        case kPsprd:      return &d->mPsprdIn;
        case kTexture:    return &d->mTextureIn;
        case kGrains:     return &d->mGrainsIn;
        case kFire:       return &d->mFireIn;
        case kHold:       return &d->mHoldIn;
        case kSemiShift:  return &d->mSemiShiftIn;
        case kGrainLen:   return &d->mGrainLenIn;
        case kMix:        return &d->mMixIn;
        case kFeedback:   return &d->mFeedbackIn;
        case kCompress:   return &d->mCompressIn;
        case kBinaural:   return &d->mBinauralIn;
        case kScale:      return &d->mScaleIn;
        case kVoct:       return &d->mVoctIn;
        case kSpeed:      return &d->mSpeedIn;
        case kHeads:      return &d->mHeadsIn;
        case kHeadSpread: return &d->mHeadSpreadIn;
        case kHeadTune:   return &d->mHeadTuneIn;
        case kSnap:       return &d->mSnapIn;
        case kColor:      return &d->mColorIn;
        case kTilt:       return &d->mTiltIn;
        case kTiltSpread: return &d->mTiltSprdIn;
        case kWindow:     return &d->mWindowIn;
        default:          return nullptr;
    }
}

void DiracUGen_Ctor(DiracUGen *unit)
{
    unit->engine     = nullptr;
    unit->poolIdx    = -1;
    unit->live       = false;
    unit->fanBuf[0]  = nullptr;
    unit->fanBuf[1]  = nullptr;

    // (3) above. A mismatch here is the single most likely cause of a render
    // that diverges wildly rather than subtly, so say so in words: a silent
    // wrong answer would be indistinguishable from a DSP bug.
    if (BUFLENGTH != FRAMELENGTH) {
        Print("Dirac: REFUSING TO RUN. This plugin was compiled for a %d-sample\n"
              "       block but the server is running %d. Rebuild with\n"
              "       -DFRAMELENGTH=%d, or start scsynth with -z %d.\n",
              (int)FRAMELENGTH, (int)BUFLENGTH, (int)BUFLENGTH, (int)FRAMELENGTH);
        SETCALC(DiracUGen_next);
        ClearUnitOutputs(unit, 1);
        return;
    }

    unit->engine = gPool.acquire(&unit->poolIdx);
    if (!unit->engine) {
        Print("Dirac: no free engine in the pool (size %d). Free the existing\n"
              "       Dirac synth before creating another.\n", kPoolSize);
        SETCALC(DiracUGen_next);
        ClearUnitOutputs(unit, 1);
        return;
    }

    for (int k = 0; k < 2; ++k) {
        unit->fanBuf[k] = (float *)RTAlloc(unit->mWorld, FRAMELENGTH * sizeof(float));
        if (!unit->fanBuf[k]) {
            Print("Dirac: RTAlloc failed. Raise the server's real-time memory\n"
                  "       (scsynth -m).\n");
            gPool.release(unit->poolIdx);
            unit->poolIdx = -1;
            unit->engine  = nullptr;
            SETCALC(DiracUGen_next);
            ClearUnitOutputs(unit, 1);
            return;
        }
        memset(unit->fanBuf[k], 0, FRAMELENGTH * sizeof(float));
    }

    unit->live = true;
    SETCALC(DiracUGen_next);
    // One silent block before the first real one, matching scsynth convention.
    ClearUnitOutputs(unit, 1);
}

void DiracUGen_Dtor(DiracUGen *unit)
{
    for (int k = 0; k < 2; ++k)
        if (unit->fanBuf[k]) RTFree(unit->mWorld, unit->fanBuf[k]);
    // The engine goes back to the pool rather than being destroyed: it is
    // reused, and destroying it here would free 694 KB on the audio thread,
    // which is the same hazard as allocating there.
    gPool.release(unit->poolIdx);
    unit->poolIdx = -1;
    unit->engine  = nullptr;
}

void DiracUGen_next(DiracUGen *unit, int inNumSamples)
{
    if (!unit->live || !unit->engine) {
        float *o0 = OUT(0), *o1 = OUT(1);
        memset(o0, 0, inNumSamples * sizeof(float));
        memset(o1, 0, inNumSamples * sizeof(float));
        return;
    }

    dirac::Dirac *d = unit->engine;
    int fan = 0;

    for (int i = 0; i < kNumInlets; ++i) {
        od::Port *p = portFor(d, i);
        if (!p) continue;

        if (isAudioRateInlet(i)) {
            if (INRATE(i) == calc_FullRate) {
                // const_cast is safe: the engine only READS inlets. Ports are a
                // single type for in and out, which is what forces this.
                p->point(const_cast<float *>(IN(i)));
            } else {
                // A control-rate or scalar wire is one float long. The engine
                // reads FRAMELENGTH of them, so fan the value out rather than
                // reading off the end of the wire.
                float *b = unit->fanBuf[fan++];
                const float v = IN0(i);
                for (int s = 0; s < FRAMELENGTH; ++s) b[s] = v;
                p->point(b);
            }
        } else {
            // Read as buffer()[0] only — verified against the engine source —
            // so a 1-float control wire is exactly enough.
            p->point(const_cast<float *>(IN(i)));
        }
    }

    d->mMultiHeadOpt.set((int)IN0(kOptPlayheads));
    d->mDiffuseOpt.set((int)IN0(kOptDiffuse));
    d->mFreezeOpt.set((int)IN0(kOptFreeze));

    d->mOutL.point(OUT(0));
    d->mOutR.point(OUT(1));

    d->process();

    // Ports borrow scsynth's wires, which are only valid inside this call.
    // Parking them stops a stale pointer from being reachable if the engine is
    // ever touched between blocks.
    for (int i = 0; i < kNumInlets; ++i)
        if (od::Port *p = portFor(d, i)) p->point(nullptr);
    d->mOutL.point(nullptr);
    d->mOutR.point(nullptr);
}

PluginLoad(DiracUGen)
{
    ft = inTable;
    gPool.init();
    DefineDtorUnit(DiracUGen);
}
