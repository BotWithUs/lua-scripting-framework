-- botwithus.skills -- the local player's skills, by name.
--
--   local wc = game:skill("woodcutting")      -- or game:skill(Skills.WOODCUTTING)
--   if wc and wc.level >= 60 then ... end
--
-- Each row: skill_id, name, xp, level (the true level) and boosted_level (the current level,
-- boosts and drains included).
--
-- WHERE THE IDS COME FROM. The agent publishes the game's StatType id and no name. The table
-- below mirrors the sibling hosts' (the Python framework's table, itself mirrored
-- from the Java host's Skills.java). It is not read from the cache. A live read of a real account
-- reported 29 skills, ATTACK..NECROMANCY, which matches it. If the game adds or reorders a
-- skill, every copy of this table is wrong until edited: treat a surprising level as a reason to
-- re-check the id.

local Skills = {}

local ORDER = {
  "attack", "defence", "strength", "constitution", "ranged", "prayer", "magic", "cooking",
  "woodcutting", "fletching", "fishing", "firemaking", "crafting", "smithing", "mining",
  "herblore", "agility", "thieving", "slayer", "farming", "runecrafting", "hunter",
  "construction", "summoning", "dungeoneering", "divination", "invention", "archaeology",
  "necromancy",
}

local BY_NAME = {}
for i, name in ipairs(ORDER) do
  local id = i - 1
  Skills[name:upper()] = id
  BY_NAME[name] = id
end

-- The lower-case name of skill `id`, or nil for an id this table does not know.
function Skills.name(id) return ORDER[id + 1] end

-- The id for a name (any case), or the id itself; nil when unknown.
function Skills.id(which)
  if math.type(which) == "integer" then return which end
  if type(which) == "string" then return BY_NAME[which:lower()] end
  return nil
end

-- Adds `name` to each row of bwu.skills (nil for an id this table does not know).
function Skills.named(rows)
  for _, row in ipairs(rows) do row.name = Skills.name(row.skill_id) end
  return rows
end

-- The row for `which` (an id or a name) in `rows`, or nil.
function Skills.find(rows, which)
  local id = Skills.id(which)
  if id == nil then
    error("botwithus: unknown skill " .. tostring(which), 3)
  end
  for _, row in ipairs(rows) do
    if row.skill_id == id then return row end
  end
  return nil
end

return Skills
