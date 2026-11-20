-- botwithus.actionbar -- the action bar: the active bar, what each slot holds, using a slot or an
-- ability, and ability cooldowns (the Java host's combat.ActionBar, AbilityCatalog, Ability,
-- ActionBarSlot and Cooldown).
--
--   local ActionBar = require("botwithus.actionbar")
--   local bar = ActionBar.new(game)
--   for _, s in ipairs(bar:slots()) do print(s.slot, s.kind, s.ability and s.ability.name) end
--   if bar:contains_ability("Backhand") then bar:use_ability("Backhand") end
--   local cd = bar:cooldown("Backhand")
--   if cd.known and cd:is_ready(game:clocks().game_cycle) then ... end
--
-- SLOTS. A slot is { slot, kind, ... }: kind "empty", "ability" (with .ability), "item" (with
-- .item_id) or "unresolved" (with .type_code and .id: an ability the cache lookup did not find).
-- They are read from the varbits ACTIONBAR<bar>_INT<slot>_TYPE / _ID and the varp
-- ACTIONBAR<bar>_OBJ<slot>; a slot holding an item wins over its ability bits.
--
-- ABILITIES come from the cache: enum COMBATV2_TYPE_TO_ENUM (13199) maps a slot's type code to
-- that style's ability enum, which maps the ability id to its struct (params 2793 id, 2794 name,
-- 2796 cooldown ticks, 9405 global cooldown ticks).
--
-- COOLDOWNS are joined through the client's own scripts: 8247 (ability struct -> the struct its
-- cooldown is kept under), then 6506 (that struct -> the START_CLIENT / END_CLIENT varc values).
-- Never by name: the gameval-name join is wrong for 63 of the 172 cases script 6506 covers. When
-- either script cannot run, the cooldown is Cooldown.UNKNOWN (known = false), never "ready".
-- Script calls need host ABI 6.
--
-- UNITS. A cooldown's start_cycle / end_cycle are client cycles (game_cycle, ~20 ms): compare
-- them with game:clocks().game_cycle, never with server_tick. The global cooldown is 3 ticks =
-- 90 cycles.

local Definitions = require("botwithus.definitions")
local Actions = require("botwithus.actions")

local ActionBar = {}
ActionBar.__index = ActionBar

ActionBar.SLOTS = 14
ActionBar.MAX_BAR = 18
ActionBar.SCRIPT_COOLDOWN_STRUCT = 8247
ActionBar.SCRIPT_COOLDOWN_WINDOW = 6506
ActionBar.COMBAT_BAR = 1430
local CURRENT_BAR = 1893            -- varbit COMBATV2_ACTIONBAR_CURRENT_BAR
local GLOBAL_COOLDOWN_START = 2091  -- varc COMBATV2_GLOBAL_COOLDOWN_START_CLIENT
local GLOBAL_COOLDOWN_END = 2092    -- varc COMBATV2_GLOBAL_COOLDOWN_END_CLIENT
local TYPE_TO_ENUM = 13199          -- enum COMBATV2_TYPE_TO_ENUM
local OP_ACTIVATE = 1
local EMPTY_TYPE = 0

-- Ability struct params.
ActionBar.PARAM_ABILITY_ID = 2793
ActionBar.PARAM_NAME = 2794
ActionBar.PARAM_COOLDOWN = 2796
ActionBar.PARAM_GLOBAL_COOLDOWN = 9405
ActionBar.DEFAULT_GLOBAL_COOLDOWN_TICKS = 3

