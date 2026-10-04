-- Transaction contract over the canonical save validator/store and an
-- isolated SaveFs backend.

local Assert = require("tests.support.Assert")
local Fixture = require("app.tests.support.SaveEditorFixture")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")

local T = {}

local function sessionModule()
  local loaded, Session = pcall(require, "app.src.saveeditor.SaveEditorSession")
  Assert.isTrue(loaded, "the save editor transaction must support staged money and named flag edits")
  return Session
end

local function sessionFor(fixture)
  local Session = sessionModule()
  return Session.new({
    record = fixture.initial,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  })
end

local function monServiceFor(fixture, bucket)
  local profile = fixture.initial.playerData.profile
  return HgssMonService.new({
    catalog = fixture.context.monCatalog,
    bucket = bucket or fixture.initial.mons,
    profile = { name = profile.name, gender = profile.gender, trainerId = profile.trainerId },
    game = fixture.initial.versionId,
    language = fixture.context.language,
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    date = CatalogFixture.metDate(),
    mapSection = 7,
  })
end

local function ok(result)
  Assert.isTrue(result.ok, result.error and result.error.message or "save editor operation should succeed")
  return result
end

local function cleanLog(backend)
  local calls = {}
  for _, method in ipairs({ "write", "replace", "remove" }) do
    local selectedMethod = method
    local original = assert(backend[selectedMethod])
    rawset(backend, selectedMethod, function(self, path, destination)
      calls[#calls + 1] = { method = selectedMethod, path = path, destination = destination }
      return original(self, path, destination)
    end)
  end
  return calls
end

function T.edit_discard_and_save_preserve_unowned_canonical_state()
  local fixture = Fixture.new()
  local calls = cleanLog(fixture.backend)
  local session = sessionFor(fixture)
  Assert.deepEqual(calls, {}, "opening a save must not write")

  local changedMoney = ok(session:setMoney(4500))
  Assert.isTrue(changedMoney.changed)
  local changedFlag = ok(session:setFlag("FLAG_HIDDENITEM_D42R0101_HYPER_POTION", false))
  Assert.isTrue(changedFlag.changed)
  Assert.isTrue(session:isDirty())
  Assert.deepEqual(calls, {}, "staging edits must not write")

  ok(session:setMoney(fixture.initial.playerData.profile.money))
  ok(session:setFlag("FLAG_HIDDENITEM_D42R0101_HYPER_POTION", true))
  Assert.isFalse(session:isDirty(), "returning owned values to baseline clears dirtiness")
  Assert.deepEqual(calls, {}, "reverting staged values must not write")
  local noChange = ok(session:save())
  Assert.isFalse(noChange.changed)
  Assert.deepEqual(calls, {}, "no-op save must not write")

  ok(session:setMoney(4500))
  ok(session:setFlag("FLAG_HIDDENITEM_D42R0101_HYPER_POTION", false))
  local candidate = session:captureCandidate()
  Assert.equal(candidate.playerData.profile.money, 4500)
  Assert.isNil(candidate.world.flags[817])
  local expected = fixture.copy(fixture.initial)
  expected.playerData.profile.money = 4500
  expected.world.flags[817] = nil
  Assert.deepEqual(candidate, expected, "candidate replaces only the owned scalar and flag domains")

  session:discard()
  Assert.isFalse(session:isDirty())
  Assert.deepEqual(calls, {}, "discard must not write")
  Assert.deepEqual(session:captureCandidate(), fixture.initial)

  ok(session:setMoney(4500))
  ok(session:setFlag("FLAG_HIDDENITEM_D42R0101_HYPER_POTION", false))
  ok(session:save())
  local published = assert(fixture.store:load(fixture.saveId))
  Assert.deepEqual(published, expected, "saved canonical record contains only supported changes")
  Assert.deepEqual(published.playerData.options, fixture.initial.playerData.options)
  Assert.deepEqual(published.playerData.profile.badges, fixture.initial.playerData.profile.badges)
  Assert.deepEqual(published.world.variables, fixture.initial.world.variables)
  Assert.deepEqual(published.world.objects, fixture.initial.world.objects)
  Assert.deepEqual(published.world.rng, fixture.initial.world.rng)
  Assert.deepEqual(published.scripts, fixture.initial.scripts)
  Assert.deepEqual(published.bag, fixture.initial.bag)
  Assert.deepEqual(published.mons, fixture.initial.mons)
  Assert.deepEqual(published.avatar, fixture.initial.avatar)
  Assert.deepEqual(published.audio, fixture.initial.audio)
  Assert.isTrue(#calls > 0, "a changed Save publishes through storage")
  for _, call in ipairs(calls) do
    Assert.isTrue(
      call.path:match("editor%-backups/") ~= nil or call.path:match("games/") ~= nil,
      "editor Save writes only its checkpoint and the published game save"
    )
  end

  local savedRevision = session:revision()
  local sameFlag = session:setFlag("FLAG_HIDDENITEM_D42R0101_HYPER_POTION", false)
  Assert.isTrue(sameFlag.ok)
  Assert.isFalse(sameFlag.changed)
  Assert.equal(session:revision(), savedRevision)
  Assert.isFalse(session:isDirty())

  ok(session:setMoney(4600))
  Assert.isTrue(session:isDirty())
  Assert.isTrue(session:discard())
  Assert.isFalse(session:isDirty())
  Assert.deepEqual(session:captureCandidate(), published, "Discard restores the latest saved baseline")
end

function T.dialogue_frame_stages_discards_and_saves_with_player_options()
  local fixture = Fixture.new()
  local session = sessionFor(fixture)
  local baselineOptions = fixture.copy(fixture.initial.playerData.options)

  Assert.equal(session:snapshot().frameIndex, fixture.initial.playerData.options.textFrame)
  local changed = ok(session:setFrameIndex(2))
  Assert.isTrue(changed.changed)
  Assert.equal(session:snapshot().frameIndex, 2)
  Assert.isTrue(session:isDirty())
  local candidate = session:captureCandidate()
  Assert.equal(candidate.playerData.options.textFrame, 2)
  Assert.equal(candidate.playerData.options.textSpeed, baselineOptions.textSpeed)
  Assert.deepEqual(candidate.playerData.profile, fixture.initial.playerData.profile)

  ok(session:setFrameIndex(baselineOptions.textFrame))
  Assert.isFalse(session:isDirty(), "reverting to the baseline frame clears dirtiness")
  ok(session:setFrameIndex(2))

  session:discard()
  Assert.equal(session:snapshot().frameIndex, baselineOptions.textFrame)
  Assert.isFalse(session:isDirty())
  Assert.deepEqual(session:captureCandidate(), fixture.initial)

  ok(session:setFrameIndex(2))
  ok(session:save())
  local published = assert(fixture.store:load(fixture.saveId))
  Assert.equal(published.playerData.options.textFrame, 2)
  Assert.equal(published.playerData.options.textSpeed, baselineOptions.textSpeed)
  Assert.deepEqual(published.playerData.profile, fixture.initial.playerData.profile)

  Assert.isFalse(session:isDirty(), "reverting the staged frame to the saved baseline clears dirtiness")
  local revision = session:revision()
  local invalid = session:setFrameIndex(99)
  Assert.isFalse(invalid.ok, "unsupported frame indices are rejected")
  Assert.equal(session:snapshot().frameIndex, 2)
  local fractional = session:setFrameIndex(2.5)
  Assert.isFalse(fractional.ok, "fractional frame indexes are rejected")
  Assert.equal(session:revision(), revision, "invalid selections do not advance the session revision")
end

local function installFailure(backend, method, predicate)
  local original = assert(backend[method])
  local armed = true
  rawset(backend, method, function(self, path, destination)
    if armed and predicate(path, destination) then
      armed = false
      return false, "injected " .. method .. " failure"
    end
    return original(self, path, destination)
  end)
end

local function backupPath(saveId)
  return "saves/editor-backups/" .. saveId .. ".lua"
end

local function mainPath(saveId)
  return "saves/games/" .. saveId .. ".lua"
end

local function stagedSession(fixture)
  local session = sessionFor(fixture)
  ok(session:setMoney(6200))
  return session
end

function T.failed_publication_keeps_checkpoint_and_staged_state_for_retry()
  for _, failure in ipairs({
    {
      method = "write",
      matches = function(path)
        return path:match("editor%-backups/.*%.tmp$") ~= nil
      end,
    },
    {
      method = "replace",
      matches = function(path, destination)
        return path:match("editor%-backups/.*%.tmp$") ~= nil and destination:match("editor%-backups/.*%.lua$") ~= nil
      end,
    },
    {
      method = "write",
      matches = function(path)
        return path:match("games/.*%.lua%.tmp$") ~= nil
      end,
    },
    {
      method = "replace",
      matches = function(path, destination)
        return path:match("games/.*%.lua%.tmp$") ~= nil and destination:match("games/.*%.lua$") ~= nil
      end,
    },
  }) do
    local fixture = Fixture.new()
    local session = stagedSession(fixture)
    local oldPublished = assert(fixture.store:load(fixture.saveId))
    installFailure(fixture.backend, failure.method, failure.matches)
    local failed = session:save()
    Assert.isFalse(failed.ok, "injected " .. failure.method .. " failure must be reported")
    Assert.isTrue(session:isDirty(), "failed publication must retain staged values")
    Assert.deepEqual(assert(fixture.store:load(fixture.saveId)), oldPublished, "failure must retain the published save")
    Assert.isNil(fixture.backend.files[backupPath(fixture.saveId) .. ".tmp"], "backup temp is cleaned after failure")

    local saved = session:save()
    Assert.isTrue(saved.ok, "the retained staged transaction must be retryable")
    Assert.isTrue(saved.changed)
    Assert.equal(assert(fixture.store:load(fixture.saveId)).playerData.profile.money, 6200)
    Assert.notNil(
      fixture.backend.files[backupPath(fixture.saveId)],
      "the canonical session-entry checkpoint is retained"
    )
    local checkpoint, checkpointError = fixture.saveFs:loadLua("editor-backups/" .. fixture.saveId .. ".lua")
    Assert.isNil(checkpointError)
    Assert.deepEqual(checkpoint, oldPublished)
    local backupBytes = fixture.backend.files[backupPath(fixture.saveId)]
    ok(session:setMoney(7300))
    Assert.isTrue(session:save().ok)
    Assert.equal(
      fixture.backend.files[backupPath(fixture.saveId)],
      backupBytes,
      "one session keeps its entry checkpoint"
    )
    Assert.equal(assert(fixture.store:load(fixture.saveId)).playerData.profile.money, 7300)
  end

  local fixture = Fixture.new()
  local session = stagedSession(fixture)
  local external = fixture.copy(fixture.initial)
  external.playerData.profile.money = 99
  fixture.store:save(external)
  local conflict = session:save()
  Assert.isFalse(conflict.ok)
  Assert.equal(conflict.error.code, "SAVE_EDITOR_CONFLICT")
  Assert.isTrue(session:isDirty())
  Assert.equal(assert(fixture.store:load(fixture.saveId)).playerData.profile.money, 99)
end

function T.named_flags_preserve_aliases_unknown_ids_and_variables()
  local fixture = Fixture.new({
    symbols = {
      flagsByName = {
        FLAG_TEST_PRIMARY = 250,
        FLAG_TEST_ALIAS = 250,
        FLAG_UNK_TEST = 251,
      },
    },
  })
  local session = sessionFor(fixture)
  local originalVars = fixture.copy(fixture.initial.world.variables)

  ok(session:setFlag("FLAG_TEST_PRIMARY", true))
  local firstCandidate = session:captureCandidate()
  Assert.isTrue(firstCandidate.world.flags[250])
  ok(session:setFlag("FLAG_TEST_ALIAS", true))
  Assert.isTrue(session:captureCandidate().world.flags[250], "catalog aliases resolve to one stored state")
  ok(session:setFlag("FLAG_TEST_ALIAS", false))
  local aliasCandidate = session:captureCandidate()
  Assert.isNil(aliasCandidate.world.flags[250], "symbolic aliases address the same numeric flag")
  Assert.deepEqual(aliasCandidate.world.variables, originalVars, "flag edits leave variables exact")
  Assert.isTrue(aliasCandidate.world.flags[50000], "an unlisted stored flag is retained")
  Assert.isNil(session.setVar, "the session does not expose variable editing")
  local unknown = session:setFlag("FLAG_NOT_IN_CATALOG", true)
  Assert.isFalse(unknown.ok)
  Assert.equal(unknown.error.code, "SAVE_EDITOR_VALUE_INVALID")
  local numeric = session:setFlag(250, false)
  Assert.isFalse(numeric.ok, "flags are addressed by exact catalog name")
end

function T.money_boundaries_and_snapshot_values_are_isolated()
  local fixture = Fixture.new()
  local session = sessionFor(fixture)
  local initialRevision = session:revision()
  local zero = session:setMoney(0)
  Assert.isTrue(zero.ok)
  Assert.isTrue(zero.changed)
  local repeatedZero = session:setMoney(0)
  Assert.isTrue(repeatedZero.ok)
  Assert.isFalse(repeatedZero.changed)
  local maximum = session:setMoney(999999)
  Assert.isTrue(maximum.ok)
  Assert.isTrue(maximum.changed)
  for _, value in ipairs({ -1, 1000000, 1.5, 0 / 0, math.huge, -math.huge, "1" }) do
    local result = session:setMoney(value)
    Assert.isFalse(result.ok, "invalid money must be rejected")
    Assert.equal(result.error.code, "SAVE_EDITOR_VALUE_INVALID")
  end
  Assert.equal(session:revision(), initialRevision + 2)

  local snapshot = session:snapshot()
  snapshot.flags[817] = nil
  snapshot.location.mapId = 1
  snapshot.originalLocation.fieldX = 1
  snapshot.dirtySections.money = false
  Assert.isTrue(session:captureCandidate().world.flags[817])
  Assert.equal(session:snapshot().location.mapId, fixture.initial.mapId)
  Assert.equal(session:snapshot().originalLocation.fieldX, fixture.initial.fieldX)
  Assert.isTrue(session:snapshot().dirtySections.money)
end

function T.active_scripts_and_invalid_candidates_are_refused_without_writes()
  local fixture = Fixture.new()
  local calls = cleanLog(fixture.backend)
  local Session = sessionModule()
  local active = fixture.copy(fixture.initial)
  active.scripts.tasks = { { taskId = "pending" } }
  local rejected, activeError = Session.new({
    record = active,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  })
  Assert.isNil(rejected)
  Assert.equal(activeError.code, "SAVE_EDITOR_ACTIVE_SCRIPT")
  Assert.isTrue(activeError.message:match("stable point") ~= nil)

  local validationError = require("libs.errors.src.Errors").new("TEST_INVALID", "candidate rejected", {})
  local session = Session.new({
    record = fixture.initial,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = function()
      return nil, validationError
    end,
    symbols = fixture.symbols,
  })
  Assert.isTrue(session:setMoney(55).ok)
  local result = session:save()
  Assert.isFalse(result.ok)
  Assert.equal(result.error, validationError)
  Assert.deepEqual(calls, {}, "failed candidate validation must not touch storage")
  Assert.isTrue(session:isDirty())
end

function T.reentrant_save_is_rejected_without_blocking_the_outer_save()
  local fixture = Fixture.new()
  local Session = sessionModule()
  local nested
  local nestedMoney
  local nestedFlag
  local nestedDiscard
  local session
  session = Session.new({
    record = fixture.initial,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = function(candidate)
      nested = session:save()
      nestedMoney = session:setMoney(6200)
      nestedFlag = session:setFlag("FLAG_HIDDENITEM_D42R0101_HYPER_POTION", false)
      nestedDiscard = session:discard()
      return fixture.validateRecord(candidate)
    end,
    symbols = fixture.symbols,
  })
  Assert.isTrue(session:setMoney(6100).ok)
  local result = session:save()
  Assert.isTrue(result.ok)
  Assert.isFalse(nested.ok)
  Assert.equal(nested.error.code, "SAVE_EDITOR_BUSY")
  Assert.isFalse(nestedMoney.ok)
  Assert.equal(nestedMoney.error.code, "SAVE_EDITOR_BUSY")
  Assert.isFalse(nestedFlag.ok)
  Assert.equal(nestedFlag.error.code, "SAVE_EDITOR_BUSY")
  Assert.isFalse(nestedDiscard)
  Assert.isFalse(session:isDirty())
end

function T.backup_replacement_failure_preserves_the_previous_checkpoint()
  for _, method in ipairs({ "write", "replace" }) do
    local fixture = Fixture.new()
    local path = backupPath(fixture.saveId)
    fixture.backend.files[path] = "previous-checkpoint"
    local session = stagedSession(fixture)
    installFailure(fixture.backend, method, function(source, destination)
      if method == "write" then
        return source == path .. ".tmp"
      end
      return source == path .. ".tmp" and destination == path
    end)
    local failed = session:save()
    Assert.isFalse(failed.ok)
    Assert.equal(fixture.backend.files[path], "previous-checkpoint")
    Assert.isNil(fixture.backend.files[path .. ".tmp"])
    Assert.isTrue(session:isDirty())
  end
end

function T.flag_capacity_and_pending_drafts_leave_the_transaction_unchanged()
  local fixture = Fixture.new({ symbols = { flagsByName = { FLAG_OVERFLOW = 5000 } } })
  local record = fixture.copy(fixture.initial)
  record.world.flags = {}
  for flagId = 0, 4095 do
    record.world.flags[flagId] = true
  end
  local Session = sessionModule()
  local session = Session.new({
    record = record,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  })
  local revision = session:revision()
  local overflow = session:setFlag("FLAG_OVERFLOW", true)
  Assert.isFalse(overflow.ok)
  Assert.isTrue(overflow.error ~= nil)
  Assert.equal(session:revision(), revision)
  Assert.isFalse(session:captureCandidate().world.flags[5000])

  local dirty = sessionFor(fixture)
  Assert.isTrue(dirty:setMoney(5000).ok)
  local result = dirty:save(true)
  Assert.isFalse(result.ok)
  Assert.equal(result.error.code, "SAVE_EDITOR_DRAFT_PENDING")
  Assert.isTrue(dirty:isDirty())
end

function T.party_and_bag_staging_use_real_domain_owners_and_reject_stale_drafts()
  local fixture = Fixture.new()
  local monService = monServiceFor(fixture)
  for _, species in ipairs({ "CHIKORITA", "TOTODILE" }) do
    Assert.isTrue(monService:giveMon({
      species = species,
      level = 5,
      location = 7,
      date = CatalogFixture.metDate(),
    }))
  end
  local bagService = HgssBagService.new({ catalog = fixture.context.itemCatalog, bag = fixture.initial.bag })
  Assert.isTrue(bagService:add("GREAT_BALL", 2))
  local initial = fixture.copy(fixture.initial)
  initial.mons = monService:capture()
  initial.bag = bagService:capture()
  Assert.isTrue(fixture.store:save(initial))
  fixture.initial = assert(fixture.store:load(fixture.saveId))

  local session = sessionFor(fixture)
  local revision = session:partyRevision()
  local party = session:partySnapshot()
  Assert.equal(party.revision, revision)
  Assert.equal(#party.members, 2)
  Assert.deepEqual(party.members[1], { slot0 = 0, mon = monService:partyMon(0) })
  party.members[1].mon.friendship = 0
  Assert.deepEqual(session:captureCandidate().mons, fixture.initial.mons, "party snapshots are owned copies")

  local stale = assert(session:beginMonEdit(0))
  Assert.isTrue(stale:setScalar("friendship", 71))
  Assert.isTrue(session:swapPartyMons(0, 1).ok)
  local afterSwap = session:captureCandidate().mons
  local rejected = session:applyMonDraft(stale)
  Assert.isFalse(rejected.ok, "a draft cannot overwrite a new slot occupant")
  Assert.deepEqual(session:captureCandidate().mons, afterSwap)

  local edit = assert(session:beginMonEdit(0))
  Assert.isTrue(edit:setScalar("friendship", 72))
  local beforeAdd = session:captureCandidate()
  local abandonedAdd = assert(session:beginMonAdd("EEVEE", {
    location = 7,
    date = CatalogFixture.metDate(),
  }))
  Assert.isTrue(abandonedAdd:record() ~= nil)
  Assert.deepEqual(session:captureCandidate(), beforeAdd, "canceling a generated candidate leaves staged RNG untouched")
  Assert.isTrue(session:applyMonDraft(edit).ok)
  Assert.equal(session:partyRevision(), revision + 2)

  local added = assert(session:beginMonAdd("EEVEE", {
    location = 7,
    date = CatalogFixture.metDate(),
  }))
  Assert.isTrue(session:applyMonDraft(added).ok)
  Assert.equal(session:partyRevision(), revision + 3)
  Assert.equal(session:captureCandidate().mons.party.mons[3].species, "EEVEE")

  local bag = session:bagSnapshot("balls")
  Assert.deepEqual(bag, { { item = "GREAT_BALL", quantity = 2 } })
  bag[1].quantity = 0
  Assert.equal(session:bagSnapshot("balls")[1].quantity, 2, "bag snapshots are owned copies")
  local beforeRejectedBagCandidate = fixture.copy(session:captureCandidate().bag)
  Assert.isFalse(session:setBagQuantity("GREAT_BALL", 1000).ok, "real stack caps reject invalid quantities")
  Assert.deepEqual(
    session:captureCandidate().bag,
    beforeRejectedBagCandidate,
    "a rejected cloned inventory candidate leaves the staged owner unchanged"
  )
  Assert.isTrue(session:setBagQuantity("GREAT_BALL", 4).ok)
  Assert.isTrue(session:setBagQuantity("POTION", 3).ok)
  Assert.equal(session:captureCandidate().bag.pockets.balls[1].quantity, 4)
  Assert.equal(session:captureCandidate().bag.pockets.medicine[1].item, "POTION")
  Assert.isTrue(session:setBagQuantity("GREAT_BALL", 0).ok)
  Assert.equal(session:captureCandidate().bag.pockets.balls[1], nil)
  Assert.isTrue(session:isDirty(), "party and inventory changes participate in transaction dirtiness")
  local dirtyPartyRevision = session:partyRevision()
  Assert.isTrue(session:discard())
  Assert.equal(session:partyRevision(), dirtyPartyRevision + 1, "Discard invalidates party drafts")
  Assert.isFalse(session:isDirty())
  Assert.deepEqual(session:captureCandidate().mons, fixture.initial.mons)
  Assert.deepEqual(session:captureCandidate().bag, fixture.initial.bag)
end

return { tests = T }
