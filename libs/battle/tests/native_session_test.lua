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

---@param seeds table<integer, table<string, unknown>>? combatant seeds whose strikes and learnsets resolve
---@return table<string, table<string, unknown>> immutable move facts for the fixture strikes and learnsets
local function scenarioMoveFacts(seeds)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local facts = {
    TACKLE = catalog:move("TACKLE"),
    STRUGGLE = { power = 50, accuracy = 100, category = "physical", moveType = "normal", priority = 0 },
  }
  for _, seed in ipairs(seeds or {}) do
    local learned = seed.mon --[[@as table<string, unknown>]]
    for _, entry in ipairs(learned.moves --[[@as table<integer, table<string, unknown>>]]) do
      if type(entry) == "table" and type(entry.move) == "string" and facts[entry.move] == nil then
        facts[entry.move] = catalog:move(entry.move)
      end
    end
    local form = catalog:form(learned.species --[[@as string]], learned.form --[[@as integer]])
    for _, chance in ipairs(form.levelUpMoves) do
      if facts[chance.move] == nil then
        facts[chance.move] = catalog:move(chance.move)
      end
    end
  end
  return facts
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
      levelUpMoves = catalog:form(species, form).levelUpMoves,
      baseExpYield = speciesRecord.baseExpYield,
      evYield = speciesRecord.evYield,
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
    moveFacts = scenarioMoveFacts({ alpha, beta }),
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
    moveFacts = scenarioMoveFacts({ alpha, beta }),
    speciesFacts = scenarioSpeciesFacts({ alpha, beta }),
  }
end

---@param woundedSide integer side whose lead enters wounded beside a healthy reserve
---@return table detached native battle setup record with a wounded lead and benched reserves
local function woundedLeadScenario(woundedSide)
  local Executor = executorOwner()
  local alphaLead = tackleCombatant(1, 11)
  -- The opening lead always lands its strike, so the wounded exchange
  -- resolves identically on every battle-stream position.
  alphaLead.mon.moves = { { move = "SCRATCH", pp = 35, ppUps = 0 } }
  local alphaReserve = tackleCombatant(3, 31)
  local betaLead = tackleCombatant(2, 23)
  local betaReserve = tackleCombatant(4, 41)
  -- The identical leads tie on Speed, so the foe holds back to keep
  -- the opening exchange striking first regardless of the tie draw.
  betaLead.mon.heldItem = "LAGGING_TAIL"
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
    moveFacts = scenarioMoveFacts(seeds),
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
  -- The identical leads tie on Speed, so the foe holds back to keep
  -- the struggling lead striking first regardless of the tie draw.
  betaLead.mon.heldItem = "LAGGING_TAIL"
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

---@return table combatant seed pinned one experience below level twelve with a full move set
local function rewardRecipient(id, seed)
  local entry = { id = id, mon = SessionFixture.makeMon(seed, { species = "CHIKORITA", level = 11 }) }
  entry.mon.experience = 972
  entry.mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "POISONPOWDER", pp = 30, ppUps = 0 },
  }
  return entry
end

---@return table detached native battle setup with a pinned recipient against a wounded foe
local function rewardScenario()
  local Executor = executorOwner()
  local alpha = rewardRecipient(1, 11)
  local beta = tackleCombatant(2, 23)
  beta.mon.condition.currentHp = 1
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
    moveFacts = scenarioMoveFacts({ alpha, beta }),
    speciesFacts = scenarioSpeciesFacts({ alpha, beta }),
  }
end

---@param frame table settled battle frame under inspection
---@return table|nil the pending learning prompt, when one is open
local function findLearnPrompt(frame)
  if frame.request == nil then
    return nil
  end
  for _, request in ipairs(frame.request.requests) do
    if request.kind == "learn_move" then
      return request
    end
  end
  return nil
end

---@param actor table addressed recipient entry under reply
---@param decision string replace or decline
---@param slot integer? zero-based move slot for replacements
---@return table decision choice carrying the learning reply
local function learnChoice(actor, decision, slot)
  local payload = { decision = decision }
  if slot ~= nil then
    payload.slot = slot
  end
  return { actor = actor, kind = "confirm", payload = payload }
end

---@param events table[] emitted events under inspection
---@param kind string event identity under inspection
---@return table|nil the first event carrying that identity
local function findSessionEvent(events, kind)
  for _, event in ipairs(events) do
    if type(event) == "table" and event.kind == kind then
      return event
    end
  end
  return nil
end

---@param events table[] emitted events under inspection
---@param kind string event identity under inspection
---@return integer events carrying that identity
local function countSessionEvents(events, kind)
  local seen = 0
  for _, event in ipairs(events) do
    if type(event) == "table" and event.kind == kind then
      seen = seen + 1
    end
  end
  return seen
end

---@param session table live headless session under test
---@param budget integer operations per advance call
---@return table boundary frame at the next atomic boundary
---@return table[] every event emitted along the way
local function advanceCollecting(session, budget)
  local collected = {}
  for _ = 1, 64 do
    local frame = session:advance(budget)
    Assert.notNil(frame, "advance returns a battle frame")
    for _, event in ipairs(frame.events or {}) do
      collected[#collected + 1] = event
    end
    if frame.status ~= "running" then
      return frame, collected
    end
  end
  error("session did not settle within its operation bound")
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
    moveFacts = scenarioMoveFacts(seeds),
    speciesFacts = scenarioSpeciesFacts(seeds),
    moneyUpItems = { "AMULET_COIN" },
  }
end

function T.entry_scan_latches_the_prize_multiplier()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local holding = contracts.Battle.newSession(prizeScenario("AMULET_COIN", false), content)
  Assert.equal(holding:capture().prizeMoneyValue, 2, "a money-up holder on the field latches the multiplier")
  holding:dispose()
  local plain = contracts.Battle.newSession(prizeScenario(nil, false), content)
  Assert.equal(plain:capture().prizeMoneyValue, 1, "battles without the hold effect keep the base multiplier")
  plain:dispose()
end

