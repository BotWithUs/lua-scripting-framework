# Plugin UI: the game's own components (`botwithus.game_ui`)

RuneScape's Lua plugin API has a `ui.*` module of native game components: canvases,
rectangles, lines, text and layers that the client draws itself, with its own z-order and
scaling. The BotWithUs agent can create and drive those same components for a script. This
module gives Lua scripts that ability **in the shape of Jagex's own API**, so plugin snippets
port almost verbatim.

It is an extra, opt-in way to show something in the game. It does not replace or change
anything else: settings, run logs and debug drawing are unchanged.

```lua
local bot = require("botwithus")

bot.run({
  manifest = { name = "hello ui", version = "1", author = "me" },
  on_start = function(ctx)
    local ui = ctx.ui                                    -- or game:ui() / bot.ui(game)
    local area = ui.Interfaces:GetComponent(1477, 61)    -- TOPLEVEL_V2__GAME_AREA

    local c = ui.Canvas.new(area)
    c:SetPos(40, 40)
    c:SetSize(300, 300)
    c:AddOutline(0, 0, 200, 200, 5, 0xFF0000FF)
    c:AddLine(20, 10, 200, 200, 2, 0x339000FF)

    local label = ui.Text.new(area)
    label:SetPos(40, 20)
    label:SetSize(200, 20)
    label.content = "Hello World"
    label.rgba = 0xFFFF00FF
    label:Subscribe(ui.Hook.DESTROYED, function(comp, reason)
      print("the game took the label down: " .. reason)
    end)
  end,
  on_loop = function() return 5 end,
})
-- When the run ends, everything it made is destroyed.
```

## What works now

