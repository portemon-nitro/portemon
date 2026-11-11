-- Bounded battle-resource closure over real dumps: representative move roots
-- spanning every geometrically distinct particle family compile their
-- particle systems without rejecting a valid source mode, and every staged
-- particle texture carries the sampler and transparency metadata the shared
-- renderer stages through. HeartGold minimum; SoulSilver runs when ready.

local Assert = require("tests.support.Assert")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSuite = require("tests.rom.support.RomSuite")
local RomSourcePath = require("tests.rom.support.RomSourcePath")

local T = {}

-- One root per geometrically distinct particle family: direct strikers,
-- element breaths and beams, sleep control, vortex pairs, spray and beam
-- water, screen setters, wave pair, and multi-needle scatter.
local REPRESENTATIVE_ROOTS = {
  "TACKLE",
  "EMBER",
  "THUNDERBOLT",
  "SHADOW_BALL",
  "HYPNOSIS",
  "GUST",
  "TWISTER",
  "WATER_GUN",
  "HYPER_BEAM",
  "MIST",
  "REFLECT",
  "SURF",
  "ROCK_SLIDE",
  "PIN_MISSILE",
  "SLUDGE_BOMB",
}

local function compileRoot(compiler, romFs, versionId, effectKey)
  local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, effectKey)
  Assert.isNil(
    err,
    effectKey .. " stages without rejecting a valid particle mode: " .. tostring(err)
  )
  Assert.notNil(effect, effectKey .. " closes through its selected source member")
  return effect
end

function T.representative_roots_stage_complete_particle_resources(romFs, versionId)
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  for _, effectKey in ipairs(REPRESENTATIVE_ROOTS) do
    local effect = compileRoot(compiler, romFs, versionId, effectKey)
    local particleCount = 0
    for resourceKey, descriptor in pairs(effect.resources) do
      if descriptor.kind == "particle" then
        particleCount = particleCount + 1
        local payload = effect.resourcePayloads[descriptor.payload]
        Assert.notNil(payload, effectKey .. " publishes its particle payload for " .. resourceKey)
        Assert.isTrue(
          type(payload.emitters) == "table" and #payload.emitters >= 1,
          effectKey .. " stages every source emitter instead of dropping modes"
        )
        for _, texture in ipairs(payload.textures or {}) do
          Assert.notNil(
            texture.sampler,
            effectKey .. " stages the texture sampler the shared pool keys on"
          )
          Assert.notNil(
            texture.alphaUsage,
            effectKey .. " stages the transparency classification the renderer composites with"
          )
        end
      end
    end
    Assert.isTrue(particleCount >= 1, effectKey .. " stages at least one particle system")
  end
end

function T.staged_particle_quads_use_real_cameras_and_uv_spans(romFs, versionId)
  local SplParticleDraw = require("libs.hgss.src.presentation.SplParticleDraw")
  local SplParticleSimulation = require("libs.hgss.src.presentation.SplParticleSimulation")
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local function expectedSpans(record, child)
    local entry = child or record
    local repS = (entry.texRepeat and entry.texRepeat.s) or 0
    local repT = (entry.texRepeat and entry.texRepeat.t) or 0
    local s, t = 2 ^ repS, 2 ^ repT
    if type(entry.reverseTex) == "table" then
      if entry.reverseTex.s then
        s = -s
      end
      if entry.reverseTex.t then
        t = -t
      end
    end
    return s, t
  end
  for _, effectKey in ipairs(REPRESENTATIVE_ROOTS) do
    local effect = compileRoot(compiler, romFs, versionId, effectKey)
    for resourceKey, descriptor in pairs(effect.resources) do
      if descriptor.kind == "particle" then
        local payload = effect.resourcePayloads[descriptor.payload]
        local sim = SplParticleSimulation.new({ state = 0 }, 0, payload.emitters)
        for ordinal = 0, #payload.emitters - 1 do
          sim:addEmitter(ordinal, nil)
        end
        local seenSpans = {}
        local seenCyclingId = false
        local maxWidth = 0
        local liveTicks = 0
        for _ = 1, 120 do
          sim:advance(nil)
          local primitives = SplParticleDraw.appendPrimitives(sim, nil, function()
            return nil
          end, {})
          if #primitives >= 1 then
            liveTicks = liveTicks + 1
          end
          for _, primitive in ipairs(primitives) do
            local width = math.abs(primitive.vertices[2].clipX - primitive.vertices[1].clipX)
            if width > maxWidth then
              maxWidth = width
            end
            if primitive.polygonId ~= 5 then
              seenCyclingId = true
            end
            seenSpans[primitive.vertices[3].u .. "x" .. primitive.vertices[3].v] = true
          end
        end
        Assert.isTrue(liveTicks >= 1, effectKey .. " produces live clip quads for " .. resourceKey)
        Assert.isTrue(
          maxWidth > 10,
          effectKey .. " projects real widths instead of unit placeholders"
        )
        Assert.isTrue(seenCyclingId, effectKey .. " cycles polygon identities past the fixed entry")
        for _, emitter in ipairs(payload.emitters) do
          local s, t = expectedSpans(emitter, nil)
          Assert.isTrue(
            seenSpans[s .. "x" .. t] == true,
            effectKey .. " emits the exact parent uv span " .. s .. "x" .. t
          )
          if emitter.child ~= nil then
            local cs, ct = expectedSpans(emitter, emitter.child)
            Assert.isTrue(
              seenSpans[cs .. "x" .. ct] == true,
              effectKey .. " emits the exact child uv span " .. cs .. "x" .. ct
            )
          end
        end
      end
    end
  end
end

function T.staged_particle_textures_keep_effective_texel_identity(romFs, versionId)
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local effect = compileRoot(compiler, romFs, versionId, "TACKLE")
  for resourceKey, descriptor in pairs(effect.resources) do
    if descriptor.kind == "particle" then
      local payload = effect.resourcePayloads[descriptor.payload]
      for _, texture in ipairs(payload.textures or {}) do
        local staged = effect.resources[texture.image]
        Assert.notNil(staged, "each TACKLE particle texture stays staged as a resource")
        local pixels = effect.resourcePayloads[staged.payload]
        Assert.notNil(pixels, "each TACKLE particle texture keeps its pixel payload")
      end
    end
  end
end

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
