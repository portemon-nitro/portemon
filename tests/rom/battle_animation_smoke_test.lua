-- Fast ROM-backed smoke cover for battle-animation closure: a handful of
-- moves that failed before (selector gaps, callback config trailers,
-- defender knockback framing) close through compileEffect without building
-- the global catalog or stepping traces, three independently corrected
-- roots keep their own selected members, and one particle move proves its
-- emitters normalize with exact drawable textures. The component compiler
-- tests pin framing rules, this pins end-to-end ROM closure; the
-- exhaustive root-by-root audit lives in battle_effect_closure_census_test.

local Assert = require("tests.support.Assert")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSuite = require("tests.rom.support.RomSuite")
local RomSourcePath = require("tests.rom.support.RomSourcePath")

local T = {}

local SMOKE_EFFECTS = {
  "WHIRLWIND",
  "ROAR",
  "MEGAHORN",
  "SHADOW_PUNCH",
  "EXTRASENSORY",
  "GUST",
}

-- Roots whose member routing was corrected independently of the six above.
-- Each must keep closing through its own selected source member.
local CORRECTED_EFFECTS = {
  "EXTREME_SPEED",
  "CHARGE_BEAM",
  "WATER_PULSE",
}

local function hasTaskKind(effect, kind)
  local program = effect.program
  if type(program) ~= "table" or type(program.taskKinds) ~= "table" then
    return false
  end
  for _, taskKind in ipairs(program.taskKinds) do
    if taskKind == kind then
      return true
    end
  end
  return false
end

-- Every selected effect must close through its own routed member with a
-- staged program, staged dependency payloads, and task kinds the live
-- native factory admits. Shared fallbacks would collapse distinct roots
-- onto one member route, so the routed archive/member identity is pinned.
local function assertEffectClosesThroughItsSelectedMember(compiler, factory, sources, romFs, versionId, effectKey)
  local route = assert(sources.resolveSemanticRoute(effectKey), effectKey .. " keeps its semantic source route")
  local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, effectKey)
  Assert.isNil(err, effectKey .. " closes without a source failure: " .. tostring(err))
  Assert.notNil(effect, effectKey .. " closes through its selected source member")
  Assert.equal(effect.key, effectKey, effectKey .. " closure carries its semantic key")
  Assert.equal(
    effect.provenance.archiveSymbol,
    route.archiveSymbol,
    effectKey .. " closure reads its own routed archive"
  )
  Assert.equal(effect.provenance.memberId, route.memberId, effectKey .. " closure reads its own routed member")
  Assert.isTrue(type(effect.program) == "table", effectKey .. " closure carries its program")
  Assert.isTrue(type(effect.resources) == "table", effectKey .. " closure carries its staged resources")
  Assert.isTrue(type(effect.requiredContext) == "table", effectKey .. " closure declares its typed runtime inputs")
  Assert.isTrue(
    type(effect.program.taskKinds) == "table" and #effect.program.taskKinds >= 1,
    effectKey .. " closure stages at least one native task kind"
  )
  for _, taskKind in ipairs(effect.program.taskKinds) do
    Assert.isTrue(
      factory.supportsKind(taskKind),
      effectKey .. " stages an admitted native task kind: " .. tostring(taskKind)
    )
  end
  for resourceKey, descriptor in pairs(effect.resources) do
    Assert.notNil(
      effect.resourcePayloads[descriptor.payload],
      effectKey .. " stages the payload for resource " .. tostring(resourceKey)
    )
  end
  return effect
end

