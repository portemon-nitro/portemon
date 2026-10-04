-- Strict generated-cache readiness: a completion marker plus a malformed
-- current index/descriptor must never read as ready. Required arrays must be
-- arrays, identity fields must match, and referenced artifacts must be present
-- and loadable. Missing schema fields must not default to empty collections.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local HgssFieldEdgeColors = require("romdump.src.digest.field.HgssFieldEdgeColors")
local HgssFieldFog = require("romdump.src.digest.field.HgssFieldFog")
local CollisionFixture = require("tests.support.CollisionFixture")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local T = {}
local SCRIPT_GENERATION = string.rep("a", 40)
local function cache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

local AVATAR_STATE_KEYS = {
  "walking",
  "cycling",
  "surfing",
  "rocket",
  "watering",
  "fishing",
  "poketch",
  "saving",
  "heal",
  "ladder",
  "rocket_heal",
  "pokeathlon",
  "apricorn_shake",
  "rocket_saving",
}

local function writeActorIndex(c, spriteIds)
  local states = {}
  local available = 0
  if type(spriteIds) == "table" then
    available = #spriteIds
  end
  for i, name in ipairs(AVATAR_STATE_KEYS) do
    states[name] = available > 0 and spriteIds[((i - 1) % available) + 1] or 0
  end
  local function capability(id, gender)
    local own = {}
    for name, spriteId in pairs(states) do
      own[name] = spriteId
    end
    return { id = id, gender = gender, states = own }
  end
  c:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    spriteIds = spriteIds,
    runtime = {
      avatars = { capability("hero", 0), capability("heroine", 1) },
      variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
    },
  })
  c:write(FieldActorCache.markerPath(), "m")
end

local function validPose()
  return {
    frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } },
    loop = true,
    durationTicks = 1,
  }
end

local function validIdlePose()
  return validPose()
end

local function validDirections()
  return {
    north = { idle = validIdlePose(), walk = validIdlePose() },
    south = { idle = validIdlePose(), walk = validIdlePose() },
    west = { idle = validIdlePose(), walk = validIdlePose() },
    east = { idle = validIdlePose(), walk = validIdlePose() },
  }
end

local function validPolygon()
  return {
    cullMode = "back",
    polygonMode = "modulation",
    polygonId = 1,
    polygonAlpha = 31,
    lightMask = 0,
    translucentDepthWrite = false,
    depthEqual = false,
    fogEnabled = false,
  }
end

local function validVertices()
  return {
    { x = -1, y = 0, z = 0, u = 0, v = 0, nx = 0, ny = 1, nz = 0, r = 255, g = 0, b = 0, a = 255, colorSource = 0 },
    { x = 1, y = 0, z = 0, u = 1, v = 0, nx = 0, ny = 1, nz = 0, r = 0, g = 255, b = 0, colorSource = 1 },
    { x = 1, y = 2, z = 0, u = 1, v = 1, nx = 0, ny = 1, nz = 0, r = 0, g = 0, b = 255, colorSource = 2 },
    { x = -1, y = 2, z = 0, u = 0, v = 1, nx = 0, ny = 1, nz = 0, r = 255, g = 255, b = 255, a = 128, colorSource = 0 },
  }
end

local function validIndices()
  return { 0, 1, 2, 0, 2, 3 }
end

local function validAtlasGeometry()
  return {
    vertices = validVertices(),
    indices = validIndices(),
    anchorTiles = { x = 0, y = 0, z = 0 },
    bounds = { width = 2, height = 2, depth = 0 },
    baseTransform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
  }
end

local function validStaticGeometry()
  return {
    vertices = validVertices(),
    indices = validIndices(),
    anchorTiles = { x = 0, y = 0, z = 0 },
    bounds = { width = 2, height = 2, depth = 0 },
    center = { 0, 1, 0 },
  }
end

local function validAtlasRender(spriteId, frameCount)
  return {
    kind = "atlas",
    image = FieldActorCache.atlasPath(spriteId),
    frameWidth = 32,
    frameHeight = 32,
    frameCount = frameCount or 1,
    alphaClass = "opaque",
    polygon = validPolygon(),
    geometry = validAtlasGeometry(),
  }
