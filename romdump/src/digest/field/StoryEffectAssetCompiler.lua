-- Compiles the field models a gym mechanism loads at runtime instead of the
-- map scene placing them: the Violet Gym elevator car (build model 111), the
-- Azalea Gym Spinarak (build model 118), the Ecruteak Gym candle (build model
-- 128) and the Blackthorn Gym platforms (build models 120 and 121). All of them
-- are ordinary interior build models of their own map (src/field/gymmick/
-- violet.c, azalea.c, ecruteak.c and blackthorn.c call MapPropManager_LoadOne
-- with the model id, the source transform and a null rotation override), and all
-- of them are listed by their area's build config, which is also how the source
-- area loader registers their animations.
--
-- The Cianwood Gym winch's own animated props are the map scene's placements,
-- so only their records matter here and they already travel with the map.
--
-- The generated bundle therefore carries their normalized model definitions
-- and clips; the runtime mechanism owns nothing but the transform and the clip
-- playback it applies to them. Each model keeps exactly the one clip its source
-- anim-list record declares, and none at all when its area registers no record
-- for it: the Blackthorn platforms are plain static build models the mechanism
-- only ever translates and rotates.

local AreaData = require("romdump.src.digest.map.AreaData")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local Hashing = require("romdump.src.digest.Hashing")
local LegendAppearanceCompiler = require("romdump.src.digest.field.LegendAppearanceCompiler")
local PngWriter = require("romdump.src.digest.PngEncoder")
local BuildingModelCompiler = require("romdump.src.digest.map.BuildingModelCompiler")
local Errors = require("libs.errors.src.Errors")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldEffects = require("romdump.src.config.FieldEffects")
local LandData = require("romdump.src.digest.map.LandData")
local Lz11 = require("romdump.src.digest.Lz11")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local Compiler = {}

local function member(romFs, alias, memberId)
  local narc = assert(romFs:openNarc(alias))
  if memberId < 0 or memberId >= narc:memberCount() then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "mechanism prop source member is unavailable", {
      archive = alias,
      memberId = memberId,
      count = narc:memberCount(),
    })
  end
  return assert(narc:readMember(memberId))
end

-- One source prop: resolve its map, then compile the single build model the
-- mechanism loads from that map's own archives.
local function compileProp(romFs, source, meshes, textures)
  local resolved, resolveErr = MapResolver.resolve(romFs, source.mapSymbol)
  if not resolved then
    error(resolveErr, 0)
  end
  local area = assert(AreaData.decode(member(romFs, "area_data", resolved.areaDataMemberId), {
    alias = "area_data",
    memberId = resolved.areaDataMemberId,
  }))
  local land = assert(LandData.decode(member(romFs, "land_data", resolved.landDataMemberId), {
    mapId = resolved.map.id,
    alias = "land_data",
    memberId = resolved.landDataMemberId,
  }))
  -- The prop has no generated placement: only the selected model is compiled,
  -- exactly like the source loading it by build model over its own transform.
  local selectedLand = {}
  for key, value in pairs(land) do
    selectedLand[key] = value
  end
  selectedLand.buildings = {}
  local compiled = BuildingModelCompiler.compile(romFs, area, selectedLand, {
    mapId = resolved.map.id,
    mapSymbol = resolved.map.symbol,
    areaDataMemberId = resolved.areaDataMemberId,
    landDataMemberId = resolved.landDataMemberId,
    meshes = meshes,
    textures = textures,
    finalizeMeshes = true,
    requiredModelMembers = { source.modelMemberId },
  })
  local modelKey =
    assert(compiled.modelKeyOf[source.modelMemberId], "mechanism prop model did not compile: " .. source.key)
  local descriptor = assert(compiled.models[modelKey], "mechanism prop descriptor is missing: " .. source.key)
  local animations = descriptor.animations
  if descriptor.kind == "nitro-dynamic" then
    if type(animations) ~= "table" or #animations ~= 1 then
      Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "mechanism prop model must carry its one source clip", {
        key = source.key,
        mapSymbol = source.mapSymbol,
        modelMemberId = source.modelMemberId,
        kind = descriptor.kind,
        animationCount = type(animations) == "table" and #animations or 0,
      })
    end
  elseif descriptor.kind ~= "static" then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "mechanism prop model must be a normalized model", {
      key = source.key,
      mapSymbol = source.mapSymbol,
      modelMemberId = source.modelMemberId,
      kind = descriptor.kind,
    })
  end
  -- The generated definition travels with the field-effect family, so its
  -- key is the semantic effect kind and never the map placement identity.
  descriptor.key = "field-effect:" .. source.key
  FieldEffectAssetCache.rewriteModelPaths(descriptor)
  ModelAsset.validate(descriptor)
  return {
    definition = { model = descriptor },
    hashes = {
      models = compiled.buildingModelShas,
      animations = compiled.animationListMemberSha1s,
      textures = {
        {
          memberId = area.buildingTexturePackId,
          sha1 = assert(compiled.buildingTextureMemberSha1, "mechanism prop texture pack has no source digest"),
        },
      },
    },
  }
end

-- One compiled mechanism prop: the generated effect definition the family
-- publishes for it, keyed by its semantic effect kind.
---@class MechanismPropDefinition
---@field model table<string, unknown> the normalized nitro-dynamic model descriptor

