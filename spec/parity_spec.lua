-- spec/parity_spec.lua -- the host ABI 5 reads: inventories, skills, ground items, projectiles,
-- session state, component reads and the raw escape hatches, over the fake bwu surface.
--
-- Every expected value differs from a zeroed default, so a facade that reads nothing, or the
-- wrong field, fails.

local fake_bwu = require("spec.fake_bwu")
local bot      = require("botwithus")

local T = {}

local function attach(opts)
  _G.bwu = fake_bwu.new(opts)
  return bot.Game.attach(4242)
end

-- Inventories ---------------------------------------------------------------------------------

T["backpack: count sums stacks, contains / find match an id, a list or a predicate"] = function(assert_)
  local bp = attach():backpack()
  assert_(bp:is_present() and bp:id() == 93 and bp:size() == 4, "93, four slots")
  assert_(bp:count(1511) == 2, "two logs across two slots: " .. bp:count(1511))
  assert_(bp:count(995) == 1000, "a stack counts its quantity")
  assert_(bp:contains(1511) and not bp:contains(4151), "contains")
  assert_(bp:find(995).slot == 1, "find gives the slot row, 0-based")
  assert_(bp:find({ 4151, 995 }).item_id == 995, "a list of ids matches any")
  assert_(#bp:find_all(function(r) return r.quantity == 1 end) == 2, "a predicate")
  assert_(bp:count({ 1511, 995 }) == 1002, "count over a list")
end

T["backpack: empty slots are not items, free_slots counts them"] = function(assert_)
  local bp = attach():backpack()
  assert_(#bp:items() == 3 and bp:free_slots() == 1, "three items, one free")
  assert_(not bp:is_empty() and not bp:is_full(), "neither empty nor full")
  assert_(bp:slot(3).item_id == -1 and bp:slot(0).item_id == 1511, "slot() is 0-based")
end

T["a bank that is not published is absent, not empty"] = function(assert_)
  local bank = attach():bank()
  assert_(not bank:is_present(), "not published")
  assert_(not bank:is_empty() and not bank:is_full(), "absent says neither")
  assert_(bank:count(995) == 0 and bank:find(995) == nil and bank:size() == 0, "reads are empty")
end

T["equipment and the inventory list"] = function(assert_)
  local g = attach()
  assert_(g:equipment():contains(1351), "the worn axe")
  local list = g:inventories()
  assert_(#list == 2 and list[1].inv_id == 93 and list[1].slot_count == 4, "listed")
end

T["an inventory matcher that is not an id, list or function raises"] = function(assert_)
  local bp = attach():backpack()
  local ok, err = pcall(bp.contains, bp, "logs")
  assert_(not ok and tostring(err):find("matcher", 1, true), tostring(err))
end

-- Skills --------------------------------------------------------------------------------------

T["skills carry names; skill() takes an id or a name in any case"] = function(assert_)
  local g = attach()
  local rows = g:skills()
  assert_(#rows == 2 and rows[1].name == "woodcutting" and rows[2].name == "mining", "named")
  local wc = g:skill("Woodcutting")
  assert_(wc and wc.level == 72 and wc.boosted_level == 70 and wc.xp == 1234567, "by name")
  assert_(g:skill(bot.Skills.MINING).boosted_level == 52, "by id")
  assert_(g:skill("attack") == nil, "a skill the player has no row for")
  local ok = pcall(g.skill, g, "sailing")
  assert_(not ok, "an unknown name raises")
  assert_(bot.Skills.NECROMANCY == 28 and bot.Skills.name(0) == "attack", "the table")
end

-- Ground items and projectiles ------------------------------------------------------------------

T["ground items are Tiles, and the query matches item ids"] = function(assert_)
  local g = attach()
  local rows = g:ground_items()
  assert_(#rows == 2 and rows[1].tile:distance({ x = 3200, y = 3200, plane = 0 }) == 2, "a Tile")
  local coins = bot.ground_items(g):of_type(995):first()
  assert_(coins and coins.quantity == 50, "query by item id")
  local near = bot.ground_items(g):nearest(g:self().tile)
  assert_(near.item_id == 526, "the nearest stack")
end

T["projectiles carry Tile endpoints and game-cycle stamps"] = function(assert_)
  local p = attach():projectiles()[1]
  assert_(p.projectile_id == 1234 and p.start_cycle == 5000 and p.end_cycle == 5060, "fields")
  assert_(p.source_index == 55 and p.target_index == 1000 and p.target_type == 0, "ends")
  assert_(p.end_tile:distance(p.start_tile) == 1, "Tiles")
end

-- Session -------------------------------------------------------------------------------------

T["game state, login state, world and account info"] = function(assert_)
  local g = attach()
  local s = g:game_state()
  assert_(s.game_state == bot.Game.STATE_IN_GAME and s.root_iface_id == 1477, "game state")
  assert_(s.scene_version == 42 and g:is_logged_in(), "scene version, logged in")
  local l = g:login_state()
  assert_(l.state == 30 and l.login_progress == 7 and l.login_status == 2, "login state")
  assert_(g:current_world() == 84, "world")
  local a = g:account_info()
  assert_(a.display_name == "Me" and a.account_name == "acct" and a.is_member, "account")
end

T["is_logged_in needs a player, not only state 30"] = function(assert_)
  local g = attach({ game_state = { game_state = 30, root_iface_id = -1, own_index = -1,
                                    scene_version = 0 } })
  assert_(not g:is_logged_in(), "state 30 with no player is not logged in")
end

T["a session read the agent refuses returns nil, code"] = function(assert_)
  local g = attach({ world = "rpc_timeout", login_state = "unknown_method" })
  local w, code = g:current_world()
  assert_(w == nil and code == "rpc_timeout", tostring(code))
  local l, why = g:login_state()
  assert_(l == nil and why == "unknown_method", tostring(why))
end

-- Self / NPC / player extras pass through -----------------------------------------------------

T["the ABI 5 self, NPC and player fields reach the script"] = function(assert_)
  local g = attach({
    self_ = { valid = true, tile = { x = 3200, y = 3200, plane = 0 }, server_index = 1000,
              orientation = 0, is_member = true, target_index = 55, target_type = 1,
              moving = true, stance_id = 1427, spot_anim_id = 2149, following_index = -1 },
    npcs_ = { { server_index = 55, type_id = 1, tile = { x = 3201, y = 3200, plane = 0 },
                orientation = 0, hp = 4321, max_hp = 5000, moving = true, spot_anim_id = 2148 } },
  })
  local me = g:self()
  assert_(me.is_member and me.target_index == 55 and me.moving and me.stance_id == 1427, "self")
  local n = g:npcs()[1]
  assert_(n.hp == 4321 and n.max_hp == 5000 and n.moving and n.spot_anim_id == 2148, "npc")
end

-- Components and the raw escape hatches -------------------------------------------------------

local COMPONENT = { iface = 1473, comp = 5, sub = -1, text = "Logs", x = 100, visible_global = true }

local function component_rpc()
  return {
    get_component = function(p)
      if p.iface == 1473 and p.comp == 5 then return COMPONENT end
      return { iface = -1 }
    end,
    get_component_ops = function(p)
      if p.iface ~= 1473 then return nil, "get_component_ops: not_found" end
      return { mask = 0x102, ops = { { op = 1, name = "Craft", transmits = true } }, sub = p.sub }
    end,
    get_static_children = function() return { children = { 1, 2, 3 } } end,
    get_dynamic_children = function() return { children = { 0 } } end,
    get_interface_tree = function() return { count = 1, nodes = { { iface = 1473, parent = -1 } } } end,
    find_component_at = function(p) return p.x == 110 and COMPONENT or { iface = -1 } end,
    get_components = function(p) return { components = { COMPONENT, { iface = -1 } }, n = #p.targets } end,
  }
end

T["component reads go through rpc_raw with the agent's param names"] = function(assert_)
  local g = attach({ rpc = component_rpc() })
  local c = g:component(1473, 5)
  assert_(c and c.text == "Logs" and c.x == 100, "the map")
  assert_(g:component(1, 1) == nil, "iface -1 is nil: not found")
  local calls = _G.bwu._abi5.rpc_calls
  assert_(calls[1].method == "get_component" and calls[1].params.iface == 1473
    and calls[1].params.comp == 5 and calls[1].params.sub == nil, "iface/comp only")
  local ops = g:component_ops(1473, 5)
  assert_(ops.mask == 0x102 and ops.ops[1].name == "Craft" and ops.sub == -1, "sub defaults to -1")
  local none, code = g:component_ops(9, 9, 0)
  assert_(none == nil and code == "get_component_ops: not_found", tostring(code))
end

T["children, tree, component_at and components"] = function(assert_)
  local g = attach({ rpc = component_rpc() })
  assert_(table.concat(g:static_children(1473, 5), ",") == "1,2,3", "static")
  assert_(table.concat(g:dynamic_children(1473, 5), ",") == "0", "dynamic")
  assert_(g:interface_tree(1473, 0).nodes[1].parent == -1, "tree")
  assert_(g:component_at(110, 210).comp == 5 and g:component_at(1, 1) == nil, "at")
  local many = g:components({ { 1473, 5 }, { 1, 1 } })
  assert_(#many == 2 and many[1].text == "Logs" and many[2].iface == -1, "many, in order")
  assert_(bot.Components.pack(1473, 5) == 96534533 and select(2, bot.Components.unpack(96534533)) == 5,
    "pack / unpack")
end

T["rpc_raw and snapshot_bytes reach the surface"] = function(assert_)
  local g = attach({ rpc = { ["rpc.ping"] = function() return { pong = true } end } })
  assert_(g:rpc_raw("rpc.ping").pong == true, "a reply")
  local r, code = g:rpc_raw("nope", { a = 1 })
  assert_(r == nil and code == "unknown_method", "a refusal")
  local state, own, root = string.unpack("<i4i4i4", g:snapshot_bytes(), 9)
  assert_(state == 30 and own == 1000 and root == 1477, "raw bytes")
end

T["an ABI 4 host raises naming the ABI the read needs"] = function(assert_)
  local g = attach({ abi = 4 })
  assert_(not g:has_abi5_reads(), "feature detection")
  for _, read in ipairs({ "backpack", "skills", "ground_items", "projectiles", "game_state",
                          "login_state", "account_info", "snapshot_bytes" }) do
    local ok, err = pcall(g[read], g)
    assert_(not ok and tostring(err):find("needs host ABI 5, it has ABI 4", 1, true),
      read .. ": " .. tostring(err))
  end
  local ok, err = pcall(g.component, g, 1473, 5)
  assert_(not ok and tostring(err):find("rpc_raw", 1, true), tostring(err))
end

return T
