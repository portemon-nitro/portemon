-- The transient source money box: one non-modal field window that shows the
-- first-row label and the second-row balance from message bank 435. The source
-- opens the window at a tile coordinate, repaints the balance only on an
-- explicit update, and deletes it on hide (src/field/scrcmd_moneybox.c and
-- src/field/script_menu.c::FieldSystem_ShowMoneyBox/MoneyBoxSys_Update). The
-- box owns presentation state only: it borrows the live player profile for the
-- displayed balance and never stores a second wallet. Pure presentation state,
-- no love dependency; the field draw path renders the snapshot.

local Errors = require("libs.errors.src.Errors")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local ScriptErrors = require("libs.script.src.errors")

local MESSAGE_BANK = 435
local LABEL_MESSAGE = 30
local VALUE_MESSAGE = 31
-- The source money row expands a six-digit, right-aligned integer into the
-- message's own money marker: files/msgdata/msg/msg_0435.gmm row
-- msg_0435_00031 is "${STRVAR_1 55, 0, 0}", and
-- MoneyBoxSys_Update buffers the balance into format field 0 with
-- BufferIntegerAsString(msgFmt, 0, money, 6, PRINTING_MODE_RIGHT_ALIGN, TRUE)
-- before StringExpandPlaceholders (src/field/script_menu.c).
-- src/pm_string.c::String16_FormatInteger fills that right-aligned field with
-- narrow spaces, so a low balance keeps six character cells of leading blanks
-- rather than zeros, and the expanded string is drawn right-aligned inside
-- the window.
local MONEY_MARKER = FieldMessageText.STRVAR_1 + 55
local MONEY_DIGITS = 6
local TILE_SIZE = 8
local WIDTH_TILES = 10
local HEIGHT_TILES = 4

---@class FieldMoneyBox
---@field private _profile table<string, unknown>? borrowed live player profile
---@field private _messages table<string, unknown>? the field message provider
---@field private _state FieldMoneyBox.Snapshot? visible window state; nil when closed
---@field private _template table<string, unknown>? the source money value template
local FieldMoneyBox = {}
FieldMoneyBox.__index = FieldMoneyBox

-- The source window is a 10x4-tile frame on the main field display; the money
-- row starts at pixel row 16 of the frame.
FieldMoneyBox.WIDTH = WIDTH_TILES * TILE_SIZE
FieldMoneyBox.HEIGHT = HEIGHT_TILES * TILE_SIZE
FieldMoneyBox.MONEY_ROW_Y = 16

---@class FieldMoneyBox.Snapshot
---@field visible boolean
---@field tileX integer? source tile column, zero-based
---@field tileY integer? source tile row, zero-based
---@field label string? first-row source label text
---@field displayedMoney integer? the balance captured by the last show/update
---@field valueText string? second-row formatted balance

-- The message-provider capability the box borrows, and the wallet it reads
-- through the live player profile. Both are named contracts so the injected
-- owners stay visible at the call sites.
---@class FieldMoneyBox.MessageProvider
---@field acquireBank fun(self: table<string, unknown>, bankId: integer): table<string, unknown>?
---@field get fun(self: table<string, unknown>, bankId: integer, messageId: integer): table<string, unknown>?
---@field releaseBank fun(self: table<string, unknown>, bankId: integer)

---@class FieldMoneyBox.Wallet
---@field money integer

---@param opts { profile: table<string, unknown>?, messages: table<string, unknown>? }
---@return FieldMoneyBox
function FieldMoneyBox.new(opts)
  assert(type(opts) == "table", "the money box needs its composition options")
  return setmetatable({
    _profile = opts.profile,
    _messages = opts.messages,
    _state = nil,
    _template = nil,
  }, FieldMoneyBox)
end

