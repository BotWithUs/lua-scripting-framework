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
    -- var_reads(fn_name, ids) -> list of records, or (nil, err) for a failed read
    var_reads = opts.var_reads or function(_, _) return {} end,
    var_calls = {},
    defaults_status = opts.defaults_status or 1,
  }
  local bwu = { PROTOCOL_VERSION = 21, ABI_VERSION = 2, MAX_ACTION_BATCH = 128, _state = state,
                -- BWU_VARP_* / BWU_VAR_KIND_* as native-scripting-host exports them
                VARP_UNAVAILABLE = 0, VARP_DEFAULT_NOT_SET_CLIENTSIDE = 1, VARP_SET = 2,
                VARP_NO_SUCH_VARP = 3, VAR_KIND_UNKNOWN = -1, VAR_KIND_INT = 0, VAR_KIND_LONG = 1,
                VAR_KIND_STRING = 2, VAR_NO_VALUE = -1 }

  state.attaches = {}   -- pids passed to attach(), in order
  state.detaches = {}   -- pids of handles passed to detach(), in order

  function bwu.discover_pids() return state.pids end
  function bwu.attach(pid)
    state.attaches[#state.attaches + 1] = pid
    if state.attach_error then return nil, state.attach_error end
    return { pid = pid }
  end
  function bwu.detach(h) state.detaches[#state.detaches + 1] = h.pid end
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
  local function var_read(fn)
    return function(_, ids)
      state.var_calls[#state.var_calls + 1] = { fn = fn, ids = ids }
      return state.var_reads(fn, ids)
    end
  end
  bwu.read_varps = var_read("read_varps")
  bwu.read_varbits = var_read("read_varbits")
  function bwu.varp_defaults_status() return state.defaults_status end
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

  if opts.no_cm then return bwu end
  M.install_cm(bwu, opts)
  return bwu
end

-- The client-management constants, as the native header defines them.
M.CM_CONSTANTS = {
  CM_SURFACE_VERSION = 1,
  CM_ID_MAX = 64, CM_NAME_MAX = 64, CM_TEXT_MAX = 256, CM_SHA_MAX = 72,
  CM_STATE_QUEUED = 1, CM_STATE_SPAWNING = 2, CM_STATE_INJECTING = 3, CM_STATE_INJECTED = 4,
  CM_STATE_FAILED = 5, CM_STATE_EXITED = 6,
  CM_KIND_JAGEX = 1, CM_KIND_STEAM = 2, CM_KIND_ATTACHED = 3,
  CM_ORIGIN_UI = 1, CM_ORIGIN_AUTOMATION = 2,
  CM_LIC_OK = 1, CM_LIC_RETRYING = 2, CM_LIC_DROPPED = 3, CM_LIC_UNTRACKED = 4,
  CM_EXIT_STOPPED = 1, CM_EXIT_LICENCE = 2, CM_EXIT_DESCRIPTOR = 3, CM_EXIT_UNKNOWN = 4,
  CM_STOP_GRACEFUL = 1, CM_STOP_KILL = 2,
  CM_ACK_CLOSING = 1, CM_ACK_DECLINED = 2, CM_ACK_LATER = 3,
  CM_EV_CLIENT_STARTED = 1, CM_EV_CLIENT_STATE = 2, CM_EV_CLIENT_EXITED = 3,
  CM_EV_AGENT_UPDATED = 4, CM_EV_DATA_UPDATE_AVAILABLE = 5, CM_EV_DATA_UPDATE_APPLIED = 6,
  CM_EV_CLOSE_REQUESTED = 7, CM_EV_LICENCE_STATE = 8, CM_EV_SERVICE_SHUTTING_DOWN = 9,
  CM_EV_SERVICE_LOST = 10, CM_EV_SERVICE_RESTORED = 11, CM_EV_EVENTS_DROPPED = 12,
}

-- The cm_* functions, with the native binding's shapes: a failure is nil, code, message;
-- every event carries all nine fields, 0 or "" where unused; is_agent_stale is a boolean.
-- Test controls live on bwu._cm:
--   down       nil when the service is up, else the code calls fail with
--   refuse     method name -> wire code the service answers with (e.g. launch = "rate_limited")
--   retry_after_ms   what cm_last_retry_after_ms() reports after a refused launch
--   on_poll    function(cm) run when a poll finds the queue empty (to script a sequence)
-- and records what was sent: launches, stops, acks, polls (the timeouts), clients_calls.
function M.install_cm(bwu, opts)
  for k, v in pairs(M.CM_CONSTANTS) do bwu[k] = v end
  local cm = {
    accounts = opts.accounts or { { id = "acct-1", name = "Main" }, { id = "acct-2", name = "Alt" } },
    clients = opts.clients or {}, events = {}, next_id = 1, last_retry = -1,
    launches = {}, stops = {}, acks = {}, polls = {}, clients_calls = 0,
    refuse = {}, retry_after_ms = -1, down = nil, on_poll = nil,
  }
  bwu._cm = cm

  local function fail(method)
    local code = cm.down or cm.refuse[method]
    if not code then return nil end
    cm.last_retry = (code == "rate_limited") and cm.retry_after_ms or -1
    return code
  end

  -- Queue an event, filling every field the binding always sets.
  function cm.push(fields)
    local ev = { kind = 0, pid = 0, state = 0, exit_code = 0, reason = 0, hosts_blocking = 0,
                 request_id = 0, client_id = "", text = "" }
    for k, v in pairs(fields) do ev[k] = v end
    cm.events[#cm.events + 1] = ev
  end

  -- A client record with every field the binding sets.
  function cm.client(fields)
    local c = { client_id = "", account_id = "acct-1", account_name = "Main", pid = 0,
                character_index = -1, kind = 1, origin = 2, state = 1, licence_state = 1,
                licence_failures = 0, is_agent_stale = false, restart_of = 0,
                started_at_ms = 1700000000000, agent_sha = "" }
    for k, v in pairs(fields) do c[k] = v end
    return c
  end

  function bwu.cm_accounts()
    local code = fail("accounts")
    if code then return nil, code, "accounts: " .. code end
    local out = {}
    for i, a in ipairs(cm.accounts) do out[i] = { id = a.id, name = a.name } end
    return out
  end
  function bwu.cm_launch(account_id, character_index)
    local code = fail("launch")
    if code then return nil, code, "launch: " .. code end
    local id = "c" .. cm.next_id
    cm.next_id = cm.next_id + 1
    cm.launches[#cm.launches + 1] = { account_id = account_id, character_index = character_index or -1, client_id = id }
    return id
  end
  function bwu.cm_last_retry_after_ms() return cm.last_retry end
  function bwu.cm_stop(client_id, mode)
    mode = mode or bwu.CM_STOP_GRACEFUL
    if mode ~= bwu.CM_STOP_GRACEFUL and mode ~= bwu.CM_STOP_KILL then
      return nil, "bad_argument", "bad stop mode"
    end
    local code = fail("stop")
    if code then return nil, code, "stop: " .. code end
    cm.stops[#cm.stops + 1] = { client_id = client_id, mode = mode }
    return true
  end
  function bwu.cm_clients()
    cm.clients_calls = cm.clients_calls + 1
    local code = fail("clients")
    if code then return nil, code, "clients: " .. code end
    local out = {}
    for i, c in ipairs(cm.clients) do
      local copy = {}
      for k, v in pairs(c) do copy[k] = v end
      out[i] = copy
    end
    return out
  end
  -- The real poll keeps working while the service is down: it waits on the host's queue.
  function bwu.cm_poll_event(timeout_ms)
    cm.polls[#cm.polls + 1] = timeout_ms or 0
    if #cm.events == 0 and cm.on_poll then cm.on_poll(cm) end
    if #cm.events == 0 then return nil end
    return table.remove(cm.events, 1)
  end
  function bwu.cm_ack_close(request_id, decision)
    if request_id <= 0 or decision < bwu.CM_ACK_CLOSING or decision > bwu.CM_ACK_LATER then
      return nil, "bad_argument", "bad ack"
    end
    local code = fail("ack_close")
    if code then return nil, code, "ack_close: " .. code end
    cm.acks[#cm.acks + 1] = { request_id = request_id, decision = decision }
    return true
  end
end

-- Add a recording stand-in for the native run log (bwu.runlog_*) to a fake. The real sink,
-- redactor and traceback parsing are native (tested in native-scripting-host); this records
-- what the Lua runner hands them. b._runlog holds opens, crumbs, crashes, writes and closes.
function M.with_runlog(b)
  local rec = { opens = {}, crumbs = {}, crashes = {}, writes = {}, closes = {}, next_id = 7 }
  b._runlog = rec
  b.LOG_DEBUG, b.LOG_INFO, b.LOG_WARN, b.LOG_ERROR = 10, 20, 30, 40
  b.runlog_open = function(info)
    rec.opens[#rec.opens + 1] = info
    rec.next_id = rec.next_id + 1
    return rec.next_id
  end
  b.runlog_crumb = function(kind, detail) rec.crumbs[#rec.crumbs + 1] = kind .. " " .. detail end
  b.runlog_crash = function(c)
    rec.crashes[#rec.crashes + 1] = c
    return #rec.crashes == 1   -- the native side keeps only a run's first crash block
  end
  b.runlog_write = function(level, logger, msg)
    rec.writes[#rec.writes + 1] = { level = level, logger = logger, msg = msg }
  end
  b.runlog_close = function(id) rec.closes[#rec.closes + 1] = id end
  return b
end

-- One record in the shape bwu.read_varps / read_varbits returns.
function M.var_record(id, state, value, opts)
  opts = opts or {}
  local verified = opts.verified
  if verified == nil then verified = true end
  return { id = id, state = state, value = value, value64 = opts.value64 or value,
           kind = opts.kind or -1, default_verified = verified }
end

return M
