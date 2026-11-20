-- botwithus.prayers -- prayer points, the active book, which prayers are on, toggling one, the
-- prayer window and quick prayers (the Java host's combat.Prayers, Prayer, PrayerBook and
-- PrayerInfo).
--
--   local Prayers = require("botwithus.prayers")
--   local p = Prayers.new(game)
--   print(p:points(), "/", p:max_points(), p:active_book())
--   if not p:is_active("PROTECT_MELEE") then
--     p:open_window()                       -- the button is clicked only while the window shows
--     p:toggle("PROTECT_MELEE")
--   end
--
-- A prayer is named by its key in Prayers.ALL ("PIETY", "CURSE_SOULSPLIT", ...) or passed as
-- that row. Each row is { key, book, struct, varbit }: its struct (COMBATV2_PRAYER_* /
-- COMBATV2_CURSE_*) and the varbit that reads 1 while it is on. A tiered prayer (Thick Skin ->
-- Rock Skin -> Steel Skin) names the tier the player's Prayer level reaches, from the struct's
-- tier params.
--
-- Points: the PRAYER_POINTS varbit stores tenths, so points() is raw // 10; max_points() is the
-- Prayer level x 10.
--
-- toggle() needs the prayer window open (its buttons are found in the window's live tree by the
-- prayer's on/off sprite and must have a trigger): open_window() first, then wait a tick.

local Definitions = require("botwithus.definitions")
local Actions = require("botwithus.actions")
local Skills = require("botwithus.skills")

local Prayers = {}
Prayers.__index = Prayers

local ON = 1
local TENTHS = 10
local POINTS_PER_LEVEL = 10
local OP_TOGGLE = 1
local OP_SELECT_QUICK_PRAYERS = 2
local POINTS = 16736             -- varbit PRAYER_POINTS
local MODE = 16789               -- varbit PRAYER_MODE
local QUICK_PRAYERS_ON = 5941    -- varbit TOPSTAT_PRAYER_BUTTON
Prayers.WINDOW = 1458            -- TOPLEVEL_V2_PRAYER
local BUTTONS_COMP = 40          -- TOPLEVEL_V2_PRAYER__PRAYER_BUTTONS
local COMBAT_BAR = 1430
local QUICK_PRAYER_ORB = 18      -- TOPLEVEL_V2_COMBAT_BAR__PRAYER_GLOBE_LAYER
local RIBBON = 1431              -- TOPLEVEL_V2_RIBBON__WINDOW_BUILD (comp 0)
local RIBBON_COMP = 0
local RIBBON_WINDOWS = 13319     -- enum RIBBON_WINDOWS: ribbon slot -> window number
local PRAYER_WINDOW_NUMBER = 4
local PRAYER_RIBBON_SLOT = 11    -- the 951 slot, used when the enum cannot be read

-- Struct params.
Prayers.PARAM_NAME = 2794
Prayers.PARAM_LEVEL = 2807
Prayers.PARAM_MEMBERS = 2809
Prayers.PARAM_DRAIN_RATE = 2945
Prayers.PARAM_QUICK_PRAYER_ID = 6670
Prayers.PARAM_GRAPHIC_ON = 735
Prayers.PARAM_GRAPHIC_OFF = 736
Prayers.PARAM_TIER1_LEVEL = 2963
Prayers.TIERS = 3

-- The books: the PRAYER_MODE value and the cache enum listing each book's prayer structs.
Prayers.NORMAL = "normal"     -- mode 0, enum COMBATV2_ENUM_OF_ALL_PRAYERS (14185)
Prayers.CURSES = "curses"     -- mode 1, enum COMBATV2_ENUM_OF_ALL_CURSES (14186)
Prayers.UNKNOWN = "unknown"
local BOOK_BY_MODE = { [0] = Prayers.NORMAL, [1] = Prayers.CURSES }

-- { key, book, struct id, active varbit id }, from the Java host's Prayer enum (gameval names
-- COMBATV2_PRAYER_<key> / COMBATV2_CURSE_<key> for the struct).
local ROWS = {
  { "TIERED_DEFENCE", "normal", 14540, 16739 },
  { "TIERED_MELEE_STRENGTH", "normal", 14544, 16740 },
  { "TIERED_MELEE_ATTACK", "normal", 14548, 16741 },
  { "RAPID_RESTORE", "normal", 14572, 16742 },
  { "RAPID_HEAL", "normal", 14573, 16743 },
  { "PROTECT_ITEM", "normal", 14575, 16744 },
  { "PROTECT_MAGIC", "normal", 14576, 16745 },
  { "PROTECT_MISSILES", "normal", 14577, 16746 },
  { "PROTECT_MELEE", "normal", 14578, 16747 },
  { "PROTECT_NECROMANCY", "normal", 48369, 53274 },
  { "RETRIBUTION", "normal", 14580, 16748 },
  { "REDEMPTION", "normal", 14581, 16749 },
  { "SMITE", "normal", 14582, 16750 },
  { "TIERED_RANGE_ATTACK", "normal", 14552, 16751 },
  { "TIERED_RANGE_STRENGTH", "normal", 14556, 16753 },
  { "TIERED_MAGIC_ATTACK", "normal", 14560, 16752 },
  { "TIERED_MAGIC_STRENGTH", "normal", 14564, 16754 },
  { "TIERED_NECROMANCY_ATTACK", "normal", 48360, 53271 },
  { "TIERED_NECROMANCY_STRENGTH", "normal", 48364, 53272 },
  { "SUMMONING", "normal", 14579, 16755 },
  { "CHIVALRY", "normal", 14568, 16756 },
  { "PIETY", "normal", 14569, 16757 },
  { "RAPID_RENEWAL", "normal", 14574, 16758 },
  { "AUGURY", "normal", 14570, 16759 },
  { "RIGOUR", "normal", 14571, 16760 },
  { "SANCTITY", "normal", 48368, 53273 },
  { "DIVINE_RAGE", "normal", 50077, 55729 },
  { "ECLIPSED_SOUL", "normal", 50228, 55986 },
  { "CURSE_PROTECT_ITEM", "curses", 14583, 16761 },
  { "CURSE_SAP_WARRIOR", "curses", 14584, 16762 },
  { "CURSE_SAP_STRENGTH", "curses", 14591, 16787 },
  { "CURSE_SAP_RANGER", "curses", 14585, 16763 },
  { "CURSE_SAP_RANGE_STRENGTH", "curses", 14586, 16786 },
  { "CURSE_SAP_MAGE", "curses", 14587, 16764 },
  { "CURSE_SAP_MAGIC_STRENGTH", "curses", 14588, 16785 },
  { "CURSE_SAP_NECROMANCY_ATTACK", "curses", 48370, 53275 },
  { "CURSE_SAP_NECROMANCY_STRENGTH", "curses", 48371, 53276 },
  { "CURSE_SAP_DEFENCE", "curses", 14590, 16788 },
  { "CURSE_SAP_SPIRIT", "curses", 14589, 16765 },
  { "CURSE_BERSERKER", "curses", 14592, 16766 },
  { "CURSE_DEFLECT_SUMMONING", "curses", 14593, 16767 },
  { "CURSE_DEFLECT_MAGIC", "curses", 14594, 16768 },
  { "CURSE_DEFLECT_MISSILES", "curses", 14595, 16769 },
  { "CURSE_DEFLECT_MELEE", "curses", 14596, 16770 },
  { "CURSE_DEFLECT_NECROMANCY", "curses", 48372, 53281 },
  { "CURSE_LEECH_ATTACK", "curses", 14597, 16771 },
  { "CURSE_LEECH_RANGED", "curses", 14598, 16772 },
  { "CURSE_LEECH_RANGE_STRENGTH", "curses", 14599, 16781 },
  { "CURSE_LEECH_MAGIC", "curses", 14600, 16773 },
  { "CURSE_LEECH_MAGIC_STRENGTH", "curses", 14601, 16782 },
  { "CURSE_LEECH_NECROMANCY_ATTACK", "curses", 48373, 53277 },
  { "CURSE_LEECH_NECROMANCY_STRENGTH", "curses", 48374, 53278 },
  { "CURSE_LEECH_DEFENCE", "curses", 14602, 16774 },
  { "CURSE_LEECH_STRENGTH", "curses", 14603, 16775 },
  { "CURSE_LEECH_ENERGY", "curses", 14604, 16776 },
  { "CURSE_LEECH_SPECIAL_ATTACK", "curses", 14605, 16777 },
  { "CURSE_WRATH", "curses", 14606, 16778 },
  { "CURSE_SOULSPLIT", "curses", 14607, 16779 },
  { "CURSE_TURMOIL", "curses", 14608, 16780 },
  { "CURSE_TORMENT", "curses", 14609, 16784 },
  { "CURSE_ANGUISH", "curses", 14610, 16783 },
  { "CURSE_SORROW", "curses", 48375, 53279 },
  { "CURSE_FORTITUDE", "curses", 32272, 29065 },
  { "CURSE_LIGHTFORM", "curses", 32273, 29066 },
  { "CURSE_DARKFORM", "curses", 32274, 29067 },
  { "CURSE_SOULLINK", "curses", 32275, 29068 },
  { "CURSE_TEAMWORK_PROTECTION", "curses", 32276, 29069 },
  { "CURSE_CHRONICLE_ATTRACTION", "curses", 29241, 49330 },
  { "CURSE_SUPERHEAT_FORM", "curses", 32278, 29071 },
  { "CURSE_OVERHEAD_TURMOIL", "curses", 35360, 34866 },
  { "CURSE_OVERHEAD_ANGUISH", "curses", 35361, 34867 },
  { "CURSE_OVERHEAD_TORMENT", "curses", 35362, 34868 },
  { "CURSE_RUINATION", "curses", 48376, 53280 },
}