function T.previously_failing_effects_close_through_compile(romFs, versionId)
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  local sources = require("romdump.src.config.BattleAnimationSources")
  for _, effectKey in ipairs(SMOKE_EFFECTS) do
    assertEffectClosesThroughItsSelectedMember(compiler, factory, sources, romFs, versionId, effectKey)
  end
  local whirlwind, whirlwindErr = compiler.compileEffect(romFs, { versionId = versionId }, "WHIRLWIND")
  Assert.isNil(whirlwindErr, "WHIRLWIND closure carries no error for the task-kind probe")
  Assert.isTrue(
    hasTaskKind(whirlwind, "pokemon-picture-linear-offscreen-transition"),
    "WHIRLWIND stages its defender offscreen slide"
  )
  Assert.isTrue(
    hasTaskKind(whirlwind, "pokemon-picture-reset-position-transition"),
    "WHIRLWIND stages its defender reset marker"
  )
  local shadowPunch, shadowPunchErr = compiler.compileEffect(romFs, { versionId = versionId }, "SHADOW_PUNCH")
  Assert.isNil(shadowPunchErr, "SHADOW_PUNCH closure carries no error for the task-kind probe")
  Assert.isTrue(
    hasTaskKind(shadowPunch, "pokemon-picture-attacker-dash-afterimages"),
    "SHADOW_PUNCH stages its attacker dash hold"
  )
end

function T.independently_corrected_effects_keep_their_own_selected_members(romFs, versionId)
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  local sources = require("romdump.src.config.BattleAnimationSources")
  local seenMembers = {}
  for _, effectKey in ipairs(CORRECTED_EFFECTS) do
    local effect = assertEffectClosesThroughItsSelectedMember(compiler, factory, sources, romFs, versionId, effectKey)
    local memberId = effect.provenance.memberId
    Assert.isNil(seenMembers[memberId], effectKey .. " does not share a fallback member with another corrected root")
    seenMembers[memberId] = effectKey
  end
end

-- The three staged particle effects load their SPL member as one particle
-- system payload: compiled emitters, exact RGBA textures, and the retail
-- emitter placement table the creation callbacks index. TACKLE and SUPERSONIC
-- are move effects; the sleep status carries the asleep member.
local PARTICLE_EFFECTS = {
  { key = "TACKLE", resource = "battle/particle/tackle", emitters = 2 },
  { key = "SUPERSONIC", resource = "battle/particle/supersonic", emitters = 1 },
  { key = "BATTLE_ANIMATION_ASLEEP", resource = "battle/particle/asleep", emitters = 10 },
}

function T.particle_effects_stage_compiled_emitters_textures_and_placements(romFs, versionId)
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  local sources = require("romdump.src.config.BattleAnimationSources")
  for _, expected in ipairs(PARTICLE_EFFECTS) do
    local effect =
      assertEffectClosesThroughItsSelectedMember(compiler, factory, sources, romFs, versionId, expected.key)
    local descriptor = effect.resources[expected.resource]
    Assert.notNil(descriptor, expected.key .. " stages its particle system")
    Assert.equal(descriptor.kind, "particle", expected.key .. " keeps the particle kind")
    local payload = effect.resourcePayloads[descriptor.payload]
    Assert.equal(#payload.emitters, expected.emitters, expected.key .. " stages every source emitter")
    Assert.isTrue(#payload.textures >= 1, expected.key .. " stages its textures")
    for _, texture in ipairs(payload.textures) do
      local staged = effect.resources[texture.image]
      Assert.notNil(staged, expected.key .. " stages each particle texture as a resource")
      local pixels = effect.resourcePayloads[staged.payload]
      Assert.equal(#pixels.rgba8888, pixels.width * pixels.height * 4, "a particle texture is exact RGBA")
    end
    if expected.key == "TACKLE" then
      -- sBattleAnimEmitterPositions[solo player][kind 0][perspective 0]
      -- is the first retail vector: x -9616, y -5464 in 1/4096 world units.
      Assert.near(payload.placements["solo-player"][1][1].x, -9616 / 4096, 1e-9, "the placement table keeps the retail x")
      Assert.near(payload.placements["solo-player"][1][1].y, -5464 / 4096, 1e-9, "the placement table keeps the retail y")
    end
  end
end

-- Each ready dump runs the smoke on its own reader; a version without a
-- ready dump is absent from the run, never reported as covered.
local readyVersions = {}
for _, versionId in ipairs(GameVersion.ORDER) do
  if RomImporter.isReady(versionId) then
    readyVersions[#readyVersions + 1] = versionId
  end
end

return RomSuite.build({
  tests = T,
  readyVersions = readyVersions,
  open = RomSourcePath.openReader,
})
