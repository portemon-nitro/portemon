-- Companion editor drafts and reproducible scenarios through the real
-- editor session and save publication: cancelled drafts restore the source
-- record byte-semantically, saved drafts change only explicit valid facts,
-- and named scenarios preview bounded changes while refusing incompatible
-- fixtures explicitly. Only the save-root backend is isolated; the editor
-- session, save store, and companion state validation stay real, and no
-- retail controller or game screen is driven here. No ROM bytes are read.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Fixture = require("app.tests.support.SaveEditorFixture")
local Session = require("app.src.saveeditor.SaveEditorSession")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local PokegearState = require("libs.hgss.src.save.PokegearState")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

local FLAG_GOT_POKEGEAR = FieldScriptSymbols.flagsByName.FLAG_GOT_POKEGEAR

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

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = copy(item)
  end
  return result
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

---@return table gear bucket with two registered contacts and default preferences
local function gearBucket()
  local gear = PokegearState.new({ seed = 90210 }, gearRefs())
  gear:registerContact("test.caller.mom")
  gear:registerContact("test.caller.elm")
  return gear:capture()
end

---@return table session, table fixture
local function openGearSession()
  local fixture = Fixture.new()
  local initial = copy(fixture.initial)
  initial.pokegear = gearBucket()
  fixture.store:save(initial)
  local session = assert(Session.new({
    record = copy(initial),
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    symbols = fixture.symbols,
  }))
  return session, fixture
end

local function stagedGearEdits(draft)
  draft:change("registerCard", "map")
  draft:change("setContactReward", "test.caller.elm", { item = "POTION", quantity = 1 })
  draft:change("setMarking", "test.place.new-bark", {
    icons = { 2, false, false, false },
    words = { "test.word.seed", false, false, false },
  })
  draft:change("setMomBalance", 1250)
end

function T.tests.gear_editor_cancel_restores_the_source_record_and_save_changes_only_explicit_facts()
  local Draft = requireFeature(
    "app.src.saveeditor.SaveEditorPokegearDraft",
    "the editor has no validated companion draft yet: card, contact, and gift edits cannot stage through a detached draft"
  )
  local session, fixture = openGearSession()
  local refs = gearRefs()
  local before = session:captureCandidate()
  Assert.isNil(before.world.flags[FLAG_GOT_POKEGEAR], "the fixture starts before companion acquisition")

  local cancelled = Draft.new({ record = session:captureCandidate(), refs = refs })
  stagedGearEdits(cancelled)
  Assert.isTrue(cancelled:validate(), "the staged card, contact, gift, marking, and savings edits validate")
  Assert.deepEqual(
    session:captureCandidate(),
    before,
    "draft edits never mutate the live session or the original save before apply"
  )
  cancelled = nil
  Assert.isFalse(session:discard(), "cancelling a detached draft stages nothing at session level")
  Assert.deepEqual(session:captureCandidate(), before, "cancel restores the source record byte-semantically")

  local draft = Draft.new({ record = session:captureCandidate(), refs = refs })
  stagedGearEdits(draft)
  local updated, applyError = draft:apply()
  Assert.isNil(applyError, "the validated draft applies without error")
  Assert.notNil(updated, "the validated draft returns its updated record")
  Assert.equal(
    updated.world.flags[FLAG_GOT_POKEGEAR],
    true,
    "the card action coherently records companion ownership beside the card bit"
  )
  Assert.equal(updated.pokegear.registeredCards.map, true, "the applied record carries the new card bit")
  Assert.deepEqual(session:captureCandidate(), before, "apply alone never touches the committed session")

  fixture.store:save(updated)
  local reloaded = assert(fixture.store:load(fixture.saveId))
  local expected = copy(before)
  expected.world.flags[FLAG_GOT_POKEGEAR] = true
  expected.pokegear.registeredCards.map = true
  expected.pokegear.phone.contacts["test.caller.elm"] = { reward = { item = "POTION", quantity = 1 } }
  expected.pokegear.markings["test.place.new-bark"] = {
    icons = { 2, false, false, false },
    words = { "test.word.seed", false, false, false },
  }
  expected.pokegear.phone.mom.balance = 1250
  Assert.deepEqual(reloaded, expected, "the saved record changes only the explicit valid facts")
end

