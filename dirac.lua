-- dirac v0.9.0 beta
-- granular processor
-- from the ER-301
-- by nickb808
--
-- first run installs the
-- engine: then SYSTEM >
-- RESTART and load again
--
-- E1 page
-- E2 / E3 the page's pair
-- K1 held: the alt pair
-- K2 tap: hold on/off
-- K2 held + E2/E3: fine
-- K3: fire
-- K1 held + K3: save the
--   buffer to a wav
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

local VERSION = "0.9.0-beta.1"

-- ── first run: install the engine's SuperCollider plugin ─────────────────────
-- Testers install with ;install and never compile. The repo carries a prebuilt
-- Dirac.so (ugen/prebuilt/, stamped with a source hash in BUILD); this runs as
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
  local installed = util.file_exists(EXT .. "Dirac.so")
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
  local stepsize = (p.step and p.step > 0) and p.step or (p.max - p.min) * quantum
  local decimals = util.clamp(math.ceil(-math.log(stepsize, 10) - 1e-9), 0, 3)
  local f = "%." .. decimals .. "f"
  return function(param) return string.format(f, param:get()) .. unit end
end

local KIND = {}   -- id -> kind, from SPEC

local note, note_frames = nil, 0         -- one-line transient message
local function flash(msg)
  note, note_frames = msg, 40
end
local OPTS = {}   -- id -> option labels, for on/off detection

