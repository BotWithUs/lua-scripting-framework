-- botwithus.game -- an ergonomic facade over the native `bwu` table.
--
-- The native host installs a global `bwu` (see native-scripting-host). This module
-- resolves it lazily -- at call time, not load time -- so the unit suite can inject a
-- fake `bwu` before exercising the facade. Nothing here reaches the pipe or shared
-- memory directly; it all goes through the one host surface.

local Tile    = require("botwithus.tile")
local Actions = require("botwithus.actions")
local Orientation = require("botwithus.orientation")
local Variables = require("botwithus.variables")
local Events = require("botwithus.events")

-- Resolve the surface each call. `_G.bwu` is set by the host (or a test fake).
-- host(self), further down, is the guard every per-client call goes through.
local function surface()
  local b = rawget(_G, "bwu")
  if not b then error("botwithus: native `bwu` surface not present (run under bwu_host)", 2) end
  return b
end

local Game = {}
Game.__index = Game

-- The agent snapshot protocol this framework is written for. It moves in lockstep with
-- native-scripting-host's BWU_PROTOCOL_VERSION (and NXTLibrary's kProtocolVersion).
Game.PROTOCOL_VERSION = 25

-- Why a host built for another protocol is refused, or nil when it matches: the surface's
-- tables would not be the shapes this framework reads.
local function protocol_mismatch(b)
  if b.PROTOCOL_VERSION == Game.PROTOCOL_VERSION then return nil end
  return "botwithus: this framework is built for agent protocol v" .. Game.PROTOCOL_VERSION
    .. " but the native host speaks v" .. tostring(b.PROTOCOL_VERSION)
    .. "; update the framework and the host together"
end

-- Refuse a host built for another protocol before attaching.
local function require_protocol(b, level)
  local mismatch = protocol_mismatch(b)
  if mismatch then error(mismatch, level + 1) end
end

-- The client the GUI started this worker for (BWU_CLIENT_PID), or nil. Honoured only in a
-- GUI worker: on the command line the variable is ignored, so a value inherited from a shell
-- can never pick the client.
local function worker_client_pid(b)
  if not (b.ctl_mode and b.ctl_mode() == b.CTL_WORKER) then return nil end
  local pid = math.tointeger(tonumber(os.getenv("BWU_CLIENT_PID") or ""))
  if pid and pid > 0 then return pid end
  return nil
end

-- The pid Game.attach() picks when given none: in a GUI worker the client the GUI started
-- it for, otherwise the first discovered client.
-- `level` is the error level to blame when there is none (default: the caller).
function Game.attach_target(level)
  local b = surface()
  local chosen = worker_client_pid(b)
  if chosen then return chosen end
  local pid = b.discover_pids()[1]
  if not pid then error("botwithus: no game client to attach to", level or 2) end
  return pid
end

-- Attach to a client. With no pid, attaches to the one Game.attach_target picks.
function Game.attach(pid)
  local b = surface()
  require_protocol(b, 2)
  pid = pid or Game.attach_target(3)
  local host, err = b.attach(pid)
  if not host then error("botwithus: attach failed: " .. tostring(err), 2) end
  return setmetatable({ _host = host, _pid = pid }, Game)
end

-- Attach to `pid` without raising: a Game, or nil, code, message. The code is "error":
-- the native attach reports only a message.
function Game.try_attach(pid)
  local b = surface()
  local mismatch = protocol_mismatch(b)
  if mismatch then return nil, "error", mismatch end
  local host, err = b.attach(pid)
  if not host then return nil, "error", tostring(err) end
  return setmetatable({ _host = host, _pid = pid }, Game)
end

function Game:pid() return self._pid end

-- Why a detached Game stopped being attached.
Game.DETACHED_BY_SCRIPT = "detached by the script"

-- The handle for a surface call. A detached Game raises a clear error here instead of
-- handing a nil handle to the native surface.
local function host(self)
  if not self._host then
    error("botwithus: game is detached (" .. tostring(self._detached_reason) .. ")", 3)
  end
  return self._host
end

-- Whether this Game is still attached; when it is not, also returns why.
function Game:is_attached()
  if self._host then return true end
  return false, self._detached_reason
end

-- Detach from the client. Safe to call more than once.
function Game:detach()
  self:_release(Game.DETACHED_BY_SCRIPT)
