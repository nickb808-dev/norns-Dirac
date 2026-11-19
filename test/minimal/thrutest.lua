-- thrutest
--
-- the input-path control
-- experiment. audio in ->
-- audio out, nothing else.
--
-- tonetest proved OUTPUT.
-- this proves INPUT.
--
-- E3 output amp
-- meters show the two input
-- busses SEPARATELY

engine.name = "ThruTest"

local amp_l, amp_r = 0, 0
local peak_l, peak_r = 0, 0
local engine_ok = true
local dirty = true

-- File scope so cleanup() can stop them. norns stops a script's clocks and
-- metros on teardown but NOT its polls; one left running fires into a dead
-- callback forever.
local poll_l, poll_r

-- A meter that only ever moves is useless for a fault where the input is
-- CONSTANT silence, so hold a decaying peak next to the live value: a peak that
-- has been pinned at 0.000 for ten seconds is a positive result, not a
-- missed reading.
local function observe(which, v)
  if which == "l" then
    amp_l = v
    if v > peak_l then peak_l = v end
  else
    amp_r = v
    if v > peak_r then peak_r = v end
  end
  dirty = true
end

function init()
  params:add_control("amp", "amp", controlspec.new(0, 1, "lin", 0, 1.0, ""))
  params:set_action("amp", function(x)
    if type(engine.amp) == "function" then engine.amp(x) else engine_ok = false end
    dirty = true
  end)
  params:bang()

  -- poll.set returns nil if the engine never registered the poll, which is
  -- exactly what happens when the engine failed to load. Guard it: the whole
  -- point of this script is to still be looking at you when things are broken.
  poll_l = poll.set("amp_l", function(v) observe("l", v) end)
  poll_r = poll.set("amp_r", function(v) observe("r", v) end)
  if poll_l and poll_r then
    poll_l.time = 0.1
    poll_r.time = 0.1
    poll_l:start()
    poll_r:start()
  else
    engine_ok = false
  end

  clock.run(function()
    while true do
      clock.sleep(1 / 15)
      -- decay the held peaks slowly so a source that stopped is still legible
      peak_l = peak_l * 0.97
      peak_r = peak_r * 0.97
      if dirty then redraw(); dirty = false end
    end
  end)
end

function enc(n, d)
  if n == 3 then params:delta("amp", d) end
  dirty = true
end

function key(n, z)
  if z == 1 and n == 2 then
    peak_l, peak_r = 0, 0   -- re-arm the peak hold
    dirty = true
  end
end

local function bar(y, label, v, peak)
  local w = math.floor(util.clamp(v, 0, 1) * 90)
  screen.level(3)
  screen.move(0, y)
  screen.text(label)
  screen.level(15)
  screen.rect(20, y - 5, math.max(w, 1), 5)
  screen.fill()
  -- peak tick
  screen.level(4)
  screen.rect(20 + math.floor(util.clamp(peak, 0, 1) * 90), y - 6, 1, 7)
  screen.fill()
  screen.level(peak > 0.0005 and 15 or 3)
  screen.move(127, y)
  screen.text_right(string.format("%.3f", v))
end

function redraw()
  screen.clear()

  screen.level(15)
  screen.move(0, 10)
  screen.text("thrutest")
  screen.level(3)
  screen.move(127, 10)
  screen.text_right(string.format("amp %.2f", params:get("amp")))

  bar(28, "in1", amp_l, peak_l)
  bar(42, "in2", amp_r, peak_r)

  screen.level(1)
  screen.move(0, 60)
  if not engine_ok then
    screen.level(15)
    screen.text("NO ENGINE - check maiden")
  elseif peak_l < 0.0005 and peak_r < 0.0005 then
    screen.text("no input reaching scsynth")
  else
    screen.text("input OK - you should hear it")
  end
  screen.update()
end

function cleanup()
  if poll_l then poll_l:stop() end
  if poll_r then poll_r:stop() end
end
