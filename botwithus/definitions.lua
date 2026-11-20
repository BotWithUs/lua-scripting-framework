-- botwithus.definitions -- cache definitions read through the native host (host ABI 7).
--
--   local Defs = require("botwithus.definitions")
--   local whip = Defs.item(4151)          -- { name, inventory_ops, ground_ops, stackable, noted, ... }
--   Defs.item_name(1512)                  -- "Logs": a note reads as its item, as the game shows it
--   Defs.npc(0).name, Defs.loc(1276).ops
--   Defs.params(Defs.CACHE_STRUCT, 4001)  -- { {param_id, kind, value | text}, ... }
--   Defs.json(Defs.CACHE_ENUM, 1234)      -- the long tail as NXTCache's JSON text
--
-- The native host links NXTCache.dll and reads each definition from the game cache once. No
-- client is needed. Item fixups match the Java host: ground op 3 reads "Take" when the cache
-- leaves it unset, and a noted item with no name of its own takes its unnoted item's name.
--
-- A missing id is nil. No cache, or an NXTCache.dll older than these reads, raises with the
-- host's reason; so does a bwu_host older than ABI 7.

local M = {}

-- bwu_host_surface.h BWU_CACHE_*: the type ids json / params take.
M.CACHE_ITEM     = 0
M.CACHE_NPC      = 1
M.CACHE_LOC      = 2
M.CACHE_ENUM     = 3
M.CACHE_STRUCT   = 4
M.CACHE_PARAM    = 5
M.CACHE_VARBIT   = 6
M.CACHE_INV      = 7
M.CACHE_QUEST    = 8
M.CACHE_WORLDMAP = 9

M.PARAM_INT    = 0
M.PARAM_STRING = 1

local NOT_FOUND = "not_found"

local function surface_fn(name)
  local b = rawget(_G, "bwu")
  if not b then error("botwithus: native `bwu` surface not present (run under bwu_host)", 3) end
  local fn = b[name]
  if fn == nil then
    error("botwithus: this bwu_host has no " .. name .. " (cache definitions); it predates"
          .. " them (native ABI 7) -- update it", 3)
  end
  return fn
end

-- One cache read: the value, nil for a missing id, or raise with the host's reason.
local function read(name, ...)
  local value, why = surface_fn(name)(...)
  if value ~= nil then return value end
  if why == NOT_FOUND then return nil end
  error("botwithus: " .. name .. ": " .. tostring(why), 3)
end

-- True when the cache opens; false (not an error) when it cannot or the host has no cache reads.
function M.available()
  local b = rawget(_G, "bwu")
  if not b or b.cache_status == nil then return false end
  return b.cache_status() == 1
end

function M.item(id) return read("cache_item", id) end
function M.npc(id) return read("cache_npc", id) end
function M.loc(id) return read("cache_loc", id) end

-- The params of an item, npc, loc, struct or quest, ascending param id.
function M.params(cache_type, id) return read("cache_params", cache_type, id) end

-- One int param, or nil when the definition does not set it.
function M.int_param(cache_type, id, param_id)
  for _, p in ipairs(M.params(cache_type, id) or {}) do
    if p.param_id == param_id and p.kind == M.PARAM_INT then return p.value end
  end
  return nil
end

-- The whole definition as NXTCache's JSON text, or nil for a missing id.
function M.json(cache_type, id) return read("cache_json", cache_type, id) end

-- Item names kept on this side: by-name matching asks for the same ids every loop. The surface
-- they came from is remembered, so a different `bwu` (another test, a re-install) starts over.
local names, names_from = {}, nil

-- The item's name as the game shows it, or nil for an empty slot (-1), an unknown id or a
-- nameless item.
function M.item_name(id)
  if id == nil or id < 0 then return nil end
  local b = rawget(_G, "bwu")
  if b ~= names_from then names, names_from = {}, b end
  local cached = names[id]
  if cached ~= nil then return cached or nil end
  local def = M.item(id)
  local name = def and def.name ~= "" and def.name or false
  names[id] = name
  return name or nil
end

-- Forget the names kept on this side.
function M.clear_item_names() names, names_from = {}, nil end

return M
