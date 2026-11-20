-- spec/n2_spec.lua -- host ABI 7: cache definitions, world map elements, the inventory's
-- by-name matching from the cache, avoid areas and route links, over the fake bwu surface
-- (spec/fake_bwu.lua install_abi7).
--
-- Every expected value differs from a zeroed default. Each test names what would fail it.

local fake_bwu = require("spec.fake_bwu")
local bot      = require("botwithus")
local W        = require("botwithus.walk")
local Defs     = require("botwithus.definitions")
local WorldMap = require("botwithus.worldmap")

local T = {}

local function attach(opts)
  _G.bwu = fake_bwu.new(opts)
  Defs.clear_item_names()
  return bot.Game.attach(4242)
end

local function raises(fn, fragment)
  local ok, err = pcall(fn)
  return not ok and tostring(err):find(fragment, 1, true) ~= nil, tostring(err)
end

-- Definitions ---------------------------------------------------------------------------------

-- Failure: a field read from the wrong key, or nil where the cache has the item.
T["definitions: typed item, npc, loc"] = function(assert_)
  attach()
  local whip = Defs.item(4151)
  assert_(whip.name == "Abyssal whip" and whip.members and whip.noted_id == 4152 and whip.wearpos2 == 5, "whip")
  assert_(whip.inventory_ops[2] == "Wield", "op 2")
  local note = Defs.item(1512)
  assert_(note.noted and note.stackable and note.name == "Logs", "the note reads as its item")
  assert_(Defs.npc(2001).ops[3] == "Attack" and Defs.npc(2001).varbit_id == 555, "npc")
  assert_(Defs.loc(3001).map_sprite_id == 17 and Defs.loc(3001).size_y == 3, "loc")
  assert_(Defs.item(999) == nil and Defs.npc(1) == nil and Defs.loc(1) == nil, "missing ids are nil")
  assert_(bot.Definitions == Defs and Defs.available(), "exported, available")
end

