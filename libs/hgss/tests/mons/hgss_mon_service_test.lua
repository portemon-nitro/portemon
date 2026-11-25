-- HGSS mon-service mutation semantics: form changes are validated and isolated.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local function withoutForm(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    if key ~= "form" then
      copy[key] = withoutForm(item)
    end
  end
  return copy
end

local function newService()
  local root = CatalogFixture.buildAssetRoot()
  root.species.EEVEE.forms[1].types = { "fire", "dark" }
  local catalog = MonCatalog.new(root, CatalogFixture.makeItemCatalog())
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x33333333):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", form = 0 }))
  Assert.isTrue(service:addMon(mon), "the multi-form mon must enter the party")
  return service
end

local T = {}

function T.set_mon_form_validates_and_mutates_only_form()
  local service = newService()
  local before = service:partyMon(0)
  local revision = service:partyRevision()

  service:setMonForm(0, 1)
  local changed = service:partyMon(0)
  Assert.equal(changed.form, 1, "a valid form persists")
  Assert.deepEqual(withoutForm(changed), withoutForm(before), "a form change preserves every other mon field")
  Assert.equal(service:partyRevision(), revision + 1, "a valid form publishes one mutation")

  local invalidBefore = service:partyMon(0)
  local invalidCapture = service:capture()
  local invalidRevision = service:partyRevision()
  local err = Assert.throws(function()
    service:setMonForm(0, 2)
  end)
  Assert.isTrue(Errors.is(err), "an invalid form is a structured service error")
  Assert.deepEqual(service:partyMon(0), invalidBefore, "an invalid form preserves the mon")
  Assert.deepEqual(service:capture(), invalidCapture, "an invalid form preserves the save capture")
  Assert.equal(service:partyRevision(), invalidRevision, "an invalid form publishes no mutation")
end

-- ScrCmd_GiveRibbon sets one stored boxed ribbon bit on the named party slot
-- through the owner, exactly like the source's unconditional mon-data write.
function T.give_ribbon_sets_the_named_stored_bit_once()
  local service = newService()
  Assert.equal(service:monRibbonCount(0), 0, "a new party mon owns no ribbon")
  service:giveRibbon(0, "ds1", 17)
  Assert.equal(service:monRibbonCount(0), 1, "the source ribbon bit is stored")
  local stored = service:partyMon(0)
  Assert.equal(math.floor(stored.ribbons.ds1 / 2 ^ 17) % 2, 1, "the ribbon lands on its own stored bit")
  Assert.equal(stored.ribbons.gba, 0, "the other ribbon fields stay untouched")
  Assert.equal(stored.ribbons.ds2, 0, "the other ribbon fields stay untouched")
  local revision = service:partyRevision()
  service:giveRibbon(0, "ds1", 17)
  Assert.equal(service:monRibbonCount(0), 1, "re-awarding the same ribbon changes nothing")
  Assert.equal(service:partyRevision(), revision + 1, "the repeated award still publishes its monotone write")
  service:giveRibbon(0, "gba", 31)
  service:giveRibbon(0, "ds2", 19)
  Assert.equal(service:monRibbonCount(0), 3, "every source field keeps its own bit")
  local err = Assert.throws(function()
    service:giveRibbon(0, "ds1", 28)
  end)
  Assert.isTrue(Errors.is(err), "a bit outside its boxed field is a structured service error")
  local _, slotErr = pcall(function()
    service:giveRibbon(3, "ds1", 0)
  end)
  Assert.isTrue(Errors.is(slotErr), "a missing party slot is a structured service error")
end

-- The source write is a single bit store: every other bit of the same stored
-- word survives, and a second award of an already-set bit stores nothing new.
function T.give_ribbon_preserves_the_other_bits_of_its_own_word()
  local service = newService()
  local mon = service:partyMon(0)
  mon.ribbons = { gba = 1 + 2 ^ 30, ds1 = 2 ^ 3, ds2 = 0 }
  local preparation, stale = service:preparePartyChanges(service:partyRevision(), { { slot = 0, mon = mon } })
  Assert.isNil(stale, "the fixture stages the stored ribbons")
  assert(preparation).publish()
  service:giveRibbon(0, "gba", 24)
  local stored = service:partyMon(0).ribbons
  Assert.equal(stored.gba, 1 + 2 ^ 24 + 2 ^ 30, "the award sets its own bit and keeps the neighbours")
  Assert.equal(stored.ds1, 2 ^ 3, "the award leaves the other stored words alone")
  service:giveRibbon(0, "gba", 24)
  service:giveRibbon(0, "gba", 24)
  Assert.equal(service:partyMon(0).ribbons.gba, 1 + 2 ^ 24 + 2 ^ 30, "a repeated award never shifts its bit")
  Assert.equal(service:monRibbonCount(0), 4, "the record keeps exactly the awarded ribbons")
end

return { tests = T }
