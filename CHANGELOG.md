# Changelog

## Unreleased

- **Host ABI 5 reads (needs a native host at `BWU_ABI_VERSION` 5; wire v25 unchanged).**
  - `game:backpack()` / `:equipment()` / `:bank()` / `:inventory(id)` return a
    `botwithus.inventory` view, with `count`, `contains`, `find`, `free_slots` and the rest. A
    closed bank is `:is_present() == false`, never an empty bank.
  - `game:skills()` / `:skill("mining")`, with names from `botwithus.skills`.
  - `game:ground_items()` (and the `bot.ground_items(game)` query) and `game:projectiles()`.
  - `game:game_state()` / `:is_logged_in()`, and `:login_state()` / `:current_world()` /
    `:account_info()`.
  - The component reads: `game:component()`, `:components()`, `:component_ops()`,
    `:static_children()`, `:dynamic_children()`, `:interface_tree()` and `:component_at()`,
    through the new `game:rpc_raw(method, params)`. Also new: `game:snapshot_bytes()`.

  Self, NPC and player rows carry the new host fields (`is_member`, `target_index`, `moving`,
  `hp` / `max_hp`, and others). On an older host every new read raises, naming the ABI it needs.
- **`Game:poll_events()` decodes eight more event types**: `varp_change` (10),
  `varbit_change` (11), `varc_change` (12), `obj_var_change` (13), `chat_message` (20),
  `hitmark` (70), `headbar` (71) and `spot_anim` (72). A body too short for its fields, or a chat
  body whose lengths run past it, comes back raw with `error` set, as before.

- **Plugin UI: `botwithus.game_ui`, shaped like Jagex's `ui.*` plugin API.** `game:ui()`,
  `ctx.ui` or `bot.ui(game)` returns a namespace with `Canvas`, `Rectangle`, `Line`, `Text`
  and `Layer` (`.new(parent, categoryID?, dynamicID?)`), `Interfaces:GetComponent`, the
  `Set*` layout methods, properties, the canvas shapes plus `Batch`, `Destroy`,
  `MoveToFront` / `MoveToBack` and `Subscribe(ui.Hook.DESTROYED, fn)`. Failures raise a ui
  error carrying the agent's message verbatim. A run releases what it made when it ends, with
  one `ui.destroy_all` on the Game's own connection. `ui` events (`destroyed`, `overflow`)
  reach `bot.run` once per server tick and a clients manager's `on("ui")` / `poll()` /
  `pump()`. Needs a native host with `bwu.ui_*` and an agent with the `ui.*` verbs. See
  [docs/UI.md](docs/UI.md).
- **`Clients:on_event(fn)` handlers now also receive `ui` events** (kind `"ui"`, a string)
  from every Game the manager attached, beside the service's integer-kind events. A handler
  registered for every kind that assumes `ev.kind` is an integer, or that every event has a
  `client_id`, should check `ev.kind == "ui"` first. Handlers registered with
  `on(<kind>, fn)` for a service kind are unaffected.
- **`Game:poll_events()` decodes `key_input` (type 30).** `Events.KEY_INPUT`, `Events.KEY_INPUT_SIZE`
  and a decoder returning `{ type, name = "key_input", key, is_alt, is_ctrl, is_shift, synthetic,
  text_input_focused, is_repeat }`. The three flags come from the body's last byte (NXTLibrary
  PR #84, merged at `ee221d2`). Against an older agent they all read false. `text_input_focused`
  is set when a text field (chat, bank search, a prompt, a native input) had the keyboard, so
  scripts can ignore keys typed into text. A body shorter than 8 bytes comes back raw with
  `error`, as other events do.

## 1.0.0 — 2026-11-08

Requires the BotWithUs native host, protocol 25, and Lua 5.4.

Lua scripts can now run in the native host's GUI. Put a script in
`~/.botwithus/scripts/lua`: the GUI lists it, shows its settings, and runs it in its own
worker process, on the client you pick. `bwu_host --lua <file>` still runs a file directly.

