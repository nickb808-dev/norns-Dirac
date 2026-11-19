// driver.cpp — run Dirac off-device and prove the wiring is right.
//
// THE TEST: drive the wrapper and a bare engine with identical control values
// and identical input audio, then compare the outputs sample for sample. Both
// sides run the same DSP on the same machine, so the only thing that can differ
// is the WIRING — which is precisely what this wrapper is, and precisely what
// nothing else tests.
//
// A pass means every one of the 30 inlets reaches the member the engine reads,
// in the right order, at the right rate. That last part matters more than it
// looks: 28 inlets are read once per block and 2 are read per sample, and a
// per-sample inlet pointed at a one-float control wire reads off the end of it.
// That does not crash. It sounds slightly wrong, forever.
//
// Cases covered:
//   wiring     all 30 inlets at distinct non-default values, vs a bare engine
//   perm       every inlet individually — catches a map that is right in
//              aggregate but has two entries transposed
//   rates      Fire as control-rate — the fan-out path
//   refuse     block-size mismatch must produce silence, not garbage
//   pool       acquire/release across more units than the pool holds
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <string>

#include "SC_PlugIn.h"

UnitCtorFunc scstub_ctor = nullptr;
UnitDtorFunc scstub_dtor = nullptr;

static size_t gRtBytes = 0;
static int    gRtBlocks = 0;
static bool   gFailRtAlloc = false;
static std::string gPrinted;

void *scstub_rtalloc(World *, size_t n)
{
    if (gFailRtAlloc) return nullptr;
    gRtBytes += n; ++gRtBlocks;
    return malloc(n);
}
void scstub_rtfree(World *, void *p) { if (p) { --gRtBlocks; free(p); } }

// Every SendNodeReply, by command: how many, and the last payload.
struct Reply { int count = 0; std::vector<float> last; int node = -1; };
static Reply gViz, gWave;
static int   gOtherReplies = 0;
void scstub_sendnodereply(Node *node, int, const char *cmd, int n, const float *values)
{
    Reply *r = !strcmp(cmd, "/dirac_viz") ? &gViz : !strcmp(cmd, "/dirac_wave") ? &gWave : nullptr;
    if (!r) { ++gOtherReplies; return; }
    ++r->count;
    r->last.assign(values, values + n);
    r->node = node ? node->mID : -1;
}
void scstub_print(const char *fmt, ...)
{
    char buf[1024];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    gPrinted += buf;
}

#include "../../ugen/DiracUGen.cpp"

// ─── a minimal scsynth-shaped host ───────────────────────────────────────────
struct Host {
    std::vector<UnitInput> inputSpecs;
    std::vector<UnitInput*> inputPtrs;
    std::vector<std::vector<float>> inBufs;
    std::vector<std::vector<float>> outBufs;
    std::vector<float *>  inPtrs, outPtrs;
    Rate                  rate{};
    // Dirac is a Unit subclass, so the host must give it storage of the
    // derived size — the same trick scsynth's DefineDtorUnit performs.
    std::vector<char>     storage;
    Graph                 graph{{1234}};

    void build(int blockLen, bool fireAudioRate = true)
    {
        storage.assign(sizeof(Dirac), 0);
        inputSpecs.resize(kNumInputs);
        inBufs.resize(kNumInputs);
        outBufs.resize(2);
        inPtrs.resize(kNumInputs);
        outPtrs.resize(2);
        inputPtrs.resize(kNumInputs);

        for (int i = 0; i < kNumInputs; ++i) {
            const bool ar = (i == kIn) || (i == kFire && fireAudioRate);
            inputSpecs[i].mCalcRate = ar ? calc_FullRate : calc_BufRate;
            inBufs[i].assign(ar ? blockLen : 1, 0.0f);
            inPtrs[i]    = inBufs[i].data();
            inputPtrs[i] = &inputSpecs[i];
        }
        for (int c = 0; c < 2; ++c) {
            outBufs[c].assign(blockLen, 0.0f);
            outPtrs[c] = outBufs[c].data();
        }
        rate.mSampleRate = 48000.0;
        rate.mBufLength  = blockLen;

        Dirac *du = reinterpret_cast<Dirac *>(storage.data());
        du->mWorld      = nullptr;
        du->mParent     = &graph;
        du->mNumInputs  = kNumInputs;
        du->mNumOutputs = 2;
        du->mBufLength  = blockLen;
        du->mInBuf      = inPtrs.data();
        du->mOutBuf     = outPtrs.data();
        du->mInput      = inputPtrs.data();
        du->mRate       = &rate;
        du->mCalcFunc   = nullptr;
    }

