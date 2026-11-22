-- dirac v0.13.0 beta
-- a chain of five units:
-- looper, granular, filter
-- (from the ER-301), delay,
-- reverb
-- by nickb808
--
-- first run installs the
-- engine: then SYSTEM >
-- RESTART and load again
--
-- E1 row, then page
-- E2 / E3 the bright row
-- K2 held + E2/E3: fine
-- K1 held + K3: rec (loop)
--
-- K1 held: the chain
--   E1 slot, E2/E3 move
--   it; release K1
-- (past the end: macros,
--   K3 learns one)
--
-- MIDI CCs: see README
--
-- loop pages (the reel):
-- K3 rec: record / close /
--   overdub in / out
-- K2 tap: stop on/off
-- K1 held + K2: undo
--
-- grain pages (the field):
-- K3: fire
-- K2 tap: hold on/off
-- K1 held + K2: field x =
--   position / stereo
--
-- file page: E3 on sample
-- opens the file browser
--
-- every param is also in
-- the PARAMS menu

engine.name = "Dirac"

local fileselect = require "fileselect"

-- Relative to this script's own folder, so the install folder can be named
-- anything (it is `dirac` on the device; the repo is `norns-dirac`).
local SPEC = include("lib/params")
local splash = include("lib/splash")

local VERSION = "0.13.0-beta.1"

-- ── first run: install the engine's SuperCollider plugin ─────────────────────
-- Testers install with ;install and never compile. The repo carries prebuilt
-- Dirac.so, Noether.so and Varia.so (ugen/prebuilt/, stamped with one source hash in
-- BUILD); this runs as
-- the script file is read - BEFORE norns loads the engine - and copies it into
-- SuperCollider's Extensions folder whenever the BUILD there differs. scsynth
-- only reads plugins at boot, so a fresh install then needs SYSTEM > RESTART,
-- and the script says so instead of starting.
--
-- Files are replaced by rename, never overwritten in place: scsynth has the
-- old Dirac.so mapped, and rewriting a mapped library under it can crash it.
-- A checkout with no ugen/prebuilt/ (building from source) is left alone.
local EXT = "/home/we/.local/share/SuperCollider/Extensions/Dirac/"
local install_state = nil      -- nil: ready. "installed" | "unsupported" | "failed"

