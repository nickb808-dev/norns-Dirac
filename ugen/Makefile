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

# ── flags ────────────────────────────────────────────────────────────────────
# -ffast-math matches how the engine is built everywhere else. It DOES change
# results slightly, which is expected and quantified: refdiff.py's tolerances
# come from measuring exactly this kind of variation.
#
# No -march/-mtune: the distro compiler already targets this machine, and
# guessing at armv7 flags is a good way to produce a plugin that will not load
# on a Pi 3 later.
CXXFLAGS := -std=c++17 -O2 -ffast-math -fPIC -Wall -Wno-unused-parameter \
            -DFRAMELENGTH=$(FRAMELENGTH) -DNDEBUG \
            -I../norns -I../engine $(SC_INC)
LDFLAGS  := -shared

EXTDIR := $(HOME)/.local/share/SuperCollider/Extensions/$(PLUGIN)

.PHONY: all info install clean

all: $(PLUGIN).so

$(PLUGIN).so: $(WRAPPER) $(ENGINE) $(SHIM) $(PLUGIN).sc.in
	@if [ -z "$(SC_DIR)" ]; then \
	  echo "ERROR: SC_PlugIn.h not found. Looked in:"; \
	  for d in $(SC_CANDIDATES); do echo "         $$d/plugin_interface"; done; \
	  echo "       Pass one explicitly:  make SC_DIR=/path/to/SuperCollider"; \
	  exit 1; \
	fi
	@echo "building $(PLUGIN).so  (FRAMELENGTH=$(FRAMELENGTH), headers in $(SC_DIR))"
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $(WRAPPER) $(ENGINE) $(SHIM)
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
	@echo
	@echo
	@echo "Restart the audio engine for scsynth to pick it up (SYSTEM > RESET on"
	@echo "the norns, or reboot). scsynth reports plugin load failures at boot —"
	@echo "if Dirac.ar is 'not understood' afterwards, check there first."

clean:
	rm -f $(PLUGIN).so