-- Generated from gameval.sqlite (meta built 2026-10-23, source: the live 951 cache):
-- ACTIONBAR<bar>_INT<slot>_TYPE / _ID (varbits) and ACTIONBAR<bar>_OBJ<slot> (varps), slot 1..14.
local SLOT_VARS = {
  [1] = {
    type = { 1747, 1749, 1751, 1753, 1755, 1757, 1759, 1761, 1763, 1765, 1767, 1769, 22337, 22339 },
    id   = { 1748, 1750, 1752, 1754, 1756, 1758, 1760, 1762, 1764, 1766, 1768, 1770, 22338, 22340 },
    obj  = { 823, 824, 825, 826, 827, 828, 829, 830, 831, 832, 833, 834, 4429, 4430 },
  },
  [2] = {
    type = { 1771, 1773, 1775, 1777, 1779, 1781, 1783, 1785, 1787, 1789, 1791, 1793, 22341, 22343 },
    id   = { 1772, 1774, 1776, 1778, 1780, 1782, 1784, 1786, 1788, 1790, 1792, 1794, 22342, 22344 },
    obj  = { 835, 836, 837, 838, 839, 840, 841, 842, 843, 844, 845, 846, 4431, 4432 },
  },
  [3] = {
    type = { 1795, 1797, 1799, 1801, 1803, 1805, 1807, 1809, 1811, 1813, 1815, 1817, 22345, 22347 },
    id   = { 1796, 1798, 1800, 1802, 1804, 1806, 1808, 1810, 1812, 1814, 1816, 1818, 22346, 22348 },
    obj  = { 847, 848, 849, 850, 851, 852, 853, 854, 855, 856, 857, 858, 4433, 4434 },
  },
  [4] = {
    type = { 1819, 1821, 1823, 1825, 1827, 1829, 1831, 1833, 1835, 1837, 1839, 1841, 22349, 22351 },
    id   = { 1820, 1822, 1824, 1826, 1828, 1830, 1832, 1834, 1836, 1838, 1840, 1842, 22350, 22352 },
    obj  = { 859, 860, 861, 862, 863, 864, 865, 866, 867, 868, 869, 870, 4435, 4436 },
  },
  [5] = {
    type = { 1843, 1845, 1847, 1849, 1851, 1853, 1855, 1857, 1859, 1861, 1863, 1865, 22353, 22355 },
    id   = { 1844, 1846, 1848, 1850, 1852, 1854, 1856, 1858, 1860, 1862, 1864, 1866, 22354, 22356 },
    obj  = { 871, 872, 873, 874, 875, 876, 877, 878, 879, 880, 881, 882, 4437, 4438 },
  },
  [6] = {
    type = { 22832, 27755, 27757, 27759, 27761, 27763, 27765, 27767, 27769, 27771, 27773, 27775, 27777, 27779 },
    id   = { 27754, 27756, 27758, 27760, 27762, 27764, 27766, 27768, 27770, 27772, 27774, 27776, 27778, 27780 },
    obj  = { 5335, 5336, 5337, 5338, 5339, 5340, 5341, 5342, 5343, 5344, 5345, 5346, 5347, 5348 },
  },
  [7] = {
    type = { 27781, 27783, 27785, 27787, 27789, 27791, 27793, 27795, 27797, 27799, 27801, 27803, 27805, 27807 },
    id   = { 27782, 27784, 27786, 27788, 27790, 27792, 27794, 27796, 27798, 27800, 27802, 27804, 27806, 27808 },
    obj  = { 5349, 5350, 5351, 5352, 5353, 5354, 5355, 5356, 5357, 5358, 5359, 5360, 5361, 5362 },
  },
  [8] = {
    type = { 27809, 27811, 27813, 27815, 27817, 27819, 27821, 27823, 27825, 27827, 27829, 27831, 27833, 27835 },
    id   = { 27810, 27812, 27814, 27816, 27818, 27820, 27822, 27824, 27826, 27828, 27830, 27832, 27834, 27836 },
    obj  = { 5363, 5364, 5365, 5366, 5367, 5368, 5369, 5370, 5371, 5372, 5373, 5374, 5375, 5376 },
  },
  [9] = {
    type = { 27837, 27839, 27841, 27843, 27845, 27847, 27849, 27851, 27853, 27855, 27857, 27859, 27861, 27863 },
    id   = { 27838, 27840, 27842, 27844, 27846, 27848, 27850, 27852, 27854, 27856, 27858, 27860, 27862, 27864 },
    obj  = { 5377, 5378, 5379, 5380, 5381, 5382, 5383, 5384, 5385, 5386, 5387, 5388, 5389, 5390 },
  },
  [10] = {
    type = { 27865, 27867, 27869, 27871, 27873, 27875, 27877, 27879, 27881, 27884, 27885, 27887, 27889, 27891 },
    id   = { 27866, 27868, 27870, 27872, 27874, 27876, 27878, 27880, 27882, 27883, 27886, 27888, 27890, 27892 },
    obj  = { 5391, 5392, 5393, 5394, 5395, 5396, 5397, 5398, 5399, 5400, 5401, 5402, 5403, 5404 },
  },
  [11] = {
    type = { 44638, 44640, 44642, 44644, 44646, 44648, 44650, 44652, 44654, 44657, 44658, 44660, 44662, 44664 },
    id   = { 44639, 44641, 44643, 44645, 44647, 44649, 44651, 44653, 44655, 44656, 44659, 44661, 44663, 44665 },
    obj  = { 8801, 8802, 8803, 8804, 8805, 8806, 8807, 8808, 8809, 8810, 8811, 8812, 8813, 8814 },
  },
  [12] = {
    type = { 44666, 44668, 44670, 44672, 44674, 44676, 44678, 44680, 44682, 44685, 44686, 44688, 44690, 44692 },
    id   = { 44667, 44669, 44671, 44673, 44675, 44677, 44679, 44681, 44683, 44684, 44687, 44689, 44691, 44693 },
    obj  = { 8815, 8816, 8817, 8818, 8819, 8820, 8821, 8822, 8823, 8824, 8825, 8826, 8827, 8828 },
  },
  [13] = {
    type = { 44694, 44696, 44698, 44700, 44702, 44704, 44706, 44708, 44710, 44713, 44714, 44716, 44718, 44720 },
    id   = { 44695, 44697, 44699, 44701, 44703, 44705, 44707, 44709, 44711, 44712, 44715, 44717, 44719, 44721 },
    obj  = { 8829, 8830, 8831, 8832, 8833, 8834, 8835, 8836, 8837, 8838, 8839, 8840, 8841, 8842 },
  },
  [14] = {
    type = { 49904, 49906, 49908, 49910, 49912, 49914, 49916, 49918, 49920, 49923, 49924, 49926, 49928, 49930 },
    id   = { 49905, 49907, 49909, 49911, 49913, 49915, 49917, 49919, 49921, 49922, 49925, 49927, 49929, 49931 },
    obj  = { 10128, 10129, 10130, 10131, 10132, 10133, 10134, 10135, 10136, 10137, 10138, 10139, 10140, 10141 },
  },
  [15] = {
    type = { 49932, 49934, 49936, 49938, 49940, 49942, 49944, 49946, 49948, 49951, 49952, 49954, 49956, 49958 },
    id   = { 49933, 49935, 49937, 49939, 49941, 49943, 49945, 49947, 49949, 49950, 49953, 49955, 49957, 49959 },
    obj  = { 10142, 10143, 10144, 10145, 10146, 10147, 10148, 10149, 10150, 10151, 10152, 10153, 10154, 10155 },
  },
  [16] = {
    type = { 53126, 53128, 53130, 53132, 53134, 53136, 53138, 53140, 53142, 53144, 53146, 53148, 53150, 53152 },
    id   = { 53125, 53127, 53129, 53131, 53133, 53135, 53137, 53139, 53141, 53143, 53145, 53147, 53149, 53151 },
    obj  = { 11261, 11262, 11263, 11264, 11265, 11266, 11267, 11268, 11269, 11270, 11271, 11272, 11273, 11274 },
  },
  [17] = {
    type = { 53154, 53156, 53158, 53160, 53162, 53164, 53166, 53168, 53170, 53172, 53174, 53176, 53178, 53180 },
    id   = { 53153, 53155, 53157, 53159, 53161, 53163, 53165, 53167, 53169, 53171, 53173, 53175, 53177, 53179 },
    obj  = { 11275, 11276, 11277, 11278, 11279, 11280, 11281, 11282, 11283, 11284, 11285, 11286, 11287, 11288 },
  },
  [18] = {
    type = { 53182, 53184, 53186, 53188, 53190, 53192, 53194, 53196, 53198, 53200, 53202, 53204, 53206, 53208 },
    id   = { 53181, 53183, 53185, 53187, 53189, 53191, 53193, 53195, 53197, 53199, 53201, 53203, 53205, 53207 },
    obj  = { 11289, 11290, 11291, 11292, 11293, 11294, 11295, 11296, 11297, 11298, 11299, 11300, 11301, 11302 },
  },
}
-- TOPLEVEL_V2_COMBAT_BAR__GRAPHIC_<slot>: the slot's click layer (BUTTON_n has no ops).
local SLOT_BUTTONS = { 66, 79, 92, 105, 118, 131, 144, 157, 170, 183, 196, 209, 222, 235 }

