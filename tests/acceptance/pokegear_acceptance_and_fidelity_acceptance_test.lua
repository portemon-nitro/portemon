-- Final acceptance for the pocket gear: the opening gate holds across
-- player and clock variants, backtrack and permitted save roundtrips
-- preserve the played frontier, repeated gear lifecycles keep bounded
-- host effects, and warm prepared assets serve repeated opens without
-- rebuilding. Every scenario boots the real field runtime over real
-- maps, scripts, and state owners through the composed production
-- entrypoints; only host audio, host input snapshots, the wall clock,
-- and the save root are recording boundaries. No ROM bytes are read here
-- and no gear implementation is faked.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local CacheFs = require("libs.storage.src.CacheFs")
local PokegearCache = require("libs.assets.src.PokegearCache")
local LocalClock = require("game.src.LocalClock")
local Fixture = require("tests.support.PokegearJourneyFixture")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = Fixture.JOURNEY_ASSETS,
    tags = { "pokegear" },
  },
  tests = {},
}

-- The opening gate holds across player and clock variants: morning and
-- night samples for both player genders each complete the house Mom
-- scene through its source script, grant the early progression flags,
-- and release the field with the gear still honestly absent.
function T.tests.opening_gate_holds_across_player_and_clock_variants()
  local variants = {
    {
      profile = { name = "GOLD", gender = 0 },
      clock = { year = 2000, month = 1, day = 1, hour = 9, minute = 0, second = 0 },
    },
    {
      profile = { name = "LYRA", gender = 1 },
      clock = { year = 2000, month = 1, day = 1, hour = 21, minute = 0, second = 0 },
    },
  }
  for _, variant in ipairs(variants) do
    local label = variant.profile.name .. " at hour " .. variant.clock.hour
    local game = Fixture.bootVariant({ map = Fixture.TOWN, profile = variant.profile, clock = variant.clock })
    local ok, err = xpcall(function()
      Fixture.compositionGates(game)
      local world = assert(game.runtime.scripts and game.runtime.scripts.worldState, label .. " needs live world state")
      Assert.isFalse(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_POKEGEAR), label .. " starts without the gear")
      game:moveTo(Fixture.TOWN_HOUSE_DOOR_APPROACH)
      game:step({ direction = "north" })
      local transition = game:waitForTransition()
      Assert.equal(transition.destination.mapSymbol, Fixture.HOUSE_1F, label .. " must reach the house interior")
      OpeningLifecycle.completeOpeningHouseScene(game)
      for _, flag in ipairs(OpeningLifecycle.MOM_GRANTED_FLAGS) do
        Assert.isTrue(world:isFlagSet(flag), label .. " must grant its early progression flags")
      end
      Assert.isTrue(Fixture.settleField(game), label .. " must release the field")
      Assert.isFalse(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_POKEGEAR), label .. " must not invent the gear")
      Assert.equal(Fixture.scriptFaults(game), 0, label .. " must run without script faults")
      Assert.equal(game:renderAttempts(), 0, label .. " must stop before GPU rendering")
    end, debug.traceback)
    game:close()
    if not ok then
      error(label .. ": " .. tostring(err), 0)
    end
  end
end

-- Backtrack and permitted save roundtrips preserve the played frontier:
-- leaving the house for town keeps every granted flag with the gear
-- still absent, and a production save in town reloads the same facts on
-- the same map with an owned field.
function T.tests.backtrack_and_permitted_save_roundtrips_preserve_the_frontier()
  Fixture.withGame(Fixture.TOWN, function(game)
    Fixture.compositionGates(game)
    local world =
      assert(game.runtime.scripts and game.runtime.scripts.worldState, "the backtrack needs live world state")
    game:moveTo(Fixture.TOWN_HOUSE_DOOR_APPROACH)
    game:step({ direction = "north" })
    local entered = game:waitForTransition()
    Assert.equal(entered.destination.mapSymbol, Fixture.HOUSE_1F, "the approach must reach the house interior")
    OpeningLifecycle.completeOpeningHouseScene(game)
    Assert.isTrue(Fixture.settleField(game), "the Mom scene must release the field")
    Fixture.takeWarpTo(game, Fixture.TOWN)
    Assert.equal(game:snapshot().mapSymbol, Fixture.TOWN, "the backtrack must return to town")
    for _, flag in ipairs(OpeningLifecycle.MOM_GRANTED_FLAGS) do
      Assert.isTrue(world:isFlagSet(flag), "the backtrack must keep the granted progression flags")
    end
    Assert.isFalse(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_POKEGEAR), "the backtrack must not invent the gear")
    Fixture.saveAndReload(game)
    world = assert(game.runtime.scripts.worldState, "the reloaded backtrack needs live world state")
    for _, flag in ipairs(OpeningLifecycle.MOM_GRANTED_FLAGS) do
      Assert.isTrue(world:isFlagSet(flag), "reload must retain the granted progression flags")
    end
    Assert.isFalse(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_POKEGEAR), "reload must not invent the gear")
    Assert.equal(game:snapshot().mapSymbol, Fixture.TOWN, "reload must resume in town")
    Assert.equal(Fixture.scriptFaults(game), 0, "the backtrack must run without script faults")
    Assert.isTrue(Fixture.settleField(game), "the backtrack must rest on an owned field")
  end)
end

