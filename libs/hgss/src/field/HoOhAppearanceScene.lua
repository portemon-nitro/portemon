-- Owns the Bell Tower appearance scene state and its source-tick clocks.

local HoOhAppearanceScene = {}
HoOhAppearanceScene.__index = HoOhAppearanceScene
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")

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
local FIELD_CAMERA_DISTANCE = 0x29AEC1 / 4096 / 16
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
}
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
  assert(
    options.audio and options.audio.play and options.audio.playMusic and options.audio.playCry,
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
    clipsById = clipsById,
    cinematicFrames = cinematicFrames,
    riseTicks = riseTicks,
    shimmerTicks = shimmerTicks,
    sequence = 0,
    state = nil,
  }, HoOhAppearanceScene)
end

local function copyPosition(position)
  return { x = position.x, y = position.y, z = position.z }
end

local function offsetPosition(position, offset)
  return { x = position.x + offset.x, y = position.y + offset.y, z = position.z + offset.z }
end

local function snapshotCamera(camera)
  return {
    target = copyPosition(camera.target),
    distance = camera.distance,
    rawPerspective = camera:rawPerspective(),
    near = camera.near,
    far = camera.far,
  }
end

local function cameraTarget(scene, state, index)
  local camera = assert(state.cameraLease and state.cameraLease.camera)
  local data = CAMERA_DATA[scene.versionId]
  local offset = assert(data.offsets[index + 1], "Ho-Oh camera offset is unavailable")
  local base = state.cameraLease.target
  return { x = base.x + offset[1], y = base.y + offset[2], z = base.z + offset[3] },
    data.angles[index + 1],
    data.perspective[index + 1],
    camera
end

local function applyCameraPose(scene, state, index, progress)
  local target, angle, perspective, camera = cameraTarget(scene, state, index)
  local transition = state.cameraTransition
  if transition ~= nil then
    local start = transition.start
    target = {
      x = start.target.x + (target.x - start.target.x) * progress,
      y = start.target.y + (target.y - start.target.y) * progress,
      z = start.target.z + (target.z - start.target.z) * progress,
    }
    -- Angles are 16-bit turns: the profile pitch is signed, the pose table's is
    -- not, so take the short way round.
    local delta = (angle - start.angle + 0x8000) % 0x10000 - 0x8000
    angle = math.floor(start.angle + delta * progress + 0.5) % 0x10000
    perspective = math.floor(start.perspective + (perspective - start.perspective) * progress + 0.5)
  end
  local player = assert(scene.playerPosition(), "Ho-Oh camera requires a live player")
  camera:setCutscenePose(target, FIELD_CAMERA_DISTANCE, angle, perspective, player)
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
  state.cinematicFade = {
    color = fade.color,
    direction = fade.direction,
    duration = fade.duration,
    frame = 0,
    alpha = fade.direction == "in" and 1 or 0,
  }
end

