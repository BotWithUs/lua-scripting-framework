-- botwithus.inventory -- views over one published inventory.
--
--   local bp = game:backpack()
--   if bp:contains(1511) then ... end
--   local coins = bp:count(995)
--   local axe   = game:equipment():find({ 1351, 1349, 1353 })
--
-- A view is a copy taken when game:inventory(id) was called: read it again after a refresh.
-- Slots are 0-based, as the game numbers them. An empty slot has item_id -1. Matchers:
--   an item id                      1511
--   a list of ids (any of them)     { 1511, 1521 }
--   a predicate over a slot row     function(row) return row.quantity > 10 end
--   an item name                    "logs"  (case-insensitive substring, names from the cache)
--
-- Item names: neither the snapshot nor any agent RPC carries one, so a name match resolves each
-- id through a `names` function (item id -> name or nil). It defaults to the cache's item names
-- (botwithus.definitions.item_name, host ABI 7), where a noted item reads as its unnoted item, as
-- the game shows it. The *_named methods take your own as a second argument.
--
-- The bank is published only while the bank interface is open, so a missing bank is not an
-- empty one: check :is_present() before trusting :is_empty() or :count() on it.

local Definitions = require("botwithus.definitions")
local Match = require("botwithus.match")
local Actions = require("botwithus.actions")

local Inventory = {}
Inventory.__index = Inventory

-- The game's own inventory ids (bwu.INV_* on the native surface).
Inventory.BACKPACK  = 93
Inventory.EQUIPMENT = 94
Inventory.BANK      = 95

-- The slot grid each inventory is clicked through: { iface, comp } (Java Backpack, Equipment and
-- Bank). An inventory with no grid here can be read but not clicked.
Inventory.GRIDS = {
  [93] = { iface = 1473, comp = 5 },     -- the backpack window
  [94] = { iface = 1464, comp = 15 },    -- the worn-equipment window
  [95] = { iface = 517, comp = 201 },    -- BANK__BANK_INV
}

-- The beast-of-burden inventory (LORE_BOB). Not 671: the gameval index names 671
-- WORN_DISPLAY_PREVIEW.
Inventory.FAMILIAR = 530
-- The area-loot window's inventory (LOOT).
Inventory.LOOT = 773

-- The option the client selects an item for use-on with. It is never one of a component's ops,
-- so it is looked up in the cache's inventory ops instead of the live menu.
Inventory.USE = "Use"

-- A view of inventory `inv_id` from its slot rows, or of an inventory that was not published
-- (rows == nil). `game` (optional) lets the view click its slots, through Inventory.GRIDS.
function Inventory.new(inv_id, rows, game)
  return setmetatable({ _id = inv_id, _rows = rows, _game = game }, Inventory)
end

local function is_item(row) return row.item_id >= 0 end

-- A predicate matching slots whose item name contains `name`, case-insensitively.
local function name_matcher(name, names)
  if type(name) ~= "string" or not name:find("%S") then
    error("botwithus: an item name must be a non-empty string", 4)
  end
  names = names or Definitions.item_name
  if type(names) ~= "function" then
    error("botwithus: names must be a function from item id to name (or nil for the cache's)", 4)
  end
  local needle = name:match("^%s*(.-)%s*$"):lower()
  return function(row)
    local item_name = names(row.item_id)
    return item_name ~= nil and item_name:lower():find(needle, 1, true) ~= nil
  end
end

-- The predicate a matcher stands for. Raises on anything else, so a typo is not a silent miss.
local function matcher(match)
  local kind = type(match)
  if kind == "function" then return match end
  if kind == "string" then return name_matcher(match, nil) end
  if math.type(match) == "integer" then return function(row) return row.item_id == match end end
  if kind == "table" then
    local set = {}
    for _, id in ipairs(match) do set[id] = true end
    return function(row) return set[row.item_id] == true end
  end
  error("botwithus: an inventory matcher is an item id, a list of ids, a name or a function, not "
    .. kind, 3)
end

function Inventory:id() return self._id end

-- Whether the agent published this inventory this frame.
function Inventory:is_present() return self._rows ~= nil end

-- Every slot, empty ones included ({} when not published).
function Inventory:slots() return self._rows or {} end

-- The inventory's size in slots (0 when not published).
function Inventory:size() return #self:slots() end

-- The slot row at 0-based `slot`, or nil.
function Inventory:slot(slot) return self:slots()[slot + 1] end

