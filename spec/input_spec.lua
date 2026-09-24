-- spec/input_spec.lua -- the input dialog: exact key packing on the wire, and input refused
-- before it is sent.
--
-- The packed vectors are the agent's (NXTLibrary Actions.h ComponentTrigger, scenario
-- iface-input-bank-x): 1469:4 is p1 96272388, a top-level key trigger is p2 720895,
-- (-1, '3') is p3 -65485 and Enter (84, 0) is 5505024. The Python suite pins the same vectors.

local fake_bwu = require("spec.fake_bwu")
local bot      = require("botwithus")
local Input    = require("botwithus.input")

local P1, P2 = 96272388, 720895
local ENTER, BACKSPACE, ESCAPE = 5505024, 5570560, 851968

local T = {}

local function dialog(opts)
  opts = opts or {}
  _G.bwu = fake_bwu.new({
    varcs = { [5] = opts.mode or Input.MODE_AMOUNT },
    varc_strings = { [2506] = opts.text or "" },
    queue_accept = opts.accept,
  })
  return Input.dialog(bot.Game.attach()), _G.bwu._state
end

-- The p3 of the one batch sent, after checking every key is a 1469:4 top-level key trigger.
local function arg0s(state)
  assert(#state.batches == 1, "every input call must be exactly one batch, got " .. #state.batches)
  local out = {}
  for i, a in ipairs(state.batches[1]) do
    assert(a.id == 5003 and a.p1 == P1 and a.p2 == P2, "key " .. i .. " is not a 1469:4 key trigger")
    out[i] = a.p3
  end
  return out
end

local function chars(text)
  local out = {}
  for i = 1, #text do out[i] = -65536 + text:byte(i) end
  return out
end

local function same(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function with_enter(list) list[#list + 1] = ENTER; return list end

local function refused(fn, prefix)
  local ok, err = pcall(fn)
  return not ok and tostring(err):find(prefix, 1, true) ~= nil, err
end

-- --- packing ------------------------------------------------------------------------

T["key_trigger packs the agent layout"] = function(assert_)
  local a = Input.key_trigger(1469, 4, Input.KEY_NONE, string.byte("3"))
  assert_(a.id == 5003 and a.p1 == P1 and a.p2 == P2 and a.p3 == -65485, "(-1,'3') on 1469:4")
  assert_(Input.key_trigger(1469, 4, Input.KEY_ENTER).p3 == ENTER, "Enter is (84,0)")
  assert_(Input.key_trigger(1469, 4, Input.KEY_BACKSPACE).p3 == BACKSPACE, "Backspace is (85,0)")
  assert_(Input.key_trigger(1469, 4, Input.KEY_ESCAPE).p3 == ESCAPE, "Escape is (13,0)")
end

T["key_trigger keeps a sub slot and high ids in int32"] = function(assert_)
  local a = Input.key_trigger(0xFFFF, 0xFFFF, 18, 0, 5)
  assert_(a.p1 == -1, "0xFFFF:0xFFFF wraps to -1")
  assert_(a.p2 == (10 << 16) | 5, "sub slot 5")
  assert_(a.p3 == 18 << 16, "keydown (18,0)")
end

T["key_trigger refuses values that do not fit"] = function(assert_)
  local bad = {
    { -1, 4 }, { 0x10000, 4 }, { 1469, 0x10000 }, { 1469, 4, 0x8000 }, { 1469, 4, -0x8001 },
    { 1469, 4, -1, -1 }, { 1469, 4, -1, 0x10000 }, { 1469, 4, -1, 0, 0x8000 }, { 1469, 4, -1, 1.5 },
  }
  for i, args in ipairs(bad) do
    assert_(not pcall(Input.key_trigger, table.unpack(args)), "case " .. i .. " must be refused")
  end
end

-- --- typing -------------------------------------------------------------------------

T["enter_amount types each digit then Enter in one batch"] = function(assert_)
  local d, st = dialog()
  d:enter_amount(3)
  assert_(same(arg0s(st), { -65485, ENTER }), "3 then Enter")
  assert_(#st.actions == 2, "both keys reached the queue")
end

T["enter_amount with a k suffix"] = function(assert_)
  local d, st = dialog()
  d:enter_amount("10k")
  assert_(same(arg0s(st), { -65487, -65488, -65429, ENTER }), "'1' '0' 'k' Enter")
end

T["enter_amount without submit sends no Enter"] = function(assert_)
  local d, st = dialog()
  d:enter_amount(250, false)
  assert_(same(arg0s(st), chars("250")), "just the digits")
end

T["enter_text types a name"] = function(assert_)
  local d, st = dialog({ mode = Input.MODE_NAME })
  d:enter_text("Bob_1")
  assert_(same(arg0s(st), { -65470, -65425, -65438, -65441, -65487, ENTER }), "Bob_1 then Enter")
end

T["submit, cancel, backspace and clear"] = function(assert_)
  local cases = {
    { function(d) d:submit() end, { ENTER } },
    { function(d) d:cancel() end, { ESCAPE } },
    { function(d) d:backspace(2) end, { BACKSPACE, BACKSPACE } },
    { function(d) d:clear() end, { BACKSPACE, BACKSPACE, BACKSPACE } },
  }
  for i, c in ipairs(cases) do
    local d, st = dialog({ text = "12k" })
    c[1](d)
    assert_(same(arg0s(st), c[2]), "case " .. i)
  end
end

T["clear of an empty dialog sends nothing"] = function(assert_)
  local d, st = dialog({ text = "" })
  d:clear()
  assert_(#st.batches == 0, "no batch")
end

T["mode reads varc 5"] = function(assert_)
  assert_(dialog({ mode = 7 }):mode() == "amount", "7 is amount")
  assert_(dialog({ mode = 2 }):mode() == "name", "2 is name")
  assert_(dialog({ mode = 0 }):mode() == "closed", "0 is closed")
  assert_(dialog({ mode = 9 }):mode() == "other", "9 is other")
  assert_(not dialog({ mode = 0 }):is_open(), "0 is not open")
  assert_(dialog({ mode = 9 }):is_open(), "an unlisted mode is open")
end

-- --- refused before anything is sent ---------------------------------------------------

T["bad amounts are refused before sending"] = function(assert_)
  local bad = { "b", "1.5", "1 0", "k", "k5", "5kk", "5k3", "5M", "5b", "", "12345678901",
                -1, 1.5, true, 2147483648, "2147483648", "2147484k", "2148m" }
  for _, amount in ipairs(bad) do
    local d, st = dialog()
    local ok, err = refused(function() d:enter_amount(amount) end, "input rejected:")
    assert_(ok, "amount " .. tostring(amount) .. " must be rejected, got: " .. tostring(err))
    assert_(#st.batches == 0, "nothing sent for " .. tostring(amount))
  end
end

T["amount edges that are accepted"] = function(assert_)
  for _, amount in ipairs({ "2147483647", "2147483k", "2147m", "5K", "0" }) do
    local d, st = dialog()
    d:enter_amount(amount)
    assert_(same(arg0s(st), with_enter(chars(amount))), "amount " .. amount)
  end
end

T["bad names are refused before sending"] = function(assert_)
  for _, name in ipairs({ "", "thirteenchars", "bob@home", "Jos\xE9", "a\tb" }) do
    local d, st = dialog({ mode = Input.MODE_NAME })
    local ok, err = refused(function() d:enter_text(name) end, "input rejected:")
    assert_(ok, "name '" .. name .. "' must be rejected, got: " .. tostring(err))
    assert_(#st.batches == 0, "nothing sent for '" .. name .. "'")
  end
end

T["text already typed counts toward the limit"] = function(assert_)
  local d, st = dialog({ text = "123456789" })
  assert_(refused(function() d:enter_amount(10) end, "input rejected:"), "11 chars in total")
  d, st = dialog({ text = "5k" })
  assert_(refused(function() d:enter_amount(3) end, "input rejected:"), "a digit after the suffix")
  assert_(#st.batches == 0, "nothing sent")
end

T["wrong or closed dialog is refused"] = function(assert_)
  local cases = {
    { 0, function(d) d:enter_amount(3) end },
    { 2, function(d) d:enter_amount(3) end },
    { 7, function(d) d:enter_text("bob") end },
    { 9, function(d) d:enter_text("bob") end },
    { 0, function(d) d:submit() end },
    { 0, function(d) d:cancel() end },
    { 0, function(d) d:backspace() end },
    { -1, function(d) d:submit() end },
  }
  for i, c in ipairs(cases) do
    local d, st = dialog({ mode = c[1] })
    local ok, err = refused(function() c[2](d) end, "input dialog:")
    assert_(ok, "case " .. i .. " must be refused, got: " .. tostring(err))
    assert_(#st.batches == 0, "case " .. i .. " sent nothing")
  end
end

T["a partly queued batch raises"] = function(assert_)
  local d = dialog({ accept = 1 })
  assert_(refused(function() d:enter_amount(3) end, "queued 1 of 2"), "partial queue is loud")
end

return T
