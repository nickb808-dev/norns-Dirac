-- dirac
--
-- granular processor
-- ported from the ER-301
--
-- E2 select parameter
-- E3 change value
-- E1 jump by section
-- K2/K3 page up/down
-- K1 for norns menu
--
-- phase 2: a flat scrolling
-- list. the cell UI is next.

engine.name = "Dirac"

-- Relative to this script's own folder, so the install folder can be named
-- anything (it is `dirac` on the device; the repo is `norns-dirac`).
local SPEC = include("lib/params")

local OPTIONS = {
  -- 1-based, matching od::OptionControl on the ER-301. The engine compares
  -- against literal 1/2/3, so index 0 would select nothing at all.
  { id = "playheadsOpt", name = "playheads",  choices = { "single", "multi" },  default = 1 },
  { id = "diffuseOpt",   name = "diffuse",    choices = { "off", "on" },        default = 1 },
  { id = "freezeOpt",    name = "capture",    choices = { "run", "freeze" },    default = 1 },
}

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

local LIST = {}
local sel = 1
local dirty = true

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
    local step = p.step or 0
    params:add_control(
      p.id, p.name,
      controlspec.new(p.min, p.max, p.warp or "lin", step, p.default, p.unit or ""))
    params:set_action(p.id, function(x)
      send(p.id, x)
      dirty = true
    end)
    table.insert(LIST, { id = p.id, name = p.name, kind = "control" })
  end

  for _, o in ipairs(OPTIONS) do
    params:add_option(o.id, o.name, o.choices, o.default)
    params:set_action(o.id, function(i)
      send(o.id, i)
      dirty = true
    end)
    table.insert(LIST, { id = o.id, name = o.name, kind = "option" })
  end

  params:bang()

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
    params:delta(LIST[sel].id, d)
  end
  dirty = true
end

function key(n, z)
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
      screen.text_right(params:string(item.id))
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
