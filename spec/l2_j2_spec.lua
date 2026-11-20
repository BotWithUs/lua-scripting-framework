-- spec/l2_j2_spec.lua -- the Java host's J2 composition APIs, ported: the action bar and its
-- cooldown join, prayers, local combat state, hitmark history, derived inventory / skill change
-- events, summoning and the lodestone network. Over the fake bwu surface, with the real ids
-- (Backhand struct 14682, the prayer varbits, BOB inventory 530). Each test names what would
-- count as a failure.

local S = require("spec.l2_support")
local ActionBar = require("botwithus.actionbar")
local Prayers = require("botwithus.prayers")
local Combat = require("botwithus.combat")
local Changes = require("botwithus.changes")
local Summoning = require("botwithus.summoning")
local Lodestones = require("botwithus.lodestones")
local Timing = require("botwithus.timing")
local Events = require("botwithus.events")

local T = {}

-- Action bar ------------------------------------------------------------------------------------

-- Bar 3: slot 1 Backhand (type 6, id 5), slot 2 an item (Logs), slot 3 empty, slot 4 an ability
-- id the style's enum does not list.
local BAR3_TYPE = { 1795, 1797, 1799, 1801 }
local BAR3_ID = { 1796, 1798, 1800, 1802 }
local BAR3_OBJ2 = 848

local function bar_opts(extra)
  local varbits = { [1893] = 3, [BAR3_TYPE[1]] = 6, [BAR3_ID[1]] = 5, [BAR3_TYPE[2]] = 6,
                    [BAR3_ID[2]] = 5, [BAR3_TYPE[4]] = 6, [BAR3_ID[4]] = 99 }
  local opts = {
    var_reads = S.vars({ [BAR3_OBJ2] = 1511 }, varbits),
    varcs = { [2091] = 17764, [2092] = 17854 },
    cache_json = {
      ["3:13199"] = '{"entries":{"6":6740,"11":13200},"entryCount":2,"id":13199}',
      ["3:6740"] = '{"entries":{"5":14682,"7":14683},"entryCount":2,"id":6740}',
    },
    cache_params = {
      ["4:14682"] = { { param_id = 2793, kind = 0, value = 3 }, { param_id = 2794, kind = 1, text = "Backhand" },
                      { param_id = 2796, kind = 0, value = 25 } },
      ["4:14683"] = { { param_id = 2793, kind = 0, value = 4 }, { param_id = 2794, kind = 1, text = "Barge" },
                      { param_id = 2796, kind = 0, value = 34 }, { param_id = 9405, kind = 0, value = 2 } },
    },
    script_results = {
      [8247] = function(args) return args[1] == 14682 and { 14212 } or { -1 } end,
      [6506] = function(args) return args[1] == 14212 and { 17700, 17950 } or "script_failed" end,
    },
  }
  for k, v in pairs(extra or {}) do opts[k] = v end
  return opts
end

