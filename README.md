# lua-scripting-framework

The **Lua scripting API** for BotWithUs — an ergonomic, author-facing library for writing
game scripts in Lua. It is open source (MIT).

Scripts run inside the native hybrid host (`native-scripting-host`), which embeds a Lua
interpreter and installs one global, `bwu` — a flat surface onto the game (snapshot reads,
actions, pathing). This framework is a thin, idiomatic layer over that surface, so scripts
read like game logic rather than wire calls. The same surface backs the Python API
(`python-scripting-framework`); both languages are frontends on one native runtime.

```lua
local bot = require("botwithus")

local script = { manifest = { name = "Woodcutter", author = "you", version = "1.0" } }

function script.on_start(ctx)
  print("at " .. tostring(ctx.game:self().tile))
end

-- return a delay in SERVER TICKS, or a negative number to stop
function script.on_loop(ctx)
  local me   = ctx.game:self()
  local tree = bot.npcs(ctx.game):of_type(1234):nearest(me.tile)
  if not tree then return -1 end
  if me.tile:distance(tree.tile) > 1 then
    ctx.game:walk_to(tree.tile.x, tree.tile.y)
  end
  return 1
end

bot.run(script)
```

Run it: `bwu_host --lua examples/woodcutter.lua` (see `native-scripting-host`).

## The lifecycle

`on_start(ctx)` once → `on_loop(ctx)` repeatedly → `on_stop(ctx)` once. `on_loop` returns
a **delay in server ticks**; a negative return stops the script. This matches the Java and
C# hosts exactly.

## The one pacing rule

There are three clocks on the surface, and only one is for pacing: **`server_tick`**
(~0.6s). `ctx:sleep_ticks(n)` waits for `server_tick` to advance by `n` and nothing else.
`game_cycle` (~20ms) and `publish_seq` are exposed but are *not* timing clocks — they live
in different number spaces, and pacing off them once shipped a ~30× speed bug. The API
gives you `sleep_ticks`, not a millisecond timer, on purpose.

## Modules

| Module | What it gives you |
|---|---|
| `botwithus` | umbrella: `run`, `npcs`, `Game`, `Tile`, `Actions` |
| `botwithus.game` | `Game.attach()`, `:self()`, `:npcs()`, `:clocks()`, `:walk_to()`, `:path()` |
| `botwithus.entities` | fluent queries: `:of_type()`, `:within()`, `:where()`, `:nearest()`, `:all()` |
| `botwithus.tile` | `Tile` with Chebyshev (8-directional) distance |
| `botwithus.actions` | action ids + builders (`walk_to`, `component_click`, …) |

## Tests

No game client needed — the suite injects a fake `bwu` surface.

```powershell
scripts\test.ps1        # finds lua/lua5.4/luajit on PATH
# or directly:
lua spec\run.lua
```

## Layout

```
botwithus/   the library (pure Lua; no wire code)
examples/    runnable sample scripts
spec/        unit suite + fake_bwu surface + a tiny runner
```
