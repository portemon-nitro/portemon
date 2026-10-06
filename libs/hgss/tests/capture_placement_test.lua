-- Capture placement: a caught mon joins the party exactly once when a
-- slot is free, and every successful capture in the batch must fit. With
-- no storage behind a full party, a batch that exceeds live capacity
-- fails during preparation before any owner publishes: nothing is
-- stored anywhere, no fitting prefix commits, and no receipt exists.

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
---@return table the loaded placement owner
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing capture placement owner: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the capture placement module loads")
  return loaded --[[@as table]]
end

---@param count integer mons to deal into the party
---@return HgssMonService party owner with a fixed roster
local function newPartyOwner(count)
  local catalog = CatalogFixture.makeCatalog()
  local owner = HgssMonService.new({
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
  local species = { "CHIKORITA", "TOTODILE", "EEVEE", "CHIKORITA", "TOTODILE", "EEVEE" }
  local factory = CatalogFixture.makeFactory(0x55555555, catalog)
  for index = 1, count do
    Assert.isTrue(
      owner:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = species[index] }))),
      "the fixed roster deals mon " .. tostring(index)
    )
  end
  return owner
end

---@param species string
---@param seed integer
---@return table<string, unknown> a fixed caught mon record of the requested species
local function caughtMonOf(species, seed)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  return factory:createNormal(CatalogFixture.normalRequest({ species = species, level = 5 }))
end

---@return table<string, unknown> a fixed caught mon record
local function caughtMon()
  return caughtMonOf("EEVEE", 0x66666666)
end

---@return HgssBagService bag owner holding a fixed ball stock
local function newBagOwner()
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  Assert.isTrue(bag:add("POKE_BALL", 5))
  return bag
end

local T = {}

