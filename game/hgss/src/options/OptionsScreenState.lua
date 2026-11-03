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
local Slider = require("libs.ui.src.Slider")
local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")

-- The one row-specific stop normalizer: the frame carousel wraps 1..20
-- in either direction while every other row keeps its bounded clamp.
---@param rowId string
---@param candidate integer 1-based candidate stop
---@return integer normalized 1-based stop
local function normalizeIndex(rowId, candidate)
  assert(type(candidate) == "number" and candidate % 1 == 0, "option stops stay integral")
  if rowId == "textFrame" then
    return ((candidate - 1) % 20) + 1
  end
  local count = OptionsInterface.valueCount(rowId)
  if candidate < 1 then
    return 1
  elseif candidate > count then
    return count
  end
  return candidate
end

-- Sums one compiled source animation sequence, validating its tick
-- shape. Missing frames or a nonpositive total fails the presented
-- screen so a half-wired press never arms silently.
---@param sequence table<string, unknown> compiled { frames = { { ticks = integer } } }
---@param what string semantic role for failure detail
---@return integer total source ticks
local function sequenceTotal(sequence, what)
  assert(
    type(sequence) == "table" and type(sequence.frames) == "table" and #sequence.frames >= 1,
    what .. " must carry at least one frame"
  )
  local total = 0
  for _, frame in ipairs(sequence.frames) do
    assert(
      type(frame.ticks) == "number" and frame.ticks % 1 == 0 and frame.ticks >= 0,
      what .. " frame durations must be non-negative integers"
    )
    total = total + frame.ticks
  end
  assert(total > 0, what .. " animation must advance")
  return total
end

---@class OptionsScreenState
---@field _preparePlayerOptions fun(values: OptionsScreenState.PlayerOptions): { apply: fun(), rollback: fun() }? the player-options one-attempt factory
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
---@field _pressVisual table<string, unknown>? one visible arrow/footer press in source ticks
---@field _pendingFooterAction table<string, unknown>? one deferred footer activation during its source sequence
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
---@field section table<string, unknown>? test-seam nested compiled animation section
---@field arrows table<string, unknown>? compiled arrow animation states (presented semantic)
---@field actions table<string, unknown>? compiled footer action states (presented semantic)

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

-- Restores a failed confirmation attempt: a restoration failure is
-- terminal and names both the original cause and the restore cause.
---@param transaction { apply: fun(), rollback: fun() }
---@param cause unknown the original apply/publication failure
local function rollbackOrRaise(transaction, cause)
  local restored, restoreErr = pcall(transaction.rollback)
  if not restored then
    error(
      "options confirmation failed and restoration failed: "
        .. tostring(cause)
        .. "; restoration: "
        .. tostring(restoreErr),
      0
    )
  end
end

---@class OptionsScreenState.Options
---@field playerOptions OptionsScreenState.PlayerOptions the six committed player fields
---@field volume integer the committed app-wide percent
---@field preparePlayerOptions fun(values: OptionsScreenState.PlayerOptions): { apply: fun(), rollback: fun() }? the player-options one-attempt factory
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
    _pressVisual = nil,
    _pendingFooterAction = nil,
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
  local built, buildErr = pcall(function()
    if self._presentationPort ~= nil then
      assert(self._measureDisplay ~= nil, "a presented options screen requires the display facts")
    end
    if self._measureDisplay ~= nil then
      local measured = self._measureDisplay()
      if measured ~= nil then
        self._session = ApplicationPresentation.new(OptionsInterface.defaults(), opts.overrides)
        self._session:resolve(measured, self:_view())
        local section = self:_animationSection()
        if section ~= nil then
          self:_validateAnimationSection(section)
        end
      elseif self._presentationPort ~= nil then
        error("a presented options screen requires the display facts", 0)
      end
    end
    self:_restartPreview()
  end)
  if not built then
    self:_releaseOwned()
    error(buildErr, 0)
  end
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

