-- Compiles the hatch application's generated presentation: the background
-- surface, the egg sprite's animation frames, the reveal bars' frames, the two
-- particle resources, and the message bank lines the scene prints. Every pixel
-- and every message comes from the source members the hatch overlay loads
-- (src/application/hatch_egg_gfx.c, src/application/hatch_egg_app.c); the
-- manifest carries only normalized values and staged image paths. Pixel
-- decoding and rasterization reuse the shared 2D producer helpers; particle
-- resources reuse the shared emitter compiler. Pure module: no love
-- dependency, no runtime import.
--
-- Authority: the retail ROM and the pinned native symbols named beside each
-- source group; see romdump/src/config/PokemonCareSources.lua.

local Errors = require("libs.errors.src.Errors")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local PngWriter = require("romdump.src.digest.PngEncoder")
local PokemonCareAssetSchema = require("libs.assets.src.PokemonCareAssetSchema")
local PokemonCareCache = require("libs.assets.src.PokemonCareCache")
local PokemonCareSources = require("romdump.src.config.PokemonCareSources")
local SplEmitterCompiler = require("romdump.src.digest.particle.SplEmitterCompiler")
local UiAssetHelpers = require("romdump.src.digest.ui.UiAssetHelpers")

---@class PokemonCareAssetCompiler
local PokemonCareAssetCompiler = {}

PokemonCareAssetCompiler.ERROR = {
  SOURCE_INVALID = "POKEMON_CARE_HATCH_SOURCE_INVALID",
}

-- The source species-name substitution the hatch lines carry
-- (BufferBoxMonSpeciesName with message-format field 0, which encodes as
-- STRVAR_1 variable 0). The compiled line keeps the substitution position as
-- this marker so the runtime prints the hatched record's own name.
local SPECIES_NAME_MARKER = "{name}"
local SPECIES_STRVAR = FieldMessageText.STRVAR_1
local SPECIES_FIELD = 0

---@param message string
---@param context table<string, unknown>|nil
local function sourceError(message, context)
  error(Errors.new(PokemonCareAssetCompiler.ERROR.SOURCE_INVALID, "hatch " .. message, context or {}), 0)
end

---@param archive table<string, unknown>
---@param memberId integer
---@param role string
---@param dependencies table<string, unknown>[]
---@param archiveLabel string
---@return string
local function readMember(archive, memberId, role, dependencies, archiveLabel)
  return UiAssetHelpers.readMember(archive, memberId, role, dependencies, archiveLabel, sourceError)
end

---@param kind string
---@param bytes string
---@param role string
---@return table
local function decode(kind, bytes, role)
  return UiAssetHelpers.decode(kind, bytes, role, "hatch", sourceError)
end

---@param path string
---@param image { width: integer, height: integer, pixels: string }
---@param assets table<string, string>
---@return table<string, unknown>
local function stageImage(path, image, assets)
  local png = PngWriter.encode(image.width, image.height, image.pixels)
  if png == nil then
    sourceError("image could not be encoded", { path = path })
  end
  assets[path] = assert(png, "hatch image encoding is malformed")
  return { image = path, width = image.width, height = image.height }
end

---@param base string
---@param index integer
---@return string
local function framePath(base, index)
  return string.format("%s/%s-%d.png", PokemonCareCache.hatchDir(), base, index)
end

