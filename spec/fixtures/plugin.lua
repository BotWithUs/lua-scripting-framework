-- spec/fixtures/plugin.lua -- a script file the worker specs load.
--
-- It records how it was called in _G.FIXTURE_CALLS and returns _G.FIXTURE_PLUGIN (a plugin
-- table, or nil to be self-running). Called with zero arguments it runs _G.FIXTURE_SELF_RUN.
_G.FIXTURE_CALLS = _G.FIXTURE_CALLS or {}
_G.FIXTURE_CALLS[#_G.FIXTURE_CALLS + 1] = { n = select("#", ...), ... }

if select("#", ...) == 0 then
  if _G.FIXTURE_SELF_RUN then _G.FIXTURE_SELF_RUN() end
  return
end

return _G.FIXTURE_PLUGIN
