-- botwithus.timing -- condition waits and the run's pause switch (the Java host's util.Timing
-- condition waits and runtime.ScriptPause).
--
--   -- inside bot.run, through ctx:
--   if not ctx:delay_until(function() return bank:is_open() end, 5000) then
--     return ctx:stopping() and -1 or 2
--   end
--   ctx:delay_until_ticks(function() return not game:self().moving end, 10)
--   ctx:delay_ticks(2, 4)
--
--   -- anywhere else, bound to a Game:
--   local wait = require("botwithus.timing").for_game(game)
--   wait:until_(cond, 3000)
--
-- Each wait returns whether its condition was met: false means it timed out, its tick budget
-- ran out, the run is stopping, or the client exited. They poll every POLL_MS on the one Lua
-- thread and check for a stop before every poll, so a stop ends a wait within one poll rather
-- than at its timeout. The tick forms count server_tick (600 ms) only -- never game_cycle or
-- publish_seq -- and give up after STALLED_CLOCK_FACTOR tick lengths of wall time per tick when
-- no tick advances (logged out, a frozen client), so a stalled clock never hangs a script.
--
-- PAUSE. While the run is paused (ctx:pause(), see botwithus.script) a wait neither tests its
-- condition nor spends its budget: time spent paused moves the deadline out, and ticks that pass
-- while paused are not counted. A stop still ends a paused wait. A script that pauses itself
-- needs something else to resume it -- a plugin-UI handler or a client-management event
-- handler, both of which run inside the waits.
--
-- TIME. The waits read the host's millisecond monotonic clock, bwu.monotonic_ms (host ABI 8). On
-- an older host they count the milliseconds they slept (the host's stop-aware ctl_wait, a real
-- sleep) and also watch os.time(), so slow condition checks cannot stretch a timeout by more than
-- about one second. A wait never ends before its timeout has really passed.

local Ctl = require("botwithus.ctl")

local Timing = {}

-- How long a wait sleeps between two checks of its condition, in milliseconds.
Timing.POLL_MS = 50
-- Tick lengths of wall time a tick wait allows per tick asked for before it decides the server
-- tick has stopped advancing.
Timing.STALLED_CLOCK_FACTOR = 2
-- One server tick, in milliseconds.
Timing.TICK_MS = 600
-- How often a wait lets plugin-UI events run while it polls (they can resume a pause).
local UI_PUMP_MS = 600
local MS_PER_SECOND = 1000

-- Pause ---------------------------------------------------------------------------------------

local Pause = {}
Pause.__index = Pause

-- The run's pause switch held by the native host (host ABI 8, GUI worker only): the GUI flips it
-- with set_paused, the script with ctx:pause() / ctx:resume(), and both sides see every change.
-- Lua has one thread, so it reads the switch where it holds instead of waiting on it.
local HostPause = {}
HostPause.__index = HostPause

function HostPause.new(b) return setmetatable({ _b = b }, HostPause) end
function HostPause:pause() self._b.ctl_set_paused(true) end
function HostPause:resume()
  local was = self:is_paused()
  self._b.ctl_set_paused(false)
  return was
end
function HostPause:is_paused() return (self._b.ctl_paused()) == true end
Timing.HostPause = HostPause

function Pause.new() return setmetatable({ _paused = false }, Pause) end
function Pause:pause() self._paused = true end
-- Resumes; returns whether it was paused.
function Pause:resume()
  local was = self._paused
  self._paused = false
  return was
end
function Pause:is_paused() return self._paused end

Timing.Pause = Pause

-- The clock ---------------------------------------------------------------------------------

-- A millisecond clock that never runs ahead of real time: the larger of the milliseconds slept
-- through it and the whole seconds of os.time() less one.
local function counting_clock()
  local b = rawget(_G, "bwu")
  if b ~= nil and b.monotonic_ms ~= nil then
    -- The host's monotonic clock: real milliseconds, so nothing needs counting.
    return { now = b.monotonic_ms, add = function() end }
  end
  local slept, t0 = 0, os.time()
  return {
    now = function() return math.max(slept, (os.time() - t0 - 1) * MS_PER_SECOND) end,
    add = function(ms) slept = slept + ms end,
  }
end

-- The engine ---------------------------------------------------------------------------------

local Waiter = {}
Waiter.__index = Waiter

