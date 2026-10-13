-- Dump-backed battle animation catalog inventory: bounded lower, HUD,
-- picture, and transition families resolve through version-filesystem
-- symbols, the producer inventory spans the native dispatch extent, and a
-- streaming program probe walks animation execution data without building
-- a whole-game corpus. Native references follow asm/overlay_07.s
-- (ov07_02234DE8, ov07_0221BEDC, ov07_0221C01C, ov07_0221C188) and
-- asm/overlay_01_021EFB38.s (transition NARC with supporting overlays) at
-- pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")
local RomFs = require("romdump.src.source.RomFs")
local RomImporter = require("romdump.src.source.RomImporter")
local Errors = require("libs.errors.src.Errors")
local Lz10 = require("romdump.src.digest.Lz10")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local AudioBank = require("libs.assets.src.audio.AudioBank")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local Hashing = require("romdump.src.digest.Hashing")

local T = {}

local ANIMATION_NARCS = {
  "NARC_a_0_0_7",
  "NARC_a_0_0_8",
  "NARC_a_0_2_2",
  "NARC_a_0_2_3",
  "NARC_a_0_2_4",
  "NARC_a_0_2_5",
}

local TRANSITION_NARC = "NARC_a_1_0_9"

-- Music column of pinned pret/pokeheartgold asm/unk_020517A4.s::_020FC40A.
-- Physical sequence/category values remain producer provenance.
local SOURCE_SEQUENCE_ROWS = {
  "SEQ_GS_VS_GYMREADER", "SEQ_GS_VS_GYMREADER", "SEQ_GS_VS_GYMREADER", "SEQ_GS_VS_GYMREADER",
  "SEQ_GS_VS_GYMREADER", "SEQ_GS_VS_GYMREADER", "SEQ_GS_VS_GYMREADER", "SEQ_GS_VS_GYMREADER",
  "SEQ_GS_VS_GYMREADER_KANTO", "SEQ_GS_VS_GYMREADER_KANTO", "SEQ_GS_VS_GYMREADER_KANTO",
  "SEQ_GS_VS_GYMREADER_KANTO", "SEQ_GS_VS_GYMREADER_KANTO", "SEQ_GS_VS_GYMREADER_KANTO",
  "SEQ_GS_VS_GYMREADER_KANTO", "SEQ_GS_VS_GYMREADER_KANTO",
  "SEQ_GS_VS_GYMREADER", "SEQ_GS_VS_GYMREADER", "SEQ_GS_VS_GYMREADER", "SEQ_GS_VS_GYMREADER",
  "SEQ_GS_VS_CHAMP", "SEQ_GS_VS_RIVAL", "SEQ_GS_VS_RAIKOU", "SEQ_GS_VS_ENTEI", "SEQ_GS_VS_SUICUNE",
  "SEQ_GS_VS_HOUOU", "SEQ_GS_VS_LUGIA", "SEQ_GS_VS_KODAI", "SEQ_GS_VS_NORAPOKE_KANTO",
  "SEQ_GS_VS_ROCKET", "SEQ_GS_VS_ROCKET", "SEQ_GS_VS_ROCKET", "SEQ_GS_VS_ROCKET", "SEQ_GS_VS_ROCKET",
  "SEQ_GS_VS_ROCKET", "SEQ_GS_VS_TRAINER", "SEQ_GS_VS_TRAINER", "SEQ_GS_VS_TRAINER",
  "SEQ_GS_VS_NORAPOKE", "SEQ_GS_BA_BRAIN", "SEQ_GS_VS_GYMREADER", "SEQ_GS_VS_TRAINER",
  "SEQ_GS_VS_NORAPOKE", "SEQ_GS_VS_TRAINER", "SEQ_GS_VS_CHAMP",
}

local INTRO_INPUTS = {
  "encounterKind",
  "trainerClass",
  "wildSpecies",
  "battleType",
  "frontierBattle",
  "doubleBattle",
  "tagBattle",
  "wildSetupParameter",
  "firstLivingOpponent",
  "kantoRegion",
}

local INTRO_ROLE_BY_SEQUENCE = {
  SEQ_GS_VS_GYMREADER = "gym-leader",
  SEQ_GS_VS_GYMREADER_KANTO = "kanto-gym-leader",
  SEQ_GS_VS_CHAMP = "champion",
  SEQ_GS_VS_RIVAL = "rival",
  SEQ_GS_VS_RAIKOU = "raikou",
  SEQ_GS_VS_ENTEI = "entei",
  SEQ_GS_VS_SUICUNE = "suicune",
  SEQ_GS_VS_HOUOU = "ho-oh",
  SEQ_GS_VS_LUGIA = "lugia",
  SEQ_GS_VS_KODAI = "special-legendary",
  SEQ_GS_VS_NORAPOKE_KANTO = "kanto-wild",
  SEQ_GS_VS_ROCKET = "rocket",
  SEQ_GS_VS_TRAINER = "trainer",
  SEQ_GS_VS_NORAPOKE = "wild",
  SEQ_GS_BA_BRAIN = "battle-arcade-brain",
}

local TRANSITION_FALLBACK_ROWS = { [23] = true, [24] = true, [25] = true, [42] = true, [43] = true }

local UNAVAILABLE_HEARTGOLD_EFFECTS = {
  "CHARGE",
  "STRUGGLE",
  "NEEDLE_ARM",
  "WING_ATTACK",
  "SKY_ATTACK",
  "EXPLOSION",
  "ROCK_SLIDE",
  "SPIT_UP",
  "POISON_FANG",
  "AIR_CUTTER",
  "CROSS_POISON",
  "STONE_EDGE",
  "BUG_BITE",
}

local function has(values, expected)
  for _, value in ipairs(values) do
    if value == expected then
      return true
    end
  end
  return false
end

local function assertNoRuntimeAudioIds(value, path)
  if type(value) ~= "table" then
    return
  end
  for key, child in pairs(value) do
    local field = type(key) == "string" and key or ""
    Assert.isFalse(
      field == "categoryId" or field == "sequenceId" or field == "bankId" or field == "playerId",
      path .. " keeps native audio selectors out of runtime data"
    )
    assertNoRuntimeAudioIds(child, path .. "." .. field)
  end
