#!/bin/bash
# check-params.sh — the parameter list appears in three files. Keep them equal.
#
#   lib/params.lua        id =        what the params menu builds
#   lib/Engine_Dirac.sc   addCommand  what matron exposes as engine.<id>
#   lib/Engine_Dirac.sc   SynthDef arg  what the synth actually accepts
#
# The failure this exists to prevent is SILENT. dirac.lua calls engine.<id>(x).
# If Engine_Dirac.sc never declared that command, matron's engine table has no
# such field and the call is a nil index — the parameter moves in the menu,
# nothing changes in the sound, and there is no error anywhere that names the
# parameter. Same story for a command that sets a SynthDef arg that does not
# exist: Synth.set on an unknown name is silently ignored by the server.
#
# Ranges are NOT checked here. They are checked by being written down once, in
# lib/params.lua, and copied from the ER-301 unit rather than remembered.
set -u
cd "$(dirname "$0")/.." || exit 2
fail=0

# The three menu OPTIONS live in dirac.lua rather than lib/params.lua, because
# they are add_option not add_control. They still need commands, so they are
# part of the same comparison.
lua_ids=$( { grep -oP '^\s*\{\s*id\s*=\s*"\K[a-zA-Z]+' lib/params.lua
             grep -oP '^\s*\{\s*id\s*=\s*"\K[a-zA-Z]+Opt' dirac.lua; } | sort -u)

# addCommand names come from the two symbol lists, not from a literal string,
# so extract the symbols inside the two .do { } blocks.
sc_cmds=$(sed -n '/one command per parameter/,/^	}/p' lib/Engine_Dirac.sc \
          | grep -oP '\\\K[a-zA-Z]+' | sort -u)

# SynthDef arguments: everything between `arg` and the closing `;`.
sc_args=$(sed -n '/SynthDef(\\dirac/,/^			    playheadsOpt/p' lib/Engine_Dirac.sc \
          | grep -oP '(?<![a-zA-Z\\])\b[a-zA-Z][a-zA-Z0-9]*(?=\s*=)' | sort -u)

emptycheck() {
    if [ -z "$2" ]; then
        echo "check-params: FAIL  extracted NOTHING for $1 — the parser is broken,"
        echo "                    not the code under test"
        fail=1
        return 1
    fi
    return 0
}
emptycheck "lib/params.lua ids"    "$lua_ids"
emptycheck "addCommand names"      "$sc_cmds"
emptycheck "SynthDef args"         "$sc_args"
[ $fail -ne 0 ] && exit 1

# ── 1. every params.lua id must have an addCommand ───────────────────────────
missing=$(comm -23 <(echo "$lua_ids") <(echo "$sc_cmds"))
if [ -n "$missing" ]; then
    echo "check-params: FAIL  in lib/params.lua but NOT addCommand'd:"
    echo "$missing" | sed 's/^/                      /'
    echo "                    dirac.lua would call a nil engine.<id> and the"
    echo "                    parameter would move while nothing happened"
    fail=1
fi

# ── 2. and the reverse: a command nothing drives ─────────────────────────────
extra=$(comm -13 <(echo "$lua_ids") <(echo "$sc_cmds"))
if [ -n "$extra" ]; then
    echo "check-params: FAIL  addCommand'd but nothing in Lua drives it:"
    echo "$extra" | sed 's/^/                      /'
    fail=1
fi

# ── 3. every command must name a real SynthDef argument ──────────────────────
badarg=$(comm -23 <(echo "$sc_cmds") <(echo "$sc_args"))
if [ -n "$badarg" ]; then
    echo "check-params: FAIL  addCommand names with no matching SynthDef arg:"
    echo "$badarg" | sed 's/^/                      /'
    echo "                    Synth.set on an unknown arg is silently ignored"
    fail=1
fi

if [ $fail -eq 0 ]; then
    n=$(echo "$lua_ids" | grep -c .)
    echo "check-params: OK    $n params+options: Lua = addCommand = SynthDef arg"
fi
exit $fail
