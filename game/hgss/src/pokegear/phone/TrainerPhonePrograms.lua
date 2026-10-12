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
    effectDone = false,
  }
end

-- Advances one program step. Invitation and ordinary trainer programs
-- never create an invitation: no generated source record identifies a
-- native invitation stage yet. Returns done once the branch resolves.
---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string "done"
function TrainerPhonePrograms.step(session, input)
  assert(type(session) == "table", "trainer programs step their session")
  assert(type(input) == "table", "trainer programs read their input")
  assert(type(session.program) == "string", "trainer sessions carry their program")
  assert(type(session.contact) == "string", "trainer sessions carry their contact")
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
