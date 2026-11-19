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
-- clickthrough, the line, rectangle and text properties; the canvas shapes; MoveToFront /
-- MoveToBack; Destroy; and the DESTROYED hook. Other component types and properties are sent
-- to the agent all the same, so its own "not supported yet" refusal is what the script sees,
-- and they start working when the agent supports them. Canvas text and sprites and every
-- other hook raise "not supported yet" here: their arguments are not defined on the wire yet.
--
-- Errors. Every call RAISES on failure, as Jagex's API does not return error codes. The error
-- is a table with `verb` ("ui.create" ...), `kind` and `message`, and it prints as text:
--   kind "refused"      the agent (or the host on its behalf) refused; `message` is its text,
--                       verbatim, e.g. "ui: prop forbidden on agent components (...)"
--   kind "timeout"      no answer in time ("rpc_timeout"); the outcome is unknown
--   kind "unsupported"  this framework has no wire form for it yet
-- Catch one with pcall and read err.kind / err.message. ui.Interfaces:GetComponent is the one
-- exception: like Jagex's, it returns nil when the component is not there (with the message
-- and kind as second and third values). A lost pipe or a malformed reply raises the host's
-- own error, as every other host call does.
--
-- Lifetime. Components belong to the Game's own connection to the agent. When a bot.run ends
-- (or a GUI worker's run), the framework destroys every component that Game's ui made, one
-- ui.destroy each, before it detaches. The host then releases whatever is left on the same
-- connection at detach and at the end of the process, and the agent at pipe close; nothing
-- here ever sends ui.destroy_all. A component the game took down (its parent closed, logout)
-- is announced by a "destroyed" event and forgotten, so it is never destroyed twice.
--
-- Events. bwu.ui_poll_events never waits. It is read by ui:poll(), by bot.run once per server
-- tick while the script sleeps, and by a botwithus.clients manager in :poll() / :pump() for
-- each Game it attached (as events of kind "ui"). Each event is
--   { kind = "ui", name = "ui", pid, handle, hook, reason, truncated, component }
-- plus the hook's own fields; hook "overflow" (handle 0, `dropped`) reports events the host
-- had to drop. A "destroyed" event runs the component's Subscribe callbacks first.

local GameUi = {}

-- The client's ui.ComponentType values the agent reports (`type` on a component).
local COMPONENT_TYPE = { LINE = 0, RECTANGLE = 1, LABEL = 2, CANVAS = 8, LAYER = 20 }

-- Jagex's hook names. Only DESTROYED (ours: the agent's ui.event) is delivered today; the rest
-- raise "not supported yet" from Subscribe until the agent pushes them.
local HOOK_DESTROYED = "destroyed"
local HOOK_OVERFLOW  = "overflow"
local JAGEX_HOOKS = {
  "ONCLICK", "ONCLICKREPEAT", "ONRELEASE", "ONHOLD", "ONMOUSEOVER", "ONMOUSEREPEAT",
  "ONMOUSELEAVE", "ONDRAG", "ONDRAGCOMPLETE", "ONSCROLLWHEEL", "ONKEY", "ONBUTTONPRESSED",
  "ONCONTENTCHANGED", "ONSELECTIONCHANGED", "ONOP", "ONOPT", "ONTIMER", "ONRESIZE",
}

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
  comp = setmetatable({ handle = info.handle, _reg = self, _info = info, _subs = {} }, class)
  self.comps[info.handle] = comp
  if is_ours then self.created[#self.created + 1] = info.handle end
  return comp
end

-- Forget a handle (destroyed by us or by the game). Its object stays usable for reads of
-- its last info, and refuses edits through the agent ("unknown handle").
function Registry:forget(handle, reason)
  local comp = self.comps[handle]
  if comp then comp._dead = reason or true end
  self.comps[handle] = nil
  for i = #self.created, 1, -1 do
    if self.created[i] == handle then table.remove(self.created, i) end
  end
end

local function run_subs(comp, hook, ev)
  local subs = comp._subs[hook]
  if not subs then return end
  local list = table.move(subs, 1, #subs, 1, {})   -- a callback may unsubscribe
  for _, s in ipairs(list) do
    local ok, keep_going = pcall(s.fn, comp, ev.reason, ev)
    if not ok then log("callback for " .. hook .. " failed: " .. tostring(keep_going))
    elseif keep_going == false then return end   -- Jagex: false stops later listeners
  end
end

function Registry:dispatch(ev)
  ev.kind, ev.name, ev.pid = "ui", "ui", self.game._pid
  local comp = self.comps[ev.handle]
  ev.component = comp
  if ev.hook == HOOK_DESTROYED and comp then
    self:forget(ev.handle, ev.reason)
    run_subs(comp, HOOK_DESTROYED, ev)
  end
  local listeners = table.move(self.listeners, 1, #self.listeners, 1, {})
  for _, fn in ipairs(listeners) do
    local ok, err = pcall(fn, ev)
    if not ok then log("event handler failed on " .. tostring(ev.hook) .. ": " .. tostring(err)) end
  end
  return ev
end

-- Read every queued ui event once (never waits) and dispatch them, in order. Nothing is read
-- before the first ui call: the host subscribes on that call, so there can be no event.
function Registry:poll()
  if not self.used or not self.game._host then return {} end
  local events = surface().ui_poll_events(self.game._host)
  for _, ev in ipairs(events) do self:dispatch(ev) end
  return events
end

-- poll() for the framework's own loops: a failure is logged, never raised into the run.
function Registry:pump()
  local ok, err = pcall(self.poll, self)
  if not ok then log("ui event poll failed: " .. tostring(err)) end
end

-- Destroy every component this Game's ui made and still holds, newest first (children before
-- their parents), one ui.destroy each. A refusal (already gone in the game) is not an error
-- here: the handle is forgotten either way. Returns how many destroys were sent.
function Registry:release()
  if not self.used or not self.game._host or self.game._exited then return 0 end
  self:pump()   -- learn about anything the game already took down
  local sent = 0
  for i = #self.created, 1, -1 do
    local handle = self.created[i]
    local ok, err = pcall(surface().ui_destroy, self.game._host, handle)
    if not ok then log("release of " .. tostring(handle) .. " failed: " .. tostring(err)) end
    sent = sent + 1
    self:forget(handle, "released")
  end
  return sent
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
local GET_COMMON = { x = "x", y = "y", width = "width", height = "height", rgba = "rgba",
                     visible = "visible", clickthrough = "clickthrough", restricted = "restricted",
                     isQuarantined = "quarantined" }

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
    return Component._read(self, class, key)
  end
  class.__newindex = function(self, key, value)
    if type(key) ~= "string" or key:sub(1, 1) == "_" then rawset(self, key, value); return end
    local prop = class._set[key]
    if not prop then
      if class._get[key] or Component._info_fields[key] then
        error("botwithus.ui: " .. name .. "." .. key .. " is read-only (use SetPos / SetSize)", 2)
      end
      unsupported(name .. "." .. key)
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

function Component._read(self, class, key)
  local info_field = Component._info_fields[key]
  if info_field then return self._info[info_field] end
  if key == "parent" then
    local p = self._info.parent
    if not p or p == 0 then return nil end
    return self._reg.comps[p] or p
  end
  if key == "content" and class._get.content then
    return self._reg:call("ui_get", "ui.get", self.handle, true).content
  end
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
-- nothing.
function Component:Destroy()
  if self._dead then return false end
  local freed = self._reg:call("ui_destroy", "ui.destroy", self.handle)
  self._reg:forget(self.handle, "destroyed by the script")
  return freed
end

-- Whether the component is gone, and why ("parent_gone", "destroyed by the script", ...).
function Component:IsDestroyed()
  if self._dead then return true, self._dead end
  return false
end

-- Subscribe(hook, fn) or Subscribe(hook, id, fn). fn(component, reason, event); returning
-- false stops later callbacks for the same event. The same hook and id replaces the earlier
-- callback. Only ui.Hook.DESTROYED is delivered today.
function Component:Subscribe(hook, id, fn)
  if fn == nil then id, fn = nil, id end
  if type(fn) ~= "function" then error("botwithus.ui: Subscribe needs a callback", 2) end
  if hook ~= HOOK_DESTROYED then unsupported("ui hook " .. tostring(hook)) end
  local subs = self._subs[hook] or {}
  self._subs[hook] = subs
  if id ~= nil then
    for _, s in ipairs(subs) do
      if s.id == id then s.fn = fn; return end
    end
  end
  subs[#subs + 1] = { id = id, fn = fn }
end

-- Unsubscribe(hook) removes the callback subscribed without an id; Unsubscribe(hook, id) the
-- one with that id.
function Component:Unsubscribe(hook, id)
  local subs = self._subs[hook] or {}
  for i = #subs, 1, -1 do
    if subs[i].id == id then table.remove(subs, i) end
  end
end

function Component:UnsubscribeAll(hook) self._subs[hook] = nil end

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

-- Types the agent will add (it refuses them today with "ui type not supported yet: <type>").
local LATER_TYPES = { Sprite = "sprite", Button = "button", Model = "model", Panel = "panel",
                      Grid = "grid", InputField = "input_field", Check = "check", Slider = "slider",
                      ComboField = "combo_field", List = "list" }
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
