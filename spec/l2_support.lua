-- spec/l2_support.lua -- shared fixtures for the J1-J3 port specs (l2_*_spec.lua).

local fake_bwu = require("spec.fake_bwu")
local bot = require("botwithus")
local Defs = require("botwithus.definitions")

local S = {}

local VARP_SET, VARP_DEFAULT = 2, 1

-- A var_reads function: `varps` / `varbits` map id -> value (set); any other id reads as its
-- default 0. Every read is also counted in reads[fn].
function S.vars(varps, varbits, reads)
  return function(fn, ids)
    local source = fn == "read_varps" and (varps or {}) or (varbits or {})
    if reads then reads[fn] = (reads[fn] or 0) + 1 end
    local out = {}
    for i, id in ipairs(ids) do
      local v = source[id]
      if v == nil then out[i] = fake_bwu.var_record(id, VARP_DEFAULT, 0)
      else out[i] = fake_bwu.var_record(id, VARP_SET, v) end
    end
    return out
  end
end

-- Attach a Game over a fresh fake surface built from `opts`.
function S.attach(opts)
  _G.bwu = fake_bwu.new(opts)
  Defs.clear_item_names()
  return bot.Game.attach(4242)
end

-- The actions queued so far.
function S.actions() return bwu._state.actions end

-- An item definition in the cache_item shape.
function S.item(id, name, extra)
  local d = { id = id, name = name, members = false, stackable = false, noted = false,
              noted_id = -1, category = 0, shop_price = 1, ge_buy_limit = 0, exchangeable = true,
              wearpos = -1, wearpos2 = -1, wearpos3 = -1, param_count = 0, text_truncated = 0,
              inventory_ops = { "", "", "", "", "" }, ground_ops = { "", "", "Take", "", "" } }
  for k, v in pairs(extra or {}) do d[k] = v end
  return d
end

-- The rpc handler for get_component_ops from a table "iface:comp:sub" -> { {op, name}, ... }
-- (mask: every listed op transmits).
function S.ops_handler(ops_by_key)
  return function(p)
    local ops = ops_by_key[p.iface .. ":" .. p.comp .. ":" .. p.sub]
    if ops == nil then return nil, "get_component_ops: not_found" end
    local mask, list = 0, {}
    for i, o in ipairs(ops) do
      list[i] = { op = o[1], name = o[2], transmits = o[3] ~= false }
      if o[3] ~= false then mask = mask | (1 << o[1]) end
    end
    return { mask = mask, ops = list }
  end
end

-- Whether calling fn raises an error whose text contains `fragment`.
function S.raises(fn, fragment)
  local ok, err = pcall(fn)
  return not ok and tostring(err):find(fragment, 1, true) ~= nil, tostring(err)
end

-- A fake clock / sleep pair for the wait engine: sleep advances the clock and runs `on_sleep`.
function S.clock(on_sleep)
  local c = { t = 0, sleeps = 0 }
  c.now = function() return c.t end
  c.sleep = function(ms)
    c.t = c.t + ms
    c.sleeps = c.sleeps + 1
    if on_sleep then on_sleep(c) end
    return true
  end
  return c
end

return S
