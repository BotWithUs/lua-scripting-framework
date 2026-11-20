-- botwithus.area -- rectangular, circular and polygonal areas of tiles (the Java host's
-- world.Area, RectangularArea, CircularArea and PolygonalArea).
--
--   local Area = require("botwithus.area")
--   local bank = Area.rect(3092, 3240, 3097, 3246)          -- plane 0
--   local pen  = Area.circle({ x = 3200, y = 3200 }, 5)
--   local yard = Area.polygon({ {3200, 3200}, {3210, 3200}, {3205, 3210} })
--   if bank:contains(game:self()) then ... end
--   local spot = yard:random_reachable_tile(game)          -- nil when 10 draws all fail
--
-- contains() takes a tile, any row with a .tile (self, an NPC, an object), or x, y, plane. A
-- rectangle is inclusive of its edges. A circle's radius is Euclidean (dx^2 + dy^2 <= r^2). A
-- polygon counts its outline and its vertices as inside, and the even-odd rule elsewhere. Every
-- area lies on one plane, and a tile on another plane is never inside it.
--
-- random_reachable_tile asks the world walker for a route (game:path) to each draw: one path query
-- per draw, so keep `attempts` small.

local Tile = require("botwithus.tile")

local Area = {}

local MAX_PLANE = 3
Area.DEFAULT_REACHABLE_ATTEMPTS = 10
Area.MIN_VERTICES = 3
local MAX_REJECTION_DRAWS = 64

local function check_plane(plane)
  if math.type(plane) ~= "integer" or plane < 0 or plane > MAX_PLANE then
    error("botwithus: plane must be 0.." .. MAX_PLANE .. ", got " .. tostring(plane), 3)
  end
end

-- x, y, plane of a tile, a row with a .tile, or the three numbers.
local function xyp(a, y, plane)
  if type(a) == "number" then return a, y, plane or 0 end
  if a == nil then return nil end
  local t = a.tile or a
  return t.x, t.y, t.plane or 0
end

-- The shared methods ------------------------------------------------------------------------

local Base = {}

function Base:contains(a, y, plane)
  local x
  x, y, plane = xyp(a, y, plane)
  if x == nil then return false end
  return self:_contains(x, y, plane)
end

function Base:random_tile(random)
  return self:_random_tile(random or math.random)
end

-- A random tile of the area the world walker can route to from the player, or nil when
-- `attempts` (default 10) draws all fail.
function Base:random_reachable_tile(game, attempts, random)
  for _ = 1, attempts or Area.DEFAULT_REACHABLE_ATTEMPTS do
    local tile = self:random_tile(random)
    if Area.is_reachable(game, tile) then return tile end
  end
  return nil
end

-- Whether the world walker finds a route from the player to `tile` (game:path does not raise).
-- The player's own tile is reachable.
function Area.is_reachable(game, tile)
  local ok, steps = pcall(game.path, game, tile.x, tile.y, tile.plane)
  return ok and steps ~= nil
end

local function class(methods)
  methods.__index = methods
  for k, v in pairs(Base) do methods[k] = methods[k] or v end
  return methods
end

-- Rectangle ---------------------------------------------------------------------------------

local Rect = class({ kind = "rect" })

-- The rectangle from (min_x, min_y) to (max_x, max_y), inclusive, on `plane` (default 0).
function Area.rect(min_x, min_y, max_x, max_y, plane)
  plane = plane or 0
  if min_x > max_x or min_y > max_y then
    error(("botwithus: min corner (%d,%d) is past max corner (%d,%d)"):format(min_x, min_y, max_x, max_y), 2)
  end
  check_plane(plane)
  return setmetatable({ min_x = min_x, min_y = min_y, max_x = max_x, max_y = max_y,
                        plane = plane }, Rect)
end

-- The rectangle spanning two corner tiles, in any order (same plane).
function Area.rect_of(a, b)
  a, b = Tile.from(a), Tile.from(b)
  if a.plane ~= b.plane then
    error(("botwithus: corners are on planes %d and %d"):format(a.plane, b.plane), 2)
  end
  return Area.rect(math.min(a.x, b.x), math.min(a.y, b.y), math.max(a.x, b.x),
                   math.max(a.y, b.y), a.plane)
end

-- The square of `radius` tiles round `centre` (a Chebyshev ball).
function Area.around(centre, radius)
  centre = Tile.from(centre)
  return Area.rect(centre.x - radius, centre.y - radius, centre.x + radius, centre.y + radius,
                   centre.plane)
end

