-- Owns one serialized retail follower interaction and its transient presentation.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local DialogueTask = require("libs.hgss.src.script.tasks.DialogueTask")
local ContextChoiceTask = require("libs.hgss.src.script.tasks.ContextChoiceTask")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")

local FollowerInteractionTask = { type = "follower_interaction", version = 2 }
local STATE_KEYS = {
  leadSlot = true,
  programId = true,
  phase = true,
  stepIndex = true,
  savedFacing = true,
  motionId = true,
  motionIndex = true,
  motionTick = true,
  cumulativeX = true,
  cumulativeY = true,
  cumulativeZ = true,
  dialogueState = true,
  choiceState = true,
  reactionTick = true,
  rewardStarted = true,
  rewardWaitForEffect = true,
  delayRemaining = true,
  choiceTargets = true,
  motionStarted = true,
}
local PHASES = {
  step = true,
  motion = true,
  reaction = true,
  dialogue = true,
  delay = true,
  deltas = true,
  choice = true,
  reward = true,
  done = true,
}
local FACING = { [1] = "north", [2] = "south", [3] = "west", [4] = "east" }
local FACING_VALUES = { north = true, south = true, west = true, east = true }

local function services(ctx)
  return assert(ctx.services, "follower interaction task services are required")
end

local function partnerId(followingMon)
  local partner = followingMon.partnerActorId
  if type(partner) == "function" then
    partner = followingMon:partnerActorId()
  end
  return assert(partner, "partner actor is unavailable")
end

function FollowerInteractionTask.create(_, ctx)
  local svc = services(ctx)
  local engine = assert(svc.followerInteraction)
  local actorId = partnerId(assert(svc.followingMon))
  if svc.actors:isScriptedMoving(actorId) then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "partner actor is busy", { actorId = actorId })
  end
  local selected = engine:select()
  if selected == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "no follower interaction rule matched", {})
  end
  selected = assert(selected)
  local facing = assert(svc.actors:getFacing(actorId), "partner actor is unavailable")
  return {
    leadSlot = selected.leadSlot,
    programId = selected.programId,
    phase = "step",
    stepIndex = 1,
    savedFacing = facing,
    motionId = 0,
    motionIndex = 1,
    motionTick = 0,
    cumulativeX = 0,
    cumulativeY = 0,
    cumulativeZ = 0,
    rewardStarted = false,
    rewardWaitForEffect = false,
    motionStarted = false,
  }
end

local function effectAnchor(svc, direction)
  local anchor = svc.followerInteraction:partnerEffectAnchor()
  anchor.direction = direction
  return anchor
end

local function emitGrassTurn(svc, engine, previousFacing, facing)
  if previousFacing == facing then
    return
  end
  local behavior = engine:partnerMetatileBehavior()
  local kind = MetatileBehavior.isTallGrass(behavior) and "tall_grass"
    or MetatileBehavior.isVeryTallGrass(behavior) and "very_tall_grass"
  if kind then
    local anchor = effectAnchor(svc, facing)
    anchor.kind = kind
    svc.terrainEffects:emit(anchor)
  end
end

local function clearMotion(state, svc, normalCompletion)
  local actorId = partnerId(svc.followingMon)
  if actorId ~= nil and svc.actors:getFacing(actorId) ~= nil then
    if state.motionStarted then
      svc.actors:cancelScriptedMovement(actorId)
    end
    local previousFacing = svc.actors:getFacing(actorId)
    svc.actors:setFacing(actorId, state.savedFacing)
    if normalCompletion then
      emitGrassTurn(svc, svc.followerInteraction, previousFacing, state.savedFacing)
    end
  end
  state.motionId, state.motionIndex, state.motionTick, state.motionStarted = 0, 1, 0, false
  state.cumulativeX, state.cumulativeY, state.cumulativeZ = 0, 0, 0
end

-- The source spawns a reaction as a blocking subtask (ov02_0224FB54 ->
-- ov01_02203AB4), so the step's message waits for the partner's emote to
-- finish. The partner action is derived presentation: after restore it is
-- rebuilt at the serialized tick.
local function pollReaction(state, svc, step)
  if state.reactionTick == nil then
    local selector = step.reactionId
    if selector == nil or selector == 0 then
      return true
    end
    if MetatileBehavior.suppressesFollowerReaction(svc.followerInteraction:partnerMetatileBehavior()) then
      return true
    end
    state.reactionTick = 0
  end
  local reaction = svc.followerInteraction:reaction(step.reactionId)
  local actorId = partnerId(svc.followingMon)
  if state.reactionTick == 0 or not svc.actors:isScriptedMoving(actorId) then
    svc.actors:beginScriptedAction(actorId, { action = "emote", name = reaction.kind, ticks = reaction.ticks })
  end
  state.reactionTick = state.reactionTick + 1
  if state.reactionTick < reaction.ticks then
    svc.actors:advanceScriptedAction(actorId, state.reactionTick, reaction.ticks)
    return false
  end
  svc.actors:commitScriptedAction(actorId)
  state.reactionTick = nil
  return true