end

-- Detach and record why. botwithus.clients calls this when the client's process is gone;
-- the Game then answers refresh() with (false, "detached", reason) and raises on reads.
function Game:_release(reason)
  if not self._host then return end
  surface().detach(self._host)
  self._host = nil
  self._detached_reason = reason
  local on_detach = self._on_detach
  self._on_detach = nil
  if on_detach then on_detach(self) end
end

-- Why a Game the framework released on its own stopped being attached: its client exited.
Game.DETACHED_EXITED = "the client exited"

-- Whether the host still lists `pid` as an attachable client.
local function listed(b, pid)
  for _, p in ipairs(b.discover_pids()) do
    if p == pid then return true end
  end
  return false
end

-- The client exit checks. A Game whose client has exited is marked, not released: the run
-- still calls on_stop with it, and reads then return the last frame. The runner releases it
-- afterwards (Game:_end_run).
--
-- Game:_exit_check(stalled) looks once. It returns
--   "gone"     the Game is detached or already marked, or its snapshot cannot be read and the
--              host no longer lists its pid: two independent signs, so the Game is marked now
--   "suspect"  the caller saw the server tick stand still for the stall bound (`stalled`) and
--              the host does not list the pid. That is what an exit looks like while the host
--              still holds a readable view of the mapping (frozen data), but one discovery
--              can miss a live client, so the caller confirms it with a second look later
--   nil        no sign of an exit: the snapshot reads and the tick is not stalled, or the
--              pid is listed (a stall while listed is the lobby or a frozen client)
-- Refreshes the snapshot as a side effect.
function Game:_exit_check(stalled)
  if self._exited or not self._host then return "gone" end
  local b = surface()
  local readable = b.refresh(self._host)
  if readable and not stalled then return nil end
  if listed(b, self._pid) then return nil end
  if readable then return "suspect" end
  self:_mark_exited()
  return "gone"
end

-- Whether this Game's client has exited, from one look (see _exit_check). A "suspect" is not
-- an exit here: only the runner's stall confirmation turns it into one.
function Game:_client_gone()
  return self:_exit_check(false) == "gone"
end

-- Record that this Game's client has exited.
function Game:_mark_exited()
  self._exited = true
end

-- The runner's end of a run: a Game whose client exited is released with DETACHED_EXITED
-- (whoever owns it), otherwise it is detached when the runner owns it.
function Game:_end_run(owned)
  if self._exited then
    self:_release(Game.DETACHED_EXITED)
  elseif owned then
    self:detach()
  end
end

-- Pull a fresh snapshot copy for this tick. Call once at the top of a loop iter.
-- On a detached Game it returns false, "detached", reason and touches nothing.
function Game:refresh()
  if not self._host then return false, "detached", self._detached_reason end
  return surface().refresh(self._host)
end

-- The three clocks. Only server_tick paces scripts; the other two are exposed
-- but deliberately never used for timing (see sleep_ticks in the runner).
function Game:clocks() return surface().clocks(host(self)) end
function Game:server_tick() return self:clocks().server_tick end

-- Facing (wire v21). The native surface hands over `orientation`: the raw client angle
-- 0..16383, or -1 when unknown (it has already turned any out-of-contract wire value into -1
-- and logged it once). Each row also gets `facing`, the nearest compass point name, and
-- `facing_degrees`, clockwise from north -- both nil when unknown. Compare two facings with
-- orientation.is_same_facing, never ==: the client can read an angle back one unit short.
local function with_facing(row)
  row.tile = Tile.from(row.tile)
  if row.server_tile then row.server_tile = Tile.from(row.server_tile) end
  local raw = row.orientation or Orientation.UNKNOWN_RAW
  row.orientation = raw
  row.facing = Orientation.compass(raw)
  row.facing_degrees = Orientation.degrees(raw)
  return row
end

