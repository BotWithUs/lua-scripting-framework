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

-- Walk plan options (bwu_host_surface.h BWU_MOVE_*). MOVE_* are BIT NUMBERS: switch categories
-- off with disabled_moves = M.moves_mask(M.MOVE_DOORS, ...). RESTRICT_FREE_TO_PLAY is already a
-- mask bit; add it to a mask with +, never twice.
M.MOVE_DOORS         = 0
M.MOVE_SHORTCUTS     = 1
M.MOVE_PLANE         = 2
M.MOVE_CLIMBOVERS    = 3
M.MOVE_TRANSPORTS    = 4
M.MOVE_TELEPORTS     = 5
M.MOVE_LODESTONES    = 6
M.MOVE_FAIRY_RINGS   = 7
M.MOVE_SPIRIT_TREES  = 8
M.MOVE_GLIDERS       = 9
M.MOVE_CHARTERS      = 10
M.MOVE_MAGIC_CARPETS = 11
M.MOVE_OTHER_CHAINS  = 12
M.RESTRICT_FREE_TO_PLAY = 2147483648
M.MAX_EXCLUDED = 256   -- most transition indices one walk / path may exclude

-- The disabled_moves mask switching off each MOVE_* category given (integer arithmetic only,
-- so it stays an integer on every Lua the framework supports). A repeat counts once.
function M.moves_mask(...)
  local mask, seen = 0, {}
  for i = 1, select("#", ...) do
    local c = select(i, ...)
    if type(c) ~= "number" or c < M.MOVE_DOORS or c > M.MOVE_OTHER_CHAINS or c % 1 ~= 0 then
      error("botwithus.walk.moves_mask: not a MOVE_* category: " .. tostring(c), 2)
    end
    if not seen[c] then
      seen[c] = true
      local bit = 1
      for _ = 1, c do bit = bit * 2 end
      mask = mask + bit
    end
  end
  return mask
end

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
