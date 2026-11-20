-- botwithus.bank -- the bank: open it, deposit and withdraw by id, exact name or pattern,
-- presets, and the withdraw / transfer modes (the Java host's inventory.Bank).
--
--   local Bank = require("botwithus.bank")
--   local Match = require("botwithus.match")
--   local bank = Bank.new(game)
--   if not bank:is_open() then bank:open() end            -- a booth or chest, else a banker
--   bank:deposit_all_except({ "Coins", "Small fishing net" })
--   bank:withdraw("Logs", Bank.ALL)                       -- "Logs" exactly, never Oak logs
--   bank:set_withdraw_mode(Bank.NOTE)
--
-- A `target` is an item id, an EXACT whole name (ignoring case), a list of either, or a matcher
-- from botwithus.match (Match.pattern("Raw %a+") for a pattern). Every click is one queued
-- COMPONENT action, sent only while the bank is open; each method returns false and sends
-- nothing when the bank is closed or nothing matches. Returning true means queued, not done:
-- wait for the inventory to change (ctx:delay_until) before relying on it.

local Inventory = require("botwithus.inventory")
local Match = require("botwithus.match")
local Actions = require("botwithus.actions")
local Input = require("botwithus.input")
local Interact = require("botwithus.interact")
local Entities = require("botwithus.entities")

local Bank = {}
Bank.__index = Bank

Bank.INTERFACE = 517          -- BANK
Bank.INPUT_INTERFACE = 1469   -- MESLAYER, the amount prompt
local ITEMS = 201             -- BANK__BANK_INV
local BACKPACK_ITEMS = 15     -- BANK__INVENTORY_CLICK
local CLOSE_BUTTON = 317      -- BANK__CLOSE_BUTTON_LAYER
local DEPOSIT_BACKPACK = 39   -- BANK__BANK_INV_BUTTON
local DEPOSIT_WORN = 42       -- BANK__BANK_WORN_BUTTON
local DEPOSIT_FAMILIAR = 45   -- BANK__BANK_BOB_BUTTON
local DEPOSIT_POUCH = 48      -- BANK__BANK_POUCH_BUTTON
local PRESET_BUTTONS = 119    -- BANK__SHARE_QUICK_CLICK
local NOTE_MODE_BUTTON = 127  -- BANK__BANK_CERT_BUTTON

local VARBIT_TRANSFER_MODE = 45189  -- BANK_CUSTOMOP
local VARBIT_SIDE_VIEW = 45139      -- BANK_CURRENT_INV
local VARBIT_SIDE_TAB = 45191       -- BANK_SIDE_TAB_SELECTED
local VARBIT_PRESET_PAGE = 49662    -- SHARE_PRESET_BANK_BUTTON_PAGE
local VARP_WITHDRAW_AMOUNT = 111    -- BANK_MOVE_X
local VARP_WITHDRAW_AS_NOTE = 160   -- BANKCERT

local OP_CLICK = 1
local OP_ENTER_AMOUNT = 6
local MAX_PRESET = 18
local PRESETS_PER_PAGE = 9
local PRESET_PAGE_SWITCH_SUB = 100
local SIDE_VIEW_BACKPACK, SIDE_VIEW_EQUIPMENT = 0, 2
local SIDE_TAB_PRESETS = 1
local WITHDRAW_AS_NOTE = 1

Bank.OPEN_RADIUS = 10
Bank.BANK_OPTION = "Bank"
Bank.USE_OPTION = "Use"
Bank.LOAD_LAST_PRESET_OPTION = "Load Last Preset from"

-- Transfer amounts: the BANK_CUSTOMOP value and the item menu op that moves that many.
Bank.ONE    = { name = "one", varbit = 2, op = 2, button = 93 }     -- BANK__DEFAULT_OP_1
Bank.FIVE   = { name = "five", varbit = 3, op = 3, button = 96 }    -- BANK__DEFAULT_OP_5
Bank.TEN    = { name = "ten", varbit = 4, op = 4, button = 99 }     -- BANK__DEFAULT_OP_10
Bank.ALL    = { name = "all", varbit = 7, op = 7, button = 103 }    -- BANK__DEFAULT_OP_ALL_BUTTON
Bank.CUSTOM = { name = "custom", varbit = 5, op = 5, button = 106 } -- BANK__DEFAULT_OP_X
local AMOUNTS = { Bank.ONE, Bank.FIVE, Bank.TEN, Bank.ALL, Bank.CUSTOM }

Bank.ITEM, Bank.NOTE = "item", "note"
Bank.BACKPACK, Bank.EQUIPMENT, Bank.FAMILIAR = "backpack", "equipment", "familiar"
Bank.TRANSFER, Bank.PRESETS = "transfer", "presets"

function Bank.new(game) return setmetatable({ _game = game }, Bank) end

function Bank:is_open() return self._game:is_interface_open(Bank.INTERFACE) end
function Bank:is_input_open() return self._game:is_interface_open(Bank.INPUT_INTERFACE) end

-- The bank's own inventory view (botwithus.inventory); not present while the bank is closed.
function Bank:items() return self._game:bank() end

function Bank:withdraw_amount() return self._game:varp(VARP_WITHDRAW_AMOUNT) end
function Bank:preset_page() return self._game:varbit(VARBIT_PRESET_PAGE) end

function Bank:view()
  local v = self._game:varbit(VARBIT_SIDE_VIEW)
  if v == SIDE_VIEW_BACKPACK then return Bank.BACKPACK end
  return v == SIDE_VIEW_EQUIPMENT and Bank.EQUIPMENT or Bank.FAMILIAR
end

function Bank:withdraw_mode()
  return self._game:varp(VARP_WITHDRAW_AS_NOTE) == WITHDRAW_AS_NOTE and Bank.NOTE or Bank.ITEM
end

function Bank:setting()
  return self._game:varbit(VARBIT_SIDE_TAB) == SIDE_TAB_PRESETS and Bank.PRESETS or Bank.TRANSFER
end

function Bank:transfer_mode()
  local v = self._game:varbit(VARBIT_TRANSFER_MODE)
  for _, a in ipairs(AMOUNTS) do
    if a.varbit == v then return a end
  end
  return Bank.ONE
end

-- Clicks ------------------------------------------------------------------------------------

function Bank:_button(comp, sub)
  self._game:do_action(Actions.component_click(Bank.INTERFACE, comp, OP_CLICK, sub or -1))
  return true
end

function Bank:_click_when_open(comp)
  if not self:is_open() then return false end
  return self:_button(comp)
end

function Bank:_slot(grid, row, op)
  if row == nil then return false end
  self._game:do_action(Actions.component_click(Bank.INTERFACE, grid, op, row.slot))
  return true
end

-- Opens the nearest booth or chest within OPEN_RADIUS offering "Bank" (or "Use"), else the
-- nearest banker NPC offering "Bank". True when already open or a click was queued.
function Bank:open()
  if self:is_open() then return true end
  local game = self._game
  local me = game:self()
  local booth = Entities.objects(game):within(me.tile, Bank.OPEN_RADIUS):where(function(o)
    return Interact.has_option("object", o, Bank.BANK_OPTION)
      or Interact.has_option("object", o, Bank.USE_OPTION)
  end):nearest(me.tile)
  if booth then
    return Interact.object(game, booth, Bank.BANK_OPTION)
      or Interact.object(game, booth, Bank.USE_OPTION)
  end
  local banker = Entities.npcs(game):within(me.tile, Bank.OPEN_RADIUS)
    :with_option(Bank.BANK_OPTION):nearest(me.tile)
  return banker ~= nil and Interact.npc(game, banker, Bank.BANK_OPTION)
end

function Bank:close()
  if not self:is_open() then return true end
  return self:_button(CLOSE_BUTTON)
end

-- The deposit buttons. deposit_all() with no target is "deposit carried items".
function Bank:deposit_backpack() return self:_click_when_open(DEPOSIT_BACKPACK) end
function Bank:deposit_equipment() return self:_click_when_open(DEPOSIT_WORN) end
function Bank:deposit_familiar() return self:_click_when_open(DEPOSIT_FAMILIAR) end
function Bank:deposit_coins() return self:_click_when_open(DEPOSIT_POUCH) end

function Bank:deposit_everything()
  local any = self:deposit_backpack()
  any = self:deposit_equipment() or any
  any = self:deposit_familiar() or any
  return self:deposit_coins() or any
end

-- One Deposit-All per distinct item the matcher picks from the backpack (a second stack of the
-- same item is never clicked twice).
function Bank:_deposit_all_matching(accept)
  if not self:is_open() then return false end
  local queued = {}
  for _, row in ipairs(self._game:backpack():find_all(accept)) do
    if not queued[row.item_id] then
      queued[row.item_id] = true
      self:_slot(BACKPACK_ITEMS, row, Bank.ALL.op)
    end
  end
  return true
end

-- With a target: Deposit-All of every backpack item it matches. Without: the deposit-carried
-- button.
function Bank:deposit_all(target)
  if target == nil then return self:deposit_backpack() end
  return self:_deposit_all_matching(Match.target(target))
end

-- Deposit-All of every backpack item the target does NOT match.
function Bank:deposit_all_except(target)
  return self:_deposit_all_matching(Match.negate(Match.target(target)))
end

-- Deposit `amount` (Bank.ONE ... Bank.ALL) of the first backpack item the target matches.
function Bank:deposit(target, amount)
  if not self:is_open() then return false end
  return self:_slot(BACKPACK_ITEMS, self._game:backpack():find(Match.target(target)), (amount or Bank.ONE).op)
end

-- Withdraw `amount` of the first bank item the target matches.
function Bank:withdraw(target, amount)
  if not self:is_open() then return false end
  return self:_slot(ITEMS, self._game:bank():find(Match.target(target)), (amount or Bank.ONE).op)
end

function Bank:withdraw_all(target) return self:withdraw(target, Bank.ALL) end

-- Opens the amount prompt for a deposit / withdraw of X; finish with :finish_transfer_x(n).
function Bank:start_deposit_x(target)
  if not self:is_open() then return false end
  return self:_slot(BACKPACK_ITEMS, self._game:backpack():find(Match.target(target)), OP_ENTER_AMOUNT)
end

function Bank:start_withdraw_x(target)
  if not self:is_open() then return false end
  return self:_slot(ITEMS, self._game:bank():find(Match.target(target)), OP_ENTER_AMOUNT)
end

function Bank:finish_transfer_x(amount)
  if not self:is_open() or not self:is_input_open() then return false end
  return Input.dialog(self._game):enter_amount(amount)
end

-- Withdraw preset 1..18, switching the preset page first when it shows the other nine.
function Bank:withdraw_preset(n)
  if not self:is_open() or n < 1 or n > MAX_PRESET then return false end
  local page = n > PRESETS_PER_PAGE and 1 or 0
  if self:preset_page() ~= page then self:_button(PRESET_BUTTONS, PRESET_PAGE_SWITCH_SUB) end
  return self:_button(PRESET_BUTTONS, (n - 1) % PRESETS_PER_PAGE + 1)
end

-- "Load Last Preset from" on the nearer of the nearest booth and the nearest banker offering it.
function Bank:load_last_preset()
  local game = self._game
  local me = game:self()
  local option = Bank.LOAD_LAST_PRESET_OPTION
  local booth, booth_d = Entities.objects(game):with_option(option):nearest(me.tile)
  local banker, banker_d = Entities.npcs(game):with_option(option):nearest(me.tile)
  if booth and (banker == nil or booth_d <= banker_d) then
    return Interact.object(game, booth, option)
  end
  return banker ~= nil and Interact.npc(game, banker, option)
end

-- Bank.ITEM or Bank.NOTE. The note button is a toggle, so it is clicked only when the mode
-- differs.
function Bank:set_withdraw_mode(mode)
  if not self:is_open() then return false end
  if self:withdraw_mode() == mode then return true end
  return self:_button(NOTE_MODE_BUTTON)
end

function Bank:set_transfer_mode(amount)
  if not self:is_open() then return false end
  return self:_button(amount.button)
end

return Bank
