-- Owns one browse or Kurt-select Box session and its message-bank lease.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")
local ApricornBoxController = require("libs.hgss.src.ui.ApricornBoxController")
local ApricornBoxInterface = require("game.hgss.src.field.ApricornBoxInterface")

---@class ApricornBoxScreenState
---@field private _controller ApricornBoxController
---@field private _session ApplicationPresentation
---@field private _measureDisplay fun(): DisplayMeasurement
---@field private _manifest table<string, unknown>
---@field private _names string[]
---@field private _actionLabels string[]
---@field private _flowMessages table<string, string>
---@field private _messageProvider FieldMessageProvider
---@field private _animationTick integer
---@field private _disposed boolean
local ApricornBoxScreenState = {}
ApricornBoxScreenState.__index = ApricornBoxScreenState

local MESSAGE_BANK = 27

---@param opts table<string, unknown>
---@return ApricornBoxScreenState
function ApricornBoxScreenState.new(opts)
  assert(type(opts) == "table", "Apricorn Box screen options are records")
  local manifest = assert(opts.manifest, "Apricorn Box screen requires its generated manifest")
  assert(ApricornBoxAssetCache.isManifestValid(manifest), "Apricorn Box screen requires a valid generated manifest")
  local messageProvider = assert(opts.messageProvider, "Apricorn Box screen requires the field message provider")
  local bank, bankErr = messageProvider:acquireBank(MESSAGE_BANK)
  assert(bank ~= nil, "Apricorn Box source message bank is ready: " .. tostring(bankErr))
  local names = {}
  local actionLabels = {}
  local flowMessages = {}
  local loaded, loadErr = pcall(function()
    for index, row in ipairs(manifest.rows) do
      names[index] =
        assert(messageProvider:get(manifest.messageBankId, row.nameMessageId), "Apricorn name message exists").text
    end
    for _, messageId in ipairs(manifest.actionMessageIds) do
      actionLabels[messageId] =
        assert(messageProvider:get(manifest.messageBankId, messageId), "Box action label exists").text
    end
    for phase, messageId in pairs(manifest.flowMessageIds) do
      flowMessages[phase] =
        assert(messageProvider:get(manifest.messageBankId, messageId), "Box flow message exists").text
    end
  end)
  if not loaded then
    messageProvider:releaseBank(MESSAGE_BANK)
    error(loadErr, 0)
  end
  local controller
  local session
  local constructed, constructionErr = pcall(function()
    controller = ApricornBoxController.new({
      mode = assert(opts.mode),
      service = assert(opts.service),
      effect = assert(opts.effect, "Apricorn Box uses the composed field sound port"),
      apricornKeys = (function()
        local keys = {}
        for index, row in ipairs(manifest.rows) do
          keys[index] = row.apricornKey
        end
        return keys
      end)(),
    })
    session = ApplicationPresentation.new(ApricornBoxInterface.defaults(), opts.overrides)
    session:resolve(assert(opts.measureDisplay, "Apricorn Box needs display measurement")(), {})
  end)
  if not constructed then
    if controller ~= nil then
      controller:dispose()
    end
    if session ~= nil then
      session:dispose()
    end
    messageProvider:releaseBank(MESSAGE_BANK)
    error(constructionErr, 0)
  end
  return setmetatable({
    _controller = assert(controller),
    _session = assert(session),
    _measureDisplay = assert(opts.measureDisplay),
    _manifest = manifest,
    _names = names,
    _actionLabels = actionLabels,
    _flowMessages = flowMessages,
    _messageProvider = messageProvider,
    _animationTick = 0,
    _disposed = false,
  }, ApricornBoxScreenState)
end

---@param uiInput table[] ordered semantic events
function ApricornBoxScreenState:updateFixed(uiInput)
  assert(not self._disposed, "a disposed Apricorn Box screen cannot update")
  local mapped = self._session:mapInput(uiInput, self:_view())
  self._controller:updateFixed(mapped)
  self._animationTick = self._animationTick + 1
  self._session:resolve(self._measureDisplay(), self:_view())
end

-- The menu flow calls this before replacing a live child; invalidating the
-- session capture prevents an old pointer release from reaching its successor.
function ApricornBoxScreenState:cancelPointerCapture()
  assert(not self._disposed, "a disposed Apricorn Box screen has no pointer capture")
  self._session:cancelPointers()
end

function ApricornBoxScreenState:_view()
  local view = self._controller:status()
  view.rowHitboxes = self._manifest.rowHitboxes
  view.controls = self._manifest.controls
  view.actionLabels = self._actionLabels
  view.flowMessages = self._flowMessages
  view.selectedName = assert(self._names[view.selectedIndex], "the selected Box row has a source message")
  view.flowMessage = view.phase == "confirm" and self._flowMessages.confirmation
    or view.phase == "quantity" and self._flowMessages.quantity
    or view.phase ~= "browse" and self._flowMessages.selection
  view.animationTick = self._animationTick
  return view
end

---@return table<string, unknown>
function ApricornBoxScreenState:status()
  assert(not self._disposed, "a disposed Apricorn Box screen has no status")
  local view = self:_view()
  view.presentation = self._session:plan()
  return view
end

---@return table<string, unknown>?
function ApricornBoxScreenState:takeResult()
  assert(not self._disposed, "a disposed Apricorn Box screen returns no result")
  return self._controller:takeResult()
end

---@return nil the screen publishes only its close or selected result
function ApricornBoxScreenState:takeIntent()
  assert(not self._disposed, "a disposed Apricorn Box screen publishes no intent")
  return nil
end

function ApricornBoxScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._session:dispose()
  self._controller:dispose()
  self._messageProvider:releaseBank(MESSAGE_BANK)
end

return ApricornBoxScreenState