function T.capture_with_room_appends_the_caught_mon_exactly_once()
  local party = newPartyOwner(5)
  Assert.equal(party:partyCount(), 5, "the room case starts with five mons")

  local Committer = requirePresent(COMMITTER_MODULE, "capture commit into a free slot")
  local capture = { captureId = 2, ball = "POKE_BALL", success = true, mon = caughtMon() }
  local prepared = Committer.prepare({
    outcome = { id = "outcome-room-capture", result = "capture" },
    partyOwner = party,
    captures = { capture },
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the room capture commits")
  Assert.equal(#receipt.placements, 1, "the room capture yields exactly one placement")
  Assert.isTrue(receipt.placements[1].retained, "the room capture retains the mon")
  Assert.equal(receipt.placements[1].destination, "party", "the room capture lands in the party")
  Assert.equal(receipt.placements[1].partySlot, 5, "the room capture takes the first free slot")
  Assert.equal(party:partyCount(), 6, "the caught mon appends exactly once")

  local repeatReceipt = Committer.commit(prepared)
  Assert.equal(repeatReceipt.outcomeId, receipt.outcomeId, "a repeated capture reuses the recorded receipt")
  Assert.equal(party:partyCount(), 6, "a repeated capture never appends a duplicate")
end

function T.explicit_caught_record_appends_its_exact_identity()
  local party = newPartyOwner(5)
  local caught = caughtMon()
  local Committer = requirePresent(COMMITTER_MODULE, "capture commit into a free slot")
  local prepared = Committer.prepare({
    outcome = { id = "outcome-explicit-record", result = "capture" },
    partyOwner = party,
    captures = { { captureId = 7, ball = "POKE_BALL", success = true, mon = caught } },
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the explicit capture commits")
  Assert.equal(#receipt.placements, 1, "the explicit capture yields exactly one placement")
  local placement = receipt.placements[1]
  Assert.isTrue(placement.retained, "the explicit capture retains the mon")
  Assert.equal(placement.destination, "party", "the explicit capture lands in the party")
  Assert.equal(placement.partySlot, 5, "the explicit capture takes the first free slot")
  Assert.equal(placement.captureId, 7, "the placement echoes its capture")
  local stored = party:partyMon(5)
  Assert.equal(stored.species, caught.species, "the appended mon keeps its species")
  Assert.equal(stored.personality, caught.personality, "the appended mon keeps its identity")
end

function T.failed_throw_yields_no_placement_but_still_commits()
  local party = newPartyOwner(5)
  local Committer = requirePresent(COMMITTER_MODULE, "capture commit into a free slot")
  local prepared = Committer.prepare({
    outcome = { id = "outcome-failed-throw", result = "flee" },
    partyOwner = party,
    captures = { { captureId = 8, species = "EEVEE", ball = "POKE_BALL", success = false } },
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "a failed throw still commits its battle consequences")
  Assert.equal(#receipt.placements, 0, "a failed throw places nothing")
  Assert.equal(party:partyCount(), 5, "a failed throw appends nothing")
end

-- A successful capture with nowhere to retain the mon never stages: the
-- preparation fails before any owner publishes, every staged candidate
-- stays unpublished, and no receipt exists. There is no storage behind
-- a full party, so not even a fitting prefix may commit.
function T.full_party_capture_fails_before_any_publication()
  local party = newPartyOwner(6)
  local bag = newBagOwner()
  local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
  local dex = PokedexKnowledge.new({ species = { CHIKORITA = true, TOTODILE = true, EEVEE = true } })
  local PlayerData = require("libs.hgss.src.save.PlayerData")
  assert(PlayerData ~= nil, "the money candidate stages through the player owner")
  local record = {
    profile = { name = "RED", gender = 0, trainerId = 1, money = 3000, badges = 3 },
    options = { textFrame = 0, textSpeed = "fastest" },
  }
  local context = { charmap = CatalogFixture.CHARMAP, frameIndexes = { [0] = true } }
  Assert.equal(party:partyCount(), 6, "the refused case starts with a full party")
  local before = {}
  for slot = 0, 5 do
    before[slot] = party:partyMon(slot)
  end
  local partyRevision = party:partyRevision()
  local bagRevision = bag:revision()
  local bagPrep =
    assert(bag:prepareInventoryChanges(bagRevision, { { op = "take", item = "POKE_BALL", quantity = 1 } }))
  local dexPrep = dex:capture("EEVEE")

  local Committer = requirePresent(COMMITTER_MODULE, "capture commit without hidden storage")
  local ok, err = pcall(Committer.prepare, {
    outcome = { id = "outcome-full-party-refused", result = "capture" },
    partyOwner = party,
    bag = bagPrep,
    dex = dexPrep,
    captures = { { captureId = 51, ball = "POKE_BALL", success = true, mon = caughtMon() } },
    player = { record = record, context = context, moneyDelta = -40 },
  })
  Assert.isFalse(ok, "a capture without retention never stages: " .. tostring(err))
  Assert.equal(party:partyCount(), 6, "the refused batch appends nothing")
  for slot = 0, 5 do
    Assert.deepEqual(party:partyMon(slot), before[slot], "slot " .. tostring(slot) .. " stays untouched")
  end
  Assert.equal(party:partyRevision(), partyRevision, "the refused batch moves no party revision")
  Assert.equal(bag:quantity("POKE_BALL"), 5, "the refused batch consumes no ball")
  Assert.equal(bag:revision(), bagRevision, "the refused batch moves no bag revision")
  Assert.isFalse(dex:isCaught("EEVEE"), "the refused batch registers no caught knowledge")
  Assert.isNil(Committer.receipt("outcome-full-party-refused"), "a refused batch records no receipt")
end

-- Scarce capacity rejects the whole capture batch: with five mons and two
-- successes nothing stages, while an exactly-fitting batch still commits
-- in capture order with exact identities and idempotent replay.
function T.scarce_party_rejects_the_batch_while_fitting_capture_commits()
  local Committer = requirePresent(COMMITTER_MODULE, "capture commit without hidden storage")
  local crowded = newPartyOwner(5)
  local ok, err = pcall(Committer.prepare, {
    outcome = { id = "outcome-scarce-refused", result = "capture" },
    partyOwner = crowded,
    captures = {
      { captureId = 61, ball = "POKE_BALL", success = true, mon = caughtMonOf("TOTODILE", 0x77777777) },
      { captureId = 62, ball = "POKE_BALL", success = true, mon = caughtMonOf("CHIKORITA", 0x88888888) },
    },
  })
  Assert.isFalse(ok, "a batch without room for every capture never stages: " .. tostring(err))
  Assert.equal(crowded:partyCount(), 5, "a refused batch appends no fitting prefix")
  Assert.isNil(Committer.receipt("outcome-scarce-refused"), "a refused batch records no receipt")

  local roomy = newPartyOwner(5)
  local solo = caughtMon()
  local prepared = Committer.prepare({
    outcome = { id = "outcome-scarce-fitting", result = "capture" },
    partyOwner = roomy,
    captures = { { captureId = 63, ball = "POKE_BALL", success = true, mon = solo } },
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the fitting capture commits")
  Assert.equal(#receipt.placements, 1, "the fitting capture yields exactly one placement")
  Assert.isTrue(receipt.placements[1].retained, "the fitting capture retains the mon")
  Assert.equal(receipt.placements[1].destination, "party", "the fitting capture lands in the party")
  Assert.equal(receipt.placements[1].partySlot, 5, "the fitting capture takes the first free slot")
  Assert.deepEqual(roomy:partyMon(5), solo, "the fitting capture keeps its exact caught identity")
  local repeatReceipt = Committer.commit(prepared)
  Assert.equal(repeatReceipt.outcomeId, receipt.outcomeId, "a repeated capture reuses the recorded receipt")
  Assert.equal(roomy:partyCount(), 6, "a repeated capture never appends a duplicate")

  local ordered = newPartyOwner(4)
  local first = caughtMonOf("TOTODILE", 0x99999991)
  local second = caughtMonOf("CHIKORITA", 0x99999992)
  local orderedPrep = Committer.prepare({
    outcome = { id = "outcome-ordered-fitting", result = "capture" },
    partyOwner = ordered,
    captures = {
      { captureId = 64, ball = "POKE_BALL", success = true, mon = first },
      { captureId = 65, ball = "POKE_BALL", success = true, mon = second },
    },
  })
  local orderedReceipt = Committer.commit(orderedPrep)
  Assert.isTrue(orderedReceipt.committed, "the ordered batch commits")
  Assert.equal(#orderedReceipt.placements, 2, "each fitting capture reports its placement")
  Assert.equal(orderedReceipt.placements[1].captureId, 64, "placements follow capture order")
  Assert.equal(orderedReceipt.placements[2].captureId, 65, "placements follow capture order")
  Assert.equal(orderedReceipt.placements[1].partySlot, 4, "the first capture takes the first free slot")
  Assert.equal(orderedReceipt.placements[2].partySlot, 5, "the second capture takes the next slot")
  Assert.deepEqual(ordered:partyMon(4), first, "the first slot keeps the first caught identity")
  Assert.deepEqual(ordered:partyMon(5), second, "the second slot keeps the second caught identity")
end

function T.unknown_species_never_reaches_publication()
  local party = newPartyOwner(5)
  local Committer = requirePresent(COMMITTER_MODULE, "capture commit into a free slot")
  local bogus = caughtMon()
  bogus.species = "MISSINGNO"
  local ok, err = pcall(Committer.prepare, {
    outcome = { id = "outcome-unknown-species", result = "capture" },
    partyOwner = party,
    captures = { { captureId = 10, ball = "POKE_BALL", success = true, mon = bogus } },
  })
  Assert.isFalse(ok, "an unknown species never stages: " .. tostring(err))
  Assert.equal(party:partyCount(), 5, "a rejected capture appends nothing")
  Assert.isNil(Committer.receipt("outcome-unknown-species"), "a rejected capture records no receipt")
end

function T.successful_capture_without_a_caught_record_is_rejected_before_publication()
  local party = newPartyOwner(5)
  local Committer = requirePresent(COMMITTER_MODULE, "capture commit into a free slot")
  local ok, err = pcall(Committer.prepare, {
    outcome = { id = "outcome-bare-species-rejected", result = "capture" },
    partyOwner = party,
    captures = { { captureId = 31, species = "EEVEE", ball = "POKE_BALL", success = true } },
  })
  Assert.isFalse(ok, "a species-only success never stages: " .. tostring(err))
  Assert.equal(party:partyCount(), 5, "a rejected capture appends nothing")
  Assert.isNil(Committer.receipt("outcome-bare-species-rejected"), "a rejected capture records no receipt")
end

function T.retained_capture_keeps_the_exact_caught_record()
  local party = newPartyOwner(5)
  local caught = caughtMon()
  local Committer = requirePresent(COMMITTER_MODULE, "capture commit into a free slot")
  local prepared = Committer.prepare({
    outcome = { id = "outcome-exact-record-kept", result = "capture" },
    partyOwner = party,
    captures = { { captureId = 33, ball = "POKE_BALL", success = true, mon = caught } },
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the exact capture commits")
  Assert.equal(#receipt.placements, 1, "the exact capture yields exactly one placement")
  local placement = receipt.placements[1]
  Assert.isTrue(placement.retained, "the exact capture retains the mon")
  Assert.equal(placement.destination, "party", "the exact capture lands in the party")
  Assert.equal(placement.partySlot, 5, "the exact capture takes the first free slot")
  Assert.equal(placement.captureId, 33, "the placement echoes its capture")
  Assert.deepEqual(party:partyMon(5), caught, "the appended mon keeps its exact caught identity")
end

return { tests = T }