-- The presented source animation section: the test seam nests it under
-- semantic.section while production presents the whole generated options
-- section as the semantic record. Absent art means headless-instant
-- behavior with no visual state. Never mutates source frames.
---@return table<string, unknown>? compiled arrows/actions section or nil
function OptionsScreenState:_animationSection()
  local semantic = self._semantic
  if type(semantic) ~= "table" then
    return nil
  end
  local nested = semantic.section
  if type(nested) == "table" then
    return nested
  end
  if semantic.arrows ~= nil or semantic.actions ~= nil then
    return semantic
  end
  return nil
end

-- Validates one presented source animation section once: both arrow
-- sides carry idle and pressed states and every footer state carries a
-- positive total. Headless screens without art skip this entirely.
---@param section table<string, unknown>
function OptionsScreenState:_validateAnimationSection(section)
  local arrows = assert(section.arrows, "the options section carries its arrows")
  for _, side in ipairs({ "left", "right" }) do
    local pair = assert(arrows[side], "arrows carry both sides")
    sequenceTotal(assert(pair.idle, "arrows carry idle and pressed states"), "arrows." .. side .. ".idle")
    sequenceTotal(assert(pair.pressed, "arrows carry idle and pressed states"), "arrows." .. side .. ".pressed")
  end
  local actions = assert(section.actions, "the options section carries footer actions")
  for _, stateName in ipairs({ "normal", "focused", "pressed", "pressedFocused" }) do
    sequenceTotal(assert(actions[stateName], "actions carry every compiled state"), "actions." .. stateName)
  end
end

-- Totals one already-validated source sequence for a new press: the
-- arrow side pressed state or the matching footer pressed state.
---@param kind string "arrow"|"footer"
---@param sideOrAction string arrow side or footer action id
---@param focused boolean whether the pressed control holds focus
---@return integer? total source ticks, nil without art
function OptionsScreenState:_pressTotal(kind, sideOrAction, focused)
  local section = self:_animationSection()
  if section == nil then
    return nil
  end
  if kind == "arrow" then
    local arrows = assert(section.arrows, "the options section carries its arrows")
    local pair = assert(arrows[sideOrAction], "arrows carry both sides")
    return sequenceTotal(
      assert(pair.pressed, "arrows carry idle and pressed states"),
      "arrows." .. sideOrAction .. ".pressed"
    )
  end
  assert(kind == "footer", "press totals name an arrow or footer press")
  local actions = assert(section.actions, "the options section carries footer actions")
  local key = focused and "pressedFocused" or "pressed"
  return sequenceTotal(assert(actions[key], "actions carry every compiled state"), "actions." .. key)
end

-- Advances one source-tick visual and completes one pending footer
-- activation: pending clears before invoking so a feedback exception
-- cannot duplicate the commit. Arrow pulses clear at their one-shot
-- total; held presses persist on their final frame until release.
function OptionsScreenState:_advanceVisual()
  local visual = self._pressVisual
  if visual ~= nil then
    visual.ageTicks = visual.ageTicks + 1
  end
  local pending = self._pendingFooterAction
  if pending == nil then
    if visual ~= nil and visual.held == false and visual.kind == "arrow" then
      local total = self:_pressTotal("arrow", assert(visual.side, "arrow presses name their side"), false)
      if total ~= nil and visual.ageTicks >= total then
        self._pressVisual = nil
      end
    end
    return
  end
  pending.remainingTicks = pending.remainingTicks - 1
  if pending.remainingTicks <= 0 then
    local id = assert(pending.id, "pending footer actions name their action")
    self._pendingFooterAction = nil
    self._pressVisual = nil
    if id == "confirm" then
      self:_confirm()
    else
      assert(id == "quit", "pending footer actions name confirm or quit")
      self:_quit()
    end
  end
end

