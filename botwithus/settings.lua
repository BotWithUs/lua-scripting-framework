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
-- SAVED in a GUI worker on host ABI 8: save() hands every key, as a string, to the GUI's settings
-- store, beside the run's saved config, and the next run starts from them with the config over
-- them. Declared config keys are owned by the config, so a put on one lasts for the run only.
-- Under bwu_host --lua there is no store: save() returns false, "unsupported". (The Java host
-- saves them to its per-account config file.)

local Settings = {}
Settings.__index = Settings

-- The host's settings store (host ABI 8, GUI worker only), or nil: { saved = the map the last
-- run saved or nil, save = function(map) -> code, why }.
function Settings.host_store()
  local b = rawget(_G, "bwu")
  if b == nil or b.ctl_save_settings == nil or b.ctl_mode == nil or b.ctl_mode() ~= b.CTL_WORKER then
    return nil
  end
  return { saved = b.ctl_settings(), save = function(map) return b.ctl_save_settings(map) end,
           ok = b.CTL_SAVE_OK }
end

-- Settings over `config_of()`, which returns the run's current config table. `store` (optional,
-- default Settings.host_store()) seeds the keys the last run saved, below the config, and takes
-- save().
function Settings.new(config_of, store)
  if store == nil then store = Settings.host_store() end
  return setmetatable({ _config_of = config_of or function() return {} end, _own = {},
                        _removed = {}, _saved = (store and store.saved) or {}, _store = store },
                      Settings)
end

-- The value of `key`: the script's own, else the config's, else what the last run saved, else
-- nil. The config wins over the saved keys, as the Java host merges an apply over its settings.
function Settings:get(key)
  local own = self._own[key]
  if own ~= nil then return own end
  if self._removed[key] then return nil end
  local configured = (self._config_of() or {})[key]
  if configured ~= nil then return configured end
  return self._saved[key]
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

-- Every key: the saved ones, the config's over them, the script's own over both.
function Settings:as_table()
  local out = {}
  for k, v in pairs(self._saved) do
    if not self._removed[k] then out[k] = v end
  end
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

local function text(v)
  if type(v) == "boolean" then return v and "true" or "false" end
  return tostring(v)
end

-- Writes every key, as strings, to the host's settings store: true, or false, why. Outside a GUI
-- worker on host ABI 8 there is no store: false, "unsupported".
function Settings:save()
  local store = self._store
  if store == nil then return false, "unsupported" end
  local map = {}
  for k, v in pairs(self:as_table()) do map[k] = text(v) end
  local code, why = store.save(map)
  if code == store.ok then return true end
  io.stderr:write(("[botwithus.settings] settings not saved: %s\n"):format(tostring(why)))
  return false, why
end

return Settings
