-- Incoming calls while the companion stays closed: whole-minute
-- eligibility with the opening offline jump ignored, source trigger
-- selection ahead of the random gate, exact inclusive random boundaries,
-- strict ring expiry with backward-time protection, and acceptance as the
-- single clearing boundary. One field-runtime-owned policy machine
-- borrowing the companion state, calendar, draw streams, world facts,
-- application host, and ring tone owner. The notification view is detached
-- and draws no randomness. Pure policy: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class IncomingCalls
---@field private _state table<string, unknown> the borrowed durable companion owner
---@field private _catalog table<string, unknown> the borrowed contact catalog
---@field private _calendar table<string, unknown> the borrowed civil calendar adapter
---@field private _random table<string, unknown> the borrowed companion draw streams
---@field private _world table<string, unknown> the borrowed world facts
---@field private _host table<string, unknown>? the borrowed companion application host
---@field private _audio table<string, unknown>? the borrowed ring tone owner
---@field private _cooldown integer accumulated eligible minutes
---@field private _firstAdvanceSeen boolean whether the opening offline jump passed
---@field private _ring table<string, unknown>? the active ring record
---@field private _disposed boolean
local IncomingCalls = {}
IncomingCalls.__index = IncomingCalls

IncomingCalls.CODE = "POKEGEAR_INCOMING_CALL_INVALID"

-- Whole civil minutes between evaluations before the field may ring.
IncomingCalls.COOLDOWN_MINUTES = 10
-- The ordinary random gate passes residues 0..50 inclusive of a %100 draw.
IncomingCalls.GATE_PASS_MAX = 50
-- Category splits of a %1000 draw: below 500 is category zero, below 800
-- is category one, otherwise category two.
IncomingCalls.CATEGORY_SPLIT_ZERO = 500
IncomingCalls.CATEGORY_SPLIT_ONE = 800
-- A ring expires once its lived seconds strictly exceed this bound.
-- Exactly this many seconds still ring.
IncomingCalls.RING_SECONDS = 30
-- The repeat tone counter resets every this many opportunity ticks.
IncomingCalls.REPEAT_TICKS = 30
-- The source ring tone identity attempted at counter zero and every reset.
IncomingCalls.RING_SEQUENCE = "PHONE1"
-- The shared Start Menu ringing animation selected while a call rings.
IncomingCalls.RINGING_ANIMATION = 5
-- Trigger kinds: an event trigger clears at acceptance, an ordinary call
-- records history at acceptance.
IncomingCalls.KIND_EVENT = 3
IncomingCalls.KIND_ORDINARY = 0
-- Source-eligible caller classes per drawn category.
IncomingCalls.CATEGORY_CLASSES = {
  [0] = { [0] = true, [12] = true },
  [1] = { [11] = true, [10] = true },
  [2] = { [14] = true },
}
-- Caller-name window geometry on the field information screen, in source
-- tiles: left 11, top 19, height 2, width capped at 9 tiles.
IncomingCalls.WINDOW_TILE_LEFT = 11
IncomingCalls.WINDOW_TOP = 19
IncomingCalls.WINDOW_HEIGHT = 2
IncomingCalls.WINDOW_MAX_WIDTH = 9
-- Per-glyph width estimate behind the caller window while no font owner is
-- composed: the field font fallback advance. The retained menu art carries
-- no per-name metrics, so the policy sizes the window from the name and
-- the presentation draws the sized window.
IncomingCalls.FALLBACK_ADVANCE = 4

---@param message string
---@param context table<string, unknown>?
local function fail(message, context)
  Errors.raise(IncomingCalls.CODE, message, context or {})
end

-- Ring expiry reads serial seconds through the shared civil calendar
-- owner, so serial arithmetic never drifts into a parallel copy here.
---@param moment table<string, integer>
---@return integer seconds since the serial epoch
local function epochSeconds(moment)
  return PokegearCalendar.epochSeconds(moment)
end

---@param name string
---@return integer the glyph count
local function glyphCount(name)
  local count = 0
  for _ in Utf8Glyphs.iter(name) do
    count = count + 1
  end
  return count
