-- spec/game_ui_p2_spec.lua -- botwithus.game_ui P2: the interactive types, hook subscriptions
-- and their typed arguments, against the fake bwu.ui_* surface (spec/fake_bwu.lua), which
-- keeps the agent's P2 rules and refusal texts (NXTLibrary a17edc4, native host 7bb38a4).

local fake_bwu = require("spec.fake_bwu")
local bot      = require("botwithus")
local GameUi   = require("botwithus.game_ui")

local T = {}

local IFACE, COMP = 1477, 61   -- TOPLEVEL_V2__GAME_AREA

local function setup(opts)
  local b = fake_bwu.new(opts)
  _G.bwu = b
  local game = bot.Game.attach(4242)
  local ui = game:ui()
  return b, game, ui, b._ui, ui.Interfaces:GetComponent(IFACE, COMP)
end

local function raised(assert_, fn, ...)
  local ok, err = pcall(fn, ...)
  assert_(not ok, "expected an error")
  return err
end

-- The props of the last ui.set.
local function last_set(f)
  local sets = f.calls_of("ui_set")
  return sets[#sets].args[3]
end

-- Shape ------------------------------------------------------------------------------------

T["p2: every interactive type has new and create; the enums are Jagex's"] = function(assert_)
  local _, _, ui = setup()
  for _, name in ipairs({ "Button", "Check", "InputField", "Slider", "ComboField", "List", "Panel",
                          "Grid" }) do
    assert_(type(ui[name].new) == "function" and type(ui[name].create) == "function", name)
  end
  assert_(ui.ComponentType.BUTTON == 9 and ui.ComponentType.COMBO_FIELD == 14
    and ui.ComponentType.PANEL == 21 and ui.ComponentType.GRID == 22, "ComponentType")
  assert_(ui.InputFieldActionResult.CONTENT_CHANGE == 0 and ui.InputFieldActionResult.SUBMIT == 2
    and ui.InputFieldActionResult.SUBMIT_ON_FOCUS_LOSS == 4, "InputFieldActionResult")
  assert_(ui.SelectionChangeEvent.DESELECTED == 0 and ui.SelectionChangeEvent.SELECTED == 1
    and ui.SelectionChangeEvent.ERROR_NOT_SELECTABLE == 3, "SelectionChangeEvent")
  assert_(ui.InputFieldFilterMode.NUMERIC == "numeric", "InputFieldFilterMode")
  assert_(ui.TextContentVisibilityMode.VISIBLE == 0, "TextContentVisibilityMode")
end

T["p2: each type is created with its wire type name, and a looked-up child gets its class"] = function(assert_)
  local _, _, ui, f, area = setup()
  local wire = { Button = "button", Check = "check", InputField = "input_field", Slider = "slider",
                 ComboField = "combo_field", List = "list", Panel = "panel", Grid = "grid" }
  for name, type_name in pairs(wire) do
    local c = ui[name].new(area)
    assert_(c.typeName == type_name and tostring(c) == "ui." .. name .. "(" .. c.handle .. ")", name)
    local creates = f.calls_of("ui_create")
    assert_(creates[#creates].args[3] == type_name, name .. " wire type")
  end
  local list = ui.List.new(area)
  local found = ui.Interfaces:GetComponentByKey(IFACE, COMP, list.key)
  assert_(getmetatable(found) == getmetatable(list), "a looked-up list is a ui.List")
end

-- Props and readback, per type -----------------------------------------------------------

T["p2: Button label, canToggle, isToggled and enabled map to the wire and read back"] = function(assert_)
  local _, _, ui, f, area = setup()
  local b = ui.Button.new(area)
  b.label = "Go"
  assert_(last_set(f).label == "Go", "label")
  b.canToggle = true
  assert_(last_set(f).can_toggle == true, "can_toggle")
  b.isToggled = true
  assert_(last_set(f).toggled == true, "toggled")
  b.enabled = false
  assert_(last_set(f).enabled == false, "enabled")
  assert_(b.label == "Go" and b.canToggle == true and b.isToggled == true and b.enabled == false,
    "every one reads back")
  local r = b:Get()
  assert_(r.label == "Go" and r.toggled == true and r.can_toggle == true, "Get has the widget keys")
end

T["p2: a toggle on a button that cannot toggle is the agent's refusal"] = function(assert_)
  local _, _, ui, _, area = setup()
  local b = ui.Button.new(area)
  local err = raised(assert_, function() b.isToggled = true end)
  assert_(err.kind == "refused" and err.verb == "ui.set"
    and err.message == "ui: toggled needs a button that can toggle (set can_toggle: true)", tostring(err))
end

T["p2: Check.value is the wire's checked; Check.label is the agent's not-supported refusal"] = function(assert_)
  local _, _, ui, f, area = setup()
  local c = ui.Check.new(area)
  c.value = true
  assert_(last_set(f).checked == true and c.value == true, "value <-> checked")
  local err = raised(assert_, function() c.label = "x" end)
  assert_(err.kind == "refused" and err.message == fake_bwu.UI_CHECK_LABEL, tostring(err))
end

T["p2: InputField content, filterMode, Setup and its readback (renders as the agent says)"] = function(assert_)
  local _, _, ui, f, area = setup()
  local i = ui.InputField.new(area)
  i.content = "hello"
  assert_(last_set(f).content == "hello", "content goes as content")
  assert_(i.content == "hello", "content reads back")
  local gets = f.calls_of("ui_get")
  assert_(gets[#gets].args[3] == true, "content is read with with_content")
  i.filterMode = ui.InputFieldFilterMode.NUMERIC
  assert_(last_set(f).filter == "numeric" and i.filterMode == ui.InputFieldFilterMode.NUMERIC,
    "filterMode <-> filter")
  i:Setup(ui.TextContentVisibilityMode.VISIBLE, ui.InputFieldFilterMode.ALPHANUMERIC, 20)
  local s = last_set(f)
  assert_(s.filter == "alphanumeric" and s.max_length == 20 and s.vis_mode == nil, "Setup: one set")
  assert_(i.maxLength == 20, "maxLength reads back")
  assert_(i.isFocused == false and i.renders == false and i.fontID == 495 and i.spriteID == -1,
    "focused, renders, font and sprite ids are passed on as read")
  local err = raised(assert_, i.Setup, i, ui.TextContentVisibilityMode.HIDDEN, "none", 5)
  assert_(err.kind == "refused" and err.message == fake_bwu.UI_LATER_PROPS.vis_mode, tostring(err))
  err = raised(assert_, function() i.maxLength = 3 end)
  assert_(err.kind ~= "refused" and tostring(err):find("read-only", 1, true), "maxLength is read-only")
end

T["p2: InputField:Blur returns whether it had focus; on another type it is refused"] = function(assert_)
  local _, _, ui, f, area = setup()
  local i = ui.InputField.new(area)
  assert_(i:Blur() == false, "no focus: false")
  f.focus(i.handle)
  assert_(i.isFocused == true, "focused reads back")
  assert_(i:Blur() == true and i.isFocused == false, "blurred")
  local b = ui.Button.new(area)
  local err = raised(assert_, GameUi._CLASSES.InputField._methods.Blur, b)
  assert_(err.kind == "refused" and err.verb == "ui.blur", tostring(err))
end

T["p2: Slider Setup, SetRange, SetValue and value; min/max/step/ticks read back"] = function(assert_)
  local _, _, ui, f, area = setup()
  local s = ui.Slider.new(area)
  assert_(s:Setup(10, 4) == true, "Setup returns true")
  local p = last_set(f)
  assert_(p.min == 0 and p.max == 10 and p.step == 1 and p.ticks == 10 and p.value == 4,
    "Setup(max, curValue): 0..max, step 1, all four together")
  assert_(s:SetRange(0, 100, 10, 10, 20) == true, "SetRange")
  p = last_set(f)
  assert_(p.min == 0 and p.max == 100 and p.step == 10 and p.ticks == 10 and p.value == 20, "range")
  assert_(s:SetValue(30) == true and last_set(f).value == 30, "SetValue")
  s.value = 40
  assert_(s.value == 40 and s.minValue == 0 and s.maxValue == 100 and s.step == 10 and s.ticks == 10,
    "readback")
  local err = raised(assert_, s.SetValue, s, 35)
  assert_(err.kind == "refused" and err.message == fake_bwu.UI_SLIDER_VALUE, tostring(err))
end

T["p2: a slider range missing one of the four is refused by the agent"] = function(assert_)
  local _, _, ui, _, area = setup()
  local s = ui.Slider.new(area)
  local err = raised(assert_, s.Set, s, { min = 0, max = 10 })
  assert_(err.kind == "refused" and err.message == "ui: slider min, max, step and ticks go together",
    tostring(err))
end

T["p2: ComboField entries, Select and the selection reads"] = function(assert_)
  local _, _, ui, f, area = setup()
  local c = ui.ComboField.new(area)
  assert_(c:SetEntries({ "Oak", "Willow", "Yew" }, 2) == true, "SetEntries returns true")
  local p = last_set(f)
  assert_(#p.entries == 3 and p.entries[1].id == 1 and p.entries[3].text == "Yew" and p.selected == 2,
    "a [String] list is ids 1..n, and the selection goes in the same call")
  assert_(c.selectedID == 2 and c.hasSelection and c.selectedLabel == "Willow" and c.numEntries == 3,
    "selection reads")
  c:SetEntries({ Maple = 9, Teak = 4 })
  p = last_set(f)
  assert_(p.entries[1].id == 4 and p.entries[1].text == "Teak" and p.entries[2].id == 9
    and p.selected == nil, "a label -> id map, sorted by id, no selection")
  assert_(c.selectedID == -1 and not c.hasSelection and c.selectedLabel == "", "nothing selected")
  assert_(c:Select(9) == true and last_set(f).selected == 9 and c.selectedLabel == "Maple", "Select")
  local es = c.entries
  assert_(#es == 2 and es[2].id == 9 and es[2].text == "Maple", "entries are { id, text }")
  c:UnselectAll()
  assert_(last_set(f).selected == -1 and c.selectedID == -1, "UnselectAll is -1")
  local err = raised(assert_, c.Select, c, 77)
  assert_(err.kind == "refused" and err.message == "ui: selected names no entry of this combo_field",
    tostring(err))
end

T["p2: Add, Remove, Clear and HasEntry rewrite the entries in one set, keeping the selection"] = function(assert_)
  local _, _, ui, f, area = setup()
  local c = ui.ComboField.new(area)
  c:SetEntries({ { id = 5, text = "a" }, { id = 6, text = "b" } }, 6)
  assert_(c:Add("c", 7) == true, "Add")
  local p = last_set(f)
  assert_(#p.entries == 3 and p.entries[3].id == 7 and p.entries[3].text == "c" and p.selected == 6,
    "appended, selection kept")
  assert_(p.entries[1].truncated == nil, "the readback-only keys are not sent back")
  assert_(c:Add("dup", 7) == false, "an existing id: false")
  assert_(c:HasEntry(7) and not c:HasEntry(8), "HasEntry")
  assert_(c:Remove(6) == true, "Remove")
  p = last_set(f)
  assert_(#p.entries == 2 and p.selected == -1 and c.selectedID == -1,
    "removing the selected one sends selected = -1 with the entries")
  assert_(c:Remove(6) == false, "a missing id: false")
  c:Clear()
  assert_(#last_set(f).entries == 0 and c.numEntries == 0, "Clear")
end

T["p2: List selection, maxSelected, entry flags and selectedEntries"] = function(assert_)
  local _, _, ui, f, area = setup()
  local l = ui.List.create(area, { selection_limit = 3,
    entries = { { id = 1, text = "Oak" }, { id = 2, text = "Willow" }, { id = 3, text = "Yew" } } })
  local create = f.calls_of("ui_create")[1].args[4]
  assert_(create.selection_limit == 3 and #create.entries == 3, "create sends entries in one call")
  assert_(l.maxSelected == 3, "maxSelected <-> selection_limit")
  l.maxSelected = 4
  assert_(last_set(f).selection_limit == 4, "maxSelected is writable")
  assert_(l:SetEntrySelected(2, true) == true and #last_set(f).selected == 1, "select 2")
  l:SetEntrySelected(3, true)
  local sel = last_set(f).selected
  assert_(#sel == 2 and sel[1] == 2 and sel[2] == 3, "select 3 keeps 2")
  assert_(l:GetEntrySelected(3) and not l:GetEntrySelected(1), "GetEntrySelected")
  assert_(l.numSelectedEntries == 2 and #l.selectedEntries == 2 and l.selectedEntries[1].text == "Willow",
    "selectedEntries")
  local ids = l.selectedIDs
  assert_(#ids == 2 and ids[1] == 2, "selectedIDs is the wire's list")
  l:SetEntrySelected(2, false)
  sel = last_set(f).selected
  assert_(#sel == 1 and sel[1] == 3, "deselect 2")
  f.set_entry_flags(l.handle, 1, { hidden = true, disabled = true })
  assert_(l:GetEntryVisible(1) == false and l:GetEntryEnabled(1) == false, "hidden / disabled")
  assert_(l:GetEntryVisible(2) == true and l:GetEntryEnabled(2) == true, "the others")
  assert_(l:GetEntryVisible(99) == false, "a missing id: false")
  local e = l.entries[1]
  assert_(e.enabled == false and e.visible == false and e.selected == false and e.text == "Oak",
    "entries in Jagex's terms")
  l:UnselectAll()
  assert_(#last_set(f).selected == 0 and l.numSelectedEntries == 0, "UnselectAll is {}")
end

T["p2: a list selection over the limit is the agent's refusal"] = function(assert_)
  local _, _, ui, _, area = setup()
  local l = ui.List.new(area)
  l:SetEntries({ "a", "b", "c" })
  l.maxSelected = 2   -- a limit L > 1 holds L - 1
  l:SetEntrySelected(1, true)
  local err = raised(assert_, l.SetEntrySelected, l, 2, true)
  assert_(err.kind == "refused" and err.message == fake_bwu.UI_LIST_LIMIT, tostring(err))
end

T["p2: Panel.vertical; panel spacing and grid layout are the agent's refusals"] = function(assert_)
  local _, _, ui, f, area = setup()
  local p = ui.Panel.new(area)
  p.vertical = true
  assert_(last_set(f).vertical == true and p.vertical == true, "vertical")
  local err = raised(assert_, p.Set, p, { spacing = 4 })
  assert_(err.kind == "refused" and err.message == fake_bwu.UI_LATER_PROPS.spacing, tostring(err))
  local g = ui.Grid.new(p)
  err = raised(assert_, g.Set, g, { layout = 1 })
  assert_(err.kind == "refused" and err.message == fake_bwu.UI_LATER_PROPS.layout, tostring(err))
  err = raised(assert_, function() return ui.Button.new(area).vertical end)
  assert_(err.kind == "unsupported", "a prop of another type is not offered: " .. tostring(err))
end

T["p2: a prop that does not fit the type is the agent's refusal"] = function(assert_)
  local _, _, ui, _, area = setup()
  local c = ui.Check.new(area)
  local err = raised(assert_, c.Set, c, { value = 3 })
  assert_(err.kind == "refused" and err.message == "ui: value applies to slider components only",
    tostring(err))
end

T["p2: what Jagex offers and the wire does not raises not supported yet, without a call"] = function(assert_)
  local _, _, ui, f, area = setup()
  local b, c, i = ui.Button.new(area), ui.Check.new(area), ui.InputField.new(area)
  local s, co, l = ui.Slider.new(area), ui.ComboField.new(area), ui.List.new(area)
  local before = #f.calls
  for _, fn in ipairs({
    function() b:SetAssociatedObject(1, 1) end,
    function() b.mode = 1 end,
    function() return b.associatedObjectID end,
    function() c.alignment = 1 end,
    function() return i.visibility end,
    function() i.emptyText = "x" end,
    function() s:SetValue(1, true) end,
    function() s:Setup(0, 10, 5, 1, 1) end,
    function() s:Setup({ "a", "b" }, 1) end,
    function() return s.valueLabel end,
    function() co:Select(1, true) end,
    function() co.entryHeight = 10 end,
    function() l:SetEntrySelected(1, true, true) end,
    function() l:SetEntryEnabled(1, false) end,
    function() l:SetEntryVisible(1, false) end,
    function() l:SetEntryIcon(1, 2) end,
    function() return l.isDropdown end,
  }) do
    local err = raised(assert_, fn)
    assert_(err.kind == "unsupported" and err.message:find("not supported yet", 1, true), tostring(err))
  end
  assert_(#f.calls == before, "none of them reaches the agent")
end

-- Hooks ------------------------------------------------------------------------------------

T["p2: Subscribe sends one ui.subscribe per hook; the last Unsubscribe sends ui.unsubscribe"] = function(assert_)
  local _, _, ui, f, area = setup()
  local b = ui.Button.new(area)
  b:Subscribe(ui.Hook.ONCLICK, function() end)
  b:Subscribe(ui.Hook.ONCLICK, "two", function() end)
  b:Subscribe(ui.Hook.ONCLICK, "two", function() end)   -- replaces
  local subs = f.calls_of("ui_subscribe")
  assert_(#subs == 1 and subs[1].args[2] == b.handle and subs[1].args[3] == "onclick",
    "one ui.subscribe, lower-cased")
  assert_(#b._subs.onclick == 2, "two callbacks")
  b:Unsubscribe(ui.Hook.ONCLICK)
  assert_(#f.calls_of("ui_unsubscribe") == 0, "one callback left: nothing sent")
  b:Unsubscribe(ui.Hook.ONCLICK, "two")
  local unsubs = f.calls_of("ui_unsubscribe")
  assert_(#unsubs == 1 and unsubs[1].args[3] == "onclick", "the last one unsubscribes")
  assert_(not f.subscribed(b.handle, "onclick"), "the agent no longer pushes it")
  b:Subscribe(ui.Hook.ONBUTTONPRESSED, function() end)
  b:Subscribe(ui.Hook.ONBUTTONPRESSED, "x", function() end)
  b:UnsubscribeAll(ui.Hook.ONBUTTONPRESSED)
  assert_(#f.calls_of("ui_unsubscribe") == 2, "UnsubscribeAll: one call")
  b:Unsubscribe(ui.Hook.ONBUTTONPRESSED)
  assert_(#f.calls_of("ui_unsubscribe") == 2, "nothing left: nothing sent")
end

T["p2: a refused Subscribe raises verbatim and keeps nothing"] = function(assert_)
  local _, _, ui, f, area = setup()
  local layer = ui.Layer.new(area)
  local err = raised(assert_, layer.Subscribe, layer, ui.Hook.ONCONTENTCHANGED, function() end)
  assert_(err.kind == "refused" and err.verb == "ui.subscribe"
    and err.message == "ui: hook not valid for this type", tostring(err))
  assert_(layer._subs.oncontentchanged == nil, "no callback kept")
  layer:Unsubscribe(ui.Hook.ONCONTENTCHANGED)
  assert_(#f.calls_of("ui_unsubscribe") == 0, "and nothing to unsubscribe")
  err = raised(assert_, area.Subscribe, area, ui.Hook.ONCLICK, function() end)
  assert_(err.kind == "refused" and err.message == fake_bwu.UI_READ_ONLY, "a Jagex handle")
  f.timeout = true
  err = raised(assert_, layer.Subscribe, layer, ui.Hook.ONCLICK, function() end)
  assert_(err.kind == "timeout", tostring(err))
end

T["p2: mouse hooks call fn(self, x, y, event) with a MouseEvent"] = function(assert_)
  local _, _, ui, f, area = setup()
  local b = ui.Button.new(area)
  local got = {}
  for _, hook in ipairs({ "ONCLICK", "ONRELEASE", "ONMOUSEOVER", "ONMOUSELEAVE" }) do
    b:Subscribe(ui.Hook[hook], function(self, x, y, ev)
      got[#got + 1] = { self = self, x = x, y = y, ev = ev }
    end)
  end
  for n, hook in ipairs({ "onclick", "onrelease", "onmouseover", "onmouseleave" }) do
    assert_(f.fire(b.handle, hook, n, n * 10), hook .. " subscribed")
  end
  ui:poll()
  assert_(#got == 4, "four callbacks: " .. #got)
  for n, g in ipairs(got) do
    assert_(g.self == b and g.x == n and g.y == n * 10, "args")
    assert_(g.ev.args.type == "MouseEvent" and g.ev.args.x == n and g.ev.args.y == n * 10
      and g.ev.component == b and g.ev.kind == "ui", "typed record")
  end
  assert_(got[1].ev.hook == "onclick" and got[4].ev.hook == "onmouseleave", "the hooks")
end

T["p2: onbuttonpressed calls fn(self, current, previous) on a button and a check"] = function(assert_)
  local _, _, ui, f, area = setup()
  local b, c = ui.Button.new(area), ui.Check.new(area)
  local got = {}
  local function on(self, current, previous, ev) got[#got + 1] = { self, current, previous, ev } end
  b:Subscribe(ui.Hook.ONBUTTONPRESSED, on)
  c:Subscribe(ui.Hook.ONBUTTONPRESSED, on)
  f.fire(b.handle, "onbuttonpressed", 1, 0)
  f.fire(c.handle, "onbuttonpressed", 0, 1)
  ui:poll()
  assert_(got[1][1] == b and got[1][2] == 1 and got[1][3] == 0, "button")
  assert_(got[2][1] == c and got[2][2] == 0 and got[2][3] == 1, "check")
  local a = got[1][4].args
  assert_(a.type == "ButtonPressed" and a.current == 1 and a.previous == 0, "typed record")
end

T["p2: oncontentchanged calls fn(self, reason, content); restricted content is nil"] = function(assert_)
  local _, _, ui, f, area = setup()
  local i = ui.InputField.new(area)
  local got = {}
  i:Subscribe(ui.Hook.ONCONTENTCHANGED, function(self, reason, content, ev)
    got[#got + 1] = { self = self, reason = reason, content = content, ev = ev }
  end)
  f.fire(i.handle, "oncontentchanged", ui.InputFieldActionResult.SUBMIT, "typed")
  f.fire(i.handle, "oncontentchanged", ui.InputFieldActionResult.CONTENT_CHANGE, nil)
  ui:poll()
  assert_(got[1].self == i and got[1].reason == ui.InputFieldActionResult.SUBMIT
    and got[1].content == "typed", "submit")
  local a = got[1].ev.args
  assert_(a.type == "ContentChanged" and a.reason == 2 and a.reasonName == "submit"
    and a.content == "typed", "typed record")
  assert_(got[2].content == nil and got[2].ev.content == nil and got[2].ev.args.content == nil,
    "the host's false for a NIL content is nil again")
end

T["p2: the script's own content set raises oncontentchanged, as the client does"] = function(assert_)
  local _, _, ui, _, area = setup()
  local i = ui.InputField.new(area)
  local got
  i:Subscribe(ui.Hook.ONCONTENTCHANGED, function(_, reason, content) got = { reason, content } end)
  i.content = "mine"
  ui:poll()
  assert_(got and got[1] == ui.InputFieldActionResult.CONTENT_CHANGE and got[2] == "mine",
    "reason 0 with the content")
end

T["p2: onselectionchanged: a slider gives (value, 1), a combo or list (entryID, event)"] = function(assert_)
  local _, _, ui, f, area = setup()
  local s, c, l = ui.Slider.new(area), ui.ComboField.new(area), ui.List.new(area)
  local got = {}
  local function on(self, a, b, ev) got[#got + 1] = { self, a, b, ev } end
  for _, comp in ipairs({ s, c, l }) do comp:Subscribe(ui.Hook.ONSELECTIONCHANGED, on) end
  f.fire(s.handle, "onselectionchanged", 40)
  f.fire(c.handle, "onselectionchanged", 7, ui.SelectionChangeEvent.SELECTED)
  f.fire(l.handle, "onselectionchanged", 3, ui.SelectionChangeEvent.ERROR_MAX_SELECTED)
  ui:poll()
  assert_(got[1][1] == s and got[1][2] == 40 and got[1][3] == 1, "slider: value, 1")
  assert_(got[1][4].args.type == "SliderChanged" and got[1][4].args.value == 40, "SliderChanged")
  assert_(got[2][1] == c and got[2][2] == 7 and got[2][3] == ui.SelectionChangeEvent.SELECTED, "combo")
  local a = got[3][4].args
  assert_(got[3][2] == 3 and a.type == "SelectionChanged" and a.entryID == 3
    and a.selectionEvent == 2 and a.eventName == "error_max_selected", "list SelectionChanged")
end

T["p2: an arg shape the host did not decode is passed on raw"] = function(assert_)
  local _, _, ui, f, area = setup()
  local b = ui.Button.new(area)
  local got
  b:Subscribe(ui.Hook.ONCLICK, function(_, a, c, ev) got = { a, c, ev } end)
  f.fire(b.handle, "onclick", nil, nil, { "odd", 5 })
  ui:poll()
  assert_(got[1] == "odd" and got[2] == 5 and got[3].args.type == "Raw" and got[3].args[2] == 5,
    "raw args, then the event")
end

T["p2: on_event listeners get the typed event; false from a callback stops later ones"] = function(assert_)
  local _, _, ui, f, area = setup()
  local b = ui.Button.new(area)
  local seen, calls = nil, 0
  ui:on_event(function(ev) seen = ev end)
  b:Subscribe(ui.Hook.ONCLICK, "a", function() calls = calls + 1; return false end)
  b:Subscribe(ui.Hook.ONCLICK, "b", function() calls = calls + 1 end)
  f.fire(b.handle, "onclick", 3, 4)
  ui:poll()
  assert_(calls == 1, "false stopped the second")
  assert_(seen and seen.hook == "onclick" and seen.args.type == "MouseEvent" and seen.args.x == 3,
    "the listener's event is typed")
end

T["p2: a clients manager hands out P2 events typed, with the callbacks run"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local f = b._ui
  local cm = bot.clients.new()
  local game = assert(cm:attach_pid(4242))
  local ui = game:ui()
  local s = ui.Slider.new(ui.Interfaces:GetComponent(IFACE, COMP))
  local value
  s:Subscribe(ui.Hook.ONSELECTIONCHANGED, function(_, v) value = v end)
  f.fire(s.handle, "onselectionchanged", 12)
  local ev = cm:poll(0)
  assert_(ev and ev.kind == "ui" and ev.hook == "onselectionchanged" and ev.args.value == 12,
    "typed through the manager")
  assert_(value == 12, "the callback ran")
end

-- Cleanup ----------------------------------------------------------------------------------

T["p2: a component the game took down drops its subscriptions; Unsubscribe then sends nothing"] = function(assert_)
  local _, _, ui, f, area = setup()
  local b = ui.Button.new(area)
  local reason
  b:Subscribe(ui.Hook.ONCLICK, function() end)
  b:Subscribe(ui.Hook.DESTROYED, function(_, r) reason = r end)
  f.game_destroy(b.handle, "parent_gone")
  ui:poll()
  assert_(reason == "parent_gone", "DESTROYED unchanged: fn(comp, reason)")
  b:Unsubscribe(ui.Hook.ONCLICK)
  assert_(#f.calls_of("ui_unsubscribe") == 0 and #f.calls_of("ui_unsubscribe_unsent") == 0,
    "nothing sent, nothing even asked of the host")
end

T["p2: Destroy drops the subscriptions; Unsubscribe afterwards is success"] = function(assert_)
  local _, _, ui, f, area = setup()
  local c = ui.Check.new(area)
  c:Subscribe(ui.Hook.ONBUTTONPRESSED, function() end)
  c:Destroy()
  c:Unsubscribe(ui.Hook.ONBUTTONPRESSED)
  c:UnsubscribeAll(ui.Hook.ONBUTTONPRESSED)
  assert_(#f.calls_of("ui_unsubscribe") == 0, "no ui.unsubscribe for a destroyed handle")
end

T["p2: an Unsubscribe the host no longer tracks answers false and is success"] = function(assert_)
  local _, _, ui, f, area = setup()
  local b = ui.Button.new(area)
  b:Subscribe(ui.Hook.ONCLICK, function() end)
  f.comps[b.handle] = nil   -- gone at the agent and host, its event not read yet
  b:Unsubscribe(ui.Hook.ONCLICK)   -- does not raise
  assert_(#f.calls_of("ui_unsubscribe_unsent") == 1, "the host answered false without sending")
end

T["p2: an overflow reconcile drops a missing handle's subscriptions without a call"] = function(assert_)
  local _, game, ui, f, area = setup()
  local b = ui.Button.new(area)
  b:Subscribe(ui.Hook.ONCLICK, function() end)
  f.comps[b.handle] = nil
  f.overflow(game._host, 2)
  ui:poll()
  assert_(b:IsDestroyed(), "reconciled away")
  b:Unsubscribe(ui.Hook.ONCLICK)
  assert_(#f.calls_of("ui_unsubscribe") == 0 and #f.calls_of("ui_unsubscribe_unsent") == 0,
    "nothing sent")
end

T["p2: the end of a run releases with one ui.destroy_all and never unsubscribes"] = function(assert_)
  local b = fake_bwu.new()
  _G.bwu = b
  local f = b._ui
  local made = {}
  bot.run({
    manifest = { name = "p2", version = "1", author = "t" },
    on_start = function(ctx)
      local ui = ctx.ui
      local panel = ui.Panel.new(ui.Interfaces:GetComponent(IFACE, COMP))
      local s, l, i = ui.Slider.new(panel), ui.List.new(panel), ui.InputField.new(panel)
      s:Subscribe(ui.Hook.ONSELECTIONCHANGED, function() end)
      l:Subscribe(ui.Hook.ONSELECTIONCHANGED, function() end)
      i:Subscribe(ui.Hook.ONCONTENTCHANGED, function() end)
      made = { panel, s, l, i }
    end,
    on_loop = function() return -1 end,
  }, { max_iters = 1 })
  assert_(#f.calls_of("ui_subscribe") == 3, "three subscribes")
  assert_(#f.calls_of("ui_destroy_all") == 1, "one ui.destroy_all")
  assert_(#f.calls_of("ui_unsubscribe") == 0 and #f.calls_of("ui_unsubscribe_unsent") == 0,
    "no ui.unsubscribe: the components took their subscriptions with them")
  for _, c in ipairs(made) do
    assert_(c:IsDestroyed() and next(c._wire) == nil, "forgotten with no subscription left")
  end
end

T["p2: an Unsubscribe that times out raises kind timeout"] = function(assert_)
  local _, _, ui, f, area = setup()
  local b = ui.Button.new(area)
  b:Subscribe(ui.Hook.ONCLICK, function() end)
  f.timeout = true
  local err = raised(assert_, b.Unsubscribe, b, ui.Hook.ONCLICK)
  assert_(err.kind == "timeout" and err.verb == "ui.unsubscribe", tostring(err))
end

-- Review fixes (F1-F5) ------------------------------------------------------------------------

T["p2 F1: a default list is single-select: selecting another replaces, UnselectAll is a no-op"] = function(assert_)
  local _, _, ui, f, area = setup()
  local l = ui.List.new(area)   -- no selection_limit: the client's default, 1
  l:SetEntries({ "Oak", "Willow", "Yew" })
  assert_(l:SetEntrySelected(1, true) == true, "select 1")
  assert_(l:SetEntrySelected(2, true) == true, "select 2 on a single-select list does not raise")
  local sel = last_set(f).selected
  assert_(#sel == 1 and sel[1] == 2, "2 replaced 1")
  assert_(l:GetEntrySelected(2) and not l:GetEntrySelected(1), "readback")
  local sets = #f.calls_of("ui_set")
  l:UnselectAll()
  assert_(#f.calls_of("ui_set") == sets and l:GetEntrySelected(2), "UnselectAll: no-op at limit 1")
  l:SetEntrySelected(2, false)
  assert_(#last_set(f).selected == 0, "deselecting still works")
end

T["p2 F1: a list selection over the limit is the agent's own text"] = function(assert_)
  local _, _, ui, f, area = setup()
  local l = ui.List.new(area)
  l:SetEntries({ "a", "b", "c" })
  local err = raised(assert_, l.Set, l, { selected = { 1, 2 } })
  assert_(err.message == fake_bwu.UI_LIST_LIMIT
    and err.message:find("limit 1: one; limit L > 1: L - 1", 1, true), tostring(err))
  assert_(f ~= nil)
end

-- A run whose button is subscribed, and a click the client raises during on_stop.
local function click_in_on_stop(crash)
  local b = fake_bwu.new()
  _G.bwu = b
  local f = b._ui
  local clicks, reasons, button = 0, {}, nil
  pcall(bot.run, {
    manifest = { name = "p2 stop", version = "1", author = "t" },
    on_start = function(ctx)
      local ui = ctx.ui
      button = ui.Button.new(ui.Interfaces:GetComponent(IFACE, COMP))
      button:Subscribe(ui.Hook.ONCLICK, function() clicks = clicks + 1 end)
      button:Subscribe(ui.Hook.DESTROYED, function(_, r) reasons[#reasons + 1] = r end)
    end,
    on_loop = function()
      if crash then error("boom") end
      return -1
    end,
    on_stop = function() f.fire(button.handle, "onclick", 1, 2) end,
  }, { max_iters = 1 })
  return clicks, reasons, f
end

T["p2 F2: a click raised during on_stop never runs its callback; DESTROYED still does"] = function(assert_)
  local clicks, reasons, f = click_in_on_stop(false)
  assert_(clicks == 0, "the click callback ran after on_stop: " .. clicks)
  assert_(#reasons == 1 and reasons[1] == "released", "DESTROYED ran with released")
  assert_(#f.calls_of("ui_destroy_all") == 1, "released once")
end

T["p2 F2: after a crash too, the release runs no wire-hook callback"] = function(assert_)
  local clicks, reasons = click_in_on_stop(true)
  assert_(clicks == 0, "the click callback ran after a crash: " .. clicks)
  assert_(reasons[1] == "released", "DESTROYED ran")
end

T["p2 F2: a Game's ui is usable after a release (the flag is cleared)"] = function(assert_)
  local _, _, ui, f, area = setup()
  ui.Button.new(area)
  ui:release()   -- releases the Jagex parent it looked up too: look it up again
  local b = ui.Button.new(ui.Interfaces:GetComponent(IFACE, COMP))
  local n = 0
  b:Subscribe(ui.Hook.ONCLICK, function() n = n + 1 end)
  f.fire(b.handle, "onclick", 1, 1)
  ui:poll()
  assert_(n == 1, "callbacks run again")
end

T["p2 F3: Subscribe without an id replaces the default listener; Unsubscribe(hook) removes it"] = function(assert_)
  local _, _, ui, f, area = setup()
  local b = ui.Button.new(area)
  local got = {}
  b:Subscribe(ui.Hook.ONCLICK, function() got[#got + 1] = "first" end)
  b:Subscribe(ui.Hook.ONCLICK, function() got[#got + 1] = "second" end)
  b:Subscribe(ui.Hook.ONCLICK, "named", function() got[#got + 1] = "named" end)
  f.fire(b.handle, "onclick", 1, 1)
  ui:poll()
  assert_(#got == 2 and got[1] == "second" and got[2] == "named", table.concat(got, ","))
  b:Unsubscribe(ui.Hook.ONCLICK)
  assert_(#f.calls_of("ui_unsubscribe") == 0, "the named one is left")
  b:Unsubscribe(ui.Hook.ONCLICK, "named")
  assert_(#f.calls_of("ui_unsubscribe") == 1, "now none: unsubscribed")
end

T["p2 F4: a callback that polls (or sleeps) does not reorder events"] = function(assert_)
  local _, _, ui, f, area = setup()
  local b = ui.Button.new(area)
  local order, nested = {}, nil
  b:Subscribe(ui.Hook.ONCLICK, function(_, x)
    order[#order + 1] = x
    if x == 1 then nested = ui:poll() end   -- as sleep_ticks would pump
  end)
  for x = 1, 3 do f.fire(b.handle, "onclick", x, 0) end
  local outer = ui:poll()
  assert_(nested and #nested == 0, "the nested poll gets nothing")
  assert_(#order == 3 and order[1] == 1 and order[2] == 2 and order[3] == 3,
    "in order: " .. table.concat(order, ","))
  assert_(#outer == 3, "the outer poll handed out all three")
  f.fire(b.handle, "onclick", 4, 0)
  assert_(#ui:poll() == 1, "the guard is cleared afterwards")
end

T["p2 F4: a poll that raises clears the guard"] = function(assert_)
  local _, _, ui, f, area = setup()
  ui.Button.new(area)
  f.poll_error = "pipe lost"
  assert_(not pcall(ui.poll, ui), "raises")
  f.poll_error = nil
  local b = ui.Button.new(area)
  b:Subscribe(ui.Hook.ONCLICK, function() end)
  f.fire(b.handle, "onclick", 1, 1)
  assert_(#ui:poll() == 1, "polls again")
end

T["p2 F5: InputFieldActionResult.NONE never equals a delivered reason"] = function(assert_)
  local _, _, ui = setup()
  local r = ui.InputFieldActionResult
  assert_(r.NONE ~= nil, "NONE exists")
  for _, v in ipairs({ r.CONTENT_CHANGE, r.ERROR, r.SUBMIT, r.SUBMIT_ON_ESCAPE, r.SUBMIT_ON_FOCUS_LOSS }) do
    assert_(v ~= r.NONE, "distinct")
  end
end

T["p2 F5: a restricted input field's content reads as an empty string"] = function(assert_)
  local _, _, ui, f, area = setup()
  local i = ui.InputField.new(area)
  i.content = "secret"
  f.restrict(i.handle)
  assert_(i.content == "", "restricted: empty, as Jagex's")
  local err = raised(assert_, function() i.content = "x" end)
  assert_(err.kind == "refused" and err.message == fake_bwu.UI_RESTRICTED_SET, "a set still raises")
  f.timeout = true
  err = raised(assert_, function() return i.content end)
  assert_(err.kind == "timeout", "other failures still raise")
end

T["p2 F5: a combo entry's selectable is not supported yet"] = function(assert_)
  local _, _, ui, _, area = setup()
  local c = ui.ComboField.new(area)
  c:SetEntries({ "a" })
  local e = c.entries[1]
  assert_(e.id == 1 and e.text == "a", "id and text")
  local err = raised(assert_, function() return e.selectable end)
  assert_(err.kind == "unsupported" and err.message:find("not supported yet", 1, true), tostring(err))
end

T["p2: ComboField:Remove of the selected entry sends selected = -1; a list's sends {}"] = function(assert_)
  local _, _, ui, f, area = setup()
  local c = ui.ComboField.new(area)
  c:SetEntries({ "a", "b" }, 1)
  c:Remove(1)
  assert_(last_set(f).selected == -1, "combo: -1")
  local l = ui.List.create(area, { selection_limit = 3 })
  l:SetEntries({ "a", "b" })
  l:SetEntrySelected(2, true)
  l:Remove(2)
  local p = last_set(f)
  assert_(type(p.selected) == "table" and #p.selected == 0 and #p.entries == 1, "list: {}")
end

-- A P1 host -------------------------------------------------------------------------------

T["p2: on a host without bwu.ui_subscribe the P2 hooks and helpers say so"] = function(assert_)
  local _, _, ui, f, area = setup({ ui_p1 = true })
  local layer = ui.Layer.new(area)
  local before = #f.calls
  for _, fn in ipairs({
    function() layer:Subscribe(ui.Hook.ONCLICK, function() end) end,
    function() GameUi._CLASSES.InputField._methods.Blur(layer) end,
    function() GameUi._CLASSES.List._methods.SetEntries(layer, { "a" }) end,
  }) do
    local err = raised(assert_, fn)
    assert_(err.kind == "unsupported" and err.message:find("no P2 plugin-UI surface", 1, true),
      tostring(err))
  end
  assert_(#f.calls == before, "nothing sent")
  local err = raised(assert_, ui.Button.new, area)
  assert_(err.kind == "refused" and err.message == "ui type not supported yet: button",
    "a P1 agent's own refusal")
  layer:Subscribe(ui.Hook.DESTROYED, function() end)   -- P1 still works
end

return T
