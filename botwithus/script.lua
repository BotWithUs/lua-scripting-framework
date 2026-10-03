-- botwithus.script -- the script lifecycle runner.
--
-- Mirrors the Java and C# hosts' contract exactly:
--   on_start(ctx)  once, after attach
--   on_loop(ctx)   repeatedly; returns a delay IN SERVER TICKS, or a negative to stop
--   on_stop(ctx)   once, on stop or error
--
-- The single pacing clock is server_tick (~0.6s). sleep_ticks waits for it to advance
-- and nothing else -- game_cycle and publish_seq are never used for timing (pacing off
-- them shipped a ~30x speed bug once; the API makes that mistake unavailable here).

local Game = require("botwithus.game")

local Script = {}

-- How long one wait between tick polls lasts, in milliseconds.
local TICK_POLL_MS = 15

-- A short wall pause between tick polls, so waiting doesn't pin a core. Pure Lua
-- (no stdlib sleep), so it busy-waits; os.clock() is fine here only because of that.
--
-- The host does offer a real wait -- the client-management event poll -- but reading it
-- takes events off the one queue the whole process shares. A script that never asked for
-- events would silently throw them away, a close request included. So the real wait is
-- used only when the script passes its botwithus.clients manager (opts.clients): its
-- handlers then see every event that arrives while the script sleeps.
local function spin_ms(ms)
  local deadline = os.clock() + ms / 1000
  while os.clock() < deadline do end
end

local function make_wait(clients)
  if not clients then return function() spin_ms(TICK_POLL_MS) end end
  return function()
    local handled, code, msg = clients:pump(TICK_POLL_MS)
    if not handled then error("botwithus: client-management wait failed: " .. tostring(code)
      .. ": " .. tostring(msg), 0) end
  end
end

local function make_ctx(game, wait, clients)
  local ctx = { game = game, clients = clients }
  -- Wait until server_tick advances by n (n<=0 returns immediately). Returns early if the
  -- game was detached meanwhile (its client exited).
  function ctx:sleep_ticks(n)
    if n <= 0 then return end
    if not game:refresh() and not game:is_attached() then return end
    local start = game:server_tick()
    while true do
      wait()
      if not game:refresh() and not game:is_attached() then return end
      if game:server_tick() - start >= n then return end
    end
  end
  return ctx
end

-- The Game to run on, and whether the runner owns it (and so detaches it at the end).
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

-- Run a script table { manifest, on_start?, on_loop, on_stop? } to completion.
--   opts.pid        attach to a specific client (default: the first one found)
--   opts.clients    a botwithus.clients manager: attach through it (at most once per pid)
--                   and wait on its events between ticks (see spin_ms above)
--   opts.client_id  with opts.clients, attach to that launched client
--   opts.game       run on a Game that is already attached; the caller keeps it
--   opts.max_iters  bounds the loop (tests)
-- The loop ends when on_loop returns a negative or non-number, or when the Game is
-- detached because its client exited.
function Script.run(script, opts)
  opts = opts or {}
  assert(type(script.on_loop) == "function", "script needs an on_loop(ctx)")
  local m = script.manifest or {}
  io.stderr:write(string.format("[botwithus] starting %s v%s by %s\n",
    m.name or "?", m.version or "?", m.author or "?"))

  local game, owned = resolve_game(opts)
  local ctx  = make_ctx(game, make_wait(opts.clients), opts.clients)
  local ok, err = pcall(function()
    if script.on_start then script.on_start(ctx) end
    local iters = 0
    while true do
      if not game:refresh() and not game:is_attached() then break end
      local delay = script.on_loop(ctx)
      if type(delay) ~= "number" or delay < 0 then break end
      iters = iters + 1
      if opts.max_iters and iters >= opts.max_iters then break end
      ctx:sleep_ticks(delay)
    end
  end)
  if script.on_stop then pcall(script.on_stop, ctx) end
  if owned then game:detach() end
  if not ok then error(err, 0) end
end

return Script
