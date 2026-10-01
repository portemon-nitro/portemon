-- Resumable native control flow: intercepted parents suspend at the child
-- boundary and resume to the correct parent, completed work never runs
-- twice, unknown or suspended completions fail loudly, and queue movement
-- never draws from the battle stream. Headless progression drains every
-- queued action identically under any operation budget with no renderer
-- present, and only missing decisions suspend the schedule.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@param id integer stable action identity
---@param combatant integer acting combatant identity
---@param kind string action class under test
---@return table staged action in queue shape
local function stagedAction(id, combatant, kind)
  return {
    id = id,
    actor = { combatant = combatant, activation = 1 },
    kind = kind,
    payload = {},
    selectedOrdinal = id,
    sampledOrder = { priority = 0, speed = 100 },
    progress = "queued",
  }
end

---@return table fresh control state in native schedule shape
local function freshFrame()
  return {
    kind = "hgss:schedule",
    version = 1,
    cursor = "opening",
    currentActionId = nil,
    residualCursor = nil,
    pendingFaints = {},
  }
end

---@param queue table explicit queue state under test
---@param id integer stable action identity
---@return table the queued action carrying the identity
local function findAction(queue, id)
  local found = nil
  for _, action in ipairs(queue) do
    if action.id == id then
      found = action
    end
  end
  Assert.notNil(found, "queue holds action " .. tostring(id))
  assert(found ~= nil, "queue holds the requested action")
  return found --[[@as table]]
end

function T.suspended_children_resume_without_replaying_completed_work()
  local ActionQueue = SessionFixture.requirePresent(
    "libs.battle.src.gen4.ActionQueue",
    "explicit queue mutation owns suspensions and resumptions"
  )
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local HgssSchedule =
    SessionFixture.requirePresent("libs.battle.src.gen4.HgssSchedule", "explicit cursors own native control flow")
  for _, name in ipairs({ "enqueue", "intercept", "suspend", "resume", "complete" }) do
    Assert.isTrue(type(ActionQueue[name]) == "function", "queue owns " .. name)
  end

  local stream = BattleRng.new(3)
  local before = stream:capture()

  local queue = {}
  ActionQueue.enqueue(queue, stagedAction(1, 1, "attack"))
  ActionQueue.enqueue(queue, stagedAction(2, 2, "switch"))
  Assert.equal(findAction(queue, 1).progress, "queued", "enqueued actions wait queued")
  Assert.equal(findAction(queue, 2).progress, "queued", "enqueued actions wait queued")

  ActionQueue.intercept(queue, 2, stagedAction(3, 1, "intercept"))
  Assert.equal(findAction(queue, 2).progress, "suspended", "intercepted parents suspend at the child boundary")
  local child = findAction(queue, 3)
  Assert.equal(child.parentActionId, 2, "children return to their causal parent")
  Assert.equal(child.progress, "queued", "intercepting children queue behind nothing else")

  local controlOk = pcall(HgssSchedule.validateFrame, freshFrame())
  Assert.isTrue(controlOk, "suspended control state keeps validating")

  local completed = pcall(ActionQueue.complete, queue, 2)
  Assert.isFalse(completed, "suspended parents never complete behind their child")

  ActionQueue.complete(queue, 3)
  Assert.equal(findAction(queue, 3).progress, "complete", "children complete exactly once")
  local repeated = pcall(ActionQueue.complete, queue, 3)
  Assert.isFalse(repeated, "completed work never runs twice")

  ActionQueue.resume(queue, 2)
  Assert.equal(findAction(queue, 2).progress, "queued", "resumed parents queue again")
  Assert.equal(findAction(queue, 3).parentActionId, 2, "completed children keep their causal parent")
  ActionQueue.complete(queue, 1)
  ActionQueue.complete(queue, 2)
  Assert.equal(findAction(queue, 1).progress, "complete", "parents finish after their child")
  Assert.equal(findAction(queue, 2).progress, "complete", "resumed parents finish once")
  local stale = pcall(ActionQueue.resume, queue, 3)
  Assert.isFalse(stale, "completed children never resume as stale actors")

  ActionQueue.enqueue(queue, stagedAction(4, 4, "switch"))
  ActionQueue.suspend(queue, 4)
  Assert.equal(findAction(queue, 4).progress, "suspended", "forced replacements suspend explicitly")
  local early = pcall(ActionQueue.complete, queue, 4)
  Assert.isFalse(early, "suspended replacements never complete before resuming")
  ActionQueue.resume(queue, 4)
  ActionQueue.complete(queue, 4)
  Assert.equal(findAction(queue, 4).progress, "complete", "resumed replacements finish once")

  local orphan = pcall(ActionQueue.intercept, queue, 99, stagedAction(5, 1, "intercept"))
  Assert.isFalse(orphan, "interceptions need a queued parent")
  local unknown = pcall(ActionQueue.complete, queue, 99)
  Assert.isFalse(unknown, "unknown actions never complete")

  Assert.deepEqual(stream:capture(), before, "queue suspensions never redraw the stream")
