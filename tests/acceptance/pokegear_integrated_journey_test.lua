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
local PokegearSources = require("romdump.src.config.PokegearSources")
local PhoneRewards = require("game.hgss.src.pokegear.PhoneRewards")
local LocalClock = require("game.src.LocalClock")

local DERIVED_ASSETS = {}
for _, key in ipairs(Fixture.JOURNEY_ASSETS) do
  DERIVED_ASSETS[#DERIVED_ASSETS + 1] = key
end
for _, bankId in ipairs({ 271, 279, 280, 664, 675, 716, 730 }) do
  DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "message-bank:" .. tostring(bankId)
end
for _, bankId in ipairs(PokegearSources.phoneMessageBankIds()) do
  DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "message-bank:" .. tostring(bankId)
end
DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "map:68"
DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "map-data:68"

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = DERIVED_ASSETS,
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

local function actionEdge(game)
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

local function cancelEdge(game)
  game.runtime:pressCancel()
  game:step()
  game.runtime:releaseCancel()
end

local function phoneView(game)
  local application = assert(game.runtime.applicationHost:status().application, "the gear application owns the tick")
  local child = assert(application.child, "the Phone card publishes its child status")
  return assert(child.view, "the Phone card publishes its detached view")
end

local function contactByFamily(catalog, family)
  for _, contact in ipairs(catalog.contacts) do
    if contact.family == family then
      return contact
    end
  end
  error("the native phone catalog contains a " .. family .. " contact", 0)
end

local function armMotherGiftCall(game, sample)
  game:step()
  Assert.isTrue(Fixture.settleField(game), "the call setup begins at an unclaimed field boundary")
  local catalog = assert(game.runtime.pokegearCatalog, "the field runtime owns its compiled phone catalog")
  local mom = contactByFamily(catalog, "mother")
  local state = assert(game.runtime.pokegearState, "the incoming call uses the composed Pokegear save owner")
  state:registerContact(mom.key)
  state:setMom({ balance = 0, purchases = {}, gifts = { { item = "POTION", quantity = 1 } } })
  local calls = assert(game.runtime.incomingCalls, "the field runtime owns its incoming call coordinator")
  calls:setTrigger(PhoneRewards.MOM_GIFT_TRIGGER, true)
  sample.minute = sample.minute + 1
  game:advanceUntil("the source Mom trigger rings at an idle field opportunity", function()
    return calls:notification() ~= false
  end, 120)
  local ring = calls:notification()
  local triggerRecord = nil
  for _, candidate in ipairs(catalog.callTriggers) do
    if candidate.key == PhoneRewards.MOM_GIFT_TRIGGER then
      triggerRecord = candidate
      break
    end
  end
  Assert.isTrue(triggerRecord ~= nil, "the compiled source catalog includes Mom's delivery trigger")
  Assert.isTrue(ring ~= false, "the eligible source Mom trigger rings after a live minute")
  assert(type(ring) == "table", "the ringing caller publishes its source contact")
  Assert.equal(ring.contactKey, mom.key, "the pending native Mom delivery trigger selects its caller")
  return mom, calls
end

local function stageTalkableObject(game)
  local FieldMovement = require("tests.acceptance.support.FieldMovement")
  local actorIds = {}
  for actorId in pairs(game:snapshot().actors) do
    if actorId:match(":object:%d+$") ~= nil then
      actorIds[#actorIds + 1] = actorId
    end
  end
  table.sort(actorIds)
  for _, actorId in ipairs(actorIds) do
    local actor = assert(game.runtime.actors:getById(actorId), "the selected object remains live")
    local position = actor:getFieldPosition()
    local candidates = {
      { fieldX = position.fieldX, fieldZ = position.fieldZ + 1, facing = "north" },
      { fieldX = position.fieldX, fieldZ = position.fieldZ - 1, facing = "south" },
      { fieldX = position.fieldX + 1, fieldZ = position.fieldZ, facing = "west" },
      { fieldX = position.fieldX - 1, fieldZ = position.fieldZ, facing = "east" },
    }
    for _, tile in ipairs(candidates) do
      if FieldMovement.route(game, tile) ~= nil then
        game:moveTo(tile)
        game:face(tile.facing)
        local player = game.runtime.player
        local intent = game.runtime.interactionResolver:resolve({
          runtimeMap = game.runtime.runtimeMap,
          fieldX = player.fieldX,
          fieldZ = player.fieldZ,
          surfaceId = player.surfaceId,
          worldY = player.worldY,
          facing = player.facing,
          tick = game.runtime.session.tick + 1,
        })
        if intent ~= nil then
          return actorId
        end
      end
    end
  end
  error("the live map exposes an adjacent talkable object through production movement", 0)
end

local function deterministicBattlePort()
  return {
    enter = function()
      return true
    end,
    present = function() end,
    ready = function()
      return true
    end,
    leave = function()
      return true
    end,
    dispose = function() end,
  }
end

local function settleTrainerBattle(game, battle)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local ticks = 0
  while battle:status().phase ~= "complete" and battle:status().phase ~= "failed" and ticks < 1200 do
    game:step()
    battle:update()
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      local choices = {}
      for _, actor in ipairs(current.request.actors) do
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
      end
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "the trainer win accepts a legal battle decision: " .. tostring(replyErr))
    end
    ticks = ticks + 1
  end
end

function T.tests.field_action_answers_moms_call_before_npc_and_returns_cleanly()
  local sample = { year = 2024, month = 1, day = 8, hour = 10, minute = 0, second = 0 }
  Fixture.withGame(Fixture.POKECENTER, function(game)
    Fixture.compositionGates(game)
    local actorId = stageTalkableObject(game)
    local _, calls = armMotherGiftCall(game, sample)
    local host = assert(game.runtime.pokegear.scriptHost, "the field uses its composed phone host")
    local beforeInteraction = game:interaction()

    game.runtime:pressAction()
    game:step()
    game.runtime:releaseAction()

    Assert.isTrue(host:isActive(), "field Action must acquire the ringing caller before ordinary interaction")
    Assert.equal(game:interaction().actorId, beforeInteraction.actorId, "the answer edge must not start the NPC")
    Assert.isFalse(calls:notification(), "the accepted call no longer publishes its ring")
    Assert.isTrue(
      game.runtime.pokegearState:readPhone().triggers[PhoneRewards.MOM_GIFT_TRIGGER],
      "Mom's trigger remains until pickup"
    )
    Assert.isTrue(Fixture.drainField(game, 480), "source Mom dialogue must finish and release its field owner")
    Assert.isFalse(host:isActive(), "a terminal call releases its host handle")
    Assert.isTrue(Fixture.settleField(game), "terminal call cleanup restores ordinary field ownership")

    game:pressAction()
    Assert.equal(game:interaction().actorId, actorId, "a fresh Action edge interacts with the same NPC")
    local scriptId = assert(game:interaction().scriptId, "the fresh NPC interaction publishes its source script")
    Assert.isTrue(#game:recordsForScript(scriptId, "script.started") > 0, "the fresh edge starts the NPC script")
    Assert.isTrue(Fixture.drainField(game, 480), "the NPC interaction releases its script owner")

    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_SAVE_BUTTON })
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    Fixture.saveAndReload(game)
    Assert.isFalse(game.runtime.pokegear.scriptHost:isActive(), "save reload starts without a stale phone owner")
    Assert.isTrue(Fixture.settleField(game), "save reload returns to ordinary field play")
  end, {
    localClock = LocalClock.new(function()
      return sample
    end),
  })