-- The local player. Wire v24 adds:
--   run_energy  0..100 as the run orb shows it, or -1 when unknown (out of the world, or
--               unreadable on this client channel; the surface never passes the wire's
--               out-of-world 0 through as a real energy)
--   run_weight  kg as the client holds it, -1 when unknown. NOT independently verified by
--               the producer: one live check could not tell the offset from a wrong one.
--   server_tile (wire v25) where the server has told the client you are going: the newest
--               walk-queue step, or your logical position while the queue is empty. `tile` is
--               where you are drawn. It leads `tile` during a walk and both end on the same
--               tile; do not assume they are equal when idle, forced movement moves it first.
--               x, y and plane are -1 when unknown (out of the world, or unreadable, which is
--               normal on the beta client channel).
function Game:self()
  return with_facing(surface().self(host(self)))
end

-- NPC rows. type_id is the BASE id the server sent. Wire v24 adds:
--   active_type_id  the morph-resolved type: the one the client names, shows options for and
--                   takes the combat level from, so look a name up by this id. == type_id
--                   for an NPC with no morph; -1 when the morph resolves to nothing (the NPC
--                   is hidden). It is never replaced by type_id.
--   combat_level    the per-instance combat level the client shows
function Game:npcs()
  local raw = surface().npcs(host(self))
  for _, n in ipairs(raw) do with_facing(n) end
  return raw
end

-- Player rows. Wire v24 adds:
--   name            the display name exactly as the client holds it (at most 15 UTF-8
--                   bytes). "" until the client has decoded that player's appearance, which
--                   is normal for a player who just came into view. It can contain U+00A0
--                   (no-break space; the client makes it from cp1252 0xA0): compare names with
--                   botwithus.entities.names_equal or the query's :named(), never ==.
--   name_truncated  true when name is a prefix of a longer client name
-- Wire v25 adds server_tile, as on Game:self(). NPC rows do not carry it.
function Game:players()
  local raw = surface().players(host(self))
  for _, p in ipairs(raw) do with_facing(p) end
  return raw
end

-- The applied appearance of the loaded player at `server_index` (wire v24 RPC
-- get_player_appearance):
--   render_id         equals that player's snapshot stance id
--   npc_transform_id  -1 when the player is not transformed
--   gender            INFERRED (bit 0 of the appearance flags), raw: not 0 or 1 = a misread
--   slots             { {kit=, item=}, ... } in the CLIENT's order, NOT wearpos (a worn
--                     shortbow, wearpos 3, is slot 15 on client 951-1): match worn items by
--                     item id, never by index. Each slot carries one of kit / item, the
--                     other is -1. Unrendered items (ammo) are absent.
--   colours           colour indices 0..255 (10 on 951-1; may be empty)
-- Returns the table, or nil and the agent's code when it refuses: not_in_game, no_player,
-- appearance_not_loaded (normal for a player who just came into view),
-- bad_appearance_record, unsupported_on_client_channel, game_thread_timeout.
function Game:player_appearance(server_index)
  local b = surface()
  if type(b.player_appearance) ~= "function" then
    error("botwithus: this native host has no player_appearance (needs wire v24)", 2)
  end
  return b.player_appearance(host(self), server_index)
end

-- The v25 entity reads, on a host new enough to have them. `level` blames the script's call.
local function entity_read(name)
  local b = surface()
  local read = b[name]
  if type(read) ~= "function" then
    error("botwithus: this native host has no " .. name .. " (needs wire v25)", 3)
  end
  return read
end

-- The text above an entity (wire v25 RPC get_overhead_text). `kind` is "npc" or "player";
-- anything else raises. Returns:
--   { text =, expires_in_ms =, truncated = }  while the entity is speaking. text is UTF-8;
--                                             truncated is true when it was longer than
--                                             the 255 bytes kept
--   {}                                        when the entity is there and silent
--   nil, code                                 when the agent refuses: not_in_world, not_found,
--                                             channel_unsupported (normal on the beta client
--                                             channel), game_thread_timeout; or
--                                             rpc_timeout, the host's own code when the agent
--                                             did not answer at all
function Game:overhead_text(kind, index)
  return entity_read("overhead_text")(host(self), kind, index)
end

