-- Mother policy: savings choice branches, balance formatting facts,
-- savings flag writes, and pending-gift announcements. Reading the
-- balance never starts a purchase; announcing a gift never grants it.
-- Grants stay with the staged gift-collection candidate. Pure source
-- policy, private to the foreground phone feature.

---@class MotherPhoneProgram
local MotherPhoneProgram = {}

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

MotherPhoneProgram.CHOICES = { "save", "keep" }

---@param contact string
---@param fact string
local function missingNativeFact(contact, fact)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "Mom's native phone program needs the " .. fact .. " source fact",
    { contact = contact, fact = fact }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
end

---@param contact string
---@param effect string
local function missingNativeEffect(contact, effect)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "Mom's native phone program needs the " .. effect .. " flag writer",
    { contact = contact, domain = "flags", effect = effect }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
end

-- Selects the source-native Mom numeric script or savings conversation.
---@param direction string
---@param record table<string, unknown>
---@param facts table<string, unknown>
---@return table<string, unknown> frozen native decision
function MotherPhoneProgram.selectNative(direction, record, facts)
  assert(direction == "incoming" or direction == "outgoing", "Mom calls have a native phone direction")
  assert(type(record) == "table", "Mom selection reads its phonebook entry")
  assert(type(facts) == "table", "Mom selection reads frozen source facts")
  local contact = record.key --[[@as string]]
  if facts.scriptedCallType == 2 then
    return { mode = "special", scriptType = 4, family = "mother" }
  end
  if type(facts.localMap) ~= "boolean" then
    missingNativeFact(contact, "map locality")
  end
  if facts.localMap then
    return { mode = "numeric", scriptId = 23, family = "mother" }
  end
  if direction == "incoming" then
    local scriptId = facts.predefinedScript
    if type(scriptId) ~= "number" or scriptId % 1 ~= 0 or scriptId < 0 then
      missingNativeFact(contact, "incoming trigger's predefined script ID")
    end
    return { mode = "numeric", scriptId = scriptId, family = "mother" }
  end
  if type(facts.gaveRivalName) ~= "boolean" then
    missingNativeFact(contact, "rival-name flag")
  end
  if not facts.gaveRivalName then
    return { mode = "numeric", scriptId = 25, family = "mother" }
  end
  if type(facts.talkedAfterNamingRival) ~= "boolean" then
    missingNativeFact(contact, "post-rival conversation flag")
  end
  if not facts.talkedAfterNamingRival then
    return { mode = "numeric", scriptId = 26, family = "mother" }
  end
  return { mode = "special", scriptType = 4, family = "mother" }
end

-- Opens Mom's native savings conversation using its one frozen decision.
---@param world table<string, unknown>
---@param request table<string, unknown>
---@return table<string, unknown>
function MotherPhoneProgram.selectNativeSession(world, request)
  assert(type(world) == "table", "Mom conversations borrow their effect owner")
  assert(type(request) == "table", "Mom conversations open from a call request")
  local decision = request.decision --[[@as table<string, unknown>]]
  assert(
    type(decision) == "table"
      and decision.family == "mother"
      and decision.mode == "special"
      and decision.scriptType == 4,
    "Mom sessions follow the frozen type-four decision"
  )
  local contact = request.contact --[[@as string]]
  local facts = request.nativeFacts --[[@as table<string, unknown>]]
  assert(type(contact) == "string" and type(facts) == "table", "Mom sessions retain call facts")
  if facts.scriptedCallType ~= 0 and facts.scriptedCallType ~= 2 then
    missingNativeFact(contact, "scripted call type")
  end
  if type(facts.momSavingsBalance) ~= "number" or facts.momSavingsBalance % 1 ~= 0 or facts.momSavingsBalance < 0 then
    missingNativeFact(contact, "savings balance")
  end
  if type(facts.momSavingsActive) ~= "boolean" then
    missingNativeFact(contact, "savings-choice flag")
  end
  if type(facts.momGiftQueueFull) ~= "boolean" then
    missingNativeFact(contact, "gift-queue capacity")
  end
  local entries = {}
  local phase = "intro"
  local deferredEffect = nil
  if facts.scriptedCallType == 2 then
    local markFollowUp = world.setMomTalkedAfterNamingRival
    if type(markFollowUp) ~= "function" then
      missingNativeEffect(contact, "post-rival")
    end
    local function commitMomIntro()
      markFollowUp(world)
    end
    deferredEffect = commitMomIntro
    entries[1] = 22
    phase = "prompt"
  else
    local parameter = facts.momIntroParameter
    if type(parameter) ~= "number" or parameter % 1 ~= 0 or parameter < 0 then
      missingNativeFact(contact, "map-specific intro parameter")
    end
    entries[1] = 7 + parameter
  end
  return {
    program = "mother-native",
    contact = contact,
    world = world,
    nativeFacts = facts,
    entries = entries,
    phase = phase,
    deferredEffect = deferredEffect,
    substitutionsByEntry = {
      [facts.scriptedCallType == 2 and 22 or 7 + facts.momIntroParameter --[[@as number]]] = {
        [55] = { [10] = facts.momSavingsBalance },
      },
    },
    effectDone = false,
  }