end

local function validStaticPart()
  return {
    textured = true,
    alphaClass = "opaque",
    polygon = validPolygon(),
    geometry = validStaticGeometry(),
  }
end

local function validStaticRender(spriteId, frameCount, parts)
  return {
    kind = "staticModel",
    image = FieldActorCache.atlasPath(spriteId),
    frameWidth = 64,
    frameHeight = 64,
    frameCount = frameCount or 1,
    parts = parts or { validStaticPart() },
  }
end

local function writeActorVisual(c, spriteId)
  c:writeLua(FieldActorCache.visualPath(spriteId), {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    render = validAtlasRender(spriteId, 1),
    idlePresentation = {
      mode = "static",
      cadence = 0,
    },
    directions = validDirections(),
    gestures = {},
  })
  c:write(FieldActorCache.atlasPath(spriteId), "atlas-bytes")
end

local function writeActorVisualWithGestures(c, spriteId, gestures, frameCount)
  c:writeLua(FieldActorCache.visualPath(spriteId), {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    render = validAtlasRender(spriteId, frameCount or 1),
    idlePresentation = {
      mode = "static",
      cadence = 0,
    },
    directions = validDirections(),
    gestures = gestures,
  })
  c:write(FieldActorCache.atlasPath(spriteId), "atlas-bytes")
end

local function writeStaticModelVisual(c, spriteId, gestures, frameCount)
  c:writeLua(FieldActorCache.visualPath(spriteId), {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    render = validStaticRender(spriteId, frameCount or 1, nil),
    idlePresentation = {
      mode = "static",
      cadence = 0,
    },
    directions = validDirections(),
    gestures = gestures or {},
  })
  c:write(FieldActorCache.atlasPath(spriteId), "atlas-bytes")
end

local function avatarStateMap(firstSpriteId)
  local states = {}
  for i, name in ipairs(AVATAR_STATE_KEYS) do
    states[name] = firstSpriteId + i - 1
  end
  return states
end

local function completeAvatarSetup()
  local heroStates = avatarStateMap(0)
  local heroineStates = avatarStateMap(20)
  local spriteIds = {}
  for _, states in ipairs({ heroStates, heroineStates }) do
    for _, name in ipairs(AVATAR_STATE_KEYS) do
      spriteIds[#spriteIds + 1] = states[name]
    end
  end
  table.sort(spriteIds)
  local avatars = {
    { id = "hero", gender = 0, states = heroStates },
    { id = "heroine", gender = 1, states = heroineStates },
  }
  return spriteIds, avatars
end

local function writeAvatarStateIndex(c, spriteIds, avatars)
  c:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    spriteIds = spriteIds,
    runtime = {
      avatars = avatars,
      variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
    },
  })
  c:write(FieldActorCache.markerPath(), "m")
end

local function writeVisualsFor(c, spriteIds)
  for _, spriteId in ipairs(spriteIds) do
    writeActorVisual(c, spriteId)
  end
end

local function writeMessageIndex(c, bankIds)
  c:writeLua(FieldMessageCache.indexPath(), {
    schema = FieldMessageCache.INDEX_SCHEMA,
    bankIds = bankIds,
  })
  c:write(FieldMessageCache.markerPath(), "m")
end

local function mapScene(mapId)
  return {
    schema = MapAssetCache.SCENE_SCHEMA,
    mapId = mapId,
    mapBatches = {},
    materials = {},
    buildingInstances = {},
    neighbors = {},
    terrainAnimations = { textureSrt = false },
  }
end

local function writeMapScene(c, mapId, scene)
  c:writeLua(MapAssetCache.mapDir(mapId) .. "/scene.lua", scene or mapScene(mapId))
  c:writeLua(MapAssetCache.terrainPath(mapId), { schema = "g4-terrain-surfaces-v1" })
  c:write(MapAssetCache.mapDir(mapId) .. "/dependencies.lua", "return {}\n")
  c:write(MapAssetCache.collisionPath(mapId), CollisionFixture.asset(32, 32))
  c:write(MapAssetCache.mapDir(mapId) .. "/complete", "m")
