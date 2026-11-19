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
| `Subscribe(hook, [id,] fn)`, `Unsubscribe`, `UnsubscribeAll` | for `ui.Hook.DESTROYED` (ours, see below); `fn(component, reason, event)`, and returning `false` stops later callbacks |

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

## Not supported yet

These raise an error whose `kind` is `"unsupported"` (nothing is sent):
`Canvas:AddText`, `Canvas:AddSprite`, `Vector4` colours, `comp.colour` / `comp.alpha` /
`comp.rgb`, `comp.visible`, hooks other than `DESTROYED` (every Jagex hook name is in
`ui.Hook`, so `ui.Hook.ONCLICK` is never nil; `Subscribe` refuses it), `ui.Interfaces:GetInterface`, the
`GetComponent(..., categoryID, dynamicID)` forms, and the collection and layout methods
(`GetChild`, `SetAspectRatio`, ...).

These are sent to the agent, which refuses them today with its own message (for example
`ui type not supported yet: button` or `ui prop not supported yet: hidden`), and they will start
working when the agent supports them, with no change to your script: `ui.Sprite`,
`ui.Button`, `ui.Model`, `ui.Panel`, `ui.Grid`, `ui.InputField`, `ui.Check`, `ui.Slider`,
`ui.ComboField`, `ui.List`, and `comp.hidden`, `comp.enabled`, `Text.font`.

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
`released` and its `DESTROYED` callbacks run, whatever the agent answered. The host releases
again when it detaches (finding nothing), and the agent when the connection closes. Because the
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

They are read without waiting, from three places:

- `bot.run` reads them about once per server tick while the script sleeps, the lobby included.
- A `botwithus.clients` manager delivers the events of every Game it attached through
  `cm:on("ui", fn)`, `cm:on_event(fn)`, `cm:poll()` and `cm:pump()`.
- `ui:poll()` reads them now.

A `destroyed` event runs the component's `Subscribe` callbacks first, then the `ui:on_event`
listeners.
