-- botwithus.input -- typing into the game's input dialog through synthetic key triggers.
--
-- The text-entry prompt ("Enter amount:", "Enter name of friend...") is MESLAYER interface
-- 1469. Its typed-key handler is the type-10 (key) CS2 trigger on component 1469:4;
-- component 0 has no triggers at all. That trigger exists only while the dialog is open,
-- so a key fired at a closed dialog is dropped by the agent.
--
-- A key is one ComponentTrigger (5003) action whose p3 packs (keyCode << 16) | keyChar:
-- keyCode a signed 16-bit Jagex key code (KEY_NONE for none), keyChar a CP1252 character
-- (identity for ASCII) or 0. The dialog reads printable characters from the char half --
-- (KEY_NONE, c) appends c -- and control keys from the code half: (KEY_ENTER, 0) submits,
-- (KEY_BACKSPACE, 0) deletes, (KEY_ESCAPE, 0) cancels.
--
-- The agent dispatches one queued action per server tick (~600 ms), so N characters and
-- Enter take N+1 ticks. They go out in one queue_actions batch: one round trip, and
-- nothing else lands between them.
--
-- The dialog's mode is varc 5: 7 amount, 2 name, 0 closed. The dialog methods check the
-- mode and the text against that mode's limits before sending anything. Input the dialog
-- would reject raises an "input rejected:" error and sends nothing.

local Actions = require("botwithus.actions")

local Input = {}

Input.KEY_NONE      = -1
Input.KEY_ENTER     = 84
Input.KEY_BACKSPACE = 85
Input.KEY_ESCAPE    = 13
Input.CHAR_NONE     = 0

Input.TRIGGER_TYPE_KEY = 10
Input.SUB_NONE         = -1

Input.IFACE           = 1469
Input.COMP            = 4
Input.VARC_MODE       = 5
Input.VARC_TEXT       = 2506

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
local AMOUNT_MULTIPLIER = { k = 1000, K = 1000, m = 1000000 }
local MODE_NAMES = { [0] = "closed", [2] = "name", [7] = "amount" }

local function rejected(msg) error("input rejected: " .. msg, 3) end
local function dialog_error(msg) error("input dialog: " .. msg, 3) end

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

-- One type-10 key event on a component, packed the way the agent unpacks it.
function Input.key_trigger(iface, comp, key_code, key_char, sub)
  key_code = key_code or Input.KEY_NONE
  key_char = key_char or Input.CHAR_NONE
  sub = sub or Input.SUB_NONE
  check_range("iface", iface, 0, U16_MAX)
  check_range("comp", comp, 0, U16_MAX)
  check_range("sub", sub, I16_MIN, I16_MAX)
  check_range("key_code", key_code, I16_MIN, I16_MAX)
  check_range("key_char", key_char, 0, U16_MAX)
  return {
    id = Actions.COMPONENT_TRIGGER,
    p1 = to_i32((iface << 16) | comp),
    p2 = to_i32((Input.TRIGGER_TYPE_KEY << 16) | (sub & U16_MAX)),
    p3 = to_i32(((key_code & U16_MAX) << 16) | key_char),
  }
end

-- The text to type for `amount`: digits, optionally one k/K/m suffix, at most 10 chars.
-- An integer is typed as its digits. The value may not exceed 2^31-1: an amount the game
-- cannot hold is rejected rather than left to overflow.
function Input.validate_amount(amount)
  if math.type(amount) == "float" then rejected("amount " .. amount .. " is not a whole number") end
  if type(amount) ~= "string" and math.type(amount) ~= "integer" then
    rejected("an amount must be an integer or a string, not a " .. type(amount))
  end
  local text = tostring(amount)
  local digits, suffix = text:match("^(%d+)([kKm]?)$")
  if not digits then rejected("amount '" .. text .. "' must be digits with at most one k, K or m suffix") end
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

-- The key events that type ASCII `text` -- one (KEY_NONE, c) per character -- then Enter.
function Input.typed_keys(text, submit, iface, comp)
  iface, comp = iface or Input.IFACE, comp or Input.COMP
  local keys = {}
  for i = 1, #text do
    keys[#keys + 1] = Input.key_trigger(iface, comp, Input.KEY_NONE, text:byte(i))
  end
  if submit then keys[#keys + 1] = Input.key_trigger(iface, comp, Input.KEY_ENTER) end
  return keys
end

local function key(code) return Input.key_trigger(Input.IFACE, Input.COMP, code) end

-- The game's input dialog, read and typed into over one Game.
local Dialog = {}
Dialog.__index = Dialog

function Input.dialog(game) return setmetatable({ _game = game }, Dialog) end

-- varc 5 as the game holds it: 0 closed, 2 name, 7 amount, anything else unlisted.
function Dialog:mode_raw()
  local raw = self._game:varc_int(Input.VARC_MODE)
  if raw < 0 then dialog_error("varc " .. Input.VARC_MODE .. " is unreadable (" .. raw .. "); not in game?") end
  return raw
end

-- "amount", "name", "closed", or "other" for a mode not listed.
function Dialog:mode() return MODE_NAMES[self:mode_raw()] or "other" end

function Dialog:is_open() return self:mode_raw() ~= Input.MODE_CLOSED end

-- What has been typed so far (varc 2506). It keeps its value after the dialog closes, so
-- it says nothing about whether the dialog is open.
function Dialog:text() return self._game:varc_string(Input.VARC_TEXT) end

function Dialog:_require_mode(wanted)
  local mode = self:mode()
  if mode ~= wanted then dialog_error("the input dialog is " .. mode .. ", not " .. wanted) end
end

function Dialog:_require_open()
  if not self:is_open() then dialog_error("the input dialog is not open") end
end

function Dialog:_send(keys)
  local queued = self._game:queue_actions(keys)
  if queued ~= #keys then
    dialog_error(string.format("the agent queued %d of %d keys (its queue is full?); "
      .. "the dialog may hold partial input", queued, #keys))
  end
end

-- Type an amount (500, "10k", "5m") into an open amount dialog; submits unless submit == false.
function Dialog:enter_amount(amount, submit)
  self:_require_mode("amount")
  local text = Input.validate_amount(amount)
  Input.validate_amount(self:text() .. text)
  self:_send(Input.typed_keys(text, submit ~= false))
end

-- Type a name into an open name dialog; submits unless submit == false.
function Dialog:enter_text(text, submit)
  self:_require_mode("name")
  Input.validate_name(text)
  Input.validate_name(self:text() .. text)
  self:_send(Input.typed_keys(text, submit ~= false))
end

function Dialog:submit() self:_require_open(); self:_send({ key(Input.KEY_ENTER) }) end
function Dialog:cancel() self:_require_open(); self:_send({ key(Input.KEY_ESCAPE) }) end

function Dialog:backspace(count)
  count = count or 1
  check_range("count", count, 1, Input.MAX_BATCH)
  self:_require_open()
  local keys = {}
  for i = 1, count do keys[i] = key(Input.KEY_BACKSPACE) end
  self:_send(keys)
end

-- Delete everything typed so far.
function Dialog:clear()
  self:_require_open()
  local typed = #self:text()
  if typed > 0 then self:backspace(typed) end
end

return Input
