-- Owns the Bell Tower and Whirl Islands legend appearance scene state and its
-- source-tick clocks. The Bell Tower dance (both versions), the bird approach
-- (Ho-Oh in HeartGold, Lugia in SoulSilver), and both legend cinematics run
-- here because the field scripts drive them through one command surface.

local HoOhAppearanceScene = {}
HoOhAppearanceScene.__index = HoOhAppearanceScene
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local LegendCutsceneRig = require("libs.hgss.src.field.LegendCutsceneRig")

---@class HoOhAppearanceScene
---@field new fun(options: table<string, unknown>): HoOhAppearanceScene
---@field command fun(self: HoOhAppearanceScene, op: string, destination: integer?)
---@field cameraPanTicks fun(self: HoOhAppearanceScene): integer
---@field shimmerWaitTicks fun(self: HoOhAppearanceScene): integer
---@field cameraPanRemainingTicks fun(self: HoOhAppearanceScene): integer
---@field birdApproachTicks fun(self: HoOhAppearanceScene): integer
---@field birdRingTicks fun(self: HoOhAppearanceScene): integer
---@field birdRingFrame fun(self: HoOhAppearanceScene, state: table<string, unknown>): integer?
---@field taskTicks fun(self: HoOhAppearanceScene, op: string): integer
---@field updateFixed fun(self: HoOhAppearanceScene)
---@field status fun(self: HoOhAppearanceScene): table<string, unknown>

