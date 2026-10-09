-- Section-local reset restores one section to its saved baseline and keeps
-- every other staged section intact.

local Assert = require("tests.support.Assert")
local Fixture = require("app.tests.support.SaveEditorFixture")
local Session = require("app.src.saveeditor.SaveEditorSession")

local T = { tests = {} }

local function openSession()
  local fixture = Fixture.new()
  local session = assert(Session.new({
    record = fixture.initial,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  }))
  return session
end

local function dirtyEverything(session)
  local money = session:setMoney(3100)
  Assert.isTrue(money.ok, "money stages cleanly")
  local frame = session:setFrameIndex(0)
  Assert.isTrue(frame.ok, "dialogue frame stages cleanly")
  local flag = session:setFlag("FLAG_GOT_POKEDEX", true)
  Assert.isTrue(flag.ok, "a named field flag stages cleanly")
  local bag = session:setBagQuantity("POKE_BALL", 5)
  Assert.isTrue(bag.ok, "an item quantity stages cleanly")
  local draft, draftError = session:beginMonAdd("CHIKORITA", {
    location = 7,
    date = { year = 2000, month = 1, day = 1 },
  })
  Assert.isNil(draftError, "a new party member drafts cleanly")
  local applied = session:applyMonDraft(assert(draft))
  Assert.isTrue(applied.ok, "a new party member applies cleanly")
  local location = session:snapshot().location
  location.fieldX = location.fieldX + 1
  local moved = session:setLocation(location)
  Assert.isTrue(moved.ok, "a neighboring field position stages cleanly")
  local dirty = session:snapshot().dirtySections
  Assert.isTrue(dirty.money, "money is staged")
  Assert.isTrue(dirty.frame, "dialogue frame is staged")
  Assert.isTrue(dirty.flags, "field flags are staged")
  Assert.isTrue(dirty.party, "party is staged")
  Assert.isTrue(dirty.bag, "bag is staged")
  Assert.isTrue(dirty.location, "location is staged")
end

local function assertRevisionBumpedOnce(session, before)
  Assert.equal(session:snapshot().revision, before + 1, "a section reset bumps the revision exactly once")
end

function T.tests.public_session_snapshots_remain_independent_copies()
  local session = openSession()
  local first = session:snapshot()
  local second = session:snapshot()

  Assert.isFalse(rawequal(first, second), "each public snapshot owns its root table")
  Assert.isFalse(rawequal(first.flags, second.flags), "each public snapshot owns its flags")
  Assert.isFalse(rawequal(first.location, second.location), "each public snapshot owns nested location data")
  first.flags[1] = not first.flags[1]
  first.location.fieldX = first.location.fieldX + 1

  local current = session:snapshot()
  Assert.equal(second.flags[1], current.flags[1], "mutating one copy leaves another and the session unchanged")
  Assert.equal(second.location.fieldX, current.location.fieldX, "nested copies stay detached from the session")
end

function T.tests.player_reset_restores_money_and_frame_but_keeps_other_sections()
  local session = openSession()
  dirtyEverything(session)
  local before = session:snapshot().revision

  Assert.isTrue(session:discardSection("Player"), "a changed Player section reports its reset")

  local snapshot = session:snapshot()
  Assert.equal(snapshot.money, 3000, "money returns to its saved value")
  Assert.equal(snapshot.frameIndex, 1, "dialogue frame returns to its saved value")
  Assert.isFalse(snapshot.dirtySections.money, "money is clean")
  Assert.isFalse(snapshot.dirtySections.frame, "dialogue frame is clean")
  Assert.isTrue(snapshot.dirtySections.flags, "field flags stay staged")
  Assert.isTrue(snapshot.dirtySections.party, "party stays staged")
  Assert.isTrue(snapshot.dirtySections.bag, "bag stays staged")
  Assert.isTrue(snapshot.dirtySections.location, "location stays staged")
  assertRevisionBumpedOnce(session, before)
end

function T.tests.progress_reset_restores_flags_but_keeps_other_sections()
  local session = openSession()
  dirtyEverything(session)
  local before = session:snapshot().revision

  Assert.isTrue(session:discardSection("Progress"), "a changed Progress section reports its reset")

  local snapshot = session:snapshot()
  Assert.isFalse(snapshot.dirtySections.flags, "field flags are clean")
  Assert.isTrue(snapshot.dirtySections.money, "money stays staged")
  Assert.isTrue(snapshot.dirtySections.frame, "dialogue frame stays staged")
  Assert.isTrue(snapshot.dirtySections.party, "party stays staged")
  Assert.isTrue(snapshot.dirtySections.bag, "bag stays staged")
  Assert.isTrue(snapshot.dirtySections.location, "location stays staged")
  assertRevisionBumpedOnce(session, before)
end

