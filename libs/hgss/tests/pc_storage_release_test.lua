-- Release eligibility follows the first protected move in stored move
-- order, scans expanded box addresses, and revalidates before publication.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PcStorageActions = require("libs.hgss.src.field.PcStorageActions")

local T = {}

local function catalogWithProtectedMoves()
  local root = CatalogFixture.buildAssetRoot()
  local names = {
    { "SURF", 57 },
    { "ROCK_CLIMB", 431 },
    { "WATERFALL", 127 },
    { "FLY", 19 },
  }
  for _, entry in ipairs(names) do
    local move = {}
    for key, value in pairs(root.moves.TACKLE) do
      move[key] = value
    end
    move.nativeId = entry[2]
    move.name = entry[1]
    root.moves[entry[1]] = move
  end
  Assert.isTrue(MonAssetSchema.assertCatalog(root))
  return MonCatalog.new(root, CatalogFixture.makeItemCatalog())
end

local function services(boxCount)
  local catalog = catalogWithProtectedMoves()
  local mons = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(
      Party.new():capture(),
      Lcrng.new(0x10203040):capture(),
      catalog:fingerprint(),
      nil,
      { configuredCount = boxCount or 18 }
    ),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
  local factory = CatalogFixture.makeFactory(0x55667788, catalog)
  for _ = 1, 2 do
    Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  end
  return mons, HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
end

local function release(actions, slot)
  return actions:preview({ kind = "release", source = { kind = "party", slot = slot } })
end

function T.first_protected_move_selects_the_release_return_guard()
  local mons, bag = services()
  mons:setMove(0, 0, "SURF")
  mons:setMove(0, 1, "FLY")
  mons:setMove(1, 0, "SURF")
  local actions = PcStorageActions.new({ mons = mons, bag = bag })
  Assert.equal(release(actions, 0).kind, "confirm", "another Surf user clears the first matching move")

  mons:setMove(0, 1, "TACKLE")
  mons:setMove(0, 0, "FLY")
  mons:setMove(0, 1, "SURF")
  local reversed = release(actions, 0)
  Assert.equal(reversed.kind, "refused", "move order makes Fly the sole first-match return guard")

  mons:setMove(0, 0, "CUT")
  mons:deleteMove(0, 1)
  Assert.equal(release(actions, 0).kind, "confirm", "Cut alone is not protected by this rule")
end

function T.expanded_boxes_count_as_alternative_hm_users_and_stale_release_does_not_publish()
  local mons, bag = services(37)
  mons:setMove(0, 0, "SURF")
  mons:setMove(1, 0, "TACKLE")
  local boxMon = mons:partyMon(1)
  boxMon.moves[1] = { move = "SURF", pp = mons:catalog():move("SURF").basePp, ppUps = 0 }
  local boxed = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 36, slot = 29, mon = boxMon } } }))
  boxed.publish()
  Assert.equal(mons:boxCount(), 37)

  local actions = PcStorageActions.new({ mons = mons, bag = bag })
  local intent = release(actions, 0)
  Assert.equal(intent.kind, "confirm", "a duplicate move in the last expanded box is found")
  local before = mons:partyMon(0)
  local external = mons:partyMon(1)
  external.heldItem = "SITRUS_BERRY"
  local changed = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 1, mon = external } }))
  changed.publish()
  Assert.equal(actions:commit(intent, true).kind, "stale")
  Assert.equal(mons:partyCount(), 2, "stale release never removes the target")
  Assert.deepEqual(mons:partyMon(0), before)
  Assert.notNil(mons:boxMon(36, 29), "stale release never alters the last box")
  Assert.equal(bag:quantity("SITRUS_BERRY"), 0, "release and stale cleanup never add held items to Bag")
end

return { tests = T }
