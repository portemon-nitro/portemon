-- Picture and presentation state stays keyed by activation identity, so a
-- withdrawn combatant's late work can never reach the replacement sharing
-- its slot: the scene keeps one entry per combatant and activation pair,
-- untouched replacements expose no patched view, and restoring the old
-- activation leaves the new one alone. The delayed-task isolation run
-- drives the battle-private program player once it exists.
-- Native geometry: libs/hgss presentation BattleScene activation-scoped
-- picture state; slot rows resolve per side, never per occupant.
-- Headless: the real scene owns the entries; no battle or field objects
-- are touched.

local Assert = require("tests.support.Assert")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
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

local function playbackPacket()
  local packet = BattlePresentationModel.packet({}, { events = {} }, {}, {
    launchId = "slot-identity-probe",
    packetId = 1,
  })
  Assert.equal(packet.launchId, "slot-identity-probe", "the playback input carries its launch identity")
  return packet
end

local function playerModule()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle-private animation player resolves through the presentation boundary")
  Assert.equal(type(Player.new), "function", "the player exposes its construction entry point")
  return Player
end

function T.replacement_activation_keeps_its_own_picture_state()
  local scene = sceneWithPair()
  local old = { combatant = 1, activation = 1 }
  local view = scene:applyPictureState(old, { vanished = true })
  Assert.equal(view.vanished, true, "the old activation records its patched picture state")
  scene:observe({
    { combatant = 1, activation = 9, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  local replacement = { combatant = 1, activation = 9 }
  Assert.isNil(scene:pictureState(replacement), "the untouched replacement exposes no patched view")
  local oldPhase = scene:entryStatus(old)
  local newPhase = scene:entryStatus(replacement)
  Assert.equal(oldPhase, "complete", "the withdrawn activation keeps its own entry")
  Assert.equal(newPhase, "complete", "the replacement installs a separate entry")
  local restored = scene:restorePictureState(old)
  Assert.notNil(restored, "the old activation restores its own snapshot")
  Assert.isNil(restored.vanished, "restoration returns the pre-patch appearance")
  Assert.isNil(scene:pictureState(replacement), "restoring the old activation leaves the new one alone")
  Assert.equal(scene:pictureState(old).vanished, nil, "the old activation no longer shows its patch")
end

function T.late_work_for_a_withdrawn_activation_never_touches_its_replacement()
  local Player = playerModule()
  local scene = sceneWithPair()
  local old = { combatant = 1, activation = 1 }
  scene:applyPictureState(old, { zOffset = 3 })
  scene:observe({
    { combatant = 1, activation = 9, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  local audio = { played = {}, stopped = {}, done = {} }
  function audio.play(name)
    audio.played[#audio.played + 1] = name
  end
  function audio.stop(name)
    audio.stopped[#audio.stopped + 1] = name
  end
  function audio.isFinished(name)
    return audio.done[name] == true
  end
  local delayed = {}
  local tasks = {}
  function tasks.create(kind, _args, context, _services)
    local task = { _state = "running" }
    function task.stepSourceTick(_tick)
      delayed[#delayed + 1] = { kind = kind, context = context }
    end
    function task.status()
      return task._state
    end
    function task.cancel(_reason)
      task._state = "cancelled"
    end
    function task.dispose() end
    return task
  end
  local resources = {}
  function resources.resolve(key)
    return { key = key, lease = key }
  end
  function resources.release(_lease) end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = tasks,
  }))
  local packet = playbackPacket()
  local staleHandle = assert(player:start(packet, {
    entry = "main",
    instructions = { { op = "reset-blend-alpha" } },
    subprograms = {},
    taskKinds = {},
  }))
  player:cancel(staleHandle, "withdrawn")
  Assert.equal(player:status(staleHandle), "cancelled", "withdrawing the old occurrence cancels it")
  scene:observe({
    { combatant = 1, activation = 9, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  for _ = 1, 5 do
    player:stepSourceTick({ tick = 1 })
  end
  Assert.isNil(scene:pictureState({ combatant = 1, activation = 9 }), "no late write lands on the replacement")
  Assert.equal(#audio.played, 0, "no late voice starts for the withdrawn occurrence")
end

return { tests = T }
