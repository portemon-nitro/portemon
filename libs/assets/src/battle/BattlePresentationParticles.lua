-- Validated particle payloads behind the generated battle presentation
-- class: staged emitter/texture/table records for move, encounter, ball,
-- and evolution particle sets. Runtime consumes normalized semantic
-- records; physical archive identities never cross this boundary.
-- Love-free and filesystem-free.

local SchemaCheck = require("libs.assets.src.SchemaCheck")
local Validate = require("libs.assets.src.Validate")

local BattlePresentationParticles = {}

local fail = SchemaCheck.fail

local CODE_SCENE = "BATTLE_SCENE_INVALID"

local function checkInt(value, lower, upper, context, code, field)
  SchemaCheck.checkInteger(value, context, code, field, lower, upper)
end

local function checkString(value, context, code, field)
  SchemaCheck.checkNonEmptyString(value, context, code, field)
end

BattlePresentationParticles.ENCOUNTER_START_TICKS = { 1, 20 }
local ENCOUNTER_START_TICKS = BattlePresentationParticles.ENCOUNTER_START_TICKS

local function isFinite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function checkFinite(value, context, field)
  if not isFinite(value) then
    fail(CODE_SCENE, field .. " must be a finite number", context)
  end
end

local function checkBool(value, context, field)
  if type(value) ~= "boolean" then
    fail(CODE_SCENE, field .. " must be a boolean", context)
  end
end

local function checkXyz(value, context, field)
  SchemaCheck.checkRecord(value, { x = true, y = true, z = true }, context, CODE_SCENE, field)
  for _, axis in ipairs({ "x", "y", "z" }) do
    checkFinite(value[axis], context, field .. "." .. axis)
  end
end

local function checkRgb555(value, context, field)
  SchemaCheck.checkRecord(value, { r = true, g = true, b = true }, context, CODE_SCENE, field)
  for _, channel in ipairs({ "r", "g", "b" }) do
    checkInt(value[channel], 0, 31, context, CODE_SCENE, field .. "." .. channel)
  end
end

local function checkTick(value, context, field)
  checkInt(value, 0, 255, context, CODE_SCENE, field)
end

local function checkOptionalFlag(value, context, field)
  if value ~= nil and value ~= true then
    fail(CODE_SCENE, field .. " is true when present", context)
  end
end

local function checkEmitterAnimations(animations, context, field)
  SchemaCheck.checkRecord(animations, { scale = true, color = true, alpha = true }, context, CODE_SCENE, field)
  local scale = animations.scale
  if scale ~= nil then
    local at = field .. ".scale"
    SchemaCheck.checkRecord(scale, {
      startFx = true,
      normalFx = true,
      finishFx = true,
      inTick = true,
      outTick = true,
      loop = true,
    }, context, CODE_SCENE, at)
    for _, name in ipairs({ "startFx", "normalFx", "finishFx" }) do
      checkInt(scale[name], -32768, 32767, context, CODE_SCENE, at .. "." .. name)
    end
    checkTick(scale.inTick, context, at .. ".inTick")
    checkTick(scale.outTick, context, at .. ".outTick")
    checkOptionalFlag(scale.loop, context, at .. ".loop")
  end
  local color = animations.color
  if color ~= nil then
    local at = field .. ".color"
    SchemaCheck.checkRecord(color, {
      startRgb = true,
      endRgb = true,
      inTick = true,
      peakTick = true,
      outTick = true,
      interpolate = true,
      random = true,
      loop = true,
    }, context, CODE_SCENE, at)
    checkRgb555(color.startRgb, context, at .. ".startRgb")
    checkRgb555(color.endRgb, context, at .. ".endRgb")
    checkTick(color.inTick, context, at .. ".inTick")
    checkTick(color.peakTick, context, at .. ".peakTick")
    checkTick(color.outTick, context, at .. ".outTick")
    checkBool(color.interpolate, context, at .. ".interpolate")
    checkOptionalFlag(color.random, context, at .. ".random")
    checkOptionalFlag(color.loop, context, at .. ".loop")
  end
  local alpha = animations.alpha
  if alpha ~= nil then
    local at = field .. ".alpha"
    SchemaCheck.checkRecord(
      alpha,
      { start = true, normal = true, finish = true, flick = true, inTick = true, outTick = true, loop = true },
      context,
      CODE_SCENE,
      at
    )
    for _, name in ipairs({ "start", "normal", "finish" }) do
      checkInt(alpha[name], 0, 31, context, CODE_SCENE, at .. "." .. name)
    end
    checkTick(alpha.flick, context, at .. ".flick")
    checkTick(alpha.inTick, context, at .. ".inTick")
    checkTick(alpha.outTick, context, at .. ".outTick")
    checkOptionalFlag(alpha.loop, context, at .. ".loop")
  end
