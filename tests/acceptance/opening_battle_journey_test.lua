-- Field battle round trip through production composition: a live field boots
-- from the warmed cache, a wild battle launches from live field state, real
-- decisions answer real requests, the required commit publishes
-- party/bag/world changes, and the same live field resumes the story only
-- afterwards. The headless presentation port acknowledges immediately; it
-- never authors decisions, hit points, or results.

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
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0, nationalDex = false },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId, 7),
        bag = require("libs.hgss.src.save.BagSave").empty(),
        mart = require("libs.hgss.src.save.MartSave").empty(),
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

---@param catalog table live mon catalog behind the journey
---@return table full enemy record detached from every live owner
local function enemyRecord(catalog, species, level, seed)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local factory = CatalogFixture.makeFactory(seed, catalog)
  return factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
end

---@param record table full mon-domain record under test preparation
---@return table the same record striking with a single known move
local function tackleOnly(record)
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

function T.tests.field_battle_returns_to_the_live_field_after_commit()
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
    Assert.isTrue(type(BattleTask.poll) == "function", "the script task polls without completing early")
    Assert.isTrue(type(BattleTask.result) == "function", "the script task returns the source outcome once")

    Assert.isTrue(
      game.runtime.monService:giveMon({ species = "CHIKORITA", level = 5, heldItem = "NONE", form = 0 }),
      "the journey needs a live party lead"
    )
    local partyRevisionBefore = game.runtime.monService:partyRevision()
    local bagRevisionBefore = game.runtime.bagService:revision()
    local tileBefore = { fieldX = game:snapshot().player.fieldX, fieldZ = game:snapshot().player.fieldZ }

    local portRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
    local liveCatalog = game.runtime.monService:catalog()
    local wildFoe = tackleOnly(enemyRecord(liveCatalog, "TOTODILE", 4, 0xB1AC0003))
    local launch = {
      id = "launch-opening-wild",
      kind = "wild",
      payload = { species = "TOTODILE", level = 4, mon = wildFoe },
    }
    local scenario = ScenarioFactory.fromEncounter(launch.payload, {
      party = game.runtime.monService,
      bag = game.runtime.bagService,
      world = game.runtime.scripts.worldState,
      player = { trainerId = 99, trainerName = "MINT", language = "french" },
    })
    local battle = BattleRuntime.new({
      request = launch,
      scenario = scenario,
      presentation = headlessPort(portRecord),
      party = game.runtime.monService,
      bag = game.runtime.bagService,
    })
    Assert.equal(battle:status().launchId, launch.id, "the runtime carries the launch identity")
    Assert.equal(battle:status().phase, "preparing", "a new battle starts before entry")

    -- Idle ticks with no answered decision never settle the battle: there
    -- is no default move selection and no automatic victory.
    for _ = 1, 30 do
      game:step()
      battle:update()
    end
    local unsettled = battle:status()
    Assert.isTrue(
      unsettled.phase ~= "complete" and unsettled.phase ~= "failed",
      "thirty unanswered ticks must not settle the battle"
    )
    Assert.isNil(unsettled.outcomeReceipt, "no outcome exists before any decision is answered")

    -- Player input during an owned decision never leaks through to the
    -- field: the avatar holds its tile while the battle owns requests.
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

    -- Answer every real request with the lead move until the battle ends.
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
    local finished = battle:status()
    Assert.equal(finished.phase, "complete", "answered decisions finish the battle")
    Assert.notNil(finished.outcomeReceipt, "a finished battle carries its commit receipt")
    Assert.isTrue(finished.outcomeReceipt.committed, "the receipt proves publication, not simulation alone")
    Assert.equal(finished.outcomeReceipt.outcomeId, launch.id, "the receipt binds the exact launch")
    Assert.isTrue(portRecord.enters >= 1, "entry presents through the port")
    Assert.isTrue(#portRecord.frames >= 1, "semantic frames reach presentation")

    -- The required commit lands party/bag/world changes exactly once, then
    -- the runtime returns through postbattle before the field resumes.
    Assert.isTrue(
      game.runtime.monService:partyRevision() >= partyRevisionBefore,
      "the committed battle publishes party changes through the live owner"
    )
    Assert.isTrue(
      game.runtime.bagService:revision() >= bagRevisionBefore,
      "the committed battle publishes bag changes through the live owner"
    )
    local returned = battle:status()
    Assert.isTrue(
      returned.phase == "complete",
      "postbattle work drains before the runtime reports completion"
    )
    battle:dispose()
    Assert.equal(portRecord.disposed, 1, "teardown releases presentation resources exactly once")

    -- The same live field resumes: identical map, movement restored, no
    -- fault, and the story continues only now that the commit exists.
    Assert.isNil(game.runtime.errorText, "the round trip runs without a runtime fault")
    game:waitForFieldReady()
    Assert.equal(game:snapshot().mapSymbol, MAP, "the battle returns to the map it launched from")
    Assert.isTrue(
      game.runtime.monService:partyCount() >= 1,
      "the live party survives the round trip"
    )
    local taskResult = BattleTask.result({ launchId = launch.id })
    Assert.isTrue(taskResult.committed, "the script continuation resumes on the committed result")
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
