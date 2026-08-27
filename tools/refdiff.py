#!/usr/bin/env python3
"""refdiff.py — the Phase 1 acceptance test.

    python3 tools/refdiff.py <rendered.bin> <reference.bin>

Compares a render against a canonical reference and returns a VERDICT, not a
number to squint at. Exit 0 = pass.

Why this is not `cmp`
---------------------
A strict byte compare is the wrong tool across architectures, and a naive
tolerance is the wrong tool too. Both were measured rather than assumed:

1. Float dialect moves the samples a little. Same source, same block size,
   only the compiler flags varied (-O0 / -O2 / -O2 -ffast-math / -O3):

       max|diff| 8.7e-05   rms 7e-06   (about -81 dBFS)

   x86 vs ARMv7 NEON will land in this same territory. That is a PASS.

2. A scheduler divergence destroys the render completely. Measured by
   rendering the same source at a 64- vs 128-sample block:

       max|diff| 1.25      rms 0.30    only 7.8% of samples identical

   Grain spawns are decided per block and every spawn draws from the RNG, so
   once the spawn timing shifts by one block the two runs grow entirely
   different grain clouds. This is a HARD FAIL, and it is what a wrong block
   size, a broken RTAlloc buffer, or a mis-wired control input will look like.

The gap between those two regimes is four orders of magnitude, so the verdict
is unambiguous. The failure mode this guards against is reading "it differs"
and shipping anyway because the number looked smallish.
"""
import struct
import sys
import math

# -81 dBFS was the worst observed pure float-dialect difference; 1e-3 (-60 dBFS)
# leaves an order of magnitude of headroom and is still far below audibility.
TOL_MAX = 1e-3
TOL_RMS = 1e-4
# Anything past here is not numerical noise, it is a different render.
DIVERGENCE_RMS = 1e-2


def load(path):
    with open(path, "rb") as f:
        raw = f.read()
    return struct.unpack("<%df" % (len(raw) // 4), raw[: len(raw) // 4 * 4])


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    got, want = load(sys.argv[1]), load(sys.argv[2])

    if len(got) != len(want):
        print("FAIL: length mismatch — %d samples vs %d." % (len(got), len(want)))
        print("      Renders of different DURATION usually mean the block size")
        print("      differs from the one the reference was made at. Check -z.")
        return 1

    n = len(got)
    diffs = [abs(a - b) for a, b in zip(got, want)]
    mx = max(diffs)
    rms = math.sqrt(sum(d * d for d in diffs) / n)
    exact = 100.0 * sum(1 for d in diffs if d == 0.0) / n
    nonfinite = sum(1 for x in got if not math.isfinite(x))

    print("samples      : %d" % n)
    print("max |diff|   : %.8f  (%.1f dBFS)"
          % (mx, 20 * math.log10(mx) if mx > 0 else -999))
    print("rms  diff    : %.8f" % rms)
    print("exact match  : %.1f%%" % exact)
    print("non-finite   : %d" % nonfinite)
    print()

    if nonfinite:
        print("FAIL: %d non-finite samples. NaN/Inf in the output is a bug in the"
              % nonfinite)
        print("      wrapper, not a tolerance question — most likely an unconnected")
        print("      input reading garbage instead of the shared zero block.")
        return 1

    if mx == 0.0:
        print("PASS: bit-for-bit identical.")
        return 0

    if rms >= DIVERGENCE_RMS:
        print("FAIL: the renders have DIVERGED, they are not merely imprecise.")
        print("      rms %.4f is ~%dx past the float-noise regime." % (rms, rms / TOL_RMS))
        print("      Expect a scheduler divergence: the grain spawn stream took a")
        print("      different path, so the RNG decorrelated. Look at, in order:")
        print("        1. block size — is the UGen really running at -z 64?")
        print("        2. control inputs — is every parameter arriving as expected?")
        print("        3. mCapBuf — is it RTAlloc'd, zeroed, and the right length?")
        return 1

    if mx <= TOL_MAX and rms <= TOL_RMS:
        print("PASS: differs only at float-dialect scale (max %.1e <= %.0e," % (mx, TOL_MAX))
        print("      rms %.1e <= %.0e). This is the expected result for a" % (rms, TOL_RMS))
        print("      different CPU and compiler rendering the same DSP.")
        return 0

    print("FAIL: in between the two known regimes — too large for float noise,")
    print("      too small for a scheduler divergence. Do not wave this through.")
    print("      A partial divergence (some scenarios matching, some not) points")
    print("      at ONE control input being wrong. Bisect by scenario.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