end

function T.tests.tearing_down_an_answered_call_releases_the_composed_host()
  local sample = { year = 2024, month = 1, day = 8, hour = 10, minute = 0, second = 0 }
  Fixture.withGame(Fixture.POKECENTER, function(game)
    Fixture.compositionGates(game)
    local _, calls = armMotherGiftCall(game, sample)
    local host = assert(game.runtime.pokegear.scriptHost, "the field uses its composed phone host")
    Fixture.pressActionEdge(game)
    Assert.isTrue(host:isActive(), "real field Action opens the ambient caller before teardown")
    Assert.isFalse(host:isStableForSave(), "the accepted conversation keeps saves behind its live lease")

    game.runtime:dispose()

    Assert.isFalse(host:isActive(), "field teardown cancels the accepted host handle")
    Assert.isTrue(host:isStableForSave(), "teardown releases the phone lease exactly once")
    Assert.isFalse(calls:notification(), "teardown leaves no transient ring")
  end, {
    localClock = LocalClock.new(function()
      return sample
    end),
  })
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
    local rematchContact = nil
    for _, contact in ipairs(game.runtime.pokegearCatalog.contacts) do
      if contact.family == "gym" then
        rematchContact = contact.key
        break
      end
    end
    rematchContact = assert(rematchContact, "the compiled phonebook carries a gym contact")
    gearState:registerContact(rematchContact)
    gearState:setRematch(rematchContact, { stage = 1, wins = 2 })
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    Fixture.openGearThroughMenu(game)
    Fixture.closeGearThroughMenu(game)
    Fixture.saveAndReload(game)
    world = assert(game.runtime.scripts.worldState, "the reloaded leg needs live world state")
    gearState = assert(game.runtime.pokegearState, "the reloaded leg needs live gear state")
    Assert.deepEqual(
      gearState:queryRematch(rematchContact),
      { stage = 1, wins = 2 },
      "production save and reload retain rematch readiness and wins"
    )
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

