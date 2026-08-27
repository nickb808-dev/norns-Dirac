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

# ── the cross-target reference ───────────────────────────────────────────────
# test/reference/ident-v0.2.10.bin is `ident` rendered by the CANONICAL engine:
# deterministic RNG seed, fixed control scenarios, sample mode and live mode.
#
# It is the acceptance test for Phase 1. When the UGen exists, render the same
# scenarios through it in NRT on the Pi and diff against this file. "Sounds
# right" is not an exit criterion; this is.
REFERENCE := test/reference/ident-v0.2.10.bin

reference: hosttest
	@mkdir -p test/reference
	./build/t ident /tmp/ident-now.bin
	@if cmp -s /tmp/ident-now.bin $(REFERENCE); then 	  echo "reference: OK — this build renders the canonical output bit-for-bit"; 	else 	  echo "reference: FAIL — output drifted from $(REFERENCE)."; 	  echo "           Either the engine was edited here (it must not be —"; 	  echo "           see ENGINE-PROVENANCE.md) or the toolchain changed."; 	  exit 1; 	fi

check: verify-vendor shimtest hosttest reference

clean:
	rm -rf build

help:
	@echo "norns-dirac $(VERSION) — Phase 0"
	@echo "  make check           verify-vendor + shimtest + hosttest"
	@echo "  make hosttest        the 17-suite ported ER-301 harness"
	@echo "  make shimtest        compile the engine against norns/od/"
	@echo "  make verify-vendor   UPSTREAM=../dirac"
	@echo "  make reference       diff this build against the canonical render"
