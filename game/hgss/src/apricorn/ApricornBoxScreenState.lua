-- Owns one browse or Kurt-select Box session and its message-bank lease.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")
local ApricornBoxController = require("libs.hgss.src.ui.ApricornBoxController")
local ApricornBoxInterface = require("game.hgss.src.field.ApricornBoxInterface")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

---@class ApricornBoxScreenState
---@field private _controller ApricornBoxController
---@field private _session ApplicationPresentation
---@field private _measureDisplay fun(): DisplayMeasurement
---@field private _manifest table<string, unknown>
---@field private _names string[]
---@field private _actionLabels string[]
---@field private _flowTemplates table<string, FieldMessageProvider.MessageTemplate>
---@field private _messageProvider FieldMessageProvider
---@field private _fontDef FieldMessageText.FontDef
---@field private _messageBankId integer
---@field private _animationTick integer
---@field private _disposed boolean
local ApricornBoxScreenState = {}
ApricornBoxScreenState.__index = ApricornBoxScreenState

---@param opts table<string, unknown>
---@return ApricornBoxScreenState
function ApricornBoxScreenState.new(opts)
  assert(type(opts) == "table", "Apricorn Box screen options are records")
  local manifest = assert(opts.manifest, "Apricorn Box screen requires its generated manifest")
  assert(ApricornBoxAssetCache.isManifestValid(manifest), "Apricorn Box screen requires a valid generated manifest")
  local fontDef = assert(opts.fontDef, "Apricorn Box formatting requires the generated field font")
  local uiManifest = assert(opts.uiManifest, "Apricorn Box prompt requires the generated field UI manifest")
  local messageBankId = manifest.messageBankId
  local messageProvider = assert(opts.messageProvider, "Apricorn Box screen requires the field message provider")
  local bank, bankErr = messageProvider:acquireBank(messageBankId)
  assert(bank ~= nil, "Apricorn Box source message bank is ready: " .. tostring(bankErr))
  local names = {}
  local actionLabels = {}
  local flowTemplates = {}
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
      flowTemplates[phase] = assert(messageProvider:get(manifest.messageBankId, messageId), "Box flow message exists")
    end
  end)
  if not loaded then
    messageProvider:releaseBank(messageBankId)
    error(loadErr, 0)
  end
  local controller
  local session
  local constructed, constructionErr = pcall(function()
    controller = ApricornBoxController.new({
      mode = assert(opts.mode),
      service = assert(opts.service),
      effect = assert(opts.effect, "Apricorn Box uses the composed field sound port"),
      promptShape = assert(
        uiManifest.yesNoPrompt and uiManifest.yesNoPrompt.shapes and uiManifest.yesNoPrompt.shapes.compact,
        "Apricorn Box requires generated compact Yes/No art geometry"
      ),
      promptPlacement = {
        x = manifest.controls.actions.kurtSelect.x * 8,
        y = manifest.controls.actions.kurtSelect.y * 8,
        shape = "compact",
        initialSelection = "yes",
      },
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
    messageProvider:releaseBank(messageBankId)
    error(constructionErr, 0)
  end
  return setmetatable({
    _controller = assert(controller),
    _session = assert(session),
    _measureDisplay = assert(opts.measureDisplay),
    _manifest = manifest,
    _names = names,
    _actionLabels = actionLabels,
    _flowTemplates = flowTemplates,
    _messageProvider = messageProvider,
    _fontDef = fontDef,
    _messageBankId = messageBankId,
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
  view.selectedName = assert(self._names[view.selectedIndex], "the selected Box row has a source message")
  if view.mode == "kurt_select" then
    if view.phase == "confirm" then
      local template = assert(self._flowTemplates.confirmation, "Kurt confirmation has source message 39")
      local function quantityResolver(control, args)
        if control ~= FieldMessageText.STRVAR_1 + 51 or #args ~= 2 or args[1] ~= 1 or args[2] ~= 0 then
          return nil
        end
        return assert(FieldMessageProvider.asciiGlyphTokens(tostring(view.quantity), self._fontDef))
      end
      local function nameResolver(control, args)
        if control ~= FieldMessageText.STRVAR_1 + 8 or #args ~= 2 or args[1] ~= 0 or args[2] ~= 0 then
          return nil
        end
        return assert(FieldMessageProvider.asciiGlyphTokens(view.selectedName, self._fontDef))
      end
      local formatted = self._messageProvider:format(template, {}, {
        [FieldMessageText.STRVAR_1 + 51] = quantityResolver,
        [FieldMessageText.STRVAR_1 + 8] = nameResolver,
      })
      assert(not formatted.hadUnresolvedSubstitutions, "Box confirmation has only resolved source substitutions")
      view.confirmationText = formatted.text
      view.flowMessage = formatted.text
    elseif view.phase == "quantity" then
      view.flowMessage = assert(self._flowTemplates.quantity).text
    elseif view.phase == "rows" or view.phase == "selection_delay" or view.phase == "actions" then
      view.flowMessage = assert(self._flowTemplates.selection).text
    end
  end
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
  self._messageProvider:releaseBank(self._messageBankId)
end

return ApricornBoxScreenState
