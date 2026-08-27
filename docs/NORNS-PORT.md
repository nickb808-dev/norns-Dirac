# NORNS-PORT.md — porting the canonical Dirac engine to monome norns

How to get **Dirac.cpp / Dirac.h — the canonical, current engine** — running on
norns, keeping the ER-301 unit's interface as far as the hardware allows.

Companions: `DAISY-SEED-PORT.md` (bare-metal C++ target), `TAPOMATIC-PORT.md`
(Daisy Patch SM via the generated `dirac_engine.c`), `DPT-PORT.md`, and
`PORT-M4L.md`. This doc is the **fifth** path and, on the DSP side, the
cheapest of them.

---

## The platform: norns shield on a Pi 4

Nick's target is a **norns shield** — monome's own open DIY board — on a
**Raspberry Pi 4B**, not an official norns. The shield runs the same norns
software stack, so scripts and engines are identical; only the hardware
underneath differs, and it differs in our favour.

| | official norns | **norns shield on Pi 4B (the target)** |
|---|---|---|
| compute | CM3/CM3+, quad 1.2 GHz A53, 1 GB | **quad 1.5 GHz Cortex-A72, 2-8 GB** |
| screen | 128x64 OLED, 16 levels | same (NHD-2.7-12864WDW3) |
| controls | 3 encoders, 3 keys | same |
| audio | CS4270 I2S | CS4270 (or the 2022 revision codec), 3.5 mm |
| jacks | 1/4", separate headphone out | 3.5 mm; headphones on the main out |

**The A72 is a much bigger machine than the A8 this engine was tuned for** —
out-of-order, higher clock, four cores, and gigabytes rather than megabytes.
Every CPU and memory constraint in the ER-301 build (mip levels, the 512 KB
ring, the per-block Snap budget) stops being a constraint here. That does NOT
mean removing them: they are what makes the sound identical across targets.

Supported Pi versions for the shield are 3B, 3B+ and 4B.

## The platform, for reference (official norns)

Per monome's specs:

| | |
|---|---|
| compute | Compute Module 3 / 3+, **quad-core 1.2 GHz** (Cortex-A53), **1 GB RAM** |
| storage | 4 GB (CM3) / 32 GB (CM3+) |
| audio | CS4270 I²S codec, 2 in / 2 out, line level |
| screen | **128 × 64 OLED, 16 brightness levels** |
| controls | **3 encoders, 3 keys** |
| USB | 4 ports — up to 4 grids, 4 arcs, 16 MIDI devices, 4 HID |
| OS | Linux, realtime kernel |
| DSP | SuperCollider (`crone`); scripts in Lua (`matron`) |

Compared with the ER-301 (single-core Cortex-A8 ~1 GHz, 256×64 display), norns
has **more CPU and far more RAM, a smaller screen, and no CV jacks**.

---

## Why this port is cheap: the seam already exists

The engine's ENTIRE platform surface, measured rather than estimated:

```
$ grep -E '^#include <' src/Dirac.h src/Dirac.cpp
  od/objects/heads/Head.h   od/objects/Object.h
  od/audio/Sample.h         od/config.h
  vector  cmath  cstdint  algorithm

$ grep -oE 'od::[A-Za-z]+' src/Dirac.* | sort -u
  od::Head  od::Inlet  od::Option  od::OptionControl  od::Outlet  od::Sample

$ wc -l test/host/od/**            # the stubs the host harness already uses
  43 total
```

**Six symbols and 43 lines of shim.** `test/host/` is not a testing
convenience — it is a working proof that the engine compiles and runs against a
non-ER-301 platform. A norns port is a third implementation of those 43 lines.

Engine size for scale: `Dirac.cpp` 1000 lines, `Dirac.h` 368,
`DiracFieldGraphic.h` 303.

---

## DSP: a SuperCollider UGen, with precedent

norns extends DSP through SuperCollider. Two options:

1. **Rewrite Dirac as a SynthDef in sclang.** Rejected: it abandons the
   canonical engine, and every fix would have to be made twice. The whole
   repo is organised around one engine, ported.