-- The composed phone samples Mother from the real FieldRuntime and writes
-- her choice through the live event owner. The cleared native flag selects
-- the source offer; accepting its default save choice must set the source
-- flag, not a temporary field on the phone facade.
function T.tests.mother_call_reads_and_writes_the_live_savings_flag()
  Fixture.withGame(Fixture.POKECENTER, function(game)
    Fixture.compositionGates(game)
    local state = assert(game.runtime.pokegearState, "the call borrows the field's durable phonebook")
    local contacts = assert(game.runtime.pokegearCatalog.contacts, "the call uses compiled native phonebook data")
    local mother = nil
    for _, record in ipairs(contacts) do
      if record.id == 0 then
        mother = record
        break
      end
    end
    mother = assert(mother, "the compiled phonebook carries native contact zero")
    local contact = mother.key
    Assert.notNil(state:readPhone().contacts[contact], "the field runtime registers Mom before composing calls")

    local flag = Fixture.FLAGS.FLAG_SYS_MOMS_SAVINGS
    local events = assert(game.runtime.eventState, "the live field owns the native story flags")
    events:clearFlag(flag)
    Assert.isFalse(events:isFlagSet(flag), "the initial phone choice starts with savings disabled")

    local host = assert(game.runtime.pokegear.scriptHost, "the real composition owns the script phone host")
    local handle = host:open({
      mode = "call",
      request = { id = "mother-savings-acceptance", contact = contact, direction = "outgoing", kind = "ordinary" },
      parentOwner = "acceptance-field-script",
    })
    for _ = 1, 32 do
      if host:result(handle) ~= nil then
        break
      end
      host:step(handle, { { type = "confirm" } })
    end
    local result = host:result(handle)
    Assert.notNil(result, "the composed source call completes after its choice is accepted")
    Assert.equal(result.program, "mother-offer", "the current native savings flag selects the offer branch")
    Assert.isTrue(events:isFlagSet(flag), "accepting save updates FieldEventState's native flag")
    host:close(handle)
    Assert.equal(Fixture.scriptFaults(game), 0, "the live flag call must not fault its field script")
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

-- A completed menu dial releases its call owner back to the real contact
-- list. The player can start another distinct call and dismiss the gear
-- through the ordinary field application shell.
function T.tests.completed_menu_dial_returns_to_contacts_and_gear_exits()
  Fixture.withGame(Fixture.TOWN, function(game)
    local catalog = assert(game.runtime.pokegearCatalog, "the field runtime owns the compiled phone catalog")
    local mom = contactByFamily(catalog, "mother")
    local elm = contactByFamily(catalog, "elm")
    local gearState = assert(game.runtime.pokegearState, "the field runtime owns phonebook state")
    gearState:registerContact(mom.key)
    gearState:registerContact(elm.key)
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })

    Fixture.openGearThroughMenu(game)
    game:advanceUntil("the Phone opening transition completes", function()
      local status = game.runtime.applicationHost:status().application
      return status ~= nil and status.transition == nil
    end, 40)
    actionEdge(game)
    actionEdge(game)
    actionEdge(game)
    local firstCall = assert(phoneView(game).call, "the selected native Mom row starts a production dial")
    Assert.equal(firstCall.contact, mom.key, "the first dial uses the first registered contact")
    Assert.equal(firstCall.stage, "message", "the first native dial reaches source-backed text")
    local firstId = firstCall.id

    actionEdge(game)
    cancelEdge(game)
    local application = assert(game.runtime.applicationHost:status().application, "the gear remains open after hangup")
    Assert.isFalse(application.busy, "a finished menu dial releases the child call owner")
    Assert.equal(application.child.view.call, nil, "the finished dial returns the Phone child to its list view")
    Assert.equal(#application.child.view.list.rows, 2, "the returned Phone list still contains both contacts")

    game.runtime:press("south")
    game:step()
    game.runtime:release("south")
    actionEdge(game)
    actionEdge(game)
    local secondCall = assert(phoneView(game).call, "the next selected contact starts a second production dial")
    Assert.equal(secondCall.contact, elm.key, "the next dial follows the contact list selection")
    Assert.isTrue(secondCall.id ~= firstId, "each menu dial receives its own conversation identity")
    cancelEdge(game)
    Assert.isFalse(
      game.runtime.applicationHost:status().application.busy,
      "hanging up the second menu dial also returns to the list"
    )

    Fixture.closeGearThroughMenu(game)
    Assert.equal(
      game.runtime.applicationHost:status().phase,
      FieldApplicationHost.PHASES.closed,
      "the ordinary shell cancel exits the gear after the dial"
    )
    Assert.isTrue(Fixture.settleField(game), "the completed journey returns to ordinary field ownership")
    Assert.equal(Fixture.scriptFaults(game), 0, "the completed call journey runs without script faults")
    Assert.equal(game:renderAttempts(), 0, "the call ownership acceptance stops before GPU rendering")
  end)
