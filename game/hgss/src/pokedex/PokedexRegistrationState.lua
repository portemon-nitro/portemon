-- Battle-owned first-catch registration presentation: one complete
-- announcement and card sequence for a single frozen capture. The state
-- borrows its presentation owner, battle timeline, and audio adapter; it
-- owns exactly one resource lease and one application session. It never
-- inspects live knowledge, mutates mechanics, or publishes captures: the
-- existing committer stays the only publisher. Draw, status, and input
-- mapping stay read-only with respect to clocks and audio; only fixed
-- updates advance the private thirty-hertz source clock.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local PokedexInterface = require("game.hgss.src.pokedex.PokedexInterface")

---@class PokedexRegistrationState
---@field _registration table<string, unknown> detached frozen first-catch facts
---@field _pokedex table<string, unknown> borrowed presentation resource owner
---@field _timeline table<string, unknown> borrowed battle timeline behind the announcement
---@field _audio table<string, unknown> borrowed registration audio adapter
---@field _measureDisplay fun(): table<string, unknown> live display facts
---@field _session table<string, unknown> owned presentation session
---@field _lease table<string, unknown>? acquired per-open preparation lease
---@field _bundle table<string, unknown>? last committed whole ready bundle
---@field _announced boolean true once the source announcement is enqueued
---@field _accumulator number accepted source seconds banked toward the next step
---@field _phase string active source phase
---@field _palette table<string, unknown> palette fade recurrence state
---@field _picture table<string, unknown> picture fade recurrence state
---@field _pictureX integer current captured-picture horizontal policy
---@field _banner integer current banner fade policy
---@field _bannerTimer integer source updates spent on the ready card
---@field _dismissible boolean true once the cry releases fresh dismissal
---@field _dismissRequested boolean latched fresh dismissal edge
---@field _spritesHidden boolean true once departure hides the popup sprites
---@field _departKind string ordinary or contest departure behavior
---@field _complete boolean true once the exit view freezes
---@field _error string? attributed failure cause
---@field _disposed boolean
local PokedexRegistrationState = {}
PokedexRegistrationState.__index = PokedexRegistrationState

-- The source post-text wait is thirty main-task updates at thirty hertz;
-- the borrowed battle timeline counts sixty internal ticks per second.
local SOURCE_STEP = 1 / 30
local ANNOUNCE_HOLD_TICKS = 60
local FADE_MAX = 16
local FADE_STEP = 2
local BANNER_HOLD = 7
local BANNER_TIMER_FIRST = 16
local BANNER_TIMER_DEPART = 32
local CARD_PICTURE_X = 48
local DEPART_PICTURE_END = 128
local DEPART_PICTURE_STEP = 4
local CRY_PATTERN = 14
local CRY_FORM = 0

---@param value unknown
---@return unknown detached copy without shared mutable state
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

---@param registration unknown frozen first-catch facts under validation
---@return table<string, unknown> detached validated registration
local function checkRegistration(registration)
  assert(type(registration) == "table", "the registration child freezes its terminal facts")
  local record = registration --[[@as table<string, unknown>]]
  assert(
    type(record.captureId) == "number" and record.captureId % 1 == 0,
    "the registration freezes its stable capture identity"
  )
  assert(type(record.mode) == "string" and record.mode ~= "", "the registration freezes the actual capture mode")
  assert(
    record.dexMode == "johto" or record.dexMode == "national",
    "the registration freezes its eligibility number mode"
  )
  assert(
    type(record.displayName) == "string" and record.displayName ~= "",
    "the registration freezes its announcement name"
  )
  assert(type(record.specimen) == "table", "the registration freezes the actual captured specimen")
  return copyValue(record)
end

---@param pokedex unknown borrowed presentation resource owner under validation
local function checkPokedex(pokedex)
  assert(type(pokedex) == "table", "the registration child borrows its presentation owner")
  assert(type(pokedex.acquire) == "function", "the borrowed owner acquires registration leases")
end

