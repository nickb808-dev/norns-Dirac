#!/bin/bash
# check-params.sh — the parameter list appears in three files. Keep them equal.
#
#   lib/params.lua        id =        what the params menu builds
#   lib/Engine_Dirac.sc   addCommand  what matron exposes as engine.<id>
#   lib/Engine_Dirac.sc   SynthDef arg  what the synth actually accepts
#
# The failure this exists to prevent is SILENT. norns-dirac.lua calls engine.<id>(x).
# If Engine_Dirac.sc never declared that command, matron's engine table has no
# such field and the call is a nil index — the parameter moves in the menu,
# nothing changes in the sound, and there is no error anywhere that names the
# parameter. Same story for a command that sets a SynthDef arg that does not
# exist: Synth.set on an unknown name is silently ignored by the server.
#
# Ranges are NOT checked here. They are checked by being written down once, in
# lib/params.lua, and copied from the ER-301 unit rather than remembered.
set -u

# grep -P is GNU-only: macOS grep has no -P, so these checks failed there before
# they reached the code under test. perl reads the same regex syntax (\K,
# lookarounds) and ships on both macOS and the norns.
pgrep_o() { PAT="$1" perl -ne 'while (/$ENV{PAT}/g) { print "$&\n" }' "${@:2}"; }
cd "$(dirname "$0")/.." || exit 2
fail=0

# Every kind (control, option, toggle, trigger) lives in lib/params.lua, the
# three od::Option menus included, so one extraction covers them all.
# `script = true` params are handled by norns-dirac.lua itself (a file path, an
# unload action), not by an engine command of the same name.
lua_ids=$(grep -v 'script\s*=\s*true' lib/params.lua \
          | pgrep_o '^\s*\{\s*id\s*=\s*"\K[a-zA-Z]+' | sort -u)

# addCommand names come from the two symbol lists, not from a literal string,
# so extract the symbols inside the two .do { } blocks.
sc_cmds=$(sed -n '/One command per parameter/,/^	}/p' lib/Engine_Dirac.sc \
          | pgrep_o '\\\K[a-zA-Z]+' | sort -u)

# SynthDef arguments: everything between `arg` and the closing `;`.
sc_args=$(cat lib/Engine_Dirac.sc \
          | pgrep_o '(?<![a-zA-Z\\])\b[a-zA-Z][a-zA-Z0-9]*(?=\s*=)' | sort -u)

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
    echo "                    norns-dirac.lua would call a nil engine.<id> and the"
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
# ── 4. the grain pool and the two params that range over it ──────────────────
# ugen/Makefile builds the engine with DIRAC_MAX_GRAINS=$(MAX_GRAINS). Density
# and the grains cap must top out at exactly that: past it the engine clamps
# silently and the top of the dial does nothing; below it, the extra grains
# are unreachable.
pool=$(pgrep_o '^MAX_GRAINS\s*\?=\s*\K[0-9]+' ugen/Makefile | head -1)
rate_max=$(pgrep_o '\{\s*id\s*=\s*"rate".*?max\s*=\s*\K[0-9.]+' lib/params.lua | head -1)
grains_max=$(pgrep_o '\{\s*id\s*=\s*"grains".*?max\s*=\s*\K[0-9.]+' lib/params.lua | head -1)
if [ -z "$pool" ] || [ -z "$rate_max" ] || [ -z "$grains_max" ]; then
    echo "check-params: FAIL  could not read MAX_GRAINS / rate max / grains max"
    fail=1
elif [ "${rate_max%.0}" != "$pool" ] || [ "${grains_max%.0}" != "$pool" ]; then
    echo "check-params: FAIL  engine pool is $pool grains, but density max = $rate_max,"
    echo "                    grains max = $grains_max (lib/params.lua)"
    fail=1
else
    echo "check-params: OK    density and grains both top out at the $pool-grain pool"
fi

# ── 5. every param reachable from a page ─────────────────────────────────────
# Inline rather than a tools/*.lua file: norns lists every .lua under
# ~/dust/code as a script, so a helper .lua shows up in SELECT on the device
# (it did: "dirac/tools/check-pages").
if command -v lua >/dev/null 2>&1; then
    lua - <<'LUA' || fail=1
-- check-pages.lua: every param in lib/params.lua is on exactly one page of
-- norns-dirac.lua's PAGES (fire excepted: it is K3), and every page names a real
-- param. A param left off every page is reachable only from the PARAMS menu,
-- which is how "I can't see grain count" happens.
local SPEC = dofile("lib/params.lua")
-- on keys rather than pages: fire is K3, rec is K3 on the loop pages (and
-- K1 + K3 anywhere), stop is K2 on the loop pages
local OFF_PAGE = { fire = "K3", lrec = "K3", lstop = "K2", order = "chain view",
                   m1map = "learned", m2map = "learned", m3map = "learned", m4map = "learned" }
local ids = {}
for _, p in ipairs(SPEC) do ids[p.id] = true end
local src = assert(io.open("norns-dirac.lua")):read("a")
local block = src:match("local PAGES = (%b{})")
if not block then print("check-pages: FAIL  could not find PAGES in norns-dirac.lua"); os.exit(1) end
local used, n = {}, 0
for list in block:gmatch("main%s*=%s*(%b{})") do
  for id in list:gmatch('"([%w_]+)"') do used[id] = (used[id] or 0) + 1; n = n + 1 end
end
for list in block:gmatch("alt%s*=%s*(%b{})") do
  for id in list:gmatch('"([%w_]+)"') do used[id] = (used[id] or 0) + 1; n = n + 1 end
end
local fail = false
for id, c in pairs(used) do
  if not ids[id] then print("check-pages: FAIL  page names unknown param '" .. id .. "'"); fail = true end
  if c > 1 then print("check-pages: FAIL  '" .. id .. "' is on " .. c .. " pages"); fail = true end
end
for id in pairs(ids) do
  if not used[id] and not OFF_PAGE[id] then
    print("check-pages: FAIL  '" .. id .. "' is on no page (PARAMS menu only)"); fail = true
  end
end
if fail then os.exit(1) end
print("check-pages: OK    " .. n .. " page slots, every param on exactly one page (fire on K3)")
LUA
else
    echo "check-params: SKIP  pages check (no lua interpreter)"
fi

# ── 6. no command may shadow matron's engine-table functions ────────────────
# engine.<name> resolves to norns' OWN function first for these names, so a
# command called e.g. "load" is unreachable: engine.load(path) asks norns to
# load an engine called <path>. That happened (sample loading, 2026-11-18).
reserved="add_command commands is_loading list_commands load name names register register_commands"
all_cmds=$( { echo "$sc_cmds"; pgrep_o 'addCommand\("\K[a-zA-Z_]+' lib/Engine_Dirac.sc; } | sort -u)
clash=""
for c in $all_cmds; do
    for r in $reserved; do [ "$c" = "$r" ] && clash="$clash $c"; done
done
if [ -n "$clash" ]; then
    echo "check-params: FAIL  commands shadow norns engine functions:$clash"
    fail=1
else
    echo "check-params: OK    no command shadows a norns engine-table function"
fi

exit $fail
