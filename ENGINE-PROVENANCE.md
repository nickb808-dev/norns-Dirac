# ENGINE-PROVENANCE

`engine/Dirac.{h,cpp}` is a **verbatim vendored copy** of the canonical Dirac
engine from the ER-301 repo (`dirac`), taken at **v0.2.10**.

Rules of the road:

1. **Do not develop the engine here.** The ER-301 repo is upstream. If a DSP
   bug is found (in either place), fix it upstream first, then hand-copy the
   change here and run `make hosttest` — the ported ER-301 test suite
   (`test/host/main.cpp`, 17 suites) verifies the sync.
2. **Record every sync** below.
3. Wrapper / shim / script code (`norns/`, `ugen/`, `lib/`, `dirac.lua`) is
   native to THIS repo and free to evolve.

`make verify-vendor` diffs `engine/` against an upstream checkout and fails on
any difference, so a silent local edit cannot survive a build:

```
make verify-vendor UPSTREAM=../dirac
```

| Date       | Upstream version | What was synced |
|------------|------------------|-----------------|
| 2026-08    | v0.2.10          | Initial vendoring (engine + the 17-suite host harness). |
| 2026-11-18 | v0.2.12 (`b6017bf`) | Engine: 0.2.11 in-tune grains (sub-sample read positions), sanitize() on every control, integer dials; 0.2.12 removes Color (one inlet fewer: wrapper enum, `Dirac.sc.in`, `Engine_Dirac.sc`, `params.lua`, stub test follow). Harness: upstream's 0.2.12 `test/host/main.cpp` 3-way-merged with this repo's `nb()` block-count conversion (new `pitch` / `nan` suites wrapped too; `colort` dropped). Builds gain `-fno-finite-math-only`, as upstream. References regenerated: `ident-v0.2.12.bin` from upstream's own harness (bit-identical to ours), `-fl64` from ours. Pi `portcheck`: PASS, max diff -99.3 dBFS. |
| 2026-11-18 | v0.2.12 + `1cab15c` | `DIRAC_MAX_GRAINS` build option, made upstream for this port (default 16; the ER-301 build is unchanged and its `ident` render bit-identical). The norns UGen builds with 32 (`ugen/Makefile` `MAX_GRAINS`); host tests and references stay at the default 16. Measured on the Pi: 13.2% avg of scsynth's deadline at 32 grains with everything at maximum, no xruns. |
| 2026-11-18 | v0.2.12 + `6f34a28` | Read-only `getCapData()` and a public `kCapBufSize`, made upstream for this port (no behaviour change; ER-301 `ident` bit-identical). The norns UGen uses them to save the ring (capture) and to draw waveform peaks from the ring itself, feedback included, and wraps against the engine's own ring size instead of a copied constant. |

## Noether (the looper)

`engine/Noether.{h,cpp}` is a verbatim vendored copy of the ER-301 looper
engine from the `noether` repo. Same rules: develop it upstream, copy it here,
and `make verify-vendor` (with `NOETHER_UPSTREAM`, default `../noether`) fails
on any difference.

```
make verify-vendor UPSTREAM=../dirac NOETHER_UPSTREAM=../noether
```

`test/noether-host/` is upstream's host harness (`test/host/main.cpp`, its `od/`
stubs, and the `NoetherReel.h` / `NoetherScale.h` / `NoetherLut.h` it includes),
with ONE change: its block counts are durations. Upstream renders "N blocks"
and judges times (a 5 ms fade is over after 3 blocks of 128; at 64 it is not),
so 7 of its 25 suites failed at the 64-sample block norns runs, while the
engine itself is per-sample throughout (every time constant is computed per
sample in the constructor). Literal block counts became `nb(N)` (N blocks of
128 as blocks of this build; identity at 128), and the few presses written as
an offset past sample 63 of a block keep their absolute time. At 128 the
harness's output is byte-identical to upstream's, every suite. `make
noethertest` runs all 25 at 128 and at 64 (`test/noether-host-fl64/` shadows
the harness's `od/config.h`).

| Date       | Upstream version | What was synced |
|------------|------------------|-----------------|
| 2026-11-21 | 0.8.14 (`d46b9ac`) | Initial vendoring: engine, the 25-suite harness (block counts as durations, above). The norns shim gained what Noether uses of the SDK: `od::Sample`'s `mSampleLoadCount`, `setDirty()` and reference counting, and `od::Head::setSample()` in the device SDK's order. Dirac's wrapper tests pass unchanged against the extended shim. |

---

## Varia (the filter)

The filter unit is **derived** from the ER-301 package Varia (`variable-bw`,
v0.4.1), not vendored: `engine/VariaFilter.h` keeps Varia's process loop and
coefficient math line for line (two Cytomic SVFs in series, resonance map,
Peaks, stereo peak phase, soft limit, denormal flush) and adds one control,
*type*, which glides the two band edges so the filter sweeps lowpass -> band
-> highpass. A parked edge is damped to Butterworth and, in the last quarter
of its travel, crossfaded out. Level is dropped (the SynthDef's mix does it).

What is vendored, and checked by `make verify-vendor` (`VARIA_UPSTREAM`,
default `../variable-bw`):

- `engine/svf_math.h`, used as is;
- `test/varia-host/ref/VariableBW.{h,cpp}` and `test/varia-host/od/`, the
  reference the derived filter is tested against.

`make variatest` runs the suite twice. In a strict IEEE build, *type* 0.5 on
noise with every control moving is bit-identical to upstream's
`VariableBW::process()`. Under the shipped `-ffast-math` the two files
reassociate differently; the difference is bounded (about -100 dB). Varia
changes upstream are not picked up automatically: re-sync by hand and the
`ident` case says whether the band path still matches.

| Date       | Upstream version | What was synced |
|------------|------------------|-----------------|
| 2026-11-22 | 0.4.1 (`4c53304`) | Initial derivation: `svf_math.h`, the reference copy, and `VariaFilter.h`. |

## Why verbatim, and not a submodule

The tapdirac port already runs this way and it works. A submodule would pin the
engine more strictly, but it makes the norns repo unusable as a norns script
install target — `;install <url>` clones one repo, and a script that arrives
with an empty `engine/` directory is worse than one carrying a copy it can
prove is current.

The proof is the point: **`make verify-vendor` plus 17 passing suites** is a
stronger guarantee than "there is a submodule pointer somewhere", because it
checks the thing that actually matters (does this code behave like upstream)
rather than the thing that is easy to check (is the hash the same).

## What is NOT vendored

`DiracFieldGraphic.h` — the ER-301 grain-field scope. It is v2 work here (see
`docs/NORNS-PORT.md`, "The screen"), and vendoring a file nothing compiles
would be dead weight that still has to be kept in sync. Copy it when the scope
is actually built.
