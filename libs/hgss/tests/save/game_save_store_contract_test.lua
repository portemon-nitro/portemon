-- Contract tests for the global GameSave catalog. The store owns catalog
-- visibility and canonical game paths; tests inject only the filesystem host
-- boundary and keep all game records in the project-owned schema.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MonsSave = require("libs.mons.src.MonsSave")
local BagSave = require("libs.hgss.src.save.BagSave")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local MartSave = require("libs.hgss.src.save.MartSave")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local PokedexSave = require("libs.hgss.src.save.PokedexSave")
local BattleFrontierRecords = require("libs.hgss.src.save.BattleFrontierRecords")
local SaveFs = require("libs.storage.src.SaveFs")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local GameSave = require("libs.hgss.src.save.GameSave")

local T = {}


local GAME_SCHEMA = GameSave.SCHEMA


local function newStore(backend)
  local loaded, GameSaveStore = pcall(require, "libs.hgss.src.save.GameSaveStore")
  Assert.isTrue(loaded, "global GameSave storage service is not implemented")
  Assert.isTrue(type(GameSaveStore.new) == "function", "global GameSave storage needs a constructor")
  Assert.isTrue(type(SaveFs.global) == "function", "SaveFs needs a global product save root")
  local Store = GameSaveStore --[[@as GameSaveStoreModule]]
  return Store.new(SaveFs.global(backend))
end

local function record(saveId, versionId, overrides)
  local value = {
    schema = GAME_SCHEMA,
    saveId = saveId,
    versionId = versionId,
    playTimeSeconds = 0,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain-" .. versionId,
    facing = "south",
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 0, money = 3000, badges = 0, nationalDex = false },
      options = { textFrame = 0, textSpeed = "mid" },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    fashionCase = FashionCaseState.empty(),
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = {},
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = {},
    mons = MonsSave.empty(7),
    bag = BagSave.empty(),
    mart = MartSave.empty(),
    mailbox = Mailbox.new():capture(),
    photoAlbum = PhotoAlbum.new():capture(),
    encounters = EncounterSave.initial(),
    pokedex = PokedexSave.initial(),
    battleFrontier = BattleFrontierRecords.new():bucket(),
  }
  for key, valueOverride in pairs(overrides or {}) do
    value[key] = valueOverride
  end
  return value
end

local function gamePath(saveId)
  return "saves/games/" .. saveId .. ".lua"
end

local function backupPath(saveId, generation)
  return "saves/backups/" .. saveId .. "." .. generation .. ".lua"
end

local function v1MonsBucket()
  return {
    schema = "g4-mons-save-v1",
    catalogFingerprint = "legacy-catalog",
    rng = { state = 7, calls = 0 },
    party = { max = 6, mons = {} },
  }
end

local function v4Payload(saveId, versionId)
  local value = record(saveId, versionId)
  value.schema = "g4-game-save-v4"
  value.playerData.profile.badges = 0
  value.fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" }
  value.scripts = {
    schema = "g4-script-save-v1",
    registryFingerprint = "legacy-registry",
    taskFingerprint = "legacy-tasks",
    capturedAtSimulationTick = 0,
    nextEnvironmentId = 0,
    nextInstanceId = 0,
    nextTaskId = 0,
    environments = {},
    instances = {},
    tasks = {},
  }
  value.mons = v1MonsBucket()
  value.mart = nil
  value.mailbox = nil
  value.photoAlbum = nil
  value.fashionCase = nil
  return value
end

local function findEntry(entries, saveId)
  for _, entry in ipairs(entries) do
    if entry.saveId == saveId then
      return entry
    end
  end
  return nil
end

---@param fn fun()
---@return Errors.Error
local function callFailure(fn)
  local ok, first, second = pcall(fn)
  if not ok then
    return first --[[@as Errors.Error]]
  end
  Assert.isNil(first, "the failing storage operation must not return a record or success value")
  Assert.notNil(second, "the failing storage operation must return its error")
  return second --[[@as Errors.Error]]
