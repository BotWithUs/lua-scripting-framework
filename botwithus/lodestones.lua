-- botwithus.lodestones -- the lodestone network: which lodestones are unlocked, and teleporting
-- to one or to the previous destination (the Java host's world.Lodestone and LodestoneNetwork).
--
--   local Lodestones = require("botwithus.lodestones")
--   local net = Lodestones.new(game)
--   if net:is_unlocked("BURTHORPE") then
--     local result = net:teleport("BURTHORPE")     -- "arrived", "locked", "timed_out", ...
--   end
--
-- teleport() opens the network from the minimap home button's "Lodestone Network" op, clicks the
-- lodestone, and waits (ctx-style, stop-aware: see botwithus.timing) until the player has moved
-- at least 20 tiles or changed plane, then for the landing animation to end. Right after an
-- arrival the game refuses the network with "Please finish what you're doing before opening the
-- lodestone network.", so the open is retried once, and the settle wait is what lets a second
-- teleport straight after the first one work. No camera and no desktop input: every click goes
-- through the action queue.
--
-- Results: Lodestones.ARRIVED, LOCKED, NETWORK_UNAVAILABLE, TIMED_OUT, NOT_IN_GAME.

local Actions = require("botwithus.actions")
local G = require("botwithus.gameval")
local Timing = require("botwithus.timing")

local Lodestones = {}
Lodestones.__index = Lodestones

Lodestones.NETWORK_INTERFACE = 1092   -- THAS_LODESTONE_MAP
Lodestones.ARRIVAL_DISTANCE = 20
Lodestones.OPEN_TIMEOUT_MS = 6000
Lodestones.SETTLE_TIMEOUT_MS = 6000
Lodestones.ARRIVAL_TIMEOUT_MS = 20000
local OPEN_ATTEMPTS = 2
local NO_ANIMATION = -1
local OP_TELEPORT = 1
local IN_GAME = 30
local MINIMAP = 1465                  -- TOPLEVEL_V2_MINIMAP
local HOME_BUTTON = 34                -- TOPLEVEL_V2_MINIMAP__HOME_TELEPORT
-- By gameval name (host ABI 8); the number is the fallback when the name does not resolve.
local NETWORK_REF = G.ref("interface", "THAS_LODESTONE_MAP", Lodestones.NETWORK_INTERFACE)
local HOME_REF = G.component_ref("TOPLEVEL_V2_MINIMAP__HOME_TELEPORT", MINIMAP, HOME_BUTTON)
Lodestones.OPEN_OPTION = "Lodestone Network"
-- The repeat option is named after the last lodestone ("Teleport Burthorpe").
Lodestones.PREVIOUS_OPTION_PREFIX = "Teleport "

Lodestones.ARRIVED = "arrived"
Lodestones.LOCKED = "locked"
Lodestones.NETWORK_UNAVAILABLE = "network_unavailable"
Lodestones.TIMED_OUT = "timed_out"
Lodestones.NOT_IN_GAME = "not_in_game"

-- { key, button comp on 1092, unlock varbit, unlocked when the varbit is at least }. Lunar Isle
-- and Bandit Camp unlock with their quests; Anachronia and Fort Forinthry with a build tier.
local ROWS = {
  { "AL_KHARID", 10, 28, 1, "THAS_LODESTONE_MAP__AL_KHARID", "THAS_ACTIVE_AL_KHARID" },
  { "ANACHRONIA", 24, 44270, 1, "THAS_LODESTONE_MAP__DINO_ISLAND", "DINO_BASE_CAMP_BUILDING_TIER_LODESTONE" },
  { "ARDOUGNE", 11, 29, 1, "THAS_LODESTONE_MAP__ARDOUGNE", "THAS_ACTIVE_ARDOUGNE" },
  { "ASHDALE", 33, 22430, 1, "THAS_LODESTONE_MAP__ASHDALE", "THAS_ACTIVE_ASHDALE" },
  { "BANDIT_CAMP", 8, 9482, 15, "THAS_LODESTONE_MAP__ANCIENTS", "DESERTTREASURE" },
  { "BURTHORPE", 12, 30, 1, "THAS_LODESTONE_MAP__BURTHORPE", "THAS_ACTIVE_BURTHORPE" },
  { "CANIFIS", 26, 18523, 1, "THAS_LODESTONE_MAP__CANIFIS", "THAS_ACTIVE_CANIFIS" },
  { "CATHERBY", 13, 31, 1, "THAS_LODESTONE_MAP__CATHERBY", "THAS_ACTIVE_CATHERBY" },
  { "CITY_OF_UM", 35, 53270, 1, "THAS_LODESTONE_MAP__CITYOFUM", "THAS_ACTIVE_CITYOFUM" },
  { "DRAYNOR_VILLAGE", 14, 32, 1, "THAS_LODESTONE_MAP__DRAYNOR", "THAS_ACTIVE_DRAYNOR" },
  { "EAGLES_PEAK", 27, 18524, 1, "THAS_LODESTONE_MAP__EAGLES", "THAS_ACTIVE_EAGLES" },
  { "EDGEVILLE", 15, 33, 1, "THAS_LODESTONE_MAP__EDGEVILLE", "THAS_ACTIVE_EDGEVILLE" },
  { "FALADOR", 16, 34, 1, "THAS_LODESTONE_MAP__FALADOR", "THAS_ACTIVE_FALADOR" },
  { "FORT_FORINTHRY", 22, 52518, 1, "THAS_LODESTONE_MAP__FORT", "PLAYER_FORT_LODESTONE" },
  { "FREMENNIK_PROVINCE", 28, 18525, 1, "THAS_LODESTONE_MAP__FREMENNIK", "THAS_ACTIVE_FREMENNIK" },
  { "KARAMJA", 29, 18526, 1, "THAS_LODESTONE_MAP__KARAMJA", "THAS_ACTIVE_KARAMJA" },
  { "LUMBRIDGE", 17, 35, 1, "THAS_LODESTONE_MAP__LUMBRIDGE", "THAS_ACTIVE_LUMBRIDGE" },
  { "LUNAR_ISLE", 9, 10236, 100, "THAS_LODESTONE_MAP__LUNAR", "LUNAR_QUEST_MAIN" },
  { "MENAPHOS", 23, 36173, 1, "THAS_LODESTONE_MAP__MENAPHOS", "THAS_ACTIVE_MENAPHOS" },
  { "OOGLOG", 30, 18527, 1, "THAS_LODESTONE_MAP__OOGLOG", "THAS_ACTIVE_OOGLOG" },
  { "PORT_SARIM", 18, 36, 1, "THAS_LODESTONE_MAP__PORT_SARIM", "THAS_ACTIVE_PORT_SARIM" },
  { "PRIFDDINAS", 34, 24967, 1, "THAS_LODESTONE_MAP__PRIFDDINAS", "THAS_ACTIVE_PRIFDDINAS" },
  { "SEERS_VILLAGE", 19, 37, 1, "THAS_LODESTONE_MAP__SEERS", "THAS_ACTIVE_SEERS" },
  { "TAVERLEY", 20, 38, 1, "THAS_LODESTONE_MAP__TAVERLEY", "THAS_ACTIVE_TAVERLEY" },
  { "TIRANNWN", 31, 18528, 1, "THAS_LODESTONE_MAP__TIRRANWN", "THAS_ACTIVE_TIRRANWN" },
  { "VARROCK", 21, 39, 1, "THAS_LODESTONE_MAP__VARROCK", "THAS_ACTIVE_VARROCK" },
  { "WENDLEWICK", 41, 60739, 1, "THAS_LODESTONE_MAP__WENDLEWICK", "THAS_ACTIVE_WENDLEWICK" },
  { "WILDERNESS_CRATER", 32, 18529, 1, "THAS_LODESTONE_MAP__WILDERNESS", "THAS_ACTIVE_WILDERNESS" },
  { "YANILLE", 25, 40, 1, "THAS_LODESTONE_MAP__YANILLE", "THAS_ACTIVE_YANILLE" },
}

Lodestones.ALL = {}
Lodestones.ORDER = {}
for i, r in ipairs(ROWS) do
  -- button / varbit are the fallback ids; button_ref / varbit_ref resolve the gameval names.
  local row = { key = r[1], button = r[2], varbit = r[3], at_least = r[4],
                button_ref = G.component_ref(r[5], Lodestones.NETWORK_INTERFACE, r[2]),
                varbit_ref = G.ref("varbit", r[6], r[3]) }
  Lodestones.ALL[r[1]] = row
  Lodestones.ORDER[i] = row
end

-- `opts.wait` is the wait engine (default Timing.for_game(game): stop- and pause-aware).
function Lodestones.new(game, opts)
  opts = opts or {}
  return setmetatable({ _game = game, _wait = opts.wait or Timing.for_game(game) }, Lodestones)
end

function Lodestones.lodestone(l)
  if type(l) == "table" then return l end
  local row = Lodestones.ALL[l]
  if row == nil then error("botwithus: unknown lodestone " .. tostring(l), 3) end
  return row
end

function Lodestones:is_unlocked(l)
  local row = Lodestones.lodestone(l)
  return self._game:varbit(row.varbit_ref:id()) >= row.at_least
end

-- The unlocked lodestones, in order.
function Lodestones:unlocked()
  local out = {}
  for _, row in ipairs(Lodestones.ORDER) do
    if self:is_unlocked(row) then out[#out + 1] = row end
  end
  return out
end

function Lodestones:is_open() return self._game:is_interface_open(NETWORK_REF:id()) end

-- Press the home button op `pick(ops)` chooses; false (nothing sent) when it picks none.
function Lodestones:_press_home(pick)
  local minimap, home = HOME_REF:component()
  local reply = self._game:component_ops(minimap, home, -1)
  local op = reply and pick(reply.ops or {})
  if op == nil then return false end
  local minimap, home = HOME_REF:component()
  self._game:do_action(Actions.component_click(minimap, home, op, -1))
  return true
end

local function op_named(name)
  return function(ops)
    for _, o in ipairs(ops) do
      if o.name:lower() == name:lower() then return o.op end
    end
    return nil
  end
end

-- Opens the network; false when the home button lists no "Lodestone Network".
function Lodestones:open() return self:_press_home(op_named(Lodestones.OPEN_OPTION)) end

function Lodestones:_ensure_open()
  local attempt = 0
  while attempt < OPEN_ATTEMPTS and not self:is_open() do
    if not self:open() then return false end
    self._wait:until_(function() return self:is_open() end, Lodestones.OPEN_TIMEOUT_MS)
    attempt = attempt + 1
  end
  return self:is_open()
end

-- The self row, or nil when not in the game.
function Lodestones:_me()
  if self._game:game_state().game_state ~= IN_GAME then return nil end
  return self._game:self()
end

-- Moved far enough, or changed plane and moved at all.
function Lodestones.has_arrived(start, now)
  local moved = math.max(math.abs(now.tile.x - start.tile.x), math.abs(now.tile.y - start.tile.y))
  return moved >= Lodestones.ARRIVAL_DISTANCE or (now.tile.plane ~= start.tile.plane and moved > 0)
end

function Lodestones:_await_arrival(start, timeout_ms)
  local arrived = self._wait:until_(function()
    local now = self:_me()
    return now ~= nil and Lodestones.has_arrived(start, now)
  end, timeout_ms)
  if not arrived then return Lodestones.TIMED_OUT end
  self._wait:until_(function()
    local now = self:_me()
    return now ~= nil and now.animation_id == NO_ANIMATION
  end, Lodestones.SETTLE_TIMEOUT_MS)
  return Lodestones.ARRIVED
end

-- Teleport to `l` (a key such as "LUMBRIDGE", or a row) and wait for the arrival.
function Lodestones:teleport(l, timeout_ms)
  local row = Lodestones.lodestone(l)
  local start = self:_me()
  if start == nil then return Lodestones.NOT_IN_GAME end
  if not self:is_unlocked(row) then return Lodestones.LOCKED end
  if not self:_ensure_open() then return Lodestones.NETWORK_UNAVAILABLE end
  local iface, button = row.button_ref:component()
  self._game:do_action(Actions.component_click(iface, button, OP_TELEPORT, -1))
  return self:_await_arrival(start, timeout_ms or Lodestones.ARRIVAL_TIMEOUT_MS)
end

-- Teleport to the previous destination through the home button's "Teleport <name>" op.
function Lodestones:teleport_to_previous(timeout_ms)
  local start = self:_me()
  if start == nil then return Lodestones.NOT_IN_GAME end
  local pressed = self:_press_home(function(ops)
    for _, o in ipairs(ops) do
      if o.name:sub(1, #Lodestones.PREVIOUS_OPTION_PREFIX) == Lodestones.PREVIOUS_OPTION_PREFIX then
        return o.op
      end
    end
    return nil
  end)
  if not pressed then return Lodestones.NETWORK_UNAVAILABLE end
  return self:_await_arrival(start, timeout_ms or Lodestones.ARRIVAL_TIMEOUT_MS)
end

return Lodestones
