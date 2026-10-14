-- Professor policies: Elm with the exact source predicate order and Oak
-- with Dex evaluation branches. Selection is a deterministic function of
-- labelled facts with no draws; every early return keeps its own program
-- identity so each branch stays testable against its counterexample.
-- Pure source policy, private to the foreground phone feature.

---@class ProfessorPhonePrograms
local ProfessorPhonePrograms = {}

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@param contact string?
---@param fact string
local function missingOakFact(contact, fact)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "Oak's native phone selector needs the " .. fact .. " source fact",
    { contact = contact, fact = fact }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
end

---@param contact string
local function missingOakEffect(contact)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "Oak's native phone program needs the event-flag writer",
    { contact = contact, domain = "flags" }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
end

---@param contact string
---@param fact string
local function missingElmFact(contact, fact)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "Elm's native phone selector needs the " .. fact .. " source fact",
    { contact = contact, family = "elm", fact = fact }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
end

-- Selects Oak's numeric definition or special type in the exact source
-- branch order. Incoming evaluations use the National Dex owned count;
-- ordinary outgoing calls use the caller map and acknowledgment flags.
---@param direction string
---@param record table<string, unknown>
---@param nativeFacts table<string, unknown>
---@return table<string, unknown> frozen native decision
function ProfessorPhonePrograms.selectOakNative(direction, record, nativeFacts)
  assert(direction == "incoming" or direction == "outgoing", "Oak calls have a native phone direction")
  assert(type(record) == "table", "Oak selection reads its phonebook entry")
  assert(type(nativeFacts) == "table", "Oak selection reads frozen source facts")
  if nativeFacts.scriptedCallType == 2 then
    return { mode = "numeric", scriptId = 82, family = "oak" }
  end
  if direction == "incoming" then
    local owned = nativeFacts.nationalDexOwned
    if type(owned) ~= "number" or owned % 1 ~= 0 or owned < 0 then
      missingOakFact(record.key --[[@as string?]], "National Dex owned count")
    end
    local parameter = math.min(math.max(math.floor(owned / 50), 1), 9)
    return { mode = "numeric", scriptId = 68 + parameter, family = "oak" }
  end
  if type(nativeFacts.localMap) ~= "boolean" then
    missingOakFact(record.key --[[@as string?]], "map locality")
  end
  if nativeFacts.localMap then
    return { mode = "numeric", scriptId = 68, family = "oak" }
  end
  if type(nativeFacts.acknowledgedNational) ~= "boolean" then
    missingOakFact(record.key --[[@as string?]], "National Dex acknowledgment")
  end
  if nativeFacts.acknowledgedNational then
    return { mode = "numeric", scriptId = 81, family = "oak" }
  end
  if type(nativeFacts.nationalDexUnlocked) ~= "boolean" then
    missingOakFact(record.key --[[@as string?]], "National Dex availability")
  end
  if not nativeFacts.nationalDexUnlocked and type(nativeFacts.acknowledgedJohto) ~= "boolean" then
    missingOakFact(record.key --[[@as string?]], "Johto Dex acknowledgment")
  end
  if not nativeFacts.nationalDexUnlocked and nativeFacts.acknowledgedJohto then
    return { mode = "numeric", scriptId = 80, family = "oak" }
  end
  return { mode = "special", scriptType = 5, family = "oak" }
end

