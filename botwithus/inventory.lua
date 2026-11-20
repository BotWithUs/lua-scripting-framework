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
--
-- The bank is published only while the bank interface is open, so a missing bank is not an
-- empty one: check :is_present() before trusting :is_empty() or :count() on it.

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

-- The predicate a matcher stands for. Raises on anything else, so a typo is not a silent miss.
local function matcher(match)
  local kind = type(match)
  if kind == "function" then return match end
  if math.type(match) == "integer" then return function(row) return row.item_id == match end end
  if kind == "table" then
    local set = {}
    for _, id in ipairs(match) do set[id] = true end
    return function(row) return set[row.item_id] == true end
  end
  error("botwithus: an inventory matcher is an item id, a list of ids or a function, not "
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

function Inventory:free_slots() return self:size() - #self:items() end

-- Not published reads as neither empty nor full: there is nothing to say either way.
function Inventory:is_empty() return self:is_present() and #self:items() == 0 end
function Inventory:is_full() return self:size() > 0 and self:free_slots() == 0 end

return Inventory
