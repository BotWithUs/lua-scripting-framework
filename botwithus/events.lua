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
Events.KEY_INPUT       = 30
Events.ACTION_EXECUTED = 40
Events.ACTION_REFUSED  = 41

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
--   text_input_focused a text field had the keyboard, so scripts can ignore keys typed into chat.
--                      Coverage is incomplete until the agent's chat source lands: today it is set
--                      only for native text fields, and NOT while typing in chat.
--   is_repeat          autorepeat of a key that is already held.
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

local DECODERS = {
  [Events.KEY_INPUT]       = { name = "key_input", size = Events.KEY_INPUT_SIZE,
                               fn = decode_key_input },
  [Events.ACTION_EXECUTED] = { name = "action_executed", size = ACTION_EXECUTED_SIZE,
                               fn = decode_executed },
  [Events.ACTION_REFUSED]  = { name = "action_refused", size = ACTION_REFUSED_SIZE,
                               fn = decode_refused },
}

-- Decode one { type, body } record. Never raises. A known type comes back as a named table:
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