-- Repeated gear lifecycles keep bounded host effects: five open, tick,
-- and close cycles publish no save, attempt no draw call, fault no
-- script, and strand no owner, while a second boot owns a distinct save
-- namespace so separate roots never collide.
function T.tests.repeated_gear_lifecycles_keep_bounded_host_effects()
  Fixture.withGame(Fixture.POKECENTER, function(game)
    Fixture.compositionGates(game)
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    local gearState = assert(game.runtime.pokegearState, "the lifecycle bound needs live gear state")
    local revisionBefore = gearState:revision()
    local writesBefore = game.lifecycle.saveWrites
    for _ = 1, 5 do
      Fixture.openGearThroughMenu(game)
      for _ = 1, 10 do
        game:step()
      end
      Fixture.closeGearThroughMenu(game)
    end
    Assert.equal(game.lifecycle.saveWrites, writesBefore, "viewing cycles must publish no save")
    Assert.equal(game:renderAttempts(), 0, "viewing cycles must stop before GPU rendering")
    Assert.equal(gearState:revision(), revisionBefore, "viewing cycles must commit no durable fact")
    Assert.equal(Fixture.scriptFaults(game), 0, "the cycles must run without script faults")
    local firstNamespace = game.saveNamespace
    local second = AcceptanceHarness.new():boot({
      versionId = AcceptanceHarness.defaultVersion(),
      map = Fixture.POKECENTER,
      save = "fresh",
    })
    local ok, err = xpcall(function()
      Assert.isTrue(second.saveNamespace ~= firstNamespace, "separate boots must own distinct save namespaces")
    end, debug.traceback)
    second:close()
    if not ok then
      error(err, 0)
    end
    Assert.isTrue(Fixture.settleField(game), "the cycles must rest on an owned field")
  end)
end

-- Warm prepared assets serve repeated opens without rebuilding: the
-- compiled family manifest loads identically before and after gear
-- lifecycles, carrying all twelve broadcast programs with no
-- main-thread source parsing behind the warm read.
function T.tests.warm_prepared_assets_serve_repeated_opens_without_rebuilding()
  Fixture.withGame(Fixture.POKECENTER, function(game)
    Fixture.compositionGates(game)
    local cache = CacheFs.forVersion(AcceptanceHarness.defaultVersion())
    local manifestBefore = PokegearCache.loadManifest(cache)
    local catalogBefore = assert(manifestBefore.catalog, "the prepared family must publish its catalog")
    Assert.equal(#catalogBefore.shows, 12, "the warm catalog carries all twelve broadcast programs")
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    Fixture.openGearThroughMenu(game)
    for _ = 1, 10 do
      game:step()
    end
    Fixture.closeGearThroughMenu(game)
    local manifestAfter = PokegearCache.loadManifest(cache)
    Assert.deepEqual(
      manifestAfter.catalog.shows,
      catalogBefore.shows,
      "repeated opens must reuse the prepared programs without rebuilding"
    )
    Assert.deepEqual(
      manifestAfter.catalog.locations,
      catalogBefore.locations,
      "repeated opens must reuse the prepared places"
    )
    Assert.equal(Fixture.scriptFaults(game), 0, "the warm leg must run without script faults")
    Assert.isTrue(Fixture.settleField(game), "the warm leg must rest on an owned field")
  end)
end

-- A fresh owner counts every live minute after its baseline sample. The
-- same persisted calendar suppresses only the offline jump after reload,
-- while daily identity still catches up and the next ten live minutes
-- remain eligible. The calls travel through the real field runtime and
-- the save travels through the production menu and save store.
function T.tests.incoming_call_cooldown_starts_at_first_live_minute()
  local sample = { year = 2024, month = 1, day = 8, hour = 10, minute = 0, second = 0 }
  local clock = LocalClock.new(function()
    return {
      year = sample.year,
      month = sample.month,
      day = sample.day,
      hour = sample.hour,
      minute = sample.minute,
      second = sample.second,
    }
  end)
  Fixture.withGame(Fixture.TOWN, function(game)
    Fixture.compositionGates(game)
    Fixture.playOpeningToLabFrontier(game)
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })

    local gearState = assert(game.runtime.pokegearState, "incoming call journey needs the production gear state")
    local catalog = assert(game.runtime.pokegearCatalog, "incoming call journey needs the compiled source catalog")
    for _, contact in ipairs(catalog.contacts) do
      gearState:registerContact(contact.key)
    end
    for _, trigger in ipairs(catalog.callTriggers) do
      gearState:setTrigger(trigger.key, true)
    end

    Assert.isTrue(Fixture.settleField(game), "the fresh call journey must settle in the real field")
    game:step()
    local calls = assert(game.runtime.incomingCalls, "the production field must own incoming calls")
    sample.minute = 9
    game:step()
    Assert.isFalse(calls:notification(), "a fresh owner is not eligible before ten live minutes")
    sample.minute = 10
    game:step()
    game:step()
    Assert.isTrue(calls:notification(), "a fresh owner is eligible at ten continuous live minutes")

    local savedDay = gearState:readCalendar().daySerial
    sample = { year = 2024, month = 1, day = 11, hour = 10, minute = 10, second = 0 }
    Fixture.saveAndReload(game)

    calls = assert(game.runtime.incomingCalls, "the reloaded field must own a fresh incoming-call lifetime")
    local reloadedState = assert(game.runtime.pokegearState, "reload must restore the production gear state")
    Assert.isTrue(
      reloadedState:readCalendar().daySerial > savedDay,
      "the restored calendar advances its daily identity across the offline jump"
    )
    Assert.isFalse(calls:notification(), "the restored owner does not count the offline jump as eligibility")

    sample.minute = 19
    game:step()
    Assert.isFalse(calls:notification(), "the restored owner waits through nine live minutes")
    sample.minute = 20
    game:step()
    game:step()
    Assert.isTrue(calls:notification(), "the restored owner is eligible after ten live minutes")
    Assert.equal(Fixture.scriptFaults(game), 0, "the incoming-call journey runs without script faults")
  end, { localClock = clock })
end

return T
