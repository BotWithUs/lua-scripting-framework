-- botwithus.orientation -- which way an entity is facing, as the client stores it.
--
-- The raw value is the client's own angle, 0..16383 per full turn: the entity's *rendered*
-- facing, interpolated while it turns (so it reads in-between angles for a few ticks after a
-- turn starts). It is UNKNOWN_RAW when the producer could not read one.
--
-- Use degrees() (compass bearing, clockwise from north) or compass() (nearest of eight
-- points) for anything but an exact comparison. Both return nil for an unknown facing --
-- never "NORTH" or 0 for a value that was not read.

local M = {}

-- Client angle units in one full turn.
M.FULL_TURN = 16384

-- The raw angle that faces north (+tileY). Raw grows clockwise seen from above:
-- 0 south, 4096 west, 8192 north, 12288 east. Inferred statically, not yet confirmed
-- against a live client: if that check disagrees this is the one line to change, and
-- spec/orientation_spec.lua pins what the cardinals must become.
M.NORTH_RAW = 8192

M.UNKNOWN_RAW  = -1       -- raw value for a facing that is not known
M.WIRE_UNKNOWN = 0xFFFF   -- what the producer publishes for "not known" (all-ones u16)

local DEGREES_PER_TURN = 360
local SECTOR_DEGREES   = 45

-- The eight points, clockwise from north. Order is load-bearing: compass() indexes it.
M.DIRECTIONS = { "NORTH", "NORTH_EAST", "EAST", "SOUTH_EAST",
                 "SOUTH", "SOUTH_WEST", "WEST", "NORTH_WEST" }

local function is_angle(v)
  return type(v) == "number" and v == math.floor(v) and v >= 0 and v < M.FULL_TURN
end

local function check(raw)
  if not is_angle(raw) then
    error(("orientation must be 0..%d or %d: %s"):format(M.FULL_TURN - 1, M.UNKNOWN_RAW,
                                                        tostring(raw)), 3)
  end
end

-- Decode the producer's zero-extended u16, degrading rather than raising. WIRE_UNKNOWN is
-- unknown and 0..16383 is the angle. Anything else breaks the producer's contract: it also
-- decodes as UNKNOWN_RAW (never wrapped into a plausible wrong angle) and is passed to
-- on_out_of_contract. This never raises -- it runs inside a snapshot decode, and one bad row
-- must not take down every running script. Passing an out-of-range raw to degrees() /
-- compass() still raises, because that is a caller's mistake rather than the wire's.
function M.from_wire(wire_value, on_out_of_contract)
  if wire_value == M.WIRE_UNKNOWN then return M.UNKNOWN_RAW end
  if not is_angle(wire_value) then
    on_out_of_contract(wire_value)
    return M.UNKNOWN_RAW
  end
  return wire_value
end

-- from_wire for the snapshot decode path, reporting a broken producer invariant at most
-- once: the same bad value can repeat on many rows and ticks. Make one per attached
-- session. `report` defaults to a single printed warning.
function M.wire_decoder(report)
  report = report or function(v)
    print(("[botwithus] producer published orientation %s (neither 0..%d nor 0x%X); "
           .. "decoding it as unknown. Further occurrences this session are not logged.")
          :format(tostring(v), M.FULL_TURN - 1, M.WIRE_UNKNOWN))
  end
  local has_reported = false
  local function report_once(v)
    if not has_reported then
      has_reported = true
      report(v)
    end
  end
  return function(wire_value) return M.from_wire(wire_value, report_once) end
end

function M.is_known(raw) return raw ~= M.UNKNOWN_RAW end

-- Compass bearing in [0, 360), clockwise from north; nil when unknown.
function M.degrees(raw)
  if not M.is_known(raw) then return nil end
  check(raw)
  return ((raw - M.NORTH_RAW) % M.FULL_TURN) * DEGREES_PER_TURN / M.FULL_TURN
end

-- Nearest of the eight points (a DIRECTIONS string); nil when unknown. A bearing exactly
-- on a sector boundary (22.5, 67.5, ...) rounds clockwise.
function M.compass(raw)
  local bearing = M.degrees(raw)
  if bearing == nil then return nil end
  local sector = math.floor(bearing / SECTOR_DEGREES + 0.5) % #M.DIRECTIONS
  return M.DIRECTIONS[sector + 1]
end

return M
