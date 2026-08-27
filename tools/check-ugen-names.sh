#!/bin/bash
# check-ugen-names.sh — the three lists that must agree, checked mechanically.
#
# A UGen has its interface written down in three places, and nothing in the
# toolchain notices when they drift apart:
#
#   1. the engine's registration order   engine/Dirac.cpp, Dirac::Dirac()
#   2. the wrapper's input enum          ugen/DiracUGen.cpp
#   3. the SC class's argument order     ugen/Dirac.sc.in
#
# Drift produces a synth that runs perfectly with every control on the wrong
# knob — no error, no crash, just wrong. And the UGen NAME must match between
# the plugin's DefineDtorUnit and the SC class, or SynthDefs fail with "UGen
# not installed", which reads like a server problem rather than a naming one.
# That one actually happened.
set -u
cd "$(dirname "$0")/.." || exit 2
fail=0

# ── 1. the registered name vs the SC class name ──────────────────────────────
reg=$(grep -oP 'DefineDtorUnit\(\K[A-Za-z_]+' ugen/DiracUGen.cpp | head -1)
cls=$(grep -oP '^\s*\K[A-Za-z_]+(?=\s*:\s*MultiOutUGen)' ugen/Dirac.sc.in | head -1)
if [ "$reg" = "$cls" ]; then
    echo "check-ugen-names: OK    unit registered as '$reg', SC class is '$cls'"
else
    echo "check-ugen-names: FAIL  plugin registers '$reg' but SC class is '$cls'"
    echo "                        SynthDefs would fail with \"UGen '$cls' not installed\""
    fail=1
fi

# ── 2. inlet order: engine vs wrapper ────────────────────────────────────────
# The engine's order is the addInput() sequence in the constructor; the
# wrapper's is the switch in portFor(). Compare the MEMBER names, which is the
# only thing both files spell identically.
engine_order=$(sed -n '/^Dirac::Dirac()/,/^}/p' engine/Dirac.cpp \
               | grep -oP 'addInput\(\K[A-Za-z_]+')
wrapper_order=$(sed -n '/od::Port \*portFor/,/^}/p' ugen/DiracUGen.cpp \
                | grep -oP 'return &d->\K[A-Za-z_]+')

# An empty list on either side means the extraction broke, not that the orders
# agree. Without this the check passes vacuously and reports "0 inlets", which
# is how a gate becomes a rubber stamp.
if [ -z "$engine_order" ] || [ -z "$wrapper_order" ]; then
    echo "check-ugen-names: FAIL  could not extract the inlet order"
    echo "                        engine: $(echo "$engine_order" | grep -c .) names," \
         "wrapper: $(echo "$wrapper_order" | grep -c .) names"
    echo "                        the parser is broken, not the code under test"
    fail=1
elif [ "$engine_order" = "$wrapper_order" ]; then
    n=$(echo "$engine_order" | grep -c .)
    echo "check-ugen-names: OK    $n inlets, wrapper order matches engine order"
else
    echo "check-ugen-names: FAIL  wrapper inlet order does not match the engine's"
    diff <(echo "$engine_order") <(echo "$wrapper_order") \
        | sed 's/^/                        /'
    fail=1
fi

# ── 3. argument count: wrapper vs SC class ───────────────────────────────────
# Counting args in the .sc is approximate, so this checks the TOTAL only —
# enough to catch an inlet added upstream and wired in one place but not both.
n_wrap=$(sed -n '/od::Port \*portFor/,/^}/p' ugen/DiracUGen.cpp | grep -c 'return &d->')
n_opts=$(grep -c 'Opt\.set(' ugen/DiracUGen.cpp)
n_sc=$(sed -n '/\*ar {/,/multiNew/p' ugen/Dirac.sc.in \
       | grep -oP '\b[a-zA-Z][a-zA-Z0-9]*\s*=' | wc -l)
want=$((n_wrap + n_opts))
if [ "$n_sc" -eq "$want" ]; then
    echo "check-ugen-names: OK    $n_sc SC arguments = $n_wrap inlets + $n_opts options"
else
    echo "check-ugen-names: FAIL  Dirac.sc declares $n_sc arguments, wrapper wants $want"
    echo "                        ($n_wrap inlets + $n_opts options)"
    fail=1
fi

exit $fail
