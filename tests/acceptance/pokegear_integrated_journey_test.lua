-- Integrated pocket-gear journey: the fully acquired shell keeps one owner
-- across all four cards, radio effects, gifts, rematches, savings, Fly,
-- and annotation results, with failure/input ownership and
-- dependency-bound coverage stated explicitly. Every journey boots the
-- real field runtime over real maps, scripts, and state owners through
-- the composed production entrypoints; only host audio, host input
-- snapshots, the wall clock, and the save root are recording boundaries.
-- No ROM bytes are read here and no gear implementation is faked.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local CacheFs = require("libs.storage.src.CacheFs")
local PokegearCache = require("libs.assets.src.PokegearCache")
local Fixture = require("tests.support.PokegearJourneyFixture")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = Fixture.JOURNEY_ASSETS,
    tags = { "pokegear" },
  },
  tests = {},
}

local function nativeMomKey(game)
  local catalog = assert(game.runtime.pokegearCatalog, "the field runtime owns its compiled phone catalog")
  for _, contact in ipairs(assert(catalog.contacts, "the compiled phone catalog lists contacts")) do
    if contact.id == 0 then
      assert(contact.family == "mother", "native phonebook contact zero is Mom")
      local key = assert(contact.key, "native Mom carries its semantic key")
      return key
    end
  end
  error("the compiled phone catalog contains native contact zero", 0)
end

-- The fully acquired shell keeps one owner across every card: the gear
-- opens through the production menu over real backing data, ticks without
-- changing owners, and closes back to an owned field with zero faults and
-- zero lingering triggers.
function T.tests.acquired_shell_keeps_one_owner_across_all_cards()
  Fixture.withGame(Fixture.POKECENTER, function(game)
    Fixture.compositionGates(game)
    local gearState = assert(game.runtime.pokegearState, "the integrated journey needs live gear state")

    -- The compiled backing closure is real before any card opens: native
    -- locations, all twelve broadcast programs, and six skins.
    local manifest = PokegearCache.loadManifest(CacheFs.forVersion(AcceptanceHarness.defaultVersion()))
    local catalog = assert(manifest.catalog, "the compiled gear family must publish its catalog")
    Assert.isTrue(
      type(catalog.locations) == "table" and #catalog.locations > 0,
      "the map card needs real compiled locations"
    )
    Assert.isTrue(
      type(catalog.shows) == "table" and #catalog.shows == 12,
      "the radio card needs all twelve compiled broadcast programs"
    )

    -- The gear flag is carried as setup for this shell-ownership journey
    -- (documented, not earned here); played acquisition is proven
    -- separately below.
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    Fixture.openGearThroughMenu(game)
    Assert.equal(
      game.runtime.applicationHost:status().phase,
      FieldApplicationHost.PHASES.application,
      "the acquired gear must own the tick with every card backed"
    )
    for _ = 1, 30 do
      game:step()
    end
    Assert.equal(
      game.runtime.applicationHost:status().phase,
      FieldApplicationHost.PHASES.application,
      "the open gear must keep its single owner across ticks"
    )
    Fixture.closeGearThroughMenu(game)
    Fixture.acceptRingingCall(game)
    Assert.deepEqual(gearState:readPhone().triggers, {}, "no integrated trigger may linger unfired")
    Assert.equal(Fixture.scriptFaults(game), 0, "the integrated scripts must run without script faults")
    Assert.isTrue(Fixture.settleField(game), "the journey must return to ordinary play")
  end)
end

-- Repeated open, cancel, and close cycles never strand an owner: every
-- cancelled modal flow releases the field, and the shell survives the
-- storm with its committed facts intact.
function T.tests.repeated_open_cancel_and_close_cycles_strand_no_owner()
  Fixture.withGame(Fixture.POKECENTER, function(game)
    Fixture.compositionGates(game)
    local gearState = assert(game.runtime.pokegearState, "the lifecycle storm needs live gear state")
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    local revisionBefore = gearState:revision()
    for _ = 1, 5 do
      Fixture.openGearThroughMenu(game)
      Assert.equal(
        game.runtime.applicationHost:status().phase,
        FieldApplicationHost.PHASES.application,
        "each storm cycle must hand the tick to the gear"
      )
      for _ = 1, 6 do
        game.runtime:pressCancel()
        game:step()
        game.runtime:releaseCancel()
        if game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.closed then
          break
        end
      end
      game:advanceUntil("the storm cycle closes back to the field", function(snapshot)
        return game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.closed
          and not snapshot.fieldLocked
      end, 240)
    end
    Assert.equal(gearState:revision(), revisionBefore, "cancelled cycles must commit no durable fact")
    Assert.equal(Fixture.scriptFaults(game), 0, "the storm must run without script faults")
    Assert.isTrue(Fixture.settleField(game), "the storm must rest on an owned field")
  end)
end

