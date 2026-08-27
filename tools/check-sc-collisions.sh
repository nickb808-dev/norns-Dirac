#!/bin/bash
# check-sc-collisions.sh — no *.sc in this repo may collide with an installed
# SuperCollider class.
#
# WHY THIS EXISTS, and it is not hypothetical:
#
#   ERROR: duplicate Class found: 'Dirac'
#     /home/we/.local/share/SuperCollider/Extensions/Dirac/Dirac.sc
#     /home/we/dust/code/norns-dirac/ugen/Dirac.sc
#   ERROR: There is a discrepancy.
#
# sclang scans ~/dust/code RECURSIVELY and compiles every *.sc it finds. This
# repo lives there on the norns. So the UGen class file, sitting in ugen/ as a
# build input, was ALSO compiled — twice-defined class, class library fails,
# norns shows SUPERCOLLIDER FAIL, and NO script loads. It bricked a working
# norns twice.
#
# The rule: the only *.sc files in this tree may be lib/Engine_*.sc, which are
# MEANT to be picked up from dust/code. Anything else that will be installed
# into Extensions must be named *.sc.in and copied into place by make install.
set -u
cd "$(dirname "$0")/.." || exit 2
fail=0

# Everything sclang would compile out of this repo.
scanned=$(find . -name '*.sc' -not -path './build/*' -not -path './.git/*' | sort)

# The allowed set: norns engine classes in lib/.
allowed=$(find ./lib -name 'Engine_*.sc' 2>/dev/null | sort)

offenders=$(comm -23 <(echo "$scanned") <(echo "$allowed"))

if [ -n "$offenders" ]; then
    echo "check-sc-collisions: FAIL  *.sc that sclang would compile from dust/code:"
    echo "$offenders" | sed 's/^/                           /'
    echo "                           Only lib/Engine_*.sc belongs here. A class that"
    echo "                           is also installed into Extensions must be named"
    echo "                           *.sc.in — see ugen/Dirac.sc.in."
    fail=1
fi

# And the reverse: every *.sc.in must declare a class, since that is the whole
# reason it is kept out of the scan.
for f in $(find . -name '*.sc.in' -not -path './.git/*'); do
    if ! grep -qE '^[A-Za-z_][A-Za-z0-9_]* *: *[A-Za-z]' "$f"; then
        echo "check-sc-collisions: WARN  $f declares no class — is the .in needed?"
    fi
done

# Non-ASCII: sclang's lexer is byte-oriented, and em-dashes in comments were a
# suspect for a full day before the real error was read. Cheap to just forbid.
for f in $scanned $(find . -name '*.sc.in' -not -path './.git/*'); do
    [ -f "$f" ] || continue
    n=$(grep -cP '[^\x00-\x7F]' "$f" 2>/dev/null); n=${n:-0}
    if [ "$n" -ne 0 ] 2>/dev/null; then
        echo "check-sc-collisions: FAIL  $f has $n lines with non-ASCII bytes"
        fail=1
    fi
done

if [ $fail -eq 0 ]; then
    n_ok=$(echo "$allowed" | grep -c . || true)
    n_in=$(find . -name '*.sc.in' -not -path './.git/*' | wc -l)
    echo "check-sc-collisions: OK    $n_ok scanned Engine class(es), $n_in staged .sc.in, all ASCII"
fi
exit $fail
