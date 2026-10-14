-- Named service-contact policies: friend, Bill, Bike Shop, Kurt, Day
-- Care, Buena, and Baoba. Each branch reads only the typed facts its
-- source branch needs; a branch that needs a production owner it was
-- not given fails with an attributed dependency error before any side
-- effect, while a local acknowledgement branch answers without one.
-- Pure source policy over the borrowed world table, private to the
-- foreground phone feature.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@class ServicePhonePrograms
local ServicePhonePrograms = {}

local function integer(value, low, high)
  return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
end

---@param contact string
---@param fact string
---@param family string
local function missingNativeFact(contact, fact, family)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "native " .. family .. " phone program needs the " .. fact .. " source fact",
    { contact = contact, family = family, fact = fact }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
end

---@param domain string
local function missingOwner(domain)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "phone service branch needs its missing " .. domain .. " owner",
    { domain = domain }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = domain })
end

---@param world table<string, unknown>
---@param domain string
---@return table<string, unknown> the borrowed domain owner
local function domainOwner(world, domain)
  local owner = world[domain]
  if type(owner) ~= "table" then
    missingOwner(domain)
  end
  assert(type(owner) == "table", "service branches borrow their domain owner")
  return owner --[[@as table<string, unknown>]]
end

-- Selects the service program identity for one named contact family.
-- Pure dispatch over labelled facts with no owner reads; owner-gated
-- branches resolve their production program here and preflight the
-- owner at the program stage through step.
---@param family string named service family
---@param facts table<string, unknown> labelled source facts for the caller
---@return string program identity
function ServicePhonePrograms.selectName(family, facts)
  assert(type(family) == "string" and family ~= "", "service selection names its contact family")
  assert(type(facts) == "table", "service selection reads labelled facts")
  if family == "bill" then
    if facts.acknowledged == true then
      return "bill-greeting"
    end
    if facts.pcFreeSlots == 0 then
      return "bill-full"
    end
    if facts.pcFreeSlots ~= nil then
      return "bill-advice"
    end
    return "bill-greeting"
  end
  if family == "buena" then
    if facts.takeover == true or facts.closed == true then
      return "buena-closed"
    end
    if facts.passwordKnown == true then
      return "buena-reward"
    end
    if facts.blueCard == true then
      return "buena-password"
    end
    return "buena-greeting"
  end
  if family == "kurt" then
    if facts.aboutProduction == true then
      return "kurt-production"
    end
    return "kurt-greeting"
  end
  if family == "daycare" then
    if facts.aboutEgg == true then
      return "daycare-egg"
    end
    return "daycare-greeting"
  end
  if family == "bike" then
    if facts.acknowledged == true then
      return "bike-greeting"
    end
    if facts.hasBicycle == true then
      return "bike-owned"
    end
    return "bike-offer"
  end
  if family == "friend" then
    if facts.subject ~= nil then
      return "friend-topic"
    end
    return "friend-greeting"
  end
  if family == "baoba" then
    if facts.safariTest == true then
      return "baoba-test"
    end
    return "baoba-greeting"
  end
  error("service selection covers the named service families", 0)
end

-- Programs whose branch reads production state, preflighted at the
-- program stage before any effect. Local branches are absent here and
-- resolve without an owner.
local PRODUCTION_PROGRAMS = {
  ["kurt-production"] = "kurt",
  ["daycare-egg"] = "daycare",
  ["baoba-test"] = "safari",
  ["bill-advice"] = "pc",
  ["bill-full"] = "pc",
  ["buena-reward"] = "buena",
  ["buena-password"] = "buena",
}

-- Opens a service program session over the borrowed world. Selection
-- itself never mutates and never requires an owner; the program stage
-- preflights the branch owner through step before any effect.
---@param world table<string, unknown> borrowed world table
---@param request { contact: string, family: string, facts: table<string, unknown> }
---@return table<string, unknown> program session
function ServicePhonePrograms.select(world, request)
  assert(type(world) == "table", "service programs borrow their world")
  assert(type(request) == "table" and type(request.contact) == "string", "service programs name their contact")
  assert(type(request.family) == "string", "service programs name their contact family")
  assert(type(request.facts) == "table", "service programs read labelled facts")
  return {
    program = ServicePhonePrograms.selectName(request.family, request.facts),
    contact = request.contact,
    family = request.family,
    world = world,
    effectDone = false,
  }
end