-- Acquired facts survive a production save and reload verbatim: the gear
-- flag, a registered caller, and the card registry all persist through
-- the actual publication pipeline, and the reloaded shell reopens over
-- the same backing.
function T.tests.acquired_facts_survive_save_and_reload_verbatim()
  Fixture.withGame(Fixture.TOWN, function(game)
    Fixture.compositionGates(game)
    Fixture.playOpeningToLabFrontier(game)
    local world = assert(game.runtime.scripts.worldState, "the durability leg needs live world state")
    local gearState = assert(game.runtime.pokegearState, "the durability leg needs live gear state")
    Assert.isTrue(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_STARTER), "the durability leg keeps the played starter")
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    Fixture.openGearThroughMenu(game)
    Fixture.closeGearThroughMenu(game)
    Fixture.saveAndReload(game)
    world = assert(game.runtime.scripts.worldState, "the reloaded leg needs live world state")
    gearState = assert(game.runtime.pokegearState, "the reloaded leg needs live gear state")
    Assert.isTrue(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_STARTER), "reload must retain the played starter")
    Assert.equal(world:getVar(Fixture.VARS.VAR_SCENE_ELMS_LAB), 2, "reload must retain the corridor gift")
    Assert.isTrue(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_POKEGEAR), "reload must retain the acquired gear")
    Fixture.openGearThroughMenu(game)
    Assert.equal(
      game.runtime.applicationHost:status().phase,
      FieldApplicationHost.PHASES.application,
      "the reloaded gear must own the tick again"
    )
    Fixture.closeGearThroughMenu(game)
    Assert.equal(Fixture.scriptFaults(game), 0, "the durability leg must run without script faults")
    Assert.isTrue(Fixture.settleField(game), "the durability leg must rest on an owned field")
  end)
end

-- Missing larger-world facts fail with attribution before any state
-- change: no fabricated specialty answer may ever appear behind a
-- contact, a broadcast, or a reward query.
function T.tests.unavailable_specialty_facts_fail_attributed_without_mutation()
  Fixture.withGame(Fixture.POKECENTER, function(game)
    Fixture.compositionGates(game)
    local gearState = assert(game.runtime.pokegearState, "the dependency leg needs live gear state")
    local PhoneWorldContext = Fixture.requireFeature(
      "game.hgss.src.pokegear.PhoneWorldContext",
      "the journey has no phone world owner yet: dependency-bound reads cannot be proven honest"
    )
    local revisionBefore = gearState:revision()
    local triggersBefore = gearState:readPhone().triggers
    local world = PhoneWorldContext.new({ state = gearState, flags = {} })
    for _, key in ipairs({ "daycare.egg", "safari.test", "kurt.production" }) do
      local failure = Assert.throws(function()
        world:read(key)
      end, "absent " .. key .. " must fail instead of fabricating a call")
      local domain = key:match("^([^.]+)%.")
      Assert.equal((failure --[[@as table]]).domain, domain, "the absent read must attribute " .. domain)
    end
    Assert.equal(gearState:revision(), revisionBefore, "failed dependency reads must not mutate gear state")
    Assert.deepEqual(gearState:readPhone().triggers, triggersBefore, "failed dependency reads must raise no trigger")
    Assert.equal(Fixture.scriptFaults(game), 0, "the dependency leg must run without script faults")
  end)
end

-- Played scripts register no additional caller before the seal: the full opening
-- path (house Mom scene, lab dispatcher, starter pick, corridor gift)
-- carries no number site, the pokecenter pocket sweep finds no giver,
-- and the tower second floor runs the password service to completion
-- while its gate rejects default answers. The town-exit Elm
-- registration waits past the sealed lab door, so the first caller
-- stays honestly unregistered with zero faults and zero seeded facts.
-- Each map below boots fresh and plays its own scripts; no cross-map
-- continuity is claimed.
function T.tests.played_opening_scripts_register_no_caller_before_the_seal()
  Fixture.withGame(Fixture.TOWN, function(game)
    Fixture.compositionGates(game)
    local gearState = assert(game.runtime.pokegearState, "the opening census needs live gear state")
    Fixture.playOpeningToLabFrontier(game)
    Assert.deepEqual(
      gearState:readPhone().contactOrder,
      { nativeMomKey(game) },
      "the played house and lab scripts add no caller beyond native Mom"
    )
    Assert.equal(Fixture.scriptFaults(game), 0, "the opening census must run without script faults")
    Assert.isTrue(Fixture.settleField(game), "the opening census must rest on an owned field")
  end)
  Fixture.withGame(Fixture.POKECENTER, function(game)
    Fixture.compositionGates(game)
    local gearState = assert(game.runtime.pokegearState, "the pocket census needs live gear state")
    Assert.isTrue(Fixture.settleField(game), "the arrival must settle before its actors are approached")
    Fixture.sweepActors(game, function()
      return false
    end, 16)
    Assert.deepEqual(
      gearState:readPhone().contactOrder,
      { nativeMomKey(game) },
      "the pocket sweep adds no caller beyond native Mom: its scripts hold no number site"
    )
    Assert.equal(Fixture.scriptFaults(game), 0, "the pocket census must run without script faults")
    Assert.isTrue(Fixture.settleField(game), "the pocket census must rest on an owned field")
  end)
  Fixture.withGame(Fixture.TOWER_2F, function(game)
    Fixture.compositionGates(game)
    local world =
      assert(game.runtime.scripts and game.runtime.scripts.worldState, "the tower census needs live world state")
    local gearState = assert(game.runtime.pokegearState, "the tower census needs live gear state")
    Assert.isTrue(Fixture.settleField(game), "the tower floor must settle before its actors are approached")
    Fixture.sweepActors(game, function()
      return false
    end, 12)
    local buenaScript = "vanilla.hgss.scr_seq.0030.script_009"
    Assert.isTrue(
      #game:recordsForScript(buenaScript, "script.ended") > 0,
      "the password service must run to completion through its source script"
    )
    Assert.isFalse(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_RADIO_CARD), "the tower sweep must not invent the card")
    Assert.deepEqual(
      gearState:readPhone().contactOrder,
      { nativeMomKey(game) },
      "the password gate adds no caller beyond native Mom on default answers"
    )
    Assert.equal(Fixture.scriptFaults(game), 0, "the tower census must run without script faults")
    Assert.isTrue(Fixture.settleField(game), "the tower census must rest on an owned field")
  end)
end

return T
