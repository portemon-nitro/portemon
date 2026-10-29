-- Source-backed effect context declarations are normalized by the producer.

local Assert = require("tests.support.Assert")
local T = {}

local function u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32(value)
  return u16(value % 65536) .. u16(math.floor(value / 65536))
end

local function g2dBlock(magic, payload)
  return magic:reverse() .. u32(8 + #payload) .. payload
end

local function g2dContainer(magic, chunks)
  local body = table.concat(chunks)
  return magic .. "\255\254" .. u16(0x0100) .. u32(0x10 + #body) .. u16(0x10) .. u16(#chunks) .. body
end

local function trainerMappingCell()
  local object = u16(0x00D8) .. u16(0x01D8) .. u16(32)
  local cell = u16(1) .. u16(0) .. u32(0x18) .. u32(1) .. string.rep("\0", 12) .. u16(1) .. u16(0) .. u32(0) .. object
  return g2dContainer("RECN", { g2dBlock("CEBK", cell) })
end

local function trainerMappingAnimation()
  local header = u16(1) .. u16(1) .. u32(0x18) .. u32(0x28) .. u32(0x30) .. string.rep("\0", 8)
  local animation = u32(1) .. u16(0) .. u16(1) .. u32(1) .. u32(0)
  local frame = u32(0) .. u16(1) .. u16(0) .. u16(0)
  return g2dContainer("RNAN", { g2dBlock("ABNK", header .. animation .. frame) })
end

local function trainerTwoFrameCells()
  local first = u16(0x00D8) .. u16(0x01D8) .. u16(32)
  local second = u16(0x00D8) .. u16(0x01E8) .. u16(0)
  local cell = u16(3)
    .. u16(0)
    .. u32(0x18)
    .. u32(1)
    .. u32(0)
    .. string.rep("\0", 8)
    .. u16(1)
    .. u16(0)
    .. u32(0)
    .. u16(1)
    .. u16(0)
    .. u32(6)
    .. u16(0)
    .. u16(0)
    .. u32(12)
    .. first
    .. second
  return g2dContainer("RECN", { g2dBlock("CEBK", cell) })
end

local function trainerTwoFrameAnimation()
  local header = u16(1) .. u16(2) .. u32(0x18) .. u32(0x28) .. u32(0x38) .. string.rep("\0", 8)
  local animation = u16(2) .. u16(0) .. u32(0x00010000) .. u32(2) .. u32(0)
  local frames = u32(0) .. u16(2) .. u16(0) .. u32(2) .. u16(5) .. u16(0)
  local frameData = u16(0) .. u16(1)
  return g2dContainer("RNAN", { g2dBlock("ABNK", header .. animation .. frames .. frameData) })
end

local function trainerSourceSequencesAnimation()
  local extensionOffset = 0xC0
  local header = u16(3) .. u16(10) .. u32(0x18) .. u32(0x48) .. u32(0x98) .. u32(0) .. u32(extensionOffset)
  local sequenceZero = u16(2) .. u16(0) .. u32(0x00010000) .. u32(2) .. u32(0)
  local sequenceOne = u16(6) .. u16(0) .. u32(0x00010000) .. u32(2) .. u32(16)
  local sequenceTwo = u16(2) .. u16(0) .. u32(0x00010000) .. u32(1) .. u32(64)
  local frames = {}
  local durations = { 2, 5, 3, 4, 5, 6, 7, 8, 9, 10 }
  for frameIndex, duration in ipairs(durations) do
    frames[#frames + 1] = u32((frameIndex - 1) * 4) .. u16(duration) .. u16(0)
  end
  local frameData = {}
  for frameIndex = 1, #durations do
    local cell = (frameIndex == 3 or frameIndex == 9) and 2 or (frameIndex - 1) % 2
    frameData[#frameData + 1] = u16(cell) .. u16(0)
  end
  local attributeValues = { 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 }
  local firstAttributeOffset = 96
  local frameAttributePointers = {}
  for frameIndex = 0, #attributeValues - 1 do
    frameAttributePointers[#frameAttributePointers + 1] = u32(firstAttributeOffset + frameIndex * 4)
  end
  local userAttributes = {}
  for _, value in ipairs(attributeValues) do
    userAttributes[#userAttributes + 1] = u32(value)
  end
  local bank = u16(3)
    .. u16(1)
    .. u32(8)
    .. u16(2)
    .. u16(0)
    .. u32(44)
    .. u32(56)
    .. u16(6)
    .. u16(0)
    .. u32(48)
    .. u32(64)
    .. u16(2)
    .. u16(0)
    .. u32(52)
    .. u32(88)
    .. u32(0)
    .. u32(0)
    .. u32(0)
    .. table.concat(frameAttributePointers)
    .. table.concat(userAttributes)
  local extension = u32(0x55414154) .. u32(8 + #bank) .. bank
  return g2dContainer("RNAN", {
    g2dBlock(
      "ABNK",
      header
        .. sequenceZero
        .. sequenceOne
        .. sequenceTwo
        .. table.concat(frames)
        .. table.concat(frameData)
        .. extension
    ),
  })
end

local function trainerMappingCharacters()
  local bytes = {}
  for tile = 0, 64 do
    local nibble = tile == 32 and 1 or (tile == 64 and 2 or 0)
    bytes[#bytes + 1] = string.rep(string.char(nibble * 17), 32)
  end
  local tiles = table.concat(bytes)
  local payload = u16(8) .. u16(0x20) .. u32(3) .. u16(0) .. u16(0) .. u32(0) .. u32(#tiles) .. u32(0x18) .. tiles
  return g2dContainer("RGCN", { g2dBlock("CHAR", payload) })
end

local function trainerMappingPalette()
  local colors = u16(0) .. u16(31) .. u16(31 * 32)
  local payload = string.char(3, 0) .. u16(3) .. u32(0) .. u32(12) .. colors
  return g2dContainer("NCLR", { g2dBlock("PLTT", payload) })
end

function T.trainer_picture_rasterizer_uses_the_cell_bank_mapping()
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local sources = require("romdump.src.config.BattlePresentationSources")
  local trainerPictures = sources.TRAINER_PICTURES
  local previousFrontClasses = trainerPictures.frontClasses
  local previousBackClasses = trainerPictures.backClasses
  trainerPictures.frontClasses = {}
  trainerPictures.backClasses = { PKMN_TRAINER_ETHAN = 0 }
  local members = {
    ["NARC_a_0_0_6:0"] = trainerMappingCharacters(),
    ["NARC_a_0_0_6:1"] = trainerMappingPalette(),
    ["NARC_a_0_0_6:2"] = trainerMappingCell(),
    ["NARC_a_0_0_6:3"] = trainerMappingAnimation(),
  }
  local romFs = {
    openNarc = function(_, archiveName)
      return {
        readMember = function(_, memberId)
          return members[archiveName .. ":" .. memberId]
        end,
      }
    end,
  }
  local ok, entries, slices = pcall(compiler.compileTrainerPictures, romFs)
  trainerPictures.frontClasses = previousFrontClasses
  trainerPictures.backClasses = previousBackClasses
  Assert.isTrue(ok, "synthetic mapping-1 trainer resources compile: " .. tostring(entries))
  local raster = assert(slices["trainer-back-PKMN_TRAINER_ETHAN"])
  local red, green, blue, alpha = string.byte(raster.pixels, 1, 4)
  Assert.deepEqual({ red, green, blue, alpha }, { 0, 255, 0, 255 }, "tile 32 samples character tile 64 in mapping 1")
  Assert.equal(entries["back:PKMN_TRAINER_ETHAN"].width, 8)
  Assert.deepEqual(entries["back:PKMN_TRAINER_ETHAN"].rasterOffset, { x = -40, y = -40 })
end

function T.trainer_picture_compilation_preserves_each_source_animation_frame()
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local sources = require("romdump.src.config.BattlePresentationSources")
  local trainerPictures = sources.TRAINER_PICTURES
  local previousFrontClasses = trainerPictures.frontClasses
  local previousBackClasses = trainerPictures.backClasses
  trainerPictures.frontClasses = {}
  trainerPictures.backClasses = { PKMN_TRAINER_ETHAN = 0 }
  local members = {
    ["NARC_a_0_0_6:0"] = trainerMappingCharacters(),
    ["NARC_a_0_0_6:1"] = trainerMappingPalette(),
    ["NARC_a_0_0_6:2"] = trainerTwoFrameCells(),
    ["NARC_a_0_0_6:3"] = trainerSourceSequencesAnimation(),
  }
  local romFs = {
    openNarc = function(_, archiveName)
      return {
        readMember = function(_, memberId)
          return members[archiveName .. ":" .. memberId]
        end,
      }
    end,
  }

  local ok, entries, slices = pcall(compiler.compileTrainerPictures, romFs)
  trainerPictures.frontClasses = previousFrontClasses
  trainerPictures.backClasses = previousBackClasses
  Assert.isTrue(ok, "source-shaped two-frame trainer resources compile: " .. tostring(entries))
  local entry = assert(entries["back:PKMN_TRAINER_ETHAN"])
  local frames =
    assert(entry.animation and entry.animation.frames, "the compiled trainer publishes its source sequence")
  Assert.equal(#frames, 2, "every source frame is retained in order")
  Assert.equal(frames[1].sourceFrame, 0, "the first frame keeps its zero-based source index")
  Assert.equal(frames[1].durationTicks, 2, "the first frame keeps its source tick duration")
  Assert.equal(frames[2].sourceFrame, 1, "the second frame keeps its zero-based source index")
  Assert.equal(frames[2].durationTicks, 5, "the second frame keeps its source tick duration")
  Assert.deepEqual(frames[1].rasterOffset, entry.rasterOffset, "the legacy image fields still describe frame zero")
  Assert.equal(frames[1].drawableKey, entry.drawableKey, "the legacy drawable key still resolves frame zero")
  Assert.equal(frames[1].image, entry.image, "the legacy image path still resolves frame zero")
  Assert.isFalse(frames[1].image == frames[2].image, "visibly different frames receive distinct image paths")
  Assert.deepEqual(frames[2].rasterOffset, { x = -24, y = -40 }, "the next cell keeps its source raster origin")
  local animation = assert(entry.animation)
  Assert.equal(animation.sourceSequence, 0, "the compatibility frame list identifies source sequence zero")
  Assert.equal(animation.playMode, "forward_loop", "sequence zero keeps its source playback mode")
  Assert.equal(animation.loopStartFrameIdx, 0, "sequence zero keeps its source loop start")
  local sequences = assert(animation.sequences)
  Assert.equal(#sequences, 3, "all source animation sequences are staged")
  Assert.equal(sequences[1].sourceSequence, 0, "the first descriptor keeps source sequence zero")
  Assert.equal(sequences[2].sourceSequence, 1, "the throw descriptor keeps source sequence one")
  Assert.equal(#sequences[2].frames, 6, "throw anchors address every staged source frame")
  Assert.equal(sequences[2].frames[4].durationTicks, 6, "the throw sequence retains source frame duration")
  Assert.equal(sequences[2].frames[4].userAttr, 1, "the throw frame retains its source UAAT user attribute")
  Assert.equal(sequences[2].frames[1].durationTicks, 3, "an objectless source frame retains its timing")
  Assert.equal(
    sequences[2].frames[1].drawableKey,
    entry.drawableKey .. ":sequence:1:frame:0",
    "additional source sequences have stable selector-scoped frame keys"
  )
  Assert.equal(sequences[3].sourceSequence, 2, "the entry descriptor keeps source sequence two")
  Assert.equal(#sequences[3].frames, 2, "the entry sequence retains its source frames")
  Assert.equal(sequences[3].frames[1].userAttr, 0, "UAAT attributes remain sequence-scoped")
  Assert.equal(sequences[3].frames[1].durationTicks, 9, "entry blanking frames retain their source timing")
  for _, frame in ipairs({ sequences[2].frames[1], sequences[3].frames[1] }) do
    Assert.deepEqual(frame.rasterOffset, { x = 0, y = 0 }, "objectless cells have no geometric origin")
    local imageName = assert(frame.image:match("([^/]+)%.png$"))
    local transparent = assert(slices[imageName])
    Assert.deepEqual({ transparent.width, transparent.height, transparent.pixels }, { 1, 1, string.rep("\0", 4) })
  end
  Assert.equal(
    sequences[3].frames[1].drawableKey,
    entry.drawableKey .. ":sequence:2:frame:0",
    "entry frames keep their source sequence identity"
  )
  local firstName = assert(frames[1].image:match("([^/]+)%.png$"))
  local secondName = assert(frames[2].image:match("([^/]+)%.png$"))
  local first = assert(slices[firstName])
  local second = assert(slices[secondName])
  Assert.isFalse(first.pixels == second.pixels, "the distinct source cells retain distinct decoded pixels")
end

function T.move_power_callback_declares_its_event_time_context()
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local sources = require("romdump.src.config.BattleAnimationSources")
  local route = assert(sources.resolveSemanticRoute("TACKLE"))
  local plan = assert(sources.resolveBattleAnimationCallback({ 28, 0 }))
  local previous = package.loaded["romdump.src.digest.battle.BattleAnimationCompiler"]
  package.loaded["romdump.src.digest.battle.BattleAnimationCompiler"] = {
    compile = function()
      return {
        entry = "main",
        instructions = {
          {
            op = "invoke-battle-animation-callback",
            callback = plan.callback,
            taskKind = plan.taskKind,
            taskContext = plan.context,
            parameters = plan.parameters,
          },
        },
        subprograms = {},
        taskKinds = { plan.taskKind },
      }
    end,
  }
  local romFs = {
    version = function()
      return "heartgold"
    end,
    metadata = function()
      return { sha1 = string.rep("a", 40) }
    end,
    openNarc = function(_, archiveSymbol)
      Assert.equal(archiveSymbol, route.archiveSymbol)
      return {
        readMember = function(_, memberId)
          Assert.equal(memberId, route.memberId)
          return "source bytes are supplied to the normalized compiler"
        end,
      }
    end,
  }

  local ok, effect, err = pcall(compiler.compileEffect, romFs, { versionId = "heartgold" }, "TACKLE")
  package.loaded["romdump.src.digest.battle.BattleAnimationCompiler"] = previous

  Assert.isTrue(ok, "producer compiles the source-normalized callback: " .. tostring(effect))
  Assert.notNil(effect, "effect contains the callback requiring event-time move power: " .. tostring(err))
  Assert.isNil(err)
  Assert.deepEqual(effect.requiredContext.movePower, { type = "battle-animation-move-power-u16" })
  Assert.deepEqual(effect.requiredContext.battlerTopology, { type = "battle-animation-battler-topology" })
  Assert.isNil(effect.requiredContext.movePower.value, "producer declares the event-time type, not a guessed value")
end

function T.picture_offset_callback_declares_battler_topology()
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local sources = require("romdump.src.config.BattleAnimationSources")
  local effectKey = "BATTLE_ANIMATION_HAPPY"
  local route = assert(sources.resolveSemanticRoute(effectKey))
  local plan = assert(sources.resolveBattleAnimationCallback({ 57, 4, 4, 0, 8, 264 }))
  local previous = package.loaded["romdump.src.digest.battle.BattleAnimationCompiler"]
  package.loaded["romdump.src.digest.battle.BattleAnimationCompiler"] = {
    compile = function()
      return {
        entry = "main",
        instructions = {
          {
            op = "invoke-battle-animation-callback",
            callback = plan.callback,
            taskKind = plan.taskKind,
            taskContext = plan.context,
            parameters = plan.parameters,
          },
        },
        subprograms = {},
        taskKinds = { plan.taskKind },
      }
    end,
  }
  local romFs = {
    version = function()
      return "heartgold"
    end,
    metadata = function()
      return { sha1 = string.rep("a", 40) }
    end,
    openNarc = function(_, archiveSymbol)
      Assert.equal(archiveSymbol, route.archiveSymbol)
      return {
        readMember = function(_, memberId)
          Assert.equal(memberId, route.memberId)
          return "source bytes are supplied to the normalized compiler"
        end,
      }
    end,
  }

  local ok, effect, err = pcall(compiler.compileEffect, romFs, { versionId = "heartgold" }, effectKey)
  package.loaded["romdump.src.digest.battle.BattleAnimationCompiler"] = previous

  Assert.isTrue(ok, "producer compiles the source-normalized callback: " .. tostring(effect))
  Assert.notNil(effect, "effect carries the target picture callback: " .. tostring(err))
  Assert.isNil(err)
  Assert.deepEqual(effect.requiredContext.battlerTopology, { type = "battle-animation-battler-topology" })
end

function T.native_shadow_compiler_extracts_the_four_selected_source_rectangles()
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local bit = require("bit")
  local surface = {}
  for y = 0, 79 do
    local value = y < 16 and 0x11 or y < 32 and 0x22 or y < 48 and 0x33 or 0x44
    for x = 0, 79 do
      surface[y * 80 + x + 1] = x < 40 and value or 0x55
    end
  end
  surface[1], surface[2] = 0, 0
  local scanned = {}
  local seed = 0x1234
  for wordOffset = 0, 3199 do
    local plain = surface[wordOffset * 2 + 1] + surface[wordOffset * 2 + 2] * 256
    local encoded = bit.bxor(plain, seed % 65536)
    scanned[#scanned + 1] = string.char(encoded % 256, math.floor(encoded / 256))
    local low, high = seed % 65536, math.floor(seed / 65536)
    local lowProduct = low * 20077 + 24691
    local highProduct = (low * 16838 + high * 20077 + math.floor(lowProduct / 65536)) % 65536
    seed = lowProduct % 65536 + highProduct * 65536
  end
  local palette = { colors = {} }
  for index = 0, 15 do
    palette.colors[index + 1] = { r = index * 10, g = 0, b = 0 }
  end
  local image = compiler.compileShadowImage({ depth = 3, tiles = table.concat(scanned) }, palette)

  Assert.equal(image.width, 64, "shadow metadata keeps the native 64-pixel width")
  Assert.equal(image.height, 64, "four native shadow-size regions are staged vertically")
  local function pixel(x, y)
    local offset = (y * image.width + x) * 4 + 1
    return {
      string.byte(image.pixels, offset),
      string.byte(image.pixels, offset + 1),
      string.byte(image.pixels, offset + 2),
      string.byte(image.pixels, offset + 3),
    }
  end
  Assert.deepEqual(pixel(4, 0), { 10, 0, 0, 255 }, "size zero reads the copied first shadow rows")
  Assert.deepEqual(pixel(4, 16), { 10, 0, 0, 255 }, "size one aliases the source size-zero rectangle")
  Assert.deepEqual(pixel(4, 32), { 20, 0, 0, 255 }, "size two selects the next native atlas rows")
  Assert.deepEqual(pixel(4, 48), { 30, 0, 0, 255 }, "size three selects the final native atlas rows")
end

function T.native_menu_feedback_patch_uses_source_tile_offset_inside_source_bounds()
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local charBytes = {}
  for tile = 0, 399 do
    for _ = 1, 32 do
      charBytes[#charBytes + 1] = string.char(tile % 16 + math.floor(tile % 16) * 16)
    end
  end
  local colors = {}
  for index = 0, 15 do
    colors[index + 1] = { r = index * 10, g = 0, b = 0 }
  end
  local screen = { width = 256, height = 256, entries = {} }
  for index = 1, 32 * 32 do
    screen.entries[index] = { tile = 1, palette = 0, flipH = false, flipV = false }
  end
  local patch = compiler.compileMenuFeedbackPatch(
    { depth = 3, tiles = table.concat(charBytes) },
    { colors = colors },
    screen,
    { left = 2, top = 4, right = 3, bottom = 4, offset = 192 }
  )

  Assert.equal(patch.width, 16, "feedback patch width follows the inclusive source tile rectangle")
  Assert.equal(patch.height, 8, "feedback patch height follows the inclusive source tile rectangle")
  Assert.equal(string.byte(patch.pixels, 1), 10, "the source tile offset selects the expected tile art")
  Assert.equal(string.byte(patch.pixels, 4), 255, "nonzero source tile pixels remain opaque")
end

function T.previously_waived_move_closes_through_its_selected_source_member()
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local sources = require("romdump.src.config.BattleAnimationSources")
  local effectKey = "CHARGE"
  local route = assert(sources.resolveSemanticRoute(effectKey))
  local plan = assert(sources.resolveBattleAnimationCallback({ 28, 0 }))
  local previous = package.loaded["romdump.src.digest.battle.BattleAnimationCompiler"]
  package.loaded["romdump.src.digest.battle.BattleAnimationCompiler"] = {
    compile = function()
      return {
        entry = "main",
        instructions = {
          {
            op = "invoke-battle-animation-callback",
            callback = plan.callback,
            taskKind = plan.taskKind,
            taskContext = plan.context,
            parameters = plan.parameters,
          },
        },
        subprograms = {},
        taskKinds = { plan.taskKind },
      }
    end,
  }
  local romFs = {
    version = function()
      return "heartgold"
    end,
    metadata = function()
      return { sha1 = string.rep("a", 40) }
    end,
    openNarc = function(_, archiveSymbol)
      Assert.equal(archiveSymbol, route.archiveSymbol)
      return {
        readMember = function(_, memberId)
          Assert.equal(memberId, route.memberId)
          return "source bytes are supplied to the normalized compiler"
        end,
      }
    end,
  }

  local ok, effect, err = pcall(compiler.compileEffect, romFs, { versionId = "heartgold" }, effectKey)
  package.loaded["romdump.src.digest.battle.BattleAnimationCompiler"] = previous

  Assert.isTrue(ok, "producer compiles the selected source member: " .. tostring(effect))
  Assert.notNil(effect, "a routed move closes instead of reporting an unavailable route: " .. tostring(err))
  Assert.isNil(err)
  Assert.equal(effect.key, effectKey)
  Assert.equal(effect.provenance.archiveSymbol, route.archiveSymbol)
  Assert.equal(effect.provenance.memberId, route.memberId)
end

local Errors = require("libs.errors.src.Errors")

local function u16le(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32le(value)
  return u16le(value % 65536) .. u16le(math.floor(value / 65536))
end

local function apsMember(emitterRecords, resourceRecords)
  return " APS12_1"
    .. u16le(#emitterRecords)
    .. u16le(#resourceRecords)
    .. string.rep("\0", 0x20 - 0x0c)
    .. table.concat(emitterRecords)
    .. table.concat(resourceRecords)
end

-- Optional emitter section sizes in flag-bit order, matching the container
-- decoder so synthetic members stay well-formed while the producer decides
-- which traits normalize and which fail the build.
local SECTION_SIZES_IN_FLAG_ORDER = {
  { bit = 8, size = 0x0c },
  { bit = 9, size = 0x0c },
  { bit = 10, size = 0x08 },
  { bit = 11, size = 0x0c },
  { bit = 16, size = 0x14 },
  { bit = 24, size = 0x08 },
  { bit = 25, size = 0x08 },
  { bit = 26, size = 0x10 },
  { bit = 27, size = 0x04 },
  { bit = 28, size = 0x08 },
  { bit = 29, size = 0x10 },
}

local function apsEmitter(flags)
  local parts = { u32le(flags), string.rep("\1", 0x58 - 4) }
  for _, section in ipairs(SECTION_SIZES_IN_FLAG_ORDER) do
    if math.floor(flags / 2 ^ section.bit) % 2 == 1 then
      parts[#parts + 1] = string.rep("\2", section.size)
    end
  end
  return table.concat(parts)
end

local function apsResource(texture, palette, textureReference)
  texture = texture or string.rep("\3", 16)
  palette = palette or string.rep("\4", 8)
  local descriptorFlags = 0
  if textureReference ~= nil then
    descriptorFlags = 2 ^ 17 + textureReference * 2 ^ 18
    texture = ""
  end
  local paletteOffset = 0x20 + #texture
  local resourceSize = 0x20 + #texture + #palette
  return u32le(0)
    .. u32le(descriptorFlags)
    .. u32le(#texture)
    .. u32le(paletteOffset)
    .. u32le(#palette)
    .. u32le(0)
    .. u32le(0)
    .. u32le(resourceSize)
    .. texture
    .. palette
end

-- Compiles one effect through the real producer while the inner command
-- lowering is stubbed: the route stream and particle members come from the
-- synthetic bundle, so only emitter normalization and texture staging are
-- exercised. Returns the raw pcall outcome so failure tests can inspect it.
local function compileParticleEffect(effectKey, particleBlobs, particleInstructions)
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local sources = require("romdump.src.config.BattleAnimationSources")
  local route = assert(sources.resolveSemanticRoute(effectKey), "the probed effect keeps its source route")
  local romFs = {
    version = function()
      return "heartgold"
    end,
    metadata = function()
      return { sha1 = string.rep("a", 40) }
    end,
    openNarc = function(_, archiveSymbol)
      if archiveSymbol == route.archiveSymbol then
        return {
          readMember = function()
            return "particle-route-stream-is-lowered-by-the-stub"
          end,
        }
      end
      return {
        readMember = function(_, memberId)
          local blob = particleBlobs[memberId]
          if blob ~= nil then
            return blob
          end
          return nil, "particle member " .. tostring(memberId) .. " is not part of this synthetic bundle"
        end,
      }
    end,
  }
  local moduleName = "romdump.src.digest.battle.BattleAnimationCompiler"
  local previous = package.loaded[moduleName]
  package.loaded[moduleName] = {
    compile = function(arguments)
      Assert.equal(arguments.key, effectKey, "the stubbed lowering sees the probed effect key")
      Assert.equal(type(arguments.stream), "string", "the stubbed lowering sees the route stream")
      Assert.equal(type(arguments.resolveSourceInput), "function", "the stubbed lowering sees the source resolver")
      return {
        entry = "main",
        instructions = particleInstructions,
        subprograms = {},
        taskKinds = { "battler-effect-continuation" },
      }
    end,
  }
  local outcome = { pcall(compiler.compileEffect, romFs, { versionId = "heartgold" }, effectKey) }
  package.loaded[moduleName] = previous
  return outcome
end

local function assertProducerEffect(outcome, what)
  Assert.isTrue(outcome[1] == true, what .. " compiles through the producer: " .. tostring(outcome[2]))
  Assert.notNil(outcome[2], what .. " stages an effect record")
  return outcome[2]
end

local function assertProducerFailure(outcome, what)
  if outcome[1] == true then
    Assert.isNil(outcome[2], what .. " stages no effect")
    Assert.isTrue(Errors.is(outcome[3]), what .. " fails as a structured producer error")
  else
    Assert.isTrue(Errors.is(outcome[2]), what .. " fails as a structured producer error: " .. tostring(outcome[2]))
  end
end

local function particleInstructionsFor(resourceKey)
  return {
    {
      op = "create-battler-effect",
      resource = resourceKey,
      emitterPosition = "solo-enemy",
      taskKind = "battler-effect-continuation",
    },
  }
end

local function texturedEmitterFlags()
  return 0x200 + 0x800 + 0x1000000 + 0x2000000
end

local function assertExactDrawable(bundle, resourceKey, what)
  local descriptor = bundle.resources[resourceKey]
  Assert.notNil(descriptor, what .. " stages its texture resource")
  Assert.equal(descriptor.kind, "texture", what .. " keeps the texture resource kind")
  local texture = bundle.resourcePayloads[descriptor.payload]
  Assert.equal(type(texture), "table", what .. " stages its texture payload as a record")
  Assert.isTrue(
    type(texture.width) == "number" and texture.width % 1 == 0 and texture.width > 0,
    what .. " declares a positive pixel width"
  )
  Assert.isTrue(
    type(texture.height) == "number" and texture.height % 1 == 0 and texture.height > 0,
    what .. " declares a positive pixel height"
  )
  Assert.equal(type(texture.rgba8888), "string", what .. " stages decoded pixel bytes")
  Assert.equal(
    #texture.rgba8888,
    texture.width * texture.height * 4,
    what .. " carries exactly one RGBA quadruple per pixel"
  )
  return texture
end

function T.particle_emitters_stage_without_opaque_source_words_and_with_exact_drawable_textures()
  local tackle = "battle/particle/tackle"
  local blob = apsMember({ apsEmitter(texturedEmitterFlags()) }, { apsResource() })
  local effect = assertProducerEffect(
    compileParticleEffect("TACKLE", { [64] = blob }, particleInstructionsFor(tackle)),
    "the textured particle archive"
  )
  local descriptor = effect.resources[tackle]
  Assert.notNil(descriptor, "the compiled effect stages its selected particle archive")
  Assert.equal(descriptor.kind, "particle", "the particle archive keeps its resource kind")
  local payload = effect.resourcePayloads[descriptor.payload]
  Assert.equal(type(payload), "table", "the staged particle payload is a record")
  local emitters = payload.emitters
  Assert.equal(type(emitters), "table", "the staged particle payload carries emitter state")
  Assert.isTrue(#emitters >= 1, "the staged particle payload carries at least one emitter")
  for index, emitter in ipairs(emitters) do
    Assert.isNil(emitter.baseRecord, "emitter " .. index .. " carries no opaque source base record")
    Assert.isNil(emitter.sections, "emitter " .. index .. " carries no opaque source sections")
    Assert.isNil(emitter.calculations, "emitter " .. index .. " carries no opaque source calculations")
    Assert.isTrue(type(emitter.flags) ~= "number", "emitter " .. index .. " carries no raw source flag word")
  end
  local textureCount = 0
  for key, resource in pairs(effect.resources) do
    if resource.kind == "texture" then
      textureCount = textureCount + 1
      assertExactDrawable(effect, key, "staged texture " .. key)
    end
  end
  Assert.isTrue(textureCount >= 1, "the embedded source texture stages at least one drawable")
end

local function textureLink(entry)
  if type(entry.textureKey) == "string" then
    return entry.textureKey
  end
  if type(entry.assetKey) == "string" then
    return entry.assetKey
  end
  return nil
end

function T.shared_particle_textures_stage_once_and_resolve_every_reference()
  local tackle = "battle/particle/tackle"
  local firstPalette = string.rep("\4", 8)
  local secondPalette = string.rep("\5", 8)
  local blob = apsMember({ apsEmitter(texturedEmitterFlags()) }, {
    apsResource(nil, firstPalette),
    apsResource(nil, secondPalette, 0),
  })
  local effect = assertProducerEffect(
    compileParticleEffect("TACKLE", { [64] = blob }, particleInstructionsFor(tackle)),
    "the texture-sharing particle archive"
  )
  local payload = effect.resourcePayloads[assert(effect.resources[tackle], "the particle archive is staged").payload]
  Assert.equal(type(payload.resources), "table", "the staged particle payload keeps its resource table")
  Assert.equal(#payload.resources, 2, "both source resources normalize")
  local firstLink = textureLink(payload.resources[1])
  local secondLink = textureLink(payload.resources[2])
  Assert.notNil(firstLink, "the embedded texture names its staged drawable")
  Assert.equal(secondLink, firstLink, "the shared texture reference resolves to the one staged drawable")
  local textureCount = 0
  local paletteCount = 0
  for key, resource in pairs(effect.resources) do
    if resource.kind == "texture" then
      textureCount = textureCount + 1
      assertExactDrawable(effect, key, "shared texture " .. key)
    elseif resource.kind == "palette" then
      paletteCount = paletteCount + 1
    end
  end
  Assert.equal(textureCount, 1, "the shared texture uploads exactly once")
  Assert.equal(paletteCount, 2, "each distinct source palette stages its own payload")
end

local Rgb555 = require("libs.codec.src.Rgb555")
local G2dBankFixture = require("tests.support.G2dBankFixture")

-- A minimal 4bpp NCGR container with caller-chosen tile bytes, mirroring
-- the Nitro character layout the producer decoder reads: depth word at
-- payload +4, tile byte count at +0x10, and the tile run at +0x18.
local function charBank(tileBytes)
  local payload = string.rep("\0", 4)
    .. u32le(3)
    .. string.rep("\0", 8)
    .. u32le(#tileBytes)
    .. u32le(0x18)
    .. tileBytes
  local blockPayload = "RAHC" .. u32le(8 + #payload) .. payload
  local size = 0x10 + #blockPayload
  return "RGCN" .. string.char(0xff, 0xfe) .. u16le(0x0100) .. u32le(size) .. u16le(0x10) .. u16le(1) .. blockPayload
end

-- A minimal NCLR container with caller-chosen RGB555 words, mirroring the
-- retail NNS palette layout the producer decoder reads: the RLCN header
-- names one TTLP chunk, and the TTLP chunk carries the depth word, the
-- color byte count, and the color run at its +0x18 data offset.
local function paletteBank(words)
  local data = {}
  for _, word in ipairs(words) do
    data[#data + 1] = u16le(word)
  end
  local colors = table.concat(data)
  local ttlp = "TTLP"
    .. u32le(8 + 0x18 + #colors)
    .. u32le(3)
    .. u32le(0)
    .. u32le(#colors)
    .. u32le(0x18)
    .. string.rep("\0", 8)
    .. colors
  local size = 0x10 + #ttlp
  return "RLCN" .. string.char(0xff, 0xfe) .. u16le(0x0100) .. u32le(size) .. u16le(0x10) .. u16le(1) .. ttlp
end

-- Compiles one effect whose command lowering is stubbed but whose source
-- resolution stays real: the route stream and the listed NARC members
-- come from the synthetic bundle, so only managed-sprite staging is
-- exercised. Returns the raw pcall outcome so failure tests can inspect it.
local function compileManagedSpriteEffect(effectKey, members, buildInstructions)
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local sources = require("romdump.src.config.BattleAnimationSources")
  local route = assert(sources.resolveSemanticRoute(effectKey), "the probed effect keeps its source route")
  local romFs = {
    version = function()
      return "heartgold"
    end,
    metadata = function()
      return { sha1 = string.rep("a", 40) }
    end,
    openNarc = function(_, archiveSymbol)
      if archiveSymbol == route.archiveSymbol then
        return {
          readMember = function()
            return "managed-sprite-route-stream-is-lowered-by-the-stub"
          end,
        }
      end
      local archiveMembers = members[archiveSymbol]
      if archiveMembers == nil then
        return nil, "archive " .. tostring(archiveSymbol) .. " is not part of this synthetic bundle"
      end
      return {
        readMember = function(_, memberId)
          local blob = archiveMembers[memberId]
          if blob ~= nil then
            return blob
          end
          return nil, "member " .. tostring(memberId) .. " is not part of this synthetic bundle"
        end,
      }
    end,
  }
  local moduleName = "romdump.src.digest.battle.BattleAnimationCompiler"
  local previous = package.loaded[moduleName]
  package.loaded[moduleName] = {
    compile = function(arguments)
      Assert.equal(arguments.key, effectKey, "the stubbed lowering sees the probed effect key")
      Assert.equal(type(arguments.resolveSourceInput), "function", "the stubbed lowering sees the source resolver")
      return {
        entry = "main",
        instructions = buildInstructions(arguments.resolveSourceInput),
        subprograms = {},
        taskKinds = { "managed-sprite-draw-loop" },
      }
    end,
  }
  local outcome = { pcall(compiler.compileEffect, romFs, { versionId = "heartgold" }, effectKey) }
  package.loaded[moduleName] = previous
  return outcome
end

-- Every staged texture of the compiled effect must be an exact RGBA
-- drawable: the live image upload path admits no other texture shape.
local function assertAllTexturesAreExactDrawables(effect, what)
  local textureCount = 0
  for key in pairs(effect.resources) do
    if effect.resources[key].kind == "texture" then
      textureCount = textureCount + 1
      assertExactDrawable(effect, key, what .. " staged texture " .. key)
    end
  end
  Assert.isTrue(textureCount >= 1, what .. " stages at least one texture")
end

function T.managed_sprite_resource_set_stages_its_character_as_an_exact_drawable()
  local tileBytes = string.rep("\0", 32) .. string.rep(string.char(0x21), 32)
  local words = { Rgb555.encode(0, 0, 0) }
  for _ = 2, 16 do
    words[#words + 1] = Rgb555.encode(0, 0, 0)
  end
  words[2] = Rgb555.encode(31, 0, 0)
  words[3] = Rgb555.encode(0, 31, 0)
  local members = {
    ["NARC_a_0_0_8"] = {
      [75] = paletteBank(words),
      [76] = charBank(tileBytes),
      [77] = G2dBankFixture.cellBank({ { { x = 0, y = 0, tile = 0, pal = 0 } } }),
      [78] = G2dBankFixture.animBank({ 0 }),
    },
  }
  local effect = assertProducerEffect(
    compileManagedSpriteEffect("TACKLE", members, function(resolveSourceInput)
      local resolved = resolveSourceInput("managed-sprite-resource-set", { 0 })
      return {
        {
          op = "load-managed-sprite-resources",
          resourceKeys = resolved.resourceKeys,
          runtimeSelection = resolved.runtimeSelection,
        },
      }
    end),
    "the co-selected managed sprite quartet"
  )
  assertAllTexturesAreExactDrawables(effect, "the co-selected managed sprite quartet")
  local characterKey = nil
  for key in pairs(effect.resources) do
    if key:find("managed%-sprite%-resource%-set/character/", 1) ~= nil then
      characterKey = key
    end
  end
  Assert.notNil(characterKey, "the quartet stages its character key")
  local drawable = assertExactDrawable(effect, characterKey, "the staged managed sprite character")
  Assert.equal(drawable.width, 16, "two source tiles stage one 16-pixel row")
  Assert.equal(drawable.height, 8, "the tile strip is one tile tall")
  local function pixel(x, y)
    local offset = (y * drawable.width + x) * 4 + 1
    return {
      string.byte(drawable.rgba8888, offset),
      string.byte(drawable.rgba8888, offset + 1),
      string.byte(drawable.rgba8888, offset + 2),
      string.byte(drawable.rgba8888, offset + 3),
    }
  end
  Assert.deepEqual(pixel(0, 0), { 0, 0, 0, 0 }, "a zero source pixel stays transparent")
  Assert.deepEqual(pixel(8, 0), { 255, 0, 0, 255 }, "a nonzero nibble reads its paired palette entry")
  Assert.deepEqual(pixel(9, 0), { 0, 255, 0, 255 }, "the high nibble reads its own paired palette entry")
end

function T.lone_sprite_character_stages_exact_rgba_through_its_template_palette()
  local tileBytes = string.rep(string.char(0x21), 32)
  local words = { Rgb555.encode(0, 0, 0), Rgb555.encode(31, 0, 0) }
  for _ = 3, 16 do
    words[#words + 1] = Rgb555.encode(0, 0, 0)
  end
  local members = {
    ["NARC_a_0_2_2"] = { [5] = charBank(tileBytes) },
    ["NARC_a_0_2_3"] = { [7] = paletteBank(words) },
    ["NARC_a_0_2_4"] = { [9] = G2dBankFixture.cellBank({ { { x = 0, y = 0, tile = 0, pal = 0 } } }) },
    ["NARC_a_0_2_5"] = { [11] = G2dBankFixture.animBank({ 0 }) },
  }
  local effect = assertProducerEffect(
    compileManagedSpriteEffect("TACKLE", members, function(resolveSourceInput)
      local character = resolveSourceInput("sprite-character", { 0, 5 })
      local palette = resolveSourceInput("sprite-palette", { 0, 7, 0 })
      local cell = resolveSourceInput("sprite-cell", { 0, 9 })
      local animation = resolveSourceInput("sprite-animation", { 0, 11 })
      local template = resolveSourceInput("managed-sprite-template", { 0, 0, 5, 7, 9, 11, 0xffffffff, 0xffffffff })
      return {
        {
          op = "load-sprite-character",
          values = { 0 },
          resourceKeys = character.resourceKeys,
        },
        {
          op = "load-sprite-palette",
          values = { 0, 0 },
          resourceKeys = palette.resourceKeys,
        },
        {
          op = "load-sprite-cell",
          values = { 0 },
          resourceKeys = cell.resourceKeys,
        },
        {
          op = "load-sprite-animation",
          values = { 0 },
          resourceKeys = animation.resourceKeys,
        },
        {
          op = "create-managed-sprite",
          values = { 0, 0 },
          resourceKeys = template.resourceKeys,
        },
      }
    end),
    "the separately loaded sprite quartet"
  )
  assertAllTexturesAreExactDrawables(effect, "the separately loaded sprite quartet")
  local characterKey = nil
  for key in pairs(effect.resources) do
    if key:find("sprite%-character/character/", 1) ~= nil then
      characterKey = key
    end
  end
  Assert.notNil(characterKey, "the quartet stages its lone character key")
  local drawable = assertExactDrawable(effect, characterKey, "the staged lone sprite character")
  Assert.equal(drawable.width, 8, "one source tile stages one 8-pixel row")
  Assert.equal(drawable.height, 8, "the tile strip is one tile tall")
  local red, green, blue, alpha = string.byte(drawable.rgba8888, 1, 4)
  Assert.deepEqual({ red, green, blue, alpha }, { 255, 0, 0, 255 }, "the lone character reads its template palette")
end

-- A separately loaded sprite palette stages the decoded color records
-- the runtime sprite task consumes: the payload carries its colors
-- field, never a bare color list, so admission never fails on a staged
-- but unreadable palette.
function T.separately_loaded_sprite_palette_stages_decoded_color_records()
  local words = { Rgb555.encode(31, 0, 0) }
  for _ = 2, 16 do
    words[#words + 1] = Rgb555.encode(0, 0, 0)
  end
  local members = {
    ["NARC_a_0_2_3"] = { [7] = paletteBank(words) },
  }
  local effect = assertProducerEffect(
    compileManagedSpriteEffect("TACKLE", members, function(resolveSourceInput)
      local palette = resolveSourceInput("sprite-palette", { 0, 7, 0 })
      return {
        {
          op = "load-sprite-palette",
          values = { 0, 0 },
          resourceKeys = palette.resourceKeys,
        },
      }
    end),
    "the separately loaded sprite palette"
  )
  local paletteKey = nil
  for key, descriptor in pairs(effect.resources) do
    if key:find("sprite%-palette/palette/", 1) ~= nil then
      paletteKey = key
      Assert.equal(descriptor.kind, "palette", "the sprite palette keeps its decoded resource kind")
    end
  end
  Assert.notNil(paletteKey, "the load stages its sprite palette key")
  local payload = effect.resourcePayloads[effect.resources[paletteKey].payload]
  Assert.equal(type(payload), "table", "the sprite palette stages its payload as a record")
  Assert.equal(type(payload.colors), "table", "the sprite palette stages decoded color records")
  Assert.equal(#payload.colors, 16, "the sprite palette stages one full palette")
  Assert.equal(payload.colors[1].r, 255, "the first entry keeps its decoded red channel")
end

function T.unrecognized_emitter_flags_fail_the_effect_without_staging()
  local tackle = "battle/particle/tackle"
  local blob = apsMember({ apsEmitter(2 ^ 31) }, { apsResource() })
  assertProducerFailure(
    compileParticleEffect("TACKLE", { [64] = blob }, particleInstructionsFor(tackle)),
    "an emitter with unrecognized source flags"
  )
end

function T.truncated_particle_members_fail_without_staging()
  local tackle = "battle/particle/tackle"
  local shortResource = u32le(0)
    .. u32le(0)
    .. u32le(4)
    .. u32le(0x24)
    .. u32le(0)
    .. u32le(0)
    .. u32le(0)
    .. u32le(0x23)
    .. "\3\3\3"
  local blob = apsMember({ apsEmitter(texturedEmitterFlags()) }, { shortResource })
  assertProducerFailure(
    compileParticleEffect("TACKLE", { [64] = blob }, particleInstructionsFor(tackle)),
    "a truncated particle member"
  )
end

local function apsFlaggedResource(texture, palette, textureFlags)
  local paletteOffset = 0x20 + #texture
  local resourceSize = 0x20 + #texture + #palette
  return u32le(0)
    .. u32le(textureFlags)
    .. u32le(#texture)
    .. u32le(paletteOffset)
    .. u32le(#palette)
    .. u32le(0)
    .. u32le(0)
    .. u32le(resourceSize)
    .. texture
    .. palette
end

function T.particle_texture_decodes_source_size_codes_to_exact_drawables()
  local tackle = "battle/particle/tackle"
  local blob = apsMember({ apsEmitter(texturedEmitterFlags()) }, {
    apsFlaggedResource(string.rep("\9", 256), string.rep("\7", 8), 0x10116),
  })
  local effect = assertProducerEffect(
    compileParticleEffect("TACKLE", { [64] = blob }, particleInstructionsFor(tackle)),
    "the source-coded particle texture"
  )
  local textureKey = nil
  for key, descriptor in pairs(effect.resources) do
    if descriptor.kind == "texture" then
      textureKey = key
    end
  end
  Assert.notNil(textureKey, "the source-coded texture stages its drawable key")
  local drawable = assertExactDrawable(effect, textureKey, "the source-coded texture")
  Assert.equal(drawable.width, 16, "the size codes select the native texture width")
  Assert.equal(drawable.height, 16, "the size codes select the native texture height")
  local paletteCount = 0
  for _, descriptor in pairs(effect.resources) do
    if descriptor.kind == "palette" then
      paletteCount = paletteCount + 1
      local staged = effect.resourcePayloads[descriptor.payload]
      Assert.equal(#staged.colors, 4, "the staged palette decodes every RGB555 entry")
    end
  end
  Assert.equal(paletteCount, 1, "the source-coded texture stages its own palette")
end

function T.particle_texture_length_mismatch_fails_without_staging()
  local tackle = "battle/particle/tackle"
  local blob = apsMember({ apsEmitter(texturedEmitterFlags()) }, {
    apsFlaggedResource(string.rep("\9", 100), string.rep("\7", 8), 0x10116),
  })
  assertProducerFailure(
    compileParticleEffect("TACKLE", { [64] = blob }, particleInstructionsFor(tackle)),
    "a texture whose length mismatches its size codes"
  )
end

function T.headerless_texture_without_unique_dimensions_fails()
  local tackle = "battle/particle/tackle"
  local blob = apsMember({ apsEmitter(texturedEmitterFlags()) }, {
    apsFlaggedResource(string.rep("\9", 16), string.rep("\7", 4), 0),
  })
  assertProducerFailure(
    compileParticleEffect("TACKLE", { [64] = blob }, particleInstructionsFor(tackle)),
    "a headerless texture with ambiguous dimensions"
  )
end

-- The vanished-picture callback is a direct picture operation, not a
-- scheduled task: the mask selects exact battler sets and the trailing
-- word is the vanished flag.
function T.vanished_picture_callback_sets_exact_targets_and_flag()
  local sources = require("romdump.src.config.BattleAnimationSources")
  local all = assert(sources.resolveBattleAnimationCallback({ 40, 2, 0x40, 1 }))
  Assert.equal(all.op, "set-pokemon-picture-vanished", "the vanished callback lowers as a direct operation")
  Assert.deepEqual(all.pictureSets, { "all-battler-positions" }, "the full mask selects every battler")
  Assert.isTrue(all.vanished == true, "a nonzero trailing word vanishes the pictures")
  local split = assert(sources.resolveBattleAnimationCallback({ 40, 2, 0x02 + 0x08, 0 }))
  Assert.deepEqual(
    split.pictureSets,
    { "active-battler", "opposing-battler" },
    "split mask bits select their own battler sets"
  )
  Assert.isTrue(split.vanished == false, "a zero trailing word restores the pictures")
end

function T.vanished_picture_callback_rejects_malformed_frames()
  local sources = require("romdump.src.config.BattleAnimationSources")
  local truncated, truncatedReason = sources.resolveBattleAnimationCallback({ 40 })
  Assert.isNil(truncated, "a truncated vanished frame resolves to no operation")
  Assert.isTrue(
    type(truncatedReason) == "string" and #truncatedReason > 0,
    "a truncated vanished frame names its failure"
  )
  local short, countReason = sources.resolveBattleAnimationCallback({ 40, 1, 0x40 })
  Assert.isNil(short, "a vanished frame with the wrong word count resolves to no operation")
  Assert.isTrue(
    type(countReason) == "string" and #countReason > 0,
    "a vanished frame with the wrong word count names its failure"
  )
end

-- An unmapped battler-state word on the cyclic picture callback is a
-- source-proven no-op: the animation has no target, so lowering emits an
-- explicit noop instead of inventing one.
function T.unmapped_cyclic_picture_state_lowers_as_an_explicit_noop()
  local sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(sources.resolveBattleAnimationCallback({ 42, 1, 0x999 }))
  Assert.deepEqual(plan, { op = "noop" }, "an unmapped state word lowers as an explicit no-op")
end

function T.mapped_cyclic_picture_state_selects_its_position_transition()
  local sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(
    sources.resolveBattleAnimationCallback({ 42, 8, 0x102, 0, 10, 0, 20, 1, 0, 5 }),
    "a mapped state word resolves its position transition"
  )
  Assert.equal(
    plan.taskKind,
    "pokemon-picture-cyclic-two-phase-position-transition",
    "the mapped state selects the cyclic position task kind"
  )
  Assert.equal(plan.context, "pokemon-picture", "the transition stays in the picture context")
  Assert.equal(plan.parameters.pictureTarget, "attacker", "the mapped state word names the attacker")
end

function T.zero_divisor_cyclic_picture_fails_closed()
  local sources = require("romdump.src.config.BattleAnimationSources")
  local plan, reason = sources.resolveBattleAnimationCallback({ 42, 8, 0x102, 0, 10, 0, 20, 0, 0, 5 })
  Assert.isNil(plan, "a zero interpolation divisor stages no transition")
  Assert.isTrue(
    type(reason) == "string" and reason:find("divisor", 1, true) ~= nil,
    "a zero interpolation divisor names its failure: " .. tostring(reason)
  )
end

-- Battler particle opcodes 48 (eight words) and 49 (six words) select
-- per-battler-pair emitter resources at runtime; both must resolve through
-- the same position-pair selection the producer consumes.
function T.battler_particle_actions_select_position_pair_resources()
  local sources = require("romdump.src.config.BattleAnimationSources")
  local wide = assert(sources.resolveSourceSelection("battler-particle-action", { 0, 10, 11, 12, 13, 14, 15, 0 }))
  Assert.equal(
    wide.runtimeSelection,
    "battler-particle-position-pair",
    "the eight-word action defers emitter choice to the battler pair"
  )
  Assert.equal(wide.taskKind, "battler-effect-continuation", "the wide action feeds the particle task body")
  Assert.isTrue(
    type(wide.sourceEmitterSelections) == "table" and wide.sourceEmitterSelections["solo-player/solo-enemy"] ~= nil,
    "the wide action maps every battler pair to an emitter selection"
  )
  local narrow = assert(sources.resolveSourceSelection("battler-particle-action", { 0, 20, 21, 22, 23, 0 }))
  Assert.equal(
    narrow.runtimeSelection,
    "battler-particle-position-pair",
    "the six-word action defers emitter choice to the battler pair"
  )
  Assert.equal(narrow.taskKind, "battler-effect-continuation", "the narrow action feeds the particle task body")
end

function T.battler_particle_actions_reject_malformed_shapes()
  local sources = require("romdump.src.config.BattleAnimationSources")
  local badShape, shapeReason = sources.resolveSourceSelection("battler-particle-action", { 0, 1, 2, 3, 4 })
  Assert.isNil(badShape, "a five-word particle frame resolves to no action")
  Assert.isTrue(
    type(shapeReason) == "string" and #shapeReason > 0,
    "a five-word particle frame names its shape failure"
  )
  local badProfile, profileReason =
    sources.resolveSourceSelection("battler-particle-action", { 0, 10, 11, 12, 13, 14, 15, 99 })
  Assert.isNil(badProfile, "an unknown emitter profile resolves to no action")
  Assert.isTrue(
    type(profileReason) == "string" and profileReason:find("pinned initializer table", 1, true) ~= nil,
    "an unknown emitter profile names its failure: " .. tostring(profileReason)
  )
end

return { tests = T }
