-- The three-line MailView letter screen with one nested shared sentence
-- editor. Owns only the detached draft, the source MailView UI state
-- (row/button focus, modality, pulse, warning/quit modals, entry/exit
-- fades), and at most one C02 child. Never touches Bag, Party, Mailbox,
-- or stats: an accepted whole letter returns to the caller, which owns
-- final custody through MailActions. The final result is observable only
-- after the exit fade and cleanup, then exactly once.
local Mail = require("libs.mons.src.gen4.Mail")
local MailTemplate = require("libs.hgss.src.field.MailTemplate")
local MailViewInterface = require("game.hgss.src.pc.MailViewInterface")

---@class MailComposeState
---@field _letter table<string, unknown> detached draft with three line slots
---@field _catalog table<string, unknown> the shared word catalog
---@field _openEasyChat fun(request: table<string, unknown>): table<string, unknown> the shared editor opener
---@field _prepare fun(status: table<string, unknown>): boolean, string? borrowed Mail preparation per update
---@field _manifest table<string, unknown> the PC manifest carrying compiled stationery
---@field _stationeryType integer selected stationery type
---@field _hitMasks table[] five generated rect-local touch masks in cursor order
---@field _measureDisplay fun(): table<string, unknown> display facts for the native plan
---@field _audio table<string, unknown>? production sound boundary
---@field _inputMode string buttons or touch modality
---@field _readNavigation fun(): table<string, unknown>? read-only navigation observation
---@field _phase string source MailView lifecycle phase
---@field _fadeIndex integer completed entry/exit fade steps
---@field _focusPos integer keyboard cursor position 0..4
---@field _focusButton integer button-row cursor 0..1
---@field _pulseLevel integer focus highlight coefficient 0..13
---@field _pulseFalling boolean pulse direction while falling
---@field _touchHeld boolean a touch press is currently held
---@field _quitCursor string quit prompt cursor yes or no
---@field _pendingLine integer? line staged for the nested editor
---@field _child table<string, unknown>? live nested sentence editor while open
---@field _pendingResult table<string, unknown>? staged one-shot result awaiting exit fade
---@field _result table<string, unknown>? published one-shot result
---@field _resultTaken boolean published result was drained
---@field _preparing boolean Mail preparation is not yet ready
---@field _preparationError string? last preparation failure
---@field _resolvedPlan table<string, unknown>? cached native write plan
---@field _disposed boolean lifetime ended
---@field uiInput string? current input profile for the host
local MailComposeState = {}
MailComposeState.__index = MailComposeState

-- Source MailView fade recurrences (palette.c wait=-1 step 3): entry
-- 16 down to 0, exit 0 up to 16, one coefficient per fixed update.
local ENTRY_COEFFICIENTS = { 16, 13, 10, 7, 4, 1, 0 }
local EXIT_COEFFICIENTS = { 0, 3, 6, 9, 12, 15, 16 }
local PULSE_MAX = 13

-- The fresh composer starts on the first line in buttons mode, matching
-- the source blank-line initialization.
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, child in pairs(value) do
    out[key] = copy(child)
  end
  return out
end

local function cue(self, sequence)
  local audio = self._audio
  if type(audio) == "table" and type(audio.play) == "function" then
    audio.play(sequence)
  end
end

