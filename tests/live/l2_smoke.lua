-- Live smoke for the J1-J3 composition port: bwu_host --lua tests/live/l2_smoke.lua
--
-- Needs a client in the world (host ABI 7, an NXTCache.dll with the quest decoder fix for the
-- quest reads). It toggles one prayer on and off, opens HUD tabs, and, when a bank booth or chest
-- is within BWU_SMOKE_BANK_RANGE tiles, walks there, deposits one Logs by name and withdraws it
-- back. Run it only on a disposable character. No camera, no desktop input: every action goes
-- through the agent's action queue. It never logs out.
-- Environment:
--   BWU_SMOKE_PID         the client pid (default: the first discovered client)
--   BWU_SMOKE_OUT         a file this script writes its results to, one "key=value" per line
--   BWU_SMOKE_BANK_RANGE  how far (tiles) a bank may be for the bank step (default 40; 0 skips)
--   BWU_SMOKE_PRAYER      the prayer key to toggle (default TIERED_DEFENCE)
--   BWU_SMOKE_BANK_AT     "x,y,plane": walk there before the bank step, and back to the start
--                         tile after it (default: no walk)
--   BWU_SMOKE_QUEST_SCAN  scan quest ids 0..N and note the started and complete ones (default 0)
-- Raises (bwu_host exits non-zero) on any mismatch.
--
-- `botwithus` comes from package.path: set LUA_PATH to this repo ("<repo>/?.lua;<repo>/?/init.lua;;").

local bot = require("botwithus")
assert(bot.Prayers and bot.Hud, "the botwithus on package.path has no composition modules: set LUA_PATH to this repo")

local out_path = assert(os.getenv("BWU_SMOKE_OUT"), "BWU_SMOKE_OUT not set")
local pid = math.tointeger(tonumber(os.getenv("BWU_SMOKE_PID") or ""))
local bank_range = math.tointeger(tonumber(os.getenv("BWU_SMOKE_BANK_RANGE") or "40"))
local prayer_key = os.getenv("BWU_SMOKE_PRAYER") or "TIERED_DEFENCE"
local lines = {}

