-- Incoming calls while the companion stays closed: whole-minute
-- eligibility with the opening offline jump ignored, source trigger
-- selection ahead of the random gate, exact inclusive random boundaries,
-- strict ring expiry with backward-time protection, and the launch as the
-- single clearing boundary. One field-runtime-owned manager standing in
-- for the source GearPhoneRingManager: it holds the one pending caller
-- request every lane writes (a ringing trigger or random call, a scripted
-- setup, a forced trigger) and the launch consumes, and it owns the
-- cooldown, the ring tone, and the caller notification view. Borrows the
-- companion state, calendar, draw streams, world facts, application host,
-- ring tone owner, and the scene-script starter behind a forced call. The
-- notification view is detached and draws no randomness. Pure policy: no
-- love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local PokegearState = require("libs.hgss.src.save.PokegearState")

---@class IncomingCalls
---@field private _state table<string, unknown> the borrowed durable companion owner
---@field private _catalog table<string, unknown> the borrowed contact catalog
---@field private _calendar table<string, unknown> the borrowed civil calendar adapter
---@field private _random table<string, unknown> the borrowed companion draw streams
---@field private _world table<string, unknown> the borrowed world facts
---@field private _messages table<string, unknown>?
---@field private _host table<string, unknown>? the borrowed companion application host
---@field private _audio table<string, unknown>? the borrowed ring tone owner
---@field private _startCallScript fun(): string? the borrowed source scene-script starter a forced call runs
---@field private _mapReceivesCalls fun(): boolean the borrowed map-header coverage gate
---@field private _cooldown integer accumulated eligible minutes
---@field private _openingSamplePending boolean whether the first field clock sample is pending
---@field private _openingCheckpointRestored boolean whether construction found a saved calendar checkpoint
---@field private _pending table<string, unknown>? the one pending caller request (source active/caller params)
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
-- The source isScriptedCall markers the launch boundary reads:
-- GearPhoneRingManager always launches a picked trigger with 3, a random
-- pick with 0, and a script setup with whatever marker its script named.
-- FieldSystem_InitPokegearArgs clears the launched trigger for a 3 and
-- records a recent caller only for a 0.
IncomingCalls.SCRIPTED_TRIGGER = 3
IncomingCalls.SCRIPTED_NONE = 0
-- Source-eligible random caller types per GearPhoneRingManager_TryRandomCall:
-- generic trainers, gym leaders, Ethan/Lyra, Buena, and Irwin. Every
-- other native contact type only rings through its trigger.
IncomingCalls.RANDOM_CALL_TYPES = { [0] = true, [12] = true, [11] = true, [10] = true, [14] = true }
-- The native Day-Care Man contact id behind the source's registration
-- rule for that one trigger caller (PHONE_CONTACT_DAY_C_MAN).
IncomingCalls.DAYCARE_MAN_CONTACT_ID = 6
-- Recent-caller chunk sizes per random-call group behind SaveMisc
-- (_020F677C): the single chunk table lives on the save owner and is
-- borrowed here, so validation and selection can never disagree.
local CHUNK_SIZES = PokegearState.HISTORY_CHUNK_SIZES

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

---@class IncomingCallsOptions
---@field state table<string, unknown> the durable companion owner
---@field catalog table<string, unknown> the compiled contact and trigger catalog
---@field calendar table<string, unknown> the civil calendar adapter
---@field random table<string, unknown> the companion draw streams
---@field world table<string, unknown> the world facts
---@field messages table<string, unknown>? the message references
---@field host table<string, unknown>? the companion application host
---@field audio table<string, unknown>? the ring tone owner
---@field startCallScript fun(): string? the source scene-script starter a forced call runs
---@field mapReceivesCalls fun(): boolean the map-header incoming-call coverage gate