local function slurp(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("a"); f:close()
  return s
end

do
  local here = norns.state.path
  local want = slurp(here .. "ugen/prebuilt/BUILD")
  local have = slurp(EXT .. "BUILD")
  local installed = util.file_exists(EXT .. "Dirac.so") and util.file_exists(EXT .. "Noether.so")
                    and util.file_exists(EXT .. "Varia.so")
  -- `make install` (ugen/Makefile) stamps "source build": someone building
  -- their own engine keeps it.
  local source_build = have ~= nil and have:match("^source build") ~= nil
  if want and not (installed and source_build) and (want ~= have or not installed) then
    local arch = (util.os_capture("uname -m") or ""):gsub("%s+", "")
    if arch ~= "armv7l" then
      install_state = "unsupported"
      print("dirac: prebuilt engine is for armv7l, this norns is " .. arch .. " - build from source (README)")
    else
      local q = function(x) return "'" .. x:gsub("'", "'\\''") .. "'" end
      local cmd = table.concat({
        "mkdir -p " .. q(EXT),
        "cp " .. q(here .. "ugen/prebuilt/Dirac.so") .. " " .. q(EXT .. "Dirac.so.new"),
        "mv -f " .. q(EXT .. "Dirac.so.new") .. " " .. q(EXT .. "Dirac.so"),
        "cp " .. q(here .. "ugen/Dirac.sc.in") .. " " .. q(EXT .. "Dirac.sc.new"),
        "mv -f " .. q(EXT .. "Dirac.sc.new") .. " " .. q(EXT .. "Dirac.sc"),
        "cp " .. q(here .. "ugen/prebuilt/Noether.so") .. " " .. q(EXT .. "Noether.so.new"),
        "mv -f " .. q(EXT .. "Noether.so.new") .. " " .. q(EXT .. "Noether.so"),
        "cp " .. q(here .. "ugen/Noether.sc.in") .. " " .. q(EXT .. "Noether.sc.new"),
        "mv -f " .. q(EXT .. "Noether.sc.new") .. " " .. q(EXT .. "Noether.sc"),
        "cp " .. q(here .. "ugen/prebuilt/Varia.so") .. " " .. q(EXT .. "Varia.so.new"),
        "mv -f " .. q(EXT .. "Varia.so.new") .. " " .. q(EXT .. "Varia.so"),
        "cp " .. q(here .. "ugen/Varia.sc.in") .. " " .. q(EXT .. "Varia.sc.new"),
        "mv -f " .. q(EXT .. "Varia.sc.new") .. " " .. q(EXT .. "Varia.sc"),
        "cp " .. q(here .. "ugen/prebuilt/BUILD") .. " " .. q(EXT .. "BUILD"),
      }, " && ")
      local ok = os.execute(cmd)
      install_state = ok and "installed" or "failed"
      print("dirac: engine plugin " .. (ok and "installed - SYSTEM > RESTART to finish" or "install FAILED: " .. cmd))
    end
  end
end

-- ── engine calls that cannot brick init() ────────────────────────────────────
-- Calling engine.<id>(x) directly kills init() if the engine is not loaded, and
-- norns then shows "error: init" on EVERY BOOT because it autoloads the last
-- script. So: send if we can, note it if we cannot, keep going, and say so on
-- screen.
local engine_ok = true

local function send(id, value)
  local f = engine[id]
  if type(f) == "function" then
    f(value)
  else
    engine_ok = false
  end
end

-- Display precision that matches the step, so a detent always changes what is
-- on screen. norns' default rounds every control to 0.01, which hid the fine
-- steps entirely (grain length read "0.05 s" from 50 ms to 54 ms).
local function formatter_for(p, quantum)
  local unit = p.unit and (" " .. p.unit) or ""
  if p.unit == "s" then
    -- Seconds below one second read better as milliseconds, with the
    -- precision a ~3.5% exponential step needs at that size.
    return function(param)
      local v = param:get()
      if v >= 1 then return string.format("%.2f s", v) end
      local ms = v * 1000
      if ms < 10 then return string.format("%.2f ms", ms) end
      if ms < 100 then return string.format("%.1f ms", ms) end
      return string.format("%.0f ms", ms)
    end
  end
  if p.unit == "Hz" then
    return function(param)
      local v = param:get()
      if v >= 10000 then return string.format("%.1fk", v / 1000) end
      if v >= 1000 then return string.format("%.2fk", v / 1000) end
      return string.format("%dHz", math.floor(v + 0.5))
    end
  end
  if p.fmt == "type" then
    -- the filter's type: its three modes by name, and the glides between
    return function(param)
      local t = param:get()
      if t < 0.01 then return "low" elseif t > 0.99 then return "high"
      elseif math.abs(t - 0.5) < 0.01 then return "band"
      elseif t < 0.5 then return "lo-bd" else return "bd-hi" end
    end
  end
  local stepsize = (p.step and p.step > 0) and p.step or (p.max - p.min) * quantum
  local decimals = util.clamp(math.ceil(-math.log(stepsize, 10) - 1e-9), 0, 3)
  local f = "%." .. decimals .. "f"
  return function(param) return string.format(f, param:get()) .. unit end
end

local KIND = {}   -- id -> kind, from SPEC
local SHORT = {}  -- id -> on-screen label, from SPEC

local note, note_frames = nil, 0         -- one-line transient message
local function flash(msg)
  note, note_frames = msg, 40
end
local OPTS = {}   -- id -> option labels, for on/off detection

-- ── pages ────────────────────────────────────────────────────────────────────
-- Two params on E2/E3, two more with K1 held. Everything else (and all of it,
-- for MIDI mapping and PSETs) is in the norns PARAMS menu.
local PAGES = {
  -- Each page: two rows of two, all four on screen. E1 steps the bright row
  -- (top, bottom, then the next page); E2 / E3 turn the bright row. The
  -- control that defines the page (or its enable switch) comes first, the
  -- one it is most often paired with second, refinements on the bottom row.
  -- Controls that are inert in the current state dim (see ACTIVE_IF).
  --
  -- Every page belongs to a UNIT; a slot shows only its unit's pages.
  -- The loop's pages show the reel and put rec / stop / undo on the keys.
  { unit = "loop",  name = "loop",  main = { "lspeed", "llevel" },      alt = { "lsos", "ldry" } },
  { unit = "loop",  name = "dub",   main = { "ldub", "lext" },          alt = { "lundo", "lclear" } },
  { unit = "dirac", name = "grain", main = { "rate", "grainlen" },      alt = { "grains", "revprob" } },
  { unit = "dirac", name = "shape", main = { "window", "texture" },     alt = { "tilt", "tiltspread" } },
  { unit = "dirac", name = "scan",  main = { "playhead", "posjtr" },    alt = { "speed", "snap" } },
  { unit = "dirac", name = "pitch", main = { "semishift", "psprd" },    alt = { "scale", "voct" } },
  { unit = "dirac", name = "heads", main = { "playheadsOpt", "heads" }, alt = { "headspread", "headtune" } },
  { unit = "dirac", name = "space", main = { "spread", "binaural" },    alt = { "detune", "diffuseOpt" } },
  { unit = "dirac", name = "regen", main = { "feedback", "compress" },  alt = { "freezeOpt", "hold" } },
  { unit = "dirac", name = "out",   main = { "mix", "level" },          alt = { "insrc", "ingain" } },
  { unit = "dirac", name = "file",  main = { "source", "sample" },      alt = { "unload", "capture" } },
  { unit = "filter", name = "filter", main = { "ffreq", "fres" },       alt = { "ftype", "fwidth" } },
  { unit = "filter", name = "peaks", main = { "fmix", "fpeaks" },       alt = { "fphase", "fdrive" } },
  -- the macros: not a unit in the chain, reached past its end (chain view)
  { unit = "macro", name = "macro", main = { "m1", "m2" },              alt = { "m3", "m4" } },
  { unit = "delay", name = "delay", main = { "dtime", "dfdbk" },        alt = { "dsprd", "dmix" } },
  { unit = "verb",  name = "verb",  main = { "vmix", "vtime" },         alt = { "vsize", "vdamp" } },
}

-- ── the chain ────────────────────────────────────────────────────────────────
-- All five units, always, in the order the "order" param picks (one of the
-- 120, saved in PSETs). Reordering only moves units, so each keeps its state.
local NSLOT = 5
local ORDERS = {}                        -- order index -> { unit x5 }
for _, p in ipairs(SPEC) do if p.id == "order" then ORDERS = p.orders end end
local ABBR  = { loop = "loop", dirac = "dirc", filter = "filt", delay = "dlay", verb = "verb" }
local ABBR2 = { loop = "lp", dirac = "dr", filter = "fl", delay = "dl", verb = "vb", macro = "mc" }
local UNIT_OF = {}                       -- param id -> its unit (from PAGES)
for _, pg in ipairs(PAGES) do
  for _, id in ipairs(pg.main) do UNIT_OF[id] = pg.unit end
  for _, id in ipairs(pg.alt) do UNIT_OF[id] = pg.unit end
end
-- the engine's unit numbers (0 is its "off", which the script never sends)
local ENGINE_UNIT = { loop = 1, dirac = 2, delay = 3, verb = 4, filter = 5 }

local function the_chain()
  local c = ORDERS[params:get("order")] or ORDERS[1]
  local t = {}
  for i = 1, NSLOT do t[i] = c[i] end
  return t
end
local function order_index(c)
  for i, o in ipairs(ORDERS) do
    local same = true
    for j = 1, NSLOT do if o[j] ~= c[j] then same = false end end
    if same then return i end
  end
end

local slot = 1                           -- the slot being played
local upos = {}                          -- unit -> row index across its pages
local function unit_pages(u)
  local t = {}
  for i, pg in ipairs(PAGES) do if pg.unit == u then t[#t + 1] = i end end
  return t
end
-- slot NSLOT + 1 is the macro page, past the end of the chain
local function cur_unit() return slot > NSLOT and "macro" or the_chain()[slot] end
-- the page and row on show: page table, row (1 top, 2 bottom), page k of n
local function cur_page()
  local u = cur_unit()
  local pg = unit_pages(u)
  if #pg == 0 then return nil, 1, 0, 0 end
  local i = util.clamp(upos[u] or 1, 1, #pg * 2)
  return PAGES[pg[(i - 1) // 2 + 1]], (i - 1) % 2 + 1, (i - 1) // 2 + 1, #pg
end

-- The chain view (K1 held): an edited copy, applied when K1 is released.
local pending = nil                      -- the chain being edited, or nil
local cpu_avg = 0

-- The engine gets all five slots in one command, debounced so a burst of
-- changes (a PSET load) rebuilds once.
local chain_queued = false
local function send_chain()
  if chain_queued then return end
  chain_queued = true
  clock.run(function()
    clock.sleep(0.01)
    chain_queued = false
    local c = the_chain()
    if type(engine.chain) == "function" then
      engine.chain(ENGINE_UNIT[c[1]], ENGINE_UNIT[c[2]], ENGINE_UNIT[c[3]], ENGINE_UNIT[c[4]], ENGINE_UNIT[c[5]])
    end
  end)
end
-- the param last turned and when: the page row spells its full name for a
-- moment, since the rows use short labels
local touched_id, touched_t = nil, 0

-- ── key state ────────────────────────────────────────────────────────────────
-- K1 reaches the script only once held past 0.25 s (a shorter tap toggles the
-- norns menu and never arrives), so K1 is a pure modifier here.
local k1_held = false
local swallow_release = nil              -- the key whose press skipped the title
-- True while norns' file browser is open. fileselect swaps out enc/key, but
-- in play mode norns.menu.init() hands `redraw` straight back to the script,
-- so the 30 fps redraw clock painted over the browser every frame (and a
-- second open saved the browser's own handlers as "the script's", leaving
-- the encoders stuck in a browser nobody could see). redraw() draws nothing
-- while this is set, and a second open is ignored.
local browsing = false
local k2_down, k2_used = false, false   -- K2: tap = hold toggle; held = fine
local view_stereo = false                -- field x: position (false) / pan
local fire_flash = 0                     -- frames left of the "fire" flash

-- ── meters ───────────────────────────────────────────────────────────────────
-- in > 0 and out = 0 is a DSP bug; in = 0 is routing. Both have mattered.
local in_amp, out_amp = 0, 0

-- ── the field: what the UGen streams (see ugen/DiracUGen.cpp) ───────────────
local sample_loaded = false             -- a buffer is loaded (engine said so)
local sample_peaks = {}                  -- the loaded file's 128 peaks

local viz = { sample = false, frozen = false, cap = 0, head = 0, texture = 0.5,
              srclen = 131072, grains = {} }
local wave = { cap = 0, peaks = {} }

-- ── the reel: what the Noether UGen streams (see ugen/NoetherUGen.cpp) ───────
local LOOP_EMPTY, LOOP_REC, LOOP_PLAY, LOOP_DUB, LOOP_STOP, LOOP_EXT = 0, 1, 2, 3, 4, 5
local ENV_BINS = 96
local loop = { state = LOOP_EMPTY, len = 0, pos = 0, write = 0, len0 = 0, speed = 1,
               detent = true, sections = 8, armed = false, can_undo = false,
               restoring = false, cap = 0, env = {} }
-- Controls that only act while something else is set. The ER-301 reveals
-- them when their switch is turned on; here they stay on their page but dim
-- while inert, so the screen says so rather than letting a turn look broken.
-- Each rule is the engine's own condition (engine/Dirac.cpp).
local function multi_on() return params:get("playheadsOpt") == 2 end
local ACTIVE_IF = {
  -- the filter: width spreads the band, so it does nothing once type has
  -- parked an edge (pure low / high); peaks and phase act on resonance
  fwidth = function() local t = params:get("ftype"); return t > 0.001 and t < 0.999 end,
  fpeaks = function() return params:get("fres") > 0 end,
  -- mMultiHeadOpt Off hard-bypasses the multi-head path
  heads = multi_on, headspread = multi_on, headtune = multi_on,
  -- Speed scans a loaded sample (speed != 0 && sampleCount > 1); live, it is
  -- inert
  speed = function() return viz.sample end,
  -- (mix is applied in the SynthDef now, against the looper's output, so it
  -- acts in sample mode too)
  -- the looper: nothing to dub into, undo or clear without a loop
  ldub   = function() return loop.state ~= LOOP_EMPTY and loop.state ~= LOOP_REC end,
  lundo  = function() return loop.can_undo end,
  lclear = function() return loop.state ~= LOOP_EMPTY end,
  -- nothing to clear, or to switch to, without a loaded sample
  unload = function() return sample_loaded end,
  -- Scale quantises the pitch offset = scatter + head x head tune; with
  -- neither there is nothing to snap
  scale = function()
    return params:get("psprd") > 0 or (multi_on() and params:get("headtune") ~= 0)
  end,
}
local function active(id)
  local rule = ACTIVE_IF[id]
  return not rule or rule()
end

local RING = 131072      -- engine ring size; the UGen's test proves it
local BINS = 128

-- File scope so cleanup() can stop them: norns does NOT stop a script's polls,
-- and one left running fires into a dead callback forever.
local poll_in, poll_out, poll_cpu

-- ── sample files ─────────────────────────────────────────────────────────────
-- The engine assumes 48 kHz (a 44.1 kHz file would play 9% sharp), so a file
-- at any other rate is converted once with sox into a cache and the copy is
-- loaded (engine.loadsample - NOT engine.load, which is norns' own "load an
-- engine" function). Everything runs in norns.system_cmd, asynchronously, so a long
-- conversion never stalls the UI. Channel count needs no conversion: the
-- engine reads interleaved frames and mixes the first two channels.
local CACHE = _path.audio .. "dirac/.cache/"

local function shq(str) return "'" .. str:gsub("'", "'\\''") .. "'" end

local function load_file(path)
  if not path or path == "" or path == "-" or path:sub(-1) == "/" then return end
  local name = path:match("[^/]*$")
  local out = CACHE .. name:gsub("%.[^.]*$", "") .. "-48k.wav"
  flash("reading " .. name)
  local cmd = string.format(
    [[r=$(soxi -r %s 2>/dev/null); if [ "$r" = "48000" ]; then printf %%s %s; ]] ..
    [[elif [ -n "$r" ]; then mkdir -p %s && { [ -f %s ] || sox %s -r 48000 %s 2>/dev/null; } && printf %%s %s; fi]],
    shq(path), shq(path), shq(CACHE), shq(out), shq(path), shq(out), shq(out))
  norns.system_cmd(cmd, function(result)
    result = (result or ""):gsub("%s+$", "")
    if result == "" then
      flash("can't read " .. name)
    else
      if result ~= path then flash("converted to 48k") end
      send("loadsample", result)
      params:set("source", 2)
    end
  end)
end

local SCRIPT_ACTION = {
  unload = function()
    send("clearsample")
    params:set("source", 1)
  end,
  -- The engine copies the ring and writes the file; /dirac/captured reports
  -- the path when it is on disk.
  capture = function()
    flash("saving buffer...")
    send("capture")
  end,
}

-- ── macros ───────────────────────────────────────────────────────────────────
-- MACRO[k] is a list of { id, from, to } in each param's own units. Turning
-- macro k sets every target to from + (to - from) * v, interpolated in the
-- param's 0..1 (raw) space. Targets live in the hidden text params m1map..
-- m4map ("id=from>to;..."), so PSETs keep them.
--
-- Learning (K3 on the macro page): every param turned from then on becomes
-- a target of that macro, "from" where it was when first touched, "to"
-- where it is left. K3 again ends it; a param left where it started is
-- dropped, which is also how a target is removed. The macro then reads 1,
-- since its targets now sit at their "to".
local MACRO_T = { {}, {}, {}, {} }
local macro_sel = 1
local learning = nil
local learn_seen = {}
local learn_last = nil
for k = 1, 4 do
  ACTIVE_IF["m" .. k] = function() return #MACRO_T[k] > 0 end
end

local function macro_parse(k, s)
  local t = {}
  for id, a, b in (s or ""):gmatch("([%w_]+)=([%-%d%.e]+)>([%-%d%.e]+)") do
    if params.lookup[id] then t[#t + 1] = { id = id, from = tonumber(a), to = tonumber(b) } end
  end
  MACRO_T[k] = t
end

local function macro_string(k)
  local parts = {}
  for _, t in ipairs(MACRO_T[k]) do
    parts[#parts + 1] = string.format("%s=%.6g>%.6g", t.id, t.from, t.to)
  end
  return table.concat(parts, ";")
end

local function macro_apply(k, v)
  if learning then return end
  for _, t in ipairs(MACRO_T[k] or {}) do
    local p = params:lookup_param(t.id)
    if p and p.controlspec then
      local a, b = p.controlspec:unmap(t.from), p.controlspec:unmap(t.to)
      p:set_raw(a + (b - a) * v)
    end
  end
end

-- continuous params only, never a macro
local function learnable(id)
  return KIND[id] == "control"
end

local function learn_start(k)
  learning, learn_seen, learn_last = k, {}, nil
  flash("learn M" .. k .. ": turn params")
end

local function learn_begin(id)
  if learn_seen[id] then return end
  learn_seen[id] = true
  local t = MACRO_T[learning]
  for i = #t, 1, -1 do if t[i].id == id then table.remove(t, i) end end
  t[#t + 1] = { id = id, from = params:get(id), to = params:get(id) }
end

local function learn_update(id)
  for _, t in ipairs(MACRO_T[learning]) do
    if t.id == id then t.to = params:get(id); learn_last = t end
  end
end

local function learn_end()
  local k = learning
  local t = MACRO_T[k]
  for i = #t, 1, -1 do
    if math.abs(t[i].to - t[i].from) < 1e-9 then table.remove(t, i) end
  end
  learning = nil
  params:set("m" .. k .. "map", macro_string(k), true)
  params:set("m" .. k, 1, true)
  flash("M" .. k .. ": " .. #t .. (#t == 1 and " target" or " targets"))
end

-- ── midi ─────────────────────────────────────────────────────────────────────
-- A fixed CC map, so a controller works without setup (README lists it).
-- Continuous CCs set the param across its range; button CCs act at >= 64.
-- norns' own MIDI mapping (PARAMS > MAP) still works for anything else.
local MIDI_CC = {
  [16] = "m1", [17] = "m2", [18] = "m3", [19] = "m4",
  [20] = "llevel", [21] = "lspeed", [22] = "mix", [23] = "rate", [24] = "grainlen",
  [25] = "ffreq", [26] = "fres", [27] = "ftype", [28] = "fdrive", [29] = "fmix",
  [30] = "dtime", [31] = "dfdbk", [85] = "dmix", [86] = "vmix", [87] = "vtime",
}
local MIDI_BUTTON = { [102] = "lrec", [103] = "lstop", [104] = "lundo", [105] = "fire", [106] = "hold" }
local midi_dev = nil
local midi_down = {}

local function midi_event(data)
  local msg = midi.to_msg(data)
  if msg.type ~= "cc" then return end
  local ch = params:get("midi_ch")
  if ch > 1 and msg.ch ~= ch - 1 then return end
  local id = MIDI_CC[msg.cc]
  if id then
    local p = params:lookup_param(id)
    p:set_raw(msg.val / 127)
    touched_id, touched_t = id, util.time()
    return
  end
  id = MIDI_BUTTON[msg.cc]
  if id then
    local down = msg.val >= 64
    if down and not midi_down[msg.cc] then
      if KIND[id] == "toggle" then params:set(id, params:get(id) == 1 and 0 or 1)
      else params:set(id, 1) end
      touched_id, touched_t = id, util.time()
    end
    midi_down[msg.cc] = down
  end
end

local function midi_init()
  local names = {}
  for i = 1, #midi.vports do
    names[i] = i .. ": " .. (midi.vports[i].name or "none")
  end
  params:add_separator("midi_sep", "midi")
  params:add_option("midi_dev", "midi device", names, 1)
  params:set_action("midi_dev", function(i)
    if midi_dev then midi_dev.event = nil end
    midi_dev = midi.connect(i)
    midi_dev.event = midi_event
  end)
  local chs = { "omni" }
  for i = 1, 16 do chs[i + 1] = tostring(i) end
  params:add_option("midi_ch", "midi channel", chs, 1)
  params:lookup_param("midi_dev"):bang()
end

-- ── init ─────────────────────────────────────────────────────────────────────
function init()
  -- Engine just installed (or cannot be): say so, and do nothing else. The
  -- engine is not running in this session, so nothing below would work.
  if install_state then
    clock.run(function() while true do clock.sleep(0.5); redraw() end end)
    return
  end
  -- the title card covers the engine load; any key or encoder skips it
  splash.start()
  for _, p in ipairs(SPEC) do
    local kind = p.kind or "control"
    KIND[p.id] = kind
    SHORT[p.id] = p.short or p.name
    if kind == "control" then
      local step = p.step or 0
      -- quantum is a fraction of the RANGE per detent. Integer dials move one
      -- whole unit per detent; everything else gets p.detents (default 200).
      local quantum = (step > 0) and (step / (p.max - p.min)) or (1 / (p.detents or 200))
      params:add_control(p.id, p.name,
        controlspec.new(p.min, p.max, p.warp or "lin", step, p.default, p.unit or "", quantum),
        formatter_for(p, quantum))
      params:set_action(p.id, function(x) send(p.id, x) end)
    elseif kind == "macro" then
      params:add_control(p.id, p.name, controlspec.new(0, 1, "lin", 0, p.default or 0, "", 1 / 100),
        function(param) return string.format("%.2f", param:get()) end)
      params:set_action(p.id, function(v) macro_apply(tonumber(p.id:sub(2)), v) end)
    elseif kind == "text" then
      params:add_text(p.id, p.name, p.default or "")
      params:set_action(p.id, function(s) macro_parse(tonumber(p.id:sub(2, 2)), s) end)
      params:hide(p.id)
    elseif kind == "option" and p.script then
      -- the chain's order: the script sends it, as one command
      OPTS[p.id] = p.options
      params:add_option(p.id, p.name, p.options, p.default or 1)
      params:set_action(p.id, function() send_chain() end)
    elseif kind == "option" then
      -- The menu shows names; the engine gets base + (index - 1).
      local base = p.base or 1
      OPTS[p.id] = p.options
      params:add_option(p.id, p.name, p.options, p.default or 1)
      params:set_action(p.id, function(i) send(p.id, base + i - 1) end)
    elseif kind == "toggle" then
      params:add_binary(p.id, p.name, "toggle", p.default or 0)
      params:set_action(p.id, function(v) send(p.id, v) end)
    elseif kind == "trigger" and p.script then
      params:add_trigger(p.id, p.name)
      params:set_action(p.id, function() SCRIPT_ACTION[p.id]() end)
    elseif kind == "trigger" then
      -- A rising edge is what the engine listens for. Send the edge, then
      -- drop back to 0 a moment later so the next press is a new edge.
      params:add_trigger(p.id, p.name)
      params:set_action(p.id, function()
        send(p.id, 1)
        if p.id == "fire" then fire_flash = 8 end
        clock.run(function() clock.sleep(0.02); send(p.id, 0) end)
      end)
    elseif kind == "file" then
      -- Starts at the audio folder (a directory: ignored by load_file). A
      -- PSET restores the path, and bang() below then reloads the file.
      params:add_file(p.id, p.name, _path.audio)
      params:set_action(p.id, function(path) load_file(path) end)
    end
  end

  -- bang() would also fire every trigger, i.e. a grain burst at load. Send
  -- everything except triggers.
  -- A macro is not banged: that would pull every target to its "from".
  for _, p in ipairs(SPEC) do
    if (p.kind or "control") ~= "trigger" and p.kind ~= "macro" then
      params:lookup_param(p.id):bang()
    end
  end
  midi_init()

  poll_in = poll.set("in_amp", function(v) in_amp = v end)
  poll_out = poll.set("out_amp", function(v) out_amp = v end)
  if poll_in and poll_out then
    poll_in.time = 0.1
    poll_out.time = 0.1
    poll_in:start()
    poll_out:start()
  else
    engine_ok = false
  end
  -- norns' own poll of the audio server's load, for the chain view
  poll_cpu = poll.set("cpu_avg", function(v) cpu_avg = v end)
  if poll_cpu then poll_cpu.time = 0.5; poll_cpu:start() end

  -- The field animates, so redraw every frame rather than on change. 30 fps
  -- matches the grain data rate; matron measured ~5% at 15 fps.
  clock.run(function()
    while true do
      clock.sleep(1 / 30)
      if fire_flash > 0 then fire_flash = fire_flash - 1 end
      if note_frames > 0 then note_frames = note_frames - 1 end
      redraw()
    end
  end)
end

-- ── OSC from the engine ──────────────────────────────────────────────────────
function osc.event(path, args, from)
  if path == "/noether/viz" then
    loop.state     = math.floor(args[1])
    loop.len       = args[2]
    loop.pos       = args[3]
    loop.write     = args[4]
    loop.len0      = args[5]
    loop.speed     = args[6]
    loop.detent    = args[7] > 0.5
    loop.sections  = math.max(1, math.floor(args[8]))
    loop.armed     = args[9] > 0.5
    loop.can_undo  = args[10] > 0.5
    loop.restoring = args[11] > 0.5
    loop.cap       = args[12]
    for b = 1, ENV_BINS do loop.env[b] = args[12 + b] or 0 end
  elseif path == "/dirac/viz" then
    viz.sample = args[1] > 0.5
    viz.frozen = args[2] > 0.5
    viz.cap    = args[3]
    viz.head   = args[4]
    local n = math.floor(args[5])
    viz.texture = args[6]
    viz.srclen  = args[7]
    local g = {}
    for i = 0, n - 1 do
      local o = 7 + i * 8
      g[#g + 1] = { pos = args[o + 1], spawn = args[o + 2], pitch = args[o + 3],
                    env = args[o + 4], gain = args[o + 5], pan = args[o + 6],
                    rev = args[o + 7] > 0.5, dur = args[o + 8] }
    end
    viz.grains = g
  elseif path == "/dirac/samplewave" then
    for b = 1, BINS do sample_peaks[b] = args[b] or 0 end
  elseif path == "/dirac/loaded" then
    sample_loaded = true
    flash("loaded " .. tostring(args[1]):match("[^/]*$"))
  elseif path == "/dirac/load_fail" then
    flash("can't read " .. tostring(args[1]):match("[^/]*$"))
  elseif path == "/dirac/captured" then
    flash("saved " .. tostring(args[1]):match("[^/]*$"):gsub("%.wav$", ""))
  elseif path == "/dirac/capture_fail" then
    flash("capture failed")
  elseif path == "/dirac/unloaded" then
    sample_loaded = false
    sample_peaks = {}
  elseif path == "/dirac/wave" then
    wave.cap = args[1]
    for b = 1, BINS do wave.peaks[b] = args[b + 1] or 0 end
  end
end

-- ── input ────────────────────────────────────────────────────────────────────
local function current_pair()
  local p, row = cur_page()
  if not p then return {} end
  return row == 2 and p.alt or p.main
end

local function adjust(id, d)
  if not id then return end                 -- an empty slot on a page
  local kind = KIND[id]
  if kind == "file" then
    -- fileselect takes over enc/key until a file is chosen or K2 cancels,
    -- then hands them back. Either direction opens it.
    if not browsing then
      browsing = true
      fileselect.enter(_path.audio, function(path)
        browsing = false
        if path and path ~= "cancel" then params:set(id, path) end
      end)
    end
    return
  elseif kind == "trigger" then
    if d > 0 then params:set(id, 1) end
    return
  elseif kind == "toggle" then
    params:set(id, d > 0 and 1 or 0)
  elseif kind == "control" and k2_down then
    -- Fine: a tenth of a detent, in the param's own (possibly exponential)
    -- 0..1 space, so it is a tenth of the step you'd get HERE.
    local prm = params:lookup_param(id)
    prm:set_raw(prm:get_raw() + d * prm.controlspec.quantum * 0.1)
  else
    params:delta(id, d)
  end
end

function enc(n, d)
  if install_state then return end
  if splash.active() then splash.skip(); return end
  if k1_held and pending then
    -- the chain view: E1 picks a slot, E2 or E3 carries its unit left/right
    if n == 1 then
      slot = util.clamp(slot + d, 1, NSLOT + 1)
    elseif slot <= NSLOT then
      local j = util.clamp(slot + (d > 0 and 1 or -1), 1, NSLOT)
      pending[slot], pending[j] = pending[j], pending[slot]
      slot = j
    end
    return
  end
  if n == 1 then
    -- two rows per page: E1 walks top, bottom, next page's top... within
    -- the slot's unit
    local u = cur_unit()
    local np = #unit_pages(u)
    if np > 0 then upos[u] = util.clamp((upos[u] or 1) + d, 1, np * 2) end
    if u == "macro" then macro_sel = ((upos[u] or 1) - 1) % 2 * 2 + 1 end
  else
    if k2_down then k2_used = true end
    local id = current_pair()[n - 1]
    if id then touched_id, touched_t = id, util.time() end
    if cur_unit() == "macro" and id then macro_sel = tonumber(id:sub(2)) end
    local learn = learning and id and learnable(id)
    if learn then learn_begin(id) end
    adjust(id, d)
    if learn then learn_update(id) end
  end
end

function key(n, z)
  if install_state then return end
  -- a press skips the title; its release must not act either
  if splash.active() then
    if z == 1 then splash.skip(); swallow_release = n end
    return
  end
  if swallow_release == n and z == 0 then swallow_release = nil; return end
  if n == 1 then
    k1_held = (z == 1)
    if z == 1 then
      pending = the_chain()
    elseif pending then
      -- apply the chain view's edits on release
      local now, changed = the_chain(), false
      for i = 1, NSLOT do if pending[i] ~= now[i] then changed = true end end
      if changed then
        params:set("order", order_index(pending))
        flash(table.concat(pending, " > "))
      end
      pending = nil
    end
  elseif n == 2 then
    if z == 1 then
      k2_down, k2_used = true, false
      if k1_held then
        k2_used = true
        if cur_unit() == "loop" then
          if loop.can_undo then params:set("lundo", 1); flash("undo") else flash("nothing to undo") end
        elseif cur_unit() == "dirac" then
          view_stereo = not view_stereo
          flash(view_stereo and "field: stereo" or "field: position")
        end
      end
    else
      if not k2_used then
        -- the unit's freeze: stop the loop, hold the grain cloud
        local id = (cur_unit() == "loop" and "lstop") or (cur_unit() == "dirac" and "hold")
        if id then params:set(id, params:get(id) == 1 and 0 or 1) end
      end
      k2_down = false
    end
  elseif n == 3 and z == 1 then
    -- learning a macro: K3 anywhere ends it (K1 + K3 still records)
    if learning and not k1_held then learn_end(); return end
    if cur_unit() == "macro" and not k1_held then learn_start(macro_sel); return end
    -- rec is K3 on the loop pages and K1 + K3 everywhere, so a loop can be
    -- caught from any page
    if k1_held or cur_unit() == "loop" then
      params:set("lrec", 1)
    elseif cur_unit() == "dirac" then
      params:set("fire", 1)
    end
  end
end

-- ── drawing ──────────────────────────────────────────────────────────────────
local FY, FH = 0, 30          -- field rows 0..29 (four params share the screen)
local YC = FY + 15            -- pitch 0 / waveform centre
local PX_PER_ST = 14 / 24     -- +-24 st fills the field

local function xof(pos01) return math.floor(util.clamp(pos01, 0, 1) * 127 + 0.5) end

-- Live mode, a ring position measured from the write head: 0 oldest, 1 now.
-- The same frame the engine uses for grain positions.
local function bin_x(b)
  local start = (b - 1) * (RING / BINS)
  local age = (wave.cap - start) % RING
  return xof(1 - age / RING)
end

-- forward declarations: drawn by redraw(), defined further down
local draw_chain, draw_delay, draw_verb, draw_filter, draw_macros

local function draw_toggle(x, y, label, on, dim)
  -- A visible on/off state, never a number. dim: on an unlit row.
  local w = #label * 4 + 3
  if on then
    screen.level(dim and 5 or 12); screen.rect(x, y - 6, w, 7); screen.fill()
    screen.level(0)
  else
    screen.level(dim and 2 or 3); screen.rect(x + 0.5, y - 5.5, w - 1, 6); screen.stroke()
    screen.level(dim and 2 or 3)
  end
  screen.move(x + 2, y); screen.text(label)
  return w
end

-- The looper's state, top right, on every unit but the loop's own: K1 + K3
-- records from anywhere, so the screen says when it is. `right`: the x to
-- end at (the field's other toggles sit to the right of it).
local function draw_loop_tag(right)
  local label = (loop.state == LOOP_REC and "rec") or (loop.state == LOOP_DUB and "dub")
                or (loop.state == LOOP_EXT and "ext")
  if not label then return end
  local w = #label * 4 + 3
  draw_toggle((right or 127) - w - 1, 7, label, true)
end

-- ── grain envelopes ──────────────────────────────────────────────────────────
-- Each grain is drawn as a 1-pixel bar over the stretch of source it reads,
-- lit along its length by its ENVELOPE, so the controls that shape a grain
-- change the picture: shape / texture / tilt move where the bar is bright,
-- grain length and transpose change its length, reverse flips its direction.
-- The engine sends position, pitch, gain and duration; the profile is
-- computed here from the same params the engine reads.
local PROFILE_N = 32
local profile = {}          -- envelope sampled at PROFILE_N points, 0..1

local function base_env(x, window, tex)
  if window == 1 then return math.exp(-0.5 * ((x - 0.5) / 0.18) ^ 2) end    -- bell
  if window == 2 then                                                        -- sinc
    local u = (x - 0.5) * 6; return u == 0 and 1 or math.abs(math.sin(math.pi * u) / (math.pi * u)) end
  if window == 3 then return 1 - math.abs(2 * x - 1) end                     -- triangle
  if window == 4 then return (1 - x) ^ 2 end                                 -- decay
  if window == 5 then return x end                                           -- ramp
  if window == 7 then return 1 end                                           -- square
  local function tukey(u)
    local t = 0.125
    if u < t then return 0.5 * (1 - math.cos(math.pi * u / t)) end
    if u > 1 - t then return 0.5 * (1 - math.cos(math.pi * (1 - u) / t)) end
    return 1
  end
  if window == 6 then return tukey(x) end                                    -- tukey
  -- normal: texture morphs percussive (0) -> hann (0.5) -> tukey (1)
  local perc = (x < 0.02) and (x / 0.02) or math.exp(-5 * (x - 0.02))
  local hann = math.sin(math.pi * x) ^ 2
  if tex <= 0.5 then
    local k = tex / 0.5; return perc * (1 - k) + hann * k
  end
  local k = (tex - 0.5) / 0.5; return hann * (1 - k) + tukey(x) * k
end

local function update_profile()
  local window = params:get("window") - 1             -- option index -> 0..7
  local tex = params:get("texture")
  local tilt = params:get("tilt")                     -- -1 attack .. +1 swell
  local warp = 2 ^ tilt
  for i = 1, PROFILE_N do
    local x = (i - 0.5) / PROFILE_N
    profile[i] = util.clamp(base_env(x ^ warp, window, tex), 0, 1)
  end
end

local function env_at(u)
  return profile[util.clamp(math.floor(u * PROFILE_N) + 1, 1, PROFILE_N)] or 0
end

local function draw_field()
  -- sample mode: the file's peaks, start at the left, static
  if viz.sample and #sample_peaks == BINS then
    screen.level(1)
    for b = 1, BINS do
      local h = math.floor(math.sqrt(util.clamp(sample_peaks[b], 0, 1)) * (FH / 2 - 1))
      if h > 0 then
        screen.move(b - 0.5, YC - h); screen.line(b - 0.5, YC + h + 1); screen.stroke()
      end
    end
  end

  -- waveform: dim columns, live ring only (sample peaks arrive with files)
  if not viz.sample and #wave.peaks == BINS then
    -- level 1: the backdrop. Grain bars start at 3 so they always read
    -- against it (at 2 they vanished into it).
    screen.level(1)
    for b = 1, BINS do
      local h = math.floor(math.sqrt(util.clamp(wave.peaks[b], 0, 1)) * (FH / 2 - 1))
      if h > 0 then
        local x = bin_x(b)
        screen.move(x + 0.5, YC - h); screen.line(x + 0.5, YC + h + 1); screen.stroke()
      end
    end
  end

  -- playhead: where the cloud is centred
  if not view_stereo then
    local px = viz.sample and xof(viz.head) or xof(1 - params:get("playhead"))
    screen.level(5)
    for y = FY, FY + FH - 1, 3 do screen.pixel(px, y) end
    screen.fill()
    -- write head ("now") at the right edge in live mode; dim when frozen
    if not viz.sample then
      screen.level(viz.frozen and 3 or 15)
      screen.move(127.5, FY); screen.line(127.5, FY + FH); screen.stroke()
    end
  end

  -- grains: envelope bars with a bright read head
  update_profile()
  for _, g in ipairs(viz.grains) do
    local y = math.floor(util.clamp(YC - g.pitch * PX_PER_ST, FY + 1, FY + FH - 2))
    -- brightness of the whole grain follows its real gain (level, density
    -- compensation, compress); sqrt so quiet grains stay visible
    local gl = util.clamp(math.sqrt(util.clamp(g.gain * 2, 0, 1)), 0.15, 1)
    if view_stereo then
      local x = xof((g.pan + 1) / 2)
      screen.level(math.floor(util.clamp(2 + 13 * gl * g.env, 1, 15)))
      screen.pixel(x, y); screen.fill()
    else
      -- the whole read span: duration x playback rate, leftward if reverse
      local span = g.dur * (2 ^ (g.pitch / 12)) / (viz.srclen > 0 and viz.srclen or RING)
      local x0 = g.spawn * 127
      local x1 = x0 + (g.rev and -span or span) * 127
      local lo, hi = math.floor(math.min(x0, x1) + 0.5), math.floor(math.max(x0, x1) + 0.5)
      if hi > lo then
        for px = math.max(lo, 0), math.min(hi, 127) do
          local u = (px - lo) / (hi - lo)
          if g.rev then u = 1 - u end                 -- envelope runs with the read
          -- 3..10: always above the waveform's 1, never competing with
          -- the read head
          local l = math.floor(3 + 7 * gl * env_at(u) + 0.5)
          screen.level(l); screen.pixel(px, y); screen.fill()
        end
      end
      -- read head: the one sharp, bright pixel
      screen.level(math.floor(util.clamp(8 + 7 * gl * (0.3 + 0.7 * g.env), 1, 15)))
      screen.pixel(xof(g.pos), y); screen.fill()
    end
  end

  -- status, top right: visible toggles
  local x = 127
  local function right_toggle(label, on)
    local w = #label * 4 + 3
    x = x - w - 1
    draw_toggle(x, 7, label, on)
  end
  right_toggle("hold", params:get("hold") == 1)
  if viz.frozen then right_toggle("frz", true) end
  if fire_flash > 0 then right_toggle("fire", true) end
  -- the looper, from a grain page: K1 + K3 records here too, so say so
  draw_loop_tag(x)

  -- tiny input meter, top left: the "is anything arriving" answer
  screen.level(in_amp > 0.001 and 6 or 1)
  screen.rect(0, 0, math.max(1, math.floor(util.clamp(in_amp * 2, 0, 1) * 24)), 1)
  screen.fill()
end

-- ── the reel ─────────────────────────────────────────────────────────────────
-- The ER-301 Noether's display (noether/src/NoetherReel.h), ported: one glyph
-- for position, direction, speed, sections, state and content.
--   - the loop's envelope in POLAR form: the ring's thickness at each angle
--     is the loudness there; 12 o'clock is the seam, clockwise is forward
--   - section ticks outside the ring; the section the head is in is bright
--   - the head is a dot with a COMET TAIL as long as the speed is far from
--     1x (four pixels an octave, trailing behind travel); on a speed detent
--     it becomes a small hollow ring
--   - recording WINDS the ring on from 12 o'clock, a turn per 4 s; extend
--     winds the new material outside the finished loop
-- y grows downward here (up on the ER-301), hence the minus on cos.
-- The reel lives in the 33 rows above the page line: radius 9, 3 px of
-- loudness, ticks at 14..16. The centre word (REC, DUB, EXT) is ~12 px wide
-- and fits the ring's 16 px inside; stop is a glyph, since STOP does not.
local RCX, RCY, RR = 64, 16, 9
-- screen.circle is a cairo arc, and an arc first draws a LINE from wherever
-- the pen is to its own start (angle 0: the circle's rightmost point). After
-- the speed text the pen sits at the right edge, and that line showed. So
-- every circle starts by moving the pen to its own start.
local function circle(x, y, r)
  screen.move(x + r, y)
  screen.circle(x, y, r)
end
local WIND = 4 * 48000

local function rpt(a01, r)
  local t = a01 * 2 * math.pi
  return math.floor(RCX + math.sin(t) * r + 0.5), math.floor(RCY - math.cos(t) * r + 0.5)
end

local function radial(a01, r0, r1, level)
  local x0, y0 = rpt(a01, r0)
  local x1, y1 = rpt(a01, r1)
  screen.level(level)
  screen.move(x0 + 0.5, y0 + 0.5); screen.line(x1 + 0.5, y1 + 0.5); screen.stroke()
end

local function winding(r, w, per_turn)
  per_turn = math.max(per_turn, 1)
  w = math.max(w, 0)
  local turns = w // per_turn
  local rem = (w - turns * per_turn) / per_turn
  for t = 0, math.min(turns, 2) - 1 do
    screen.level(7); circle(RCX + 0.5, RCY + 0.5, r + 3 * t); screen.stroke()
  end
  local rr = r + 3 * math.min(turns, 2)
  local steps = math.max(1, math.floor(rem * 64))
  local px, py = rpt(0, rr)
  screen.level(15)
  for k = 1, steps do
    local x, y = rpt(rem * k / steps, rr)
    screen.move(px + 0.5, py + 0.5); screen.line(x + 0.5, y + 0.5); screen.stroke()
    px, py = x, y
  end
  circle(px + 0.5, py + 0.5, 2); screen.fill()
end

local function word(s, level)
  screen.level(level); screen.move(RCX, RCY + 3); screen.text_center(s)
end

-- the speed as the ER-301's sub display reads it: a ratio on a detent
local RATIO = { [2] = "2x", [1] = "1x", [0.5] = "1/2x", [0.25] = "1/4x" }
local function speed_string(sp)
  if loop.detent then
    if math.abs(sp) < 0.01 then return "0x" end
    local r = RATIO[math.floor(math.abs(sp) * 4 + 0.5) / 4]
    if r then return (sp < 0 and "-" or "") .. r end
  end
  return string.format("%.2fx", sp)
end

local function draw_reel()
  local blink = math.floor(util.time() * 4) % 2 == 0
  local st = loop.state

  -- the loop's length (or the take so far) on the left, the speed on the right
  screen.level(6)
  if st == LOOP_REC then
    screen.move(2, RCY + 3); screen.text(string.format("%.2fs", loop.write / 48000))
  elseif loop.len > 0 then
    screen.move(2, RCY + 3); screen.text(string.format("%.2fs", loop.len / 48000))
  end
  screen.move(126, RCY + 3); screen.text_right(speed_string(loop.speed))

  if st == LOOP_EMPTY then
    screen.level(3); circle(RCX + 0.5, RCY + 0.5, RR); screen.stroke()
    if loop.armed then if blink then word("REC", 15) end else word("rec", 7) end
    return
  end
  if st == LOOP_REC then
    winding(RR, loop.write, WIND)
    word("REC", 15)
    return
  end

  local L0 = loop.len0 > 0 and loop.len0 or loop.len
  if L0 <= 0 then
    screen.level(3); circle(RCX + 0.5, RCY + 0.5, RR); screen.stroke()
    return
  end
  local sections = loop.sections
  local cur = math.floor(loop.pos * sections / L0)
  for i = 0, ENV_BINS - 1 do
    local sec = math.floor(i * sections / ENV_BINS)
    local level = (sec == cur and st ~= LOOP_EXT) and 15 or 9
    local e = loop.env[i + 1] or 0
    -- 3 px of loudness, not the ER-301's 5: it has 64 rows, this 33
    radial(i / ENV_BINS, RR - 1, RR + 1 + math.floor(e * 3 + 0.5), level)
  end
  for k = 0, sections - 1 do radial(k / sections, RR + 5, RR + 7, 6) end

  if st == LOOP_EXT then
    winding(RR + 4, loop.write - L0, L0)       -- outside the ring, inside the ticks
    word("EXT", 15)
    return
  end

  -- the head and its comet tail
  local head = (loop.pos / L0) % 1
  local sp = loop.speed
  local ratio = math.max(math.abs(sp), 0.0625)
  if ratio < 1 then ratio = 1 / ratio end
  local n = 0
  while ratio > 1.0905 and n < 12 do ratio = ratio * 0.8409; n = n + 1 end
  local dir = sp >= 0 and -1 or 1
  for t = 1, n do
    local x, y = rpt(head + dir * t / 128, RR)
    screen.level(math.max(3, 11 - (t * 9) // n)); screen.pixel(x, y); screen.fill()
  end
  local hx, hy = rpt(head, RR)
  screen.level(15)
  if loop.detent then
    circle(hx + 0.5, hy + 0.5, 3); screen.stroke()
    screen.pixel(hx, hy); screen.fill()
  else
    circle(hx + 0.5, hy + 0.5, 2); screen.fill()
  end

  if st == LOOP_DUB then word("DUB", 15)
  elseif st == LOOP_STOP then
    -- a pause glyph: "STOP" is wider than the ring's inside (photographed)
    screen.level(9)
    screen.rect(RCX - 4, RCY - 3, 3, 7); screen.fill()
    screen.rect(RCX + 1, RCY - 3, 3, 7); screen.fill()
  elseif loop.restoring then word("undo", 15)
  elseif loop.can_undo then word("undo", 4) end
end

-- ── the chain view (K1 held) ─────────────────────────────────────────────────
-- Four slots as boxes, in -> out; the selected slot filled, and a mark under
-- every slot whose unit will change on release.
draw_chain = function()
  screen.level(3)
  screen.move(0, 7); screen.text("in")
  screen.move(127, 7); screen.text_right("out")
  local now = the_chain()
  for i = 1, NSLOT do
    local x = 1 + (i - 1) * 25
    local u = pending[i]
    local top, h = 11, 16
    if i == slot then
      screen.level(15); screen.rect(x, top, 23, h); screen.fill()
      screen.level(0)
    else
      screen.level(5); screen.rect(x + 0.5, top + 0.5, 22, h - 1); screen.stroke()
      screen.level(9)
    end
    screen.move(x + 12, top + h / 2 + 3); screen.text_center(ABBR[u])
    if i < NSLOT then
      screen.level(5); screen.move(x + 23, top + h / 2 + 0.5); screen.line(x + 25, top + h / 2 + 0.5); screen.stroke()
    end
    -- a slot whose unit will change on release
    if u ~= now[i] then
      screen.level(12); screen.rect(x + 10, top + h + 2, 3, 1); screen.fill()
    end
  end

  if slot > NSLOT then
    screen.level(15); screen.rect(0, 37, 33, 9); screen.fill()
    screen.level(0); screen.move(2, 44); screen.text("macros")
  else
    screen.level(15); screen.move(0, 44); screen.text("chain")
  end
  screen.level(6); screen.move(127, 44); screen.text_right(string.format("cpu %d%%", math.floor(cpu_avg + 0.5)))
  screen.level(8)
  screen.move(0, 54); screen.text("E1 slot")
  screen.move(127, 54); screen.text_right("E2/E3 move it")
  local changed = false
  for i = 1, NSLOT do if pending[i] ~= now[i] then changed = true end end
  screen.level(changed and 12 or 3)
  screen.move(0, 63); screen.text(changed and "release K1 to apply" or "release K1 to play")
end

-- ── the delay ────────────────────────────────────────────────────────────────
-- The echoes over 2.5 s: the dry hit at the left edge, then every repeat as a
-- tap, left channel up, right down, each as loud as the feedback has left
-- it. Spread is visible as the left/right balance of each tap (ping-pong
-- alternates sides); mix is the taps' brightness.
draw_delay = function()
  local W = 2.5
  local t = params:get("dtime")
  local fb = params:get("dfdbk") * 0.98
  local sp = params:get("dsprd")
  local mx = params:get("dmix")
  screen.level(1)
  for x = 0, 127, 3 do screen.pixel(x, YC); screen.fill() end
  -- the dry signal, at time 0
  screen.level(math.floor(3 + 12 * (1 - mx)))
  screen.move(1.5, YC - 12); screen.line(1.5, YC + 13); screen.stroke()
  -- a mono hit through the same matrix the delay runs
  local l, r = (1 + sp) / 2, (1 - sp) / 2
  local n = 1
  while n * t <= W and n <= 48 do
    local x = math.floor(1 + n * t / W * 125) + 0.5
    local lv = math.floor(3 + 12 * mx * math.max(l, r))
    if l > 0.02 then
      screen.level(lv); screen.move(x, YC); screen.line(x, YC - math.max(1, math.floor(l * 13 + 0.5))); screen.stroke()
    end
    if r > 0.02 then
      screen.level(lv); screen.move(x, YC + 1); screen.line(x, YC + 1 + math.max(1, math.floor(r * 13 + 0.5))); screen.stroke()
    end
    l, r = fb * ((1 - sp) * l + sp * r), fb * (sp * l + (1 - sp) * r)
    if math.max(l, r) < 0.01 then break end
    n = n + 1
  end
  screen.level(3)
  screen.move(127, 6); screen.text_right("L")
  screen.move(127, 28); screen.text_right("R")
end

-- ── the filter ───────────────────────────────────────────────────────────────
-- Its magnitude response, 20 Hz .. 20 kHz on a log axis, +24 .. -36 dB: the
-- same analog-prototype curve Varia's slope scope draws (filter_response.h),
-- from the same edge and damping math as engine/VariaFilter.h. The dotted
-- line is 0 dB; the tick at the top is freq. Mix is the brightness.
local filter_resp
do
  local QMIN, RESSPAN, FCMIN, FCMAX, EDGEMAX, PARK = 0.5, 11.5507, 10, 21600, 23520, 1.41421356
  local function glide(x, to, a) return a <= 0 and x or x * (to / x) ^ a end
  local function stage(f, f0, k, lp)
    if k < 0.02 then k = 0.02 end
    local w = f / f0
    local w2 = w * w
    local d = math.sqrt(math.max((1 - w2) ^ 2 + (k * w) ^ 2, 1e-20))
    return lp and 1 / d or w2 / d
  end
  local function bp(f, f0, k)
    if k < 0.02 then k = 0.02 end
    local w = f / f0
    return w / math.sqrt(math.max((1 - w * w) ^ 2 + (k * w) ^ 2, 1e-20))
  end
  -- returns a function f -> |H(f)|
  filter_resp = function()
    local fc = util.clamp(params:get("ffreq"), FCMIN, FCMAX)
    local bw, rs, t = params:get("fwidth"), params:get("fres"), params:get("ftype")
    local r = 2 ^ (bw * 3)
    local l, h = fc / r, fc * r
    local pl = t < 0.5 and 1 - 2 * t or 0
    local ph = t > 0.5 and 2 * t - 1 or 0
    if pl > 0 then h = glide(h, fc, pl); l = glide(l, FCMIN, pl) end
    if ph > 0 then l = glide(l, fc, ph); h = glide(h, EDGEMAX, ph) end
    local fL, fH = util.clamp(l, FCMIN, EDGEMAX), util.clamp(h, FCMIN, EDGEMAX)
    local k = rs >= 0.999 and 0 or 1 / (QMIN * 2 ^ (rs * RESSPAN))
    local kL = k + pl * (PARK - k)
    local kH = k + ph * (PARK - k)
    local xL = util.clamp((pl - 0.75) * 4, 0, 1)
    local xH = util.clamp((ph - 0.75) * 4, 0, 1)
    -- Varia's interior peaks
    local inner, gsum, kin = {}, 0, math.max(k, 0.02)
    local P = 2 + params:get("fpeaks") * 5
    if P > 2.0001 and rs > 1e-4 then
      local D = P - 1
      local span, base
      if pl == 0 and ph == 0 then span, base = bw * 6, fL
      else
        span = math.min(math.log(fH / fL, 2), 6)
        base = pl > 0 and fH / 2 ^ span or fL
      end
      for j = 1, 5 do
        local g = D - j
        if g <= 0 then break end
        g = math.min(g, 1) * rs
        inner[#inner + 1] = { util.clamp(base * 2 ^ (span * j / D), FCMIN, EDGEMAX), g }
        gsum = gsum + g
      end
    end
    local norm = 1 / (1 + 0.7 * gsum)
    return function(f)
      local a = stage(f, fL, kL, false) * (1 - xL) + xL
      local b = stage(f, fH, kH, true) * (1 - xH) + xH
      local m = a * b
      for _, pk in ipairs(inner) do m = m + pk[2] * bp(f, pk[1], kin) end
      return m * norm
    end
  end
end

draw_filter = function()
  local H = filter_resp()
  local mx = params:get("fmix")
  local body = math.floor(2 + 4 * mx)
  local crest = math.floor(5 + 10 * mx)
  screen.level(1)
  for x = 0, 127, 3 do screen.pixel(x, 12); screen.fill() end
  for x = 0, 127 do
    local f = 20 * 1000 ^ (x / 127)
    local db = 20 * math.log(math.max(H(f), 1e-6), 10)
    local y = math.floor(util.clamp(12 - db * 0.5, 0, 29) + 0.5)
    if y < 29 then
      screen.level(body); screen.move(x + 0.5, 29); screen.line(x + 0.5, y + 1); screen.stroke()
    end
    screen.level(crest); screen.pixel(x, y); screen.fill()
  end
  local fx = math.floor(127 * math.log(params:get("ffreq") / 20, 1000) + 0.5)
  screen.level(10); screen.move(fx + 0.5, 1); screen.line(fx + 0.5, 4); screen.stroke()
end

-- ── the macros ───────────────────────────────────────────────────────────────
-- Four blocks: name, a bar for the knob, and what it moves (short labels).
-- The selected macro (what K3 learns) is underlined; while learning, its
-- block blinks.
draw_macros = function()
  for k = 1, 4 do
    local x = ((k - 1) % 2) * 65 + 1
    local y = ((k - 1) // 2) * 15
    local t = MACRO_T[k]
    local lit = (learning == k) and (util.time() * 4 % 2 < 1) or (learning ~= k)
    screen.level(learning == k and (lit and 15 or 4) or (#t > 0 and 8 or 3))
    screen.move(x, y + 6); screen.text("M" .. k)
    if k == macro_sel then screen.level(10); screen.rect(x, y + 8, 9, 1); screen.fill() end
    screen.level(2); screen.rect(x + 12, y + 3, 48, 2); screen.fill()
    local v = params:get("m" .. k)
    if #t > 0 then
      screen.level(12); screen.rect(x + 12, y + 3, math.max(1, math.floor(48 * v + 0.5)), 2); screen.fill()
    end
    -- the first target with its unit ("fl mix"), then how many more
    local s = "K3 to learn"
    if #t > 0 then
      s = (ABBR2[UNIT_OF[t[1].id]] or "") .. " " .. SHORT[t[1].id] .. (#t > 1 and " +" .. (#t - 1) or "")
    end
    screen.level(3); screen.move(x + 12, y + 12); screen.text(s)
  end
end

-- ── the reverb ───────────────────────────────────────────────────────────────
-- Its decay on a log time axis (0.05 to 30 s): the tail falls 60 dB over the
-- reverb time. The bright upper band is the high end, which damping makes
-- fall faster; size spaces the columns (a bigger room, sparser
-- reflections); mix is the brightness.
draw_verb = function()
  local t60 = params:get("vtime")
  local damp = params:get("vdamp")
  local size = params:get("vsize")
  local mx = params:get("vmix")
  local t0, t1 = 0.05, 30
  local step = math.max(1, math.floor(1 + size * 0.8))
  for x = 1, 126, step do
    local t = t0 * (t1 / t0) ^ (x / 127)
    local lo = 1 - t / t60                         -- 0 dB .. -60 dB, as 1 .. 0
    local hi = 1 - t / (t60 * (1 - 0.85 * damp))
    if lo > 0 then
      local h = math.floor(lo * 26 + 0.5)
      screen.level(math.floor(2 + 6 * mx))
      screen.move(x + 0.5, 28); screen.line(x + 0.5, 28 - h); screen.stroke()
      if hi > 0 then
        local hh = math.floor(hi * 26 + 0.5)
        screen.level(math.floor(4 + 11 * mx))
        screen.move(x + 0.5, 28 - hh); screen.line(x + 0.5, 28 - hh - 2); screen.stroke()
      end
    end
  end
  -- 1 s and 10 s marks
  screen.level(3)
  for _, m in ipairs({ 1, 10 }) do
    local x = math.floor(127 * math.log(m / t0) / math.log(t1 / t0)) + 0.5
    screen.move(x, 29); screen.line(x, 30); screen.stroke()
  end
end

local function value_string(id)
  local kind = KIND[id]
  if kind == "toggle" then return nil end
  return params:string(id)
end

local function is_onoff(id)
  local o = OPTS[id]
  return o and #o == 2 and o[1] == "off" and o[2] == "on"
end

-- Cut a string to `px` pixels wide, marking the cut.
local function fit(str, px)
  if screen.text_extents(str) <= px then return str end
  while #str > 1 and screen.text_extents(str .. "~") > px do str = str:sub(1, -2) end
  return str .. "~"
end

-- One param on one line: a short label, then the value from x + 27 (five
-- letters of this font are 23-24 px; 22 ran "speed" into its value).
-- `lit`: the row E2 / E3 are turning.
local LABEL_W, VALUE_W = 27, 33
local function draw_param(x, y, id, lit)
  if not id then return end                 -- an empty slot on a page
  local on = active(id)
  local dim = not lit
  screen.level(lit and (on and 6 or 3) or (on and 3 or 1))
  screen.move(x, y)
  screen.text(SHORT[id])
  local vx = x + LABEL_W
  local vl = lit and (on and 15 or 4) or (on and 7 or 2)
  if KIND[id] == "file" then
    local name = sample_loaded and params:string(id) or "none"
    screen.level(vl); screen.move(vx, y); screen.text(fit(name, VALUE_W))
  elseif KIND[id] == "trigger" then
    screen.level(lit and (on and 10 or 3) or (on and 4 or 1))
    screen.move(vx, y); screen.text("E3 >")
  elseif KIND[id] == "toggle" then
    draw_toggle(vx, y, params:get(id) == 1 and "on" or "off", params:get(id) == 1, dim)
  elseif is_onoff(id) then
    local v = params:get(id) == 2
    draw_toggle(vx, y, v and "on" or "off", v, dim)
  else
    screen.level(vl)
    screen.move(vx, y)
    screen.text(fit(value_string(id), VALUE_W))
  end
end

local INSTALL_MSG = {
  installed   = { "dirac " .. VERSION, "engine installed.", "SYSTEM > RESTART,", "then load norns-dirac." },
  unsupported = { "dirac " .. VERSION, "this norns is not armv7l:", "build the engine", "from source (README)." },
  failed      = { "dirac " .. VERSION, "engine install failed.", "see maiden's output", "for the reason." },
}

function redraw()
  if install_state then
    screen.clear(); screen.font_face(1); screen.font_size(8)
    for i, line in ipairs(INSTALL_MSG[install_state]) do
      screen.level(i == 1 and 15 or (i == 3 and 15 or 8))
      screen.move(64, 10 + i * 11); screen.text_center(line)
    end
    screen.update()
    return
  end
  if browsing then return end              -- the file browser owns the screen
  if splash.active() then splash.draw(); return end
  screen.clear()
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)

  if k1_held and pending then
    draw_chain()
    if note_frames > 0 and note then
      screen.level(10); screen.move(64, 40); screen.text_center(note)
    end
    screen.update()
    return
  end

  local u = cur_unit()
  local p, row, pk, pn = cur_page()
  if u == "dirac" then
    draw_field()
  else
    if u == "loop" then draw_reel()
    elseif u == "delay" then draw_delay()
    elseif u == "verb" then draw_verb()
    elseif u == "filter" then draw_filter()
    elseif u == "macro" then draw_macros() end
    draw_loop_tag()
    -- the same "is anything arriving" meter as the field's
    screen.level(in_amp > 0.001 and 6 or 1)
    screen.rect(0, 0, math.max(1, math.floor(util.clamp(in_amp * 2, 0, 1) * 24)), 1)
    screen.fill()
  end

  -- learning a macro shows on every page, since learning happens on the
  -- other units' pages
  if learning then
    screen.level(15); screen.rect(84, 0, 44, 9); screen.fill()
    screen.level(0); screen.move(106, 7); screen.text_center("learn M" .. learning)
  end

  -- page row: the page's name, and the page dots - or, for a moment after a
  -- turn, the full name of the param being turned (the rows use short labels)
  screen.level(15)
  screen.move(0, 37)
  screen.text(p and p.name or ("slot " .. slot))
  if k2_down then
    screen.level(6); screen.text(" fine")
  end
  if touched_id and util.time() - touched_t < 1.2 then
    screen.level(10); screen.move(127, 37)
    screen.text_right(params:lookup_param(touched_id).name)
  else
    -- the chain, small: this slot bright, and under it how far through
    -- its unit's pages this page is
    local c = the_chain()
    c[NSLOT + 1] = "macro"
    for i = 1, NSLOT + 1 do
      local x = 48 + (i - 1) * 13
      screen.level(i == slot and 15 or 3)
      screen.move(x, 37); screen.text(ABBR2[c[i]])
      if i == slot and pn > 1 then
        local w = 9 / pn
        screen.level(10)
        screen.rect(x + math.floor((pk - 1) * w), 39, math.max(1, math.floor(w)), 1)
        screen.fill()
      end
    end
  end

  if not p then screen.update(); return end
  -- the four params: the lit row is the one E2 / E3 turn
  screen.level(15); screen.rect(0, (row == 1 and 47 or 59) - 6, 2, 7); screen.fill()
  draw_param(4, 47, p.main[1], row == 1)
  draw_param(66, 47, p.main[2], row == 1)
  draw_param(4, 59, p.alt[1], row == 2)
  draw_param(66, 59, p.alt[2], row == 2)

  if not engine_ok then
    -- usually: installed but not restarted yet, or the class library failed
    screen.level(15); screen.move(64, 12); screen.text_center("NO ENGINE")
    screen.level(8); screen.move(64, 22); screen.text_center("try SYSTEM > RESTART")
  elseif note_frames > 0 and note then
    screen.level(10); screen.move(64, 22); screen.text_center(note)
  end
  screen.update()
end

function cleanup()
  if poll_in then poll_in:stop() end
  if poll_out then poll_out:stop() end
  if poll_cpu then poll_cpu:stop() end
  if midi_dev then midi_dev.event = nil end
end