local function note(key, value)
  lines[#lines + 1] = key .. "=" .. tostring(value)
  local f = assert(io.open(out_path, "w"))
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
  print("SMOKE " .. key .. "=" .. tostring(value))
end

local function check(label, cond, detail)
  if not cond then error(label .. ": " .. tostring(detail), 2) end
end

local game = bot.Game.attach(pid)
local wait = bot.Timing.for_game(game)
assert(game:refresh())
check("in the world", game:game_state().game_state == 30, game:game_state().game_state)
local me = game:self()
note("start_tile", tostring(me.tile))

-- ---- a condition wait, counted in server ticks ----
local t0 = game:server_tick()
local target = t0 + 3
local met = wait:until_(function() return game:server_tick() >= target end, 5000)
note("wait_until_ticks", ("met=%s from=%d to=%d"):format(tostring(met), t0, game:server_tick()))
check("delay_until met", met, "tick did not advance 3 in 5 s")
local t1 = game:server_tick()
note("delay_ticks_2", ("ok=%s ticks=%d"):format(tostring(wait:ticks(2)), game:server_tick() - t1))
note("wait_timeout_false", tostring(wait:until_(function() return false end, 300) == false))

-- ---- an Area-filtered query ----
local yard = bot.Area.around(me.tile, 8)
local inside = bot.objects(game):inside(yard):count()
local outside = bot.objects(game):outside(yard):count()
note("objects_inside_8", inside)
note("objects_outside_8", outside)
check("area split", inside + outside == bot.objects(game):count(), "inside + outside != all")
local npcs_in = bot.npcs(game):inside(bot.Area.circle(me.tile, 15)):count()
note("npcs_inside_circle_15", npcs_in)
local named = bot.objects(game):with_option("Bank"):nearest(me.tile)
note("nearest_bank_object", named and (named.id .. "@" .. tostring(named.tile)) or "none")

-- ---- skills, xp tracker ----
local tracker = bot.Xp.tracker(game, "woodcutting")
local wc = game:skill("woodcutting")
note("woodcutting", ("xp=%d level=%d virtual=%d next=%d"):format(wc.xp, wc.level, bot.Xp.virtual_level(wc),
  bot.Xp.xp_to_next_level(wc)))
note("xp_tracker", ("gained=%d per_hour=%d elapsed_ms=%d"):format(tracker:xp_gained(), tracker:xp_per_hour(),
  tracker:elapsed_ms()))

-- ---- quests ----
local quests = bot.Quests.new(game)
for _, id in ipairs({ 257, 6, 132, 258 }) do
  local s = quests:status(id)
  local var = s.variable and (s.variable.kind .. " " .. s.variable.id .. " " .. s.variable.start_value
    .. ".." .. s.variable.end_value) or "none"
  note("quest_" .. id, ("resolved=%d name=%q stage=%s progress=%d var=%s"):format(s.quest_id, s.name,
    s.stage, s.progress, var))
end
check("stub 6 resolves to 257", quests:status(6).quest_id == 257, quests:status(6).quest_id)
local scan = math.tointeger(tonumber(os.getenv("BWU_SMOKE_QUEST_SCAN") or "0"))
if scan > 0 then
  local started, complete, unknown, seen = {}, {}, 0, {}
  for id = 0, scan do
    local s = quests:status(id)
    if s.stage == bot.Quests.UNKNOWN then unknown = unknown + 1
    elseif not seen[s.quest_id] then
      seen[s.quest_id] = true
      local row = ("%d %q %s=%d (%d..%d)"):format(s.quest_id, s.name, s.variable.kind, s.progress,
        s.variable.start_value, s.variable.end_value)
      if s.stage == bot.Quests.COMPLETE then complete[#complete + 1] = row
      elseif s.stage == bot.Quests.STARTED then started[#started + 1] = row end
    end
  end
  note("quests_complete", table.concat(complete, "; "))
  note("quests_started", table.concat(started, "; "))
  note("quests_unknown_ids", unknown)
end

-- ---- action bar (read only: slot 1 holds an ability from an earlier test; it stays) ----
local bar = bot.ActionBar.new(game)
note("actionbar_active", bar:active_bar())
for i, s in ipairs(bar:slots()) do
  if s.kind ~= "empty" then
    local detail = s.kind == "ability" and (s.ability.name .. " struct " .. s.ability.struct_id)
      or s.kind == "item" and ("item " .. s.item_id) or ("type " .. tostring(s.type_code) .. " id " .. tostring(s.id))
    note("actionbar_slot_" .. i, s.kind .. " " .. detail)
    if s.kind == "ability" then
      local cd = bar:cooldown(s.ability)
      note("actionbar_slot_" .. i .. "_cooldown", ("known=%s start=%d end=%d now=%d"):format(tostring(cd.known),
        cd.start_cycle, cd.end_cycle, game:clocks().game_cycle))
    end
  end
end
local gcd = bar:global_cooldown()
note("global_cooldown", ("start=%d end=%d span=%d"):format(gcd.start_cycle, gcd.end_cycle, gcd.end_cycle - gcd.start_cycle))

-- ---- combat state, buffs, summoning, lodestones (reads) ----
local combat = bot.Combat.new(game)
note("combat", ("life=%d/%d prayer=%d summoning=%d adrenaline=%d in_combat=%s target=%s"):format(
  combat:life_points(), combat:max_life_points(), combat:prayer_points(), combat:summoning_points(),
  combat:adrenaline(), tostring(combat:is_in_combat()), combat:target().kind))
note("own_name_known", tostring(combat:name() ~= nil))
note("buffs_active", #bot.Buffs.new(game):active())
note("familiar", tostring(bot.Summoning.new(game):has_familiar()))
local unlocked = {}
for _, l in ipairs(bot.Lodestones.new(game):unlocked()) do unlocked[#unlocked + 1] = l.key end
note("lodestones_unlocked", table.concat(unlocked, ","))

-- ---- HUD tabs: open each and read the state back from its button ----
local hud = bot.Hud.new(game)
for _, tab in ipairs({ bot.Hud.SKILLS, bot.Hud.EQUIPMENT, bot.Hud.BACKPACK }) do
  local before = hud:is_open(tab)
  local pressed = hud:open(tab)
  local after = wait:until_(function() return hud:is_open(tab) end, 3000)
  note("hud_" .. tab.name, ("slot=%d before=%s pressed=%s open_after=%s"):format(hud:slot_of(tab), tostring(before),
    tostring(pressed), tostring(after)))
  check("hud " .. tab.name .. " open", after, "did not come to the front")
end

-- ---- prayer: open the window, toggle on, read back, toggle off ----
local prayers = bot.Prayers.new(game)
note("prayer_points", ("%d/%d book=%s"):format(prayers:points(), prayers:max_points(), prayers:active_book()))
local info = prayers:info(prayer_key)
note("prayer_info", info and ("%s struct %d on %d off %d"):format(info.name, info.struct_id, info.graphic_on,
  info.graphic_off) or "nil")
if prayers:points() > 0 and info then
  prayers:open_window()
  check("prayer window", wait:until_(function() return prayers:is_window_open() end, 3000), "not open")
  local was = prayers:is_active(prayer_key)
  check("toggle on sent", prayers:toggle(prayer_key), "no button")
  local on = wait:until_(function() return prayers:is_active(prayer_key) ~= was end, 3000)
  note("prayer_toggle_1", ("was=%s now=%s"):format(tostring(was), tostring(prayers:is_active(prayer_key))))
  check("prayer flipped", on, "state did not change")
  check("toggle back sent", prayers:toggle(prayer_key), "no button")
  local back = wait:until_(function() return prayers:is_active(prayer_key) == was end, 3000)
  note("prayer_toggle_2", ("back=%s now=%s"):format(tostring(back), tostring(prayers:is_active(prayer_key))))
  check("prayer restored", back, "state did not come back")
else
  note("prayer_toggle", "skipped: no prayer points or no prayer info")
end

-- ---- bank by name, when a bank is within reach ----
local bank_at = os.getenv("BWU_SMOKE_BANK_AT")
local start_tile = game:self().tile

local function bank_step()
  if bank_range == 0 then return "skipped: BWU_SMOKE_BANK_RANGE=0" end
  if bank_at then
    local x, y, plane = bank_at:match("^(%d+),(%d+),(%d+)$")
    local arrived = game:walk(tonumber(x), tonumber(y), tonumber(plane), 2)
    game:refresh()
    note("walk_to_bank", ("to=%s arrived=%s at=%s"):format(bank_at, tostring(arrived), tostring(game:self().tile)))
  end
  local here = game:self().tile
  local booth, d = bot.objects(game):with_option("Bank"):nearest(here)
  if booth == nil or d > bank_range then return "skipped: no bank object within " .. bank_range end
  local logs_before = game:backpack():count(bot.Match.exact("Logs"))
  if logs_before == 0 then return "skipped: no Logs in the backpack" end
  local bank = bot.Bank.new(game)
  if d > bot.Bank.OPEN_RADIUS then
    local arrived = game:walk(booth.tile.x, booth.tile.y, booth.tile.plane, 3)
    game:refresh()
    note("bank_walk", ("to=%s arrived=%s"):format(tostring(booth.tile), tostring(arrived)))
  end
  check("bank open sent", bank:open(), "no booth or banker in range")
  check("bank opened", wait:until_(function() return bank:is_open() end, 15000), "bank did not open")
  note("bank_mode", ("withdraw=%s transfer=%s"):format(bank:withdraw_mode(), bank:transfer_mode().name))
  check("deposit sent", bank:deposit("Logs", bot.Bank.ONE), "no Logs")
  check("deposited", wait:until_(function() return game:backpack():count(bot.Match.exact("Logs")) == logs_before - 1 end,
    5000), "count did not drop")
  check("withdraw sent", bank:withdraw("Logs", bot.Bank.ONE), "no Logs in the bank")
  check("withdrawn", wait:until_(function() return game:backpack():count(bot.Match.exact("Logs")) == logs_before end,
    5000), "count did not come back")
  bank:close()
  return ("ok logs=%d -> %d -> %d"):format(logs_before, logs_before - 1, logs_before)
end
note("bank_by_name", bank_step())
if bank_at then
  local back = game:walk(start_tile.x, start_tile.y, start_tile.plane, 0)
  game:refresh()
  note("walk_back", ("arrived=%s at=%s"):format(tostring(back), tostring(game:self().tile)))
end

note("end_tile", tostring(game:self().tile))
note("result", "ok")
game:detach()
