-- Foreground phone session owner: at most one live call with a stable
-- runtime id and a monotonically advancing program position. Connection
-- tones, frozen greeting selection, program dispatch, choices, and
-- hangup are separate stages; each source effect runs once when its
-- original stage is entered, never per poll and never as a blanket
-- commit at hangup. Dialing plays the source dial tone twice and waits
-- on the effect-player completion boundary; hangup plays PHONE_OFF
-- once and then prints three localized messages across staged timer
-- waits. Views are detached closed
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

-- Source call tones: the connecting stage dials PHONE0 twice and waits
-- on that sequence; the staged hangup plays PHONE_OFF once behind its
-- three localized lines. The generic audio boundary
-- resolves them by symbol exactly like every other effect;
-- bespoke playDialing/playHangup fakes keep working where the generic
-- play entry is absent, and toneless fakes stay silent.
PhoneCall.DIAL_SEQUENCE = "SEQ_SE_GS_PHONE0"
-- The two source dial notices (bank271 entries 30 and 31) printed in the
-- speech window beside each PHONE0 tone of PhoneCall_InitialRing.
PhoneCall.DIAL_MESSAGE_ENTRIES = { 30, 31 }
PhoneCall.HANGUP_SEQUENCE = "SEQ_SE_GS_PHONE_OFF"
-- The three staged hangup messages, read through the shared UI message
-- reader: the first prints on hangup entry, the other two each follow
-- an eleven-tick post-increment wait, and a third wait ends the call.
PhoneCall.HANGUP_MESSAGE_ENTRIES = { 33, 34, 35 }
-- The button-press tone behind the pre-hangup wait, played once for
-- either source confirmation: Action/tap or the cancel press.
PhoneCall.SELECT_SEQUENCE = "SEQ_SE_DP_SELECT"

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
  "timeOfDay",
  "mapId",
  "playerGender",
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
  "kenjiWaitDays",
  "waitExpired",
  "kurtFlag127",
  "kurtMaking",
  "oakJohtoAcked",
  "flypoint25",
  "unlockLevel",
  "scriptedCall",
  "momBalance",
  "momGiftFull",
  "momCallIntroParam",
  "momSavingsFlag",
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
---@param record table<string, unknown>?
---@return table<string, unknown> frozen dispatch facts
local function snapshotFacts(world, kind, direction, record)
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
  local readFacts = world.callFacts
  if type(record) == "table" and type(readFacts) == "function" then
    local live = readFacts(world, record)
    assert(type(live) == "table", "phone calls read current source facts as one record")
    for name, value in pairs(live) do
      facts[name] = value
    end
  end
  local reader = world.read
  if type(record) == "table" and record.family == "mother" and type(reader) == "function" then
    facts.savingsChoice = reader(world, "mom.savings-choice")
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
-- kind, and message references before taking the single call lease;
-- branch-required facts are preflighted at their stage, not here. A
-- map without signal opens the no-signal flow instead of the
-- conversation, exactly like the source out-of-area states. Scripted
-- field calls thread their source isScriptedCall/callScriptID through
-- the request so the native selector sees scriptedCall==2 first,
-- before localMap (retail order).
---@param args { id: string, contact: string, direction: string, kind: string, isScriptedCall: integer?, callScriptID: integer? }
---@return { id: string } typed call handle
function PhoneCall:begin(args)
  assert(type(args) == "table", "phone calls open through a request record")
  assert(type(args.id) == "string" and args.id ~= "", "phone calls carry a stable runtime id")
  assert(type(args.contact) == "string" and args.contact ~= "", "phone calls name their contact")
  assert(PhoneCall.DIRECTIONS[args.direction] == true, "phone calls name an incoming or outgoing direction")
  assert(PhoneCall.KINDS[args.kind] == true, "phone calls name a known source call kind")
  if args.isScriptedCall ~= nil then
    assert(
      type(args.isScriptedCall) == "number" and args.isScriptedCall % 1 == 0,
      "scripted phone calls carry their source scripted flag"
    )
  end
  if args.callScriptID ~= nil then
    assert(
      type(args.callScriptID) == "number" and args.callScriptID % 1 == 0,
      "scripted phone calls carry their source script identity"
    )
  end
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
  local facts = snapshotFacts(self._world, args.kind, args.direction, record)
  if args.isScriptedCall ~= nil then
    facts.scriptedCall = args.isScriptedCall
  end
  if args.callScriptID ~= nil then
    facts.callScriptID = args.callScriptID
    -- Trigger and scripted launches carry the source predefined script
    -- identity the native selector reads for incoming calls.
    facts.predefinedScript = args.callScriptID
  end
  -- Mom balance and gift-full read through the durable companion state,
  -- never the world facade: the balance stages the save-prompt variant
  -- and the gift queue gates the gift-full branch.
  if record.family == "mother" then
    local okPhone, phone = pcall(function()
      local readPhone = (self._state --[[@as table<string, unknown>]]).readPhone
      assert(type(readPhone) == "function", "mother facts read the companion phone")
      return readPhone(self._state)
    end)
    if okPhone and type(phone) == "table" then
      local mom = (phone --[[@as table<string, unknown>]]).mom
      if type(mom) == "table" then
        if
          type((mom --[[@as table<string, unknown>]]).balance) == "number"
        then
          facts.momBalance = (mom --[[@as table<string, unknown>]]).balance
        end
        local gifts = (mom --[[@as table<string, unknown>]]).gifts
        if type(gifts) == "table" then
          facts.momGiftFull = #gifts >= 5
        end
      end
    end
  end
  local session = {
    id = args.id,
    contact = args.contact,
    direction = args.direction,
    kind = args.kind,
    world = self._world,
    catalog = self._catalog,
    record = record,
    greeting = greeting,
    facts = facts,
    isScriptedCall = args.isScriptedCall or 0,
    callScriptID = args.callScriptID,
    dynamicMother = false,
    random = self._random,
    owner = nil,
    family = nil,
    program = nil,
    programSession = nil,
    scriptId = nil,
    lines = nil,
    textPage = 1,
    textRevealed = 0,
    textTick = 0,
    stage = "connecting",
    position = 1,
    ticks = 0,
    terminal = false,
    failed = nil,
    result = nil,
    hangupDone = false,
  }
  -- A rematch kind always takes the trainer invitation path; every
  -- other kind follows the contact's generated family.
  local owner, family = "trainer", "trainer"
  if args.kind ~= "rematch" then
    owner, family = resolveFamily(record)
  end
  session.owner = owner
  session.family = family
  -- Outgoing calls dial twice behind the connecting wait, exactly like
  -- the source InitialRing; incoming calls start at the conversation
  -- (mainState 1) and never dial. A map without signal opens the
  -- no-signal flow instead of either stage.
  local signaled = true
  local phoneSignal = self._world.phoneSignal
  if type(phoneSignal) == "function" then
    signaled = phoneSignal(self._world, args.direction) == true
  end
  if not signaled then
    session.stage = "noSignal"
    session.noSignalSub = 0
    session.noSignalTimer = 0
    session.noSignalArmed = true
    session.lines = { self:_uiText(30) }
    session.textPage = 1
    self._calls[args.id] = session
    self._active = args.id
    return { id = args.id }
  end
  if args.direction ~= "incoming" then
    session.stage = "connecting"
    session.dialSub = 0
    self._calls[args.id] = session
    self._active = args.id
    self:_dialStep(session)
    return { id = args.id }
  end
  session.stage = "greeting"
  self._calls[args.id] = session
  self._active = args.id
  return { id = args.id }
end

-- Plays one source dial step: PhoneCall_InitialRing stage 0 opens the
-- window with the first dial notice beside its tone, and stage 1 plays
-- again with the second notice once that tone has finished.
---@param session table<string, unknown>
function PhoneCall:_dialStep(session)
  local sub = session.dialSub --[[@as integer]]
  assert(sub == 0 or sub == 1, "the source dial has two tone steps")
  session.lines = { self:_uiText(PhoneCall.DIAL_MESSAGE_ENTRIES[sub + 1]) }
  session.textPage = 1
  local audio = self._audio
  if type(audio) == "table" and audio.playDialing ~= nil then
    local dial = audio.playDialing --[[@as fun(self: table<string, unknown>)]]
    dial(audio)
  elseif type(audio) == "table" and type(audio.play) == "function" then
    local play = audio.play --[[@as fun(self: table<string, unknown>, sequence: string)]]
    play(audio, PhoneCall.DIAL_SEQUENCE)
  end
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
  local done = audio.isEffectWaitComplete --[[@as fun(self: table<string, unknown>, sequence: string): boolean]]
  return done(audio, PhoneCall.DIAL_SEQUENCE) ~= true
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

-- Native generic header gate types in GenericPhoneCallType order:
-- nil, random, rematch-until-tower, rematch window, contest days,
-- takeover, random, rematch outside contest, gift outside contest, and
-- the terminator. The runtime resolves outgoing and incoming tables
-- through the same gates as GearPhoneCall_GetScriptId_Generic.
PhoneCall.GENERIC_GATE = {
  NIL = 0,
  RANDOM = 1,
  REMATCH = 2,
  WINDOW = 3,
  CONTEST_DAYS = 4,
  TAKEOVER = 5,
  RANDOM6 = 6,
  REMATCH_NO_CONTEST = 7,
  GIFT_NO_CONTEST = 8,
  NONE = 255,
}

-- The National Park map identity behind the bug-contest call exclusion.
PhoneCall.NATIONAL_PARK_MAP = 96

-- Replicates the source percent-chance roll: two source draws folded
-- exactly like PhoneScript_Generic_RandomChance.
---@param chance integer percent chance 0..100
---@return boolean passed
function PhoneCall:_rollPercentChance(chance)
  local first, second
  local random = self._random
  if type(random) == "table" and type(random.mt) == "function" then
    first = random:mt("generic-gate")
    second = random:mt("generic-gate")
  else
    first = math.random(0, 4294967295)
    second = math.random(0, 4294967295)
  end
  local combined = bit.bxor(first, second)
  if combined < 0 then
    combined = combined + 4294967296
  end
  local folded = bit.bxor(combined % 65536, math.floor(combined / 256)) % 100
  return folded <= chance
end

-- Draws a retail LCRandom-bounded pick: the Elm Everstone and
-- Pokerus rolls and the dynamic Buena, friend, and gym draws.
-- Mirrors the Bill advice draw with its headless fallback.
---@param count integer exclusive upper bound
---@param stream string labelled draw stream
---@return integer bounded pick
function PhoneCall:_drawBounded(count, stream)
  assert(type(count) == "number" and count > 0, "selectors bound their draws")
  local random = self._random
  if type(random) == "table" and type(random.lc) == "function" then
    return random:lc(stream) % count
  end
  return math.random(0, count - 1)
end

-- Reads Kenji's staged seeking invitation behind the native selector:
-- a durable rematch record with a positive stage, exactly like the
-- trainer readiness query. Worlds without the query stage nothing.
---@param session table<string, unknown>
---@return boolean seeking
function PhoneCall:_kenjiSeeking(session)
  local world = session.world --[[@as table<string, unknown>]]
  local query = world.queryRematch
  assert(type(query) == "function", "kenji selection reads the staged rematch record")
  local contact = session.contact --[[@as string]]
  local current = query(world, contact)
  return type(current) == "table" and (current --[[@as table<string, unknown>]]).stage > 0
end

