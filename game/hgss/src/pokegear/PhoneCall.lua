-- Foreground phone session owner: at most one live call with a stable
-- runtime id and a monotonically advancing program position. Connection
-- tones, frozen greeting selection, program dispatch, choices, and
-- hangup are separate stages; each source effect runs once when its
-- original stage is entered, never per poll and never as a blanket
-- commit at hangup. Dialing plays the source dial tone twice and waits
-- on the effect-player completion boundary; hangup plays the source
-- hangup tone and post-increments its timers. Views are detached closed
-- unions; stale handles fail without touching a new call. Cancellation
-- releases the lease but never rolls back committed effects. Pure
-- session logic over injected owners: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local GenericPhoneProgram = require("game.hgss.src.pokegear.phone.GenericPhoneProgram")
local MotherPhoneProgram = require("game.hgss.src.pokegear.phone.MotherPhoneProgram")
local ProfessorPhonePrograms = require("game.hgss.src.pokegear.phone.ProfessorPhonePrograms")
local ServicePhonePrograms = require("game.hgss.src.pokegear.phone.ServicePhonePrograms")
local TrainerPhonePrograms = require("game.hgss.src.pokegear.phone.TrainerPhonePrograms")

---@class PhoneCall
---@field private _state table<string, unknown>
---@field private _catalog table<string, unknown>
---@field private _messages table<string, unknown>
---@field private _world table<string, unknown>
---@field private _audio table<string, unknown>?
---@field private _random table<string, unknown>?
---@field private _active string?
---@field private _calls table<string, table<string, unknown>>
---@field private _hangups integer
local PhoneCall = {}
PhoneCall.__index = PhoneCall

PhoneCall.DIRECTIONS = { incoming = true, outgoing = true }
PhoneCall.KINDS = { ordinary = true, rematch = true, predefined = true, incoming = true }

-- World facts frozen at the call boundary for program dispatch. Only
-- these keys are snapshotted; a long call never switches its greeting
-- or program after midnight.
local FACT_KEYS = {
  "predefinedScript",
  "localMap",
  "panicCall",
  "rivalUnnamed",
  "eggEvent",
  "eggGift",
  "eggHatched",
  "everstone",
  "badges",
  "rockets",
  "gameClear",
  "ssTicket",
  "pokerus",
  "dexSeen",
  "dexCaught",
  "nationalDex",
  "excluded",
  "giftPending",
  "storyCall",
  "contest",
  "weekday",
  "hour",
  "morning",
  "repeatCall",
  "aboutProduction",
  "aboutEgg",
  "subject",
  "safariTest",
  "hasBicycle",
  "blueCard",
  "passwordKnown",
  "takeover",
  "closed",
  "pcFreeSlots",
  "acknowledged",
  "storyEvent",
  "kenjiActive",
  "waitExpired",
}

---@param deps { state: table<string, unknown>, catalog: table<string, unknown>, messages: table<string, unknown>, world: table<string, unknown>, audio: table<string, unknown>?, random: table<string, unknown>? }
---@return PhoneCall
function PhoneCall.new(deps)
  assert(type(deps) == "table", "phone calls borrow their owners through a record")
  assert(type(deps.state) == "table", "phone calls borrow the companion state")
  assert(type(deps.catalog) == "table", "phone calls borrow the contact catalog")
  assert(type(deps.messages) == "table", "phone calls borrow their message references")
  assert(type(deps.world) == "table", "phone calls borrow their world")
  if deps.audio ~= nil then
    assert(type(deps.audio) == "table", "phone calls use the audio boundary as a record")
  end
  if deps.random ~= nil then
    assert(type(deps.random) == "table", "phone calls draw through the companion streams")
  end
  return setmetatable({
    _state = deps.state,
    _catalog = deps.catalog,
    _messages = deps.messages,
    _world = deps.world,
    _audio = deps.audio,
    _random = deps.random,
    _active = nil,
    _calls = {},
    _hangups = 0,
  }, PhoneCall)
end

