# Plan: sound parity, the norns UI, and files

Written 2026-11-18, the day Dirac first made grains on the norns (after the
`RemoveIPC` fix on the device and the input-aliasing fix in `DiracUGen.cpp`).

Three workstreams, in this order:

- **A. Sound:** clear optimizations only. The norns version has a character of
  its own that's worth keeping, so ER-301 parity is not the goal. Fix what is
  plainly a defect (coarse controls, level loss, DC, clipping) and leave the
  voice alone.
- **B. UI:** a waveform-and-grains display with two-knob pages.
- **C. Files:** load a sample the norns way, and capture the live ring to disk.

Every step ends in a check you can run.

---

## Where it differs from the ER-301, and what is actually a defect

Ranked by how likely each is to be audible, with evidence:

1. **Control resolution (likely the biggest, and the cheapest to fix).**
   `dirac.lua` builds every controlspec with no `quantum`, so each encoder
   detent moves 1% of the range. Grain length (0.001–1.0 s) moves in **10 ms
   steps**, so the 10–100 ms sweet spot has about nine settings. Density moves
   0.16 per detent. The ER-301 uses the same linear ranges (`../dirac/assets/Dirac.lua`
   `gb(...)` maps), but with fine 0.001 steps and a fine-adjust mode. On the
   norns you can't dial in what you'd dial in on the ER-301.
2. **Block size: the engine runs at 64 here, 128 on the ER-301.** Grain
   *spawning* is sample-accurate (`mSpawnTimer`, `spawnAt`), but three things
   are per block:
   - **The feedback path is one block long** (`mFeedBuf.assign(FRAMELENGTH)`).
     At 64 the regen loop is half the ER-301's, so its comb colour differs.
   - **Snap's search budget** (`kSnapPerBlock = 2`) doubles in real time.
   - **Window shape and the other per-block reads** update twice as often.

   `reference64` proves the build is bit-exact with *a* 64-sample engine. It
   doesn't prove it matches the ER-301, which runs at 128.
3. **Gain staging.** On the ER-301, ±1.0 is ±10 V, and a typical Eurorack
   source peaks around 0.5. norns line input arrives at whatever level the
   source sends, and `Engine_Dirac.sc` sums L+R and halves it, so a mono
   source on one jack loses 6 dB. Compress, Color and the engine's soft limit
   all respond to level, so the same settings behave differently at a
   different input level.
4. **No modulation.** ER-301 patches usually modulate Dirac's inputs, since
   every control is a GainBias with a CV input. A static norns patch can sound
   flat by comparison. (See B, alt layer / LFOs, later.)
5. **ARM float differences.** These are small. `make portcheck` on the Pi has
   never been run, so this is unverified rather than ruled out.

## A. Sound

**A0. Sync the engine to upstream 0.2.12 (first, and the clearest win).** The
vendored copy is v0.2.10. Upstream has since released:
- **0.2.11:** grains play in tune. A grain's read position was one rounded
  float; transposed grains in live mode could be up to 2 cents off, and in
  sample mode +1 st went 5 cents sharp from ~1 s in and played at unison past
  21.8 s. Every control is now `sanitize()`d against NaN. Integer dials step in
  whole numbers.
- **0.2.12:** removes Color. Old presets still load without it.

Two upstream findings apply to this build too:
- **`-ffast-math` deletes `sanitize()` and `isfinite`** (it implies
  `-ffinite-math-only`). Upstream builds with `-fno-finite-math-only`. Our
  `Makefile` and `ugen/Makefile` use bare `-ffast-math` and must get the same
  flag, or the NaN guards are compiled away on the Pi.
- **Removing Color changes the inlet list.** `DiracUGen.cpp`'s enum and
  `portFor`, `Dirac.sc.in`, `Engine_Dirac.sc`, `lib/params.lua` and the test
  references all follow. `check-ugen-names.sh` and `check-params.sh` catch any
  of them being missed.
- *Check:* `make verify-vendor UPSTREAM=../dirac` passes; the references are
  regenerated from upstream 0.2.12 (its `ident` is bit-identical to 0.2.11);
  every gate is green; it builds and plays on the device.

