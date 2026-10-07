-- botwithus.walk -- constants and helpers for the native host's walk progress surface.
--
-- The host records every WorldWalker event during a walk, the step and transition a failed
-- walk failed on, and the transition it last attempted as OBSERVED through its callbacks (the
-- loc it tried to interact with, the NPC it tried to click, the chain steps it ran). Results
-- and events are plain tables from bwu.walk_ex / walk_status / walk_wait / walk_events; field
-- meanings follow bwu_host_surface.h (BwuWalkResult / BwuWalkEvent / BwuWalkTransition).
--
-- The values are restated here so a script can name them without the native surface.
local M = {}

-- result.status
M.RUNNING   = 0
M.ARRIVED   = 1
M.FAILED    = 2
M.CANCELLED = 3
M.TIMED_OUT = 4
M.ERROR     = 5

-- event.kind / result.final_event (WorldWalker WW_EVENT_*)
M.EV_STEP_ADVANCED       = 0
M.EV_WALKING_TO_INTERACT = 1
M.EV_TELEPORT_INITIATED  = 2
M.EV_STUCK               = 3
M.EV_REPLAN_STARTED      = 4
M.EV_ARRIVED             = 5
M.EV_FAILED              = 6
M.EV_NONE                = -1

-- transition.kind (what the host saw the walker do)
M.TX_NONE     = 0
M.TX_OBJECT   = 1
M.TX_NPC      = 2
M.TX_CHAIN    = 3
M.TX_TELEPORT = 4

-- True while the walk has not ended.
function M.is_running(result)
  return result ~= nil and result.status == M.RUNNING
end

-- The observed transition the walk failed on, or nil when it failed elsewhere (a walk step,
-- no route) or did not fail. result.transition can be an earlier transition that succeeded.
function M.failed_on_transition(result)
  if result == nil or result.fail_transition < 0 then return nil end
  local t = result.transition
  if t == nil or t.transition_index ~= result.fail_transition then return nil end
  return t
end

-- True if any event in `events` has kind `kind`.
function M.has_event(events, kind)
  for _, e in ipairs(events or {}) do
    if e.kind == kind then return true end
  end
  return false
end

return M
