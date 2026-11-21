# Changelog

## 1.1.0 — 2026-11-21

- **Tests: the fake host drops queued events on unsubscribe (no framework change).**
  `spec/fake_bwu.lua`'s `ui_unsubscribe` now discards that hook's queued events for the handle
  once the agent answers, as the native host's `bwu_ui_unsubscribe` does, and keeps them when it
  plays a timeout. Three specs in `spec/game_ui_p2_spec.lua` pin what `docs/UI.md` says: a queued
  event is not delivered after the unsubscribe, events already read in the same batch still
  reach `ui:on_event` and `ui:poll()`, and a timed-out unsubscribe keeps delivering to
  `ui:on_event`.

- **Docs: unsubscribing and the end-of-run release (no code change).** `docs/UI.md` now says that
  an answered `ui.unsubscribe` makes the host discard that hook's events not read yet, so a click
  made just before `Unsubscribe` may be lost, and what still happens to events the framework has
  already read. It also says that a native host from `61e65ab` on sends no second
  `ui.destroy_all` at detach after the framework's own release.

- **Native host ABI 8: gameval names, a millisecond clock, pause from the GUI, a settings store,
  object animations** (native-scripting-host feat/n3-host-gaps).
  - `botwithus.gameval`: the host's gameval index (`bwu.gameval_*`) by the Java `GamevalType`
    strings; `G.ref(type, name, fallback):id()`. Every pinned Java `GamevalRef` fallback id now
    resolves by its name first: the action bar (slot variables all of one bar or the generated
    table, slot buttons, current bar, global cooldown varcs, `COMBATV2_TYPE_TO_ENUM`), prayers (73
    struct and varbit names and the rest), combat, HUD, bank, buffs, summoning, lodestones, chat
    pages, item destruction, deposit box and loot; a name that does not resolve uses the old id
    with one warning. Quests are listed from the index (the id scan is the fallback), and
    `status` takes a quest gameval name.
  - Timers and waits read `bwu.monotonic_ms` (`Timers.now_ms`, `Timers.has_ms_clock`):
    millisecond resolution instead of `os.time()`'s seconds. `Clients:wait_for` too.
  - Pause: in a GUI worker the run's switch is the host's (`Timing.HostPause`): `ctx:pause()` /
    `ctx:resume()` reach the GUI, and the GUI's pause button holds `on_loop` and the waits.
  - Settings: `ctx.settings` starts from the map the last run saved, under the config, and
    `save()` sends it, as strings, to the GUI's store; a refusal is false, why.
  - Objects: loc rows carry `animation_id`, so `:animating()` / `:with_animation(...)` work on
    `Entities.objects`.
  - Needs host ABI 8; on an older host the names fall back to the old ids, the clock is
    `os.time()`, `save()` is false, "unsupported" and the GUI cannot pause the run.

- **Plugin UI P2: interactive components and hook subscriptions (`botwithus.game_ui`, needs an
  agent from NXTLibrary a17edc4 and a native host with `bwu.ui_subscribe`, native-scripting-host
  7bb38a4; no protocol change).** Additive: every P1 script runs unchanged.
  - `ui.Button`, `ui.Check`, `ui.InputField`, `ui.Slider`, `ui.ComboField`, `ui.List`,
    `ui.Panel`, `ui.Grid`, Jagex-shaped (`label`, `isToggled`, `value`, `content`, `filterMode`,
    `Setup`, `SetValue`, `SetEntries`, `Add`, `Remove`, `Select`, `SetEntrySelected`, ...) plus
    `comp.enabled`; ours: `InputField:Blur()`, `.isFocused`, `.renders`, `Slider:SetRange`.
  - `comp:Subscribe(ui.Hook.X, fn)` for ONCLICK, ONRELEASE, ONMOUSEOVER, ONMOUSELEAVE,
    ONBUTTONPRESSED, ONCONTENTCHANGED, ONSELECTIONCHANGED, with Jagex's arguments
    (`fn(self, x, y)`, `fn(self, current, previous)`, ...) and a typed `event.args` record.
    `ui.InputFieldActionResult`, `ui.SelectionChangeEvent`, `ui.InputFieldFilterMode`,
    `ui.TextContentVisibilityMode`.
  - A gone component takes its subscriptions with it: no `ui.unsubscribe` for it, and
    `Unsubscribe` on it succeeds. The end of a run is still one `ui.destroy_all`.
  - A default list is single-select (selecting another replaces; `UnselectAll` is a no-op);
    `Subscribe(hook, fn)` without an id replaces the hook's default callback; no click, content
    or selection callback runs once `on_stop` has returned or the run crashed; a callback that
    polls or sleeps does not reorder events; a restricted input field's content reads `""`.
  - Tests: `spec/game_ui_p2_spec.lua` (fake agent P2 rules; `ui_p1 = true` plays an older host);
    live: `tests/live/ui_smoke_p2.lua`.

