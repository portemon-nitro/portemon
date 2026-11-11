-- The gear companion's retained shell: one application holding exactly the
-- setup, radio, map, and phone cards with source setup/run-child,
-- transition, and teardown states behind the existing four-method
-- application contract. Normal opens choose the remembered card with a
-- locked-card fallback to setup; a scripted call forces phone; a completed
-- exit remembers the actual last card. New children are acquired before the
-- published owner is replaced and every child disposes exactly once; a
-- failed acquisition keeps the last valid owner and propagates the original
-- failure. Strip focus walks only available slots with wrap and never leaks
-- into the parked card; call and word-entry busy classification stays
-- authoritative in child status. Pure module: no love, no I/O.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local StandardFade = require("libs.hgss.src.presentation.StandardFade")

---@class PokegearScreenState
---@field _state table<string, unknown> the borrowed durable companion owner
---@field _assets table<string, unknown> the borrowed compiled asset family
---@field _clock table<string, unknown> the injected civil-time boundary
---@field _children table<string, fun(context: table<string, unknown>): table<string, unknown>> the closed card-factory set
---@field _effect fun(sequence: string)? source UI sound effect boundary
---@field _measureDisplay fun(): DisplayMeasurement the live display facts
---@field _signal boolean the outgoing-call reception flag
---@field _session ApplicationPresentation the per-open presentation session
---@field _child table<string, unknown> the active card controller
---@field _tab string the active card identity
---@field _focus string the strip focus identity
---@field _entered boolean true while focus is inside the active card
---@field _transition { kind: string, fade: StandardFade }? the active open/switch fade
---@field _result { kind: "close" }? the pending close, consumed once
---@field _openEasyChat (fun(request: table<string, unknown>): table<string, unknown>)? the injected word editor child factory
---@field _easyChat table<string, unknown>? the active word editor child over the retained map card
---@field _easyPhase string? fadeout, open, or fadein behind the word editor child
---@field _easyRequest table<string, unknown>? the pending word request behind the word editor child
---@field _easyFade { from: integer, to: integer, steps: integer, t: integer }? the local handoff fade
---@field _ticks integer source ticks since open; drives the colon sequence only
---@field _pendingChild table<string, unknown>[] the child batch behind the current tick
---@field _disposed boolean
local PokegearScreenState = {}
PokegearScreenState.__index = PokegearScreenState

local KNOWN_TABS = {
  configure = true,
  radio = true,
  map = true,
  phone = true,
}

-- Keyboard walk order over source-available slots; the walk index is never
-- the semantic card identity.
local WALK_ORDER = { "configure", "radio", "map", "phone" }

-- Entering or switching cards answers with the application-change tone:
-- the source plays GEARAPPLICHANGE on every A-press and strip tap that
-- selects a card, including reselecting the current one, and GEARCANCEL
-- only for the cancel cell. Walking strip focus answers with the cursor
-- tone, exactly like the source left/right keys in the app-switch zone.
local APPLY_SOUND = "SEQ_SE_GS_GEARAPPLICHANGE"
local WALK_SOUND = "SEQ_SE_GS_GEARCURSOR"
-- Leaving a card for the strip, and closing the gear from the strip,
-- both answer with the cancel tone: the source moves the cursor into the
-- app-switch zone with GEARCANCEL, and every B-press, cancel tap, and
-- cancel-cell selection that dismisses the application plays it before
-- the close latches. This also covers B in the phone list and the gear
-- map, which the shell owns.
local CANCEL_SOUND = "SEQ_SE_GS_GEARCANCEL"

---@param child unknown
---@param tab string
local function assertChild(child, tab)
  assert(type(child) == "table", "the " .. tab .. " card factory must return a controller")
  assert(type(child) == "table", "card validation reads the " .. tab .. " controller")
  local record = child --[[@as table<string, unknown>]]
  for _, method in ipairs({ "updateFixed", "status", "takeResult", "dispose" }) do
    assert(type(record[method]) == "function", "the " .. tab .. " card controller needs " .. method)
  end
end

---@param state table<string, unknown>
---@param tab string
---@return boolean available
local function isAvailable(state, tab)
  if tab == "configure" or tab == "phone" then
    return true
  end
  if tab ~= "map" and tab ~= "radio" then
    return false
  end
  local bucket = state:capture()
  assert(type(bucket) == "table", "card availability reads the companion bucket")
  local cards = (bucket --[[@as table<string, unknown>]]).registeredCards
  return type(cards) == "table" and (cards --[[@as table<string, boolean>]])[tab] == true