-- The occupied slots, in slot order.
function Inventory:items()
  local out = {}
  for _, row in ipairs(self:slots()) do
    if is_item(row) then out[#out + 1] = row end
  end
  return out
end

-- Every occupied slot the matcher accepts.
function Inventory:find_all(match)
  local accept, out = matcher(match), {}
  for _, row in ipairs(self:items()) do
    if accept(row) then out[#out + 1] = row end
  end
  return out
end

-- The first occupied slot the matcher accepts, or nil.
function Inventory:find(match) return self:find_all(match)[1] end

function Inventory:contains(match) return self:find(match) ~= nil end

-- The total quantity across every matching slot (stacks summed).
function Inventory:count(match)
  local total = 0
  for _, row in ipairs(self:find_all(match)) do total = total + row.quantity end
  return total
end

-- By item name with an explicit resolver (`names` nil: the cache's item names).
function Inventory:find_all_named(name, names) return self:find_all(name_matcher(name, names)) end
function Inventory:find_named(name, names) return self:find_all_named(name, names)[1] end
function Inventory:contains_named(name, names) return self:find_named(name, names) ~= nil end
function Inventory:count_named(name, names) return self:count(name_matcher(name, names)) end

function Inventory:free_slots() return self:size() - #self:items() end

-- Not published reads as neither empty nor full: there is nothing to say either way.
function Inventory:is_empty() return self:is_present() and #self:items() == 0 end
function Inventory:is_full() return self:size() > 0 and self:free_slots() == 0 end

-- Exact names, patterns, categories (the Java host's InventoryContainer) ----------------------
--
-- Every name-taking method below matches the WHOLE display name (see botwithus.match): these
-- decide what to click, and with a substring "Logs" would click Oak logs.

-- The first item whose whole name is `name`, ignoring case, or nil.
function Inventory:find_exact(name) return self:find(Match.exact(name)) end

-- Whether every one of `...` (whole names) is present.
function Inventory:contains_all_of(...)
  for _, name in ipairs({ ... }) do
    if self:find_exact(name) == nil then return false end
  end
  return true
end

-- Whether any of `...` (whole names) is present.
function Inventory:contains_any_of(...) return self:find(Match.exact(...)) ~= nil end

-- Whether anything other than `...` is present: item ids, or whole names when the first is a
-- string.
function Inventory:contains_any_except(...)
  local first = ...
  local keep = type(first) == "string" and Match.exact(...) or Match.ids(...)
  return self:find(Match.negate(keep)) ~= nil
end

function Inventory:contains_category(category) return self:find(Match.category(category)) ~= nil end
function Inventory:find_all_in_category(category) return self:find_all(Match.category(category)) end

-- The items whose cache inventory ops include `option` (ignoring case).
function Inventory:items_with_option(option) return self:find_all(Match.option(option)) end

-- Clicking ------------------------------------------------------------------------------------

local function grid_of(self)
  local grid = Inventory.GRIDS[self._id]
  if self._game == nil or grid == nil then
    error("botwithus: inventory " .. tostring(self._id) .. " cannot be clicked from this view", 3)
  end
  return grid
end

-- Click option index `op` (1-based, as the COMPONENT action takes it) on 0-based `slot`. False
-- for a slot outside the inventory.
function Inventory:interact_slot(slot, op)
  local grid = grid_of(self)
  if slot < 0 or slot >= self:size() then return false end
  self._game:do_action(Actions.component_click(grid.iface, grid.comp, op, slot))
  return true
end

-- The op the live menu lists as `option` on this slot (ignoring case), or nil.
function Inventory:_live_op(row, option)
  local grid = grid_of(self)
  local reply = self._game:component_ops(grid.iface, grid.comp, row.slot)
  for _, op in ipairs(reply and reply.ops or {}) do
    if op.name:lower() == option:lower() then return op.op end
  end
  return nil
end

-- "Use" through the cache's inventory ops: its position there is the op to send.
local function cache_op(row, option)
  local ok, def = pcall(Definitions.item, row.item_id)
  for i, op in ipairs(ok and def and def.inventory_ops or {}) do
    if op:lower() == option:lower() then return i end
  end
  return nil
end

-- Click `option` on the first item `target` matches. `target` is an item id, an EXACT whole name,
-- a list of either, or a matcher (botwithus.match). The op is the one the client's live menu
-- lists under that name (one component_ops round trip), never a position in the cache's list:
-- the client's own Drop is not in that list. "Use" is the exception (see Inventory.USE). False
-- when no item matches or its menu has no such option; nothing is sent then.
function Inventory:interact(target, option)
  local row = self:find(Match.target(target))
  if row == nil then return false end
  local op
  if option:lower() == Inventory.USE:lower() then op = cache_op(row, option)
  else op = self:_live_op(row, option) end
  if op == nil then return false end
  return self:interact_slot(row.slot, op)
end

-- Select the first item `target` matches for use-on (its "Use" op).
function Inventory:use(target) return self:interact(target, Inventory.USE) end

return Inventory