local HG_CORNER_OFFSETS = {
  { 12.5, -4.5625, 9 },
  { -12.375, -4.5625, 9 },
  { 12.5, -4.5625, -16.875 },
  { -12.375, -4.5625, -16.875 },
}
local SS_CORNER_OFFSETS = {
  { 8, 2, -11.25 },
  { -8, 2, -11.25 },
}
local CAMERA_DATA = {
  heartgold = {
    angles = { 0xF562, 0xF562, 0xF762, 0xFBA2 },
    perspective = { 0x5C1, 0x5C1, 0xCC1, 0xCC1 },
    offsets = {
      { -12.1875, -9.2878, -2.8245 },
      { 12.375, -9.2878, -2.8245 },
      { 0, -2.2345, -1.4405 },
      { 0, 30.977, 1.7956 },
    },
  },
  soulsilver = {
    angles = { 0xDFE2, 0xDFE2, 0xDEF2, 0xDEF2, 0xDEF2 },
    perspective = { 0x5C1, 0x5C1, 0x5C1, 0x5C1, 0x5C1 },
    offsets = {
      { -7.9375, 0, -13 },
      { 3.9375, 0, -13 },
      { 0, 0, -5.125 },
      { 0, 0, -27.0625 },
      { 0, 0, -14.0625 },
    },
  },
}
-- The legend actor drops one source unit per tick; sixteen units make a tile.
local BIRD_DESCENT_TICKS = { heartgold = 120, soulsilver = 160 }
local BIRD_APPROACH_SOURCE_UNITS_PER_TILE = 16
-- The legend object hovers 60 ticks after landing, then flaps until its cry ring ends.
local BIRD_LAND_TO_FLAP_TICKS = 60
local BIRD_PRE_RING_TICKS = BIRD_LAND_TO_FLAP_TICKS + 50
local BIRD_FLAP_SOUND_INTERVAL = 24
local BIRD_FIRST_FLAP_SOUND_TICK = { heartgold = 0, soulsilver = 18 }
local BIRD_FLAP_SOUND = { heartgold = "SEQ_SE_GS_HOUOU_HABATAKI", soulsilver = "SEQ_SE_GS_RUGIA_HABATAKI" }
local BIRD_SPECIES = { heartgold = 250, soulsilver = 249 }
local BIRD_POST_RING_TICKS = 30
local CINEMATIC_CAMERA = {
  first = {
    target = { x = 0x0025A7F4 / 65536, y = 0x0024282F / 65536, z = -0x0025CE83 / 65536 },
    distance = 0x004B4152 / 4096 / 16,
    angleX = 0x0C80,
    angleY = 0xD8E0,
    perspective = 0x0881,
    near = 0x00009000 / 4096 / 16,
    far = 0x006A4000 / 4096 / 16,
  },
  second = {
    target = { x = -75511 / 65536, y = -134660 / 65536, z = 241555 / 65536 },
    distance = 0x001BA152 / 4096 / 16,
    angleX = 0xECA2,
    angleY = 0x8380,
    perspective = 0x0381,
    near = 0x00096000 / 4096 / 16,
    far = 0x006A4000 / 4096 / 16,
  },
}
-- The retail cinematic's own sound cues, by frame of its first shot.
local FIRST_SHOT_CUES = {
  [0] = { "SEQ_SE_GS_SUZUNOONPA_APRI" },
  [40] = { "SEQ_SE_GS_HAKKOUTAI_SYUTUGEN" },
  [78] = { "SEQ_GS_E_HOUOU", "SEQ_SE_GS_HAKKOUTAI_HIROGARI2" },
  [98] = { "SEQ_SE_GS_HAKKOUTAI_HIROGARI" },
}
local CINEMATIC_FADE = {
  firstIn = { color = "white", direction = "in", duration = 6 },
  firstOut = { color = "black", direction = "out", duration = 6 },
  secondIn = { color = "black", direction = "in", duration = 6 },
  secondOut = { color = "white", direction = "out", duration = 10 },
  lugiaIn = { color = "black", direction = "in", duration = 6 },
  lugiaOut = { color = "black", direction = "out", duration = 6 },
}
-- The Whirl Islands eye glimmer: model 28 of the legend archive with its
-- three material clips, drawn above and behind the player. Retail sounds
-- its cue on the second tick and runs the clips to completion.
local EYE_ANIMATION_IDS = { "eye.color", "eye.pattern", "eye.joint" }
local EYE_SOUND_FRAME = 2
local EYE_SOUND = "SEQ_SE_GS_RUGIA_MENOHIKARI"
-- The Lugia-arrives platform-framing pose: the fifth retail camera entry.
-- Retail only runs it on SoulSilver; HeartGold has no fifth entry, so the
-- SoulSilver pose doubles for both versions if a mod ever invokes it there.
local ARRIVES_CAMERA_INDEX = 4
local ARRIVES_PAN_TICKS = 30
local ARRIVES_NEAR = 150 / 16
local ARRIVES_FAR = 1700 / 16
-- The retail Lugia cinematic camera, in tiles.
local LUGIA_CINEMATIC_CAMERA = {
  target = { x = 0x00004DEC / 65536, y = 0x000803CD / 65536, z = 0x0002B2F5 / 65536 },
  distance = 0x00153B51 / 4096 / 16,
  angleX = 0x0982,
  angleY = 0x1E20,
  perspective = 0x0A01,
  near = 0x0007B000 / 4096 / 16,
  far = 0x006A4000 / 4096 / 16,
}
-- The retail Lugia cinematic's own sound cues, by frame of its single shot.
-- Frame 0 starts the waterfall loop at zero volume and ramps it to 30 over
-- the first ten frames (frame * 0x300 / 0x100, then 30); the scene drives
-- that schedule through the field-audio volume contract. Frame 145 also
-- starts the display-capture motion blur, which the software renderer does
-- not reproduce: the cue timing stays exact, only the trails are missing.
local LUGIA_WATERFALL = "SEQ_SE_GS_TAKI_RUGIADEMO"
local LUGIA_WATERFALL_START_VOLUME = 0
local LUGIA_WATERFALL_FULL_VOLUME = 30
local LUGIA_WATERFALL_RAMP_FRAMES = 10
local LUGIA_CUES = {
  [0] = { LUGIA_WATERFALL },
  [115] = { "SEQ_SE_GS_RUGIA_TAKISHUTUGEN" },
  [145] = { "cry" },
}
local LUGIA_CRY_SPECIES = 249
local LUGIA_FADE_OUT_FRAME = 232
---@param options table<string, unknown>
---@return HoOhAppearanceScene
function HoOhAppearanceScene.new(options)
  assert(type(options) == "table", "Ho-Oh scene requires options")
  assert(options.versionId == "heartgold" or options.versionId == "soulsilver", "Ho-Oh scene requires a game version")
  assert(type(options.playerPosition) == "function", "Ho-Oh scene requires the live player position")
  assert(type(options.currentCamera) == "function", "Ho-Oh scene requires the live field camera")
  assert(type(options.timeOfDayCode) == "function", "Ho-Oh scene requires the live RTC time-of-day code")
  assert(type(options.setBirdHeight) == "function", "Ho-Oh scene requires the legend actor height writer")
  assert(type(options.revealBird) == "function", "Ho-Oh scene requires the legend actor reveal")
  assert(type(options.setBirdFlap) == "function", "Ho-Oh scene requires the legend actor flap writer")
  assert(type(options.resumeField) == "function", "Ho-Oh scene requires the field resume")
  assert(
    options.audio
      and options.audio.play
      and options.audio.playMusic
      and options.audio.playCry
      and options.audio.stop
      and options.audio.moveSequenceVolume,
    "Ho-Oh scene requires the field audio"
  )
  assert(options.cacheFs and options.cacheFs.loadLua, "Ho-Oh scene requires the generated model cache")
  local definition = assert(
    options.cacheFs:loadLua(FieldEffectAssetCache.definitionPath("ho_oh_appearance")),
    "Ho-Oh appearance model asset is missing from the field-effect cache"
  )
  local clipsById = {}
  local cinematicFrames = { first = {}, second = {} }
  for _, model in ipairs(assert(definition.models)) do
    for _, clip in ipairs(model.animations) do
      clipsById[clip.id] = clip.frameCount
    end
    local scene, variant = model.key:match("cinematic%.([%a]+)%.(%d+)$")
    if scene ~= nil then
      local count = 0
      for _, clip in ipairs(model.animations) do
        count = math.max(count, clip.frameCount)
      end
      cinematicFrames[scene][tonumber(variant)] = count
    end
  end
  local riseTicks = math.max(
    assert(clipsById["bell.rise.joint"]),
    assert(clipsById["bell.rise.pattern"]),
    assert(clipsById["bell.rise.srt"])
  )
  local shimmerTicks = math.max(
    assert(clipsById["bell.shimmer.joint"]),
    assert(clipsById["bell.shimmer.srt"]),
    assert(clipsById["corner_bells.srt"])
  )
  return setmetatable({
    versionId = options.versionId,
    playerPosition = options.playerPosition,
    currentCamera = options.currentCamera,
    timeOfDayCode = options.timeOfDayCode,
    setBirdHeight = options.setBirdHeight,
    audio = options.audio,
    revealBird = options.revealBird,
    setBirdFlap = options.setBirdFlap,
    resumeField = options.resumeField,
    cacheFs = options.cacheFs,
    clipsById = clipsById,
    cinematicFrames = cinematicFrames,
    riseTicks = riseTicks,
    shimmerTicks = shimmerTicks,
    lugiaClipsById = nil,
    lugiaAnimationFrames = nil,
    eyeGlimmer = nil,
    arrives = nil,
    sequence = 0,
    state = nil,
  }, HoOhAppearanceScene)
