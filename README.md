# dirac

**Dirac**, the granular processor from the ER-301, on monome norns.

**v0.9.0 beta.** For norns and norns shield (32-bit norns images, which is all
of them today). Developed on a norns shield with a Raspberry Pi 4B.

---

## Beta testers: start here

### Install

1. In maiden, run:

   ```
   ;install https://github.com/nickb808-dev/dirac
   ```

2. Load **dirac** from SELECT. The first time, it installs its SuperCollider
   plugin and shows **"engine installed. SYSTEM > RESTART"**.
3. Do **SYSTEM > RESTART**, then load **dirac** again. You'll see the title
   screen, then the grain field.

An update that changes the engine shows the same screen once, and needs one
more restart. Updates that don't change the engine load straight away.

### Playing it

Plug a source into the norns input. The top of the screen is the **field**:
the live buffer as a waveform, with "now" at the right edge, and each grain as
a bright bar where it is reading, raised or lowered by its pitch.

| control | does |
|---|---|
| E1 | page: grain, shape, scan, pitch, heads, space, regen, out, file |
| E2 / E3 | the two parameters on the page |
| K1 held | the page's second pair of parameters (hold for about 1/4 s) |
| K2 tap | hold the cloud on/off |
| K2 held + E2/E3 | fine adjust |
| K3 | fire: spawn grains now (at density 0, the only way they spawn) |
| K1 held + K3 | save the buffer (2.73 s) to `~/dust/audio/dirac/` |
| K1 held + K2 | field shows stereo position instead of buffer position |

Dimmed parameters do nothing in the current state (for example, speed in live
mode, or head spread with multi off). Every parameter is also in **PARAMS**,
for MIDI mapping and PSETs.

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
- if anything errored, maiden's output after loading dirac.

### If you SSH into a norns shield

Set `RemoveIPC=no` in `/etc/systemd/logind.conf` and reboot. Without it,
every SSH logout deletes JACK's shared memory, and audio connections break in
ways that look like script bugs. (Only matters if you log in over SSH.)

### Building the engine yourself

Only needed on a 64-bit norns image, or to work on the code: on the norns,

```
cd ~/dust/code/dirac/ugen && make install
```

then SYSTEM > RESTART. `make install` marks the engine as a source build, so
the script won't replace it with the prebuilt one.

---

## What this is

The DSP is the **canonical Dirac engine**, vendored verbatim from the ER-301
repo — not a reimplementation. The same C++ that runs on the ER-301, on the
Daisy Seed (`DAISY-SEED-PORT.md`) and in Tap-O-Matic runs here, wrapped as a
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
dirac.lua        (Phase 2) the script
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

Apache-2.0. See `LICENSE` and `NOTICE`. Engine © Nicholas Breinich (nickb808).
