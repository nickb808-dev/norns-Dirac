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
//    Measured: 49 heap allocations totalling 694 KB and 0.117 ms at
//    construction, and ZERO allocations across 200 process() calls. So the
//    audio path is already RT-safe; only the constructor touches the heap.
//
//    An earlier version pre-built engines at plugin load and handed them out
//    from a pool, to keep malloc off the audio thread entirely. THAT WAS A
//    MISTAKE and the off-device tests caught it: a pooled engine is handed back
//    DIRTY. Its capture ring still holds the previous session's audio and its
//    grain RNG has advanced, so restarting a script would granulate whatever
//    was playing before. The engine is vendored, so it has no reset() to call
//    and one cannot be added here.
//
//    So: construct per unit, in the constructor, and accept one 694 KB / 0.117
//    ms allocation on the audio thread. norns creates this synth once when the
//    script loads. Trading a brief, one-time allocation at load for guaranteed
//    clean state is the right way round — the allocation is theoretical, the
//    stale ring was audible.
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

#include <cmath>
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
    kHeadTune, kSnap,     kTilt,     kTiltSpread, kWindow,
    kNumInlets,
    // Menu options. Ints, 1-based, matching od::OptionControl on the device —
    // the engine compares against literal 1/2/3, so 0 is not a valid value.
    kOptPlayheads = kNumInlets, kOptDiffuse, kOptFreeze,
    // Sample mode: a server buffer number, or < 0 for live. Not an engine
    // inlet - the wrapper turns it into setSample() (see "sample mode" below).
    kBuf,
    kNumInputs
};

// The two inlets the engine reads PER SAMPLE rather than once per block.
// Verified against the source: every other inlet is read only as buffer()[0],
// so pointing it at a 1-float control wire is safe. These two are not, and
// getting this wrong is an out-of-bounds read that would usually not crash —
// it would just sound subtly wrong, which is worse.
static inline bool isAudioRateInlet(int i) { return i == kIn || i == kFire; }

// ─── the unit ────────────────────────────────────────────────────────────────
// NAME IS LOAD-BEARING. DefineDtorUnit registers the UGen under this struct's
// name, and Dirac.sc asks the server for a UGen by ITS class name. They must be
// the same string or the plugin loads fine and every SynthDef using it fails
// with "UGen 'Dirac' not installed" — a failure that points at the server, not
// at this line. (It was DiracUGen here and Dirac there. Fixed.)
//
// ─── display data ─────────────────────────────────────────────────────────────
// The norns UI draws the grain field from the engine's public read-only state
// (the same getters the ER-301's own field view uses). The wrapper sends it to
// sclang with SendNodeReply - the mechanism SendReply uses - at display rate:
//
//   /dirac_viz  ~30 Hz   [sampleMode, frozen, capWrite, headPos01, nActive,
//                         texture, srcLen, then per ACTIVE grain: readPos01,
//                         spawnPos01, pitchSemi, envelope, gain, pan,
//                         reverse, durationSamples]
//
// srcLen is the length of the [0,1] axis in samples (the ring, or the
// sample), so the UI can draw each grain's whole read span: duration x
// playback rate (2^(pitch/12)) / srcLen, leftward if reverse.
//   /dirac_wave ~15 Hz   [capWrite, then kWaveBins peaks]
//
// texture is getVizTexture(): the envelope shape grains spawn with, 0
// percussive .. 0.5 hann .. 1 tukey (a fixed Window maps to its nearest). The
// UI draws each grain as a glyph of that shape, as the ER-301's field does.
// 15 Hz waveform: 129 floats a frame is trivial, and at 4 Hz the live input
// visibly stepped.
//
// Waveform peaks are |input| per kWaveBinLen samples, indexed by ABSOLUTE ring
// position, so the UI rotates them against capWrite. They are the input as
// written, not the ring's contents: with Feedback up the ring also holds the
// regenerated signal, which only an engine getter can show (planned upstream:
// getCapData()). Live mode only; sample-mode peaks come from the file.
static constexpr int kRingSize    = 131072;  // == Dirac::kCapBufSize (private); see above
static constexpr int kWaveBins    = 128;     // one per screen column
static constexpr int kWaveBinLen  = kRingSize / kWaveBins;   // 1024
static constexpr int kVizHz       = 30;
static constexpr int kWaveHz      = 15;
static constexpr int kVizPerGrain = 8;
static constexpr int kVizHeader   = 7;