end

---@param HgssSchedule table explicit cursor owner under test
---@param ActionQueue table explicit queue mutation owner under test
---@param BattleRng table labeled stream owner under test
---@param ids integer[] action identities to queue in selection order
---@param budget integer operations each step may spend before yielding
---@return integer[] yielded action identities in drain order
---@return table stream snapshot after draining
local function drain(HgssSchedule, ActionQueue, BattleRng, ids, budget)
  local stream = BattleRng.new(21)
  local queue = {}
  for _, id in ipairs(ids) do
    ActionQueue.enqueue(queue, stagedAction(id, id, "attack"))
  end
  local frame = freshFrame()
  local valid = pcall(HgssSchedule.validateFrame, frame)
  Assert.isTrue(valid, "schedule frames validate before stepping")
  local yielded = {}
  for _ = 1, 64 do
    local action = HgssSchedule.step(queue, frame, stream, budget)
    if action == nil then
      break
    end
    yielded[#yielded + 1] = action.id
    ActionQueue.complete(queue, action.id)
  end
  return yielded, stream:capture()
end

function T.headless_progression_waits_only_for_missing_decisions()
  local HgssRuleset =
    SessionFixture.requirePresent("libs.battle.src.gen4.HgssRuleset", "native ruleset binding owns lifecycle handlers")
  local HgssSchedule =
    SessionFixture.requirePresent("libs.battle.src.gen4.HgssSchedule", "explicit cursors own native control flow")
  local ActionQueue = SessionFixture.requirePresent(
    "libs.battle.src.gen4.ActionQueue",
    "explicit queue mutation owns suspensions and resumptions"
  )
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  for _, name in ipairs({ "new", "initialize", "advanceFrame", "finalize" }) do
    Assert.isTrue(type(HgssRuleset[name]) == "function", "ruleset owns " .. name)
  end
  for _, name in ipairs({ "step", "validateFrame", "sourceCorrespondence" }) do
    Assert.isTrue(type(HgssSchedule[name]) == "function", "schedule owns " .. name)
  end

  local rejected = pcall(HgssRuleset.new, {})
  Assert.isFalse(rejected, "rulesets reject missing lifecycle handlers before gameplay")

  local malformed = pcall(HgssSchedule.validateFrame, { kind = "hgss:schedule" })
  Assert.isFalse(malformed, "malformed frames never step")
  local correspondence = HgssSchedule.sourceCorrespondence()
  Assert.isTrue(type(correspondence) == "table", "schedule publishes its native correspondence")
  Assert.isTrue(next(correspondence) ~= nil, "correspondence names at least one native behavior")

  -- No step anywhere takes a renderer: both drains below run headlessly.
  local narrow, narrowCalls = drain(HgssSchedule, ActionQueue, BattleRng, { 1, 2, 3 }, 1)
  local wide, wideCalls = drain(HgssSchedule, ActionQueue, BattleRng, { 1, 2, 3 }, 1000)
  Assert.deepEqual(narrow, { 1, 2, 3 }, "headless runs drain every queued action")
  Assert.deepEqual(wide, narrow, "operation budgets never change the drained sequence")
  Assert.deepEqual(wideCalls, narrowCalls, "operation budgets never change stream use")

  local stream = BattleRng.new(21)
  local queue = {}
  local frame = freshFrame()
  Assert.isNil(HgssSchedule.step(queue, frame, stream, 1), "missing decisions suspend instead of fabricating actions")
  ActionQueue.enqueue(queue, stagedAction(1, 1, "attack"))
  local resumed = HgssSchedule.step(queue, frame, stream, 1)
  Assert.notNil(resumed, "late decisions resume the suspended schedule")
  Assert.equal(resumed.id, 1, "resumed schedules yield the decided action")
end

function T.malformed_frames_and_queue_misuse_fail_loudly()
  local HgssRuleset =
    SessionFixture.requirePresent("libs.battle.src.gen4.HgssRuleset", "native ruleset binding owns lifecycle handlers")
  local HgssSchedule =
    SessionFixture.requirePresent("libs.battle.src.gen4.HgssSchedule", "explicit cursors own native control flow")
  local ActionQueue = SessionFixture.requirePresent(
    "libs.battle.src.gen4.ActionQueue",
    "explicit queue mutation owns suspensions and resumptions"
  )
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  Assert.throws(function()
    HgssSchedule.validateFrame({ kind = "other:schedule", version = 1, cursor = "opening", pendingFaints = {} })
  end, "frames carry the native schedule identity")
  Assert.throws(function()
    HgssSchedule.validateFrame({ kind = "hgss:schedule", version = 2, cursor = "opening", pendingFaints = {} })
  end, "frames carry the current version")
  Assert.throws(function()
    HgssSchedule.validateFrame({ kind = "hgss:schedule", version = 1, cursor = "", pendingFaints = {} })
  end, "frames name their cursor")
  Assert.throws(function()
    HgssSchedule.validateFrame({ kind = "hgss:schedule", version = 1, cursor = "opening" })
  end, "frames carry their pending faints")
  Assert.throws(function()
    HgssSchedule.step({}, { kind = "hgss:schedule" }, BattleRng.new(3), 1)
  end, "malformed frames never step")
  Assert.throws(function()
    HgssSchedule.step({}, freshFrame(), BattleRng.new(3), 0)
  end, "steps spend a positive operation budget")

  local queue = {}
  ActionQueue.enqueue(queue, stagedAction(1, 1, "attack"))
  local duplicate = pcall(ActionQueue.enqueue, queue, stagedAction(1, 1, "attack"))
  Assert.isFalse(duplicate, "staged identities never repeat while queued")
  Assert.isFalse(pcall(ActionQueue.suspend, queue, 99), "suspensions name a queued action")
  Assert.isFalse(pcall(ActionQueue.resume, queue, 1), "resumptions restart a suspended action")
  Assert.isFalse(pcall(ActionQueue.complete, queue, 99), "completions name a queued action")
  ActionQueue.suspend(queue, 1)
  local clash = pcall(ActionQueue.intercept, queue, 1, stagedAction(1, 1, "intercept"))
  Assert.isFalse(clash, "interceptions reuse no live identity")
  ActionQueue.resume(queue, 1)
  ActionQueue.complete(queue, 1)

  local function openTurn()
    return true
  end
  local function executeAction()
    return true
  end
  local function applyResiduals()
    return true
  end
  local function closeTurn()
    return true
  end
  local handlers = {
    openTurn = openTurn,
    executeAction = executeAction,
    applyResiduals = applyResiduals,
    closeTurn = closeTurn,
  }
  Assert.throws(function()
    HgssRuleset.new({
      openTurn = openTurn,
      executeAction = executeAction,
    })
  end, "rulesets bind every lifecycle handler before gameplay")
  local ruleset = HgssRuleset.new(handlers)
  Assert.equal(ruleset:handler("openTurn"), openTurn, "bindings expose their handlers")
  Assert.throws(function()
    ruleset:handler("missing")
  end, "handler reads name a bound lifecycle phase")
  Assert.throws(function()
    ruleset:advanceFrame({}, freshFrame(), BattleRng.new(3), 1)
  end, "rulesets advance only after binding")
  Assert.isTrue(ruleset:initialize({}), "bindings validate their session")
  Assert.throws(function()
    ruleset:initialize({})
  end, "rulesets bind once")
  Assert.isNil(ruleset:advanceFrame({}, freshFrame(), BattleRng.new(3), 1), "empty frames suspend")
  Assert.isTrue(ruleset:finalize(), "bindings release once")
  Assert.throws(function()
    ruleset:advanceFrame({}, freshFrame(), BattleRng.new(3), 1)
  end, "released rulesets advance nothing")
  Assert.throws(function()
    ruleset:finalize()
  end, "rulesets release once")
end

return { tests = T }
