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

local SWITCH_SOUND = "pokegear.switch"
local RESELECT_SOUND = "pokegear.reselect"

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
    _entered = true,
    _transition = nil,
    _result = nil,
    _closed = false,
    _ticks = 0,
    _pendingChild = {},
    _disposed = false,
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
  self:_playSound(SWITCH_SOUND)
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
          self:_forwardToChild(event)
          self:_playSound(RESELECT_SOUND)
        elseif self._focus == self._tab then
          self:_forwardToChild(event)
          self:_playSound(RESELECT_SOUND)
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
        else
          self:_close()
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
-- or draw streams.
---@param uiInput table[]
function PokegearScreenState:updateFixed(uiInput)
  assert(not self._disposed, "a disposed gear shell steps nothing")
  assert(type(uiInput) == "table", "the gear shell input must be an event list")
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
  return {
    open = not self._closed and not self._disposed,
    tab = self._tab,
    focus = self._focus,
    entered = self._entered,
    skin = prefs.skin,
    unlockedSkins = prefs.unlockedSkins,
    clock = {
      hour = now.hour,
      minute = now.minute,
      weekday = PokegearCalendar.weekday(now),
      signal = self._signal,
      colon = math.floor(self._ticks / 30) % 2,
    },
    transition = transition,
    child = childView,
    busy = childView.busy == true,
    dismissible = childView.dismissible ~= false and childView.busy ~= true,
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
  self._result = nil
end

return PokegearScreenState
