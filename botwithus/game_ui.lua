-- botwithus.game_ui -- native game UI components, shaped like Jagex's own `ui.*` plugin API.
--
--   local ui = game:ui()                      -- or ctx.ui inside bot.run
--   local area = ui.Interfaces:GetComponent(1477, 61)   -- TOPLEVEL_V2__GAME_AREA
--   local c = ui.Canvas.new(area)
--   c:SetPos(40, 40)
--   c:SetSize(300, 300)
--   c:AddOutline(0, 0, 200, 200, 5, 0xFF0000FF)
--   c:AddLine(20, 10, 200, 200, 2, 0x339000FF)
--   local label = ui.Text.new(area)
--   label:SetSize(100, 20)
--   label.content = "Hello World"
--   label:Subscribe(ui.Hook.DESTROYED, function(comp, reason) print("gone:", reason) end)
--
-- The components are the client's own (Jagex's `ui.*` module): the game draws them, with its
-- own z-order and scaling. The agent creates and edits them for us; nothing here runs Lua in
-- the game. Snippets written for Jagex's plugin API port almost verbatim: the names, argument
-- orders and the 0xRRGGBBAA colours are the same. Differences are listed in docs/UI.md.
--
-- What is supported now: Canvas, Rectangle, Line, Text and Layer; position, size, rgba,
-- clickthrough, enabled, the line, rectangle and text properties; the canvas shapes;
-- MoveToFront / MoveToBack; Destroy; and the DESTROYED hook. P2 (an agent with plugin-UI
-- P2 and a host with bwu.ui_subscribe): the interactive types Button, Check, InputField,
-- Slider, ComboField, List, Panel and Grid with the properties and methods the wire carries,
-- and the hooks ONCLICK, ONRELEASE, ONMOUSEOVER, ONMOUSELEAVE, ONBUTTONPRESSED,
-- ONCONTENTCHANGED and ONSELECTIONCHANGED, whose callbacks get Jagex's arguments (see
-- Component:Subscribe). Props the agent refuses (hidden, check label, panel spacing, ...) are
-- sent all the same, so its own "not supported yet" refusal is what the script sees. What has
-- no wire form at all (canvas text and sprites, every other hook, triggerEvents = true, ...)
-- raises "not supported yet" here without a call.
--
-- Errors. Every call RAISES on failure, as Jagex's API does not return error codes. The error
-- is a table with `verb` ("ui.create" ...), `kind` and `message`, and it prints as text:
--   kind "refused"      the agent (or the host on its behalf) refused; `message` is its text,
--                       verbatim, e.g. "ui: prop forbidden on agent components (...)"
--   kind "timeout"      no answer in time ("rpc_timeout"); the outcome is unknown
--   kind "unsupported"  this framework has no wire form for it yet
-- Catch one with pcall and read err.kind / err.message. ui.Interfaces:GetComponent is the one
-- exception: like Jagex's, it returns nil when the component is not there (with the message
-- and kind as second and third values: kind "refused" means not there, "timeout" means no
-- answer). Passing its nil on as a parent raises kind "refused", "parent is nil (...)". A lost
-- pipe or a malformed reply raises the host's own error, as every other host call does.
-- Jagex's interaction configurations (opConfig, dragConfig, ...) raise the agent's refusal,
-- kind "refused", without a call: agent components never take them.
--
-- Lifetime. Components belong to the Game's own connection to the agent; no other Game and no
-- other script shares it. When a bot.run ends (or a GUI worker's run), the framework releases
-- them with ONE ui.destroy_all on that connection, before it detaches, and every held component
-- is forgotten as "released" (its DESTROYED callbacks run). One call, so a stalled agent costs
-- one timeout, not one per component. A host from 1.1.0 on sends no second ui.destroy_all at
-- detach once that release emptied its records (an older one sends one that finds nothing); the
-- agent releases what is left at pipe close. comp:Destroy() is the only per-handle destroy.
-- A component the game took down (its parent closed, logout) is announced by a "destroyed"
-- event and forgotten, so it is never destroyed twice; a Destroy that races that event is refused by the agent and
-- treated the same way. After an "overflow" (events lost), the held handles are checked
-- against ui.list and the missing ones forgotten with reason "unknown".
--
-- Events. bwu.ui_poll_events never waits. It is read by ui:poll(), by bot.run once per server
-- tick while the script sleeps, and by a botwithus.clients manager in :poll() / :pump() for
-- each Game it attached (as events of kind "ui"). Each event is
--   { kind = "ui", name = "ui", pid, handle, hook, reason, truncated, component }
-- plus the hook's own fields; hook "overflow" (handle 0, `dropped`) reports events the host
-- had to drop. A "destroyed" event, or one of a subscribed hook, runs the component's Subscribe
-- callbacks first. A subscribed hook's event also carries `args`, a typed record: MouseEvent
-- {x, y}, ButtonPressed {current, previous}, ContentChanged {reason, reasonName, content},
-- SliderChanged {value}, SelectionChanged {entryID, selectionEvent, eventName}, or Raw.
--
-- Subscriptions belong to the Game's connection, like the components. A component that is gone
-- (destroyed, released, taken down by the game, or missing after an overflow) takes its
-- subscriptions with it: no ui.unsubscribe is ever sent for it, and Unsubscribe on it succeeds.
-- An answered ui.unsubscribe also makes the host discard that hook's events it had not handed
-- over yet. Events already read (the rest of the current batch) run no Subscribe callback for a
-- hook with none left, but still reach the ui:on_event listeners and ui:poll()'s result.

local GameUi = {}

-- The client's ui.ComponentType values the agent reports (`type` on a component).
local COMPONENT_TYPE = { LINE = 0, RECTANGLE = 1, LABEL = 2, CANVAS = 8, BUTTON = 9, CHECK = 10,
                         LIST = 11, INPUT_FIELD = 12, SLIDER = 13, COMBO_FIELD = 14, LAYER = 20,
                         PANEL = 21, GRID = 22 }

-- Jagex's hook names, all of them, so ui.Hook.X is never nil. Only DESTROYED (ours: the agent's
-- ui.event) is delivered today; Subscribe raises "not supported yet" for the rest until the
-- agent pushes them.
local HOOK_DESTROYED = "destroyed"
local HOOK_OVERFLOW  = "overflow"
local JAGEX_HOOKS = {
  -- mouse and keyboard
  "ONCLICK", "ONCLICKREPEAT", "ONRELEASE", "ONHOLD", "ONMOUSEOVER", "ONMOUSEREPEAT",
  "ONMOUSELEAVE", "ONDRAG", "ONDRAGCOMPLETE", "ONSCROLLWHEEL", "ONKEY",
  -- touch
  "ONSWIPEVERTICAL", "ONSWIPEHORIZONTAL", "ONSWIPECOMPLETE", "ONPINCHHORIZONTAL",
  "ONPINCHVERTICAL", "ONPINCHCOMPLETE",
  -- state change
  "ONBUTTONPRESSED", "ONCONTENTCHANGED", "ONSELECTIONCHANGED", "ONCUTSCENEFINISHED",
  -- action
  "ONOP", "ONOPT", "ONTARGETENTER", "ONTARGETLEAVE",
  -- transmission
  "ONVARPTRANSMIT", "ONINVTRANSMIT", "ONSTATTRANSMIT", "ONVARCTRANSMIT", "ONVARCSTRTRANSMIT",
  "ONVARCLANTRANSMIT", "ONCHATTRANSMIT", "ONFRIENDTRANSMIT", "ONCLANTRANSMIT",
  "ONCLANSETTINGSTRANSMIT", "ONCLANCHANNELTRANSMIT", "ONRELATIONSHIPSETTRANSMIT",
  "ONMISCTRANSMIT", "ONSTOCKTRANSMIT", "ONPLAYERGROUPTRANSMIT", "ONPLAYERGROUPVARPTRANSMIT",
  "ONCAMERAUPDATETRANSMIT",
  -- misc
  "ONTIMER", "ONDIALOGABORT", "ONSUBCHANGE", "ONCAMFINISHED", "ONRESIZE",
  -- controller
  "ONGAMEPADBUTTON", "ONGAMEPADBUTTONHELD", "ONGAMEPADAXIS", "ONGAMEPADTRIGGER",
}
GameUi.JAGEX_HOOKS = JAGEX_HOOKS