-- Cooldown --------------------------------------------------------------------------------------

local Cooldown = {}
Cooldown.__index = Cooldown
Cooldown.CLIENT_CYCLE_MS = 20

function Cooldown.of(start_cycle, end_cycle)
  return setmetatable({ start_cycle = start_cycle, end_cycle = end_cycle, known = true }, Cooldown)
end

Cooldown.UNKNOWN = setmetatable({ start_cycle = 0, end_cycle = 0, known = false }, Cooldown)

-- Client cycles left at `now_cycle` (game_cycle), 0 when ready, -1 when unknown.
function Cooldown:remaining_cycles(now_cycle)
  if not self.known then return -1 end
  return math.max(0, self.end_cycle - now_cycle)
end

-- Milliseconds left, or -1 when unknown.
function Cooldown:remaining_ms(now_cycle)
  local cycles = self:remaining_cycles(now_cycle)
  return cycles < 0 and -1 or cycles * Cooldown.CLIENT_CYCLE_MS
end

-- Ready only when known and the window has passed: an unknown cooldown is never ready.
function Cooldown:is_ready(now_cycle) return self.known and now_cycle >= self.end_cycle end

ActionBar.Cooldown = Cooldown

-- The ability catalog -----------------------------------------------------------------------

local Catalog = {}
Catalog.__index = Catalog