-- ── pages ────────────────────────────────────────────────────────────────────
-- Two params on E2/E3, two more with K1 held. Everything else (and all of it,
-- for MIDI mapping and PSETs) is in the norns PARAMS menu.
local PAGES = {
  -- Each page: the control that defines it (or its enable switch) first, the
  -- one it is most often paired with second, refinements under K1. Controls
  -- that are inert in the current state dim (see ACTIVE_IF).
  { name = "grain", main = { "rate", "grainlen" },        alt = { "grains", "revprob" } },
  { name = "shape", main = { "window", "texture" },       alt = { "tilt", "tiltspread" } },
  { name = "scan",  main = { "playhead", "posjtr" },      alt = { "speed", "snap" } },
  { name = "pitch", main = { "semishift", "psprd" },      alt = { "scale", "voct" } },
  { name = "heads", main = { "playheadsOpt", "heads" },   alt = { "headspread", "headtune" } },
  { name = "space", main = { "spread", "binaural" },      alt = { "detune", "diffuseOpt" } },
  { name = "regen", main = { "feedback", "compress" },    alt = { "freezeOpt", "hold" } },
  { name = "out",   main = { "mix", "level" },            alt = { "insrc", "ingain" } },
  { name = "file",  main = { "source", "sample" },        alt = { "unload", "capture" } },
}
local page = 1

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
-- Controls that only act while something else is set. The ER-301 reveals
-- them when their switch is turned on; here they stay on their page but dim
-- while inert, so the screen says so rather than letting a turn look broken.
-- Each rule is the engine's own condition (engine/Dirac.cpp).
local function multi_on() return params:get("playheadsOpt") == 2 end
local ACTIVE_IF = {
  -- mMultiHeadOpt Off hard-bypasses the multi-head path
  heads = multi_on, headspread = multi_on, headtune = multi_on,
  -- Speed scans a loaded sample (speed != 0 && sampleCount > 1); live, it is
  -- inert
  speed = function() return viz.sample end,
  -- Mix is the live wet/dry (`if (liveMode && mix < ...)`); a loaded sample
  -- has no dry signal to mix
  mix = function() return not viz.sample end,
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
local poll_in, poll_out

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
    if kind == "control" then
      local step = p.step or 0
      -- quantum is a fraction of the RANGE per detent. Integer dials move one
      -- whole unit per detent; everything else gets p.detents (default 200).
      local quantum = (step > 0) and (step / (p.max - p.min)) or (1 / (p.detents or 200))
      params:add_control(p.id, p.name,
        controlspec.new(p.min, p.max, p.warp or "lin", step, p.default, p.unit or "", quantum),
        formatter_for(p, quantum))
      params:set_action(p.id, function(x) send(p.id, x) end)
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
        fire_flash = 8
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
  for _, p in ipairs(SPEC) do
    if (p.kind or "control") ~= "trigger" then
      params:lookup_param(p.id):bang()
    end
  end

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
  if path == "/dirac/viz" then
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
  local p = PAGES[page]
  return k1_held and p.alt or p.main
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
  if n == 1 then
    page = util.clamp(page + d, 1, #PAGES)
  else
    if k2_down then k2_used = true end
    adjust(current_pair()[n - 1], d)
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
  elseif n == 2 then
    if z == 1 then
      k2_down, k2_used = true, false
      if k1_held then
        view_stereo = not view_stereo
        k2_used = true
        flash(view_stereo and "field: stereo" or "field: position")
      end
    else
      if not k2_used then
        params:set("hold", params:get("hold") == 1 and 0 or 1)
      end
      k2_down = false
    end
  elseif n == 3 and z == 1 then
    if k1_held then
      params:set("capture", 1)
    else
      params:set("fire", 1)
    end
  end
end

-- ── drawing ──────────────────────────────────────────────────────────────────
local FY, FH = 0, 40          -- field rows 0..39
local YC = FY + 20            -- pitch 0 / waveform centre
local PX_PER_ST = 0.75        -- +-24 st fills the field

local function xof(pos01) return math.floor(util.clamp(pos01, 0, 1) * 127 + 0.5) end

-- Live mode, a ring position measured from the write head: 0 oldest, 1 now.
-- The same frame the engine uses for grain positions.
local function bin_x(b)
  local start = (b - 1) * (RING / BINS)
  local age = (wave.cap - start) % RING
  return xof(1 - age / RING)
end

local function draw_toggle(x, y, label, on)
  -- A visible on/off state, never a number.
  local w = #label * 4 + 3
  if on then
    screen.level(12); screen.rect(x, y - 6, w, 7); screen.fill()
    screen.level(0)
  else
    screen.level(3); screen.rect(x + 0.5, y - 5.5, w - 1, 6); screen.stroke()
    screen.level(3)
  end
  screen.move(x + 2, y); screen.text(label)
  return w
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

  -- tiny input meter, top left: the "is anything arriving" answer
  screen.level(in_amp > 0.001 and 6 or 1)
  screen.rect(0, 0, math.max(1, math.floor(util.clamp(in_amp * 2, 0, 1) * 24)), 1)
  screen.fill()
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

local function draw_param(x, id)
  if not id then return end                 -- an empty slot on a page
  local prm = params:lookup_param(id)
  local on = active(id)
  screen.level(on and 4 or 2)
  screen.move(x, 55)
  screen.text(prm.name)
  if KIND[id] == "file" then
    local name = sample_loaded and params:string(id) or "none"
    if #name > 14 then name = name:sub(1, 13) .. "~" end
    screen.level(on and 15 or 3); screen.move(x, 63); screen.text(name)
  elseif KIND[id] == "trigger" then
    screen.level(on and 10 or 3); screen.move(x, 63); screen.text("E3 >")
  elseif KIND[id] == "toggle" then
    draw_toggle(x, 63, params:get(id) == 1 and "on" or "off", params:get(id) == 1)
  elseif is_onoff(id) then
    local on = params:get(id) == 2
    draw_toggle(x, 63, on and "on" or "off", on)
  else
    screen.level(on and 15 or 3)
    screen.move(x, 63)
    screen.text(value_string(id))
  end
end

local INSTALL_MSG = {
  installed   = { "dirac " .. VERSION, "engine installed.", "SYSTEM > RESTART,", "then load dirac again." },
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

  draw_field()

  -- page row
  screen.level(15)
  screen.move(0, 47)
  screen.text(PAGES[page].name)
  if k1_held then
    screen.level(6); screen.text(" alt")
  end
  if k2_down then
    screen.level(6); screen.text(" fine")
  end
  for i = 1, #PAGES do
    screen.level(i == page and 15 or 2)
    screen.rect(127 - (#PAGES - i) * 5 - 2, 44, 2, 2)
    screen.fill()
  end

  local pair = current_pair()
  draw_param(0, pair[1])
  draw_param(66, pair[2])

  if not engine_ok then
    -- usually: installed but not restarted yet, or the class library failed
    screen.level(15); screen.move(64, 20); screen.text_center("NO ENGINE")
    screen.level(8); screen.move(64, 30); screen.text_center("try SYSTEM > RESTART")
  elseif note_frames > 0 and note then
    screen.level(10); screen.move(64, 30); screen.text_center(note)
  end
  screen.update()
end

function cleanup()
  if poll_in then poll_in:stop() end
  if poll_out then poll_out:stop() end
end
