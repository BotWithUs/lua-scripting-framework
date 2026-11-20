-- Live smoke for host ABI 7: bwu_host --lua tests/live/n2_smoke.lua
--
-- Cache definitions, world map elements, an avoid-area plan and route links through this
-- framework, against a client in the world and a bwu_host at ABI 7 with NXTCache.dll and a
-- worldwalker.dll from WorldWalker #44 or later in BWU_NATIVE_DIR. It only reads and plans: it
-- walks nowhere and clicks nothing.
-- Environment:
--   BWU_SMOKE_PID   the client pid (default: the first discovered client)
--   BWU_SMOKE_OUT   a file this script writes its results to, one "key=value" per line
-- Raises (bwu_host exits non-zero) on any mismatch.
--
-- `botwithus` comes from package.path: set LUA_PATH to this repo ("<repo>/?.lua;<repo>/?/init.lua;;").

local bot = require("botwithus")
assert(bot.Definitions and bot.WorldMap, "the botwithus on package.path has no definitions/worldmap")
local W = require("botwithus.walk")

local out_path = assert(os.getenv("BWU_SMOKE_OUT"), "BWU_SMOKE_OUT not set")
local pid = math.tointeger(tonumber(os.getenv("BWU_SMOKE_PID") or ""))
local lines = {}

local function note(key, value)
  lines[#lines + 1] = key .. "=" .. tostring(value)
  local f = assert(io.open(out_path, "w"))
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
  print("SMOKE " .. key .. "=" .. tostring(value))
end

local function check(label, cond, detail)
  if not cond then error(label .. ": " .. tostring(detail), 2) end
end

local function steps_text(steps)
  local out = {}
  for i, s in ipairs(steps) do out[i] = string.format("%d@%d,%d", s.kind, s.x, s.y) end
  return table.concat(out, " ")
end

local game = bot.Game.attach(pid)
local me = game:self()
check("in the world", me and me.valid, "no self")
note("abi", bwu.ABI_VERSION)
note("start_tile", string.format("%d,%d,%d", me.tile.x, me.tile.y, me.tile.plane))

-- Backpack names and ops from the cache, and a by-name match.
local pack = game:backpack()
local first
for _, row in ipairs(pack:items()) do
  local d = bot.Definitions.item(row.item_id)
  check("item defined", d ~= nil, row.item_id)
  note("item_" .. row.item_id, string.format("name=%q ops=%s noted=%s qty=%d", d.name,
       table.concat(d.inventory_ops, "|"), tostring(d.noted), row.quantity))
  first = first or d
end
check("an item in the backpack", first ~= nil)
note("count_by_name", first.name .. ":" .. pack:count(first.name))

-- The Lumbridge lodestone in the main world area, by category and tile.
local lode = bot.WorldMap.nearest(3233, 3222, { category = 2613, radius = 3 })
check("Lumbridge lodestone", lode ~= nil and lode.area_id == 28)
note("lumbridge_lodestone", string.format("area=%d element=%d at %d,%d,%d category=%d", lode.area_id,
     lode.element_id, lode.x, lode.y, lode.plane, lode.category))

-- An avoid box over the midpoint of a short walk makes the plan go round (plan only).
local offsets = { { 12, 0 }, { -12, 0 }, { 0, 12 }, { 0, -12 }, { 10, 10 }, { -10, -10 } }
local found = false
for _, o in ipairs(offsets) do
  local gx, gy = me.tile.x + o[1], me.tile.y + o[2]
  local ok, plain = pcall(game.path, game, gx, gy, me.tile.plane)
  if ok and #plain > 0 then
    local box = W.around(me.tile.x + o[1] // 2, me.tile.y + o[2] // 2, 2, me.tile.plane)
    local ok2, around = pcall(game.path, game, gx, gy, me.tile.plane, { avoid = { box } })
    if ok2 and steps_text(around) ~= steps_text(plain) then
      local inside = 0
      for _, s in ipairs(around) do if W.contains(box, s.x, s.y, s.plane) then inside = inside + 1 end end
      note("avoid_goal", gx .. "," .. gy)
      note("avoid_box", string.format("%d,%d-%d,%d p%d", box.min_x, box.min_y, box.max_x, box.max_y, box.plane))
      note("plan_plain", steps_text(plain))
      note("plan_avoid", steps_text(around))
      note("plan_avoid_waypoints_in_box", inside)
      check("no waypoint in the box", inside == 0, inside)
      found = true
      break
    end
  end
end
check("an avoid box that makes the plan detour", found)

-- Route links to Draynor (plan only).
local route = game:path_route(3093, 3244, 0)
note("route_steps", #route.steps)
local links = {}
for i, l in ipairs(route.links) do
  links[i] = string.format("[step %d tx %d kind %d origin %d obj %d -> %d,%d,%d %s %s]", l.step_index,
    l.transition_index, l.kind, l.origin, l.object_id, l.to.x, l.to.y, l.to.plane, l.code, l.name)
end
note("route_links", table.concat(links, " "))
game:detach()
note("result", "ok")