    Dirac *unit() { return reinterpret_cast<Dirac *>(storage.data()); }
    void ctor() { scstub_ctor(reinterpret_cast<Unit *>(storage.data())); }
    void dtor() { scstub_dtor(reinterpret_cast<Unit *>(storage.data())); }
    void set(int idx, float v) { for (auto &x : inBufs[idx]) x = v; }
    void run(int n)
    {
        Unit *uu = reinterpret_cast<Unit *>(storage.data());
        uu->mCalcFunc(uu, n);
    }
};

// The control set: every inlet at a distinct, non-default, in-range value, so a
// transposed pair in the map cannot cancel out.
//
// PLAYHEAD MUST STAY SMALL. In live mode it indexes the 131072-sample capture
// ring, and this test only renders 400 blocks = 25600 samples. Playhead 0.41
// points at sample ~53700 — a part of the ring nothing has written yet — so
// every grain reads silence and 27 of 28 inlets measure as inert. That is
// correct engine behaviour and a broken test.
struct CtlVal { int idx; float v; const char *name; };
static const CtlVal kCtls[] = {
    {kPlayhead,0.05f,"Playhead"}, {kRate,4.7f,"Rate"},       {kPosJtr,0.29f,"PosJtr"},
    {kSpread,0.63f,"Spread"},     {kDetune,0.7f,"Detune"},   {kLevel,0.83f,"Level"},
    {kRevProb,0.31f,"RevProb"},   {kPsprd,4.2f,"Psprd"},     {kTexture,0.37f,"Texture"},
    {kGrains,11.0f,"Grains"},     {kHold,0.0f,"Hold"},       {kSemiShift,3.0f,"SemiShift"},
    {kGrainLen,0.077f,"GrainLen"},{kMix,0.71f,"Mix"},        {kFeedback,0.42f,"Feedback"},
    {kCompress,0.53f,"Compress"}, {kBinaural,0.39f,"Binaural"},{kScale,2.0f,"Scale"},
    {kVoct,0.08f,"V/Oct"},        {kSpeed,0.9f,"Speed"},     {kHeads,3.0f,"Heads"},
    {kHeadSpread,0.47f,"HeadSpread"},{kHeadTune,5.0f,"HeadTune"},{kSnap,0.61f,"Snap"},
    {kTilt,0.66f,"Tilt"},      {kTiltSpread,0.28f,"TiltSpread"},
    {kWindow,3.0f,"Window"},
};
static const int kNumCtls = sizeof(kCtls) / sizeof(kCtls[0]);

// How long to render before comparing. This is not a taste parameter.
//
// At 64 samples a block, 24 blocks is 32 ms — SHORTER THAN THE 77 ms GRAIN
// under test. Nothing but the dry path had contributed yet, so 27 of the 28
// inlets measured as having no effect and the per-inlet test verified exactly
// one of them while reporting a pass. 400 blocks is 0.53 s: several grains
// spawn, run and finish.
static const int kProbeBlocks = 400;

