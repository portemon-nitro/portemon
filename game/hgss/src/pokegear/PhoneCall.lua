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
PhoneCall.HANGUP_SEQUENCE = "SEQ_SE_GS_PHONE_OFF"
-- The three staged hangup messages, read through the shared UI message
-- reader: the first prints on hangup entry, the other two each follow
-- an eleven-tick post-increment wait, and a third wait ends the call.
PhoneCall.HANGUP_MESSAGE_ENTRIES = { 33, 34, 35 }

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
-- kind, message references, and signal before taking the single call
-- lease; branch-required facts are preflighted at their stage, not
-- here. An invalid signal takes no lease and selects no program.
-- Scripted field calls thread their source isScriptedCall/callScriptID
-- through the request so the native selector sees scriptedCall==2
-- first, before localMap (retail order).
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
  self._calls[args.id] = session
  self._active = args.id
  local audio = self._audio
  if type(audio) == "table" and audio.playDialing ~= nil then
    local dial = audio.playDialing --[[@as fun(self: table<string, unknown>)]]
    dial(audio)
    dial(audio)
  elseif type(audio) == "table" and type(audio.play) == "function" then
    local play = audio.play --[[@as fun(self: table<string, unknown>, sequence: string)]]
    play(audio, PhoneCall.DIAL_SEQUENCE)
    play(audio, PhoneCall.DIAL_SEQUENCE)
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

---@param session table<string, unknown>
---@param record table<string, unknown>
local function selectNativeScript(session, record)
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
    if scripted == 2 then
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
      session.dynamicElm = true
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
    elseif facts.nationalDex == true then
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
      session.scriptId = facts.predefinedScript
    else
      local safariVar = facts.safariTest
      if type(safariVar) == "number" then
        session.scriptId = 147 + safariVar
      end
    end
  elseif session.family == "kenji" then
    if nativeFacts.localMap then
      session.scriptId = 86
    elseif facts.waitExpired == true then
      session.scriptId = 88
    elseif facts.kenjiActive == true then
      session.scriptId = 87
    else
      session.dynamicKenji = true
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
  elseif session.family == "gym" or session.family == "rematch" or session.family == "trainer" then
    if nativeFacts.localMap and record.localScript ~= nil then
      session.scriptId = record.localScript
    elseif session.direction == "incoming" then
      session.scriptId = facts.predefinedScript
    else
      session.dynamicGeneric = true
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
    if nativeFacts.localMap and record.localScript ~= nil then
      session.scriptId = record.localScript
    elseif session.direction == "incoming" then
      session.scriptId = facts.predefinedScript
    else
      session.dynamicGeneric = true
    end
  end
  if session.dynamicMother == true then
    return
  end
  if
    session.dynamicBill == true
    or session.dynamicKurt == true
    or session.dynamicDaycareMan == true
    or session.dynamicDaycareLady == true
    or session.dynamicElm == true
    or session.dynamicOak == true
    or session.dynamicKenji == true
    or session.dynamicGeneric == true
    or session.dynamicFriendIncoming == true
    or session.dynamicFriend == true
    or session.dynamicBuenaIncoming == true
    or session.dynamicBuena == true
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
---@return string|{ status: string, entry: integer? } program step result ("waiting"|"done" or { status: string, entry: integer? } for dynamic lines)
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

---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown> resolved native dialogue
local function resolveNativeDialogue(messages, session)
  selectNativeScript(session, session.record --[[@as table<string, unknown>]])
  if session.dynamicMother == true then
    local entry = MotherPhoneProgram.introEntry(session.facts --[[@as table<string, unknown>]])
    return resolveMotherEntry(messages, session, entry)
  end
  if
    session.dynamicBill == true
    or session.dynamicKurt == true
    or session.dynamicDaycareMan == true
    or session.dynamicDaycareLady == true
    or session.dynamicElm == true
    or session.dynamicOak == true
    or session.dynamicKenji == true
    or session.dynamicGeneric == true
    or session.dynamicFriendIncoming == true
    or session.dynamicFriend == true
    or session.dynamicBuenaIncoming == true
    or session.dynamicBuena == true
  then
    local failure = Errors.new(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "native phone dynamic handler needs its save-owned program wiring for " .. tostring(session.family),
      { family = session.family, contact = session.contact, program = session.program }
    )
    error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
  end
  local scriptId = session.scriptId
  local resolveLine = messages.resolveLine
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

-- Reads one localized hangup message through the shared UI message
-- reader. No literal text lives in the session.
---@param entryId integer bank271 hangup entry number
---@return table<string, unknown> the printable speech line
function PhoneCall:_hangupText(entryId)
  local resolveUi = self._messages.resolvePhoneUiMessage
  assert(type(resolveUi) == "function", "phone hangup text resolves through the shared UI message reader")
  local record = resolveUi(self._messages, entryId)
  assert(type(record) == "table" and type(record.text) == "string", "phone hangup entries resolve to printable text")
  return { text = record.text, tokens = record.tokens }
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
  session.lines = { self:_hangupText(PhoneCall.HANGUP_MESSAGE_ENTRIES[1]) }
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
    session.lines = { self:_hangupText(PhoneCall.HANGUP_MESSAGE_ENTRIES[2]) }
    session.textPage = 1
    return false
  end
  if sub == 2 then
    session.lines = { self:_hangupText(PhoneCall.HANGUP_MESSAGE_ENTRIES[3]) }
    session.textPage = 1
    return false
  end
  self:_finishHangup(session)
  return true
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