function T.tests.gear_scenarios_preview_bounded_changes_and_refuse_incompatible_fixtures()
  local Presets = requireFeature(
    "app.src.saveeditor.PokegearPresets",
    "the editor has no reproducible companion scenarios yet: scenario changes cannot preview boundedly"
  )
  local refs = gearRefs()
  local names = Presets.names()
  Assert.isTrue(#names >= 2, "the editor offers more than one named scenario")

  local pinned = {}
  for _, name in ipairs(names) do
    Assert.equal(type(name), "string", "every scenario carries a behaviour name")
    local description = Presets.describe(name)
    Assert.isTrue(type(description.preconditions) == "table", "every scenario declares its preconditions")
    Assert.isTrue(type(description.changes) == "table", "every scenario declares its ordered change summary")
    Assert.isTrue(#description.changes > 0, "every scenario changes at least one fact")
    for _, change in ipairs(description.changes) do
      Assert.equal(type(change.fact), "string", "every change names the fact it touches")
      Assert.notNil(
        string.find(change.fact, "^pokegear%.", 1),
        "scenario changes stay inside the companion bucket: " .. change.fact
      )
    end
    if name == "pending-gift" or name == "eligible-trainer-rematch" then
      pinned[name] = description
    end
  end
  Assert.notNil(pinned["pending-gift"], "the pending gift scenario is offered by name")
  Assert.notNil(pinned["eligible-trainer-rematch"], "the eligible trainer rematch scenario is offered by name")

  local fixture = Fixture.new()
  local initial = copy(fixture.initial)
  initial.pokegear = gearBucket()
  local first, firstError = Presets.applyToRecord("pending-gift", copy(initial), refs)
  Assert.isNil(firstError, "the gift scenario applies to a compatible fixture")
  Assert.notNil(first, "the gift scenario returns its updated record")
  local second = assert(Presets.applyToRecord("pending-gift", copy(initial), refs))
  Assert.deepEqual(second.pokegear, first.pokegear, "the gift scenario reproduces its state exactly")
  local previewed = Presets.preview("pending-gift", refs)
  Assert.isNil(first.__presetSummary, "scenario summaries never persist inside saves")
  Assert.equal(#previewed, #pinned["pending-gift"].changes, "the preview matches the declared change set")
  local restBefore, restAfter = copy(initial), copy(first)
  restBefore.pokegear.phone, restAfter.pokegear.phone = nil, nil
  restBefore.pokegear, restAfter.pokegear = nil, nil
  Assert.deepEqual(restAfter, restBefore, "the gift scenario mutates no party, story, or world system")
  Assert.deepEqual(first.pokegear.calendar, initial.pokegear.calendar, "the gift scenario moves no daily identity")
  Assert.deepEqual(
    first.pokegear.contactOrder,
    initial.pokegear.contactOrder,
    "the gift scenario preserves contact order"
  )

  local unacquired = copy(initial)
  unacquired.pokegear = (function()
    local gear = PokegearState.new({ seed = 90210 }, refs)
    gear:registerContact("test.caller.mom")
    return gear:capture()
  end)()
  local refused, refusal = Presets.applyToRecord("pending-gift", copy(unacquired), refs)
  Assert.isNil(refused, "the gift scenario applies nothing to an incompatible fixture")
  Assert.isTrue(Errors.is(refusal), "the refusal is an attributed error, never a silent repair")
  Assert.notNil(
    string.find(refusal.message, "test.caller.elm", 1, true),
    "the refusal names the unmet contact precondition"
  )

  local prunedRefs = {
    catalog = {
      contacts = { { key = "test.caller.mom", sortWeight = 10 } },
      locations = { { key = "test.place.new-bark" } },
    },
  }
  local previewedMissing, previewError = Presets.preview("pending-gift", prunedRefs)
  Assert.isNil(previewedMissing, "a scenario with missing catalog assets previews nothing")
  Assert.isTrue(Errors.is(previewError), "missing scenario assets fail explicitly")

  local unavailable = {}
  for _, name in ipairs(names) do
    local description = Presets.describe(name)
    if description.available == false then
      Assert.isTrue(type(description.reason) == "string" and description.reason ~= "", "an unavailable scenario explains why")
      unavailable[#unavailable + 1] = name
    end
  end
  Assert.isTrue(#unavailable >= 1, "specialty scenarios without world support stay explicitly unavailable")
  local held = copy(initial)
  local filled, specialtyError = Presets.applyToRecord(unavailable[1], copy(held), refs)
  Assert.isNil(filled, "an unavailable specialty scenario fabricates no facts")
  Assert.isTrue(Errors.is(specialtyError), "an unavailable specialty scenario fails explicitly")
end

return T
