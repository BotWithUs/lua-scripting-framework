-- botwithus.clients -- manage game clients through the BotWithUs launcher's background service.
--
--   local bot = require("botwithus")
--   local cm  = bot.clients.new()
--   local launch = assert(cm:launch(cm:accounts()[1].id))
--   local game   = assert(launch:wait_attached(300))
--   ...
--   cm:stop(launch.client_id, "graceful")
--
-- This is the entry point for a management script: list accounts, launch, stop and list
-- clients, watch the service's events, and answer a request to close for a data update.
-- It sits on the `cm_*` functions of the native `bwu` table, like every other module here.
--
-- The host keeps one connection to the service for the whole process and reconnects on its
-- own; scripts never open or close it. The Lua state has one thread, so nothing happens "in
-- the background": events wait in the host's queue until the script reads them with
-- :poll(), :pump() or :wait_for(), and handlers run only inside those calls.
--
-- Errors. A call the service could not answer, or refused, returns nil, code, message --
-- "service_unavailable" is a normal state, not a crash. Mistakes in the calling code (an
-- unknown stop mode, a bad decision) raise "botwithus: ..." errors, like the rest of the
-- framework.

local Game = require("botwithus.game")

local Clients = {}
Clients.__index = Clients

-- The client-management surface version this module is written against.
Clients.SURFACE_VERSION = 1
-- The longest single wait :poll() and :pump() will make. The state has one thread, so a
-- long wait would freeze the script; :wait_for() loops in slices of WAIT_SLICE_MS instead.
Clients.MAX_POLL_MS   = 1000
Clients.WAIT_SLICE_MS = 200

-- Names for the surface's integer constants. The integers stay on every record and event;
-- the names are added beside them so scripts can read and log them.
local STATE_NAMES = {
  CM_STATE_QUEUED = "queued", CM_STATE_SPAWNING = "spawning", CM_STATE_INJECTING = "injecting",
  CM_STATE_INJECTED = "injected", CM_STATE_FAILED = "failed", CM_STATE_EXITED = "exited",
}
local EVENT_NAMES = {
  CM_EV_CLIENT_STARTED = "client_started", CM_EV_CLIENT_STATE = "client_state",
  CM_EV_CLIENT_EXITED = "client_exited", CM_EV_AGENT_UPDATED = "agent_updated",
  CM_EV_DATA_UPDATE_AVAILABLE = "data_update_available",
  CM_EV_DATA_UPDATE_APPLIED = "data_update_applied", CM_EV_CLOSE_REQUESTED = "close_requested",
  CM_EV_LICENCE_STATE = "licence_state", CM_EV_SERVICE_SHUTTING_DOWN = "service_shutting_down",
  CM_EV_SERVICE_LOST = "service_lost", CM_EV_SERVICE_RESTORED = "service_restored",
  CM_EV_EVENTS_DROPPED = "events_dropped",
}
local KIND_NAMES   = { CM_KIND_JAGEX = "jagex", CM_KIND_STEAM = "steam", CM_KIND_ATTACHED = "attached" }
local ORIGIN_NAMES = { CM_ORIGIN_UI = "ui", CM_ORIGIN_AUTOMATION = "automation" }
local LICENCE_NAMES = {
  CM_LIC_OK = "ok", CM_LIC_RETRYING = "retrying", CM_LIC_DROPPED = "dropped",
  CM_LIC_UNTRACKED = "untracked",
}
local EXIT_NAMES = {
  CM_EXIT_STOPPED = "stopped", CM_EXIT_LICENCE = "licence", CM_EXIT_DESCRIPTOR = "descriptor",
  CM_EXIT_UNKNOWN = "unknown",
}
local MODE_NAMES     = { CM_STOP_GRACEFUL = "graceful", CM_STOP_KILL = "kill" }
local DECISION_NAMES = { CM_ACK_CLOSING = "closing", CM_ACK_DECLINED = "declined", CM_ACK_LATER = "later" }

-- Why a Game this module attached was detached for the script.
Clients.DETACHED_EXITED    = "the client exited"
Clients.DETACHED_RESTARTED = "the client restarted as a new process"

-- Resolve the surface at call time, like botwithus.game, so tests can inject a fake.
local function surface()
  local b = rawget(_G, "bwu")
  if not b then error("botwithus: native `bwu` surface not present (run under bwu_host)", 3) end
  if b.CM_SURFACE_VERSION ~= Clients.SURFACE_VERSION then
    error("botwithus: this host has no client-management surface v" .. Clients.SURFACE_VERSION
      .. " (it reports " .. tostring(b.CM_SURFACE_VERSION) .. ")", 3)
  end
  return b
end