end

-- Loads the Whirl Islands model clocks on first use: the Bell Tower dance
-- never needs the Lugia bytes.
---@return table<string, integer> clipsById
---@return integer lugiaAnimationFrames
function HoOhAppearanceScene:lugiaClips()
  if self.lugiaClipsById == nil then
    local definition = assert(
      self.cacheFs:loadLua(FieldEffectAssetCache.definitionPath("lugia_appearance")),
      "Lugia appearance model asset is missing from the field-effect cache"
    )
    local clipsById = {}
    for _, model in ipairs(assert(definition.models)) do
      for _, clip in ipairs(model.animations) do
        clipsById[clip.id] = clip.frameCount
      end
    end
    self.lugiaClipsById = clipsById
    self.lugiaAnimationFrames = math.max(
      assert(clipsById["lugia.joint"]),
      assert(clipsById["lugia.color"]),
      assert(clipsById["lugia.srt"]),
      assert(clipsById["lugia.pattern"]),
      assert(clipsById["lugia.far.joint"])
    )
  end
  return self.lugiaClipsById, assert(self.lugiaAnimationFrames)
end

-- Ticks the eye-glimmer effect runs: its clips play to completion.
--@return integer
function HoOhAppearanceScene:eyeGlimmerTicks()
  local clipsById = self:lugiaClips()
  local ticks = 0
  for _, id in ipairs(EYE_ANIMATION_IDS) do
    ticks = math.max(ticks, assert(clipsById[id]))
  end
  return ticks
end

local function cameraPose(scene, state, index)
  local data = CAMERA_DATA[scene.versionId]
  local offset = assert(data.offsets[index + 1], "Ho-Oh camera offset is unavailable")
  local base = state.cameraLease.target
  return {
    target = { x = base.x + offset[1], y = base.y + offset[2], z = base.z + offset[3] },
    angle = data.angles[index + 1],
    perspective = data.perspective[index + 1],
  }
end

local function applyCameraPose(scene, state, index, progress)
  local camera = assert(state.cameraLease and state.cameraLease.camera, "Ho-Oh camera lease is missing")
  local pose = cameraPose(scene, state, index)
  local transition = state.cameraTransition
  local target, angle, perspective = pose.target, pose.angle, pose.perspective
  if transition ~= nil then
    target, angle, perspective = LegendCutsceneRig.interpolatePose(transition.start, pose, progress)
  end
  local player = assert(scene.playerPosition(), "Ho-Oh camera requires a live player")
  LegendCutsceneRig.applyPose(camera, player, target, angle, perspective)
  state.cameraAngle = angle
end

local function timeOfDayVariant(code)
  assert(type(code) == "number" and code % 1 == 0 and code >= 0 and code <= 4, "Ho-Oh RTC code is invalid")
  if code <= 1 then
    return 0
  elseif code == 2 then
    return 1
  end
  return 2
end

local function startCinematicFade(state, fade)
  state.cinematicFade = LegendCutsceneRig.startFade(fade)
end

local function restoreCinematicCamera(scene, state)
  local saved = state.cameraRestore
  if saved == nil then
    return
  end
  local camera = assert(scene.currentCamera())
  local player = assert(scene.playerPosition(), "Ho-Oh cinematic requires a live player to restore its camera")
  scene.fieldCamera = nil
  LegendCutsceneRig.applyPose(camera, player, saved.target, camera.profile.angleXRaw, saved.rawPerspective, {
    distance = saved.distance,
    angleY = camera.profile.angleYRaw,
    near = saved.near,
    far = saved.far,
  })
