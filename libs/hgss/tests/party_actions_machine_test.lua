-- The teach_move publication branch: revision guards, stale expected
-- moves, HM zero-delta accounting, and single-effect replays over the
-- live mon and bag services.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyActions = require("libs.hgss.src.field.PartyActions")

local function itemRoot()
  local root = ItemFixture.buildAssetRoot()
  root.items.TM01.tmhmMoveNativeId = 331
  return root
end

local function openServices()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local itemCatalog = ItemCatalog.new(itemRoot())
  local catalog = MonCatalog.new(CatalogFixture.buildAssetRoot(), itemCatalog)
  local mons = require("libs.hgss.src.mons.HgssMonService").new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x55555555):capture()),
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
  local bag = require("libs.hgss.src.items.HgssBagService").new({ catalog = itemCatalog })
  local factory = CatalogFixture.makeFactory(0x66666666, catalog)
  return mons, bag, factory
end

local function addGifted(mons, factory, species, level)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level or 1 }))
  Assert.isTrue(mons:addMon(mon), "setup mon must enter the party")
end

local function teachRequest(mons, bag, slot, item, moveSlot, expectedOldMove)
  return {
    kind = "teach_move",
    slot = slot,
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
    item = item,
    moveSlot = moveSlot,
    expectedOldMove = expectedOldMove,
  }
end

local T = {}

function T.unknown_kinds_stale_revisions_and_missing_items_refuse()
  local mons, bag, factory = openServices()
  addGifted(mons, factory, "CHIKORITA", 1)
  local actions = PartyActions.new({ mons = mons, bag = bag })

  local absent = actions:preview(teachRequest(mons, bag, 0, "TM01"))
  Assert.equal(absent.kind, "stale", "an unowned machine cannot teach")

  Assert.isTrue(bag:add("TM01", 1))
  local monRevision = mons:partyRevision()
  local bagRevision = bag:revision()
  local drifted = teachRequest(mons, bag, 0, "TM01")
  mons:setMove(0, 0, "TOXIC")
  Assert.equal(actions:preview(drifted).kind, "stale", "a drifted party revision refuses")
  Assert.equal(actions:commit(drifted).kind, "stale", "a drifted commit publishes nothing")
  Assert.equal(mons:partyRevision(), monRevision + 1, "only the setup drift moved the revision")
  Assert.equal(bag:revision(), bagRevision, "refusals move no bag revision")
  Assert.equal(bag:quantity("TM01"), 1, "refusals consume nothing")
end

function T.stale_expected_moves_and_wrong_slots_refuse_before_mutation()
  local mons, bag, factory = openServices()
  addGifted(mons, factory, "CHIKORITA", 9)
  Assert.isTrue(bag:add("TM01", 1))
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local monRevision = mons:partyRevision()

  local wrong = actions:commit(teachRequest(mons, bag, 0, "TM01", 0, "GROWL"))
  Assert.equal(wrong.kind, "stale", "a mismatched expected move refuses")
  local unknown = actions:commit(teachRequest(mons, bag, 0, "TM01", 0, "NO_SUCH_MOVE"))
  Assert.equal(unknown.kind, "stale", "an unknown expected move refuses")
  Assert.equal(mons:partyRevision(), monRevision, "stale guards publish nothing")
  Assert.equal(bag:quantity("TM01"), 1, "stale guards consume nothing")
end

function T.hm_success_moves_no_bag_revision_and_replays_go_stale()
  local mons, bag, factory = openServices()
  addGifted(mons, factory, "TOTODILE", 1)
  Assert.isTrue(bag:add("HM01", 3))
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local bagRevision = bag:revision()

  local request = teachRequest(mons, bag, 0, "HM01")
  local outcome = actions:commit(request)
  Assert.equal(outcome.kind, "changed", "HM teaching publishes")
  Assert.equal(outcome.feedback.textKey, "learned", "teaching reports its learned feedback")
  Assert.equal(bag:quantity("HM01"), 3, "HMs are never consumed")
  Assert.equal(bag:revision(), bagRevision, "a zero HM delta moves no bag revision")
  Assert.equal(actions:commit(request).kind, "stale", "replaying a consumed revision teaches nothing twice")
  Assert.equal(bag:quantity("HM01"), 3, "the replay consumes nothing")
end

function T.tm_preview_reports_readiness_without_reserving()
  local mons, bag, factory = openServices()
  addGifted(mons, factory, "CHIKORITA", 1)
  Assert.isTrue(bag:add("TM01", 1))
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local monRevision = mons:partyRevision()

  local preview = actions:preview(teachRequest(mons, bag, 0, "TM01"))
  Assert.equal(preview.kind, "ready", "a compatible free slot previews ready")
  Assert.equal(mons:partyRevision(), monRevision, "previews reserve nothing")
  Assert.equal(bag:quantity("TM01"), 1, "previews consume nothing")
end

return { tests = T }