end

-- The generated render-environment record every current field record
-- carries: parsed lighting, the area edge-color table, the map weather id,
-- and the helper-derived fog preset.
local function validRenderEnvironment()
  return {
    lighting = {
      records = {
        {
          startHalfSeconds = 0,
          lights = {},
          diffuseRgb555 = 0,
          ambientRgb555 = 0,
          specularRgb555 = 0,
          emissionRgb555 = 0,
        },
      },
    },
    edgeColors = HgssFieldEdgeColors.tableForAreaLightPattern(0),
    weatherId = 0,
    fog = HgssFieldFog.runtimePreset(HgssFieldFog.resolve(0)),
  }
end

local function writeFieldRecord(c, mapId, events, audioPolicy, schema)
  audioPolicy = audioPolicy
    or {
      music = { day = "SEQ_X", night = "SEQ_X", flagOverrides = {}, traversalOverrides = {} },
      soundplates = {},
    }
  c:writeLua(FieldMapDataCache.fieldPath(mapId), {
    schema = schema or FieldMapDataCache.FIELD_SCHEMA,
    mapId = mapId,
    mapSymbol = "test",
    transitionEnvironment = "outdoors",
    renderEnvironment = validRenderEnvironment(),
    fieldUse = {
      flyAllowed = true,
      teleportAllowed = true,
      escapeAllowed = false,
      flashUsable = false,
      alphChamber = false,
      icePathB2F = false,
      cave = false,
      unionOrColosseum = false,
    },
    events = events,
    music = audioPolicy.music,
    soundplates = audioPolicy.soundplates,
    initScripts = {},
  })
  c:writeLua(FieldMapDataCache.dependenciesPath(mapId), { cacheFormat = FieldMapDataCache.FORMAT })
  c:write(FieldMapDataCache.markerPath(mapId), "m")
end

local function writeCurrentFieldRecord(c, mapId, transitionEnvironment)
  writeFieldRecord(
    c,
    mapId,
    { background = {}, objects = {}, warps = {}, coordinates = {} },
    nil,
    FieldMapDataCache.FIELD_SCHEMA
  )
  local field = assert(c:loadLua(FieldMapDataCache.fieldPath(mapId)))
  field.transitionEnvironment = transitionEnvironment
  c:writeLua(FieldMapDataCache.fieldPath(mapId), field)
end

local function writeFieldObjectRecord(c, object)
  writeFieldRecord(c, 60, {
    background = {},
    objects = { object },
    warps = {},
    coordinates = {},
  })
end

local function writeGenerationIndex(c, generation, marker, resources, memberAudioSequences)
  local closures = memberAudioSequences
  if closures == nil then
    closures = {}
    for _, entry in ipairs(resources) do
      if type(entry) == "table" and type(entry.member) == "number" then
        closures[tostring(entry.member)] = {}
      end
    end
  end
  c:write(ScriptCache.generationMarkerPath(generation), marker)
  c:writeLua(ScriptCache.generationIndexPath(generation), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = generation,
    marker = marker,
    resources = resources,
    memberAudioSequences = closures,
  })
end

local function writeScriptIndex(c, resources)
  c:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_GENERATION,
    marker = "m",
  })
  c:write(ScriptCache.markerPath(), "m")
  writeGenerationIndex(c, SCRIPT_GENERATION, "m", resources)
end

local function writeGenerationResource(c, generation, member, id, kind)
  c:write(
    ScriptCache.scriptPath(generation, member, id),
    string.format('return { kind = "%s", id = "%s" }\n', kind or "field_script", id)
  )
end

function T.actor_index_with_complete_avatar_state_maps_is_ready()
  local c = cache()
  local spriteIds, avatars = completeAvatarSetup()
  writeAvatarStateIndex(c, spriteIds, avatars)
  writeVisualsFor(c, spriteIds)
  Assert.isTrue(FieldActorCache.isReady(c, "m"), "complete gendered state maps must be ready")
end

