-- Battle medicine executes from generated semantic facts carried beside the
-- native session: fixed restoration reaches battle state through the
-- ordinary item path with both health mirrors, stock, ledger, and the
-- emitted event agreeing, while ineffective medicine is refused and
-- unmodeled families fail explicitly, all without consuming stock.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

local NATIVE_SEED = 0x1BADB002
local WILD_FORMAT = "wild-single"

---@return table loaded native session owner
local function executorOwner()
  return SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "the private native lifecycle owns HGSS ruleset sessions"
  )
end

---@return table frozen battle content binding the native ruleset over the wild format
local function actionContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = executorOwner()
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "native-item-facts-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "native-item-facts-tests"
  )
  behaviors:registerFormat(WILD_FORMAT, { key = WILD_FORMAT }, "native-item-facts-tests")
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
  for _, key in
    ipairs(formRecord.types --[[@as string[] ]])
  do
    types[#types + 1] = key --[[@as string]]
  end
  return types
end

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, table<integer, table<string, unknown>>> static species facts for the fixture combatants
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

---@param alpha table[] owning-side combatant seeds in scenario order
---@param beta table[] opposing-side combatant seeds in scenario order
---@param pack table battle inventory seed for the owning side
---@param itemFacts table<string, table<string, unknown>> detached semantic facts for the stocked items
---@return table detached native battle setup record carrying its item facts
local function itemScenario(alpha, beta, pack, itemFacts)
  local Executor = executorOwner()
  local seeds = {}
  for _, seed in ipairs(alpha) do
    seeds[#seeds + 1] = seed
  end
  for _, seed in ipairs(beta) do
    seeds[#seeds + 1] = seed
  end
  local alphaSpec = SessionFixture.participant(1, 1, "alpha", alpha)
  alphaSpec.inventoryId = (pack --[[@as table<string, unknown>]]).id
  local alphaLead = alpha[1] --[[@as table<string, unknown>]]
  local betaLead = beta[1] --[[@as table<string, unknown>]]
  return {
    ruleset = Executor.RULESET,
    format = WILD_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      alphaSpec,
      SessionFixture.participant(2, 2, "beta", beta),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, alphaLead.id --[[@as integer]]),
      SessionFixture.position(2, 2, { 2 }, betaLead.id --[[@as integer]]),
    },
    inventories = { pack },
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(),
    speciesFacts = scenarioSpeciesFacts(seeds),
    itemFacts = itemFacts,
  }
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

---@param target unknown event target under inspection
---@param holder integer combatant identity expected to receive the serving
---@return boolean true when the target names that combatant
local function targetsHolder(target, holder)
  if target == holder then
    return true
  end
  if type(target) == "table" then
    return (target --[[@as table<string, unknown>]]).combatant == holder
  end
  return false
end

---@param cures table<string, boolean> semantic cure flags for a medicine record
---@return table<string, unknown> detached generated-style medicine facts
local function medicineFacts(restore, cures)
  return {
    kind = "medicine",
    restore = restore,
    cures = cures,
    revive = "none",
    mood = 0,
  }
end

---@return table<string, boolean> medicine cure flags with nothing curable
local function noCures()
  return { sleep = false, poison = false, burn = false, freeze = false, paralysis = false }
end

-- A generated fixed restoration reaches battle state through the native
-- item path: the wounded holder recovers exactly the generated amount, both
-- health mirrors agree, one unit and one ledger delta are consumed, and the
-- emitted event names the holder with the actual restored delta.
function T.generated_fixed_restoration_reaches_battle_state()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  lead.mon.condition.currentHp = 1
  local pack = SessionFixture.inventory("party", { 1 }, { SUPER_POTION = 1 })
  local facts = {
    SUPER_POTION = { partyUse = medicineFacts({ kind = "fixed", amount = 50 }, noCures()) },
  }
  local session = contracts.Battle.newSession(
    itemScenario({ lead }, { leveledCombatant(2, 41, "EEVEE", 5), leveledCombatant(4, 43, "EEVEE", 5) }, pack, facts),
    content
  )
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local before = session:capture()
  local hpBefore = before.combatants[1].hp
  local maxHp = before.combatants[1].maxHp
  Assert.isTrue(type(maxHp) == "number", "the holder carries its health ceiling")
  Assert.isTrue(maxHp --[[@as integer]] - hpBefore >= 50, "the wound leaves room for the full fixed restoration")
  local callsBefore = before.rng.calls
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local ok, replyErr = session:submit(SessionFixture.replyFor(alpha, { bagChoice(actor, "SUPER_POTION", 1) }))
  Assert.isTrue(ok, "the fixed restoration choice is accepted")
  Assert.isNil(replyErr, "accepted bag use carries no input error")
  local answered, answerErr = session:submit(SessionFixture.replyFor(beta, { SessionFixture.switchChoice(foe, 4) }))
  Assert.isTrue(answered, "the opposing exchange is accepted")
  Assert.isNil(answerErr, "accepted exchanges carry no input error")
  local turn = session:advance(64)
  local served = nil
  for _, event in ipairs(turn.events or {}) do
    if event.kind == "item" then
      served = event
    end
  end
  Assert.notNil(served, "the bag use announces itself")
  local payload = served.payload --[[@as table<string, unknown>]]
  Assert.equal(payload.item, "SUPER_POTION", "the event names the served item")
  Assert.equal(payload.inventory, "party", "the event names the owning stock")
  local settled = session:capture()
  local gained = settled.combatants[1].hp - hpBefore
  Assert.equal(gained, 50, "the holder recovers the generated fixed amount, gained " .. gained)
  Assert.equal(
    settled.combatants[1].hp,
    math.min(maxHp --[[@as integer]], hpBefore + 50),
    "recovery respects the health ceiling"
  )
  Assert.equal(
    settled.combatants[1].mon.condition.currentHp,
    settled.combatants[1].hp,
    "both health mirrors agree after the serving"
  )
  Assert.equal(settled.inventories.party.quantities.SUPER_POTION, 0, "exactly one unit leaves the stock")
  Assert.equal(#settled.ledger, 1, "the serving writes exactly one ledger delta")
  local delta = settled.ledger[1]
  Assert.equal(delta.inventoryId, "party", "the delta names its inventory owner")
  Assert.equal(delta.item, "SUPER_POTION", "the delta names its item")
  Assert.equal(delta.delta, -1, "the delta consumes exactly one unit")
  Assert.equal(payload.restored, gained, "the event reports the actual restored delta")
  Assert.isTrue(targetsHolder(payload.target, 1), "the event names the served holder")
  -- The serving draws nothing itself; the four draws are the following
  -- batch samples, already spent while it waits for decisions.
  Assert.equal(settled.rng.calls, callsBefore + 4, "deterministic bag use draws nothing")
  session:dispose()
end

-- Ineffective medicine and unmodeled families never masquerade as healing:
-- full-health medicine plans its refusal with no mutation, and a
-- power-point family fails explicitly with no mutation.
function T.ineffective_and_unsupported_semantics_never_heal()
  local ItemUse = SessionFixture.requirePresent(
    "libs.battle.src.gen4.ItemUse",
    "battle bag planning owns selection without consuming"
  )
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local facts = {
    POTION = { partyUse = medicineFacts({ kind = "fixed", amount = 20 }, noCures()) },
    ETHER = { partyUse = { kind = "pp", target = "one", restore = 10, mood = 0 } },
  }
  local rng = BattleRng.new(3)
  local callsBefore = rng:capture().calls

  local fullView = {
    inventories = { party = { quantities = { POTION = 1, ETHER = 1 }, revision = 0 } },
    outstanding = {},
    combatants = { [1] = { hp = 30, maxHp = 30 } },
  }
  local fullChoice = { inventoryId = "party", item = "POTION", target = { kind = "combatant", combatant = 1 } }
  local refused = ItemUse.plan(fullChoice, fullView, facts)
  Assert.equal(
    refused.failureReason,
    "no_effect",
    "full-health medicine plans its refusal, got " .. tostring(refused.failureReason)
  )
  Assert.isTrue(refused.executed ~= true, "refused plans carry no execution stamp")
  local fullBattle = {
    inventories = { party = { quantities = { POTION = 1, ETHER = 1 }, revision = 0 } },
    ledger = {},
    combatants = { [1] = { hp = 30, maxHp = 30 } },
  }
  local refuseOk, refuseErr = pcall(ItemUse.execute, refused, fullBattle, rng)
  Assert.isFalse(refuseOk, "executing a refused plan raises its typed failure")
  Assert.equal((refuseErr --[[@as table<string, unknown>]]).code, "no_effect", "the refusal names its reason")
  Assert.deepEqual(fullBattle.ledger, {}, "refused executions write no ledger")
  Assert.equal(fullBattle.inventories.party.quantities.POTION, 1, "refused executions consume nothing")
  Assert.equal(fullBattle.combatants[1].hp, 30, "refused executions heal nothing")
  Assert.equal(rng:capture().calls, callsBefore, "refused executions draw nothing")

  local hurtView = {
    inventories = { party = { quantities = { POTION = 1, ETHER = 1 }, revision = 0 } },
    outstanding = {},
    combatants = { [1] = { hp = 10, maxHp = 30 } },
  }
  local strangeChoice = { inventoryId = "party", item = "ETHER", target = { kind = "combatant", combatant = 1 } }
  local hurtBattle = {
    inventories = { party = { quantities = { POTION = 1, ETHER = 1 }, revision = 0 } },
    ledger = {},
    combatants = { [1] = { hp = 10, maxHp = 30 } },
  }
  local planOk, planOrErr = pcall(ItemUse.plan, strangeChoice, hurtView, facts)
  local failure = nil
  if planOk then
    local plan = planOrErr --[[@as table<string, unknown>]]
    Assert.isNil(plan.failureReason, "unmodeled semantics never downgrade to a refusal")
    local execOk, execErr = pcall(ItemUse.execute, plan, hurtBattle, rng)
    Assert.isFalse(execOk, "unmodeled semantics fail instead of healing")
    failure = execErr
    Assert.isTrue(plan.executed ~= true, "failed plans carry no execution stamp")
  else
    failure = planOrErr
  end
  Assert.equal(
    (failure --[[@as table<string, unknown>]]).code,
    "BATTLE_MISSING_BEHAVIOR",
    "unmodeled semantics report the missing behavior"
  )
  Assert.deepEqual(hurtBattle.ledger, {}, "failed executions write no ledger")
  Assert.equal(hurtBattle.inventories.party.quantities.ETHER, 1, "failed executions consume nothing")
  Assert.equal(hurtBattle.combatants[1].hp, 10, "failed executions heal nothing")
  Assert.equal(rng:capture().calls, callsBefore, "failed executions draw nothing")
end

-- A generated battle-use serving raises its stage through the native
-- item path: one X-item unit leaves the stock with one ledger delta,
-- the holder gains exactly one attack stage, and the emitted event
-- names the serving.
function T.generated_battle_use_raises_its_stage_through_the_session()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  local pack = SessionFixture.inventory("party", { 1 }, { X_ATTACK = 1 })
  local facts = {
    X_ATTACK = {
      partyUse = { kind = "deferred", reason = "battle_only" },
      battleUse = {
        cures = { confusion = false, infatuation = false },
        guardSpec = false,
        stages = {
          attack = 1,
          defense = 0,
          specialAttack = 0,
          specialDefense = 0,
          speed = 0,
          accuracy = 0,
          critical = 0,
        },
      },
    },
  }
  local session = contracts.Battle.newSession(
    itemScenario({ lead }, { leveledCombatant(2, 41, "EEVEE", 5), leveledCombatant(4, 43, "EEVEE", 5) }, pack, facts),
    content
  )
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local ok, replyErr = session:submit(SessionFixture.replyFor(alpha, { bagChoice(actor, "X_ATTACK", 1) }))
  Assert.isTrue(ok, "the battle-use choice is accepted")
  Assert.isNil(replyErr, "accepted bag use carries no input error")
  local answered, answerErr = session:submit(SessionFixture.replyFor(beta, { SessionFixture.switchChoice(foe, 4) }))
  Assert.isTrue(answered, "the opposing exchange is accepted")
  Assert.isNil(answerErr, "accepted exchanges carry no input error")
  local turn = session:advance(64)
  local served = nil
  for _, event in ipairs(turn.events or {}) do
    if event.kind == "item" then
      served = event
    end
  end
  Assert.notNil(served, "the bag use announces itself")
  local payload = served.payload --[[@as table<string, unknown>]]
  Assert.equal(payload.item, "X_ATTACK", "the event names the served item")
  local settled = session:capture()
  Assert.equal(settled.combatants[1].stages.attack, 1, "the holder gains one attack stage")
  Assert.equal(settled.inventories.party.quantities.X_ATTACK, 0, "exactly one unit leaves the stock")
  Assert.equal(#settled.ledger, 1, "the serving writes exactly one ledger delta")
  session:dispose()
end

---@return table<string, table<string, unknown>> immutable battle-use facts for a focusing serving
local function focusServingFacts()
  return {
    DIRE_HIT = {
      partyUse = { kind = "deferred", reason = "battle_only" },
      battleUse = {
        cures = { confusion = false, infatuation = false },
        guardSpec = false,
        stages = {
          attack = 0,
          defense = 0,
          specialAttack = 0,
          specialDefense = 0,
          speed = 0,
          accuracy = 0,
          critical = 1,
        },
      },
    },
  }
end

---@return table<string, table<string, unknown>> immutable battle-use facts for a screening serving
local function guardServingFacts()
  return {
    GUARD_SPEC = {
      partyUse = { kind = "deferred", reason = "battle_only" },
      battleUse = {
        cures = { confusion = false, infatuation = false },
        guardSpec = true,
        stages = {
          attack = 0,
          defense = 0,
          specialAttack = 0,
          specialDefense = 0,
          speed = 0,
          accuracy = 0,
          critical = 0,
        },
      },
    },
  }
end

---@param events table[] emitted turn events under inspection
---@return table the served bag-use event
local function servedItemEvent(events)
  for _, event in ipairs(events) do
    if event.kind == "item" then
      return event
    end
  end
  error("the bag use announces itself")
end

-- A second focusing serving in the same stay refuses at commit: the first
-- use consumes once and focuses, the repeat announces its refusal while
-- stock, ledger, and the battle stream stay exactly as they were.
function T.repeated_focusing_servings_refuse_at_commit()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  local pack = SessionFixture.inventory("party", { 1 }, { DIRE_HIT = 2 })
  local session = contracts.Battle.newSession(
    itemScenario(
      { lead },
      { leveledCombatant(2, 41, "EEVEE", 5), leveledCombatant(4, 43, "EEVEE", 5) },
      pack,
      focusServingFacts()
    ),
    content
  )
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local ok, replyErr = session:submit(SessionFixture.replyFor(alpha, { bagChoice(actor, "DIRE_HIT", 1) }))
  Assert.isTrue(ok, "the first focusing choice is accepted")
  Assert.isNil(replyErr, "accepted bag use carries no input error")
  local answered, answerErr = session:submit(SessionFixture.replyFor(beta, { SessionFixture.switchChoice(foe, 4) }))
  Assert.isTrue(answered, "the opposing exchange is accepted")
  Assert.isNil(answerErr, "accepted exchanges carry no input error")
  local first = session:advance(64)
  local served = servedItemEvent(first.events or {})
  local servedPayload = served.payload --[[@as table<string, unknown>]]
  Assert.equal(servedPayload.item, "DIRE_HIT", "the event names the served item")
  Assert.isNil(servedPayload.refused, "the first focusing serving is not refused")
  local afterFirst = session:capture()
  Assert.equal(afterFirst.inventories.party.quantities.DIRE_HIT, 1, "the first serving spends one unit")
  Assert.equal(#afterFirst.ledger, 1, "the first serving writes one ledger delta")

  local repeat_turn = SessionFixture.driveUntilSettled(session)
  Assert.equal(repeat_turn.status, "waiting", "the next turn asks for decisions")
  local alphaAgain = requestFor(repeat_turn, "alpha")
  local betaAgain = requestFor(repeat_turn, "beta")
  local actorAgain = assert(alphaAgain.actors[1], "the owning request addresses its lead again")
  local foeAgain = assert(betaAgain.actors[1], "the opposing request addresses its lead again")
  local okAgain, replyErrAgain =
    session:submit(SessionFixture.replyFor(alphaAgain, { bagChoice(actorAgain, "DIRE_HIT", 1) }))
  Assert.isTrue(okAgain, "the repeated focusing choice is accepted")
  Assert.isNil(replyErrAgain, "accepted bag use carries no input error")
  local answeredAgain, answerErrAgain =
    session:submit(SessionFixture.replyFor(betaAgain, { SessionFixture.switchChoice(foeAgain, 2) }))
  Assert.isTrue(answeredAgain, "the opposing exchange back is accepted")
  Assert.isNil(answerErrAgain, "accepted exchanges carry no input error")
  local beforeRepeat = session:capture()
  local second = session:advance(64)
  local refused = servedItemEvent(second.events or {})
  local refusedPayload = refused.payload --[[@as table<string, unknown>]]
  Assert.equal(refusedPayload.item, "DIRE_HIT", "the refusal names the served item")
  Assert.equal(refusedPayload.refused, "no_effect", "the repeat announces it had no effect")
  local settled = session:capture()
  Assert.equal(settled.inventories.party.quantities.DIRE_HIT, 1, "the refused repeat consumes nothing")
  Assert.equal(#settled.ledger, 1, "the refused repeat writes no ledger delta")
  -- The refused repeat draws nothing itself; the four draws are the
  -- following batch samples, already spent while it waits.
  Assert.equal(settled.rng.calls, beforeRepeat.rng.calls + 4, "the refused repeat draws nothing")
  session:dispose()
end

-- A second screening serving while mist stands refuses at commit with the
-- same no-mutation guarantees as the focusing repeat.
function T.repeated_screening_servings_refuse_at_commit()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  local pack = SessionFixture.inventory("party", { 1 }, { GUARD_SPEC = 2 })
  local session = contracts.Battle.newSession(
    itemScenario(
      { lead },
      { leveledCombatant(2, 41, "EEVEE", 5), leveledCombatant(4, 43, "EEVEE", 5) },
      pack,
      guardServingFacts()
    ),
    content
  )
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local ok, replyErr = session:submit(SessionFixture.replyFor(alpha, { bagChoice(actor, "GUARD_SPEC", 1) }))
  Assert.isTrue(ok, "the first screening choice is accepted")
  Assert.isNil(replyErr, "accepted bag use carries no input error")
  local answered, answerErr = session:submit(SessionFixture.replyFor(beta, { SessionFixture.switchChoice(foe, 4) }))
  Assert.isTrue(answered, "the opposing exchange is accepted")
  Assert.isNil(answerErr, "accepted exchanges carry no input error")
  local first = session:advance(64)
  local served = servedItemEvent(first.events or {})
  local servedPayload = served.payload --[[@as table<string, unknown>]]
  Assert.equal(servedPayload.item, "GUARD_SPEC", "the event names the served item")
  Assert.isNil(servedPayload.refused, "the first screening serving is not refused")
  local afterFirst = session:capture()
  Assert.equal(afterFirst.inventories.party.quantities.GUARD_SPEC, 1, "the first serving spends one unit")
  Assert.equal(#afterFirst.ledger, 1, "the first serving writes one ledger delta")

  local repeat_turn = SessionFixture.driveUntilSettled(session)
  Assert.equal(repeat_turn.status, "waiting", "the next turn asks for decisions")
  local alphaAgain = requestFor(repeat_turn, "alpha")
  local betaAgain = requestFor(repeat_turn, "beta")
  local actorAgain = assert(alphaAgain.actors[1], "the owning request addresses its lead again")
  local foeAgain = assert(betaAgain.actors[1], "the opposing request addresses its lead again")
  local okAgain, replyErrAgain =
    session:submit(SessionFixture.replyFor(alphaAgain, { bagChoice(actorAgain, "GUARD_SPEC", 1) }))
  Assert.isTrue(okAgain, "the repeated screening choice is accepted")
  Assert.isNil(replyErrAgain, "accepted bag use carries no input error")
  local answeredAgain, answerErrAgain =
    session:submit(SessionFixture.replyFor(betaAgain, { SessionFixture.switchChoice(foeAgain, 2) }))
  Assert.isTrue(answeredAgain, "the opposing exchange back is accepted")
  Assert.isNil(answerErrAgain, "accepted exchanges carry no input error")
  local beforeRepeat = session:capture()
  local second = session:advance(64)
  local refused = servedItemEvent(second.events or {})
  local refusedPayload = refused.payload --[[@as table<string, unknown>]]
  Assert.equal(refusedPayload.item, "GUARD_SPEC", "the refusal names the served item")
  Assert.equal(refusedPayload.refused, "no_effect", "the repeat announces it had no effect")
  local settled = session:capture()
  Assert.equal(settled.inventories.party.quantities.GUARD_SPEC, 1, "the refused repeat consumes nothing")
  Assert.equal(#settled.ledger, 1, "the refused repeat writes no ledger delta")
  -- The refused repeat draws nothing itself; the four draws are the
  -- following batch samples, already spent while it waits.
  Assert.equal(settled.rng.calls, beforeRepeat.rng.calls + 4, "the refused repeat draws nothing")
  session:dispose()
end


---@param actorOptions table<string, unknown> one actor's projected options under search
---@param item string item key under search
---@param holder integer combatant receiving the serving
---@return table<integer, table<string, unknown>> item options by zero-based move slot
local function itemOptionsBySlot(actorOptions, item, holder)
  local found = {}
  for _, option in
    ipairs(actorOptions.choices --[[@as table<integer, table<string, unknown>>]])
  do
    local choice = option.choice --[[@as table<string, unknown>]]
    local payload = choice.payload --[[@as table<string, unknown>]]
    if choice.kind == "item" and payload.item == item and targetsHolder(payload.target, holder) then
      Assert.isTrue(type(payload.moveSlot) == "number", "one-move PP options name their move slot")
      found[payload.moveSlot --[[@as integer]]] = option
    end
  end
  return found
end

-- A one-move PP serving is chosen per move slot like the native Restore
-- PP page: each held move projects its own option, a full move refuses
-- with no effect, a choice naming no move is refused at submission, and
-- the chosen move recovers the generated amount through the item path.
function T.one_move_pp_servings_select_their_move()
  local Executor = executorOwner()
  local content = actionContent()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  lead.mon.moves = { { move = "TACKLE", pp = 5, ppUps = 0 }, { move = "GROWL", pp = 40, ppUps = 0 } }
  local pack = SessionFixture.inventory("party", { 1 }, { ETHER = 1 })
  local facts = { ETHER = { partyUse = { kind = "pp", target = "one", restore = 10, mood = 0 } } }
  local scenario =
    itemScenario({ lead }, { leveledCombatant(2, 41, "EEVEE", 5), leveledCombatant(4, 43, "EEVEE", 5) }, pack, facts)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  scenario.moveFacts.GROWL = CatalogFixture.makeCatalog():move("GROWL")
  local session = Executor.new(scenario, content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local options = session:decisionOptions(alpha.requestId)
  local bySlot = itemOptionsBySlot(options.actors[1], "ETHER", 1)
  Assert.isTrue(bySlot[0] ~= nil and bySlot[0].enabled == true, "the spent move offers its restoration")
  Assert.isTrue(bySlot[1] ~= nil and bySlot[1].enabled == false, "the full move refuses its restoration")
  Assert.equal(bySlot[1].reason, "no_effect", "the full move explains it would have no effect")

  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  local unslotted, unslottedErr = session:submit(SessionFixture.replyFor(alpha, { bagChoice(actor, "ETHER", 1) }))
  Assert.isFalse(unslotted, "a one-move PP serving naming no move is refused")
  Assert.notNil(unslottedErr, "the refusal carries its input error")

  local unheld = bagChoice(actor, "ETHER", 1)
  unheld.payload.moveSlot = 2
  Assert.isFalse(
    session:submit(SessionFixture.replyFor(alpha, { unheld })),
    "a move slot the holder does not hold is refused"
  )

  local ok, replyErr = session:submit(SessionFixture.replyFor(alpha, { bySlot[0].choice }))
  Assert.isTrue(ok, "the slotted restoration is accepted")
  Assert.isNil(replyErr, "accepted bag use carries no input error")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(beta, { SessionFixture.switchChoice(foe, 4) })),
    "the opposing exchange is accepted"
  )
  local turn = session:advance(64)
  local served = servedItemEvent(turn.events or {})
  local payload = served.payload --[[@as table<string, unknown>]]
  Assert.equal(payload.restoredPp, 10, "the event reports the restored PP")
  local settled = session:capture()
  Assert.equal(settled.combatants[1].mon.moves[1].pp, 15, "the chosen move recovers the generated amount")
  Assert.equal(settled.combatants[1].mon.moves[2].pp, 40, "the other move is untouched")
  Assert.equal(settled.inventories.party.quantities.ETHER, 0, "exactly one unit leaves the stock")
  session:dispose()
end

-- Retail TryUseItem embargo (battle_bag_menu.c msg 46): servings from an
-- embargoed holder refuse with the embargo reason while Guard Spec and
-- escape dolls (battleUseFunc 3) stay selectable. The embargo lands
-- through the real EMBARGO strike, so the gate reads the live effect
-- bag like execution does.
function T.embargoed_servings_refuse_with_embargo_reason()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  lead.mon.condition.currentHp = 1
  local foe = leveledCombatant(2, 41, "EEVEE", 20)
  foe.mon.moves = { { move = "EMBARGO", pp = 15, ppUps = 0 }, { move = "GROWL", pp = 40, ppUps = 0 } }
  local pack = SessionFixture.inventory("party", { 1 }, { POTION = 1, GUARD_SPEC = 1 })
  local facts = {
    POTION = { partyUse = medicineFacts({ kind = "fixed", amount = 20 }, noCures()), battleUseFunc = 2 },
    GUARD_SPEC = guardServingFacts().GUARD_SPEC,
  }
  local scenario =
    itemScenario({ lead }, { foe, leveledCombatant(4, 43, "EEVEE", 5) }, pack, facts)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  scenario.moveFacts.GROWL = catalog:move("GROWL")
  local embargoFacts = {}
  for key, value in pairs(scenario.moveFacts.GROWL) do
    embargoFacts[key] = value
  end
  scenario.moveFacts.EMBARGO = embargoFacts
  local session = contracts.Battle.newSession(scenario, content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  local foeActor = assert(beta.actors[1], "the opposing request addresses its lead")
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(alpha, {
      SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)),
    })),
    "the opening strike is accepted"
  )
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(beta, {
      SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(1)),
    })),
    "the embargo strike is accepted"
  )
  local nextFrame = SessionFixture.driveUntilSettled(session)
  Assert.equal(nextFrame.status, "waiting", "the embargoed turn asks for decisions")
  local embargoed = requestFor(nextFrame, "alpha")
  local options = session:decisionOptions(embargoed.requestId)
  local actorOptions = assert(options.actors[1], "the embargoed request addresses its lead")
  local potionOption, guardOption = nil, nil
  for _, option in ipairs(actorOptions.choices) do
    local choice = option.choice --[[@as table<string, unknown>]]
    local payload = choice.payload --[[@as table<string, unknown>]]
    if choice.kind == "item" and targetsHolder(payload.target, 1) then
      if payload.item == "POTION" then
        potionOption = option
      elseif payload.item == "GUARD_SPEC" then
        guardOption = option
      end
    end
  end
  Assert.notNil(potionOption, "the embargoed holder still lists its serving")
  Assert.isFalse(potionOption.enabled == true, "the embargoed serving stays disabled")
  Assert.equal(potionOption.reason, "embargo", "the embargoed serving names its gate")
  Assert.notNil(guardOption, "guard spec still lists under embargo")
  Assert.isTrue(guardOption.enabled == true, "the embargo exception stays selectable")
  local refused, replyErr = session:submit(SessionFixture.replyFor(embargoed, { bagChoice(actor, "POTION", 1) }))
  Assert.isFalse(refused, "the embargoed serving is refused at submission")
  Assert.notNil(replyErr, "the refusal carries its input error")
  session:dispose()