end

local function message(ctx, bank, id, bindings)
  assert(services(ctx).dialogue)
  local node = { op = "say", message = { message = "external", bank = bank, id = id }, bindings = bindings }
  return DialogueTask.create({ node = node }, ctx)
end

local function beginStep(state, ctx)
  local svc = services(ctx)
  local engine = svc.followerInteraction
  local program = engine:program(state.programId)
  local step = program.steps[state.stepIndex]
  if step == nil then
    state.phase = "deltas"
    return false
  end
  state.phase = step.motionId ~= nil and "motion" or "reaction"
  if step.motionId ~= nil then
    state.motionId, state.motionIndex, state.motionTick = step.motionId, 1, 0
  end
  return true
end

-- Each phase stepper performs exactly the work the sequential poll used to do
-- for its phase and reports how polling continues. Continue starts the next
-- phase in the same poll; yield suspends until the next poll; complete
-- finishes the interaction.
local function stepPhase(state, ctx)
  beginStep(state, ctx)
  return "continue"
end

local function motionPhase(state, ctx)
  local svc = services(ctx)
  local engine = assert(svc.followerInteraction)
  local actorId = partnerId(svc.followingMon)
  assert(svc.actors:getFacing(actorId) ~= nil, "partner actor disappeared during interaction")
  local motion = engine:motion(state.motionId)
  local step = assert(engine:program(state.programId).steps[state.stepIndex])
  while state.phase == "motion" do
    local record = motion[state.motionIndex]
    if
      record == nil
      or (
        record.x == 0
        and record.y == 0
        and record.z == 0
        and record.facing == 0
        and record.ticks == 0
        and not record.sound
      )
    then
      clearMotion(state, svc, true)
      state.phase = "reaction"
      break
    end
    if not state.motionStarted then
      state.cumulativeX = state.cumulativeX + record.x
      state.cumulativeZ = state.cumulativeZ + record.z
      if not engine:ignoresMotionVerticalOffset(state.leadSlot) then
        state.cumulativeY = state.cumulativeY + record.y
      end
      local facing = type(record.facing) == "string" and record.facing or FACING[record.facing]
      if facing then
        local previousFacing = svc.actors:getFacing(actorId)
        svc.actors:setFacing(actorId, facing)
        emitGrassTurn(svc, engine, previousFacing, facing)
      end
      svc.actors:beginScriptedAction(actorId, {
        action = "presentation_offset",
        x = state.cumulativeX,
        y = state.cumulativeY,
        z = state.cumulativeZ,
        ticks = record.ticks,
      })
      svc.actors:advanceScriptedAction(actorId, 0, record.ticks)
      if record.sound and step.sound ~= nil then
        local sound = step.sound
        if sound.kind == "effect" then
          svc.audio:play(sound.id)
        elseif sound.kind == "cry" then
          svc.audio:playCry(svc.mons:partyMonSpecies(state.leadSlot), sound.pattern)
        else
          error("validated follower interaction sound kind is invalid")
        end
      end
      state.motionStarted = true
      if record.ticks > 0 then
        return "yield"
      end
    elseif not svc.actors:isScriptedMoving(actorId) then
      -- The partner actor is derived presentation and is absent after restore.
      -- Rebuild the current render action without advancing offsets or replaying
      -- the record's facing and sound side effects.
      svc.actors:beginScriptedAction(actorId, {
        action = "presentation_offset",
        x = state.cumulativeX,
        y = state.cumulativeY,
        z = state.cumulativeZ,
        ticks = record.ticks,
      })
      svc.actors:advanceScriptedAction(actorId, state.motionTick, record.ticks)
    end
    if record.ticks == 0 then
      svc.actors:commitScriptedAction(actorId)
      state.motionIndex, state.motionTick, state.motionStarted = state.motionIndex + 1, 0, false
    else
      state.motionTick = state.motionTick + 1
      svc.actors:advanceScriptedAction(actorId, state.motionTick, record.ticks)
      if state.motionTick >= record.ticks then
        svc.actors:commitScriptedAction(actorId)
        state.motionIndex, state.motionTick, state.motionStarted = state.motionIndex + 1, 0, false
      else
        return "yield"
      end
    end
  end
  return "continue"
