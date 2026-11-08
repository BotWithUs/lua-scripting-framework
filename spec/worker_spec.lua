-- spec/worker_spec.lua -- botwithus.worker: describe, run, config, stop, self-running scripts.
--
-- The host side (the GUI connection, the frames, config validation against the schema) is
-- native and tested there. These specs drive the framework against the fake bwu.ctl_* surface
-- and check what the framework reports and calls, in what order.

local fake_bwu = require("spec.fake_bwu")
local worker   = require("botwithus.worker")
local Script   = require("botwithus.script")

local T = {}

local CLIENT_PID = 4242
local STOP_WAIT_LIMIT_MS = 250   -- a sleeping script must see stop within this

local function fixture(name)
  local path = package.searchpath("spec.fixtures." .. name, package.path)
  assert(path, "fixture " .. name .. " not on package.path")
  return path
end

-- A fresh fake with run control and a run log, installed as _G.bwu.
local function setup(ctl_opts, fake_opts)
  _G.FIXTURE_CALLS, _G.FIXTURE_PLUGIN, _G.FIXTURE_SELF_RUN = nil, nil, nil
  local b = fake_bwu.with_ctl(fake_bwu.with_runlog(fake_bwu.new(fake_opts)), ctl_opts)
  _G.bwu = b
  return b
end