end

---@param opts { state: table<string, unknown>, catalog: table<string, unknown>, calendar: table<string, unknown>, random: table<string, unknown>, world: table<string, unknown>, host: table<string, unknown>?, audio: table<string, unknown>? }
---@return IncomingCalls
function IncomingCalls.new(opts)
  assert(type(opts) == "table", "incoming calls borrow their owners through a record")
  assert(
    type(opts.state) == "table"
      and type(opts.state.readPhone) == "function"
      and type(opts.state.setTrigger) == "function"
      and type(opts.state.setCallHistory) == "function",
    "incoming calls persist trigger and history facts through the companion state"
  )
  assert(
    type(opts.catalog) == "table"
      and type(opts.catalog.contacts) == "table"
      and type(opts.catalog.callTriggers) == "table",
    "incoming calls borrow the contact and trigger catalogs"
  )
  assert(
    type(opts.calendar) == "table" and type(opts.calendar.observeField) == "function",
    "incoming calls advance civil time through the companion calendar"
  )
  assert(
    type(opts.random) == "table" and type(opts.random.mt) == "function" and type(opts.random.lc) == "function",
    "incoming calls draw through the companion streams"
  )
  assert(type(opts.world) == "table", "incoming calls borrow their world facts")
  assert(
    opts.host == nil
      or (type(opts.host) == "table" and type(opts.host.open) == "function" and type(opts.host.isActive) == "function"),
    "incoming calls enter accepted calls through the companion host"
  )
  assert(
    opts.audio == nil
      or (
        type(opts.audio) == "table"
        and type(opts.audio.playRing) == "function"
        and type(opts.audio.isRingPlaying) == "function"
        and type(opts.audio.stopRing) == "function"
      ),
    "incoming calls repeat their tone through the ring tone owner"
  )
  return setmetatable({
    _state = opts.state,
    _catalog = opts.catalog,
    _calendar = opts.calendar,
    _random = opts.random,
    _world = opts.world,
    _host = opts.host,
    _audio = opts.audio,
    _cooldown = 0,
    _firstAdvanceSeen = false,
    _ring = nil,
    _disposed = false,
  }, IncomingCalls)
end

-- Asserts the runtime lifetime is still owned.
function IncomingCalls:_checkLive()
  assert(not self._disposed, "incoming calls are disposed")
end

-- Attempts the source ring tone without stacking: a sequence that is
-- already playing keeps its single instance while the counter behavior
-- still applies at the call site.
---@param self IncomingCalls
function IncomingCalls:_attemptTone()
  local audio = self._audio
  if audio == nil then
    return
  end
  local playing = audio.isRingPlaying --[[@as fun(self: table<string, unknown>): boolean]]
  if playing(audio) then
    return
  end
  local play = audio.playRing --[[@as fun(self: table<string, unknown>, sequence: string)]]
  play(audio, IncomingCalls.RING_SEQUENCE)
end

-- Starts one ring over a selected caller: records the pending payload
-- immutably and attempts the opening tone. Trigger flags, history, and
-- the cooldown accumulator are untouched until acceptance or reset.
---@param self IncomingCalls
---@param contactKey string
---@param kind integer
---@param triggerKey string?
function IncomingCalls:_startRing(contactKey, kind, triggerKey)
  self._ring = {
    contactKey = contactKey,
    kind = kind,
    triggerKey = triggerKey,
    startEpoch = nil,
    counter = 0,
  }
  self:_attemptTone()
end

---@param record unknown
---@return string contactKey, integer kind
local function checkTriggerRecord(record)
  if type(record) ~= "table" then
    fail("incoming call triggers carry key, contact, and kind", {})
  end
  assert(type(record) == "table", "trigger selection reads the trigger record")
  local entry = record --[[@as table<string, unknown>]]
  if type(entry.key) ~= "string" or entry.key == "" then
    fail("incoming call triggers carry their trigger key", {})
  end
  if type(entry.contact) ~= "string" or entry.contact == "" then
    fail("incoming call triggers carry their owning contact", { key = entry.key })
  end
  if entry.kind ~= IncomingCalls.KIND_EVENT and entry.kind ~= IncomingCalls.KIND_ORDINARY then
    fail("incoming call triggers carry a known source call kind", { key = entry.key, kind = entry.kind })
  end
  return entry.key, --[[@as string]]
    entry.kind --[[@as integer]]
