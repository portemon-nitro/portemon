-- The credit-roll choreography application: twelve dancing mons flip sets
-- on the source screen-flip timeline, scene backgrounds and dance sequences
-- switch through the five source transitions with clouds covering the swap,
-- and sixteen cutscenes activate their sprites on source times, advancing
-- only when every active sprite finishes its animation. The roll ends at
-- the source frame count; skipping stays the state owner's job.

local Assert = require("tests.support.Assert")
local CreditsScene = require("game.hgss.src.ending.CreditsScene")

local T = { tests = {} }

local TRANSITION_TIMINGS = { 890, 1780, 2615, 3030, 4295 }
local DANCE_SEQS = { 6, 1, 2, 4, 3, 5 }
local CLOUD_SEQ = 7

local function frame(duration)
  return { durationTicks = duration, path = "frame.png", blank = false, origin = { x = 0, y = 0 } }
end

local function danceSequences()
  local sequences = {}
  for _, seqNo in ipairs({ 0, 1, 2, 3, 4, 5, 6, 7 }) do
    sequences[seqNo] = { frames = { frame(4), frame(4) }, playMode = "forward_loop" }
  end
  return sequences
end

local function cutsceneSprites()
  local sprites = {}
  sprites[0] = { sequences = { [2] = { frames = { frame(10), frame(10) }, playMode = "forward" } } }
  sprites[1] = { sequences = { [3] = { frames = { frame(30) }, playMode = "forward" } } }
  return sprites
end

local function cutscenes()
  return {
    {
      uniqueSprites = 1,
      totalSprites = 1,
      spriteIds = { 0 },
      params = {
        { spriteIdx = 0, animSeq = 2, x = 128, y = 96, activateTime = 50 },
      },
    },
    {
      uniqueSprites = 1,
      totalSprites = 1,
      spriteIds = { 1 },
      params = {
        { spriteIdx = 0, animSeq = 3, x = 64, y = 48, activateTime = 200 },
      },
    },
  }
end

local function newSceneWith(sprites)
  return CreditsScene.new({
    danceSequences = danceSequences(),
    danceSeqsByScene = DANCE_SEQS,
    cloudSeq = CLOUD_SEQ,
    cutscenes = cutscenes(),
    cutsceneSprites = sprites,
    gender = "male",
    totalFrames = 4976,
    transitionTimings = TRANSITION_TIMINGS,
    flipTimings = TRANSITION_TIMINGS,
  })
end

local function newScene()
  return newSceneWith(cutsceneSprites())
end

