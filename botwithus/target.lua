-- botwithus.target -- "use X on Y" (target mode).
--
--   game:use_item_on_item(0, 3)                -- the knife in slot 0 on the logs in slot 3
--   game:use_item_on_npc(0, npc.server_index)
--   game:use_item_on_object(0, obj.id, obj.tile.x, obj.tile.y)
--   game:use_on_component(Target.ref(1430, 12), Target.backpack(5))
--   local m = game:target_mode()               -- { active, is_item, obj_id, source, verb, ... }
--
-- Each use-on is two actions, as two clicks are for a player: SELECT_COMPONENT (25) arms
-- target mode on the source, then one target action fires: 58 on an item or component, 8 on
-- an NPC, 2 on a loc. The host waits until target mode reads active WITH that source before it
-- fires (active alone could be an earlier arm), and the agent ends target mode after the
-- target action. Each returns true when both actions are queued, or nil, code: the code is
-- "use_on: target mode did not arm" when the arm never showed, and then the target action was
-- NOT queued. Ground items, players and tiles have no helper: the agent has not documented
-- their packing.

local Target = {}

Target.SELECT_COMPONENT      = 25
Target.SELECT_COMPONENT_ITEM = 58
Target.SELECT_NPC            = 8
Target.SELECT_OBJECT         = 2

Target.BACKPACK_IFACE = 1473
Target.BACKPACK_COMP  = 5

-- A component, or one dynamic child (sub) of it. sub defaults to -1 (none).
function Target.ref(iface, comp, sub)
  return { iface = iface, comp = comp, sub = sub or -1 }
end

-- Backpack slot `slot` (0-based), as a source or a target.
function Target.backpack(slot)
  if math.type(slot) ~= "integer" or slot < 0 then
    error("botwithus: backpack slot must be an integer >= 0, got " .. tostring(slot), 2)
  end
  return Target.ref(Target.BACKPACK_IFACE, Target.BACKPACK_COMP, slot)
end

return Target