end

-- The retail cinematic is its own application: the field resumes (its map
-- on_resume script runs) when it exits.
local function exitCinematic(scene, state)
  restoreCinematicCamera(scene, state)
  scene.resumeField()
end

local function startQueuedShimmer(state)
  if state.queuedShimmer == nil or state.bellStage ~= "idle" or state.loopFrame == nil then
    return
  end
  state.bellStage = "shimmer"
  state.shimmerFrame = 0
  state.shimmerClearBellOnly = state.queuedShimmer == 1
  state.bellVisible = false
  state.queuedShimmer = nil
end

function HoOhAppearanceScene:command(op, destination)
  local state = self.state
  if op == "legend_cutscene_bell_begin" then
    assert(state == nil, "Ho-Oh scene is already active")
    local player = assert(self.playerPosition(), "Ho-Oh scene requires a live player")
    self.sequence = self.sequence + 1
    self.state = {
      active = true,
      sequence = self.sequence,
      origin = LegendCutsceneRig.copyPosition(player),
      cameraLease = { camera = assert(self.currentCamera(), "Ho-Oh scene requires a live camera") },
      bellFrame = 0,
      bellStage = "idle",
      bellVisible = false,
      loopFrame = nil,
      shimmerFrame = nil,
      shimmerClearBellOnly = true,
      effectsActive = false,
      effectFrame = 0,
      leafFrame = 0,
      cameraDestination = nil,
      birdFrame = nil,
      cinematicFrame = nil,
    }
    self.state.cameraLease = LegendCutsceneRig.snapshotCamera(self.state.cameraLease.camera)
    self.state.cameraLease.camera = self.currentCamera()
    self.fieldCamera = LegendCutsceneRig.snapshotCamera(self.state.cameraLease.camera)
    self.state.cameraAngle = self.state.cameraLease.camera.profile.angleXRaw
  elseif op == "legend_cutscene_bell_end" then
    assert(state ~= nil and not state.effectsActive, "Ho-Oh bell scene is not ready to end")
    self.state = nil
  elseif op == "legend_cutscene_bell_rise" then
    assert(state ~= nil and state.bellStage == "idle", "Ho-Oh bell cannot rise in its current state")
    state.bellStage = "rise"
    state.bellFrame = 0
    state.bellVisible = true
  elseif op == "legend_cutscene_bell_shimmer" then
    assert(state ~= nil and state.bellStage ~= nil, "Ho-Oh bell scene is not active")
    assert(destination == 0 or destination == 1, "Ho-Oh shimmer selection is invalid")
    assert(state.queuedShimmer == nil, "Ho-Oh shimmer is already queued")
    -- A shimmer requested while the bell is still rising or shimmering waits for
    -- the idle loop, then starts.
    state.queuedShimmer = destination
    startQueuedShimmer(state)
  elseif op == "legend_cutscene_effect_begin" then
    assert(state ~= nil and not state.effectsActive, "Ho-Oh scene effect cannot begin")
    state.effectsActive = true
    state.effectFrame = 0
  elseif op == "legend_cutscene_effect_end" then
    assert(state ~= nil and state.effectsActive, "Ho-Oh scene effect is not active")
    state.effectsActive = false
  elseif op == "legend_cutscene_camera_move" then
    assert(state ~= nil and (destination == 1 or destination == 2), "invalid Ho-Oh camera destination")
    state.cameraDestination = destination
    state.cameraTransition = nil
    applyCameraPose(self, state, destination, 1)
  elseif op == "legend_cutscene_camera_pan" then
    assert(state ~= nil and (destination == 0 or destination == 1), "invalid Ho-Oh camera pan destination")
    state.cameraDestination = destination == 0 and 0 or 3
    state.cameraTransition = {
      start = {
        target = LegendCutsceneRig.copyPosition(assert(self.currentCamera()).target),
        angle = state.cameraAngle or self.currentCamera().profile.angleXRaw,
        perspective = self.currentCamera():rawPerspective(),
      },
      frame = 0,
      duration = self:cameraPanTicks(),
    }
  elseif op == "legend_cutscene_camera_wait" then
    assert(state ~= nil and state.cameraDestination ~= nil, "Ho-Oh camera pan has not started")
  elseif op == "legend_cutscene_bird_approach" then
    assert(state == nil, "Ho-Oh bell scene is still active")
    local player = assert(self.playerPosition(), "Ho-Oh approach requires a live player")
    self.sequence = self.sequence + 1
    self.state = {
      active = true,
      sequence = self.sequence,
      origin = LegendCutsceneRig.copyPosition(player),
      birdFrame = 0,
      flapSoundCooldown = 0,
      cinematicFrame = nil,
      effectsActive = false,
    }
    self.revealBird()
    self.setBirdHeight(BIRD_DESCENT_TICKS[self.versionId] / BIRD_APPROACH_SOURCE_UNITS_PER_TILE)
  elseif op == "legend_cutscene_lugia_eye_glimmer" then
    assert(self.eyeGlimmer == nil, "Lugia eye glimmer is already active")
    local player = assert(self.playerPosition(), "Lugia eye glimmer requires a live player")
    self:lugiaClips()
    self.eyeGlimmer = { frame = 0, origin = LegendCutsceneRig.copyPosition(player) }
  elseif op == "legend_cutscene_lugia_arrives_begin" then
    assert(state == nil, "Lugia arrives cannot begin while the bell scene is active")
    assert(self.arrives == nil, "Lugia arrives effect is already active")
    local player = assert(self.playerPosition(), "Lugia arrives requires a live player")
    local camera = assert(self.currentCamera(), "Lugia arrives requires a live camera")
    local data = CAMERA_DATA.soulsilver
    local offset = assert(data.offsets[ARRIVES_CAMERA_INDEX + 1], "Lugia arrives camera offset is unavailable")
    local lease = LegendCutsceneRig.snapshotCamera(camera)
    self.arrives = {
      camera = camera,
      snapshot = lease,
      -- The pan home shares the snapshot target: the transition only reads
      -- its destination, and the snapshot target never moves after capture.
      home = {
        target = lease.target,
        angle = camera.profile.angleXRaw,
        perspective = lease.rawPerspective,
      },
      pose = {
        target = {
          x = lease.target.x + offset[1],
          y = lease.target.y + offset[2],
          z = lease.target.z + offset[3],
        },
        angle = data.angles[ARRIVES_CAMERA_INDEX + 1],
        perspective = data.perspective[ARRIVES_CAMERA_INDEX + 1],
      },
      transition = nil,
      origin = LegendCutsceneRig.copyPosition(player),
    }
    LegendCutsceneRig.applyPose(
      camera,
      player,
      self.arrives.pose.target,
      self.arrives.pose.angle,
      self.arrives.pose.perspective,
      {
        near = ARRIVES_NEAR,
        far = ARRIVES_FAR,
      }
    )
  elseif op == "legend_cutscene_lugia_arrives_camera_pan" then
    local arrives = assert(self.arrives, "Lugia arrives effect has not begun")
    assert(arrives.transition == nil, "Lugia arrives camera is already panning")
    arrives.transition = {
      -- The pan starts from the applied arrives pose, not the field
      -- profile the pose overrode.
      start = {
        target = LegendCutsceneRig.copyPosition(assert(self.currentCamera()).target),
        angle = arrives.pose.angle,
        perspective = arrives.camera:rawPerspective(),
      },
      frame = 0,
      duration = ARRIVES_PAN_TICKS,
    }
  elseif op == "legend_cutscene_lugia_arrives_end" then
    local arrives = assert(self.arrives, "Lugia arrives effect has not begun")
    assert(arrives.transition == nil, "Lugia arrives camera is still panning")
    local player = assert(self.playerPosition(), "Lugia arrives requires a live player")
    local snapshot = arrives.snapshot
    LegendCutsceneRig.applyPose(arrives.camera, player, snapshot.target, arrives.home.angle, snapshot.rawPerspective, {
      distance = snapshot.distance,
      near = snapshot.near,
      far = snapshot.far,
    })
    self.arrives = nil
  elseif op == "legend_cinematic" then
    assert(state == nil, "Ho-Oh bird approach is still active")
    assert(destination == 0 or destination == 1, "unsupported legend cinematic scene")
    local player = assert(self.playerPosition(), "Ho-Oh cinematic requires a live player")
    local camera = assert(self.currentCamera(), "Ho-Oh cinematic requires a live camera")
    if destination == 1 then
      local _, lugiaFrames = self:lugiaClips()
      self.sequence = self.sequence + 1
      self.state = {
        active = true,
        sequence = self.sequence,
        origin = LegendCutsceneRig.copyPosition(player),
        cinematicPhase = "lugia_fade_in",
        cinematicShot = "lugia",
        cinematicVariant = nil,
        cinematicFrame = nil,
        cinematicModelFrame = 0,
        lugiaAnimationFrames = lugiaFrames,
        motionBlur = false,
        -- The retail cinematic is its own application: the field comes back
        -- with its ordinary camera, not the cutscene pose the script left.
        cameraRestore = self.fieldCamera or LegendCutsceneRig.snapshotCamera(camera),
        effectsActive = false,
      }
      startCinematicFade(self.state, CINEMATIC_FADE.lugiaIn)
      local pose = LUGIA_CINEMATIC_CAMERA
      LegendCutsceneRig.applyPose(
        camera,
        player,
        LegendCutsceneRig.offsetPosition(player, pose.target),
        pose.angleX,
        pose.perspective,
        {
          distance = pose.distance,
          angleY = pose.angleY,
          near = pose.near,
          far = pose.far,
        }
      )
      return
    end
    local variant = timeOfDayVariant(self.timeOfDayCode())
    local firstFrames = assert(self.cinematicFrames.first[variant], "Ho-Oh first-shot model animation is missing")
    local secondFrames = assert(self.cinematicFrames.second[variant], "Ho-Oh second-shot model animation is missing")
    self.sequence = self.sequence + 1
    self.state = {
      active = true,
      sequence = self.sequence,
      origin = LegendCutsceneRig.copyPosition(player),
      cinematicPhase = "first_fade_in",
      cinematicShot = "first",
      cinematicVariant = variant,
      cinematicFrame = nil,
      cinematicModelFrame = 0,
      cinematicAnimationFrames = { first = firstFrames, second = secondFrames },
      -- The retail cinematic is its own application: the field comes back with
      -- its ordinary camera, not the cutscene pose the script left behind.
      cameraRestore = self.fieldCamera or LegendCutsceneRig.snapshotCamera(camera),
      effectsActive = false,
    }
    startCinematicFade(self.state, CINEMATIC_FADE.firstIn)
    local pose = CINEMATIC_CAMERA.first
    LegendCutsceneRig.applyPose(
      camera,
      player,
      LegendCutsceneRig.offsetPosition(player, pose.target),
      pose.angleX,
      pose.perspective,
      {
        distance = pose.distance,
        angleY = pose.angleY,
        near = pose.near,
        far = pose.far,
      }
    )
  else
    error("unknown Ho-Oh scene command: " .. tostring(op))
  end
