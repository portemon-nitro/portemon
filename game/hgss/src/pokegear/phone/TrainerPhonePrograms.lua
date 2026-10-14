-- Trainer policies: ordinary callers, gym leaders, Kenji, and Irwin,
-- plus the single rematch policy shared by outgoing invitations,
-- incoming-call effects, the field readiness query, and map markers.
-- Registration is never readiness: only a staged invitation makes a
-- contact ready, and only a source-qualified win clears it. Battle
-- launch carries the same tier the query reports. Pure source policy
-- over the borrowed world table, private to the foreground phone
-- feature.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@class TrainerPhonePrograms
local TrainerPhonePrograms = {}

---@param contact string
---@param fact string
local function missingNativeFact(contact, fact)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "native trainer conversation needs the " .. fact .. " source fact",
    { contact = contact, fact = fact }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
end

TrainerPhonePrograms.DEFAULT_GYM_WEEKDAY = "saturday"

local IRWIN_ONE_SHOT_FLAGS = {
  [168] = "FLAG_UNK_9A4",
  [167] = "FLAG_UNK_9A3",
  [166] = "FLAG_UNK_9A2",
  [165] = "FLAG_UNK_9A1",
  [163] = "FLAG_UNK_9A5",
  [160] = "FLAG_UNK_9A0",
  [159] = "FLAG_UNK_99F",
}

-- Chooses Irwin's incoming numeric script in source predicate order. The
-- returned event mutation payload is committed by PhoneCall after its
-- selected first page resolves.
---@param facts table<string, unknown> source flag and profile facts
---@return { scriptId: integer, clearInitialTrigger: boolean, setOneShotFlag: string? }
function TrainerPhonePrograms.selectIrwinIncoming(facts)
  assert(type(facts) == "table", "Irwin reads frozen native call facts")
  assert(type(facts.irwinInitialTrigger) == "boolean", "Irwin carries the native incoming trigger")
  assert(type(facts.badges) == "number" and facts.badges >= 0, "Irwin carries the badge count")
  for _, name in ipairs({
    "plainBadge",
    "fogBadge",
    "marshBadge",
    "risingBadge",
    "irwinNationalBadgeMessageSeen",
    "irwinMarshBadgeMessageSeen",
    "irwinSnorlaxMessageSeen",
    "irwinVermilionMessageSeen",
    "irwinVermilionEvent",
    "vermilionFlypoint",
    "gameClear",
    "irwinGameClearMessageSeen",
    "radioTowerBeaten",
    "rocketHideoutCleared",
    "irwinHideoutMessageSeen",
    "irwinUnknownProgress",
    "irwinUnknownProgressMessageSeen",
    "snorlaxMet",
  }) do
    assert(type(facts[name]) == "boolean", "Irwin selector facts include " .. name)
  end
  if facts.irwinInitialTrigger == true then
    local scriptId
    if facts.badges >= 16 then
      if not facts.irwinNationalBadgeMessageSeen then
        scriptId = 168
      end
    elseif facts.marshBadge then
      if not facts.irwinMarshBadgeMessageSeen then
        scriptId = 167
      end
    elseif facts.snorlaxMet then
      if not facts.irwinSnorlaxMessageSeen then
        scriptId = 166
      end
    elseif facts.irwinVermilionEvent then
      if not facts.irwinVermilionMessageSeen then
        scriptId = 165
      end
    elseif facts.vermilionFlypoint then
      scriptId = 164
    elseif facts.gameClear then
      if not facts.irwinGameClearMessageSeen then
        scriptId = 163
      end
    elseif facts.risingBadge then
      scriptId = 162
    elseif facts.radioTowerBeaten then
      scriptId = 161
    elseif facts.rocketHideoutCleared then
      if not facts.irwinHideoutMessageSeen then
        scriptId = 160
      end
    elseif facts.irwinUnknownProgress then
      if not facts.irwinUnknownProgressMessageSeen then
        scriptId = 159
      end
    elseif facts.fogBadge then
      scriptId = 158
    elseif facts.plainBadge then
      scriptId = 157
    end
    if scriptId ~= nil then
      return {
        scriptId = scriptId,
        clearInitialTrigger = true,
        setOneShotFlag = IRWIN_ONE_SHOT_FLAGS[scriptId],
      }
    end
  end
  if not facts.plainBadge then
    return { scriptId = 169, clearInitialTrigger = facts.irwinInitialTrigger == true }
  end
  if facts.badges < 16 then
    return { scriptId = 170, clearInitialTrigger = facts.irwinInitialTrigger == true }
  end
  return { scriptId = 171, clearInitialTrigger = facts.irwinInitialTrigger == true }
