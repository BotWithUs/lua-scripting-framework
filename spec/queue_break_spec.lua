-- spec/queue_break_spec.lua -- all-or-nothing queue_actions, and breaks.
--
-- queue_actions: the agent queues the whole batch or refuses it whole (batch_too_large,
-- queue_full, action_id_required, bad_param) and queues nothing. A failed call (timeout, pipe
-- gone) leaves the outcome unknown. Only an agent older than all-or-nothing queues a prefix.
--
-- Breaks: the API takes seconds; the surface gets whole milliseconds, rounded to the nearest
-- (half to even), 1 .. INT32_MAX -- the Python framework's conversion, vector for vector.

local fake_bwu = require("spec.fake_bwu")
local bot      = require("botwithus")
local Game     = bot.Game

local T = {}

local INT32_MAX = 2147483647

local function attach(opts)
  _G.bwu = fake_bwu.new(opts)
  return Game.attach(), _G.bwu._state
end

local function two() return { { id = 23, p1 = 1, p2 = 3200, p3 = 3200 }, { id = 23, p1 = 1, p2 = 3201, p3 = 3201 } } end

-- --- queue_actions --------------------------------------------------------------------

T["queue_actions returns the batch size when all are queued"] = function(assert_)
  local g, st = attach()
  assert_(g:queue_actions(two()) == 2, "2 queued")
  assert_(#st.batches == 1 and #st.actions == 2, "one batch, both actions")
end

T["each agent refusal says nothing was queued"] = function(assert_)
  for _, code in ipairs({ "batch_too_large", "queue_full", "action_id_required", "bad_param param1" }) do
    local g = attach({ queue_error = "queue_actions: " .. code })
    local n, msg, outcome = g:try_queue_actions(two())
    assert_(n == nil and outcome == Game.QUEUED_NONE, code .. " is QUEUED_NONE")
    assert_(msg:find("nothing was queued", 1, true), code .. ": " .. msg)
    local ok, err = pcall(g.queue_actions, g, two())
    assert_(not ok and tostring(err):find("nothing was queued", 1, true), "raises: " .. tostring(err))
  end
end

T["a failed call says the outcome is unknown"] = function(assert_)
  local g = attach({ queue_error = "rpc_timeout", queue_outcome = "unknown" })
  local n, msg, outcome = g:try_queue_actions(two())
  assert_(n == nil and outcome == Game.QUEUED_UNKNOWN, "QUEUED_UNKNOWN")
  assert_(msg:find("rpc_timeout", 1, true) and msg:find("may have been queued", 1, true), msg)
end

-- The host's third value decides; the message text is not consulted when it is there.
T["host 'refused' means nothing queued, whatever the message"] = function(assert_)
  local g = attach({ queue_error = "queue_actions: count must be 0..BWU_MAX_ACTION_BATCH" })
  local n, msg, outcome = g:try_queue_actions(two())
  assert_(n == nil and outcome == Game.QUEUED_NONE, "a host-side refusal is QUEUED_NONE: " .. tostring(msg))
  assert_(msg:find("nothing was queued", 1, true), msg)
end

T["host 'unknown' wins over a refusal code in the message"] = function(assert_)
  local g = attach({ queue_error = "queue_actions: queue_full", queue_outcome = "unknown" })
  local _, msg, outcome = g:try_queue_actions(two())
  assert_(outcome == Game.QUEUED_UNKNOWN, "unknown is unknown: " .. tostring(msg))
end

-- A bwu_host older than the third value: fall back to the agent's refusal code in the message.
T["older host: a refusal code in the message means nothing queued"] = function(assert_)
  local g = attach({ queue_error = "queue_actions: queue_full", queue_outcome = false })
  local n, msg, outcome = g:try_queue_actions(two())
  assert_(n == nil and outcome == Game.QUEUED_NONE, "QUEUED_NONE")
  assert_(msg:find("queue_full", 1, true) and msg:find("nothing was queued", 1, true), msg)
end

T["older host: any other message means the outcome is unknown"] = function(assert_)
  local g = attach({ queue_error = "rpc_timeout", queue_outcome = false })
  local _, msg, outcome = g:try_queue_actions(two())
  assert_(outcome == Game.QUEUED_UNKNOWN, "QUEUED_UNKNOWN: " .. tostring(msg))
end

T["do_action passes queue_action's error through"] = function(assert_)
  local g = attach({ queue_action_error = "queue_action: queue_full" })
  local ok, err = g:do_action({ id = 23, p1 = 1, p2 = 3200, p3 = 3200 })
  assert_(ok == false and err == "queue_action: queue_full", "false, err: " .. tostring(err))
  g = attach()
  assert_(g:do_action({ id = 23, p1 = 1, p2 = 3200, p3 = 3200 }) == true, "true when queued")
end

T["an old agent's prefix is reported as a prefix"] = function(assert_)
  local g = attach({ queue_accept = 1 })
  local n, msg, outcome, queued = g:try_queue_actions(two())
  assert_(n == nil and outcome == Game.QUEUED_PREFIX and queued == 1, "prefix of 1")
  assert_(msg:find("queued 1 of 2", 1, true), msg)
end

T["a batch over MAX_ACTION_BATCH is refused before sending"] = function(assert_)
  local g, st = attach()
  local list = {}
  for i = 1, 129 do list[i] = { id = 23, p1 = 1, p2 = i, p3 = i } end
  local n, msg, outcome = g:try_queue_actions(list)
  assert_(n == nil and outcome == Game.QUEUED_NONE, "QUEUED_NONE")
  assert_(msg:find("nothing was queued", 1, true), msg)
  assert_(#st.batches == 0, "nothing sent")
end

-- --- breaks ---------------------------------------------------------------------------

T["schedule_break(300) sends 300000 ms"] = function(assert_)
  local g, st = attach()
  g:schedule_break(300)
  assert_(#st.breaks == 1 and st.breaks[1] == 300000, "300000 ms: " .. tostring(st.breaks[1]))
  assert_(math.type(st.breaks[1]) == "integer", "an integer, not a float")
end

T["seconds convert to whole milliseconds like Python"] = function(assert_)
  local cases = {
    { 1, 1000 }, { 0.001, 1 }, { 0.0015, 2 }, { 0.0025, 2 }, { 2.5, 2500 },
    { Game.MAX_BREAK_SECONDS, INT32_MAX },
  }
  for _, c in ipairs(cases) do
    local g, st = attach()
    g:schedule_break(c[1])
    assert_(st.breaks[1] == c[2] and math.type(st.breaks[1]) == "integer",
      tostring(c[1]) .. " s -> " .. tostring(st.breaks[1]) .. ", want " .. c[2])
  end
  assert_(Game.MAX_BREAK_MS == INT32_MAX, "the cap is the agent's")
end

T["out-of-range breaks are refused before sending"] = function(assert_)
  local bad = { 0, 0.0, -1, -300, 0.0004, Game.MAX_BREAK_SECONDS + 0.001, 2147484,
                math.huge, -math.huge, 0 / 0, true, "300", nil }
  for i = 1, 13 do
    local g, st = attach()
    local ok, err = pcall(g.schedule_break, g, bad[i])
    assert_(not ok and tostring(err):find("duration_seconds", 1, true), "case " .. i .. ": " .. tostring(err))
    assert_(#st.breaks == 0, "case " .. i .. " sent nothing")
  end
end

T["interrupt_break calls the surface with no duration"] = function(assert_)
  local g, st = attach()
  g:interrupt_break()
  assert_(#st.breaks == 1 and st.breaks[1] == "interrupt", "interrupted")
end

T["a bwu_host without breaks says so"] = function(assert_)
  local g = attach({ no_breaks = true })
  assert_(g:has_breaks() == false, "has_breaks false")
  local ok, err = pcall(g.schedule_break, g, 60)
  assert_(not ok and tostring(err):find("has no schedule_break", 1, true), tostring(err))
  ok, err = pcall(g.interrupt_break, g)
  assert_(not ok and tostring(err):find("has no interrupt_break", 1, true), tostring(err))
end

T["a refused break raises with the host's error"] = function(assert_)
  local g = attach()
  _G.bwu.schedule_break = function() return nil, "bad_param duration" end
  local ok, err = pcall(g.schedule_break, g, 60)
  assert_(not ok and tostring(err):find("bad_param duration", 1, true), tostring(err))
end

return T
