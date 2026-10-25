-- HoOhAppearanceScene: the field cutscene camera poses must stay inside the
-- camera's view volume, in the tile units FieldCamera consumes.

local Assert = require("tests.support.Assert")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local HoOhAppearanceScene = require("libs.hgss.src.field.HoOhAppearanceScene")
local FieldScriptScreenFade = require("libs.hgss.src.transition.FieldScriptScreenFade")
local HoOhAppearanceFixture = require("tests.support.HoOhAppearanceFixture")

local FX32_PER_TILE = 4096 * 16
local FIELD_CAMERA_DISTANCE_FX32 = 0x29AEC1

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
  function camera:setCutscenePose(target, distance, _, perspective, _, _, _, far)
    assert(type(perspective) == "number", "every pose carries its perspective")
    self.target = target
    self.distance = distance
    self.far = far or self.far
    self.poses[#self.poses + 1] = { distance = distance, far = self.far }
  end
  return camera
end

local function newAudio()
  local audio = { cues = {} }
  function audio:play(symbol)
    self.cues[#self.cues + 1] = { kind = "se", symbol = symbol }
  end
  function audio:playMusic(symbol)
    self.cues[#self.cues + 1] = { kind = "bgm", symbol = symbol }
  end
  function audio:playCry(species, pattern)
    self.cues[#self.cues + 1] =
      { kind = "cry", symbol = tostring(species) .. ":" .. tostring(pattern), tick = self.tick }
  end
  function audio:stop(symbol)
    self.cues[#self.cues + 1] = { kind = "stop", symbol = symbol }
  end
  function audio:moveSequenceVolume() end
  return audio
end

local loadLog = {}

local function newScene(versionId, camera, birdHeights, audio, bird, rtcCode)
  loadLog = {}
  local cacheFs = {
    loadLua = function(_, path)
      loadLog[#loadLog + 1] = path
      return HoOhAppearanceFixture.core()
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
      return rtcCode or 2
    end,
    setBirdHeight = function(tiles)
      if birdHeights then
        birdHeights[#birdHeights + 1] = tiles
      end
    end,
    audio = audio or newAudio(),
    revealBird = function()
      if bird then
        bird.revealed = (bird.revealed or 0) + 1
        bird.heightsAtReveal = #(birdHeights or {})
      end
    end,
    resumeField = function() end,
    setBirdFlap = function(tick)
      if bird then
        bird.flaps[#bird.flaps + 1] = tick == nil and "clear" or tick
      end
    end,
    setBirdAnimationAllowance = function(allowed)
      if bird then
        bird.animationAllowance = allowed
      end
    end,
    cacheFs = cacheFs,
  })
end

local T = { tests = {} }

function T.tests.construction_loads_nothing_and_first_use_loads_only_the_core()
  local scene = newScene("heartgold", newCamera())
  Assert.equal(#loadLog, 0, "building the scene reads no record")
  scene:command("legend_cutscene_bell_begin")
  scene:command("legend_cutscene_bell_rise")
  Assert.equal(#loadLog, 0, "commands that need no clip length read nothing")
  scene:updateFixed()
  Assert.deepEqual(loadLog, { FieldEffectAssetCache.definitionPath("ho_oh_appearance") }, "one load, of the core only")
  scene:taskTicks("legend_cutscene_bell_shimmer")
  scene:updateFixed()
  Assert.equal(#loadLog, 1, "later use serves the loaded summary")
end

function T.tests.current_variant_follows_the_rtc_code()
  for code, expected in pairs({ [0] = 0, [1] = 0, [2] = 1, [3] = 2, [4] = 2 }) do
    local scene = newScene("heartgold", newCamera(), nil, nil, nil, code)
    Assert.equal(scene:currentVariant(), expected, "RTC code " .. code)
  end
end

function T.tests.camera_move_places_the_eye_inside_the_far_plane()
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local camera = newCamera()
    local scene = newScene(versionId, camera)
    scene:command("legend_cutscene_bell_begin")
    scene:command("legend_cutscene_camera_move", 1)
    local pose = camera.poses[#camera.poses]
    Assert.equal(
      pose.distance,
      FIELD_CAMERA_DISTANCE_FX32 / FX32_PER_TILE,
      versionId .. " cutscene camera keeps the field camera distance in tiles"
    )
    Assert.isTrue(pose.distance < pose.far, versionId .. " cutscene eye is inside the far plane")
  end
end

function T.tests.camera_pan_keeps_the_eye_inside_the_far_plane_every_tick()
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local camera = newCamera()
    local scene = newScene(versionId, camera)
    scene:command("legend_cutscene_bell_begin")
    scene:command("legend_cutscene_camera_pan", 0)
    for _ = 1, scene:cameraPanTicks() do
      scene:updateFixed()
    end
    Assert.isTrue(#camera.poses > 1, versionId .. " pan updates the camera pose")
    for _, pose in ipairs(camera.poses) do
      Assert.isTrue(pose.distance < pose.far, versionId .. " pan eye is inside the far plane")
    end
  end
end

-- Field profiles carry a signed pitch while the pan targets are unsigned raw
-- angles; the pan must take the short way round, never a full revolution.
function T.tests.camera_pan_takes_the_short_arc_from_a_signed_profile_pitch()
  local camera = newCamera()
  camera.profile.angleXRaw = -0x0A00
  local pitches = {}
  function camera:setCutscenePose(target, distance, angleX)
    self.target = target
    pitches[#pitches + 1] = angleX
  end
  local scene = newScene("heartgold", camera)
  scene:command("legend_cutscene_bell_begin")
  scene:command("legend_cutscene_camera_pan", 0)
  for _ = 1, scene:cameraPanTicks() do
    scene:updateFixed()
  end
  for _, angleX in ipairs(pitches) do
    local signed = (angleX + 0x8000) % 0x10000 - 0x8000
    Assert.isTrue(
      signed >= -0x0A00 - 0x400 and signed <= -0x0A00 + 0x400,
      "pitch " .. angleX .. " stays on the short arc"
    )
  end
end

function T.tests.cinematic_plays_its_own_effects_and_music_on_source_frames()
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local audio = newAudio()
    local scene = newScene(versionId, newCamera(), nil, audio)
    scene:command("legend_cinematic", 0)
    local ticks = scene:taskTicks("legend_cinematic")
    for _ = 1, ticks + 40 do
      scene:updateFixed()
    end
    local symbols = {}
    for _, cue in ipairs(audio.cues) do
      symbols[#symbols + 1] = cue.kind .. ":" .. cue.symbol
    end
    Assert.equal(symbols[1], "se:SEQ_SE_GS_SUZUNOONPA_APRI", versionId .. " first shot opens with the bell tone")
    Assert.equal(symbols[2], "se:SEQ_SE_GS_HAKKOUTAI_SYUTUGEN", versionId .. " light appears")
    Assert.equal(symbols[3], "bgm:SEQ_GS_E_HOUOU", versionId .. " Ho-Oh music starts")
    Assert.equal(symbols[4], "se:SEQ_SE_GS_HAKKOUTAI_HIROGARI2", versionId .. " light spreads with the music")
    Assert.equal(symbols[5], "se:SEQ_SE_GS_HAKKOUTAI_HIROGARI", versionId .. " light spreads again")
    Assert.equal(symbols[6], "se:SEQ_SE_GS_HOUOUHABATAKI_APRI", versionId .. " second shot starts the wing beats")
    Assert.isTrue(#symbols >= 7, versionId .. " wing beats repeat every 64 frames")
  end
end

function T.tests.bird_approach_reveals_before_it_lowers_flaps_and_cries()
  for versionId, expected in pairs({
    heartgold = { descent = 120, flapSound = "SEQ_SE_GS_HOUOU_HABATAKI", firstSound = 1, species = "250:0" },
    soulsilver = { descent = 160, flapSound = "SEQ_SE_GS_RUGIA_HABATAKI", firstSound = 18, species = "249:0" },
  }) do
    local audio, bird, heights = newAudio(), { flaps = {} }, {}
    local scene = newScene(versionId, newCamera(), heights, audio, bird)
    scene:command("legend_cutscene_bird_approach")
    Assert.equal(bird.revealed, 1, versionId .. " reveals the legend object when the approach begins")
    Assert.equal(heights[1], expected.descent / 16, versionId .. " starts at the full descent height")
    Assert.equal(bird.heightsAtReveal, 0, versionId .. " is revealed before its first height write")
    local flapSoundTicks, cryTicks = {}, {}
    for tick = 1, scene:birdApproachTicks() do
      audio.tick = tick
      local before = #audio.cues
      scene:updateFixed()
      for index = before + 1, #audio.cues do
        local cue = audio.cues[index]
        if cue.symbol == expected.flapSound then
          flapSoundTicks[#flapSoundTicks + 1] = tick
        elseif cue.kind == "cry" then
          Assert.equal(cue.symbol, expected.species, versionId .. " cries as its own species")
          cryTicks[#cryTicks + 1] = tick
        end
      end
    end
    Assert.equal(flapSoundTicks[1], expected.firstSound, versionId .. " flaps from its first flap tick")
    Assert.equal(flapSoundTicks[2] - flapSoundTicks[1], 24, versionId .. " flaps every 24 ticks")
    Assert.isTrue(flapSoundTicks[#flapSoundTicks] <= expected.descent, versionId .. " flaps only while descending")
    Assert.equal(#cryTicks, 1, versionId .. " cries once")
    Assert.equal(cryTicks[1], expected.descent + 110, versionId .. " cries when the ring begins")
    Assert.equal(bird.flaps[1], 0, versionId .. " the flap sequence restarts at tick 0")
    Assert.equal(bird.flaps[#bird.flaps], "clear", versionId .. " returns to the idle loop after the ring")
    Assert.isNil(scene:status().birdFrame, versionId .. " the scene is over")
  end
end

local function riseBell(scene)
  scene:command("legend_cutscene_bell_begin")
  scene:command("legend_cutscene_bell_rise")
  for _ = 1, 10 do
    scene:updateFixed()
  end
end

function T.tests.shimmer_starts_without_waiting_for_the_glow()
  local scene = newScene("heartgold", newCamera())
  riseBell(scene)
  scene:command("legend_cutscene_bell_shimmer", 0)
  Assert.equal(scene:taskTicks("legend_cutscene_bell_shimmer"), 1, "the source command yields one tick")
  Assert.equal(scene:status().bellStage, "shimmer", "the glow starts at once")
end

function T.tests.shimmer_requested_mid_glow_waits_for_the_idle_loop_then_starts()
  local scene = newScene("heartgold", newCamera())
  riseBell(scene)
  scene:command("legend_cutscene_bell_shimmer", 0)
  for _ = 1, 4 do
    scene:updateFixed()
  end
  scene:command("legend_cutscene_bell_shimmer", 1)
  local wait = scene:taskTicks("legend_cutscene_bell_shimmer")
  Assert.equal(wait, 6, "the script waits out the glow already running, got " .. tostring(wait))
  for _ = 1, wait do
    scene:updateFixed()
  end
  Assert.equal(scene:status().bellStage, "shimmer", "the queued glow starts once the bell is idle")
  Assert.isTrue(scene:status().shimmerClearBellOnly, "the queued glow keeps its own selection")
end

function T.tests.camera_wait_runs_only_the_rest_of_the_pan()
  local scene = newScene("heartgold", newCamera())
  scene:command("legend_cutscene_bell_begin")
  scene:command("legend_cutscene_camera_pan", 0)
  for _ = 1, 150 do
    scene:updateFixed()
  end
  Assert.equal(scene:taskTicks("legend_cutscene_camera_wait"), 50, "the wait covers the unfinished pan")
  for _ = 1, 50 do
    scene:updateFixed()
  end
  Assert.equal(scene:taskTicks("legend_cutscene_camera_wait"), 1, "a finished pan costs the one-tick yield")
end

function T.tests.second_pan_targets_the_same_camera_point_on_both_versions()
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local scene = newScene(versionId, newCamera())
    scene:command("legend_cutscene_bell_begin")
    scene:command("legend_cutscene_camera_pan", 1)
    Assert.equal(scene:status().cameraDestination, 3, versionId .. " pans to the high camera point")
  end
end

function T.tests.legend_descends_to_its_tile_then_the_ring_plays()
  for versionId, descent in pairs({ heartgold = 120, soulsilver = 160 }) do
    local heights = {}
    local bird = { flaps = {} }
    local scene = newScene(versionId, newCamera(), heights, nil, bird)
    scene:command("legend_cutscene_bird_approach")
    Assert.isTrue(bird.animationAllowance, versionId .. " idle animation is allowed through the descent lock")
    Assert.equal(heights[1], descent / 16, versionId .. " the legend starts above its tile")
    for _ = 1, descent do
      scene:updateFixed()
    end
    Assert.equal(heights[#heights], 0, versionId .. " the legend lands on its tile")
    Assert.isFalse(bird.animationAllowance, versionId .. " the animation allowance ends at landing")
    Assert.isNil(scene:status().birdRingFrame, versionId .. " the cry ring waits for the landing")
    for _ = 1, 110 do
      scene:updateFixed()
    end
    Assert.equal(scene:status().birdRingFrame, 0, versionId .. " the cry ring starts after the landing delays")
  end
end

function T.tests.backdrop_lifetime_outlives_the_clear_bell_scene_until_handoff()
  local scene = newScene("heartgold", newCamera())
  local fade = FieldScriptScreenFade.new()
  scene:command("legend_cutscene_bell_begin")
  scene:command("legend_cutscene_bell_end")
  Assert.isFalse(scene:status().active, "Clear Bell effects end")
  Assert.isTrue(scene:status().backdropRetained, "the backdrop survives the outgoing fade")
  fade:startFade({ direction = "out", color = "white", duration = 6, speed = 1 })
  for _ = 1, 5 do
    fade:updateSourceFrame()
    Assert.isFalse(fade:isOpaque(), "the outgoing white fade has uncovered pixels")
    Assert.isTrue(scene:status().backdropRetained, "the backdrop stays through the incomplete fade")
  end
  fade:updateSourceFrame()
  Assert.isTrue(fade:isOpaque(), "the outgoing white fade now covers the field")
  scene:retireBackdrop()
  Assert.isFalse(scene:status().backdropRetained, "presentation can retire the backdrop at full coverage")
end

function T.tests.cinematic_returns_the_ordinary_field_camera_not_the_script_pose()
  local camera = newCamera()
  local scene = newScene("heartgold", camera)
  scene:command("legend_cutscene_bell_begin")
  scene:command("legend_cutscene_camera_move", 2)
  scene:command("legend_cutscene_bell_end")
  Assert.isTrue(camera.target.y ~= 0, "the script left the camera away from the field view")
  scene:command("legend_cinematic", 0)
  for _ = 1, 2000 do
    if not scene:status().active then
      break
    end
    scene:updateFixed()
  end
  Assert.isFalse(scene:status().active, "the cinematic ends")
  Assert.equal(camera.target.y, 0, "the field view returns")
  Assert.isTrue(camera.collapses >= 3, "every camera cut skips render interpolation")
end

return T