**A1. Quick wins (one session).**
- Give every param a `quantum` that matches the ER-301's fine step: 0.001 for
  [0,1] controls, and whole steps for integer ones. Hold K1 for an extra
  ×0.1 fine adjust. Consider an exponential warp for grain length and density,
  but compare it against the ER-301's feel first: it's linear there, just
  finer.
- Show **names, not integers,** for option-like params (`controlspec` →
  `params:add_option`, or a formatter). Scale: off, chromatic, Major, minor,
  pent. Major, pent. minor, whole tone (the ER-301's labels). Shape: normal,
  bell, sinc, triangle, decay, ramp, Tukey, square.
- Input stage in `Engine_Dirac.sc`:
  - an `input gain` param (dB, default 0);
  - an `input source` param: L+R (no −6 dB), L, R;
  - `LeakDC.ar` ahead of the ring (already flagged in `PAPPUS-VS-DIRAC.md` §7).
- Check the output: `level` default 0.7, the norns ENG level, and no clipping
  at crone.
- *Check:* knob sweeps feel continuous. A test tone at a known level reads the
  same on the engine's `in` meter whichever input source is selected.

**A2 (optional). A "128" character switch, not a replacement.** The 64-sample
block is part of why this sounds different: the regen loop is half the length,
and Snap and the per-block reads run twice as often. That may well be part of
the character you like. If it's ever worth comparing, the wrapper can collect
two 64-sample blocks and run one 128-sample `process()` (+1.3 ms latency),
exposed as a `block` param (64 / 128) defaulting to **64**. That lets the two
characters be compared directly without losing the current one. Only build it
if you want to hear the difference.

**A3 (cheap sanity check). Run `make portcheck` on the Pi** to confirm ARM
floats don't push the engine off the 64-sample reference. This is one command,
and it catches a real bug if there is one. The NRT bit-exact render and an A/B
against a real ER-301 are parked: they answer a parity question we're no
longer asking.

## B. UI

**Screen (128×64, 16 levels).**

```
┌──────────────────────────────────────────────┐
│ ▁▂▅▇▅▃▂▁▁▂▃▅▆▅▃▂ waveform peaks (dim 2–4)     │  rows 0–41: the field
│      ·  ˚ ·  ●   grains: x = read position,   │
│    ·   ●  ·      y = pitch, brightness = env  │
│   ▲ playhead(s) (10)        │ write head (15) │
├──────────────────────────────────────────────┤
│ GRAIN  ● ○ ○ ○ ○ ○ ○ ○ ○                      │  row 44: page + dots
│ density   3.00      length   50 ms            │  rows 52–62: E2 | E3
└──────────────────────────────────────────────┘
```

- The field combines the ER-301's two views, `WaveHeadView` (waveform +
  playhead) and `GrainFieldView` POSITION mode (grains where they read), in one
  128-pixel strip. Grains fade out over a few frames instead of blinking.
  Freeze stops the write head and shows a small snowflake.
- **Alt view** (K1+K2): x = stereo pan instead of position. That's the
  ER-301's STEREO field.

**Controls.**

| | |
|---|---|
| E1 | page |
| E2 / E3 | the page's two params |
| K1 held + E2/E3 | the page's alt pair (and fine adjust on the main pair) |
| K2 | freeze (Hold) toggle |
| K3 | fire (manual grain burst) |
| K1 + K3 | capture the ring to disk (C2) |

**Pages (main pair / alt pair).**

| page | E2 | E3 | alt E2 | alt E3 |
|---|---|---|---|---|
| GRAIN | density | length | grains cap | shape (window) |
| SCAN | playhead | speed | pos jitter | reverse prob |
| PITCH | transpose | scatter | scale | v/oct |
| TONE | texture | tilt | tilt scatter | snap |
| SPACE | spread | binaural | detune | diffuse |
| HEADS | heads | head spread | head tune | playhead mode |
| REGEN | feedback | compress | — | — |
| OUT | mix | level | input gain | input source |
| FILE | source (live / sample) | sample select | save capture | clear |

