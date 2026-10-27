-- Compiles the HGSS title creature and source animation channels from the retail title NARC.
-- Source basis: the retail HGSS title resources in NARC_demo_title_titledemo.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local PngWriter = require("romdump.src.digest.PngEncoder")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local RgbaImage = require("romdump.src.digest.ui.RgbaImage")
local Lz10 = require("romdump.src.digest.Lz10")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local MapPropAnimCompiler = require("romdump.src.digest.model.MapPropAnimCompiler")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local charmap = require("romdump.src.catalog.hgss.charmap")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local TitleScreenCompiler = {}

local ARCHIVE = "NARC_demo_title_titledemo"
---@class TitleSurfaceSource
---@field char integer
---@field screen integer
---@field palette integer

---@class TitleSparkleSource
---@field model integer
---@field joint integer
---@field pattern integer

---@alias TitleClipField "joint"|"srt"|"color"|"pattern"

---@class TitleClipSpec
---@field field TitleClipField
---@field format string
---@field category string
---@field kind string

---@class TitleResources
---@field model integer
---@field clips table<TitleClipField, integer>
---@field sparkle TitleSparkleSource
---@field surfaces table<string, TitleSurfaceSource>
---@field crySpeciesId integer
---@field legendary string

---@type table<string, TitleResources>
local RESOURCES = {
  heartgold = {
    model = 25,
    clips = { joint = 26, srt = 27, color = 28, pattern = 29 },
    sparkle = { model = 38, joint = 39, pattern = 40 },
    surfaces = {
      editionLogo = { char = 34, screen = 35, palette = 4 },
      subscreenLower = { char = 3, screen = 0, palette = 4 },
    },
    crySpeciesId = 250,
    legendary = "ho-oh",
  },
  soulsilver = {
    model = 20,
    clips = { joint = 21, srt = 22, pattern = 23, color = 24 },
    sparkle = { model = 41, joint = 42, pattern = 43 },
    surfaces = {
      editionLogo = { char = 36, screen = 37, palette = 2 },
      subscreenLower = { char = 1, screen = 0, palette = 2 },
    },
    crySpeciesId = 249,
    legendary = "lugia",
  },
}

---@type TitleClipSpec[]
local CLIPS = {
  { field = "joint", format = "NSBCA", category = "joint", kind = "trs" },
  { field = "srt", format = "NSBTA", category = "material", kind = "texsrt" },
  { field = "pattern", format = "NSBTP", category = "material", kind = "pattern" },
  { field = "color", format = "NSBMA", category = "material", kind = "color" },
}

---@param message string
---@param context Errors.Context
local function sourceError(message, context)
  error(Errors.new("STARTUP_TITLE_SOURCE_INVALID", message, context), 0)
end

local function finalizedData(value, role)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" or type(value) == "userdata" then
    if type(value.getSize) == "function" then
      return value
    end
  end
  sourceError("compiled title " .. role .. " is not finalized binary data", { role = role })
end

