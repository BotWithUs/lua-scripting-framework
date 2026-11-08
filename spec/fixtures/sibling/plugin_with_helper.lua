-- spec/fixtures/sibling/plugin_with_helper.lua -- a plugin that requires a file beside it.
local helper = require("sibling_helper")

return {
  manifest = { name = helper.NAME },
  on_loop = function() return -1 end,
}
