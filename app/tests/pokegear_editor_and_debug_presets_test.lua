-- Companion editor validation and inert status reads: rejected references
-- never mutate committed state, failed writes keep recovery usable, and
-- repeated status queries never disturb random streams, state, or timing.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Fixture = require("app.tests.support.SaveEditorFixture")
local Session = require("app.src.saveeditor.SaveEditorSession")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local Draft = require("app.src.saveeditor.SaveEditorPokegearDraft")
local Presets = require("app.src.saveeditor.PokegearPresets")
local CompanionCard = require("app.src.saveeditor.SaveEditorPokegearCard")

local T = { tests = {} }

-- Loads a companion editor module that does not exist yet at this
-- baseline. The failure names the missing behaviour instead of surfacing
-- as a suite load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

---@return table catalog references in the exact shape state validation reads
local function gearRefs()
  return {
    catalog = {
      contacts = {
        { key = "test.caller.mom", sortWeight = 10 },
        { key = "test.caller.elm", sortWeight = 20 },
      },
      locations = {
        { key = "test.place.new-bark" },
        { key = "test.place.violet" },
      },
    },
  }
end

---@param refs table<string, unknown>
---@return boolean both callers stay catalogued
local function contactKeysPresent(refs)
  local catalog = refs.catalog --[[@as table<string, unknown>]]
  local seen = {}
  for _, contact in ipairs(catalog.contacts --[[@as table<integer, unknown>]]) do
    seen[(contact --[[@as table<string, unknown>]]).key] = true
  end
  return seen["test.caller.mom"] == true and seen["test.caller.elm"] == true
end

---@return table gear bucket with two registered contacts, one marking, one gift, and savings
local function gearBucket()
  local refs = gearRefs()
  local gear = PokegearState.new({ seed = 90210 }, refs)
  gear:registerContact("test.caller.mom")
  gear:registerContact("test.caller.elm")
  gear:setContactReward("test.caller.elm", { item = "POTION", quantity = 1 })
  gear:setMarking("test.place.new-bark", {
    icons = { 2, false, false, false },
    words = { "test.word.seed", false, false, false },
  })
  return gear:capture()
end

local function openGearSession()
  local fixture = Fixture.new()
  local initial = fixture.copy(fixture.initial)
  initial.pokegear = gearBucket()
  fixture.store:save(initial)
  local session = assert(Session.new({
    record = fixture.copy(initial),
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    symbols = fixture.symbols,
  }))
  return session, fixture
end