---@param letter table<string, unknown> fresh detached draft with three false lines
local function checkLetter(letter)
  assert(type(letter) == "table", "composition carries its detached draft")
  assert(letter.schema == Mail.SCHEMA, "composition drafts use the current Mail schema")
  assert(type(letter.type) == "number" and letter.type % 1 == 0, "composition carries its stationery type")
  assert(type(letter.author) == "table", "composition carries its detached author")
  assert(type(letter.icons) == "table" and #letter.icons == 3, "composition carries three icon snapshots")
  assert(type(letter.lines) == "table" and #letter.lines == 3, "composition assembles exactly three lines")
end

function MailComposeState.new(opts)
  assert(type(opts) == "table", "mail composition requires options")
  local letter = assert(opts.letter, "mail composition carries its detached draft")
  checkLetter(letter)
  local catalog = assert(opts.catalog, "mail composition reads the shared word catalog")
  assert(type(catalog.messageStatus) == "function", "mail composition adapts through the shared catalog")
  local openEasyChat = assert(opts.openEasyChat, "mail composition borrows the shared editor opener")
  assert(type(openEasyChat) == "function", "the shared editor opens through its factory")
  local prepare = assert(opts.prepare, "mail composition borrows its Mail preparation")
  assert(type(prepare) == "function", "Mail preparation resolves per update")
  local manifest = assert(opts.manifest, "mail composition reads the PC manifest")
  assert(
    type(manifest.mail) == "table" and type(manifest.mail.stationery) == "table",
    "mail composition reads compiled stationery"
  )
  local stationeryType = assert(letter.type, "the draft carries its stationery type")
  local write = manifest.mail.stationery[stationeryType] and manifest.mail.stationery[stationeryType].write
  assert(type(write) == "table" and type(write.hitMasks) == "table", "composition maps its compiled touch masks")
  assert(type(opts.measureDisplay) == "function", "mail composition needs its display facts")
  local inputMode = opts.inputMode or "buttons"
  assert(inputMode == "buttons" or inputMode == "touch", "composition starts in buttons or touch mode")
  local readNavigation = opts.readNavigation
  assert(readNavigation == nil or type(readNavigation) == "function", "navigation arrives as a callback")
  return setmetatable({
    _letter = copy(letter),
    _catalog = catalog,
    _openEasyChat = openEasyChat,
    _prepare = prepare,
    _manifest = manifest,
    _stationeryType = stationeryType,
    _hitMasks = write.hitMasks,
    _measureDisplay = opts.measureDisplay,
    _audio = opts.audio,
    _inputMode = inputMode,
    _readNavigation = readNavigation,
    _phase = "prepare",
    _fadeIndex = 0,
    _focusPos = 0,
    _focusButton = 0,
    _pulseLevel = 0,
    _pulseFalling = false,
    _touchHeld = false,
    _quitCursor = "yes",
    _pendingLine = nil,
    _child = nil,
    _pendingResult = nil,
    _result = nil,
    _resultTaken = false,
    _preparing = true,
    _preparationError = nil,
    _resolvedPlan = nil,
    _disposed = false,
    uiInput = nil,
  }, MailComposeState)
end

-- Polls the late-bound Mail preparation with the write demand. Readiness
-- gates entry, fades, and input; the failure cause rides status until a
-- later update recovers.
---@param self MailComposeState
---@return boolean ready
function MailComposeState:_pollPreparation()
  local ok, ready, failure = pcall(self._prepare, { viewMode = "write", stationeryType = self._stationeryType })
  if not ok then
    self._preparing = true
    self._preparationError = tostring(ready)
    return false
  end
  if ready then
    self._preparing = false
    self._preparationError = nil
    return true
  end
  self._preparing = true
  self._preparationError = failure
  return false
end

function MailComposeState:_resolvePlan()
  local display = self._measureDisplay()
  self._resolvedPlan = MailViewInterface.plan(display, "write", { hitMasks = self._hitMasks })
  return self._resolvedPlan
end

---@return table<string, unknown> resolved write plan
function MailComposeState:_plan()
  if self._resolvedPlan == nil then
    self:_resolvePlan()
  end
  return assert(self._resolvedPlan, "composition resolves its write plan")
end

-- Detached draft letter for custody handoff and status snapshots; never
-- aliases the live draft.
---@return table<string, unknown>
function MailComposeState:draftLetter()
  return {
    schema = Mail.SCHEMA,
    type = self._stationeryType,
    author = copy(self._letter.author),
    icons = copy(self._letter.icons),
    lines = copy(self._letter.lines),
  }
end

-- Source modality arbitration (mail_view.c CheckInputModeSwitch) over the
-- read-only navigation sample plus the locally tracked touch press: a
-- touch-mode key with no held touch switches to buttons and is consumed;
-- a buttons-mode touch switches modality and activates its control in
-- the same input step. Returns true when the batch is consumed.
---@param self MailComposeState
---@param events table[]
---@return boolean consumed
function MailComposeState:_arbitrateModality(events)
  local sample = nil
  if self._readNavigation ~= nil then
    local ok, observed = pcall(self._readNavigation)
    if ok then
      sample = observed
    end
  end
  local heldKeys = sample ~= nil and sample.buttonsHeld == true
  local newKey, newTouch = false, false
  for _, event in ipairs(events) do
    if event.type == "confirm" or event.type == "cancel" or event.type == "navigate" then
      newKey = true
    elseif event.type == "pointer_down" or event.type == "touch" then
      newTouch = true
    elseif event.type == "pointer_up" or event.type == "pointer_cancel" then
      self._touchHeld = false
    end
  end
  if newTouch then
    self._touchHeld = true
  end
  heldKeys = heldKeys or newKey
  local touchHeld = self._touchHeld or newTouch
  if self._inputMode == "touch" then
    if touchHeld then
      return false
    end
    if heldKeys then
      self._inputMode = "buttons"
      self:_resetPulse()
      return true
    end
    return false
  end
  if heldKeys then
    return false
  end
  if touchHeld then
    self._inputMode = "touch"
    self:_resetPulse()
  end
  return false
end

function MailComposeState:_resetPulse()
  self._pulseLevel = 0
  self._pulseFalling = false
end

-- Advances the keyboard focus pulse one source tick: coefficients rise
-- 0..13 and fall back to 0, frozen in touch mode and in the quit prompt.
---@param self MailComposeState
function MailComposeState:_stepPulse()
  if self._inputMode == "touch" or self._phase == "quit" then
    return
  end
  local level = self._pulseLevel
  if self._pulseFalling then
    level = level - 1
    if level <= 0 then
      level = 0
      self._pulseFalling = false
    end
  else
    level = level + 1
    if level >= PULSE_MAX then
      level = PULSE_MAX
      self._pulseFalling = true
    end
  end
  self._pulseLevel = level
end

-- Moves the keyboard focus: up/down wrap the four source rows, left/right
-- toggle the button pair only on the button row, Start selects Confirm.
---@param self MailComposeState
---@param direction string
function MailComposeState:_moveFocus(direction)
  local row = self._focusPos <= 2 and self._focusPos or 3
  if direction == "down" then
    row = (row + 1) % 4
  elseif direction == "up" then
    row = (row + 3) % 4
  elseif (direction == "left" or direction == "right") and row == 3 then
    self._focusButton = 1 - self._focusButton
    self:_syncFocusPos()
    self:_resetPulse()
    cue(self, "SEQ_SE_DP_SELECT")
    return
  else
    return
  end
  if row <= 2 then
    self._focusPos = row
  else
    self._focusPos = 3 + self._focusButton
  end
  self:_resetPulse()
  cue(self, "SEQ_SE_DP_SELECT")
end

function MailComposeState:_syncFocusPos()
  self._focusPos = 3 + self._focusButton
end

---@param self MailComposeState
---@return boolean all three line slots are false
function MailComposeState:_allBlank()
  for index = 1, 3 do
    if self._letter.lines[index] ~= false then
      return false
    end
  end
  return true
end

-- Launches the shared sentence editor for one line after the MailView
-- exit fade. A false line initializes to bank 3/message 0 with NULL
-- words; an existing line converts through the semantic adapter once.
---@param self MailComposeState
---@param lineIndex integer
function MailComposeState:_beginLineEdit(lineIndex)
  self._pendingLine = lineIndex
  self._phase = "exitChild"
  self._fadeIndex = 0
  cue(self, "SEQ_SE_DP_DECIDE")
end

-- Opens the nested C02 child exactly once the MailView exit fade
-- completes. Construction and preparation failures propagate through
-- preparationError with the draft preserved.
---@param self MailComposeState
function MailComposeState:_openChild()
  local lineIndex = assert(self._pendingLine, "line edits name their selected line")
  local line = self._letter.lines[lineIndex]
  local message
  if line == false then
    message = { bank = 3, number = 0, words = { 65535, 65535 } }
  else
    local ok, converted = pcall(MailTemplate.toMessage, line)
    if not ok then
      self._preparationError = tostring(converted)
      self._phase = "write"
      self._pendingLine = nil
      return
    end
    message = converted
  end
  local ok, child = pcall(self._openEasyChat, {
    mode = 2,
    promptId = 0,
    alwaysConfirm = false,
    inputMode = self._inputMode,
    message = message,
  })
  if not ok then
    self._preparationError = tostring(child)
    self._phase = "write"
    self._pendingLine = nil
    return
  end
  assert(type(child) == "table", "the shared editor opens its child")
  -- The selected line stays staged behind the parked draft until the
  -- finished editor resolves it.
  self._child = child
  self._phase = "child"
  self.uiInput = child.uiInput
end

-- Drains one finished nested editor: accepted results replace only the
-- selected line (accepted-but-unchanged still initializes a previously
-- false line), cancellations preserve that line exactly. The composer
-- adopts the result modality, disposes the child once, and re-prepares
-- its write surface before re-entering with preserved focus.
---@param self MailComposeState
---@param finished table<string, unknown>
function MailComposeState:_finishChild(finished)
  local child = assert(self._child, "finished editors drain their owned child")
  local lineIndex = assert(self._pendingLine, "finished editors resolve their selected line")
  if finished.cancelled == false then
    -- Accepted results replace only the selected line; accepted-but-
    -- unchanged still initializes a previously false line, and unused
    -- trailing fields normalize to false at the Mail boundary.
    local adapted =
      MailTemplate.fromMessage(assert(finished.message, "accepted edits carry their message"), self._catalog)
    self._letter.lines[lineIndex] = adapted
  end
  if type(finished.inputMode) == "string" then
    self._inputMode = finished.inputMode
  end
  local ok, failure = pcall(child.dispose, child)
  self._child = nil
  self._pendingLine = nil
  self.uiInput = nil
  if not ok then
    error(failure, 0)
  end
  cue(self, "SEQ_SE_DP_DECIDE")
  self._phase = "prepare"
end

-- Submits the whole letter: at least one initialized complete line must
-- exist; an all-false draft warns and stays. Other incomplete drafts
-- cannot arise: accepted sentences are always complete.
---@param self MailComposeState
function MailComposeState:_submit()
  if self:_allBlank() then
    self._phase = "warning"
    cue(self, "SEQ_SE_DP_DECIDE")
    return
  end
  local ok, reason = MailTemplate.checkComposed(self:draftLetter(), self._catalog)
  if not ok then
    self._preparationError = tostring(reason)
    self._phase = "write"
    return
  end
  self._pendingResult = { kind = "submitted", letter = self:draftLetter(), inputMode = self._inputMode }
  self._phase = "exit"
  self._fadeIndex = 0
  cue(self, "SEQ_SE_DP_PIRORIRO2")
end

function MailComposeState:_quit()
  self._phase = "quit"
  self._quitCursor = "yes"
  cue(self, "SEQ_SE_DP_DECIDE")
end

-- Routes one mapped write control: lines open the shared editor, Confirm
-- submits, Cancel asks the whole-letter quit question.
---@param self MailComposeState
---@param action table<string, unknown>
function MailComposeState:_activate(action)
  if action.type == "line" then
    self:_beginLineEdit(assert(action.index, "line actions name their line"))
  elseif action.type == "confirm" then
    self._focusPos, self._focusButton = 3, 0
    self:_submit()
  else
    assert(action.type == "cancel", "write controls answer line, confirm, or cancel")
    self._focusPos, self._focusButton = 4, 1
    self:_quit()
  end
end

-- Routes one buttons-mode key: A activates the focused row, B asks quit,
-- Start selects Confirm, arrows move the source cursor.
---@param self MailComposeState
---@param event table<string, unknown>
function MailComposeState:_handleKey(event)
  if event.type == "confirm" then
    if self._focusPos <= 2 then
      self:_beginLineEdit(self._focusPos + 1)
    elseif self._focusButton == 0 then
      self:_submit()
    else
      self:_quit()
    end
  elseif event.type == "cancel" then
    self:_quit()
  elseif event.type == "navigate" then
    local direction = assert(event.direction, "navigation carries its direction")
    if direction == "start" then
      self._focusPos, self._focusButton = 3, 0
      self:_resetPulse()
      self:_submit()
    else
      assert(
        direction == "up" or direction == "down" or direction == "left" or direction == "right",
        "composition uses the four controller directions"
      )
      self:_moveFocus(direction)
    end
  end
end

-- Routes one touch-mode press: the mapped control activates in the same
-- input step that switched modality.
---@param self MailComposeState
---@param action table<string, unknown>
function MailComposeState:_handleTouchAction(action)
  self:_activate(action)
end

function MailComposeState:updateFixed(events)
  assert(not self._disposed, "disposed mail composition cannot update")
  assert(type(events) == "table", "mail composition updates from an event list")
  if self._phase == "done" then
    return
  end
  if self._phase == "child" then
    local child = assert(self._child, "the pending editor owns its ticks")
    -- The child alone advances its lease: exactly one fixed step per
    -- tick, with the raw batch routed exclusively to the child.
    child:updateFixed(events)
    local finished = child:takeResult()
    if finished ~= nil then
      self:_finishChild(finished)
    else
      self.uiInput = child.uiInput
    end
    return
  end
  if self._phase == "prepare" then
    for _, event in ipairs(events) do
      assert(type(event) == "table" and type(event.type) == "string", "mail composition uses typed events")
      if event.type == "pointer_up" or event.type == "pointer_cancel" then
        self._touchHeld = false
      end
    end
    if self:_pollPreparation() then
      self:_resolvePlan()
      self._phase = "enter"
      self._fadeIndex = 0
    end
    return
  end
  if self._phase == "enter" then
    self._fadeIndex = self._fadeIndex + 1
    if self._fadeIndex >= #ENTRY_COEFFICIENTS then
      self._phase = "write"
    end
    return
  end
  if self._phase == "exitChild" then
    self._fadeIndex = self._fadeIndex + 1
    if self._fadeIndex >= #EXIT_COEFFICIENTS then
      self:_openChild()
    end
    return
  end
  if self._phase == "exit" then
    self._fadeIndex = self._fadeIndex + 1
    if self._fadeIndex >= #EXIT_COEFFICIENTS then
      local finished = assert(self._pendingResult, "exit fades publish their staged result")
      local ok, failure = pcall(self._disposeChild, self)
      self._pendingResult = nil
      self._phase = "done"
      if not ok then
        error(failure, 0)
      end
      self._result = finished
    end
    return
  end
  local plan = self:_plan()
  local mapped = MailViewInterface.events(plan, events, self._hitMasks)
  if self._phase == "warning" then
    local dismiss = false
    for _, event in ipairs(mapped) do
      if event.type == "confirm" or event.type == "cancel" or event.type == "line" then
        dismiss = true
        break
      end
    end
    if not dismiss then
      for _, event in ipairs(events) do
        if event.type == "pointer_down" or event.type == "touch" then
          dismiss = true
          break
        end
      end
    end
    if dismiss then
      self._phase = "write"
      cue(self, "SEQ_SE_DP_DECIDE")
    end
    return
  end
  if self._phase == "quit" then
    for _, event in ipairs(mapped) do
      if event.source == "touch" then
        if event.type == "confirm" then
          self._quitCursor = "yes"
        elseif event.type == "cancel" then
          self._quitCursor = "no"
        else
          break
        end
        self._pendingResult = { kind = "cancelled", inputMode = self._inputMode }
        self._phase = "exit"
        self._fadeIndex = 0
        cue(self, "SEQ_SE_DP_DECIDE")
        break
      elseif event.type == "cancel" or event.type == "close" then
        self._phase = "write"
        cue(self, "SEQ_SE_DP_DECIDE")
        break
      elseif event.type == "confirm" or event.type == "line" then
        if self._quitCursor == "yes" then
          self._pendingResult = { kind = "cancelled", inputMode = self._inputMode }
          self._phase = "exit"
          self._fadeIndex = 0
          cue(self, "SEQ_SE_DP_DECIDE")
        else
          self._phase = "write"
          cue(self, "SEQ_SE_DP_DECIDE")
        end
        break
      elseif event.type == "navigate" then
        self._quitCursor = self._quitCursor == "yes" and "no" or "yes"
        cue(self, "SEQ_SE_DP_SELECT")
      end
    end
    return
  end
  assert(self._phase == "write", "composition input reaches the write screen")
  if self:_arbitrateModality(events) then
    return
  end
  self:_stepPulse()
  for _, event in ipairs(mapped) do
    if event.source == "touch" then
      -- Mapped presses activate in the same step that switched modality.
      self:_activate(event)
      break
    elseif event.type == "close" then
      self:_quit()
      break
    else
      self:_handleKey(event)
      if self._phase ~= "write" then
        break
      end
    end
  end
end

function MailComposeState:_disposeChild()
  local child = self._child
  if child ~= nil then
    self._child = nil
    self.uiInput = nil
    child:dispose()
  end
end

-- The presentation snapshot: the current native plan and its detached
-- draft view, preparation facts, modal state, and the raw nested editor
-- status while it owns input. Snapshots never alias the live draft.
---@return table<string, unknown>
function MailComposeState:status()
  local lines = {}
  for index, line in ipairs(self._letter.lines) do
    if line == false then
      lines[index] = false
    else
      lines[index] = { template = line.template, words = { line.words[1], line.words[2] } }
    end
  end
  local view = {
    mode = "write",
    stationeryType = self._stationeryType,
    author = copy(self._letter.author),
    icons = copy(self._letter.icons),
    lines = lines,
    focusPos = self._focusPos,
    focusButton = self._focusButton,
    inputMode = self._inputMode,
    pulseLevel = self._pulseLevel,
    warning = self._phase == "warning",
    modal = self._phase == "warning" or self._phase == "quit",
    prompt = self._phase == "quit" and { cursor = self._quitCursor } or nil,
    quit = self._phase == "quit" and { cursor = self._quitCursor } or nil,
    fadeCoefficient = self:_fadeCoefficient(),
    letter = self:draftLetter(),
  }
  local status = {
    phase = self._phase,
    stationeryType = self._stationeryType,
    author = copy(self._letter.author),
    icons = copy(self._letter.icons),
    lines = lines,
    letter = self:draftLetter(),
    focusPos = self._focusPos,
    focusButton = self._focusButton,
    inputMode = self._inputMode,
    pulseLevel = self._pulseLevel,
    warning = view.warning,
    modal = view.modal,
    prompt = view.prompt,
    quit = view.quit,
    preparing = self._preparing,
    preparationError = self._preparationError,
    fadeCoefficient = view.fadeCoefficient,
    view = view,
    viewMode = "write",
    closed = self._phase == "done",
  }
  -- While the shared editor owns input, its raw status and plan route
  -- the tick; the local MailView plan resumes when the child closes.
  if self._child ~= nil then
    local childStatus = self._child:status()
    status.child = childStatus
    status.uiInput = "easy-chat"
    status.presentation = childStatus.presentation or self:_plan()
  else
    status.child = nil
    status.uiInput = "mail-view"
    status.presentation = self:_plan()
  end
  return status
end

---@return integer fade overlay coefficient, 0 outside fades
function MailComposeState:_fadeCoefficient()
  if self._phase == "enter" then
    return ENTRY_COEFFICIENTS[math.min(self._fadeIndex + 1, #ENTRY_COEFFICIENTS)]
  end
  if self._phase == "exitChild" or self._phase == "exit" then
    return EXIT_COEFFICIENTS[math.min(self._fadeIndex + 1, #EXIT_COEFFICIENTS)]
  end
  return 0
end

-- Draws through the shared stationery renderer for the write view, or
-- through the borrowed editor draw for the nested child. Never acquires
-- images and never gates on readiness: preparation owns the leases.
---@param resources table<string, unknown>
---@param status table<string, unknown>?
function MailComposeState:draw(resources, status)
  assert(not self._disposed, "disposed mail composition draws nothing")
  assert(type(resources) == "table", "mail composition borrows field presentation resources")
  local value = status or self:status()
  if self._child ~= nil then
    local drawEasyChat = assert(resources.drawEasyChat, "nested editors draw through the borrowed editor")
    drawEasyChat(assert(value.child, "the nested editor carries its status"))
    return
  end
  local renderer = assert(resources.mailboxRenderer, "write views borrow the shared stationery renderer")
  renderer:drawMailPane(value.view or value, nil, resources)
end

function MailComposeState:takeResult()
  if self._phase ~= "done" or self._resultTaken then
    return nil
  end
  self._resultTaken = true
  return self._result
end

function MailComposeState:cancel()
  -- Host teardown path: the nested child releases once and the
  -- cancellation reports at once; the normal quit flow still observes
  -- the exit fade through updateFixed.
  if self._phase ~= "done" and self._result == nil then
    self:_disposeChild()
    self._pendingResult = nil
    self._phase = "done"
    self._result = { kind = "cancelled", inputMode = self._inputMode }
  end
end

function MailComposeState:cancelPointerCapture()
  self._touchHeld = false
  local child = self._child
  if child ~= nil and type(child.cancelPointerCapture) == "function" then
    child:cancelPointerCapture()
  end
end

function MailComposeState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self:_disposeChild()
end

function MailComposeState:isActive()
  return self._phase ~= "done"
end

return MailComposeState
