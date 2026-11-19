-- dirac
-- granular processor
-- from the ER-301
--
-- E1 page
-- E2 / E3 the page's pair
-- K1 held: the alt pair
-- K2 tap: hold on/off
-- K2 held + E2/E3: fine
-- K3: fire
-- K1 held + K2: field x =
--   position / stereo
--
-- every param is also in
-- the PARAMS menu

engine.name = "Dirac"

-- Relative to this script's own folder, so the install folder can be named
-- anything (it is `dirac` on the device; the repo is `norns-dirac`).
local SPEC = include("lib/params")

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
local OPTS = {}   -- id -> option labels, for on/off detection

-- ── pages ────────────────────────────────────────────────────────────────────
-- Two params on E2/E3, two more with K1 held. Everything else (and all of it,
-- for MIDI mapping and PSETs) is in the norns PARAMS menu.
local PAGES = {
  { name = "grain", main = { "rate", "grainlen" },     alt = { "grains", "window" } },
  { name = "scan",  main = { "playhead", "speed" },    alt = { "posjtr", "revprob" } },
  { name = "pitch", main = { "semishift", "psprd" },   alt = { "scale", "voct" } },
  { name = "tone",  main = { "texture", "tilt" },      alt = { "tiltspread", "snap" } },
  { name = "space", main = { "spread", "binaural" },   alt = { "detune", "diffuseOpt" } },
  { name = "heads", main = { "heads", "headspread" },  alt = { "headtune", "playheadsOpt" } },
  { name = "regen", main = { "feedback", "compress" }, alt = { "freezeOpt", "hold" } },
  { name = "out",   main = { "mix", "level" },         alt = { "ingain", "insrc" } },
}
local page = 1

-- ── key state ────────────────────────────────────────────────────────────────
-- K1 reaches the script only once held past 0.25 s (a shorter tap toggles the
-- norns menu and never arrives), so K1 is a pure modifier here.
local k1_held = false
local k2_down, k2_used = false, false   -- K2: tap = hold toggle; held = fine
local view_stereo = false                -- field x: position (false) / pan
local fire_flash = 0                     -- frames left of the "fire" flash
local note, note_frames = nil, 0         -- one-line transient message

-- ── meters ───────────────────────────────────────────────────────────────────
-- in > 0 and out = 0 is a DSP bug; in = 0 is routing. Both have mattered.
local in_amp, out_amp = 0, 0

-- ── the field: what the UGen streams (see ugen/DiracUGen.cpp) ───────────────
local viz = { sample = false, frozen = false, cap = 0, head = 0, grains = {} }
local wave = { cap = 0, peaks = {} }
local RING = 131072      -- engine ring size; the UGen's test proves it
local BINS = 128

-- File scope so cleanup() can stop them: norns does NOT stop a script's polls,
-- and one left running fires into a dead callback forever.
local poll_in, poll_out

-- ── init ─────────────────────────────────────────────────────────────────────
function init()
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
    elseif kind == "trigger" then
      -- A rising edge is what the engine listens for. Send the edge, then
      -- drop back to 0 a moment later so the next press is a new edge.
      params:add_trigger(p.id, p.name)
      params:set_action(p.id, function()
        send(p.id, 1)
        fire_flash = 4
        clock.run(function() clock.sleep(0.02); send(p.id, 0) end)
      end)
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

  -- The field animates, so redraw every frame rather than on change.
  clock.run(function()
    while true do
      clock.sleep(1 / 15)
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
    local g = {}
    for i = 0, n - 1 do
      local o = 5 + i * 6
      g[#g + 1] = { pos = args[o + 1], spawn = args[o + 2], pitch = args[o + 3],
                    bright = args[o + 4], pan = args[o + 5], rev = args[o + 6] > 0.5 }
    end
    viz.grains = g
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

local function flash(msg)
  note, note_frames = msg, 20
end

local function adjust(id, d)
  local kind = KIND[id]
  if kind == "toggle" then
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
  if n == 1 then
    page = util.clamp(page + d, 1, #PAGES)
  else
    if k2_down then k2_used = true end
    adjust(current_pair()[n - 1], d)
  end
end

function key(n, z)
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
      flash("capture: coming soon")
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

local function draw_field()
  -- waveform: dim columns, live ring only (sample peaks arrive with files)
  if not viz.sample and #wave.peaks == BINS then
    screen.level(2)
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

  -- grains: x = read position (or pan), y = pitch, brightness = envelope x gain
  for _, g in ipairs(viz.grains) do
    local x = view_stereo and xof((g.pan + 1) / 2) or xof(g.pos)
    local y = math.floor(util.clamp(YC - g.pitch * PX_PER_ST, FY + 1, FY + FH - 2))
    local lvl = math.floor(util.clamp(3 + 12 * math.sqrt(util.clamp(g.bright * 2, 0, 1)), 1, 15))
    if not view_stereo then
      -- read-span trail from where the grain started, as on the ER-301
      local sx = xof(g.spawn)
      if sx ~= x then
        screen.level(2); screen.move(sx + 0.5, y + 0.5); screen.line(x + 0.5, y + 0.5); screen.stroke()
      end
    end
    screen.level(lvl)
    screen.rect(x - 1, y - 1, 2, 2)
    screen.fill()
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
  local prm = params:lookup_param(id)
  screen.level(4)
  screen.move(x, 55)
  screen.text(prm.name)
  if KIND[id] == "toggle" then
    draw_toggle(x, 63, params:get(id) == 1 and "on" or "off", params:get(id) == 1)
  elseif is_onoff(id) then
    local on = params:get(id) == 2
    draw_toggle(x, 63, on and "on" or "off", on)
  else
    screen.level(15)
    screen.move(x, 63)
    screen.text(value_string(id))
  end
end

function redraw()
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
    screen.level(15); screen.move(64, 24); screen.text_center("NO ENGINE")
  elseif note_frames > 0 and note then
    screen.level(10); screen.move(64, 30); screen.text_center(note)
  end
  screen.update()
end

function cleanup()
  if poll_in then poll_in:stop() end
  if poll_out then poll_out:stop() end
end