// Unqualified `Dirac` is this wrapper's unit. The engine is always `dirac::Dirac`.
struct Dirac : public Unit {
    dirac::Dirac *engine;
    bool          live;        // false => refusing to run; output silence
    // Private copies of the two per-sample inlets (kIn, kFire), refilled every
    // block: a copy of the wire when it is audio rate, the scalar fanned out
    // when it is not. RTAlloc'd because these ARE created on the audio thread.
    // Why the copy is mandatory, not an optimisation: see Dirac_next.
    float        *fanBuf[2];

    // Display state. Plain arrays: scsynth allocates the unit struct itself,
    // so these cost no RTAlloc.
    int           vizEvery, waveEvery;       // in blocks
    int           vizCountdown, waveCountdown;
    float         peaks[kWaveBins];
    float         binPeak;                   // the bin being written, until it completes
    float         vizMsg[kVizHeader + dirac::Dirac::kMaxGrains * kVizPerGrain];
    float         waveMsg[1 + kWaveBins];

    // Sample mode. The engine borrows an od::Sample; this one is refilled
    // from the server's SndBuf every block (see Dirac_next).
    od::Sample    sample;
    bool          attached;
    int           attachedFrames;
};

static void Dirac_next(Dirac *unit, int inNumSamples);
static void Dirac_Ctor(Dirac *unit);
static void Dirac_Dtor(Dirac *unit);

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
        case kTilt:       return &d->mTiltIn;
        case kTiltSpread: return &d->mTiltSprdIn;
        case kWindow:     return &d->mWindowIn;
        default:          return nullptr;
    }
}

void Dirac_Ctor(Dirac *unit)
{
    unit->engine     = nullptr;
    unit->live       = false;
    unit->fanBuf[0]  = nullptr;
    unit->fanBuf[1]  = nullptr;
    // Blocks per display frame. Server-rate derived, never zero.
    const double blocksPerSec = SAMPLERATE / double(BUFLENGTH > 0 ? BUFLENGTH : 64);
    unit->vizEvery  = blocksPerSec / kVizHz  >= 1.0 ? int(blocksPerSec / kVizHz)  : 1;
    unit->waveEvery = blocksPerSec / kWaveHz >= 1.0 ? int(blocksPerSec / kWaveHz) : 1;
    unit->vizCountdown  = unit->vizEvery;
    unit->waveCountdown = unit->waveEvery;
    memset(unit->peaks, 0, sizeof(unit->peaks));
    unit->binPeak = 0.0f;
    unit->sample = od::Sample();
    unit->attached = false;
    unit->attachedFrames = 0;

    // (3) above. A mismatch here is the single most likely cause of a render
    // that diverges wildly rather than subtly, so say so in words: a silent
    // wrong answer would be indistinguishable from a DSP bug.
    if (BUFLENGTH != FRAMELENGTH) {
        Print("Dirac: REFUSING TO RUN. This plugin was compiled for a %d-sample\n"
              "       block but the server is running %d. Rebuild with\n"
              "       -DFRAMELENGTH=%d, or start scsynth with -z %d.\n",
              (int)FRAMELENGTH, (int)BUFLENGTH, (int)BUFLENGTH, (int)FRAMELENGTH);
        SETCALC(Dirac_next);
        ClearUnitOutputs(unit, 1);
        return;
    }

    // The one heap allocation, and the reason it is here rather than at plugin
    // load: a freshly constructed engine has a zeroed capture ring and a seeded
    // RNG, which is what makes two runs of the same script sound the same.
    unit->engine = new (std::nothrow) dirac::Dirac();
    if (!unit->engine) {
        Print("Dirac: out of memory constructing the engine (~694 KB).\n");
        SETCALC(Dirac_next);
        ClearUnitOutputs(unit, 1);
        return;
    }

    for (int k = 0; k < 2; ++k) {
        unit->fanBuf[k] = (float *)RTAlloc(unit->mWorld, FRAMELENGTH * sizeof(float));
        if (!unit->fanBuf[k]) {
            Print("Dirac: RTAlloc failed. Raise the server's real-time memory\n"
                  "       (scsynth -m).\n");
            delete unit->engine;
            unit->engine = nullptr;
            SETCALC(Dirac_next);
            ClearUnitOutputs(unit, 1);
            return;
        }
        memset(unit->fanBuf[k], 0, FRAMELENGTH * sizeof(float));
    }

    unit->live = true;
    SETCALC(Dirac_next);
    // One silent block before the first real one, matching scsynth convention.
    ClearUnitOutputs(unit, 1);
}