2. **Compile Dirac.cpp as a scsynth UGen plugin (`.so`)**, wrap it in a
   SuperCollider class, drive it from a Lua script. **This is the path.**

The precedent is exact: **mi-UGens** (Volker Böhm) ports Mutable Instruments'
C++ DSP to SuperCollider UGens, and those are recompiled on the Raspberry Pi
for norns, with norns engines built around them (`mi-eng`). Same shape as this:
existing C++ audio code → SC UGen → norns engine → Lua script.

**Shim work** (the norns equivalent of `test/host/od/`):

| ER-301 | norns / SC |
|---|---|
| `od::Inlet::buffer()` | UGen input pointer (`IN(n)`), or a scalar control |
| `od::Outlet::buffer()` | `OUT(0)`, `OUT(1)` |
| `od::Option` | UGen control input, integer-valued |
| `od::Sample` (`mpData`, `mSampleCount`, `mChannelCount`) | SC `Buffer` — `SndBuf`, `bufData`, `bufFrames`, `bufChannels` |
| `FRAMELENGTH` | SC block size (**verify** — do not assume 128) |
| `globalConfig.sampleRate` | SC sample rate, 48 kHz on norns |

Two things to audit rather than assume:

- **Block size.** `kSnapPerBlock = 2` is a per-BLOCK budget, and grain spawn
  decisions are per-block. If norns runs SC at 64 samples, every per-block rate
  doubles. Measure, then decide whether to rescale or set the block size.
- **`mCapBuf` = 131072 floats = 512 KB.** Trivial against 1 GB — but it must be
  allocated in the UGen's RT-safe world (`RTAlloc`), not `std::vector`, because
  scsynth forbids allocation on the audio thread. This is the same constraint
  the Daisy doc raises about SDRAM, arrived at differently.

**CPU:** measured worst case on the dev host is 0.0082 ms/block at 48 k/128
(16 grains, 4 heads, Color + Feedback + Snap all on). An A53 at 1.2 GHz has
ample headroom, and scsynth will use one core. Not a concern; still measure.

---

## Interface: keeping it close to the ER-301

The ER-301 unit exposes **30 CV-able inlets** and **3 menu options**:

```
In Playhead Rate PosJtr Spread Detune Level RevProb Psprd Texture Grains
Fire Hold SemiShift GrainLen Mix Feedback Compress Binaural Scale V/Oct
Speed Heads HeadSpread HeadTune Snap Color Tilt TiltSpread Window
options: Playheads  Diffuse  Freeze
```

Mapping that onto 3 encoders and 3 keys:

**`params` is the backbone.** Every dial becomes `params:add_control` with the
same name, range and default as the ER-301 control. That gets you the params
menu, MIDI learn, and PSET save/load for free — and PSETs are the norns
analogue of ER-301 presets. The three options become `params:add_option`.

**Arc is the closest thing to the ER-301's dials.** Four endless encoders with
LED rings, and norns supports up to four of them. Assign the four most-performed
controls (Playhead, Grains, GrainLen, Texture is my starting guess) with the
ring showing value — the nearest available analogue to reaching for a knob.

**Grid**, if present, is the natural home for Fire/Hold/Freeze plus scene
recall — and for a row that scrubs Playhead.

**Crow replaces the CV jacks**: 4 in / 4 out over USB. This is where the port
is honestly *worse* than the ER-301, and the gap should be stated plainly —
see below.

**Suggested on-device layout — the Pappus cell model** (see the study below;
this replaces an earlier one-param-per-encoder sketch, which wasted E1 on
paging and could only reach two controls at a time):

```
E1              select cell          K2 / K3     page back / forward
E2              value                K2 + K3     change lane
E3              sub-value / fine     long K2     reset cell + clear modulation
                                     long K3     page toggle (Freeze / Hold)
```

Pages as a declarative table, each a grid of labelled cells:

| page | cells |
|---|---|
| GRAIN | Playhead, Grains, GrainLen, Texture, Window, PosJtr |
| PITCH | SemiShift, Detune, Psprd, Scale, V/Oct, RevProb |
| SPACE | Spread, Heads, HeadSpread, HeadTune, Binaural, Snap |
| TONE | Color, Tilt, TiltSpread, Compress, Diffuse, Mix |
| TIME | Rate, Speed, Feedback, Freeze, Level, Fire |
| FIELD | the grain scope, no controls |

Six pages of six covers all 30 inlets and the 3 options with room to spare, and
"scroll along a strip of labelled controls, each with a value and a fine
adjust" is very close to what the ER-301 control strip already is.

---

## The screen: the best news and the main risk

`DiracFieldGraphic.h` is a phosphor grain-field scope. Its own constants:

```cpp
static const int kMaxW = 128;
static const int kMaxH = 64;
uint8_t mPixels[kMaxW * kMaxH];
if (b > 15) b = 15;              // 4-bit intensity
```

**128 × 64 at 16 levels is exactly the norns screen.** The visualisation was
written, coincidentally, to norns' native format — no rescaling, no
requantising, no loss.

**The risk is where it runs.** On the ER-301 the graphic is C++ inside the
unit. On norns the screen is drawn from **Lua**, and a naive port means Lua
touching 8192 cells per frame for the phosphor decay alone. At 15–30 fps that
is likely too slow. Three options, in order of preference:

1. **Engine renders, Lua blits.** Keep the phosphor buffer in the UGen and
   poll it to Lua. 8 KB/frame is too chatty for OSC at 30 fps, so: decimate,
   or send a run-length/nibble-packed frame, or drop to 15 fps.
2. **Engine sends grain positions; Lua draws.** ~16 grains × a few floats per
   frame is nothing. Lua keeps a coarser phosphor table (say 64 × 32) and
   upscales. Loses some of the trail's fineness, keeps the character.
3. **Lua does it all** at reduced resolution.

**Measure option 1 before choosing.** This is the one part of the port where
the ER-301 version may genuinely be nicer, and it is worth the effort to keep,
because the field scope is a lot of what the unit *is*.

---

## What is lost, stated plainly

- **Per-parameter audio-rate CV.** On the ER-301 every parameter has a mono
  branch that accepts audio-rate modulation — that is the platform's whole
  idea. On norns you get crow's 4 control-rate CV inputs, MIDI, and whatever
  modulation you build in SuperCollider. Audio-rate FM of grain parameters
  from an external source is not available. **This is the real cost of the
  port**, and no amount of UI work substitutes for it.
- **The chain context.** Dirac on the ER-301 is a unit inside a signal chain
  with other units. On norns it is the script; anything around it must be
  built in SC or patched externally.
- **The 256-wide display.** norns is half as wide, so the field scope loses
  horizontal resolution (the graphic already scales — `mWidth < kMaxW`).

---

## THE PLAN

Target decided with Nick: **v1 is live-input granulation, the full cell UI, and
PSET save. No grain-field scope, no sample loading** — those are v2. Controls:
shield encoders/keys plus an **8x8 Novation Launchpad** acting as a grid (via
the `midigrid` mod). No arc, no crow.

**The backbone of the whole plan is `test/host`'s `ident` suite.** It renders
deterministic scenarios — fixed RNG seed, fixed control values, sample mode and
live mode — to a binary file. So "is the port correct" is not a listening test:
it is *does the norns UGen produce the same samples as the ER-301 engine*.
Every phase below has a measurable exit.

### Phase 0 — repo + vendoring *(entirely off-device; I can do this now)*

New repo `norns-dirac`, structured like `tapdirac-staging` because that pattern
already works here:

```
norns-dirac/
  engine/Dirac.{h,cpp}      verbatim vendored copy, v0.2.10
  ENGINE-PROVENANCE.md      sync rules + sync log (copy tapdirac's)
  norns/od/                 the shim: Head, Inlet, Outlet, Option, Sample, config
  ugen/DiracUGen.cpp        scsynth plugin wrapper
  lib/Engine_Dirac.sc       SC class, one addCommand per parameter
  dirac.lua                 the script
  test/                     ported host suite + Lua UI tests + mock_norns.lua
  README.md  LICENSE  NOTICE
```