---@return table<string, unknown> the controller snapshot for resolvers and renderers
function OptionsScreenState:_view()
  local labels = self:_labels()
  local rows = {}
  for _, rowId in ipairs(OptionsInterface.ROW_IDS) do
    -- Slider row names stay authored: Volume and Battle Speed values are
    -- numeric, so they have no source records by design.
    local sourceLabel = nil
    if OptionsInterface.rowKind(rowId) ~= "slider" and labels ~= nil then
      sourceLabel = labels[rowId]
    end
    if sourceLabel ~= nil then
      assert(type(sourceLabel.text) == "string", "options row labels carry their diagnostic text")
    end
    local valueSource = nil
    if rowId == "textFrame" and labels ~= nil and labels.frameValues ~= nil then
      local frame = assert(self._draft.textFrame, "frame drafts carry their frame")
      valueSource = labels.frameValues[frame]
    end
    rows[#rows + 1] = {
      id = rowId,
      kind = OptionsInterface.rowKind(rowId),
      label = self:_rowLabel(rowId),
      sourceLabel = sourceLabel,
      value = draftValue(rowId, self._draft),
      valueLabel = self:_valueLabel(rowId, self._draft),
      valueSource = valueSource,
      valueIndex = draftIndex(rowId, self._draft),
      valueCount = OptionsInterface.valueCount(rowId),
      choiceLabels = OptionsRows.choiceLabels(rowId, self:_labels()),
      choiceDisplay = OptionsRows.choicePresentation(rowId, self:_labels()),
    }
  end
  local titleSource = labels ~= nil and labels.title or nil
  local confirmSource = labels ~= nil and labels.confirm or nil
  local quitSource = labels ~= nil and labels.quit or nil
  return {
    open = self._phase == "open",
    preparing = self._preparing,
    rows = rows,
    focusId = self._focusId,
    scrollOffset = self._scrollOffset,
    dirty = self:_draftDirty(),
    legacyNote = self._legacyNote or nil,
    preview = self:_previewView(),
    titleSource = titleSource,
    footer = {
      confirm = {
        enabled = not self._preparing and self._phase == "open",
        label = (labels ~= nil and labels.confirm ~= nil and labels.confirm.text) or "CONFIRM",
        sourceLabel = confirmSource,
      },
      quit = {
        label = (labels ~= nil and labels.quit ~= nil and labels.quit.text) or "QUIT",
        sourceLabel = quitSource,
      },
    },
    error = self._error,
    pressVisual = self:_pressSnapshot(),
  }
end

-- One immutable per-tick visual snapshot for the renderer: never source
-- frames, only the pressed kind/side/action, the source age, the held
-- flag, and focus. Nil when no press paints.
---@return table<string, unknown>?
function OptionsScreenState:_pressSnapshot()
  local visual = self._pressVisual
  if visual == nil then
    return nil
  end
  local snapshot = {
    kind = visual.kind,
    ageTicks = visual.ageTicks,
    held = visual.held,
    focused = visual.focused,
  }
  if visual.side ~= nil then
    snapshot.side = visual.side
  end
  if visual.actionId ~= nil then
    snapshot.actionId = visual.actionId
  end
  if visual.rowId ~= nil then
    snapshot.rowId = visual.rowId
  end
  return snapshot
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
  local index = draftIndex(rowId, self._draft)
  local candidate = index
  if direction == "left" then
    candidate = index - 1
  else
    candidate = index + 1
  end
  candidate = normalizeIndex(rowId, candidate)
  self:_editRow(rowId, valueAt(rowId, candidate), false)
  if rowId == "textFrame" and self:_animationSection() ~= nil then
    self._pressVisual = {
      kind = "arrow",
      side = direction,
      rowId = rowId,
      ageTicks = 0,
      held = false,
      focused = self._focusId == rowId,
    }
  end
end

-- Keeps the focused row fully visible: scrolling never edits values or
-- moves focus, it only reveals the focused interval. Focusing the closing
-- frame reveals its whole 64px item, sample window included.
function OptionsScreenState:_ensureVisible()
  if not OptionsInterface.isRow(self._focusId) then
    return
  end
  self._scrollOffset = OptionsInterface.revealRow(self._scrollOffset, self._focusId, self:_listExtent())