function T.actor_visual_with_wrong_identity_is_not_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  c:writeLua(FieldActorCache.visualPath(0), { schema = FieldActorCache.SCHEMA, spriteId = 7 })
  c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "visual file identity must match its index entry")
end

function T.actor_visual_with_malformed_idle_presentation_is_not_ready()
  local cases = {
    { mode = "unknown", cadence = 0 },
    { mode = "static", cadence = 1 },
    { mode = "animated", cadence = 0 },
    { mode = "static", cadence = "0" },
  }
  for _, idlePresentation in ipairs(cases) do
    local c = cache()
    writeActorIndex(c, { 0 })
    c:writeLua(FieldActorCache.visualPath(0), {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = { kind = "atlas", image = FieldActorCache.atlasPath(0), frameCount = 1 },
      idlePresentation = { mode = idlePresentation.mode, cadence = idlePresentation.cadence },
      directions = validDirections(),
    })
    c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    Assert.isFalse(FieldActorCache.isReady(c, "m"), "malformed idle presentation must fail readiness")
  end
end

function T.actor_visual_with_malformed_gesture_pose_is_not_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisualWithGestures(c, 0, {
    give = { pose = { frames = {}, loop = false, durationTicks = 1 }, displayOffset = { x = 0, y = 0, z = 1 / 32 } },
  }, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "empty gesture pose must fail")

  c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisualWithGestures(c, 0, {
    give = {
      pose = { frames = { { frameIndex = 2, ticks = 1 } }, loop = false, durationTicks = 1 },
      displayOffset = { x = 0, y = 0, z = 0 },
    },
  }, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "out-of-range gesture frameIndex must fail")

  c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisualWithGestures(c, 0, {
    give = {
      pose = { frames = { { frameIndex = 1, ticks = 0 } }, loop = false, durationTicks = 1 },
      displayOffset = { x = 0, y = 0, z = 0 },
    },
  }, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "zero-tick gesture pose must fail")

  c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisualWithGestures(c, 0, {
    give = {
      pose = { frames = { { frameIndex = 1, ticks = 1 } }, loop = false, durationTicks = 2 },
      displayOffset = { x = 0, y = 0, z = 0 },
    },
  }, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "duration-mismatch gesture pose must fail")

  c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisualWithGestures(c, 0, {
    give = { displayOffset = { x = 0, y = 0, z = 0 } },
  }, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "missing gesture pose must fail")
end

function T.message_index_with_missing_bank_is_not_ready()
  local c = cache()
  writeMessageIndex(c, { 542 })
  Assert.isFalse(FieldMessageCache.isReady(c, "m"), "an indexed bank file is required")
end

function T.message_bank_with_wrong_schema_is_not_ready()
  local c = cache()
  writeMessageIndex(c, { 542 })
  c:writeLua(FieldMessageCache.bankPath(542), { schema = "g4-other-v1", bankId = 542 })
  Assert.isFalse(FieldMessageCache.isReady(c, "m"), "bank file must carry the expected schema")
end

function T.message_valid_artifact_is_ready()
  local c = cache()
  writeMessageIndex(c, { 542 })
  c:writeLua(FieldMessageCache.bankPath(542), { schema = FieldMessageCache.SCHEMA, bankId = 542 })
  Assert.isTrue(FieldMessageCache.isReady(c, "m"))
end

-- Map scene, model descriptors, and neighbor cells

function T.map_scene_with_wrong_schema_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.schema = "g4-map-scene-v2"
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "scene identity must carry the expected schema")
end

function T.map_batch_without_geometry_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.mapBatches = { { material = 0 } }
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "every batch must reference a geometry path")
end

function T.map_neighbor_cell_without_batches_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.neighbors = { { offsetTilesX = 0, offsetTilesY = 0, offsetTilesZ = 32, materials = {} } }
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "neighbor cells must carry batches and materials arrays")
end

function T.map_valid_artifact_is_ready()
  local c = cache()
  writeMapScene(c, 61)
  Assert.isTrue(MapAssetCache.isReady(c, 61, "m"))
end

-- Field-map record collections

