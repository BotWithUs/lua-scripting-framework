-- spec/l2_j3_spec.lua -- the Java host's J3 composition APIs, ported: component options and
-- queries, chat dialog text, the destroy confirmation, the quest log, the deposit box, area loot,
-- buffs, the HUD tabs, logout / exit to lobby, the run pause and writable settings. Over the fake
-- bwu surface; each test names what would count as a failure.

local S = require("spec.l2_support")
local bot = require("botwithus")
local CQ = require("botwithus.component_query")
local Dialog = require("botwithus.dialog")
local Quests = require("botwithus.quests")
local DepositBox = require("botwithus.deposit_box")
local Loot = require("botwithus.loot")
local Buffs = require("botwithus.buffs")
local Hud = require("botwithus.hud")
local Settings = require("botwithus.settings")
local Script = require("botwithus.script")
local Json = require("botwithus.json")

local T = {}

local function iface(id, modal)
  return { id = id, type = modal and 0 or 1, client_opened = false, is_modal = modal or false }
end

-- Components ------------------------------------------------------------------------------------

local LOOT_TREE = { count = 5, nodes = {
  { iface = 1622, comp = 0, sub = -1, category = 1, text = "", item_id = -1, item_amount = 0,
    visible_global = true, parent = -1 },
  { iface = 1622, comp = 22, sub = -1, category = 6, text = "Loot All", item_id = -1, item_amount = 0,
    visible_global = true, parent = 0 },
  { iface = 1622, comp = 30, sub = 0, category = 4, text = "", item_id = 1521, item_amount = 12,
    visible_global = true, parent = 0 },
  { iface = 1622, comp = 30, sub = 1, category = 4, text = "", item_id = 1511, item_amount = 3,
    visible_global = false, parent = 0 },
  { iface = 1622, comp = 9, sub = -1, category = 3, text = "<col=ff0000>Loot</col>", item_id = -1,
    item_amount = 0, visible_global = true, parent = 0 },
} }

local function loot_opts(extra)
  local opts = {
    open_ifaces_ = { iface(1477), iface(1622) },
    cache_items = { [1511] = S.item(1511, "Logs", { category = 22 }),
                    [1521] = S.item(1521, "Oak logs", { category = 22 }) },
    inventories = { [773] = { { item_id = 1521, quantity = 12 }, { item_id = 1511, quantity = 3 } } },
    var_reads = S.vars({}, { [27943] = 1 }),
    rpc = {
      get_interface_tree = function(p)
        if p.iface == 1622 and p.comp == 0 then return LOOT_TREE end
        return nil, "not_found"
      end,
      get_component_ops = S.ops_handler({
        ["1622:22:-1"] = { { 1, "Loot All" } },
        ["1622:30:0"] = { { 2, "Take" }, { 9, "Examine", false } },
        ["1622:30:1"] = { { 1, "Take" }, { 4, "Inspect" } },
      }),
    },
  }
  for k, v in pairs(extra or {}) do opts[k] = v end
  return opts
end

