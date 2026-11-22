#!/bin/bash
# prebuilt-sources.sh - print the hash of everything that goes into the three plugins.
# Shared by make-prebuilt.sh (which stamps it into ugen/prebuilt/BUILD) and
# check-prebuilt.sh (which fails when the stamp no longer matches): a shipped
# binary built from older sources is a bug testers would hear, not see.
set -eu
cd "$(dirname "$0")/.."
files=$(ls engine/Dirac.cpp engine/Dirac.h ugen/DiracUGen.cpp ugen/Dirac.sc.in \
           engine/Noether.cpp engine/Noether.h ugen/NoetherUGen.cpp ugen/Noether.sc.in \
           engine/VariaFilter.h engine/svf_math.h ugen/VariaUGen.cpp ugen/Varia.sc.in ugen/Makefile; \
        find norns/od -type f | sort)
for f in $files; do printf '%s\n' "$f"; cat "$f"; done | shasum -a 256 | cut -c1-16