end

-- Retail TryUseItem trainer escapes (battle_bag_menu.c battleUseFunc 3,
-- msg bank 0040 id 37): escape dolls refuse in trainer battles with the
-- stealing reason and stay usable in the wild.
function T.trainer_escape_dolls_refuse_with_stealing_reason()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local facts = {
    POKE_DOLL = { partyUse = { kind = "none" }, pocket = "items", battleUseFunc = 3 },
  }
  local function dollScenario(kind)
    local scenario = itemScenario(
      { leveledCombatant(1, 23, "EEVEE", 20) },
      { leveledCombatant(2, 41, "EEVEE", 5), leveledCombatant(4, 43, "EEVEE", 5) },
      SessionFixture.inventory("party", { 1 }, { POKE_DOLL = 1 }),
      facts
    )
    scenario.kind = kind
    return scenario
  end
  local wild = contracts.Battle.newSession(dollScenario(nil), content)
  local wildFrame = SessionFixture.driveUntilSettled(wild)
  local wildRequest = requestFor(wildFrame, "alpha")
  local wildOptions = wild:decisionOptions(wildRequest.requestId)
  local wildReason = nil
  for _, option in ipairs(wildOptions.actors[1].choices) do
    local choice = option.choice --[[@as table<string, unknown>]]
    local payload = choice.payload --[[@as table<string, unknown>]]
    if choice.kind == "item" and payload.item == "POKE_DOLL" then
      wildReason = option.enabled == true and "enabled" or option.reason
      break
    end
  end
  Assert.isTrue(wildReason ~= "no_stealing", "the wild doll never reports the trainer gate")
  wild:dispose()
  local trainer = contracts.Battle.newSession(dollScenario("trainer"), content)
  local trainerFrame = SessionFixture.driveUntilSettled(trainer)
  local trainerRequest = requestFor(trainerFrame, "alpha")
  local trainerOptions = trainer:decisionOptions(trainerRequest.requestId)
  local dollOption = nil
  for _, option in ipairs(trainerOptions.actors[1].choices) do
    local choice = option.choice --[[@as table<string, unknown>]]
    local payload = choice.payload --[[@as table<string, unknown>]]
    if choice.kind == "item" and payload.item == "POKE_DOLL" then
      dollOption = option
      break
    end
  end
  Assert.notNil(dollOption, "the trainer battle lists the stocked doll")
  Assert.isFalse(dollOption.enabled == true, "the trainer doll stays disabled")
  Assert.equal(dollOption.reason, "no_stealing", "the trainer doll names its gate")
  local actor = assert(trainerRequest.actors[1], "the trainer request addresses its lead")
  local refused, replyErr =
    trainer:submit(SessionFixture.replyFor(trainerRequest, { bagChoice(actor, "POKE_DOLL", 2) }))
  Assert.isFalse(refused, "the trainer doll is refused at submission")
  Assert.notNil(replyErr, "the refusal carries its input error")
  trainer:dispose()