---@param messageId integer
---@return table<string, unknown>
function FieldMoneyBox:_readMessage(messageId)
  local messages = self._messages
  if type(messages) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the money box requires the message provider", {})
  end
  ---@cast messages FieldMoneyBox.MessageProvider
  local acquire = messages.acquireBank
  local get = messages.get
  local release = messages.releaseBank
  if type(acquire) ~= "function" or type(get) ~= "function" or type(release) ~= "function" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the money box requires the message provider", {})
  end
  local bank, bankErr = acquire(messages, MESSAGE_BANK)
  if type(bank) ~= "table" then
    local err = bankErr --[[@as Errors.Error]]
    local context = { bankId = MESSAGE_BANK, cause = err.context }
    ---@cast context Errors.Context
    Errors.raise(err.code, err.message, context)
  end
  local template, templateErr = get(messages, MESSAGE_BANK, messageId)
  release(messages, MESSAGE_BANK)
  if type(template) ~= "table" then
    local err = templateErr --[[@as Errors.Error]]
    local context = { bankId = MESSAGE_BANK, messageId = messageId, cause = err.context }
    ---@cast context Errors.Context
    Errors.raise(err.code, err.message, context)
  end
  return template --[[@as table<string, unknown>]]
end

-- The source money row formats the balance into the message's money marker
-- as the source's space-padded, right-aligned integer. A template without
-- that marker has no field for the balance, so it faults instead of printing
-- the template's glyphs as if they were the money.
---@param template table<string, unknown>
---@param money integer
---@return string
local function formatMoneyText(template, money)
  local digits = string.format("%" .. MONEY_DIGITS .. "d", money)
  local parts = {}
  local substituted = false
  local tokens = template.tokens --[[@as { kind: string?, control: integer?, text: string? }[] ]]
  assert(type(tokens) == "table", "the money box value message carries tokens")
  for _, token in ipairs(tokens) do
    if token.kind == "substitution" and token.control == MONEY_MARKER then
      parts[#parts + 1] = digits
      substituted = true
    elseif token.kind == "glyph" and type(token.text) == "string" then
      parts[#parts + 1] = token.text
    end
  end
  if not substituted then
    Errors.raise(ScriptErrors.SCRIPT_MONEY_BOX_MESSAGE_INVALID, "the money value message carries no money marker", {
      bankId = template.bankId,
      messageId = template.messageId,
    })
  end
  return table.concat(parts)
end

---@param value unknown
---@param axis string
---@return integer
local function sourceTile(value, axis)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the money box needs a source tile " .. axis, {
      tile = value,
    })
  end
  ---@cast value number
  -- The source window takes u8 tile coordinates even though ScriptGetVar
  -- reads a u16 value.
  return (value % 0x100) --[[@as integer]]
end

---@return integer
function FieldMoneyBox:_liveMoney()
  local profile = self._profile
  if profile == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the money box requires the live player profile", {})
  end
  ---@cast profile FieldMoneyBox.Wallet
  local money = profile.money
  if type(money) ~= "number" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the money box requires the live player profile", {})
  end
  return money
end

---@param tileX integer
---@param tileY integer
function FieldMoneyBox:show(tileX, tileY)
  if self._state ~= nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the money box window is already open", {})
  end
  local tileColumn = sourceTile(tileX, "column")
  local tileRow = sourceTile(tileY, "row")
  local money = self:_liveMoney()
  local label = self:_readMessage(LABEL_MESSAGE)
  local template = self:_readMessage(VALUE_MESSAGE)
  local labelText = label.text
  assert(type(labelText) == "string", "the money box label message carries its text")
  self._template = template
  self._state = {
    visible = true,
    tileX = tileColumn,
    tileY = tileRow,
    label = labelText,
    displayedMoney = money,
    valueText = formatMoneyText(template, money),
  }
end

-- The source repaints the balance row only here; wallet changes while the
-- window is open do not reach the drawn snapshot.
function FieldMoneyBox:update()
  local state = self._state
  if state == nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the money box window is not open", {})
  end
  local money = self:_liveMoney()
  state.displayedMoney = money
  state.valueText = formatMoneyText(assert(self._template), money)
end

function FieldMoneyBox:hide()
  if self._state == nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the money box window is not open", {})
  end
  self._state = nil
  self._template = nil
end

---@return FieldMoneyBox.Snapshot
function FieldMoneyBox:snapshot()
  local state = self._state
  if state == nil then
    return { visible = false }
  end
  return {
    visible = true,
    tileX = state.tileX,
    tileY = state.tileY,
    label = state.label,
    displayedMoney = state.displayedMoney,
    valueText = state.valueText,
  }
end

-- Field teardown closes the transient window exactly once; disposing a closed
-- box is a no-op.
function FieldMoneyBox:dispose()
  self._state = nil
  self._template = nil
end

return FieldMoneyBox