- **The Java host's composition APIs (J1-J3), ported to Lua.** Built only on what the frontend
  already binds (host ABI 7; wire v25 unchanged). Names follow the Java host's, in snake_case.
  - Condition waits (`botwithus.timing`, and `ctx:delay_until` / `:delay_while` /
    `:delay_until_ticks` / `:delay_ticks`): each returns whether its condition was met, ends within
    one poll of a stop or the client exiting, counts `server_tick` only, gives up on a stalled tick,
    and holds while the run is paused.
  - Pause and settings: `ctx:pause()` / `:resume()` / `:is_paused()` (no `on_loop` runs while
    paused; a plugin-UI or client-event handler resumes) and `ctx.settings` (read through
    `ctx.config`, kept across a config change; not persisted: the host has no settings store yet).
  - `botwithus.area` (rectangle, circle, polygon; `contains`, `random_tile`,
    `random_reachable_tile`) and `Tile` region helpers (`bot.Coordinate` is `Tile`).
  - Items by WHOLE name, pattern, category and option (`botwithus.match`), inventory
    `find_exact`, `contains_all_of` / `_any_of` / `_any_except`, `items_with_option`, and clicks:
    `interact(target, option)` through the live menu, `use(target)`. `botwithus.bank`: open (booth,
    chest or banker), deposit / withdraw by id, name or pattern, `deposit_all_except`, presets,
    `load_last_preset`, withdraw / transfer modes.
  - `botwithus.xp` (skill display names, the standard and elite xp tables, `XpTracker`) and
    `botwithus.timers` (Stopwatch, Timer, Durations).
  - Entity query filters: animation, stance, spot anim, moving, combat level, health and health
    percent, option, `named_any_of`, `name_matching`, `with_ids`, `inside` / `outside` an area,
    `reachable`, `within_distance`, and `last`, `random`, `nearest_to`; `botwithus.interact` clicks
    an NPC, object or ground item by option name.
  - `botwithus.actionbar` (slots from the bar vars, abilities from the cache, cooldowns joined
    through client scripts 8247 then 6506, UNKNOWN when they fail), `botwithus.prayers`,
    `botwithus.combat` (local combat state and a hitmark history), `botwithus.changes`
    (inventory and skill change events derived per server tick), `botwithus.summoning` (beast of
    burden inventory 530), `botwithus.lodestones` (with the settle wait and one open retry).
  - `botwithus.component_query` (queries over a live component tree; option clicks with the
    node's own sub), `botwithus.dialog` (chat page text and title across 1184 / 1191 / 1186 /
    1189, multi-choice options, the destroy confirmation), `botwithus.quests` (status at or above
    the start value, stubs read as their listed quest, unmet requirements),
    `botwithus.deposit_box`, `botwithus.loot`, `botwithus.buffs`, `botwithus.hud` (tabs through
    RIBBON_WINDOWS and the button's own Open / Close) and `game:logout()` /
    `game:exit_to_lobby()`.
  - `botwithus.definitions` gains `enum`, `param_map` and `quest`; `botwithus.json` decodes the
    cache's JSON. Gameval names are pinned as ids (the native host has no gameval index), each with
    its name beside it.
  - Tests: `spec/l2_j1_spec.lua`, `spec/l2_j2_spec.lua`, `spec/l2_j3_spec.lua`; the fake surface
    takes extra cache rows and client-script results. Live: `tests/live/l2_smoke.lua`.

- **Host ABI 7: cache definitions, world map elements, avoid areas and route links (needs a native
  host at `BWU_ABI_VERSION` 7; wire v25 unchanged).** On an older host each raises naming ABI 7.
  - `botwithus.definitions` (`bot.Definitions`): `item` / `npc` / `loc` (names, ops, stackable,
    noted, members, category, ...), `params`, `int_param`, `json` for the long tail, `item_name`
    (kept on this side), `available()`. A missing id is nil; no cache raises with the host's reason.
  - Inventory views match by item name: a string matcher (`bp:count("logs")`), names from the
    cache by default, a note reading as its item; `:count_named(name, names)` / `:find_named` /
    `:find_all_named` / `:contains_named` take your own resolver.
  - `botwithus.worldmap` (`bot.WorldMap`): `elements(area_id, filter)` / `nearest(x, y, filter)`,
    area 28 (the main world) by default, `area_id` kept.
  - Walk options take `avoid = { ... }` (`botwithus.walk`: `area`, `box`, `around`, `contains`,
    `MAX_AVOID`); `game:path_route(x, y, plane, opts)` returns `{ steps, links }`
    (`walk.teleports(route)`); `game:has_avoid()`. Refused, never ignored, on an older host or a
    worldwalker.dll before WorldWalker #44.
  - Tests: `spec/n2_spec.lua` (fake surface `install_abi7`; the fake defaults to ABI 7).

- **Host ABI 6 calls (needs a native host at `BWU_ABI_VERSION` 6; wire v25 unchanged; the agent
  RPCs of NXTLibrary 0f746b4).** On an older host each raises naming ABI 6;
  `game:has_abi6_calls()` tells.
  - `game:ge_offers()`: the eight GE slots of market 0, each with `in_use` (`stage ~= 0`) and
    `is_sell` (`botwithus.grand_exchange`).
  - `game:world_list()`: rows with `members`, `skill_total`, `classic_only`, `eoc_only` decoded
    and `flags` raw; `is_fetched` is false for the empty list the client holds before the game
    fetched it, which is not an error (`botwithus.worlds`, `Worlds.find`).
  - `game:set_world(id)` and `game:hop_world(id[, timeout_ms = 30000])`: waits until the client
    reports the world with its state back at 20 or 30; nil, code, detail on a refusal or timeout.
  - `game:target_mode()`, and use-on (`botwithus.target`): `:use_on_component(src, dst)`,
    `:use_on_npc(src, index)`, `:use_on_object(src, loc, x, y)`, and the backpack forms
    `:use_item_on_item(slot, slot)` / `:use_item_on_npc` / `:use_item_on_object`. The host arms
    with 25, waits for target mode armed from that source, then fires 58, 8 or 2; the agent
    clears target mode after. Ground items, players and tiles are not bound (packing not
    documented).
  - `game:world_to_screen(tiles)`: 1..64 tiles to window pixels; `on_screen` per point.
  - `game:static_children_with_sub` / `:dynamic_children_with_sub`: `{comp, sub}` rows. Use
    these instead of the count-only `:dynamic_children`.
  - `game:script_handle` / `:execute_script(handle, ints, strings, returns)` /
    `:destroy_script_handle`, with string arguments (16 args together, 255 bytes each).
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
