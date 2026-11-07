-- Mother policy: savings choice branches, balance formatting facts,
-- savings flag writes, and pending-gift announcements. Reading the
-- balance never starts a purchase; announcing a gift never grants it.
-- Grants stay with the staged gift-collection candidate. Pure source
-- policy, private to the foreground phone feature.
--
-- Dynamic flow (GearPhoneCall_Mother): intro 664.(7+param) where param
-- is MapHeader_GetMomCallIntroParam(playerMapSec), gift-full check
-- (msg 21, end, no choice), save-prompt variant by (scriptedCall==2
-- → 22; savingsFlag → balance≠0 ? 23 : 27; else balance≠0 ? 24 : 28),
-- touchscreen menu 2 (bank271 entries 8/9, tooltip 22), result msg
-- 25/26 + savings-flag write, hangup. Runs when the selector falls
-- through (outgoing, non-local, rival named + introduced, or
-- scriptedCall==2). Static scripts resolve without writing.

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
    facts = request.facts,
    effectDone = false,
    dynamicPhase = nil,
  }
end

-- The source dynamic Mother path behind the savings offer: any other
-- scripted branch (the local-map greeting, the early-rival greetings, or
-- an incoming predefined script) prints its static text and hangs up with
-- no choice. Mirrors the PhoneCall_GetScriptId_Mother early returns: only
-- an outgoing call away from home with the rival named and introduced,
-- or a scriptedCall==2 request, reaches the offer. ScriptedCall==2 is
-- checked first, before localMap and incoming (retail order).
---@param facts table<string, unknown> labelled source facts for the caller
---@return boolean true while the call may owe the savings choice
function MotherPhoneProgram.isSavingsCall(facts)
  assert(type(facts) == "table", "mother selection reads labelled facts")
  if facts.scriptedCall == 2 then
    return true
  end
  if facts.incomingCall == true then
    return false
  end
  if facts.localMap == true then
    return false
  end
  if facts.gaveRivalName ~= true then
    return false
  end
  if facts.talkedAfterNamingRival ~= true then
    return false
  end
  return true
end

-- Resolves the dynamic intro bank entry: 7 + momCallIntroParam, where
-- the param rides facts.momCallIntroParam (romdump maps catalog join)
-- defaulting to 10 (New Bark Town) when the world carries no map.
---@param facts table<string, unknown>
---@return integer bank-664 entry for the intro
function MotherPhoneProgram.introEntry(facts)
  assert(type(facts) == "table", "mother intro reads labelled facts")
  local param = facts.momCallIntroParam
  if type(param) ~= "number" or param % 1 ~= 0 or param < 0 or param > 15 then
    param = 10
  end
  return 7 + param
end

-- Resolves the dynamic save-prompt bank entry by the retail variant
-- rule: scriptedCall==2 → 22; savingsFlag → balance≠0 ? 23 : 27; else
-- balance≠0 ? 24 : 28. Entries are bank-664 numbers.
---@param facts table<string, unknown>
---@return integer bank-664 entry for the prompt
function MotherPhoneProgram.promptEntry(facts)
  assert(type(facts) == "table", "mother prompt reads labelled facts")
  if facts.scriptedCall == 2 then
    return 22
  end
  local savings = facts.savingsChoice == true or facts.momSavingsFlag == true
  local balance = facts.momBalance
  if type(balance) ~= "number" then
    balance = 0
  end
  if savings then
    return balance ~= 0 and 23 or 27
  end
  return balance ~= 0 and 24 or 28
end

-- Resolves the dynamic result bank entry: save → 25, keep → 26.
---@param choice string semantic answer
---@return integer bank-664 entry for the result
function MotherPhoneProgram.resultEntry(choice)
  assert(choice == "save" or choice == "keep", "mother results answer save or keep")
  return choice == "save" and 25 or 26
end

-- Advances one program step. Choice branches wait for an explicit save
-- or keep choice and write the savings flag exactly once, but only on
-- the dynamic path; static scripts resolve without writing and ignore a
-- late answer. Announcement and greeting branches resolve without
-- writing. Returns waiting while a choice is owed, else done. Dynamic
-- callers (PhoneCall dynamicMother) read the staged entries via
-- session.dynamicPhase: "prompt" owes the choice, "result" carries the
-- answer entry, "giftFull" ends without a choice.
---@param session table<string, unknown>
---@param input table<string, unknown>
---@return "done"|"waiting"|{ status: string, entry: integer? } outcome
function MotherPhoneProgram.step(session, input)
  assert(type(session) == "table", "mother programs step their session")
  assert(type(input) == "table", "mother programs read their input")
  assert(type(session.program) == "string", "mother sessions carry their program")
  if session.effectDone == true then
    return "done"
  end
  local facts = session.facts --[[@as table<string, unknown>]]
  assert(type(facts) == "table", "mother choices read their labelled facts")
  -- Dynamic path: the PhoneCall sets facts.dynamicMother via the
  -- selector fall-through; the program stages intro/prompt/result
  -- entries for the call to resolve through its message provider.
  if facts.dynamicMother == true or session.dynamicMother == true then
    return MotherPhoneProgram.stepDynamic(session, input)
  end
  local program = session.program --[[@as string]]
  if program == "mother-savings" or program == "mother-offer" then
    if not MotherPhoneProgram.isSavingsCall(facts) then
      session.effectDone = true
      return "done"
    end
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

-- Dynamic step behind the savings offer. First call (no choice yet):
-- gift-full ends with entry 21 and no choice; otherwise waits with the
-- prompt entry. Second call (with choice): writes the flag and ends
-- with the result entry. Gift-full keeps isSavingsCall true but skips
-- the menu, exactly like the retail flag1 branch.
---@param session table<string, unknown>
---@param input table<string, unknown>
---@return "done"|{ status: string, entry: integer? } outcome
function MotherPhoneProgram.stepDynamic(session, input)
  local facts = session.facts --[[@as table<string, unknown>]]
  if session.dynamicPhase == "result" then
    session.effectDone = true
    return "done"
  end
  if session.dynamicPhase == "prompt" or input.choice ~= nil then
    local choice = input.choice
    assert(choice == "save" or choice == "keep", "mother choices answer save or keep")
    session.effectDone = false
    session.dynamicPhase = "result"
    local world = session.world --[[@as table<string, unknown>]]
    assert(type(world) == "table", "mother effects stage through the borrowed world")
    local writeChoice = world.setMomSavingsChoice
    assert(type(writeChoice) == "function", "mother savings choices write the native event flag")
    writeChoice(world, choice == "save")
    return { status = "done", entry = MotherPhoneProgram.resultEntry(choice) }
  end
  -- Gift-full ends with no choice; the flag check happens after the
  -- intro in retail order, so the intro still prints first.
  if facts.momGiftFull == true then
    session.effectDone = true
    session.dynamicPhase = "giftFull"
    return { status = "done", entry = 21 }
  end
  session.dynamicPhase = "prompt"
  return { status = "waiting", entry = MotherPhoneProgram.promptEntry(facts) }
end

return MotherPhoneProgram