end

function HoOhAppearanceScene:cameraPanTicks()
  local destination = assert(self.state and self.state.cameraDestination, "Ho-Oh camera pan has not started")
  if self.versionId == "heartgold" then
    return destination == 0 and 200 or 20
  end
  return destination == 0 and 160 or 200
end

-- Ticks until the pending shimmer has started, never fewer than the one-tick
-- yield the source command always takes.
function HoOhAppearanceScene:shimmerWaitTicks()
  local state = assert(self.state, "Ho-Oh bell scene is not active")
  local ticks = 0
  if state.queuedShimmer ~= nil then
    ticks = state.bellStage == "rise" and self.riseTicks - state.bellFrame or self.shimmerTicks - state.shimmerFrame
  end
  return math.max(1, ticks)
end

-- Ticks the source camera-pan wait still has to run: the pan is a background
-- task that began at the pan command.
function HoOhAppearanceScene:cameraPanRemainingTicks()
  local transition = assert(self.state and self.state.cameraTransition, "Ho-Oh camera pan has not started")
  return transition.duration - transition.frame
end

function HoOhAppearanceScene:birdApproachTicks()
  return BIRD_DESCENT_TICKS[self.versionId] + BIRD_PRE_RING_TICKS + self:birdRingTicks() + BIRD_POST_RING_TICKS