end

---@return integer visible list height
function OptionsScreenState:_listExtent()
  if self._session ~= nil then
    local plan = self._session:plan()
    if plan ~= nil and plan.content ~= nil and plan.content.listViewport ~= nil then
      return plan.content.listViewport.height
    end
  end
  return 144
end

-- Settles a released list drag without touching values or focus: a
-- focused frame always rests fully revealed; otherwise a drag ending
-- with the frame only partially visible rests fully revealed when the
-- gesture moved toward the end, or back at the top when it moved toward
-- the start. With this leaf's 64px overflow, a strictly interior offset
-- is exactly the partially visible frame. Active drags never settle.
---@param startY number? logical press y
---@param releaseY number? logical release y
function OptionsScreenState:_settleListScroll(startY, releaseY)
  if self._focusId == "textFrame" then
    self._scrollOffset = OptionsInterface.revealRow(self._scrollOffset, "textFrame", self:_listExtent())
    return
  end
  if type(startY) ~= "number" or type(releaseY) ~= "number" or releaseY == startY then
    return
  end
  local max = math.max(0, OptionsInterface.totalHeight() - self:_listExtent())
  if self._scrollOffset <= 0 or self._scrollOffset >= max then
    return
  end
  if releaseY < startY then
    self._scrollOffset = max
  else
    self._scrollOffset = 0
  end
end

---@param direction string
function OptionsScreenState:_moveFocus(direction)
  self._focusId = OptionsInterface.focusNext(self._focusId, direction)
  self:_ensureVisible()
  self._effect(SELECT_SOUND)
end

-- The fixed confirmation order: prepare the reversible six-field
-- attempt, run its player application, then publish the app-wide volume
-- as the final durable step. Either failure restores the committed
-- player state, reapplies the still-open draft channel preview, and
-- leaves the menu open with its draft. Success settles before feedback.
function OptionsScreenState:_confirm()
  if self._phase ~= "open" or self._preparing then
    return
  end
  self._error = nil
  local candidate = copyOptions(self._draft)
  local transaction, invalid = self._preparePlayerOptions(candidate)
  if transaction == nil then
    self._error = (type(invalid) == "table" and invalid.message) or tostring(invalid)
    return
  end
  local applied, applyErr = pcall(transaction.apply)
  if not applied then
    rollbackOrRaise(transaction, applyErr)
    self._applyChannelMode(self._draft.soundMode)
    self._error = tostring(applyErr)
    return
  end
  local published, volumeErr = pcall(self._audio.commit, self._draft.volume)
  if not published then
    rollbackOrRaise(transaction, volumeErr)
    self._applyChannelMode(self._draft.soundMode)
    self._error = tostring(volumeErr)
    return
  end
  self._committed = true
  self._phase = "closed"
  self._result = { kind = "close" }
  self._capture = nil
  self._pressVisual = nil
  self._pendingFooterAction = nil
  if self._previewOpen and self._previewPrinter ~= nil then
    self._previewPrinter:close()
    self._previewOpen = false
  end
  self._effect(SAVE_SOUND)
  self._effect(BUTTON_SOUND)
end

-- Every uncommitted terminal path restores the committed baseline: the
-- app-wide gain returns and the live channel mode returns, while the
-- player record is never touched.
function OptionsScreenState:_quit()
  if self._phase ~= "open" then
    return
  end
  self._capture = nil
  self._pressVisual = nil
  self._pendingFooterAction = nil
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