-- The hooks the agent pushes once subscribed (P2), Jagex name -> wire name (lower-cased).
-- Every other Jagex hook raises "not supported yet" in Subscribe.
local WIRE_HOOKS = { ONCLICK = "onclick", ONRELEASE = "onrelease", ONMOUSEOVER = "onmouseover",
                     ONMOUSELEAVE = "onmouseleave", ONBUTTONPRESSED = "onbuttonpressed",
                     ONCONTENTCHANGED = "oncontentchanged",
                     ONSELECTIONCHANGED = "onselectionchanged" }
local IS_WIRE_HOOK = {}
for _, wire in pairs(WIRE_HOOKS) do IS_WIRE_HOOK[wire] = true end
local MOUSE_HOOKS = { onclick = true, onrelease = true, onmouseover = true, onmouseleave = true }
GameUi.WIRE_HOOKS = WIRE_HOOKS

-- The wire name for a hook a script passes (ui.Hook.X, or the wire name itself), or nil when
-- it is not one we deliver.
local function wire_hook(hook)
  if hook == "destroyed" then return hook end
  if IS_WIRE_HOOK[hook] then return hook end
  return WIRE_HOOKS[hook]
end

-- Jagex's enums for the hook arguments, numbered as the agent sends them.
-- NONE is Jagex's; the agent never sends it (its reasons are 0..4), so it is -1 here and never
-- equals a reason a callback receives.
local INPUT_ACTION_RESULT = { NONE = -1, CONTENT_CHANGE = 0, ERROR = 1, SUBMIT = 2, SUBMIT_ON_ESCAPE = 3,
                              SUBMIT_ON_FOCUS_LOSS = 4 }
local SELECTION_CHANGE_EVENT = { DESELECTED = 0, SELECTED = 1, ERROR_MAX_SELECTED = 2,
                                 ERROR_NOT_SELECTABLE = 3 }
-- ui.InputFieldFilterMode: the wire's filter names, so a readback compares equal to the enum.
local FILTER_MODE = { NONE = "none", ALPHANUMERIC = "alphanumeric", NUMERIC = "numeric",
                      QUANTITY = "quantity", NUMBERS_AS_TEXT = "numbers_as_text" }
-- ui.TextContentVisibilityMode. Only VISIBLE is usable: the agent refuses any other mode
-- (it would mark the field restricted).
local VISIBILITY_MODE = { VISIBLE = 0, SHOW_LAST = 1, HIDDEN = 2 }
-- A slider's onselectionchanged second argument: the client always sends 1.
local SLIDER_SELECTED = 1