---@param audio unknown borrowed registration audio adapter under validation
local function checkAudio(audio)
  assert(type(audio) == "table", "the registration child borrows its audio adapter")
  assert(type(audio.playCry) == "function", "the audio adapter plays the card cry")
  assert(type(audio.isCryFinished) == "function", "the audio adapter reports cry completion")
  assert(type(audio.select) == "function", "the audio adapter keeps its select role")
end

---@param registration table<string, unknown> detached frozen first-catch facts
---@return table<string, unknown> immutable whole registration demand
local function buildDemand(registration)
  local specimen = registration.specimen --[[@as table<string, unknown>]]
  return {
    key = "registration-" .. tostring(registration.captureId),
    purpose = "registration",
    pageRole = "registration",
    dexMode = registration.dexMode,
    language = "native",
    iconKeys = {},
    pictures = {
      {
        slot = "registration",
        specimen = specimen,
        facing = "front",
        mode = "registration",
      },
    },
    text = { registration = registration },
    cry = { species = specimen.species, form = CRY_FORM },
  }
end

---@param from integer fade start coefficient
---@param to integer fade end coefficient
---@param stepped boolean true for the alternating palette recurrence, false for the per-update picture recurrence
---@return table<string, unknown> initialized fade recurrence state
local function fadeInit(from, to, stepped)
  return {
    active = from ~= to,
    from = from,
    to = to,
    current = from,
    shown = from,
    next = from,
    wait = false,
    stepped = stepped,
  }
end

---@param fade table<string, unknown> palette recurrence state under advancement
---@return integer published coefficient
local function fadeStepPalette(fade)
  if fade.active ~= true then
    return fade.current --[[@as integer]]
  end
  if fade.wait == true then
    fade.wait = false
    return fade.current --[[@as integer]]
  end
  local direction = 1
  if
    fade.to --[[@as integer]]
    < fade.current --[[@as integer]]
  then
    direction = -1
  end
  local following = fade.current --[[@as integer]] + direction * FADE_STEP
  if
    (
      direction == 1 and following >= fade.to --[[@as integer]]
    ) or (
      direction == -1 and following <= fade.to --[[@as integer]]
    )
  then
    following = fade.to --[[@as integer]]
  end
  fade.next = following
  fade.current = following
  fade.shown = following
  fade.wait = true
  if following == fade.to then
    fade.active = false
  end
  return following
end

---@param fade table<string, unknown> picture recurrence state under advancement
---@return integer published coefficient
local function fadeStepPicture(fade)
  if fade.active ~= true then
    return fade.current --[[@as integer]]
  end
  local direction = 1
  if
    fade.to --[[@as integer]]
    < fade.current --[[@as integer]]
  then
    direction = -1
  end
  -- The source publishes the current coefficient on each update, steps
  -- by one, and clears active only once the end coefficient publishes.
  -- The published value stays observable through shown while current
  -- already carries the next step.
  local published = fade.current --[[@as integer]]
  fade.shown = published
  if published == fade.to then
    fade.active = false
    return published
  end
  fade.current = published + direction
  return published
end

---@class PokedexRegistrationState.Options
---@field registration table<string, unknown> detached frozen first-catch facts
---@field pokedex table<string, unknown> borrowed presentation resource owner
---@field timeline table<string, unknown> borrowed battle timeline behind the announcement
---@field audio table<string, unknown> borrowed registration audio adapter
---@field measureDisplay fun(): table<string, unknown> live display facts

