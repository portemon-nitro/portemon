-- Battle-family artifact jobs bind existing compilers and cache writers to the central worker protocol.
local ArtifactBattleJobs = {}

-- Battle input families stage their whole semantic payload plus a
-- completion marker; readiness revalidates the staged payload through its
-- semantic schema. Dependencies name the semantic identity catalogs the
-- projection resolves against (species/move/item keys).
---@return { kind: string, key: string }[], boolean
local function dependenciesBattleData()
  return { { kind = "mon-catalog", key = "global" }, { kind = "items", key = "global" } }, true
end

---@return { kind: string, key: string }[], boolean
local function dependenciesTrainers()
  return { { kind = "mon-catalog", key = "global" }, { kind = "items", key = "global" } }, true
end

---@return { kind: string, key: string }[], boolean
local function dependenciesEncounters()
  return { { kind = "mon-catalog", key = "global" } }, true
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@param family string
---@param compile fun(romFs: table<string, unknown>, versionId: string): table<string, unknown>?, unknown
---@param payloadPath string
---@param markerPath string
---@param mark fun(romSha1: string, depHash: string): string
---@return string compiler marker for the receipt
local function executeBattleFamily(artifact, context, job, family, compile, payloadPath, markerPath, mark)
  local Hashing = require("romdump.src.digest.Hashing")
  local romFs = assert(context.romFs, family .. " jobs require a source reader")
  local versionId = assert(context.versionId, family .. " jobs require a version")
  local compiled, compileErr = compile(romFs, versionId)
  if compiled == nil then
    error(family .. " emission failed for generation " .. job.generationId .. ": " .. tostring(compileErr), 0)
  end
  assert(compiled ~= nil, family .. " emission produced no payload")
  local stage = artifact:stageFs()
  artifact:addOwnedRoot(payloadPath)
  artifact:addOwnedRoot(markerPath)
  stage:writeLua(payloadPath, compiled)
  local metadata = romFs:metadata()
  local marker = mark(metadata.sha1, Hashing.hashLua(compiled))
  stage:write(markerPath, marker)
  return marker
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string
local function executeBattleDataJob(artifact, context, job)
  local BattleDataCompiler = require("romdump.src.digest.battle.BattleDataCompiler")
  local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
  local function compile(romFs, versionId)
    return BattleDataCompiler.compileFromDump(romFs, { versionId = versionId })
  end
  return executeBattleFamily(
    artifact,
    context,
    job,
    "battle-data",
    compile,
    BattleDataCache.battleDataPath(),
    BattleDataCache.battleDataMarkerPath(),
    BattleDataCache.marker
  )
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string
local function executeTrainersJob(artifact, context, job)
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
  local function compile(romFs, versionId)
    return TrainerCatalogCompiler.compileFromDump(romFs, { versionId = versionId })
  end
  return executeBattleFamily(
    artifact,
    context,
    job,
    "trainers",
    compile,
    BattleDataCache.trainersPath(),
    BattleDataCache.trainersMarkerPath(),
    BattleDataCache.trainersMarker
  )
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string
local function executeEncountersJob(artifact, context, job)
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
  local function compile(romFs, versionId)
    return EncounterCatalogCompiler.compileFromDump(romFs, { versionId = versionId })
  end
  return executeBattleFamily(
    artifact,
    context,
    job,
    "encounters",
    compile,
    BattleDataCache.encountersPath(),
    BattleDataCache.encountersMarkerPath(),
    BattleDataCache.encountersMarker
  )
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateBattleData(check)
  local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
  return BattleDataCache.isBattleDataReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateTrainers(check)
  local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
  return BattleDataCache.isTrainersReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateEncounters(check)
  local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
  return BattleDataCache.isEncountersReady(check.cacheFs, check.marker)
end

-- Battle presentation families stage validated semantic pixels through the
-- existing worker: the global job compiles the shared menu/HUD definitions
-- once, and each scene job compiles exactly its validated scene key on top
-- of the staged global. Scene keys are validated semantic keys, never
-- filesystem paths.
---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string compiler marker for the receipt
local function executeBattlePresentationJob(artifact, context, job)
  local BattlePresentationCompiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local romFs = assert(context.romFs, "battle presentation jobs require a source reader")
  local versionId = assert(context.versionId, "battle presentation jobs require a version")
  local bundle, compileErr = BattlePresentationCompiler.compileGlobal(romFs, { versionId = versionId })
  if bundle == nil then
    error("battle presentation emission failed for generation " .. job.generationId .. ": " .. tostring(compileErr), 0)
  end
  assert(bundle ~= nil, "battle presentation emission produced no bundle")
  local metadata = romFs:metadata()
  return BattlePresentationCompiler.stageGlobal(
    artifact,
    bundle,
    BattlePresentationCompiler.globalMarker(metadata.sha1, bundle)
  )
