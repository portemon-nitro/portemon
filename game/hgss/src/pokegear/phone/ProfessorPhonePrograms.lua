-- Professor policies: Elm with the exact source predicate order and Oak
-- with Dex evaluation branches. Selection is a deterministic function of
-- labelled facts with no draws; every early return keeps its own program
-- identity so each branch stays testable against its counterexample.
-- Pure source policy, private to the foreground phone feature.

---@class ProfessorPhonePrograms
local ProfessorPhonePrograms = {}

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

-- Resolves the dynamic Oak gendered intro: 13 (male) or 14
-- (female). An unknown gender defaults to the male entry, mirroring
-- the local friend branch.
---@param gender unknown player gender fact
---@return integer bank-666 entry for the intro
function ProfessorPhonePrograms.oakIntroEntry(gender)
  if gender == "female" or gender == 1 then
    return 14
  end
  return 13
end

-- The dynamic Oak touchscreen menus behind sharedU8var, mirroring the
-- source context-menu table (menu 3: evaluate/quit, menu 4: evaluate/
-- national/quit, menu 5: national/quit with bank-271 labels 10/11,
-- 12/13/14, and 15/16).
ProfessorPhonePrograms.OAK_MENUS = {
  [0] = { id = 3, base = 10, choices = { "evaluate", "quit" } },
  [1] = { id = 4, base = 12, choices = { "evaluate", "national", "quit" } },
  [2] = { id = 5, base = 15, choices = { "national", "quit" } },
}

-- Resolves the dynamic Oak menu identity behind sharedU8var: the
-- national dex without the johto acknowledgement opens menu 4, with
-- it menu 5, else menu 3.
---@param nationalDex boolean national dex ownership
---@param johtoAcked boolean johto completion acknowledgement
---@return integer 0..2 menu index
function ProfessorPhonePrograms.oakMenuIndex(nationalDex, johtoAcked)
  if nationalDex == true then
    if johtoAcked == true then
      return 2
    end
    return 1
  end
  return 0
end

-- Resolves the dynamic Oak answer outcome behind the menu choice:
-- evaluate walks the johto pair unless menu 5 forces the national
-- pair, national walks the national pair, quit ends with 21 and no
-- write. Answers outside the menu's choices fail loudly.
---@param shared integer 0..2 menu index
---@param answer string menu answer
---@return "johto"|"national"|"quit" evaluation outcome
function ProfessorPhonePrograms.oakAnswerOutcome(shared, answer)
  local menu = ProfessorPhonePrograms.OAK_MENUS[shared]
  assert(type(menu) == "table", "oak answers read their menu")
  local allowed = menu.choices
  assert(type(allowed) == "table", "oak menus carry their semantic choices")
  local valid = false
  for _, choice in ipairs(allowed) do
    if choice == answer then
      valid = true
    end
  end
  assert(valid, "oak answers name their menu choice")
  if answer == "quit" then
    return "quit"
  end
  if answer == "national" then
    return "national"
  end
  if shared == 2 then
    return "national"
  end
  return "johto"
end

-- The source rating ladders behind GetOakJohtoDexRating and
-- GetOakNationalDexRating: owned-count ceilings with their bank-666
-- message entries. Counts above the ladder top earn the gendered
-- completion entries with the closing fanfare.
ProfessorPhonePrograms.OAK_JOHTO_LADDER = {
  9,
  19,
  34,
  49,
  64,
  79,
  94,
  109,
  124,
  139,
  154,
  169,
  184,
  199,
  214,
  229,
  244,
  253,
}

ProfessorPhonePrograms.OAK_JOHTO_LADDER_BASE = 28

ProfessorPhonePrograms.OAK_NATIONAL_LADDER = {
  100,
  150,
  200,
  250,
  300,
  350,
  400,
  435,
  465,
  475,
  483,
}

ProfessorPhonePrograms.OAK_NATIONAL_LADDER_BASE = 46