end

local function reactionPhase(state, ctx)
  local svc = services(ctx)
  local engine = assert(svc.followerInteraction)
  local program = engine:program(state.programId)
  local step = program.steps[state.stepIndex]
  if not pollReaction(state, svc, step) then
    return "yield"
  end
  if step.messageId ~= nil then
    local bindings = engine:bindings(state.leadSlot)
    state.dialogueState = message(ctx, 265, step.messageId, bindings)
    state.phase = "dialogue"
  else
    state.phase = "delay"
  end
  return "continue"
end

local function dialoguePhase(state, ctx)
  local result = DialogueTask.poll(state.dialogueState, ctx)
  if not result.complete then
    return "yield"
  end
  state.dialogueState = nil
  state.phase = "delay"
  return "continue"
end

local function delayPhase(state, ctx)
  local svc = services(ctx)
  local engine = assert(svc.followerInteraction)
  local program = engine:program(state.programId)
  local step = program.steps[state.stepIndex]
  local delay = step.delayTicks or 0
  if delay > 0 then
    state.delayRemaining = (state.delayRemaining or delay) - 1
    if state.delayRemaining > 0 then
      return "yield"
    end
  end
  state.delayRemaining = nil
  state.stepIndex, state.phase = state.stepIndex + 1, "step"
  return "yield"
end

local function deltasPhase(state, ctx)
  local svc = services(ctx)
  local engine = assert(svc.followerInteraction)
  local program = engine:program(state.programId)
  engine:applyDeltas(state.leadSlot, program.friendshipDelta, program.moodDelta)
  if program.continuation then
    local continuation = program.continuation
    state.choiceTargets = {
      continuation.choice0InteractionId,
      continuation.choice1InteractionId,
    }
    state.choiceState = ContextChoiceTask.create({}, ctx)
    state.phase = "choice"
  else
    state.phase = "reward"
  end
  return "continue"
end

local function choicePhase(state, ctx)
  local svc = services(ctx)
  local engine = assert(svc.followerInteraction)
  local result = ContextChoiceTask.poll(state.choiceState, ctx)
  if not result.complete then
    return "yield"
  end
  local target = state.choiceTargets[result.result == 1 and 2 or 1]
  state.choiceState, state.choiceTargets = nil, nil
  if target == 0 then
    state.phase = "reward"
  else
    engine:program(target)
    state.programId, state.stepIndex = target, 1
    state.cumulativeX, state.cumulativeY, state.cumulativeZ = 0, 0, 0
    state.phase = "step"
  end
  return "yield"
end

local function rewardPhase(state, ctx)
  local svc = services(ctx)
  local engine = assert(svc.followerInteraction)
  local program = engine:program(state.programId)
  local reward = program.reward
  if reward == nil and program.fashionAccessoryId ~= nil then
    reward = { kind = "fashion", selector = program.fashionAccessoryId + 1 }
  end
  if reward == nil and program.shinyLeafId ~= nil then
    reward = { kind = "leaf", selector = program.shinyLeafId }
  end
  if reward == nil then
    state.phase = "done"
    return "complete"
  end
  if not state.rewardStarted then
    local result = engine:reward(state.leadSlot, reward)
    state.rewardStarted = true
    local outcome = type(result) == "table" and result.outcome or result
    local bank, id, bindings
    if reward.kind == "fashion" then
      bank, id = 40, outcome == "added" and 32 or 95
      local name = type(result) == "table" and (outcome == "added" and result.plain or result.article)
        or outcome == "added" and "Accessory"
        or "an Accessory"
      bindings = { svc.player and svc.player:name() or "Red", name }
      if outcome == "added" then
        svc.audio:play("SEQ_ME_ACCE")
        state.rewardWaitForEffect = true
      end
    else
      bank, id = 40, outcome == "new" and 97 or 98
      bindings = { svc.player and svc.player:name() or "Red", engine:bindings(state.leadSlot)[0] }
      if outcome == "new" then
        svc.world:setFlag(0x99C)
        svc.audio:play("SEQ_ME_ACCE")
        state.rewardWaitForEffect = true
      end
    end
    state.dialogueState = message(ctx, bank, id, bindings)
    return "yield"
  end
  local dialogueCtx = ctx
  if state.rewardWaitForEffect and not svc.audio:isEffectWaitComplete("SEQ_ME_ACCE") then
    dialogueCtx = {}
    for key, value in pairs(ctx) do
      dialogueCtx[key] = value
    end
    dialogueCtx.input = {}
    for key, value in pairs(ctx.input or {}) do
      dialogueCtx.input[key] = value
    end
    dialogueCtx.input.pressedAction = nil
    dialogueCtx.input.pressedCancel = nil
  end
  local result = DialogueTask.poll(state.dialogueState, dialogueCtx)
  if not result.complete then
    return "yield"
  end
  state.dialogueState = nil
  state.phase = "done"
  return "complete"