### Changes that can affect existing scripts

- **The manifest is checked before a run.** `name`, `version`, `author`, `description` and
  `category` must be strings when set, and within length limits. A numeric `version = 1.0`
  is now refused.
- **`on_config_update(ctx, config)` runs before `on_start`,** with every setting's default,
  on the command line too. If it raises, neither `on_start` nor `on_stop` runs.
- **`ctx:sleep_ticks(n)` returns a boolean:** `true` when the ticks passed, `false` when the
  run is stopping or its client has exited. It used to return nothing.
- **`Game:queue_actions` raises when the agent queues only part of a batch.** The agent now
  queues a batch whole or refuses it whole. Against an older agent that queued only the
  first part, `queue_actions` used to return a count below `#list`; it now raises, and the
  error says how many were queued.
- **`Actions.component_click` and `Actions.dialogue_option` send what the agent expects.**
  `component_click(iface, comp [, option = 1 [, sub_slot = -1]])` used to send the wrong
  shape, and `dialogue_option` sent an action the agent does not have. Both now work.
- **Lua 5.4 only.** The test script no longer falls back to LuaJIT.

### Added

- **Running under the GUI.** A script file that returns a table is a plugin: the GUI reads
  its manifest and settings without running it. A file that returns anything else is
  self-running, and the GUI runs it as a whole.
  - A plugin can `require` the files next to it.
  - In a self-running script, `os.exit()`, `os.exit(0)` or `os.exit(true)` ends the run
    normally; any other code is reported as a crash.
- **Settings.** `botwithus.config` adds `int_field`, `string_field`, `bool_field`,
  `choice_field` and `item_id_field`. The GUI shows them as a form, and `ctx.config` holds
  the values in force. Changes made while the script runs are applied between loops.
- **Stopping.** `ctx:stopping()` and, for self-running scripts, `bot.stopping()`. Both are
  always false on the command line. Waits in `sleep_ticks`, `clients` `wait_for` and
  `Launch:wait_attached` return early when the run is asked to stop.
- **`Game:poll_events()` decodes agent events.** New `botwithus.events`: `action_refused`
  (with the reason and where the agent was waiting) and `action_executed`. Other event
  types come back raw. A record too short to decode comes back raw with an `error` field,
  and the rest of the batch still decodes.
- **`Game:try_queue_actions`** returns `nil, msg, kind` instead of raising, where `kind`
  says whether nothing, an unknown part, or a known first part was queued.
- **Breaks:** `Game:schedule_break(seconds)`, `Game:interrupt_break()` and
  `Game:has_breaks()`.
- `Game.try_attach(pid)`, which does not raise.
- The woodcutter example now chops trees as scenery objects with their real ids. The banker
  and manager examples are safe to list in the GUI.

### Fixed

- **A run ends when its game client exits.** Before, a run in the GUI kept going until it
  was stopped by hand. Now the run ends cleanly (`on_stop` runs, then the client is
  released) within one poll if the client's data can no longer be read, or within about
  7 seconds if it is frozen. `on_stop` can still read the last frame. A client that is only
  stalled, for example in the lobby, does not end the run.
- A NaN delay from `on_loop` now ends the loop, like a negative one.

### Also since 0.1.0

- Client management for management scripts (`bot.clients`), and the native package update
  events.
- Typing into the game's input dialog (`botwithus.input`).
- Varp and varbit reads, `Game:local_health()`, and each open interface's open type.
- Walking: `walk_ex`, the non-blocking walk calls, and walk plan options.
- Run logs from `bot.run`: phase, iteration and a traceback from where the error was raised.
- Protocol 24 and 25 data: player names and appearance, NPC combat levels, run energy,
  server tiles, overhead text, health bars and hint arrows.
- Attaching to a host built for another agent protocol is refused.