-- The Rocket hideout's own script-driven effects: the three trap models with
-- their source clips out of the demo/legend archive
-- (src/field/script_field_effects.c sTrapEffects) and the alarm's red overlay,
-- whose palette, character data and tilemap the source loads into the main BG1
-- (Task_ShowHideoutAlarm). The overlay is rasterized once here so the runtime
-- only ever draws a prepared image.
---@param romFs table<string, unknown>
---@param meshes table<string, unknown>
---@param textures table<string, unknown>
---@param memberHashes table[]
---@return table<string, table<string, unknown>> definitions by semantic kind
local function compileHideoutEffects(romFs, meshes, textures, memberHashes)
  local archiveName = FieldEffects.hideoutEffectArchive
  local models, modelMeshes, modelTextures, modelHashes = LegendAppearanceCompiler.compileModels(romFs, {
    archive = archiveName,
    cinematicArchive = archiveName,
    label = "Rocket hideout",
    role = "field-effect-rocket-hideout",
    keyPrefix = "field-effect:rocket-hideout:",
    models = FieldEffects.hideoutTrapModels,
  })
  -- The legend compiler owns its own accumulators; the effect bundle publishes
  -- one shared set, so both the bytes and the provenance join it here.
  for sha1, mesh in pairs(modelMeshes) do
    meshes[sha1] = mesh
  end
  for sha1, texture in pairs(modelTextures) do
    textures[sha1] = texture
  end
  for _, entry in ipairs(modelHashes) do
    memberHashes[#memberHashes + 1] = entry
  end
  local definitions = {}
  for index, source in ipairs(FieldEffects.hideoutTrapModels) do
    local descriptor = assert(models[index], "hideout trap model did not compile: " .. source.key)
    descriptor.key = "field-effect:" .. source.key
    -- One source anim-list record names one animation for every channel kind it
    -- carries, so a poison trap's joint and colour clips share their source
    -- name. A runtime model keeps unique clip names, so the channel kind
    -- qualifies a shared name; each clip keeps its own semantic identity.
    local seen = {}
    for _, clip in ipairs(descriptor.animations or {}) do
      if seen[clip.name] ~= nil then
        clip.name = clip.name .. "." .. clip.kind
      end
      seen[clip.name] = true
    end
    definitions[source.key] = { model = descriptor }
  end
  local overlay = FieldEffects.hideoutAlarmOverlay
  local archive = assert(romFs:openNarc(archiveName), "the hideout effect archive is unavailable")
  local function read(memberId, decode, label)
    if memberId < 0 or memberId >= archive:memberCount() then
      Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "hideout effect source member is unavailable", {
        archive = archiveName,
        memberId = memberId,
        count = archive:memberCount(),
        role = label,
      })
    end
    local bytes = assert(archive:readMember(memberId), "hideout effect source member is unreadable")
    memberHashes[#memberHashes + 1] = { archive = archiveName, memberId = memberId, sha1 = Hashing.sha1hex(bytes) }
    local decoded, err = decode(bytes, { asset = archiveName, member = memberId, role = label })
    if decoded == nil then
      Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "hideout effect source member could not be decoded", {
        archive = archiveName,
        memberId = memberId,
        role = label,
        error = tostring(err),
      })
    end
    return decoded
  end
  -- The reader raises on a member it could not decode, so every record below
  -- is present; the asserts state that contract at the point it is consumed.
  local charData = assert(read(overlay.charMemberId, G2dDecoder.decodeChar, "alarm character data"))
  local palette = assert(read(overlay.paletteMemberId, G2dDecoder.decodePalette, "alarm palette"))
  local screen = assert(read(overlay.screenMemberId, G2dDecoder.decodeScreen, "alarm tilemap"))
  local image = G2dRasterizer.renderScreen(charData, palette, screen, {
    asset = archiveName,
    member = overlay.screenMemberId,
    role = "alarm overlay",
  }, { backdrop = true })
  local png = PngWriter.encode(image.width, image.height, image.pixels)
  local sha1 = Hashing.sha1hex(png)
  textures[sha1] = { data = png, width = image.width, height = image.height }
  definitions[overlay.key] = {
    overlay = {
      texture = FieldEffectAssetCache.texturePath(sha1),
      width = image.width,
      height = image.height,
    },
  }
  return definitions
end

-- The legendary-story scenes this field drives: the Kimono Girls' wing effect
-- (src/field/script_field_effects.c sLegendaryWingModels and their intro, loop
-- and end animation lists), the Sinjoh Mystri Stage models
-- (src/field/gymmick/sinjoh.c), the Sinjoh Unown circle and egg cutscenes
-- (src/field/event_cutscene_sinjoh.c) and the Arceus montage application
-- (src/application/arceus_cinematic.c). Every model and clip comes out of the
-- plain demo/legend archive; the montage layers and the sprite come out of the
-- cinematic application archive NARC_a_2_4_5.
local LEGEND_ARCHIVE = "NARC_demo_legend"
local MONTAGE_ARCHIVE = "NARC_a_2_4_5"
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")

local LegendEffects = {}

---@param format string
---@return string category
---@return string kind
local function animationKind(format)
  if format == "NSBCA" then
    return "joint", "trs"
  elseif format == "NSBMA" then
    return "material", "color"
  elseif format == "NSBTP" then
    return "material", "pattern"
  end
  assert(format == "NSBTA", "unknown legend animation format " .. tostring(format))
  return "material", "texsrt"
end