end

-- Rematch resolution outcomes that preserve the staged invitation: only
-- a qualified win clears readiness, so a full party, a blackout, a
-- loss, or a cancellation never completes a rematch spuriously.
TrainerPhonePrograms.PRESERVING_OUTCOMES = {
  loss = true,
  cancel = true,
  blackout = true,
  ["full-party"] = true,
}

-- Selects the trainer program identity for one named trainer family.
-- Pure dispatch over labelled facts with no owner reads.
---@param family string named trainer family
---@param facts table<string, unknown> labelled source facts for the caller
---@return string program identity
function TrainerPhonePrograms.selectName(family, facts)
  assert(type(family) == "string" and family ~= "", "trainer selection names its contact family")
  assert(type(facts) == "table", "trainer selection reads labelled facts")
  if family == "gym" or family == "rematch" then
    if facts.invitation == true then
      return "gym-invitation"
    end
    local window = facts.window --[[@as table<string, unknown>?]]
    local weekday = TrainerPhonePrograms.DEFAULT_GYM_WEEKDAY
    local morning = true
    if type(window) == "table" then
      if window.weekday ~= nil then
        assert(type(window.weekday) == "string", "rematch windows name their weekday")
        weekday = window.weekday --[[@as string]]
      end
      if window.morning ~= nil then
        assert(type(window.morning) == "boolean", "rematch windows name their morning half")
        morning = window.morning --[[@as boolean]]
      end
    end
    if facts.weekday == weekday and facts.morning == morning then
      return "gym-rematch"
    end
    return "gym-waiting"
  end
  if family == "kenji" then
    if facts.kenjiActive == true then
      return "kenji-active"
    end
    if facts.waitExpired == true then
      return "kenji-ready"
    end
    return "kenji-waiting"
  end
  if family == "irwin" then
    if facts.storyEvent == true then
      return "irwin-story"
    end
    return "irwin-greeting"
  end
  if facts.invitation == true then
    return "trainer-rematch"
  end
  return "trainer-ordinary"
end

-- Chooses Kenji's exact native numeric caller and returns the source
-- active-flag write for the eligible morning/day branch.
---@param facts table<string, unknown> frozen Kenji caller facts
---@return { scriptId: integer, activate: boolean }
function TrainerPhonePrograms.selectKenjiNative(facts)
  assert(type(facts) == "table", "Kenji selection reads frozen native facts")
  if type(facts.localMap) ~= "boolean" then
    missingNativeFact("kenji", "map locality")
  end
  if facts.localMap then
    return { scriptId = 86, activate = false }
  end
  local waitDays = facts.kenjiWaitDays
  if type(waitDays) ~= "number" or waitDays % 1 ~= 0 or waitDays < 0 then
    missingNativeFact("kenji", "wait days")
  end
  if waitDays > 1 then
    return { scriptId = 87, activate = false }
  end
  if waitDays == 1 then
    return { scriptId = 88, activate = false }
  end
  if type(facts.kenjiActive) ~= "boolean" then
    missingNativeFact("kenji", "active flag")
  end
  if facts.kenjiActive then
    if type(facts.seeking) ~= "boolean" then
      missingNativeFact("kenji", "rematch seeking state")
    end
    if not facts.seeking then
      return { scriptId = 87, activate = false }
    end
  end
  if type(facts.timeOfDay) ~= "number" or facts.timeOfDay % 1 ~= 0 or facts.timeOfDay < 0 or facts.timeOfDay > 2 then
    missingNativeFact("kenji", "time of day")
  end
  if facts.timeOfDay == 2 then
    return { scriptId = 91, activate = false }
  end
  return { scriptId = facts.timeOfDay == 1 and 90 or 89, activate = not facts.kenjiActive }
