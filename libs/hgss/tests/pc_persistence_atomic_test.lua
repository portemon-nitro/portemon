-- Party and boxes publish as one revision-checked custody change.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

local function serviceModule()
  local ok, result = pcall(require, "libs.hgss.src.mons.HgssMonService")
  Assert.isTrue(ok, "Pokemon custody must support atomic party and box changes")
  Assert.isTrue(
    type(result.preparePcChanges) == "function",
    "Pokemon custody must expose a joint prepared change for party and boxes"
  )
  return result
end

function T.stale_joint_preparation_cannot_duplicate_or_lose_a_mon()
  local HgssMonService = serviceModule()
  local catalog = CatalogFixture.makeCatalog()
  local args = CatalogFixture.factoryArgs(0x76543210, catalog)
  local MonFactory = require("libs.mons.src.gen4.MonFactory")
  local factory = MonFactory.new(args)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))
  local party = Party.new()
  party:add(mon)
  local bucket = MonsSave.capture(party:capture(), args.rng:capture())
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = bucket,
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
  Assert.isTrue(type(service.boxRevision) == "function", "the joint preparation tracks a box revision")
  local expected = { partyRevision = service:partyRevision(), boxRevision = service:boxRevision() }
  local change = { party = {}, boxUpdates = { { box = 0, slot = 0, mon = mon } } }
  local first = service:preparePcChanges(expected, change)
  local stale = service:preparePcChanges(expected, change)
  Assert.notNil(first)
  Assert.notNil(stale)

  first.publish()
  Assert.isFalse(stale.isCurrent(), "the second preparation observes the moved owner revision")
  local rejected, reason = service:preparePcChanges(expected, change)
  Assert.isNil(rejected)
  Assert.equal(reason, "stale")
  Assert.equal(service:partyCount(), 0)
  Assert.deepEqual(service:boxMon(0, 0), mon)
  Assert.equal(service:partyRevision(), expected.partyRevision + 1)
  Assert.equal(service:boxRevision(), expected.boxRevision + 1)
  local current = { partyRevision = service:partyRevision(), boxRevision = service:boxRevision() }
  local noOp = service:preparePcChanges(current, { boxUpdates = { { box = 0, slot = 0, mon = mon } } })
  Assert.isFalse(noOp.changed)
  noOp.publish()
  Assert.equal(service:partyRevision(), current.partyRevision)
  Assert.equal(service:boxRevision(), current.boxRevision)
  Assert.throws(function()
    first.publish()
  end, "a published token is single-use")
end

return { tests = T }
