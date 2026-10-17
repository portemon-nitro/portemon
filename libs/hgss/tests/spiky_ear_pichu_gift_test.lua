-- Spiky-Ear Pichu gift ordering: unlike the ordinary script gift (whose
-- creation draws precede its insertion result), the source refuses a full
-- party before creating anything, so no generator draws run and nothing
-- is published anywhere. A roomy party receives the event distribution.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local Personality = require("libs.mons.src.gen4.Personality")

local T = {}

local SERVICE_MODULE = "libs.hgss.src.mons.HgssMonService"

local function openService(catalog, seed, extra)
  local HgssMonService = assert(require(SERVICE_MODULE))
  local opts = {
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
  }
  for key, value in pairs(extra or {}) do
    opts[key] = value
  end
  return HgssMonService.new(opts)
end

local function context()
  return { location = 7, date = CatalogFixture.metDate() }
end

function T.full_party_reports_false_without_consuming_draws_or_changing_state()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x77777777)
  for _ = 1, Party.MAX do
    Assert.isTrue(service:giveMon({
      species = "CHIKORITA",
      level = 5,
      heldItem = "NONE",
      form = 0,
      location = 7,
      date = CatalogFixture.metDate(),
    }), "setup gifts fill the party")
  end
  Assert.equal(service:partyCount(), 6, "the party holds six mons")
  local revisionBefore = service:partyRevision()
  local rngBefore = service:capture().rng
  local partyBefore = {}
  for slot = 0, 5 do
    partyBefore[slot] = service:partyMon(slot)
  end

  Assert.isFalse(service:giveSpikyEarPichu(context()), "the seventh gift reports the source refusal")
  Assert.equal(service:partyCount(), 6, "a full party never overflows into storage")
  Assert.equal(service:partyRevision(), revisionBefore, "the refused gift bumps no revision")
  for slot = 0, 5 do
    Assert.deepEqual(service:partyMon(slot), partyBefore[slot], "the published party is unchanged")
  end
  Assert.deepEqual(service:capture().rng, rngBefore, "the refusal consumes no generator draws")
end

function T.roomy_party_receives_the_event_distribution()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x5151ED)
  Assert.isTrue(service:giveSpikyEarPichu(context()), "the gift publishes into the roomy party")
  Assert.equal(service:partyCount(), 1, "exactly the gift is published")
  local mon = service:partyMon(0)
  Assert.equal(mon.species, "PICHU")
  Assert.equal(mon.form, 1)
  Assert.equal(mon.ability, "STATIC")
  Assert.equal(mon.heldItem, "ZAP_PLATE")
  Assert.equal(Personality.nature(mon.personality), 4)
  Assert.equal(Personality.gender(127, mon.personality), "female")
end

function T.bare_call_uses_the_configured_meeting_point()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x5151ED, { mapSection = 9, date = CatalogFixture.metDate() })
  Assert.isTrue(service:giveSpikyEarPichu(), "the script-shaped bare call publishes")
  local mon = service:partyMon(0)
  Assert.equal(mon.species, "PICHU")
  Assert.equal(mon.met.location, 9, "the configured map section owns the meeting point")
end

return { tests = T }
