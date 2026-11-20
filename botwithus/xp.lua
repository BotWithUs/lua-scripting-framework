-- botwithus.xp -- skill display names, the xp tables and an xp tracker (the Java host's
-- util.SkillType, util.XpTable and util.XpTracker).
--
--   local Xp = require("botwithus.xp")
--   Xp.STANDARD:level_for_xp(13034431)          -- 99
--   Xp.table_for("invention"):xp_for_level(120) -- the elite table
--   Xp.display_name(Skills.WOODCUTTING)         -- "Woodcutting"
--   local tracker = Xp.tracker(game, "woodcutting")
--   print(tracker:xp_gained(), tracker:xp_per_hour(), tracker:time_to_next_level_ms())
--
-- The tables are v1's, trimmed to what the 200M cap reaches: the standard table to level 126, the
-- elite table (Invention) to 120. Nothing past 120 is invented for the elite table. There is no
-- per-skill level cap on the wire, so level_for_xp(xp) is the VIRTUAL level; pass the cap you
-- want (99, 120) as level_for_xp(xp, cap).

local Skills = require("botwithus.skills")
local Timers = require("botwithus.timers")

local Xp = {}

Xp.MAX_XP = 200000000
Xp.MIN_LEVEL = 1

-- standard: 126 levels
local STANDARD_XP = {
  0, 83, 174, 276, 388, 512, 650, 801, 969, 1154, 1358, 1584, 1833, 2107, 2411, 2746, 3115, 3523,
  3973, 4470, 5018, 5624, 6291, 7028, 7842, 8740, 9730, 10824, 12031, 13363, 14833, 16456, 18247,
  20224, 22406, 24815, 27473, 30408, 33648, 37224, 41171, 45529, 50339, 55649, 61512, 67983,
  75127, 83014, 91721, 101333, 111945, 123660, 136594, 150872, 166636, 184040, 203254, 224466,
  247886, 273742, 302288, 333804, 368599, 407015, 449428, 496254, 547953, 605032, 668051, 737627,
  814445, 899257, 992895, 1096278, 1210421, 1336443, 1475581, 1629200, 1798808, 1986068, 2192818,
  2421087, 2673114, 2951373, 3258594, 3597792, 3972294, 4385776, 4842295, 5346332, 5902831,
  6517253, 7195629, 7944614, 8771558, 9684577, 10692629, 11805606, 13034431, 14391160, 15889109,
  17542976, 19368992, 21385073, 23611006, 26068632, 28782068, 31777942, 35085654, 38737661,
  42769801, 47221641, 52136869, 57563718, 63555443, 70170840, 77474828, 85539082, 94442736,
  104273167, 115126838, 127110260, 140341028, 154948977, 171077457, 188884740,
}
-- elite: 120 levels
local ELITE_XP = {
  0, 830, 1861, 2902, 3980, 5126, 6390, 7787, 9400, 11275, 13605, 16372, 19656, 23546, 28138,
  33520, 39809, 47109, 55535, 64802, 77190, 90811, 106221, 123573, 143025, 164742, 188893,
  215651, 245196, 277713, 316311, 358547, 404634, 454796, 509259, 568254, 632019, 700797, 774834,
  854383, 946227, 1044569, 1149696, 1261903, 1381488, 1508756, 1644015, 1787581, 1939773,
  2100917, 2283490, 2476369, 2679907, 2894505, 3120508, 3358307, 3608290, 3870846, 4146374,
  4435275, 4758122, 5096111, 5449685, 5819299, 6205407, 6608473, 7028964, 7467354, 7924122,
  8399751, 8925664, 9472665, 10041285, 10632061, 11245538, 11882262, 12542789, 13227679,
  13937496, 14672812, 15478994, 16313404, 17176661, 18069395, 18992239, 19945833, 20930821,
  21947856, 22997593, 24080695, 25259906, 26475754, 27728955, 29020233, 30350318, 31719944,
  33129852, 34580790, 36073511, 37608773, 39270442, 40978509, 42733789, 44537107, 46389292,
  48291180, 50243611, 52247435, 54303504, 56412678, 58575823, 60793812, 63067521, 65397835,
  67785643, 70231841, 72737330, 75303019, 77929820, 80618654,
}

local XpTable = {}
XpTable.__index = XpTable

local function xp_table(name, xp) return setmetatable({ name = name, _xp = xp }, XpTable) end

Xp.STANDARD = xp_table("standard", STANDARD_XP)
Xp.ELITE = xp_table("elite", ELITE_XP)

-- The highest level the table holds (126 standard, 120 elite).
function XpTable:max_level() return #self._xp end

