-- Shared source-model compiler behind the Bell Tower and Whirl Islands
-- legend appearance assets. Both cutscenes compile Nitro models and clips
-- out of the demo/legend archive plus one LZ11-compressed cinematic archive;
-- only the member tables, the descriptor key prefix, and the error label
-- differ per legend.

local Errors = require("libs.errors.src.Errors")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local MapPropAnimCompiler = require("romdump.src.digest.model.MapPropAnimCompiler")
local Hashing = require("romdump.src.digest.Hashing")
local Lz11 = require("romdump.src.digest.Lz11")

local LegendAppearanceCompiler = {}

local function readMember(archive, memberId, archiveName, label)
  if memberId < 0 or memberId >= archive:memberCount() then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", label .. " legend model member is unavailable", {
      archive = archiveName,
      memberId = memberId,
      count = archive:memberCount(),
    })
  end
  local bytes, err = archive:readMember(memberId)
  if bytes == nil then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", label .. " legend model member could not be read", {
      archive = archiveName,
      memberId = memberId,
      error = tostring(err),
    })
  end
  return assert(bytes)
end

local function decodeSourceMember(bytes, compressed, archiveName, memberId, label)
  if not compressed then
    return bytes
  end
  local decoded, err = Lz11.decode(bytes)
  if decoded == nil then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", label .. " cinematic member could not be decompressed", {
      archive = archiveName,
      memberId = memberId,
      error = tostring(err),
    })
  end
  return assert(decoded)
end

local function compileAnimation(archive, source, hashes, archiveName, compressed, label)
  local sourceBytes = readMember(archive, source.memberId, archiveName, label)
  local bytes = decodeSourceMember(sourceBytes, compressed, archiveName, source.memberId, label)
  local decoded, err = NitroAnimation.decode(bytes, { alias = archiveName, memberId = source.memberId })
  if
    not decoded
    or decoded.format ~= source.format
    or type(decoded.animations) ~= "table"
    or #decoded.animations ~= 1
  then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", label .. " legend animation has an unexpected Nitro format", {
      archive = archiveName,
      memberId = source.memberId,
      expectedFormat = source.format,
      actualFormat = decoded and decoded.format or "unreadable",
      error = tostring(err),
    })
  end
  decoded = assert(decoded)
  local animation = assert(decoded.animations[1])
  local clip = MapPropAnimCompiler.compileDecoded(decoded, {
    name = animation.name,
    id = source.id,
    source = {
      type = "nitro",
      format = source.format,
      archive = archiveName,
      memberId = source.memberId,
      sha1 = Hashing.sha1hex(sourceBytes),
    },
  })
  clip.id = source.id
  clip.semanticNames = { source.id }
  clip.source = nil
  assert(clip.category == source.category and clip.kind == source.kind, label .. " animation kind changed")
  hashes[#hashes + 1] = {
    archive = archiveName,
    memberId = source.memberId,
    sha1 = Hashing.sha1hex(sourceBytes),
  }
  return clip
end

local function rewritePaths(descriptor, label)
  for _, batch in ipairs(descriptor.dynamic.batches) do
    local sha1 = assert(batch.geometry:match("/([^/]+)%.g4mesh$"), label .. " model geometry path is malformed")
    batch.geometry = FieldEffectAssetCache.geometryPath(sha1)
  end
  for _, material in ipairs(descriptor.materials) do
    if material.texture then
      local sha1 = assert(material.texture:match("/([^/]+)%.png$"), label .. " model texture path is malformed")
      material.texture = FieldEffectAssetCache.texturePath(sha1)
    end
    for _, variant in ipairs(material.variants or {}) do
      if variant.texture then
        local sha1 = assert(variant.texture:match("/([^/]+)%.png$"), label .. " variant texture path is malformed")
        variant.texture = FieldEffectAssetCache.texturePath(sha1)
      end
    end
  end
end

