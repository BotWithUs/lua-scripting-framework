-- botwithus.worker -- the entry points the native host calls when the GUI runs a script.
--
-- The GUI runs each script in its own worker process (bwu_host --worker / --describe). The
-- host owns the GUI connection; this module loads the script, reports what it is, and drives
-- its lifecycle through the host's run control (bwu.ctl_*). It never sees the connection.
--
--   require("botwithus.worker").describe(path)          -- report the script, run nothing
--   require("botwithus.worker").run(path, client_pid)   -- report it, then run it
--
-- A script file is a plugin when it returns its script table: the file is called as
-- chunk(modname, path), and the table it returns has
--   manifest           { name, version, author, description, category }
--   config_fields      a sequence of field tables (see botwithus.config), or a function
--                      config_fields(script) returning one
--   on_config_update(ctx, config), on_start(ctx), on_loop(ctx), on_stop(ctx)
--                      on_loop is required; the others are optional
-- A file that returns anything else is self-running: it is run as on the command line, with
-- zero arguments, and attaches itself. Its self-run belongs under
--   if select("#", ...) == 0 then ... end
-- so loading it to describe it does nothing.
--
-- Neither entry raises for a script failure: a failure is written to the run log as a crash
-- block, which the host turns into the run's outcome. Both return only when the script is done.

local Config = require("botwithus.config")
local Ctl    = require("botwithus.ctl")
local Game   = require("botwithus.game")
local Script = require("botwithus.script")

local M = {}

