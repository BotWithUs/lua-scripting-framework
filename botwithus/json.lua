-- botwithus.json -- a small JSON decoder for the cache's JSON tail (definitions.json).
--
--   local Json = require("botwithus.json")
--   local enum = Json.decode(Defs.json(Defs.CACHE_ENUM, 13319))
--
-- Objects become tables keyed by their (string) keys, arrays become 1-based lists, whole numbers
-- become integers (so `entries["11"] == 4` compares as the game value) and JSON null becomes nil.
-- A malformed document raises with the byte position. There is no encoder: nothing in the
-- framework sends JSON.

local Json = {}

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n",
                  r = "\r", t = "\t" }

local function fail(text, pos, what)
  error(("botwithus.json: %s at byte %d near %q"):format(what, pos, text:sub(pos, pos + 10)), 0)
end

local function skip_space(text, pos)
  return text:find("[^ \t\r\n]", pos) or #text + 1
end

-- One \uXXXX code point (surrogate pairs joined) as UTF-8, and the position after it.
local function unicode_escape(text, pos)
  local hex = text:match("^%x%x%x%x", pos)
  if not hex then fail(text, pos, "bad \\u escape") end
  local cp = tonumber(hex, 16)
  pos = pos + 4
  if cp >= 0xD800 and cp <= 0xDBFF then
    local low = text:match("^\\u(%x%x%x%x)", pos)
    if low then
      cp = 0x10000 + ((cp - 0xD800) << 10) + (tonumber(low, 16) - 0xDC00)
      pos = pos + 6
    end
  end
  return utf8.char(cp), pos
end

local function decode_string(text, pos)
  local parts, i = {}, pos + 1
  while true do
    local stop = text:find('["\\]', i)
    if not stop then fail(text, pos, "unterminated string") end
    parts[#parts + 1] = text:sub(i, stop - 1)
    if text:sub(stop, stop) == '"' then return table.concat(parts), stop + 1 end
    local esc = text:sub(stop + 1, stop + 1)
    if esc == "u" then
      parts[#parts + 1], i = unicode_escape(text, stop + 2)
    elseif ESCAPES[esc] then
      parts[#parts + 1], i = ESCAPES[esc], stop + 2
    else
      fail(text, stop, "bad escape")
    end
  end
end

local function decode_number(text, pos)
  local num = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
  if not num or num == "" or num == "-" then fail(text, pos, "bad number") end
  local value = math.tointeger(tonumber(num)) or tonumber(num)
  if value == nil then fail(text, pos, "bad number") end
  return value, pos + #num
end

local decode_value

local function decode_array(text, pos)
  local out, n = {}, 0
  pos = skip_space(text, pos + 1)
  if text:sub(pos, pos) == "]" then return out, pos + 1 end
  while true do
    local value
    value, pos = decode_value(text, pos)
    n = n + 1
    out[n] = value
    pos = skip_space(text, pos)
    local c = text:sub(pos, pos)
    if c == "]" then return out, pos + 1 end
    if c ~= "," then fail(text, pos, "expected , or ]") end
    pos = skip_space(text, pos + 1)
  end
end

local function decode_object(text, pos)
  local out = {}
  pos = skip_space(text, pos + 1)
  if text:sub(pos, pos) == "}" then return out, pos + 1 end
  while true do
    if text:sub(pos, pos) ~= '"' then fail(text, pos, "expected a key") end
    local key
    key, pos = decode_string(text, pos)
    pos = skip_space(text, pos)
    if text:sub(pos, pos) ~= ":" then fail(text, pos, "expected :") end
    out[key], pos = decode_value(text, skip_space(text, pos + 1))
    pos = skip_space(text, pos)
    local c = text:sub(pos, pos)
    if c == "}" then return out, pos + 1 end
    if c ~= "," then fail(text, pos, "expected , or }") end
    pos = skip_space(text, pos + 1)
  end
end

local LITERALS = { ["true"] = true, ["false"] = false }

function decode_value(text, pos)
  pos = skip_space(text, pos)
  local c = text:sub(pos, pos)
  if c == "{" then return decode_object(text, pos) end
  if c == "[" then return decode_array(text, pos) end
  if c == '"' then return decode_string(text, pos) end
  for word, value in pairs(LITERALS) do
    if text:sub(pos, pos + #word - 1) == word then return value, pos + #word end
  end
  if text:sub(pos, pos + 3) == "null" then return nil, pos + 4 end
  return decode_number(text, pos)
end

-- The value `text` holds. Raises on malformed JSON or trailing text.
function Json.decode(text)
  if type(text) ~= "string" then error("botwithus.json: decode takes a string", 2) end
  local value, pos = decode_value(text, 1)
  pos = skip_space(text, pos)
  if pos <= #text then fail(text, pos, "trailing text") end
  return value
end

-- An enum's entries as an integer-keyed table: { [key] = value }. String keys that are whole
-- numbers become integers, as the cache stores them.
function Json.int_keys(entries)
  local out = {}
  for k, v in pairs(entries or {}) do out[math.tointeger(tonumber(k)) or k] = v end
  return out
end

return Json
