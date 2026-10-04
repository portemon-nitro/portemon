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
  for _, key in ipairs(formRecord.types --[[@as string[] ]]) do
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
    itemScenario(
      { lead },
      { leveledCombatant(2, 41, "EEVEE", 5), leveledCombatant(4, 43, "EEVEE", 5) },
      pack,
      facts
    ),
    content
  )
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the opening turn asks for decisions")
  local before = session:capture()
  local hpBefore = before.combatants[1].hp
  local maxHp = before.combatants[1].maxHp
  Assert.isTrue(type(maxHp) == "number", "the holder carries its health ceiling")
  Assert.isTrue(
    maxHp --[[@as integer]] - hpBefore >= 50,
    "the wound leaves room for the full fixed restoration"
  )
  local callsBefore = before.rng.calls
  local alpha = requestFor(opening, "alpha")
  local beta = requestFor(opening, "beta")
  local actor = assert(alpha.actors[1], "the owning request addresses its lead")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local ok, replyErr =
    session:submit(SessionFixture.replyFor(alpha, { bagChoice(actor, "SUPER_POTION", 1) }))
  Assert.isTrue(ok, "the fixed restoration choice is accepted")
  Assert.isNil(replyErr, "accepted bag use carries no input error")
  local answered, answerErr =
    session:submit(SessionFixture.replyFor(beta, { SessionFixture.switchChoice(foe, 4) }))
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
  Assert.equal(settled.rng.calls, callsBefore, "deterministic bag use draws nothing")
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
  local BattleRng = SessionFixture.requirePresent(
    "libs.battle.src.gen4.BattleRng",
    "labeled native draws own the battle stream"
  )
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
  local fullChoice =
    { inventoryId = "party", item = "POTION", target = { kind = "combatant", combatant = 1 } }
  local refused = ItemUse.plan(fullChoice, fullView, facts)
  Assert.equal(refused.failureReason, "no_effect", "full-health medicine plans its refusal, got " .. tostring(refused.failureReason))
  Assert.isTrue(refused.executed ~= true, "refused plans carry no execution stamp")
  local fullBattle = {
    inventories = { party = { quantities = { POTION = 1, ETHER = 1 }, revision = 0 } },
    ledger = {},
    combatants = { [1] = { hp = 30, maxHp = 30 } },
  }
  local refuseOk, refuseErr = pcall(ItemUse.execute, refused, fullBattle, rng)
  Assert.isFalse(refuseOk, "executing a refused plan raises its typed failure")
  Assert.equal(
    (refuseErr --[[@as table<string, unknown>]]).code,
    "no_effect",
    "the refusal names its reason"
  )
  Assert.deepEqual(fullBattle.ledger, {}, "refused executions write no ledger")
  Assert.equal(fullBattle.inventories.party.quantities.POTION, 1, "refused executions consume nothing")
  Assert.equal(fullBattle.combatants[1].hp, 30, "refused executions heal nothing")
  Assert.equal(rng:capture().calls, callsBefore, "refused executions draw nothing")

  local hurtView = {
    inventories = { party = { quantities = { POTION = 1, ETHER = 1 }, revision = 0 } },
    outstanding = {},
    combatants = { [1] = { hp = 10, maxHp = 30 } },
  }
  local strangeChoice =
    { inventoryId = "party", item = "ETHER", target = { kind = "combatant", combatant = 1 } }
  local hurtBattle = {
    inventories = { party = { quantities = { POTION = 1, ETHER = 1 }, revision = 0 } },
    ledger = {},
    combatants = { [1] = { hp = 10, maxHp = 30 } },
  }
  local planOk, planOrErr = pcall(ItemUse.plan, strangeChoice, hurtView, facts)
  local failure = nil
  if planOk then
    local plan = planOrErr --[[@as table<string, unknown>]]
    Assert.isNil(
      plan.failureReason,
      "unmodeled semantics never downgrade to a refusal"
    )
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
    itemScenario(
      { lead },
      { leveledCombatant(2, 41, "EEVEE", 5), leveledCombatant(4, 43, "EEVEE", 5) },
      pack,
      facts
    ),
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
  local answered, answerErr =
    session:submit(SessionFixture.replyFor(beta, { SessionFixture.switchChoice(foe, 4) }))
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

return { tests = T }