end

---@param key string semantic scene key
---@param plans ArtifactJobs.Plans
---@return { kind: string, key: string }[], boolean
local function dependenciesBattleScene(key, plans)
  assert(type(plans) == "table", "dependency edges require the session plans")
  local Sources = require("romdump.src.config.BattlePresentationSources")
  assert(Sources.validateSceneKey(key), "invalid battle scene key: " .. tostring(key))
  return { { kind = "battle-presentation", key = "global" } }, true
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string compiler marker for the receipt
local function executeBattleSceneJob(artifact, context, job)
  local BattlePresentationCompiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local romFs = assert(context.romFs, "battle scene jobs require a source reader")
  local versionId = assert(context.versionId, "battle scene jobs require a version")
  local scene, compileErr = BattlePresentationCompiler.compileScene(romFs, { versionId = versionId }, job.key)
  if scene == nil then
    error("battle scene emission failed for generation " .. job.generationId .. ": " .. tostring(compileErr), 0)
  end
  assert(scene ~= nil, "battle scene emission produced no scene")
  local metadata = romFs:metadata()
  return BattlePresentationCompiler.stageScene(
    artifact,
    scene,
    BattlePresentationCompiler.sceneMarker(metadata.sha1, scene)
  )
end

---@param key string semantic effect key without slashes
---@param plans ArtifactJobs.Plans
---@return { kind: string, key: string }[], boolean
local function dependenciesBattleEffect(key, plans)
  assert(type(plans) == "table", "dependency edges require the session plans")
  assert(
    type(key) == "string" and key ~= "" and key:find("/", 1, true) == nil,
    "invalid battle effect key: " .. tostring(key)
  )
  return { { kind = "battle-presentation", key = "global" } }, true
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string compiler marker for the receipt
local function executeBattleEffectJob(artifact, context, job)
  local BattlePresentationCompiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local Errors = require("libs.errors.src.Errors")
  local romFs = assert(context.romFs, "battle effect jobs require a source reader")
  local versionId = assert(context.versionId, "battle effect jobs require a version")
  local effect, compileErr = BattlePresentationCompiler.compileEffect(romFs, { versionId = versionId }, job.key)
  if effect == nil then
    if Errors.is(compileErr) then
      error(compileErr, 0)
    end
    error("battle effect emission failed for generation " .. job.generationId .. ": " .. tostring(compileErr), 0)
  end
  assert(effect ~= nil, "battle effect emission produced no effect")
  local metadata = romFs:metadata()
  return BattlePresentationCompiler.stageEffect(
    artifact,
    effect,
    BattlePresentationCompiler.effectMarker(metadata.sha1, effect)
  )
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateBattleEffect(check)
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local record, _ = BattlePresentationCache.loadEffect(check.cacheFs, check.key)
  if record == nil then
    return false
  end
  return check.cacheFs:read(BattlePresentationCache.effectMarkerPath(check.key)) == check.marker
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateBattlePresentation(check)
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  return BattlePresentationCache.isGlobalReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateBattleScene(check)
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  return BattlePresentationCache.isSceneReady(check.cacheFs, check.key, check.marker)
end

ArtifactBattleJobs.dependenciesBattleData = dependenciesBattleData
ArtifactBattleJobs.dependenciesTrainers = dependenciesTrainers
ArtifactBattleJobs.dependenciesEncounters = dependenciesEncounters
ArtifactBattleJobs.executeBattleData = executeBattleDataJob
ArtifactBattleJobs.executeTrainers = executeTrainersJob
ArtifactBattleJobs.executeEncounters = executeEncountersJob
ArtifactBattleJobs.validateBattleData = validateBattleData
ArtifactBattleJobs.validateTrainers = validateTrainers
ArtifactBattleJobs.validateEncounters = validateEncounters
ArtifactBattleJobs.executePresentation = executeBattlePresentationJob
ArtifactBattleJobs.dependenciesScene = dependenciesBattleScene
ArtifactBattleJobs.executeScene = executeBattleSceneJob
ArtifactBattleJobs.validatePresentation = validateBattlePresentation
ArtifactBattleJobs.validateScene = validateBattleScene
ArtifactBattleJobs.dependenciesEffect = dependenciesBattleEffect
ArtifactBattleJobs.executeEffect = executeBattleEffectJob
ArtifactBattleJobs.validateEffect = validateBattleEffect

return ArtifactBattleJobs
