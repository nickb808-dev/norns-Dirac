#!/bin/bash
# check-prebuilt.sh - the shipped Dirac.so must be built from these sources.
set -u
cd "$(dirname "$0")/.."
if [ ! -f ugen/prebuilt/Dirac.so ] || [ ! -f ugen/prebuilt/BUILD ]; then
    echo "check-prebuilt: FAIL  ugen/prebuilt/{Dirac.so,BUILD} missing - run tools/make-prebuilt.sh"
    exit 1
fi
want=$(bash tools/prebuilt-sources.sh)
have=$(awk '/^sources /{print $2}' ugen/prebuilt/BUILD)
if [ "$want" != "$have" ]; then
    echo "check-prebuilt: FAIL  ugen/prebuilt/Dirac.so is STALE (built from $have, sources are $want)"
    echo "                      run tools/make-prebuilt.sh before shipping"
    exit 1
fi
if ! file ugen/prebuilt/Dirac.so | grep -q "ELF 32-bit LSB shared object, ARM"; then
    echo "check-prebuilt: FAIL  ugen/prebuilt/Dirac.so is not a 32-bit ARM shared object"
    exit 1
fi
echo "check-prebuilt: OK    ugen/prebuilt/Dirac.so matches the sources ($want), ARM"