-- The xp at which `level` starts. Raises outside 1..max_level().
function XpTable:xp_for_level(level)
  if math.type(level) ~= "integer" or level < Xp.MIN_LEVEL or level > #self._xp then
    error(("botwithus: level %s is outside 1..%d for the %s table"):format(tostring(level),
      #self._xp, self.name), 2)
  end
  return self._xp[level]
end

-- The (virtual) level `xp` reaches, at least 1; capped at `cap` when given.
function XpTable:level_for_xp(xp, cap)
  local lo, hi = 1, #self._xp
  while lo < hi do                               -- the last level whose start is <= xp
    local mid = (lo + hi + 1) // 2
    if self._xp[mid] <= xp then lo = mid else hi = mid - 1 end
  end
  local level = math.max(Xp.MIN_LEVEL, lo)
  return cap and math.min(level, cap) or level
end

-- The xp still needed for the next level; 0 at the top of the table.
function XpTable:xp_to_next_level(xp)
  local level = self:level_for_xp(xp)
  if level >= #self._xp then return 0 end
  return self._xp[level + 1] - math.max(0, xp)
end

-- Skill names -----------------------------------------------------------------------------------

-- The elite skills (the elite xp table): Invention.
local ELITE_SKILLS = { [Skills.INVENTION] = true }

-- "Woodcutting" for Skills.WOODCUTTING, or nil for an id the table does not know.
function Xp.display_name(which)
  local name = Skills.name(Skills.id(which) or -1)
  return name and (name:sub(1, 1):upper() .. name:sub(2)) or nil
end

function Xp.is_elite(which) return ELITE_SKILLS[Skills.id(which)] == true end

-- The table a skill (id or name) levels on.
function Xp.table_for(which)
  local id = Skills.id(which)
  if id == nil or Skills.name(id) == nil then error("botwithus: unknown skill " .. tostring(which), 2) end
  return ELITE_SKILLS[id] and Xp.ELITE or Xp.STANDARD
end

-- The virtual level of a skill row (from game:skill(...)), from its xp on its own table.
function Xp.virtual_level(row)
  return Xp.table_for(row.skill_id):level_for_xp(row.xp)
end

-- Xp still needed by a skill row for its next level.
function Xp.xp_to_next_level(row)
  return Xp.table_for(row.skill_id):xp_to_next_level(row.xp)
end

-- XpTracker -------------------------------------------------------------------------------------

local Tracker = {}
Tracker.__index = Tracker

-- Tracks a skill (id or name) from now. When the skill cannot be read yet (out of the world), the
-- baseline is taken at the first call that can read it, and the clock restarts there.
-- `opts.clock` returns milliseconds (see botwithus.timers).
function Xp.tracker(game, which, opts)
  opts = opts or {}
  local id = Skills.id(which)
  if id == nil then error("botwithus: unknown skill " .. tostring(which), 2) end
  local t = setmetatable({ _game = game, _skill = id,
                           _watch = Timers.Stopwatch.started(opts.clock) }, Tracker)
  t._baseline = t:_read()
  return t
end

-- A copy of the skill's { xp, level } now, or nil when it cannot be read.
function Tracker:_read()
  local ok, row = pcall(self._game.skill, self._game, self._skill)
  if ok and row then return { xp = row.xp, level = row.level } end
  return nil
end

function Tracker:_current()
  local now = self:_read()
  if self._baseline == nil and now ~= nil then
    self._baseline = now
    self._watch:reset()
  end
  return now
end

function Tracker:skill() return self._skill end

function Tracker:elapsed_ms()
  self:_current()
  return self._watch:elapsed_ms()
end

function Tracker:xp_gained()
  local now = self:_current()
  if now == nil or self._baseline == nil then return 0 end
  return now.xp - self._baseline.xp
end

function Tracker:levels_gained()
  local now = self:_current()
  if now == nil or self._baseline == nil then return 0 end
  return now.level - self._baseline.level
end

function Tracker:xp_per_hour()
  return Timers.Durations.per_hour(self:xp_gained(), self:elapsed_ms())
end

-- Milliseconds to the next level at the current rate, or nil with no rate or at the table top.
function Tracker:time_to_next_level_ms()
  local now = self:_current()
  local rate = self:xp_per_hour()
  if now == nil or rate <= 0 then return nil end
  local remaining = Xp.table_for(self._skill):xp_to_next_level(now.xp)
  if remaining == 0 then return nil end
  return remaining * Timers.Durations.MS_PER_HOUR // rate
end

-- Starts again from the current reading and zero time.
function Tracker:reset()
  self._baseline = self:_read()
  self._watch:reset()
end

Xp.XpTable = XpTable
Xp.Tracker = Tracker
return Xp