end

local function donePhase()
  return "complete"
end

local PHASE_POLL = {
  step = stepPhase,
  motion = motionPhase,
  reaction = reactionPhase,
  dialogue = dialoguePhase,
  delay = delayPhase,
  deltas = deltasPhase,
  choice = choicePhase,
  reward = rewardPhase,
  done = donePhase,
}

function FollowerInteractionTask.poll(state, ctx)
  while true do
    local handler = PHASE_POLL[state.phase]
    if handler == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
        "unknown follower interaction phase",
        { phase = state.phase }
      )
    else
      local disposition = handler(state, ctx)
      if disposition == "yield" then
        return { complete = false, state = state }
      end
      if disposition == "complete" then
        return { complete = true, state = state }
      end
      assert(disposition == "continue", "follower interaction step disposition is invalid")
    end
  end
end

function FollowerInteractionTask.cancel(state, reason, ctx)
  if ctx == nil then
    return
  end
  local svc = services(ctx)
  if state.dialogueState then
    DialogueTask.cancel(state.dialogueState, reason, ctx)
    state.dialogueState = nil
  end
  if state.choiceState then
    ContextChoiceTask.cancel(state.choiceState, reason, ctx)
    state.choiceState = nil
  end
  if state.reactionTick ~= nil then
    svc.actors:cancelScriptedMovement(partnerId(svc.followingMon))
    state.reactionTick = nil
  end
  clearMotion(state, svc, false)
end

local function taskStateError(state)
  return Errors.new(
    ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
    "follower interaction task state is invalid",
    { state = state }
  )
end

local function integerField(value, minimum, maximum)
  return type(value) == "number" and value % 1 == 0 and value >= minimum and value <= maximum
end

