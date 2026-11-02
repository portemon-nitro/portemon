-- One open Options menu: the detached draft beside the committed
-- baseline, the deterministic focus/scroll/gesture ownership, the local
-- text/frame preview, and the two-scope confirmation lifetime. The screen
-- borrows the volume port, the channel-mode collaborator, the player-options
-- preparation closure, the generated semantic labels, and the per-open
-- presentation port; it owns its preview printer restarts, its pointer
-- capture, and exactly one terminal result. Draw and status snapshots
-- never acquire resources or perform IO.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local OptionsInterface = require("game.hgss.src.options.OptionsInterface")
local OptionsRows = require("game.hgss.src.options.OptionsRows")
local ScrollViewport = require("libs.ui.src.ScrollViewport")
local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")

---@class OptionsScreenState
---@field _preparePlayerOptions fun(values: OptionsScreenState.PlayerOptions): fun()? the player-options one-use closure factory
---@field _audio OptionsScreenState.VolumePort the borrowed app-wide volume port
---@field _applyChannelMode fun(mode: string) the live sink channel preview/restore collaborator
---@field _effect fun(sequence: string) the source UI sound boundary
---@field _semantic OptionsScreenState.Semantic? generated labels/metrics ({ labels = ... })
---@field _measureDisplay (fun(): DisplayMeasurement)? the live display facts (absent in headless tests)
---@field _presentationPort FieldPresentationResources.OptionsPresentationPort? the per-open resource port (absent headless)
---@field _previewPrinter FieldDialogueController? a separate dialogue printer for the menu-local sample
---@field _session ApplicationPresentation? the per-open presentation session (absent headless)
---@field _baseline OptionsScreenState.PlayerOptions the committed six player fields
---@field _baselineVolume integer the committed app-wide percent
---@field _baselineChannel string the committed channel mode
---@field _draft OptionsScreenState.Draft the detached editable copy beside the baseline
---@field _legacyNote boolean whether the draft carries the slow-to-mid migration note
---@field _disposed boolean
---@field _phase string "open"|"closed" menu lifetime
---@field _preparing boolean whether the per-open presentation still prepares
---@field _committed boolean whether Confirm published exactly once
---@field _result { kind: string }? the exactly-once host result
---@field _error string? the last recoverable confirmation failure
---@field _focusId string the focused row or footer action
---@field _scrollOffset number the revealed list offset in logical pixels
---@field _capture table<string, unknown>? the one held pointer press
---@field _previewOpen boolean whether the menu-local sample prints
local OptionsScreenState = {}
OptionsScreenState.__index = OptionsScreenState

---@class OptionsScreenState.PlayerOptions
---@field textSpeed string
---@field battleScene boolean
---@field battleStyle string
---@field soundMode string
---@field textFrame integer
---@field battleSpeed integer
---@class OptionsScreenState.Draft
---@field textSpeed string
---@field battleScene boolean
---@field battleStyle string
---@field soundMode string
---@field textFrame integer
---@field battleSpeed integer
---@field volume integer
---@class OptionsScreenState.VolumePort
---@field read fun(): integer
---@field preview fun(volume: integer)
---@field commit fun(volume: integer)
---@field restore fun()
---@class OptionsScreenState.Semantic
---@field labels table<string, unknown>?
---@field framePreviewText table<integer, table<string, unknown>>?

local SELECT_SOUND = "SEQ_SE_DP_SELECT"
local CANCEL_SOUND = "SEQ_SE_GS_GEARCANCEL"
local SAVE_SOUND = "SEQ_SE_DP_SAVE"
local BUTTON_SOUND = "SEQ_SE_DP_BUTTON9"

local function copyOptions(options)
  return {
    textSpeed = options.textSpeed,
    battleScene = options.battleScene,
    battleStyle = options.battleStyle,
    soundMode = options.soundMode,
    textFrame = options.textFrame,
    battleSpeed = options.battleSpeed,
  }
end

---@param rowId string
---@param draft OptionsScreenState.Draft
---@return unknown value
local function draftValue(rowId, draft)
  if rowId == "volume" then
    return draft.volume
  end
  return draft[rowId]
