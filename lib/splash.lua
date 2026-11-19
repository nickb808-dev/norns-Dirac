-- lib/splash.lua — the Dirac title screen.
--
-- Geometric and a little retro-futurist: "DIRAC" in wide, squared letters
-- with chamfered corners (the Eurostile / Microgramma family of 80s sci-fi
-- type), drawn as strokes, over a perspective grid floor that scrolls toward
-- the viewer and a striped wireframe sun on the horizon.
--
-- Credit: (c) 2026 nickb808.
--
-- Shown as the script starts (~3 s); any key or encoder skips it.

local M = {}

local DURATION = 3.0          -- seconds
local t0 = nil                -- start time; nil when not showing

-- ── the letters ──────────────────────────────────────────────────────────────
-- Each letter is a set of polylines on a 15 x 10 grid (x right, y down),
-- stroked with a 2 x 2 pixel brush, so letters are 16 x 11 px. Corners are cut
-- at 45 degrees; that, and the width, is what reads as "futuristic".
local LETTERS = {
  D = { w = 15, lines = { { {0,0}, {11,0}, {14,3}, {14,7}, {11,10}, {0,10}, {0,0} } } },
  I = { w = 1,  lines = { { {0,0}, {0,10} } } },
  R = { w = 15, lines = { { {0,10}, {0,0}, {12,0}, {14,2}, {14,4}, {12,6}, {0,6} },
                          { {11,6}, {14,9}, {14,10} } } },
  A = { w = 15, lines = { { {0,10}, {0,3}, {3,0}, {14,0}, {14,10} },
                          { {0,6}, {14,6} } } },
  C = { w = 14, lines = { { {14,0}, {3,0}, {0,3}, {0,7}, {3,10}, {14,10} } } },
}
local WORD = { "D", "I", "R", "A", "C" }
local SPACING = 6
local LOGO_Y = 3