end

---@class PokegearScreenState.Options
---@field state table<string, unknown> the durable companion owner
---@field assets table<string, unknown> the borrowed compiled asset family
---@field clock table<string, unknown> the injected civil-time boundary
---@field children table<string, fun(context: table<string, unknown>): table<string, unknown>> the closed card-factory set
---@field presentation table<string, fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>> the interface set
---@field effect fun(sequence: string)? source UI sound effect boundary
---@field entry { kind: string } browse opens the remembered card, call forces phone
---@field measureDisplay fun(): DisplayMeasurement the current display facts
---@field signal boolean? the outgoing-call reception flag
---@field openEasyChat (fun(request: table<string, unknown>): table<string, unknown>)? the word editor child factory

---@param opts PokegearScreenState.Options
---@return PokegearScreenState
function PokegearScreenState.new(opts)
  assert(type(opts) == "table", "the gear shell requires its options")
  assert(
    type(opts.state) == "table"
      and type(opts.state.readPreferences) == "function"
      and type(opts.state.setPreference) == "function"
      and type(opts.state.capture) == "function",
    "the gear shell requires the durable companion owner"
  )
  assert(type(opts.assets) == "table", "the gear shell requires its compiled asset family")
  assert(type(opts.clock) == "table" and type(opts.clock.nowLocal) == "function", "the gear shell requires its clock")
  assert(type(opts.children) == "table", "the gear shell requires its closed card set")
  for _, tab in ipairs({ "configure", "radio", "map", "phone" }) do
    assert(type(opts.children[tab]) == "function", "the gear shell requires the " .. tab .. " card factory")
  end
  assert(type(opts.presentation) == "table", "the gear shell requires its interface set")
  assert(opts.effect == nil or type(opts.effect) == "function", "the gear shell sound boundary must be a function")
  assert(
    type(opts.entry) == "table" and (opts.entry.kind == "browse" or opts.entry.kind == "call"),
    "the gear shell entry is browse or call"
  )
  assert(type(opts.measureDisplay) == "function", "the gear shell requires the display facts")
  assert(opts.signal == nil or type(opts.signal) == "boolean", "the gear shell reception flag must be a boolean")
  assert(
    opts.openEasyChat == nil or type(opts.openEasyChat) == "function",
    "the gear shell word editor factory must be a function"
  )
  -- The source opens with the cursor in the app switch zone
  -- (cursorInAppSwitchZone = 1): a browse open focuses the strip while
  -- the remembered card waits underneath, and only a scripted call
  -- launch starts inside the card. Selecting the focused cell enters
  -- the card; backing out of a card returns to the strip.
  local entered = opts.entry.kind == "call"
  local self = setmetatable({
    _state = opts.state,
    _assets = opts.assets,
    _clock = opts.clock,
    _children = opts.children,
    _effect = opts.effect,
    _measureDisplay = opts.measureDisplay,
    _signal = opts.signal == true,
    _tab = "phone",
    _focus = "phone",
    _entered = entered,
    _transition = nil,
    _result = nil,
    _closed = false,
    _ticks = 0,
    _pendingChild = {},
    _openEasyChat = opts.openEasyChat,
    _easyChat = nil,
    _easyPhase = nil,
    _easyRequest = nil,
    _easyFade = nil,
    _disposed = false,
    uiInput = nil,
  }, PokegearScreenState)
  local preferences = self._state:readPreferences()
  assert(type(preferences) == "table", "the gear shell reads its saved preferences")
  local wanted = "phone"
  if opts.entry.kind == "browse" and type(preferences.lastApp) == "string" and KNOWN_TABS[preferences.lastApp] then
    wanted = preferences.lastApp
  end
  if not isAvailable(self._state, wanted) then
    wanted = "configure"
  end
  local child
  local session
  local built, buildErr = pcall(function()
    child = self:_buildChild(wanted)
    session = ApplicationPresentation.new(opts.presentation)
  end)
  if not built then
    if session ~= nil then
      session:dispose()
    end
    if child ~= nil then
      (child --[[@as table<string, unknown>]]).dispose()
    end
    error(buildErr, 0)
  end
  self._child = assert(child, "the gear shell requires its opening card")
  self._session = assert(session, "the gear shell requires its presentation session")
  self._tab = wanted
  self._focus = wanted
  local resolveOk, resolveErr = pcall(function()
    self._session:resolve(self:_measured(), self:_resolveView())
  end)
  if not resolveOk then
    self._child:dispose()
    self._session:dispose()
    error(resolveErr, 0)
  end
  self._transition = { kind = "open", fade = StandardFade.new({ direction = "out" }) }
  return self