end

---@param rowId string
---@param draft OptionsScreenState.Draft
---@return integer index
local function draftIndex(rowId, draft)
  return OptionsRows.indexFor(rowId, draftValue(rowId, draft))
end

---@param rowId string
---@param index integer
---@return unknown value
local function valueAt(rowId, index)
  return OptionsRows.valueAt(rowId, index)
end

---@class OptionsScreenState.Options
---@field playerOptions OptionsScreenState.PlayerOptions the six committed player fields
---@field volume integer the committed app-wide percent
---@field preparePlayerOptions fun(values: OptionsScreenState.PlayerOptions): fun()? the player-options one-use application closure factory
---@field audioPreferences OptionsScreenState.VolumePort the borrowed app-wide volume port
---@field applyChannelMode fun(mode: string) the live sink channel preview/restore collaborator
---@field effect fun(sequence: string) the source UI sound boundary
---@field semantic OptionsScreenState.Semantic? generated labels/metrics ({ labels = ... })
---@field measureDisplay (fun(): DisplayMeasurement)? the live display facts (absent in headless tests)
---@field presentationPort FieldPresentationResources.OptionsPresentationPort? the per-open resource port (absent headless)
---@field previewPrinter FieldDialogueController? a separate dialogue printer for the menu-local sample
---@field overrides table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>? per-case interface overrides

---@param opts OptionsScreenState.Options
---@return OptionsScreenState
function OptionsScreenState.new(opts)
  assert(type(opts) == "table", "the options screen requires options")
  local committed = assert(opts.playerOptions, "the options screen requires the committed player options")
  local volume = assert(opts.volume, "the options screen requires the committed volume")
  assert(type(volume) == "number" and volume % 1 == 0 and volume >= 0 and volume <= 100, "volume stays 0..100")
  local prepare = assert(opts.preparePlayerOptions, "the options screen requires its player-options preparation")
  assert(type(prepare) == "function", "the options screen requires its player-options preparation")
  local audio = assert(opts.audioPreferences, "the options screen requires its volume port")
  assert(
    type(audio.read) == "function"
      and type(audio.preview) == "function"
      and type(audio.commit) == "function"
      and type(audio.restore) == "function",
    "the volume port carries read/preview/commit/restore"
  )
  local applyChannelMode = assert(opts.applyChannelMode, "the options screen requires its channel collaborator")
  assert(type(applyChannelMode) == "function", "the channel collaborator is a function")
  local effect = assert(opts.effect, "the options screen requires its sound boundary")
  assert(type(effect) == "function", "the sound boundary is a function")
  local self = setmetatable({
    _preparePlayerOptions = prepare,
    _audio = audio,
    _applyChannelMode = applyChannelMode,
    _effect = effect,
    _semantic = opts.semantic,
    _measureDisplay = opts.measureDisplay,
    _presentationPort = opts.presentationPort,
    _previewPrinter = opts.previewPrinter,
    _disposed = false,
    _phase = "open",
    _preparing = opts.presentationPort ~= nil,
    _committed = false,
    _result = nil,
    _error = nil,
    _focusId = "textSpeed",
    _scrollOffset = 0,
    _capture = nil,
    _previewOpen = false,
  }, OptionsScreenState)
  self._baseline = copyOptions(committed)
  self._baselineVolume = volume
  self._baselineChannel = committed.soundMode
  self._draft = copyOptions(committed)
  self._draft.volume = volume
  self._legacyNote = false
  if committed.textSpeed == "slow" then
    self._draft.textSpeed = "mid"
    self._legacyNote = true
  end
  local built = true
  local buildErr = nil
  if self._presentationPort ~= nil then
    built, buildErr = pcall(function()
      assert(self._measureDisplay ~= nil, "a presented options screen requires the display facts")
      self._session = ApplicationPresentation.new(OptionsInterface.defaults(), opts.overrides)
      self._session:resolve(self:_measured(), self:_view())
    end)
  end
  if not built then
    self:_releaseOwned()
    error(buildErr, 0)
  end
  self:_restartPreview()
  return self
