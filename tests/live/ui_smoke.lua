-- Live plugin-UI smoke for botwithus.game_ui: bwu_host --lua tests/live/ui_smoke.lua
--
-- Written against this framework's API only (bot.run, ctx.ui, ui.Layer.new, ...), never the
-- raw bwu.ui_* bindings. Needs a client in the world whose agent has the ui.* verbs, and a
-- bwu_host with bwu.ui_*. It follows the native host's live smoke contract, so that host's
-- driver (or one like it) can run it. Environment:
--   BWU_SMOKE_PID   the client pid (default: the first discovered client)
--   BWU_SMOKE_OUT   a file this script writes its results to, one "key=value" per line
--   BWU_SMOKE_MODE  "cleanup" (default) or "event"
--
-- cleanup: under TOPLEVEL_V2__GAME_AREA (1477:61) it makes a layer, a text, a canvas and a
--   rectangle inside the layer, draws on the canvas, reads it all back and checks the agent's
--   refusals reach the script verbatim. It writes the keys and handles, then "ready=1", and
--   runs until the file BWU_SMOKE_OUT .. ".go" exists. bot.run then ends, and the framework
--   must release the four components itself (one ui.destroy_all) before it detaches.
-- event: makes a layer, subscribes to its DESTROYED hook and writes "ready=1"; a second
--   connection makes another layer whose events nobody reads. The driver takes the client to
--   the lobby; the callback writes "event_reason=...", then Destroys the other layer (gone in
--   the game, event unread) and writes what that returned. The run ends once the driver logs
--   back in and "BWU_SMOKE_OUT .. '.go'" exists (or after 180 s).
-- Raises (bwu_host exits non-zero) on any mismatch.

-- `botwithus` comes from package.path: set LUA_PATH to this repo
-- ("<repo>/?.lua;<repo>/?/init.lua;;") and run from a directory with no other copy in it.
-- bwu_host names chunks by their short path, so this file cannot find its repo by itself.
local bot = require("botwithus")
assert(bot.GameUi, "the botwithus on package.path has no game_ui: set LUA_PATH to this repo")

local IFACE, COMP = 1477, 61   -- TOPLEVEL_V2__GAME_AREA
local FORBIDDEN = "ui: prop forbidden on agent components (no op, drag or target configuration)"
local READ_ONLY = "ui: handle is a Jagex component: read-only, usable only as a parent or with ui.get"
local EVENT_TIMEOUT_S = 180

local out_path = assert(os.getenv("BWU_SMOKE_OUT"), "BWU_SMOKE_OUT not set")
local mode = os.getenv("BWU_SMOKE_MODE") or "cleanup"
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

-- The ui error a call raises, which must be the agent's own text.
local function refusal(label, want, fn, ...)
  local ok, err = pcall(fn, ...)
  check(label .. " raised", ok, false)
  check(label .. " is a ui error", bot.GameUi.is_error(err), true)
  check(label .. " kind", err.kind, "refused")
  check(label .. " text", err.message, want)
end

local function build(ui)
  local area = assert(ui.Interfaces:GetComponent(IFACE, COMP))
  check("area jagex", area.isJagex, true)
  check("combined id", ui.Interfaces:GetComponent((IFACE << 16) | COMP), area)

  local layer = ui.Layer.new(area)
  layer:SetPos(40, 40)
  layer:SetSize(320, 140)
  local text = ui.Text.new(area)
  text:SetPos(48, 48)
  text:SetSize(300, 20)
  text.content = "botwithus.game_ui smoke"
  text.rgba = 0xFFFF00FF
  local canvas = ui.Canvas.new(area)
  canvas:SetPos(40, 80)
  canvas:SetSize(320, 100)
  local inner = ui.Rectangle.new(layer)
  inner:SetPos(4, 4)
  inner:SetSize(20, 20)
  inner.rgba = 0x00FF00FF
  inner.fill = true
  return area, layer, text, canvas, inner
end

