-- botwithus.tile -- a game tile and the distance metric the game uses.
--
-- RuneScape movement is 8-directional, so adjacency is Chebyshev (chessboard)
-- distance, not Euclidean: diagonal and orthogonal steps both cost one.

local Tile = {}
Tile.__index = Tile

function Tile.new(x, y, plane)
  return setmetatable({ x = x, y = y, plane = plane or 0 }, Tile)
end

-- Accepts either a Tile or a plain {x=,y=,plane=} (as the bwu surface returns).
function Tile.from(t)
  if getmetatable(t) == Tile then return t end
  return Tile.new(t.x, t.y, t.plane or 0)
end

-- Chebyshev distance on the same plane; math.huge across planes (not walkable
-- as a straight line -- that needs a transition, which pathing handles).
function Tile:distance(other)
  other = Tile.from(other)
  if self.plane ~= other.plane then return math.huge end
  return math.max(math.abs(self.x - other.x), math.abs(self.y - other.y))
end

function Tile:equals(other)
  other = Tile.from(other)
  return self.x == other.x and self.y == other.y and self.plane == other.plane
end

function Tile:__tostring()
  return string.format("(%d,%d,%d)", self.x, self.y, self.plane)
end

return Tile
