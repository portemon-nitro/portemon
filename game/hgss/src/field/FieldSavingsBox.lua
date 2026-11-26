-- The transient source savings box: one non-modal field window that prints
-- Mom's deposited savings and the player's held money from message bank 191.
-- The source opens a 16x8-tile frame at a tile coordinate, prints the two row
-- labels, repaints both balances only on an explicit update, and deletes the
-- window on hide (src/field/script_menu.c::SavingsBox_New/SavingsBox_Update/
-- SavingsBox_Delete, driven by src/field/headbutt.c::ScrCmd_ShowSavingsBox/
-- ScrCmd_UpdateSavingsBox). Row labels are bank 191 message 330 "DEPOSITED
-- MONEY" at pixel row 0 and message 331 "HELD MONEY" at pixel row 32; the two
-- balances print message 332 "${STRVAR_1 55, 0, 0}" right-aligned inside the
-- 128-pixel frame at pixel rows 16 and 48. The box owns presentation state
-- only: it borrows the live profile for the held money and the live phone
-- state for the savings, and never stores a second wallet. Pure presentation
-- state, no love dependency; the field draw path renders the snapshot.

local Errors = require("libs.errors.src.Errors")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local ScriptErrors = require("libs.script.src.errors")

local MESSAGE_BANK = 191
local SAVINGS_LABEL_MESSAGE = 330
local MONEY_LABEL_MESSAGE = 331
local VALUE_MESSAGE = 332
-- SavingsBox_Update expands the balance into the money marker as an unpadded
-- decimal and then draws it at `128 - width(string)`, so the value lands
-- right-aligned inside the frame's 128 pixels.
local VALUE_MARKER = FieldMessageText.STRVAR_1 + 55
local TILE_SIZE = 8
local WIDTH_TILES = 16
local HEIGHT_TILES = 8
local LABEL_ROW_HEIGHT = 32
local VALUE_ROW_HEIGHT = 16

---@class FieldSavingsBox
---@field private _profile table<string, unknown>? borrowed live player profile
---@field private _pokegearState table<string, unknown>? borrowed live phone state
---@field private _messages table<string, unknown>? the field message provider
---@field private _state FieldSavingsBox.Snapshot? visible window state; nil when closed
---@field private _template table<string, unknown>? the source money value template
local FieldSavingsBox = {}
FieldSavingsBox.__index = FieldSavingsBox

-- The source frame is a 16x8-tile window on the main field display.
FieldSavingsBox.WIDTH = WIDTH_TILES * TILE_SIZE
FieldSavingsBox.HEIGHT = HEIGHT_TILES * TILE_SIZE

---@class FieldSavingsBox.Row
---@field label string the row's source label
---@field labelY integer pixel row of the row's label inside the frame
---@field y integer pixel row of the row's balance inside the frame
---@field value integer the balance captured by the last show/update
---@field text string the expanded source value row

---@class FieldSavingsBox.Snapshot
---@field visible boolean
---@field tileX integer? source tile column, zero-based
---@field tileY integer? source tile row, zero-based
---@field rows FieldSavingsBox.Row[]? the two balance rows in source order

-- The message-provider capability the box borrows, the wallet it reads through
-- the live player profile, and the savings balance it reads through the live
-- phone state. All three are named contracts so the injected owners stay
-- visible at the call sites.
---@class FieldSavingsBox.MessageProvider
---@field acquireBank fun(self: table<string, unknown>, bankId: integer): table<string, unknown>?
---@field get fun(self: table<string, unknown>, bankId: integer, messageId: integer): table<string, unknown>?
---@field releaseBank fun(self: table<string, unknown>, bankId: integer)

---@class FieldSavingsBox.Wallet
---@field money integer

---@class FieldSavingsBox.SavingsOwner
---@field readPhone fun(self: table<string, unknown>): table<string, unknown>

---@param opts { profile: table<string, unknown>?, pokegearState: table<string, unknown>?, messages: table<string, unknown>? }
---@return FieldSavingsBox
function FieldSavingsBox.new(opts)
  assert(type(opts) == "table", "the savings box needs its composition options")
  return setmetatable({
    _profile = opts.profile,
    _pokegearState = opts.pokegearState,
    _messages = opts.messages,
    _state = nil,
    _template = nil,
  }, FieldSavingsBox)
end

---@param messageId integer
---@return table<string, unknown>
function FieldSavingsBox:_readMessage(messageId)
  local messages = self._messages
  if type(messages) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the savings box requires the message provider", {})
  end
  ---@cast messages FieldSavingsBox.MessageProvider
  local acquire = messages.acquireBank
  local get = messages.get
  local release = messages.releaseBank
  if type(acquire) ~= "function" or type(get) ~= "function" or type(release) ~= "function" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the savings box requires the message provider", {})
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

