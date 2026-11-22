# dirac

**Dirac**, the granular processor from the ER-301, on monome norns.

**v0.13.0 beta.** For norns and norns shield (32-bit norns images, which is all
of them today). Developed on a norns shield with a Raspberry Pi 4B.

---

## Beta testers: start here

### Install

1. In maiden, run:

   ```
   ;install https://github.com/nickb808-dev/norns-dirac
   ```

2. Load **norns-dirac** from SELECT. The first time, it installs its SuperCollider
   plugin and shows **"engine installed. SYSTEM > RESTART"**.
3. Do **SYSTEM > RESTART**, then load **norns-dirac** again. You'll see the title
   screen, then the loop (the first unit in the chain).

An update that changes the engine shows the same screen once, and needs one
more restart. Updates that don't change the engine load straight away.

### Playing it

Plug a source into the norns input. It runs through a **chain of five
units**, in whatever order you like:

- **loop**: Noether, a stereo looper from the ER-301. With no loop it passes
  the input untouched.
- **dirac**: the ER-301 granular processor.
- **filter**: Varia, the ER-301 variable-bandwidth filter, made multimode.
  *type* sweeps continuously from lowpass through Varia's band to highpass;
  *width* is the band's width, *res* peaks the edges (self-oscillating at
  the top), *peaks* adds Varia's extra resonant peaks inside the band, and
  *phase* swings them across the stereo field. *drive* pushes the signal
  into a soft saturator before the filter, for resonance with grit. The
  display is its live response curve.
- **delay**: stereo, from twin echoes to ping-pong (*spread*).
- **verb**: a reverb (JPverb). It uses no CPU while its mix is 0.

The default chain is loop → dirac → filter → delay → verb, with the filter,
delay and reverb off (mix 0), so it sounds as it always has until you turn
them up.

**Hold K1 to see the chain.** E1 picks a slot, E2 or E3 carries its unit
left or right; release K1 to apply. Changes crossfade, and every unit keeps
what it was doing as it moves (a loop keeps playing). To take a unit out of
the sound, turn its mix down. The order is saved with PSETs.

**Macros.** Past the last unit in the chain view (E1 all the way right) is
**mc**, the macro page: four knobs, M1 to M4, each moving several
parameters at once, each between its own two settings. M1 (*darker*: filter
in and down, reverb damped) and M2 (*space*: reverb and delay in, wider)
come filled; M3 and M4 are empty.

To make your own: on the macro page, pick a macro (E1 / E2 / E3 select it,
underlined) and press **K3**. *learn M3* shows on every page. Now go to any
unit and turn the parameters you want the macro to move, from where they
are to where the macro's far end should be. Press **K3** again to finish.
Where each parameter started is the macro at 0, where you left it is the
macro at 1. Learning a macro again replaces what it moves; a parameter
turned and put back where it was is dropped. Macros save with PSETs.

**Every page shows four parameters**, in two rows. The bright row is the one
E2 and E3 turn; **E1 steps the bright row** (top, bottom, then on to the
unit's next page). Labels are short; the full name of whatever you turn
shows on the page line for a moment. The page line also shows the chain,
with the slot you're on bright.

**The loop pages** (`loop`, `dub`) show the **reel**: the loop as a ring whose
thickness is its loudness, 12 o'clock the seam, clockwise forward. The head is
a dot with a tail that grows the further speed is from 1x, and turns into a
small hollow ring on 1/4, 1/2, 1 or 2x (or 0, or any of them reversed).
Recording winds the ring on from 12 o'clock.

| control | on the loop pages |
|---|---|
| K3 | rec: empty → record → close and play → overdub in → overdub out |
| K2 tap | stop the loop on/off (it fades out and holds its place) |
| K1 held + K2 | undo the last overdub (again = redo) |

The loop closes on the sample you pressed, phase-matched and blended so it
wraps without a click at any speed or direction. *sos* sets how much of the
old loop an overdub keeps; *extend* lets an overdub past the end grow the loop.

**The grain pages** show the **field**: the live buffer as a waveform, with
"now" at the right edge, and each grain as a bright bar where it is reading,
raised or lowered by its pitch.

| control | does |
|---|---|
| E1 | row, then page, within the slot's unit |
| K1 held | the chain: E1 slot, E2/E3 move it, release to apply |
| E2 / E3 | the two parameters in the bright row |
| K2 held + E2/E3 | fine adjust |
| K1 held + K3 | rec, from any page (the field shows *rec* / *dub* while it runs) |
| K2 tap | hold the cloud on/off |
| K3 | fire: spawn grains now (at density 0, the only way they spawn) |
| K1 held + K2 | field shows stereo position instead of buffer position |

| control | on the macro page |
|---|---|
| K3 | learn the selected macro; K3 again (on any page) to finish |

**mix** (out page) blends Dirac against the looper's stereo output: turn it
down to hear the loop itself. *save capture* on the file page saves Dirac's
buffer (2.73 s) to `~/dust/audio/dirac/`.

Dimmed parameters do nothing in the current state (for example, speed in live
mode, head spread with multi off, or undo with nothing to undo). Every
parameter is also in **PARAMS**, for MIDI mapping and PSETs.

### MIDI

Plug in a controller; pick it in PARAMS > *midi device* (and a channel, or
*omni*). These CCs work with no setup. Whatever you turn shows its full
name on the page line, so you can check a mapping by moving it.

| CC | controls | | CC | controls |
|---|---|---|---|---|
| 16 | macro M1 | | 26 | filter res |
| 17 | macro M2 | | 27 | filter type |
| 18 | macro M3 | | 28 | filter drive |
| 19 | macro M4 | | 29 | filter mix |
| 20 | loop level | | 30 | delay time |
| 21 | loop speed | | 31 | delay feedback |
| 22 | dirac mix | | 85 | delay mix |
| 23 | dirac density | | 86 | reverb mix |
| 24 | grain length | | 87 | reverb time |
| 25 | filter freq | | | |

Buttons (a CC sent at 64 or above, as most pads and buttons do):

| CC | does |
|---|---|
| 102 | loop rec / close / overdub |
| 103 | loop stop on/off |
| 104 | loop undo |
| 105 | dirac fire |
| 106 | dirac hold on/off |

The macros are the best things to put on knobs: one CC moves a whole
gesture. For anything else, norns' own MIDI mapping still works (PARAMS >
MAP); avoid giving a CC both meanings.


