-- spec/run.lua -- a tiny dependency-free test runner.
--
-- Usage: lua spec/run.lua   (run from the repo root, or via scripts/test.ps1)
-- Discovers test tables (name -> fn) returned by spec/*_spec.lua and runs each,
-- passing an assert_(cond, msg) into every test. Exit code 1 on any failure.

-- Make `require("botwithus...")` and `require("spec...")` resolve from the repo root.
local here = arg[0]:gsub("[^/\\]*$", "")            -- .../spec/
local root = here:gsub("[/\\]spec[/\\]?$", "") .. "/" -- repo root
package.path = root .. "?.lua;" .. root .. "?/init.lua;" .. package.path

local specs = { "spec.api_spec" }

local passed, failed = 0, 0
local failures = {}

for _, mod in ipairs(specs) do
  local tests = require(mod)
  local names = {}
  for name in pairs(tests) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local fn = tests[name]
    local function assert_(cond, msg)
      if not cond then error(msg or "assertion failed", 2) end
    end
    -- Reset any injected global between tests.
    _G.bwu = nil
    local ok, err = pcall(fn, assert_)
    if ok then
      passed = passed + 1
      io.write("  ok   " .. name .. "\n")
    else
      failed = failed + 1
      failures[#failures + 1] = name .. "  --  " .. tostring(err)
      io.write("  FAIL " .. name .. "\n")
    end
  end
end

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then
  io.write("\nFailures:\n")
  for _, f in ipairs(failures) do io.write("  - " .. f .. "\n") end
  os.exit(1)
end