T["definitions: params, int_param and the JSON tail"] = function(assert_)
  attach()
  local p = Defs.params(Defs.CACHE_ITEM, 4151)
  assert_(#p == 2 and p[1].param_id == 14 and p[1].value == 4, "int param")
  assert_(p[2].text == "Whip" and p[2].text_truncated == true, "string param")
  assert_(Defs.int_param(Defs.CACHE_ITEM, 4151, 14) == 4, "int_param")
  assert_(Defs.int_param(Defs.CACHE_ITEM, 4151, 555) == nil, "a string param is not an int")
  assert_(Defs.json(Defs.CACHE_ENUM, 5001):find('"entries"', 1, true) ~= nil, "json")
  assert_(Defs.json(Defs.CACHE_ENUM, 1) == nil, "missing json is nil")
  assert_(Defs.CACHE_QUEST == 8 and Defs.CACHE_WORLDMAP == 9, "constants")
end

-- Failure: a host error swallowed as nil (a missing cache would read as "no such item").
T["definitions: no cache raises with the host's reason"] = function(assert_)
  attach({ no_cache = true })
  local ok, err = raises(function() Defs.item(4151) end, "NXTCache.dll not found")
  assert_(ok, err)
  assert_(Defs.available() == false, "not available")
end

T["definitions: an ABI 6 host says it predates them"] = function(assert_)
  attach({ abi = 6 })
  local ok, err = raises(function() Defs.item(4151) end, "native ABI 7")
  assert_(ok, err)
  assert_(Defs.available() == false, "not available")
end

-- Failure: every call reading the cache again (a loop over a backpack would hit it 28x per frame).
T["definitions: item names are kept on this side"] = function(assert_)
  attach()
  assert_(Defs.item_name(4151) == "Abyssal whip" and Defs.item_name(4151) == "Abyssal whip", "name")
  assert_(Defs.item_name(-1) == nil and Defs.item_name(999) == nil, "empty slot, unknown id")
  assert_(Defs.item_name(999) == nil, "unknown id again")
  -- 4151 once, 999 once (an unknown id is kept too), -1 never.
  assert_(_G.bwu._abi7.item_reads == 2, "reads: " .. _G.bwu._abi7.item_reads)
  Defs.clear_item_names()
end

-- Inventory by name -----------------------------------------------------------------------------

-- Failure: names not resolved through the cache by default, a note not matching its item's name,
-- or a caller's resolver ignored.
T["inventory: matches item names from the cache by default"] = function(assert_)
  local game = attach({ inventories = { [93] = { { item_id = 1511, quantity = 3 },
                                                  { item_id = 1512, quantity = 40 },
                                                  { item_id = 4151, quantity = 1 },
                                                  { item_id = -1, quantity = 0 } } } })
  local pack = game:backpack()
  assert_(pack:count("logs") == 43, "logs and noted logs: " .. pack:count("logs"))
  assert_(pack:contains("WHIP") and not pack:contains("rune"), "case-insensitive")
  assert_(pack:count_named("logs") == 43 and pack:find_named("whip").item_id == 4151, "named")
  local mine = function(id) return id == 4151 and "Oak logs" or nil end
  assert_(pack:count_named("logs", mine) == 1, "a caller's resolver wins")
  local ok, err = raises(function() pack:count("") end, "non-empty")
  assert_(ok, err)
end

-- World map -------------------------------------------------------------------------------------

-- Failure: an area other than 28 by default, area_id dropped, a filter that misses the tooltip.
T["worldmap: the main area by default, filters, nearest"] = function(assert_)
  attach()
  local main = WorldMap.elements()
  assert_(#main == 4 and main[1].area_id == 28 and main[2].x == 4576, "area 28, Prifddinas drawn")
  assert_(_G.bwu._abi7.calls[1][2] == 28, "asked for area 28")
  local prif = WorldMap.elements(231)
  assert_(#prif == 1 and prif[1].x == 2208 and prif[1].y == 3361, "Prifddinas at its real tile")
  assert_(#WorldMap.elements(WorldMap.ALL_AREAS) == 5, "every area")
  assert_(WorldMap.elements(nil, { name = "lumbridge" })[1].element_id == 10, "tooltip match")
  local near = WorldMap.elements(nil, { near = { x = 3235, y = 3225 }, radius = 10 })
  assert_(#near == 2 and near[1].element_id == 3612 and near[2].element_id == 9, "nearest first")
  assert_(WorldMap.nearest(3235, 3225, { category = 2613 }).element_id == 3612, "nearest")
  local ok, err = raises(function() WorldMap.elements(99) end, "not_found")
  assert_(ok, err)
end

-- Avoid areas and route links ---------------------------------------------------------------------

-- Failure: an area built with the wrong bounds, or a bad one accepted.
T["walk: area constructors"] = function(assert_)
  local a = W.around(3205, 3206, 2, 0)
  assert_(a.min_x == 3203 and a.max_y == 3208 and a.plane == 0, "around")
  local b = W.box(30, 40, 10, 20)
  assert_(b.min_x == 10 and b.max_x == 30 and b.plane == W.AREA_ALL_PLANES, "box")
  assert_(W.contains(a, 3204, 3207, 0) and not W.contains(a, 3204, 3207, 1), "contains")
  assert_(raises(function() W.area(5, 0, 4, 1) end, "min <= max"), "min > max refused")
  assert_(raises(function() W.area(0, 0, 1, 1, 4) end, "plane"), "plane 4 refused")
  assert_(W.MAX_AVOID == 64, "max")
end

-- Failure: the avoid table not reaching the host, or an empty one changing the call shape.
T["walk: avoid reaches the host; an empty list keeps the old call"] = function(assert_)
  local game = attach()
  local door = W.area(3204, 3205, 3206, 3207, 0)
  game:walk(9002, 0, 0, 1, { avoid = { door } })
  local o = _G.bwu._state.walks[#_G.bwu._state.walks].opts
  assert_(o ~= nil and o.avoid[1] == door, "avoid passed")
  game:walk(9001, 0, 0, 1, { avoid = {} })
  assert_(_G.bwu._state.walks[#_G.bwu._state.walks].opts == nil, "empty avoid: no options table")
  assert_(game:has_avoid(), "has_avoid")
end

-- Failure: avoid areas silently dropped on a host or walker that cannot honour them.
T["walk: avoid is refused, never ignored"] = function(assert_)
  local game = attach({ cannot_avoid = true })
  local ok, err = raises(function() game:walk_ex(9002, 0, 0, 1, { avoid = { W.area(1, 1, 2, 2) } }) end,
                         "cannot avoid areas")
  assert_(ok, err)
  ok, err = raises(function() game:path_route(9014, 0, 0) end, "cannot list route links")
  assert_(ok, err)
  game = attach({ abi = 6 })
  ok, err = raises(function() game:path(9002, 0, 0, { avoid = { W.area(1, 1, 2, 2) } }) end, "native ABI 7")
  assert_(ok, err)
  ok, err = raises(function() game:path_route(9014, 0, 0) end, "path_route")
  assert_(ok, err)
  assert_(game:has_avoid() == false, "has_avoid false on ABI 6")
end

-- Failure: steps and links not handed through, or a teleport not found by origin.
T["walk: path_route returns steps and links"] = function(assert_)
  local game = attach()
  local route = game:path_route(9014, 0, 0, { avoid = { W.area(1, 1, 2, 2, 3) } })
  assert_(#route.steps == 3 and route.steps[3].x == 2801, "steps")
  assert_(route.links[1].name == "Lumbridge lodestone" and route.links[1].to.x == 3233, "lodestone")
  assert_(route.links[2].code == "CKS" and route.links[2].object_id == 12128, "fairy ring")
  local tps = W.teleports(route)
  assert_(#tps == 1 and tps[1].transition_index == 300, "teleports")
  local call = _G.bwu._abi7.calls[#_G.bwu._abi7.calls]
  assert_(call[1] == "path_route" and call[5].avoid[1].plane == 3, "options passed")
end

return T
