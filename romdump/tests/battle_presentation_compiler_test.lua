-- Source-backed effect context declarations are normalized by the producer.

local Assert = require("tests.support.Assert")
local T = {}

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
  return "RGCN"
    .. string.char(0xff, 0xfe)
    .. u16le(0x0100)
    .. u32le(size)
    .. u16le(0x10)
    .. u16le(1)
    .. blockPayload
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
  return "RLCN"
    .. string.char(0xff, 0xfe)
    .. u16le(0x0100)
    .. u32le(size)
    .. u16le(0x10)
    .. u16le(1)
    .. ttlp
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

return { tests = T }
