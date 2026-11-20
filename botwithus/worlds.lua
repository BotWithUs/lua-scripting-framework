-- botwithus.worlds -- the world list (game:world_list()) and the four world flags the agent
-- has resolved.
--
--   local list = game:world_list()            -- nil, code on a refusal
--   if not list.is_fetched then ... end        -- empty: the game has not fetched it yet
--   local w = Worlds.find(list, 84)
--   if w and not w.members then game:hop_world(84) end
--
-- Each row carries id, flags (raw), activity, location_id, location_name, population and ping
-- (ping is a hypothesis on the agent side and has read 0 on every world), plus the decoded
-- booleans members, skill_total, classic_only and eoc_only. The other flag bits are unresolved:
-- read `flags` raw for them.

local Worlds = {}

-- The bits resolved live on client 951-4 (NXTLibrary PUBLIC_PROTOCOL.md 6.2.1).
Worlds.FLAG_MEMBERS      = 0x1
Worlds.FLAG_SKILL_TOTAL  = 0x80
Worlds.FLAG_CLASSIC_ONLY = 0x400000
Worlds.FLAG_EOC_ONLY     = 0x800000

local function has(flags, bit) return (flags & bit) ~= 0 end

-- Adds the decoded booleans to one row, in place; returns it.
function Worlds.decorate(w)
  w.members      = has(w.flags, Worlds.FLAG_MEMBERS)
  w.skill_total  = has(w.flags, Worlds.FLAG_SKILL_TOTAL)
  w.classic_only = has(w.flags, Worlds.FLAG_CLASSIC_ONLY)
  w.eoc_only     = has(w.flags, Worlds.FLAG_EOC_ONLY)
  return w
end

-- Decorates every row of a world_list reply and sets is_fetched; returns it.
function Worlds.decorate_list(list)
  for _, w in ipairs(list.worlds) do Worlds.decorate(w) end
  list.is_fetched = #list.worlds > 0
  return list
end

-- The row for `id`, or nil.
function Worlds.find(list, id)
  for _, w in ipairs(list.worlds) do
    if w.id == id then return w end
  end
  return nil
end

return Worlds