**Rule, from ENGINE-PROVENANCE: do not develop the engine here.** The ER-301
repo is upstream; DSP fixes go there first and are hand-synced.

*Exit:* the vendored engine builds against the existing host stubs and the full
17-suite `hosttest` passes unchanged. **Verifiable here, today.**

### Phase 1 — shim + UGen, and the cross-target check *(I write it; you build it)*

Write `norns/od/` (the ~43 lines) and `ugen/DiracUGen.cpp`. Two things need
care and are already flagged in this doc: `mCapBuf` must come from `RTAlloc`,
not `std::vector`; and the SC block size must be measured, not assumed, before
anything rescales `kSnapPerBlock`.

*Exit, and this is the important one:* run `ident` on the dev host to produce
the reference render. Run the same scenarios through the UGen in **NRT** on the
Pi. **Diff the two.** Identical (or within float-noise tolerance, quantified)
means the engine survived the port. Anything else means stop and find out why
before building a UI on top of it.

Also produced here: the first real CPU number on the A72, from NRT timing.

### Phase 2 — SC class + params *(mostly off-device)*

`Engine_Dirac.sc` with an `addCommand` per parameter, and `dirac.lua` declaring
all 30 as `params:add_control` with **the ER-301's own names, ranges and
defaults**. Nothing custom yet — the params menu IS the UI at this stage.

*Exit:* audible on the shield, every parameter reachable and moving, PSET save
and recall round-trips.

### Phase 3 — the cell UI *(almost entirely testable off-device)*

The six-page cell model from the Pappus study: declarative PAGES table, E1
select / E2 value / E3 fine, K2/K3 page, long-press reset and toggle.

Pappus proves the Lua layer is testable headlessly — it ships a
`mock_norns.lua` and drives its own UI in tests. **We do the same**, so page
navigation, cell selection, value quantisation and reset/lock behaviour are all
verified here rather than by turning knobs.

*Exit:* every one of the 30 params reachable from the cell UI; nav tests pass
against the mock; value grid follows the size-of-the-value rule (10 Hz steps at
700 Hz, 1 Hz at 70).

### Phase 4 — the 8x8 Launchpad *(needs the device)*

Note the constraint: **8 columns, not 16.** Pappus assumes a 128 grid and much
of its layout is 16-wide. Ours has to fit half that, so:

- rows 1-2: 16 grain slots (Grains cap is 16 — two rows of 8 fits exactly)
- row 4: Playhead scrub, 8 positions
- row 6: Fire / Hold / Freeze / Diffuse toggles
- rows 7-8: 16 snapshot slots

*Exit:* everything above works, and the script still runs correctly with no
grid attached at all.

### v2, in priority order

1. **The grain-field scope.** Measure the Lua redraw cost first (see the screen
   section); pick the engine-renders/Lua-blits option only if the cheaper one
   looks bad.
2. **Sample loading** — norns Buffer read as `od::Sample`.
3. **crow**, if you ever get one — the only route back to CV.

### What could go wrong, honestly

- **Block size mismatch** changes every per-block rate. Caught in Phase 1 by
  the `ident` diff, which is exactly why that diff comes before any UI work.
- **`RTAlloc` and the RT-safety rules** — scsynth forbids allocation on the
  audio thread. The engine already never allocates in `process()`; the risk is
  the constructor path.
- **The scope may not be affordable in Lua.** Deliberately deferred to v2 so it
  cannot block a working instrument.
- **The Launchpad-as-grid layer** (`midigrid`) is a third-party mod and a
  dependency the script does not control. Phase 4 exit therefore includes
  "works with no grid at all".

## Prior art: Pappus, studied

