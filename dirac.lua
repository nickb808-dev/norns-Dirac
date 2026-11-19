-- dirac
--
-- granular processor
-- ported from the ER-301
--
-- E2 select parameter
-- E3 change value
-- K1 held + E3: fine
-- E1 jump by section
-- K2/K3 page up/down
--
-- phase 2: a flat scrolling
-- list. the cell UI is next.

engine.name = "Dirac"

-- Relative to this script's own folder, so the install folder can be named
-- anything (it is `dirac` on the device; the repo is `norns-dirac`).
local SPEC = include("lib/params")

-- The on-screen list: every control, then every option. Built from the same
-- tables the params menu is built from, so the two cannot drift.

-- Calling engine.<id>(x) directly kills init() if the engine is not loaded:
-- params:bang() fires all 32 actions at once, the first nil index raises, and
-- norns then shows "error: init" on EVERY BOOT because it autoloads the last
-- script. A script should not be able to brick its own start-up because an
-- engine is missing.
--
-- So: send if we can, note it if we cannot, and keep going. The params menu
-- still works, the UI still draws, and the reason is on screen instead of
-- being a dead device.
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
-- on screen. norns' default rounds every control to 0.01, which hid the new
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

local LIST = {}
local sel = 1
local dirty = true
local k1_held = false   -- K1 held = fine adjust (x0.1 per detent)

-- ── meters ───────────────────────────────────────────────────────────────────
-- Fed by the engine's in_amp / out_amp polls. These exist because this engine
-- has been silent twice for reasons invisible from the norns, and because a
-- granular PROCESSOR that shows no input level is indistinguishable, on stage
-- or on the bench, from one whose DSP is broken. in > 0 and out = 0 is a DSP
-- bug; in = 0 is an audio-routing problem and no amount of DSP work touches it.
local in_amp, out_amp = 0, 0
local in_peak, out_peak = 0, 0

-- File scope, NOT local to init(), because cleanup() has to be able to stop
-- them. A poll is registered with matron, not with the script: norns tears down
-- a script's clocks and metros for you but it does NOT stop its polls. One left
-- running keeps firing into a callback whose script is gone, at its poll rate,
-- forever - which reads on screen as an endless "attempt to call a nil value"
-- with an empty traceback, because the call comes from C and there is no Lua
-- stack above it. That is not a crash in the next script; it is this one still
-- talking. Stopping them in cleanup() is the whole fix.
local poll_in, poll_out

local ROWS = 5   -- visible rows on the 64px screen

function init()
  -- Parameters come from lib/params.lua rather than being written out here, so
  -- the ranges cannot drift from the ER-301's. A hand-written second copy is
  -- exactly how Speed, Heads, Grains and Tilt ended up wrong the first time.
  for _, p in ipairs(SPEC) do
    local kind = p.kind or "control"
    if kind == "control" then
      local step = p.step or 0
      -- quantum is a fraction of the RANGE per detent. Integer dials move one
      -- whole unit per detent; everything else gets p.detents (default 200).
      local quantum = (step > 0) and (step / (p.max - p.min)) or (1 / (p.detents or 200))
      params:add_control(p.id, p.name,
        controlspec.new(p.min, p.max, p.warp or "lin", step, p.default, p.unit or "", quantum),
        formatter_for(p, quantum))
      params:set_action(p.id, function(x) send(p.id, x); dirty = true end)
    elseif kind == "option" then
      -- The menu shows names; the engine gets base + (index - 1).
      local base = p.base or 1
      params:add_option(p.id, p.name, p.options, p.default or 1)
      params:set_action(p.id, function(i) send(p.id, base + i - 1); dirty = true end)
    elseif kind == "toggle" then
      params:add_binary(p.id, p.name, "toggle", p.default or 0)
      params:set_action(p.id, function(v) send(p.id, v); dirty = true end)
    elseif kind == "trigger" then
      -- A rising edge is what the engine listens for. Send the edge, then
      -- drop back to 0 a moment later so the next press is a new edge.
      params:add_trigger(p.id, p.name)
      params:set_action(p.id, function()
        send(p.id, 1)
        clock.run(function() clock.sleep(0.02); send(p.id, 0) end)
        dirty = true
      end)
    end
    table.insert(LIST, { id = p.id, name = p.name, kind = kind })
  end

  -- bang() would also fire every trigger param, i.e. a grain burst at load.
  -- Harmless, but it is not "restore the saved state", so send everything
  -- except triggers.
  for _, p in ipairs(SPEC) do
    if (p.kind or "control") ~= "trigger" then
      params:lookup_param(p.id):bang()
    end
  end

  -- poll.set returns nil when the engine never registered the poll, which is
  -- precisely the case when the engine failed to load. Same rule as send():
  -- note it and keep going, never raise out of init().
  poll_in = poll.set("in_amp", function(v)
    in_amp = v
    if v > in_peak then in_peak = v end
    dirty = true
  end)
  poll_out = poll.set("out_amp", function(v)
    out_amp = v
    if v > out_peak then out_peak = v end
    dirty = true
  end)
  if poll_in and poll_out then
    poll_in.time = 0.1
    poll_out.time = 0.1
    poll_in:start()
    poll_out:start()
  else
    engine_ok = false
  end

  clock.run(function()
    while true do
      clock.sleep(1 / 15)
      -- Decay the held peaks rather than tracking the instantaneous value
      -- alone: a source that has stopped and a source that was never there
      -- must not look the same for the one frame you happen to be looking at.
      in_peak = in_peak * 0.96
      out_peak = out_peak * 0.96
      if dirty then redraw(); dirty = false end
    end
  end)
