# norns-dirac — Dirac (canonical ER-301 engine) as a norns script.
#
# `make help` lists the targets. Two are worth knowing about up front:
#
#   make check       everything, off-device. Run before every commit.
#   make portcheck   run this ON THE PI. Asks the one question a dev host
#                    cannot: does the engine compute the same on 32-bit ARM?
#
# The UGen itself lives in ugen/ and is built there, natively on the target.
#
VERSION      := 0.1.0
UPSTREAM     ?= ../dirac
NOETHER_UPSTREAM ?= ../noether
VARIA_UPSTREAM ?= ../variable-bw
ENGINE       := engine/Dirac.cpp
HOSTINC      := -Itest/host -Iengine
NORNSINC     := -Inorns -Iengine
# -fno-finite-math-only: -ffast-math implies -ffinite-math-only, which lets the
# compiler assume NaN/Inf never occur and DELETE the engine's sanitize() and
# isfinite() guards (found upstream in 0.2.11). Upstream builds this way; so must
# every build here, or the NaN guards exist only in the source.
CXXFLAGS     := -std=c++17 -O2 -ffast-math -fno-finite-math-only -Wall -Wno-unused-parameter

.PHONY: all check prebuiltcheck variatest noethertest hosttest shimtest verify-vendor reference ugentest luacheck sccheck paramcheck portcheck clean help
all: help

# ── the Lua and glue-layer gates ─────────────────────────────────────────────
# Lua has no compiler and SuperCollider has no link step, so nothing else in
# the toolchain notices a dropped parameter or an unclosed function until the
# norns tries to run it. These make both checkable here.
luacheck:
	@bash tools/check-lua.sh

sccheck:
	@bash tools/check-sc-collisions.sh

paramcheck:
	@bash tools/check-params.sh

# ── the UGen wrapper, run off-device ─────────────────────────────────────────
# Drives DiracUGen.cpp through a stub scsynth (test/scstub/) and compares its
# output against the bare engine driven directly. Same DSP both sides, same
# machine, so the only thing that can differ is the WIRING — which is all the
# wrapper is.
#
# The per-inlet case is the valuable one: it checks each control inlet ALONE,
# against a full-signal baseline, and reports any inlet that changes no sample
# as INERT rather than counting it as verified.
# The Dirac.so that ships in ugen/prebuilt/ must be built from these sources.
prebuiltcheck:
	@bash tools/check-prebuilt.sh

ugentest:
	@bash tools/check-ugen-names.sh
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -Inorns -Iengine -Itest/scstub -DFRAMELENGTH=64 -DDIRAC_MAX_GRAINS=32 \
	  $(ENGINE) norns/od/shim.cpp test/scstub/driver.cpp -o build/ugentest
	@./build/ugentest
	$(CXX) $(CXXFLAGS) -Wno-mismatched-tags -Wno-inconsistent-missing-override -Inorns -Iengine -Itest/scstub -DFRAMELENGTH=64 \
	  engine/Noether.cpp norns/od/shim.cpp test/scstub/noether_driver.cpp -o build/noethertest
	@./build/noethertest
	$(CXX) $(CXXFLAGS) -Iengine -Itest/scstub test/scstub/varia_driver.cpp -o build/variadrv
	@./build/variadrv

# ── the ported ER-301 harness ────────────────────────────────────────────────
# Identical source to upstream's test/host. If this passes here and there, the
# vendored engine behaves like the canonical one.
HOSTSUITES := pitch nan seam fieldpos headsnap snapt difft freezet sfbt \
              headscale fbdc windowt tiltt winbankt

# Each suite exits non-zero on failure, and so does this. (It used to print
# `| tail -1` and carry on, so a FAIL scrolled past and make still exited 0.)
# $(1) = the harness binary.
define run_suites
	@for s in $(HOSTSUITES); do \
	  if $(1) $$s > build/suite-$$s.txt 2>&1; then printf '  ok   %s\n' $$s; \
	  else cat build/suite-$$s.txt; printf '  FAIL %s\n' $$s; exit 1; fi; done
endef