end

---@param tab string
---@return table<string, unknown> a usable card controller, or an error
function PokegearScreenState:_buildChild(tab)
  local factory = assert(self._children[tab], "the gear shell holds the " .. tab .. " card factory")
  local context = {
    state = self._state,
    assets = self._assets,
    clock = self._clock,
    effect = self._effect,
    tab = tab,
    switched = self._child ~= nil and self._tab ~= tab,
  }
  local child = factory(context)
  assertChild(child, tab)
  return child --[[@as table<string, unknown>]]
end

---@return DisplayMeasurement
function PokegearScreenState:_measured()
  local measurement = self._measureDisplay()
  return assert(measurement, "the gear shell requires current display facts")
end

---@return table<string, unknown> the snapshot resolvers and mappers read
function PokegearScreenState:_resolveView()
  local preferences = self._state:readPreferences()
  assert(type(preferences) == "table", "the gear shell reads its saved preferences")
  local childStatus = self._child:status()
  assert(type(childStatus) == "table", "the gear shell reads its active card status")
  local status = childStatus --[[@as table<string, unknown>]]
  return {
    tab = self._tab,
    focus = self._focus,
    entered = self._entered,
    dismissible = status.dismissible ~= false and status.busy ~= true,
    nestedCancel = status.nestedCancel == true,
    skin = preferences.skin,
    assets = self._assets,
    -- The fixed source tick behind every focus indicator: the shell owns
    -- the clock, so strip corners, card cursors, and scroll arrows blink
    -- in step instead of sticking on their opening frame.
    ticks = self._ticks,
  }
end

---@param sequence string
function PokegearScreenState:_playSound(sequence)
  if self._effect ~= nil then
    self._effect(sequence)
  end
end

---@param kind string
function PokegearScreenState:_beginTransition(kind)
  self._transition = { kind = kind, fade = StandardFade.new({ direction = "out" }) }
end

-- Acquires the next card before replacing the published owner: a factory or
-- shape failure cancels the initiating press and propagates with the
-- previous owner, its transition, and its pending result untouched.
---@param tab string
function PokegearScreenState:_switch(tab)
  local ok, child = pcall(function()
    return self:_buildChild(tab)
  end)
  if not ok then
    self._session:cancelPointers()
    error(child, 0)
  end
  assert(child ~= nil, "the gear shell acquires its next card before replacing its owner")
  local old = self._child
  self._child = child
  self._tab = tab
  self._focus = tab
  self._entered = true
  old:dispose()
  self:_beginTransition("switch")
  self:_playSound(APPLY_SOUND)
end

-- Takes the map card's pending word request after its tick and parks the
-- parent session: captures drop, the held map touch clears, and the
-- source six-step black fade leaves the map. The shared editor answers
-- through the injected factory after the fade.
---@param self PokegearScreenState
---@return boolean claimed
function PokegearScreenState:_takeWordRequest()
  if self._easyChat ~= nil or self._easyPhase ~= nil then
    return false
  end
  local child = self._child
  if type(child) ~= "table" or type(child.takeWordRequest) ~= "function" then
    return false
  end
  local request = child:takeWordRequest()
  if request == nil then
    return false
  end
  assert(type(request) == "table", "word requests carry their typed record")
  self._session:cancelPointers()
  if type(child.cancelPointerCapture) == "function" then
    child:cancelPointerCapture()
  end
  if type(child.cancelWordCapture) == "function" then
    child:cancelWordCapture()
  end
  local wordId = 0xFFFF
  if request.oldWord ~= nil and request.oldWord ~= false then
    local parsed = tonumber(request.oldWord)
    assert(parsed ~= nil, "word requests carry decimal identities")
    wordId = parsed
  end
  self._easyRequest = request
  self._easyPhase = "fadeout"
  self._easyFade = { from = 0, to = 16, steps = 6, t = 0 }
  self._pendingEditorRequest = {
    mode = 0,
    words = { wordId, 0xFFFF },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = request.inputMode == "touch" and "touch" or "buttons",
  }
  return true