end

local function checkTexRepeat(value, context, field)
  SchemaCheck.checkRecord(value, { s = true, t = true }, context, CODE_SCENE, field)
  checkInt(value.s, 0, 3, context, CODE_SCENE, field .. ".s")
  checkInt(value.t, 0, 3, context, CODE_SCENE, field .. ".t")
end

-- Particle texture and polygon validators shared by every staged
-- particle family. One table local holds them because this contract chunk
-- already sits at the host local-variable ceiling.
local ParticleChecks = {}

-- One staged particle texture's sampler: nearest sampling with the
-- texture header's wrap mode per axis, the identity the shared pool
-- stages through.
function ParticleChecks.sampler(value, context, code, field)
  SchemaCheck.checkRecord(
    value,
    { minFilter = true, magFilter = true, wrapX = true, wrapY = true },
    context,
    code,
    field
  )
  if value.minFilter ~= "nearest" or value.magFilter ~= "nearest" then
    fail(code, field .. " samples with nearest filtering", context)
  end
  for _, axis in ipairs({ "wrapX", "wrapY" }) do
    local wrap = value[axis]
    if wrap ~= "clamp" and wrap ~= "repeat" and wrap ~= "mirroredrepeat" then
      fail(code, field .. "." .. axis .. " names a hardware wrap mode", context)
    end
  end
end

-- One staged particle texture's transparency classification: the shared
-- decoder's exact coverage flags, never a re-derived opaque guess.
function ParticleChecks.alphaUsage(value, context, code, field)
  SchemaCheck.checkRecord(value, { hasZero = true, hasPartial = true, hasOpaque = true }, context, code, field)
  for _, name in ipairs({ "hasZero", "hasPartial", "hasOpaque" }) do
    if type(value[name]) ~= "boolean" then
      fail(code, field .. "." .. name .. " must be a boolean", context)
    end
  end
end

-- Signed texture mirroring per axis, independent from the sampler wrap.
function ParticleChecks.reverseTex(value, context, code, field)
  SchemaCheck.checkRecord(value, { s = true, t = true }, context, code, field)
  for _, axis in ipairs({ "s", "t" }) do
    if type(value[axis]) ~= "boolean" then
      fail(code, field .. "." .. axis .. " must be a boolean", context)
    end
  end
end

-- Polygon rotation axis and plane names shared by parent and child draw
-- modes: the axis selects the source two-entry rotation table.
function ParticleChecks.polygonGeometry(axis, plane, context, code, field)
  if axis ~= "y" and axis ~= "diagonal" then
    fail(code, field .. " selects a source polygon rotation axis", context)
  end
  if plane ~= "xy" and plane ~= "xz" then
    fail(code, field .. " selects a source polygon plane", context)
  end
end

