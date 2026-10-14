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
local bit = require("bit")

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
  facts.scriptedCallType = kind == "predefined" and 2 or 0
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

---@param session table<string, unknown>
---@param decision table<string, unknown>
local function unsupportedNativeProgram(session, decision)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "native phone conversation has no verified family handler",
    { contact = session.contact, family = session.family, mode = decision.mode, scriptType = decision.scriptType }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
end

---@param session table<string, unknown>
---@param fact string
local function missingSelectorFact(session, fact)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "native phone selector is missing the " .. fact .. " source fact",
    { contact = session.contact, family = session.family, fact = fact }
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
---@param args { id: string, contact: string, direction: string, kind: string, triggerKey: string?, scriptedCallType: integer?, predefinedScriptId: integer? }
---@return { id: string } typed call handle
function PhoneCall:begin(args)
  assert(type(args) == "table", "phone calls open through a request record")
  assert(type(args.id) == "string" and args.id ~= "", "phone calls carry a stable runtime id")
  assert(type(args.contact) == "string" and args.contact ~= "", "phone calls name their contact")
  assert(PhoneCall.DIRECTIONS[args.direction] == true, "phone calls name an incoming or outgoing direction")
  assert(PhoneCall.KINDS[args.kind] == true, "phone calls name a known source call kind")
  assert(
    (args.scriptedCallType == nil and args.predefinedScriptId == nil)
      or (
        (args.scriptedCallType == 2 or args.scriptedCallType == 3)
        and type(args.predefinedScriptId) == "number"
        and args.predefinedScriptId % 1 == 0
        and args.predefinedScriptId >= 0
        and (args.scriptedCallType ~= 2 or args.predefinedScriptId <= 4)
      ),
    "scripted incoming calls carry their source predefined script identity"
  )
  if self._calls[args.id] ~= nil then
    error("a phone call id opens once", 0)
  end
  local record = findContact(self._catalog, args.contact)
  if registeredContacts(self._state)[args.contact] ~= true then
    unacquiredContact(args.contact)
  end
  local canCall = self._world.canCall
  assert(type(canCall) == "function", "phone call admission reads the native map permission")
  local permitted = canCall(self._world, args.direction)
  assert(type(permitted) == "boolean", "phone call admission returns a strict permission boolean")
  if not permitted then
    local handle = { id = args.id }
    self._calls[args.id] = {
      id = args.id,
      handle = handle,
      stage = "noSignal",
      terminal = true,
      result = { signal = false, ready = false },
    }
    return handle
  end
  if self._active ~= nil then
    error("a foreground phone call already owns the line", 0)
  end
  local greeting = frozenGreeting(self._messages)
  local handle = { id = args.id }
  local facts = snapshotFacts(self._world, args.kind, args.direction, record)
  if args.scriptedCallType ~= nil then
    facts.scriptedCallType = args.scriptedCallType
    facts.predefinedScript = args.predefinedScriptId
  end
  if record.family == "mother" and args.direction == "incoming" then
    local phone = self._state.readPhone(self._state)
    local mom = phone.mom
    assert(type(mom) == "table" and type(mom.gifts) == "table", "incoming Mom calls inspect the gift queue")
    facts.giftPending = #mom.gifts > 0
  end
  local session = {
    id = args.id,
    handle = handle,
    contact = args.contact,
    direction = args.direction,
    kind = args.kind,
    triggerKey = args.triggerKey,
    world = self._world,
    catalog = self._catalog,
    random = self._random,
    record = record,
    greeting = greeting,
    facts = facts,
    owner = nil,
    family = nil,
    program = nil,
    programSession = nil,
    scriptId = nil,
    lines = nil,
    textPage = 1,
    stage = "connecting",
    position = 1,
    ticks = 0,
    terminal = false,
    failed = nil,
    result = nil,
    hangupDone = false,
  }
  local owner, family = resolveFamily(record)
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
  return handle
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
  if session == nil or session.handle ~= handle then
    error("a stale phone handle never acts on a new call", 0)
  end
  return session
end