end

function OptionsScreenState:_releaseOwned()
  if self._previewOpen and self._previewPrinter ~= nil then
    self._previewPrinter:close()
    self._previewOpen = false
  end
  if self._session ~= nil then
    self._session:dispose()
    self._session = nil
  end
end

---@return DisplayMeasurement
function OptionsScreenState:_measured()
  local measure = assert(self._measureDisplay, "a presented options screen requires the display facts")
  return assert(measure(), "the options screen requires current display facts")
end

---@return table<string, unknown> the controller snapshot for resolvers and renderers
function OptionsScreenState:_view()
  local rows = {}
  for _, rowId in ipairs(OptionsInterface.ROW_IDS) do
    rows[#rows + 1] = {
      id = rowId,
      kind = OptionsInterface.rowKind(rowId),
      label = self:_rowLabel(rowId),
      value = draftValue(rowId, self._draft),
      valueLabel = self:_valueLabel(rowId, self._draft),
      valueIndex = draftIndex(rowId, self._draft),
      valueCount = OptionsInterface.valueCount(rowId),
      choiceLabels = OptionsRows.choiceLabels(rowId, self:_labels()),
    }
  end
  local labels = self:_labels()
  return {
    open = self._phase == "open",
    preparing = self._preparing,
    rows = rows,
    focusId = self._focusId,
    scrollOffset = self._scrollOffset,
    dirty = self:_draftDirty(),
    legacyNote = self._legacyNote or nil,
    preview = self:_previewView(),
    footer = {
      confirm = {
        enabled = not self._preparing and self._phase == "open",
        label = (labels ~= nil and labels.confirm ~= nil and labels.confirm.text) or "CONFIRM",
      },
      quit = {
        label = (labels ~= nil and labels.quit ~= nil and labels.quit.text) or "QUIT",
      },
    },
    error = self._error,
  }
end

---@param rowId string
---@return string
local function fallbackRowLabel(rowId)
  local labels = {
    textSpeed = "TEXT SPEED",
    battleScene = "BATTLE SCENE",
    battleStyle = "BATTLE STYLE",
    soundMode = "SOUND",
    textFrame = "FRAME",
    volume = "VOLUME",
    battleSpeed = "BATTLE SPEED",
  }
  return assert(labels[rowId], "unknown options row " .. tostring(rowId))
end

-- The preview snapshot: the draft speed/frame plus the currently revealed
-- token lines borrowed from the menu-local printer. A headless screen
-- without a printer publishes only the draft pair; the borrowed lines stay
-- valid until the next printer step and are never retained across ticks.
---@return table<string, unknown>
function OptionsScreenState:_previewView()
  local preview = { textSpeed = self._draft.textSpeed, textFrame = self._draft.textFrame }
  if self._previewOpen and self._previewPrinter ~= nil then
    local status = self._previewPrinter:status()
    preview.visibleLines = status.visibleLines
    preview.scrollLines = status.scrollLines
    preview.lineHeight = status.lineHeight
    preview.lineSpacing = status.lineSpacing
    preview.scrollOffsetY = status.scrollOffsetY
  end
  return preview
end

---@return table<string, unknown>? generated labels or nil
function OptionsScreenState:_labels()
  local semantic = self._semantic
  if type(semantic) == "table" and type(semantic.labels) == "table" then
    return semantic.labels
  end
  return nil
end

---@param rowId string
---@return string
function OptionsScreenState:_rowLabel(rowId)
  local labels = self:_labels()
  if labels ~= nil and labels[rowId] ~= nil and type(labels[rowId].text) == "string" then
    return labels[rowId].text
  end
  return fallbackRowLabel(rowId)
end

