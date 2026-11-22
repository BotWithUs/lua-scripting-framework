-- Live plugin-UI P2 smoke for botwithus.game_ui: bwu_host --lua tests/live/ui_smoke_p2.lua
--
-- Written against this framework's API only (bot.run, ctx.ui, ui.Panel.new, comp:Subscribe,
-- ...), never the raw bwu.ui_* bindings. Needs a client in the world with an agent
-- that has plugin-UI P2, and a bwu_host with bwu.ui_subscribe (1.1.0 or later). It follows the
-- native host's p2 live smoke contract, so that host's p2 smoke driver can run it. Environment:
--   BWU_SMOKE_PID   the client pid (default: the first discovered client)
--   BWU_SMOKE_OUT   a file this script writes its results to, one "key=value" per line
--
-- Under TOPLEVEL_V2__GAME_AREA (1477:61) it makes a panel holding a button, a check, a slider,
-- a list (selection limit 3), an input field and a default (single-select) list, sets values and reads them back, then subscribes ONSELECTIONCHANGED
-- on the slider and the list and ONCONTENTCHANGED on the input field, and sets values again
-- through the script API. The client raises hook 50 for a content set, so a typed
-- ONCONTENTCHANGED callback must run with (reason CONTENT_CHANGE, content). A slider value or a
-- list selection set raises nothing, so the script counts any
-- ONSELECTIONCHANGED and the driver checks there were none. No click: the only click path is a
-- debug-only agent verb, which scripts never use.
-- It writes the panel's key and "ready=1", runs until BWU_SMOKE_OUT .. ".go" exists, and ends
-- WITHOUT destroying or unsubscribing anything: bot.run's end must release the seven components
-- (one ui.destroy_all) and with them their subscriptions (no ui.unsubscribe).
-- Raises (bwu_host exits non-zero) on any mismatch.

-- `botwithus` comes from package.path: set LUA_PATH to this repo
-- ("<repo>/?.lua;<repo>/?/init.lua;;") and run from a directory with no other copy in it.
local bot = require("botwithus")
assert(bot.GameUi and bot.GameUi.WIRE_HOOKS,
  "the botwithus on package.path has no P2 game_ui: set LUA_PATH to this repo")

local IFACE, COMP = 1477, 61   -- TOPLEVEL_V2__GAME_AREA
local EVENT_WAIT_TICKS = 8     -- ~5 s of server ticks for the content event
local GO_TIMEOUT_S = 120

local out_path = assert(os.getenv("BWU_SMOKE_OUT"), "BWU_SMOKE_OUT not set")
local pid = math.tointeger(tonumber(os.getenv("BWU_SMOKE_PID") or ""))
local lines = {}