end

-- Opens a trainer program session over the borrowed world. Selection
-- itself never mutates; invitation readiness stages once at the
-- program stage through step.
---@param world table<string, unknown> borrowed world table
---@param request { contact: string, family: string, facts: table<string, unknown> }
---@return table<string, unknown> program session
function TrainerPhonePrograms.select(world, request)
  assert(type(world) == "table", "trainer programs borrow their world")
  assert(type(request) == "table" and type(request.contact) == "string", "trainer programs name their contact")
  assert(type(request.family) == "string", "trainer programs name their contact family")
  assert(type(request.facts) == "table", "trainer programs read labelled facts")
  return {
    program = TrainerPhonePrograms.selectName(request.family, request.facts),
    contact = request.contact,
    family = request.family,
    world = world,
    effectDone = false,
  }
end

-- Selects the pinned gym leader special script from one frozen native
-- decision and its call-entry facts. Script type 13 is outgoing; type 14
-- is incoming. Direct entry numbers and the invitation response follow
-- phone_scripts_gym_leader.c.
---@param world table<string, unknown> borrowed world table
---@param request table<string, unknown> native contact, decision, record, and facts
---@return table<string, unknown> native gym program session
function TrainerPhonePrograms.selectNative(world, request)
  assert(type(world) == "table", "native gym programs borrow their effect owner")
  assert(type(request) == "table", "native gym programs read a call request")
  assert(request.family == "gym", "native gym programs require the gym contact family")
  local decision = request.decision --[[@as table<string, unknown>]]
  assert(
    type(decision) == "table"
      and decision.mode == "special"
      and (decision.scriptType == 13 or decision.scriptType == 14),
    "native gym programs follow the frozen incoming or outgoing special script"
  )
  local facts = request.nativeFacts --[[@as table<string, unknown>]]
  assert(type(facts) == "table", "native gym programs use frozen source facts")
  local contact = request.contact --[[@as string]]
  assert(type(contact) == "string" and contact ~= "", "native gym programs preserve contact identity")

  local session = {
    program = decision.scriptType == 13 and "gym-outgoing" or "gym-incoming",
    contact = contact,
    world = world,
    nativeFacts = facts,
    draw = request.draw,
    effectDone = false,
    entries = {},
  }
  if decision.scriptType == 14 then
    if type(facts.seeking) ~= "boolean" then
      missingNativeFact(contact, "rematch seeking")
    end
    session.entries = { 10 }
    return session
  end

  if type(facts.localMap) ~= "boolean" then
    missingNativeFact(contact, "map locality")
  end
  if facts.localMap then
    session.entries = { 1 }
    return session
  end
  if type(facts.badges) ~= "number" then
    missingNativeFact(contact, "badge count")
  end
  if facts.badges < 16 then
    session.entries = { 2, 3 }
    return session
  end
  if type(facts.seeking) ~= "boolean" then
    missingNativeFact(contact, "rematch seeking")
  end
  if facts.seeking then
    session.entries = { 2, 9 }
    return session
  end
  local record = request.record --[[@as table<string, unknown>]]
  assert(type(record) == "table", "gym calls read their compiled phonebook record")
  assert(
    type(record.rematchWeekday) == "number" and type(record.rematchTime) == "number",
    "gym calls use their native weekday and time window"
  )
  if type(facts.weekday) ~= "number" or type(facts.timeOfDay) ~= "number" then
    missingNativeFact(contact, "weekday and time")
  end
  if facts.weekday ~= record.rematchWeekday or facts.timeOfDay ~= record.rematchTime then
    session.entries = { 2, 4 }
    return session
  end
  if type(facts.dojoHasRoom) ~= "boolean" then
    missingNativeFact(contact, "dojo availability")
  end
  session.entries = { 2, 5 }
  session.program = "gym-invitation"
  session.invitationAvailable = facts.dojoHasRoom
  return session
end