-- Resolves one caller program identity from its family and labelled
-- facts. Closed dispatch over the concrete family modules: no predicate
-- language, no default conversation.
---@param family string caller family
---@param facts table<string, unknown> labelled source facts
---@return string program identity
function PhoneCall.selectProgram(family, facts)
  assert(type(family) == "string" and family ~= "", "program dispatch names its caller family")
  assert(type(facts) == "table", "program dispatch reads labelled facts")
  if family == "elm" or family == "elm-predefined" then
    return ProfessorPhonePrograms.selectElm(facts)
  end
  if family == "oak" then
    return ProfessorPhonePrograms.selectOak(facts)
  end
  if family == "mother" then
    return MotherPhoneProgram.selectName(facts)
  end
  if family == "generic" then
    return GenericPhoneProgram.selectName(facts)
  end
  if family == "gym" or family == "rematch" or family == "kenji" or family == "irwin" or family == "trainer" then
    return TrainerPhonePrograms.selectName(family, facts)
  end
  return ServicePhonePrograms.selectName(family, facts)
end

---@param owner table<string, unknown>
---@return table<string, boolean> registered contact set
local function registeredContacts(owner)
  local readPhone = owner.readPhone --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
  local phone = readPhone(owner)
  assert(type(phone) == "table" and type(phone.contacts) == "table", "phone calls read registered contacts")
  local keys = {}
  for key in
    pairs(phone.contacts --[[@as table<string, unknown>]])
  do
    keys[
      key --[[@as string]]
    ] = true
  end
  return keys
end

---@param world table<string, unknown>
---@param kind string
---@param direction string
---@return table<string, unknown> frozen dispatch facts
local function snapshotFacts(world, kind, direction)
  local facts = {}
  for _, name in ipairs(FACT_KEYS) do
    if world[name] ~= nil then
      facts[name] = world[name]
    end
  end
  if direction == "incoming" then
    facts.incomingCall = true
  end
  if kind == "rematch" then
    facts.invitation = true
  end
  local flags = world.flags
  if type(flags) == "table" and facts.savingsChoice == nil then
    local choice = (flags --[[@as table<string, unknown>]]).savingsChoice
    if choice ~= nil then
      facts.savingsChoice = choice
    end
  end
  return facts
end

---@param messages table<string, unknown>
---@return string frozen greeting reference
local function frozenGreeting(messages)
  for _, name in ipairs({ "greeting", "invitation", "program", "accept" }) do
    if type(messages[name]) == "string" then
      return messages[name] --[[@as string]]
    end
  end
  for _, value in pairs(messages) do
    if type(value) == "string" then
      return value
    end
  end
  error("phone calls need a greeting message reference before taking the lease", 0)
end

---@param contact string
local function unknownContact(contact)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "phone calls name a catalogued contact, got " .. contact,
    { contact = contact }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
end

---@param contact string
local function unacquiredContact(contact)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "phone calls open only acquired contacts, got " .. contact,
    { contact = contact }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
end

-- The closed owner behind one generated conversation family. The
-- producer stamps the family onto every compiled contact beside its
-- message bank; the runtime never guesses it from key substrings, so a
-- native key always dispatches to its own program.
local FAMILY_OWNERS = {
  mother = "mother",
  elm = "professor",
  oak = "professor",
  friend = "service",
  kurt = "service",
  daycare = "service",
  buena = "service",
  bill = "service",
  bike = "service",
  baoba = "service",
  kenji = "trainer",
  irwin = "trainer",
  gym = "trainer",
  trainer = "trainer",
  generic = "generic",
}

---@param catalog table<string, unknown>
---@param contactKey string
---@return table<string, unknown> the compiled contact record
local function findContact(catalog, contactKey)
  local contacts = catalog.contacts
  assert(type(contacts) == "table", "phone calls read the catalog contact list")
  for _, contact in
    ipairs(contacts --[[@as table<integer, unknown>]])
  do
    assert(
      type(contact) == "table" and type((contact --[[@as table<string, unknown>]]).key) == "string",
      "catalog contacts carry semantic keys"
    )
    if
      (contact --[[@as table<string, unknown>]]).key == contactKey
    then
      return contact --[[@as table<string, unknown>]]
    end
  end
  unknownContact(contactKey)
  error("unreachable", 0)
end

---@param record table<string, unknown>
---@return string ownerName, string family
local function resolveFamily(record)
  local family = record.family
  local owner = type(family) == "string" and FAMILY_OWNERS[
    family --[[@as string]]
  ] or nil
  if owner == nil then
    local failure = Errors.new(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "phone calls name a contact with a known conversation family, got " .. tostring(record.key),
      { contact = record.key }
    )
    error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
  end
  return owner, family --[[@as string]]
end

