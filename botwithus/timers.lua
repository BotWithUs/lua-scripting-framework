-- botwithus.timers -- Stopwatch, Timer and Durations (the Java host's util.Stopwatch, util.Timer
-- and util.Durations).
--
--   local T = require("botwithus.timers")
--   local run = T.Stopwatch.started()
--   local idle = T.Timer.new(30000, 60000)       -- a random 30..60 s countdown
--   if idle:has_expired() then idle:reset() end  -- reset re-rolls the duration
--   print(T.Durations.format(run:elapsed_ms()))  -- "01:02:03", or "2d 01:02:03"
--
-- THE CLOCK. The default clock is the native host's millisecond monotonic clock,
-- bwu.monotonic_ms (host ABI 8): it never goes backwards and does not follow wall-clock changes.
-- On an older host, or a surface without it, it falls back to os.time() in milliseconds, which has
-- one-second resolution. Every constructor takes a clock (a function returning milliseconds) so a
-- test can pass its own. os.clock() is CPU time, not wall time, and is never used here.

local Timers = {}

local MS_PER_SECOND = 1000
local SECONDS_PER_MINUTE = 60
local MINUTES_PER_HOUR = 60
local HOURS_PER_DAY = 24
local MS_PER_HOUR = MS_PER_SECOND * SECONDS_PER_MINUTE * MINUTES_PER_HOUR

-- The default clock, in milliseconds: bwu.monotonic_ms when the host has it (host ABI 8), else
-- os.time() (one-second resolution). Resolved on each call, so a surface installed later counts.
function Timers.now_ms()
  local b = rawget(_G, "bwu")
  if b ~= nil and b.monotonic_ms ~= nil then return b.monotonic_ms() end
  return os.time() * MS_PER_SECOND
end

-- Kept for callers of the old name; the same clock as now_ms.
Timers.wall_ms = function() return Timers.now_ms() end

-- True when the default clock has millisecond resolution (the host's monotonic clock).
function Timers.has_ms_clock()
  local b = rawget(_G, "bwu")
  return b ~= nil and b.monotonic_ms ~= nil
end

-- Stopwatch -------------------------------------------------------------------------------------

local Stopwatch = {}
Stopwatch.__index = Stopwatch

-- A stopped stopwatch at zero. `clock` (optional) returns milliseconds.
function Stopwatch.new(clock)
  return setmetatable({ _clock = clock or Timers.now_ms, _accumulated = 0, _since = 0,
                        _running = false }, Stopwatch)
end

function Stopwatch.started(clock) return Stopwatch.new(clock):start() end

-- Starts (or resumes) counting; a running stopwatch is unchanged.
function Stopwatch:start()
  if not self._running then
    self._since = self._clock()
    self._running = true
  end
  return self
end

Stopwatch.resume = Stopwatch.start

-- Stops counting, keeping the time so far.
function Stopwatch:pause()
  if self._running then
    self._accumulated = self._accumulated + self._clock() - self._since
    self._running = false
  end
  return self
end

-- Back to zero, keeping its running state.
function Stopwatch:reset()
  self._accumulated = 0
  self._since = self._clock()
  return self
end

function Stopwatch:is_running() return self._running end

-- Milliseconds counted: paused time is not included.
function Stopwatch:elapsed_ms()
  local running = self._running and self._clock() - self._since or 0
  return self._accumulated + running
end

-- Timer -----------------------------------------------------------------------------------------

local Timer = {}
Timer.__index = Timer

-- A countdown of a random whole number of milliseconds in min_ms..max_ms (both inclusive), or of
-- exactly min_ms when max_ms is nil. `opts.clock` returns milliseconds; `opts.random(lo, hi)`
-- draws the duration (math.random by default).
function Timer.new(min_ms, max_ms, opts)
  max_ms = max_ms or min_ms
  if min_ms < 0 or min_ms > max_ms then
    error(("botwithus: a timer needs 0 <= min_ms <= max_ms, got %s..%s"):format(min_ms, max_ms), 2)
  end
  opts = opts or {}
  local t = setmetatable({ _min = min_ms, _max = max_ms, _clock = opts.clock or Timers.now_ms,
                           _random = opts.random or math.random }, Timer)
  return t:reset()
end

-- Starts again from now, with a freshly drawn duration.
function Timer:reset()
  self._duration = self._min == self._max and self._min or self._random(self._min, self._max)
  self._start = self._clock()
  return self
end

function Timer:remaining_ms()
  return math.max(0, self._duration - (self._clock() - self._start))
end

function Timer:has_expired() return self:remaining_ms() == 0 end
function Timer:duration_ms() return self._duration end

-- Durations -------------------------------------------------------------------------------------

local Durations = {}

-- "HH:MM:SS", with "Nd " in front once it reaches a day. Negative reads as zero.
function Durations.format(ms)
  local total = math.max(0, ms // MS_PER_SECOND)
  local seconds = total % SECONDS_PER_MINUTE
  local minutes = (total // SECONDS_PER_MINUTE) % MINUTES_PER_HOUR
  local hours_total = total // (SECONDS_PER_MINUTE * MINUTES_PER_HOUR)
  local clock = ("%02d:%02d:%02d"):format(hours_total % HOURS_PER_DAY, minutes, seconds)
  local days = hours_total // HOURS_PER_DAY
  return days == 0 and clock or (days .. "d " .. clock)
end

-- `count` scaled to one hour of `elapsed_ms`, rounded down; 0 for no elapsed time.
function Durations.per_hour(count, elapsed_ms)
  if elapsed_ms <= 0 then return 0 end
  return math.floor(count * MS_PER_HOUR / elapsed_ms)
end

Durations.MS_PER_HOUR = MS_PER_HOUR

Timers.Stopwatch = Stopwatch
Timers.Timer = Timer
Timers.Durations = Durations
return Timers