end

local function failOn(backend, method, occurrence)
  local original = assert(backend[method])
  local calls = 0
  rawset(backend, method, function(self, ...)
    calls = calls + 1
    if calls == occurrence then
      return false, "injected " .. method .. " failure"
    end
    return original(self, ...)
  end)
end

local function expectVisible(store, saveId)
  local entries = assert(store:list())
  local entry = findEntry(entries, saveId)
  Assert.notNil(entry, "published save must be catalog-visible")
  Assert.isNil(entry and entry.error, "a valid published save must not list an error")
  return entries
end

function T.multiple_versions_use_one_global_catalog_and_strict_game_records()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local firstId = store:reserve()
  local secondId = store:reserve()
  local first = record(firstId, "heartgold")
  local second = record(secondId, "soulsilver")
  store:publishFirst(first)
  store:publishFirst(second)

  local entries = expectVisible(store, firstId)
  Assert.notNil(findEntry(entries, secondId))
  Assert.equal(assert(store:load(firstId)).versionId, "heartgold")
  Assert.equal(assert(store:load(secondId)).versionId, "soulsilver")
  Assert.notNil(backend.files["saves/catalog.lua"])
  Assert.notNil(backend.files[gamePath(firstId)])
  Assert.notNil(backend.files[gamePath(secondId)])
  Assert.isNil(backend.files["saves/heartgold/field-session.lua"])
  Assert.isNil(backend.files["saves/soulsilver/field-session.lua"])

  local invalidId = store:reserve()
  local invalid = record(invalidId, "heartgold", { schema = "g4-field-save-v3" })
  callFailure(function()
    store:publishFirst(invalid)
  end)
end

