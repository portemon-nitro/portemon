-- Native ruleset sessions through the common battle entrypoint: strikes
-- run move mechanics with observable damage instead of the generic fixed
-- settlement, operation budgets only change responsiveness, terminal and
-- repeated disposal release exactly once, unbound native rulesets fail
-- before running, and snapshots resume deterministically or reject.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

local NATIVE_FORMAT = "test:native-format"
local NATIVE_SEED = 0x1BADB002

---@return table loaded native session owner
local function executorOwner()
  return SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "the private native lifecycle owns HGSS ruleset sessions"
  )
end

---@return table frozen battle content carrying the native ruleset binding
local function nativeContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = executorOwner()
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "native-session-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "native-session-tests"
  )
  behaviors:registerFormat(NATIVE_FORMAT, { key = NATIVE_FORMAT }, "native-session-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@return table combatant seed striking with a single known move
local function tackleCombatant(id, seed)
  local entry = SessionFixture.combatant(id, seed)
  entry.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return entry
end

---@return table combatant seed carrying no usable move entry over a real record
local function bareCombatant(id)
  local entry = SessionFixture.combatant(id, 23)
  entry.mon.moves = {}
  return entry
end

---@return table<string, table<string, unknown>> immutable move facts for the fixture strikes
local function scenarioMoveFacts()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  return {
    TACKLE = catalog:move("TACKLE"),
    STRUGGLE = { power = 50, accuracy = 100, category = "physical", moveType = "normal", priority = 0 },
  }
end

---@param formRecord table<string, unknown> catalog form record carrying its semantic types
---@return string[] detached semantic types for the form
local function copyFormTypes(formRecord)
  local types = {} ---@type string[]
  for _, key in ipairs(formRecord.types --[[@as string[] ]]) do
    types[#types + 1] = key --[[@as string]]
  end
  return types
end

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, SpeciesFormFacts> static species facts for the fixture combatants
local function scenarioSpeciesFacts(seeds)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local facts = {}
  for _, seed in ipairs(seeds) do
    local mon = seed.mon --[[@as table<string, unknown>]]
    local species = mon.species --[[@as string]]
    local form = mon.form --[[@as integer]]
    local speciesRecord = catalog:species(species)
    local bucket = facts[species]
    if bucket == nil then
      bucket = {}
      facts[species] = bucket
    end
    bucket[form] = {
      baseStats = catalog:form(species, form).baseStats,
      growthCurve = catalog:growthCurve(speciesRecord.growthCurve --[[@as string]]),
      types = copyFormTypes(catalog:form(species, form)),
    }
  end
  return facts
end

---@return table detached native battle setup record
local function nativeScenario()
  local Executor = executorOwner()
  local alpha = tackleCombatant(1, 11)
  local beta = bareCombatant(2)
  return {
    ruleset = Executor.RULESET,
    format = NATIVE_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { alpha }),
      SessionFixture.participant(2, 2, "beta", { beta }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(),
    speciesFacts = scenarioSpeciesFacts({ alpha, beta }),
  }
end

---@return table detached native battle setup record with two healthy leads
local function healthyDuelScenario()
  local Executor = executorOwner()
  local alpha = tackleCombatant(1, 11)
  local beta = tackleCombatant(2, 23)
  return {
    ruleset = Executor.RULESET,
    format = NATIVE_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { alpha }),
      SessionFixture.participant(2, 2, "beta", { beta }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(),
    speciesFacts = scenarioSpeciesFacts({ alpha, beta }),
  }
end

---@param woundedSide integer side whose lead enters wounded beside a healthy reserve
---@return table detached native battle setup record with a wounded lead and benched reserves
local function woundedLeadScenario(woundedSide)
  local Executor = executorOwner()
  local alphaLead = tackleCombatant(1, 11)
  local alphaReserve = tackleCombatant(3, 31)
  local betaLead = tackleCombatant(2, 23)
  local betaReserve = tackleCombatant(4, 41)
  if woundedSide == 1 then
    alphaLead.mon.condition.currentHp = 1
  else
    betaLead.mon.condition.currentHp = 1
  end
  local seeds = { alphaLead, alphaReserve, betaLead, betaReserve }
  return {
    ruleset = Executor.RULESET,
    format = NATIVE_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { alphaLead, alphaReserve }),
      SessionFixture.participant(2, 2, "beta", { betaLead, betaReserve }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(),
    speciesFacts = scenarioSpeciesFacts(seeds),
  }
end

---@return table detached native battle setup record with two one-point leads beside benched reserves
local function mutualKnockoutScenario()
  local Executor = executorOwner()
  local alphaLead = bareCombatant(1)
  alphaLead.mon.condition.currentHp = 1
  local alphaReserve = tackleCombatant(3, 31)
  local betaLead = tackleCombatant(2, 23)
  betaLead.mon.condition.currentHp = 1
  local betaReserve = tackleCombatant(4, 41)
  local seeds = { alphaLead, alphaReserve, betaLead, betaReserve }
  return {
    ruleset = Executor.RULESET,
    format = NATIVE_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { alphaLead, alphaReserve }),
      SessionFixture.participant(2, 2, "beta", { betaLead, betaReserve }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(seeds),
    speciesFacts = scenarioSpeciesFacts(seeds),
  }
end

---@param collected table[] emitted events under inspection
---@param combatant integer roster identity expected to have fainted
---@return boolean true when a faint was announced for the combatant
local function announcesFaint(collected, combatant)
  for _, event in ipairs(collected) do
    if event.kind == "faint" then
      local payload = event.payload --[[@as table<string, unknown>]]
      if type(payload) == "table" and payload.combatant == combatant then
        return true
      end
    end
  end
  return false
end

---@param request table pending decision request under test
---@return table[] one strike per addressed actor against the opposing slot
local function answer(request)
  local opposing = 2
  if request.controller == "beta" then
    opposing = 1
  end
  local choices = {}
  for _, actor in ipairs(request.actors) do
    choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(opposing))
  end
  return choices
end

---@param collected table[] emitted events under inspection
---@return integer fixed one-point strikes
---@return integer mechanic strikes dealing more than one point
local function classify(collected)
  local fixed, heavy = 0, 0
  for _, event in ipairs(collected) do
    if event.kind == "strike" then
      fixed = fixed + 1
    elseif event.kind == "struck" then
      local payload = event.payload --[[@as table<string, unknown>]]
      Assert.isTrue(type(payload.damage) == "number", "mechanic strikes report their damage")
      if
        payload.damage --[[@as integer]]
        > 1
      then
        heavy = heavy + 1
      end
    end
  end
  return fixed, heavy
end

function T.native_ruleset_strikes_run_move_mechanics_deterministically()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local first = contracts.Battle.newSession(nativeScenario(), content)
  local second = contracts.Battle.newSession(nativeScenario(), content)
  local firstEvents = SessionFixture.driveToEnd(first, 64, answer)
  local secondEvents = SessionFixture.driveToEnd(second, 64, answer)
  Assert.deepEqual(firstEvents, secondEvents, "one seed replays one event sequence")
  local fixed, heavy = classify(firstEvents)
  Assert.equal(fixed, 0, "native strikes never settle as fixed one-point strikes")
  Assert.isTrue(heavy > 0, "native strikes deal mechanic damage")
  Assert.deepEqual(first:capture(), second:capture(), "one seed replays one terminal state")
  first:dispose()
  second:dispose()
end

function T.operation_budgets_change_responsiveness_only()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local narrow = contracts.Battle.newSession(nativeScenario(), content)
  local wide = contracts.Battle.newSession(nativeScenario(), content)
  local narrowEvents = SessionFixture.driveToEnd(narrow, 1, answer)
  local wideEvents = SessionFixture.driveToEnd(wide, 64, answer)
  Assert.deepEqual(narrowEvents, wideEvents, "budgets never reorder events, actions, or draws")
  Assert.deepEqual(narrow:capture(), wide:capture(), "budgets never move terminal state")
  narrow:dispose()
  wide:dispose()
end

function T.terminal_and_repeated_disposal_release_exactly_once()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local session = contracts.Battle.newSession(nativeScenario(), content)
  SessionFixture.driveToEnd(session, 64, answer)
  session:dispose()
  session:dispose()

  local fresh = contracts.Battle.newSession(nativeScenario(), content)
  fresh:dispose()
  fresh:dispose()
end

function T.unbound_native_bindings_fail_before_running()
  local contracts = SessionFixture.sessionContracts()
  Assert.throws(function()
    contracts.Battle.newSession(nativeScenario(), SessionFixture.makeContent())
  end, "native rulesets without a frozen binding never publish a session")
end

function T.snapshots_resume_deterministically_and_reject_garbage()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local content = nativeContent()
  local session = contracts.Battle.newSession(nativeScenario(), content)
  local waiting = SessionFixture.driveUntilSettled(session)
  Assert.equal(waiting.status, "waiting", "the first decision boundary opens")
  local snapshot = session:capture()
  SessionFixture.assertPlainData(snapshot)

  local revived = Executor.restore(snapshot, content)
  for _, live in ipairs({ session, revived }) do
    local frame = SessionFixture.driveUntilSettled(live)
    Assert.equal(frame.status, "waiting", "restored sessions reopen the same boundary")
    for _, request in ipairs(frame.request.requests) do
      local ok, replyErr = live:submit(SessionFixture.replyFor(request, answer(request)))
      Assert.isTrue(ok, "restored sessions accept the open replies")
      Assert.isNil(replyErr, "accepted replies carry no input error")
    end
  end
  local firstEvents = SessionFixture.driveToEnd(session, 16, answer)
  local secondEvents = SessionFixture.driveToEnd(revived, 16, answer)
  Assert.deepEqual(firstEvents, secondEvents, "restored sessions replay the same events")
  Assert.deepEqual(session:capture(), revived:capture(), "restored sessions reach the same state")
  session:dispose()
  revived:dispose()

  Assert.throws(function()
    Executor.restore({ version = 1 }, content)
  end, "malformed captures reject instead of resuming")
  snapshot.schedule = { kind = "other:schedule", version = 1, cursor = "opening", pendingFaints = {} }
  Assert.throws(function()
    Executor.restore(snapshot, content)
  end, "foreign schedule frames reject instead of resuming")
end

---@param holderItem string? held item key carried by the opening lead
---@param bench boolean true when a benched reserve joins the opening roster
---@return table detached native battle setup record with its money-up facts
local function prizeScenario(holderItem, bench)
  local Executor = executorOwner()
  local alpha = tackleCombatant(1, 11)
  if holderItem ~= nil then
    alpha.mon.heldItem = holderItem
  end
  local seeds = { alpha }
  local roster = { alpha }
  if bench == true then
    local reserve = bareCombatant(3)
    seeds[#seeds + 1] = reserve
    roster[#roster + 1] = reserve
  end
  local beta = bareCombatant(2)
  seeds[#seeds + 1] = beta
  return {
    ruleset = Executor.RULESET,
    format = NATIVE_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", roster),
      SessionFixture.participant(2, 2, "beta", { beta }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(),
    speciesFacts = scenarioSpeciesFacts(seeds),
    moneyUpItems = { "COIN" },
  }
end

function T.entry_scan_latches_the_prize_multiplier()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local holding = contracts.Battle.newSession(prizeScenario("COIN", false), content)
  Assert.equal(holding:capture().prizeMoneyValue, 2, "a money-up holder on the field latches the multiplier")
  holding:dispose()
  local plain = contracts.Battle.newSession(prizeScenario(nil, false), content)
  Assert.equal(plain:capture().prizeMoneyValue, 1, "battles without the hold effect keep the base multiplier")
  plain:dispose()
end

function T.the_latched_multiplier_survives_the_holder_leaving()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local session = contracts.Battle.newSession(prizeScenario("COIN", true), content)
  Assert.equal(session:capture().prizeMoneyValue, 2, "the holder latches the multiplier at send-out")
  local waiting = SessionFixture.driveUntilSettled(session)
  Assert.equal(waiting.status, "waiting", "the battle opens its decision boundary")
  for _, request in ipairs(waiting.request.requests) do
    local choices
    if request.controller == "alpha" then
      local actor = assert(request.actors[1], "the alpha request addresses its holder")
      choices = { SessionFixture.switchChoice(actor, 3) }
    else
      choices = answer(request)
    end
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, choices))
    Assert.isTrue(ok, "the boundary accepts the replies: " .. tostring(replyErr))
  end
  session:advance(64)
  Assert.equal(session:capture().prizeMoneyValue, 2, "the multiplier persists after the holder leaves")
  session:dispose()
end

function T.snapshots_preserve_the_latched_multiplier()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local content = nativeContent()
  local session = contracts.Battle.newSession(prizeScenario("COIN", false), content)
  local snapshot = session:capture()
  Assert.equal(snapshot.prizeMoneyValue, 2, "captures carry the latched multiplier")
  local revived = Executor.restore(snapshot, content)
  Assert.equal(revived:capture().prizeMoneyValue, 2, "restored sessions keep the latched multiplier")
  session:dispose()
  revived:dispose()
end

-- Battles that reach no terminal state keep taking turns: with both
-- sides standing after three full rounds, the fourth decision boundary
-- still opens, the round counter keeps sequencing, and no scripted result
-- is ever named.
function T.battles_without_a_terminal_state_continue_past_three_turns()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local session = contracts.Battle.newSession(healthyDuelScenario(), content)
  for turn = 1, 4 do
    local frame = SessionFixture.driveUntilSettled(session)
    Assert.equal(frame.status, "waiting", "turn " .. turn .. " still asks for decisions")
    for _, request in ipairs(frame.request.requests) do
      local ok, replyErr = session:submit(SessionFixture.replyFor(request, answer(request)))
      Assert.isTrue(ok, "turn " .. turn .. " replies are accepted")
      Assert.isNil(replyErr, "accepted replies carry no input error")
    end
    session:advance(64)
  end
  local boundary = SessionFixture.driveUntilSettled(session)
  Assert.equal(boundary.status, "waiting", "the fifth turn still asks for decisions")
  local snapshot = session:capture()
  Assert.equal(snapshot.round, 5, "the round counter keeps sequencing past the old bound")
  Assert.isNil(snapshot.outcome, "no terminal result is named while both sides stand")
  Assert.isTrue(snapshot.combatants[1].hp > 0, "the alpha lead is still standing")
  Assert.isTrue(snapshot.combatants[2].hp > 0, "the beta lead is still standing")
  session:dispose()
end

-- A knocked-out lead is replaced before normal turns resume: the fainted
-- occupant leaves, the bereaved side fields its healthy reserve with a
-- fresh entry, and the following turn addresses the reserve instead of
-- ending the battle. The owning side answers its own replacement while
-- the opposing side's reserve arrives without an external decision.
function T.fainted_leads_are_replaced_before_the_next_turn()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local session = contracts.Battle.newSession(woundedLeadScenario(1), content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local leadActivation = session:capture().combatants[1].active.activation
  local collected = {}
  for _, request in ipairs(opening.request.requests) do
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, answer(request)))
    Assert.isTrue(ok, "opening replies are accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
  end
  local knockout = session:advance(64)
  for _, event in ipairs(knockout.events or {}) do
    collected[#collected + 1] = event
  end
  local settled = session:capture()
  Assert.equal(settled.combatants[1].hp, 0, "the strike knocks out the wounded lead")
  Assert.isTrue(announcesFaint(collected, 1), "the knockout is announced before replacement")
  Assert.isNil(settled.positions[1].occupant, "the fainted occupant leaves its position")
  local waiting = SessionFixture.driveUntilSettled(session)
  Assert.isTrue(waiting.status ~= "ended", "the battle does not end on a replaceable faint")
  local replacement = nil
  for _, request in ipairs(waiting.request.requests) do
    if request.controller == "alpha" then
      replacement = request
    end
  end
  Assert.notNil(replacement, "the bereaved side is asked for its replacement before the next turn")
  local choices = {}
  for _, actor in ipairs(replacement.actors) do
    choices[#choices + 1] = SessionFixture.switchChoice(actor, 3)
  end
  local ok, replyErr = session:submit(SessionFixture.replyFor(replacement, choices))
  Assert.isTrue(ok, "the replacement reply is accepted")
  Assert.isNil(replyErr, "accepted replacements carry no input error")
  session:advance(64)
  local replaced = session:capture()
  Assert.equal(replaced.positions[1].occupant, 3, "the reserve takes the vacated position")
  Assert.isNil(replaced.combatants[1].active, "the fainted lead stays out of the field")
  Assert.notNil(replaced.combatants[3].active, "the reserve enters the field")
  Assert.isTrue(
    replaced.combatants[3].active.activation ~= leadActivation,
    "the reserve enters with a fresh entry"
  )
  local following = SessionFixture.driveUntilSettled(session)
  Assert.equal(following.status, "waiting", "the following turn asks for decisions")
  local addressesReserve = false
  for _, request in ipairs(following.request.requests) do
    if request.controller == "alpha" then
      for _, actor in ipairs(request.actors) do
        if actor.combatant == 3 then
          addressesReserve = true
        end
      end
    end
  end
  Assert.isTrue(addressesReserve, "the following turn addresses the reserve")
  Assert.isNil(session:capture().outcome, "no terminal result is named while reserves stand")
  session:dispose()

  local foeSession = contracts.Battle.newSession(woundedLeadScenario(2), content)
  local foeOpening = SessionFixture.driveUntilSettled(foeSession)
  Assert.equal(foeOpening.status, "waiting", "the opposing opening asks for decisions")
  local foeActivation = foeSession:capture().combatants[2].active.activation
  for _, request in ipairs(foeOpening.request.requests) do
    local answered, answerErr = foeSession:submit(SessionFixture.replyFor(request, answer(request)))
    Assert.isTrue(answered, "opposing opening replies are accepted")
    Assert.isNil(answerErr, "accepted replies carry no input error")
  end
  local foeKnockout = foeSession:advance(64)
  local foeCollected = {}
  for _, event in ipairs(foeKnockout.events or {}) do
    foeCollected[#foeCollected + 1] = event
  end
  Assert.equal(foeSession:capture().combatants[2].hp, 0, "the strike knocks out the opposing lead")
  Assert.isTrue(announcesFaint(foeCollected, 2), "the opposing knockout is announced")
  for _ = 1, 6 do
    if foeSession:capture().positions[2].occupant == 4 then
      break
    end
    local boundary = SessionFixture.driveUntilSettled(foeSession)
    if boundary.status == "ended" then
      break
    end
    for _, request in ipairs(boundary.request.requests) do
      Assert.isTrue(
        request.controller ~= "beta",
        "the opposing reserve arrives without an external decision"
      )
      local advanceOk, advanceErr = foeSession:submit(SessionFixture.replyFor(request, answer(request)))
      Assert.isTrue(advanceOk, "standing-side replies are accepted")
      Assert.isNil(advanceErr, "accepted replies carry no input error")
    end
    foeSession:advance(64)
  end
  local foeReplaced = foeSession:capture()
  Assert.isTrue(foeReplaced.status ~= "ended", "the battle does not end on a replaceable faint")
  Assert.equal(foeReplaced.positions[2].occupant, 4, "the opposing reserve takes its position")
  Assert.isNil(foeReplaced.combatants[2].active, "the fainted opposing lead stays out")
  Assert.notNil(foeReplaced.combatants[4].active, "the opposing reserve enters the field")
  Assert.isTrue(
    foeReplaced.combatants[4].active.activation ~= foeActivation,
    "the opposing reserve enters with a fresh entry"
  )
  Assert.isNil(foeReplaced.outcome, "no terminal result is named while reserves stand")
  foeSession:dispose()
end

-- A struggle recoil that knocks out both leads settles every ordered
-- replacement through the session: both faints announce, the bereaved
-- player side is asked for its reserve while the foe resolves internally,
-- and both reserves hold their positions before the next turn instead
-- of ending the battle.
function T.simultaneous_knockouts_replace_both_sides_before_the_next_turn()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local session = contracts.Battle.newSession(mutualKnockoutScenario(), content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  for _, request in ipairs(opening.request.requests) do
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, answer(request)))
    Assert.isTrue(ok, "opening replies are accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
  end
  local collected = {}
  local knockout = session:advance(64)
  for _, event in ipairs(knockout.events or {}) do
    collected[#collected + 1] = event
  end
  Assert.equal(session:capture().combatants[1].hp, 0, "the recoil knocks out the struggling lead")
  Assert.equal(session:capture().combatants[2].hp, 0, "the struggle knocks out the defending lead")
  Assert.isTrue(announcesFaint(collected, 1), "the recoil knockout is announced")
  Assert.isTrue(announcesFaint(collected, 2), "the defending knockout is announced")
  local waiting = SessionFixture.driveUntilSettled(session)
  Assert.equal(waiting.status, "waiting", "the double knockout suspends on replacement")
  local replacement = nil
  for _, request in ipairs(waiting.request.requests) do
    if request.controller == "alpha" then
      replacement = request
    else
      Assert.isTrue(false, "the bereaved foe resolves without an external decision")
    end
  end
  Assert.notNil(replacement, "the bereaved player side is asked for its replacement")
  local choices = {}
  for _, actor in ipairs(replacement.actors) do
    Assert.equal(actor.combatant, 1, "the replacement answers the fainted lead")
    choices[#choices + 1] = SessionFixture.switchChoice(actor, 3)
  end
  local ok, replyErr = session:submit(SessionFixture.replyFor(replacement, choices))
  Assert.isTrue(ok, "the replacement reply is accepted")
  Assert.isNil(replyErr, "accepted replacements carry no input error")
  session:advance(64)
  local replaced = session:capture()
  Assert.equal(replaced.positions[1].occupant, 3, "the player reserve takes the vacated position")
  Assert.equal(replaced.positions[2].occupant, 4, "the foe reserve takes its position without a decision")
  Assert.isNil(replaced.outcome, "no terminal result is named while reserves stand")
  local following = SessionFixture.driveUntilSettled(session)
  Assert.equal(following.status, "waiting", "the following turn asks for decisions")
  local addressesReserve = false
  for _, request in ipairs(following.request.requests) do
    if request.controller == "alpha" then
      for _, actor in ipairs(request.actors) do
        if actor.combatant == 3 then
          addressesReserve = true
        end
      end
    end
  end
  Assert.isTrue(addressesReserve, "the following turn addresses the reserve")
  session:dispose()
end

-- A last-stand knockout with no living reserve ends the battle instead
-- of asking for a replacement: the faint is announced, the position stays
-- vacant, and the terminal marker names the surviving standings with no
-- further turn.
function T.a_final_knockout_without_a_reserve_ends_the_battle()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local Executor = executorOwner()
  local alpha = tackleCombatant(1, 11)
  local beta = tackleCombatant(2, 23)
  beta.mon.condition.currentHp = 1
  local scenario = {
    ruleset = Executor.RULESET,
    format = NATIVE_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { alpha }),
      SessionFixture.participant(2, 2, "beta", { beta }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(),
    speciesFacts = scenarioSpeciesFacts({ alpha, beta }),
  }
  local session = contracts.Battle.newSession(scenario, content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  for _, request in ipairs(opening.request.requests) do
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, answer(request)))
    Assert.isTrue(ok, "opening replies are accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
  end
  local knockout = session:advance(64)
  local collected = {}
  for _, event in ipairs(knockout.events or {}) do
    collected[#collected + 1] = event
  end
  Assert.isTrue(announcesFaint(collected, 2), "the final knockout is announced")
  local settled = session:capture()
  Assert.equal(settled.combatants[2].hp, 0, "the losing lead stays knocked out")
  Assert.isNil(settled.positions[2].occupant, "the vacated position stays vacant")
  Assert.isTrue(settled.combatants[1].hp > 0, "the surviving lead is still standing")
  local boundary = SessionFixture.driveUntilSettled(session)
  Assert.equal(boundary.status, "ended", "no reserve means no replacement and no next turn")
  Assert.notNil(boundary.outcome, "the final knockout still names its terminal result")
  Assert.equal(boundary.outcome.kind, "no_actors", "standings decide through the mapped terminal word")
  Assert.isNil(boundary.request, "ended battles ask for nothing")
  session:dispose()
end

-- A slower lead knocked out before it can act never spends its action:
-- the knockout turn settles exactly the faster strike and the faint, so
-- the fainted entry's queued action emits nothing after its activation.
function T.knocked_out_leads_spend_no_later_action()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local session = contracts.Battle.newSession(woundedLeadScenario(2), content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  for _, request in ipairs(opening.request.requests) do
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, answer(request)))
    Assert.isTrue(ok, "opening replies are accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
  end
  local knockout = session:advance(64)
  local struck = 0
  for _, event in ipairs(knockout.events or {}) do
    if event.kind == "struck" then
      struck = struck + 1
      Assert.equal(event.actionId, 1, "only the faster surviving strike lands")
    end
  end
  Assert.equal(struck, 1, "the fainted entry spends no action after its knockout")
  Assert.isTrue(announcesFaint(knockout.events or {}, 2), "the knockout is announced")
  Assert.equal(session:capture().combatants[2].hp, 0, "the slower lead stays knocked out")
  session:dispose()
end

-- A replacement reply naming no living reserve is refused and the
-- bereaved side is asked again: the continuation stays open until a
-- genuine reserve answers it.
function T.replacement_replies_must_name_a_living_reserve()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local session = contracts.Battle.newSession(woundedLeadScenario(1), content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  for _, request in ipairs(opening.request.requests) do
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, answer(request)))
    Assert.isTrue(ok, "opening replies are accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
  end
  session:advance(64)
  local waiting = SessionFixture.driveUntilSettled(session)
  Assert.equal(waiting.status, "waiting", "the knockout suspends on its replacement")
  local replacement = nil
  for _, request in ipairs(waiting.request.requests) do
    if request.controller == "alpha" then
      replacement = request
    end
  end
  Assert.notNil(replacement, "the bereaved side is asked for its replacement")
  local actor = assert(replacement.actors[1], "the replacement addresses its fainted entry")
  local refused, refuseErr = session:submit(
    SessionFixture.replyFor(replacement, { SessionFixture.switchChoice(actor, 2) })
  )
  Assert.isFalse(refused, "a foreign active mon answers no replacement")
  Assert.notNil(refuseErr, "refused replacements report their input error")
  local fainted, faintErr = session:submit(
    SessionFixture.replyFor(replacement, { SessionFixture.switchChoice(actor, 1) })
  )
  Assert.isFalse(fainted, "the fainted lead cannot replace itself")
  Assert.notNil(faintErr, "refused replacements report their input error")
  local again = SessionFixture.driveUntilSettled(session)
  Assert.equal(again.status, "waiting", "refused replies leave the continuation open")
  Assert.equal(
    again.request.requests[1].requestId,
    replacement.requestId,
    "the bereaved side is asked again with the same request"
  )
  local ok, replyErr = session:submit(
    SessionFixture.replyFor(replacement, { SessionFixture.switchChoice(actor, 3) })
  )
  Assert.isTrue(ok, "the living reserve is accepted")
  Assert.isNil(replyErr, "accepted replacements carry no input error")
  session:advance(64)
  Assert.equal(session:capture().positions[1].occupant, 3, "the reserve takes the vacated position")
  session:dispose()
end

-- An open replacement survives interruption: capturing while the bereaved
-- side still owes its reserve and restoring reopens the identical
-- request, accepts the same reply, and replays the same entry with the
-- same following state.
function T.open_replacements_restore_identically_across_snapshots()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local content = nativeContent()
  local session = contracts.Battle.newSession(woundedLeadScenario(1), content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  for _, request in ipairs(opening.request.requests) do
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, answer(request)))
    Assert.isTrue(ok, "opening replies are accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
  end
  session:advance(64)
  local waiting = SessionFixture.driveUntilSettled(session)
  Assert.equal(waiting.status, "waiting", "the knockout suspends on its replacement")
  local snapshot = session:capture()
  SessionFixture.assertPlainData(snapshot)
  local revived = Executor.restore(snapshot, content)
  local first = SessionFixture.driveUntilSettled(session)
  local second = SessionFixture.driveUntilSettled(revived)
  Assert.deepEqual(second.request, first.request, "restored sessions reopen the identical replacement request")
  for _, live in ipairs({ session, revived }) do
    local boundary = SessionFixture.driveUntilSettled(live)
    for _, request in ipairs(boundary.request.requests) do
      local choices = {}
      for _, entry in ipairs(request.actors) do
        choices[#choices + 1] = SessionFixture.switchChoice(entry, 3)
      end
      local ok, replyErr = live:submit(SessionFixture.replyFor(request, choices))
      Assert.isTrue(ok, "restored sessions accept the open replacement reply")
      Assert.isNil(replyErr, "accepted replacements carry no input error")
    end
  end
  local firstFrame = session:advance(64)
  local secondFrame = revived:advance(64)
  Assert.deepEqual(secondFrame.events, firstFrame.events, "restored sessions replay the same entry")
  Assert.deepEqual(revived:capture(), session:capture(), "restored sessions reach the same following state")
  session:dispose()
  revived:dispose()
end

-- Fixed battle-stream seed for the projection duels below. Its early
-- draws never crit, so damage comparisons stay roll-shaped in every
-- action order the tests below exercise.
local PROJECTION_SEED = 7

---@param priority integer compiled move priority carried by the immutable facts
---@param moveType string semantic move type carried by the immutable facts
---@param power integer compiled strike power carried by the immutable facts
---@return table<string, unknown> immutable facts for one ordinary strike
local function strikeFacts(priority, moveType, power)
  return { power = power, accuracy = 0, category = "physical", moveType = moveType, priority = priority }
end

---@return table<string, unknown> immutable fallback facts for the struggle action
local function struggleFacts()
  return { power = 50, accuracy = 100, category = "physical", moveType = "normal", priority = 0 }
end

---@param id integer nonreused positive combatant identity
---@param seed integer fixed generator state for the underlying mon
---@param species string catalog species key
---@param move string move identity carried by the single slot
---@return table combatant seed with one usable move entry
local function singleMoveCombatant(id, seed, species, move)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = 9 }))
  mon.moves = { { move = move, pp = 35, ppUps = 0 } }
  return { id = id, mon = mon }
end

---@param entries table[] static species entries pairing a catalog species with its semantic types
---@return table<string, table<integer, table<string, unknown>>> static species facts with semantic types
local function typedSpeciesFacts(entries)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local facts = {}
  for _, entry in ipairs(entries) do
    local speciesRecord = catalog:species(entry.species)
    local types = {}
    for _, key in ipairs(entry.types) do
      types[#types + 1] = key
    end
    facts[entry.species] = {
      [0] = {
        baseStats = catalog:form(entry.species, 0).baseStats,
        growthCurve = catalog:growthCurve(speciesRecord.growthCurve),
        types = types,
      },
    }
  end
  return facts
end

---@return table frozen battle content binding the native ruleset over a closed test chart
local function chartContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local Executor = executorOwner()
  local keys = { "normal", "fire", "water", "grass", "ice", "dragon", "bug", "ghost" }
  local doubled = {
    ["fire|grass"] = true,
    ["fire|ice"] = true,
    ["fire|bug"] = true,
    ["water|fire"] = true,
    ["grass|water"] = true,
    ["ice|grass"] = true,
    ["ice|dragon"] = true,
    ["dragon|dragon"] = true,
    ["ghost|ghost"] = true,
    ["bug|grass"] = true,
  }
  local halved = {
    ["fire|fire"] = true,
    ["fire|water"] = true,
    ["fire|dragon"] = true,
    ["water|water"] = true,
    ["water|grass"] = true,
    ["water|dragon"] = true,
    ["grass|fire"] = true,
    ["grass|grass"] = true,
    ["grass|dragon"] = true,
    ["grass|bug"] = true,
    ["ice|fire"] = true,
    ["ice|water"] = true,
  }
  local builder = ContentBuilder.new()
  for _, attack in ipairs(keys) do
    local relations = {}
    for _, defend in ipairs(keys) do
      local numerator, denominator = 1, 1
      local pair = attack .. "|" .. defend
      if doubled[pair] == true then
        numerator, denominator = 2, 1
      elseif halved[pair] == true then
        numerator, denominator = 1, 2
      elseif pair == "normal|ghost" then
        numerator, denominator = 0, 1
      end
      relations[#relations + 1] = { attack = attack, defend = defend, numerator = numerator, denominator = denominator }
    end
    builder:define("types", attack, { key = attack, name = attack, relations = relations }, "projection-tests")
  end
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "projection-tests"
  )
  behaviors:registerFormat(NATIVE_FORMAT, { key = NATIVE_FORMAT }, "projection-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@param alpha table combatant seed for the owning side
---@param beta table combatant seed for the opposing side
---@param moveFacts table<string, table<string, unknown>> immutable move facts
---@param speciesFacts table static species facts with semantic types
---@param seed integer battle stream seed
---@return table live native session over the projection duel
local function projectionDuel(alpha, beta, moveFacts, speciesFacts, seed)
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local scenario = {
    ruleset = Executor.RULESET,
    format = NATIVE_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { alpha }),
      SessionFixture.participant(2, 2, "beta", { beta }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = seed },
    formatState = {},
    moveFacts = moveFacts,
    speciesFacts = speciesFacts,
  }
  return contracts.Battle.newSession(scenario, chartContent())
end

---@param session table live native session at its opening decision boundary
---@return table[] turn events in execution order
local function playOpeningTurn(session)
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the opening turn asks for decisions")
  for _, request in ipairs(frame.request.requests) do
    local target = 2
    if request.controller == "beta" then
      target = 1
    end
    local choices = {}
    for _, actor in ipairs(request.actors) do
      choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(target))
    end
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, choices))
    Assert.isTrue(ok, "opening replies are accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
  end
  local turn = session:advance(64)
  return turn.events or {}
end

---@param events table[] emitted events in execution order
---@return string|nil move identity behind the first landed strike
local function firstStriker(events)
  for _, event in ipairs(events) do
    if event.kind == "struck" then
      local cause = event.cause --[[@as table<string, unknown>]]
      return cause.key --[[@as string]]
    end
  end
  return nil
end

---@param session table live native session after its turn
---@param combatant integer combatant identity under inspection
---@return integer damage dealt to that combatant so far
local function damageTaken(session, combatant)
  local snapshot = session:capture()
  local combatants = snapshot.combatants --[[@as table<integer, table<string, unknown>>]]
  local record = combatants[combatant] --[[@as table<string, unknown>]]
  return (record.entryHp --[[@as integer]]) - (record.hp --[[@as integer]])
end

-- Move priority brackets dominate Speed while lowered priority waits: across
-- battle seeds a slower combatant striking with raised priority always lands
-- before a faster neutral strike, and a faster combatant striking with lowered
-- priority always lands after a slower neutral strike. Both strikes are weak
-- enough that every seed lands both, so the first landed strike names the
-- winner without any knockout masking the order.
function T.slower_raised_priority_strikes_first_and_faster_lowered_priority_strikes_last()
  local facts = {
    TACKLE = strikeFacts(0, "normal", 1),
    QUICK_ATTACK = strikeFacts(1, "normal", 1),
    VITAL_THROW = strikeFacts(-1, "normal", 1),
    STRUGGLE = struggleFacts(),
  }
  local species = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "EEVEE", types = { "normal" } },
  })
  for seed = 1, 8 do
    local raised = projectionDuel(
      singleMoveCombatant(1, 11, "CHIKORITA", "QUICK_ATTACK"),
      singleMoveCombatant(2, 11, "EEVEE", "TACKLE"),
      facts,
      species,
      seed
    )
    Assert.equal(
      firstStriker(playOpeningTurn(raised)),
      "QUICK_ATTACK",
      "raised priority beats Speed on seed " .. seed
    )
    raised:dispose()

    local lowered = projectionDuel(
      singleMoveCombatant(1, 11, "EEVEE", "VITAL_THROW"),
      singleMoveCombatant(2, 11, "CHIKORITA", "TACKLE"),
      facts,
      species,
      seed
    )
    Assert.equal(
      firstStriker(playOpeningTurn(lowered)),
      "TACKLE",
      "lowered priority waits on seed " .. seed
    )
    lowered:dispose()
  end
end

-- Only genuine Speed ties draw the battle stream: an unequal-Speed turn
-- consumes exactly one fewer draw than the same turn with tied Speeds, and
-- the faster combatant leads every seed without any draw to take.
function T.unequal_speeds_order_without_tie_draws_while_true_ties_draw_once()
  local facts = {
    TACKLE = strikeFacts(0, "normal", 1),
    QUICK_ATTACK = strikeFacts(0, "normal", 1),
    STRUGGLE = struggleFacts(),
  }
  local species = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "EEVEE", types = { "normal" } },
  })
  local mixed = projectionDuel(
    singleMoveCombatant(1, 11, "CHIKORITA", "TACKLE"),
    singleMoveCombatant(2, 11, "EEVEE", "QUICK_ATTACK"),
    facts,
    species,
    PROJECTION_SEED
  )
  playOpeningTurn(mixed)
  local mixedCalls = mixed:capture().rng.calls
  mixed:dispose()
  local tied = projectionDuel(
    singleMoveCombatant(1, 11, "CHIKORITA", "TACKLE"),
    singleMoveCombatant(2, 11, "CHIKORITA", "QUICK_ATTACK"),
    facts,
    species,
    PROJECTION_SEED
  )
  playOpeningTurn(tied)
  local tiedCalls = tied:capture().rng.calls
  tied:dispose()
  Assert.equal(tiedCalls, mixedCalls + 1, "a genuine tie costs exactly one tie draw over its unequal control")
  for seed = 1, 8 do
    local duel = projectionDuel(
      singleMoveCombatant(1, 11, "CHIKORITA", "TACKLE"),
      singleMoveCombatant(2, 11, "EEVEE", "QUICK_ATTACK"),
      facts,
      species,
      seed
    )
    Assert.equal(
      firstStriker(playOpeningTurn(duel)),
      "QUICK_ATTACK",
      "the faster combatant leads on seed " .. seed
    )
    duel:dispose()
  end
