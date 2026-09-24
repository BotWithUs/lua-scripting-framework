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
                             server_index = 1000, combat_level = 126, health = 990, max_health = 990,
                             orientation = 4096 },
    npcs_  = opts.npcs_ or {
      { server_index = 55, type_id = 1234, tile = { x = 3201, y = 3201, plane = 0 }, health_ratio = 255,
        orientation = 12288 },
      { server_index = 56, type_id = 1234, tile = { x = 3205, y = 3205, plane = 0 }, health_ratio = 128,
        orientation = -1 },
      { server_index = 57, type_id = 9999, tile = { x = 3202, y = 3200, plane = 0 }, health_ratio = -1,
        orientation = 8191 },
    },
    players_ = opts.players_ or {
      { server_index = 1000, tile = { x = 3200, y = 3200, plane = 0 }, animation_id = -1, combat_level = 126,
        orientation = 4096 },
      { server_index = 1001, tile = { x = 3210, y = 3200, plane = 0 }, animation_id = 808, combat_level = 90,
        orientation = 0 },
    },
    -- flags: 0x1 hidden, 0x2 combined section, 0x4 deleted (BWU_LOC_FLAG_*)
    locs_  = opts.locs_ or {
      { id = 1276, resolved_id = 1276, tile = { x = 3203, y = 3200, plane = 0 }, shape = 10, rotation = 1, flags = 0 },
      { id = 1530, resolved_id = 1530, tile = { x = 3201, y = 3200, plane = 0 }, shape = 0,  rotation = 3, flags = 0 },
      { id = 1276, resolved_id = 1276, tile = { x = 3199, y = 3200, plane = 0 }, shape = 10, rotation = 0, flags = 0x1 },
      { id = 1276, resolved_id = 1276, tile = { x = 3198, y = 3200, plane = 0 }, shape = 10, rotation = 0, flags = 0x4 },
      { id = 125195, resolved_id = 125205, tile = { x = 3210, y = 3210, plane = 0 }, shape = 10, rotation = 2, flags = 0x2 },
    },
    actions = {},   -- recorded queue_action calls
    batches = {},   -- recorded queue_actions calls, one list per call
    queue_accept = opts.queue_accept,  -- nil: queue_actions takes every action
    varcs = opts.varcs or {},                -- varc id -> int
    varc_strings = opts.varc_strings or {},  -- varc id -> string
    walks   = {},   -- recorded walk() calls (executor)
    walk_arrives = (opts.walk_arrives ~= false),  -- what walk() returns
    walk_cancelled = false,
  }
  local bwu = { PROTOCOL_VERSION = 21, ABI_VERSION = 2, MAX_ACTION_BATCH = 128, _state = state }

  function bwu.discover_pids() return state.pids end
  function bwu.attach(pid) return { pid = pid } end
  function bwu.detach(_) end
  function bwu.refresh(_) state.tick = state.tick + 1; state.seq = state.seq + 30; return true end
  function bwu.clocks(_) return { server_tick = state.tick, game_cycle = state.tick * 30, publish_seq = state.seq } end
  function bwu.self(_)
    local s = state.self_
    return { valid = s.valid, tile = { x = s.tile.x, y = s.tile.y, plane = s.tile.plane },
             server_index = s.server_index, combat_level = s.combat_level,
             health = s.health, max_health = s.max_health, orientation = s.orientation }
  end
  function bwu.npcs(_)
    local out = {}
    for i, n in ipairs(state.npcs_) do
      out[i] = { server_index = n.server_index, type_id = n.type_id,
                 tile = { x = n.tile.x, y = n.tile.y, plane = n.tile.plane },
                 health_ratio = n.health_ratio, orientation = n.orientation }
    end
    return out
  end
  local function copy_tile(t) return { x = t.x, y = t.y, plane = t.plane } end
  function bwu.players(_)
    local out = {}
    for i, p in ipairs(state.players_) do
      out[i] = { server_index = p.server_index, tile = copy_tile(p.tile),
                 animation_id = p.animation_id, combat_level = p.combat_level,
                 orientation = p.orientation }
    end
    return out
  end
  function bwu.locations(_)
    local out = {}
    for i, o in ipairs(state.locs_) do
      out[i] = { id = o.id, resolved_id = o.resolved_id, tile = copy_tile(o.tile),
                 shape = o.shape, rotation = o.rotation, flags = o.flags }
    end
    return out
  end
  function bwu.queue_action(_, id, p1, p2, p3)
    state.actions[#state.actions + 1] = { id = id, p1 = p1, p2 = p2, p3 = p3 }
    return true
  end
  -- Batched queue: records every action in order (into `actions` too) and the batch
  -- itself. `queue_accept` caps how many the fake agent takes, like a full agent queue.
  function bwu.queue_actions(_, list)
    local accepted = math.min(#list, state.queue_accept or #list)
    local batch = {}
    for i, a in ipairs(list) do
      batch[i] = { id = a.id, p1 = a.p1 or 0, p2 = a.p2 or 0, p3 = a.p3 or 0 }
      if i <= accepted then state.actions[#state.actions + 1] = batch[i] end
    end
    state.batches[#state.batches + 1] = batch
    return accepted
  end
  function bwu.varc_int(_, id) return state.varcs[id] or -1 end
  function bwu.varc_string(_, id) return state.varc_strings[id] or "" end
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
