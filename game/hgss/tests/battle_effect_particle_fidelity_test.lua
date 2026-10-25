-- Native particle fidelity at the production task boundary: pinned
-- particle members resolve to their own semantic resources, creation
-- words carry their emitter position with that resource, the source
-- clock advances effect age deterministically while reads stay free of
-- side effects, and no visual step may consume the mechanics random
-- stream. Setup below holds today through the real producer and scene
-- paths; the measurement gate drives the battle-private effect task
-- factory once it exists.
-- Native mechanism: the overlay-7 particle words and their emitter,
-- lifetime, trajectory, color, alpha, and size behavior with child
-- emission (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Headless: synthetic command streams use the real producer lowering and
-- the shared program shape; the recorder doubles record only. Synthetic
-- particle members stage through the real effect producer, so emitted
-- sprites resolve against genuine staged records and seeded runs compare
-- grouped against split host reads.

local Assert = require("tests.support.Assert")
local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")
local BattleAnimationSources = require("romdump.src.config.BattleAnimationSources")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
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

function T.particle_creation_lowers_with_emitter_position_and_resource()
  local foe = lowered("particle-foe-emitter", { 51, 1, 64, 50, 4 })
  Assert.equal(foe.instructions[1].op, "create-battler-effect", "the creation word keeps its own operation")
  Assert.equal(foe.instructions[1].emitterPosition, "solo-enemy", "the foe emitter keeps its battler position")
  Assert.equal(foe.instructions[1].resource, "battle/particle/tackle", "the foe emission keeps its semantic resource")
  Assert.equal(
    foe.instructions[1].taskKind,
    "battler-effect-continuation",
    "the foe emission keeps its continuation kind"
  )
  local ally = lowered("particle-ally-emitter", { 51, 0, 27, 50, 4 })
  Assert.equal(ally.instructions[1].emitterPosition, "solo-player", "the ally emitter keeps its battler position")
  Assert.equal(
    ally.instructions[1].resource,
    "battle/particle/asleep",
    "the ally emission keeps its own semantic resource"
  )
  Assert.isTrue(
    foe.instructions[1].resource ~= ally.instructions[1].resource,
    "two emitters never share one collapsed resource"
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

function T.particle_spawn_lifetime_and_render_match_source_measurements_under_a_fixed_seed()
  local Factory = effectFactoryModule()
  local scene = sceneWithPair()
  local draws = {}
  local randomDraws = {}
  local context = {
    actors = { attacker = 1, target = 3 },
    seed = 4242,
    random = function(bound)
      Assert.isTrue(type(bound) == "number" and bound > 0, "visual draws name a positive bound")
      randomDraws[#randomDraws + 1] = bound
      return 0
    end,
  }
  local services = { scene = scene, audio = {}, resources = {} }
  function services.resolve(key)
    local params = {}
    for index = 1, 42 do
      params[index] = 0
    end
    params[29], params[30], params[24], params[32] = 12, 12, 0, 1
    return {
      key = key,
      kind = "particle-emitter",
      payloadPath = "probe/particle-emitter",
      data = { features = { "alpha", "random" }, params = params },
    }
  end
  function services.release(_lease) end
  local task = assert(
    Factory.create("battler-effect-continuation", {
      resource = "battle/particle/tackle",
      emitterPosition = "solo-enemy",
    }, context, services),
    "the factory constructs the particle continuation"
  )
  local trace = {}
  for tick = 1, 30 do
    task:stepSourceTick({ tick = tick })
    trace[#trace + 1] = task:status()
    draws[#draws + 1] = #randomDraws
  end
  Assert.equal(task:status(), "complete", "the particle run reaches its own completion boundary")
  Assert.isTrue(#randomDraws > 0, "the run draws its visual randomness from the occurrence-local stream")
  local rerunScene = sceneWithPair()
  local rerunServices = { scene = rerunScene, audio = {}, resources = {} }
  function rerunServices.resolve(key)
    local params = {}
    for index = 1, 42 do
      params[index] = 0
    end
    params[29], params[30], params[24], params[32] = 12, 12, 0, 1
    return {
      key = key,
      kind = "particle-emitter",
      payloadPath = "probe/particle-emitter",
      data = { features = { "alpha", "random" }, params = params },
    }
  end
  function rerunServices.release(_lease) end
  local rerunDraws = {}
  local rerun = assert(
    Factory.create("battler-effect-continuation", {
      resource = "battle/particle/tackle",
      emitterPosition = "solo-enemy",
    }, {
      actors = { attacker = 1, target = 3 },
      seed = 4242,
      random = function(bound)
        rerunDraws[#rerunDraws + 1] = bound
        return 0
      end,
    }, rerunServices),
    "the rerun constructs the same continuation"
  )
  local rerunTrace = {}
  for tick = 1, 30 do
    rerun:stepSourceTick({ tick = tick })
    rerunTrace[#rerunTrace + 1] = rerun:status()
  end
  Assert.deepEqual(rerunTrace, trace, "the same seed gives the same source-tick trace at any host schedule")
  Assert.deepEqual(rerunDraws, randomDraws, "the same seed draws the same visual sequence")
  task:dispose()
  rerun:dispose()
  Assert.isTrue(#draws == 30, "every source tick of the run is observed")
end

local PARTICLE_KEY = "battle/particle/tackle"

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

local function apsResource(texture, palette)
  texture = texture or string.rep("\3", 16)
  palette = palette or string.rep("\4", 8)
  local paletteOffset = 0x20 + #texture
  local resourceSize = 0x20 + #texture + #palette
  return u32le(0)
    .. u32le(0)
    .. u32le(#texture)
    .. u32le(paletteOffset)
    .. u32le(#palette)
    .. u32le(0)
    .. u32le(0)
    .. u32le(resourceSize)
    .. texture
    .. palette
end

-- Stages one textured synthetic emitter through the real producer while the
-- inner command lowering is stubbed, so the factory under test borrows
-- genuine staged records instead of hand-built shapes.
local function particleBundle()
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local sources = require("romdump.src.config.BattleAnimationSources")
  local route = assert(sources.resolveSemanticRoute("TACKLE"), "the probed effect keeps its source route")
  local flags = 0x200 + 0x800 + 0x1000000 + 0x2000000
  local blob = apsMember({ apsEmitter(flags) }, { apsResource() })
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
          Assert.equal(memberId, 64, "the bundle stages the selected striking particle member")
          return blob
        end,
      }
    end,
  }
  local moduleName = "romdump.src.digest.battle.BattleAnimationCompiler"
  local previous = package.loaded[moduleName]
  package.loaded[moduleName] = {
    compile = function()
      return {
        entry = "main",
        instructions = {
          {
            op = "create-battler-effect",
            resource = PARTICLE_KEY,
            emitterPosition = "solo-enemy",
            taskKind = "battler-effect-continuation",
          },
        },
        subprograms = {},
        taskKinds = { "battler-effect-continuation" },
      }
    end,
  }
  local outcome = { pcall(compiler.compileEffect, romFs, { versionId = "heartgold" }, "TACKLE") }
  package.loaded[moduleName] = previous
  Assert.isTrue(outcome[1] == true, "the synthetic particle bundle stages: " .. tostring(outcome[2]))
  Assert.notNil(outcome[2], "the synthetic particle bundle stages an effect record")
  return outcome[2]
end

-- Occurrence-local visual randomness with the same seeded stream the live
-- player carries, so same-seed runs must agree and different seeds diverge.
local function occurrenceContext(seed)
  local state = seed
  local draws = {}
  local context = {
    launchId = "particle-fidelity-probe",
    packetId = 1,
    programKey = "particle-fidelity-probe",
    seed = seed,
    random = function(bound)
      Assert.isTrue(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
      draws[#draws + 1] = bound
      state = (state * 1103515245 + 12345) % 2147483648
      return state % math.floor(bound)
    end,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "particle-fidelity-probe" },
    visualSeed = seed,
  }
  return context, draws
end

-- Resource collaborators backed by the genuinely staged bundle: every key
-- the task borrows resolves to its staged record, and every release is
-- journaled so exactly-once ownership stays observable.
local function particleServices(scene, bundle, journal)
  local resources = {}
  function resources.resolve(key)
    local descriptor = bundle.resources[key]
    Assert.notNil(descriptor, "the particle task borrows only staged semantic resources: " .. tostring(key))
    journal.acquired[#journal.acquired + 1] = key
    local payload = bundle.resourcePayloads[descriptor.payload]
    -- The bundle double mirrors the production holder: non-texture
    -- payloads travel as decoded records beside their staged path,
    -- textures as drawable leases.
    if descriptor.kind == "texture" then
      return {
        key = key,
        kind = "texture",
        width = payload.width,
        height = payload.height,
        rgba8888 = payload.rgba8888,
        payload = descriptor.payload,
        contentIdentity = descriptor.contentIdentity,
      }
    end
    return {
      key = key,
      kind = descriptor.kind,
      payloadPath = descriptor.payload,
      contentIdentity = descriptor.contentIdentity,
      data = payload,
    }
  end
  function resources.release(lease)
    journal.released[#journal.released + 1] = lease
  end
  return { scene = scene, audio = {}, resources = resources }
end

local function assertBalanced(journal, what)
  Assert.equal(#journal.released, #journal.acquired, what .. " releases exactly what it acquires")
end

local function snapshot(scene)
  local views = scene:effectViews()
  table.sort(views, function(a, b)
    return a.id < b.id
  end)
  local spots = {}
  for _, view in ipairs(views) do
    if view.picture ~= nil then
      spots[#spots + 1] = {
        id = view.id,
        x = view.picture.centerX,
        y = view.picture.centerY,
        key = view.picture.assetKey,
        alpha = view.picture.alpha,
        width = view.picture.width,
        height = view.picture.height,
      }
    end
  end
  return spots
end

local function stripIds(spots)
  local bare = {}
  for _, spot in ipairs(spots) do
    bare[#bare + 1] = {
      x = spot.x,
      y = spot.y,
      key = spot.key,
      alpha = spot.alpha,
      width = spot.width,
      height = spot.height,
    }
  end
  table.sort(bare, function(a, b)
    if a.key ~= b.key then
      return a.key < b.key
    end
    if a.x ~= b.x then
      return a.x < b.x
    end
    if a.y ~= b.y then
      return a.y < b.y
    end
    if a.alpha ~= b.alpha then
      return a.alpha < b.alpha
    end
    if a.width ~= b.width then
      return a.width < b.width
    end
    return a.height < b.height
  end)
  return bare
end

local function stagedDrawable(bundle, assetKey)
  local descriptor = bundle.resources[assetKey]
  if descriptor == nil then
    return nil
  end
  local payload = bundle.resourcePayloads[descriptor.payload]
  if type(payload) ~= "table" then
    return nil
  end
  if type(payload.width) ~= "number" or type(payload.height) ~= "number" then
    return nil
  end
  if type(payload.rgba8888) ~= "string" then
    return nil
  end
  if payload.width < 1 or payload.height < 1 then
    return nil
  end
  if #payload.rgba8888 ~= payload.width * payload.height * 4 then
    return nil
  end
  return payload
end

local function spotsMatch(first, second)
  return pcall(Assert.deepEqual, first, second, "spot comparison")
end

function T.native_emitter_moves_with_the_seed_and_ignores_host_read_schedule()
  local Factory = effectFactoryModule()
  local bundle = particleBundle()
  local function run(seed, observeEveryTick)
    local scene = sceneWithPair()
    local context, draws = occurrenceContext(seed)
    local journal = { acquired = {}, released = {} }
    local task = assert(
      Factory.create("battler-effect-continuation", {
        resource = PARTICLE_KEY,
        emitterPosition = "solo-enemy",
      }, context, particleServices(scene, bundle, journal)),
      "the factory constructs the native emitter"
    )
    local trace = {}
    for tick = 1, 60 do
      task:stepSourceTick({ tick = tick })
      if observeEveryTick then
        trace[#trace + 1] = stripIds(snapshot(scene))
      end
    end
    task:dispose()
    return stripIds(snapshot(scene)), trace, draws
  end
  local finalA, traceA, drawsA = run(4242, true)
  local positions = {}
  for _, spots in ipairs(traceA) do
    for _, spot in ipairs(spots) do
      positions[spot.x .. "," .. spot.y] = true
    end
  end
  local distinct = 0
  for _ in pairs(positions) do
    distinct = distinct + 1
  end
  Assert.isTrue(distinct > 1, "the emitter moves its sprites across source ticks instead of staging one fixed center")
  local finalB, _, drawsB = run(4242, false)
  Assert.deepEqual(finalB, finalA, "host read schedule never changes the visual state")
  Assert.deepEqual(drawsB, drawsA, "the same seed draws the same visual sequence at any read schedule")
  local _, traceC, drawsC = run(777, true)
  Assert.isTrue(#drawsC > 0, "the alternate seed draws occurrence-local visual randomness")
  local differs = false
  for tick = 1, 60 do
    if not spotsMatch(traceA[tick], traceC[tick]) then
      differs = true
      break
    end
  end
  Assert.isTrue(
    differs,
    "a different visual seed observes different particle placement when the source demands randomness"
  )
end

function T.emitted_sprites_carry_staged_drawables_and_retire_on_the_native_boundary()
  local Factory = effectFactoryModule()
  local bundle = particleBundle()
  local scene = sceneWithPair()
  local context = occurrenceContext(4242)
  local journal = { acquired = {}, released = {} }
  local task = assert(
    Factory.create("battler-effect-continuation", {
      resource = PARTICLE_KEY,
      emitterPosition = "solo-enemy",
    }, context, particleServices(scene, bundle, journal)),
    "the factory constructs the native emitter"
  )
  local seenIds = {}
  local maxLive = 0
  local status = task:status()
  for tick = 1, 600 do
    task:stepSourceTick({ tick = tick })
    local spots = snapshot(scene)
    if #spots > maxLive then
      maxLive = #spots
    end
    for _, spot in ipairs(spots) do
      seenIds[spot.id] = true
      local drawable = stagedDrawable(bundle, spot.key)
      Assert.notNil(drawable, "emitted sprite asset resolves to a staged drawable: " .. tostring(spot.key))
      Assert.equal(spot.width, drawable.width, "emitted sprite width matches its staged drawable")
      Assert.equal(spot.height, drawable.height, "emitted sprite height matches its staged drawable")
    end
    status = task:status()
    if status == "complete" then
      break
    end
  end
  local distinct = 0
  for _ in pairs(seenIds) do
    distinct = distinct + 1
  end
  Assert.isTrue(distinct > 1, "one source emission owns more than one sprite record")
  Assert.isTrue(maxLive > 1, "sibling sprites coexist on the same source tick")
  Assert.equal(status, "complete", "the emitter retires on its native completion boundary")
  Assert.equal(#snapshot(scene), 0, "retirement releases every owned sprite record")
  task:dispose()
end

function T.particle_continuation_refuses_defaults_and_releases_only_owned_records_on_cancel()
  local Factory = effectFactoryModule()
  local bundle = particleBundle()
  local missingSelections = {
    {},
    { resource = PARTICLE_KEY },
    { emitterPosition = "solo-enemy" },
  }
  for _, args in ipairs(missingSelections) do
    local scene = sceneWithPair()
    local context = occurrenceContext(4242)
    local journal = { acquired = {}, released = {} }
    local built, failure =
      pcall(Factory.create, "battler-effect-continuation", args, context, particleServices(scene, bundle, journal))
    Assert.isFalse(built, "a particle continuation without its full source selection never constructs")
    Assert.isTrue(type(failure) == "string" and failure ~= "", "refused construction names its cause")
    Assert.equal(#scene:effectViews(), 0, "a refused construction publishes no visual records")
    assertBalanced(journal, "refused construction")
  end
  local scene = sceneWithPair()
  local context = occurrenceContext(4242)
  local journal = { acquired = {}, released = {} }
  local task = assert(
    Factory.create("battler-effect-continuation", {
      resource = PARTICLE_KEY,
      emitterPosition = "solo-enemy",
    }, context, particleServices(scene, bundle, journal)),
    "the factory constructs the native emitter"
  )
  local maxLive = 0
  for tick = 1, 10 do
    task:stepSourceTick({ tick = tick })
    local live = #snapshot(scene)
    if live > maxLive then
      maxLive = live
    end
  end
  Assert.isTrue(maxLive > 1, "cancellation starts from a live multi-sprite emission")
  task:cancel("fidelity-probe-cancel")
  Assert.equal(task:status(), "cancelled", "cancellation stays distinct from completion")
  Assert.equal(#scene:effectViews(), 0, "cancellation releases every owned sprite record")
  assertBalanced(journal, "cancelled emission")
  task:dispose()
  assertBalanced(journal, "disposed emission")
  local shared = sceneWithPair()
  local firstContext = occurrenceContext(4242)
  local firstJournal = { acquired = {}, released = {} }
  local first = assert(
    Factory.create("battler-effect-continuation", {
      resource = PARTICLE_KEY,
      emitterPosition = "solo-enemy",
    }, firstContext, particleServices(shared, bundle, firstJournal)),
    "the first overlapping emission constructs"
  )
  local secondContext = occurrenceContext(777)
  local secondJournal = { acquired = {}, released = {} }
  local second = assert(
    Factory.create("battler-effect-continuation", {
      resource = PARTICLE_KEY,
      emitterPosition = "solo-enemy",
    }, secondContext, particleServices(shared, bundle, secondJournal)),
    "the second overlapping emission constructs"
  )
  for tick = 1, 5 do
    first:stepSourceTick({ tick = tick })
    second:stepSourceTick({ tick = tick })
  end
  Assert.isTrue(#snapshot(shared) > 1, "overlapping emissions coexist before cancellation")
  local survivorAcquired = #secondJournal.acquired
  local survivorReleased = #secondJournal.released
  first:cancel("overlap-probe-cancel")
  Assert.equal(#secondJournal.acquired, survivorAcquired, "cancellation stages nothing on the survivor")
  Assert.equal(#secondJournal.released, survivorReleased, "cancellation releases nothing on the survivor")
  local survivorTrace = {}
  local survivorStatus = second:status()
  for tick = 6, 600 do
    second:stepSourceTick({ tick = tick })
    survivorTrace[#survivorTrace + 1] = stripIds(snapshot(shared))
    survivorStatus = second:status()
    if survivorStatus == "complete" then
      break
    end
  end
  Assert.equal(survivorStatus, "complete", "the surviving emission still reaches its own completion")
  local controlScene = sceneWithPair()
  local controlContext = occurrenceContext(777)
  local controlJournal = { acquired = {}, released = {} }
  local control = assert(
    Factory.create("battler-effect-continuation", {
      resource = PARTICLE_KEY,
      emitterPosition = "solo-enemy",
    }, controlContext, particleServices(controlScene, bundle, controlJournal)),
    "the solo control emission constructs"
  )
  local controlTrace = {}
  for tick = 1, 600 do
    control:stepSourceTick({ tick = tick })
    if tick >= 6 then
      controlTrace[#controlTrace + 1] = stripIds(snapshot(controlScene))
    end
    if control:status() == "complete" then
      break
    end
  end
  Assert.equal(#survivorTrace, #controlTrace, "the survivor follows the solo control schedule tick for tick")
  for index, spots in ipairs(survivorTrace) do
    Assert.deepEqual(spots, controlTrace[index], "survivor visuals match the solo control after cancellation")
  end
  first:dispose()
  second:dispose()
  control:dispose()
end

local CUSTOM_ARCHIVE_KEY = "battle/particle/custom-archive"
local CUSTOM_TEXTURE_KEY = "battle/particle/custom-texture"

local function customEmitter(overrides)
  local params = {}
  for index = 1, 42 do
    params[index] = 0
  end
  params[29] = 10
  params[30] = 10
  params[24] = 0
  params[32] = 1
  local record = {
    features = { "color", "random" },
    variant = 0,
    params = params,
    textureSlot = 0,
    textureKey = CUSTOM_TEXTURE_KEY,
  }
  if overrides ~= nil then
    if overrides.params ~= nil then
      for index, value in pairs(overrides.params) do
        params[index] = value
      end
      overrides.params = nil
    end
    for key, value in pairs(overrides) do
      record[key] = value
    end
  end
  return record
end

local function customBundle(emitters, width, height)
  width = width or 8
  height = height or 8
  return {
    resources = {
      [CUSTOM_ARCHIVE_KEY] = { kind = "particle", payload = "custom/archive" },
      [CUSTOM_TEXTURE_KEY] = { kind = "texture", payload = "custom/texture" },
    },
    resourcePayloads = {
      ["custom/archive"] = {
        emitters = emitters,
        resources = { { textureKey = CUSTOM_TEXTURE_KEY, paletteKey = nil } },
      },
      ["custom/texture"] = {
        width = width,
        height = height,
        rgba8888 = string.rep("\1\2\3\255", width * height),
      },
    },
  }
end

local function runCustom(emitters, ticks, seed)
  local Factory = effectFactoryModule()
  local bundle = customBundle(emitters)
  local scene = sceneWithPair()
  local context = occurrenceContext(seed or 4242)
  local journal = { acquired = {}, released = {} }
  local task = assert(
    Factory.create("battler-effect-continuation", {
      resource = CUSTOM_ARCHIVE_KEY,
      emitterPosition = "solo-enemy",
    }, context, particleServices(scene, bundle, journal)),
    "the factory constructs the staged emitter"
  )
  local seen = {}
  local maxLive = 0
  for _ = 1, ticks do
    task:stepSourceTick({ tick = 1 })
    local live = 0
    for _, spot in ipairs(snapshot(scene)) do
      seen[spot.id] = true
      live = live + 1
    end
    if live > maxLive then
      maxLive = live
    end
    if task:status() == "complete" then
      break
    end
  end
  local distinct = 0
  for _ in pairs(seen) do
    distinct = distinct + 1
  end
  return task, scene, journal, distinct, maxLive
end

function T.native_emitter_emits_every_tick_at_zero_interval_and_retires()
  local task, scene, journal, distinct = runCustom({ customEmitter() }, 30)
  Assert.equal(task:status(), "complete", "the zero-interval emission reaches its own boundary")
  Assert.equal(distinct, 10, "an emission every tick over ten active ticks owns ten sprites")
  Assert.equal(#snapshot(scene), 0, "retirement releases every owned sprite record")
  task:dispose()
  assertBalanced(journal, "disposed zero-interval emission")
end

function T.native_emitter_paces_large_intervals_to_a_single_generation()
  local emitter = customEmitter()
  emitter.params[24] = 600
  emitter.params[29] = 10
  emitter.params[30] = 5
  emitter.params[32] = 3
  local task, scene, journal, distinct, maxLive = runCustom({ emitter }, 30)
  Assert.equal(task:status(), "complete", "the large-interval emission reaches its own boundary")
  Assert.equal(distinct, 3, "one paced generation owns exactly its staged spawn count")
  Assert.equal(maxLive, 3, "the generation coexists on the same source tick")
  task:dispose()
  assertBalanced(journal, "disposed paced emission")
end

function T.native_emitter_counts_match_the_staged_control_block()
  local emitter = customEmitter()
  emitter.params[24] = 600
  emitter.params[32] = 4
  local _, _, journal, distinct = runCustom({ emitter }, 30)
  Assert.equal(distinct, 4, "one emission owns exactly four sprites")
  assertBalanced(journal, "counted emission")
end

function T.native_emitter_moves_with_signed_fixed_point_velocity()
  local emitter = customEmitter({ features = { "color" } })
  emitter.params[17] = 0
  emitter.params[18] = 65520
  emitter.params[21] = 0
  emitter.params[22] = 16
  local task, scene = runCustom({ emitter }, 5)
  local spots = snapshot(scene)
  Assert.isTrue(#spots > 0, "the velocity run owns live sprites")
  local minX, maxY = nil, nil
  for _, spot in ipairs(spots) do
    Assert.isTrue(spot.x % 1 == 0, "sprite pixels quantize to integer positions")
    Assert.isTrue(spot.y % 1 == 0, "sprite pixels quantize to integer positions")
    if minX == nil or spot.x < minX then
      minX = spot.x
    end
    if maxY == nil or spot.y > maxY then
      maxY = spot.y
    end
  end
  Assert.isTrue(minX < 192, "the negative fixed-point velocity moves sprites left")
  Assert.isTrue(maxY > 80, "the positive fixed-point velocity moves sprites down")
  Assert.equal(task:status(), "running", "the velocity run is still mid-emission")
  task:cancel("velocity-probe-cancel")
  task:dispose()
end

-- Production lease proving ground: a synthetic striking effect staged
-- through the real cache, resolved through the real field envelope
-- services and the per-launch holder, then admitted through the live
-- player and task factory. The archive and texture below stand in for
-- one producer-normalized SPL member and its decoded image bytes.
local PROBE_ARCHIVE_KEY = "battle/particle/tackle"
local PROBE_TEXTURE_KEY = "battle/particle/tackle-texture"
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
    sceneKey = "probe/plain/day",
    shadowRegions = BattlePresentationManifestFixture.manifest().pictures.shadow.regions,
  })
end

local function probeArchivePayload(textureKey)
  local emitter = customEmitter({ textureKey = textureKey, features = { "color", "random" } })
  return {
    emitters = { emitter },
    resources = { { textureKey = textureKey, paletteKey = nil } },
  }
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
          emitterPosition = "solo-enemy",
          taskKind = "battler-effect-continuation",
        },
        { op = "wait-for-battler-effects", cursorRule = "advance-when-effects-finish" },
      },
      subprograms = {},
      taskKinds = { "battler-effect-continuation" },
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

local function stageProductionTackle(cache, archivePayloadOverride, texturePayloadOverride)
  local Hashing = require("romdump.src.digest.Hashing")
  local textureBytes = EffectStagingFixture.rgba(PROBE_TEXTURE_WIDTH, PROBE_TEXTURE_HEIGHT)
  local textureIdentity = Hashing.sha1hex(textureBytes)
  local archivePayload = archivePayloadOverride or probeArchivePayload(PROBE_TEXTURE_KEY)
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

local function liveSpots(scene)
  local spots = {}
  for _, view in ipairs(scene:effectViews()) do
    if view.picture ~= nil then
      spots[#spots + 1] = view.picture
    end
  end
  return spots
end

-- The production resolver decodes the staged archive instead of handing
-- out its path: the particle task consumes the normalized emitters and
-- the staged texture bytes, paints staged sprites through the live
-- player, retires them at the source boundary, and releases every lease.
function T.production_particle_lease_decodes_staged_records_and_completes()
  local probe = demandProductionTackle("probe-particle-production")
  local owned, effect = probe.owned, probe.effect
  Assert.equal(
    effect.resources[PROBE_ARCHIVE_KEY].payload,
    PROBE_ARCHIVE_PATH,
    "the generated descriptor keeps naming the staged path"
  )
  local lease = owned:resolveEffectResource(effect, PROBE_ARCHIVE_KEY)
  Assert.notNil(lease, "the archive admits through the production holder")
  Assert.equal(lease.kind, "particle", "the archive lease keeps its semantic kind")
  Assert.equal(lease.payloadPath, PROBE_ARCHIVE_PATH, "the runtime lease names its staged path separately")
  Assert.isNil(lease.payload, "the runtime lease never conflates the path field with decoded content")
  Assert.equal(lease.contentIdentity, probe.staged.archiveIdentity, "the lease carries its content identity")
  Assert.isTrue(type(lease.data) == "table", "the archive lease carries its decoded record")
  Assert.deepEqual(lease.data, probe.staged.archive, "the decoded lease matches the staged archive")
  local texture = owned:resolveEffectResource(effect, PROBE_TEXTURE_KEY)
  Assert.notNil(texture, "the texture admits beside the archive")
  Assert.equal(texture.width, PROBE_TEXTURE_WIDTH, "the texture lease carries its staged width")
  Assert.equal(texture.height, PROBE_TEXTURE_HEIGHT, "the texture lease carries its staged height")
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
  }))
  local handle = assert(player:start(productionPlayback("TACKLE"), effect.program))
  local maxLive = 0
  for _ = 1, 600 do
    player:stepSourceTick({ tick = 1 })
    local live = liveSpots(scene)
    if #live > maxLive then
      maxLive = #live
      for _, picture in ipairs(live) do
        Assert.equal(picture.assetKey, PROBE_TEXTURE_KEY, "live sprites reference the staged texture key")
        Assert.equal(picture.width, PROBE_TEXTURE_WIDTH, "live sprites carry the staged drawable width")
        Assert.equal(picture.height, PROBE_TEXTURE_HEIGHT, "live sprites carry the staged drawable height")
      end
    end
    if player:status(handle) == "complete" or player:status(handle) == "failed" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "the production-fed run reaches its own completion")
  Assert.isTrue(maxLive > 1, "sibling sprites coexist on the same source tick")
  Assert.equal(#scene:effectViews(), 0, "retirement releases every owned sprite record")
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
  Assert.isNil(lease, "the undecodable archive hands out no lease")
  Assert.isTrue(type(failure) == "string" and failure ~= "", "the undecodable archive carries its reason")
  local reason = failure --[[@as string]]
  Assert.isTrue(reason:find("TACKLE", 1, true) ~= nil, "the failure names its effect: " .. reason)
  Assert.isTrue(reason:find(PROBE_ARCHIVE_KEY, 1, true) ~= nil, "the failure names its resource: " .. reason)
  Assert.isTrue(reason:find(PROBE_ARCHIVE_PATH, 1, true) ~= nil, "the failure names its path: " .. reason)
  owned:dispose()
  envelope:dispose()
end

-- A continuation staged against a non-particle lease fails at
-- construction with the resource key: textures never masquerade as
-- emitter records.
function T.particle_continuation_rejects_non_particle_leases_with_provenance()
  local probe = demandProductionTackle("probe-wrong-kind")
  local Factory = effectFactoryModule()
  local scene = sceneWithPair()
  local context = occurrenceContext(4242)
  local journal = { acquired = {}, released = {} }
  local services =
    { scene = scene, audio = {}, resources = journaledHolderServices(probe.owned, probe.effect, journal) }
  local built, failure = pcall(Factory.create, "battler-effect-continuation", {
    resource = PROBE_TEXTURE_KEY,
    emitterPosition = "solo-enemy",
  }, context, services)
  Assert.isFalse(built, "a texture lease never constructs a particle continuation")
  Assert.isTrue(type(failure) == "string" and failure ~= "", "the refused construction names its cause")
  Assert.isTrue(
    tostring(failure):find(PROBE_TEXTURE_KEY, 1, true) ~= nil,
    "the refusal names the offending resource: " .. tostring(failure)
  )
  Assert.equal(#scene:effectViews(), 0, "a refused construction publishes no visual records")
  assertJournalBalanced(journal, "refused construction")
  probe.owned:dispose()
  probe.envelope:dispose()
end

-- Cancellation and repeated disposal release exactly once: the cancelled
-- emission drops every sprite, every acquired lease returns once, and a
-- second dispose never frees again.
function T.cancelled_production_emission_releases_every_lease_exactly_once()
  local probe = demandProductionTackle("probe-cancel-production")
  local Factory = effectFactoryModule()
  local scene = sceneWithPair()
  local context = occurrenceContext(4242)
  local journal = { acquired = {}, released = {} }
  local services =
    { scene = scene, audio = {}, resources = journaledHolderServices(probe.owned, probe.effect, journal) }
  local task = assert(
    Factory.create("battler-effect-continuation", {
      resource = PROBE_ARCHIVE_KEY,
      emitterPosition = "solo-enemy",
    }, context, services),
    "the factory constructs the production-fed emitter"
  )
  local maxLive = 0
  for tick = 1, 10 do
    task:stepSourceTick({ tick = tick })
    local live = #liveSpots(scene)
    if live > maxLive then
      maxLive = live
    end
  end
  Assert.isTrue(maxLive > 1, "cancellation starts from a live multi-sprite emission")
  task:cancel("production-probe-cancel")
  Assert.equal(task:status(), "cancelled", "cancellation stays distinct from completion")
  Assert.equal(#scene:effectViews(), 0, "cancellation releases every owned sprite record")
  assertJournalBalanced(journal, "cancelled emission")
  task:dispose()
  task:dispose()
  assertJournalBalanced(journal, "disposed emission")
  probe.owned:dispose()
  probe.owned:dispose()
  probe.envelope:dispose()
end

-- A child texture that fails to stage fails the whole continuation:
-- construction raises, no sprite record survives, and exactly the
-- acquired leases return.
function T.failed_child_texture_rolls_back_the_production_continuation()
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
  local context = occurrenceContext(4242)
  local journal = { acquired = {}, released = {} }
  local services = { scene = scene, audio = {}, resources = journaledHolderServices(owned, effect, journal) }
  local built, failure = pcall(Factory.create, "battler-effect-continuation", {
    resource = PROBE_ARCHIVE_KEY,
    emitterPosition = "solo-enemy",
  }, context, services)
  Assert.isFalse(built, "a continuation with an unstaged texture never constructs")
  Assert.isTrue(type(failure) == "string" and failure ~= "", "the refused construction names its cause")
  Assert.isTrue(
    tostring(failure):find(PROBE_TEXTURE_KEY, 1, true) ~= nil,
    "the refusal names the failed texture resource: " .. tostring(failure)
  )
  Assert.equal(#scene:effectViews(), 0, "a refused continuation publishes no visual records")
  assertJournalBalanced(journal, "rolled-back continuation")
  owned:dispose()
  envelope:dispose()
end

-- Runtime-selected emitters travel the same typed lease: one solo pair
-- and one double-side pair each lease only their own published emitter
-- and texture, render, complete, and release exactly once.
local PAIR_EFFECT_KEY = "PAIR"
local PAIR_LONE_KEY = "battle/particle-emitter/lone"
local PAIR_PARTNER_KEY = "battle/particle-emitter/partner"
local PAIR_LONE_TEXTURE = "probe/lone-texture"
local PAIR_PARTNER_TEXTURE = "probe/partner-texture"
local PAIR_POSITIONS = {
  "solo-player",
  "solo-enemy",
  "player-side-slot-1",
  "enemy-side-slot-1",
  "player-side-slot-2",
  "enemy-side-slot-2",
}

local function pairEffectRecord(loneArchive, partnerArchive, loneTextureBytes, partnerTextureBytes)
  local Hashing = require("romdump.src.digest.Hashing")
  local cases = {}
  for _, attacker in ipairs(PAIR_POSITIONS) do
    for _, target in ipairs(PAIR_POSITIONS) do
      cases[attacker .. "/" .. target] = PAIR_LONE_KEY
    end
  end
  cases["player-side-slot-1/enemy-side-slot-1"] = PAIR_PARTNER_KEY
  return {
    schema = BattleAnimationSchema.EFFECT_SCHEMA,
    key = PAIR_EFFECT_KEY,
    catalogIdentity = "probe-catalog",
    program = {
      entry = "main",
      instructions = {
        {
          op = "create-parameterized-battler-effect",
          taskKind = "battler-effect-continuation",
          actionProfile = "particle-emitter-target-battler-relative",
          emitterPosition = "solo-enemy",
          runtimeSelection = "battler-particle-position-pair",
          resourceCases = cases,
        },
        { op = "wait-for-battler-effects", cursorRule = "advance-when-effects-finish" },
      },
      subprograms = {},
      taskKinds = { "battler-effect-continuation" },
    },
    dependencies = { PAIR_LONE_KEY, PAIR_PARTNER_KEY, PAIR_LONE_TEXTURE, PAIR_PARTNER_TEXTURE },
    resources = {
      [PAIR_LONE_KEY] = {
        kind = "particle-emitter",
        payload = "effects/probe-lone-emitter.lua",
        contentIdentity = Hashing.sha1hex("probe-lone-emitter"),
      },
      [PAIR_PARTNER_KEY] = {
        kind = "particle-emitter",
        payload = "effects/probe-partner-emitter.lua",
        contentIdentity = Hashing.sha1hex("probe-partner-emitter"),
      },
      [PAIR_LONE_TEXTURE] = {
        kind = "texture",
        payload = "effects/probe-lone-texture.lua",
        contentIdentity = Hashing.sha1hex(loneTextureBytes),
      },
      [PAIR_PARTNER_TEXTURE] = {
        kind = "texture",
        payload = "effects/probe-partner-texture.lua",
        contentIdentity = Hashing.sha1hex(partnerTextureBytes),
      },
    },
    requiredContext = {},
  }
end

local function runPairCase(attackerSlot, targetSlot, expectEmitter, expectTexture, expectWidth, launchId)
  local FakeCache = require("tests.support.FakeCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local cache = CacheFs.forVersion("probe-pair-selection", FakeCache.new())
  local loneTextureBytes = EffectStagingFixture.rgba(8, 8)
  local partnerTextureBytes = EffectStagingFixture.rgba(4, 4)
  cache:writeLua(
    BattlePresentationCache.effectPath(PAIR_EFFECT_KEY),
    pairEffectRecord(nil, nil, loneTextureBytes, partnerTextureBytes)
  )
  cache:write(BattlePresentationCache.effectMarkerPath(PAIR_EFFECT_KEY), "probe-marker")
  cache:writeLua("effects/probe-lone-emitter.lua", customEmitter({ textureKey = PAIR_LONE_TEXTURE }))
  cache:writeLua("effects/probe-partner-emitter.lua", customEmitter({ textureKey = PAIR_PARTNER_TEXTURE }))
  cache:writeLua("effects/probe-lone-texture.lua", { width = 8, height = 8, rgba8888 = loneTextureBytes })
  cache:writeLua("effects/probe-partner-texture.lua", { width = 4, height = 4, rgba8888 = partnerTextureBytes })
  local host = recordingProductionHost()
  host.answers[PAIR_EFFECT_KEY] = true
  local envelope = productionEnvelope(cache, host)
  local owned = productionHolder(envelope:_preparationServices(), launchId)
  Assert.equal(owned:demandEffect(PAIR_EFFECT_KEY), true, "the paired closure reads ready")
  local effect = owned:loadEffect(PAIR_EFFECT_KEY)
  Assert.notNil(effect, "the paired effect loads before resolving")
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
  }))
  local packet = {
    launchId = launchId,
    packetId = 1,
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = PAIR_EFFECT_KEY },
    visualSeed = 777,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = attackerSlot, sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = targetSlot, sideType = 1 } },
    },
  }
  local handle = assert(player:start(packet, effect.program))
  local maxLive = 0
  for _ = 1, 600 do
    player:stepSourceTick({ tick = 1 })
    local live = liveSpots(scene)
    if #live > maxLive then
      maxLive = #live
      for _, picture in ipairs(live) do
        Assert.equal(picture.assetKey, expectTexture, "paired sprites reference the selected texture")
        Assert.equal(picture.width, expectWidth, "paired sprites carry the selected drawable width")
        Assert.equal(picture.height, expectWidth, "paired sprites carry the selected drawable height")
      end
    end
    local status = player:status(handle)
    if status == "complete" or status == "failed" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", attackerSlot .. "/" .. targetSlot .. " reaches its completion")
  Assert.isTrue(maxLive > 0, "the selected pair paints its emitter")
  Assert.equal(#scene:effectViews(), 0, "retirement releases every owned sprite record")
  player:dispose()
  assertJournalBalanced(journal, "the paired run")
  local acquired = {}
  for _, key in ipairs(journal.acquired) do
    acquired[#acquired + 1] = key
  end
  table.sort(acquired)
  -- The occurrence journals one emitter lease while the spawned task
  -- stages its own emitter and texture leases: exactly these three
  -- acquisitions, nothing sibling-wide.
  Assert.deepEqual(
    acquired,
    { expectEmitter, expectEmitter, expectTexture },
    "the pair leases only its own emitter and texture"
  )
  owned:dispose()
  envelope:dispose()
end

function T.runtime_selected_emitters_resolve_typed_leases_for_solo_and_paired_slots()
  runPairCase("solo-player", "solo-enemy", PAIR_LONE_KEY, PAIR_LONE_TEXTURE, 8, "probe-pair-solo")
  runPairCase("player-side-slot-1", "enemy-side-slot-1", PAIR_PARTNER_KEY, PAIR_PARTNER_TEXTURE, 4, "probe-pair-double")
end

return { tests = T }
