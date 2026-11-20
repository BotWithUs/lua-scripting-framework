-- botwithus.events -- decode the agent's event records.
--
-- bwu.poll_events(host) hands back every event the agent published since the last call,
-- in order, as raw { type = <int>, body = <bytes> } records. Game:poll_events() runs each
-- one through Events.decode: the types this module knows come back as named tables, and
-- every other record passes through unchanged (still { type, body }), so nothing is lost.
--
-- Bodies are little-endian PODs whose layouts belong to the agent; the sizes below are the
-- agent's minimum. Bytes past them are ignored (a later agent may append fields). A body too
-- short to hold its fields is never read as wrong numbers: the record comes back raw, with
-- `error` saying why, and the rest of the batch still decodes -- the host ring is already
-- drained, so raising would lose every event read with it.

local Events = {}

-- Event type discriminators (the agent's numbering; permanent).
Events.VARP_CHANGE     = 10
Events.VARBIT_CHANGE   = 11
Events.VARC_CHANGE     = 12
Events.OBJ_VAR_CHANGE  = 13
Events.CHAT_MESSAGE    = 20
Events.KEY_INPUT       = 30
Events.ACTION_EXECUTED = 40
Events.ACTION_REFUSED  = 41
Events.HITMARK         = 70
Events.HEADBAR         = 71
Events.SPOT_ANIM       = 72

-- target_type in hitmark / headbar / spot_anim: the entity the event is on.
Events.TARGET_PLAYER = 0
Events.TARGET_NPC    = 1

-- Why a queued action was refused. No action_executed follows a refusal.
Events.REASON_NO_TARGET      = 1  -- the target does not exist, or the action has none to click
Events.REASON_ANCHOR_TIMEOUT = 2  -- the target never became clickable in time
Events.REASON_NO_OPENER      = 3  -- hidden behind a window or tab the agent cannot open

-- Which anchoring the action was waiting on when it was refused.
Events.ANCHOR_NONE   = 0
Events.ANCHOR_SCROLL = 1
Events.ANCHOR_OPEN   = 2
Events.ANCHOR_CAMERA = 3
Events.ANCHOR_WAIT   = 4  -- a transient miss

local REASON_NAMES = {
  [Events.REASON_NO_TARGET]      = "no_target",
  [Events.REASON_ANCHOR_TIMEOUT] = "anchor_timeout",
  [Events.REASON_NO_OPENER]      = "no_opener",
}

local ANCHOR_NAMES = {
  [Events.ANCHOR_NONE]   = "none",
  [Events.ANCHOR_SCROLL] = "scroll",
  [Events.ANCHOR_OPEN]   = "open",
  [Events.ANCHOR_CAMERA] = "camera",
  [Events.ANCHOR_WAIT]   = "wait",
}

local UNKNOWN = "unknown"

-- key_input flags bits (the byte at offset 7). Other bits are reserved and ignored.
Events.KEY_FLAG_SYNTHETIC          = 1  -- the agent's own send_key sent it
Events.KEY_FLAG_TEXT_INPUT_FOCUSED = 2  -- a text field had the keyboard (see decode_key_input)
Events.KEY_FLAG_REPEAT             = 4  -- autorepeat of a key already held

-- Body sizes, in bytes.
Events.KEY_INPUT_SIZE = 8         -- uint32 key, then uint8 isAlt, isCtrl, isShift, flags
local ACTION_EXECUTED_SIZE = 16   -- int32 actionId, param1, param2, param3
local ACTION_REFUSED_SIZE  = 28   -- the same four, then uint32 reason, anchorCase, heldMs

-- The readable name of a refusal reason / anchor case ("unknown" for a code this
-- framework does not know yet).
function Events.reason_name(code) return REASON_NAMES[code] or UNKNOWN end
function Events.anchor_name(code) return ANCHOR_NAMES[code] or UNKNOWN end

-- nil when `body` holds at least `size` bytes, else why it cannot be decoded.
local function size_error(name, body, size)
  if type(body) == "string" and #body >= size then return nil end
  return ("%s event body is %s bytes, expected at least %d; the host and framework"
    .. " disagree about the event layout"):format(name,
    type(body) == "string" and tostring(#body) or type(body), size)
end

local function decode_action(name, etype, body)
  local action_id, p1, p2, p3 = string.unpack("<i4i4i4i4", body)
  return { type = etype, name = name, action_id = action_id, param1 = p1, param2 = p2, param3 = p3 }
end

local function decode_executed(rec)
  return decode_action("action_executed", rec.type, rec.body)
end

local function decode_refused(rec)
  local ev = decode_action("action_refused", rec.type, rec.body)
  local reason, anchor, held_ms = string.unpack("<I4I4I4", rec.body, ACTION_EXECUTED_SIZE + 1)
  ev.reason, ev.reason_name = reason, Events.reason_name(reason)
  ev.anchor_case, ev.anchor_name = anchor, Events.anchor_name(anchor)
  ev.held_ms = held_ms
  return ev
end

-- One key-down as the game received it (key-up is not reported).
--   key                Windows virtual-key code: the generic VK_SHIFT (16), VK_CONTROL (17) and
--                      VK_MENU (18), never the left/right variants.
--   is_alt / is_ctrl / is_shift   the modifiers held, including the pressed key itself.
--   synthetic          the agent's own send_key sent this key, not the user.
--   text_input_focused a text field had the keyboard at the moment this key-down arrived: the chat
--                      line, bank search, a game prompt, the bug-report box, or a native input/list
--                      field. Scripts can use it to ignore keys typed into text. Known gap: the
--                      effect of the "always-on chat" setting is not established.
--   is_repeat          autorepeat of a key that is already held. Not set on autorepeats while the
--                      developer console is open; normal play is unaffected.
-- An older agent writes 0 in the flags byte, so all three flags read false against it.
local function has_flag(flags, bit) return flags & bit ~= 0 end

local function decode_key_input(rec)
  local key, alt, ctrl, shift, flags = string.unpack("<I4BBBB", rec.body)
  return {
    type = rec.type, name = "key_input", key = key,
    is_alt = alt ~= 0, is_ctrl = ctrl ~= 0, is_shift = shift ~= 0,
    synthetic          = has_flag(flags, Events.KEY_FLAG_SYNTHETIC),
    text_input_focused = has_flag(flags, Events.KEY_FLAG_TEXT_INPUT_FOCUSED),
    is_repeat          = has_flag(flags, Events.KEY_FLAG_REPEAT),
  }
end

-- Var changes. VarChangeBody / VarbitChangeBody: int32 id, oldValue, newValue (12 bytes). A
-- varc change reuses the varp shape with a varc id.
local VAR_CHANGE_SIZE = 12

local function decode_var(rec, name)
  local id, old, new = string.unpack("<i4i4i4", rec.body)
  return { type = rec.type, name = name, id = id, old_value = old, new_value = new }
end

-- ObjVarChangeBody: int32 invId, slot, varId, oldValue, newValue (20 bytes). A per-item var
-- on one inventory slot changed. No sibling framework decodes this one yet.
local OBJ_VAR_CHANGE_SIZE = 20

local function decode_obj_var(rec)
  local inv_id, slot, var_id, old, new = string.unpack("<i4i4i4i4i4", rec.body)
  return { type = rec.type, name = "obj_var_change", inv_id = inv_id, slot = slot,
           var_id = var_id, old_value = old, new_value = new }
end

-- ChatMessageBody: int32 msgType, uint16 senderLen, uint16 textLen, then the sender's bytes
-- immediately followed by the text's. The header is 8 bytes; a body whose lengths run past its
-- end is refused rather than read short.
local CHAT_HEADER_SIZE = 8

local function decode_chat(rec)
  local msg_type, sender_len, text_len = string.unpack("<i4I2I2", rec.body)
  local first = CHAT_HEADER_SIZE + 1
  if CHAT_HEADER_SIZE + sender_len + text_len > #rec.body then
    return { type = rec.type, body = rec.body, error = ("botwithus: chat_message event says %d"
      .. " + %d text bytes, but its body has %d after the header"):format(sender_len, text_len,
      #rec.body - CHAT_HEADER_SIZE) }
  end
  return { type = rec.type, name = "chat_message", msg_type = msg_type,
           sender = rec.body:sub(first, first + sender_len - 1),
           text = rec.body:sub(first + sender_len, first + sender_len + text_len - 1) }
end

-- Combat and scene events share a head: int32 targetServerIndex, int8 targetType, 3 pad bytes.
-- target_type is Events.TARGET_PLAYER (0) or TARGET_NPC (1).
local TARGET_HEAD = "<i4i1xxx"
local HITMARK_SIZE   = 20   -- head, int32 hitmarkType, damage, cycle (game_cycle units)
local HEADBAR_SIZE   = 16   -- head, int32 headbarType, value
local SPOT_ANIM_SIZE = 17   -- head, int32 spotAnimId, int16 tileX, tileY, int8 plane (+3 pad)

local function decode_hitmark(rec)
  local idx, ttype, hm_type, damage, cycle = string.unpack(TARGET_HEAD .. "i4i4i4", rec.body)
  return { type = rec.type, name = "hitmark", target_index = idx, target_type = ttype,
           hitmark_type = hm_type, damage = damage, cycle = cycle }
end

local function decode_headbar(rec)
  local idx, ttype, hb_type, value = string.unpack(TARGET_HEAD .. "i4i4", rec.body)
  return { type = rec.type, name = "headbar", target_index = idx, target_type = ttype,
           headbar_type = hb_type, value = value }
end

-- target_index is -1 for a spot anim on the world; then tile says where. On an entity, tile is
-- whatever the agent wrote and means nothing.
local function decode_spot_anim(rec)
  local idx, ttype, id, x, y, plane = string.unpack(TARGET_HEAD .. "i4i2i2i1", rec.body)
  return { type = rec.type, name = "spot_anim", target_index = idx, target_type = ttype,
           spot_anim_id = id, tile = { x = x, y = y, plane = plane } }
end

local DECODERS = {
  [Events.VARP_CHANGE]     = { name = "varp_change", size = VAR_CHANGE_SIZE,
                               fn = function(rec) return decode_var(rec, "varp_change") end },
  [Events.VARBIT_CHANGE]   = { name = "varbit_change", size = VAR_CHANGE_SIZE,
                               fn = function(rec) return decode_var(rec, "varbit_change") end },
  [Events.VARC_CHANGE]     = { name = "varc_change", size = VAR_CHANGE_SIZE,
                               fn = function(rec) return decode_var(rec, "varc_change") end },
  [Events.OBJ_VAR_CHANGE]  = { name = "obj_var_change", size = OBJ_VAR_CHANGE_SIZE,
                               fn = decode_obj_var },
  [Events.CHAT_MESSAGE]    = { name = "chat_message", size = CHAT_HEADER_SIZE, fn = decode_chat },
  [Events.HITMARK]         = { name = "hitmark", size = HITMARK_SIZE, fn = decode_hitmark },
  [Events.HEADBAR]         = { name = "headbar", size = HEADBAR_SIZE, fn = decode_headbar },
  [Events.SPOT_ANIM]       = { name = "spot_anim", size = SPOT_ANIM_SIZE, fn = decode_spot_anim },
  [Events.KEY_INPUT]       = { name = "key_input", size = Events.KEY_INPUT_SIZE,
                               fn = decode_key_input },
  [Events.ACTION_EXECUTED] = { name = "action_executed", size = ACTION_EXECUTED_SIZE,
                               fn = decode_executed },
  [Events.ACTION_REFUSED]  = { name = "action_refused", size = ACTION_REFUSED_SIZE,
                               fn = decode_refused },
}

-- Decode one { type, body } record. Never raises. A known type comes back as a named table:
--   varp_change / varbit_change / varc_change   { type, name, id, old_value, new_value }
--   obj_var_change   { type, name, inv_id, slot, var_id, old_value, new_value }
--   chat_message     { type, name, msg_type, sender, text } (sender and text as the bytes
--                      the game sent; msg_type is the game's own chat type)
--   hitmark          { type, name, target_index, target_type, hitmark_type, damage, cycle }
--   headbar          { type, name, target_index, target_type, headbar_type, value }
--   spot_anim        { type, name, target_index, target_type, spot_anim_id, tile }
--   key_input        { type, name, key, is_alt, is_ctrl, is_shift, synthetic,
--                      text_input_focused, is_repeat }
--   action_executed  { type, name, action_id, param1, param2, param3 }
--   action_refused   the same, plus reason / reason_name, anchor_case / anchor_name, held_ms
-- A known type whose body is too short comes back as { type, body, error = <why> }.
-- Any other record is returned as it was.
function Events.decode(rec)
  local d = DECODERS[rec.type]
  if d == nil then return rec end
  local err = size_error(d.name, rec.body, d.size)
  if err then return { type = rec.type, body = rec.body, error = "botwithus: " .. err } end
  return d.fn(rec)
end

-- Decode a list of records, in order.
function Events.decode_all(records)
  local out = {}
  for i, rec in ipairs(records) do out[i] = Events.decode(rec) end
  return out
end

return Events
