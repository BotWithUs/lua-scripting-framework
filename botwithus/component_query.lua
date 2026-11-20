-- botwithus.component_query -- queries over an interface's live component tree, and a
-- component's own menu ops and option clicks (the Java host's ComponentQuery and ComponentNode
-- ops / options / hasOption / interact).
--
--   local CQ = require("botwithus.component_query")
--   local button = CQ.new(game, 11):with_option("Deposit Carried Items"):first()
--   if button then CQ.interact(game, button, "Deposit Carried Items") end
--   local logs = CQ.new(game, 1622):with_item_name("logs"):with_item_amount(5, 28):all()
--
-- A query reads the tree once (get_interface_tree on (iface, comp), comp 0 by default: the whole
-- interface) at its first terminal and keeps it, and keeps each node's ops and each item's
-- definition, so a chain of filters costs one round trip per node at most. A node is the
-- component map the agent sends (iface, comp, sub, category, text, sprite_id, item_id,
-- item_amount, triggers, visible_global, ...) plus `parent`, the 0-based index of its parent.
--
-- Options come from the client's live menu (get_component_ops), matched ignoring case, and a
-- click sends the op the client lists under that name with the node's own sub id. An interface
-- that is not open has no tree: every terminal then reads empty.

local Actions = require("botwithus.actions")
local Definitions = require("botwithus.definitions")

local CQ = {}
CQ.__index = CQ