Prayers.ALL = {}
Prayers.ORDER = {}
for i, r in ipairs(ROWS) do
  local row = { key = r[1], book = r[2], struct = r[3], varbit = r[4] }
  Prayers.ALL[r[1]] = row
  Prayers.ORDER[i] = row
end

function Prayers.new(game) return setmetatable({ _game = game }, Prayers) end

-- A prayer row from its key or the row itself; raises on an unknown key.
function Prayers.prayer(p)
  if type(p) == "table" then return p end
  local row = Prayers.ALL[p]
  if row == nil then error("botwithus: unknown prayer " .. tostring(p), 3) end
  return row
end

-- The rows of one book, in order.
function Prayers.of_book(book)
  local out = {}
  for _, row in ipairs(Prayers.ORDER) do
    if row.book == book then out[#out + 1] = row end
  end
  return out
end

function Prayers:raw_points() return self._game:varbit(POINTS) end

function Prayers:points()
  local raw = self:raw_points()
  return raw < 0 and -1 or raw // TENTHS
end

function Prayers:_level()
  local ok, row = pcall(self._game.skill, self._game, Skills.PRAYER)
  if ok and row then return row.level end
  return nil
end

-- The Prayer level x 10, or -1 when the skill cannot be read.
function Prayers:max_points()
  local level = self:_level()
  return level and level * POINTS_PER_LEVEL or -1
end

function Prayers:active_book() return BOOK_BY_MODE[self._game:varbit(MODE)] or Prayers.UNKNOWN end

function Prayers:is_active(p) return self._game:varbit(Prayers.prayer(p).varbit) == ON end

-- The prayers among `list` that are on, in one varbit read.
function Prayers:_active(list)
  if #list == 0 then return {} end
  local ids = {}
  for i, p in ipairs(list) do ids[i] = p.varbit end
  local on = {}
  for i, r in ipairs(self._game:read_varbits(ids)) do
    if r.value == ON then on[#on + 1] = list[i] end
  end
  return on
end

local function rows_of(...)
  local list = {}
  for i, p in ipairs({ ... }) do list[i] = Prayers.prayer(p) end
  return list
end

function Prayers:is_any_active(...) return #self:_active(rows_of(...)) > 0 end
function Prayers:is_all_active(...)
  local list = rows_of(...)
  return #self:_active(list) == #list
end

-- The active book's prayers that are on.
function Prayers:active_prayers() return self:_active(Prayers.of_book(self:active_book())) end

local function struct_params(id)
  local ok, params = pcall(Definitions.param_map, Definitions.CACHE_STRUCT, id)
  if ok then return params end
  return nil
end

-- A tiered struct's tier for the player's level: the highest tier the level reaches, else the
-- first tier.
function Prayers:_tier_for(params)
  local level = self:_level() or 0
  local chosen, chosen_id = nil, nil
  for tier = 0, Prayers.TIERS - 1 do
    local level_param = Prayers.PARAM_TIER1_LEVEL + 2 * tier
    local needed, id = params[level_param], params[level_param + 1]
    if math.type(needed) ~= "integer" or math.type(id) ~= "integer" then break end
    if chosen == nil or level >= needed then
      local tier_params = struct_params(id)
      if tier_params then chosen, chosen_id = tier_params, id end
    end
  end
  return chosen, chosen_id
end

local UNKNOWN_VALUE = -1

-- A prayer's cache details: { key, struct_id, name, level_required, drain_rate, is_members,
-- quick_prayer_id, graphic_on, graphic_off }, or nil when the cache cannot read it.
function Prayers:info(p)
  local row = Prayers.prayer(p)
  local params = struct_params(row.struct)
  if params == nil then return nil end
  local struct_id = row.struct
  local tier, tier_id = self:_tier_for(params)
  if tier then params, struct_id = tier, tier_id end
  local function int(id) return params[id] or UNKNOWN_VALUE end
  return { key = row.key, struct_id = struct_id, name = params[Prayers.PARAM_NAME] or row.key,
           level_required = int(Prayers.PARAM_LEVEL), drain_rate = int(Prayers.PARAM_DRAIN_RATE),
           is_members = (params[Prayers.PARAM_MEMBERS] or 0) ~= 0,
           quick_prayer_id = int(Prayers.PARAM_QUICK_PRAYER_ID),
           graphic_on = int(Prayers.PARAM_GRAPHIC_ON), graphic_off = int(Prayers.PARAM_GRAPHIC_OFF) }
end

function Prayers:is_window_open() return self._game:is_interface_open(Prayers.WINDOW) end

-- The ribbon slot holding the prayer window (enum RIBBON_WINDOWS), else the 951 slot.
function Prayers:_ribbon_slot()
  local ok, e = pcall(Definitions.enum, RIBBON_WINDOWS)
  if ok and e then
    for slot, window in pairs(e.entries) do
      if window == PRAYER_WINDOW_NUMBER then return slot end
    end
  end
  return PRAYER_RIBBON_SLOT
end

-- Opens the prayer window through its ribbon button; true when already open.
function Prayers:open_window()
  if self:is_window_open() then return true end
  self._game:do_action(Actions.component_click(RIBBON, RIBBON_COMP, OP_TOGGLE, self:_ribbon_slot()))
  return true
end

-- The prayer's button in the open window, or nil.
function Prayers:_button(info)
  if not self:is_window_open() then return nil end
  local tree = self._game:interface_tree(Prayers.WINDOW, BUTTONS_COMP)
  for _, node in ipairs(tree and tree.nodes or {}) do
    local sprite = node.sprite_id
    if (sprite == info.graphic_on or sprite == info.graphic_off) and #(node.triggers or {}) > 0 then
      return node
    end
  end
  return nil
end

-- Clicks the prayer's button. False (nothing sent) when the window is closed, the cache cannot
-- read the prayer, or no button shows its sprite.
function Prayers:toggle(p)
  local info = self:info(p)
  if info == nil then return false end
  local node = self:_button(info)
  if node == nil then return false end
  self._game:do_action(Actions.component_click(node.iface, node.comp, OP_TOGGLE, node.sub))
  return true
end

function Prayers:is_quick_prayers_active() return self._game:varbit(QUICK_PRAYERS_ON) == ON end

-- The quick-prayer orb's own ops: 1 toggles, 2 opens the selection.
function Prayers:toggle_quick_prayers()
  self._game:do_action(Actions.component_click(COMBAT_BAR, QUICK_PRAYER_ORB, OP_TOGGLE, -1))
  return true
end

function Prayers:open_quick_prayer_selection()
  self._game:do_action(Actions.component_click(COMBAT_BAR, QUICK_PRAYER_ORB, OP_SELECT_QUICK_PRAYERS, -1))
  return true
end

return Prayers
