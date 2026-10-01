-- Captures keep the caught mon bit-for-bit and never claim storage: a
-- successful throw returns the existing target record with its identity,
-- moves, experience, and current condition intact, spends exactly one ball,
-- and leaves placement to the later committer. Illegal throws fail at their
-- proper stage with no draws spent, no stock moved, and no state changed,
-- while an explicitly permitted custom policy takes the same path.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@param behavior string missing owner under test
---@return table the loaded catch calculator
local function captureOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.Capture", behavior)
end

---@param behavior string missing owner under test
---@return table the loaded capture environment owner
local function contextOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.CaptureContext", behavior)
end

---@param behavior string missing owner under test
---@return table the loaded special-capture owner
local function formatsOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.formats.CaptureFormats", behavior)
end

---@param behavior string missing owner under test
---@return table the loaded battle item planner
local function itemUseOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.ItemUse", behavior)
end

---@param behavior string missing owner under test
---@return table the loaded terminal-result owner
local function outcomeOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.OutcomePolicy", behavior)
end

---@param values integer[] scripted draw results in consumption order
---@return table stream double with draw accounting
local function scriptedStream(values)
  local used = 0
  return {
    nextU16 = function(self, label, cause)
      assert(self ~= nil, "draws arrive through the stream")
      assert(type(label) == "string" and label ~= "", "shake draws name their call site")
      assert(type(cause) == "table", "shake draws carry their semantic cause")
      used = used + 1
      return values[used] or 0
    end,
    capture = function()
      return { used = used }
    end,
  }
end

