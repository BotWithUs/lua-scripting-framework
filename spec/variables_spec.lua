-- spec/variables_spec.lua -- varp / varbit reads over bwu.read_varps / read_varbits.
--
-- The native host does the composition (agent state + cache default) and is tested there;
-- these pin what the Lua layer adds: naming by the surface's own constants, the Game
-- conveniences, and the error paths.

local fake_bwu = require("spec.fake_bwu")
local bot      = require("botwithus")
local V        = require("botwithus.variables")

local rec = fake_bwu.var_record
local SET, DEFAULT, NO_SUCH, UNAVAILABLE = 2, 1, 3, 0
local INT, LONG = 0, 1

local T = {}

local function canned(by_id)
  return function(_, ids)
    local out = {}
    for i, id in ipairs(ids) do out[i] = by_id[id] end
    return out
  end
end

local function game(opts)
  _G.bwu = fake_bwu.new(opts)
  return bot.Game.attach()
end

T["every state is named"] = function(assert_)
  local g = game({ var_reads = canned({
    [13537] = rec(13537, SET, 2350, { kind = INT }),
    [193]   = rec(193, DEFAULT, -1),
    [20000] = rec(20000, NO_SUCH, -1),
    [-5]    = rec(-5, UNAVAILABLE, -1),
    [7]     = rec(7, DEFAULT, 0, { verified = false }),
  }) })
  local r = g:read_varps({ 13537, 193, 20000, -5, 7 })
  assert_(r[1].state == V.SET and r[1].value == 2350 and r[1].kind == "int", "13537 set")
  assert_(r[2].state == V.DEFAULT and r[2].value == -1 and r[2].default_verified, "193 default -1")
  assert_(r[3].state == V.NO_SUCH_VARP and r[3].value == V.NO_VALUE, "20000 no such varp")
  assert_(r[4].state == V.UNAVAILABLE, "-5 unavailable")
  assert_(r[5].state == V.DEFAULT and r[5].value == 0 and r[5].default_verified == false, "unverified default")
  assert_(r[1].is_set and not r[2].is_set, "is_set only for set")
  assert_(r[2].has_value and r[5].has_value and not r[3].has_value and not r[4].has_value, "has_value")
  assert_(V.SET == "set" and V.DEFAULT == "default_not_set_clientside", "state strings")
end

T["a stored -1 is still set"] = function(assert_)
  local g = game({ var_reads = canned({ [4] = rec(4, SET, -1, { kind = INT }) }) })
  assert_(g:varp_state(4) == "set", "state is set")
  assert_(g:varp(4) == -1, "value is -1")
end

T["a LONG varp keeps all 64 bits"] = function(assert_)
  local whole = 0x123456789ABCDEF0
  local low = whole & 0xFFFFFFFF
  if low >= 0x80000000 then low = low - 0x100000000 end
  local g = game({ var_reads = canned({ [12921] = rec(12921, SET, low, { value64 = whole, kind = LONG }) }) })
  local r = g:read_varp(12921)
  assert_(r.kind == "long", "kind long")
  assert_(g:varp_long(12921) == whole, "varp_long is the whole value")
  assert_(g:varp(12921) == low, "varp is the low 32 bits")
end

T["varp / varps return what the game reads"] = function(assert_)
  local g = game({ var_reads = canned({ [1] = rec(1, SET, 5), [2] = rec(2, DEFAULT, -1),
                                        [3] = rec(3, UNAVAILABLE, -1) }) })
  assert_(g:varp(2) == -1, "the cache default, not the agent's 0")
  local v = g:varps({ 1, 2, 3 })
  assert_(v[1] == 5 and v[2] == -1 and v[3] == -1 and #v == 3, "varps in order")
end

T["varbits decode, without a kind"] = function(assert_)
  local g = game({ var_reads = canned({ [10] = rec(10, DEFAULT, 15), [11] = rec(11, SET, 3),
                                        [12] = rec(12, NO_SUCH, -1) }) })
  local r = g:read_varbits({ 10, 11, 12 })
  assert_(r[1].state == V.DEFAULT and r[1].value == 15, "decoded from the default")
  assert_(r[2].state == V.SET and r[2].value == 3, "set base")
  assert_(r[3].state == V.NO_SUCH_VARP, "no such varbit")
  assert_(r[1].kind == nil and r[1].value64 == nil, "varbits carry no kind / value64")
  assert_(g:varbit(11) == 3, "varbit()")
  assert_(bwu._state.var_calls[1].fn == "read_varbits", "went through read_varbits")
end

T["states are named through the surface's constants, not by number"] = function(assert_)
  local g = game({ var_reads = function(_, _)
    return { rec(1, 7, 4, { kind = 21 }), rec(2, 8, 0), rec(3, 2, 0) }
  end })
  bwu.VARP_SET, bwu.VARP_DEFAULT_NOT_SET_CLIENTSIDE, bwu.VARP_NO_SUCH_VARP, bwu.VARP_UNAVAILABLE = 7, 8, 9, 10
  bwu.VAR_KIND_INT, bwu.VAR_KIND_LONG, bwu.VAR_KIND_STRING, bwu.VAR_KIND_UNKNOWN = 20, 21, 22, 23
  local r = g:read_varps({ 1, 2, 3 })
  assert_(r[1].state == V.SET and r[1].kind == "long", "renumbered set / long")
  assert_(r[2].state == V.DEFAULT, "renumbered default")
  assert_(r[3].state == V.UNAVAILABLE, "2 is not a state in this numbering")
end

T["an out-of-contract number is unavailable / unknown"] = function(assert_)
  local g = game({ var_reads = function(_, _) return { rec(1, 99, 4, { kind = 42 }) } end })
  local r = g:read_varp(1)
  assert_(r.state == V.UNAVAILABLE and r.kind == "unknown", "out of contract")
end

T["many ids go in one call; the host chunks"] = function(assert_)
  local g = game({ var_reads = function(_, ids)
    local out = {}
    for i, id in ipairs(ids) do out[i] = rec(id, SET, id) end
    return out
  end })
  local ids = {}
  for i = 1, 600 do ids[i] = i - 1 end
  local v = g:varps(ids)
  assert_(#v == 600 and v[1] == 0 and v[600] == 599, "600 values in order")
  assert_(#bwu._state.var_calls == 1, "one surface call")
end

T["a failed read raises"] = function(assert_)
  local g = game({ var_reads = function(_, _) return nil, "rpc timeout" end })
  local ok, err = pcall(g.read_varp, g, 1)
  assert_(not ok and tostring(err):find("rpc timeout", 1, true), "error carries the host's message")
end

T["an older native host is refused loudly"] = function(assert_)
  local g = game()
  bwu.read_varps, bwu.VARP_SET = nil, nil
  local ok, err = pcall(g.read_varp, g, 1)
  assert_(not ok and tostring(err):find("predates varp state reads", 1, true), "names what is missing")
end

T["defaults status is forwarded"] = function(assert_)
  local g = game({ defaults_status = -1 })
  assert_(g:varp_defaults_status() == -1, "status -1")
end

return T
