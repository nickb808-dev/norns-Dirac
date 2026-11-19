# Pappus vs Dirac — a close comparison, where the port stands, and the test checklist

Written 2026-09-04, after ThruTest came up silent on the shield. Pappus is
`~/Downloads/pappus` (Michael Manning; 6401-line `pappus.lua`, 1532-line
`Engine_Pappus.sc`, 45 test files). Dirac is this repo at commit `e6efb5e` plus
the uncommitted meter/ThruTest work.

One caveat governs everything below. **Pappus is a reference for FORM, not a
proof of anything.** Its own source says so: "NOT VERIFIED HERE ... the polls
exist in the source and have never once fired in a test." It has never run on
this norns. Where Pappus and Dirac agree, that is two unverified opinions
agreeing, not evidence. Where they differ, the difference is worth a look; it
is not automatically a bug in Dirac.

---

## 1. What each one is

**Pappus** is an instrument designed on norns from scratch. All of its DSP is a
single sclang `SynthDef` — two `GrainBuf` granulators reading 60-second capture
buffers, a filterbank, a multitap delay, a colour stage — 96 engine commands,
121 params, and a Lua layer that is most of the program: six-page cell UI,
scene morphing, a modulation matrix, LFO/envelope sources, MIDI, an optional
grid. Everything lives in SuperCollider and Lua; there is no compiled code.

**Dirac** is the opposite shape on purpose. The DSP is 1000 lines of vendored
C++ from the ER-301, compiled into a scsynth plugin (`Dirac.so`), and the
SuperCollider class around it is 160 lines: one function-synth, one command per
inlet. The capture ring (2.73 s, `kCapBufSize = 131072`) lives *inside* the
engine — there are no `Buffer`s in SC at all. The Lua layer is a params table
and a flat scrolling list. Total SC + Lua, about 400 lines against Pappus's
8000.

That asymmetry is the design (`ENGINE-PROVENANCE.md`: one engine, ported), and
it is why the comparison is useful in one direction only: Pappus tells you
what a norns engine *wrapper* has to do. It says nothing about the DSP.

---

## 2. The engine wrapper, line by line

| | Pappus (`Engine_Pappus.sc`) | Dirac (`Engine_Dirac.sc`, now) | note |
|---|---|---|---|
| `alloc` guard | `try { prAlloc } { err.reportError }` | same, copied | an uncaught error in alloc hangs the script on "loading..." with nothing in any log |
| server resources | 9 `Buffer`s + 1 control bus, allocated first, `srv.sync` once, then filled | none | Dirac's ring is inside the UGen; nothing to allocate or free |
| synth creation | `SynthDef(\pappus, {...}).add; srv.sync; Synth.new(\pappus, [...], context.xg, \addToTail)` | `{...}.play(args: [...], target: context.xg)` (implies `\addToHead`) | see §4 — the placement difference is inert |
| input read | `LeakDC.ar([In.ar(inbusl,1), In.ar(inbusr,1)]) * Lag.kr(ingain)` — stereo, DC-blocked, gain ahead of everything | `(In.ar(inbusl,1) + In.ar(inbusr,1)) * 0.5` — mono, no DC block, no gain | engine has one `od::Inlet`, so mono is forced; the missing `LeakDC` is a real gap (§6) |
| bus arguments | `\inbusl in_b[0].index, \inbusr in_b[1].index, \outbus out_b.index` | `\inbusl in_b[0].index, \inbusr in_b[1].index, \out context.out_b` | `Bus.asControlInput` returns `.index`; verified in the dumped SynthDef — control `out` is our own, `.play`'s is `i_out` |
| input selector | `msrc`/`nsrc`: OFF / STEREO / MONO L / MONO R, **default OFF** | none; always live | Pappus README: "select an input to hear something" |
| output stage | `LeakDC → * Lag(amp) → * Lag(fade) → Limiter(limceil) → Out.ar` | `Dirac.ar → Out.ar`; engine does `sanitize` + `softLimit` internally | engine already limits; no fade envelope on free (a click on script change) |
| meters | `Out.kr(mbus, 6)` + `mbus.getnSynchronous(6)` in `addPoll` — never fired in a test | `SendReply.kr → OSCFunc → addPoll(\in_amp, \out_amp)` — graph verified offline, never fired on device | `getnSynchronous` needs sclang's shm interface to the server; SendReply does not |
| commands | 96, hand-listed "because addCommand names have to be greppable" | 32, generated from a symbol list; `check-params.sh` cross-checks Lua = addCommand = SynthDef arg | Dirac's is the stronger gate |
| `free` | synth + 9 buffers + bus | OSCFunc + synth | |
| block-size dependence | none (sclang) | `FRAMELENGTH=64` baked into `Dirac.so`; ctor refuses to run on mismatch | a Pappus advantage the UGen route buys back with the ctor check |