function T.current_field_data_requires_a_valid_transition_environment()
  for _, environment in ipairs({ "cave", "outdoors", "building" }) do
    local c = cache()
    writeCurrentFieldRecord(c, 60, environment)
    Assert.isTrue(FieldMapDataCache.isReady(c, 60, "m"), environment)
  end

  for _, case in ipairs({ { value = nil }, { value = "unknown" } }) do
    local c = cache()
    writeCurrentFieldRecord(c, 60, case.value)
    Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"), "invalid transition environment")
  end
end

function T.field_data_with_partial_events_is_not_ready()
  local c = cache()
  writeFieldRecord(c, 60, { background = {}, objects = {} })
  Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"), "all four event collections are required")
end

function T.field_data_rejects_objects_without_semantic_movement_types()
  local cases = {
    { movement = nil, xRange = 0, yRange = 0 },
    { movement = 3, xRange = 0, yRange = 0 },
    { movement = 3, movementType = "wander_around", xRange = 0, yRange = 0 },
    { movementType = "3", xRange = 0, yRange = 0 },
    { movementType = "unknown", xRange = 0, yRange = 0 },
  }
  for _, object in ipairs(cases) do
    local c = cache()
    writeFieldObjectRecord(c, object)
    Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"), "object movement type must be a known semantic string")
  end
end

function T.field_data_valid_artifact_is_ready()
  local c = cache()
  writeFieldRecord(c, 60, { background = {}, objects = {}, warps = {}, coordinates = {} })
  Assert.isTrue(FieldMapDataCache.isReady(c, 60, "m"))
end

function T.field_data_rejects_malformed_init_descriptor_union()
  local c = cache()
  writeFieldRecord(c, 60, { background = {}, objects = {}, warps = {}, coordinates = {} })
  local field = assert(c:loadLua(FieldMapDataCache.fieldPath(60)))
  field.initScripts = { { type = "on_resume", scriptId = "vanilla.hgss.scr_seq.0001.script_000", extra = true } }
  c:writeLua(FieldMapDataCache.fieldPath(60), field)
  Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"))
end

function T.script_generation_with_wrong_marker_is_not_ready()
  local c = cache()
  writeGenerationIndex(c, SCRIPT_GENERATION, "m", {})
  Assert.isFalse(ScriptCache.isGenerationReady(c, SCRIPT_GENERATION, "other"))
end

function T.script_generation_with_missing_or_malformed_resource_is_not_ready()
  local c = cache()
  local resources = { { id = "a.b", member = 1, scriptIndex = 0 } }
  writeGenerationIndex(c, SCRIPT_GENERATION, "m", resources)
  Assert.isFalse(ScriptCache.isGenerationReady(c, SCRIPT_GENERATION, "m"))

  writeGenerationResource(c, SCRIPT_GENERATION, 1, "a.b", "other")
  Assert.isFalse(ScriptCache.isGenerationReady(c, SCRIPT_GENERATION, "m"))
end

function T.script_generation_with_duplicate_entries_is_not_ready()
  local c = cache()
  local resources = {
    { id = "a.b", member = 1, scriptIndex = 0, resourceHash = string.rep("1", 64) },
    { id = "a.b", member = 1, scriptIndex = 0, resourceHash = string.rep("1", 64) },
  }
  writeGenerationIndex(c, SCRIPT_GENERATION, "m", resources)
  writeGenerationResource(c, SCRIPT_GENERATION, 1, "a.b")
  Assert.isFalse(ScriptCache.isGenerationReady(c, SCRIPT_GENERATION, "m"), "duplicate index entries are not ready")
end

function T.script_valid_artifact_is_ready()
  local c = cache()
  writeScriptIndex(c, { { id = "a.b", member = 1, scriptIndex = 0, resourceHash = string.rep("3", 64) } })
  c:write(
    ScriptCache.scriptPath(SCRIPT_GENERATION, 1, "a.b"),
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = "a.b", steps = { S.stop() } }\n'
  )
  Assert.isTrue(ScriptCache.isReady(c, "m"))
end