end

function T.corrected_animation_roots_compile_as_independent_effects(romFs, versionId)
  Assert.equal(versionId, "heartgold", "the source-root trace is pinned to the verified HeartGold dump")
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local expectedCalls = { EXTREME_SPEED = 0, CHARGE_BEAM = 0, WATER_PULSE = 1 }
  for key, callCount in pairs(expectedCalls) do
    local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, key)
    Assert.notNil(effect, key .. " compiles independently: " .. tostring(err))
    Assert.isNil(err)
    local actualCalls = 0
    for _, instruction in ipairs(effect.program.instructions) do
      if instruction.op == "call-subprogram" then
        actualCalls = actualCalls + 1
        Assert.isNil(instruction.alternateTarget, "stack saturation stays a dynamic cursor rule")
        Assert.equal(
          instruction.cursorRule,
          "call-first-free-subprogram-slot; all-slots-busy-redispatch-count-word"
        )
      end
    end
    Assert.equal(actualCalls, callCount, key .. " has the source-traced subprogram call depth")
  end
end

---@param moduleName string
---@return table|nil
local function tryLoad(moduleName)
  local ok, module = pcall(require, moduleName)
  if ok and type(module) == "table" then
    return module
  end
  return nil
end

---@param romFs table
---@param symbol string
---@return table archive
local function openArchive(romFs, symbol, versionId)
  local archive, err = romFs:openNarc(symbol)
  Assert.isTrue(
    archive ~= nil,
    versionId .. ": animation archive " .. symbol .. " opens through the version filesystem: " .. tostring(err)
  )
  assert(archive ~= nil, "the archive stays open while members stream")
  return archive
end