## 3. The Lua layer

| | Pappus | Dirac | note |
|---|---|---|---|
| params | 121, grouped by separator, controlspecs written inline | 29 controls + 3 options generated from `lib/params.lua`, the ER-301's own ranges | single source of truth; the checker enforces it |
| engine calls | `engine.x(v)` direct; a missing engine kills `init()` | `send()` checks `type(engine[id]) == "function"`, flags `NO ENGINE` on screen | Dirac's is safer; norns autoloads the last script on boot, so a hard error in init is a device that errors on every boot |
| polls | 11 polls, every one stopped in `cleanup()` by name | 2 polls, stopped in `cleanup()` as of today | an unstopped poll outlives the script and fires into a dead callback forever (the endless "attempt to call a nil value" this evening) |
| **norns in>out monitor** | `audio.level_monitor(0)` via a param defaulting OFF; restored to 1 in cleanup. Comment: "the engine passes the dry signal through itself, so norns' own monitor path would double it" | untouched | **directly relevant to what you heard.** If the LEVELS monitor is up, the dry input reaches the output regardless of any engine, and `mix` cannot be judged by ear |
| UI | six pages of cells, E1 select / E2 value / E3 fine, scenes, grid, MIDI | flat list, E2 select / E3 value / E1 jump, K2/K3 page | Phase 3 in NORNS-PORT.md is "adopt Pappus's cell model" |
| PSET | yes, plus its own scene store on disk | params only; never round-tripped on device | |
| headless testability | `mock_norns.lua` (402 lines) runs init/redraw/enc/key off-device; engine table populated from the real `addCommand` list | none | Pappus's mock catches "script calls a command the engine doesn't declare" before the hardware does |

## 4. What the comparison actually says about the silence

> **Resolved 2026-11-18. The analysis below was half right.** There were two
> faults, one on each side of the line it draws:
>
> 1. **The device (what §4 predicted).** systemd's `RemoveIPC` was on, so every
>    SSH logout deleted JACK's `/dev/shm` files. Clients already connected kept
>    running; nothing new could connect. After `RemoveIPC=no` and a reboot,
>    `jack_lsp -c` showed correct routing and ThruTest passed audio.
> 2. **The UGen (what §4 ruled out).** scsynth may give a UGen an output buffer
>    that is the same memory as an input nobody else reads. `DiracUGen.cpp`
>    pointed the engine straight at `IN(kIn)` / `IN(kFire)`, so writing the
>    output overwrote the input and the unit went permanently silent, even at
>    mix 0. `Engine_Dirac.sc` always triggers it: `K2A.ar(fire)` has no other
>    reader. Measured on the device: `Dirac.ar(src)` with src read only by Dirac
>    is silent; the same graph with src also metered passes it perfectly. The
>    stub scsynth gave every wire its own buffer, so `ugentest` could not see
>    it. The wrapper now copies its per-sample inlets first, and `ugentest`'s
>    new `aliased` case catches the regression.
>
> "`verify` proves it loads, not that it runs" (item 3 below) was exactly the
> gap. Kept as written for the record.