local function checkEmitterChild(child, textures, context, field)
  SchemaCheck.checkRecord(child, {
    useScaleAnm = true,
    useAlphaAnm = true,
    followEmitter = true,
    useChildColor = true,
    affectFields = true,
    childColor = true,
    drawType = true,
    rotationType = true,
    polygonRotationAxis = true,
    polygonPlane = true,
    directionFromCenter = true,
    fixedPolygonId = true,
    reverseTex = true,
    initVelRandom = true,
    scaleEnd = true,
    life = true,
    velRatio = true,
    sclRatio = true,
    genNum = true,
    genStart = true,
    genInterval = true,
    texNo = true,
    textureImage = true,
    texRepeat = true,
  }, context, CODE_SCENE, field)
  for _, name in ipairs({ "useScaleAnm", "useAlphaAnm", "followEmitter", "useChildColor" }) do
    checkBool(child[name], context, field .. "." .. name)
  end
  if child.affectFields ~= nil and child.affectFields ~= true then
    fail(CODE_SCENE, field .. ".affectFields is true when present", context)
  end
  checkRgb555(child.childColor, context, field .. ".childColor")
  checkInt(child.drawType, 0, 3, context, CODE_SCENE, field .. ".drawType")
  if child.rotationType ~= nil then
    checkInt(child.rotationType, 1, 3, context, CODE_SCENE, field .. ".rotationType")
  end
  ParticleChecks.polygonGeometry(child.polygonRotationAxis, child.polygonPlane, context, CODE_SCENE, field)
  if child.drawType >= 2 and child.polygonRotationAxis ~= "y" and child.polygonRotationAxis ~= "diagonal" then
    fail(CODE_SCENE, field .. " indexes a defined polygon rotation function", context)
  end
  if child.directionFromCenter ~= nil and child.directionFromCenter ~= true then
    fail(CODE_SCENE, field .. ".directionFromCenter is true when present", context)
  end
  if child.fixedPolygonId ~= nil and child.fixedPolygonId ~= true then
    fail(CODE_SCENE, field .. ".fixedPolygonId is true when present", context)
  end
  ParticleChecks.reverseTex(child.reverseTex, context, CODE_SCENE, field .. ".reverseTex")
  checkFinite(child.initVelRandom, context, field .. ".initVelRandom")
  checkFinite(child.scaleEnd, context, field .. ".scaleEnd")
  checkInt(child.life, 1, nil, context, CODE_SCENE, field .. ".life")
  checkInt(child.velRatio, 0, 255, context, CODE_SCENE, field .. ".velRatio")
  checkInt(child.sclRatio, 0, 255, context, CODE_SCENE, field .. ".sclRatio")
  checkInt(child.genNum, 0, nil, context, CODE_SCENE, field .. ".genNum")
  checkInt(child.genStart, 0, 255, context, CODE_SCENE, field .. ".genStart")
  checkInt(child.genInterval, 0, nil, context, CODE_SCENE, field .. ".genInterval")
  checkInt(child.texNo, 0, 255, context, CODE_SCENE, field .. ".texNo")
  local texture = textures[child.texNo]
  if texture == nil or child.textureImage ~= texture.image then
    fail(CODE_SCENE, field .. " must reference a staged texture of its set", context)
  end
  checkTexRepeat(child.texRepeat, context, field .. ".texRepeat")
end

local function checkEmitterFields(fields, context, field)
  if not Validate.isArray(fields) then
    fail(CODE_SCENE, field .. " must be an ordered field list", context)
  end
  for index, entry in ipairs(fields) do
    local at = field .. "[" .. index .. "]"
    if type(entry) ~= "table" then
      fail(CODE_SCENE, at .. " must be a record", context)
    end
    if entry.kind == "gravity" then
      SchemaCheck.checkRecord(entry, { kind = true, magnitude = true }, context, CODE_SCENE, at)
      checkXyz(entry.magnitude, context, at .. ".magnitude")
    elseif entry.kind == "magnet" then
      SchemaCheck.checkRecord(entry, { kind = true, position = true, magnitude = true }, context, CODE_SCENE, at)
      checkXyz(entry.position, context, at .. ".position")
      checkFinite(entry.magnitude, context, at .. ".magnitude")
    elseif entry.kind == "convergence" then
      SchemaCheck.checkRecord(entry, { kind = true, position = true, ratio = true }, context, CODE_SCENE, at)
      checkXyz(entry.position, context, at .. ".position")
      checkInt(entry.ratio, -32768, 32767, context, CODE_SCENE, at .. ".ratio")
    elseif entry.kind == "spin" then
      SchemaCheck.checkRecord(entry, { kind = true, rotation = true, axis = true }, context, CODE_SCENE, at)
      checkInt(entry.rotation, 0, 65535, context, CODE_SCENE, at .. ".rotation")
      checkInt(entry.axis, 0, 2, context, CODE_SCENE, at .. ".axis")
    elseif entry.kind == "random" then
      SchemaCheck.checkRecord(entry, { kind = true, magnitude = true, interval = true }, context, CODE_SCENE, at)
      checkXyz(entry.magnitude, context, at .. ".magnitude")
      checkInt(entry.interval, 1, nil, context, CODE_SCENE, at .. ".interval")
    elseif entry.kind == "collision" then
      SchemaCheck.checkRecord(
        entry,
        { kind = true, height = true, bounceFx = true, response = true },
        context,
        CODE_SCENE,
        at
      )
      checkFinite(entry.height, context, at .. ".height")
      checkInt(entry.bounceFx, -32768, 32767, context, CODE_SCENE, at .. ".bounceFx")
      if entry.response ~= "kill" and entry.response ~= "bounce" and entry.response ~= "none" then
        fail(CODE_SCENE, at .. ".response names a source collision response", context)
      end
    else
      fail(CODE_SCENE, at .. " names an unknown field kind", context)
    end
  end
