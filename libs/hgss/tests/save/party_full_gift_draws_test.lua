-- Full-party gift ordering: creation consumes its generator draws even
-- when the party has no room, the result is false, and nothing is
-- published anywhere.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

local SERVICE_MODULE = "libs.hgss.src.mons.HgssMonService"

local function requireService()
  local ok, service = pcall(require, SERVICE_MODULE)
  Assert.isTrue(ok, "the HGSS mon service owns script-gift creation and party insertion")
  return assert(service)
end

local function openService(catalog, seed)
  local HgssMonService = requireService()
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
end

local function gift(service, species)
  return service:giveMon({
    species = species,
    level = 5,
    heldItem = "NONE",
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  })
end

function T.full_party_reports_false_without_changing_state_or_branching()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x44444444)
  for _ = 1, Party.MAX do
    Assert.isTrue(gift(service, "CHIKORITA"), "setup gifts fill the party")
  end
  Assert.equal(service:partyCount(), 6, "the party holds six mons")
  local revisionBefore = service:partyRevision()
  local rngBefore = service:capture().rng
  local partyBefore = {}
  for slot = 0, 5 do
    partyBefore[slot] = service:partyMon(slot)
  end

  Assert.isFalse(gift(service, "TOTODILE"), "the seventh gift reports the source failure result")
  Assert.equal(service:partyCount(), 6, "a full party never overflows into storage")
  Assert.equal(service:partyRevision(), revisionBefore, "the discarded gift bumps no revision")
  for slot = 0, 5 do
    Assert.deepEqual(service:partyMon(slot), partyBefore[slot], "the published party is unchanged")
  end
  Assert.isTrue(service:capture().rng.calls > rngBefore.calls, "creation draws precede the insertion result")
end

-- Script-gift eggs check capacity before anything else: a full party
-- reports false without consuming generator draws, without calling the
-- date provider, and without touching the party, boxes, or revisions.
-- Ordinary gift ordering above stays unchanged.
function T.full_party_egg_reports_false_before_any_draw_or_date_lookup()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x44444444)
  for _ = 1, Party.MAX do
    Assert.isTrue(gift(service, "CHIKORITA"), "setup gifts fill the party")
  end
  local rngBefore = service:capture().rng
  local revisionBefore = service:partyRevision()
  local dateCalls = 0
  local refused = service:giveEgg({
    species = "PICHU",
    locationOffset = 14,
    date = function()
      dateCalls = dateCalls + 1
      return CatalogFixture.metDate()
    end,
  })
  Assert.isFalse(refused, "the full party refuses the egg before creation")
  Assert.equal(dateCalls, 0, "a full party never reaches the date provider")
  Assert.deepEqual(service:capture().rng, rngBefore, "a full party consumes no generator draws")
  Assert.equal(service:partyCount(), 6, "a full party never overflows into storage")
  Assert.equal(service:partyRevision(), revisionBefore, "the refused egg bumps no revision")
end

-- A free slot creates exactly one cleared gift egg through four
-- generator draws: the biological species stays on the record while the
-- receipt location narrows the gift offset and the meeting record is
-- cleared.
function T.free_slot_egg_creates_exactly_one_cleared_egg_with_four_draws()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local accepted = service:giveEgg({
    species = "PICHU",
    locationOffset = 14,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(accepted, "a free slot accepts the gift egg")
  Assert.equal(service:partyCount(), 1, "the gift appends exactly one party mon")
  local mon = service:partyMon(0)
  Assert.isTrue(mon.isEgg, "the gift stays an egg")
  Assert.equal(mon.species, "PICHU", "the biological species stays on the record")
  Assert.isNil(mon.nickname, "the gift sets no custom nickname")
  Assert.deepEqual(mon.egg, { location = 2014, date = CatalogFixture.metDate() })
  Assert.deepEqual(mon.met, { location = 0, level = 0, terrain = 0 })
  Assert.equal(mon.personality, 0x84EA0B71, "the gift draws the exact creation stream")
  local rng = service:capture().rng
  Assert.equal(rng.calls, 4, "the gift consumes exactly four generator draws")
  Assert.equal(rng.state, 0xF4E023DC, "the gift leaves the exact generator state")
end

return { tests = T }
