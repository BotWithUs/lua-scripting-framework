-- spec/actions_spec.lua -- the action builders send exactly the agent's param shapes.
--
-- Component (57): p1 = option 1..10, p2 = sub-slot (-1 none), p3 = (iface << 16) | comp.
-- Dialogue (30):  p1 = 0, p2 = -1, p3 = (iface << 16) | comp.
-- The same shapes the Python framework's component_click / dialogue_option build.

local fake_bwu = require("spec.fake_bwu")
local bot      = require("botwithus")
local Actions  = require("botwithus.actions")

local T = {}

local function same(a, id, p1, p2, p3)
  return a.id == id and a.p1 == p1 and a.p2 == p2 and a.p3 == p3
end

local function show(a)
  return ("{%s, %s, %s, %s}"):format(tostring(a.id), tostring(a.p1), tostring(a.p2), tostring(a.p3))
end

T["action ids are the agent's"] = function(assert_)
  assert_(Actions.COMPONENT == 57, "Component is 57")
  assert_(Actions.DIALOGUE == 30, "Dialogue is 30")
  assert_(Actions.COMPONENT_CLICK == 57, "the old name is the same id")
  assert_(Actions.DIALOGUE_OPTION == 30, "the old name is no longer 43")
end

-- ESCAPE_MENU__LOGOUT_LOBBY, 1433:69: option 1 on it is the agent's own exit_to_lobby click.
T["component_click packs option, no sub-slot, iface<<16|comp"] = function(assert_)
  local a = Actions.component_click(1433, 69)
  assert_(same(a, 57, 1, -1, 93913157), "1433:69 option 1: " .. show(a))
end

T["component_click passes option and sub-slot through"] = function(assert_)
  local a = Actions.component_click(1473, 5, 2, 7)
  assert_(same(a, 57, 2, 7, 96534533), "backpack 1473:5 slot 7 option 2: " .. show(a))
end

T["dialogue_option packs 0, -1, iface<<16|comp"] = function(assert_)
  local a = Actions.dialogue_option(1188, 8)
  assert_(same(a, 30, 0, -1, 77856776), "1188:8: " .. show(a))
end

T["dialogue_option refuses the old (index) form"] = function(assert_)
  local ok, err = pcall(Actions.dialogue_option, 2)
  assert_(not ok and tostring(err):find("interface_id, component_id", 1, true), tostring(err))
end

T["a built component click reaches queue_action unchanged"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local g = bot.Game.attach()
  g:do_action(Actions.component_click(1433, 69))
  local sent = _G.bwu._state.actions[1]
  assert_(same(sent, 57, 1, -1, 93913157), "sent " .. show(sent))
end

return T