---@param opts IncomingCallsOptions
---@return IncomingCalls
function IncomingCalls.new(opts)
  assert(type(opts) == "table", "incoming calls borrow their owners through a record")
  assert(
    type(opts.state) == "table"
      and type(opts.state.readPhone) == "function"
      and type(opts.state.readCalendar) == "function"
      and type(opts.state.setTrigger) == "function"
      and type(opts.state.setCallHistory) == "function"
      and type(opts.state.setKenjiErrand) == "function"
      and type(opts.state.setRematch) == "function"
      and type(opts.state.setContactReward) == "function",
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
      ),
    "incoming calls repeat their tone through the ring tone owner"
  )
  -- A forced trigger answers itself by running the source scene script
  -- that rings and then launches the call; without that starter the
  -- trigger could not reach its own launch.
  assert(
    type(opts.startCallScript) == "function",
    "incoming calls start forced calls through their scene-script starter"
  )
  -- The source TryStartCall refuses every call on a map whose header
  -- forbids incoming calls before any draw or trigger; the gate is the
  -- caller's map-header coverage, never a default.
  assert(type(opts.mapReceivesCalls) == "function", "incoming calls read the map-header incoming-call coverage")
  local calendarState = opts.state.readCalendar(opts.state)
  assert(type(calendarState) == "table", "incoming calls inspect the persisted calendar checkpoint")
  return setmetatable({
    _state = opts.state,
    _catalog = opts.catalog,
    _calendar = opts.calendar,
    _random = opts.random,
    _world = opts.world,
    _messages = opts.messages,
    _host = opts.host,
    _audio = opts.audio,
    _startCallScript = opts.startCallScript,
    _mapReceivesCalls = opts.mapReceivesCalls,
    _cooldown = 0,
    _openingSamplePending = true,
    _openingCheckpointRestored = calendarState.checkpoint ~= nil,
    _pending = nil,
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

-- Records the one pending caller request the launch consumes: the source
-- ring manager's caller parameters. A toned request also owns the source
-- ring tone loop; a scripted or forced request is toned by its own scene
-- script instead. Only a random pick carries the recent-caller chunk and
-- candidate count the launch records with.
---@param self IncomingCalls
---@param record { contactKey: string, callScriptID: integer?, isScriptedCall: integer, triggerKey: string?, recentCallersChunk: integer?, recentCallerCount: integer?, toned: boolean }
function IncomingCalls:_stageCall(record)
  assert(self._pending == nil, "one pending call owns the phone line")
  self._pending = {
    contactKey = record.contactKey,
    callScriptID = record.callScriptID,
    isScriptedCall = record.isScriptedCall,
    triggerKey = record.triggerKey,
    recentCallersChunk = record.recentCallersChunk,
    recentCallerCount = record.recentCallerCount,
    toned = record.toned == true,
    startEpoch = nil,
    counter = 0,
  }
end

-- Stages one scripted call setup from the script platform. The source
-- stores the ring manager's caller parameters ahead of the launch, so the
-- call is incoming by construction and carries its scripted marker and
-- predefined script identity untouched. A script setup names no trigger
-- and no recent-caller chunk, exactly like ScrCmd_SetPhoneCall, so its
-- launch clears and records nothing. Nothing is cleared here either: the
-- launch below is the clearing boundary.
---@param request { contact: string, isScriptedCall: integer, callScriptID: integer }
function IncomingCalls:stageCall(request)
  self:_checkLive()
  assert(type(request) == "table", "staged calls carry their evaluated request")
  assert(type(request.contact) == "string" and request.contact ~= "", "staged calls name their caller")
  assert(
    type(request.isScriptedCall) == "number" and request.isScriptedCall % 1 == 0,
    "staged calls carry their source scripted marker"
  )
  assert(
    type(request.callScriptID) == "number" and request.callScriptID % 1 == 0,
    "staged calls carry their source script identity"
  )
  self:_stageCall({
    contactKey = request.contact,
    isScriptedCall = request.isScriptedCall,
    callScriptID = request.callScriptID,
    toned = false,
  })
end

---@return boolean
function IncomingCalls:hasPendingCall()
  return self._pending ~= nil
end

-- The source gearRingingManagerReset: the pending caller clears and the
-- eligibility clock restarts at zero. The source destroys only the task
-- that re-triggers the ring tone, never the tone already playing, so no
-- effect is cut here either. Trigger flags, history, and the emerging day
-- facts keep their own clearing points.
---@param self IncomingCalls
function IncomingCalls:_resetManager()
  self._pending = nil
  self._cooldown = 0
end

-- Consumes the pending caller request and closes the source launch-args
-- boundary (FieldSystem_InitPokegearArgs): an isScriptedCall-3 launch
-- clears the trigger it launched, an isScriptedCall-0 launch records its
-- recent caller into the chunk captured at pick, and any other marker
-- leaves both alone. The manager then resets. Returns the consumed
-- request, or nil when nothing was pending.
---@param self IncomingCalls
---@return { contactKey: string, triggerKey: string?, callScriptID: integer?, isScriptedCall: integer }?
function IncomingCalls:takePendingCall()
  self:_checkLive()
  local pending = self._pending
  if pending == nil then
    return nil
  end
  if pending.isScriptedCall == IncomingCalls.SCRIPTED_TRIGGER then
    -- A script setup carries no trigger of its own, so only a picked
    -- trigger has a flag to clear here.
    if pending.triggerKey ~= nil then
      local setTrigger = self._state.setTrigger --[[@as fun(self: table<string, unknown>, key: string, active: boolean)]]
      setTrigger(self._state, pending.triggerKey, false)
    end
  elseif pending.isScriptedCall == IncomingCalls.SCRIPTED_NONE and pending.recentCallersChunk ~= nil then
    -- The source records with the candidate count captured at pick: a
    -- full chunk clears before the caller lands, otherwise its oldest
    -- entry shifts out.
    local readPhone = self._state.readPhone --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
    local history = readPhone(self._state).history
    assert(type(history) == "table", "acceptance reads the call journal")
    self:_historyAdd(
      history,
      pending.recentCallersChunk --[[@as integer]],
      pending.recentCallerCount --[[@as integer]],
      pending.contactKey --[[@as string]]
    )
    local setHistory = self._state.setCallHistory --[[@as fun(self: table<string, unknown>, history: table<string, unknown>)]]
    setHistory(self._state, history)
  end
  self:_resetManager()
  return pending
end

-- Starts one ring over a selected source trigger: stages the pending
-- payload the launch consumes and attempts the opening tone. Trigger
-- flags, history, and the cooldown accumulator are untouched until the
-- launch or a reset; the source launches every trigger call with
-- isScriptedCall 3, so the ring carries that marker, the trigger's script
-- identity, and the trigger the launch clears.
---@param self IncomingCalls
---@param contactKey string
---@param triggerKey string
---@param callScriptID integer?
function IncomingCalls:_startRing(contactKey, triggerKey, callScriptID)
  self:_stageCall({
    contactKey = contactKey,
    triggerKey = triggerKey,
    callScriptID = callScriptID,
    isScriptedCall = IncomingCalls.SCRIPTED_TRIGGER,
    toned = true,
  })
  self:_attemptTone()
end

---@param record unknown
---@return string triggerKey, integer? callScriptID, boolean forcePickUp
local function checkTriggerRecord(record)
  if type(record) ~= "table" then
    fail("incoming call triggers carry key, contact, and pickup flag", {})
  end
  assert(type(record) == "table", "trigger selection reads the trigger record")
  local entry = record --[[@as table<string, unknown>]]
  if type(entry.key) ~= "string" or entry.key == "" then
    fail("incoming call triggers carry their trigger key", {})
  end
  if type(entry.contact) ~= "string" or entry.contact == "" then
    fail("incoming call triggers carry their owning contact", { key = entry.key })
  end
  if type(entry.forcePickUp) ~= "boolean" then
    fail("incoming call triggers carry their pickup flag", { key = entry.key })
  end
  local scriptID = entry.callScriptID
  if scriptID ~= nil then
    if type(scriptID) ~= "number" or scriptID % 1 ~= 0 then
      fail("incoming call triggers carry their source script identity", { key = entry.key })
    end
  end
  return entry.key, --[[@as string]]
    scriptID, --[[@as integer?]]
    entry.forcePickUp
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

-- The ordered per-chunk journal behind SaveMisc (_020F677C):
-- Contains/Count/Clear scoped to the time-of-day chunk, and Add
-- filling the first empty slot, clearing a full chunk when the
-- pre-filter candidate count covers the whole chunk plus one, else
-- shifting the oldest caller out. Counts and callers ride the
-- detached journal; the caller commits through setCallHistory.
---@param history table<integer, string[]> detached ordered journal
---@param chunk integer 0..2 time-of-day chunk
---@param contactKey string caller key
---@return boolean contained
function IncomingCalls:_historyContains(history, chunk, contactKey)
  assert(type(history) == "table", "chunk reads borrow the detached journal")
  assert(chunk == 0 or chunk == 1 or chunk == 2, "chunk reads name a source chunk")
  local list = history[chunk]
  assert(type(list) == "table", "chunk reads carry every chunk list")
  for _, key in ipairs(list) do
    if key == contactKey then
      return true
    end
  end
  return false
end

---@param history table<integer, string[]> detached ordered journal
---@param chunk integer 0..2 time-of-day chunk
---@return integer count
function IncomingCalls:_historyCount(history, chunk)
  assert(type(history) == "table", "chunk reads borrow the detached journal")
  assert(chunk == 0 or chunk == 1 or chunk == 2, "chunk reads name a source chunk")
  local list = history[chunk]
  assert(type(list) == "table", "chunk reads carry every chunk list")
  return #list
end

---@param history table<integer, string[]> detached ordered journal
---@param chunk integer 0..2 time-of-day chunk
function IncomingCalls:_historyClear(history, chunk)
  assert(type(history) == "table", "chunk writes borrow the detached journal")
  assert(chunk == 0 or chunk == 1 or chunk == 2, "chunk writes name a source chunk")
  history[chunk] = {}
end

---@param history table<integer, string[]> detached ordered journal
---@param chunk integer 0..2 time-of-day chunk
---@param a2 integer pre-filter candidate count captured at pick
---@param contactKey string caller key
function IncomingCalls:_historyAdd(history, chunk, a2, contactKey)
  assert(type(history) == "table", "chunk writes borrow the detached journal")
  assert(chunk == 0 or chunk == 1 or chunk == 2, "chunk writes name a source chunk")
  assert(type(a2) == "number" and a2 % 1 == 0 and a2 >= 0, "chunk writes carry their candidate count")
  local list = history[chunk]
  assert(type(list) == "table", "chunk writes carry every chunk list")
  local size = CHUNK_SIZES[chunk]
  assert(type(size) == "number", "chunk writes read the chunk size")
  -- The pick excludes callers already in the chunk, so a recorded caller
  -- cannot reach here twice; the source add has no duplicate check either.
  assert(not self:_historyContains(history, chunk, contactKey), "the launch records an unrecorded caller")
  if #list < size then
    list[#list + 1] = contactKey
    return
  end
  if a2 == size + 1 then
    history[chunk] = { contactKey }
    return
  end
  for index = 1, size - 1 do
    list[index] = list[index + 1]
  end
  list[size] = contactKey
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
    place = record.mapId
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
-- whose caller passes the source reachability rule. Only the Day-Care
-- Man trigger requires a registered number; every other trigger rings
-- regardless of registration, and every non-Day-Care-Man trigger stays
-- silent on its caller's own map. Corrupt set records fail with
-- attribution instead of selecting a plausible caller.
---@param self IncomingCalls
---@param args { mapKey: unknown?, mapId: unknown? }
---@return table<integer, { key: string, contactKey: string, callScriptID: integer?, forcePickUp: boolean }>
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
        local triggerKey, callScriptID, forcePickUp = checkTriggerRecord(record)
        local contact = (record --[[@as table<string, unknown>]]).contact --[[@as string]]
        local contactRecord = self:_contactRecord(contact)
        if contactRecord == nil then
          fail("incoming call triggers reference a catalogued contact", { key = triggerKey, contact = contact })
        end
        assert(type(contactRecord) == "table", "trigger callers resolve through the contact catalog")
        local caller = contactRecord --[[@as table<string, unknown>]]
        -- The Day-Care Man is the only trigger caller the source gates
        -- on registration; his ring has no same-map exclusion, while
        -- every other trigger caller only needs to be off the
        -- opportunity map.
        if caller.id == IncomingCalls.DAYCARE_MAN_CONTACT_ID then
          if registered[contact] ~= nil then
            out[#out + 1] = {
              key = triggerKey,
              contactKey = contact,
              callScriptID = callScriptID,
              forcePickUp = forcePickUp,
            }
          end
        elseif not self:_isSameMap(contact, args) then
          out[#out + 1] = {
            key = triggerKey,
            contactKey = contact,
            callScriptID = callScriptID,
            forcePickUp = forcePickUp,
          }
        end
      end
    end
  end
  return out
end

---@param class integer
---@return boolean
local function isRandomCallType(class)
  return IncomingCalls.RANDOM_CALL_TYPES[class] == true
end

-- Builds the eligible random pool in catalog order: acquired contacts of
-- a pool caller type in the drawn random-call group, off the opportunity
-- map, outside live contests, and (optionally) outside call history. Also
-- reports the source candidate count -- the registered pool callers in
-- the group before the map, contest, and history exclusions -- which
-- decides the full-chunk clear and travels to the launch as the recent-
-- caller add's candidate count. History filtering stays an argument so a
-- covered pool can reset before the final filter.
---@param self IncomingCalls
---@param category integer
---@param args { mapKey: unknown?, mapId: unknown? }
---@param withHistory boolean whether call-history entries exclude
---@return table<integer, string> eligible contact keys
---@return integer candidate count before the map and contest exclusions
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
  local candidates = 0
  for _, entry in ipairs(contacts) do
    if type(entry) == "table" then
      local record = entry --[[@as table<string, unknown>]]
      local key = record.key
      if type(key) == "string" and key ~= "" and registered[key] ~= nil then
        local nativeType = record.entryType
        if type(nativeType) ~= "number" or nativeType % 1 ~= 0 then
          fail("incoming callers carry a numeric native caller type", { contact = key, entryType = nativeType })
        end
        local group = record.randomCallGroup
        if type(group) ~= "number" or group % 1 ~= 0 then
          fail("incoming callers carry a numeric source random-call group", { contact = key, group = group })
        end
        if isRandomCallType(nativeType) and group == category then
          candidates = candidates + 1
          if
            not self:_isSameMap(key, args)
            and not (withHistory and self:_historyContains(history, category, key))
            and not self:_isContestExcluded(record)
          then
            out[#out + 1] = key
          end
        end
      end
    end
  end
  return out, candidates
end

-- Observes one civil sample: advances the cooldown by completed whole
-- minutes and expires an active ring on strict second bounds. A restored
-- checkpoint's opening report may include offline time, which is ignored
-- once. A fresh checkpoint starts at its opening sample, so its next live
-- minute counts. A backward sample preserves the ring. Polling, expiry,
-- and evaluation draw nothing here. Returns the calendar report so the
-- field runtime can consume the civil-day advance on the same observation.
---@param sample table<string, integer>
---@return { dayAdvance: integer, minuteAdvance: integer, backward: boolean } report
function IncomingCalls:onFieldClock(sample)
  self:_checkLive()
  local observe = self._calendar.observeField --[[@as fun(self: table<string, unknown>, sample: table<string, integer>): table<string, integer>]]
  local report = observe(self._calendar, sample)
  assert(type(report) == "table", "calendar observations report their advance")
  local openingSample = self._openingSamplePending
  self._openingSamplePending = false
  if report.backward == true then
    return report --[[@as { dayAdvance: integer, minuteAdvance: integer, backward: boolean }]]
  end
  local advance = report.minuteAdvance
  assert(type(advance) == "number", "calendar observations report whole elapsed minutes")
  if advance > 0 and not (openingSample and self._openingCheckpointRestored) then
    self._cooldown = self._cooldown + advance
  end
  local dayAdvance = report.dayAdvance
  assert(type(dayAdvance) == "number", "calendar observations report whole elapsed days")
  if dayAdvance > 0 then
    self:_advanceKenjiErrand(dayAdvance)
  end
  local pending = self._pending
  if pending ~= nil then
    if pending.startEpoch == nil then
      pending.startEpoch = epochSeconds(sample)
    else
      local elapsed = epochSeconds(sample) - pending.startEpoch
      if elapsed > IncomingCalls.RING_SECONDS or elapsed < 0 then
        -- An expired request resets the whole manager like the source
        -- gearRingingManagerReset: the tone stops and the cooldown
        -- restarts instead of re-ringing at once.
        self:_resetManager()
      end
    end
  end
  return report --[[@as { dayAdvance: integer, minuteAdvance: integer, backward: boolean }]]
end

-- Advances the Kenji errand wait on a civil-day advance, mirroring
-- PhoneCallPersistentState_BlackBeltKenji_UpdateWaitDays: the active
-- flag always clears; a wait covering the elapsed days decrements;
-- otherwise a fresh 1-6 day wait rolls and the staged seeking and
-- gift clear with it. The reroll draws exactly like the source
-- LCRandom bound.
---@param days integer elapsed civil days
function IncomingCalls:_advanceKenjiErrand(days)
  assert(type(days) == "number" and days % 1 == 0 and days > 0, "kenji errands advance whole elapsed days")
  local readPhone = self._state.readPhone --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
  local phone = readPhone(self._state)
  assert(type(phone) == "table", "kenji errands read the phone projection")
  local kenji = phone.kenji
  local waitDays = type(kenji) == "table" and kenji.waitDays or 0
  assert(type(waitDays) == "number" and waitDays % 1 == 0, "kenji errands carry integral wait days")
  local setErrand = self._state.setKenjiErrand
  assert(type(setErrand) == "function", "kenji errands write durable companion state")
  if waitDays >= days then
    setErrand(self._state, waitDays - days, false)
    return
  end
  local draw = self._random.lc --[[@as fun(self: table<string, unknown>, label: string): integer]]
  local reroll = draw(self._random, "kenji-wait") % 6 + 1
  setErrand(self._state, reroll, false)
  local key = nil
  for _, entry in ipairs(self._catalog.contacts) do
    if type(entry) == "table" and entry.family == "kenji" then
      key = entry.key
      break
    end
  end
  local contacts = phone.contacts
  if type(key) == "string" and type(contacts) == "table" and contacts[key] ~= nil then
    local clearRematch = self._state.setRematch
    assert(type(clearRematch) == "function", "kenji expiry clears the staged invitation")
    clearRematch(self._state, key, nil)
    local clearReward = self._state.setContactReward
    assert(type(clearReward) == "function", "kenji expiry clears the staged gift")
    clearReward(self._state, key, nil)
  end
end

-- Offers one stable field opportunity: a claimed tick clears only
-- transient ring state, an active ring advances only its repeat counter,
-- and a settled unclaimed tick evaluates once. Trigger flags win without
-- touching the random gate; the gate fails and empty pools reset the
-- cooldown; an empty history-covered pool resets before filtering. Polls
-- and evaluations never draw outside the documented draws. A forced
-- source trigger answers itself by running the source scene script, which
-- rings and launches the call; nothing opens here.
---@param args { mapKey: unknown?, mapId: unknown?, movementState: string, higherPriorityClaimed: boolean? }
function IncomingCalls:onOpportunity(args)
  self:_checkLive()
  assert(type(args) == "table", "field opportunities carry their stable-tick record")
  assert(
    type(args.movementState) == "string" and args.movementState ~= "",
    "field opportunities name their movement state"
  )
  if args.higherPriorityClaimed == true then
    -- A held tick quiets an ambient ring without restarting the
    -- eligibility clock. A scripted or forced request belongs to the field
    -- task that claimed this tick, so it survives until its own launch.
    local pending = self._pending
    if pending ~= nil and pending.toned then
      self._pending = nil
    end
    return
  end
  if args.movementState ~= "none" and args.movementState ~= "end" then
    return
  end
  -- The source refuses every call on a map whose header forbids incoming
  -- calls: no gate draw, no trigger, and nothing consumed.
  if self._mapReceivesCalls() ~= true then
    return
  end
  local pending = self._pending
  if pending ~= nil then
    -- A scripted or forced request is toned by its own scene script, so
    -- only a manager-toned ring advances the repeat counter here.
    if pending.toned then
      pending.counter = pending.counter + 1
      if pending.counter >= IncomingCalls.REPEAT_TICKS then
        pending.counter = 0
        self:_attemptTone()
      end
    end
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
    if selected.forcePickUp == true then
      self:_startForcedCall(selected)
      return
    end
    self:_startRing(selected.contactKey, selected.key, selected.callScriptID)
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
  -- The source counts its candidates before the map and contest
  -- exclusions, so an all-excluded group still counts (and can still
  -- clear a covered chunk) while it rings nobody.
  local _, candidateCount = self:_eligibleCallers(category, args, false)
  if candidateCount == 0 then
    self._cooldown = 0
    return
  end
  local readPhone = self._state.readPhone --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
  local history = readPhone(self._state).history
  assert(type(history) == "table", "caller selection reads the call journal")
  local setHistory = self._state.setCallHistory --[[@as fun(self: table<string, unknown>, history: table<string, unknown>)]]
  if self:_historyCount(history, category) == candidateCount then
    self:_historyClear(history, category)
    setHistory(self._state, history)
  end
  local pool = self:_eligibleCallers(category, args, true)
  if #pool == 0 then
    self._cooldown = 0
    return
  end
  local index = math.floor((drawMt(self._random, "incoming-pick") % (#pool * 100)) / 100)
  assert(index >= 0 and index < #pool, "the source pick form selects inside its pool")
  -- The pick hands its caller parameters to the launch, which is the only
  -- place the source records a recent caller: the drawn chunk and the
  -- candidate count travel with the pending request.
  self:_stageCall({
    contactKey = pool[index + 1],
    isScriptedCall = IncomingCalls.SCRIPTED_NONE,
    recentCallersChunk = category,
    recentCallerCount = candidateCount,
    toned = true,
  })
  self:_attemptTone()
end

--- Starts one forced trigger call the way the source does: the trigger
--- params land on the manager (so the caller window shows while it rings),
--- then the field runs the source scene script that plays the two blocking
--- tones, covers the screen, and launches the call (result 2 of
--- TryCallTrigger). The trigger flag is deliberately not cleared here: the
--- source clears an isScriptedCall-3 flag when the launch reads the caller
--- params, and the eligibility clock restarts at that same boundary.
---@param selected { key: string, contactKey: string, callScriptID: integer? }
function IncomingCalls:_startForcedCall(selected)
  self:_checkLive()
  assert(type(selected) == "table", "forced launches name their trigger")
  assert(type(selected.key) == "string" and selected.key ~= "", "forced launches name their trigger key")
  assert(type(selected.contactKey) == "string" and selected.contactKey ~= "", "forced launches name their caller")
  self:_stageCall({
    contactKey = selected.contactKey,
    triggerKey = selected.key,
    callScriptID = selected.callScriptID,
    isScriptedCall = IncomingCalls.SCRIPTED_TRIGGER,
    toned = false,
  })
  local started = self._startCallScript()
  assert(
    type(started) == "string" and started ~= "",
    "a settled opportunity starts the forced call's source scene script"
  )
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

-- Accepts the pending ring through the companion host: acquires first so
-- a failed acquisition consumes nothing, then closes the source
-- launch-args boundary (its trigger flag or recent-caller record) and
-- resets the manager, exactly like every other launch lane.
---@param parentOwner string
---@return table<string, unknown>? the entered host handle
function IncomingCalls:accept(parentOwner)
  self:_checkLive()
  assert(type(parentOwner) == "string" and parentOwner ~= "", "accepted calls carry their parent identity")
  local pending = self._pending
  assert(pending ~= nil, "no incoming call is ringing")
  local request = {
    id = "incoming:" .. pending.contactKey,
    contact = pending.contactKey,
    direction = "incoming",
    kind = "incoming",
    isScriptedCall = pending.isScriptedCall,
    callScriptID = pending.callScriptID,
  }
  if self._host == nil then
    fail("no companion host is composed for the incoming call", { contact = pending.contactKey })
  end
  local host = self._host
  assert(type(host) == "table", "accepted calls enter through the composed host")
  local open = host.open --[[@as fun(self: table<string, unknown>, args: table<string, unknown>): table<string, unknown>]]
  local ok, handle = pcall(open, host, { mode = "call", request = request, parentOwner = parentOwner })
  if not ok then
    error(handle, 0)
  end
  assert(self:takePendingCall() ~= nil, "the accepted request is consumed exactly once")
  return handle
end

-- Borrows the detached notification view: false while silent, otherwise
-- the caller key, display name, and the shared ringing animation. Reading
-- the view draws no randomness and mutates nothing. The view carries no art
-- and no window geometry of its own: the compiled field-UI class owns the
-- caller bubble and the source window it frames, and the presentation sizes
-- that window from the caller name.
---@return false|{ contactKey: string, name: string, ringingAnimation: integer }
function IncomingCalls:notification()
  if self._disposed then
    return false
  end
  local pending = self._pending
  if pending == nil then
    return false
  end
  local record = self:_contactRecord(pending.contactKey)
  local name = pending.contactKey
  if record ~= nil then
    if type(record.name) == "table" then
      local messages = self._messages
      local resolveName = type(messages) == "table" and messages.resolveName or nil
      assert(type(resolveName) == "function", "incoming caller names resolve through the field message provider")
      name = resolveName(messages, pending.contactKey)
    elseif type(record.name) == "string" and record.name ~= "" then
      name = record.name
    elseif type(record.label) == "string" and record.label ~= "" then
      name = record.label
    end
  end
  return {
    contactKey = pending.contactKey,
    name = name,
    ringingAnimation = IncomingCalls.RINGING_ANIMATION,
  }
end

-- Resets the manager for a field transition, a battle, or runtime
-- teardown, mirroring the source GearPhoneRingManager_ResetIfActive: the
-- tone stops, the pending caller clears, and the eligibility clock
-- restarts. Trigger flags and history keep their own clearing points.
---@param reason string
function IncomingCalls:resetTransient(reason)
  self:_checkLive()
  assert(type(reason) == "string" and reason ~= "", "transient resets name their reason")
  self:_resetManager()
end

-- Releases the runtime lifetime exactly once: the ring quiets and later
-- calls fail instead of acting on borrowed owners past teardown.
function IncomingCalls:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._pending = nil
end

return IncomingCalls
