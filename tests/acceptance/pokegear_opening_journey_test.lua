-- Opening first-impression journey for the pocket gear: a genuine New Game
-- through the house Mom scene, Elm's lab welcome and dispatcher
-- conversation, the starter pick, and the corridor gift, with a permitted
-- save/load roundtrip at the frontier. Past the frontier the lab door
-- stands sealed by scriptless actors on its warp anchors, so the
-- town-exit registration, the home handoff, the road walks, the Map
-- Card, the errand, the panic call, and the rival naming stay unplayed
-- and are marked blocked with that seal evidence instead of faked: the
-- leg asserts the exact blocking condition with zero faults and zero
-- mutations. Every leg boots the real field runtime over real maps,
-- scripts, and state owners; only host audio, host input snapshots, the
-- wall clock, and the save root are recording boundaries. No ROM bytes
-- are read here and no gear implementation is faked.

local Assert = require("tests.support.Assert")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldMovement = require("tests.acceptance.support.FieldMovement")
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

-- The opening play runs the genuine New Game through the lab frontier
-- and marks the naming route blocked at the sealed lab door: the
-- starter errand is underway past a permitted save roundtrip, and every
-- lab door warp anchor is occupied by a live actor answering with no
-- script, so production movement offers no route out and a bounded exit
-- attempt changes no map, fires no transition, faults no script, and
-- mutates no gear fact. The town-exit registration, the home handoff,
-- and the rival naming wait past that seal instead of faked.
function T.tests.opening_play_holds_the_frontier_behind_the_sealed_lab_exit()
  Fixture.withGame(Fixture.TOWN, function(game)
    Fixture.compositionGates(game)
    local world =
      assert(game.runtime.scripts and game.runtime.scripts.worldState, "the opening journey needs live world state")
    local gearState = assert(game.runtime.pokegearState, "the opening journey needs live gear state")

    Fixture.playOpeningToLabFrontier(game)

    -- Frontier truth: the starter errand is underway, the gear is still
    -- unowned, and no scripted registration point has played yet. The
    -- native Mom default exists independently of those script effects.
    world = assert(game.runtime.scripts.worldState, "the frontier needs live world state")
    gearState = assert(game.runtime.pokegearState, "the frontier needs live gear state")
    Assert.isTrue(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_STARTER), "the frontier keeps the played starter")
    Assert.equal(world:getVar(Fixture.VARS.VAR_SCENE_ELMS_LAB), 2, "the frontier keeps the concluded corridor gift")
    Assert.isFalse(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_POKEGEAR), "the gear still waits past the frontier")
    Assert.deepEqual(
      gearState:readPhone().contactOrder,
      { nativeMomKey(game) },
      "only the native Mom default is registered"
    )
    Assert.equal(Fixture.scriptFaults(game), 0, "the opening scenes must run without script faults")

    -- The frontier roundtrips through a permitted save: the starter, the
    -- scene, and native Mom default all survive verbatim.
    Fixture.saveAndReload(game)
    world = assert(game.runtime.scripts.worldState, "the reloaded journey needs live world state")
    gearState = assert(game.runtime.pokegearState, "the reloaded journey needs live gear state")
    Assert.isTrue(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_STARTER), "reload must retain the played starter")
    Assert.equal(world:getVar(Fixture.VARS.VAR_SCENE_ELMS_LAB), 2, "reload must retain the corridor gift")
    Assert.isFalse(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_POKEGEAR), "reload must not invent the gear")
    Assert.deepEqual(gearState:readPhone().contactOrder, { nativeMomKey(game) }, "reload retains only native Mom")
    Assert.equal(game:snapshot().mapSymbol, Fixture.LAB_1F, "reload must resume inside the lab")

    -- Past the frontier the lab door stands sealed: every door warp
    -- anchor is occupied by a live actor, production movement cannot
    -- route onto an occupied anchor, and each blocker answers with no
    -- script at all, so no briefing and no naming scene can start behind
    -- the sealed door. The block lands pre-mutation: revisions, contacts,
    -- and flags read identical before and after the exit attempt.
    local warps = assert(game.runtime.runtimeMap.fieldData.events.warps, "the frontier needs production warp data")
    Assert.isTrue(#warps > 0, "the lab must publish its door warps")
    local faultsBefore = Fixture.scriptFaults(game)
    local revisionBefore = gearState:revision()
    for index = 0, #warps - 1 do
      local anchor = game:warpDestination(index)
      local tile = { fieldX = anchor.fieldX, fieldZ = anchor.fieldZ }
      local blocker = nil
      for actorId in pairs(game:snapshot().actors) do
        local live = game.runtime.actors:getById(actorId)
        local pos = live and live:getFieldPosition() or nil
        if pos ~= nil and pos.fieldX == tile.fieldX and pos.fieldZ == tile.fieldZ then
          blocker = actorId
        end
      end
      Assert.notNil(blocker, "a live actor must stand on the lab door anchor")
      Assert.isNil(FieldMovement.route(game, tile), "production movement must not route onto the occupied door anchor")
      Assert.isTrue(pcall(Fixture.talkTo, game, blocker), "the door blocker must be addressable")
      Assert.equal(
        game:interaction().scriptId,
        "runtime.inert_interaction",
        "the door blocker carries no briefing script"
      )
      Assert.isTrue(Fixture.drainField(game, 240), "addressing the blocker must release the field")
    end
    for _ = 1, 12 do
      if game:snapshot().mapSymbol ~= Fixture.LAB_1F then
        break
      end
      local snapshot = game:snapshot()
      if snapshot.dialogue.modal or game.runtime.scripts.scheduler:foregroundEnvironmentId() ~= nil then
        Assert.isTrue(Fixture.drainField(game, 240), "exit dialogue settles")
      else
        game:move("south")
        game:advanceUntil("the exit step resolves", function(current)
          return current.player.motion == "idle"
        end, 120)
      end
    end
    Assert.equal(game:snapshot().mapSymbol, Fixture.LAB_1F, "the blocked exit must never change maps")
    Assert.equal(game:snapshot().transition.phase, "idle", "the blocked exit must never fire a transition")
    Assert.equal(Fixture.scriptFaults(game), faultsBefore, "the blocked exit must fault no script")
    Assert.equal(gearState:revision(), revisionBefore, "the blocked exit must mutate no gear fact")
    Assert.deepEqual(
      gearState:readPhone().contactOrder,
      { nativeMomKey(game) },
      "the blocked exit adds no caller beyond native Mom"
    )
    Assert.isTrue(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_STARTER), "the seal keeps the played starter")
    Assert.equal(world:getVar(Fixture.VARS.VAR_SCENE_ELMS_LAB), 2, "the seal keeps the corridor gift")
    Assert.isFalse(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_POKEGEAR), "the gear handoff waits past the sealed door")
    Assert.isTrue(Fixture.settleField(game), "the frontier must rest on an owned field")
  end)
