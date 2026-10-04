-- Fixed-tick purchase presentation over one borrowed MartService session.

local DialogueLayout = require("libs.hgss.src.ui.DialogueLayout")
local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local MartAssetSchema = require("libs.assets.src.MartAssetSchema")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local YesNoPromptController = require("libs.hgss.src.ui.YesNoPromptController")

---@class MartController
---@field private _session table<string, unknown>
---@field private _manifest table<string, unknown>
---@field private _fontDef table<string, unknown>
---@field private _effect (fun(sequence: string|integer))?
---@field private _frameIndex integer?
---@field private _printer FieldDialogueController
---@field private _prompt YesNoPromptController
---@field private _state string
---@field private _page integer
---@field private _selection integer
---@field private _quantity integer
---@field private _maximum integer
---@field private _animationRemaining integer
---@field private _animationFrame integer
---@field private _controlFeedback { key: string, phase: string, remaining: integer, pending: table<string, unknown> }?
---@field private _amountAnimations table<string, { family: string, elapsed: integer }>
---@field private _pointer { id: string, target: string, x: number, y: number }?
---@field private _quote unknown
---@field private _terms table<string, unknown>?
---@field private _receipt unknown
---@field private _printerTarget string?
---@field private _messageRole string?
---@field private _messagePages DialogueLayout.Result?
---@field private _printerComplete boolean
---@field private _failureReason string?
---@field private _result table<string, unknown>?
---@field private _disposed boolean
local MartController = {}
MartController.__index = MartController

local SOURCE_NAVIGATION = {
  [0] = { 4, 2, 6, 1 },
  [1] = { 8, 3, 0, 7 },
  [2] = { 0, 4, 6, 3 },
  [3] = { 1, 5, 2, 7 },
  [4] = { 2, 0, 6, 5 },
  [5] = { 3, 8, 4, 7 },
  [6] = { 4, 0, 8, 8 },
  [7] = { 4, 0, 8, 8 },
  [8] = { 5, 1, 8, 8 },
}

local DIRECTION_INDEX = { up = 1, down = 2, left = 3, right = 4 }
local SOURCE_CUES = {
  select = "SEQ_SE_DP_SELECT",
  cancel = "SEQ_SE_GS_GEARCANCEL",
  quantity = "SEQ_SE_DP_BAG_004",
}
local PRINTER_STATES =
  { quantity_prompt = true, confirm_prompt = true, success_print = true, bonus_print = true, error_print = true }
local ERROR_ROLES = {
  insufficient_money = "insufficientMoney",
  insufficient_points = "insufficientPoints",
  bag_full = "noRoom",
  apricorn_full = "noRoom",
  seal_full = "sealFull",
  bought_today = "boughtToday",
  already_owned = "alreadyOwned",
  legacy_unavailable = "noRoom",
  stale = "noRoom",
}

local function contains(rect, x, y)
  return x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height
end

local function clipFrame(clip, elapsed)
  local ticks = 0
  for index, frame in ipairs(clip.frames) do
    ticks = ticks + frame.ticks
    if elapsed < ticks then
      return index
    end
  end
  return #clip.frames
end