end

function HoOhAppearanceScene:birdRingTicks()
  return math.max(
    assert(self.clipsById["bird.joint"]),
    assert(self.clipsById["bird.color"]),
    assert(self.clipsById["bird.pattern"]),
    65
  )
end

function HoOhAppearanceScene:taskTicks(op)
  if op == "legend_cutscene_bell_shimmer" then
    return self:shimmerWaitTicks()
  elseif op == "legend_cutscene_camera_wait" then
    return math.max(1, self.state and self.state.cameraTransition and self:cameraPanRemainingTicks() or 0)
  elseif op == "legend_cutscene_bird_approach" then
    return self:birdApproachTicks()
  elseif op == "legend_cutscene_lugia_eye_glimmer" then
    return self:eyeGlimmerTicks()
  elseif op == "legend_cutscene_lugia_arrives_camera_pan" then
    assert(self.arrives, "Lugia arrives effect has not begun")
    return ARRIVES_PAN_TICKS
  elseif op == "legend_cinematic" then
    local state = assert(self.state, "legend cinematic has not started")
    if state.cinematicShot == "lugia" then
      -- The waterfall fades the single shot out six ticks after frame 232.
      return math.max(assert(state.lugiaAnimationFrames), LUGIA_FADE_OUT_FRAME + CINEMATIC_FADE.lugiaOut.duration)
    end
    local frames = assert(state.cinematicAnimationFrames, "Ho-Oh cinematic has not started")
    return math.max(frames.first, 141) + math.max(frames.second, 206)
  end
  error("Ho-Oh scene has no blocking task for " .. op)
end