-- Stages the Kenji errand side effect behind script 89/90, mirroring
-- the source SetActiveFlag plus SetSeeking writes: the durable active
-- flag flips on while the seeking invitation stages with its
-- accumulated wins preserved, exactly like the static rematch kind.
---@param session table<string, unknown>
function PhoneCall:_stageKenjiErrand(session)
  local world = session.world --[[@as table<string, unknown>]]
  local contact = session.contact --[[@as string]]
  local setRematch = world.setRematch
  assert(type(setRematch) == "function", "kenji errands stage their seeking invitation through durable state")
  local query = world.queryRematch
  local wins = 0
  if type(query) == "function" then
    local current = query(world, contact)
    if type(current) == "table" and type(current.wins) == "number" then
      wins = current.wins --[[@as integer]]
    end
  end
  setRematch(world, contact, { stage = 1, wins = wins })
  local setActive = world.setKenjiActive
  assert(type(setActive) == "function", "kenji errands record their active flag through durable state")
  setActive(world, true)
end

-- Evaluates one generic header gate for the session. Weekday, time,
-- tower, takeover, and contest facts ride the frozen selection facts;
-- seeking and the staged gift read the live companion owners, exactly
-- like their source checks.
---@param session table<string, unknown>
---@param row table<integer, integer> {gate, chance, scriptType, scriptID}
---@param defKind string? script definition kind behind rematch staging
---@return boolean passed
function PhoneCall:_genericGatePasses(session, row, defKind)
  local gate, chance = row[1], row[2]
  if gate == PhoneCall.GENERIC_GATE.RANDOM or gate == PhoneCall.GENERIC_GATE.RANDOM6 then
    return self:_rollPercentChance(chance)
  end
  local facts = session.facts --[[@as table<string, unknown>]]
  if gate == PhoneCall.GENERIC_GATE.CONTEST_DAYS then
    local weekday = facts.weekday
    if weekday ~= 2 and weekday ~= 4 and weekday ~= 6 then
      return false
    end
    return self:_rollPercentChance(chance)
  end
  if gate == PhoneCall.GENERIC_GATE.TAKEOVER then
    if facts.takeover ~= true then
      return false
    end
    return self:_rollPercentChance(chance)
  end
  local world = session.world --[[@as table<string, unknown>]]
  local query = world.queryRematch
  assert(type(query) == "function", "generic rematch gates read durable companion state")
  local stored = query(world, session.contact --[[@as string]])
  local seeking = type(stored) == "table"
    and (stored --[[@as table<string, unknown>]]).stage ~= nil
    and (stored --[[@as table<string, unknown>]]).stage --[[@as integer]]
      > 0
  local gifted = false
  local readPhone = (self._state --[[@as table<string, unknown>]]).readPhone
  assert(type(readPhone) == "function", "generic gift gates read the companion phone")
  local phone = readPhone(self._state)
  if type(phone) == "table" then
    local contacts = (phone --[[@as table<string, unknown>]]).contacts
    if type(contacts) == "table" then
      local entry = (contacts --[[@as table<string, unknown>]])[
        session.contact --[[@as string]]
      ]
      gifted = type(entry) == "table" and (entry --[[@as table<string, unknown>]]).reward ~= nil
    end
  end
  if gate == PhoneCall.GENERIC_GATE.REMATCH then
    if seeking or gifted then
      return false
    end
    if facts.towerCleared ~= true and row[3] == 0 and defKind == "rematch" then
      return false
    end
    return self:_rollPercentChance(chance)
  end
  if gate == PhoneCall.GENERIC_GATE.WINDOW then
    if facts.towerCleared ~= true then
      return false
    end
    local record = session.record --[[@as table<string, unknown>]]
    if facts.weekday ~= record.rematchWeekday or facts.timeOfDay ~= record.rematchTimeOfDay then
      return false
    end
    return self:_rollPercentChance(chance)
  end
  if gate == PhoneCall.GENERIC_GATE.REMATCH_NO_CONTEST then
    if facts.towerCleared ~= true then
      return false
    end
    local record = session.record --[[@as table<string, unknown>]]
    if record.mapId == PhoneCall.NATIONAL_PARK_MAP and facts.bugContest == true then
      return false
    end
    if not seeking then
      return false
    end
    return self:_rollPercentChance(chance)
  end
  if gate == PhoneCall.GENERIC_GATE.GIFT_NO_CONTEST then
    local record = session.record --[[@as table<string, unknown>]]
    if record.mapId == PhoneCall.NATIONAL_PARK_MAP and facts.bugContest == true then
      return false
    end
    if not gifted then
      return false
    end
    return self:_rollPercentChance(chance)
  end
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "generic calls name a known source header gate, got " .. tostring(gate),
    { contact = session.contact }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
end