-- Opens one foreground call. Validates the contact, direction, call
-- kind, message references, and signal before taking the single call
-- lease; branch-required facts are preflighted at their stage, not
-- here. An invalid signal takes no lease and selects no program.
---@param args { id: string, contact: string, direction: string, kind: string }
---@return { id: string } typed call handle
function PhoneCall:begin(args)
  assert(type(args) == "table", "phone calls open through a request record")
  assert(type(args.id) == "string" and args.id ~= "", "phone calls carry a stable runtime id")
  assert(type(args.contact) == "string" and args.contact ~= "", "phone calls name their contact")
  assert(PhoneCall.DIRECTIONS[args.direction] == true, "phone calls name an incoming or outgoing direction")
  assert(PhoneCall.KINDS[args.kind] == true, "phone calls name a known source call kind")
  if self._active ~= nil then
    error("a foreground phone call already owns the line", 0)
  end
  if self._calls[args.id] ~= nil then
    error("a phone call id opens once", 0)
  end
  local record = findContact(self._catalog, args.contact)
  if registeredContacts(self._state)[args.contact] ~= true then
    unacquiredContact(args.contact)
  end
  local greeting = frozenGreeting(self._messages)
  local signal = self._world.signal
  local reception = self._world.reception
  local session = {
    id = args.id,
    contact = args.contact,
    direction = args.direction,
    kind = args.kind,
    greeting = greeting,
    facts = snapshotFacts(self._world, args.kind, args.direction),
    owner = nil,
    family = nil,
    program = nil,
    programSession = nil,
    stage = "connecting",
    position = 1,
    ticks = 0,
    terminal = false,
    failed = nil,
    result = nil,
    hangupDone = false,
  }
  if signal == "none" or reception == "none" then
    session.stage = "noSignal"
    session.terminal = true
    session.result = { id = args.id, contact = args.contact, kind = args.kind, signal = false, ready = false }
    self._calls[args.id] = session
    return { id = args.id }
  end
  -- A rematch kind always takes the trainer invitation path; every
  -- other kind follows the contact's generated family.
  local owner, family = "trainer", "trainer"
  if args.kind ~= "rematch" then
    owner, family = resolveFamily(record)
  end
  session.owner = owner
  session.family = family
  self._calls[args.id] = session
  self._active = args.id
  local audio = self._audio
  if type(audio) == "table" and audio.playDialing ~= nil then
    local dial = audio.playDialing --[[@as fun(self: table<string, unknown>)]]
    dial(audio)
    dial(audio)
  end
  return { id = args.id }
end

---@param handle unknown
---@return table<string, unknown> the live call session
local function checkHandle(self, handle)
  assert(
    type(handle) == "table" and type((handle --[[@as table<string, unknown>]]).id) == "string",
    "phone handles carry their runtime id"
  )
  local id = (handle --[[@as table<string, unknown>]]).id --[[@as string]]
  local session = self._calls[id]
  if session == nil then
    error("a stale phone handle never acts on a new call", 0)
  end
  return session
end

---@return boolean waiting true while the effect player has not completed
function PhoneCall:_audioWait()
  local audio = self._audio
  if type(audio) ~= "table" or audio.isEffectWaitComplete == nil then
    return false
  end
  local done = audio.isEffectWaitComplete --[[@as fun(self: table<string, unknown>): boolean]]
  return done(audio) ~= true
end

---@param session table<string, unknown>
local function enterStage(session)
  session.position = session.position --[[@as integer]] + 1
end

---@param session table<string, unknown>
function PhoneCall:_selectProgramAtGreeting(session)
  local owner = session.owner --[[@as string]]
  local facts = session.facts --[[@as table<string, unknown>]]
  if owner == "mother" then
    session.program = MotherPhoneProgram.selectName(facts)
  elseif owner == "professor" then
    if session.family == "oak" then
      session.program = ProfessorPhonePrograms.selectOak(facts)
    else
      session.program = ProfessorPhonePrograms.selectElm(facts)
    end
  elseif owner == "service" then
    session.program = ServicePhonePrograms.selectName(session.family --[[@as string]], facts)
  elseif owner == "trainer" then
    session.program = TrainerPhonePrograms.selectName(session.family --[[@as string]], facts)
  else
    session.program = GenericPhoneProgram.selectName(facts)
  end
end

---@param session table<string, unknown>
function PhoneCall:_openProgramSession(session)
  local programOwner = session.owner --[[@as string]]
  local request = {
    contact = session.contact,
    family = session.family,
    professor = session.family,
    facts = session.facts,
  }
  if programOwner == "mother" then
    session.programSession = MotherPhoneProgram.select(self._world, request)
  elseif programOwner == "professor" then
    session.programSession = ProfessorPhonePrograms.select(self._world, request)
  elseif programOwner == "service" then
    session.programSession = ServicePhonePrograms.select(self._world, request)
  elseif programOwner == "trainer" then
    session.programSession = TrainerPhonePrograms.select(self._world, request)
  else
    session.programSession = GenericPhoneProgram.select(self._world, request)
  end
