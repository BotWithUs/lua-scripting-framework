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

T["KeyStroke packs the agent layout"] = function(assert_)
  assert_(Input.KeyStroke.character("3"):packed() == -65485, "(-1,'3')")
  assert_(Input.ENTER:packed() == ENTER, "Enter is (84,0)")
  assert_(Input.BACKSPACE:packed() == BACKSPACE, "Backspace is (85,0)")
  assert_(Input.ESCAPE:packed() == ESCAPE, "Escape is (13,0)")
  assert_(Input.KeyStroke.new(18):packed() == 18 << 16, "keydown (18,0)")
  local a = Input.key_action(1469, 4, Input.ENTER)
  assert_(a.id == 5003 and a.p1 == P1 and a.p2 == P2 and a.p3 == ENTER, "Enter on 1469:4")
end

T["KeyStroke refuses values that do not fit"] = function(assert_)
  for i, args in ipairs({ { 0x8000, 0 }, { -0x8001, 0 }, { -1, -1 }, { -1, 0x10000 }, { 1.5, 0 } }) do
    assert_(not pcall(Input.KeyStroke.new, args[1], args[2]), "case " .. i)
  end
end

T["character takes one printable ASCII char"] = function(assert_)
  for _, c in ipairs({ "", "ab", "\t", "\x7f", "\xE9", 51 }) do
    assert_(refused(function() Input.KeyStroke.character(c) end, "input rejected:"), "refuse " .. tostring(c))
  end
end

T["component_trigger legacy rule for key triggers"] = function(assert_)
  assert_(Input.component_trigger(1469, 4, 10, 84).p3 == ENTER, "84 is Enter, not 'T'")
  assert_(Input.component_trigger(1469, 4, 10, -65485).p3 == -65485, "packed passes through")
  assert_(Input.component_trigger(1469, 4, 10, ENTER).p3 == ENTER, "packed Enter passes through")
  assert_(Input.component_trigger(1469, 4, 10, 0).p3 == 0, "0 stays 0")
  local a = Input.component_trigger(1469, 4, 0, 84)
  assert_(a.p2 == 0xFFFF and a.p3 == 84, "other trigger types never get the rule")
end

T["component_trigger keeps a sub slot and high ids in int32"] = function(assert_)
  local a = Input.component_trigger(0xFFFF, 0xFFFF, 10, 18, 5)
  assert_(a.p1 == -1, "0xFFFF:0xFFFF wraps to -1")
  assert_(a.p2 == (10 << 16) | 5, "sub slot 5")
  assert_(a.p3 == 18 << 16, "keydown (18,0)")
end

T["component_trigger refuses values that do not fit"] = function(assert_)
  local bad = { { -1, 4, 10 }, { 0x10000, 4, 10 }, { 1469, 0x10000, 10 }, { 1469, 4, -1 },
                { 1469, 4, 10, 0, 0x8000 }, { 1469, 4, 10, 1.5 } }
  for i, args in ipairs(bad) do
    assert_(not pcall(Input.component_trigger, table.unpack(args)), "case " .. i .. " must be refused")
  end
end

-- --- raw key calls ---------------------------------------------------------------------

T["fire_keys sends one batch and returns the count"] = function(assert_)
  local d, st = dialog()
  local n = Input.fire_keys(d._game, 1469, 4, { Input.KeyStroke.new(18), Input.KeyStroke.character("3") })
  assert_(n == 2, "two queued")
  assert_(same(arg0s(st), { 18 << 16, -65485 }), "keydown then char")
end

