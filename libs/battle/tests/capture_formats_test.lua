-- Special capture contexts carry real mechanics: registration publishes
-- the native mode bindings, each mode admits only its own actions and balls,
-- special ball counters spend exactly once, exhaustion and missing context
-- are rejected instead of falling back to ordinary wild rules, and contest
-- captures record their candidate for judging.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@param behavior string missing owner under test
---@return table the loaded special-capture owner
local function formatsOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.formats.CaptureFormats", behavior)
end

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

---@param mode string capture mode under test
---@param extra table<string, unknown>|nil mode facts under test
---@return table encounter environment carrying the mode facts
local function modeEnv(mode, extra)
  local env = {
    mode = mode,
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
  if extra ~= nil then
    for key, value in pairs(extra) do
      env[key] = value
    end
  end
  return env
end

---@param registry table registered capture-mode bindings under test
---@param mode string capture mode under test
---@return table the policy bound for the mode
local function policyFor(registry, mode)
  local Formats = formatsOwner("capture-only and special mechanics own their mode policies")
  return Formats.policyFor(registry, mode)
end

---@param list string[] admitted action vocabulary under test
---@param action string candidate action under test
---@return boolean true when the vocabulary admits the action
local function admits(list, action)
  for _, allowed in ipairs(list) do
    if allowed == action then
      return true
    end
  end
  return false
end

-- Registration publishes every native capture mode with a real action set:
-- each policy names its mode and admits at least throwing and running.
function T.registration_publishes_every_native_capture_mode()
  local Formats = formatsOwner("capture-only and special mechanics own their mode policies")
  Assert.isTrue(type(Formats.register) == "function", "special capture mechanics bind through registration")
  local registry = Formats.register()
  Assert.notNil(registry, "registration publishes the native bindings")
  for _, mode in ipairs({ "wild", "safari", "contest", "pal_park", "tutorial" }) do
    local policy = Formats.policyFor(registry, mode)
    Assert.notNil(policy, mode .. " binds a policy")
    Assert.isTrue(type(policy.actions) == "table" and #policy.actions > 0, mode .. " admits real actions")
    Assert.isTrue(admits(policy.actions, "throw_ball"), mode .. " admits throwing")
    Assert.isTrue(admits(policy.actions, "run"), mode .. " admits running")
  end
  local ok, err = pcall(Formats.policyFor, registry, "deep_space")
  Assert.isFalse(ok, "an unknown mode binds nothing")
  Assert.isTrue(type(err) == "table" and type(err.code) == "string", "an unknown mode names its failure")
end

-- The wild policy admits the full battle repertoire while the Safari
-- policy admits only balls, bait, rock, and running: attacks and battle
-- items stay outside the Safari action set.
function T.safari_limits_the_action_set()
  local Formats = formatsOwner("capture-only and special mechanics own their mode policies")
  local registry = Formats.register()
  local wild = Formats.policyFor(registry, "wild")
  Assert.isTrue(admits(wild.actions, "attack"), "the wild policy admits attacking")
  Assert.isTrue(admits(wild.actions, "bag_item"), "the wild policy admits battle items")
  local safari = Formats.policyFor(registry, "safari")
  Assert.isTrue(admits(safari.actions, "throw_bait"), "the safari policy admits bait")
  Assert.isTrue(admits(safari.actions, "throw_rock"), "the safari policy admits rocks")
  Assert.isFalse(admits(safari.actions, "attack"), "the safari policy never admits attacking")
  Assert.isFalse(admits(safari.actions, "bag_item"), "the safari policy never admits battle items")
end

-- Safari throws spend the Safari counter exactly once: a counter of one
-- lands the catch and reaches zero, and no bag stock moves.
function T.safari_throws_spend_the_safari_counter_once()
  local Capture = captureOwner("exact catch and shake arithmetic owns thrown balls")
  local Context = contextOwner("typed capture environments own the facts each ball reads")
  local Formats = formatsOwner("capture-only and special mechanics own their mode policies")
  local target = targetFacts({ catchRate = 255, hp = 1 })
  local env = modeEnv("safari", { safariBalls = 1, safariCatchRateStage = 6 })
  local context = Context.forBall("SAFARI_BALL", target, env)
  local attempt = { actor = 1, ball = "SAFARI_BALL", target = { combatant = 2 } }
  local battle = {
    mode = "safari",
    safariBalls = 1,
    formatState = Formats.initialState("safari"),
    inventories = { party = { quantities = { SAFARI_BALL = 0 } } },
    ledger = {},
    combatants = { [2] = { mon = { species = "PIKACHU" }, hp = 1, maxHp = 100 } },
  }
  local stream = scriptedStream({ 0, 0, 0 })
  local outcome = Capture.execute(attempt, battle, stream)
  Assert.isTrue(outcome.result.success, "the scripted tape lands the safari catch")
  Assert.equal(battle.safariBalls, 0, "the safari throw spends its counter exactly once")
  Assert.deepEqual(battle.inventories.party.quantities, { SAFARI_BALL = 0 }, "a safari throw never touches bag stock")
  Assert.equal(env.safariBalls, 1, "executing never mutates the detached environment")
end

-- An exhausted Safari counter fails before any draw: the attempt is
-- refused, the stream is untouched, and nothing is spent.
function T.exhausted_safari_counters_fail_before_any_draw()
  local Capture = captureOwner("exact catch and shake arithmetic owns thrown balls")
  local Context = contextOwner("typed capture environments own the facts each ball reads")
  local Formats = formatsOwner("capture-only and special mechanics own their mode policies")
  local attempt = { actor = 1, ball = "SAFARI_BALL", target = { combatant = 2 } }
  local battle = {
    mode = "safari",
    safariBalls = 0,
    formatState = Formats.initialState("safari"),
    inventories = { party = { quantities = {} } },
    ledger = {},
    combatants = { [2] = { mon = { species = "PIKACHU" }, hp = 100, maxHp = 100 } },
  }
  local stream = scriptedStream({ 0, 0, 0 })
  local context = Context.forBall("SAFARI_BALL", targetFacts(), modeEnv("safari", { safariBalls = 0, safariCatchRateStage = 6 }))
  local ok, err = pcall(Capture.execute, attempt, battle, stream)
  Assert.isFalse(ok, "an exhausted counter never throws")
  Assert.isTrue(type(err) == "table" and type(err.code) == "string", "an exhausted counter names its failure")
  Assert.deepEqual(stream:capture(), { used = 0 }, "an exhausted counter spends no draw")
  Assert.equal(battle.safariBalls, 0, "an exhausted counter spends nothing")
  Assert.deepEqual(battle.ledger, {}, "a refused throw records no consumption")
  Assert.notNil(context, "the rejected context still builds for diagnosis")
end

-- Safari without its counter is rejected, never treated as an ordinary
-- wild throw: missing context fails instead of falling back.
function T.safari_without_its_counter_is_rejected()
  local Capture = captureOwner("exact catch and shake arithmetic owns thrown balls")
  local Context = contextOwner("typed capture environments own the facts each ball reads")
  local Formats = formatsOwner("capture-only and special mechanics own their mode policies")
  local attempt = { actor = 1, ball = "SAFARI_BALL", target = { combatant = 2 } }
  local battle = {
    mode = "safari",
    formatState = Formats.initialState("safari"),
    inventories = { party = { quantities = {} } },
    ledger = {},
    combatants = { [2] = { mon = { species = "PIKACHU" }, hp = 100, maxHp = 100 } },
  }
  local stream = scriptedStream({ 0, 0, 0 })
  local context = Context.forBall("SAFARI_BALL", targetFacts(), modeEnv("wild"))
  local ok, err = pcall(Capture.execute, attempt, battle, stream)
  Assert.isFalse(ok, "a safari throw without its counter never executes")
  Assert.isTrue(type(err) == "table" and type(err.code) == "string", "missing context names its failure")
  Assert.deepEqual(stream:capture(), { used = 0 }, "missing context spends no draw")
  Assert.notNil(context, "the wild-built context still builds for diagnosis")
end

-- Contest throws spend Sport Balls and record the candidate: the result
-- carries the contest mode with the caught species and level for judging,
-- and exhaustion is refused without spending a draw.
function T.contest_throws_record_the_candidate_for_judging()
  local Capture = captureOwner("exact catch and shake arithmetic owns thrown balls")
  local Context = contextOwner("typed capture environments own the facts each ball reads")
  local target = targetFacts({ catchRate = 255, hp = 1, species = "SCYTHER", level = 14 })
  local context = Context.forBall("SPORT_BALL", target, modeEnv("contest", { sportBalls = 1 }))
  local attempt = { actor = 1, ball = "SPORT_BALL", target = { combatant = 2 } }
  local battle = {
    mode = "contest",
    sportBalls = 1,
    inventories = { party = { quantities = {} } },
    ledger = {},
    combatants = { [2] = { mon = { species = "SCYTHER" }, hp = 1, maxHp = 100 } },
  }
  local stream = scriptedStream({ 0, 0, 0 })
  local outcome = Capture.execute(attempt, battle, stream)
  Assert.isTrue(outcome.result.success, "the scripted tape lands the contest catch")
  Assert.equal(outcome.result.context.mode, "contest", "the result names its contest mode")
  Assert.equal(battle.sportBalls, 0, "the contest throw spends its counter exactly once")
  local empty = {
    mode = "contest",
    sportBalls = 0,
    inventories = { party = { quantities = {} } },
    ledger = {},
    combatants = { [2] = { mon = { species = "SCYTHER" }, hp = 1, maxHp = 100 } },
  }
  local quiet = scriptedStream({ 0, 0, 0 })
  local ok, err = pcall(Capture.execute, attempt, empty, quiet)
  Assert.isFalse(ok, "an exhausted contest counter never throws")
  Assert.isTrue(type(err) == "table" and type(err.code) == "string", "an exhausted contest counter names its failure")
  Assert.deepEqual(quiet:capture(), { used = 0 }, "an exhausted contest counter spends no draw")
  Assert.notNil(context, "the contest context still builds for diagnosis")
end

-- Contest comparison keeps the stronger candidate and stays coherent: the
-- higher level leads either way round, and ties keep the earlier catch.
function T.contest_comparison_keeps_the_stronger_candidate()
  local Formats = formatsOwner("capture-only and special mechanics own their mode policies")
  local registry = Formats.register()
  local contest = policyFor(registry, "contest")
  Assert.isTrue(type(contest.compare) == "function", "the contest policy compares candidates")
  local young = { species = "CATERPIE", level = 9 }
  local elder = { species = "SCYTHER", level = 14 }
  local leading = contest.compare(young, elder)
  Assert.deepEqual(leading, elder, "the higher level leads")
  Assert.deepEqual(contest.compare(elder, young), elder, "the order of comparison never matters")
  local first = { species = "WEEDLE", level = 12 }
  local second = { species = "PARAS", level = 12 }
  Assert.deepEqual(contest.compare(first, second), first, "ties keep the earlier catch")
end

-- Pal Park admits only Park Balls and always lands them without a draw,
-- even against a nearly uncatchable target.
function T.pal_park_admits_only_park_balls_and_always_lands()
  local Formats = formatsOwner("capture-only and special mechanics own their mode policies")
  local Capture = captureOwner("exact catch and shake arithmetic owns thrown balls")
  local Context = contextOwner("typed capture environments own the facts each ball reads")
  local registry = Formats.register()
  local park = policyFor(registry, "pal_park")
  Assert.isTrue(admits(park.actions, "throw_ball"), "the park policy admits throwing")
  Assert.isFalse(admits(park.actions, "attack"), "the park policy never admits attacking")
  local target = targetFacts({ catchRate = 3 })
  local context = Context.forBall("PARK_BALL", target, modeEnv("pal_park", { parkBalls = 1 }))
  local attempt = { actor = 1, ball = "PARK_BALL", target = { combatant = 2 } }
  local battle = {
    mode = "pal_park",
    parkBalls = 1,
    inventories = { party = { quantities = {} } },
    ledger = {},
    combatants = { [2] = { mon = { species = "PIKACHU" }, hp = 100, maxHp = 100 } },
  }
  local stream = scriptedStream({ 65535 })
  local outcome = Capture.execute(attempt, battle, stream)
  Assert.isTrue(outcome.result.success, "the park throw always lands")
  Assert.equal(outcome.result.shakes, 3, "the park throw reports full shakes")
  Assert.deepEqual(stream:capture(), { used = 0 }, "the park throw spends no draw")
  Assert.equal(battle.parkBalls, 0, "the park throw spends its counter exactly once")
  local refused = { actor = 1, ball = "ULTRA_BALL", target = { combatant = 2 } }
  local quiet = scriptedStream({ 0, 0, 0 })
  local ok, err = pcall(Capture.execute, refused, battle, quiet)
  Assert.isFalse(ok, "ordinary balls never throw in the park")
  Assert.isTrue(type(err) == "table" and type(err.code) == "string", "a park refusal names its failure")
  Assert.deepEqual(quiet:capture(), { used = 0 }, "a park refusal spends no draw")
  Assert.notNil(context, "the park context still builds for diagnosis")
end

-- Tutorial throws belong to the script: player throws are refused without
-- spending anything, and missing script facts are rejected rather than
-- treated as ordinary wild throws.
function T.tutorial_throws_belong_to_the_script()
  local Capture = captureOwner("exact catch and shake arithmetic owns thrown balls")
  local attempt = { actor = 1, inventoryId = "party", ball = "POKE_BALL", target = { combatant = 2 } }
  local battle = {
    mode = "tutorial",
    inventories = { party = { quantities = { POKE_BALL = 5 } } },
    ledger = {},
    combatants = { [2] = { mon = { species = "PIKACHU" }, hp = 100, maxHp = 100 } },
  }
  local stream = scriptedStream({ 0, 0, 0 })
  local ok, err = pcall(Capture.execute, attempt, battle, stream)
  Assert.isFalse(ok, "a tutorial throw never executes by itself")
  Assert.isTrue(type(err) == "table" and type(err.code) == "string", "a tutorial refusal names its failure")
  Assert.deepEqual(stream:capture(), { used = 0 }, "a tutorial refusal spends no draw")
  Assert.equal(battle.inventories.party.quantities.POKE_BALL, 5, "a tutorial refusal spends no ball")
  Assert.deepEqual(battle.ledger, {}, "a tutorial refusal records no consumption")
end

---@param values integer[] scripted draw results in consumption order
---@return table stream double recording labels with draw accounting
local function labeledStream(values)
  local used = 0
  local labels = {} ---@type string[]
  return {
    nextU16 = function(self, label, cause)
      assert(self ~= nil, "draws arrive through the stream")
      assert(type(label) == "string" and label ~= "", "safari draws name their call site")
      assert(type(cause) == "table", "safari draws carry their semantic cause")
      used = used + 1
      labels[#labels + 1] = label
      return values[used] or 0
    end,
    capture = function()
      return { used = used, labels = labels }
    end,
  }
end

-- Safari bait and rock mutate the native stage state with one draw each:
-- bait spends an attempt and, on a nonzero share, lowers the catch stage,
-- while rock raises the catch stage and, on a nonzero share, refunds an
-- attempt. A share divisible by ten moves only the guaranteed half.
function T.safari_bait_and_rock_move_stage_and_attempts_with_one_draw_each()
  local Formats = formatsOwner("capture-only and special mechanics own their mode policies")
  local fresh = Formats.initialState("safari")
  Assert.deepEqual(
    fresh,
    { safariCatchRateStage = 6, safariRunAttempts = 6 },
    "safari battles open at stage 6 with 6 attempts"
  )
  local baited = Formats.initialState("safari")
  local baitStream = labeledStream({ 7 })
  Formats.applyAction("safari", "throw_bait", baited, baitStream)
  Assert.equal(baited.safariCatchRateStage, 5, "nonzero bait lowers the catch stage")
  Assert.equal(baited.safariRunAttempts, 5, "bait spends an attempt")
  Assert.deepEqual(baitStream:capture().labels, { "safari:bait" }, "bait spends one labeled draw")
  local kept = Formats.initialState("safari")
  local keptStream = labeledStream({ 0 })
  Formats.applyAction("safari", "throw_bait", kept, keptStream)
  Assert.equal(kept.safariCatchRateStage, 6, "a divisible bait share keeps the catch stage")
  Assert.equal(kept.safariRunAttempts, 5, "a divisible bait share still spends an attempt")
  Assert.deepEqual(keptStream:capture().labels, { "safari:bait" }, "divisible bait still spends one draw")
  local rocked = Formats.initialState("safari")
  local rockStream = labeledStream({ 7 })
  Formats.applyAction("safari", "throw_rock", rocked, rockStream)
  Assert.equal(rocked.safariCatchRateStage, 7, "nonzero rock raises the catch stage")
  Assert.equal(rocked.safariRunAttempts, 7, "nonzero rock refunds an attempt")
  Assert.deepEqual(rockStream:capture().labels, { "safari:rock" }, "rock spends one labeled draw")
  local held = Formats.initialState("safari")
  local heldStream = labeledStream({ 0 })
  Formats.applyAction("safari", "throw_rock", held, heldStream)
  Assert.equal(held.safariCatchRateStage, 7, "a divisible rock share still raises the catch stage")
  Assert.equal(held.safariRunAttempts, 6, "a divisible rock share refunds no attempt")
  Assert.deepEqual(heldStream:capture().labels, { "safari:rock" }, "divisible rock still spends one draw")
end

-- Safari stage transitions clamp at their native bounds and refuse work
-- outside safari mode: the stage never leaves 0..12, attempts never leave
-- 0..12, and a refused action spends no draw and mutates nothing.
function T.safari_stage_transitions_clamp_and_refuse_outside_safari()
  local Formats = formatsOwner("capture-only and special mechanics own their mode policies")
  local floored = { safariCatchRateStage = 0, safariRunAttempts = 1 }
  Formats.applyAction("safari", "throw_bait", floored, labeledStream({ 7 }))
  Assert.equal(floored.safariCatchRateStage, 0, "bait never lowers the stage below zero")
  Assert.equal(floored.safariRunAttempts, 0, "bait still spends an attempt at the floor")
  local empty = { safariCatchRateStage = 6, safariRunAttempts = 0 }
  Formats.applyAction("safari", "throw_bait", empty, labeledStream({ 7 }))
  Assert.equal(empty.safariCatchRateStage, 5, "bait still lowers the stage with no attempts left")
  Assert.equal(empty.safariRunAttempts, 0, "bait never spends an attempt below zero")
  local capped = { safariCatchRateStage = 12, safariRunAttempts = 11 }
  Formats.applyAction("safari", "throw_rock", capped, labeledStream({ 7 }))
  Assert.equal(capped.safariCatchRateStage, 12, "rock never raises the stage above twelve")
  Assert.equal(capped.safariRunAttempts, 12, "rock still refunds an attempt at the ceiling")
  local full = { safariCatchRateStage = 6, safariRunAttempts = 12 }
  Formats.applyAction("safari", "throw_rock", full, labeledStream({ 7 }))
  Assert.equal(full.safariCatchRateStage, 7, "rock still raises the stage with full attempts")
  Assert.equal(full.safariRunAttempts, 12, "rock never refunds an attempt above twelve")
  local state = Formats.initialState("safari")
  local quiet = labeledStream({ 7 })
  local ok, err = pcall(Formats.applyAction, "wild", "throw_bait", state, quiet)
  Assert.isFalse(ok, "bait outside safari mode never executes")
  Assert.isTrue(type(err) == "table" and type(err.code) == "string", "a refused bait names its failure")
  Assert.deepEqual(quiet:capture(), { used = 0, labels = {} }, "a refused bait spends no draw")
  Assert.deepEqual(
    state,
    { safariCatchRateStage = 6, safariRunAttempts = 6 },
    "a refused bait mutates nothing"
  )
  local loud = labeledStream({ 7 })
  local settled, settleErr = pcall(Formats.applyAction, "safari", "attack", state, loud)
  Assert.isFalse(settled, "a non-safari action never executes")
  Assert.isTrue(
    type(settleErr) == "table" and type(settleErr.code) == "string",
    "a refused action names its failure"
  )
  Assert.deepEqual(loud:capture(), { used = 0, labels = {} }, "a refused action spends no draw")
end

-- Malformed safari state fails before any draw: a missing record, a
-- missing field, or a value outside 0..12 refuses the action with the
-- stream untouched.
function T.malformed_safari_state_fails_before_any_draw()
  local Formats = formatsOwner("capture-only and special mechanics own their mode policies")
  local candidates = {
    {},
    { safariCatchRateStage = 6 },
    { safariRunAttempts = 6 },
    { safariCatchRateStage = 13, safariRunAttempts = 6 },
    { safariCatchRateStage = -1, safariRunAttempts = 6 },
    { safariCatchRateStage = 6.5, safariRunAttempts = 6 },
    { safariCatchRateStage = 6, safariRunAttempts = 13 },
    { safariCatchRateStage = 6, safariRunAttempts = "6" },
  }
  local function refuses(state)
    local stream = labeledStream({ 7 })
    local ok, err = pcall(Formats.applyAction, "safari", "throw_bait", state, stream)
    Assert.isFalse(ok, "malformed safari state never executes")
    Assert.isTrue(
      type(err) == "table" and err.code == "invalid_format_state",
      "malformed safari state names its failure"
    )
    Assert.deepEqual(stream:capture(), { used = 0, labels = {} }, "malformed state spends no draw")
  end
  refuses(nil)
  for _, candidate in ipairs(candidates) do
    refuses(candidate)
  end
  local unknown = labeledStream({ 7 })
  local ok, err = pcall(Formats.applyAction, "deep_space", "throw_bait", {
    safariCatchRateStage = 6,
    safariRunAttempts = 6,
  }, unknown)
  Assert.isFalse(ok, "an unknown mode never executes")
  Assert.isTrue(type(err) == "table" and type(err.code) == "string", "an unknown mode names its failure")
  Assert.deepEqual(unknown:capture(), { used = 0, labels = {} }, "an unknown mode spends no draw")
end

return { tests = T }
