/* VariaFilter.h — a multimode filter built on Varia's core, for norns.
 *
 * DERIVED, NOT VENDORED. Varia (the ER-301 package in `variable-bw`, v0.4.1)
 * is a Serge-style variable-bandwidth bandpass: two Cytomic SVFs in series per
 * channel, highpass @ fL -> lowpass @ fH, shared resonance, Peaks (interior
 * resonators), stereo peak phase. This file keeps that core line for line
 * and adds ONE control, TYPE, that moves the two edges:
 *
 *     type 0    lowpass   fL parked at 10 Hz,      fH = freq
 *     type 0.5  band      fL = freq / r, fH = freq * r   (Varia itself)
 *     type 1    highpass  fL = freq,               fH parked at 23.5 kHz
 *
 * with r = 2^(width * 3), Varia's bandwidth. In between, the edges glide on a
 * log scale, so the knob sweeps continuously low -> band -> high with no
 * switch and no click. At exactly type 0.5 the output is BIT-IDENTICAL to
 * Varia's VariableBW::process() (test/varia-host checks it on noise against
 * a verbatim copy of upstream).
 *
 * A parked edge must not resonate: a lowpass with a self-oscillating 10 Hz
 * highpass in front of it would thump. So each stage gets its own damping,
 * gliding from the shared resonance to Butterworth (k = sqrt 2) as it parks,
 * and in the last quarter of its travel the stage is crossfaded out to the
 * plain input, so the fully parked edge leaves no trace at all.
 *
 * Peaks span the band as in Varia; in the low/high regions the span is
 * anchored at the edge that moves (fH for low, fL for high) and capped at
 * Varia's 6 octaves, so the peaks stay where the sound is.
 *
 * Unlike Varia (am335x), the norns has a working libm, but svf_math.h is used
 * for every coefficient so the band path is the same arithmetic as upstream;
 * std::log2 / exp2 appear only for the edge glide, off the identity path.
 */
#pragma once

#include <cstdint>
#include <cmath>
#include "svf_math.h"

namespace varia {

static constexpr float kSampleRate = 48000.0f;
static constexpr float kMaxBwOct   = 6.0f;
static constexpr float kQmin       = 0.5f;
static constexpr float kResSpan    = 11.5507f;   // log2(1500 / 0.5)
static constexpr int   kMaxPeaks   = 7;
static constexpr int   kMaxInner   = kMaxPeaks - 2;
static constexpr float kFcMin      = 10.0f;
static constexpr float kFcMax      = 0.45f * 48000.0f;
static constexpr float kEdgeMax    = 0.49f * 48000.0f;
static constexpr float kPark       = 1.41421356f;   // Butterworth damping

static inline float sanitize(float x)
{
    union { float f; uint32_t u; } v;
    v.f = x;
    return ((v.u & 0x7F800000u) == 0x7F800000u) ? 0.0f : x;
}
static inline float flushTiny(float x) { return (x > -1e-30f && x < 1e-30f) ? 0.0f : x; }
static inline float softLimit(float x)
{
    const float T  = 0.9f;
    const float ax = (x >= 0.0f) ? x : -x;
    if (ax <= T) return x;
    const float e   = ax - T;
    const float lim = T + (1.0f - T) * (e / (e + (1.0f - T)));
    return (x >= 0.0f) ? lim : -lim;
}
static inline float clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }

// x * (to / x)^a, on a log scale; a in [0, 1]
static inline float glide(float x, float to, float a)
{
    return a <= 0.0f ? x : x * std::exp2(a * std::log2(to / x));
}

// Varia's interior resonator bank, unchanged.
static inline float innerBank(const float x, const int n,
                              const float *a1, const float *a2, const float *a3,
                              const float *g, const float k,
                              float *ic1, float *ic2)
{
    float acc = 0.0f;
    for (int i = 0; i < n; ++i) {
        const float v3 = x - ic2[i];
        const float v1 = a1[i] * ic1[i] + a2[i] * v3;
        const float v2 = ic2[i] + a2[i] * ic1[i] + a3[i] * v3;
        ic1[i] = 2.0f * v1 - ic1[i];
        ic2[i] = 2.0f * v2 - ic2[i];
        acc += g[i] * v1;
    }
    return acc;
}

