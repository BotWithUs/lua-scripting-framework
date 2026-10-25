-- botwithus.entities -- fluent, chainable queries over snapshot entities.
--
--   local q = Npcs.new(game)
--   local nearest = q:of_type(1234):nearest()
--
-- Each filter returns a new query so chains don't mutate shared state. Terminals
-- (:all / :nearest / :count / :first) run the underlying bwu read once.

local Tile = require("botwithus.tile")

local Query = {}
Query.__index = Query

local function new_query(source, preds)
  return setmetatable({ _source = source, _preds = preds or {} }, Query)
end

-- Add a predicate, returning a fresh query (immutable chaining).
function Query:filter(pred)
  local preds = {}
  for i, p in ipairs(self._preds) do preds[i] = p end
  preds[#preds + 1] = pred
  return new_query(self._source, preds)
end

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

function Query:within(tile, radius)
  tile = Tile.from(tile)
  return self:filter(function(e) return tile:distance(e.tile) <= radius end)
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

-- Terminal: the match nearest to `origin` (a Tile or entity), or nil.
function Query:nearest(origin)
  origin = Tile.from(origin)
  local best, bestd = nil, math.huge
  for _, e in ipairs(self:all()) do
    local d = origin:distance(e.tile)
    if d < bestd then best, bestd = e, d end
  end
  return best, bestd
end

local Entities = {}

-- Npcs over a Game facade. `game:npcs()` is the source, read fresh on each terminal.
function Entities.npcs(game)
  return new_query(function() return game:npcs() end)
end

-- Players over a Game facade.
function Entities.players(game)
  return new_query(function() return game:players() end)
end

-- Visible scene objects over a Game facade; :of_type() matches the loc id the server sent.
function Entities.objects(game)
  return new_query(function() return game:objects() end)
end

Entities.Query = Query
Entities.normalize_name = Query.normalize_name
Entities.names_equal = Query.names_equal
return Entities
