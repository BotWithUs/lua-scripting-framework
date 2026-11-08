-- botwithus.ctl -- the framework's view of the host's run control (bwu.ctl_*).
--
-- Under the GUI the host runs each script in a worker process and passes stop requests and
-- config changes to it. Script code never needs this module: it sees stop through
-- ctx:stopping() and ctx:sleep_ticks(), and config through ctx.config and
-- on_config_update(ctx, config).
--
-- Every function here works on a surface without the ctl functions (an older host or a test
-- fake) and then behaves as a command-line run: never stopping, plain waits.

local M = {}

M.CLI, M.WORKER, M.DESCRIBE = 0, 1, 2

local function surface() return rawget(_G, "bwu") end

-- The run mode: M.CLI, M.WORKER or M.DESCRIBE.
function M.mode()
  local b = surface()
  if not (b and b.ctl_mode) then return M.CLI end
  local mode = b.ctl_mode()
  if mode == b.CTL_WORKER then return M.WORKER end
  if mode == b.CTL_DESCRIBE then return M.DESCRIBE end
  return M.CLI
end

function M.is_worker() return M.mode() == M.WORKER end

-- True once the GUI asked this run to stop (or went away). Never blocks.
function M.stopping()
  local b = surface()
  return (b and b.ctl_stopping and b.ctl_stopping()) and true or false
end

-- A stop-aware wait, or nil when the surface has none.
-- The returned function waits up to ms and returns false when stop is set, else true.
function M.waiter()
  local b = surface()
  if not (b and b.ctl_wait) then return nil end
  return function(ms) return b.ctl_wait(ms) ~= "stop" end
end

return M
