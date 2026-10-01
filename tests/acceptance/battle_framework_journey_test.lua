-- Production-path battle journeys: a wild encounter and a trainer battle
-- each run from a live field through the real encounter-to-scenario,
-- session, and result owners, then hand the same field back. The headless
-- presentation port acknowledges immediately; it never authors decisions,
-- hit points, or results. Idle ticks with no answered decision never
-- settle a battle, and player input never leaks through to the field
-- while a battle owns decisions. Both battles publish through the live
-- party and bag owners exactly once, then the same live field resumes.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local BATTLE_RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local SCENARIO_FACTORY_MODULE = "libs.hgss.src.battle.HgssBattleScenarioFactory"
local BATTLE_TASK_MODULE = "libs.hgss.src.script.tasks.BattleTask"

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:7", "map-data:61", "map-data:111", "map:7", "map:61", "map:111" },
    tags = { "field", "battle", "journey" },
  },
  tests = {},
}

---@param name string module path under test
---@param behavior string missing owner under test
---@return table the loaded battle owner
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing battle owner: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the battle module loads")
  return loaded --[[@as table]]
end

local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map or MAP, fieldX = 4, fieldZ = 13, facing = "north" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId, 7),
        bag = require("libs.hgss.src.save.BagSave").empty(),
      }
    end,
  })
end

