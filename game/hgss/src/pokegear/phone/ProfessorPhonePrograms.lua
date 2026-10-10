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
  session.effectDone = true
  return "done"
end

return ProfessorPhonePrograms