---@param rowId string
---@param draft OptionsScreenState.Draft
---@return string
function OptionsScreenState:_valueLabel(rowId, draft)
  if OptionsRows.rowKind(rowId) == "choice" then
    local ordered = assert(OptionsRows.choiceLabels(rowId, self:_labels()), "choice rows label every stop")
    return assert(ordered[OptionsRows.indexFor(rowId, draftValue(rowId, draft))], "choice stops stay labeled")
  end
  local labels = self:_labels()
  if rowId == "textFrame" then
    local frame = assert(draft.textFrame, "frame drafts carry their frame")
    if labels ~= nil and labels.frameValues ~= nil and labels.frameValues[frame] ~= nil then
      local entry = labels.frameValues[frame]
      if type(entry.text) == "string" then
        return entry.text
      end
    end
    return "TYPE " .. (frame + 1)
  elseif rowId == "volume" then
    return tostring(assert(draft.volume, "volume drafts carry their percent")) .. "%"
  end
  assert(rowId == "battleSpeed", "unknown options row " .. tostring(rowId))
  return tostring(assert(draft.battleSpeed, "speed drafts carry their stop")) .. "x"
end

---@return boolean
function OptionsScreenState:_draftDirty()
  local baseline = self._baseline
  local draft = self._draft
  if self._legacyNote then
    return true
  end
  for _, key in ipairs({ "textSpeed", "battleScene", "battleStyle", "soundMode", "textFrame", "battleSpeed" }) do
    if draft[key] ~= baseline[key] then
      return true
    end
  end
  return draft.volume ~= self._baselineVolume
end

-- The presentation snapshot: the semantic view plus the session plan
-- when presented. Fresh tables per call; no live renderer, pool, or port
-- leaks into the status.
---@return table<string, unknown>
function OptionsScreenState:status()
  local status = self:_view()
  if self._session ~= nil then
    status.presentation = self._session:plan()
  end
  return status
end

-- Restarts the menu-local preview sample on the separate printer: the
-- draft policy paces it, the draft frame borders it, and menu ticks
-- advance it without any gameplay acceleration input.
function OptionsScreenState:_restartPreview()
  local printer = self._previewPrinter
  if printer == nil then
    return
  end
  if self._previewOpen then
    printer:close()
    self._previewOpen = false
  end
  if self._phase ~= "open" then
    return
  end
  local message = self:_previewMessage()
  printer:setPolicy(TextSpeedPolicy.forSpeed(self._draft.textSpeed))
  printer:open({
    id = "options-preview",
    message = message,
    frameIndex = self._draft.textFrame,
    allowCancel = false,
  })
  self._previewOpen = true
end