-- integer constant -> name, for one of the tables above.
local function name_of(names, value)
  local b = surface()
  for constant, name in pairs(names) do
    if b[constant] == value then return name end
  end
  return nil
end

-- A name ("kill") or an integer constant -> the integer. Anything else raises.
local function constant_of(names, value, what)
  local b = surface()
  for constant, name in pairs(names) do
    if value == name or value == b[constant] then return b[constant] end
  end
  error("botwithus: unknown " .. what .. " " .. tostring(value), 3)
end

local function log(line) io.stderr:write("[botwithus.clients] ", line, "\n") end

-- Create a manager. Each one has its own handlers, its own view of the clients and its
-- own record of which clients it attached to.
function Clients.new()
  surface()
  return setmetatable({
    _listeners = {},   -- { kind = integer or nil, fn = function }, in registration order
    _close_hook = nil,
    _known = {},       -- client_id -> { pid, state, failure }
    _claims = {},      -- pid -> { game, client_id }
  }, Clients)
end

-- Names ----------------------------------------------------------------------------------

function Clients.state_name(state)  return name_of(STATE_NAMES, state) end
function Clients.event_name(kind)   return name_of(EVENT_NAMES, kind) end

local function decorate_client(c)
  c.state_name   = name_of(STATE_NAMES, c.state)
  c.kind_name    = name_of(KIND_NAMES, c.kind)
  c.origin_name  = name_of(ORIGIN_NAMES, c.origin)
  c.licence_name = name_of(LICENCE_NAMES, c.licence_state)
  return c
end

local function decorate_event(ev)
  local b = surface()
  ev.name = name_of(EVENT_NAMES, ev.kind)
  if ev.kind == b.CM_EV_LICENCE_STATE then
    ev.state_name = name_of(LICENCE_NAMES, ev.state)
  elseif ev.state ~= 0 then
    ev.state_name = name_of(STATE_NAMES, ev.state)
  end
  if ev.kind == b.CM_EV_CLIENT_EXITED then ev.reason_name = name_of(EXIT_NAMES, ev.reason) end
  return ev
end

-- Tracking and attach claims --------------------------------------------------------------

local function known(self, client_id)
  local k = self._known[client_id]
  if not k then k = {}; self._known[client_id] = k end
  return k
end

-- Detach a Game this manager attached because its process is gone.
local function release_pid(self, pid, reason)
  local claim = self._claims[pid]
  if claim then claim.game:_release(reason) end
end

local function release_client(self, client_id, reason)
  for pid, claim in pairs(self._claims) do
    if claim.client_id == client_id then release_pid(self, pid, reason) end
  end
end

-- Replace the view of the clients with a fresh list from the service, and detach any
-- client this manager attached that the list says is gone or now has another pid.
local function adopt(self, list)
  local live = {}
  for _, c in ipairs(list) do
    live[c.client_id] = c
    self._known[c.client_id] = { pid = c.pid, state = c.state }
  end
  local b = surface()
  for pid, claim in pairs(self._claims) do
    local c = claim.client_id and live[claim.client_id]
    if claim.client_id and (not c or c.state == b.CM_STATE_EXITED) then
      release_pid(self, pid, Clients.DETACHED_EXITED)
    elseif c and c.pid ~= pid then
      release_pid(self, pid, Clients.DETACHED_RESTARTED)
    end
  end
end

local function track(self, ev)
  local b = surface()
  if ev.kind == b.CM_EV_CLIENT_STARTED then
    local k = known(self, ev.client_id)
    if k.pid and k.pid ~= 0 and k.pid ~= ev.pid then
      release_pid(self, k.pid, Clients.DETACHED_RESTARTED)
    end
    k.pid, k.state, k.failure = ev.pid, ev.state, nil
  elseif ev.kind == b.CM_EV_CLIENT_STATE then
    local k = known(self, ev.client_id)
    k.state = ev.state
    k.failure = (ev.state == b.CM_STATE_FAILED) and ev.text or nil
  elseif ev.kind == b.CM_EV_CLIENT_EXITED then
    known(self, ev.client_id).state = b.CM_STATE_EXITED
    release_client(self, ev.client_id, Clients.DETACHED_EXITED)
  end
end

-- Calls ----------------------------------------------------------------------------------

-- The launcher's accounts this host may launch: a list of { id, name }.
function Clients:accounts()
  return surface().cm_accounts()
end

-- The clients the service manages: a list of records with client_id, account_id,
-- account_name, pid, character_index, kind, origin, state, licence_state,
-- licence_failures, is_agent_stale, restart_of, started_at_ms and agent_sha, plus
-- state_name, kind_name, origin_name and licence_name.
function Clients:clients()
  local list, code, msg = surface().cm_clients()
  if not list then return nil, code, msg end
  for _, c in ipairs(list) do decorate_client(c) end
  adopt(self, list)
  return list