-- The run log crash phases (the host maps them to the GUI's crash kinds).
local PHASE_LOAD, PHASE_OTHER = "load", "other"
local PHASE_ON_LOOP = "on_loop"

local function surface()
  local b = rawget(_G, "bwu")
  if not b then error("botwithus.worker: native `bwu` surface not present (run under bwu_host)", 2) end
  return b
end

-- The file name without its directory or ".lua": the script's module name.
local function stem_of(path)
  local name = path:match("([^/\\]+)$") or path
  return (name:gsub("%.lua$", ""))
end

-- The directory a script file is in ("." for a bare file name).
local function dir_of(path)
  return path:match("^(.*)[/\\][^/\\]*$") or "."
end

-- Let the script `require` the files beside it: put its directory first on package.path,
-- once, before the file is loaded.
local function add_script_dir(path)
  local dir = dir_of(path)
  local entries = dir .. "/?.lua;" .. dir .. "/?/init.lua;"
  if package.path:sub(1, #entries) ~= entries then package.path = entries .. package.path end
end

-- A traceback-taking message handler for xpcall.
local capture = Script._capture

-- Report a failure as the run's crash block. Only the first block of a run is kept; a later
-- failure becomes an ERROR line.
local function crash(phase, report, iteration)
  Script._RunLog.bound():crash(phase, iteration or 0, report)
end

-- The error's own text, for config_ack and os.exit reports: never a traceback.
local function error_text(err)
  if type(err) == "string" then return err end
  if type(err) == "table" and getmetatable(err) == nil and err.err ~= nil then err = err.err end
  if type(err) == "string" then return err end
  return "(error object is a " .. type(err) .. " value)"
end

-- Call fn(...) protected. On success: true, results. On failure: false, the captured failure.
local function try(fn, ...)
  return xpcall(fn, capture, ...)
end

-- Build the description the host reports for a plugin table. Raises on a malformed table.
local function plugin_desc(script, stem)
  if type(script.on_loop) ~= "function" then
    error("the script table has no on_loop function", 0)
  end
  return { manifest = Config.manifest_of(script, stem), config_schema = Config.fields_of(script) }
end

local function self_running_desc(stem)
  return { manifest = { name = stem, version = "1.0", author = "", description = "" },
           config_schema = {}, self_running = true }
end

-- Load the file in plugin mode. Returns { desc, script? }, or nil after writing a load crash.
local function load_plugin(path)
  add_script_dir(path)
  local chunk, load_err = loadfile(path, "t")
  if not chunk then
    crash(PHASE_LOAD, tostring(load_err))
    return nil
  end
  local stem = stem_of(path)
  local ok, result = try(chunk, stem, path)
  if not ok then
    crash(PHASE_LOAD, result.report)
    return nil
  end
  if type(result) ~= "table" then return { desc = self_running_desc(stem) } end
  local built, desc = try(plugin_desc, result, stem)
  if not built then
    crash(PHASE_LOAD, desc.report)
    return nil
  end
  return { desc = desc, script = result }
end

-- Report the script to the host. Returns the initial config, or nil when it is invalid (the
-- host already has the reason and ends the run as a schema crash).
local function describe_loaded(loaded)
  return surface().ctl_describe(loaded.desc)
end

function M.describe(path)
  local loaded = load_plugin(path)
  if not loaded then return end
  describe_loaded(loaded)
end

-- Report a framework phase. Returns true, or false when the run is stopping (the GUI's stop
-- can arrive at any moment, and the host may then refuse a later phase). Any other refusal is
-- a framework bug, so it raises (the host reports it as a host crash).
local function report_state(phase)
  local ok, err = surface().ctl_state(phase)
  if ok then return not Ctl.stopping() end
  if Ctl.stopping() then return false end
  error("botwithus.worker: ctl_state(" .. phase .. ") refused: " .. tostring(err), 0)
end

-- os.exit inside a self-run ends the run, not the worker: it is replaced, for the self-run's
-- duration, by a function that raises this marker.
local Exit = {}

local function exit_marker(code) error(setmetatable({ code = code }, Exit), 0) end

local function capture_or_exit(err)
  if getmetatable(err) == Exit then return err end
  return capture(err)
end

-- A self-run's exit code that means a normal end: none, true or 0.
local function is_clean_exit(code)
  return code == nil or code == true or code == 0
end

-- Run a self-running file the command-line way: loaded fresh and called with zero arguments.
local function self_run(path)
  local chunk, load_err = loadfile(path, "t")
  if not chunk then
    crash(PHASE_ON_LOOP, tostring(load_err))
    return
  end
  local real_exit = os.exit
  os.exit = exit_marker
  local ok, failure = xpcall(chunk, capture_or_exit)
  os.exit = real_exit
  if ok then return end
  if getmetatable(failure) == Exit then
    if not is_clean_exit(failure.code) then
      crash(PHASE_ON_LOOP, "os.exit(" .. tostring(failure.code) .. ")")
    end
    return
  end
  -- A bot.run inside the self-run reports its own failure, then re-raises it here: that
  -- failure is already the run's crash block, so it is not reported a second time.
  if Script._crash_written() then return end
  crash(PHASE_ON_LOOP, failure.report)
end

-- Call script[name](ctx, ...) when the script defines it. Returns true, or false after
-- writing the crash block for `name`.
local function callback(script, name, ctx, ...)
  local fn = script[name]
  if not fn then return true end
  local ok, failure = try(fn, ctx, ...)
  if ok then return true end
  crash(name, failure.report)
  return false
end

-- The next config change to apply: one the loop's sleep already took, else the host's next.
local function next_change(b, pending)
  local change = table.remove(pending, 1)
  if change then return change.id, change.config end
  return b.ctl_take_config()
end

-- The wait between the loop sleep's tick polls. It ends the sleep for a stop, as every wait
-- does, and also when the GUI queues a config change: the change is taken into `pending` and
-- applied, in order, at the top of the next iteration. Without this, a stalled server tick
-- (the lobby, a frozen client) holds the change until ticks resume. A change still pending
-- at a stop stays unacked, as one never taken does. The script's own ctx:sleep_ticks does not
-- end for a change: its true means the ticks passed.
local function config_waking_wait(b, pending)
  local wait = Script._make_wait(nil)
  return function()
    if not wait() then return false end
    local id, config = b.ctl_take_config()
    if id == nil then return true end
    pending[#pending + 1] = { id = id, config = config }
    return false
  end
end

-- Apply every queued config change, in order. Returns false after an on_config_update error.
local function apply_queued_config(b, script, ctx, pending)
  while true do
    local id, config = next_change(b, pending)
    if id == nil then return true end
    ctx.config = config
    local ok, failure = true, nil
    if script.on_config_update then ok, failure = try(script.on_config_update, ctx, config) end
    if ok then
      b.ctl_config_done(id, true)
    else
      b.ctl_config_done(id, false, error_text(failure.err))
      crash("on_config_update", failure.report)
      return false
    end
  end
end

-- One loop iteration: queued config, then on_loop, then the sleep. Returns true to go on.
local function iterate(b, script, ctx, iteration, pending, sleep_wait)
  if not apply_queued_config(b, script, ctx, pending) then return false end
  if b.ctl_stopping() then return false end
  if not ctx.game:refresh() and not ctx.game:is_attached() then return false end
  local ok, delay = try(script.on_loop, ctx)
  if not ok then
    crash(PHASE_ON_LOOP, delay.report, iteration)
    return false
  end
  if Script._ends_loop(delay) then return false end
  return Script._sleep_ticks(ctx.game, sleep_wait, delay) or not b.ctl_stopping()
end

local function loop(b, script, ctx)
  local pending = {}
  local sleep_wait = config_waking_wait(b, pending)
  local iteration = 0
  while not b.ctl_stopping() do
    iteration = iteration + 1
    if not iterate(b, script, ctx, iteration, pending, sleep_wait) then return end
  end
end

-- Steps 4-12 of a plugin run, once described.
local function run_plugin(b, script, config, client_pid)
  if not report_state("attaching") then return end
  local game, code, msg = Game.try_attach(client_pid)
  if not game then
    crash(PHASE_OTHER, "attach failed: " .. tostring(code) .. ": " .. tostring(msg))
    return
  end
  local ctx = Script._make_ctx(game, Script._make_wait(nil), nil)
  ctx.config = config
  if b.ctl_stopping() then game:detach(); return end
  if not callback(script, "on_config_update", ctx, config) then game:detach(); return end
  if not callback(script, "on_start", ctx) then
    callback(script, "on_stop", ctx)
    game:detach()
    return
  end
  -- A stop during on_config_update or on_start: the loop sees it and runs no on_loop.
  report_state("running")
  loop(b, script, ctx)
  b.ctl_state("stopping")   -- a no-op when the host already reported stopping
  callback(script, "on_stop", ctx)
  game:detach()
end

function M.run(path, client_pid)
  local b = surface()
  local loaded = load_plugin(path)
  if not loaded then return end
  local config = describe_loaded(loaded)
  if config == nil then return end
  if b.ctl_stopping() then return end
  if loaded.desc.self_running then
    if not report_state("running") then return end
    self_run(path)
    return
  end
  run_plugin(b, loaded.script, config, client_pid)
end

return M
