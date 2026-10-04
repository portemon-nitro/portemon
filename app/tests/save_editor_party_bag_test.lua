-- Save editor party and inventory operations stay inside the canonical owners.

local Assert = require("tests.support.Assert")
local Fixture = require("app.tests.support.SaveEditorFixture")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local MonsSave = require("libs.mons.src.MonsSave")
local Mon = require("libs.mons.src.Mon")

local T = { tests = {} }

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

local function monService(fixture, bucket)
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

local function bagService(fixture, bucket)
  return HgssBagService.new({ catalog = fixture.context.itemCatalog, bag = bucket })
end

local function buildFixture(monCount, bagKind)
  local fixture = Fixture.new()
  local candidate = copy(fixture.initial)
  if monCount > 0 then
    local service = monService(fixture)
    local species = { "CHIKORITA", "TOTODILE", "EEVEE" }
    for index = 1, monCount do
      local added = service:giveMon({
        species = species[(index - 1) % #species + 1],
        level = 5,
        location = 7,
        date = CatalogFixture.metDate(),
      })
      Assert.isTrue(added, "fixture Pokemon must fit in the real party service")
    end
    candidate.mons = service:capture()
  end
  if bagKind == "ordered_registered" then
    local bag = bagService(fixture)
    Assert.isTrue(bag:add("GREAT_BALL", 2))
    Assert.isTrue(bag:add("POKE_BALL", 3))
    Assert.isTrue(bag:add("BICYCLE", 1))
    Assert.equal(bag:tryRegister("BICYCLE"), "slot1")
    candidate.bag = bag:capture()
  elseif bagKind == "full_key_items" then
    local bag = bagService(fixture)
    local catalog = fixture.context.itemCatalog
    local pocket = catalog:pocket("key_items")
    for _, itemKey in ipairs(catalog:itemKeys()) do
      if itemKey ~= "NONE" and catalog:item(itemKey).pocket == "key_items" then
        Assert.isTrue(bag:add(itemKey, 1), "each fixture key item fits until the pocket is full")
        if #bag:pocketItems("key_items") == pocket.capacity then
          break
        end
      end
    end
    Assert.equal(#bag:pocketItems("key_items"), pocket.capacity)
    local absentKey = nil
    for _, itemKey in ipairs(catalog:itemKeys()) do
      if itemKey ~= "NONE" and catalog:item(itemKey).pocket == "key_items" and bag:quantity(itemKey) == 0 then
        absentKey = itemKey
        break
      end
    end
    Assert.notNil(absentKey, "the item fixture has a key item outside the full pocket")
    fixture.fullPocketProbe = absentKey
    candidate.bag = bag:capture()
  end
  Assert.isTrue(fixture.store:save(candidate), "the canonical fixture record must accept real mon and bag buckets")
  fixture.initial = assert(fixture.store:load(fixture.saveId))
  return fixture
end

local function sessionFor(fixture)
  local Session = require("app.src.saveeditor.SaveEditorSession")
  local session, err = Session.new({
    record = fixture.initial,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  })
  Assert.isNil(err, "the real save fixture must open in an editor session")
  return assert(session)
end

local function sessionBucket(session, bucket)
  return session:captureCandidate()[bucket]
end

local function assertSuccess(result, message)
  Assert.isTrue(type(result) == "table" and result.ok == true, message)
  return result
end

local function richMon(fixture)
  local factory = CatalogFixture.makeFactory(0x10293847, fixture.context.monCatalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ profile = fixture.initial.playerData.profile }))
  record.markings = 5
  record.contest = { cool = 11, beauty = 12, cute = 13, smart = 14, tough = 15, sheen = 16 }
  record.ribbons = { ds1 = 3, gba = 5, ds2 = 7 }
  record.fatefulEncounter = true
  record.shinyLeaves = 9
  record.egg = { location = 4, date = { year = 2008, month = 2, day = 3 } }
  record.pokerus = 7
  record.mood = -3
  record.capsule = { id = 2, seals = { { x = 4, y = 5, graphic = 6 } } }
  record.mail = {}
  return Mon.validate(record, {
    catalog = fixture.context.monCatalog,
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
  })
end

local function installParty(fixture, mons)
  local bucket =
    MonsSave.capture({ max = 6, mons = mons }, fixture.initial.mons.rng, fixture.context.monCatalog:fingerprint())
  local candidate = copy(fixture.initial)
  candidate.mons = bucket
  Assert.isTrue(fixture.store:save(candidate))
  fixture.initial = assert(fixture.store:load(fixture.saveId))
end

local function saveEditorApi(session)
  for _, method in ipairs({
    "partyRevision",
    "partySnapshot",
    "beginMonEdit",
    "beginMonAdd",
    "applyMonDraft",
    "removePartyMon",
    "swapPartyMons",
    "bagSnapshot",
    "setBagQuantity",
  }) do
    Assert.isTrue(type(session[method]) == "function", "save editor Session must expose " .. method)
  end
end