---@return FieldMessageProvider.FormattedMessage formatted preview message tokens
function OptionsScreenState:_previewMessage()
  local semantic = assert(self._semantic, "the options preview needs its generated section")
  local message = assert(
    semantic.framePreviewText[self._draft.textFrame],
    "the selected frame requires its generated preview message"
  )
  assert(type(message.tokens) == "table" and #message.tokens > 0, "the options preview uses a formatted token stream")
  return message --[[@as FieldMessageProvider.FormattedMessage]]
end

-- Applies one validated row value to the draft with its reversible
-- preview: volume and channel mode reach the running audio immediately,
-- frame and text stay local until Confirm.
---@param rowId string
---@param value unknown
---@param silent boolean? skip navigation feedback (pointer drags)
function OptionsScreenState:_editRow(rowId, value, silent)
  if self._phase ~= "open" then
    return
  end
  if rowId == "volume" then
    assert(type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 100, "volume stays 0..100")
    if value == self._draft.volume then
      return
    end
    self._draft.volume = value
    self._audio.preview(value)
    return
  end
  if rowId == "battleSpeed" then
    if value == self._draft.battleSpeed then
      return
    end
    self._draft.battleSpeed = value
    return
  end
  if rowId == "textSpeed" then
    if value == self._draft.textSpeed then
      return
    end
    self._draft.textSpeed = value
    self:_restartPreview()
    if not silent then
      self._effect(SELECT_SOUND)
    end
    return
  end
  if rowId == "textFrame" then
    if value == self._draft.textFrame then
      return
    end
    self._draft.textFrame = value
    self:_restartPreview()
    if not silent then
      self._effect(SELECT_SOUND)
    end
    return
  end
  if rowId == "soundMode" then
    if value == self._draft.soundMode then
      return
    end
    self._draft.soundMode = value
    self._applyChannelMode(value)
    if not silent then
      self._effect(SELECT_SOUND)
    end
    return
  end
  if rowId == "battleScene" then
    if value == self._draft.battleScene then
      return
    end
    self._draft.battleScene = value
    if not silent then
      self._effect(SELECT_SOUND)
    end
    return
  end
  assert(rowId == "battleStyle", "unknown options row " .. tostring(rowId))
  if value == self._draft.battleStyle then
    return
  end
  self._draft.battleStyle = value
  if not silent then
    self._effect(SELECT_SOUND)
  end
end

---@param rowId string
---@param direction string "left"|"right"
function OptionsScreenState:_stepRow(rowId, direction)
  local count = OptionsInterface.valueCount(rowId)
  local index = draftIndex(rowId, self._draft)
  if direction == "left" then
    index = math.max(1, index - 1)
  else
    index = math.min(count, index + 1)
  end
  self:_editRow(rowId, valueAt(rowId, index), false)
end

-- Keeps the focused row fully visible: scrolling never edits values or
-- moves focus, it only reveals the focused row.
function OptionsScreenState:_ensureVisible()
  local position = nil
  for index, rowId in ipairs(OptionsInterface.ROW_IDS) do
    if rowId == self._focusId then
      position = index
      break
    end
  end
  if position == nil then
    return
  end
  local extent = self:_listExtent()
  local itemStart = (position - 1) * OptionsInterface.ROW_HEIGHT
  self._scrollOffset = ScrollViewport.reveal(self._scrollOffset, extent, itemStart, OptionsInterface.ROW_HEIGHT)
end

---@return integer visible list height
function OptionsScreenState:_listExtent()
  if self._session ~= nil then
    local plan = self._session:plan()
    if plan ~= nil and plan.content ~= nil and plan.content.listViewport ~= nil then
      return plan.content.listViewport.height
    end
  end
  return 88
end

---@param direction string
function OptionsScreenState:_moveFocus(direction)
  self._focusId = OptionsInterface.focusNext(self._focusId, direction)
  self:_ensureVisible()
  self._effect(SELECT_SOUND)
end

-- The fixed confirmation order: validate and prepare the six player
-- fields first, publish the app-wide volume second, then run the
-- prevalidated synchronous application. A recoverable storage failure
-- leaves the menu open with its draft and baseline intact.
function OptionsScreenState:_confirm()
  if self._phase ~= "open" or self._preparing then
    return
  end
  self._error = nil
  local candidate = copyOptions(self._draft)
  local apply, invalid = self._preparePlayerOptions(candidate)
  if apply == nil then
    self._error = (type(invalid) == "table" and invalid.message) or tostring(invalid)
    return
  end
  local published, failure = pcall(self._audio.commit, self._draft.volume)
  if not published then
    self._error = tostring(failure)
    return
  end
  apply()
  self._committed = true
  self._capture = nil
  self._effect(SAVE_SOUND)
  self._effect(BUTTON_SOUND)
  self._phase = "closed"
  self._result = { kind = "close" }
  if self._previewOpen and self._previewPrinter ~= nil then
    self._previewPrinter:close()
    self._previewOpen = false
  end
end

-- Every uncommitted terminal path restores the committed baseline: the
-- app-wide gain returns and the live channel mode returns, while the
-- player record is never touched.
function OptionsScreenState:_quit()
  if self._phase ~= "open" then
    return
  end
  self._capture = nil
  self._audio.restore()
  self._applyChannelMode(self._baselineChannel)
  self._effect(CANCEL_SOUND)
  self._phase = "closed"
  self._result = { kind = "close" }
  if self._previewOpen and self._previewPrinter ~= nil then
    self._previewPrinter:close()
    self._previewOpen = false
  end
end

---@param event table<string, unknown>
function OptionsScreenState:_applyEvent(event)
  if self._phase ~= "open" then
    return
  end
  local kind = event.type
  if kind == "navigate" then
    local direction = assert(event.direction, "navigate events carry a direction")
    if direction == "up" or direction == "down" then
      self._capture = nil
      self:_moveFocus(direction)
    elseif direction == "left" or direction == "right" then
      if OptionsInterface.isRow(self._focusId) then
        self:_stepRow(self._focusId, direction)
      else
        self:_moveFocus(direction)
      end
    end
    return
  end
  if kind == "confirm" then
    if self._focusId == "confirm" then
      self:_confirm()
    elseif self._focusId == "quit" then
      self:_quit()
    end
    return
  end
  if kind == "cancel" or kind == "menu" or kind == "dismiss" then
    self:_quit()
    return
  end
  if kind == "activate" then
    local id = assert(event.id, "activate events carry an id")
    if id == "confirm" then
      self:_confirm()
    elseif id == "quit" then
      self:_quit()
    end
    return
  end
  if kind == "direct-select" then
    local row = assert(event.row, "direct selection carries its row")
    local index = assert(event.index, "direct selection carries its stop")
    local count = OptionsInterface.valueCount(row)
    index = math.max(1, math.min(count, index))
    self:_editRow(row, valueAt(row, index), false)
    return
  end
  if kind == "slider-set" then
    local row = assert(event.row, "slider edits carry their row")
    local index = assert(event.index, "slider edits carry their stop")
    local count = OptionsInterface.valueCount(row)
    index = math.max(1, math.min(count, index))
    self:_editRow(row, valueAt(row, index), true)
    return
  end
  if kind == "scroll" then
    if self._capture ~= nil and self._capture.owned then
      return
    end
    self._capture = nil
    local delta = event.delta or 0
    local total = #OptionsInterface.ROW_IDS * OptionsInterface.ROW_HEIGHT
    self._scrollOffset = ScrollViewport.clamp(self._scrollOffset + delta, total, self:_listExtent())
    return
  end
  if kind == "pointer_down" or kind == "pointer_move" or kind == "pointer_up" then
    self:_pointerEvent(kind, event)
    return
  end
  if kind == "pointer_cancel" or kind == "resize" or kind == "blur" then
    self._capture = nil
    return
  end
end

-- One captured pointer: footer buttons arm on press and activate on a
-- matching release, value choices arm on press and select on a matching
-- release, and slider drags own their gesture while captured. Any
-- cancellation keeps the last valid draft value and drops the capture.
---@param kind string
---@param event table<string, unknown>
function OptionsScreenState:_pointerEvent(kind, event)
  local plan = nil
  if self._session ~= nil then
    plan = self._session:plan()
  end
  local hit = nil
  if plan ~= nil and plan.content ~= nil and event.x ~= nil and event.y ~= nil then
    hit = OptionsInterface.hitTest(plan.content, event.x, event.y)
  elseif event.hit ~= nil then
    hit = event.hit
  end
  if kind == "pointer_down" then
    if self._capture ~= nil then
      return
    end
    if hit == nil then
      if plan ~= nil and plan.content ~= nil and event.x ~= nil and event.y ~= nil then
        if OptionsInterface.inList(plan.content, event.x, event.y) then
          self._capture = { pointerId = event.pointerId, list = true, lastY = event.y }
        end
      end
      return
    end
    self._capture = {
      pointerId = event.pointerId,
      hit = hit,
      armed = true,
      owned = hit.control == "thumb",
    }
    if hit.control == "thumb" then
      self:_applyEvent({ type = "slider-set", row = hit.target, index = hit.index })
    end
    return
  end
  local capture = self._capture
  if capture == nil then
    return
  end
  if event.pointerId ~= nil and capture.pointerId ~= nil and event.pointerId ~= capture.pointerId then
    return
  end
  if kind == "pointer_move" then
    if capture.list then
      if event.y ~= nil then
        local total = #OptionsInterface.ROW_IDS * OptionsInterface.ROW_HEIGHT
        self._scrollOffset =
          ScrollViewport.clamp(self._scrollOffset + (capture.lastY - event.y), total, self:_listExtent())
        capture.lastY = event.y
      end
      return
    end
    if capture.owned then
      if hit ~= nil and hit.target == capture.hit.target and hit.index ~= nil then
        self:_applyEvent({ type = "slider-set", row = hit.target, index = hit.index })
      end
      return
    end
    if hit == nil or hit.target ~= capture.hit.target or hit.control ~= capture.hit.control then
      capture.armed = false
    end
    return
  end
  -- pointer_up: a matching release commits the armed press; a dragged or
  -- re-targeted release only drops the capture.
  local armed = capture.armed
  self._capture = nil
  if not armed then
    return
  end
  if event.dragged == true then
    return
  end
  if hit == nil or hit.target ~= capture.hit.target or hit.control ~= capture.hit.control then
    return
  end
  if hit.target == "confirm" or hit.target == "quit" then
    self:_applyEvent({ type = "activate", id = hit.target })
  elseif hit.control == "left" then
    local index = draftIndex(hit.target, self._draft)
    self:_applyEvent({ type = "direct-select", row = hit.target, index = index - 1 })
  elseif hit.control == "right" then
    local index = draftIndex(hit.target, self._draft)
    self:_applyEvent({ type = "direct-select", row = hit.target, index = index + 1 })
  elseif hit.control == "value" and hit.index ~= nil then
    self:_applyEvent({ type = "direct-select", row = hit.target, index = hit.index })
  end
end

-- One fixed tick: resolve, map one ordered batch, advance the draft
-- machine once, resolve again for the resulting snapshot. Confirm and
-- Quit stop processing the remaining batch.
---@param uiInput table[]
function OptionsScreenState:updateFixed(uiInput)
  assert(not self._disposed, "a disposed options screen steps nothing")
  if self._phase == "closed" then
    return
  end
  assert(type(uiInput) == "table", "the options input must be an event list")
  if self._session ~= nil then
    local measurement = self:_measured()
    self._session:resolve(measurement, self:_view())
  end
  local batch = uiInput
  if self._session ~= nil then
    batch = self._session:mapInput(uiInput, self:_view())
  end
  for _, event in ipairs(batch) do
    if self._phase ~= "open" then
      break
    end
    self:_applyEvent(event)
  end
  if self._previewPrinter ~= nil and self._previewOpen then
    self._previewPrinter:step({})
  end
  if self._session ~= nil then
    if self._presentationPort ~= nil and self._preparing then
      local ok, ready = pcall(function()
        return self._presentationPort.prepare()
      end)
      if ok and ready then
        self._preparing = false
      elseif not ok then
        self:_releaseOwned()
        error(ready, 0)
      end
    end
    self._session:resolve(self:_measured(), self:_view())
  end
end

-- The host result contract: exactly one close, whether the menu
-- confirmed, quit, or was disposed uncommitted.
---@return { kind: "close" }?
function OptionsScreenState:takeResult()
  local result = self._result
  self._result = nil
  return result
end

-- Cancels a held press through the session so a stale release never
-- activates after reflow. The draft keeps its last valid value.
function OptionsScreenState:cancelPointerCapture()
  if self._session ~= nil then
    self._session:cancelPointers()
  end
  self._capture = nil
end

-- Releases the session and the per-open port exactly once. An
-- uncommitted disposal restores audio before borrowed audio owners are
-- released; a committed disposal never rolls settings back.
function OptionsScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  if not self._committed and self._phase ~= "closed" then
    pcall(function()
      self._audio.restore()
    end)
    pcall(function()
      self._applyChannelMode(self._baselineChannel)
    end)
    self._phase = "closed"
  end
  if self._presentationPort ~= nil then
    local port = assert(self._presentationPort, "a per-open options port disposes before release")
    local disposePort = assert(port.dispose, "a per-open options port disposes before release")
    pcall(disposePort)
    self._presentationPort = nil
  end
  self:_releaseOwned()
  self._session = nil
end

return OptionsScreenState