local function copyTerms(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copyTerms(child)
  end
  return result
end

---@param opts table<string, unknown>
---@return MartController
function MartController.new(opts)
  assert(type(opts) == "table", "mart controller options must be a record")
  local session = assert(opts.session, "mart controller requires the active session")
  assert(
    type(session.view) == "function" and type(session.quoteBuy) == "function",
    "mart controller requires a buy session"
  )
  assert(
    type(session.commit) == "function" and type(session.acknowledge) == "function",
    "mart session has transaction operations"
  )
  local manifest = assert(opts.manifest, "mart controller requires the complete generated manifest")
  MartAssetSchema.assertManifest(manifest)
  local fontDef = assert(opts.fontDef, "mart controller requires the generated field font")
  assert(
    type(fontDef.charmap) == "table" and type(fontDef.glyphs) == "table",
    "mart text needs the field font charmap and glyph metrics"
  )
  local policy = assert(opts.textPolicy, "mart controller requires the player text policy")
  assert(
    type(policy) == "table"
      and type(policy.interGlyphDelay) == "number"
      and policy.interGlyphDelay >= 0
      and policy.interGlyphDelay % 1 == 0
      and type(policy.glyphBudget) == "number"
      and policy.glyphBudget >= 1
      and policy.glyphBudget % 1 == 0
      and type(policy.abAcceleration) == "boolean",
    "mart text policy must carry valid printer timing"
  )
  assert(
    opts.frameIndex == nil or (type(opts.frameIndex) == "number" and opts.frameIndex >= 0 and opts.frameIndex % 1 == 0),
    "mart frame index is a non-negative integer"
  )
  assert(opts.effect == nil or type(opts.effect) == "function", "mart effect must be a function")
  local cursor = assert(opts.continueCursor, "mart controller requires the field-UI continuation cursor")
  local promptShape = assert(opts.promptShape, "mart controller requires the compact field-UI prompt shape")
  assert(manifest.lower, "mart manifest carries its lower pane")
  local text = assert(manifest.text, "mart manifest carries its text programs")

  local self = setmetatable({
    _session = session,
    _manifest = manifest,
    _fontDef = fontDef,
    _effect = opts.effect,
    _frameIndex = opts.frameIndex,
    _state = "browse",
    _page = 0,
    _selection = 0,
    _quantity = 1,
    _maximum = 1,
    _animationRemaining = 0,
    _animationFrame = 0,
    _controlFeedback = nil,
    _amountAnimations = {},
    _pointer = nil,
    _quote = nil,
    _terms = nil,
    _receipt = nil,
    _printerTarget = nil,
    _messageRole = nil,
    _messagePages = nil,
    _printerComplete = false,
    _failureReason = nil,
    _result = nil,
    _disposed = false,
  }, MartController)
  local effect = opts.effect
  local function play(sequence)
    if effect then
      effect(sequence)
    end
  end
  local function layoutPrinterMessage(message)
    return DialogueLayout.layout(message.tokens, FieldDialogueTheme.fontMetrics(fontDef), {
      width = 216,
      maxLines = 2,
      sourcePositioned = true,
    })
  end
  local function playPrinterAudio(_, sequence)
    play(sequence)
  end
  local function onPrinterCallback(token)
    assert(
      token.kind == "printer_callback" and token.name == "transaction_received",
      "mart printer callback is source transaction cue"
    )
    play(1603)
  end
  self._prompt = YesNoPromptController.new(promptShape, play)
  self._printer = FieldDialogueController.new({
    layout = layoutPrinterMessage,
    policy = policy,
    audio = { play = playPrinterAudio },
    continueCursor = cursor,
    onPrinterCallback = onPrinterCallback,
  })
  assert(type(text.templates) == "table", "mart manifest carries normalized message templates")
  return self
end

function MartController:_view()
  return self._session:view()
end

function MartController:_entry()
  local view = self:_view()
  return view.entries[self._page * 6 + self._selection + 1]
end

function MartController:_play(sequence)
  if self._effect then
    self._effect(sequence)
  end
end

function MartController:_messageTokens(role, bindings)
  local program = assert(self._manifest.text.templates[role], "mart message role exists")
  local tokens = {}
  for _, part in ipairs(program.parts) do
    if part.kind == "literal" then
      local parsed, err = FieldMessageText.parse(part.value, self._fontDef, { eos = false })
      assert(parsed, tostring(err))
      for _, token in ipairs(parsed) do
        tokens[#tokens + 1] = token
      end
    elseif part.kind == "binding" then
      local value = bindings[part.name]
      assert(type(value) == "string", "mart message binding " .. part.name .. " is available")
      local parsed, err = FieldMessageText.parse(value, self._fontDef, { eos = false })
      assert(parsed, tostring(err))
      for _, token in ipairs(parsed) do
        tokens[#tokens + 1] = token
      end
    elseif part.kind == "line" then
      tokens[#tokens + 1] = { kind = "line_break", raw = { FieldMessageText.CHAR_LF } }
    elseif part.kind == "clear" then
      tokens[#tokens + 1] =
        { kind = "clear_continuation", control = FieldMessageText.CLEAR_CONTINUATION, args = {}, raw = {} }
    elseif part.kind == "scroll" then
      tokens[#tokens + 1] =
        { kind = "scroll_continuation", control = FieldMessageText.SCROLL_CONTINUATION, args = {}, raw = {} }
    elseif part.kind == "callback" then
      assert(part.name == "transaction_received", "mart callback has the source transaction meaning")
      tokens[#tokens + 1] = {
        kind = "printer_callback",
        control = FieldMessageText.CALLBACK_SIGNAL,
        name = part.name,
        args = {},
        raw = { FieldMessageText.EXT_CTRL_CODE_BEGIN, FieldMessageText.CALLBACK_SIGNAL, 0 },
      }
    else
      error("unknown mart message part " .. tostring(part.kind), 0)
    end
  end
  tokens[#tokens + 1] = { kind = "eos", control = FieldMessageText.EOS, args = {}, raw = { FieldMessageText.EOS } }
  return tokens
end

function MartController:_openMessage(role, bindings, target)
  local tokens = self:_messageTokens(role, bindings or {})
  self._messageRole = role
  self._messagePages = DialogueLayout.layout(tokens, FieldDialogueTheme.fontMetrics(self._fontDef), {
    width = 216,
    maxLines = 2,
    sourcePositioned = true,
  })
  local message = {
    tokens = tokens,
    text = FieldMessageText.tokensToText(tokens),
    hadUnresolvedSubstitutions = false,
  }
  self._printerTarget = target
  self._printerComplete = false
  local handle = self._printer:open({
    id = "mart-" .. target .. "-" .. role,
    message = message,
    allowCancel = false,
    frameIndex = self._frameIndex,
  })
  handle:onComplete(function()
    self._printerComplete = true
  end)
  handle:onError(function(result)
    self._result = { kind = "error", error = result.error }
    self._state = "closed"
  end)
end

local function namedItemBindings(bindings)
  return {
    item = assert(bindings.itemName, "mart item messages use the service item name"),
    pocket = assert(bindings.pocketName, "mart item messages use the service pocket name"),
  }
end

function MartController:_beginError(reason)
  self._failureReason = reason
  self._state = "error_print"
  self:_openMessage(assert(ERROR_ROLES[reason], "mart business reason has a source message family"), {}, "error_ack")
end

function MartController:_itemBindings(entry)
  return namedItemBindings(entry.bindings)
end

function MartController:_formatRole(role, bindings)
  local tokens = self:_messageTokens(role, bindings or {})
  local lines = DialogueLayout.layout(tokens, FieldDialogueTheme.fontMetrics(self._fontDef), {
    width = 216,
    maxLines = 2,
    sourcePositioned = true,
  }).pages
  return lines[1] and lines[1].lines[1] and copyTerms(lines[1].lines[1].tokens) or {}
end

function MartController:_quote(quantity)
  local entry = assert(self:_entry(), "a quote needs the selected populated entry")
  local token, termsOrReason = self._session:quoteBuy(entry.entryKey, quantity)
  if token == nil then
    self._quote = nil
    self._terms = nil
    self:_beginError(termsOrReason)
    return false
  end
  self._quote = token
  self._terms = termsOrReason
  local view = self:_view()
  local role = view.currency == "athlete_points" and "pointsConfirm" or "moneyConfirm"
  local bindings = role == "pointsConfirm" and { item = self:_itemBindings(entry).item }
    or {
      quantity = tostring(quantity),
      total = tostring(termsOrReason.total),
    }
  self._state = "confirm_prompt"
  self:_openMessage(role, bindings, "confirm")
  return true
end

function MartController:_afterSelection()
  local entry = self:_entry()
  if entry == nil then
    self._state = "browse"
    return
  end
  if entry.selectionFailure ~= nil then
    self:_beginError(entry.selectionFailure)
    return
  end
  local view = self:_view()
  self._maximum = entry.maxQuantity
  self._quantity = 1
  if view.quantityMode == "single" then
    self:_quote(1)
  else
    self._state = "quantity_prompt"
    self:_openMessage("quantityPrompt", self:_itemBindings(entry), "quantity")
  end
end

function MartController:_commit()
  local receipt, reason = self._session:commit(assert(self._quote, "success print owns one quote"))
  if receipt == nil then
    self._quote = nil
    self._terms = nil
    self:_beginError(reason or "stale")
    return
  end
  self._receipt = receipt
  self._quote = nil
  self._state = "success_ack"
end

function MartController:_finishPrinter()
  if not self._printerComplete then
    return
  end
  self._printerComplete = false
  local target = assert(self._printerTarget)
  self._printerTarget = nil
  if target == "quantity" then
    self._state = "quantity"
  elseif target == "confirm" then
    local yesNo = self._manifest.lower.yesNo
    self._prompt:open({
      x = yesNo.anchor.x,
      y = yesNo.anchor.y,
      shape = yesNo.shape,
      initialSelection = yesNo.initialChoice,
    })
    self._state = "confirm"
  elseif target == "commit" then
    self:_commit()
  elseif target == "success_ack" then
    self._state = "success_ack"
  elseif target == "bonus_ack" then
    self._state = "bonus_ack"
  elseif target == "error_ack" then
    self._state = "error_ack"
  end
end

function MartController:_beginControlFeedback(controlKey, pending)
  assert(self._controlFeedback == nil, "mart control feedback has one pending action")
  self._controlFeedback = {
    key = controlKey,
    phase = "dispatch",
    remaining = assert(self._manifest.feedback.dispatchTicks),
    pending = pending,
  }
end

function MartController:_changePage(direction, controlKey)
  local view = self:_view()
  local count = #view.entries
  local pages = math.ceil(count / 6)
  local nextPage = self._page + direction
  if pages == 0 or nextPage < 0 or nextPage >= pages then
    return
  end
  self:_play(SOURCE_CUES.select)
  self:_beginControlFeedback(controlKey, { kind = "page", page = nextPage })
end

function MartController:_focus(target)
  if target == self._selection then
    return
  end
  self._selection = target
  self:_play(SOURCE_CUES.select)
end

function MartController:_activateBrowse()
  if self._selection == 8 then
    self:_play(SOURCE_CUES.cancel)
    self:_beginControlFeedback("cancel", { kind = "close" })
  elseif self:_entry() ~= nil then
    self:_play(SOURCE_CUES.select)
    self._state = "selection_feedback"
    self._animationRemaining = self._manifest.animations.selectionEntry.totalTicks
    self._animationFrame = 1
  end
end

function MartController:_closeNormally()
  self._controlFeedback = nil
  self._amountAnimations = {}
  self._state = "closed"
  self._result = { kind = "close" }
  self._quote = nil
end

function MartController:_applyPendingAction(action)
  if action.kind == "page" then
    self._page = assert(action.page)
  elseif action.kind == "close" then
    self:_closeNormally()
  elseif action.kind == "quote" then
    self:_quote(assert(action.quantity))
  elseif action.kind == "browse" then
    self._state = "browse"
    self._messageRole, self._messagePages = nil, nil
  else
    error("unknown mart control action " .. tostring(action.kind), 0)
  end
end

function MartController:_stepControlFeedback()
  local feedback = assert(self._controlFeedback)
  feedback.remaining = feedback.remaining - 1
  if feedback.remaining > 0 then
    return
  end
  if feedback.phase == "dispatch" then
    feedback.phase = "selected"
    feedback.remaining = self._manifest.feedback.selectedTicks
  elseif feedback.phase == "selected" then
    feedback.phase = "restored"
    feedback.remaining = self._manifest.feedback.restoredTicks
  else
    local pending = feedback.pending
    self._controlFeedback = nil
    self:_applyPendingAction(pending)
  end
end

function MartController:_stepAmountAnimations()
  for key, animation in pairs(self._amountAnimations) do
    animation.elapsed = animation.elapsed + 1
    local clip = self._manifest.animations[animation.family]
    if animation.elapsed >= clip.totalTicks then
      self._amountAnimations[key] = nil
    end
  end
end

function MartController:_navigateBrowse(direction)
  local index = DIRECTION_INDEX[direction]
  if index == nil then
    return
  end
  local target = SOURCE_NAVIGATION[self._selection][index]
  if (target == 6 and self._page == 0) or (target == 7 and (self._page + 1) * 6 >= #self:_view().entries) then
    return
  end
  if target == 6 then
    self:_changePage(-1, "pagePrevious")
  elseif target == 7 then
    self:_changePage(1, "pageNext")
  else
    self:_focus(target)
  end
end

function MartController:_quantityAdjust(direction, touch)
  local maximum, quantity = self._maximum, self._quantity
  local delta = direction == "up" and 1 or direction == "down" and -1 or direction == "left" and -10 or 10
  local unit = math.abs(delta) == 1
  if touch and ((unit and maximum == 1) or (not unit and maximum < 10)) then
    return
  end
  local nextValue
  if unit then
    if delta > 0 then
      nextValue = quantity >= maximum and 1 or quantity + 1
    else
      nextValue = quantity <= 1 and maximum or quantity - 1
    end
  elseif touch then
    if delta > 0 then
      nextValue = quantity >= maximum and 1 or math.min(maximum, quantity + 10)
    else
      nextValue = quantity <= 1 and maximum or math.max(1, quantity - 10)
    end
  else
    nextValue = math.max(1, math.min(maximum, quantity + delta))
  end
  if nextValue ~= quantity then
    self._quantity = nextValue
    self:_play(SOURCE_CUES.quantity)
    local control = (direction == "up" and "increment1")
      or (direction == "down" and "decrement1")
      or (direction == "left" and "decrement10")
      or "increment10"
    if touch then
      local family = delta > 0 and "increment" or "decrement"
      self._amountAnimations[control] = { family = family, elapsed = 0 }
    end
  end
end

function MartController:_hitBrowse(x, y)
  local lower = self._manifest.lower
  for index = 1, 6 do
    if contains(lower.slots[index].hitbox, x, y) then
      return index - 1
    end
  end
  for _, pair in ipairs({
    { 6, lower.pagePrevious.hitbox },
    { 7, lower.pageNext.hitbox },
    { 8, lower.cancel.hitbox },
  }) do
    if contains(pair[2], x, y) then
      return pair[1]
    end
  end
  return nil
end

function MartController:_hitQuantity(x, y)
  local quantity = self._manifest.lower.quantity
  for _, key in ipairs({ "increment10", "increment1", "decrement10", "decrement1", "confirm", "cancel" }) do
    if contains(quantity[key].hitbox, x, y) then
      return key
    end
  end
  return nil
end

function MartController:_pointerDown(event)
  if self._pointer ~= nil or type(event.pointerId) ~= "string" then
    return
  end
  if self._state == "browse" then
    local target = self:_hitBrowse(event.x, event.y)
    if target == nil then
      return
    end
    self._pointer = { id = event.pointerId, target = tostring(target), x = event.x, y = event.y }
  elseif self._state == "quantity" then
    local target = self:_hitQuantity(event.x, event.y)
    if target ~= nil then
      self._pointer = { id = event.pointerId, target = target, x = event.x, y = event.y }
    end
  elseif self._state == "confirm" then
    self._pointer = { id = event.pointerId, target = "prompt", x = event.x, y = event.y }
  end
end

function MartController:_pointerUp(event)
  local capture = self._pointer
  if capture == nil or capture.id ~= event.pointerId then
    return
  end
  self._pointer = nil
  if self._state == "browse" then
    local target = self:_hitBrowse(event.x, event.y)
    if target ~= nil and tostring(target) == capture.target then
      if target == 6 then
        self:_changePage(-1, "pagePrevious")
      elseif target == 7 then
        self:_changePage(1, "pageNext")
      else
        self._selection = target
        self:_activateBrowse()
      end
    end
  elseif self._state == "quantity" then
    local target = self:_hitQuantity(event.x, event.y)
    if target == capture.target then
      if target == "confirm" then
        self:_play(SOURCE_CUES.select)
        self:_beginControlFeedback("confirm", { kind = "quote", quantity = self._quantity })
      elseif target == "cancel" then
        self:_play(SOURCE_CUES.cancel)
        self:_beginControlFeedback("cancel", { kind = "browse" })
      else
        local direction = target == "increment10" and "right"
          or target == "increment1" and "up"
          or target == "decrement10" and "left"
          or "down"
        self:_quantityAdjust(direction, true)
      end
    end
  elseif self._state == "confirm" then
    self._prompt:updateFixed({ { type = "pointer_down", x = event.x, y = event.y } })
  end
end

function MartController:_eventsForPrinter(events)
  local input = {}
  for _, event in ipairs(events) do
    if event.type == "confirm" then
      input.actionPressed = true
    elseif event.type == "cancel" then
      input.cancelPressed = true
    end
  end
  return input
end

function MartController:_startSuccess()
  local view = self:_view()
  local role = view.presentationKind == "seals" and "sealReceived"
    or view.currency == "athlete_points" and "pointsReceived"
    or "itemReceived"
  local bindings = role == "sealReceived" and { item = assert(self._terms).bindings.itemName }
    or role == "itemReceived" and namedItemBindings(assert(self._terms).bindings)
    or {}
  self._state = "success_print"
  self:_openMessage(role, bindings, "commit")
end

function MartController:_acknowledgeSuccess()
  local result, reason = self._session:acknowledge(assert(self._receipt, "success acknowledgement owns its receipt"))
  self._receipt = nil
  if result == nil then
    self:_beginError(reason or "stale")
  elseif result.bonusGranted then
    self._state = "bonus_print"
    self:_openMessage("premierBonus", { quantity = tostring(self._terms and self._terms.quantity or 1) }, "bonus_ack")
  else
    self._terms = nil
    self._messageRole, self._messagePages = nil, nil
    self._state = "browse"
  end
end

function MartController:step(events)
  assert(not self._disposed, "a disposed mart controller steps nothing")
  assert(type(events) == "table", "mart controller input must be an ordered event array")
  if self._state == "closed" then
    return
  end
  for _, event in ipairs(events) do
    assert(type(event) == "table" and type(event.type) == "string", "mart input events need a type")
    if event.type == "pointer_cancel" then
      self:cancelPointerCapture()
    elseif event.type == "dismiss" then
      self._pointer = nil
      self._prompt:dispose()
      self._printer:close()
      self:_closeNormally()
      return
    end
  end
  self:_stepAmountAnimations()
  if self._controlFeedback ~= nil then
    self:_stepControlFeedback()
    return
  end
  if self._state == "selection_feedback" then
    self._animationRemaining = self._animationRemaining - 1
    local clip = self._manifest.animations.selectionEntry
    local elapsed = clip.totalTicks - self._animationRemaining
    self._animationFrame = clipFrame(clip, elapsed - 1)
    if self._animationRemaining <= 0 then
      self._animationRemaining = 0
      self:_afterSelection()
    end
    return
  end
  if
    self._state == "quantity_prompt"
    or self._state == "confirm_prompt"
    or self._state == "success_print"
    or self._state == "bonus_print"
    or self._state == "error_print"
  then
    self._printer:step(self:_eventsForPrinter(events))
    self:_finishPrinter()
    return
  end
  if self._state == "confirm" then
    self._prompt:updateFixed(events)
    local answer = self._prompt:takeResult()
    if answer == "yes" then
      self:_startSuccess()
    elseif answer == "no" then
      self._quote, self._terms = nil, nil
      self._messageRole, self._messagePages = nil, nil
      self._state = "browse"
    end
    return
  end
  if self._state == "success_ack" then
    for _, event in ipairs(events) do
      if event.type == "confirm" or event.type == "cancel" then
        self:_acknowledgeSuccess()
        break
      end
    end
    return
  end
  if self._state == "bonus_ack" or self._state == "error_ack" then
    for _, event in ipairs(events) do
      if event.type == "confirm" or event.type == "cancel" then
        self._state = "browse"
        self._terms, self._failureReason = nil, nil
        self._messageRole, self._messagePages = nil, nil
        break
      end
    end
    return
  end
  if self._state == "quantity" then
    local order = { up = 1, down = 2, left = 3, right = 4 }
    local selected
    for _, event in ipairs(events) do
      if
        event.type == "navigate"
        and order[event.direction]
        and (selected == nil or order[event.direction] < selected.priority)
      then
        selected =
          { direction = event.direction, priority = order[event.direction], repeatKey = event["repeat"] == true }
      elseif event.type == "pointer_down" then
        self:_pointerDown(event)
      elseif event.type == "pointer_up" then
        self:_pointerUp(event)
        if self._controlFeedback ~= nil then
          return
        end
      elseif event.type == "pointer_cancel" then
        self:cancelPointerCapture()
      elseif event.type == "confirm" then
        self:_play(SOURCE_CUES.select)
        self:_beginControlFeedback("confirm", { kind = "quote", quantity = self._quantity })
        return
      elseif event.type == "cancel" then
        self:_play(SOURCE_CUES.cancel)
        self:_beginControlFeedback("cancel", { kind = "browse" })
        return
      end
    end
    if selected ~= nil then
      self:_quantityAdjust(selected.direction, false)
    end
    return
  end
  if self._state ~= "browse" then
    return
  end
  local acted = false
  for _, event in ipairs(events) do
    if event.type == "navigate" then
      if event["repeat"] ~= true then
        self:_navigateBrowse(event.direction)
      end
    elseif event.type == "confirm" then
      self:_activateBrowse()
      acted = true
      break
    elseif event.type == "cancel" then
      self:_play(SOURCE_CUES.cancel)
      self:_beginControlFeedback("cancel", { kind = "close" })
      return
    elseif event.type == "pointer_down" then
      self:_pointerDown(event)
    elseif event.type == "pointer_up" then
      self:_pointerUp(event)
      if self._controlFeedback ~= nil then
        return
      end
      acted = true
    end
    if acted then
      break
    end
    if self._controlFeedback ~= nil then
      return
    end
  end
end

function MartController:status()
  local view = self:_view()
  local count = #view.entries
  local pageCount = math.ceil(count / 6)
  local state = self._state
  local slots = {}
  for slot = 0, 5 do
    local entryIndex = self._page * 6 + slot + 1
    local entry = view.entries[entryIndex]
    slots[slot + 1] = entry
        and {
          entryKey = entry.entryKey,
          entryIndex = entryIndex,
          displayItemKey = entry.displayItemKey,
          bindings = copyTerms(entry.bindings),
          description = entry.descriptionText,
          price = entry.unitPrice,
          priceTokens = entry.priceVisible and self:_formatRole(
            view.currency == "athlete_points" and "pointsPrice" or "moneyPrice",
            { price = tostring(entry.unitPrice) }
          ) or {},
          priceVisible = entry.priceVisible,
          ownedQuantity = entry.ownedQuantity,
          maxQuantity = entry.maxQuantity,
          selectionFailure = entry.selectionFailure,
          iconAnchor = self._manifest.lower.slots[slot + 1].iconAnchor,
          focusAnchor = self._manifest.lower.slots[slot + 1].focusAnchor,
          labelBox = self._manifest.lower.slots[slot + 1].labelBox,
        }
      or { entryIndex = entryIndex }
  end
  local selected = view.entries[self._page * 6 + self._selection + 1]
  local printer = self._printer:status()
  local messageLines
  if PRINTER_STATES[state] then
    messageLines = printer.visibleLines
  elseif self._messagePages ~= nil then
    local pages = self._messagePages.pages
    local page = pages[#pages]
    messageLines = page and page.lines or {}
  else
    messageLines = {}
  end
  local lowerMode = "browse"
  if state == "quantity" or state == "quantity_prompt" then
    lowerMode = "quantity"
  end
  if state == "confirm" or state == "confirm_prompt" then
    lowerMode = "confirm"
  end
  local balanceRole = view.currency == "athlete_points" and "pointsBalance" or "moneyBalance"
  local pageTokens = self:_formatRole("pageNumber", {
    currentPage = tostring(self._page + 1),
    pageCount = tostring(pageCount),
  })
  local total = self._terms and self._terms.total or (selected and selected.unitPrice * self._quantity)
  local ownedQuantity = selected and selected.ownedQuantity or 0
  local controlFeedback = self._controlFeedback
      and {
        key = self._controlFeedback.key,
        phase = self._controlFeedback.phase,
      }
    or nil
  local amountAnimations = {}
  for key, animation in pairs(self._amountAnimations) do
    amountAnimations[key] = {
      family = animation.family,
      frame = clipFrame(self._manifest.animations[animation.family], animation.elapsed),
    }
  end
  return {
    state = state,
    open = state ~= "closed",
    page = self._page,
    pageCount = pageCount,
    selection = self._selection,
    entryIndex = selected and self._page * 6 + self._selection + 1 or nil,
    currentEntry = selected and copyTerms(selected) or nil,
    entries = slots,
    entryCount = count,
    description = selected and selected.descriptionText or nil,
    balance = view.balance,
    currency = view.currency,
    presentationKind = view.presentationKind,
    quantity = self._quantity,
    maxQuantity = self._maximum,
    total = total,
    totalTokens = self:_formatRole("quantityTotal", { total = tostring(total or 0) }),
    ownedTokens = self:_formatRole("ownedCount", { owned = tostring(ownedQuantity) }),
    balanceTokens = self:_formatRole(balanceRole, { balance = tostring(view.balance) }),
    pageTokens = pageTokens,
    lowerMode = lowerMode,
    animationFrame = self._animationFrame,
    animationRemaining = self._animationRemaining,
    controlFeedback = controlFeedback,
    amountAnimations = amountAnimations,
    printer = PRINTER_STATES[state] and printer or nil,
    messageRole = self._messageRole,
    messageLines = copyTerms(messageLines),
    prompt = state == "confirm" and self._prompt:status() or nil,
    plan = nil,
    failureReason = self._failureReason,
    result = self._result and copyTerms(self._result) or nil,
  }
end

function MartController:takeResult()
  local result = self._result
  self._result = nil
  return result and copyTerms(result) or nil
end

function MartController:cancelPointerCapture()
  self._pointer = nil
end

function MartController:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._pointer = nil
  self._prompt:dispose()
  self._printer:dispose()
  self._quote = nil
  self._receipt = nil
  self._terms = nil
  self._messageRole = nil
  self._messagePages = nil
  self._result = nil
  self._controlFeedback = nil
  self._amountAnimations = {}
  self._state = "closed"
end

return MartController
