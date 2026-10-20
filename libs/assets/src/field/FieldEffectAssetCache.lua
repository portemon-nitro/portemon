-- Strict cache contract for the normalized field-effect model and its assets.

local Contract = require("libs.assets.src.DerivedAssetContract")
local HoOhCinematicParts = require("libs.assets.src.field.HoOhCinematicParts")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local FieldEffectAssetCache = {}
FieldEffectAssetCache.FORMAT = Contract.fieldEffects.cacheFormat
local DIR = "data/generated/field/effects"
local INDEX = DIR .. "/index.lua"
local MARKER = DIR .. "/complete"
local ASSET_DIR = "assets/generated/field/effects"

local MARKER_PREFIX = FieldEffectAssetCache.FORMAT .. ":"

local function finiteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function validLifecycle(lifecycle, frameCount)
  if type(lifecycle) ~= "table" or type(lifecycle.mode) ~= "string" then
    return false
  end
  if lifecycle.mode == "hold_until_owner_moves" then
    return finiteNumber(lifecycle.holdFrame)
      and lifecycle.holdFrame >= 0
      and lifecycle.holdFrame == math.floor(lifecycle.holdFrame)
      and finiteNumber(frameCount)
      and lifecycle.holdFrame < frameCount
      and lifecycle.frameCount == nil
  elseif lifecycle.mode == "once" then
    return finiteNumber(lifecycle.frameCount)
      and lifecycle.frameCount >= 1
      and lifecycle.frameCount == math.floor(lifecycle.frameCount)
      and finiteNumber(frameCount)
      and lifecycle.frameCount == frameCount
      and lifecycle.holdFrame == nil
  end
  return false
end

local function validPlacement(offset)
  return type(offset) == "table" and finiteNumber(offset.x) and finiteNumber(offset.y) and finiteNumber(offset.z)
end

local function validSurfPresentation(presentation)
  if type(presentation) ~= "table" then
    return false
  end
  local fieldCount = 0
  for _ in pairs(presentation) do
    fieldCount = fieldCount + 1
  end
  if fieldCount ~= 5 then
    return false
  end
  if not validPlacement(presentation.initialPlayerOffset) then
    return false
  end
  if not validPlacement(presentation.playerBaseOffset) then
    return false
  end
  if not validPlacement(presentation.attachmentBaseOffset) then
    return false
  end
  local oscillator = presentation.oscillator
  if type(oscillator) ~= "table" then
    return false
  end
  local oscillatorCount = 0
  for _ in pairs(oscillator) do
    oscillatorCount = oscillatorCount + 1
  end
  if oscillatorCount ~= 4 then
    return false
  end
  if
    not finiteNumber(oscillator.initialY)
    or not finiteNumber(oscillator.minY)
    or not finiteNumber(oscillator.maxY)
    or not finiteNumber(oscillator.stepY)
  then
    return false
  end
  if oscillator.stepY <= 0 or oscillator.minY > oscillator.maxY then
    return false
  end
  if oscillator.initialY < oscillator.minY or oscillator.initialY > oscillator.maxY then
    return false
  end
  local yaw = presentation.yawDegrees
  if type(yaw) ~= "table" then
    return false
  end
  local yawCount = 0
  for _ in pairs(yaw) do
    yawCount = yawCount + 1
  end
  if yawCount ~= 4 then
    return false
  end
  return finiteNumber(yaw.north) and finiteNumber(yaw.south) and finiteNumber(yaw.west) and finiteNumber(yaw.east)
end

local function validSurfDefinition(definition, _)
  return type(definition) == "table"
    and type(definition.model) == "table"
    and definition.model.kind == "static"
    and type(definition.lifecycle) == "nil"
    and validSurfPresentation(definition.presentation)
end

-- Shared by the single-model animated effects (grass, trainer reveal,
-- follower reaction): exactly one dynamic model carrying one compiled clip.
-- Each caller keeps its own lifecycle mode and effect-specific metadata
-- restrictions; this helper only unifies the repeated shape check.
local function singleDynamicClip(model)
  if type(model) ~= "table" or model.kind ~= "nitro-dynamic" then
    return nil
  end
  local animations = model.animations
  local clip = type(animations) == "table" and animations[1]
  if type(animations) ~= "table" or #animations ~= 1 or type(clip) ~= "table" then
    return nil
  end
  return clip
