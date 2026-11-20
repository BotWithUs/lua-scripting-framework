-- botwithus.interact -- names, menu options and option clicks for NPCs, scene objects and ground
-- items (the Java host's Npc / SceneObject / GroundItem getOptions, hasOption and interact).
--
--   local Interact = require("botwithus.interact")
--   local banker = bot.npcs(game):with_option("Bank"):nearest(game:self())
--   if banker then Interact.npc(game, banker, "Bank") end
--   Interact.object(game, booth, "Bank")
--   Interact.options("object", booth)        -- { "Bank", "Collect", ... } from the cache
--
-- Names and options come from the cache definitions (host ABI 7): an NPC by its morph-resolved
-- id (active_type_id; a hidden morph, -1, has no name or options), an object by resolved_id, a
-- ground item by its item's ground ops. Options are matched ignoring case and the click sends
-- the option's 1-based position, as the Java host does. Players have no option list on the wire
-- (no snapshot field or RPC carries the server-set player menu), so there is no player click.

local Definitions = require("botwithus.definitions")

local Interact = {}

-- The action ids per option position (the Java host's ActionTypes NPC_OPTIONS, OBJECT_OPTIONS,
-- GROUND_ITEM_OPTIONS). Position 1 is the left-click option.
Interact.NPC_ACTIONS = { 9, 10, 11, 12, 13, 1003 }
Interact.OBJECT_ACTIONS = { 3, 4, 5, 6, 1001, 1002 }
Interact.GROUND_ITEM_ACTIONS = { 18, 19, 20, 21, 22, 1004 }

-- A definition read that treats "no cache" as no definition, as the Java host's lookups do.
local function def(read, id)
  if id == nil or id < 0 then return nil end
  local ok, d = pcall(read, id)
  if ok then return d end
  return nil
end

local function npc_def(row)
  local id = row.active_type_id
  if id == nil then id = row.type_id end
  return def(Definitions.npc, id)
end

local function object_def(row) return def(Definitions.loc, row.resolved_id or row.id) end
local function item_def(row) return def(Definitions.item, row.item_id) end

-- The display name of a row of `kind` ("npc", "player", "object", "ground_item"), or nil.
function Interact.name(kind, row)
  if kind == "player" then return row.name ~= "" and row.name or nil end
  local d
  if kind == "npc" then d = npc_def(row)
  elseif kind == "object" then d = object_def(row)
  elseif kind == "ground_item" then return Definitions.item_name(row.item_id)
  end
  if d == nil or d.name == nil or d.name == "" or d.name == "null" then return nil end
  return d.name
end

-- The menu options of a row of `kind`, in position order ("" where a position is unset).
function Interact.options(kind, row)
  if kind == "npc" then
    local d = npc_def(row)
    return d and d.ops or {}
  elseif kind == "object" then
    local d = object_def(row)
    return d and d.ops or {}
  elseif kind == "ground_item" then
    local d = item_def(row)
    return d and d.ground_ops or {}
  end
  return {}
end

-- The 1-based position of `option` in the row's options, ignoring case, or nil.
function Interact.option_index(kind, row, option)
  local want = option:lower()
  for i, o in ipairs(Interact.options(kind, row)) do
    if o ~= "" and o:lower() == want then return i end
  end
  return nil
end

function Interact.has_option(kind, row, option)
  return Interact.option_index(kind, row, option) ~= nil
end

-- The action a click on option position `index` of a row of `kind` sends, or nil.
function Interact.action(kind, row, index)
  if kind == "npc" then
    local id = Interact.NPC_ACTIONS[index]
    return id and { id = id, p1 = row.server_index, p2 = 0, p3 = 0 }
  elseif kind == "object" then
    local id = Interact.OBJECT_ACTIONS[index]
    return id and { id = id, p1 = row.id, p2 = row.tile.x, p3 = row.tile.y }
  elseif kind == "ground_item" then
    local id = Interact.GROUND_ITEM_ACTIONS[index]
    return id and { id = id, p1 = row.item_id, p2 = row.tile.x, p3 = row.tile.y }
  end
  return nil
end

-- Click `option` on a row of `kind`. False (nothing sent) when the row has no such option.
function Interact.row(game, kind, row, option)
  local index = Interact.option_index(kind, row, option)
  if index == nil then return false end
  local action = Interact.action(kind, row, index)
  if action == nil then return false end
  game:do_action(action)
  return true
end

function Interact.npc(game, row, option) return Interact.row(game, "npc", row, option) end
function Interact.object(game, row, option) return Interact.row(game, "object", row, option) end
function Interact.ground_item(game, row, option) return Interact.row(game, "ground_item", row, option) end

return Interact