end

-- A winning trainer battle launched by the composed FieldRuntime commits
-- its source savings transfer and native purchase queue through the same
-- live save owners. The deterministic staged trainer keeps the acceptance
-- focused on the production battle consequence boundary.
function T.tests.trainer_win_saves_moms_purchase_from_the_field_battle()
  Fixture.withGame(Fixture.TOWN, function(game)
    Fixture.playOpeningToLabFrontier(game)
    local state = assert(game.runtime.pokegearState, "the battle borrows the live Pokegear save owner")
    local events = assert(game.runtime.eventState, "the battle reads the live native story flags")
    local savingsFlag = Fixture.FLAGS.FLAG_SYS_MOMS_SAVINGS
    events:setFlag(savingsFlag)
    state:setMom({ balance = 800, purchases = {}, gifts = {} })

    local party = assert(game.runtime.monService, "the battle uses the composed party owner")
    Assert.isTrue(
      party:giveMon({ species = "CHIKORITA", level = 50, heldItem = "NONE", form = 0 }),
      "the staged trainer fight has a live player lead"
    )
    party:setMove(0, 0, "SWIFT")

    local CatalogFixture = require("libs.mons.tests.catalog_fixture")
    local factory = CatalogFixture.makeFactory(0xD0501, game.runtime.monService:catalog())
    local opponent = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 5 }))
    opponent.condition.currentHp = 1
    opponent.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
    local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
    local request = {
      id = "field-mom-savings-trainer-win",
      kind = "trainer",
      payload = { trainer = "acceptance-native-trainer" },
    }
    local scenario = ScenarioFactory.fromTrainer({
      id = request.id,
      trainers = {
        {
          id = request.payload.trainer,
          class = 1,
          name = "TRAINER",
          party = { opponent },
          partyLevels = { 5 },
          prizeMoney = { trainerClass = 1, classRate = 1000 },
          program = { key = "acceptance_opening", revision = "native-1", instructions = {}, entryPoints = {} },
          aiPasses = {},
        },
      },
    }, {
      party = game.runtime.monService,
      player = { trainerId = 1, trainerName = "GOLD", language = "english" },
    })
    local beforeMoney = game.runtime.playerData.profile.money
    local beforeMom = state:readPhone().mom
    local battle = game.runtime:startBattle({
      request = request,
      scenario = scenario,
      presentation = deterministicBattlePort(),
    })
    settleTrainerBattle(game, battle)
    Assert.equal(battle:status().phase, "complete", "the production field battle reaches its committed result")
    Assert.equal(battle:status().result, "win", "the staged trainer opponent loses to the live party")
    local receipt = assert(battle:status().outcomeReceipt, "the trainer result publishes its battle receipt")
    Assert.isTrue(receipt.committed, "the field caller commits the trainer result")

    local payout = assert(receipt.rewards.amount, "the winning trainer receipt names its prize")
    local deposit = math.floor(payout / 4)
    Assert.equal(
      receipt.player.profile.money,
      beforeMoney + payout - deposit,
      "the live player record receives the prize less the quarter transferred after caps"
    )
    local mom = state:readPhone().mom
    Assert.isTrue(mom.balance < beforeMom.balance + deposit, "the same battle buys from Mom's increased balance")
    Assert.isTrue(#mom.gifts > 0, "the same battle queues a native purchase instead of publishing only a deposit")
    Assert.isTrue(next(state:readPhone().triggers) ~= nil, "a queued purchase raises its compiled Mom delivery trigger")

    game.runtime:updateBattle()
    Fixture.saveAndReload(game)
    state = assert(game.runtime.pokegearState, "the reloaded journey restores Pokegear state")
    Assert.deepEqual(state:readPhone().mom, mom, "the battle purchase survives the production save and reload")
  end)