-- Draws the generic chatter species pair behind script types 1 and 2:
-- the caller's own party mon and the map encounter slot, exactly like
-- the Generic handler buffers species 10 and 11. The keys publish
-- through the world species buffer the text resolver reads.
---@param session table<string, unknown>
function PhoneCall:_drawGenericSpecies(session)
  local record = session.record --[[@as table<string, unknown>]]
  local world = session.world --[[@as table<string, unknown>]]
  local trainerId = record.trainerId
  assert(type(trainerId) == "number", "generic chatter reads the caller trainer number")
  local mapId = record.mapId
  assert(type(mapId) == "number", "generic chatter reads the caller map")
  local trainerClass = record.trainerClass
  assert(type(trainerClass) == "number", "generic chatter reads the caller class")
  local facts = session.facts --[[@as table<string, unknown>]]
  local timeOfDay = facts.timeOfDay
  assert(timeOfDay == 0 or timeOfDay == 1 or timeOfDay == 2, "generic chatter reads the call time band")
  local partyFor = world.trainerPartySpecies
  assert(type(partyFor) == "function", "generic chatter reads trainer parties through the world")
  local party = partyFor(world, trainerId)
  assert(type(party) == "table" and #party > 0, "trainer parties carry species for phone chatter")
  local slotsFor = world.encounterSpecies
  assert(type(slotsFor) == "function", "generic chatter reads encounter slots through the world")
  local band = timeOfDay == 0 and "morning" or (timeOfDay == 1 and "day" or "night")
  local slots = slotsFor(world, mapId, band, trainerClass)
  assert(type(slots) == "table" and #slots > 0, "encounter tables carry slots for phone chatter")
  local random = self._random
  local pickA, pickB
  if type(random) == "table" and type(random.lc) == "function" then
    pickA = random:lc("generic-species") % #party
    pickB = random:lc("generic-species") % #slots
  else
    pickA = math.random(0, #party - 1)
    pickB = math.random(0, #slots - 1)
  end
  local buffer = self._messages.speciesStaging
  if type(buffer) ~= "table" then
    buffer = {}
    self._messages.speciesStaging = buffer
  end
  assert(type(buffer) == "table", "generic chatter publishes its species buffer");
  (buffer --[[@as table<string, unknown>]])[
    session.contact --[[@as string]]
  ] = {
    a = party[pickA + 1],
    b = slots[pickB + 1],
  }
end

-- Resolves one generic header table in source order: the first passing
-- gate wins with its script; a nil/none terminator stops the scan and
-- reports the empty script; falling off the end reports the last
-- examined row, exactly like PhoneScriptGeneric_GetScriptIdInternal.
-- Script types 1 and 2 draw the chatter species pair first.
---@param session table<string, unknown>
---@param rows table<integer, table<integer, integer>> eight header rows
function PhoneCall:_resolveGenericHeaders(session, rows)
  local definitions = (self._catalog --[[@as table<string, unknown>]]).callDefinitions
  local lastType, lastID = 0, 0
  for _, row in ipairs(rows) do
    local gate = row[1]
    if gate == PhoneCall.GENERIC_GATE.NONE or gate == PhoneCall.GENERIC_GATE.NIL then
      session.scriptId = 0
      session.scriptType = 0
      return
    end
    lastType, lastID = row[3], row[4]
    local definition = type(definitions) == "table" and definitions[lastID] or nil
    local kind = type(definition) == "table" and (definition --[[@as table<string, unknown>]]).kind or nil
    if
      self:_genericGatePasses(session, row, kind --[[@as string?]])
    then
      session.scriptId = lastID
      session.scriptType = lastType
      if lastType == 1 or lastType == 2 then
        self:_drawGenericSpecies(session)
      end
      return
    end
  end
  session.scriptId = lastID
  session.scriptType = lastType
  if lastType == 1 or lastType == 2 then
    self:_drawGenericSpecies(session)
  end
end

---@param session table<string, unknown>
---@param record table<string, unknown>
local function selectNativeScript(self, session, record)
  local facts = session.facts --[[@as table<string, unknown>]]
  local world = session.world --[[@as table<string, unknown>]]
  local readFacts = world.nativeSelectorFacts
  assert(type(readFacts) == "function", "native script selection reads source selector facts")
  local nativeFacts = readFacts(world, record)
  assert(type(nativeFacts) == "table", "native selector returns a fact record")
  local scripted = session.isScriptedCall == 2 and 2 or (facts.scriptedCall == 2 and 2 or 0)
  if session.family == "mother" then
    -- Source order: the scripted dynamic path precedes everything,
    -- then the local-map greeting, the incoming predefined script,
    -- then the early-rival greetings in flag order. A fall-through
    -- reaches the dynamic savings offer (scriptType 4, no scriptId).
    -- The scripted branch also marks the after-naming conversation as
    -- held, so the later early-rival greeting never repeats.
    if scripted == 2 then
      local setFlag = world.setFlag
      assert(type(setFlag) == "function", "the scripted mother branch writes its source flag")
      setFlag(world, "FLAG_TALKED_TO_MOM_AFTER_NAMING_RIVAL")
      facts.talkedAfterNamingRival = true
      session.dynamicMother = true
      facts.dynamicMother = true
    elseif nativeFacts.localMap then
      session.scriptId = 23
    elseif session.direction == "incoming" then
      session.scriptId = facts.predefinedScript
    elseif not nativeFacts.gaveRivalName then
      session.scriptId = 25
    elseif not nativeFacts.talkedAfterNamingRival then
      session.scriptId = 26
    else
      session.dynamicMother = true
      facts.dynamicMother = true
    end
  elseif session.family == "bill" then
    if session.direction == "incoming" then
      session.scriptId = 93
    elseif nativeFacts.localMap then
      session.scriptId = 92
    else
      session.dynamicBill = true
    end
  elseif session.family == "bike" then
    session.scriptId = nativeFacts.localMap and 84 or 85
  elseif session.family == "kurt" then
    if nativeFacts.localMap then
      session.scriptId = 83
    else
      session.dynamicKurt = true
    end
  elseif session.family == "daycare" then
    if record.id == 6 and session.direction == "incoming" then
      session.scriptId = nativeFacts.eggCallPending and 96 or 95
    elseif record.id == 7 and nativeFacts.localMap then
      session.scriptId = 97
    elseif record.id == 6 then
      session.dynamicDaycareMan = true
    else
      session.dynamicDaycareLady = true
    end
  elseif session.family == "elm" then
    if scripted == 2 then
      local mapScripts = { [0] = 2, [1] = 3, [2] = 4, [3] = 5, [4] = 6 }
      local predefined = facts.callScriptID or facts.predefinedScript
      if type(predefined) == "number" and mapScripts[predefined] ~= nil then
        session.scriptId = mapScripts[predefined]
      elseif predefined == nil then
        session.scriptId = 2
      end
    elseif session.direction == "incoming" then
      session.scriptId = facts.predefinedScript
    elseif nativeFacts.localMap then
      session.scriptId = 1
    elseif facts.panicCall == true then
      session.scriptId = 8
    elseif nativeFacts.gaveRivalName == false then
      session.scriptId = 9
    elseif facts.eggEvent == true then
      session.scriptId = 10
    elseif facts.eggGift == true then
      session.scriptId = 11
    else
      -- Source order below the gift state: the badge chain with the
      -- Everstone roll, the takeover, the badge gate, the clear and
      -- ticket gates, the late egg fallback, then the Pokerus roll.
      -- Retail counts badges from the player profile; a missing count
      -- reads as zero exactly like a fresh profile.
      local badges = facts.badges or 0
      assert(type(badges) == "number", "elm selection counts profile badges")
      local hatched = facts.eggHatched == true
      local everstone = facts.everstone == true
      if badges < 7 then
        if not hatched then
          session.scriptId = 12
        elseif everstone then
          session.scriptId = 14 + self:_drawBounded(2, "elm-everstone")
        else
          session.scriptId = 13
        end
      elseif facts.takeover == true then
        session.scriptId = 16
      elseif badges < 8 then
        session.scriptId = 17
      elseif facts.gameClear ~= true then
        session.scriptId = 18
      elseif facts.ssTicket ~= true then
        session.scriptId = 19
      elseif not everstone then
        session.scriptId = hatched and 13 or 12
      elseif facts.pokerus == true then
        session.scriptId = 20 + self:_drawBounded(3, "elm-pokerus")
      else
        session.scriptId = 20 + self:_drawBounded(2, "elm-pokerus")
      end
    end
  elseif session.family == "oak" then
    if scripted == 2 then
      session.scriptId = 82
    elseif session.direction == "incoming" then
      local caught = facts.dexCaught
      local param = 1
      if type(caught) == "number" then
        param = math.floor(caught / 50)
        if param < 1 then
          param = 1
        elseif param > 9 then
          param = 9
        end
      end
      session.scriptId = 68 + param
    elseif nativeFacts.localMap then
      session.scriptId = 68
    elseif facts.acknowledged == true then
      session.scriptId = 81
    elseif facts.nationalDex ~= true and facts.oakJohtoAcked == true then
      -- Retail sends only the johto-acked trainer without the
      -- national dex to the static 80; national dex owners fall
      -- through to the dynamic handler with menus 4 and 5.
      session.scriptId = 80
    else
      session.dynamicOak = true
    end
  elseif session.family == "baoba" then
    if scripted == 2 then
      session.scriptId = 141
    elseif nativeFacts.localMap then
      session.scriptId = 140
    elseif session.direction == "incoming" then
      -- Source scriptType 15: an incoming call without a predefined
      -- script prints the safari arrangement dynamically. Numbered
      -- trigger scripts resolve statically with the selector side
      -- effects; anything outside 142..146 falls back to 154.
      if type(facts.predefinedScript) ~= "number" then
        session.dynamicBaobaArrangement = true
      elseif facts.predefinedScript >= 142 and facts.predefinedScript <= 146 then
        local applyTrigger = world.applyBaobaTrigger
        assert(
          type(applyTrigger) == "function",
          "baoba triggers stage their selector side effects through the borrowed world"
        )
        applyTrigger(world, facts.predefinedScript)
        session.scriptId = facts.predefinedScript
      else
        session.scriptId = 154
      end
    else
      -- Retail always returns Var4057 plus the base script: a missing
      -- var reads as zero exactly like the source zero-init.
      local safariVar = facts.safariTest or 0
      assert(type(safariVar) == "number", "baoba selection reads the numeric safari var")
      session.scriptId = 147 + safariVar
    end
  elseif session.family == "kenji" then
    if nativeFacts.localMap then
      session.scriptId = 86
    else
      -- Source order past the local map: wait days split first, then
      -- an active errand without a staged invitation, then the
      -- evening split. Retail zero-inits the persistent wait and
      -- active flag, so missing facts read as zero and false.
      local waitDays = facts.kenjiWaitDays or 0
      assert(type(waitDays) == "number" and waitDays % 1 == 0, "kenji selection reads integral wait days")
      if waitDays > 1 then
        session.scriptId = 87
      elseif waitDays == 1 then
        session.scriptId = 88
      elseif facts.kenjiActive == true and not self:_kenjiSeeking(session) then
        session.scriptId = 87
      elseif facts.timeOfDay == 2 then
        session.scriptId = 91
      else
        session.scriptId = facts.timeOfDay == 1 and 90 or 89
        self:_stageKenjiErrand(session)
      end
    end
  elseif session.family == "irwin" then
    if session.direction ~= "incoming" then
      if facts.takeover == true then
        session.scriptId = 156
      else
        -- Retail rolls 172/173/174 (LCRandom()%3) for ordinary outgoing
        -- Irwin calls outside the takeover.
        local roll = 0
        local rng = session.random
        if type(rng) == "table" and type(rng.lc) == "function" then
          roll = rng:lc("irwin_outgoing") % 3
        else
          roll = math.random(0, 2)
        end
        session.scriptId = 172 + roll
      end
    elseif facts.storyEvent == true then
      session.scriptId = facts.predefinedScript
    elseif facts.acknowledged ~= true then
      session.scriptId = 169
    elseif (facts.badges or 0) >= 16 then
      session.scriptId = 171
    else
      session.scriptId = 170
    end
  elseif session.family == "gym" or session.family == "rematch" then
    if nativeFacts.localMap and record.phoneScriptIfLocal ~= nil then
      -- A same-map gym call skips the script table and prints the
      -- caller's bank entry one directly, with no side effect.
      session.localBankEntry = 1
    elseif session.direction == "incoming" then
      session.dynamicGymIncoming = true
    else
      -- Same-map gym calls skip the script table above; every other
      -- outgoing gym call runs the dynamic outgoing handler, never
      -- the fixture generic path.
      session.dynamicGymOutgoing = true
    end
  elseif session.family == "trainer" or session.family == "generic" then
    if session.direction ~= "incoming" and nativeFacts.localMap and record.phoneScriptIfLocal ~= nil then
      session.scriptId = record.phoneScriptIfLocal
    else
      local headers = record.genericHeaders
      if type(headers) ~= "table" then
        -- Fixture contacts without compiled header tables keep the
        -- historical predefined-script incoming path; anything else is
        -- an unimplemented dynamic branch.
        if session.direction == "incoming" and facts.predefinedScript ~= nil then
          session.scriptId = facts.predefinedScript
        else
          session.dynamicGeneric = true
        end
      else
        local rows = session.direction == "incoming" and headers.incoming or headers.outgoing
        assert(type(rows) == "table", "generic header tables carry both directions")
        self:_resolveGenericHeaders(session, rows)
      end
    end
  elseif session.family == "friend" then
    if session.direction == "incoming" then
      session.dynamicFriendIncoming = true
    elseif nativeFacts.localMap then
      local gender = facts.playerGender
      session.scriptId = (gender == "female" or gender == 1) and 101 or 102
    else
      session.dynamicFriend = true
    end
  elseif session.family == "buena" then
    if facts.takeover == true then
      session.scriptId = 99
    elseif session.direction == "incoming" then
      session.dynamicBuenaIncoming = true
    elseif facts.passwordKnown == true then
      session.scriptId = 100
    elseif nativeFacts.localMap then
      session.scriptId = 98
    else
      session.dynamicBuena = true
    end
  elseif session.family == "generic" then
    if session.direction ~= "incoming" and nativeFacts.localMap and record.phoneScriptIfLocal ~= nil then
      session.scriptId = record.phoneScriptIfLocal
    else
      local headers = record.genericHeaders
      if type(headers) ~= "table" then
        if session.direction == "incoming" and facts.predefinedScript ~= nil then
          session.scriptId = facts.predefinedScript
        else
          session.dynamicGeneric = true
        end
      else
        local rows = session.direction == "incoming" and headers.incoming or headers.outgoing
        assert(type(rows) == "table", "generic header tables carry both directions")
        self:_resolveGenericHeaders(session, rows)
      end
    end
  end
  if session.dynamicMother == true then
    return
  end
  if session.localBankEntry ~= nil then
    return
  end
  if
    session.dynamicBill == true
    or session.dynamicKurt == true
    or session.dynamicDaycareMan == true
    or session.dynamicDaycareLady == true
    or session.dynamicOak == true
    or session.dynamicGeneric == true
    or session.dynamicGymIncoming == true
    or session.dynamicGymOutgoing == true
    or session.dynamicFriendIncoming == true
    or session.dynamicFriend == true
    or session.dynamicBuenaIncoming == true
    or session.dynamicBuena == true
    or session.dynamicBaobaArrangement == true
  then
    return
  end
  if type(session.scriptId) ~= "number" then
    local failure = Errors.new(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "native phone selector needs an unmodeled source branch for " .. tostring(session.family),
      { family = session.family, contact = session.contact, program = session.program }
    )
    error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
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
---@return string|{ status: string, entry: integer?, entries: integer[]?, fanfare: string? } program step result
local function stepProgram(session, input)
  local owner = session.owner --[[@as string]]
  local programSession = session.programSession --[[@as table<string, unknown>]]
  if owner == "mother" then
    return MotherPhoneProgram.step(programSession, input) --[[@as string|{ status: string, entry: integer?, entries: integer[]?, fanfare: string? }]]
  end
  if owner == "professor" then
    return ProfessorPhonePrograms.step(programSession, input) --[[@as string|{ status: string, entry: integer?, entries: integer[]?, fanfare: string? }]]
  end
  if owner == "service" then
    return ServicePhonePrograms.step(programSession, input) --[[@as string|{ status: string, entry: integer?, entries: integer[]?, fanfare: string? }]]
  end
  if owner == "trainer" then
    return TrainerPhonePrograms.step(programSession, input) --[[@as string|{ status: string, entry: integer?, entries: integer[]?, fanfare: string? }]]
  end
  return GenericPhoneProgram.step(programSession, input) --[[@as string|{ status: string, entry: integer?, entries: integer[]?, fanfare: string? }]]
end

-- Resolves one bank-664 entry for the dynamic Mother flow through the
-- contact-entry reader when present, else through the script table when
-- the entry coincides with a static definition. Tests stub the reader;
-- production resolves through the field message provider with the same
-- landmark fallback (id 0 → bank 280 entry 2) as static greetings.
---@param messages table<string, unknown>
---@param session table<string, unknown>
---@param entry integer bank-664 entry number
---@return table<string, unknown> resolved native dialogue
local function resolveMotherEntry(messages, session, entry)
  local resolveEntry = messages.resolveContactEntry
  if type(resolveEntry) == "function" then
    local facts = session.facts --[[@as table<string, unknown>]]
    local balance = facts.momBalance
    if type(balance) ~= "number" then
      balance = 0
    end
    return resolveEntry(messages, session.contact, entry, { balance = balance })
  end
  local resolveLine = messages.resolveLine
  assert(type(resolveLine) == "function", "phone dialogue resolves through the field message provider")
  -- Fallback for fixtures that only stub resolveLine: map the dynamic
  -- entries onto their closest static definitions is forbidden (producer
  -- work); fail loudly so the missing reader is added instead.
  error("dynamic mother needs its contact-entry message reader, got entry " .. tostring(entry), 0)
end

-- Resolves the dynamic Bill conversation behind GearPhoneCall_Bill:
-- the gendered intro (665.3/4), the box status (665.9 when full,
-- else 665.5/6/7), and the closer 665.8. The box name and free count
-- stage through the entry options for the slot-10/11 substitutions,
-- mirroring the source BufferString/BufferIntegerAsString case. The
-- shared time-of-day greeting prints ahead of these entries through
-- the normal greeting path. An absent pc owner fails with attribution
-- instead of an invented box.
---@param self table<string, unknown>
---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown> resolved native dialogue
local function resolveBillDialogue(self, messages, session)
  local world = session.world --[[@as table<string, unknown>]]
  assert(type(world) == "table", "bill dialogue borrows its world")
  local pc = (world --[[@as table<string, unknown>]]).pc
  if type(pc) ~= "table" then
    local failure =
      Errors.new(ScriptErrors.FEATURE_UNAVAILABLE, "phone bill branch needs its missing pc owner", { domain = "pc" })
    error({ code = failure.code, message = failure.message, context = failure.context, domain = "pc" })
  end
  local box = pc --[[@as table<string, unknown>]]
  local freeSlots = box.freeSlots
  assert(type(freeSlots) == "number" and freeSlots % 1 == 0, "bill dialogue reads the free box count")
  local boxName = box.boxName
  assert(type(boxName) == "string" and boxName ~= "", "bill dialogue reads the active box name")
  local facts = session.facts --[[@as table<string, unknown>]]
  local roll = 0
  local random = (self --[[@as table<string, unknown>]])._random
  if type(random) == "table" and type(random.lc) == "function" then
    roll = random:lc("bill-advice") % 3
  else
    roll = math.random(0, 2)
  end
  local entries = {
    ServicePhonePrograms.billIntroEntry(facts),
    ServicePhonePrograms.billStatusEntry(freeSlots, roll),
    ServicePhonePrograms.billCloserEntry(),
  }
  local resolveEntry = messages.resolveContactEntry
  assert(type(resolveEntry) == "function", "bill dialogue resolves through its contact-entry reader")
  local tokens = {}
  local opts = { boxName = boxName, freeCount = freeSlots }
  for _, entry in ipairs(entries) do
    local formatted = resolveEntry(messages, session.contact, entry, opts)
    assert(
      type(formatted) == "table" and type(formatted.tokens) == "table",
      "bill dialogue returns formatted source tokens"
    )
    for _, token in ipairs(formatted.tokens) do
      tokens[#tokens + 1] = token
    end
  end
  return { tokens = tokens }
end

-- Resolves one dynamic contact-entry conversation: each bank entry
-- prints through the contact-entry reader and concatenates its
-- tokens, exactly like the Bill staging loop. A stage is either a
-- bare entry number sharing the common options, or an
-- { entry, opts } pair carrying its own slot staging behind handlers
-- that re-buffer between messages.
---@param messages table<string, unknown> field message provider
---@param contact string catalog contact key
---@param entries (integer|{ entry: integer, opts: table<string, unknown>? })[] bank entries in source order
---@param opts table<string, unknown>? common slot staging options
---@return table<string, unknown> formatted native dialogue
local function resolveContactEntries(messages, contact, entries, opts)
  local resolveEntry = messages.resolveContactEntry
  assert(type(resolveEntry) == "function", "dynamic dialogue resolves through its contact-entry reader")
  local tokens = {}
  for _, stage in ipairs(entries) do
    local entry, stageOpts = stage, opts
    if type(stage) == "table" then
      entry = (stage --[[@as table<string, unknown>]]).entry
      stageOpts = (stage --[[@as table<string, unknown>]]).opts
    end
    assert(type(entry) == "number" and entry % 1 == 0, "dynamic dialogue names its bank entry")
    local formatted = resolveEntry(messages, contact, entry, stageOpts)
    assert(
      type(formatted) == "table" and type(formatted.tokens) == "table",
      "dynamic dialogue returns formatted source tokens"
    )
    for _, token in ipairs(formatted.tokens) do
      tokens[#tokens + 1] = token
    end
  end
  return { tokens = tokens }
end

-- Resolves the dynamic Buena incoming conversation behind
-- GearPhoneCall_Buena: the gendered time-of-day intro (3/5/7 male,
-- 4/6/8 female) and the random extra 10..12. No owner reads, no
-- slot buffers, no side effects.
---@param self table<string, unknown>
---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown> resolved native dialogue
local function resolveBuenaIncomingDialogue(self, messages, session)
  local facts = session.facts --[[@as table<string, unknown>]]
  local timeOfDay = facts.timeOfDay
  assert(
    type(timeOfDay) == "number" and timeOfDay % 1 == 0 and timeOfDay >= 0 and timeOfDay <= 2,
    "buena dialogue reads the source time band"
  )
  local entries = {
    ServicePhonePrograms.buenaIntroEntry(facts.playerGender, timeOfDay),
    ServicePhonePrograms.buenaExtraEntry((self --[[@as table<string, unknown>]]):_drawBounded(3, "buena-extra")),
  }
  return resolveContactEntries(messages, session.contact --[[@as string]], entries)
end

-- Resolves the dynamic Buena outgoing conversation behind
-- GearPhoneCall_Buena2: the gendered time-of-day intro (15/17/19
-- male, 16/18/20 female) and the password-hour body (36 on the air,
-- else 21 plus the clear-sized roll with the gendered 34/35 pair on
-- 13). The password identity derives from the raw civil hour exactly
-- like IsBuenasPasswordOnAir.
---@param self table<string, unknown>
---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown> resolved native dialogue
local function resolveBuenaDialogue(self, messages, session)
  local facts = session.facts --[[@as table<string, unknown>]]
  local timeOfDay = facts.timeOfDay
  assert(
    type(timeOfDay) == "number" and timeOfDay % 1 == 0 and timeOfDay >= 0 and timeOfDay <= 2,
    "buena dialogue reads the source time band"
  )
  local hour = facts.hour
  assert(type(hour) == "number" and hour % 1 == 0 and hour >= 0 and hour < 24, "buena dialogue reads the civil hour")
  local sharedU8
  if hour % 3 == 2 then
    sharedU8 = 3
  elseif hour > 3 and hour < 10 then
    sharedU8 = 0
  elseif hour > 9 and hour < 20 then
    sharedU8 = 1
  else
    sharedU8 = 2
  end
  local gameClear = facts.gameClear == true
  local count = gameClear and 14 or 11
  local roll = (self --[[@as table<string, unknown>]]):_drawBounded(count, "buena-body")
  local entries = {
    ServicePhonePrograms.buena2IntroEntry(facts.playerGender, timeOfDay),
    ServicePhonePrograms.buena2BodyEntry(sharedU8, gameClear, roll, facts.playerGender),
  }
  return resolveContactEntries(messages, session.contact --[[@as string]], entries)
end

-- Resolves the dynamic friend incoming conversation behind
-- GearPhoneCall_EthanLyra: the time-of-day intro 4/5/6 and the
-- caller-map location message 13..85 with the 10..12 fallback. No
-- slot buffers, no side effects.
---@param self table<string, unknown>
---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown> resolved native dialogue
local function resolveFriendIncomingDialogue(self, messages, session)
  local facts = session.facts --[[@as table<string, unknown>]]
  local timeOfDay = facts.timeOfDay
  assert(
    type(timeOfDay) == "number" and timeOfDay % 1 == 0 and timeOfDay >= 0 and timeOfDay <= 2,
    "friend dialogue reads the source time band"
  )
  local entries = {
    ServicePhonePrograms.friendIntroEntry(timeOfDay),
    ServicePhonePrograms.friendLocationEntry(
      facts.mapId,
      (self --[[@as table<string, unknown>]]):_drawBounded(3, "friend-location")
    ),
  }
  return resolveContactEntries(messages, session.contact --[[@as string]], entries)
end

-- Resolves the dynamic gym incoming conversation behind
-- GearPhoneCall_GymLeader_Incoming: the opener 10 and the seeking
-- body 11, else 12..14 behind the source LCRandom()%3. Seeking reads
-- the staged rematch record exactly like the trainer readiness query.
---@param self table<string, unknown>
---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown> resolved native dialogue
local function resolveGymIncomingDialogue(self, messages, session)
  local world = session.world --[[@as table<string, unknown>]]
  local query = world.queryRematch
  assert(type(query) == "function", "gym dialogue reads the staged rematch record")
  local contact = session.contact --[[@as string]]
  local current = query(world, contact)
  local seeking = type(current) == "table" and (current --[[@as table<string, unknown>]]).stage > 0
  local entries = {
    ServicePhonePrograms.gymIncomingOpenerEntry(),
    ServicePhonePrograms.gymIncomingBodyEntry(
      seeking,
      (self --[[@as table<string, unknown>]]):_drawBounded(3, "gym-incoming")
    ),
  }
  return resolveContactEntries(messages, session.contact --[[@as string]], entries)
end

-- Resolves the dynamic Kurt conversation behind GearPhoneCall_Kurt:
-- the order-flag intro (6 while the flag stands, else 2) and the
-- handed status (5 empty, 4 while the balls are made, else 3 with
-- the staged ball item and quantity). The handed order reads its
-- apricorn owner; an absent owner fails with attribution instead of
-- an invented empty box.
---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown> resolved native dialogue
local function resolveKurtDialogue(messages, session)
  local world = session.world --[[@as table<string, unknown>]]
  local facts = session.facts --[[@as table<string, unknown>]]
  local pending = ServicePhonePrograms.kurtPending(world)
  local entries = {
    ServicePhonePrograms.kurtIntroEntry(facts.kurtFlag127 == true),
    ServicePhonePrograms.kurtStatusEntry(pending.quantity, facts.kurtMaking == true),
  }
  local opts = nil
  if pending.quantity > 0 and facts.kurtMaking ~= true then
    opts = {
      ballItem = ServicePhonePrograms.kurtBallItem(pending.apricorn --[[@as string]]),
      kurtCount = pending.quantity,
    }
  end
  return resolveContactEntries(messages, session.contact --[[@as string]], entries, opts)
end

-- Resolves the dynamic friend outgoing conversation behind
-- GearPhoneCall_EthanLyra2: the time-of-day intro 7/8/9 and the
-- coin flip between the fixed 10..12 and the region message 86..158
-- behind the unlock and flypoint state. No slot buffers, no side
-- effects.
---@param self table<string, unknown>
---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown> resolved native dialogue
local function resolveFriendOutgoingDialogue(self, messages, session)
  local facts = session.facts --[[@as table<string, unknown>]]
  local timeOfDay = facts.timeOfDay
  assert(
    type(timeOfDay) == "number" and timeOfDay % 1 == 0 and timeOfDay >= 0 and timeOfDay <= 2,
    "friend dialogue reads the source time band"
  )
  local bounded = (self --[[@as table<string, unknown>]])._drawBounded
  local coin = bounded(self, 1000, "friend-coin")
  local body
  if coin < 500 then
    body = ServicePhonePrograms.friendFixedEntry(bounded(self, 900, "friend-fixed"))
  else
    local unlock = facts.unlockLevel
    assert(type(unlock) == "number" and unlock % 1 == 0 and unlock >= 0, "friend regions read the map unlock level")
    local available = {
      [0] = true,
      [1] = facts.flypoint25 == true,
      [2] = unlock ~= 0,
      [3] = unlock > 1,
    }
    -- The candidate count is data-dependent, so the region draw
    -- bounds itself after counting: at most the 73 table rows.
    local count = 0
    for _, class in ipairs(ServicePhonePrograms.FRIEND_REGION_CONDITIONS) do
      if available[class] == true then
        count = count + 1
      end
    end
    assert(count > 0, "friend regions open at least one candidate row")
    body = ServicePhonePrograms.friendRegionEntry(available, bounded(self, count, "friend-region"))
  end
  local entries = { ServicePhonePrograms.friendOutgoingIntroEntry(timeOfDay), body }
  return resolveContactEntries(messages, session.contact --[[@as string]], entries)
end

-- Resolves the dynamic Day Care Man conversation behind
-- GearPhoneCall_DayCareMan: the opener 2 with the egg, empty,
-- single, or pair branch and the compatibility message. Both
-- stabled nicknames stage for slots 10/11 behind the whole call,
-- exactly like the selection-time buffers.
---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown> resolved native dialogue
local function resolveDaycareManDialogue(messages, session)
  local world = session.world --[[@as table<string, unknown>]]
  local status = ServicePhonePrograms.daycareStatus(world)
  local entries = ServicePhonePrograms.daycareManEntries(status)
  local opts = { nickA = status.nicknames[1], nickB = status.nicknames[2] }
  return resolveContactEntries(messages, session.contact --[[@as string]], entries, opts)
end

-- Resolves the dynamic Day Care Lady conversation behind
-- GearPhoneCall_DayCareLady: the gendered intro 3/4, the empty 10
-- or the stabled 5, then the per-mon growth report 6 with its own
-- nickname and growth staging, closed by the single 8 or pair 9.
-- Each growth report re-buffers its own mon, so every 6 carries its
-- own slot options.
---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown> resolved native dialogue
local function resolveDaycareLadyDialogue(messages, session)
  local world = session.world --[[@as table<string, unknown>]]
  local facts = session.facts --[[@as table<string, unknown>]]
  local status = ServicePhonePrograms.daycareStatus(world)
  ---@type (integer|{ entry: integer, opts: table<string, unknown> })[] bank entries with per-message staging
  local stages = { ServicePhonePrograms.daycareLadyIntroEntry(facts.playerGender) }
  if status.count == 0 then
    stages[#stages + 1] = 10
    return resolveContactEntries(messages, session.contact --[[@as string]], stages)
  end
  stages[#stages + 1] = 5
  local growths = status.growths
  -- Retail zero-inits the growth of an absent mon, so a missing
  -- second growth reads as no growth.
  local secondGrowth = growths[2] or 0
  local first = growths[1] ~= 0 and 1 or (secondGrowth ~= 0 and 2 or nil)
  if first == nil then
    stages[#stages + 1] = 9
    return resolveContactEntries(messages, session.contact --[[@as string]], stages)
  end
  stages[#stages + 1] = {
    entry = 6,
    opts = { nickname = status.nicknames[first], growth = growths[first] },
  }
  local second = first == 1 and secondGrowth ~= 0
  if second then
    stages[#stages + 1] = {
      entry = 6,
      opts = { nickname = status.nicknames[2], growth = growths[2] },
    }
  end
  stages[#stages + 1] = status.count == 1 and 8 or 9
  return resolveContactEntries(messages, session.contact --[[@as string]], stages)
end

-- Resolves the dynamic Baoba arrangement conversation behind
-- GearPhoneCall_Baoba: the empty gendered 38/39, the full 24/25,
-- else the gendered 14/15 pair by area count with the area names
-- staged for slots 10 and up. An absent safari owner fails with
-- attribution instead of an invented empty zone.
---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown> resolved native dialogue
local function resolveBaobaArrangementDialogue(messages, session)
  local world = session.world --[[@as table<string, unknown>]]
  local facts = session.facts --[[@as table<string, unknown>]]
  local read = world.read
  assert(type(read) == "function", "baoba dialogue reads its safari owner")
  local arrangement = read(world, "safari.arrangement")
  assert(type(arrangement) == "table", "baoba dialogue resolves its area arrangement")
  local clean = arrangement --[[@as table<string, unknown>]]
  local count = clean.count
  assert(type(count) == "number" and count % 1 == 0 and count >= 0, "baoba dialogue reads its arranged area count")
  local names = clean.names
  assert(type(names) == "table", "baoba dialogue reads its arranged area names")
  local female = facts.playerGender == "female" or facts.playerGender == 1
  local entry
  if count == 0 then
    entry = female and 39 or 38
  elseif count >= 6 then
    entry = female and 25 or 24
  else
    entry = (female and 15 or 14) + 2 * (count - 1)
    for index = 1, count do
      assert(type(names[index]) == "string" and names[index] ~= "", "baoba dialogue names every arranged area")
    end
  end
  local opts = nil
  if count > 0 and count < 6 then
    opts = { areaNames = names }
  end
  return resolveContactEntries(messages, session.contact --[[@as string]], { entry }, opts)
end

-- Resolves the dynamic gym outgoing conversation behind
-- GearPhoneCall_GymLeader_Outgoing: the opener 2 with the badge 3,
-- seeking 9, window 4, or invitation 5 branch. The invitation owes
-- the yes/no menu; the dojo reading freezes behind the answer
-- exactly like the source single-iteration quirk.
---@param self table<string, unknown>
---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown> resolved native dialogue
local function resolveGymOutgoingDialogue(self, messages, session)
  local world = session.world --[[@as table<string, unknown>]]
  local facts = session.facts --[[@as table<string, unknown>]]
  local query = world.queryRematch
  assert(type(query) == "function", "gym dialogue reads the staged rematch record")
  local contact = session.contact --[[@as string]]
  local current = query(world, contact)
  local seeking = type(current) == "table" and (current --[[@as table<string, unknown>]]).stage > 0
  local badges = facts.badges or 0
  assert(type(badges) == "number", "gym selection counts profile badges")
  local me = self --[[@as table<string, unknown>]]
  local catalog = me._catalog --[[@as table<string, unknown>]]
  local windowOk = TrainerPhonePrograms.eligible(contact, world, catalog)
  local entries = {
    TrainerPhonePrograms.gymOutgoingOpenerEntry(),
    TrainerPhonePrograms.gymOutgoingBranchEntry(badges >= 16, seeking, windowOk),
  }
  if entries[2] == 5 then
    -- The first compiled gym contact anchors the source quirk loop;
    -- the caller always resolves through the catalog above.
    local firstKey = nil
    local contacts = (catalog --[[@as table<string, unknown>]]).contacts
    assert(type(contacts) == "table", "gym quirks read the contact catalog")
    for _, record in ipairs(contacts) do
      local candidate = record --[[@as table<string, unknown>]]
      if candidate.family == "gym" or candidate.family == "rematch" then
        firstKey = candidate.key
        break
      end
    end
    assert(type(firstKey) == "string", "gym quirks name their first compiled contact")
    local firstSeeking = false
    if firstKey ~= contact then
      local first = query(world, firstKey --[[@as string]])
      firstSeeking = type(first) == "table" and (first --[[@as table<string, unknown>]]).stage > 0
    end
    facts.dynamicGymMenu = true
    session.dynamicGymMenu = true
    facts.dynamicGymDojoFull = TrainerPhonePrograms.gymDojoFull(contact, firstKey, firstSeeking)
  end
  return resolveContactEntries(messages, session.contact --[[@as string]], entries)
end

-- Resolves the dynamic Oak opening behind GearPhoneCall_ProfOak:
-- the gendered intro 13/14 and the second message 15. The menu
-- identity derives from the national dex and johto acknowledgement
-- facts; the evaluation itself stages behind the menu answer.
---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown> resolved native dialogue
local function resolveOakDialogue(messages, session)
  local facts = session.facts --[[@as table<string, unknown>]]
  local shared = ProfessorPhonePrograms.oakMenuIndex(facts.nationalDex == true, facts.oakJohtoAcked == true)
  local entries = {
    ProfessorPhonePrograms.oakIntroEntry(facts.playerGender),
    15,
  }
  facts.dynamicOakMenu = true
  session.dynamicOakMenu = true
  facts.dynamicOakShared = shared
  session.dynamicOakShared = shared
  return resolveContactEntries(messages, session.contact --[[@as string]], entries)
end

-- Resolves the dynamic Oak result entries with their fanfare: plays
-- the staged rating fanfare through the audio boundary, then prints
-- the seen/owned 20 with its slot staging plus the rating and the
-- closer 21 unless the completed dex ends the call.
---@param self table<string, unknown>
---@param messages table<string, unknown>
---@param session table<string, unknown>
---@param outcome table<string, unknown> answer outcome
---@return table<string, unknown> resolved native dialogue
local function resolveOakResult(self, messages, session, outcome)
  local fanfare = outcome.fanfare
  if fanfare ~= nil then
    assert(type(fanfare) == "string" and fanfare ~= "", "oak ratings play their fanfare sequence")
    local audio = (self --[[@as table<string, unknown>]])._audio
    assert(type(audio) == "table", "oak ratings play through the audio boundary")
    local play = audio.play --[[@as fun(self: table<string, unknown>, sequence: string)]]
    assert(type(play) == "function", "oak fanfare plays its source sequence")
    play(audio, fanfare)
  end
  local entries = outcome.entries
  assert(type(entries) == "table" and #entries > 0, "oak answers stage their result entries")
  local facts = session.facts --[[@as table<string, unknown>]]
  local opts = nil
  if type(facts.dynamicOakSeen) == "number" and type(facts.dynamicOakOwned) == "number" then
    opts = { seenCount = facts.dynamicOakSeen, ownedCount = facts.dynamicOakOwned }
  end
  return resolveContactEntries(messages, session.contact --[[@as string]], entries, opts)
end

-- Resolves the source time-of-day greeting for one static call: the
-- contact greeting set behind the call time band, direction, and
-- player gender. Dynamic sessions and local-bank calls resolve their
-- own intros and skip the generic greeting, exactly like the source
-- handlers that never print it. Dynamic Bill is the exception: its
-- handler prints the greeting before its own entries, so it greets
-- like a static call. Contacts without a greeting set skip
-- silently; a set without a greeting reader fails loudly.
---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown>? formatted greeting text
local function resolveCallGreeting(messages, session)
  if session.dynamicMother == true or session.localBankEntry ~= nil then
    return nil
  end
  if type(session.scriptId) ~= "number" and session.dynamicBill ~= true then
    return nil
  end
  local record = session.record --[[@as table<string, unknown>]]
  local set = record.greetingMsgSet
  if type(set) ~= "number" or set == 255 then
    return nil
  end
  local resolveGreeting = messages.resolveCallGreeting
  assert(type(resolveGreeting) == "function", "static calls greet through the shared greeting reader")
  local facts = session.facts --[[@as table<string, unknown>]]
  return resolveGreeting(messages, session.contact --[[@as string]], facts.timeOfDay, session.direction == "incoming")
end

---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown> resolved native dialogue
local function resolveNativeDialogue(self, messages, session)
  selectNativeScript(self, session, session.record --[[@as table<string, unknown>]])
  if session.dynamicMother == true then
    local entry = MotherPhoneProgram.introEntry(session.facts --[[@as table<string, unknown>]])
    return resolveMotherEntry(messages, session, entry)
  end
  if session.dynamicBill == true then
    return resolveBillDialogue(self, messages, session)
  end
  if session.dynamicBuenaIncoming == true then
    return resolveBuenaIncomingDialogue(self, messages, session)
  end
  if session.dynamicBuena == true then
    return resolveBuenaDialogue(self, messages, session)
  end
  if session.dynamicFriendIncoming == true then
    return resolveFriendIncomingDialogue(self, messages, session)
  end
  if session.dynamicGymIncoming == true then
    return resolveGymIncomingDialogue(self, messages, session)
  end
  if session.dynamicGymOutgoing == true then
    return resolveGymOutgoingDialogue(self, messages, session)
  end
  if session.dynamicKurt == true then
    return resolveKurtDialogue(messages, session)
  end
  if session.dynamicFriend == true then
    return resolveFriendOutgoingDialogue(self, messages, session)
  end
  if session.dynamicDaycareMan == true then
    return resolveDaycareManDialogue(messages, session)
  end
  if session.dynamicDaycareLady == true then
    return resolveDaycareLadyDialogue(messages, session)
  end
  if session.dynamicOak == true then
    return resolveOakDialogue(messages, session)
  end
  if session.dynamicBaobaArrangement == true then
    return resolveBaobaArrangementDialogue(messages, session)
  end
  if session.dynamicGeneric == true then
    local failure = Errors.new(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "native phone dynamic handler needs its save-owned program wiring for " .. tostring(session.family),
      { family = session.family, contact = session.contact, program = session.program }
    )
    error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
  end
  local scriptId = session.scriptId
  local resolveLine = messages.resolveLine
  if session.localBankEntry ~= nil then
    -- Same-map gym calls print the caller's bank entry one with no
    -- side effect, exactly like the outgoing gym handler's local map
    -- branch.
    local entry = session.localBankEntry --[[@as integer]]
    assert(type(entry) == "number", "the local caller carries its bank entry")
    local resolveEntry = messages.resolveContactEntry
    assert(type(resolveEntry) == "function", "phone dialogue resolves through its contact-entry reader")
    return resolveEntry(messages, session.contact --[[@as string]], entry)
  end
  assert(type(scriptId) == "number", "the selected caller carries its native script identity")
  assert(type(resolveLine) == "function", "phone dialogue resolves through the field message provider")
  return resolveLine(messages, session.contact, scriptId)
end

---@param session table<string, unknown>
---@param failure unknown
---@return boolean handled as an unavailable source feature
function PhoneCall:_failCall(session, failure)
  session.failed = failure
  session.stage = "done"
  session.terminal = true
  if self._active == session.id then
    self._active = nil
  end
  if type(failure) == "table" and failure.code == ScriptErrors.FEATURE_UNAVAILABLE then
    session.result = {
      id = session.id,
      contact = session.contact,
      kind = session.kind,
      error = failure,
    }
    return true
  end
  error(failure, 0)
end

---@param sequence string
function PhoneCall:_playSequence(sequence)
  local audio = self._audio
  if type(audio) ~= "table" then
    return
  end
  if sequence == PhoneCall.HANGUP_SEQUENCE and audio.playHangup ~= nil then
    local hangup = audio.playHangup --[[@as fun(self: table<string, unknown>)]]
    hangup(audio)
    return
  end
  if type(audio.play) == "function" then
    local play = audio.play --[[@as fun(self: table<string, unknown>, sequence: string)]]
    play(audio, sequence)
  end
end

-- Enters the pre-hangup button wait: the finished conversation holds
-- its last page until the player confirms with Action or the
-- fast-forward touch, which plays the source SELECT tone once before
-- the staged hangup runs. Mirrors PhoneCall_WaitButtonBeforeHangup.
---@param session table<string, unknown>
function PhoneCall:_beginWaitPress(session)
  session.stage = "waitPress"
  enterStage(session)
end

-- Enters the staged hangup: plays the source PHONE_OFF tone once,
-- publishes the first localized hangup message, and holds the hangingUp
-- stage across fixed steps until the staged timers complete. Exactly-once
-- per call: later cancel edges while hanging up never restart it.
---@param session table<string, unknown>
function PhoneCall:_beginHangup(session)
  if session.stage == "hangingUp" then
    return
  end
  session.stage = "hangingUp"
  enterStage(session)
  session.hangupSub = 0
  session.hangupTimer = 0
  session.lines = { self:_uiText(PhoneCall.HANGUP_MESSAGE_ENTRIES[1]) }
  session.textPage = 1
  self:_playSequence(PhoneCall.HANGUP_SEQUENCE)
end

-- Advances the staged hangup timer one tick. Each wait holds its message
-- across eleven post-increment ticks before printing the next message or
-- completing the call; waiting ticks never duplicate a tone.
---@param session table<string, unknown>
---@return boolean completed
function PhoneCall:_advanceHangup(session)
  if session.hangupSub == nil then
    self:_beginHangup(session)
    return false
  end
  local timer = session.hangupTimer --[[@as integer]] or 0
  if timer < 10 then
    session.hangupTimer = timer + 1
    return false
  end
  session.hangupTimer = 0
  local sub = session.hangupSub --[[@as integer]] + 1
  session.hangupSub = sub
  enterStage(session)
  if sub == 1 then
    session.lines = { self:_uiText(PhoneCall.HANGUP_MESSAGE_ENTRIES[2]) }
    session.textPage = 1
    return false
  end
  if sub == 2 then
    session.lines = { self:_uiText(PhoneCall.HANGUP_MESSAGE_ENTRIES[3]) }
    session.textPage = 1
    return false
  end
  if session.noSignalArmed == true then
    -- The out-of-area closer replaces the hangup window after the
    -- tone completes; its button wait ends the call with no replay.
    session.lines = { self:_uiText(PhoneCall.NO_SIGNAL_CLOSER_ENTRY) }
    session.textPage = 1
    session.stage = "waitPress"
    enterStage(session)
    return false
  end
  self:_finishHangup(session)
  return true
end

-- The two no-signal message sets: the toneless out-of-area notices
-- (bank 271 entries 30-32) and the out-of-area closer (entry 37)
-- printed after the hangup tone completes.
PhoneCall.NO_SIGNAL_MESSAGE_ENTRIES = { 30, 31, 32 }
PhoneCall.NO_SIGNAL_CLOSER_ENTRY = 37

-- Reads one localized bank271 call line through the shared UI message
-- reader: the dial notices, the hangup clicks, and the away notice. No
-- literal text lives in the session.
---@param entryId integer bank271 entry number
---@return table<string, unknown> the printable speech line
function PhoneCall:_uiText(entryId)
  local resolveUi = self._messages.resolvePhoneUiMessage
  assert(type(resolveUi) == "function", "phone call text resolves through the shared UI message reader")
  local record = resolveUi(self._messages, entryId)
  assert(type(record) == "table" and type(record.text) == "string", "phone call entries resolve to printable text")
  return { text = record.text, tokens = record.tokens }
end

-- Advances the no-signal flow one tick: the three toneless notices
-- print across eleven-tick waits, then the staged hangup runs behind
-- the armed flag so the out-of-area closer follows it.
---@param session table<string, unknown>
function PhoneCall:_advanceNoSignal(session)
  local sub = session.noSignalSub --[[@as integer]] or 0
  local timer = session.noSignalTimer --[[@as integer]] or 0
  if timer < 10 then
    session.noSignalTimer = timer + 1
    return
  end
  session.noSignalTimer = 0
  sub = sub + 1
  session.noSignalSub = sub
  enterStage(session)
  if sub == 1 then
    session.lines = { self:_uiText(PhoneCall.NO_SIGNAL_MESSAGE_ENTRIES[2]) }
    session.textPage = 1
    return
  end
  if sub == 2 then
    session.lines = { self:_uiText(PhoneCall.NO_SIGNAL_MESSAGE_ENTRIES[3]) }
    session.textPage = 1
    return
  end
  self:_beginHangup(session)
end

-- Completes the staged hangup with its terminal result. The hangup
-- tone already played once at hangup entry; completion never replays it.
---@param session table<string, unknown>
function PhoneCall:_finishHangup(session)
  if session.hangupDone ~= true then
    session.hangupDone = true
    local count = self._hangups
    self._hangups = count + 1
  end
  if session.result == nil then
    local query = self._world.queryRematch
    local rematch = type(query) == "function" and query(self._world, session.contact --[[@as string]]) or nil
    local staged = type(rematch) == "table" and rematch.stage > 0
    session.result = {
      id = session.id,
      contact = session.contact,
      kind = session.kind,
      program = session.program,
      ready = staged,
    }
  end
  session.stage = "done"
  session.terminal = true
  if self._active == session.id then
    self._active = nil
  end
end

-- Snapshots the owed menu choice: the source menu identity with its
-- bank-271 display labels in source order, plus the localized choice
-- prompt where the menu carries one. The savings menu keeps its
-- historical entries; dynamic gym and oak menus ride their own
-- identities. Semantic answers stay with the owning program module;
-- the session only carries display strings. Resolved once at choice
-- entry so detached views never fetch messages.
---@param session table<string, unknown>
function PhoneCall:_resolveChoiceLabels(session)
  local resolveUi = self._messages.resolvePhoneUiMessage
  assert(type(resolveUi) == "function", "phone choices resolve through the shared UI message reader")
  local menuId, base, count, tooltipEntry, choices = 2, 8, 2, 22, MotherPhoneProgram.CHOICES
  if session.dynamicGymMenu == true then
    menuId, base, count, tooltipEntry, choices = 6, 18, 2, 22, TrainerPhonePrograms.GYM_MENU_CHOICES
  elseif session.dynamicOakMenu == true then
    local shared = session.dynamicOakShared
    assert(type(shared) == "number" and shared % 1 == 0 and shared >= 0 and shared <= 2, "oak menus read their menu")
    local menu = ProfessorPhonePrograms.OAK_MENUS[shared]
    assert(type(menu) == "table", "oak menus carry their source identity")
    menuId, base, choices = menu.id, menu.base, menu.choices
    assert(type(choices) == "table", "oak menus carry their semantic choices")
    count, tooltipEntry = #choices, 22
  end
  local labels = {}
  for offset = 0, count - 1 do
    local item = resolveUi(self._messages, base + offset)
    assert(
      type(item) == "table" and type((item --[[@as table<string, unknown>]]).text) == "string",
      "phone choice entries resolve to printable text"
    )
    labels[#labels + 1] = (item --[[@as table<string, unknown>]]).text
  end
  local tooltip = nil
  if tooltipEntry ~= nil then
    local prompt = resolveUi(self._messages, tooltipEntry)
    assert(
      type(prompt) == "table" and type((prompt --[[@as table<string, unknown>]]).text) == "string",
      "phone choice prompt resolves to printable text"
    )
    tooltip = (prompt --[[@as table<string, unknown>]]).text
  end
  session.menuId = menuId
  session.choiceLabels = labels
  session.choiceTooltip = tooltip
  session.choiceIds = choices
end

-- Counts the printable glyphs on the session's current page: only
-- glyph-kind tokens reveal, so breaks and zero-width controls never stall
-- the typewriter. Pages without compiled tokens carry no reveal count.
---@param session table<string, unknown>
---@return integer glyph count
local function pageGlyphTotal(session)
  local lines = session.lines --[[@as table<integer, unknown>?]]
  local page = session.textPage --[[@as integer?]]
  if type(lines) ~= "table" or type(page) ~= "number" then
    return 0
  end
  local entry = lines[page]
  if type(entry) ~= "table" then
    return 0
  end
  local tokens = (entry --[[@as table<string, unknown>]]).tokens
  if type(tokens) ~= "table" then
    return 0
  end
  local total = 0
  for _, token in
    ipairs(tokens --[[@as table<integer, unknown>]])
  do
    if
      type(token) == "table" and (token --[[@as table<string, unknown>]]).kind == "glyph"
    then
      total = total + 1
    end
  end
  return total
end

-- Reads the player's text speed behind call text typing through the
-- world boundary, defaulting to mid where the world carries no option.
-- Retail prints call pages behind Options_GetTextFrameDelay, never a
-- fixed cadence. The world may carry the speed as a function returning
-- the option or as the plain option string; both are honored so a
-- setting change always reaches the typewriter.
---@return string the configured text speed
function PhoneCall:_textSpeed()
  local world = self._world
  local query = type(world) == "table" and (world --[[@as table<string, unknown>]]).textSpeed or nil
  local speed = nil
  if type(query) == "function" then
    speed = query(world)
  elseif type(query) == "string" then
    speed = query
  end
  if type(speed) ~= "string" then
    return "mid"
  end
  local PlayerData = require("libs.hgss.src.save.PlayerData")
  if PlayerData.TEXT_SPEEDS[speed] == nil then
    return "mid"
  end
  return speed --[[@as string]]
end

-- Reads the player's text speed behind call text typing through the
-- world boundary, defaulting to mid where the world carries no option.
-- Retail prints call pages behind Options_GetTextFrameDelay, never a
-- fixed cadence.
---@return integer fixed ticks per revealed glyph
function PhoneCall:_ticksPerGlyph()
  local PlayerData = require("libs.hgss.src.save.PlayerData")
  return PlayerData.ticksPerGlyph(self:_textSpeed())
end

-- Advances the typewriter one fixed tick on the session's open page:
-- glyphs reveal behind the configured text speed, with the fastest
-- setting printing its two-glyph budget so it stays distinct from fast.
-- Returns true while the page still hides glyphs. Callers reset the
-- counters when they publish new lines or turn the page; hangup lines
-- never type and never call this.
---@param session table<string, unknown>
---@return boolean typing true while glyphs remain hidden
function PhoneCall:_revealTick(session)
  local total = pageGlyphTotal(session)
  local revealed = session.textRevealed --[[@as integer?]] or 0
  if revealed >= total then
    session.textRevealed = total
    return false
  end
  local tick = (
    session.textTick --[[@as integer?]]
    or 0
  ) + 1
  if tick >= self:_ticksPerGlyph() then
    tick = 0
    local budget = self:_textSpeed() == "fastest" and 2 or 1
    revealed = math.min(total, revealed + budget)
  end
  session.textTick = tick
  session.textRevealed = revealed
  return revealed < total
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
    -- The finished conversation's button wait answers B like A: one
    -- source SELECT tone, then the staged hangup.
    if session.stage == "waitPress" then
      self:_playSequence(PhoneCall.SELECT_SEQUENCE)
    end
    self:_beginHangup(session)
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
      -- The dial advances one source stage per settled tone: the second
      -- tone and its notice, then the conversation.
      if session.dialSub == 0 then
        session.dialSub = 1
        self:_dialStep(session)
        return
      end
      session.stage = "greeting"
      enterStage(session)
    elseif stage == "greeting" then
      if session.program == nil then
        self:_selectProgramAtGreeting(session)
        self:_openProgramSession(session)
      end
      local ok, formatted = pcall(resolveNativeDialogue, self, self._messages, session)
      if not ok then
        self:_failCall(session, formatted)
        return
      end
      assert(
        type(formatted) == "table" and type(formatted.tokens) == "table",
        "phone dialogue returns formatted source tokens"
      )
      -- Static calls open behind the source time-of-day greeting when
      -- the caller carries a greeting set, exactly like the Simple,
      -- Generic, and Generic2 handlers print before their script text.
      -- Dynamic and local-bank calls resolve their own intros.
      local pages = {}
      local greetOk, greeting = pcall(resolveCallGreeting, self._messages, session)
      if not greetOk then
        self:_failCall(session, greeting)
        return
      end
      if greeting ~= nil then
        assert(
          type(greeting) == "table" and type(greeting.tokens) == "table",
          "phone greetings return formatted source tokens"
        )
        for _, page in ipairs(self:_pagesFromTokens(greeting.tokens)) do
          pages[#pages + 1] = page
        end
      end
      for _, page in ipairs(self:_pagesFromTokens(formatted.tokens)) do
        pages[#pages + 1] = page
      end
      session.lines = pages
      session.textRevealed, session.textTick = 0, 0
      assert(#session.lines > 0, "phone scripts produce at least one printable text page")
      -- Static script side effects (rematch/item/flag/word) run once at
      -- greeting, before the text prints, mirroring
      -- PhoneCall_ApplyGenericNPCcallSideEffect. Dynamic Mother has no
      -- scriptId; its savings flag runs in the program stage.
      if session.dynamicMother ~= true then
        local sideOk, sideFault = pcall(function()
          self:_applyStaticSideEffect(session)
        end)
        if not sideOk then
          self:_failCall(session, sideFault)
          return
        end
      end
      session.stage = "message"
      enterStage(session)
      return
    elseif stage == "message" then
      if self:_revealTick(session) then
        -- The page still types: a forced edge completes it at once
        -- instead of turning it, exactly like the source printer
        -- fast-forward behind Action.
        if forced then
          session.textRevealed = pageGlyphTotal(session)
          session.textTick = 0
        end
        return
      end
      if not forced then
        return
      end
      forced = false
      local page = session.textPage --[[@as integer]]
      local lines = session.lines --[[@as table<integer, unknown>]]
      if page < #lines then
        session.textPage = page + 1
        session.textRevealed, session.textTick = 0, 0
        enterStage(session)
        return
      end
      session.stage = "program"
      enterStage(session)
    elseif stage == "program" then
      local ok, outcome = pcall(stepProgram, session, edges)
      if not ok then
        self:_failCall(session, outcome)
        return
      end
      local status, entry = outcome, nil
      if type(outcome) == "table" then
        status = (outcome --[[@as table<string, unknown>]]).status
        entry = (outcome --[[@as table<string, unknown>]]).entry
      end
      if status == "waiting" then
        -- Dynamic menu prompts: the savings prompt resolves its bank
        -- entry while gym and oak prompts already printed behind the
        -- message stage, so the choice views the staged text before
        -- answering.
        if type(entry) == "number" and session.dynamicMother == true then
          local promptOk, promptFormatted = pcall(resolveMotherEntry, self._messages, session, entry)
          if not promptOk then
            self:_failCall(session, promptFormatted)
            return
          end
          session.lines = self:_pagesFromTokens(promptFormatted.tokens)
          session.textPage = 1
          session.textRevealed, session.textTick = 0, 0
        end
        session.stage = "choice"
        enterStage(session)
        local labelsOk, labelsFault = pcall(function()
          self:_resolveChoiceLabels(session)
        end)
        if not labelsOk then
          self:_failCall(session, labelsFault)
          return
        end
        return
      end
      -- Dynamic menu terminal entries (the savings gift-full 21 and
      -- results 25/26, the gym answers 6/7/8): show the staged pages
      -- in a result stage before hangup. Savings entries resolve
      -- through the balance reader; gym and oak answers resolve
      -- through the contact-entry reader like their dialogue.
      if type(entry) == "number" and session.dynamicMother == true then
        local resultOk, resultFormatted = pcall(resolveMotherEntry, self._messages, session, entry)
        if not resultOk then
          self:_failCall(session, resultFormatted)
          return
        end
        session.lines = self:_pagesFromTokens(resultFormatted.tokens)
        session.textPage = 1
        session.textRevealed, session.textTick = 0, 0
        session.stage = "result"
        enterStage(session)
        return
      end
      if type(entry) == "number" and session.dynamicGymMenu == true then
        local resultOk, resultFormatted =
          pcall(resolveContactEntries, self._messages, session.contact --[[@as string]], { entry })
        if not resultOk then
          self:_failCall(session, resultFormatted)
          return
        end
        session.lines = self:_pagesFromTokens(resultFormatted.tokens)
        session.textPage = 1
        session.textRevealed, session.textTick = 0, 0
        session.stage = "result"
        enterStage(session)
        return
      end
      if session.dynamicOakMenu == true and type(outcome) == "table" then
        local answerOutcome = outcome --[[@as table<string, unknown>]]
        if type(answerOutcome.entries) ~= "table" then
          self:_failCall(session, "oak answers stage their result entries")
          return
        end
        local resultOk, resultFormatted = pcall(resolveOakResult, self, self._messages, session, answerOutcome)
        if not resultOk then
          self:_failCall(session, resultFormatted)
          return
        end
        session.lines = self:_pagesFromTokens(resultFormatted.tokens)
        session.textPage = 1
        session.textRevealed, session.textTick = 0, 0
        session.stage = "result"
        enterStage(session)
        return
      end
      self:_beginWaitPress(session)
      return
    elseif stage == "choice" then
      if edges.choice == nil then
        if self:_revealTick(session) then
          -- The prompt still types while the menu waits: a forced edge
          -- completes it at once.
          if forced then
            session.textRevealed = pageGlyphTotal(session)
            session.textTick = 0
          end
          return
        end
        return
      end
      -- An answer lands while the prompt still types: completing the
      -- page and answering at once keeps one tap counting.
      session.textRevealed = pageGlyphTotal(session)
      session.textTick = 0
      local ok, outcome = pcall(stepProgram, session, edges)
      if not ok then
        self:_failCall(session, outcome)
        return
      end
      local status, entry = outcome, nil
      if type(outcome) == "table" then
        status = (outcome --[[@as table<string, unknown>]]).status
        entry = (outcome --[[@as table<string, unknown>]]).entry
      end
      if status == "waiting" then
        return
      end
      if type(entry) == "number" and session.dynamicMother == true then
        local resultOk, resultFormatted = pcall(resolveMotherEntry, self._messages, session, entry)
        if not resultOk then
          self:_failCall(session, resultFormatted)
          return
        end
        session.lines = self:_pagesFromTokens(resultFormatted.tokens)
        session.textPage = 1
        session.textRevealed, session.textTick = 0, 0
        session.stage = "result"
        enterStage(session)
        return
      end
      if type(entry) == "number" and session.dynamicGymMenu == true then
        local resultOk, resultFormatted =
          pcall(resolveContactEntries, self._messages, session.contact --[[@as string]], { entry })
        if not resultOk then
          self:_failCall(session, resultFormatted)
          return
        end
        session.lines = self:_pagesFromTokens(resultFormatted.tokens)
        session.textPage = 1
        session.textRevealed, session.textTick = 0, 0
        session.stage = "result"
        enterStage(session)
        return
      end
      if session.dynamicOakMenu == true and type(outcome) == "table" then
        local answerOutcome = outcome --[[@as table<string, unknown>]]
        if type(answerOutcome.entries) ~= "table" then
          self:_failCall(session, "oak answers stage their result entries")
          return
        end
        local resultOk, resultFormatted = pcall(resolveOakResult, self, self._messages, session, answerOutcome)
        if not resultOk then
          self:_failCall(session, resultFormatted)
          return
        end
        session.lines = self:_pagesFromTokens(resultFormatted.tokens)
        session.textPage = 1
        session.textRevealed, session.textTick = 0, 0
        session.stage = "result"
        enterStage(session)
        return
      end
      self:_beginWaitPress(session)
      return
    elseif stage == "result" then
      -- Dynamic Mother result/gift-full pages print like message pages,
      -- then the staged hangup runs. No program re-entry.
      if self:_revealTick(session) then
        if forced then
          session.textRevealed = pageGlyphTotal(session)
          session.textTick = 0
        end
        return
      end
      if not forced then
        return
      end
      forced = false
      local page = session.textPage --[[@as integer]]
      local lines = session.lines --[[@as table<integer, unknown>]]
      if page < #lines then
        session.textPage = page + 1
        session.textRevealed, session.textTick = 0, 0
        enterStage(session)
        return
      end
      self:_beginWaitPress(session)
      return
    elseif stage == "noSignal" then
      self:_advanceNoSignal(session)
      return
    elseif stage == "hangingUp" then
      self:_advanceHangup(session)
      return
    elseif stage == "waitPress" then
      -- The finished conversation holds its last page: a press plays
      -- the source SELECT tone once. Ordinary calls stage the timed
      -- hangup behind it; an armed no-signal flow ends at once with
      -- no tone replay.
      if not forced then
        return
      end
      forced = false
      self:_playSequence(PhoneCall.SELECT_SEQUENCE)
      if session.noSignalArmed == true then
        session.noSignalArmed = false
        self:_finishHangup(session)
        return
      end
      self:_beginHangup(session)
      return
    else
      return
    end
  end
end

-- Splits formatted source tokens into printable pages at page and
-- prompt breaks, exactly like the greeting path. Shared by static
-- greetings and dynamic Mother entries so Bank 664 multi-page intros
-- never pre-flatten.
---@param tokens table<integer, unknown> formatted source tokens
---@return table<integer, unknown> printable pages
function PhoneCall:_pagesFromTokens(tokens)
  assert(type(tokens) == "table", "phone pages split formatted source tokens")
  local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
  local lines = {}
  local pageTokens = {}
  local function finishPage()
    if #pageTokens > 0 then
      lines[#lines + 1] = { text = FieldMessageText.tokensToText(pageTokens), tokens = pageTokens }
      pageTokens = {}
    end
  end
  for _, token in
    ipairs(tokens --[[@as table<integer, unknown>]])
  do
    local kind = (token --[[@as table<string, unknown>]]).kind
    if kind == "page_break" or kind == "prompt_break" then
      finishPage()
    else
      pageTokens[#pageTokens + 1] = token
    end
  end
  finishPage()
  return lines
end

-- Applies one static script side effect from the compiled call table,
-- mirroring PhoneCall_ApplyGenericNPCcallSideEffect: rematch stages
-- readiness, item stages a contact gift (Cheri Berry and Poke Ball
-- roll their source random windows), flag sets/clears the named event
-- flag, word draws its random pick. None kinds do nothing. Missing
-- owners fail with attribution, never a fabricated world.
---@param session table<string, unknown>
function PhoneCall:_applyStaticSideEffect(session)
  local scriptId = session.scriptId
  if type(scriptId) ~= "number" then
    return
  end
  local catalog = self._catalog --[[@as table<string, unknown>]]
  local definitions = catalog.callDefinitions
  if type(definitions) ~= "table" then
    return
  end
  local definition = (definitions --[[@as table<integer, unknown>]])[scriptId]
  if type(definition) ~= "table" then
    return
  end
  local record = definition --[[@as table<string, unknown>]]
  local kind = record.kind
  if kind == nil or kind == "none" then
    return
  end
  local contact = session.contact --[[@as string]]
  if kind == "rematch" then
    local world = self._world --[[@as table<string, unknown>]]
    if type(world.setRematch) == "function" then
      local query = world.queryRematch
      local current = type(query) == "function" and query(world, contact) or nil
      local wins = 0
      if type(current) == "table" and type(current.wins) == "number" then
        wins = current.wins
      end
      world.setRematch(world, contact, { stage = 1, wins = wins })
    else
      local ready = world.rematchReady
      if type(ready) ~= "table" then
        ready = {}
        world.rematchReady = ready
      end
      (ready --[[@as table<string, boolean>]])[contact] = true
    end
    return
  end
  if kind == "item" then
    local item = record.param1
    assert(type(item) == "string" and item ~= "", "phone item effects name their item")
    local resolved = item
    if item == "ITEM_CHERI_BERRY" then
      local berries = {
        "ITEM_CHERI_BERRY",
        "ITEM_CHESTO_BERRY",
        "ITEM_PECHA_BERRY",
        "ITEM_RAWST_BERRY",
        "ITEM_ASPEAR_BERRY",
        "ITEM_LEPPA_BERRY",
        "ITEM_ORAN_BERRY",
        "ITEM_PERSIM_BERRY",
        "ITEM_LUM_BERRY",
        "ITEM_SITRUS_BERRY",
      }
      local draw = 0
      if type(self._random) == "table" and type(self._random.mt) == "function" then
        draw = self._random:mt("gift_item") % 10
      else
        draw = math.random(0, 9)
      end
      resolved = berries[draw + 1]
    elseif item == "ITEM_POKE_BALL" then
      local balls = { "ITEM_ULTRA_BALL", "ITEM_GREAT_BALL", "ITEM_POKE_BALL" }
      local draw = 0
      if type(self._random) == "table" and type(self._random.mt) == "function" then
        draw = self._random:mt("gift_item") % 3
      else
        draw = math.random(0, 2)
      end
      resolved = balls[draw + 1]
    end
    local state = self._state --[[@as table<string, unknown>]]
    local setReward = state.setContactReward
    if type(setReward) == "function" then
      setReward(state, contact, { item = resolved, quantity = 1 })
    else
      local world = self._world --[[@as table<string, unknown>]]
      local gifts = world.contactGifts
      if type(gifts) ~= "table" then
        gifts = {}
        world.contactGifts = gifts
      end
      (gifts --[[@as table<string, unknown>]])[contact] = { item = resolved, quantity = 1 }
    end
    return
  end
  if kind == "flag" then
    -- The compiled table names its flag semantically; the world boundary
    -- resolves that name to its native identity.
    local flag = record.param1
    assert(type(flag) == "string" and flag ~= "", "phone flag effects name their flag")
    local set = record.param0 ~= 0
    local world = self._world --[[@as table<string, unknown>]]
    if type(world.setFlag) == "function" and type(world.clearFlag) == "function" then
      if set then
        world.setFlag(world, flag)
      else
        world.clearFlag(world, flag)
      end
    else
      local flags = world.flags
      assert(type(flags) == "table", "phone flag effects need their flag owner")
      if set then
        flags[flag] = true
      else
        flags[flag] = nil
      end
    end
    return
  end
  if kind == "word" then
    local count = record.param0
    assert(type(count) == "number" and count > 0, "phone word effects name their pick count")
    local pick = 0
    if type(self._random) == "table" and type(self._random.lc) == "function" then
      pick = self._random:lc("word_pick") % count
    else
      pick = math.random(0, count - 1)
    end
    local staging = self._messages.wordStaging
    if type(staging) ~= "table" then
      staging = {}
      self._messages.wordStaging = staging
    end
    (staging --[[@as table<string, unknown>]])[contact] = { base = record.param1, pick = pick }
    return
  end
  error("phone static effects name a known source kind, got " .. tostring(kind), 0)
end

---@param stage string
---@return string public view stage
local function publicStage(stage)
  if stage == "connecting" then
    return "connecting"
  end
  if stage == "greeting" or stage == "message" or stage == "program" or stage == "result" or stage == "waitPress" then
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
    lines = session.lines,
    page = session.textPage,
  }
  -- Typing stages publish the typewriter position behind the current
  -- page: revealed glyphs and the page glyph total. Instant stages
  -- (ringing, signal, hangup, completed) omit both and render whole.
  if stage == "message" or stage == "choice" then
    shown.revealed = session.textRevealed or 0
    shown.total = pageGlyphTotal(session)
  end
  if stage == "choice" then
    -- Choice menus ride the session's staged identities: the savings
    -- menu and the dynamic gym and oak menus each carry their own
    -- semantic ids, menu identity, labels, and prompt. Display labels
    -- and the choice prompt ride along in the same order; game effects
    -- only read the semantic ids.
    local choices = session.choiceIds or MotherPhoneProgram.CHOICES
    assert(type(choices) == "table" and #choices >= 2 and #choices <= 3, "choice menus carry two or three semantic ids")
    assert(
      session.owner == "mother" or session.dynamicGymMenu == true or session.dynamicOakMenu == true,
      "only staged menus wait for input"
    )
    local menuId = session.menuId
    assert(type(menuId) == "number", "choice menus carry their menu identity")
    local labels = session.choiceLabels
    assert(type(labels) == "table" and #labels == #choices, "choice menus carry one display label per semantic id")
    local tooltip = session.choiceTooltip
    assert(tooltip == nil or type(tooltip) == "string", "choice menus carry their localized prompt")
    local shownChoices, shownLabels = {}, {}
    for _, choice in ipairs(choices) do
      shownChoices[#shownChoices + 1] = choice
    end
    for _, label in ipairs(labels) do
      shownLabels[#shownLabels + 1] = label
    end
    shown.choices = shownChoices
    shown.menuId = menuId
    shown.choiceLabels = shownLabels
    shown.choiceTooltip = tooltip
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

-- Hangs the call up at once behind the single source hangup tone.
-- Forced teardown never replays the tone: a call already hanging up
-- finishes silently, any other live call plays it once here, and a
-- terminal call stays untouched. A call waiting on the finished
-- conversation's button still voices the source SELECT tone first, so
-- cancelling that wait sounds like the source A/B confirmation. Committed
-- effects are always kept; the staged timer path belongs to stepped
-- player hangups.
---@param handle { id: string }
---@param reason string hangup reason
function PhoneCall:cancel(handle, reason)
  local session = checkHandle(self, handle)
  assert(type(reason) == "string" and reason ~= "", "phone cancellation names its reason")
  if session.terminal == true then
    return
  end
  if session.stage ~= "hangingUp" then
    if session.stage == "waitPress" then
      self:_playSequence(PhoneCall.SELECT_SEQUENCE)
    end
    self:_playSequence(PhoneCall.HANGUP_SEQUENCE)
  end
  self:_finishHangup(session)
end

-- Releases a call handle. Terminal handles leave their effects in
-- place; a live handle finishes at once through the same no-rollback
-- path as cancel, without staging timers or tones.
---@param handle { id: string }
function PhoneCall:release(handle)
  local session = checkHandle(self, handle)
  if session.terminal ~= true then
    self:_finishHangup(session)
  end
  self._calls[
    session.id --[[@as string]]
  ] = nil
end

-- The single field rematch query for a contact: the native trainer tier the
-- saved invitation resolves to, or numeric zero when none is on offer.
---@param contact string
---@return { ready: boolean, trainerId: integer }
function PhoneCall:queryRematch(contact)
  return TrainerPhonePrograms.query(contact, self._world, self._catalog)
end

-- Projects the map marker from the same resolved readiness.
---@param contact string
---@return { trainerId: integer, ready: boolean }
function PhoneCall:rematchMarker(contact)
  return TrainerPhonePrograms.marker(contact, self._world, self._catalog)
end

-- Ends the contact's saved rematch invitation at the source's own clear.
---@param contact string
---@return { contact: string, ready: boolean }
function PhoneCall:clearRematchSeeking(contact)
  return TrainerPhonePrograms.clearSeeking(contact, self._world)
end

return PhoneCall
