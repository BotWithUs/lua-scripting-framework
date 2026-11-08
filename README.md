# lua-scripting-framework

The **Lua scripting API** for BotWithUs — an ergonomic, author-facing library for writing
game scripts in Lua. It is open source (MIT) and targets **Lua 5.4** (the version the native
host embeds); LuaJIT and Lua 5.1-5.3 are not supported.

Scripts run inside the native hybrid host (`native-scripting-host`), which embeds a Lua
interpreter and installs one global, `bwu` — a flat surface onto the game (snapshot reads,
actions, pathing). This framework is a thin, idiomatic layer over that surface, so scripts
read like game logic rather than wire calls. The same surface backs the Python API
(`python-scripting-framework`); both languages are frontends on one native runtime.

```lua
local bot = require("botwithus")

local TREE = 1276   -- loc TREE: trees are scenery objects, not NPCs

local script = { manifest = { name = "Woodcutter", author = "you", version = "1.0" } }

function script.on_start(ctx)
  print("at " .. tostring(ctx.game:self().tile))
end

-- return a delay in SERVER TICKS, or a negative number to stop
function script.on_loop(ctx)
  local me   = ctx.game:self()
  local tree = bot.objects(ctx.game):of_type(TREE):nearest(me.tile)
  if not tree then return -1 end
  -- object option 1 ("Chop down"): p1 = loc id, p2 / p3 = its tile. Like a click, it makes
  -- the client walk the player to the tree first.
  ctx.game:do_action({ id = 3, p1 = tree.id, p2 = tree.tile.x, p3 = tree.tile.y })
  return 5
end

-- Run directly (the host calls the file with no arguments), it runs itself; a loader that
-- calls the file with an argument, as `require` does, just gets the table.
if select("#", ...) == 0 then bot.run(script) end
return script
```

Run it: `bwu_host --lua examples/woodcutter.lua` (see `native-scripting-host`). A script file
**returns its script table**, so a script loader can list it without running it. The GUI is
such a loader (see *Running under the GUI* below).

## The lifecycle

`on_config_update(ctx, config)` with the initial settings → `on_start(ctx)` once →
`on_loop(ctx)` repeatedly → `on_stop(ctx)` once. `on_loop` returns a **delay in server
ticks**; a negative return stops the script. This matches the Java and C# hosts exactly.
Only `on_loop` is required.

**Stopping.** When the GUI stops a run, `ctx:stopping()` turns `true`, `ctx:sleep_ticks(n)`
returns `false` at once (it returns `true` when the ticks passed), no further `on_loop` runs,
and `on_stop` runs. A script stuck in its own busy loop does not see the stop; after 10 s the
GUI ends the process. So wait with `ctx:sleep_ticks`, and check `ctx:stopping()` inside any
long loop of your own. On the command line nothing stops a run and both behave as before.

## Settings (config fields)

A script declares its settings as `config_fields`, and the GUI shows them as a form:

```lua
local config = require("botwithus.config")

script.config_fields = {
  config.int_field("logs", "Logs per trip", 28, { min = 1, max = 28 }),
  config.choice_field("tree", "Tree", { "Tree", "Oak", "Willow" }, "Oak"),
  config.bool_field("bank", "Bank the logs", true),
  config.string_field("note", "Note", "", { max_len = 64 }),
  config.item_id_field("food", "Food"),   -- default -1: no item
}

function script.on_config_update(ctx, cfg)
  -- cfg holds every field: { logs = 28, tree = "Oak", bank = true, note = "", food = -1 }
end
```

`config_fields` may also be a function `config_fields(script)` returning the list; the
helpers just build plain tables with the keys `key`, `kind`, `label`, `default`,
`description`, and per kind `min` / `max` / `step`, `max_len` or `options`.
`on_config_update(ctx, config)` is called with the full set once before `on_start`, and again
between iterations whenever the user changes a setting; `ctx.config` always holds the set in
force (a new table each time). On the command line the script gets the defaults.

The rules are stricter than the Java host's in four places, and a script that breaks one is
refused before it runs: a `choice` default must be one of its options, a `choice` needs at
least one option, an `item_id` default must be `-1` or more, and a `string` default over 256
bytes needs a larger `max_len`. An invalid saved value is replaced by the field's default.

The manifest is `{ name, version, author, description, category }`. `name` defaults to the
file name, `version` to `"1.0"`, `author` and `description` to `""`. `category` is optional;
use one of the Java host's category names (`Skilling`, `Combat`, `Woodcutting`, ...) to group
the script in the GUI.

## Running under the GUI

`bwu_host` with no arguments opens the GUI. It lists the `.lua` files in
`~/.botwithus/scripts/lua` and runs each one in its own worker process against the client you
pick. To list a script it **loads the file** as `chunk(modname, path)`, so:

- a **plugin** returns its script table, and the GUI shows its manifest and settings and
  drives its lifecycle itself;
- a file that returns anything else is **self-running**: the GUI lists it by its file name
  with no settings, and runs it like the command line does, with zero arguments. Its
  `Game.attach()` / `bot.run` attach to the client the GUI picked. Inside a GUI run, `bot.run`
  ignores `max_iters` (with one info line in the log) and runs until `on_loop` ends it, the
  client exits or the GUI stops it.

Loading a file to list it runs its top level, so keep the self-run under
`if select("#", ...) == 0 then ... end`, as every example does. Attaching to a client while the
file is being listed fails with `attach during load: guard the self-run`. `print`, `io.write`
and `bwu.log` output shows in the GUI's log view as well as in the run log.

The entry points the host calls are in `botwithus.worker` (`describe(path)`,
`run(path, client_pid)`); scripts do not call them.

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
| `botwithus` | umbrella: `run`, `npcs`, `players`, `objects`, `Game`, `Tile`, `Actions`, `Events`, `Input`, `clients`, `Variables` |
| `botwithus.game` | `Game.attach()`, `:self()`, `:npcs()`, `:players()`, `:objects()` (visible scenery with `shape` / `rotation` / `resolved_id`), `:open_ifaces()` (each open interface's `type` / `client_opened` / `is_modal`, plus the table total) / `:is_interface_open()` / `:modal_ifaces()` / `:is_modal_open()`, `:clocks()`, `:walk_to()` (one hop), `:path()` (query), `:walk()` (full pathed walk that executes transitions), `:walk_cancel()`, `:queue_actions()` / `:try_queue_actions()` (one round trip, all or nothing), `:poll_events()`, `:schedule_break(seconds)` / `:interrupt_break()`, `:varc_int()` / `:varc_string()`, `:read_varp(s)` / `:read_varbit(s)` / `:varp_state()` / `:varp()` / `:varp_long()` / `:varbit()`, `:overhead_text(kind, index)` / `:headbars(kind, index)` / `:hint_arrows()` (each nil, code on refusal). Player and self rows carry `server_tile` beside the visual `tile` |
| `botwithus.config` | settings fields: `int_field`, `string_field`, `bool_field`, `choice_field`, `item_id_field`, plus `validate_fields`, `validate_manifest`, `defaults` |
| `botwithus.worker` | the GUI's entry points (`describe`, `run`); called by the host, not by scripts |
| `botwithus.variables` | the varp state names (`SET`, `DEFAULT`, `NO_SUCH_VARP`, `UNAVAILABLE`) |
| `botwithus.entities` | fluent queries: `:of_type()`, `:within()`, `:where()`, `:nearest()`, `:all()` |
| `botwithus.clients` | client management: `clients.new()` -> `:accounts()`, `:launch()` (-> `:wait_attached()`), `:stop()`, `:clients()`, `:attach()` (once per process), events via `:poll()` / `:pump()` / `:wait_for()` / `:on()`, `:on_close_requested()` and `:ack_close()`. See [docs/CLIENTS.md](docs/CLIENTS.md) |
| `botwithus.tile` | `Tile` with Chebyshev (8-directional) distance |
| `botwithus.actions` | action ids + builders: `walk_to(x, y)`, `component_click(iface, comp [, option = 1 [, sub_slot = -1]])`, `dialogue_option(iface, comp)` |
| `botwithus.events` | agent event decoding for `Game:poll_events()`: `action_refused` (`reason_name` `no_target` / `anchor_timeout` / `no_opener`, `anchor_name`, `held_ms`) and `action_executed`; other types pass through as raw `{ type, body }` |
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

## Queueing actions: all or nothing

`ctx.game:queue_actions(list)` sends up to `bwu.MAX_ACTION_BATCH` actions in one round trip.
The agent queues **every** action or **none**: it refuses the whole batch (`batch_too_large`,
`queue_full`, `action_id_required`, `bad_param`) rather than queueing part of it. On success
it returns `#list`; otherwise it raises, and the error says plainly whether anything was
queued. `:try_queue_actions(list)` does not raise:

```lua
local n, msg, outcome = ctx.game:try_queue_actions(list)
if n then ...                                   -- all #list queued
elseif outcome == bot.Game.QUEUED_NONE then ... -- refused: nothing queued, safe to retry
else ... end                                    -- QUEUED_UNKNOWN (timeout, pipe gone): check first
```

The host tells the two failures apart (`"refused"` or `"unknown"`). On a `bwu_host` too old to
say, a failure counts as `QUEUED_NONE` only when the message names one of the agent's refusal
codes, and as `QUEUED_UNKNOWN` otherwise. An agent from before all-or-nothing could queue a
prefix; that comes back as `QUEUED_PREFIX` with the count as a fourth value.

`ctx.game:do_action(a)` queues one action and returns `true`, or `false` and the host's error
(for example `queue_action: queue_full`).

An action the agent queued can still be dropped later if its target never becomes
clickable. `ctx.game:poll_events()` then carries an `action_refused` event with the action
as queued, `reason_name` and how long it was held; no `action_executed` follows it.

## Breaks

`ctx.game:schedule_break(seconds)` holds the action queue for that many **seconds**
(fractions allowed): `schedule_break(300)` is a five-minute break. The agent counts in
milliseconds, so the value is rounded to the nearest millisecond; under 1 ms or over
`Game.MAX_BREAK_SECONDS` (about 24.8 days) raises without sending. `interrupt_break()` ends
a break early. `has_breaks()` is false on a `bwu_host` that predates them, and both calls
then raise.

## Walking: two styles

- `ctx.game:walk_to(x, y)` — queue **one** WALK hop. You write the per-tick loop (plan with
  `:path()`, step, repeat). Non-blocking; paces with `ctx:sleep_ticks`.
- `ctx.game:walk(x, y, plane, radius)` — a **full pathed walk** through the native executor:
  it plans, walks, re-plans, and **executes transitions** (doors, stairs, teleports, dialogue)
  until it arrives. **Blocks** for the whole route and returns `(arrived, err)`;
  `:walk_cancel()` stops it. See `examples/banker.lua`.
- `ctx.game:walk_ex(...)` — the same blocking walk, returning a result table: `status`,
  `fail_step` / `fail_transition`, `transition` (the loc, NPC or chain the walker last tried,
  as the host saw it), `replans`, `elapsed_ms`, `error` and `events`.
- `ctx.game:walk_start(...)` + `:walk_events(since)` / `:walk_wait(ms)` / `:walk_status()` —
  the non-blocking form. Lua has no threads, so this is how a script watches a walk and steps
  in (on `STUCK`, say) instead of waiting for the walker to spend its re-plans:

```lua
local W = require("botwithus.walk")
if g:has_walk_progress() then            -- false on a bwu_host that predates it
  assert(g:walk_start(3165, 3486, 0, 2))
  local seen, r = 0, nil
  repeat
    local evs = g:walk_events(seen); seen = seen + #evs
    if W.has_event(evs, W.EV_STUCK) then g:walk_cancel() end
    r = g:walk_wait(600)
  until not W.is_running(r)
  local t = W.failed_on_transition(r)
  if t then print("failed on", t.kind, t.object_id, t.x, t.y, t.interact_attempts) end
end
```

**Walk options.** `:path`, `:walk`, `:walk_ex` and `:walk_start` take an optional trailing table:
`{ exclude = { ... }, exclude_loc_siblings = true, disabled_moves = W.moves_mask(W.MOVE_CHARTERS) }`.

- `exclude` lists transition indices the planner must not use, on every plan and re-plan.
  Take them from `r.fail_transition` or `transition.transition_index`. It is how a script
  routes around a transition that failed:
  `g:walk_ex(x, y, p, 2, { exclude = { r.fail_transition }, exclude_loc_siblings = true })`.

Options are never silently ignored:

- A table with every field at its default is the old call.
- Anything else on a bwu_host without options (`g:has_walk_options()` false) raises.
- An exclusion on a worldwalker.dll that cannot honour it raises "cannot exclude
  transitions". `g:walk_options_supported()` tells you in advance.

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

Life points: `ctx.game:local_health()` returns `current, max` from varps 13537 / 13538, or `nil`
while unknown (lobby, entering the world, warm-up, a failed read). The host reads them once per
server tick and caches a known pair, so call it every loop. `:has_local_health()` is false on a
`bwu_host` that predates it. (`self().health` is always 0: the snapshot carries no self HP.)

## Run an example

```powershell
scripts\run_example.ps1 examples\banker.lua   # needs bwu_host on PATH (or $env:BWU_HOST) + a live client
```

## Tests

No game client needed — the suite injects a fake `bwu` surface.

```powershell
scripts\test.ps1        # finds a Lua 5.4 (lua5.4, lua54 or lua) on PATH
# or directly:
lua5.4 spec\run.lua
# or with the host's own Lua 5.4, when no lua is installed:
bwu_host --lua spec\run.lua
```

`bwu_host` needs the Python runtime it was built against on `PATH`, because it embeds both
languages.

## Layout

```
botwithus/   the library (pure Lua; no wire code)
examples/    runnable sample scripts (woodcutter and banker are plugins, manager is self-running)
spec/        unit suite + fake_bwu surface + a tiny runner
```
