# ugen/Makefile — build the Dirac scsynth plugin natively on the norns.
#
#   make          build Dirac.so
#   make install  copy Dirac.so + Dirac.sc into the SC Extensions dir
#   make info     print what was detected, without building
#
# Built ON THE TARGET on purpose. The Pi runs a 32-bit armv7l userland (probed:
# `uname -m` = armv7l on a Pi 4B), so a plugin must match scsynth's ABI exactly
# or it will not load — and a plugin that fails to load looks identical to a
# broken one from the Lua side. Compiling natively makes the ABI question
# answer itself.

PLUGIN   := Dirac
ENGINE   := ../engine/Dirac.cpp
SHIM     := ../norns/od/shim.cpp
WRAPPER  := DiracUGen.cpp

# ── scsynth's block size is NOT a free choice ────────────────────────────────
# The engine bakes FRAMELENGTH in at compile time. norns launches scsynth with
# no -z, so it runs at scsynth's default of 64. The wrapper refuses to run on a
# mismatch rather than reading past the ends of the graph's wires, so a wrong
# value here is loud, not silent — but set it right.
#
# Override if norns ever changes: make FRAMELENGTH=128
FRAMELENGTH ?= 64

# ── locating the plugin headers ──────────────────────────────────────────────
# Probed at /usr/local/include/SuperCollider/plugin_interface on the target.
# Searched rather than hardcoded so a source build of SC elsewhere still works.
SC_CANDIDATES := \
  /usr/local/include/SuperCollider \
  /usr/include/SuperCollider \
  $(HOME)/supercollider/include

SC_DIR := $(firstword $(foreach d,$(SC_CANDIDATES),$(if $(wildcard $(d)/plugin_interface/SC_PlugIn.h),$(d))))

SC_INC := -I$(SC_DIR)/plugin_interface -I$(SC_DIR)/common -I$(SC_DIR)

# 32 grains, twice the ER-301's 16. Upstream's DIRAC_MAX_GRAINS option; the
# Pi 4 runs the whole engine at maximum for 2-4% of scsynth's deadline.
# lib/params.lua's density and grains maxima must equal this; check-params.sh fails otherwise.
MAX_GRAINS ?= 32

# ── flags ────────────────────────────────────────────────────────────────────
# -ffast-math matches how the engine is built everywhere else. It DOES change
# results slightly, which is expected and quantified: refdiff.py's tolerances
# come from measuring exactly this kind of variation.
#
# -fno-finite-math-only is NOT optional. -ffast-math alone lets the compiler
# assume NaN/Inf never happen and delete the engine's sanitize()/isfinite()
# guards (found upstream in 0.2.11). On the audio thread that turns one bad
# control value into a NaN that sticks in the feedback ring.
#
# No -march/-mtune: the distro compiler already targets this machine, and
# guessing at armv7 flags is a good way to produce a plugin that will not load
# on a Pi 3 later.
CXXFLAGS := -std=c++17 -O2 -ffast-math -fno-finite-math-only -fPIC -Wall -Wno-unused-parameter \
            -DFRAMELENGTH=$(FRAMELENGTH) -DNDEBUG -DDIRAC_MAX_GRAINS=$(MAX_GRAINS) \
            -I../norns -I../engine $(SC_INC)
LDFLAGS  := -shared

EXTDIR := $(HOME)/.local/share/SuperCollider/Extensions/$(PLUGIN)

.PHONY: all info install verify clean

# The first target in a makefile is the default goal, and `verify` was
# accidentally sitting above `all`, so a bare `make` ran the verifier and built
# nothing - while reporting success. State the goal explicitly so the ORDER of
# targets in this file stops being load-bearing.
.DEFAULT_GOAL := all