end

local EMITTER_KEYS = {
  id = true,
  emitterLife = true,
  particleLife = true,
  startOffset = true,
  generation = true,
  initPosType = true,
  circleAxis = true,
  drawType = true,
  radius = true,
  length = true,
  position = true,
  axis = true,
  baseColorRgb = true,
  baseAlpha = true,
  baseScaleFx = true,
  velocityFx = true,
  velRandom = true,
  scaleRandom = true,
  lifeRandom = true,
  rotation = true,
  useRotationAnim = true,
  useInitRotationRandom = true,
  initRotation = true,
  airResist = true,
  aspect = true,
  loopFrame = true,
  dbbScale = true,
  sclAnmDirect = true,
  texRepeat = true,
  reverseTex = true,
  randomLoopPhase = true,
  cameraOffset = true,
  fixedPolygonId = true,
  polygonRotationAxis = true,
  polygonPlane = true,
  directionFromCenter = true,
  texture = true,
  textureImage = true,
  textureAnim = true,
  textureOffset = true,
  drawChildFirst = true,
  followEmitter = true,
  persistent = true,
  hideParent = true,
  animations = true,
  child = true,
  fields = true,
}

-- One compiled emitter record. Every texture the emitter, its texture
-- animation, and its child name must be a staged texture of the same set.
---@param emitter table<string, unknown> compiled emitter record under validation
---@param textures table<integer, table<string, unknown>> staged textures of the emitter set by texture id
---@param context table<string, unknown> validation context
---@param field string emitter path behind diagnostics
local function checkEncounterEmitter(emitter, textures, context, field)
  SchemaCheck.checkRecord(emitter, EMITTER_KEYS, context, CODE_SCENE, field)
  checkInt(emitter.id, 0, 255, context, CODE_SCENE, field .. ".id")
  checkInt(emitter.emitterLife, 0, nil, context, CODE_SCENE, field .. ".emitterLife")
  checkInt(emitter.particleLife, 0, nil, context, CODE_SCENE, field .. ".particleLife")
  checkInt(emitter.startOffset, 0, nil, context, CODE_SCENE, field .. ".startOffset")
  SchemaCheck.checkRecord(
    emitter.generation,
    { countFx = true, interval = true },
    context,
    CODE_SCENE,
    field .. ".generation"
  )
  checkInt(emitter.generation.countFx, nil, nil, context, CODE_SCENE, field .. ".generation.countFx")
  checkInt(emitter.generation.interval, 1, nil, context, CODE_SCENE, field .. ".generation.interval")
  checkInt(emitter.initPosType, 0, 15, context, CODE_SCENE, field .. ".initPosType")
  checkInt(emitter.circleAxis, 0, 3, context, CODE_SCENE, field .. ".circleAxis")
  checkInt(emitter.drawType, 0, 3, context, CODE_SCENE, field .. ".drawType")
  ParticleChecks.polygonGeometry(emitter.polygonRotationAxis, emitter.polygonPlane, context, CODE_SCENE, field)
  if emitter.drawType >= 2 and emitter.polygonRotationAxis ~= "y" and emitter.polygonRotationAxis ~= "diagonal" then
    fail(CODE_SCENE, field .. " indexes a defined polygon rotation function", context)
  end
  for _, name in ipairs({ "randomLoopPhase", "cameraOffset", "fixedPolygonId", "directionFromCenter" }) do
    if emitter[name] ~= nil and emitter[name] ~= true then
      fail(CODE_SCENE, field .. "." .. name .. " is true when present", context)
    end
  end
  ParticleChecks.reverseTex(emitter.reverseTex, context, CODE_SCENE, field .. ".reverseTex")
  checkFinite(emitter.radius, context, field .. ".radius")
  checkFinite(emitter.length, context, field .. ".length")
  checkXyz(emitter.position, context, field .. ".position")
  checkXyz(emitter.axis, context, field .. ".axis")
  checkRgb555(emitter.baseColorRgb, context, field .. ".baseColorRgb")
  checkInt(emitter.baseAlpha, 0, 31, context, CODE_SCENE, field .. ".baseAlpha")
  checkInt(emitter.baseScaleFx, nil, nil, context, CODE_SCENE, field .. ".baseScaleFx")
  SchemaCheck.checkRecord(emitter.velocityFx, { pos = true, axis = true }, context, CODE_SCENE, field .. ".velocityFx")
  checkInt(emitter.velocityFx.pos, nil, nil, context, CODE_SCENE, field .. ".velocityFx.pos")
  checkInt(emitter.velocityFx.axis, nil, nil, context, CODE_SCENE, field .. ".velocityFx.axis")
  checkInt(emitter.velRandom, 0, 255, context, CODE_SCENE, field .. ".velRandom")
  checkInt(emitter.scaleRandom, 0, 255, context, CODE_SCENE, field .. ".scaleRandom")
  checkInt(emitter.lifeRandom, 0, 255, context, CODE_SCENE, field .. ".lifeRandom")
  SchemaCheck.checkRecord(emitter.rotation, { min = true, max = true }, context, CODE_SCENE, field .. ".rotation")
  checkInt(emitter.rotation.min, nil, nil, context, CODE_SCENE, field .. ".rotation.min")
  checkInt(emitter.rotation.max, nil, nil, context, CODE_SCENE, field .. ".rotation.max")
  checkBool(emitter.useRotationAnim, context, field .. ".useRotationAnim")
  checkBool(emitter.useInitRotationRandom, context, field .. ".useInitRotationRandom")
  checkInt(emitter.initRotation, 0, 65535, context, CODE_SCENE, field .. ".initRotation")
  checkInt(emitter.airResist, 0, 255, context, CODE_SCENE, field .. ".airResist")
  checkFinite(emitter.aspect, context, field .. ".aspect")
  checkInt(emitter.loopFrame, 1, nil, context, CODE_SCENE, field .. ".loopFrame")
  checkInt(emitter.dbbScale, 0, 65535, context, CODE_SCENE, field .. ".dbbScale")
  checkInt(emitter.sclAnmDirect, 0, 7, context, CODE_SCENE, field .. ".sclAnmDirect")
  checkTexRepeat(emitter.texRepeat, context, field .. ".texRepeat")
  checkInt(emitter.texture, 0, 255, context, CODE_SCENE, field .. ".texture")
  local texture = textures[emitter.texture]
  if texture == nil or emitter.textureImage ~= texture.image then
    fail(CODE_SCENE, field .. " must reference a staged texture of its set", context)
  end
  local anim = emitter.textureAnim
  if anim ~= nil then
    local at = field .. ".textureAnim"
    SchemaCheck.checkRecord(anim, { textures = true, diff = true, random = true, loop = true }, context, CODE_SCENE, at)
    if not Validate.isArray(anim.textures) or #anim.textures < 1 or #anim.textures > 8 then
      fail(CODE_SCENE, at .. ".textures must list one to eight textures", context)
    end
    for index, textureId in ipairs(anim.textures) do
      checkInt(textureId, 0, 255, context, CODE_SCENE, at .. ".textures[" .. index .. "]")
      if textures[textureId] == nil then
        fail(CODE_SCENE, at .. ".textures[" .. index .. "] must reference a staged texture of its set", context)
      end
    end
    if anim.textures[1] ~= emitter.texture then
      fail(CODE_SCENE, at .. " must start on the emitter texture", context)
    end
    checkInt(anim.diff, 0, 255, context, CODE_SCENE, at .. ".diff")
    checkBool(anim.random, context, at .. ".random")
    checkBool(anim.loop, context, at .. ".loop")
  end
  local offset = emitter.textureOffset
  if offset ~= nil then
    local at = field .. ".textureOffset"
    SchemaCheck.checkRecord(offset, { mode = true, x = true, y = true }, context, CODE_SCENE, at)
    checkInt(offset.mode, 0, nil, context, CODE_SCENE, at .. ".mode")
    checkFinite(offset.x, context, at .. ".x")
    checkFinite(offset.y, context, at .. ".y")
  end
  checkOptionalFlag(emitter.drawChildFirst, context, field .. ".drawChildFirst")
  checkOptionalFlag(emitter.followEmitter, context, field .. ".followEmitter")
  checkOptionalFlag(emitter.persistent, context, field .. ".persistent")
  checkOptionalFlag(emitter.hideParent, context, field .. ".hideParent")
  checkEmitterAnimations(emitter.animations, context, field .. ".animations")
  if emitter.child ~= nil then
    checkEmitterChild(emitter.child, textures, context, field .. ".child")
  end
  checkEmitterFields(emitter.fields, context, field .. ".fields")
