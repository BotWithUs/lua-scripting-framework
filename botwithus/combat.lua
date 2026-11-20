-- botwithus.combat -- the local player's combat state and recent hitmarks (the Java host's
-- combat.LocalCombat, CombatTarget and HitmarkHistory).
--
--   local Combat = require("botwithus.combat")
--   local me = Combat.new(game)
--   print(me:life_points(), "/", me:max_life_points(), me:adrenaline(), me:prayer_points())
--   local t = me:target()                      -- { kind = "npc", npc = row } / "player" / ...
--   local hits = Combat.history(game)
--   hits:feed(game:poll_events())              -- feed it the events you poll each loop
--   if me:is_in_combat(hits) then ... end
--
-- is_in_combat is a heuristic, as in the Java host: the game's COMBATV2_PLAYER_IS_IN_COMBAT flag,
-- or a current target, or (given a history) a hitmark on the player in the last 6 s.
--
-- TARGET TYPES. The self row's target_type reads 1 for an NPC (verified live), 0 after a kill and
-- 127 when never set this session (both "none"); 2 is taken as a player, which is inferred, not
-- verified.

local Prayers = require("botwithus.prayers")
local Events = require("botwithus.events")

local Combat = {}
Combat.__index = Combat

Combat.TARGET_TYPE_CLEARED = 0
Combat.TARGET_TYPE_NPC = 1
Combat.TARGET_TYPE_PLAYER = 2
Combat.TARGET_TYPE_NEVER_SET = 127
Combat.NO_TARGET_INDEX = -1
Combat.RECENT_HIT_MS = 6000

local IN_COMBAT = 1
local TENTHS = 10
local ADRENALINE = 679          -- varp SA_ENERGY
local IN_COMBAT_FLAG = 1899     -- varbit COMBATV2_PLAYER_IS_IN_COMBAT
local SUMMONING_POINTS = 41524  -- varbit LORE_POINTS (tenths)
local LIFE_POINTS = 13537       -- varp LIFEPOINTS
local MAX_LIFE_POINTS = 13538   -- varp MAXLIFEPOINTS

function Combat.new(game)
  return setmetatable({ _game = game, _prayers = Prayers.new(game) }, Combat)
end

function Combat:adrenaline() return self._game:varp(ADRENALINE) end

-- The self row's health when it carries one, else the LIFEPOINTS varps.
function Combat:_health()
  local me = self._game:self()
  if me.health ~= nil and me.max_health ~= nil and me.max_health > 0 then
    return me.health, me.max_health
  end
  return nil
end

function Combat:life_points()
  local current = self:_health()
  return current or self._game:varp(LIFE_POINTS)
end

function Combat:max_life_points()
  local _, max = self:_health()
  return max or self._game:varp(MAX_LIFE_POINTS)
end

function Combat:prayer_points() return self._prayers:points() end

function Combat:summoning_points()
  local raw = self._game:varbit(SUMMONING_POINTS)
  return raw < 0 and -1 or raw // TENTHS
end

-- The local player's own display name, or nil while the client has not decoded it.
function Combat:name()
  local me = self._game:self()
  for _, p in ipairs(self._game:players()) do
    if p.server_index == me.server_index and p.name ~= nil and p.name ~= "" then return p.name end
  end
  return nil
end

local function has_target(me)
  local t = me.target_type
  return me.target_index ~= nil and me.target_index ~= Combat.NO_TARGET_INDEX
    and t ~= Combat.TARGET_TYPE_CLEARED and t ~= Combat.TARGET_TYPE_NEVER_SET
end

local function by_index(rows, index)
  for _, r in ipairs(rows) do
    if r.server_index == index then return r end
  end
  return nil
end

-- The current target: { kind = "none" }, { kind = "npc", npc = row }, { kind = "player",
-- player = row }, or { kind = "unresolved", target_index, target_type } (not in view, or a type
-- this does not know).
function Combat:target()
  local me = self._game:self()
  if not has_target(me) then return { kind = "none" } end
  local index, ttype = me.target_index, me.target_type
  local row
  if ttype == Combat.TARGET_TYPE_NPC then
    row = by_index(self._game:npcs(), index)
    if row then return { kind = "npc", npc = row } end
  elseif ttype == Combat.TARGET_TYPE_PLAYER then
    row = by_index(self._game:players(), index)
    if row then return { kind = "player", player = row } end
  end
  return { kind = "unresolved", target_index = index, target_type = ttype }
end

function Combat:is_in_combat(history)
  if self._game:varbit(IN_COMBAT_FLAG) == IN_COMBAT then return true end
  local me = self._game:self()
  if has_target(me) then return true end
  return history ~= nil
    and #history:recent(Events.TARGET_PLAYER, me.server_index, Combat.RECENT_HIT_MS) > 0
end

-- HitmarkHistory ----------------------------------------------------------------------------

local History = {}
History.__index = History

History.PER_ENTITY_CAPACITY = 16
History.RETENTION_MS = 30000
local CYCLE_MS = 20

-- Recent hitmarks per entity, fed from game:poll_events(). Times are the hitmark's own cycle
-- (game_cycle, 20 ms each) against the game's current game_cycle, so no wall clock is needed.
-- `opts.now_ms` overrides the clock (milliseconds in the same space as cycle * 20).
function Combat.history(game, opts)
  opts = opts or {}
  local now = opts.now_ms or function() return game:clocks().game_cycle * CYCLE_MS end
  return setmetatable({ _by = {}, _now = now }, History)
end

local function key(target_type, index) return target_type .. ":" .. index end

-- Record one decoded hitmark event (botwithus.events); anything else is ignored.
function History:record(ev)
  if ev.name ~= "hitmark" then return end
  local k = key(ev.target_type, ev.target_index)
  local list = self._by[k] or {}
  self._by[k] = list
  list[#list + 1] = ev
  local cutoff = self._now() - History.RETENTION_MS
  while #list > History.PER_ENTITY_CAPACITY or (#list > 0 and list[1].cycle * CYCLE_MS < cutoff) do
    table.remove(list, 1)
  end
end

-- Record every hitmark among `events` (game:poll_events()'s list); returns `events`.
function History:feed(events)
  for _, ev in ipairs(events or {}) do self:record(ev) end
  return events
end

-- The hitmarks on (target_type, index) within the last `within_ms` (default the retention).
-- target_type is Events.TARGET_PLAYER (0) or Events.TARGET_NPC (1).
function History:recent(target_type, index, within_ms)
  local list = self._by[key(target_type, index)]
  if list == nil then return {} end
  local cutoff = self._now() - (within_ms or History.RETENTION_MS)
  local out = {}
  for _, ev in ipairs(list) do
    if ev.cycle * CYCLE_MS >= cutoff then out[#out + 1] = ev end
  end
  return out
end

-- The damage dealt to (target_type, index) within `within_ms`.
function History:damage_within(target_type, index, within_ms)
  local total = 0
  for _, ev in ipairs(self:recent(target_type, index, within_ms)) do total = total + ev.damage end
  return total
end

function History:clear() self._by = {} end

Combat.History = History
return Combat
