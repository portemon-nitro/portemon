-- Whole-save compatibility matrix: every persisted owner keeps loading
-- when only unrelated content moves, and keeps rejecting when a selected
-- reference disappears or state leaves its valid range. Compatible edits
-- cover profile, options, location, world, travel, interface, audio,
-- encounters, and dex; incompatible edits cover mons, bag, scripts,
-- audio, encounters, and dex. Rejections name their owner and key and
-- leave the candidate record untouched, and a failed store write never
-- rewrites the last published bytes. One production round trip closes the
-- matrix: saved field progress continues after a restart.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local Errors = require("libs.errors.src.Errors")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local MonCatalog = require("libs.mons.src.MonCatalog")
local GameSaveValidation = require("game.hgss.src.save.GameSaveValidation")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local PokedexSave = require("libs.hgss.src.save.PokedexSave")
local BagSave = require("libs.hgss.src.save.BagSave")
local MonsSave = require("libs.mons.src.MonsSave")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local CompatibilityFixture = require("tests.support.script.CompatibilityFixture")

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:7", "map-data:61", "map-data:111", "map:7", "map:61", "map:111" },
    tags = { "field", "battle", "save", "compatibility" },
  },
  tests = {},
}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy(item)
  end
  return out
end

local function stockedBag()
  local bag = BagSave.empty()
  bag.pockets.balls = { { item = "POKE_BALL", quantity = 3 } }
  bag.pockets.medicine = { { item = "POTION", quantity = 1 } }
  bag.registered = { "BICYCLE" }
  return bag
end

local function partyBucket(monCatalog)
  local factory = CatalogFixture.makeFactory(0x12345678, monCatalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest())
  return MonsSave.capture({ max = 6, mons = { mon } }, Lcrng.new(0x99999999):capture(), monCatalog:fingerprint())
end

local function quietScripts(setup)
  return {
    schema = "g4-script-save-v1",
    registryFingerprint = setup.registry:fingerprint(),
    taskFingerprint = setup.tasks:fingerprint(),
    capturedAtSimulationTick = 0,
    nextEnvironmentId = 0,
    nextInstanceId = 0,
    nextTaskId = 0,
    environments = {},
    instances = {},
    tasks = {},
  }
end

local function speciesRefs(monRoot)
  local refs = {}
  for key in pairs(assert(monRoot.species, "the mon root carries its species")) do
    refs[key] = true
  end
  return refs
end