-- Every headbar entry on an entity (wire v25 RPC get_headbars), slot by slot, with no liveness
-- filter. `kind` as overhead_text. Each row:
--   headbar_id   gameval HEADBAR id: 0 HEALTH_DEFAULT, 7 ADRENALINE_DEFAULT; -1 has no type
--   value        the CURRENT value, 0..255. There is no value_end: this is it.
--   value_start  where the interpolation began, 0..255
--   start_cycle, duration   in game_cycle units (the ~20ms clock, not server_tick).
--                start_cycle can lie slightly ahead of game_cycle.
-- The list's `truncated` field is true when it is incomplete: the agent's walk stopped with
-- entries unread, so treat the rows as a partial list. An entity with no bars is an empty list.
-- Returns nil, code on refusal, as overhead_text.
function Game:headbars(kind, index)
  return entity_read("headbars")(host(self), kind, index)
end

-- Every hint arrow (wire v25 RPC query_hint_arrows), in the manager's slots and its owner tree.
-- Each row:
--   source        "slot" or "tree"; slot is 0..7 for a slot arrow, -1 for a tree arrow
--   type          1 npc, 2 tile centre, 3 west, 4 east, 5 south, 6 north, 7 corner, 10 player.
--                 type_name is the same as a name, type_id an alias for the query's :of_type()
--   target_type   "npc", "player", "tile" or "unknown"
--   target_index  the server index for npc and player arrows, otherwise -1
--   tile_x, tile_y, plane  the arrow's stored position. tile_x / tile_y are -1 when it is not
--                 a coordinate or reads tile (0,0), and plane is -1 when outside 0..3. An npc or
--                 player arrow can carry one too: use target_index for those, not this.
--   tile          a Tile for a tile arrow (target_type "tile") with a usable position, otherwise
--                 nil. An arrow on an entity never has one, so queries never rank it by position.
--   range_tiles   the arrow's view range
-- The list's `truncated` field is true when it is incomplete, as headbars. Returns nil, code on
-- refusal: not_in_world, channel_unsupported (normal on the beta client channel),
-- game_thread_timeout, or the host's rpc_timeout.
function Game:hint_arrows()
  local rows, code = entity_read("hint_arrows")(host(self))
  if not rows then return nil, code end
  for _, arrow in ipairs(rows) do
    arrow.type_id = arrow.type
    if arrow.target_type == "tile" and arrow.tile_x >= 0 and arrow.tile_y >= 0 and arrow.plane >= 0 then
      arrow.tile = Tile.new(arrow.tile_x, arrow.tile_y, arrow.plane)
    end
  end
  return rows
end

-- Location flag bits, mirroring BWU_LOC_FLAG_* on the native surface.
Game.LOC_FLAG_HIDDEN           = 0x1
Game.LOC_FLAG_COMBINED_SECTION = 0x2
Game.LOC_FLAG_DELETED          = 0x4

local function has_flag(flags, bit) return math.floor(flags / bit) % 2 == 1 end