end

-- Retail TryUseItem doubles aim (battle_bag_menu.c msg 44): balls refuse
-- while both foes stand, regardless of per-foe cover.
function T.doubled_foes_refuse_balls_with_doubles_reason()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local lead = leveledCombatant(1, 11, "EEVEE", 20)
  local ally = leveledCombatant(3, 31, "EEVEE", 20)
  local foeLead = leveledCombatant(2, 23, "EEVEE", 20)
  local foeAlly = leveledCombatant(4, 41, "EEVEE", 20)
  local seeds = { lead, ally, foeLead, foeAlly }
  local pack = SessionFixture.inventory("party", { 1 }, { POKE_BALL = 2 })
  local player = SessionFixture.participant(1, 1, "alpha", { lead, ally })
  player.inventoryId = pack.id
  local scenario = {
    ruleset = executorOwner().RULESET,
    format = "doubles",
    kind = "trainer",
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = { player, SessionFixture.participant(2, 2, "beta", { foeLead, foeAlly }) },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 1, { 1 }, 3),
      SessionFixture.position(3, 2, { 2 }, 2),
      SessionFixture.position(4, 2, { 2 }, 4),
    },
    inventories = { pack },
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(),
    speciesFacts = scenarioSpeciesFacts(seeds),
    itemFacts = {},
  }
  local session = contracts.Battle.newSession(scenario, content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the doubles opener asks for decisions")
  local alpha = requestFor(opening, "alpha")
  local options = session:decisionOptions(alpha.requestId)
  local balls = 0
  for _, actorOptions in ipairs(options.actors) do
    for _, option in ipairs(actorOptions.choices) do
      local choice = option.choice --[[@as table<string, unknown>]]
      local payload = choice.payload --[[@as table<string, unknown>]]
      if choice.kind == "item" and payload.item == "POKE_BALL" then
        balls = balls + 1
        Assert.isFalse(option.enabled == true, "doubled throws stay disabled")
        Assert.equal(option.reason, "no_aim_doubles", "doubled throws name the aim gate")
      end
    end
  end
  Assert.isTrue(balls > 0, "the doubles battle lists its stocked balls")
  session:dispose()
end

-- Retail TryUseItem PC room (battle_bag_menu.c msg 45): balls refuse only
-- while the party is full and every PC box is full. Box room rides the
-- scenario from the live storage owner; absent box facts keep offering.
function T.full_party_and_boxes_refuse_balls_with_room_reason()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local function fullAlpha()
    local seeds = {}
    for index = 0, 5 do
      seeds[#seeds + 1] = leveledCombatant(1 + index * 2, 11 + index, "EEVEE", 20)
    end
    return seeds
  end
  local function roomScenario(boxHasSpace)
    local alpha = fullAlpha()
    local scenario = itemScenario(
      alpha,
      { leveledCombatant(2, 41, "EEVEE", 5), leveledCombatant(4, 43, "EEVEE", 5) },
      SessionFixture.inventory("party", { 1 }, { POKE_BALL = 1 }),
      {}
    )
    if boxHasSpace ~= nil then
      scenario.boxHasSpace = boxHasSpace
    end
    return scenario
  end
  local offered = contracts.Battle.newSession(roomScenario(nil), content)
  local offeredFrame = SessionFixture.driveUntilSettled(offered)
  local offeredRequest = requestFor(offeredFrame, "alpha")
  local offeredOptions = offered:decisionOptions(offeredRequest.requestId)
  local offeredBall = nil
  for _, option in ipairs(offeredOptions.actors[1].choices) do
    local choice = option.choice --[[@as table<string, unknown>]]
    local payload = choice.payload --[[@as table<string, unknown>]]
    if choice.kind == "item" and payload.item == "POKE_BALL" then
      offeredBall = option
      break
    end
  end
  Assert.notNil(offeredBall, "the full party still lists its stocked ball")
  Assert.isTrue(offeredBall.enabled == true, "absent box facts keep offering the throw")
  offered:dispose()
  local refused = contracts.Battle.newSession(roomScenario(false), content)
  local refusedFrame = SessionFixture.driveUntilSettled(refused)
  local refusedRequest = requestFor(refusedFrame, "alpha")
  local refusedOptions = refused:decisionOptions(refusedRequest.requestId)
  local refusedBall = nil
  for _, option in ipairs(refusedOptions.actors[1].choices) do
    local choice = option.choice --[[@as table<string, unknown>]]
    local payload = choice.payload --[[@as table<string, unknown>]]
    if choice.kind == "item" and payload.item == "POKE_BALL" then
      refusedBall = option
      break
    end
  end
  Assert.notNil(refusedBall, "the boxed-in party still lists its stocked ball")
  Assert.isFalse(refusedBall.enabled == true, "the boxed-in throw stays disabled")
  Assert.equal(refusedBall.reason, "no_room", "the boxed-in throw names its gate")
  refused:dispose()
end

-- Retail TryUseItem hidden-foe aim (battle_bag_menu.c msgs 47-48): balls
-- refuse while the lone foe rides its semi-invulnerable charge or hides
-- behind a substitute. Both covers land through the real strikes, so the
-- gates read live battle state like the select-item packet does.
function T.hidden_foes_refuse_balls_with_hidden_reasons()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local function coverScenario(coverMove)
    local lead = leveledCombatant(1, 23, "EEVEE", 20)
    -- The opener only lowers attack: a damaging strike would shatter the
    -- fresh cover the same turn it lands.
    lead.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 }, { move = "GROWL", pp = 40, ppUps = 0 } }
    local foe = leveledCombatant(2, 41, "EEVEE", 20)
    foe.mon.moves = { { move = coverMove, pp = 15, ppUps = 0 } }
    local scenario = itemScenario(
      { lead },
      { foe, leveledCombatant(4, 43, "EEVEE", 5) },
      SessionFixture.inventory("party", { 1 }, { POKE_BALL = 1 }),
      {}
    )
    scenario.moveFacts[coverMove] = catalog:move("GROWL")
    scenario.moveFacts.GROWL = catalog:move("GROWL")
    return scenario
  end
  local function ballReason(scenario, coverSlot)
    local session = contracts.Battle.newSession(scenario, content)
    local opening = SessionFixture.driveUntilSettled(session)
    local alpha = requestFor(opening, "alpha")
    local beta = requestFor(opening, "beta")
    local actor = assert(alpha.actors[1], "the owning request addresses its lead")
    local foeActor = assert(beta.actors[1], "the opposing request addresses its lead")
    Assert.isTrue(
      session:submit(SessionFixture.replyFor(alpha, {
        SessionFixture.attackChoice(actor, 1, SessionFixture.positionTarget(2)),
      })),
      "the opening growl is accepted"
    )
    Assert.isTrue(
      session:submit(SessionFixture.replyFor(beta, {
        SessionFixture.attackChoice(foeActor, coverSlot, SessionFixture.positionTarget(1)),
      })),
      "the cover move is accepted"
    )
    local nextFrame = SessionFixture.driveUntilSettled(session)
    Assert.equal(nextFrame.status, "waiting", "the covered turn asks for decisions")
    local covered = requestFor(nextFrame, "alpha")
    local options = session:decisionOptions(covered.requestId)
    local reason = nil
    for _, option in ipairs(options.actors[1].choices) do
      local choice = option.choice --[[@as table<string, unknown>]]
      local payload = choice.payload --[[@as table<string, unknown>]]
      if choice.kind == "item" and payload.item == "POKE_BALL" then
        reason = option.enabled == true and "enabled" or option.reason
        break
      end
    end
    session:dispose()
    return reason
  end
  local subReason = ballReason(coverScenario("SUBSTITUTE"), 0)
  Assert.equal(subReason, "no_aim_hidden_foe", "the substitute hides the foe, got " .. tostring(subReason))
  local flyReason = ballReason(coverScenario("FLY"), 0)
  Assert.equal(flyReason, "no_aim_hidden", "the semi-invulnerable charge hides the foe, got " .. tostring(flyReason))