-- Opens the source-selected Oak program without running a second semantic
-- selector over the same call facts.
---@param world table<string, unknown>
---@param request table<string, unknown>
---@return table<string, unknown>
function ProfessorPhonePrograms.selectOakNativeSession(world, request)
  assert(type(world) == "table", "Oak conversations borrow their live effect owner")
  assert(type(request) == "table", "Oak conversations open from a call request")
  local decision = request.decision --[[@as table<string, unknown>]]
  assert(
    type(decision) == "table"
      and decision.family == "oak"
      and (decision.mode == "numeric" or decision.mode == "special"),
    "Oak sessions follow one frozen native decision"
  )
  local session = {
    program = decision.mode == "special" and "oak-special" or "oak-numeric",
    contact = request.contact,
    world = world,
    decision = decision,
    nativeFacts = request.nativeFacts,
    effectDone = false,
  }
  if decision.mode == "special" then
    local facts = request.nativeFacts --[[@as table<string, unknown>]]
    if facts.nationalDexUnlocked ~= true and facts.nationalDexUnlocked ~= false then
      missingOakFact(request.contact --[[@as string]], "National Dex availability")
    end
    if type(facts.playerGender) ~= "number" or (facts.playerGender ~= 0 and facts.playerGender ~= 1) then
      missingOakFact(request.contact --[[@as string]], "player gender")
    end
    local variant = 0
    if facts.nationalDexUnlocked then
      if type(facts.acknowledgedJohto) ~= "boolean" then
        missingOakFact(request.contact --[[@as string]], "Johto Dex acknowledgment")
      end
      variant = facts.acknowledgedJohto and 2 or 1
    end
    session.entries = { facts.playerGender == 0 and 13 or 14, 15 }
    session.menuVariant = variant
    session.choices = variant == 0 and { "johto", "decline" }
      or variant == 1 and { "johto", "national" }
      or { "national", "decline" }
  end
  return session
end

---@param contact string
---@param facts table<string, unknown>
---@param dex "johto"|"national"
---@return integer seen, integer owned, boolean complete, integer ratingEntry
local function oakEvaluation(contact, facts, dex)
  local prefix = dex == "johto" and "johto" or "national"
  local seen = facts[prefix .. "Seen"]
  local owned = facts[prefix .. "Owned"]
  local complete = facts[prefix .. "Complete"]
  local ratingEntry = facts[prefix .. "RatingEntry"]
  if type(seen) ~= "number" or seen % 1 ~= 0 or seen < 0 then
    missingOakFact(contact, prefix .. " Dex seen count")
  end
  if type(owned) ~= "number" or owned % 1 ~= 0 or owned < 0 then
    missingOakFact(contact, prefix .. " Dex owned count")
  end
  if type(complete) ~= "boolean" then
    missingOakFact(contact, prefix .. " Dex completion state")
  end
  if ratingEntry == nil then
    local thresholds = dex == "johto"
        and { 9, 19, 34, 49, 64, 79, 94, 109, 124, 139, 154, 169, 184, 199, 214, 229, 244, 253 }
      or { 100, 150, 200, 250, 300, 350, 400, 435, 465, 475, 483 }
    local gender = facts.playerGender
    if type(gender) ~= "number" or (gender ~= 0 and gender ~= 1) then
      missingOakFact(contact, "player gender")
    end
    if complete then
      ratingEntry = dex == "johto" and (gender == 0 and 22 or 23) or (gender == 0 and 24 or 25)
    else
      for index, threshold in ipairs(thresholds) do
        if owned <= threshold then
          ratingEntry = (dex == "johto" and 27 or 45) + index
          break
        end
      end
    end
  end
  if type(ratingEntry) ~= "number" or ratingEntry % 1 ~= 0 or ratingEntry < 0 then
    missingOakFact(contact, prefix .. " Dex rating message")
  end
  return seen, owned, complete, ratingEntry
end

