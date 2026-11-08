-- examples/woodcutter.lua -- a minimal sample script: find the nearest tree and chop it.
--
-- Run under the native host:  bwu_host --lua examples/woodcutter.lua
-- (needs botwithus/ on package.path; see scripts/run_example.ps1)
--
-- Plugin-style: the file returns its script table, so a script loader can pick it up
-- without running it. A loader that calls the file with any argument (as `require` does)
-- only gets the table. Run directly, the host calls it with none, and it runs itself.

local bot = require("botwithus")

-- Trees are scenery (locs), not NPCs. Loc ids from the game's own names: TREE, LIGHTTREE
-- and TREE2, plain trees whose first option is "Chop down".
local TREE_IDS = { [1276] = true, [1277] = true, [1278] = true }

-- The agent's "object option 1" action: p1 = loc id, p2 / p3 = the loc's tile. Like a click
-- on the tree, it makes the client walk the player up to it first, so there is no walking
-- step here (a tree covers several tiles, and its tile is only one corner of them).
local OBJECT_OPTION_1 = 3
local CHOP_TICKS = 5   -- give the chop a few ticks before looking again

local script = {
  manifest = { name = "Woodcutter", author = "example", version = "1.0.0" },
}

function script.on_start(ctx)
  local me = ctx.game:self()
  io.write(("woodcutter: starting at %s (cb %d)\n"):format(tostring(me.tile), me.combat_level))
end

-- Return a delay in SERVER TICKS, or a negative number to stop.
function script.on_loop(ctx)
  local me   = ctx.game:self()
  local tree = bot.objects(ctx.game):where(function(o) return TREE_IDS[o.id] end):nearest(me.tile)
  if not tree then
    io.write("woodcutter: no tree nearby; stopping\n")
    return -1
  end
  ctx.game:do_action({ id = OBJECT_OPTION_1, p1 = tree.id, p2 = tree.tile.x, p3 = tree.tile.y })
  io.write(("woodcutter: chopping tree %d at %s\n"):format(tree.id, tostring(tree.tile)))
  return CHOP_TICKS
end

function script.on_stop(ctx)
  io.write("woodcutter: stopped\n")
end

if select("#", ...) == 0 then
  bot.run(script, { max_iters = 3 })  -- bound for the demo; drop max_iters for real runs
end

return script
