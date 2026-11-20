-- botwithus.gameval -- gameval names: the stable names the game ships for its ids, by type (the
-- Java host's gameval.GamevalIndex, GamevalType and GamevalRef).
--
--   local G = require("botwithus.gameval")
--   local yew = G.id("item", "YEW_LOGS")                          -- 1515, or nil, why
--   local iface, comp = G.component("BANK__BANK_INV_BUTTON")      -- 517, 39
--   local CURRENT_BAR = G.ref("varbit", "COMBATV2_ACTIONBAR_CURRENT_BAR", 1893)
--   game:varbit(CURRENT_BAR:id())                                 -- by name; 1893 if it cannot be
--
-- A gameval is unique within its type and survives a game update, so a module that names
-- BANK__BANK_INV_BUTTON keeps working when the id moves. TYPES are the Java GamevalType wire
-- strings (G.Type): "item", "npc", "loc", "varp", "varbit", "var_client", "component",
-- "interface", "enum", "struct", "quest", ... A component id is packed (iface << 16) | comp.
--
-- THE INDEX is the native host's (bwu.gameval_*, host ABI 8): the game's own index-67 tables in
-- the LOCAL game cache, read without the network, one type on its first lookup. Names match
-- case-insensitively. On an older host, with no local cache, or with an NXTCache that cannot read
-- them, G.available() is false and every lookup is nil, so code degrades rather than raises.
--
-- REFS carry the id the name had when the module was written. ref:id() returns the named id, or
-- that fallback with ONE warning per name on stderr when the name does not resolve.

local G = {}

G.ABI = 8
G.INTERFACE_ID_SHIFT = 16
G.COMPONENT_ID_MASK = 0xFFFF
G.DEFAULT_PREFIX_LIMIT = 100
-- How long an unavailable index waits before the host is asked again, in milliseconds.
G.RETRY_UNAVAILABLE_MS = 5000

G.Type = {
  ITEM = "item", NPC = "npc", LOC = "loc", INV = "inv", ENUM = "enum", STRUCT = "struct",
  PARAM = "param", SEQ = "seq", GRAPHIC = "graphic", QUEST = "quest", CATEGORY = "category",
  ACHIEVEMENT = "achievement", DBROW = "dbrow", DBTABLE = "dbtable", MAPELEMENT = "mapelement",
  INTERFACE = "interface", COMPONENT = "component", CURSOR = "cursor", HEADBAR = "headbar",
  HITMARK = "hitmark", STYLESHEET = "stylesheet", FONTMETRICS = "fontmetrics", UI_ANIM = "ui_anim",
  UI_ANIM_CURVE = "ui_anim_curve", VARP = "varp", VARBIT = "varbit", VAR_CLIENT = "var_client",
  VAR_NPC = "var_npc", VARBIT_NPC = "varbit_npc", VAR_OBJECT = "var_object",
  VARBIT_OBJECT = "varbit_object", VAR_CLAN = "var_clan", VARBIT_CLAN = "varbit_clan",
  VAR_CLAN_SETTING = "var_clan_setting", VARBIT_CLAN_SETTING = "varbit_clan_setting",
  VAR_PLAYER_GROUP = "var_player_group", MODEL = "model", MATERIAL = "material", SOUND = "sound",
  MIDI = "midi", BAS = "bas",
}

local function surface()
  local b = rawget(_G, "bwu")
  if b ~= nil and b.gameval_id ~= nil then return b end
  return nil
end

local function now_ms()
  local b = rawget(_G, "bwu")
  if b ~= nil and b.monotonic_ms ~= nil then return b.monotonic_ms() end
  return os.time() * 1000
end

-- The status, asked again only after RETRY_UNAVAILABLE_MS while unavailable.
local status = nil
local retry_at = 0

function G.available()
  local now = now_ms()
  local b = surface()
  -- Asked again when the surface itself changed (a test swapping its fake), or after the retry
  -- period while unavailable.
  if status == nil or status.surface ~= b or (not status.ok and now >= retry_at) then
    if b == nil then
      status = { ok = false, why = ("this bwu_host predates gameval names (host ABI %d)"):format(G.ABI) }
    else
      local ok, version_or_why = b.gameval_status()
      status = ok and { ok = true, version = version_or_why } or { ok = false, why = version_or_why }
    end
    status.surface = b
    retry_at = now + G.RETRY_UNAVAILABLE_MS
  end
  if status.ok then return true, status.version end
  return false, status.why
end

-- Forget the cached status and the warned names (tests).
function G._reset()
  status, retry_at = nil, 0
  G._warned = {}
end
G._warned = {}

-- The id named `name` of `type`, or nil, why ("not_found", or why there is no index).
function G.id(type, name)
  local ok, why = G.available()
  if not ok then return nil, why end
  return surface().gameval_id(type, name)
end

-- The name of `id` of `type`, or nil, why.
function G.name(type, id)
  local ok, why = G.available()
  if not ok then return nil, why end
  return surface().gameval_name(type, id)
end

-- { {id, name}, ... } of `type` starting with `prefix`, in name order, at most `limit` of them,
-- and how many match in all. Empty when there is no index. For tooling and diagnostics.
function G.starting_with(type, prefix, limit)
  if not G.available() then return {}, 0 end
  local rows, total = surface().gameval_prefix(type, prefix or "", limit or G.DEFAULT_PREFIX_LIMIT)
  return rows or {}, total or 0
end

function G.split(packed) return packed >> G.INTERFACE_ID_SHIFT, packed & G.COMPONENT_ID_MASK end
function G.pack(iface, comp) return (iface << G.INTERFACE_ID_SHIFT) | comp end

-- The interface and component ids of a COMPONENT name, or nil, why.
function G.component(name)
  local packed, why = G.id(G.Type.COMPONENT, name)
  if packed == nil then return nil, why end
  return G.split(packed)
end

local function warn_fallback(ref, why)
  local key = ref.type .. ":" .. ref.name
  if G._warned[key] then return end
  G._warned[key] = true
  io.stderr:write(("[botwithus.gameval] %s %s did not resolve (%s); using its fallback id %d\n")
    :format(ref.type, ref.name, tostring(why), ref.fallback))
end

local Ref = {}
Ref.__index = Ref

-- A name and the id it had when the code was written; for "component" the fallback is packed.
function G.ref(type, name, fallback)
  return setmetatable({ type = type, name = name, fallback = fallback }, Ref)
end

-- A COMPONENT ref from its fallback interface and component.
function G.component_ref(name, iface, comp)
  return G.ref(G.Type.COMPONENT, name, G.pack(iface, comp))
end

-- The id the name resolves to, else the fallback (with one warning per name).
function Ref:id()
  local found, why = G.id(self.type, self.name)
  if found ~= nil then return found end
  warn_fallback(self, why)
  return self.fallback
end

-- The interface and component of a COMPONENT ref.
function Ref:component() return G.split(self:id()) end

return G