end

-- Retail escape dolls (battle_controller_player.c ~1747,
-- BATTLE_SUBSCRIPT_ESCAPE_ITEM): wild use consumes one unit and flees
-- outright with the fled event carrying the item for the
-- fled-with-item narration. Trainer use stays refused at submission.
function T.wild_escape_dolls_consume_and_flee()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local facts = {
    POKE_DOLL = { partyUse = { kind = "none" }, pocket = "items", battleUseFunc = 3 },
  }
  local scenario = itemScenario(
    { leveledCombatant(1, 23, "EEVEE", 20) },
    { leveledCombatant(2, 41, "EEVEE", 5), leveledCombatant(4, 43, "EEVEE", 5) },
    SessionFixture.inventory("party", { 1 }, { POKE_DOLL = 1 }),
    facts
  )
  local session = contracts.Battle.newSession(scenario, content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local alpha = requestFor(opening, "alpha")
  local options = session:decisionOptions(alpha.requestId)
  local dollOption = nil
  for _, option in ipairs(options.actors[1].choices) do
    local choice = option.choice --[[@as table<string, unknown>]]
    local payload = choice.payload --[[@as table<string, unknown>]]
    if choice.kind == "item" and payload.item == "POKE_DOLL" then
      dollOption = option
      break
    end
  end
  Assert.notNil(dollOption, "the wild battle lists its stocked doll")
  Assert.isTrue(dollOption.enabled == true, "the wild doll stays selectable")
  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(alpha, { bagChoice(actor, "POKE_DOLL", 1) })),
    "the wild doll seals"
  )
  local beta = requestFor(opening, "beta")
  local foeActor = assert(beta.actors[1], "the opposing request addresses its lead")
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(beta, {
      SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(1)),
    })),
    "the opposing strike is accepted"
  )
  local turn = session:advance(64)
  local fled = nil
  for _, event in ipairs(turn.events or {}) do
    if event.kind == "flee" then
      fled = event
    end
  end
  Assert.notNil(fled, "the doll announces its flight")
  local payload = fled.payload --[[@as table<string, unknown>]]
  Assert.isTrue(payload.escaped == true, "the doll flees outright")
  local source = payload.escapeSource --[[@as table<string, unknown>]]
  Assert.notNil(source, "the flight carries its item source for the fled-with-item narration")
  Assert.equal(source.kind, "item", "the flight names its item source")
  Assert.equal(source.key, "POKE_DOLL", "the flight names the consumed doll")
  local settled = session:capture()
  Assert.equal(settled.inventories.party.quantities.POKE_DOLL, 0, "exactly one doll leaves the stock")
  Assert.equal(#settled.ledger, 1, "the doll writes exactly one ledger delta")
  Assert.equal(settled.ledger[1].item, "POKE_DOLL", "the delta names the doll")
  Assert.equal(settled.ledger[1].delta, -1, "the delta consumes exactly one unit")
  Assert.equal(turn.status, "ended", "the doll ends the battle")
  Assert.equal(turn.outcome.kind, "escaped", "the terminal outcome names the escape")
  session:dispose()
end

-- Escape dolls bypass trapping like retail (TryUseItem pocket 3 has no
-- trap gate): a trapped holder still seals its doll and flees, while
-- ordinary runs answer through the existing Escape trap law.
function T.trapped_dolls_bypass_the_trap_gate()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  local facts = {
    POKE_DOLL = { partyUse = { kind = "none" }, pocket = "items", battleUseFunc = 3 },
  }
  local scenario = itemScenario(
    { leveledCombatant(1, 23, "EEVEE", 20) },
    { leveledCombatant(2, 41, "EEVEE", 5), leveledCombatant(4, 43, "EEVEE", 5) },
    SessionFixture.inventory("party", { 1 }, { POKE_DOLL = 1 }),
    facts
  )
  local session = contracts.Battle.newSession(scenario, content)
  local opening = SessionFixture.driveUntilSettled(session)
  -- Seed the retail trap beside the live entry like Mean Look would:
  -- the ordinary run gate already refuses trapped flight, so the doll
  -- proves it carries no new trap of its own by still fleeing.
  local live = session._state --[[@as table<string, unknown>]]
  assert(type(live) == "table", "the session keeps its live battle state")
  local combatants = (live --[[@as table<string, unknown>]]).combatants --[[@as table<integer, table<string, unknown>>]]
  combatants[1].trap = { held = true }
  local Escape = SessionFixture.requirePresent("libs.battle.src.gen4.Escape", "trapping owns leaving battle")
  local gate = Escape.canRun({ battleKind = "wild", trapped = { held = true }, guaranteed = false, attempts = 0 })
  Assert.isFalse(gate.ok, "the existing trap law still holds ordinary runs")
  local alpha = requestFor(opening, "alpha")
  local options = session:decisionOptions(alpha.requestId)
  local dollOption = nil
  for _, option in ipairs(options.actors[1].choices) do
    local choice = option.choice --[[@as table<string, unknown>]]
    local payload = choice.payload --[[@as table<string, unknown>]]
    if choice.kind == "item" and payload.item == "POKE_DOLL" then
      dollOption = option
      break
    end
  end
  Assert.notNil(dollOption, "the trapped battle still lists its doll")
  Assert.isTrue(dollOption.enabled == true, "trapping never disables the doll option")
  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(alpha, { bagChoice(actor, "POKE_DOLL", 1) })),
    "the trapped doll still seals"
  )
  local beta = requestFor(opening, "beta")
  local foeActor = assert(beta.actors[1], "the opposing request addresses its lead")
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(beta, {
      SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(1)),
    })),
    "the opposing strike is accepted"
  )
  local turn = session:advance(64)
  local fled = nil
  for _, event in ipairs(turn.events or {}) do
    if event.kind == "flee" then
      fled = event
    end
  end
  Assert.notNil(fled, "the trapped doll still announces its flight")
  Assert.isTrue((fled.payload --[[@as table<string, unknown>]]).escaped == true, "the trapped doll flees")
  session:dispose()