end

-- The expected lifecycle for the single clip plus the normalized placement
-- offset shared by grass and trainer reveal.
local function validSingleClipPlacement(definition, expectedMode)
  local clip = singleDynamicClip(definition.model)
  if clip == nil then
    return false
  end
  local lifecycle = definition.lifecycle
  if type(lifecycle) ~= "table" or lifecycle.mode ~= expectedMode then
    return false
  end
  return validLifecycle(lifecycle, clip.frameCount) and validPlacement(definition.placementOffset)
end

local function validGrassDefinition(definition, _)
  if type(definition.lifetime) ~= "nil" or type(definition.animation) ~= "nil" then
    return false
  end
  return validSingleClipPlacement(definition, "hold_until_owner_moves")
end

local function validTrainerRevealDefinition(definition, _)
  if type(definition.lifetime) ~= "nil" or type(definition.animation) ~= "nil" then
    return false
  end
  return validSingleClipPlacement(definition, "once")
end

-- The follower-transition definition: exactly two compiled models (one
-- static companion, one animated model carrying the single source clip),
-- the once lifecycle with the traced prelude tick count and the exact
-- compiled clip frame count, and the normalized placement offset.
local function validTransitionDefinition(definition, _)
  if type(definition.lifetime) ~= "nil" or type(definition.animation) ~= "nil" then
    return false
  end
  if type(definition.models) ~= "table" or #definition.models ~= 2 then
    return false
  end
  local animatedClip = nil
  for _, model in ipairs(definition.models) do
    if type(model) ~= "table" then
      return false
    end
    if model.kind == "nitro-dynamic" then
      if animatedClip ~= nil then
        return false
      end
      local animations = model.animations
      local clip = type(animations) == "table" and animations[1]
      if type(animations) ~= "table" or #animations ~= 1 or type(clip) ~= "table" then
        return false
      end
      animatedClip = clip
    elseif model.kind ~= "static" then
      return false
    end
  end
  if animatedClip == nil then
    return false
  end
  if type(definition.model) ~= "nil" then
    return false
  end
  local lifecycle = definition.lifecycle
  if type(lifecycle) ~= "table" or lifecycle.mode ~= "once" or lifecycle.preludeTicks ~= 2 then
    return false
  end
  return validLifecycle(lifecycle, animatedClip.frameCount) and validPlacement(definition.placementOffset)
end

local function validReactionDefinition(definition, kind)
  local selector = assert(kind:match("^follower_reaction_(%d+)$"))
  if type(definition) ~= "table" or definition.definition ~= kind then
    return false
  end
  local fieldCount = 0
  for _ in pairs(definition) do
    fieldCount = fieldCount + 1
  end
  if fieldCount ~= 3 then
    return false
  end
  local model = definition.model
  local clip = singleDynamicClip(model)
  if clip == nil then
    return false
  end
  if model.key ~= "field-effect:follower-reaction-" .. selector or type(model.dynamic) ~= "table" then
    return false
  end
  if clip.category ~= "material" or clip.kind ~= "pattern" then
    return false
  end
  local lifecycle = definition.lifecycle
  if type(lifecycle) ~= "table" or lifecycle.mode ~= "once" then
    return false
  end
  return validLifecycle(lifecycle, clip.frameCount)
end

