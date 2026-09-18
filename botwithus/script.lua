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

-- A short wall pause between tick polls, so waiting doesn't pin a core. Pure Lua
-- (no stdlib sleep); the native host will offer a real wait later.
local function spin_ms(ms)
  local deadline = os.clock() + ms / 1000
  while os.clock() < deadline do end
end

local function make_ctx(game)
  local ctx = { game = game }
  -- Wait until server_tick advances by n (n<=0 returns immediately).
  function ctx:sleep_ticks(n)
    if n <= 0 then return end
    game:refresh()
    local start = game:server_tick()
    while true do
      spin_ms(15)
      game:refresh()
      if game:server_tick() - start >= n then return end
    end
  end
  return ctx
end

-- Run a script table { manifest, on_start?, on_loop, on_stop? } to completion.
-- `opts.pid` attaches to a specific client; `opts.max_iters` bounds the loop (tests).
function Script.run(script, opts)
  opts = opts or {}
  assert(type(script.on_loop) == "function", "script needs an on_loop(ctx)")
  local m = script.manifest or {}
  io.stderr:write(string.format("[botwithus] starting %s v%s by %s\n",
    m.name or "?", m.version or "?", m.author or "?"))

  local game = Game.attach(opts.pid)
  local ctx  = make_ctx(game)
  local ok, err = pcall(function()
    if script.on_start then script.on_start(ctx) end
    local iters = 0
    while true do
      game:refresh()
      local delay = script.on_loop(ctx)
      if type(delay) ~= "number" or delay < 0 then break end
      iters = iters + 1
      if opts.max_iters and iters >= opts.max_iters then break end
      ctx:sleep_ticks(delay)
    end
  end)
  if script.on_stop then pcall(script.on_stop, ctx) end
  game:detach()
  if not ok then error(err, 0) end
end

return Script