---@param opts PokedexRegistrationState.Options construction record behind the card
---@return PokedexRegistrationState
function PokedexRegistrationState.new(opts)
  assert(type(opts) == "table", "the registration child requires its construction record")
  local registration = checkRegistration(opts.registration)
  checkPokedex(opts.pokedex)
  assert(type(opts.timeline) == "table", "the registration child borrows its battle timeline")
  assert(type(opts.timeline.announce) == "function", "the borrowed timeline announces the card text")
  assert(type(opts.timeline.settled) == "function", "the borrowed timeline reports its announcement")
  checkAudio(opts.audio)
  assert(type(opts.measureDisplay) == "function", "the registration child measures its display")
  local self = setmetatable({
    _registration = registration,
    _pokedex = opts.pokedex,
    _timeline = opts.timeline,
    _audio = opts.audio,
    _measureDisplay = opts.measureDisplay,
    _session = ApplicationPresentation.new(PokedexInterface.registration()),
    _lease = nil,
    _bundle = nil,
    _announced = false,
    _accumulator = 0,
    _phase = "preparing",
    _palette = fadeInit(0, 0, true),
    _picture = fadeInit(0, 0, false),
    _pictureX = CARD_PICTURE_X,
    _banner = 0,
    _bannerTimer = 0,
    _dismissible = false,
    _dismissRequested = false,
    _spritesHidden = false,
    _departKind = "ordinary",
    _complete = false,
    _error = nil,
    _disposed = false,
  }, PokedexRegistrationState)
  local okLease, lease = pcall(opts.pokedex.acquire, opts.pokedex, { purpose = "registration" })
  if not okLease or type(lease) ~= "table" then
    self._phase = "preparing"
    self._error = "the registration card failed to acquire its lease: " .. tostring(lease)
    return self
  end
  self._lease = lease
  return self
end

---@param self PokedexRegistrationState
---@return table<string, unknown> detached card policy for plans and drawing
function PokedexRegistrationState:_cardView()
  return {
    phase = self._phase,
    paletteFade = self._palette.shown,
    pictureFade = self._picture.shown,
    pictureX = self._pictureX,
    banner = self._banner,
    spritesHidden = self._spritesHidden,
    dismissible = self._dismissible,
  }
end

-- Resolves the current plan against fresh display facts without advancing
-- gameplay. A failed resolution keeps the previous plan; draw and input
-- mapping tolerate its absence until the first resolution succeeds.
---@param self PokedexRegistrationState
local function resolvePlan(self)
  local okMeasurement, measurement = pcall(self._measureDisplay)
  if not okMeasurement or type(measurement) ~= "table" then
    return
  end
  pcall(self._session.resolve, self._session, measurement, self:_cardView())
end

---@param self PokedexRegistrationState
local function startDeparture(self)
  self._dismissRequested = false
  local kind = "ordinary"
  if self._registration.mode == "contest" then
    kind = "contest"
  end
  self._departKind = kind
  self._phase = "departure"
  if kind == "contest" then
    self._palette = fadeInit(0, FADE_MAX, true)
    self._picture = fadeInit(0, FADE_MAX, false)
  else
    self._palette = fadeInit(0, FADE_MAX, true)
  end
end

---@param self PokedexRegistrationState
local function completeCard(self)
  if self._departKind == "contest" then
    self._palette = fadeInit(FADE_MAX, FADE_MAX, true)
    self._picture = fadeInit(FADE_MAX, FADE_MAX, false)
  else
    -- The frozen final exit keeps the centered captured picture under the
    -- terminal cover: the departure slides away, the completed card stays.
    self._palette = fadeInit(FADE_MAX, FADE_MAX, true)
    self._picture = fadeInit(0, 0, false)
    self._pictureX = CARD_PICTURE_X
    self._spritesHidden = false
    self._banner = 0
  end
  self._dismissible = false
  self._dismissRequested = false
  self._complete = true
  self._phase = "complete"
end

