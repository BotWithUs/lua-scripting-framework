-- botwithus.deposit_box -- the bank deposit box (the Java host's inventory.DepositBox).
--
--   local DepositBox = require("botwithus.deposit_box")
--   local box = DepositBox.new(game)
--   if not box:is_open() then box:open() end
--   box:deposit_all_except({ "Small fishing net" })
--
-- The buttons are found by their live menu option ("Deposit Carried Items", "Deposit Worn Items",
-- "Deposit Familiar's Items", "Deposit Money Pouch", "Close") and pressed through it, so a wrong
-- name returns false rather than clicking something else. The option names are xapi's and have
-- not been checked live. deposit_all_except presses each backpack slot's "Deposit-All" once per
-- distinct item. A `target` is as for botwithus.bank (an exact name, ids, or a matcher).

local Match = require("botwithus.match")
local G = require("botwithus.gameval")
local Actions = require("botwithus.actions")
local CQ = require("botwithus.component_query")
local Interact = require("botwithus.interact")
local Entities = require("botwithus.entities")

local DepositBox = {}
DepositBox.__index = DepositBox

DepositBox.INTERFACE = 11            -- BANK_DEPOSIT_BOX
local BACKPACK_GRID = 19             -- BANK_DEPOSIT_BOX__ICONS
-- By gameval name (host ABI 8); the number is the fallback when the name does not resolve.
local INTERFACE_REF = G.ref("interface", "BANK_DEPOSIT_BOX", DepositBox.INTERFACE)
local GRID_REF = G.component_ref("BANK_DEPOSIT_BOX__ICONS", DepositBox.INTERFACE, BACKPACK_GRID)
DepositBox.OPEN = "Deposit"
DepositBox.DEPOSIT_CARRIED = "Deposit Carried Items"
DepositBox.DEPOSIT_WORN = "Deposit Worn Items"
DepositBox.DEPOSIT_FAMILIAR = "Deposit Familiar's Items"
DepositBox.DEPOSIT_POUCH = "Deposit Money Pouch"
DepositBox.CLOSE = "Close"
DepositBox.DEPOSIT_ALL = "Deposit-All"

function DepositBox.new(game) return setmetatable({ _game = game }, DepositBox) end

function DepositBox:is_open() return self._game:is_interface_open(INTERFACE_REF:id()) end

-- "Deposit" on the nearest object offering it.
function DepositBox:open()
  local game = self._game
  local box = Entities.objects(game):with_option(DepositBox.OPEN):nearest(game:self().tile)
  return box ~= nil and Interact.object(game, box, DepositBox.OPEN)
end

function DepositBox:_press(option)
  if not self:is_open() then return false end
  local button = CQ.new(self._game, INTERFACE_REF:id()):with_option(option):first()
  return button ~= nil and CQ.interact(self._game, button, option)
end

function DepositBox:close() return self:_press(DepositBox.CLOSE) end
function DepositBox:deposit_all() return self:_press(DepositBox.DEPOSIT_CARRIED) end
function DepositBox:deposit_worn() return self:_press(DepositBox.DEPOSIT_WORN) end
function DepositBox:deposit_familiar() return self:_press(DepositBox.DEPOSIT_FAMILIAR) end
function DepositBox:deposit_money_pouch() return self:_press(DepositBox.DEPOSIT_POUCH) end

function DepositBox:_deposit_slot(row)
  local iface, grid = GRID_REF:component()
  local reply = self._game:component_ops(iface, grid, row.slot)
  local op = type(reply) == "table" and CQ.op_named({ ops = reply.ops or {} }, DepositBox.DEPOSIT_ALL)
  if not op then return false end
  self._game:do_action(Actions.component_click(iface, grid, op, row.slot))
  return true
end

-- Deposit-All of every backpack item `target` does NOT match. True only when every press was
-- queued.
function DepositBox:deposit_all_except(target)
  if not self:is_open() then return false end
  local keep = Match.target(target)
  local queued, all = {}, true
  for _, row in ipairs(self._game:backpack():find_all(Match.negate(keep))) do
    if not queued[row.item_id] then
      queued[row.item_id] = true
      all = self:_deposit_slot(row) and all
    end
  end
  return all
end

return DepositBox
