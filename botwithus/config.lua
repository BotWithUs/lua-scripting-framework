-- botwithus.config -- declarative config fields for a plugin script.
--
-- A plugin script declares the settings the GUI shows as `config_fields`: a sequence of
-- field tables, or a function returning one. Each field uses the keys the GUI reads:
--
--   key          1..64 bytes of [A-Za-z0-9_.-], unique in the script
--   kind         "int", "string", "bool", "choice" or "item_id"
--   label        1..128 bytes
--   default      a valid value for the field (see below)
--   description  optional tooltip, 1..1024 bytes
--   int:     min / max (optional, within int32, min <= max), step (optional, 1..2147483647;
--            a UI hint)
--   string:  max_len (optional, 1..4096, default 256)
--   choice:  options, a sequence of 1..64 distinct strings of 1..128 bytes
--
-- Valid values: an int within [min, max]; a string of at most max_len bytes of UTF-8; a
-- boolean (never 0 / 1); a choice equal to one of its options; an item id from -1 ("no
-- item") to 2147483647.
--
-- The helpers below build those tables, mirroring the Java host's ConfigField factories.
-- The schema rules are deliberately stricter than the Java host's in four places: a choice
-- default must be one of its options, a choice needs at least one option, an item id
-- default must be -1 or more, and a string default over 256 bytes needs a larger max_len.
--
-- The native host validates the schema when a script is described or run. M.validate_fields
-- and M.validate_manifest are the same per-field checks in Lua: bot.run uses them when the
-- host surface cannot validate. One rule is checked by the host only: the whole schema must
-- fit one message to the GUI (every string at its max_len, every choice at its longest
-- option), which refuses, say, 256 string fields of max_len 4096.

local M = {}

local INT32_MIN, INT32_MAX = -2147483648, 2147483647
local ITEM_NONE = -1
local DEFAULT_MAX_LEN, MAX_MAX_LEN = 256, 4096
local MAX_FIELDS, MAX_OPTIONS = 256, 64
local KEY_MAX, LABEL_MAX, DESCRIPTION_MAX, OPTION_MAX = 64, 128, 1024, 128
local NAME_MAX, VERSION_MAX, AUTHOR_MAX, MANIFEST_DESCRIPTION_MAX, CATEGORY_MAX =
  128, 64, 128, 4096, 64

M.ITEM_NONE = ITEM_NONE
M.DEFAULT_MAX_LEN = DEFAULT_MAX_LEN
M.KINDS = { int = true, string = true, bool = true, choice = true, item_id = true }

-- Copy the optional keys a helper accepts from `opts` into `field`.
local function with(field, opts, keys)
  for _, k in ipairs(keys) do
    if opts and opts[k] ~= nil then field[k] = opts[k] end
  end
  return field
end

-- int_field(key, label, default, { min, max, step, description })
function M.int_field(key, label, default, opts)
  return with({ key = key, kind = "int", label = label, default = default }, opts,
              { "description", "min", "max", "step" })
end

-- string_field(key, label, default, { max_len, description })
function M.string_field(key, label, default, opts)
  return with({ key = key, kind = "string", label = label, default = default }, opts,
              { "description", "max_len" })
end

-- bool_field(key, label, default, { description })
function M.bool_field(key, label, default, opts)
  return with({ key = key, kind = "bool", label = label, default = default }, opts,
              { "description" })
end

-- choice_field(key, label, options, default, { description })
function M.choice_field(key, label, options, default, opts)
  return with({ key = key, kind = "choice", label = label, default = default, options = options },
              opts, { "description" })
end

-- item_id_field(key, label, default, { description }); default -1 means "no item"
function M.item_id_field(key, label, default, opts)
  return with({ key = key, kind = "item_id", label = label,
                default = default == nil and ITEM_NONE or default }, opts, { "description" })
end

-- An integer value: a Lua integer, or a float with an exact integral value.
local function as_integer(v)
  if math.type(v) == "integer" then return v end
  if math.type(v) == "float" then return math.tointeger(v) end
  return nil
end
M.as_integer = as_integer

local function check_text(v, path, lo, hi)
  if type(v) ~= "string" then return path .. ": expected a string" end
  if not utf8.len(v) then return path .. ": not valid UTF-8" end
  if #v < lo or #v > hi then
    return string.format("%s: must be %d..%d bytes, got %d", path, lo, hi, #v)
  end
  return nil
end

local function check_optional_text(v, path, lo, hi)
  if v == nil then return nil end
  return check_text(v, path, lo, hi)
end

local function check_int_bound(v, path)
  local i = as_integer(v)
  if i == nil then return nil, path .. ": expected an integer" end
  if i < INT32_MIN or i > INT32_MAX then return nil, path .. ": outside int32" end
  return i
end

-- The kind-specific rules. Each returns nil when the field is valid, else "<path>: <detail>".
local KIND_CHECKS = {}

function KIND_CHECKS.int(f, path)
  local lo, hi = INT32_MIN, INT32_MAX
  local err
  if f.min ~= nil then lo, err = check_int_bound(f.min, path .. ".min"); if err then return err end end
  if f.max ~= nil then hi, err = check_int_bound(f.max, path .. ".max"); if err then return err end end
  if lo > hi then return path .. ".min: greater than max" end
  if f.step ~= nil then
    local step = as_integer(f.step)
    if step == nil then return path .. ".step: expected an integer" end
    if step < 1 or step > INT32_MAX then return path .. ".step: must be 1..2147483647" end
  end
  local d = as_integer(f.default)
  if d == nil then return path .. ".default: expected an integer" end
  if d < lo or d > hi then return path .. ".default: outside [min, max]" end
  return nil
end

function KIND_CHECKS.string(f, path)
  local max_len = DEFAULT_MAX_LEN
  if f.max_len ~= nil then
    max_len = as_integer(f.max_len)
    if max_len == nil then return path .. ".max_len: expected an integer" end
    if max_len < 1 or max_len > MAX_MAX_LEN then return path .. ".max_len: must be 1..4096" end
  end
  return check_text(f.default, path .. ".default", 0, max_len)
end

function KIND_CHECKS.bool(f, path)
  if type(f.default) ~= "boolean" then return path .. ".default: expected a boolean" end
  return nil
end

function KIND_CHECKS.choice(f, path)
  local options = f.options
  if type(options) ~= "table" then return path .. ".options: expected a sequence" end
  if #options < 1 or #options > MAX_OPTIONS then return path .. ".options: must hold 1..64 options" end
  local seen = {}
  for i, o in ipairs(options) do
    local opath = string.format("%s.options[%d]", path, i - 1)
    local err = check_text(o, opath, 1, OPTION_MAX)
    if err then return err end
    if seen[o] then return opath .. ": duplicate option" end
    seen[o] = true
  end
  if type(f.default) ~= "string" then return path .. ".default: expected a string" end
  if not seen[f.default] then return path .. ".default: not one of the options" end
  return nil
end

function KIND_CHECKS.item_id(f, path)
  local d = as_integer(f.default)
  if d == nil then return path .. ".default: expected an integer" end
  if d < ITEM_NONE or d > INT32_MAX then return path .. ".default: must be -1..2147483647" end
  return nil
end

local function check_field(f, path, keys)
  if type(f) ~= "table" then return path .. ": expected a field table" end
  local err = check_text(f.key, path .. ".key", 1, KEY_MAX)
  if err then return err end
  if f.key:find("[^%w_%.%-]") then return path .. ".key: only [A-Za-z0-9_.-] allowed" end
  if keys[f.key] then return path .. ".key: duplicate key " .. f.key end
  keys[f.key] = true
  if type(f.kind) ~= "string" then return path .. ".kind: expected a string" end
  if not M.KINDS[f.kind] then return path .. ".kind: unknown kind " .. f.kind end
  err = check_text(f.label, path .. ".label", 1, LABEL_MAX)
  if err then return err end
  err = check_optional_text(f.description, path .. ".description", 1, DESCRIPTION_MAX)
  if err then return err end
  return KIND_CHECKS[f.kind](f, path)
end

-- Validate a sequence of fields. Returns true, or nil and "<key path>: <detail>".
function M.validate_fields(fields)
  if type(fields) ~= "table" then return nil, "config_schema: expected a sequence" end
  if #fields > MAX_FIELDS then return nil, "config_schema: more than 256 fields" end
  local keys = {}
  for i, f in ipairs(fields) do
    local err = check_field(f, string.format("config_schema[%d]", i - 1), keys)
    if err then return nil, err end
  end
  return true
end

-- Validate a manifest table. Returns true, or nil and "<key path>: <detail>".
function M.validate_manifest(m)
  if type(m) ~= "table" then return nil, "manifest: expected a table" end
  local err = check_text(m.name, "manifest.name", 1, NAME_MAX)
    or check_text(m.version, "manifest.version", 1, VERSION_MAX)
    or check_text(m.author, "manifest.author", 0, AUTHOR_MAX)
    or check_text(m.description, "manifest.description", 0, MANIFEST_DESCRIPTION_MAX)
    or check_optional_text(m.category, "manifest.category", 1, CATEGORY_MAX)
  if err then return nil, err end
  return true
end

-- Normalise one field's default to the type the host hands back (an int as a Lua integer).
local function typed_default(f)
  if f.kind == "int" or f.kind == "item_id" then return as_integer(f.default) or f.default end
  return f.default
end

-- The defaults of a field sequence, key -> value. Not validated: call M.validate_fields first
-- when the fields come from a script.
function M.defaults(fields)
  local out = {}
  for _, f in ipairs(fields or {}) do
    if type(f) == "table" and f.key ~= nil then out[f.key] = typed_default(f) end
  end
  return out
end

-- The fields a script table declares: config_fields as a sequence, or a function
-- config_fields(script) returning one. Absent means none. Raises on a non-table result.
function M.fields_of(script)
  local cf = script.config_fields
  if cf == nil then return {} end
  if type(cf) == "function" then cf = cf(script) end
  if cf == nil then return {} end
  if type(cf) ~= "table" then
    error("config_fields: expected a sequence of field tables, got " .. type(cf), 0)
  end
  local out = {}
  for i, f in ipairs(cf) do out[i] = f end
  return out
end

-- The manifest a script reports, with the defaults filled: name -> `stem`, version -> "1.0",
-- author and description -> "". Raises when the script's manifest is not a table.
function M.manifest_of(script, stem)
  local m = script.manifest
  if m == nil then m = {} end
  if type(m) ~= "table" then error("manifest: expected a table, got " .. type(m), 0) end
  local out = { name = m.name, version = m.version, author = m.author,
                description = m.description, category = m.category }
  if out.name == nil then out.name = stem end
  if out.version == nil then out.version = "1.0" end
  if out.author == nil then out.author = "" end
  if out.description == nil then out.description = "" end
  return out
end

return M
