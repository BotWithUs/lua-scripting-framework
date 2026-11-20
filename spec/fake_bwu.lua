-- spec/fake_bwu.lua -- an injectable stand-in for the native `bwu` global.
--
-- Lets the whole API be exercised with no game client and no native host: install it
-- as _G.bwu, drive the facade, assert. Mirrors the shapes native-scripting-host's
-- host_surface.c returns.

local M = {}

-- Build a fresh fake and return it (does not install it globally).
local function copy_tile_or_nil(t)
  return t and { x = t.x, y = t.y, plane = t.plane } or nil
end

function M.new(opts)
  opts = opts or {}
  local state = {
    pids   = opts.pids or { 4242 },
    tick   = opts.tick or 1000,
    seq    = 5000000,
    self_  = opts.self_ or { valid = true, tile = { x = 3200, y = 3200, plane = 0 },
                             server_index = 1000, combat_level = 126, health = 990, max_health = 990,
                             orientation = 4096, run_energy = 73, run_weight = 12,
                             server_tile = { x = 3203, y = 3200, plane = 0 } },   -- walking east
    npcs_  = opts.npcs_ or {
      { server_index = 55, type_id = 1234, tile = { x = 3201, y = 3201, plane = 0 }, health_ratio = 255,
        orientation = 12288, active_type_id = 1234, combat_level = 12 },
      { server_index = 56, type_id = 1234, tile = { x = 3205, y = 3205, plane = 0 }, health_ratio = 128,
        orientation = -1, active_type_id = -1, combat_level = 12 },     -- morph hides it
      { server_index = 57, type_id = 9999, tile = { x = 3202, y = 3200, plane = 0 }, health_ratio = -1,
        orientation = 8191, active_type_id = 11476, combat_level = 41 }, -- morphed
    },
    players_ = opts.players_ or {
      { server_index = 1000, tile = { x = 3200, y = 3200, plane = 0 }, animation_id = -1, combat_level = 126,
        orientation = 4096, name = "Me", name_truncated = false,
        server_tile = { x = 3203, y = 3200, plane = 0 } },
      { server_index = 1001, tile = { x = 3210, y = 3200, plane = 0 }, animation_id = 808, combat_level = 90,
        orientation = 0, name = "Sir\xC2\xA0Test", name_truncated = false,    -- U+00A0, raw
        server_tile = { x = 3210, y = 3200, plane = 0 } },
      { server_index = 1002, tile = { x = 3220, y = 3200, plane = 0 }, animation_id = -1, combat_level = 3,
        orientation = -1, name = "", name_truncated = false,               -- not decoded yet
        server_tile = { x = -1, y = -1, plane = -1 } },                    -- unreadable
    },
    -- flags: 0x1 hidden, 0x2 combined section, 0x4 deleted (BWU_LOC_FLAG_*)
    locs_  = opts.locs_ or {
      { id = 1276, resolved_id = 1276, tile = { x = 3203, y = 3200, plane = 0 }, shape = 10, rotation = 1, flags = 0 },
      { id = 1530, resolved_id = 1530, tile = { x = 3201, y = 3200, plane = 0 }, shape = 0,  rotation = 3, flags = 0 },
      { id = 1276, resolved_id = 1276, tile = { x = 3199, y = 3200, plane = 0 }, shape = 10, rotation = 0, flags = 0x1 },
      { id = 1276, resolved_id = 1276, tile = { x = 3198, y = 3200, plane = 0 }, shape = 10, rotation = 0, flags = 0x4 },
      { id = 125195, resolved_id = 125205, tile = { x = 3210, y = 3210, plane = 0 }, shape = 10, rotation = 2, flags = 0x2 },
    },
    -- BWU_OPEN_IFACE_TYPE_*: 0 modal, 1 overlay, 3 CS2-opened child
    open_ifaces_ = opts.open_ifaces_ or {
      { id = 1477, type = 1, client_opened = false, is_modal = false },
      { id = 517,  type = 0, client_opened = false, is_modal = true },
      { id = 1432, type = 3, client_opened = true,  is_modal = false },
    },
    open_iface_total = opts.open_iface_total,   -- nil: the row count
    actions = {},   -- recorded queue_action calls
    batches = {},   -- recorded queue_actions calls, one list per call
    queue_accept = opts.queue_accept,  -- nil: queue_actions takes every action (an old agent's prefix)
    queue_error = opts.queue_error,    -- set: queue_actions returns nil, queue_error, queue_outcome
    -- the third value: "refused" (default) or "unknown"; false plays a bwu_host without it
    queue_outcome = opts.queue_outcome == nil and "refused" or opts.queue_outcome,
    queue_action_error = opts.queue_action_error,  -- set: queue_action returns false, it
    events = opts.events or {},        -- raw { type, body } records poll_events hands back once
    breaks = {},                       -- recorded schedule_break ms / "interrupt" calls
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
  local bwu = { PROTOCOL_VERSION = opts.protocol_version or 25, ABI_VERSION = opts.abi or 5, MAX_ACTION_BATCH = 128, _state = state,
                -- BWU_VARP_* / BWU_VAR_KIND_* as native-scripting-host exports them
                VARP_UNAVAILABLE = 0, VARP_DEFAULT_NOT_SET_CLIENTSIDE = 1, VARP_SET = 2,
                VARP_NO_SUCH_VARP = 3, VAR_KIND_UNKNOWN = -1, VAR_KIND_INT = 0, VAR_KIND_LONG = 1,
                VAR_KIND_STRING = 2, VAR_NO_VALUE = -1,
                OPEN_IFACE_TYPE_MODAL = 0, OPEN_IFACE_TYPE_OVERLAY = 1, OPEN_IFACE_TYPE_CHILD = 3,
                OPEN_IFACE_TYPE_UNKNOWN = 7 }

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
  -- A row as the native embed hands it over: a fresh table, tiles copied, every other field
  -- as the fixture has it (so an ABI 5 field is there only when the fixture sets it).
  local function copy_row(r)
    local out = {}
    for k, v in pairs(r) do out[k] = type(v) == "table" and copy_tile_or_nil(v) or v end
    return out
  end
  function bwu.self(_) return copy_row(state.self_) end
  function bwu.npcs(_)
    local out = {}
    for i, n in ipairs(state.npcs_) do out[i] = copy_row(n) end
    return out
  end
  local function copy_tile(t) return { x = t.x, y = t.y, plane = t.plane } end
  function bwu.players(_)
    local out = {}
    for i, p in ipairs(state.players_) do out[i] = copy_row(p) end
    return out
  end
  -- player_appearance: opts.appearances maps server_index -> reply table, or -> a string
  -- code the agent refuses with (returned as nil, code, like the native embed).
  state.appearances = opts.appearances or {}
  state.appearance_calls = {}
  function bwu.player_appearance(_, idx)
    state.appearance_calls[#state.appearance_calls + 1] = idx
    local a = state.appearances[idx]
    if a == nil then return nil, "no_player" end
    if type(a) == "string" then return nil, a end
    return a
  end
  -- The v25 entity reads. opts.overhead_texts and opts.headbars map "<kind>:<index>" -> reply
  -- table, or -> a string code the agent refuses with; an unlisted target is not_found.
  -- opts.hint_arrows is the reply list, or a string code.
  state.overhead_texts = opts.overhead_texts or {}
  state.headbars = opts.headbars or {}
  state.hint_arrows = opts.hint_arrows or { truncated = false }
  state.entity_calls = {}
  local function entity_reply(replies, kind, index)
    state.entity_calls[#state.entity_calls + 1] = { kind = kind, index = index }
    local reply = replies[kind .. ":" .. tostring(index)]
    if reply == nil then return nil, "not_found" end
    if type(reply) == "string" then return nil, reply end
    return reply
  end
  function bwu.overhead_text(_, kind, index) return entity_reply(state.overhead_texts, kind, index) end
  function bwu.headbars(_, kind, index) return entity_reply(state.headbars, kind, index) end
  function bwu.hint_arrows(_)
    if type(state.hint_arrows) == "string" then return nil, state.hint_arrows end
    local out = { truncated = state.hint_arrows.truncated }
    for i, a in ipairs(state.hint_arrows) do
      local row = {}
      for k, v in pairs(a) do row[k] = v end
      out[i] = row
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
  function bwu.open_ifaces(_)
    local out = {}
    for i, r in ipairs(state.open_ifaces_) do
      out[i] = { id = r.id, type = r.type, client_opened = r.client_opened, is_modal = r.is_modal }
    end
    return out, state.open_iface_total or #out
  end
  function bwu.queue_action(_, id, p1, p2, p3)
    if state.queue_action_error then return false, state.queue_action_error end
    state.actions[#state.actions + 1] = { id = id, p1 = p1, p2 = p2, p3 = p3 }
    return true
  end
  -- Batched queue: records every action in order (into `actions` too) and the batch
  -- itself. `queue_accept` caps how many the fake agent takes, as an agent older than
  -- all-or-nothing queue_actions did; `queue_error` plays a refused or failed call.
  function bwu.queue_actions(_, list)
    if state.queue_error then
      state.batches[#state.batches + 1] = list
      if state.queue_outcome == false then return nil, state.queue_error end
      return nil, state.queue_error, state.queue_outcome
    end
    local accepted = math.min(#list, state.queue_accept or #list)
    local batch = {}
    for i, a in ipairs(list) do
      batch[i] = { id = a.id, p1 = a.p1 or 0, p2 = a.p2 or 0, p3 = a.p3 or 0 }
      if i <= accepted then state.actions[#state.actions + 1] = batch[i] end
    end
    state.batches[#state.batches + 1] = batch
    return accepted
  end
  function bwu.poll_events(_)
    local out = state.events
    state.events = {}
    return out
  end
  if not opts.no_breaks then
    function bwu.schedule_break(_, ms)
      state.breaks[#state.breaks + 1] = ms
      return true
    end
    function bwu.interrupt_break(_)
      state.breaks[#state.breaks + 1] = "interrupt"
      return true
    end
  end
  function bwu.varc_int(_, id) return state.varcs[id] or -1 end
  function bwu.varc_string(_, id) return state.varc_strings[id] or "" end
  -- Walk plan options: every walk / path records the options table it got (`opts`, nil when
  -- none was passed). opts.no_walk_options leaves walk_options_supported out (a bwu_host that
  -- predates options); opts.cannot_exclude plays a worldwalker.dll without the _opts pair,
  -- raising the host's refusal for a non-empty exclude.
  local function take_options(name, o)
    if o ~= nil and opts.cannot_exclude and o.exclude ~= nil and #o.exclude > 0 then
      error("bwu." .. name .. ": this worldwalker.dll has no ww_executor_run_opts /"
            .. " ww_query_opts: cannot exclude transitions; update worldwalker.dll", 0)
    end
  end
  if not opts.no_walk_options then
    function bwu.walk_options_supported(_) return not opts.cannot_exclude end
  end
  function bwu.walk(_, x, y, plane, radius, o)
    take_options("walk", o)
    state.walks[#state.walks + 1] = { x = x, y = y, plane = plane, radius = radius, opts = o }
    -- The real executor moves the player; the fake just lands them on the goal on arrival.
    if state.walk_arrives then
      state.self_.tile = { x = x, y = y, plane = plane }
      return true
    end
    return false, "did not arrive"
  end
  function bwu.walk_cancel(_) state.walk_cancelled = true end
  -- Walk progress, in the real binding's table shape (native-scripting-host's
  -- tests/bindings/walk_check.lua reads the same fields). opts.walk_progress is the result
  -- table (nil = never walked / refuses a start); opts.walk_events the event list.
  -- opts.no_walk_progress leaves these out, like a bwu_host that predates them.
  if not opts.no_walk_progress then
    state.walk_waits = {}
    local function copy_events(since)
      local out = {}
      for i = since + 1, #(opts.walk_events or {}) do out[#out + 1] = opts.walk_events[i] end
      return out
    end
    function bwu.walk_ex(_, x, y, plane, radius, o)
      take_options("walk_ex", o)
      state.walks[#state.walks + 1] = { x = x, y = y, plane = plane, radius = radius, opts = o }
      if opts.walk_progress == nil then return nil, "a walk is already running on this host" end
      local r = {}
      for k, v in pairs(opts.walk_progress) do r[k] = v end
      r.events = copy_events(0)
      return r
    end
    function bwu.walk_start(_, x, y, plane, radius, o)
      take_options("walk_start", o)
      state.walks[#state.walks + 1] = { x = x, y = y, plane = plane, radius = radius, opts = o }
      if opts.walk_progress == nil then return false, "a walk is already running on this host" end
      return true
    end
    function bwu.walk_status(_) return opts.walk_progress end
    function bwu.walk_wait(_, timeout_ms)
      state.walk_waits[#state.walk_waits + 1] = timeout_ms
      return opts.walk_progress
    end
    function bwu.walk_events(_, since) return copy_events(since or 0) end
  end
  local function var_read(fn)
    return function(_, ids)
      state.var_calls[#state.var_calls + 1] = { fn = fn, ids = ids }
      return state.var_reads(fn, ids)
    end
  end
  bwu.read_varps = var_read("read_varps")
  bwu.read_varbits = var_read("read_varbits")
  function bwu.varp_defaults_status() return state.defaults_status end
  -- local_health: opts.health is {current, max} (nil = unknown); opts.no_local_health leaves
  -- the function out, like a bwu_host that predates it.
  if not opts.no_local_health then
    state.health_calls = 0
    function bwu.local_health(_)
      state.health_calls = state.health_calls + 1
      if opts.health == nil then return nil end
      return opts.health[1], opts.health[2]
    end
  end
  state.paths = {}
  function bwu.path(_, x, y, plane, o)
    take_options("path", o)
    state.paths[#state.paths + 1] = { x = x, y = y, plane = plane, opts = o }
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

  -- The detach the host makes: its plugin-UI release (one ui.destroy_all on this host's own
  -- connection, when it used the ui) happens inside it, as the native host's detach does.
  local plain_detach = bwu.detach
  function bwu.detach(h)
    if bwu._ui then bwu._ui.host_release(h) end
    plain_detach(h)
  end

  if not opts.no_ui then M.install_ui(bwu) end
  if (opts.abi or 5) >= 5 then M.install_abi5(bwu, opts) end
  if opts.no_cm then return bwu end
  M.install_cm(bwu, opts)
  return bwu
end

-- Plugin UI (bwu.ui_*) -----------------------------------------------------------------------
--
-- The shapes the native host's bwu.ui_* Lua binding returns, over a toy agent that keeps the
-- agent's ui.* rules and refusal texts: per-connection ownership (a connection
-- is one attach's host table), Jagex handles usable only as parents and ui.get targets, the
-- forbidden props, category 0, the types and canvas ops not supported yet. A refusal returns
-- nil, text, "refused"; `ui.timeout = true` makes the next call return nil, "rpc_timeout",
-- "timeout", and `ui.stalled = true` every call (counted in ui.stalled_calls). Polls hand over
-- at most 32 events each, as the binding does. Test hooks: ui.game_destroy(handle, reason) plays the game taking a component
-- down (a "destroyed" event to its owner, and parent_gone for its children), ui.overflow(host, n).

local UI_FORBIDDEN = "ui: prop forbidden on agent components (no op, drag or target configuration)"
local UI_READ_ONLY = "ui: handle is a Jagex component: read-only, usable only as a parent or with ui.get"
local UI_UNKNOWN   = "ui: unknown handle (destroyed, invalidated or not yours)"
local UI_UNKNOWN_PARENT = "ui: unknown parent handle (destroyed, invalidated or not yours)"
M.UI_FORBIDDEN, M.UI_READ_ONLY, M.UI_UNKNOWN = UI_FORBIDDEN, UI_READ_ONLY, UI_UNKNOWN

local UI_TYPES = { line = 0, rectangle = 1, text = 2, canvas = 8, layer = 20 }
local UI_LATER_TYPES = { sprite = true, button = true, model = true, panel = true, grid = true,
                         input_field = true, check = true, slider = true, combo_field = true,
                         list = true }
local UI_FORBIDDEN_PROPS = { op_config = true, opConfig = true, ops = true, drag_config = true,
                             dragConfig = true, target = true, target_config = true,
                             targetConfig = true, swipe_config = true, pinch_config = true,
                             cursor_config = true, params_config = true, flag_restricted = true }
local UI_LATER_PROPS = { hidden = true, enabled = true, font = true, sprite = true }
local UI_PROPS = { x = "integer", y = "integer", width = "integer", height = "integer",
                   rgba = "integer", clickthrough = "boolean", line_width = "integer",
                   line_invert = "boolean", fill = "boolean", outline_thickness = "integer",
                   text = "string", x_parent_pc = "float", x_self_pc = "float",
                   y_parent_pc = "float", y_self_pc = "float", width_pc = "float",
                   height_pc = "float" }
local UI_CANVAS_ARGS = {
  line = { "x", "y", "end_x", "end_y", "thickness", "rgba" },
  outline = { "x", "y", "width", "height", "thickness", "rgba" },
  rect = { "x", "y", "width", "height", "rgba" },
  gradient_h = { "x", "y", "width", "height", "rgba_start", "rgba_end" },
  gradient_v = { "x", "y", "width", "height", "rgba_start", "rgba_end" },
  triangle = { "x0", "y0", "x1", "y1", "x2", "y2", "rgba" },
  clear = {}, undo = {},
}

-- A stalled agent (`ui.stalled = true`): every verb times out after this long, as the host's
-- rpc timeout would. The fake does not wait; it adds the time to ui.stalled_ms.
local UI_STALL_MS = 5000
-- The most events one bwu.ui_poll_events call hands over (the binding's batch).
local UI_POLL_BATCH = 32
M.UI_POLL_BATCH = UI_POLL_BATCH

-- ---- host ABI 5: the typed reads, rpc_raw and snapshot_bytes ----
-- opts.skills / inventories (inv id -> list of {item_id, quantity}, one per slot) /
-- ground_items / projectiles / game_state / login_state / world / account replace the
-- defaults below. A session read given a string plays the agent refusing with that code.
-- opts.rpc maps method -> function(params) returning the reply (or nil, code); an unlisted
-- method is nil, "unknown_method". Every rpc_raw call is recorded in bwu._abi5.rpc_calls.
local function abi5_defaults(opts)
  return {
    skills = opts.skills or {
      { skill_id = 8, xp = 1234567, level = 72, boosted_level = 70 },
      { skill_id = 14, xp = 101333, level = 50, boosted_level = 52 },
    },
    inventories = opts.inventories or {
      [93] = { { item_id = 1511, quantity = 1 }, { item_id = 995, quantity = 1000 },
               { item_id = 1511, quantity = 1 }, { item_id = -1, quantity = 0 } },
      [94] = { { item_id = -1, quantity = 0 }, { item_id = 1351, quantity = 1 } },
    },
    ground_items = opts.ground_items or {
      { item_id = 526, quantity = 1, tile = { x = 3202, y = 3200, plane = 0 } },
      { item_id = 995, quantity = 50, tile = { x = 3210, y = 3200, plane = 0 } },
    },
    projectiles = opts.projectiles or {
      { projectile_id = 1234, start_cycle = 5000, end_cycle = 5060, source_index = 55,
        source_type = 1, target_index = 1000, target_type = 0,
        start_tile = { x = 3201, y = 3201, plane = 0 }, end_tile = { x = 3200, y = 3200, plane = 0 } },
    },
    game_state = opts.game_state or { game_state = 30, root_iface_id = 1477, own_index = 1000,
                                      scene_version = 42 },
    login_state = opts.login_state or { state = 30, login_progress = 7, login_status = 2 },
    world = opts.world or 84,
    account = opts.account or { display_name = "Me", jx_display_name = "", account_name = "acct",
                                account_uuid = "dev_uuid", logged_in = true, is_member = true,
                                game_state = 30, text_truncated = 0 },
    rpc = opts.rpc or {},
    rpc_calls = {},
  }
end

local function session_reply(v)
  if type(v) == "string" then return nil, v end
  return v
end

function M.install_abi5(bwu, opts)
  local st = abi5_defaults(opts)
  bwu._abi5 = st
  bwu.INV_BACKPACK, bwu.INV_EQUIPMENT, bwu.INV_BANK = 93, 94, 95
  function bwu.skills(_) return st.skills end
  function bwu.inventories(_)
    local out = {}
    for id, slots in pairs(st.inventories) do out[#out + 1] = { inv_id = id, slot_count = #slots } end
    table.sort(out, function(a, b) return a.inv_id < b.inv_id end)
    return out
  end
  function bwu.inventory(_, id)
    local slots = st.inventories[id]
    if slots == nil then return nil end
    local out = {}
    for i, s in ipairs(slots) do out[i] = { slot = i - 1, item_id = s.item_id, quantity = s.quantity } end
    return out
  end
  function bwu.ground_items(_)
    local out = {}
    for i, g in ipairs(st.ground_items) do
      out[i] = { item_id = g.item_id, quantity = g.quantity, tile = copy_tile_or_nil(g.tile) }
    end
    return out
  end
  function bwu.projectiles(_)
    local out = {}
    for i, p in ipairs(st.projectiles) do
      local row = {}
      for k, v in pairs(p) do row[k] = type(v) == "table" and copy_tile_or_nil(v) or v end
      out[i] = row
    end
    return out
  end
  function bwu.game_state(_) return st.game_state end
  function bwu.login_state(_) return session_reply(st.login_state) end
  function bwu.current_world(_) return session_reply(st.world) end
  function bwu.account_info(_) return session_reply(st.account) end
  function bwu.rpc_raw(_, method, params)
    st.rpc_calls[#st.rpc_calls + 1] = { method = method, params = params }
    local handler = st.rpc[method]
    if handler == nil then return nil, "unknown_method" end
    return handler(params)
  end
  function bwu.snapshot_bytes(_) return opts.snapshot_bytes or string.pack("<I8i4i4i4", 5000, 30, 1000, 1477) end
end

local function ui_type_ok(kind, v)
  if kind == "float" then return math.type(v) == "float" end
  if kind == "integer" then return math.type(v) == "integer" end
  return type(v) == kind
end

function M.install_ui(bwu)
  local ui = { next_handle = 100, comps = {}, calls = {}, events = {}, used = {},
               jagex = { ["1477:61"] = true }, timeout = false }
  bwu._ui = ui
  bwu.UI_KEY_STATIC, bwu.UI_DEFAULT, bwu.UI_CANVAS_OPS_MAX, bwu.UI_LIST_MAX = -1, -1, 128, 256

  local function record(fn, ...) ui.calls[#ui.calls + 1] = { fn = fn, args = { ... } } end
  local function refuse(text) return nil, text, "refused" end
  local function info(c)
    return { handle = c.handle, parent = c.parent, type = c.type, type_name = c.type_name,
             iface = c.iface, comp = c.comp, key = c.key, jagex = c.jagex,
             quarantined = false, truncated = false }
  end
  local function owned(h, handle) local c = ui.comps[handle]; return c and c.owner == h and c or nil end
  local function push(h, ev)
    ui.events[h] = ui.events[h] or {}
    table.insert(ui.events[h], ev)
  end
  -- The common start of every verb: the host marks the connection used, and the toy agent may
  -- play a timeout.
  local function begin(fn, h, ...)
    record(fn, h, ...)
    ui.used[h] = true
    if ui.timeout then ui.timeout = false; return false end
    if ui.stalled then
      ui.stalled_calls = (ui.stalled_calls or 0) + 1
      ui.stalled_ms = (ui.stalled_ms or 0) + UI_STALL_MS   -- what a real call would block
      return false
    end
    return true
  end
  local function check_props(c, props)
    for k, v in pairs(props or {}) do
      if UI_FORBIDDEN_PROPS[k] then return UI_FORBIDDEN end
      if UI_LATER_PROPS[k] then return "ui prop not supported yet: " .. k end
      local kind = UI_PROPS[k]
      if not kind then return "ui: unknown prop" end
      if not ui_type_ok(kind, v) then return "ui: prop value has the wrong type or is out of range" end
      if (k == "line_width" or k == "line_invert") and c.type_name ~= "line" then
        return "ui: line_width / line_invert apply to line components only"
      end
      if k == "text" and c.type_name ~= "text" then return "ui: text applies to text components only" end
    end
    return nil
  end
  local function apply(c, props)
    for k, v in pairs(props or {}) do c.props[k] = v end
  end
  -- Remove a component and (as the game does) its children, which are announced to their owner
  -- as parent_gone. With `reason`, the component itself is announced too.
  local function remove(handle, reason)
    local c = ui.comps[handle]
    if not c then return 0 end
    ui.comps[handle] = nil
    if reason then
      push(c.owner, { handle = handle, hook = "destroyed", reason = reason, truncated = false })
    end
    local n = 1
    for h2, child in pairs(ui.comps) do
      if child.parent == handle then n = n + remove(h2, "parent_gone") end
    end
    return n
  end
  local function timed_out() return nil, "rpc_timeout", "timeout" end

  function bwu.ui_get_component(h, iface, comp, key)
    if not begin("ui_get_component", h, iface, comp, key) then return timed_out() end
    local found
    if key == nil or key < 0 then
      if not ui.jagex[iface .. ":" .. comp] then return refuse("ui: component not found") end
    else
      for _, c in pairs(ui.comps) do
        if not c.jagex and c.iface == iface and c.comp == comp and c.key == key then found = c end
      end
      if not found then return refuse("ui: component not found") end
    end
    local want_key = (key == nil or key < 0) and -1 or key
    for _, c in pairs(ui.comps) do
      if c.jagex and c.owner == h and c.iface == iface and c.comp == comp and c.key == want_key then
        return info(c)
      end
    end
    local handle = ui.next_handle
    ui.next_handle = handle + 1
    ui.comps[handle] = { handle = handle, owner = h, parent = 0, jagex = true, iface = iface,
                         comp = comp, key = want_key, type = found and found.type or 20,
                         type_name = found and found.type_name or "layer", props = {} }
    return info(ui.comps[handle])
  end

  function bwu.ui_create(h, parent, type_name, props, opts)
    if not begin("ui_create", h, parent, type_name, props, opts) then return timed_out() end
    local p = owned(h, parent)
    if not p then return refuse(UI_UNKNOWN_PARENT) end
    if UI_LATER_TYPES[type_name] then return refuse("ui type not supported yet: " .. type_name) end
    if not UI_TYPES[type_name] then return refuse("ui: unknown type") end
    opts = opts or {}
    if opts.category == 0 then return refuse("ui: bad_param category (1..234)") end
    local c = { owner = h, parent = parent, jagex = false, iface = p.iface, comp = p.comp,
                type = UI_TYPES[type_name], type_name = type_name, props = {}, elements = {} }
    local why = check_props(c, props)
    if why then return refuse(why) end
    local handle = ui.next_handle
    ui.next_handle = handle + 1
    c.handle = handle
    c.key = 0x1000 + handle   -- opaque here: the agent computes it
    apply(c, props)
    ui.comps[handle] = c
    return info(c)
  end

  -- The handle a verb that edits may act on, or nil and the refusal.
  local function editable(h, handle)
    local c = owned(h, handle)
    if c and c.jagex then return nil, UI_READ_ONLY end
    if not c then return nil, UI_UNKNOWN end
    return c
  end

  function bwu.ui_set(h, handle, props)
    if not begin("ui_set", h, handle, props) then return timed_out() end
    local c, err = editable(h, handle)
    if not c then return refuse(err) end
    local why = check_props(c, props)
    if why then return refuse(why) end
    apply(c, props)
    return true
  end

  function bwu.ui_get(h, handle, with_content)
    if not begin("ui_get", h, handle, with_content) then return timed_out() end
    local c = owned(h, handle)
    if not c then return refuse(UI_UNKNOWN) end
    local r, pr, t = info(c), c.props, c.type_name
    r.x, r.y, r.width, r.height = pr.x or 0, pr.y or 0, pr.width or 0, pr.height or 0
    r.rgba = pr.rgba or 0xFFFFFFFF
    r.visible, r.restricted, r.clickthrough = true, false, pr.clickthrough or false
    r.num_elements = t == "canvas" and #c.elements or -1
    r.line_width = t == "line" and (pr.line_width or 1) or -1
    r.line_invert = t == "line" and (pr.line_invert and 1 or 0) or -1
    r.fill = t == "rectangle" and (pr.fill and 1 or 0) or -1
    r.outline_thickness = t == "rectangle" and (pr.outline_thickness or 1) or -1
    r.use_count, r.op_flags_read, r.op_mask, r.op_target = 2, true, 0, -1
    if with_content then
      if t ~= "text" then return refuse("ui: content is readable on text components only") end
      r.content, r.content_truncated = pr.text or "", false
    end
    return r
  end

  local function check_op(op)
    if op.op == "text" or op.op == "sprite" then return "ui canvas op not supported yet (text / sprite)" end
    local args = UI_CANVAS_ARGS[op.op]
    if not args then return "ui.canvas: unknown op" end
    local n = 0
    for k, v in pairs(op) do
      if k ~= "op" then
        n = n + 1
        if math.type(v) ~= "integer" then return "ui.canvas: op arguments are integers" end
      end
    end
    if n ~= #args then return "ui.canvas: wrong arguments for op" end
    for _, a in ipairs(args) do
      if op[a] == nil then return "ui.canvas: wrong arguments for op" end
    end
    return nil
  end

  function bwu.ui_canvas(h, handle, ops)
    if type(ops) ~= "table" or #ops < 1 or #ops > bwu.UI_CANVAS_OPS_MAX then
      error("bad argument #3 to 'ui_canvas' (1..128 ops)", 2)
    end
    if not begin("ui_canvas", h, handle, ops) then return timed_out() end
    local c, err = editable(h, handle)
    if not c then return refuse(err) end
    if c.type_name ~= "canvas" then return refuse("ui: handle is not a canvas") end
    for _, op in ipairs(ops) do
      local why = check_op(op)
      if why then return refuse(why) end   -- nothing applied
    end
    for _, op in ipairs(ops) do
      if op.op == "clear" then c.elements = {}
      elseif op.op == "undo" then table.remove(c.elements)
      else c.elements[#c.elements + 1] = op end
    end
    return #c.elements
  end

  function bwu.ui_order(h, handle, to)
    if not begin("ui_order", h, handle, to) then return timed_out() end
    local c, err = editable(h, handle)
    if not c then return refuse(err) end
    if to ~= "front" and to ~= "back" then return refuse("ui: bad_param to") end
    c.order = to
    return true
  end

  function bwu.ui_destroy(h, handle)
    if not begin("ui_destroy", h, handle) then return timed_out() end
    local c, err = editable(h, handle)
    if not c then return refuse(err) end
    remove(handle, nil)
    return true
  end

  local function drop_all(h)
    local n = 0
    for handle, c in pairs(ui.comps) do
      if c.owner == h then
        if not c.jagex then n = n + 1 end
        ui.comps[handle] = nil
      end
    end
    return n
  end

  function bwu.ui_destroy_all(h)
    if not begin("ui_destroy_all", h) then return timed_out() end
    return drop_all(h)
  end

  function bwu.ui_list(h)
    if not begin("ui_list", h) then return timed_out() end
    local out = {}
    for _, c in pairs(ui.comps) do
      if c.owner == h then out[#out + 1] = info(c) end
    end
    table.sort(out, function(a, b) return a.handle < b.handle end)
    return out
  end

  function bwu.ui_poll_events(h)
    ui.polls = (ui.polls or 0) + 1
    if ui.poll_error then error("bwu.ui_poll_events: " .. ui.poll_error, 2) end
    local queued = ui.events[h] or {}
    local list = {}
    while #list < UI_POLL_BATCH and #queued > 0 do list[#list + 1] = table.remove(queued, 1) end
    ui.events[h] = queued
    return list
  end

  -- Test hooks ------------------------------------------------------------------------------
  function ui.game_destroy(handle, reason) return remove(handle, reason or "removed") end
  function ui.overflow(h, n)
    push(h, { handle = 0, hook = "overflow", reason = "", truncated = false, dropped = n })
  end
  -- What the host does at detach: one ui.destroy_all on this host's own connection, if it used
  -- the ui. Counts what it found left.
  function ui.host_release(h)
    if not ui.used[h] then return end
    record("host_release", h)
    ui.host_released = (ui.host_released or 0) + drop_all(h)
  end
  -- The calls of one bwu.ui_* function, in order.
  function ui.calls_of(fn)
    local out = {}
    for _, c in ipairs(ui.calls) do
      if c.fn == fn then out[#out + 1] = c end
    end
    return out
  end
  -- How many non-Jagex components a connection owns.
  function ui.live(h)
    local n = 0
    for _, c in pairs(ui.comps) do
      if c.owner == h and not c.jagex then n = n + 1 end
    end
    return n
  end
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
  CM_EV_NATIVE_UPDATE_AVAILABLE = 13, CM_EV_NATIVE_UPDATE_APPLIED = 14,
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

-- Add a stand-in for the host's run control (bwu.ctl_*) to a fake, in the shapes the native
-- Lua binding has: ctl_describe -> config | nil, err; ctl_state -> true | nil, err;
-- ctl_wait -> "timeout" | "stop"; ctl_stopping -> boolean; ctl_take_config -> id, cfg | nil;
-- ctl_config_done -> nothing. A wrong argument type raises, as luaL_check* does.
--   opts.mode              "worker" (default), "describe" or "cli"
--   opts.stop_after_waits  set stop on the n-th ctl_wait (that wait returns "stop")
--   opts.stopping          start with stop already set
--   opts.refuse_after_stop ctl_state(attaching|running) after a stop returns nil, err (a
--                          host without the stop-during-start rule), instead of a no-op
-- b._ctl records describes, waits (their ms), dones and takes, and `states`: every state
-- frame the worker would send, in order, including the host's own `stopping`.
-- b._ctl.stop() plays a GUI stop: the host sets the stop flag and sends `stopping` (once).
-- After that, ctl_state(attaching|running|stopping) is a no-op returning true.
-- b._ctl.push(id, cfg) queues a config change.
local Config = require("botwithus.config")

local MODES = { cli = 0, worker = 1, describe = 2 }
local PHASES = { attaching = true, running = true, stopping = true }
local UINT32_MAX = 4294967295

-- The describe checks the binding and the host make, reduced to what the specs need.
local function check_desc(desc)
  if type(desc) ~= "table" then error("bad argument #1 to 'ctl_describe' (table expected)", 2) end
  if desc.self_running ~= nil and type(desc.self_running) ~= "boolean" then
    return nil, "self_running: expected a boolean"
  end
  local ok, err = Config.validate_manifest(desc.manifest)
  if ok then ok, err = Config.validate_fields(desc.config_schema) end
  return ok, err
end

-- The legal framework-reported transitions, from the last sent phase.
local function legal(rec, phase)
  local last = rec.states[#rec.states]
  if rec.stopped then return false end
  if phase == "attaching" then return last == nil and not rec.self_running end
  if phase == "running" then
    return last == "attaching" or (last == nil and rec.self_running == true)
  end
  return false
end

function M.with_ctl(b, opts)
  opts = opts or {}
  local rec = { describes = {}, states = {}, waits = {}, dones = {}, takes = 0, queue = {},
                stopping = opts.stopping or false, running = false }
  b._ctl = rec
  b.CTL_CLI, b.CTL_WORKER, b.CTL_DESCRIBE = MODES.cli, MODES.worker, MODES.describe
  local mode = MODES[opts.mode or "worker"]
  function rec.stop()
    rec.stopping = true
    if mode == MODES.worker and not rec.stopped then
      rec.states[#rec.states + 1] = "stopping"
      rec.stopped, rec.host_stopped = true, true
    end
  end
  function rec.push(id, cfg) rec.queue[#rec.queue + 1] = { id = id, cfg = cfg } end
  rec.stopping = false
  if opts.stopping then rec.stop() end

  function b.ctl_mode() return mode end
  function b.ctl_describe(desc)
    rec.describes[#rec.describes + 1] = desc
    if #rec.describes > 1 then return nil, "ctl_describe: called twice" end
    local ok, err = check_desc(desc)
    if not ok then return nil, err end
    rec.self_running = desc.self_running == true
    local cfg = Config.defaults(desc.config_schema)
    for k, v in pairs(opts.initial or {}) do cfg[k] = v end
    return cfg
  end
  function b.ctl_state(phase)
    if type(phase) ~= "string" then error("bad argument #1 to 'ctl_state' (string expected)", 2) end
    if not PHASES[phase] then return nil, "ctl_state: unknown phase " .. phase end
    if mode ~= MODES.worker then return true end
    if rec.host_stopped then
      if opts.refuse_after_stop and phase ~= "stopping" then
        return nil, "ctl_state: illegal transition to " .. phase
      end
      return true   -- after the host's stopping: a no-op
    end
    if phase == "stopping" then
      if not rec.stopped then rec.states[#rec.states + 1] = "stopping" end
      rec.stopped = true
      return true
    end
    if not legal(rec, phase) then return nil, "ctl_state: illegal transition to " .. phase end
    rec.states[#rec.states + 1] = phase
    if phase == "running" then rec.running = true end
    return true
  end
  function b.ctl_wait(ms)
    if math.type(ms) ~= "integer" or ms < 0 or ms > UINT32_MAX then
      error("bad argument #1 to 'ctl_wait' (number has no integer representation)", 2)
    end
    rec.waits[#rec.waits + 1] = ms
    if mode ~= MODES.cli and opts.stop_after_waits and #rec.waits >= opts.stop_after_waits then
      rec.stop()
    end
    if mode ~= MODES.cli and rec.stopping then return "stop" end
    return "timeout"
  end
  function b.ctl_stopping() return mode ~= MODES.cli and rec.stopping end
  function b.ctl_take_config()
    if mode ~= MODES.worker or not rec.running or #rec.queue == 0 then return nil end
    rec.takes = rec.takes + 1
    local change = table.remove(rec.queue, 1)
    return change.id, change.cfg
  end
  function b.ctl_config_done(id, ok, message)
    if math.type(id) ~= "integer" then error("bad argument #1 to 'ctl_config_done' (number expected)", 2) end
    rec.dones[#rec.dones + 1] = { id = id, ok = ok and true or false, message = message }
  end
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