-- Realizes every frame of one sprite group's source animation sequence in
-- source order, retaining its per-frame duration.
---@param archive table<string, unknown>
---@param group table<string, unknown>
---@param role string
---@param dependencies table<string, unknown>[]
---@param assets table<string, string>
---@return table<string, unknown>
local function compileSpriteGroup(archive, group, role, dependencies, assets)
  local archiveLabel = "hatch-art"
  local charData = decode(
    "decodeChar",
    readMember(archive, assert(group.char --[[@as integer]]), role .. "-char", dependencies, archiveLabel),
    role .. "-char"
  )
  local paletteData = decode(
    "decodePalette",
    readMember(archive, assert(group.palette --[[@as integer]]), role .. "-palette", dependencies, archiveLabel),
    role .. "-palette"
  )
  local colors = paletteData.colors --[[@as table[] ]]
  local bank = assert(group.paletteBank --[[@as integer]], "the sprite group names its palette bank")
  local palette = {}
  for index = 1, 16 do
    local color = colors[bank * 16 + index]
    if color == nil then
      sourceError("sprite palette bank is unavailable", { role = role, bank = bank })
    end
    palette[index] = color
  end
  local cellData = decode(
    "decodeCell",
    readMember(archive, assert(group.cell --[[@as integer]]), role .. "-cell", dependencies, archiveLabel),
    role .. "-cell"
  )
  local animation = decode(
    "decodeAnimation",
    readMember(archive, assert(group.anim --[[@as integer]]), role .. "-anim", dependencies, archiveLabel),
    role .. "-anim"
  )
  local sequenceNo = assert(group.sequence --[[@as integer]], "the sprite group names its sequence")
  local sequence = animation.anims[sequenceNo + 1]
  if sequence == nil then
    sourceError("sprite animation sequence is missing", { role = role, sequence = sequenceNo })
  end
  assert(sequence ~= nil, "missing animation sequences fail above")
  local frames = {}
  for frameIndex in ipairs(sequence.frames) do
    local ok, rendered = pcall(
      G2dRasterizer.renderAnimationFrame,
      charData,
      { colors = palette },
      cellData,
      sequence,
      frameIndex,
      { role = role, frame = frameIndex - 1 },
      nil
    )
    if not ok then
      if Errors.is(rendered) then
        sourceError(role .. " does not rasterize: " .. tostring(rendered), { role = role })
      end
      error(rendered, 0)
    end
    local image = rendered --[[@as { width: integer, height: integer, pixels: string }]]
    local frame = stageImage(framePath(role, frameIndex - 1), image, assets)
    local duration = sequence.frames[frameIndex].duration
    if type(duration) ~= "number" or duration % 1 ~= 0 or duration < 0 then
      sourceError("frame timing is invalid", { role = role, frame = frameIndex - 1 })
    end
    frame.durationTicks = duration
    frames[frameIndex] = frame
  end
  return { frames = frames }
end

-- The scene's background: one composed 256x192 surface from the source char,
-- screen map, and palette.
---@param archive table<string, unknown>
---@param dependencies table<string, unknown>[]
---@param assets table<string, string>
---@return table<string, unknown>
local function compileBackground(archive, dependencies, assets)
  local source = PokemonCareSources.hatchArt.background
  local archiveLabel = "hatch-art"
  local charData = decode(
    "decodeChar",
    readMember(archive, source.char, "background-char", dependencies, archiveLabel),
    "background-char"
  )
  local paletteData = decode(
    "decodePalette",
    readMember(archive, source.palette, "background-palette", dependencies, archiveLabel),
    "background-palette"
  )
  local screenData = decode(
    "decodeScreen",
    readMember(archive, source.screen, "background-screen", dependencies, archiveLabel),
    "background-screen"
  )
  -- The palette member carries exactly the banks the screen addresses, so
  -- rasterization reads the decoded colors directly (the scene's own
  -- destination offset is a hardware slot arrangement, not a different set).
  local image = UiAssetHelpers.rasterizeScreen(
    charData,
    assert(paletteData.colors) --[[@as table]],
    screenData,
    "background",
    sourceError
  )
  return stageImage(framePath("background", 0), image, assets)
end