| Jagex | Here |
|---|---|
| `ui.Canvas.new(parent, categoryID?, dynamicID?)`, and `Rectangle`, `Line`, `Text`, `Layer` | the same |
| `ui.Interfaces:GetComponent(combinedID)` / `(interfaceID, staticID)` | the same; returns nil (and the agent's message) when the component is not there |
| `SetX`, `SetY`, `SetPos`, `SetWidth`, `SetHeight`, `SetSize` (with the percentage arguments) | the same |
| `MoveToFront()`, `MoveToBack()`, `Destroy()` | the same; `Destroy()` returns whether the component was freed, and a second call sends nothing. If the game already took it down (its `destroyed` event not read yet) it returns `false`, runs its `DESTROYED` callbacks with reason `removed`, and does not raise; only a timeout raises |
| `comp.rgba`, `comp.clickthrough` | the same, read and write |
| `comp.x`, `.y`, `.width`, `.height`, `.visibleGlobal`, `.isRestricted` | read-only, read back from the game. `visible` (the component's own visibility) has no wire form yet and raises "not supported yet" |
| `Line.width`, `Line.invert` | the same (the stroke width, as in Jagex's API) |
| `Rectangle.fill`, `Rectangle.outlineThickness` | the same |
| `Text.content` | the same, read and write |
| `Canvas.numElements`, `AddLine`, `AddOutline`, `AddRectangle`, `AddGradientH`, `AddGradientV`, `AddTriangle`, `Clear`, `Undo` | the same; each returns the element count |
| `Subscribe(hook, [id,] fn)`, `Unsubscribe`, `UnsubscribeAll` | for `ui.Hook.DESTROYED` (ours, see below) and the P2 hooks below; returning `false` stops later callbacks |
| `comp.enabled` | the same, read and write |

Additions of ours:

- `Type.create(parent, props, { category =, dynamic = })` creates and sets wire props in one
  call, e.g. `ui.Text.create(area, { text = "hi", x = 4, y = 4, width = 100, height = 20 })`.
- `comp:Set(props)` sets several wire props in one call, and `comp:Get([with_content])`
  returns every readback field (`x`, `y`, `width`, `height`, `rgba`, `visible`,
  `num_elements`, `op_mask`, ...).
- `canvas:Batch(function(c) ... end)` queues the `Add*` / `Clear` / `Undo` calls made inside it
  and sends them together, in chunks of `bwu.UI_CANVAS_OPS_MAX`. `canvas:Draw(ops)` sends ops
  in their wire form.
- `ui.Interfaces:GetComponentByKey(interfaceID, staticID, key)` looks up a dynamic child by
  the key a component reports (`comp.key`).
- `comp.isJagex`, `comp.key`, `comp.typeName`, `comp:IsDestroyed()`, and `comp.isQuarantined`:
  true when the agent could not remove the component and keeps retrying (it then refuses every
  other call on it).
- `ui:on_event(fn)`, `ui:poll()`, `ui:list()`, `ui:components()`, `ui:release()`.

Colours are always `0xRRGGBBAA` integers.

## Interactive components (P2)

Needs an agent with plugin-UI P2 support and a native host with `bwu.ui_subscribe` (native host
1.1.0 or later). On an older host the hooks and the entry helpers raise
`not supported yet (this host has no P2 plugin-UI surface)`, and an older agent refuses the
types with its own text.

```lua
local panel = ui.Panel.new(area)
panel:SetPos(40, 40); panel:SetSize(220, 260); panel.vertical = true

local go = ui.Button.new(panel)
go:SetSize(200, 30); go.label = "Start"
go:Subscribe(ui.Hook.ONBUTTONPRESSED, function(btn, current, previous) print("pressed", current) end)

local trees = ui.List.new(panel)
trees:SetSize(200, 80)
trees:SetEntries({ "Oak", "Willow", "Yew" })         -- ids 1, 2, 3
trees:Subscribe(ui.Hook.ONSELECTIONCHANGED, function(list, entryID, event)
  if event == ui.SelectionChangeEvent.SELECTED then print("picked", entryID) end
end)

local name = ui.InputField.new(panel)
name:SetSize(200, 30)
name:Setup(ui.TextContentVisibilityMode.VISIBLE, ui.InputFieldFilterMode.ALPHANUMERIC, 20)
name:Subscribe(ui.Hook.ONCONTENTCHANGED, function(field, reason, content)
  if reason == ui.InputFieldActionResult.SUBMIT then print("submitted", content); field:Blur() end
end)
```

| Jagex | Here |
|---|---|
| `ui.Button.new`, `ui.Check.new`, `ui.InputField.new`, `ui.Slider.new`, `ui.ComboField.new`, `ui.List.new`, `ui.Panel.new`, `ui.Grid.new` | the same (and `Type.create(parent, props, opts)` with the wire props, e.g. `entries`) |
| `Button.label`, `.canToggle`, `.isToggled` | the same, read and write (a toggle needs `canToggle`) |
| `Check.value` | the same (the wire's `checked`) |
| `InputField.content`, `.filterMode`, `.maxLength` (read), `:Setup(visibility, filter, maxLength)` | the same; `content` of a restricted (password) field reads `""`, as Jagex's; `filterMode` takes `ui.InputFieldFilterMode.*` and reads back equal to it. `visibility` other than `VISIBLE` is the agent's refusal |
| `Slider.value`, `:SetValue(v)`, `:Setup(max, curValue)`, `.minValue`, `.maxValue` | the same; `Setup(max, cur)` is `0..max` in steps of 1. **A set never raises `ONSELECTIONCHANGED`** (see below) |
| `ComboField:SetEntries(entries, selectedID?)`, `:Add`, `:Remove`, `:Clear`, `:Select`, `:UnselectAll`, `:HasEntry`, `.entries`, `.numEntries`, `.selectedID`, `.hasSelection`, `.selectedLabel` | the same; `entries` as `{ "a", "b" }` (ids 1..n), `{ a = 7 }` (label -> id) or `{ { id =, text = } }`. An entry is `{ id, text }`; its `selectable` has no wire form and raises "not supported yet". `Remove` of the selected entry leaves nothing selected (`selectedID == -1`) |
| `List:SetEntries`, `:Add`, `:Clear`, `:UnselectAll`, `:SetEntrySelected(id, sel)`, `:GetEntrySelected`, `:GetEntryEnabled`, `:GetEntryVisible`, `:HasEntry`, `.entries`, `.selectedEntries`, `.numSelectedEntries`, `.maxSelected` | the same. A new list is single-select (`maxSelected == 1`): `SetEntrySelected(id, true)` replaces the selection and `UnselectAll` does nothing, as in Jagex's. A limit L > 1 holds at most L − 1 selected entries (the client's rule, measured on 951-4) |
| hooks `ONCLICK`, `ONRELEASE`, `ONMOUSEOVER`, `ONMOUSELEAVE` | `fn(comp, x, y, event)`, component-relative |
| `ONBUTTONPRESSED` (button, check) | `fn(comp, current, previous, event)`, 0/1 |
| `ONCONTENTCHANGED` (input field) | `fn(comp, reason, content, event)`; `reason` is `ui.InputFieldActionResult.*` (CONTENT_CHANGE 0, ERROR 1, SUBMIT 2, SUBMIT_ON_ESCAPE 3, SUBMIT_ON_FOCUS_LOSS 4; `NONE` is -1 and never delivered); `content` is nil on a restricted field |
| `ONSELECTIONCHANGED` (slider) | `fn(comp, value, 1, event)` |
| `ONSELECTIONCHANGED` (combo field, list) | `fn(comp, entryID, selectionEvent, event)`; `ui.SelectionChangeEvent.*` (DESELECTED 0, SELECTED 1, ERROR_MAX_SELECTED 2, ERROR_NOT_SELECTABLE 3) |

The last callback argument is always the event table; `event.args` is a typed record:
`MouseEvent {x, y}`, `ButtonPressed {current, previous}`, `ContentChanged {reason, reasonName,
content}`, `SliderChanged {value}`, `SelectionChanged {entryID, selectionEvent, eventName}`, or
`Raw` (an argument shape the host did not decode, passed on as it came). `ui:on_event` listeners
and a `botwithus.clients` manager see the same typed event.

Additions of ours: `InputField:Blur()` (drop its input focus; returns whether it had it — while a
field has focus the game's keys go to it, so blur it when done), `InputField.isFocused`,
`.renders`, `.fontID`, `.spriteID`, `Slider:SetRange(min, max, step, ticks, value)` (the client
takes all four together: `min < max`, `0 < step <= max - min`, `(max - min) % step == 0`,
`0 < ticks <= max - min`), `Slider.step` / `.ticks`, `List.selectedIDs`, `Panel.vertical`.

**`renders` is reported as the agent reads it.** On 951-4 an agent input field does not draw
(not even its text) until a background sprite is known, and in the world there is usually none to
copy, so expect `renders == false`. Content, events and focus work regardless.

**Subscriptions.** `Subscribe(hook, fn)` without an id is the hook's one default callback: subscribing
again replaces it, and `Unsubscribe(hook)` removes it. Callbacks with an id sit beside it.
The first callback for a hook sends one `ui.subscribe`; removing the last one
sends `ui.unsubscribe`. The agent's refusal (`ui: hook not valid for this type`, a Jagex handle)
raises and keeps nothing. A component that is gone — destroyed, released at the end of the run,
taken down by the game, or missing after an overflow — takes its subscriptions with it: no
`ui.unsubscribe` is sent for it, and `Unsubscribe` on it succeeds. The end of a run is still one
`ui.destroy_all`.

**Unsubscribing drops events still queued.** When the last callback for a hook goes
(`Unsubscribe` or `UnsubscribeAll`) and the agent answers the `ui.unsubscribe`, the host also
discards that hook's events for the component that arrived but were not read yet. So a click
made just before you unsubscribe may never reach a callback. Events the framework had already
read before you unsubscribed are not dropped. For example, a callback unsubscribes while later
events of the same hook wait in the same read (up to 32 events). Those events run no
`Subscribe` callback, but they still reach the `ui:on_event` listeners and the list that
`ui:poll()` returns. Removing one callback while others remain sends nothing and drops nothing:
the hook stays subscribed. A callback removed by an earlier callback of the same event still runs
for that event, and not for later ones. If the `ui.unsubscribe` times out, the callbacks are gone
anyway, but the host keeps the subscription, so the hook's events keep reaching `ui:on_event`.

**Sets do not raise change hooks.** A slider value or a combo / list selection set through the
agent never raises `ONSELECTIONCHANGED`; only a user's interaction does. So `triggerEvents = true`
(`Slider:SetValue`, `ComboField:Select`, `List:SetEntrySelected`) raises `not supported yet`, and
`slider.value = v` does not fire hooks as Jagex's does. The one exception is the client's own:
an input field's content set **does** raise `ONCONTENTCHANGED` (reason `CONTENT_CHANGE`), so a
subscribed script sees its own sets.

## Not supported yet

These raise an error whose `kind` is `"unsupported"` (nothing is sent):
`Canvas:AddText`, `Canvas:AddSprite`, `Vector4` colours, `comp.colour` / `comp.alpha` /
`comp.rgb`, `comp.visible`, hooks other than `DESTROYED` and the seven P2 hooks (every Jagex
hook name is in `ui.Hook`, so `ui.Hook.ONDRAG` is never nil; `Subscribe` refuses it),
`ui.Interfaces:GetInterface`, the
`GetComponent(..., categoryID, dynamicID)` forms, and the collection and layout methods
(`GetChild`, `SetAspectRatio`, ...). From P2: `triggerEvents = true`, `Button.mode` and its
associated object, `Check.alignment` / `.buttonSize`, `InputField.visibility` / `.inputMode` /
`.emptyText` / the caret and highlight colours, the `Slider:Setup` forms with a display divisor
or named entries, `Slider.valueLabel` / `.rate`, the dropdown and entry-height properties, and
`List:SetEntryEnabled` / `:SetEntryVisible` / `:SetEntryIcon`.

These are sent to the agent, which refuses them today with its own message (for example
`ui type not supported yet: sprite` or `ui prop not supported yet: hidden`), and they will start
working when the agent supports them, with no change to your script: `ui.Sprite`, `ui.Model`,
`comp.hidden`, `Text.font`, `Check.label`, a panel's `spacing`, a grid's `layout`, and an input
field visibility other than `VISIBLE`.

Never offered, and always refused by the agent: interaction configuration on a component
(`op_config`, `drag_config`, `target` and the like), category 0, and editing a Jagex
component. A component looked up with `GetComponent` is a **parent**: you can create under it
and read it, nothing else.

## Errors

Every call **raises** on failure, as Jagex's API does not return error codes. The error is a
table that prints as text:

```lua
local ok, err = pcall(function() layer:Set({ op_config = 1 }) end)
-- err.kind    "refused" (the agent said no), "timeout" (no answer in time), "unsupported"
-- err.verb    "ui.set"
-- err.message "ui: prop forbidden on agent components (no op, drag or target configuration)"
if not ok and ui.is_error(err) then print(err.kind, err.message) end
```

`err.message` is the agent's text, verbatim. `ui.Interfaces:GetComponent` is the one call that
returns instead: `nil, message, kind`. Its third value tells the cases apart: `"refused"` means
the component is not there, `"timeout"` means no answer came. Passing that `nil` on as a parent
raises kind `"refused"` with `"parent is nil (GetComponent found nothing?)"`, and sends nothing.

Jagex's interaction configurations (`opConfig`, `dragConfig`, `swipeConfig`, `pinchConfig`,
`cursorConfig`, `paramsConfig`, `FlagRestricted`) raise kind `"refused"` with the agent's own
text, `ui: prop forbidden on agent components (no op, drag or target configuration)`, without a
call: the agent never puts them on a component it made.

## Lifetime

Components belong to the Game's own connection to the agent; no other Game or script shares
it. When a `bot.run` (or a GUI run) ends, the framework releases them with **one**
`ui.destroy_all` on that connection, before it detaches. One call, so a stalled agent costs a
single timeout however many components there are. Every component it held is then forgotten as
`released` and its `DESTROYED` callbacks run, whatever the agent answered. When the host then
detaches, it holds no component, so it sends no second `ui.destroy_all` (native host 1.1.0
or later; an older host sends one that finds nothing). The host still sends one if the agent may
still hold a component: the framework's `ui.destroy_all` failed, or a ui call went unanswered
after it. The agent releases
whatever is left when the connection closes. Because the
connection is the Game's own, another connection's components are never touched.
`comp:Destroy()` is the only per-component destroy.

The game can also take a component down: its parent closed (on logout, for example), or the
agent removed it for safety. That arrives as a `destroyed` event with a `reason`
(`parent_gone`, `removed`, `server_events`, `interface_unreadable`). The component is then
forgotten, so it is never destroyed twice, and `comp:IsDestroyed()` returns `true, reason`.
A `Destroy()` that races that event is refused by the agent and handled the same way (reason
`removed`).

## Events

Each event is `{ kind = "ui", name = "ui", pid, handle, hook, reason, truncated, component }`,
plus the hook's own fields. Hook `"overflow"` (handle 0, `dropped = n`) reports events the
host had to drop. On an overflow the framework logs it, asks the agent for this connection's
handles (`ui.list`), and forgets every held component the agent no longer lists, running its
`DESTROYED` callbacks with reason `unknown`. One read hands over at most 32 events, so the
framework reads again until a read comes back short.

**When callbacks run.** Events are read (and callbacks run) only at these points, never in the
background. In a `bot.run` that is while `sleep_ticks` waits and before each `on_loop`, so a long
blocking call in the script delays every callback until it returns. Meanwhile the host keeps a
bounded queue: if it overflows, the oldest events are dropped, a click or a selection among them,
and the drop is logged (the `overflow` event above). Once `on_stop` has returned (or the run
crashed), the end-of-run release runs no more click, content or selection callbacks; `DESTROYED`
callbacks still run with reason `released`. A callback that itself sleeps or calls `ui:poll()`
gets nothing from that nested read; the remaining events stay in order for the outer one.

They are read without waiting, from three places:

- `bot.run` reads them about once per server tick while the script sleeps, the lobby included.
- A `botwithus.clients` manager delivers the events of every Game it attached through
  `cm:on("ui", fn)`, `cm:on_event(fn)`, `cm:poll()` and `cm:pump()`.
- `ui:poll()` reads them now.

A `destroyed` event runs the component's `Subscribe` callbacks first, then the `ui:on_event`
listeners.