function T.script_generation_without_member_audio_closure_is_not_ready()
  local c = cache()
  local resources = { { id = "a.b", member = 1, scriptIndex = 0, resourceHash = string.rep("3", 64) } }
  c:write(ScriptCache.generationMarkerPath(SCRIPT_GENERATION), "m")
  c:writeLua(ScriptCache.generationIndexPath(SCRIPT_GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_GENERATION,
    marker = "m",
    resources = resources,
  })
  writeGenerationResource(c, SCRIPT_GENERATION, 1, "a.b")
  Assert.isFalse(
    ScriptCache.isGenerationReady(c, SCRIPT_GENERATION, "m"),
    "every generation member requires a published audio closure"
  )
end

function T.script_member_audio_lookup_returns_the_published_closure()
  local index = {
    schema = ScriptCache.INDEX_SCHEMA,
    memberAudioSequences = { ["1"] = { "SEQ_A", "SEQ_B" }, ["7"] = {} },
  }
  Assert.deepEqual(ScriptCache.audioSequencesForMember(index, 1), { "SEQ_A", "SEQ_B" })
  Assert.deepEqual(ScriptCache.audioSequencesForMember(index, 7), {})
  Assert.isNil(ScriptCache.audioSequencesForMember(index, 2))
  Assert.isNil(ScriptCache.audioSequencesForMember({ memberAudioSequences = { ["1"] = { "B", "A" } } }, 1))
  Assert.isNil(ScriptCache.audioSequencesForMember({}, 1))
end

function T.actor_valid_atlas_and_static_renders_are_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisual(c, 0)
  local visual = c:loadLua(FieldActorCache.visualPath(0))
  Assert.isTrue(FieldActorCache.isValidVisual(visual, 0))
  Assert.isTrue(FieldActorCache.isReady(c, "m"), "valid atlas with geometry/polygon/dimensions must be ready")

  c = cache()
  writeActorIndex(c, { 1 })
  writeStaticModelVisual(c, 1, {})
  visual = c:loadLua(FieldActorCache.visualPath(1))
  Assert.isTrue(FieldActorCache.isValidVisual(visual, 1))
  Assert.isTrue(FieldActorCache.isReady(c, "m"), "valid static with parts/geometry/polygon must be ready")

  -- direct validation of helpers without cache
  Assert.isTrue(FieldActorCache.isValidVisual({
    schema = FieldActorCache.SCHEMA,
    spriteId = 0,
    render = validAtlasRender(0, 2),
    idlePresentation = { mode = "static", cadence = 0 },
    directions = validDirections(),
    gestures = {},
  }, 0))
  Assert.isTrue(FieldActorCache.isValidVisual({
    schema = FieldActorCache.SCHEMA,
    spriteId = 0,
    render = validStaticRender(0, 1, { validStaticPart(), validStaticPart() }),
    idlePresentation = { mode = "static", cadence = 0 },
    directions = validDirections(),
    gestures = {},
  }, 0))
end

function T.actor_visual_with_malformed_static_render_is_not_ready()
  local function mutateStatic(mutator, label)
    local c = cache()
    writeActorIndex(c, { 0 })
    local visual = {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = validStaticRender(0, 1),
      idlePresentation = { mode = "static", cadence = 0 },
      directions = validDirections(),
      gestures = {},
    }
    mutator(visual.render)
    c:writeLua(FieldActorCache.visualPath(0), visual)
    c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    Assert.isFalse(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0), label .. " must fail")
    Assert.isFalse(FieldActorCache.isReady(c, "m"), label .. " must fail readiness")
  end

  mutateStatic(function(r)
    r.frameCount = 2
  end, "static frameCount 2")
  mutateStatic(function(r)
    r.frameCount = 0
  end, "static frameCount 0")
  mutateStatic(function(r)
    r.parts = nil
  end, "missing parts")
  mutateStatic(function(r)
    r.parts = {}
  end, "empty parts")
  mutateStatic(function(r)
    r.parts = { named = 1 }
  end, "hash parts")
  mutateStatic(function(r)
    r.frameWidth = nil
  end, "static missing frameWidth")
  mutateStatic(function(r)
    r.frameHeight = nil
  end, "static missing frameHeight")
  mutateStatic(function(r)
    r.image = nil
  end, "static missing image")
end

return { tests = T }