end

local Launch = {}
Launch.__index = Launch

-- Ask the service to launch a client on an account. Returns once the launch is queued,
-- with a handle whose client_id names the client. character_index is for Steam accounts.
-- On failure: nil, code, message, retry_after_ms (-1 unless the code is "rate_limited").
function Clients:launch(account_id, character_index)
  local b = surface()
  local client_id, code, msg = b.cm_launch(account_id, character_index or -1)
  if not client_id then return nil, code, msg, b.cm_last_retry_after_ms() end
  known(self, client_id).state = b.CM_STATE_QUEUED
  return setmetatable({ client_id = client_id, _cm = self }, Launch)
end

-- Stop any client, whoever launched it. mode is "graceful" (the default: ask the game to
-- close) or "kill" (end the process at once), or a CM_STOP_* constant. A client_exited
-- event follows.
function Clients:stop(client_id, mode)
  local m = constant_of(MODE_NAMES, mode or "graceful", "stop mode")
  return surface().cm_stop(client_id, m)
end

-- Answer a close request. decision is "closing", "declined" or "later", or a CM_ACK_*
-- constant. Only the launcher's display changes; nothing is closed for you.
function Clients:ack_close(request_id, decision)
  if math.type(request_id) ~= "integer" or request_id <= 0 then
    error("botwithus: request_id must be a positive integer, got " .. tostring(request_id), 2)
  end
  local d = constant_of(DECISION_NAMES, decision, "close decision")
  return surface().cm_ack_close(request_id, d)
end

-- Events ---------------------------------------------------------------------------------

-- Call fn(event) for every event. Returns a function that removes it again.
function Clients:on_event(fn)
  return self:on(nil, fn)
end