end

-- A fresh arrival owns no gear and no tab: without the source flags the
-- menu offers no usable gear route, so every later tab effect proves its
-- own acquisition.
function T.tests.fresh_arrival_offers_no_usable_gear_route()
  Fixture.withGame(Fixture.TOWN, function(game)
    Fixture.compositionGates(game)
    local world = assert(game.runtime.scripts and game.runtime.scripts.worldState, "the arrival needs live world state")
    Assert.isFalse(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_POKEGEAR), "a fresh arrival owns no gear and no tab")
    Assert.isFalse(
      world:isFlagSet(Fixture.FLAGS.FLAG_GOT_RADIO_CARD),
      "a fresh arrival owns no radio card and no station"
    )
    game.runtime:pressMenu()
    game:step()
    game.runtime:releaseMenu()
    game:advanceUntil("the start menu becomes modal", function()
      return game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.menu
    end, 120)
    do
      local status = game.runtime.applicationHost:status()
      assert(status.menu, "the menu phase must expose its controller status")
      local offered = false
      local usable = false
      for _, action in ipairs(assert(status.menu.actions, "the menu must list its actions")) do
        if action.id == Fixture.POKEGEAR_ACTION then
          offered = true
          usable = usable or action.enabled == true
        end
      end
      Assert.isFalse(offered and usable, "an unacquired gear must never offer a usable menu route")
    end
    game.runtime:pressMenu()
    game:step()
    game.runtime:releaseMenu()
    game:advanceUntil("the start menu closes", function()
      return game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.closed
    end, 120)
    Assert.isTrue(Fixture.settleField(game), "the arrival must rest on an owned field")
  end)
end

return T