-- A plugin table that records every callback in `calls`. Hooks override behaviour.
local function plugin(hooks)
  hooks = hooks or {}
  local calls = {}
  local p = {
    manifest = hooks.manifest or { name = "Fixture", author = "spec", category = "Skilling" },
    config_fields = hooks.config_fields or {
      { key = "logs", kind = "int", label = "Logs", default = 28, min = 1, max = 28 },
      { key = "tree", kind = "choice", label = "Tree", default = "oak", options = { "oak", "willow" } },
    },
    calls = calls,
  }
  function p.on_config_update(ctx, config)
    calls[#calls + 1] = { "on_config_update", config, ctx.config }
    if hooks.on_config_update then hooks.on_config_update(ctx, config) end
  end
  function p.on_start(ctx)
    calls[#calls + 1] = { "on_start" }
    if hooks.on_start then hooks.on_start(ctx) end
  end
  local loops = 0
  function p.on_loop(ctx)
    loops = loops + 1
    calls[#calls + 1] = { "on_loop", loops }
    if hooks.on_loop then return hooks.on_loop(ctx, loops) end
    return loops < 3 and 1 or -1
  end
  function p.on_stop(ctx)
    calls[#calls + 1] = { "on_stop" }
    if hooks.on_stop then hooks.on_stop(ctx) end
  end
  return p
end

local function names(calls)
  local out = {}
  for i, c in ipairs(calls) do out[i] = c[1] end
  return table.concat(out, ",")
end

-- Run a plugin through worker.run, which must never raise for a script failure.
local function run_plugin(p, ctl_opts, fake_opts)
  local b = setup(ctl_opts, fake_opts)
  _G.FIXTURE_PLUGIN = p
  worker.run(fixture("plugin"), CLIENT_PID)
  return b
end

local function crashes(b) return b._runlog.crashes end

-- describe ----------------------------------------------------------------------------------

T["describe: a plugin reports its manifest with defaults filled and its fields"] = function(assert_)
  local b = setup({ mode = "describe" })
  local p = plugin()
  _G.FIXTURE_PLUGIN = p
  worker.describe(fixture("plugin"))
  local d = b._ctl.describes[1]
  assert_(#b._ctl.describes == 1, "described once")
  assert_(d.manifest.name == "Fixture" and d.manifest.version == "1.0" and d.manifest.author == "spec"
          and d.manifest.description == "" and d.manifest.category == "Skilling", "manifest defaults")
  assert_(#d.config_schema == 2 and d.config_schema[2].key == "tree", "fields in order")
  assert_(d.self_running == nil, "a plugin is not self-running")
  assert_(#p.calls == 0, "no callback ran: " .. names(p.calls))
  assert_(#b._state.attaches == 0, "nothing attached")
  assert_(#b._ctl.states == 0, "no phase reported")
  local call = _G.FIXTURE_CALLS[1]
  assert_(#_G.FIXTURE_CALLS == 1 and call.n == 2 and call[1] == "plugin" and call[2] == fixture("plugin"),
          "loaded once as chunk(modname, path)")
end

T["describe: author defaults to empty and name to the file stem"] = function(assert_)
  local b = setup({ mode = "describe" })
  _G.FIXTURE_PLUGIN = plugin({ manifest = {} })
  worker.describe(fixture("plugin"))
  local m = b._ctl.describes[1].manifest
  assert_(m.name == "plugin" and m.author == "" and m.version == "1.0" and m.category == nil,
          "stem name, empty author, no category")
end

T["describe: config_fields may be a function of the script"] = function(assert_)
  local b = setup({ mode = "describe" })
  local p = plugin()
  p.config_fields = function(self)
    assert(self == p, "called with the script table")
    return { { key = "food", kind = "item_id", label = "Food", default = 385 } }
  end
  _G.FIXTURE_PLUGIN = p
  worker.describe(fixture("plugin"))
  local schema = b._ctl.describes[1].config_schema
  assert_(#schema == 1 and schema[1].key == "food", "the function's fields")
end

T["describe: a file that returns no table is self-running and is not run"] = function(assert_)
  local b = setup({ mode = "describe" })
  local ran = false
  _G.FIXTURE_SELF_RUN = function() ran = true end
  worker.describe(fixture("plugin"))
  local d = b._ctl.describes[1]
  assert_(d.self_running == true and #d.config_schema == 0, "self_running, empty schema")
  assert_(d.manifest.name == "plugin" and d.manifest.version == "1.0" and d.manifest.author == ""
          and d.manifest.description == "", "manifest from the file name")
  assert_(not ran, "the self-run block did not run")
end

T["describe: a syntax error is a load crash and nothing is described"] = function(assert_)
  local b = setup({ mode = "describe" })
  worker.describe(fixture("syntax_error"))
  assert_(#b._ctl.describes == 0, "not described")
  local c = crashes(b)[1]
  assert_(c and c.phase == "load" and c.report:find("syntax_error.lua", 1, true), "load crash names the file")
end

T["describe: an error at load is a load crash with a traceback"] = function(assert_)
  local b = setup({ mode = "describe" })
  worker.describe(fixture("load_error"))
  local c = crashes(b)[1]
  assert_(#b._ctl.describes == 0, "not described")
  assert_(c and c.phase == "load" and c.report:find("load went wrong", 1, true)
          and c.report:find("stack traceback:", 1, true), "load crash with its traceback")
end

T["describe: config_fields raising, or a table without on_loop, is a load crash"] = function(assert_)
  local b = setup({ mode = "describe" })
  local p = plugin()
  p.config_fields = function() error("fields broke") end
  _G.FIXTURE_PLUGIN = p
  worker.describe(fixture("plugin"))
  assert_(#b._ctl.describes == 0 and crashes(b)[1].phase == "load"
          and crashes(b)[1].report:find("fields broke", 1, true), "config_fields error -> load")

  b = setup({ mode = "describe" })
  _G.FIXTURE_PLUGIN = { manifest = { name = "NoLoop" } }
  worker.describe(fixture("plugin"))
  assert_(#b._ctl.describes == 0 and crashes(b)[1].phase == "load"
          and crashes(b)[1].report:find("on_loop", 1, true), "no on_loop -> load")
end

T["describe and run: a plugin can require a file beside it"] = function(assert_)
  local path = fixture("sibling.plugin_with_helper")
  local saved = package.path
  for _, entry in ipairs({ "describe", "run" }) do
    package.path = saved
    package.loaded["sibling_helper"] = nil
    local b = setup({ mode = entry == "run" and "worker" or "describe" })
    if entry == "run" then worker.run(path, CLIENT_PID) else worker.describe(path) end
    local d = b._ctl.describes[1]
    assert_(#crashes(b) == 0, entry .. ": no crash: " .. tostring(crashes(b)[1] and crashes(b)[1].report))
    assert_(d and d.manifest.name == "FromSibling", entry .. ": the sibling module was found")
    local dir = path:match("^(.*)[/\\][^/\\]*$")
    assert_(package.path:sub(1, #dir + 7) == dir .. "/?.lua;", entry .. ": the script dir comes first")
  end
  worker.describe(path)
  local _, count = package.path:gsub("sibling/%?%.lua", "")
  assert_(count == 1, "added once, not per load")
  package.path = saved
  package.loaded["sibling_helper"] = nil
end

T["describe: an invalid schema is left to the host (no crash block, nothing run)"] = function(assert_)
  local b = setup({ mode = "describe" })
  _G.FIXTURE_PLUGIN = plugin({ config_fields = {
    { key = "tree", kind = "choice", label = "Tree", default = "yew", options = { "oak" } } } })
  worker.describe(fixture("plugin"))
  assert_(#b._ctl.describes == 1, "described")
  assert_(#crashes(b) == 0, "the framework writes no crash block; the host reports the schema error")
end

-- run: a plugin -----------------------------------------------------------------------------

T["run: a plugin follows the normative order"] = function(assert_)
  local p = plugin()
  local b = run_plugin(p)
  assert_(table.concat(b._ctl.states, ",") == "attaching,running,stopping",
          "phases: " .. table.concat(b._ctl.states, ","))
  assert_(names(p.calls) == "on_config_update,on_start,on_loop,on_loop,on_loop,on_stop",
          "callbacks: " .. names(p.calls))
  local first = p.calls[1]
  assert_(first[2].logs == 28 and first[2].tree == "oak", "on_config_update gets the initial set")
  assert_(first[3] == first[2], "ctx.config is that set")
  assert_(b._state.attaches[1] == CLIENT_PID and b._state.detaches[1] == CLIENT_PID, "attached and detached")
  assert_(#crashes(b) == 0, "no crash")
end

T["run: the initial config comes from the host (saved values applied)"] = function(assert_)
  local p = plugin()
  run_plugin(p, { initial = { logs = 5 } })
  assert_(p.calls[1][2].logs == 5 and p.calls[1][2].tree == "oak", "the host's initial set")
end

T["run: a queued config change is applied between iterations and acked"] = function(assert_)
  local seen
  local p
  p = plugin({ on_loop = function(ctx, n)
    if n == 1 then _G.bwu._ctl.push(7, { logs = 10, tree = "willow" }) end
    if n == 2 then seen = ctx.config end
    return n < 2 and 0 or -1
  end })
  local b = run_plugin(p)
  assert_(names(p.calls) == "on_config_update,on_start,on_loop,on_config_update,on_loop,on_stop",
          "update applied before the next on_loop: " .. names(p.calls))
  assert_(p.calls[4][2].tree == "willow", "on_config_update gets the full new set")
  assert_(seen and seen.logs == 10, "ctx.config replaced")
  assert_(#b._ctl.dones == 1 and b._ctl.dones[1].id == 7 and b._ctl.dones[1].ok, "acked ok")
end

-- Stall the fake's server tick (the lobby, a frozen client) and run `on_wait(b, n)` on every
-- ctl_wait. A wait that never ends is turned into a stop after WAIT_GUARD waits, so a
-- regression fails the spec instead of hanging the suite.
local WAIT_GUARD = 400
local function stall_ticks(b, on_wait)
  b.refresh = function() return true end
  local base_wait = b.ctl_wait
  b.ctl_wait = function(ms)
    local n = #b._ctl.waits + 1
    if n >= WAIT_GUARD then b._ctl.stop() end
    if on_wait then on_wait(b, n) end
    return base_wait(ms)
  end
end

T["run: a config change wakes the loop's sleep while the server tick is stalled"] = function(assert_)
  local p = plugin({
    on_start = function() stall_ticks(_G.bwu, function(b, n)
      if n == 3 then b._ctl.push(11, { logs = 4, tree = "willow" }) end
    end) end,
    on_loop = function(_, n) return n == 1 and 1000 or -1 end,
  })
  local b = run_plugin(p)
  assert_(#b._ctl.waits < WAIT_GUARD, "the sleep ended for the change, not the guard: " .. #b._ctl.waits)
  assert_(names(p.calls) == "on_config_update,on_start,on_loop,on_config_update,on_loop,on_stop",
          "applied before the next on_loop: " .. names(p.calls))
  assert_(p.calls[4][2].logs == 4, "the new set")
  assert_(#b._ctl.dones == 1 and b._ctl.dones[1].id == 11 and b._ctl.dones[1].ok, "acked ok")
end

T["run: a change the sleep took is applied before the host's next, in order"] = function(assert_)
  local p = plugin({
    on_start = function() stall_ticks(_G.bwu, function(b, n)
      if n == 2 then
        b._ctl.push(21, { logs = 1, tree = "oak" })
        b._ctl.push(22, { logs = 2, tree = "oak" })
      end
    end) end,
    on_loop = function(_, n) return n == 1 and 1000 or -1 end,
  })
  local b = run_plugin(p)
  assert_(#b._ctl.dones == 2 and b._ctl.dones[1].id == 21 and b._ctl.dones[2].id == 22, "acked 21 then 22")
  assert_(p.calls[4][2].logs == 1 and p.calls[5][2].logs == 2, "applied 21 then 22: " .. names(p.calls))
  assert_(names(p.calls):find("on_config_update,on_config_update,on_loop", 1, true), "both before on_loop")
end

T["run: a change the sleep took is left unacked when the run stops"] = function(assert_)
  local p = plugin({
    on_start = function()
      local b = _G.bwu
      stall_ticks(b, function(_, n) if n == 2 then b._ctl.push(31, { logs = 3, tree = "oak" }) end end)
      local take = b.ctl_take_config
      b.ctl_take_config = function()
        local id, cfg = take()
        if id ~= nil then b._ctl.stop() end
        return id, cfg
      end
    end,
    on_loop = function() return 1000 end,
  })
  local b = run_plugin(p)
  assert_(b._ctl.takes == 1 and #b._ctl.dones == 0, "taken, never acked")
  assert_(names(p.calls) == "on_config_update,on_start,on_loop,on_stop", "not applied: " .. names(p.calls))
end

T["run: ctx:sleep_ticks in on_loop does not end for a config change"] = function(assert_)
  local slept
  local p = plugin({
    on_loop = function(ctx, n)
      if n == 1 then
        _G.bwu._ctl.push(41, { logs = 5, tree = "oak" })
        slept = ctx:sleep_ticks(2)
      end
      return -1
    end,
  })
  local b = run_plugin(p)
  assert_(slept == true, "slept the full ticks")
  assert_(b._ctl.takes == 0, "the script's own sleep took nothing")
end

T["run: on_config_update raising acks update_failed and ends as a script crash"] = function(assert_)
  local updates = 0
  local p = plugin({
    on_config_update = function()
      updates = updates + 1
      if updates == 2 then error("bad value", 0) end
    end,
    on_loop = function(_, n)
      if n == 1 then _G.bwu._ctl.push(9, { logs = 1, tree = "oak" }) end
      return 0
    end,
  })
  local b = run_plugin(p)
  local done = b._ctl.dones[1]
  assert_(done and done.id == 9 and not done.ok and done.message == "bad value", "update_failed ack with the text")
  assert_(crashes(b)[1].phase == "on_config_update", "crash phase on_config_update")
  assert_(b._ctl.states[#b._ctl.states] == "stopping", "stopping reported after a queued-update crash")
  assert_(names(p.calls):sub(-7) == "on_stop", "on_stop ran")
end

T["run: a config change queued while stopping is not applied"] = function(assert_)
  local p = plugin({ on_loop = function()
    _G.bwu._ctl.push(3, { logs = 2, tree = "oak" })
    _G.bwu._ctl.stop()
    return 1
  end })
  local b = run_plugin(p)
  assert_(b._ctl.takes == 0 and #b._ctl.dones == 0, "never taken or acked by the framework")
  assert_(names(p.calls) == "on_config_update,on_start,on_loop,on_stop", "no further callback: " .. names(p.calls))
end

T["run: stop during a sleep ends the run within the wait slice"] = function(assert_)
  local p = plugin({ on_loop = function() return 50 end })
  local b = run_plugin(p, { stop_after_waits = 3 })
  assert_(names(p.calls) == "on_config_update,on_start,on_loop,on_stop", "one on_loop, then on_stop: " .. names(p.calls))
  assert_(#b._ctl.waits == 3, "the sleep returned on the wait that saw stop")
  for _, ms in ipairs(b._ctl.waits) do
    assert_(ms <= STOP_WAIT_LIMIT_MS, "each wait is at most 250 ms, got " .. ms)
  end
  assert_(b._ctl.states[#b._ctl.states] == "stopping", "stopping reported")
  assert_(#crashes(b) == 0, "a stop is not a crash")
end

T["run: ctx:sleep_ticks returns false on stop and true when the ticks pass"] = function(assert_)
  local results = {}
  local p = plugin({ on_loop = function(ctx, n)
    results[n] = ctx:sleep_ticks(1)
    results["stopping" .. n] = ctx:stopping()
    if n == 1 then _G.bwu._ctl.stop() end
    return 0
  end })
  run_plugin(p)
  assert_(results[1] == true and results.stopping1 == false, "true when the tick passed")
  assert_(results[2] == nil, "no on_loop after stop")
end

T["run: an on_loop error is a script crash; on_stop still runs"] = function(assert_)
  local p = plugin({ on_loop = function(_, n) if n == 2 then error("loop broke") end return 0 end })
  local b = run_plugin(p)
  local c = crashes(b)[1]
  assert_(c.phase == "on_loop" and c.iteration == 2, "phase on_loop, iteration 2")
  assert_(c.report:find("loop broke", 1, true) and c.report:find("stack traceback:", 1, true), "with a traceback")
  assert_(b._ctl.states[#b._ctl.states] == "stopping", "stopping reported")
  assert_(names(p.calls):sub(-7) == "on_stop" and b._state.detaches[1] == CLIENT_PID, "on_stop ran, detached")
end

T["run: on_start raising runs on_stop but reports no stopping"] = function(assert_)
  local p = plugin({ on_start = function() error("start broke") end })
  local b = run_plugin(p)
  assert_(crashes(b)[1].phase == "on_start", "phase on_start")
  assert_(table.concat(b._ctl.states, ",") == "attaching", "never running, never stopping")
  assert_(names(p.calls) == "on_config_update,on_start,on_stop", "on_stop ran: " .. names(p.calls))
  assert_(b._state.detaches[1] == CLIENT_PID, "detached")
end

T["run: the initial on_config_update raising skips on_start and on_stop"] = function(assert_)
  local p = plugin({ on_config_update = function() error("config broke") end })
  local b = run_plugin(p)
  assert_(crashes(b)[1].phase == "on_config_update", "phase on_config_update")
  assert_(names(p.calls) == "on_config_update", "nothing else ran: " .. names(p.calls))
  assert_(table.concat(b._ctl.states, ",") == "attaching", "no stopping")
  assert_(b._state.detaches[1] == CLIENT_PID, "detached")
end

T["run: an attach failure is crash phase other with the attach error"] = function(assert_)
  local b = setup()
  b._state.attach_error = "attach during load: guard the self-run"
  local p = plugin()
  _G.FIXTURE_PLUGIN = p
  worker.run(fixture("plugin"), CLIENT_PID)
  local c = crashes(b)[1]
  assert_(c.phase == "other" and c.report == "attach failed: error: attach during load: guard the self-run",
          "report: " .. tostring(c.report))
  assert_(#p.calls == 0, "no callback ran")
end

T["run: a stop before attach returns without reporting a phase"] = function(assert_)
  local p = plugin()
  local b = run_plugin(p, { stopping = true })
  assert_(#b._ctl.describes == 1 and #b._state.attaches == 0, "described only")
  assert_(table.concat(b._ctl.states, ",") == "stopping", "only the host's stopping: "
          .. table.concat(b._ctl.states, ","))
  assert_(#p.calls == 0, "no callback")
end

-- A GUI stop while on_start runs: the host has already sent stopping, so the framework's
-- ctl_state("running") is a no-op. The run must still end through on_stop and detach.
local function stop_in_on_start(ctl_opts)
  local p = plugin({ on_start = function() _G.bwu._ctl.stop() end })
  return p, run_plugin(p, ctl_opts)
end

T["run: a stop during on_start runs on_stop, detaches and ends stopped"] = function(assert_)
  local p, b = stop_in_on_start()
  assert_(names(p.calls) == "on_config_update,on_start,on_stop", "no on_loop: " .. names(p.calls))
  assert_(b._state.detaches[1] == CLIENT_PID, "detached")
  assert_(table.concat(b._ctl.states, ",") == "attaching,stopping", "states: " .. table.concat(b._ctl.states, ","))
  assert_(#crashes(b) == 0, "stopped, not crashed")
end

T["run: a host that refuses running after a stop is treated as the stop"] = function(assert_)
  local p, b = stop_in_on_start({ refuse_after_stop = true })
  assert_(names(p.calls) == "on_config_update,on_start,on_stop", "no on_loop: " .. names(p.calls))
  assert_(b._state.detaches[1] == CLIENT_PID, "detached")
  assert_(#crashes(b) == 0, "stopped, not crashed")
end

T["run: a stop during the initial on_config_update still pairs on_start with on_stop"] = function(assert_)
  local p = plugin({ on_config_update = function() _G.bwu._ctl.stop() end })
  local b = run_plugin(p)
  assert_(names(p.calls) == "on_config_update,on_start,on_stop", "callbacks: " .. names(p.calls))
  assert_(b._state.detaches[1] == CLIENT_PID and #crashes(b) == 0, "detached, stopped")
end

T["run: a stop during a queued on_config_update runs no further on_loop"] = function(assert_)
  local updates = 0
  local p = plugin({
    on_config_update = function()
      updates = updates + 1
      if updates == 2 then _G.bwu._ctl.stop() end
    end,
    on_loop = function(_, n)
      if n == 1 then _G.bwu._ctl.push(4, { logs = 3, tree = "oak" }) end
      return 0
    end,
  })
  local b = run_plugin(p)
  assert_(names(p.calls) == "on_config_update,on_start,on_loop,on_config_update,on_stop",
          "callbacks: " .. names(p.calls))
  assert_(b._ctl.dones[1] and b._ctl.dones[1].ok, "the update is still acked")
  assert_(#crashes(b) == 0, "stopped, not crashed")
end

T["run: an invalid schema returns without running"] = function(assert_)
  local p = plugin({ config_fields = { { key = "x", kind = "item_id", label = "X", default = -2 } } })
  local b = run_plugin(p)
  assert_(#b._ctl.states == 0 and #p.calls == 0 and #b._state.attaches == 0, "nothing ran")
  assert_(#crashes(b) == 0, "the host reports it")
end

T["run: a NaN delay from on_loop ends the loop"] = function(assert_)
  local p = plugin({ on_loop = function() return 0 / 0 end })
  local b = run_plugin(p, { stop_after_waits = 50 })
  assert_(names(p.calls) == "on_config_update,on_start,on_loop,on_stop", "one on_loop: " .. names(p.calls))
  assert_(#b._ctl.waits == 0, "it did not sleep")
  assert_(#crashes(b) == 0, "a normal end")
end

-- run: self-running -------------------------------------------------------------------------

local function with_env(vars, fn)
  local real = os.getenv
  os.getenv = function(k) if vars[k] ~= nil then return vars[k] end return real(k) end
  local ok, err = pcall(fn)
  os.getenv = real
  if not ok then error(err, 0) end
end

T["run: a self-running file reports running and runs with zero arguments"] = function(assert_)
  local b = setup()
  local attached
  _G.FIXTURE_SELF_RUN = function() attached = require("botwithus").Game.attach():pid() end
  with_env({ BWU_CLIENT_PID = "777" }, function() worker.run(fixture("plugin"), CLIENT_PID) end)
  assert_(table.concat(b._ctl.states, ",") == "running", "only running: " .. table.concat(b._ctl.states, ","))
  assert_(#_G.FIXTURE_CALLS == 2 and _G.FIXTURE_CALLS[2].n == 0, "loaded again with zero arguments")
  assert_(attached == 777, "the default attach target is BWU_CLIENT_PID in a worker")
  assert_(#crashes(b) == 0, "a clean end")
end

T["run: a self-run error is a crash in on_loop"] = function(assert_)
  local b = setup()
  _G.FIXTURE_SELF_RUN = function() error("self-run broke") end
  worker.run(fixture("plugin"), CLIENT_PID)
  local c = crashes(b)[1]
  assert_(c and c.phase == "on_loop" and c.report:find("self-run broke", 1, true), "crash phase on_loop")
end

T["run: os.exit in a self-run ends the run, not the worker"] = function(assert_)
  local real_exit = os.exit
  local b = setup()
  _G.FIXTURE_SELF_RUN = function() os.exit(0) end
  worker.run(fixture("plugin"), CLIENT_PID)
  assert_(#crashes(b) == 0, "os.exit(0) is a normal end")
  assert_(os.exit == real_exit, "os.exit restored")

  b = setup()
  _G.FIXTURE_SELF_RUN = function() os.exit(3) end
  worker.run(fixture("plugin"), CLIENT_PID)
  local c = crashes(b)[1]
  assert_(c and c.phase == "on_loop" and c.report == "os.exit(3)", "a non-zero exit is a crash")
  assert_(os.exit == real_exit, "os.exit restored after a crash")
end

T["run: bot.run in a worker self-run ignores max_iters with one info line"] = function(assert_)
  local b = setup({ stop_after_waits = 4 })
  local loops = 0
  _G.FIXTURE_SELF_RUN = function()
    require("botwithus").run({ manifest = { name = "S" }, on_loop = function()
      loops = loops + 1
      return 1
    end }, { max_iters = 1 })
  end
  worker.run(fixture("plugin"), CLIENT_PID)
  assert_(loops > 1, "max_iters ignored: ran " .. loops .. " loops until stop")
  local infos = 0
  for _, w in ipairs(b._runlog.writes) do
    if w.level == b.LOG_INFO and w.msg == "botwithus: worker mode ignores bot.run options: max_iters" then
      infos = infos + 1
    end
  end
  assert_(infos == 1, "one info record")
  assert_(#crashes(b) == 0, "stopped cleanly")
end

T["run: a self-run whose bot.run crashed writes one crash block, no ERROR line"] = function(assert_)
  local b = setup()
  _G.FIXTURE_SELF_RUN = function()
    require("botwithus").run({ manifest = { name = "S" }, on_loop = function() error("inner broke") end })
  end
  worker.run(fixture("plugin"), CLIENT_PID)
  assert_(#crashes(b) == 1 and crashes(b)[1].phase == "on_loop" and crashes(b)[1].iteration == 1,
          "the one block is bot.run's: " .. #crashes(b))
  for _, w in ipairs(b._runlog.writes) do
    assert_(w.level ~= b.LOG_ERROR, "no ERROR line: " .. tostring(w.msg))
  end
end

T["clients: wait_for and wait_attached return nil, stopping once the run is stopping"] = function(assert_)
  local b = setup()
  local cm = require("botwithus").clients.new()
  local h = cm:launch("acct-1")
  b._ctl.stop()
  local ev, code = cm:wait_for(function() return true end, 5)
  assert_(ev == nil and code == "stopping", "wait_for: " .. tostring(code))
  local game, code2 = h:wait_attached(5)
  assert_(game == nil and code2 == "stopping", "wait_attached: " .. tostring(code2))
  assert_(#b._state.attaches == 0, "nothing attached")
  assert_(require("botwithus").stopping() == true, "bot.stopping()")
end

-- bot.run on the command line ---------------------------------------------------------------

T["bot.run (CLI): a NaN delay from on_loop ends the loop"] = function(assert_)
  local b = setup({ mode = "cli" })
  local wait = b.ctl_wait
  b.ctl_wait = function(ms)   -- a sleep that never ends would hang the suite: fail it instead
    if #b._ctl.waits >= 100 then error("slept on a NaN delay", 0) end
    return wait(ms)
  end
  local loops = 0
  local ok, err = pcall(require("botwithus").run,
    { on_loop = function() loops = loops + 1; return 0 / 0 end }, { max_iters = 50 })
  assert_(ok, "ran cleanly: " .. tostring(err))
  assert_(loops == 1, "one on_loop, got " .. loops)
  assert_(#b._ctl.waits == 0, "it did not sleep")
end

T["bot.run (CLI): an initial on_config_update error skips on_start and on_stop"] = function(assert_)
  local b = setup({ mode = "cli" })
  local p = plugin({ on_config_update = function() error("config broke") end })
  local ok, err = pcall(require("botwithus").run, p, { max_iters = 1 })
  assert_(not ok and tostring(err):find("config broke", 1, true), "re-raised: " .. tostring(err))
  assert_(names(p.calls) == "on_config_update", "nothing else ran: " .. names(p.calls))
  assert_(crashes(b)[1].phase == "on_config_update", "crash phase on_config_update")
  assert_(b._state.detaches[1] == 4242, "detached")
end

T["bot.run (CLI): on_config_update gets the defaults before on_start"] = function(assert_)
  local b = setup({ mode = "cli" })
  local p = plugin()
  local seen_in_start
  p.on_start = function(ctx) p.calls[#p.calls + 1] = { "on_start" }; seen_in_start = ctx.config end
  require("botwithus").run(p, { max_iters = 1 })
  assert_(names(p.calls):sub(1, 25) == "on_config_update,on_start", "order: " .. names(p.calls))
  assert_(seen_in_start.logs == 28 and seen_in_start.tree == "oak", "ctx.config holds the defaults")
  assert_(#b._ctl.describes == 1, "the host validated the schema")
end

T["bot.run (CLI): an invalid schema raises before attaching"] = function(assert_)
  local b = setup({ mode = "cli" })
  local p = plugin({ config_fields = { { key = "s", kind = "string", label = "S", default = string.rep("a", 257) } } })
  local ok, err = pcall(require("botwithus").run, p, { max_iters = 1 })
  assert_(not ok and tostring(err):find("config_schema[0].default", 1, true), "error names the field: " .. tostring(err))
  assert_(#b._state.attaches == 0, "nothing attached")
end

T["bot.run (CLI): BWU_CLIENT_PID is ignored and max_iters honoured"] = function(assert_)
  local b = setup({ mode = "cli" })
  local loops = 0
  with_env({ BWU_CLIENT_PID = "777" }, function()
    require("botwithus").run({ on_loop = function() loops = loops + 1; return 0 end }, { max_iters = 2 })
  end)
  assert_(b._state.attaches[1] == 4242, "discovery, not the variable")
  assert_(loops == 2, "max_iters honoured on the command line")
end

T["bot.run without a ctl surface still sleeps between ticks"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local slept
  require("botwithus").run({ on_loop = function(ctx)
    slept = ctx:sleep_ticks(1)
    return -1
  end })
  assert_(slept == true, "the fallback wait returns true")
end

-- the converted examples --------------------------------------------------------------------

local function example(name)
  local path = package.searchpath("examples." .. name, package.path)
  assert(path, "examples/" .. name .. ".lua not on package.path")
  return path
end

T["examples: loaded with arguments, none runs itself or contacts anything"] = function(assert_)
  for _, name in ipairs({ "woodcutter", "banker", "manager" }) do
    local b = setup({ mode = "describe" })
    b.cm_get = function() error(name .. " contacted the launcher at load") end
    local result = assert(loadfile(example(name), "t"))(name, example(name))
    assert_(#b._state.attaches == 0, name .. " attached at load")
    if name == "manager" then
      assert_(result == nil, "manager is self-running")
    else
      assert_(type(result) == "table" and type(result.on_loop) == "function", name .. " returns its table")
    end
  end
end

T["examples: the worker describes woodcutter and banker as plugins, manager as self-running"] = function(assert_)
  for _, name in ipairs({ "woodcutter", "banker", "manager" }) do
    local b = setup({ mode = "describe" })
    worker.describe(example(name))
    local d = b._ctl.describes[1]
    assert_(d ~= nil and #crashes(b) == 0, name .. " described without a crash")
    assert_((d.self_running == true) == (name == "manager"), name .. " self_running")
  end
end

-- helpers exposed to the specs --------------------------------------------------------------

T["the worker's tick poll is within the stop latency"] = function(assert_)
  assert_(Script.TICK_POLL_MS <= STOP_WAIT_LIMIT_MS, "TICK_POLL_MS " .. Script.TICK_POLL_MS)
end

return T