function T.tests.starts_on_the_first_scene_with_the_opening_dance()
  local scene = newScene()
  local status = scene:status()
  Assert.equal(status.timer, 0, "the roll starts at frame zero")
  Assert.equal(status.sceneIdx, 0, "the roll opens on the first scene")
  Assert.equal(status.danceSeq, 6, "the opening scene dances the first sequence")
  Assert.equal(status.screensFlipped, true, "the source starts with swapped displays")
  Assert.equal(status.cloudsVisible, false, "no transition clouds cover the opening")
  Assert.equal(status.cutsceneIdx, 0, "the roll opens on the first cutscene")
  Assert.equal(#status.cutsceneSprites, 1, "the first cutscene stages its sprite")
  Assert.isTrue(status.cutsceneSprites[1].active == false, "cutscene sprites wait for their activation time")
  Assert.isTrue(scene:isDone() == false, "the fresh roll never reads as finished")
end

function T.tests.switches_scenes_on_the_source_transition_timeline()
  local scene = newScene()
  for _ = 1, 890 do
    scene:step({})
  end
  local status = scene:status()
  Assert.equal(status.timer, 890, "the scene steps its source frame counter")
  Assert.equal(status.sceneIdx, 0, "the outgoing scene holds while clouds appear")
  Assert.isTrue(status.cloudsVisible, "clouds cover the background swap")
  Assert.equal(status.danceSeq, 6, "the dance holds until the swap tick")
  scene:step({})
  status = scene:status()
  Assert.equal(status.sceneIdx, 1, "the swap tick advances the display scene")
  Assert.equal(status.danceSeq, 1, "the incoming scene dances its own sequence")
  Assert.isTrue(status.cloudsVisible, "clouds linger while they dissipate")
  for _ = 1, 29 do
    scene:step({})
  end
  status = scene:status()
  Assert.isTrue(status.cloudsVisible, "clouds cover the full thirty-frame dissipate")
  scene:step({})
  status = scene:status()
  Assert.isTrue(status.cloudsVisible == false, "clouds clear after the dissipate")
  Assert.equal(status.sceneIdx, 1, "the scene index holds after its own transition")
end

function T.tests.flips_the_visible_dance_set_on_the_source_flip_timeline()
  local scene = newScene()
  for _ = 1, 889 do
    scene:step({})
  end
  Assert.equal(scene:status().screensFlipped, true, "the opening display mapping holds before the first flip")
  scene:step({})
  Assert.equal(scene:status().screensFlipped, false, "the first flip swaps the visible dance set")
  for _ = 1, 890 do
    scene:step({})
  end
  Assert.equal(scene:status().screensFlipped, true, "the second flip swaps back")
end

function T.tests.activates_cutscene_sprites_on_their_source_times()
  local scene = newScene()
  for _ = 1, 49 do
    scene:step({})
  end
  Assert.isTrue(scene:status().cutsceneSprites[1].active == false, "the sprite waits before its activation frame")
  scene:step({})
  local status = scene:status()
  Assert.isTrue(status.cutsceneSprites[1].active, "the sprite activates on its source frame")
  Assert.equal(status.cutsceneSprites[1].x, 128, "the sprite draws at its source anchor")
  Assert.equal(status.cutsceneIdx, 0, "the cutscene holds while its sprite animates")
end

function T.tests.advances_the_cutscene_only_when_every_sprite_finishes()
  local scene = newScene()
  -- First sprite: 2 frames of 10 ticks, activated at frame 50.
  for _ = 1, 69 do
    scene:step({})
  end
  Assert.equal(scene:status().cutsceneIdx, 0, "the cutscene holds mid-animation")
  scene:step({})
  local status = scene:status()
  Assert.equal(status.cutsceneIdx, 1, "the cutscene advances once its sprite finishes")
  Assert.isTrue(status.cutsceneSprites[1].active == false, "the next cutscene stages its sprite inactive")
  for _ = 1, 129 do
    scene:step({})
  end
  Assert.isTrue(scene:status().cutsceneSprites[1].active == false, "the second sprite waits for frame 200")
  scene:step({})
  Assert.isTrue(scene:status().cutsceneSprites[1].active, "the second sprite activates on its source frame")
end

function T.tests.resolves_player_sprites_by_gender()
  local sprites = cutsceneSprites()
  sprites[5] = {
    sequences = { [2] = { frames = { frame(10) }, playMode = "forward" } },
    femaleSequences = { [2] = { frames = { frame(10), frame(10), frame(10) }, playMode = "forward" } },
  }
  local scenes = {
    {
      uniqueSprites = 1,
      totalSprites = 1,
      spriteIds = { 5 },
      params = {
        { spriteIdx = 0, animSeq = 2, x = 128, y = 96, activateTime = 50 },
      },
    },
  }
  local male = CreditsScene.new({
    danceSequences = danceSequences(),
    danceSeqsByScene = DANCE_SEQS,
    cloudSeq = CLOUD_SEQ,
    cutscenes = scenes,
    cutsceneSprites = sprites,
    gender = "male",
    totalFrames = 4976,
    transitionTimings = TRANSITION_TIMINGS,
    flipTimings = TRANSITION_TIMINGS,
  })
  for _ = 1, 70 do
    male:step({})
  end
  Assert.equal(male:status().cutsceneIdx, 1, "the male player sprite finishes its short animation")
  local female = CreditsScene.new({
    danceSequences = danceSequences(),
    danceSeqsByScene = DANCE_SEQS,
    cloudSeq = CLOUD_SEQ,
    cutscenes = scenes,
    cutsceneSprites = sprites,
    gender = "female",
    totalFrames = 4976,
    transitionTimings = TRANSITION_TIMINGS,
    flipTimings = TRANSITION_TIMINGS,
  })
  for _ = 1, 70 do
    female:step({})
  end
  Assert.equal(female:status().cutsceneIdx, 0, "the female player sprite still plays its longer animation")
end

function T.tests.fails_fast_when_a_cutscene_sprite_has_no_realized_animation()
  local sprites = cutsceneSprites()
  sprites[0] = { sequences = {} }
  local ok, err = pcall(newSceneWith, sprites)
  Assert.isTrue(ok == false, "an unresolvable cutscene sprite fails construction")
  Assert.isTrue(
    tostring(err):find("animation", 1, true) ~= nil,
    "the failure names the missing animation: " .. tostring(err)
  )
end

function T.tests.ends_the_roll_at_the_source_frame_count()
  local scene = newScene()
  for _ = 1, 4975 do
    scene:step({})
  end
  Assert.isTrue(scene:isDone() == false, "frame 4975 still rolls")
  scene:step({})
  Assert.isTrue(scene:isDone(), "frame 4976 ends the roll")
end

return T