function HoOhAppearanceScene:updateFixed()
  if self.eyeGlimmer ~= nil then
    local eye = self.eyeGlimmer
    eye.frame = eye.frame + 1
    if eye.frame == EYE_SOUND_FRAME then
      self.audio:play(EYE_SOUND)
    end
    if eye.frame >= self:eyeGlimmerTicks() then
      self.eyeGlimmer = nil
    end
  end
  if self.arrives ~= nil and self.arrives.transition ~= nil then
    local arrives = self.arrives
    local player = assert(self.playerPosition(), "Lugia arrives requires a live player")
    if LegendCutsceneRig.tickTransition(arrives.camera, player, arrives.transition, arrives.home) then
      arrives.transition = nil
    end
  end
  local state = self.state
  if state == nil then
    return
  end
  if state.bellStage == "rise" then
    state.bellFrame = state.bellFrame + 1
    if state.bellFrame >= self.riseTicks then
      state.bellStage = "idle"
      state.loopFrame = 0
      state.bellVisible = true
    end
  elseif state.bellStage == "shimmer" then
    state.loopFrame = assert(state.loopFrame) + 1
    state.shimmerFrame = state.shimmerFrame + 1
    if state.shimmerFrame >= self.shimmerTicks then
      state.bellStage = "idle"
      state.shimmerFrame = nil
      state.bellVisible = true
    end
  elseif state.loopFrame ~= nil then
    state.loopFrame = state.loopFrame + 1
  end
  if state.queuedShimmer ~= nil then
    startQueuedShimmer(state)
  end
  if state.effectsActive then
    state.effectFrame = state.effectFrame + 1
    if self.versionId == "heartgold" then
      state.leafFrame = state.leafFrame + 1
    end
  end
  if state.cameraTransition ~= nil then
    local pose = cameraPose(self, state, state.cameraDestination)
    local camera = assert(state.cameraLease and state.cameraLease.camera, "Ho-Oh camera lease is missing")
    local player = assert(self.playerPosition(), "Ho-Oh camera requires a live player")
    if LegendCutsceneRig.tickTransition(camera, player, state.cameraTransition, pose) then
      state.cameraTransition = nil
    end
  end
  if state.birdFrame ~= nil then
    state.birdFrame = state.birdFrame + 1
    local descentTicks = BIRD_DESCENT_TICKS[self.versionId]
    if state.birdFrame <= descentTicks then
      self.setBirdHeight((descentTicks - state.birdFrame) / BIRD_APPROACH_SOURCE_UNITS_PER_TILE)
      if state.birdFrame >= BIRD_FIRST_FLAP_SOUND_TICK[self.versionId] then
        if state.flapSoundCooldown == 0 then
          self.audio:play(BIRD_FLAP_SOUND[self.versionId])
          state.flapSoundCooldown = BIRD_FLAP_SOUND_INTERVAL
        end
        state.flapSoundCooldown = state.flapSoundCooldown - 1
      end
    end
    local flapStart = descentTicks + BIRD_LAND_TO_FLAP_TICKS
    local ringFrame = self:birdRingFrame(state)
    if ringFrame == 0 then
      self.audio:playCry(BIRD_SPECIES[self.versionId], 0)
    end
    if state.birdFrame > flapStart and (ringFrame ~= nil or state.birdFrame <= descentTicks + BIRD_PRE_RING_TICKS) then
      self.setBirdFlap(state.birdFrame - flapStart - 1)
    elseif state.birdFrame > flapStart and not state.flapEnded then
      state.flapEnded = true
      self.setBirdFlap(nil)
    end
    if state.birdFrame >= self:birdApproachTicks() then
      self.state = nil
    end
  end
  if state.cinematicPhase ~= nil then
    state.cinematicModelFrame = state.cinematicModelFrame + 1
    local fade = state.cinematicFade
    if fade ~= nil and LegendCutsceneRig.tickFade(fade) then
      state.cinematicFade = nil
    end
    if state.cinematicPhase == "first_fade_in" and state.cinematicFade == nil then
      state.cinematicPhase = "first"
      state.cinematicFrame = 0
    elseif state.cinematicPhase == "first" then
      if state.cinematicModelFrame >= state.cinematicAnimationFrames.first and state.cinematicFade == nil then
        state.cinematicPhase = "second_fade_in"
        state.cinematicShot = "second"
        state.cinematicModelFrame = 0
        state.cinematicFrame = nil
        startCinematicFade(state, CINEMATIC_FADE.secondIn)
        local camera = assert(self.currentCamera())
        local player = assert(self.playerPosition())
        local pose = CINEMATIC_CAMERA.second
        LegendCutsceneRig.applyPose(
          camera,
          player,
          LegendCutsceneRig.offsetPosition(player, pose.target),
          pose.angleX,
          pose.perspective,
          {
            distance = pose.distance,
            angleY = pose.angleY,
            near = pose.near,
            far = pose.far,
          }
        )
      else
        for _, symbol in ipairs(FIRST_SHOT_CUES[state.cinematicFrame] or {}) do
          if symbol == "SEQ_GS_E_HOUOU" then
            self.audio:playMusic(symbol)
          else
            self.audio:play(symbol)
          end
        end
        state.cinematicFrame = state.cinematicFrame + 1
        if state.cinematicFrame == 129 then
          startCinematicFade(state, CINEMATIC_FADE.firstOut)
        end
      end
    elseif state.cinematicPhase == "lugia_fade_in" and state.cinematicFade == nil then
      state.cinematicPhase = "lugia"
      state.cinematicFrame = 0
    elseif state.cinematicPhase == "lugia" then
      if state.cinematicModelFrame >= state.lugiaAnimationFrames and state.cinematicFade == nil then
        self.audio:stop(LUGIA_WATERFALL)
        exitCinematic(self, state)
        self.state = nil
      else
        for _, symbol in ipairs(LUGIA_CUES[state.cinematicFrame] or {}) do
          if symbol == "cry" then
            self.audio:playCry(LUGIA_CRY_SPECIES, 0)
            state.motionBlur = true
          elseif symbol == LUGIA_WATERFALL then
            self.audio:play(symbol, LUGIA_WATERFALL_START_VOLUME)
            self.audio:moveSequenceVolume(symbol, LUGIA_WATERFALL_FULL_VOLUME, LUGIA_WATERFALL_RAMP_FRAMES)
          else
            self.audio:play(symbol)
          end
        end
        state.cinematicFrame = state.cinematicFrame + 1
        if state.cinematicFrame == LUGIA_FADE_OUT_FRAME then
          startCinematicFade(state, CINEMATIC_FADE.lugiaOut)
        end
      end
    elseif state.cinematicPhase == "second_fade_in" and state.cinematicFade == nil then
      state.cinematicPhase = "second"
      state.cinematicFrame = 0
    elseif state.cinematicPhase == "second" then
      if state.cinematicModelFrame >= state.cinematicAnimationFrames.second and state.cinematicFade == nil then
        exitCinematic(self, state)
        self.state = nil
      else
        if state.cinematicFrame % 64 == 0 then
          self.audio:play("SEQ_SE_GS_HOUOUHABATAKI_APRI")
        end
        state.cinematicFrame = state.cinematicFrame + 1
        if state.cinematicFrame == 190 then
          startCinematicFade(state, CINEMATIC_FADE.secondOut)
        end
      end
    end
  end