local function validPokemonCenterHealDefinition(definition, _)
  local fieldCount = 0
  local allowed = {
    models = true,
    anchorModelKey = true,
    machineModelKey = true,
    ballAnimation = true,
    machineAnimation = true,
    machineAnimationFrameCount = true,
    ballPositions = true,
    spawnIntervalSourceFrames = true,
    placementSound = true,
    fanfare = true,
  }
  for key in pairs(definition) do
    fieldCount = fieldCount + 1
    if not allowed[key] then
      return false
    end
  end
  if fieldCount ~= 10 then
    return false
  end
  if type(definition.models) ~= "table" or #definition.models ~= 1 then
    return false
  end
  local model = definition.models[1]
  if
    type(model) ~= "table"
    or model.kind ~= "nitro-dynamic"
    or type(model.animations) ~= "table"
    or #model.animations ~= 1
  then
    return false
  end
  if
    type(definition.anchorModelKey) ~= "string"
    or definition.anchorModelKey == ""
    or type(definition.machineModelKey) ~= "string"
    or definition.machineModelKey == ""
    or definition.anchorModelKey == definition.machineModelKey
  then
    return false
  end
  if
    type(definition.ballAnimation) ~= "string"
    or definition.ballAnimation == ""
    or type(definition.machineAnimation) ~= "string"
    or definition.machineAnimation == ""
  then
    return false
  end
  local ballClip = model.animations[1]
  if ballClip.name ~= definition.ballAnimation and ballClip.id ~= definition.ballAnimation then
    return false
  end
  local machineFrameCount = definition.machineAnimationFrameCount
  if
    not finiteNumber(machineFrameCount)
    or machineFrameCount < 1
    or machineFrameCount ~= math.floor(machineFrameCount)
  then
    return false
  end
  if definition.spawnIntervalSourceFrames ~= 12 then
    return false
  end
  if definition.placementSound ~= "SEQ_SE_DP_BOWA" or definition.fanfare ~= "SEQ_ME_ASA" then
    return false
  end
  local positions = definition.ballPositions
  if type(positions) ~= "table" or #positions ~= 6 then
    return false
  end
  local expected = {
    { x = -0.28125, y = 0.75, z = -0.28125 },
    { x = 0.28125, y = 0.75, z = -0.28125 },
    { x = -0.28125, y = 0.75, z = 0 },
    { x = 0.28125, y = 0.75, z = 0 },
    { x = -0.28125, y = 0.75, z = 0.28125 },
    { x = 0.28125, y = 0.75, z = 0.28125 },
  }
  local expectedRoles = { "northwest", "northeast", "west", "east", "southwest", "southeast" }
  for index, position in ipairs(positions) do
    if type(position) ~= "table" or position.role ~= expectedRoles[index] then
      return false
    end
    local offset = position.offset
    local source = expected[index]
    if not validPlacement(offset) or offset.x ~= source.x or offset.y ~= source.y or offset.z ~= source.z then
      return false
    end
    local count = 0
    for key in pairs(position) do
      count = count + 1
      if key ~= "role" and key ~= "offset" then
        return false
      end
    end
    if count ~= 2 then
      return false
    end
  end
  return true
end

local function validCelebiTimeTravelDefinition(definition, _)
  if type(definition) ~= "table" or type(definition.model) ~= "table" then
    return false
  end
  local definitionFields = 0
  for key in pairs(definition) do
    definitionFields = definitionFields + 1
    if key ~= "model" then
      return false
    end
  end
  if definitionFields ~= 1 then
    return false
  end
  local model = definition.model
  if model.kind ~= "nitro-dynamic" or model.key ~= "field-effect:celebi-time-travel" then
    return false
  end
  local expected = {
    { id = "celebi.joint", category = "joint", kind = "trs" },
    { id = "celebi.pattern", category = "material", kind = "pattern" },
    { id = "celebi.srt", category = "material", kind = "texsrt" },
  }
  if type(model.animations) ~= "table" or #model.animations ~= #expected then
    return false
  end
  for index, selector in ipairs(expected) do
    local clip = model.animations[index]
    if
      type(clip) ~= "table"
      or clip.id ~= selector.id
      or clip.category ~= selector.category
      or clip.kind ~= selector.kind
      or type(clip.name) ~= "string"
      or type(clip.semanticNames) ~= "table"
      or #clip.semanticNames ~= 1
      or clip.semanticNames[1] ~= selector.id
      or not finiteNumber(clip.frameCount)
      or clip.frameCount < 1
      or clip.frameCount ~= math.floor(clip.frameCount)
    then
      return false
    end
  end
  return true
end

