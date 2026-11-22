// noether_driver.cpp — run the Noether UGen off-device and prove the wiring.
//
// Same method as driver.cpp (Dirac): drive the wrapper and a bare engine with
// identical inputs and compare sample for sample. Same DSP, same machine, so
// anything that differs is the WIRING.
//
// Cases:
//   wiring    a scripted session through every inlet (rec, close, speed,
//             sos, dry, level, dub, undo, stop, extend, clk) vs a bare engine:
//             outputs AND the loop buffer must be identical
//   aliased   OUT(0)/OUT(1) share IN(L)/IN(R)'s buffers, as scsynth may do
//   ctlrate   the triggers as control-rate wires (fan-out path) still work
//   nobuf     no loop buffer (bufnum -1): the unit is a wire
//   viz       /noether_viz rate and payload; the envelope sees the loop
//   clear     a clear edge empties the loop and zeroes the buffer
//   swap      a different loop buffer resets to EMPTY
//   refuse    a block-size mismatch outputs silence
//   noleak    every RT allocation is freed
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

static int  gRtBlocks = 0;
static std::string gPrinted;
void *scstub_rtalloc(World *, size_t n) { ++gRtBlocks; return malloc(n); }
void  scstub_rtfree(World *, void *p) { if (p) { --gRtBlocks; free(p); } }

struct Reply { int count = 0; std::vector<float> last; };
static Reply gViz;
static int   gOther = 0;
void scstub_sendnodereply(Node *, int, const char *cmd, int n, const float *values)
{
    if (strcmp(cmd, "/noether_viz")) { ++gOther; return; }
    ++gViz.count;
    gViz.last.assign(values, values + n);
}
void scstub_print(const char *fmt, ...)
{
    char buf[1024];
    va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    gPrinted += buf;
}

#include "../../ugen/NoetherUGen.cpp"

static const int kSR = 48000;
static const int kLoopFrames = kSR * 4;     // a 4 s stereo loop buffer

// ─── a scsynth-shaped host ───────────────────────────────────────────────────
struct Host {
    std::vector<UnitInput> specs;
    std::vector<UnitInput *> specPtrs;
    std::vector<std::vector<float>> inBufs, outBufs;
    std::vector<float *> inPtrs, outPtrs;
    std::vector<char> storage;
    std::vector<SndBuf> sndbufs;
    std::vector<std::vector<float>> bufData;
    Rate  rate{};
    Graph graph{{7}};
    World world{0, nullptr};

    // buffers 0 and 1: loop and undo (stereo); 2: a second loop buffer
    void build(int blockLen, bool trigAudioRate = true)
    {
        bufData.assign(3, std::vector<float>((size_t)kLoopFrames * 2, 0.0f));
        sndbufs.assign(3, SndBuf{});
        for (int i = 0; i < 3; ++i) {
            sndbufs[i].data = bufData[i].data();
            sndbufs[i].channels = 2;
            sndbufs[i].frames = kLoopFrames;
            sndbufs[i].samples = kLoopFrames * 2;
            sndbufs[i].samplerate = kSR;
        }
        world.mNumSndBufs = 3;
        world.mSndBufs = sndbufs.data();

        storage.assign(sizeof(Noether), 0);
        specs.resize(kNumInputs); specPtrs.resize(kNumInputs);
        inBufs.resize(kNumInputs); inPtrs.resize(kNumInputs);
        outBufs.assign(2, std::vector<float>(blockLen, 0.0f));
        outPtrs = { outBufs[0].data(), outBufs[1].data() };
        for (int i = 0; i < kNumInputs; ++i) {
            const bool trig = (i == kRec || i == kDub || i == kUndo || i == kClk);
            const bool ar = (i == kInL || i == kInR) || (trig && trigAudioRate);
            specs[i].mCalcRate = ar ? calc_FullRate : calc_BufRate;
            inBufs[i].assign(ar ? blockLen : 1, 0.0f);
            inPtrs[i] = inBufs[i].data();
            specPtrs[i] = &specs[i];
        }
        set(kSpeed, 1.0f); set(kSos, 0.5f); set(kDry, 1.0f); set(kLevel, 1.0f);
        set(kOptSync, 1.0f); set(kBuf, 0.0f); set(kUndoBuf, 1.0f);
        rate.mSampleRate = kSR;
        rate.mBufLength = blockLen;
        Unit *u = reinterpret_cast<Unit *>(storage.data());
        u->mWorld = &world; u->mParent = &graph;
        u->mNumInputs = kNumInputs; u->mNumOutputs = 2;
        u->mBufLength = blockLen;
        u->mInBuf = inPtrs.data(); u->mOutBuf = outPtrs.data();
        u->mInput = specPtrs.data(); u->mRate = &rate;
    }
    Noether *unit() { return reinterpret_cast<Noether *>(storage.data()); }
    void ctor() { scstub_ctor(reinterpret_cast<Unit *>(storage.data())); }
    void dtor() { scstub_dtor(reinterpret_cast<Unit *>(storage.data())); }
    void set(int i, float v) { for (auto &x : inBufs[i]) x = v; }
    void run() { Unit *u = reinterpret_cast<Unit *>(storage.data()); u->mCalcFunc(u, rate.mBufLength); }
};

