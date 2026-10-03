# Managing clients from Lua

`botwithus.clients` lets a Lua script manage game clients through the BotWithUs launcher's
background service. A script can list accounts, launch, stop and list clients, watch what
happens to them, and answer a request to close for a data update.

```lua
local bot = require("botwithus")
local cm  = bot.clients.new()

local launch = assert(cm:launch(cm:accounts()[1].id))
local game   = assert(launch:wait_attached(300))   -- waits for "injected", then attaches
game:refresh()
print("attached to", game:pid())
cm:stop(launch.client_id, "graceful")
```

`examples/manager.lua` is a complete script. Run it with
`scripts\run_example.ps1 examples\manager.lua`.

## What the host does for you

- **It connects on its own.** `bwu_host` connects to the service when it starts and keeps one
  connection for the whole process. If the service is not running, the host still runs and
  keeps retrying in the background. Your script never opens or closes anything.
- **It never starts the service.** While the service is away, calls fail quickly with
  `service_unavailable`; see [Errors](#errors).
- **It queues events.** Events wait in the host until your script reads them.

## The manager

`bot.clients.new()` returns a manager. Its handlers, its view of the clients and the
clients it attached belong to it alone. Most scripts make exactly one.

| Call | Returns |
|---|---|
| `cm:accounts()` | a list of `{ id, name }` |
| `cm:launch(account_id [, character_index])` | a launch handle `{ client_id }`, once the service has queued the launch. `character_index` is for Steam accounts. |
| `launch:wait_attached(timeout_s)` | a `Game`, once the client is injected and attached |
| `cm:stop(client_id [, mode])` | `true`, once the stop is sent. `mode` is `"graceful"` (the default: asks the game to close) or `"kill"`. It works on any client, whoever launched it. |
| `cm:clients()` | a list of client records (below) |
| `cm:attach(client_id)` / `cm:attach_pid(pid)` | a `Game`, attached once per process |
| `cm:detach(client_id)` | detaches this manager's `Game` for that client |
| `cm:game_for(pid)` | the `Game` this manager holds for a pid, or `nil` |
| `cm:on(kind, fn)` / `cm:on_event(fn)` | a function that removes the handler |
| `cm:on_close_requested(fn)` | sets the close handler, or removes it if `fn` is `nil` |
| `cm:ack_close(request_id, decision)` | `true` |
| `cm:poll(timeout_ms)` / `cm:pump(timeout_ms)` / `cm:wait_for(pred, timeout_s)` | see [Events](#events) |

A client record has these fields: `client_id`, `account_id`, `account_name`, `pid`,
`character_index` (-1 unless Steam), `kind`, `origin`, `state`, `licence_state`,
`licence_failures`, `is_agent_stale` (a boolean), `restart_of` (the previous pid after an
automatic restart, otherwise 0), `started_at_ms` and `agent_sha`.

Each integer field also has a readable twin: `state_name`, `kind_name`, `origin_name` and
`licence_name`. States are `queued`, `spawning`, `injecting`, `injected`, `failed` and
`exited`. **`injected` is the last state the service knows.** To see whether the game has
reached the lobby, attach and read the game yourself.

## Errors

A call the service could not answer, or refused, returns `nil, code, message`; it does not
raise. Branch on `code`:

- `service_unavailable`: the service is not running, is restarting, or did not answer in time.
- `service_stopped`: the user stopped the service from the tray.
- Codes from the service itself, for example `account_not_found`, `client_not_found`,
  `not_signed_in`, `session_limit`, `concurrency_cap` and `rate_limited`.

  `cm:launch` returns a fourth value, `retry_after_ms`. It says how long to wait after
  `rate_limited`, and is -1 for every other code.
- From this framework: `attach_failed`, `timeout`, `exited` (the client exited before it was
  injected) and `client_not_found`.

A mistake in your own code raises a `botwithus: ...` error, as the rest of the framework
does. That covers an unknown stop mode, an unknown decision, a bad request id, or running
outside `bwu_host`.

## Events

**The script has one thread, so nothing runs in the background.** Events wait in the host
until you read them, and handlers run only inside these calls:

- `cm:poll(timeout_ms)` reads one event. It waits at most `timeout_ms`: 0 by default, and
  never more than `bot.clients.MAX_POLL_MS`. It returns the event, or `nil` if none came.
- `cm:pump(timeout_ms)` waits up to `timeout_ms` for the first event, handles everything else
  that is queued, and returns how many events it handled.
- `cm:wait_for(pred, timeout_s)` handles events until `pred(event)` is true and returns that
  event. After `timeout_s` it returns `nil, "timeout"`.

Keep waits short. While a wait lasts, your script does nothing else.

Every event gets a `name`, as listed below. It also carries `client_id`, `pid`, `state`,
`exit_code`, `reason`, `hosts_blocking`, `request_id` and `text`. A field that does not apply
to a kind is 0 or `""`.

| `name` | What it tells you |
|---|---|
| `client_started` | A client process started. `pid` is the new process. This is also sent after an automatic restart. |
| `client_state` | The client moved to `state`. When it `failed`, `text` is the failure code; otherwise `text` is a progress message. |
| `client_exited` | The client ended. `exit_code`, and `reason` (`reason_name`: `stopped`, `licence`, `descriptor` or `unknown`). |
| `agent_updated` | A newer agent was published. |
| `data_update_available` / `data_update_applied` | A data update is staged, or was applied. |
| `close_requested` | The service asks this host to close for a data update; see below. |
| `licence_state` | A client's licence changed. `state_name` is `ok`, `retrying`, `dropped` or `untracked`. |
| `service_shutting_down` | The service is about to stop. |
| `service_lost` | The connection to the service was lost. Sent once per loss. |
| `service_restored` | The connection is back. |
| `events_dropped` | Events were lost because the queue overflowed. |

### After the service comes back

Nothing that happened while the service was away is replayed. On `service_restored`, and on
`events_dropped`, the manager asks for the client list again **before** your handlers run.
The list is on the event as `event.clients`. If that call failed, the code is in
`event.resync_error` instead.

## Attaching, and when a Game goes away

`launch:wait_attached()` and `cm:attach()` attach through the manager, which attaches each
process **at most once**. Asking again for the same client or pid returns the same `Game`.

When the service reports that a client exited, or restarted as a new process, the manager
detaches its `Game` for you, because that process is gone. A script that still holds the
`Game` can tell:

- `game:is_attached()` returns `false` and the reason;
- `game:refresh()` returns `false, "detached", reason`;
- any read raises `botwithus: game is detached (...)`.

To attach to the new process after a restart, call `cm:attach(client_id)` again.

## Close requests for a data update

When a data update is ready, the service asks open hosts to close. The host prints one line
to stderr and queues a `close_requested` event. **It never closes by itself.**

- **No handler:** nothing is answered and the script keeps running. That is a normal state.
  The launcher shows the host as waiting, and applies the update after the host exits.
- **With a handler:** `cm:on_close_requested(function(request) ... end)` is called with
  `{ request_id, reason, hosts_blocking }`.
  - Return `"closing"`, `"declined"` or `"later"` and the framework sends that answer.
  - Return `nil` to answer later yourself, with `cm:ack_close(request_id, decision)`.
  - If the handler raises, nothing is sent, one line goes to stderr, and event handling
    carries on.

The answer only changes what the launcher displays. If you answer `"closing"`, closing is up
to your script.

## Running a game script under a manager

Pass the manager to `bot.run`:

```lua
bot.run(script, { clients = cm, client_id = launch.client_id })
```

The run then attaches through the manager, and `ctx.clients` is the manager. Between ticks,
`ctx:sleep_ticks()` waits on the manager's events instead of spinning, so your handlers,
including the close handler, run while the script sleeps. The loop ends when the client
exits.

Without `clients`, `bot.run` waits as it always has, and never reads the event queue. **This
is deliberate.** Reading an event removes it from the one queue the whole host shares, so a
script that never asked for events would silently throw them away, a close request included.

You can also pass `game = g` to run on a `Game` you already hold. `bot.run` then leaves it
attached when it finishes.