-- Opens the source type-twelve remote Kurt call. Its second page depends
-- on the live order, Apricorn daily flag, and caller's first-call flag.
---@param world table<string, unknown> borrowed world table
---@param request { contact: string, decision: table<string, unknown>, nativeFacts: table<string, unknown> }
---@return table<string, unknown> native Kurt session
function ServicePhonePrograms.selectNativeKurt(world, request)
  assert(type(world) == "table", "Kurt's native conversation borrows its world")
  assert(type(request) == "table" and type(request.contact) == "string", "Kurt's native call names its contact")
  local decision = request.decision
  assert(
    type(decision) == "table" and decision.family == "kurt" and decision.mode == "special" and decision.scriptType == 12,
    "Kurt's session follows the frozen source type-twelve decision"
  )
  local facts = request.nativeFacts
  assert(type(facts) == "table", "Kurt's native session retains source facts")
  if type(facts.kurtRepeatCaller) ~= "boolean" then
    missingNativeFact(request.contact, "repeat-caller flag", "kurt")
  end
  if type(facts.kurtQuantity) ~= "number" or facts.kurtQuantity % 1 ~= 0 or facts.kurtQuantity < 0 then
    missingNativeFact(request.contact, "Apricorn order quantity", "kurt")
  end
  if type(facts.kurtDailyWork) ~= "boolean" then
    missingNativeFact(request.contact, "daily work flag", "kurt")
  end
  if facts.kurtQuantity > 0 and not facts.kurtDailyWork and type(facts.kurtBallName) ~= "string" then
    missingNativeFact(request.contact, "ordered Ball name", "kurt")
  end
  local openingEntry = facts.kurtRepeatCaller and 6 or 2
  return {
    program = "kurt-native",
    contact = request.contact,
    facts = facts,
    entries = { openingEntry },
    phase = "opening",
    substitutionsByEntry = {},
    effectDone = false,
  }
end

-- Advances Kurt's two source message stages without changing the order.
---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string "continue"|"done"
function ServicePhonePrograms.stepNativeKurt(session, input)
  assert(type(session) == "table" and session.program == "kurt-native", "Kurt advances a native call session")
  assert(type(input) == "table", "Kurt's native call reads its input")
  if session.effectDone == true then
    return "done"
  end
  local facts = session.facts --[[@as table<string, unknown>]]
  if session.phase == "response" then
    assert(input.responseResolved == true, "Kurt's source call waits for its response page")
    session.effectDone = true
    return "done"
  end
  assert(session.phase == "opening", "Kurt's source call has one opening page")
  local entry = 5
  if facts.kurtQuantity > 0 then
    entry = facts.kurtDailyWork and 4 or 3
  end
  session.responseEntry = entry
  if entry == 3 then
    session.substitutionsByEntry[3] = { [51] = { [11] = facts.kurtBallName }, [8] = { [10] = facts.kurtQuantity } }
  end
  session.phase = "response"
  return "continue"
end