local function restoreCinematicCamera(scene, state)
  local saved = state.cameraRestore
  if saved == nil then
    return
  end
  local camera = assert(scene.currentCamera())
  local player = assert(scene.playerPosition(), "Ho-Oh cinematic requires a live player to restore its camera")
  scene.fieldCamera = nil
  camera:setCutscenePose(
    saved.target,
    saved.distance,
    camera.profile.angleXRaw,
    saved.rawPerspective,
    player,
    camera.profile.angleYRaw,
    saved.near,
    saved.far
  )
  camera:collapseRenderInterpolation()
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
      origin = copyPosition(player),
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
    self.state.cameraLease = snapshotCamera(self.state.cameraLease.camera)
    self.state.cameraLease.camera = self.currentCamera()
    self.fieldCamera = snapshotCamera(self.state.cameraLease.camera)
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
    assert(self.currentCamera()):collapseRenderInterpolation()
  elseif op == "legend_cutscene_camera_pan" then
    assert(state ~= nil and (destination == 0 or destination == 1), "invalid Ho-Oh camera pan destination")
    state.cameraDestination = destination == 0 and 0 or 3
    state.cameraTransition = {
      start = {
        target = copyPosition(assert(self.currentCamera()).target),
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
      origin = copyPosition(player),
      birdFrame = 0,
      flapSoundCooldown = 0,
      cinematicFrame = nil,
      effectsActive = false,
    }
    self.revealBird()
    self.setBirdHeight(BIRD_DESCENT_TICKS[self.versionId] / BIRD_APPROACH_SOURCE_UNITS_PER_TILE)
  elseif op == "legend_cinematic" then
    assert(state == nil, "Ho-Oh bird approach is still active")
    assert(destination == 0, "unsupported Ho-Oh cinematic scene")
    local player = assert(self.playerPosition(), "Ho-Oh cinematic requires a live player")
    local camera = assert(self.currentCamera(), "Ho-Oh cinematic requires a live camera")
    local variant = timeOfDayVariant(self.timeOfDayCode())
    local firstFrames = assert(self.cinematicFrames.first[variant], "Ho-Oh first-shot model animation is missing")
    local secondFrames = assert(self.cinematicFrames.second[variant], "Ho-Oh second-shot model animation is missing")
    self.sequence = self.sequence + 1
    self.state = {
      active = true,
      sequence = self.sequence,
      origin = copyPosition(player),
      cinematicPhase = "first_fade_in",
      cinematicShot = "first",
      cinematicVariant = variant,
      cinematicFrame = nil,
      cinematicModelFrame = 0,
      cinematicAnimationFrames = { first = firstFrames, second = secondFrames },
      -- The retail cinematic is its own application: the field comes back with
      -- its ordinary camera, not the cutscene pose the script left behind.
      cameraRestore = self.fieldCamera or snapshotCamera(camera),
      effectsActive = false,
    }
    startCinematicFade(self.state, CINEMATIC_FADE.firstIn)
    local pose = CINEMATIC_CAMERA.first
    camera:setCutscenePose(
      offsetPosition(player, pose.target),
      pose.distance,
      pose.angleX,
      pose.perspective,
      player,
      pose.angleY,
      pose.near,
      pose.far
    )
    camera:collapseRenderInterpolation()
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
  elseif op == "legend_cinematic" then
    local state = assert(self.state and self.state.cinematicAnimationFrames, "Ho-Oh cinematic has not started")
    return math.max(state.first, 141) + math.max(state.second, 206)
  end
  error("Ho-Oh scene has no blocking task for " .. op)
end

function HoOhAppearanceScene:updateFixed()
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
    local transition = state.cameraTransition
    transition.frame = transition.frame + 1
    applyCameraPose(self, state, state.cameraDestination, math.min(1, transition.frame / transition.duration))
    if transition.frame >= transition.duration then
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
    if fade ~= nil then
      fade.frame = fade.frame + 1
      local progress = math.min(1, fade.frame / fade.duration)
      fade.alpha = fade.direction == "in" and (1 - progress) or progress
      if fade.frame >= fade.duration then
        state.cinematicFade = nil
      end
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
        camera:setCutscenePose(
          offsetPosition(player, pose.target),
          pose.distance,
          pose.angleX,
          pose.perspective,
          player,
          pose.angleY,
          pose.near,
          pose.far
        )
        camera:collapseRenderInterpolation()
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
    elseif state.cinematicPhase == "second_fade_in" and state.cinematicFade == nil then
      state.cinematicPhase = "second"
      state.cinematicFrame = 0
    elseif state.cinematicPhase == "second" then
      if state.cinematicModelFrame >= state.cinematicAnimationFrames.second and state.cinematicFade == nil then
        restoreCinematicCamera(self, state)
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
  if state == nil then
    return { active = false, sequence = self.sequence }
  end
  local offsets = self.versionId == "heartgold" and HG_CORNER_OFFSETS or SS_CORNER_OFFSETS
  return {
    active = state.active,
    sequence = state.sequence,
    versionId = self.versionId,
    origin = copyPosition(state.origin),
    bellStage = state.bellStage,
    bellVisible = state.bellVisible,
    bellFrame = state.bellFrame,
    loopFrame = state.loopFrame,
    shimmerFrame = state.shimmerFrame,
    shimmerClearBellOnly = state.shimmerClearBellOnly,
    cornerOffsets = offsets,
    effectsActive = state.effectsActive,
    effectFrame = state.effectFrame,
    leavesActive = state.effectsActive and self.versionId == "heartgold",
    leafFrame = state.leafFrame,
    cameraDestination = state.cameraDestination,
    birdFrame = state.birdFrame,
    birdRingFrame = self:birdRingFrame(state),
    cinematicFrame = state.cinematicFrame,
    cinematicShot = state.cinematicShot,
    cinematicVariant = state.cinematicVariant,
    cinematicModelFrame = state.cinematicModelFrame,
    cinematicFadeColor = state.cinematicFade and state.cinematicFade.color or nil,
    cinematicFadeAlpha = state.cinematicFade and state.cinematicFade.alpha or nil,
  }
end

return HoOhAppearanceScene
