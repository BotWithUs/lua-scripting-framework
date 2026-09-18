-- examples/banker.lua -- walk to a bank with the native transition executor.
--
-- Run under the native host:  bwu_host --lua examples/banker.lua
-- (needs botwithus/ on package.path; see scripts/run_example.ps1)
--
-- The point of this example is `ctx.game:walk(...)`, which drives worldwalker's blocking
-- executor: it plans the route, walks it, re-plans as needed, and EXECUTES the transitions
-- along the way (doors, stairs, teleports, dialogue) -- one call from the player's current
-- tile to the goal. That is the difference from `walk_to`, which only queues a single hop
-- and leaves the pathing loop to you.

local bot  = require("botwithus")
local Tile = bot.Tile

-- Grand Exchange bank area (ground floor). Change to wherever you want to bank.
local BANK   = Tile.new(3165, 3486, 0)
local RADIUS = 3   -- "arrived" once within this many tiles of BANK

local script = {
  manifest = { name = "Banker", author = "example", version = "1.0.0" },
}

function script.on_start(ctx)
  local me = ctx.game:self()
  io.write(("banker: starting at %s, heading for the bank at %s\n")
    :format(tostring(me.tile), tostring(BANK)))
end

-- One loop turn = one full walk to the bank. The executor blocks until it arrives (or
-- fails), so there is no per-step loop to write; when it returns we are either there or done.
function script.on_loop(ctx)
  local me = ctx.game:self()
  if me.tile.plane == BANK.plane and me.tile:distance(BANK) <= RADIUS then
    io.write(("banker: at the bank (%s) -- would open it here\n"):format(tostring(me.tile)))
    return -1  -- negative == stop; the goal is reached
  end

  io.write("banker: walking to the bank via the executor (routes + runs doors/stairs)...\n")
  local arrived, err = ctx.game:walk(BANK.x, BANK.y, BANK.plane, RADIUS)
  if not arrived then
    io.write(("banker: walk did not arrive (%s); stopping\n"):format(tostring(err)))
    return -1
  end
  return 0  -- arrived: loop again to confirm and bank
end

function script.on_stop(ctx)
  io.write("banker: stopped\n")
end

-- max_iters bounds the demo; drop it for a real run.
bot.run(script, { max_iters = 3 })
