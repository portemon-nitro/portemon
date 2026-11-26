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
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local ModelAssetCompiler = require("romdump.src.digest.model.ModelAssetCompiler")
local MonCache = require("libs.assets.src.MonCache")
local MonSources = require("romdump.src.config.MonSources")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local Hashing = require("romdump.src.digest.Hashing")
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
-- The trade sequence fills message-format buffers 0..2 with the sent mon's
-- nickname, the received mon's nickname and the player's name; the compiled
-- lines keep those positions as printable markers.
local REMINDER_MON_MARKER = "{mon}"
local REMINDER_MOVE_MARKER = "{move}"
-- STRVAR_1 controls the reminder lines substitute: 1 is the boxed mon's
-- nickname buffer, 6 a move name buffer.
local REMINDER_MON_STRVAR = 0x0101
local REMINDER_MOVE_STRVAR = { [0x0106] = true, [0x0107] = true }
local TRADE_SENT_MARKER = "{sent}"
local TRADE_RECEIVED_MARKER = "{received}"
local TRADE_PLAYER_MARKER = "{player}"

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
---@param decodeOptions table<string, unknown>?
---@return table<string, unknown>
local function decode(kind, bytes, role, decodeOptions)
  return UiAssetHelpers.decode(kind, bytes, role, "hatch", sourceError, decodeOptions)
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

-- Decodes one sprite group's source members: the character tiles, the
-- sixteen-colour palette bank the sprites draw with, the cell bank and the
-- animation bank.
---@param archive table<string, unknown>
---@param group table<string, unknown>
---@param role string
---@param archiveLabel string
---@param dependencies table<string, unknown>[]
---@return table<string, unknown> charData
---@return table[] palette
---@return table<string, unknown> cellData
---@return table<string, unknown> animation
local function decodeSpriteGroup(archive, group, role, archiveLabel, dependencies)
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
  return charData, palette, cellData, animation
end