---@param self PokedexRegistrationState
local function stepSource(self)
  if self._phase == "announcement" then
    local okSettled, settled = pcall(self._timeline.settled, self._timeline)
    if okSettled and settled == true then
      self._palette = fadeInit(0, FADE_MAX, true)
      self._picture = fadeInit(0, FADE_MAX, false)
      self._phase = "entryFade"
    end
    return
  end
  if self._phase == "entryFade" then
    fadeStepPalette(self._palette)
    fadeStepPicture(self._picture)
    if self._palette.active ~= true and self._picture.active ~= true then
      self._pictureX = CARD_PICTURE_X
      self._spritesHidden = false
      self._palette = fadeInit(FADE_MAX, 0, true)
      self._picture = fadeInit(FADE_MAX, 0, false)
      self._phase = "waitCardFade"
    end
    return
  end
  if self._phase == "waitCardFade" then
    fadeStepPalette(self._palette)
    fadeStepPicture(self._picture)
    if self._palette.active ~= true and self._picture.active ~= true then
      self._phase = "preCry"
    end
    return
  end
  if self._phase == "preCry" then
    self._phase = "playCry"
    return
  end
  if self._phase == "playCry" then
    local audio = self._audio --[[@as table<string, unknown>]]
    local play = audio.playCry --[[@as fun(species: string, pattern: integer, form: integer): boolean]]
    local specimen = self._registration.specimen --[[@as table<string, unknown>]]
    local okPlay, playErr = pcall(play, specimen.species, CRY_PATTERN, CRY_FORM)
    if not okPlay then
      self._error = "the registration cry failed: " .. tostring(playErr)
      return
    end
    self._bannerTimer = 0
    self._banner = 0
    self._phase = "readyCard"
    return
  end
  if self._phase == "readyCard" then
    -- The banner belongs to the ready card after the cry releases it:
    -- no palette animation advances while the cry is unfinished.
    local audio = self._audio --[[@as table<string, unknown>]]
    local finished = audio.isCryFinished --[[@as fun(): boolean]]
    local okCry, cryDone = pcall(finished)
    if not okCry then
      self._error = "the registration cry failed: " .. tostring(cryDone)
      return
    end
    if cryDone == true then
      self._dismissible = true
    end
    if self._dismissible then
      self._bannerTimer = self._bannerTimer + 1
      if self._bannerTimer == BANNER_TIMER_FIRST then
        self._banner = BANNER_HOLD
      end
      -- The banner timer is purely palette animation: palette7 from
      -- timer16 resets to palette0 at timer32 while the card still waits
      -- for a latched fresh dismissal.
      if self._bannerTimer == BANNER_TIMER_DEPART then
        self._banner = 0
      end
    end
    if self._dismissRequested and self._dismissible then
      startDeparture(self)
      return
    end
    return
  end
  if self._phase == "departure" then
    if self._departKind == "contest" then
      fadeStepPalette(self._palette)
      fadeStepPicture(self._picture)
      if self._palette.active ~= true and self._picture.active ~= true then
        completeCard(self)
      end
      return
    end
    fadeStepPalette(self._palette)
    if self._pictureX < DEPART_PICTURE_END then
      self._pictureX = math.min(DEPART_PICTURE_END, self._pictureX + DEPART_PICTURE_STEP)
    end
    if self._pictureX >= DEPART_PICTURE_END then
      self._spritesHidden = true
    end
    if self._palette.active ~= true and self._pictureX >= DEPART_PICTURE_END then
      completeCard(self)
    end
    return
  end
end

-- Advances the card once per accepted presentation update: one whole
-- resource preparation while pending (discarding banked source time so
-- readiness never jumps), then accepted thirty-hertz quanta through the
-- source phases. Never ticks the borrowed timeline, never replays the
-- cry, never prepares a second demand generation.
---@param dt number accepted presentation seconds
function PokedexRegistrationState:updateFixed(dt)
  if self._disposed then
    return
  end
  assert(type(dt) == "number" and dt == dt and dt >= 0, "registration updates take accepted seconds")
  if self._complete or self._error ~= nil then
    return
  end
  if self._phase == "preparing" then
    self._accumulator = 0
    local lease = self._lease
    if lease == nil then
      return
    end
    local outcome = lease:prepare(buildDemand(self._registration))
    assert(type(outcome) == "table" and type(outcome.kind) == "string", "leases answer pending, ready, or failed")
    if outcome.kind == "ready" then
      self._bundle = assert(outcome.assets, "ready outcomes carry their whole bundle")
      local messages = self._bundle.messages --[[@as table<string, unknown>?]]
      local announcement = nil
      if type(messages) == "table" and type(messages.registrationAnnouncement) == "string" then
        announcement = messages.registrationAnnouncement --[[@as string]]
      end
      if type(announcement) ~= "string" or announcement == "" then
        self._error = "the registration bundle carries no announcement"
        return
      end
      local okAnnounce, announceErr =
        pcall(self._timeline.announce, self._timeline, announcement, false, ANNOUNCE_HOLD_TICKS)
      if not okAnnounce then
        self._error = "the registration announcement failed: " .. tostring(announceErr)
        return
      end
      self._announced = true
      self._phase = "announcement"
    elseif outcome.kind == "failed" then
      self._error = tostring(outcome.error)
      return
    else
      assert(outcome.kind == "pending", "leases answer pending, ready, or failed")
    end
    resolvePlan(self)
    return
  end
  self._accumulator = self._accumulator + dt
  while self._accumulator >= SOURCE_STEP - 1e-12 do
    self._accumulator = self._accumulator - SOURCE_STEP
    if self._accumulator < 0 then
      self._accumulator = 0
    end
    stepSource(self)
    if self._complete or self._error ~= nil then
      self._accumulator = 0
      break
    end
  end
  resolvePlan(self)
