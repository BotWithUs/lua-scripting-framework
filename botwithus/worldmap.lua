-- botwithus.worldmap -- world map elements: lodestones, place labels, quest starts, fairy rings.
--
--   local WorldMap = require("botwithus.worldmap")
--   WorldMap.elements()                                          -- area 28, the main world
--   WorldMap.elements(nil, { category = 2613, near = { x = 3233, y = 3222 }, radius = 10 })
--   WorldMap.elements(231)                                       -- Prifddinas at its real tiles
--   WorldMap.nearest(3233, 3222, { category = 2613 })
--
-- Read from the game cache (index 41) through the native host (host ABI 7), each placement
-- joined with its definition: { area_id, element_id, x, y, plane, flags, category, sprite_id,
-- name, tooltip, text_truncated }. Most minimap function icons (banks, altars) are not here:
-- they are locs.
--
-- ONE AREA AT A TIME, THE MAIN WORLD BY DEFAULT. Every placement belongs to a world map area and
-- its tile is in that area's map space. Area 28 draws a few regions (Prifddinas, Ashdale) away
-- from their real tiles and places them again, at the real tile, in their own area: the
-- Prifddinas lodestone is (4576, 2665) in area 28 and (2208, 3361) in area 231. So area 28 is the
-- default, as in the Java host; ALL_AREAS reads every area, and those regions then appear twice.
-- Many definitions carry no name (the lodestones among them): match by category and tile.

local M = {}

M.MAIN_AREA_ID = 28
M.ALL_AREAS    = -1

local function chebyshev(e, x, y) return math.max(math.abs(e.x - x), math.abs(e.y - y)) end

local function read(area_id)
  local b = rawget(_G, "bwu")
  if not b then error("botwithus: native `bwu` surface not present (run under bwu_host)", 3) end
  if b.worldmap_elements == nil then
    error("botwithus: this bwu_host has no worldmap_elements; it predates them (native ABI 7)"
          .. " -- update it", 3)
  end
  local found, why = b.worldmap_elements(area_id)
  if found == nil then error("botwithus: worldmap_elements(" .. area_id .. "): " .. tostring(why), 3) end
  return found
end

local function matches(e, filter)
  if filter.name ~= nil then
    local needle = filter.name:lower()
    if not (e.name:lower():find(needle, 1, true) or e.tooltip:lower():find(needle, 1, true)) then
      return false
    end
  end
  if filter.category ~= nil and e.category ~= filter.category then return false end
  if filter.plane ~= nil and e.plane ~= filter.plane then return false end
  if filter.near ~= nil and filter.radius ~= nil
     and chebyshev(e, filter.near.x, filter.near.y) > filter.radius then
    return false
  end
  return true
end

-- The placements of `area_id` (nil: the main world) that `filter` accepts:
--   name      case-insensitive substring of the name or the tooltip
--   category  exact
--   plane     exact
--   near      { x =, y = }: sort nearest first; with radius, keep those within it (Chebyshev)
function M.elements(area_id, filter)
  filter = filter or {}
  local out = {}
  for _, e in ipairs(read(area_id or M.MAIN_AREA_ID)) do
    if matches(e, filter) then out[#out + 1] = e end
  end
  if filter.near ~= nil then
    local x, y = filter.near.x, filter.near.y
    table.sort(out, function(a, b) return chebyshev(a, x, y) < chebyshev(b, x, y) end)
  end
  return out
end

-- The placement nearest (x, y) that `filter` accepts (filter.area_id picks the area), or nil.
function M.nearest(x, y, filter)
  local f = {}
  for k, v in pairs(filter or {}) do f[k] = v end
  f.near = { x = x, y = y }
  return M.elements(f.area_id, f)[1]
end

return M