-- The source value row expands the balance into the money marker. A template
-- without that marker has no field for the balance, so it faults instead of
-- printing the template's glyphs as the amount.
---@param template table<string, unknown>
---@param money integer
---@return string
local function expandMoney(template, money)
  local digits = tostring(money)
  local parts = {}
  local substituted = false
  local tokens = template.tokens --[[@as { kind: string?, control: integer?, text: string? }[] ]]
  assert(type(tokens) == "table", "the savings box value message carries tokens")
  for _, token in ipairs(tokens) do
    if token.kind == "substitution" and token.control == VALUE_MARKER then
      parts[#parts + 1] = digits
      substituted = true
    elseif token.kind == "glyph" and type(token.text) == "string" then
      parts[#parts + 1] = token.text
    end
  end
  if not substituted then
    Errors.raise(ScriptErrors.SCRIPT_MONEY_BOX_MESSAGE_INVALID, "the savings value message carries no money marker", {
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
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the savings box needs a source tile " .. axis, {
      tile = value,
    })
  end
  ---@cast value number
  -- The source window takes u8 tile coordinates even though ScriptGetVar
  -- reads a u16 value.
  return (value % 0x100) --[[@as integer]]
end

---@return integer money the held wallet
---@return integer savings Mom's deposited savings
function FieldSavingsBox:_liveBalances()
  local profile = self._profile
  if type(profile) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the savings box requires the live player profile", {})
  end
  ---@cast profile FieldSavingsBox.Wallet
  local money = profile.money
  if type(money) ~= "number" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the savings box requires the live player profile", {})
  end
  local state = self._pokegearState
  if type(state) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the savings box requires the live phone state", {})
  end
  ---@cast state FieldSavingsBox.SavingsOwner
  local phone = state:readPhone()
  local mom = type(phone) == "table" and phone.mom or nil
  local savings = type(mom) == "table" and mom.balance or nil
  if type(savings) ~= "number" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the savings box requires the live phone state", {})
  end
  return money, --[[@as integer]]
    savings --[[@as integer]]
end

---@param template table<string, unknown>
---@return FieldSavingsBox.Row[]
function FieldSavingsBox:_rows(template)
  local money, savings = self:_liveBalances()
  local savingsLabel = self:_readMessage(SAVINGS_LABEL_MESSAGE)
  local moneyLabel = self:_readMessage(MONEY_LABEL_MESSAGE)
  assert(type(savingsLabel.text) == "string", "the savings label message carries its text")
  assert(type(moneyLabel.text) == "string", "the money label message carries its text")
  return {
    {
      label = savingsLabel.text --[[@as string]],
      labelY = 0,
      y = VALUE_ROW_HEIGHT,
      value = savings,
      text = expandMoney(template, savings),
    },
    {
      label = moneyLabel.text --[[@as string]],
      labelY = LABEL_ROW_HEIGHT,
      y = LABEL_ROW_HEIGHT + VALUE_ROW_HEIGHT,
      value = money,
      text = expandMoney(template, money),
    },
  }
end

-- ScrCmd_ShowSavingsBox: SavingsBox_New opens the frame, prints both labels
-- and paints both balances once.
---@param tileX integer script value operand
---@param tileY integer script value operand
function FieldSavingsBox:show(tileX, tileY)
  if self._state ~= nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the savings box window is already open", {})
  end
  local tileColumn = sourceTile(tileX, "column")
  local tileRow = sourceTile(tileY, "row")
  local template = self:_readMessage(VALUE_MESSAGE)
  self._state = {
    visible = true,
    tileX = tileColumn,
    tileY = tileRow,
    rows = self:_rows(template),
  }
  self._template = template
end

-- ScrCmd_UpdateSavingsBox: the only repaint of both balances. Wallet or phone
-- changes while the window is open never reach the drawn snapshot.
function FieldSavingsBox:update()
  local state = self._state
  if state == nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the savings box window is not open", {})
  end
  state.rows = self:_rows(assert(self._template))
end

-- ScrCmd_HideSavingsBox: SavingsBox_Delete drops the one open frame.
function FieldSavingsBox:hide()
  if self._state == nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the savings box window is not open", {})
  end
  self._state = nil
  self._template = nil
end

---@return FieldSavingsBox.Snapshot
function FieldSavingsBox:snapshot()
  local state = self._state
  if state == nil then
    return { visible = false }
  end
  local rows = {}
  for index, row in ipairs(assert(state.rows)) do
    rows[index] = { label = row.label, labelY = row.labelY, y = row.y, value = row.value, text = row.text }
  end
  return {
    visible = true,
    tileX = state.tileX,
    tileY = state.tileY,
    rows = rows,
  }
end

-- Field teardown closes the transient window exactly once; disposing a closed
-- box is a no-op.
function FieldSavingsBox:dispose()
  self._state = nil
  self._template = nil
end

return FieldSavingsBox
