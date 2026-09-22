-- botwithus.variables -- varp and varbit reads that say WHY a value is what it is.
--
-- Varps are set lazily by the server, so most varps have no client-side entry at all, and a
-- value alone cannot tell you whether one is set: a set varp can hold -1, and so can a varp at
-- its default. Every read therefore carries a `state`, one of these strings:
--
--   "set"                         the client holds a value; `value` is it
--   "default_not_set_clientside"  the varp exists and the client holds no entry; `value` is
--                                 the default the game reads (usually 0; -1 for BOOLEAN-domain
--                                 and object-typed varps). The normal state of most varps.
--   "no_such_varp"                the cache has no such varp (for a varbit: no such varbit)
--   "unavailable"                 the read could not be made: not in the world, still
--                                 entering it, a bad id, a timeout. Says nothing about the varp.
--
-- Decide on `state`, never on `value`. Defaults come from the game cache through the native
-- host; when it cannot confirm one (an older NXTCache.dll, the cache still warming up) the
-- read is still "default_not_set_clientside" with value 0 and default_verified false.
--
-- A varbit takes its base variable's state and decodes the base's value -- for an unset base,
-- its default, exactly as the game reads it.
--
-- The composition happens in the native host (bwu_read_varps / bwu_read_varbits). This module
-- only names the numbers, and it maps them through the `bwu` table's own VARP_* / VAR_KIND_*
-- constants by name, so a renumbering on the host cannot silently misread.

local M = {}

M.SET          = "set"
M.DEFAULT      = "default_not_set_clientside"
M.NO_SUCH_VARP = "no_such_varp"
M.UNAVAILABLE  = "unavailable"

-- `value` of a read that has none (no_such_varp, unavailable). A set varp can hold it too.
M.NO_VALUE = -1

local STATE_CONSTANTS = {
  VARP_SET                        = M.SET,
  VARP_DEFAULT_NOT_SET_CLIENTSIDE = M.DEFAULT,
  VARP_NO_SUCH_VARP               = M.NO_SUCH_VARP,
  VARP_UNAVAILABLE                = M.UNAVAILABLE,
}

local KIND_CONSTANTS = {
  VAR_KIND_INT     = "int",
  VAR_KIND_LONG    = "long",
  VAR_KIND_STRING  = "string",
  VAR_KIND_UNKNOWN = "unknown",
}

local function number_map(b, names)
  local out = {}
  for name, label in pairs(names) do
    local n = b[name]
    if n == nil then
      error("botwithus: this bwu_host has no " .. name .. "; it predates varp state reads -- update it", 3)
    end
    out[n] = label
  end
  return out
end

local function native_fn(b, name)
  local fn = b[name]
  if fn == nil then
    error("botwithus: this bwu_host has no bwu." .. name .. "; it predates varp state reads -- update it", 3)
  end
  return fn
end

local function has_value(state) return state == M.SET or state == M.DEFAULT end

-- Turn the native records into reads. An out-of-contract state number is "unavailable" and an
-- unknown kind is "unknown": neither says anything about the varp.
local function decode(b, records, with_kind)
  local states = number_map(b, STATE_CONSTANTS)
  local kinds = with_kind and number_map(b, KIND_CONSTANTS) or nil
  local out = {}
  for i, r in ipairs(records) do
    local state = states[r.state] or M.UNAVAILABLE
    local read = {
      id = r.id,
      state = state,
      value = r.value,
      default_verified = r.default_verified,
      is_set = state == M.SET,
      has_value = has_value(state),
    }
    if with_kind then
      read.value64 = r.value64
      read.kind = kinds[r.kind] or "unknown"
    end
    out[i] = read
  end
  return out
end

local function read(b, host, fn_name, ids, with_kind)
  local records, err = native_fn(b, fn_name)(host, ids)
  if not records then error("botwithus: " .. fn_name .. " failed: " .. tostring(err), 3) end
  return decode(b, records, with_kind)
end

-- One read per id, in order: {id, state, value, value64, kind, default_verified, is_set,
-- has_value}. `value` is a LONG varp's low 32 bits; `value64` is the whole value. Any number of
-- ids (the native host batches at the agent's cap).
function M.read_varps(b, host, ids) return read(b, host, "read_varps", ids, true) end

-- One read per id, in order: {id, state, value, default_verified, is_set, has_value}.
function M.read_varbits(b, host, ids) return read(b, host, "read_varbits", ids, false) end

-- 1 once defaults come from the cache, 0 while it warms up after attach, -1 never.
function M.defaults_status(b) return native_fn(b, "varp_defaults_status")() end

return M
