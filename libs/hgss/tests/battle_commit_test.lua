-- Battle result publication: every affected owner stages its candidate
-- first, then one synchronous publication installs them together exactly
-- once. Repeating the completion reuses the recorded receipt instead of
-- duplicating rewards, and a preparation failure leaves every live owner
-- on its last known-good state.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local COMMITTER_MODULE = "libs.hgss.src.battle.HgssBattleCommitter"

---@param name string module path under test
---@param behavior string missing owner under test
---@return table the loaded completion owner
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing battle completion owner: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the battle completion module loads")
  return loaded --[[@as table]]
end

---@return HgssMonService party owner holding one fixed mon
local function newPartyOwner()
  local catalog = CatalogFixture.makeCatalog()
  local owner = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture(), catalog:fingerprint()),
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
  local factory = CatalogFixture.makeFactory(0x33333333, catalog)
  Assert.isTrue(owner:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  return owner
end

---@return HgssBagService bag owner holding a fixed ball stock
local function newBagOwner()
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  Assert.isTrue(bag:add("POKE_BALL", 5))
  return bag
end

local T = {}

function T.staged_owners_publish_together_exactly_once()
  local party = newPartyOwner()
  local bag = newBagOwner()
  local partyRevision = party:partyRevision()
  local bagRevision = bag:revision()
  local update = party:partyMon(0)
  update.heldItem = "SITRUS_BERRY"
  local partyPrep, partyReason = party:preparePartyChanges(partyRevision, { { slot = 0, mon = update } })
  assert(partyPrep ~= nil, "a current party revision stages: " .. tostring(partyReason))
  local bagPrep, bagReason =
    bag:prepareInventoryChanges(bagRevision, { { op = "take", item = "POKE_BALL", quantity = 1 } })
  assert(bagPrep ~= nil, "a current bag revision stages: " .. tostring(bagReason))
  Assert.isTrue(partyPrep.isCurrent(), "the party candidate stays current before publication")
  Assert.isTrue(bagPrep.isCurrent(), "the bag candidate stays current before publication")
  Assert.equal(party:partyMon(0).heldItem, "NONE", "staging leaves the live party alone")
  Assert.equal(bag:quantity("POKE_BALL"), 5, "staging leaves the live bag alone")

  local Committer = requirePresent(COMMITTER_MODULE, "cross-owner result publication")
  Assert.isTrue(type(Committer.prepare) == "function", "the committer stages every owner before publishing")
  Assert.isTrue(type(Committer.commit) == "function", "the committer publishes staged owners synchronously")
  Assert.isTrue(type(Committer.receipt) == "function", "the committer records one receipt per outcome")

  local outcome = { id = "outcome-together-once", result = "win" }
  local prepared = Committer.prepare({ outcome = outcome, party = partyPrep, bag = bagPrep })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the first commit publishes the staged owners")
  Assert.equal(party:partyRevision(), partyRevision + 1, "the party publishes exactly once")
  Assert.equal(bag:revision(), bagRevision + 1, "the bag publishes exactly once")
  Assert.equal(party:partyMon(0).heldItem, "SITRUS_BERRY", "the staged party update lands")
  Assert.equal(bag:quantity("POKE_BALL"), 4, "the staged ball consumption lands")

  local repeatReceipt = Committer.commit(prepared)
  Assert.equal(repeatReceipt.outcomeId, receipt.outcomeId, "a repeated completion reuses the recorded receipt")
  Assert.equal(party:partyRevision(), partyRevision + 1, "a repeated completion never duplicates the party")
  Assert.equal(bag:revision(), bagRevision + 1, "a repeated completion never duplicates inventory")
  Assert.equal(bag:quantity("POKE_BALL"), 4, "a repeated completion never consumes a second ball")
end

function T.failed_preparation_leaves_every_live_owner_unchanged()
  local party = newPartyOwner()
  local bag = newBagOwner()
  local partyBefore = party:partyMon(0)
  local partyRevision = party:partyRevision()
  local bagRevision = bag:revision()
  local badUpdate = party:partyMon(0)
  badUpdate.heldItem = "SITRUS_BERRY"

  local staleParty, partyReason = party:preparePartyChanges(partyRevision + 1, { { slot = 0, mon = badUpdate } })
  Assert.isNil(staleParty)
  Assert.equal(partyReason, "stale")
  local staleBag, bagReason =
    bag:prepareInventoryChanges(bagRevision + 1, { { op = "take", item = "POKE_BALL", quantity = 1 } })
  Assert.isNil(staleBag)
  Assert.equal(bagReason, "stale")
  Assert.deepEqual(party:partyMon(0), partyBefore, "a stale party staging touches nothing")
  Assert.equal(party:partyRevision(), partyRevision, "a stale party staging moves no revision")
  Assert.equal(bag:quantity("POKE_BALL"), 5, "a stale bag staging touches nothing")
  Assert.equal(bag:revision(), bagRevision, "a stale bag staging moves no revision")

  local Committer = requirePresent(COMMITTER_MODULE, "atomic cross-owner failure handling")
  local outcome = { id = "outcome-failed-leaves-clean", result = "win" }
  local ok, err = pcall(Committer.prepare, { outcome = outcome, party = staleParty, bag = staleBag })
  Assert.isFalse(ok, "an invalid candidate batch never reaches publication: " .. tostring(err))
  Assert.deepEqual(party:partyMon(0), partyBefore, "a failed batch preserves the last known-good party")
  Assert.equal(bag:quantity("POKE_BALL"), 5, "a failed batch preserves the last known-good bag")
end

function T.stale_candidates_fail_at_commit_before_any_swap()
  local party = newPartyOwner()
  local bag = newBagOwner()
  local partyRevision = party:partyRevision()
  local update = party:partyMon(0)
  update.heldItem = "SITRUS_BERRY"
  local partyPrep = assert(party:preparePartyChanges(partyRevision, { { slot = 0, mon = update } }))
  local bagPrep = assert(bag:prepareInventoryChanges(bag:revision(), { { op = "take", item = "POKE_BALL", quantity = 1 } }))

  local Committer = requirePresent(COMMITTER_MODULE, "cross-owner result publication")
  local prepared = Committer.prepare({ outcome = { id = "outcome-stale-at-commit", result = "win" }, party = partyPrep, bag = bagPrep })
  Assert.isTrue(bag:add("POKE_BALL", 1), "a live restock moves the bag revision after staging")
  Assert.isFalse(bagPrep.isCurrent(), "the staged bag candidate is stale now")

  local ok, err = pcall(Committer.commit, prepared)
  Assert.isFalse(ok, "a stale candidate never publishes: " .. tostring(err))
  Assert.equal(party:partyMon(0).heldItem, "NONE", "the party keeps its last known-good state")
  Assert.equal(party:partyRevision(), partyRevision, "the party publishes nothing")
  Assert.equal(bag:quantity("POKE_BALL"), 6, "the bag keeps only its live restock")
  Assert.isNil(Committer.receipt("outcome-stale-at-commit"), "a failed commit records no receipt")
end

function T.receipt_accessor_returns_only_committed_outcomes()
  local Committer = requirePresent(COMMITTER_MODULE, "cross-owner result publication")
  Assert.isNil(Committer.receipt("outcome-never-committed"), "an unknown outcome has no receipt")
  local prepared =
    Committer.prepare({ outcome = { id = "outcome-receipt-roundtrip", result = "win" }, rewards = { kind = "money", amount = 10 } })
  local receipt = Committer.commit(prepared)
  local stored = Committer.receipt("outcome-receipt-roundtrip")
  Assert.deepEqual(stored, receipt, "the accessor returns the recorded receipt")
end

function T.dex_knowledge_publishes_through_the_committer()
  local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
  local dex = PokedexKnowledge.new({ species = { CHIKORITA = true, EEVEE = true } })
  local staged = dex:capture("EEVEE")
  local Committer = requirePresent(COMMITTER_MODULE, "cross-owner result publication")
  local prepared = Committer.prepare({ outcome = { id = "outcome-dex-through-commit", result = "win" }, dex = staged })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the dex batch commits")
  Assert.isTrue(dex:isCaught("EEVEE"), "the staged caught knowledge lands")
  Assert.isTrue(dex:isSeen("EEVEE"), "a caught mon counts as seen")
  local revision = dex:revision()
  Committer.commit(prepared)
  Assert.equal(dex:revision(), revision, "a repeated commit never republishes dex facts")
end

function T.roamer_writeback_applies_before_owner_swaps()
  local Fixture = require("libs.hgss.tests.encounter_fixture")
  local HgssRoamerState = require("libs.hgss.src.encounters.HgssRoamerState")
  local refs = Fixture.refs()
  local state = HgssRoamerState.new({
    records = { Fixture.roamerRecord(Fixture.roamerMon(), 11, "roaming", 0) },
    species = refs.species,
    maps = refs.maps,
  })
  local Committer = requirePresent(COMMITTER_MODULE, "cross-owner result publication")
  local prepared = Committer.prepare({
    outcome = { id = "outcome-roamer-through-commit", result = "capture" },
    roamer = { owner = state, key = "roamer-eevee", outcome = "captured", expectedRevision = 0, details = {} },
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the roamer outcome commits")
  Assert.equal(receipt.roamer.lifecycle, "caught", "the receipt carries the settled roamer")
  local ok = pcall(state.prepareEncounter, state, "roamer-eevee")
  Assert.isFalse(ok, "a caught roamer no longer offers encounters")
  local repeatReceipt = Committer.commit(prepared)
  Assert.equal(repeatReceipt.outcomeId, receipt.outcomeId, "a repeated commit reuses the receipt")
end

function T.failing_roamer_writeback_leaves_staged_owners_alone()
  local party = newPartyOwner()
  local partyRevision = party:partyRevision()
  local update = party:partyMon(0)
  update.heldItem = "SITRUS_BERRY"
  local partyPrep = assert(party:preparePartyChanges(partyRevision, { { slot = 0, mon = update } }))
  local Fixture = require("libs.hgss.tests.encounter_fixture")
  local HgssRoamerState = require("libs.hgss.src.encounters.HgssRoamerState")
  local refs = Fixture.refs()
  local state = HgssRoamerState.new({
    records = { Fixture.roamerRecord(Fixture.roamerMon(), 11, "roaming", 0) },
    species = refs.species,
    maps = refs.maps,
  })
  local Committer = requirePresent(COMMITTER_MODULE, "cross-owner result publication")
  local prepared = Committer.prepare({
    outcome = { id = "outcome-roamer-stale-rejected", result = "flee" },
    party = partyPrep,
    roamer = { owner = state, key = "roamer-eevee", outcome = "fled", expectedRevision = 4, details = { location = 12 } },
  })
  local ok, err = pcall(Committer.commit, prepared)
  Assert.isFalse(ok, "a stale roamer delta never commits: " .. tostring(err))
  Assert.equal(party:partyMon(0).heldItem, "NONE", "the staged party update never lands")
  Assert.equal(party:partyRevision(), partyRevision, "the party publishes nothing")
  Assert.isNil(Committer.receipt("outcome-roamer-stale-rejected"), "a failed commit records no receipt")
end

return { tests = T }