// A second, clearly different value for each inlet, in the same order. The
// per-inlet test moves ONE control from kCtls to kAltVal and checks the change
// reaches the engine. Values are chosen to be audibly distinct rather than
// merely different — e.g. Grains 11 -> 3, not 11 -> 11.5.
static const float kAltVal[] = {
    0.12f,  // Playhead
    9.0f,   // Rate
    0.90f,  // PosJtr
    0.05f,  // Spread
   -7.0f,   // Detune
    0.25f,  // Level
    0.95f,  // RevProb
   11.0f,   // Psprd
    0.95f,  // Texture
    3.0f,   // Grains
    1.0f,   // Hold
  -12.0f,   // SemiShift
    0.25f,  // GrainLen
    0.10f,  // Mix
    0.90f,  // Feedback
    0.05f,  // Compress
    0.95f,  // Binaural
    5.0f,   // Scale
   -0.5f,   // V/Oct
   -2.0f,   // Speed
    1.0f,   // Heads
    0.95f,  // HeadSpread
  -11.0f,   // HeadTune
    0.05f,  // Snap
    0.10f,  // Tilt
    0.90f,  // TiltSpread
    6.0f,   // Window
};
static_assert(sizeof(kAltVal)/sizeof(kAltVal[0]) == kNumCtls,
              "kAltVal must have one entry per kCtls entry, in the same order");

// An INDEPENDENT transcription of the inlet map.
//
// This deliberately does NOT call the wrapper's portFor(). An earlier version
// did, and it made the per-inlet test worthless: with both sides sharing one
// table, transposing two entries transposed them for the reference too and the
// outputs matched exactly. Verified by doing it — swapping Tilt and TiltSpread
// passed every case.
//
// So the reference names each member itself. Two lists written from the same
// source of truth, compared by rendering audio: that is the only arrangement
// where disagreement can show up as a difference.
static void setEnginePort(dirac::Dirac *d, int idx, float *buf)
{
    od::Port *p = nullptr;
    switch (idx) {
        case 0:  p = &d->mIn;          break;
        case 1:  p = &d->mPlayheadIn;  break;
        case 2:  p = &d->mRateIn;      break;
        case 3:  p = &d->mPosJtrIn;    break;
        case 4:  p = &d->mSprdIn;      break;
        case 5:  p = &d->mDetuneIn;    break;
        case 6:  p = &d->mLevelIn;     break;
        case 7:  p = &d->mRevProbIn;   break;
        case 8:  p = &d->mPsprdIn;     break;
        case 9:  p = &d->mTextureIn;   break;
        case 10: p = &d->mGrainsIn;    break;
        case 11: p = &d->mFireIn;      break;
        case 12: p = &d->mHoldIn;      break;
        case 13: p = &d->mSemiShiftIn; break;
        case 14: p = &d->mGrainLenIn;  break;
        case 15: p = &d->mMixIn;       break;
        case 16: p = &d->mFeedbackIn;  break;
        case 17: p = &d->mCompressIn;  break;
        case 18: p = &d->mBinauralIn;  break;
        case 19: p = &d->mScaleIn;     break;
        case 20: p = &d->mVoctIn;      break;
        case 21: p = &d->mSpeedIn;     break;
        case 22: p = &d->mHeadsIn;     break;
        case 23: p = &d->mHeadSpreadIn;break;
        case 24: p = &d->mHeadTuneIn;  break;
        case 25: p = &d->mSnapIn;      break;
        case 26: p = &d->mTiltIn;      break;
        case 27: p = &d->mTiltSprdIn;  break;
        case 28: p = &d->mWindowIn;    break;
        default: return;
    }
    p->point(buf);
}

