# norns-dirac — Dirac (canonical ER-301 engine) as a norns script.
#
# Phase 0 targets only. The UGen build arrives in Phase 1, once the SC plugin
# headers are on the Pi.
#
#   make hosttest        build + run the 17-suite ported harness (off-device)
#   make shimtest        build the engine against the NORNS shim (not the host
#                        stubs) — proves the shim is a working third target
#   make verify-vendor   diff engine/ against an upstream checkout; fails on any
#                        difference  (UPSTREAM=../dirac)
#   make check           all three
#
VERSION      := 0.1.0
UPSTREAM     ?= ../dirac
ENGINE       := engine/Dirac.cpp
HOSTINC      := -Itest/host -Iengine
NORNSINC     := -Inorns -Iengine
CXXFLAGS     := -std=c++17 -O2 -ffast-math -Wall -Wno-unused-parameter

.PHONY: all check hosttest shimtest verify-vendor reference clean help
all: help

# ── the ported ER-301 harness ────────────────────────────────────────────────
# Identical source to upstream's test/host. If this passes here and there, the
# vendored engine behaves like the canonical one.
HOSTSUITES := seam fieldpos headsnap snapt colort difft freezet sfbt \
              headscale fbdc windowt tiltt winbankt

hosttest:
	@mkdir -p build
	$(CXX) $(CXXFLAGS) $(HOSTINC) $(ENGINE) test/host/main.cpp -o build/t
	@for s in $(HOSTSUITES); do printf '%-12s ' $$s; ./build/t $$s | tail -1; done
	@./build/t asan >/dev/null && echo "asan        ok"
	@echo ">>> hosttest: all suites reported above"

# ── the engine, built against the NORNS shim ─────────────────────────────────
# The point of Phase 0: the shim is a THIRD implementation of the same six
# symbols, so it must compile the vendored engine untouched. Catches a shim
# that drifted from the ER-301's signatures before any SuperCollider is
# involved.
shimtest:
	@mkdir -p build
	$(CXX) $(CXXFLAGS) $(NORNSINC) -c $(ENGINE) -o build/dirac_norns.o
	$(CXX) $(CXXFLAGS) $(NORNSINC) -c norns/od/shim.cpp -o build/shim.o
	@echo ">>> shimtest: OK — vendored engine compiles clean against norns/od/"

# ── vendoring gate ───────────────────────────────────────────────────────────
# ENGINE-PROVENANCE says the engine is not developed here. This makes that
# checkable rather than aspirational: any local edit fails the build.
verify-vendor:
	@test -d "$(UPSTREAM)/src" || { \
	  echo "verify-vendor: no upstream at $(UPSTREAM) — pass UPSTREAM=<path to dirac>"; \
	  exit 2; }
	@fail=0; for f in Dirac.h Dirac.cpp; do \
	  if diff -q "$(UPSTREAM)/src/$$f" "engine/$$f" >/dev/null 2>&1; then \
	    echo "verify-vendor: OK    engine/$$f matches upstream"; \
	  else \
	    echo "verify-vendor: FAIL  engine/$$f DIFFERS from $(UPSTREAM)/src/$$f"; \
	    echo "                     the engine is vendored, not developed here —"; \
	    echo "                     fix it upstream and re-sync (ENGINE-PROVENANCE.md)"; \
	    fail=1; \
	  fi; \
	done; exit $$fail

# ── the cross-target references ──────────────────────────────────────────────
# `ident` rendered by the CANONICAL engine: deterministic RNG seed, fixed
# control scenarios, sample mode and live mode.
#
# THERE ARE TWO, because block size is not a free parameter here. Grain spawn
# decisions are made once per block and each spawn consumes the RNG, so a
# 64-sample build and a 128-sample build diverge into completely different
# grain clouds — measured: 7.8% of samples match, rms difference 0.30. The
# statistics are identical (every suite passes at both sizes with the same
# numbers) but the waveforms are unrelated. A cross-block-size bit-diff is
# therefore meaningless, and comparing against the wrong one would look like a
# catastrophic port bug.
#
#   ident-v0.2.10.bin       FRAMELENGTH=128 — parity with the ER-301
#   ident-v0.2.10-fl64.bin  FRAMELENGTH=64  — THE PHASE 1 ACCEPTANCE TARGET,
#                                             because norns runs scsynth at 64
#                                             (probed 2026-08-27: launched with
#                                             no -z; scsynth's default is 64)
#
# When the UGen exists, render the same scenarios through it in NRT on the Pi
# at 64 and diff against the fl64 file. "Sounds right" is not an exit
# criterion; this is.
REFERENCE   := test/reference/ident-v0.2.10.bin
REFERENCE64 := test/reference/ident-v0.2.10-fl64.bin