end

-- Advances the exact type-four source stages: location intro, capacity
-- check, balance prompt, explicit choice, then its matching response.
---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string "waiting"|"continue"|"done"
function MotherPhoneProgram.stepNative(session, input)
  assert(type(session) == "table", "native Mom sessions step their program")
  assert(type(input) == "table", "native Mom sessions read their input")
  if session.effectDone == true then
    return "done"
  end
  local facts = session.nativeFacts --[[@as table<string, unknown>]]
  local phase = session.phase --[[@as string]]
  if phase == "intro" then
    if facts.momGiftQueueFull then
      session.responseEntry = 21
      session.phase = "full"
    else
      local prompt = nil
      if facts.momSavingsActive then
        prompt = facts.momSavingsBalance ~= 0 and 23 or 27
      else
        prompt = facts.momSavingsBalance ~= 0 and 24 or 28
      end
      session.responseEntry = prompt
      session.substitutionsByEntry[prompt] = { [55] = { [10] = facts.momSavingsBalance } }
      session.phase = "prompt"
    end
    return "continue"
  end
  if phase == "choice" then
    local choice = input.choice
    assert(choice == "save" or choice == "keep", "Mom choices answer save or keep")
    local world = session.world --[[@as table<string, unknown>]]
    local writeChoice = world.setMomSavingsChoice
    if type(writeChoice) ~= "function" then
      missingNativeEffect(session.contact --[[@as string]], "savings")
    end
    -- PhoneCall runs this only after the selected response page validates.
    local function commitSavingsChoice()
      writeChoice(world, choice == "save")
    end
    session.responseEffect = commitSavingsChoice
    session.responseEntry = choice == "save" and 25 or 26
    session.phase = "response"
    return "continue"
  end
  if input.responseResolved ~= true then
    return "waiting"
  end
  if phase == "full" then
    session.effectDone = true
    return "done"
  end
  if phase == "prompt" then
    session.phase = "choice"
    return "waiting"
  end
  assert(phase == "response", "Mom's native conversation ends on its selected response")
  session.effectDone = true
  return "done"
end

-- Selects the Mother program identity in source order: a pending gift
-- announces first, then the current savings choice, else the opening
-- branch that offers the choice.
---@param facts table<string, unknown> labelled source facts for the caller
---@return string program identity
function MotherPhoneProgram.selectName(facts)
  assert(type(facts) == "table", "mother selection reads labelled facts")
  if facts.giftPending == true then
    return "mother-gift"
  end
  if facts.savingsChoice == true then
    return "mother-savings"
  end
  if facts.savingsChoice == false then
    return "mother-offer"
  end
  return "mother-greeting"
end

-- Opens a program session over the borrowed world. Selection itself never
-- mutates; savings flag writes run once at the program stage through
-- step, and only for an explicit choice.
---@param world table<string, unknown> borrowed world table
---@param request { contact: string, facts: table<string, unknown> }
---@return table<string, unknown> program session
function MotherPhoneProgram.select(world, request)
  assert(type(world) == "table", "mother programs borrow their world")
  assert(type(request) == "table" and type(request.contact) == "string", "mother programs name their contact")
  assert(type(request.facts) == "table", "mother programs read labelled facts")
  return {
    program = MotherPhoneProgram.selectName(request.facts),
    contact = request.contact,
    world = world,
    effectDone = false,
  }
end

-- Advances one program step. Choice branches wait for an explicit save
-- or keep choice and write the savings flag exactly once; announcement
-- and greeting branches resolve without writing. Returns waiting while a
-- choice is owed, else done.
---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string "waiting" while a choice is owed, else "done"
function MotherPhoneProgram.step(session, input)
  assert(type(session) == "table", "mother programs step their session")
  assert(type(input) == "table", "mother programs read their input")
  assert(type(session.program) == "string", "mother sessions carry their program")
  if session.effectDone == true then
    return "done"
  end
  local program = session.program --[[@as string]]
  if program == "mother-savings" or program == "mother-offer" then
    local choice = input.choice
    if choice == nil then
      return "waiting"
    end
    assert(choice == "save" or choice == "keep", "mother choices answer save or keep")
    session.effectDone = true
    local world = session.world --[[@as table<string, unknown>]]
    assert(type(world) == "table", "mother effects stage through the borrowed world")
    local writeChoice = world.setMomSavingsChoice
    assert(type(writeChoice) == "function", "mother savings choices write the native event flag")
    writeChoice(world, choice == "save")
    return "done"
  end
  session.effectDone = true
  return "done"
end

return MotherPhoneProgram
