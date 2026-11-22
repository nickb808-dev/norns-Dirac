#!/bin/bash
# check-prebuilt.sh - the shipped plugins must be built from these sources.
set -u
cd "$(dirname "$0")/.."
for so in Dirac Noether Varia; do
    if [ ! -f ugen/prebuilt/$so.so ] || [ ! -f ugen/prebuilt/BUILD ]; then
        echo "check-prebuilt: FAIL  ugen/prebuilt/{$so.so,BUILD} missing - run tools/make-prebuilt.sh"
        exit 1
    fi
    if ! file ugen/prebuilt/$so.so | grep -q "ELF 32-bit LSB shared object, ARM"; then
        echo "check-prebuilt: FAIL  ugen/prebuilt/$so.so is not a 32-bit ARM shared object"
        exit 1
    fi
done
want=$(bash tools/prebuilt-sources.sh)
have=$(awk '/^sources /{print $2}' ugen/prebuilt/BUILD)
if [ "$want" != "$have" ]; then
    echo "check-prebuilt: FAIL  ugen/prebuilt/*.so are STALE (built from $have, sources are $want)"
    echo "                      run tools/make-prebuilt.sh before shipping"
    exit 1
fi
echo "check-prebuilt: OK    ugen/prebuilt/{Dirac,Noether,Varia}.so match the sources ($want), ARM"
