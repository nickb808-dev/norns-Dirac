// Host-test stub of od/config.h
//
// FRAMELENGTH is overridable here for one specific reason: norns runs scsynth
// at a 64-sample block (probed 2026-08-27 — the server is launched with no -z,
// and scsynth's default is 64), while the ER-301 is a compile-time 128.
//
// Several per-BLOCK budgets in the engine are tuned to the block size
// (kSnapPerBlock, grain spawn decisions), so a 64-sample build does NOT render
// bit-identically to a 128-sample one. That is expected, not a bug — but it
// means the Phase 1 acceptance diff needs a reference generated at the SAME
// block size the UGen will run at.
//
// Hence two references, both rendered by the canonical engine:
//   ident-v0.2.10.bin       FRAMELENGTH=128  — parity with the ER-301
//   ident-v0.2.10-fl64.bin  FRAMELENGTH=64   — the norns acceptance target
#pragma once
#include <cstdint>

#ifndef FRAMELENGTH
#define FRAMELENGTH 128
#endif
