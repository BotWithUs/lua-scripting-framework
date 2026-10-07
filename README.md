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

## Logging and run logs

Use `bwu.log` rather than `print`:

```lua
bwu.log.debug("checking bank at", tile)
bwu.log.warn("no food left")
```

`bwu.log.debug/info/warn/error` take any values (joined with spaces, like `print` with
tabs). Under `bwu_host` every run of a script writes one file under
`~/.botwithus/logs/scripts/<script-slug>/`, redacted before it reaches disk (account and
character names, emails, tokens, IPs, your user folder). It holds DEBUG and up: `bwu.log`,
`print`, `io.write` and `io.stderr:write`; the console shows INFO and up. When `bot.run`
stops on an error, the file ends with a crash block: the phase (`on_start`, `on_loop` with its
iteration, `on_stop`), the traceback taken where the error was raised, the innermost frame in
your code, and the last 200 host calls the script made. The native host owns the file and the
redaction; `bot.run` only tells it the phase. `io.stdout` / `io.stderr` are proxies under the
host, so `io.type(io.stderr)` is `nil` there. The host also loads every Lua file under a short
chunk name, so tracebacks read `myscript.lua:12` and `botwithus/script.lua:138` rather than a
full install path (which could carry your Windows user name). A script that finds its own
folder from `debug.getinfo(1, "S").source` only gets one when it was launched by a relative path.

## The one pacing rule

There are three clocks on the surface, and only one is for pacing: **`server_tick`**
(~0.6s). `ctx:sleep_ticks(n)` waits for `server_tick` to advance by `n` and nothing else.
`game_cycle` (~20ms) and `publish_seq` are exposed but are *not* timing clocks — they live
in different number spaces, and pacing off them once shipped a ~30× speed bug. The API
gives you `sleep_ticks`, not a millisecond timer, on purpose.

## Modules

| Module | What it gives you |
|---|---|
| `botwithus` | umbrella: `run`, `npcs`, `players`, `objects`, `Game`, `Tile`, `Actions`, `Input`, `clients`, `Variables` |
| `botwithus.game` | `Game.attach()`, `:self()`, `:npcs()`, `:players()`, `:objects()` (visible scenery with `shape` / `rotation` / `resolved_id`), `:open_ifaces()` (each open interface's `type` / `client_opened` / `is_modal`, plus the table total) / `:is_interface_open()` / `:modal_ifaces()` / `:is_modal_open()`, `:clocks()`, `:walk_to()` (one hop), `:path()` (query), `:walk()` (full pathed walk that executes transitions), `:walk_cancel()`, `:queue_actions()` (one round trip), `:varc_int()` / `:varc_string()`, `:read_varp(s)` / `:read_varbit(s)` / `:varp_state()` / `:varp()` / `:varp_long()` / `:varbit()` |
| `botwithus.variables` | the varp state names (`SET`, `DEFAULT`, `NO_SUCH_VARP`, `UNAVAILABLE`) |
| `botwithus.entities` | fluent queries: `:of_type()`, `:within()`, `:where()`, `:nearest()`, `:all()` |
| `botwithus.clients` | client management: `clients.new()` -> `:accounts()`, `:launch()` (-> `:wait_attached()`), `:stop()`, `:clients()`, `:attach()` (once per process), events via `:poll()` / `:pump()` / `:wait_for()` / `:on()`, `:on_close_requested()` and `:ack_close()`. See [docs/CLIENTS.md](docs/CLIENTS.md) |
| `botwithus.tile` | `Tile` with Chebyshev (8-directional) distance |
| `botwithus.actions` | action ids + builders (`walk_to`, `component_click`, …) |
| `botwithus.input` | the game's input dialog: `Input.dialog(game)` with `:mode()`, `:is_open()`, `:text()`, `:enter_amount(3 \| "10k")` / `:enter_text(name)` (type and submit), `:submit()`, `:cancel()`, `:backspace(n)`, `:clear()` (false when the dialog is closed or in the wrong mode; text it would reject raises before anything is sent). Low level: `KeyStroke` with `ENTER` / `BACKSPACE` / `ESCAPE`, `fire_keys`, `type_text`, `component_trigger` |

## Managing clients

A **management script** launches and stops game clients through the BotWithUs launcher's
background service, and can answer when the launcher asks to close for a data update:

```lua
local cm     = bot.clients.new()
local launch = assert(cm:launch(cm:accounts()[1].id))
local game   = assert(launch:wait_attached(300))   -- attaches once the client is injected
cm:stop(launch.client_id, "graceful")
```

Lua scripts have one thread, so events are read with `cm:poll()` / `cm:pump()` /
`cm:wait_for()`, and handlers run only inside those calls. With no close handler, nothing is
answered and the script keeps running. See [docs/CLIENTS.md](docs/CLIENTS.md) and
`examples/manager.lua`.

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
# or with the host's own Lua 5.4, when no lua is installed:
bwu_host --lua spec\run.lua
```

`bwu_host` needs the Python runtime it was built against on `PATH`, because it embeds both
languages.

## Layout

```
botwithus/   the library (pure Lua; no wire code)
examples/    runnable sample scripts
spec/        unit suite + fake_bwu surface + a tiny runner
```
