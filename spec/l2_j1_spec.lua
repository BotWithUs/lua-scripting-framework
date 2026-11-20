-- spec/l2_j1_spec.lua -- the Java host's J1 composition APIs, ported: condition waits, Coordinate
-- and Area, inventory and bank by name / pattern / category, skills and xp, timing utilities and
-- the entity filters. Over the fake bwu surface; every expected value differs from a default.
-- Each test names what would count as a failure.

local S = require("spec.l2_support")
local bot = require("botwithus")
local Timing = require("botwithus.timing")
local Timers = require("botwithus.timers")
local Area = require("botwithus.area")
local Tile = require("botwithus.tile")
local Match = require("botwithus.match")
local Bank = require("botwithus.bank")
local Xp = require("botwithus.xp")
local Script = require("botwithus.script")

local T = {}

-- Condition waits ------------------------------------------------------------------------------

-- Failure: a wait that keeps polling after the stop, runs past its timeout, or reports true
-- when the condition never held.
T["j1 timing: until_ meets, times out, and leaves within one poll of a stop"] = function(assert_)
  local c = S.clock()
  local calls = 0
  local w = Timing.new({ now = c.now, sleep = c.sleep, stopping = function() return false end })
  assert_(w:until_(function() calls = calls + 1; return calls == 3 end, 1000) == true, "met")
  assert_(c.t == 2 * Timing.POLL_MS, "two polls before the third check, got " .. c.t)
  c.t = 0
  assert_(w:until_(function() return false end, 730) == false, "timeout")
  assert_(c.t == 730, "stops at the timeout exactly, got " .. c.t)
  local stop = false
  local c2 = S.clock(function(cc) if cc.sleeps == 2 then stop = true end end)
  local w2 = Timing.new({ now = c2.now, sleep = c2.sleep, stopping = function() return stop end })
  assert_(w2:until_(function() return false end, 60000) == false, "stop is false")
  assert_(c2.sleeps == 2, "left right after the stop, polls: " .. c2.sleeps)
  assert_(w:while_(function() return false end, 10) == true, "while_ ends when the condition stops")
end

-- Failure: the tick wait counting anything but server ticks, or hanging on a stalled tick.
T["j1 timing: tick waits count server ticks and give up on a stalled tick"] = function(assert_)
  local tick = 7000
  local c = S.clock(function(cc) if cc.sleeps % 3 == 0 then tick = tick + 1 end end)
  local w = Timing.new({ now = c.now, sleep = c.sleep, stopping = function() return false end,
                         tick = function() return tick end })
  assert_(w:ticks(4) == true and tick == 7004, "4 ticks passed: " .. tick)
  local hit = tick + 2
  assert_(w:until_ticks(function() return tick >= hit end, 5) == true, "met within budget")
  local start = tick
  assert_(w:until_ticks(function() return false end, 3) == false and tick - start == 3, "budget")
  local stalled = S.clock()
  local ws = Timing.new({ now = stalled.now, sleep = stalled.sleep,
                          stopping = function() return false end, tick = function() return 42 end })
  assert_(ws:ticks(2) == false, "a stalled tick ends the wait")
  local cap = 3 * Timing.TICK_MS * Timing.STALLED_CLOCK_FACTOR
  assert_(stalled.t >= cap and stalled.t < cap + 2 * Timing.POLL_MS, "wall cap, got " .. stalled.t)
  local r = Timing.new({ now = c.now, sleep = c.sleep, tick = function() return tick end,
                         stopping = function() return false end,
                         random = function(a, b) assert_(a == 2 and b == 6, "range"); return 3 end })
  local before = tick
  assert_(r:delay_ticks(2, 6) and tick - before == 3, "delay_ticks draws in min..max")
end