local function draw_and_read(ui, area, layer, text, canvas, inner)
  check("batch elements", canvas:Batch(function(c)
    c:AddRectangle(0, 0, 320, 100, 0x20202080)
    c:AddOutline(0, 0, 320, 100, 2, 0xFFFFFFFF)
    c:AddLine(10, 10, 310, 90, 3, 0xFF0000FF)
  end), 3)
  check("triangle", canvas:AddTriangle(20, 20, 60, 20, 40, 60, 0x0000FFFF), 4)
  check("undo", canvas:Undo(), 3)
  check("text content", text.content, "botwithus.game_ui smoke")
  check("text visibleGlobal", text.visibleGlobal, true)
  check("text isRestricted", text.isRestricted, false)
  check("text rgba", text.rgba, 0xFFFF00FF)
  check("canvas x", canvas.x, 40)
  check("canvas width", canvas.width, 320)
  check("canvas numElements", canvas.numElements, 3)
  check("canvas op_mask", canvas:Get().op_mask, 0)
  check("layer height", layer.height, 140)
  check("inner fill", inner.fill, true)
  check("inner parent", inner.parent, layer)
  check("list", #ui:list(), 5)   -- the Jagex parent and four components
  check("held", #ui:components(), 4)

  refusal("forbidden prop", FORBIDDEN, layer.Set, layer, { op_config = 1 })
  refusal("jagex edit", READ_ONLY, area.SetPos, area, 1, 1)
  refusal("later type", "ui type not supported yet: button", ui.Button.new, area)
  refusal("later prop", "ui prop not supported yet: hidden", function() layer.hidden = true end)
  refusal("category 0", "ui: bad_param category (1..234)", ui.Layer.new, area, 0)
  refusal("Jagex opConfig", FORBIDDEN, function() layer.opConfig = 1 end)
end

local function run_cleanup()
  bot.run({
    manifest = { name = "game_ui smoke", version = "1", author = "botwithus" },
    on_start = function(ctx)
      local area, layer, text, canvas, inner = build(ctx.ui)
      draw_and_read(ctx.ui, area, layer, text, canvas, inner)
      note("layer_key", layer.key)
      note("text_key", text.key)
      note("canvas_key", canvas.key)
      note("handles", table.concat({ layer.handle, text.handle, canvas.handle, inner.handle }, ","))
      note("ready", 1)
    end,
    on_loop = function() return go_signal() and -1 or 1 end,
  }, { pid = pid })
  -- bot.run has ended: the framework released the four components with one ui.destroy_all,
  -- then detached.
end

local function run_event()
  local reason
  -- A second connection the runner never reads events for: its layer's destroyed event stays
  -- unread, so its Destroy after the logout meets the agent's refusal (already gone).
  local other = bot.Game.attach(pid)
  local stale
  bot.run({
    manifest = { name = "game_ui event smoke", version = "1", author = "botwithus" },
    on_start = function(ctx)
      local ui = ctx.ui
      local area = assert(ui.Interfaces:GetComponent(IFACE, COMP))
      local layer = ui.Layer.new(area)
      layer:SetPos(40, 40)
      layer:SetSize(100, 40)
      local oui = other:ui()
      stale = oui.Layer.new(assert(oui.Interfaces:GetComponent(IFACE, COMP)))
      local stale_reason
      stale:Subscribe(oui.Hook.DESTROYED, function(_, why) stale_reason = why end)
      layer:Subscribe(ui.Hook.DESTROYED, function(comp, why)
        reason = why
        note("event_reason", why)
        note("event_destroyed", comp:IsDestroyed())
        -- Destroy after the logout, its event not read: no raise, false, reason "removed".
        local ok, freed = pcall(stale.Destroy, stale)
        note("stale_destroy_ok", ok)
        note("stale_destroy_result", tostring(freed))
        note("stale_reason", tostring(stale_reason))
        note("stale_handle", stale.handle)
      end)
      note("layer_handle", layer.handle)
      note("ready", 1)
      ctx.deadline = os.time() + EVENT_TIMEOUT_S
    end,
    on_loop = function(ctx)
      if reason and go_signal() then return -1 end
      if os.time() > ctx.deadline then error("no destroyed event within " .. EVENT_TIMEOUT_S .. " s") end
      return 1
    end,
  }, { pid = pid })
  other:detach()
  check("event reason", reason, "parent_gone")
end

if mode == "event" then run_event() else run_cleanup() end
note("done", 1)
