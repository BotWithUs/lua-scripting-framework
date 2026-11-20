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

local Inventory = {}
Inventory.__index = Inventory

-- The game's own inventory ids (bwu.INV_* on the native surface).
Inventory.BACKPACK  = 93
Inventory.EQUIPMENT = 94
Inventory.BANK      = 95

-- A view of inventory `inv_id` from its slot rows, or of an inventory that was not published
-- (rows == nil).
function Inventory.new(inv_id, rows)
  return setmetatable({ _id = inv_id, _rows = rows }, Inventory)
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

return Inventory