struct Filter {
    // controls, read once per block
    float freq = 1000.0f;   // Hz
    float width = 0.5f;     // [0, 1] -> 0..6 octaves (band region)
    float res = 0.0f;       // [0, 1]; 1 self-oscillates
    float type = 0.0f;      // [0, 1]: low .. band (0.5) .. high
    float peaks = 0.0f;     // [0, 1] -> 2..7 peaks
    float phase = 0.0f;     // [-1, 1] stereo peak phase

    // the last block's edges and damping, for anyone drawing the response
    float fL = 10.0f, fH = 1000.0f, kL = 1.0f, kH = 1.0f;
    float xL = 0.0f, xH = 0.0f;      // how far each stage is crossfaded out

    // coefficients
    float a1L = 0, a2L = 0, a3L = 0, a1H = 0, a2H = 0, a3H = 0;
    int   innerN = 0;
    float innerG[kMaxInner] = {0}, innerA1[kMaxInner] = {0}, innerA2[kMaxInner] = {0}, innerA3[kMaxInner] = {0};
    float innerK = 0.0f, innerNorm = 1.0f;
    // state
    float ic1Ll = 0, ic2Ll = 0, ic1Hl = 0, ic2Hl = 0;
    float ic1Lr = 0, ic2Lr = 0, ic1Hr = 0, ic2Hr = 0;
    float innerIc1L[kMaxInner] = {0}, innerIc2L[kMaxInner] = {0};
    float innerIc1R[kMaxInner] = {0}, innerIc2R[kMaxInner] = {0};

    void updateCoeffs()
    {
        const float fc  = clampf(freq, kFcMin, kFcMax);
        const float bw  = clampf(width, 0.0f, 1.0f);
        const float rs  = clampf(res, 0.0f, 1.0f);
        const float t   = clampf(type, 0.0f, 1.0f);

        const float r  = vbfmath::pexp2(bw * kMaxBwOct * 0.5f);
        float l = fc / r, h = fc * r;               // Varia's edges
        const float pl = t < 0.5f ? 1.0f - 2.0f * t : 0.0f;   // highpass parking
        const float ph = t > 0.5f ? 2.0f * t - 1.0f : 0.0f;   // lowpass parking
        if (pl > 0.0f) { h = glide(h, fc, pl); l = glide(l, kFcMin, pl); }
        if (ph > 0.0f) { l = glide(l, fc, ph); h = glide(h, kEdgeMax, ph); }
        fL = clampf(l, kFcMin, kEdgeMax);
        fH = clampf(h, kFcMin, kEdgeMax);

        const float gL = vbfmath::ptan(vbfmath::kPi * fL / kSampleRate);
        const float gH = vbfmath::ptan(vbfmath::kPi * fH / kSampleRate);

        float k;
        if (rs >= 0.999f) k = 0.0f;
        else              k = 1.0f / (kQmin * vbfmath::pexp2(rs * kResSpan));
        kL = pl > 0.0f ? k + pl * (kPark - k) : k;
        kH = ph > 0.0f ? k + ph * (kPark - k) : k;
        xL = clampf((pl - 0.75f) * 4.0f, 0.0f, 1.0f);
        xH = clampf((ph - 0.75f) * 4.0f, 0.0f, 1.0f);

        const float b1L = 1.0f / (1.0f + gL * (gL + kL));
        a1L = b1L; a2L = gL * b1L; a3L = gL * a2L;
        const float b1H = 1.0f / (1.0f + gH * (gH + kH));
        a1H = b1H; a2H = gH * b1H; a3H = gH * a2H;

        // Peaks: Varia's interior resonators
        const float pk = clampf(peaks, 0.0f, 1.0f);
        const float P  = 2.0f + pk * float(kMaxPeaks - 2);
        innerN = 0;
        if (P > 2.0f + 1e-4f && rs > 1e-4f) {
            const float D = P - 1.0f;
            float spanOct, base;
            if (pl == 0.0f && ph == 0.0f) { spanOct = bw * kMaxBwOct; base = fL; }   // Varia
            else {
                spanOct = std::log2(fH / fL);
                if (spanOct > kMaxBwOct) spanOct = kMaxBwOct;
                base = pl > 0.0f ? fH / std::exp2(spanOct) : fL;
            }
            const float kIn = (k > 0.02f) ? k : 0.02f;
            innerK = kIn;
            for (int j = 1; j <= kMaxInner; ++j) {
                float g = D - float(j);
                if (g <= 0.0f) break;
                if (g > 1.0f) g = 1.0f;
                const float fj = clampf(base * vbfmath::pexp2(spanOct * float(j) / D), kFcMin, kEdgeMax);
                const float gj = vbfmath::ptan(vbfmath::kPi * fj / kSampleRate);
                const float a1 = 1.0f / (1.0f + gj * (gj + kIn));
                const int   i  = innerN++;
                innerA1[i] = a1; innerA2[i] = gj * a1; innerA3[i] = gj * innerA2[i];
                innerG[i]  = g * rs;
            }
        }
        float gSum = 0.0f;
        for (int i = 0; i < innerN; ++i) gSum += innerG[i];
        innerNorm = 1.0f / (1.0f + 0.7f * gSum);
    }