end

-- The retail encounter animation's two terrain emitter sets in start
-- order: each set carries its start tick, its compiled emitters, and
-- one staged RGBA image per texture.
---@param sets table<integer, table<string, unknown>> staged terrain emitter sets in start order
---@param sceneKey string scene identity behind staged texture paths
---@param context table<string, unknown> validation context
local function checkEncounterParticles(sets, sceneKey, context)
  local field = "scene encounterParticles"
  if not Validate.isArray(sets) or #sets ~= #ENCOUNTER_START_TICKS then
    fail(CODE_SCENE, field .. " must carry the two retail emitter sets", context)
  end
  local stem = sceneKey:gsub("/", "-")
  for setIndex, set in ipairs(sets) do
    local at = field .. "[" .. setIndex .. "]"
    SchemaCheck.checkRecord(set, { startTick = true, emitters = true, textures = true }, context, CODE_SCENE, at)
    if set.startTick ~= ENCOUNTER_START_TICKS[setIndex] then
      fail(CODE_SCENE, at .. ".startTick must be the retail start tick", context)
    end
    if not Validate.isArray(set.textures) or #set.textures == 0 then
      fail(CODE_SCENE, at .. ".textures must carry the set's staged textures", context)
    end
    local byId = {}
    for index, texture in ipairs(set.textures) do
      local textureField = at .. ".textures[" .. index .. "]"
      SchemaCheck.checkRecord(
        texture,
        { id = true, width = true, height = true, image = true, sampler = true, alphaUsage = true },
        context,
        CODE_SCENE,
        textureField
      )
      checkInt(texture.id, 0, 255, context, CODE_SCENE, textureField .. ".id")
      if byId[texture.id] ~= nil then
        fail(CODE_SCENE, textureField .. ".id repeats a texture of its set", context)
      end
      checkInt(texture.width, 1, 1024, context, CODE_SCENE, textureField .. ".width")
      checkInt(texture.height, 1, 1024, context, CODE_SCENE, textureField .. ".height")
      checkString(texture.image, context, CODE_SCENE, textureField .. ".image")
      ParticleChecks.sampler(texture.sampler, context, CODE_SCENE, textureField .. ".sampler")
      ParticleChecks.alphaUsage(texture.alphaUsage, context, CODE_SCENE, textureField .. ".alphaUsage")
      local expected = "assets/generated/battle/scenes/"
        .. stem
        .. "-particles-"
        .. setIndex
        .. "-"
        .. texture.id
        .. ".png"
      if texture.image ~= expected then
        fail(CODE_SCENE, textureField .. ".image must be the staged particle texture PNG of its scene", context)
      end
      byId[texture.id] = texture
    end
    if not Validate.isArray(set.emitters) or #set.emitters == 0 then
      fail(CODE_SCENE, at .. ".emitters must carry the set's emitters", context)
    end
    for index, emitter in ipairs(set.emitters) do
      checkEncounterEmitter(emitter, byId, context, at .. ".emitters[" .. index .. "]")
    end
  end