---@return boolean waiting true while the effect player has not completed
function PhoneCall:_audioWait()
  local audio = self._audio
  if
    type(audio) ~= "table"
    or type(audio.playDialing) ~= "function"
    or type(audio.isEffectWaitComplete) ~= "function"
  then
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
---@param record table<string, unknown>
local function selectNativeDecision(session, record)
  local world = session.world --[[@as table<string, unknown>]]
  local readFacts = world.nativeSelectorFacts
  assert(type(readFacts) == "function", "native script selection reads source selector facts")
  local nativeFacts = readFacts(world, record)
  assert(type(nativeFacts) == "table", "native selector returns a fact record")
  local selectorFacts = {}
  for key, value in pairs(nativeFacts) do
    selectorFacts[key] = value
  end
  for key, value in
    pairs(session.facts --[[@as table<string, unknown>]])
  do
    selectorFacts[key] = value
  end
  local family = session.family --[[@as string]]
  local direction = session.direction --[[@as string]]
  if family == "mother" then
    local decision = MotherPhoneProgram.selectNative(direction, record, selectorFacts)
    session.decision = decision
    session.scriptId = decision.scriptId
    return
  elseif family == "oak" then
    local decision = ProfessorPhonePrograms.selectOakNative(direction, record, selectorFacts)
    session.decision = decision
    session.scriptId = decision.scriptId
    return
  elseif family == "elm" then
    local decision = ProfessorPhonePrograms.selectElmNative(
      direction --[[@as "incoming"|"outgoing"]],
      session.contact --[[@as string]],
      selectorFacts,
      session.random
    )
    session.decision = decision
    session.scriptId = decision.scriptId
    return
  elseif family == "gym" then
    session.decision = { mode = "special", scriptType = direction == "incoming" and 14 or 13, family = "gym" }
    return
  elseif family == "kurt" then
    if nativeFacts.localMap == true then
      session.decision = { mode = "numeric", scriptId = 83, family = "kurt" }
      session.scriptId = 83
    else
      session.decision = { mode = "special", scriptType = 12, family = "kurt" }
    end
    return
  elseif family == "bike" then
    if type(nativeFacts.localMap) ~= "boolean" then
      missingSelectorFact(session, "map locality")
    end
    session.decision = { mode = "numeric", scriptId = nativeFacts.localMap and 84 or 85, family = family }
    session.scriptId = session.decision.scriptId
    return
  elseif family == "bill" then
    if direction == "incoming" then
      session.decision = { mode = "numeric", scriptId = 93, family = family }
    elseif type(nativeFacts.localMap) ~= "boolean" then
      missingSelectorFact(session, "map locality")
    elseif nativeFacts.localMap then
      session.decision = { mode = "numeric", scriptId = 92, family = family }
    else
      session.decision = { mode = "special", scriptType = 3, family = family }
    end
    session.scriptId = session.decision.scriptId
    return
  elseif family == "friend" then
    if direction == "incoming" then
      session.decision = { mode = "special", scriptType = 11, family = family }
    elseif type(nativeFacts.localMap) ~= "boolean" then
      missingSelectorFact(session, "map locality")
    elseif nativeFacts.localMap then
      local gender = nativeFacts.playerGender
      if gender ~= 0 and gender ~= 1 then
        missingSelectorFact(session, "player gender")
      end
      session.decision = { mode = "numeric", scriptId = gender == 0 and 101 or 102, family = family }
      session.scriptId = session.decision.scriptId
    else
      session.decision = { mode = "special", scriptType = 10, family = family }
    end
    return
  elseif family == "daycare" then
    local callerId = record.id
    if callerId == 6 then
      if direction == "incoming" then
        if type(selectorFacts.eggCallPending) ~= "boolean" then
          missingSelectorFact(session, "pending Egg call flag")
        end
        session.decision = {
          mode = "numeric",
          scriptId = selectorFacts.eggCallPending and 96 or 95,
          family = family,
        }
        session.scriptId = session.decision.scriptId
      else
        session.decision = { mode = "special", scriptType = 7, family = family }
      end
      return
    elseif callerId == 7 then
      if type(selectorFacts.localMap) ~= "boolean" then
        missingSelectorFact(session, "map locality")
      end
      if selectorFacts.localMap then
        session.decision = { mode = "numeric", scriptId = 97, family = family }
        session.scriptId = 97
      else
        session.decision = { mode = "special", scriptType = 6, family = family }
      end
      return
    end
    unsupportedNativeProgram(session, { mode = "daycare-contact", contactId = callerId })
  elseif family == "buena" then
    if type(selectorFacts.rocketTakeoverActive) ~= "boolean" then
      missingSelectorFact(session, "Rocket takeover state")
    end
    if selectorFacts.rocketTakeoverActive then
      session.decision = { mode = "numeric", scriptId = 99, family = family }
    elseif direction == "incoming" then
      session.decision = { mode = "special", scriptType = 9, family = family }
    elseif type(selectorFacts.hour) ~= "number" then
      missingSelectorFact(session, "civil hour")
    elseif selectorFacts.hour % 3 == 2 then
      session.decision = { mode = "numeric", scriptId = 100, family = family }
    elseif selectorFacts.localMap == true then
      session.decision = { mode = "numeric", scriptId = 98, family = family }
    else
      session.decision = { mode = "special", scriptType = 8, family = family }
    end
    session.scriptId = session.decision.scriptId
    return
  elseif family == "baoba" then
    if selectorFacts.scriptedCallType == 2 then
      session.decision = { mode = "numeric", scriptId = 141, family = family }
    elseif direction == "incoming" then
      if selectorFacts.predefinedScript ~= nil then
        local scriptId = selectorFacts.predefinedScript
        if type(scriptId) ~= "number" or scriptId % 1 ~= 0 then
          missingSelectorFact(session, "incoming predefined Safari script")
        end
        session.decision = { mode = "numeric", scriptId = scriptId, family = family }
      else
        session.decision = { mode = "special", scriptType = 15, family = family }
      end
    elseif selectorFacts.localMap == true then
      session.decision = { mode = "numeric", scriptId = 140, family = family }
    elseif type(selectorFacts.baobaProgress) == "number" then
      session.decision = { mode = "numeric", scriptId = selectorFacts.baobaProgress + 147, family = family }
    else
      missingSelectorFact(session, "Safari Zone progression variable")
    end
    session.scriptId = session.decision.scriptId
    return
  elseif family == "kenji" then
    local selected = TrainerPhonePrograms.selectKenjiNative(selectorFacts)
    if selected.activate then
      local applyEffect = world.applyKenjiActiveEffect
      assert(type(applyEffect) == "function", "Kenji selection commits active and seeking facts through the save owner")
      local deferredEffects = session.deferredEffects or {}
      session.deferredEffects = deferredEffects
      local function commitKenjiSelection()
        applyEffect(world, session.contact)
      end
      deferredEffects[#deferredEffects + 1] = commitKenjiSelection
    end
    session.decision = { mode = "numeric", scriptId = selected.scriptId, family = family }
    session.scriptId = session.decision.scriptId
    return
  elseif family == "irwin" then
    if direction == "outgoing" then
      if type(selectorFacts.rocketTakeoverActive) ~= "boolean" then
        missingSelectorFact(session, "Rocket takeover state")
      end
      local scriptId = 156
      if not selectorFacts.rocketTakeoverActive then
        local random = session.random --[[@as table<string, unknown>?]]
        local draw = type(random) == "table" and random.lc or nil
        if type(draw) ~= "function" then
          missingSelectorFact(session, "Irwin's native random stream")
        end
        local drawRandom = draw --[[@as fun(self: table<string, unknown>, label: string): integer]]
        scriptId = 172 + drawRandom(random --[[@as table<string, unknown>]], "irwin-call-random") % 3
      end
      session.decision = { mode = "numeric", scriptId = scriptId, family = family }
      session.scriptId = scriptId
      return
    end
    local effect = TrainerPhonePrograms.selectIrwinIncoming(selectorFacts)
    local applyEffect = world.applyIrwinIncomingEffect
    assert(type(applyEffect) == "function", "Irwin selection commits its source flag effects through the world owner")
    local deferredEffects = session.deferredEffects or {}
    session.deferredEffects = deferredEffects
    local function commitIrwinSelection()
      applyEffect(world, effect)
    end
    deferredEffects[#deferredEffects + 1] = commitIrwinSelection
    session.decision = { mode = "numeric", scriptId = effect.scriptId, family = family }
    session.scriptId = effect.scriptId
    return
  elseif family == "trainer" then
    if direction == "outgoing" and nativeFacts.localMap == true then
      local localScript = record.localScript
      if type(localScript) ~= "number" or localScript < 1 then
        missingSelectorFact(session, "local contact script")
      end
      session.decision = { mode = "numeric", scriptId = localScript, scriptType = 0, family = family }
      session.scriptId = localScript
      return
    end
    local headers = record.genericCallHeaders --[[@as table<string, unknown>]]
    assert(type(headers) == "table", "native generic callers have compiled source headers")
    local rows = headers[direction] --[[@as table<integer, table<string, unknown>>]]
    assert(type(rows) == "table" and #rows == 8, "native generic calls inspect eight ordered source slots")
    local last = nil
    local random = session.random --[[@as table<string, unknown>?]]
    local draw = type(random) == "table" and random.mt or nil
    local function chance(percent)
      if type(draw) ~= "function" then
        missingSelectorFact(session, "native generic-call random stream")
      end
      local drawRandom = draw --[[@as fun(self: table<string, unknown>, label: string): integer]]
      local first = drawRandom(random --[[@as table<string, unknown>]], "generic-call-header-chance")
      local second = drawRandom(random --[[@as table<string, unknown>]], "generic-call-header-chance")
      local combined = bit.bxor(first, second)
      local folded = bit.band(bit.bxor(bit.band(combined, 0xffff), bit.rshift(combined, 8)), 0xffff) % 100
      return folded <= percent
    end
    for _, header in ipairs(rows) do
      local headerType = header.type --[[@as integer]]
      if headerType == 0 or headerType == 255 then
        break
      end
      last = header
      local eligible = false
      if headerType == 1 or headerType == 6 then
        eligible = chance(header.chance --[[@as integer]])
      elseif headerType == 2 then
        if type(selectorFacts.seeking) ~= "boolean" then
          missingSelectorFact(session, "rematch-seeking state")
        end
        if not selectorFacts.seeking then
          if type(selectorFacts.pendingGenericGift) ~= "boolean" then
            missingSelectorFact(session, "pending generic gift state")
          end
          if not selectorFacts.pendingGenericGift then
            local catalog = session.catalog --[[@as table<string, unknown>]]
            local definitions = catalog.callDefinitions --[[@as table<integer, table<string, unknown>>]]
            local definition = definitions[
              header.scriptId --[[@as integer]]
            ]
            assert(type(definition) == "table", "generic headers refer to native script definitions")
            eligible = (
              selectorFacts.radioTowerBeaten == true
              or header.scriptType ~= 0
              or definition.kind ~= "rematch"
            ) and chance(header.chance --[[@as integer]])
          end
        end
      elseif headerType == 3 then
        if type(selectorFacts.radioTowerBeaten) ~= "boolean" then
          missingSelectorFact(session, "Radio Tower story flag")
        end
        if selectorFacts.radioTowerBeaten then
          if type(selectorFacts.weekday) ~= "number" or type(selectorFacts.timeOfDay) ~= "number" then
            missingSelectorFact(session, "rematch weekday and time")
          end
          eligible = selectorFacts.weekday == record.rematchWeekday
            and selectorFacts.timeOfDay == record.rematchTime
            and chance(header.chance --[[@as integer]])
        end
      elseif headerType == 4 then
        if type(selectorFacts.weekday) ~= "number" then
          missingSelectorFact(session, "weekday")
        end
        eligible = (selectorFacts.weekday == 2 or selectorFacts.weekday == 4 or selectorFacts.weekday == 6)
          and chance(header.chance --[[@as integer]])
      elseif headerType == 5 then
        if type(selectorFacts.rocketTakeoverActive) ~= "boolean" then
          missingSelectorFact(session, "Rocket takeover state")
        end
        eligible = selectorFacts.rocketTakeoverActive and chance(header.chance --[[@as integer]])
      elseif headerType == 7 then
        if type(selectorFacts.radioTowerBeaten) ~= "boolean" then
          missingSelectorFact(session, "Radio Tower story flag")
        end
        if selectorFacts.radioTowerBeaten then
          if
            type(selectorFacts.nationalParkCaller) ~= "boolean" or type(selectorFacts.bugContestActive) ~= "boolean"
          then
            missingSelectorFact(session, "National Park Bug Contest state")
          end
          if not (selectorFacts.nationalParkCaller and selectorFacts.bugContestActive) then
            if type(selectorFacts.seeking) ~= "boolean" then
              missingSelectorFact(session, "rematch-seeking state")
            end
            eligible = selectorFacts.seeking and chance(header.chance --[[@as integer]])
          end
        end
      elseif headerType == 8 then
        if type(selectorFacts.nationalParkCaller) ~= "boolean" or type(selectorFacts.bugContestActive) ~= "boolean" then
          missingSelectorFact(session, "National Park Bug Contest state")
        end
        if not (selectorFacts.nationalParkCaller and selectorFacts.bugContestActive) then
          if type(selectorFacts.pendingGenericGift) ~= "boolean" then
            missingSelectorFact(session, "pending generic gift state")
          end
          eligible = selectorFacts.pendingGenericGift and chance(header.chance --[[@as integer]])
        end
      else
        unsupportedNativeProgram(session, { mode = "generic", headerType = headerType })
      end
      if eligible then
        session.decision = {
          mode = "numeric",
          scriptId = header.scriptId,
          scriptType = header.scriptType,
          family = family,
        }
        session.scriptId = header.scriptId
        return
      end
    end
    if last ~= nil then
      session.decision = {
        mode = "numeric",
        scriptId = last.scriptId,
        scriptType = last.scriptType,
        family = family,
      }
      session.scriptId = last.scriptId
      return
    end
    unsupportedNativeProgram(session, { mode = "generic-empty" })
    return
  end
  do
    local failure = Errors.new(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "native phone selector needs an unmodeled source branch for " .. tostring(session.family),
      { family = session.family, contact = session.contact, program = session.program }
    )
    error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
  end
end

---@param session table<string, unknown>
function PhoneCall:_selectProgramAtGreeting(session)
  selectNativeDecision(session, session.record --[[@as table<string, unknown>]])
  local decision = session.decision --[[@as table<string, unknown>]]
  session.program = session.family
    .. "-"
    .. (decision.mode == "numeric" and tostring(decision.scriptId) or tostring(decision.scriptType))
end

---@param session table<string, unknown>
function PhoneCall:_openProgramSession(session)
  if session.decision.mode == "numeric" then
    return
  end
  local request = {
    contact = session.contact,
    family = session.family,
    professor = session.family,
    facts = session.facts,
  }
  if session.family == "gym" then
    local draw = self._random ~= nil and self._random.lc or nil
    request.direction = session.direction
    request.decision = session.decision
    request.record = session.record
    request.nativeFacts = session.facts
    if type(draw) == "function" then
      local function drawGymMessage()
        return draw(self._random --[[@as table<string, unknown>]], "gym-incoming-message")
      end
      request.draw = drawGymMessage
    end
    session.programSession = TrainerPhonePrograms.selectNative(self._world, request)
    return
  end
  if session.family == "oak" then
    request.direction = session.direction
    request.decision = session.decision
    request.nativeFacts = session.facts
    session.programSession = ProfessorPhonePrograms.selectOakNativeSession(self._world, request)
    return
  end
  if session.family == "mother" and session.decision.mode == "special" then
    request.decision = session.decision
    request.nativeFacts = session.facts
    session.programSession = MotherPhoneProgram.selectNativeSession(self._world, request)
    local deferredEffect = session.programSession.deferredEffect
    if type(deferredEffect) == "function" then
      local deferredEffects = session.deferredEffects or {}
      session.deferredEffects = deferredEffects
      deferredEffects[#deferredEffects + 1] = deferredEffect
    end
    return
  end
  if session.family == "kurt" and session.decision.mode == "special" then
    request.decision = session.decision
    request.nativeFacts = session.facts
    session.programSession = ServicePhonePrograms.selectNativeKurt(self._world, request)
    return
  end
  if
    (
      session.family == "bill"
      or session.family == "friend"
      or session.family == "daycare"
      or session.family == "buena"
      or session.family == "baoba"
    ) and session.decision.mode == "special"
  then
    request.decision = session.decision
    request.nativeFacts = session.facts
    if
      session.family == "bill"
      or session.family == "friend"
      or session.family == "baoba"
      or session.family == "buena"
    then
      local draw = self._random ~= nil and self._random.lc or nil
      if type(draw) == "function" then
        local drawLabel = session.family == "baoba" and "baoba-incoming-message"
          or session.family == "bill" and "bill-response-message"
          or session.family == "friend" and "friend-response-message"
          or "buena-response-message"
        local function drawServiceMessage()
          return draw(self._random --[[@as table<string, unknown>]], drawLabel)
        end
        request.draw = drawServiceMessage
      end
    end
    session.programSession = ServicePhonePrograms.selectNativePage(request)
    return
  end
  unsupportedNativeProgram(session, session.decision --[[@as table<string, unknown>]])
  error("unreachable", 0)
end

---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string program step result
local function stepProgram(session, input)
  if session.programSession == nil then
    assert(session.decision.mode == "numeric", "only numeric calls skip a family session")
    return "done"
  end
  local programSession = session.programSession --[[@as table<string, unknown>]]
  if session.family == "oak" then
    return ProfessorPhonePrograms.step(programSession, input)
  end
  if session.family == "mother" then
    return MotherPhoneProgram.stepNative(programSession, input)
  end
  if session.family == "gym" then
    return TrainerPhonePrograms.step(programSession, input)
  end
  if session.family == "kurt" then
    if programSession.program == "kurt-native" then
      return ServicePhonePrograms.stepNativeKurt(programSession, input)
    end
    return ServicePhonePrograms.step(programSession, input)
  end
  if
    session.family == "bill"
    or session.family == "friend"
    or session.family == "daycare"
    or session.family == "buena"
    or session.family == "baoba"
  then
    return ServicePhonePrograms.stepNativePage(programSession, input)
  end
  unsupportedNativeProgram(session, session.decision --[[@as table<string, unknown>]])
  error("unreachable", 0)
end

---@param messages table<string, unknown>
---@param session table<string, unknown>
---@return table<string, unknown> resolved native dialogue
local function resolveNativeDialogue(messages, session)
  local decision = session.decision
  if type(decision) ~= "table" then
    selectNativeDecision(session, session.record --[[@as table<string, unknown>]])
    decision = session.decision
  end
  assert(type(decision) == "table", "a call freezes one native program decision")
  if decision.mode == "numeric" then
    local scriptId = decision.scriptId
    local scriptType = decision.scriptType
    local resolveLine = messages.resolveLine
    assert(type(scriptId) == "number", "numeric calls carry a source script identity")
    assert(type(resolveLine) == "function", "phone dialogue resolves through the field message provider")
    local variation = nil
    if scriptType == 2 then
      local random = session.random --[[@as table<string, unknown>?]]
      local draw = type(random) == "table" and random.lc or nil
      if type(draw) ~= "function" then
        missingSelectorFact(session, "generic type-two random stream")
      end
      local drawRandom = draw --[[@as fun(self: table<string, unknown>, label: string): integer]]
      variation = drawRandom(random --[[@as table<string, unknown>]], "generic-type-two-phrase") % 11
    end
    local substitutions = session.definitionSubstitutions --[[@as table<integer, unknown>?]]
    if scriptType == 1 then
      local timeOfDay = session.facts.timeOfDay
      if type(timeOfDay) ~= "number" then
        missingSelectorFact(session, "generic type-one time of day")
      end
      local world = session.world --[[@as table<string, unknown>]]
      local selectBuffers = world.genericTrainerSubstitutions
      if type(selectBuffers) ~= "function" then
        missingSelectorFact(session, "generic type-one trainer and encounter catalogs")
      end
      local buildBuffers = selectBuffers
      --[[@as fun(self: table<string, unknown>, contact: table<string, unknown>, random: table<string, unknown>, timeOfDay: integer): table<integer, string>]]
      local buffers = buildBuffers(world, session.record, session.random, timeOfDay --[[@as integer]])
      local merged = {}
      if type(substitutions) == "table" then
        for key, value in pairs(substitutions) do
          merged[key] = value
        end
      end
      for key, value in pairs(buffers) do
        merged[key] = value
      end
      substitutions = merged
    end
    return resolveLine(messages, session.contact, scriptId, scriptType, variation, substitutions)
  end
  assert(decision.mode == "special", "phone decisions distinguish numeric and special programs")
  local resolveEntry = messages.resolveContactEntry
  assert(type(resolveEntry) == "function", "special dialogue resolves direct caller-bank entries")
  -- Every native special program starts in its caller's phone message bank.
  -- The family state machine owns subsequent pages and choices.
  if
    session.family == "gym"
    or session.family == "oak"
    or session.family == "mother"
    or session.family == "kurt"
    or session.family == "bill"
    or session.family == "friend"
    or session.family == "daycare"
    or session.family == "buena"
    or session.family == "baoba"
  then
    local programSession = session.programSession --[[@as table<string, unknown>]]
    local entries = programSession.entries --[[@as table<integer, unknown>]]
    local tokens = {}
    for index, entry in ipairs(entries) do
      assert(type(entry) == "number" and entry % 1 == 0, "gym special entries use native bank indices")
      if index > 1 then
        tokens[#tokens + 1] = { kind = "page_break" }
      end
      local substitutionsByEntry = programSession.substitutionsByEntry
      local substitutions = type(substitutionsByEntry) == "table" and substitutionsByEntry[entry] or nil
      local formatted = resolveEntry(messages, session.contact, entry, substitutions)
      assert(
        type(formatted) == "table" and type(formatted.tokens) == "table",
        "native bank entries return formatted tokens"
      )
      for _, token in
        ipairs(formatted.tokens --[[@as table<integer, unknown>]])
      do
        tokens[#tokens + 1] = token
      end
    end
    return { tokens = tokens }
  end
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "native special phone script has no implemented family program",
    { family = session.family, scriptType = decision.scriptType, contact = session.contact }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
end

---@param messages table<string, unknown>
---@param session table<string, unknown>
---@param entry integer direct contact-bank entry
---@return table<string, unknown> formatted native text
local function resolveNativeEntry(messages, session, entry)
  local resolveEntry = messages.resolveContactEntry
  assert(type(resolveEntry) == "function", "special dialogue resolves direct caller-bank entries")
  local programSession = session.programSession --[[@as table<string, unknown>]]
  local substitutionsByEntry = programSession.substitutionsByEntry
  local substitutions = programSession.responseSubstitutions
    or (type(substitutionsByEntry) == "table" and substitutionsByEntry[entry] or nil)
  local formatted = resolveEntry(messages, session.contact, entry, substitutions)
  assert(
    type(formatted) == "table" and type(formatted.tokens) == "table",
    "native bank entries return formatted tokens"
  )
  return formatted --[[@as table<string, unknown>]]
end

---@param formatted table<string, unknown>
---@return table<integer, table<string, unknown>> native page lines
local function nativeLines(formatted)
  assert(type(formatted) == "table" and type(formatted.tokens) == "table", "native dialogue returns formatted tokens")
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
    ipairs(formatted.tokens --[[@as table<integer, unknown>]])
  do
    local item = token --[[@as table<string, unknown>]]
    if item.kind == "page_break" or item.kind == "prompt_break" then
      finishPage()
    elseif item.kind ~= "eos" then
      pageTokens[#pageTokens + 1] = item
    end
  end
  finishPage()
  assert(#lines > 0, "phone scripts produce at least one printable text page")
  return lines
end

---@param messages table<string, unknown>
---@param session table<string, unknown>
---@param entry integer
---@return table<integer, table<string, unknown>> validated native response pages
local function resolveNativeResponseLines(messages, session, entry)
  return nativeLines(resolveNativeEntry(messages, session, entry))
end

---@param programSession table<string, unknown>
local function commitNativeResponseEffect(programSession)
  local effect = programSession.responseEffect
  if type(effect) == "function" then
    effect()
    programSession.responseEffect = nil
  end
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
  if Errors.is(failure) or (type(failure) == "table" and type(failure.code) == "string") then
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

---@param session table<string, unknown>
---@param successful boolean?
function PhoneCall:_finishHangup(session, successful)
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
    local query = self._world.queryRematch
    local rematch = type(query) == "function" and query(self._world, session.contact --[[@as string]]) or nil
    local staged = type(rematch) == "table" and rematch.stage > 0
    if successful == false then
      session.result = {
        id = session.id,
        contact = session.contact,
        kind = session.kind,
        program = session.program,
        signal = false,
        ready = false,
      }
    else
      session.result = {
        id = session.id,
        contact = session.contact,
        kind = session.kind,
        program = session.program,
        ready = staged,
      }
    end
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
    self:_finishHangup(session, false)
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
      local random = session.random
      local checkpoint = nil
      if type(random) == "table" then
        local makeCheckpoint = random.checkpoint
        if type(makeCheckpoint) == "function" then
          checkpoint = makeCheckpoint(random)
        end
      end
      local function resolveCurrentNativeDialogue()
        if session.program == nil then
          self:_selectProgramAtGreeting(session)
          self:_openProgramSession(session)
        end
        local decision = session.decision --[[@as table<string, unknown>]]
        if decision.mode == "numeric" then
          local definitions = session.catalog.callDefinitions
          if type(definitions) == "table" and next(definitions) ~= nil then
            local definition = definitions[
              decision.scriptId --[[@as integer]]
            ]
            assert(type(definition) == "table", "native catalogs provide each selected call definition")
            if definition.kind ~= "none" then
              local prepareEffect = session.world.prepareCallDefinitionEffect
              assert(type(prepareEffect) == "function", "numeric call effects use the field world owner")
              local prepared = prepareEffect(session.world, session.contact, definition, session.random)
              assert(
                type(prepared) == "table"
                  and type(prepared.substitutions) == "table"
                  and type(prepared.commit) == "function",
                "numeric call effects prepare substitutions and one deferred commit"
              )
              session.definitionSubstitutions = prepared.substitutions
              session.preparedDefinitionEffect = prepared
            end
          end
        end
        return nativeLines(resolveNativeDialogue(self._messages, session))
      end
      local ok, lines = pcall(resolveCurrentNativeDialogue)
      if not ok then
        if checkpoint ~= nil then
          local restoreCheckpoint = random.restoreCheckpoint --[[@as fun(self: table<string, unknown>, checkpoint: table<string, unknown>)]]
          restoreCheckpoint(random --[[@as table<string, unknown>]], checkpoint)
        end
        self:_failCall(session, lines)
        return
      end
      local preparedEffect = session.preparedDefinitionEffect
      if type(preparedEffect) == "table" then
        local commit = preparedEffect.commit --[[@as fun()]]
        commit()
        session.preparedDefinitionEffect = nil
      end
      local deferredEffects = session.deferredEffects --[[@as table<integer, fun()>?]]
      if type(deferredEffects) == "table" then
        for _, commit in ipairs(deferredEffects) do
          commit()
        end
        session.deferredEffects = nil
      end
      session.lines = lines
      session.stage = "message"
      enterStage(session)
      return
    elseif stage == "message" then
      if not forced then
        return
      end
      forced = false
      local page = session.textPage --[[@as integer]]
      local lines = session.lines --[[@as table<integer, unknown>]]
      if page < #lines then
        session.textPage = page + 1
        enterStage(session)
        return
      end
      session.stage = "program"
      enterStage(session)
    elseif stage == "program" then
      local responseInput = session.responsePending == true and { responseResolved = true } or edges
      local ok, outcome = pcall(stepProgram, session, responseInput)
      if not ok then
        self:_failCall(session, outcome)
        return
      end
      if session.responsePending == true then
        session.responsePending = false
      end
      if outcome == "waiting" then
        session.stage = "choice"
        enterStage(session)
        return
      elseif outcome == "continue" then
        local programSession = session.programSession --[[@as table<string, unknown>]]
        local entry = programSession.responseEntry
        assert(type(entry) == "number", "native family continuations carry a bank entry")
        local resolvedOk, lines = pcall(resolveNativeResponseLines, self._messages, session, entry)
        if not resolvedOk then
          self:_failCall(session, lines)
          return
        end
        commitNativeResponseEffect(programSession)
        session.lines = lines --[[@as table<integer, table<string, unknown>>]]
        session.textPage = 1
        session.responsePending = true
        session.stage = "message"
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
        self:_failCall(session, outcome)
        return
      end
      if outcome == "waiting" then
        return
      end
      if outcome == "continue" then
        local programSession = session.programSession --[[@as table<string, unknown>]]
        local entry = programSession.responseEntry
        assert(type(entry) == "number", "native family choices carry a bank response")
        local resolvedOk, lines = pcall(resolveNativeResponseLines, self._messages, session, entry)
        if not resolvedOk then
          self:_failCall(session, lines)
          return
        end
        commitNativeResponseEffect(programSession)
        session.lines = lines --[[@as table<integer, table<string, unknown>>]]
        session.textPage = 1
        session.responsePending = true
        session.stage = "message"
        enterStage(session)
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
  if stage == "greeting" or stage == "message" or stage == "program" then
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

---@param value unknown
---@return unknown
local function detachValue(value)
  if type(value) ~= "table" then
    return value
  end
  if Errors.is(value) then
    ---@cast value Errors.Error
    return Errors.new(value.code, value.message, detachValue(value.context))
  end
  local detached = {}
  for key, nested in
    pairs(value --[[@as table<unknown, unknown>]])
  do
    detached[detachValue(key)] = detachValue(nested)
  end
  return detached
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
    lines = detachValue(session.lines),
    page = session.textPage,
  }
  if stage == "choice" then
    local programSession = session.programSession --[[@as table<string, unknown>]]
    if session.owner == "mother" then
      shown.choices = { MotherPhoneProgram.CHOICES[1], MotherPhoneProgram.CHOICES[2] }
    elseif session.owner == "trainer" and programSession.program == "gym-invitation" then
      shown.choices = { "yes", "no" }
    elseif session.owner == "professor" and programSession.program == "oak-special" then
      shown.choices = detachValue(programSession.choices)
    else
      error("phone choice stages have a family-owned choice list", 0)
    end
  end
  if session.result ~= nil then
    shown.result = detachValue(session.result)
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
  return detachValue(session.result)
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
  self:_finishHangup(session, false)
end

-- Releases a call handle. Terminal handles leave their effects in
-- place; a live handle hangs up first through the same no-rollback
-- path as cancel.
---@param handle { id: string }
function PhoneCall:release(handle)
  local session = checkHandle(self, handle)
  if session.terminal ~= true then
    enterStage(session)
    self:_finishHangup(session, false)
  end
  self._calls[
    session.id --[[@as string]]
  ] = nil
end

-- The single field readiness query for a contact, projected from durable
-- seeking through the native trainer selection.
---@param contact string
---@return { ready: boolean, trainerId: integer }
function PhoneCall:queryRematch(contact)
  return TrainerPhonePrograms.query(contact, self._world, self._catalog)
end

-- Projects the map marker from the same native trainer selection.
---@param contact string
---@return { ready: boolean, trainerId: integer }
function PhoneCall:rematchMarker(contact)
  return TrainerPhonePrograms.marker(contact, self._world, self._catalog)
end

-- Returns the source trainer identity for legacy callers; retail scripts
-- launch battles through their existing TrainerBattle opcode.
---@param contact string
---@param world table<string, unknown>? the already composed world, when explicitly supplied
---@return integer native trainer ID
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