-- Lowers one hatch message line: literal text with the source species-name
-- substitution kept as a printable marker. Any other substitution is a source
-- form this scene never prints, so it fails instead of publishing a line the
-- runtime cannot fill.
---@param bank table<string, unknown>
---@param bankId integer
---@param messageId integer
---@param role string
---@param dependencies table<string, unknown>[]
---@return { id: integer, text: string, align: string? }
local function compileMessage(bank, bankId, messageId, role, dependencies)
  local tokens = UiAssetHelpers.messageTokens(bank, bankId, messageId, role, "hatch", sourceError)
  local pieces = {}
  local align = nil
  for _, token in ipairs(tokens) do
    local typed = token --[[@as table<string, unknown>]]
    if typed.kind == "substitution" then
      local isSpecies = typed.name == "STRVAR_1"
        and type(typed.control) == "number"
        and typed.control - SPECIES_STRVAR == SPECIES_FIELD
      if not isSpecies then
        sourceError("message line carries an unsupported substitution", {
          role = role,
          messageId = messageId,
          control = typed.control,
          args = typed.args,
        })
      end
      pieces[#pieces + 1] = SPECIES_NAME_MARKER
    elseif typed.kind == "glyph" then
      local text = typed.text
      if type(text) ~= "string" then
        sourceError("glyph token carries no text", { role = role, messageId = messageId })
      end
      assert(type(text) == "string")
      pieces[#pieces + 1] = text
    elseif typed.kind == "line_break" then
      pieces[#pieces + 1] = "\n"
    elseif typed.kind == "eos" then
      break
    elseif typed.kind == "focus_indicator" then
      -- The source's own end-of-line prompt marker; the compiled line keeps
      -- only its printable text and the scene shows its own answer menu.
    elseif typed.control == FieldMessageText.ALN_CENTER then
      align = "center"
    elseif typed.control == FieldMessageText.ALN_RIGHT then
      align = "right"
    else
      sourceError("message line carries an unsupported token", {
        role = role,
        messageId = messageId,
        kind = typed.kind,
        code = typed.code,
        args = typed.args,
        control = typed.control,
      })
    end
  end
  local text = table.concat(pieces)
  text = text:gsub("\n+$", "")
  if text:match("^%s*$") ~= nil then
    sourceError("message line prints nothing", { role = role, messageId = messageId })
  end
  local line = { id = messageId, text = text }
  if align ~= nil then
    line.align = align
  end
  return line
end

---@param romFs table<string, unknown>
---@param dependencies table<string, unknown>[]
---@param assets table<string, string>
---@return table<string, unknown>
local function compileParticles(romFs, dependencies, assets)
  local source = PokemonCareSources.hatchParticles
  local archive, openErr = romFs:openNarc(source.alias)
  if archive == nil then
    sourceError("particle archive is unavailable", { archive = source.alias, cause = openErr })
  end
  assert(archive ~= nil, "missing particle archives fail above")
  local sets = {}
  for _, variant in ipairs({ "egg", "manaphy" }) do
    local memberId = assert(source[variant].member --[[@as integer]])
    local bytes = readMember(archive, memberId, "particle-" .. variant, dependencies, "hatch-particles")
    local compiled, compileErr = SplEmitterCompiler.compile(bytes, {
      texturePath = function(textureId)
        return string.format("%s/particle-%s-%d.png", PokemonCareCache.hatchDir(), variant, textureId)
      end,
    })
    if compiled == nil then
      sourceError("particle resource does not compile", {
        variant = variant,
        cause = tostring(compileErr),
      })
    end
    assert(compiled ~= nil, "uncompilable particle resources fail above")
    for path, bytesOut in pairs(compiled.files --[[@as table<string, string> ]]) do
      assets[path] = bytesOut
    end
    local particles = compiled.particles --[[@as table<string, unknown> ]]
    for _, dependency in ipairs(compiled.dependencies or {}) do
      dependencies[#dependencies + 1] = dependency
    end
    sets[variant] = { emitters = particles.emitters, textures = particles.textures }
  end
  return sets
end

-- Compiles the hatch presentation from one cartridge view.
---@param romFs table<string, unknown>
---@return table<string, unknown>|nil bundle, Errors.Error|nil failure
function PokemonCareAssetCompiler.compileHatch(romFs)
  local dependencies = {}
  local assets = {}
  local ok, bundle = pcall(function()
    local art = PokemonCareSources.hatchArt
    local archive, openErr = romFs:openNarc(art.alias)
    if archive == nil then
      sourceError("art archive is unavailable", { archive = art.alias, cause = openErr })
    end
    assert(archive ~= nil, "missing art archives fail above")
    local background = compileBackground(archive, dependencies, assets)
    local egg = compileSpriteGroup(archive, art.egg, "egg", dependencies, assets)
    local bars = compileSpriteGroup(archive, art.bars, "bars", dependencies, assets)

    local messages = PokemonCareSources.hatchMessages
    local messageArchive, messageErr = romFs:openNarc(messages.alias)
    if messageArchive == nil then
      sourceError("message archive is unavailable", { archive = messages.alias, cause = messageErr })
    end
    assert(messageArchive ~= nil, "missing message archives fail above")
    local bank = UiAssetHelpers.readMessageBank(
      messageArchive,
      messages.memberId,
      "hatch-messages",
      dependencies,
      "hatch",
      sourceError
    )
    local window = PokemonCareSources.hatchWindow
    local manifest = {
      schema = PokemonCareAssetSchema.HATCH_SCHEMA,
      background = background,
      window = {
        x = window.x * 8,
        y = window.y * 8,
        width = window.width * 8,
        height = window.height * 8,
      },
      egg = egg,
      bars = bars,
      messages = {
        hatched = compileMessage(bank, messages.memberId, messages.hatched, "hatched", dependencies),
        nicknameQuestion = compileMessage(
          bank,
          messages.memberId,
          messages.nicknameQuestion,
          "nickname-question",
          dependencies
        ),
        yes = compileMessage(bank, messages.memberId, messages.yes, "yes", dependencies),
        no = compileMessage(bank, messages.memberId, messages.no, "no", dependencies),
      },
      particles = compileParticles(romFs, dependencies, assets),
    }
    local valid, validationErr = pcall(PokemonCareAssetSchema.assertHatchManifest, manifest)
    if not valid then
      sourceError("compiled manifest is invalid", { cause = tostring(validationErr) })
    end
    return { manifest = manifest, assets = assets, dependencies = dependencies }
  end)
  if ok then
    return bundle --[[@as table<string, unknown>]]
  end
  if Errors.is(bundle) then
    return nil, bundle --[[@as Errors.Error]]
  end
  error(bundle, 0)
end

return PokemonCareAssetCompiler