---@param phases table[]
---@param key string
---@return table[]
local function modelAnimations(phases, key)
  local animations = {}
  for _, phase in ipairs(phases) do
    for _, anim in ipairs(phase.anims) do
      local category, kind = animationKind(anim.format)
      animations[#animations + 1] = {
        memberId = anim.memberId,
        format = anim.format,
        id = phase.role .. "." .. kind,
        category = category,
        kind = kind,
      }
    end
  end
  assert(#animations > 0, "legend scene model has no clips: " .. key)
  return animations
end

-- The wing effect's two source models: each version's own wing with its intro,
-- loop and end animation lists (sLegendaryWingModels and the three lists).
LegendEffects.wingParts = {
  {
    key = "legend_wing_0",
    modelMemberId = 55,
    phases = {
      {
        role = "intro",
        anims = {
          { memberId = 57, format = "NSBCA" },
          { memberId = 56, format = "NSBMA" },
          { memberId = 58, format = "NSBTP" },
        },
      },
      {
        role = "loop",
        anims = {
          { memberId = 59, format = "NSBCA" },
          { memberId = 60, format = "NSBMA" },
          { memberId = 61, format = "NSBTP" },
        },
      },
      {
        role = "end",
        anims = {
          { memberId = 62, format = "NSBCA" },
          { memberId = 63, format = "NSBMA" },
          { memberId = 64, format = "NSBTP" },
        },
      },
    },
  },
  {
    key = "legend_wing_1",
    modelMemberId = 65,
    phases = {
      {
        role = "intro",
        anims = {
          { memberId = 67, format = "NSBCA" },
          { memberId = 66, format = "NSBMA" },
          { memberId = 68, format = "NSBTP" },
        },
      },
      {
        role = "loop",
        anims = {
          { memberId = 69, format = "NSBCA" },
          { memberId = 70, format = "NSBMA" },
          { memberId = 71, format = "NSBTP" },
        },
      },
      {
        role = "end",
        anims = {
          { memberId = 72, format = "NSBCA" },
          { memberId = 73, format = "NSBMA" },
          { memberId = 74, format = "NSBTP" },
        },
      },
    },
  },
}

-- The Mystri Stage's three models with the two records each
-- (SinjohGymmick_Load3dGraphics).
LegendEffects.stageParts = {
  {
    key = "sinjoh_stage_0",
    modelMemberId = 101,
    phases = {
      { role = "joint", anims = { { memberId = 102, format = "NSBCA" } } },
      { role = "material", anims = { { memberId = 103, format = "NSBTA" } } },
    },
  },
  {
    key = "sinjoh_stage_1",
    modelMemberId = 104,
    phases = {
      { role = "joint", anims = { { memberId = 105, format = "NSBCA" } } },
      { role = "material", anims = { { memberId = 106, format = "NSBTA" } } },
    },
  },
  {
    key = "sinjoh_stage_2",
    modelMemberId = 107,
    phases = {
      { role = "joint", anims = { { memberId = 108, format = "NSBCA" } } },
      { role = "material", anims = { { memberId = 109, format = "NSBTA" } } },
    },
  },
}

-- The Unown circle's two Unown models and the Arceus object over the field's
-- own follower (SinjohCutscene_LoadResources).
LegendEffects.unownParts = {
  {
    key = "sinjoh_unown_0",
    modelMemberId = 79,
    phases = {
      { role = "joint", anims = { { memberId = 80, format = "NSBCA" } } },
      { role = "material", anims = { { memberId = 81, format = "NSBTA" } } },
    },
  },
  {
    key = "sinjoh_unown_1",
    modelMemberId = 82,
    phases = {
      { role = "joint", anims = { { memberId = 83, format = "NSBCA" } } },
      { role = "material", anims = { { memberId = 84, format = "NSBTA" } } },
    },
  },
  {
    key = "sinjoh_unown_2",
    modelMemberId = 85,
    phases = {
      { role = "joint", anims = { { memberId = 86, format = "NSBCA" } } },
      { role = "material", anims = { { memberId = 87, format = "NSBMA" } } },
    },
  },
}

-- The three egg models with their four records each (sSinjohEggAnimationFiles:
-- one shared joint record and three material ones per source variant).
LegendEffects.eggParts = {
  {
    key = "sinjoh_egg_0",
    modelMemberId = 88,
    phases = {
      {
        role = "all",
        anims = {
          { memberId = 100, format = "NSBCA" },
          { memberId = 90, format = "NSBTA" },
          { memberId = 91, format = "NSBMA" },
          { memberId = 89, format = "NSBTP" },
        },
      },
    },
  },
  {
    key = "sinjoh_egg_1",
    modelMemberId = 92,
    phases = {
      {
        role = "all",
        anims = {
          { memberId = 100, format = "NSBCA" },
          { memberId = 94, format = "NSBTA" },
          { memberId = 95, format = "NSBMA" },
          { memberId = 93, format = "NSBTP" },
        },
      },
    },
  },
  {
    key = "sinjoh_egg_2",
    modelMemberId = 96,
    phases = {
      {
        role = "all",
        anims = {
          { memberId = 100, format = "NSBCA" },
          { memberId = 98, format = "NSBTA" },
          { memberId = 99, format = "NSBMA" },
          { memberId = 97, format = "NSBTP" },
        },
      },
    },
  },
}

-- The Arceus montage timeline exactly as src/application/arceus_cinematic.c
-- declares it: an opcode followed by its own arguments, in source order.
LegendEffects.arceusTimeline = {
  { 12 },
  { 6, 0, 58 },
  { 0, 60 },
  { 1, 1, 1 },
  { 5 },
  { 0, 90 },
  { 2, 15, 2 },
  { 5 },
  { 15, 0 },
  { 13 },
  { 14, "SEQ_GS_E_ARCEUS" },
  { 0, 15 },
  { 6, 0, 1 },
  { 18, 0 },
  { 1, 1, 1 },
  { 5 },
  { 0, 15 },
  { 2, 15, 2 },
  { 5 },
  { 6, 0, 2 },
  { 0, 40 },
  { 18, 1 },
  { 1, 1, 1 },
  { 5 },
  { 0, 15 },
  { 2, 15, 2 },
  { 5 },
  { 6, 0, 3 },
  { 0, 35 },
  { 18, 2 },
  { 1, 1, 1 },
  { 5 },
  { 0, 15 },
  { 2, 15, 2 },
  { 5 },
  { 6, 0, 6 },
  { 6, 1, 4 },
  { 8, 0, 0 },
  { 8, 1, 1 },
  { 0, 37 },
  { 18, 10 },
  { 1, 1, 1 },
  { 5 },
  { 0, 5 },
  { 9, 0, 1, 15 },
  { 9, 1, 2, 0 },
  { 10, 0, 20 },
  { 2, 15, 2 },
  { 5 },
  { 11 },
  { 6, 0, 4 },
  { 6, 1, 7 },
  { 9, 0, 1, 15 },
  { 9, 1, 2, 0 },
  { 0, 35 },
  { 18, 11 },
  { 1, 1, 1 },
  { 5 },
  { 0, 5 },
  { 9, 0, 1, 15 },
  { 9, 1, 2, 0 },
  { 10, 0, 20 },
  { 2, 20, 2 },
  { 5 },
  { 11 },
  { 0, 17 },
  { 6, 0, 52 },
  { 6, 1, 53 },
  { 8, 0, 0 },
  { 8, 1, 1 },
  { 9, 0, 1, 15 },
  { 9, 1, 2, 0 },
  { 18, 20 },
  { 1, 10, 1 },
  { 5 },
  { 0, 20 },
  { 10, 0, 30 },
  { 8, 1, 0 },
  { 8, 0, 1 },
  { 11 },
  { 6, 0, 54 },
  { 9, 0, 2, 15 },
  { 9, 1, 1, 0 },
  { 0, 20 },
  { 18, 21 },
  { 10, 0, 30 },
  { 8, 0, 0 },
  { 8, 1, 1 },
  { 11 },
  { 6, 1, 55 },
  { 9, 0, 1, 15 },
  { 9, 1, 2, 0 },
  { 0, 20 },
  { 18, 22 },
  { 10, 0, 30 },
  { 0, 17 },
  { 2, 1, 1 },
  { 5 },
  { 11 },
  { 6, 0, 11 },
  { 6, 1, 12 },
  { 8, 0, 0 },
  { 8, 1, 1 },
  { 18, 30 },
  { 1, 10, 1 },
  { 0, 22 },
  { 8, 0, 1 },
  { 8, 1, 0 },
  { 18, 31 },
  { 6, 0, 13 },
  { 0, 22 },
  { 8, 0, 0 },
  { 8, 1, 1 },
  { 18, 32 },
  { 6, 1, 14 },
  { 0, 22 },
  { 8, 0, 1 },
  { 8, 1, 0 },
  { 18, 33 },
  { 6, 0, 15 },
  { 0, 22 },
  { 8, 0, 0 },
  { 8, 1, 1 },
  { 18, 34 },
  { 6, 1, 16 },
  { 0, 22 },
  { 8, 0, 1 },
  { 8, 1, 0 },
  { 18, 35 },
  { 6, 0, 17 },
  { 0, 22 },
  { 8, 0, 0 },
  { 8, 1, 1 },
  { 18, 36 },
  { 6, 1, 19 },
  { 0, 22 },
  { 8, 0, 1 },
  { 8, 1, 0 },
  { 18, 37 },
  { 0, 22 },
  { 4, 1, 1 },
  { 5 },
  { 6, 0, 36 },
  { 6, 1, 37 },
  { 6, 2, 38 },
  { 8, 0, 0 },
  { 8, 1, 1 },
  { 8, 2, 2 },
  { 9, 0, 2, 15 },
  { 9, 1, 4, 0 },
  { 15, 1 },
  { 16, 128, 80 },
  { 17, 0 },
  { 18, 40 },
  { 3, 10, 1 },
  { 5 },
  { 0, 20 },
  { 10, 0, 30 },
  { 8, 2, 0 },
  { 8, 1, 1 },
  { 11 },
  { 6, 1, 39 },
  { 9, 0, 4, 15 },
  { 9, 1, 2, 0 },
  { 0, 20 },
  { 18, 41 },
  { 10, 0, 30 },
  { 8, 1, 0 },
  { 8, 2, 1 },
  { 11 },
  { 6, 2, 40 },
  { 9, 0, 2, 15 },
  { 9, 1, 4, 0 },
  { 0, 20 },
  { 18, 42 },
  { 10, 0, 30 },
  { 0, 17 },
  { 4, 1, 1 },
  { 5 },
  { 11 },
  { 6, 1, 66 },
  { 6, 2, 58 },
  { 8, 0, 0 },
  { 8, 1, 1 },
  { 8, 2, 2 },
  { 9, 0, 2, 15 },
  { 9, 1, 4, 0 },
  { 18, 50 },
  { 3, 1, 1 },
  { 5 },
  { 0, 10 },
  { 10, 0, 3 },
  { 8, 2, 0 },
  { 8, 1, 1 },
  { 11 },
  { 6, 1, 23 },
  { 9, 1, 4, 15 },
  { 9, 0, 2, 0 },
  { 18, 51 },
  { 10, 0, 2 },
  { 8, 1, 0 },
  { 8, 2, 1 },
  { 11 },
  { 0, 10 },
  { 10, 0, 5 },
  { 8, 2, 0 },
  { 8, 1, 1 },
  { 11 },
  { 6, 1, 22 },
  { 9, 1, 4, 15 },
  { 9, 0, 2, 0 },
  { 18, 52 },
  { 10, 0, 2 },
  { 8, 1, 0 },
  { 8, 2, 1 },
  { 11 },
  { 0, 10 },
  { 10, 0, 5 },
  { 8, 2, 0 },
  { 8, 1, 1 },
  { 11 },
  { 6, 1, 25 },
  { 9, 1, 4, 15 },
  { 9, 0, 2, 0 },
  { 18, 53 },
  { 10, 0, 2 },
  { 8, 1, 0 },
  { 8, 2, 1 },
  { 11 },
  { 0, 10 },
  { 10, 0, 5 },
  { 8, 2, 0 },
  { 8, 1, 1 },
  { 11 },
  { 6, 1, 24 },
  { 9, 1, 4, 15 },
  { 9, 0, 2, 0 },
  { 18, 54 },
  { 10, 0, 2 },
  { 8, 1, 0 },
  { 8, 2, 1 },
  { 11 },
  { 0, 10 },
  { 10, 0, 5 },
  { 8, 2, 0 },
  { 8, 1, 1 },
  { 11 },
  { 6, 1, 21 },
  { 9, 1, 4, 15 },
  { 9, 0, 2, 0 },
  { 18, 55 },
  { 10, 0, 2 },
  { 8, 1, 0 },
  { 8, 2, 1 },
  { 11 },
  { 0, 10 },
  { 10, 0, 5 },
  { 8, 2, 0 },
  { 8, 1, 1 },
  { 11 },
  { 6, 1, 27 },
  { 9, 1, 4, 15 },
  { 9, 0, 2, 0 },
  { 18, 56 },
  { 10, 0, 2 },
  { 8, 1, 0 },
  { 8, 2, 1 },
  { 11 },
  { 0, 10 },
  { 10, 0, 5 },
  { 8, 2, 0 },
  { 8, 1, 1 },
  { 11 },
  { 6, 1, 26 },
  { 9, 1, 4, 15 },
  { 9, 0, 2, 0 },
  { 18, 57 },
  { 10, 0, 2 },
  { 8, 1, 0 },
  { 8, 2, 1 },
  { 11 },
  { 0, 10 },
  { 10, 0, 5 },
  { 8, 2, 0 },
  { 8, 1, 1 },
  { 11 },
  { 6, 1, 41 },
  { 8, 0, 0 },
  { 8, 2, 1 },
  { 8, 1, 2 },
  { 9, 1, 4, 15 },
  { 9, 0, 2, 0 },
  { 18, 60 },
  { 10, 0, 2 },
  { 8, 1, 1 },
  { 8, 2, 2 },
  { 11 },
  { 6, 2, 42 },
  { 9, 0, 2, 15 },
  { 9, 1, 4, 0 },
  { 0, 20 },
  { 18, 61 },
  { 10, 0, 30 },
  { 8, 2, 1 },
  { 8, 1, 2 },
  { 11 },
  { 6, 1, 43 },
  { 9, 0, 4, 15 },
  { 9, 1, 2, 0 },
  { 0, 20 },
  { 18, 62 },
  { 10, 0, 30 },
  { 8, 1, 1 },
  { 8, 2, 2 },
  { 11 },
  { 6, 2, 44 },
  { 9, 0, 2, 15 },
  { 9, 1, 4, 0 },
  { 0, 20 },
  { 18, 63 },
  { 10, 0, 30 },
  { 11 },
  { 8, 2, 1 },
  { 8, 1, 2 },
  { 6, 1, 59 },
  { 0, 20 },
  { 10, 0, 2 },
  { 8, 1, 1 },
  { 8, 2, 2 },
  { 6, 2, 45 },
  { 9, 0, 2, 15 },
  { 9, 1, 4, 0 },
  { 18, 70 },
  { 10, 0, 22 },
  { 8, 2, 1 },
  { 8, 1, 2 },
  { 11 },
  { 6, 1, 48 },
  { 9, 0, 4, 15 },
  { 9, 1, 2, 0 },
  { 18, 71 },
  { 10, 0, 22 },
  { 8, 1, 1 },
  { 8, 2, 2 },
  { 11 },
  { 6, 2, 65 },
  { 9, 0, 2, 15 },
  { 9, 1, 4, 0 },
  { 18, 72 },
  { 10, 0, 22 },
  { 8, 2, 1 },
  { 8, 1, 2 },
  { 11 },
  { 6, 1, 46 },
  { 9, 0, 4, 15 },
  { 9, 1, 2, 0 },
  { 18, 73 },
  { 10, 0, 22 },
  { 8, 1, 1 },
  { 8, 2, 2 },
  { 11 },
  { 6, 2, 64 },
  { 9, 0, 2, 15 },
  { 9, 1, 4, 0 },
  { 18, 74 },
  { 10, 0, 22 },
  { 8, 2, 1 },
  { 8, 1, 2 },
  { 11 },
  { 6, 1, 63 },
  { 9, 0, 4, 15 },
  { 9, 1, 2, 0 },
  { 18, 75 },
  { 10, 0, 22 },
  { 8, 1, 1 },
  { 8, 2, 2 },
  { 11 },
  { 6, 2, 49 },
  { 9, 0, 2, 15 },
  { 9, 1, 4, 0 },
  { 18, 76 },
  { 10, 0, 21 },
  { 8, 2, 1 },
  { 8, 1, 2 },
  { 11 },
  { 6, 1, 59 },
  { 9, 1, 4, 15 },
  { 9, 0, 2, 0 },
  { 0, 15 },
  { 10, 0, 2 },
  { 8, 1, 1 },
  { 8, 2, 2 },
  { 11 },
  { 6, 2, 28 },
  { 9, 0, 2, 15 },
  { 9, 1, 4, 0 },
  { 18, 80 },
  { 10, 0, 5 },
  { 8, 2, 1 },
  { 8, 1, 2 },
  { 11 },
  { 9, 1, 4, 15 },
  { 9, 0, 2, 0 },
  { 0, 10 },
  { 10, 0, 30 },
  { 8, 1, 1 },
  { 8, 2, 2 },
  { 6, 2, 50 },
  { 9, 0, 2, 15 },
  { 9, 1, 4, 0 },
  { 18, 81 },
  { 10, 0, 5 },
  { 8, 2, 1 },
  { 8, 1, 2 },
  { 11 },
  { 9, 1, 4, 15 },
  { 9, 0, 2, 0 },
  { 0, 9 },
  { 10, 0, 30 },
  { 8, 1, 1 },
  { 8, 2, 2 },
  { 6, 2, 57 },
  { 9, 0, 2, 15 },
  { 9, 1, 4, 0 },
  { 18, 82 },
  { 10, 0, 5 },
  { 8, 2, 1 },
  { 8, 1, 2 },
  { 11 },
  { 9, 1, 4, 15 },
  { 9, 0, 2, 0 },
  { 0, 9 },
  { 10, 0, 30 },
  { 8, 1, 1 },
  { 8, 2, 2 },
  { 6, 2, 51 },
  { 9, 0, 2, 15 },
  { 9, 1, 4, 0 },
  { 18, 83 },
  { 10, 0, 5 },
  { 8, 2, 1 },
  { 8, 1, 2 },
  { 11 },
  { 9, 1, 4, 15 },
  { 9, 0, 2, 0 },
  { 0, 9 },
  { 2, 30, 1 },
  { 5 },
  { 8, 1, 1 },
  { 8, 2, 2 },
  { 6, 0, 4 },
  { 15, 0 },
  { 18, 90 },
  { 1, 3, 1 },
  { 5 },
  { 0, 26 },
  { 2, 10, 1 },
  { 5 },
  { 6, 0, 67 },
  { 1, 3, 1 },
  { 5 },
  { 0, 26 },
  { 2, 10, 1 },
  { 5 },
  { 6, 0, 29 },
  { 1, 3, 1 },
  { 5 },
  { 0, 26 },
  { 2, 10, 1 },
  { 5 },
  { 6, 0, 36 },
  { 6, 1, 56 },
  { 6, 2, 58 },
  { 7, 0, 0 },
  { 18, 91 },
  { 1, 10, 1 },
  { 5 },
  { 0, 40 },
  { 18, 92 },
  { 7, 0, 1 },
  { 9, 0, 2, 15 },
  { 9, 1, 4, 0 },
  { 0, 10 },
  { 18, 93 },
  { 10, 0, 30 },
  { 8, 2, 1 },
  { 8, 1, 2 },
  { 11 },
  { 6, 1, 61 },
  { 0, 55 },
  { 18, 94 },
  { 8, 1, 0 },
  { 8, 0, 1 },
  { 8, 2, 2 },
  { 9, 0, 1, 15 },
  { 9, 1, 4, 0 },
  { 0, 90 },
  { 10, 0, 30 },
  { 8, 1, 0 },
  { 8, 2, 1 },
  { 8, 0, 2 },
  { 11 },
  { 6, 0, 62 },
  { 0, 60 },
  { 8, 0, 0 },
  { 8, 2, 1 },
  { 8, 1, 2 },
  { 18, 95 },
  { 2, 60, 1 },
  { 5 },
  { 13 },
  { 0, 1 },
  { 19 },
}

LegendEffects.arceusBgm = "SEQ_GS_E_ARCEUS"

-- The source montage's own layers: every LOAD_BG command names one source file
-- id whose character data, palette and tilemap members the application loads
-- (fileId + 68 for the characters, fileId + 136 for the palette, fileId for the
-- screen).
---@param archive table<string, unknown>
---@param fileIds integer[]
---@param textures table<string, unknown>
---@param memberHashes table[]
---@return table<integer, { path: string, width: integer, height: integer }>
local function compileMontageLayers(archive, fileIds, textures, memberHashes)
  local layers = {}
  for _, fileId in ipairs(fileIds) do
    local function read(memberId, role)
      if memberId < 0 or memberId >= archive:memberCount() then
        Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "Arceus montage source member is unavailable", {
          archive = MONTAGE_ARCHIVE,
          memberId = memberId,
          count = archive:memberCount(),
          role = role,
          fileId = fileId,
        })
      end
      local bytes = assert(archive:readMember(memberId), "Arceus montage source member is unreadable")
      memberHashes[#memberHashes + 1] =
        { archive = MONTAGE_ARCHIVE, memberId = memberId, sha1 = Hashing.sha1hex(bytes) }
      -- The application loader decompresses a member only when it carries an
      -- LZ11 stream; an already-flat NSCR/NCGR/NCLR member is used as it is.
      if bytes:sub(1, 1) ~= "\17" then
        return bytes
      end
      local decoded, err = Lz11.decode(bytes)
      if decoded == nil then
        Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "Arceus montage source member could not be decompressed", {
          archive = MONTAGE_ARCHIVE,
          memberId = memberId,
          error = tostring(err),
        })
      end
      return assert(decoded)
    end
    local screenBytes = read(fileId, "screen")
    local charBytes = read(fileId + 68, "tiles")
    local paletteBytes = read(fileId + 136, "palette")
    local charData, charErr = G2dDecoder.decodeChar(charBytes, { label = MONTAGE_ARCHIVE .. ":" .. (fileId + 68) })
    if charData == nil then
      Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "Arceus montage tiles could not be decoded", {
        archive = MONTAGE_ARCHIVE,
        fileId = fileId + 68,
        error = tostring(charErr),
      })
    end
    local paletteData, paletteErr =
      G2dDecoder.decodePalette(paletteBytes, { label = MONTAGE_ARCHIVE .. ":" .. (fileId + 136) })
    if paletteData == nil then
      Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "Arceus montage palette could not be decoded", {
        archive = MONTAGE_ARCHIVE,
        fileId = fileId + 136,
        error = tostring(paletteErr),
      })
    end
    local screenData, screenErr = G2dDecoder.decodeScreen(screenBytes, { label = MONTAGE_ARCHIVE .. ":" .. fileId })
    if screenData == nil then
      Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "Arceus montage screen could not be decoded", {
        archive = MONTAGE_ARCHIVE,
        fileId = fileId,
        error = tostring(screenErr),
      })
    end
    local image = G2dRasterizer.renderScreen(
      assert(charData),
      assert(paletteData),
      assert(screenData),
      { asset = MONTAGE_ARCHIVE, member = fileId, role = "arceus montage" }
    )
    local png = PngWriter.encode(image.width, image.height, image.pixels)
    local sha1 = Hashing.sha1hex(png)
    textures[sha1] = { data = png, width = image.width, height = image.height }
    layers[fileId] = { path = FieldEffectAssetCache.texturePath(sha1), width = image.width, height = image.height }
  end
  return layers
