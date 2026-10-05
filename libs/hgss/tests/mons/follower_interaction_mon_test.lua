-- Follower interaction changes use the live party mutation boundary.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local function newService(initialMood)
  local catalog = MonCatalog.new(CatalogFixture.buildAssetRoot(), CatalogFixture.makeItemCatalog())
  local bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x1234):capture(), catalog:fingerprint())
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = bucket,
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  local mon = CatalogFixture.makeFactory(0x5678, catalog)
    :createNormal(CatalogFixture.normalRequest({ species = "EEVEE", level = 9 }))
  mon.friendship = 254
  mon.mood = initialMood or 126
  mon.shinyLeaves = 0
  Assert.isTrue(service:addMon(mon))
  return service
end

local T = {}

function T.deltas_clamp_and_noops_do_not_publish()
  local service = newService()
  local revision = service:partyRevision()
  service:applyFollowerInteractionDeltas(0, 20, 20)
  Assert.equal(service:partyMon(0).friendship, 255)
  Assert.equal(service:partyMon(0).mood, 127)
  Assert.equal(service:partyRevision(), revision + 1)

  service:applyFollowerInteractionDeltas(0, 1, 1)
  Assert.equal(service:partyRevision(), revision + 1)
  service:applyFollowerInteractionDeltas(0, -400, -400)
  Assert.equal(service:partyMon(0).friendship, 0)
  Assert.equal(service:partyMon(0).mood, -127)
  Assert.equal(service:partyRevision(), revision + 2)
end

function T.zero_delta_preserves_the_legacy_lower_mood_without_publishing()
  local service = newService(-128)
  local revision = service:partyRevision()
  service:applyFollowerInteractionDeltas(0, 0, 0)
  Assert.equal(service:partyMon(0).mood, -128)
  Assert.equal(service:partyRevision(), revision)
end

function T.leaf_awards_and_crown_are_idempotent()
  local service = newService()
  for leaf = 1, 4 do
    Assert.isTrue(service:tryGiveShinyLeaf(0, leaf))
  end
  Assert.equal(service:shinyLeafCount(0), 4)
  local revision = service:partyRevision()
  Assert.isFalse(service:tryGiveShinyLeafCrown(0))
  Assert.isFalse(service:tryGiveShinyLeaf(0, 4))
  Assert.equal(service:partyRevision(), revision)
  Assert.isTrue(service:tryGiveShinyLeaf(0, 5))
  Assert.equal(service:shinyLeafCount(0), 5)
  Assert.isTrue(service:tryGiveShinyLeafCrown(0))
  Assert.equal(service:shinyLeafCount(0), 6)
  Assert.isFalse(service:tryGiveShinyLeafCrown(0))
  Assert.equal(service:partyRevision(), revision + 2)
end

return { tests = T }