-- Call fn(event) for one kind of event: a name ("client_exited") or a CM_EV_* constant.
function Clients:on(kind, fn)
  assert(type(fn) == "function", "botwithus: a handler must be a function")
  local entry = { kind = kind and constant_of(EVENT_NAMES, kind, "event kind"), fn = fn }
  self._listeners[#self._listeners + 1] = entry
  return function()
    for i, e in ipairs(self._listeners) do
      if e == entry then table.remove(self._listeners, i); return end
    end
  end
end

-- Set the handler for a request to close this host for a data update; nil removes it.
-- fn(request) gets { request_id, reason, hosts_blocking } and returns a decision --
-- "closing", "declined" or "later" -- which is sent for it, or nil to send nothing now
-- (it can call :ack_close later). With no handler nothing is ever sent and the script
-- keeps running: not answering is a normal state, and the host never closes on its own.
function Clients:on_close_requested(fn)
  assert(fn == nil or type(fn) == "function", "botwithus: a handler must be a function or nil")
  self._close_hook = fn
end

local function answer_close(self, ev)
  local hook = self._close_hook
  if not hook then return end
  local request = { request_id = ev.request_id, reason = ev.text, hosts_blocking = ev.hosts_blocking }
  local ok, decision = pcall(hook, request)
  if not ok then
    log("close handler failed, nothing sent for request " .. ev.request_id .. ": " .. tostring(decision))
    return
  end
  if decision == nil then return end
  local valid, acked, code, msg = pcall(self.ack_close, self, ev.request_id, decision)
  if not valid then
    log("close handler returned " .. tostring(decision) .. ", nothing sent: " .. tostring(acked))
  elseif acked then
    ev.acked = true
  else
    ev.ack_error = code
    log("close answer for request " .. ev.request_id .. " failed: " .. tostring(code) .. ": " .. tostring(msg))
  end
end

local function notify(self, ev)
  -- Copy first: a handler may unsubscribe itself.
  local listeners = table.move(self._listeners, 1, #self._listeners, 1, {})
  for _, e in ipairs(listeners) do
    if e.kind == nil or e.kind == ev.kind then
      local ok, err = pcall(e.fn, ev)
      if not ok then log("event handler failed on " .. tostring(ev.name) .. ": " .. tostring(err)) end
    end
  end
end

-- What happens to each event read from the host's queue, in order: update the view of
-- the clients (detaching any Game whose process is gone), resynchronise after the service
-- comes back or events were lost, answer a close request, then call the handlers.
local function dispatch(self, ev)
  local b = surface()
  decorate_event(ev)
  track(self, ev)
  if ev.kind == b.CM_EV_SERVICE_RESTORED or ev.kind == b.CM_EV_EVENTS_DROPPED then
    -- Nothing that happened while events were missing is replayed: ask for the list.
    local list, code = self:clients()
    ev.clients, ev.resync_error = list, code
  elseif ev.kind == b.CM_EV_CLOSE_REQUESTED then
    answer_close(self, ev)
  end
  notify(self, ev)
  return ev
end

local function clamp_ms(ms)
  ms = math.tointeger(ms) or math.floor(tonumber(ms) or 0)
  if ms < 0 then return 0 end
  if ms > Clients.MAX_POLL_MS then return Clients.MAX_POLL_MS end
  return ms
end

-- Read one event, waiting up to timeout_ms (0 by default, at most MAX_POLL_MS). The event
-- goes through the handlers first and is then returned. nil when none came; nil, code,
-- message if the host's connection core has stopped.
function Clients:poll(timeout_ms)
  local ev, code, msg = surface().cm_poll_event(clamp_ms(timeout_ms))
  if not ev then return nil, code, msg end
  return dispatch(self, ev)
end

-- Wait up to timeout_ms for an event, then handle everything queued. Returns how many
-- events were handled, or nil, code, message as :poll() does.
function Clients:pump(timeout_ms)
  local ev, code, msg = self:poll(timeout_ms)
  if code then return nil, code, msg end
  local count = 0
  while ev do
    count = count + 1
    ev, code, msg = self:poll(0)
    if code then return nil, code, msg end
  end
  return count
end

-- Handle events until pred(event) is true, and return that event. Gives up after
-- timeout_s seconds with nil, "timeout". Every event on the way still reaches the handlers.
-- The clock is os.time(): os.clock() counts CPU time, which stops while the script waits.
function Clients:wait_for(pred, timeout_s)
  local deadline = os.time() + (timeout_s or 0)
  repeat
    local ev, code, msg = self:poll(Clients.WAIT_SLICE_MS)
    if code then return nil, code, msg end
    if ev and pred(ev) then return ev end
  until os.time() > deadline
  return nil, "timeout", "no matching event within " .. tostring(timeout_s) .. " s"
end

-- Attaching ------------------------------------------------------------------------------

-- Attach to a game process, at most once. A pid this manager already holds returns the
-- same Game, with no second attach. The Game is detached for you when the service reports
-- its client exited or restarted as a new process; game:is_attached() then says why.
function Clients:attach_pid(pid, client_id)
  local claim = self._claims[pid]
  if claim then return claim.game end
  local ok, game = pcall(Game.attach, pid)
  if not ok then return nil, "attach_failed", tostring(game) end
  self._claims[pid] = { game = game, client_id = client_id }
  game._on_detach = function() self._claims[pid] = nil end
  return game
end

-- The Game this manager holds for a pid, or nil.
function Clients:game_for(pid)
  local claim = self._claims[pid]
  return claim and claim.game
end

-- The pid of a client: from a client_started event when it carried one, otherwise from the
-- service's client list. A client_started sent as the launch is queued has pid 0, because
-- no process exists yet, so in practice a fresh launch's pid comes from the list.
function Clients:pid_of(client_id)
  local k = self._known[client_id]
  if k and k.pid and k.pid ~= 0 then return k.pid end
  local list, code, msg = self:clients()
  if not list then return nil, code, msg end
  k = self._known[client_id]
  if k and k.pid and k.pid ~= 0 then return k.pid end
  return nil, "client_not_found", "no running client " .. tostring(client_id)
end

-- Attach to a launched client by its client_id (see attach_pid).
function Clients:attach(client_id)
  local pid, code, msg = self:pid_of(client_id)
  if not pid then return nil, code, msg end
  return self:attach_pid(pid, client_id)
end

-- Detach this manager's Game for a client, if it has one.
function Clients:detach(client_id)
  for _, claim in pairs(self._claims) do
    if claim.client_id == client_id then claim.game:detach() end
  end
end

-- Launch handle --------------------------------------------------------------------------

-- Wait until the client is injected, then attach to it and return the Game. On failure:
-- nil, code, message, where code is the service's failure code, "exited", "timeout", or
-- what attaching returned.
function Launch:wait_attached(timeout_s)
  local cm, id = self._cm, self.client_id
  local b = surface()
  local function settled()
    local k = cm._known[id] or {}
    return k.state == b.CM_STATE_INJECTED or k.state == b.CM_STATE_FAILED
        or k.state == b.CM_STATE_EXITED
  end
  if not settled() then
    local _, code, msg = cm:wait_for(function(ev) return ev.client_id == id and settled() end, timeout_s)
    if code then return nil, code, msg end
  end
  local k = cm._known[id]
  if k.state == b.CM_STATE_FAILED then return nil, k.failure or "failed", "the launch failed" end
  if k.state == b.CM_STATE_EXITED then return nil, "exited", "the client exited before it was injected" end
  return cm:attach(id)
end

return Clients