-- Failure: a paused wait that tests its condition or spends its timeout or tick budget.
T["j1 timing: pause holds the waits without spending their budget"] = function(assert_)
  local paused = true
  local tested = 0
  local c = S.clock(function(cc) if cc.t >= 5000 then paused = false end end)
  local w = Timing.new({ now = c.now, sleep = c.sleep, stopping = function() return false end,
                         paused = function() return paused end })
  local met = w:until_(function() tested = tested + 1; return tested == 3 end, 200)
  assert_(met == true, "the 200 ms timeout was not spent while paused")
  assert_(c.t >= 5000, "it held until resume")
  local tick, ticks_paused = 100, true
  local c2 = S.clock(function(cc)
    tick = tick + 1
    if cc.sleeps == 10 then ticks_paused = false end
  end)
  local w2 = Timing.new({ now = c2.now, sleep = c2.sleep, stopping = function() return false end,
                          tick = function() return tick end, paused = function() return ticks_paused end })
  assert_(w2:ticks(3) == true, "ticks")
  assert_(tick >= 113, "ticks passed while paused were not counted: " .. tick)
  local stop = false
  local c3 = S.clock(function(cc) if cc.sleeps == 4 then stop = true end end)
  local w3 = Timing.new({ now = c3.now, sleep = c3.sleep, stopping = function() return stop end,
                          paused = function() return true end })
  assert_(w3:until_(function() return true end, 100) == false and c3.sleeps == 4, "stop ends a paused wait")
end

-- Failure: ctx missing a wait, or ctx:pause not reaching the waits bound to the same Game.
T["j1 timing: ctx waits, pause and the Game's shared pause"] = function(assert_)
  local game = S.attach()
  local ctx = Script._make_ctx(game, function() return true end, nil)
  assert_(ctx:delay_until(function() return true end, 100) == true, "delay_until")
  assert_(ctx:delay_while(function() return false end, 100) == true, "delay_while")
  ctx:pause()
  assert_(ctx:is_paused() and Timing.pause_of(game):is_paused(), "shared pause")
  assert_(ctx:resume() == true and not ctx:is_paused(), "resume reports it was paused")
  assert_(type(ctx.delay_until_ticks) == "function" and type(ctx.delay_ticks) == "function", "tick forms")
end

-- Coordinate and Area -------------------------------------------------------------------------

-- Failure: region x/y swapped (Varrock is region (50, 53), where a swap shows), or a wrong
-- euclidean distance.
T["j1 coordinate: region helpers, offset, euclidean"] = function(assert_)
  local t = Tile.new(3212, 3424, 0)
  assert_(t:region_x() == 50 and t:region_y() == 53, "region x/y")
  assert_(t:region_id() == (50 << 8 | 53) and t:region_id() == 12853, "region id")
  assert_(t:region_local_x() == 12 and t:region_local_y() == 32, "local x/y")
  assert_(t:offset(3, -4):equals(Tile.new(3215, 3420, 0)), "offset")
  assert_(t:offset(0, 0, 2).plane == 2 and t:with_plane(1).plane == 1, "planes")
  assert_(t:euclidean(Tile.new(3215, 3428, 0)) == 5.0, "3-4-5")
  assert_(bot.Coordinate == Tile, "Coordinate is Tile")
end

-- Failure: an edge reported outside, a tile on another plane reported inside, the circle using
-- Chebyshev, the polygon outline excluded or a concave notch reported inside.
T["j1 area: rectangle, circle and polygon containment"] = function(assert_)
  local r = Area.rect(3092, 3240, 3097, 3246, 1)
  assert_(r:contains(3092, 3240, 1) and r:contains(3097, 3246, 1), "edges inclusive")
  assert_(not r:contains(3092, 3240, 0), "other plane")
  assert_(not r:contains(3098, 3243, 1) and r:width() == 6 and r:height() == 7, "outside / size")
  assert_(r:contains({ tile = { x = 3095, y = 3241, plane = 1 } }), "a row with a tile")
  local c = Area.circle({ x = 3200, y = 3200, plane = 0 }, 5)
  assert_(c:contains(3203, 3204, 0), "3,4 is at distance 5")
  assert_(not c:contains(3204, 3204, 0), "4,4 is a Chebyshev 4 but Euclidean 5.66")
  -- A U shape: the notch (3203..3206, 3203..3209) is outside.
  local u = Area.polygon({ { 3200, 3200 }, { 3210, 3200 }, { 3210, 3210 }, { 3207, 3210 },
                           { 3207, 3203 }, { 3203, 3203 }, { 3203, 3210 }, { 3200, 3210 } })
  assert_(u:contains(3201, 3205, 0) and u:contains(3209, 3209, 0), "inside both arms")
  assert_(not u:contains(3205, 3207, 0), "the notch is outside")
  assert_(u:contains(3205, 3203, 0) and u:contains(3210, 3210, 0), "outline and vertex inside")
  local ok = pcall(Area.polygon, { { 1, 1 }, { 2, 2 } })
  assert_(not ok, "two vertices refused")
