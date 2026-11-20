-- spec/events_parity_spec.lua -- the var, obj var, chat, hitmark, headbar and spot anim events.
--
-- Bodies are written out byte by byte (little-endian), as in events_spec, so the spec does not
-- share the decoder's format strings. Every value is nonzero and distinct, so a field read from
-- the wrong offset cannot pass.

local Events = require("botwithus.events")

local T = {}

local function bytes(t)
  local out = {}
  for i, b in ipairs(t) do out[i] = string.char(b) end
  return table.concat(out)
end

-- id 1234 (0x4D2), old -1, new 70000 (0x11170). 12 bytes.
local VAR = bytes({
  0xD2, 0x04, 0x00, 0x00,
  0xFF, 0xFF, 0xFF, 0xFF,
  0x70, 0x11, 0x01, 0x00,
})

T["varp, varbit and varc changes decode id, old and new"] = function(assert_)
  for etype, name in pairs({ [10] = "varp_change", [11] = "varbit_change", [12] = "varc_change" }) do
    local ev = Events.decode({ type = etype, body = VAR })
    assert_(ev.name == name and ev.type == etype, name .. ": " .. tostring(ev.error))
    assert_(ev.id == 1234 and ev.old_value == -1 and ev.new_value == 70000,
      ("%s: %s %s %s"):format(name, tostring(ev.id), tostring(ev.old_value), tostring(ev.new_value)))
  end
  assert_(Events.VARP_CHANGE == 10 and Events.VARBIT_CHANGE == 11 and Events.VARC_CHANGE == 12,
    "the agent's numbering")
end

T["obj_var_change decodes inventory, slot, var, old and new"] = function(assert_)
  local body = bytes({
    0x5D, 0x00, 0x00, 0x00,   -- invId 93
    0x03, 0x00, 0x00, 0x00,   -- slot 3
    0x37, 0x00, 0x00, 0x00,   -- varId 55
    0x0A, 0x00, 0x00, 0x00,   -- old 10
    0x0B, 0x00, 0x00, 0x00,   -- new 11
  })
  local ev = Events.decode({ type = 13, body = body })
  assert_(ev.name == "obj_var_change", tostring(ev.error))
  assert_(ev.inv_id == 93 and ev.slot == 3 and ev.var_id == 55, "where")
  assert_(ev.old_value == 10 and ev.new_value == 11, "values")
  local short = Events.decode({ type = 13, body = body:sub(1, 16) })
  assert_(short.error and short.name == nil, "a 16-byte obj var body is refused")
end

-- msgType 2, sender "Bob" (3), text "hi there" (8), then the agent's zero padding to 112.
local function chat_body(sender_len, text_len)
  return bytes({ 0x02, 0x00, 0x00, 0x00, sender_len, 0x00, text_len, 0x00 })
    .. "Bob" .. "hi there" .. string.rep("\0", 112 - 8 - 11)
end

T["chat_message splits sender and text by their lengths"] = function(assert_)
  local ev = Events.decode({ type = 20, body = chat_body(3, 8) })
  assert_(ev.name == "chat_message", tostring(ev.error))
  assert_(ev.msg_type == 2 and ev.sender == "Bob" and ev.text == "hi there",
    ("%q %q"):format(tostring(ev.sender), tostring(ev.text)))
  local empty = Events.decode({ type = 20, body = chat_body(0, 0) })
  assert_(empty.sender == "" and empty.text == "", "zero lengths are empty strings")
end

T["chat_message whose lengths run past the body is refused, not read short"] = function(assert_)
  local body = chat_body(3, 8):sub(1, 14)   -- 6 bytes after the header for 11 claimed
  local ok, ev = pcall(Events.decode, { type = 20, body = body })
  assert_(ok, "decode does not raise")
  assert_(ev.error and ev.name == nil and ev.body == body, tostring(ev.error))
end

T["hitmark decodes target, type, damage and cycle"] = function(assert_)
  local ev = Events.decode({ type = 70, body = bytes({
    0x1E, 0x00, 0x00, 0x00,   -- target 30
    0x01, 0xEE, 0xEE, 0xEE,   -- npc, then three pad bytes that must be skipped
    0x84, 0x00, 0x00, 0x00,   -- hitmarkType 132
    0xFA, 0x00, 0x00, 0x00,   -- damage 250
    0x8D, 0x13, 0x00, 0x00,   -- cycle 5005
  }) })
  assert_(ev.name == "hitmark", tostring(ev.error))
  assert_(ev.target_index == 30 and ev.target_type == Events.TARGET_NPC, "target")
  assert_(ev.hitmark_type == 132 and ev.damage == 250 and ev.cycle == 5005, "fields")
end

T["headbar decodes target, type and value"] = function(assert_)
  local ev = Events.decode({ type = 71, body = bytes({
    0x07, 0x00, 0x00, 0x00,   -- target 7
    0x00, 0x00, 0x00, 0x00,   -- player
    0x07, 0x00, 0x00, 0x00,   -- headbarType 7
    0xC8, 0x00, 0x00, 0x00,   -- value 200
  }) })
  assert_(ev.name == "headbar", tostring(ev.error))
  assert_(ev.target_index == 7 and ev.target_type == Events.TARGET_PLAYER, "target")
  assert_(ev.headbar_type == 7 and ev.value == 200, "fields")
end

T["spot_anim decodes a world-anchored anim and its tile"] = function(assert_)
  local body = bytes({
    0xFF, 0xFF, 0xFF, 0xFF,   -- target -1: on the world
    0x01, 0x00, 0x00, 0x00,
    0x64, 0x08, 0x00, 0x00,   -- spotAnimId 2148
    0x96, 0x0C,               -- tileX 3222
    0x92, 0x0C,               -- tileY 3218
    0x02, 0x00, 0x00, 0x00,   -- plane 2, pad
  })
  local ev = Events.decode({ type = 72, body = body })
  assert_(ev.name == "spot_anim", tostring(ev.error))
  assert_(ev.target_index == -1 and ev.spot_anim_id == 2148, "anim")
  assert_(ev.tile.x == 3222 and ev.tile.y == 3218 and ev.tile.plane == 2, "tile")
  local short = Events.decode({ type = 72, body = body:sub(1, 16) })
  assert_(short.error ~= nil, "a body without the plane byte is refused")
end

return T
