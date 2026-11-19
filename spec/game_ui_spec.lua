-- spec/game_ui_spec.lua -- botwithus.game_ui (the Jagex-shaped plugin UI) against the fake
-- bwu.ui_* surface (spec/fake_bwu.lua), which keeps the agent's rules and refusal texts.

local fake_bwu = require("spec.fake_bwu")
local bot      = require("botwithus")
local GameUi   = require("botwithus.game_ui")

local T = {}

local IFACE, COMP = 1477, 61   -- TOPLEVEL_V2__GAME_AREA

-- Run fn with io.stderr captured; returns the lines written.
local function capture_stderr(fn)
  local real, lines = io.stderr, {}
  io.stderr = { write = function(self, ...)
    lines[#lines + 1] = table.concat({ ... })
    return self
  end }
  local ok, err = pcall(fn)
  io.stderr = real
  if not ok then error(err, 0) end
  return lines
end

local function setup(opts)
  local b = fake_bwu.new(opts)
  _G.bwu = b
  local game = bot.Game.attach(4242)
  return b, game, game:ui(), b._ui
end

-- pcall fn and return the error it raised (failing when it raised nothing).
local function raised(assert_, fn, ...)
  local ok, err = pcall(fn, ...)
  assert_(not ok, "expected an error")
  return err
end

-- Shape ------------------------------------------------------------------------------------

T["ui: game:ui(), ctx.ui and bot.ui(game) are the same namespace, made without a call"] = function(assert_)
  local b, game, ui, f = setup()
  assert_(game:ui() == ui and bot.ui(game) == ui, "one namespace per Game")
  assert_(#f.calls == 0, "creating it calls nothing")
  local ctx = require("botwithus.script")._make_ctx(game, function() return true end, nil)
  assert_(ctx.ui == ui, "ctx.ui is the Game's namespace")
  for _, name in ipairs({ "Canvas", "Rectangle", "Line", "Text", "Layer", "Button", "Sprite" }) do
    assert_(type(ui[name].new) == "function", name .. ".new exists")
  end
  assert_(ui.ComponentType.CANVAS == 8 and ui.ComponentType.LABEL == 2, "ComponentType values")
  assert_(ui.Hook.DESTROYED == "destroyed", "DESTROYED hook")
  assert_(b ~= nil)
end

T["ui: Jagex's canvas example ports verbatim and sends exactly these wire calls"] = function(assert_)
  local _, game, ui, f = setup()
  local parent = ui.Interfaces:GetComponent(IFACE, COMP)
  local c = ui.Canvas.new(parent)
  c:SetSize(300, 300)
  c:AddOutline(0, 0, 200, 200, 5, 0xFF0000FF)
  c:AddLine(20, 10, 200, 200, 2, 0x339000FF)
  local create = f.calls_of("ui_create")[1].args
  assert_(create[1] == game._host and create[2] == parent.handle and create[3] == "canvas",
    "created under the Jagex handle")
  assert_(create[4] == nil and create[5].category == nil and create[5].dynamic == nil,
    "no props, default key")
  local set = f.calls_of("ui_set")[1].args[3]
  assert_(set.width == 300 and set.height == 300 and set.width_pc == nil, "SetSize -> width/height")
  local ops = f.calls_of("ui_canvas")
  assert_(#ops == 2, "one ui.canvas per Add*")
  local o = ops[1].args[3][1]
  assert_(o.op == "outline" and o.x == 0 and o.width == 200 and o.thickness == 5
    and o.rgba == 0xFF0000FF, "outline args")
  local l = ops[2].args[3][1]
  assert_(l.op == "line" and l.x == 20 and l.y == 10 and l.end_x == 200 and l.end_y == 200
    and l.thickness == 2 and l.rgba == 0x339000FF, "line args")
  assert_(c.numElements == 2, "numElements reads back")
end

T["ui: every canvas shape maps to its wire op; Clear and Undo too"] = function(assert_)
  local _, _, ui, f = setup()
  local c = ui.Canvas.new(ui.Interfaces:GetComponent(IFACE, COMP))
  c:AddRectangle(1, 2, 3, 4, 0x11223344)
  c:AddGradientH(1, 2, 3, 4, 0x10, 0x20)
  c:AddGradientV(1, 2, 3, 4, 0x30, 0x40)
  c:AddTriangle(1, 2, 3, 4, 5, 6, 0x50)
  assert_(c:Undo() == 3, "Undo returns the element count")
  local ops = f.calls_of("ui_canvas")
  local r, gh, gv, t = ops[1].args[3][1], ops[2].args[3][1], ops[3].args[3][1], ops[4].args[3][1]
  assert_(r.op == "rect" and r.height == 4 and r.rgba == 0x11223344, "rect")
  assert_(gh.op == "gradient_h" and gh.rgba_start == 0x10 and gh.rgba_end == 0x20, "gradient_h")
  assert_(gv.op == "gradient_v" and gv.rgba_start == 0x30, "gradient_v")
  assert_(t.op == "triangle" and t.x0 == 1 and t.y2 == 6 and t.rgba == 0x50, "triangle")
  assert_(c:Clear() == 0, "Clear empties it")
end

T["ui: Batch sends one ui.canvas, chunked at UI_CANVAS_OPS_MAX"] = function(assert_)
  local _, _, ui, f = setup()
  local c = ui.Canvas.new(ui.Interfaces:GetComponent(IFACE, COMP))
  local n = c:Batch(function(cv)
    for i = 1, 130 do cv:AddRectangle(i, i, 2, 2, 0xFFFFFFFF) end
  end)
  local calls = f.calls_of("ui_canvas")
  assert_(#calls == 2 and #calls[1].args[3] == 128 and #calls[2].args[3] == 2, "128 + 2")
  assert_(n == 130, "the element count after the last chunk")
  assert_(c:Batch(function() end) == nil and #f.calls_of("ui_canvas") == 2, "an empty batch sends nothing")
  local err = raised(assert_, c.Batch, c, function(cv) cv:AddLine(0, 0, 1, 1, 1, 1); error("boom") end)
  assert_(tostring(err):find("boom", 1, true) and #f.calls_of("ui_canvas") == 2, "a failed batch sends nothing")
end

T["ui: whole-number floats go as integers, so Jagex's Float thickness works"] = function(assert_)
  local _, _, ui, f = setup()
  local c = ui.Canvas.new(ui.Interfaces:GetComponent(IFACE, COMP))
  c:AddLine(0, 0, 10, 10, 2.0, 0xFF)
  assert_(math.type(f.calls_of("ui_canvas")[1].args[3][1].thickness) == "integer", "2.0 -> 2")
  local err = raised(assert_, c.AddLine, c, 0, 0, 10, 10, 1.5, 0xFF)
  assert_(err.kind == "refused" and err.message == "ui.canvas: op arguments are integers",
    "a fraction is the agent's refusal, verbatim: " .. tostring(err))
end

-- Interfaces:GetComponent --------------------------------------------------------------------

T["ui: GetComponent takes Jagex's static forms; a child is looked up by its key"] = function(assert_)
  local _, _, ui, f = setup()
  local a = ui.Interfaces:GetComponent(IFACE, COMP)
  local b = ui.Interfaces:GetComponent((IFACE << 16) | COMP)
  assert_(a == b, "combined id resolves to the same component object")
  assert_(a.isJagex == true and a.interfaceID == IFACE and a.staticID == COMP, "info fields")
  local layer = ui.Layer.new(a, 3, 7)
  local create_opts = f.calls_of("ui_create")[1].args[5]
  assert_(create_opts.category == 3 and create_opts.dynamic == 7, "category and dynamic id sent")
  local child = ui.Interfaces:GetComponentByKey(IFACE, COMP, layer.key)
  assert_(child and child.isJagex and child.key == layer.key and child ~= layer,
    "a lookup by key is a separate, Jagex (read-only) handle")
  local lookups = f.calls_of("ui_get_component")
  assert_(lookups[1].args[4] == nil and lookups[3].args[4] == layer.key, "key nil, then the key")
  local before = #f.calls
  for _, fn in ipairs({
    function() ui.Interfaces:GetComponent(IFACE, COMP, 3, 7) end,
    function() ui.Interfaces:GetComponent((IFACE << 16) | COMP, 3, 7) end,
  }) do
    local err = raised(assert_, fn)
    assert_(err.kind == "unsupported", "the category / dynamic forms: " .. tostring(err))
  end
  assert_(#f.calls == before, "and they send nothing")
end

T["ui: GetComponent returns nil, the agent's text and kind when it is not there"] = function(assert_)
  local _, _, ui = setup()
  local comp, err, kind = ui.Interfaces:GetComponent(9999, 1)
  assert_(comp == nil and err == "ui: component not found" and kind == "refused", tostring(err))
end


-- Properties -------------------------------------------------------------------------------

T["ui: properties map to the wire props and read back"] = function(assert_)
  local _, _, ui, f = setup()
  local area = ui.Interfaces:GetComponent(IFACE, COMP)
  local line = ui.Line.new(area)
  line.width = 3            -- Jagex: a Line's width is its stroke
  line.invert = true
  local rect = ui.Rectangle.new(area)
  rect.fill = true
  rect.outlineThickness = 2
  rect.rgba = 0x0000FF77
  rect.clickthrough = true
  local text = ui.Text.new(area)
  text.content = "Hello World"
  local sets = f.calls_of("ui_set")
  assert_(sets[1].args[3].line_width == 3 and sets[2].args[3].line_invert == true, "line props")
  assert_(sets[3].args[3].fill == true and sets[4].args[3].outline_thickness == 2, "rectangle props")
  assert_(sets[5].args[3].rgba == 0x0000FF77 and sets[6].args[3].clickthrough == true, "common props")
  assert_(sets[7].args[3].text == "Hello World", "content -> text")
  assert_(line.width == 3 and line.invert == true, "line reads back")
  assert_(rect.fill == true and rect.outlineThickness == 2 and rect.rgba == 0x0000FF77, "rect reads back")
  assert_(text.content == "Hello World", "content reads back with ui.get's content")
  assert_(f.calls_of("ui_get")[#f.calls_of("ui_get")].args[3] == true, "asked for content")
  assert_(text.typeName == "text" and text.type == ui.ComponentType.LABEL, "type from the info")
  assert_(text.parent == area, "parent is the parent's object")
end

T["ui: SetPos/SetX/SetWidth send their percentages as numbers"] = function(assert_)
  local _, _, ui, f = setup()
  local c = ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  c:SetPos(0, 0, 0.5, 0.5, -0.5, -0.5)
  c:SetX(4, 1)
  c:SetWidth(10, 0)
  local sets = f.calls_of("ui_set")
  local p = sets[1].args[3]
  assert_(p.x == 0 and p.x_parent_pc == 0.5 and p.y_self_pc == -0.5, "SetPos")
  assert_(math.type(sets[2].args[3].x_parent_pc) == "float", "an integer percentage goes as a float")
  assert_(math.type(sets[3].args[3].width_pc) == "float", "SetWidth's percentage")
  local r = c:Get()
  assert_(r.x == 4 and r.width == 10, "Get() returns the readback")
end

T["ui: x, y, width, height are read-only like Jagex's; unknown names raise"] = function(assert_)
  local _, _, ui = setup()
  local c = ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  local err = raised(assert_, function() c.x = 5 end)
  assert_(tostring(err):find("read-only", 1, true), tostring(err))
  err = raised(assert_, function() return c.alpha end)
  assert_(err.kind == "unsupported", "alpha has no wire form yet")
  err = raised(assert_, function() c.colour = 1 end)
  assert_(err.kind == "unsupported", "colour has no wire form yet")
end

-- Errors -----------------------------------------------------------------------------------

T["ui: the agent's refusals raise verbatim, with kind refused"] = function(assert_)
  local _, _, ui = setup()
  local area = ui.Interfaces:GetComponent(IFACE, COMP)
  local layer = ui.Layer.new(area)
  local err = raised(assert_, layer.Set, layer, { op_config = 1 })
  assert_(GameUi.is_error(err) and ui.is_error(err), "a ui error")
  assert_(err.kind == "refused" and err.verb == "ui.set" and err.message == fake_bwu.UI_FORBIDDEN,
    "forbidden prop, verbatim")
  assert_(tostring(err) == "botwithus.ui: ui.set refused: " .. fake_bwu.UI_FORBIDDEN, "prints")
  err = raised(assert_, area.SetPos, area, 1, 1)
  assert_(err.message == fake_bwu.UI_READ_ONLY, "a Jagex component is read-only")
  err = raised(assert_, ui.Button.new, area)
  assert_(err.message == "ui type not supported yet: button", "a later type: the agent's text")
  err = raised(assert_, function() layer.hidden = true end)
  assert_(err.message == "ui prop not supported yet: hidden", "hidden: the agent's text")
  err = raised(assert_, ui.Layer.new, area, 0)
  assert_(err.message == "ui: bad_param category (1..234)", "category 0 is refused")
end

T["ui: a timeout raises with kind timeout"] = function(assert_)
  local _, _, ui, f = setup()
  local area = ui.Interfaces:GetComponent(IFACE, COMP)
  f.timeout = true
  local err = raised(assert_, ui.Layer.new, area)
  assert_(err.kind == "timeout" and err.message == "rpc_timeout", tostring(err))
end

T["ui: canvas text and sprites, Vector4 colours and other hooks are unsupported here"] = function(assert_)
  local _, _, ui, f = setup()
  local c = ui.Canvas.new(ui.Interfaces:GetComponent(IFACE, COMP))
  local before = #f.calls
  for _, fn in ipairs({
    function() c:AddText(0, 0, "x", 1, 0xFF) end,
    function() c:AddSprite(0, 0, 1, 1, 1, 0xFF) end,
    function() c:AddRectangle(0, 0, 1, 1, { 1, 0, 0, 1 }) end,
    function() c:Subscribe(ui.Hook.ONCLICK, function() end) end,
    function() ui.Interfaces:GetInterface(1477) end,
  }) do
    local err = raised(assert_, fn)
    assert_(err.kind == "unsupported" and err.message:find("not supported yet", 1, true), tostring(err))
  end
  assert_(#f.calls == before, "none of them reaches the agent")
end

T["ui: a detached Game raises the framework's detached error"] = function(assert_)
  local _, game, ui = setup()
  game:detach()
  local ok, err = pcall(function() return ui.Interfaces:GetComponent(IFACE, COMP) end)
  assert_(not ok and tostring(err):find("detached", 1, true), tostring(err))
end

T["ui: a host without bwu.ui_* is named in the error"] = function(assert_)
  local _, _, ui = setup({ no_ui = true })
  local ok, err = pcall(function() return ui.Layer.new(1) end)
  assert_(not ok and tostring(err):find("plugin-UI surface", 1, true), tostring(err))
end

-- Destroy, order ----------------------------------------------------------------------------

T["ui: Destroy, MoveToFront and MoveToBack; a second Destroy sends nothing"] = function(assert_)
  local _, _, ui, f = setup()
  local c = ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  c:MoveToFront()
  c:MoveToBack()
  local orders = f.calls_of("ui_order")
  assert_(orders[1].args[3] == "front" and orders[2].args[3] == "back", "order")
  assert_(c:Destroy() == true, "freed")
  assert_(c:Destroy() == false and #f.calls_of("ui_destroy") == 1, "idempotent, no second call")
  assert_(c:IsDestroyed(), "IsDestroyed")
  assert_(#ui:components() == 0, "no longer held")
end

-- Events -----------------------------------------------------------------------------------

T["ui: a destroyed event runs Subscribe callbacks, forgets the handle and reaches on_event"] = function(assert_)
  local _, game, ui, f = setup()
  local area = ui.Interfaces:GetComponent(IFACE, COMP)
  local layer = ui.Layer.new(area)
  local inner = ui.Rectangle.new(layer)
  local seen, order, all = {}, {}, {}
  layer:Subscribe(ui.Hook.DESTROYED, function(comp, reason) seen[#seen + 1] = { comp, reason } end)
  inner:Subscribe(ui.Hook.DESTROYED, "a", function() order[#order + 1] = "a"; return false end)
  inner:Subscribe(ui.Hook.DESTROYED, "b", function() order[#order + 1] = "b" end)
  ui:on_event(function(ev) all[#all + 1] = ev end)
  f.game_destroy(layer.handle, "parent_gone")
  local events = ui:poll()
  assert_(#events == 2 and #all == 2, "the layer and its child")
  assert_(seen[1][1] == layer and seen[1][2] == "parent_gone", "callback(comp, reason)")
  assert_(#order == 1 and order[1] == "a", "returning false stops later callbacks")
  local ev = all[1]
  assert_(ev.kind == "ui" and ev.hook == "destroyed" and ev.handle == layer.handle
    and ev.component == layer and ev.pid == game:pid(), "event shape")
  assert_(layer:IsDestroyed() and inner:IsDestroyed() and #ui:components() == 0, "forgotten")
  assert_(layer:Destroy() == false and #f.calls_of("ui_destroy") == 0, "never destroyed twice")
end

T["ui: Subscribe with the same id replaces; Unsubscribe removes"] = function(assert_)
  local _, _, ui, f = setup()
  local layer = ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  local got = {}
  layer:Subscribe(ui.Hook.DESTROYED, "x", function() got[#got + 1] = 1 end)
  layer:Subscribe(ui.Hook.DESTROYED, "x", function() got[#got + 1] = 2 end)
  layer:Subscribe(ui.Hook.DESTROYED, function() got[#got + 1] = 3 end)
  layer:Unsubscribe(ui.Hook.DESTROYED)
  f.game_destroy(layer.handle)
  ui:poll()
  assert_(#got == 1 and got[1] == 2, "only the replacement ran")
end

T["ui: the overflow event is surfaced with dropped"] = function(assert_)
  local _, game, ui, f = setup()
  ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  f.overflow(game._host, 7)
  local ev = ui:poll()[1]
  assert_(ev.hook == "overflow" and ev.handle == 0 and ev.dropped == 7 and ev.kind == "ui", "overflow")
end

T["ui: nothing is polled before the first ui call"] = function(assert_)
  local b, game = setup()
  game:_pump_ui()
  game:ui():poll()
  assert_((b._ui.polls or 0) == 0, "no poll before any ui verb")
end

T["ui: a failing poll in the framework's own loop is logged, not raised"] = function(assert_)
  local _, game, ui, f = setup()
  ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  f.poll_error = "pipe lost"
  local lines = capture_stderr(function() game:_pump_ui() end)
  assert_(#lines == 1 and lines[1]:find("pipe lost", 1, true), "logged once")
  local ok = pcall(ui.poll, ui)
  assert_(not ok, "the script's own ui:poll() raises it")
end

-- Lifetime ---------------------------------------------------------------------------------

-- A run that makes a layer, a nested rectangle, a canvas and a text, then ends.
local function ui_script(made)
  return {
    manifest = { name = "ui", version = "1", author = "t" },
    on_start = function(ctx)
      local ui = ctx.ui
      local area = ui.Interfaces:GetComponent(IFACE, COMP)
      local layer = ui.Layer.new(area)
      made[#made + 1] = layer
      made[#made + 1] = ui.Rectangle.new(layer)
      made[#made + 1] = ui.Canvas.new(area)
      made[#made + 1] = ui.Text.new(area)
    end,
    on_loop = function() return -1 end,
  }
end

T["ui: the end of a run releases with one ui.destroy_all, before the host's own release"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local f = b._ui
  local made, reasons = {}, {}
  local script = ui_script(made)
  script.on_loop = function()
    for _, c in ipairs(made) do
      c:Subscribe("destroyed", function(_, r) reasons[#reasons + 1] = r end)
    end
    return -1
  end
  bot.run(script, { max_iters = 1 })
  assert_(#f.calls_of("ui_destroy_all") == 1, "one ui.destroy_all")
  assert_(#f.calls_of("ui_destroy") == 0, "no per-handle destroys")
  assert_(#reasons == 4 and reasons[1] == "released", "every component's DESTROYED ran: released")
  for _, c in ipairs(made) do assert_(c:IsDestroyed(), "forgotten") end
  local release = f.calls_of("host_release")
  assert_(#release == 1 and f.host_released == 0, "the host's release found nothing left")
  assert_(f.calls[#f.calls].fn == "host_release", "the host released last, at detach")
end

T["ui: on a stalled agent the end-of-run release costs one call, not one per component"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local f = b._ui
  local made = {}
  bot.run({
    manifest = { name = "ui", version = "1", author = "t" },
    on_start = function(ctx)
      local area = ctx.ui.Interfaces:GetComponent(IFACE, COMP)
      for i = 1, 20 do made[i] = ctx.ui.Layer.new(area) end
    end,
    on_loop = function() f.stalled = true; return -1 end,
  }, { max_iters = 1 })
  assert_(f.stalled_calls == 1, "one stalled call: " .. tostring(f.stalled_calls))
  assert_(f.stalled_ms <= 5000, "a stop costs one timeout: " .. tostring(f.stalled_ms) .. " ms")
  for _, c in ipairs(made) do assert_(c:IsDestroyed(), "all forgotten anyway") end
end

T["ui: a run on a caller's Game releases on its own connection and leaves another's alone"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local f = b._ui
  local other = bot.Game.attach(4242)           -- another connection to the same client
  local keep = other:ui().Layer.new(other:ui().Interfaces:GetComponent(IFACE, COMP))
  local game = bot.Game.attach(4242)
  bot.run(ui_script({}), { game = game, max_iters = 1 })
  assert_(game:is_attached(), "the caller keeps its Game")
  assert_(f.live(game._host) == 0, "the run's components are gone")
  assert_(f.live(other._host) == 1 and not keep:IsDestroyed(), "the other connection's stay")
  local alls = f.calls_of("ui_destroy_all")
  assert_(#alls == 1 and alls[1].args[1] == game._host, "the one release went on the run's connection")
end

T["ui: what the game already took down keeps its own reason at the end-of-run release"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local f = b._ui
  local made, reasons = {}, {}
  local script = ui_script(made)
  script.on_loop = function()
    for i, c in ipairs(made) do
      c:Subscribe("destroyed", function(_, r) reasons[i] = (reasons[i] or "") .. r end)
    end
    f.game_destroy(made[1].handle, "parent_gone")   -- the layer and its rectangle
    return -1
  end
  bot.run(script, { max_iters = 1 })
  assert_(reasons[1] == "parent_gone" and reasons[2] == "parent_gone", "taken down by the game, once")
  assert_(reasons[3] == "released" and reasons[4] == "released", "the rest released")
end

T["ui: an exited client gets no release call"] = function(assert_)
  local _, game, ui, f = setup()
  local layer = ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  game:_mark_exited()
  assert_(ui:release() == 0, "nothing sent")
  assert_(#f.calls_of("ui_destroy_all") == 0 and not layer:IsDestroyed(), "no call, nothing forgotten")
end

T["ui: the runner reads ui events once per tick, so callbacks run during a run"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local f = b._ui
  local layer, reason
  local iters = 0
  bot.run({
    manifest = { name = "ui", version = "1", author = "t" },
    on_start = function(ctx)
      layer = ctx.ui.Layer.new(ctx.ui.Interfaces:GetComponent(IFACE, COMP))
      layer:Subscribe(ctx.ui.Hook.DESTROYED, function(_, r) reason = r end)
    end,
    on_loop = function(ctx)
      iters = iters + 1
      if iters == 1 then f.game_destroy(layer.handle, "server_events") end
      return 3
    end,
  }, { max_iters = 2 })
  assert_(reason == "server_events", "the callback ran inside the run: " .. tostring(reason))
  assert_(#f.calls_of("ui_destroy") == 0, "and the end of the run did not destroy it again")
end

T["ui: a sleep on a stalled tick (the lobby) still reads ui events, about once a tick"] = function(assert_)
  local b, game, ui, f = setup()
  local Script = require("botwithus.script")
  local layer = ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  local reason
  layer:Subscribe(ui.Hook.DESTROYED, function(_, r) reason = r end)
  b.refresh = function() return true end            -- the tick stands still
  local waits = 0
  local polls_before = f.polls or 0
  local function wait()
    waits = waits + 1
    if waits == 3 then f.game_destroy(layer.handle, "parent_gone") end
    return waits < 200   -- then stop the sleep
  end
  Script._sleep_ticks(game, wait, 1)
  assert_(reason == "parent_gone", "delivered during the stall: " .. tostring(reason))
  local polls = (f.polls or 0) - polls_before
  local expected = 200 * Script.TICK_POLL_MS // Script.UI_PUMP_MS
  assert_(polls >= expected - 1 and polls <= expected + 1, "about once per tick, not per wait: " .. polls)
end

T["ui: a one-tick sleep still reads ui events (the GUI worker's loop relies on it)"] = function(assert_)
  local _, game, ui, f = setup()
  local Script = require("botwithus.script")
  local layer = ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  local reason
  layer:Subscribe(ui.Hook.DESTROYED, function(_, r) reason = r end)
  f.game_destroy(layer.handle, "removed")
  assert_(Script._sleep_ticks(game, function() return true end, 1), "the tick advanced")
  assert_(reason == "removed", "pumped before returning: " .. tostring(reason))
end

T["ui: detach marks every component destroyed (the host released them)"] = function(assert_)
  local _, game, ui, f = setup()
  local c = ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  game:detach()
  assert_(c:IsDestroyed() and #f.calls_of("host_release") == 1, "released by the host")
end

-- clients ----------------------------------------------------------------------------------

T["ui: a clients manager delivers ui events as kind ui through on, on_event, poll and pump"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local f = b._ui
  local cm = bot.clients.new()
  local game = assert(cm:attach_pid(4242))
  local ui = game:ui()
  local layer = ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  local by_kind, all = {}, {}
  cm:on("ui", function(ev) by_kind[#by_kind + 1] = ev end)
  cm:on("client_exited", function() error("not this kind") end)
  cm:on_event(function(ev) all[#all + 1] = ev end)
  f.game_destroy(layer.handle, "parent_gone")
  f.overflow(game._host, 3)
  local ev = cm:poll(0)
  assert_(ev and ev.kind == "ui" and ev.hook == "destroyed" and ev.handle == layer.handle
    and ev.reason == "parent_gone" and ev.pid == 4242, "the destroyed event first")
  assert_(cm:pump(0) == 1, "pump handles the overflow")
  assert_(#by_kind == 2 and #all == 2 and by_kind[2].hook == "overflow" and by_kind[2].dropped == 3,
    "both reached on('ui') and on_event")
  assert_(layer:IsDestroyed(), "the Game's ui forgot it too")
  assert_(cm:poll(0) == nil, "nothing left")
end

T["ui: a manager stops reading a Game's ui events once it is detached"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local cm = bot.clients.new()
  local game = assert(cm:attach_pid(4242))
  game:ui().Layer.new(game:ui().Interfaces:GetComponent(IFACE, COMP))
  cm:detach(nil)    -- no client id: nothing matches
  game:detach()
  local polls = b._ui.polls or 0
  cm:poll(0)
  assert_((b._ui.polls or 0) == polls, "no poll on a released claim")
end

-- Review fixes ---------------------------------------------------------------------------------

T["ui: Destroy after the game removed it (event not read yet) forgets it and returns false"] = function(assert_)
  local _, _, ui, f = setup()
  local layer = ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  local reasons = {}
  layer:Subscribe(ui.Hook.DESTROYED, function(_, r) reasons[#reasons + 1] = r end)
  f.game_destroy(layer.handle, "parent_gone")   -- queued, not polled
  local ok, freed = pcall(layer.Destroy, layer)
  assert_(ok, "no raise: " .. tostring(freed))
  assert_(freed == false and layer:IsDestroyed(), "returns false and is forgotten")
  assert_(#reasons == 1 and reasons[1] == "removed", "DESTROYED ran with removed")
  ui:poll()   -- the late event for it
  assert_(#reasons == 1, "the late event does not run the callbacks again")
  assert_(layer:Destroy() == false and #f.calls_of("ui_destroy") == 1, "and nothing more is sent")
end

T["ui: Destroy still raises on a timeout and keeps the component"] = function(assert_)
  local _, _, ui, f = setup()
  local layer = ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  f.timeout = true
  local err = raised(assert_, layer.Destroy, layer)
  assert_(err.kind == "timeout" and not layer:IsDestroyed(), "outcome unknown: kept")
end

T["ui: Destroy on a Jagex component raises the read-only refusal and keeps it"] = function(assert_)
  local _, _, ui = setup()
  local area = ui.Interfaces:GetComponent(IFACE, COMP)
  local err = raised(assert_, area.Destroy, area)
  assert_(err.message == fake_bwu.UI_READ_ONLY and not area:IsDestroyed(), tostring(err))
end

T["ui: Jagex's interaction configs raise the agent's forbidden refusal without a call"] = function(assert_)
  local _, _, ui, f = setup()
  local layer = ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  local before = #f.calls
  for _, name in ipairs({ "opConfig", "dragConfig", "swipeConfig", "pinchConfig", "cursorConfig",
                          "paramsConfig", "FlagRestricted" }) do
    local err = raised(assert_, function() layer[name] = 1 end)
    assert_(err.kind == "refused" and err.message == fake_bwu.UI_FORBIDDEN, name .. ": " .. tostring(err))
    err = raised(assert_, function() return layer[name] end)
    assert_(err.kind == "refused", name .. " read")
  end
  assert_(GameUi.FORBIDDEN_TEXT == fake_bwu.UI_FORBIDDEN, "the host's exact text")
  assert_(#f.calls == before, "nothing sent")
end

T["ui: one poll reads every queued event, past the binding's 32 per call"] = function(assert_)
  local _, _, ui, f = setup()
  local area = ui.Interfaces:GetComponent(IFACE, COMP)
  for _ = 1, 40 do ui.Layer.new(area) end
  for _, c in ipairs(ui:components()) do f.game_destroy(c.handle, "parent_gone") end
  local before = f.polls or 0
  local events = ui:poll()
  assert_(#events == 40, "all 40: " .. #events)
  assert_((f.polls or 0) - before == 2, "32, then 8 (fewer than 32 ends it)")
  assert_(#ui:components() == 0, "all forgotten")
end

T["ui: an overflow reconciles with ui.list: held handles it no longer lists are gone"] = function(assert_)
  local _, game, ui, f = setup()
  local area = ui.Interfaces:GetComponent(IFACE, COMP)
  local lost = ui.Layer.new(area)
  local kept = ui.Layer.new(area)
  local reason
  lost:Subscribe(ui.Hook.DESTROYED, function(_, r) reason = r end)
  f.comps[lost.handle] = nil            -- gone, and its destroyed event was dropped
  f.overflow(game._host, 1)
  local lines = capture_stderr(function() ui:poll() end)
  assert_(lost:IsDestroyed() and reason == "unknown", "the missing one is gone: unknown")
  assert_(not kept:IsDestroyed() and not area:IsDestroyed(), "listed ones stay")
  assert_(#f.calls_of("ui_list") == 1, "one ui.list")
  assert_(#lines >= 1 and lines[1]:find("dropped", 1, true), "the overflow is logged")
end

T["ui: a nil parent raises kind refused, with a hint, and sends nothing"] = function(assert_)
  local _, _, ui, f = setup()
  local area = ui.Interfaces:GetComponent(9999, 1)   -- not there
  local before = #f.calls
  local err = raised(assert_, ui.Layer.new, area)
  assert_(GameUi.is_error(err) and err.kind == "refused"
    and err.message == "parent is nil (GetComponent found nothing?)", tostring(err))
  assert_(#f.calls == before, "nothing sent")
  f.timeout = true
  local comp, _, kind = ui.Interfaces:GetComponent(IFACE, COMP)
  assert_(comp == nil and kind == "timeout", "the third value tells a timeout from not found")
end

T["ui: visibleGlobal and isRestricted use Jagex's names; local visible is unsupported"] = function(assert_)
  local _, _, ui = setup()
  local text = ui.Text.new(ui.Interfaces:GetComponent(IFACE, COMP))
  assert_(text.visibleGlobal == true and text.isRestricted == false and text.isQuarantined == false,
    "readback names")
  local err = raised(assert_, function() return text.visible end)
  assert_(err.kind == "unsupported", "visible (local) has no wire form yet")
end

T["ui: ui.Hook lists every Jagex hook; Subscribe raises for any but DESTROYED"] = function(assert_)
  local _, _, ui = setup()
  for _, name in ipairs({ "ONCLICK", "ONSWIPEVERTICAL", "ONCUTSCENEFINISHED", "ONTARGETLEAVE",
                          "ONVARPTRANSMIT", "ONCAMERAUPDATETRANSMIT", "ONDIALOGABORT",
                          "ONGAMEPADTRIGGER" }) do
    assert_(ui.Hook[name] ~= nil, name)
  end
  local count = 0
  for k in pairs(ui.Hook) do if k ~= "DESTROYED" then count = count + 1 end end
  assert_(count == #GameUi.JAGEX_HOOKS and count == 51, "51 Jagex hooks: " .. count)
  local layer = ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  local err = raised(assert_, layer.Subscribe, layer, ui.Hook.ONVARPTRANSMIT, function() end)
  assert_(err.kind == "unsupported", tostring(err))
end

-- Tests that kill surviving mutants -------------------------------------------------------------

T["ui: a failing Subscribe callback is logged; later callbacks and the poll go on"] = function(assert_)
  local _, _, ui, f = setup()
  local layer = ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  local second = false
  layer:Subscribe(ui.Hook.DESTROYED, "a", function() error("boom") end)
  layer:Subscribe(ui.Hook.DESTROYED, "b", function() second = true end)
  f.game_destroy(layer.handle)
  local ok
  local lines = capture_stderr(function() ok = pcall(ui.poll, ui) end)
  assert_(ok and second, "the poll did not raise and the next callback ran")
  assert_(#lines == 1 and lines[1]:find("boom", 1, true), "logged")
end

T["ui: a failing on_event listener is logged; later listeners still run"] = function(assert_)
  local _, _, ui, f = setup()
  local layer = ui.Layer.new(ui.Interfaces:GetComponent(IFACE, COMP))
  local second = false
  ui:on_event(function() error("bad listener") end)
  ui:on_event(function() second = true end)
  f.game_destroy(layer.handle)
  local ok
  local lines = capture_stderr(function() ok = pcall(ui.poll, ui) end)
  assert_(ok and second, "no raise, and the next listener ran")
  assert_(#lines == 1 and lines[1]:find("bad listener", 1, true), "logged")
end

T["ui: a component of another Game is refused as a parent before any call"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local f = b._ui
  local a = bot.Game.attach(4242)
  local other = bot.Game.attach(4242)
  local layer = a:ui().Layer.new(a:ui().Interfaces:GetComponent(IFACE, COMP))
  local creates = #f.calls_of("ui_create")
  local ok, err = pcall(other:ui().Layer.new, layer)
  assert_(not ok and tostring(err):find("another game", 1, true), tostring(err))
  assert_(#f.calls_of("ui_create") == creates, "nothing sent on the other connection")
end

T["ui: the run loop reads ui events every iteration, even with on_loop returning 0"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local f = b._ui
  local layer, seen_in_iter2
  local iters = 0
  bot.run({
    manifest = { name = "ui", version = "1", author = "t" },
    on_start = function(ctx)
      layer = ctx.ui.Layer.new(ctx.ui.Interfaces:GetComponent(IFACE, COMP))
    end,
    on_loop = function()
      iters = iters + 1
      if iters == 1 then f.game_destroy(layer.handle, "removed"); return 0 end
      seen_in_iter2 = layer:IsDestroyed()
      return -1
    end,
  }, { max_iters = 5 })
  assert_(seen_in_iter2 == true, "read at the top of the next iteration (no sleep in between)")
end

T["ui: a manager's listener is removed from a Game it no longer holds"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local cm = bot.clients.new()
  local game = assert(cm:attach_pid(4242))
  game:ui().Layer.new(game:ui().Interfaces:GetComponent(IFACE, COMP))
  game:detach()
  game._ui:dispatch({ handle = 999, hook = "destroyed", reason = "removed", truncated = false })
  assert_(#cm._ui_queue == 0, "nothing queued for the manager after detach")
end

T["ui: a manager hands out a queued ui event without waiting on the service"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local cm = bot.clients.new()
  local game = assert(cm:attach_pid(4242))
  local layer = game:ui().Layer.new(game:ui().Interfaces:GetComponent(IFACE, COMP))
  b._ui.game_destroy(layer.handle, "removed")
  local waits = #b._cm.polls
  local ev = cm:poll(500)
  assert_(ev and ev.kind == "ui" and ev.handle == layer.handle, "the ui event")
  assert_(#b._cm.polls == waits, "no wait on the service queue")
end

T["ui: a ui event that arrives during the service wait is handed out by that poll"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local cm = bot.clients.new()
  local game = assert(cm:attach_pid(4242))
  local layer = game:ui().Layer.new(game:ui().Interfaces:GetComponent(IFACE, COMP))
  b._cm.on_poll = function(c)
    c.on_poll = nil
    b._ui.game_destroy(layer.handle, "parent_gone")   -- arrives while the poll waits
  end
  local ev = cm:poll(200)
  assert_(ev and ev.kind == "ui" and ev.reason == "parent_gone", "returned by the same poll")
end

return T
