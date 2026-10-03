-- spec/clients_spec.lua -- botwithus.clients against the fake cm_* surface.

local fake_bwu = require("spec.fake_bwu")
local bot      = require("botwithus")
local Clients  = bot.clients

local T = {}

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
  return b, b._cm, Clients.new()
end

-- Surface ----------------------------------------------------------------------------------

T["clients: the surface keeps ABI 2 and adds cm surface 1"] = function(assert_)
  local b = setup()
  assert_(b.ABI_VERSION == 2, "ABI_VERSION stays 2")
  assert_(b.CM_SURFACE_VERSION == 1, "cm surface is version 1")
end

T["clients: new() without the bwu surface raises"] = function(assert_)
  _G.bwu = nil
  local ok, err = pcall(Clients.new)
  assert_(not ok and tostring(err):find("bwu", 1, true), "missing surface raises: " .. tostring(err))
end

T["clients: new() on a host without the cm surface raises"] = function(assert_)
  _G.bwu = fake_bwu.new({ no_cm = true })
  local ok, err = pcall(Clients.new)
  assert_(not ok and tostring(err):find("client-management", 1, true), "no cm surface raises: " .. tostring(err))
end

-- Calls ------------------------------------------------------------------------------------

T["clients: accounts() lists id and name"] = function(assert_)
  local _, _, cm = setup()
  local a = cm:accounts()
  assert_(#a == 2 and a[1].id == "acct-1" and a[2].name == "Alt", "two accounts")
end

T["clients: a call while the service is down returns nil, code, message"] = function(assert_)
  local _, f, cm = setup()
  f.down = "service_unavailable"
  for _, call in ipairs({ function() return cm:accounts() end, function() return cm:clients() end,
                          function() return cm:launch("acct-1") end,
                          function() return cm:stop("c1") end,
                          function() return cm:ack_close(1, "later") end }) do
    local v, code, msg = call()
    assert_(v == nil and code == "service_unavailable" and type(msg) == "string", "fails with the code")
  end
  assert_(#f.launches == 0 and #f.stops == 0 and #f.acks == 0, "nothing was sent")
end

T["clients: the user-stopped code passes through"] = function(assert_)
  local _, f, cm = setup()
  f.down = "service_stopped"
  local v, code = cm:accounts()
  assert_(v == nil and code == "service_stopped", "service_stopped")
end

T["clients: launch returns a handle; character_index defaults to -1"] = function(assert_)
  local _, f, cm = setup()
  local h = cm:launch("acct-1")
  assert_(h and h.client_id == "c1", "handle carries the client id")
  assert_(f.launches[1].account_id == "acct-1" and f.launches[1].character_index == -1, "default -1")
  cm:launch("acct-2", 3)
  assert_(f.launches[2].character_index == 3, "character index passed through")
end

T["clients: a rate-limited launch also returns retry_after_ms"] = function(assert_)
  local _, f, cm = setup()
  f.refuse.launch, f.retry_after_ms = "rate_limited", 12000
  local h, code, msg, retry = cm:launch("acct-1")
  assert_(h == nil and code == "rate_limited" and msg, "refused")
  assert_(retry == 12000, "retry_after_ms is 12000, got " .. tostring(retry))
  f.refuse.launch = "session_limit"
  local _, code2, _, retry2 = cm:launch("acct-1")
  assert_(code2 == "session_limit" and retry2 == -1, "other codes carry -1")
end

T["clients: stop takes graceful, kill or a constant; default graceful"] = function(assert_)
  local b, f, cm = setup()
  assert_(cm:stop("c1") == true, "stop returns true")
  cm:stop("c2", "kill")
  cm:stop("c3", b.CM_STOP_GRACEFUL)
  assert_(f.stops[1].mode == b.CM_STOP_GRACEFUL, "default graceful")
  assert_(f.stops[2].mode == b.CM_STOP_KILL, "kill")
  assert_(f.stops[3].mode == b.CM_STOP_GRACEFUL, "constant")
end

T["clients: an unknown stop mode raises and sends nothing"] = function(assert_)
  local _, f, cm = setup()
  local ok, err = pcall(cm.stop, cm, "c1", "nuke")
  assert_(not ok and tostring(err):find("stop mode", 1, true), "raises: " .. tostring(err))
  assert_(#f.stops == 0, "nothing sent")
end

T["clients: clients() adds names and keeps the raw fields"] = function(assert_)
  local b, f, cm = setup()
  f.clients = { f.client({ client_id = "c1", pid = 900, state = b.CM_STATE_INJECTED, is_agent_stale = true }) }
  local list = cm:clients()
  local c = list[1]
  assert_(c.state == b.CM_STATE_INJECTED and c.state_name == "injected", "state and name")
  assert_(c.kind_name == "jagex" and c.origin_name == "automation" and c.licence_name == "ok", "names")
  assert_(c.is_agent_stale == true, "is_agent_stale stays a boolean")
end

-- Events -----------------------------------------------------------------------------------

T["clients: poll returns nil when nothing is queued"] = function(assert_)
  local _, f, cm = setup()
  assert_(cm:poll(0) == nil, "nil on timeout")
  assert_(f.polls[1] == 0, "polled with 0")
end

T["clients: poll clamps its wait to 0..MAX_POLL_MS"] = function(assert_)
  local _, f, cm = setup()
  cm:poll(60000); cm:poll(-5); cm:poll()
  assert_(f.polls[1] == Clients.MAX_POLL_MS, "long wait clamped, got " .. tostring(f.polls[1]))
  assert_(f.polls[2] == 0 and f.polls[3] == 0, "negative and default are 0")
end

T["clients: events get a name and keep their fields"] = function(assert_)
  local b, f, cm = setup()
  f.push({ kind = b.CM_EV_CLIENT_EXITED, client_id = "c1", state = b.CM_STATE_EXITED,
           exit_code = 7, reason = b.CM_EXIT_STOPPED })
  local ev = cm:poll(0)
  assert_(ev.name == "client_exited" and ev.state_name == "exited", "names")
  assert_(ev.reason_name == "stopped" and ev.exit_code == 7, "exit fields")
  f.push({ kind = b.CM_EV_LICENCE_STATE, client_id = "c1", state = b.CM_LIC_RETRYING, text = "live" })
  ev = cm:poll(0)
  assert_(ev.state_name == "retrying", "licence state is named from the licence table")
end

T["clients: pump waits once, then drains with 0"] = function(assert_)
  local b, f, cm = setup()
  for _ = 1, 3 do f.push({ kind = b.CM_EV_AGENT_UPDATED, text = "abc" }) end
  assert_(cm:pump(50) == 3, "three handled")
  assert_(f.polls[1] == 50, "first poll waits")
  for i = 2, #f.polls do assert_(f.polls[i] == 0, "the rest drain with 0") end
  assert_(cm:pump(0) == 0, "nothing left")
end

T["clients: on(kind) filters and the returned function unsubscribes"] = function(assert_)
  local b, f, cm = setup()
  local exited, all = 0, 0
  local off = cm:on("client_exited", function() exited = exited + 1 end)
  cm:on_event(function() all = all + 1 end)
  f.push({ kind = b.CM_EV_CLIENT_EXITED, client_id = "c1" })
  f.push({ kind = b.CM_EV_AGENT_UPDATED })
  cm:pump(0)
  assert_(exited == 1 and all == 2, "filtered and unfiltered")
  off()
  f.push({ kind = b.CM_EV_CLIENT_EXITED, client_id = "c2" })
  cm:pump(0)
  assert_(exited == 1 and all == 3, "unsubscribed")
end

T["clients: a handler that raises is logged and the pump goes on"] = function(assert_)
  local b, f, cm = setup()
  local seen = 0
  cm:on_event(function() error("boom") end)
  cm:on_event(function() seen = seen + 1 end)
  f.push({ kind = b.CM_EV_AGENT_UPDATED })
  f.push({ kind = b.CM_EV_AGENT_UPDATED })
  local lines = capture_stderr(function() assert_(cm:pump(0) == 2, "both handled") end)
  assert_(seen == 2, "the next handler still runs")
  assert_(#lines == 2 and lines[1]:find("boom", 1, true), "one line per failure")
end

T["clients: wait_for returns the matching event and dispatches the rest"] = function(assert_)
  local b, f, cm = setup()
  local others = 0
  cm:on("agent_updated", function() others = others + 1 end)
  f.push({ kind = b.CM_EV_AGENT_UPDATED })
  f.push({ kind = b.CM_EV_CLIENT_STATE, client_id = "c1", state = b.CM_STATE_INJECTED })
  local ev = cm:wait_for(function(e) return e.kind == b.CM_EV_CLIENT_STATE end, 5)
  assert_(ev and ev.state == b.CM_STATE_INJECTED, "matched")
  assert_(others == 1, "the event before it reached its handler")
  assert_(f.polls[1] == Clients.WAIT_SLICE_MS, "waits in slices")
end

T["clients: wait_for times out with nil, timeout"] = function(assert_)
  local _, _, cm = setup()
  local ev, code = cm:wait_for(function() return true end, 0)
  assert_(ev == nil and code == "timeout", "timeout")
end

T["clients: wait_for returns a poll failure at once"] = function(assert_)
  local b, _, cm = setup()
  b.cm_poll_event = function() return nil, "service_unavailable", "core stopped" end
  local ev, code = cm:wait_for(function() return true end, 60)
  assert_(ev == nil and code == "service_unavailable", "failure passed through")
end

-- Close requests ---------------------------------------------------------------------------

local function close_event(f, b, id)
  f.push({ kind = b.CM_EV_CLOSE_REQUESTED, request_id = id, hosts_blocking = 2, text = "data_update" })
end

T["close: with no handler nothing is acked and the script carries on"] = function(assert_)
  local b, f, cm = setup()
  close_event(f, b, 4)
  local ev
  local lines = capture_stderr(function() ev = cm:poll(0) end)
  assert_(ev and ev.name == "close_requested" and ev.request_id == 4, "the event is still delivered")
  assert_(#f.acks == 0, "no ack sent")
  assert_(ev.acked == nil, "not acked")
  assert_(#lines == 0, "nothing printed: the host already printed its one line")
  assert_(cm:poll(0) == nil, "and the script just keeps polling")
end

T["close: a handler's decision is sent"] = function(assert_)
  local b, f, cm = setup()
  local got
  cm:on_close_requested(function(request) got = request; return "later" end)
  close_event(f, b, 9)
  local ev = cm:poll(0)
  assert_(got.request_id == 9 and got.reason == "data_update" and got.hosts_blocking == 2, "request fields")
  assert_(#f.acks == 1 and f.acks[1].request_id == 9 and f.acks[1].decision == b.CM_ACK_LATER, "ack sent")
  assert_(ev.acked == true, "marked acked")
end

T["close: each decision maps to its constant"] = function(assert_)
  local b, f, cm = setup()
  local answers = { "closing", "declined", b.CM_ACK_LATER }
  local i = 0
  cm:on_close_requested(function() i = i + 1; return answers[i] end)
  for id = 1, 3 do close_event(f, b, id) end
  cm:pump(0)
  assert_(f.acks[1].decision == b.CM_ACK_CLOSING, "closing")
  assert_(f.acks[2].decision == b.CM_ACK_DECLINED, "declined")
  assert_(f.acks[3].decision == b.CM_ACK_LATER, "constant")
end

T["close: a handler returning nil sends nothing; it may ack later"] = function(assert_)
  local b, f, cm = setup()
  local pending
  cm:on_close_requested(function(request) pending = request.request_id end)
  close_event(f, b, 5)
  cm:poll(0)
  assert_(#f.acks == 0, "nothing sent yet")
  assert_(cm:ack_close(pending, "closing") == true, "acked later")
  assert_(f.acks[1].request_id == 5 and f.acks[1].decision == b.CM_ACK_CLOSING, "the later ack")
end

T["close: a handler that raises sends nothing, logs one line, and the pump goes on"] = function(assert_)
  local b, f, cm = setup()
  local after = 0
  cm:on_close_requested(function() error("handler bug") end)
  cm:on("agent_updated", function() after = after + 1 end)
  close_event(f, b, 6)
  f.push({ kind = b.CM_EV_AGENT_UPDATED })
  local lines = capture_stderr(function() assert_(cm:pump(0) == 2, "both events handled") end)
  assert_(#f.acks == 0, "no ack")
  assert_(#lines == 1 and lines[1]:find("handler bug", 1, true), "one stderr line: " .. tostring(lines[1]))
  assert_(after == 1, "the next event was still handled")
end

T["close: a handler returning a bad decision sends nothing"] = function(assert_)
  local b, f, cm = setup()
  cm:on_close_requested(function() return "maybe" end)
  close_event(f, b, 7)
  local lines = capture_stderr(function() cm:poll(0) end)
  assert_(#f.acks == 0, "no ack")
  assert_(#lines == 1, "one stderr line")
end

T["close: an ack the service could not take is reported on the event"] = function(assert_)
  local b, f, cm = setup()
  cm:on_close_requested(function() return "later" end)
  f.refuse.ack_close = "service_unavailable"
  close_event(f, b, 8)
  local ev
  capture_stderr(function() ev = cm:poll(0) end)
  assert_(ev.acked == nil and ev.ack_error == "service_unavailable", "ack_error set")
end

T["close: removing the handler stops answering"] = function(assert_)
  local b, f, cm = setup()
  cm:on_close_requested(function() return "later" end)
  cm:on_close_requested(nil)
  close_event(f, b, 3)
  cm:poll(0)
  assert_(#f.acks == 0, "no ack once removed")
end

T["close: ack_close rejects a bad request id or decision before sending"] = function(assert_)
  local _, f, cm = setup()
  assert_(not pcall(cm.ack_close, cm, 0, "later"), "id 0")
  assert_(not pcall(cm.ack_close, cm, 1.5, "later"), "non-integer id")
  assert_(not pcall(cm.ack_close, cm, 1, "whenever"), "unknown decision")
  assert_(#f.acks == 0, "nothing sent")
end

-- Resync -----------------------------------------------------------------------------------

T["resync: service_restored asks for the client list"] = function(assert_)
  local b, f, cm = setup()
  f.clients = { f.client({ client_id = "c1", pid = 900, state = b.CM_STATE_INJECTED }) }
  f.push({ kind = b.CM_EV_SERVICE_LOST, text = "service_unavailable" })
  local lost = cm:poll(0)
  assert_(lost.name == "service_lost" and f.clients_calls == 0, "no resync on loss")
  f.push({ kind = b.CM_EV_SERVICE_RESTORED })
  local seen
  cm:on("service_restored", function(ev) seen = ev end)
  local ev = cm:poll(0)
  assert_(f.clients_calls == 1, "one cm_clients call")
  assert_(ev.clients and ev.clients[1].client_id == "c1", "the fresh list is on the event")
  assert_(seen == ev and seen.clients, "handlers see the list already")
end

T["resync: a failed resync is reported, not raised"] = function(assert_)
  local b, f, cm = setup()
  f.refuse.clients = "service_unavailable"
  f.push({ kind = b.CM_EV_SERVICE_RESTORED })
  local ev = cm:poll(0)
  assert_(ev.clients == nil and ev.resync_error == "service_unavailable", "resync_error")
end

T["resync: events_dropped resyncs too"] = function(assert_)
  local b, f, cm = setup()
  f.push({ kind = b.CM_EV_EVENTS_DROPPED, text = "12" })
  local ev = cm:poll(0)
  assert_(f.clients_calls == 1 and ev.clients, "resynced")
end

-- Launch, attach, detach -------------------------------------------------------------------

local function launch_events(f, b, id, pid)
  f.push({ kind = b.CM_EV_CLIENT_STARTED, client_id = id, pid = pid, state = b.CM_STATE_SPAWNING, text = "acct-1" })
  f.push({ kind = b.CM_EV_CLIENT_STATE, client_id = id, state = b.CM_STATE_INJECTING })
  f.push({ kind = b.CM_EV_CLIENT_STATE, client_id = id, state = b.CM_STATE_INJECTED })
end

T["attach: wait_attached attaches once the client is injected"] = function(assert_)
  local b, f, cm = setup()
  local h = cm:launch("acct-1")
  launch_events(f, b, h.client_id, 777)
  local game = h:wait_attached(10)
  assert_(game and game:pid() == 777, "attached to the started pid")
  assert_(#b._state.attaches == 1 and b._state.attaches[1] == 777, "one attach")
  assert_(f.clients_calls == 0, "pid came from client_started, no extra call")
end

T["attach: wait_attached works when the events were already handled"] = function(assert_)
  local b, f, cm = setup()
  local h = cm:launch("acct-1")
  launch_events(f, b, h.client_id, 778)
  cm:pump(0)
  local game = h:wait_attached(10)
  assert_(game and game:pid() == 778, "attached from what the manager already saw")
end

T["attach: the pid comes from the service when client_started was missed"] = function(assert_)
  local b, f, cm = setup()
  local h = cm:launch("acct-1")
  f.clients = { f.client({ client_id = h.client_id, pid = 779, state = b.CM_STATE_INJECTED }) }
  f.push({ kind = b.CM_EV_CLIENT_STATE, client_id = h.client_id, state = b.CM_STATE_INJECTED })
  local game = h:wait_attached(10)
  assert_(game and game:pid() == 779 and f.clients_calls == 1, "looked up through cm_clients")
end

T["attach: client_started sent at queue time with pid 0 still attaches"] = function(assert_)
  local b, f, cm = setup()
  local h = cm:launch("acct-1")
  -- What the service sends for a fresh launch: started while queued, before any process.
  f.push({ kind = b.CM_EV_CLIENT_STARTED, client_id = h.client_id, pid = 0, state = b.CM_STATE_QUEUED })
  f.push({ kind = b.CM_EV_CLIENT_STATE, client_id = h.client_id, state = b.CM_STATE_INJECTED })
  f.clients = { f.client({ client_id = h.client_id, pid = 781, state = b.CM_STATE_INJECTED }) }
  local game = h:wait_attached(10)
  assert_(game and game:pid() == 781, "pid from the service list, not 0")
  assert_(#b._state.attaches == 1 and b._state.attaches[1] == 781, "never attached pid 0")
end

T["attach: a failed launch returns its failure code"] = function(assert_)
  local b, f, cm = setup()
  local h = cm:launch("acct-1")
  f.push({ kind = b.CM_EV_CLIENT_STATE, client_id = h.client_id, state = b.CM_STATE_FAILED, text = "inject_failed" })
  local game, code = h:wait_attached(10)
  assert_(game == nil and code == "inject_failed", "failure code: " .. tostring(code))
  assert_(#b._state.attaches == 0, "no attach")
end

T["attach: a client that exits first returns exited"] = function(assert_)
  local b, f, cm = setup()
  local h = cm:launch("acct-1")
  f.push({ kind = b.CM_EV_CLIENT_EXITED, client_id = h.client_id, state = b.CM_STATE_EXITED })
  local game, code = h:wait_attached(10)
  assert_(game == nil and code == "exited", "exited")
end

T["attach: wait_attached times out"] = function(assert_)
  local _, _, cm = setup()
  local h = cm:launch("acct-1")
  local game, code = h:wait_attached(0)
  assert_(game == nil and code == "timeout", "timeout")
end

T["attach: other clients' events do not settle a launch"] = function(assert_)
  local b, f, cm = setup()
  local h = cm:launch("acct-1")
  f.push({ kind = b.CM_EV_CLIENT_STATE, client_id = "c99", state = b.CM_STATE_INJECTED })
  local game, code = h:wait_attached(0)
  assert_(game == nil and code == "timeout", "c99 did not count")
end

T["attach: the same pid is never attached twice"] = function(assert_)
  local b, f, cm = setup()
  f.clients = { f.client({ client_id = "c1", pid = 800, state = b.CM_STATE_INJECTED }) }
  local g1 = cm:attach("c1")
  local g2 = cm:attach("c1")
  local g3 = cm:attach_pid(800)
  assert_(g1 == g2 and g2 == g3, "the same Game every time")
  assert_(#b._state.attaches == 1, "one native attach, got " .. #b._state.attaches)
end

T["attach: a failed attach returns nil, attach_failed"] = function(assert_)
  local b, _, cm = setup()
  b._state.attach_error = "no snapshot mapping"
  local game, code, msg = cm:attach_pid(801)
  assert_(game == nil and code == "attach_failed" and msg:find("no snapshot mapping", 1, true), "attach_failed")
  b._state.attach_error = nil
  assert_(cm:attach_pid(801), "a later attach is allowed")
end

T["attach: an unknown client returns client_not_found"] = function(assert_)
  local _, _, cm = setup()
  local game, code = cm:attach("c42")
  assert_(game == nil and code == "client_not_found", "client_not_found")
end

T["attach: game:detach() frees the pid for a new attach"] = function(assert_)
  local b, _, cm = setup()
  local g1 = cm:attach_pid(802)
  g1:detach()
  local g2 = cm:attach_pid(802)
  assert_(g2 ~= g1 and #b._state.attaches == 2, "attached again after detach")
  assert_(#b._state.detaches == 1, "one native detach")
end

T["attach: a held Game outlives its client"] = function(assert_)
  local b, f, cm = setup()
  local h = cm:launch("acct-1")
  launch_events(f, b, h.client_id, 803)
  local game = h:wait_attached(10)
  f.push({ kind = b.CM_EV_CLIENT_EXITED, client_id = h.client_id, state = b.CM_STATE_EXITED,
           reason = b.CM_EXIT_STOPPED })
  cm:pump(0)
  local attached, why = game:is_attached()
  assert_(attached == false and why == Clients.DETACHED_EXITED, "detached because it exited")
  local ok, code, reason = game:refresh()
  assert_(ok == false and code == "detached" and reason == Clients.DETACHED_EXITED, "refresh says detached")
  local read_ok, err = pcall(game.self, game)
  assert_(not read_ok and tostring(err):find("game is detached", 1, true), "a read raises clearly: " .. tostring(err))
  assert_(#b._state.detaches == 1 and b._state.detaches[1] == 803, "native detach once")
  game:detach()
  assert_(#b._state.detaches == 1, "a second detach is a no-op")
  local again = cm:attach_pid(803)
  assert_(again ~= game, "the claim was released")
end

T["attach: a restart to a new pid detaches the old Game"] = function(assert_)
  local b, f, cm = setup()
  local h = cm:launch("acct-1")
  launch_events(f, b, h.client_id, 804)
  local game = h:wait_attached(10)
  f.push({ kind = b.CM_EV_CLIENT_STARTED, client_id = h.client_id, pid = 805, state = b.CM_STATE_SPAWNING })
  cm:pump(0)
  local attached, why = game:is_attached()
  assert_(not attached and why == Clients.DETACHED_RESTARTED, "detached as restarted")
  assert_(cm:pid_of(h.client_id) == 805, "the new pid is known")
end

T["attach: a resync detaches a client that went away while the service was down"] = function(assert_)
  local b, f, cm = setup()
  f.clients = { f.client({ client_id = "c1", pid = 806, state = b.CM_STATE_INJECTED }) }
  local game = cm:attach("c1")
  f.clients = {}
  f.push({ kind = b.CM_EV_SERVICE_RESTORED })
  cm:poll(0)
  assert_(not game:is_attached(), "detached after the resync")
end

T["attach: a resync keeps a client that is still there"] = function(assert_)
  local b, f, cm = setup()
  f.clients = { f.client({ client_id = "c1", pid = 807, state = b.CM_STATE_INJECTED }) }
  local game = cm:attach("c1")
  f.push({ kind = b.CM_EV_SERVICE_RESTORED })
  cm:poll(0)
  assert_(game:is_attached(), "still attached")
end

T["attach: cm:detach(client_id) detaches that client's Game"] = function(assert_)
  local b, f, cm = setup()
  f.clients = { f.client({ client_id = "c1", pid = 808, state = b.CM_STATE_INJECTED }) }
  local game = cm:attach("c1")
  cm:detach("c1")
  assert_(not game:is_attached(), "detached")
end

-- Script.run -------------------------------------------------------------------------------

local function counting_script(n)
  local s = { manifest = { name = "t" }, loops = 0, stopped = false }
  s.on_loop = function() s.loops = s.loops + 1; return (s.loops < n) and 1 or -1 end
  s.on_stop = function() s.stopped = true end
  return s
end

T["run: without clients the wait does not touch the event queue"] = function(assert_)
  local b, f = setup()
  close_event(f, b, 1)
  capture_stderr(function() bot.run(counting_script(3), {}) end)
  assert_(#f.polls == 0, "no cm poll")
  assert_(#f.events == 1, "the queued event is left for whoever asks")
end

T["run: with clients the wait is the event poll and handlers fire while asleep"] = function(assert_)
  local b, f, cm = setup()
  local acked
  cm:on_close_requested(function(r) acked = r.request_id; return "later" end)
  close_event(f, b, 11)
  capture_stderr(function() bot.run(counting_script(3), { clients = cm, pid = 4242 }) end)
  assert_(#f.polls > 0 and f.polls[1] == 15, "slept on cm_poll_event(15)")
  assert_(acked == 11 and f.acks[1].request_id == 11, "the close handler answered during sleep")
end

T["run: with clients the pid is attached through the claims"] = function(assert_)
  local b, _, cm = setup()
  local held = cm:attach_pid(4242)
  capture_stderr(function() bot.run(counting_script(2), { clients = cm, pid = 4242 }) end)
  assert_(#b._state.attaches == 1, "no second attach of 4242")
  assert_(held:is_attached(), "a Game the script already held is left attached")
  capture_stderr(function() bot.run(counting_script(2), { clients = cm, pid = 4243 }) end)
  assert_(cm:game_for(4243) == nil, "a Game the runner attached itself is detached at the end")
end

T["run: a Game passed in is not detached by the runner"] = function(assert_)
  local _, _, cm = setup()
  local game = cm:attach_pid(4242)
  capture_stderr(function() bot.run(counting_script(2), { game = game }) end)
  assert_(game:is_attached(), "caller keeps its Game")
end

T["run: the loop ends and on_stop runs when the client exits mid-run"] = function(assert_)
  local b, f, cm = setup()
  local h = cm:launch("acct-1")
  launch_events(f, b, h.client_id, 809)
  assert_(h:wait_attached(10), "attached")
  f.on_poll = function(q)
    q.on_poll = nil
    q.push({ kind = b.CM_EV_CLIENT_EXITED, client_id = h.client_id, state = b.CM_STATE_EXITED })
  end
  local s = counting_script(1000)
  capture_stderr(function() bot.run(s, { clients = cm, client_id = h.client_id }) end)
  assert_(s.loops < 1000 and s.stopped, "stopped after " .. s.loops .. " loops, on_stop ran")
end

return T
