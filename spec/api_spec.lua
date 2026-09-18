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
  assert_(bot.protocol_version() == 19, "surface reports v19")
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

T["script stops on negative delay"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local loops = 0
  bot.run({
    manifest = {},
    on_loop = function() loops = loops + 1; return loops >= 2 and -1 or 1 end,
  }, { max_iters = 100 })
  assert_(loops == 2, "returning -1 stopped the loop at 2")
end

return T