---@return table headless port acknowledging immediately while recording every frame
local function headlessPort(record)
  return {
    enter = function(_plan)
      record.enters = record.enters + 1
      return true
    end,
    present = function(frame)
      record.frames[#record.frames + 1] = frame
    end,
    leave = function(_plan)
      record.leaves = record.leaves + 1
      return true
    end,
    dispose = function()
      record.disposed = record.disposed + 1
    end,
  }
end

---@param request table pending decision request from the running battle
---@return table[] one opening-move strike per addressed actor
local function strikeWithLeadMove(request)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local choices = {}
  for _, actor in ipairs(assert(request.actors, "a decision request names its actors")) do
    choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
  end
  return choices
end

---@param game table live acceptance game behind the battle
---@param battle table running application battle lifetime
local function driveToCompletion(game, battle)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local ticks = 0
  while battle:status().phase ~= "complete" and battle:status().phase ~= "failed" and ticks < 1200 do
    game:step()
    battle:update()
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      local request = current.request
      local reply = SessionFixture.replyFor(request, strikeWithLeadMove(request))
      local accepted, replyErr = battle:submit(reply)
      Assert.isTrue(accepted, "a legal decision is accepted: " .. tostring(replyErr))
    end
    ticks = ticks + 1
  end
end

---@param catalog table live mon catalog behind the journey
---@return table full enemy record detached from every live owner
local function enemyRecord(catalog, species, level, seed)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local factory = CatalogFixture.makeFactory(seed, catalog)
  return factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
end

function T.tests.wild_and_trainer_battles_run_the_production_path_and_return()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({
    versionId = versionId,
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()

    local BattleRuntime = requirePresent(BATTLE_RUNTIME_MODULE, "application battle lifetime from launch to return")
    local ScenarioFactory =
      requirePresent(SCENARIO_FACTORY_MODULE, "field, trainer, and wild sources mapped to one scenario")
    local BattleTask = requirePresent(BATTLE_TASK_MODULE, "script continuation resumed only after the commit")
    Assert.isTrue(type(BattleTask.start) == "function", "the script task starts a pending launch")
    Assert.isTrue(type(BattleTask.result) == "function", "the script task returns the source outcome once")

    Assert.isTrue(
      game.runtime.monService:giveMon({ species = "CHIKORITA", level = 5, heldItem = "NONE", form = 0 }),
      "the journey needs a live party lead"
    )
    local partyRevisionBefore = game.runtime.monService:partyRevision()
    local bagRevisionBefore = game.runtime.bagService:revision()

    -- First the wild encounter through the live owners.
    local wildRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
    local wildLaunch = { id = "launch-opening-wild", kind = "wild", payload = { species = "TOTODILE", level = 4 } }
    local wildScenario = ScenarioFactory.fromEncounter(wildLaunch.payload, {
      party = game.runtime.monService,
      bag = game.runtime.bagService,
      world = game.runtime.scripts.worldState,
    })
    local wild = BattleRuntime.new({
      request = wildLaunch,
      scenario = wildScenario,
      presentation = headlessPort(wildRecord),
      party = game.runtime.monService,
      bag = game.runtime.bagService,
    })
    Assert.equal(wild:status().launchId, wildLaunch.id, "the runtime carries the launch identity")
    Assert.equal(wild:status().phase, "preparing", "a new battle starts before entry")

    -- Idle ticks with no answered decision never settle the battle: there
    -- is no default move selection and no automatic victory.
    for _ = 1, 30 do
      game:step()
      wild:update()
    end
    local unsettled = wild:status()
    Assert.isTrue(
      unsettled.phase ~= "complete" and unsettled.phase ~= "failed",
      "thirty unanswered ticks must not settle the battle"
    )
    Assert.isNil(unsettled.outcomeReceipt, "no outcome exists before any decision is answered")

    -- Player input during an owned decision never leaks through to the
    -- field: the avatar holds its tile while the battle owns requests.
    local tileBefore = { fieldX = game:snapshot().player.fieldX, fieldZ = game:snapshot().player.fieldZ }
    game:face("north")
    local facingBefore = game:snapshot().player.facing
    game:move("north")
    game:advanceUntil("field input resolves", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 120)
    local held = game:snapshot()
    Assert.equal(held.player.fieldX, tileBefore.fieldX, "a decision owns movement, not the field")
    Assert.equal(held.player.fieldZ, tileBefore.fieldZ, "a decision owns movement, not the field")
    Assert.equal(held.player.facing, facingBefore, "a decision owns facing, not the field")

    driveToCompletion(game, wild)
    local wildFinished = wild:status()
    Assert.equal(wildFinished.phase, "complete", "answered decisions finish the wild battle")
    Assert.notNil(wildFinished.outcomeReceipt, "a finished battle carries its commit receipt")
    Assert.isTrue(wildFinished.outcomeReceipt.committed, "the receipt proves publication, not simulation alone")
    Assert.equal(wildFinished.outcomeReceipt.outcomeId, wildLaunch.id, "the receipt binds the exact launch")
    Assert.isTrue(wildRecord.enters >= 1, "entry presents through the port")
    Assert.isTrue(#wildRecord.frames >= 1, "semantic frames reach presentation")
    Assert.isTrue(
      game.runtime.monService:partyRevision() >= partyRevisionBefore,
      "the committed battle publishes party changes through the live owner"
    )
    Assert.isTrue(
      game.runtime.bagService:revision() >= bagRevisionBefore,
      "the committed battle publishes bag changes through the live owner"
    )
    wild:dispose()
    Assert.equal(wildRecord.disposed, 1, "teardown releases presentation resources exactly once")

    -- Then a trainer battle on the same live field: the trainer fields
    -- real records and answers through its bound selection program while
    -- the player keeps answering real decisions.
    local liveCatalog = game.runtime.monService:catalog()
    local foe = enemyRecord(liveCatalog, "TOTODILE", 4, 0x5EED0001)
    Assert.equal(foe.species, "TOTODILE", "the trainer fields its own record")
    local trainerRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
    local trainerLaunch = { id = "launch-first-rival", kind = "trainer", payload = { trainer = "rival-early" } }
    local trainerScenario = ScenarioFactory.fromTrainer({
      id = trainerLaunch.id,
      trainers = {
        {
          id = "rival-early",
          party = { foe },
          program = {
            key = "rival_opening",
            revision = "native-1",
            instructions = {},
            entryPoints = {},
          },
        },
      },
    }, {
      party = game.runtime.monService,
      bag = game.runtime.bagService,
      world = game.runtime.scripts.worldState,
    })
    local rival = BattleRuntime.new({
      request = trainerLaunch,
      scenario = trainerScenario,
      presentation = headlessPort(trainerRecord),
      party = game.runtime.monService,
      bag = game.runtime.bagService,
    })
    driveToCompletion(game, rival)
    local rivalFinished = rival:status()
    Assert.equal(rivalFinished.phase, "complete", "answered decisions finish the trainer battle")
    Assert.notNil(rivalFinished.outcomeReceipt, "a finished trainer battle carries its commit receipt")
    Assert.isTrue(rivalFinished.outcomeReceipt.committed, "the trainer receipt proves publication")
    Assert.equal(rivalFinished.outcomeReceipt.outcomeId, trainerLaunch.id, "the trainer receipt binds its launch")
    Assert.isTrue(#trainerRecord.frames >= 1, "trainer frames reach presentation")
    rival:dispose()
    Assert.equal(trainerRecord.disposed, 1, "trainer teardown releases its port exactly once")

    -- The same live field resumes: identical map, no fault, the party
    -- survives both round trips, and the script continuation resumes on
    -- the committed results.
    Assert.isNil(game.runtime.errorText, "the round trips run without a runtime fault")
    game:waitForFieldReady()
    Assert.equal(game:snapshot().mapSymbol, MAP, "the battles return to the map they launched from")
    Assert.isTrue(game.runtime.monService:partyCount() >= 1, "the live party survives the round trips")
    local wildResult = BattleTask.result({ launchId = wildLaunch.id })
    Assert.isTrue(wildResult.committed, "the script continuation resumes on the wild result")
    local rivalResult = BattleTask.result({ launchId = trainerLaunch.id })
    Assert.isTrue(rivalResult.committed, "the script continuation resumes on the trainer result")
    Assert.equal(game:renderAttempts(), 0, "the journey must stop before GPU rendering")
  end, debug.traceback)
  local namespace = game.saveNamespace
  game:close()
  if not ok then
    error(err, 0)
  end
  Assert.isNil(love.filesystem.getInfo(namespace), "teardown removes the isolated save namespace")
end

return T