-- The most events one bwu.ui_poll_events call hands over (the host binding's batch).
local POLL_BATCH = 32
GameUi.POLL_BATCH = POLL_BATCH

-- Reasons this module gives a component it forgets without a destroyed event from the agent.
local REASON_RELEASED = "released"   -- the end-of-run release
local REASON_REMOVED  = "removed"    -- a destroy the agent refused: it was already gone
local REASON_UNKNOWN  = "unknown"    -- missing from ui.list after events were dropped

-- Jagex's interaction configurations. The agent refuses them on every component it makes,
-- always, so they raise that refusal here (kind "refused") without a call.
local FORBIDDEN_TEXT = "ui: prop forbidden on agent components (no op, drag or target configuration)"
local FORBIDDEN = { opConfig = true, dragConfig = true, swipeConfig = true, pinchConfig = true,
                    cursorConfig = true, paramsConfig = true, targetConfig = true,
                    FlagRestricted = true, flagRestricted = true }
GameUi.FORBIDDEN_TEXT = FORBIDDEN_TEXT

-- Jagex combined component ids are (interface << 16) | component.
local COMBINED_SHIFT = 16
local COMBINED_MASK  = 0xFFFF


-- Errors -----------------------------------------------------------------------------------

local UiError = {}
UiError.__index = UiError
UiError.__tostring = function(e)
  return "botwithus.ui: " .. tostring(e.verb) .. " " .. tostring(e.kind) .. ": " .. tostring(e.message)
end
GameUi.Error = UiError

local function raise(verb, kind, message)
  error(setmetatable({ verb = verb, kind = kind, message = message }, UiError), 0)
end

local function unsupported(what)
  raise(what, "unsupported", what .. " is not supported yet")
end

-- Whether `err` is an error this module raised.
function GameUi.is_error(err) return getmetatable(err) == UiError end

local function surface()
  local b = rawget(_G, "bwu")
  if not b then error("botwithus: native `bwu` surface not present (run under bwu_host)", 3) end
  if not b.ui_create then error("botwithus: this host has no plugin-UI surface (bwu.ui_*)", 3) end
  return b
end

local function log(line) io.stderr:write("[botwithus.ui] ", line, "\n") end

-- Registry: one per Game -------------------------------------------------------------------

local Registry = {}
Registry.__index = Registry

-- The Game's live host handle, or raise as every Game call does on a detached Game.
function Registry:host()
  local h = self.game._host
  if not h then
    error("botwithus: game is detached (" .. tostring(self.game._detached_reason) .. ")", 0)
  end
  return h
end

-- One bwu.ui_* call. nil (a refusal or a timeout) raises a UiError; anything else is returned.
function Registry:call(fn, verb, ...)
  local b = surface()
  local host = self:host()
  self.used = true
  local result, err, kind = b[fn](host, ...)
  if result == nil then raise(verb, kind or "refused", err) end
  return result
end

-- The Lua object for a handle info table: one object per handle, so == works.
function Registry:wrap(info, class, is_ours)
  local comp = self.comps[info.handle]
  if comp then
    comp._info = info
    return comp
  end
  comp = setmetatable({ handle = info.handle, _reg = self, _info = info, _subs = {}, _wire = {} },
                      class)
  self.comps[info.handle] = comp
  if is_ours then self.created[#self.created + 1] = info.handle end
  return comp
end

-- Forget a handle (destroyed by us or by the game). Its object stays usable for reads of
-- its last info, and refuses edits through the agent ("unknown handle").
function Registry:forget(handle, reason)
  local comp = self.comps[handle]
  if comp then
    comp._dead = reason or true
    comp._wire = {}   -- the agent dropped its subscriptions with it: never unsubscribe them
  end
  self.comps[handle] = nil
  for i = #self.created, 1, -1 do
    if self.created[i] == handle then table.remove(self.created, i) end
  end
end

-- Run comp's callbacks for `hook` as fn(comp, <the hook's own arguments...>, ev).
local function run_subs(comp, hook, ev, ...)
  local subs = comp._subs[hook]
  if not subs then return end
  local args = table.pack(...)
  args.n = args.n + 1
  args[args.n] = ev
  local list = table.move(subs, 1, #subs, 1, {})   -- a callback may unsubscribe
  for _, s in ipairs(list) do
    local ok, keep_going = pcall(s.fn, comp, table.unpack(args, 1, args.n))
    if not ok then log("callback for " .. hook .. " failed: " .. tostring(keep_going))
    elseif keep_going == false then return end   -- Jagex: false stops later listeners
  end
end

-- A component is gone (the game took it down, a release, a refused destroy): forget it and
-- run its DESTROYED callbacks with `reason`. `ev` is the event that said so, or a made-up one.
function Registry:gone(comp, reason, ev)
  self:forget(comp.handle, reason)
  ev = ev or { kind = "ui", name = "ui", pid = self.game._pid, handle = comp.handle,
               hook = HOOK_DESTROYED, reason = reason, truncated = false, component = comp }
  run_subs(comp, HOOK_DESTROYED, ev, reason)
end

-- A subscribed hook's arguments, from the host's named fields: sets ev.args to a typed record
-- and returns Jagex's positional arguments for the callback. A NIL payload value arrives from
-- the host as false; content is the one that can be nil (a restricted field), so it is mapped
-- back. A shape the host did not decode (arg0, arg1, ...) is passed on as it came.
local function decode_hook(ev)
  local hook = ev.hook
  if MOUSE_HOOKS[hook] and ev.x ~= nil then
    ev.args = { type = "MouseEvent", x = ev.x, y = ev.y }
    return ev.x, ev.y
  elseif hook == "onbuttonpressed" and ev.current ~= nil then
    ev.args = { type = "ButtonPressed", current = ev.current, previous = ev.previous }
    return ev.current, ev.previous
  elseif hook == "oncontentchanged" and ev.reason_code ~= nil then
    if ev.content == false then ev.content = nil end
    ev.args = { type = "ContentChanged", reason = ev.reason_code, reasonName = ev.reason,
                content = ev.content }
    return ev.reason_code, ev.content
  elseif hook == "onselectionchanged" and ev.value ~= nil then
    ev.args = { type = "SliderChanged", value = ev.value }
    return ev.value, SLIDER_SELECTED
  elseif hook == "onselectionchanged" and ev.entry_id ~= nil then
    ev.args = { type = "SelectionChanged", entryID = ev.entry_id,
                selectionEvent = ev.selection_event, eventName = ev.reason }
    return ev.entry_id, ev.selection_event
  end
  local raw = { type = "Raw" }
  local i = 0
  while ev["arg" .. i] ~= nil do
    raw[i + 1] = ev["arg" .. i]
    i = i + 1
  end
  ev.args = raw
  return table.unpack(raw, 1, i)
end

-- ui.subscribe a hook on one of our components, once per (component, hook).
function Registry:subscribe(comp, wire)
  if comp._wire[wire] then return end
  if not surface().ui_subscribe then
    unsupported("ui hook " .. wire .. " (this host has no P2 plugin-UI surface)")
  end
  self:call("ui_subscribe", "ui.subscribe", comp.handle, wire)
  comp._wire[wire] = true
end

-- ui.unsubscribe a hook the last callback left. A component already gone sends nothing: the
-- agent dropped its subscriptions with it (and the host answers false for an unknown handle).
function Registry:unsubscribe(comp, wire)
  if not comp._wire[wire] then return end
  comp._wire[wire] = nil
  if comp._dead then return end
  self:call("ui_unsubscribe", "ui.unsubscribe", comp.handle, wire)
end

-- After an overflow some destroyed events may be lost: ask the agent which handles this
-- connection still has, and treat every held handle it no longer lists as gone ("unknown").
function Registry:reconcile(ev)
  log("ui events were dropped (" .. tostring(ev.dropped) .. "); reconciling with ui.list")
  local b = surface()
  local rows, err = b.ui_list(self.game._host)
  if not rows then
    log("reconcile after overflow failed: " .. tostring(err))
    return
  end
  local listed = {}
  for _, row in ipairs(rows) do listed[row.handle] = true end
  local missing = {}
  for handle, comp in pairs(self.comps) do
    if not listed[handle] then missing[#missing + 1] = comp end
  end
  for _, comp in ipairs(missing) do self:gone(comp, REASON_UNKNOWN) end
end

function Registry:dispatch(ev)
  ev.kind, ev.name, ev.pid = "ui", "ui", self.game._pid
  local comp = self.comps[ev.handle]
  ev.component = comp
  if ev.hook == HOOK_DESTROYED and comp then
    self:gone(comp, ev.reason, ev)
  elseif IS_WIRE_HOOK[ev.hook] then
    -- While the run's end releases (on_stop has returned, or the run crashed), a click or a
    -- selection must not call back into the script: it is dropped here, unseen.
    if self.releasing then return ev end
    if comp then run_subs(comp, ev.hook, ev, decode_hook(ev)) else decode_hook(ev) end
  elseif ev.hook == HOOK_OVERFLOW then
    local ok, err = pcall(self.reconcile, self, ev)
    if not ok then log("reconcile after overflow failed: " .. tostring(err)) end
  end
  local listeners = table.move(self.listeners, 1, #self.listeners, 1, {})
  for _, fn in ipairs(listeners) do
    local ok, err = pcall(fn, ev)
    if not ok then log("event handler failed on " .. tostring(ev.hook) .. ": " .. tostring(err)) end
  end
  return ev
end

-- Read every queued ui event (never waits) and dispatch them, in order. One host call hands
-- over at most POLL_BATCH events, so this calls again until one returns fewer. Nothing is read
-- before the first ui call: the host subscribes on that call, so there can be no event.
--
-- Not re-entrant: a callback that sleeps (sleep_ticks pumps) or calls ui:poll() inside a poll
-- gets {}, and the events after its own stay queued for the outer poll, so the order holds.
function Registry:poll()
  if not self.used or not self.game._host or self.polling then return {} end
  self.polling = true
  local all = {}
  local ok, err = pcall(function()
    repeat
      local events = surface().ui_poll_events(self.game._host)
      for _, ev in ipairs(events) do
        self:dispatch(ev)
        all[#all + 1] = ev
      end
    until #events < POLL_BATCH or not self.game._host
  end)
  self.polling = false
  if not ok then error(err, 0) end
  return all
end

-- poll() for the framework's own loops: a failure is logged, never raised into the run.
function Registry:pump()
  local ok, err = pcall(self.poll, self)
  if not ok then log("ui event poll failed: " .. tostring(err)) end
end

-- Destroy everything this Game's ui holds with ONE ui.destroy_all. The Game is one agent
-- connection of its own, so that releases exactly this Game's components and no one else's,
-- and a stalled agent costs one call's timeout, not one per component. Every held component
-- is then forgotten as "released" and its DESTROYED callbacks run, whatever the agent
-- answered: closing the connection releases anything a failed call left. Returns the number
-- of ui.destroy_all calls sent (0 or 1).
function Registry:release()
  if not self.used or not self.game._host or self.game._exited then return 0 end
  self.releasing = true   -- from here no wire-hook callback runs (see dispatch)
  self:pump()   -- learn about anything the game already took down
  local ok, n, err = pcall(surface().ui_destroy_all, self.game._host)
  if not ok then log("release failed: " .. tostring(n))
  elseif n == nil then log("release refused or timed out: " .. tostring(err)) end
  local held = {}   -- ours, newest first
  for i = #self.created, 1, -1 do held[#held + 1] = self.comps[self.created[i]] end
  for _, comp in ipairs(held) do self:gone(comp, REASON_RELEASED) end
  self:detached()   -- the Jagex parents it looked up are released too
  self.releasing = false
  return 1
end

-- The Game detached: the host released this connection's components with it.
function Registry:detached()
  for handle in pairs(self.comps) do self:forget(handle, "detached") end
end

-- Arguments --------------------------------------------------------------------------------

-- A whole number as a Lua integer (2.0 -> 2); anything else is passed on unchanged, so the
-- agent's own range / type refusal is what the script sees.
local function int(v)
  if type(v) == "number" then return math.tointeger(v) or v end
  return v
end

-- A percentage as a float: the wire wants a number, and an integer 0 would go as an int.
local function pc(v)
  if v == nil then return nil end
  if type(v) ~= "number" then error("botwithus.ui: a percentage must be a number", 3) end
  return v + 0.0
end

local function colour(v, verb)
  if type(v) == "table" then
    raise(verb, "unsupported", "Vector4 colours are not supported yet; pass 0xRRGGBBAA")
  end
  return int(v)
end

local function handle_of(reg, v, what)
  if v == nil then
    raise("ui.create", "refused", what .. " is nil (GetComponent found nothing?)")
  end
  if type(v) == "table" and v._reg then
    if v._reg ~= reg then error("botwithus.ui: " .. what .. " belongs to another game", 3) end
    return v.handle
  end
  if math.type(v) == "integer" then return v end
  error("botwithus.ui: " .. what .. " must be a component or a handle", 3)
end

-- Components -------------------------------------------------------------------------------

local Component = {}

-- Jagex property -> wire prop, for assignment (comp.rgba = ...). Per class below.
local SET_COMMON = { rgba = "rgba", clickthrough = "clickthrough", hidden = "hidden",
                     enabled = "enabled" }
-- Jagex property -> readback field. A function converts the field.
local function flag(v) return v ~= nil and v >= 0 and v ~= 0 or false end
-- The wire's `visible` is GLOBAL visibility (false when any parent is hidden): Jagex calls that
-- visibleGlobal. Jagex's `visible` (this component's own) has no wire form yet, so it raises.
-- isQuarantined is ours: the agent could not remove the component and keeps retrying.
local GET_COMMON = { x = "x", y = "y", width = "width", height = "height", rgba = "rgba",
                     visibleGlobal = "visible", clickthrough = "clickthrough",
                     isRestricted = "restricted", isQuarantined = "quarantined",
                     enabled = "enabled" }

local function component_class(name, wire_type, extra)
  local class = { _name = name, _type = wire_type, _set = {}, _get = {}, _methods = {} }
  for k, v in pairs(SET_COMMON) do class._set[k] = v end
  for k, v in pairs(GET_COMMON) do class._get[k] = v end
  for k, v in pairs(extra and extra.set or {}) do class._set[k] = v end
  for k, v in pairs(extra and extra.get or {}) do class._get[k] = v end
  setmetatable(class._methods, { __index = Component })
  class.__index = function(self, key)
    local m = class._methods[key]
    if m ~= nil then return m end
    if type(key) ~= "string" or key:sub(1, 1) == "_" then return nil end   -- internal state
    if FORBIDDEN[key] then raise("ui.get", "refused", FORBIDDEN_TEXT) end
    return Component._read(self, class, key)
  end
  class.__newindex = function(self, key, value)
    if type(key) ~= "string" or key:sub(1, 1) == "_" then rawset(self, key, value); return end
    if FORBIDDEN[key] then raise("ui.set", "refused", FORBIDDEN_TEXT) end
    local prop = class._set[key]
    if not prop then
      if class._get[key] or Component._info_fields[key] then
        error("botwithus.ui: " .. name .. "." .. key .. " is read-only (use SetPos / SetSize)", 2)
      end
      unsupported(name .. "." .. key)
    end
    if type(prop) == "function" then
      self._reg:call("ui_set", "ui.set", self.handle, prop(value))
      return
    end
    if prop == "rgba" then value = colour(value, "ui.set") end
    self._reg:call("ui_set", "ui.set", self.handle, { [prop] = int(value) })
  end
  class.__tostring = function(self)
    return "ui." .. name .. "(" .. tostring(self.handle) .. ")"
  end
  return class
end

-- Fields read from the handle info, with no call.
Component._info_fields = {
  type = "type", typeName = "type_name", interfaceID = "iface", staticID = "comp",
  key = "key", isJagex = "jagex",
}

-- The agent's refusal to read a restricted component's content.
local RESTRICTED_CONTENT = "ui: content of a restricted component cannot be read"

-- `content` of a text or an input field. A restricted input field (a password field) reads as
-- "", as Jagex's does; every other refusal raises.
function Component._content(self, class)
  local reg = self._reg
  local b = surface()
  local host = reg:host()
  reg.used = true
  local r, err, kind = b.ui_get(host, self.handle, true)
  if r ~= nil then return r.content end
  if class._type == "input_field" and kind == "refused" and err == RESTRICTED_CONTENT then
    return ""
  end
  raise("ui.get", kind or "refused", err)
end

function Component._read(self, class, key)
  local info_field = Component._info_fields[key]
  if info_field then return self._info[info_field] end
  if key == "parent" then
    local p = self._info.parent
    if not p or p == 0 then return nil end
    return self._reg.comps[p] or p
  end
  if key == "content" and class._get.content then return Component._content(self, class) end
  local field = class._get[key]
  if not field then unsupported(class._name .. "." .. key) end
  local readback = self._reg:call("ui_get", "ui.get", self.handle)
  if type(field) == "function" then return field(readback) end
  return readback[field]
end

-- Every readback field at once: x, y, width, height, rgba, visible, num_elements ... (with
-- `content` when asked, for a text).
function Component:Get(with_content)
  return self._reg:call("ui_get", "ui.get", self.handle, with_content and true or false)
end

-- Set wire props directly ({ x = 1, rgba = 0xFF0000FF, ... }), all in one call.
function Component:Set(props)
  self._reg:call("ui_set", "ui.set", self.handle, props)
end

function Component:SetX(x, parent_pc, self_pc)
  self:Set({ x = int(x), x_parent_pc = pc(parent_pc), x_self_pc = pc(self_pc) })
end

function Component:SetY(y, parent_pc, self_pc)
  self:Set({ y = int(y), y_parent_pc = pc(parent_pc), y_self_pc = pc(self_pc) })
end

function Component:SetPos(x, y, x_parent_pc, y_parent_pc, x_self_pc, y_self_pc)
  self:Set({ x = int(x), y = int(y), x_parent_pc = pc(x_parent_pc), y_parent_pc = pc(y_parent_pc),
             x_self_pc = pc(x_self_pc), y_self_pc = pc(y_self_pc) })
end

function Component:SetWidth(w, parent_pc)
  self:Set({ width = int(w), width_pc = pc(parent_pc) })
end

function Component:SetHeight(h, parent_pc)
  self:Set({ height = int(h), height_pc = pc(parent_pc) })
end

function Component:SetSize(w, h, width_pc, height_pc)
  self:Set({ width = int(w), height = int(h), width_pc = pc(width_pc), height_pc = pc(height_pc) })
end

function Component:MoveToFront() self._reg:call("ui_order", "ui.order", self.handle, "front") end
function Component:MoveToBack()  self._reg:call("ui_order", "ui.order", self.handle, "back") end

-- Destroy the component (and, in the game, its children). Returns whether its last reference
-- is gone. A component already destroyed (by Destroy, or by the game) returns false and sends
-- nothing. If the agent refuses, the component is already gone in the game (its destroyed
-- event not read yet): it is forgotten as "removed", its DESTROYED callbacks run, and Destroy
-- returns false. Only "timeout" (the outcome is unknown) raises. A Jagex component raises
-- the host's read-only refusal and is kept.
function Component:Destroy()
  if self._dead then return false end
  if self._info.jagex then return self._reg:call("ui_destroy", "ui.destroy", self.handle) end
  local reg = self._reg
  local b = surface()
  reg.used = true
  local freed, err, kind = b.ui_destroy(reg:host(), self.handle)
  if freed == nil then
    if kind == "timeout" then raise("ui.destroy", kind, err) end
    reg:gone(self, REASON_REMOVED)
    return false
  end
  reg:forget(self.handle, "destroyed by the script")
  return freed
end

-- Whether the component is gone, and why ("parent_gone", "destroyed by the script", ...).
function Component:IsDestroyed()
  if self._dead then return true, self._dead end
  return false
end

-- Subscribe(hook, fn) or Subscribe(hook, id, fn). The callback gets Jagex's arguments for the
-- hook, then the event table (its typed record in event.args):
--   DESTROYED                                    fn(component, reason, event)
--   ONCLICK, ONRELEASE, ONMOUSEOVER, ONMOUSELEAVE fn(component, x, y, event)
--   ONBUTTONPRESSED                              fn(component, current, previous, event)
--   ONCONTENTCHANGED                             fn(component, reason, content, event)
--   ONSELECTIONCHANGED (slider)                  fn(component, value, 1, event)
--   ONSELECTIONCHANGED (combo field, list)       fn(component, entryID, selectionEvent, event)
-- Returning false stops later callbacks for the same event. The same hook and id replaces the
-- earlier callback, and so does Subscribe(hook, fn) again (one default callback per hook, as
-- Jagex's), which Unsubscribe(hook) removes. The first callback for a hook sends ui.subscribe
-- (the agent's refusal, e.g.
-- "ui: hook not valid for this type", raises and nothing is kept). Other hooks raise "not
-- supported yet".
-- The key of the listener subscribed without an id: Jagex keeps one default listener per hook,
-- so Subscribe(hook, fn) again replaces it and Unsubscribe(hook) removes it.
local DEFAULT_ID = setmetatable({}, { __tostring = function() return "default" end })

function Component:Subscribe(hook, id, fn)
  if fn == nil then id, fn = nil, id end
  if id == nil then id = DEFAULT_ID end
  if type(fn) ~= "function" then error("botwithus.ui: Subscribe needs a callback", 2) end
  local wire = wire_hook(hook)
  if not wire then unsupported("ui hook " .. tostring(hook)) end
  if wire ~= HOOK_DESTROYED then self._reg:subscribe(self, wire) end
  local subs = self._subs[wire] or {}
  self._subs[wire] = subs
  for _, s in ipairs(subs) do
    if s.id == id then s.fn = fn; return end
  end
  subs[#subs + 1] = { id = id, fn = fn }
end

-- The last callback for a hook is gone: drop the list, and the agent subscription with it.
local function drop_hook(self, wire)
  self._subs[wire] = nil
  if wire ~= HOOK_DESTROYED then self._reg:unsubscribe(self, wire) end
end

-- Unsubscribe(hook) removes the callback subscribed without an id; Unsubscribe(hook, id) the
-- one with that id. Removing the last one sends ui.unsubscribe, unless the component is gone;
-- the host then discards the hook's events not read yet, so a click just before may be lost.
function Component:Unsubscribe(hook, id)
  if id == nil then id = DEFAULT_ID end
  local wire = wire_hook(hook) or hook
  local subs = self._subs[wire]
  if not subs then return end
  for i = #subs, 1, -1 do
    if subs[i].id == id then table.remove(subs, i) end
  end
  if #subs == 0 then drop_hook(self, wire) end
end

function Component:UnsubscribeAll(hook)
  local wire = wire_hook(hook) or hook
  if self._subs[wire] then drop_hook(self, wire) end
end

for _, name in ipairs({ "SetAspectRatio", "UpdateLayout", "GetChild", "Delete", "DeleteAll",
                        "IterateStaticComponents", "IterateDynamicComponents", "SetScrollPos",
                        "SetScrollSize" }) do
  Component[name] = function() unsupported("Component:" .. name) end
end

-- Canvas -----------------------------------------------------------------------------------

local Canvas = {}

-- Send one op now, or queue it inside Batch.
local function canvas_op(self, op)
  if self._batch then
    self._batch[#self._batch + 1] = op
    return nil
  end
  return self._reg:call("ui_canvas", "ui.canvas", self.handle, { op })
end

function Canvas:AddLine(x, y, end_x, end_y, thickness, rgba)
  return canvas_op(self, { op = "line", x = int(x), y = int(y), end_x = int(end_x),
                           end_y = int(end_y), thickness = int(thickness),
                           rgba = colour(rgba, "ui.canvas") })
end

function Canvas:AddOutline(x, y, width, height, thickness, rgba)
  return canvas_op(self, { op = "outline", x = int(x), y = int(y), width = int(width),
                           height = int(height), thickness = int(thickness),
                           rgba = colour(rgba, "ui.canvas") })
end

function Canvas:AddRectangle(x, y, width, height, rgba)
  return canvas_op(self, { op = "rect", x = int(x), y = int(y), width = int(width),
                           height = int(height), rgba = colour(rgba, "ui.canvas") })
end

local function gradient(name)
  return function(self, x, y, width, height, rgba_start, rgba_end)
    return canvas_op(self, { op = name, x = int(x), y = int(y), width = int(width),
                             height = int(height), rgba_start = colour(rgba_start, "ui.canvas"),
                             rgba_end = colour(rgba_end, "ui.canvas") })
  end
end
Canvas.AddGradientH = gradient("gradient_h")
Canvas.AddGradientV = gradient("gradient_v")

function Canvas:AddTriangle(x0, y0, x1, y1, x2, y2, rgba)
  return canvas_op(self, { op = "triangle", x0 = int(x0), y0 = int(y0), x1 = int(x1),
                           y1 = int(y1), x2 = int(x2), y2 = int(y2),
                           rgba = colour(rgba, "ui.canvas") })
end

function Canvas:Clear() return canvas_op(self, { op = "clear" }) end
function Canvas:Undo()  return canvas_op(self, { op = "undo" }) end
function Canvas:AddText()   unsupported("Canvas:AddText") end
function Canvas:AddSprite() unsupported("Canvas:AddSprite") end

-- Ops in their wire form ({ { op = "rect", x = .., ... }, ... }), sent in calls of at most
-- bwu.UI_CANVAS_OPS_MAX. Returns the canvas's element count after the last call.
function Canvas:Draw(ops)
  local max = surface().UI_CANVAS_OPS_MAX
  local count
  for first = 1, #ops, max do
    local chunk = table.move(ops, first, math.min(first + max - 1, #ops), 1, {})
    count = self._reg:call("ui_canvas", "ui.canvas", self.handle, chunk)
  end
  return count
end

-- Run fn(canvas), queueing every Add* / Clear / Undo it makes, then send them together (one
-- call per UI_CANVAS_OPS_MAX ops). Returns the element count, or nil when fn drew nothing.
-- If fn raises, nothing is sent.
function Canvas:Batch(fn)
  if self._batch then error("botwithus.ui: Batch is already open on this canvas", 2) end
  local ops = {}
  rawset(self, "_batch", ops)
  local ok, err = pcall(fn, self)
  rawset(self, "_batch", nil)
  if not ok then error(err, 0) end
  if #ops == 0 then return nil end
  return self:Draw(ops)
end

-- Classes ----------------------------------------------------------------------------------

local function flag_field(field) return function(r) return flag(r[field]) end end
local function count_field(field)
  return function(r) local v = r[field]; return (v ~= nil and v >= 0) and v or nil end
end

local CLASSES = {
  Canvas    = component_class("Canvas", "canvas", { get = { numElements = count_field("num_elements") } }),
  Rectangle = component_class("Rectangle", "rectangle", {
    set = { fill = "fill", outlineThickness = "outline_thickness" },
    get = { fill = flag_field("fill"), outlineThickness = count_field("outline_thickness") } }),
  -- Jagex's Line.width is the stroke width, not the size (SetSize sets the direction).
  Line      = component_class("Line", "line", {
    set = { width = "line_width", invert = "line_invert" },
    get = { width = count_field("line_width"), invert = flag_field("line_invert") } }),
  Text      = component_class("Text", "text", { set = { content = "text", font = "font" },
                                                get = { content = "content" } }),
  Layer     = component_class("Layer", "layer"),
}
for name, fn in pairs(Canvas) do CLASSES.Canvas._methods[name] = fn end
GameUi._CLASSES = CLASSES

-- Interactive types (P2) ------------------------------------------------------------------

local function needs_p2(what)
  if not surface().ui_subscribe then
    unsupported(what .. " (this host has no P2 plugin-UI surface)")
  end
end

-- No Jagex "fire the hook" option: a set through the agent never raises the client's change
-- hook, so triggerEvents = true cannot be honoured.
local function no_trigger(what, trigger)
  if trigger then unsupported(what .. " with triggerEvents") end
end

CLASSES.Button = component_class("Button", "button", {
  set = { label = "label", canToggle = "can_toggle", isToggled = "toggled" },
  get = { label = "label", canToggle = "can_toggle", isToggled = "toggled" } })
CLASSES.Button._methods.SetAssociatedObject = function() unsupported("Button:SetAssociatedObject") end

-- Check.label is sent: the agent refuses it ("ui prop not supported yet: label ...").
CLASSES.Check = component_class("Check", "check", {
  set = { value = "checked", label = "label" }, get = { value = "checked" } })

CLASSES.InputField = component_class("InputField", "input_field", {
  set = { content = "content", filterMode = "filter" },
  get = { content = "content", filterMode = "filter", maxLength = "max_length",
          isFocused = "focused", renders = "renders", fontID = "font_id", spriteID = "sprite_id" } })

local InputField = CLASSES.InputField._methods

-- Jagex's Setup(visibility, filter, maxLength), in one call. A visibility other than VISIBLE
-- is sent as vis_mode, which the agent refuses (it would mark the field restricted).
function InputField:Setup(visibility, filter, max_length)
  local props = { filter = filter, max_length = int(max_length) }
  if visibility ~= nil and visibility ~= VISIBILITY_MODE.VISIBLE then props.vis_mode = int(visibility) end
  self:Set(props)
end

-- Ours: drop the field's input focus (while it has it, the game's keys go to the field).
-- Returns whether it had focus.
function InputField:Blur()
  needs_p2("InputField:Blur")
  return self._reg:call("ui_blur", "ui.blur", self.handle)
end

CLASSES.Slider = component_class("Slider", "slider", {
  set = { value = "value" },
  get = { value = "value", minValue = "min", maxValue = "max", step = "step", ticks = "ticks" } })

local Slider = CLASSES.Slider._methods

-- Jagex's Setup(max, curValue): 0..max in steps of 1. Its other forms (a display divisor and
-- increment rate; named entries) have no wire form yet.
function Slider:Setup(a, b, c)
  if type(a) == "table" then unsupported("Slider:Setup with entries") end
  if c ~= nil then unsupported("Slider:Setup(min, max, curValue, valueDisplayDivisor, incrementRate)") end
  local max = int(a)
  self:Set({ min = 0, max = max, step = 1, ticks = max, value = int(b) })
  return true
end

-- Ours: the wire's range in one call (the client takes min, max, step and ticks together).
function Slider:SetRange(min, max, step, ticks, value)
  self:Set({ min = int(min), max = int(max), step = int(step), ticks = int(ticks), value = int(value) })
  return true
end

function Slider:SetValue(value, trigger)
  no_trigger("Slider:SetValue", trigger)
  self:Set({ value = int(value) })
  return true
end

-- Combo fields and lists: entries are { id, text }; a combo field selects one id (-1: none),
-- a list a set of ids.

local function is_list(self) return getmetatable(self)._type == "list" end

-- A script's entries as the wire's: { "a", "b" } (ids 1..n), { a = 7, b = 9 } (label -> id,
-- sorted by id) or { { id =, text = }, ... }.
local function to_entries(entries)
  if type(entries) ~= "table" then error("botwithus.ui: entries must be a table", 3) end
  local out = {}
  if #entries > 0 then
    for i, e in ipairs(entries) do
      if type(e) == "table" then out[i] = { id = int(e.id), text = e.text }
      else out[i] = { id = i, text = e } end
    end
    return out
  end
  for label, id in pairs(entries) do out[#out + 1] = { id = int(id), text = label } end
  table.sort(out, function(x, y) return x.id < y.id end)
  return out
end

-- The readback's entries in their wire form (what a ui.set takes back).
local function wire_entries(r)
  local out = {}
  for i, e in ipairs(r.entries or {}) do out[i] = { id = e.id, text = e.text } end
  return out
end

local function find_entry(r, id)
  for _, e in ipairs(r.entries or {}) do
    if e.id == id then return e end
  end
  return nil
end

-- The selected ids of a readback, as a list for both types.
local function selection_of(self, r)
  if is_list(self) then return r.selected or {} end
  return (r.selected ~= nil and r.selected >= 0) and { r.selected } or {}
end

local function selection_wire(self, ids)
  if is_list(self) then return ids end
  return ids[1] or -1
end

local Choice = {}

function Choice:SetEntries(entries, selected_id)
  needs_p2(getmetatable(self)._name .. ":SetEntries")
  local props = { entries = to_entries(entries) }
  if selected_id ~= nil then props.selected = selection_wire(self, { int(selected_id) }) end
  self:Set(props)
  return true
end

-- Replace the entries, keeping what is still selected (one ui.set).
local function rewrite(self, r, entries, ids)
  local props = { entries = entries }
  if #ids > 0 then props.selected = selection_wire(self, ids) end
  self:Set(props)
end

function Choice:Add(label, id)
  needs_p2(getmetatable(self)._name .. ":Add")
  id = int(id)
  local r = self:Get()
  if find_entry(r, id) then return false end
  local entries = wire_entries(r)
  entries[#entries + 1] = { id = id, text = label }
  rewrite(self, r, entries, selection_of(self, r))
  return true
end

function Choice:Remove(id)
  needs_p2(getmetatable(self)._name .. ":Remove")
  id = int(id)
  local r = self:Get()
  if not find_entry(r, id) then return false end
  local entries, ids = {}, {}
  for _, e in ipairs(wire_entries(r)) do
    if e.id ~= id then entries[#entries + 1] = e end
  end
  for _, s in ipairs(selection_of(self, r)) do
    if s ~= id then ids[#ids + 1] = s end
  end
  -- The selection goes with the entries every time, so removing the selected entry has a
  -- defined outcome (none selected: -1 / {}), whatever the client would keep.
  self:Set({ entries = entries, selected = selection_wire(self, ids) })
  return true
end

function Choice:Clear()
  needs_p2(getmetatable(self)._name .. ":Clear")
  self:Set({ entries = {} })
end

-- Jagex: a no-op on a single-select list (selection_limit 1); a combo field selects none.
function Choice:UnselectAll()
  needs_p2(getmetatable(self)._name .. ":UnselectAll")
  if is_list(self) and (self:Get().selection_limit or 1) <= 1 then return end
  self:Set({ selected = selection_wire(self, {}) })
end

function Choice:HasEntry(id) return find_entry(self:Get(), int(id)) ~= nil end

local function entry_count(r) return #(r.entries or {}) end

-- A combo entry: { id, text }. Jagex's `selectable` has no wire form yet.
local COMBO_ENTRY = { __index = function(_, key)
  if key == "selectable" then unsupported("ComboField entry.selectable") end
  return nil
end }

local function combo_entries(r)
  local out = wire_entries(r)
  for i, e in ipairs(out) do out[i] = setmetatable(e, COMBO_ENTRY) end
  return out
end

CLASSES.ComboField = component_class("ComboField", "combo_field", {
  get = {
    entries = combo_entries, numEntries = entry_count, selectedID = "selected",
    hasSelection = function(r) return r.selected ~= nil and r.selected >= 0 end,
    selectedLabel = function(r)
      local e = find_entry(r, r.selected)
      return e and e.text or ""
    end } })
for name, fn in pairs(Choice) do CLASSES.ComboField._methods[name] = fn end

function CLASSES.ComboField._methods:Select(id, trigger)
  no_trigger("ComboField:Select", trigger)
  self:Set({ selected = int(id) })
  return true
end

-- A list entry as Jagex shows it: enabled / visible rather than the wire's disabled / hidden.
local function list_entry(e)
  return { id = e.id, text = e.text, enabled = not e.disabled, visible = not e.hidden,
           selected = e.selected and true or false }
end

local function list_entries(r, only_selected)
  local out = {}
  for _, e in ipairs(r.entries or {}) do
    if not only_selected or e.selected then out[#out + 1] = list_entry(e) end
  end
  return out
end

CLASSES.List = component_class("List", "list", {
  set = { maxSelected = "selection_limit" },
  get = { entries = function(r) return list_entries(r, false) end,
          selectedEntries = function(r) return list_entries(r, true) end,
          numEntries = entry_count,
          numSelectedEntries = function(r) return #(r.selected or {}) end,
          selectedIDs = "selected", maxSelected = "selection_limit" } })
for name, fn in pairs(Choice) do CLASSES.List._methods[name] = fn end

local List = CLASSES.List._methods

function List:SetEntrySelected(id, selected, trigger)
  no_trigger("List:SetEntrySelected", trigger)
  id = int(id)
  local r = self:Get()
  local ids = {}
  if selected and (r.selection_limit or 1) <= 1 then
    ids = { id }   -- single select: selecting one replaces the other, as the client does
  else
    for _, s in ipairs(selection_of(self, r)) do
      if s ~= id then ids[#ids + 1] = s end
    end
    if selected then ids[#ids + 1] = id end
  end
  self:Set({ selected = ids })
  return true
end

local function entry_flag(field, default)
  return function(self, id)
    local e = find_entry(self:Get(), int(id))
    if not e then return false end
    return list_entry(e)[field] or default
  end
end
List.GetEntrySelected = entry_flag("selected", false)
List.GetEntryEnabled  = entry_flag("enabled", false)
List.GetEntryVisible  = entry_flag("visible", false)
for _, name in ipairs({ "SetEntryEnabled", "SetEntryVisible", "SetEntryIcon" }) do
  List[name] = function() unsupported("List:" .. name) end
end

-- Panel.vertical is ours (the wire's); its spacing is refused by the agent as not supported yet.
CLASSES.Panel = component_class("Panel", "panel", { set = { vertical = "vertical" },
                                                    get = { vertical = "vertical" } })
CLASSES.Grid = component_class("Grid", "grid")

-- Types the agent will add (it refuses them today with "ui type not supported yet: <type>").
local LATER_TYPES = { Sprite = "sprite", Model = "model" }
for name, wire in pairs(LATER_TYPES) do CLASSES[name] = component_class(name, wire) end

-- The class for a type_name the agent reports (Jagex parents report "other").
local BY_TYPE_NAME = {}
for _, class in pairs(CLASSES) do BY_TYPE_NAME[class._type] = class end
local OTHER = component_class("Component", "other")

-- The namespace ---------------------------------------------------------------------------

local function create(reg, class, parent, category, dynamic, props)
  local parent_handle = handle_of(reg, parent, "parent")
  local opts = { category = int(category), dynamic = int(dynamic) }
  local info = reg:call("ui_create", "ui.create", parent_handle, class._type, props, opts)
  return reg:wrap(info, class, true)
end

local function make_type(reg, class)
  return {
    -- Jagex: Type.new(parent, categoryID?, dynamicID?).
    new = function(parent, category, dynamic) return create(reg, class, parent, category, dynamic) end,
    -- Ours: create with its wire props in one call, e.g. ui.Text.create(p, { text = "hi", x = 4 }).
    create = function(parent, props, opts)
      opts = opts or {}
      return create(reg, class, parent, opts.category, opts.dynamic, props)
    end,
  }
end

local function make_interfaces(reg)
  local Interfaces = {}

  -- A Jagex component as a parent (or a ui.get target), or nil, message, kind. `key` picks a
  -- dynamic child of the static component (the `.key` its handle reports); nil for the
  -- static component itself.
  function Interfaces:GetComponentByKey(iface, comp, key)
    local b = surface()
    reg.used = true
    local info, err, kind = b.ui_get_component(reg:host(), int(iface), int(comp), key and int(key))
    if info == nil then return nil, err, kind end
    return reg:wrap(info, BY_TYPE_NAME[info.type_name] or OTHER, false)
  end

  -- Jagex's static forms: (combinedID) and (interfaceID, staticID). The dynamic-child forms,
  -- (combinedID, categoryID, dynamicID) and (interfaceID, staticID, categoryID, dynamicID),
  -- raise "not supported yet": the agent looks a child up by its key, not by category and
  -- id. GetComponentByKey takes that key (a component's `.key`).
  function Interfaces:GetComponent(a, b, c, d)
    if c ~= nil or d ~= nil then
      unsupported("ui.Interfaces:GetComponent with a category and dynamic id")
    end
    if b == nil then
      if math.type(a) ~= "integer" then error("botwithus.ui: a combined id must be an integer", 2) end
      return self:GetComponentByKey(a >> COMBINED_SHIFT, a & COMBINED_MASK)
    end
    return self:GetComponentByKey(a, b)
  end

  function Interfaces:GetInterface() unsupported("ui.Interfaces:GetInterface") end
  return Interfaces
end

local function make_namespace(reg)
  local ns = { ComponentType = {}, Hook = { DESTROYED = HOOK_DESTROYED },
               HOOK_DESTROYED = HOOK_DESTROYED, HOOK_OVERFLOW = HOOK_OVERFLOW,
               Error = UiError, is_error = GameUi.is_error, Interfaces = make_interfaces(reg) }
  for k, v in pairs(COMPONENT_TYPE) do ns.ComponentType[k] = v end
  for _, h in ipairs(JAGEX_HOOKS) do ns.Hook[h] = h end
  ns.InputFieldActionResult = setmetatable({}, { __index = INPUT_ACTION_RESULT })
  ns.SelectionChangeEvent = setmetatable({}, { __index = SELECTION_CHANGE_EVENT })
  ns.InputFieldFilterMode = setmetatable({}, { __index = FILTER_MODE })
  ns.TextContentVisibilityMode = setmetatable({}, { __index = VISIBILITY_MODE })
  for name, class in pairs(CLASSES) do ns[name] = make_type(reg, class) end

  -- Call fn(event) for every ui event of this Game. Returns a function that removes it.
  function ns:on_event(fn)
    assert(type(fn) == "function", "botwithus: a handler must be a function")
    reg.listeners[#reg.listeners + 1] = fn
    return function()
      for i, f in ipairs(reg.listeners) do
        if f == fn then table.remove(reg.listeners, i); return end
      end
    end
  end

  -- Read and dispatch every queued ui event now (never waits). Returns them.
  function ns:poll() return reg:poll() end

  -- This connection's handles as the agent lists them (info tables, Jagex parents included).
  function ns:list() return reg:call("ui_list", "ui.list") end

  -- The components this Game's ui made and still holds, oldest first.
  function ns:components()
    local out = {}
    for i, h in ipairs(reg.created) do out[i] = reg.comps[h] end
    return out
  end

  -- Destroy everything this Game's ui made (as the end of a run does). Returns the count.
  function ns:release() return reg:release() end

  return ns
end

-- A new registry for a Game (botwithus.game calls this once per Game, from Game:ui()).
function GameUi.new(game)
  local reg = setmetatable({ game = game, comps = {}, created = {}, listeners = {},
                             used = false }, Registry)
  reg.ns = make_namespace(reg)
  return reg
end

return GameUi