local function compileModel(archive, source, meshes, textures, hashes, archiveName, compressed, spec)
  local sourceBytes = readMember(archive, source.memberId, archiveName, spec.label)
  local modelBytes = decodeSourceMember(sourceBytes, compressed, archiveName, source.memberId, spec.label)
  local decoded, err = Nsbmd.decode(modelBytes, { alias = archiveName, memberId = source.memberId })
  if not decoded or not decoded.models[1] or not decoded.embeddedTextures then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", spec.label .. " legend model has no geometry or embedded textures", {
      archive = archiveName,
      memberId = source.memberId,
      error = tostring(err),
    })
  end
  decoded = assert(decoded)
  hashes[#hashes + 1] = { archive = archiveName, memberId = source.memberId, sha1 = Hashing.sha1hex(sourceBytes) }
  local clips = {}
  for _, animation in ipairs(source.animations) do
    clips[#clips + 1] = compileAnimation(archive, animation, hashes, archiveName, compressed, spec.label)
  end
  local model = assert(decoded.models[1])
  local descriptor, unresolved = DynamicModelCompiler.compile(
    model,
    decoded,
    decoded.embeddedTextures,
    { clips = clips },
    {
      role = spec.role,
      modelArchive = archiveName,
      modelMemberId = source.memberId,
      modelName = model.name,
      textureArchive = archiveName,
      textureMemberId = source.memberId,
    },
    source.memberId,
    textures,
    meshes
  )
  if #unresolved > 0 then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", spec.label .. " legend model has unresolved material resources", {
      archive = archiveName,
      memberId = source.memberId,
      unresolved = unresolved,
    })
  end
  descriptor.key = spec.keyPrefix .. source.id
  if source.noMaterialColors == true then
    -- Retail loads this model with its material-color registers disabled
    -- (NNSi_G3dModifyMatFlag FALSE for diffuse/ambient/specular/emission):
    -- the cinematic draws it unlit from its vertex colors and textures.
    -- Carry white registers so the evaluator reproduces that unlit look
    -- instead of the source gray.
    for _, material in ipairs(assert(descriptor.materials, spec.label .. " model has materials")) do
      material.baseColor = { r = 255, g = 255, b = 255, a = 255 }
      material.diffuse = { r = 255, g = 255, b = 255, a = 255 }
      material.colors = {
        diffuse = { r = 255, g = 255, b = 255 },
        ambient = { r = 255, g = 255, b = 255 },
        specular = { r = 255, g = 255, b = 255 },
        emission = { r = 255, g = 255, b = 255 },
      }
    end
  end
  rewritePaths(descriptor, spec.label)
  ModelAsset.validate(descriptor)
  return descriptor
end

-- Compiles every model in `spec.models` out of the legend archives.
-- Each model selects its archive with `cinematic = true` (the compressed
-- cinematic archive) or false (the plain legend archive).
---@param romFs RomFs
---@param spec { archive: string, cinematicArchive: string, label: string, role: string, keyPrefix: string, models: table[] }
---@return table<string, unknown>[] models, table<string, table<string, unknown>> meshes, table<string, table<string, unknown>> textures, { archive: string, memberId: integer, sha1: string }[] hashes
function LegendAppearanceCompiler.compileModels(romFs, spec)
  assert(type(spec) == "table", "legend appearance compiler spec is required")
  assert(type(spec.archive) == "string", "legend appearance spec requires its legend archive")
  assert(type(spec.cinematicArchive) == "string", "legend appearance spec requires its cinematic archive")
  assert(type(spec.models) == "table", "legend appearance spec requires its model list")
  local archives = {}
  for _, archiveName in ipairs({ spec.archive, spec.cinematicArchive }) do
    if archives[archiveName] == nil then
      local archive, err = romFs:openNarc(archiveName)
      if archive == nil then
        Errors.raise("FIELD_EFFECT_SOURCE_MISSING", spec.label .. " legend source archive is unavailable", {
          archive = archiveName,
          error = tostring(err),
        })
      end
      archives[archiveName] = assert(archive)
    end
  end
  local models, meshes, textures, hashes = {}, {}, {}, {}
  for _, source in ipairs(spec.models) do
    local archiveName = source.cinematic and spec.cinematicArchive or spec.archive
    models[#models + 1] = compileModel(
      assert(archives[archiveName]),
      source,
      meshes,
      textures,
      hashes,
      archiveName,
      source.cinematic == true,
      spec
    )
  end
  return models, meshes, textures, hashes
end

return LegendAppearanceCompiler