-- Resolves the dynamic Oak rating entry and fanfare behind the owned
-- count: the ladder entry, else the gendered completion entry with
-- the closing fanfare. The opening fanfare rides every rung.
---@param national boolean national versus johto evaluation
---@param count integer mythical-excluded owned count
---@param gender unknown player gender fact
---@return integer ratingEntry bank-666 rating entry
---@return string fanfare sequence to play behind the rating
function ProfessorPhonePrograms.oakRating(national, count, gender)
  assert(type(count) == "number" and count % 1 == 0 and count >= 0, "oak ratings read the owned count")
  local female = gender == "female" or gender == 1
  local ladder, base, topMale, topFemale
  if national == true then
    ladder, base, topMale, topFemale =
      ProfessorPhonePrograms.OAK_NATIONAL_LADDER, ProfessorPhonePrograms.OAK_NATIONAL_LADDER_BASE, 24, 25
  else
    ladder, base, topMale, topFemale =
      ProfessorPhonePrograms.OAK_JOHTO_LADDER, ProfessorPhonePrograms.OAK_JOHTO_LADDER_BASE, 22, 23
  end
  for step, ceiling in ipairs(ladder) do
    if count <= ceiling then
      return base + step - 1, "SEQ_ME_HYOUKA1"
    end
  end
  if female then
    return topFemale, "SEQ_ME_HYOUKA6"
  end
  return topMale, "SEQ_ME_HYOUKA6"
end

-- Advances the dynamic Oak menu: no answer waits, quit ends with 21
-- and no write, else the evaluation prints seen and owned through
-- slots 5/6 with the rating and its fanfare. Completion writes the
-- acknowledgement flag once and ends without the closer 21.
---@param session table<string, unknown> program session
---@param input table<string, unknown> player input
---@return { status: string, entries: integer[]?, fanfare: string? } outcome
function ProfessorPhonePrograms.stepOakMenu(session, input)
  assert(type(session) == "table", "oak menu steps its session")
  assert(type(input) == "table", "oak menu reads its input")
  local facts = session.facts --[[@as table<string, unknown>]]
  assert(type(facts) == "table", "oak answers read their labelled facts")
  local shared = facts.dynamicOakShared
  assert(type(shared) == "number" and shared % 1 == 0 and shared >= 0 and shared <= 2, "oak answers read their menu")
  local choice = input.choice
  if choice == nil then
    return { status = "waiting" }
  end
  local outcome = ProfessorPhonePrograms.oakAnswerOutcome(shared, choice)
  session.effectDone = true
  if outcome == "quit" then
    return { status = "done", entries = { 21 } }
  end
  local national = outcome == "national"
  local world = session.world --[[@as table<string, unknown>]]
  assert(type(world) == "table", "oak evaluations read the borrowed world")
  local read = world.read
  assert(type(read) == "function", "oak evaluations read the dex owner")
  local scope = national and "national" or "johto"
  ---@param value unknown
  ---@param what string dex count the read answers
  ---@return integer
  local function countFact(value, what)
    assert(type(value) == "number" and value % 1 == 0 and value >= 0, "oak evaluations read the " .. what)
    return value --[[@as integer]]
  end
  local seen = countFact(read(world, "dex." .. scope .. "-seen"), "seen count")
  local owned = countFact(read(world, "dex." .. scope .. "-caught"), "owned count")
  local rated = countFact(read(world, "dex." .. scope .. "-owned-ex-mythical"), "rating count")
  local complete = read(world, "dex." .. scope .. "-complete")
  assert(type(complete) == "boolean", "oak evaluations read completion")
  local entry, fanfare = ProfessorPhonePrograms.oakRating(national, rated, facts.playerGender)
  facts.dynamicOakSeen = seen
  facts.dynamicOakOwned = owned
  local entries = { 20, entry }
  if complete ~= true then
    entries[#entries + 1] = 21
    return { status = "done", entries = entries, fanfare = fanfare }
  end
  local setFlag = world.setFlag
  assert(type(setFlag) == "function", "oak completion writes its acknowledgement flag")
  local flag = national and "FLAG_SYS_OAK_ACKNOWLEDGED_NATIONAL_DEX_COMPLETION"
    or "FLAG_SYS_OAK_ACKNOWLEDGED_JOHTO_DEX_COMPLETION"
  setFlag(world, flag)
  return { status = "done", entries = { 20, entry }, fanfare = fanfare }
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
    facts = request.facts,
    effectDone = false,
  }
end

-- Advances one program step. Professor branches carry no world effect;
-- the step only records the single visit. Dynamic Oak menu sessions
-- stage their evaluation through the menu. Returns done.
---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string|{ status: string, entries: integer[]?, fanfare: string? } outcome
function ProfessorPhonePrograms.step(session, input)
  assert(type(session) == "table", "professor programs step their session")
  assert(type(input) == "table", "professor programs read their input")
  local facts = session.facts --[[@as table<string, unknown>]]
  if type(facts) == "table" and facts.dynamicOakMenu == true then
    return ProfessorPhonePrograms.stepOakMenu(session, input)
  end
  session.effectDone = true
  return "done"
end

return ProfessorPhonePrograms