-- Rasterise once: the set of pixels each letter covers, with a 2 x 2 brush
-- stepped along every segment.
local logo = {}               -- { {x, y}, ... } relative to the logo's origin
local LOGO_W = 0
do
  local seen = {}
  local x0 = 0
  for i, ch in ipairs(WORD) do
    local L = LETTERS[ch]
    for _, pl in ipairs(L.lines) do
      for k = 1, #pl - 1 do
        local ax, ay, bx, by = pl[k][1], pl[k][2], pl[k + 1][1], pl[k + 1][2]
        local n = math.max(math.abs(bx - ax), math.abs(by - ay))
        for s = 0, n do
          local px = x0 + math.floor(ax + (bx - ax) * s / math.max(n, 1) + 0.5)
          local py = math.floor(ay + (by - ay) * s / math.max(n, 1) + 0.5)
          for dx = 0, 1 do for dy = 0, 1 do
            local key = (px + dx) .. ":" .. (py + dy)
            if not seen[key] then seen[key] = true; logo[#logo + 1] = { px + dx, py + dy } end
          end end
        end
      end
    end
    x0 = x0 + L.w + 1 + ((i < #WORD) and SPACING or 0)
  end
  LOGO_W = x0
end
local LOGO_X = math.floor((128 - LOGO_W) / 2)

-- Brightness by row: bright top, a black cut through the lower third (the
-- "speed line" through the word), dimmer below it. Row 8: below the A's
-- crossbar and the R's bowl (rows 6-7), so only stems are cut.
local ROW_LEVEL = { [0] = 15, 15, 15, 14, 14, 13, 12, 12, 0, 9, 9, 8 }

-- ── the scene ────────────────────────────────────────────────────────────────
local HORIZON = 33            -- the grid's horizon line
local VX = 64                 -- vanishing point x
local SUN_R = 14

local stars = {}
do
  local s = 4242
  for i = 1, 22 do
    s = (s * 1103515245 + 12345) % 2147483648
    stars[i] = { x = s % 128, y = (s // 128) % (HORIZON - 2), l = 1 + (s // 7) % 3 }
  end
end

-- ── public ───────────────────────────────────────────────────────────────────
function M.start() t0 = util.time() end
function M.skip() t0 = nil end
function M.active()
  if not t0 then return false end
  if util.time() - t0 > DURATION then t0 = nil; return false end
  return true
end

-- t: seconds since start (a previewer can pass any t)
function M.draw(t)
  t = t or (t0 and util.time() - t0 or 0)
  screen.clear()
  screen.aa(0)
  screen.line_width(1)

  -- stars
  for _, s in ipairs(stars) do
    screen.level(s.l); screen.pixel(s.x, s.y); screen.fill()
  end

  -- the sun: a half disc on the horizon cut into stripes that thicken
  -- toward the bottom, the classic retro-futurist sunset
  for y = HORIZON - SUN_R, HORIZON - 1 do
    local dy = HORIZON - y
    local band = (HORIZON - y)
    -- stripe gaps grow as we approach the horizon
    local gap = (band < 3) and (band % 2 == 0) or (band < 8 and band % 3 == 0) or (band < 14 and band % 5 == 0)
    if not gap then
      local half = math.floor(math.sqrt(math.max(0, SUN_R * SUN_R - dy * dy)))
      screen.level((dy > 12) and 3 or 4)
      screen.rect(VX - half, y, half * 2 + 1, 1)
      screen.fill()
    end
  end

  -- the floor: lines converging on the vanishing point, and cross lines that
  -- scroll toward the viewer and spread out as they come
  screen.level(5)
  for i = -9, 9 do
    screen.move(VX + i * 2 + 0.5, HORIZON + 0.5)
    screen.line(VX + i * 22 + 0.5, 64.5)
  end
  screen.stroke()
  local phase = (t * 0.9) % 1
  for k = 0, 6 do
    local z = (k + phase) / 7              -- 0 at the horizon, 1 at the viewer
    local y = HORIZON + math.floor((64 - HORIZON) * z * z + 0.5)
    if y > HORIZON and y < 64 then
      screen.level(math.floor(2 + 6 * z))
      screen.move(0, y + 0.5); screen.line(128, y + 0.5); screen.stroke()
    end
  end
  screen.level(10)
  screen.move(0, HORIZON + 0.5); screen.line(128, HORIZON + 0.5); screen.stroke()

  -- the word: black backing first so the sun and stars do not show through
  -- the letters' cut, then the rows, revealed top-down over the first 0.4 s
  local reveal = math.floor(util.clamp(t / 0.4, 0, 1) * 12)
  screen.level(0)
  screen.rect(LOGO_X - 2, LOGO_Y - 2, LOGO_W + 4, 15)
  screen.fill()
  for _, p in ipairs(logo) do
    local row = p[2]
    if row < reveal then
      local l = ROW_LEVEL[row] or 10
      if l > 0 then
        screen.level(l); screen.pixel(LOGO_X + p[1], LOGO_Y + row); screen.fill()
      end
    end
  end
  -- a thin rule under the word, tapering at the ends
  if reveal >= 12 then
    for x = 0, LOGO_W - 1 do
      local e = math.min(x, LOGO_W - 1 - x)
      screen.level(util.clamp(2 + e // 3, 2, 9))
      screen.pixel(LOGO_X + x, LOGO_Y + 14); screen.fill()
    end
  end

  -- prompt and credit on black plates on the floor, so grid lines never
  -- run through the text
  screen.font_face(1); screen.font_size(8)
  if t > 0.6 and math.floor(t * 2.5) % 2 == 0 then
    local pw = screen.text_extents("PUSH ANY KEY")
    screen.level(0); screen.rect(64 - pw / 2 - 3, 41, pw + 6, 9); screen.fill()
    screen.level(13); screen.move(64, 48); screen.text_center("PUSH ANY KEY")
  end

  local credit = "2026 nickb808"
  local w = screen.text_extents(credit)
  local cx = math.floor(64 - (w + 7) / 2)
  screen.level(0); screen.rect(cx - 3, 55, w + 13, 9); screen.fill()
  screen.level(7)
  -- a drawn (c): the font has no copyright glyph
  screen.circle(cx + 2.5, 59.5, 2.5); screen.stroke()
  screen.pixel(cx + 2, 58); screen.pixel(cx + 3, 58); screen.pixel(cx + 1, 59)
  screen.pixel(cx + 2, 60); screen.pixel(cx + 3, 60); screen.fill()
  screen.move(cx + 7, 62); screen.text(credit)

  screen.update()
end

return M
