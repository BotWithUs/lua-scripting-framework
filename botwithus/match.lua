-- botwithus.match -- item matchers by exact name, pattern, category or option (the Java host's
-- InventoryContainer name / Pattern / category predicates).
--
--   local Match = require("botwithus.match")
--   bp:find(Match.exact("Logs"))                 -- "Logs" only, never "Oak logs"
--   bp:count(Match.pattern("Raw %a+"))           -- the WHOLE name must match the Lua pattern
--   bank:deposit_all_except(Match.exact("Coins", "Small fishing net"))
--   bp:find_all(Match.category(22))
--   bp:find_all(Match.option("Eat"))
--
-- Each matcher is a predicate over an inventory slot row ({ slot, item_id, quantity }), so it
-- goes anywhere an inventory matcher does (botwithus.inventory). Names come from the cache
-- (botwithus.definitions.item_name: a note reads as its item); an item the cache cannot name never
-- matches a name matcher.
--
-- WHOLE NAMES, stated loudly. A plain string given to :find / :count / :contains is a
-- case-insensitive SUBSTRING (bp:count("logs") counts Oak logs too). Match.exact and
-- Match.pattern match the WHOLE display name, case-insensitively for exact. So do the methods
-- that decide what to click or deposit (Inventory:interact, Bank:deposit / withdraw /
-- deposit_all*, DepositBox:deposit_all_except, Inventory:find_exact): with a substring, "Logs"
-- would deposit Oak logs.

local Definitions = require("botwithus.definitions")

local Match = {}

local function name_of(row) return Definitions.item_name(row.item_id) end

-- Lower-cased names, raising on anything that is not a non-empty string.
local function wanted_names(names, level)
  local out = {}
  for i, n in ipairs(names) do
    if type(n) ~= "string" or not n:find("%S") then
      error("botwithus: an item name must be a non-empty string", level)
    end
    out[i] = n:lower()
  end
  if #out == 0 then error("botwithus: give at least one name", level) end
  return out
end

-- The items whose whole display name is one of `...`, ignoring case.
function Match.exact(...)
  local wanted = wanted_names({ ... }, 3)
  return function(row)
    local name = name_of(row)
    if name == nil then return false end
    name = name:lower()
    for _, w in ipairs(wanted) do
      if name == w then return true end
    end
    return false
  end
end

-- A Lua pattern anchored at both ends, so it must match the whole name (Java's matches()).
local function anchored(p)
  if p:sub(1, 1) ~= "^" then p = "^" .. p end
  if p:sub(-1) ~= "$" or p:sub(-2) == "%$" then p = p .. "$" end
  return p
end

-- The items whose whole display name matches one of the Lua patterns `...` (case-sensitive, as
-- Lua patterns are; write "[Ll]ogs" for either case).
function Match.pattern(...)
  local patterns = {}
  for i, p in ipairs({ ... }) do
    if type(p) ~= "string" or p == "" then error("botwithus: a pattern must be a non-empty string", 2) end
    patterns[i] = anchored(p)
  end
  return function(row)
    local name = name_of(row)
    if name == nil then return false end
    for _, p in ipairs(patterns) do
      if name:find(p) then return true end
    end
    return false
  end
end

-- The items whose cache category is `category`.
function Match.category(category)
  return function(row)
    local ok, def = pcall(Definitions.item, row.item_id)
    return ok and def ~= nil and def.category == category
  end
end

-- The items whose cache inventory ops include `option`, ignoring case. These are the cache's
-- ops, not the live menu: the client's own Drop and Examine are not in them.
function Match.option(option)
  local want = option:lower()
  return function(row)
    local ok, def = pcall(Definitions.item, row.item_id)
    if not ok or def == nil then return false end
    for _, op in ipairs(def.inventory_ops or {}) do
      if op:lower() == want then return true end
    end
    return false
  end
end

-- The items with one of the ids `...`.
function Match.ids(...)
  local set = {}
  for _, id in ipairs({ ... }) do set[id] = true end
  return function(row) return set[row.item_id] == true end
end

-- Everything `m` (a predicate) does not match.
function Match.negate(m)
  return function(row) return not m(row) end
end

-- A deposit / click target: a matcher where a plain string (or a list of strings) is an EXACT
-- name, an integer or a list of integers are ids, and a function is itself.
function Match.target(m)
  local kind = type(m)
  if kind == "function" then return m end
  if kind == "string" then return Match.exact(m) end
  if math.type(m) == "integer" then return Match.ids(m) end
  if kind == "table" and #m > 0 then
    if type(m[1]) == "string" then return Match.exact(table.unpack(m)) end
    return Match.ids(table.unpack(m))
  end
  error("botwithus: a target is an exact name, a list of names, an id, a list of ids or a"
    .. " matcher function, not " .. kind, 3)
end

return Match
