-- Overlapping native effects at the production task boundary: tasks
-- that change different targets and layers compose, cancelling one
-- releases exactly its own pictures, leases, and voices, replacing an
-- actor never lets a stale restore overwrite the new owner, and the next
-- valid occurrence still runs normally. Setup below holds today through
-- the real scene path; the execution gate drives the battle-private
-- program player together with the battle-private effect task factory
-- once both exist.
-- Native mechanism: occurrence-owned picture, background, palette, and
-- sound state with source overlap and priority rules
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Headless: synthetic command streams use the real producer lowering and
-- the shared program shape; the recorder doubles record only.

local Assert = require("tests.support.Assert")
local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local function u32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function streamOf(list)
  local parts = {}
  for _, word in ipairs(list) do
    parts[#parts + 1] = u32(word)
  end
  return table.concat(parts)
end

local function lowered(key, list)
  local program = assert(BattleAnimationCompiler.compile({ key = key, stream = streamOf(list) }))
  Assert.isTrue(
    BattleAnimationSchema.assertProgram({
      entry = program.entry,
      instructions = program.instructions,
      subprograms = program.subprograms,
      taskKinds = program.taskKinds,
    }),
    "the lowered program validates against the shared program shape"
  )
  return program
end

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
    launchId = "overlap-cancel-probe",
    packetId = 1,
  })
  Assert.equal(packet.launchId, "overlap-cancel-probe", "the playback input carries its launch identity")
  return packet
end

local function playerModule()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle-private animation player resolves through the presentation boundary")
  Assert.equal(type(Player.new), "function", "the player exposes its construction entry point")
  return Player
end

local function effectFactoryModule()
  local ok, Factory = pcall(require, "libs.hgss.src.presentation.BattleEffectTasks")
  Assert.isTrue(ok, "the battle-private effect task factory resolves through the presentation boundary")
  Assert.equal(type(Factory.create), "function", "the factory exposes its task construction entry point")
  return Factory
end

function T.effect_records_release_exactly_once_and_stay_silent_afterward()
  local scene = sceneWithPair()
  local first = scene:allocEffect("overlap-probe")
  local second = scene:allocEffect("overlap-probe")
  Assert.isTrue(second.id ~= first.id, "two overlapping effects hold distinct identities")
  scene:setEffectPicture(first.id, {
    assetKey = "staged-first",
    selector = "first",
    centerX = 64,
    centerY = 112,
    zCenter = 0,
    width = 64,
    height = 64,
    alpha = 1,
  })
  scene:releaseEffect(first.id)
  scene:releaseEffect(first.id)
  scene:releaseEffect(99999)
  local views = scene:effectViews()
  Assert.equal(#views, 1, "only the surviving effect still publishes")
  Assert.equal(views[1].id, second.id, "the survivor keeps its own identity")
  scene:release()
  scene:release()
  Assert.equal(#scene:effectViews(), 0, "launch release drops every owned record")
end

function T.picture_state_stays_keyed_by_activation_across_replacement()
  local scene = sceneWithPair()
  local outgoing = { combatant = 1, activation = 1 }
  local staying = { combatant = 3, activation = 3 }
  scene:applyPictureState(outgoing, { pictureXOffset2 = 40 })
  Assert.equal(
    scene:pictureState(outgoing).pictureXOffset2,
    40,
    "the outgoing activation carries its temporary change"
  )
  Assert.isNil(scene:pictureState(staying), "the untouched activation exposes no patched view")
  scene:remove(1, 1)
  Assert.isNil(scene:pictureState(outgoing), "the withdrawn activation leaves no patched view behind")
  Assert.isNil(scene:pictureState(staying), "withdrawing one activation never touches the other")
  scene:observe({ { combatant = 1, activation = 2, visible = true } })
  local incoming = { combatant = 1, activation = 2 }
  Assert.isNil(scene:pictureState(incoming), "the replacement starts without the old change")
  scene:restorePictureState(outgoing)
  Assert.isNil(scene:pictureState(incoming), "restoring the old activation never reaches the replacement")
end

function T.overlapping_tasks_cancel_and_replace_without_stale_restores()
  local firstProgram = lowered("overlap-first", { 34, 1, 2, 3, 50, 4 })
  local secondProgram = lowered("overlap-second", { 51, 0, 27, 50, 4 })
  local Player = playerModule()
  local Factory = effectFactoryModule()
  local scene = sceneWithPair()
  local journals = {}
  local function collaborators(key)
    local journal = { acquired = {}, released = {}, played = {}, stopped = {} }
    journals[key] = journal
    local audio = {}
    function audio.play(name)
      journal.played[#journal.played + 1] = name
    end
    function audio.stop(name)
      journal.stopped[#journal.stopped + 1] = name
    end
    function audio.isFinished(_name)
      return true
    end
    local resources = {}
    function resources.resolve(name)
      journal.acquired[#journal.acquired + 1] = name
      return { key = name, lease = key .. ":" .. key }
    end
    function resources.release(lease)
      journal.released[#journal.released + 1] = lease
    end
    return { audio = audio, resources = resources, journal = journal }
  end
  local first = collaborators("first")
  local runner = assert(Player.new({
    scene = scene,
    audio = first.audio,
    resources = first.resources,
    tasks = Factory,
  }))
  local surviving = assert(runner:start(playbackPacket(), firstProgram))
  local cancelled = assert(runner:start(playbackPacket(), secondProgram))
  runner:stepSourceTick({ tick = 1 })
  runner:cancel(cancelled, "overlap-superseded")
  Assert.equal(runner:status(cancelled), "cancelled", "the cancelled task lands on cancelled")
  Assert.isTrue(runner:status(surviving) ~= "cancelled", "the surviving task keeps its own state")
  scene:remove(1, 1)
  scene:observe({ { combatant = 1, activation = 2, visible = true } })
  for _ = 1, 60 do
    runner:stepSourceTick({ tick = 1 })
    if runner:status(surviving) == "complete" then
      break
    end
  end
  Assert.equal(runner:status(surviving), "complete", "the survivor completes after the replacement")
  Assert.isNil(
    scene:pictureState({ combatant = 1, activation = 2 }),
    "no stale restore overwrites the replacement owner"
  )
  local journal = assert(journals.first, "the occurrence journal is retained")
  Assert.equal(#journal.released, #journal.acquired, "the occurrence releases exactly its own leases")
  Assert.equal(#journal.stopped, #journal.played, "the occurrence stops exactly its own voices")
  local fresh = collaborators("fresh")
  local nextRunner = assert(Player.new({
    scene = scene,
    audio = fresh.audio,
    resources = fresh.resources,
    tasks = Factory,
  }))
  local nextHandle = assert(nextRunner:start(playbackPacket(), firstProgram))
  for _ = 1, 60 do
    nextRunner:stepSourceTick({ tick = 1 })
    if nextRunner:status(nextHandle) == "complete" then
      break
    end
  end
  Assert.equal(nextRunner:status(nextHandle), "complete", "the next valid occurrence still runs normally")
end

return { tests = T }
