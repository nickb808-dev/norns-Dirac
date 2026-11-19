#!/bin/bash
# prebuilt-sources.sh - print the hash of everything that goes into Dirac.so.
# Shared by make-prebuilt.sh (which stamps it into ugen/prebuilt/BUILD) and
# check-prebuilt.sh (which fails when the stamp no longer matches): a shipped
# binary built from older sources is a bug testers would hear, not see.
set -eu
cd "$(dirname "$0")/.."
files=$(ls engine/Dirac.cpp engine/Dirac.h ugen/DiracUGen.cpp ugen/Dirac.sc.in ugen/Makefile; \
        find norns/od -type f | sort)
for f in $files; do printf '%s\n' "$f"; cat "$f"; done | shasum -a 256 | cut -c1-16