hosttest:
	@mkdir -p build
	$(CXX) $(CXXFLAGS) $(HOSTINC) $(ENGINE) test/host/main.cpp -o build/t
	$(call run_suites,./build/t)
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
	$(CXX) $(CXXFLAGS) $(NORNSINC) -c engine/Noether.cpp -o build/noether_norns.o
	$(CXX) $(CXXFLAGS) $(NORNSINC) -c norns/od/shim.cpp -o build/shim.o
	@echo ">>> shimtest: OK — both vendored engines compile clean against norns/od/"

# ── Noether: the looper engine, vendored from the ER-301 repo `noether` ──────
# Upstream's 25-suite host harness, run at the ER-301's block size AND at the
# 64 norns runs. The harness here is upstream's with its block counts made
# durations (nb(), identity at 128 — its 128 output is byte-identical to
# upstream's); see ENGINE-PROVENANCE.md.
NOETHERSUITES := ident length seam pulse tri speed sos extend voct persist detent aa viz \
                 undo stop clock bars dub close seamq clean syncdub stoprec barview nan
NTFLAGS := -std=c++17 -O2 -ffast-math -fno-finite-math-only -w
define run_noether
	@for s in $(NOETHERSUITES); do \
	  if $(1) $$s > build/nt-$$s.txt 2>&1; then printf '  ok   noether %s%s\n' $$s "$(2)"; \
	  else cat build/nt-$$s.txt; printf '  FAIL noether %s%s\n' $$s "$(2)"; exit 1; fi; done
endef
noethertest:
	@mkdir -p build
	$(CXX) $(NTFLAGS) -Itest/noether-host -Iengine engine/Noether.cpp test/noether-host/main.cpp -o build/nt
	$(CXX) $(NTFLAGS) -Itest/noether-host-fl64 -Itest/noether-host -Iengine engine/Noether.cpp test/noether-host/main.cpp -o build/nt64
	$(call run_noether,./build/nt,)
	$(call run_noether,./build/nt64, @64)
	@echo ">>> noethertest: 25 suites at 128 and at 64"

# ── the filter: engine/VariaFilter.h, derived from Varia (`variable-bw`) ─────
# Run twice. Strict IEEE first: there, type 0.5 must be BIT-IDENTICAL to a
# verbatim copy of upstream's VariableBW (test/varia-host/ref/). Then with the
# flags the plugin ships with, where -ffast-math may reassociate the two files
# differently (ulps; the suite bounds them).
VTSRC := -Dprivate=public -Itest/varia-host -Itest/varia-host/ref -Iengine \
         test/varia-host/ref/VariableBW.cpp test/varia-host/main.cpp
variatest:
	@mkdir -p build
	$(CXX) -std=c++17 -O2 -ffp-contract=off -w $(VTSRC) -o build/vt-strict
	$(CXX) $(NTFLAGS) -DVT_FAST $(VTSRC) -o build/vt-fast
	@./build/vt-strict
	@./build/vt-fast

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
	done; \
	if [ -d "$(NOETHER_UPSTREAM)/src" ]; then \
	  for f in Noether.h Noether.cpp; do \
	    if diff -q "$(NOETHER_UPSTREAM)/src/$$f" "engine/$$f" >/dev/null 2>&1; then \
	      echo "verify-vendor: OK    engine/$$f matches upstream"; \
	    else \
	      echo "verify-vendor: FAIL  engine/$$f DIFFERS from $(NOETHER_UPSTREAM)/src/$$f"; \
	      fail=1; \
	    fi; \
	  done; \
	else \
	  echo "verify-vendor: FAIL  no Noether upstream at $(NOETHER_UPSTREAM) — pass NOETHER_UPSTREAM=<path>"; \
	  fail=1; \
	fi; \
	if [ -d "$(VARIA_UPSTREAM)/src" ]; then \
	  for f in src/svf_math.h:engine/svf_math.h \
	           src/VariableBW.h:test/varia-host/ref/VariableBW.h \
	           src/VariableBW.cpp:test/varia-host/ref/VariableBW.cpp \
	           test/host/od/config.h:test/varia-host/od/config.h \
	           test/host/od/objects/Object.h:test/varia-host/od/objects/Object.h; do \
	    up=$$(echo $$f | cut -d: -f1); here=$$(echo $$f | cut -d: -f2); \
	    if diff -q "$(VARIA_UPSTREAM)/$$up" "$$here" >/dev/null 2>&1; then \
	      echo "verify-vendor: OK    $$here matches Varia"; \
	    else \
	      echo "verify-vendor: FAIL  $$here DIFFERS from $(VARIA_UPSTREAM)/$$up"; \
	      fail=1; \
	    fi; \
	  done; \
	else \
	  echo "verify-vendor: FAIL  no Varia upstream at $(VARIA_UPSTREAM) — pass VARIA_UPSTREAM=<path>"; \
	  fail=1; \
	fi; exit $$fail

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
#   ident-v0.2.12.bin       FRAMELENGTH=128 — parity with the ER-301; rendered
#                                             by UPSTREAM's own harness
#   ident-v0.2.12-fl64.bin  FRAMELENGTH=64  — THE PHASE 1 ACCEPTANCE TARGET,
#                                             because norns runs scsynth at 64
#                                             (probed 2026-08-27: launched with
#                                             no -z; scsynth's default is 64)
#
# When the UGen exists, render the same scenarios through it in NRT on the Pi
# at 64 and diff against the fl64 file. "Sounds right" is not an exit
# criterion; this is.
REFERENCE   := test/reference/ident-v0.2.12.bin
REFERENCE64 := test/reference/ident-v0.2.12-fl64.bin