function ActionBar.new_catalog()
  return setmetatable({ _by_key = {}, _type_to_enum = nil, _enums = {} }, Catalog)
end

local function cache_or_nil(fn, ...)
  local ok, v = pcall(fn, ...)
  if ok then return v end
  return nil
end

function Catalog:_enum(id)
  local e = self._enums[id]
  if e == nil then
    e = cache_or_nil(Definitions.enum, id)
    if e then self._enums[id] = e end
  end
  return e
end

-- type code -> ability enum id, or {} when the cache cannot be read (not remembered, so a later
-- call can still resolve).
function Catalog:type_to_enum()
  if self._type_to_enum then return self._type_to_enum end
  local e = self:_enum(TYPE_TO_ENUM)
  if e == nil then return {} end
  self._type_to_enum = e.entries
  return e.entries
end

local function ability_of(type_code, struct_id)
  local params = cache_or_nil(Definitions.param_map, Definitions.CACHE_STRUCT, struct_id)
  if params == nil then return nil end
  local id, name = params[ActionBar.PARAM_ABILITY_ID], params[ActionBar.PARAM_NAME]
  if math.type(id) ~= "integer" or type(name) ~= "string" then return nil end
  return { struct_id = struct_id, type_code = type_code, ability_id = id, name = name,
           cooldown_ticks = params[ActionBar.PARAM_COOLDOWN] or 0,
           global_cooldown_ticks = params[ActionBar.PARAM_GLOBAL_COOLDOWN]
             or ActionBar.DEFAULT_GLOBAL_COOLDOWN_TICKS }
end

-- The ability a slot's (type code, id) holds, or nil.
function Catalog:resolve(type_code, id)
  local map = self:type_to_enum()
  if next(map) == nil then return nil end
  local key = type_code .. ":" .. id
  local hit = self._by_key[key]
  if hit ~= nil then return hit or nil end
  local enum_id = map[type_code]
  local abilities = enum_id and self:_enum(enum_id)
  local struct_id = abilities and abilities.entries[id]
  local ability = struct_id and ability_of(type_code, struct_id) or nil
  self._by_key[key] = ability or false
  return ability
end

-- The ability named `name` (whole name, ignoring case) in any style, or nil. Reads every
-- style's ability enum once.
function Catalog:by_name(name)
  local want = name:lower()
  for type_code, enum_id in pairs(self:type_to_enum()) do
    local abilities = self:_enum(enum_id)
    for ability_id in pairs(abilities and abilities.entries or {}) do
      local a = self:resolve(type_code, ability_id)
      if a and a.name:lower() == want then return a end
    end
  end
  return nil
end

ActionBar.Catalog = Catalog

-- The bar --------------------------------------------------------------------------------------

function ActionBar.new(game, catalog)
  return setmetatable({ _game = game, _catalog = catalog or ActionBar.new_catalog() }, ActionBar)
end

function ActionBar:catalog() return self._catalog end