local function note(key, value)
  lines[#lines + 1] = key .. "=" .. tostring(value)
  local f = assert(io.open(out_path, "w"))
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
  print("SMOKE " .. key .. "=" .. tostring(value))
end

local function check(label, got, want)
  if got ~= want then error(string.format("%s: got %s, want %s", label, tostring(got), tostring(want)), 2) end
end

local function go_signal()
  local f = io.open(out_path .. ".go", "r")
  if f then f:close() return true end
  return false
end

local function build(ui)
  local area = assert(ui.Interfaces:GetComponent(IFACE, COMP))
  local panel = ui.Panel.new(area)
  panel:SetPos(40, 40)
  panel:SetSize(220, 260)
  panel.vertical = true
  local button = ui.Button.new(panel)
  button:SetSize(200, 30)
  button.label = "bwu P2"
  button.canToggle = true
  local check_box = ui.Check.new(panel)
  check_box:SetSize(30, 30)
  local slider = ui.Slider.new(panel)
  slider:SetSize(200, 30)
  slider:SetRange(0, 100, 10, 10, 20)
  local list = ui.List.create(panel, { width = 200, height = 80, selection_limit = 3 })
  list:SetEntries({ "Oak", "Willow", "Yew" })
  local input = ui.InputField.new(panel)
  input:SetSize(200, 30)
  input:Setup(ui.TextContentVisibilityMode.VISIBLE, ui.InputFieldFilterMode.NONE, 20)
  local single = ui.List.new(panel)   -- no selection_limit: the client's default
  single:SetSize(200, 60)
  single:SetEntries({ "Logs", "Oak logs" })
  return { panel = panel, button = button, check = check_box, slider = slider, list = list,
           input = input, single = single }
end

local function set_and_read(ui, c)
  c.button.isToggled = true
  c.check.value = true
  check("slider SetValue", c.slider:SetValue(30), true)
  check("list SetEntrySelected", c.list:SetEntrySelected(2, true), true)
  c.input.content = "first"

  check("panel vertical", c.panel.vertical, true)
  check("button label", c.button.label, "bwu P2")
  check("button isToggled", c.button.isToggled, true)
  check("button enabled", c.button.enabled, true)
  check("check value", c.check.value, true)
  check("slider value", c.slider.value, 30)
  check("slider maxValue", c.slider.maxValue, 100)
  check("list numEntries", c.list.numEntries, 3)
  check("list numSelectedEntries", c.list.numSelectedEntries, 1)
  check("list entry 2 selected", c.list:GetEntrySelected(2), true)
  check("list selectedEntries", c.list.selectedEntries[1].text, "Willow")
  check("input content", c.input.content, "first")
  check("input isFocused", c.input.isFocused, false)
  check("input maxLength", c.input.maxLength, 20)
  check("input filterMode", c.input.filterMode, ui.InputFieldFilterMode.NONE)
  -- A default list is single-select: selecting another replaces; UnselectAll is a no-op.
  check("single maxSelected", c.single.maxSelected, 1)
  check("single select 1", c.single:SetEntrySelected(1, true), true)
  check("single select 2", c.single:SetEntrySelected(2, true), true)
  check("single selected count", c.single.numSelectedEntries, 1)
  check("single entry 2 selected", c.single:GetEntrySelected(2), true)
  c.single:UnselectAll()
  check("single UnselectAll no-op", c.single:GetEntrySelected(2), true)
  note("single_selected", table.concat(c.single.selectedIDs, ","))
  note("input_renders", c.input.renders)   -- reported as is: false is expected on 951-4
  note("input_font_id", c.input.fontID)
  note("input_sprite_id", c.input.spriteID)
end

-- Subscribe, then set through the script API again.
local function subscribe_and_set(ui, c, seen)
  local function on_selection(_, a, b, ev)
    seen.selection = seen.selection + 1
    note("selection_event_" .. seen.selection, ev.hook .. ":" .. tostring(a) .. "," .. tostring(b))
  end
  c.slider:Subscribe(ui.Hook.ONSELECTIONCHANGED, on_selection)
  c.list:Subscribe(ui.Hook.ONSELECTIONCHANGED, on_selection)
  c.input:Subscribe(ui.Hook.ONCONTENTCHANGED, function(comp, reason, content, ev)
    check("content event component", comp, c.input)
    seen.content = { reason = reason, content = content, args = ev.args }
  end)
  c.slider.value = 40
  c.list:SetEntrySelected(2, false)
  c.list:SetEntrySelected(1, true)
  c.input.content = "bwu p2 smoke"
  check("slider value 2", c.slider.value, 40)
  check("list selected 1", c.list:GetEntrySelected(1), true)
  check("list selected 2", c.list:GetEntrySelected(2), false)
end

bot.run({
  manifest = { name = "game_ui p2 smoke", version = "1", author = "botwithus" },
  on_start = function(ctx)
    local ui = ctx.ui
    local c = build(ui)
    set_and_read(ui, c)
    ctx.seen = { selection = 0 }
    subscribe_and_set(ui, c, ctx.seen)
    ctx.c, ctx.waited = c, 0
  end,
  on_loop = function(ctx)
    local seen, c = ctx.seen, ctx.c
    if not seen.content and ctx.waited < EVENT_WAIT_TICKS then
      ctx.waited = ctx.waited + 1
      return 1
    end
    if not ctx.reported then
      ctx.reported = true
      assert(seen.content, "no ONCONTENTCHANGED within " .. EVENT_WAIT_TICKS .. " ticks")
      check("content reason", seen.content.reason, ctx.ui.InputFieldActionResult.CONTENT_CHANGE)
      check("content args type", seen.content.args.type, "ContentChanged")
      note("content_reason", seen.content.args.reasonName)
      note("content_reason_code", seen.content.reason)
      note("content_text", seen.content.content)
      note("selection_events", seen.selection)
      note("blurred", c.input:Blur())
      note("panel_key", c.panel.key)
      note("components", #ctx.ui:components())
      note("ready", 1)
      ctx.go_deadline = os.time() + GO_TIMEOUT_S
    end
    if go_signal() then return -1 end
    if os.time() > ctx.go_deadline then error("no go signal within " .. GO_TIMEOUT_S .. " s") end
    return 1
  end,
}, { pid = pid })
-- bot.run has ended: the framework released the six components with one ui.destroy_all, then
-- detached. Nothing was unsubscribed by hand.
note("done", 1)