-- Advances the selected native gym program through its message and choice
-- stages. Returns done once the branch resolves.
---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string "done"
function TrainerPhonePrograms.step(session, input)
  assert(type(session) == "table", "trainer programs step their session")
  assert(type(input) == "table", "trainer programs read their input")
  assert(type(session.program) == "string", "trainer sessions carry their program")
  assert(type(session.contact) == "string", "trainer sessions carry their contact")
  if session.program == "gym-incoming" then
    if session.effectDone == true then
      return "done"
    end
    local facts = session.nativeFacts --[[@as table<string, unknown>]]
    assert(type(facts.seeking) == "boolean", "incoming gym calls retain their frozen seeking value")
    if facts.seeking then
      session.responseEntry = 11
    else
      local draw = session.draw --[[@as fun(): integer]]
      assert(type(draw) == "function", "incoming gym calls draw their source response after the opening page")
      session.responseEntry = 12 + draw() % 3
    end
    session.effectDone = true
    return "continue"
  end
  if session.program == "gym-outgoing" then
    session.effectDone = true
    return "done"
  end
  if session.effectDone == true then
    return "done"
  end
  if session.program == "gym-invitation" then
    local choice = input.choice
    if session.responseEntry ~= nil then
      if input.responseResolved ~= true then
        return "waiting"
      end
      if session.responseEntry == 6 then
        local world = session.world --[[@as table<string, unknown>]]
        local query = world.queryRematch
        local write = world.setRematch
        assert(type(query) == "function" and type(write) == "function", "gym invitations use durable rematch state")
        local previous = query(world, session.contact --[[@as string]])
        local wins = type(previous) == "table" and previous.wins or 0
        write(world, session.contact --[[@as string]], { stage = 1, wins = wins })
      end
      session.effectDone = true
      return "done"
    end
    if choice == nil then
      return "waiting"
    end
    assert(choice == "yes" or choice == "no", "gym invitations accept the source yes or no choice")
    if choice == "yes" then
      session.responseEntry = session.invitationAvailable and 6 or 8
    else
      session.responseEntry = 7
    end
    return "continue"
  end
  session.effectDone = true
  return "done"
end

-- Reports a story tier only when the runtime has source facts for it.
---@param world table<string, unknown> borrowed world table
---@return integer? story tier
function TrainerPhonePrograms.tierFor(world)
  assert(type(world) == "table", "rematch tiers read the borrowed world")
  local tier = world.storyTier
  if tier == nil then
    return nil
  end
  assert(type(tier) == "number" and tier % 1 == 0 and tier >= 1, "the story tier stays a positive integer")
  return tier --[[@as integer]]
end

---@param contact string
---@param catalog table<string, unknown>?
---@return { weekday: number, timeOfDay: number }? native contact window
local function catalogWindow(contact, catalog)
  if type(catalog) ~= "table" then
    return nil
  end
  local contacts = catalog.contacts
  if type(contacts) ~= "table" then
    return nil
  end
  for _, entry in
    ipairs(contacts --[[@as table<integer, unknown>]])
  do
    if type(entry) == "table" then
      local record = entry --[[@as table<string, unknown>]]
      if record.key == contact then
        local weekday, timeOfDay = record.rematchWeekday, record.rematchTime
        if
          type(weekday) == "number"
          and weekday % 1 == 0
          and weekday >= 0
          and weekday <= 6
          and type(timeOfDay) == "number"
          and timeOfDay % 1 == 0
          and timeOfDay >= 0
          and timeOfDay <= 2
        then
          return { weekday = weekday, timeOfDay = timeOfDay }
        end
        return nil
      end
    end
  end
  return nil
end

-- Reports whether the native weekday and time fields match the live
-- field clock. Missing data cannot manufacture eligibility.
---@param contact string
---@param world table<string, unknown> borrowed world table
---@param catalog table<string, unknown>? borrowed contact catalog
---@return boolean eligible
function TrainerPhonePrograms.eligible(contact, world, catalog)
  assert(type(contact) == "string" and contact ~= "", "rematch eligibility names its contact")
  assert(type(world) == "table", "rematch eligibility reads the borrowed world")
  local window = catalogWindow(contact, catalog)
  if window == nil then
    return false
  end
  local readFacts = world.rematchFacts
  local facts = type(readFacts) == "function" and readFacts(world, contact) or world
  assert(type(facts) == "table", "rematch eligibility reads live contact window facts")
  return facts.weekday == window.weekday and facts.timeOfDay == window.timeOfDay