local function finiteField(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Shared scalar, key, and child-shape checks that apply in every phase.
local function checkShared(state)
  for key in pairs(state) do
    if not STATE_KEYS[key] then
      return taskStateError(state)
    end
  end
  if
    not integerField(state.leadSlot, 0, 5)
    or not integerField(state.programId, 1, 1023)
    or not integerField(state.stepIndex, 1, 6)
    or not integerField(state.motionId, 0, 108)
    or not integerField(state.motionIndex, 1, 10)
    or not integerField(state.motionTick, 0, 254)
    or not finiteField(state.cumulativeX)
    or not finiteField(state.cumulativeY)
    or not finiteField(state.cumulativeZ)
    or state.cumulativeX < -80
    or state.cumulativeY < -80
    or state.cumulativeZ < -80
    or state.cumulativeX > 79.375
    or state.cumulativeY > 79.375
    or state.cumulativeZ > 79.375
    or state.cumulativeX * 16 % 1 ~= 0
    or state.cumulativeY * 16 % 1 ~= 0
    or state.cumulativeZ * 16 % 1 ~= 0
    or not FACING_VALUES[state.savedFacing]
    or type(state.motionStarted) ~= "boolean"
    or type(state.rewardStarted) ~= "boolean"
    or type(state.rewardWaitForEffect) ~= "boolean"
  then
    return taskStateError(state)
  end
  if state.delayRemaining ~= nil and not integerField(state.delayRemaining, 1, 0xFF) then
    return taskStateError(state)
  end
  if state.reactionTick ~= nil and not integerField(state.reactionTick, 1, 0xFF) then
    return taskStateError(state)
  end
  if state.choiceTargets ~= nil then
    local count = 0
    if
      type(state.choiceTargets) ~= "table"
      or not integerField(state.choiceTargets[1], 0, 1023)
      or not integerField(state.choiceTargets[2], 0, 1023)
    then
      return taskStateError(state)
    end
    for key in pairs(state.choiceTargets) do
      if key ~= 1 and key ~= 2 then
        return taskStateError(state)
      end
      count = count + 1
    end
    if count ~= 2 then
      return taskStateError(state)
    end
  end
  if state.dialogueState ~= nil then
    local dialogue = state.dialogueState
    if
      type(dialogue) ~= "table"
      or dialogue.mode ~= "say"
      or type(dialogue.phase) ~= "string"
      or type(dialogue.message) ~= "table"
      or dialogue.message.message ~= "external"
      or not integerField(dialogue.message.bank, 0, 0xFFFF)
      or not integerField(dialogue.message.id, 0, 0xFFFF)
      or type(dialogue.bindings) ~= "table"
      or not integerField(dialogue.phaseReadyInTicks, 0, 1)
    then
      return taskStateError(state)
    end
    for key in pairs(dialogue.message) do
      if key ~= "message" and key ~= "bank" and key ~= "id" then
        return taskStateError(state)
      end
    end
    local bindingCount = 0
    local bindingMinimum = math.huge
    local bindingMaximum = -math.huge
    for key, value in pairs(dialogue.bindings) do
      if type(key) ~= "number" or key < 0 or key > 4 or key % 1 ~= 0 or type(value) ~= "string" then
        return taskStateError(state)
      end
      bindingCount = bindingCount + 1
      bindingMinimum = math.min(bindingMinimum, key)
      bindingMaximum = math.max(bindingMaximum, key)
    end
    if
      not (bindingCount == 5 and bindingMinimum == 0 and bindingMaximum == 4)
      and not (bindingCount == 2 and bindingMinimum == 1 and bindingMaximum == 2)
    then
      return taskStateError(state)
    end
    for key in pairs(dialogue) do
      if key ~= "message" and key ~= "bindings" and key ~= "mode" and key ~= "phase" and key ~= "phaseReadyInTicks" then
        return taskStateError(state)
      end
    end
    if DialogueTask.validate(dialogue) then
      return taskStateError(state)
    end
  end
  if state.choiceState ~= nil then
    local choice = state.choiceState
    if type(choice) ~= "table" then
      return taskStateError(state)
    end
    for key in pairs(choice) do
      if key ~= "active" and key ~= "phase" and key ~= "selected" then
        return taskStateError(state)
      end
    end
    if ContextChoiceTask.validate(choice) then
      return taskStateError(state)
    end
  end
  if
    (state.phase == "motion") ~= (state.motionId ~= 0)
    or (not state.rewardStarted and state.rewardWaitForEffect)
    or (state.delayRemaining ~= nil and state.phase ~= "delay")
    or (state.reactionTick ~= nil and state.phase ~= "reaction")
    or (state.rewardStarted and state.phase ~= "reward" and state.phase ~= "done")
    or (state.motionStarted and state.phase ~= "motion")
  then
    return taskStateError(state)
  end
  return nil
end

local function checkIdleChildren(state)
  if state.dialogueState ~= nil or state.choiceState ~= nil or state.choiceTargets ~= nil then
    return taskStateError(state)
  end
  return nil
end

local function checkDialogueChild(state)
  if state.dialogueState == nil or state.choiceState ~= nil or state.choiceTargets ~= nil then
    return taskStateError(state)
  end
  return nil
end

local function checkChoiceChildren(state)
  if state.choiceState == nil or state.choiceTargets == nil or state.dialogueState ~= nil then
    return taskStateError(state)
  end
  return nil
end

-- A reward with no follow-up suspends once before its mutation runs and keeps
-- its dialogue only after the mutation.
local function checkRewardChild(state)
  if state.choiceState ~= nil or state.choiceTargets ~= nil then
    return taskStateError(state)
  end
  if state.rewardStarted and state.dialogueState == nil then
    return taskStateError(state)
  end
  if not state.rewardStarted and state.dialogueState ~= nil then
    return taskStateError(state)
  end
  return nil
end

-- Phase payload checks: which child states each suspended phase may carry.
local PHASE_VALIDATE = {
  step = checkIdleChildren,
  motion = checkIdleChildren,
  reaction = checkIdleChildren,
  delay = checkIdleChildren,
  deltas = checkIdleChildren,
  dialogue = checkDialogueChild,
  choice = checkChoiceChildren,
  reward = checkRewardChild,
  done = checkIdleChildren,
}

function FollowerInteractionTask.validate(state)
  if type(state) ~= "table" or not PHASES[state.phase] then
    return taskStateError(state)
  end
  local shared = checkShared(state)
  if shared ~= nil then
    return shared
  end
  local check = PHASE_VALIDATE[state.phase]
  if check == nil then
    return taskStateError(state)
  end
  return check(state)
end

return FollowerInteractionTask
