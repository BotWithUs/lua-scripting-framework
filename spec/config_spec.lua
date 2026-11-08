-- spec/config_spec.lua -- botwithus.config: the field helpers and the schema rules, including
-- the four places the native host is stricter than the Java host.

local Config = require("botwithus.config")

local T = {}

local function field_error(field)
  local ok, err = Config.validate_fields({ field })
  if ok then return nil end
  return err
end

local function refused(assert_, field, path)
  local err = field_error(field)
  assert_(err and err:find(path, 1, true) == 1, "expected an error at " .. path .. ", got " .. tostring(err))
end

T["helpers build wire-keyed fields that validate"] = function(assert_)
  local fields = {
    Config.int_field("logs", "Logs", 28, { min = 1, max = 28, step = 1, description = "how many" }),
    Config.string_field("note", "Note", "", { max_len = 32 }),
    Config.bool_field("bank", "Bank", true),
    Config.choice_field("tree", "Tree", { "oak", "willow" }, "oak"),
    Config.item_id_field("food", "Food"),
  }
  assert_(Config.validate_fields(fields), "valid")
  assert_(fields[5].default == Config.ITEM_NONE, "item_id defaults to -1 (no item)")
  local d = Config.defaults(fields)
  assert_(d.logs == 28 and d.note == "" and d.bank == true and d.tree == "oak" and d.food == -1, "defaults")
end

T["stricter than Java: a choice default must be an option"] = function(assert_)
  refused(assert_, Config.choice_field("t", "T", { "oak" }, "yew"), "config_schema[0].default")
end

T["stricter than Java: a choice needs at least one option"] = function(assert_)
  refused(assert_, Config.choice_field("t", "T", {}, ""), "config_schema[0].options")
end

T["stricter than Java: an item id default below -1 is refused"] = function(assert_)
  refused(assert_, Config.item_id_field("f", "F", -2), "config_schema[0].default")
end

T["stricter than Java: a string default over 256 bytes needs max_len"] = function(assert_)
  local long = string.rep("x", 257)
  refused(assert_, Config.string_field("s", "S", long), "config_schema[0].default")
  assert_(field_error(Config.string_field("s", "S", long, { max_len = 300 })) == nil, "allowed with max_len")
end

T["int fields: range, int32 bounds, step and integral floats"] = function(assert_)
  refused(assert_, Config.int_field("n", "N", 5, { min = 6 }), "config_schema[0].default")
  refused(assert_, Config.int_field("n", "N", 0, { min = 2, max = 1 }), "config_schema[0].min")
  refused(assert_, Config.int_field("n", "N", 0, { max = 2147483648 }), "config_schema[0].max")
  refused(assert_, Config.int_field("n", "N", 0, { step = 0 }), "config_schema[0].step")
  refused(assert_, Config.int_field("n", "N", 1.5), "config_schema[0].default")
  assert_(field_error(Config.int_field("n", "N", 3.0)) == nil, "an integral float is an integer")
  assert_(Config.defaults({ Config.int_field("n", "N", 3.0) }).n == 3
          and math.type(Config.defaults({ Config.int_field("n", "N", 3.0) }).n) == "integer", "default as an integer")
end

T["bool fields take booleans only"] = function(assert_)
  refused(assert_, Config.bool_field("b", "B", 1), "config_schema[0].default")
end

T["keys: charset, length, uniqueness; kinds and labels"] = function(assert_)
  refused(assert_, Config.bool_field("has space", "B", true), "config_schema[0].key")
  refused(assert_, Config.bool_field(string.rep("k", 65), "B", true), "config_schema[0].key")
  refused(assert_, Config.bool_field("", "B", true), "config_schema[0].key")
  refused(assert_, { key = "k", kind = "float", label = "K", default = 1 }, "config_schema[0].kind")
  refused(assert_, Config.bool_field("k", "", true), "config_schema[0].label")
  local ok, err = Config.validate_fields({ Config.bool_field("k", "A", true), Config.bool_field("k", "B", true) })
  assert_(not ok and err:find("config_schema[1].key", 1, true), "duplicate key: " .. tostring(err))
  assert_(Config.validate_fields({ Config.bool_field("a.b-c_1", "A", true) }), "[A-Za-z0-9_.-] allowed")
end

T["choice options: no duplicates, bounded"] = function(assert_)
  refused(assert_, Config.choice_field("c", "C", { "a", "a" }, "a"), "config_schema[0].options[1]")
  local many = {}
  for i = 1, 65 do many[i] = "o" .. i end
  refused(assert_, Config.choice_field("c", "C", many, "o1"), "config_schema[0].options")
end

T["manifest rules and defaults"] = function(assert_)
  local m = Config.manifest_of({ manifest = { name = "N" } }, "stem")
  assert_(m.version == "1.0" and m.author == "" and m.description == "", "defaults filled")
  assert_(Config.manifest_of({}, "stem").name == "stem", "name from the stem")
  assert_(Config.validate_manifest(m), "valid")
  local ok, err = Config.validate_manifest({ name = "", version = "1.0", author = "", description = "" })
  assert_(not ok and err:find("manifest.name", 1, true) == 1, "empty name refused")
  ok, err = Config.validate_manifest({ name = "N", version = "1.0", author = "", description = "", category = "" })
  assert_(not ok and err:find("manifest.category", 1, true) == 1, "empty category refused")
end

return T
