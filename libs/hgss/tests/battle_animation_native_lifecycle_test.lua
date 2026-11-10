-- Occurrence lifecycle and ownership: normal completion keeps native
-- terminal writes, published frames never alias mutable scene state, and
-- aborts restore only fields their occurrence still owns. Probes run real
-- tasks through the real player against a real scene; op spellings below
-- are the current producer vocabulary.

local Assert = require("tests.support.Assert")
local BattleAnimationPlayer = require("libs.hgss.src.presentation.BattleAnimationPlayer")
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

local function topology()
  return {
    attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
    targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
  }
end

local function packet()
  return {
    launchId = "native-lifecycle-probe",
    packetId = 1,
    topology = topology(),
    events = {},
    before = {},
    after = {},
  }
end

local function programOf(instructions)
  return { entry = "main", instructions = instructions, subprograms = {}, taskKinds = {} }
end

local function motionProgram()
  return programOf({
    {
      op = "invoke-battle-animation-callback",
      taskKind = "pokemon-picture-sinusoidal-position-motion",
      callback = "pokemon-picture-sinusoidal-position-attacker",
      taskContext = "pokemon-picture",
      battlerTarget = "attacker",
      parameters = { oscillationCycles = 1, durationTicks = 4 },
    },
  })
end

local function blendProgram()
  return programOf({
    {
      op = "invoke-battle-animation-callback",
      taskKind = "battle-background-blend-transition",
      callback = "battle-background-position-transition",
      taskContext = "battle-display",
      parameters = {
        offsetX = 10,
        offsetY = 20,
        ticksPerStep = 4,
        steps = 5,
        pictureSets = {},
        pictureAttributeOffset = false,
        managedSpriteOffset = false,
        backgroundPositionEnabled = false,
      },
    },
  })
end

local function startLive(program)
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local audio = {}
  function audio.play(_name)
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
  local player = assert(BattleAnimationPlayer.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = BattleEffectTasks,
    services = { onNativeFrame = function() end },
  }))
  local handle, reason = player:start(packet(), program)
  Assert.notNil(handle, "the motion program admits: " .. tostring(reason))
  return player, assert(handle), scene, journal
end

local function activation()
  return { combatant = 1, activation = 1 }
end

function T.completed_work_keeps_its_terminal_writes()
  local player, handle, scene = startLive(motionProgram())
  for _ = 1, 12 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "the motion occurrence drains to completion")
  local final = scene:pictureState(activation())
  Assert.notNil(final, "normal completion preserves the terminal picture write")
  Assert.equal(final.centerX, 16, "the terminal center keeps the commanded endpoint")
end

function T.published_frames_are_detached_from_scene_state()
  local scene = sceneWithPair()
  Assert.isTrue(
    type(scene.animationFrame) == "function",
    "the scene publishes detached source frames for its consumers"
  )
  local frame = scene:animationFrame()
  Assert.isTrue(type(frame) == "table", "the published frame is a detached record")
  if type(frame.main) == "table" then
    frame.main = nil
  end
  local reread = scene:animationFrame()
  Assert.notNil(reread, "mutating a published frame never affects scene state")
  Assert.isTrue(type(reread.main) == "table", "the scene still publishes its own state afterwards")
end

function T.aborted_work_restores_only_owned_fields()
  local player, handle, scene, journal = startLive(blendProgram())
  local mid = scene:scroll()
  for _ = 1, 8 do
    player:stepSourceTick({ tick = 1 })
    mid = scene:scroll()
    if mid.x ~= 0 or mid.y ~= 0 then
      break
    end
  end
  Assert.isTrue(mid.x ~= 0 or mid.y ~= 0, "the running task publishes its viewport write")
  player:cancel(handle, "withdrawn")
  Assert.equal(player:status(handle), "cancelled", "the running occurrence cancels")
  local restored = scene:scroll()
  Assert.equal(restored.x, 0, "the abort restores the owned horizontal sweep")
  Assert.equal(restored.y, 0, "the abort restores the owned vertical sweep")
  Assert.equal(#journal.released, #journal.acquired, "the abort releases every staged lease exactly once")
  player:cancel(handle, "repeated")
  Assert.equal(player:status(handle), "cancelled", "repeated cancellation stays silent")
end

return { tests = T }