Michael Manning's **Pappus** (`~/Downloads/pappus`) is a deep norns granular
instrument — two euclidean grain swarmers, filterbank, multitap delay, colour,
scene morphing, modular routing, LFO/envelope modulation. Written with heavy
LLM assistance, like this repo. Four things in it are worth taking.

**1. It answers "how do 30 parameters fit on 3 encoders."** Not the params
menu — a declarative table of PAGES, each holding CELLS:

```lua
{ name = "GRAINSWARM", short = "GR.SW", dots = {1,4}, rows = 2,
  cells = {
    { id = "m_pitch",   label = "PITCH", mode = "m_scale" },
    { id = "m_rate",    label = "RATE",  alt  = "m_rate_free" },
    { id = "m_contour", label = "SHAPE", bipolar = true },
    ...
```

with `E1` select cell, `E2` value, `E3` sub-value or fine tune, `K2`/`K3` page
back/forward, `K2+K3` change LANE (audio chain vs modulators), long-press to
reset or to fire the page's toggle, encoder push for default/snap.

**This is much closer to the ER-301 than norns' params menu is** — a strip of
labelled controls you scroll along, with a value and a sub-value each, is
essentially what a unit's control strip is. Dirac's 30 inlets map onto four or
five pages of cells almost mechanically. Adopt this wholesale; keep `params`
underneath it for MIDI-learn and PSET, as Pappus does.

**2. It has an offline DSP harness, and it is the same idea as `test/host`.**
`test/harness.py` text-extracts the `SynthDef` body out of `Engine_Pappus.sc`,
stubs the engine's instance variables with fixed buffer numbers, allocates the
matching buffers in a Score, and renders **NRT** (non-realtime) through sclang
— then analyses the result in Python. Around 25 Python tests plus `.scd` tests,
plus Lua UI tests against a `mock_norns.lua`.

So: SuperCollider DSP *can* be measured offline and asserted on numbers, which
is the thing this repo will not ship without. If Dirac goes the UGen route the
existing `test/host` harness keeps working unchanged, and this pattern is the
model for testing the SC/Lua layers around it.

**3. A bug in its harness is one we have hit repeatedly.** Their own comment:

> patbuf is EUCLID's sixteen gate steps now, not the old pitch sequence. It was
> left as the pitch sequence for one version, whose first element is 0 - so
> every grain was gated off and every NRT render came back silent. The analysis
> then divided silence by silence and reported 0.0 dB everywhere, **which reads
> as "no change" rather than as "nothing happened"**.

That is exactly the dishonest-diagnostic class from ER301-UNIT-STANDARD §14/§16
— a measurement that fails in a way that looks like a pass. Independent
confirmation the rule is worth keeping.

**4. Two design principles worth stealing verbatim:**

- *"A stage nobody can turn off has to be right for every signal that can
  reach it."* They removed a hidden mastering chain that measured well on grain
  clouds and buffeted a clean signal. Same instinct as our exact-bypass rule.
- **Knob grid from the size of the value, not the width of the range** — a
  frequency control steps 10 Hz at 700 Hz and 1 Hz at 70, and the fine knob is
  exactly a tenth of the coarse step. Worth adopting for Dirac's wide-range
  controls (GrainLen, Rate).
- **Snapshot load = reset first, then apply**, so nothing from the previous
  patch survives into a recalled scene.

One difference to be deliberate about: **Pappus is an sclang SynthDef, not a
C++ UGen.** That is right for an instrument designed on norns from scratch. It
is wrong for Dirac, which already exists as a canonical C++ engine that three
other targets share — rewriting it in sclang would fork the DSP and every fix
would have to be made twice. The UGen path keeps one engine.

---

## Open questions

- SC block size on norns — verify before rescaling any per-block budget.
- Does `crone` permit a third-party UGen plugin without a system rebuild?
  (mi-UGens on norns says yes; confirm the current install path.)
- Stereo: Dirac is stereo out; norns is stereo in/out. Straightforward, but
  the binaural/phase code should be re-verified on the target.
- SC block size on the shield build — verify on the actual Pi 4.
