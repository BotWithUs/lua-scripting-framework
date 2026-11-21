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

M.VERSION  = "1.1.0"
M.Tile     = require("botwithus.tile")
M.Actions  = require("botwithus.actions")
M.Game     = require("botwithus.game")
M.Entities = require("botwithus.entities")
M.Input    = require("botwithus.input")
-- Agent event decoding (Game:poll_events): see botwithus/events.lua.
M.Events   = require("botwithus.events")

-- Client management for a management script: bot.clients.new() (see botwithus/clients.lua).
M.clients  = require("botwithus.clients")
M.Variables = require("botwithus.variables")
-- Walk progress constants and helpers (Game:walk_ex / :walk_start ...): see botwithus/walk.lua.
M.walk     = require("botwithus.walk")
-- Host ABI 5 reads: inventory views (game:backpack() ...), skill names (game:skill("mining")),
-- and component reads (game:component(...)). See each module.
M.Inventory  = require("botwithus.inventory")
M.Skills     = require("botwithus.skills")
M.Components = require("botwithus.components")
-- Host ABI 6: GE offers, the world list and hop, use-on (target mode). See each module.
M.GrandExchange = require("botwithus.grand_exchange")
M.Worlds     = require("botwithus.worlds")
M.Target     = require("botwithus.target")
-- Host ABI 7: cache definitions (items, NPCs, locs, the JSON long tail) and world map elements.
M.Definitions = require("botwithus.definitions")
M.WorldMap   = require("botwithus.worldmap")

-- The composition APIs ported from the Java host (J1-J3). See each module.
M.Coordinate = M.Tile                              -- the Java host's world.Coordinate
M.Area       = require("botwithus.area")
M.Timing     = require("botwithus.timing")         -- condition waits, the run's pause
M.Timers     = require("botwithus.timers")         -- Stopwatch, Timer, Durations
M.Xp         = require("botwithus.xp")             -- skill names, XpTable, XpTracker
M.Match      = require("botwithus.match")          -- item matchers by exact name / pattern / category
M.Interact   = require("botwithus.interact")       -- NPC / object / ground item options and clicks
M.Bank       = require("botwithus.bank")
M.DepositBox = require("botwithus.deposit_box")
M.Loot       = require("botwithus.loot")
M.ActionBar  = require("botwithus.actionbar")
M.Prayers    = require("botwithus.prayers")
M.Combat     = require("botwithus.combat")         -- local combat state, hitmark history
M.Changes    = require("botwithus.changes")        -- inventory / skill changes per server tick
M.Summoning  = require("botwithus.summoning")
M.Lodestones = require("botwithus.lodestones")
M.ComponentQuery = require("botwithus.component_query")
M.Dialog     = require("botwithus.dialog")
M.Quests     = require("botwithus.quests")
M.Buffs      = require("botwithus.buffs")
M.Hud        = require("botwithus.hud")
M.Settings   = require("botwithus.settings")
M.Json       = require("botwithus.json")

-- Plugin UI: native game components shaped like Jagex's `ui.*` (see botwithus/game_ui.lua).
-- Reached per Game: `local ui = game:ui()` (or ctx.ui in bot.run), then ui.Canvas.new(...).
M.GameUi   = require("botwithus.game_ui")

-- Sugar: bot.ui(game) -> that Game's ui namespace.
function M.ui(game) return game:ui() end

local Script = require("botwithus.script")
M.run = Script.run

-- True once the GUI asked this run to stop (always false on the command line). For a
-- self-running script, which has no ctx: check it in your own loops and finish up.
M.stopping = require("botwithus.ctl").stopping

-- Sugar: bot.npcs(game) / bot.players(game) / bot.objects(game) / bot.hint_arrows(game)
-- -> a fluent query.
M.npcs    = M.Entities.npcs
M.players = M.Entities.players
M.objects = M.Entities.objects
M.hint_arrows = M.Entities.hint_arrows
M.ground_items = M.Entities.ground_items

-- The agent protocol this framework is written for; Game.attach refuses any other.
M.PROTOCOL_VERSION = M.Game.PROTOCOL_VERSION

-- The protocol version the native surface speaks (nil if the surface isn't present).
function M.protocol_version()
  local b = rawget(_G, "bwu")
  return b and b.PROTOCOL_VERSION or nil
end

return M
