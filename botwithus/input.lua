-- botwithus.input -- typing into the game's input dialog through synthetic key triggers.
--
-- The text-entry prompt ("Enter amount:", "Enter name of friend...") is MESLAYER interface
-- 1469. Its typed-key handler is the type-10 (key) CS2 trigger on component 1469:4
-- (MESLAYER__MES_TEXT2); component 0 has no triggers at all. That trigger exists only while
-- the dialog is open, so a key fired at a closed dialog is dropped by the agent.
--
-- A key is one ComponentTrigger (5003) action whose p3 is a packed KeyStroke,
-- (keyCode << 16) | keyChar: keyCode a signed 16-bit Jagex key code (NO_KEY_CODE for none),
-- keyChar a CP1252 character (identity for ASCII) or 0. The dialog reads printable
-- characters from the char half -- (-1, c) appends c -- and control keys from the code half:
-- ENTER (84, 0) submits, BACKSPACE (85, 0) deletes, ESCAPE (13, 0) cancels.
--
-- The agent dispatches one queued action per server tick (~600 ms), so N characters and
-- Enter take N+1 ticks. They go out in one queue_actions batch: one round trip, and
-- nothing else lands between them.
--
-- The dialog's mode is varc 5: 7 amount, 2 name, 0 closed. The dialog methods check the
-- mode before sending and return false when the dialog cannot take the input. Text the
-- dialog would reject raises an "input rejected:" error. Nothing is sent in either case.

local Actions = require("botwithus.actions")

local Input = {}

Input.NO_KEY_CODE      = -1
Input.TRIGGER_TYPE_KEY = 10
Input.SUB_NONE         = -1

Input.IFACE     = 1469
Input.COMP      = 4
Input.VARC_MODE = 5
Input.VARC_TEXT = 2506

Input.MODE_CLOSED = 0
Input.MODE_NAME   = 2
Input.MODE_AMOUNT = 7

Input.AMOUNT_MAX_LEN = 10
Input.NAME_MAX_LEN   = 12
-- The most actions the agent takes in one queue_actions call; it drops any past this.
Input.MAX_BATCH = 128

local U16_MAX = 0xFFFF
local I16_MIN, I16_MAX = -0x8000, 0x7FFF
local I32_MAX = 0x7FFFFFFF
local PRINTABLE_FIRST, PRINTABLE_LAST = 0x20, 0x7E
local AMOUNT_MULTIPLIER = { k = 1000, K = 1000, m = 1000000, M = 1000000 }
local MODE_NAMES = { [0] = "closed", [2] = "name", [7] = "amount" }

local function rejected(msg) error("input rejected: " .. msg, 3) end

-- Reinterpret an unsigned 32-bit pattern as the signed int the wire carries.
local function to_i32(v)
  v = v & 0xFFFFFFFF
  if v > I32_MAX then v = v - 0x100000000 end
  return v
end

local function check_range(name, v, lo, hi)
  if math.type(v) ~= "integer" or v < lo or v > hi then
    error(string.format("%s %s is not an integer in %d..%d", name, tostring(v), lo, hi), 3)
  end
end

-- KeyStroke: one key event, a Jagex key code (NO_KEY_CODE for none) and a CP1252 char (0 for none).
local KeyStroke = {}
KeyStroke.__index = KeyStroke
Input.KeyStroke = KeyStroke

function KeyStroke.new(key_code, key_char)
  key_char = key_char or 0
  check_range("key_code", key_code, I16_MIN, I16_MAX)
  check_range("key_char", key_char, 0, U16_MAX)
  return setmetatable({ key_code = key_code, key_char = key_char }, KeyStroke)
end

-- (key_code << 16) | key_char as the signed int32 the trigger's arg carries.
function KeyStroke:packed() return to_i32(((self.key_code & U16_MAX) << 16) | self.key_char) end

-- The char event (NO_KEY_CODE, c) for one printable ASCII character.
function KeyStroke.character(c)
  local b = type(c) == "string" and #c == 1 and c:byte() or nil
  if not b or b < PRINTABLE_FIRST or b > PRINTABLE_LAST then
    rejected("'" .. tostring(c) .. "' is not one printable ASCII character")
  end
  return KeyStroke.new(Input.NO_KEY_CODE, b)
end

Input.ENTER     = KeyStroke.new(84)
Input.BACKSPACE = KeyStroke.new(85)
Input.ESCAPE    = KeyStroke.new(13)

local function trigger(iface, comp, trigger_type, arg, sub)
  check_range("iface", iface, 0, U16_MAX)
  check_range("comp", comp, 0, U16_MAX)
  check_range("sub", sub, I16_MIN, I16_MAX)
  return {
    id = Actions.COMPONENT_TRIGGER,
    p1 = to_i32((iface << 16) | comp),
    p2 = to_i32((trigger_type << 16) | (sub & U16_MAX)),
    p3 = to_i32(arg),
  }
end

-- Fire any CS2 trigger type on a component. For a key trigger (type 10) an arg whose high
-- half is zero is taken as a bare Jagex key code and sent as arg << 16, so 84 is Enter
-- rather than the character 'T'. An arg with a non-zero high half is an already packed
-- KeyStroke and passes through.
function Input.component_trigger(iface, comp, trigger_type, arg, sub)
  arg, sub = arg or 0, sub or Input.SUB_NONE
  check_range("trigger_type", trigger_type, 0, I16_MAX)
  check_range("arg", arg, -0x80000000, 0xFFFFFFFF)
  if trigger_type == Input.TRIGGER_TYPE_KEY and arg > 0 and arg <= U16_MAX then arg = arg << 16 end
  return trigger(iface, comp, trigger_type, arg, sub)