local function readMember(archive, memberId, role, dependencies, archiveName)
  archiveName = archiveName or ARCHIVE
  if memberId < 0 or memberId >= archive:memberCount() then
    sourceError("title source member is unavailable", {
      archive = archiveName,
      memberId = memberId,
      role = role,
      count = archive:memberCount(),
    })
  end
  local bytes, err = archive:readMember(memberId)
  if type(bytes) ~= "string" then
    sourceError("title source member could not be read", {
      archive = archiveName,
      memberId = memberId,
      role = role,
      error = tostring(err),
    })
  end
  dependencies[#dependencies + 1] = { role = role, sha1 = Hashing.sha1hex(bytes) }
  return bytes
end

local function unpack2d(bytes, role)
  if string.byte(bytes, 1) == 0x10 then
    local unpacked, err = Lz10.decode(bytes)
    if unpacked == nil then
      sourceError("title 2D source could not be decompressed", { role = role, error = tostring(err) })
    end
    return assert(unpacked)
  end
  return bytes
end

---@param bytes string
---@param role string
---@param memberId integer
---@return { depth: integer, tiles: string }
local function decodeChar(bytes, role, memberId)
  local decoded, err = G2dDecoder.decodeChar(unpack2d(bytes, role), { label = "title:" .. role })
  if decoded == nil then
    sourceError("title 2D member has an unexpected format", {
      role = role,
      memberId = memberId,
      error = tostring(err),
    })
  end
  return assert(decoded)
end

---@param bytes string
---@param role string
---@param memberId integer
---@return { width: integer, height: integer, entries: table[] }
local function decodeScreen(bytes, role, memberId)
  local decoded, err = G2dDecoder.decodeScreen(unpack2d(bytes, role), { label = "title:" .. role })
  if decoded == nil then
    sourceError("title 2D member has an unexpected format", {
      role = role,
      memberId = memberId,
      error = tostring(err),
    })
  end
  return assert(decoded)
end

---@param bytes string
---@param role string
---@param memberId integer
---@return { colors: { r: integer, g: integer, b: integer }[] }
local function decodePalette(bytes, role, memberId)
  local decoded, err = G2dDecoder.decodePalette(unpack2d(bytes, role), { label = "title:" .. role })
  if decoded == nil then
    sourceError("title 2D member has an unexpected format", {
      role = role,
      memberId = memberId,
      error = tostring(err),
    })
  end
  return assert(decoded)
end

local function compileClip(bytes, resource, spec)
  local decoded, decodeError = NitroAnimation.decode(bytes, { alias = ARCHIVE, memberId = resource })
  if
    type(decoded) ~= "table"
    or decoded.format ~= spec.format
    or type(decoded.animations) ~= "table"
    or #decoded.animations ~= 1
  then
    sourceError("title animation member has an unexpected format or entry count", {
      archive = ARCHIVE,
      memberId = resource,
      expectedFormat = spec.format,
      actualFormat = decoded and decoded.format,
      animationCount = decoded and type(decoded.animations) == "table" and #decoded.animations or 0,
      error = tostring(decodeError),
    })
  end
  decoded = assert(decoded)
  local animation = assert(decoded.animations[1])
  local clip = MapPropAnimCompiler.compileDecoded(decoded, {
    name = animation.name,
    id = "title:" .. spec.field,
    source = { type = "nitro", format = spec.format, archive = ARCHIVE, memberId = resource },
  })
  if clip.category ~= spec.category or clip.kind ~= spec.kind then
    sourceError("title animation compiled with an unexpected channel", {
      archive = ARCHIVE,
      memberId = resource,
      expectedCategory = spec.category,
      expectedKind = spec.kind,
      category = clip.category,
      kind = clip.kind,
    })
  end
  clip.source = nil
  return clip
end

local function compileSurface(archive, spec, role, dependencies, files)
  local charBytes = readMember(archive, spec.char, role .. "-characters", dependencies)
  local screenBytes = readMember(archive, spec.screen, role .. "-screen", dependencies)
  local paletteBytes = readMember(archive, spec.palette, role .. "-palette", dependencies)
  local charData = decodeChar(charBytes, role .. "-characters", spec.char)
  local screenData = decodeScreen(screenBytes, role .. "-screen", spec.screen)
  local paletteData = decodePalette(paletteBytes, role .. "-palette", spec.palette)
  if screenData.width ~= 256 or screenData.height < 192 then
    sourceError("title screen map must cover the retail 256 by 192 display", {
      role = role,
      width = screenData.width,
      height = screenData.height,
    })
  end
  local rendered = G2dRasterizer.renderScreen(charData, paletteData, screenData, {
    asset = ARCHIVE,
    member = spec.screen,
    role = role,
  })
  local surface = RgbaImage.crop(rendered, { x = 0, y = 0, width = 256, height = 192 }, "title " .. role)
  local path = "assets/generated/startup/title/surfaces/" .. role .. ".png"
  files[path] = PngWriter.encode(surface.width, surface.height, surface.pixels)
  return {
    width = surface.width,
    height = surface.height,
    image = path,
    sourceHash = Hashing.hashLua({
      characters = Hashing.sha1hex(charBytes),
      screen = Hashing.sha1hex(screenBytes),
      palette = Hashing.sha1hex(paletteBytes),
    }),
  }
end

local function compilePrompt(romFs, versionId, dependencies)
  local archive, err = romFs:openNarc("messages")
  if archive == nil then
    sourceError("title prompt message archive is unavailable", { error = tostring(err) })
  end
  archive = assert(archive)
  local bytes = readMember(archive, 719, "touch-to-start-message", dependencies, "messages")
  local bank, decodeError = FieldMessageBank.decode(bytes, { label = "title-message-bank-719" })
  if bank == nil then
    sourceError("title prompt message bank is malformed", { error = tostring(decodeError) })
  end
  bank = assert(bank)
  local message = bank.messages[1]
  if message == nil then
    sourceError("title prompt message is missing", { bankId = 719, messageId = 0 })
  end
  message = assert(message)
  local tokens, tokenizeError = FieldMessageTokenizer.tokenize(message.raw, charmap, { bankId = 719, messageId = 0 })
  if tokens == nil then
    sourceError("title prompt message could not be tokenized", { error = tostring(tokenizeError) })
  end
  tokens = assert(tokens) ---@type FieldMessageText.Token[]
  local parsedText = FieldMessageText.tokensToText(tokens)
  if parsedText ~= "{ALN_CENTER}TOUCH TO START" then
    sourceError("title prompt message differs from the retail centered start instruction", { text = parsedText })
  end
  -- The retail prompt ink is an edition-specific text-palette entry
  -- (src/title_screen.c, TitleScreenAnim_Load2dBgGfx): HeartGold prints
  -- with foreground index 1 over RGB(27, 8, 0), SoulSilver with
  -- foreground index 2 over RGB(0, 28, 31). Both are DS RGB555 literals
  -- compiled here to 0..1 floats; the shadow index matches the
  -- foreground index per edition, so both passes share one RGB.
  local promptRgb = versionId == "heartgold" and { 27 / 31, 8 / 31, 0 } or { 0, 28 / 31, 1 }
  return {
    text = "TOUCH TO START",
    alignment = "center",
    tokens = tokens,
    color = versionId == "heartgold" and {
      foreground = 1,
      shadow = 1,
      background = 0,
      foregroundRgb = { promptRgb[1], promptRgb[2], promptRgb[3] },
      shadowRgb = { promptRgb[1], promptRgb[2], promptRgb[3] },
    } or {
      foreground = 2,
      shadow = 2,
      background = 0,
      foregroundRgb = { promptRgb[1], promptRgb[2], promptRgb[3] },
      shadowRgb = { promptRgb[1], promptRgb[2], promptRgb[3] },
    },
    flash = {
      initialDelayFrames = 30,
      initialPhaseFrame = 30,
      cycleFrames = 45,
      visibleFrames = 30,
      hiddenFrames = 15,
    },
  }
end

local CAMERA = {
  heartgold = {
    endPosition = { 625, 152, 256 },
    points = {
      { position = { 180, 177, 301 }, durationSeconds = 10 },
      { position = { 335, -293, 296 }, durationSeconds = 5 },
      { position = { 180, 177, 301 }, durationSeconds = 5 },
      { position = { 625, 152, 256 }, durationSeconds = 10 },
    },
  },
  soulsilver = {
    endPosition = { 420, 87, 331 },
    points = {
      { position = { 105, 162, 291 }, durationSeconds = 10 },
      { position = { 395, 432, 191 }, durationSeconds = 5 },
      { position = { 105, 162, 291 }, durationSeconds = 5 },
      { position = { 420, 87, 331 }, durationSeconds = 10 },
    },
  },
}

-- The retail title camera uses Nitro perspective with half-angle 0xB60 on a
-- 4:3 source frame and a near/far clip pair of (0, 0.5). The source near
-- plane is not representable to a host depth projection, so the manifest
-- keeps the raw source clip facts while the runtime maps them onto a
-- stable positive GPU range that contains the whole camera script.
local function titleProjection()
  return {
    nitroHalfAngleIndex = 0xB60,
    sourceAspect = { width = 4, height = 3 },
    sourceNear = 0,
    sourceFar = 0.5,
  }
end

-- The retail title screen enables exactly two white directional lights whose
-- source vectors normalize to straight up: (0, 0.635498, 0) and
-- (0, 0.476807, 0). Slots 2 and 3 stay disabled. Material registers are the
-- constant title profile: a white diffuse key over a mid ambient floor with
-- specular and emission off, so upward faces shade while the model can
-- never render unlit. Each slot carries the packed RGB555 register the GPU
-- upload reads plus the normalized float aliases the scene lighting record
-- exposes to the shared field-lighting selection.
local WHITE_RGB555 = 31 + 31 * 32 + 31 * 1024
local AMBIENT_RGB555 = 10 + 10 * 32 + 10 * 1024
local FX12_ONE = 4096
local function titleLighting()
  local function slot(enabled, x, y, z)
    local color = enabled and { 1, 1, 1 } or { 0, 0, 0 }
    return {
      enabled = enabled,
      colorRgb555 = enabled and WHITE_RGB555 or 0,
      color = color,
      vectorFx12 = { x, y, z },
      direction = { x / FX12_ONE, y / FX12_ONE, z / FX12_ONE },
    }
  end
  return {
    records = {
      {
        endHalfSeconds = 43200,
        lights = {
          slot(true, 0, FX12_ONE, 0),
          slot(true, 0, FX12_ONE, 0),
          slot(false, 0, 0, 0),
          slot(false, 0, 0, 0),
        },
        diffuseRgb555 = WHITE_RGB555,
        ambientRgb555 = AMBIENT_RGB555,
        specularRgb555 = 0,
        emissionRgb555 = 0,
      },
    },
  }
end

local function cameraTimeline(versionId)
  local source = assert(CAMERA[versionId])
  return {
    start = { position = { 0, 65, 72 }, target = { 0, 90, 0 } },
    target = { -2, 124, -38 },
    endPosition = source.endPosition,
    points = source.points,
    movement = { unitsPerFrame = 5, tolerance = 1, waitFramesPerSecond = 30 },
  }
end

local function baseTexturePack(model, modelPack)
  local missing = {}
  for _, material in ipairs(model.materials) do
    if material.textureName and modelPack.textureByName[material.textureName] == nil then
      missing[material.textureName] = true
    end
  end
  if next(missing) then
    sourceError("title model TEX0 is missing a referenced base texture", { model = model.name, textures = missing })
  end
  return modelPack
end

local function rewriteAssetPaths(model)
  local function rewrite(path)
    assert(type(path) == "string", "compiled title asset path is missing")
    local geometry = path:match("^assets/generated/maps/geometry/(.+)$")
    if geometry then
      return "assets/generated/startup/title/geometry/" .. geometry
    end
    local texture = path:match("^assets/generated/maps/textures/(.+)$")
    if texture then
      return "assets/generated/startup/title/textures/" .. texture
    end
    return path
  end
  for _, batch in ipairs(model.dynamic.batches) do
    batch.geometry = rewrite(batch.geometry)
  end
  for _, material in ipairs(model.materials) do
    if material.texture then
      material.texture = rewrite(material.texture)
    end
    for _, variant in ipairs(material.variants or {}) do
      variant.texture = rewrite(variant.texture)
    end
  end
end

---@param romFs RomFs
---@param versionId string
---@return table<string, unknown>
local function compile(romFs, versionId)
  assert(type(romFs) == "table" and type(romFs.openNarc) == "function", "title compilation requires a ROM filesystem")
  local resources = RESOURCES[versionId]
  if resources == nil then
    sourceError("unsupported title edition", { versionId = versionId })
  end
  resources = assert(resources)
  local archive, archiveError = romFs:openNarc(ARCHIVE)
  if archive == nil then
    error(archiveError, 0)
  end
  local dependencies = {}
  local modelBytes = readMember(archive, resources.model, "title-model", dependencies)
  local decodedModel, modelError = Nsbmd.decode(modelBytes, { alias = ARCHIVE, memberId = resources.model })
  if
    type(decodedModel) ~= "table"
    or type(decodedModel.models) ~= "table"
    or type(decodedModel.models[1]) ~= "table"
    or type(decodedModel.embeddedTextures) ~= "table"
  then
    sourceError("title model member is not a textured NSBMD", {
      archive = ARCHIVE,
      memberId = resources.model,
      error = tostring(modelError),
    })
  end
  decodedModel = assert(decodedModel)

  local clips = {} ---@type table<string, table<string, unknown>>
  local memberIds = { resources.model } ---@type integer[]
  for _, spec in ipairs(CLIPS) do
    local memberId = assert(resources.clips[spec.field])
    memberIds[#memberIds + 1] = memberId
    local bytes = readMember(archive, memberId, "title-" .. spec.field, dependencies)
    clips[spec.field] = compileClip(bytes, memberId, spec)
  end
  -- Retail soulsilver's title PAT0 carries no texture targets, so that
  -- edition has no pattern animation. The channel is omitted instead of
  -- published as a trackless clip the model contract rejects; every other
  -- title channel must stay animated.
  local patternTracks = assert(clips.pattern).tracks
  assert(type(patternTracks) == "table", "title pattern channel lost its tracks")
  if #patternTracks == 0 then
    clips.pattern = nil
  end
  local animationClips = { clips.joint, clips.srt }
  if clips.pattern ~= nil then
    animationClips[#animationClips + 1] = clips.pattern
  end
  animationClips[#animationClips + 1] = clips.color

  local modelData = assert(decodedModel.models[1])
  local modelTextures = assert(decodedModel.embeddedTextures)
  local basePack = baseTexturePack(modelData, modelTextures)
  local textures, meshes = {}, {}
  local model, unresolved = DynamicModelCompiler.compile(
    modelData,
    decodedModel,
    basePack,
    { clips = animationClips },
    {
      role = "startup-title-legendary",
      modelArchive = ARCHIVE,
      modelMemberId = resources.model,
      modelName = modelData.name,
      finalizeMeshes = true,
    },
    resources.model,
    textures,
    meshes
  )
  if #unresolved > 0 then
    sourceError("title model has unresolved material resources", {
      archive = ARCHIVE,
      memberId = resources.model,
      unresolved = unresolved,
    })
  end
  model.memberId = nil
  rewriteAssetPaths(model)
  ModelAsset.validate(model)

  memberIds[#memberIds + 1] = resources.sparkle.model
  memberIds[#memberIds + 1] = resources.sparkle.joint
  memberIds[#memberIds + 1] = resources.sparkle.pattern
  local sparkleModelBytes = readMember(archive, resources.sparkle.model, "title-sparkle-model", dependencies)
  local decodedSparkle, sparkleModelError = Nsbmd.decode(sparkleModelBytes, {
    alias = ARCHIVE,
    memberId = resources.sparkle.model,
  })
  if
    type(decodedSparkle) ~= "table"
    or type(decodedSparkle.models) ~= "table"
    or type(decodedSparkle.models[1]) ~= "table"
  then
    sourceError("title sparkle member is not an NSBMD model", {
      archive = ARCHIVE,
      memberId = resources.sparkle.model,
      error = tostring(sparkleModelError),
    })
  end
  decodedSparkle = assert(decodedSparkle)
  local sparkleClips = {
    joint = compileClip(
      readMember(archive, resources.sparkle.joint, "title-sparkle-joint", dependencies),
      resources.sparkle.joint,
      CLIPS[1]
    ),
    pattern = compileClip(
      readMember(archive, resources.sparkle.pattern, "title-sparkle-pattern", dependencies),
      resources.sparkle.pattern,
      CLIPS[3]
    ),
  }
  local sparkleData = assert(decodedSparkle.models[1])
  -- Lugia's sparkle mesh is untextured (one lambert material, no texture
  -- reference), so its NSBMD carries no embedded TEX0. An empty pack flows
  -- through: a genuinely referenced texture still fails at the unresolved
  -- check below.
  local sparkleTextures = decodedSparkle.embeddedTextures or { textureByName = {} }
  local sparkleModel, sparkleUnresolved = DynamicModelCompiler.compile(
    sparkleData,
    decodedSparkle,
    baseTexturePack(sparkleData, sparkleTextures),
    { clips = { sparkleClips.joint, sparkleClips.pattern } },
    {
      role = "startup-title-sparkle",
      modelArchive = ARCHIVE,
      modelMemberId = resources.sparkle.model,
      modelName = sparkleData.name,
      finalizeMeshes = true,
    },
    resources.sparkle.model,
    textures,
    meshes
  )
  if #sparkleUnresolved > 0 then
    sourceError("title sparkle model has unresolved material resources", {
      archive = ARCHIVE,
      memberId = resources.sparkle.model,
      unresolved = sparkleUnresolved,
    })
  end
  sparkleModel.memberId = nil
  rewriteAssetPaths(sparkleModel)
  ModelAsset.validate(sparkleModel)

  local files = {}
  for sha1, mesh in pairs(meshes) do
    files["assets/generated/startup/title/geometry/" .. sha1 .. ".g4mesh"] = finalizedData(mesh, "geometry")
  end
  for sha1, texture in pairs(textures) do
    files["assets/generated/startup/title/textures/" .. sha1 .. ".png"] = finalizedData(texture.data, "texture")
  end

  local surfaces = {}
  for role, spec in pairs(resources.surfaces) do
    surfaces[role] = compileSurface(archive, spec, role, dependencies, files)
  end
  local prompt = compilePrompt(romFs, versionId, dependencies)

  local romMetadata = assert(romFs:metadata())
  dependencies.versionId = versionId
  dependencies.romSha1 = assert(romMetadata.sha1)
  dependencies.modelMembers = memberIds
  return {
    manifest = {
      schema = "g4-startup-title-v2",
      versionId = versionId,
      kind = "animated-title",
      legendary = resources.legendary,
      crySpeciesId = resources.crySpeciesId,
      sequence = "SEQ_GS_POKEMON_THEME",
      menuSelectSequence = "SEQ_SE_DP_SELECT",
      model = model,
      clips = clips,
      surfaces = surfaces,
      sparkle = { model = sparkleModel, clips = sparkleClips },
      timeline = {
        camera = cameraTimeline(versionId),
        animation = { startFrame = 0, framesPerUpdate = 1 },
        titleReveal = { delayFrames = 3, durationFrames = 32 },
        start = { initialDelayFrames = 30, activeDurationFrames = 2340 },
        glow = {
          fadeInSteps = 61,
          fadeOutSteps = 61,
          pauseFrames = 21,
          color = { 12, 12, 12 },
        },
        attachments = {
          model = { framesPerUpdate = 1, endFrame = "wrap-to-zero" },
          sparkle = { framesPerUpdate = 1, endFrame = "wrap-to-zero" },
        },
      },
      prompt = prompt,
      projection = titleProjection(),
      lighting = titleLighting(),
    },
    files = files,
    dependencies = dependencies,
    sourceHash = Hashing.hashLua(dependencies),
  }
end

---@param romFs RomFs
---@param versionId string
---@return table<string, unknown>|nil
---@return Errors.Error|string|nil
function TitleScreenCompiler.compile(romFs, versionId)
  local ok, result = pcall(compile, romFs, versionId)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result, 0)
end

return TitleScreenCompiler