function T.tests.gear_draft_rejects_invalid_references_and_failed_writes_keep_recovery_usable()
  local Draft = requireFeature(
    "app.src.saveeditor.SaveEditorPokegearDraft",
    "the editor has no validated companion draft yet: unknown contact references cannot be rejected without partial mutation"
  )
  local session, fixture = openGearSession()
  local refs = gearRefs()
  local before = session:captureCandidate()

  local draft = Draft.new({ record = session:captureCandidate(), refs = refs })
  draft:change("setPreference", "skin", 3)
  draft:change("setContactReward", "test.caller.nobody", { item = "POTION", quantity = 1 })
  local updated, applyError = draft:apply()
  Assert.isNil(updated, "an unknown contact reference applies nothing")
  Assert.isTrue(Errors.is(applyError), "an unknown contact reference fails with an attributed error")
  Assert.notNil(
    string.find(applyError.message, "test.caller.nobody", 1, true),
    "the reference failure names the offending contact key"
  )
  Assert.deepEqual(session:captureCandidate(), before, "the failed draft leaves the committed save untouched")

  local misplaced = Draft.new({ record = session:captureCandidate(), refs = refs })
  misplaced:change("setMarking", "test.place.nowhere", {
    icons = { 1, false, false, false },
    words = { false, false, false, false },
  })
  local marked, markingError = misplaced:apply()
  Assert.isNil(marked, "an unknown marking location applies nothing")
  Assert.isTrue(Errors.is(markingError), "an unknown marking location fails with an attributed error")
  Assert.notNil(
    string.find(markingError.message, "test.place.nowhere", 1, true),
    "the marking failure names the offending location key"
  )
  Assert.deepEqual(session:captureCandidate(), before, "the failed marking leaves the committed save untouched")

  local indebted = Draft.new({ record = session:captureCandidate(), refs = refs })
  indebted:change("setPreference", "skin", 3)
  indebted:change("setMomBalance", -5)
  local balanced, balanceError = indebted:apply()
  Assert.isNil(balanced, "a negative savings balance applies nothing")
  Assert.isTrue(Errors.is(balanceError), "a negative savings balance fails with an attributed error")
  Assert.deepEqual(
    session:captureCandidate(),
    before,
    "the valid staged skin never leaks through the failed balance apply"
  )

  local untouched = Draft.new({ record = session:captureCandidate(), refs = refs })
  Assert.isTrue(untouched:validate(), "an unchanged draft validates cleanly")
  local same, sameError = untouched:apply()
  Assert.isNil(sameError, "an unchanged draft applies without error")
  Assert.deepEqual(same.pokegear, before.pokegear, "an unchanged draft applies no silent repair")

  local storedGear =
    PokegearState.restore(assert(fixture.store:load(fixture.saveId)).pokegear, refs):capture()

  local staged = session:setMoney(session:snapshot().money + 1)
  Assert.isTrue(staged.ok, "an ordinary edit stages through the existing session")
  local failingSave = session._saveStore.save
  session._saveStore.save = function()
    error(Errors.new("SAVE_CONFLICT", "The save changed before publication.", {}))
  end
  local result = session:save()
  session._saveStore.save = failingSave
  Assert.isFalse(result.ok, "a store failure rejects the save")
  Assert.isTrue(Errors.is(result.error), "a store failure stays an attributed error")
  Assert.isTrue(session:isDirty(), "the failed save retains its staged edits")

  local recovered = assert(fixture.store:load(fixture.saveId))
  Assert.deepEqual(
    PokegearState.restore(recovered.pokegear, refs):capture(),
    storedGear,
    "the failed save leaves the prior companion bucket usable"
  )
  local saved = session:save()
  Assert.isTrue(saved.ok, "the same staged edits save cleanly once the store recovers")

  local stranger = assert(fixture.store:load(fixture.saveId))
  stranger.playerData.profile.money = stranger.playerData.profile.money + 41
  fixture.store:save(stranger)
  local conflicted = session:save()
  Assert.isFalse(conflicted.ok, "an externally replaced save conflicts instead of overwriting")
  Assert.equal(conflicted.error.code, "SAVE_EDITOR_CONFLICT", "the conflict names its attribution code")
  local kept = assert(fixture.store:load(fixture.saveId))
  Assert.equal(
    kept.playerData.profile.money,
    stranger.playerData.profile.money,
    "the conflict preserves the external replacement instead of partially mutating it"
  )
end

