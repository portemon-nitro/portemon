-- Native particle fidelity at the production task boundary: pinned
-- particle members resolve to their own semantic resources, creation words
-- carry their system slot and emitter ordinal, the source clock advances
-- effect age deterministically while reads stay free of side effects, and a
-- staged particle system runs through the real player, task factory, and
-- production resource holder: emitters take their callback placement, the
-- effects wait holds until the emitters retire, and every lease returns once.
-- Native mechanism: battle_anim_system.c LoadParticleSystem, CreateEmitter,
-- WaitForParticles, and FreeParticleSystem over the SPL library
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Headless: synthetic command streams use the real producer lowering and
-- the shared program shape; staged particle payloads stand in for the ROM
-- members, whose compilation tests/rom/battle_animation_smoke_test pins.

local Assert = require("tests.support.Assert")
local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")
local BattleAnimationSources = require("romdump.src.config.BattleAnimationSources")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local BattleParticleLeaseFixture = require("tests.support.BattleParticleLeaseFixture")
local BattleParticleSystems = require("libs.hgss.src.presentation.BattleParticleSystems")
local EffectStagingFixture = require("tests.support.EffectStagingFixture")

local T = {}

local function u32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function streamOf(list)
  local parts = {}
  for _, word in ipairs(list) do
    parts[#parts + 1] = u32(word)
  end
  return table.concat(parts)
end

local function lowered(key, list)
  local program = assert(BattleAnimationCompiler.compile({ key = key, stream = streamOf(list) }))
  Assert.isTrue(
    BattleAnimationSchema.assertProgram({
      entry = program.entry,
      instructions = program.instructions,
      subprograms = program.subprograms,
      taskKinds = program.taskKinds,
    }),
    "the lowered program validates against the shared program shape"
  )
  return program
end

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

local function effectFactoryModule()
  local ok, Factory = pcall(require, "libs.hgss.src.presentation.BattleEffectTasks")
  Assert.isTrue(ok, "the battle-private effect task factory resolves through the presentation boundary")
  Assert.equal(type(Factory.create), "function", "the factory exposes its task construction entry point")
  return Factory
end

function T.pinned_particle_members_resolve_to_their_own_semantic_resources()
  Assert.equal(
    BattleAnimationSources.resolveParticleResource(64),
    "battle/particle/tackle",
    "the striking particle keeps its semantic resource"
  )
  Assert.equal(
    BattleAnimationSources.resolveParticleResource(27),
    "battle/particle/asleep",
    "the sleep particle keeps its semantic resource"
  )
  Assert.equal(
    BattleAnimationSources.resolveParticleResource(79),
    "battle/particle/supersonic",
    "the confusion particle keeps its semantic resource"
  )
  Assert.isNil(BattleAnimationSources.resolveParticleResource(0), "an unmapped member resolves to nothing")
  Assert.notNil(
    BattleAnimationSources.resolveParticleSource("battle/particle/tackle"),
    "the striking resource keeps its producer-side source detail"
  )
end

function T.particle_creation_lowers_with_its_system_slot_and_resource()
  local foe = lowered("particle-foe-system", { 51, 1, 64, 50, 4 })
  Assert.equal(foe.instructions[1].op, "create-battler-effect", "the load word keeps its own operation")
  Assert.equal(foe.instructions[1].systemIndex, 1, "the load names the system slot, never a battler")
  Assert.isNil(foe.instructions[1].emitterPosition, "no battler position is derived from the slot")
  Assert.equal(foe.instructions[1].resource, "battle/particle/tackle", "the system keeps its semantic resource")
  Assert.equal(foe.instructions[1].taskKind, "battle-particle-system", "the load spawns a particle system task")
  local ally = lowered("particle-ally-system", { 51, 0, 27, 50, 4 })
  Assert.equal(ally.instructions[1].systemIndex, 0, "the second load names its own slot")
  Assert.equal(ally.instructions[1].resource, "battle/particle/asleep", "the system keeps its own semantic resource")
  Assert.isTrue(
    foe.instructions[1].resource ~= ally.instructions[1].resource,
    "two systems never share one collapsed resource"
  )
end

function T.source_ticks_advance_effect_age_deterministically_and_reads_stay_pure()
  local first = sceneWithPair()
  local second = sceneWithPair()
  local firstEffect = first:allocEffect("particle-probe")
  local secondEffect = second:allocEffect("particle-probe")
  for _ = 1, 10 do
    for _ = 1, 3 do
      first:effectViews()
    end
    first:stepSourceTick()
    second:stepSourceTick()
  end
  local function ageOf(scene, id)
    for _, view in ipairs(scene:effectViews()) do
      if view.id == id then
        return view.age
      end
    end
    return nil
  end
  Assert.equal(ageOf(first, firstEffect.id), 10, "ten accepted ticks age the effect by ten")
  Assert.equal(
    ageOf(first, firstEffect.id),
    ageOf(second, secondEffect.id),
    "the same tick count gives the same age on both scenes"
  )
  for _ = 1, 5 do
    first:stepSourceTick()
  end
  Assert.equal(ageOf(first, firstEffect.id), 15, "further ticks advance the age by exactly their count")
end

local PROBE_ARCHIVE_KEY = "battle/particle/tackle"
local PROBE_TEXTURE_KEY = "battle/particle/texture/probe-0"
local PROBE_ARCHIVE_PATH = "effects/probe-tackle-archive.lua"
local PROBE_TEXTURE_PATH = "effects/probe-tackle-texture.lua"
local PROBE_TEXTURE_WIDTH = 8
local PROBE_TEXTURE_HEIGHT = 8

local function recordingProductionHost()
  local host = { asks = {}, answers = {} }
  local derived = {}
  function derived.requestBattleEffect(key, urgency)
    host.asks[#host.asks + 1] = { key = key, urgency = urgency }
    if host.answers[key] ~= nil then
      return true
    end
    return nil
  end
  host.derivedAssets = derived
  return host
end

local function productionEnvelope(cache, host)
  local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local text = {}
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(_) end
  local windows = {}
  function windows.drawWindow(_, _, _) end
  return FieldBattlePresentation.new({
    cacheFs = cache,
    windows = windows,
    text = text,
    measureDisplay = function()
      return {
        width = 256,
        height = 384,
        topology = ScreenTopology.dualDisplay(
          { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
          { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
        ),
        pixelRatio = 1,
        signature = "production-lease-probe:dual",
      }
    end,
    derivedAssets = host.derivedAssets,
  })
end

local function productionHolder(services, launchId)
  local BattlePresentationAssets = require("game.hgss.src.battle.BattlePresentationAssets")
  local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
  return BattlePresentationAssets.new({
    assets = services,
    launchId = launchId,
    sceneKey = "general/plain/day",
    shadowRegions = BattlePresentationManifestFixture.manifest().pictures.shadow.regions,
  })
end

local function probeEffectRecord(archivePath, texturePath, archiveIdentity, textureIdentity)
  return {
    schema = BattleAnimationSchema.EFFECT_SCHEMA,
    key = "TACKLE",
    catalogIdentity = "probe-catalog",
    program = {
      entry = "main",
      instructions = {
        {
          op = "create-battler-effect",
          resource = PROBE_ARCHIVE_KEY,
          systemIndex = 0,
          taskKind = "battle-particle-system",
        },
        { op = "wait-interpreter-counter", cursorRule = "pending-redispatch-current-opcode; zero-advances-past-current-opcode", branchTarget = 2 },
        {
          op = "create-parameterized-battler-effect",
          actionProfile = "particle-emitter-target-battler-relative",
          systemIndex = 0,
          emitter = 0,
          taskKind = "battler-effect-continuation",
        },
        { op = "wait-for-battler-effects", cursorRule = "advance-when-effects-finish" },
        { op = "destroy-battler-effect", values = { 0 } },
      },
      subprograms = {},
      taskKinds = { "battle-particle-system", "battler-effect-continuation" },
    },
    dependencies = { PROBE_ARCHIVE_KEY, PROBE_TEXTURE_KEY },
    resources = {
      [PROBE_ARCHIVE_KEY] = {
        kind = "particle",
        payload = archivePath,
        contentIdentity = archiveIdentity,
      },
      [PROBE_TEXTURE_KEY] = {
        kind = "texture",
        payload = texturePath,
        contentIdentity = textureIdentity,
      },
    },
    requiredContext = {},
  }
end

local function probeArchivePayload()
  local payload = BattleParticleLeaseFixture.payload(1)
  payload.textures[1].image = PROBE_TEXTURE_KEY
  payload.emitters[1].particleLife = 12
  return payload
end

local function stageProductionTackle(cache, archivePayloadOverride, texturePayloadOverride)
  local Hashing = require("romdump.src.digest.Hashing")
  local textureBytes = EffectStagingFixture.rgba(PROBE_TEXTURE_WIDTH, PROBE_TEXTURE_HEIGHT)
  local textureIdentity = Hashing.sha1hex(textureBytes)
  local archivePayload = archivePayloadOverride or probeArchivePayload()
  local archiveIdentity = Hashing.sha1hex(textureBytes .. "probe-tackle-archive")
  local record = probeEffectRecord(PROBE_ARCHIVE_PATH, PROBE_TEXTURE_PATH, archiveIdentity, textureIdentity)
  cache:writeLua(BattlePresentationCache.effectPath("TACKLE"), record)
  cache:write(BattlePresentationCache.effectMarkerPath("TACKLE"), "probe-marker")
  cache:writeLua(PROBE_ARCHIVE_PATH, archivePayload)
  cache:writeLua(PROBE_TEXTURE_PATH, texturePayloadOverride or {
    width = PROBE_TEXTURE_WIDTH,
    height = PROBE_TEXTURE_HEIGHT,
    rgba8888 = textureBytes,
  })
  return {
    record = record,
    archive = archivePayload,
    textureBytes = textureBytes,
    archiveIdentity = archiveIdentity,
    textureIdentity = textureIdentity,
  }
end

local function demandProductionTackle(launchId)
  local FakeCache = require("tests.support.FakeCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local cache = CacheFs.forVersion("probe-particle-production", FakeCache.new())
  local staged = stageProductionTackle(cache)
  local host = recordingProductionHost()
  host.answers["TACKLE"] = true
  local envelope = productionEnvelope(cache, host)
  local services = envelope:_preparationServices()
  local owned = productionHolder(services, launchId)
  Assert.equal(owned:demandEffect("TACKLE"), true, "the closed staged effect reads ready")
  local effect = owned:loadEffect("TACKLE")
  Assert.notNil(effect, "the ready effect loads before resolving")
  return { cache = cache, staged = staged, host = host, envelope = envelope, owned = owned, effect = effect }
end

local function journaledHolderServices(owned, effect, journal)
  local services = {}
  function services.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    return owned:resolveEffectResource(effect, key)
  end
  function services.release(lease)
    journal.released[#journal.released + 1] = type(lease) == "table" and lease.key or lease
    return owned:releaseEffectResource(lease)
  end
  return services
end

local function assertJournalBalanced(journal, what)
  local released = {}
  for _, key in ipairs(journal.released) do
    released[key] = (released[key] or 0) + 1
  end
  local acquired = {}
  for _, key in ipairs(journal.acquired) do
    acquired[key] = (acquired[key] or 0) + 1
  end
  for key, count in pairs(acquired) do
    Assert.equal(released[key] or 0, count, what .. " releases " .. tostring(key) .. " exactly once per acquire")
  end
  for key in pairs(released) do
    Assert.notNil(acquired[key], what .. " never releases unacquired " .. tostring(key))
  end
end

local function productionPlayback(effectKey)
  return {
    launchId = "production-lease-probe",
    packetId = 1,
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = effectKey },
    visualSeed = 4242,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
  }
end

local function runPlayerToSettled(player, handle, limit)
  for _ = 1, limit or 600 do
    player:stepSourceTick({ tick = 1 })
    local status = player:status(handle)
    if status == "complete" or status == "failed" then
      return status
    end
  end
  return player:status(handle)
end

local function productionPlayback(effectKey)
  return {
    launchId = "production-lease-probe",
    packetId = 1,
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = effectKey },
    visualSeed = 4242,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
  }
end

local function runPlayerToSettled(player, handle, limit)
  for _ = 1, limit or 600 do
    player:stepSourceTick({ tick = 1 })
    local status = player:status(handle)
    if status == "complete" or status == "failed" then
      return status
    end
  end
  return player:status(handle)
end

-- The production resolver decodes the staged system instead of handing out
-- its path: the player loads it, the emitter takes the defender placement,
-- the effects wait holds until the emitter retires, the script frees the
-- system, and every lease returns exactly once.
function T.production_particle_lease_decodes_staged_records_and_completes()
  local probe = demandProductionTackle("probe-particle-production")
  local owned, effect = probe.owned, probe.effect
  Assert.equal(
    effect.resources[PROBE_ARCHIVE_KEY].payload,
    PROBE_ARCHIVE_PATH,
    "the generated descriptor keeps naming the staged path"
  )
  local lease = owned:resolveEffectResource(effect, PROBE_ARCHIVE_KEY)
  Assert.notNil(lease, "the system admits through the production holder")
  Assert.equal(lease.kind, "particle", "the system lease keeps its semantic kind")
  Assert.equal(lease.payloadPath, PROBE_ARCHIVE_PATH, "the runtime lease names its staged path separately")
  Assert.isNil(lease.payload, "the runtime lease never conflates the path field with decoded content")
  Assert.equal(lease.contentIdentity, probe.staged.archiveIdentity, "the lease carries its content identity")
  Assert.deepEqual(lease.data, probe.staged.archive, "the decoded lease matches the staged system")
  local texture = owned:resolveEffectResource(effect, PROBE_TEXTURE_KEY)
  Assert.notNil(texture, "the texture admits beside the system")
  Assert.equal(texture.rgba8888, probe.staged.textureBytes, "the texture lease shares its exact staged bytes")
  owned:releaseEffectResource(lease)
  owned:releaseEffectResource(texture)
  local Factory = effectFactoryModule()
  local Player = require("libs.hgss.src.presentation.BattleAnimationPlayer")
  local scene = sceneWithPair()
  local audio = {}
  function audio.play(_) end
  function audio.stop(_) end
  function audio.isFinished(_)
    return true
  end
  local journal = { acquired = {}, released = {} }
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = journaledHolderServices(owned, effect, journal),
    tasks = Factory,
    splRandomState = { state = 0 },
    services = {
      onNativeFrame = function(phase, sourceTick)
        if phase == "draw" then
          local BattleParticleSystems = require("libs.hgss.src.presentation.BattleParticleSystems")
          BattleParticleSystems.stepSourceDrawPhase(scene, sourceTick)
          scene:stepAnimationPictures(sourceTick)
        end
      end,
    },
  }))
  local handle = assert(player:start(productionPlayback("TACKLE"), effect.program))
  local sawSystem, sawEmitter = false, false
  for _ = 1, 600 do
    player:stepSourceTick({ tick = 1 })
    local systems = scene:particleSystems()
    if #systems > 0 then
      sawSystem = true
      local emitters = systems[1].simulation.emitters
      if #emitters > 0 then
        sawEmitter = true
        -- Fresh occurrences default all systems to perspective projection,
        -- so the emitter takes the perspective (second staged) vector.
        Assert.equal(
          emitters[1].x,
          BattleParticleLeaseFixture.payload().placements["solo-enemy"][1][2].x,
          "the emitter takes the defender placement under default perspective"
        )
        Assert.equal(player:status(handle), "waiting", "the effects wait holds while the emitter lives")
      end
    end
    if player:status(handle) == "complete" or player:status(handle) == "failed" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "the production-fed run reaches its own completion")
  Assert.isTrue(sawSystem and sawEmitter, "the run published a live system with a live emitter")
  Assert.equal(#scene:particleSystems(), 0, "the script's free drops the system from the scene")
  player:dispose()
  assertJournalBalanced(journal, "the settled production run")
  Assert.deepEqual(
    probe.host.asks,
    { { key = "TACKLE", urgency = "required" } },
    "only the selected effect is demanded"
  )
  owned:dispose()
  owned:dispose()
  local stale, staleErr = owned:resolveEffectResource(effect, PROBE_ARCHIVE_KEY)
  Assert.isNil(stale, "a stale resolve after disposal publishes nothing")
  Assert.isTrue(type(staleErr) == "string" and staleErr ~= "", "the stale resolve names its disposal")
  probe.envelope:dispose()
end

-- A staged path that decodes to nothing is terminal with provenance: the
-- resolver names the effect, the resource, and the path instead of
-- handing the task a descriptor it will misread as data.
function T.production_resolver_names_effect_key_and_path_for_broken_payloads()
  local FakeCache = require("tests.support.FakeCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local cache = CacheFs.forVersion("probe-broken-payload", FakeCache.new())
  stageProductionTackle(cache)
  cache:write(PROBE_ARCHIVE_PATH, "garbage-bytes-are-no-record")
  local host = recordingProductionHost()
  host.answers["TACKLE"] = true
  local envelope = productionEnvelope(cache, host)
  local owned = productionHolder(envelope:_preparationServices(), "probe-broken-payload")
  Assert.equal(owned:demandEffect("TACKLE"), true, "a present path still reads ready before decoding")
  local effect = owned:loadEffect("TACKLE")
  Assert.notNil(effect, "the ready effect loads before resolving")
  local lease, failure = owned:resolveEffectResource(effect, PROBE_ARCHIVE_KEY)
  Assert.isNil(lease, "the undecodable system hands out no lease")
  Assert.isTrue(type(failure) == "string" and failure ~= "", "the undecodable system carries its reason")
  local reason = failure --[[@as string]]
  Assert.isTrue(reason:find("TACKLE", 1, true) ~= nil, "the failure names its effect: " .. reason)
  Assert.isTrue(reason:find(PROBE_ARCHIVE_KEY, 1, true) ~= nil, "the failure names its resource: " .. reason)
  Assert.isTrue(reason:find(PROBE_ARCHIVE_PATH, 1, true) ~= nil, "the failure names its path: " .. reason)
  owned:dispose()
  envelope:dispose()
end

-- A system task staged against a non-particle lease fails at construction
-- with the resource key: textures never masquerade as particle systems.
function T.particle_system_rejects_non_particle_leases_with_provenance()
  local probe = demandProductionTackle("probe-wrong-kind")
  local Factory = effectFactoryModule()
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local services =
    { scene = scene, audio = {}, resources = journaledHolderServices(probe.owned, probe.effect, journal) }
  local built, failure = pcall(Factory.create, "battle-particle-system", {
    resource = PROBE_TEXTURE_KEY,
    systemIndex = 0,
  }, { particles = BattleParticleSystems.newRegistry() }, services)
  Assert.isFalse(built, "a texture lease never constructs a particle system")
  Assert.isTrue(
    tostring(failure):find(PROBE_TEXTURE_KEY, 1, true) ~= nil,
    "the refusal names the offending resource: " .. tostring(failure)
  )
  Assert.equal(#scene:particleSystems(), 0, "a refused construction registers no system")
  assertJournalBalanced(journal, "refused construction")
  probe.owned:dispose()
  probe.envelope:dispose()
end

-- Cancellation and repeated disposal release exactly once: the cancelled
-- system drops its scene registration, every acquired lease returns once,
-- and a second dispose never frees again.
function T.cancelled_production_system_releases_every_lease_exactly_once()
  local probe = demandProductionTackle("probe-cancel-production")
  local Factory = effectFactoryModule()
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local services =
    { scene = scene, audio = {}, resources = journaledHolderServices(probe.owned, probe.effect, journal) }
  local task = assert(
    Factory.create(
      "battle-particle-system",
      { resource = PROBE_ARCHIVE_KEY, systemIndex = 0 },
      { particles = BattleParticleSystems.newRegistry() },
      services
    ),
    "the factory constructs the production-fed system"
  )
  Assert.equal(#scene:particleSystems(), 1, "the system is registered while it runs")
  task:cancel("production-probe-cancel")
  Assert.equal(task:status(), "cancelled", "cancellation stays distinct from completion")
  Assert.equal(#scene:particleSystems(), 0, "cancellation drops the scene registration")
  assertJournalBalanced(journal, "cancelled system")
  task:dispose()
  task:dispose()
  assertJournalBalanced(journal, "disposed system")
  probe.owned:dispose()
  probe.owned:dispose()
  probe.envelope:dispose()
end

-- A texture that fails to stage fails the whole system: construction raises,
-- nothing is registered, and exactly the acquired leases return.
function T.failed_texture_rolls_back_the_production_system()
  local FakeCache = require("tests.support.FakeCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local cache = CacheFs.forVersion("probe-child-failure", FakeCache.new())
  stageProductionTackle(cache)
  cache:write(PROBE_TEXTURE_PATH, "garbage-bytes-are-no-texture")
  local host = recordingProductionHost()
  host.answers["TACKLE"] = true
  local envelope = productionEnvelope(cache, host)
  local owned = productionHolder(envelope:_preparationServices(), "probe-child-failure")
  Assert.equal(owned:demandEffect("TACKLE"), true, "a present path still reads ready before decoding")
  local effect = owned:loadEffect("TACKLE")
  Assert.notNil(effect, "the ready effect loads before resolving")
  local Factory = effectFactoryModule()
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local services = { scene = scene, audio = {}, resources = journaledHolderServices(owned, effect, journal) }
  local built, failure = pcall(
    Factory.create,
    "battle-particle-system",
    { resource = PROBE_ARCHIVE_KEY, systemIndex = 0 },
    { particles = BattleParticleSystems.newRegistry() },
    services
  )
  Assert.isFalse(built, "a system with an unstaged texture never constructs")
  Assert.isTrue(
    tostring(failure):find(PROBE_TEXTURE_KEY, 1, true) ~= nil,
    "the refusal names the failed texture resource: " .. tostring(failure)
  )
  Assert.equal(#scene:particleSystems(), 0, "a refused system registers nothing")
  assertJournalBalanced(journal, "rolled-back system")
  owned:dispose()
  envelope:dispose()
end

return { tests = T }