-- Failure: interact sending sub -1 instead of the node's own, the default-option test reading the
-- wrong mask bit, or the item filters reading the wrong field.
T["j3 components: options, interact with the node's sub, query filters"] = function(assert_)
  local game = S.attach(loot_opts())
  local q = CQ.new(game, 1622)
  local slot = q:with_item_name("logs"):with_item_amount(10, 20):first()
  assert_(slot and slot.sub == 0 and slot.item_id == 1521, "Oak logs x12")
  local opts = CQ.options(game, slot)
  assert_(#opts == 2 and opts[1] == "Take" and CQ.has_option(game, slot, "examine"), "options")
  assert_(CQ.interact(game, slot, "take") == true, "interact")
  local a = S.actions()[1]
  assert_(a.id == 57 and a.p1 == 2 and a.p2 == 0 and a.p3 == (1622 << 16 | 30), "op 2, sub 0")
  assert_(CQ.interact(game, slot, "Bury") == false and #S.actions() == 1, "no such option")
  local defaults = CQ.new(game, 1622):has_default_option():all()
  assert_(#defaults == 2 and defaults[1].comp == 22 and defaults[2].sub == 1,
    "op 1 transmits on Loot All and the Logs slot; the Oak logs slot has only ops 2 and 9")
  assert_(CQ.new(game, 1622):with_option("Take"):count() == 2, "with_option")
  assert_(CQ.new(game, 1622):with_item_category(22):visible():count() == 1, "category + visible")
  assert_(CQ.new(game, 1622):with_item_name("Oak %a+", true):count() == 1, "pattern")
  assert_(CQ.new(game, 1622):containing_text("loot"):count() == 2, "text")
  assert_(CQ.new(game, 1622):with_text("loot all"):first().comp == 22, "with_text ignores case")
  assert_(CQ.new(game, 1622):of_category(CQ.TEXT):first().comp == 9, "category")
  assert_(#CQ.new(game, 1622):children(LOOT_TREE.nodes[1]) == 4, "children")
  assert_(CQ.new(game, 1188):count() == 0, "a closed interface reads empty")
end

-- Failure: Take clicked by a different item, Loot All pressed through another op, or anything
-- sent while the window is closed.
T["j3 loot: take by id and name, loot all, closed window"] = function(assert_)
  local game = S.attach(loot_opts())
  local loot = Loot.new(game)
  assert_(loot:is_open() and loot:is_area_loot_enabled(), "open, area loot on")
  assert_(loot:items():count(1511) == 3 and #loot:contents() == 2, "inventory 773")
  assert_(loot:take("logs") == true, "take by name (substring: Oak logs is first)")
  assert_(S.actions()[1].p2 == 0 and S.actions()[1].p1 == 2, "slot 0, op 2")
  assert_(loot:take(1511) == true and S.actions()[2].p2 == 1 and S.actions()[2].p1 == 1, "Logs slot: its Take is op 1")
  assert_(loot:loot_all() == true and S.actions()[3].p3 == (1622 << 16 | 22), "loot all")
  game = S.attach(loot_opts({ open_ifaces_ = { iface(1477) } }))
  loot = Loot.new(game)
  assert_(loot:take(1511) == false and loot:loot_all() == false and #S.actions() == 0, "closed")
end

-- Dialog ------------------------------------------------------------------------------------------

local function chat_opts(page, texts)
  return {
    open_ifaces_ = { iface(1477), iface(page, true) },
    rpc = { get_component = function(p)
      local t = texts[p.iface .. ":" .. p.comp]
      if t == nil then return { iface = -1 } end
      return { iface = p.iface, comp = p.comp, text = t }
    end },
  }
end

-- Failure: the player page's text read from the NPC page's component, the title read where a page
-- has none, or continue pressed on the wrong page.
T["j3 dialog: text and title across 1184 / 1191 / 1186 / 1189"] = function(assert_)
  local game = S.attach(chat_opts(1191, { ["1191:10"] = "<p=1>Howdy.", ["1191:4"] = "Me" }))
  assert_(Dialog.get_text(game) == "<p=1>Howdy." and Dialog.get_title(game) == "Me", "player chat")
  assert_(Dialog.plain(Dialog.get_text(game)) == "Howdy.", "plain")
  assert_(Dialog.is_player_chat_open(game) and Dialog.can_continue(game), "open")
  assert_(Dialog.continue_dialog(game) and S.actions()[1].id == 30 and S.actions()[1].p3 == (1191 << 16 | 15), "continue")
  game = S.attach(chat_opts(1186, { ["1186:3"] = "You <col=00ff00>light</col> the fire." }))
  assert_(Dialog.plain(Dialog.get_text(game)) == "You light the fire." and Dialog.get_title(game) == nil, "message box")
  assert_(Dialog.continue_dialog(game) and S.actions()[1].p3 == (1186 << 16 | 8), "message continue")
  game = S.attach(chat_opts(1189, { ["1189:3"] = "Item text" }))
  assert_(Dialog.get_text(game) == "Item text" and Dialog.continue_dialog(game)
    and S.actions()[1].p3 == (1189 << 16 | 20), "item box")
  game = S.attach(chat_opts(1184, { ["1184:10"] = "Hello.", ["1184:4"] = "Hans" }))
  assert_(Dialog.get_title(game) == "Hans" and Dialog.continue_chat(game), "npc chat")
  game = S.attach({ open_ifaces_ = { iface(1477) } })
  assert_(Dialog.get_text(game) == nil and not Dialog.continue_dialog(game) and #S.actions() == 0, "none open")
end

-- Failure: an option selected by its label leaf instead of its row, numbering from the wrong cell,
-- or a substring match that ignores markup.
T["j3 dialog: multi-choice options and select"] = function(assert_)
  local tree = { count = 7, nodes = {
    { iface = 1188, comp = 0, sub = -1, category = 1, parent = -1 },
    { iface = 1188, comp = 8, sub = -1, category = 1, parent = 0 },
    { iface = 1188, comp = 9, sub = -1, category = 3, text = "1.", parent = 1 },
    { iface = 1188, comp = 10, sub = -1, category = 3, text = "Yes, <col=ff0000>please</col>.", parent = 1 },
    { iface = 1188, comp = 13, sub = -1, category = 1, parent = 0 },
    { iface = 1188, comp = 14, sub = -1, category = 3, text = "2.", parent = 4 },
    { iface = 1188, comp = 15, sub = -1, category = 3, text = "No thanks.", parent = 4 },
  } }
  local game = S.attach({ rpc = { get_interface_tree = function() return tree end } })
  local opts = Dialog.options(game)
  assert_(#opts == 2 and opts[1].index == 1 and opts[2].text == "No thanks.", "two options")
  assert_(Dialog.select(game, "yes, please") == true and S.actions()[1].p3 == (1188 << 16 | 8), "the row, comp 8")
  assert_(Dialog.select(game, 2) == true and S.actions()[2].p3 == (1188 << 16 | 13), "by number")
  assert_(Dialog.select(game, "maybe") == false and Dialog.select(game, 3) == false, "no match")
end

-- Failure: confirm pressing No, or anything sent while the prompt is closed.
T["j3 dialog: ConfirmItemDestruction"] = function(assert_)
  local game = S.attach(chat_opts(1183, { ["1183:4"] = "<col=ff9040>Yak Track Task List</col>" }))
  local C = Dialog.Confirm
  assert_(C.is_open(game) and C.item_name(game) == "Yak Track Task List", "item name")
  assert_(C.confirm(game) and S.actions()[1].id == 30 and S.actions()[1].p3 == (1183 << 16 | 7), "yes is 7")
  assert_(C.cancel(game) and S.actions()[2].p3 == (1183 << 16 | 8), "no is 8")
  game = S.attach({ open_ifaces_ = { iface(1477) } })
  assert_(not C.confirm(game) and C.item_name(game) == nil and #S.actions() == 0, "closed")
end

-- Quests ------------------------------------------------------------------------------------------

local COOK = '{"id":257,"listName":"Cook\'s Assistant","membersOnly":false,"name":"Cook\'s Assistant",'
  .. '"progressVarbits":[],"progressVarps":[[2492,1,2]],"skillRequirements":[],"dependentQuestIds":[]}'
local COOK_STUB = '{"id":6,"listName":"","membersOnly":false,"name":"Cook\'s Assistant",'
  .. '"progressVarbits":[],"progressVarps":[],"skillRequirements":[],"dependentQuestIds":[]}'
local DRAGON = '{"id":300,"listName":"Dragon Test","membersOnly":true,"name":"Dragon Test",'
  .. '"progressVarbits":[[4567,10,110]],"progressVarps":[],'
  .. '"skillRequirements":[{"skill":8,"level":80},{"skill":14,"level":40}],"dependentQuestIds":[257]}'

local function quest_opts(cook_value, extra)
  local opts = {
    cache_json = { ["8:257"] = COOK, ["8:6"] = COOK_STUB, ["8:300"] = DRAGON },
    var_reads = S.vars({ [2492] = cook_value }, { [4567] = 10 }),
  }
  for k, v in pairs(extra or {}) do opts[k] = v end
  return opts
end

-- Failure: "started" only above the start value (v1's rule: Cook's Assistant 1..2 would never
-- read started), the stub not resolved to its listed twin, or a missing quest guessed.
T["j3 quests: stages, the at-or-above start rule, stubs"] = function(assert_)
  local log = Quests.new(S.attach(quest_opts(1)))
  local s = log:status(257)
  assert_(s.stage == Quests.STARTED and s.progress == 1 and s.variable.id == 2492, "value 1 at start 1 is started")
  assert_(log:is_started(257) and not log:is_complete(257), "started, not complete")
  local stub = log:status(6)
  assert_(stub.quest_id == 257 and stub.stage == Quests.STARTED, "stub 6 reads the listed 257")
  assert_(log:status("cook's assistant").quest_id == 257, "by display name")
  log = Quests.new(S.attach(quest_opts(2)))
  assert_(log:is_complete(257) and log:progress(257) == 2, "complete at the end value")
  log = Quests.new(S.attach(quest_opts(0)))
  assert_(log:status(257).stage == Quests.NOT_STARTED and not log:is_started(257), "not started")
  local missing = log:status(9999)
  assert_(missing.stage == Quests.UNKNOWN and missing.progress == -1, "unknown, never guessed")
  assert_(Json.decode(COOK).progressVarps[1][3] == 2, "the cache's [id, start, end] arrays")
end

-- Failure: a met skill reported unmet, a prior quest not checked through the log, or membership
-- ignored on a members quest.
T["j3 quests: unmet requirements"] = function(assert_)
  local self_ = { valid = true, tile = { x = 3200, y = 3200, plane = 0 }, server_index = 1000,
                  is_member = false, health = 1, max_health = 1 }
  local game = S.attach(quest_opts(1, { self_ = self_ }))
  local log = Quests.new(game)
  local unmet = log:unmet_requirements(300)
  local kinds = {}
  for _, r in ipairs(unmet) do kinds[#kinds + 1] = r.kind .. (r.skill_id and (":" .. r.skill_id) or "") .. (r.quest_id and (":" .. r.quest_id) or "") end
  assert_(table.concat(kinds, ",") == "membership,skill:8,quest:257",
    "woodcutting 72 < 80, mining 50 >= 40, Cook's Assistant only started: " .. table.concat(kinds, ","))
  local skill = unmet[2]
  assert_(skill.required == 80 and skill.actual == 72, "required / actual")
  assert_(log:requirements_met(257) and not log:requirements_met(300), "requirements_met")
end

-- Deposit box, buffs, HUD -------------------------------------------------------------------------

-- Failure: a deposit sent with op 1, the kept item deposited, or a press while closed.
T["j3 deposit box: buttons by option, deposit_all_except per distinct item"] = function(assert_)
  local opts = {
    open_ifaces_ = { iface(1477), iface(11, true) },
    cache_items = { [1511] = S.item(1511, "Logs"), [995] = S.item(995, "Coins") },
    rpc = {
      get_interface_tree = function(p)
        if p.iface ~= 11 then return nil, "not_found" end
        return { count = 2, nodes = { { iface = 11, comp = 0, sub = -1, parent = -1 },
                                      { iface = 11, comp = 4, sub = -1, parent = 0 } } }
      end,
      get_component_ops = S.ops_handler({
        ["11:4:-1"] = { { 1, "Deposit Carried Items" } },
        ["11:19:0"] = { { 7, "Deposit-All" } }, ["11:19:2"] = { { 7, "Deposit-All" } },
      }),
    },
  }
  local game = S.attach(opts)
  local box = DepositBox.new(game)
  assert_(box:deposit_all() and S.actions()[1].p3 == (11 << 16 | 4), "carried items button")
  assert_(box:deposit_worn() == false, "no such button: false, nothing sent")
  assert_(box:deposit_all_except({ "Coins" }) == true, "except coins")
  local a, b = S.actions()[2], S.actions()[3]
  assert_(#S.actions() == 2, "slots 0 and 2 are both Logs: one click: " .. #S.actions())
  assert_(a.p1 == 7 and a.p2 == 0 and a.p3 == (11 << 16 | 19) and b == nil, "Deposit-All op 7 on slot 0")
  game = S.attach({ open_ifaces_ = { iface(1477) } })
  assert_(not DepositBox.new(game):deposit_all() and #S.actions() == 0, "closed")
end

-- Failure: a buff's time in 10 s units, potency missing, or a flag buff given a time.
T["j3 buffs: active, remaining and potency"] = function(assert_)
  local game = S.attach({ var_reads = S.vars({}, { [48834] = 22, [43714] = 4, [43696] = 3, [33448] = 1 }) })
  local b = Buffs.new(game)
  assert_(b:is_active(Buffs.OVERLOAD) and not b:is_active(Buffs.ANTIFIRE), "active")
  assert_(b:remaining_ms(Buffs.OVERLOAD) == 22 * 15000, "15 s units")
  local irit = b:state(Buffs.IRIT_INCENSE)
  assert_(irit.potency == 3 and irit.remaining_ms == 60000 and irit.raw == 4, "incense potency")
  local aggro = b:state(Buffs.AGGRESSION)
  assert_(aggro.is_active and aggro.remaining_ms == nil, "a flag has no time")
  local keys = {}
  for _, x in ipairs(b:active()) do keys[#keys + 1] = x.key end
  assert_(table.concat(keys, ",") == "OVERLOAD,IRIT_INCENSE,AGGRESSION", "active list")
end

-- Failure: a tab found through a fixed slot when the cache enum says otherwise, a press when the
-- tab already shows, or the open state read from the open-interface list.
T["j3 hud: tabs through RIBBON_WINDOWS and the button's own Open / Close"] = function(assert_)
  local opts = {
    cache_json = { ["3:13319"] = '{"entries":{"20":0,"21":2,"11":4},"id":13319}' },
    rpc = { get_component_ops = S.ops_handler({
      ["1431:0:20"] = { { 1, "Open" } },     -- skills: in slot 20 on this cache, not 8
      ["1431:0:21"] = { { 1, "Close" } },    -- backpack shows
    }) },
  }
  local game = S.attach(opts)
  local hud = Hud.new(game)
  assert_(hud:slot_of(Hud.SKILLS) == 20 and hud:slot_of(Hud.MAGIC) == 12, "enum slot; fallback for magic")
  assert_(not hud:is_open(Hud.SKILLS) and hud:is_open(Hud.BACKPACK), "state from the button")
  assert_(hud:open(Hud.BACKPACK) == true and #S.actions() == 0, "already showing: nothing pressed")
  assert_(hud:open(Hud.SKILLS) == true, "open skills")
  local a = S.actions()[1]
  assert_(a.id == 57 and a.p1 == 1 and a.p2 == 20 and a.p3 == (1431 << 16), "slot 20 by its Open op")
  assert_(hud:open(Hud.PRAYER) == false, "no menu: false")
end

-- Failure: a refusal reported as success, or the wrong agent method.
T["j3 hud: logout and exit_to_lobby call the agent's methods"] = function(assert_)
  local called = {}
  local game = S.attach({ rpc = {
    logout = function() called[#called + 1] = "logout"; return {} end,
    exit_to_lobby = function() called[#called + 1] = "exit_to_lobby"; return nil, "not_in_game" end,
  } })
  local hud = Hud.new(game)
  assert_(hud:logout() == true, "logout queued")
  local ok, code = hud:exit_to_lobby()
  assert_(ok == false and code == "not_in_game", "refusal passed through")
  assert_(table.concat(called, ",") == "logout,exit_to_lobby", "methods")
end

-- Pause and settings ------------------------------------------------------------------------------

-- Failure: a paused run still looping, a resume not taking effect, or settings replacing the keys
-- the script wrote when the config changes.
T["j3 runner: pause holds on_loop until a UI-side resume"] = function(assert_)
  local game = S.attach()
  local loops, held_polls = 0, 0
  local script = { manifest = { name = "pause", version = "1" } }
  function script.on_loop(ctx)
    loops = loops + 1
    if loops == 2 then
      ctx:pause()
      -- What a plugin-UI button handler would do, a few polls into the hold.
      local Timing = require("botwithus.timing")
      local pause = Timing.pause_of(game)
      local real = ctx.waits._sleep
      ctx.waits._sleep = function(ms)
        held_polls = held_polls + 1
        if held_polls == 3 then pause:resume() end
        return real(ms)
      end
    end
    if loops == 4 then return -1 end
    return 0
  end
  bot.run(script, { game = game })
  assert_(loops == 4, "it looped to the end: " .. loops)
  assert_(held_polls == 3, "it held for three polls before the resume: " .. held_polls)
end

T["j3 settings: read through the config, kept across a config change, not persisted"] = function(assert_)
  local config = { tree = "Oak", logs = 28 }
  local s = Settings.new(function() return config end)
  assert_(s:get("tree") == "Oak" and s:get_int("logs", 0) == 28, "reads the config")
  s:put("trips", 7)
  s:put_boolean("banked", true)
  config = { tree = "Willow", logs = 20 }
  assert_(s:get("tree") == "Willow" and s:get_int("trips", 0) == 7 and s:get_boolean("banked", false), "merged")
  assert_(s:remove("logs") == true and s:get("logs") == nil and s:as_table().trips == 7, "remove")
  assert_(s:get_string("missing", "x") == "x", "default")
  local ok, why = s:save()
  assert_(ok == false and why == "unsupported", "not persisted")
  local game = S.attach()
  local ctx = Script._make_ctx(game, function() return true end, nil)
  ctx.config = { a = 1 }
  ctx.settings:put("b", 2)
  ctx.config = { a = 3 }
  assert_(ctx.settings:get("a") == 3 and ctx.settings:get("b") == 2, "ctx.settings over ctx.config")
end

return T
