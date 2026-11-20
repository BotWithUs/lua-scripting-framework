-- botwithus.components -- interface component reads, over the agent's existing RPCs.
--
--   local c = game:component(1477, 25)            -- one component of the HUD
--   if c and c.visible_global then ... end
--   local ops = game:component_ops(1473, 5, 0)    -- { mask =, ops = { {op, name, transmits} } }
--
-- These go through bwu.rpc_raw, one round trip each, so read them when you need them, not every
-- tick. Each returns the agent's reply as Lua tables, or nil, code when the agent refuses or does
-- not answer in time ("rpc timeout").
--
-- A component map (NXTLibrary PUBLIC_PROTOCOL.md 6.7.1) carries iface, comp, sub, type (raw and
-- build-specific: prefer category), category, x, y, w, h, text, hidden, sprite_id, item_id,
-- item_amount, triggers ({ {type, script_id} }), visible (its own flag), visible_global (it and
-- every parent: what "on screen" means), slot_flags, parent_global, scrollable and the scroll
-- fields. get_component answers iface -1 for a component that does not exist: :component returns
-- nil for that, so `if c then` is the test.

local Components = {}

-- (iface << 16) | comp, the packed id parent_global and the client use.
function Components.pack(iface, comp) return (iface << 16) | comp end

-- The iface and comp of a packed id.
function Components.unpack(packed) return packed >> 16, packed & 0xFFFF end

-- A component map, or nil for "not found"; nil, code passes a refusal through.
local function found(reply, code)
  if reply == nil then return nil, code end
  if reply.iface == -1 then return nil end
  return reply
end

-- The component at iface:comp, or nil when it does not exist. (For one slot of an item container,
-- the slot is a sub: read the container and its dynamic children, or use :component_ops with sub.)
function Components.get(rpc, iface, comp)
  return found(rpc("get_component", { iface = iface, comp = comp }))
end

-- Several in one round trip: `targets` is { {iface, comp}, ... } (the agent caps it at 64).
-- Returns the list of maps in order; a missing one has iface -1 there.
function Components.get_many(rpc, targets)
  local reply, code = rpc("get_components", { targets = targets })
  if reply == nil then return nil, code end
  return reply.components or {}
end

-- The right-click ops: { mask =, ops = { {op =, name =, transmits =}, ... } }. op is the number
-- the COMPONENT action takes as param1. An op can be listed with transmits false: it then runs
-- only client-side script. A component that is not open is nil, "get_component_ops: not_found".
function Components.ops(rpc, iface, comp, sub)
  return rpc("get_component_ops", { iface = iface, comp = comp, sub = sub or -1 })
end

-- The ids of the children baked into the cache layout.
function Components.static_children(rpc, iface, comp)
  local reply, code = rpc("get_static_children", { iface = iface, comp = comp })
  if reply == nil then return nil, code end
  return reply.children or {}
end

-- The ids of the children created at run time.
function Components.dynamic_children(rpc, iface, comp)
  local reply, code = rpc("get_dynamic_children", { iface = iface, comp = comp })
  if reply == nil then return nil, code end
  return reply.children or {}
end

-- The whole subtree in one call: { count =, nodes = { map + parent, ... } }. A node's parent is
-- the 0-based index of its parent in `nodes`, -1 for the root (add 1 to index the Lua list).
function Components.tree(rpc, iface, comp)
  return rpc("get_interface_tree", { iface = iface, comp = comp })
end

-- The most specific on-screen component under screen point (x, y), or nil.
function Components.at(rpc, x, y)
  return found(rpc("find_component_at", { x = x, y = y }))
end

return Components
