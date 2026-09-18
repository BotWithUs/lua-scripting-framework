# lua-scripting-framework — context

The open-source Lua author API for BotWithUs. One of two scripting frontends on the native
hybrid host (`native-scripting-host`); the other is `python-scripting-framework`.

## Where it sits

```
native-scripting-host (private, C)   embeds Lua + CPython; installs the global `bwu`
        └── bwu table  ◄─────────────  THIS repo wraps it into an ergonomic Lua API
python-scripting-framework (private)  the sibling Python API on botwithus._native
```

This repo contains **no wire code** — no pipe, no shared memory, no crypto. It is pure Lua
over the `bwu` surface. That is deliberate: the wire contract and the SDN decrypt path live
in the native host, and this layer is safe to open-source because it is just idioms.

## Design rules

- **Resolve `bwu` at call time**, never at load (`rawget(_G, "bwu")`). This keeps the whole
  library unit-testable with an injected fake (`spec/fake_bwu.lua`) — no client, no host.
- **Only `server_tick` paces.** `sleep_ticks(n)` is the only wait primitive; there is no
  millisecond timer, so a script cannot accidentally pace off `game_cycle`/`publish_seq`.
- **Immutable query chaining** — each `entities` filter returns a new query; terminals
  (`:all`/`:nearest`/`:count`/`:first`) read the surface once.
- **Match the other hosts' lifecycle** — `on_start`/`on_loop`(→ticks or negative)/`on_stop`.

## Tests

`scripts/test.ps1` or `lua spec/run.lua` (Lua 5.4). The runner is dependency-free and sets
`package.path` from its own location. CI installs `lua5.4` and runs the same file.

## Compatibility note

The action ids and surface field names in `botwithus.actions` / `botwithus.game` mirror the
native host's `include/bwu_host_surface.h`. If that surface changes, update these to match;
`spec/fake_bwu.lua` is the shape contract the tests pin.
