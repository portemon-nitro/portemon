-- Complete general callback behavior: defined callbacks resolve and run
-- their own state machines. An argument-free callback with source
-- constants still executes its phases, the empty callback stays a
-- synchronous no-op, one-frame callbacks count two states, and knockback
-- displaces its target instead of holding a timer. Probes use the real
-- producer lowering and the real task factory.

local Assert = require("tests.support.Assert")
local BattleAnimationSources = require("romdump.src.config.BattleAnimationSources")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

local function occurrenceContext()
  return {
    launchId = "native-callback-probe",
    packetId = 1,
    programKey = "native-callback-probe",
    seed = 4242,
    random = function(bound)
      assert(type(bound) == "number" and bound > 0, "visual draws name a positive bound")
      return 0
    end,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "native-callback-probe" },
    visualSeed = 4242,
  }
end

local function factoryServices(scene)
  local journal = { acquired = {}, released = {} }
  local audio = { played = {} }
  function audio.play(name)
    audio.played[#audio.played + 1] = name
    return name
  end
  function audio.stop(_name)
  end
  function audio.isFinished(_name)
    return true
  end
  local resources = {}
  function resources.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    return { key = key, lease = key }
  end
  function resources.release(lease)
    journal.released[#journal.released + 1] = lease
  end
  return { scene = scene, audio = audio, resources = resources }, journal, audio
end

local function resolveNoOperand(selector)
  local resolved, reason = BattleAnimationSources.resolveBattleAnimationCallback({ selector, 0 })
  Assert.notNil(resolved, "defined no-operand callback " .. selector .. " resolves: " .. tostring(reason))
  return assert(resolved)
end

function T.argument_free_table_driven_callbacks_execute_their_phases()
  local resolved = resolveNoOperand(6)
  local scene = sceneWithPair()
  local services = factoryServices(scene)
  local activation = { combatant = 1, activation = 1 }
  local ok, task = pcall(BattleEffectTasks.create, assert(resolved.taskKind), {
    callback = resolved.callback,
    taskContext = resolved.context,
    battlerTarget = resolved.battlerTarget,
    parameters = resolved.parameters,
    activation = activation,
  }, occurrenceContext(), services)
  Assert.isTrue(ok, "the argument-free callback constructs from source constants: " .. tostring(task))
  local body = assert(task)
  local scales = {}
  for _ = 1, 40 do
    body:stepSourceTick({ tick = 1 })
    local state = scene:pictureState(activation)
    if state ~= nil and (state.scaleX ~= nil or state.scaleY ~= nil) then
      scales[#scales + 1] = { x = state.scaleX, y = state.scaleY }
    end
    if body:status() == "complete" then
      break
    end
  end
  Assert.equal(body:status(), "complete", "the phased callback reaches its own completion")
  Assert.isTrue(#scales > 1, "the run writes distinct squash and stretch phases instead of one static pose")
end

function T.defined_no_operand_callbacks_resolve_instead_of_missing()
  for _, selector in ipairs({ 0, 1, 2, 3, 21 }) do
    local resolved = resolveNoOperand(selector)
    Assert.isTrue(
      type(resolved.callback) == "string" and resolved.callback ~= "",
      "callback " .. selector .. " names its semantic behavior"
    )
    Assert.isTrue(
      type(resolved.taskKind) == "string" and resolved.taskKind ~= "",
      "callback " .. selector .. " names its native task"
    )
  end
end

function T.empty_callbacks_complete_synchronously_without_side_effects()
  local resolved = resolveNoOperand(0)
  local scene = sceneWithPair()
  local services, journal, audio = factoryServices(scene)
  local ok, task = pcall(BattleEffectTasks.create, assert(resolved.taskKind), {
    callback = resolved.callback,
    taskContext = resolved.context,
    parameters = resolved.parameters,
  }, occurrenceContext(), services)
  Assert.isTrue(ok, "the empty callback constructs: " .. tostring(task))
  local body = assert(task)
  body:stepSourceTick({ tick = 1 })
  Assert.equal(body:status(), "complete", "the empty callback completes without waiting")
  Assert.equal(#scene:effectViews(), 0, "the empty callback stages no drawable state")
  Assert.equal(#audio.played, 0, "the empty callback plays no voice")
  Assert.equal(#journal.acquired, 0, "the empty callback stages no lease")
end

function T.one_frame_callbacks_count_two_states_instead_of_collapsing()
  for _, selector in ipairs({ 1, 2, 3 }) do
    local resolved = resolveNoOperand(selector)
    local scene = sceneWithPair()
    local services = factoryServices(scene)
    local ok, task = pcall(BattleEffectTasks.create, assert(resolved.taskKind), {
      callback = resolved.callback,
      taskContext = resolved.context,
      parameters = resolved.parameters,
    }, occurrenceContext(), services)
    Assert.isTrue(ok, "one-frame callback " .. selector .. " constructs: " .. tostring(task))
    local body = assert(task)
    Assert.isTrue(
      body:status() == "pending" or body:status() == "running",
      "one-frame callback " .. selector .. " opens unfinished instead of completing synchronously"
    )
    body:stepSourceTick({ tick = 1 })
    local mid = body:status()
    body:stepSourceTick({ tick = 2 })
    Assert.equal(body:status(), "complete", "one-frame callback " .. selector .. " completes on its end state")
    Assert.isTrue(mid == "running" or mid == "complete", "one-frame callback " .. selector .. " counts a wait state")
  end
end

function T.knockback_displaces_its_target_instead_of_holding_a_timer()
  local resolved, reason = BattleAnimationSources.resolveBattleAnimationCallback({ 48, 0 })
  Assert.notNil(resolved, "defender knockback resolves: " .. tostring(reason))
  local plan = assert(resolved)
  local scene = sceneWithPair()
  local services = factoryServices(scene)
  local activation = { combatant = 3, activation = 3 }
  local task = assert(BattleEffectTasks.create(assert(plan.taskKind), {
    callback = plan.callback,
    taskContext = plan.context,
    battlerTarget = plan.battlerTarget,
    parameters = plan.parameters,
    activation = activation,
  }, occurrenceContext(), services))
  local displaced = false
  for _ = 1, 40 do
    task:stepSourceTick({ tick = 1 })
    local state = scene:pictureState(activation)
    if state ~= nil and state.centerX ~= nil then
      displaced = true
      break
    end
    if task:status() == "complete" then
      break
    end
  end
  Assert.isTrue(displaced, "knockback visibly displaces its target instead of idling imageless")
end

return { tests = T }