local function u32le(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function effectSourceFixture(romFs, effectKey, stream, replacements)
  local route = assert(
    require("romdump.src.config.BattleAnimationSources").resolveSemanticRoute(effectKey),
    "the effect has a source route"
  )
  local streamArchive = {
    readMember = function(_, memberId)
      Assert.equal(memberId, route.memberId, "the producer requests the source-selected program member")
      return stream
    end,
  }
  return {
    version = function()
      return romFs:version()
    end,
    metadata = function()
      return romFs:metadata()
    end,
    openNarc = function(_, archiveSymbol)
      if archiveSymbol == route.archiveSymbol then
        return streamArchive
      end
      local replacement = replacements and replacements[archiveSymbol]
      if replacement ~= nil then
        local sourceArchive = assert(romFs:openNarc(archiveSymbol))
        return {
          readMember = function(_, memberId)
            if memberId == replacement.memberId then
              return replacement.bytes, replacement.error
            end
            return sourceArchive:readMember(memberId)
          end,
        }
      end
      return romFs:openNarc(archiveSymbol)
    end,
  }
end

function T.bounded_resource_families_resolve_through_symbols_not_file_numbers(romFs, versionId)
  local Sources = require("romdump.src.config.BattlePresentationSources")
  Assert.equal(Sources.LOWER_NARC, "NARC_a_0_0_7", versionId .. ": the lower archive resolves by symbol")
  Assert.equal(Sources.SCENE_NARC, "NARC_a_0_0_8", versionId .. ": the scene archive resolves by symbol")
  local lower = openArchive(romFs, Sources.LOWER_NARC, versionId)
  local sceneArchive = openArchive(romFs, Sources.SCENE_NARC, versionId)
  local lowerMember, lowerErr = lower:readMember(Sources.ROLES.lowerChars)
  Assert.notNil(lowerMember, versionId .. ": the bounded lower family reads its shared characters")
  Assert.isTrue(lowerErr == nil, versionId .. ": the bounded lower read carries no error: " .. tostring(lowerErr))
  local hudMember, hudErr = sceneArchive:readMember(Sources.ROLES.playerHud.ncgr)
  Assert.notNil(hudMember, versionId .. ": the bounded HUD family reads its player characters")
  Assert.isTrue(hudErr == nil, versionId .. ": the bounded HUD read carries no error")
  for _, symbol in ipairs(ANIMATION_NARCS) do
    local archive = openArchive(romFs, symbol, versionId)
    local first, firstErr = archive:readMember(0)
    Assert.notNil(first, versionId .. ": animation archive " .. symbol .. " streams its first member")
    Assert.isTrue(firstErr == nil, versionId .. ": archive " .. symbol .. " reads without error")
  end
  local transition = openArchive(romFs, TRANSITION_NARC, versionId)
  local transitionMember, transitionErr = transition:readMember(0)
  Assert.notNil(transitionMember, versionId .. ": the bounded transition family reads through its NARC symbol")
  Assert.isTrue(transitionErr == nil, versionId .. ": the transition read carries no error")
  local AnimSources = tryLoad("romdump.src.config.BattleAnimationSources")
  Assert.isTrue(
    AnimSources ~= nil,
    versionId .. ": no build-only animation source inventory maps loader, selector, and transition roles"
  )
end

function T.malformed_effect_sources_fail_without_replacing_ready_effects(romFs, versionId)
  Assert.equal(versionId, "heartgold", "malformed source probes are scoped to the verified HeartGold dump")
  local compiler = tryLoad("romdump.src.digest.battle.BattlePresentationCompiler")
  Assert.isTrue(compiler ~= nil, "the battle presentation compiler is available")
  local ArtifactBattleJobs = require("romdump.src.build.ArtifactBattleJobs")
  local charArchive = "NARC_a_0_2_2"
  local lzTruncated = string.char(0x10, 1, 0, 0)
  local sourceChar = openArchive(romFs, charArchive, versionId):readMember(0)
  Assert.notNil(sourceChar, "the selected character member is present")
  if string.byte(sourceChar, 1) == 0x10 then
    sourceChar = assert(Lz10.decode(sourceChar), "the source CHAR member decompresses before truncation")
  end
  local truncatedChar = sourceChar:sub(1, #sourceChar - 1)
  local cases = {
    {
      name = "missing selected palette",
      words = { 21, 0, 54 },
      replacements = { ["NARC_a_0_0_7"] = { memberId = 295, bytes = nil } },
      expectedCode = "BATTLE_EFFECT_SOURCE_UNAVAILABLE",
      expectedRole = "battle-background",
      expectedSlot = "palette",
    },
    {
      name = "unknown callback",
      words = { 45, 84, 0, 54 },
      expectedCode = "BATTLE_EFFECT_SOURCE_UNRESOLVED",
      expectedRole = "battle-animation-callback",
      expectedOperandSelector = 84,
    },
    {
      name = "out-of-range branch",
      words = { 33, 999, 54 },
      expectedCode = "BATTLE_ANIMATION_STREAM_INVALID",
      expectedProgram = "TACKLE",
      expectedOffset = 999,
    },
    {
      name = "corrupt compressed member",
      words = { 74, 0, 0, 54 },
      replacements = { [charArchive] = { memberId = 0, bytes = lzTruncated } },
      expectedCode = "BATTLE_COMPRESSED_MEMBER_INVALID",
      expectedCauseCode = Lz10.ERROR.STREAM_INVALID,
      expectedResource = true,
    },
    {
      name = "truncated true CHAR",
      words = { 74, 0, 0, 54 },
      replacements = { [charArchive] = { memberId = 0, bytes = truncatedChar } },
      expectedCode = "BATTLE_DECODE_FAILED",
      expectedCause = "G2D_TRUNCATED",
      expectedResource = true,
    },
  }

  for _, case in ipairs(cases) do
    local words = {}
    for _, word in ipairs(case.words) do
      words[#words + 1] = u32le(word)
    end
    local fixture = effectSourceFixture(romFs, "TACKLE", table.concat(words), case.replacements)
    local compileOk, effectOrError, compileErr = pcall(compiler.compileEffect, fixture, { versionId = versionId }, "TACKLE")
    local failure = compileOk and compileErr or effectOrError
    Assert.isTrue(not compileOk or effectOrError == nil, case.name .. ": malformed source cannot compile")
    Assert.isTrue(Errors.is(failure), case.name .. ": failure is structured")
    Assert.equal(
      failure.code,
      case.expectedCode,
      case.name .. ": exact source/decoder failure is identified, got " .. tostring(failure.code) .. ": " .. failure.message
    )
    if case.expectedProgram ~= nil then
      Assert.equal(failure.context.program, case.expectedProgram, case.name .. ": diagnostic names the program")
      Assert.equal(failure.context.offset, case.expectedOffset, case.name .. ": diagnostic names the native offset")
    end
    if case.expectedRole ~= nil then
      local role = failure.context.role or (failure.context.provenance and failure.context.provenance.role)
      Assert.equal(role, case.expectedRole, case.name .. ": diagnostic names the source role")
      if case.expectedSlot ~= nil then
        Assert.equal(failure.context.provenance.slot, case.expectedSlot, case.name .. ": diagnostic names the missing slot")
      end
    end
    if case.expectedOperandSelector ~= nil then
      Assert.equal(failure.context.provenance.operands[1], case.expectedOperandSelector)
    end
    if case.expectedResource then
      Assert.equal(failure.context.label, "animation sprite-character characters", case.name .. ": diagnostic names the resource")
      Assert.equal(failure.context.memberId, 0, case.name .. ": diagnostic identifies the physical source member")
    end
    if case.expectedCauseCode ~= nil then
      Assert.equal(failure.context.causeCode, case.expectedCauseCode, case.name .. ": diagnostic retains the decoder cause")
    end
    if case.expectedCause ~= nil then
      Assert.equal(failure.context.cause, case.expectedCause, case.name .. ": diagnostic retains the decoder cause")
    end

    local markerPath = BattlePresentationCache.effectMarkerPath("TACKLE")
    local effectPath = BattlePresentationCache.effectPath("TACKLE")
    local files = { [markerPath] = "last-good-marker", [effectPath] = "last-good-record" }
    local owned = {}
    local artifact = {
      stageFs = function()
        return {
          write = function(_, path, bytes)
            files[path] = bytes
          end,
          writeLua = function(_, path, value)
            files[path] = value
          end,
        }
      end,
      addOwnedRoot = function(_, path)
        owned[path] = true
      end,
    }
    local jobOk = pcall(ArtifactBattleJobs.executeEffect, artifact, {
      romFs = fixture,
      versionId = versionId,
    }, { key = "TACKLE", generationId = "a15-probe" })
    Assert.isFalse(jobOk, case.name .. ": the real effect job rejects failed source compilation")
    Assert.equal(files[markerPath], "last-good-marker", case.name .. ": the last good ready marker survives")
    Assert.equal(files[effectPath], "last-good-record", case.name .. ": the last good record survives")
    Assert.isNil(next(owned), case.name .. ": no partial artifact roots are claimed")
  end
end

function T.source_callback_40_lowers_to_a_direct_semantic_picture_operation(romFs, versionId)
  Assert.equal(versionId, "heartgold", "the source callback is checked against HeartGold evidence")
  local compiler = tryLoad("romdump.src.digest.battle.BattlePresentationCompiler")
  Assert.isTrue(compiler ~= nil, "the battle presentation compiler is available")
  local words = { 45, 40, 2, 0x0e, 1, 54 }
  local stream = {}
  for _, word in ipairs(words) do
    stream[#stream + 1] = u32le(word)
  end
  local fixture = effectSourceFixture(romFs, "TACKLE", table.concat(stream))
  local effect, err = compiler.compileEffect(fixture, { versionId = versionId }, "TACKLE")
  Assert.notNil(effect, "source-proven direct picture operations compile: " .. tostring(err))
  Assert.isNil(err)
  local direct
  for _, instruction in ipairs(effect.program.instructions) do
    if instruction.op == "set-pokemon-picture-vanished" then
      direct = instruction
    end
  end
  Assert.notNil(direct, "the callback lowers as its direct semantic operation")
  Assert.deepEqual(
    direct.pictureSets,
    { "active-battler", "active-battler-pair-when-enabled", "opposing-battler" }
  )
  Assert.isTrue(direct.vanished)
  local resolved = assert(effect.provenance.resolvedSourceInputs[1])
  Assert.equal(resolved.op, "set-pokemon-picture-vanished")
  Assert.isNil(resolved.callback, "the semantic operation does not invent a callback wrapper")
end

function T.source_callback_42_default_branch_lowers_to_a_direct_noop(romFs, versionId)
  Assert.equal(versionId, "heartgold", "the source callback branch is checked against HeartGold evidence")
  local compiler = tryLoad("romdump.src.digest.battle.BattlePresentationCompiler")
  Assert.isTrue(compiler ~= nil, "the battle presentation compiler is available")
  local words = { 45, 42, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4 }
  local stream = {}
  for _, word in ipairs(words) do
    stream[#stream + 1] = u32le(word)
  end
  local fixture = effectSourceFixture(romFs, "TACKLE", table.concat(stream))
  local effect, err = compiler.compileEffect(fixture, { versionId = versionId }, "TACKLE")
  Assert.notNil(effect, "the source-proven default callback path compiles: " .. tostring(err))
  Assert.isNil(err)
  Assert.equal(effect.program.instructions[1].op, "noop")
  Assert.equal(effect.program.instructions[2].op, "reset-battle-presentation", "the callback consumes all declared parameters")
  local resolved = assert(effect.provenance.resolvedSourceInputs[1])
  Assert.equal(resolved.op, "noop")
  Assert.isNil(resolved.callback, "the source no-op is not wrapped in a runtime callback")
end

function T.source_callbacks_44_and_45_stage_source_selected_background_resources(romFs, versionId)
  Assert.equal(versionId, "heartgold", "background callback resources are checked against HeartGold evidence")
  local compiler = tryLoad("romdump.src.digest.battle.BattlePresentationCompiler")
  Assert.isTrue(compiler ~= nil, "the battle presentation compiler is available")
  local callbacks = {
    [44] = "battle-background-alpha-scroll-transition",
    [45] = "battle-background-sprite-slide-transition",
  }
  for selector, taskKind in pairs(callbacks) do
    local words = { 45, selector, 8, 0, 0, 0, 0, 0, 0, 0, 0, 54 }
    local stream = {}
    for _, word in ipairs(words) do
      stream[#stream + 1] = u32le(word)
    end
    local fixture = effectSourceFixture(romFs, "TACKLE", table.concat(stream))
    local effect, err = compiler.compileEffect(fixture, { versionId = versionId }, "TACKLE")
    Assert.notNil(effect, "the source-proven callback " .. selector .. " compiles: " .. tostring(err))
    Assert.isNil(err)
    local callback
    for _, instruction in ipairs(effect.program.instructions) do
      if instruction.op == "invoke-battle-animation-callback" then
        callback = instruction
      end
    end
    Assert.notNil(callback, "the callback retains its source-normalized task")
    Assert.equal(callback.taskKind, taskKind)
    Assert.equal(callback.taskContext, "battle-display")
    Assert.equal(callback.runtimeSelection, "battle-background-three-way-screen-selection")
    Assert.equal(callback.parameters.paletteTarget, "battle-animation-palette-target")
    local expectedSlots = {
      "character",
      "palette",
      "screenDefault",
      "screenBattlerClassFour",
      "screenContextFlag",
    }
    for _, slot in ipairs(expectedSlots) do
      local resourceKey = assert(callback.resourceKeys[slot], "the callback references its " .. slot .. " resource")
      Assert.isTrue(resourceKey:match("^battle/animation/battle%-animation%-callback/") ~= nil)
    end
    Assert.isNil(callback.sourceSelections, "physical source selections stay producer-only")
    Assert.isNil(callback.memberId, "native member identities stay producer-only")
    local resourceCount = 0
    for _ in pairs(callback.resourceKeys) do
      resourceCount = resourceCount + 1
    end
    Assert.equal(resourceCount, #expectedSlots, "the callback exposes exactly its five source resource roles")
    local source = assert(effect.provenance.resolvedSourceInputs[1])
    Assert.equal(source.role, "battle-animation-callback")
    Assert.isNil(source.operands, "source operands remain producer provenance, not normalized callback data")
    for _, resourceKey in pairs(callback.resourceKeys) do
      local descriptor = assert(effect.resources[resourceKey], "the semantic key has a staged resource descriptor")
      Assert.notNil(effect.resourcePayloads[descriptor.payload], "the decoded source payload is staged")
    end
  end
end

function T.producer_rejects_fixed_point_values_outside_the_normalized_u32_domain(romFs, versionId)
  Assert.equal(versionId, "heartgold", "the invalid normalized value is probed at the HeartGold producer boundary")
  local compiler = tryLoad("romdump.src.digest.battle.BattlePresentationCompiler")
  Assert.isTrue(compiler ~= nil, "the battle presentation compiler is available")
  local animationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
  local previousCompile = animationCompiler.compile
  local function malformedProgram()
    return {
      entry = "main",
      instructions = {
        {
          op = "create-configured-sprite",
          taskKind = "sprite-affine-rotation-transition",
          taskContext = "battle-sprite",
          parameters = {
            spriteSpacingX = 0,
            spriteSpacingY = 0,
            positionTransitionTicks = 0,
            rotationAngle = 0x100000000,
          },
          resourceKeys = {
            character = "test/character",
            palette = "test/palette",
            cell = "test/cell",
            animation = "test/animation",
            multiCell = "test/multi-cell",
            multiAnimation = "test/multi-animation",
          },
        },
      },
      subprograms = {},
      taskKinds = {},
    }
  end
  animationCompiler.compile = malformedProgram
  local fixture = effectSourceFixture(romFs, "TACKLE", "")
  local ok, effectOrError = pcall(compiler.compileEffect, fixture, { versionId = versionId }, "TACKLE")
  animationCompiler.compile = previousCompile
  Assert.isFalse(ok, "the producer rejects malformed normalized fixed-point IR")
  Assert.isTrue(
    tostring(effectOrError):find("parameters.rotationAngle", 1, true) ~= nil,
    "the diagnostic identifies the out-of-domain fixed-point field"
  )

  local ArtifactBattleJobs = require("romdump.src.build.ArtifactBattleJobs")
  local markerPath = BattlePresentationCache.effectMarkerPath("TACKLE")
  local effectPath = BattlePresentationCache.effectPath("TACKLE")
  local files = { [markerPath] = "last-good-marker", [effectPath] = "last-good-record" }
  local owned = {}
  local artifact = {
    stageFs = function()
      return {
        write = function(_, path, bytes)
          files[path] = bytes
        end,
        writeLua = function(_, path, value)
          files[path] = value
        end,
      }
    end,
    addOwnedRoot = function(_, path)
      owned[path] = true
    end,
  }
  animationCompiler.compile = malformedProgram
  local jobOk = pcall(ArtifactBattleJobs.executeEffect, artifact, {
    romFs = fixture,
    versionId = versionId,
  }, { key = "TACKLE", generationId = "invalid-fixed-point" })
  animationCompiler.compile = previousCompile
  Assert.isFalse(jobOk, "the real effect job rejects invalid normalized fixed-point IR")
  Assert.equal(files[markerPath], "last-good-marker", "invalid IR preserves the last good ready marker")
  Assert.equal(files[effectPath], "last-good-record", "invalid IR preserves the last good effect record")
  Assert.isNil(next(owned), "invalid IR does not claim partial artifact roots")
end

local function heartgoldSourceRoutesPublishCompleteGlobalCatalog(romFs, versionId)
  Assert.equal(versionId, "heartgold", "this source inventory is scoped to HeartGold")
  local Sources = require("romdump.src.config.BattlePresentationSources")
  local standard = Sources.menuDisplay("standard", false, false)
  Assert.equal(standard.layoutVariant, "standard")
  Assert.equal(standard.labels.fight, "label/fight")
  Assert.deepEqual(standard.dynamicFields, {})
  local caughtContest = Sources.menuDisplay("bug-contest", true, false)
  Assert.equal(caughtContest.layoutVariant, "frontier")
  Assert.equal(caughtContest.key, "menu/main/bug-contest")
  Assert.deepEqual(caughtContest.dynamicFields, { "caughtPokemonGender", "caughtPokemonLevel", "remainingBalls" })
  Assert.equal(Sources.TRANSITION_SELECTOR_FAMILIES[9], "overlay-119")
  Assert.equal(Sources.transitionFallbackSelector("cave", "night", true), 11)

  local Compiler = tryLoad("romdump.src.digest.battle.BattlePresentationCompiler")
  Assert.isTrue(Compiler ~= nil, "no presentation compiler backs the source inventory")
  local bundle, err = Compiler.compileGlobal(romFs, { versionId = versionId })
  Assert.isNil(err, "complete source routes and closure publish without blockers: " .. tostring(err))
  local manifest = assert(bundle and bundle.manifest, "global compilation publishes a manifest")
  require("libs.assets.src.battle.BattlePresentationSchema").assertManifest(manifest)
  for _, section in ipairs({
    "catalogIdentity",
    "scenes",
    "layouts",
    "hud",
    "pictures",
    "menus",
    "messages",
    "transitions",
    "audioRoles",
    "programs",
    "resources",
    "coverage",
  }) do
    Assert.notNil(manifest[section], "the complete catalog carries its " .. section .. " section")
  end

  local intro = assert(
    manifest.audioRoles.introMusic,
    "the catalog closes battle-intro music routes instead of only listing baseline sequence symbols"
  )
  Assert.deepEqual(intro.inputs, INTRO_INPUTS, "intro routes retain typed trainer/wild/setup inputs")
  Assert.equal(#intro.sourceRoutes, #SOURCE_SEQUENCE_ROWS, "catalog routes correspond to pinned music-table rows")
  local routesByKey = {}
  for _, route in ipairs(intro.routes) do
    routesByKey[route.key] = route
  end
  local sequenceSymbols = {}
  for index, symbol in ipairs(SOURCE_SEQUENCE_ROWS) do
    local sourceRoute = assert(intro.sourceRoutes[index], "each pinned source row maps to a semantic route")
    Assert.equal(sourceRoute.sequenceSymbol, symbol, "catalog preserves the sequence selected by the pinned table row")
    local role = assert(INTRO_ROLE_BY_SEQUENCE[symbol], "pinned sequence has a semantic music role")
    Assert.equal(sourceRoute.routeKey, "battle/music/" .. role, "each pinned row maps to its semantic music role")
    Assert.equal(
      sourceRoute.transitionFallback,
      TRANSITION_FALLBACK_ROWS[index] == true,
      "visual fallback rows preserve their selected music route"
    )
    Assert.notNil(routesByKey[sourceRoute.routeKey], "source row's semantic route is present")
    sequenceSymbols[sourceRoute.sequenceKey] = symbol
  end
  for _, route in ipairs(intro.routes) do
    Assert.isTrue(type(route.key) == "string" and route.key ~= "", "intro route has a semantic key")
    Assert.isTrue(
      type(route.sequenceKey) == "string" and route.sequenceKey ~= "",
      "intro route selects a semantic sequence key"
    )
    Assert.isTrue(type(route.context) == "table" and #route.context > 0, "intro route declares typed context")
    for _, input in ipairs(route.context) do
      Assert.isTrue(has(INTRO_INPUTS, input), "route context uses a declared semantic input")
    end
  end
  Assert.isTrue(
    has(intro.kantoOverrides, "wild/ordinary") and has(intro.kantoOverrides, "trainer/generic"),
    "post-selection Kanto overrides preserve wild and generic-trainer music"
  )
  Assert.isTrue(intro.transitionFallbackIndependent, "0xffff transition fallback never drops the selected music")

  local audioPlan = assert(AudioCompiler.planSource(romFs))
  local sequenceClosures = assert(intro.sequenceClosures)
  local selectedBanks = {}
  local selectedSequences = {}
  for sequenceKey, symbol in pairs(sequenceSymbols) do
    local closure = assert(sequenceClosures[sequenceKey], "every source-selected sequence has a closure")
    Assert.isTrue(type(closure.bankKey) == "string" and closure.bankKey ~= "", "audio closure names a semantic bank")
    Assert.isTrue(type(closure.player) == "table", "audio closure carries runtime player settings")
    Assert.isTrue(
      type(closure.sampleKeys) == "table" and #closure.sampleKeys > 0,
      "audio closure lists sample identities"
    )
    Assert.isTrue(
      type(closure.closureIdentity) == "string" and #closure.closureIdentity == 40,
      "audio closure has a content identity"
    )
    local sequenceId = audioPlan.plan.index.sequenceBySymbol[symbol]
    Assert.notNil(sequenceId, "selected sequence resolves in the adopted dump's audio index")
    local sequence = audioPlan.plan.index.sequences[sequenceId]
    Assert.notNil(sequence, "selected sequence record resolves")
    local bankId = sequence.bankId
    Assert.notNil(audioPlan.plan.index.banks[bankId], "selected sequence resolves to its bank")
    selectedBanks[bankId] = selectedBanks[bankId] or { sequenceIds = {}, closures = {} }
    selectedBanks[bankId].sequenceIds[#selectedBanks[bankId].sequenceIds + 1] = sequenceId
    selectedBanks[bankId].closures[#selectedBanks[bankId].closures + 1] = closure
    selectedSequences[sequenceKey] = { sequence = sequence, sequenceId = sequenceId }
  end
  for bankId, selected in pairs(selectedBanks) do
    table.sort(selected.sequenceIds)
    local stagedSamples = {}
    local compiled = assert(
      AudioCompiler.compileBank(romFs, { bankId = bankId, sequenceIds = selected.sequenceIds }, function(sampleKey)
        stagedSamples[sampleKey] = true
      end)
    )
    local bankSampleKeys = assert(AudioBank.sampleKeys(compiled.bank))
    table.sort(bankSampleKeys)
    local manifestSampleKeys = {}
    for _, sampleKey in ipairs(bankSampleKeys) do
      manifestSampleKeys[#manifestSampleKeys + 1] = "audio/sample/content/" .. sampleKey
    end
    table.sort(manifestSampleKeys)
    for _, closure in ipairs(selected.closures) do
      for _, sampleKey in ipairs(bankSampleKeys) do
        Assert.isTrue(stagedSamples[sampleKey], "bank sample payload is compiled")
        Assert.isTrue(
          has(closure.sampleKeys, "audio/sample/content/" .. sampleKey),
          "every bank sample is represented by its semantic route-closure key"
        )
      end
      Assert.deepEqual(
        closure.sampleKeys,
        manifestSampleKeys,
        "route closure contains the sorted semantic identities for every bank sample"
      )
    end
    for sequenceKey, selectedSequence in pairs(selectedSequences) do
      if selectedSequence.sequence.bankId == bankId then
        local compiledSequence = assert(compiled.sequences[selectedSequence.sequenceId])
        local player = assert(sequenceClosures[sequenceKey]).player
        local closure = assert(sequenceClosures[sequenceKey])
        Assert.equal(player.volume, compiledSequence.player.initialVolume, "route retains sequence volume")
        Assert.equal(player.channelPriority, compiledSequence.player.channelPriority, "route retains channel priority")
        Assert.equal(player.playerPriority, compiledSequence.player.playerPriority, "route retains player priority")
        Assert.equal(
          closure.closureIdentity,
          Hashing.hashLua({
            sequence = Hashing.hashLua(compiledSequence),
            bank = Hashing.hashLua(compiled.bank),
            samples = manifestSampleKeys,
          }),
          "content identity binds the selected sequence, bank, and all sample identities"
        )
      end
    end
  end
  assertNoRuntimeAudioIds(intro, "audioRoles.introMusic")

  Assert.isTrue(type(manifest.menus) == "table", "the catalog retains the normalized menu section")
  Assert.isTrue(type(manifest.transitions) == "table", "the catalog retains the transition section")
  Assert.isTrue(type(manifest.messages) == "table", "the catalog retains the source-backed message section")
  Assert.isTrue(
    type(manifest.messages.sourceRoutes) == "table",
    "the message catalog retains source-normalized runtime routes"
  )
  local scriptMessages = assert(manifest.messages.sourceRoutes["battle/script-message"])
  Assert.deepEqual(scriptMessages.banks, { "message-bank/battle-script-controller" })
  Assert.deepEqual(scriptMessages.inputs, { "messageRecordReference", "messageTagSymbol", "tagTypedParameters" })
  Assert.equal(scriptMessages.placeholderPlan, "battleMessageTags")
  Assert.deepEqual(scriptMessages.programContext, Sources.MESSAGE_SOURCE_ROUTES.scriptLiteral.programContext)
  local scriptMessageCoverage = assert(manifest.coverage["battle/script-message"])
  Assert.deepEqual(scriptMessageCoverage.programContext, scriptMessages.programContext)
  Assert.deepEqual(scriptMessageCoverage.messageRoutes, { "battle/message-template" })
  local globalScriptMessages = assert(manifest.messages.sourceRoutes["battle/global-script-message"])
  Assert.deepEqual(globalScriptMessages.banks, { "message-bank/battle-script-controller" })
  Assert.deepEqual(globalScriptMessages.inputs, { "messageRecordReference", "messageTagSymbol", "tagTypedParameters" })
  Assert.equal(globalScriptMessages.programContext.delivery, "message-scope-global")
  local globalMessageCoverage = assert(manifest.coverage["battle/global-script-message"])
  Assert.deepEqual(globalMessageCoverage.programContext, globalScriptMessages.programContext)
  Assert.deepEqual(globalMessageCoverage.messageRoutes, { "battle/message-template" })
  local trainerPairs = assert(manifest.messages.sourceRoutes["battle/trainer-pair-speech"])
  Assert.deepEqual(trainerPairs.banks, { "message-bank/trainer-pair-lookup" })
  Assert.deepEqual(trainerPairs.resources, {
    "trainer-message-index/offsets",
    "trainer-message-index/pairs",
  })
  Assert.deepEqual(
    manifest.coverage["battle/trainer-pair-speech"].resources,
    {
      "message-bank/trainer-pair-lookup",
      "trainer-message-index/offsets",
      "trainer-message-index/pairs",
    },
    "trainer-pair closure stages its message bank and decoded lookup tables"
  )
  local trainerPairSelection = assert(manifest.messages.dynamicRoutes.trainerPairSpeech).selection
  Assert.deepEqual(trainerPairSelection, {
      lookup = Sources.MESSAGE_ROUTES.trainerPairSpeech.selection.lookup,
      offsetsResource = Sources.TRAINER_MESSAGE_TABLES.offsetsResource,
      pairsResource = Sources.TRAINER_MESSAGE_TABLES.pairsResource,
      offsetSelection = Sources.TRAINER_MESSAGE_TABLES.offsetSelection,
      pairSelection = Sources.TRAINER_MESSAGE_TABLES.pairSelection,
    }, "trainer-pair route publishes the exact semantic two-table lookup")
  local frontierSpeech = assert(manifest.messages.sourceRoutes["battle/frontier-trainer-speech"])
  Assert.equal(frontierSpeech.expansion, "frontierTrainerMail")
  Assert.equal(frontierSpeech.selectionCase, "special-trainer-or-frontier-battle-type")
  local frontierMail = assert(manifest.messages.sourceRoutes["battle/frontier-trainer-mail"])
  Assert.equal(frontierMail.selection, "runtime-mail-bank-and-message-number")
  Assert.equal(frontierMail.placeholderInputs, "easyChatWordIndices")
  Assert.equal(#frontierMail.banks, 16)
  local messageTemplate = assert(manifest.messages.sourceRoutes["battle/message-template"])
  Assert.equal(messageTemplate.bufferPlan, "tagSelectedBuffers")
  Assert.deepEqual(manifest.messages.tagSchemas["nickname-move"], { "nickname", "move" })
  Assert.deepEqual(manifest.messages.tagInputs.move.selection, { "currentMove", "temporaryMove" })
  for role, resolver in pairs(Sources.MESSAGE_TAG_CONTEXT_RESOLVERS) do
    Assert.equal(
      manifest.messages.tagInputs[role].output,
      resolver.result,
      role .. " resolver output is normalized into the published manifest"
    )
  end
  Assert.equal(manifest.messages.templateInputs.nickname.dependency, "partyBoxMon")
  Assert.equal(manifest.messages.templateExpansion.input, "tagSelectedBuffers")
  Assert.isNil(scriptMessages.source, "source file and symbol evidence stays in producer provenance")
  Assert.equal(
    manifest.resources["trainer-message-index/offsets"].format,
    "hgss-trainer-message-offsets-v1",
    "trainer offsets have a source-independent decoded resource"
  )
  Assert.equal(
    manifest.resources["trainer-message-index/pairs"].format,
    "hgss-trainer-message-pairs-v1",
    "trainer pairs have a source-independent decoded resource"
  )
  Assert.isTrue(type(manifest.resources) == "table", "the catalog retains decoded resource candidates")
  Assert.isTrue(type(manifest.coverage) == "table", "the catalog retains source route closure admissions")
  for routeKey, route in pairs(manifest.transitions.routes) do
    local admission = manifest.coverage["transition/" .. routeKey]
    Assert.notNil(admission, "every semantic transition route has an admission closure: " .. routeKey)
    Assert.equal(admission.kind, "transition-route")
    Assert.equal(admission.route, routeKey)
    Assert.deepEqual(admission.resources, route.resources)
    Assert.deepEqual(admission.operations, { route.role })
    Assert.equal(#admission.closureIdentity, 40)
  end
  Assert.notNil(manifest.programs, "source-selected executable roots receive normalized program entries")
  Assert.notNil(manifest.programs.TACKLE, "a real move stream is admitted as an animation program")
  Assert.isNil(manifest.programs.TACKLE.status, "ordinary TACKLE route remains available")
  Assert.isNil(manifest.programs.TACKLE.failure, "ordinary TACKLE route keeps its existing record shape")
  Assert.equal(assert(manifest.coverage.TACKLE).kind, "animation-program")
  local unavailable = {}
  local ArtifactBattleJobs = require("romdump.src.build.ArtifactBattleJobs")
  for _, key in ipairs(UNAVAILABLE_HEARTGOLD_EFFECTS) do
    unavailable[key] = true
    local program = assert(manifest.programs[key], key .. " remains an explicit catalog route")
    Assert.equal(program.status, "unavailable", key .. " is explicitly unavailable")
    local admission = assert(manifest.coverage[key], key .. " remains represented in route coverage")
    Assert.equal(admission.kind, "animation-program")
    Assert.equal(admission.status, "unavailable", key .. " coverage preserves unavailable status")
    Assert.deepEqual(admission.failure, program.failure, key .. " coverage preserves its exact source cause")

    local artifact = {
      stageFs = function()
        error(key .. " must fail before staging")
      end,
      addOwnedRoot = function()
        error(key .. " must not claim a staged artifact")
      end,
    }
    local requestOk, requestErr = pcall(ArtifactBattleJobs.executeEffect, artifact, {
      romFs = romFs,
      versionId = versionId,
    }, { key = key, generationId = "unavailable-route" })
    Assert.isFalse(requestOk, key .. " lazy effect request rejects its unavailable route")
    Assert.isTrue(Errors.is(requestErr), key .. " lazy failure remains structured")
    Assert.equal(requestErr.code, "BATTLE_EFFECT_ROUTE_UNAVAILABLE")
    Assert.equal(requestErr.context.effectKey, key, key .. " error identifies the requested route")
    Assert.isTrue(
      requestErr.context.cause ~= nil or requestErr.context.causeCode ~= nil,
      key .. " error retains the selected source failure"
    )
  end
  for programKey in pairs(manifest.programs) do
    Assert.isTrue(programKey:find("transition/", 1, true) ~= 1, "transition callbacks are not invented streams")
    if unavailable[programKey] then
      Assert.equal(manifest.programs[programKey].status, "unavailable")
    else
      Assert.isNil(manifest.programs[programKey].status, "every other published program has a complete source closure")
    end
  end
  for _, root in ipairs(Sources.listSemanticRoots()) do
    local closure = assert(manifest.coverage[root.key], "every source semantic route has a closure: " .. root.key)
    Assert.equal(closure.kind, root.kind)
    if unavailable[root.key] then
      Assert.isNil(closure.closureIdentity, root.key .. " has no fabricated complete closure identity")
    else
      Assert.isTrue(type(closure.closureIdentity) == "string" and #closure.closureIdentity == 40)
    end
  end

  local lastGoodMarker = "previous-global-marker"
  local markerPath = BattlePresentationCache.markerPath()
  local published = {
    [markerPath] = lastGoodMarker,
    [BattlePresentationCache.manifestPath()] = "previous-global-manifest",
  }
  local owned = {}
  local malformedRomFs = {
    version = function()
      return versionId
    end,
    metadata = function()
      return romFs:metadata()
    end,
    openNarc = function(_, symbol)
      if symbol == Sources.LOWER_NARC then
        return nil, Errors.new("TEST_MALFORMED_SOURCE", "synthetic lower-screen source failure", {
          symbol = symbol,
        })
      end
      return romFs:openNarc(symbol)
    end,
  }
  local malformedBundle, malformedErr = Compiler.compileGlobal(malformedRomFs, { versionId = versionId })
  Assert.isNil(malformedBundle, "malformed unapproved global source cannot yield a partial catalog")
  Assert.isTrue(Errors.is(malformedErr), "malformed source remains a structured global import error")
  Assert.equal(malformedErr.code, "TEST_MALFORMED_SOURCE")
  Assert.equal(malformedErr.context.symbol, Sources.LOWER_NARC)

  local globalArtifact = {
    stageFs = function()
      return {
        write = function(_, path, bytes)
          published[path] = bytes
        end,
        writeLua = function(_, path, value)
          published[path] = value
        end,
      }
    end,
    addOwnedRoot = function(_, path)
      owned[path] = true
    end,
  }
  local publicationOk = pcall(ArtifactBattleJobs.executePresentation, globalArtifact, {
    romFs = malformedRomFs,
    versionId = versionId,
  }, { generationId = "malformed-global-source" })
  Assert.isFalse(publicationOk, "malformed unapproved source still fails global publication")
  Assert.equal(published[markerPath], lastGoodMarker, "failed global compilation retains the last good marker")
  Assert.equal(
    published[BattlePresentationCache.manifestPath()],
    "previous-global-manifest",
    "failed global compilation retains the last good catalog"
  )
  Assert.isNil(next(owned), "failed global compilation claims no publication roots")
  Assert.deepEqual(manifest.menus.selectors["menu/bug-contest/initial"], {
    screenGroup = "command",
    textSet = "main",
    mode = "bug-contest",
    phase = "initial",
  })
  Assert.deepEqual(bundle.provenance.frontierTrainerMessageRoute, Sources.FRONTIER_TRAINER_MESSAGE_ROUTE)
  local messageArchive = assert(romFs:openNarc(Sources.FRONTIER_TRAINER_MESSAGE_ROUTE.archive))
  for _, memberId in ipairs({
    Sources.FRONTIER_TRAINER_MESSAGE_ROUTE.profileVersionZero,
    Sources.FRONTIER_TRAINER_MESSAGE_ROUTE.noProfileVersionZero,
  }) do
    local bank = assert(
      require("romdump.src.digest.ui.UiMessageBank").read(
        messageArchive,
        memberId,
        "Frontier trainer message route",
        {},
        "Frontier trainer messages"
      ),
      "Frontier trainer bank member decodes"
    )
    for _, messageId in ipairs({
      Sources.FRONTIER_TRAINER_MESSAGE_ROUTE.trainerMessageString.winOffset,
      Sources.FRONTIER_TRAINER_MESSAGE_ROUTE.trainerMessageString.lossOffset,
    }) do
      Assert.notNil(bank.messages[messageId + 1], "Frontier trainer win/loss message ID is present")
    end
  end
  Assert.equal(
    bundle.provenance.menuSelectors["menu/bug-contest/initial"],
    19,
    "the native route selector stays producer provenance"
  )
end

function T.heartgold_source_routes_publish_a_complete_global_catalog(romFs, versionId)
  heartgoldSourceRoutesPublishCompleteGlobalCatalog(romFs, versionId)
end

function T.heartgold_unavailable_route_requests_return_their_structured_source_cause(romFs, versionId)
  local ArtifactBattleJobs = require("romdump.src.build.ArtifactBattleJobs")
  local cases = {
    CHARGE = { kind = "missing-selected-member", detail = "native route selects an absent animation member" },
    STRUGGLE = {
      kind = "unresolved-selected-branch",
      detail = "native control flow leaves the selected animation member",
    },
    BUG_BITE = { kind = "missing-sound-sequence", detail = "native animation requests an unavailable sound sequence" },
  }
  local artifact = {
    stageFs = function()
      error("unavailable effect requests must fail before staging")
    end,
    addOwnedRoot = function()
      error("unavailable effect requests must not own artifacts")
    end,
  }
  for effectKey, cause in pairs(cases) do
    local ok, err = pcall(ArtifactBattleJobs.executeEffect, artifact, {
      romFs = romFs,
      versionId = versionId,
    }, { key = effectKey, generationId = "unavailable-route" })
    Assert.isFalse(ok, effectKey .. " request fails")
    Assert.isTrue(Errors.is(err), effectKey .. " failure is structured")
    Assert.equal(err.code, "BATTLE_EFFECT_ROUTE_UNAVAILABLE")
    Assert.equal(err.context.effectKey, effectKey)
    Assert.deepEqual(err.context.cause, cause)
  end
end

return RomSuite.build({
  tests = T,
  readyVersions = RomImporter.isReady("heartgold") and { "heartgold" } or {},
  open = RomFs.open,
})
