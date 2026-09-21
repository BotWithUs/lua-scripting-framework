-- botwithus.game -- an ergonomic facade over the native `bwu` table.
--
-- The native host installs a global `bwu` (see native-scripting-host). This module
-- resolves it lazily -- at call time, not load time -- so the unit suite can inject a
-- fake `bwu` before exercising the facade. Nothing here reaches the pipe or shared
-- memory directly; it all goes through the one host surface.

local Tile    = require("botwithus.tile")
local Actions = require("botwithus.actions")

-- Resolve the surface each call. `_G.bwu` is set by the host (or a test fake).
local function surface()
  local b = rawget(_G, "bwu")
  if not b then error("botwithus: native `bwu` surface not present (run under bwu_host)", 2) end
  return b
end

local Game = {}
Game.__index = Game

-- Attach to a client. With no pid, attaches to the first discovered one.
function Game.attach(pid)
  local b = surface()
  if not pid then
    local pids = b.discover_pids()
    pid = pids[1]
    if not pid then error("botwithus: no game client to attach to", 2) end
  end
  local host, err = b.attach(pid)
  if not host then error("botwithus: attach failed: " .. tostring(err), 2) end
  return setmetatable({ _host = host, _pid = pid }, Game)
end

function Game:pid() return self._pid end

function Game:detach()
  if self._host then surface().detach(self._host); self._host = nil end
end

-- Pull a fresh snapshot copy for this tick. Call once at the top of a loop iter.
function Game:refresh() return surface().refresh(self._host) end

-- The three clocks. Only server_tick paces scripts; the other two are exposed
-- but deliberately never used for timing (see sleep_ticks in the runner).
function Game:clocks() return surface().clocks(self._host) end
function Game:server_tick() return self:clocks().server_tick end

function Game:self()
  local s = surface().self(self._host)
  s.tile = Tile.from(s.tile)
  return s
end

function Game:npcs()
  local raw = surface().npcs(self._host)
  for _, n in ipairs(raw) do n.tile = Tile.from(n.tile) end
  return raw
end

function Game:players()
  local raw = surface().players(self._host)
  for _, p in ipairs(raw) do p.tile = Tile.from(p.tile) end
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
  for _, o in ipairs(surface().locations(self._host)) do
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
  return surface().queue_action(self._host, a.id, a.p1 or 0, a.p2 or 0, a.p3 or 0)
end

-- Walk one hop toward a tile (queues a WALK; pathing/stepping is the caller's loop).
function Game:walk_to(x, y)
  return self:do_action(Actions.walk_to(x, y))
end

-- Ask the native pather for a route to a goal tile; returns a list of steps.
function Game:path(x, y, plane)
  local steps, err = surface().path(self._host, x, y, plane or 0)
  if not steps then error("botwithus: path failed: " .. tostring(err), 2) end
  return steps
end

-- Walk all the way to (x, y, plane) within `radius` tiles, via the native executor:
-- it plans, walks, re-plans, and EXECUTES transitions (doors/stairs/teleports/dialogue),
-- returning only when the walk terminates. BLOCKS for the whole route -- unlike walk_to,
-- which queues a single hop. Returns (true) on arrival, or (false, err) otherwise. Cancel
-- an in-flight walk from another coroutine/thread with :walk_cancel().
function Game:walk(x, y, plane, radius)
  local ok, err = surface().walk(self._host, x, y, plane or 0, radius or 1)
  return ok == true, err
end

-- Request cancellation of an in-flight :walk (idempotent).
function Game:walk_cancel()
  return surface().walk_cancel(self._host)
end

return Game