end

---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string program step result
local function stepProgram(session, input)
  local owner = session.owner --[[@as string]]
  local programSession = session.programSession --[[@as table<string, unknown>]]
  if owner == "mother" then
    return MotherPhoneProgram.step(programSession, input)
  end
  if owner == "professor" then
    return ProfessorPhonePrograms.step(programSession, input)
  end
  if owner == "service" then
    return ServicePhonePrograms.step(programSession, input)
  end
  if owner == "trainer" then
    return TrainerPhonePrograms.step(programSession, input)
  end
  return GenericPhoneProgram.step(programSession, input)
end

---@param session table<string, unknown>
function PhoneCall:_finishHangup(session)
  if session.hangupDone ~= true then
    session.hangupDone = true
    local audio = self._audio
    if type(audio) == "table" and audio.playHangup ~= nil then
      local hangup = audio.playHangup --[[@as fun(self: table<string, unknown>)]]
      hangup(audio)
    end
    local count = self._hangups
    self._hangups = count + 1
  end
  if session.result == nil then
    local ready = self._world.rematchReady
    local staged = type(ready) == "table" and ready[
      session.contact --[[@as string]]
    ] == true
    session.result = {
      id = session.id,
      contact = session.contact,
      kind = session.kind,
      program = session.program,
      signal = true,
      ready = staged,
    }
  end
  session.stage = "done"
  session.terminal = true
  if self._active == session.id then
    self._active = nil
  end
end

-- Advances the call one step. Waits hold their stage until the audio or
-- text completion boundary reports done; each stage advance moves the
-- program position once and runs the stage effect once. Steps on a
-- terminal call and repeated views never duplicate an effect.
---@param handle { id: string }
---@param input table<string, unknown>? confirm, choice, advance, or cancel edges
function PhoneCall:step(handle, input)
  local session = checkHandle(self, handle)
  local edges = input or {}
  assert(type(edges) == "table", "phone calls step through an input record")
  session.ticks = session.ticks --[[@as integer]] + 1
  if session.terminal == true then
    return
  end
  if edges.cancel == true then
    enterStage(session)
    self:_finishHangup(session)
    return
  end
  local forced = edges.confirm == true or edges.advance == true
  for _ = 1, 8 do
    local stage = session.stage --[[@as string]]
    if stage == "connecting" then
      if self:_audioWait() and not forced then
        return
      end
      forced = false
      session.stage = "greeting"
      enterStage(session)
    elseif stage == "greeting" then
      if session.program == nil then
        self:_selectProgramAtGreeting(session)
        self:_openProgramSession(session)
      end
      session.stage = "program"
      enterStage(session)
    elseif stage == "program" then
      local ok, outcome = pcall(stepProgram, session, edges)
      if not ok then
        session.failed = outcome
        session.stage = "done"
        session.terminal = true
        session.result = { id = session.id, contact = session.contact, kind = session.kind, error = outcome }
        if self._active == session.id then
          self._active = nil
        end
        return
      end
      if outcome == "waiting" then
        session.stage = "choice"
        enterStage(session)
        return
      end
      session.stage = "hangingUp"
      enterStage(session)
    elseif stage == "choice" then
      if edges.choice == nil then
        return
      end
      local ok, outcome = pcall(stepProgram, session, edges)
      if not ok then
        session.failed = outcome
        session.stage = "done"
        session.terminal = true
        session.result = { id = session.id, contact = session.contact, kind = session.kind, error = outcome }
        if self._active == session.id then
          self._active = nil
        end
        return
      end
      if outcome == "waiting" then
        return
      end
      session.stage = "hangingUp"
      enterStage(session)
    elseif stage == "hangingUp" then
      self:_finishHangup(session)
      return
    else
      return
    end
  end
end

---@param stage string
---@return string public view stage
local function publicStage(stage)
  if stage == "connecting" then
    return "connecting"
  end
  if stage == "greeting" or stage == "program" then
    return "message"
  end
  if stage == "choice" then
    return "choice"
  end
  if stage == "hangingUp" then
    return "hangingUp"
  end
  if stage == "noSignal" then
    return "noSignal"
  end
  return "completed"