Both wrappers read the input the same way: `In.ar(context.in_b[n].index)`.
Both place their synth in `context.xg`. From norns' `CroneAudioContext.sc`, the
groups are created `ig = Group.new; xg = Group.after(ig); og = Group.after(xg)`
and the hardware input is written into `in_b` by `\adc` synths **in `ig`**. So
anything in `xg` — head or tail — runs after the input is written. The
`\addToTail` → `\addToHead` change (commit `eccc5df`) and the SynthDef →
`.play` change (`e6efb5e`) cannot have affected input freshness, and the
"bisection" that motivated them compared a SinOsc (needs no input) against
Dirac (needs input). It proved the output path. It did not touch the question
that matters.

ThruTest — the same `.play` form with the DSP replaced by a wire — is silent.
That is the first test to have exercised the input path at all, and it says
the input path is broken *upstream of every line in this repo*. **If Pappus
were installed on this norns today it would be silent too.**

So, ranked by how much they explain:

1. **jack routing.** `jack_lsp -c` on the norns; the ports that matter are
   `SuperCollider:in_1` / `in_2`. Not connected = the whole bug.
2. **What ThruTest's meters read.** Flat at 0.000 confirms (1) from inside SC.
   Moving-but-silent would contradict ToneTest and point at `out_b`.
3. Only after those: the UGen. `make -C ugen verify` already passes (dlopen
   OK, no plugin complaint at scsynth start), so the plugin loads; what has
   never been shown is that it *produces samples inside a running scsynth*.

Off-device, the engine and the SC graph are exonerated: with the exact
`params.lua` defaults and playhead 0 the engine holds a steady 0.208 RMS for 12 s
with no fade and no DC; the SynthDef built from the current function has no
envelope, no duplicate `out` control, and all 33 UGen inputs in enum order.

---

## 5. Where the port stands, against the plan

`README.md` still says "Phase 0 complete ... makes no sound." That is stale in
both directions: much more is built, and it *still* makes no sound.

**Done, and proven off-device**

- Phase 0 entirely: vendored engine, `norns/od/` shim, 17-suite host harness,
  bit-exact `reference` at 128 and `reference64` at 64.
- Phase 1, the parts a dev host can prove: `ugen/DiracUGen.cpp`, `ugen/Dirac.sc.in`,
  hardened `ugen/Makefile` (install/verify/rollback), `ugentest` through a stub
  scsynth, `check-ugen-names.sh` (enum = SC args = engine inlets). On the
  device: `Dirac.so` builds, installs, dlopens, and scsynth boots with it.
- Phase 2, the static half: `Engine_Dirac.sc` (32 commands, alloc guard,
  meters), `lib/params.lua` from the ER-301's numbers, `dirac.lua` with a
  working list UI, `check-params.sh`, `check-lua.sh`, `check-sc-collisions.sh`.
  Both `.sc` files compile in a real sclang (this session, stubbed
  `CroneEngine`).

**Done, but never exercised on the device**

- The UGen producing audio inside scsynth. `verify` proves it loads, not that
  it runs.
- Every command reaching the synth (they register; nothing has confirmed a
  `synth.set` changes a sample).
- Both meter polls.
- `make portcheck` on the Pi — the host harness on ARM plus `refdiff` against
  the x86 reference. There is no record of it having been run.

**Not done**

- Phase 1's actual exit criterion: the `ident` scenarios rendered through the
  UGen in NRT on the Pi, diffed with `refdiff.py`. There is no NRT score
  generator in `tools/` yet; `DiracUGen.cpp` refers to one that does not exist.
