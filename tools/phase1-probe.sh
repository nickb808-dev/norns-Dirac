#!/bin/bash
# phase1-probe.sh — gather everything Phase 1 needs, from the norns itself.
#
# Run this ON THE NORNS (ssh we@norns.local, password: sleep) and send back the
# whole output. It answers, with evidence rather than assumption:
#
#   1. the scsynth BLOCK SIZE actually in use   -> -DFRAMELENGTH=<n>
#   2. the sample rate actually in use
#   3. whether the SuperCollider PLUGIN HEADERS are present, and where
#   4. the SC version, so headers can be matched to it if they must be fetched
#   5. the compiler and CPU, for the UGen build
#
# Read-only. It installs nothing and changes nothing.

echo "=============================================="
echo " norns-dirac Phase 1 probe"
echo " $(date)"
echo "=============================================="

echo
echo "--- 1. hardware / OS -------------------------"
uname -a
echo "model: $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
echo "cores: $(nproc)   mem: $(awk '/MemTotal/{printf "%.1f GB", $2/1048576}' /proc/meminfo)"

echo
echo "--- 2. scsynth: THE ACTUAL INVOCATION --------"
# This is the authoritative answer for block size. scsynth's -z flag IS the
# block size and -S is the sample rate; whatever is on this command line is
# what the engine will really see. Do not trust documentation over this.
ps aux | grep -E '[s]csynth' || echo "scsynth not running — start a script on the norns first, then re-run"
echo
echo "(-z = block size, -S = sample rate, -i/-o = in/out channel counts)"

echo
echo "--- 3. SuperCollider version -----------------"
scsynth -v 2>/dev/null || echo "scsynth not on PATH"
which sclang scsynth 2>/dev/null

echo
echo "--- 4. plugin headers ------------------------"
# SC_PlugIn.h is the one that matters: it is the scsynth plugin API. If this
# is present, the UGen can be built natively with no downloads.
echo "SC_PlugIn.h:"
find / -name 'SC_PlugIn.h' 2>/dev/null | head -5 || true
echo "SC_Unit.h / plugin_interface dirs:"
find / -type d -name 'plugin_interface' 2>/dev/null | head -5 || true
echo "sc3-plugins or existing 3rd-party UGens (proof the path works):"
ls -d ~/.local/share/SuperCollider/Extensions/* 2>/dev/null | head -10 || echo "  (no Extensions dir)"

echo
echo "--- 5. norns SC layer ------------------------"
ls ~/norns/sc 2>/dev/null | head -20 || echo "  (~/norns/sc not found)"
echo "crone startup / server options, if greppable:"
grep -rn "blockSize\|blockSize_\|-z " ~/norns/sc ~/norns/lua/core 2>/dev/null | head -10 || true

echo
echo "--- 6. toolchain -----------------------------"
gcc --version 2>/dev/null | head -1
g++ --version 2>/dev/null | head -1
cmake --version 2>/dev/null | head -1 || echo "cmake: not installed"
echo "free disk: $(df -h / | awk 'NR==2{print $4}')"

echo
echo "=============================================="
echo " done — send this whole block back"
echo "=============================================="