function T.load_trusts_nested_buckets_and_reads_no_generated_caches()
  local backend = FakeCache.new()
  local generatedReads = 0
  local reader = backend.read
  function backend.read(self, path)
    if type(path) == "string" and path:sub(1, 6) ~= "saves/" then
      generatedReads = generatedReads + 1
    end
    return reader(self, path)
  end
  local store = newStore(backend)
  local saveId = store:reserve()
  -- Valid envelope, garbage nested buckets: the owning runtime domains read
  -- that state later, so publication and load both succeed without touching
  -- generated caches.
  local trusted = record(saveId, "heartgold", { mons = { fingerprint = "drifted" }, world = {}, bag = {} })
  store:publishFirst(trusted)
  local loaded = assert(store:load(saveId))
  Assert.equal(loaded.saveId, saveId)
  Assert.equal(loaded.mons.fingerprint, "drifted")
  local entries = assert(store:list())
  Assert.equal(#entries, 1)
  Assert.isNil(entries[1].error)
  Assert.equal(generatedReads, 0, "persistence load performs no generated-cache reads")
end

function T.reservation_survives_restart_without_payload_or_visibility_and_never_reuses_ids()
  local backend = FakeCache.new()
  local firstStore = newStore(backend)
  local first = firstStore:reserve()
  Assert.notNil(first)
  Assert.isNil(backend.files[gamePath(first)])
  Assert.isNil(findEntry(assert(firstStore:list()), first))

  local restarted = newStore(backend)
  local second = restarted:reserve()
  Assert.notNil(second)
  Assert.isFalse(first == second, "a later reservation must not reuse an abandoned identity")
  Assert.isNil(backend.files[gamePath(first)])
  Assert.isNil(findEntry(assert(restarted:list()), first))
  Assert.notNil(backend.files["saves/catalog.lua"], "allocation state must be durable")
end

function T.first_publication_normalizes_before_catalog_visibility_and_can_retry_an_orphan()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local saveId = store:reserve()
  local value = record(saveId, "heartgold")

  failOn(backend, "write", 1)
  callFailure(function()
    store:publishFirst(value)
  end)
  Assert.isNil(findEntry(assert(store:list()), saveId))
  Assert.isNil(backend.files[gamePath(saveId)])

  local payloadFailureBackend = FakeCache.new()
  local payloadFailureStore = newStore(payloadFailureBackend)
  local payloadFailureId = payloadFailureStore:reserve()
  failOn(payloadFailureBackend, "replace", 1)
  callFailure(function()
    payloadFailureStore:publishFirst(record(payloadFailureId, "heartgold"))
  end)
  Assert.isNil(findEntry(assert(payloadFailureStore:list()), payloadFailureId))
  Assert.isNil(payloadFailureBackend.files[gamePath(payloadFailureId)])
  Assert.isNil(payloadFailureBackend.files[gamePath(payloadFailureId) .. ".tmp"])

  local retryBackend = FakeCache.new()
  local retryStore = newStore(retryBackend)
  local retryId = retryStore:reserve()
  local retryValue = record(retryId, "heartgold")
  failOn(retryBackend, "replace", 2)
  callFailure(function()
    retryStore:publishFirst(retryValue)
  end)
  Assert.isNil(findEntry(assert(retryStore:list()), retryId))
  Assert.notNil(retryBackend.files[gamePath(retryId)], "catalog failure may leave an invisible orphan payload")

  retryStore:publishFirst(retryValue)
  Assert.notNil(findEntry(assert(retryStore:list()), retryId))
  retryValue.avatar = { state = "walking" }
  Assert.deepEqual(assert(retryStore:load(retryId)), retryValue)
end

function T.malformed_nil_catalog_and_payload_are_structured_errors()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local _ = store:reserve()
  backend.files["saves/catalog.lua"] = LuaWriter.encode(nil)
  local catalogErr = callFailure(function()
    store:list()
  end)
  Assert.equal(catalogErr.code, "GAME_SAVE_CATALOG_INVALID")

  local payloadBackend = FakeCache.new()
  local payloadStore = newStore(payloadBackend)
  local payloadId = payloadStore:reserve()
  payloadStore:publishFirst(record(payloadId, "heartgold"))
  payloadBackend.files[gamePath(payloadId)] = LuaWriter.encode(nil)
  local entries = assert(payloadStore:list())
  local entry = findEntry(entries, payloadId)
  Assert.notNil(entry and entry.error)
  local payloadError = assert(entry and entry.error)
  Assert.equal(payloadError.code, "GAME_SAVE_INVALID")
end

function T.update_and_delete_failures_preserve_a_valid_checkpoint_and_order()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local firstId = store:reserve()
  local secondId = store:reserve()
  local first = record(firstId, "heartgold")
  local second = record(secondId, "soulsilver")
  store:publishFirst(first)
  store:publishFirst(second)
  local before = assert(store:list())

  local replacement = record(firstId, "heartgold", { playTimeSeconds = 12 })
  failOn(backend, "replace", 1)
  callFailure(function()
    store:save(replacement)
  end)
  -- Loading canonicalizes the envelope: normalization backfills the
  -- reserved avatar field to walking.
  first.avatar = { state = "walking" }
  Assert.deepEqual(assert(store:load(firstId)), first)
  local afterFailedUpdate = assert(store:list())
  Assert.equal(afterFailedUpdate[1].saveId, before[1].saveId)
  Assert.equal(afterFailedUpdate[2].saveId, before[2].saveId)

  store:save(replacement)
  Assert.equal(assert(store:load(firstId)).playTimeSeconds, 12)
  local afterUpdate = assert(store:list())
  Assert.equal(afterUpdate[1].saveId, before[1].saveId)
  Assert.equal(afterUpdate[2].saveId, before[2].saveId)

  failOn(backend, "remove", 1)
  callFailure(function()
    store:delete(firstId)
  end)
  local failedDeleteEntries = assert(store:list())
  local failedDeleteEntry = findEntry(failedDeleteEntries, firstId)
  if failedDeleteEntry ~= nil then
    Assert.isNil(failedDeleteEntry.error, "a failed delete must not expose a broken visible save")
    Assert.equal(assert(store:load(firstId)).playTimeSeconds, 12)
  end

  store:delete(firstId)
  Assert.isNil(findEntry(assert(store:list()), firstId))
  Assert.isNil(backend.files[gamePath(firstId)])
  Assert.notNil(findEntry(assert(store:list()), secondId), "deleting one save must not affect another")
end

function T.catalog_authority_preserves_errors_and_ignores_orphans_and_reserved_gaps()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local validId = store:reserve()
  local corruptId = store:reserve()
  local oldId = store:reserve()
  local abandonedId = store:reserve()
  store:publishFirst(record(validId, "heartgold"))
  store:publishFirst(record(corruptId, "heartgold"))
  store:publishFirst(record(oldId, "soulsilver"))

  backend.files[gamePath(corruptId)] = "return { schema = 'not-lua-save' }"
  backend.files[gamePath(oldId)] = LuaWriter.encode({
    schema = "g4-field-save-v3",
    saveId = oldId,
    versionId = "soulsilver",
  })
  local orphanId = "save-orphan"
  backend.files[gamePath(orphanId)] = LuaWriter.encode(record(orphanId, "heartgold"))

  local entries = assert(store:list())
  Assert.equal(#entries, 3, "only catalog-referenced IDs may be listed")
  Assert.equal(entries[1].saveId, oldId)
  Assert.equal(entries[2].saveId, corruptId)
  Assert.equal(entries[3].saveId, validId)
  Assert.notNil(findEntry(entries, corruptId).error)
  Assert.notNil(findEntry(entries, oldId).error)
  Assert.isNil(findEntry(entries, orphanId))
  Assert.isNil(findEntry(entries, abandonedId))

  callFailure(function()
    store:load(corruptId)
  end)
  callFailure(function()
    store:load(oldId)
  end)
  store:delete(corruptId)
  store:delete(oldId)
  Assert.isNil(findEntry(assert(store:list()), corruptId))
  Assert.isNil(findEntry(assert(store:list()), oldId))
  Assert.notNil(findEntry(assert(store:list()), validId))
end

function T.metadata_listing_reads_envelopes_and_keeps_ordering_and_errors()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local firstId = store:reserve()
  local secondId = store:reserve()
  store:publishFirst(record(firstId, "heartgold"))
  store:publishFirst(record(secondId, "soulsilver"))
  backend.files[gamePath(secondId)] = LuaWriter.encode(record(secondId, "soulsilver", { playerData = {} }))

  local metadata = assert(store:listMetadata())
  Assert.equal(#metadata, 2)
  Assert.equal(metadata[1].saveId, secondId)
  Assert.equal(metadata[2].saveId, firstId)
  Assert.equal(metadata[2].versionId, "heartgold")
  Assert.equal(assert(metadata[2].playerData and metadata[2].playerData.profile).name, "GOLD")
  Assert.isNil(metadata[2].error)
  local broken = assert(findEntry(metadata, secondId))
  Assert.isTrue(Errors.is(broken.error), "a malformed envelope lists its error, never a silent card")
  Assert.equal(broken.error.code, "GAME_SAVE_BUCKET_INVALID")

  local listed = assert(store:list())
  Assert.equal(#listed, 2, "listing keeps the same catalog ordering")
  Assert.equal(listed[1].saveId, secondId)
  Assert.equal(listed[2].saveId, firstId)
end

function T.metadata_listing_exposes_v4_envelopes_without_normalization()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local v4Id = store:reserve()
  local currentId = store:reserve()
  local unknownId = store:reserve()
  store:publishFirst(record(v4Id, "heartgold"))
  store:publishFirst(record(currentId, "soulsilver"))
  store:publishFirst(record(unknownId, "heartgold"))
  -- Historical and future payloads arrive as stored bytes: the v4 record
  -- stays a v4 record on disk, and the future record stays unreadable.
  backend.files[gamePath(v4Id)] = LuaWriter.encode(v4Payload(v4Id, "heartgold"))
  local unknown = record(unknownId, "heartgold")
  unknown.schema = "g4-game-save-v9"
  backend.files[gamePath(unknownId)] = LuaWriter.encode(unknown)

  local metadata = assert(store:listMetadata())
  Assert.equal(#metadata, 3)
  Assert.equal(metadata[1].saveId, unknownId)
  Assert.equal(assert(metadata[1].error).code, "GAME_SAVE_SCHEMA_UNSUPPORTED")
  Assert.equal(metadata[2].saveId, currentId)
  Assert.equal(metadata[2].versionId, "soulsilver")
  Assert.isNil(metadata[2].error)
  Assert.equal(metadata[3].saveId, v4Id)
  Assert.isNil(metadata[3].error, "a known v4 envelope remains visible")
  Assert.equal(metadata[3].versionId, "heartgold")
  Assert.equal(assert(metadata[3].playerData and metadata[3].playerData.profile).name, "GOLD")

  -- Loading migrates the stored v4 record to current through normalization.
  local loaded = assert(store:load(v4Id))
  Assert.equal(loaded.schema, GameSave.SCHEMA)
end

function T.metadata_listing_distinguishes_historical_from_current_and_future_schemas()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local historicalId = store:reserve()
  local currentId = store:reserve()
  local futureId = store:reserve()
  -- A master-era record: v5 schema with national Dex plus mart state,
  -- no fashion-case state. It stays listable as stored bytes.
  local historical = v4Payload(historicalId, "heartgold")
  historical.schema = "g4-game-save-v5"
  historical.playerData.profile.nationalDex = false
  historical.mart = MartSave.empty()
  local current = record(currentId, "soulsilver")
  current.schema = GameSave.SCHEMA
  local future = record(futureId, "heartgold")
  future.schema = "g4-game-save-v9"
  store:publishFirst(record(historicalId, "heartgold"))
  store:publishFirst(current)
  store:publishFirst(record(futureId, "heartgold"))
  backend.files[gamePath(historicalId)] = LuaWriter.encode(historical)
  backend.files[gamePath(futureId)] = LuaWriter.encode(future)

  local metadata = assert(store:listMetadata())
  Assert.equal(#metadata, 3)
  local historicalEntry = findEntry(metadata, historicalId)
  Assert.notNil(historicalEntry, "a master envelope stays listable")
  Assert.isNil(historicalEntry.error)
  Assert.equal(historicalEntry.versionId, "heartgold")
  local currentEntry = findEntry(metadata, currentId)
  Assert.notNil(currentEntry, "the current envelope lists without deep validation")
  Assert.isNil(currentEntry.error)
  Assert.equal(currentEntry.versionId, "soulsilver")
  local futureEntry = findEntry(metadata, futureId)
  Assert.notNil(futureEntry, "a future envelope still lists its error")
  Assert.equal(assert(futureEntry.error).code, "GAME_SAVE_SCHEMA_UNSUPPORTED")
end

function T.deleted_ids_are_not_reusable_and_listing_follows_publication_order()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local firstId = store:reserve()
  local secondId = store:reserve()
  store:publishFirst(record(secondId, "soulsilver"))
  store:publishFirst(record(firstId, "heartgold"))
  -- First publication appends in publication order, and listing
  -- enumerates that stored order newest-first.
  local entries = assert(store:list())
  Assert.equal(entries[1].saveId, firstId)
  Assert.equal(entries[2].saveId, secondId)

  store:delete(firstId)
  callFailure(function()
    store:publishFirst(record(firstId, "heartgold"))
  end)
  local thirdId = store:reserve()
  Assert.isFalse(thirdId == firstId)
  Assert.equal(thirdId, "save-00000003")
end

function T.hostile_save_ids_are_rejected_before_path_resolution()
  local store = newStore(FakeCache.new())
  local _, err = store:load("../escape")
  Assert.notNil(err)
  Assert.equal(assert(err).code, "GAME_SAVE_SAVE_ID_INVALID")
end

function T.successive_updates_retain_three_prior_raw_payloads_and_prune_older_generations()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local saveId = store:reserve()
  store:publishFirst(record(saveId, "heartgold", { playTimeSeconds = 0 }))
  local bytesA = backend.files[gamePath(saveId)]
  Assert.notNil(bytesA)
  Assert.isNil(backend.files[backupPath(saveId, 1)], "first publication has no predecessor to preserve")

  store:save(record(saveId, "heartgold", { playTimeSeconds = 1 }))
  local bytesB = backend.files[gamePath(saveId)]
  Assert.notNil(bytesB)
  Assert.equal(backend.files[backupPath(saveId, 1)], bytesA)

  store:save(record(saveId, "heartgold", { playTimeSeconds = 2 }))
  local bytesC = backend.files[gamePath(saveId)]
  Assert.equal(backend.files[backupPath(saveId, 1)], bytesB)
  Assert.equal(backend.files[backupPath(saveId, 2)], bytesA)

  store:save(record(saveId, "heartgold", { playTimeSeconds = 3 }))
  local bytesD = backend.files[gamePath(saveId)]
  Assert.equal(backend.files[backupPath(saveId, 1)], bytesC)
  Assert.equal(backend.files[backupPath(saveId, 2)], bytesB)
  Assert.equal(backend.files[backupPath(saveId, 3)], bytesA)

  store:save(record(saveId, "heartgold", { playTimeSeconds = 4 }))
  local bytesE = backend.files[gamePath(saveId)]
  Assert.notNil(bytesE)
  Assert.isTrue(bytesE ~= bytesD, "the newest snapshot becomes current")
  Assert.equal(backend.files[backupPath(saveId, 1)], bytesD)
  Assert.equal(backend.files[backupPath(saveId, 2)], bytesC)
  Assert.equal(backend.files[backupPath(saveId, 3)], bytesB)
  Assert.isNil(backend.files[backupPath(saveId, 4)], "no fourth prior generation is retained")
  Assert.isTrue(bytesE ~= bytesA, "the oldest payload has aged out of the retained history")
  Assert.isNil(backend.files[gamePath(saveId) .. ".tmp"], "no staged replacement lingers after success")

  store:delete(saveId)
  Assert.isNil(backend.files[gamePath(saveId)])
  Assert.isNil(backend.files[gamePath(saveId) .. ".tmp"])
  for generation = 1, 3 do
    Assert.isNil(backend.files[backupPath(saveId, generation)])
    Assert.isNil(backend.files[backupPath(saveId, generation) .. ".tmp"])
  end
end

function T.failed_backup_rotation_leaves_prior_current_authoritative()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local saveId = store:reserve()
  store:publishFirst(record(saveId, "heartgold", { playTimeSeconds = 0 }))
  local bytesA = backend.files[gamePath(saveId)]
  store:save(record(saveId, "heartgold", { playTimeSeconds = 1 }))
  local bytesB = backend.files[gamePath(saveId)]
  Assert.notNil(bytesA)
  Assert.notNil(bytesB)

  -- Destination-targeted injection: only prior-generation staging fails, so
  -- the failure proves the current payload waits for its predecessors.
  local originalWrite = assert(backend.write)
  rawset(backend, "write", function(self, path, data)
    if type(path) == "string" and path:find("backups/", 1, true) then
      return false, "injected prior-generation staging failure"
    end
    return originalWrite(self, path, data)
  end)
  local originalReplace = assert(backend.replace)
  rawset(backend, "replace", function(self, source, destination)
    if type(source) == "string" and source:find("backups/", 1, true) then
      return false, "injected prior-generation staging failure"
    end
    if type(destination) == "string" and destination:find("backups/", 1, true) then
      return false, "injected prior-generation staging failure"
    end
    return originalReplace(self, source, destination)
  end)

  local failure = callFailure(function()
    store:save(record(saveId, "heartgold", { playTimeSeconds = 2 }))
  end)
  Assert.notNil(failure)
  Assert.equal(backend.files[gamePath(saveId)], bytesB, "the prior current payload stays authoritative")
  Assert.isNil(backend.files[gamePath(saveId) .. ".tmp"], "the staged replacement is cleaned after failure")
  for generation = 1, 3 do
    local history = backend.files[backupPath(saveId, generation)]
    if history ~= nil then
      Assert.isTrue(
        history == bytesA or history == bytesB,
        "retained history holds only previously published bytes"
      )
    end
    Assert.isNil(backend.files[backupPath(saveId, generation) .. ".tmp"])
  end
end

function T.updates_persist_owner_snapshots_without_envelope_preflight()
  local backend = FakeCache.new()
  local generatedReads = 0
  local reader = backend.read
  function backend.read(self, path)
    if type(path) == "string" and path:sub(1, 6) ~= "saves/" then
      generatedReads = generatedReads + 1
    end
    return reader(self, path)
  end
  local store = newStore(backend)
  local saveId = store:reserve()
  store:publishFirst(record(saveId, "heartgold", { playTimeSeconds = 0 }))
  -- An envelope value the read boundary rejects, still plain serializable data.
  local update = record(saveId, "heartgold", { playTimeSeconds = 1, mapId = -1 })
  local normalized, normalizeErr = GameSave.normalize(update)
  Assert.isNil(normalized)
  Assert.equal(assert(normalizeErr).code, "GAME_SAVE_FIELD_INVALID")

  Assert.isTrue(store:save(update))
  Assert.equal(generatedReads, 0, "publication performs no generated-cache reads")
  local saveFs = SaveFs.global(backend)
  local persisted = assert(saveFs:loadLua("games/" .. saveId .. ".lua"))
  Assert.equal(persisted.mapId, -1, "the owner snapshot reaches durable storage byte-identically")
  -- The read boundary still owns routing safety: a later load may reject
  -- the same stored bytes the write boundary trusted.
  local loadFailure = callFailure(function()
    store:load(saveId)
  end)
  Assert.equal(loadFailure.code, "GAME_SAVE_FIELD_INVALID")
end

function T.relaxed_catalog_history_keeps_published_saves_reachable()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local firstId = store:reserve()
  local secondId = store:reserve()
  store:publishFirst(record(firstId, "heartgold"))
  store:publishFirst(record(secondId, "soulsilver"))

  local saveFs = SaveFs.global(backend)
  local catalog = assert(saveFs:loadLua("catalog.lua"))
  -- Nonessential history edits only: unknown metadata plus reordered
  -- allocation history and stored visible order, while addressing facts
  -- (schema, nextId above every known numeric identity, dense safe-id
  -- arrays, unique visible entries) stay intact.
  catalog.extraMetadata = { note = "kept" }
  catalog.allocatedIds = { secondId, firstId }
  catalog.saveIds = { secondId, firstId }
  backend.files["saves/catalog.lua"] = LuaWriter.encode(catalog)

  local restarted = newStore(backend)
  local metadata = assert(restarted:listMetadata())
  Assert.equal(#metadata, 2)
  Assert.equal(metadata[1].saveId, firstId)
  Assert.equal(metadata[2].saveId, secondId)
  Assert.notNil(assert(restarted:load(firstId)))
  Assert.notNil(assert(restarted:load(secondId)))
  local thirdId = restarted:reserve()
  Assert.equal(thirdId, "save-00000003")
  local rewritten = assert(saveFs:loadLua("catalog.lua"))
  Assert.equal(assert(rewritten.extraMetadata).note, "kept")
end

return { tests = T }
