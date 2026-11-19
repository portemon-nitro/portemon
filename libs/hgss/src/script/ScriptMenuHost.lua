-- Script menu host resolves source-faithful script menu builders into
-- controller-ready requests. Builders belong to their ScriptInstance; this
-- service has no script-persistent state or love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local MenuProtocol = require("libs.assets.src.MenuProtocol")

---@class ScriptMenuHost
---@field _provider FieldMessageProvider
---@field _resolveText fun(message: unknown): table<string, unknown>|nil
---@field _substitutionResolvers fun(template: table<string, unknown>, textArgs: table<string, unknown>): table<string, function>
local ScriptMenuHost = {}
ScriptMenuHost.__index = ScriptMenuHost

---@param value unknown
---@param name string
local function assertInteger(value, name)
  assert(
    type(value) == "number"
      and value == value
      and value ~= math.huge
      and value ~= -math.huge
      and value == math.floor(value),
    name .. " must be a finite integer"
  )
end

---@param source unknown
---@return integer
local function messageBank(source)
  if source == "standard" then
    return MenuProtocol.STANDARD_MESSAGE_BANK
  end
  assert(type(source) == "table" and source.kind == "script", "menu message source is invalid")
  assertInteger(source.bank, "script menu message bank")
  return source.bank
end

---@param spec table<string, unknown>
---@return boolean
local function isMultichoice(spec)
  if spec.kind == nil then
    return false
  end
  assert(spec.kind == "multichoice", "script menu kind is invalid")
  return true
end

---@param self ScriptMenuHost
---@param source unknown
---@param messageId integer
---@param textArgs table<string, unknown> buffered script text by slot
---@return table<string, unknown>
local function resolveMessage(self, source, messageId, textArgs)
  local bankId = messageBank(source)
  local acquired, bankErr = self._provider:acquireBank(bankId)
  if not acquired then
    local context = { bankId = bankId, messageId = messageId, cause = bankErr and bankErr.context }
    ---@cast context Errors.Context
    Errors.raise(ScriptErrors.SCRIPT_MENU_MESSAGE_UNRESOLVED, "menu message bank is unavailable", context)
  end
  local template, templateErr = self._provider:get(bankId, messageId)
  if not template then
    self._provider:releaseBank(bankId)
    local context = { bankId = bankId, messageId = messageId, cause = templateErr and templateErr.context }
    ---@cast context Errors.Context
    Errors.raise(ScriptErrors.SCRIPT_MENU_MESSAGE_UNRESOLVED, "menu message is unavailable", context)
  end
  ---@cast template table<string, unknown>
  local ok, formatted = pcall(function()
    return self._provider:format(template, {}, self._substitutionResolvers(template, textArgs))
  end)
  self._provider:releaseBank(bankId)
  if not ok then
    error(formatted)
  end
  return formatted
end

local function resolveSemanticText(self, message)
  if type(message) == "table" or (type(message) == "string" and message:match("^msg%.hgss%.%d+%.%d+$")) then
    local resolveText = self._resolveText
    if resolveText == nil then
      local context = { message = message }
      ---@cast context Errors.Context
      Errors.raise(
        ScriptErrors.SCRIPT_MENU_MESSAGE_UNRESOLVED,
        "semantic menu message resolution is unavailable",
        context
      )
    end
    ---@cast resolveText fun(message: unknown): table<string, unknown>|nil
    local text = resolveText(message)
    if type(text) ~= "table" or type(text.text) ~= "string" then
      local context = { message = message }
      ---@cast context Errors.Context
      Errors.raise(
        ScriptErrors.SCRIPT_MENU_MESSAGE_UNRESOLVED,
        "semantic menu message did not resolve to text",
        context
      )
    end
    return text
  end
  return { text = message }
end

---@param opts table<string, unknown> { provider, substitutionResolvers, resolveText?: fun(message: unknown): table<string, unknown> }
---@return ScriptMenuHost
function ScriptMenuHost.new(opts)
  assert(type(opts) == "table" and opts.provider, "script menu host requires a message provider")
  assert(type(opts.substitutionResolvers) == "function", "script menu host requires its substitution resolvers")
  assert(
    opts.resolveText == nil or type(opts.resolveText) == "function",
    "script menu text resolver must be a function"
  )
  return setmetatable({
    _provider = opts.provider,
    _resolveText = opts.resolveText,
    _substitutionResolvers = opts.substitutionResolvers,
  }, ScriptMenuHost)
end

-- Publishes one semantic mod menu without entering the imported-HGSS builder
-- state. A project may supply its dialogue resolver; bare strings remain
-- useful as local text in isolated tools and tests.
---@param spec table<string, unknown>
---@return unknown menuController
function ScriptMenuHost:choose(spec)
  assert(type(spec) == "table" and type(spec.items) == "table", "semantic menu specification is invalid")
  local items = {}
  for luaIndex, item in ipairs(spec.items) do
    local text = resolveSemanticText(self, item.text)
    assert(type(text) == "table", "semantic menu text resolver returned an invalid message")
    items[luaIndex] = {
      text = text,
      message = item.text,
      value = item.value,
      metadata = item.metadata,
    }
  end
  return {
    items = items,
    cancellable = spec.cancellable,
    cancelValue = spec.cancelValue,
    initialCursor = spec.initialCursor,
    result = spec.result,
  }
end