// ─── the scripted session ────────────────────────────────────────────────────
// Per block: control values and trigger pulses. Times are in blocks of 64.
struct Step { float speed, sos, dry, level, stop, ext; int recAt, dubAt, undoAt, clkAt; };
static Step script(int b)
{
    Step s{1.0f, 0.5f, 1.0f, 1.0f, 0.0f, 0.0f, -1, -1, -1, -1};
    if (b == 10)  s.recAt = 17;           // start a take
    if (b == 800) s.recAt = 40;           // close (~1.06 s loop)
    if (b >= 1000 && b < 1300) s.speed = -0.5f;    // reverse, half speed
    if (b >= 1300 && b < 1500) s.speed = 1.5f;
    if (b == 1500) s.recAt = 3;           // overdub in
    if (b >= 1500 && b < 1900) { s.sos = 0.3f; s.dry = 0.6f; }
    if (b == 1900) s.dubAt = 9;           // overdub out (the DUB button)
    if (b == 2000) s.undoAt = 0;          // undo that pass
    if (b >= 2100 && b < 2300) s.stop = 1.0f;
    if (b >= 2300) s.level = 0.7f;
    if (b == 2400) { s.recAt = 11; }      // overdub with extend latched...
    if (b >= 2400 && b < 3400) s.ext = 1.0f;
    if (b == 3400) s.recAt = 50;          // ...close the extension
    if (b == 3600) s.clkAt = 5;           // free mode: restart from the seam
    return s;
}
static const int kScriptBlocks = 3800;

static float srcL(long t) { return 0.5f * sinf(2.0f * 3.14159265f * 220.0f * t / kSR); }
static float srcR(long t) { return 0.4f * sinf(2.0f * 3.14159265f * 331.0f * t / kSR + 0.7f); }

