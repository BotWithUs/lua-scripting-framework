-- botwithus.hud -- the ribbon tabs (skills, backpack, equipment, prayer, magic), logout and exit
-- to lobby (the Java host's hud.Hud and HudTab).
--
--   local Hud = require("botwithus.hud")
--   local hud = Hud.new(game)
--   if not hud:is_open(Hud.SKILLS) then hud:open(Hud.SKILLS) end
--   hud:exit_to_lobby()        -- queued: poll game:game_state() for the result
--
-- A tab's state is read from its ribbon button's own menu: "Close" while its window is in front,
-- "Open" otherwise. Every ribbon button's option is plain "Open" (not "Open Backpack"), and a
-- docked window stays loaded behind another tab, so the open-interface list cannot tell whether a
-- tab shows. Each tab's button is a sub of TOPLEVEL_V2_RIBBON__WINDOW_BUILD (1431:0); the sub is
-- found through the cache enum RIBBON_WINDOWS (13319, slot -> window number), with the 951 slots
-- as the fallback when the cache cannot be read.
--
-- logout() and exit_to_lobby() call the agent's own Escape-menu RPCs ("logout",
-- "exit_to_lobby"). They return once the clicks are queued; a refusal (not_in_game,
-- actions_blocked, logout_ui_not_found, action_queue_full) is false, code.

local Definitions = require("botwithus.definitions")
local Actions = require("botwithus.actions")
local G = require("botwithus.gameval")

local Hud = {}
Hud.__index = Hud

-- By gameval name (host ABI 8); the number is the fallback when the name does not resolve.
local RIBBON_BUTTONS = G.component_ref("TOPLEVEL_V2_RIBBON__WINDOW_BUILD", 1431, 0)
local RIBBON_WINDOWS = G.ref("enum", "RIBBON_WINDOWS", 13319)
Hud.OPEN = "Open"
Hud.CLOSE = "Close"

-- The tabs: the window number RIBBON_WINDOWS maps a slot to, and the 951 slot.
Hud.SKILLS    = { name = "skills", window = 0, fallback_slot = 8 }
Hud.BACKPACK  = { name = "backpack", window = 2, fallback_slot = 9 }
Hud.EQUIPMENT = { name = "equipment", window = 3, fallback_slot = 10 }
Hud.PRAYER    = { name = "prayer", window = 4, fallback_slot = 11 }
Hud.MAGIC     = { name = "magic", window = 5, fallback_slot = 12 }
Hud.TABS = { Hud.SKILLS, Hud.BACKPACK, Hud.EQUIPMENT, Hud.PRAYER, Hud.MAGIC }

function Hud.new(game) return setmetatable({ _game = game }, Hud) end

-- The ribbon slot (the button's sub) of `tab`.
function Hud:slot_of(tab)
  local ok, e = pcall(Definitions.enum, RIBBON_WINDOWS:id())
  if ok and e then
    for slot, window in pairs(e.entries) do
      if window == tab.window then return slot end
    end
  end
  return tab.fallback_slot
end

function Hud:_button_ops(tab, slot)
  local ribbon, buttons = RIBBON_BUTTONS:component()
  local reply = self._game:component_ops(ribbon, buttons, slot)
  return type(reply) == "table" and reply.ops or {}
end

local function op_named(ops, name)
  for _, o in ipairs(ops) do
    if o.name:lower() == name:lower() then return o.op end
  end
  return nil
end

-- Whether the tab's window is in front (its button lists "Close").
function Hud:is_open(tab)
  return op_named(self:_button_ops(tab, self:slot_of(tab)), Hud.CLOSE) ~= nil
end

-- Brings the tab's window to the front through its button's "Open". True when it already shows
-- (nothing is pressed) or the press was queued; false when the button lists neither.
function Hud:open(tab)
  local slot = self:slot_of(tab)
  local ops = self:_button_ops(tab, slot)
  if op_named(ops, Hud.CLOSE) then return true end
  local open = op_named(ops, Hud.OPEN)
  if open == nil then return false end
  local ribbon, buttons = RIBBON_BUTTONS:component()
  self._game:do_action(Actions.component_click(ribbon, buttons, open, slot))
  return true
end

function Hud:logout() return self._game:logout() end
function Hud:exit_to_lobby() return self._game:exit_to_lobby() end

return Hud