end

-- Borrows the detached call view: the closed stage union with the frozen
-- greeting, the selected program, the program position, and any owed
-- choice. Reads never mutate and never duplicate an effect.
---@param handle { id: string }
---@return table<string, unknown> detached view
function PhoneCall:view(handle)
  local session = checkHandle(self, handle)
  local stage = publicStage(session.stage --[[@as string]])
  local shown = {
    stage = stage,
    id = session.id,
    contact = session.contact,
    position = session.position,
    greeting = session.greeting,
    program = session.program,
  }
  if stage == "choice" then
    -- Only the savings choice waits for input today; the owed choice
    -- ids stay with the program that defines them so a new waiting
    -- program cannot silently inherit these.
    assert(session.owner == "mother", "only the savings choice waits for input")
    shown.choices = { MotherPhoneProgram.CHOICES[1], MotherPhoneProgram.CHOICES[2] }
  end
  if session.result ~= nil then
    local result = session.result --[[@as table<string, unknown>]]
    local detached = {}
    for key, value in pairs(result) do
      detached[key] = value
    end
    shown.result = detached
  end
  return shown
end

-- Reports the terminal result once the call has completed, hung up, or
-- failed; nil while the call is still live. Never touches a new call.
---@param handle { id: string }
---@return table<string, unknown>? terminal result
function PhoneCall:result(handle)
  local session = checkHandle(self, handle)
  if session.result == nil then
    return nil
  end
  local result = session.result --[[@as table<string, unknown>]]
  local detached = {}
  for key, value in pairs(result) do
    detached[key] = value
  end
  return detached
end

-- Hangs the call up. A live call plays the hangup tone and completes
-- with its staged result; a terminal call keeps its committed effects
-- and result untouched.
---@param handle { id: string }
---@param reason string hangup reason
function PhoneCall:cancel(handle, reason)
  local session = checkHandle(self, handle)
  assert(type(reason) == "string" and reason ~= "", "phone cancellation names its reason")
  if session.terminal == true then
    if session.hangupDone ~= true and session.stage ~= "noSignal" then
      local audio = self._audio
      if type(audio) == "table" and audio.playHangup ~= nil then
        local hangup = audio.playHangup --[[@as fun(self: table<string, unknown>)]]
        hangup(audio)
      end
      session.hangupDone = true
      local count = self._hangups
      self._hangups = count + 1
    end
    return
  end
  enterStage(session)
  self:_finishHangup(session)
end

-- Releases a call handle. Terminal handles leave their effects in
-- place; a live handle hangs up first through the same no-rollback
-- path as cancel.
---@param handle { id: string }
function PhoneCall:release(handle)
  local session = checkHandle(self, handle)
  if session.terminal ~= true then
    enterStage(session)
    self:_finishHangup(session)
  end
  self._calls[
    session.id --[[@as string]]
  ] = nil
end

-- The single field readiness query for a contact: ready only when an
-- invitation was staged and the source window holds.
---@param contact string
---@return { ready: boolean, tier: integer }
function PhoneCall:queryRematch(contact)
  return TrainerPhonePrograms.query(contact, self._world, self._catalog)
end

-- Projects the map marker for a contact at the queried tier.
---@param contact string
---@return { tier: integer, ready: boolean }
function PhoneCall:rematchMarker(contact)
  return TrainerPhonePrograms.marker(contact, self._world, self._catalog)
end

-- Launches the accepted rematch at the queried tier.
---@param contact string
---@param world table<string, unknown>? tier team owner, defaulting to the borrowed world
---@return { tier: integer, team: table<string, unknown> }
function PhoneCall:launchRematch(contact, world)
  local teams = world or self._world
  assert(type(teams) == "table", "rematch launches read their tier teams")
  if teams ~= self._world then
    local merged = {}
    for key, value in pairs(self._world) do
      merged[key] = value
    end
    for key, value in
      pairs(teams --[[@as table<string, unknown>]])
    do
      merged[key] = value
    end
    return TrainerPhonePrograms.launch(contact, merged, self._catalog)
  end
  return TrainerPhonePrograms.launch(contact, self._world, self._catalog)
end

-- Resolves the launched rematch at its source boundary.
---@param contact string
---@param outcome string source resolution outcome
---@return { contact: string, outcome: string, ready: boolean }
function PhoneCall:resolveRematch(contact, outcome)
  return TrainerPhonePrograms.resolve(contact, self._world, outcome)
end

return PhoneCall
