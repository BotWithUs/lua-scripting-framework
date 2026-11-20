-- botwithus.changes -- inventory and skill changes, derived once per server tick (the Java
-- host's InventoryChangeEvent, SkillChangeEvent and SnapshotChangeDetector).
--
--   local Changes = require("botwithus.changes")
--   local watch = Changes.new(game)
--   -- each loop:
--   for _, ev in ipairs(watch:poll()) do
--     if ev.name == "inventory_change" and ev.is_added then ... end
--     if ev.name == "skill_change" and ev.is_level_up then ... end
--   end
--
-- The agent sends no such events: they are the difference between two server ticks' readings,
-- taken by this module. poll() takes a reading only when server_tick has moved since the last
-- one, and compares it with that last one, so polling every loop costs one read per tick.
-- Changes between two polls further apart than a tick come out together, stamped with the
-- later tick.
--
-- An inventory that was not published at the previous reading is taken as a silent baseline
-- (opening the bank does not flood you with a "change" per bank slot), and leaving the game
-- (game_state not 30) drops the baseline altogether.
--
-- Events:
--   inventory_change  { inv_id, slot, old = {item_id, quantity}, new = {item_id, quantity},
--                       server_tick, is_added, is_removed, quantity_delta }
--   skill_change      { skill_id, old_xp, new_xp, old_level, new_level, old_boosted,
--                       new_boosted, server_tick, xp_gained, levels_gained, is_level_up }

local Changes = {}
Changes.__index = Changes

local IN_GAME = 30
local EMPTY = { item_id = -1, quantity = 0 }

function Changes.new(game) return setmetatable({ _game = game, _previous = nil }, Changes) end

-- One reading: { tick, inventories = { [id] = { {item_id, quantity}, ... } }, skills = { [id] = row } },
-- or nil when not in the game.
function Changes:_capture()
  local game = self._game
  if game:game_state().game_state ~= IN_GAME then return nil end
  local reading = { tick = game:server_tick(), inventories = {}, skills = {} }
  for _, inv in ipairs(game:inventories()) do
    local view = game:inventory(inv.inv_id)
    if view:is_present() then
      local slots = {}
      for i, row in ipairs(view:slots()) do slots[i] = { item_id = row.item_id, quantity = row.quantity } end
      reading.inventories[inv.inv_id] = slots
    end
  end
  for _, s in ipairs(game:skills()) do
    reading.skills[s.skill_id] = { xp = s.xp, level = s.level, boosted_level = s.boosted_level }
  end
  return reading
end

local function same(a, b) return a.item_id == b.item_id and a.quantity == b.quantity end

local function inventory_event(inv_id, slot, was, now, tick)
  local delta
  if was.item_id == now.item_id then delta = now.quantity - was.quantity
  elseif now.item_id < 0 then delta = -was.quantity
  else delta = now.quantity end
  return { name = "inventory_change", inv_id = inv_id, slot = slot, old = was, new = now,
           server_tick = tick, is_added = was.item_id < 0 and now.item_id >= 0,
           is_removed = was.item_id >= 0 and now.item_id < 0, quantity_delta = delta }
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function inventory_changes(before, after, out)
  for _, inv_id in ipairs(sorted_keys(after.inventories)) do
    local old, now = before.inventories[inv_id], after.inventories[inv_id]
    if old ~= nil then
      for slot = 1, math.max(#old, #now) do
        local was, is = old[slot] or EMPTY, now[slot] or EMPTY
        if not same(was, is) then out[#out + 1] = inventory_event(inv_id, slot - 1, was, is, after.tick) end
      end
    end
  end
end

local function skill_changes(before, after, out)
  for _, id in ipairs(sorted_keys(after.skills)) do
    local was, now = before.skills[id], after.skills[id]
    if was ~= nil and (was.xp ~= now.xp or was.level ~= now.level or was.boosted_level ~= now.boosted_level) then
      out[#out + 1] = { name = "skill_change", skill_id = id, old_xp = was.xp, new_xp = now.xp,
                        old_level = was.level, new_level = now.level,
                        old_boosted = was.boosted_level, new_boosted = now.boosted_level,
                        server_tick = after.tick, xp_gained = now.xp - was.xp,
                        levels_gained = now.level - was.level, is_level_up = now.level > was.level }
    end
  end
end

-- The changes since the previous reading, or {} when the tick has not moved (or this is the
-- first reading, or the player is not in the game).
function Changes:poll()
  local game = self._game
  local prev = self._previous
  if prev ~= nil and game:server_tick() == prev.tick then return {} end
  local now = self:_capture()
  self._previous = now
  local out = {}
  if now == nil or prev == nil then return out end
  inventory_changes(prev, now, out)
  skill_changes(prev, now, out)
  return out
end

-- Forget the baseline: the next poll takes a fresh one.
function Changes:reset() self._previous = nil end

return Changes