end

-- Same-type bonus and matchup ratios reshape ordinary strikes: a matching
-- attacker type hits harder than an unmatching one with the same strike, a
-- doubled matchup hits harder than a halved one with the same stats, and a
-- chart immunity deals nothing where a neutral matchup wounds.
function T.matching_types_and_matchup_ratios_reshape_ordinary_strikes()
  local leaf = {
    MAGICAL_LEAF = strikeFacts(0, "grass", 60),
    STRUGGLE = struggleFacts(),
  }
  local honest = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "TOTODILE", types = { "water" } },
    { species = "EEVEE", types = { "normal" } },
    { species = "SHEDINJA", types = { "bug", "ghost" } },
  })
  local stabbed = projectionDuel(
    singleMoveCombatant(1, 11, "CHIKORITA", "MAGICAL_LEAF"),
    singleMoveCombatant(2, 23, "EEVEE", "MAGICAL_LEAF"),
    leaf,
    honest,
    PROJECTION_SEED
  )
  playOpeningTurn(stabbed)
  local stabbedDamage = damageTaken(stabbed, 2)
  stabbed:dispose()
  local unstabbed = projectionDuel(
    singleMoveCombatant(1, 11, "EEVEE", "MAGICAL_LEAF"),
    singleMoveCombatant(2, 23, "EEVEE", "MAGICAL_LEAF"),
    leaf,
    honest,
    PROJECTION_SEED
  )
  playOpeningTurn(unstabbed)
  local plainDamage = damageTaken(unstabbed, 2)
  unstabbed:dispose()
  Assert.isTrue(stabbedDamage > plainDamage, "matching attacker types hit harder with the same strike")

  local fire = {
    AERIAL_ACE = strikeFacts(0, "fire", 60),
    STRUGGLE = struggleFacts(),
  }
  local intoGrass = projectionDuel(
    singleMoveCombatant(1, 11, "CHIKORITA", "AERIAL_ACE"),
    singleMoveCombatant(2, 23, "CHIKORITA", "AERIAL_ACE"),
    fire,
    honest,
    PROJECTION_SEED
  )
  playOpeningTurn(intoGrass)
  local grassDamage = damageTaken(intoGrass, 2)
  intoGrass:dispose()
  local intoWater = projectionDuel(
    singleMoveCombatant(1, 11, "CHIKORITA", "AERIAL_ACE"),
    singleMoveCombatant(2, 23, "TOTODILE", "AERIAL_ACE"),
    fire,
    honest,
    PROJECTION_SEED
  )
  playOpeningTurn(intoWater)
  local waterDamage = damageTaken(intoWater, 2)
  intoWater:dispose()
  Assert.isTrue(grassDamage > waterDamage, "doubled matchups hit harder than halved ones with the same stats")

  local heavy = {
    TACKLE = strikeFacts(0, "normal", 40),
    STRUGGLE = struggleFacts(),
  }
  local intoGhost = projectionDuel(
    singleMoveCombatant(1, 11, "EEVEE", "TACKLE"),
    singleMoveCombatant(2, 23, "SHEDINJA", "TACKLE"),
    heavy,
    honest,
    PROJECTION_SEED
  )
  playOpeningTurn(intoGhost)
  local ghostDamage = damageTaken(intoGhost, 2)
  intoGhost:dispose()
  local intoPlain = projectionDuel(
    singleMoveCombatant(1, 11, "EEVEE", "TACKLE"),
    singleMoveCombatant(2, 23, "EEVEE", "TACKLE"),
    heavy,
    honest,
    PROJECTION_SEED
  )
  playOpeningTurn(intoPlain)
  local plainTackle = damageTaken(intoPlain, 2)
  intoPlain:dispose()
  Assert.equal(ghostDamage, 0, "chart immunities deal nothing")
  Assert.isTrue(plainTackle > 0, "the neutral control wounds")