**Files:** on the **file** page, turn E3 on *sample* to open the browser and
pick a file from `~/dust/audio`. Files that aren't 48 kHz are converted once
(into `~/dust/audio/dirac/.cache/`). *source* switches between live input and
the sample. Saved buffer captures load straight back in as samples.

### Known issues

- One brief click when the script loads, while the engine allocates its
  memory.
- Converting a long non-48 kHz file takes a few seconds the first time.
- In sample mode the waveform shows the file, not the regeneration buffer
  that feedback writes into.

### Reporting a problem

Please include:

- what you did, what you expected, and what happened;
- your norns (official or shield, and which Pi) and its norns version;
- if anything errored, maiden's output after loading norns-dirac.

### If you SSH into a norns shield

Set `RemoveIPC=no` in `/etc/systemd/logind.conf` and reboot. Without it,
every SSH logout deletes JACK's shared memory, and audio connections break in
ways that look like script bugs. (Only matters if you log in over SSH.)

### Building the engine yourself

Only needed on a 64-bit norns image, or to work on the code: on the norns,

```
cd ~/dust/code/norns-dirac/ugen && make install
```

then SYSTEM > RESTART. `make install` marks the engine as a source build, so
the script won't replace it with the prebuilt one.

---

## What this is

The DSP is the **canonical Dirac engine**, vendored verbatim from the ER-301
repo — not a reimplementation. The same C++ that runs on the ER-301 and on the
Daisy Seed (`DAISY-SEED-PORT.md`) runs here, wrapped as a
SuperCollider UGen and driven by a Lua script.

That is the whole design constraint: **one engine, ported.** A SuperCollider
rewrite would fork the DSP and every fix would have to be made twice.

## Phase 0 — what is done, and what proves it

```
make check
```

runs four gates:

| gate | what it proves |
|---|---|
| `verify-vendor` | `engine/` is byte-identical to the upstream ER-301 source |
| `shimtest` | the vendored engine compiles against `norns/od/` — a THIRD implementation of the six `od::` symbols, after the ER-301's and the host harness's |
| `hosttest` | all 17 ported ER-301 suites pass here |
| `reference` | this build renders `ident` **bit-for-bit** identical to the canonical engine |

That last one is the important one. `test/reference/ident-v0.2.12.bin` is the
canonical engine's output for a set of deterministic scenarios — fixed RNG
seed, fixed control values, live and sample mode. It is **the acceptance test
for Phase 1**: when the UGen exists, render the same scenarios through it in
non-realtime on the Pi and diff against this file.

Correctness of this port is a byte comparison, not a listening test.

## Layout

```
engine/          vendored Dirac.{h,cpp} — DO NOT EDIT (see ENGINE-PROVENANCE.md)
norns/od/        the shim: the six od:: symbols, for SuperCollider (163 lines)
test/host/       the ported ER-301 harness, unchanged from upstream
test/reference/  the canonical ident render
docs/            NORNS-PORT.md — platform notes, interface design, the plan
ugen/            (Phase 1) scsynth plugin wrapper
lib/             (Phase 2) Engine_Dirac.sc
norns-dirac.lua  the script
```

## The shim, and the one real difference

`norns/od/` mirrors the ER-301's surface, with one structural change:

**Ports do not own their buffers.** On the ER-301 a `Port` carries
`float mBuf[FRAMELENGTH]`. Under scsynth the audio lives in the graph's wires —
`IN(n)` / `OUT(n)` return pointers the server owns, which can move between
calls. So a `Port` here is a named pointer the wrapper re-points every block.
The engine never notices: it only calls `buffer()`, and it re-reads that every
block already.

An unconnected inlet points at a shared zero block, matching the ER-301
firmware (`Inlet::buffer()` returns `ZeroOutput.buffer()` when nothing is
patched). Several exact-bypass behaviours depend on that reading as real zeros
rather than null.

## Known unknowns, carried into Phase 1

- **Block size.** `FRAMELENGTH` is 128 on the ER-301 and several per-block
  budgets are tuned to it (`kSnapPerBlock`, grain spawn decisions). scsynth's
  block size is a server setting. Build with `-DFRAMELENGTH=<n>` once the real
  value is known — and expect the `reference` diff to catch a mismatch.
- **`mCapBuf` is 512 KB and must come from `RTAlloc`**, not `std::vector`:
  scsynth forbids allocation on the audio thread. The engine never allocates in
  `process()`; the risk is the constructor path.

## Licence

Apache-2.0. See `LICENSE` and `NOTICE`. Engine © Nick Breinich (nickb808).