end

-- The montage's own Arceus screen sprite: the application loads one cell
-- animation, palette and character resource from its archive and draws it at
-- the timeline's own position.
---@param archive table<string, unknown>
---@param textures table<string, unknown>
---@param memberHashes table[]
---@return { path: string, width: integer, height: integer }
local function compileMontageSprite(archive, textures, memberHashes)
  local function read(memberId, role)
    if memberId < 0 or memberId >= archive:memberCount() then
      Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "Arceus sprite source member is unavailable", {
        archive = MONTAGE_ARCHIVE,
        memberId = memberId,
        count = archive:memberCount(),
        role = role,
      })
    end
    local bytes = assert(archive:readMember(memberId), "Arceus sprite source member is unreadable")
    memberHashes[#memberHashes + 1] = { archive = MONTAGE_ARCHIVE, memberId = memberId, sha1 = Hashing.sha1hex(bytes) }
    if bytes:sub(1, 1) ~= "\17" then
      return bytes
    end
    local decoded, err = Lz11.decode(bytes)
    if decoded == nil then
      Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "Arceus sprite source member could not be decompressed", {
        archive = MONTAGE_ARCHIVE,
        memberId = memberId,
        error = tostring(err),
      })
    end
    return assert(decoded)
  end
  local charData, charErr = G2dDecoder.decodeChar(read(204, "sprite tiles"), { label = MONTAGE_ARCHIVE .. ":204" })
  local paletteData, paletteErr =
    G2dDecoder.decodePalette(read(207, "sprite palette"), { label = MONTAGE_ARCHIVE .. ":207" })
  local cellData, cellErr = G2dDecoder.decodeCell(read(205, "sprite cells"), { label = MONTAGE_ARCHIVE .. ":205" })
  local animation, animationErr =
    G2dDecoder.decodeAnimation(read(206, "sprite animation"), { label = MONTAGE_ARCHIVE .. ":206" })
  if charData == nil or paletteData == nil or cellData == nil or animation == nil then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "Arceus sprite resources could not be decoded", {
      archive = MONTAGE_ARCHIVE,
      charError = tostring(charErr),
      paletteError = tostring(paletteErr),
      cellError = tostring(cellErr),
      animationError = tostring(animationErr),
    })
  end
  local sequence = assert(assert(animation).anims)[1]
  local image = G2dRasterizer.renderAnimationFrame(
    assert(charData),
    assert(paletteData),
    assert(cellData),
    assert(sequence),
    1,
    { asset = MONTAGE_ARCHIVE, member = 205, role = "arceus sprite" }
  )
  local png = PngWriter.encode(image.width, image.height, image.pixels)
  local sha1 = Hashing.sha1hex(png)
  textures[sha1] = { data = png, width = image.width, height = image.height }
  return { path = FieldEffectAssetCache.texturePath(sha1), width = image.width, height = image.height }