-- Component categories (the node's `category`), as the Java host's ComponentType numbers them.
CQ.LAYER, CQ.BOX, CQ.TEXT, CQ.SPRITE, CQ.MODEL, CQ.BUTTON = 1, 2, 3, 4, 5, 6
local NO_ITEM = -1
local DEFAULT_OP = 1
local MAX_OP = 10

-- Node ops -------------------------------------------------------------------------------------

-- { mask, ops = { {op, name, transmits}, ... } } for a node, or an empty set when the agent
-- refuses (the component is not open).
function CQ.ops(game, node)
  local reply = game:component_ops(node.iface, node.comp, node.sub)
  if type(reply) ~= "table" then return { mask = 0, ops = {} } end
  return { mask = reply.mask or 0, ops = reply.ops or {} }
end

-- The op listed as `name` (ignoring case) in an ops set, or nil.
function CQ.op_named(ops, name)
  if name == nil then return nil end
  for _, o in ipairs(ops.ops) do
    if o.name:lower() == name:lower() then return o.op end
  end
  return nil
end

-- Whether op `op` (1..10) transmits to the server (its mask bit).
function CQ.is_transmitting(ops, op)
  if op < 1 or op > MAX_OP then return false end
  return (ops.mask & (1 << op)) ~= 0
end

-- A node's option names, in menu order.
function CQ.options(game, node)
  local out = {}
  for i, o in ipairs(CQ.ops(game, node).ops) do out[i] = o.name end
  return out
end

function CQ.has_option(game, node, option)
  return CQ.op_named(CQ.ops(game, node), option) ~= nil
end

-- Click `option` on a node, with its own sub id. False (nothing sent) when its menu lists no
-- such option.
function CQ.interact(game, node, option)
  local op = CQ.op_named(CQ.ops(game, node), option)
  if op == nil then return false end
  game:do_action(Actions.component_click(node.iface, node.comp, op, node.sub))
  return true
end

-- The query ------------------------------------------------------------------------------------

-- A query over the subtree at (iface, comp); comp 0 (the default) is the whole interface.
function CQ.new(game, iface, comp)
  return setmetatable({ _game = game, _iface = iface, _comp = comp or 0, _preds = {},
                        _limit = math.huge, _ops = {}, _items = {} }, CQ)
end

-- Add a predicate. Unlike entity queries, a component query is built up in place, as the Java
-- host's is: it keeps its tree and its ops between terminals.
function CQ:filter(pred)
  self._preds[#self._preds + 1] = pred
  return self
end

-- The tree: { count, nodes } as get_interface_tree sends it, read once.
function CQ:tree()
  if self._tree == nil then
    local reply = self._game:interface_tree(self._iface, self._comp)
    self._tree = type(reply) == "table" and reply or { count = 0, nodes = {} }
    self._tree.nodes = self._tree.nodes or {}
  end
  return self._tree
end

function CQ:_ops_of(node)
  local key = node.iface .. ":" .. node.comp .. ":" .. tostring(node.sub)
  local ops = self._ops[key]
  if ops == nil then
    ops = CQ.ops(self._game, node)
    self._ops[key] = ops
  end
  return ops
end

function CQ:_item_of(node)
  local id = node.item_id
  if id == nil or id == NO_ITEM then return nil end
  local hit = self._items[id]
  if hit == nil then
    local ok, def = pcall(Definitions.item, id)
    hit = ok and def or false
    self._items[id] = hit
  end
  return hit or nil
end

function CQ:with_id(comp) return self:filter(function(n) return n.comp == comp end) end
function CQ:of_category(...)
  local set = {}
  for _, c in ipairs({ ... }) do set[c] = true end
  return self:filter(function(n) return set[n.category] == true end)
end
CQ.with_type = CQ.of_category

-- Text equal to `text`, ignoring case.
function CQ:with_text(text)
  return self:filter(function(n) return (n.text or ""):lower() == text:lower() end)
end
function CQ:containing_text(needle)
  local lower = needle:lower()
  return self:filter(function(n) return (n.text or ""):lower():find(lower, 1, true) ~= nil end)
end
-- Text matching the Lua pattern as a whole.
function CQ:text_matching(pattern)
  local p = "^" .. pattern:gsub("^%^", ""):gsub("%$$", "") .. "$"
  return self:filter(function(n) return (n.text or ""):find(p) ~= nil end)
end
function CQ:with_sprite_id(id) return self:filter(function(n) return n.sprite_id == id end) end
function CQ:with_item_id(id) return self:filter(function(n) return n.item_id == id end) end

-- Nodes whose live menu lists any of `...`.
function CQ:with_option(...)
  local options = { ... }
  if #options == 0 then return self:filter(function() return false end) end
  return self:filter(function(n)
    local ops = self:_ops_of(n)
    for _, o in ipairs(options) do
      if CQ.op_named(ops, o) then return true end
    end
    return false
  end)
end

-- Nodes whose op 1 transmits (the Java host's "has a default option").
function CQ:has_default_option()
  return self:filter(function(n) return CQ.is_transmitting(self:_ops_of(n), DEFAULT_OP) end)
end

-- Nodes holding an item whose name contains `name` (ignoring case), or, with `is_pattern`,
-- whose name the Lua pattern finds.
function CQ:with_item_name(name, is_pattern)
  local needle = is_pattern and name or name:lower()
  return self:filter(function(n)
    local def = self:_item_of(n)
    if def == nil or def.name == nil then return false end
    if is_pattern then return def.name:find(needle) ~= nil end
    return def.name:lower():find(needle, 1, true) ~= nil
  end)
end

function CQ:with_item_category(category)
  return self:filter(function(n)
    local def = self:_item_of(n)
    return def ~= nil and def.category == category
  end)
end

function CQ:with_item_amount(min, max)
  return self:filter(function(n)
    return n.item_id ~= nil and n.item_id ~= NO_ITEM and n.item_amount >= min and n.item_amount <= max
  end)
end

-- On screen (the node and every parent visible), or not.
function CQ:visible() return self:filter(function(n) return n.visible_global == true end) end
function CQ:hidden() return self:filter(function(n) return n.visible_global ~= true end) end

function CQ:limit(max)
  self._limit = math.max(0, max)
  return self
end

-- Terminals.
function CQ:all()
  local out = {}
  for _, n in ipairs(self:tree().nodes) do
    if #out >= self._limit then break end
    local keep = true
    for _, p in ipairs(self._preds) do
      if not p(n) then keep = false; break end
    end
    if keep then out[#out + 1] = n end
  end
  return out
end

function CQ:first() return self:all()[1] end
function CQ:count() return #self:all() end
function CQ:exists() return self:first() ~= nil end

-- Tree navigation: the 1-based list index of `node` in the tree, its children and descendants.
function CQ:children(node)
  local nodes, out, index = self:tree().nodes, {}, nil
  for i, n in ipairs(nodes) do
    if n == node then index = i - 1 end
  end
  if index == nil then return out end
  for _, n in ipairs(nodes) do
    if n.parent == index then out[#out + 1] = n end
  end
  return out
end

function CQ:descendants(node)
  local out = {}
  for _, child in ipairs(self:children(node)) do
    out[#out + 1] = child
    for _, d in ipairs(self:descendants(child)) do out[#out + 1] = d end
  end
  return out
end

-- The node at (iface, comp) with no sub (or sub -1), or nil.
function CQ:node(iface, comp)
  for _, n in ipairs(self:tree().nodes) do
    if n.iface == iface and n.comp == comp and (n.sub == nil or n.sub < 0) then return n end
  end
  return nil
end

return CQ