function T.tests.companion_status_queries_leave_random_state_and_timing_undisturbed()
  local Presets = requireFeature(
    "app.src.saveeditor.PokegearPresets",
    "the editor has no companion scenario presets yet: status queries cannot be observed for inertness"
  )
  local refs = gearRefs()
  local gear = PokegearState.new({ seed = 90210 }, refs)
  gear:registerContact("test.caller.elm")
  gear:setTrigger("test.trigger.elm", true)
  local random = PokegearRandom.new(90210)
  local calendar = PokegearCalendar.new(gear)
  local signals = {
    ring = "idle",
    acceptedCaller = false,
    effectLatch = "none",
    showId = false,
    signal = "clear",
  }

  local first = Presets.statusSnapshot(gear, signals)
  for _ = 1, 4 do
    Assert.deepEqual(Presets.statusSnapshot(gear, signals), first, "repeated status reads agree exactly")
  end
  local streamsBefore = random:capture()
  local gearBefore = gear:capture()
  local revisionBefore = gear:revision()
  local calendarBefore = gear:readCalendar()
  Assert.deepEqual(random:capture(), streamsBefore, "status reads draw no random values")
  Assert.deepEqual(gear:capture(), gearBefore, "status reads mutate no companion state")
  Assert.equal(gear:revision(), revisionBefore, "status reads advance no revision")
  Assert.deepEqual(gear:readCalendar(), calendarBefore, "status reads move no clock checkpoint")

  local report = calendar:observeField({ year = 2009, month = 3, day = 7, hour = 6, minute = 30, second = 0 })
  Assert.equal(report.minuteAdvance, 0, "the first observation only commits its checkpoint")
  Assert.equal(gear:revision(), revisionBefore + 1, "the legitimate checkpoint commit advances once")
  Assert.deepEqual(
    Presets.statusSnapshot(gear, signals).minuteCheckpoint,
    gear:readCalendar().checkpoint,
    "the reported minute checkpoint comes from persisted state, never the host clock"
  )
  Assert.deepEqual(random:capture(), streamsBefore, "the clock observation draws no stream values")

  local seenLc, seenMt = {}, nil
  for index = 1, 3 do
    seenLc[index] = random:lc("probe")
  end
  seenMt = random:mt("probe")
  local fresh = PokegearRandom.new(90210)
  for index = 1, 3 do
    Assert.equal(seenLc[index], fresh:lc("probe"), "live linear draws match the undisturbed stream")
  end
  Assert.equal(seenMt, fresh:mt("probe"), "live source draws match the undisturbed stream")
end

function T.tests.gear_draft_rejects_conflicting_ownership_excess_savings_and_oversized_queues()
  local session, _ = openGearSession()
  local refs = gearRefs()
  local before = session:captureCandidate()

  local conflicted = Draft.new({ record = session:captureCandidate(), refs = refs })
  conflicted:change("registerCard", "map")
  conflicted:change("setOwnership", false)
  local cleared, conflictError = conflicted:apply()
  Assert.isNil(cleared, "a card without its coherent ownership applies nothing")
  Assert.isTrue(Errors.is(conflictError), "conflicting card and ownership fail with an attributed error")
  Assert.deepEqual(session:captureCandidate(), before, "the conflict leaves the committed save untouched")

  local excessive = Draft.new({ record = session:captureCandidate(), refs = refs })
  excessive:change("setMomBalance", 1000000)
  local rich, richError = excessive:apply()
  Assert.isNil(rich, "a savings balance past the companion ceiling applies nothing")
  Assert.isTrue(Errors.is(richError), "an excess savings balance fails with an attributed error")

  local crowded = Draft.new({ record = session:captureCandidate(), refs = refs })
  crowded:change("setMomGifts", {
    { item = "POTION", quantity = 1 },
    { item = "POTION", quantity = 1 },
    { item = "POTION", quantity = 1 },
    { item = "POTION", quantity = 1 },
    { item = "POTION", quantity = 1 },
    { item = "POTION", quantity = 1 },
  })
  local queued, queueError = crowded:apply()
  Assert.isNil(queued, "a gift queue past five entries applies nothing")
  Assert.isTrue(Errors.is(queueError), "an oversized gift queue fails with an attributed error")
  Assert.deepEqual(session:captureCandidate(), before, "the rejected edits never reach the committed save")
end