end

-- Opens the shared editor child once the map has faded out. A factory
-- or preparation failure unblocks the pending map edit and propagates
-- the original cause with no fabricated user cancellation.
---@param self PokegearScreenState
function PokegearScreenState:_openWordEditor()
  local factory = assert(self._openEasyChat, "word edits open through the injected editor factory")
  local editorRequest = assert(self._pendingEditorRequest, "word edits open through their editor request")
  local ok, child = pcall(factory, editorRequest)
  if not ok then
    self:_failWordEdit(child)
  end
  assert(type(child) == "table", "the editor factory returns its screen")
  for _, method in ipairs({ "updateFixed", "status", "takeResult", "dispose" }) do
    assert(type(child[method]) == "function", "the editor screen needs " .. method)
  end
  self._easyChat = child --[[@as table<string, unknown>]]
  self._easyPhase = "open"
  self.uiInput = child.uiInput
  -- Step the child once on open so a ready stub lease commits before the
  -- next status read; a pending real lease simply stays preparing.
  child:updateFixed({})
end

-- Releases a failed editor open or step: disposes any partial child,
-- marks the pending map operation cancelled to unblock it without
-- touching the marking, restores shell ownership, and propagates the
-- original cause. A settlement failure accompanies but never replaces
-- the original cause.
---@param self PokegearScreenState
---@param cause unknown
function PokegearScreenState:_failWordEdit(cause)
  local request = self._easyRequest
  local child = self._easyChat
  self._easyChat = nil
  self._easyRequest = nil
  self._pendingEditorRequest = nil
  self._easyPhase = nil
  self._easyFade = nil
  self.uiInput = nil
  if child ~= nil then
    child:dispose()
  end
  if request ~= nil then
    local map = self._child
    if type(map) == "table" and type(map.acceptWordResult) == "function" then
      pcall(map.acceptWordResult, map, {
        operationId = request.operationId,
        result = { cancelled = true, inputMode = request.inputMode == "touch" and "touch" or "buttons" },
      })
    end
  end
  error(cause, 0)
end

-- Settles the exited editor child once: converts the accepted word to
-- its decimal identity, applies the detached terminal result through the
-- single map settlement path, then disposes the child and fades the
-- retained map back before ordinary map input resumes.
---@param self PokegearScreenState
---@param result table<string, unknown> detached terminal editor result
function PokegearScreenState:_settleWordEditor(result)
  local request = assert(self._easyRequest, "word edits settle their pending request")
  local child = assert(self._easyChat, "word edits settle their active child")
  local settled = nil
  local ok, failure = pcall(function()
    local payload
    if result.cancelled == true then
      payload = { cancelled = true, inputMode = result.inputMode }
    else
      local words = assert(result.words, "accepted word edits carry their words")
      payload = {
        cancelled = false,
        word = tostring(assert(words[1], "accepted edits carry word one")),
        inputMode = result.inputMode,
      }
    end
    local map = self._child
    assert(type(map) == "table" and type(map.acceptWordResult) == "function", "the map card settles word edits")
    map:acceptWordResult({ operationId = request.operationId, result = payload })
    settled = true
  end)
  child:dispose()
  self._easyChat = nil
  self._easyRequest = nil
  self._pendingEditorRequest = nil
  self._easyPhase = "fadein"
  self._easyFade = { from = 16, to = 0, steps = 6, t = 0 }
  self.uiInput = nil
  if not ok then
    error(failure, 0)
  end
  assert(settled, "word edits settle through the map card")
end

-- Records the single close: remembers the actual last card, including after
-- a scripted phone launch. The close latches terminally: further close edges
-- are ignored until disposal, and the result is consumed exactly once.
function PokegearScreenState:_close()
  if self._closed then
    return
  end
  self._closed = true
  self._state:setPreference("lastApp", self._tab)
  self:_playSound(CANCEL_SOUND)
  self._result = { kind = "close" }
end