end

-- Failure: a random tile outside its area, or a reachable draw that was not checked.
T["j1 area: random tiles stay inside; random_reachable_tile asks the walker"] = function(assert_)
  local seq = { 3, 9, 1, 1, 7, 2 }
  local i = 0
  local function rnd(a, b) i = i + 1; return a + (seq[(i - 1) % #seq + 1] % (b - a + 1)) end
  local poly = Area.polygon({ { 3200, 3200 }, { 3208, 3200 }, { 3200, 3208 } })
  for _ = 1, 20 do
    local t = poly:random_tile(rnd)
    assert_(poly:contains(t), "random tile inside: " .. tostring(t))
  end
  local asked = {}
  local game = { path = function(_, x, y)
    asked[#asked + 1] = x .. "," .. y
    if x ~= 3204 then error("no route") end
    return {}
  end }
  local rect = Area.rect(3201, 3200, 3204, 3200)
  local n = 0
  local function cycle(a, b) n = n + 1; return n <= 2 and a or b end
  local t = rect:random_reachable_tile(game, 5, cycle)
  assert_(t ~= nil and t.x == 3204, "the reachable draw")
  assert_(#asked == 2, "one walker query per draw: " .. #asked)
  assert_(rect:random_reachable_tile(game, 2, function(a) return a end) == nil, "none in 2 draws")
end

-- Inventory and bank by name ------------------------------------------------------------------

local function item_opts(extra)
  local opts = {
    cache_items = {
      [1511] = S.item(1511, "Logs", { category = 22, inventory_ops = { "Craft", "Light", "", "", "" } }),
      [1521] = S.item(1521, "Oak logs", { category = 22 }),
      [995] = S.item(995, "Coins", { stackable = true, category = 1093 }),
      [2347] = S.item(2347, "Hammer", { category = 70, inventory_ops = { "", "", "", "Use", "" } }),
    },
    inventories = {
      [93] = { { item_id = 1521, quantity = 1 }, { item_id = 1511, quantity = 1 },
               { item_id = 995, quantity = 1000 }, { item_id = 1511, quantity = 1 },
               { item_id = 2347, quantity = 1 }, { item_id = -1, quantity = 0 } },
      [95] = { { item_id = 1521, quantity = 50 }, { item_id = 1511, quantity = 300 } },
    },
    rpc = { get_component_ops = S.ops_handler({
      ["1473:5:1"] = { { 2, "Light" }, { 8, "Drop" } },
    }) },
  }
  for k, v in pairs(extra or {}) do opts[k] = v end
  return opts
end

-- Failure: "Logs" matching Oak logs (a substring where the whole name is meant), the pattern not
-- anchored, a category or option read wrong.
T["j1 inventory: exact names, patterns, categories, options"] = function(assert_)
  local game = S.attach(item_opts())
  local bp = game:backpack()
  assert_(bp:find_exact("logs").slot == 1, "Logs at slot 1, not Oak logs at slot 0")
  assert_(bp:count("logs") == 3, "a plain string stays a substring")
  assert_(bp:count(Match.exact("Logs")) == 2, "exact")
  assert_(bp:count(Match.pattern("Oak %a+")) == 1, "pattern")
  assert_(bp:count(Match.pattern("ogs")) == 0, "a pattern must match the whole name")
  assert_(bp:contains_all_of("Logs", "Coins") and not bp:contains_all_of("Logs", "Bones"), "all of")
  assert_(bp:contains_any_of("Bones", "coins"), "any of")
  assert_(bp:contains_any_except(1511, 1521, 995) == true, "the hammer is left")
  assert_(bp:contains_any_except(1511, 1521, 995, 2347) == false, "nothing else")
  assert_(#bp:find_all_in_category(22) == 3 and bp:contains_category(1093), "category")
  assert_(#bp:items_with_option("light") == 2, "items with an option")
end

-- Failure: the op taken from the cache position (Light is cache op 2 but the live menu says 2 for
-- slot 1 here too, so Drop proves it: cache has no Drop), a click on Oak logs, or Use not found.
T["j1 inventory: interact uses the live menu; Use uses the cache ops"] = function(assert_)
  local game = S.attach(item_opts())
  local bp = game:backpack()
  assert_(bp:interact("Logs", "Drop") == true, "Drop from the live menu")
  local a = S.actions()[1]
  assert_(a.id == 57 and a.p1 == 8 and a.p2 == 1 and a.p3 == (1473 << 16 | 5), "drop slot 1 op 8")
  assert_(bp:interact("Logs", "Bury") == false and #S.actions() == 1, "no such option: nothing sent")
  assert_(bp:use("Hammer") == true and S.actions()[2].p1 == 4 and S.actions()[2].p2 == 4, "Use: cache op 4")
  assert_(bp:interact("Bones", "Drop") == false, "no such item")
end

-- Failure: a click while the bank is closed, a duplicate Deposit-All for a second stack, the
-- excepted item deposited, or the note toggle flipping a mode that is already right.
T["j1 bank: deposit_all_except, withdraw by name, withdraw mode"] = function(assert_)
  local opts = item_opts({ var_reads = S.vars({ [160] = 1 }, {}),
                          open_ifaces_ = { { id = 1477, type = 1, client_opened = false, is_modal = false } } })
  local closed = S.attach(opts)
  assert_(Bank.new(closed):deposit_all_except({ "Coins" }) == false and #S.actions() == 0, "closed")
  opts.open_ifaces_ = { { id = 517, type = 0, client_opened = false, is_modal = true } }
  local game = S.attach(opts)
  local bank = Bank.new(game)
  assert_(bank:deposit_all_except({ "Coins" }) == true, "queued")
  local acts = S.actions()
  assert_(#acts == 3, "Oak logs, Logs (once), Hammer: got " .. #acts)
  for _, a in ipairs(acts) do
    assert_(a.p1 == 7 and a.p3 == (517 << 16 | 15) and a.p2 ~= 2, "Deposit-All on the backpack grid")
  end
  assert_(acts[1].p2 == 0 and acts[2].p2 == 1 and acts[3].p2 == 4, "one click per distinct item")
  assert_(bank:withdraw("Logs", Bank.TEN) == true, "withdraw")
  local w = S.actions()[4]
  assert_(w.p1 == 4 and w.p2 == 1 and w.p3 == (517 << 16 | 201), "Logs (slot 1), not Oak logs")
  assert_(bank:withdraw_mode() == Bank.NOTE and bank:set_withdraw_mode(Bank.NOTE) and #S.actions() == 4,
    "already noting: nothing pressed")
  assert_(bank:set_withdraw_mode(Bank.ITEM) and S.actions()[5].p3 == (517 << 16 | 127), "toggle once")
  assert_(bank:deposit_all(Match.pattern("Oak %a+")) and S.actions()[6].p2 == 0, "deposit_all by pattern")
  assert_(bank:withdraw_preset(12) == true, "preset 12")
  local page, preset = S.actions()[7], S.actions()[8]
  assert_(page.p2 == 100 and preset.p2 == 3 and preset.p3 == (517 << 16 | 119), "page 2, slot 3")
end

-- Failure: open() ignoring bankers, or load_last_preset not picking the nearer of the two.
T["j1 bank: open prefers a booth, else a banker; load_last_preset picks the nearer"] = function(assert_)
  local opts = {
    cache_locs = { [1530] = { id = 1530, name = "Bank booth", ops = { "Bank", "Collect", "", "", "" } } },
    cache_npcs = { [1234] = { id = 1234, name = "Banker", ops = { "Talk to", "Bank", "Collect",
                                                                   "Load Last Preset from", "" } } },
    open_ifaces_ = { { id = 1477, type = 1, client_opened = false, is_modal = false } },
  }
  local game = S.attach(opts)
  assert_(Bank.new(game):open() == true, "booth")
  local a = S.actions()[1]
  assert_(a.id == 3 and a.p1 == 1530 and a.p2 == 3201, "booth option 1 (Bank)")
  opts.cache_locs = { [1530] = { id = 1530, name = "Door", ops = { "Open", "", "", "", "" } } }
  game = S.attach(opts)
  assert_(Bank.new(game):open() == true, "banker")
  a = S.actions()[1]
  assert_(a.id == 10 and a.p1 == 55, "the nearest banker (55), option 2 (Bank)")
  assert_(Bank.new(game):load_last_preset() == true and S.actions()[2].id == 12, "banker option 4")
end

-- Skills and xp ------------------------------------------------------------------------------

-- Failure: any anchor level off by any amount, a boundary round trip failing, Invention not
-- elite, or a cap ignored.
T["j1 xp: standard and elite anchors, caps, display names"] = function(assert_)
  local s = Xp.STANDARD
  local anchors = { [1] = 0, [2] = 83, [10] = 1154, [50] = 101333, [92] = 6517253,
                    [99] = 13034431, [120] = 104273167, [126] = 188884740 }
  for level, xp in pairs(anchors) do
    assert_(s:xp_for_level(level) == xp, "standard " .. level)
    assert_(s:level_for_xp(xp) == level and (level == 1 or s:level_for_xp(xp - 1) == level - 1),
      "round trip at " .. level)
  end
  assert_(s:max_level() == 126 and Xp.ELITE:max_level() == 120, "table tops")
  assert_(Xp.ELITE:xp_for_level(2) == 830 and Xp.ELITE:xp_for_level(99) == 36073511
    and Xp.ELITE:xp_for_level(120) == 80618654, "elite anchors")
  assert_(s:level_for_xp(200000000) == 126 and s:level_for_xp(200000000, 99) == 99, "cap")
  assert_(s:xp_to_next_level(13034431) == 14391160 - 13034431 and s:xp_to_next_level(188884740) == 0, "next")
  assert_(Xp.table_for("invention") == Xp.ELITE and Xp.table_for(8) == Xp.STANDARD, "elite")
  assert_(Xp.display_name(8) == "Woodcutting" and Xp.display_name("necromancy") == "Necromancy", "names")
  assert_(Xp.virtual_level({ skill_id = 8, xp = 1234567 }) == 75, "virtual level from xp (75 starts at 1210421)")
  assert_(not pcall(s.xp_for_level, s, 127), "past the table raises")
end

-- Failure: a wrong rate, gains counted from the wrong baseline, or a stale clock after a late
-- baseline.
T["j1 xp: XpTracker gains, rate and a late baseline"] = function(assert_)
  local game = S.attach()
  local now = 1000000
  local tr = Xp.tracker(game, "woodcutting", { clock = function() return now end })
  local wc = bwu._abi5.skills[1]
  wc.xp, wc.level = 1234567 + 25000, 73
  now = now + 30 * 60 * 1000
  assert_(tr:xp_gained() == 25000 and tr:levels_gained() == 1, "gains")
  assert_(tr:xp_per_hour() == 50000, "rate per hour, got " .. tr:xp_per_hour())
  local need = Xp.STANDARD:xp_to_next_level(1259567)
  assert_(tr:time_to_next_level_ms() == need * 3600000 // 50000, "time to level")
  local missing = Xp.tracker(game, "agility", { clock = function() return now end })
  assert_(missing:xp_gained() == 0, "no row: no gain")
  bwu._abi5.skills[3] = { skill_id = 16, xp = 50000, level = 32, boosted_level = 32 }
  now = now + 5000
  assert_(missing:xp_gained() == 0 and missing:elapsed_ms() == 0, "baseline and clock taken late")
end

-- Timing utilities ---------------------------------------------------------------------------

-- Failure: paused time counted, a timer that never expires or does not re-roll, a wrong format.
T["j1 timers: Stopwatch, Timer, Durations"] = function(assert_)
  local now = 500
  local clock = function() return now end
  local sw = Timers.Stopwatch.started(clock)
  now = 2500
  sw:pause()
  now = 9500
  assert_(sw:elapsed_ms() == 2000 and not sw:is_running(), "paused time excluded")
  sw:resume(); now = 10500
  assert_(sw:elapsed_ms() == 3000, "resumed")
  local draws = { 4000, 7000 }
  local d = 0
  local t = Timers.Timer.new(3000, 8000, { clock = clock,
    random = function(a, b) assert_(a == 3000 and b == 8000, "range"); d = d + 1; return draws[d] end })
  assert_(t:duration_ms() == 4000 and not t:has_expired(), "drawn")
  now = now + 4000
  assert_(t:has_expired() and t:remaining_ms() == 0, "expired")
  t:reset()
  assert_(t:duration_ms() == 7000 and t:remaining_ms() == 7000, "reset re-rolls")
  assert_(not pcall(Timers.Timer.new, 5, 4), "min > max refused")
  assert_(Timers.Durations.format(3723000) == "01:02:03", "format")
  assert_(Timers.Durations.format(90061000) == "1d 01:01:01", "days")
  assert_(Timers.Durations.per_hour(150, 600000) == 900 and Timers.Durations.per_hour(5, 0) == 0, "per hour")
end

-- Entity filters ------------------------------------------------------------------------------

local function npc_opts()
  return {
    npcs_ = {
      { server_index = 55, type_id = 1234, active_type_id = 1234, tile = { x = 3201, y = 3201, plane = 0 },
        animation_id = 422, stance_id = 808, spot_anim_id = -1, moving = false, hp = 300,
        max_hp = 1000, combat_level = 12 },
      { server_index = 56, type_id = 1234, active_type_id = 1234, tile = { x = 3209, y = 3209, plane = 0 },
        animation_id = -1, stance_id = 809, spot_anim_id = 85, moving = true, hp = 900,
        max_hp = 1000, combat_level = 40 },
      { server_index = 57, type_id = 9999, active_type_id = 9999, tile = { x = 3204, y = 3200, plane = 1 },
        animation_id = -1, stance_id = 808, spot_anim_id = -1, moving = false, hp = 5, max_hp = 0,
        combat_level = 90 },
    },
    cache_npcs = {
      [1234] = { id = 1234, name = "Goblin", ops = { "Attack", "", "", "", "Examine" } },
      [9999] = { id = 9999, name = "Banker", ops = { "Talk to", "Bank", "", "", "" } },
    },
  }
end

-- Failure: a filter reading the wrong field, an unknown max hp passing the percent filter, the
-- area filter ignoring planes, or a terminal returning the wrong row.
T["j1 entities: animation, actor, health, option, name and area filters"] = function(assert_)
  local game = S.attach(npc_opts())
  local q = bot.npcs(game)
  local function idx(rows) local o = {} for i, r in ipairs(rows) do o[i] = r.server_index end return table.concat(o, ",") end
  assert_(idx(q:animating():all()) == "55" and idx(q:not_animating():all()) == "56,57", "animating")
  assert_(idx(q:with_animation(422, 1):all()) == "55", "with_animation")
  assert_(idx(q:with_stance(808):all()) == "55,57" and idx(q:with_spot_anim(85):all()) == "56", "stance, spot")
  assert_(idx(q:moving():all()) == "56" and idx(q:not_moving():all()) == "55,57", "moving")
  assert_(idx(q:with_combat_level(30, 90):all()) == "56,57", "combat level")
  assert_(idx(q:with_health(250, 500):all()) == "55", "health")
  assert_(idx(q:with_health_percent(0, 50):all()) == "55", "percent; unknown max excluded")
  assert_(idx(q:with_option("bank"):all()) == "57" and idx(q:named_any_of("goblin"):all()) == "55,56", "option, names")
  assert_(idx(q:name_matching("Gob%a+"):all()) == "55,56" and idx(q:with_ids(9999):all()) == "57", "pattern, ids")
  local yard = Area.rect(3200, 3200, 3205, 3205, 0)
  assert_(idx(q:inside(yard):all()) == "55" and idx(q:outside(yard):all()) == "56,57", "area + plane")
  assert_(q:last().server_index == 57 and q:random(function(_, n) return n - 1 end).server_index == 56, "last, random")
  assert_(q:nearest_to(3210, 3210).server_index == 56, "nearest_to x, y")
  assert_(q:nearest_to(3204, 3201, 0).server_index == 55, "nearest_to on a plane skips 57")
  assert_(q:nearest_to({ tile = { x = 3204, y = 3201, plane = 1 } }).server_index == 57, "nearest_to a row")
  assert_(q:interact(q:with_ids(9999):first(), "Bank") == true and S.actions()[1].id == 10, "interact by option")
end

-- Failure: reachable() keeping a row the walker cannot route to, or skipping the plane check.
T["j1 entities: reachable asks the walker per candidate"] = function(assert_)
  local game = S.attach(npc_opts())
  local inner = bwu.path
  local asked = 0
  bwu.path = function(h, x, y, plane, o)
    asked = asked + 1
    if x == 3209 then return nil, "no route" end
    return inner(h, x, y, plane, o)
  end
  local rows = bot.npcs(game):reachable():all()
  assert_(#rows == 1 and rows[1].server_index == 55, "only 55: 56 has no route, 57 is upstairs")
  assert_(asked == 2, "no query for another plane: " .. asked)
end

return T