end

-- Maps one raw batch through the current plan, then consumes card edges:
-- fresh confirmation or touch dismisses the ready card, cancellation never
-- does, and every other edge falls away. During the announcement,
-- confirmation accelerates the borrowed reveal without skipping its timed
-- hold; an early edge never crosses into dismissal.
---@param events table<integer, table<string, unknown>> raw fixed-tick batch
function PokedexRegistrationState:input(events)
  if self._disposed or self._complete or self._error ~= nil then
    return
  end
  assert(type(events) == "table", "registration input arrives as an event list")
  local okPlan, _ = pcall(self._session.plan, self._session)
  local mapped = events
  if okPlan then
    local okMap, converted = pcall(self._session.mapInput, self._session, events, self:_cardView())
    if okMap and type(converted) == "table" then
      mapped = converted
    end
  end
  for _, event in ipairs(mapped) do
    if type(event) == "table" then
      local kind = event.type
      if kind == "confirm" or kind == "touch_new" then
        if self._phase == "readyCard" and self._dismissible then
          self._dismissRequested = true
        elseif self._phase == "announcement" and self._announced then
          pcall(self._timeline.ack, self._timeline)
        end
      end
    end
  end
end

---@return table<string, unknown> detached card policy for plans and drawing
function PokedexRegistrationState:view()
  return self:_cardView()
end

---@return { phase: string, complete: boolean, acceptsDismissal: boolean, error?: string } detached lifecycle status
function PokedexRegistrationState:status()
  local status = {
    phase = self._phase,
    complete = self._complete,
    acceptsDismissal = self._phase == "readyCard" and self._dismissible and not self._complete,
  }
  if self._error ~= nil then
    status.error = self._error
  end
  return status
end

-- Draws the published card through the prepared renderer and plan: a
-- read-only pass that never advances clocks, replays audio, or prepares
-- resources. Before the card publishes, or after disposal, it draws
-- nothing. The frozen final view stays drawable until disposal.
---@param resources table<string, unknown> draw resources carrying the host graphics
function PokedexRegistrationState:draw(resources)
  if self._disposed or self._bundle == nil then
    return
  end
  assert(type(resources) == "table" and resources.graphics ~= nil, "registration drawing needs its host graphics")
  resolvePlan(self)
  local okPlan, plan = pcall(self._session.plan, self._session)
  if not okPlan or plan == nil then
    return
  end
  local graphics = resources.graphics
  local bundle = assert(self._bundle, "registration drawing needs its ready bundle")
  local renderer = bundle.renderer
  assert(type(renderer) == "table", "ready bundles carry their shared renderer")
  ApplicationPresentation.draw(graphics, { renderer = renderer }, {
    view = self:_cardView(),
    assets = bundle,
  }, plan)
end

-- Cancels a held press through the owned session so a stale release never
-- activates after dismissal or disposal.
function PokedexRegistrationState:cancelPointerCapture()
  if self._disposed then
    return
  end
  pcall(self._session.cancelPointers, self._session)
end

-- Idempotent release of the card lifetime: the owned session and the one
-- acquired lease release exactly once. Borrowed presentation, timeline,
-- audio, and display owners stay alive.
function PokedexRegistrationState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._dismissRequested = false
  self._dismissible = false
  pcall(self._session.dispose, self._session)
  local lease = self._lease
  self._lease = nil
  self._bundle = nil
  if lease ~= nil then
    lease:release()
  end
end

return PokedexRegistrationState