---@return string[] the source-available cards in walk order
function PokegearScreenState:_walkOrder()
  local order = {}
  for _, tab in ipairs(WALK_ORDER) do
    if isAvailable(self._state, tab) then
      order[#order + 1] = tab
    end
  end
  return order
end

---@param direction string
function PokegearScreenState:_walkFocus(direction)
  local order = self:_walkOrder()
  if #order == 0 then
    return
  end
  local index = 1
  for position, tab in ipairs(order) do
    if tab == self._focus then
      index = position
      break
    end
  end
  if direction == "left" then
    index = (index - 2) % #order + 1
  else
    index = index % #order + 1
  end
  self._focus = order[index]
  self:_playSound(WALK_SOUND)
end

---@param event table<string, unknown>
function PokegearScreenState:_forwardToChild(event)
  self._pendingChild[#self._pendingChild + 1] = event
end

---@param mapped table<string, unknown>[]
---@param view table<string, unknown>
function PokegearScreenState:_handle(mapped, view)
  for _, event in ipairs(mapped) do
    if type(event) == "table" and type(event.type) == "string" then
      local eventType = event.type
      if eventType == "select_tab" then
        local tab = event.tab
        if type(tab) == "string" and KNOWN_TABS[tab] and tab ~= self._tab and isAvailable(self._state, tab) then
          self:_switch(tab)
        end
      elseif eventType == "dismiss" then
        if view.dismissible == true then
          self:_close()
        end
      elseif eventType == "navigate" then
        if self._entered then
          self:_forwardToChild(event)
        elseif event.direction == "left" or event.direction == "right" then
          self:_walkFocus(event.direction)
        end
      elseif eventType == "confirm" then
        if self._entered then
          -- In-card confirms belong to the card alone: the source
          -- app-switch handler never runs inside a card, so the shell
          -- forwards without answering and the card voices the press.
          self:_forwardToChild(event)
        elseif self._focus == self._tab then
          -- Confirming the focused current cell re-enters the card
          -- without acting on it: focus transitions consume their
          -- event, so returning from the strip never opens a menu or
          -- starts a call as a side effect. Boundary navigation and the
          -- cancel unfocus both land here.
          self._entered = true
          self:_playSound(APPLY_SOUND)
        else
          self:_switch(self._focus)
        end
      elseif eventType == "cancel" then
        local nested = view.nestedCancel == true
        if nested then
          self:_forwardToChild(event)
        elseif self._entered then
          self._entered = false
          self._focus = self._tab
          self:_playSound(CANCEL_SOUND)
        else
          self:_close()
        end
      elseif eventType == "menu" then
        -- The X button: cards that bind it (the region map's zoom) get it
        -- while focus is inside the card.
        if self._entered then
          self:_forwardToChild(event)
        end
      elseif eventType == "pointer_cancel" then
        -- A cancelled capture owns nothing: the stale release never fires.
      elseif
        eventType == "pointer_down"
        or eventType == "pointer_move"
        or eventType == "pointer_up"
        or eventType == "pointer_scroll"
      then
        if self._entered then
          self:_forwardToChild(event)
        end
      end
    end
  end
end

-- One fixed tick: resolve, map once, advance shell selection and the active
-- card once, advance the presentation timeline, then resolve again for the
-- resulting snapshot. Status reads and draws never tick clocks, animations,
-- or draw streams. A word editor child over the retained map card owns the
-- raw batch exclusively while it is open or fading: the parked map takes
-- no input and renders underneath nothing until the child exits.
---@param uiInput table[]
function PokegearScreenState:updateFixed(uiInput)
  assert(not self._disposed, "a disposed gear shell steps nothing")
  assert(type(uiInput) == "table", "the gear shell input must be an event list")
  if self._easyPhase == "fadeout" then
    local fade = assert(self._easyFade, "the word editor handoff carries its fade")
    fade.t = fade.t + 1
    self._ticks = self._ticks + 1
    if fade.t >= fade.steps then
      self:_openWordEditor()
    end
    local measurement = self:_measured()
    self._session:resolve(measurement, self:_resolveView())
    return
  end
  if self._easyPhase == "open" then
    local child = assert(self._easyChat, "word edits step their active child")
    child:updateFixed(uiInput)
    local result = child:takeResult()
    if result ~= nil then
      self:_settleWordEditor(result)
    end
    self._ticks = self._ticks + 1
    local measurement = self:_measured()
    self._session:resolve(measurement, self:_resolveView())
    return
  end
  if self._easyPhase == "fadein" then
    -- The retained map is already back: it steps and answers input
    -- while the return fade plays purely visually underneath.
    local measurement = self:_measured()
    local view = self:_resolveView()
    self._session:resolve(measurement, view)
    local mapped = self._session:mapInput(uiInput, view)
    self._pendingChild = {}
    self:_handle(mapped, view)
    self._child:updateFixed(self._pendingChild)
    self._pendingChild = {}
    self._ticks = self._ticks + 1
    local fade = assert(self._easyFade, "the word editor return carries its fade")
    fade.t = fade.t + 1
    if fade.t >= fade.steps then
      self._easyPhase = nil
      self._easyFade = nil
    end
    if self._transition ~= nil then
      local transition = self._transition.fade
      transition:updateSourceFrame()
      if transition.completed then
        self._transition = nil
      end
    end
    self:_takeWordRequest()
    self._session:resolve(measurement, self:_resolveView())
    return
  end
  local measurement = self:_measured()
  local view = self:_resolveView()
  self._session:resolve(measurement, view)
  local mapped = self._session:mapInput(uiInput, view)
  self._pendingChild = {}
  self:_handle(mapped, view)
  self._child:updateFixed(self._pendingChild)
  self._pendingChild = {}
  self._ticks = self._ticks + 1
  if self._transition ~= nil then
    local fade = self._transition.fade
    fade:updateSourceFrame()
    if fade.completed then
      self._transition = nil
    end
  end
  self:_takeWordRequest()
  self._session:resolve(measurement, self:_resolveView())
end

-- The presentation snapshot: card and focus identities, the civil clock
-- strip with its native colon phase, the active transition coefficients,
-- the child view, and the published plan. Fresh tables per call; status
-- performs no mutation.
---@return table<string, unknown>
function PokegearScreenState:status()
  local childStatus = self._child:status()
  assert(type(childStatus) == "table", "the gear shell reads its active card status")
  local childView = childStatus --[[@as table<string, unknown>]]
  local preferences = self._state:readPreferences()
  assert(type(preferences) == "table", "the gear shell reads its saved preferences")
  local prefs = preferences --[[@as table<string, unknown>]]
  local now = self._clock:nowLocal()
  local transition = nil
  if self._transition ~= nil then
    transition = {
      kind = self._transition.kind,
      coefficient = self._transition.fade.coefficient,
      completed = self._transition.fade.completed,
    }
  end
  local easy = nil
  if self._easyChat ~= nil then
    easy = self._easyChat:status()
    assert(type(easy) == "table", "the gear shell reads its word editor status")
  end
  local easyActive = easy ~= nil or self._easyPhase ~= nil
  return {
    open = not self._closed and not self._disposed,
    easyChat = easy,
    tab = self._tab,
    focus = self._focus,
    entered = self._entered,
    skin = prefs.skin,
    unlockedSkins = prefs.unlockedSkins,
    cards = { radio = isAvailable(self._state, "radio"), map = isAvailable(self._state, "map") },
    ticks = self._ticks,
    clock = {
      hour = now.hour,
      minute = now.minute,
      weekday = PokegearCalendar.weekday(now),
      signal = self._signal,
      colon = math.floor(self._ticks / 30) % 2,
    },
    transition = transition,
    child = childView,
    busy = childView.busy == true or easyActive,
    dismissible = childView.dismissible ~= false and childView.busy ~= true and not easyActive,
    presentation = self._session:plan(),
  }
end

-- The host result contract: the shell only ever closes, reported exactly
-- once. Disposal discards a pending close.
---@return { kind: "close" }?
function PokegearScreenState:takeResult()
  local result = self._result
  self._result = nil
  return result
end

-- Drops the session capture so a stale release never activates after focus
-- loss or an input-mode change.
function PokegearScreenState:cancelPointerCapture()
  self._session:cancelPointers()
  if self._easyChat ~= nil then
    self._easyChat:cancelPointerCapture()
  end
end

-- Idempotent release of the logical lifetime: the session and the active
-- card release exactly once, a pending result is discarded and no close is
-- reported after disposal.
function PokegearScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._session:dispose()
  self._child:dispose()
  if self._easyChat ~= nil then
    self._easyChat:dispose()
    self._easyChat = nil
  end
  self._easyPhase = nil
  self._easyFade = nil
  self._easyRequest = nil
  self._result = nil
end

return PokegearScreenState