static void renderBare(std::vector<float> &L, std::vector<float> &R, std::vector<float> &buf)
{
    noether::Noether e(2);
    std::vector<float> data((size_t)kLoopFrames * 2, 0.0f), undo((size_t)kLoopFrames * 2, 0.0f);
    od::Sample s, u;
    s.mpData = data.data(); s.mSampleCount = s.mSampleLoadCount = kLoopFrames; s.mChannelCount = 2;
    u.mpData = undo.data(); u.mSampleCount = u.mSampleLoadCount = kLoopFrames; u.mChannelCount = 2;
    e.setSample(&s); e.setUndoSample(&u);
    float in[14][FRAMELENGTH], oL[FRAMELENGTH], oR[FRAMELENGTH];
    od::Port *ports[14] = { &e.mLeftIn, &e.mRightIn, &e.mRecIn, &e.mDubIn, &e.mStopIn, &e.mUndoIn,
                            &e.mClkIn, &e.mSpeedIn, &e.mVoctIn, &e.mExtIn, &e.mBarsIn,
                            &e.mSosIn, &e.mDryIn, &e.mLevelIn };
    for (int i = 0; i < 14; ++i) ports[i]->point(in[i]);
    e.mLeftOut.point(oL); e.mRightOut.point(oR);
    long t = 0;
    for (int b = 0; b < kScriptBlocks; ++b) {
        const Step st = script(b);
        for (int i = 0; i < FRAMELENGTH; ++i, ++t) {
            in[0][i] = srcL(t); in[1][i] = srcR(t);
            in[2][i] = (st.recAt >= 0 && i >= st.recAt && i < st.recAt + 4) ? 1.0f : 0.0f;
            in[3][i] = (st.dubAt >= 0 && i >= st.dubAt && i < st.dubAt + 4) ? 1.0f : 0.0f;
            in[4][i] = st.stop;
            in[5][i] = (st.undoAt >= 0 && i >= st.undoAt && i < st.undoAt + 4) ? 1.0f : 0.0f;
            in[6][i] = (st.clkAt >= 0 && i >= st.clkAt && i < st.clkAt + 4) ? 1.0f : 0.0f;
            in[7][i] = st.speed; in[8][i] = 0.0f; in[9][i] = st.ext; in[10][i] = 0.0f;
            in[11][i] = st.sos; in[12][i] = st.dry; in[13][i] = st.level;
        }
        e.process();
        L.insert(L.end(), oL, oL + FRAMELENGTH);
        R.insert(R.end(), oR, oR + FRAMELENGTH);
    }
    buf = data;
    e.setUndoSample(nullptr); e.setSample(nullptr);
}

static void renderWrapped(std::vector<float> &L, std::vector<float> &R, std::vector<float> &buf,
                          bool alias, bool trigAudioRate = true, int *finalState = nullptr)
{
    Host h;
    h.build(FRAMELENGTH, trigAudioRate);
    if (alias) { h.outPtrs[0] = h.inBufs[kInL].data(); h.outPtrs[1] = h.inBufs[kInR].data(); }
    h.ctor();
    long t = 0;
    for (int b = 0; b < kScriptBlocks; ++b) {
        const Step st = script(b);
        for (int i = 0; i < FRAMELENGTH; ++i) { h.inBufs[kInL][i] = srcL(t + i); h.inBufs[kInR][i] = srcR(t + i); }
        auto pulse = [&](int idx, int at) {
            if (trigAudioRate) {
                for (int i = 0; i < FRAMELENGTH; ++i) h.inBufs[idx][i] = (at >= 0 && i >= at && i < at + 4) ? 1.0f : 0.0f;
            } else {
                h.inBufs[idx][0] = at >= 0 ? 1.0f : 0.0f;   // a t_ control: high for one block
            }
        };
        pulse(kRec, st.recAt); pulse(kDub, st.dubAt); pulse(kUndo, st.undoAt); pulse(kClk, st.clkAt);
        h.set(kStop, st.stop); h.set(kSpeed, st.speed); h.set(kExt, st.ext);
        h.set(kSos, st.sos); h.set(kDry, st.dry); h.set(kLevel, st.level);
        h.run();
        L.insert(L.end(), h.outPtrs[0], h.outPtrs[0] + FRAMELENGTH);
        R.insert(R.end(), h.outPtrs[1], h.outPtrs[1] + FRAMELENGTH);
        t += FRAMELENGTH;
    }
    buf = h.bufData[0];
    if (finalState) *finalState = h.unit()->engine ? h.unit()->engine->getState() : -1;
    h.dtor();
}

static double maxDiff(const std::vector<float> &a, const std::vector<float> &b)
{
    if (a.size() != b.size()) return 1e9;
    double m = 0; for (size_t i = 0; i < a.size(); ++i) m = fmax(m, fabs((double)a[i] - b[i]));
    return m;
}

static int gFails = 0;
static void report(const char *name, bool ok, const char *detail)
{
    printf("  %-9s %s  %s\n", name, ok ? "PASS" : "FAIL", detail);
    if (!ok) ++gFails;
}

