-- check-pages.lua: every param in lib/params.lua is on exactly one page of
-- dirac.lua's PAGES (fire excepted: it is K3), and every page names a real
-- param. A param left off every page is reachable only from the PARAMS menu,
-- which is how "I can't see grain count" happens.
local SPEC = dofile("lib/params.lua")
local OFF_PAGE = { fire = "K3" }
local ids = {}
for _, p in ipairs(SPEC) do ids[p.id] = true end
local src = assert(io.open("dirac.lua")):read("a")
local block = src:match("local PAGES = (%b{})")
if not block then print("check-pages: FAIL  could not find PAGES in dirac.lua"); os.exit(1) end
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
