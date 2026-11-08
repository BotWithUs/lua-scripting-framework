-- botwithus.actions -- the action-id table and small builders.
--
-- queue_action on the `bwu` table takes (host, id, p1, p2, p3); these builders name the
-- common shapes so scripts don't pass bare integers. The ids and param shapes are the
-- agent's, and the builders send exactly what the Python framework's builders send, so the
-- two frontends never disagree about what an action means.

local Actions = {}

-- Known action ids (extend as the surface grows).
Actions.WALK            = 23
-- Click a component option: p1 = 1-based option (1..10), p2 = sub-slot (-1 none),
-- p3 = (iface << 16) | comp.
Actions.COMPONENT       = 57
-- Select a multi-choice dialogue option: p1 = 0, p2 = -1, p3 = (iface << 16) | comp.
Actions.DIALOGUE        = 30
-- Fire a component's CS2 trigger: p1 = (iface << 16) | comp,
-- p2 = (triggerType << 16) | (sub & 0xFFFF), p3 = the trigger's arg (see botwithus.input for keys).
Actions.COMPONENT_TRIGGER = 5003

-- Older names, kept so existing scripts keep loading. COMPONENT_CLICK is the same id.
-- DIALOGUE_OPTION used to be 43, an id the agent does not have; it now names the real one.
Actions.COMPONENT_CLICK = Actions.COMPONENT
Actions.DIALOGUE_OPTION = Actions.DIALOGUE

-- The first option slot, and "no sub-slot".
Actions.DEFAULT_OPTION = 1
Actions.NO_SUB_SLOT    = -1

local COMPONENT_SHIFT = 16

-- The (iface << 16) | comp hash a component action carries.
function Actions.component_hash(interface_id, component_id)
  return (interface_id << COMPONENT_SHIFT) | component_id
end

-- Walk to a tile. p1 == 1 is the "minimap/scene walk" selector the agent expects.
function Actions.walk_to(x, y)
  return { id = Actions.WALK, p1 = 1, p2 = x, p3 = y }
end

-- Click option `option` (default 1) of a component, or of one slot of an inventory-style
-- grid when `sub_slot` is given (default -1, none).
function Actions.component_click(interface_id, component_id, option, sub_slot)
  return { id = Actions.COMPONENT, p1 = option or Actions.DEFAULT_OPTION,
           p2 = sub_slot or Actions.NO_SUB_SLOT,
           p3 = Actions.component_hash(interface_id, component_id) }
end

-- Select the dialogue option that is component `component_id` of interface `interface_id`.
-- This is the agent's dialogue action, not a plain component click.
function Actions.dialogue_option(interface_id, component_id)
  if component_id == nil then
    error("botwithus: dialogue_option takes (interface_id, component_id), not an option index", 2)
  end
  return { id = Actions.DIALOGUE, p1 = 0, p2 = Actions.NO_SUB_SLOT,
           p3 = Actions.component_hash(interface_id, component_id) }
end

return Actions
