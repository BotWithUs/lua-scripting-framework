-- botwithus.buffs -- potion and incense effects read from their varbits (the Java host's
-- buff.Buffs, Buff and BuffState).
--
--   local Buffs = require("botwithus.buffs")
--   local b = Buffs.new(game)
--   if not b:is_active(Buffs.OVERLOAD) then ... end
--   local s = b:state(Buffs.IRIT_INCENSE)      -- { is_active, remaining_ms, potency, raw }
--
-- A timed buff's varbit counts down in units of 15 s (TIME_UNIT_MS; xapi's unit, not yet checked
-- live). Aggression and the two renewals are flags only: no time left. Powder of Protection and
-- weapon poison are left out on purpose: the varbits xapi named for them are something else
-- (DUEL_ARENA_REMOVAL_SCARAB_POWDER_GREEN_DURATION, COMBATV2_P_POISON).

local Buffs = {}
Buffs.__index = Buffs

Buffs.TIME_UNIT_MS = 15000
Buffs.UNREAD = -1

local function buff(key, varbit, timed, potency)
  return { key = key, varbit = varbit, timed = timed, potency = potency }
end

Buffs.OVERLOAD = buff("OVERLOAD", 48834, true)                       -- OVERLOAD_POTION_EFFECTS_LONG
Buffs.ANTIFIRE = buff("ANTIFIRE", 497, true)                         -- DRAGONRESIST_ORIGINAL
Buffs.SUPER_ANTIFIRE = buff("SUPER_ANTIFIRE", 498, true)             -- DRAGONRESIST_ALL
Buffs.IRIT_INCENSE = buff("IRIT_INCENSE", 43714, true, 43696)        -- INCENSE_IRIT_ACTIVE / _POTENCY
Buffs.KWUARM_INCENSE = buff("KWUARM_INCENSE", 43725, true, 43707)    -- INCENSE_KWUARM_ACTIVE / _POTENCY
Buffs.LANTADYME_INCENSE = buff("LANTADYME_INCENSE", 43717, true, 43699) -- INCENSE_LANTADYME_*
Buffs.AGGRESSION = buff("AGGRESSION", 33448, false)                  -- WILDERNESS_AGGRESSION_POTION_EFFECTS
Buffs.PRAYER_RENEWAL = buff("PRAYER_RENEWAL", 2100, false)
Buffs.SUPER_PRAYER_RENEWAL = buff("SUPER_PRAYER_RENEWAL", 25852, false)
Buffs.ALL = { Buffs.OVERLOAD, Buffs.ANTIFIRE, Buffs.SUPER_ANTIFIRE, Buffs.IRIT_INCENSE,
              Buffs.KWUARM_INCENSE, Buffs.LANTADYME_INCENSE, Buffs.AGGRESSION,
              Buffs.PRAYER_RENEWAL, Buffs.SUPER_PRAYER_RENEWAL }

function Buffs.new(game) return setmetatable({ _game = game }, Buffs) end

function Buffs:is_active(b) return self._game:varbit(b.varbit) > 0 end

-- { buff, is_active, remaining_ms (timed and active only), potency (incense only), raw }.
function Buffs:state(b)
  local raw = self._game:varbit(b.varbit)
  local active = raw > 0
  return { buff = b, is_active = active, raw = raw,
           remaining_ms = (active and b.timed) and raw * Buffs.TIME_UNIT_MS or nil,
           potency = b.potency and self._game:varbit(b.potency) or nil }
end

function Buffs:remaining_ms(b) return self:state(b).remaining_ms end

-- The active buffs, in Buffs.ALL order.
function Buffs:active()
  local out = {}
  for _, b in ipairs(Buffs.ALL) do
    if self:is_active(b) then out[#out + 1] = b end
  end
  return out
end

return Buffs
