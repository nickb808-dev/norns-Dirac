// driver.cpp — run DiracUGen off-device and prove the wiring is right.
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
    // DiracUGen is a Unit subclass, so the host must give it storage of the
    // derived size — the same trick scsynth's DefineDtorUnit performs.
    std::vector<char>     storage;

    void build(int blockLen, bool fireAudioRate = true)
    {
        storage.assign(sizeof(DiracUGen), 0);
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

        DiracUGen *du = reinterpret_cast<DiracUGen *>(storage.data());
        du->mWorld      = nullptr;
        du->mNumInputs  = kNumInputs;
        du->mNumOutputs = 2;
        du->mBufLength  = blockLen;
        du->mInBuf      = inPtrs.data();
        du->mOutBuf     = outPtrs.data();
        du->mInput      = inputPtrs.data();
        du->mRate       = &rate;
        du->mCalcFunc   = nullptr;
    }

    DiracUGen *unit() { return reinterpret_cast<DiracUGen *>(storage.data()); }
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
struct CtlVal { int idx; float v; const char *name; };
static const CtlVal kCtls[] = {
    {kPlayhead,0.41f,"Playhead"}, {kRate,4.7f,"Rate"},       {kPosJtr,0.29f,"PosJtr"},
    {kSpread,0.63f,"Spread"},     {kDetune,0.7f,"Detune"},   {kLevel,0.83f,"Level"},
    {kRevProb,0.31f,"RevProb"},   {kPsprd,4.2f,"Psprd"},     {kTexture,0.37f,"Texture"},
    {kGrains,11.0f,"Grains"},     {kHold,0.0f,"Hold"},       {kSemiShift,3.0f,"SemiShift"},
    {kGrainLen,0.077f,"GrainLen"},{kMix,0.71f,"Mix"},        {kFeedback,0.42f,"Feedback"},
    {kCompress,0.53f,"Compress"}, {kBinaural,0.39f,"Binaural"},{kScale,2.0f,"Scale"},
    {kVoct,0.08f,"V/Oct"},        {kSpeed,0.9f,"Speed"},     {kHeads,3.0f,"Heads"},
    {kHeadSpread,0.47f,"HeadSpread"},{kHeadTune,5.0f,"HeadTune"},{kSnap,0.61f,"Snap"},
    {kColor,0.44f,"Color"},       {kTilt,0.66f,"Tilt"},      {kTiltSpread,0.28f,"TiltSpread"},
    {kWindow,3.0f,"Window"},
};
static const int kNumCtls = sizeof(kCtls) / sizeof(kCtls[0]);

static void setEnginePort(dirac::Dirac *d, int idx, float *buf) { portFor(d, idx)->point(buf); }

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
                          bool fireAudioRate = true)
{
    Host h;
    h.build(FRAMELENGTH, fireAudioRate);
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
        h.run(FRAMELENGTH);
        L.insert(L.end(), h.outBufs[0].begin(), h.outBufs[0].end());
        R.insert(R.end(), h.outBufs[1].begin(), h.outBufs[1].end());
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

    printf("DiracUGen wiring tests (FRAMELENGTH=%d)\n", (int)FRAMELENGTH);

    // 1. all inlets at once
    {
        std::vector<float> bL, bR, wL, wR;
        renderBare(bL, bR, 60, kCtls, kNumCtls, 0.0f);
        renderWrapped(wL, wR, 60, kCtls, kNumCtls, 0.0f);
        double md = 0;
        bool ok = same(bL, wL, &md);
        double md2 = 0; ok = ok && same(bR, wR, &md2);
        char d[128]; snprintf(d, sizeof d, "max|diff| L=%.3g R=%.3g", md, md2);
        report("wiring", ok, d);
        bool nonzero = false;
        for (float v : wL) if (v != 0.0f) { nonzero = true; break; }
        report("nonsilent", nonzero, nonzero ? "" : "wrapper produced pure silence");
    }

    // 2. one inlet at a time — catches transposed map entries that case 1 misses
    {
        int bad = 0; std::string names;
        for (int i = 0; i < kNumCtls; ++i) {
            std::vector<float> bL, bR, wL, wR;
            renderBare(bL, bR, 24, &kCtls[i], 1, 0.0f);
            renderWrapped(wL, wR, 24, &kCtls[i], 1, 0.0f);
            double md = 0, md2 = 0;
            if (!same(bL, wL, &md) || !same(bR, wR, &md2)) {
                ++bad;
                if (!names.empty()) names += ",";
                names += kCtls[i].name;
            }
        }
        char d[512];
        snprintf(d, sizeof d, bad ? "%d wrong: %s" : "%d inlets each verified alone",
                 bad ? bad : kNumCtls, bad ? names.c_str() : "");
        report("perinlet", bad == 0, d);
    }

    // 3. Fire as a control-rate wire — exercises the fan-out path
    {
        std::vector<float> bL, bR, wL, wR;
        renderBare(bL, bR, 40, kCtls, kNumCtls, 1.0f);
        renderWrapped(wL, wR, 40, kCtls, kNumCtls, 1.0f, /*fireAudioRate=*/false);
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

    // 5. pool exhaustion must degrade to silence, not to a crash or a shared
    //    engine — two units sharing one Dirac would sound plausible and be wrong
    {
        std::vector<Host *> hs;
        int live = 0;
        for (int i = 0; i < kPoolSize + 2; ++i) {
            Host *h = new Host(); h->build(FRAMELENGTH); h->ctor();
            if (h->unit()->live) ++live;
            hs.push_back(h);
        }
        bool distinct = true;
        for (size_t i = 0; i < hs.size(); ++i)
            for (size_t j = i + 1; j < hs.size(); ++j)
                if (hs[i]->unit()->live && hs[j]->unit()->live &&
                    hs[i]->unit()->engine == hs[j]->unit()->engine) distinct = false;
        for (auto *h : hs) { h->dtor(); delete h; }
        char d[128];
        snprintf(d, sizeof d, "%d of %d live, no engine shared", live, kPoolSize + 2);
        report("pool", live == kPoolSize && distinct, d);

        // and the pool must be reusable after those releases
        Host h; h.build(FRAMELENGTH); h.ctor();
        bool reusable = h.unit()->live;
        h.dtor();
        report("poolreuse", reusable, reusable ? "released slots came back" : "");
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

    printf("%s\n", gFails ? "FAILED" : ">>> DiracUGen: all wiring tests passed");
    return gFails ? 1 : 0;
}
