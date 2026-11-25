-- spec/pacing_spec.lua -- the agent's session plan (bwu.session_pacing) and paced_ticks.
-- Each test says what result would have counted as a failure.

local fake_bwu = require("spec.fake_bwu")
local bot      = require("botwithus")

local T = {}

local SCRIPT_TICKS = 3
local PRESS_IN_MS = 1500           -- 2.5 ticks: paced_ticks rounds up to 3
local PRESS_IN_TICKS = 3
local BREAK_MS = 45000

local function held(press_ms, brk)
  return { active = true, held = true, next_press_in_ms = press_ms, ["break"] = brk }
end

T["pacing: an inactive layer leaves the script's own ticks alone"] = function(assert_)
  -- Failure: an agent without the layer changed how a script paces.
  _G.bwu = fake_bwu.new({})
  local g = bot.Game.attach()
  assert_(g:session_pacing().active == false, "inactive")
  assert_(g:paced_ticks(SCRIPT_TICKS) == SCRIPT_TICKS, "own ticks kept")
end

T["pacing: a host without bwu.session_pacing reads inactive"] = function(assert_)
  -- Failure: an older native host raised instead of pacing as before.
  _G.bwu = fake_bwu.new({ session_pacing = false })
  local g = bot.Game.attach()
  local p = g:session_pacing()
  assert_(p.active == false and p.next_press_in_ms == 0, "inactive table")
  assert_(g:paced_ticks(SCRIPT_TICKS) == SCRIPT_TICKS, "own ticks kept")
end

T["pacing: an active layer replaces the script's ticks with the wait to the press"] = function(assert_)
  -- Failure: the script's own ticks stacked on the agent's planned gap.
  _G.bwu = fake_bwu.new({ session_pacing = held(PRESS_IN_MS) })
  local g = bot.Game.attach()
  assert_(g:paced_ticks(SCRIPT_TICKS + 10) == PRESS_IN_TICKS,
          "ticks to the press, rounded up: " .. tostring(g:paced_ticks(SCRIPT_TICKS + 10)))
end

T["pacing: nothing held waits one tick, never zero"] = function(assert_)
  -- Failure: a zero delay that spins the loop on the pipe.
  _G.bwu = fake_bwu.new({ session_pacing = { active = true, held = false, next_press_in_ms = 0 } })
  local g = bot.Game.attach()
  assert_(g:paced_ticks(SCRIPT_TICKS) == bot.Game.MIN_DEFERRED_TICKS, "the minimum")
end

T["pacing: the planned break passes through, read-only"] = function(assert_)
  -- Failure: a script could not see the break coming.
  local brk = { carrier = "next_action", starts_in_ms = 0, length_ms = BREAK_MS }
  _G.bwu = fake_bwu.new({ session_pacing = { active = true, held = false,
                                             next_press_in_ms = 0, ["break"] = brk } })
  local got = bot.Game.attach():session_pacing()["break"]
  assert_(got.carrier == "next_action" and got.length_ms == BREAK_MS, "break fields")
end

T["pacing: a failed read paces as the script asked"] = function(assert_)
  -- Failure: a transport hiccup on the pacing read failed the script's loop.
  _G.bwu = fake_bwu.new({ session_pacing = "pipe disconnected" })
  local g = bot.Game.attach()
  local none, code = g:session_pacing()
  assert_(none == nil and code == "pipe disconnected", "nil, code")
  assert_(g:paced_ticks(SCRIPT_TICKS) == SCRIPT_TICKS, "own ticks kept")
end

return T