end

---@param self IncomingCalls
---@param contactKey string
---@return table<string, unknown>? the borrowed catalog contact record
function IncomingCalls:_contactRecord(contactKey)
  local contacts = self._catalog.contacts --[[@as table<integer, unknown>]]
  for _, entry in ipairs(contacts) do
    if
      type(entry) == "table" and (entry --[[@as table<string, unknown>]]).key == contactKey
    then
      return entry --[[@as table<string, unknown>]]
    end
  end
  return nil
end

-- Whether the candidate shares the opportunity map: only a contact record
-- that actually declares a place can collide with it. Records without
-- placement facts never exclude.
---@param self IncomingCalls
---@param contactKey string
---@param args { mapKey: unknown?, mapId: unknown? }
---@return boolean
function IncomingCalls:_isSameMap(contactKey, args)
  local record = self:_contactRecord(contactKey)
  if record == nil then
    return false
  end
  local place = record.place
  if place == nil then
    place = record.location
  end
  if place == nil then
    place = record.map
  end
  if place == nil then
    return false
  end
  return place == args.mapKey or place == args.mapId
end

-- Whether the world confirms a live contest or takeover for a constrained
-- contact. Constraints activate only on records that declare them, and an
-- unavailable fact means no exclusion: absent world systems never
-- fabricate a silence.
---@param self IncomingCalls
---@param record table<string, unknown>
---@return boolean excluded
function IncomingCalls:_isContestExcluded(record)
  if record.contestPlace == nil and record.buenaRestricted ~= true then
    return false
  end
  local reader = self._world.read
  if type(reader) ~= "function" then
    return false
  end
  local world = self._world
  local function probe(key)
    -- Only an attributed missing-owner failure reads as no exclusion:
    -- programmer errors inside the world read propagate instead of
    -- silently admitting a caller the source would silence.
    local ok, value = pcall(reader, world, key)
    if not ok then
      if type(value) == "table" and value.code == ScriptErrors.FEATURE_UNAVAILABLE then
        return nil
      end
      error(value, 0)
    end
    return value
  end
  if record.contestPlace ~= nil then
    local contest = probe("contest.live")
    if contest == true then
      return true
    end
  end
  if record.buenaRestricted == true then
    if probe("takeover.active") == true then
      return true
    end
  end
  return false
end