-- A wait engine over injected parts, all optional:
--   now()        monotonic milliseconds (default: a counting clock fed by sleep)
--   sleep(ms)    sleeps; returns false when the run is stopping (default: Ctl's waiter)
--   stopping()   true once the waits must end (default: Ctl.stopping)
--   paused()     true while the run is paused (default: never)
--   tick()       the current server tick, or nil when none is published (tick waits only)
--   on_poll(ms)  called after each sleep with the milliseconds slept
--   random(a, b) draws delay_ticks' count (default math.random)
function Timing.new(parts)
  parts = parts or {}
  local w = setmetatable({}, Waiter)
  local clock = parts.now == nil and counting_clock() or nil
  w._now = parts.now or clock.now
  local sleep = parts.sleep or Timing.default_sleep()
  w._sleep = function(ms)
    local ok = sleep(ms)
    if clock then clock.add(ms) end
    if parts.on_poll then parts.on_poll(ms) end
    return ok ~= false
  end
  w._stopping = parts.stopping or Ctl.stopping
  w._paused = parts.paused or function() return false end
  w._tick = parts.tick
  w._random = parts.random or math.random
  return w
end

-- A pure-Lua wall pause for a surface with no ctl_wait (a test fake, an older host): it spins,
-- which os.clock measures well enough while spinning.
local function spin_ms(ms)
  local deadline = os.clock() + ms / MS_PER_SECOND
  while os.clock() < deadline do end
  return true
end

-- The sleep the waits use outside a test: the host's stop-aware ctl_wait when there is one.
function Timing.default_sleep()
  local waiter = Ctl.waiter()
  if waiter then return waiter end
  return spin_ms
end

-- Sleeps in polls while paused and not stopping; returns the milliseconds held (at least 1 when
-- it held), 0 when not paused.
function Waiter:_hold()
  if not self._paused() then return 0 end
  local start = self._now()
  while self._paused() and not self._stopping() do
    if not self._sleep(Timing.POLL_MS) then break end
  end
  return math.max(1, self._now() - start)
end

-- Polls until `cond()` holds (true), `timeout_ms` passes, or a stop (false). A timeout <= 0
-- checks once.
function Waiter:until_(cond, timeout_ms)
  local deadline = self._now() + math.max(0, timeout_ms)
  while not self._stopping() do
    local held = self:_hold()
    if held > 0 then
      deadline = deadline + held
    else
      if cond() then return true end
      local remaining = deadline - self._now()
      if remaining <= 0 then return false end
      if not self._sleep(math.min(Timing.POLL_MS, remaining)) then return false end
    end
  end
  return false
end

-- Waits until `cond()` stops holding.
function Waiter:while_(cond, timeout_ms)
  return self:until_(function() return not cond() end, timeout_ms)
end

local function ticks_between(a, b)
  if a == nil or b == nil then return 0 end
  return b - a
end

function Waiter:_read_tick()
  if not self._tick then error("botwithus: this wait has no server tick (bind it to a Game)", 3) end
  return self._tick()
end

-- The loop behind both tick waits: true when `cond` holds, `budget_result` once max_ticks have
-- passed, false on a stop or when the wall cap (the stalled-clock guard) runs out.
function Waiter:_run_ticks(cond, max_ticks, budget_result)
  local start = self:_read_tick()
  local cap_ticks = budget_result and max_ticks + 1 or max_ticks
  local wall_deadline = self._now() + cap_ticks * Timing.TICK_MS * Timing.STALLED_CLOCK_FACTOR
  while not self._stopping() do
    local before = self:_read_tick()
    local held = self:_hold()
    if held > 0 then
      local after = self:_read_tick()
      if start ~= nil then start = start + ticks_between(before, after) end
      wall_deadline = wall_deadline + held
    else
      if cond() then return true end
      local now_tick = self:_read_tick()
      if start == nil then start = now_tick end
      if ticks_between(start, now_tick) >= max_ticks then return budget_result end
      if self._now() >= wall_deadline then return false end
      if not self._sleep(Timing.POLL_MS) then return false end
    end
  end
  return false
end

-- Polls until `cond()` holds, for at most `max_ticks` server ticks.
function Waiter:until_ticks(cond, max_ticks)
  return self:_run_ticks(cond, max_ticks, false)
end

-- Waits `ticks` server ticks: true when they passed, false on a stop or a stalled tick.
function Waiter:ticks(ticks)
  return self:_run_ticks(function() return false end, ticks, true)
end

-- Waits a random whole number of server ticks in min_ticks..max_ticks (inclusive).
function Waiter:delay_ticks(min_ticks, max_ticks)
  max_ticks = max_ticks or min_ticks
  local n = min_ticks >= max_ticks and min_ticks or self._random(min_ticks, max_ticks)
  return self:ticks(n)
end

-- The Java names, for ports: delay_until / delay_while / delay_until_ticks.
Waiter.delay_until = Waiter.until_
Waiter.delay_while = Waiter.while_
Waiter.delay_until_ticks = Waiter.until_ticks

-- Bound to a Game -------------------------------------------------------------------------

-- The run pause a Game carries (created on first use; botwithus.script gives each run's Game
-- one, so ctx:pause() and every wait bound to that Game share it).
-- The run's pause switch: the host's in a GUI worker on host ABI 8, else this frontend's own.
function Timing.pause_of(game)
  if game._pause == nil then
    local b = rawget(_G, "bwu")
    local hosted = b ~= nil and b.ctl_paused ~= nil and Ctl.is_worker()
    game._pause = hosted and HostPause.new(b) or Pause.new()
  end
  return game._pause
end

-- The server tick, or nil when the snapshot cannot be read (logged out, no client).
local function tick_of(game)
  local ok, tick = pcall(game.server_tick, game)
  if ok then return tick end
  return nil
end

-- A wait engine bound to `game`: its stop is the run's stop or the client exiting, its pause is
-- the Game's run pause, its tick is the Game's server_tick, and plugin-UI events run once per
-- UI_PUMP_MS while it polls. The stop check refreshes the Game's snapshot, so a condition reads a
-- fresh frame on every poll. `opts` may override any part (see Timing.new).
function Timing.for_game(game, opts)
  opts = opts or {}
  local pause = Timing.pause_of(game)
  local unpumped = 0
  return Timing.new({
    now = opts.now,
    sleep = opts.sleep,
    random = opts.random,
    stopping = opts.stopping or function() return Ctl.stopping() or game:_client_gone() end,
    paused = opts.paused or function() return pause:is_paused() end,
    tick = opts.tick or function() return tick_of(game) end,
    on_poll = function(ms)
      unpumped = unpumped + ms
      if unpumped >= UI_PUMP_MS then
        unpumped = 0
        if game._pump_ui then game:_pump_ui() end
      end
      if opts.on_poll then opts.on_poll(ms) end
    end,
  })
end

return Timing