function T.the_latched_multiplier_survives_the_holder_leaving()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local session = contracts.Battle.newSession(prizeScenario("AMULET_COIN", true), content)
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
  local session = contracts.Battle.newSession(prizeScenario("AMULET_COIN", false), content)
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
    moveFacts = scenarioMoveFacts({ alpha, beta }),
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
        levelUpMoves = catalog:form(entry.species, 0).levelUpMoves,
        baseExpYield = speciesRecord.baseExpYield,
        evYield = speciesRecord.evYield,
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
-- consumes exactly two fewer draws than the same turn with tied Speeds --
-- one action-order tie and one residual battler-order tie -- and the
-- faster combatant leads every seed without any draw to take.
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
  Assert.equal(
    tiedCalls,
    mixedCalls + 2,
    "a genuine tie costs one action tie draw plus one residual battler tie draw"
  )
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
  -- The cross-duel comparisons below share one stream seed, so a critical
  -- flip in either duel would mask the matchup under test; this seed keeps
  -- both opening strikes non-critical under the native divisor law.
  local MATCHUP_SEED = 11
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
    MATCHUP_SEED
  )
  playOpeningTurn(stabbed)
  local stabbedDamage = damageTaken(stabbed, 2)
  stabbed:dispose()
  local unstabbed = projectionDuel(
    singleMoveCombatant(1, 11, "EEVEE", "MAGICAL_LEAF"),
    singleMoveCombatant(2, 23, "EEVEE", "MAGICAL_LEAF"),
    leaf,
    honest,
    MATCHUP_SEED
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
    MATCHUP_SEED
  )
  playOpeningTurn(intoGrass)
  local grassDamage = damageTaken(intoGrass, 2)
  intoGrass:dispose()
  local intoWater = projectionDuel(
    singleMoveCombatant(1, 11, "CHIKORITA", "AERIAL_ACE"),
    singleMoveCombatant(2, 23, "TOTODILE", "AERIAL_ACE"),
    fire,
    honest,
    MATCHUP_SEED
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
    MATCHUP_SEED
  )
  playOpeningTurn(intoGhost)
  local ghostDamage = damageTaken(intoGhost, 2)
  intoGhost:dispose()
  local intoPlain = projectionDuel(
    singleMoveCombatant(1, 11, "EEVEE", "TACKLE"),
    singleMoveCombatant(2, 23, "EEVEE", "TACKLE"),
    heavy,
    honest,
    MATCHUP_SEED
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
    WATER_GUN = strikeFacts(0, "void", 60),
    TACKLE = strikeFacts(0, "normal", 1),
    STRUGGLE = struggleFacts(),
  }
  local plainSpecies = typedSpeciesFacts({
    { species = "EEVEE", types = { "normal" } },
  })
  local voidStriker = projectionDuel(
    singleMoveCombatant(1, 11, "EEVEE", "WATER_GUN"),
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

-- A knockout pays its reward through the resumable reward owner before the
-- battle moves on: the strike knocks out the wounded foe, experience and
-- effort land once on the battle-owned recipient with a level stat reload,
-- the full-set learning prompt suspends the battle with no terminal result
-- yet, and the chosen replacement applies exactly once before the battle
-- ends carrying the level gain for post-battle handling.
function T.knockout_rewards_pause_on_move_learning_before_the_outcome()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local session = contracts.Battle.newSession(rewardScenario(), content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  Assert.equal(
    #session:capture().combatants[1].mon.moves,
    4,
    "the recipient enters with a full move set"
  )
  for _, request in ipairs(opening.request.requests) do
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, answer(request)))
    Assert.isTrue(ok, "opening replies are accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
  end
  local boundary, collected = advanceCollecting(session, 64)
  Assert.isTrue(announcesFaint(collected, 2), "the strike knocks out the wounded foe")
  Assert.equal(session:capture().combatants[2].hp, 0, "the foe stays knocked out")
  Assert.equal(
    boundary.status,
    "waiting",
    "the knockout suspends on its learning prompt instead of ending the battle"
  )
  Assert.notNil(boundary.request, "suspended battles carry their pending prompt")
  local prompt = findLearnPrompt(boundary)
  Assert.notNil(prompt, "the suspension names the pending learning prompt")
  Assert.equal(prompt.controller, "alpha", "the owning side answers its own learning prompt")
  local actor = assert(prompt.actors[1], "the prompt addresses its recipient")
  Assert.equal(actor.combatant, 1, "the prompt addresses the battle recipient")
  Assert.equal(prompt.incomingMove, "SYNTHESIS", "crossing to level twelve prompts synthesis")
  Assert.equal(#prompt.currentMoves, 4, "the prompt carries the four current moves")
  Assert.isTrue(prompt.canDecline, "the prompt can be declined")
  local award = findSessionEvent(collected, "exp")
  Assert.notNil(award, "the knockout awards experience through the reward owner")
  Assert.equal(award.combatant, 1, "the award names the battle recipient")
  Assert.isTrue(type(award.gained) == "number", "awards report their experience")
  Assert.isTrue(award.gained --[[@as integer]] >= 1, "the award is positive")
  local reload = findSessionEvent(collected, "stats")
  Assert.notNil(reload, "the award recalculates level stats")
  Assert.isTrue(type(reload.maxHpBefore) == "number", "reloads report their previous maximum")
  Assert.isTrue(type(reload.maxHpAfter) == "number", "reloads report their recalculated maximum")
  Assert.isTrue(
    reload.maxHpAfter --[[@as integer]] > reload.maxHpBefore --[[@as integer]],
    "the level crossing raises the health maximum"
  )
  Assert.isNil(findSessionEvent(collected, "learn"), "no move is learned before the reply")
  local pending = session:capture()
  Assert.isNil(pending.outcome, "no terminal result is named while learning waits")
  local recipient = pending.combatants[1].mon
  Assert.equal(
    recipient.experience,
    972 + award.gained --[[@as integer]],
    "the award lands exactly once on the battle copy"
  )
  Assert.deepEqual(recipient.evs, {
    hp = 0,
    attack = 0,
    defense = 0,
    speed = 0,
    specialAttack = 0,
    specialDefense = 1,
  }, "the defeated yield lands as effort once")
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local Experience = require("libs.mons.src.gen4.Experience")
  local catalog = CatalogFixture.makeCatalog()
  local species = catalog:species("CHIKORITA")
  Assert.equal(
    Experience.level(catalog:growthCurve(species.growthCurve), recipient.experience),
    12,
    "the award crosses to level twelve"
  )
  local ok, replyErr =
    session:submit(SessionFixture.replyFor(prompt, { learnChoice(actor, "replace", 3) }))
  Assert.isTrue(ok, "the learning reply is accepted")
  Assert.isNil(replyErr, "accepted replies carry no input error")
  local ended, closing = advanceCollecting(session, 64)
  Assert.equal(
    ended.status,
    "ended",
    "the battle ends once learning resolves with no reserve behind the foe"
  )
  local learned = findSessionEvent(closing, "learn")
  Assert.notNil(learned, "the reply learns its move")
  Assert.equal(learned.move, "SYNTHESIS", "the reply learns the prompted move")
  Assert.equal(learned.combatant, 1, "the reply learns on the battle recipient")
  local finished = session:capture()
  Assert.equal(
    finished.combatants[1].mon.moves[4].move,
    "SYNTHESIS",
    "the replacement lands in the named slot"
  )
  Assert.equal(countSessionEvents(collected, "exp"), 1, "the opening run awards experience once")
  Assert.equal(countSessionEvents(closing, "exp"), 0, "the reply awards no experience again")
  Assert.equal(
    finished.combatants[1].mon.experience,
    972 + award.gained --[[@as integer]],
    "the reply never awards twice"
  )
  Assert.notNil(ended.outcome, "the finished battle names its terminal result")
  Assert.deepEqual(
    ended.outcome.evolutionEligible,
    { 1 },
    "the level gain surfaces once for post-battle handling"
  )
  local again, againErr =
    session:submit(SessionFixture.replyFor(prompt, { learnChoice(actor, "replace", 3) }))
  Assert.isFalse(again, "a stale reply after completion answers nothing")
  Assert.notNil(againErr, "stale replies report their input error")
  session:dispose()
end

-- A learning suspension survives interruption: capturing while the prompt
-- is open and restoring reopens the identical prompt, accepts the same
-- reply, replays the same completion, awards nothing twice, and carries
-- the same single post-battle eligibility.
function T.learning_suspensions_restore_without_a_second_award()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local content = nativeContent()
  local session = contracts.Battle.newSession(rewardScenario(), content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  for _, request in ipairs(opening.request.requests) do
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, answer(request)))
    Assert.isTrue(ok, "opening replies are accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
  end
  local boundary, collected = advanceCollecting(session, 64)
  Assert.equal(boundary.status, "waiting", "the knockout suspends on its learning prompt")
  local prompt = findLearnPrompt(boundary)
  Assert.notNil(prompt, "the suspension names the pending learning prompt")
  local snapshot = session:capture()
  SessionFixture.assertPlainData(snapshot, "pending learning")
  local revived = Executor.restore(snapshot, content)
  local first = SessionFixture.driveUntilSettled(session)
  local second = SessionFixture.driveUntilSettled(revived)
  Assert.deepEqual(second.request, first.request, "restored sessions reopen the identical learning prompt")
  local firstPrompt = findLearnPrompt(first)
  local secondPrompt = findLearnPrompt(second)
  Assert.notNil(firstPrompt, "the uninterrupted run keeps its prompt")
  Assert.notNil(secondPrompt, "the restored run keeps its prompt")
  Assert.equal(
    secondPrompt.incomingMove,
    firstPrompt.incomingMove,
    "both runs prompt the same move"
  )
  for _, live in ipairs({ session, revived }) do
    local held = live == session and firstPrompt or secondPrompt
    local entry = assert(held.actors[1], "the prompt addresses its recipient")
    local liveOk, liveErr = live:submit(
      SessionFixture.replyFor(held, { learnChoice(entry, "replace", 3) })
    )
    Assert.isTrue(liveOk, "restored sessions accept the open learning reply")
    Assert.isNil(liveErr, "accepted replies carry no input error")
  end
  local firstEnded, firstClosing = advanceCollecting(session, 64)
  local secondEnded, secondClosing = advanceCollecting(revived, 64)
  Assert.equal(firstEnded.status, "ended", "the uninterrupted run ends after learning")
  Assert.equal(secondEnded.status, "ended", "the restored run ends after learning")
  Assert.deepEqual(secondClosing, firstClosing, "restored sessions replay the same completion")
  Assert.deepEqual(revived:capture(), session:capture(), "restored sessions reach the same following state")
  Assert.equal(countSessionEvents(collected, "exp"), 1, "the suspended run awards experience once")
  Assert.equal(countSessionEvents(firstClosing, "exp"), 0, "completing the run awards nothing again")
  Assert.equal(countSessionEvents(secondClosing, "exp"), 0, "completing the restore awards nothing again")
  local final = session:capture()
  local twin = revived:capture()
  Assert.equal(
    final.combatants[1].mon.experience,
    twin.combatants[1].mon.experience,
    "both runs award identical experience"
  )
  Assert.deepEqual(
    firstEnded.outcome.evolutionEligible,
    { 1 },
    "the uninterrupted run surfaces eligibility once"
  )
  Assert.deepEqual(
    secondEnded.outcome.evolutionEligible,
    firstEnded.outcome.evolutionEligible,
    "the restored run surfaces identical eligibility"
  )
  session:dispose()
  revived:dispose()
end

-- A knockout into a free move slot learns without prompting: the
-- recipient carries two moves across the same learning level, so the
-- award lands, the new move fills the first free slot with base power
-- points, and the battle ends with no suspension and single eligibility.
function T.rewards_with_a_free_slot_learn_silently_without_a_prompt()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local Executor = executorOwner()
  local alpha = rewardRecipient(1, 11)
  alpha.mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
  }
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
    moveFacts = scenarioMoveFacts({ alpha, beta }),
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
  local ended, collected = advanceCollecting(session, 64)
  Assert.isTrue(announcesFaint(collected, 2), "the strike knocks out the wounded foe")
  Assert.equal(ended.status, "ended", "a free slot never suspends the battle")
  Assert.isNil(findLearnPrompt(ended), "a free slot never prompts")
  local award = findSessionEvent(collected, "exp")
  Assert.notNil(award, "the knockout awards experience through the reward owner")
  Assert.equal(countSessionEvents(collected, "exp"), 1, "the award lands exactly once")
  local learned = findSessionEvent(collected, "learn")
  Assert.notNil(learned, "the free slot reports its learned move")
  Assert.equal(learned.move, "SYNTHESIS", "the free slot learns the level-twelve move")
  local finished = session:capture()
  Assert.equal(
    finished.combatants[1].mon.moves[3].move,
    "SYNTHESIS",
    "the new move fills the first free slot"
  )
  Assert.equal(
    finished.combatants[1].mon.moves[3].pp,
    5,
    "an auto-learned move resets to its base power points"
  )
  Assert.equal(
    finished.combatants[1].mon.experience,
    972 + award.gained --[[@as integer]],
    "the award lands exactly once on the battle copy"
  )
  Assert.deepEqual(
    ended.outcome.evolutionEligible,
    { 1 },
    "the level gain surfaces once for post-battle handling"
  )
  session:dispose()
end

-- Rejected learning replies hold the prompt open: an unknown decision, a
-- stray slot, and a foreign request all fail with an input error while
-- the identical prompt waits, and only the valid decline completes the
-- battle without touching the move set.
function T.invalid_learning_replies_hold_the_prompt_open()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local session = contracts.Battle.newSession(rewardScenario(), content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  for _, request in ipairs(opening.request.requests) do
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, answer(request)))
    Assert.isTrue(ok, "opening replies are accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
  end
  local boundary = SessionFixture.driveUntilSettled(session)
  Assert.equal(boundary.status, "waiting", "the knockout suspends on its learning prompt")
  local prompt = findLearnPrompt(boundary)
  Assert.notNil(prompt, "the suspension names the pending learning prompt")
  local actor = assert(prompt.actors[1], "the prompt addresses its recipient")
  local held = session:capture().combatants[1].mon
  local unknown, unknownErr =
    session:submit(SessionFixture.replyFor(prompt, { learnChoice(actor, "forget") }))
  Assert.isFalse(unknown, "an unknown decision answers nothing")
  Assert.notNil(unknownErr, "rejected replies report their input error")
  local stray, strayErr = session:submit(SessionFixture.replyFor(prompt, { learnChoice(actor, "replace", 9) }))
  Assert.isFalse(stray, "a stray slot answers nothing")
  Assert.notNil(strayErr, "rejected slots report their input error")
  local foreign, foreignErr = session:submit({
    requestId = prompt.requestId + 1000,
    epoch = prompt.epoch,
    controller = prompt.controller,
    choices = { learnChoice(actor, "decline") },
  })
  Assert.isFalse(foreign, "a foreign request answers nothing")
  Assert.notNil(foreignErr, "foreign requests report their input error")
  local again = SessionFixture.driveUntilSettled(session)
  Assert.equal(again.status, "waiting", "rejected replies leave the prompt open")
  Assert.equal(
    findLearnPrompt(again).requestId,
    prompt.requestId,
    "the same prompt waits after every rejection"
  )
  Assert.equal(
    session:capture().combatants[1].mon.experience,
    held.experience,
    "rejected replies award nothing more"
  )
  local declined, declineErr =
    session:submit(SessionFixture.replyFor(prompt, { learnChoice(actor, "decline") }))
  Assert.isTrue(declined, "the decline is accepted")
  Assert.isNil(declineErr, "accepted replies carry no input error")
  local ended, closing = advanceCollecting(session, 64)
  Assert.equal(ended.status, "ended", "the decline completes the battle")
  Assert.isNil(findSessionEvent(closing, "learn"), "a decline learns no move")
  Assert.equal(
    session:capture().combatants[1].mon.moves[4].move,
    "POISONPOWDER",
    "a decline keeps the old set"
  )
  Assert.deepEqual(
    ended.outcome.evolutionEligible,
    { 1 },
    "the level gain still surfaces once after a decline"
  )
  session:dispose()
end

-- Sequential knockouts award in faint order without double counting: the
-- foe fields a wounded lead and a healthy reserve behind it, the
-- free-slot recipient crosses its learning level on the first knockout,
-- and both awards land exactly once while eligibility names the
-- recipient a single time.
function T.sequential_knockouts_award_in_order_without_double_counting()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local Executor = executorOwner()
  local alpha = rewardRecipient(1, 11)
  alpha.mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
  }
  local betaLead = tackleCombatant(2, 23)
  betaLead.mon.condition.currentHp = 1
  local betaReserve = tackleCombatant(3, 31)
  local seeds = { alpha, betaLead, betaReserve }
  local scenario = {
    ruleset = Executor.RULESET,
    format = NATIVE_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { alpha }),
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
  local session = contracts.Battle.newSession(scenario, content)
  local collected = {}
  local ended = nil
  for _ = 1, 64 do
    local frame = SessionFixture.driveUntilSettled(session)
    for _, event in ipairs(frame.events or {}) do
      collected[#collected + 1] = event
    end
    if frame.status == "ended" then
      ended = frame
      break
    end
    Assert.equal(frame.status, "waiting", "every open boundary asks for decisions")
    Assert.isNil(findLearnPrompt(frame), "free slots never interrupt the run")
    for _, request in ipairs(frame.request.requests) do
      local ok, replyErr = session:submit(SessionFixture.replyFor(request, answer(request)))
      Assert.isTrue(ok, "open replies are accepted")
      Assert.isNil(replyErr, "accepted replies carry no input error")
    end
    local settled = session:advance(64)
    for _, event in ipairs(settled.events or {}) do
      collected[#collected + 1] = event
    end
    if settled.status == "ended" then
      ended = settled
      break
    end
  end
  Assert.notNil(ended, "the run ends once both foes fall")
  local first, second = nil, nil
  for _, event in ipairs(collected) do
    if event.kind == "faint" then
      local payload = event.payload --[[@as table<string, unknown>]]
      if first == nil then
        first = payload.combatant
      else
        second = payload.combatant
      end
    end
  end
  Assert.equal(first, 2, "the wounded lead falls first")
  Assert.equal(second, 3, "the reserve falls second")
  Assert.equal(countSessionEvents(collected, "exp"), 2, "each knockout awards exactly once")
  local gains = 0
  for _, event in ipairs(collected) do
    if type(event) == "table" and event.kind == "exp" then
      gains = gains + event.gained --[[@as integer]]
    end
  end
  local finished = session:capture()
  Assert.equal(
    finished.combatants[1].mon.experience,
    972 + gains,
    "both awards land on the battle copy with no double count"
  )
  Assert.deepEqual(
    finished.combatants[1].mon.moves[3].move,
    "SYNTHESIS",
    "the first crossing still auto-learns into the free slot"
  )
  Assert.deepEqual(ended.outcome.evolutionEligible, { 1 }, "eligibility names the recipient once")
  session:dispose()
end

-- Production wild/trainer format keys exercised through the test content
-- binding. The content registers the same keys the application composition
-- uses, so encounter-kind behavior keyed off the format travels the same
-- path in tests and in production.
local WILD_FORMAT = "wild-single"
local TRAINER_FORMAT = "single"

---@return table frozen battle content binding the native ruleset over the production wild/trainer formats
local function actionContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = executorOwner()
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "native-action-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "native-action-tests"
  )
  behaviors:registerFormat(WILD_FORMAT, { key = WILD_FORMAT }, "native-action-tests")
  behaviors:registerFormat(TRAINER_FORMAT, { key = TRAINER_FORMAT }, "native-action-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@param id integer nonreused positive combatant identity
---@param seed integer fixed generator state for the underlying mon
---@param species string catalog species key
---@param level integer battle level for the underlying mon
---@return table combatant seed with one usable move entry
local function leveledCombatant(id, seed, species, level)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return { id = id, mon = mon }
end

---@param id integer nonreused positive combatant identity
---@param seed integer fixed generator state for the underlying mon
---@return table combatant seed already knocked out on the bench
local function faintedCombatant(id, seed)
  local entry = tackleCombatant(id, seed)
  local mon = entry.mon --[[@as table<string, unknown>]]
  local condition = mon.condition --[[@as table<string, unknown>]]
  condition.currentHp = 0
  return entry
end

---@param formatKey string production format key under test
---@param alpha table[] owning-side combatant seeds in scenario order
---@param beta table[] opposing-side combatant seeds in scenario order
---@param pack table|nil battle inventory seed for the owning side
---@param itemFacts table<string, table<string, unknown>>? detached semantic facts for the stocked items
---@return table detached native battle setup record
local function actionScenario(formatKey, alpha, beta, pack, itemFacts)
  local Executor = executorOwner()
  local seeds = {}
  for _, seed in ipairs(alpha) do
    seeds[#seeds + 1] = seed
  end
  for _, seed in ipairs(beta) do
    seeds[#seeds + 1] = seed
  end
  local alphaSpec = SessionFixture.participant(1, 1, "alpha", alpha)
  if pack ~= nil then
    alphaSpec.inventoryId = (pack --[[@as table<string, unknown>]]).id
  end
  local alphaLead = alpha[1] --[[@as table<string, unknown>]]
  local betaLead = beta[1] --[[@as table<string, unknown>]]
  local scenario = {
    ruleset = Executor.RULESET,
    format = formatKey,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      alphaSpec,
      SessionFixture.participant(2, 2, "beta", beta),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, alphaLead.id --[[@as integer]]),
      SessionFixture.position(2, 2, { 2 }, betaLead.id --[[@as integer]]),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(),
    speciesFacts = scenarioSpeciesFacts(seeds),
  }
  if pack ~= nil then
    scenario.inventories = { pack }
  end
  if itemFacts ~= nil then
    scenario.itemFacts = itemFacts
  end
  return scenario
end

---@param actor table combatant reference the choice is issued for
---@param item string item key requested from the shared stack
---@param holder integer combatant receiving the item
---@return table validated decision payload for bag use
local function bagChoice(actor, item, holder)
  return {
    actor = actor,
    kind = "item",
    payload = { item = item, target = { kind = "combatant", combatant = holder } },
  }
end

---@param actor table combatant reference the choice is issued for
---@return table validated decision payload for flight
local function runChoice(actor)
  return { actor = actor, kind = "run", payload = {} }
end

---@param frame table waiting battle frame under inspection
---@param controller string decision producer owning the wanted request
---@return table the pending decision request for the controller
local function requestFor(frame, controller)
  for _, request in ipairs(frame.request.requests) do
    if request.controller == controller then
      return request
    end
  end
  error("the " .. controller .. " request stays open")
end

---@param events table[]|nil emitted events under inspection
---@param kind string event kind under counting
---@return integer events carrying the kind
local function countKind(events, kind)
  local found = 0
  for _, event in ipairs(events or {}) do
    if event.kind == kind then
      found = found + 1
    end
  end
  return found
end

-- Exchanges into reserves that cannot fight are refused before anything
-- moves: the reply is rejected as invalid input, the outgoing lead keeps
-- its position and entry token, both reserves stay benched, no exchange
-- event escapes, and the stream spends nothing.
function T.voluntary_switches_refuse_ineligible_reserves_without_moving_anyone()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local session = contracts.Battle.newSession(
    actionScenario(
      WILD_FORMAT,
      { tackleCombatant(1, 11), tackleCombatant(3, 31), faintedCombatant(5, 51) },
      { tackleCombatant(2, 23) },
      nil
    ),
    content
  )
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local before = session:capture()
  local leadActivation = before.combatants[1].active.activation
  local callsBefore = before.rng.calls
  local alpha = requestFor(opening, "alpha")
  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  local refused, refuseErr =
    session:submit(SessionFixture.replyFor(alpha, { SessionFixture.switchChoice(actor, 5) }))
  Assert.isFalse(refused, "an exchange into a fainted reserve is refused")
  Assert.notNil(refuseErr, "refused exchanges report their input error")
  local waiting = SessionFixture.driveUntilSettled(session)
  Assert.equal(waiting.status, "waiting", "refused exchanges leave the turn open")
  Assert.equal(
    requestFor(waiting, "alpha").requestId,
    alpha.requestId,
    "the owning side is asked again with the same request"
  )
  local settled = session:capture()
  Assert.equal(settled.positions[1].occupant, 1, "the outgoing lead stays on the field")
  Assert.equal(
    settled.combatants[1].active.activation,
    leadActivation,
    "the outgoing entry keeps its token"
  )
  Assert.isNil(settled.combatants[5].active, "the fainted reserve stays benched")
  Assert.isNil(settled.combatants[3].active, "the healthy reserve stays benched")
  Assert.equal(countKind(waiting.events, "switch"), 0, "refused exchanges emit no exchange event")
  Assert.equal(settled.rng.calls, callsBefore, "refused exchanges draw nothing")
  session:dispose()
end

-- A free exchange completes its lifecycle: the reserve takes the vacated
-- position with a fresh entry token, the outgoing lead leaves the field,
-- a strike locked to the departed entry fizzles without wounding the
-- arrival, and the following turn addresses the reserve with no terminal
-- result named.
function T.voluntary_switches_complete_the_exchange_with_a_fresh_entry()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local session = contracts.Battle.newSession(
    actionScenario(WILD_FORMAT, { tackleCombatant(1, 11), tackleCombatant(3, 31) }, { tackleCombatant(2, 23) }, nil),
    content
  )
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local leadActivation = session:capture().combatants[1].active.activation
  local callsBefore = session:capture().rng.calls
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local ok, replyErr = session:submit(SessionFixture.replyFor(alpha, { SessionFixture.switchChoice(actor, 3) }))
  Assert.isTrue(ok, "the free exchange is accepted")
  Assert.isNil(replyErr, "accepted exchanges carry no input error")
  local answered, answerErr = session:submit(
    SessionFixture.replyFor(
      beta,
      { SessionFixture.attackChoice(foe, 0, SessionFixture.combatantTarget(1, leadActivation)) }
    )
  )
  Assert.isTrue(answered, "the locked strike is accepted")
  Assert.isNil(answerErr, "accepted strikes carry no input error")
  local turn = session:advance(64)
  Assert.isTrue(countKind(turn.events, "switch") >= 1, "the exchange announces itself")
  local settled = session:capture()
  Assert.equal(settled.positions[1].occupant, 3, "the reserve takes the vacated position")
  Assert.isNil(settled.combatants[1].active, "the outgoing lead leaves the field")
  Assert.notNil(settled.combatants[3].active, "the reserve enters the field")
  Assert.isTrue(
    settled.combatants[3].active.activation ~= leadActivation,
    "the reserve enters with a fresh entry"
  )
  Assert.equal(
    settled.combatants[3].hp,
    settled.combatants[3].entryHp,
    "the strike locked to the departed entry never wounds the arrival"
  )
  Assert.equal(countKind(turn.events, "struck"), 0, "the stale strike lands nothing")
  -- The exchange spends no draw itself; the four draws are the
  -- following batch samples, already spent while it waits.
  Assert.equal(settled.rng.calls, callsBefore + 4, "the exchange turn spends no draws")
  local following = SessionFixture.driveUntilSettled(session)
  Assert.equal(following.status, "waiting", "the following turn asks for decisions")
  local addressesReserve = false
  for _, entry in ipairs(requestFor(following, "alpha").actors) do
    if entry.combatant == 3 then
      addressesReserve = true
    end
  end
  Assert.isTrue(addressesReserve, "the following turn addresses the reserve")
  Assert.isNil(session:capture().outcome, "no terminal result is named after a free exchange")
  session:dispose()
end

-- Bag healing applies the modeled restoration through the shared stack:
-- the wounded holder recovers exactly the modeled amount, one unit leaves
-- the declared stock, deterministic use spends no draws, the spent stack
-- refuses a second serving, and a throw at a holder that is not on the
-- field is refused without touching the stock.
function T.bag_healing_restores_health_and_spends_exactly_one_unit()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local facts = {
    POTION = {
      partyUse = {
        kind = "medicine",
        restore = { kind = "fixed", amount = 20 },
        cures = { sleep = false, poison = false, burn = false, freeze = false, paralysis = false },
        revive = "none",
        mood = 0,
      },
    },
  }
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  lead.mon.condition.currentHp = 1
  local pack = SessionFixture.inventory("party", { 1 }, { POTION = 1 })
  local session = contracts.Battle.newSession(
    actionScenario(
      WILD_FORMAT,
      { lead },
      { leveledCombatant(2, 41, "EEVEE", 5), leveledCombatant(4, 43, "EEVEE", 5) },
      pack,
      facts
    ),
    content
  )
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local callsBefore = session:capture().rng.calls
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local ok, replyErr =
    session:submit(SessionFixture.replyFor(alpha, { bagChoice(actor, "POTION", 1) }))
  Assert.isTrue(ok, "the healing choice is accepted")
  Assert.isNil(replyErr, "accepted bag use carries no input error")
  local answered, answerErr =
    session:submit(SessionFixture.replyFor(beta, { SessionFixture.switchChoice(foe, 4) }))
  Assert.isTrue(answered, "the opposing exchange is accepted")
  Assert.isNil(answerErr, "accepted exchanges carry no input error")
  local turn = session:advance(64)
  Assert.isTrue(countKind(turn.events, "item") >= 1, "the bag use announces itself")
  local settled = session:capture()
  Assert.equal(settled.combatants[1].hp, 21, "the wounded holder recovers the modeled amount")
  Assert.equal(settled.inventories.party.quantities.POTION, 0, "exactly one unit leaves the stock")
  -- The serving draws nothing itself; the four draws are the following
  -- batch samples, already spent while it waits for decisions.
  Assert.equal(settled.rng.calls, callsBefore + 4, "deterministic bag use draws nothing")
  local following = SessionFixture.driveUntilSettled(session)
  Assert.equal(following.status, "waiting", "the following turn asks for decisions")
  local again = requestFor(following, "alpha")
  local user = assert(again.actors[1], "the following request addresses the healed lead")
  local spent, spentErr = session:submit(SessionFixture.replyFor(again, { bagChoice(user, "POTION", 1) }))
  Assert.isFalse(spent, "the spent stack serves nothing more")
  Assert.notNil(spentErr, "the spent stack reports its input error")
  Assert.equal(
    session:capture().inventories.party.quantities.POTION,
    0,
    "the refused serving consumes nothing more"
  )
  session:dispose()

  local freshLead = leveledCombatant(1, 23, "EEVEE", 20)
  freshLead.mon.condition.currentHp = 1
  local fresh = contracts.Battle.newSession(
    actionScenario(
      WILD_FORMAT,
      { freshLead },
      { leveledCombatant(2, 41, "EEVEE", 5), leveledCombatant(4, 43, "EEVEE", 5) },
      SessionFixture.inventory("party", { 1 }, { POTION = 1 }),
      facts
    ),
    content
  )
  local boundary = SessionFixture.driveUntilSettled(fresh)
  Assert.equal(boundary.status, "waiting", "the second battle opens its turn")
  local holder = assert(requestFor(boundary, "alpha").actors[1], "the second request addresses its lead")
  local refused, refuseErr = fresh:submit(SessionFixture.replyFor(requestFor(boundary, "alpha"), {
    bagChoice(holder, "POTION", 9),
  }))
  Assert.isFalse(refused, "a holder that is not on the field is refused")
  Assert.notNil(refuseErr, "the refused holder reports its input error")
  Assert.equal(
    fresh:capture().inventories.party.quantities.POTION,
    1,
    "the refused holder leaves the stock untouched"
  )
  fresh:dispose()
end

-- A thrown ball runs the capture path and closes the wild battle: the
-- session records the exact caught mon in plain snapshot-safe data, the
-- throw tells its ordered throw, shakes, and catch, the shared stack
-- drops by exactly one unit with no draw spent on the guaranteed ball,
-- and the battle ends with both sides standing.
function T.thrown_balls_record_the_caught_mon_and_close_the_wild_battle()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local pack = SessionFixture.inventory("party", { 1 }, { MASTER_BALL = 1 })
  local session = contracts.Battle.newSession(
    actionScenario(
      WILD_FORMAT,
      { leveledCombatant(1, 11, "CHIKORITA", 20) },
      { leveledCombatant(2, 23, "EEVEE", 5) },
      pack
    ),
    content
  )
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local foeRecord = session:capture().combatants[2].mon
  local callsBefore = session:capture().rng.calls
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local ok, replyErr = session:submit(SessionFixture.replyFor(alpha, { bagChoice(actor, "MASTER_BALL", 2) }))
  Assert.isTrue(ok, "the thrown ball is accepted")
  Assert.isNil(replyErr, "accepted throws carry no input error")
  local answered, answerErr = session:submit(
    SessionFixture.replyFor(beta, { SessionFixture.attackChoice(foe, 0, SessionFixture.positionTarget(1)) })
  )
  Assert.isTrue(answered, "the opposing strike is accepted")
  Assert.isNil(answerErr, "accepted strikes carry no input error")
  local turn = session:advance(64)
  local kinds = {}
  for _, event in ipairs(turn.events or {}) do
    kinds[#kinds + 1] = event.kind
  end
  local wanted = { "throw", "shake", "shake", "shake", "caught" }
  local cursor = 1
  for _, kind in ipairs(kinds) do
    if kind == wanted[cursor] then
      cursor = cursor + 1
    end
    if cursor > #wanted then
      break
    end
  end
  Assert.equal(cursor, #wanted + 1, "the throw tells throw, shakes, and catch in order")
  Assert.equal(kinds[#kinds], "caught", "the successful throw closes with the catch")
  local boundary = SessionFixture.driveUntilSettled(session)
  Assert.equal(boundary.status, "ended", "the successful wild capture ends the battle")
  Assert.notNil(boundary.outcome, "the closed capture names its terminal result")
  local settled = session:capture()
  Assert.equal(
    settled.inventories.party.quantities.MASTER_BALL,
    0,
    "the throw spends exactly one ball"
  )
  Assert.equal(settled.rng.calls, callsBefore, "the guaranteed throw spends no roll")
  Assert.equal(countKind(turn.events, "struck"), 0, "the catch preempts the queued strike")
  local ledger = settled.captures
  Assert.notNil(ledger, "the session owns its capture ledger")
  Assert.equal(#ledger, 1, "the throw records exactly one capture")
  local record = ledger[1]
  Assert.isTrue(record.success, "the guaranteed throw lands")
  Assert.equal(record.ball, "MASTER_BALL", "the record names its ball")
  Assert.deepEqual(record.mon, foeRecord, "the record keeps the exact caught mon")
  SessionFixture.assertPlainData(ledger, "captures")
  Assert.isTrue(settled.combatants[1].hp > 0, "the thrower is still standing")
  Assert.isTrue(settled.combatants[2].hp > 0, "the catch ends the battle without a knockout")
  session:dispose()
end

-- Flight follows escape law: a failed wild attempt spends exactly one
-- labeled roll and the battle continues with both leads in place, a
-- faster wild lead leaves outright with no roll and the queued strike
-- never lands, and flight from a trainer battle is refused before
-- anything moves, draws, or ends.
function T.run_attempts_follow_escape_law_and_trainer_flight_stays_refused()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local slow = contracts.Battle.newSession(
    actionScenario(
      WILD_FORMAT,
      { leveledCombatant(1, 11, "CHIKORITA", 5) },
      { leveledCombatant(2, 23, "EEVEE", 40), leveledCombatant(4, 41, "EEVEE", 5) },
      nil
    ),
    content
  )
  local opening = SessionFixture.driveUntilSettled(slow)
  Assert.equal(opening.status, "waiting", "the slow turn asks for decisions")
  local callsBefore = slow:capture().rng.calls
  local slowActivation = slow:capture().combatants[1].active.activation
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local runner = assert(alpha.actors[1], "the slow request addresses its lead")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local ok, replyErr = slow:submit(SessionFixture.replyFor(alpha, { runChoice(runner) }))
  Assert.isTrue(ok, "the wild run is accepted")
  Assert.isNil(replyErr, "accepted runs carry no input error")
  local answered, answerErr =
    slow:submit(SessionFixture.replyFor(beta, { SessionFixture.switchChoice(foe, 4) }))
  Assert.isTrue(answered, "the opposing exchange is accepted")
  Assert.isNil(answerErr, "accepted exchanges carry no input error")
  slow:advance(64)
  local waiting = SessionFixture.driveUntilSettled(slow)
  Assert.equal(waiting.status, "waiting", "the failed attempt continues the battle")
  Assert.isNil(slow:capture().outcome, "the failed attempt names no terminal result")
  local settled = slow:capture()
  Assert.equal(settled.positions[1].occupant, 1, "the slow lead stays on the field")
  Assert.equal(
    settled.combatants[1].active.activation,
    slowActivation,
    "the slow entry keeps its token"
  )
  Assert.equal(settled.positions[2].occupant, 4, "the opposing exchange still runs its turn")
  -- One odds roll for the failed flight plus the four pre-turn samples
  -- of the following batch, already spent while it waits for decisions.
  Assert.equal(settled.rng.calls, callsBefore + 5, "the failed attempt spends exactly one roll")
  slow:dispose()

  local swift = contracts.Battle.newSession(
    actionScenario(
      WILD_FORMAT,
      { leveledCombatant(1, 11, "CHIKORITA", 20) },
      { leveledCombatant(2, 13, "CHIKORITA", 5) },
      nil
    ),
    content
  )
  local dash = SessionFixture.driveUntilSettled(swift)
  Assert.equal(dash.status, "waiting", "the swift turn asks for decisions")
  local dashCalls = swift:capture().rng.calls
  local dashHp = swift:capture().combatants[1].hp
  local dashEntry = swift:capture().combatants[1].entryHp
  local dashAlpha = requestFor(dash, "alpha")
  local dashBeta = requestFor(dash, "beta")
  local escaper = assert(dashAlpha.actors[1], "the swift request addresses its lead")
  local chaser = assert(dashBeta.actors[1], "the chasing request addresses its lead")
  local fled, fledErr = swift:submit(SessionFixture.replyFor(dashAlpha, { runChoice(escaper) }))
  Assert.isTrue(fled, "the swift run is accepted")
  Assert.isNil(fledErr, "accepted runs carry no input error")
  local chased, chasedErr = swift:submit(
    SessionFixture.replyFor(dashBeta, { SessionFixture.attackChoice(chaser, 0, SessionFixture.positionTarget(1)) })
  )
  Assert.isTrue(chased, "the chasing strike is accepted")
  Assert.isNil(chasedErr, "accepted strikes carry no input error")
  local flight = swift:advance(64)
  Assert.equal(countKind(flight.events, "struck"), 0, "the escape preempts the queued strike")
  local escaped = SessionFixture.driveUntilSettled(swift)
  Assert.equal(escaped.status, "ended", "the successful wild run ends the battle")
  Assert.notNil(escaped.outcome, "the escape names its terminal result")
  local fledState = swift:capture()
  Assert.equal(fledState.combatants[1].hp, dashHp, "the escapee leaves unwounded")
  Assert.equal(fledState.combatants[1].hp, dashEntry, "the escapee keeps its entry health")
  Assert.equal(fledState.rng.calls, dashCalls, "the outright escape spends no roll")
  Assert.isTrue(fledState.combatants[2].hp > 0, "the escape claims no knockout")
  swift:dispose()

  local trainer = contracts.Battle.newSession(
    actionScenario(
      TRAINER_FORMAT,
      { leveledCombatant(1, 11, "CHIKORITA", 20) },
      { leveledCombatant(2, 23, "EEVEE", 5) },
      nil
    ),
    content
  )
  local standoff = SessionFixture.driveUntilSettled(trainer)
  Assert.equal(standoff.status, "waiting", "the trainer turn asks for decisions")
  local standoffCalls = trainer:capture().rng.calls
  local trainerAlpha = requestFor(standoff, "alpha")
  local athletic = assert(trainerAlpha.actors[1], "the trainer request addresses its lead")
  local refused, refuseErr = trainer:submit(SessionFixture.replyFor(trainerAlpha, { runChoice(athletic) }))
  Assert.isFalse(refused, "flight from a trainer battle is refused")
  Assert.notNil(refuseErr, "the refused flight reports its input error")
  local held = SessionFixture.driveUntilSettled(trainer)
  Assert.equal(held.status, "waiting", "the refused flight continues the battle")
  Assert.equal(
    requestFor(held, "alpha").requestId,
    trainerAlpha.requestId,
    "the trainer side is asked again with the same request"
  )
  local heldState = trainer:capture()
  Assert.equal(heldState.positions[1].occupant, 1, "the refused lead stays on the field")
  Assert.equal(heldState.positions[2].occupant, 2, "the opposing lead stays on the field")
  Assert.equal(heldState.rng.calls, standoffCalls, "the refused flight spends no roll")
  Assert.isNil(heldState.outcome, "the refused flight names no terminal result")
  trainer:dispose()
end

-- Smoke Ball guarantees wild flight: a slower lead that fails its bare
-- odds leaves outright holding the ball, spending no roll and taking no
-- parting strike, while the identical bare lead fails and fights on.
function T.smoke_ball_guarantees_wild_flight_for_slower_leads()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()

  ---@param holderItem string? held item carried by the slow lead
  ---@return table live wild session pairing the slow lead with its faster foe
  local function slowDuel(holderItem)
    local lead = leveledCombatant(1, 11, "CHIKORITA", 5)
    if holderItem ~= nil then
      lead.mon.heldItem = holderItem
    end
    return contracts.Battle.newSession(
      actionScenario(
        WILD_FORMAT,
        { lead },
        { leveledCombatant(2, 23, "EEVEE", 40), leveledCombatant(4, 41, "EEVEE", 5) },
        nil
      ),
      content
    )
  end

  ---@param session table live session at its opening decision boundary
  ---@return table[] turn events after both sides answer
  local function fleeTurn(session)
    local opening = SessionFixture.driveUntilSettled(session)
    Assert.equal(opening.status, "waiting", "the flight turn asks for decisions")
    local alpha = requestFor(opening, "alpha")
    local beta = requestFor(opening, "beta")
    local runner = assert(alpha.actors[1], "the flight request addresses its lead")
    local foe = assert(beta.actors[1], "the opposing request addresses its lead")
    local ok, replyErr = session:submit(SessionFixture.replyFor(alpha, { runChoice(runner) }))
    Assert.isTrue(ok, "the wild run is accepted")
    Assert.isNil(replyErr, "accepted runs carry no input error")
    local answered, answerErr =
      session:submit(SessionFixture.replyFor(beta, { SessionFixture.switchChoice(foe, 4) }))
    Assert.isTrue(answered, "the opposing exchange is accepted")
    Assert.isNil(answerErr, "accepted exchanges carry no input error")
    return session:advance(64).events or {}
  end

  local bare = slowDuel(nil)
  local bareCalls = bare:capture().rng.calls
  fleeTurn(bare)
  local stalled = SessionFixture.driveUntilSettled(bare)
  Assert.equal(stalled.status, "waiting", "the failed attempt continues the battle")
  Assert.isNil(bare:capture().outcome, "the failed attempt names no terminal result")
  -- The fresh baseline spends nothing: one odds roll for the failed
  -- flight plus the four pre-turn samples of each of the two batches
  -- the turn opens and closes with.
  Assert.equal(bare:capture().rng.calls, bareCalls + 9, "the failed attempt spends exactly one roll")
  bare:dispose()

  local smoked = slowDuel("SMOKE_BALL")
  local smokedCalls = smoked:capture().rng.calls
  local smokedHp = smoked:capture().combatants[1].hp
  local smokedEvents = fleeTurn(smoked)
  Assert.equal(countKind(smokedEvents, "struck"), 0, "the escape preempts the queued strike")
  local escaped = SessionFixture.driveUntilSettled(smoked)
  Assert.equal(escaped.status, "ended", "the smoked flight ends the battle")
  Assert.notNil(escaped.outcome, "the escape names its terminal result")
  local fledState = smoked:capture()
  Assert.equal(fledState.combatants[1].hp, smokedHp, "the escapee leaves unwounded")
  -- The guaranteed flight spends no roll itself; the four draws are
  -- the opening batch samples spent while it waited for decisions.
  Assert.equal(fledState.rng.calls, smokedCalls + 4, "the guaranteed flight spends no roll")
  smoked:dispose()
end

-- Servings the shared stack never carried are refused before anything
-- moves: the reply is rejected as invalid input, the declared stock
-- stays untouched, the holder keeps its health, and the stream spends
-- nothing.
function T.bag_unknown_items_refuse_without_spending_stock()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  local session = contracts.Battle.newSession(
    actionScenario(
      WILD_FORMAT,
      { lead },
      { leveledCombatant(2, 41, "EEVEE", 5) },
      SessionFixture.inventory("party", { 1 }, { POTION = 1 })
    ),
    content
  )
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local callsBefore = session:capture().rng.calls
  local hpBefore = session:capture().combatants[1].hp
  local alpha = requestFor(opening, "alpha")
  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  local refused, refuseErr =
    session:submit(SessionFixture.replyFor(alpha, { bagChoice(actor, "ANTIDOTE", 1) }))
  Assert.isFalse(refused, "a serving the stack never carried is refused")
  Assert.notNil(refuseErr, "the refused serving reports its input error")
  local waiting = SessionFixture.driveUntilSettled(session)
  Assert.equal(waiting.status, "waiting", "the refused serving leaves the turn open")
  Assert.equal(
    requestFor(waiting, "alpha").requestId,
    alpha.requestId,
    "the owning side is asked again with the same request"
  )
  local settled = session:capture()
  Assert.equal(settled.inventories.party.quantities.POTION, 1, "the declared stock stays untouched")
  Assert.equal(settled.combatants[1].hp, hpBefore, "the holder keeps its health")
  Assert.equal(settled.rng.calls, callsBefore, "the refused serving draws nothing")
  Assert.isNil(settled.outcome, "the refused serving names no terminal result")
  session:dispose()
end

-- Interruption captures preserve the serving facts: the held capture
-- carries the exact projected facts, later scenario edits never reach
-- the live session, and a restored session serves the identical
-- restoration with the identical event through the same turn.
function T.interruption_captures_preserve_item_facts_for_restored_servings()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local content = actionContent()
  local facts = {
    POTION = {
      partyUse = {
        kind = "medicine",
        restore = { kind = "fixed", amount = 20 },
        cures = { sleep = false, poison = false, burn = false, freeze = false, paralysis = false },
        revive = "none",
        mood = 0,
      },
    },
  }
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  lead.mon.condition.currentHp = 1
  local scenario = actionScenario(
    WILD_FORMAT,
    { lead },
    { leveledCombatant(2, 41, "EEVEE", 5), leveledCombatant(4, 43, "EEVEE", 5) },
    SessionFixture.inventory("party", { 1 }, { POTION = 1 }),
    facts
  )
  local session = contracts.Battle.newSession(scenario, content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  facts.POTION.partyUse.restore.amount = 999
  local hpBefore = session:capture().combatants[1].hp
  local held = session:capture()
  Assert.equal(
    held.itemFacts.POTION.partyUse.restore.amount,
    20,
    "the held capture keeps the projected restoration"
  )
  Assert.deepEqual(held.itemFacts.POTION.partyUse.cures, {
    sleep = false,
    poison = false,
    burn = false,
    freeze = false,
    paralysis = false,
  }, "the held capture keeps the projected cures")
  local twin = Executor.restore(held, content)
  local served = {}
  for _, live in ipairs({ session, twin }) do
    local frame = SessionFixture.driveUntilSettled(live)
    Assert.equal(frame.status, "waiting", "both sessions reopen the serving boundary")
    local alpha = requestFor(frame, "alpha")
    local beta = requestFor(frame, "beta")
    local actor = assert(alpha.actors[1], "the serving request addresses its lead")
    local foe = assert(beta.actors[1], "the opposing request addresses its lead")
    local ok, replyErr = live:submit(SessionFixture.replyFor(alpha, { bagChoice(actor, "POTION", 1) }))
    Assert.isTrue(ok, "the restored facts accept the serving")
    Assert.isNil(replyErr, "accepted servings carry no input error")
    local answered, answerErr =
      live:submit(SessionFixture.replyFor(beta, { SessionFixture.switchChoice(foe, 4) }))
    Assert.isTrue(answered, "the opposing exchange is accepted")
    Assert.isNil(answerErr, "accepted exchanges carry no input error")
    served[#served + 1] = live:advance(64)
  end
  local payloads = {}
  for _, turn in ipairs(served) do
    for _, event in ipairs(turn.events or {}) do
      if event.kind == "item" then
        payloads[#payloads + 1] = event.payload
      end
    end
  end
  Assert.equal(#payloads, 2, "both sessions announce their serving")
  Assert.deepEqual(payloads[1], payloads[2], "restored sessions serve the identical event")
  Assert.equal(payloads[1].restored, 20, "the restored serving reports the generated restoration")
  Assert.equal(payloads[1].item, "POTION", "the restored serving names its item")
  local settled = session:capture()
  local revived = twin:capture()
  Assert.equal(settled.combatants[1].hp, hpBefore + 20, "the live session heals the generated amount")
  Assert.equal(revived.combatants[1].hp, settled.combatants[1].hp, "restored servings heal identically")
  Assert.equal(
    revived.combatants[1].mon.condition.currentHp,
    settled.combatants[1].hp,
    "restored servings synchronize the condition mirror"
  )
  Assert.deepEqual(revived.inventories, settled.inventories, "restored servings spend identical stock")
  Assert.deepEqual(revived.ledger, settled.ledger, "restored servings ledger identical deltas")
  Assert.deepEqual(revived.itemFacts, settled.itemFacts, "restored sessions carry identical facts")
  Assert.equal(revived.rng.calls, settled.rng.calls, "restored servings draw identically")
  session:dispose()
  twin:dispose()
end

-- Thrown balls refuse trainer targets before anything moves: the reply
-- is rejected as invalid input, the shared stack keeps its ball, both
-- leads stay put, no capture is ledgered, and the stream spends nothing.
function T.thrown_balls_refuse_trainer_targets_without_spending()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local session = contracts.Battle.newSession(
    actionScenario(
      TRAINER_FORMAT,
      { leveledCombatant(1, 11, "CHIKORITA", 20) },
      { leveledCombatant(2, 23, "EEVEE", 5) },
      SessionFixture.inventory("party", { 1 }, { MASTER_BALL = 1 })
    ),
    content
  )
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the trainer turn asks for decisions")
  local callsBefore = session:capture().rng.calls
  local alpha = requestFor(opening, "alpha")
  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  local refused, refuseErr =
    session:submit(SessionFixture.replyFor(alpha, { bagChoice(actor, "MASTER_BALL", 2) }))
  Assert.isFalse(refused, "a throw at a trainer target is refused")
  Assert.notNil(refuseErr, "the refused throw reports its input error")
  local waiting = SessionFixture.driveUntilSettled(session)
  Assert.equal(waiting.status, "waiting", "the refused throw leaves the turn open")
  Assert.equal(
    requestFor(waiting, "alpha").requestId,
    alpha.requestId,
    "the owning side is asked again with the same request"
  )
  local settled = session:capture()
  Assert.equal(settled.positions[1].occupant, 1, "the refused lead stays on the field")
  Assert.equal(settled.positions[2].occupant, 2, "the opposing lead stays on the field")
  Assert.equal(settled.inventories.party.quantities.MASTER_BALL, 1, "the shared stack keeps its ball")
  Assert.equal(#settled.captures, 0, "the refused throw ledgers no capture")
  Assert.equal(settled.rng.calls, callsBefore, "the refused throw draws nothing")
  Assert.isNil(settled.outcome, "the refused throw names no terminal result")
  session:dispose()
end

-- Attempt counters and capture ledgers ride interruption captures
-- exactly once: a restored failed run spends its single roll from the
-- restored stream position, and a restored successful catch keeps its
-- one ledger record with the battle still ended.
function T.escape_attempts_and_capture_ledgers_survive_restore_without_duplication()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local content = actionContent()
  local slow = contracts.Battle.newSession(
    actionScenario(
      WILD_FORMAT,
      { leveledCombatant(1, 11, "CHIKORITA", 5) },
      { leveledCombatant(2, 23, "EEVEE", 40), leveledCombatant(4, 41, "EEVEE", 5) },
      nil
    ),
    content
  )
  local opening = SessionFixture.driveUntilSettled(slow)
  Assert.equal(opening.status, "waiting", "the slow turn asks for decisions")
  local snapshot = slow:capture()
  SessionFixture.assertPlainData(snapshot)
  local callsBefore = snapshot.rng.calls
  local revived = Executor.restore(snapshot, content)
  for _, live in ipairs({ slow, revived }) do
    local boundary = SessionFixture.driveUntilSettled(live)
    Assert.equal(boundary.status, "waiting", "the restored turn asks for decisions")
    local alpha = requestFor(boundary, "alpha")
    local beta = requestFor(boundary, "beta")
    local runner = assert(alpha.actors[1], "the slow request addresses its lead")
    local foe = assert(beta.actors[1], "the opposing request addresses its lead")
    local ok, replyErr = live:submit(SessionFixture.replyFor(alpha, { runChoice(runner) }))
    Assert.isTrue(ok, "the wild run is accepted")
    Assert.isNil(replyErr, "accepted runs carry no input error")
    local answered, answerErr =
      live:submit(SessionFixture.replyFor(beta, { SessionFixture.switchChoice(foe, 4) }))
    Assert.isTrue(answered, "the opposing exchange is accepted")
    Assert.isNil(answerErr, "accepted exchanges carry no input error")
    live:advance(64)
  end
  for _, live in ipairs({ slow, revived }) do
    local waiting = SessionFixture.driveUntilSettled(live)
    Assert.equal(waiting.status, "waiting", "the restored attempt still continues the battle")
    local settled = live:capture()
    Assert.equal(settled.escapeAttempts, 1, "the failed attempt counts exactly once")
    -- One odds roll for the failed flight plus the four pre-turn
    -- samples of the following batch, already spent while it waits.
    Assert.equal(settled.rng.calls, callsBefore + 5, "the restored attempt spends exactly one roll")
    Assert.equal(settled.positions[2].occupant, 4, "the opposing exchange still runs its turn")
  end
  Assert.deepEqual(revived:capture().escapeAttempts, slow:capture().escapeAttempts, "restore replays the counter")
  slow:dispose()
  revived:dispose()

  local pack = SessionFixture.inventory("party", { 1 }, { MASTER_BALL = 1 })
  local catcher = contracts.Battle.newSession(
    actionScenario(
      WILD_FORMAT,
      { leveledCombatant(1, 11, "CHIKORITA", 20) },
      { leveledCombatant(2, 23, "EEVEE", 5) },
      pack
    ),
    content
  )
  local duel = SessionFixture.driveUntilSettled(catcher)
  Assert.equal(duel.status, "waiting", "the capture turn asks for decisions")
  local thrower = assert(requestFor(duel, "alpha").actors[1], "the owning request addresses its lead")
  local target = assert(requestFor(duel, "beta").actors[1], "the opposing request addresses its lead")
  local thrown, thrownErr =
    catcher:submit(SessionFixture.replyFor(requestFor(duel, "alpha"), { bagChoice(thrower, "MASTER_BALL", 2) }))
  Assert.isTrue(thrown, "the thrown ball is accepted")
  Assert.isNil(thrownErr, "accepted throws carry no input error")
  local struck, struckErr = catcher:submit(
    SessionFixture.replyFor(
      requestFor(duel, "beta"),
      { SessionFixture.attackChoice(target, 0, SessionFixture.positionTarget(1)) }
    )
  )
  Assert.isTrue(struck, "the opposing strike is accepted")
  Assert.isNil(struckErr, "accepted strikes carry no input error")
  catcher:advance(64)
  local closed = SessionFixture.driveUntilSettled(catcher)
  Assert.equal(closed.status, "ended", "the successful wild capture ends the battle")
  local caught = catcher:capture()
  Assert.equal(#caught.captures, 1, "the throw records exactly one capture")
  SessionFixture.assertPlainData(caught.captures, "captures")
  local kept = Executor.restore(caught, content)
  Assert.deepEqual(kept:capture().captures, caught.captures, "restore keeps the one ledger record")
  Assert.equal(kept:capture().captureSeq, caught.captureSeq, "restore keeps the capture identity counter")
  Assert.equal(
    kept:capture().inventories.party.quantities.MASTER_BALL,
    0,
    "restore never re-spends the ball"
  )
  local reclosed = SessionFixture.driveUntilSettled(kept)
  Assert.equal(reclosed.status, "ended", "the restored capture stays ended")
  Assert.equal(reclosed.outcome.kind, "captured", "the restored capture keeps its terminal result")
  catcher:dispose()
  kept:dispose()
end

-- Battle-local health survives activation changes and interruption: a
-- damaged lead switched out keeps its wounded value while benched,
-- capturing and restoring mid-bench preserves it, and switching back in
-- resumes exactly the wounded value under the original baseline with a
-- fresh entry token and zeroed stages.
function T.switched_reserves_keep_their_wounded_health_across_restore()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local content = actionContent()
  local session = contracts.Battle.newSession(
    actionScenario(
      TRAINER_FORMAT,
      { leveledCombatant(1, 11, "EEVEE", 20), leveledCombatant(3, 31, "EEVEE", 20) },
      { leveledCombatant(2, 23, "EEVEE", 15) },
      nil
    ),
    content
  )
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local entered = session:capture()
  local fullHp = entered.combatants[1].hp
  Assert.isTrue(fullHp > 0, "the lead enters standing")
  Assert.equal(entered.combatants[1].entryHp, fullHp, "the baseline starts at full health")
  local leadActivation = entered.combatants[1].active.activation
  local reserveFullHp = entered.combatants[3].hp
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local ok, replyErr = session:submit(
    SessionFixture.replyFor(alpha, { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)) })
  )
  Assert.isTrue(ok, "the opening strike is accepted")
  Assert.isNil(replyErr, "accepted strikes carry no input error")
  local answered, answerErr = session:submit(
    SessionFixture.replyFor(beta, { SessionFixture.attackChoice(foe, 0, SessionFixture.positionTarget(1)) })
  )
  Assert.isTrue(answered, "the opposing strike is accepted")
  Assert.isNil(answerErr, "accepted strikes carry no input error")
  session:advance(64)
  local wounded = session:capture()
  local hurtHp = wounded.combatants[1].hp
  Assert.isTrue(hurtHp > 0, "the opening exchange leaves the lead standing")
  Assert.isTrue(hurtHp < fullHp, "the opening exchange wounds the lead")
  Assert.equal(wounded.combatants[1].entryHp, fullHp, "damage never moves the writeback baseline")
  Assert.isTrue(wounded.combatants[2].hp > 0, "the foe survives the opening exchange")
  local following = SessionFixture.driveUntilSettled(session)
  Assert.equal(following.status, "waiting", "the following turn asks for decisions")
  local alphaAgain = requestFor(following, "alpha")
  local betaAgain = requestFor(following, "beta")
  local lead = assert(alphaAgain.actors[1], "the following request addresses the lead")
  local foeAgain = assert(betaAgain.actors[1], "the opposing request addresses its lead")
  local switched, switchErr = session:submit(
    SessionFixture.replyFor(alphaAgain, { SessionFixture.switchChoice(lead, 3) })
  )
  Assert.isTrue(switched, "the exchange is accepted")
  Assert.isNil(switchErr, "accepted exchanges carry no input error")
  local struck, struckErr = session:submit(
    SessionFixture.replyFor(betaAgain, { SessionFixture.attackChoice(foeAgain, 0, SessionFixture.positionTarget(1)) })
  )
  Assert.isTrue(struck, "the opposing strike is accepted")
  Assert.isNil(struckErr, "accepted strikes carry no input error")
  session:advance(64)
  local benched = session:capture()
  Assert.equal(benched.positions[1].occupant, 3, "the reserve takes the vacated position")
  Assert.isNil(benched.combatants[1].active, "the outgoing lead leaves the field")
  Assert.equal(benched.combatants[1].hp, hurtHp, "the benched lead keeps its wounded value")
  Assert.equal(benched.combatants[1].entryHp, fullHp, "the benched lead keeps its baseline")
  local reserveHp = benched.combatants[3].hp
  Assert.isTrue(reserveHp > 0, "the reserve survives the exchange turn")
  SessionFixture.assertPlainData(benched, "benched interruption")
  local revived = Executor.restore(benched, content)
  local first = SessionFixture.driveUntilSettled(session)
  local second = SessionFixture.driveUntilSettled(revived)
  Assert.deepEqual(second.request, first.request, "restored sessions reopen the identical turn request")
  local revivedAlpha = requestFor(second, "alpha")
  local revivedBeta = requestFor(second, "beta")
  local reserve = assert(revivedAlpha.actors[1], "the restored request addresses the reserve")
  Assert.equal(reserve.combatant, 3, "the restored turn addresses the reserve")
  local revivedFoe = assert(revivedBeta.actors[1], "the restored opposing request addresses its lead")
  local returned, returnErr = revived:submit(
    SessionFixture.replyFor(revivedAlpha, { SessionFixture.switchChoice(reserve, 1) })
  )
  Assert.isTrue(returned, "the return exchange is accepted")
  Assert.isNil(returnErr, "accepted exchanges carry no input error")
  local revivedAnswered, revivedAnswerErr = revived:submit(
    SessionFixture.replyFor(
      revivedBeta,
      { SessionFixture.attackChoice(revivedFoe, 0, SessionFixture.positionTarget(1)) }
    )
  )
  Assert.isTrue(revivedAnswered, "the restored opposing strike is accepted")
  Assert.isNil(revivedAnswerErr, "accepted strikes carry no input error")
  local reseatedBoundary, reseatedEvents = advanceCollecting(revived, 64)
  Assert.isTrue(reseatedBoundary.status ~= "ended", "the exchange turn never ends the battle")
  local homeDamage = nil
  for _, event in ipairs(reseatedEvents) do
    if event.kind == "struck" then
      local payload = event.payload --[[@as table<string, unknown>]]
      if payload.target == 1 then
        homeDamage = payload.damage
      end
    end
  end
  Assert.isTrue(
    type(homeDamage) == "number" and homeDamage --[[@as integer]] > 0,
    "the opposing strike lands on the returning lead"
  )
  local reseated = revived:capture()
  Assert.equal(reseated.positions[1].occupant, 1, "the wounded lead retakes its position")
  Assert.equal(
    reseated.combatants[1].hp,
    hurtHp - homeDamage --[[@as integer]],
    "the returning lead resumes its wounded value before the new strike"
  )
  Assert.equal(reseated.combatants[1].entryHp, fullHp, "the returning lead keeps its original baseline")
  Assert.isTrue(
    reseated.combatants[1].active.activation ~= leadActivation,
    "the returning lead enters with a fresh entry"
  )
  Assert.deepEqual(reseated.combatants[1].stages, {
    attack = 0,
    defense = 0,
    speed = 0,
    specialAttack = 0,
    specialDefense = 0,
    accuracy = 0,
    evasion = 0,
  }, "the returning lead resets only its activation-local stages")
  Assert.isNil(reseated.combatants[3].active, "the reserve leaves the field")
  Assert.equal(reseated.combatants[3].hp, reserveHp, "the benched reserve keeps its own wounded value")
  Assert.equal(
    reseated.combatants[3].entryHp,
    reserveFullHp,
    "the benched reserve keeps its own baseline"
  )
  Assert.isNil(reseated.outcome, "no terminal result is named across the round trip")
  session:dispose()
  revived:dispose()
end

---@return table detached double battle setup with two one-point foes beside foe reserves
local function doubleKnockoutLearningScenario()
  local Executor = executorOwner()
  local first = rewardRecipient(1, 11)
  local second = tackleCombatant(6, 61)
  local foeLead = tackleCombatant(2, 23)
  foeLead.mon.condition.currentHp = 1
  local foeMate = tackleCombatant(5, 51)
  foeMate.mon.condition.currentHp = 1
  local foeReserveA = tackleCombatant(4, 41)
  local foeReserveB = tackleCombatant(7, 71)
  local seeds = { first, second, foeLead, foeMate, foeReserveA, foeReserveB }
  return {
    ruleset = Executor.RULESET,
    format = NATIVE_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { first, second }),
      SessionFixture.participant(2, 2, "beta", { foeLead, foeMate, foeReserveA, foeReserveB }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 1, { 1 }, 6),
      SessionFixture.position(3, 2, { 2 }, 2),
      SessionFixture.position(4, 2, { 2 }, 5),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(seeds),
    speciesFacts = scenarioSpeciesFacts(seeds),
  }
end

---@param request table pending decision request under test
---@return table[] one strike per addressed actor against the paired opposing slot
local function doubleAnswer(request)
  local choices = {}
  for _, actor in ipairs(request.actors) do
    local target = 3
    if actor.combatant == 6 then
      target = 4
    elseif actor.combatant == 2 then
      target = 1
    elseif actor.combatant == 5 then
      target = 2
    end
    choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(target))
  end
  return choices
end

-- Faint settlement owns one ordered replacement obligation per knocked-out
-- entry, and reward suspension never recreates or reorders them: a double
-- knockout suspends on move learning with both obligations held aside in
-- detection order, every prompt resumes the identical obligations, and
-- each reserve then enters its own vacated position exactly once with no
-- repeated award.
function T.replacement_obligations_survive_learning_suspension_in_order()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local session = contracts.Battle.newSession(doubleKnockoutLearningScenario(), content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  for _, request in ipairs(opening.request.requests) do
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, doubleAnswer(request)))
    Assert.isTrue(ok, "opening replies are accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
  end
  local collected = {}
  local boundary, knockoutEvents = advanceCollecting(session, 64)
  for _, event in ipairs(knockoutEvents) do
    collected[#collected + 1] = event
  end
  Assert.isTrue(announcesFaint(collected, 2), "the first strike knocks out its foe")
  Assert.isTrue(announcesFaint(collected, 5), "the second strike knocks out its foe")
  Assert.equal(session:capture().combatants[2].hp, 0, "the first foe stays knocked out")
  Assert.equal(session:capture().combatants[5].hp, 0, "the second foe stays knocked out")
  Assert.equal(
    boundary.status,
    "waiting",
    "the double knockout suspends on its learning prompt instead of replacing"
  )
  local prompt = findLearnPrompt(boundary)
  Assert.notNil(prompt, "the suspension names the pending learning prompt")
  Assert.equal(prompt.controller, "alpha", "the owning side answers its own learning prompt")
  local recipient = assert(prompt.actors[1], "the prompt addresses its recipient")
  Assert.equal(recipient.combatant, 1, "the prompt addresses the battle recipient")
  Assert.equal(prompt.incomingMove, "SYNTHESIS", "crossing to level twelve prompts synthesis")
  local activations = {}
  for _, event in ipairs(collected) do
    if event.kind == "faint" then
      local payload = event.payload --[[@as table<string, unknown>]]
      activations[payload.combatant --[[@as integer]]] = payload.activation
    end
  end
  Assert.notNil(activations[2], "the first faint binds its entry token")
  Assert.notNil(activations[5], "the second faint binds its entry token")
  local suspended = session:capture()
  Assert.isNil(suspended.outcome, "no terminal result is named while learning waits")
  local held = assert(suspended.pending.learning, "learning suspensions hold their obligations aside")
  local heldObligations = held --[[@as table<string, unknown>]]
  local wanted = {
    {
      combatant = 2,
      activation = activations[2],
      position = 3,
      participant = 2,
      controller = "beta",
      side = 2,
      internal = true,
    },
    {
      combatant = 5,
      activation = activations[5],
      position = 4,
      participant = 2,
      controller = "beta",
      side = 2,
      internal = true,
    },
  }
  Assert.deepEqual(
    heldObligations.obligations,
    wanted,
    "the suspension holds one ordered obligation per fainted entry"
  )
  local suspensions = 0
  local answeredSynthesis = false
  while findLearnPrompt(boundary) ~= nil and suspensions < 6 do
    suspensions = suspensions + 1
    local waiting = session:capture()
    local waitingHeld = assert(waiting.pending.learning, "every prompt holds its obligations aside")
    Assert.deepEqual(
      (waitingHeld --[[@as table<string, unknown>]]).obligations,
      wanted,
      "later prompts resume the identical obligations in order"
    )
    local open = assert(findLearnPrompt(boundary), "the suspension names its prompt")
    local addressed = assert(open.actors[1], "the prompt addresses its recipient")
    local choice
    if not answeredSynthesis and open.incomingMove == "SYNTHESIS" and addressed.combatant == 1 then
      choice = learnChoice(addressed, "replace", 3)
      answeredSynthesis = true
    else
      choice = learnChoice(addressed, "decline")
    end
    local ok, replyErr = session:submit(SessionFixture.replyFor(open, { choice }))
    Assert.isTrue(ok, "the learning reply is accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
    boundary, knockoutEvents = advanceCollecting(session, 64)
    for _, event in ipairs(knockoutEvents) do
      collected[#collected + 1] = event
    end
  end
  Assert.isTrue(answeredSynthesis, "the suspended run answers its synthesis prompt")
  Assert.isNil(findLearnPrompt(boundary), "learning drains fully before replacement")
  Assert.equal(boundary.status, "waiting", "internally resolved replacements ask for no decision")
  local following = boundary
  Assert.isNil(findLearnPrompt(following), "the following turn carries no prompt")
  local addresses = {}
  for _, request in ipairs(following.request.requests) do
    for _, actor in ipairs(request.actors) do
      addresses[#addresses + 1] = actor.combatant
    end
  end
  table.sort(addresses)
  Assert.deepEqual(addresses, { 1, 4, 6, 7 }, "the following turn addresses the standing leads")
  local settled = session:capture()
  Assert.equal(settled.positions[3].occupant, 4, "the first reserve takes the first vacated position")
  Assert.equal(settled.positions[4].occupant, 7, "the second reserve takes the second vacated position")
  Assert.isNil(settled.combatants[2].active, "the first fainted foe stays out of the field")
  Assert.isNil(settled.combatants[5].active, "the second fainted foe stays out of the field")
  local entered = { [4] = 0, [7] = 0 }
  local gained = 0
  local awards = 0
  local learned = 0
  for _, event in ipairs(collected) do
    if event.kind == "switch" then
      local payload = event.payload --[[@as table<string, unknown>]]
      if entered[payload.to --[[@as integer]]] ~= nil then
        entered[payload.to --[[@as integer]]] = entered[payload.to --[[@as integer]]] + 1
      end
    elseif event.kind == "exp" then
      awards = awards + 1
      if event.combatant == 1 then
        gained = gained + (event.gained --[[@as integer]] or 0)
      end
    elseif event.kind == "learn" then
      if event.combatant == 1 and event.move == "SYNTHESIS" then
        learned = learned + 1
      end
    end
  end
  Assert.equal(entered[4], 1, "the first reserve enters exactly once")
  Assert.equal(entered[7], 1, "the second reserve enters exactly once")
  Assert.equal(awards, 4, "both knockouts award both recipients exactly once")
  Assert.equal(
    settled.combatants[1].mon.experience,
    972 + gained,
    "the recipient keeps exactly its awarded experience"
  )
  Assert.equal(learned, 1, "the answered prompt learns its move exactly once")
  Assert.isNil(settled.outcome, "no terminal result is named while reserves stand")
  session:dispose()
end

-- Suspended obligations validate their carried identities on restore: a
-- snapshot whose held obligations lose their entry binding or stop
-- being records is rejected instead of resuming the continuation.
function T.suspended_obligations_with_broken_identities_never_restore()
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
  local unbound = session:capture()
  Assert.notNil(unbound.pending.replacement, "the suspension carries its obligations")
  unbound.pending.replacement.obligations[1].activation = nil
  Assert.throws(function()
    Executor.restore(unbound, content)
  end, "obligations without their entry token never restore")
  local foreign = session:capture()
  foreign.pending.replacement.obligations[1] = "not-a-record"
  Assert.throws(function()
    Executor.restore(foreign, content)
  end, "obligations that stop being records never restore")
  session:dispose()

  local learning = contracts.Battle.newSession(rewardScenario(), content)
  local learningOpening = SessionFixture.driveUntilSettled(learning)
  Assert.equal(learningOpening.status, "waiting", "the learning run asks for decisions")
  for _, request in ipairs(learningOpening.request.requests) do
    local ok, replyErr = learning:submit(SessionFixture.replyFor(request, answer(request)))
    Assert.isTrue(ok, "learning opening replies are accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
  end
  local suspended = SessionFixture.driveUntilSettled(learning)
  Assert.equal(suspended.status, "waiting", "the knockout suspends on its learning prompt")
  Assert.notNil(findLearnPrompt(suspended), "the suspension names its prompt")
  local held = learning:capture()
  Assert.notNil(held.pending.learning, "learning suspensions hold their obligations aside")
  held.pending.learning.obligations = { "not-a-record" }
  Assert.throws(function()
    Executor.restore(held, content)
  end, "suspended learning with a broken obligation never restores")
  learning:dispose()
end

-- Paralysis quarters effective Speed while a statused Quick Feet holder
-- keeps its passive Speed instead of the quarter. The duel pairs a faster
-- combatant against a slower one, so action order names the effective
-- speeds: healthy the faster leads, paralyzed the slower leads, and
-- paralyzed with Quick Feet the faster leads again. The first actor is
-- read from struck, missed, and status-gate events alike, so a withheld
-- paralyzed strike still proves its owner acted first.
---@param events table[] turn events in execution order
---@return integer? combatant identity that acted first, when one is named
local function firstActor(events)
  for _, event in ipairs(events) do
    if event.kind == "status-gate" then
      local payload = event.payload --[[@as table<string, unknown>]]
      if type(payload) == "table" and type(payload.combatant) == "number" then
        return payload.combatant --[[@as integer]]
      end
    elseif event.kind == "struck" or event.kind == "missed" then
      local payload = event.payload --[[@as table<string, unknown>]]
      if type(payload) == "table" and payload.target == 2 then
        return 1
      end
      if type(payload) == "table" and payload.target == 1 then
        return 2
      end
    end
  end
  return nil
end

---@param seed integer fixed generator state for the fast combatant
---@param condition string? persistent condition carried by the fast combatant
---@param ability string? battle ability carried by the fast combatant
---@return table fast combatant seed with its status and ability pinned
local function fastCombatant(seed, condition, ability)
  local entry = singleMoveCombatant(1, seed, "EEVEE", "TACKLE")
  if condition ~= nil then
    entry.mon.condition.effects = { { key = condition, version = 1, state = {} } }
  end
  if ability ~= nil then
    entry.mon.ability = ability
  end
  return entry
end

function T.paralysis_quarters_speed_while_quick_feet_keeps_passive_speed()
  local facts = {
    TACKLE = strikeFacts(0, "normal", 1),
    STRUGGLE = struggleFacts(),
  }
  local species = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "EEVEE", types = { "normal" } },
  })
  local healthy = projectionDuel(fastCombatant(11), singleMoveCombatant(2, 23, "CHIKORITA", "TACKLE"), facts, species, PROJECTION_SEED)
  Assert.equal(firstActor(playOpeningTurn(healthy)), 1, "healthy the faster combatant acts first")
  healthy:dispose()

  local held = projectionDuel(fastCombatant(11, "paralysis"), singleMoveCombatant(2, 23, "CHIKORITA", "TACKLE"), facts, species, PROJECTION_SEED)
  Assert.equal(firstActor(playOpeningTurn(held)), 2, "paralyzed the slower combatant acts first")
  held:dispose()

  local fleet = projectionDuel(fastCombatant(11, "paralysis", "QUICK_FEET"), singleMoveCombatant(2, 23, "CHIKORITA", "TACKLE"), facts, species, PROJECTION_SEED)
  Assert.equal(
    firstActor(playOpeningTurn(fleet)),
    1,
    "a statused Quick Feet holder keeps its passive Speed instead of the quarter"
  )
  fleet:dispose()
end

-- Held items reshape effective Speed before status: a Choice Scarf
-- holder outruns its faster foe while a Macho Brace holder drops behind
-- its slower foe, so action order names the item adjustment. The duel
-- pairs the same seeds as the paralysis case, hence the healthy baseline
-- still leads with the faster combatant.
function T.held_items_reshape_effective_speed_before_status()
  local facts = {
    TACKLE = strikeFacts(0, "normal", 1),
    STRUGGLE = struggleFacts(),
  }
  local species = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "EEVEE", types = { "normal" } },
  })
  local scarfed = singleMoveCombatant(2, 23, "CHIKORITA", "TACKLE")
  scarfed.mon.heldItem = "CHOICE_SCARF"
  local swift = projectionDuel(fastCombatant(11), scarfed, facts, species, PROJECTION_SEED)
  Assert.equal(firstActor(playOpeningTurn(swift)), 2, "a scarfed slower combatant acts first")
  swift:dispose()

  local braced = fastCombatant(11)
  braced.mon.heldItem = "MACHO_BRACE"
  local slow = projectionDuel(braced, singleMoveCombatant(2, 23, "CHIKORITA", "TACKLE"), facts, species, PROJECTION_SEED)
  Assert.equal(firstActor(playOpeningTurn(slow)), 2, "a braced faster combatant acts last")
  slow:dispose()
end

-- Burn halves ordinary physical output while a statused Guts holder keeps
-- its attack boost and skips the burn penalty; special output never pays
-- the burn penalty. Defender-side damage isolates the strike: the burned
-- attacker also suffers its own residual tick, which never touches the
-- defender. Identical seeds hold stats, matchups, and every draw fixed,
-- so only the status arithmetic moves the amounts.
---@param power integer compiled strike power carried by the immutable facts
---@return table<string, unknown> immutable facts for one ordinary special strike
local function specialFacts(power)
  return { power = power, accuracy = 0, category = "special", moveType = "normal", priority = 0 }
end

---@param seed integer fixed generator state for the attacker
---@param condition string? persistent condition carried by the attacker
---@param ability string? battle ability carried by the attacker
---@param move string move identity carried by the single slot
---@return table attacker seed with its status, ability, and move pinned
local function statusAttacker(seed, condition, ability, move)
  local entry = singleMoveCombatant(1, seed, "CHIKORITA", move)
  if condition ~= nil then
    entry.mon.condition.effects = { { key = condition, version = 1, state = {} } }
  end
  if ability ~= nil then
    entry.mon.ability = ability
  end
  return entry
end

function T.burn_halves_physical_damage_while_guts_keeps_its_boost()
  local physical = {
    TACKLE = strikeFacts(0, "normal", 60),
    STRUGGLE = struggleFacts(),
  }
  local special = {
    TACKLE = strikeFacts(0, "normal", 60),
    AURA_SPHERE = specialFacts(60),
    STRUGGLE = struggleFacts(),
  }
  local species = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "EEVEE", types = { "normal" } },
  })

  local plain = projectionDuel(statusAttacker(11, nil, nil, "TACKLE"), singleMoveCombatant(2, 23, "EEVEE", "TACKLE"), physical, species, PROJECTION_SEED)
  playOpeningTurn(plain)
  local healthyDamage = damageTaken(plain, 2)
  plain:dispose()

  local burned = projectionDuel(statusAttacker(11, "burn", nil, "TACKLE"), singleMoveCombatant(2, 23, "EEVEE", "TACKLE"), physical, species, PROJECTION_SEED)
  playOpeningTurn(burned)
  local burnedDamage = damageTaken(burned, 2)
  burned:dispose()
  Assert.isTrue(burnedDamage < healthyDamage, "burn halves ordinary physical output")

  local gutsy = projectionDuel(statusAttacker(11, "burn", "GUTS", "TACKLE"), singleMoveCombatant(2, 23, "EEVEE", "TACKLE"), physical, species, PROJECTION_SEED)
  playOpeningTurn(gutsy)
  local gutsDamage = damageTaken(gutsy, 2)
  gutsy:dispose()
  Assert.isTrue(gutsDamage > healthyDamage, "a statused Guts holder keeps its attack boost past the burn")

  local castPlain = projectionDuel(statusAttacker(11, nil, nil, "AURA_SPHERE"), singleMoveCombatant(2, 23, "EEVEE", "TACKLE"), special, species, PROJECTION_SEED)
  playOpeningTurn(castPlain)
  local healthySpecial = damageTaken(castPlain, 2)
  castPlain:dispose()

  local castBurned = projectionDuel(statusAttacker(11, "burn", nil, "AURA_SPHERE"), singleMoveCombatant(2, 23, "EEVEE", "TACKLE"), special, species, PROJECTION_SEED)
  playOpeningTurn(castBurned)
  local burnedSpecial = damageTaken(castBurned, 2)
  castBurned:dispose()
  Assert.equal(burnedSpecial, healthySpecial, "burn never penalizes special output")
end

-- The session decision lease lends the battle stream to exactly one open
-- internal request: the wild answer draws from the session stream and
-- returns its reply, while player, unknown, stale, and disposed requests
-- raise before drawing. The proxy dies with the callback, a failing
-- callback still releases the lease, and leases never nest.
---@return table detached native battle setup with player and wild controllers
local function leaseScenario()
  local Executor = executorOwner()
  local alpha = tackleCombatant(1, 11)
  local beta = tackleCombatant(2, 23)
  return {
    ruleset = Executor.RULESET,
    format = NATIVE_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "player", { alpha }),
      SessionFixture.participant(2, 2, "wild", { beta }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts({ alpha, beta }),
    speciesFacts = scenarioSpeciesFacts({ alpha, beta }),
  }
end

---@return table live native session waiting on its opening decisions
local function leaseSession()
  local contracts = SessionFixture.sessionContracts()
  local session = contracts.Battle.newSession(leaseScenario(), nativeContent())
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the lease duel opens its decision batch")
  return session
end

---@param session table live native session under inspection
---@param controller string controller owning the request
---@return table the open request for the controller
local function openRequest(session, controller)
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the batch stays open while requests wait")
  for _, request in ipairs(frame.request.requests) do
    if request.controller == controller then
      return request
    end
  end
  error("no open request for controller " .. controller)
end

function T.decision_stream_lease_serves_the_open_wild_request()
  local session = leaseSession()
  local wild = openRequest(session, "wild")
  local callsBefore = session:capture().rng.calls
  local drawn = nil
  local reply = session:withDecisionStream(wild, function(stream)
    drawn = stream:nextU16("wild_strike", { controller = wild.controller, request = wild.requestId })
    return {
      requestId = wild.requestId,
      epoch = wild.epoch,
      controller = wild.controller,
      choices = {},
    }
  end)
  Assert.equal(reply.requestId, wild.requestId, "the lease returns its callback result")
  Assert.isTrue(type(drawn) == "number", "the leased draw resolves through the session stream")
  Assert.equal(session:capture().rng.calls, callsBefore + 1, "the leased draw advances the session stream")
  session:dispose()
end

function T.decision_stream_lease_rejects_foreign_requests_without_drawing()
  local session = leaseSession()
  local player = openRequest(session, "wild")
  local external = openRequest(session, "player")
  local callsBefore = session:capture().rng.calls
  Assert.throws(function()
    session:withDecisionStream(external, function(stream)
      stream:nextU16("wild_strike", { controller = external.controller, request = external.requestId })
    end)
  end, "player requests never borrow the decision stream")
  Assert.throws(function()
    session:withDecisionStream(
      { requestId = 9999, epoch = player.epoch, controller = "wild", actors = player.actors },
      function(stream)
        stream:nextU16("wild_strike", { controller = "wild", request = 9999 })
      end
    )
  end, "unknown requests never borrow the decision stream")
  Assert.throws(function()
    session:withDecisionStream(
      {
        requestId = player.requestId,
        epoch = player.epoch + 1,
        controller = "wild",
        actors = player.actors,
      },
      function(stream)
        stream:nextU16("wild_strike", { controller = "wild", request = player.requestId })
      end
    )
  end, "stale epochs never borrow the decision stream")
  Assert.equal(session:capture().rng.calls, callsBefore, "rejected leases draw nothing")
  session:dispose()
end

function T.decision_stream_proxy_dies_with_its_callback()
  local session = leaseSession()
  local wild = openRequest(session, "wild")
  local held = nil
  session:withDecisionStream(wild, function(stream)
    held = stream
    return { requestId = wild.requestId }
  end)
  Assert.notNil(held, "the callback receives its stream proxy")
  Assert.throws(function()
    held:nextU16("wild_strike", { controller = wild.controller, request = wild.requestId })
  end, "retained proxies raise after the callback returns")
  Assert.throws(function()
    session:withDecisionStream(wild, function(stream)
      session:withDecisionStream(wild, function(_)
        return {}
      end)
      return { requestId = wild.requestId }
    end)
  end, "decision leases never nest")
  local callsBefore = session:capture().rng.calls
  local ok, failure = pcall(session.withDecisionStream, session, wild, function(_)
    error("controller failure")
  end)
  Assert.isFalse(ok, "callback failures propagate")
  Assert.isTrue(failure ~= nil, "the callback failure carries its cause")
  Assert.equal(session:capture().rng.calls, callsBefore, "a failed callback draws nothing")
  local recovered = session:withDecisionStream(wild, function(_)
    return { requestId = wild.requestId }
  end)
  Assert.equal(recovered.requestId, wild.requestId, "a failed callback still releases the lease")
  session:dispose()
  Assert.throws(function()
    session:withDecisionStream(wild, function(_)
      return {}
    end)
  end, "disposed sessions lend no stream")
end

-- Threaded move-frame facts reach the shared continuation from live
-- battle state: bound entries cannot flee or voluntarily switch,
-- friendship strikes execute without missing facts, pay day strikes
-- accumulate scattered coins, trick room reverses speed order, and
-- mirror move copies the recorded incoming strike. Hand-written move
-- facts stand in for the synthetic catalog where it carries no such
-- move; production facts arrive compiled.
---@param scenario table detached native battle setup record under facts
---@param extra table<string, table<string, unknown>> hand-written move facts under the union
local function withMoveFacts(scenario, extra)
  for key, facts in pairs(extra) do
    scenario.moveFacts[key] = facts
  end
  return scenario
end

---@param power integer compiled strike power under the hand facts
---@param accuracy integer compiled strike accuracy under the hand facts
---@param category string compiled strike category under the hand facts
---@param moveType string compiled strike type under the hand facts
---@param chance integer compiled secondary chance under the hand facts
---@return table<string, unknown> hand-written compiled-shaped move facts
local function handFacts(power, accuracy, category, moveType, chance)
  return {
    power = power,
    accuracy = accuracy,
    category = category,
    moveType = moveType,
    effectChance = chance,
    priority = 0,
  }
end

-- A bound entry can neither flee nor voluntarily switch: the escape
-- attempt reports its trap and the exchange reply is refused, while
-- the binding countdown keeps ticking underneath.
function T.bound_entries_cannot_flee_or_voluntarily_switch()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local alphaLead = leveledCombatant(1, 11, "CHIKORITA", 20)
  local betaLead = leveledCombatant(2, 23, "EEVEE", 20)
  betaLead.mon.moves = { { move = "WRAP", pp = 10, ppUps = 0 } }
  local scenario = withMoveFacts(actionScenario(WILD_FORMAT, { alphaLead }, { betaLead }, nil), {
    WRAP = handFacts(15, 100, "physical", "normal", 0),
  })
  local session = contracts.Battle.newSession(scenario, content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local striker = assert(alpha.actors[1], "the opening request addresses its lead")
  local binder = assert(beta.actors[1], "the opposing request addresses its lead")
  local ok, replyErr = session:submit(
    SessionFixture.replyFor(alpha, { SessionFixture.attackChoice(striker, 0, SessionFixture.positionTarget(2)) })
  )
  Assert.isTrue(ok, "the opening strike is accepted")
  Assert.isNil(replyErr, "accepted strikes carry no input error")
  local answered, answerErr = session:submit(
    SessionFixture.replyFor(beta, { SessionFixture.attackChoice(binder, 0, SessionFixture.positionTarget(1)) })
  )
  Assert.isTrue(answered, "the binding strike is accepted")
  Assert.isNil(answerErr, "accepted strikes carry no input error")
  session:advance(64)
  local held = SessionFixture.driveUntilSettled(session)
  Assert.equal(held.status, "waiting", "the bound turn asks for decisions")
  local runner = assert(requestFor(held, "alpha").actors[1], "the bound request addresses its lead")
  local chaser = assert(requestFor(held, "beta").actors[1], "the chasing request addresses its lead")
  local fled, fledErr = session:submit(SessionFixture.replyFor(requestFor(held, "alpha"), { runChoice(runner) }))
  Assert.isTrue(fled, "the bound run is accepted as an attempt")
  Assert.isNil(fledErr, "accepted runs carry no input error")
  local chased, chasedErr = session:submit(
    SessionFixture.replyFor(requestFor(held, "beta"), { SessionFixture.attackChoice(chaser, 0, SessionFixture.positionTarget(1)) })
  )
  Assert.isTrue(chased, "the chasing strike is accepted")
  Assert.isNil(chasedErr, "accepted strikes carry no input error")
  local flight = session:advance(64)
  local trapped = false
  for _, event in ipairs(flight.events or {}) do
    if event.kind == "flee" then
      local payload = event.payload --[[@as table<string, unknown>]]
      if payload.escaped == false and payload.reason == "trapped" then
        trapped = true
      end
    end
  end
  Assert.isTrue(trapped, "the bound run reports its trap")
  session:dispose()
end

-- Friendship strikes execute through threaded facts instead of
-- missing-behavior failures.
function T.threaded_friendship_strikes_execute()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local alphaLead = leveledCombatant(1, 11, "CHIKORITA", 5)
  alphaLead.mon.moves = { { move = "RETURN", pp = 10, ppUps = 0 } }
  local betaLead = leveledCombatant(2, 23, "EEVEE", 5)
  local scenario = withMoveFacts(actionScenario(WILD_FORMAT, { alphaLead }, { betaLead }, nil), {
    RETURN = handFacts(102, 100, "physical", "normal", 0),
  })
  local session = contracts.Battle.newSession(scenario, content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local before = session:capture().combatants[2].hp
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local striker = assert(alpha.actors[1], "the opening request addresses its lead")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local ok, replyErr = session:submit(
    SessionFixture.replyFor(alpha, { SessionFixture.attackChoice(striker, 0, SessionFixture.positionTarget(2)) })
  )
  Assert.isTrue(ok, "the friendship strike is accepted")
  Assert.isNil(replyErr, "accepted strikes carry no input error")
  local answered, answerErr = session:submit(
    SessionFixture.replyFor(beta, { SessionFixture.attackChoice(foe, 0, SessionFixture.positionTarget(1)) })
  )
  Assert.isTrue(answered, "the opposing strike is accepted")
  Assert.isNil(answerErr, "accepted strikes carry no input error")
  local turn = session:advance(64)
  Assert.isTrue(countKind(turn.events, "struck") >= 1, "friendship strikes land")
  Assert.isTrue(session:capture().combatants[2].hp < before, "the friendship strike deals damage")
  session:dispose()
end

-- Pay day strikes accumulate five coins per level into the snapshot
-- scatter.
function T.pay_day_strikes_accumulate_scattered_coins()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local alphaLead = leveledCombatant(1, 11, "CHIKORITA", 5)
  alphaLead.mon.moves = { { move = "PAY_DAY", pp = 10, ppUps = 0 } }
  local betaLead = leveledCombatant(2, 23, "EEVEE", 5)
  local scenario = withMoveFacts(actionScenario(WILD_FORMAT, { alphaLead }, { betaLead }, nil), {
    PAY_DAY = handFacts(40, 100, "physical", "normal", 0),
  })
  local session = contracts.Battle.newSession(scenario, content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local striker = assert(alpha.actors[1], "the opening request addresses its lead")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local ok, replyErr = session:submit(
    SessionFixture.replyFor(alpha, { SessionFixture.attackChoice(striker, 0, SessionFixture.positionTarget(2)) })
  )
  Assert.isTrue(ok, "pay day is accepted")
  Assert.isNil(replyErr, "accepted strikes carry no input error")
  local answered, answerErr = session:submit(
    SessionFixture.replyFor(beta, { SessionFixture.attackChoice(foe, 0, SessionFixture.positionTarget(1)) })
  )
  Assert.isTrue(answered, "the opposing strike is accepted")
  Assert.isNil(answerErr, "accepted strikes carry no input error")
  session:advance(64)
  Assert.equal(session:capture().paydayScattered, 25, "pay day scatters five coins per level")
  session:dispose()
end

-- Trick room reverses speed order while its field instance stands.
function T.trick_room_reverses_speed_order()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local alphaLead = leveledCombatant(1, 11, "CHIKORITA", 8)
  alphaLead.mon.moves = {
    { move = "TRICK_ROOM", pp = 10, ppUps = 0 },
    { move = "TACKLE", pp = 35, ppUps = 0 },
  }
  local betaLead = leveledCombatant(2, 23, "EEVEE", 12)
  -- The chasing lead always lands its strike, so the order assertions
  -- resolve identically on every battle-stream position.
  betaLead.mon.moves = { { move = "SCRATCH", pp = 35, ppUps = 0 } }
  local scenario = withMoveFacts(actionScenario(WILD_FORMAT, { alphaLead }, { betaLead }, nil), {
    TRICK_ROOM = {
      power = 0,
      accuracy = 0,
      category = "other",
      moveType = "psychic",
      effectChance = 0,
      priority = -7,
    },
    SCRATCH = strikeFacts(0, "normal", 35),
  })
  local session = contracts.Battle.newSession(scenario, content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local twister = assert(alpha.actors[1], "the opening request addresses its lead")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local ok, replyErr = session:submit(
    SessionFixture.replyFor(alpha, { SessionFixture.attackChoice(twister, 0, SessionFixture.positionTarget(2)) })
  )
  Assert.isTrue(ok, "trick room is accepted")
  Assert.isNil(replyErr, "accepted twists carry no input error")
  local answered, answerErr = session:submit(
    SessionFixture.replyFor(beta, { SessionFixture.attackChoice(foe, 0, SessionFixture.positionTarget(1)) })
  )
  Assert.isTrue(answered, "the opposing strike is accepted")
  Assert.isNil(answerErr, "accepted strikes carry no input error")
  session:advance(64)
  local twisted = SessionFixture.driveUntilSettled(session)
  Assert.equal(twisted.status, "waiting", "the twisted turn asks for decisions")
  local secondAlpha = requestFor(twisted, "alpha")
  local secondBeta = requestFor(twisted, "beta")
  local slow = assert(secondAlpha.actors[1], "the twisted request addresses its lead")
  local fast = assert(secondBeta.actors[1], "the chasing request addresses its lead")
  local first, firstErr = session:submit(
    SessionFixture.replyFor(secondAlpha, { SessionFixture.attackChoice(slow, 1, SessionFixture.positionTarget(2)) })
  )
  Assert.isTrue(first, "the slow strike is accepted")
  Assert.isNil(firstErr, "accepted strikes carry no input error")
  local second, secondErr = session:submit(
    SessionFixture.replyFor(secondBeta, { SessionFixture.attackChoice(fast, 0, SessionFixture.positionTarget(1)) })
  )
  Assert.isTrue(second, "the fast strike is accepted")
  Assert.isNil(secondErr, "accepted strikes carry no input error")
  local turn = session:advance(64)
  local slowIndex, fastIndex = nil, nil
  for index, event in ipairs(turn.events or {}) do
    if event.kind == "struck" then
      local payload = event.payload --[[@as table<string, unknown>]]
      if payload.target == 2 and slowIndex == nil then
        slowIndex = index
      end
      if payload.target == 1 and fastIndex == nil then
        fastIndex = index
      end
    end
  end
  Assert.notNil(slowIndex, "the slow strike lands")
  Assert.notNil(fastIndex, "the fast strike lands")
  Assert.isTrue(
    (slowIndex --[[@as integer]]) < (fastIndex --[[@as integer]]),
    "trick room orders the slow strike first"
  )
  session:dispose()
end

-- Mirror move copies the recorded incoming strike through the
-- threaded recent-move record.
function T.mirror_move_copies_the_recorded_incoming_strike()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local alphaLead = leveledCombatant(1, 11, "CHIKORITA", 20)
  alphaLead.mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "MIRROR_MOVE", pp = 10, ppUps = 0 },
  }
  -- The defender outlevels a turn-one knockout across the full native
  -- roll range, so the copying turn always has a battle to copy in.
  -- The copied strike skips its accuracy roll, so the copy lands
  -- identically on every battle-stream position.
  local betaLead = leveledCombatant(2, 23, "EEVEE", 10)
  betaLead.mon.moves = { { move = "SCRATCH", pp = 35, ppUps = 0 } }
  local scenario = withMoveFacts(actionScenario(WILD_FORMAT, { alphaLead }, { betaLead }, nil), {
    MIRROR_MOVE = handFacts(0, 0, "other", "flying", 0),
    SCRATCH = strikeFacts(0, "normal", 35),
  })
  local session = contracts.Battle.newSession(scenario, content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local striker = assert(alpha.actors[1], "the opening request addresses its lead")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local ok, replyErr = session:submit(
    SessionFixture.replyFor(alpha, { SessionFixture.attackChoice(striker, 0, SessionFixture.positionTarget(2)) })
  )
  Assert.isTrue(ok, "the opening strike is accepted")
  Assert.isNil(replyErr, "accepted strikes carry no input error")
  local answered, answerErr = session:submit(
    SessionFixture.replyFor(beta, { SessionFixture.attackChoice(foe, 0, SessionFixture.positionTarget(1)) })
  )
  Assert.isTrue(answered, "the opposing strike is accepted")
  Assert.isNil(answerErr, "accepted strikes carry no input error")
  session:advance(64)
  local copied = SessionFixture.driveUntilSettled(session)
  Assert.equal(copied.status, "waiting", "the copying turn asks for decisions")
  local before = session:capture().combatants[2].hp
  local secondAlpha = requestFor(copied, "alpha")
  local secondBeta = requestFor(copied, "beta")
  local mirror = assert(secondAlpha.actors[1], "the copying request addresses its lead")
  local target = assert(secondBeta.actors[1], "the targeted request addresses its lead")
  local first, firstErr = session:submit(
    SessionFixture.replyFor(secondAlpha, { SessionFixture.attackChoice(mirror, 1, SessionFixture.positionTarget(2)) })
  )
  Assert.isTrue(first, "mirror move is accepted")
  Assert.isNil(firstErr, "accepted copies carry no input error")
  local second, secondErr = session:submit(
    SessionFixture.replyFor(secondBeta, { SessionFixture.attackChoice(target, 0, SessionFixture.positionTarget(1)) })
  )
  Assert.isTrue(second, "the targeted strike is accepted")
  Assert.isNil(secondErr, "accepted strikes carry no input error")
  session:advance(64)
  Assert.isTrue(session:capture().combatants[2].hp < before, "mirror move strikes with the recorded move")
  session:dispose()
end

---@param id integer nonreused combatant identity under test
---@param seed integer fixed generator state for the underlying mon
---@param heldItem string carried item key under reward
---@param mark integer stored condition byte under reward
---@return table combatant seed earning the knockout with its stored mark
local function markedRecipient(id, seed, heldItem, mark)
  local entry = SessionFixture.combatant(id, seed)
  entry.mon.heldItem = heldItem
  entry.mon.pokerus = mark
  entry.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return entry
end

---@param recipient table combatant seed earning the knockout under test
---@return table detached native battle setup with a one-point foe
local function markedRewardScenario(recipient)
  local Executor = executorOwner()
  local foe = tackleCombatant(2, 23)
  foe.mon.condition.currentHp = 1
  local seeds = { recipient, foe }
  return {
    ruleset = Executor.RULESET,
    format = NATIVE_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { recipient }),
      SessionFixture.participant(2, 2, "beta", { foe }),
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

---@param session table live headless session under test
---@return table settled battle frame once the lone knockout ends the battle
local function settleMarkedKnockout(session)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  for _, request in ipairs(opening.request.requests) do
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, answer(request)))
    Assert.isTrue(ok, "opening replies are accepted")
    Assert.isNil(replyErr, "accepted replies carry no input error")
  end
  local ended, collected = advanceCollecting(session, 64)
  Assert.equal(ended.status, "ended", "the lone knockout ends the battle")
  Assert.isTrue(announcesFaint(collected, 2), "the strike knocks out the wounded foe")
  return ended
end

---@return table<string, integer> empty six-stat effort record under reward
local function blankReward()
  return { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
end

-- A stored mark reaches the live knockout reward: the marked recipient
-- with empty hands banks double the defeated single-point yield.
function T.stored_mark_reaches_the_live_knockout_reward()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local session = contracts.Battle.newSession(
    markedRewardScenario(markedRecipient(1, 11, "NONE", 1)),
    content
  )
  settleMarkedKnockout(session)
  local expected = blankReward()
  expected.specialDefense = 2
  Assert.deepEqual(
    session:capture().combatants[1].mon.evs,
    expected,
    "the marked recipient banks the doubled yield"
  )
  session:dispose()
end

-- The carried training item bonuses before the live doubling: the band
-- adds four to the defeated point first, then the mark doubles the sum.
function T.carried_training_item_bonuses_before_the_live_doubling()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local session = contracts.Battle.newSession(
    markedRewardScenario(markedRecipient(1, 11, "POWER_BAND", 1)),
    content
  )
  settleMarkedKnockout(session)
  local expected = blankReward()
  expected.specialDefense = 10
  Assert.deepEqual(
    session:capture().combatants[1].mon.evs,
    expected,
    "the band bonus stages before the live doubling"
  )
  session:dispose()
end

-- The carried brace multiplies after the live doubling even when the
-- holder cannot use items in battle: the brace effect still quadruples
-- the defeated point from the raw carried item.
function T.carried_brace_multiplies_despite_battle_item_suppression()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local recipient = markedRecipient(1, 11, "MACHO_BRACE", 1)
  recipient.mon.ability = "KLUTZ"
  local session = contracts.Battle.newSession(markedRewardScenario(recipient), content)
  settleMarkedKnockout(session)
  local expected = blankReward()
  expected.specialDefense = 4
  Assert.deepEqual(
    session:capture().combatants[1].mon.evs,
    expected,
    "the raw carried brace survives battle item suppression"
  )
  session:dispose()
end

-- Every nonzero stored mark doubles identically: an unmarked recipient
-- banks the single point while two distinct nonzero marks each bank two.
function T.every_nonzero_stored_mark_doubles_identically()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local cases = { { mark = 0, expected = 1 }, { mark = 1, expected = 2 }, { mark = 23, expected = 2 } }
  for _, case in ipairs(cases) do
    local session = contracts.Battle.newSession(
      markedRewardScenario(markedRecipient(1, 11, "NONE", case.mark)),
      content
    )
    settleMarkedKnockout(session)
    local expected = blankReward()
    expected.specialDefense = case.expected
    Assert.deepEqual(
      session:capture().combatants[1].mon.evs,
      expected,
      "mark " .. case.mark .. " settles its doubled yield"
    )
    session:dispose()
  end
end

-- Early-order holdings reorder live turns from a pre-request sample: a
-- slower Quick Claw holder moves first when its stored sample triggers
-- and stays last when the sample misses, with the samples already spent
-- while the turn waits for decisions.
function T.slower_quick_claw_holders_act_first_from_a_pre_request_sample()
  local facts = {
    TACKLE = strikeFacts(0, "normal", 1),
    STRUGGLE = struggleFacts(),
  }
  local species = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "EEVEE", types = { "normal" } },
  })

  ---@param seed integer battle stream seed under the claw duel
  ---@return table live claw duel with the slower holder leading
  local function clawDuel(seed)
    local slow = singleMoveCombatant(1, 11, "CHIKORITA", "TACKLE")
    slow.mon.heldItem = "QUICK_CLAW"
    return projectionDuel(slow, singleMoveCombatant(2, 23, "EEVEE", "TACKLE"), facts, species, seed)
  end

  local missing = clawDuel(7)
  local waiting = SessionFixture.driveUntilSettled(missing)
  Assert.equal(waiting.status, "waiting", "the turn asks for decisions")
  Assert.equal(missing:capture().rng.calls, 4, "order samples are spent before requests")
  Assert.equal(firstActor(playOpeningTurn(missing)), 2, "a missing sample keeps the slower holder last")
  missing:dispose()

  local triggering = clawDuel(164)
  Assert.equal(firstActor(playOpeningTurn(triggering)), 1, "a triggering sample moves the slower holder first")
  triggering:dispose()
end

-- Pinch priority answers from current health without spending order
-- rolls: a slower Custap holder moves first at a quarter of its health,
-- and at half health under Gluttony, while half health without Gluttony
-- and a suppressed holder stay last with identical stream use.
function T.pinch_priority_berries_answer_from_health_without_spending_order_rolls()
  local facts = {
    TACKLE = strikeFacts(0, "normal", 1),
    STRUGGLE = struggleFacts(),
  }
  local species = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "EEVEE", types = { "normal" } },
  })

  ---@param health integer holder health entering the turn
  ---@param ability string? holder ability gating the pinch threshold
  ---@return integer combatant identity acting first with the berry
  ---@return integer battle draws spent with the berry
  ---@return integer battle draws spent without the berry
  local function pinchOrder(health, ability)
    local holder = singleMoveCombatant(1, 11, "CHIKORITA", "TACKLE")
    holder.mon.heldItem = "CUSTAP_BERRY"
    holder.mon.condition.currentHp = health
    if ability ~= nil then
      holder.mon.ability = ability
    end
    local berried = projectionDuel(holder, singleMoveCombatant(2, 23, "EEVEE", "TACKLE"), facts, species, 7)
    local berriedFirst = firstActor(playOpeningTurn(berried))
    local berriedCalls = berried:capture().rng.calls
    berried:dispose()
    local plain = singleMoveCombatant(1, 11, "CHIKORITA", "TACKLE")
    plain.mon.condition.currentHp = health
    local bare = projectionDuel(plain, singleMoveCombatant(2, 23, "EEVEE", "TACKLE"), facts, species, 7)
    local bareFirst = firstActor(playOpeningTurn(bare))
    local bareCalls = bare:capture().rng.calls
    bare:dispose()
    Assert.equal(bareFirst, 2, "the bare slower holder stays last")
    Assert.equal(berriedCalls, bareCalls, "the pinch berry spends no order roll")
    return berriedFirst --[[@as integer]]
  end

  Assert.equal(pinchOrder(7, nil), 1, "a quarter-health holder moves first")
  Assert.equal(pinchOrder(14, "GLUTTONY"), 1, "a half-health holder moves first under Gluttony")
  Assert.equal(pinchOrder(14, nil), 2, "half health stays last without Gluttony")
  Assert.equal(pinchOrder(7, "KLUTZ"), 2, "a suppressed holder stays last")
end

-- Suppressed holdings lose their ordinary effects while raw speed halving
-- survives: a Klutz Choice Scarf holder moves last with its item still
-- possessed, a Klutz Macho Brace holder still moves last, and a Klutz
-- Smoke Ball holder fails its wild flight odds like a bare lead.
function T.suppressed_holdings_lose_ordinary_effects_while_raw_speed_halving_survives()
  local facts = {
    TACKLE = strikeFacts(0, "normal", 1),
    STRUGGLE = struggleFacts(),
  }
  local species = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "EEVEE", types = { "normal" } },
  })

  ---@param slow table slower lead seed carrying the holding under test
  ---@param foeSpecies string opposing species setting the speed matchup
  ---@return integer combatant identity acting first
  ---@return table live session after its opening turn
  local function orderAfterTurn(slow, foeSpecies)
    local session = projectionDuel(
      slow,
      singleMoveCombatant(2, 23, foeSpecies, "TACKLE"),
      facts,
      species,
      7
    )
    local first = firstActor(playOpeningTurn(session))
    return first --[[@as integer]], session
  end

  local swift = singleMoveCombatant(1, 11, "CHIKORITA", "TACKLE")
  swift.mon.heldItem = "CHOICE_SCARF"
  local swiftFirst, swiftSession = orderAfterTurn(swift, "EEVEE")
  Assert.equal(swiftFirst, 1, "an effective scarf moves the slower holder first")
  swiftSession:dispose()

  local gagged = singleMoveCombatant(1, 11, "CHIKORITA", "TACKLE")
  gagged.mon.heldItem = "CHOICE_SCARF"
  gagged.mon.ability = "KLUTZ"
  local gaggedFirst, gaggedSession = orderAfterTurn(gagged, "EEVEE")
  Assert.equal(gaggedFirst, 2, "a suppressed scarf keeps the slower holder last")
  Assert.equal(
    gaggedSession:capture().combatants[1].mon.heldItem,
    "CHOICE_SCARF",
    "suppression keeps the possession on record"
  )
  gaggedSession:dispose()

  local braced = singleMoveCombatant(1, 11, "EEVEE", "TACKLE")
  braced.mon.heldItem = "MACHO_BRACE"
  local bracedFirst, bracedSession = orderAfterTurn(braced, "CHIKORITA")
  Assert.equal(bracedFirst, 2, "the raw halving drops the faster holder last")
  bracedSession:dispose()

  local shackled = singleMoveCombatant(1, 11, "EEVEE", "TACKLE")
  shackled.mon.heldItem = "MACHO_BRACE"
  shackled.mon.ability = "KLUTZ"
  local shackledFirst, shackledSession = orderAfterTurn(shackled, "CHIKORITA")
  Assert.equal(shackledFirst, 2, "the raw halving survives suppression")
  shackledSession:dispose()

  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local lead = leveledCombatant(1, 11, "CHIKORITA", 5)
  lead.mon.heldItem = "SMOKE_BALL"
  lead.mon.ability = "KLUTZ"
  local flight = contracts.Battle.newSession(
    actionScenario(
      WILD_FORMAT,
      { lead },
      { leveledCombatant(2, 23, "EEVEE", 40), leveledCombatant(4, 41, "EEVEE", 5) },
      nil
    ),
    content
  )
  local opening = SessionFixture.driveUntilSettled(flight)
  Assert.equal(opening.status, "waiting", "the flight turn asks for decisions")
  local callsBefore = flight:capture().rng.calls
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local runner = assert(alpha.actors[1], "the flight request addresses its lead")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local fled, fledErr = flight:submit(SessionFixture.replyFor(alpha, { runChoice(runner) }))
  Assert.isTrue(fled, "the wild run is accepted")
  Assert.isNil(fledErr, "accepted runs carry no input error")
  local answered, answerErr =
    flight:submit(SessionFixture.replyFor(beta, { SessionFixture.switchChoice(foe, 4) }))
  Assert.isTrue(answered, "the opposing exchange is accepted")
  Assert.isNil(answerErr, "accepted exchanges carry no input error")
  flight:advance(64)
  local stalled = SessionFixture.driveUntilSettled(flight)
  Assert.equal(stalled.status, "waiting", "the suppressed flight continues the battle")
  Assert.isNil(flight:capture().outcome, "the suppressed flight names no terminal result")
  -- One odds roll for the suppressed flight plus the four pre-turn
  -- samples of the following batch, already spent while it waits.
  Assert.equal(flight:capture().rng.calls, callsBefore + 5, "the suppressed flight spends its odds roll")
  flight:dispose()