end

-- A source animation record that keys no target carries no visual state: the
-- egg cutscene's shared joint record comes with empty texture-SRT and pattern
-- records, which the source still loads (and finishes immediately). Such a
-- record contributes its phase timing but no compiled clip, because a model
-- clip with no keys is not a renderable record.
---@param archive table<string, unknown>
---@param anim { memberId: integer, format: string }
---@return boolean
local function hasVisualKeys(archive, anim)
  local bytes = archive:readMember(anim.memberId)
  if bytes == nil then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "legend scene animation member is unreadable", {
      archive = LEGEND_ARCHIVE,
      memberId = anim.memberId,
    })
  end
  local decoded, err = NitroAnimation.decode(assert(bytes), { alias = LEGEND_ARCHIVE, memberId = anim.memberId })
  if decoded == nil or decoded.format ~= anim.format then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "legend scene animation has an unexpected Nitro format", {
      archive = LEGEND_ARCHIVE,
      memberId = anim.memberId,
      expectedFormat = anim.format,
      actualFormat = decoded and decoded.format or "unreadable",
      error = tostring(err),
    })
  end
  ---@cast decoded -nil
  local resource = assert(assert(decoded.animations)[1], "legend animation record is missing").resource
  for _, key in ipairs({ "targets", "joints", "nodes", "materials" }) do
    local list = resource ~= nil and resource[key] or nil
    if type(list) == "table" then
      return #list > 0
    end
  end
  return true