end

-- The action that sends one KeyStroke to a component's key trigger.
function Input.key_action(iface, comp, stroke, sub)
  return trigger(iface, comp, Input.TRIGGER_TYPE_KEY, stroke:packed(), sub or Input.SUB_NONE)
end

-- Send `strokes` in order as one batch. Returns how many the agent queued.
function Input.fire_keys(game, iface, comp, strokes)
  if #strokes > Input.MAX_BATCH then
    error(#strokes .. " keys is more than one batch (" .. Input.MAX_BATCH .. ")", 2)
  end
  if #strokes == 0 then return 0 end
  local actions = {}
  for i, s in ipairs(strokes) do actions[i] = Input.key_action(iface, comp, s) end
  return game:queue_actions(actions)
end

local function strokes_of(text)
  local out = {}
  for i = 1, #text do out[i] = KeyStroke.character(text:sub(i, i)) end
  return out
end

-- Type printable ASCII `text` as one (NO_KEY_CODE, c) per character, without submitting.
function Input.type_text(game, iface, comp, text)
  return Input.fire_keys(game, iface, comp, strokes_of(text))
end

-- The text to type for `amount`: digits, optionally one k/K/m/M suffix, at most 10 chars.
-- An integer is typed as its digits. The value may not exceed 2^31-1: an amount the game
-- cannot hold is rejected rather than left to overflow.
function Input.validate_amount(amount)
  if type(amount) ~= "string" and math.type(amount) ~= "integer" then
    rejected("an amount must be an integer or a string, not " .. tostring(amount))
  end
  local text = tostring(amount)
  local digits, suffix = text:match("^(%d+)([kKmM]?)$")
  if not digits then rejected("amount '" .. text .. "' must be digits with at most one k/K/m/M suffix") end
  if #text > Input.AMOUNT_MAX_LEN then
    rejected("amount '" .. text .. "' is longer than " .. Input.AMOUNT_MAX_LEN .. " characters")
  end
  if math.tointeger(tonumber(digits)) * (AMOUNT_MULTIPLIER[suffix] or 1) > I32_MAX then
    rejected("amount '" .. text .. "' is larger than " .. I32_MAX)
  end
  return text
end

-- `text` if a name dialog would take it: 1..12 of letters, digits, space and _-.!
function Input.validate_name(text)
  if type(text) ~= "string" or not text:match("^[A-Za-z0-9 _%-%.!]+$") then
    rejected("name '" .. tostring(text) .. "' may hold only ASCII letters, digits, space and _-.! and not be empty")
  end
  if #text > Input.NAME_MAX_LEN then
    rejected("name '" .. text .. "' is longer than " .. Input.NAME_MAX_LEN .. " characters")
  end
  return text
end

-- The game's input dialog, read and typed into over one Game. Methods that send return
-- false, sending nothing, when the dialog is closed or in the wrong mode.
local Dialog = {}
Dialog.__index = Dialog

function Input.dialog(game) return setmetatable({ _game = game }, Dialog) end

-- varc 5 as the game holds it: 0 closed, 2 name, 7 amount, anything else unlisted.
function Dialog:mode_raw()
  local raw = self._game:varc_int(Input.VARC_MODE)
  if raw < 0 then
    error("input dialog: varc " .. Input.VARC_MODE .. " is unreadable (" .. raw .. "); not in game?", 2)
  end
  return raw
end

-- "amount", "name", "closed", or "other" for a mode not listed.
function Dialog:mode() return MODE_NAMES[self:mode_raw()] or "other" end

function Dialog:is_open() return self:mode_raw() ~= Input.MODE_CLOSED end

-- What has been typed so far (varc 2506), or "" when the dialog is closed.
function Dialog:text() return self:is_open() and self:_typed() or "" end

-- varc 2506 without the open check (the caller has already made it).
function Dialog:_typed() return self._game:varc_string(Input.VARC_TEXT) end

function Dialog:_send(strokes)
  local queued = Input.fire_keys(self._game, Input.IFACE, Input.COMP, strokes)
  if queued ~= #strokes then
    error(string.format("input dialog: the agent queued %d of %d keys (its queue is full?); "
      .. "the dialog may hold partial input", queued, #strokes), 3)
  end
  return true
end

local function with_enter(strokes) strokes[#strokes + 1] = Input.ENTER; return strokes end

-- Type an amount (500, "10k", "5m") and submit it.
function Dialog:enter_amount(amount)
  local text = Input.validate_amount(amount)
  if self:mode() ~= "amount" then return false end
  Input.validate_amount(self:_typed() .. text)
  return self:_send(with_enter(strokes_of(text)))
end

-- Type a name and submit it.
function Dialog:enter_text(text)
  Input.validate_name(text)
  if self:mode() ~= "name" then return false end
  Input.validate_name(self:_typed() .. text)
  return self:_send(with_enter(strokes_of(text)))
end

function Dialog:submit() return self:is_open() and self:_send({ Input.ENTER }) end
function Dialog:cancel() return self:is_open() and self:_send({ Input.ESCAPE }) end

function Dialog:backspace(count)
  count = count or 1
  check_range("count", count, 1, Input.MAX_BATCH)
  if not self:is_open() then return false end
  local strokes = {}
  for i = 1, count do strokes[i] = Input.BACKSPACE end
  return self:_send(strokes)
end

-- Delete everything typed so far: one Backspace per character of text().
function Dialog:clear()
  if not self:is_open() then return false end
  local typed = #self:_typed()
  if typed == 0 then return true end
  return self:backspace(typed)
end

return Input
