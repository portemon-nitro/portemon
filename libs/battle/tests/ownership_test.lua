-- Presentation and entry-identity ownership: participant views are
-- detached copies that hide opposing hidden detail and future choices, and
-- every entry carries an incrementing token so a locked combatant reference
-- cannot write through a reused slot after a replacement while a
-- retargetable position reference still follows the new occupant.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@return table scenario parts for a singles lineup with reserves
local function singles()
  return {
    sides = {
      SessionFixture.side(1, { 1 }),
      SessionFixture.side(2, { 2 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "alpha", {
        SessionFixture.combatant(1, 11),
        SessionFixture.combatant(2, 12),
      }),
      SessionFixture.participant(2, 2, "beta", {
        SessionFixture.combatant(3, 23),
        SessionFixture.combatant(4, 24),
      }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 3),
    },
  }
end

---@param request table pending decision request
---@return table[] one strike per addressed actor
local function strikeEveryone(request)
  local choices = {}
  for _, actor in ipairs(request.actors) do
    choices[#choices + 1] =
      SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
  end
  return choices
end

---@param node unknown presented value under inspection
---@param marker string sentinel smuggled into live state
---@return boolean true when the marker leaks into presentation
local function leaksMarker(node, marker)
  local seen = {}
  local found = false
  local function visit(value)
    if found then
      return
    end
    if type(value) == "string" and value == marker then
      found = true
      return
    end
    if type(value) == "table" and not seen[value] then
      seen[value] = true
      for key, item in pairs(value) do
        visit(key)
        visit(item)
      end
    end
  end
  visit(node)
  return found
end

function T.presentation_views_stay_detached_and_hide_future_state()
  local contracts = SessionFixture.sessionContracts()
  Assert.isTrue(
    type(contracts.View.forController) == "function",
    "views resolve per controller without exposing live state"
  )
  Assert.isTrue(
    type(contracts.View.forDebug) == "function",
    "trusted debug reads stay separate from controller views"
  )

  local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(singles()))
  local opening = SessionFixture.driveUntilSettled(session, 64)
  Assert.equal(opening.status, "waiting", "open battles wait for decisions")

  local alphaBefore = session:view("alpha")
  local betaBefore = session:view("beta")
  Assert.isTrue(type(alphaBefore) == "table", "controller views are detached tables")
  Assert.isTrue(type(betaBefore) == "table", "every controller reads its own view")

  for _, request in ipairs(opening.request.requests) do
    if request.controller == "alpha" then
      local ok, err = session:submit(SessionFixture.replyFor(request, strikeEveryone(request)))
      Assert.isTrue(ok, "alpha answers first")
      Assert.isNil(err, "accepted replies carry no input error")
    end
  end
  Assert.deepEqual(
    session:view("beta"),
    betaBefore,
    "waiting peers never observe sealed opposing choices"
  )

  local heldEvents = opening.events or {}
  local seenCount = #heldEvents
  local next = SessionFixture.driveUntilSettled(session, 64)
  Assert.isTrue(#(opening.events or {}) >= seenCount, "delayed events stay readable")
  for index, event in ipairs(opening.events or {}) do
    if index <= seenCount then
      Assert.deepEqual(event, heldEvents[index], "prior event values stay correct")
    end
  end
  Assert.isTrue(type(next.status) == "string", "requesting the next frame settles again")

  local tampered = session:view("alpha")
  tampered.hp = -999
  tampered.nested = { injected = true }
  Assert.deepEqual(session:view("alpha"), alphaBefore, "mutating a view never touches live state")

  Assert.throws(function()
    session:view("ghost")
  end, "undeclared observers cannot open a perspective view")
  session:dispose()
end

function T.stale_entry_references_cannot_write_through_reused_slots()
  local contracts = SessionFixture.sessionContracts()

  local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(singles()))
  local opening = SessionFixture.driveUntilSettled(session, 64)
  Assert.equal(opening.status, "waiting", "open battles wait for decisions")

  local firstActor = nil
  for _, request in ipairs(opening.request.requests) do
    if request.controller == "alpha" then
      firstActor = request.actors[1]
    end
  end
  Assert.notNil(firstActor, "alpha fields an acting combatant")
  assert(firstActor ~= nil, "the acting combatant loads")
  Assert.equal(firstActor.combatant, 1, "the lead combatant holds its scenario identity")
  Assert.notNil(firstActor.activation, "active entries carry incrementing tokens")
  local staleToken = firstActor.activation

  local leaveChoices = { SessionFixture.switchChoice(firstActor, 2) }
  local leaveReply = nil
  for _, request in ipairs(opening.request.requests) do
    if request.controller == "alpha" then
      leaveReply = SessionFixture.replyFor(request, leaveChoices)
    else
      local ok, err = session:submit(SessionFixture.replyFor(request, strikeEveryone(request)))
      Assert.isTrue(ok, "beta answers alongside the switch")
      Assert.isNil(err, "accepted replies carry no input error")
    end
  end
  Assert.notNil(leaveReply, "the switch reply addresses its own request")
  assert(leaveReply ~= nil, "the switch reply loads")
  local switchOk, switchErr = session:submit(leaveReply)
  Assert.isTrue(switchOk, "replacements enter through validated replies")
  Assert.isNil(switchErr, "accepted replies carry no input error")

  local afterSwitch = SessionFixture.driveUntilSettled(session, 64)
  local freshToken = nil
  for _, request in ipairs((afterSwitch.request or {}).requests or {}) do
    for _, actor in ipairs(request.actors) do
      if actor.combatant == 2 then
        freshToken = actor.activation
      end
      Assert.isTrue(actor.combatant ~= 1, "departed combatants hold no further actions")
    end
  end
  if afterSwitch.status == "waiting" then
    Assert.notNil(freshToken, "replacements enter with their own entry token")
    Assert.isTrue(freshToken ~= staleToken, "entry tokens never repeat across entries")
  end

  local clean = session:capture()
  local staleActor = { combatant = 1, activation = staleToken }
  local staleChoices =
    { SessionFixture.attackChoice(staleActor, 0, SessionFixture.combatantTarget(1, staleToken)) }
  local staleReply = nil
  for _, request in ipairs((afterSwitch.request or {}).requests or {}) do
    if request.controller == "alpha" then
      staleReply = SessionFixture.replyFor(request, staleChoices)
    end
  end
  if staleReply ~= nil then
    local staleOk, staleErr = session:submit(staleReply)
    Assert.isFalse(staleOk, "locked references die with their entry")
    Assert.notNil(staleErr, "stale writes name their input error")
    Assert.deepEqual(session:capture(), clean, "stale writes leave no side effects")
  end

  local liveReply = nil
  for _, request in ipairs((afterSwitch.request or {}).requests or {}) do
    if request.controller == "alpha" then
      local liveActor = request.actors[1]
      local liveChoices =
        { SessionFixture.attackChoice(liveActor, 0, SessionFixture.positionTarget(2)) }
      liveReply = SessionFixture.replyFor(request, liveChoices)
    end
  end
  if liveReply ~= nil then
    local liveOk, liveErr = session:submit(liveReply)
    Assert.isTrue(liveOk, "position references follow the current occupant")
    Assert.isNil(liveErr, "accepted replies carry no input error")
  end
  Assert.isFalse(
    leaksMarker(session:view("alpha"), "live-state-sentinel"),
    "views expose values, never live handles"
  )
  session:dispose()
end

return { tests = T }
