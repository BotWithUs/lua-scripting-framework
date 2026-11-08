-- spec/events_spec.lua -- decoding the agent's event records.
--
-- The bodies are written out byte by byte (little-endian) rather than built with
-- string.pack, so the spec does not share the decoder's format strings.

local fake_bwu = require("spec.fake_bwu")
local bot      = require("botwithus")
local Events   = require("botwithus.events")

local T = {}

local function bytes(t)
  local out = {}
  for i, b in ipairs(t) do out[i] = string.char(b) end
  return table.concat(out)
end

-- action_refused: Component 57, option 1, no sub-slot, 1433:69; anchor_timeout while
-- waiting on "open", held 4500 ms. 28 bytes.
local REFUSED = bytes({
  0x39, 0x00, 0x00, 0x00,   -- actionId 57
  0x01, 0x00, 0x00, 0x00,   -- param1 1
  0xFF, 0xFF, 0xFF, 0xFF,   -- param2 -1
  0x45, 0x00, 0x99, 0x05,   -- param3 0x05990045 = (1433 << 16) | 69
  0x02, 0x00, 0x00, 0x00,   -- reason 2 anchor_timeout
  0x02, 0x00, 0x00, 0x00,   -- anchorCase 2 open
  0x94, 0x11, 0x00, 0x00,   -- heldMs 4500
})

T["action_refused decodes every field from a 28-byte body"] = function(assert_)
  assert_(#REFUSED == 28, "the body is 28 bytes")
  local ev = Events.decode({ type = 41, body = REFUSED })
  assert_(ev.name == "action_refused" and ev.type == 41, "named action_refused")
  assert_(ev.action_id == 57, "action_id " .. tostring(ev.action_id))
  assert_(ev.param1 == 1 and ev.param2 == -1 and ev.param3 == 93913157,
    ("params %s %s %s"):format(tostring(ev.param1), tostring(ev.param2), tostring(ev.param3)))
  assert_(ev.reason == 2 and ev.reason_name == "anchor_timeout", "reason " .. tostring(ev.reason_name))
  assert_(ev.anchor_case == 2 and ev.anchor_name == "open", "anchor " .. tostring(ev.anchor_name))
  assert_(ev.held_ms == 4500, "held_ms " .. tostring(ev.held_ms))
end

T["action_refused reason and anchor fields are unsigned"] = function(assert_)
  local body = REFUSED:sub(1, 16) .. bytes({ 0x01, 0, 0, 0, 0x04, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF })
  local ev = Events.decode({ type = 41, body = body })
  assert_(ev.reason_name == "no_target" and ev.anchor_name == "wait", "no_target / wait")
  assert_(ev.held_ms == 4294967295, "held_ms reads unsigned: " .. tostring(ev.held_ms))
end

T["every reason and anchor code has its name"] = function(assert_)
  local reasons = { [1] = "no_target", [2] = "anchor_timeout", [3] = "no_opener" }
  for code, name in pairs(reasons) do
    assert_(Events.reason_name(code) == name, "reason " .. code)
  end
  local anchors = { [0] = "none", [1] = "scroll", [2] = "open", [3] = "camera", [4] = "wait" }
  for code, name in pairs(anchors) do
    assert_(Events.anchor_name(code) == name, "anchor " .. code)
  end
  assert_(Events.reason_name(9) == "unknown" and Events.anchor_name(9) == "unknown", "unknown codes")
end

T["action_refused of the wrong size is refused loudly"] = function(assert_)
  local ok, err = pcall(Events.decode, { type = 41, body = REFUSED:sub(1, 16) })
  assert_(not ok and tostring(err):find("16 bytes, expected 28", 1, true), tostring(err))
end

T["action_executed decodes the four ints"] = function(assert_)
  local ev = Events.decode({ type = 40, body = REFUSED:sub(1, 16) })
  assert_(ev.name == "action_executed" and ev.action_id == 57 and ev.param3 == 93913157, "decoded")
  assert_(ev.reason == nil, "no refusal fields")
end

T["unknown event types pass through unchanged"] = function(assert_)
  local rec = { type = 2, body = bytes({ 1, 0, 0, 0 }) }
  assert_(Events.decode(rec) == rec, "same record back")
end

T["Game:poll_events decodes in order and drains"] = function(assert_)
  _G.bwu = fake_bwu.new({ events = {
    { type = 2, body = bytes({ 7, 0, 0, 0 }) },
    { type = 41, body = REFUSED },
  } })
  local g = bot.Game.attach()
  local evs = g:poll_events()
  assert_(#evs == 2, "two events")
  assert_(evs[1].type == 2 and evs[1].body ~= nil, "raw tick passes through")
  assert_(evs[2].name == "action_refused" and evs[2].reason_name == "anchor_timeout", "refusal decoded")
  assert_(#g:poll_events() == 0, "a second poll is empty")
end

return T