- Phase 2's exit: audible, every parameter moving, PSET round-trip.
- Phase 3 (cell UI), Phase 4 (Launchpad), all of v2.
- The two things Pappus has that this repo should copy before the next build:
  an `alloc_test.scd` (boots a real scsynth with a fake context, runs `alloc`,
  invokes every command — "the step that catches bus wiring; compiling the
  SynthDef does not"), and a `mock_norns.lua`.

---

## 6. Test checklist for the next build

In order. Each has a pass condition; do not skip forward on a fail.

**Off-device, before anything is copied**

- [ ] `make check` passes (needs `UPSTREAM=../dirac` for `verify-vendor`; `luacheck` needs `lua5.3` or `luaparser` installed).
- [ ] `bash tools/check-sc-collisions.sh` — only `lib/Engine_*.sc` is scannable, all ASCII.
- [ ] Both `.sc` files compile in sclang against a stubbed `CroneEngine` (the check done this session; worth scripting as `test/sccompile.sh`).
- [ ] `git status` clean or intentionally not; no `.git/index.lock`.

**On the norns, the input path (the current blocker)**

- [ ] `jack_lsp -c` shows `SuperCollider:in_1` and `in_2` connected. Record to what.
- [ ] `thrutest` loaded, synth playing: meters move, footer says `input OK`, you hear it.
- [ ] `SimplePassThru` (norns built-in) also passes audio — an independent second opinion.
- [ ] LEVELS > monitor: note the level. If it is up, turn it down for every listening test below; the dry path will otherwise mask `mix`.

**On the norns, Dirac**

- [ ] `journalctl -u norns-sclang -f` while loading: `Engine_Dirac: loaded` appears; no `alloc failed`, no `REFUSING TO RUN`, no `RTAlloc failed`.
- [ ] Script screen shows `in` meter moving with the synth (this alone proves the input bus reaches the Dirac synth).
- [ ] `mix` = 0.0: you hear the dry synth through Dirac (pure passthrough, no grains). `out` meter moves.
- [ ] `mix` = 1.0, playhead 0.0, density 3, grain length 0.05: grains audible, tracking the input in near real time. (Off-device this holds 0.208 RMS indefinitely.)
- [ ] playhead 1.0: audio *disappears for ~2.7 s* and then returns, delayed. That is correct behaviour — playhead is a delay time in live mode — and it is a cheap proof the ring is being written.
- [ ] Stop the synth: output dies within ~250 ms at playhead 0. (A one-shot source going quiet is not a fade bug.)
- [ ] Each of the 29 controls moves *something* audible or on the `out` meter; the 3 options switch. Tick them off individually.
- [ ] PSET save, change five params, PSET load: all five return.
- [ ] Load another script, then reload dirac: no "attempt to call a nil value", no orphaned polls.
- [ ] SYSTEM > RESTART with dirac as the last script: boots clean, no `error: init`.

**Phase 1 acceptance, once it makes sound**

- [ ] `make portcheck` on the Pi: 14 suites at 64, `refdiff` PASS against `ident-v0.2.12-fl64.bin`.
- [ ] NRT render of the `ident` scenarios through `Dirac.so` in scsynth on the Pi, `refdiff` PASS. (Tool to be written.)

---

## 7. Changes worth making before the next build

Small, and each one is a thing Pappus already learned.

1. **`audio.level_monitor(0)` in `init()`, restored in `cleanup()`**, behind a
   param defaulting off, exactly as Pappus does. Until this exists, no ear-based
   result on this script means anything.
2. **`LeakDC.ar` on the input** before it enters the ring. The ER-301 chain
   provides DC-free input by construction; a norns codec does not, and DC in a
   feedback ring is the one thing that *would* fade or pump.
3. **`test/alloc_test.scd`** for Dirac, modelled on Pappus's: real scsynth,
   fake `context`, run `alloc`, fire every command, assert the synth exists and
   the `in_amp` poll delivers a number when a test signal is written to `in_b`.
   This is the test that would have made the last week unnecessary.
4. **`README.md` status line**: replace "Phase 0 complete" with the state in §5.
5. Consider a short output fade on `free` (Pappus: `Lag.kr(fade, 0.06)`) so a
   script change does not click. Cosmetic; last.