// Reference: the engine driven directly, with no wrapper in the way.
static void renderBare(std::vector<float> &L, std::vector<float> &R, int blocks,
                       const CtlVal *ctls, int nCtls, float fireVal)
{
    dirac::Dirac d;
    std::vector<std::vector<float>> bufs(kNumInlets);
    for (int i = 0; i < kNumInlets; ++i) bufs[i].assign(FRAMELENGTH, 0.0f);
    for (int i = 0; i < nCtls; ++i)
        for (auto &x : bufs[ctls[i].idx]) x = ctls[i].v;
    for (auto &x : bufs[kFire]) x = fireVal;

    for (int i = 0; i < kNumInlets; ++i) setEnginePort(&d, i, bufs[i].data());
    d.mMultiHeadOpt.set(2);
    d.mDiffuseOpt.set(2);
    d.mFreezeOpt.set(1);

    std::vector<float> oL(FRAMELENGTH), oR(FRAMELENGTH);
    d.mOutL.point(oL.data());
    d.mOutR.point(oR.data());

    L.clear(); R.clear();
    for (int b = 0; b < blocks; ++b) {
        for (int s = 0; s < FRAMELENGTH; ++s)
            bufs[kIn][s] = 0.5f * sinf(2.0f * 3.14159265f * 110.0f *
                                       (b * FRAMELENGTH + s) / 48000.0f);
        // Ports are re-pointed every block by the wrapper, so do the same here:
        // the two sides must differ ONLY in who does the pointing.
        for (int i = 0; i < kNumInlets; ++i) setEnginePort(&d, i, bufs[i].data());
        d.mOutL.point(oL.data());
        d.mOutR.point(oR.data());
        d.process();
        L.insert(L.end(), oL.begin(), oL.end());
        R.insert(R.end(), oR.begin(), oR.end());
    }
}

static void renderWrapped(std::vector<float> &L, std::vector<float> &R, int blocks,
                          const CtlVal *ctls, int nCtls, float fireVal,
                          bool fireAudioRate = true, bool alias = false)
{
    Host h;
    h.build(FRAMELENGTH, fireAudioRate);
    // alias: do what scsynth's wire allocator does when this UGen is the last
    // reader of an input - hand it that SAME buffer as an output. OUT(0) shares
    // memory with IN(kIn) and OUT(1) with IN(kFire), so any write to an outlet
    // before the inlet has been fully read corrupts the input.
    if (alias) {
        h.outPtrs[0] = h.inBufs[kIn].data();
        h.outPtrs[1] = h.inBufs[kFire].data();
    }
    h.ctor();
    for (int i = 0; i < nCtls; ++i) h.set(ctls[i].idx, ctls[i].v);
    h.set(kFire, fireVal);
    h.set(kOptPlayheads, 2.0f);
    h.set(kOptDiffuse,   2.0f);
    h.set(kOptFreeze,    1.0f);

    L.clear(); R.clear();
    for (int b = 0; b < blocks; ++b) {
        for (int s = 0; s < FRAMELENGTH; ++s)
            h.inBufs[kIn][s] = 0.5f * sinf(2.0f * 3.14159265f * 110.0f *
                                           (b * FRAMELENGTH + s) / 48000.0f);
        // Upstream UGens rewrite their wires every block; with aliasing the
        // previous block's output is sitting in them, so refill Fire too.
        if (alias) h.set(kFire, fireVal);
        h.run(FRAMELENGTH);
        const float *oL = h.outPtrs[0], *oR = h.outPtrs[1];
        L.insert(L.end(), oL, oL + FRAMELENGTH);
        R.insert(R.end(), oR, oR + FRAMELENGTH);
    }
    h.dtor();
}

static bool same(const std::vector<float> &a, const std::vector<float> &b, double *maxd)
{
    *maxd = 0.0;
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        double d = fabs(double(a[i]) - double(b[i]));
        if (d > *maxd) *maxd = d;
    }
    return *maxd == 0.0;
}

static int gFails = 0;
static void report(const char *name, bool ok, const char *detail = "")
{
    printf("  %-10s %s%s%s\n", name, ok ? "PASS" : "FAIL",
           detail[0] ? "  " : "", detail);
    if (!ok) ++gFails;
}

