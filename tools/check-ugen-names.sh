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

# grep -P is GNU-only: macOS grep has no -P, so these checks failed there before
# they reached the code under test. perl reads the same regex syntax (\K,
# lookarounds) and ships on both macOS and the norns.
pgrep_o() { PAT="$1" perl -ne 'while (/$ENV{PAT}/g) { print "$&\n" }' "${@:2}"; }
cd "$(dirname "$0")/.." || exit 2
fail=0

# ── 1. the registered name vs the SC class name ──────────────────────────────
reg=$(pgrep_o 'DefineDtorUnit\(\K[A-Za-z_]+' ugen/DiracUGen.cpp | head -1)
cls=$(pgrep_o '^\s*\K[A-Za-z_]+(?=\s*:\s*MultiOutUGen)' ugen/Dirac.sc.in | head -1)
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
               | pgrep_o 'addInput\(\K[A-Za-z_]+')
wrapper_order=$(sed -n '/od::Port \*portFor/,/^}/p' ugen/DiracUGen.cpp \
                | pgrep_o 'return &d->\K[A-Za-z_]+')

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
# Wrapper-only inputs that are not engine inlets or options (the sample-mode
# buffer number).
n_extra=$(grep -oE 'IN0\(k(Buf|CapTrig|CapBuf)\)' ugen/DiracUGen.cpp | sort -u | wc -l | tr -d ' ')
n_sc=$(sed -n '/\*ar {/,/multiNew/p' ugen/Dirac.sc.in \
       | pgrep_o '\b[a-zA-Z][a-zA-Z0-9]*\s*=' | wc -l)
want=$((n_wrap + n_opts + n_extra))
if [ "$n_sc" -eq "$want" ]; then
    echo "check-ugen-names: OK    $n_sc SC arguments = $n_wrap inlets + $n_opts options + $n_extra wrapper inputs (sample buffer, capture)"
else
    echo "check-ugen-names: FAIL  Dirac.sc declares $n_sc arguments, wrapper wants $want"
    echo "                        ($n_wrap inlets + $n_opts options + $n_extra buffer)"
    fail=1
fi

# ── Noether: the same three checks ───────────────────────────────────────────
reg=$(pgrep_o 'DefineDtorUnit\(\K[A-Za-z_]+' ugen/NoetherUGen.cpp | head -1)
cls=$(pgrep_o '^\s*\K[A-Za-z_]+(?=\s*:\s*MultiOutUGen)' ugen/Noether.sc.in | head -1)
if [ -n "$reg" ] && [ "$reg" = "$cls" ]; then
    echo "check-ugen-names: OK    unit registered as '$reg', SC class is '$cls'"
else
    echo "check-ugen-names: FAIL  plugin registers '$reg' but SC class is '$cls'"
    fail=1
fi
engine_order=$(sed -n '/^Noether::Noether(/,/^}/p' engine/Noether.cpp \
               | pgrep_o 'addInput\(\K[A-Za-z_]+')
wrapper_order=$(sed -n '/od::Port \*portFor/,/^}/p' ugen/NoetherUGen.cpp \
                | pgrep_o 'return &d->\K[A-Za-z_]+')
if [ -z "$engine_order" ] || [ -z "$wrapper_order" ]; then
    echo "check-ugen-names: FAIL  could not extract Noether's inlet order"
    fail=1
elif [ "$engine_order" = "$wrapper_order" ]; then
    echo "check-ugen-names: OK    $(echo "$engine_order" | grep -c .) Noether inlets, wrapper order matches engine order"
else
    echo "check-ugen-names: FAIL  Noether wrapper inlet order does not match the engine's"
    diff <(echo "$engine_order") <(echo "$wrapper_order") | sed 's/^/                        /'
    fail=1
fi
n_wrap=$(sed -n '/od::Port \*portFor/,/^}/p' ugen/NoetherUGen.cpp | grep -c 'return &d->')
n_opts=$(grep -c 'Opt\.set(' ugen/NoetherUGen.cpp)
n_extra=$(grep -oE 'IN0\(k(Buf|UndoBuf|Clear)\)' ugen/NoetherUGen.cpp | sort -u | wc -l | tr -d ' ')
n_sc=$(sed -n '/\*ar {/,/multiNew/p' ugen/Noether.sc.in \
       | pgrep_o '\b[a-zA-Z][a-zA-Z0-9]*\s*=' | wc -l)
want=$((n_wrap + n_opts + n_extra))
if [ "$n_sc" -eq "$want" ]; then
    echo "check-ugen-names: OK    $n_sc Noether SC arguments = $n_wrap inlets + $n_opts option + $n_extra wrapper inputs (loop, undo, clear)"
else
    echo "check-ugen-names: FAIL  Noether.sc declares $n_sc arguments, wrapper wants $want"
    fail=1
fi

# ── Varia: registered name, and the SC args = the wrapper's enum, in order ───
reg=$(pgrep_o 'DefineSimpleUnit\(\K[A-Za-z_]+' ugen/VariaUGen.cpp | head -1)
cls=$(pgrep_o '^\s*\K[A-Za-z_]+(?=\s*:\s*MultiOutUGen)' ugen/Varia.sc.in | head -1)
if [ -n "$reg" ] && [ "$reg" = "$cls" ]; then
    echo "check-ugen-names: OK    unit registered as '$reg', SC class is '$cls'"
else
    echo "check-ugen-names: FAIL  plugin registers '$reg' but SC class is '$cls'"
    fail=1
fi
# enum kInL, kInR, kFreq... -> inl inr freq ...; SC args lowercased
wrap_args=$(pgrep_o 'enum \{[^}]*\}' ugen/VariaUGen.cpp | pgrep_o '\bk\K[A-Za-z]+' \
            | grep -v '^NumInputs$' | tr 'A-Z' 'a-z')
sc_args=$(sed -n '/\*ar {/,/;/p' ugen/Varia.sc.in | pgrep_o '\b[a-zA-Z][a-zA-Z0-9]*(?=\s*=)' | tr 'A-Z' 'a-z')
if [ -z "$wrap_args" ] || [ -z "$sc_args" ]; then
    echo "check-ugen-names: FAIL  could not extract Varia's inputs"
    fail=1
elif [ "$wrap_args" = "$sc_args" ]; then
    echo "check-ugen-names: OK    $(echo "$sc_args" | grep -c .) Varia SC arguments, same names and order as the wrapper"
else
    echo "check-ugen-names: FAIL  Varia.sc arguments do not match VariaUGen.cpp's enum"
    diff <(echo "$wrap_args") <(echo "$sc_args") | sed 's/^/                        /'
    fail=1
fi

exit $fail
