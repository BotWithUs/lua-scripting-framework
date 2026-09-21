-- Pins the facing convention. The four cardinal rows are the contract: raw grows clockwise
-- seen from above, 0 is south and 8192 is north. If a live check moves the zero offset,
-- NORTH_RAW changes and these rows say what must follow.
local O = require("botwithus.orientation")

local T = {}

local function near(a, b) return math.abs(a - b) < 1e-9 end

T["cardinals map to bearing and compass point"] = function(assert_)
  local rows = {
    { 8192, 0, "NORTH" }, { 12288, 90, "EAST" }, { 0, 180, "SOUTH" }, { 4096, 270, "WEST" },
  }
  for _, r in ipairs(rows) do
    assert_(near(O.degrees(r[1]), r[2]), ("raw %d -> %s degrees"):format(r[1], r[2]))
    assert_(O.compass(r[1]) == r[3], ("raw %d -> %s"):format(r[1], r[3]))
  end
end

T["intercardinals map to their point"] = function(assert_)
  local rows = {
    { 10240, "NORTH_EAST" }, { 14336, "SOUTH_EAST" }, { 2048, "SOUTH_WEST" }, { 6144, "NORTH_WEST" },
  }
  for _, r in ipairs(rows) do
    assert_(O.compass(r[1]) == r[2], ("raw %d -> %s"):format(r[1], r[2]))
  end
end

T["just short of north wraps to north"] = function(assert_)
  local raw = O.NORTH_RAW - 1
  assert_(O.degrees(raw) > 315, "bearing is past north-west")
  assert_(O.compass(raw) == "NORTH", "and rounds to north, not off the end")
end

local function fail_on_report(v) error("an in-contract wire value was reported: " .. tostring(v)) end

T["wire sentinel is unknown with no bearing and no point"] = function(assert_)
  local raw = O.from_wire(O.WIRE_UNKNOWN, fail_on_report)
  assert_(raw == O.UNKNOWN_RAW, "0xFFFF decodes to UNKNOWN_RAW")
  assert_(not O.is_known(raw), "not known")
  assert_(O.degrees(raw) == nil, "no bearing")
  assert_(O.compass(raw) == nil, "no point")
end

T["wire angle decodes to itself"] = function(assert_)
  assert_(O.from_wire(O.NORTH_RAW, fail_on_report) == O.NORTH_RAW, "an angle is passed through")
end

T["from_wire degrades an out-of-contract value to unknown and reports it"] = function(assert_)
  for _, bad in ipairs({ O.FULL_TURN, 0xFFFE, -2 }) do
    local reported = {}
    local ok, raw = pcall(O.from_wire, bad, function(v) reported[#reported + 1] = v end)
    assert_(ok, ("%d must not raise at the wire"):format(bad))
    assert_(raw == O.UNKNOWN_RAW, ("%d decodes as unknown"):format(bad))
    assert_(#reported == 1 and reported[1] == bad, ("%d is reported"):format(bad))
  end
end

T["the api raises for an out-of-range raw"] = function(assert_)
  for _, bad in ipairs({ O.FULL_TURN, 0xFFFE, -2 }) do
    assert_(not pcall(O.degrees, bad), ("degrees(%d) must raise"):format(bad))
  end
end

T["wire decoder reports only the first out-of-contract value"] = function(assert_)
  local reported = {}
  local decode = O.wire_decoder(function(v) reported[#reported + 1] = v end)
  for _ = 1, 50 do assert_(decode(0xFFFE) == O.UNKNOWN_RAW, "unknown") end
  assert_(decode(O.FULL_TURN) == O.UNKNOWN_RAW, "a second bad value is unknown too")
  assert_(decode(O.NORTH_RAW) == O.NORTH_RAW, "a good value still decodes")
  assert_(#reported == 1 and reported[1] == 0xFFFE, "only the first is reported")
end

T["is_same_facing allows one unit of read-back"] = function(assert_)
  assert_(O.is_same_facing(O.NORTH_RAW - O.READBACK_TOLERANCE, O.NORTH_RAW), "one short matches")
  assert_(O.is_same_facing(O.FULL_TURN - 1, 0), "wraps around the turn")
  assert_(not O.is_same_facing(O.NORTH_RAW - 2, O.NORTH_RAW), "two apart does not match")
  assert_(not O.is_same_facing(O.UNKNOWN_RAW, O.UNKNOWN_RAW), "unknown matches nothing")
end

return T
