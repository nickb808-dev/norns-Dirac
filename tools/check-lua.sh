#!/bin/bash
# check-lua.sh — parse every Lua file before it reaches the norns.
#
# Lua has no compile step, so a syntax error is invisible until the file is
# require'd at runtime. On the ER-301 that cost about twenty device round-trips:
# a regex that deleted trace calls swallowed one line of a two-line statement,
# the orphaned continuation was a syntax error, and the unit simply failed to
# load with a message that named the unit rather than the line.
#
# Same exposure here, and worse feedback: a broken dirac.lua shows up on the
# norns as a script that will not start.
#
# Uses luac when present (the real Lua compiler, so the real grammar) and falls
# back to python's luaparser. If NEITHER is available this FAILS rather than
# passing quietly — an unavailable checker is not a clean bill of health.
set -u
cd "$(dirname "$0")/.." || exit 2

FILES=$(find . -name '*.lua' -not -path './build/*' | sort)
[ -z "$FILES" ] && { echo "check-lua: FAIL  no .lua files found — wrong directory?"; exit 1; }

if command -v luac >/dev/null 2>&1;      then LUAC=luac
elif command -v luac5.4 >/dev/null 2>&1; then LUAC=luac5.4
elif command -v luac5.3 >/dev/null 2>&1; then LUAC=luac5.3
else LUAC=""; fi

fail=0
if [ -n "$LUAC" ]; then
    for f in $FILES; do
        if $LUAC -p "$f" 2>/tmp/luaerr; then
            echo "check-lua: OK    $f"
        else
            echo "check-lua: FAIL  $f"; sed 's/^/                 /' /tmp/luaerr; fail=1
        fi
    done
    echo "check-lua: parsed with $LUAC (the real Lua grammar)"
    exit $fail
fi

if python3 -c 'import luaparser' 2>/dev/null; then
    for f in $FILES; do
        if python3 - "$f" <<'PY'
import sys
from luaparser import ast
src = open(sys.argv[1]).read()
try:
    ast.parse(src)
except Exception as e:
    print(e); sys.exit(1)
PY
        then echo "check-lua: OK    $f"
        else echo "check-lua: FAIL  $f"; fail=1; fi
    done
    echo "check-lua: parsed with python luaparser (luac not installed)"
    exit $fail
fi

echo "check-lua: FAIL  no Lua parser available (luac or python luaparser)."
echo "                 Refusing to report a pass without having checked."
echo "                 apt install lua5.3   OR   pip install luaparser"
exit 1
