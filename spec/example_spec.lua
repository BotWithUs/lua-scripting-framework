-- spec/example_spec.lua -- examples/woodcutter.lua is plugin-style and finds trees as scenery.

local fake_bwu = require("spec.fake_bwu")
local bot      = require("botwithus")

local T = {}

local TREE = 1276   -- loc TREE

-- Load the example the way a loader would: called with an argument, so it must not run.
local function load_example()
  local path = package.searchpath("examples.woodcutter", package.path)
  assert(path, "examples/woodcutter.lua not on package.path")
  return assert(loadfile(path))("examples.woodcutter", path)
end

T["woodcutter returns its script table without running"] = function(assert_)
  _G.bwu = fake_bwu.new()
  local script = load_example()
  assert_(type(script) == "table" and type(script.on_loop) == "function", "a script table")
  assert_(script.manifest and script.manifest.name == "Woodcutter", "with a manifest")
  assert_(#_G.bwu._state.attaches == 0, "loading it attached to nothing")
end

-- The fake's self stands on (3200,3200,0).
local function run_once(locs)
  local b = fake_bwu.new({ locs_ = locs })
  _G.bwu = b
  local script = load_example()
  local delay = script.on_loop({ game = bot.Game.attach() })
  return delay, b._state.actions[#b._state.actions]
end

T["woodcutter walks to the nearest tree object"] = function(assert_)
  local delay, a = run_once({
    { id = 1277, tile = { x = 3201, y = 3200, plane = 0 }, flags = 0 },   -- a nearer loc, not TREE
    { id = TREE, tile = { x = 3205, y = 3200, plane = 0 }, flags = 0 },
  })
  assert_(delay == 1, "walking returns 1 tick")
  assert_(a.id == 23 and a.p2 == 3205 and a.p3 == 3200, "walks to the TREE, not the 1277")
end

T["woodcutter chops an adjacent tree with object option 1"] = function(assert_)
  local _, a = run_once({ { id = TREE, tile = { x = 3201, y = 3201, plane = 0 }, flags = 0 } })
  assert_(a.id == 3 and a.p1 == TREE and a.p2 == 3201 and a.p3 == 3201, "Object1 on the tree")
end

T["woodcutter stops when no tree is visible"] = function(assert_)
  local delay = run_once({})
  assert_(delay < 0, "negative delay stops")
end

return T