function Rect:_contains(x, y, plane)
  return plane == self.plane and x >= self.min_x and x <= self.max_x and y >= self.min_y
    and y <= self.max_y
end

function Rect:_random_tile(random)
  return Tile.new(random(self.min_x, self.max_x), random(self.min_y, self.max_y), self.plane)
end

function Rect:width() return self.max_x - self.min_x + 1 end
function Rect:height() return self.max_y - self.min_y + 1 end
function Rect:bounds() return self end

-- Circle --------------------------------------------------------------------------------------

local Circle = class({ kind = "circle" })

-- The tiles within Euclidean `radius` of `centre` (a tile or {x, y, plane}).
function Area.circle(centre, radius)
  if radius < 0 then error("botwithus: radius must be >= 0, got " .. radius, 2) end
  centre = Tile.from(centre)
  check_plane(centre.plane)
  return setmetatable({ centre = centre, radius = radius, plane = centre.plane }, Circle)
end

function Circle:_contains(x, y, plane)
  local dx, dy = x - self.centre.x, y - self.centre.y
  return plane == self.plane and dx * dx + dy * dy <= self.radius * self.radius
end

function Circle:bounds() return Area.around(self.centre, self.radius) end

function Circle:_random_tile(random)
  local box = self:bounds()
  while true do
    local tile = box:_random_tile(random)
    if self:_contains(tile.x, tile.y, tile.plane) then return tile end
  end
end

-- Polygon -------------------------------------------------------------------------------------

local Polygon = class({ kind = "polygon" })

local function vertex(v, plane)
  if v.x ~= nil then return Tile.new(v.x, v.y, v.plane or plane) end
  return Tile.new(v[1], v[2], v[3] or plane)
end

-- The polygon with these vertices (tiles, {x, y, plane} or {x, y}), in order, on `plane` for any
-- vertex that does not name one (default 0). At least three vertices, all on one plane.
function Area.polygon(vertices, plane)
  if #vertices < Area.MIN_VERTICES then
    error(("botwithus: a polygon needs at least %d vertices, got %d"):format(Area.MIN_VERTICES, #vertices), 2)
  end
  local vs = {}
  for i, v in ipairs(vertices) do vs[i] = vertex(v, plane or 0) end
  local min_x, min_y, max_x, max_y = vs[1].x, vs[1].y, vs[1].x, vs[1].y
  for _, v in ipairs(vs) do
    if v.plane ~= vs[1].plane then
      error(("botwithus: vertices span planes %d and %d"):format(vs[1].plane, v.plane), 2)
    end
    min_x, min_y = math.min(min_x, v.x), math.min(min_y, v.y)
    max_x, max_y = math.max(max_x, v.x), math.max(max_y, v.y)
  end
  check_plane(vs[1].plane)
  return setmetatable({ vertices = vs, plane = vs[1].plane,
                        _bounds = Area.rect(min_x, min_y, max_x, max_y, vs[1].plane) }, Polygon)
end

function Polygon:bounds() return self._bounds end

local function on_segment(x, y, a, b)
  local cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)
  return cross == 0 and x >= math.min(a.x, b.x) and x <= math.max(a.x, b.x)
    and y >= math.min(a.y, b.y) and y <= math.max(a.y, b.y)
end

function Polygon:_on_outline(x, y)
  local vs = self.vertices
  for i = 1, #vs do
    if on_segment(x, y, vs[i], vs[i % #vs + 1]) then return true end
  end
  return false
end

function Polygon:_inside_even_odd(x, y)
  local vs, inside, j = self.vertices, false, #self.vertices
  for i = 1, #vs do
    local a, b = vs[i], vs[j]
    if (a.y > y) ~= (b.y > y) then
      local cross_x = a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y)
      if x < cross_x then inside = not inside end
    end
    j = i
  end
  return inside
end

function Polygon:_contains(x, y, plane)
  if not self._bounds:_contains(x, y, plane) then return false end
  return self:_on_outline(x, y) or self:_inside_even_odd(x, y)
end

-- Every tile inside, row by row.
function Polygon:tiles()
  local out, b = {}, self._bounds
  for y = b.min_y, b.max_y do
    for x = b.min_x, b.max_x do
      if self:_contains(x, y, self.plane) then out[#out + 1] = Tile.new(x, y, self.plane) end
    end
  end
  return out
end

function Polygon:_random_tile(random)
  for _ = 1, MAX_REJECTION_DRAWS do
    local tile = self._bounds:_random_tile(random)
    if self:_contains(tile.x, tile.y, tile.plane) then return tile end
  end
  local tiles = self:tiles()
  return tiles[random(1, #tiles)]
end

return Area