function T.tests.location_reset_restores_the_saved_destination_but_keeps_other_sections()
  local session = openSession()
  dirtyEverything(session)
  local savedLocation = session:snapshot().originalLocation
  local before = session:snapshot().revision

  Assert.isTrue(session:discardSection("Location"), "a changed Location section reports its reset")

  local snapshot = session:snapshot()
  Assert.deepEqual(snapshot.location, savedLocation, "the staged destination returns to its saved position")
  Assert.isFalse(snapshot.dirtySections.location, "location is clean")
  Assert.isTrue(snapshot.dirtySections.money, "money stays staged")
  Assert.isTrue(snapshot.dirtySections.flags, "field flags stay staged")
  Assert.isTrue(snapshot.dirtySections.party, "party stays staged")
  Assert.isTrue(snapshot.dirtySections.bag, "bag stays staged")
  assertRevisionBumpedOnce(session, before)
end

function T.tests.party_reset_restores_the_saved_roster_and_retires_open_drafts()
  local session = openSession()
  dirtyEverything(session)
  local partyRevision = session:partyRevision()
  local stale, staleError = session:beginMonEdit(0)
  Assert.isNil(staleError, "a party draft opens cleanly")
  stale = assert(stale)
  local before = session:snapshot().revision

  Assert.isTrue(session:discardSection("Party"), "a changed Party section reports its reset")

  local snapshot = session:snapshot()
  Assert.isFalse(snapshot.dirtySections.party, "party is clean")
  Assert.equal(#session:partySnapshot().members, 0, "the staged member is gone")
  Assert.equal(session:partyRevision(), partyRevision + 1, "the party revision advances exactly once")
  Assert.isTrue(snapshot.dirtySections.money, "money stays staged")
  Assert.isTrue(snapshot.dirtySections.flags, "field flags stay staged")
  Assert.isTrue(snapshot.dirtySections.bag, "bag stays staged")
  Assert.isTrue(snapshot.dirtySections.location, "location stays staged")
  assertRevisionBumpedOnce(session, before)
  local retired = session:applyMonDraft(stale)
  Assert.isFalse(retired.ok, "a draft opened before the reset no longer applies")
end

function T.tests.bag_reset_restores_saved_quantities_but_keeps_other_sections()
  local session = openSession()
  dirtyEverything(session)
  local before = session:snapshot().revision

  Assert.isTrue(session:discardSection("Bag"), "a changed Bag section reports its reset")

  local snapshot = session:snapshot()
  Assert.isFalse(snapshot.dirtySections.bag, "bag is clean")
  Assert.deepEqual(session:bagSnapshot("balls"), {}, "staged items return to their saved pockets")
  Assert.isTrue(snapshot.dirtySections.money, "money stays staged")
  Assert.isTrue(snapshot.dirtySections.flags, "field flags stay staged")
  Assert.isTrue(snapshot.dirtySections.party, "party stays staged")
  Assert.isTrue(snapshot.dirtySections.location, "location stays staged")
  assertRevisionBumpedOnce(session, before)
end

function T.tests.section_reset_without_changes_reports_no_change_and_keeps_its_revision()
  local session = openSession()
  local before = session:snapshot().revision
  for _, section in ipairs({ "Location", "Player", "Party", "Bag", "Progress" }) do
    Assert.isFalse(session:discardSection(section), section .. " has nothing to reset")
  end
  Assert.equal(session:snapshot().revision, before, "an idle reset never bumps the revision")
  Assert.isFalse(session:isDirty(), "an idle reset stays clean")
end

function T.tests.unknown_section_reset_fails_loudly()
  local session = openSession()
  Assert.isTrue(type(session.discardSection) == "function", "the session owns a section-local reset")
  Assert.throws(function()
    session:discardSection("Unknown")
  end, "an unknown section name is a programming error")
end

function T.tests.invalid_party_is_rejected_at_session_entry_without_mutating_the_save()
  local fixture = Fixture.new()
  local validSession = assert(Session.new({
    record = fixture.initial,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  }))
  local draft = assert(validSession:beginMonAdd("CHIKORITA", {
    location = 7,
    date = { year = 2000, month = 1, day = 1 },
  }))
  local invalid = fixture.copy(fixture.initial)
  local mon = draft:record()
  mon.condition.effects = nil
  invalid.mons.party.mons[1] = mon
  local before = fixture.copy(invalid)

  local session, failure = Session.new({
    record = invalid,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  })

  Assert.isNil(session, "a current Party record missing typed effects fails before UI projection")
  Assert.equal(failure.code, "SAVE_EDITOR_PARTY_INVALID", "the opening error identifies the touched Party domain")
  Assert.equal(failure.context.saveId, fixture.saveId, "the error retains the selected save identity")
  Assert.isTrue(
    failure.context.reason:find("effects", 1, true) ~= nil,
    "the error preserves the domain validation cause"
  )
  Assert.deepEqual(invalid, before, "rejected Party validation leaves the source save unchanged")
  Assert.isNil(fixture.store:load(fixture.saveId).mons.party.mons[1], "validation does not publish a save write")
end

function T.tests.party_with_non_array_effects_is_rejected_at_session_entry()
  local fixture = Fixture.new()
  local validSession = assert(Session.new({
    record = fixture.initial,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  }))
  local draft = assert(validSession:beginMonAdd("CHIKORITA", {
    location = 7,
    date = { year = 2000, month = 1, day = 1 },
  }))
  local mon = draft:record()
  mon.condition.effects = "poison"
  local invalid = fixture.copy(fixture.initial)
  invalid.mons.party.mons[1] = mon
  local before = fixture.copy(invalid)

  local session, failure = Session.new({
    record = invalid,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  })

  Assert.isNil(session, "typed condition effects must be an array at Party entry")
  Assert.equal(failure.code, "SAVE_EDITOR_PARTY_INVALID")
  Assert.isTrue(
    failure.context.reason:find("condition effects must be an array", 1, true) ~= nil,
    "the app error preserves the Party validator's malformed-array cause"
  )
  Assert.deepEqual(invalid, before, "rejected shape validation leaves the source save unchanged")
  Assert.isNil(fixture.store:load(fixture.saveId).mons.party.mons[1], "validation does not publish a save write")
end

function T.tests.canonical_party_conditions_survive_session_entry()
  local fixture = Fixture.new()
  local baseSession = assert(Session.new({
    record = fixture.initial,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  }))
  local draft = assert(baseSession:beginMonAdd("CHIKORITA", {
    location = 7,
    date = { year = 2000, month = 1, day = 1 },
  }))
  local mon = draft:record()
  mon.condition.effects = require("libs.mons.src.gen4.StatusCodec").decode(0x8)
  local input = fixture.copy(fixture.initial)
  input.mons.party.mons[1] = mon

  local session = assert(Session.new({
    record = input,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  }))

  local member = assert(session:partySnapshot().members[1])
  Assert.deepEqual(member.mon.condition.effects, mon.condition.effects, "canonical typed status survives entry")
  Assert.equal(
    require("libs.hgss.src.ui.PartyScreenTheme").statusKey(member.mon.condition),
    "poison",
    "the strict Party presentation projection recognizes canonical poison"
  )
  Assert.isNil(member.mon.condition.status, "entry does not add an obsolete status scalar")
  Assert.deepEqual(input.mons.party.mons[1], mon, "session construction leaves the source Party untouched")
end

function T.tests.supported_legacy_party_normalizes_before_session_entry()
  local fixture = Fixture.new()
  local baseSession = assert(Session.new({
    record = fixture.initial,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  }))
  local draft = assert(baseSession:beginMonAdd("CHIKORITA", {
    location = 7,
    date = { year = 2000, month = 1, day = 1 },
  }))
  local legacyMon = draft:record()
  legacyMon.schema = require("libs.mons.src.Mon").LEGACY_SCHEMA
  legacyMon.condition = { status = 0x8, currentHp = legacyMon.condition.currentHp }
  local legacy = fixture.copy(fixture.initial)
  local GameSave = require("libs.hgss.src.save.GameSave")
  local MonsSave = require("libs.mons.src.MonsSave")
  legacy.schema = GameSave.LEGACY_V5_SCHEMA
  legacy.fashionCase = nil
  legacy.mailbox = nil
  legacy.photoAlbum = nil
  legacy.mons = {
    schema = MonsSave.LEGACY_SCHEMA,
    catalogFingerprint = "legacy-catalog",
    rng = fixture.copy(fixture.initial.mons.rng),
    party = { max = 6, mons = { legacyMon } },
  }
  local original = fixture.copy(legacy)
  local normalized = assert(GameSave.normalize(legacy))

  Assert.deepEqual(legacy, original, "official normalization leaves the stored legacy record unchanged")
  local session = assert(Session.new({
    record = normalized,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  }))
  local member = assert(session:partySnapshot().members[1])
  Assert.equal(member.mon.schema, require("libs.mons.src.Mon").SCHEMA)
  Assert.deepEqual(
    member.mon.condition.effects,
    require("libs.mons.src.gen4.StatusCodec").decode(0x8),
    "the supported legacy status is migrated by GameSave normalization"
  )
  Assert.equal(
    require("libs.hgss.src.ui.PartyScreenTheme").statusKey(member.mon.condition),
    "poison",
    "the normalized Party reaches the strict presentation projection"
  )
end

function T.tests.global_reset_still_clears_every_staged_section()
  local session = openSession()
  dirtyEverything(session)

  Assert.isTrue(session:discard(), "a dirty session reports its global reset")

  local snapshot = session:snapshot()
  Assert.isFalse(snapshot.dirtySections.money, "money is clean")
  Assert.isFalse(snapshot.dirtySections.frame, "dialogue frame is clean")
  Assert.isFalse(snapshot.dirtySections.flags, "field flags are clean")
  Assert.isFalse(snapshot.dirtySections.party, "party is clean")
  Assert.isFalse(snapshot.dirtySections.bag, "bag is clean")
  Assert.isFalse(snapshot.dirtySections.location, "location is clean")
  Assert.isFalse(session:isDirty(), "the session is clean")
end

return T