T["fire_keys refuses more than one batch"] = function(assert_)
  local d, st = dialog()
  local many = {}
  for i = 1, Input.MAX_BATCH + 1 do many[i] = Input.ENTER end
  assert_(not pcall(Input.fire_keys, d._game, 1469, 4, many), "129 keys refused")
  assert_(#st.batches == 0, "nothing sent")
end

T["type_text types without submitting"] = function(assert_)
  local d, st = dialog()
  assert_(Input.type_text(d._game, 1469, 4, "12") == 2, "two queued")
  assert_(same(arg0s(st), chars("12")), "just the chars")
end

-- --- the dialog ------------------------------------------------------------------------

T["enter_amount types each digit then Enter in one batch"] = function(assert_)
  local d, st = dialog()
  assert_(d:enter_amount(3) == true, "returns true")
  assert_(same(arg0s(st), { -65485, ENTER }), "3 then Enter")
  assert_(#st.actions == 2, "both keys reached the queue")
end

T["enter_amount with a k suffix"] = function(assert_)
  local d, st = dialog()
  assert_(d:enter_amount("10k"), "returns true")
  assert_(same(arg0s(st), { -65487, -65488, -65429, ENTER }), "'1' '0' 'k' Enter")
end

T["enter_text types a name"] = function(assert_)
  local d, st = dialog({ mode = Input.MODE_NAME })
  assert_(d:enter_text("Bob_1"), "returns true")
  assert_(same(arg0s(st), { -65470, -65425, -65438, -65441, -65487, ENTER }), "Bob_1 then Enter")
end

T["submit, cancel, backspace and clear"] = function(assert_)
  local cases = {
    { function(d) return d:submit() end, { ENTER } },
    { function(d) return d:cancel() end, { ESCAPE } },
    { function(d) return d:backspace(2) end, { BACKSPACE, BACKSPACE } },
    { function(d) return d:clear() end, { BACKSPACE, BACKSPACE, BACKSPACE } },
  }
  for i, c in ipairs(cases) do
    local d, st = dialog({ text = "12k" })
    assert_(c[1](d) == true, "case " .. i .. " returns true")
    assert_(same(arg0s(st), c[2]), "case " .. i)
  end
end

T["clear of an empty dialog sends nothing"] = function(assert_)
  local d, st = dialog({ text = "" })
  assert_(d:clear() == true, "nothing to clear is success")
  assert_(#st.batches == 0, "no batch")
end

T["mode and text"] = function(assert_)
  assert_(dialog({ mode = 7 }):mode() == "amount", "7 is amount")
  assert_(dialog({ mode = 2 }):mode() == "name", "2 is name")
  assert_(dialog({ mode = 0 }):mode() == "closed", "0 is closed")
  assert_(dialog({ mode = 9 }):mode() == "other", "9 is other")
  assert_(not dialog({ mode = 0 }):is_open(), "0 is not open")
  assert_(dialog({ mode = 9 }):is_open(), "an unlisted mode is open")
  assert_(dialog({ mode = 7, text = "42" }):text() == "42", "open: the typed text")
  assert_(dialog({ mode = 0, text = "42" }):text() == "", "closed: empty (varc 2506 outlives the dialog)")
end

T["unset mode is closed"] = function(assert_)
  -- Live: in game, before the dialog has ever been opened, varc 5 reads -1.
  local d, st = dialog({ mode = -1, text = "42" })
  assert_(d:mode() == "closed", "-1 is closed")
  assert_(not d:is_open(), "-1 is not open")
  assert_(d:text() == "", "no text while closed")
  assert_(d:submit() == false and d:enter_amount(3) == false, "sends return false")
  assert_(#st.batches == 0, "nothing sent")
end

T["a failed mode read raises"] = function(assert_)
  local d = dialog()
  _G.bwu.varc_int = function() return nil, "rpc timeout" end
  assert_(refused(function() d:submit() end, "varc_int failed"), "RPC failure is loud")
end

-- --- refused, nothing sent ---------------------------------------------------------------

T["bad amounts raise before sending"] = function(assert_)
  local bad = { "b", "1.5", "1 0", "k", "k5", "5kk", "5k3", "5b", "5M", "", "12345678901",
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
    assert_(d:enter_amount(amount), "amount " .. amount .. " returns true")
    assert_(same(arg0s(st), with_enter(chars(amount))), "amount " .. amount)
  end
end

T["bad names raise before sending"] = function(assert_)
  for _, name in ipairs({ "", "thirteenchars", "bob@home", "Jos\xE9", "a\tb" }) do
    local d, st = dialog({ mode = Input.MODE_NAME })
    local ok, err = refused(function() d:enter_text(name) end, "input rejected:")
    assert_(ok, "name '" .. name .. "' must be rejected, got: " .. tostring(err))
    assert_(#st.batches == 0, "nothing sent for '" .. name .. "'")
  end
end

T["a bad argument raises even when the dialog is closed"] = function(assert_)
  local d = dialog({ mode = 0 })
  assert_(refused(function() d:enter_amount("b") end, "input rejected:"), "argument before state")
end

T["text already typed counts toward the limit"] = function(assert_)
  local d, st = dialog({ text = "123456789" })
  assert_(refused(function() d:enter_amount(10) end, "input rejected:"), "11 chars in total")
  d, st = dialog({ text = "5k" })
  assert_(refused(function() d:enter_amount(3) end, "input rejected:"), "a digit after the suffix")
  assert_(#st.batches == 0, "nothing sent")
end

T["wrong or closed dialog returns false"] = function(assert_)
  local cases = {
    { 0, function(d) return d:enter_amount(3) end },
    { 2, function(d) return d:enter_amount(3) end },
    { 7, function(d) return d:enter_text("bob") end },
    { 9, function(d) return d:enter_text("bob") end },
    { 0, function(d) return d:submit() end },
    { 0, function(d) return d:cancel() end },
    { 0, function(d) return d:backspace() end },
    { 0, function(d) return d:clear() end },
  }
  for i, c in ipairs(cases) do
    local d, st = dialog({ mode = c[1], text = "12" })
    assert_(c[2](d) == false, "case " .. i .. " returns false")
    assert_(#st.batches == 0, "case " .. i .. " sent nothing")
  end
end

T["a partly queued batch raises"] = function(assert_)
  local d = dialog({ accept = 1 })
  assert_(refused(function() d:enter_amount(3) end, "queued 1 of 2"), "partial queue is loud")
end

return T