-- Snapshots the owed savings choice: the source menu identity with the
-- two localized display labels in source order, plus the localized
-- choice prompt. Semantic answers stay with MotherPhoneProgram; the
-- session only carries display strings. Resolved once at choice entry
-- so detached views never fetch messages.
---@param session table<string, unknown>
function PhoneCall:_resolveChoiceLabels(session)
  local resolveUi = self._messages.resolvePhoneUiMessage
  assert(type(resolveUi) == "function", "phone choices resolve through the shared UI message reader")
  local first = resolveUi(self._messages, 8)
  local second = resolveUi(self._messages, 9)
  local prompt = resolveUi(self._messages, 22)
  assert(type(first) == "table" and type(first.text) == "string", "phone choice entries resolve to printable text")
  assert(type(second) == "table" and type(second.text) == "string", "phone choice entries resolve to printable text")
  assert(type(prompt) == "table" and type(prompt.text) == "string", "phone choice prompt resolves to printable text")
  session.menuId = 2
  session.choiceLabels = { first.text, second.text }
  session.choiceTooltip = prompt.text
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
      session.stage = "greeting"
      enterStage(session)
    elseif stage == "greeting" then
      if session.program == nil then
        self:_selectProgramAtGreeting(session)
        self:_openProgramSession(session)
      end
      local ok, formatted = pcall(resolveNativeDialogue, self._messages, session)
      if not ok then
        self:_failCall(session, formatted)
        return
      end
      assert(
        type(formatted) == "table" and type(formatted.tokens) == "table",
        "phone dialogue returns formatted source tokens"
      )
      session.lines = self:_pagesFromTokens(formatted.tokens)
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
        -- Dynamic Mother prompt: resolve the staged prompt entry so the
        -- choice views the retail prompt text before answering.
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
      -- Dynamic Mother terminal entries (gift-full 21, result 25/26):
      -- show the staged pages in a result stage before hangup.
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
      self:_beginHangup(session)
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
      self:_beginHangup(session)
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
      self:_beginHangup(session)
      return
    elseif stage == "hangingUp" then
      self:_advanceHangup(session)
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
    local flag = record.param1
    assert(flag ~= nil, "phone flag effects name their flag")
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
    local world = self._world --[[@as table<string, unknown>]]
    local words = world.wordBuffer
    if type(words) ~= "table" then
      words = {}
      world.wordBuffer = words
    end
    (words --[[@as table<string, unknown>]])[contact] = { base = record.param1, pick = pick }
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
  if stage == "greeting" or stage == "message" or stage == "program" or stage == "result" then
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
    -- Only the savings choice waits for input today; the owed choice
    -- ids stay with the program that defines them so a new waiting
    -- program cannot silently inherit these. Display labels and the
    -- choice prompt ride along in the same order; game effects only
    -- read the semantic ids.
    assert(session.owner == "mother", "only the savings choice waits for input")
    shown.choices = { MotherPhoneProgram.CHOICES[1], MotherPhoneProgram.CHOICES[2] }
    assert(session.menuId == 2, "the savings choice carries its menu identity")
    local labels = session.choiceLabels
    assert(type(labels) == "table" and #labels == 2, "the savings choice carries its localized display labels")
    local tooltip = session.choiceTooltip
    assert(type(tooltip) == "string", "the savings choice carries its localized prompt")
    shown.menuId = session.menuId
    shown.choiceLabels = { labels[1], labels[2] }
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
-- terminal call stays untouched. Committed effects are always kept;
-- the staged timer path belongs to stepped player hangups.
---@param handle { id: string }
---@param reason string hangup reason
function PhoneCall:cancel(handle, reason)
  local session = checkHandle(self, handle)
  assert(type(reason) == "string" and reason ~= "", "phone cancellation names its reason")
  if session.terminal == true then
    return
  end
  if session.stage ~= "hangingUp" then
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

-- The single field readiness query for a contact, projected from durable
-- state through the native contact window.
---@param contact string
---@return { ready: boolean, tier: integer? }
function PhoneCall:queryRematch(contact)
  return TrainerPhonePrograms.query(contact, self._world, self._catalog)
end

-- Projects the map marker from the same durable record and native window.
---@param contact string
---@return { tier: integer?, ready: boolean }
function PhoneCall:rematchMarker(contact)
  return TrainerPhonePrograms.marker(contact, self._world, self._catalog)
end

-- Launches the accepted rematch at the queried tier.
---@param contact string
---@param world table<string, unknown>? the already composed world, when explicitly supplied
---@return { tier: integer, team: table<string, unknown> }
function PhoneCall:launchRematch(contact, world)
  assert(world == nil or world == self._world, "rematch launches cannot override the composed world")
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
