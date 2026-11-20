-- botwithus.loot -- the area-loot window (the Java host's inventory.LootInventory).
--
--   local Loot = require("botwithus.loot")
--   local loot = Loot.new(game)
--   if loot:is_area_loot_enabled() and not loot:is_open() then loot:open() end
--   loot:take("Bones")            -- or loot:loot_all()
--
-- The window's items are inventory 773 (LOOT); its buttons are found and pressed by their live
-- option ("Take", "Loot All", "Close", xapi's names), so a wrong name returns false rather than
-- clicking something else. open() takes the nearest ground item, which opens the window only
-- while Area Loot is on.

local Inventory = require("botwithus.inventory")
local G = require("botwithus.gameval")
local CQ = require("botwithus.component_query")
local Interact = require("botwithus.interact")
local Entities = require("botwithus.entities")

local Loot = {}
Loot.__index = Loot

Loot.INTERFACE = 1622          -- TOPLEVEL_V2_LOOT
-- By gameval name (host ABI 8); the number is the fallback when the name does not resolve.
local INTERFACE_REF = G.ref("interface", "TOPLEVEL_V2_LOOT", Loot.INTERFACE)
local AREA_LOOT = G.ref("varbit", "LOOT_BY_AREA", 27943)
local ENABLED = 1
Loot.TAKE = "Take"
Loot.LOOT_ALL = "Loot All"
Loot.CLOSE = "Close"

function Loot.new(game) return setmetatable({ _game = game }, Loot) end

-- The window's inventory view (773).
function Loot:items() return self._game:inventory(Inventory.LOOT) end
function Loot:contents() return self:items():items() end

function Loot:is_open() return self._game:is_interface_open(INTERFACE_REF:id()) end
function Loot:is_area_loot_enabled() return self._game:varbit(AREA_LOOT:id()) == ENABLED end

function Loot:open()
  if not self:is_area_loot_enabled() then return false end
  local game = self._game
  local nearest = Entities.ground_items(game):nearest(game:self().tile)
  return nearest ~= nil and Interact.ground_item(game, nearest, Loot.TAKE)
end

function Loot:_press(option)
  if not self:is_open() then return false end
  local button = CQ.new(self._game, INTERFACE_REF:id()):with_option(option):first()
  return button ~= nil and CQ.interact(self._game, button, option)
end

function Loot:close() return self:_press(Loot.CLOSE) end
function Loot:loot_all() return self:_press(Loot.LOOT_ALL) end

-- "Take" on the window's slot holding `target`: an item id, or a name (a case-insensitive
-- substring, as the Java host's take(String) matches).
function Loot:take(target)
  if not self:is_open() then return false end
  local id = target
  if type(target) == "string" then
    local row = self:items():find(target)
    if row == nil then return false end
    id = row.item_id
  end
  local slot = CQ.new(self._game, INTERFACE_REF:id()):with_item_id(id):with_option(Loot.TAKE):first()
  return slot ~= nil and CQ.interact(self._game, slot, Loot.TAKE)
end

return Loot