-- Failure: type and id read the wrong way round, an item slot read as an ability, the wrong bar's
-- vars, or a slot pressed through a component other than its GRAPHIC_n layer.
T["j2 actionbar: slots decode from the bar's vars and the cache"] = function(assert_)
  local game = S.attach(bar_opts())
  local bar = ActionBar.new(game)
  assert_(bar:active_bar() == 3, "bar 3")
  local slots = bar:slots()
  assert_(#slots == 14, "14 slots")
  assert_(slots[1].kind == "ability" and slots[1].ability.name == "Backhand"
    and slots[1].ability.struct_id == 14682 and slots[1].ability.cooldown_ticks == 25
    and slots[1].ability.global_cooldown_ticks == 3, "Backhand, default global cooldown 3")
  assert_(slots[2].kind == "item" and slots[2].item_id == 1511, "the item wins over the ability bits")
  assert_(slots[3].kind == "empty", "empty")
  assert_(slots[4].kind == "unresolved" and slots[4].type_code == 6 and slots[4].id == 99, "unresolved")
  assert_(bar:contains_ability("backhand") and not bar:contains_ability("Barge"), "contains")
  assert_(bar:use_ability("Backhand") == true, "use")
  local a = S.actions()[1]
  assert_(a.id == 57 and a.p1 == 1 and a.p2 == -1 and a.p3 == 93716546, "GRAPHIC_1 = 1430:66")
  assert_(bar:use_slot(14) and S.actions()[2].p3 == (1430 << 16 | 235), "slot 14 layer")
  assert_(bar:use_slot(15) == false and bar:use_ability("Barge") == false, "out of range / not held")
  assert_(#bar:slots_of(19) == 0, "bar 19 does not exist")
end

-- Failure: the cooldown joined by name, a failed script reading as ready, or the handle left open.
T["j2 actionbar: cooldowns join through scripts 8247 then 6506"] = function(assert_)
  local game = S.attach(bar_opts())
  local bar = ActionBar.new(game)
  local cd = bar:cooldown("Backhand")
  assert_(cd.known and cd.start_cycle == 17700 and cd.end_cycle == 17950, "the 6506 window")
  assert_(cd:remaining_cycles(17900) == 50 and cd:remaining_ms(17900) == 1000, "cycles x 20 ms")
  assert_(not cd:is_ready(17949) and cd:is_ready(17950), "ready at the end cycle")
  local calls = bwu._abi6.calls
  local seen = {}
  for _, c in ipairs(calls) do seen[#seen + 1] = c[1] .. (c[2] and ("(" .. tostring(c[2]) .. ")") or "") end
  local trail = table.concat(seen, " ")
  assert_(trail:find("script_handle(8247)", 1, true) and trail:find("script_handle(6506)", 1, true), trail)
  local destroys = 0
  for _, c in ipairs(calls) do if c[1] == "destroy_script_handle" then destroys = destroys + 1 end end
  assert_(destroys == 2, "both handles released: " .. destroys)
  local barge = bar:cooldown("Barge")
  assert_(barge == ActionBar.Cooldown.UNKNOWN and not barge:is_ready(99999999), "6506 failed: unknown, not ready")
  assert_(barge:remaining_ms(1) == -1, "unknown remaining")
  assert_(bar:cooldown("Nonexistent") == ActionBar.Cooldown.UNKNOWN, "unknown ability")
  local g = bar:global_cooldown()
  assert_(g.start_cycle == 17764 and g.end_cycle == 17854 and g.end_cycle - g.start_cycle == 90, "global")
  local cat = bar:catalog()
  local b = cat:by_name("BARGE")
  assert_(b and b.global_cooldown_ticks == 2 and b.cooldown_ticks == 34, "catalog by name")
end

-- Prayers ---------------------------------------------------------------------------------------

local function prayer_opts(extra)
  local opts = {
    var_reads = S.vars({}, { [16736] = 455, [16789] = 0, [16747] = 1, [16739] = 0, [5941] = 1 }),
    skills = { { skill_id = 5, xp = 1500, level = 12, boosted_level = 12 } },
    cache_params = {
      ["4:14540"] = { { param_id = 2963, kind = 0, value = 1 }, { param_id = 2964, kind = 0, value = 14541 },
                      { param_id = 2965, kind = 0, value = 10 }, { param_id = 2966, kind = 0, value = 14542 },
                      { param_id = 2967, kind = 0, value = 28 }, { param_id = 2968, kind = 0, value = 14543 } },
      ["4:14541"] = { { param_id = 2794, kind = 1, text = "Thick Skin" }, { param_id = 735, kind = 0, value = 900 },
                      { param_id = 736, kind = 0, value = 901 }, { param_id = 2807, kind = 0, value = 1 } },
      ["4:14542"] = { { param_id = 2794, kind = 1, text = "Rock Skin" }, { param_id = 735, kind = 0, value = 910 },
                      { param_id = 736, kind = 0, value = 911 }, { param_id = 2807, kind = 0, value = 10 },
                      { param_id = 2945, kind = 0, value = 60 }, { param_id = 2809, kind = 0, value = 1 } },
      ["4:14543"] = { { param_id = 2794, kind = 1, text = "Steel Skin" }, { param_id = 735, kind = 0, value = 920 } },
    },
    cache_json = { ["3:13319"] = '{"entries":{"8":0,"23":4},"id":13319}' },
    rpc = { get_interface_tree = function(p)
      if p.iface ~= 1458 or p.comp ~= 40 then return nil, "not_found" end
      return { count = 3, nodes = {
        { iface = 1458, comp = 40, sub = -1, sprite_id = -1, triggers = {}, parent = -1 },
        { iface = 1458, comp = 40, sub = 6, sprite_id = 911, triggers = {}, parent = 0 },
        { iface = 1458, comp = 40, sub = 7, sprite_id = 911, triggers = { { type = 1, script_id = 9 } }, parent = 0 },
      } }
    end },
  }
  for k, v in pairs(extra or {}) do opts[k] = v end
  return opts
end

-- Failure: points not in tenths, the "on" value wrong, the book misread, or the tier not chosen by
-- the Prayer level.
T["j2 prayers: points, book, active prayers and the tier for the level"] = function(assert_)
  local game = S.attach(prayer_opts())
  local p = Prayers.new(game)
  assert_(p:raw_points() == 455 and p:points() == 45 and p:max_points() == 120, "points in tenths")
  assert_(p:active_book() == Prayers.NORMAL, "mode 0 is the normal book")
  assert_(p:is_active("PROTECT_MELEE") and not p:is_active("TIERED_DEFENCE"), "is_active")
  assert_(p:is_any_active("TIERED_DEFENCE", "PROTECT_MELEE"), "any")
  assert_(not p:is_all_active("TIERED_DEFENCE", "PROTECT_MELEE"), "all")
  local on = p:active_prayers()
  assert_(#on == 1 and on[1].key == "PROTECT_MELEE", "active prayers of the book")
  local info = p:info("TIERED_DEFENCE")
  assert_(info.name == "Rock Skin" and info.struct_id == 14542 and info.graphic_off == 911, "level 12: Rock Skin")
  assert_(info.drain_rate == 60 and info.is_members and info.quick_prayer_id == -1, "fields, unknown -1")
  assert_(p:is_quick_prayers_active(), "quick prayers on")
  assert_(#Prayers.of_book(Prayers.CURSES) > 30 and Prayers.ALL.CURSE_SOULSPLIT.varbit == 16779, "table")
  assert_(not pcall(p.is_active, p, "NOT_A_PRAYER"), "an unknown key raises")
end

-- Failure: a toggle sent while the window is closed, the button picked without a trigger, or the
-- ribbon slot taken from the fallback when the cache enum says otherwise.
T["j2 prayers: toggle, open_window and the quick-prayer orb"] = function(assert_)
  local game = S.attach(prayer_opts({ open_ifaces_ = { { id = 1477, type = 1, client_opened = false, is_modal = false } } }))
  local p = Prayers.new(game)
  assert_(p:toggle("TIERED_DEFENCE") == false and #S.actions() == 0, "window closed: nothing sent")
  assert_(p:open_window() == true, "open")
  local a = S.actions()[1]
  assert_(a.p2 == 23 and a.p3 == (1431 << 16), "ribbon slot 23 from RIBBON_WINDOWS, not the fallback 11")
  game = S.attach(prayer_opts({ open_ifaces_ = { { id = 1458, type = 1, client_opened = false, is_modal = false } } }))
  p = Prayers.new(game)
  assert_(p:open_window() == true and #S.actions() == 0, "already open: nothing sent")
  assert_(p:toggle("TIERED_DEFENCE") == true, "toggle")
  a = S.actions()[1]
  assert_(a.id == 57 and a.p1 == 1 and a.p2 == 7 and a.p3 == (1458 << 16 | 40), "the sub with a trigger")
  p:toggle_quick_prayers(); p:open_quick_prayer_selection()
  assert_(S.actions()[2].p1 == 1 and S.actions()[3].p1 == 2 and S.actions()[3].p3 == (1430 << 16 | 18), "orb ops")
end

-- Combat state and hitmarks -----------------------------------------------------------------------

-- Failure: life points from the varp when the row has them, the summoning tenths wrong, the target
-- type mapped wrong, or a hit outside the 6 s window counting as in combat.
T["j2 combat: state, target and is_in_combat"] = function(assert_)
  local self_ = { valid = true, tile = { x = 3200, y = 3200, plane = 0 }, server_index = 1000,
                  combat_level = 126, health = 4200, max_health = 4800, orientation = 0,
                  target_index = 55, target_type = 1 }
  local game = S.attach({ self_ = self_, var_reads = S.vars({ [679] = 650, [13537] = 1, [13538] = 2 },
                                                            { [41524] = 437, [16736] = 990 }) })
  local c = Combat.new(game)
  assert_(c:adrenaline() == 650, "adrenaline")
  assert_(c:life_points() == 4200 and c:max_life_points() == 4800, "the row's health")
  assert_(c:summoning_points() == 43 and c:prayer_points() == 99, "tenths")
  assert_(c:name() == "Me", "own name")
  local t = c:target()
  assert_(t.kind == "npc" and t.npc.server_index == 55, "npc target")
  assert_(c:is_in_combat(), "a target is combat")
  self_.target_index, self_.target_type = 2000, 2
  t = c:target()
  assert_(t.kind == "unresolved" and t.target_index == 2000 and t.target_type == 2, "unresolved player")
  self_.target_type = 127
  assert_(c:target().kind == "none" and not c:is_in_combat(), "127 is never set")
  local now = 100000
  local h = Combat.history(game, { now_ms = function() return now end })
  h:feed({ { name = "hitmark", target_index = 1000, target_type = Events.TARGET_PLAYER, damage = 120,
             cycle = (now - 7000) // 20, hitmark_type = 1 },
           { name = "headbar", target_index = 1000, target_type = 0 } })
  assert_(not c:is_in_combat(h), "a hit 7 s ago is not recent")
  h:record({ name = "hitmark", target_index = 1000, target_type = Events.TARGET_PLAYER, damage = 80,
             cycle = (now - 2000) // 20, hitmark_type = 1 })
  assert_(c:is_in_combat(h), "a hit 2 s ago is")
  assert_(h:damage_within(Events.TARGET_PLAYER, 1000, 30000) == 200, "damage summed")
  assert_(#h:recent(Events.TARGET_NPC, 1000) == 0, "per entity kind")
  self_.health, self_.max_health = -1, 0
  assert_(c:life_points() == 1 and c:max_life_points() == 2, "varps when the row has no health")
end

-- Failure: a change missed or doubled, old and new swapped, the bank's first read flooding, or
-- changes reported while the tick has not moved.
T["j2 changes: inventory and skill changes per server tick"] = function(assert_)
  local game = S.attach()
  local watch = Changes.new(game)
  assert_(#watch:poll() == 0, "the first poll is the baseline")
  local bp = bwu._abi5.inventories[93]
  bp[4] = { item_id = 1511, quantity = 1 }
  bp[2] = { item_id = 995, quantity = 1250 }
  bwu._abi5.inventories[95] = { { item_id = 1521, quantity = 50 } }
  bwu._abi5.skills[1].xp = 1234567 + 380
  assert_(#watch:poll() == 0, "the tick has not moved")
  bwu._state.tick = bwu._state.tick + 1
  local evs = watch:poll()
  local inv, sk = {}, {}
  for _, e in ipairs(evs) do
    if e.name == "inventory_change" then inv[#inv + 1] = e else sk[#sk + 1] = e end
  end
  assert_(#inv == 2, "two backpack slots changed, the new bank is a baseline: " .. #inv)
  assert_(inv[1].slot == 1 and inv[1].old.quantity == 1000 and inv[1].new.quantity == 1250
    and inv[1].quantity_delta == 250 and not inv[1].is_added, "coins +250")
  assert_(inv[2].slot == 3 and inv[2].is_added and inv[2].quantity_delta == 1 and inv[2].old.item_id == -1, "added")
  assert_(inv[1].server_tick == bwu._state.tick, "stamped with the tick")
  assert_(#sk == 1 and sk[1].skill_id == 8 and sk[1].xp_gained == 380 and not sk[1].is_level_up, "xp")
  bp[1] = { item_id = -1, quantity = 0 }
  bwu._state.tick = bwu._state.tick + 1
  evs = watch:poll()
  assert_(#evs == 1 and evs[1].is_removed and evs[1].quantity_delta == -1, "removed")
  bwu._abi5.game_state.game_state = 10
  bwu._state.tick = bwu._state.tick + 1
  assert_(#watch:poll() == 0, "out of the game")
  bwu._abi5.game_state.game_state = 30
  bp[1] = { item_id = 995, quantity = 5 }
  bwu._state.tick = bwu._state.tick + 1
  assert_(#watch:poll() == 0, "the baseline was dropped on leaving the game")
end

-- Summoning ---------------------------------------------------------------------------------------

-- Failure: the familiar from a hand table, the BOB inventory read from 671, or a button sent with
-- no familiar out.
T["j2 summoning: familiar from the pouch params, BOB 530, buttons"] = function(assert_)
  local opts = {
    var_reads = S.vars({ [1831] = 12047, [1787] = 60 }, { [41524] = 655, [6055] = 31, [25412] = 7 }),
    skills = { { skill_id = 23, xp = 5000000, level = 88, boosted_level = 88 } },
    cache_items = { [12047] = S.item(12047, "Spirit wolf pouch") },
    cache_params = { ["0:12047"] = { { param_id = 74, kind = 0, value = 6829 },
                                     { param_id = 394, kind = 0, value = 1 },
                                     { param_id = 396, kind = 0, value = 1 } } },
    inventories = { [530] = { { item_id = 1511, quantity = 3 }, { item_id = -1, quantity = 0 } },
                    [671] = { { item_id = 995, quantity = 9 } } },
  }
  local game = S.attach(opts)
  local s = Summoning.new(game)
  assert_(s:points() == 65 and s:max_points() == 880, "points")
  local f = s:familiar()
  assert_(f.pouch_item_id == 12047 and f.npc_id == 6829 and f.pouch_name == "Spirit wolf pouch"
    and f.level_required == 1, "from the pouch params")
  assert_(s:minutes_remaining() == 31 and s:scrolls_stored() == 7 and s:special_move_points() == 60, "vars")
  assert_(s:beast_of_burden():count(1511) == 3 and s:beast_of_burden():count(995) == 0, "530, not 671")
  assert_(s:call() and S.actions()[1].p3 == (1430 << 16 | 50), "call")
  assert_(s:cast_special() and S.actions()[2].p3 == (662 << 16 | 38), "special")
  opts.var_reads = S.vars({ [1831] = -1 }, {})
  game = S.attach(opts)
  s = Summoning.new(game)
  assert_(not s:has_familiar() and s:familiar() == nil and s:dismiss() == false and #S.actions() == 0, "none")
end

-- Lodestones --------------------------------------------------------------------------------------

-- A fake game around the fake surface for the network: `net_open_after` presses of "Lodestone
-- Network" open it (the first one refused, as right after an arrival); a teleport press moves the
-- player 400 tiles with the landing animation for a while.
local function lodestone_game(open_after, varbits)
  local presses = 0
  local game = S.attach({
    var_reads = S.vars({}, varbits or { [30] = 1, [35] = 1, [10236] = 99 }),
    open_ifaces_ = { { id = 1477, type = 1, client_opened = false, is_modal = false } },
    rpc = { get_component_ops = S.ops_handler({
      ["1465:34:-1"] = { { 1, "Teleport" }, { 2, "Lodestone Network" }, { 3, "Teleport Burthorpe" } } }) },
  })
  local st = bwu._state
  local landing = 0
  local inner = bwu.queue_action
  bwu.queue_action = function(h, id, p1, p2, p3)
    if p3 == (1465 << 16 | 34) and p1 == 2 then
      presses = presses + 1
      if presses >= open_after then
        st.open_ifaces_[#st.open_ifaces_ + 1] = { id = 1092, type = 0, client_opened = false, is_modal = true }
      end
    elseif p3 >> 16 == 1092 or (p3 == (1465 << 16 | 34) and p1 == 3) then
      st.self_.tile = { x = 2899, y = 3545, plane = 0 }
      st.self_.animation_id = 8941
      landing = 3
    end
    return inner(h, id, p1, p2, p3)
  end
  local c = S.clock(function()
    if landing > 0 then
      landing = landing - 1
      if landing == 0 then st.self_.animation_id = -1 end
    end
  end)
  local wait = Timing.new({ now = c.now, sleep = c.sleep, stopping = function() return false end })
  return game, Lodestones.new(game, { wait = wait }), function() return presses end
end

-- Failure: no retry when the first open is refused, the arrival returned before the landing
-- animation ends, a locked lodestone clicked, or Lunar Isle unlocked below its quest value.
T["j2 lodestones: unlocks, teleport with the open retry and the settle wait"] = function(assert_)
  local game, net, presses = lodestone_game(2)
  assert_(net:is_unlocked("BURTHORPE") and net:is_unlocked("LUMBRIDGE"), "unlocked")
  assert_(not net:is_unlocked("LUNAR_ISLE"), "Lunar needs LUNAR_QUEST_MAIN >= 100, it is 99")
  assert_(#net:unlocked() == 2, "two")
  assert_(net:teleport("VARROCK") == Lodestones.LOCKED and #S.actions() == 0, "locked: nothing sent")
  local result = net:teleport("BURTHORPE")
  assert_(result == Lodestones.ARRIVED, "arrived: " .. tostring(result))
  assert_(presses() == 2, "the refused open was retried once")
  local acts = S.actions()
  assert_(acts[#acts].p3 == (1092 << 16 | 12), "the Burthorpe button")
  assert_(game:self().animation_id == -1, "waited for the landing animation to end")
  local _, net2 = lodestone_game(9)
  assert_(net2:teleport("BURTHORPE") == Lodestones.NETWORK_UNAVAILABLE, "two refusals: unavailable")
  local _, net3 = lodestone_game(1)
  assert_(net3:teleport_to_previous() == Lodestones.ARRIVED, "previous via 'Teleport Burthorpe'")
  assert_(Lodestones.has_arrived({ tile = { x = 1, y = 1, plane = 0 } }, { tile = { x = 2, y = 1, plane = 1 } }),
    "a plane change counts")
end

return T
