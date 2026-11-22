// varia_driver.cpp - run the Varia filter UGen off-device and prove the wiring.
//
// Same method as driver.cpp: the wrapper and a bare varia::Filter get
// identical inputs; same DSP, same machine, so any difference is the WIRING.
//
// Cases:
//   wiring    noise through every control moving, vs a bare filter: identical
//   aliased   OUT(0) on IN(R) and OUT(1) on IN(L), as scsynth may wire it
//   garbage   the unit's memory full of junk before the Ctor (scsynth does not
//             zero it): output identical to a fresh filter
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <cstdarg>
#include <vector>
#include <string>

#include "SC_PlugIn.h"

UnitCtorFunc scstub_ctor = nullptr;
UnitDtorFunc scstub_dtor = nullptr;
void *scstub_rtalloc(World *, size_t n) { return malloc(n); }
void  scstub_rtfree(World *, void *p) { free(p); }
void  scstub_sendnodereply(Node *, int, const char *, int, const float *) {}
void  scstub_print(const char *, ...) {}

#include "../../ugen/VariaUGen.cpp"

static const int B = 64;
static int gFails = 0;
static void report(const char *name, bool ok, const char *detail)
{
    printf("  %s %-8s %s\n", ok ? "ok  " : "FAIL", name, detail);
    if (!ok) ++gFails;
}
static uint32_t rng = 777;
static float noise() { rng = rng * 1664525u + 1013904223u; return (float(rng >> 8) / 8388608.0f) - 1.0f; }

struct Host {
    std::vector<UnitInput> specs; std::vector<UnitInput *> specPtrs;
    std::vector<std::vector<float>> inBufs, outBufs;
    std::vector<float *> inPtrs, outPtrs;
    std::vector<char> storage;
    Rate rate{}; Graph graph{{7}}; World world{0, nullptr};
    void build(unsigned char fill)
    {
        storage.assign(sizeof(Varia), (char)fill);
        specs.resize(kNumInputs); specPtrs.resize(kNumInputs);
        inBufs.resize(kNumInputs); inPtrs.resize(kNumInputs);
        outBufs.assign(2, std::vector<float>(B, 0.0f));
        outPtrs = { outBufs[0].data(), outBufs[1].data() };
        for (int i = 0; i < kNumInputs; ++i) {
            const bool ar = (i == kInL || i == kInR);
            specs[i].mCalcRate = ar ? calc_FullRate : calc_BufRate;
            inBufs[i].assign(ar ? B : 1, 0.0f);
            inPtrs[i] = inBufs[i].data(); specPtrs[i] = &specs[i];
        }
        rate.mSampleRate = 48000; rate.mBufLength = B;
        Unit *u = reinterpret_cast<Unit *>(storage.data());
        u->mWorld = &world; u->mParent = &graph;
        u->mNumInputs = kNumInputs; u->mNumOutputs = 2; u->mBufLength = B;
        u->mInBuf = inPtrs.data(); u->mOutBuf = outPtrs.data();
        u->mInput = specPtrs.data(); u->mRate = &rate;
    }
    void ctor() { scstub_ctor(reinterpret_cast<Unit *>(storage.data())); }
    void run() { Unit *u = reinterpret_cast<Unit *>(storage.data()); u->mCalcFunc(u, B); }
};

// the control scenario at block b
static void controls(int b, float *c)
{
    c[0] = 60.0f * powf(2.0f, 8.0f * (0.5f + 0.5f * sinf(b * 0.011f)));   // freq
    c[1] = 0.5f + 0.5f * sinf(b * 0.007f);                               // width
    c[2] = 0.5f + 0.45f * sinf(b * 0.005f);                              // res
    c[3] = 0.5f + 0.5f * sinf(b * 0.003f);                               // type
    c[4] = (b / 300) % 2 ? 0.7f : 0.0f;                                  // peaks
    c[5] = sinf(b * 0.002f);                                             // phase
}
static void setBare(varia::Filter &f, const float *c)
{ f.freq = c[0]; f.width = c[1]; f.res = c[2]; f.type = c[3]; f.peaks = c[4]; f.phase = c[5]; }

static long runCase(bool alias, unsigned char fill, double *peak)
{
    Host h; h.build(fill); h.ctor();
    if (alias) { h.outPtrs[0] = h.inPtrs[kInR]; h.outPtrs[1] = h.inPtrs[kInL]; }
    varia::Filter bare;
    std::vector<float> l(B), r(B), ol(B), orr(B);
    long diffs = 0; *peak = 0;
    rng = 777;
    for (int b = 0; b < 3000; ++b) {
        float c[6]; controls(b, c); setBare(bare, c);
        for (int k = 0; k < 6; ++k) h.inBufs[kFreq + k][0] = c[k];
        for (int s = 0; s < B; ++s) { l[s] = h.inBufs[kInL][s] = 0.3f * noise(); r[s] = h.inBufs[kInR][s] = 0.3f * noise(); }
        h.run();
        bare.process(l.data(), r.data(), ol.data(), orr.data(), B);
        for (int s = 0; s < B; ++s) {
            if (h.outPtrs[0][s] != ol[s] || h.outPtrs[1][s] != orr[s]) ++diffs;
            *peak = fmax(*peak, fabs(ol[s]));
        }
    }
    return diffs;
}

int main()
{
    scstub_pluginload(nullptr);
    char d[200]; double pk;
    long n = runCase(false, 0, &pk);
    snprintf(d, sizeof d, "3000 blocks, every control moving: %ld samples differ from a bare filter (peak %.2f)", n, pk);
    report("wiring", n == 0 && pk > 0.01, d);
    n = runCase(true, 0, &pk);
    snprintf(d, sizeof d, "outputs on the opposite input wires: %ld samples differ", n);
    report("aliased", n == 0, d);
    n = runCase(false, 0xA5, &pk);
    snprintf(d, sizeof d, "unit memory filled with 0xA5 before the Ctor: %ld samples differ", n);
    report("garbage", n == 0, d);
    printf(gFails ? ">>> Varia: %d wiring test(s) FAILED\n" : ">>> Varia: all wiring tests passed\n", gFails);
    return gFails ? 1 : 0;
}