-- The active bar, 1..18, or -1 when the varbit reads anything else.
function ActionBar:active_bar()
  local bar = self._game:varbit(CURRENT_BAR)
  return (bar >= 1 and bar <= ActionBar.MAX_BAR) and bar or -1
end

function ActionBar:_decode(slot, type_code, id, item_id)
  if item_id > 0 then return { slot = slot, kind = "item", item_id = item_id } end
  if type_code == EMPTY_TYPE or type_code < 0 then return { slot = slot, kind = "empty" } end
  local ability = self._catalog:resolve(type_code, id)
  if ability then return { slot = slot, kind = "ability", ability = ability } end
  return { slot = slot, kind = "unresolved", type_code = type_code, id = id }
end

-- The 14 slots of bar `bar` (1..18), or {} outside that range. One varbit read and one varp
-- read for the whole bar.
function ActionBar:slots_of(bar)
  local vars = SLOT_VARS[bar]
  if vars == nil then return {} end
  local ids = {}
  for i = 1, ActionBar.SLOTS do
    ids[2 * i - 1], ids[2 * i] = vars.type[i], vars.id[i]
  end
  local bits = self._game:read_varbits(ids)
  local items = self._game:varps(vars.obj)
  local out = {}
  for i = 1, ActionBar.SLOTS do
    out[i] = self:_decode(i, bits[2 * i - 1].value, bits[2 * i].value, items[i])
  end
  return out
end

-- The active bar's slots, or {} when no bar is active.
function ActionBar:slots()
  local bar = self:active_bar()
  return bar < 0 and {} or self:slots_of(bar)
end

function ActionBar:slot(n) return self:slots()[n] end

-- The active bar's slot holding the ability named `name` (ignoring case), or nil.
function ActionBar:find_ability(name)
  local want = name:lower()
  for _, s in ipairs(self:slots()) do
    if s.kind == "ability" and s.ability.name:lower() == want then return s end
  end
  return nil
end

function ActionBar:contains_ability(name) return self:find_ability(name) ~= nil end

-- Press slot 1..14 of the active bar (its GRAPHIC_n click layer).
function ActionBar:use_slot(n)
  local comp = SLOT_BUTTONS[n]
  if comp == nil then return false end
  self._game:do_action(Actions.component_click(ActionBar.COMBAT_BAR, comp, OP_ACTIVATE, -1))
  return true
end

-- Press the active bar's slot holding `name`; false when no slot holds it.
function ActionBar:use_ability(name)
  local s = self:find_ability(name)
  return s ~= nil and self:use_slot(s.slot)
end

function ActionBar:global_cooldown()
  return Cooldown.of(self._game:varc_int(GLOBAL_COOLDOWN_START),
                     self._game:varc_int(GLOBAL_COOLDOWN_END))
end

-- One int-returning client script run: its returns, or nil when any step fails. The handle is
-- always released.
function ActionBar:_run_script(script_id, arg, returns)
  local game = self._game
  local ok, handle = pcall(game.script_handle, game, script_id)
  if not ok or handle == nil then return nil end
  local kinds = {}
  for i = 1, returns do kinds[i] = "int" end
  local ran, result = pcall(game.execute_script, game, handle, { arg }, nil, kinds)
  pcall(game.destroy_script_handle, game, handle)
  if not ran or type(result) ~= "table" or #result < returns then return nil end
  return result
end

-- An ability's cooldown window (an ability table, or a name looked up in the catalog).
function ActionBar:cooldown(ability)
  if type(ability) == "string" then ability = self._catalog:by_name(ability) end
  if ability == nil then return Cooldown.UNKNOWN end
  local holder = self:_run_script(ActionBar.SCRIPT_COOLDOWN_STRUCT, ability.struct_id, 1)
  if holder == nil then return Cooldown.UNKNOWN end
  local window = self:_run_script(ActionBar.SCRIPT_COOLDOWN_WINDOW, holder[1], 2)
  if window == nil then return Cooldown.UNKNOWN end
  return Cooldown.of(window[1], window[2])
end

-- Milliseconds of `ability`'s cooldown left now, or -1 when unknown.
function ActionBar:cooldown_remaining_ms(ability)
  return self:cooldown(ability):remaining_ms(self._game:clocks().game_cycle)
end

return ActionBar