-- The Ho-Oh appearance record is published in parts so a phase loads only
-- what it uses: a core (the five non-cinematic models, the leaf overlay, and
-- a clip summary), and per cinematic shot one shared part plus one overlay
-- per time-of-day variant (see HoOhCinematicParts).
local HOOH_CORE_MODELS = {
  { key = "field-effect:ho-oh-appearance:bellRising", clips = 6 },
  { key = "field-effect:ho-oh-appearance:bellShimmer", clips = 2 },
  { key = "field-effect:ho-oh-appearance:cornerBells", clips = 1 },
  { key = "field-effect:ho-oh-appearance:birdApproach", clips = 3 },
  { key = "field-effect:ho-oh-appearance:wavesEffect", clips = 2 },
}
local HOOH_SHOT_CLIPS = { first = 4, second = 3 }
local HOOH_SHOTS = { "first", "second" }
local HOOH_VARIANT_COUNT = 3

---@param shot string "first" or "second"
---@param variant integer? 0..2, or nil for the shot's shared part
---@return string kind the field-effect inventory key of that part
function FieldEffectAssetCache.hoOhCinematicKind(shot, variant)
  assert(HOOH_SHOT_CLIPS[shot] ~= nil, "unknown Ho-Oh cinematic shot")
  if variant == nil then
    return "ho_oh_cinematic_" .. shot .. "_shared"
  end
  assert(
    type(variant) == "number" and variant % 1 == 0 and variant >= 0 and variant < HOOH_VARIANT_COUNT,
    "unknown Ho-Oh cinematic variant"
  )
  return "ho_oh_cinematic_" .. shot .. "_" .. variant
end

