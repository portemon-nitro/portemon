-- Mon preparation: detached validated candidates with a one-shot install
-- operation, plus the read-only derived-stat projection used by item and
-- summary calculations.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local function newService()
  local catalog = CatalogFixture.makeCatalog()
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x44444444):capture()),
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
  local factory = CatalogFixture.makeFactory(0x55555555, catalog)
  Assert.isTrue(service:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  return service
end

local T = {}

function T.prepare_rejects_a_stale_revision_without_touching_state()
  local service = newService()
  local before = service:partyMon(0)
  local revision = service:partyRevision()
  local update = service:partyMon(0)
  update.heldItem = "SITRUS_BERRY"
  local preparation, reason = service:preparePartyChanges(revision + 1, { { slot = 0, mon = update } })
  Assert.isNil(preparation)
  Assert.equal(reason, "stale")
  Assert.deepEqual(service:partyMon(0), before)
  Assert.equal(service:partyRevision(), revision)
end

function T.prepare_validates_before_allocating_and_publishes_once()
  local service = newService()
  local revision = service:partyRevision()
  local update = service:partyMon(0)
  update.heldItem = "SITRUS_BERRY"
  local preparation, reason = service:preparePartyChanges(revision, { { slot = 0, mon = update } })
  assert(preparation ~= nil, "a current revision prepares: " .. tostring(reason))
  Assert.isTrue(preparation.isCurrent())
  update.heldItem = "POTION"
  preparation.publish()
  Assert.equal(service:partyMon(0).heldItem, "SITRUS_BERRY", "post-preparation caller edits never publish")
  Assert.equal(service:partyRevision(), revision + 1)
  Assert.isFalse(preparation.isCurrent(), "publication moves the revision past the preparation")
  Assert.throws(function()
    preparation.publish()
  end, "a repeated publish is a programming error")
  Assert.equal(service:partyRevision(), revision + 1, "a duplicate publish never increments twice")
end

function T.prepare_raises_on_a_malformed_candidate()
  local service = newService()
  local revision = service:partyRevision()
  local update = service:partyMon(0)
  update.heldItem = "BOGUS_ITEM"
  Assert.throws(function()
    service:preparePartyChanges(revision, { { slot = 0, mon = update } })
  end, "malformed generated data fails loudly instead of preparing")
  Assert.equal(service:partyRevision(), revision)
end

function T.derive_projects_full_stats_without_mutating()
  local service = newService()
  local revision = service:partyRevision()
  local projected = service:derive(service:partyMon(0))
  local direct = service:partyMonDerived(0)
  Assert.equal(projected.level, direct.level)
  Assert.equal(projected.maxHp, direct.maxHp)
  Assert.isTrue(projected.attack > 0 and projected.defense > 0, "full stats project")
  Assert.isTrue(projected.speed > 0 and projected.specialAttack > 0 and projected.specialDefense > 0)
  Assert.equal(service:partyRevision(), revision, "a read-only projection never mutates")
end

function T.health_adjustment_preserves_damage_across_maximum_changes()
  local adjust = HgssMonService.adjustHpForMaxChange
  Assert.equal(adjust(30, 32, 20), 22, "a raised maximum preserves damage")
  Assert.equal(adjust(30, 32, 30), 32, "full health stays full")
  Assert.equal(adjust(30, 28, 30), 28, "a shrunk maximum clamps")
  Assert.equal(adjust(30, 28, 20), 18, "damage survives a shrink")
  Assert.equal(adjust(30, 32, 0), 0, "the fainted stay fainted")
  Assert.equal(newService():currentMapSection(), 7, "the service reports its configured section")
end

function T.ev_staging_finalizes_health_through_shared_derivation()
  local service = newService()
  local maxHp = service:derive(service:partyMon(0)).maxHp
  local staged = service:partyMon(0)
  staged.evs.hp = 96
  staged.condition.currentHp = maxHp - 4
  local finalized = service:refreshStagedHp(staged, maxHp)
  local recalculated = service:derive(finalized)
  Assert.isTrue(recalculated.maxHp >= maxHp, "added health effort cannot shrink the maximum")
  Assert.equal(
    finalized.condition.currentHp,
    math.min(maxHp - 4 + (recalculated.maxHp - maxHp), recalculated.maxHp),
    "damage survives the recalculation"
  )
  local fainted = service:partyMon(0)
  fainted.evs.hp = 96
  fainted.condition.currentHp = 0
  local kept = service:refreshStagedHp(fainted, maxHp)
  Assert.equal(kept.condition.currentHp, 0, "effort changes never revive the fainted")
end

return { tests = T }
