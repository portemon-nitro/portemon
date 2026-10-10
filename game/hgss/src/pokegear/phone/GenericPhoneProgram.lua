-- Generic caller policy: source generic header chance and order, the
-- local-map response, story, weekday, time-of-day and contest gates,
-- repeat history, and gift or rematch side effects. Pure source policy:
-- selection is a deterministic function of labelled facts with no draws;
-- effects run through the borrowed world table only. Private to the
-- foreground phone feature.

---@class GenericPhoneProgram
local GenericPhoneProgram = {}

-- Selects the generic program identity in source order: a predefined
-- story call first, then the contest gate, then weekday and time gates,
-- then repeat history, else the greeting branch.
---@param facts table<string, unknown> labelled source facts for the caller
---@return string program identity
function GenericPhoneProgram.selectName(facts)
  assert(type(facts) == "table", "generic selection reads labelled facts")
  if facts.storyCall ~= nil then
    return "generic-story"
  end
  if facts.contest == true then
    return "generic-contest"
  end
  if facts.weekday ~= nil then
    return "generic-weekday"
  end
  if facts.repeatCall == true then
    return "generic-repeat"
  end
  return "generic-greeting"
end

-- Opens a program session over the borrowed world. Selection itself never
-- mutates; effects run once at the program stage through step.
---@param world table<string, unknown> borrowed world table
---@param request { contact: string, facts: table<string, unknown> }
---@return table<string, unknown> program session
function GenericPhoneProgram.select(world, request)
  assert(type(world) == "table", "generic programs borrow their world")
  assert(type(request) == "table" and type(request.contact) == "string", "generic programs name their contact")
  assert(type(request.facts) == "table", "generic programs read labelled facts")
  return {
    program = GenericPhoneProgram.selectName(request.facts),
    contact = request.contact,
    world = world,
    effectDone = false,
  }
end

---@param world table<string, unknown>
---@return table<string, boolean> the borrowed readiness table
local function ensureRematchTable(world)
  local ready = world.rematchReady
  if type(ready) ~= "table" then
    ready = {}
    world.rematchReady = ready
  end
  assert(type(ready) == "table", "generic rematch effects stage through the world table")
  return ready --[[@as table<string, boolean>]]
end

-- Advances one program step. The source effect runs once on the first
-- step: contest and story invitations stage rematch readiness for the
-- contact; every other branch only resolves its message. Returns done
-- once the effect has run.
---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string "done" once the program effect has run
function GenericPhoneProgram.step(session, input)
  assert(type(session) == "table", "generic programs step their session")
  assert(type(input) == "table", "generic programs read their input")
  assert(type(session.program) == "string", "generic sessions carry their program")
  assert(type(session.contact) == "string", "generic sessions carry their contact")
  if session.effectDone == true then
    return "done"
  end
  session.effectDone = true
  local program = session.program --[[@as string]]
  if program == "generic-contest" or program == "generic-story" then
    local world = session.world --[[@as table<string, unknown>]]
    assert(type(world) == "table", "generic effects stage through the borrowed world")
    ensureRematchTable(world)[
      session.contact --[[@as string]]
    ] = true
  end
  return "done"
end

return GenericPhoneProgram
