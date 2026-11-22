// varia-host — engine/VariaFilter.h against Varia itself, and the new modes.
//
//   make variatest
//
// ref/VariableBW.{h,cpp} and od/ are verbatim copies of the ER-301 package
// `variable-bw` (src/ and test/host/od/); make verify-vendor checks them.
//
// Cases:
//   ident    type 0.5 on noise, every control moving, vs upstream Varia:
//            bit-identical, both channels
//   low      type 0: passes below freq, falls 12 dB/oct above it
//   high     type 1: the mirror image
//   morph    at freq 1 kHz, res 0, the 100 Hz gain falls and the 10 kHz
//            gain rises as type goes 0 -> 1, with no step over 12 dB
//   osc      type 0 and 1 at full resonance self-oscillate at freq, not at a
//            parked edge, and stay bounded
//   parked   the parked stage leaves no trace: type 0 res 0 at 20 Hz in
//            passes like a plain lowpass (no 10 Hz highpass droop)
//   alias    out pointers == in pointers gives the same output
//   nan      NaN in -> finite out
//   denorm   the state reaches exact zero after the input stops
#include "VariableBW.h"
#include "VariaFilter.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <vector>

static const int N = FRAMELENGTH;
static int gFails = 0;
static void report(const char *name, bool ok, const char *detail)
{
    printf("  %s %-7s %s\n", ok ? "ok  " : "FAIL", name, detail);
    if (!ok) ++gFails;
}
static uint32_t rng = 12345;
static float noise() { rng = rng * 1664525u + 1013904223u; return (float(rng >> 8) / 8388608.0f) - 1.0f; }

// steady-state gain (dB) of one channel at frequency f
static double gainAt(float f, float freq, float width, float res, float type)
{
    varia::Filter F; F.freq = freq; F.width = width; F.res = res; F.type = type;
    std::vector<float> l(N), r(N), ol(N), orr(N);
    const double A = 0.25;
    double ein = 0, eout = 0; long t = 0;
    const int blocks = int(48000 * 1.0 / N);
    for (int b = 0; b < blocks; ++b) {
        for (int s = 0; s < N; ++s, ++t) { l[s] = r[s] = float(A * sin(2 * M_PI * f * t / 48000.0)); }
        F.process(l.data(), r.data(), ol.data(), orr.data(), N);
        if (b > blocks / 2) for (int s = 0; s < N; ++s) { ein += l[s] * l[s]; eout += ol[s] * ol[s]; }
    }
    return 10 * log10((eout + 1e-30) / ein);
}

