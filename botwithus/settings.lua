-- botwithus.settings -- a run's writable settings (the Java host's config.ScriptSettings).
--
--   function script.on_loop(ctx)
--     local trips = ctx.settings:get_int("trips", 0)
--     ctx.settings:put("trips", trips + 1)
--   end
--
-- ctx.settings reads through to ctx.config: a key the script has not written reads the current
-- config value, and a key it wrote wins over the config. When the user applies new settings in
-- the GUI, ctx.config is replaced but the keys the script wrote are kept: the new config is
-- merged under them, as the Java host's UI apply merges.
--
-- NOT PERSISTED. The native host's run-control channel has no settings store yet, so save()
-- returns false, "unsupported" and the written keys last for the run only. (The Java host saves
-- them to the per-account config file.)

local Settings = {}
Settings.__index = Settings

-- Settings over `config_of()`, which returns the run's current config table.
function Settings.new(config_of)
  return setmetatable({ _config_of = config_of or function() return {} end, _own = {},
                        _removed = {} }, Settings)
end

-- The value of `key`: the script's own, else the config's, else nil.
function Settings:get(key)
  local own = self._own[key]
  if own ~= nil then return own end
  if self._removed[key] then return nil end
  return (self._config_of() or {})[key]
end

function Settings:put(key, value)
  if type(key) ~= "string" then error("botwithus: a settings key is a string", 2) end
  self._own[key] = value
  self._removed[key] = nil
end

-- Removes `key` (the config's value too, for the rest of the run); true when it was set.
function Settings:remove(key)
  local had = self:get(key) ~= nil
  self._own[key] = nil
  self._removed[key] = true
  return had
end

-- Every key, the config's under the script's own.
function Settings:as_table()
  local out = {}
  for k, v in pairs(self._config_of() or {}) do
    if not self._removed[k] then out[k] = v end
  end
  for k, v in pairs(self._own) do out[k] = v end
  return out
end

function Settings:get_string(key, default)
  local v = self:get(key)
  if v == nil then return default end
  return tostring(v)
end

function Settings:get_int(key, default)
  local v = self:get(key)
  local n = math.tointeger(type(v) == "string" and tonumber(v) or v)
  return n or default
end

function Settings:get_boolean(key, default)
  local v = self:get(key)
  if type(v) == "boolean" then return v end
  if v == "true" then return true end
  if v == "false" then return false end
  return default
end

Settings.put_int = Settings.put
Settings.put_boolean = Settings.put

-- Not supported by the native host yet: false, "unsupported".
function Settings:save() return false, "unsupported" end

return Settings