    // One block, stereo. Every input sample is read before the output sample
    // of the same index is written, so out may alias in (scsynth wires).
    void process(const float *inL, const float *inR, float *outL, float *outR, int n)
    {
        updateCoeffs();
        const float kl = kL;
        const float w = clampf(phase, -1.0f, 1.0f);
        const float xl = xL, xh = xH;
        float sLl = ic1Ll, tLl = ic2Ll, sHl = ic1Hl, tHl = ic2Hl;
        float sLr = ic1Lr, tLr = ic2Lr, sHr = ic1Hr, tHr = ic2Hr;

        for (int s = 0; s < n; ++s) {
            const float x0 = sanitize(inL[s]);
            const float x1 = sanitize(inR[s]);
            {
                const float x = x0;
                float v3  = x - tLl;
                float v1L = a1L * sLl + a2L * v3;
                float v2  = tLl + a2L * sLl + a3L * v3;
                sLl = 2.0f * v1L - sLl;
                tLl = 2.0f * v2  - tLl;
                float hp = x - kl * v1L - v2;
                if (xl > 0.0f) hp += xl * (x - hp);
                v3 = hp - tHl;
                float v1H = a1H * sHl + a2H * v3;
                v2 = tHl + a2H * sHl + a3H * v3;
                sHl = 2.0f * v1H - sHl;
                tHl = 2.0f * v2  - tHl;
                if (xh > 0.0f) v2 += xh * (hp - v2);
                const float q = v1L + v1H;
                float y = v2 + w * q;
                if (innerN) y = (y + innerBank(x, innerN, innerA1, innerA2, innerA3,
                                               innerG, innerK, innerIc1L, innerIc2L)) * innerNorm;
                outL[s] = softLimit(sanitize(y));
            }
            {
                const float x = x1;
                float v3  = x - tLr;
                float v1L = a1L * sLr + a2L * v3;
                float v2  = tLr + a2L * sLr + a3L * v3;
                sLr = 2.0f * v1L - sLr;
                tLr = 2.0f * v2  - tLr;
                float hp = x - kl * v1L - v2;
                if (xl > 0.0f) hp += xl * (x - hp);
                v3 = hp - tHr;
                float v1H = a1H * sHr + a2H * v3;
                v2 = tHr + a2H * sHr + a3H * v3;
                sHr = 2.0f * v1H - sHr;
                tHr = 2.0f * v2  - tHr;
                if (xh > 0.0f) v2 += xh * (hp - v2);
                const float q = v1L + v1H;
                float y = v2 - w * q;
                if (innerN) y = (y + innerBank(x, innerN, innerA1, innerA2, innerA3,
                                               innerG, innerK, innerIc1R, innerIc2R)) * innerNorm;
                outR[s] = softLimit(sanitize(y));
            }
        }
        ic1Ll = flushTiny(sLl); ic2Ll = flushTiny(tLl); ic1Hl = flushTiny(sHl); ic2Hl = flushTiny(tHl);
        ic1Lr = flushTiny(sLr); ic2Lr = flushTiny(tLr); ic1Hr = flushTiny(sHr); ic2Hr = flushTiny(tHr);
        for (int i = 0; i < kMaxInner; ++i) {
            innerIc1L[i] = flushTiny(innerIc1L[i]); innerIc2L[i] = flushTiny(innerIc2L[i]);
            innerIc1R[i] = flushTiny(innerIc1R[i]); innerIc2R[i] = flushTiny(innerIc2R[i]);
        }
    }
};

} // namespace varia
