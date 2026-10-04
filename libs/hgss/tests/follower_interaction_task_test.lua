-- The follower interaction task owns one serializable interaction lifetime.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local HgssComposition = require("libs.hgss.src.script.Composition")
local ScriptComposition = require("libs.script.src.Composition")
local Registry = require("libs.script.src.Registry")
local Scheduler = require("libs.script.src.Scheduler")
local ScriptSave = require("libs.script.src.ScriptSave")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local S = require("gen4.script")

local TASK_MODULE = "libs.hgss.src.script.tasks.FollowerInteractionTask"
local loaded, FollowerInteractionTask = pcall(require, TASK_MODULE)
if not loaded then
  local reason = tostring(FollowerInteractionTask)
  assert(reason:find("module '" .. TASK_MODULE .. "' not found", 1, true), reason)
  FollowerInteractionTask = nil
end

local T = {}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[copy(key)] = copy(child)
  end
  return result
end

-- Test fixture seam: the task receives its deterministic engine and borrowed field
-- collaborators through ctx.services. This is only a task test harness contract.
local function fixture(programs)
  local events = {}
  local selected = { leadSlot = 0, programId = 10 }
  local actor = { x = 12, z = 8, facing = "west", offset = { x = 0, y = 0, z = 0 } }
  local engine = {
    select = function()
      events[#events + 1] = "select"
      return selected
    end,
    program = function(_, programId)
      return assert(programs[programId], "fixture program exists")
    end,
    motion = function(_, motionId)
      return assert(programs.motions[motionId], "fixture motion exists")
    end,
    reaction = function(_, selector)
      return { selector = selector, kind = "test-follower-reaction" }
    end,
    bindings = function(_, _leadSlot)
      return { [0] = "Sparky", [1] = "EEVEE", [2] = "Red", [3] = "New Bark Town", [4] = "" }
    end,
    ignoresMotionVerticalOffset = function()
      return false
    end,
    applyDeltas = function(_, leadSlot, friendship, mood)
      events[#events + 1] = { "deltas", leadSlot, friendship, mood }
    end,
    reward = function(_, leadSlot, reward)
      events[#events + 1] = { "reward", leadSlot, reward.kind, reward.selector }
      return reward.outcome
    end,
  }
  local actors = {}
  function actors:isScriptedMoving(actorId)
    Assert.equal(actorId, "partner", "task checks the partner action before selection")
    return actor.motionActive == true
  end
  function actors:getFacing(actorId)
    Assert.equal(actorId, "partner", "task uses the existing partner actor")
    return actor.facing
  end
  function actors:setFacing(actorId, facing)
    Assert.equal(actorId, "partner")
    actor.facing = facing
    events[#events + 1] = { "facing", facing }
  end
  function actors:beginScriptedAction(actorId, action)
    Assert.equal(actorId, "partner")
    actor.motionActive = true
    actor.begins = (actor.begins or 0) + 1
    actor.offset = { x = action.x, y = action.y, z = action.z }
    events[#events + 1] = { "begin", action.x, action.y, action.z, action.ticks }
  end
  function actors:advanceScriptedAction(actorId, elapsed, duration)
    Assert.equal(actorId, "partner")
    events[#events + 1] = { "advance", elapsed, duration }
  end
  function actors:commitScriptedAction(actorId)
    Assert.equal(actorId, "partner")
    actor.motionActive = false
    actor.offset = { x = 0, y = 0, z = 0 }
    events[#events + 1] = "commit"
  end
  function actors:cancelScriptedMovement(actorId)
    Assert.equal(actorId, "partner")
    actor.motionActive = false
    actor.offset = { x = 0, y = 0, z = 0 }
    events[#events + 1] = "cancel-motion"
  end

  local dialogue = { open = false, messages = {}, finished = false, closes = 0 }
  function dialogue:isOpen()
    return self.open
  end
  function dialogue:openMessage(_node)
    self.open = true
  end
  function dialogue:startPrint(message, bindings)
    self.messages[#self.messages + 1] = { message = message, bindings = bindings }
  end
  function dialogue:printProgress()
    return { done = self.finished }
  end
  function dialogue:close()
    self.open = false
    self.closes = self.closes + 1
  end

  local choice = { active = false, selected = 0, opens = 0, closes = 0 }
  function choice:open(selected)
    self.active = true
    self.selected = selected
    self.opens = self.opens + 1
  end
  function choice:status()
    return self.active and { selected = self.selected } or nil
  end
  function choice:select(selected)
    self.selected = selected
    return selected
  end
  function choice:confirm()
    return self.selected
  end
  function choice:close()
    self.active = false
    self.closes = self.closes + 1
  end

  local audio = { played = {} }
  function audio:play(sound)
    self.played[#self.played + 1] = sound
  end
  local terrainEffects = { active = {}, removed = {} }
  function terrainEffects:emit(response)
    self.active[1] = response
    return 1
  end
  function terrainEffects:remove(handle)
    self.removed[#self.removed + 1] = handle
    self.active[handle] = nil
  end
  local world = {
    flags = {},
    setFlag = function(self, flag)
      self.flags[flag] = true
    end,
  }
  local mons = { friendship = 254, mood = 126, leaves = 0 }
  local ctx = {
    services = {
      followerInteraction = engine,
      followingMon = { partnerActorId = "partner" },
      actors = actors,
      dialogue = dialogue,
      contextChoice = choice,
      audio = audio,
      terrainEffects = terrainEffects,
      world = world,
      mons = mons,
    },
    input = {},
    instance = { scriptId = "interaction-test", instanceId = 1, textArgs = {} },
  }
  return ctx,
    {
      events = events,
      actor = actor,
      dialogue = dialogue,
      choice = choice,
      audio = audio,
      terrainEffects = terrainEffects,
      world = world,
      mons = mons,
    }
end

local function poll(task, state, ctx, count)
  local result
  for _ = 1, count do
    result = task.poll(state, ctx)
    if result.complete then
      return result
    end
  end
  return result
end

local function finish(task, state, ctx, seen)
  local result
  for _ = 1, 40 do
    seen.dialogue.finished = true
    ctx.input.pressedAction = true
    result = task.poll(state, ctx)
    if result.complete then
      return result
    end
  end
  return result
end

T["motion and dialogue preserve actor identity, offsets, facing, and substitutions"] = function()
  Assert.notNil(
    FollowerInteractionTask,
    "multi-step follower interaction execution is missing: no serialized task drives motion and dialogue"
  )
  local programs = {
    motions = {
      [4] = {
        { x = 1, y = 2, z = -1, facing = "north", ticks = 2, sound = "step" },
        { x = -2, y = 3, z = 1, facing = "east", ticks = 1 },
      },
    },
    [10] = {
      steps = { { motionId = 4, messageId = 7, delayTicks = 1 } },
      friendshipDelta = 0,
      moodDelta = 0,
      continuation = { choice0InteractionId = 11, choice1InteractionId = 11 },
    },
    [11] = { steps = {}, friendshipDelta = 0, moodDelta = 0 },
  }
  local ctx, seen = fixture(programs)
  local task = FollowerInteractionTask
  local state = task.create({}, ctx)
  Assert.isNil(task.validate(state), "new interaction task state is serializable")
  Assert.equal(state.programId, 10)
  Assert.equal(seen.actor.x, 12, "motion never changes logical actor X")
  Assert.equal(seen.actor.z, 8, "motion never changes logical actor Z")

  local initial = task.poll(state, ctx)
  Assert.isFalse(initial.complete)
  Assert.deepEqual(
    seen.actor.offset,
    { x = 1, y = 2, z = -1 },
    "the first record applies its render offset immediately"
  )
  Assert.equal(seen.actor.facing, "north", "the record applies its facing immediately")
  Assert.equal(seen.audio.played[1], "step", "record sound plays once at record start")

  state = copy(state)
  task.poll(state, ctx)
  task.poll(state, ctx)
  Assert.deepEqual(
    seen.actor.offset,
    { x = -1, y = 5, z = 0 },
    "later records add to the cumulative presentation offset"
  )
  Assert.equal(seen.actor.x, 12, "cumulative render motion leaves logical X unchanged")
  Assert.equal(seen.actor.z, 8, "cumulative render motion leaves logical Z unchanged")

  seen.dialogue.finished = true
  for _ = 1, 12 do
    task.poll(state, ctx)
  end
  Assert.equal(#seen.dialogue.messages, 1, "the selected step prints its message")
  local message = seen.dialogue.messages[1]
  Assert.equal(message.message.id, 7, "message id is already normalized")
  Assert.deepEqual(message.bindings, { [0] = "Sparky", [1] = "EEVEE", [2] = "Red", [3] = "New Bark Town", [4] = "" })
  Assert.equal(seen.actor.x, 12, "finished motion preserves logical X")
  Assert.equal(seen.actor.z, 8, "finished motion preserves logical Z")
  Assert.equal(seen.actor.facing, "west", "finished motion restores original facing")
  Assert.deepEqual(seen.actor.offset, { x = 0, y = 0, z = 0 }, "finished motion clears presentation offset")
end

T["continuation uses the selected target without selecting or rolling again"] = function()
  Assert.notNil(FollowerInteractionTask, "continuation execution is missing: no selected interaction task exists")
  local programs = {
    motions = {},
    [10] = {
      steps = {},
      friendshipDelta = 0,
      moodDelta = 0,
      continuation = { choice0InteractionId = 11, choice1InteractionId = 12 },
    },
    [11] = { steps = {}, friendshipDelta = 0, moodDelta = 0 },
    [12] = { steps = {}, friendshipDelta = 0, moodDelta = 0 },
  }
  local task = FollowerInteractionTask
  for selectedChoice, expectedProgram in ipairs({ 11, 12 }) do
    local ctx, seen = fixture(programs)
    local state = task.create({}, ctx)
    for _ = 1, 8 do
      task.poll(state, ctx)
      if seen.choice.active then
        break
      end
    end
    Assert.isTrue(seen.choice.active, "two-way continuation opens the existing choice host")
    seen.choice.selected = selectedChoice - 1
    ctx.input.uiEvents = { { type = "confirm" } }
    task.poll(state, ctx)
    Assert.equal(state.programId, expectedProgram, "each choice follows its named generated target")
    Assert.equal(#seen.events, 2, "only selection and first program deltas have happened")
    Assert.equal(seen.events[1], "select", "rule selection occurs once at task creation")
    Assert.deepEqual(seen.events[2], { "deltas", 0, 0, 0 })
    Assert.equal(seen.choice.opens, 1)
  end
end

T["interaction deltas precede Fashion success and full reward branches"] = function()
  Assert.notNil(FollowerInteractionTask, "Fashion reward execution is missing")
  local programs = {
    motions = {},
    [10] = {
      steps = {},
      friendshipDelta = 8,
      moodDelta = 5,
      reward = { kind = "fashion", selector = 4, outcome = "added" },
    },
    [20] = {
      steps = {},
      friendshipDelta = 8,
      moodDelta = 5,
      reward = { kind = "fashion", selector = 4, outcome = "full" },
    },
  }
  local task = FollowerInteractionTask
  local ctx, success = fixture(programs)
  local state = task.create({}, ctx)
  Assert.equal(finish(task, state, ctx, success).complete, true, "success reward task completes")
  Assert.deepEqual(success.events, {
    "select",
    { "deltas", 0, 8, 5 },
    { "reward", 0, "fashion", 4 },
  }, "deltas commit before Fashion inventory mutation")
  Assert.equal(success.dialogue.messages[1].message.bank, 40)
  Assert.equal(success.dialogue.messages[1].message.id, 32)
  Assert.deepEqual(success.dialogue.messages[1].bindings, { "Red", "Accessory" })
  Assert.deepEqual(success.audio.played, { "SEQ_ME_ACCE" })

  local fullCtx, full = fixture(programs)
  fullCtx.services.followerInteraction.select = function()
    full.events[#full.events + 1] = "select"
    return { leadSlot = 0, programId = 20 }
  end
  local fullState = task.create({}, fullCtx)
  Assert.equal(finish(task, fullState, fullCtx, full).complete, true, "full reward task completes")
  Assert.deepEqual(full.events, {
    "select",
    { "deltas", 0, 8, 5 },
    { "reward", 0, "fashion", 4 },
  })
  Assert.equal(full.dialogue.messages[1].message.bank, 40)
  Assert.equal(full.dialogue.messages[1].message.id, 95)
  Assert.deepEqual(full.dialogue.messages[1].bindings, { "Red", "an Accessory" })
  Assert.equal(#full.audio.played, 0, "full Fashion Case has no success fanfare")
end

T["new and duplicate Shiny Leaf branches have exact durable effects"] = function()
  Assert.notNil(FollowerInteractionTask, "Shiny Leaf reward execution is missing")
  local programs = {
    motions = {},
    [10] = {
      steps = {},
      friendshipDelta = 0,
      moodDelta = 0,
      reward = { kind = "leaf", selector = 2, outcome = "new" },
    },
    [20] = {
      steps = {},
      friendshipDelta = 0,
      moodDelta = 0,
      reward = { kind = "leaf", selector = 2, outcome = "duplicate" },
    },
  }
  local task = FollowerInteractionTask
  local ctx, fresh = fixture(programs)
  local state = task.create({}, ctx)
  Assert.equal(finish(task, state, ctx, fresh).complete, true)
  Assert.isTrue(fresh.world.flags[0x99C], "new leaf sets the retail world flag")
  Assert.deepEqual(fresh.events[3], { "reward", 0, "leaf", 2 })
  Assert.equal(fresh.dialogue.messages[1].message.id, 97)
  Assert.deepEqual(fresh.dialogue.messages[1].bindings, { "Red", "Sparky" })
  Assert.equal(fresh.audio.played[1], "SEQ_ME_ACCE")

  local duplicateCtx, duplicate = fixture(programs)
  duplicateCtx.services.followerInteraction.select = function()
    duplicate.events[#duplicate.events + 1] = "select"
    return { leadSlot = 0, programId = 20 }
  end
  local duplicateState = task.create({}, duplicateCtx)
  Assert.equal(finish(task, duplicateState, duplicateCtx, duplicate).complete, true)
  Assert.equal(next(duplicate.world.flags), nil, "duplicate leaf does not set its award flag")
  Assert.equal(duplicate.dialogue.messages[1].message.id, 98)
  Assert.equal(#duplicate.audio.played, 0, "duplicate leaf has no award fanfare")
end

T["cancellation during motion clears the offset and restores facing"] = function()
  Assert.notNil(FollowerInteractionTask, "interaction cancellation cleanup is missing")
  local programs = {
    motions = { [4] = { { x = 1, y = 1, z = 0, facing = "north", ticks = 5 } } },
    [10] = { steps = { { motionId = 4, messageId = 1 } }, friendshipDelta = 0, moodDelta = 0 },
  }
  local ctx, seen = fixture(programs)
  local task = FollowerInteractionTask
  local state = task.create({}, ctx)
  task.poll(state, ctx)
  Assert.deepEqual(seen.actor.offset, { x = 1, y = 1, z = 0 })
  task.cancel(state, "test cancellation", ctx)
  Assert.deepEqual(seen.actor.offset, { x = 0, y = 0, z = 0 }, "cancel releases transient actor offset")
  Assert.equal(seen.actor.facing, "west", "cancel restores the saved facing")
  Assert.isFalse(seen.dialogue.open, "cancel closes an open task-owned message")
  Assert.isFalse(seen.choice.active, "cancel closes an open continuation")
end

T["cancellation during dialogue closes dialogue and removes reaction effect"] = function()
  Assert.notNil(FollowerInteractionTask, "interaction cancellation cleanup is missing")
  local programs = {
    motions = {},
    [10] = {
      steps = { { messageId = 1, reactionSelector = 3 } },
      friendshipDelta = 0,
      moodDelta = 0,
    },
  }
  local ctx, seen = fixture(programs)
  local task = FollowerInteractionTask
  local state = task.create({}, ctx)
  task.poll(state, ctx)
  Assert.isTrue(seen.dialogue.open, "the task owns an open dialogue while printing")
  Assert.notNil(seen.terrainEffects.active[1], "the reaction effect is active before cancellation")
  task.cancel(state, "test cancellation", ctx)
  Assert.isFalse(seen.dialogue.open, "cancel closes the active task-owned dialogue")
  Assert.deepEqual(seen.terrainEffects.removed, { 1 }, "cancel removes its task-owned reaction effect")
  Assert.equal(seen.actor.facing, "west", "cancel restores saved partner facing")
  Assert.deepEqual(seen.actor.offset, { x = 0, y = 0, z = 0 }, "cancel leaves no presentation offset")
end

T["cancellation during continuation closes the active choice"] = function()
  Assert.notNil(FollowerInteractionTask, "interaction continuation cancellation cleanup is missing")
  local programs = {
    motions = {},
    [10] = {
      steps = {},
      friendshipDelta = 0,
      moodDelta = 0,
      continuation = { choice0InteractionId = 11, choice1InteractionId = 11 },
    },
    [11] = { steps = {}, friendshipDelta = 0, moodDelta = 0 },
  }
  local ctx, seen = fixture(programs)
  local task = FollowerInteractionTask
  local state = task.create({}, ctx)
  for _ = 1, 8 do
    task.poll(state, ctx)
    if seen.choice.active then
      break
    end
  end
  Assert.isTrue(seen.choice.active, "the continuation owns an active choice before cancellation")
  task.cancel(state, "test cancellation", ctx)
  Assert.isFalse(seen.choice.active, "cancel closes the active task-owned choice")
  Assert.equal(seen.choice.closes, 1, "active choice closes exactly once")
  Assert.equal(seen.actor.facing, "west", "cancel restores saved partner facing")
  Assert.deepEqual(seen.actor.offset, { x = 0, y = 0, z = 0 }, "cancel leaves no presentation offset")
end

T["task state is plain serialized data and rejects invalid fields or phases"] = function()
  Assert.notNil(FollowerInteractionTask, "serialized follower interaction state validation is missing")
  local task = FollowerInteractionTask
  local ctx, _seen = fixture({ motions = {}, [10] = { steps = {}, friendshipDelta = 0, moodDelta = 0 } })
  local state = task.create({}, ctx)
  Assert.isNil(task.validate(state), "task state validates before serialization")
  local restored = copy(state)
  Assert.isNil(task.validate(restored), "serialized task state validates after restore")
  local maximumOffset = copy(restored)
  maximumOffset.cumulativeX = -1280
  Assert.isNil(task.validate(maximumOffset), "the full source motion range remains serializable")
  Assert.isNil(restored.engine, "task state contains no engine pointer")
  Assert.isNil(restored.actor, "task state contains no actor/controller pointer")

  local unknown = copy(restored)
  unknown.unexpected = true
  Assert.isTrue(Errors.is(task.validate(unknown)), "unknown task state fields are rejected")
  local invalidPhase = copy(restored)
  invalidPhase.phase = "not-a-phase"
  Assert.isTrue(Errors.is(task.validate(invalidPhase)), "unknown task phases are rejected")
  local invalidIndex = copy(restored)
  invalidIndex.stepIndex = -1
  Assert.isTrue(Errors.is(task.validate(invalidIndex)), "negative step indices are rejected")
  local pointer = copy(restored)
  pointer.foreign = function() end
  Assert.isTrue(Errors.is(task.validate(pointer)), "non-serializable state is rejected")

  local invalidStates = {
    { field = "stepIndex", value = 7 },
    { field = "motionId", value = 109 },
    { field = "motionIndex", value = 0 },
    { field = "motionIndex", value = 11 },
    { field = "motionTick", value = math.huge },
    { field = "cumulativeX", value = 0 / 0 },
    { field = "cumulativeY", value = math.huge },
    { field = "cumulativeZ", value = -math.huge },
    { field = "cumulativeX", value = 1281 },
    { field = "cumulativeY", value = -1281 },
    { field = "savedFacing", value = "northeast" },
    { field = "motionStarted", value = 1 },
    { field = "rewardStarted", value = "yes" },
    { field = "effectSelector", value = 15 },
    { field = "effectId", value = 1 },
    { field = "soundId", value = {} },
    { field = "delayRemaining", value = -1 },
    { field = "choiceTargets", value = { 1 } },
    { field = "dialogueState", value = { phase = "missing" } },
    { field = "choiceState", value = { active = true, selected = 3, phase = "waiting" } },
  }
  for _, vector in ipairs(invalidStates) do
    local corrupt = copy(restored)
    corrupt[vector.field] = vector.value
    Assert.isTrue(Errors.is(task.validate(corrupt)), vector.field .. " rejects malformed serialized values")
  end
end

T["reward restore state requires a completed reward mutation and its dialogue"] = function()
  Assert.notNil(FollowerInteractionTask, "reward restore validation is missing")
  local task = FollowerInteractionTask
  local ctx, seen = fixture({
    motions = {},
    [10] = {
      steps = {},
      friendshipDelta = 0,
      moodDelta = 0,
      reward = { kind = "fashion", selector = 4, outcome = "added" },
    },
  })
  local state = task.create({}, ctx)
  task.poll(state, ctx)
  Assert.equal(state.phase, "reward", "reward dialogue remains in the reward phase")
  Assert.isTrue(state.rewardStarted, "inventory mutation is recorded before reward dialogue")
  Assert.notNil(state.dialogueState, "reward dialogue is saved with the mutation")
  Assert.equal(#seen.events, 3, "the reward mutation occurred once")
  Assert.isNil(task.validate(state), "a reward with its pending dialogue is valid")

  local missingDialogue = copy(state)
  missingDialogue.dialogueState = nil
  Assert.isTrue(
    Errors.is(task.validate(missingDialogue)),
    "a completed reward cannot resume without its dialogue task"
  )

  local repeatedMutation = copy(state)
  repeatedMutation.rewardStarted = false
  Assert.isTrue(
    Errors.is(task.validate(repeatedMutation)),
    "a saved reward dialogue cannot resume before the reward mutation is marked complete"
  )
end

T["reaction dialogue restore recreates presentation without serializing its handle"] = function()
  Assert.notNil(FollowerInteractionTask, "reaction presentation restore is missing")
  local programs = {
    motions = {},
    [10] = {
      steps = { { messageId = 1, reactionSelector = 3 } },
      friendshipDelta = 0,
      moodDelta = 0,
    },
  }
  local task = FollowerInteractionTask
  local ctx, seen = fixture(programs)
  local state = task.create({}, ctx)
  task.poll(state, ctx)
  Assert.equal(state.phase, "dialogue", "the reaction is active while its message is open")
  Assert.equal(#seen.terrainEffects.removed, 0)

  local saved = copy(state)
  Assert.isNil(saved.effectId, "the runtime effect handle is absent from serialized task state")

  local resumedCtx, resumedSeen = fixture(programs)
  task.poll(saved, resumedCtx)
  Assert.equal(saved.phase, "dialogue", "restored dialogue remains active")
  Assert.equal(resumedSeen.terrainEffects.active[1].kind, "test-follower-reaction")
  Assert.equal(saved.effectSelector, 3, "the semantic selector survives restore")
end

T["mid-motion task restore rebuilds the derived partner action without replaying effects"] = function()
  local resource = S.script({
    api = 1,
    id = "test.follower_interaction_save",
    steps = { S.followerInteract(), S.setFlag({ flag = "FLAG_RESUMED" }), S.stop() },
  })
  local function harness()
    local ctx, seen = fixture({
      motions = { [4] = { { x = 2, y = 3, z = -1, facing = "north", ticks = 4, sound = "motion-start" } } },
      [10] = { steps = { { motionId = 4 } }, friendshipDelta = 0, moodDelta = 0 },
    })
    local registry = Registry.new()
    local composition = ScriptComposition.new(registry)
    registry:installBase(resource.id, resource, "generated")
    local taskRegistry = HgssComposition.registerTasks(TaskRegistry.new())
    local scheduler = Scheduler.new({
      semantics = HgssComposition.semantics(),
      services = ctx.services,
      taskRegistry = taskRegistry,
      resolveComposition = function(id)
        return composition:effective(id)
      end,
    })
    return { ctx = ctx, seen = seen, registry = registry, composition = composition, scheduler = scheduler }
  end

  local original = harness()
  local instanceId = original.scheduler:createForeground(assert(original.composition:effective(resource.id)), nil, 100)
  original.scheduler:step(100, {})
  original.scheduler:step(101, {})
  original.scheduler:step(102, {})
  local runningTask = assert(original.scheduler:tasks()[1], "the interaction task is running")
  Assert.equal(runningTask.state.phase, "motion")
  Assert.isTrue(runningTask.state.motionStarted, "the task has begun the render-only motion")
  Assert.equal(runningTask.state.motionTick, 1, "one motion tick has elapsed before capture")
  Assert.deepEqual(original.seen.actor.offset, { x = 2, y = 3, z = -1 })
  Assert.deepEqual(original.seen.audio.played, { "motion-start" }, "motion sound has played once")
  local bucket = ScriptSave.capture(original.scheduler, 102, { registryFingerprint = original.registry:fingerprint() })
  Assert.equal(#bucket.tasks, 1, "the blocked interaction task is captured")
  Assert.equal(bucket.tasks[1].taskType, "follower_interaction")
  Assert.equal(bucket.tasks[1].taskVersion, 1)
  Assert.equal(bucket.tasks[1].state.phase, "motion")

  local resumed = harness()
  ScriptSave.restore(bucket, resumed.scheduler, 102, {})
  local task = assert(resumed.scheduler:tasks()[1], "the active interaction task restores")
  Assert.equal(task.taskType, bucket.tasks[1].taskType)
  Assert.equal(task.taskVersion, bucket.tasks[1].taskVersion)
  Assert.deepEqual(task.state, bucket.tasks[1].state, "the active interaction state survives the save round trip")
  Assert.isFalse(resumed.seen.actor.motionActive, "the derived partner action is absent after reconstruction")
  Assert.deepEqual(
    resumed.seen.actor.offset,
    { x = 0, y = 0, z = 0 },
    "actor persistence omits transient partner presentation"
  )

  resumed.scheduler:step(103, {})
  Assert.isTrue(resumed.seen.actor.motionActive, "the restored task rebuilds its missing actor action")
  Assert.deepEqual(resumed.seen.actor.offset, { x = 2, y = 3, z = -1 }, "resume restores the current cumulative offset")
  Assert.equal(resumed.seen.actor.begins, 1, "resume begins the presentation action exactly once")
  Assert.deepEqual(resumed.seen.audio.played, {}, "resume does not replay the motion sound")
  Assert.equal(task.state.motionTick, 2, "resume continues from the saved elapsed tick")
  for tick = 104, 110 do
    if task.status == "completed" then
      break
    end
    resumed.scheduler:step(tick, {})
  end
  Assert.equal(task.status, "completed", "the restored interaction finishes at its original duration")
  Assert.deepEqual(resumed.seen.actor.offset, { x = 0, y = 0, z = 0 }, "completion clears the transient offset")
  resumed.scheduler:step(111, {})
  Assert.isTrue(resumed.seen.world.flags.FLAG_RESUMED, "the script resumes after the restored task completes")
end

return { tests = T }
