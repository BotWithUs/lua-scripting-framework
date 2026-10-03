-- botwithus.game -- an ergonomic facade over the native `bwu` table.
--
-- The native host installs a global `bwu` (see native-scripting-host). This module
-- resolves it lazily -- at call time, not load time -- so the unit suite can inject a
-- fake `bwu` before exercising the facade. Nothing here reaches the pipe or shared
-- memory directly; it all goes through the one host surface.

local Tile    = require("botwithus.tile")
local Actions = require("botwithus.actions")
local Orientation = require("botwithus.orientation")

-- Resolve the surface each call. `_G.bwu` is set by the host (or a test fake).
-- host(self), further down, is the guard every per-client call goes through.
local function surface()
  local b = rawget(_G, "bwu")
  if not b then error("botwithus: native `bwu` surface not present (run under bwu_host)", 2) end
  return b
end

local Game = {}
Game.__index = Game

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

-- Ask the native pather for a route to a goal tile; returns a list of steps.
function Game:path(x, y, plane)
  local steps, err = surface().path(host(self), x, y, plane or 0)
  if not steps then error("botwithus: path failed: " .. tostring(err), 2) end
  return steps
end

-- Walk all the way to (x, y, plane) within `radius` tiles, via the native executor:
-- it plans, walks, re-plans, and EXECUTES transitions (doors/stairs/teleports/dialogue),
-- returning only when the walk terminates. BLOCKS for the whole route -- unlike walk_to,
-- which queues a single hop. Returns (true) on arrival, or (false, err) otherwise. Cancel
-- an in-flight walk from another coroutine/thread with :walk_cancel().
function Game:walk(x, y, plane, radius)
  local ok, err = surface().walk(host(self), x, y, plane or 0, radius or 1)
  return ok == true, err
end

-- Request cancellation of an in-flight :walk (idempotent).
function Game:walk_cancel()
  return surface().walk_cancel(host(self))
end

return Game