end

-- Builds one tutorial scenario (scripted kind with the lesson marker)
-- carrying the fixed Marill/Rattata content and 20 balls for the
-- throw gate. The kernel derives its wild-like capture policy from
-- the tutorial flag, not the scripted kind.
local function tutorialScenario(pack, itemFacts)
  local Executor = executorOwner()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local seeds = { lead, foe }
  local alphaSpec = SessionFixture.participant(1, 1, "alpha", { lead })
  alphaSpec.inventoryId = (pack --[[@as table<string, unknown>]]).id
  return {
    ruleset = Executor.RULESET,
    format = WILD_FORMAT,
    kind = "scripted",
    tutorial = true,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = { alphaSpec, SessionFixture.participant(2, 2, "beta", { foe }) },
    positions = {
      SessionFixture.position(1, 1, { 1 }, lead.id),
      SessionFixture.position(2, 2, { 2 }, foe.id),
    },
    inventories = { pack },
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(),
    speciesFacts = scenarioSpeciesFacts(seeds),
    itemFacts = itemFacts,
    boxHasSpace = true,
  }
end
-- Retail lessons skip their rolls (battle_controller_player.c:2425 and
-- battle_command.c:7185 under TUTORIAL): throws always catch without
-- spending stock, shakes, or draws, and strikes always miss without
-- spending accuracy or critical draws. One lesson scenario proves both
-- halves without building the native content twice.
function T.tutorial_lessons_skip_their_rolls_and_spend_nothing()
  local contracts = SessionFixture.sessionContracts()
  local content = actionContent()
  do
    local pack = SessionFixture.inventory("party", { 1 }, { POKE_BALL = 20 })
    local scenario = tutorialScenario(pack, {})
    local session = contracts.Battle.newSession(scenario, content)
    local opening = SessionFixture.driveUntilSettled(session)
    Assert.equal(opening.status, "waiting", "the lesson asks for decisions")
    local alpha = requestFor(opening, "alpha")
    local beta = requestFor(opening, "beta")
    local actor = assert(alpha.actors[1], "the lesson addresses its lead")
    local foeActor = assert(beta.actors[1], "the lesson addresses its foe")
    local before = session:capture()
    Assert.isTrue(
      session:submit(SessionFixture.replyFor(alpha, { bagChoice(actor, "POKE_BALL", 2) })),
      "the lesson throw seals"
    )
    Assert.isTrue(
      session:submit(SessionFixture.replyFor(beta, {
        SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(1)),
      })),
      "the lesson foe strikes"
    )
    local turn = session:advance(64)
    local caught = nil
    for _, event in ipairs(turn.events or {}) do
      if event.kind == "caught" then
        caught = event
      end
    end
    Assert.notNil(caught, "the lesson throw catches")
    local settled = session:capture()
    Assert.equal(settled.inventories.party.quantities.POKE_BALL, 20, "the lesson spends no ball")
    Assert.deepEqual(settled.ledger, {}, "the lesson ledgers no consumption")
    Assert.equal(settled.rng.calls, before.rng.calls, "the lesson spends no shake draw")
    Assert.equal(turn.status, "ended", "the lesson ends on its catch")
    session:dispose()
  end
  do
    local pack = SessionFixture.inventory("party", { 1 }, {})
    local scenario = tutorialScenario(pack, {})
    local session = contracts.Battle.newSession(scenario, content)
    local opening = SessionFixture.driveUntilSettled(session)
    local alpha = requestFor(opening, "alpha")
    local beta = requestFor(opening, "beta")
    local actor = assert(alpha.actors[1], "the lesson addresses its lead")
    local foeActor = assert(beta.actors[1], "the lesson addresses its foe")
    local before = session:capture()
    Assert.isTrue(
      session:submit(SessionFixture.replyFor(alpha, {
        SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)),
      })),
      "the lesson strike seals"
    )
    Assert.isTrue(
      session:submit(SessionFixture.replyFor(beta, {
        SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(1)),
      })),
      "the lesson foe strikes"
    )
    local turn = session:advance(64)
    local struck = false
    for _, event in ipairs(turn.events or {}) do
      if event.kind == "struck" then
        struck = true
      end
    end
    Assert.isFalse(struck, "the lesson strikes never land")
    local settled = session:capture()
    Assert.equal(settled.combatants[1].hp, before.combatants[1].hp, "the lesson deals no damage")
    Assert.equal(settled.rng.calls, before.rng.calls + 4, "the lesson spends no accuracy or critical draws")
    session:dispose()
  end
end

return { tests = T }
