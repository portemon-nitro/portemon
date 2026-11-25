-- The transient source points window: one non-modal field window that prints
-- the source wallet row the script names. The source opens it at a tile
-- coordinate with a type selector, repaints it only on an explicit update, and
-- deletes the window on hide (src/overlay_22.c::ScrCmd_ShowPointsBox/
-- ScrCmd_UpdatePointsBox and src/field/script_menu.c::PointsBox_New/
-- PointsBox_Update). Type 1 is the battle-point balance this port owns: bank
-- 191 message 220 is "${STRVAR_1 53, 0, 0} BP", and
-- PointsBox_Update buffers the balance into format field 0 with
-- BufferIntegerAsString(msgFmt, 0, value, 5, PRINTING_MODE_RIGHT_ALIGN, TRUE)
-- before it right-aligns the expanded 80-pixel row. The box owns presentation
-- state only: it borrows the live wallet for the displayed balance and never
-- stores a second one. Pure presentation state, no love dependency; the field
-- draw path renders the snapshot.

local Errors = require("libs.errors.src.Errors")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local ScriptErrors = require("libs.script.src.errors")

local MESSAGE_BANK = 191
local VALUE_MESSAGE = 220
-- src/pm_string.c::String16_FormatInteger fills the five-cell right-aligned
-- field with narrow spaces, so a low balance keeps five character cells of
-- leading blanks rather than zeros.
local VALUE_DIGITS = 5
local TILE_SIZE = 8
local WIDTH_TILES = 10
local HEIGHT_TILES = 2

-- The source's `enum PointsBoxType`: 0 coins, 1 battle points, 2 athlete
-- points. This window owns the battle-point row; the coin and athlete rows
-- belong to the features that own those wallets.
local BATTLE_POINTS_TYPE = 1
local VALUE_MARKER = FieldMessageText.STRVAR_1 + 53

---@class FieldPointsBox
---@field private _messages table<string, unknown>? the field message provider
---@field private _wallet table<string, unknown>? borrowed live battle-point owner
---@field private _state FieldPointsBox.Snapshot? visible window state; nil when closed
local FieldPointsBox = {}
FieldPointsBox.__index = FieldPointsBox

FieldPointsBox.WIDTH = WIDTH_TILES * TILE_SIZE
FieldPointsBox.HEIGHT = HEIGHT_TILES * TILE_SIZE
FieldPointsBox.BATTLE_POINTS_TYPE = BATTLE_POINTS_TYPE

---@class FieldPointsBox.Snapshot
---@field visible boolean
---@field tileX integer? source tile column, zero-based
---@field tileY integer? source tile row, zero-based
---@field displayedValue integer? the balance the last show/update captured
---@field valueText string? the five-cell right-aligned value field
---@field text string? the fully expanded source row the frame prints

-- The message-provider capability the window borrows, and the wallet it reads
-- through the live owner. Both are named contracts so the injected owners stay
-- visible at the call sites.
---@class FieldPointsBox.MessageProvider
---@field acquireBank fun(self: table<string, unknown>, bankId: integer): table<string, unknown>?
---@field get fun(self: table<string, unknown>, bankId: integer, messageId: integer): table<string, unknown>?
---@field releaseBank fun(self: table<string, unknown>, bankId: integer)

---@class FieldPointsBox.Wallet
---@field balance fun(self: FieldPointsBox.Wallet): integer

---@param opts { messages: table<string, unknown>?, battlePoints: table<string, unknown>? }
---@return FieldPointsBox
function FieldPointsBox.new(opts)
  assert(type(opts) == "table", "the points box needs its composition options")
  return setmetatable({
    _messages = opts.messages,
    _wallet = opts.battlePoints,
    _state = nil,
  }, FieldPointsBox)
end

---@param valueType unknown
---@return integer
local function checkType(valueType)
  if type(valueType) ~= "number" or valueType % 1 ~= 0 then
    Errors.raise(ScriptErrors.SCRIPT_POINTS_BOX_TYPE_UNSUPPORTED, "the points window needs a source type", {
      valueType = valueType,
    })
  end
  if valueType ~= BATTLE_POINTS_TYPE then
    Errors.raise(
      ScriptErrors.SCRIPT_POINTS_BOX_TYPE_UNSUPPORTED,
      "this points window owns the battle-point row only",
      { valueType = valueType }
    )
  end
  ---@cast valueType integer
  return valueType
end

---@param value unknown
---@param axis string
---@return integer
local function sourceTile(value, axis)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the points window needs a source tile " .. axis, {
      tile = value,
    })
  end
  ---@cast value number
  -- The source window takes u8 tile coordinates even though ScriptGetVar reads
  -- a u16 value.
  return (value % 0x100) --[[@as integer]]