function T.tests.cancelled_add_keeps_rng_and_apply_publishes_one_candidate_revision()
  local fixture = buildFixture(0)
  local session = sessionFor(fixture)
  saveEditorApi(session)
  local before = session:captureCandidate()
  local partyRevision = session:partyRevision()
  local options = { location = 7, date = CatalogFixture.metDate() }
  local cancelled = assert(session:beginMonAdd("CHIKORITA", options))
  local cancelledRecord = cancelled:record()
  Assert.deepEqual(session:captureCandidate(), before, "an abandoned Add draft must not touch party or RNG")
  Assert.equal(session:partyRevision(), partyRevision)

  local expected = monService(fixture)
  Assert.isTrue(expected:giveMon({ species = "CHIKORITA", level = 1, location = 7, date = options.date }))
  local accepted = assert(session:beginMonAdd("CHIKORITA", options))
  Assert.deepEqual(accepted:record(), cancelledRecord, "a cancelled candidate must not consume Session RNG")
  assertSuccess(session:applyMonDraft(accepted), "an accepted Add draft must publish")
  Assert.equal(session:partyRevision(), partyRevision + 1)
  Assert.deepEqual(
    sessionBucket(session, "mons"),
    expected:capture(),
    "Add publishes the real factory candidate and RNG"
  )

  local full = buildFixture(6)
  local fullSession = sessionFor(full)
  saveEditorApi(fullSession)
  local fullBefore = fullSession:captureCandidate()
  local refused = fullSession:beginMonAdd("CHIKORITA", options)
  Assert.isNil(refused, "a full party cannot create another Add draft")
  Assert.deepEqual(fullSession:captureCandidate(), fullBefore)
end

function T.tests.party_reorder_remove_and_stale_draft_keep_slot_identity()
  local fixture = buildFixture(2)
  local session = sessionFor(fixture)
  saveEditorApi(session)
  local before = sessionBucket(session, "mons").party.mons
  local revision = session:partyRevision()
  local stale = assert(session:beginMonEdit(0))
  Assert.isTrue(stale:setScalar("friendship", 71))
  assertSuccess(session:swapPartyMons(0, 1), "reorder uses the party owner")
  Assert.equal(session:partyRevision(), revision + 1)
  Assert.deepEqual(sessionBucket(session, "mons").party.mons, { before[2], before[1] })

  local afterReorder = sessionBucket(session, "mons")
  local staleResult = session:applyMonDraft(stale)
  Assert.isFalse(staleResult.ok, "a draft opened before a reorder cannot overwrite its new slot occupant")
  Assert.equal(staleResult.error.code, "SAVE_EDITOR_STALE_DRAFT")
  Assert.deepEqual(sessionBucket(session, "mons"), afterReorder)

  assertSuccess(session:removePartyMon(1), "removal uses the party owner")
  Assert.deepEqual(sessionBucket(session, "mons").party.mons, { before[2] })
  Assert.equal(session:partyRevision(), revision + 2)
end

function T.tests.bag_changes_use_catalog_pockets_caps_order_and_registration()
  local fixture = buildFixture(0, "ordered_registered")
  local session = sessionFor(fixture)
  saveEditorApi(session)
  local before = sessionBucket(session, "bag")
  local failed = session:setBagQuantity("POKE_BALL", 1000)
  Assert.isFalse(failed.ok, "stack maximum comes from the real pocket definition")
  Assert.deepEqual(sessionBucket(session, "bag"), before, "a refused stack update publishes no partial bag")

  assertSuccess(session:setBagQuantity("POKE_BALL", 5), "an existing stack can change quantity")
  assertSuccess(session:setBagQuantity("POTION", 3), "a catalog item chooses its own pocket")
  local bag = sessionBucket(session, "bag")
  Assert.equal(bag.pockets.balls[1].item, "GREAT_BALL", "manual pocket order survives quantity changes")
  Assert.equal(bag.pockets.balls[2].item, "POKE_BALL")
  Assert.equal(bag.pockets.balls[2].quantity, 5)
  Assert.equal(bag.pockets.medicine[1].item, "POTION")
  Assert.deepEqual(bag.registered, { "BICYCLE" }, "inventory registration remains owned by the bag service")

  local full = buildFixture(0, "full_key_items")
  local fullSession = sessionFor(full)
  saveEditorApi(fullSession)
  local fullBefore = sessionBucket(fullSession, "bag")
  local cannotAdd = fullSession:setBagQuantity(assert(full.fullPocketProbe), 1)
  Assert.isFalse(cannotAdd.ok, "pocket capacity comes from the catalog")
  Assert.deepEqual(sessionBucket(fullSession, "bag"), fullBefore)
  Assert.isFalse(fullSession:setBagQuantity("NONE", 1).ok, "the NONE catalog key cannot become an inventory stack")

  assertSuccess(session:setBagQuantity("BICYCLE", 0), "zero removes a stack")
  local removed = sessionBucket(session, "bag")
  Assert.deepEqual(removed.registered, { "BICYCLE" }, "the Bag owner retains registration after final-copy removal")
  Assert.equal(removed.pockets.key_items[1], nil)
end

function T.tests.raw_apply_save_reopen_preserves_unsupported_fields_and_readonly_derivations()
  local fixture = buildFixture(0)
  local original = richMon(fixture)
  installParty(fixture, { original })
  local session = sessionFor(fixture)
  saveEditorApi(session)
  local draft = assert(session:beginMonEdit(0))
  local before = draft:record()
  local setterOk, setterResult = pcall(draft.setScalar, draft, "level", 99)
  Assert.isFalse(setterOk and type(setterResult) == "table" and setterResult.ok == true)
  Assert.deepEqual(draft:record(), before, "derived Level is read-only")
  Assert.isFalse(draft:isDirty(), "a rejected read-only edit does not dirty the draft")
  Assert.isTrue(draft:setScalar("friendship", 71), "a supported raw field can be edited")
  assertSuccess(session:applyMonDraft(draft), "the valid raw draft applies")

  local expected = copy(original)
  expected.friendship = 71
  Assert.deepEqual(sessionBucket(session, "mons").party.mons[1], expected)
  assertSuccess(session:save(), "the applied record saves through the canonical store")
  local reopenedRecord = assert(fixture.store:load(fixture.saveId))
  Assert.deepEqual(reopenedRecord.mons.party.mons[1], expected)
  fixture.initial = reopenedRecord
  local reopened = sessionFor(fixture)
  Assert.deepEqual(sessionBucket(reopened, "mons").party.mons[1], expected)
end

return T