end

-- Live strikes carry complete critical facts to the resolver: held-item,
-- ability, move, and species contributions raise the stage, wards negate
-- only after the draw, and the sniping ability replaces only the
-- surviving multiplier, all without spending extra draws.
function T.live_strikes_carry_complete_critical_facts_to_the_resolver()
  local species = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "EEVEE", types = { "normal" } },
  })
  local facts = {
    TACKLE = strikeFacts(0, "normal", 60),
    RAZOR_LEAF = { power = 60, accuracy = 0, category = "physical", moveType = "normal", priority = 0 },
    STRUGGLE = struggleFacts(),
  }

  ---@param move string striking move carried by the faster lead
  ---@param ability string? striker ability under the check
  ---@param item string? striker holding under the check
  ---@param ward string? defender ability under the check
  ---@return integer damage dealt to the defender over the opening turn
  ---@return integer battle draws spent over the opening turn
  local function openingDamage(move, ability, item, ward)
    local striker = singleMoveCombatant(1, 11, "EEVEE", move)
    if ability ~= nil then
      striker.mon.ability = ability
    end
    if item ~= nil then
      striker.mon.heldItem = item
    end
    local defender = singleMoveCombatant(2, 23, "CHIKORITA", "TACKLE")
    if ward ~= nil then
      defender.mon.ability = ward
    end
    -- The critical roll is the fifth battle draw behind the four
    -- pre-turn order samples; this seed separates a missing stage
    -- from a raised one on that roll while the later roll never crits.
    local session = projectionDuel(striker, defender, facts, species, 30)
    playOpeningTurn(session)
    local dealt = damageTaken(session, 2)
    local calls = session:capture().rng.calls
    session:dispose()
    return dealt, calls
  end

  local plain, plainCalls = openingDamage("TACKLE", nil, nil, nil)
  local lens, lensCalls = openingDamage("TACKLE", nil, "SCOPE_LENS", nil)
  Assert.isTrue(lens > plain, "a critical holding raises the live stage")
  local lucky, luckyCalls = openingDamage("TACKLE", "SUPER_LUCK", nil, nil)
  Assert.isTrue(lucky > plain, "a critical ability raises the live stage")
  local raised, raisedCalls = openingDamage("RAZOR_LEAF", nil, nil, nil)
  Assert.isTrue(raised > plain, "a raised move carries its live stage")
  local punch, punchCalls = openingDamage("TACKLE", nil, "LUCKY_PUNCH", nil)
  Assert.equal(punch, plain, "a species-locked holding stays silent for the wrong holder")
  local warded, wardedCalls = openingDamage("TACKLE", nil, "SCOPE_LENS", "BATTLE_ARMOR")
  Assert.equal(warded, plain, "a ward negates the spent roll without touching the stream")
  local sniping, snipingCalls = openingDamage("TACKLE", "SNIPER", "SCOPE_LENS", nil)
  Assert.isTrue(sniping > lens, "the sniping ability replaces only the surviving multiplier")
  for _, calls in ipairs({ lensCalls, luckyCalls, raisedCalls, punchCalls, wardedCalls, snipingCalls }) do
    Assert.equal(calls, plainCalls, "complete facts spend no extra draw")
  end
