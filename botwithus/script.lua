-- botwithus.script -- the script lifecycle runner.
--
-- Mirrors the Java and C# hosts' contract exactly:
--   on_config_update(ctx, config)  once with the initial config, before on_start, and again
--                                  whenever the config changes (optional)
--   on_start(ctx)  once, after attach
--   on_loop(ctx)   repeatedly; returns a delay IN SERVER TICKS, or a negative to stop
--   on_stop(ctx)   once, on stop or error
--
-- The single pacing clock is server_tick (~0.6s). sleep_ticks waits for it to advance
-- and nothing else -- game_cycle and publish_seq are never used for timing (pacing off
-- them shipped a ~30x speed bug once; the API makes that mistake unavailable here).
--
-- Stop: when the GUI stops a run, ctx:stopping() turns true, ctx:sleep_ticks returns false
-- early (within a tick poll), and no further on_loop runs.

local Game   = require("botwithus.game")
local Config = require("botwithus.config")
local Ctl    = require("botwithus.ctl")

local Script = {}

-- How long one wait between tick polls lasts, in milliseconds. It also bounds how long a
-- sleeping script takes to see a stop.
local TICK_POLL_MS = 15
Script.TICK_POLL_MS = TICK_POLL_MS

-- A short wall pause between tick polls, for a surface with no ctl_wait (an older host or a
-- test fake). Pure Lua (no stdlib sleep), so it busy-waits; os.clock() is fine here only
-- because of that.
local function spin_ms(ms)
  local deadline = os.clock() + ms / 1000
  while os.clock() < deadline do end
end

-- The wait between tick polls. Returns false when the run is stopping, else true.
--
-- The host's ctl_wait is a real sleep that returns at once on stop. The host also offers the
-- client-management event poll, but reading it takes events off the one queue the whole
-- process shares, so a script that never asked for events would throw them away. That wait is
-- used only when the script passes its botwithus.clients manager (opts.clients): its handlers
-- then see every event that arrives while the script sleeps, and stop is checked after it.
local function make_wait(clients)
  if clients then
    return function()
      local handled, code, msg = clients:pump(TICK_POLL_MS)
      if not handled then error("botwithus: client-management wait failed: " .. tostring(code)
        .. ": " .. tostring(msg), 0) end
      return not Ctl.stopping()
    end
  end
  local waiter = Ctl.waiter()
  if waiter then return function() return waiter(TICK_POLL_MS) end end
  return function() spin_ms(TICK_POLL_MS); return true end
end
Script._make_wait = make_wait

-- Wait until server_tick advances by n, calling wait() between polls. Returns true when it
-- did, false when the run is stopping, the game was detached meanwhile (its client exited) or
-- wait() returned false. n <= 0 returns at once.
local function sleep_ticks(game, wait, n)
  if Ctl.stopping() then return false end
  if n <= 0 then return true end
  if not game:refresh() and not game:is_attached() then return false end
  local start = game:server_tick()
  while true do
    if not wait() then return false end
    if not game:refresh() and not game:is_attached() then return false end
    if game:server_tick() - start >= n then return true end
  end
end
Script._sleep_ticks = sleep_ticks

local function make_ctx(game, wait, clients)
  local ctx = { game = game, clients = clients, config = {} }
  -- Wait until server_tick advances by n. Returns true when it did, false when the run is
  -- stopping or the game was detached meanwhile (its client exited). n <= 0 returns at once.
  function ctx:sleep_ticks(n) return sleep_ticks(game, wait, n) end
  -- True once the run has been asked to stop: finish up and return from on_loop.
  function ctx:stopping() return Ctl.stopping() end
  return ctx
end
Script._make_ctx = make_ctx

-- The Game to run on, and whether the runner owns it (and so detaches it at the end).
-- Precedence: opts.game, then opts.pid / opts.client_id, then (in a GUI worker) the client
-- the GUI picked, then the first discovered client (Game.attach_target).
local function resolve_game(opts)
  if opts.game then return opts.game, false end
  local cm = opts.clients
  if cm then
    local pid = opts.pid
    if opts.client_id then
      local code, msg
      pid, code, msg = cm:pid_of(opts.client_id)
      if not pid then error("botwithus: attach failed: " .. tostring(code) .. ": " .. tostring(msg), 0) end
    end
    pid = pid or Game.attach_target()
    -- A Game the manager already held stays the caller's: the runner does not detach it.
    local held = cm:game_for(pid)
    if held then return held, false end
    local game, code, msg = cm:attach_pid(pid, opts.client_id)
    if not game then error("botwithus: attach failed: " .. tostring(code) .. ": " .. tostring(msg), 0) end
    return game, true
  end
  return Game.attach(opts.pid), true