int main()
{
    InterfaceTable table{};
    scstub_pluginload(&table);
    printf("Noether wiring tests (FRAMELENGTH=%d)\n", (int)FRAMELENGTH);
    char d[512];

    std::vector<float> bL, bR, bBuf;
    renderBare(bL, bR, bBuf);
    double peak = 0; for (float v : bL) peak = fmax(peak, fabs(v));

    {   // wiring
        std::vector<float> L, R, B; int st = -1;
        renderWrapped(L, R, B, false, true, &st);
        const double dl = maxDiff(L, bL), dr = maxDiff(R, bR), db = maxDiff(B, bBuf);
        double bufPeak = 0; for (float v : B) bufPeak = fmax(bufPeak, fabs(v));
        snprintf(d, sizeof d, "scripted session vs bare engine: max|diff| L=%g R=%g buffer=%g (out peak %.3f, loop peak %.3f, end state %d)",
                 dl, dr, db, peak, bufPeak, st);
        report("wiring", dl == 0 && dr == 0 && db == 0 && bufPeak > 0.1 && st == 2, d);
    }
    {   // aliased
        std::vector<float> L, R, B;
        renderWrapped(L, R, B, true);
        const double dl = maxDiff(L, bL), dr = maxDiff(R, bR);
        snprintf(d, sizeof d, "OUT shares IN's buffers: max|diff| L=%g R=%g", dl, dr);
        report("aliased", dl == 0 && dr == 0, d);
    }
    {   // control-rate triggers
        std::vector<float> L, R, B; int st = -1;
        renderWrapped(L, R, B, false, false, &st);
        double bufPeak = 0; for (float v : B) bufPeak = fmax(bufPeak, fabs(v));
        snprintf(d, sizeof d, "triggers as t_ controls: loop recorded (peak %.3f), end state %d", bufPeak, st);
        report("ctlrate", bufPeak > 0.1 && st == 2, d);
    }
    {   // no buffer: a wire
        Host h; h.build(FRAMELENGTH); h.set(kBuf, -1.0f); h.set(kUndoBuf, -1.0f); h.ctor();
        double md = 0;
        for (int b = 0; b < 50; ++b) {
            for (int i = 0; i < FRAMELENGTH; ++i) { h.inBufs[kInL][i] = srcL(b * FRAMELENGTH + i); h.inBufs[kInR][i] = srcR(b * FRAMELENGTH + i); }
            std::vector<float> iL(h.inBufs[kInL]), iR(h.inBufs[kInR]);
            h.inBufs[kRec][3] = (b == 5) ? 1.0f : 0.0f;
            h.run();
            for (int i = 0; i < FRAMELENGTH; ++i) md = fmax(md, fmax(fabs(h.outPtrs[0][i] - iL[i]), fabs(h.outPtrs[1][i] - iR[i])));
        }
        const int st = h.unit()->engine->getState();
        h.dtor();
        snprintf(d, sizeof d, "bufnum -1: output = input (max|diff| %g), rec ignored (state %d)", md, st);
        report("nobuf", md == 0 && st == 0, d);
    }
    {   // viz + clear + swap
        gViz = Reply();
        Host h; h.build(FRAMELENGTH); h.ctor();
        long t = 0;
        auto blocks = [&](int n, int recAt = -1) {
            for (int k = 0; k < n; ++k) {
                for (int i = 0; i < FRAMELENGTH; ++i, ++t) {
                    h.inBufs[kInL][i] = srcL(t); h.inBufs[kInR][i] = srcR(t);
                    h.inBufs[kRec][i] = (k == 0 && recAt >= 0 && i >= recAt && i < recAt + 4) ? 1.0f : 0.0f;
                }
                h.run();
            }
        };
        blocks(10); blocks(1, 5); blocks(1000); blocks(1, 7);   // a ~1.3 s loop
        gViz.count = 0;
        blocks(750);                                            // 1 s of playing
        const int perSec = gViz.count;
        const std::vector<float> m = gViz.last;
        const bool sizeOk = (int)m.size() == kVizHeader + kEnvBins;
        int filled = 0; for (int i = 0; i < kEnvBins && sizeOk; ++i) if (m[kVizHeader + i] > 0.3f) ++filled;
        const noether::Noether *e = h.unit()->engine;
        const bool headerOk = sizeOk && (int)m[0] == 2 && (int)m[1] == const_cast<noether::Noether *>(e)->getLoopSamples()
                              && m[1] > 48000 && m[2] >= 0 && m[2] < m[1] && fabsf(m[5] - 1.0f) < 1e-3f
                              && (int)m[6] == 1 && (int)m[7] == 8 && (int)m[11] == kLoopFrames;
        snprintf(d, sizeof d, "%d Hz, %d floats, state %.0f, loop %.0f, pos %.0f, speed %.3f, detent %.0f, sections %.0f, cap %.0f, envelope %d/%d bins filled",
                 perSec, (int)m.size(), m.empty() ? -1.0 : m[0], m.size() > 1 ? m[1] : -1.0, m.size() > 2 ? m[2] : -1.0,
                 m.size() > 5 ? m[5] : 0.0, m.size() > 6 ? m[6] : 0.0, m.size() > 7 ? m[7] : 0.0, m.size() > 11 ? m[11] : 0.0, filled, kEnvBins);
        report("viz", perSec >= 28 && perSec <= 32 && headerOk && filled == kEnvBins, d);

        // clear: rising edge -> EMPTY, buffer zeroed
        h.set(kClear, 1.0f); blocks(1); h.set(kClear, 0.0f);
        blocks(800);
        const int stC = h.unit()->engine->getState();
        double left = 0; for (float v : h.bufData[0]) left = fmax(left, fabs(v));
        snprintf(d, sizeof d, "after a clear edge: state %d, buffer peak %g", stC, left);
        report("clear", stC == 0 && left == 0.0, d);

        // swap: record again, then point at buffer 2 -> EMPTY on the new one
        blocks(1, 5); blocks(500); blocks(1, 7); blocks(20);
        const int before = h.unit()->engine->getState();
        h.set(kBuf, 2.0f); blocks(1);
        const int after = h.unit()->engine->getState();
        const bool onNew = h.unit()->engine->getSample() == &h.unit()->loop && h.unit()->loop.mpData == h.bufData[2].data();
        snprintf(d, sizeof d, "loop playing (state %d) -> bufnum 2: state %d, engine on the new buffer %d", before, after, (int)onNew);
        report("swap", before == 2 && after == 0 && onNew, d);
        h.dtor();
    }
    {   // refuse
        gPrinted.clear();
        Host h; h.build(FRAMELENGTH * 2); h.ctor();
        for (int i = 0; i < FRAMELENGTH * 2; ++i) h.inBufs[kInL][i] = h.inBufs[kInR][i] = 0.5f;
        h.outBufs[0].assign(FRAMELENGTH * 2, 9.0f); h.outBufs[1].assign(FRAMELENGTH * 2, 9.0f);
        h.run();
        double m = 0; for (int i = 0; i < FRAMELENGTH * 2; ++i) m = fmax(m, fmax(fabs(h.outPtrs[0][i]), fabs(h.outPtrs[1][i])));
        const bool said = gPrinted.find("REFUSING") != std::string::npos;
        h.dtor();
        snprintf(d, sizeof d, "block %d vs FRAMELENGTH %d: output peak %g, said so %d", FRAMELENGTH * 2, FRAMELENGTH, m, (int)said);
        report("refuse", m == 0 && said, d);
    }
    snprintf(d, sizeof d, "RT blocks outstanding after every case: %d; unexpected replies %d", gRtBlocks, gOther);
    report("noleak", gRtBlocks == 0 && gOther == 0, d);

    printf(gFails ? ">>> Noether: %d wiring test(s) FAILED\n" : ">>> Noether: all wiring tests passed\n", gFails);
    return gFails ? 1 : 0;
}
