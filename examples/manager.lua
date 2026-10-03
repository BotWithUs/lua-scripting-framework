-- examples/manager.lua -- a management script: launch a client, attach, stop it.
--
-- Run under the native host:  scripts\run_example.ps1 examples\manager.lua
-- Needs the BotWithUs launcher's background service running and signed in.
--
--   BWU_ACCOUNT   the account id to launch (default: the first account the service lists)
--   BWU_STOP      "graceful" (default) or "kill"
--
-- The script waits for the client to be injected, attaches to it through the manager (so
-- the same process is never attached twice), reads one snapshot, then stops the client and
-- waits for it to exit. It answers a data-update close request with "later" meanwhile.

local bot = require("botwithus")

local cm = bot.clients.new()

-- Without this handler the script would simply not answer, which is fine too: the host
-- never closes by itself.
cm:on_close_requested(function(request)
  print(("manager: data update waiting (request %d, %d host(s) open); answering later")
    :format(request.request_id, request.hosts_blocking))
  return "later"
end)

cm:on("service_lost", function(ev) print("manager: lost the service (" .. ev.text .. ")") end)
cm:on("service_restored", function(ev)
  -- The manager has already asked for the client list again; nothing missed is replayed.
  print(("manager: service back, %s client(s)"):format(ev.clients and #ev.clients or "?"))
end)
cm:on("client_state", function(ev)
  print(("manager: %s is %s %s"):format(ev.client_id, ev.state_name or "?", ev.text))
end)

local function fail(what, code, msg)
  error(("manager: %s failed: %s: %s"):format(what, tostring(code), tostring(msg)), 0)
end

local accounts, code, msg = cm:accounts()
if not accounts then fail("accounts", code, msg) end
local account = os.getenv("BWU_ACCOUNT") or (accounts[1] and accounts[1].id)
if not account then error("manager: the service lists no accounts", 0) end

local launch, retry
while true do
  launch, code, msg, retry = cm:launch(account)
  if launch then break end
  if code ~= "rate_limited" then fail("launch", code, msg) end
  print(("manager: rate limited, retrying in %d ms"):format(retry))
  local wait_until = os.time() + math.ceil(retry / 1000)
  while os.time() < wait_until do cm:pump(bot.clients.WAIT_SLICE_MS) end
end
print("manager: launched " .. launch.client_id)

local game
game, code, msg = launch:wait_attached(300)
if not game then fail("attach", code, msg) end
game:refresh()
print(("manager: attached to pid %d, server tick %d"):format(game:pid(), game:server_tick()))

local mode = os.getenv("BWU_STOP") or "graceful"
local ok
ok, code, msg = cm:stop(launch.client_id, mode)
if not ok then fail("stop", code, msg) end

local exited = cm:wait_for(function(ev)
  return ev.name == "client_exited" and ev.client_id == launch.client_id
end, 120)
print(("manager: %s %s; game attached: %s"):format(launch.client_id,
  exited and ("exited (" .. tostring(exited.reason_name) .. ")") or "did not exit in time",
  tostring(game:is_attached())))
