-- spec/n3_spec.lua -- host ABI 8 in the Lua frontend: gameval names (botwithus.gameval and every
-- module that pinned a Java GamevalRef fallback id), the millisecond clock behind the timers and
-- waits, the host's pause switch, the settings store, and the object animation filter. Over the
-- fake bwu surface (spec/fake_bwu.lua install_abi8). Every name resolves to an id that differs
-- from the module's fallback, so a module still reading its pinned id fails. Each test names what
-- would count as a failure.

local S = require("spec.l2_support")
local fake_bwu = require("spec.fake_bwu")
local bot = require("botwithus")
local G = require("botwithus.gameval")
local ActionBar = require("botwithus.actionbar")
local Prayers = require("botwithus.prayers")
local Combat = require("botwithus.combat")
local Summoning = require("botwithus.summoning")
local Hud = require("botwithus.hud")
local Bank = require("botwithus.bank")
local Buffs = require("botwithus.buffs")
local Lodestones = require("botwithus.lodestones")
local Dialog = require("botwithus.dialog")
local Loot = require("botwithus.loot")
local Quests = require("botwithus.quests")
local Timers = require("botwithus.timers")
local Timing = require("botwithus.timing")
local Settings = require("botwithus.settings")
local Script = require("botwithus.script")
local Entities = require("botwithus.entities")

local T = {}

local function iface(id) return { id = id, type = 1, client_opened = false, is_modal = false } end

-- A Game over a fake with the ABI 8 surface; `gamevals` nil makes the index unavailable.
local function attach(opts, abi8)
  local game = S.attach(opts)
  fake_bwu.install_abi8(bwu, abi8)
  G._reset()
  return game
end

-- The gameval index ---------------------------------------------------------------------------

