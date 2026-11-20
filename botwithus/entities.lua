-- botwithus.entities -- fluent, chainable queries over snapshot entities.
--
--   local q = Npcs.new(game)
--   local nearest = q:of_type(1234):nearest()
--
-- Each filter returns a new query so chains don't mutate shared state. Terminals
-- (:all / :nearest / :count / :first) run the underlying bwu read once.

local Tile = require("botwithus.tile")
local Interact = require("botwithus.interact")
local Area = require("botwithus.area")

local Query = {}
Query.__index = Query

-- `kind` ("npc", "player", "object", "ground_item", "hint_arrow") picks how names and options
-- resolve; `game` is the Game the rows come from (for :reachable and :within_distance).
local function new_query(source, preds, kind, game)
  return setmetatable({ _source = source, _preds = preds or {}, _kind = kind, _game = game }, Query)
end

-- Add a predicate, returning a fresh query (immutable chaining).
function Query:filter(pred)
  local preds = {}
  for i, p in ipairs(self._preds) do preds[i] = p end
  preds[#preds + 1] = pred
  return new_query(self._source, preds, self._kind, self._game)
end

function Query:kind() return self._kind end

function Query:of_type(type_id)
  return self:filter(function(e) return e.type_id == type_id end)
end

-- U+00A0 (no-break space) in UTF-8. The client turns cp1252 0xA0 into it, so a player name
-- can carry one where the player typed a space.
local NO_BREAK_SPACE = "\xC2\xA0"

-- A player name in the form names are compared in: every U+00A0 becomes a plain space.
-- Display the raw name; compare this.
function Query.normalize_name(name)
  return (name:gsub(NO_BREAK_SPACE, " "))
end

-- Whether two player names are the same name. An empty (or missing) name never equals
-- anything, itself included: "" means the client has not decoded that name yet.
function Query.names_equal(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or a == "" or b == "" then return false end
  return Query.normalize_name(a) == Query.normalize_name(b)
end

-- Rows whose name is `name` (see names_equal): an undecoded name never matches, and an
-- empty `name` matches nothing.
function Query:named(name)
  return self:filter(function(e) return Query.names_equal(e.name, name) end)
end

-- A row with no tile (a hint arrow on an entity) is within no distance of anything.
function Query:within(tile, radius)
  tile = Tile.from(tile)
  return self:filter(function(e) return e.tile ~= nil and tile:distance(e.tile) <= radius end)
end

function Query:where(fn) return self:filter(fn) end

-- Terminal: materialize the filtered list.
function Query:all()
  local out = {}
  for _, e in ipairs(self._source()) do
    local keep = true
    for _, p in ipairs(self._preds) do
      if not p(e) then keep = false; break end
    end
    if keep then out[#out + 1] = e end
  end
  return out
end

function Query:count() return #self:all() end
function Query:first() return self:all()[1] end

-- Terminal: the match nearest to `origin` (a Tile or entity), or nil. Rows with no tile are
-- skipped.
function Query:nearest(origin)
  origin = Tile.from(origin)
  local best, bestd = nil, math.huge
  for _, e in ipairs(self:all()) do
    local d = e.tile and origin:distance(e.tile) or math.huge
    if d < bestd then best, bestd = e, d end
  end
  return best, bestd
end

-- The Java host's entity filters (J1) ----------------------------------------------------------
--
-- Fields a row lacks never match a filter on them: an NPC's hp needs host ABI 5, and an object
-- row carries no stance or health (its animation_id needs host ABI 8).

local function id_set(...)
  local set = {}
  for _, id in ipairs({ ... }) do set[id] = true end
  return set
end

-- Rows whose type id is any of `...` (an object's loc id, a ground item's item id).
function Query:with_ids(...)
  local set = id_set(...)
  return self:filter(function(e) return set[e.type_id] == true end)
end

-- The display name of a row (players: their name; others: the cache's), or nil.
function Query:name_of(e) return Interact.name(self._kind, e) end

-- Rows whose WHOLE name is one of `...`, ignoring case (U+00A0 reads as a space).
function Query:named_any_of(...)
  local wanted = {}
  for i, n in ipairs({ ... }) do wanted[i] = Query.normalize_name(n):lower() end
  return self:filter(function(e)
    local name = self:name_of(e)
    if name == nil then return false end
    name = Query.normalize_name(name):lower()
    for _, w in ipairs(wanted) do
      if w ~= "" and name == w then return true end
    end
    return false
  end)
end

-- Rows whose whole name matches the Lua pattern (anchored at both ends).
function Query:name_matching(pattern)
  if pattern:sub(1, 1) ~= "^" then pattern = "^" .. pattern end
  if pattern:sub(-1) ~= "$" then pattern = pattern .. "$" end
  return self:filter(function(e)
    local name = self:name_of(e)
    return name ~= nil and Query.normalize_name(name):find(pattern) ~= nil
  end)
end

-- Rows whose menu lists `option`, ignoring case (NPCs, objects, ground items; from the cache).
function Query:with_option(option)
  local kind = self._kind
  return self:filter(function(e) return Interact.has_option(kind, e, option) end)
end

-- Animation (NPCs, players, and objects from host ABI 8): animation_id -1 is "not animating".
function Query:animating()
  return self:filter(function(e) return e.animation_id ~= nil and e.animation_id ~= -1 end)
end
function Query:not_animating()
  return self:filter(function(e) return e.animation_id == -1 end)
end
function Query:with_animation(...)
  local set = id_set(...)
  return self:filter(function(e) return set[e.animation_id] == true end)
end

-- Actors (NPCs, players): stance, spot animation, movement, combat level.
function Query:with_stance(...)
  local set = id_set(...)
  return self:filter(function(e) return set[e.stance_id] == true end)
end
function Query:with_spot_anim(...)
  local set = id_set(...)
  return self:filter(function(e) return set[e.spot_anim_id] == true end)
end
function Query:moving() return self:filter(function(e) return e.moving == true end) end
function Query:not_moving() return self:filter(function(e) return e.moving == false end) end
function Query:with_combat_level(min, max)
  return self:filter(function(e)
    return e.combat_level ~= nil and e.combat_level >= min and e.combat_level <= max
  end)
end

-- NPC health (host ABI 5 hp / max_hp). Players carry no hp on the wire.
function Query:with_health(min, max)
  return self:filter(function(e) return e.hp ~= nil and e.hp >= min and e.hp <= max end)
end

local FULL_HEALTH_PERCENT = 100
-- An NPC with an unknown max hp (0) never matches.
function Query:with_health_percent(min, max)
  return self:filter(function(e)
    if e.max_hp == nil or e.max_hp <= 0 then return false end
    local pct = (e.hp * FULL_HEALTH_PERCENT) // e.max_hp
    return pct >= min and pct <= max
  end)
end

function Query:on_plane(plane)
  return self:filter(function(e) return e.tile ~= nil and e.tile.plane == plane end)
end

-- Rows inside / outside a botwithus.area.
function Query:inside(area) return self:filter(function(e) return area:contains(e) end) end
function Query:outside(area) return self:filter(function(e) return not area:contains(e) end) end

-- Rows the world walker finds a route to, on the player's plane. One path query per candidate,
-- and scenery that blocks its own tile (a booth, a tree) reads unreachable: add this filter last.
function Query:reachable()
  local game = self._game
  return self:filter(function(e)
    if game == nil or e.tile == nil then return false end
    return e.tile.plane == game:self().tile.plane and Area.is_reachable(game, e.tile)
  end)
end

-- Rows within `radius` tiles of the player.
function Query:within_distance(radius)
  local game = self._game
  return self:filter(function(e)
    if game == nil or e.tile == nil then return false end
    return Tile.from(game:self().tile):distance(e.tile) <= radius
  end)
end

-- Terminals: the last match, a random one, and the nearest to a tile, an entity or x, y[, plane]
-- (with x, y and no plane it ignores planes, as the Java host's two-argument form does).
function Query:last()
  local all = self:all()
  return all[#all]
end

function Query:random(random)
  local all = self:all()
  if #all == 0 then return nil end
  return all[(random or math.random)(1, #all)]
end

function Query:nearest_to(a, y, plane)
  if type(a) ~= "number" then
    local t = Tile.from(a.tile or a)
    a, y, plane = t.x, t.y, t.plane
  end
  local best, bestd = nil, math.huge
  for _, e in ipairs(self:all()) do
    if e.tile ~= nil and (plane == nil or e.tile.plane == plane) then
      local d = math.max(math.abs(e.tile.x - a), math.abs(e.tile.y - y))
      if d < bestd then best, bestd = e, d end
    end
  end
  return best, bestd
end

-- Click `option` on a row this query returned (NPCs, objects, ground items). False when the
-- row's menu has no such option.
function Query:interact(row, option)
  if self._game == nil then error("botwithus: this query has no Game to click through", 2) end
  return Interact.row(self._game, self._kind, row, option)
end

local Entities = {}

-- Npcs over a Game facade. `game:npcs()` is the source, read fresh on each terminal.
function Entities.npcs(game)
  return new_query(function() return game:npcs() end, nil, "npc", game)
end

-- Players over a Game facade.
function Entities.players(game)
  return new_query(function() return game:players() end, nil, "player", game)
end

-- Visible scene objects over a Game facade; :of_type() matches the loc id the server sent.
function Entities.objects(game)
  return new_query(function() return game:objects() end, nil, "object", game)
end

-- Hint arrows over a Game facade; :of_type() matches the arrow type. Any refusal (out of the
-- world, a client channel without arrows) reads as no arrows, and so does a timeout
-- (game_thread_timeout, rpc_timeout), so a polling script cannot tell "none" from "did not
-- answer" here. A query's rows do not carry the list's `truncated` field either: call
-- game:hint_arrows() for the code or the flag.
function Entities.hint_arrows(game)
  return new_query(function() return game:hint_arrows() or {} end, nil, "hint_arrow", game)
end

-- Ground-item stacks over a Game facade; :of_type() matches the item id. Needs host ABI 5.
function Entities.ground_items(game)
  return new_query(function() return game:ground_items() end, nil, "ground_item", game)
end

Entities.Query = Query
Entities.normalize_name = Query.normalize_name
Entities.names_equal = Query.names_equal
return Entities