end

-- Canonical ability and item passives change live battle state: wards
-- block, prevention holds, reflection answers, stat abilities reshape
-- output, triggered holdings consume, and residual holdings recover or
-- heal through poison, with suppression silencing only the ordinary
-- effect while raw possession stays on record.
function T.canonical_passives_change_live_battle_state()
  local species = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "EEVEE", types = { "normal" } },
    { species = "TOTODILE", types = { "water" } },
    { species = "SHEDINJA", types = { "bug", "ghost" } },
  })
  -- Heavy strikes pipeline through bound plain strikers with test-owned
  -- facts: unbound move names cannot execute, so the measurement uses
  -- real handlers while power and type stay with the fixture.
  local facts = {
    TACKLE = strikeFacts(0, "normal", 1),
    FAINT_ATTACK = strikeFacts(0, "normal", 60),
    WATER_GUN = strikeFacts(0, "water", 60),
    POISON_JAB = {
      power = 20,
      accuracy = 0,
      category = "physical",
      moveType = "normal",
      priority = 0,
      effectChance = 100,
    },
    STRUGGLE = struggleFacts(),
  }

  ---@param session table live native session after its turn
  ---@param combatant integer combatant identity under inspection
  ---@return integer persistent conditions carried by the mon record
  local function conditionCount(session, combatant)
    local record = session:capture().combatants[combatant] --[[@as table<string, unknown>]]
    local mon = record.mon --[[@as table<string, unknown>]]
    local condition = mon.condition --[[@as table<string, unknown>]]
    local effects = condition.effects --[[@as table<integer, unknown>]]
    return #effects
  end

  ---@param session table live native session under inspection
  ---@param combatant integer combatant identity under inspection
  ---@return string? held item key carried by the mon record, absent once consumed
  local function heldItemOf(session, combatant)
    local record = session:capture().combatants[combatant] --[[@as table<string, unknown>]]
    local mon = record.mon --[[@as table<string, unknown>]]
    local held = mon.heldItem --[[@as string?]]
    if held == "NONE" then
      return nil
    end
    return held
  end

  do
    local striker = singleMoveCombatant(1, 11, "TOTODILE", "TACKLE")
    local guard = singleMoveCombatant(2, 23, "SHEDINJA", "TACKLE")
    guard.mon.ability = "WONDER_GUARD"
    local session = projectionDuel(
      striker,
      guard,
      { TACKLE = strikeFacts(0, "water", 60), STRUGGLE = struggleFacts() },
      species,
      7
    )
    playOpeningTurn(session)
    local guarded = session:capture().combatants
    Assert.equal(
      guarded[2].hp,
      guarded[2].entryHp,
      "the ward leaves the guarded holder unwounded"
    )
    session:dispose()
  end

  do
    local striker = singleMoveCombatant(1, 11, "CHIKORITA", "POISON_JAB")
    local ward = singleMoveCombatant(2, 23, "EEVEE", "TACKLE")
    ward.mon.ability = "IMMUNITY"
    local session = projectionDuel(striker, ward, facts, species, 7)
    playOpeningTurn(session)
    Assert.equal(conditionCount(session, 2), 0, "prevention keeps the warded holder clean")
    session:dispose()
  end

  do
    local striker = singleMoveCombatant(1, 11, "CHIKORITA", "POISON_JAB")
    local mirror = singleMoveCombatant(2, 23, "EEVEE", "TACKLE")
    mirror.mon.ability = "SYNCHRONIZE"
    local session = projectionDuel(striker, mirror, facts, species, 7)
    playOpeningTurn(session)
    Assert.isTrue(conditionCount(session, 1) >= 1, "reflection shares the inflicted status with the user")
    session:dispose()
  end

  ---@param ability string? defender ability reshaping the strike
  ---@return integer damage dealt to the poisoned defender
  local function poisonedDamage(ability)
    local striker = singleMoveCombatant(1, 11, "EEVEE", "FAINT_ATTACK")
    local defender = singleMoveCombatant(2, 23, "CHIKORITA", "TACKLE")
    defender.mon.condition.effects = { { key = "poison", version = 1, state = {} } }
    if ability ~= nil then
      defender.mon.ability = ability
    end
    local session = projectionDuel(striker, defender, facts, species, 7)
    playOpeningTurn(session)
    local dealt = damageTaken(session, 2)
    session:dispose()
    return dealt
  end
  Assert.isTrue(
    poisonedDamage("MARVEL_SCALE") < poisonedDamage(nil),
    "a statused scale holder softens the strike"
  )

  ---@param ability string? striker ability reshaping the resisted strike
  ---@return integer damage dealt through the resisted matchup
  local function resistedDamage(ability)
    local striker = singleMoveCombatant(1, 11, "EEVEE", "WATER_GUN")
    if ability ~= nil then
      striker.mon.ability = ability
    end
    local session = projectionDuel(striker, singleMoveCombatant(2, 23, "CHIKORITA", "TACKLE"), facts, species, 7)
    playOpeningTurn(session)
    local dealt = damageTaken(session, 2)
    session:dispose()
    return dealt
  end
  Assert.isTrue(
    resistedDamage("TINTED_LENS") > resistedDamage(nil),
    "a piercing ability restores the resisted strike"
  )

  ---@param item string? striker holding answering the landed strike
  ---@return integer striker health after dealing its strike
  local function bellHealth(item)
    local striker = singleMoveCombatant(1, 11, "EEVEE", "FAINT_ATTACK")
    if item ~= nil then
      striker.mon.heldItem = item
    end
    striker.mon.condition.currentHp = 21
    local session = projectionDuel(striker, singleMoveCombatant(2, 23, "CHIKORITA", "TACKLE"), facts, species, 7)
    playOpeningTurn(session)
    local health = session:capture().combatants[1].hp
    session:dispose()
    return health
  end
  Assert.isTrue(bellHealth("SHELL_BELL") > bellHealth(nil), "a ringing holder recovers from its strike")

  ---@param ability string? holder ability answering the poison
  ---@param item string? holder item answering the turn
  ---@param health integer holder health entering the turn
  ---@param condition string? persistent status carried by the holder
  ---@return integer holder health after the turn
  ---@return string? holder item after the turn
  local function residualHealth(ability, item, health, condition)
    local holder = singleMoveCombatant(1, 11, "CHIKORITA", "TACKLE")
    if ability ~= nil then
      holder.mon.ability = ability
    end
    if item ~= nil then
      holder.mon.heldItem = item
    end
    holder.mon.condition.currentHp = health
    if condition ~= nil then
      holder.mon.condition.effects = { { key = condition, version = 1, state = {} } }
    end
    local session = projectionDuel(holder, singleMoveCombatant(2, 23, "EEVEE", "TACKLE"), facts, species, 7)
    playOpeningTurn(session)
    local after = session:capture().combatants[1].hp
    local held = heldItemOf(session, 1)
    session:dispose()
    return after, held
  end
  local healed = residualHealth("POISON_HEAL", nil, 23, "poison")
  local ticking = residualHealth(nil, nil, 23, "poison")
  Assert.isTrue(healed > ticking, "a poisoned healer recovers instead of draining")
  local berried, berriedHeld = residualHealth(nil, "SITRUS_BERRY", 14, nil)
  local unberried = residualHealth(nil, nil, 14, nil)
  Assert.isTrue(berried > unberried, "a pinch berry recovers its holder")
  Assert.isNil(berriedHeld, "a triggered berry leaves the holder empty")
  local stuffed, stuffedHeld = residualHealth(nil, "LEFTOVERS", 24, nil)
  local unstuffed = residualHealth(nil, nil, 24, nil)
  Assert.isTrue(stuffed > unstuffed, "a persistent holding recovers its holder")
  Assert.equal(stuffedHeld, "LEFTOVERS", "a persistent holding stays possessed")
  local gagged, gaggedHeld = residualHealth("KLUTZ", "LEFTOVERS", 24, nil)
  Assert.equal(gagged, unstuffed, "a suppressed holding recovers nothing")
  Assert.equal(gaggedHeld, "LEFTOVERS", "suppression keeps the possession on record")
