# norns-dirac

**Dirac** — the granular processor from the ER-301 — on monome norns.

Target: **norns shield on a Raspberry Pi 4B**. Works on official norns too.

> **Status (2026-11-18): makes grains on the device.** The UGen, the norns
> engine and a basic list-UI script all run on a norns shield (Pi 4B), with
> live input. The engine is still the v0.2.10 vendored copy; upstream is at
> 0.2.12. Next: the work in `docs/PLAN-SOUND-UI-FILES.md`, which covers the
> engine sync, finer controls, a paged waveform UI, and file load and capture.
> The history of getting to sound is in `docs/PAPPUS-VS-DIRAC.md` §4.
>
> **norns shield setup:** set `RemoveIPC=no` in `/etc/systemd/logind.conf`
> and reboot. Without it, every SSH logout deletes JACK's shared memory, and
> audio connections break in ways that look like script bugs.

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

That last one is the important one. `test/reference/ident-v0.2.10.bin` is the
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