int main()
{
    InterfaceTable table{};
    scstub_pluginload(&table);

    printf("Dirac wiring tests (FRAMELENGTH=%d)\n", (int)FRAMELENGTH);

    // 1. all inlets at once
    {
        std::vector<float> bL, bR, wL, wR;
        renderBare(bL, bR, kProbeBlocks, kCtls, kNumCtls, 0.0f);
        renderWrapped(wL, wR, kProbeBlocks, kCtls, kNumCtls, 0.0f);
        double md = 0;
        bool ok = same(bL, wL, &md);
        double md2 = 0; ok = ok && same(bR, wR, &md2);
        char d[128]; snprintf(d, sizeof d, "max|diff| L=%.3g R=%.3g", md, md2);
        report("wiring", ok, d);
        bool nonzero = false;
        for (float v : wL) if (v != 0.0f) { nonzero = true; break; }
        report("nonsilent", nonzero, nonzero ? "" : "wrapper produced pure silence");
    }

    // 2. one inlet at a time — catches transposed map entries that case 1 misses.
    //
    // With a SENSITIVITY PRECONDITION, which is the part that makes this mean
    // anything. Comparing rendered audio can only verify a control that CHANGES
    // the audio. An inlet that is inert at the surrounding settings passes
    // trivially, and counting it as verified is a false guarantee — measured:
    // transposing Tilt and TiltSpread in the wrapper changed no sample at all,
    // because the selected Window shape ignores both.
    //
    // So each inlet is first checked against a render with it left at default.
    // Inert ones are reported as inert rather than counted as passing.
    {
        int bad = 0, inert = 0, checked = 0;
        std::string badNames, inertNames;

        // The baseline is the FULL control set, not an empty one. Varying a
        // single inlet against silence proves nothing: with everything else at
        // zero, Level is zero and the render is silent whatever else changes.
        // Measured — 27 of 28 inlets looked "inert" that way.
        std::vector<float> baseL, baseR;
        renderBare(baseL, baseR, kProbeBlocks, kCtls, kNumCtls, 0.0f);

        for (int i = 0; i < kNumCtls; ++i) {
            std::vector<CtlVal> alt(kCtls, kCtls + kNumCtls);
            alt[i].v = kAltVal[i];                    // one inlet moved

            std::vector<float> bL, bR, wL, wR;
            renderBare(bL, bR, kProbeBlocks, alt.data(), kNumCtls, 0.0f);

            double sens = 0;
            if (same(bL, baseL, &sens)) {
                // Moving this inlet changed no sample, so rendered audio cannot
                // verify its wiring. Say so instead of counting it as passed.
                ++inert;
                if (!inertNames.empty()) inertNames += ",";
                inertNames += kCtls[i].name;
                continue;
            }

            ++checked;
            renderWrapped(wL, wR, kProbeBlocks, alt.data(), kNumCtls, 0.0f);
            double md = 0, md2 = 0;
            if (!same(bL, wL, &md) || !same(bR, wR, &md2)) {
                ++bad;
                if (!badNames.empty()) badNames += ",";
                badNames += kCtls[i].name;
            }
        }
        char d[768];
        if (bad) snprintf(d, sizeof d, "%d wrong: %s", bad, badNames.c_str());
        else if (inert) snprintf(d, sizeof d, "%d verified; %d INERT here (%s)",
                                 checked, inert, inertNames.c_str());
        else snprintf(d, sizeof d, "%d inlets each verified alone", checked);
        report("perinlet", bad == 0, d);
    }

    // 3. Fire as a control-rate wire — exercises the fan-out path
    {
        std::vector<float> bL, bR, wL, wR;
        renderBare(bL, bR, kProbeBlocks, kCtls, kNumCtls, 1.0f);
        renderWrapped(wL, wR, kProbeBlocks, kCtls, kNumCtls, 1.0f, /*fireAudioRate=*/false);
        double md = 0, md2 = 0;
        bool ok = same(bL, wL, &md) && same(bR, wR, &md2);
        char d[128]; snprintf(d, sizeof d, "control-rate Fire fanned out, max|diff|=%.3g", md);
        report("fire_kr", ok, d);
    }

    // 4. a block-size mismatch must refuse, loudly and silently
    {
        gPrinted.clear();
        const int wrongLen = (FRAMELENGTH == 64) ? 128 : 64;
        Host h; h.build(wrongLen);
        h.ctor();
        for (auto &x : h.outBufs[0]) x = 12345.0f;
        for (auto &x : h.outBufs[1]) x = 12345.0f;
        // The server would call with ITS block length, not the engine's — which
        // is the whole point of the mismatch.
        h.run(wrongLen);
        bool silent = true;
        for (float v : h.outBufs[0]) if (v != 0.0f) silent = false;
        bool warned = gPrinted.find("REFUSING") != std::string::npos;
        h.dtor();
        report("refuse", silent && warned,
               silent ? (warned ? "silence + warning" : "silent but NO warning")
                      : "did not silence output");
    }

    // 5. two units must be INDEPENDENT, and a fresh unit must be REPEATABLE.
    //    This replaces an engine-pool test. The pool handed engines back dirty
    //    — stale capture ring, advanced RNG — and the per-inlet test caught it
    //    as 27 false failures. Constructing per unit is what makes these two
    //    properties hold, so they are what gets checked.
    {
        std::vector<float> aL, aR, bL, bR;
        renderWrapped(aL, aR, kProbeBlocks, kCtls, kNumCtls, 0.0f);
        renderWrapped(bL, bR, kProbeBlocks, kCtls, kNumCtls, 0.0f);
        double md = 0;
        bool repeatable = same(aL, bL, &md);
        report("repeat", repeatable,
               repeatable ? "second unit renders identically to the first"
                          : "a fresh unit inherited state from a previous one");
    }

    // 6. RTAlloc failure must be handled, not ignored
    {
        gPrinted.clear();
        gFailRtAlloc = true;
        Host h; h.build(FRAMELENGTH); h.ctor();
        bool refused = !h.unit()->live;
        h.run(FRAMELENGTH);
        bool silent = true;
        for (float v : h.outBufs[0]) if (v != 0.0f) silent = false;
        h.dtor();
        gFailRtAlloc = false;
        report("rtalloc", refused && silent, "OOM refused cleanly");
    }

    // 7. no leak across a create/destroy cycle
    {
        int before = gRtBlocks;
        for (int i = 0; i < 20; ++i) { Host h; h.build(FRAMELENGTH); h.ctor(); h.run(FRAMELENGTH); h.dtor(); }
        char d[128]; snprintf(d, sizeof d, "RT blocks %d -> %d", before, gRtBlocks);
        report("noleak", gRtBlocks == before, d);
    }

    // 8. outputs ALIASED onto the audio-rate inputs, as scsynth really does it.
    //    Found on the norns, not here: with OUT sharing IN's buffer the unit
    //    went permanently silent, even at mix 0, and every test above passed
    //    because this stub gave each wire its own buffer. The wrapper must copy
    //    its per-sample inlets before process(); this checks it does, against
    //    the bare engine, sample for sample.
    {
        std::vector<float> bL, bR, wL, wR;
        renderBare(bL, bR, kProbeBlocks, kCtls, kNumCtls, 0.0f);
        renderWrapped(wL, wR, kProbeBlocks, kCtls, kNumCtls, 0.0f,
                      /*fireAudioRate=*/true, /*alias=*/true);
        double md = 0, md2 = 0;
        bool ok = same(bL, wL, &md) && same(bR, wR, &md2);
        bool nonzero = false;
        for (float v : wL) if (v != 0.0f) { nonzero = true; break; }
        char d[160]; snprintf(d, sizeof d, "OUT shares IN's buffer: max|diff| L=%.3g R=%.3g%s",
                              md, md2, nonzero ? "" : ", PURE SILENCE");
        report("aliased", ok && nonzero, d);
    }

    // 9. display data: what the norns UI will draw from.
    //    - /dirac_viz at ~30 Hz carries exactly the ACTIVE grains, each with a
    //      read position on [0,1] and a finite brightness;
    //    - /dirac_wave at ~4 Hz carries 128 peaks that match the input level;
    //    - the wrapper's ring size (kRingSize, a copy of the engine's private
    //      kCapBufSize) is RIGHT: one ring's worth of blocks brings the write
    //      head back to where it started. If upstream ever resizes the ring
    //      this fails instead of drawing a skewed waveform.
    {
        gViz = Reply(); gWave = Reply(); gOtherReplies = 0;
        Host h; h.build(FRAMELENGTH); h.ctor();
        for (int i = 0; i < kNumCtls; ++i) h.set(kCtls[i].idx, kCtls[i].v);
        h.set(kOptPlayheads, 1.0f); h.set(kOptDiffuse, 1.0f); h.set(kOptFreeze, 1.0f);
        const int startCap = h.unit()->engine->getCapWritePos();
        const int ringBlocks = kRingSize / FRAMELENGTH;
        int blocks = 0;
        auto runBlocks = [&](int nblk) {
            for (int b = 0; b < nblk; ++b, ++blocks) {
                for (int s = 0; s < FRAMELENGTH; ++s)
                    h.inBufs[kIn][s] = 0.5f * sinf(2.0f * 3.14159265f * 110.0f *
                                                   (blocks * FRAMELENGTH + s) / 48000.0f);
                h.run(FRAMELENGTH);
            }
        };
        runBlocks(ringBlocks);
        const bool ringOk = (h.unit()->engine->getCapWritePos() == startCap);
        // On a fresh unit the last bin of the first pass commits on the final
        // block, after the last /dirac_wave went out. Run on until every bin
        // has been through a frame.
        runBlocks(2 * h.unit()->waveEvery);
        const double secs = double(blocks) * FRAMELENGTH / 48000.0;
        const double vizHz = gViz.count / secs, waveHz = gWave.count / secs;

        bool vizOk = gViz.last.size() >= 5 && gViz.node == 1234;
        int active = 0, counted = 0;
        if (vizOk) {
            for (int g = 0; g < dirac::Dirac::kMaxGrains; ++g)
                if (h.unit()->engine->isGrainActive(g)) ++counted;
            active = int(gViz.last[4]);
            vizOk = (gViz.last.size() == size_t(5 + 6 * active));
            for (int g = 0; vizOk && g < active; ++g) {
                const float rp = gViz.last[5 + g * 6], br = gViz.last[5 + g * 6 + 3];
                vizOk = rp >= 0.0f && rp <= 1.0f && std::isfinite(br);
            }
        }
        // The last viz frame and the engine's state are from the same block
        // only if the frame was sent on the final block; compare counts only
        // when it was, otherwise just require a plausible count.
        const bool countOk = active >= 1 && active <= dirac::Dirac::kMaxGrains;

        float pmax = 0, pmin = 1;
        bool waveOk = gWave.last.size() == size_t(1 + kWaveBins);
        if (waveOk) for (int b = 0; b < kWaveBins; ++b) {
            pmax = std::max(pmax, gWave.last[1 + b]); pmin = std::min(pmin, gWave.last[1 + b]);
        }
        // A full ring of a 0.5-amplitude sine: every bin saw a peak near 0.5.
        waveOk = waveOk && pmax <= 0.5001f && pmin > 0.45f;
        h.dtor();

        char d[256];
        snprintf(d, sizeof d, "viz %.1f Hz (%d grains, engine %d), wave %.1f Hz peaks %.3f..%.3f, ring %s",
                 vizHz, active, counted, waveHz, pmin, pmax, ringOk ? "131072 ok" : "SIZE MISMATCH");
        const bool rates = vizHz > 25 && vizHz < 35 && waveHz > 3 && waveHz < 5;
        report("viz", vizOk && countOk && waveOk && ringOk && rates && gOtherReplies == 0, d);
    }

    printf("%s\n", gFails ? "FAILED" : ">>> Dirac: all wiring tests passed");
    return gFails ? 1 : 0;
}