# Two tiers. Bit-identical is the strong result. A different compiler (an Xcode
# update did exactly this: Apple clang 21 drifted from the August references by
# at most -81.6 dBFS) is graded by refdiff.py, which passes float-dialect
# differences and fails anything larger. Only a refdiff FAIL means the engine
# behaves differently.
# $(1) = render, $(2) = reference, $(3) = label
define check_ref
	@if cmp -s $(1) $(2); then \
	  echo "$(3): OK — bit-identical to $(2)"; \
	else \
	  echo "$(3): not bit-identical to $(2); grading with refdiff:"; \
	  python3 -I tools/refdiff.py $(2) $(1) || { echo "$(3): FAIL"; exit 1; }; \
	fi
endef

reference: hosttest
	@mkdir -p test/reference
	./build/t ident build/ident-now.bin
	$(call check_ref,build/ident-now.bin,$(REFERENCE),reference)

# ── the same harness at the block size norns actually runs ───────────────────
# Guards two things at once: that the engine behaves at 64 (it does — every
# suite reports the same statistics), and that no block count in the harness is
# secretly a duration. Three suites DID fail here before nb() was introduced,
# for that exact reason: they rendered 80 blocks for a 0.2 s grain and at 64
# that cut the grain off before its tail.
hosttest64:
	@mkdir -p build
	$(CXX) $(CXXFLAGS) $(HOSTINC) -DFRAMELENGTH=64 $(ENGINE) test/host/main.cpp -o build/t64
	$(call run_suites,./build/t64)
	@./build/t64 asan >/dev/null && echo "asan        ok"
	@echo ">>> hosttest64: all suites reported above (FRAMELENGTH=64)"

reference64: hosttest64
	@mkdir -p test/reference
	./build/t64 ident build/ident64-now.bin
	$(call check_ref,build/ident64-now.bin,$(REFERENCE64),reference64)

check: verify-vendor shimtest noethertest variatest hosttest reference hosttest64 reference64 ugentest luacheck sccheck paramcheck prebuiltcheck

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
	$(call run_suites,./build/t64)
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
	@echo "norns-dirac $(VERSION) — Phase 2 (engine + params; no custom UI yet)"
	@echo "  make check           all ten gates (off-device)"
	@echo "  make hosttest        the ported ER-301 harness at FRAMELENGTH=128"
	@echo "  make hosttest64      the same harness at 64 — what norns runs"
	@echo "  make variatest       the filter vs Varia (bit-exact at type 0.5) + its modes"
	@echo "  make shimtest        compile the engine against norns/od/"
	@echo "  make verify-vendor   UPSTREAM=../dirac"
	@echo "  make reference       diff vs the canonical 128 render (ER-301 parity)"
	@echo "  make reference64     diff vs the canonical 64 render (norns target)"
	@echo "  make ugentest        name/order gates + drive the UGen through a stub scsynth"
	@echo "  make luacheck        parse every .lua (no compiler otherwise)"
	@echo "  make sccheck         no *.sc collides with an installed SC class"
	@echo "  make paramcheck      params.lua = addCommand = SynthDef arg"
	@echo "  make portcheck       RUN THIS ON THE PI — the ARM float question,"
	@echo "                       with no SuperCollider involved"