-- Opens the first verified page of the remaining native service specials.
---@param request { contact: string, decision: table<string, unknown>, nativeFacts: table<string, unknown>, draw: (fun(): integer)? }
---@return table<string, unknown> source page session
function ServicePhonePrograms.selectNativePage(request)
  assert(type(request) == "table" and type(request.contact) == "string", "service calls name their caller")
  local decision = request.decision
  local facts = request.nativeFacts
  assert(type(decision) == "table" and type(facts) == "table", "service pages retain source selection facts")
  local entry = nil
  local responseEntries = {}
  local substitutionsByEntry = {}
  if decision.family == "bill" and decision.scriptType == 3 then
    if facts.playerGender ~= 0 and facts.playerGender ~= 1 then
      missingNativeFact(request.contact, "player gender", "bill")
    end
    entry = facts.playerGender == 0 and 3 or 4
    local freeSlots = facts.pcFreeSlots
    if type(freeSlots) ~= "number" or freeSlots % 1 ~= 0 or freeSlots < 0 then
      missingNativeFact(request.contact, "PC free-slot count", "bill")
    end
    if freeSlots == 0 then
      responseEntries[#responseEntries + 1] = 9
    else
      local draw = request.draw
      if type(draw) ~= "function" then
        missingNativeFact(request.contact, "Bill's native random stream", "bill")
      end
      local drawMessage = draw --[[@as fun(): integer]]
      local response = 5 + drawMessage() % 3
      local boxName = facts.pcBoxName
      if type(boxName) ~= "string" then
        missingNativeFact(request.contact, "active PC box name", "bill")
      end
      responseEntries[#responseEntries + 1] = response
      substitutionsByEntry[response] = { [11] = { [10] = boxName }, [52] = { [11] = freeSlots } }
    end
    responseEntries[#responseEntries + 1] = 8
  elseif decision.family == "friend" and (decision.scriptType == 10 or decision.scriptType == 11) then
    local timeOfDay = facts.timeOfDay
    if type(timeOfDay) ~= "number" or timeOfDay % 1 ~= 0 or timeOfDay < 0 or timeOfDay > 2 then
      missingNativeFact(request.contact, "time of day", "friend")
    end
    entry = (decision.scriptType == 10 and 4 or 7) + timeOfDay
    local draw = request.draw
    if decision.scriptType == 10 then
      local mapIndex = facts.friendMapIndex
      if type(mapIndex) == "number" then
        responseEntries[#responseEntries + 1] = 13 + mapIndex
      else
        if type(draw) ~= "function" then
          missingNativeFact(request.contact, "Friend's native random stream", "friend")
        end
        local drawMessage = draw --[[@as fun(): integer]]
        responseEntries[#responseEntries + 1] = 10 + drawMessage() % 3
      end
    else
      if type(draw) ~= "function" then
        missingNativeFact(request.contact, "Friend's native random stream", "friend")
      end
      local drawMessage = draw --[[@as fun(): integer]]
      if drawMessage() % 1000 < 500 then
        responseEntries[#responseEntries + 1] = 10 + math.floor((drawMessage() % 900) / 300)
      else
        local unlocked = facts.friendEligiblePhraseIndices
        if type(unlocked) ~= "table" or #unlocked == 0 then
          missingNativeFact(request.contact, "eligible Friend map phrases", "friend")
        end
        responseEntries[#responseEntries + 1] = 86 + unlocked[drawMessage() % #unlocked + 1]
      end
    end
  elseif decision.family == "daycare" and decision.scriptType == 6 then
    local gender = facts.playerGender
    if gender ~= 0 and gender ~= 1 then
      missingNativeFact(request.contact, "player gender", "daycare")
    end
    entry = gender == 0 and 3 or 4
    local mons = facts.daycareMons
    if type(mons) ~= "table" or #mons > 2 then
      missingNativeFact(request.contact, "ordered Day Care mon facts", "daycare")
    end
    if #mons == 0 then
      responseEntries[#responseEntries + 1] = 10
    else
      responseEntries[#responseEntries + 1] = 5
      local growthCount = 0
      local responseSubstitutions = {}
      for _, mon in ipairs(mons) do
        if
          type(mon) ~= "table"
          or type(mon.nickname) ~= "string"
          or type(mon.growth) ~= "number"
          or mon.growth % 1 ~= 0
          or mon.growth < 0
        then
          missingNativeFact(request.contact, "Day Care mon nickname and growth", "daycare")
        end
        if mon.growth > 0 then
          growthCount = growthCount + 1
          responseEntries[#responseEntries + 1] = 6
          responseSubstitutions[#responseEntries] = { [0] = { [10] = mon.nickname }, [52] = { [11] = mon.growth } }
        end
      end
      if growthCount == 0 then
        responseEntries[#responseEntries + 1] = 9
      else
        responseEntries[#responseEntries + 1] = #mons == 1 and 8 or 9
      end
      return {
        program = "service-native-page",
        contact = request.contact,
        entries = { entry },
        responseEntries = responseEntries,
        responseSubstitutionsByIndex = responseSubstitutions,
        responseIndex = 0,
        substitutionsByEntry = substitutionsByEntry,
        effectDone = false,
      }
    end
  elseif decision.family == "daycare" and decision.scriptType == 7 then
    entry = 2
    local eggPid = facts.daycareEggPid
    local mons = facts.daycareMons
    if type(eggPid) ~= "number" or eggPid % 1 ~= 0 or eggPid < 0 then
      missingNativeFact(request.contact, "Day Care egg identity", "daycare")
    end
    if type(mons) ~= "table" or #mons > 2 then
      missingNativeFact(request.contact, "ordered Day Care mon facts", "daycare")
    end
    if eggPid ~= 0 then
      responseEntries[#responseEntries + 1] = 3
    elseif #mons == 0 then
      responseEntries[#responseEntries + 1] = 4
      responseEntries[#responseEntries + 1] = 11
    elseif #mons == 1 then
      responseEntries[#responseEntries + 1] = 5
      responseEntries[#responseEntries + 1] = 11
    else
      local first, second = mons[1], mons[2]
      if
        type(first) ~= "table"
        or type(second) ~= "table"
        or type(first.nickname) ~= "string"
        or type(second.nickname) ~= "string"
        or not integer(facts.daycareCompatibility, 0, 3)
      then
        missingNativeFact(request.contact, "Day Care pair compatibility and nicknames", "daycare")
      end
      responseEntries[#responseEntries + 1] = 6
      substitutionsByEntry[6] = { [0] = { [10] = first.nickname, [11] = second.nickname } }
      responseEntries[#responseEntries + 1] = 7 + facts.daycareCompatibility
      responseEntries[#responseEntries + 1] = 11
    end
  elseif decision.family == "buena" and (decision.scriptType == 8 or decision.scriptType == 9) then
    local timeOfDay = facts.timeOfDay
    local gender = facts.playerGender
    if type(timeOfDay) ~= "number" or timeOfDay % 1 ~= 0 or timeOfDay < 0 or timeOfDay > 2 then
      missingNativeFact(request.contact, "time of day", "buena")
    end
    if gender ~= 0 and gender ~= 1 then
      missingNativeFact(request.contact, "player gender", "buena")
    end
    local base = decision.scriptType == 8 and 3 or 15
    entry = base + 2 * timeOfDay + gender
    if decision.scriptType == 8 then
      local draw = request.draw
      if type(draw) ~= "function" then
        missingNativeFact(request.contact, "Buena's native random stream", "buena")
      end
      local drawMessage = draw --[[@as fun(): integer]]
      responseEntries[#responseEntries + 1] = 10 + drawMessage() % 3
    elseif facts.passwordOnAir == true then
      responseEntries[#responseEntries + 1] = 36
    else
      if type(facts.gameClear) ~= "boolean" then
        missingNativeFact(request.contact, "game-clear flag", "buena")
      end
      local draw = request.draw
      if type(draw) ~= "function" then
        missingNativeFact(request.contact, "Buena's native random stream", "buena")
      end
      local drawMessage = draw --[[@as fun(): integer]]
      local random = drawMessage() % (facts.gameClear and 14 or 11)
      responseEntries[#responseEntries + 1] = random == 13 and (34 + gender) or 21 + random
    end
  elseif decision.family == "baoba" and decision.scriptType == 15 then
    local gender = facts.playerGender
    local areas = facts.safariArrangementAreas
    if gender ~= 0 and gender ~= 1 then
      missingNativeFact(request.contact, "player gender", "baoba")
    end
    if type(areas) ~= "table" or #areas > 6 then
      missingNativeFact(request.contact, "ordered Safari arrangement areas", "baoba")
    end
    local count = #areas
    if count == 0 then
      entry = 38 + gender
    elseif count >= 6 then
      entry = 24 + gender
    else
      entry = 14 + 2 * (count - 1) + gender
      substitutionsByEntry[entry] = { safariAreaIds = areas }
    end
  else
    error("native service page follows a supported special call", 0)
  end
  return {
    program = "service-native-page",
    contact = request.contact,
    entries = { entry },
    responseEntries = responseEntries,
    responseIndex = 0,
    substitutionsByEntry = substitutionsByEntry,
    effectDone = false,
  }
end

---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string "done"
function ServicePhonePrograms.stepNativePage(session, input)
  assert(type(session) == "table" and session.program == "service-native-page", "service call advances its native page")
  assert(type(input) == "table", "service call reads its input")
  local responseIndex = session.responseIndex --[[@as integer]]
  local responses = session.responseEntries --[[@as table<integer, integer>]]
  if responseIndex == 0 then
    if #responses == 0 then
      session.effectDone = true
      return "done"
    end
  else
    assert(input.responseResolved == true, "service calls advance after their previous response page")
  end
  responseIndex = responseIndex + 1
  session.responseIndex = responseIndex
  local responseEntry = responses[responseIndex]
  if responseEntry ~= nil then
    session.responseEntry = responseEntry
    local responseSubstitutionsByIndex = session.responseSubstitutionsByIndex
    session.responseSubstitutions = type(responseSubstitutionsByIndex) == "table"
        and responseSubstitutionsByIndex[responseIndex]
      or nil
    return "continue"
  end
  session.effectDone = true
  return "done"
end

-- Advances one program step. Production branches preflight their owner
-- first: a missing owner fails with attribution and changes nothing.
-- Service branches carry no other world effect. Returns done once the
-- branch has resolved.
---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string "done"
function ServicePhonePrograms.step(session, input)
  assert(type(session) == "table", "service programs step their session")
  assert(type(input) == "table", "service programs read their input")
  assert(type(session.program) == "string", "service sessions carry their program")
  if session.effectDone == true then
    return "done"
  end
  local program = session.program --[[@as string]]
  if program == "kurt-native" then
    assert(input.responseResolved == true, "Kurt's native call finishes after its response page")
    session.effectDone = true
    return "done"
  end
  local domain = PRODUCTION_PROGRAMS[program]
  if domain ~= nil then
    local world = session.world --[[@as table<string, unknown>]]
    assert(type(world) == "table", "service effects stage through the borrowed world")
    domainOwner(world, domain)
  end
  session.effectDone = true
  return "done"
end

return ServicePhonePrograms