end

-- Combined and special attack identities follow the composed chart: one fire
-- strike doubles twice into a doubly weak pair, stays level on a split
-- pair, quarters into a doubly resisted pair, typeless strikes take no
-- attacker bonus without turning immune, and undeclared types fail instead
-- of striking neutrally. Defender pairs below are detached chart-projection
-- facts exercising the combining seam, mirroring the existing custom-chart
-- suites; attacker and defender species stay distinct so each side keeps
-- its own declared types.
function T.combined_and_special_attack_identities_follow_the_composed_chart()
  local fireFacts = {
    FLARE_BLITZ = strikeFacts(0, "fire", 60),
    TACKLE = strikeFacts(0, "normal", 1),
    STRUGGLE = struggleFacts(),
  }
  local attackerFacts = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "TOTODILE", types = { "grass", "ice" } },
  })
  local splitFacts = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "TOTODILE", types = { "grass", "water" } },
  })
  local resistedFacts = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "TOTODILE", types = { "water", "dragon" } },
  })
  local function fireInto(defenderTypesFacts)
    local duel = projectionDuel(
      singleMoveCombatant(1, 11, "CHIKORITA", "FLARE_BLITZ"),
      singleMoveCombatant(2, 23, "TOTODILE", "FLARE_BLITZ"),
      fireFacts,
      defenderTypesFacts,
      PROJECTION_SEED
    )
    playOpeningTurn(duel)
    local dealt = damageTaken(duel, 2)
    duel:dispose()
    return dealt
  end
  local quadrupled = fireInto(attackerFacts)
  local level = fireInto(splitFacts)
  local quartered = fireInto(resistedFacts)
  Assert.isTrue(quadrupled > level, "doubly weak pairs take more than split pairs")
  Assert.isTrue(level > quartered, "split pairs take more than doubly resisted pairs")

  local waterFacts = {
    AQUA_JET = strikeFacts(0, "water", 60),
    SWIFT = strikeFacts(0, "typeless", 60),
    TACKLE = strikeFacts(0, "normal", 1),
    STRUGGLE = struggleFacts(),
  }
  local waterHonest = typedSpeciesFacts({
    { species = "TOTODILE", types = { "water" } },
    { species = "EEVEE", types = { "normal" } },
    { species = "SHEDINJA", types = { "bug", "ghost" } },
  })
  local stabbedWater = projectionDuel(
    singleMoveCombatant(1, 11, "TOTODILE", "AQUA_JET"),
    singleMoveCombatant(2, 23, "EEVEE", "TACKLE"),
    waterFacts,
    waterHonest,
    PROJECTION_SEED
  )
  playOpeningTurn(stabbedWater)
  local waterDamage = damageTaken(stabbedWater, 2)
  stabbedWater:dispose()
  local typelessWater = projectionDuel(
    singleMoveCombatant(1, 11, "TOTODILE", "SWIFT"),
    singleMoveCombatant(2, 23, "EEVEE", "TACKLE"),
    waterFacts,
    waterHonest,
    PROJECTION_SEED
  )
  playOpeningTurn(typelessWater)
  local typelessDamage = damageTaken(typelessWater, 2)
  typelessWater:dispose()
  Assert.isTrue(waterDamage > typelessDamage, "typeless strikes take no attacker bonus")
  local typelessGhost = projectionDuel(
    singleMoveCombatant(1, 11, "TOTODILE", "SWIFT"),
    singleMoveCombatant(2, 23, "SHEDINJA", "TACKLE"),
    waterFacts,
    waterHonest,
    PROJECTION_SEED
  )
  playOpeningTurn(typelessGhost)
  local ghostTypeless = damageTaken(typelessGhost, 2)
  typelessGhost:dispose()
  Assert.isTrue(ghostTypeless > 0, "typeless strikes stay neutral against immunities")

  local voidFacts = {
    AURA_SPHERE = strikeFacts(0, "void", 60),
    TACKLE = strikeFacts(0, "normal", 1),
    STRUGGLE = struggleFacts(),
  }
  local plainSpecies = typedSpeciesFacts({
    { species = "EEVEE", types = { "normal" } },
  })
  local voidStriker = projectionDuel(
    singleMoveCombatant(1, 11, "EEVEE", "AURA_SPHERE"),
    singleMoveCombatant(2, 23, "EEVEE", "TACKLE"),
    voidFacts,
    plainSpecies,
    PROJECTION_SEED
  )
  local waiting = SessionFixture.driveUntilSettled(voidStriker)
  Assert.equal(waiting.status, "waiting", "the void strike opens its turn")
  for _, request in ipairs(waiting.request.requests) do
    local target = 2
    if request.controller == "beta" then
      target = 1
    end
    local choices = {}
    for _, actor in ipairs(request.actors) do
      choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(target))
    end
    local ok, replyErr = voidStriker:submit(SessionFixture.replyFor(request, choices))
    Assert.isTrue(ok, "void strike replies are accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
  end
  Assert.throws(function()
    voidStriker:advance(64)
  end, "undeclared attacking types fail instead of striking neutrally")
  voidStriker:dispose()

  local voidDefender = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "EEVEE", types = { "void" } },
  })
  local voidShield = projectionDuel(
    singleMoveCombatant(1, 11, "CHIKORITA", "FLARE_BLITZ"),
    singleMoveCombatant(2, 23, "EEVEE", "TACKLE"),
    fireFacts,
    voidDefender,
    PROJECTION_SEED
  )
  local shieldWaiting = SessionFixture.driveUntilSettled(voidShield)
  Assert.equal(shieldWaiting.status, "waiting", "the void shield opens its turn")
  for _, request in ipairs(shieldWaiting.request.requests) do
    local target = 2
    if request.controller == "beta" then
      target = 1
    end
    local choices = {}
    for _, actor in ipairs(request.actors) do
      choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(target))
    end
    local ok, replyErr = voidShield:submit(SessionFixture.replyFor(request, choices))
    Assert.isTrue(ok, "void shield replies are accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
  end
  Assert.throws(function()
    voidShield:advance(64)
  end, "undeclared defending types fail instead of striking neutrally")
  voidShield:dispose()
end

---@param snapshot table<string, unknown> detached interruption capture under staging
---@return table<string, unknown> detached capture with the slower lead fully raised in Speed
local function copySnapshotStages(snapshot)
  local staged = {}
  for key, value in pairs(snapshot) do
    if type(value) == "table" then
      local branch = {}
      for innerKey, innerValue in pairs(value --[[@as table<unknown, unknown>]]) do
        if type(innerValue) == "table" then
          local leaf = {}
          for leafKey, leafValue in pairs(innerValue --[[@as table<unknown, unknown>]]) do
            leaf[leafKey] = leafValue
          end
          branch[innerKey] = leaf
        else
          branch[innerKey] = innerValue
        end
      end
      staged[key] = branch
    else
      staged[key] = value
    end
  end
  local combatants = staged.combatants --[[@as table<integer, table<string, unknown>>]]
  combatants[1].stages =
    { attack = 0, defense = 0, speed = 6, specialAttack = 0, specialDefense = 0, accuracy = 0, evasion = 0 }
  return staged
end

-- Restored stage state steers later turns: raising the slower lead's
-- Speed stage through six stages in the interruption capture flips the
-- opening order after restore, while an untouched restore replays the
-- same order with both strikes still landing.
function T.restored_speed_stages_steer_the_replayed_order()
  local Executor = executorOwner()
  local facts = {
    TACKLE = strikeFacts(0, "normal", 1),
    QUICK_ATTACK = strikeFacts(0, "normal", 1),
    STRUGGLE = struggleFacts(),
  }
  local species = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "EEVEE", types = { "normal" } },
  })
  local function duel()
    return projectionDuel(
      singleMoveCombatant(1, 11, "CHIKORITA", "TACKLE"),
      singleMoveCombatant(2, 11, "EEVEE", "QUICK_ATTACK"),
      facts,
      species,
      PROJECTION_SEED
    )
  end
  local session = duel()
  local snapshot = session:capture()
  SessionFixture.assertPlainData(snapshot)
  session:dispose()

  local plain = Executor.restore(snapshot, chartContent())
  Assert.equal(
    firstStriker(playOpeningTurn(plain)),
    "QUICK_ATTACK",
    "the untouched restore keeps the faster lead first"
  )
  Assert.isTrue(damageTaken(plain, 1) > 0, "the untouched restore still lands the slower strike")
  Assert.isTrue(damageTaken(plain, 2) > 0, "the untouched restore still lands the faster strike")
  plain:dispose()

  local boosted = copySnapshotStages(snapshot)
  local revived = Executor.restore(boosted, chartContent())
  Assert.equal(
    firstStriker(playOpeningTurn(revived)),
    "TACKLE",
    "a fully raised slower lead moves first after restore"
  )
  Assert.isTrue(damageTaken(revived, 1) > 0, "the staged restore still lands the slower strike")
  Assert.isTrue(damageTaken(revived, 2) > 0, "the staged restore still lands the faster strike")
  revived:dispose()
end

return { tests = T }