end

-- The script run log (native-scripting-host's bwu.runlog_*): one redacted file per run, with a
-- crash block when the script stops on an error. Every call is a no-op on a surface without
-- it (a test fake, an older host). The native side owns the file, the redaction and the
-- breadcrumbs of the script's host calls; this runner adds the phase and the state changes.
local RunLog = {}
RunLog.__index = RunLog
Script._RunLog = RunLog

-- `source` is the chunk name of the file that called Script.run ("@<path>").
function RunLog.open(manifest, game, source)
  local b = rawget(_G, "bwu")
  if not (b and b.runlog_open) then return setmetatable({}, RunLog) end
  local path = type(source) == "string" and source:sub(1, 1) == "@" and source:sub(2) or nil
  local id = b.runlog_open({ name = manifest.name, version = manifest.version,
                             author = manifest.author, path = path, pid = game:pid() or 0 })
  return setmetatable({ b = b, id = id }, RunLog)
end

-- The run the host already opened and bound (a GUI worker): crash blocks and crumbs go to it,
-- and the runner never closes it.
function RunLog.bound()
  local b = rawget(_G, "bwu")
  if not (b and b.runlog_crash) then return setmetatable({}, RunLog) end
  return setmetatable({ b = b, host_owned = true }, RunLog)
end

function RunLog:state(from, to)
  if self.b and self.b.runlog_crumb then self.b.runlog_crumb("state", from .. "->" .. to) end
end

-- Surfaces whose run log already holds a crash block written by this framework. A GUI worker
-- has one surface and one run, so this tells the worker that a self-run's bot.run already
-- reported the failure it is about to see.
local crash_written = setmetatable({}, { __mode = "k" })

function Script._crash_written()
  local b = rawget(_G, "bwu")
  return b ~= nil and crash_written[b] == true
end

-- Write the crash block; a run keeps only its first, so a later failure becomes an ERROR line.
function RunLog:crash(phase, iteration, report)
  if not self.b then return end
  if self.b.runlog_crash({ phase = phase, iteration = iteration, report = report }) then
    crash_written[self.b] = true
  else
    self.b.runlog_write(self.b.LOG_ERROR, "botwithus.script", phase .. " failed: " .. report)
  end
end

-- One info record in the run log (stdout when there is no run log).
function RunLog:info(message)
  local b = rawget(_G, "bwu")
  if b and b.runlog_write and b.LOG_INFO then
    b.runlog_write(b.LOG_INFO, "botwithus.script", message)
  else
    io.stderr:write("[botwithus] " .. message .. "\n")
  end
end

function RunLog:close()
  if self.b and not self.host_owned then self.b.runlog_close(self.id) end
end

-- xpcall message handler: keep the error itself (to re-raise unchanged) and the traceback
-- taken where it was raised, while the failing frames still exist.
local function capture(err)
  local trace = rawget(_G, "debug") and debug.traceback(tostring(err), 2) or tostring(err)
  return { err = err, report = trace }
end
Script._capture = capture

-- Options bot.run honours only on the command line. A GUI worker runs until on_loop ends
-- the run, the client exits, or the GUI stops it.
local CLI_ONLY_OPTIONS = { "max_iters" }

-- The CLI-only options a worker ignores: their names, or nil when none were given.
local function ignored_options(opts)
  local names = {}
  for _, name in ipairs(CLI_ONLY_OPTIONS) do
    if opts[name] ~= nil then names[#names + 1] = name end
  end
  return #names > 0 and table.concat(names, ", ") or nil
end

-- Hosts whose ctl_describe already validated a bot.run schema. The host accepts one describe
-- per process; a second bot.run in the same command-line run is checked in Lua instead.
local described = setmetatable({}, { __mode = "k" })

-- The initial config for a bot.run: the defaults of the script's fields, validated.
-- On the command line the host validates them (ctl_describe sends nothing there). In a GUI
-- worker the script is a self-run, which the GUI described as having no settings, so its
-- defaults are used as declared.
local function initial_config(script, manifest)
  local fields = Config.fields_of(script)
  local b = rawget(_G, "bwu")
  local mode = Ctl.mode()
  if mode == Ctl.WORKER then return Config.defaults(fields) end
  local desc = { manifest = Config.manifest_of({ manifest = manifest }, "script"),
                 config_schema = fields }
  if mode == Ctl.CLI and b and b.ctl_describe and not described[b] then
    described[b] = true
    local config, err = b.ctl_describe(desc)
    if config == nil then error("botwithus: invalid script: " .. tostring(err), 0) end
    return config
  end
  local ok, err = Config.validate_manifest(desc.manifest)
  if ok then ok, err = Config.validate_fields(fields) end
  if not ok then error("botwithus: invalid script: " .. tostring(err), 0) end
  return Config.defaults(fields)
end

-- Whether on_loop's return ends the loop: a negative, a non-number, or NaN (which no wait
-- could ever reach, and which compares false with everything).
local function ends_loop(delay)
  return type(delay) ~= "number" or delay ~= delay or delay < 0
end
Script._ends_loop = ends_loop

-- on_config_update, on_start, then the paced loop. `progress` records the phase and the
-- 1-based iteration, so a failure is reported against the step it escaped from.
local function lifecycle(script, ctx, game, opts, progress)
  if script.on_config_update then
    progress.phase = "on_config_update"
    script.on_config_update(ctx, ctx.config)
  end
  progress.phase = "on_start"
  if script.on_start then script.on_start(ctx) end
  progress.phase = "on_loop"
  local iters = 0
  while not Ctl.stopping() do
    if not game:refresh() and not game:is_attached() then break end
    progress.iteration = iters + 1
    local delay = script.on_loop(ctx)
    if ends_loop(delay) then break end
    iters = iters + 1
    if opts.max_iters and iters >= opts.max_iters then break end
    if not ctx:sleep_ticks(delay) and Ctl.stopping() then break end
  end
end

-- Run a script table { manifest, config_fields?, on_config_update?, on_start?, on_loop,
-- on_stop? } to completion.
--   opts.pid        attach to a specific client (default: the GUI's client in a worker, else
--                   the first one found)
--   opts.clients    a botwithus.clients manager: attach through it (at most once per pid)
--                   and wait on its events between ticks (see make_wait above)
--   opts.client_id  with opts.clients, attach to that launched client
--   opts.game       run on a Game that is already attached; the caller keeps it
--   opts.max_iters  bounds the loop (tests); command line only, ignored in a GUI worker
-- The loop ends when on_loop returns a negative or non-number, when the Game is detached
-- because its client exited, or when the run is stopped.
function Script.run(script, opts)
  opts = opts or {}
  assert(type(script.on_loop) == "function", "script needs an on_loop(ctx)")
  local m = script.manifest or {}
  io.stderr:write(string.format("[botwithus] starting %s v%s by %s\n",
    m.name or "?", m.version or "?", m.author or "?"))

  local worker = Ctl.is_worker()
  local ignored = worker and ignored_options(opts) or nil
  if ignored then
    RunLog:info("botwithus: worker mode ignores bot.run options: " .. ignored)
    local kept = {}
    for k, v in pairs(opts) do kept[k] = v end
    for _, name in ipairs(CLI_ONLY_OPTIONS) do kept[name] = nil end
    opts = kept
  end

  local config = initial_config(script, m)
  local game, owned = resolve_game(opts)
  local ctx  = make_ctx(game, make_wait(opts.clients), opts.clients)
  ctx.config = config
  local caller = rawget(_G, "debug") and debug.getinfo(2, "S") or nil
  local run = RunLog.open(m, game, caller and caller.source)
  run:state("STARTING", "RUNNING")
  local progress = { phase = "on_start", iteration = 0 }
  local ok, failure = xpcall(lifecycle, capture, script, ctx, game, opts, progress)
  if not ok then
    run:state("RUNNING", "ERROR")
    run:crash(progress.phase, progress.phase == "on_loop" and progress.iteration or 0, failure.report)
  end
  -- on_stop pairs with on_start: a failure in the initial on_config_update skips both.
  local started = ok or progress.phase ~= "on_config_update"
  if script.on_stop and started then
    local stopped, stop_failure = xpcall(script.on_stop, capture, ctx)
    if not stopped then run:crash("on_stop", 0, stop_failure.report) end
  end
  if ok then run:state("RUNNING", "STOPPED") end
  run:close()
  if owned then game:detach() end
  if not ok then error(failure.err, 0) end
end

return Script