-- True when one animation frame resolves to a cell with no objects: the
-- source shows nothing on that frame (the sprite animations carry blank
-- frames), so the frame publishes its blank mark instead of pixels nobody
-- authored.
---@param cellData table<string, unknown>
---@param animationFrame table<string, unknown>
---@return boolean
local function isBlankFrame(cellData, animationFrame)
  local cellId = animationFrame.cell
  if type(cellId) ~= "number" then
    return false
  end
  local cell = (cellData.cells --[[@as table[] ]])[cellId + 1]
  return type(cell) == "table" and (type(cell.objs) ~= "table" or #cell.objs == 0)
end

-- Realizes every frame of one decoded animation sequence in source order,
-- retaining its per-frame duration. A blank source frame keeps only its mark
-- and timing when the caller admits blank frames.
---@param charData table<string, unknown>
---@param palette table[]
---@param cellData table<string, unknown>
---@param sequence table<string, unknown>
---@param role string frame path role of this sequence
---@param directory string staged directory the frames live under
---@param assets table<string, string>
---@param allowBlank boolean? whether blank source frames are published as marks
---@return table<string, unknown> { frames = ... }
local function compileAnimationFrames(charData, palette, cellData, sequence, role, directory, assets, allowBlank)
  local frames = {}
  for frameIndex in ipairs(sequence.frames) do
    local sourceFrame = assert(sequence.frames[frameIndex] --[[@as table<string, unknown>]])
    local duration = sourceFrame.duration
    if type(duration) ~= "number" or duration % 1 ~= 0 or duration < 0 then
      sourceError("frame timing is invalid", { role = role, frame = frameIndex - 1 })
    end
    if allowBlank == true and isBlankFrame(cellData, sourceFrame) then
      frames[frameIndex] = { blank = true, durationTicks = duration }
    else
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
      local path = string.format("%s/%s-%d.png", directory, role, frameIndex - 1)
      local frame = stageImage(path, image, assets)
      frame.durationTicks = duration
      frames[frameIndex] = frame
    end
  end
  return { frames = frames }
end

-- One sequence of a sprite group, from its decoded members.
---@param animation table<string, unknown>
---@param sequenceNo integer zero-based animation sequence identity
---@param role string frame path role of this sequence
---@param directory string staged directory the frames live under
---@param charData table<string, unknown>
---@param palette table[]
---@param cellData table<string, unknown>
---@param assets table<string, string>
---@param allowBlank boolean? whether blank source frames are published as marks
---@return table<string, unknown> { frames = ... }
local function compileSequence(animation, sequenceNo, role, directory, charData, palette, cellData, assets, allowBlank)
  local sequence = animation.anims[sequenceNo + 1]
  if sequence == nil then
    sourceError("sprite animation sequence is missing", { role = role, sequence = sequenceNo })
  end
  return compileAnimationFrames(
    charData,
    palette,
    cellData,
    assert(sequence --[[@as table<string, unknown>]]),
    role,
    directory,
    assets,
    allowBlank
  )
end

-- Realizes every frame of one hatch sprite group's source animation sequence.
---@param archive table<string, unknown>
---@param group table<string, unknown>
---@param role string
---@param dependencies table<string, unknown>[]
---@param assets table<string, string>
---@return table<string, unknown>
local function compileSpriteGroup(archive, group, role, dependencies, assets)
  local charData, palette, cellData, animation = decodeSpriteGroup(archive, group, role, "hatch-art", dependencies)
  local sequenceNo = assert(group.sequence --[[@as integer]], "the sprite group names its sequence")
  return compileSequence(animation, sequenceNo, role, PokemonCareCache.hatchDir(), charData, palette, cellData, assets)
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
---@return { id: integer, text: string, align: string? }
local function compileMessage(bank, bankId, messageId, role)
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
    local function particleTexturePath(textureId)
      return string.format("%s/particle-%s-%d.png", PokemonCareCache.hatchDir(), variant, textureId)
    end
    local compiled, compileErr = SplEmitterCompiler.compile(bytes, {
      texturePath = particleTexturePath,
    })
    if compiled == nil then
      sourceError("particle resource does not compile", {
        variant = variant,
        cause = tostring(compileErr),
      })
    end
    assert(compiled ~= nil, "uncompilable particle resources fail above")
    for path, bytesOut in
      pairs(compiled.files --[[@as table<string, string> ]])
    do
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
        hatched = compileMessage(bank, messages.memberId, messages.hatched, "hatched"),
        nicknameQuestion = compileMessage(bank, messages.memberId, messages.nicknameQuestion, "nickname-question"),
        yes = compileMessage(bank, messages.memberId, messages.yes, "yes"),
        no = compileMessage(bank, messages.memberId, messages.no, "no"),
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

-- Compiles the app71 trade sequence's generated presentation: every source
-- scene's own composed layers, the source message-window geometry and the four
-- bank-179 lines the in-game trade prints. Each layer is rasterized from the
-- exact members the native scene loads
-- (src/application/trade_sequence/trade_sequence_{send,depart,recede,exchange,
-- approach,arrive,receive}.c) under that scene's own palette-load rules: the
-- depart/arrive map layer is the 256-colour affine surface whose palette takes
-- its second block from the time-of-day offset, the outdoor layer shifts one
-- colour bank per time of day, and the 256x16 layer loads one 256-colour bank.
-- Pure module: no love dependency, no runtime import.

-- One layer's 256-colour palette under the source's partial loads. Each load
-- places `colors` palette entries at `firstColor`, reading the member from
-- `source` (0 for the first bank, or the time-of-day byte offset).
---@param loads table[]
---@param paletteOffsets table<string, integer>?
---@param variant string?
---@param paletteColors table[]
---@return table[]
local function tradePlacedPalette(loads, paletteOffsets, variant, paletteColors)
  local colors = {}
  for _, load in ipairs(loads) do
    local first = 0
    if load.source == "timeOfDay" then
      local offsets = assert(paletteOffsets, "a time-of-day palette load names its offsets")
      local offsetBytes = assert(offsets[assert(variant, "a time-of-day palette load names its variant")], nil)
      assert(offsetBytes % 2 == 0, "palette byte offsets are whole colours")
      first = offsetBytes / 2
    else
      first = assert(load.source --[[@as integer]], "a palette load names its source offset")
    end
    local target = load.firstColor == nil and 0 or assert(load.firstColor --[[@as integer]])
    for index = 0, assert(load.colors --[[@as integer]]) - 1 do
      local color = paletteColors[first + index + 1]
      if color ~= nil then
        colors[target + index + 1] = color
      end
    end
  end
  return colors
end

-- One layer's 16-colour palette shifted by whole colour banks: the source
-- loads the member from a later bank into hardware slot zero, so the screen's
-- own bank indices read that shifted range.
---@param paletteColors table[]
---@param bankShift integer
---@return table[]
local function tradeShiftedPalette(paletteColors, bankShift)
  local colors = {}
  for index = 1, #paletteColors do
    colors[index] = paletteColors[index + bankShift * 16] or paletteColors[index]
  end
  return colors
end

---@param archive table<string, unknown>
---@param layerSource table<string, unknown>
---@param role string
---@param dependencies table<string, unknown>[]
---@param assets table<string, string>
---@return table<string, unknown> one layer manifest record
local function compileTradeLayer(archive, layerSource, role, dependencies, assets)
  local archiveLabel = "trade-art"
  local charData = decode(
    "decodeChar",
    readMember(archive, assert(layerSource.char --[[@as integer]]), role .. "-char", dependencies, archiveLabel),
    role .. "-char"
  )
  local paletteData = decode(
    "decodePalette",
    readMember(archive, assert(layerSource.palette --[[@as integer]]), role .. "-palette", dependencies, archiveLabel),
    role .. "-palette"
  )
  -- An affine layer is the source's 256-colour background, whose map stores
  -- one tile-index byte per entry; every text layer stores two.
  local screenData = decode(
    "decodeScreen",
    readMember(archive, assert(layerSource.screen --[[@as integer]]), role .. "-screen", dependencies, archiveLabel),
    role .. "-screen",
    layerSource.affine == true and { entryBytes = 1 } or nil
  )
  local paletteColors = assert(paletteData.colors) --[[@as table[] ]]
  local affine = layerSource.affine == true
  -- The affine layers publish their palette indices too: the source's link
  -- pulses walk the layer's own palette slots, and only an index plane lets a
  -- consumer resolve a slot back to its pixels.
  local indexPath = nil
  if affine then
    local plane = G2dRasterizer.renderScreenIndices(charData, screenData, { role = role .. "-indices" })
    indexPath = PokemonCareCache.tradeIndexPath(role)
    assets[indexPath] = plane.indices
  end

  ---@param variant string?
  ---@return table<string, unknown>
  local function compose(variant)
    local colors
    if layerSource.paletteLoads ~= nil then
      colors = tradePlacedPalette(
        layerSource.paletteLoads --[[@as table[] ]],
        layerSource.paletteOffsets --[[@as table<string, integer>? ]],
        variant,
        paletteColors
      )
    elseif layerSource.paletteOffsets ~= nil then
      local offsets = layerSource.paletteOffsets --[[@as table<string, integer> ]]
      local offsetBytes = assert(offsets[assert(variant, "a time-of-day layer names its variant")], nil)
      assert(offsetBytes % 32 == 0, "16-colour layer offsets are whole banks")
      colors = tradeShiftedPalette(paletteColors, math.floor(offsetBytes / 32))
    else
      colors = paletteColors
    end
    local image = UiAssetHelpers.rasterizeScreen(
      charData,
      colors,
      screenData,
      variant ~= nil and (role .. "-" .. variant) or role,
      sourceError
    )
    local path =
      string.format("%s/%s%s.png", PokemonCareCache.tradeDir(), role, variant ~= nil and ("-" .. variant) or "")
    return stageImage(path, image, assets)
  end

  local record = {}
  if layerSource.paletteOffsets ~= nil then
    local variants = {}
    for _, variantName in ipairs(PokemonCareSources.tradeBackdropNames) do
      if
        (layerSource.paletteOffsets --[[@as table<string, integer> ]])[variantName] ~= nil
      then
        variants[variantName] = compose(variantName)
      end
    end
    record.variants = variants
  else
    local image = compose(nil)
    record.image = image.image
    record.width = image.width
    record.height = image.height
  end
  if affine then
    record.affine = true
    record.indices = assert(indexPath, "an affine layer publishes its index plane")
  end
  return record
end

-- The complete trade scene inventory: every phase the sequence plays, with its
-- source layers in native draw order.
---@param archive table<string, unknown>
---@param dependencies table<string, unknown>[]
---@param assets table<string, string>
---@return table<string, unknown>
local function compileTradeScenes(archive, dependencies, assets)
  local scenes = {}
  for _, phase in ipairs(PokemonCareSources.tradePhaseOrder) do
    local source = assert(PokemonCareSources.tradeScenes[phase], "every played phase names its source scene")
    local layers = {}
    for index, layerSource in
      ipairs(source.layers --[[@as table[] ]])
    do
      layers[index] = compileTradeLayer(archive, layerSource, phase .. "-" .. index, dependencies, assets)
    end
    scenes[phase] = { layers = layers }
  end
  return scenes
end

-- One trade sprite sheet: its decoded members read once, then every animation
-- sequence its scenes select. Each published sequence names its own source
-- sequence index, so the runtime selects exactly the sequence the scene sets
-- with Sprite_SetAnimCtrlSeq.
---@param archive table<string, unknown>
---@param sheet table<string, unknown>
---@param key string sheet identity in the manifest
---@param dependencies table<string, unknown>[]
---@param assets table<string, string>
---@return table<string, unknown> { sequences = ... }
local function compileTradeSpriteSheet(archive, sheet, key, dependencies, assets)
  local charData, palette, cellData, animation = decodeSpriteGroup(archive, sheet, key, "trade-art", dependencies)
  local sequences = {}
  for _, sequenceNo in
    ipairs(sheet.sequences --[[@as integer[] ]])
  do
    local compiled = compileSequence(
      animation,
      sequenceNo,
      key .. "-" .. tostring(sequenceNo),
      PokemonCareCache.tradeDir(),
      charData,
      palette,
      cellData,
      assets,
      true
    )
    sequences[#sequences + 1] = { sequence = sequenceNo, frames = compiled.frames }
  end
  return { sequences = sequences }
end

-- The trade scene's Poke Ball model: the single model of member 27, compiled
-- into normalized batches/materials whose geometry and textures are staged
-- under the trade family's own content-addressed paths. The runtime realizes
-- it through the shared model stack (GpuAssetPool, ModelDefinition,
-- ModelInstance), exactly like every other generated model.
---@param archive table<string, unknown>
---@param dependencies table<string, unknown>[]
---@param assets table<string, string>
---@return table<string, unknown> model descriptor
local function compileTradeBalloon(archive, dependencies, assets)
  local memberId = assert(PokemonCareSources.tradeArt.balloonMember --[[@as integer]])
  local bytes = readMember(archive, memberId, "balloon-model", dependencies, "trade-art")
  local decoded = Nsbmd.decode(bytes, { alias = "NARC_a_0_8_9", memberId = memberId, section = "trade-balloon" })
  if decoded == nil then
    sourceError("the trade balloon model does not decode", { memberId = memberId })
  end
  ---@cast decoded -nil
  local model = assert(decoded.models[1], "decoded balloon source exists")
  if decoded.embeddedTextures == nil then
    sourceError("the trade balloon model carries no model or textures", { memberId = memberId })
  end
  ---@cast model -nil
  local meshes, textures = {}, {}
  local compiled = ModelAssetCompiler.compileModel(model, decoded.embeddedTextures, meshes, textures, {
    role = "trade-balloon",
    modelArchive = "NARC_a_0_8_9",
    modelMemberId = memberId,
    modelName = model.name,
    textureArchive = "NARC_a_0_8_9",
    textureMemberId = memberId,
    finalizeMeshes = true,
  })
  if #compiled.unresolved > 0 then
    sourceError("the trade balloon model has unresolved materials", {
      memberId = memberId,
      unresolved = #compiled.unresolved,
    })
  end
  for sha1, mesh in pairs(meshes) do
    assets[PokemonCareCache.tradeGeometryPath(sha1)] = mesh
  end
  for key, texture in pairs(textures) do
    assets[PokemonCareCache.tradeTexturePath(key)] = texture
  end
  local descriptor = {
    schema = ModelAsset.SCHEMA,
    key = "trade-balloon",
    kind = "static",
    batches = compiled.batches,
    materials = compiled.materials,
  }
  for _, batch in ipairs(descriptor.batches) do
    batch.geometry = ModelAsset.retargetGeometry(batch.geometry, PokemonCareCache.tradeGeometryPath)
  end
  for _, material in ipairs(descriptor.materials) do
    if material.texture ~= nil then
      material.texture = ModelAsset.retargetTexture(material.texture, PokemonCareCache.tradeTexturePath)
    end
  end
  ModelAsset.validate(descriptor)
  return descriptor
end

-- The front picture height of every portrait the mon family publishes, keyed
-- by that selector: the source anchors a Pokepic's 80x80 frame so its bottom
-- sits at height + 80 (GetBoxMonPicHeightEx). The height only depends on
-- species, form and gender, so shiny selectors share the plain entry.
---@param romFs table<string, unknown>
---@param dependencies table<string, unknown>[]
---@return table<string, integer> height by portrait selector
local function compileTradePictureHeights(romFs, dependencies)
  local base, baseErr = romFs:openNarc(MonSources.PICTURE_HEIGHT_NARC)
  if base == nil then
    sourceError(
      "the picture height archive is unavailable",
      { archive = MonSources.PICTURE_HEIGHT_NARC, cause = baseErr }
    )
  end
  local other, otherErr = romFs:openNarc(MonSources.PICTURE_HEIGHT_OTHER_NARC)
  if other == nil then
    sourceError("the special picture height archive is unavailable", {
      archive = MonSources.PICTURE_HEIGHT_OTHER_NARC,
      cause = otherErr,
    })
  end
  assert(base ~= nil and other ~= nil, "missing height archives fail above")
  local archives = {
    [MonSources.PICTURE_HEIGHT_NARC] = base,
    [MonSources.PICTURE_HEIGHT_OTHER_NARC] = other,
  }
  local facing = assert(PokemonCareSources.tradePicture.facing --[[@as integer]])
  local heights = {}
  for speciesId = 1, MonSources.MAX_SPECIES do
    local speciesKey = assert(MonSources.speciesKeys[speciesId], "every species carries its key")
    for _, form in ipairs(MonSources.runtimeForms(speciesId)) do
      for _, gender in ipairs({ "male", "female" }) do
        local symbol, memberId = MonSources.pictureHeightIds(speciesId, gender, facing, form)
        local archive = assert(archives[symbol], "picture heights read a known archive")
        -- Height members are one plain byte, so they are read raw: the shared
        -- member reader decompresses LZ10 payloads by their 0x10 header, and a
        -- legitimate height of 16 would look like one.
        local bytes, readErr = archive:readMember(memberId)
        if bytes == nil then
          sourceError("a picture height member is unreadable", {
            archive = symbol,
            memberId = memberId,
            cause = tostring(readErr),
          })
        end
        assert(bytes ~= nil, "unreadable height members fail above")
        dependencies[#dependencies + 1] = {
          name = symbol .. ":member:" .. memberId,
          role = "picture-height",
          sha1 = Hashing.sha1hex(bytes),
        }
        -- Members past a species' portrait block are empty: those selectors
        -- have no generated portrait, so they carry no height either.
        if #bytes == 1 then
          heights[MonCache.portraitSelector(speciesKey, form, gender, false)] = string.byte(bytes, 1)
        elseif #bytes ~= 0 then
          sourceError("a picture height member carries at most one byte", {
            archive = symbol,
            memberId = memberId,
            size = #bytes,
          })
        end
      end
    end
  end
  return heights
end

-- Lowers one trade-sequence line: literal text with the three source
-- message-format buffers the sequence fills (the sent mon's nickname, the
-- received mon's nickname and the player's name) kept as printable markers.
---@param bank table<string, unknown>
---@param bankId integer
---@param messageId integer
---@param role string
---@return { id: integer, text: string, align: string? }
local function compileTradeMessage(bank, bankId, messageId, role)
  local tokens = UiAssetHelpers.messageTokens(bank, bankId, messageId, role, "trade", sourceError)
  local pieces = {}
  local align = nil
  for _, token in ipairs(tokens) do
    local typed = token --[[@as table<string, unknown>]]
    if typed.kind == "substitution" then
      -- The sequence's lines name the message-format buffers it fills: field 0
      -- with buffer 0 or 1 is a subject's nickname, and field 3 with buffer 2 is
      -- the trade profile's player name.
      local field = type(typed.control) == "number"
          and typed.name == "STRVAR_1"
          and typed.control - FieldMessageText.STRVAR_1
        or nil
      local args = typed.args --[[@as table|nil ]]
      local buffer = type(args) == "table" and args[1] or nil
      local marker = nil
      if field == 0 and buffer == 0 then
        marker = TRADE_SENT_MARKER
      elseif field == 0 and buffer == 1 then
        marker = TRADE_RECEIVED_MARKER
      elseif field == 3 and buffer == 2 then
        marker = TRADE_PLAYER_MARKER
      end
      if marker == nil then
        sourceError("trade line carries an unsupported substitution", {
          role = role,
          messageId = messageId,
          control = typed.control,
          args = typed.args,
        })
      end
      assert(marker ~= nil, "unsupported substitutions fail above")
      pieces[#pieces + 1] = marker
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
      -- The source end-of-line prompt marker; the compiled line keeps only
      -- its printable text.
    elseif typed.control == FieldMessageText.ALN_CENTER then
      align = "center"
    elseif typed.control == FieldMessageText.ALN_RIGHT then
      align = "right"
    else
      sourceError("trade line carries an unsupported token", {
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
    sourceError("trade line prints nothing", { role = role, messageId = messageId })
  end
  local line = { id = messageId, text = text }
  if align ~= nil then
    line.align = align
  end
  return line
end

-- Lowers one reminder line: its printable text with the source's name and
-- move substitutions kept as markers. Any other substitution is a source form
-- this application never prints, so it fails instead of publishing a line the
-- runtime cannot fill.
---@param bank table<string, unknown>
---@param bankId integer
---@param messageId integer
---@param role string
---@return { id: integer, text: string, align: string? }?
local function compileReminderLine(bank, bankId, messageId, role)
  local ok, tokens = pcall(UiAssetHelpers.messageTokens, bank, bankId, messageId, role, "reminder", sourceError)
  if not ok then
    -- The source table leaves two of its eleven columns empty; an empty line is
    -- simply not printed by this application.
    return nil
  end
  local pieces = {}
  local align = nil
  for _, token in ipairs(tokens) do
    local typed = token --[[@as table<string, unknown>]]
    if typed.kind == "substitution" then
      local control = typed.control
      if typed.name == "STRVAR_1" and control == REMINDER_MON_STRVAR then
        pieces[#pieces + 1] = REMINDER_MON_MARKER
      elseif
        typed.name == "STRVAR_1" and REMINDER_MOVE_STRVAR[
          control --[[@as integer]]
        ]
      then
        pieces[#pieces + 1] = REMINDER_MOVE_MARKER
      else
        sourceError("reminder line carries an unsupported substitution", {
          role = role,
          messageId = messageId,
          control = control,
          args = typed.args,
        })
      end
    elseif typed.kind == "glyph" then
      pieces[#pieces + 1] = assert(typed.text) --[[@as string]]
    elseif typed.kind == "line_break" then
      pieces[#pieces + 1] = "\n"
    elseif typed.kind == "prompt_break" then
      -- The source's scrolling prompt closes a paragraph; the application
      -- prints one window's worth of text per state, so it starts a new line.
      pieces[#pieces + 1] = "\n"
    elseif typed.kind == "eos" then
      break
    elseif typed.kind == "focus_indicator" then
      -- The source's end-of-line answer prompt; the compiled line keeps only
      -- its printable text and the application draws its own answer.
    elseif typed.kind == "pause" or typed.kind == "wait" or typed.kind == "printer_callback" then
      -- The source's own print pacing; the application prints a whole line per
      -- state, so the compiled text carries no timing controls.
    elseif typed.control == FieldMessageText.ALN_CENTER then
      align = "center"
    elseif typed.control == FieldMessageText.ALN_RIGHT then
      align = "right"
    else
      sourceError("reminder line carries an unsupported token", {
        role = role,
        messageId = messageId,
        kind = typed.kind,
        code = typed.code,
        args = typed.args,
        control = typed.control,
      })
    end
  end
  local text = table.concat(pieces):gsub("\n+$", "")
  if text:match("^%s*$") ~= nil then
    return nil
  end
  local line = { id = messageId, text = text }
  if align ~= nil then
    line.align = align
  end
  return line
end

-- One source screen: the shared character data and colour bank rasterized with
-- the screen map the source layer loads.
---@param archive table<string, unknown>
---@param charData table<string, unknown>
---@param palette table<string, unknown>
---@param screenMember integer
---@param role string
---@param dependencies table<string, unknown>[]
---@param assets table<string, string>
---@return table<string, unknown>
local function compileReminderSurface(archive, charData, palette, screenMember, role, dependencies, assets)
  local screenData = decode(
    "decodeScreen",
    readMember(archive, screenMember, role .. "-screen", dependencies, "reminder-art"),
    role .. "-screen"
  )
  local image =
    UiAssetHelpers.rasterizeScreen(charData, assert(palette.colors) --[[@as table]], screenData, role, sourceError)
  return stageImage(PokemonCareCache.reminderDir() .. "/" .. role .. ".png", image, assets)
end

-- Compiles the move reminder / singleton tutor presentation: the source's main
-- and sub screens, its button tile screen, the source window rectangles in
-- pixels, and the compiled msg_0747 lines both modes print.
---@param romFs table<string, unknown>
---@return table<string, unknown>?
---@return Errors.Error?
function PokemonCareAssetCompiler.compileReminder(romFs)
  return UiAssetHelpers.compileWithGuard(function()
    local dependencies = {}
    local assets = {}
    local art = PokemonCareSources.relearnerArt
    local archive, openErr = romFs:openNarc(art.alias)
    if archive == nil then
      sourceError("reminder art archive is unavailable", { archive = art.alias, cause = openErr })
    end
    assert(archive ~= nil, "missing art archives fail above")
    local messagesSource = PokemonCareSources.relearnerMessages
    local messageArchive, messageErr = romFs:openNarc(messagesSource.alias)
    if messageArchive == nil then
      sourceError("reminder message archive is unavailable", {
        archive = messagesSource.alias,
        cause = messageErr,
      })
    end
    assert(messageArchive ~= nil, "missing message archives fail above")
    local charData = decode(
      "decodeChar",
      readMember(archive, art.main.char, "reminder-char", dependencies, "reminder-art"),
      "reminder-char"
    )
    local palette = decode(
      "decodePalette",
      readMember(archive, art.main.palette, "reminder-palette", dependencies, "reminder-art"),
      "reminder-palette"
    )
    local bank = UiAssetHelpers.readMessageBank(
      messageArchive,
      messagesSource.memberId,
      "reminder-messages",
      dependencies,
      "reminder",
      sourceError
    )
    local lines = {}
    local function addLine(messageId, role)
      local line = compileReminderLine(bank, messagesSource.memberId, messageId, role)
      if line ~= nil then
        lines[#lines + 1] = line
      end
    end
    for _, column in ipairs({ "tutor", "relearn" }) do
      local range = assert(messagesSource.columns[column], "the reminder source carries its " .. column .. " column")
      for messageId = range.first, range.last do
        addLine(messageId, column .. "-" .. tostring(messageId))
      end
    end
    for key, messageId in pairs(messagesSource.labels) do
      addLine(messageId, "label-" .. key)
    end
    table.sort(lines, function(a, b)
      return a.id < b.id
    end)
    local windows = {}
    for _, template in ipairs(art.windows) do
      windows[template.key] = {
        x = template.x * 8,
        y = template.y * 8,
        width = template.width * 8,
        height = template.height * 8,
        framed = template.framed,
      }
    end
    local manifest = {
      schema = PokemonCareAssetSchema.REMINDER_SCHEMA,
      main = compileReminderSurface(archive, charData, palette, art.main.screen, "reminder-main", dependencies, assets),
      sub = compileReminderSurface(archive, charData, palette, art.sub.screen, "reminder-sub", dependencies, assets),
      buttons = compileReminderSurface(
        archive,
        charData,
        palette,
        art.buttons.screen,
        "reminder-buttons",
        dependencies,
        assets
      ),
      windows = windows,
      messages = lines,
    }
    local valid, validationErr = pcall(PokemonCareAssetSchema.assertReminderManifest, manifest)
    if not valid then
      sourceError("compiled reminder manifest is invalid", { cause = tostring(validationErr) })
    end
    return { manifest = manifest, assets = assets, dependencies = dependencies }
  end, romFs)
end

-- Compiles the trade sequence presentation from one cartridge view.
---@param romFs table<string, unknown>
---@return table<string, unknown>|nil bundle, Errors.Error|nil failure
function PokemonCareAssetCompiler.compileTrade(romFs)
  local dependencies = {}
  local assets = {}
  local ok, bundle = pcall(function()
    local art = PokemonCareSources.tradeArt
    local archive, openErr = romFs:openNarc(art.alias)
    if archive == nil then
      sourceError("trade art archive is unavailable", { archive = art.alias, cause = openErr })
    end
    assert(archive ~= nil, "missing art archives fail above")

    local messagesSource = PokemonCareSources.tradeSequenceMessages
    local messageArchive, messageErr = romFs:openNarc(messagesSource.alias)
    if messageArchive == nil then
      sourceError("trade message archive is unavailable", { archive = messagesSource.alias, cause = messageErr })
    end
    assert(messageArchive ~= nil, "missing message archives fail above")
    local bank = UiAssetHelpers.readMessageBank(
      messageArchive,
      messagesSource.memberId,
      "trade-sequence-messages",
      dependencies,
      "trade",
      sourceError
    )
    local lines = PokemonCareSources.tradeSequenceLines
    local window = art.window
    local sprites = PokemonCareSources.tradeSprites
    local manifest = {
      schema = PokemonCareAssetSchema.TRADE_SCHEMA,
      window = {
        x = window.x * 8,
        y = window.y * 8,
        width = window.width * 8,
        height = window.height * 8,
      },
      scenes = compileTradeScenes(archive, dependencies, assets),
      sprites = {
        effect = compileTradeSpriteSheet(archive, sprites.effect, "effect", dependencies, assets),
      },
      balloon = { model = compileTradeBalloon(archive, dependencies, assets) },
      pictures = {
        baseY = assert(PokemonCareSources.tradePicture.baseY --[[@as integer]]),
        sentTileX = assert(PokemonCareSources.tradePicture.sentTileX --[[@as integer]]),
        receivedTileX = assert(PokemonCareSources.tradePicture.receivedTileX --[[@as integer]]),
        heights = compileTradePictureHeights(romFs, dependencies),
      },
      messages = {
        send = compileTradeMessage(bank, messagesSource.memberId, lines.send, "send"),
        farewell = compileTradeMessage(bank, messagesSource.memberId, lines.farewell, "farewell"),
        received = compileTradeMessage(bank, messagesSource.memberId, lines.received, "received"),
        takeCare = compileTradeMessage(bank, messagesSource.memberId, lines.takeCare, "take-care"),
      },
    }
    local valid, validationErr = pcall(PokemonCareAssetSchema.assertTradeManifest, manifest)
    if not valid then
      sourceError("compiled trade manifest is invalid", { cause = tostring(validationErr) })
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