end

local MOM_DELIVERY_SCRIPT = "common.moms_gift_deliveryman"

local function runMomDeliveryScript(game)
  Assert.notNil(
    game.runtime.scripts.composition:effective(MOM_DELIVERY_SCRIPT),
    "the map runtime loads the compiled Mom deliveryman script"
  )
  local startsBefore = #game:recordsForScript(MOM_DELIVERY_SCRIPT, "script.started")
  local actorIds = {}
  for actorId in pairs(game:snapshot().actors) do
    if actorId:match(":object:%d+$") ~= nil then
      actorIds[#actorIds + 1] = actorId
    end
  end
  table.sort(actorIds)
  for _, actorId in ipairs(actorIds) do
    if #game:recordsForScript(MOM_DELIVERY_SCRIPT, "script.started") > startsBefore then
      break
    end
    if Fixture.sweepReachable(game, actorId) then
      Fixture.talkTo(game, actorId)
    end
  end
  Assert.isTrue(
    #game:recordsForScript(MOM_DELIVERY_SCRIPT, "script.started") > startsBefore,
    "a reachable source deliveryman starts the compiled Mom gift script"
  )
end

function T.tests.deliveryman_gives_one_queued_gift_and_preserves_it_when_bag_is_full()
  local PhoneRewards = require("game.hgss.src.pokegear.PhoneRewards")
  local deliveredQuantity = nil
  local deliveredQueue = nil
  local deliveredTrigger = nil
  Fixture.withGame("MAP_CHERRYGROVE_POKEMART", function(game)
    local state = assert(game.runtime.pokegearState, "the deliveryman reads the live Pokegear save owner")
    state:setMom({ balance = 0, purchases = {}, gifts = { { item = "POTION", quantity = 1 } } })
    state:setTrigger(PhoneRewards.MOM_GIFT_TRIGGER, true)
    runMomDeliveryScript(game)
    deliveredQuantity = game.runtime.bagService:quantity("POTION")
    deliveredQueue = state:readPhone().mom.gifts
    deliveredTrigger = state:readPhone().triggers[PhoneRewards.MOM_GIFT_TRIGGER] == true
  end)

  local fullBagQuantity = nil
  local fullBagSlotsBefore = nil
  local fullBagSlotsAfter = nil
  local fullBagQueue = nil
  local fullBagTrigger = nil
  Fixture.withGame("MAP_CHERRYGROVE_POKEMART", function(game)
    local state = assert(game.runtime.pokegearState, "the full-Bag deliveryman reads the live save owner")
    local bag = assert(game.runtime.bagService, "the full-Bag path uses the composed Bag service")
    local pocket = bag:pocketOf("REPEL")
    for _, key in ipairs(bag:catalog():itemKeys()) do
      if key ~= "REPEL" and bag:pocketOf(key) == pocket and not bag:hasSpace("REPEL", 1) then
        break
      end
      if key ~= "REPEL" and bag:pocketOf(key) == pocket then
        bag:add(key, 1)
      end
    end
    Assert.isFalse(bag:hasSpace("REPEL", 1), "setup fills the real Bag pocket before delivery")
    local beforeSlots = #bag:pocketItems(pocket)
    fullBagSlotsBefore = beforeSlots
    state:setMom({ balance = 0, purchases = {}, gifts = { { item = "REPEL", quantity = 1 } } })
    state:setTrigger(PhoneRewards.MOM_GIFT_TRIGGER, true)
    runMomDeliveryScript(game)
    fullBagQuantity = bag:quantity("REPEL")
    fullBagSlotsAfter = #bag:pocketItems(pocket)
    fullBagQueue = state:readPhone().mom.gifts
    fullBagTrigger = state:readPhone().triggers[PhoneRewards.MOM_GIFT_TRIGGER] == true
  end)
  Assert.equal(deliveredQuantity, 1, "the source give path adds the queued item once")
  Assert.deepEqual(deliveredQueue, {}, "the source dequeue follows a successful item give")
  Assert.isFalse(deliveredTrigger, "successful pickup clears the Mom trigger")
  Assert.equal(fullBagQuantity, 0, "a full Bag pocket refuses the item")
  Assert.equal(fullBagSlotsAfter, fullBagSlotsBefore, "a refused give leaves every Bag slot intact")
  Assert.deepEqual(fullBagQueue, { { item = "REPEL", quantity = 1 } }, "a refused give retains the FIFO head")
  Assert.isTrue(fullBagTrigger, "a refused give leaves the Mom delivery trigger active")
end

return T
