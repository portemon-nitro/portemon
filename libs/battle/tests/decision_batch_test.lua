-- Shared decision batch admission: replies that overbook one batch are
-- rejected atomically, while the surrounding protocol envelope behaves
-- identically no matter which controller answers first.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@return table scenario parts where one side fields two leads beside a benched reserve
local function reserveDoubles()
  return {
    sides = {
      SessionFixture.side(1, { 1 }),
      SessionFixture.side(2, { 2 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "alpha", {
        SessionFixture.combatant(1, 11),
        SessionFixture.combatant(2, 12),
        SessionFixture.combatant(5, 15),
      }),
      SessionFixture.participant(2, 2, "beta", { SessionFixture.combatant(3, 23) }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 1, { 1 }, 2),
      SessionFixture.position(3, 2, { 2 }, 3),
    },
  }
end

---@return table scenario parts where one side fields two leads over a single shared unit
local function stockedDoubles()
  local parts = reserveDoubles()
  parts.participants[1].inventoryId = "bag"
  parts.inventories = {
    SessionFixture.inventory("bag", { 1 }, { POTION = 1 }),
  }
  return parts
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

---@return table combatant seed striking with a single known move
local function sharedTackleCombatant(id, seed)
  local entry = SessionFixture.combatant(id, seed)
  entry.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return entry
end

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, table<string, unknown>> immutable move facts for the shared fixture strikes
local function sharedMoveFacts(seeds)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local facts = {
    TACKLE = catalog:move("TACKLE"),
    STRUGGLE = { power = 50, accuracy = 100, category = "physical", moveType = "normal", priority = 0 },
  }
  for _, seed in ipairs(seeds) do
    local learned = seed.mon --[[@as table<string, unknown>]]
    for _, entry in
      ipairs(learned.moves --[[@as table<integer, table<string, unknown>>]])
    do
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

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, table<integer, table<string, unknown>>> static species facts for the shared combatants
local function sharedSpeciesFacts(seeds)
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
    local formRecord = catalog:form(species, form)
    local types = {} ---@type string[]
    for _, key in
      ipairs(formRecord.types --[[@as string[] ]])
    do
      types[#types + 1] = key --[[@as string]]
    end
    bucket[form] = {
      baseStats = formRecord.baseStats,
      growthCurve = catalog:growthCurve(speciesRecord.growthCurve --[[@as string]]),
      types = types,
      levelUpMoves = formRecord.levelUpMoves,
      baseExpYield = speciesRecord.baseExpYield,
      evYield = speciesRecord.evYield,
    }
  end
  return facts
end

---@return table frozen battle content carrying the native ruleset with a doubles format
local function sharedNativeDoubleContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "the private native lifecycle owns HGSS ruleset sessions"
  )
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "shared-batch-native-doubles")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "shared-batch-native-doubles"
  )
  behaviors:registerFormat("test:shared-double", { key = "test:shared-double" }, "shared-batch-native-doubles")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

local SHARED_NATIVE_SEED = 0x1BADB002

---@return table detached native doubles setup with two leads per side beside benched reserves
local function sharedNativeDoublesScenario()
  local Executor = SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "the private native lifecycle owns HGSS ruleset sessions"
  )
  local seeds = {
    sharedTackleCombatant(1, 11),
    sharedTackleCombatant(2, 12),
    sharedTackleCombatant(5, 15),
    sharedTackleCombatant(3, 23),
    sharedTackleCombatant(4, 24),
    sharedTackleCombatant(6, 26),
  }
  return {
    ruleset = Executor.RULESET,
    format = "test:shared-double",
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { seeds[1], seeds[2], seeds[3] }),
      SessionFixture.participant(2, 2, "beta", { seeds[4], seeds[5], seeds[6] }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 1, { 1 }, 2),
      SessionFixture.position(3, 2, { 2 }, 3),
      SessionFixture.position(4, 2, { 2 }, 4),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = SHARED_NATIVE_SEED },
    formatState = {},
    moveFacts = sharedMoveFacts(seeds),
    speciesFacts = sharedSpeciesFacts(seeds),
  }
end

---@param actor table combatant reference the choice is issued for
---@return table validated decision payload spending one shared unit on its holder
local function itemChoice(actor)
  return {
    actor = actor,
    kind = "item",
    payload = { item = "POTION", target = { kind = "combatant", combatant = actor.combatant } },
  }
end