-- Advances Oak's source special type 5 after its intro pages. The menu
-- choice selects the Dex, entry 20 reports its counts, and the rating
-- message follows the exact completion acknowledgment stage.
---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string "waiting"|"continue"|"done"
local function stepOakNative(session, input)
  if session.effectDone == true then
    return "done"
  end
  local choice = input.choice
  if session.responseEntry == nil then
    if choice == nil then
      return "waiting"
    end
    local choices = session.choices --[[@as table<integer, string>]]
    assert(type(choices) == "table", "Oak choice input follows its source menu variant")
    local selected = false
    for _, option in ipairs(choices) do
      if option == choice then
        selected = true
        break
      end
    end
    assert(selected, "Oak selection is one of the active native menu choices")
    if choice == "decline" then
      session.responseEntry = 21
      session.programStage = "decline"
      return "continue"
    end
    session.selectedDex = choice
    local contact = session.contact --[[@as string]]
    local facts = session.nativeFacts --[[@as table<string, unknown>]]
    local seen, owned = oakEvaluation(contact, facts, choice)
    session.substitutionsByEntry = {
      [20] = { [52] = { [5] = seen, [6] = owned } },
    }
    session.responseEntry = 20
    session.programStage = "counts"
    return "continue"
  end
  if input.responseResolved ~= true then
    return "waiting"
  end
  if session.programStage == "decline" then
    session.effectDone = true
    return "done"
  end
  if session.programStage == "counts" then
    local contact = session.contact --[[@as string]]
    local facts = session.nativeFacts --[[@as table<string, unknown>]]
    local dex = session.selectedDex --[[@as "johto"|"national"]]
    local _, _, complete, ratingEntry = oakEvaluation(contact, facts, dex)
    if complete then
      local world = session.world --[[@as table<string, unknown>]]
      local acknowledge = world.setOakAcknowledged
      if type(acknowledge) ~= "function" then
        missingOakEffect(contact)
      end
      -- PhoneCall runs this only after the selected rating page validates.
      local function commitOakAcknowledgment()
        acknowledge(world, dex)
      end
      session.responseEffect = commitOakAcknowledgment
    end
    session.responseEntry = ratingEntry
    session.programStage = "rating"
    return "continue"
  end
  assert(session.programStage == "rating", "Oak's native evaluation advances through its rating page")
  session.effectDone = true
  return "done"
end

-- Selects the Elm program identity in source order: predefined scripts
-- precede incoming handling, then ordinary outgoing checks run local
-- map, panic-call state, rival naming, egg-call and gift state,
-- hatch and Everstone state, badges and Rockets, clear state, the SS
-- Ticket, and Pokerus.
---@param facts table<string, unknown> labelled source facts for the caller
---@return string program identity
function ProfessorPhonePrograms.selectElm(facts)
  assert(type(facts) == "table", "elm selection reads labelled facts")
  if facts.predefinedScript ~= nil then
    return "elm-predefined"
  end
  if facts.incomingCall == true then
    return "elm-incoming"
  end
  if facts.localMap == true then
    return "elm-local-map"
  end
  if facts.panicCall == true then
    return "elm-panic"
  end
  if facts.rivalUnnamed == true then
    return "elm-rival"
  end
  if facts.eggEvent == true then
    return "elm-egg"
  end
  if facts.eggGift == true then
    return "elm-gift"
  end
  if facts.eggHatched == true then
    return "elm-hatch"
  end
  if facts.everstone == true then
    return "elm-everstone"
  end
  if facts.rockets == true then
    return "elm-rockets"
  end
  if facts.badges ~= nil then
    return "elm-early"
  end
  if facts.gameClear == true then
    return "elm-clear"
  end
  if facts.ssTicket == true then
    return "elm-ticket"
  end
  if facts.pokerus == true then
    return "elm-pokerus"
  end
  return "elm-early"
end