end

---@param messageId integer
---@return table<string, unknown>
function FieldPointsBox:_readMessage(messageId)
  local messages = self._messages
  if type(messages) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the points window requires the message provider", {})
  end
  ---@cast messages FieldPointsBox.MessageProvider
  local acquire = messages.acquireBank
  local get = messages.get
  local release = messages.releaseBank
  if type(acquire) ~= "function" or type(get) ~= "function" or type(release) ~= "function" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the points window requires the message provider", {})
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

-- The source value row expands the balance into the message's battle-point
-- marker as a five-cell right-aligned field. A template without that marker
-- has no field for the balance, so it faults instead of printing the
-- template's glyphs as the amount.
---@param template table<string, unknown>
---@param balance integer
---@return string valueText, string text
local function expandValueRow(template, balance)
  local valueText = string.format("%" .. VALUE_DIGITS .. "d", balance)
  local parts = {}
  local substituted = false
  local tokens = template.tokens --[[@as { kind: string?, control: integer?, text: string? }[] ]]
  assert(type(tokens) == "table", "the points window value message carries tokens")
  for _, token in ipairs(tokens) do
    if token.kind == "substitution" and token.control == VALUE_MARKER then
      parts[#parts + 1] = valueText
      substituted = true
    elseif token.kind == "glyph" and type(token.text) == "string" then
      parts[#parts + 1] = token.text
    end
  end
  if not substituted then
    Errors.raise(
      ScriptErrors.SCRIPT_POINTS_BOX_MESSAGE_INVALID,
      "the points value message carries no battle-point marker",
      { bankId = template.bankId, messageId = template.messageId }
    )
  end
  return valueText, table.concat(parts)
end

---@return integer
function FieldPointsBox:_liveBalance()
  local wallet = self._wallet
  if type(wallet) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the points window requires the live wallet", {})
  end
  ---@cast wallet FieldPointsBox.Wallet
  if type(wallet.balance) ~= "function" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the points window requires the live wallet", {})
  end
  local balance = wallet:balance()
  if type(balance) ~= "number" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the points window requires the live wallet", {})
  end
  return balance
end

-- ScrCmd_ShowPointsBox: PointsBox_New opens the frame and paints it once.
---@param valueType integer raw source type byte
---@param tileX integer script value operand
---@param tileY integer script value operand
function FieldPointsBox:show(valueType, tileX, tileY)
  local kind = checkType(valueType)
  if self._state ~= nil then
    Errors.raise(ScriptErrors.SCRIPT_POINTS_BOX_WINDOW_STATE, "the points window is already open", {
      valueType = kind,
    })
  end
  local tileColumn = sourceTile(tileX, "column")
  local tileRow = sourceTile(tileY, "row")
  local template = self:_readMessage(VALUE_MESSAGE)
  local balance = self:_liveBalance()
  local valueText, text = expandValueRow(template, balance)
  self._state = {
    visible = true,
    tileX = tileColumn,
    tileY = tileRow,
    displayedValue = balance,
    valueText = valueText,
    text = text,
  }
end

-- ScrCmd_UpdatePointsBox: PointsBox_Update is the only repaint; wallet changes
-- while the window is open never reach the drawn snapshot.
---@param valueType integer raw source type byte
function FieldPointsBox:update(valueType)
  local kind = checkType(valueType)
  local state = self._state
  if state == nil then
    Errors.raise(ScriptErrors.SCRIPT_POINTS_BOX_WINDOW_STATE, "the points window is not open", {
      valueType = kind,
    })
  end
  local template = self:_readMessage(VALUE_MESSAGE)
  local balance = self:_liveBalance()
  local valueText, text = expandValueRow(template, balance)
  state.displayedValue = balance
  state.valueText = valueText
  state.text = text
end

-- ScrCmd_HidePointsBox: PointsBox_Delete drops the one open frame.
function FieldPointsBox:hide()
  if self._state == nil then
    Errors.raise(ScriptErrors.SCRIPT_POINTS_BOX_WINDOW_STATE, "the points window is not open", {})
  end
  self._state = nil
end

---@return FieldPointsBox.Snapshot
function FieldPointsBox:snapshot()
  local state = self._state
  if state == nil then
    return { visible = false }
  end
  return {
    visible = true,
    tileX = state.tileX,
    tileY = state.tileY,
    displayedValue = state.displayedValue,
    valueText = state.valueText,
    text = state.text,
  }
end

-- Field teardown closes the transient window exactly once; disposing a closed
-- box is a no-op.
function FieldPointsBox:dispose()
  self._state = nil
end

return FieldPointsBox