end

-- Compile one legend scene's source parts into a scene definition: each part
-- keeps its normalized model and the clips of every source phase, with the
-- longest clip of a phase as that phase's own duration.
---@param romFs table<string, unknown>
---@param parts table[]
---@param role string family asset role for the legend models
---@param meshes table<string, unknown>
---@param textures table<string, unknown>
---@param memberHashes table[]
---@return table<string, unknown> definition
local function compileLegendParts(romFs, parts, role, meshes, textures, memberHashes)
  local legendArchive = assert(romFs:openNarc(LEGEND_ARCHIVE), "the legend scene archive is unavailable")
  local models, compiledPhases = {}, {}
  for index, source in ipairs(parts) do
    local phases = {}
    for _, phase in ipairs(source.phases) do
      local anims = {}
      for _, anim in ipairs(phase.anims) do
        if hasVisualKeys(assert(legendArchive), anim) then
          anims[#anims + 1] = anim
        end
      end
      phases[#phases + 1] = { role = phase.role, anims = anims }
    end
    compiledPhases[index] = phases
    models[index] = {
      id = source.key,
      memberId = source.modelMemberId,
      animations = modelAnimations(phases, source.key),
    }
  end
  local compiledModels, compiledMeshes, compiledTextures, hashes = LegendAppearanceCompiler.compileModels(romFs, {
    archive = LEGEND_ARCHIVE,
    cinematicArchive = LEGEND_ARCHIVE,
    label = "legend scene",
    role = role,
    keyPrefix = "field-effect:",
    models = models,
  })
  for sha1, mesh in pairs(compiledMeshes) do
    meshes[sha1] = mesh
  end
  for sha1, texture in pairs(compiledTextures) do
    textures[sha1] = texture
  end
  for _, entry in ipairs(hashes) do
    memberHashes[#memberHashes + 1] = entry
  end
  local definitionParts = {}
  for index, source in ipairs(parts) do
    local descriptor = assert(compiledModels[index], "legend scene model did not compile: " .. source.key)
    local clips = {}
    for _, phase in ipairs(compiledPhases[index]) do
      local ids, frames = {}, 0
      for _, anim in ipairs(phase.anims) do
        local _, kind = animationKind(anim.format)
        ids[#ids + 1] = phase.role .. "." .. kind
      end
      for _, clip in ipairs(descriptor.animations or {}) do
        for _, id in ipairs(ids) do
          if clip.id == id then
            frames = math.max(frames, clip.frameCount)
          end
        end
      end
      assert(frames > 0, "legend scene phase has no source clip: " .. source.key .. "/" .. phase.role)
      clips[phase.role] = { ids = ids, frames = frames }
    end
    definitionParts[index] = { model = descriptor, clips = clips }
  end
  return { parts = definitionParts }
end

---@param romFs table<string, unknown>
---@param meshes table<string, unknown> shared mesh accumulator
---@param textures table<string, unknown> shared texture accumulator
---@return { definitions: table<string, MechanismPropDefinition>, memberHashes: table[] }
function Compiler.compile(romFs, meshes, textures)
  assert(romFs and romFs.openNarc, "mechanism prop compiler requires RomFs")
  assert(
    type(meshes) == "table" and type(textures) == "table",
    "mechanism prop compilation requires the shared asset accumulators"
  )
  local definitions, memberHashes = {}, {}
  for _, source in ipairs(FieldEffects.mechanismPropModels) do
    local compiled = compileProp(romFs, source, meshes, textures)
    definitions[source.key] = compiled.definition
    for _, group in ipairs({ compiled.hashes.models, compiled.hashes.animations, compiled.hashes.textures }) do
      for _, entry in ipairs(group) do
        memberHashes[#memberHashes + 1] = entry
      end
    end
  end
  for kind, definition in pairs(compileHideoutEffects(romFs, meshes, textures, memberHashes)) do
    definitions[kind] = definition
  end
  local wing =
    compileLegendParts(romFs, LegendEffects.wingParts, "field-effect-legend-wing", meshes, textures, memberHashes)
  wing.sound = "SEQ_SE_GS_STOPPERKAIJO"
  definitions.legend_wing = wing
  definitions.sinjoh_stage =
    compileLegendParts(romFs, LegendEffects.stageParts, "field-effect-sinjoh-stage", meshes, textures, memberHashes)
  definitions.sinjoh_unown =
    compileLegendParts(romFs, LegendEffects.unownParts, "field-effect-sinjoh-unown", meshes, textures, memberHashes)
  definitions.sinjoh_egg =
    compileLegendParts(romFs, LegendEffects.eggParts, "field-effect-sinjoh-egg", meshes, textures, memberHashes)
  local montageArchive, montageErr = romFs:openNarc(MONTAGE_ARCHIVE)
  if montageArchive == nil then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "the Arceus montage archive is unavailable", {
      archive = MONTAGE_ARCHIVE,
      error = tostring(montageErr),
    })
  end
  local fileIds, seenFileId = {}, {}
  for _, command in ipairs(LegendEffects.arceusTimeline) do
    if command[1] == 6 and not seenFileId[command[3]] then
      seenFileId[command[3]] = true
      fileIds[#fileIds + 1] = command[3]
    end
  end
  table.sort(fileIds)
  definitions.arceus_cinematic = {
    timeline = LegendEffects.arceusTimeline,
    bgm = LegendEffects.arceusBgm,
    layers = compileMontageLayers(assert(montageArchive), fileIds, textures, memberHashes),
    sprite = compileMontageSprite(assert(montageArchive), textures, memberHashes),
  }
  return { definitions = definitions, memberHashes = memberHashes }
end

return Compiler