function T.tests.gear_draft_repairs_legacy_records_explicitly_without_inventing_history()
  local fixture = Fixture.new()
  local refs = gearRefs()
  local session = assert(Session.new({
    record = fixture.copy(fixture.initial),
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    symbols = fixture.symbols,
  }))
  Assert.isNil(session:captureCandidate().pokegear, "the legacy fixture carries no companion record")

  local premature = Draft.new({ record = session:captureCandidate(), refs = refs })
  premature:change("setMomBalance", 100)
  local rushed, rushedError = premature:apply()
  Assert.isNil(rushed, "ordinary edits stage nothing before the explicit repair")
  Assert.isTrue(Errors.is(rushedError), "edits without a companion record fail with an attributed error")

  local repair = Draft.new({ record = session:captureCandidate(), refs = refs })
  repair:change("repairLegacyOwnership")
  local changes = repair:changes()
  Assert.isTrue(#changes >= 1, "the repair lists its changes before any save")
  local repaired, repairError = repair:apply()
  Assert.isNil(repairError, "the explicit repair applies without error")
  Assert.notNil(repaired and repaired.pokegear, "the repair creates the missing companion bucket")
  Assert.deepEqual(session:captureCandidate().pokegear, nil, "the repair alone never touches the session")

  local staged = session:adoptPokegearRecord(assert(repaired), refs)
  Assert.isTrue(staged.ok, "the repaired record stages through the session transaction")
  Assert.isTrue(session:isDirty(), "the staged repair dirties the session")
  Assert.isTrue(session:save().ok, "the staged repair saves through the existing publication")
  local reloaded = assert(fixture.store:load(fixture.saveId))
  local gear = PokegearState.restore(reloaded.pokegear, refs)
  Assert.deepEqual(gear:capture(), assert(repaired).pokegear, "the published repair keeps exactly the staged facts")
end

function T.tests.gear_draft_rejects_corrupted_buckets_without_touching_the_save()
  local session, _ = openGearSession()
  local refs = gearRefs()
  local before = session:captureCandidate()
  local corrupted = session:captureCandidate()
  corrupted.pokegear.schema = "bogus-schema"

  local draft = Draft.new({ record = corrupted, refs = refs })
  local updated, corruptionError = draft:apply()
  Assert.isNil(updated, "a corrupted bucket applies nothing, even unchanged")
  Assert.isTrue(Errors.is(corruptionError), "corrupted companion data fails with an attributed error")
  Assert.deepEqual(session:captureCandidate(), before, "the corrupted draft never reaches the committed save")
end

function T.tests.gear_companion_staging_flows_through_the_session_transaction()
  local session, fixture = openGearSession()
  local refs = gearRefs()

  local draft = Draft.new({ record = session:captureCandidate(), refs = refs })
  draft:change("setMomBalance", 500)
  draft:change("registerCard", "radio")
  local staged = session:applyPokegearDraft(draft)
  Assert.isTrue(staged.ok, "a validated companion draft stages through the session")
  Assert.isTrue(session:snapshot().dirtySections.pokegear, "the staged companion edit marks its dirty section")
  Assert.isTrue(session:save().ok, "the staged companion edit saves through the existing publication")
  local reloaded = assert(fixture.store:load(fixture.saveId))
  Assert.equal(reloaded.pokegear.phone.mom.balance, 500, "the published save carries the staged savings")
  Assert.equal(reloaded.pokegear.registeredCards.radio, true, "the published save carries the staged card")

  local second = Draft.new({ record = session:captureCandidate(), refs = refs })
  second:change("setMomBalance", 600)
  Assert.isTrue(session:applyPokegearDraft(second).ok, "a second companion edit stages cleanly")
  Assert.isTrue(session:discardSection("Companion"), "the Companion section resets on its own")
  Assert.isFalse(
    session:snapshot().dirtySections.pokegear,
    "the Companion reset clears only its dirty section"
  )
  local kept = assert(fixture.store:load(fixture.saveId))
  Assert.equal(kept.pokegear.phone.mom.balance, 500, "the reset keeps the last published companion state")
end

function T.tests.gear_scenarios_refuse_missing_assets_at_preview_and_apply()
  local fixture = Fixture.new()
  local fullRefs = gearRefs()
  local initial = fixture.copy(fixture.initial)
  initial.pokegear = gearBucket()
  local prunedRefs = {
    catalog = {
      contacts = { { key = "test.caller.mom", sortWeight = 10 } },
      locations = { { key = "test.place.new-bark" } },
    },
  }
  local previewed, previewError = Presets.preview("pending-gift", prunedRefs)
  Assert.isNil(previewed, "a scenario with missing catalog assets previews nothing")
  Assert.isTrue(Errors.is(previewError), "missing scenario assets fail explicitly at preview")
  local applied, applyError = Presets.applyToRecord("pending-gift", fixture.copy(initial), prunedRefs)
  Assert.isNil(applied, "a scenario with missing catalog assets applies nothing")
  Assert.isTrue(Errors.is(applyError), "missing scenario assets fail explicitly at apply")
  local described = Presets.describe("pending-gift")
  Assert.equal(described.available, true, "the gift scenario stays available with its full catalog")
  Assert.isTrue(contactKeysPresent(fullRefs), "the full catalog keeps both callers")
end

function T.tests.gear_companion_card_reports_state_and_pending_failures_without_committing()
  local session, _ = openGearSession()
  local refs = gearRefs()
  local spec = CompanionCard.describe(session:captureCandidate(), refs)
  Assert.equal(spec.title, "Companion", "the card names its companion section")
  Assert.isTrue(spec.available, "the card is available with its catalog provisioned")
  Assert.isTrue(#spec.rows > 0, "the card projects readable companion facts")
  Assert.isTrue(#spec.actions > 0, "the card carries its labeled semantic actions")
  Assert.isNil(spec.pendingError, "a valid record reports no pending failure")

  local corrupted = session:captureCandidate()
  corrupted.pokegear.schema = "bogus-schema"
  local failed = CompanionCard.describe(corrupted, refs)
  Assert.notNil(failed.pendingError, "malformed companion data shows its attributed failure on the card")
  Assert.deepEqual(
    session:captureCandidate().pokegear,
    gearBucket(),
    "describing a corrupted copy never mutates the session bucket"
  )

  local cells = CompanionCard.cells({ x = 0, y = 0, width = 256, height = 192 }, 2)
  Assert.equal(#cells, 2, "the card resolves through the shared grid mechanism")
end

function T.tests.gear_draft_stages_named_preset_scenarios_with_their_own_checks()
  local session, _ = openGearSession()
  local refs = gearRefs()

  local draft = Draft.new({ record = session:captureCandidate(), refs = refs })
  draft:changePreset("pending-gift")
  local updated, applyError = draft:apply()
  Assert.isNil(applyError, "the staged gift scenario applies without error")
  Assert.deepEqual(
    updated.pokegear.phone.contacts["test.caller.elm"].reward,
    { item = "POTION", quantity = 1 },
    "the staged gift scenario carries the resolved caller reward"
  )

  local unknown = Draft.new({ record = session:captureCandidate(), refs = refs })
  local okUnknown = pcall(function()
    unknown:changePreset("bogus-scenario")
  end)
  Assert.isFalse(okUnknown, "an unknown scenario name never stages")

  local specialty = Draft.new({ record = session:captureCandidate(), refs = refs })
  local okSpecialty = pcall(function()
    specialty:changePreset("safari-call-standby")
  end)
  Assert.isFalse(okSpecialty, "a scenario without staged operations is never stageable")
end

function T.tests.gear_scenarios_preview_and_apply_bounded_changes_for_every_name()
  local fixture = Fixture.new()
  local refs = gearRefs()
  local initial = fixture.copy(fixture.initial)
  initial.pokegear = gearBucket()
  for _, name in ipairs(Presets.names()) do
    local description = Presets.describe(name)
    if description.available == false then
      local refused, refusal = Presets.applyToRecord(name, fixture.copy(initial), refs)
      Assert.isNil(refused, "unavailable scenario " .. name .. " fabricates no facts")
      Assert.isTrue(Errors.is(refusal), "unavailable scenario " .. name .. " fails explicitly")
    else
      local previewed, previewError = Presets.preview(name, refs)
      Assert.isNil(previewError, "scenario " .. name .. " previews against its full catalog")
      Assert.equal(
        #previewed,
        #description.changes,
        "scenario " .. name .. " previews exactly its declared change set"
      )
      local updated, applyError = Presets.applyToRecord(name, fixture.copy(initial), refs)
      Assert.isNil(applyError, "scenario " .. name .. " applies to a compatible fixture")
      Assert.notNil(updated, "scenario " .. name .. " returns its updated record")
      Assert.isNil(updated.__presetSummary, "scenario " .. name .. " persists no summary inside saves")
    end
  end
end

return T
