-- Party staged replacement: same-size candidate construction without
-- mutating the live aggregate. Unique existing slots only; the revision
-- advances once for a non-empty update set and stays put otherwise.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Party = require("libs.mons.src.Party")

local function twoMonParty()
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0xAAAAAAAA, catalog)
  local party = Party.new()
  for _, species in ipairs({ "CHIKORITA", "EEVEE" }) do
    Assert.isTrue(party:add(factory:createNormal(CatalogFixture.normalRequest({ species = species }))))
  end
  return party
end

local T = {}

function T.with_updates_replaces_listed_slots_and_bumps_once()
  local party = twoMonParty()
  local revision = party:revision()
  local replacement = party:get(1)
  replacement.heldItem = "SITRUS_BERRY"
  local candidate = party:withUpdates({ { slot = 1, mon = replacement } })
  Assert.equal(candidate:get(1).heldItem, "SITRUS_BERRY")
  Assert.equal(candidate:get(0).species, party:get(0).species, "unlisted slots carry over")
  Assert.equal(candidate:revision(), revision + 1)
  Assert.equal(party:revision(), revision, "the live party keeps its revision")
  Assert.equal(party:get(1).heldItem, "NONE", "the live party keeps its record")
end

function T.with_updates_rejects_bad_and_duplicate_slots()
  local party = twoMonParty()
  local revision = party:revision()
  Assert.throws(function()
    party:withUpdates({ { slot = 2, mon = party:get(0) } })
  end, "a missing slot cannot be staged")
  Assert.throws(function()
    party:withUpdates({ { slot = -1, mon = party:get(0) } })
  end, "a negative slot cannot be staged")
  Assert.throws(function()
    party:withUpdates({ { slot = 0, mon = party:get(0) }, { slot = 0, mon = party:get(1) } })
  end, "a duplicated slot cannot be staged")
  Assert.equal(party:revision(), revision, "a rejected staging publishes nothing")
end

function T.with_updates_isolates_copies_and_preserves_empty_revision()
  local party = twoMonParty()
  local revision = party:revision()
  local staged = party:get(0)
  local candidate = party:withUpdates({ { slot = 0, mon = staged } })
  staged.heldItem = "SITRUS_BERRY"
  Assert.equal(candidate:get(0).heldItem, "NONE", "later caller edits never leak into the candidate")
  local same = party:withUpdates({})
  Assert.equal(same:revision(), revision, "an empty update set preserves the revision")
  Assert.equal(same:count(), party:count())
end

return { tests = T }
