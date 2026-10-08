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
local REACTION_TICKS = 4

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
local function fixture(programs, options)
  options = options or {}
  local events = {}
  local selected = { leadSlot = 0, programId = 10 }
  local actor = {
    x = 12,
    z = 8,
    worldY = 2.5,
    cellKey = "upper",
    sourceSurfaceId = 9,
    facing = "west",
    offset = { x = 0, y = 0, z = 0 },
  }
  local anchorReads = 0
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
      Assert.equal(selector, 3, "fixture programs use reaction selector 3")
      return { kind = "test-follower-reaction", ticks = REACTION_TICKS }
    end,
    partnerMetatileBehavior = function()
      return options.metatileBehavior or 0
    end,
    partnerEffectAnchor = function()
      anchorReads = anchorReads + 1
      return {
        fieldX = actor.x,
        fieldZ = actor.z,
        worldY = actor.worldY,
        cellKey = "upper-" .. anchorReads,
        sourceSurfaceId = actor.sourceSurfaceId + anchorReads - 1,
      }
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
    actor.actionX, actor.actionY, actor.actionZ = action.x, action.y, action.z
    actor.offset = { x = 0, y = 0, z = 0 }
    if action.action == "emote" then
      events[#events + 1] = { "emote", action.name, action.ticks }
    else
      events[#events + 1] = { "begin", action.x, action.y, action.z, action.ticks }
    end
  end
  function actors:advanceScriptedAction(actorId, elapsed, duration)
    Assert.equal(actorId, "partner")
    events[#events + 1] = { "advance", elapsed, duration }
    if elapsed < duration and actor.motionActive then
      actor.offset = { x = actor.actionX, y = actor.actionY, z = actor.actionZ }
    else
      actor.offset = { x = 0, y = 0, z = 0 }
    end
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

  local audio = { played = {}, cries = {}, effectWaitComplete = true }
  function audio:play(sound)
    self.played[#self.played + 1] = sound
  end
  function audio:playCry(species, pattern)
    self.cries[#self.cries + 1] = { species, pattern }
  end
  function audio:isEffectWaitComplete(effect)
    Assert.equal(effect, "SEQ_ME_ACCE")
    return self.effectWaitComplete
  end
  local terrainEffects = { active = {}, removed = {}, emitted = {} }
  function terrainEffects:emit(response)
    local handle = #self.emitted + 1
    self.emitted[handle] = response
    self.active[handle] = response
    return handle
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
  local mons = {
    friendship = 254,
    mood = 126,
    leaves = 0,
    speciesBySlot = { [0] = 133, [1] = 25 },
    partyMonSpecies = function(self, slot)
      self.lastSpeciesSlot = slot
      return self.speciesBySlot[slot]
    end,
  }
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
      mons = mons,
      terrainEffects = terrainEffects,
      world = world,
      anchorReads = function()
        return anchorReads
      end,
    }
end

local function emoteBegins(seen)
  local begins = {}
  for _, event in ipairs(seen.events) do
    if type(event) == "table" and event[1] == "emote" then
      begins[#begins + 1] = event
    end
  end
  return begins
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
        { x = 1, y = 2, z = -1, facing = "north", ticks = 2, sound = true },
        { x = -2, y = 3, z = 1, facing = "east", ticks = 1 },
      },
    },
    [10] = {
      steps = { { motionId = 4, messageId = 7, delayTicks = 1, sound = { kind = "effect", id = 42 } } },
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
  Assert.equal(seen.audio.played[1], 42, "record sound plays once at record start")

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

T["one-tick motion advances presentation before yielding"] = function()
  local programs = {
    motions = { [4] = { { x = 0.0625, y = 0, z = 0, ticks = 1 } } },
    [10] = { steps = { { motionId = 4 } }, friendshipDelta = 0, moodDelta = 0 },
  }
  local ctx, seen = fixture(programs)
  local state = FollowerInteractionTask.create({}, ctx)
  local result = FollowerInteractionTask.poll(state, ctx)
  Assert.isFalse(result.complete, "the one-tick action yields after its visible interval begins")
  Assert.deepEqual(seen.actor.offset, { x = 0.0625, y = 0, z = 0 })
  Assert.isTrue(
    seen.events[3][1] == "advance" and seen.events[3][2] == 0,
    "the task advances progress zero immediately after beginning the action"
  )
end

T["motionless normalized step opens its already-normalized message"] = function()
  local programs = {
    motions = {},
    [10] = { steps = { { messageId = 0 } }, friendshipDelta = 0, moodDelta = 0 },
  }
  local ctx, seen = fixture(programs)
  local state = FollowerInteractionTask.create({}, ctx)
  FollowerInteractionTask.poll(state, ctx)
  Assert.equal(seen.dialogue.messages[1].message.id, 0, "the semantic message ID is used directly")
  Assert.equal(seen.actor.begins or 0, 0, "an absent motion stays absent")
end

T["tagged motion sounds dispatch effects and cries through their existing services"] = function()
  local function dispatch(sound, leadSlot)
    local programs = {
      motions = { [4] = { { x = 0, y = 0, z = 0, ticks = 1, sound = true } } },
      [10] = { steps = { { motionId = 4, sound = sound } }, friendshipDelta = 0, moodDelta = 0 },
    }
    local ctx, seen = fixture(programs)
    ctx.services.followerInteraction.select = function()
      return { leadSlot = leadSlot or 0, programId = 10 }
    end
    local state = FollowerInteractionTask.create({}, ctx)
    seen.mons.speciesBySlot[0] = 151
    FollowerInteractionTask.poll(state, ctx)
    return seen
  end

  local effect = dispatch({ kind = "effect", id = 42 }, 1)
  Assert.deepEqual(effect.audio.played, { 42 }, "tagged effects use play(id)")
  Assert.deepEqual(effect.audio.cries, {}, "effect dispatch does not call the cry service")

  local ordinaryCry = dispatch({ kind = "cry", pattern = 0 }, 1)
  Assert.deepEqual(ordinaryCry.audio.cries, { { 25, 0 } }, "the captured lead slot supplies the native cry species")
  Assert.equal(ordinaryCry.mons.lastSpeciesSlot, 1, "cry dispatch keeps the selected lead slot")
  Assert.deepEqual(ordinaryCry.audio.played, {}, "cry dispatch does not treat its tag as an effect ID")

  local patternCry = dispatch({ kind = "cry", pattern = 11 }, 1)
  Assert.deepEqual(patternCry.audio.cries, { { 25, 11 } }, "the alternate cry pattern is preserved")
end

T["reward dialogue stays open until acquisition fanfare and needs a fresh edge"] = function()
  local programs = {
    motions = {},
    [10] = {
      steps = {},
      friendshipDelta = 0,
      moodDelta = 0,
      reward = { kind = "fashion", selector = 4, outcome = "added" },
    },
  }
  local ctx, seen = fixture(programs)
  seen.audio.effectWaitComplete = false
  local state = FollowerInteractionTask.create({}, ctx)
  for _ = 1, 8 do
    FollowerInteractionTask.poll(state, ctx)
    if state.dialogueState ~= nil then
      break
    end
  end
  Assert.deepEqual(seen.audio.played, { "SEQ_ME_ACCE" }, "the reward effect starts once")
  Assert.notNil(state.dialogueState, "the reward dialogue is active before completion")
  seen.dialogue.finished = true
  for _ = 1, 4 do
    ctx.input.pressedAction = true
    FollowerInteractionTask.poll(state, ctx)
  end
  ctx.input.pressedAction = false
  Assert.notNil(state.dialogueState, "action presses cannot close reward dialogue before fanfare completion")
  Assert.isTrue(seen.dialogue.open, "the reward dialogue remains open through the fanfare")
  Assert.equal(seen.dialogue.closes, 0, "the dialogue host has not been closed")
  Assert.isNil(FollowerInteractionTask.validate(state), "the pending reward dialogue remains valid task state")
  state = copy(state)
  Assert.isFalse(FollowerInteractionTask.poll(state, ctx).complete, "the active acquisition effect keeps input gated")
  seen.audio.effectWaitComplete = true
  Assert.isFalse(FollowerInteractionTask.poll(state, ctx).complete, "fanfare completion alone does not reuse an old press")
  Assert.notNil(state.dialogueState, "the dialogue still awaits a fresh input edge")
  ctx.input.pressedAction = true
  Assert.isFalse(FollowerInteractionTask.poll(state, ctx).complete, "a fresh edge starts the ordinary close delay")
  ctx.input.pressedAction = false
  Assert.isTrue(FollowerInteractionTask.poll(state, ctx).complete, "the fresh edge closes dialogue through its task")
  Assert.equal(seen.dialogue.closes, 1, "the dialogue host closes once")
  Assert.deepEqual(seen.audio.played, { "SEQ_ME_ACCE" }, "repeated polls do not replay the reward effect")
end

T["reaction emotes are suppressed only on retail reaction-blocking tiles"] = function()
  for _, behavior in ipairs({ 46, 113, 114, 0, 2, 3 }) do
    local programs = {
      motions = {},
      [10] = { steps = { { messageId = 1, reactionId = 3 } }, friendshipDelta = 0, moodDelta = 0 },
    }
    local ctx, seen = fixture(programs, { metatileBehavior = behavior })
    local state = FollowerInteractionTask.create({}, ctx)
    poll(FollowerInteractionTask, state, ctx, REACTION_TICKS)
    Assert.equal(
      #emoteBegins(seen),
      (behavior == 46 or behavior == 113 or behavior == 114) and 0 or 1,
      "reaction emote count for metatile behavior " .. behavior
    )
    Assert.equal(state.phase, "dialogue", "reaction suppression preserves message progression")
    Assert.isTrue(seen.dialogue.open, "the interaction message continues on behavior " .. behavior)
  end
end

T["a reaction plays as a partner emote that finishes before the interaction message"] = function()
  local programs = {
    motions = {},
    [10] = { steps = { { messageId = 1, reactionId = 3 } }, friendshipDelta = 0, moodDelta = 0 },
  }
  local ctx, seen = fixture(programs)
  local task = FollowerInteractionTask
  local state = task.create({}, ctx)
  task.poll(state, ctx)
  Assert.deepEqual(
    emoteBegins(seen),
    { { "emote", "test-follower-reaction", REACTION_TICKS } },
    "the reaction begins one partner emote action with its clip-derived duration"
  )
  Assert.isFalse(seen.dialogue.open, "the message waits for the reaction like the source subtask")
  for tick = 2, REACTION_TICKS - 1 do
    task.poll(state, ctx)
    Assert.isFalse(seen.dialogue.open, "the message stays closed through reaction tick " .. tick)
  end
  local advances = {}
  for _, event in ipairs(seen.events) do
    if type(event) == "table" and event[1] == "advance" then
      advances[#advances + 1] = event[2]
    end
  end
  Assert.deepEqual(advances, { 1, 2, 3 }, "each fixed tick advances the emote exactly once")
  task.poll(state, ctx)
  Assert.equal(seen.events[#seen.events], "commit", "the emote completes on its final tick")
  Assert.isFalse(seen.actor.motionActive, "the partner action is committed before the message")
  Assert.equal(state.phase, "dialogue", "the message starts once the reaction completes")
  Assert.isTrue(seen.dialogue.open, "the interaction message opens after the reaction")
end

T["interaction turns emit grass effects only for actual facing changes"] = function()
  local function emissions(behavior)
    local programs = {
      motions = {
        [4] = {
          { x = 0, y = 0, z = 0, facing = "north", ticks = 0 },
          { x = 0, y = 0, z = 0, facing = "north", ticks = 0 },
          { x = 0, y = 0, z = 0, facing = 0, ticks = 0 },
        },
      },
      [10] = { steps = { { motionId = 4, messageId = 1 } }, friendshipDelta = 0, moodDelta = 0 },
    }
    local ctx, seen = fixture(programs, { metatileBehavior = behavior })
    local state = FollowerInteractionTask.create({}, ctx)
    for _ = 1, 8 do
      FollowerInteractionTask.poll(state, ctx)
      if state.phase == "dialogue" then
        break
      end
    end
    return seen.terrainEffects.emitted, seen.actor.facing, seen.anchorReads()
  end

  for _, vector in ipairs({
    { behavior = 2, kind = "tall_grass" },
    { behavior = 3, kind = "very_tall_grass" },
  }) do
    local emitted, facing, reads = emissions(vector.behavior)
    Assert.equal(#emitted, 2, "one motion turn and normal facing restoration emit two effects")
    Assert.equal(emitted[1].kind, vector.kind)
    Assert.equal(emitted[1].direction, "north", "effect direction follows the new motion facing")
    Assert.equal(emitted[1].fieldX, 12)
    Assert.equal(emitted[1].fieldZ, 8)
    Assert.equal(emitted[1].worldY, 2.5)
    Assert.equal(emitted[1].cellKey, "upper-1")
    Assert.equal(emitted[1].sourceSurfaceId, 9)
    Assert.equal(emitted[2].kind, vector.kind, "normal facing restoration disturbs the same grass")
    Assert.equal(emitted[2].direction, "west", "restoration effect uses the restored facing")
    Assert.equal(emitted[2].cellKey, "upper-2", "each emission reacquires the current committed anchor")
    Assert.equal(emitted[2].sourceSurfaceId, 10)
    Assert.equal(reads, 2, "the task requests one engine anchor per terrain effect")
    Assert.equal(facing, "west")
  end
  local ordinary, _facing = emissions(0)
  Assert.equal(#ordinary, 0, "ordinary terrain emits no turn-grass effects")
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
  local ctx, seen = fixture(programs, { metatileBehavior = 2 })
  local task = FollowerInteractionTask
  local state = task.create({}, ctx)
  task.poll(state, ctx)
  Assert.deepEqual(seen.actor.offset, { x = 1, y = 1, z = 0 })
  Assert.equal(#seen.terrainEffects.emitted, 1, "the actual interaction turn disturbs the grass once")
  task.cancel(state, "test cancellation", ctx)
  Assert.deepEqual(seen.actor.offset, { x = 0, y = 0, z = 0 }, "cancel releases transient actor offset")
  Assert.equal(seen.actor.facing, "west", "cancel restores the saved facing")
  Assert.equal(#seen.terrainEffects.emitted, 1, "cancellation does not synthesize a restoration grass turn")
  Assert.isFalse(seen.dialogue.open, "cancel closes an open task-owned message")
  Assert.isFalse(seen.choice.active, "cancel closes an open continuation")
end

T["cancellation during a reaction cancels the partner emote"] = function()
  local programs = {
    motions = {},
    [10] = {
      steps = { { messageId = 1, reactionId = 3 } },
      friendshipDelta = 0,
      moodDelta = 0,
    },
  }
  local ctx, seen = fixture(programs)
  local task = FollowerInteractionTask
  local state = task.create({}, ctx)
  task.poll(state, ctx)
  Assert.isTrue(seen.actor.motionActive, "the reaction emote is active before cancellation")
  task.cancel(state, "test cancellation", ctx)
  Assert.isFalse(seen.actor.motionActive, "cancel ends the task-owned reaction emote")
  Assert.isFalse(seen.dialogue.open, "a cancelled reaction never opens its message")
  Assert.equal(seen.actor.facing, "west", "cancel restores saved partner facing")
end

T["cancellation during dialogue closes dialogue"] = function()
  local programs = {
    motions = {},
    [10] = {
      steps = { { messageId = 1 } },
      friendshipDelta = 0,
      moodDelta = 0,
    },
  }
  local ctx, seen = fixture(programs)
  local task = FollowerInteractionTask
  local state = task.create({}, ctx)
  task.poll(state, ctx)
  Assert.isTrue(seen.dialogue.open, "the task owns an open dialogue while printing")
  task.cancel(state, "test cancellation", ctx)
  Assert.isFalse(seen.dialogue.open, "cancel closes the active task-owned dialogue")
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
  maximumOffset.cumulativeX = -80
  Assert.isNil(task.validate(maximumOffset), "the normalized motion range remains serializable")
  maximumOffset.cumulativeX = -80.0625
  Assert.isTrue(Errors.is(task.validate(maximumOffset)), "offsets outside the normalized motion range are rejected")
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
    { field = "cumulativeX", value = 0.01 },
    { field = "cumulativeY", value = math.huge },
    { field = "cumulativeZ", value = -math.huge },
    { field = "cumulativeX", value = 1281 },
    { field = "cumulativeY", value = -1281 },
    { field = "savedFacing", value = "northeast" },
    { field = "motionStarted", value = 1 },
    { field = "rewardStarted", value = "yes" },
    { field = "reactionTick", value = 0 },
    { field = "reactionTick", value = 1.5 },
    { field = "reactionTick", value = 1 },
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

T["reaction restore rebuilds the derived partner emote at its saved tick"] = function()
  local programs = {
    motions = {},
    [10] = {
      steps = { { messageId = 1, reactionId = 3 } },
      friendshipDelta = 0,
      moodDelta = 0,
    },
  }
  local task = FollowerInteractionTask
  local ctx = fixture(programs)
  local state = task.create({}, ctx)
  task.poll(state, ctx)
  task.poll(state, ctx)
  Assert.equal(state.phase, "reaction", "the reaction is still presenting")
  Assert.equal(state.reactionTick, 2, "the reaction's progress is serialized")

  local saved = copy(state)
  Assert.isNil(task.validate(saved), "a mid-reaction task state is serializable")
  local resumedCtx, resumedSeen = fixture(programs)
  task.poll(saved, resumedCtx)
  Assert.deepEqual(
    emoteBegins(resumedSeen),
    { { "emote", "test-follower-reaction", REACTION_TICKS } },
    "restore rebuilds the derived partner emote once"
  )
  Assert.deepEqual(resumedSeen.events[#resumedSeen.events], { "advance", 3, REACTION_TICKS })
  task.poll(saved, resumedCtx)
  Assert.equal(saved.phase, "dialogue", "the restored reaction completes into its message")
end

T["mid-motion task restore rebuilds the derived partner action without replaying effects"] = function()
  local resource = S.script({
    api = 1,
    id = "test.follower_interaction_save",
    steps = { S.followerInteract(), S.setFlag({ flag = "FLAG_RESUMED" }), S.stop() },
  })
  local function harness()
    local ctx, seen = fixture({
      motions = { [4] = { { x = 2, y = 3, z = -1, facing = "north", ticks = 4, sound = true } } },
      [10] = { steps = { { motionId = 4, sound = { kind = "effect", id = 43 } } }, friendshipDelta = 0, moodDelta = 0 },
    }, { metatileBehavior = 2 })
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
  Assert.deepEqual(original.seen.audio.played, { 43 }, "motion sound has played once")
  Assert.equal(#original.seen.terrainEffects.emitted, 1, "the interaction turn emits grass presentation once")
  local bucket = ScriptSave.capture(original.scheduler, 102)
  Assert.equal(#bucket.tasks, 1, "the blocked interaction task is captured")
  Assert.equal(bucket.tasks[1].taskType, "follower_interaction")
  Assert.equal(bucket.tasks[1].taskVersion, FollowerInteractionTask.version)
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
  Assert.equal(#resumed.seen.terrainEffects.emitted, 0, "resume does not replay the grass turn effect")
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