# ── does the installed plugin actually LOAD? ─────────────────────────────────
# The check that was missing, and its absence cost a working norns. A plugin
# scsynth cannot dlopen stops the SERVER from booting - not just this UGen -
# so norns shows SUPERCOLLIDER FAIL and no script runs at all. The error names
# the server, so it reads like the norns broke rather than like a bad copy.
#
# Boots a throwaway server on a spare port, which is safe while norns is
# running, and greps its output for a load failure naming this plugin.
verify:
	@# An ABSENT plugin generates no complaint, so a grep-only check passes
	@# when nothing is installed. That is not a pass, it is a missing subject.
	@test -f $(EXTDIR)/$(PLUGIN).so || { \
	  echo "verify: FAIL  $(EXTDIR)/$(PLUGIN).so does not exist."; \
	  echo "              Nothing to verify - run 'make install' first."; \
	  exit 1; }
	@# THE REAL TEST: dlopen, exactly what scsynth does at boot, with no audio
	@# hardware involved.
	@#
	@# An earlier version booted a throwaway scsynth and required it to reach
	@# "server ready". That cannot work on a live norns: JACK already owns the
	@# audio device, so the second server dies with "could not initialize
	@# audio" no matter how good the plugin is. The check failed on a perfectly
	@# loadable plugin and rolled back a good install.
	@#
	@# ctypes.CDLL is the same dlopen call. It catches "file too short",
	@# unresolved symbols and ABI mismatches - every failure that stops scsynth
	@# booting - and needs no sound card, no free port and no running server.
	@python3 -c "import ctypes, sys; \
	  ctypes.CDLL('$(EXTDIR)/$(PLUGIN).so'); \
	  print('verify: OK    dlopen succeeded - scsynth will load this plugin')" \
	  || { \
	    echo "verify: FAIL  dlopen refused the plugin (above). scsynth would"; \
	    echo "              refuse to BOOT with this installed - no audio, no"; \
	    echo "              scripts, and the error would name the server."; \
	    exit 1; }
	@# Belt and braces: if scsynth can be started at all, make sure it does not
	@# name our plugin in a complaint. A failure to init audio is EXPECTED here
	@# and is not a plugin problem, so it is not treated as one.
	@out=$$(timeout 20 scsynth -u 57999 -i 2 -o 2 2>&1 | head -40); \
	 if echo "$$out" | grep -qi "$(PLUGIN).so"; then \
	   echo "verify: FAIL  scsynth complained about the plugin:"; \
	   echo "$$out" | grep -i "$(PLUGIN)" | sed 's/^/              /'; \
	   exit 1; \
	 fi; \
	 echo "verify: OK    scsynth start-up mentions no plugin problem"

all: $(PLUGIN).so

$(PLUGIN).so: $(WRAPPER) $(ENGINE) $(SHIM) $(PLUGIN).sc.in
	@if [ -z "$(SC_DIR)" ]; then \
	  echo "ERROR: SC_PlugIn.h not found. Looked in:"; \
	  for d in $(SC_CANDIDATES); do echo "         $$d/plugin_interface"; done; \
	  echo "       Pass one explicitly:  make SC_DIR=/path/to/SuperCollider"; \
	  exit 1; \
	fi
	@echo "building $(PLUGIN).so  (FRAMELENGTH=$(FRAMELENGTH), headers in $(SC_DIR))"
	@rm -f $@
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $(WRAPPER) $(ENGINE) $(SHIM)
	@# A partial .so is not a build error - the link can be interrupted and
	@# leave a short file that make then treats as up to date. scsynth reports
	@# it as "file too short" and REFUSES TO BOOT, which takes the whole norns
	@# down: no audio, no scripts, and an error that names the server rather
	@# than this file. So check the artifact, not just the exit code.
	@sz=$$(wc -c < $@); \
	 if [ "$$sz" -lt 10000 ]; then \
	   echo "build: FAIL  $@ is only $$sz bytes - truncated link."; \
	   rm -f $@; exit 1; \
	 fi; \
	 if ! file $@ 2>/dev/null | grep -q 'shared object'; then \
	   echo "build: FAIL  $@ is not an ELF shared object:"; \
	   file $@ | sed 's/^/             /'; \
	   rm -f $@; exit 1; \
	 fi; \
	 if command -v readelf >/dev/null 2>&1; then \
	   if ! readelf -l $@ >/dev/null 2>&1; then \
	     echo "build: FAIL  $@ has unreadable program headers - truncated."; \
	     rm -f $@; exit 1; \
	   fi; \
	 fi; \
	 echo "build: OK    $@ is a $$sz-byte shared object"
	@echo "OK: $@"
	@file $@ 2>/dev/null || true

