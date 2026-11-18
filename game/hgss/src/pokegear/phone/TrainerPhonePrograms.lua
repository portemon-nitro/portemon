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

TrainerPhonePrograms.DEFAULT_GYM_WEEKDAY = "saturday"

-- The dynamic gym-outgoing menu answers behind touchscreen menu 6
-- (bank-271 entries 18/19, Yes/No).
TrainerPhonePrograms.GYM_MENU_CHOICES = { "yes", "no" }

-- Resolves the dynamic gym outgoing opener bank entry 2.
---@return integer gym bank entry for the opener
function TrainerPhonePrograms.gymOutgoingOpenerEntry()
  return 2
end

-- Resolves the dynamic gym outgoing branch bank entry: 3 below
-- sixteen badges, 9 while the caller seeks a rematch, 4 outside the
-- rematch window, else the invitation 5 with the yes/no menu owed.
---@param hasBadges boolean sixteen-badge gate behind flag0
---@param seeking boolean staged rematch invitation behind flag1
---@param windowOk boolean rematch weekday and time match
---@return integer gym bank entry for the branch
function TrainerPhonePrograms.gymOutgoingBranchEntry(hasBadges, seeking, windowOk)
  if hasBadges ~= true then
    return 3
  end
  if seeking == true then
    return 9
  end
  if windowOk ~= true then
    return 4
  end
  return 5
end

-- Replicates the source dojo-full quirk exactly: the loop runs once
-- over the first compiled gym contact by source bug, and the
-- comparison keeps the source count<5 shape, so a yes always stages
-- the invitation with entry 6 and the room branch stays unreachable
-- as shipped (phone_scripts_gym_leader.c isDojoFull).
---@param callerKey string calling contact key
---@param firstKey string first compiled gym contact key
---@param firstSeeking boolean staged invitation on the first contact
---@return boolean dojo full
function TrainerPhonePrograms.gymDojoFull(callerKey, firstKey, firstSeeking)
  local count = 0
  -- Single-iteration source loop: only the first gym contact counts.
  if callerKey ~= firstKey and firstSeeking == true then
    count = count + 1
  end
  return count < 5
end

-- Resolves the dynamic gym outgoing answer bank entry: 7 on no,
-- 6 on yes with the staged invitation, else the unreachable room 8.
---@param answer string "yes"|"no" menu answer
---@param dojoFull boolean source dojo-full reading
---@return integer gym bank entry for the answer
function TrainerPhonePrograms.gymOutgoingAnswerEntry(answer, dojoFull)
  assert(answer == "yes" or answer == "no", "gym answers name their menu choice")
  if answer == "no" then
    return 7
  end
  if dojoFull == true then
    return 6
  end
  return 8
end

-- Advances the dynamic gym-outgoing menu: no answer waits, no ends
-- with 7 and no write, yes stages the seeking invitation with 6
-- behind the source always-full reading. Wins carry over from the
-- staged record exactly like the static rematch kind.
---@param session table<string, unknown> program session
---@param input table<string, unknown> player input
---@return string|{ status: string, entry: integer? } outcome
function TrainerPhonePrograms.stepGymMenu(session, input)
  assert(type(session) == "table", "gym menu steps its session")
  assert(type(input) == "table", "gym menu reads its input")
  local choice = input.choice
  if choice == nil then
    return { status = "waiting" }
  end
  assert(choice == "yes" or choice == "no", "gym answers name their menu choice")
  local facts = session.facts --[[@as table<string, unknown>]]
  assert(type(facts) == "table", "gym answers read their labelled facts")
  session.effectDone = true
  if choice == "no" then
    return { status = "done", entry = 7 }
  end
  local full = facts.dynamicGymDojoFull
  assert(type(full) == "boolean", "gym answers read the staged dojo reading")
  if full ~= true then
    return { status = "done", entry = 8 }
  end
  local world = session.world --[[@as table<string, unknown>]]
  assert(type(world) == "table", "gym invitations stage through the borrowed world")
  local setRematch = world.setRematch
  assert(type(setRematch) == "function", "gym invitations stage through durable companion state")
  local contact = session.contact --[[@as string]]
  local wins = 0
  local query = world.queryRematch
  if type(query) == "function" then
    local current = query(world, contact)
    if type(current) == "table" and type(current.wins) == "number" then
      wins = current.wins --[[@as integer]]
    end
  end
  setRematch(world, contact, { stage = 1, wins = wins })
  return { status = "done", entry = 6 }
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
    facts = request.facts,
    effectDone = false,
  }
end

-- Advances one program step. Invitation and ordinary trainer programs
-- never create an invitation: no generated source record identifies a
-- native invitation stage yet. Returns done once the branch resolves.
---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string|{ status: string, entry: integer? } outcome
function TrainerPhonePrograms.step(session, input)
  assert(type(session) == "table", "trainer programs step their session")
  assert(type(input) == "table", "trainer programs read their input")
  assert(type(session.program) == "string", "trainer sessions carry their program")
  assert(type(session.contact) == "string", "trainer sessions carry their contact")
  local facts = session.facts --[[@as table<string, unknown>]]
  if type(facts) == "table" and facts.dynamicGymMenu == true then
    return TrainerPhonePrograms.stepGymMenu(session, input)
  end
  if session.effectDone == true then
    return "done"
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
        local weekday, timeOfDay = record.rematchWeekday, record.rematchTimeOfDay
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