-- Arms one deferred footer activation once the source pressed sequence
-- completes: the visible press stays painted while pending, and pending
-- clears before invoking so a feedback exception cannot duplicate the
-- effect. Without presented art the activation stays instant.
---@param id string "confirm"|"quit"
function OptionsScreenState:_armFooter(id)
  assert(id == "confirm" or id == "quit", "footer activations name confirm or quit")
  local focused = self._focusId == id
  local total = self:_pressTotal("footer", id, focused)
  if total == nil then
    if id == "confirm" then
      self:_confirm()
    else
      self:_quit()
    end
    return
  end
  local age = 0
  local visual = self._pressVisual
  if type(visual) == "table" and visual.kind == "footer" and visual.actionId == id then
    age = assert(visual.ageTicks, "footer presses carry their source age")
  end
  self._pressVisual = { kind = "footer", actionId = id, ageTicks = age, held = false, focused = focused }
  local remaining = total - age
  if remaining < 0 then
    remaining = 0
  end
  if remaining < 1 then
    remaining = 1
  end
  self._pendingFooterAction = { id = id, remainingTicks = remaining }
end

---@param event table<string, unknown>
function OptionsScreenState:_applyEvent(event)
  if self._phase ~= "open" then
    return
  end
  local kind = event.type
  if kind == "pointer_cancel" then
    self._capture = nil
    self._pressVisual = nil
    self._pendingFooterAction = nil
    return
  end
  if kind == "resize" or kind == "blur" then
    self._capture = nil
    local visual = self._pressVisual
    if type(visual) == "table" and visual.held == true then
      self._pressVisual = nil
    end
    return
  end
  if self._pendingFooterAction ~= nil then
    return
  end
  if kind == "navigate" then
    local direction = assert(event.direction, "navigate events carry a direction")
    if direction == "up" or direction == "down" then
      self._capture = nil
      self._pressVisual = nil
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
      self:_armFooter("confirm")
    elseif self._focusId == "quit" then
      self:_armFooter("quit")
    end
    return
  end
  if kind == "cancel" or kind == "menu" or kind == "dismiss" then
    self:_quit()
    return
  end
  if kind == "activate" then
    local id = assert(event.id, "activate events carry an id")
    if id == "confirm" or id == "quit" then
      self:_armFooter(id)
    end
    return
  end
  if kind == "direct-select" then
    local row = assert(event.row, "direct selection carries its row")
    local index = assert(event.index, "direct selection carries its stop")
    index = normalizeIndex(row, index)
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
    self._scrollOffset =
      ScrollViewport.clamp(self._scrollOffset + delta, OptionsInterface.totalHeight(), self:_listExtent())
    return
  end
  if kind == "pointer_down" or kind == "pointer_move" or kind == "pointer_up" then
    self:_pointerEvent(kind, event)
    return
  end
end

-- Arms one visible arrow press for a true arrow hit, or clears any
-- staged visual when the press cannot paint. Without presented art no
-- visual arms and pointer behavior stays instant.
---@param hit table<string, unknown> resolved control hit
function OptionsScreenState:_beginArrowVisual(hit)
  if hit.control ~= "left" and hit.control ~= "right" then
    return
  end
  if self:_animationSection() == nil then
    return
  end
  self._pressVisual = {
    kind = "arrow",
    side = hit.control,
    rowId = hit.target,
    ageTicks = 0,
    held = true,
    focused = self._focusId == hit.target,
  }
end

