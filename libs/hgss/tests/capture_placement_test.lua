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

---@return table<string, unknown> a fixed caught mon record
local function caughtMon()
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0x66666666, catalog)
  return factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", level = 5 }))
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
  local capture = { captureId = 1, species = "EEVEE", ball = "POKE_BALL", success = true }
  local prepared = Committer.prepare({ outcome = { id = "outcome-full-party", result = "capture" }, captures = { capture } })
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
  local capture = { captureId = 2, species = "EEVEE", ball = "POKE_BALL", success = true }
  local prepared = Committer.prepare({ outcome = { id = "outcome-room-capture", result = "capture" }, captures = { capture } })
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
    captures = { { captureId = 9, species = "EEVEE", ball = "POKE_BALL", success = true } },
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
  local ok, err = pcall(Committer.prepare, {
    outcome = { id = "outcome-unknown-species", result = "capture" },
    partyOwner = party,
    captures = { { captureId = 10, species = "MISSINGNO", ball = "POKE_BALL", success = true } },
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

return { tests = T }