end

-- Consumed holdings stay empty for later checkpoints: a pinch berry
-- heals once and leaves, and the following turn recovers nothing more.
function T.consumed_holdings_stay_empty_for_later_checkpoints()
  local facts = {
    TACKLE = strikeFacts(0, "normal", 1),
    STRUGGLE = struggleFacts(),
  }
  local species = typedSpeciesFacts({
    { species = "CHIKORITA", types = { "grass" } },
    { species = "EEVEE", types = { "normal" } },
  })

  ---@param item string? holder item answering the turns
  ---@return integer holder health after the first turn
  ---@return string? holder item after the first turn
  ---@return integer holder health after the second turn
  ---@return table live session after two turns
  local function twoTurns(item)
    local holder = singleMoveCombatant(1, 11, "CHIKORITA", "TACKLE")
    if item ~= nil then
      holder.mon.heldItem = item
    end
    holder.mon.condition.currentHp = 14
    local session = projectionDuel(holder, singleMoveCombatant(2, 23, "EEVEE", "TACKLE"), facts, species, 7)
    playOpeningTurn(session)
    local middle = session:capture().combatants[1].hp
    local held = session:capture().combatants[1].mon.heldItem --[[@as string?]]
    if held == "NONE" then
      held = nil
    end
    playOpeningTurn(session)
    local finish = session:capture().combatants[1].hp
    return middle, held, finish, session
  end

  local berriedMiddle, berriedHeld, berriedFinish, berried = twoTurns("SITRUS_BERRY")
  local bareMiddle, _, bareFinish, bare = twoTurns(nil)
  Assert.isTrue(berriedMiddle > bareMiddle, "the berry heals on its triggering turn")
  Assert.isNil(berriedHeld, "the consumed berry stays empty for the later turn")
  Assert.equal(
    berriedFinish - berriedMiddle,
    bareFinish - bareMiddle,
    "the later turn recovers nothing more"
  )
  berried:dispose()
  bare:dispose()