-- Arms one visible footer press for a true footer hit. Without
-- presented art no visual arms and activation stays instant.
---@param hit table<string, unknown> resolved footer hit
function OptionsScreenState:_beginFooterVisual(hit)
  if hit.target ~= "confirm" and hit.target ~= "quit" then
    return
  end
  if self:_animationSection() == nil then
    return
  end
  self._pressVisual = {
    kind = "footer",
    actionId = hit.target,
    ageTicks = 0,
    held = true,
    focused = self._focusId == hit.target,
  }
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
          self._capture = { pointerId = event.pointerId, list = true, lastY = event.y, startY = event.y }
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
    elseif hit.control == "left" or hit.control == "right" then
      self:_beginArrowVisual(hit)
    elseif hit.target == "confirm" or hit.target == "quit" then
      self:_beginFooterVisual(hit)
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
        self._scrollOffset = ScrollViewport.clamp(
          self._scrollOffset + (capture.lastY - event.y),
          OptionsInterface.totalHeight(),
          self:_listExtent()
        )
        capture.lastY = event.y
      end
      return
    end
    if capture.owned then
      if hit ~= nil and hit.target == capture.hit.target and hit.index ~= nil then
        self:_applyEvent({ type = "slider-set", row = hit.target, index = hit.index })
      elseif type(event.x) == "number" and self._session ~= nil then
        local livePlan = self._session:plan()
        if livePlan ~= nil and livePlan.content ~= nil then
          for _, row in ipairs(assert(livePlan.content.rows, "content carries its rows")) do
            if row.id == capture.hit.target and row.control ~= nil and row.control.kind == "slider" then
              local resolved = assert(row.control.slider, "slider rows carry resolved geometry")
              local clamped = Slider.indexAt(resolved, event.x)
              self:_applyEvent({ type = "slider-set", row = row.id, index = clamped })
              break
            end
          end
        end
      end
      return
    end
    if hit == nil or hit.target ~= capture.hit.target or hit.control ~= capture.hit.control then
      capture.armed = false
      local visual = self._pressVisual
      if type(visual) == "table" and visual.held == true then
        self._pressVisual = nil
      end
    end
    return
  end
  -- pointer_up: a released list drag settles whole without editing
  -- anything; a matching control release commits the armed press, while
  -- a dragged or re-targeted release only drops the capture.
  if capture.list then
    local startY = capture.startY
    self._capture = nil
    self:_settleListScroll(startY, event.y)
    return
  end
  local armed = capture.armed
  local pressed = capture.hit
  self._capture = nil
  if not armed then
    if self._pressVisual ~= nil and self._pressVisual.held == true then
      self._pressVisual = nil
    end
    return
  end
  if event.dragged == true then
    if self._pressVisual ~= nil and self._pressVisual.held == true then
      self._pressVisual = nil
    end
    return
  end
  if hit == nil or hit.target ~= pressed.target or hit.control ~= pressed.control then
    if self._pressVisual ~= nil and self._pressVisual.held == true then
      self._pressVisual = nil
    end
    return
  end
  if hit.target == "confirm" or hit.target == "quit" then
    if self:_animationSection() ~= nil then
      self:_armFooter(hit.target)
    else
      self._pressVisual = nil
      self:_applyEvent({ type = "activate", id = hit.target })
    end
  elseif hit.control == "left" then
    local index = draftIndex(hit.target, self._draft)
    self:_applyEvent({ type = "direct-select", row = hit.target, index = index - 1 })
    if self:_animationSection() ~= nil then
      local visual = self._pressVisual
      if type(visual) == "table" and visual.kind == "arrow" then
        visual.held = false
      else
        self._pressVisual = {
          kind = "arrow",
          side = "left",
          rowId = hit.target,
          ageTicks = 0,
          held = false,
          focused = self._focusId == hit.target,
        }
      end
    else
      self._pressVisual = nil
    end
  elseif hit.control == "right" then
    local index = draftIndex(hit.target, self._draft)
    self:_applyEvent({ type = "direct-select", row = hit.target, index = index + 1 })
    if self:_animationSection() ~= nil then
      local visual = self._pressVisual
      if type(visual) == "table" and visual.kind == "arrow" then
        visual.held = false
      else
        self._pressVisual = {
          kind = "arrow",
          side = "right",
          rowId = hit.target,
          ageTicks = 0,
          held = false,
          focused = self._focusId == hit.target,
        }
      end
    else
      self._pressVisual = nil
    end
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
  if self._phase == "open" then
    self:_advanceVisual()
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
  self._pressVisual = nil
  self._pendingFooterAction = nil
end

-- Releases the session and the per-open port exactly once. An
-- uncommitted disposal restores audio before borrowed audio owners are
-- released; a committed disposal never rolls settings back.
function OptionsScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._capture = nil
  self._pressVisual = nil
  self._pendingFooterAction = nil
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