-- Two leads answering together cannot book the same reserve or spend one
-- shared unit twice: each overbooking reply is rejected whole, keeps no
-- partial reservation, draws nothing, and leaves a later valid reply
-- accepted. A reply that fails only on its second choice is rejected the
-- same way.
function T.shared_reservations_reject_same_reply_double_booking_without_side_effects()
  local contracts = SessionFixture.sessionContracts()

  local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(reserveDoubles()))
  local waiting = SessionFixture.driveUntilSettled(session, 64)
  Assert.equal(waiting.status, "waiting", "the doubled battle waits for both sides")
  local alpha = requestFor(waiting, "alpha")
  Assert.equal(#alpha.actors, 2, "one reply answers both leads together")
  local firstActor = assert(alpha.actors[1], "the shared reply addresses its first lead")
  local secondActor = assert(alpha.actors[2], "the shared reply addresses its second lead")
  local pristine = session:capture()
  local callsBefore = pristine.rng.calls

  local doubled, doubleErr = session:submit(SessionFixture.replyFor(alpha, {
    SessionFixture.switchChoice(firstActor, 5),
    SessionFixture.switchChoice(secondActor, 5),
  }))
  Assert.isFalse(doubled, "one reserve cannot answer twice in the same reply")
  Assert.notNil(doubleErr, "rejected double bookings name their input error")
  Assert.deepEqual(session:capture(), pristine, "rejected replies keep no partial reservation")

  local mixed, mixedErr = session:submit(SessionFixture.replyFor(alpha, {
    SessionFixture.attackChoice(firstActor, 0, SessionFixture.positionTarget(3)),
    SessionFixture.switchChoice(secondActor, 99),
  }))
  Assert.isFalse(mixed, "a reply failing only on its second choice is rejected whole")
  Assert.notNil(mixedErr, "rejected late choices name their input error")
  Assert.deepEqual(session:capture(), pristine, "late failures keep no earlier choice")
  Assert.equal(session:capture().rng.calls, callsBefore, "rejected replies draw nothing")

  local ok, replyErr = session:submit(SessionFixture.replyFor(alpha, {
    SessionFixture.switchChoice(firstActor, 5),
    SessionFixture.attackChoice(secondActor, 0, SessionFixture.positionTarget(3)),
  }))
  Assert.isTrue(ok, "a later valid reply is accepted: " .. tostring(replyErr))
  Assert.isNil(replyErr, "accepted replies carry no input error")
  local beta = requestFor(SessionFixture.driveUntilSettled(session, 64), "beta")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local foeOk, foeErr = session:submit(SessionFixture.replyFor(beta, {
    SessionFixture.attackChoice(foe, 0, SessionFixture.positionTarget(1)),
  }))
  Assert.isTrue(foeOk, "the waiting peer still answers: " .. tostring(foeErr))
  Assert.isNil(foeErr, "accepted peer replies carry no input error")
  local turn = session:advance(64)
  Assert.isTrue(turn.status ~= nil, "the completed batch commits")
  session:dispose()

  local stocked = SessionFixture.newSession(contracts, SessionFixture.buildScenario(stockedDoubles()))
  local stockedWaiting = SessionFixture.driveUntilSettled(stocked, 64)
  Assert.equal(stockedWaiting.status, "waiting", "the stocked battle waits for both sides")
  local stockedAlpha = requestFor(stockedWaiting, "alpha")
  local stockedFirst = assert(stockedAlpha.actors[1], "the stocked reply addresses its first lead")
  local stockedSecond = assert(stockedAlpha.actors[2], "the stocked reply addresses its second lead")
  local stockedPristine = stocked:capture()
  local spent, spentErr = stocked:submit(SessionFixture.replyFor(stockedAlpha, {
    itemChoice(stockedFirst),
    itemChoice(stockedSecond),
  }))
  Assert.isFalse(spent, "one shared unit cannot serve twice in the same reply")
  Assert.notNil(spentErr, "rejected double spending names its input error")
  Assert.deepEqual(stocked:capture(), stockedPristine, "rejected spending keeps the shared stock")
  local healed, healedErr = stocked:submit(SessionFixture.replyFor(stockedAlpha, {
    itemChoice(stockedFirst),
    SessionFixture.attackChoice(stockedSecond, 0, SessionFixture.positionTarget(3)),
  }))
  Assert.isTrue(healed, "spending the single unit once is accepted: " .. tostring(healedErr))
  Assert.isNil(healedErr, "accepted spending carries no input error")
  stocked:dispose()
end

-- The decision envelope is order independent: stale epochs, duplicates,
-- foreign controllers, and unknown requests fail as input errors without
-- touching the batch, while answering in either arrival order commits
-- the identical events.
function T.decision_envelopes_behave_identically_across_executors_and_arrival_orders()
  local contracts = SessionFixture.sessionContracts()

  local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(reserveDoubles()))
  local waiting = SessionFixture.driveUntilSettled(session, 64)
  Assert.equal(waiting.status, "waiting", "open battles wait for both controllers")
  local alpha = requestFor(waiting, "alpha")
  local beta = requestFor(waiting, "beta")
  local pristine = session:capture()

  local staleReply = SessionFixture.replyFor(alpha, {
    SessionFixture.attackChoice(alpha.actors[1], 0, SessionFixture.positionTarget(3)),
    SessionFixture.attackChoice(alpha.actors[2], 0, SessionFixture.positionTarget(3)),
  })
  staleReply.epoch = waiting.request.epoch + 1
  local staleOk, staleErr = session:submit(staleReply)
  Assert.isFalse(staleOk, "stale epochs cannot answer a frozen batch")
  Assert.notNil(staleErr, "rejected epochs name their input error")

  local foreignReply = SessionFixture.replyFor(alpha, {
    SessionFixture.attackChoice(beta.actors[1], 0, SessionFixture.positionTarget(1)),
  })
  local foreignOk, foreignErr = session:submit(foreignReply)
  Assert.isFalse(foreignOk, "controllers cannot answer for foreign actors")
  Assert.notNil(foreignErr, "rejected foreign actors name their input error")

  local unknownReply = SessionFixture.replyFor(alpha, {
    SessionFixture.attackChoice(alpha.actors[1], 0, SessionFixture.positionTarget(3)),
    SessionFixture.attackChoice(alpha.actors[2], 0, SessionFixture.positionTarget(3)),
  })
  unknownReply.requestId = 999999
  local unknownOk, unknownErr = session:submit(unknownReply)
  Assert.isFalse(unknownOk, "unknown requests answer nothing")
  Assert.notNil(unknownErr, "rejected unknown requests name their input error")

  local validChoices = {
    SessionFixture.attackChoice(alpha.actors[1], 0, SessionFixture.positionTarget(3)),
    SessionFixture.attackChoice(alpha.actors[2], 0, SessionFixture.positionTarget(3)),
  }
  local ok, replyErr = session:submit(SessionFixture.replyFor(alpha, validChoices))
  Assert.isTrue(ok, "the first valid reply is accepted: " .. tostring(replyErr))
  Assert.isNil(replyErr, "accepted replies carry no input error")
  local again, againErr = session:submit(SessionFixture.replyFor(alpha, validChoices))
  Assert.isFalse(again, "duplicate replies cannot answer twice")
  Assert.notNil(againErr, "rejected duplicates name their input error")

  local betaActor = assert(beta.actors[1], "the opposing request addresses its lead")
  local betaOk, betaErr = session:submit(SessionFixture.replyFor(beta, {
    SessionFixture.attackChoice(betaActor, 0, SessionFixture.positionTarget(1)),
  }))
  Assert.isTrue(betaOk, "the waiting peer still answers: " .. tostring(betaErr))
  Assert.isNil(betaErr, "accepted peer replies carry no input error")
  local firstEvents = SessionFixture.driveToEnd(session, 64, function(request)
    local choices = {}
    for _, actor in ipairs(request.actors) do
      choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(3))
    end
    return choices
  end)
  session:dispose()

  local reversed = SessionFixture.newSession(contracts, SessionFixture.buildScenario(reserveDoubles()))
  local reopened = SessionFixture.driveUntilSettled(reversed, 64)
  local reopenedBeta = requestFor(reopened, "beta")
  local reopenedAlpha = requestFor(reopened, "alpha")
  local reopenedFoe = assert(reopenedBeta.actors[1], "the reversed peer answers first")
  local reversedBetaOk, reversedBetaErr = reversed:submit(SessionFixture.replyFor(reopenedBeta, {
    SessionFixture.attackChoice(reopenedFoe, 0, SessionFixture.positionTarget(1)),
  }))
  Assert.isTrue(reversedBetaOk, "reordered legal replies are accepted: " .. tostring(reversedBetaErr))
  Assert.isNil(reversedBetaErr, "accepted reordered replies carry no input error")
  local reopenedChoices = {}
  for _, actor in ipairs(reopenedAlpha.actors) do
    reopenedChoices[#reopenedChoices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(3))
  end
  local reversedAlphaOk, reversedAlphaErr = reversed:submit(SessionFixture.replyFor(reopenedAlpha, reopenedChoices))
  Assert.isTrue(reversedAlphaOk, "the delayed side still answers: " .. tostring(reversedAlphaErr))
  Assert.isNil(reversedAlphaErr, "accepted delayed replies carry no input error")
  local secondEvents = SessionFixture.driveToEnd(reversed, 64, function(request)
    local choices = {}
    for _, actor in ipairs(request.actors) do
      choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(3))
    end
    return choices
  end)
  reversed:dispose()

  Assert.deepEqual(firstEvents, secondEvents, "submission order never affects the outcome")
  Assert.isTrue(#firstEvents > 0, "the committed batches settle their strikes")
end

-- Both session paths open batches through one shared construction step:
-- the shared owner increments the batch counter, installs the pending
-- maps, groups active fighters by controller, and publishes one request
-- per controller.
function T.both_session_paths_open_batches_through_shared_construction()
  local BatchOwner =
    SessionFixture.requirePresent("libs.battle.src.DecisionBatch", "shared batch construction owns batch opening")
  Assert.isTrue(type(BatchOwner.prepare) == "function", "batch opening shares one counter and grouping step")
  Assert.isTrue(type(BatchOwner.publishRound) == "function", "batch opening shares one request publication step")
end

-- The generic and native doubles open the identical batch protocol: one
-- batch identity per opening, controllers grouped in participant and
-- roster order, one request per controller, empty reservations, and no
-- draws beyond the native pre-request order samples. Answering both
-- batches advances both counters together.
function T.generic_and_native_doubles_open_the_identical_batch_protocol()
  local contracts = SessionFixture.sessionContracts()
  local Lcrng = require("libs.mons.src.gen4.Lcrng")

  local generic = SessionFixture.newSession(contracts, SessionFixture.buildScenario(reserveDoubles()))
  local genericCallsBefore = generic:capture().rng.calls
  local genericOpening = SessionFixture.driveUntilSettled(generic, 64)
  Assert.equal(genericOpening.status, "waiting", "the generic doubles wait for both sides")
  local genericSettled = generic:capture()
  Assert.equal(genericSettled.batchCounter, 1, "the generic opening spends exactly one batch")
  Assert.equal(genericSettled.rng.calls, genericCallsBefore, "the generic opening draws nothing")
  Assert.isNil(genericSettled.pending.nativeOrderRolls, "the generic batch carries no order samples")
  Assert.deepEqual(
    genericSettled.pending.reserved,
    { replacements = {}, items = {} },
    "the generic opening starts with empty reservations"
  )
  local genericRequests = genericOpening.request.requests
  Assert.equal(#genericRequests, 2, "the generic opening asks each controller once")
  Assert.equal(genericRequests[1].controller, "alpha", "the generic publication follows roster order")
  Assert.equal(genericRequests[2].controller, "beta", "the generic publication follows roster order")
  Assert.isTrue(
    genericRequests[1].requestId < genericRequests[2].requestId,
    "the generic publication order matches the request order"
  )
  Assert.equal(genericRequests[1].kind, "action", "the generic request names its decision kind")
  Assert.equal(genericRequests[2].kind, "action", "the generic request names its decision kind")
  Assert.equal(genericOpening.request.epoch, 1, "the generic batch carries its first epoch")
  Assert.equal(#genericRequests[1].actors, 2, "the generic reply answers both leads together")
  Assert.equal(genericRequests[1].actors[1].combatant, 1, "the generic actors follow roster order")
  Assert.equal(genericRequests[1].actors[2].combatant, 2, "the generic actors follow roster order")
  Assert.equal(
    genericRequests[1].actors[1].activation,
    genericSettled.combatants[1].active.activation,
    "the generic actor carries its live entry token"
  )
  Assert.equal(
    genericRequests[1].actors[2].activation,
    genericSettled.combatants[2].active.activation,
    "the generic actor carries its live entry token"
  )
  Assert.equal(#genericRequests[2].actors, 1, "the opposing generic request addresses its lead")

  local native = contracts.Battle.newSession(sharedNativeDoublesScenario(), sharedNativeDoubleContent())
  local nativeCallsBefore = native:capture().rng.calls
  local nativeOpening = SessionFixture.driveUntilSettled(native, 64)
  Assert.equal(nativeOpening.status, "waiting", "the native doubles wait for both sides")
  local nativeSettled = native:capture()
  Assert.equal(nativeSettled.batchCounter, 1, "the native opening spends exactly one batch")
  Assert.equal(
    nativeSettled.rng.calls,
    nativeCallsBefore + 4,
    "the native opening spends exactly its four order samples"
  )
  local rolls = nativeSettled.pending.nativeOrderRolls
  Assert.notNil(rolls, "the native batch stores its pre-request order samples")
  assert(rolls ~= nil, "the order samples are observed before assertions")
  Assert.equal(#rolls, 4, "the native batch stores one sample per battler slot")
  local stream = Lcrng.new(SHARED_NATIVE_SEED)
  for _ = 1, nativeCallsBefore do
    stream:nextU16()
  end
  for position = 1, 4 do
    Assert.equal(
      rolls[position],
      stream:nextU16(),
      "the native samples replay from the batch-opening stream position in canonical slot order"
    )
  end
  Assert.deepEqual(
    nativeSettled.pending.reserved,
    { replacements = {}, items = {} },
    "the native opening starts with empty reservations"
  )
  local nativeRequests = nativeOpening.request.requests
  Assert.equal(#nativeRequests, 2, "the native opening asks each controller once")
  Assert.equal(nativeRequests[1].controller, "alpha", "the native publication follows roster order")
  Assert.equal(nativeRequests[2].controller, "beta", "the native publication follows roster order")
  Assert.isTrue(
    nativeRequests[1].requestId < nativeRequests[2].requestId,
    "the native publication order matches the request order"
  )
  Assert.equal(nativeRequests[1].kind, "action", "the native request names its decision kind")
  Assert.equal(nativeRequests[2].kind, "action", "the native request names its decision kind")
  Assert.equal(nativeOpening.request.epoch, 1, "the native batch carries its first epoch")
  Assert.equal(#nativeRequests[1].actors, 2, "the native reply answers both leads together")
  Assert.equal(nativeRequests[1].actors[1].combatant, 1, "the native actors follow roster order")
  Assert.equal(nativeRequests[1].actors[2].combatant, 2, "the native actors follow roster order")
  Assert.equal(#nativeRequests[2].actors, 2, "the opposing native request answers both leads together")
  Assert.equal(nativeRequests[2].actors[1].combatant, 3, "the opposing native actors follow roster order")
  Assert.equal(nativeRequests[2].actors[2].combatant, 4, "the opposing native actors follow roster order")

  local twice = contracts.Battle.newSession(sharedNativeDoublesScenario(), sharedNativeDoubleContent())
  local reopened = SessionFixture.driveUntilSettled(twice, 64)
  Assert.deepEqual(
    twice:capture().pending.nativeOrderRolls,
    rolls,
    "the identical seed replays the identical order samples"
  )
  twice:dispose()
  _ = reopened

  for _, request in ipairs(genericRequests) do
    local choices = {}
    for _, actor in ipairs(request.actors) do
      choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(3))
    end
    local ok, replyErr = generic:submit(SessionFixture.replyFor(request, choices))
    Assert.isTrue(ok, "the generic opening replies are accepted: " .. tostring(replyErr))
    Assert.isNil(replyErr, "accepted generic replies carry no input error")
  end
  for _, request in ipairs(nativeRequests) do
    local choices = {}
    for _, actor in ipairs(request.actors) do
      local target = 1
      if request.controller == "alpha" then
        target = 3
      end
      choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(target))
    end
    local ok, replyErr = native:submit(SessionFixture.replyFor(request, choices))
    Assert.isTrue(ok, "the native opening replies are accepted: " .. tostring(replyErr))
    Assert.isNil(replyErr, "accepted native replies carry no input error")
  end
  generic:advance(64)
  native:advance(64)
  Assert.equal(generic:capture().batchCounter, 2, "the answered generic batch advances its counter")
  Assert.equal(native:capture().batchCounter, 2, "the answered native batch advances its counter")
  local genericNext = SessionFixture.driveUntilSettled(generic, 64)
  local nativeNext = SessionFixture.driveUntilSettled(native, 64)
  Assert.equal(genericNext.request.epoch, 2, "the following generic batch carries the next epoch")
  Assert.equal(nativeNext.request.epoch, 2, "the following native batch carries the next epoch")
  generic:dispose()
  native:dispose()
end

return { tests = T }