-- Selects Elm's source script ID for one outgoing, incoming, or scripted call.
---@param direction "incoming"|"outgoing"
---@param contact string
---@param facts table<string, unknown>
---@param random table<string, unknown>?
---@return table<string, unknown> frozen native decision
function ProfessorPhonePrograms.selectElmNative(direction, contact, facts, random)
  assert(direction == "incoming" or direction == "outgoing", "Elm calls have a native phone direction")
  assert(type(contact) == "string" and type(facts) == "table", "Elm selection reads its contact and source facts")
  local function randomOffset(count)
    local draw = type(random) == "table" and random.lc or nil
    if type(draw) ~= "function" then
      missingElmFact(contact, "native LC random stream")
    end
    assert(type(draw) == "function", "Elm selection draws through the native LC stream")
    return draw(random --[[@as table<string, unknown>]], "elm-call-random") % count
  end
  local scriptId
  if facts.scriptedCallType == 2 then
    local scripted = facts.predefinedScript
    if type(scripted) ~= "number" or scripted % 1 ~= 0 or scripted < 0 or scripted > 4 then
      missingElmFact(contact, "scripted-call intro index")
    end
    scriptId = 2 + scripted
  elseif direction == "incoming" then
    scriptId = facts.predefinedScript
    if type(scriptId) ~= "number" or scriptId % 1 ~= 0 or scriptId < 1 then
      missingElmFact(contact, "incoming trigger script ID")
    end
  elseif facts.localMap == true then
    scriptId = 1
  else
    local function flag(key)
      local value = facts[key]
      if type(value) ~= "boolean" then
        missingElmFact(contact, key)
      end
      return value --[[@as boolean]]
    end
    local badges = facts.badges
    if type(badges) ~= "number" or badges % 1 ~= 0 or badges < 0 then
      missingElmFact(contact, "badge count")
    end
    if not flag("elmPanicCallReceived") then
      scriptId = 8
    elseif not flag("gaveRivalName") then
      scriptId = 9
    elseif not flag("elmEggCallReceived") then
      scriptId = 10
    elseif not flag("elmEggReceived") then
      scriptId = 11
    else
      local hatched = flag("togePiEggHatched")
      local everstone = flag("elmEverstoneReceived")
      if badges < 7 then
        if not hatched then
          scriptId = 12
        elseif everstone then
          scriptId = 14 + randomOffset(2)
        else
          scriptId = 13
        end
      elseif flag("rocketTakeoverActive") then
        scriptId = 16
      elseif badges < 8 then
        scriptId = 17
      elseif not flag("gameClear") then
        scriptId = 18
      elseif not flag("elmSsTicketReceived") then
        scriptId = 19
      elseif not everstone then
        scriptId = hatched and 13 or 12
      else
        scriptId = 20 + randomOffset(flag("toldAboutPokerus") and 3 or 2)
      end
    end
  end
  assert(type(scriptId) == "number", "Elm selection produces a native script ID")
  return { mode = "numeric", scriptId = scriptId, family = "elm" }
end

-- Selects the Oak program identity in source order: source exclusions
-- and progress flags defer first, then the National Dex evaluation
-- choice, then the seen-based evaluation, else the introduction.
---@param facts table<string, unknown> labelled source facts for the caller
---@return string program identity
function ProfessorPhonePrograms.selectOak(facts)
  assert(type(facts) == "table", "oak selection reads labelled facts")
  if facts.excluded == true then
    return "oak-deferred"
  end
  if facts.nationalDex == true then
    return "oak-national-evaluation"
  end
  if facts.dexSeen ~= nil then
    return "oak-evaluation"
  end
  return "oak-intro"
end

-- Opens a professor program session over the borrowed world. Selection
-- itself never mutates; professor branches resolve their message with
-- no world effect, so the single step only marks the stage visited.
---@param world table<string, unknown> borrowed world table
---@param request { contact: string, professor: string, facts: table<string, unknown> }
---@return table<string, unknown> program session
function ProfessorPhonePrograms.select(world, request)
  assert(type(world) == "table", "professor programs borrow their world")
  assert(type(request) == "table" and type(request.contact) == "string", "professor programs name their contact")
  assert(type(request.facts) == "table", "professor programs read labelled facts")
  local professor = request.professor --[[@as string]]
  assert(professor == "elm" or professor == "oak", "professor programs cover elm and oak")
  local program = professor == "elm" and ProfessorPhonePrograms.selectElm(request.facts)
    or ProfessorPhonePrograms.selectOak(request.facts)
  return {
    program = program,
    contact = request.contact,
    world = world,
    effectDone = false,
  }
end

-- Advances one program step. Professor branches carry no world effect;
-- the step only records the single visit. Returns done.
---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string "done"
function ProfessorPhonePrograms.step(session, input)
  assert(type(session) == "table", "professor programs step their session")
  assert(type(input) == "table", "professor programs read their input")
  if session.program == "oak-special" then
    return stepOakNative(session, input)
  end
  session.effectDone = true
  return "done"
end

return ProfessorPhonePrograms