end

---@param world table<string, unknown>
---@param contact string
---@return { stage: integer, wins: integer }? saved record
local function rematchRecord(world, contact)
  local query = world.queryRematch
  assert(type(query) == "function", "rematch queries read durable companion state")
  return query(world, contact)
end

-- Readiness projects one saved record through the native contact window.
---@param contact string
---@param world table<string, unknown> borrowed world table
---@param catalog table<string, unknown>? borrowed contact catalog
---@return { ready: boolean, tier: integer? }
function TrainerPhonePrograms.query(contact, world, catalog)
  assert(type(contact) == "string" and contact ~= "", "rematch queries name their contact")
  assert(type(world) == "table", "rematch queries read the borrowed world")
  local tier = TrainerPhonePrograms.tierFor(world)
  local record = rematchRecord(world, contact)
  local staged = type(record) == "table" and record.stage > 0
  return { ready = staged == true and TrainerPhonePrograms.eligible(contact, world, catalog), tier = tier }
end

-- Projects the map marker for a contact: the same tier the query
-- reports, with its current readiness.
---@param contact string
---@param world table<string, unknown> borrowed world table
---@param catalog table<string, unknown>? borrowed contact catalog
---@return { tier: integer?, ready: boolean }
function TrainerPhonePrograms.marker(contact, world, catalog)
  local status = TrainerPhonePrograms.query(contact, world, catalog)
  return { tier = status.tier, ready = status.ready }
end

-- Launches only through a runtime resolver backed by a generated source
-- mapping. The present catalog has no such mapping.
---@param contact string
---@param world table<string, unknown> borrowed world table
---@param catalog table<string, unknown>? borrowed contact catalog
---@return { tier: integer, team: table<string, unknown> }
function TrainerPhonePrograms.launch(contact, world, catalog)
  local status = TrainerPhonePrograms.query(contact, world, catalog)
  if status.ready ~= true then
    local failure = Errors.new(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "no staged rematch invitation waits for contact " .. contact,
      { contact = contact }
    )
    error({ code = failure.code, message = failure.message, context = failure.context, domain = "trainer" })
  end
  local resolve = world.resolveRematchTeam
  if type(resolve) ~= "function" or status.tier == nil then
    local failure = Errors.new(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "no source-backed rematch team is available for contact " .. contact,
      { contact = contact }
    )
    error({ code = failure.code, message = failure.message, context = failure.context, domain = "trainer" })
  end
  local team = resolve(world, contact, status.tier)
  if type(team) ~= "table" then
    local failure = Errors.new(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "no source-backed rematch team is available for contact " .. contact,
      { contact = contact, tier = status.tier }
    )
    error({ code = failure.code, message = failure.message, context = failure.context, domain = "trainer" })
  end
  return { tier = status.tier, team = team }
end

-- Resolves a rematch win once. Settling to stage zero makes repeated
-- receipts idempotent while preserving the accumulated win count.
---@param contact string
---@param world table<string, unknown> borrowed world table
---@param outcome string source resolution outcome
---@return { contact: string, outcome: string, ready: boolean }
function TrainerPhonePrograms.resolve(contact, world, outcome)
  assert(type(contact) == "string" and contact ~= "", "rematch resolution names its contact")
  assert(type(world) == "table", "rematch resolution writes durable companion state")
  assert(
    outcome == "win" or TrainerPhonePrograms.PRESERVING_OUTCOMES[outcome] == true,
    "rematch resolution names a source outcome"
  )
  if outcome == "win" then
    local record = rematchRecord(world, contact)
    if type(record) == "table" and record.stage > 0 then
      local write = world.setRematch
      assert(type(write) == "function", "rematch wins settle through durable companion state")
      write(world, contact, { stage = 0, wins = record.wins + 1 })
    end
    return { contact = contact, outcome = outcome, ready = false }
  end
  local record = rematchRecord(world, contact)
  local staged = type(record) == "table" and record.stage > 0
  return { contact = contact, outcome = outcome, ready = staged }
end

return TrainerPhonePrograms
