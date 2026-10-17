-- Compiles the original HGSS Celebi model and animations selected by
-- event_cutscene_celebi.c in ctrl-cheeb-del/pokeheartgold@27da732f.

local Errors = require("libs.errors.src.Errors")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local MapPropAnimCompiler = require("romdump.src.digest.model.MapPropAnimCompiler")
local Hashing = require("romdump.src.digest.Hashing")

local Compiler = {}

local ARCHIVE = "NARC_demo_legend"
local MODEL_MEMBER = 75
local ANIMATIONS = {
  { memberId = 76, format = "NSBCA", id = "celebi.joint", category = "joint", kind = "trs" },
  { memberId = 78, format = "NSBTP", id = "celebi.pattern", category = "material", kind = "pattern" },
  { memberId = 77, format = "NSBTA", id = "celebi.srt", category = "material", kind = "texsrt" },
}

local function readRequiredMember(archive, memberId)
  if memberId < 0 or memberId >= archive:memberCount() then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "Celebi legend source member is unavailable", {
      archive = ARCHIVE,
      memberId = memberId,
      count = archive:memberCount(),
    })
  end
  local bytes, err = archive:readMember(memberId)
  if not bytes then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "Celebi legend source member could not be read", {
      archive = ARCHIVE,
      memberId = memberId,
      error = tostring(err),
    })
  end
  return bytes
end

local function decodeModel(bytes)
  local decoded, err = Nsbmd.decode(bytes, { alias = ARCHIVE, memberId = MODEL_MEMBER })
  if
    not decoded
    or type(decoded.models) ~= "table"
    or not decoded.models[1]
    or type(decoded.embeddedTextures) ~= "table"
  then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "Celebi legend model is missing geometry or embedded textures", {
      archive = ARCHIVE,
      memberId = MODEL_MEMBER,
      expectedFormat = "NSBMD",
      error = tostring(err),
    })
  end
  return assert(decoded)
end

local function decodeClip(archive, source)
  local bytes = readRequiredMember(archive, source.memberId)
  local decoded, err = NitroAnimation.decode(bytes, { alias = ARCHIVE, memberId = source.memberId })
  if
    not decoded
    or decoded.format ~= source.format
    or type(decoded.animations) ~= "table"
    or #decoded.animations ~= 1
  then
    Errors.raise(
      "FIELD_EFFECT_SOURCE_INVALID",
      "Celebi legend animation has an unexpected Nitro format or entry count",
      {
        archive = ARCHIVE,
        memberId = source.memberId,
        expectedFormat = source.format,
        actualFormat = decoded and decoded.format or "unreadable",
        animationCount = decoded and type(decoded.animations) == "table" and #decoded.animations or 0,
        error = tostring(err),
      }
    )
  end
  decoded = assert(decoded)
  local animation = assert(decoded.animations[1])
  local clip = MapPropAnimCompiler.compileDecoded(decoded, {
    name = animation.name,
    id = source.id,
    source = {
      type = "nitro",
      format = source.format,
      archive = ARCHIVE,
      memberId = source.memberId,
      sha1 = Hashing.sha1hex(bytes),
    },
  })
  clip.id = source.id
  clip.semanticNames = { source.id }
  clip.source = nil
  if clip.category ~= source.category or clip.kind ~= source.kind then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "Celebi legend animation compiled with an unexpected clip kind", {
      archive = ARCHIVE,
      memberId = source.memberId,
      expectedFormat = source.format,
      category = clip.category,
      kind = clip.kind,
    })
  end
  return clip, { memberId = source.memberId, sha1 = Hashing.sha1hex(bytes) }
end

local function rewritePaths(descriptor)
  for _, batch in ipairs(descriptor.dynamic.batches) do
    local sha1 = assert(batch.geometry:match("/([^/]+)%.g4mesh$"), "compiled field-effect geometry path is malformed")
    batch.geometry = FieldEffectAssetCache.geometryPath(sha1)
  end
  for _, material in ipairs(descriptor.materials) do
    if material.texture then
      local sha1 = assert(material.texture:match("/([^/]+)%.png$"), "compiled field-effect texture path is malformed")
      material.texture = FieldEffectAssetCache.texturePath(sha1)
    end
    for _, variant in ipairs(material.variants or {}) do
      if variant.texture then
        local sha1 = assert(variant.texture:match("/([^/]+)%.png$"), "compiled field-effect variant path is malformed")
        variant.texture = FieldEffectAssetCache.texturePath(sha1)
      end
    end
  end
end

function Compiler.compile(romFs)
  assert(romFs and romFs.openNarc, "Celebi legend compiler requires RomFs")
  local archive, archiveErr = romFs:openNarc(ARCHIVE)
  if not archive then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "Celebi legend source archive is unavailable", {
      archive = ARCHIVE,
      error = tostring(archiveErr),
    })
  end
  local modelBytes = readRequiredMember(archive, MODEL_MEMBER)
  local decodedModel = decodeModel(modelBytes)
  local clips, memberHashes = {}, { { memberId = MODEL_MEMBER, sha1 = Hashing.sha1hex(modelBytes) } }
  for _, source in ipairs(ANIMATIONS) do
    local clip, memberHash = decodeClip(archive, source)
    clips[#clips + 1] = clip
    memberHashes[#memberHashes + 1] = memberHash
  end

  local meshes, textures = {}, {}
  local model = assert(decodedModel.models[1])
  local embeddedTextures = assert(decodedModel.embeddedTextures)
  local descriptor, unresolved = DynamicModelCompiler.compile(
    model,
    decodedModel,
    embeddedTextures,
    { clips = clips },
    {
      role = "field-effect-celebi",
      modelArchive = ARCHIVE,
      modelMemberId = MODEL_MEMBER,
      modelName = model.name,
      textureArchive = ARCHIVE,
      textureMemberId = MODEL_MEMBER,
    },
    MODEL_MEMBER,
    textures,
    meshes
  )
  if #unresolved > 0 then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "Celebi legend model has unresolved material resources", {
      archive = ARCHIVE,
      memberId = MODEL_MEMBER,
      unresolved = unresolved,
    })
  end
  descriptor.key = "field-effect:celebi-time-travel"
  rewritePaths(descriptor)
  ModelAsset.validate(descriptor)
  assert(descriptor.kind == "nitro-dynamic" and #descriptor.animations == 3)
  return {
    definition = { model = descriptor },
    meshes = meshes,
    textures = textures,
    memberHashes = memberHashes,
  }
end

return Compiler
