-- botwithus.summoning -- summoning points, the familiar and its beast-of-burden inventory, and
-- the familiar buttons (the Java host's summoning.Summoning, Familiar and BeastOfBurden).
--
--   local Summoning = require("botwithus.summoning")
--   local s = Summoning.new(game)
--   if s:has_familiar() then
--     local f = s:familiar()                 -- { pouch_item_id, pouch_name, npc_id, ... }
--     print(f.pouch_name, s:minutes_remaining(), s:beast_of_burden():count(1511))
--   end
--   s:call(); s:dismiss(); s:cast_special()
--
-- Familiar details come from the cache, through the pouch item's params (74 FOLLOWER_NPC, 394 the
-- level needed, 396 the summoning cost), not from a hand-typed table. The beast-of-burden
-- inventory is 530 (LORE_BOB), not 671. The buttons are sent only while a familiar is out.

local Definitions = require("botwithus.definitions")
local Actions = require("botwithus.actions")
local Inventory = require("botwithus.inventory")
local Skills = require("botwithus.skills")

local Summoning = {}
Summoning.__index = Summoning

local TENTHS = 10
local POINTS_PER_LEVEL = 10
local NO_POUCH = 0
local OP_PRESS = 1
local POINTS = 41524          -- varbit LORE_POINTS (tenths)
local POUCH = 1831            -- varp FOLLOWER_OBJ
local MINUTES_LEFT = 6055     -- varbit LORE_FULL_TIMER
local SPECIAL_POINTS = 1787   -- varp LORE_SPELL_POINTS
local SCROLLS_STORED = 25412  -- varbit COMBATV2_SUMMONING_SCROLLCOUNT
local COMBAT_BAR = 1430
local CALL_BUTTON = 50        -- TOPLEVEL_V2_COMBAT_BAR__CALL_OP1
local DISMISS_BUTTON = 51     -- TOPLEVEL_V2_COMBAT_BAR__DISMISS_OP1
local INTERACT_BUTTON = 44    -- TOPLEVEL_V2_COMBAT_BAR__INTERACT_OP1
local FAMILIAR_SIDE = 662     -- LORE_STATS_SIDE
local SPECIAL_BUTTON = 38     -- LORE_STATS_SIDE__LORE_SPELL_BUTTON_GRAPHIC_1

Summoning.PARAM_FOLLOWER_NPC = 74
Summoning.PARAM_LEVEL_REQUIRED = 394
Summoning.PARAM_COST = 396

function Summoning.new(game) return setmetatable({ _game = game }, Summoning) end

function Summoning:raw_points() return self._game:varbit(POINTS) end

function Summoning:points()
  local raw = self:raw_points()
  return raw < 0 and -1 or raw // TENTHS
end

-- The Summoning level x 10, or -1 when the skill cannot be read.
function Summoning:max_points()
  local ok, row = pcall(self._game.skill, self._game, Skills.SUMMONING)
  if ok and row then return row.level * POINTS_PER_LEVEL end
  return -1
end

-- The summoned familiar's pouch item id, 0 for none.
function Summoning:pouch_id() return math.max(self._game:varp(POUCH), NO_POUCH) end
function Summoning:has_familiar() return self:pouch_id() > NO_POUCH end

-- The familiar from its pouch's params: { pouch_item_id, pouch_name, npc_id, level_required,
-- summoning_cost } (-1 where the pouch does not say), or nil with no familiar or no cache.
function Summoning:familiar()
  local pouch = self:pouch_id()
  if pouch == NO_POUCH then return nil end
  local ok, params = pcall(Definitions.param_map, Definitions.CACHE_ITEM, pouch)
  if not ok or params == nil or math.type(params[Summoning.PARAM_FOLLOWER_NPC]) ~= "integer" then
    return nil
  end
  local def_ok, def = pcall(Definitions.item, pouch)
  return { pouch_item_id = pouch, pouch_name = def_ok and def and def.name or "",
           npc_id = params[Summoning.PARAM_FOLLOWER_NPC],
           level_required = params[Summoning.PARAM_LEVEL_REQUIRED] or -1,
           summoning_cost = params[Summoning.PARAM_COST] or -1 }
end

function Summoning:minutes_remaining() return math.max(0, self._game:varbit(MINUTES_LEFT)) end
function Summoning:special_move_points() return self._game:varp(SPECIAL_POINTS) end
function Summoning:scrolls_stored() return math.max(0, self._game:varbit(SCROLLS_STORED)) end

-- The beast-of-burden inventory view (530); not present without a beast of burden.
function Summoning:beast_of_burden() return self._game:inventory(Inventory.FAMILIAR) end

function Summoning:_press(iface, comp)
  if not self:has_familiar() then return false end
  self._game:do_action(Actions.component_click(iface, comp, OP_PRESS, -1))
  return true
end

function Summoning:call() return self:_press(COMBAT_BAR, CALL_BUTTON) end
function Summoning:dismiss() return self:_press(COMBAT_BAR, DISMISS_BUTTON) end
function Summoning:interact() return self:_press(COMBAT_BAR, INTERACT_BUTTON) end
function Summoning:cast_special() return self:_press(FAMILIAR_SIDE, SPECIAL_BUTTON) end

return Summoning
