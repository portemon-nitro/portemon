-- Owns one browse or Kurt-select Box session and its message-bank lease.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
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
---@field private _plurals string[]
---@field private _descriptions string[]
---@field private _titleText string
---@field private _closeText string
---@field private _browseHeaderText string
---@field private _panelMessageText string
---@field private _actionLabels string[]
---@field private _flowTemplates table<string, FieldMessageProvider.MessageTemplate>
---@field private _messageProvider FieldMessageProvider
---@field private _fontDef FieldMessageText.FontDef
---@field private _messageBankId integer
---@field private _pluralBankId integer
---@field private _animationTick integer
---@field private _disposed boolean
local ApricornBoxScreenState = {}
ApricornBoxScreenState.__index = ApricornBoxScreenState

---@param opts table<string, unknown>
---@return ApricornBoxScreenState
function ApricornBoxScreenState.new(opts)
  assert(type(opts) == "table", "Apricorn Box screen options are records")
  local manifest = assert(opts.manifest, "Apricorn Box screen requires its generated manifest")
  local fontDef = assert(opts.fontDef, "Apricorn Box formatting requires the generated field font")
  local uiManifest = assert(opts.uiManifest, "Apricorn Box prompt requires the generated field UI manifest")
  local messageBankId = manifest.messageBankId
  local pluralBankId = assert(manifest.pluralBankId, "the Box manifest carries its plural name bank")
  local messageProvider = assert(opts.messageProvider, "Apricorn Box screen requires the field message provider")
  local bank, bankErr = messageProvider:acquireBank(messageBankId)
  assert(bank ~= nil, "Apricorn Box source message bank is ready: " .. tostring(bankErr))
  local pluralBank, pluralBankErr = messageProvider:acquireBank(pluralBankId)
  if pluralBank == nil then
    messageProvider:releaseBank(messageBankId)
    error("Apricorn Box plural name bank is ready: " .. tostring(pluralBankErr), 0)
  end
  local names = {}
  local plurals = {}
  local descriptions = {}
  local actionLabels = {}
  local flowTemplates = {}
  local titleText, closeText, browseHeaderText, panelMessageText
  local loaded, loadErr = pcall(function()
    for index, row in ipairs(manifest.rows) do
      names[index] =
        assert(messageProvider:get(manifest.messageBankId, row.nameMessageId), "Apricorn name message exists").text
      plurals[index] = assert(
        messageProvider:get(pluralBankId, assert(row.itemId, "the Box row carries its native item identity")),
        "Apricorn plural name message exists"
      ).text
      descriptions[index] = assert(
        messageProvider:get(
          manifest.messageBankId,
          assert(row.descriptionMessageId, "the Box row carries its source description message")
        ),
        "Apricorn description message exists"
      ).text
    end
    for _, messageId in ipairs(manifest.actionMessageIds) do
      actionLabels[messageId] =
        assert(messageProvider:get(manifest.messageBankId, messageId), "Box action label exists").text
    end
    for phase, messageId in pairs(manifest.flowMessageIds) do
      flowTemplates[phase] = assert(messageProvider:get(manifest.messageBankId, messageId), "Box flow message exists")
    end
    titleText = assert(
      messageProvider:get(
        manifest.messageBankId,
        assert(manifest.titleMessageId, "the Box manifest carries its source title message")
      ),
      "Box title message exists"
    ).text
    closeText = assert(
      messageProvider:get(
        manifest.messageBankId,
        assert(manifest.closeMessageId, "the Box manifest carries its source close message")
      ),
      "Box close message exists"
    ).text
    browseHeaderText = assert(
      messageProvider:get(
        manifest.messageBankId,
        assert(manifest.browseHeaderMessageId, "the Box manifest carries its browse header message")
      ),
      "Box browse header exists"
    ).text
    panelMessageText = assert(
      messageProvider:get(
        manifest.messageBankId,
        assert(manifest.panelMessageId, "the Box manifest carries its quantity panel message")
      ),
      "Box quantity panel message exists"
    ).text
  end)
  if not loaded then
    messageProvider:releaseBank(pluralBankId)
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
    messageProvider:releaseBank(pluralBankId)
    messageProvider:releaseBank(messageBankId)
    error(constructionErr, 0)
  end
  return setmetatable({
    _controller = assert(controller),
    _session = assert(session),
    _measureDisplay = assert(opts.measureDisplay),
    _manifest = manifest,
    _names = names,
    _plurals = plurals,
    _descriptions = descriptions,
    _titleText = titleText,
    _closeText = closeText,
    _browseHeaderText = browseHeaderText,
    _panelMessageText = panelMessageText,
    _actionLabels = actionLabels,
    _flowTemplates = flowTemplates,
    _messageProvider = messageProvider,
    _fontDef = fontDef,
    _messageBankId = messageBankId,
    _pluralBankId = pluralBankId,
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
  view.titleText = assert(self._titleText, "the Box view carries its source title")
  view.closeText = assert(self._closeText, "the Box view carries its source close label")
  view.panelMessage = assert(self._panelMessageText, "the Box view carries its quantity panel message")
  local selectedStock = assert(view.rows[view.selectedIndex], "selected stock belongs to one canonical row")
  if selectedStock.quantity > 0 then
    view.descriptionText =
      assert(self._descriptions[view.selectedIndex], "the selected Box row has a source description")
  else
    view.descriptionText = ""
  end
  if view.mode == "browse" then
    view.headerText = assert(self._browseHeaderText, "the browse view carries its source header")
  elseif view.mode == "kurt_select" then
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
        -- Retail pluralizes the confirm name past one Apricorn through the
        -- item plural bank; a single Apricorn keeps the singular label.
        local name = view.selectedName
        if view.quantity > 1 then
          name = assert(self._plurals[view.selectedIndex], "the selected Box row has a source plural name")
        end
        return assert(FieldMessageProvider.asciiGlyphTokens(name, self._fontDef))
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
    elseif
      view.phase == "rows"
      or view.phase == "selection_delay"
      or view.phase == "row_return_delay"
      or view.phase == "actions"
    then
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
  self._messageProvider:releaseBank(self._pluralBankId)
  self._messageProvider:releaseBank(self._messageBankId)
end

return ApricornBoxScreenState