int main()
{
    char d[256];
    {   // ident
        vbf::VariableBW ref;
        varia::Filter F; F.type = 0.5f;
        std::vector<float> l(N), r(N), ol(N), orr(N);
        long diffs = 0; double maxAbs = 0, maxDiff = 0, eSig = 0, eErr = 0;
        for (int b = 0; b < 4000; ++b) {
            if (b % 25 == 0) {
                F.freq = 40.0f * powf(2.0f, 9.0f * (noise() * 0.5f + 0.5f));
                F.width = noise() * 0.5f + 0.5f;
                F.res = (b / 25) % 7 == 0 ? 1.0f : noise() * 0.5f + 0.5f;
                F.peaks = (b / 25) % 3 == 0 ? 0.0f : noise() * 0.5f + 0.5f;
                F.phase = noise();
            }
            for (int s = 0; s < N; ++s) {
                l[s] = 0.3f * noise(); r[s] = 0.3f * noise();
                ref.mFreqIn.buffer()[s] = F.freq; ref.mBandwidthIn.buffer()[s] = F.width;
                ref.mResonanceIn.buffer()[s] = F.res; ref.mPeaksIn.buffer()[s] = F.peaks;
                ref.mPhaseIn.buffer()[s] = F.phase; ref.mLevelIn.buffer()[s] = 1.0f;
                ref.mVoctIn.buffer()[s] = 0.0f;
                ref.mInL.buffer()[s] = l[s]; ref.mInR.buffer()[s] = r[s];
            }
            ref.process();
            F.process(l.data(), r.data(), ol.data(), orr.data(), N);
            for (int s = 0; s < N; ++s) {
                if (ol[s] != ref.mOutL.buffer()[s] || orr[s] != ref.mOutR.buffer()[s]) ++diffs;
                maxDiff = fmax(maxDiff, fmax(fabs(ol[s] - ref.mOutL.buffer()[s]), fabs(orr[s] - ref.mOutR.buffer()[s])));
                eSig += double(ol[s]) * ol[s];
                eErr += double(ol[s] - ref.mOutL.buffer()[s]) * (ol[s] - ref.mOutL.buffer()[s]);
                maxAbs = fmax(maxAbs, fabs(ol[s]));
            }
        }
#ifdef VT_FAST
        // -ffast-math reassociates the two files differently: ulps, not a
        // different filter. The strict build (variatest's first run) is the
        // bit-exact check.
        // (the self-oscillating stretches are marginally stable, so ulps
        // there grow into small phase drift; hence an energy bound)
        const double db = 10 * log10((eErr + 1e-30) / eSig);
        snprintf(d, sizeof d, "fast-math: difference from Varia %.0f dB below the signal (largest %.2g)", db, maxDiff);
        report("ident", db < -60 && maxAbs > 0.01, d);
#else
        snprintf(d, sizeof d, "strict IEEE, %d blocks of noise, controls moving: %ld samples differ from Varia (peak %.3f)", 4000, diffs, maxAbs);
        report("ident", diffs == 0 && maxAbs > 0.01, d);
#endif
    }
    {   // low / high
        const double l100 = gainAt(100, 1000, 0.5, 0.0, 0.0), l4k = gainAt(4000, 1000, 0.5, 0.0, 0.0), l8k = gainAt(8000, 1000, 0.5, 0.0, 0.0);
        snprintf(d, sizeof d, "freq 1 kHz: 100 Hz %.1f dB, 4 kHz %.1f dB, 8 kHz %.1f dB (slope %.1f dB/oct)", l100, l4k, l8k, l4k - l8k);
        report("low", fabs(l100) < 0.5 && l4k < -20 && (l4k - l8k) > 10, d);
        const double h10k = gainAt(10000, 1000, 0.5, 0.0, 1.0), h250 = gainAt(250, 1000, 0.5, 0.0, 1.0), h125 = gainAt(125, 1000, 0.5, 0.0, 1.0);
        snprintf(d, sizeof d, "freq 1 kHz: 10 kHz %.1f dB, 250 Hz %.1f dB, 125 Hz %.1f dB (slope %.1f dB/oct)", h10k, h250, h125, h250 - h125);
        report("high", fabs(h10k) < 0.5 && h250 < -20 && (h250 - h125) > 10, d);
    }
    {   // morph
        double prevLo = 1e9, prevHi = -1e9, worst = 0; bool mono = true;
        for (int i = 0; i <= 20; ++i) {
            const float t = i / 20.0f;
            const double lo = gainAt(100, 1000, 0.5, 0.0f, t), hi = gainAt(10000, 1000, 0.5, 0.0f, t);
            if (i) {
                if (lo > prevLo + 0.2 || hi < prevHi - 0.2) mono = false;
                worst = fmax(worst, fmax(fabs(lo - prevLo), fabs(hi - prevHi)));
            }
            prevLo = lo; prevHi = hi;
        }
        snprintf(d, sizeof d, "type 0 -> 1 in 21 steps: 100 Hz falls, 10 kHz rises %s; biggest step %.1f dB", mono ? "monotonically" : "NOT monotonically", worst);
        report("morph", mono && worst < 12, d);
    }
    {   // osc
        bool ok = true; char buf[128] = "";
        for (float type : { 0.0f, 1.0f }) {
            varia::Filter F; F.freq = 440; F.res = 1.0f; F.type = type; F.width = 0.5f;
            std::vector<float> l(N, 0), r(N, 0), ol(N), orr(N);
            int cross = 0; float prev = 0, peak = 0; long t = 0;
            for (int b = 0; b < 48000 * 2 / N; ++b) {
                for (int s = 0; s < N; ++s) l[s] = r[s] = (b == 0 && s == 0) ? 0.5f : 0.0f;
                F.process(l.data(), r.data(), ol.data(), orr.data(), N);
                for (int s = 0; s < N; ++s, ++t) if (t >= 48000) {
                    if ((prev < 0) != (ol[s] < 0)) ++cross;
                    prev = ol[s]; peak = fmaxf(peak, fabsf(ol[s]));
                }
            }
            const double hz = cross / 2.0;
            snprintf(buf + strlen(buf), sizeof buf - strlen(buf), "%s %.0f Hz peak %.2f; ", type == 0 ? "low" : "high", hz, peak);
            if (fabs(hz - 440) > 15 || peak > 1.0f || peak < 0.005f) ok = false;
        }
        report("osc", ok, buf);
    }
    {   // parked
        const double g20 = gainAt(20, 1000, 0.5, 0.9f, 0.0), g40 = gainAt(40, 1000, 0.5, 0.9f, 0.0);
        const double h20k = gainAt(18000, 1000, 0.5, 0.9f, 1.0);
        snprintf(d, sizeof d, "res 0.9: low passes 20 Hz %.2f dB, 40 Hz %.2f dB; high passes 18 kHz %.2f dB", g20, g40, h20k);
        report("parked", fabs(g20) < 0.5 && fabs(g40) < 0.5 && fabs(h20k) < 0.5, d);
    }
    {   // alias
        varia::Filter A, B;
        A.freq = B.freq = 700; A.res = B.res = 0.7f; A.type = B.type = 0.3f; A.phase = B.phase = 0.8f; A.peaks = B.peaks = 0.6f;
        std::vector<float> l(N), r(N), ol(N), orr(N), bl(N), br(N);
        long diffs = 0;
        for (int b = 0; b < 300; ++b) {
            for (int s = 0; s < N; ++s) { l[s] = bl[s] = 0.3f * noise(); r[s] = br[s] = 0.3f * noise(); }
            A.process(l.data(), r.data(), ol.data(), orr.data(), N);
            B.process(bl.data(), br.data(), br.data(), bl.data(), N);   // out L on in R and vice versa
            for (int s = 0; s < N; ++s) if (ol[s] != br[s] || orr[s] != bl[s]) ++diffs;
        }
        snprintf(d, sizeof d, "outputs written over the other channel's input: %ld samples differ", diffs);
        report("alias", diffs == 0, d);
    }
    {   // nan
        varia::Filter F; F.res = 0.9f; F.type = 0.2f;
        std::vector<float> l(N, NAN), r(N, INFINITY), ol(N), orr(N);
        bool fin = true;
        for (int b = 0; b < 10; ++b) {
            F.process(l.data(), r.data(), ol.data(), orr.data(), N);
            for (int s = 0; s < N; ++s) if (!std::isfinite(ol[s]) || !std::isfinite(orr[s])) fin = false;
        }
        report("nan", fin, fin ? "NaN / Inf in: finite out" : "non-finite output");
    }
    {   // denorm
        varia::Filter F; F.res = 0.9f; F.type = 0.7f; F.peaks = 0.8f;
        std::vector<float> l(N), r(N), ol(N), orr(N);
        for (int b = 0; b < 200; ++b) { for (int s = 0; s < N; ++s) l[s] = r[s] = 0.3f * noise(); F.process(l.data(), r.data(), ol.data(), orr.data(), N); }
        std::fill(l.begin(), l.end(), 0.0f); std::fill(r.begin(), r.end(), 0.0f);
        int left = -1;
        for (int b = 0; b < 48000 * 30 / N; ++b) {
            F.process(l.data(), r.data(), ol.data(), orr.data(), N);
            const bool zero = F.ic1Ll == 0 && F.ic2Ll == 0 && F.ic1Hl == 0 && F.ic2Hl == 0 && F.ic1Lr == 0 && F.ic2Hr == 0;
            if (zero) { left = b; break; }
        }
        snprintf(d, sizeof d, "after the input stops the state is exactly zero by block %d", left);
        report("denorm", left > 0, d);
    }
    printf(gFails ? ">>> VariaFilter: %d case(s) FAILED\n" : ">>> VariaFilter: all cases passed\n", gFails);
    return gFails ? 1 : 0;
}