info:
	@echo "SC headers   : $(if $(SC_DIR),$(SC_DIR),NOT FOUND)"
	@echo "FRAMELENGTH  : $(FRAMELENGTH)"
	@echo "compiler     : $$($(CXX) --version | head -1)"
	@echo "arch         : $$(uname -m)"
	@echo "install to   : $(EXTDIR)"

# The class file is Dirac.sc.IN in the repo and becomes Dirac.sc only here.
# sclang compiles every *.sc under ~/dust/code, so a Dirac.sc left in the repo
# would be a second definition of the class and the whole class library would
# fail: "duplicate Class found: 'Dirac'". That takes down every script on the
# norns, not just this one.
install: $(PLUGIN).so
	@test -s $(PLUGIN).sc.in || { \
	  echo "install: FAIL  $(PLUGIN).sc.in is missing or EMPTY."; \
	  echo "               Refusing to install a class file with no class in it —"; \
	  echo "               that produces a server that boots but hangs every script."; \
	  exit 1; }
	@grep -qE '^$(PLUGIN) *: *MultiOutUGen' $(PLUGIN).sc.in || { \
	  echo "install: FAIL  $(PLUGIN).sc.in does not declare '$(PLUGIN) : MultiOutUGen'"; \
	  exit 1; }
	mkdir -p $(EXTDIR)
	cp $(PLUGIN).so $(EXTDIR)/
	cp $(PLUGIN).sc.in $(EXTDIR)/$(PLUGIN).sc
	@a=$$(wc -c < $(PLUGIN).sc.in); b=$$(wc -c < $(EXTDIR)/$(PLUGIN).sc); \
	 if [ "$$a" != "$$b" ]; then \
	   echo "install: FAIL  copied class file is $$b bytes, source is $$a"; \
	   exit 1; \
	 fi; \
	 echo "install: OK    $(PLUGIN).so + $(PLUGIN).sc ($$b bytes) -> $(EXTDIR)"
	@a=$$(wc -c < $(PLUGIN).so); b=$$(wc -c < $(EXTDIR)/$(PLUGIN).so); \
	 if [ "$$a" != "$$b" ]; then \
	   echo "install: FAIL  copied .so is $$b bytes, source is $$a"; \
	   rm -f $(EXTDIR)/$(PLUGIN).so; exit 1; \
	 fi
	@# If verify fails, REMOVE the plugin rather than leaving it installed.
	@# A plugin scsynth cannot load bricks the norns at next boot, so "install
	@# failed" must leave the machine bootable, not armed.
	@if ! $(MAKE) --no-print-directory verify; then \
	  echo; \
	  echo "install: rolling back - removing $(EXTDIR)/$(PLUGIN).so"; \
	  rm -f $(EXTDIR)/$(PLUGIN).so; \
	  echo "install: FAILED, but the norns will still boot."; \
	  exit 1; \
	fi
	@# Mark this as a source build, so dirac.lua's first-run installer leaves it
	@# alone instead of replacing it with the prebuilt plugin.
	@echo "source build $$(date -u +%Y-%m-%dT%H:%MZ) on $$(uname -m)" > $(EXTDIR)/BUILD
	@echo
	@echo
	@echo "Restart the audio engine for scsynth to pick it up (SYSTEM > RESET on"
	@echo "the norns, or reboot). scsynth reports plugin load failures at boot —"
	@echo "if Dirac.ar is 'not understood' afterwards, check there first."

clean:
	rm -f $(PLUGIN).so
