-- Live smoke for the host ABI 6 calls: bwu_host --lua tests/live/h1n_smoke.lua
--
-- Written against this framework's API (Game, botwithus.worlds, botwithus.target). Needs a client
-- in the world whose agent has the ABI 6 RPCs (1.1.0 release or later), and a bwu_host at ABI 6. It changes
-- world once and uses one backpack item on another, so run it only on a disposable character.
-- Environment:
--   BWU_SMOKE_PID        the client pid (default: the first discovered client)
--   BWU_SMOKE_OUT        a file this script writes its results to, one "key=value" per line
--   BWU_SMOKE_HOP_WORLD  the world to hop to (default: the first listed world that is not the
--                        current one, whose flags carry no bit but members, and whose members
--                        bit fits the account)
--   BWU_SMOKE_SKIP_HOP   "1" to leave the world alone
--   BWU_SMOKE_USE        "<item id>:<item id>" to use on each other (default "946:1511", knife on logs)
-- Raises (bwu_host exits non-zero) on any mismatch.
--
-- `botwithus` comes from package.path: set LUA_PATH to this repo ("<repo>/?.lua;<repo>/?/init.lua;;").

local bot = require("botwithus")
assert(bot.Worlds and bot.Target, "the botwithus on package.path has no worlds/target: set LUA_PATH to this repo")

local out_path = assert(os.getenv("BWU_SMOKE_OUT"), "BWU_SMOKE_OUT not set")
local pid = math.tointeger(tonumber(os.getenv("BWU_SMOKE_PID") or ""))
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

local function sleep_ms(ms)
  local deadline = os.clock() + ms / 1000
  while os.clock() < deadline do end
end

local game = bot.Game.attach(pid)
check("ABI 6 host", game:has_abi6_calls(), "no ABI 6 calls")
assert(game:refresh())
local gs = game:game_state()
note("game_state", gs.game_state)
check("in the world", gs.game_state == 30, gs.game_state)

local account = assert(game:account_info())
note("account_name", account.account_name)
note("is_member", account.is_member)

-- ---- reads ----
local offers = assert(game:ge_offers())
note("ge_slots", #offers)
note("ge_in_use", #bot.GrandExchange.in_use(offers))
check("eight GE slots", #offers == 8, #offers)

local list = assert(game:world_list())
local current = assert(game:current_world())
note("world_count", #list.worlds)
note("world_total", list.total)
note("world_current", current)
check("world list fetched", list.is_fetched, "empty")
local here = bot.Worlds.find(list, current)
check("current world listed", here ~= nil, current)
note("world_current_flags", string.format("0x%x", here.flags))
note("world_current_members", here.members)

local idle = assert(game:target_mode())
note("target_idle_active", idle.active)

local kids = assert(game:dynamic_children_with_sub(1473, 5))
note("backpack_children", #kids)
note("backpack_child_last_sub", kids[#kids] and kids[#kids].sub)

-- ---- world_to_screen of the own tile ----
local function project_self(tag)
  assert(game:refresh())
  local me = game:self()
  local r = assert(game:world_to_screen({ { x = me.tile.x, y = me.tile.y } }))
  local p = r.points[1]
  note(tag .. "_tile", tostring(me.tile))
  note(tag .. "_result", p.result)
  note(tag .. "_on_screen", p.on_screen)
  note(tag .. "_xy", tostring(p.x) .. "," .. tostring(p.y))
  if r.viewport then
    note(tag .. "_viewport", string.format("%d,%d %dx%d", r.viewport.x, r.viewport.y, r.viewport.width, r.viewport.height))
    if p.on_screen then
      check(tag .. " inside the viewport", p.x >= r.viewport.x and p.x < r.viewport.x + r.viewport.width
        and p.y >= r.viewport.y and p.y < r.viewport.y + r.viewport.height, p.x .. "," .. p.y)
    end
  end
  check(tag .. " own tile on screen", p.on_screen == true, p.result)
end
project_self("w2s")

-- ---- world hop ----
local function pick_world()
  local wanted = math.tointeger(tonumber(os.getenv("BWU_SMOKE_HOP_WORLD") or ""))
  if wanted then return wanted end
  for _, w in ipairs(list.worlds) do
    local only_members = (w.flags & ~bot.Worlds.FLAG_MEMBERS) == 0
    if w.id ~= current and only_members and w.population > 0 and (account.is_member or not w.members) then
      return w.id
    end
  end
  return nil
end

if os.getenv("BWU_SMOKE_SKIP_HOP") ~= "1" then
  local target = pick_world()
  check("a world to hop to", target ~= nil, "none eligible")
  note("hop_target", target)
  local r, code, detail = game:hop_world(target, 45000)
  local info = r or detail or {}
  note("hop_code", code)
  note("hop_started", info.started)
  note("hop_elapsed_ms", info.elapsed_ms)
  note("hop_game_state", info.game_state)
  check("hop arrived", r ~= nil, code)
  local after = assert(game:current_world())
  note("world_after_hop", after)
  check("current world is the target", after == target, after)
  -- Let the scene settle before the next reads. gameState is back at 30 before the scene has
  -- loaded: world_to_screen answers "unavailable" until it has (seen live, 951-4).
  for i = 1, 100 do
    assert(game:refresh())
    local me = game:self()
    if game:game_state().game_state == 30 and me.valid then
      local r = assert(game:world_to_screen({ { x = me.tile.x, y = me.tile.y } }))
      if r.points[1].result ~= "unavailable" then note("w2s_settle_polls", i); break end
    end
    sleep_ms(200)
  end
  project_self("w2s_after_hop")
end

-- ---- use item on item ----
local use = os.getenv("BWU_SMOKE_USE") or "946:1511"
local src_id, dst_id = use:match("^(%d+):(%d+)$")
src_id, dst_id = tonumber(src_id), tonumber(dst_id)
assert(game:refresh())
local bp = game:backpack()
local src, dst = bp:find(src_id), bp:find(dst_id)
check("source item in the backpack", src ~= nil, src_id)
check("target item in the backpack", dst ~= nil, dst_id)
note("use_src_slot", src.slot)
note("use_dst_slot", dst.slot)
local ok, code = game:use_item_on_item(src.slot, dst.slot)
note("use_result", ok)
note("use_code", code)
check("use queued", ok == true, code)
local cleared = false
for i = 1, 40 do
  local m = assert(game:target_mode())
  if not m.active then cleared = true; note("target_cleared_after_polls", i); break end
  sleep_ms(100)
end
note("target_cleared", cleared)
check("target mode cleared after the use", cleared, "still active")

note("done", 1)
game:detach()