end

-- ── input ────────────────────────────────────────────────────────────────────
-- Without these the script page is inert: it draws, and no encoder or key does
-- anything. The first version had no enc/key at all on the theory that the
-- norns params menu was the interface, which is true but leaves the script's
-- own page dead in a way that reads as "broken" rather than "deliberate".
function enc(n, d)
  if n == 1 then
    -- coarse jump, so 32 entries are reachable without a long scroll
    sel = util.clamp(sel + (d * 5), 1, #LIST)
  elseif n == 2 then
    sel = util.clamp(sel + d, 1, #LIST)
  elseif n == 3 then
    local item = LIST[sel]
    if item.kind == "trigger" then
      if d > 0 then params:set(item.id, 1) end   -- any clockwise detent fires
    elseif item.kind == "toggle" then
      params:set(item.id, d > 0 and 1 or 0)
    elseif k1_held and item.kind == "control" then
      -- Fine: a tenth of a detent, in the param's own (possibly exponential)
      -- 0..1 space, so it is a tenth of the step you'd otherwise get HERE.
      local prm = params:lookup_param(item.id)
      prm:set_raw(prm:get_raw() + d * prm.controlspec.quantum * 0.1)
    else
      params:delta(item.id, d)
    end
  end
  dirty = true
end

function key(n, z)
  if n == 1 then k1_held = (z == 1); dirty = true; return end
  if z ~= 1 then return end
  if n == 2 then
    sel = util.clamp(sel - ROWS, 1, #LIST)
  elseif n == 3 then
    sel = util.clamp(sel + ROWS, 1, #LIST)
  end
  dirty = true
end

-- One meter: label, a 22 px bar, and a peak tick. Deliberately crude - it has
-- to answer "is anything arriving", not "what is the level", and it has to do
-- that in the 80 px left over beside the scroll position.
local function meter(x, label, v, peak)
  screen.level(3)
  screen.move(x, 63)
  screen.text(label)
  local x0 = x + (label == "in" and 12 or 18)
  screen.level(1)
  screen.rect(x0, 58, 22, 5)
  screen.stroke()
  local w = math.floor(util.clamp(v * 2, 0, 1) * 20)
  if w > 0 then
    screen.level(15)
    screen.rect(x0 + 1, 59, w, 3)
    screen.fill()
  end
  screen.level(peak > 0.001 and 8 or 2)
  screen.rect(x0 + 1 + math.floor(util.clamp(peak * 2, 0, 1) * 20), 58, 1, 5)
  screen.fill()
end

function redraw()
  screen.clear()

  -- Scroll so the selection stays in view, keeping one row of context above
  -- where possible.
  local top = util.clamp(sel - math.floor(ROWS / 2), 1, math.max(1, #LIST - ROWS + 1))

  for i = 0, ROWS - 1 do
    local idx = top + i
    local item = LIST[idx]
    if item then
      local y = 12 + (i * 11)
      screen.level(idx == sel and 15 or 3)
      screen.move(0, y)
      screen.text(item.name)
      screen.move(127, y)
      if item.kind == "toggle" then
        screen.text_right(params:get(item.id) == 1 and "on" or "off")
      elseif item.kind == "trigger" then
        screen.text_right("E3 >")
      else
        screen.text_right(params:string(item.id))
      end
    end
  end

  screen.level(1)
  screen.move(0, 63)
  screen.text(sel .. "/" .. #LIST)

  if not engine_ok then
    screen.level(15)
    screen.move(127, 63)
    screen.text_right("NO ENGINE")
  else
    meter(46, "in", in_amp, in_peak)
    meter(90, "out", out_amp, out_peak)
  end
  screen.update()
end

function cleanup()
  -- Stop the meters. See the note at poll_in/poll_out: an unstopped poll
  -- outlives the script and errors on every fire from then on.
  if poll_in then poll_in:stop() end
  if poll_out then poll_out:stop() end
end
