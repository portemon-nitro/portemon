-- Capture placement: a caught mon joins the party exactly once when a
-- slot is free. With a full party the send-to-party fallback stays an
-- explicit unimplemented handoff: the ball stays consumed, the capture
-- stays registered, nothing is stored anywhere, and the placement says so.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local STUB_MODULE = "libs.hgss.src.battle.HgssSendToPcStub"
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
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x44444444):capture(), catalog:fingerprint()),
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

function T.full_party_capture_reports_the_explicit_unplaced_handoff()
  local party = newPartyOwner(6)
  local bag = newBagOwner()
  Assert.equal(party:partyCount(), 6, "the full-party case starts with six mons")
  local before = {}
  for slot = 0, 5 do
    before[slot] = party:partyMon(slot)
  end

  local Stub = requirePresent(STUB_MODULE, "explicit unimplemented party-overflow handoff")
  Assert.isTrue(type(Stub.send) == "function", "the handoff exposes one explicit send operation")
  local placement = Stub.send(caughtMon(), { partyCount = party:partyCount() })
  Assert.isFalse(placement.retained, "the full-party capture retains nothing")
  Assert.equal(placement.destination, "pc", "the placement names the unimplemented destination")
  Assert.equal(placement.reason, "pc_unimplemented", "the placement names the limitation honestly")
  Assert.equal(party:partyCount(), 6, "the full-party roster gains no seventh mon")
  for slot = 0, 5 do
    Assert.deepEqual(party:partyMon(slot), before[slot], "slot " .. tostring(slot) .. " stays untouched")
  end

  local Committer = requirePresent(COMMITTER_MODULE, "capture commit without hidden storage")
  local capture = { captureId = 1, ball = "POKE_BALL", success = true, mon = caughtMon() }
  local prepared = Committer.prepare({
    outcome = { id = "outcome-full-party", result = "capture" },
    partyOwner = party,
    captures = { capture },
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the capture still commits its battle consequences")
  Assert.equal(#receipt.placements, 1, "the capture yields exactly one placement")
  Assert.isFalse(receipt.placements[1].retained, "the committed placement retains nothing")
  Assert.equal(receipt.placements[1].reason, "pc_unimplemented", "the committed placement stays honest")
  Assert.equal(party:partyCount(), 6, "the commit stores the overflow mon nowhere")
  Assert.isTrue(bag:has("POKE_BALL", 5), "no hidden storage path consumes extra balls")
end

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

function T.explicit_full_party_owner_stays_an_honest_handoff()
  local party = newPartyOwner(6)
  local Committer = requirePresent(COMMITTER_MODULE, "capture commit without hidden storage")
  local prepared = Committer.prepare({
    outcome = { id = "outcome-explicit-full-party", result = "capture" },
    partyOwner = party,
    captures = { { captureId = 9, ball = "POKE_BALL", success = true, mon = caughtMon() } },
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the full-party capture still commits")
  Assert.equal(#receipt.placements, 1, "the full-party capture yields exactly one placement")
  Assert.isFalse(receipt.placements[1].retained, "the explicit full-party capture retains nothing")
  Assert.equal(receipt.placements[1].destination, "pc", "the placement names the unimplemented destination")
  Assert.equal(receipt.placements[1].reason, "pc_unimplemented", "the placement stays honest")
  Assert.equal(party:partyCount(), 6, "the explicit full-party roster is untouched")
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

function T.stub_stays_pure_across_repeated_handoffs()
  local Stub = requirePresent(STUB_MODULE, "explicit unimplemented party-overflow handoff")
  local first = Stub.send(caughtMon(), { partyCount = 6, captureId = 11 })
  local second = Stub.send(caughtMon(), { partyCount = 6, captureId = 11 })
  Assert.deepEqual(first, second, "the handoff is a pure function of its inputs")
  Assert.isFalse(first.retained, "repeated handoffs retain nothing")
  Assert.equal(first.destination, "pc", "repeated handoffs name the destination")
  Assert.equal(first.reason, "pc_unimplemented", "repeated handoffs name the limitation")
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

function T.full_party_capture_forwards_the_caught_record_and_replays_identically()
  local party = newPartyOwner(6)
  local caught = caughtMon()
  local before = {}
  for slot = 0, 5 do
    before[slot] = party:partyMon(slot)
  end
  local Committer = requirePresent(COMMITTER_MODULE, "capture commit without hidden storage")
  local prepared = Committer.prepare({
    outcome = { id = "outcome-overflow-keeps-record", result = "capture" },
    partyOwner = party,
    captures = { { captureId = 32, ball = "POKE_BALL", success = true, mon = caught } },
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the overflow capture still commits")
  Assert.equal(#receipt.placements, 1, "the overflow capture yields exactly one placement")
  local placement = receipt.placements[1]
  Assert.isFalse(placement.retained, "the overflow capture retains nothing")
  Assert.equal(placement.destination, "pc", "the overflow placement names the unimplemented destination")
  Assert.equal(placement.reason, "pc_unimplemented", "the overflow placement stays honest")
  Assert.equal(placement.captureId, 32, "the placement echoes its capture")
  Assert.equal(party:partyCount(), 6, "the overflow commit stores the mon nowhere")
  for slot = 0, 5 do
    Assert.deepEqual(party:partyMon(slot), before[slot], "slot " .. tostring(slot) .. " stays untouched")
  end
  local repeatReceipt = Committer.commit(prepared)
  Assert.deepEqual(repeatReceipt, receipt, "a replayed overflow commit reuses the recorded receipt")
  Assert.equal(party:partyCount(), 6, "a replayed overflow commit never mutates the party")
end

function T.scarce_slot_goes_to_the_first_capture_in_order()
  local party = newPartyOwner(5)
  local first = caughtMonOf("TOTODILE", 0x77777777)
  local second = caughtMonOf("CHIKORITA", 0x88888888)
  local Committer = requirePresent(COMMITTER_MODULE, "capture commit into a free slot")
  local prepared = Committer.prepare({
    outcome = { id = "outcome-scarce-slot-order", result = "capture" },
    partyOwner = party,
    captures = {
      { captureId = 34, ball = "POKE_BALL", success = true, mon = first },
      { captureId = 35, ball = "POKE_BALL", success = true, mon = second },
    },
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the scarce-slot batch commits")
  Assert.equal(#receipt.placements, 2, "each capture reports its placement in order")
  Assert.isTrue(receipt.placements[1].retained, "the first capture retains the scarce slot")
  Assert.equal(receipt.placements[1].destination, "party", "the first capture lands in the party")
  Assert.equal(receipt.placements[1].partySlot, 5, "the first capture takes the first free slot")
  Assert.equal(receipt.placements[1].captureId, 34, "the first placement echoes its capture")
  Assert.isFalse(receipt.placements[2].retained, "the second capture retains nothing")
  Assert.equal(receipt.placements[2].destination, "pc", "the second capture names the handoff")
  Assert.equal(receipt.placements[2].reason, "pc_unimplemented", "the second placement stays honest")
  Assert.equal(receipt.placements[2].captureId, 35, "the second placement echoes its capture")
  Assert.equal(party:partyCount(), 6, "only the fitting capture appends")
  Assert.deepEqual(party:partyMon(5), first, "the scarce slot keeps the first caught identity")
end

return { tests = T }