---@param overrides table<string, unknown>|nil field replacements for this target
---@return table wild target facts with full health and no status
local function targetFacts(overrides)
  local facts = {
    catchRate = 45,
    maxHp = 100,
    hp = 100,
    status = "healthy",
    species = "PIKACHU",
    types = { "electric" },
    level = 20,
    weight = 60,
    baseSpeed = 90,
    gender = "male",
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      facts[key] = value
    end
  end
  return facts
end

---@param overrides table<string, unknown>|nil field replacements for this encounter
---@return table open wild encounter environment on the first turn
local function wildEnv(overrides)
  local env = {
    mode = "wild",
    turns = 0,
    pokedexCaught = false,
    attackerLevel = 20,
    attackerSpecies = "PIDGEY",
    attackerGender = "female",
    method = "land",
    fished = false,
    timeOfDay = "day",
    inCave = false,
    backdrop = "field",
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      env[key] = value
    end
  end
  return env
end

---@param seed integer fixed generator state for the wild mon
---@return table real persistent mon record owned by the mon domain
local function wildMon(seed)
  return SessionFixture.makeMon(seed)
end

---@param mon table persistent mon record held by the target slot
---@param ball string ball key under test
---@param balls integer units on the shared stack under test
---@return table battle-owned execution state holding the target
local function wildBattle(mon, ball, balls)
  local quantities = {}
  quantities[ball] = balls
  return {
    mode = "wild",
    battleKind = "wild",
    inventories = { party = { quantities = quantities, revision = 0 } },
    ledger = {},
    combatants = {
      [1] = { hp = 30, maxHp = 30 },
      [2] = { mon = mon, hp = 1, maxHp = 100, activation = 5 },
    },
  }
end

---@param ball string ball key under test
---@return table throw attempt at the live target slot
local function wildAttempt(ball)
  return { actor = 1, inventoryId = "party", ball = ball, target = { combatant = 2, activation = 5 } }
end

---@param err unknown raised value under test
---@return string the typed failure code it carries
local function failureCode(err)
  Assert.isTrue(type(err) == "table", "failures arrive as typed errors")
  local coded = err --[[@as table<string, unknown>]]
  Assert.isTrue(type(coded.code) == "string", "failures name their code")
  return coded.code --[[@as string]]
end

-- The capture owner exposes validation, calculation, and execution while
-- the environment owner exposes validation and per-ball staging.
function T.capture_exposes_validation_calculation_and_execution()
  local Capture = captureOwner("throwing, calculating, and settling own captures")
  Assert.isTrue(type(Capture.validate) == "function", "attempts validate before anything is spent")
  Assert.isTrue(type(Capture.calculate) == "function", "throws calculate exact odds and shakes")
  Assert.isTrue(type(Capture.execute) == "function", "throws execute through one owned path")
  local Context = contextOwner("typed capture environments own the facts each ball reads")
  Assert.isTrue(type(Context.validate) == "function", "environments validate at their owner")
  Assert.isTrue(type(Context.forBall) == "function", "environments stage exactly the facts each ball reads")
  local Formats = formatsOwner("capture-only and special mechanics own their mode policies")
  Assert.isTrue(type(Formats.register) == "function", "special capture mechanics bind through registration")
end

-- The caught mon survives bit-for-bit: species, level, personality, IVs,
-- experience, and origin in the result match the target record exactly, so
-- nothing is rerolled and no capture metadata is invented by the throw.
function T.caught_identity_survives_bit_for_bit()
  local Capture = captureOwner("throwing, calculating, and settling own captures")
  local Context = contextOwner("typed capture environments own the facts each ball reads")
  local mon = wildMon(11)
  local context = Context.forBall("MASTER_BALL", targetFacts(), wildEnv())
  local battle = wildBattle(mon, "MASTER_BALL", 1)
  local stream = scriptedStream({ 0, 0, 0 })
  local outcome = Capture.execute(wildAttempt("MASTER_BALL"), battle, stream)
  Assert.isTrue(outcome.result.success, "the guaranteed throw lands")
  Assert.equal(outcome.result.ball, "MASTER_BALL", "the result names its ball")
  Assert.equal(outcome.result.shakes, 3, "the guaranteed throw reports full shakes")
  Assert.equal(outcome.result.target, 2, "the result names its combatant")
  Assert.equal(outcome.result.mon.species, mon.species, "the species survives")
  Assert.equal(outcome.result.mon.level, mon.level, "the level survives")
  Assert.equal(outcome.result.mon.personality, mon.personality, "the personality survives")
  Assert.deepEqual(outcome.result.mon.ivs, mon.ivs, "the IVs survive")
  Assert.equal(outcome.result.mon.experience, mon.experience, "the experience survives")
  Assert.deepEqual(outcome.result.source, mon.origin, "the origin travels unchanged")
  Assert.deepEqual(stream:capture(), { used = 0 }, "a guaranteed throw draws nothing extra")
end

-- A landed throw claims no placement: the result carries no stored or
-- retained flag even with a full party, so success never pretends the mon
-- reached storage.
function T.success_claims_no_placement_even_with_a_full_party()
  local Capture = captureOwner("throwing, calculating, and settling own captures")
  local Context = contextOwner("typed capture environments own the facts each ball reads")
  local mon = wildMon(23)
  local context = Context.forBall("MASTER_BALL", targetFacts(), wildEnv())
  assert(context ~= nil, "the throw context builds")
  local battle = wildBattle(mon, "MASTER_BALL", 1)
  battle.party = { capacity = 6, members = { 11, 12, 13, 14, 15, 16 } }
  local outcome = Capture.execute(wildAttempt("MASTER_BALL"), battle, scriptedStream({ 0, 0, 0 }))
  Assert.isTrue(outcome.result.success, "a full party never blocks the throw itself")
  Assert.isNil(outcome.result.retained, "success never claims retention")
  Assert.isNil(outcome.result.stored, "success never claims storage")
  Assert.isNil(outcome.result.placed, "success never claims placement")
end

-- The ball leaves exactly once: one unit leaves the shared stack, one
-- delta enters the ledger, and a second throw from the emptied stack is
-- refused instead of spending again.
function T.the_ball_leaves_exactly_once()
  local Capture = captureOwner("throwing, calculating, and settling own captures")
  local Context = contextOwner("typed capture environments own the facts each ball reads")
  local mon = wildMon(37)
  local context = Context.forBall("MASTER_BALL", targetFacts(), wildEnv())
  assert(context ~= nil, "the throw context builds")
  local battle = wildBattle(mon, "MASTER_BALL", 1)
  local outcome = Capture.execute(wildAttempt("MASTER_BALL"), battle, scriptedStream({ 0, 0, 0 }))
  Assert.isTrue(outcome.result.success, "the guaranteed throw lands")
  Assert.equal(battle.inventories.party.quantities.MASTER_BALL, 0, "the throw spends its ball")
  Assert.equal(#battle.ledger, 1, "the throw records exactly one consumption")
  Assert.equal(battle.ledger[1].delta, -1, "the ledger records the single unit")
  Assert.equal(battle.ledger[1].item, "MASTER_BALL", "the ledger names the spent ball")
  local quiet = scriptedStream({ 0, 0, 0 })
  local ok, err = pcall(Capture.execute, wildAttempt("MASTER_BALL"), battle, quiet)
  Assert.isFalse(ok, "the emptied stack throws nothing more")
  failureCode(err)
  Assert.deepEqual(quiet:capture(), { used = 0 }, "a refused throw spends no draw")
end

-- Events tell the throw in order: the ball first, one entry per shake, and
-- a final outcome matching success, with no experience posted anywhere.
function T.events_tell_throw_shakes_and_outcome_in_order()
  local Capture = captureOwner("throwing, calculating, and settling own captures")
  local Context = contextOwner("typed capture environments own the facts each ball reads")
  local landed = Context.forBall("POKE_BALL", targetFacts({ hp = 1 }), wildEnv())
  assert(landed ~= nil, "the landed context builds")
  local won =
    Capture.execute(wildAttempt("POKE_BALL"), wildBattle(wildMon(41), "POKE_BALL", 1), scriptedStream({ 0, 0, 0 }))
  Assert.isTrue(won.result.success, "the kind tape lands the catch")
  local kinds = {}
  for _, event in ipairs(won.events) do
    kinds[#kinds + 1] = event.kind
  end
  Assert.deepEqual(
    kinds,
    { "throw", "shake", "shake", "shake", "caught" },
    "success tells throw, shakes, and catch in order"
  )
  Assert.equal(won.events[1].ball, "POKE_BALL", "the throw event names its ball")
  Assert.equal(won.events[5].shakes, 3, "the catch event reports full shakes")
  local missed = Context.forBall("POKE_BALL", targetFacts({ hp = 1 }), wildEnv())
  assert(missed ~= nil, "the missed context builds")
  local lost =
    Capture.execute(wildAttempt("POKE_BALL"), wildBattle(wildMon(43), "POKE_BALL", 1), scriptedStream({ 65535 }))
  Assert.isFalse(lost.result.success, "the hostile draw breaks out")
  local missKinds = {}
  for _, event in ipairs(lost.events) do
    missKinds[#missKinds + 1] = event.kind
  end
  Assert.deepEqual(missKinds, { "throw", "broke_free" }, "failure tells throw and breakout in order")
  for _, outcome in ipairs({ won, lost }) do
    for _, event in ipairs(outcome.events) do
      Assert.isNil(event.experience, "captures post no experience")
      Assert.isNil(event.expAwarded, "captures award no experience")
    end
  end
end

-- Trainer targets are refused without cost: validation fails, no draw is
-- spent, and the shared stack is untouched.
function T.trainer_targets_are_refused_without_cost()
  local Capture = captureOwner("throwing, calculating, and settling own captures")
  local attempt = wildAttempt("ULTRA_BALL")
  local battle = wildBattle(wildMon(53), "ULTRA_BALL", 4)
  battle.battleKind = "trainer"
  battle.combatants[2].ownedByTrainer = true
  local stream = scriptedStream({ 0, 0, 0 })
  local ok, err = pcall(Capture.validate, attempt, battle)
  Assert.isFalse(ok, "a trainer target never validates")
  failureCode(err)
  local settled, settleErr = pcall(Capture.execute, attempt, battle, stream)
  Assert.isFalse(settled, "a trainer target never executes")
  failureCode(settleErr)
  Assert.deepEqual(stream:capture(), { used = 0 }, "a refused trainer throw spends no draw")
  Assert.equal(battle.inventories.party.quantities.ULTRA_BALL, 4, "a refused trainer throw spends no ball")
  Assert.deepEqual(battle.ledger, {}, "a refused trainer throw records no consumption")
end

-- Stale entry tokens cannot be caught: a token that no longer holds the
-- slot fails without spending draws or stock.
function T.stale_entry_tokens_cannot_be_caught()
  local Capture = captureOwner("throwing, calculating, and settling own captures")
  local attempt = { actor = 1, inventoryId = "party", ball = "GREAT_BALL", target = { combatant = 2, activation = 4 } }
  local battle = wildBattle(wildMon(59), "GREAT_BALL", 2)
  local stream = scriptedStream({ 0, 0, 0 })
  local ok, err = pcall(Capture.execute, attempt, battle, stream)
  Assert.isFalse(ok, "a stale token never executes")
  failureCode(err)
  Assert.deepEqual(stream:capture(), { used = 0 }, "a stale token spends no draw")
  Assert.equal(battle.inventories.party.quantities.GREAT_BALL, 2, "a stale token spends no ball")
end

-- Empty stacks throw nothing: the attempt fails with no draws spent and no
-- ledger entry written.
function T.empty_stacks_throw_nothing()
  local Capture = captureOwner("throwing, calculating, and settling own captures")
  local battle = wildBattle(wildMon(61), "POKE_BALL", 0)
  local stream = scriptedStream({ 0, 0, 0 })
  local ok, err = pcall(Capture.execute, wildAttempt("POKE_BALL"), battle, stream)
  Assert.isFalse(ok, "an empty stack never executes")
  failureCode(err)
  Assert.deepEqual(stream:capture(), { used = 0 }, "an empty stack spends no draw")
  Assert.deepEqual(battle.ledger, {}, "an empty stack records no consumption")
end

-- Unknown balls throw nothing: the attempt fails before staging odds with
-- no draws spent and no stock moved.
function T.unknown_balls_throw_nothing()
  local Capture = captureOwner("throwing, calculating, and settling own captures")
  local attempt = wildAttempt("GOLD_BALL")
  local battle = wildBattle(wildMon(67), "GOLD_BALL", 3)
  local stream = scriptedStream({ 0, 0, 0 })
  local ok, err = pcall(Capture.execute, attempt, battle, stream)
  Assert.isFalse(ok, "an unknown ball never executes")
  failureCode(err)
  Assert.deepEqual(stream:capture(), { used = 0 }, "an unknown ball spends no draw")
  Assert.equal(battle.inventories.party.quantities.GOLD_BALL, 3, "an unknown ball spends no stock")
end

-- Fainted targets are not catchable: a slot at zero health fails without
-- spending draws or stock.
function T.fainted_targets_are_not_catchable()
  local Capture = captureOwner("throwing, calculating, and settling own captures")
  local battle = wildBattle(wildMon(71), "POKE_BALL", 2)
  battle.combatants[2].hp = 0
  local stream = scriptedStream({ 0, 0, 0 })
  local ok, err = pcall(Capture.execute, wildAttempt("POKE_BALL"), battle, stream)
  Assert.isFalse(ok, "a fainted target never executes")
  failureCode(err)
  Assert.deepEqual(stream:capture(), { used = 0 }, "a fainted target spends no draw")
  Assert.equal(battle.inventories.party.quantities.POKE_BALL, 2, "a fainted target spends no ball")
end

-- An explicitly permitted custom policy takes the same path: a registered
-- custom mode that allows trainer targets lands the catch, spends one
-- ball, and keeps the caught identity intact.
function T.permitted_trainer_captures_use_the_same_path()
  local Capture = captureOwner("throwing, calculating, and settling own captures")
  local Context = contextOwner("typed capture environments own the facts each ball reads")
  local Formats = formatsOwner("capture-only and special mechanics own their mode policies")
  local registry = Formats.register({
    { mode = "custom:mentor", trainerCapture = true, actions = { "throw_ball", "run" } },
  })
  local custom = Formats.policyFor(registry, "custom:mentor")
  Assert.isTrue(custom.trainerCapture, "the custom policy permits trainer targets")
  local mon = wildMon(73)
  local context = Context.forBall("MASTER_BALL", targetFacts(), wildEnv({ mode = "custom:mentor" }))
  assert(context ~= nil, "the custom context builds")
  local attempt = wildAttempt("MASTER_BALL")
  local battle = wildBattle(mon, "MASTER_BALL", 1)
  battle.battleKind = "trainer"
  battle.mode = "custom:mentor"
  battle.combatants[2].ownedByTrainer = true
  local outcome = Capture.execute(attempt, battle, scriptedStream({ 0, 0, 0 }))
  Assert.isTrue(outcome.result.success, "the permitted custom throw lands")
  Assert.equal(outcome.result.mon.personality, mon.personality, "the custom path keeps the caught identity")
  Assert.equal(battle.inventories.party.quantities.MASTER_BALL, 0, "the custom path spends its ball once")
end

-- A kept combatant ends the wild battle as a capture: the terminal result
-- names capture and echoes the kept combatant instead of naming a winner.
function T.kept_combatants_end_the_battle_as_capture()
  local Outcome = outcomeOwner("the terminal result selector owns result gates")
  local result = Outcome.evaluate({
    sides = {
      { id = 1, standing = 1, fled = false },
      { id = 2, standing = 1, fled = false },
    },
    pendingReplacements = 0,
    captured = { 2 },
  })
  Assert.notNil(result, "a kept combatant names its result")
  Assert.equal(result.reason, "capture", "a kept combatant selects capture, never victory")
  Assert.deepEqual(result.captured, { 2 }, "the result echoes the kept combatant")
end

-- Bag throws delegate to the capture path: planning a ball names capture
-- effects rather than healing, and execution spends one unit while
-- returning the capture outcome.
function T.bag_throws_delegate_to_the_capture_path()
  local ItemUse = itemUseOwner("the bag owns throw-ball delegation to the capture path")
  local view = {
    inventories = { party = { quantities = { POKE_BALL = 1 }, revision = 0 } },
    outstanding = {},
    combatants = { [1] = { hp = 10, maxHp = 30 } },
  }
  local choice = { inventoryId = "party", item = "POKE_BALL", target = { kind = "combatant", combatant = 1 } }
  local plan = ItemUse.plan(choice, view)
  Assert.isNil(plan.failureReason, "the ball choice plans")
  Assert.isTrue(type(plan.effectOperations) == "table", "the ball plan lists its effects")
  Assert.isTrue(#plan.effectOperations >= 1, "the ball plan carries capture work")
  Assert.equal(plan.effectOperations[1].kind, "capture", "the ball plan names capture effects")
  local battle = {
    inventories = { party = { quantities = { POKE_BALL = 1 }, revision = 0 } },
    ledger = {},
    combatants = { [1] = { hp = 10, maxHp = 30 } },
  }
  local outcome = ItemUse.execute(plan, battle)
  Assert.equal(battle.inventories.party.quantities.POKE_BALL, 0, "the bag throw spends its ball")
  Assert.notNil(outcome.result, "the bag throw returns the capture outcome")
end

return { tests = T }
