-- spec/fake_bwu.lua -- an injectable stand-in for the native `bwu` global.
--
-- Lets the whole API be exercised with no game client and no native host: install it
-- as _G.bwu, drive the facade, assert. Mirrors the shapes native-scripting-host's
-- host_surface.c returns.

local M = {}

-- Build a fresh fake and return it (does not install it globally).
function M.new(opts)
  opts = opts or {}
  local state = {
    pids   = opts.pids or { 4242 },
    tick   = opts.tick or 1000,
    seq    = 5000000,
    self_  = opts.self_ or { valid = true, tile = { x = 3200, y = 3200, plane = 0 },
                             server_index = 1000, combat_level = 126, health = 990, max_health = 990 },
    npcs_  = opts.npcs_ or {
      { server_index = 55, type_id = 1234, tile = { x = 3201, y = 3201, plane = 0 }, health_ratio = 255 },
      { server_index = 56, type_id = 1234, tile = { x = 3205, y = 3205, plane = 0 }, health_ratio = 128 },
      { server_index = 57, type_id = 9999, tile = { x = 3202, y = 3200, plane = 0 }, health_ratio = -1 },
    },
    actions = {},   -- recorded queue_action calls
    walks   = {},   -- recorded walk() calls (executor)
    walk_arrives = (opts.walk_arrives ~= false),  -- what walk() returns
    walk_cancelled = false,
  }
  local bwu = { PROTOCOL_VERSION = 19, _state = state }

  function bwu.discover_pids() return state.pids end
  function bwu.attach(pid) return { pid = pid } end
  function bwu.detach(_) end
  function bwu.refresh(_) state.tick = state.tick + 1; state.seq = state.seq + 30; return true end
  function bwu.clocks(_) return { server_tick = state.tick, game_cycle = state.tick * 30, publish_seq = state.seq } end
  function bwu.self(_)
    local s = state.self_
    return { valid = s.valid, tile = { x = s.tile.x, y = s.tile.y, plane = s.tile.plane },
             server_index = s.server_index, combat_level = s.combat_level,
             health = s.health, max_health = s.max_health }
  end
  function bwu.npcs(_)
    local out = {}
    for i, n in ipairs(state.npcs_) do
      out[i] = { server_index = n.server_index, type_id = n.type_id,
                 tile = { x = n.tile.x, y = n.tile.y, plane = n.tile.plane },
                 health_ratio = n.health_ratio }
    end
    return out
  end
  function bwu.queue_action(_, id, p1, p2, p3)
    state.actions[#state.actions + 1] = { id = id, p1 = p1, p2 = p2, p3 = p3 }
    return true
  end
  function bwu.walk(_, x, y, plane, radius)
    state.walks[#state.walks + 1] = { x = x, y = y, plane = plane, radius = radius }
    -- The real executor moves the player; the fake just lands them on the goal on arrival.
    if state.walk_arrives then
      state.self_.tile = { x = x, y = y, plane = plane }
      return true
    end
    return false, "did not arrive"
  end
  function bwu.walk_cancel(_) state.walk_cancelled = true end
  function bwu.path(_, x, y, plane)
    -- straight-line steps from self toward (x,y), matching the native stub's shape
    local sx, sy = state.self_.tile.x, state.self_.tile.y
    local steps, cx, cy = {}, sx, sy
    while (cx ~= x or cy ~= y) and #steps < 64 do
      if cx < x then cx = cx + 1 elseif cx > x then cx = cx - 1 end
      if cy < y then cy = cy + 1 elseif cy > y then cy = cy - 1 end
      steps[#steps + 1] = { kind = 0, plane = plane or 0, x = cx, y = cy }
    end
    return steps
  end

  return bwu
end

return M
