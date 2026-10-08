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
Game.PROTOCOL_VERSION = 23

-- Refuse a host built for another protocol before attaching: the surface's tables would
-- not be the shapes this framework reads.
local function require_protocol(b, level)
  if b.PROTOCOL_VERSION ~= Game.PROTOCOL_VERSION then
    error("botwithus: this framework is built for agent protocol v" .. Game.PROTOCOL_VERSION
      .. " but the native host speaks v" .. tostring(b.PROTOCOL_VERSION)
      .. "; update the framework and the host together", level + 1)
  end
end

-- The pid Game.attach() picks when given none: the first discovered client.
-- `level` is the error level to blame when there is none (default: the caller).
function Game.attach_target(level)
  local pid = surface().discover_pids()[1]
  if not pid then error("botwithus: no game client to attach to", level or 2) end
  return pid
end

-- Attach to a client. With no pid, attaches to the first discovered one.
function Game.attach(pid)
  local b = surface()
  require_protocol(b, 2)
  pid = pid or Game.attach_target(3)
  local host, err = b.attach(pid)
  if not host then error("botwithus: attach failed: " .. tostring(err), 2) end
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
  local raw = row.orientation or Orientation.UNKNOWN_RAW
  row.orientation = raw
  row.facing = Orientation.compass(raw)
  row.facing_degrees = Orientation.degrees(raw)
  return row
end

function Game:self()
  return with_facing(surface().self(host(self)))
end

function Game:npcs()
  local raw = surface().npcs(host(self))
  for _, n in ipairs(raw) do with_facing(n) end
  return raw
end

function Game:players()
  local raw = surface().players(host(self))
  for _, p in ipairs(raw) do with_facing(p) end
  return raw
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

-- Queue any action built by botwithus.actions (or a raw {id,p1,p2,p3}).
function Game:do_action(a)
  return surface().queue_action(host(self), a.id, a.p1 or 0, a.p2 or 0, a.p3 or 0)
end

-- Queue a list of actions in one round trip, in order. Returns how many the agent accepted,
-- which is fewer than #list only when its queue is full. At most bwu.MAX_ACTION_BATCH.
function Game:queue_actions(list)
  local n, err = surface().queue_actions(host(self), list)
  if not n then error("botwithus: queue_actions failed: " .. tostring(err), 2) end
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

return Game