reference: hosttest
	@mkdir -p test/reference
	./build/t ident /tmp/ident-now.bin
	@if cmp -s /tmp/ident-now.bin $(REFERENCE); then 	  echo "reference: OK — this build renders the canonical output bit-for-bit"; 	else 	  echo "reference: FAIL — output drifted from $(REFERENCE)."; 	  echo "           Either the engine was edited here (it must not be —"; 	  echo "           see ENGINE-PROVENANCE.md) or the toolchain changed."; 	  exit 1; 	fi

# ── the same harness at the block size norns actually runs ───────────────────
# Guards two things at once: that the engine behaves at 64 (it does — every
# suite reports the same statistics), and that no block count in the harness is
# secretly a duration. Three suites DID fail here before nb() was introduced,
# for that exact reason: they rendered 80 blocks for a 0.2 s grain and at 64
# that cut the grain off before its tail.
hosttest64:
	@mkdir -p build
	$(CXX) $(CXXFLAGS) $(HOSTINC) -DFRAMELENGTH=64 $(ENGINE) test/host/main.cpp -o build/t64
	@for s in $(HOSTSUITES); do printf '%-12s ' $$s; ./build/t64 $$s | tail -1; done
	@./build/t64 asan >/dev/null && echo "asan        ok"
	@echo ">>> hosttest64: all suites reported above (FRAMELENGTH=64)"

reference64: hosttest64
	@mkdir -p test/reference
	./build/t64 ident /tmp/ident64-now.bin
	@if cmp -s /tmp/ident64-now.bin $(REFERENCE64); then \
	  echo "reference64: OK — 64-sample build matches the norns acceptance target"; \
	else \
	  echo "reference64: FAIL — output drifted from $(REFERENCE64)."; \
	  exit 1; \
	fi

check: verify-vendor shimtest hosttest reference hosttest64 reference64

# ── run this ON THE PI ────────────────────────────────────────────────────────
# Everything in `check` except verify-vendor, which needs an upstream ER-301
# checkout that will not exist on the target.
#
# This is the ARM question, asked on its own and with no SuperCollider in the
# way: does the engine compute the same numbers on a 32-bit ARMv7 A72 with
# gcc 10 as it does on x86-64 with a much newer compiler?
#
# It is worth answering BEFORE the UGen exists, because if the answer is no,
# the wrapper cannot be what is wrong. refdiff.py grades the result — the
# expected outcome is a small float-dialect difference, not bit-equality, and
# the tolerances come from measurement (see tools/refdiff.py).
portcheck: shimtest
	@mkdir -p build
	$(CXX) $(CXXFLAGS) $(HOSTINC) -DFRAMELENGTH=64 $(ENGINE) test/host/main.cpp -o build/t64
	@echo "--- suites at FRAMELENGTH=64 (the block size norns runs) -------------"
	@for s in $(HOSTSUITES); do printf '%-12s ' $$s; ./build/t64 $$s | tail -1; done
	@./build/t64 asan >/dev/null && echo "asan         ok"
	@echo
	@echo "--- the cross-architecture diff --------------------------------------"
	@./build/t64 ident /tmp/ident64-arm.bin >/dev/null
	@python3 tools/refdiff.py /tmp/ident64-arm.bin $(REFERENCE64)
	@echo
	@echo "--- CPU on this machine ----------------------------------------------"
	@printf 'ident render: '; \
	 /usr/bin/time -f '%e s wall' ./build/t64 ident /dev/null 2>&1 | tail -1

clean:
	rm -rf build

help:
	@echo "norns-dirac $(VERSION) — Phase 0"
	@echo "  make check           all six gates"
	@echo "  make hosttest        the ported ER-301 harness at FRAMELENGTH=128"
	@echo "  make hosttest64      the same harness at 64 — what norns runs"
	@echo "  make shimtest        compile the engine against norns/od/"
	@echo "  make verify-vendor   UPSTREAM=../dirac"
	@echo "  make reference       diff vs the canonical 128 render (ER-301 parity)"
	@echo "  make reference64     diff vs the canonical 64 render (norns target)"
	@echo "  make portcheck       RUN THIS ON THE PI — the ARM float question,"
	@echo "                       with no SuperCollider involved"