-- Builds the eligible source trigger list in catalog order: set flags
-- whose contact is acquired (or declares the day-care exception) and off
-- the opportunity map. Corrupt set records fail with attribution instead
-- of selecting a plausible caller.
---@param self IncomingCalls
---@param args { mapKey: unknown?, mapId: unknown? }
---@return table<integer, { key: string, contactKey: string, kind: integer }>
function IncomingCalls:_eligibleTriggers(args)
  local readPhone = self._state.readPhone --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
  local phone = readPhone(self._state)
  assert(type(phone) == "table", "trigger selection reads the companion phone facts")
  local set = phone.triggers
  assert(type(set) == "table", "trigger selection reads the set trigger flags")
  local registered = phone.contacts
  assert(type(registered) == "table", "trigger selection reads the acquired contacts")
  local triggers = self._catalog.callTriggers --[[@as table<integer, unknown>]]
  local out = {}
  for _, record in ipairs(triggers) do
    if
      type(record) == "table" and type((record --[[@as table<string, unknown>]]).key) == "string"
    then
      local key = (record --[[@as table<string, unknown>]]).key --[[@as string]]
      if set[key] == true then
        local triggerKey, kind = checkTriggerRecord(record)
        local contact = (record --[[@as table<string, unknown>]]).contact --[[@as string]]
        if self:_contactRecord(contact) == nil then
          fail("incoming call triggers reference a catalogued contact", { key = triggerKey, contact = contact })
        end
        local daycare = (record --[[@as table<string, unknown>]]).daycare == true
        if (registered[contact] == nil and not daycare) or (self:_isSameMap(contact, args) and not daycare) then
          -- The caller is not reachable on this map through this trigger.
        else
          out[#out + 1] = { key = triggerKey, contactKey = contact, kind = kind }
        end
      end
    end
  end
  return out
end

---@param class integer
---@param category integer
---@return boolean
local function classInCategory(class, category)
  local classes = IncomingCalls.CATEGORY_CLASSES[category]
  return type(classes) == "table" and classes[class] == true
end

-- Builds the eligible random pool in catalog order: acquired contacts of
-- the drawn category, off the opportunity map, outside call history, and
-- outside live contests. History filtering stays separate so a covered
-- pool can reset before the final filter.
---@param self IncomingCalls
---@param category integer
---@param args { mapKey: unknown?, mapId: unknown? }
---@param withHistory boolean whether call-history entries exclude
---@return table<integer, string> eligible contact keys
function IncomingCalls:_eligibleCallers(category, args, withHistory)
  local readPhone = self._state.readPhone --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
  local phone = readPhone(self._state)
  assert(type(phone) == "table", "caller selection reads the companion phone facts")
  local registered = phone.contacts
  assert(type(registered) == "table", "caller selection reads the acquired contacts")
  local history = phone.history
  assert(type(history) == "table", "caller selection reads the call journal")
  local contacts = self._catalog.contacts --[[@as table<integer, unknown>]]
  local out = {}
  for _, entry in ipairs(contacts) do
    if type(entry) == "table" then
      local record = entry --[[@as table<string, unknown>]]
      local key = record.key
      if type(key) == "string" and key ~= "" and registered[key] ~= nil then
        local class = record.contactClass
        if class == nil then
          class = IncomingCalls.KIND_ORDINARY
        end
        if type(class) ~= "number" or class % 1 ~= 0 then
          fail("incoming callers carry a numeric source caller class", { contact = key, class = class })
        end
        if classInCategory(class, category) then
          if
            not self:_isSameMap(key, args)
            and not (withHistory and history[key] ~= nil)
            and not self:_isContestExcluded(record)
          then
            out[#out + 1] = key
          end
        end
      end
    end
  end
  return out
end

-- Observes one civil sample: advances the cooldown by completed whole
-- minutes and expires an active ring on strict second bounds. The first
-- positive advance is the opening offline jump and is ignored for
-- cooldown. A backward sample returns early through the calendar and
-- preserves the ring. Polling, expiry, and evaluation draw nothing here.
---@param sample table<string, integer>
function IncomingCalls:onFieldClock(sample)
  self:_checkLive()
  local observe = self._calendar.observeField --[[@as fun(self: table<string, unknown>, sample: table<string, integer>): table<string, integer>]]
  local report = observe(self._calendar, sample)
  assert(type(report) == "table", "calendar observations report their advance")
  if report.backward == true then
    return
  end
  local advance = report.minuteAdvance
  assert(type(advance) == "number", "calendar observations report whole elapsed minutes")
  if advance > 0 then
    if not self._firstAdvanceSeen then
      self._firstAdvanceSeen = true
    else
      self._cooldown = self._cooldown + advance
    end
  end
  local ring = self._ring
  if ring ~= nil then
    if ring.startEpoch == nil then
      ring.startEpoch = epochSeconds(sample)
    else
      local elapsed = epochSeconds(sample) - ring.startEpoch
      if elapsed > IncomingCalls.RING_SECONDS or elapsed < 0 then
        self._ring = nil
      end
    end
  end
end

-- Offers one stable field opportunity: a claimed tick clears only
-- transient ring state, an active ring advances only its repeat counter,
-- and a settled unclaimed tick evaluates once. Trigger flags win without
-- touching the random gate; the gate fails and empty pools reset the
-- cooldown; an empty history-covered pool resets before filtering. Polls
-- and evaluations never draw outside the documented draws.
---@param args { mapKey: unknown?, mapId: unknown?, movementState: string, higherPriorityClaimed: boolean? }
function IncomingCalls:onOpportunity(args)
  self:_checkLive()
  assert(type(args) == "table", "field opportunities carry their stable-tick record")
  assert(
    type(args.movementState) == "string" and args.movementState ~= "",
    "field opportunities name their movement state"
  )
  if args.higherPriorityClaimed == true then
    self._ring = nil
    return
  end
  if args.movementState ~= "none" and args.movementState ~= "end" then
    return
  end
  local ring = self._ring
  if ring ~= nil then
    ring.counter = ring.counter + 1
    if ring.counter >= IncomingCalls.REPEAT_TICKS then
      ring.counter = 0
      self:_attemptTone()
    end
    return
  end
  local signal = self._world.signal
  local reception = self._world.reception
  if signal == "none" or reception == "none" then
    return
  end
  if self._cooldown < IncomingCalls.COOLDOWN_MINUTES then
    return
  end
  local triggers = self:_eligibleTriggers(args)
  if #triggers > 0 then
    local draw = self._random.lc --[[@as fun(self: table<string, unknown>, label: string): integer]]
    local pick = draw(self._random, "incoming-trigger-pick") % #triggers
    local selected = triggers[pick + 1]
    self:_startRing(selected.contactKey, selected.kind, selected.key)
    return
  end
  local drawMt = self._random.mt --[[@as fun(self: table<string, unknown>, label: string): integer]]
  local drawLc = self._random.lc --[[@as fun(self: table<string, unknown>, label: string): integer]]
  if drawMt(self._random, "incoming-gate") % 100 > IncomingCalls.GATE_PASS_MAX then
    self._cooldown = 0
    return
  end
  local residue = drawLc(self._random, "incoming-category") % 1000
  local category = 2
  if residue < IncomingCalls.CATEGORY_SPLIT_ZERO then
    category = 0
  elseif residue < IncomingCalls.CATEGORY_SPLIT_ONE then
    category = 1
  end
  local pool = self:_eligibleCallers(category, args, true)
  if #pool == 0 then
    local raw = self:_eligibleCallers(category, args, false)
    if #raw == 0 then
      self._cooldown = 0
      return
    end
    local readPhone = self._state.readPhone --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
    local history = readPhone(self._state).history
    assert(type(history) == "table", "history resets read the call journal")
    local cleared = {}
    for contactKey, value in pairs(history) do
      cleared[contactKey] = value
    end
    for _, contactKey in ipairs(raw) do
      cleared[contactKey] = nil
    end
    local setHistory = self._state.setCallHistory --[[@as fun(self: table<string, unknown>, history: table<string, boolean>)]]
    setHistory(self._state, cleared)
    pool = raw
  end
  local index = math.floor((drawMt(self._random, "incoming-pick") % (#pool * 100)) / 100)
  assert(index >= 0 and index < #pool, "the source pick form selects inside its pool")
  self:_startRing(pool[index + 1], IncomingCalls.KIND_ORDINARY, nil)
end

-- Raises one pending source trigger toward the threshold without ringing:
-- the next minute completes eligibility for the accelerated caller.
---@param key string
---@param accelerate boolean?
function IncomingCalls:setTrigger(key, accelerate)
  self:_checkLive()
  assert(type(key) == "string" and key ~= "", "trigger helpers name their trigger")
  local setTrigger = self._state.setTrigger --[[@as fun(self: table<string, unknown>, key: string, active: boolean)]]
  setTrigger(self._state, key, true)
  if accelerate == true and self._cooldown < IncomingCalls.COOLDOWN_MINUTES - 1 then
    self._cooldown = IncomingCalls.COOLDOWN_MINUTES - 1
  end
end

-- Accepts the active ring through the companion host: acquires first so a
-- failed acquisition consumes nothing, then clears the event trigger for
-- kind-three calls or records ordinary history for kind-zero calls,
-- resets ringing, and enters the incoming call. Clearing happens at
-- acceptance, never at ring start, expiry, or hangup.
---@param parentOwner string
---@return table<string, unknown>? the entered host handle
function IncomingCalls:accept(parentOwner)
  self:_checkLive()
  assert(type(parentOwner) == "string" and parentOwner ~= "", "accepted calls carry their parent identity")
  local ring = self._ring
  assert(ring ~= nil, "no incoming call is ringing")
  local request = {
    id = "incoming:" .. ring.contactKey,
    contact = ring.contactKey,
    direction = "incoming",
    kind = "incoming",
  }
  if self._host == nil then
    fail("no companion host is composed for the incoming call", { contact = ring.contactKey })
  end
  local host = self._host
  assert(type(host) == "table", "accepted calls enter through the composed host")
  local open = host.open --[[@as fun(self: table<string, unknown>, args: table<string, unknown>): table<string, unknown>]]
  local ok, handle = pcall(open, host, { mode = "call", request = request, parentOwner = parentOwner })
  if not ok then
    error(handle, 0)
  end
  if ring.kind == IncomingCalls.KIND_EVENT and ring.triggerKey ~= nil then
    local setTrigger = self._state.setTrigger --[[@as fun(self: table<string, unknown>, key: string, active: boolean)]]
    setTrigger(self._state, ring.triggerKey, false)
  elseif ring.kind == IncomingCalls.KIND_ORDINARY then
    local readPhone = self._state.readPhone --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
    local history = readPhone(self._state).history
    assert(type(history) == "table", "acceptance reads the call journal")
    local recorded = {}
    for contactKey, value in pairs(history) do
      recorded[contactKey] = value
    end
    recorded[ring.contactKey] = true
    local setHistory = self._state.setCallHistory --[[@as fun(self: table<string, unknown>, history: table<string, boolean>)]]
    setHistory(self._state, recorded)
  end
  self._ring = nil
  return handle
end

-- Borrows the detached notification view: false while silent, otherwise
-- the caller key, display name, shared ringing animation, and source
-- caller window. Reading the view draws no randomness and mutates
-- nothing. The view carries no art of its own.
---@return false|{ contactKey: string, name: string, nameTokens: string[], ringingAnimation: integer, sourceWindow: { tileLeft: integer, top: integer, height: integer, width: integer } }
function IncomingCalls:notification()
  if self._disposed then
    return false
  end
  local ring = self._ring
  if ring == nil then
    return false
  end
  local record = self:_contactRecord(ring.contactKey)
  local name = ring.contactKey
  if record ~= nil then
    if type(record.name) == "string" and record.name ~= "" then
      name = record.name
    elseif type(record.label) == "string" and record.label ~= "" then
      name = record.label
    end
  end
  local width = math.floor((glyphCount(name) * IncomingCalls.FALLBACK_ADVANCE) / 8) + 2
  if width > IncomingCalls.WINDOW_MAX_WIDTH then
    width = IncomingCalls.WINDOW_MAX_WIDTH
  end
  return {
    contactKey = ring.contactKey,
    name = name,
    nameTokens = { name },
    ringingAnimation = IncomingCalls.RINGING_ANIMATION,
    sourceWindow = {
      tileLeft = IncomingCalls.WINDOW_TILE_LEFT,
      top = IncomingCalls.WINDOW_TOP,
      height = IncomingCalls.WINDOW_HEIGHT,
      width = width,
    },
  }
end

-- Clears only transient ring state for a no-signal transition, a
-- higher-priority field event, or runtime teardown. Trigger flags,
-- history, and the cooldown accumulator keep their source clearing
-- points elsewhere.
---@param reason string
function IncomingCalls:resetTransient(reason)
  self:_checkLive()
  assert(type(reason) == "string" and reason ~= "", "transient resets name their reason")
  self._ring = nil
end

-- Releases the runtime lifetime exactly once: the ring quiets and later
-- calls fail instead of acting on borrowed owners past teardown.
function IncomingCalls:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._ring = nil
end

return IncomingCalls
