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

---@param world table<string, unknown>
---@return table<string, boolean> the borrowed readiness table, created on first staging
local function readinessTable(world)
  local ready = world.rematchReady
  if ready == nil then
    ready = {}
    world.rematchReady = ready
  end
  assert(type(ready) == "table", "rematch readiness stages through the world table")
  return ready --[[@as table<string, boolean>]]
end

-- Advances one program step. Invitation and ordinary trainer programs
-- stage readiness once on the first step; every other branch only
-- resolves its message. Returns done once the branch has resolved.
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
  local program = session.program --[[@as string]]
  if program == "trainer-rematch" or program == "trainer-ordinary" or program == "gym-rematch" then
    local world = session.world --[[@as table<string, unknown>]]
    assert(type(world) == "table", "trainer effects stage through the borrowed world")
    readinessTable(world)[
      session.contact --[[@as string]]
    ] = true
  end
  return "done"
end

-- Reports the story tier behind rematch teams. Defaults to the first
-- tier when the borrowed world carries no story facts.
---@param world table<string, unknown> borrowed world table
---@return integer story tier
function TrainerPhonePrograms.tierFor(world)
  assert(type(world) == "table", "rematch tiers read the borrowed world")
  local tier = world.storyTier
  if tier == nil then
    return 1
  end
  assert(type(tier) == "number" and tier % 1 == 0 and tier >= 1, "the story tier stays a positive integer")
  return tier --[[@as integer]]
end

---@param contact string
---@param catalog table<string, unknown>?
---@return { weekday: string?, morning: boolean? }? the catalog window for the contact, when one is recorded
local function catalogWindow(contact, catalog)
  if type(catalog) ~= "table" then
    return nil
  end
  local rematches = catalog.rematches
  if type(rematches) ~= "table" then
    return nil
  end
  for _, entry in
    ipairs(rematches --[[@as table<integer, unknown>]])
  do
    if type(entry) == "table" then
      local record = entry --[[@as table<string, unknown>]]
      if record.contact == contact and record.weekday ~= nil then
        assert(type(record.weekday) == "string", "catalog rematch windows name their weekday")
        local morning = record.morning
        if morning ~= nil then
          assert(type(morning) == "boolean", "catalog rematch windows name their morning half")
        end
        return {
          weekday = record.weekday --[[@as string]],
          morning = morning --[[@as boolean?]],
        }
      end
    end
  end
  return nil
end

-- Reports whether the contact's weekday and time window currently
-- holds. Contacts without a recorded window stay eligible; the staged
-- invitation still gates readiness separately.
---@param contact string
---@param world table<string, unknown> borrowed world table
---@param catalog table<string, unknown>? borrowed contact catalog
---@return boolean eligible
function TrainerPhonePrograms.eligible(contact, world, catalog)
  assert(type(contact) == "string" and contact ~= "", "rematch eligibility names its contact")
  assert(type(world) == "table", "rematch eligibility reads the borrowed world")
  local window = catalogWindow(contact, catalog)
  if window == nil then
    return true
  end
  if world.weekday ~= nil and world.weekday ~= window.weekday then
    return false
  end
  if window.morning ~= nil and world.morning ~= nil and world.morning ~= window.morning then
    return false
  end
  return true
end

-- The single field readiness query: ready only when an invitation was
-- staged and the source window holds. Registration alone, a defeat, or
-- an unstaged contact never reports ready. Pure read: no mutation.
---@param contact string
---@param world table<string, unknown> borrowed world table
---@param catalog table<string, unknown>? borrowed contact catalog
---@return { ready: boolean, tier: integer }
function TrainerPhonePrograms.query(contact, world, catalog)
  assert(type(contact) == "string" and contact ~= "", "rematch queries name their contact")
  assert(type(world) == "table", "rematch queries read the borrowed world")
  local tier = TrainerPhonePrograms.tierFor(world)
  local ready = world.rematchReady
  local staged = type(ready) == "table" and ready[contact] == true
  if staged ~= true then
    return { ready = false, tier = tier }
  end
  return { ready = TrainerPhonePrograms.eligible(contact, world, catalog), tier = tier }
end

-- Projects the map marker for a contact: the same tier the query
-- reports, with its current readiness.
---@param contact string
---@param world table<string, unknown> borrowed world table
---@param catalog table<string, unknown>? borrowed contact catalog
---@return { tier: integer, ready: boolean }
function TrainerPhonePrograms.marker(contact, world, catalog)
  local status = TrainerPhonePrograms.query(contact, world, catalog)
  return { tier = status.tier, ready = status.ready }
end

-- Launches the accepted rematch at the queried tier: the team owner for
-- that tier must exist, and the launched team is the tier team, never a
-- neighboring tier. Fails with attribution when the tier team is
-- missing instead of substituting another team.
---@param contact string
---@param world table<string, unknown> borrowed world table carrying tier teams
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
  local teams = world.teamsByTier
  assert(type(teams) == "table", "rematch launches read the borrowed tier teams")
  local team = (teams --[[@as table<integer, unknown>]])[status.tier]
  if type(team) ~= "table" then
    local failure = Errors.new(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "no tier team waits for contact " .. contact .. " at tier " .. tostring(status.tier),
      { contact = contact, tier = status.tier }
    )
    error({ code = failure.code, message = failure.message, context = failure.context, domain = "trainer" })
  end
  return {
    tier = status.tier,
    team = team --[[@as table<string, unknown>]],
  }
end

-- Resolves the launched rematch. Only a qualified win clears the
-- staged invitation; losses, cancellations, blackouts, and full-party
-- interruptions preserve it for another attempt.
---@param contact string
---@param world table<string, unknown> borrowed world table
---@param outcome string source resolution outcome
---@return { contact: string, outcome: string, ready: boolean }
function TrainerPhonePrograms.resolve(contact, world, outcome)
  assert(type(contact) == "string" and contact ~= "", "rematch resolution names its contact")
  assert(type(world) == "table", "rematch resolution writes the borrowed world")
  assert(
    outcome == "win" or TrainerPhonePrograms.PRESERVING_OUTCOMES[outcome] == true,
    "rematch resolution names a source outcome"
  )
  if outcome == "win" then
    local ready = world.rematchReady
    if type(ready) == "table" then
      ready[contact] = nil
    end
    return { contact = contact, outcome = outcome, ready = false }
  end
  local ready = world.rematchReady
  local staged = type(ready) == "table" and ready[contact] == true
  return { contact = contact, outcome = outcome, ready = staged }
end

return TrainerPhonePrograms
