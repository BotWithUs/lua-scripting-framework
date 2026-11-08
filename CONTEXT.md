# lua-scripting-framework — context

The open-source Lua author API for BotWithUs. One of two scripting frontends on the native
hybrid host (`native-scripting-host`); the other is `python-scripting-framework`.

## Where it sits

```
native-scripting-host   embeds Lua 5.4 (and Python); installs the global `bwu`
        └── bwu table  ◄─────────────  THIS repo wraps it into an ergonomic Lua API
python-scripting-framework            the sibling Python API on the same host
```

This repo contains **no wire code** — no pipe, no shared memory. It is pure Lua over the
`bwu` surface. The host owns the connection to the game client; this layer is only idioms.

## Design rules

- **Resolve `bwu` at call time**, never at load (`rawget(_G, "bwu")`). This keeps the whole
  library unit-testable with an injected fake (`spec/fake_bwu.lua`) — no client, no host.
- **Only `server_tick` paces.** `sleep_ticks(n)` is the only wait primitive; there is no
  millisecond timer, so a script cannot accidentally pace off `game_cycle`/`publish_seq`.
- **Immutable query chaining** — each `entities` filter returns a new query; terminals
  (`:all`/`:nearest`/`:count`/`:first`) read the surface once.
- **One thread, no background.** `botwithus.clients` reads the host's event queue only
  inside `poll`/`pump`/`wait_for`, and handlers run only there. `bot.run` waits on that queue
  only when given a manager (`clients = cm`): reading an event removes it from the queue the
  whole host shares.
- **Per-instance state.** A `clients` manager owns its handlers, its view of the clients and
  its attach claims; nothing lives at module level, so tests stay isolated.
- **Match the other hosts' lifecycle** — `on_start`/`on_loop`(→ticks or negative)/`on_stop`.

## Tests

`scripts/test.ps1` or `lua5.4 spec/run.lua`. **Lua 5.4 only**: the library uses 5.4
integer and bitwise operators, so LuaJIT and 5.1-5.3 cannot run it. The runner is
dependency-free, sets `package.path` from its own location, and exits 1 when any spec fails.
CI (`.github/workflows/test.yml`) installs `lua5.4` on ubuntu-latest and runs the same file.

## Compatibility note

The action ids and surface field names in `botwithus.actions` / `botwithus.game` mirror the
native host's `include/bwu_host_surface.h`. The action builders send exactly the param shapes
the Python framework's builders send, and the specs pin the packed values. If that surface changes, update these to match;
`spec/fake_bwu.lua` is the shape contract the tests pin.

Varp state numbers are the exception: `botwithus.variables` maps them through the surface's own
`bwu.VARP_*` / `bwu.VAR_KIND_*` constants **by name**, so a renumbering on the host cannot
silently misread, and a `bwu` without them is refused with an error naming what is missing.
The composition (agent state + cache default) lives in the native host, not here.
