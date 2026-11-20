-- spec/client_reads_spec.lua -- the host ABI 6 calls: GE offers, the world list and hop, target
-- mode and use-on, world_to_screen, children with sub ids and CS2 scripts, over the fake bwu
-- surface (spec/fake_bwu.lua install_abi6).
--
-- Every expected value differs from a zeroed default, so a facade that reads nothing, decodes the
-- wrong bit, or sends the wrong argument fails. Each test names the result that would fail it.

local fake_bwu = require("spec.fake_bwu")
local bot      = require("botwithus")

local T = {}

local function attach(opts)
  _G.bwu = fake_bwu.new(opts)
  return bot.Game.attach(4242)
end

local function calls() return _G.bwu._abi6.calls end

-- GE ------------------------------------------------------------------------------------------

-- Failure: in_use true on an empty slot, or the 64-bit price lost.
T["ge_offers: eight slots, in_use is stage ~= 0, prices past 32 bits"] = function(assert_)
  local offers = attach():ge_offers()
  assert_(#offers == 8, "eight slots: " .. #offers)
  local used = bot.GrandExchange.in_use(offers)
  assert_(#used == 1 and used[1].slot == 2 and used[1].is_sell, "slot 2 sells")
  assert_(used[1].price == 5000000000 and used[1].gold_from_sale == 600000000000, "64-bit")
  assert_(offers[1].in_use == false and offers[1].stage_name == "empty", "slot 0 empty")
end

T["ge_offers: a refusal is nil, code"] = function(assert_)
  local r, code = attach({ ge_offers = "not_available" }):ge_offers()
  assert_(r == nil and code == "not_available", tostring(code))
end

-- Worlds --------------------------------------------------------------------------------------

-- Failure: a flag bit decoded from the wrong mask, or is_fetched true on an empty list.
T["world_list: the four flags decode, find() by id"] = function(assert_)
  local list = attach():world_list()
  assert_(list.is_fetched and #list.worlds == 2, "two worlds")
  local w1 = bot.Worlds.find(list, 1)
  assert_(w1.members and w1.skill_total and not w1.classic_only and not w1.eoc_only, "world 1 flags")
  local w2 = bot.Worlds.find(list, 2)
  assert_(w2.classic_only and not w2.members, "world 2 flags")
  assert_(bot.Worlds.find(list, 3) == nil, "no world 3")
end

T["world_list: an empty list is not fetched, not an error"] = function(assert_)
  local list = attach({ world_list = { count = 0, total = 0, skipped = 0, truncated = false,
                                       worlds = {} } }):world_list()
  assert_(list ~= nil and list.is_fetched == false, "empty")
end

-- Hop ----------------------------------------------------------------------------------------

-- Failure: the default timeout not passed, or a refusal raised instead of returned.
T["hop_world: passes the id and a 30 s default, arrival is the table"] = function(assert_)
  local g = attach()
  local r = g:hop_world(2)
  assert_(r and r.world_id == 2 and r.game_state == 30, "arrived")
  local c = calls()[#calls()]
  assert_(c[1] == "hop_world" and c[2] == 2 and c[3] == 30000, "id and default timeout")
  g:hop_world(2, 5000)
  assert_(calls()[#calls()][3] == 5000, "explicit timeout")
end

T["hop_world: a refusal is nil, code, detail"] = function(assert_)
  local r, code, detail = attach({ hop = "members_world" }):hop_world(84)
  assert_(r == nil and code == "members_world" and detail.started == false, tostring(code))
end

T["set_world: started false with the reason"] = function(assert_)
  local s = attach():set_world(999)
  assert_(s.started == false and s.reason == "unknown_world", "refused")
end

-- Use-on --------------------------------------------------------------------------------------

-- Failure: a backpack slot sent as the wrong iface / comp, or the sub dropped.
T["use_item_on_item: two backpack refs, slot as sub"] = function(assert_)
  local g = attach()
  assert_(g:use_item_on_item(0, 3) == true, "queued")
  local c = calls()[#calls()]
  assert_(c[1] == "use_on_component", c[1])
  assert_(c[2].iface == 1473 and c[2].comp == 5 and c[2].sub == 0, "source slot 0")
  assert_(c[3].iface == 1473 and c[3].comp == 5 and c[3].sub == 3, "target slot 3")
end

T["use_item_on_npc / use_item_on_object pass their targets"] = function(assert_)
  local g = attach()
  g:use_item_on_npc(1, 30)
  local c = calls()[#calls()]
  assert_(c[1] == "use_on_npc" and c[2].sub == 1 and c[3] == 30, "npc")
  g:use_item_on_object(2, 1278, 3200, 3201)
  c = calls()[#calls()]
  assert_(c[1] == "use_on_object" and c[2].sub == 2 and c[3] == 1278 and c[4] == 3200 and c[5] == 3201, "object")
end

T["a backpack slot that is not an integer >= 0 raises before sending"] = function(assert_)
  local g = attach()
  local ok = pcall(g.use_item_on_item, g, -1, 3)
  assert_(not ok and #calls() == 0, "raised, nothing sent")
end

T["Target.ref defaults sub to -1"] = function(assert_)
  local r = bot.Target.ref(1430, 12)
  assert_(r.iface == 1430 and r.comp == 12 and r.sub == -1, "ref")
end

T["target_mode passes the host's table through"] = function(assert_)
  local m = attach({ target_mode = { active = true, is_item = true, obj_id = 946,
    source = { iface = 1473, comp = 5, sub = 0 }, verb = "Use", name = "Knife", target_mask = 31 } }):target_mode()
  assert_(m.active and m.obj_id == 946 and m.source.sub == 0, "armed")
end

-- Projection ----------------------------------------------------------------------------------

-- Failure: a Tile's plane dropped, or a plain {x, y} given a plane (the fake answers wrong_plane).
T["world_to_screen: a plain tile keeps no plane, a Tile keeps its own"] = function(assert_)
  local g = attach()
  local r = g:world_to_screen({ { x = 3200, y = 3201 }, bot.Tile.new(3200, 3201, 1) })
  local sent = calls()[#calls()][2]
  assert_(sent[1].plane == nil and sent[2].plane == 1, "planes as given")
  assert_(r.points[1].on_screen and r.points[1].x == 641, "ok point")
  assert_(r.points[2].result == "wrong_plane", "other plane")
  assert_(r.viewport.width == 1264, "viewport")
end

-- Children ------------------------------------------------------------------------------------

-- Failure: the flat count-only read used (no sub), or the native function not called.
T["dynamic_children_with_sub: {comp, sub} rows from the native read"] = function(assert_)
  local kids = attach():dynamic_children_with_sub(1473, 5)
  assert_(#kids == 2 and kids[2].comp == 5 and kids[2].sub == 1, "subs")
  local c = calls()[#calls()]
  assert_(c[1] == "dynamic_children" and c[2] == 1473 and c[3] == 5, "native call")
end

T["static_children_with_sub"] = function(assert_)
  local kids = attach():static_children_with_sub(1473, 5)
  assert_(kids[1].comp == 6 and kids[1].sub == -1, "static")
end

-- Scripts -------------------------------------------------------------------------------------

-- Failure: string args not passed through, or passed in the int position.
T["execute_script passes int args, string args and returns in order"] = function(assert_)
  local g = attach()
  local h = g:script_handle(4321)
  assert_(h == 0x100000001, "handle")
  local r = g:execute_script(h, { 7, 35 }, { "abc", "x" }, { "int" })
  assert_(r[1] == 42, "returns")
  local c = calls()[#calls()]
  assert_(c[1] == "execute_script" and c[2] == h, "handle")
  assert_(c[3][2] == 35 and c[4][1] == "abc" and c[4][2] == "x" and c[5][1] == "int", "args in place")
  assert_(g:destroy_script_handle(h) == true, "destroy")
end

-- Older host ----------------------------------------------------------------------------------

T["on an ABI 5 host the ABI 6 calls raise naming the ABI"] = function(assert_)
  local g = attach({ abi = 5 })
  assert_(g:has_abi6_calls() == false, "no ABI 6")
  local ok, err = pcall(g.world_list, g)
  assert_(not ok and tostring(err):find("ABI 6", 1, true), tostring(err))
end

return T