end

-- The emitter placement positions a battle particle system carries: for each
-- battler position, the staged emitter world position under each of the two
-- particle perspective types.
local PARTICLE_PLACEMENT_POSITIONS = {
  "solo-player",
  "solo-enemy",
  "player-side-slot-1",
  "enemy-side-slot-1",
  "player-side-slot-2",
  "enemy-side-slot-2",
}

-- Asserts one battle move particle system payload: its compiled
-- emitters, the staged texture keys they draw, the emitter placement
-- table, the eight per-pair axis tables, and the configured emitter
-- tables. The payload carries no random seed; the boot stream record
-- lives with the boot, never in persisted data. Every staged system is
-- fully compiled: source-undefined vocabulary fails at compile time
-- with source context, never as a staged marker.
---@param system table<string, unknown> particle system payload under validation
function BattlePresentationParticles.assertParticleSystem(system)
  local context = {}
  local field = "particle system"
  SchemaCheck.checkRecord(
    system,
    { emitters = true, textures = true, placements = true, axisTables = true, emitterTables = true },
    context,
    CODE_SCENE,
    field
  )
  if not Validate.isArray(system.textures) or #system.textures == 0 then
    fail(CODE_SCENE, field .. ".textures must carry the system's staged textures", context)
  end
  local byId = {}
  for index, texture in ipairs(system.textures) do
    local at = field .. ".textures[" .. index .. "]"
    SchemaCheck.checkRecord(
      texture,
      { id = true, width = true, height = true, image = true, sampler = true, alphaUsage = true },
      context,
      CODE_SCENE,
      at
    )
    checkInt(texture.id, 0, 255, context, CODE_SCENE, at .. ".id")
    if byId[texture.id] ~= nil then
      fail(CODE_SCENE, at .. ".id repeats a texture of its system", context)
    end
    checkInt(texture.width, 1, 1024, context, CODE_SCENE, at .. ".width")
    checkInt(texture.height, 1, 1024, context, CODE_SCENE, at .. ".height")
    checkString(texture.image, context, CODE_SCENE, at .. ".image")
    ParticleChecks.sampler(texture.sampler, context, CODE_SCENE, at .. ".sampler")
    ParticleChecks.alphaUsage(texture.alphaUsage, context, CODE_SCENE, at .. ".alphaUsage")
    byId[texture.id] = {}
  end
  if not Validate.isArray(system.emitters) or #system.emitters == 0 then
    fail(CODE_SCENE, field .. ".emitters must carry the system's emitters", context)
  end
  -- Emitters name their textures by id only; the system's texture list owns
  -- the staged resource keys.
  for index, emitter in ipairs(system.emitters) do
    checkEncounterEmitter(emitter, byId, context, field .. ".emitters[" .. index .. "]")
  end
  local allowed = {}
  for _, position in ipairs(PARTICLE_PLACEMENT_POSITIONS) do
    allowed[position] = true
  end
  SchemaCheck.checkRecord(system.placements, allowed, context, CODE_SCENE, field .. ".placements")
  for _, position in ipairs(PARTICLE_PLACEMENT_POSITIONS) do
    local at = field .. ".placements[" .. position .. "]"
    local kinds = system.placements[position]
    if not Validate.isArray(kinds) or #kinds ~= 12 then
      fail(CODE_SCENE, at .. " must carry all twelve emitter kinds", context)
    end
    for kind, perspectives in ipairs(kinds) do
      local kindAt = at .. "[" .. kind .. "]"
      if not Validate.isArray(perspectives) or #perspectives ~= 2 then
        fail(CODE_SCENE, kindAt .. " must carry one vector per particle perspective type", context)
      end
      for perspective, vector in ipairs(perspectives) do
        checkXyz(vector, context, kindAt .. "[" .. perspective .. "]")
      end
    end
  end
  local axisTables = system.axisTables
  SchemaCheck.checkRecord(axisTables, {
    mode1 = true,
    mode8 = true,
    mode10 = true,
    mode12 = true,
    mode14 = true,
    mode16 = true,
    mode18 = true,
    mode20 = true,
  }, context, CODE_SCENE, field .. ".axisTables")
  for _, mode in ipairs({ "mode1", "mode8", "mode10", "mode12", "mode14", "mode16", "mode18", "mode20" }) do
    local entries = axisTables[mode]
    if not Validate.isArray(entries) or #entries ~= 36 then
      fail(CODE_SCENE, field .. ".axisTables." .. mode .. " must carry one axis per battler-type pair", context)
    end
    for index, vector in ipairs(entries) do
      checkXyz(vector, context, field .. ".axisTables." .. mode .. "[" .. index .. "]")
    end
  end
  BattlePresentationParticles.checkEmitterTables(system.emitterTables, context, field .. ".emitterTables")