local function baseRecord(saveId, scripts)
  local monCatalog = CatalogFixture.makeCatalog()
  return {
    schema = "g4-game-save-v5",
    saveId = saveId,
    versionId = "heartgold",
    playTimeSeconds = 0,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain-heartgold",
    facing = "south",
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
      options = { textFrame = 0, textSpeed = "mid" },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    world = { flags = { [10] = true }, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = scripts,
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = { fieldMusicOverride = 7 },
    mons = partyBucket(monCatalog),
    bag = stockedBag(),
    encounters = EncounterSave.initial(),
    pokedex = PokedexSave.initial(),
  }
end

local function contextWith(setup, monCatalog, itemCatalog, audioIds)
  local monRoot = CatalogFixture.buildAssetRoot()
  return {
    charmap = CatalogFixture.CHARMAP,
    frameIndexes = { [0] = true },
    audioSequenceIds = audioIds or { [7] = true },
    monCatalog = monCatalog or CatalogFixture.makeCatalog(),
    itemCatalog = itemCatalog or ItemFixture.makeCatalog(),
    speciesRefs = speciesRefs(monRoot),
    mapRefs = { [60] = true, [7] = true },
    scriptCompatibility = {
      validationOptions = function()
        return CompatibilityFixture.optionsFor(setup)
      end,
    },
  }
end

local function serviceFor(cell)
  return GameSaveValidation.new({
    contextLoader = function()
      return cell.current
    end,
  })
end

-- Whether a whole-save failure names its owner and referenced key, however
-- the cause chain phrases it: the top-level message or context carries it.
local function mentions(haystack, needle, seen)
  if type(haystack) == "string" then
    return haystack:find(needle, 1, true) ~= nil
  end
  if type(haystack) == "number" then
    return tostring(haystack):find(needle, 1, true) ~= nil
  end
  if type(haystack) ~= "table" then
    return false
  end
  seen = seen or {}
  if seen[haystack] then
    return false
  end
  seen[haystack] = true
  for key, value in pairs(haystack) do
    if mentions(key, needle, seen) or mentions(value, needle, seen) then
      return true
    end
  end
  return false
end

local function failureNamesKey(err, bucket, needle)
  if not Errors.is(err) then
    return false
  end
  if err.code ~= "GAME_SAVE_BUCKET_INVALID" then
    return false
  end
  if type(err.context) ~= "table" or err.context.bucket ~= bucket then
    return false
  end
  return mentions(err.message, needle) or mentions(err.context, needle)
end

function T.tests.unrelated_profile_options_location_and_world_edits_keep_loading()
  local setup = CompatibilityFixture.rig()
  local candidate = baseRecord("save-00000101", quietScripts(setup))
  candidate.playerData.profile.name = "SILVER"
  candidate.playerData.profile.money = 4500
  candidate.playerData.options.textSpeed = "fastest"
  candidate.mapId = 7
  candidate.fieldX = 100
  candidate.fieldZ = 200
  candidate.world.flags[11] = true
  candidate.world.variables[3] = 9
  candidate.auxiliaryUi = { requested = "hidden", state = "hidden" }
  candidate.audio = { fieldMusicOverride = 8 }
  candidate.pokedex = {
    schema = PokedexSave.initial().schema,
    stateVersion = PokedexSave.initial().stateVersion,
    seen = { "CHIKORITA" },
    caught = { "CHIKORITA" },
  }
  candidate.encounters.steps = 12
  candidate.encounters.repelSteps = 3
  candidate.encounters.roamers = {
    ["roamer-eevee"] = {
      key = "roamer-eevee",
      stateVersion = 1,
      mon = { species = "EEVEE" },
      location = 60,
      lifecycle = "roaming",
      revision = 0,
    },
  }
  local service = serviceFor({ current = contextWith(setup, nil, nil, { [7] = true, [8] = true }) })
  local valid = assert(service:validate(candidate))
  Assert.equal(valid.saveId, "save-00000101")
  Assert.equal(valid.playerData.profile.name, "SILVER", "the unrelated profile edit survives the load")
  Assert.equal(valid.playerData.profile.money, 4500, "the unrelated money edit survives the load")
  Assert.equal(valid.mapId, 7, "the moved location survives the load")
  Assert.isTrue(valid.world.flags[11], "the unrelated world flag survives the load")
  Assert.equal(valid.world.variables[3], 9, "the unrelated world variable survives the load")
  Assert.equal(valid.audio.fieldMusicOverride, 8, "the known audio override survives the load")
  Assert.equal(valid.pokedex.seen[1], "CHIKORITA", "known dex sightings survive the load")
  Assert.equal(valid.encounters.steps, 12, "advanced encounter counters survive the load")
  Assert.equal(valid.encounters.roamers["roamer-eevee"].lifecycle, "roaming", "a referenced roamer survives the load")
end

function T.tests.grown_registries_and_rebuilt_terrain_keep_geometry_loading()
  local setup = CompatibilityFixture.rig()
  local bucket = CompatibilityFixture.pausedBucket(setup)
  CompatibilityFixture.growWithUnused(setup)
  Assert.isTrue(
    setup.registry:fingerprint() ~= bucket.registryFingerprint,
    "the unused script must move the registry fingerprint"
  )
  local candidate = baseRecord("save-00000102", bucket)
  candidate.terrainDependencyHash = "rebuilt-terrain-hash"
  local service = serviceFor({ current = contextWith(setup) })
  local valid = assert(service:validate(candidate))
  Assert.equal(valid.saveId, "save-00000102")
  Assert.equal(#valid.scripts.instances, 1, "the paused script instance survives registry growth")
  Assert.equal(#valid.scripts.tasks, 1, "the waiting task survives registry growth")
  Assert.equal(valid.mapId, 60, "rebuilt terrain keeps the saved map")
  Assert.equal(valid.fieldX, 684, "rebuilt terrain keeps the saved position")
  Assert.equal(valid.fieldZ, 393, "rebuilt terrain keeps the saved position")
end

function T.tests.missing_selected_references_reject_naming_owner_and_key()
  local setup = CompatibilityFixture.rig()
  local bagCandidate = baseRecord("save-00000111", quietScripts(setup))
  bagCandidate.bag.pockets.balls = { { item = "NOPE_BALL", quantity = 1 } }
  local bagService = serviceFor({ current = contextWith(setup) })
  local invalid, err = bagService:validate(bagCandidate)
  Assert.isNil(invalid, "a bag naming a removed item must not load")
  Assert.isTrue(failureNamesKey(err, "bag", "NOPE_BALL"), "the failure must name the removed item")
  Assert.equal(bagCandidate.bag.pockets.balls[1].item, "NOPE_BALL", "the rejected record is left untouched")

  local dexSetup = CompatibilityFixture.rig()
  local dexCandidate = baseRecord("save-00000112", quietScripts(dexSetup))
  dexCandidate.pokedex = {
    schema = PokedexSave.initial().schema,
    stateVersion = PokedexSave.initial().stateVersion,
    seen = { "NOT_A_SPECIES" },
    caught = {},
  }
  local dexService = serviceFor({ current = contextWith(dexSetup) })
  invalid, err = dexService:validate(dexCandidate)
  Assert.isNil(invalid, "a dex naming an unknown species must not load")
  Assert.isTrue(failureNamesKey(err, "pokedex", "NOT_A_SPECIES"), "the failure must name the unknown species")
  Assert.equal(dexCandidate.pokedex.seen[1], "NOT_A_SPECIES", "the rejected record is left untouched")

  local roamerSetup = CompatibilityFixture.rig()
  local roamerCandidate = baseRecord("save-00000113", quietScripts(roamerSetup))
  roamerCandidate.encounters.roamers = {
    ["roamer-stray"] = {
      key = "roamer-stray",
      stateVersion = 1,
      mon = { species = "NOT_A_SPECIES" },
      location = 60,
      lifecycle = "roaming",
      revision = 0,
    },
  }
  local roamerService = serviceFor({ current = contextWith(roamerSetup) })
  invalid, err = roamerService:validate(roamerCandidate)
  Assert.isNil(invalid, "a roamer naming a missing species must not load")
  Assert.isTrue(failureNamesKey(err, "encounters", "NOT_A_SPECIES"), "the failure must name the missing species")
  Assert.equal(
    roamerCandidate.encounters.roamers["roamer-stray"].mon.species,
    "NOT_A_SPECIES",
    "the rejected record is left untouched"
  )

  local audioSetup = CompatibilityFixture.rig()
  local audioCandidate = baseRecord("save-00000114", quietScripts(audioSetup))
  audioCandidate.audio = { fieldMusicOverride = 99 }
  local audioService = serviceFor({ current = contextWith(audioSetup) })
  invalid, err = audioService:validate(audioCandidate)
  Assert.isNil(invalid, "an audio override outside the known sequences must not load")
  Assert.isTrue(failureNamesKey(err, "audio", "99"), "the failure must name the unknown override")
  Assert.equal(audioCandidate.audio.fieldMusicOverride, 99, "the rejected record is left untouched")
end

function T.tests.out_of_range_state_rejects_and_failed_saves_keep_published_bytes()
  local setup = CompatibilityFixture.rig()
  local healthCandidate = baseRecord("save-00000121", quietScripts(setup))
  healthCandidate.mons.party.mons[1].condition.currentHp = 77777
  local healthService = serviceFor({ current = contextWith(setup) })
  local invalid, err = healthService:validate(healthCandidate)
  Assert.isNil(invalid, "a mon above its valid health maximum must not load")
  Assert.isTrue(failureNamesKey(err, "mons", "77777"), "the failure must name the offending value")
  Assert.equal(healthCandidate.mons.party.mons[1].condition.currentHp, 77777, "the rejected record is left untouched")

  local counterSetup = CompatibilityFixture.rig()
  local counterCandidate = baseRecord("save-00000122", quietScripts(counterSetup))
  counterCandidate.encounters.repelSteps = -1
  local counterService = serviceFor({ current = contextWith(counterSetup) })
  invalid, err = counterService:validate(counterCandidate)
  Assert.isNil(invalid, "a negative encounter counter must not load")
  Assert.isTrue(failureNamesKey(err, "encounters", "repel"), "the failure must name the offending counter")
  Assert.equal(counterCandidate.encounters.repelSteps, -1, "the rejected record is left untouched")

  local storeSetup = CompatibilityFixture.rig()
  local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
  local SaveFs = require("libs.storage.src.SaveFs")
  local FakeCache = require("tests.support.FakeCache")
  local backend = FakeCache.new()
  local validation = serviceFor({ current = contextWith(storeSetup) })
  local store = GameSaveStore.new(SaveFs.global(backend), {
    recordValidate = function(record)
      return validation:validate(record)
    end,
  })
  local saveId = store:reserve()
  local first = baseRecord(saveId, quietScripts(storeSetup))
  store:publishFirst(first)
  local payloadPath = "saves/games/" .. saveId .. ".lua"
  local publishedPayload = backend.files[payloadPath]
  local publishedCatalog = backend.files["saves/catalog.lua"]
  Assert.notNil(publishedPayload, "the published payload must reach the save root")
  local before = assert(store:load(saveId))
  local broken = baseRecord(saveId, quietScripts(storeSetup))
  broken.bag.pockets.balls = { { item = "NOPE_BALL", quantity = 1 } }
  local written, failure = pcall(function()
    return store:save(broken)
  end)
  Assert.isFalse(written, "the invalid record must not save")
  Assert.isTrue(Errors.is(failure))
  Assert.equal(failure.code, "GAME_SAVE_BUCKET_INVALID")
  Assert.equal(backend.files[payloadPath], publishedPayload, "a failed save must not rewrite the last payload")
  Assert.equal(backend.files["saves/catalog.lua"], publishedCatalog, "a failed save must not touch the catalog")
  Assert.deepEqual(store:load(saveId), before, "the last save still loads unchanged")
end

---@param value unknown
---@return unknown detached plain copy
local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = deepCopy(item)
  end
  return out
end

---@return table scenario parts with a human side and a native-AI side
local function duel()
  local SessionFixture = require("libs.battle.tests.session_fixture")
  return {
    sides = {
      SessionFixture.side(1, { 1 }),
      SessionFixture.side(2, { 2 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "human", {
        SessionFixture.combatant(1, 11),
        SessionFixture.combatant(2, 12),
      }),
      SessionFixture.participant(2, 2, "ai", {
        SessionFixture.combatant(3, 23),
        SessionFixture.combatant(4, 24),
      }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 3),
    },
    inventories = {},
  }
end

---@param request table pending decision request
---@return table[] one strike per addressed actor
local function strikeEveryone(request)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local choices = {}
  for _, actor in ipairs(request.actors) do
    choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
  end
  return choices
end

---@return table executable identity under test
local function executableIdentity()
  local SessionFixture = require("libs.battle.tests.session_fixture")
  return {
    engineBuild = "test-session-kernel",
    ruleset = SessionFixture.RULESET,
    format = SessionFixture.FORMAT,
    contentRevision = "session-tests",
    randomAlgorithm = "gen4-lcrng",
    seed = SessionFixture.RANDOM_SEED,
  }
end

function T.tests.recorded_battles_keep_exact_identity_while_saves_soften()
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local Replay = SessionFixture.requirePresent(
    "libs.battle.src.BattleReplay",
    "strict executable envelopes own deterministic battle replays"
  )
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local contracts = SessionFixture.sessionContracts()
  local aiStream = BattleRng.new(11259375)
  local drawLog = {}
  local watched = {
    nextU16 = function(_, label, cause)
      local raw = aiStream:nextU16(label, cause)
      drawLog[#drawLog + 1] = { raw = raw, reason = label, ordinal = #drawLog + 1, cause = cause }
      return raw
    end,
    capture = function(_)
      return aiStream:capture()
    end,
  }
  local Opponents = SessionFixture.requirePresent(
    "libs.hgss.src.battle.HgssOpponentControllers",
    "wild and scripted policies answer through the shared reply shape"
  )
  local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(duel()))
  local decisions, events = {}, {}
  local boundaryRng = nil
  local restored = false
  local outcome = nil
  for _ = 1, 512 do
    local frame = session:advance(1)
    if frame.events ~= nil then
      for _, event in ipairs(frame.events) do
        events[#events + 1] = event
      end
    end
    if frame.status == "ended" then
      outcome = frame.outcome
      break
    end
    Assert.equal(frame.status, "waiting", "open battles wait for decisions")
    if not restored then
      restored = true
      local held = session:capture()
      boundaryRng = deepCopy(held.rng)
      local continuing = contracts.Session.restore(held, SessionFixture.makeContent())
      Assert.notNil(continuing, "restoring resumes from captured data")
      session:dispose()
      session = continuing
    end
    for _, request in ipairs(frame.request.requests) do
      local reply
      if request.controller == "ai" then
        reply = Opponents.wild(request, session:view("ai"), watched)
      else
        reply = SessionFixture.replyFor(request, strikeEveryone(request))
      end
      decisions[#decisions + 1] = reply
      Assert.isTrue(session:submit(reply), "scripted answers to open requests are accepted")
    end
  end
  Assert.notNil(outcome, "ended battles carry their outcome")
  Assert.notNil(boundaryRng, "the recording crossed its restore boundary")
  local held = session:capture()
  session:dispose()
  local envelope = Replay.capture({
    identity = deepCopy(executableIdentity()),
    scenario = SessionFixture.buildScenario(duel()),
    decisions = decisions,
    externalInputs = {},
    randomTrace = {
      controllerDraws = drawLog,
      kernelBoundaryRng = boundaryRng,
      kernelFinalRng = held.rng,
    },
    expectedEvents = events,
    expectedOutcome = outcome,
  })
  Assert.equal(envelope.schema, "portemon-battle-replay-v1", "replay envelopes carry their versioned schema")
  Replay.validateIdentity(envelope, executableIdentity())
  local exact = Replay.replay(envelope, { budget = 1, content = SessionFixture.makeContent() })
  Assert.isNil(exact.mismatch, "exact replays report no mismatch")

  local changedIdentity = executableIdentity()
  changedIdentity.contentRevision = "softened-build"
  Assert.throws(function()
    Replay.validateIdentity(envelope, changedIdentity)
  end, "a softened executable identity never replays exactly")
  local tampered = deepCopy(envelope)
  tampered.identity = changedIdentity
  local identityMismatch = Replay.replay(tampered, { budget = 1 })
  Assert.isTrue(type(identityMismatch.mismatch) == "table", "changed identity replays report their mismatch")
  Assert.equal(identityMismatch.mismatch.kind, "identity", "changed builds mismatch at the identity boundary")
end

function T.tests.saved_field_progress_continues_after_restart()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = AcceptanceHarness.new({
    gameFactory = function(bootVersion, map)
      return {
        saveId = "save-00000131",
        versionId = bootVersion,
        location = { mapSymbol = map or MAP, fieldX = 4, fieldZ = 13, facing = "north" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(bootVersion, 7),
        bag = require("libs.hgss.src.save.BagSave").empty(),
      }
    end,
  }):boot({
    versionId = versionId,
    map = MAP,
    save = "fresh",
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    Assert.isTrue(
      game.runtime.monService:giveMon({ species = "CHIKORITA", level = 5, heldItem = "NONE", form = 0 }),
      "the round trip needs a live party"
    )
    Assert.isTrue(
      game.runtime.monService:giveMon({ species = "TOTODILE", level = 5, heldItem = "NONE", form = 0 }),
      "the round trip needs a second party member"
    )
    game:save()
    game:restart()
    game:waitForFieldReady()
    Assert.equal(game:snapshot().mapSymbol, MAP, "continuing restores the saved map")
    Assert.equal(game.runtime.monService:partyCount(), 2, "continuing restores the saved party")
    Assert.equal(game.runtime.monService:partyMon(0).species, "CHIKORITA", "continuing restores the saved lead")
    Assert.isNil(game.runtime.errorText, "the round trip runs without a runtime fault")
    Assert.equal(game:renderAttempts(), 0, "the round trip must stop before GPU rendering")
  end, debug.traceback)
  local namespace = game.saveNamespace
  game:close()
  if not ok then
    error(err, 0)
  end
  Assert.isNil(love.filesystem.getInfo(namespace), "teardown removes the isolated save namespace")
end

return T
