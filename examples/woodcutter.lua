-- examples/woodcutter.lua -- a minimal, runnable sample script.
--
-- Run under the native host:  bwu_host --lua examples/woodcutter.lua
-- (needs botwithus/ on package.path; see scripts/run_example.ps1)

local bot = require("botwithus")

local script = {
  manifest = { name = "Woodcutter", author = "example", version = "1.0.0" },
}

function script.on_start(ctx)
  local me = ctx.game:self()
  io.write(("woodcutter: starting at %s (cb %d)\n"):format(tostring(me.tile), me.combat_level))
end

-- Return a delay in SERVER TICKS. Here: find the nearest tree-ish npc, step toward it.
function script.on_loop(ctx)
  local me   = ctx.game:self()
  local tree = bot.npcs(ctx.game):of_type(1234):nearest(me.tile)
  if not tree then
    io.write("woodcutter: nothing nearby; stopping\n")
    return -1  -- negative == stop
  end
  local d = me.tile:distance(tree.tile)
  if d > 1 then
    ctx.game:walk_to(tree.tile.x, tree.tile.y)
    io.write(("woodcutter: walking toward %s (d=%d)\n"):format(tostring(tree.tile), d))
  else
    io.write(("woodcutter: chopping npc #%d\n"):format(tree.server_index))
  end
  return 1  -- one tick between iterations
end

function script.on_stop(ctx)
  io.write("woodcutter: stopped\n")
end

bot.run(script, { max_iters = 3 })  -- bound for the demo; drop for real runs