end

-- The cry ring's own animation clock; nil outside the ticks it is drawn.
function HoOhAppearanceScene:birdRingFrame(state)
  if state.birdFrame == nil then
    return nil
  end
  local frame = state.birdFrame - BIRD_DESCENT_TICKS[self.versionId] - BIRD_PRE_RING_TICKS
  if frame < 0 or frame >= self:birdRingTicks() then
    return nil
  end
  return frame
end

function HoOhAppearanceScene:status()
  local state = self.state
  -- The eye glimmer and the arrives camera run beside the bell state, never
  -- inside it: the glimmer starts before the bell scene ends, and the
  -- arrives effect brackets the bird approach.
  local eye, arrives = self.eyeGlimmer, self.arrives
  if state == nil and eye == nil and arrives == nil then
    return { active = false, sequence = self.sequence }
  end
  local offsets = self.versionId == "heartgold" and HG_CORNER_OFFSETS or SS_CORNER_OFFSETS
  local origin = state and state.origin or eye and eye.origin or assert(arrives).origin
  return {
    active = true,
    sequence = self.sequence,
    versionId = self.versionId,
    origin = LegendCutsceneRig.copyPosition(origin),
    bellStage = state and state.bellStage or nil,
    bellVisible = state and state.bellVisible or nil,
    bellFrame = state and state.bellFrame or nil,
    loopFrame = state and state.loopFrame or nil,
    shimmerFrame = state and state.shimmerFrame or nil,
    shimmerClearBellOnly = state and state.shimmerClearBellOnly or nil,
    cornerOffsets = offsets,
    effectsActive = state and state.effectsActive or false,
    effectFrame = state and state.effectFrame or nil,
    leavesActive = (state and state.effectsActive or false) and self.versionId == "heartgold",
    leafFrame = state and state.leafFrame or nil,
    cameraDestination = state and state.cameraDestination or nil,
    birdFrame = state and state.birdFrame or nil,
    birdRingFrame = state and self:birdRingFrame(state) or nil,
    cinematicFrame = state and state.cinematicFrame or nil,
    cinematicShot = state and state.cinematicShot or nil,
    cinematicVariant = state and state.cinematicVariant or nil,
    cinematicModelFrame = state and state.cinematicModelFrame or nil,
    cinematicFadeColor = state and state.cinematicFade and state.cinematicFade.color or nil,
    cinematicFadeAlpha = state and state.cinematicFade and state.cinematicFade.alpha or nil,
    eyeGlimmerFrame = eye and eye.frame or nil,
    arrivesActive = arrives ~= nil,
  }
end

return HoOhAppearanceScene
