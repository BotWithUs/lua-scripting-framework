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

T["ui: GetComponent takes Jagex's four forms"] = function(assert_)
  local _, _, ui, f = setup()
  local a = ui.Interfaces:GetComponent(IFACE, COMP)
  local b = ui.Interfaces:GetComponent((IFACE << 16) | COMP)
  assert_(a == b, "combined id resolves to the same component object")
  assert_(a.isJagex == true and a.interfaceID == IFACE and a.staticID == COMP, "info fields")
  local layer = ui.Layer.new(a, 3, 7)
  local key = layer.key
  assert_(key == 7 + ((3 + 15) << 8), "the agent-side key for (3, 7)")
  local child = ui.Interfaces:GetComponent(IFACE, COMP, 3, 7)
  assert_(child and child.isJagex and child.key == key, "4-arg form looks the child up by its key")
  local child3 = ui.Interfaces:GetComponent((IFACE << 16) | COMP, 3, 7)
  assert_(child3 == child, "3-arg combined form")
  local lookups = f.calls_of("ui_get_component")
  assert_(lookups[1].args[4] == nil and lookups[3].args[4] == key, "key nil, then the child key")
end

T["ui: GetComponent returns nil, the agent's text and kind when it is not there"] = function(assert_)
  local _, _, ui = setup()
  local comp, err, kind = ui.Interfaces:GetComponent(9999, 1)
  assert_(comp == nil and err == "ui: component not found" and kind == "refused", tostring(err))
end

T["ui: child_key mirrors the agent's key math and its ranges"] = function(assert_)
  assert_(GameUi.child_key(0, 5) == 5, "category 0 is the id itself")
  assert_(GameUi.child_key(1, 0) == 16 << 8, "category 1")
  assert_(GameUi.child_key(234, 255) == 255 + (249 << 8), "the top of the range")
  assert_(GameUi.child_key(235, 0) == nil, "category above 234")
  assert_(GameUi.child_key(1, 256) == nil, "dynamic id above 255 with a category")
  assert_(GameUi.child_key(0, 0x1000) == nil, "dynamic id above 0xFFF in category 0")
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

T["ui: the end of a run destroys exactly its components, newest first, before the host's release"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local f = b._ui
  local made = {}
  bot.run(ui_script(made), { max_iters = 1 })
  local destroys = f.calls_of("ui_destroy")
  assert_(#destroys == 4, "one ui.destroy per component: " .. #destroys)
  for i, d in ipairs(destroys) do
    assert_(d.args[2] == made[#made + 1 - i].handle, "newest first (children before parents)")
  end
  assert_(#f.calls_of("ui_destroy_all") == 0, "the framework never sends ui.destroy_all")
  local release = f.calls_of("host_release")
  assert_(#release == 1 and f.host_released == 0, "the host's release found nothing left")
  assert_(f.calls[#f.calls].fn == "host_release", "the host released last, at detach")
end

T["ui: a run on a caller's Game cleans up its UI and leaves another connection's alone"] = function(assert_)
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
  assert_(#f.calls_of("ui_destroy_all") == 0 and #f.calls_of("host_release") == 0, "no blanket release")
end

T["ui: the end of a run skips what the game already took down"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local f = b._ui
  local made = {}
  local script = ui_script(made)
  script.on_loop = function()
    f.game_destroy(made[1].handle, "parent_gone")   -- the layer and its rectangle
    return -1
  end
  bot.run(script, { max_iters = 1 })
  local destroyed = {}
  for _, d in ipairs(f.calls_of("ui_destroy")) do destroyed[d.args[2]] = true end
  assert_(not destroyed[made[1].handle] and not destroyed[made[2].handle], "gone ones skipped")
  assert_(destroyed[made[3].handle] and destroyed[made[4].handle], "the rest destroyed")
  assert_(#f.calls_of("ui_destroy") == 2, "two destroys")
end

T["ui: a refusal during the end-of-run release is not an error"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local f = b._ui
  local made = {}
  local script = ui_script(made)
  script.on_loop = function()
    f.comps[made[3].handle] = nil   -- gone in the game with no event (a quarantine, a race)
    return -1
  end
  bot.run(script, { max_iters = 1 })
  assert_(#f.calls_of("ui_destroy") == 4, "still tried each one")
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

return T