end

-- A breaking striker pierces ability wards live: the same water
-- strike stops cold on a wonder-guarded holder but wounds it when the
-- striker carries the breaking ability.
function T.breaking_strikes_pierce_ability_wards_live()
  local species = typedSpeciesFacts({
    { species = "TOTODILE", types = { "water" } },
    { species = "SHEDINJA", types = { "bug", "ghost" } },
  })
  local facts = {
    WATER_GUN = strikeFacts(0, "water", 60),
    TACKLE = strikeFacts(0, "normal", 1),
    STRUGGLE = struggleFacts(),
  }
  do
    local striker = singleMoveCombatant(1, 11, "TOTODILE", "WATER_GUN")
    local guard = singleMoveCombatant(2, 23, "SHEDINJA", "TACKLE")
    guard.mon.ability = "WONDER_GUARD"
    local session = projectionDuel(striker, guard, facts, species, 7)
    playOpeningTurn(session)
    local holders = session:capture().combatants
    Assert.equal(holders[2].hp, holders[2].entryHp, "the ward leaves the guarded holder unwounded")
    session:dispose()
  end
  do
    local breaker = singleMoveCombatant(1, 11, "TOTODILE", "WATER_GUN")
    breaker.mon.ability = "MOLD_BREAKER"
    local guard = singleMoveCombatant(2, 23, "SHEDINJA", "TACKLE")
    guard.mon.ability = "WONDER_GUARD"
    local session = projectionDuel(breaker, guard, facts, species, 7)
    playOpeningTurn(session)
    local holders = session:capture().combatants
    Assert.isTrue(holders[2].hp < holders[2].entryHp, "the breaking strike wounds the guarded holder")
    session:dispose()
  end
end

return { tests = T }
