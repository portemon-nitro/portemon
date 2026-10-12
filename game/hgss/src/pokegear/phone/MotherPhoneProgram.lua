-- Mother policy: savings choice branches, balance formatting facts,
-- savings flag writes, and pending-gift announcements. Reading the
-- balance never starts a purchase; announcing a gift never grants it.
-- Grants stay with the staged gift-collection candidate. Pure source
-- policy, private to the foreground phone feature.

---@class MotherPhoneProgram
local MotherPhoneProgram = {}

MotherPhoneProgram.CHOICES = { "save", "keep" }

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
