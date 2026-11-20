-- botwithus.quests -- quest status, progress and unmet requirements (the Java host's
-- quest.QuestLog, QuestStatus, QuestStage and QuestRequirement).
--
--   local Quests = require("botwithus.quests")
--   local log = Quests.new(game)
--   local s = log:status(257)                    -- or log:status("Cook's Assistant")
--   print(s.name, s.stage, s.progress)           -- "Cook's Assistant", "started", 1
--   if not log:requirements_met(258) then
--     for _, r in ipairs(log:unmet_requirements(258)) do print(r.kind) end
--   end
--
-- A quest's stage comes from its first progress variable (varp or varbit) and that variable's
-- start / end values in the cache: "complete" at or above the end value, "started" AT OR ABOVE
-- the start value (not above it, as v1 had: Cook's Assistant is start 1, end 2, and under v1's
-- rule no value of its variable read "started"), else "not_started". "unknown" when the quest,
-- its variable or the variable's value cannot be read: never guessed.
--
-- STUBS. The cache holds unlisted stub records next to the real quests (6 and 132 are stubs of
-- Cook's Assistant 257 and Vampyre Slayer 258: same name, empty listName, no progress variable).
-- Asked about a stub, the log reads the listed quest of the same name instead. The name index
-- this needs is built once per log, only when a stub is asked about (or a quest by name), from the
-- quest ids the gameval index names (host ABI 8), as the Java host does; without a gameval index
-- it reads every quest id up to Quests.MAX_QUEST_ID instead, and says so once.
--
-- BY NAME. status("COOKS_ASSISTANT") takes a quest gameval name (the Java host's status(String));
-- a string that is not one is matched against the listed quests' display names.
--
-- Requirements: { kind = "skill", skill_id, required, actual }, { kind = "quest", quest_id },
-- { kind = "membership" }. Varp / varbit requirements and quest points are not checked: the cache
-- decoder skips the former, and the varp v1 read for quest points is PAGEPOS.

local Definitions = require("botwithus.definitions")
local G = require("botwithus.gameval")

local Quests = {}
Quests.__index = Quests

Quests.NOT_STARTED = "not_started"
Quests.STARTED = "started"
Quests.COMPLETE = "complete"
Quests.UNKNOWN = "unknown"
Quests.UNKNOWN_PROGRESS = -1
-- The highest quest id the fallback scan looks at.
Quests.MAX_QUEST_ID = 1024
-- How many quest gamevals the index lists at most (the Java host's MAX_QUESTS).
Quests.MAX_QUESTS = 4096

function Quests.new(game) return setmetatable({ _game = game, _types = {}, _listed = nil }, Quests) end

-- A quest definition (decoded JSON), or nil (missing id, or no cache). Each id is read once.
function Quests:_type(id)
  local hit = self._types[id]
  if hit == nil then
    local ok, q = pcall(Definitions.quest, id)
    hit = ok and q or false
    self._types[id] = hit
  end
  return hit or nil
end

local function is_listed(q) return type(q.listName) == "string" and q.listName ~= "" end

local warned_scan = false

-- name -> the first listed quest id with that name: the gameval index's quest ids in name order,
-- else (no index) every id up to MAX_QUEST_ID.
function Quests:_listed_by_name()
  if self._listed then return self._listed end
  local index = {}
  local rows = G.starting_with("quest", "", Quests.MAX_QUESTS)
  local ids = {}
  for i, row in ipairs(rows) do ids[i] = row.id end
  if #ids == 0 then
    if not warned_scan then
      warned_scan = true
      local _, why = G.available()
      io.stderr:write(("[botwithus.quests] no quest ids from the gameval index (%s); scanning ids\n")
        :format(tostring(why or "no quest names")))
    end
    for id = 0, Quests.MAX_QUEST_ID do ids[#ids + 1] = id end
  end
  for _, id in ipairs(ids) do
    local q = self:_type(id)
    if q and is_listed(q) and index[q.name] == nil then index[q.name] = id end
  end
  self._listed = index
  return index
end

-- The listed twin of a stub, else the quest itself.
function Quests:_prefer_listed(q)
  if is_listed(q) then return q end
  local listed = self:_listed_by_name()[q.name]
  if listed == nil or listed == q.id then return q end
  return self:_type(listed) or q
end

-- An entry of a progress / requirement list: the cache's [a, b, c] array, or a map.
local function triple(entry, k1, k2, k3)
  if entry[1] ~= nil then return entry[1], entry[2], entry[3] end
  return entry[k1], entry[k2], entry[k3]
end

-- A quest's progress variables: { {kind = "varp"|"varbit", id, start_value, end_value}, ... },
-- varps first.
function Quests.progress_vars(q)
  local out = {}
  for _, spec in ipairs({ { "varp", q.progressVarps }, { "varbit", q.progressVarbits } }) do
    for _, entry in ipairs(spec[2] or {}) do
      local id, start_value, end_value = triple(entry, "id", "threshold1", "threshold2")
      if math.type(id) == "integer" and math.type(start_value) == "integer"
        and math.type(end_value) == "integer" then
        out[#out + 1] = { kind = spec[1], id = id, start_value = start_value, end_value = end_value }
      end
    end
  end
  return out
end

function Quests.stage_of(var, value)
  if value >= var.end_value then return Quests.COMPLETE end
  return value >= var.start_value and Quests.STARTED or Quests.NOT_STARTED
end

-- A quest id from an id or a quest name (the listed quest's display name, ignoring case).
function Quests:_id_of(which)
  if math.type(which) == "integer" then return which end
  if type(which) ~= "string" then return nil end
  local by_gameval = G.id("quest", which)
  if by_gameval ~= nil then return by_gameval end
  local want = which:lower()
  for name, id in pairs(self:_listed_by_name()) do
    if name:lower() == want then return id end
  end
  return nil
end

local function unknown(id, name)
  return { quest_id = id, name = name or "", stage = Quests.UNKNOWN,
           progress = Quests.UNKNOWN_PROGRESS, variable = nil }
end

function Quests:_read(var)
  local read = var.kind == "varp" and self._game:read_varp(var.id) or self._game:read_varbit(var.id)
  if read == nil or not read.has_value then return nil end
  return read.value
end

-- { quest_id, name, stage, progress, variable }: see the module comment.
function Quests:status(which)
  local id = self:_id_of(which)
  local q = id and self:_type(id)
  if q == nil then return unknown(id or -1, type(which) == "string" and which or "") end
  q = self:_prefer_listed(q)
  local vars = Quests.progress_vars(q)
  if #vars == 0 then return unknown(q.id, q.name) end
  local value = self:_read(vars[1])
  if value == nil then return unknown(q.id, q.name) end
  return { quest_id = q.id, name = q.name, stage = Quests.stage_of(vars[1], value),
           progress = value, variable = vars[1] }
end

function Quests:is_started(which)
  local stage = self:status(which).stage
  return stage == Quests.STARTED or stage == Quests.COMPLETE
end

function Quests:is_complete(which) return self:status(which).stage == Quests.COMPLETE end
function Quests:progress(which) return self:status(which).progress end

-- What the player still lacks for a quest (see the module comment); {} for an unknown quest.
function Quests:unmet_requirements(which)
  local id = self:_id_of(which)
  local q = id and self:_type(id)
  if q == nil then return {} end
  q = self:_prefer_listed(q)
  local unmet = {}
  if q.membersOnly and self._game:self().is_member == false then
    unmet[#unmet + 1] = { kind = "membership" }
  end
  for _, entry in ipairs(q.skillRequirements or {}) do
    local skill, level = triple(entry, "skill", "level")
    if math.type(skill) == "integer" and math.type(level) == "integer" then
      local ok, row = pcall(self._game.skill, self._game, skill)
      local actual = ok and row and row.level or 0
      if actual < level then
        unmet[#unmet + 1] = { kind = "skill", skill_id = skill, required = level, actual = actual }
      end
    end
  end
  for _, prior in ipairs(q.dependentQuestIds or {}) do
    if not self:is_complete(prior) then unmet[#unmet + 1] = { kind = "quest", quest_id = prior } end
  end
  return unmet
end

function Quests:requirements_met(which) return #self:unmet_requirements(which) == 0 end

return Quests
