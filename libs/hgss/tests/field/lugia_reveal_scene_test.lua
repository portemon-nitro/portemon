-- LugiaReveal: the Whirl Islands eye glimmer, Lugia-arrives camera, bird
-- approach, and Lugia cinematic must follow the source frame clocks on the
-- shared legend-cutscene state machine.

local Assert = require("tests.support.Assert")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local HoOhAppearanceScene = require("libs.hgss.src.field.HoOhAppearanceScene")
local HoOhAppearanceFixture = require("tests.support.HoOhAppearanceFixture")
local LugiaAppearanceFixture = require("tests.support.LugiaAppearanceFixture")

local FX32_PER_TILE = 4096 * 16
local FIELD_CAMERA_DISTANCE_FX32 = 0x29AEC1

-- The SoulSilver Lugia-arrives pose: the retail camera table's fifth entry.
local ARRIVES_DISTANCE = FIELD_CAMERA_DISTANCE_FX32 / FX32_PER_TILE
local ARRIVES_ANGLE = 0xDEF2
local ARRIVES_PERSPECTIVE = 0x5C1
local ARRIVES_OFFSET = { 0, 0, -14.0625 }

local function newCamera()
  local camera = {
    target = { x = 0, y = 0, z = 0 },
    distance = 1,
    far = 1700 / 16,
    near = 150 / 16,
    profile = { angleXRaw = 0 },
    poses = {},
    collapses = 0,
  }
  function camera:collapseRenderInterpolation()
    self.collapses = self.collapses + 1
  end
  function camera:rawPerspective()
    return 0x5C1
  end
  function camera:setCutscenePose(target, distance, angleX, perspective, _, _, near, far)
    self.target = target
    self.distance = distance
    self.near = near or self.near
    self.far = far or self.far
    self.poses[#self.poses + 1] = { target = target, distance = distance, angleX = angleX, perspective = perspective }
  end
  return camera
end

local function newAudio()
  local audio = { cues = {} }
  function audio:play(symbol, volume)
    self.cues[#self.cues + 1] = { kind = "se", symbol = symbol, volume = volume }
  end
  function audio:playMusic(symbol)
    self.cues[#self.cues + 1] = { kind = "bgm", symbol = symbol }
  end
  function audio:playCry(species, pattern)
    self.cues[#self.cues + 1] = { kind = "cry", symbol = tostring(species) .. ":" .. tostring(pattern) }
  end
  function audio:stop(symbol)
    self.cues[#self.cues + 1] = { kind = "stop", symbol = symbol }
  end
  function audio:moveSequenceVolume(symbol, target, durationFrames)
    self.cues[#self.cues + 1] = { kind = "volume", symbol = symbol, target = target, duration = durationFrames }
  end
  return audio
end

local function newScene(versionId, camera, audio, resumes)
  local cacheFs = {
    loadLua = function(_, path)
      if path == FieldEffectAssetCache.definitionPath("ho_oh_appearance") then
        return HoOhAppearanceFixture.definition()
      end
      Assert.equal(path, FieldEffectAssetCache.definitionPath("lugia_appearance"), "scene loads its model definitions")
      return LugiaAppearanceFixture.definition()
    end,
  }
  return HoOhAppearanceScene.new({
    versionId = versionId,
    playerPosition = function()
      return { x = 0, y = 0, z = 0 }
    end,
    currentCamera = function()
      return camera
    end,
    timeOfDayCode = function()
      return 2
    end,
    setBirdHeight = function() end,
    audio = audio or newAudio(),
    revealBird = function() end,
    setBirdFlap = function() end,
    resumeField = function()
      if resumes then
        resumes.count = resumes.count + 1
      end
    end,
    cacheFs = cacheFs,
  })
end

local T = { tests = {} }

function T.tests.eye_glimmer_plays_its_sound_on_the_second_tick_and_clears()
  local audio = newAudio()
  local scene = newScene("soulsilver", newCamera(), audio)
  scene:command("legend_cutscene_lugia_eye_glimmer")
  Assert.equal(scene:taskTicks("legend_cutscene_lugia_eye_glimmer"), 61, "the glimmer blocks for its animation")
  Assert.equal(scene:status().eyeGlimmerFrame, 0, "the glimmer effect starts at frame zero")
  scene:updateFixed()
  Assert.equal(#audio.cues, 0, "no sound on the first glimmer tick")
  scene:updateFixed()
  Assert.equal(audio.cues[1].symbol, "SEQ_SE_GS_RUGIA_MENOHIKARI", "the eyes sound on the second tick")
  for _ = 1, 59 do
    scene:updateFixed()
  end
  Assert.isNil(scene:status().eyeGlimmerFrame, "the glimmer clears after its animation")
end

function T.tests.eye_glimmer_runs_beside_the_bell_scene()
  local scene = newScene("soulsilver", newCamera())
  scene:command("legend_cutscene_bell_begin")
  scene:command("legend_cutscene_lugia_eye_glimmer")
  Assert.equal(scene:status().bellStage, "idle", "the bell scene stays active under the glimmer")
  Assert.equal(scene:status().eyeGlimmerFrame, 0, "the glimmer starts while the bell is active")
end

function T.tests.lugia_arrives_applies_its_pose_then_pans_home_over_thirty_ticks()
  local camera = newCamera()
  local scene = newScene("soulsilver", camera)
  scene:command("legend_cutscene_bell_begin")
  scene:command("legend_cutscene_camera_move", 2)
  scene:command("legend_cutscene_bell_end")
  local scripted = { x = camera.target.x, y = camera.target.y, z = camera.target.z }
  scene:command("legend_cutscene_lugia_arrives_begin")
  local pose = camera.poses[#camera.poses]
  Assert.equal(pose.distance, ARRIVES_DISTANCE, "the arrives effect keeps the field camera distance")
  Assert.equal(pose.angleX, ARRIVES_ANGLE, "the arrives effect takes its own pitch")
  Assert.equal(pose.perspective, ARRIVES_PERSPECTIVE, "the arrives effect takes its own perspective")
  Assert.deepEqual(
    { pose.target.x, pose.target.y, pose.target.z },
    { scripted.x + ARRIVES_OFFSET[1], scripted.y + ARRIVES_OFFSET[2], scripted.z + ARRIVES_OFFSET[3] },
    "the arrives effect frames the platform from the script camera"
  )
  Assert.equal(scene:taskTicks("legend_cutscene_lugia_arrives_camera_pan"), 30, "the return pan lasts thirty ticks")
  scene:command("legend_cutscene_lugia_arrives_camera_pan")
  scene:updateFixed()
  -- One tick in, the pitch has barely left the arrives pose: a pan rooted
  -- at the stale field profile would sit near zero instead.
  Assert.isTrue(camera.poses[#camera.poses].angleX > ARRIVES_ANGLE, "the pan starts from the arrives pose")
  for _ = 1, 29 do
    scene:updateFixed()
  end
  Assert.deepEqual(
    { camera.target.x, camera.target.y, camera.target.z },
    { scripted.x, scripted.y, scripted.z },
    "the pan returns the script camera exactly"
  )
  scene:command("legend_cutscene_lugia_arrives_end")
  Assert.isFalse(scene:status().active, "the arrives effect releases the scene")
end

function T.tests.lugia_cinematic_plays_its_own_cues_then_restores_the_field_camera()
  local camera = newCamera()
  local audio = newAudio()
  local resumes = { count = 0 }
  local scene = newScene("soulsilver", camera, audio, resumes)
  scene:command("legend_cutscene_bell_begin")
  scene:command("legend_cutscene_camera_move", 2)
  scene:command("legend_cutscene_bell_end")
  Assert.isTrue(camera.target.z ~= 0, "the script left the camera away from the field view")
  scene:command("legend_cinematic", 1)
  Assert.equal(scene:taskTicks("legend_cinematic"), 246, "the Lugia cinematic blocks for its animation")
  Assert.equal(scene:status().cinematicShot, "lugia", "the Lugia cinematic presents its own shot")
  local ticks = scene:taskTicks("legend_cinematic")
  for _ = 1, ticks do
    scene:updateFixed()
  end
  Assert.isFalse(scene:status().active, "the Lugia cinematic ends")
  Assert.equal(resumes.count, 1, "the field resumes once when the cinematic application exits")
  Assert.equal(camera.target.y, 0, "the field view returns")
  local symbols = {}
  for _, cue in ipairs(audio.cues) do
    symbols[#symbols + 1] = cue.kind .. ":" .. cue.symbol
  end
  Assert.equal(symbols[1], "se:SEQ_SE_GS_TAKI_RUGIADEMO", "the waterfall starts with the cinematic")
  local shouted, cried, stopped = nil, nil, nil
  for index, symbol in ipairs(symbols) do
    if symbol == "se:SEQ_SE_GS_RUGIA_TAKISHUTUGEN" then
      shouted = index
    elseif symbol == "cry:249:0" then
      cried = index
    elseif symbol == "stop:SEQ_SE_GS_TAKI_RUGIADEMO" then
      stopped = index
    end
  end
  Assert.notNil(shouted, "the waterfall bursts forth")
  Assert.notNil(cried, "Lugia cries as itself")
  Assert.isTrue(shouted < cried, "the burst precedes the cry")
  Assert.equal(stopped, #symbols, "the waterfall stops when the cinematic ends")
end

function T.tests.lugia_cinematic_ramps_the_waterfall_from_silence_over_ten_frames()
  local audio = newAudio()
  local scene = newScene("soulsilver", newCamera(), audio)
  scene:command("legend_cinematic", 1)
  for _ = 1, 6 do
    scene:updateFixed()
  end
  Assert.equal(#audio.cues, 0, "the opening fade sounds nothing")
  scene:updateFixed()
  Assert.equal(#audio.cues, 2, "frame zero starts the waterfall and its ramp")
  Assert.equal(audio.cues[1].kind, "se", "the waterfall starts first")
  Assert.equal(audio.cues[1].symbol, "SEQ_SE_GS_TAKI_RUGIADEMO", "the waterfall starts with the cinematic")
  Assert.equal(audio.cues[1].volume, 0, "the waterfall starts at silence")
  Assert.equal(audio.cues[2].kind, "volume", "the ramp follows the start")
  Assert.equal(audio.cues[2].symbol, "SEQ_SE_GS_TAKI_RUGIADEMO", "the ramp owns the waterfall")
  Assert.equal(audio.cues[2].target, 30, "the ramp reaches the source level")
  Assert.equal(audio.cues[2].duration, 10, "the ramp spans the source ten frames")
  for _ = 1, 231 do
    scene:updateFixed()
  end
  Assert.equal(#audio.cues, 4, "frames one through 231 add only the burst and the cry")
  Assert.equal(audio.cues[4].kind, "cry", "Lugia cries as itself")
end

function T.tests.lugia_cinematic_fades_out_at_its_source_frame()
  local scene = newScene("soulsilver", newCamera())
  scene:command("legend_cinematic", 1)
  for _ = 1, 6 do
    scene:updateFixed()
  end
  Assert.isNil(scene:status().cinematicFadeColor, "the opening black fade completes")
  for _ = 1, 231 do
    scene:updateFixed()
    Assert.isNil(scene:status().cinematicFadeColor, "no closing fade before frame 232")
  end
  scene:updateFixed()
  Assert.equal(scene:status().cinematicFadeColor, "black", "frame 232 starts the closing fade")
  Assert.equal(scene:status().cinematicFadeAlpha, 0, "the closing fade starts transparent")
  for _ = 1, 5 do
    scene:updateFixed()
  end
  Assert.equal(scene:status().cinematicFadeAlpha, 5 / 6, "the closing fade covers the screen")
  scene:updateFixed()
  Assert.isNil(scene:status().cinematicFadeColor, "the closing fade completes")
end

return T
