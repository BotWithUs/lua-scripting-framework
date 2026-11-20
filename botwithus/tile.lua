-- botwithus.tile -- a game tile and the distance metric the game uses.
--
-- RuneScape movement is 8-directional, so adjacency is Chebyshev (chessboard)
-- distance, not Euclidean: diagonal and orthogonal steps both cost one.
--
-- This is the Java host's world.Coordinate (bot.Coordinate is the same table): distance is
-- Chebyshev, euclidean() is the straight line, and the region helpers match Coordinate's.

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

-- Euclidean distance on the same plane (math.huge across planes).
function Tile:euclidean(other)
  other = Tile.from(other)
  if self.plane ~= other.plane then return math.huge end
  local dx, dy = self.x - other.x, self.y - other.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Regions are 64x64 tiles. region_id is (region_x << 8) | region_y, as the game numbers them.
Tile.REGION_SIZE = 64
local REGION_SHIFT = 6
local REGION_ID_X_SHIFT = 8
local REGION_LOCAL_MASK = Tile.REGION_SIZE - 1

function Tile:region_x() return self.x >> REGION_SHIFT end
function Tile:region_y() return self.y >> REGION_SHIFT end
function Tile:region_id() return (self:region_x() << REGION_ID_X_SHIFT) | self:region_y() end
function Tile:region_local_x() return self.x & REGION_LOCAL_MASK end
function Tile:region_local_y() return self.y & REGION_LOCAL_MASK end

-- A new tile moved by (dx, dy[, dplane]).
function Tile:offset(dx, dy, dplane)
  return Tile.new(self.x + dx, self.y + dy, self.plane + (dplane or 0))
end

-- The same x/y on another plane.
function Tile:with_plane(plane) return Tile.new(self.x, self.y, plane) end

function Tile:__tostring()
  return string.format("(%d,%d,%d)", self.x, self.y, self.plane)
end

return Tile