void Dirac_Dtor(Dirac *unit)
{
    for (int k = 0; k < 2; ++k)
        if (unit->fanBuf[k]) RTFree(unit->mWorld, unit->fanBuf[k]);
    delete unit->engine;
    unit->engine = nullptr;
}

void Dirac_next(Dirac *unit, int inNumSamples)
{
    if (!unit->live || !unit->engine) {
        float *o0 = OUT(0), *o1 = OUT(1);
        memset(o0, 0, inNumSamples * sizeof(float));
        memset(o1, 0, inNumSamples * sizeof(float));
        return;
    }

    dirac::Dirac *d = unit->engine;

    for (int i = 0; i < kNumInlets; ++i) {
        od::Port *p = portFor(d, i);
        if (!p) continue;

        if (isAudioRateInlet(i)) {
            // NEVER point the engine at an audio-rate IN(i) directly.
            //
            // scsynth reuses wire buffers: when this UGen is the last reader of
            // an input wire, the graph builder may hand that SAME buffer to the
            // UGen as OUT(0) or OUT(1). Writing the output then overwrites the
            // input. The engine writes its outlets as it goes, so with aliasing
            // it reads back its own output (zeros, at first) as input, and the
            // whole unit goes permanently silent - even at mix 0.
            //
            // Measured on the norns: `Dirac.ar(src)` with src used by nothing
            // else is silent; the same graph with src also metered passes it
            // perfectly. Engine_Dirac hit this through `K2A.ar(fire)`, whose
            // wire only Dirac reads. The stub scsynth gives every wire its own
            // buffer, which is why no off-device test could see it.
            //
            // So every per-sample inlet is copied into a private buffer before
            // process() runs, and the engine never sees a wire it could clobber.
            float *b = unit->fanBuf[i == kIn ? 0 : 1];
            if (INRATE(i) == calc_FullRate) {
                memcpy(b, IN(i), FRAMELENGTH * sizeof(float));
            } else {
                // A control-rate or scalar wire is one float long. The engine
                // reads FRAMELENGTH of them, so fan the value out rather than
                // reading off the end of the wire.
                const float v = IN0(i);
                for (int s = 0; s < FRAMELENGTH; ++s) b[s] = v;
            }
            p->point(b);
        } else {
            // Read as buffer()[0] only — verified against the engine source —
            // so a 1-float control wire is exactly enough.
            p->point(const_cast<float *>(IN(i)));
        }
    }

    // ── sample mode ──────────────────────────────────────────────────────────
    // The buffer is the server's: sclang allocates, fills and frees it. So the
    // od::Sample is rebuilt from the SndBuf EVERY block, before process(), and
    // never trusted across blocks. That is what makes buffer changes safe:
    // b_allocRead / b_free swap a SndBuf's data between RT blocks and free the
    // old memory afterwards, so a pointer read here is current for this block.
    // (Engine_Dirac still frees a replaced buffer only after the synth has
    // moved to the new one.) Only global buffers; anything invalid - out of
    // range, unallocated, empty - means live.
    {
        od::Sample *want = nullptr;
        const float fb = IN0(kBuf);
        World *w = unit->mWorld;
        if (fb >= 0.0f && w) {
            const uint32 bn = uint32(fb);
            if (bn < w->mNumSndBufs) {
                SndBuf *buf = w->mSndBufs + bn;
                LOCK_SNDBUF_SHARED(buf);   // no-op on scsynth; supernova would need it held through process()
                if (buf->data && buf->frames > 1 && buf->channels > 0) {
                    unit->sample.mpData        = buf->data;
                    unit->sample.mChannelCount = buf->channels;
                    unit->sample.mSampleCount  = size_t(buf->frames);
                    want = &unit->sample;
                }
            }
        }
        // setSample() only on a change of state or length: it resets the
        // engine's end index. The data pointer is re-read by the engine every
        // block, so refreshing the struct above is enough otherwise.
        const bool wantAttached = (want != nullptr);
        const int  wantFrames   = want ? int(want->mSampleCount) : 0;
        if (wantAttached != unit->attached || wantFrames != unit->attachedFrames) {
            d->setSample(want);
            unit->attached = wantAttached;
            unit->attachedFrames = wantFrames;
        }
    }

    d->mMultiHeadOpt.set((int)IN0(kOptPlayheads));
    d->mDiffuseOpt.set((int)IN0(kOptDiffuse));
    d->mFreezeOpt.set((int)IN0(kOptFreeze));

    d->mOutL.point(OUT(0));
    d->mOutR.point(OUT(1));

    const int  capBefore = d->getCapWritePos();
    const bool frozen    = d->getFreezeOn();
    const bool sampleMode = d->isSampleMode();

    d->process();

    // Waveform peaks, in step with the ring the engine just wrote. Uses the
    // private input copy (fanBuf[0]): OUT(0) may alias the input wire, and by
    // now it holds output.
    //
    // A bin's peak is committed when its LAST sample is written. Resetting it
    // on entry instead (the first version) showed a gap at the write head in
    // every frame - the ugentest `viz` case caught it at 64. Committing late
    // shows the previous pass of that bin for up to 21 ms, which is invisible.
    if (!frozen && !sampleMode) {
        const float *in = unit->fanBuf[0];
        for (int s = 0; s < FRAMELENGTH; ++s) {
            const int idx = (capBefore + s) & (kRingSize - 1);
            const float a = fabsf(in[s]);
            if (a > unit->binPeak) unit->binPeak = a;
            if ((idx % kWaveBinLen) == kWaveBinLen - 1) {
                unit->peaks[idx / kWaveBinLen] = unit->binPeak;
                unit->binPeak = 0.0f;
            }
        }
    }

    if (--unit->vizCountdown <= 0) {
        unit->vizCountdown = unit->vizEvery;
        float *m = unit->vizMsg;
        int n = kVizHeader;
        int active = 0;
        for (int g = 0; g < dirac::Dirac::kMaxGrains; ++g) {
            if (!d->isGrainActive(g)) continue;
            m[n++] = d->getGrainReadPos01(g);
            m[n++] = d->getGrainSpawnPos01(g);
            m[n++] = d->getGrainPitch(g);
            m[n++] = d->getGrainEnvelope(g);
            m[n++] = d->getGrainGain(g);
            m[n++] = d->getGrainPan(g);
            m[n++] = d->getGrainReverse(g) ? 1.0f : 0.0f;
            m[n++] = float(d->getGrainDuration(g));
            ++active;
        }
        m[0] = sampleMode ? 1.0f : 0.0f;
        m[1] = d->getFreezeOn() ? 1.0f : 0.0f;
        m[2] = float(d->getCapWritePos());        // < 2^24: exact in a float
        m[3] = (sampleMode && d->mEndIndex > 0) ? float(d->getPosition()) / float(d->mEndIndex) : 0.0f;
        m[4] = float(active);
        m[5] = d->getVizTexture();
        m[6] = (sampleMode && d->mEndIndex > 0) ? float(d->mEndIndex) : float(kRingSize);
        SendNodeReply(&unit->mParent->mNode, -1, "/dirac_viz", n, m);
    }

    if (--unit->waveCountdown <= 0) {
        unit->waveCountdown = unit->waveEvery;
        unit->waveMsg[0] = float(d->getCapWritePos());
        memcpy(unit->waveMsg + 1, unit->peaks, sizeof(unit->peaks));
        SendNodeReply(&unit->mParent->mNode, -1, "/dirac_wave", 1 + kWaveBins, unit->waveMsg);
    }

    // Ports borrow scsynth's wires, which are only valid inside this call.
    // Parking them stops a stale pointer from being reachable if the engine is
    // ever touched between blocks.
    for (int i = 0; i < kNumInlets; ++i)
        if (od::Port *p = portFor(d, i)) p->point(nullptr);
    d->mOutL.point(nullptr);
    d->mOutR.point(nullptr);
}

PluginLoad(Dirac)
{
    ft = inTable;
    DefineDtorUnit(Dirac);
}
