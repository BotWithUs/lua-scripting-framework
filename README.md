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
| `botwithus` | umbrella: `run`, `npcs`, `players`, `objects`, `Game`, `Tile`, `Actions`, `Variables` |
| `botwithus.game` | `Game.attach()`, `:self()`, `:npcs()`, `:players()`, `:objects()` (visible scenery with `shape` / `rotation` / `resolved_id`), `:clocks()`, `:walk_to()` (one hop), `:path()` (query), `:walk()` (full pathed walk that executes transitions), `:walk_cancel()`, `:read_varp(s)` / `:read_varbit(s)` / `:varp_state()` / `:varp()` / `:varp_long()` / `:varbit()` |
| `botwithus.variables` | the varp state names (`SET`, `DEFAULT`, `NO_SUCH_VARP`, `UNAVAILABLE`) |
| `botwithus.entities` | fluent queries: `:of_type()`, `:within()`, `:where()`, `:nearest()`, `:all()` |
| `botwithus.tile` | `Tile` with Chebyshev (8-directional) distance |
| `botwithus.actions` | action ids + builders (`walk_to`, `component_click`, …) |

## Walking: two styles

- `ctx.game:walk_to(x, y)` — queue **one** WALK hop. You write the per-tick loop (plan with
  `:path()`, step, repeat). Non-blocking; paces with `ctx:sleep_ticks`.
- `ctx.game:walk(x, y, plane, radius)` — a **full pathed walk** through the native executor:
  it plans, walks, re-plans, and **executes transitions** (doors, stairs, teleports, dialogue)
  until it arrives. **Blocks** for the whole route and returns `(arrived, err)`;
  `:walk_cancel()` stops it. See `examples/banker.lua`.

## Varps and varbits: decide on the state, not the value

Varps are set lazily by the server, so most have no client-side entry at all, and a value
alone can't tell you whether one is set: a set varp can hold `-1`, and so can a varp at its
default. Every read carries a `state` string:

```lua
local V = require("botwithus.variables")
local r = ctx.game:read_varp(3)          -- or :read_varps / :read_varbit / :read_varbits
if r.state == V.SET then ...             -- "set": r.value is the stored value
elseif r.state == V.DEFAULT then ...     -- "default_not_set_clientside": the default the game reads
elseif r.state == V.NO_SUCH_VARP then ...
else ... end                             -- "unavailable": lobby, entering the world, bad id, timeout
```

- `:varp(id)` / `:varps(ids)` / `:varbit(id)` return what the game reads: the stored value, the
  default when unset, or `-1` for no value. `:varp_long(id)` gives all 64 bits of a LONG varp,
  whose `value` is only the low 32.
- Defaults come from the game cache through the native host. If it can't confirm one (an older
  `NXTCache.dll`, or the cache still warming up just after attach), the read is still
  `"default_not_set_clientside"` with `value` `0` and `default_verified` false.
- A varbit takes its base variable's state and decodes the base's value, so a varbit over an
  unset base reads the base's default bits, exactly as the game does.

## Run an example

```powershell
scripts\run_example.ps1 examples\banker.lua   # needs bwu_host on PATH (or $env:BWU_HOST) + a live client
```

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
