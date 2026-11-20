-- N3 live smoke (host ABI 8): a gameval name used by real APIs, the millisecond Stopwatch, and
-- the object rows' animation_id, against a live client. Read-only: no click, no input, no camera.
--
--   bwu_host --lua tests/live/n3_smoke.lua
--
-- Run with BWU_NATIVE_DIR at a directory holding an NXTCache.dll, and LUA_PATH at this checkout.

local bot = require("botwithus")
local G = require("botwithus.gameval")
local ActionBar = require("botwithus.actionbar")
local Quests = require("botwithus.quests")
local Prayers = require("botwithus.prayers")
local Timers = require("botwithus.timers")
local Entities = require("botwithus.entities")

local failures = 0
local function check(cond, what)
  io.write((cond and "ok   " or "FAIL ") .. what .. "\n")
  io.flush()
  if not cond then failures = failures + 1 end
end

local game = bot.Game.attach(bwu.discover_pids()[1])
local ok, version = G.available()
check(ok, "gameval index available, index_version " .. tostring(version))

-- A real API resolving by name: the action bar's current bar and its slot variables.
local named = G.id("varbit", "COMBATV2_ACTIONBAR_CURRENT_BAR")
local bar = ActionBar.new(game)
local active = bar:active_bar()
check(named ~= nil and active >= 1 and active <= 18,
      ("COMBATV2_ACTIONBAR_CURRENT_BAR -> varbit %s; active bar %d"):format(tostring(named), active))
local vars = bar:_vars_of(active)
check(vars == bar._vars[active], ("bar %d slot 1 by name: type %d id %d obj %d"):format(
  active, vars.type[1], vars.id[1], vars.obj[1]))
check(#bar:slots() == 14, "14 slots read through the named variables")

-- Quests by gameval name, and a prayer varbit by name.
local quests = Quests.new(game)
local cook = quests:status("COOKS_ASSISTANT")
check(cook.quest_id == 257, ("quest COOKS_ASSISTANT -> %d %q %s"):format(cook.quest_id, cook.name, cook.stage))
local p = Prayers.new(game)
check(p:points() >= 0, ("prayer points %d via PRAYER_POINTS -> varbit %s"):format(
  p:points(), tostring(G.id("varbit", "PRAYER_POINTS"))))

-- The millisecond clock: a Stopwatch across a 37 ms wait reads tens of ms, not 0 or 1000.
check(Timers.has_ms_clock(), "the host's millisecond clock is in use")
local watch = Timers.Stopwatch.started()
bwu.ctl_wait(37)
local elapsed = watch:elapsed_ms()
check(elapsed >= 30 and elapsed < 500, ("Stopwatch across ctl_wait(37): %d ms"):format(elapsed))
local t0 = bwu.monotonic_ms()
local spins = 0
while bwu.monotonic_ms() == t0 do spins = spins + 1 end
check(bwu.monotonic_ms() - t0 >= 1, ("monotonic_ms ticks in milliseconds (%d spins to the next)"):format(spins))

-- Object rows carry animation_id (host ABI 8).
local objects = Entities.objects(game):all()
local typed = 0
for _, o in ipairs(objects) do
  if math.type(o.animation_id) == "integer" then typed = typed + 1 end
end
check(#objects > 0 and typed == #objects, ("%d objects, every row has an integer animation_id"):format(#objects))
local animating = Entities.objects(game):animating():all()
io.write(("     animating objects in view: %d\n"):format(#animating))

game:detach()
io.write(("n3 smoke: %d failure(s)\n"):format(failures))
if failures > 0 then error("n3 smoke failed") end
