-- botwithus.actions -- the action-id table and small builders.
--
-- Ids mirror the host surface / api actions table (WALK == 23). queue_action on
-- the `bwu` table takes (host, id, p1, p2, p3); these builders name the common
-- shapes so scripts don't pass bare integers.

local Actions = {}

-- Known action ids (extend as the surface grows).
Actions.WALK            = 23
Actions.COMPONENT_CLICK = 57
Actions.DIALOGUE_OPTION = 43

-- Walk to a tile. p1 == 1 is the "minimap/scene walk" selector the agent expects.
function Actions.walk_to(x, y)
  return { id = Actions.WALK, p1 = 1, p2 = x, p3 = y }
end

function Actions.component_click(interface_id, component_id)
  return { id = Actions.COMPONENT_CLICK, p1 = interface_id, p2 = component_id, p3 = 0 }
end

function Actions.dialogue_option(index)
  return { id = Actions.DIALOGUE_OPTION, p1 = index, p2 = 0, p3 = 0 }
end

return Actions
