-- tonetest
--
-- the smallest possible
-- norns script: one engine,
-- one tone, nothing else.
--
-- Build a WORKING baseline
-- before adding anything.

engine.name = "ToneTest"

function init()
  params:add_control("hz", "hz",
    controlspec.new(100, 2000, "exp", 0, 440, "hz"))
  params:set_action("hz", function(x) engine.hz(x) end)
  params:bang()
  redraw()
end

function enc(n, d)
  if n == 3 then params:delta("hz", d) end
  redraw()
end

function redraw()
  screen.clear()
  screen.level(15)
  screen.move(0, 20)
  screen.text("tonetest")
  screen.move(0, 40)
  screen.text(string.format("%.0f hz", params:get("hz")))
  screen.move(0, 55)
  screen.level(3)
  screen.text("E3 pitch. should be audible.")
  screen.update()
end

function cleanup() end