T["n3 gameval: both ways, case-insensitive, packed components, prefix in name order"] = function(assert_)
  attach({}, { gamevals = { varbit = { ACTIONBAR1_INT1_TYPE = 1747 },
                            component = { BANK__BANK_INV_BUTTON = (517 << 16) | 39 },
                            quest = { COOKS_ASSISTANT = 257, COOK_ALONE = 9 } } })
  local ok, version = G.available()
  assert_(ok and version == 1794589493, "available with the index version")
  assert_(G.id("varbit", "actionbar1_int1_type") == 1747, "case-insensitive")
  local i, c = G.component("BANK__BANK_INV_BUTTON")
  assert_(i == 517 and c == 39, "packed component split")
  assert_(G.name("varbit", 1747) == "ACTIONBAR1_INT1_TYPE", "id to name")
  local none, why = G.id("varp", "ACTIONBAR1_INT1_TYPE")
  assert_(none == nil and why == "not_found", "types are separate")
  local rows, total = G.starting_with("quest", "cook", 1)
  assert_(total == 2 and #rows == 1 and rows[1].id == 257, "byte order: S before _, limited")
end

T["n3 gameval: an unavailable index falls back once per name, and a new surface is asked again"] = function(assert_)
  attach({}, {})                 -- no gamevals: the host says no local cache
  local ok, why = G.available()
  assert_(not ok and why:find("no local game cache", 1, true), "the host's reason")
  local ref = G.ref("varp", "SA_ENERGY", 679)
  assert_(ref:id() == 679 and ref:id() == 679, "fallback")
  assert_(G._warned["varp:SA_ENERGY"] == true, "warned (once, by key)")
  _G.bwu = fake_bwu.new({})      -- an older host: no gameval surface at all
  local ok2, why2 = G.available()
  assert_(not ok2 and why2:find("ABI 8", 1, true), "re-asked for the new surface")
  fake_bwu.install_abi8(bwu, { gamevals = { varp = { SA_ENERGY = 9679 } } })
  assert_(ref:id() == 9679, "the name wins once the index can answer")
end

-- The modules resolve by name --------------------------------------------------------------------

local function bar_names(offset)
  local varbits, varps = { COMBATV2_ACTIONBAR_CURRENT_BAR = 99893 }, {}
  local comps = {}
  for slot = 1, 14 do
    varbits[("ACTIONBAR2_INT%d_TYPE"):format(slot)] = offset + 2 * slot
    varbits[("ACTIONBAR2_INT%d_ID"):format(slot)] = offset + 2 * slot + 1
    varps[("ACTIONBAR2_OBJ%d"):format(slot)] = offset + 500 + slot
    comps[("TOPLEVEL_V2_COMBAT_BAR__GRAPHIC_%d"):format(slot)] = (1430 << 16) | (600 + slot)
  end
  return { varbit = varbits, varp = varps, component = comps }
end

T["n3 action bar: slot variables, current bar and slot buttons by name"] = function(assert_)
  -- Failure: the generated table (1771..) read while every name of bar 2 resolves.
  local reads = {}
  local asked = {}
  local game = attach({ var_reads = function(fn, ids)
    asked[#asked + 1] = { fn = fn, ids = ids }
    return S.vars({}, { [99893] = 2 }, reads)(fn, ids)
  end }, { gamevals = bar_names(90000) })
  local bar = ActionBar.new(game)
  assert_(bar:active_bar() == 2, "current bar by name")
  bar:slots()
  local bits = asked[#asked - 1].ids
  assert_(bits[1] == 90002 and bits[2] == 90003 and bits[3] == 90004, "named varbits: " .. tostring(bits[1]))
  assert_(asked[#asked].ids[1] == 90501, "named varps")
  assert_(bar:use_slot(3) == true and S.actions()[1].p3 == ((1430 << 16) | 603), "named slot button")
end

T["n3 action bar: one missing name falls back for the whole bar"] = function(assert_)
  local names = bar_names(90000)
  names.varp.ACTIONBAR2_OBJ14 = nil
  local asked = {}
  local game = attach({ var_reads = function(fn, ids)
    asked[#asked + 1] = ids
    return S.vars({}, { [99893] = 2 })(fn, ids)
  end }, { gamevals = names })
  ActionBar.new(game):slots()
  assert_(asked[#asked - 1][1] == 1771, "the generated ACTIONBAR2 slot 1 type varbit, not a mix")
end

T["n3 prayers, combat, summoning: varbits, varps and windows by name"] = function(assert_)
  local game = attach({
    open_ifaces_ = { iface(4458) },
    var_reads = S.vars({ [70679] = 55, [71831] = 12345 },
                       { [77739] = 1, [77736] = 330, [71524] = 420 }),
  }, { gamevals = {
    varbit = { COMBATV2_PRAYER_BOOST_DEFENCE = 77739, PRAYER_POINTS = 77736, LORE_POINTS = 71524 },
    varp = { SA_ENERGY = 70679, FOLLOWER_OBJ = 71831 },
    interface = { TOPLEVEL_V2_PRAYER = 4458 } } })
  local p = Prayers.new(game)
  assert_(p:is_active("TIERED_DEFENCE") and p:points() == 33 and p:is_window_open(), "prayers by name")
  assert_(Combat.new(game):adrenaline() == 55, "adrenaline by name")
  local summ = Summoning.new(game)
  assert_(summ:raw_points() == 420 and summ:pouch_id() == 12345, "summoning by name")
end

T["n3 hud and bank: named components clicked"] = function(assert_)
  local game = attach({
    open_ifaces_ = { iface(617) },
    rpc = { get_component_ops = S.ops_handler({ ["2431:5:10"] = { { 1, "Open" } } }) },
  }, { gamevals = { component = { TOPLEVEL_V2_RIBBON__WINDOW_BUILD = (2431 << 16) | 5,
                                  BANK__BANK_INV_BUTTON = (617 << 16) | 49 },
                    interface = { BANK = 617 } } })
  assert_(Hud.new(game):open(Hud.EQUIPMENT) == true, "hud open")
  assert_(S.actions()[1].p3 == ((2431 << 16) | 5), "the named ribbon")
  local bank = Bank.new(game)
  assert_(bank:is_open() and bank:deposit_backpack(), "bank open by name; deposit")
  assert_(S.actions()[2].p3 == ((617 << 16) | 49), "the named deposit button")
end

T["n3 buffs, lodestones, chat pages, loot by name"] = function(assert_)
  local game = attach({
    open_ifaces_ = { iface(3184) },
    var_reads = S.vars({}, { [9001] = 4, [9002] = 1, [9003] = 1 }),
  }, { gamevals = {
    varbit = { OVERLOAD_POTION_EFFECTS_LONG = 9001, THAS_ACTIVE_VARROCK = 9002, LOOT_BY_AREA = 9003 },
    interface = { CHAT_V2_LEFT = 3184 },
    component = { CHAT_V2_LEFT__CHAT_TEXT = (3184 << 16) | 11 } } })
  assert_(Buffs.new(game):is_active(Buffs.OVERLOAD), "buff varbit by name")
  assert_(Lodestones.new(game):is_unlocked("VARROCK"), "unlock varbit by name")
  local page = Dialog.open_page(game)
  assert_(page and page.name == "npc" and page.iface == 3184 and page.text == 11 and page.continue == 15,
          "chat page resolved by name; an unnamed component keeps its fallback")
  assert_(Loot.new(game):is_area_loot_enabled(), "loot varbit by name")
end

T["n3 quests: listed from the gameval index; a quest asked for by its gameval name"] = function(assert_)
  -- The id scan would find nothing (no quest defs below 900); the listing names 900.
  local game = attach({ cache_json = {
    ["8:900"] = '{"id":900,"name":"Cook\'s Assistant","listName":"Cook\'s Assistant"}',
  } }, { gamevals = { quest = { COOKS_ASSISTANT_NEW = 900 } } })
  local log = Quests.new(game)
  assert_(log:_listed_by_name()["Cook's Assistant"] == 900, "listed from the index")
  assert_(log:_id_of("COOKS_ASSISTANT_NEW") == 900 and log:_id_of("Cook's Assistant") == 900, "by gameval or name")
end

-- The millisecond clock -----------------------------------------------------------------------------

T["n3 timers: Stopwatch, Timer and the waits run on the host's millisecond clock"] = function(assert_)
  -- Failure: os.time() (one-second steps) used while the host has a millisecond clock.
  attach({}, {})
  local clock = bwu._abi8
  assert_(Timers.has_ms_clock(), "the host's clock is seen")
  local watch = Timers.Stopwatch.started()
  clock.now = clock.now + 1234
  assert_(watch:elapsed_ms() == 1234, "ms resolution: " .. tostring(watch:elapsed_ms()))
  local timer = Timers.Timer.new(250)
  clock.now = clock.now + 249
  assert_(not timer:has_expired(), "not yet at 249 ms")
  clock.now = clock.now + 1
  assert_(timer:has_expired(), "expired at 250 ms")
  local polls = 0
  local waits = Timing.new({ sleep = function(ms) polls = polls + 1; clock.now = clock.now + ms; return true end,
                             stopping = function() return false end })
  local met = waits:until_(function() return false end, 120)
  assert_(met == false and polls == 3, "a 120 ms wait ends after three 50 ms polls: " .. polls)
end

-- Pause -------------------------------------------------------------------------------------------

T["n3 pause: in a worker the switch is the host's, both ways"] = function(assert_)
  -- Failure: ctx:pause() kept local (the GUI never sees it), or a GUI pause the script misses.
  local game = attach({}, {})
  fake_bwu.with_ctl(bwu, { mode = "worker" })
  game._pause = nil
  local ctx = Script._make_ctx(game, function() return true end, nil)
  ctx:pause()
  local rec = bwu._abi8
  assert_(rec.paused and rec.flips[1][2] == "script", "the host has the script's pause")
  rec.gui_pause(false)
  assert_(not ctx:is_paused(), "the GUI's resume is seen")
  rec.gui_pause(true)
  assert_(ctx:is_paused(), "the GUI's pause is seen")
end

T["n3 pause: the runner holds while the GUI has paused the run"] = function(assert_)
  -- Failure: on_loop runs during the GUI's pause, or the hold never ends on its resume.
  local game = attach({}, {})
  fake_bwu.with_ctl(bwu, { mode = "worker" })
  game._pause = nil
  local rec = bwu._abi8
  local loops, held_polls, during = 0, 0, nil
  local script = { manifest = { name = "n3 pause", version = "1" } }
  function script.on_loop(ctx)
    loops = loops + 1
    if loops == 2 then
      rec.gui_pause(true)            -- the GUI's pause button, between iterations
      local real = ctx.waits._sleep
      ctx.waits._sleep = function(ms)
        held_polls = held_polls + 1
        if held_polls == 3 then during = loops; rec.gui_pause(false) end
        return real(ms)
      end
    end
    if loops == 4 then return -1 end
    return 0
  end
  bot.run(script, { game = game })
  assert_(during == 2 and loops == 4, "held at loop 2 for three polls, then ran on: " .. tostring(during))
end

-- Settings -------------------------------------------------------------------------------------------

T["n3 settings: the saved map sits under the config, save() reaches the store as strings"] = function(assert_)
  -- Failure: the saved map ignored, a saved declared key beating the config, a non-string sent,
  -- or a refused save reported as kept.
  attach({}, { saved = { route = "south", n = "7" } })
  fake_bwu.with_ctl(bwu, { mode = "worker" })
  local config = { n = 3 }
  local s = Settings.new(function() return config end)
  assert_(s:get("route") == "south" and s:get("n") == 3, "saved below the config")
  s:put("trips", 12)
  s:put_boolean("banked", true)
  assert_(s:save() == true, "saved")
  local sent = bwu._abi8.saves[1]
  assert_(sent.route == "south" and sent.n == "3" and sent.trips == "12" and sent.banked == "true",
          "the whole map as strings")
end

T["n3 settings: a refused save is false with the reason; no store outside a worker"] = function(assert_)
  attach({}, { save_code = -1 + 1 })          -- CTL_SAVE_FAILED (0)
  fake_bwu.with_ctl(bwu, { mode = "worker" })
  local ok, why = Settings.new(function() return {} end):save()
  assert_(ok == false and why == "disk full", "refused")
  attach({}, {})
  fake_bwu.with_ctl(bwu, { mode = "cli" })
  local ok2, why2 = Settings.new(function() return {} end):save()
  assert_(ok2 == false and why2 == "unsupported" and #bwu._abi8.saves == 0, "CLI: no store")
end

-- Objects ---------------------------------------------------------------------------------------------

T["n3 objects: the animation filter matches a loc playing an animation"] = function(assert_)
  -- Failure: a fire not found by its animation (the row lost it), or a still loc counted.
  local game = S.attach({ locs_ = {
    { id = 7000, resolved_id = 7000, tile = { x = 3201, y = 3200, plane = 0 }, shape = 10, rotation = 0,
      flags = 0, animation_id = 2484 },
    { id = 7001, resolved_id = 7001, tile = { x = 3202, y = 3200, plane = 0 }, shape = 10, rotation = 0,
      flags = 0, animation_id = -1 },
  } })
  local fires = Entities.objects(game):with_animation(2484):all()
  assert_(#fires == 1 and fires[1].id == 7000, "the animating loc")
  local still = Entities.objects(game):not_animating():all()
  assert_(#still == 1 and still[1].id == 7001, "the still loc")
end

return T
