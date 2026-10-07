-- spec/walk_spec.lua -- the walk progress wrappers (Game:walk_ex / :walk_start / ...) over the
-- fake bwu surface, which returns tables in the real binding's shape.

local fake_bwu = require("spec.fake_bwu")
local bot      = require("botwithus")
local W        = require("botwithus.walk")

local T = {}

local function transition(over)
  local t = { kind = W.TX_NONE, transition_index = -1, step_index = -1, object_id = -1,
              npc_type_hi = -1, x = 0, y = 0, plane = 0, option_index = -1,
              interact_attempts = 0, interact_issued = 0, chain_count = 0, chain = {} }
  for k, v in pairs(over or {}) do t[k] = v end
  return t
end

local function result(over)
  local r = { status = W.ARRIVED, result = 0, final_event = W.EV_ARRIVED, fail_step = -1,
              fail_transition = -1, replans = 0, event_count = 0, events_dropped = 0,
              elapsed_ms = 1200, transition = transition(), error = "" }
  for k, v in pairs(over or {}) do r[k] = v end
  return r
end

local function event(kind, step, tx)
  return { kind = kind, step_index = step or 0, transition_index = tx or -1,
           interaction_hint = 0, t_ms = 0, replans = 0 }
end

local DOOR = transition({ kind = W.TX_OBJECT, transition_index = 42, step_index = 1,
                          object_id = 1530, x = 3205, y = 3206, plane = 0, option_index = 1,
                          interact_attempts = 3, interact_issued = 0 })

T["walk: constants match the host header"] = function(assert_)
  assert_(W.RUNNING == 0 and W.ARRIVED == 1 and W.FAILED == 2 and W.CANCELLED == 3, "statuses")
  assert_(W.TIMED_OUT == 4 and W.ERROR == 5, "timed out / error")
  assert_(W.EV_STUCK == 3 and W.EV_REPLAN_STARTED == 4 and W.EV_FAILED == 6 and W.EV_NONE == -1,
          "event kinds")
  assert_(W.TX_OBJECT == 1 and W.TX_NPC == 2 and W.TX_TELEPORT == 4, "transition kinds")
  assert_(bot.walk == W, "bot.walk is botwithus.walk")
end

T["walk_ex: a transition failure keeps the descriptor and events"] = function(assert_)
  _G.bwu = fake_bwu.new({
    walk_progress = result({ status = W.FAILED, result = -7, final_event = W.EV_FAILED,
                             fail_step = 1, fail_transition = 42, transition = DOOR }),
    walk_events = { event(0, 0, -1), event(0, 1, 42), event(W.EV_FAILED, 1, 42) },
  })
  local g = bot.Game.attach()
  assert_(g:has_walk_progress(), "the fake has walk progress")
  local r = g:walk_ex(3210, 3210, 0, 2)
  local walks = rawget(_G, "bwu")._state.walks
  assert_(walks[1].x == 3210 and walks[1].radius == 2, "goal and radius thread through")
  assert_(r.status == W.FAILED and r.result == -7, "failed, NO_PATH")
  local t = W.failed_on_transition(r)
  assert_(t ~= nil and t.kind == W.TX_OBJECT and t.object_id == 1530, "door descriptor")
  assert_(t.interact_attempts == 3 and t.interact_issued == 0, "loc never found")
  assert_(#r.events == 3 and W.has_event(r.events, W.EV_FAILED), "events ride along")
end

T["walk_ex: a walk-step failure has no failed transition"] = function(assert_)
  _G.bwu = fake_bwu.new({
    walk_progress = result({ status = W.FAILED, fail_step = 3, fail_transition = -1,
                             replans = 3, transition = DOOR }),
  })
  local r = bot.Game.attach():walk_ex(1, 2)
  assert_(W.failed_on_transition(r) == nil, "the door was an earlier, passed transition")
  assert_(r.replans == 3, "re-plans threaded through")
end

T["walk_start / events / wait / cancel: the non-blocking trio"] = function(assert_)
  _G.bwu = fake_bwu.new({
    walk_progress = result({ status = W.RUNNING, final_event = W.EV_STUCK }),
    walk_events = { event(0), event(W.EV_STUCK) },
  })
  local g = bot.Game.attach()
  local ok = g:walk_start(3210, 3205, 0, 2)
  assert_(ok == true, "start accepted")
  local evs = g:walk_events()
  assert_(#evs == 2 and W.has_event(evs, W.EV_STUCK), "live events")
  assert_(#g:walk_events(#evs) == 0, "cursor past the end")
  assert_(W.is_running(g:walk_wait(600)), "still running")
  g:walk_wait(-5)
  local waits = rawget(_G, "bwu")._state.walk_waits
  assert_(waits[1] == 600 and waits[2] == 0, "timeouts thread through, negative clamped")
  g:walk_cancel()
  assert_(rawget(_G, "bwu")._state.walk_cancelled == true, "cancel reached the surface")
  assert_(g:walk_status().status == W.RUNNING, "status reads the walk")
end

T["walk_start / walk_ex refused while a walk runs"] = function(assert_)
  _G.bwu = fake_bwu.new()   -- walk_progress nil: refuses like a host with a walk running
  local g = bot.Game.attach()
  local ok, err = g:walk_start(1, 2)
  assert_(ok == false and err:find("already running") ~= nil, "start refused with a reason")
  local r, why = g:walk_ex(1, 2)
  assert_(r == nil and type(why) == "string", "walk_ex returns (nil, err)")
  assert_(g:walk_status() == nil, "never walked: status is nil")
end

T["walk progress: feature-detected on an older host"] = function(assert_)
  _G.bwu = fake_bwu.new({ no_walk_progress = true })
  local g = bot.Game.attach()
  assert_(g:has_walk_progress() == false, "older host has no walk progress")
  assert_(g:walk(3165, 3486, 0, 1) == true, "the bool walk still works")
  local ok, err = pcall(function() return g:walk_ex(1, 2) end)
  assert_(not ok and tostring(err):find("predates walk progress") ~= nil, "a clear error")
end

return T
