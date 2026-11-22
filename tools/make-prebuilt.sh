#!/bin/bash
# make-prebuilt.sh - build the plugins that ship in the repo (Dirac, Noether, Varia), ON THE NORNS.
#
#   tools/make-prebuilt.sh [we@norns.local]
#
# Testers install with ;install and never compile, so the repo carries a
# prebuilt plugin (armv7l, scsynth block 64, 32 grains). This copies the UGen
# sources to a scratch folder on the device, builds there (the installed
# plugin is not touched), fetches the .so into ugen/prebuilt/ and writes
# ugen/prebuilt/BUILD: the source hash (tools/prebuilt-sources.sh), the
# machine, the compiler and the date. norns-dirac.lua installs it when the BUILD on
# the device differs; tools/check-prebuilt.sh fails when it is stale.
set -eu
cd "$(dirname "$0")/.."
HOST=${1:-we@norns.local}
HASH=$(bash tools/prebuilt-sources.sh)
COPYFILE_DISABLE=1 tar cf - --no-xattrs engine norns ugen/DiracUGen.cpp ugen/Dirac.sc.in ugen/NoetherUGen.cpp ugen/Noether.sc.in ugen/VariaUGen.cpp ugen/Varia.sc.in ugen/Makefile 2>/dev/null \
  | ssh -o BatchMode=yes "$HOST" 'rm -rf /tmp/dirac-prebuilt && mkdir -p /tmp/dirac-prebuilt && cd /tmp/dirac-prebuilt && tar xf - 2>/dev/null && make -C ugen >/dev/null && echo "built on $(uname -m), $(g++ --version | head -1)"'
mkdir -p ugen/prebuilt
scp -q "$HOST:/tmp/dirac-prebuilt/ugen/Dirac.so" ugen/prebuilt/Dirac.so
scp -q "$HOST:/tmp/dirac-prebuilt/ugen/Noether.so" ugen/prebuilt/Noether.so
scp -q "$HOST:/tmp/dirac-prebuilt/ugen/Varia.so" ugen/prebuilt/Varia.so
INFO=$(ssh -o BatchMode=yes "$HOST" 'echo "$(uname -m) | $(g++ --version | head -1) | $(grep -m1 VERSION_ID /etc/os-release)"')
{
  echo "sources $HASH"
  echo "target  $INFO | FRAMELENGTH=64 MAX_GRAINS=32"
  echo "built   $(date -u +%Y-%m-%dT%H:%MZ)"
} > ugen/prebuilt/BUILD
cat ugen/prebuilt/BUILD