-- Starts one source-faithful builder. `messageSource` deliberately retains
-- the distinction between standard/global and current-script message banks.
-- A `multichoice` builder is the foreground framed window family and keeps
-- its native tile position; an absent kind is the auxiliary list family.
---@param spec table<string, unknown>
---@return table<string, unknown> builder
function ScriptMenuHost:beginMenu(spec)
  assert(type(spec) == "table", "script menu specification must be a table")
  messageBank(spec.messageSource)
  assertInteger(spec.initialCursor, "script menu initial cursor")
  assert(type(spec.cancellable) == "boolean", "script menu cancellable must be a boolean")
  assert(spec.result ~= nil, "script menu result target is required")
  local multichoice = isMultichoice(spec)
  local messageSource = spec.messageSource
  if type(messageSource) == "table" then
    messageSource = { kind = "script", bank = messageSource.bank }
  end
  local cancelValue = spec.cancelValue
  local builder = {
    messageSource = messageSource,
    initialCursor = spec.initialCursor,
    cancellable = spec.cancellable,
    -- The retail list menu carries no cancellation value: B selects the
    -- last row, so the list builder leaves cancellation unresolved until
    -- execute() can name the last item value.
    cancelValue = cancelValue,
    result = spec.result,
    items = {},
  }
  if multichoice then
    assertInteger(spec.tileX, "multichoice window column")
    assertInteger(spec.tileY, "multichoice window row")
    assert(spec.cancelValue ~= nil, "a source multichoice keeps its cancellation value")
    builder.kind = "multichoice"
    builder.tileX = spec.tileX
    builder.tileY = spec.tileY
    builder.anchorRight = false
  end
  return builder
end

-- ScrCmd_MultichoiceSetAnchorRight mutates the pending foreground builder; it
-- only applies to the foreground family, so a list builder rejects it instead
-- of silently ignoring the source request.
---@param builder table<string, unknown>|nil imported HGSS menu builder owned by a ScriptInstance
---@param enabled unknown source selector, already decoded to a boolean
function ScriptMenuHost:setAnchorRight(builder, enabled)
  if builder == nil then
    Errors.raise(ScriptErrors.SCRIPT_MENU_NOT_INITIALIZED, "script menu anchor requested without a menu builder")
  end
  ---@cast builder table<string, unknown>
  if builder.kind ~= "multichoice" then
    Errors.raise(ScriptErrors.SCRIPT_MENU_KIND_INVALID, "only a multichoice menu has a foreground anchor")
  end
  assert(type(enabled) == "boolean", "multichoice anchor selector must be a boolean")
  builder.anchorRight = enabled
end

---@param builder table<string, unknown>|nil imported HGSS menu builder owned by a ScriptInstance
---@param item table<string, unknown> { messageId, vanillaMetadata?, value }
function ScriptMenuHost:addItem(builder, item)
  if builder == nil then
    Errors.raise(ScriptErrors.SCRIPT_MENU_NOT_INITIALIZED, "script menu item added without a menu builder")
  end
  ---@cast builder table<string, unknown>
  assert(type(item) == "table", "script menu item must be a table")
  assertInteger(item.messageId, "script menu message id")
  assert(item.value ~= nil, "script menu result value is required")
  local multichoice = builder.kind == "multichoice"
  if multichoice and item.vanillaMetadata ~= nil then
    Errors.raise(ScriptErrors.SCRIPT_MENU_KIND_INVALID, "a foreground multichoice item has no list help metadata")
  end
  if not multichoice and item.vanillaMetadata == nil then
    Errors.raise(ScriptErrors.SCRIPT_MENU_KIND_INVALID, "a list menu item requires its help metadata selector")
  end
  builder.items[#builder.items + 1] = {
    text = { source = builder.messageSource, id = item.messageId },
    vanillaMetadata = item.vanillaMetadata,
    value = item.value,
  }
end

-- Resolves every builder entry before publication. Bank acquisitions are
-- released after each lookup; on any failure no controller request is made
-- and the builder remains available for diagnostic inspection by its caller.
---@param builder table<string, unknown>|nil imported HGSS menu builder owned by a ScriptInstance
---@param textArgs table<string, unknown> the instance's buffered text by slot
---@return unknown menuController
function ScriptMenuHost:execute(builder, textArgs)
  if builder == nil then
    Errors.raise(ScriptErrors.SCRIPT_MENU_NOT_INITIALIZED, "script menu executed without a menu builder")
  end
  ---@cast builder table<string, unknown>
  if #builder.items == 0 then
    Errors.raise(ScriptErrors.SCRIPT_MENU_EMPTY, "script menu has no items")
  end
  local items = {}
  for luaIndex, item in ipairs(builder.items) do
    items[luaIndex] = {
      text = resolveMessage(self, item.text.source, item.text.id, textArgs),
      message = item.text,
      vanillaMetadata = item.vanillaMetadata,
      value = item.value,
    }
  end
  local request = {
    items = items,
    initialCursor = builder.initialCursor,
    cancellable = builder.cancellable,
    cancelValue = builder.cancelValue,
    result = builder.result,
  }
  if builder.kind == "multichoice" then
    -- The foreground window keeps the source geometry and anchor the pending
    -- builder accumulated; the task owns this frozen definition from here.
    request.kind = "multichoice"
    request.tileX = builder.tileX
    request.tileY = builder.tileY
    request.anchorRight = builder.anchorRight == true
  elseif request.cancellable and request.cancelValue == nil then
    -- Source B behavior for a cancellable list menu (touchscreen choice
    -- menu list input): the cursor jumps to the last row and confirms it,
    -- so cancellation carries the last item value instead of a synthetic one.
    request.cancelValue = items[#items].value
  end
  return request
end

return ScriptMenuHost