-- Scene objects (scenery) that are on screen: hidden and deleted rows are dropped, the
-- same visibility rule the Java host's SceneObjects uses. Each row carries:
--   id / type_id  the loc id the server sent -- identity, hardcoded id sets, interaction
--   resolved_id   the morph-resolved id to look a name or options up by (== id if no morph)
--   shape         scenery shape code (wall, decoration, centrepiece...)
--   rotation      0..3 quarter turns of the loc's model. Relative to the model's own
--                 default pose, so it is NOT a compass heading.
-- type_id is an alias of id so the shared query's :of_type() works on objects too.
function Game:objects()
  local out = {}
  for _, o in ipairs(surface().locations(host(self))) do
    if not has_flag(o.flags, Game.LOC_FLAG_HIDDEN) and not has_flag(o.flags, Game.LOC_FLAG_DELETED) then
      o.tile = Tile.from(o.tile)
      o.type_id = o.id
      out[#out + 1] = o
    end
  end
  return out
end

-- Open-interface types (wire v23), mirroring BWU_OPEN_IFACE_TYPE_* on the native surface:
-- the client's raw open type, clamped. Observed on client 950-1: MODAL closes when the player
-- moves (the bank, dialogue), OVERLAY is a HUD panel or the XP popup, CHILD was opened by CS2
-- and closes with its parent, UNKNOWN means the raw type was above 6. Other values can appear.
Game.OPEN_IFACE_TYPE_MODAL   = 0
Game.OPEN_IFACE_TYPE_OVERLAY = 1
Game.OPEN_IFACE_TYPE_CHILD   = 3
Game.OPEN_IFACE_TYPE_UNKNOWN = 7

-- The open interfaces, in the agent's table order. Each row carries:
--   id             the interface id
--   type           Game.OPEN_IFACE_TYPE_*
--   client_opened  true when CS2 opened it
--   is_modal       true exactly when type is MODAL: decide modality on this
-- The second return is the client table's own size. It is 0 when the agent could not read
-- the table, and larger than #rows when the agent's list was truncated; only when it equals
-- #rows (and is not 0) does a missing id prove an interface is closed.
function Game:open_ifaces()
  return surface().open_ifaces(host(self))
end

function Game:is_interface_open(id)
  for _, row in ipairs(self:open_ifaces()) do
    if row.id == id then return true end
  end
  return false
end

-- The ids of the open modal interfaces (they close when the player moves).
function Game:modal_ifaces()
  local out = {}
  for _, row in ipairs(self:open_ifaces()) do
    if row.is_modal then out[#out + 1] = row.id end
  end
  return out
end

function Game:is_modal_open()
  return #self:modal_ifaces() > 0
end

-- Queue any action built by botwithus.actions (or a raw {id,p1,p2,p3}). Returns true, or
-- false and the host's error (e.g. "queue_action: queue_full"); an older bwu_host returns
-- false alone.
function Game:do_action(a)
  return surface().queue_action(host(self), a.id, a.p1 or 0, a.p2 or 0, a.p3 or 0)
end

-- queue_actions is all or nothing: the agent queues the whole batch or refuses the whole
-- batch and queues none of it. These are its refusal codes; the error names one of them.
Game.QUEUE_REFUSALS = { "batch_too_large", "queue_full", "action_id_required", "bad_param" }

-- What a failed :try_queue_actions says about the batch.
Game.QUEUED_NONE    = "none"      -- refused: not one action was queued; safe to retry
Game.QUEUED_UNKNOWN = "unknown"   -- the call failed (timeout, pipe gone): some may be queued
Game.QUEUED_PREFIX  = "prefix"    -- an agent older than all-or-nothing queued only a prefix

local DEFAULT_MAX_ACTION_BATCH = 128

-- The third value bwu.queue_actions returns with nil, err.
local HOST_REFUSED = "refused"   -- the host or the agent refused the batch: nothing queued
local HOST_UNKNOWN = "unknown"   -- timeout or transport failure: the outcome is unknown

local function refusal_code(err)
  local text = tostring(err)
  for _, code in ipairs(Game.QUEUE_REFUSALS) do
    if text:find(code, 1, true) then return code end
  end
  return nil
end

-- Queue a list of actions in order, in one round trip, without raising on failure.
--   #list                         every action was queued
--   nil, message, QUEUED_NONE     the batch was refused and nothing was queued
--   nil, message, QUEUED_UNKNOWN  the call failed; whether anything was queued is unknown
--   nil, message, QUEUED_PREFIX, n  (an old agent) only the first n were queued
-- At most bwu.MAX_ACTION_BATCH actions; a longer list is refused before anything is sent.
-- Malformed input still RAISES rather than returning: an entry that is not a table, an id
-- that is not an integer, or a field outside int32. Nothing is queued in those cases.
function Game:try_queue_actions(list)
  local b = surface()
  local cap = b.MAX_ACTION_BATCH or DEFAULT_MAX_ACTION_BATCH
  if #list > cap then
    return nil, ("a batch of %d actions is more than MAX_ACTION_BATCH (%d); nothing was queued")
      :format(#list, cap), Game.QUEUED_NONE
  end
  local n, err, outcome = b.queue_actions(host(self), list)
  if n == nil then
    -- The host says which it was: "refused" (nothing queued) or "unknown". A bwu_host that
    -- predates that third value leaves it nil; then the agent's refusal code in the message
    -- is the only sign that nothing was queued.
    local code = refusal_code(err)
    if outcome == HOST_REFUSED then
      return nil, ("the batch was refused (%s); nothing was queued"):format(code or tostring(err)),
        Game.QUEUED_NONE
    elseif outcome == HOST_UNKNOWN then
      code = nil
    end
    if code then
      return nil, ("the agent refused the batch (%s); nothing was queued"):format(code), Game.QUEUED_NONE
    end
    return nil, ("the call failed (%s); some or all of the actions may have been queued")
      :format(tostring(err)), Game.QUEUED_UNKNOWN
  end
  if n < #list then
    return nil, ("the agent queued %d of %d actions, a prefix: it predates all-or-nothing"
      .. " queue_actions"):format(n, #list), Game.QUEUED_PREFIX, n
  end
  return n
end

-- Queue a list of actions in order, in one round trip. All or nothing: returns #list when
-- every action was queued, and otherwise raises, saying whether anything was queued (see
-- :try_queue_actions for the non-raising form).
function Game:queue_actions(list)
  local n, msg = self:try_queue_actions(list)
  if n == nil then error("botwithus: queue_actions: " .. msg, 2) end
  return n
end

-- Client variables (varcs). An int varc the agent cannot read comes back as -1.
function Game:varc_int(id)
  local v, err = surface().varc_int(host(self), id)
  if v == nil then error("botwithus: varc_int failed: " .. tostring(err), 2) end
  return v
end

function Game:varc_string(id)
  local v, err = surface().varc_string(host(self), id)
  if v == nil then error("botwithus: varc_string failed: " .. tostring(err), 2) end
  return v
end

-- Walk one hop toward a tile (queues a WALK; pathing/stepping is the caller's loop).
function Game:walk_to(x, y)
  return self:do_action(Actions.walk_to(x, y))
end

-- Walk plan options: an optional trailing table on :path / :walk / :walk_ex / :walk_start,
--   { disabled_moves = W.moves_mask(W.MOVE_CHARTERS), exclude = { 42 }, exclude_loc_siblings = true }
-- (W = botwithus.walk). `exclude` lists transition indices (result.fail_transition,
-- transition.transition_index) the planner must not use, on every plan and re-plan of the
-- walk. nil, or a table with every field at its default, makes exactly the call made before
-- options existed, so an older bwu_host still works. Anything else on a bwu_host without walk
-- options raises; so does an exclusion the installed worldwalker.dll cannot honour (the host's
-- "cannot exclude transitions"). Never silently ignored.
local function is_default_option(k, v)
  if k == "disabled_moves" then return v == 0 end
  if k == "exclude" then return type(v) == "table" and next(v) == nil end
  if k == "exclude_loc_siblings" then return v == false end
  return false   -- an unknown key goes to the host, which names it in its error
end

-- The options to pass on: nil when there are none to apply.
local function walk_opts(opts)
  if opts == nil then return nil end
  if type(opts) ~= "table" then error("botwithus: walk options must be a table", 3) end
  local any = false
  for k, v in pairs(opts) do
    if not is_default_option(k, v) then any = true end
  end
  if not any then return nil end
  if surface().walk_options_supported == nil then
    error("botwithus: this bwu_host has no walk options (disabled_moves / exclude /"
          .. " exclude_loc_siblings); it predates them -- update it", 3)
  end
  return opts
end

-- Whether this bwu_host takes walk options at all (see :walk_options_supported).
function Game:has_walk_options()
  return surface().walk_options_supported ~= nil
end

-- True when both this bwu_host and its worldwalker.dll can exclude transitions; false for an
-- older either. Raises when worldwalker cannot be loaded at all.
function Game:walk_options_supported()
  local fn = surface().walk_options_supported
  if fn == nil then return false end
  return fn(host(self)) == true
end

-- Ask the native pather for a route to a goal tile; returns a list of steps. `opts`: the
-- walk plan options above.
function Game:path(x, y, plane, opts)
  local o = walk_opts(opts)
  local steps, err
  if o == nil then
    steps, err = surface().path(host(self), x, y, plane or 0)
  else
    steps, err = surface().path(host(self), x, y, plane or 0, o)
  end
  if not steps then error("botwithus: path failed: " .. tostring(err), 2) end
  return steps
end

-- Calls `fn` with the goal, adding the options table only when there is one: a bwu_host
-- without options then sees exactly its old call.
local function call_walk(fn, self, x, y, plane, radius, opts)
  local o = walk_opts(opts)
  if o == nil then return fn(host(self), x, y, plane or 0, radius or 1) end
  return fn(host(self), x, y, plane or 0, radius or 1, o)
end

-- Walk all the way to (x, y, plane) within `radius` tiles, via the native executor:
-- it plans, walks, re-plans, and EXECUTES transitions (doors/stairs/teleports/dialogue),
-- returning only when the walk terminates. BLOCKS for the whole route -- unlike walk_to,
-- which queues a single hop. Returns (true) on arrival, or (false, err) otherwise. Cancel
-- an in-flight walk from another coroutine/thread with :walk_cancel().
function Game:walk(x, y, plane, radius, opts)
  local ok, err = call_walk(surface().walk, self, x, y, plane, radius, opts)
  return ok == true, err
end

-- Request cancellation of an in-flight walk -- :walk, :walk_ex or :walk_start (idempotent).
function Game:walk_cancel()
  return surface().walk_cancel(host(self))
end

-- Walk progress (botwithus.walk has the constants and helpers). Feature-detected: on a
-- bwu_host that predates it, has_walk_progress() is false and the calls below raise.
function Game:has_walk_progress()
  return surface().walk_start ~= nil
end

local function walk_fn(name)
  local fn = surface()[name]
  if fn == nil then
    error("botwithus: this bwu_host has no " .. name .. "; it predates walk progress -- update it", 3)
  end
  return fn
end

-- BLOCKING like :walk, but returns a result table: status, result, final_event, fail_step,
-- fail_transition, replans, elapsed_ms, transition (the one last attempted), error, and
-- events. Returns (nil, err) if a walk is already running on this host.
function Game:walk_ex(x, y, plane, radius, opts)
  return call_walk(walk_fn("walk_ex"), self, x, y, plane, radius, opts)
end

-- Start a walk and return at once: (true), or (false, err) if one is already running. Lua has
-- no threads, so this is how a script watches a walk and steps in: poll :walk_events /
-- :walk_wait (a short timeout) from its loop and call :walk_cancel on STUCK.
function Game:walk_start(x, y, plane, radius, opts)
  local ok, err = call_walk(walk_fn("walk_start"), self, x, y, plane, radius, opts)
  return ok == true, err
end

-- The current or last walk's result table, or nil if this host has never walked.
function Game:walk_status()
  return walk_fn("walk_status")(host(self))
end

-- Wait up to `timeout_ms` (default 0) for the walk to end; its result table (status RUNNING
-- if it has not ended), or nil if never walked. Blocks the script for at most timeout_ms.
function Game:walk_wait(timeout_ms)
  local t = timeout_ms or 0
  if t < 0 then t = 0 end
  return walk_fn("walk_wait")(host(self), t)
end

-- The walk's events from index `since` (0-based, default 0) on. Keep a cursor:
-- since = since + #events.
function Game:walk_events(since)
  local s = since or 0
  if s < 0 then s = 0 end
  return walk_fn("walk_events")(host(self), s)
end

-- Varps and varbits (see botwithus.variables for what each state means). Decide on `state`,
-- never on `value`: a set varp can hold -1, and so can a varp at its default. A failed read
-- raises; an unreadable varp is a read whose state is "unavailable".

-- {id, state, value, value64, kind, default_verified, is_set, has_value}
function Game:read_varp(id) return Variables.read_varps(surface(), self._host, { id })[1] end
function Game:read_varps(ids) return Variables.read_varps(surface(), self._host, ids) end

-- {id, state, value, default_verified, is_set, has_value}
function Game:read_varbit(id) return Variables.read_varbits(surface(), self._host, { id })[1] end
function Game:read_varbits(ids) return Variables.read_varbits(surface(), self._host, ids) end

-- Just the state string.
function Game:varp_state(id) return self:read_varp(id).state end

-- The value the game reads: the stored value, the default when the client holds none, or -1
-- for no such varp / a failed read (-1 is also a legal stored value). A LONG varp's low 32 bits.
function Game:varp(id) return self:read_varp(id).value end

-- Like :varp, at full width: all 64 bits of a LONG varp.
function Game:varp_long(id) return self:read_varp(id).value64 end

-- :varp for each id, in order.
function Game:varps(ids)
  local out = {}
  for i, r in ipairs(self:read_varps(ids)) do out[i] = r.value end
  return out
end

-- The varbit's value as the game reads it, or -1 when it has none.
function Game:varbit(id) return self:read_varbit(id).value end

-- 1 once varp defaults come from the cache, 0 while it warms up after attach, -1 never.
function Game:varp_defaults_status() return Variables.defaults_status(surface()) end

-- Local life points, (current, max), from varps 13537 / 13538, or nil while unknown (lobby,
-- entering the world, the varp-default warm-up, a failed read). The host reads both varps
-- once per server tick and caches a known reading for the rest of it, so calling this every
-- loop is cheap. Raises if the pipe to the client is gone. Feature-detected: on a bwu_host
-- that predates it, has_local_health() is false and local_health() raises.
function Game:has_local_health()
  return surface().local_health ~= nil
end

function Game:local_health()
  local fn = surface().local_health
  if fn == nil then
    error("botwithus: this bwu_host has no local_health; it predates it -- update it", 2)
  end
  return fn(host(self))
end


-- Agent events -------------------------------------------------------------------------

-- Every event the agent published since the last call, in order, decoded by
-- botwithus.events: action_refused / action_executed come back as named tables, every other
-- type as its raw { type, body } record. Reading drains the host's ring for this client.
function Game:poll_events()
  return Events.decode_all(surface().poll_events(host(self)))
end

-- Breaks ---------------------------------------------------------------------------------

local MS_PER_SECOND = 1000
-- The agent's schedule_break reads `duration` as whole milliseconds and refuses anything
-- above INT32_MAX. A zero or negative duration schedules nothing, silently, so it is refused
-- here instead.
Game.MAX_BREAK_MS      = 0x7FFFFFFF
Game.MAX_BREAK_SECONDS = Game.MAX_BREAK_MS / MS_PER_SECOND

-- Round half to even, as the Python framework does, so both frontends send the same ms.
local function round_half_even(x)
  local f = math.floor(x)
  local diff = x - f
  if diff > 0.5 or (diff == 0.5 and f % 2 == 1) then f = f + 1 end
  return f
end

-- `seconds` as the whole milliseconds the agent's `duration` takes. Raises, naming
-- duration_seconds, for a non-number, a non-finite value, under 1 ms, or over the cap.
function Game.break_duration_ms(seconds)
  if type(seconds) ~= "number" then
    error("botwithus: duration_seconds must be a number of seconds, not " .. type(seconds), 2)
  end
  if seconds ~= seconds or seconds == math.huge or seconds == -math.huge then
    error("botwithus: duration_seconds must be finite, got " .. tostring(seconds), 2)
  end
  -- Multiply as a float: an integer product wraps modulo 2^64 and could land in range.
  local ms = round_half_even((seconds + 0.0) * MS_PER_SECOND)
  if ms < 1 then
    error("botwithus: duration_seconds must be at least 0.001 s (1 ms), got " .. tostring(seconds), 2)
  end
  if ms > Game.MAX_BREAK_MS then
    error(("botwithus: duration_seconds must be at most %s s (the agent's limit is %d ms), got %s")
      :format(tostring(Game.MAX_BREAK_SECONDS), Game.MAX_BREAK_MS, tostring(seconds)), 2)
  end
  return math.tointeger(ms)
end

-- Feature-detected: on a bwu_host that predates breaks, has_breaks() is false and the two
-- calls below raise.
function Game:has_breaks()
  local b = surface()
  return b.schedule_break ~= nil and b.interrupt_break ~= nil
end

local function break_fn(name)
  local fn = surface()[name]
  if fn == nil then
    error("botwithus: this bwu_host has no " .. name .. "; it predates breaks -- update it", 3)
  end
  return fn
end

-- Hold the action queue for `seconds` seconds (fractions allowed), starting now; replaces
-- any break already running. schedule_break(300) is a five-minute break. The agent counts
-- in milliseconds, so the value is rounded to the nearest ms before it is sent; a value out
-- of range raises and nothing is sent. The agent then publishes break_started, and
-- break_ended when the break ends or :interrupt_break() is called.
function Game:schedule_break(seconds)
  local ms = Game.break_duration_ms(seconds)
  local ok, err = break_fn("schedule_break")(host(self), ms)
  if not ok then error("botwithus: schedule_break failed: " .. tostring(err), 2) end
end

-- End the running break early.
function Game:interrupt_break()
  local ok, err = break_fn("interrupt_break")(host(self))
  if not ok then error("botwithus: interrupt_break failed: " .. tostring(err), 2) end
end

return Game
