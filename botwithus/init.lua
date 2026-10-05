-- botwithus -- the umbrella module for the Lua scripting API.
--
--   local bot = require("botwithus")
--   bot.run({ manifest = {...}, on_start = ..., on_loop = ..., on_stop = ... })
--   local cm = bot.clients.new()   -- launch, stop and watch clients
--
-- This is the open, author-facing API. It sits entirely on the native `bwu` table
-- that native-scripting-host installs; it contains no wire code of its own. Requires
-- Lua 5.4 and the bwu_host runtime (or a fake `bwu` for tests).

local M = {}

M.VERSION  = "0.1.0"
M.Tile     = require("botwithus.tile")
M.Actions  = require("botwithus.actions")
M.Game     = require("botwithus.game")
M.Entities = require("botwithus.entities")
M.Input    = require("botwithus.input")

-- Client management for a management script: bot.clients.new() (see botwithus/clients.lua).
M.clients  = require("botwithus.clients")
M.Variables = require("botwithus.variables")

local Script = require("botwithus.script")
M.run = Script.run

-- Sugar: bot.npcs(game) / bot.players(game) / bot.objects(game) -> a fluent query.
M.npcs    = M.Entities.npcs
M.players = M.Entities.players
M.objects = M.Entities.objects

-- The protocol version the native surface speaks (nil if the surface isn't present).
function M.protocol_version()
  local b = rawget(_G, "bwu")
  return b and b.PROTOCOL_VERSION or nil
end

return M
