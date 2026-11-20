-- botwithus.dialog -- the game's chat dialogs: multi-choice options, continuing a chat page, the
-- text and title of the open page, and the item-destroy confirmation (the Java host's
-- dialog.Dialog, ChatPage and ConfirmItemDestruction).
--
--   local Dialog = require("botwithus.dialog")
--   if Dialog.can_continue(game) then
--     print(Dialog.get_title(game), Dialog.plain(Dialog.get_text(game)))
--     Dialog.continue_dialog(game)
--   end
--   Dialog.select(game, "Yes")                -- a multi-choice option by (plain) text
--   if Dialog.Confirm.is_open(game) then Dialog.Confirm.confirm(game) end
--
-- Chat pages: NPC chat 1184, PLAYER chat 1191 (the player's own lines; its title is the
-- character's own name), the message box 1186 and the item box 1189. get_text / get_title read
-- the open page's text components and return the raw text (with <col>/<br> markup); plain()
-- strips markup. The message and item boxes have no title. Each read is one get_component round
-- trip; every press is a queued dialogue action, sent only while its page is open.

local Actions = require("botwithus.actions")
local CQ = require("botwithus.component_query")

local Dialog = {}

Dialog.MULTI_CHOICE_INTERFACE = 1188
Dialog.NPC_CHAT_INTERFACE = 1184
Dialog.PLAYER_CHAT_INTERFACE = 1191
local OPTIONS_CONTAINER = 0
local NPC_CHAT_CONTINUE = 15

-- The chat pages, checked in this order: { name, iface, text comp, title comp, continue comp }.
Dialog.PAGES = {
  { name = "npc", iface = 1184, text = 10, title = 4, continue = 15 },      -- CHAT_V2_LEFT
  { name = "player", iface = 1191, text = 10, title = 4, continue = 15 },   -- CHAT_V2_RIGHT
  { name = "message", iface = 1186, text = 3, continue = 8 },               -- MESBOX_V2
  { name = "object", iface = 1189, text = 3, continue = 20 },               -- OBJBOX_V2
}

local function dialogue_action(iface, comp)
  return Actions.dialogue_option(iface, comp)
end

-- Text without markup: every <...> tag becomes a space, whitespace runs become one space.
function Dialog.plain(text)
  if text == nil or text == "" then return "" end
  local stripped = text:gsub("<[^>]+>", " "):gsub("%s+", " ")
  return (stripped:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize(text) return Dialog.plain(text):lower() end

-- The open chat page row (see Dialog.PAGES), or nil.
function Dialog.open_page(game)
  for _, page in ipairs(Dialog.PAGES) do
    if game:is_interface_open(page.iface) then return page end
  end
  return nil
end

local function read_text(game, iface, comp)
  if comp == nil then return nil end
  local c = game:component(iface, comp)
  return c and c.text or nil
end

-- The open page's text (raw, with markup), or nil when no page is open.
function Dialog.get_text(game)
  local page = Dialog.open_page(game)
  return page and read_text(game, page.iface, page.text) or nil
end

-- The open page's title (the speaker), or nil (no page, or a page with no title).
function Dialog.get_title(game)
  local page = Dialog.open_page(game)
  return page and read_text(game, page.iface, page.title) or nil
end

function Dialog.can_continue(game) return Dialog.open_page(game) ~= nil end
function Dialog.is_player_chat_open(game) return game:is_interface_open(Dialog.PLAYER_CHAT_INTERFACE) end
function Dialog.is_chat_open(game) return game:is_interface_open(Dialog.NPC_CHAT_INTERFACE) end

-- Press the open page's continue. False when no page is open.
function Dialog.continue_dialog(game)
  local page = Dialog.open_page(game)
  if page == nil then return false end
  game:do_action(dialogue_action(page.iface, page.continue))
  return true
end

-- Press the NPC chat page's continue only.
function Dialog.continue_chat(game)
  if not Dialog.is_chat_open(game) then return false end
  game:do_action(dialogue_action(Dialog.NPC_CHAT_INTERFACE, NPC_CHAT_CONTINUE))
  return true
end

-- Multi-choice options --------------------------------------------------------------------------

-- A "1." number cell's number, or nil.
local function number_cell(text)
  local n = text:match("^%s*(%d+)%.%s*$")
  return n and tonumber(n) or nil
end

-- The (index, label) a row's text cells give: a number cell sets the index, the last other
-- cell is the label. nil when there is no label.
function Dialog.cells(texts, positional)
  local label, parsed = nil, nil
  for _, t in ipairs(texts) do
    local n = number_cell(t)
    if n and n > 0 and parsed == nil then parsed = n else label = t end
  end
  if label == nil or not label:find("%S") then return nil end
  return parsed or positional, label
end

-- The open multi-choice options: { {index, text, iface, comp, sub}, ... } in order, or {} when
-- none are open.
function Dialog.options(game)
  local q = CQ.new(game, Dialog.MULTI_CHOICE_INTERFACE)
  local container = q:node(Dialog.MULTI_CHOICE_INTERFACE, OPTIONS_CONTAINER)
  if container == nil then return {} end
  local out = {}
  for _, row in ipairs(q:children(container)) do
    if row.category == CQ.LAYER then
      local texts = {}
      for _, leaf in ipairs(q:descendants(row)) do
        if leaf.category == CQ.TEXT and leaf.text and leaf.text:find("%S") then texts[#texts + 1] = leaf.text end
      end
      local index, label = Dialog.cells(texts, #out + 1)
      if index then
        out[#out + 1] = { index = index, text = label, iface = row.iface, comp = row.comp, sub = row.sub }
      end
    end
  end
  return out
end

function Dialog.is_open(game) return #Dialog.options(game) > 0 end

local function press_option(game, option)
  game:do_action(dialogue_action(option.iface, option.comp))
  return true
end

-- Select the option whose plain text contains `which` (ignoring case), or the option numbered
-- `which` when it is an integer. False when none matches.
function Dialog.select(game, which)
  local options = Dialog.options(game)
  if math.type(which) == "integer" then
    for _, o in ipairs(options) do
      if o.index == which then return press_option(game, o) end
    end
    return false
  end
  local needle = normalize(which)
  if needle == "" then return false end
  for _, o in ipairs(options) do
    if normalize(o.text):find(needle, 1, true) then return press_option(game, o) end
  end
  return false
end

-- ConfirmItemDestruction (1183) -------------------------------------------------------------

local Confirm = {}
Confirm.INTERFACE = 1183     -- CONFIRM_DESTROY_V2
local YES, NO, ITEM_NAME = 7, 8, 4

function Confirm.is_open(game) return game:is_interface_open(Confirm.INTERFACE) end

-- The item being destroyed, as plain text, or nil when the prompt is closed.
function Confirm.item_name(game)
  if not Confirm.is_open(game) then return nil end
  local text = read_text(game, Confirm.INTERFACE, ITEM_NAME)
  return text and Dialog.plain(text) or nil
end

local function press(game, comp)
  if not Confirm.is_open(game) then return false end
  game:do_action(dialogue_action(Confirm.INTERFACE, comp))
  return true
end

function Confirm.confirm(game) return press(game, YES) end
function Confirm.cancel(game) return press(game, NO) end

Dialog.Confirm = Confirm
return Dialog