end

-- Checks one staged 36-entry signed pixel offset list.
---@param values unknown staged offset list under validation
---@param context table<string, unknown> validation context
---@param field string offset list path behind diagnostics
local function checkOffsetList(values, context, field)
  if not Validate.isArray(values) or #values ~= 36 then
    fail(CODE_SCENE, field .. " must carry one signed pixel step per battler-type pair", context)
  end
  for index, value in ipairs(values) do
    checkInt(value, -32768, 32767, context, CODE_SCENE, field .. "[" .. index .. "]")
  end
end

-- Checks the staged configured emitter tables: pixel offsets, the
-- single static vector/flag row, the seven static rows, the XY
-- position pairs, and the six unsigned camera angle triples.
---@param tables unknown staged emitter tables under validation
---@param context table<string, unknown> validation context
---@param field string emitter table path behind diagnostics
function BattlePresentationParticles.checkEmitterTables(tables, context, field)
  SchemaCheck.checkRecord(tables, {
    offsetX = true,
    offsetY = true,
    axisBase = true,
    axisRows = true,
    axisPositions = true,
    position30 = true,
    position31 = true,
    position32 = true,
    cameraAngles = true,
  }, context, CODE_SCENE, field)
  checkOffsetList(tables.offsetX, context, field .. ".offsetX")
  checkOffsetList(tables.offsetY, context, field .. ".offsetY")
  local function checkAxisRow(row, what)
    SchemaCheck.checkRecord(row, { x = true, y = true, z = true, mirrorFlag = true }, context, CODE_SCENE, what)
    checkFinite(row.x, context, what .. ".x")
    checkFinite(row.y, context, what .. ".y")
    checkFinite(row.z, context, what .. ".z")
    checkInt(row.mirrorFlag, 0, 1, context, CODE_SCENE, what .. ".mirrorFlag")
  end
  checkAxisRow(tables.axisBase, field .. ".axisBase")
  if not Validate.isArray(tables.axisRows) or #tables.axisRows ~= 7 then
    fail(CODE_SCENE, field .. ".axisRows must carry all seven static vector rows", context)
  end
  for index, row in ipairs(tables.axisRows) do
    checkAxisRow(row, field .. ".axisRows[" .. index .. "]")
  end
  local function checkPairList(pairs, count, what)
    if not Validate.isArray(pairs) or #pairs ~= count then
      fail(CODE_SCENE, what .. " must carry one XY pair per staged battler type", context)
    end
    for index, pair in ipairs(pairs) do
      SchemaCheck.checkRecord(pair, { x = true, y = true }, context, CODE_SCENE, what .. "[" .. index .. "]")
      checkFinite(pair.x, context, what .. "[" .. index .. "].x")
      checkFinite(pair.y, context, what .. "[" .. index .. "].y")
    end
  end
  checkPairList(tables.axisPositions, 6, field .. ".axisPositions")
  checkPairList(tables.position30, 7, field .. ".position30")
  checkPairList(tables.position31, 6, field .. ".position31")
  checkPairList(tables.position32, 7, field .. ".position32")
  if not Validate.isArray(tables.cameraAngles) or #tables.cameraAngles ~= 6 then
    fail(CODE_SCENE, field .. ".cameraAngles must carry all six camera angle triples", context)
  end
  for index, triple in ipairs(tables.cameraAngles) do
    local at = field .. ".cameraAngles[" .. index .. "]"
    SchemaCheck.checkRecord(triple, { x = true, y = true, z = true }, context, CODE_SCENE, at)
    for _, name in ipairs({ "x", "y", "z" }) do
      checkInt(triple[name], 0, 65535, context, CODE_SCENE, at .. "." .. name)
    end
  end
end

BattlePresentationParticles.checkEncounterParticles = checkEncounterParticles
BattlePresentationParticles.checkEncounterEmitter = checkEncounterEmitter
BattlePresentationParticles.ParticleChecks = ParticleChecks

return BattlePresentationParticles
