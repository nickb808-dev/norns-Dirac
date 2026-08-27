// norns/od/config.h — the norns/SuperCollider shim for od/config.h
//
// FRAMELENGTH IS NOT 128 HERE, NECESSARILY.
//
// On the ER-301 it is a compile-time 128. Under scsynth the block size is a
// server option, and norns sets it; the engine must be built against whatever
// that turns out to be. `Dirac.cpp` uses FRAMELENGTH as the loop bound in
// process() and — this is the part that matters — several per-BLOCK budgets
// are tuned to it:
//
//   kSnapPerBlock = 2      Snap search steps per block
//   grain spawn decisions  once per block
//
// At a 64-sample block those rates DOUBLE in real time. Do not "fix" that by
// editing the engine (it is vendored; see ENGINE-PROVENANCE.md). Either build
// scsynth's block size to 128, or rescale at the wrapper.
//
// Phase 1's exit criterion — diffing an NRT render against the host `ident`
// reference — is what catches a mismatch here, which is exactly why that diff
// comes before any UI work.
#pragma once
#include <cstdint>

#ifndef FRAMELENGTH
// Overridden by the build (-DFRAMELENGTH=...) once the real scsynth block
// size is known. 128 matches the ER-301, so an un-overridden build is
// bit-comparable with the host reference by construction.
#define FRAMELENGTH 128
#endif