Every param also stays in the PARAMS menu, so PSET and MIDI mapping work
without extra code.

**Data path for the display.**
- `DiracUGen.cpp` calls `SendNodeReply` (it's in this server's interface
  table, SC 3.13) about 30 times a second with the state the engine already
  exposes publicly: for each of 16 grains, `getGrainSpawnPos`, `getGrainPitch`,
  `getGrainEnvelope` and `getGrainPan`; the head positions; `getCapWritePos`;
  freeze; sample mode.
- `Engine_Dirac.sc` forwards it to matron, the norns Lua process, at
  `127.0.0.1:10111` as `/dirac/viz`. Lua's `osc.event` stores it, and a 15 fps
  clock redraws.
- **Waveform:** live, the wrapper keeps 128 peak bins of 1024 samples each as
  it writes, and sends the ones that changed. For a file, sclang computes peaks
  once at load with `SoundFile`.
- *Check:* frame rate and CPU on the Pi with 16 grains; no xruns in the JACK
  log.

## C. Files

**C1. Load a sample.**
- `params:add_file` opens the standard norns file browser in `~/dust/audio`,
  and PSET remembers the path.
- sclang reads the file into a `Buffer`. The UGen gets a new `buf` input, and
  the wrapper builds an `od::Sample` from the server's buffer (frames,
  channels, data) and calls `setSample`. The engine already supports mono and
  stereo samples. `buf = -1` means live.
- **Sample rate:** the engine hard-codes 48 kHz (`kSampleRate`), so a 44.1 kHz
  file would play about 9% sharp. Convert at load time with `sox`, which is
  installed on this norns, into `~/dust/audio/dirac/.cache/`.
- **Swapping files:** point the engine at the new buffer, wait one block, then
  free the old one, so the audio thread never reads a freed buffer.
- *Check:* load mono and stereo files at 48 k and 44.1 k; pitch is correct;
  switching files during playback never clicks or crashes.

**C2. Capture the ring and save it.**
- To save exactly what Dirac is granulating, including the feedback written
  into it, the wrapper needs to read the capture ring. `mCapBuf` is private to
  the engine, and `getCapWritePos()` is already public.
- **Decided (2026-11-18): the upstream getter.** Add
  `const float *getCapData() const` upstream in the ER-301 repo. It's
  read-only and changes no DSP. Then sync it here under
  `ENGINE-PROVENANCE.md`'s rules.
- On K1+K3, the wrapper copies the ring into a server buffer, rotated so it
  starts at the oldest sample, and sclang writes
  `~/dust/audio/dirac/capture-YYMMDD-HHMMSS.wav`.
- A follow-on option: "capture → load as sample" in one press, which turns a
  frozen moment into sample mode.
- (Rejected alternative: recording the dry input into a parallel buffer. It
  differs from the ring whenever feedback is above 0.)
- The ring is 2.73 s by design. Anything longer is norns TAPE's job.
- *Check:* the saved file, loaded back, granulates the same as the live
  freeze did.

---

## Order of work

1. **Housekeeping.** Commit the aliasing fix. Make `tools/check-ugen-names.sh`
   work without GNU `grep -P`, so `make check` runs on macOS. Correct
   `PAPPUS-VS-DIRAC.md` §4 and the README status. *(Done 2026-11-18.)*
2. **A0** engine sync to 0.2.12 (removes Color, fixes pitch).
3. **A1 quick wins**, then a listening check: does it play better while still
   sounding like itself?
4. **A3** `portcheck` on the Pi (one command).
5. **B:** pages and controls first with a placeholder field, then the viz data
   path, then the waveform.
6. **C1** load, then **C2** capture via the upstream getter.
7. **A2** only if you want to compare characters.

## Decisions

- **Sound:** clear optimizations only; keep the norns character (2026-11-18).
- **Color:** removed, via the upstream 0.2.12 sync (2026-11-18).
- **Option params show names, not integers** (scale, shape) (2026-11-18).
- **Capture:** an upstream read-only `getCapData()` getter, not a dry-input
  recording (2026-11-18).
