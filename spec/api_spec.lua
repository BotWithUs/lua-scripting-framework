-- spec/api_spec.lua -- unit tests for the Lua API, driven by the fake bwu surface.
-- No game client, no native host. Run via: scripts/test.ps1  (or any lua 5.4 + run.lua)

local fake_bwu = require("spec.fake_bwu")
local Tile     = require("botwithus.tile")
local bot      = require("botwithus")

local T = {}  -- test registry: name -> fn

T["tile chebyshev distance (diagonal == 1)"] = function(assert_)
  local a = Tile.new(3200, 3200, 0)
  assert_(a:distance({ x = 3201, y = 3201, plane = 0 }) == 1, "diagonal step is distance 1")
  assert_(a:distance({ x = 3205, y = 3200, plane = 0 }) == 5, "5 tiles east is 5")
  assert_(a:distance({ x = 3200, y = 3200, plane = 1 }) == math.huge, "other plane is unreachable straight")
end

T["protocol version comes from the surface"] = function(assert_)
  _G.bwu = fake_bwu.new()
  assert_(bot.protocol_version() == 21, "surface reports v21")
end

T["game facade decodes self into a Tile"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local g = bot.Game.attach()
  local me = g:self()
  assert_(getmetatable(me.tile) == Tile, "self.tile is a Tile")
  assert_(tostring(me.tile) == "(3200,3200,0)", "self tile is (3200,3200,0)")
  assert_(me.combat_level == 126, "combat level threads through")
end

T["only server_tick is exposed for pacing; clocks are distinct spaces"] = function(assert_)
  _G.bwu = fake_bwu.new({ tick = 1000 })
  local g = bot.Game.attach()
  local c = g:clocks()
  assert_(c.server_tick ~= c.game_cycle, "server_tick and game_cycle are different numbers")
  assert_(c.publish_seq > c.game_cycle, "publish_seq is its own space, not derived from cycle")
end

T["npc query: of_type + nearest"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local g = bot.Game.attach()
  local me = g:self()
  local q = bot.npcs(g):of_type(1234)
  assert_(q:count() == 2, "two npcs of type 1234")
  local nearest, d = q:nearest(me.tile)
  assert_(nearest.server_index == 55, "nearest 1234 is #55")
  assert_(d == 1, "nearest is one diagonal step away")
end

T["npc query: within radius is immutable-chainable"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local g = bot.Game.attach()
  local base = bot.npcs(g):of_type(1234)
  local close = base:within({ x = 3200, y = 3200, plane = 0 }, 2)
  assert_(base:count() == 2, "base query unchanged by chaining")
  assert_(close:count() == 1, "only #55 is within radius 2")
end

T["objects: hidden and deleted rows are dropped"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local g = bot.Game.attach()
  -- five rows on the surface, one hidden (0x1) and one deleted (0x4)
  assert_(bot.objects(g):count() == 3, "three visible objects")
  assert_(bot.objects(g):of_type(1276):count() == 1, "only the visible 1276 remains")
end

T["objects: shape and rotation reach the script"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local g = bot.Game.attach()
  local door = bot.objects(g):of_type(1530):first()
  assert_(door.shape == 0, "wall shape passes through")
  assert_(door.rotation == 3, "rotation passes through")
  local tree = bot.objects(g):of_type(1276):first()
  assert_(tree.shape == 10 and tree.rotation == 1, "each row keeps its own shape/rotation")
end

T["objects: a morph loc keeps its base id and carries the resolved one"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local g = bot.Game.attach()
  local range = bot.objects(g):of_type(125195):first()
  assert_(range ~= nil, "found by the base id the server sent")
  assert_(range.resolved_id == 125205, "resolved id rides alongside")
  assert_(bot.objects(g):of_type(125205):count() == 0, "of_type matches the base id only")
end

T["players: query + nearest"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local g = bot.Game.attach()
  assert_(bot.players(g):count() == 2, "two players")
  local p = bot.players(g):where(function(e) return e.server_index == 1001 end):first()
  assert_(p.combat_level == 90 and p.animation_id == 808, "player fields pass through")
  assert_(p.tile.x == 3210, "tile is a Tile")
  local nearest, d = bot.players(g):nearest({ x = 3209, y = 3200, plane = 0 })
  assert_(nearest.server_index == 1001, "nearest to (3209,3200) is #1001, not #1000")
  assert_(d == 1, "one step away")
end

T["walk_to queues a WALK (id 23, p1 1)"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local g = bot.Game.attach()
  g:walk_to(3210, 3212)
  local acts = rawget(_G, "bwu")._state.actions
  assert_(#acts == 1, "one action queued")
  assert_(acts[1].id == 23 and acts[1].p1 == 1, "it's a WALK with p1==1")
  assert_(acts[1].p2 == 3210 and acts[1].p3 == 3212, "target threads through")
end

T["path returns straight-line steps toward the goal"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local g = bot.Game.attach()
  local steps = g:path(3203, 3202, 0)
  assert_(#steps == 3, "max(|3|,|2|) == 3 steps")
  local last = steps[#steps]
  assert_(last.x == 3203 and last.y == 3202, "final step lands on the goal")
end

T["script lifecycle: on_start/on_loop/on_stop run, paced, bounded"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local seen = { start = 0, loop = 0, stop = 0 }
  bot.run({
    manifest = { name = "T", author = "spec", version = "0" },
    on_start = function() seen.start = seen.start + 1 end,
    on_loop  = function() seen.loop = seen.loop + 1; return 1 end,
    on_stop  = function() seen.stop = seen.stop + 1 end,
  }, { max_iters = 4 })
  assert_(seen.start == 1, "on_start once")
  assert_(seen.loop == 4, "on_loop bounded to 4 iters")
  assert_(seen.stop == 1, "on_stop once")
end

T["walk: executor call forwards goal+radius and reports arrival"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local g = bot.Game.attach()
  local arrived, err = g:walk(3165, 3486, 0, 3)
  assert_(arrived == true, "walk reports arrival")
  assert_(err == nil, "no error on arrival")
  local walks = rawget(_G, "bwu")._state.walks
  assert_(#walks == 1, "one executor walk issued")
  assert_(walks[1].x == 3165 and walks[1].y == 3486 and walks[1].plane == 0, "goal threads through")
  assert_(walks[1].radius == 3, "radius threads through")
  assert_(g:self().tile:equals({ x = 3165, y = 3486, plane = 0 }), "player ends at the goal")
end

T["walk: non-arrival returns (false, err); cancel reaches the surface"] = function(assert_)
  _G.bwu = fake_bwu.new({ walk_arrives = false })
  local g = bot.Game.attach()
  local arrived, err = g:walk(3165, 3486, 0, 1)
  assert_(arrived == false, "walk reports non-arrival")
  assert_(err ~= nil, "an error message is returned")
  g:walk_cancel()
  assert_(rawget(_G, "bwu")._state.walk_cancelled == true, "walk_cancel reached the surface")
end

T["script stops on negative delay"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local loops = 0
  bot.run({
    manifest = {},
    on_loop = function() loops = loops + 1; return loops >= 2 and -1 or 1 end,
  }, { max_iters = 100 })
  assert_(loops == 2, "returning -1 stopped the loop at 2")
end

T["facing: npc rows carry orientation, compass point and degrees"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local g = bot.Game.attach()
  local npcs = g:npcs()
  assert_(npcs[1].orientation == 12288 and npcs[1].facing == "EAST", "raw 12288 faces east")
  assert_(npcs[1].facing_degrees == 90, "east is 90 degrees")
  assert_(npcs[2].orientation == -1, "unknown stays -1")
  assert_(npcs[2].facing == nil and npcs[2].facing_degrees == nil, "unknown has no point, no bearing")
end

T["facing: a read-back one unit short is the same facing"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local g = bot.Game.attach()
  local npc = g:npcs()[3]
  assert_(npc.orientation == 8191, "fixture reads back one short of north")
  assert_(require("botwithus.orientation").is_same_facing(npc.orientation, 8192), "same facing as north")
  assert_(npc.facing == "NORTH", "and it buckets to north")
end

T["facing: self and players carry it too"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local g = bot.Game.attach()
  assert_(g:self().facing == "WEST", "self faces west")
  local p = bot.players(g):where(function(e) return e.server_index == 1001 end):first()
  assert_(p.facing == "SOUTH" and p.facing_degrees == 180, "raw 0 is south, 180 degrees")
end

-- Run log (bwu.runlog_*) -------------------------------------------------------------------

local function failing_script(fail_in, at_iteration)
  local s = { manifest = { name = "Crashy", version = "1.2", author = "spec" }, loops = 0 }
  s.on_start = function() if fail_in == "on_start" then error("start broke") end end
  s.on_loop = function()
    s.loops = s.loops + 1
    if fail_in == "on_loop" and s.loops == at_iteration then error("loop broke") end
    return 1
  end
  s.on_stop = function() if fail_in == "on_stop" then error("stop broke") end end
  return s
end

local function run_capturing(script, opts)
  -- Through a Lua frame of this file, so the runner sees api_spec.lua as its caller.
  return pcall(function() bot.run(script, opts or { max_iters = 5 }) end)   -- not a tail call
end

T["runlog: a run opens with the manifest and pid, records state, and closes"] = function(assert_)
  local b = fake_bwu.with_runlog(fake_bwu.new())
  _G.bwu = b
  local ok = run_capturing(failing_script(nil))
  local rec = b._runlog
  assert_(ok, "a clean run does not raise")
  assert_(#rec.opens == 1, "one run opened")
  local o = rec.opens[1]
  assert_(o.name == "Crashy" and o.version == "1.2" and o.author == "spec", "manifest passed")
  assert_(o.pid == 4242, "the attached pid is passed (it gives the slot)")
  assert_(type(o.path) == "string" and o.path:find("api_spec.lua", 1, true), "the calling file is hashed")
  assert_(rec.crumbs[1] == "state STARTING->RUNNING" and rec.crumbs[2] == "state RUNNING->STOPPED",
          "state crumbs: " .. table.concat(rec.crumbs, " | "))
  assert_(#rec.crashes == 0, "no crash block")
  assert_(#rec.closes == 1 and rec.closes[1] == 8, "the run is closed")
end

T["runlog: an on_loop error is phase on_loop with its iteration and a raise-site traceback"] = function(assert_)
  local b = fake_bwu.with_runlog(fake_bwu.new())
  _G.bwu = b
  local ok, err = run_capturing(failing_script("on_loop", 3))
  local rec = b._runlog
  assert_(not ok and tostring(err):find("loop broke", 1, true), "the error is re-raised unchanged")
  assert_(#rec.crashes == 1, "one crash block")
  local c = rec.crashes[1]
  assert_(c.phase == "on_loop" and c.iteration == 3, "phase on_loop, iteration 3: " .. c.phase .. " " .. c.iteration)
  assert_(c.report:find("loop broke", 1, true) and c.report:find("stack traceback:", 1, true), "traceback text")
  assert_(c.report:find("api_spec.lua", 1, true), "the traceback reaches the failing script frame")
  assert_(rec.crumbs[#rec.crumbs] == "state RUNNING->ERROR", "the last crumb is the state change")
  assert_(#rec.closes == 1, "closed even after a crash")
end

T["runlog: an on_start error is phase on_start, not on_loop"] = function(assert_)
  local b = fake_bwu.with_runlog(fake_bwu.new())
  _G.bwu = b
  local ok = run_capturing(failing_script("on_start"))
  local c = b._runlog.crashes[1]
  assert_(not ok and c and c.phase == "on_start" and c.iteration == 0, "phase on_start, iteration 0")
end

T["runlog: an on_stop error is phase on_stop and is not re-raised"] = function(assert_)
  local b = fake_bwu.with_runlog(fake_bwu.new())
  _G.bwu = b
  local ok = run_capturing(failing_script("on_stop"))
  local c = b._runlog.crashes[1]
  assert_(ok, "on_stop failures stay swallowed, as before")
  assert_(c and c.phase == "on_stop" and c.report:find("stop broke", 1, true), "phase on_stop")
end

T["runlog: a second failure after the crash block becomes an ERROR line"] = function(assert_)
  local b = fake_bwu.with_runlog(fake_bwu.new())
  _G.bwu = b
  local s = failing_script("on_loop", 1)
  s.on_stop = function() error("stop also broke") end
  run_capturing(s)
  local rec = b._runlog
  assert_(#rec.crashes == 2 and rec.crashes[2].phase == "on_stop", "both offered to the sink")
  assert_(#rec.writes == 1 and rec.writes[1].level == 40 and rec.writes[1].msg:find("stop also broke", 1, true),
          "the refused second crash is kept as an ERROR line")
end

T["runlog: a surface without runlog_* runs exactly as before"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local ok, err = run_capturing(failing_script("on_loop", 2))
  assert_(not ok and tostring(err):find("loop broke", 1, true), "error still re-raised")
end

return T