---@return string[] kinds every cinematic part kind, shared parts and overlays
function FieldEffectAssetCache.hoOhPartKinds()
  local kinds = {}
  for _, shot in ipairs(HOOH_SHOTS) do
    kinds[#kinds + 1] = FieldEffectAssetCache.hoOhCinematicKind(shot)
    for variant = 0, HOOH_VARIANT_COUNT - 1 do
      kinds[#kinds + 1] = FieldEffectAssetCache.hoOhCinematicKind(shot, variant)
    end
  end
  return kinds
end

local function hasExactKeys(value, keys, optionalKeys)
  if type(value) ~= "table" then
    return false
  end
  local allowed = {}
  for _, key in ipairs(keys) do
    allowed[key] = true
  end
  for _, key in ipairs(optionalKeys or {}) do
    allowed[key] = true
  end
  for key in pairs(value) do
    if not allowed[key] then
      return false
    end
  end
  for _, key in ipairs(keys) do
    if value[key] == nil then
      return false
    end
  end
  return true
end

local function validClipSummary(clips, models)
  if not hasExactKeys(clips, { "frames", "cinematic" }) then
    return false
  end
  local expected = 0
  for _, model in ipairs(models) do
    for _, clip in ipairs(model.animations) do
      expected = expected + 1
      if clips.frames[clip.id] ~= clip.frameCount then
        return false
      end
    end
  end
  local count = 0
  for _ in pairs(clips.frames) do
    count = count + 1
  end
  if count ~= expected or not hasExactKeys(clips.cinematic, HOOH_SHOTS) then
    return false
  end
  for _, shot in ipairs(HOOH_SHOTS) do
    local frames = clips.cinematic[shot]
    if type(frames) ~= "table" or #frames ~= HOOH_VARIANT_COUNT then
      return false
    end
    for _, shotFrames in ipairs(frames) do
      if not finiteNumber(shotFrames) or shotFrames <= 0 then
        return false
      end
    end
  end
  return true
end

local function validHoOhAppearanceDefinition(definition, _)
  if
    not hasExactKeys(definition, { "models", "clips" })
    and not hasExactKeys(definition, { "models", "clips", "leaves" })
  then
    return false
  end
  if type(definition.models) ~= "table" or #definition.models ~= #HOOH_CORE_MODELS then
    return false
  end
  for index, expected in ipairs(HOOH_CORE_MODELS) do
    local model = definition.models[index]
    if
      type(model) ~= "table"
      or model.kind ~= "nitro-dynamic"
      or model.key ~= expected.key
      or type(model.animations) ~= "table"
      or #model.animations ~= expected.clips
    then
      return false
    end
    for _, clip in ipairs(model.animations) do
      if type(clip) ~= "table" or type(clip.id) ~= "string" or type(clip.frameCount) ~= "number" then
        return false
      end
    end
  end
  if not validClipSummary(definition.clips, definition.models) then
    return false
  end
  if definition.leaves ~= nil then
    local leaves = definition.leaves
    if type(leaves) ~= "table" then
      return false
    end
    for key in pairs(leaves) do
      if key ~= "bg2" and key ~= "bg3" then
        return false
      end
    end
    for _, layerName in ipairs({ "bg2", "bg3" }) do
      local layer = leaves[layerName]
      if type(layer) ~= "table" or type(layer.frames) ~= "table" or #layer.frames ~= 6 then
        return false
      end
      for key in pairs(layer) do
        if key ~= "frames" then
          return false
        end
      end
      for _, frame in ipairs(layer.frames) do
        if
          type(frame) ~= "table"
          or type(frame.path) ~= "string"
          or not frame.path:match("^assets/generated/field/effects/textures/[%da-f]+%.png$")
          or frame.width ~= 256
          or frame.height ~= 256
        then
          return false
        end
        for key in pairs(frame) do
          if key ~= "path" and key ~= "width" and key ~= "height" then
            return false
          end
        end
      end
    end
  end
  return true
end

local function validHoOhSharedPart(shot)
  local function validate(definition, _)
    if not hasExactKeys(definition, { "shot", "kind", "schema", "animations", "materials" }) then
      return false
    end
    if definition.shot ~= shot or definition.kind ~= "nitro-dynamic" then
      return false
    end
    if type(definition.animations) ~= "table" or #definition.animations ~= HOOH_SHOT_CLIPS[shot] then
      return false
    end
    for _, clip in ipairs(definition.animations) do
      if type(clip) ~= "table" or type(clip.frameCount) ~= "number" then
        return false
      end
    end
    return type(definition.materials) == "table"
  end
  return validate
end

local function validHoOhOverlayPart(shot, variant)
  local function validate(definition, _)
    if
      not hasExactKeys(
        definition,
        { "shot", "variant", "key", "dynamic", "clipStrings", "materialTextures" },
        { "memberId" }
      )
    then
      return false
    end
    if
      definition.shot ~= shot
      or definition.variant ~= variant
      or definition.key ~= string.format("field-effect:ho-oh-appearance:cinematic.%s.%d", shot, variant)
      or type(definition.dynamic) ~= "table"
      or type(definition.clipStrings) ~= "table"
      or #definition.clipStrings ~= HOOH_SHOT_CLIPS[shot]
      or type(definition.materialTextures) ~= "table"
    then
      return false
    end
    for _, strings in ipairs(definition.clipStrings) do
      if type(strings) ~= "table" or type(strings.id) ~= "string" then
        return false
      end
    end
    return true
  end
  return validate
end

local function validWarpDefinition(definition, _)
  return type(definition.lifetime) == "number" and definition.lifetime > 0
end

-- The single closed inventory of published field effects: each entry carries
-- its index key, the expected index entry kind, and the definition
-- validator. This table is the only source for required index coverage and
-- deterministic declaration checks below, and the fourteen follower
-- reactions are generated from the same builder so the declared set cannot
-- drift from the validated set.
local function followerReactionEntry(selector)
  return {
    key = "follower_reaction_" .. selector,
    entryKind = "reaction",
    validator = validReactionDefinition,
  }
end

local FIELD_EFFECT_INVENTORY = {
  { key = "warp_entrance", entryKind = "model", validator = validWarpDefinition },
  { key = "tall_grass", entryKind = "animated_model", validator = validGrassDefinition },
  { key = "very_tall_grass", entryKind = "animated_model", validator = validGrassDefinition },
  { key = "trainer_reveal", entryKind = "animated_model", validator = validTrainerRevealDefinition },
  { key = "surf_attachment", entryKind = "model", validator = validSurfDefinition },
  { key = "follower_transition", entryKind = "transition", validator = validTransitionDefinition },
  { key = "pokemon_center_heal", entryKind = "healing", validator = validPokemonCenterHealDefinition },
  { key = "celebi_time_travel", entryKind = "cinematic", validator = validCelebiTimeTravelDefinition },
  { key = "ho_oh_appearance", entryKind = "cinematic", validator = validHoOhAppearanceDefinition },
}
for selector = 1, 14 do
  FIELD_EFFECT_INVENTORY[#FIELD_EFFECT_INVENTORY + 1] = followerReactionEntry(selector)
end
for _, shot in ipairs(HOOH_SHOTS) do
  FIELD_EFFECT_INVENTORY[#FIELD_EFFECT_INVENTORY + 1] = {
    key = FieldEffectAssetCache.hoOhCinematicKind(shot),
    entryKind = "cinematic",
    validator = validHoOhSharedPart(shot),
    part = true,
  }
  for variant = 0, HOOH_VARIANT_COUNT - 1 do
    FIELD_EFFECT_INVENTORY[#FIELD_EFFECT_INVENTORY + 1] = {
      key = FieldEffectAssetCache.hoOhCinematicKind(shot, variant),
      entryKind = "cinematic",
      validator = validHoOhOverlayPart(shot, variant),
      part = true,
    }
  end
end

function FieldEffectAssetCache.indexPath()
  return INDEX
end
function FieldEffectAssetCache.definitionPath(kind)
  assert(type(kind) == "string" and kind ~= "", "field-effect kind required")
  return DIR .. "/" .. kind .. ".lua"
end
function FieldEffectAssetCache.markerPath()
  return MARKER
end

---@param cacheFs CacheFs
---@param kind string
---@return table<string, unknown> definition
local function requireDefinition(cacheFs, kind)
  local definition, err = cacheFs:loadLua(FieldEffectAssetCache.definitionPath(kind))
  assert(definition ~= nil, "field-effect definition is missing from the cache: " .. kind .. " " .. tostring(err))
  return definition
end

-- The Ho-Oh core: the non-cinematic models, the leaf overlay and the clip summary.
---@param cacheFs CacheFs
---@return table<string, unknown> core
function FieldEffectAssetCache.loadHoOhCore(cacheFs)
  return requireDefinition(cacheFs, "ho_oh_appearance")
end

-- One cinematic shot's variant as the full model descriptor it was published
-- from (shared part merged with the variant's overlay).
---@param cacheFs CacheFs
---@param shot string "first" or "second"
---@param variant integer 0..2
---@return table<string, unknown> descriptor
function FieldEffectAssetCache.loadHoOhCinematic(cacheFs, shot, variant)
  assert(variant ~= nil, "a cinematic variant is required")
  local sharedKind = FieldEffectAssetCache.hoOhCinematicKind(shot)
  local overlayKind = FieldEffectAssetCache.hoOhCinematicKind(shot, variant)
  return HoOhCinematicParts.merge(requireDefinition(cacheFs, sharedKind), requireDefinition(cacheFs, overlayKind))
end

-- The full model descriptors one definition carries, for validation and
-- referenced-asset checks: a shared cinematic part carries none, an overlay
-- is merged with its shared part (found through `definitionOf(kind)`), and
-- every other definition names its own `models` or `model`.
---@param kind string
---@param definition table<string, unknown>
---@param definitionOf fun(kind: string): table<string, unknown>
---@return table<string, unknown>[] descriptors
function FieldEffectAssetCache.modelDescriptors(kind, definition, definitionOf)
  local shot, variant = kind:match("^ho_oh_cinematic_(%a+)_(%w+)$")
  if shot == nil then
    return definition.models or { definition.model }
  end
  if variant == "shared" then
    return {}
  end
  return { HoOhCinematicParts.merge(definitionOf(FieldEffectAssetCache.hoOhCinematicKind(shot)), definition) }
end
function FieldEffectAssetCache.geometryPath(sha1)
  return ASSET_DIR .. "/geometry/" .. sha1 .. ".g4mesh"
end
function FieldEffectAssetCache.texturePath(sha1)
  return ASSET_DIR .. "/textures/" .. sha1 .. ".png"
end
function FieldEffectAssetCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldEffectAssetCache.FORMAT, romSha1, depHash)
end

function FieldEffectAssetCache.isReady(cacheFs, expectedMarker)
  if type(expectedMarker) ~= "string" or expectedMarker:sub(1, #MARKER_PREFIX) ~= MARKER_PREFIX then
    return false
  end
  if cacheFs:read(MARKER) ~= expectedMarker then
    return false
  end
  local loaded, index = pcall(cacheFs.loadLua, cacheFs, INDEX)
  if not loaded or type(index) ~= "table" or index.schema ~= Contract.fieldEffects.indexSchema then
    return false
  end
  if type(index.effects) ~= "table" then
    return false
  end
  local effectCount = 0
  for _ in pairs(index.effects) do
    effectCount = effectCount + 1
  end
  if effectCount ~= #FIELD_EFFECT_INVENTORY then
    return false
  end
  local core ---@type table?
  local sharedParts = {} ---@type table<string, table>
  for _, spec in ipairs(FIELD_EFFECT_INVENTORY) do
    local kind = spec.key
    local entry = index.effects and index.effects[kind]

    if
      type(entry) ~= "table"
      or entry.kind ~= spec.entryKind
      or entry.definition ~= kind
      or entry.path ~= FieldEffectAssetCache.definitionPath(kind)
    then
      return false
    end
    local definitionLoaded, definition = pcall(cacheFs.loadLua, cacheFs, entry.path)
    if not definitionLoaded or type(definition) ~= "table" then
      return false
    end
    if (spec.entryKind == "reaction" or spec.entryKind == "cinematic") and not spec.validator(definition, kind) then
      return false
    end
    local descriptors
    if spec.part then
      local assembled, result = pcall(FieldEffectAssetCache.modelDescriptors, kind, definition, function(partKind)
        return requireDefinition(cacheFs, partKind)
      end)
      if not assembled then
        return false
      end
      descriptors = result
    else
      descriptors = definition.models or { definition.model }
      if
        kind ~= "follower_transition"
        and kind ~= "pokemon_center_heal"
        and kind ~= "ho_oh_appearance"
        and definition.models ~= nil
      then
        return false
      end
      local descriptorCount = 0
      for _ in ipairs(descriptors) do
        descriptorCount = descriptorCount + 1
      end
      if descriptorCount == 0 then
        return false
      end
    end
    if kind == "ho_oh_appearance" then
      core = definition
    end
    local sharedShot = kind:match("^ho_oh_cinematic_(%a+)_shared$")
    if sharedShot ~= nil then
      sharedParts[sharedShot] = definition
    end
    for _, descriptor in ipairs(descriptors) do
      local valid, err = pcall(ModelAsset.validate, descriptor)
      if not valid then
        return false, err
      end
      local referenced, paths = pcall(ModelAsset.referencedPaths, descriptor)
      if not referenced then
        return false, paths
      end
      for _, path in ipairs(paths) do
        if not cacheFs:exists(path) then
          return false
        end
      end
    end
    if kind == "ho_oh_appearance" and definition.leaves ~= nil then
      for _, layer in pairs(definition.leaves) do
        for _, frame in ipairs(layer.frames) do
          if not cacheFs:exists(frame.path) then
            return false
          end
        end
      end
    end
    if spec.entryKind ~= "reaction" and not spec.validator(definition, kind) then
      return false
    end
  end
  -- The core's clip summary names each shot's length: the longest clip of the
  -- shared part, for every variant.
  for _, shot in ipairs(HOOH_SHOTS) do
    local longest = 0
    for _, clip in ipairs(sharedParts[shot].animations) do
      longest = math.max(longest, clip.frameCount)
    end
    for variant = 1, HOOH_VARIANT_COUNT do
      if core.clips.cinematic[shot][variant] ~= longest then
        return false
      end
    end
  end
  return true
end

return FieldEffectAssetCache
