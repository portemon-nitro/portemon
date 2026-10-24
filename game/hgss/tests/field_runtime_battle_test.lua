-- Field runtime battle ownership: explicit launches run the application
-- lifetime to commit and return, failed battles fault loudly instead of
-- resuming the story, prepared encounters are consumed exactly once, and
-- only one battle runs at a time. Most of the suite drives the runtime
-- through a focused composition fake; the two boot witnesses below
-- construct the real cache-backed runtime and prove field boot serves live
-- encounters and launches generated trainers through public behavior before
-- any field step or launch can ask for battle work.

local Assert = require("tests.support.Assert")
local FieldRuntimeFixture = require("tests.support.FieldRuntimeFixture")
local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldOverworldLifecycle = require("libs.hgss.src.field.FieldOverworldLifecycle")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldBattleCoordinator = require("game.hgss.src.field.FieldBattleCoordinator")
local GameVersion = require("romdump.src.source.GameVersion")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local RomImporter = require("romdump.src.source.RomImporter")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

local function headlessPort(record)
  return {
    enter = function(_)
      record.enters = record.enters + 1
      return true
    end,
    -- The five-operation port delivers detached packets; the fake
    -- unwraps their ordered events so kernel-event probes keep reading
    -- the same payloads.
    present = function(packet)
      for _, event in ipairs(packet.events) do
        record.frames[#record.frames + 1] = event
      end
    end,
    ready = function()
      return true
    end,
    leave = function(_)
      record.leaves = record.leaves + 1
      return true
    end,
    dispose = function()
      record.disposed = record.disposed + 1
    end,
  }
end

local function fakeRuntime(overrides)
  local battleFlags = {}
  local runtime = FieldRuntimeFixture.withApricornDateOwner(setmetatable({
    battleRuntime = nil,
    _battleLaunch = nil,
    _battleReceipts = {},
    overworld = FieldOverworldLifecycle.new(),
    battlePresentation = nil,
    pendingEncounterId = nil,
    pendingEncounter = nil,
    _lastBattleResult = nil,
    _encounters = nil,
    _launchCounter = nil,
    monService = {
      partyRevision = function()
        return 7
      end,
    },
    session = {
      setBattleActive = function(_, active)
        battleFlags[#battleFlags + 1] = active
      end,
    },
    scripts = {
      worldState = {
        rng = {
          nextRaw = function()
            return 0
          end,
        },
      },
    },
    localClock = {
      nowLocal = function()
        return { year = 2026, month = 10, day = 9, hour = 12 }
      end,
    },
    -- Presented launches read the player narration pace and the profile
    -- gender; production boot always composes both, so the composition
    -- fake carries them too.
    playerData = { options = { textSpeed = "mid", textFrame = 0 }, profile = CatalogFixture.profile() },
  }, FieldRuntime))
  for key, value in pairs(overrides or {}) do
    runtime[key] = value
  end
  local coordinator = FieldBattleCoordinator.new(runtime)
  for _, key in ipairs({
    "battleRuntime",
    "battlePresentation",
    "_battleLaunch",
    "_battleReceipt",
    "_lastBattleResult",
    "_battlePresentationFactory",
    "_battlePresentationBindingId",
    "_battlePresentationWithdrawn",
  }) do
    coordinator[key] = runtime[key]
    runtime[key] = nil
  end
  runtime.battleCoordinator = coordinator
  return runtime, battleFlags
end

local function wildScenario()
  return ScenarioFactory.fromEncounter({ species = "TOTODILE", level = 4 }, {})
end

---@param record table full mon-domain record under test preparation
---@return table the same record striking with a single known move
local function tackleOnly(record)
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

---@param species string
---@param level integer
---@param seed integer
---@return table full mon-domain record
local function foeRecord(species, level, seed)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  return tackleOnly(factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level })))
end

---@return table party owner holding one fixed lead
local function newPartyOwner(lead, catalog)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  catalog = catalog or CatalogFixture.makeCatalog()
  local owner = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture()),
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
  Assert.isTrue(
    owner:addMon(lead or foeRecord("CHIKORITA", 5, 0x33333333)),
    "the owned lifetime needs its live party lead"
  )
  return owner
end

local function catalogWithTrick()
  local Catalog = require("libs.mons.src.MonCatalog")
  local root = CatalogFixture.buildAssetRoot()
  local trick = {}
  for key, value in pairs(root.moves.TACKLE) do
    trick[key] = value
  end
  trick.nativeId = 271
  trick.name = "Trick"
  root.moves.TRICK = trick
  return Catalog.new(root, CatalogFixture.makeItemCatalog())
end

local function wildRequest(id)
  return { id = id or "launch-field-1", kind = "wild", payload = { species = "TOTODILE", level = 4 } }
end

local function driveToSettled(runtime, battle, firstMoveSlot, laterMoveSlot)
  local ticks = 0
  local submittedAction = false
  while battle:status().phase ~= "complete" and battle:status().phase ~= "failed" and ticks < 200 do
    runtime:updateBattle()
    battle = runtime.battleCoordinator:activeBattle() or battle
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      local choices = {}
      for _, actor in ipairs(current.request.actors) do
        local moveSlot = submittedAction and laterMoveSlot or firstMoveSlot
        choices[#choices + 1] = SessionFixture.attackChoice(actor, moveSlot or 0, SessionFixture.positionTarget(2))
      end
      local accepted, err = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "field-driven decisions answer: " .. tostring(err))
      submittedAction = true
    end
    ticks = ticks + 1
  end
  return battle:status()
end

function T.startBattle_commits_trick_held_item_exchange_to_the_party()
  local catalog = catalogWithTrick()
  local playerFactory = CatalogFixture.makeFactory(0x33333333, catalog)
  local player = playerFactory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA", level = 5 }))
  player.moves = {
    { move = "TRICK", pp = 10, ppUps = 0 },
    { move = "TACKLE", pp = 35, ppUps = 0 },
  }
  player.heldItem = "SITRUS_BERRY"
  local party = newPartyOwner(player, catalog)
  local runtime = fakeRuntime({ monService = party })
  local foe = foeRecord("TOTODILE", 4, 0x5EED0004)
  foe.heldItem = "CHERI_BERRY"
  local request = { id = "launch-trick-items", kind = "wild", payload = { species = "TOTODILE", level = 4, mon = foe } }
  local scenario = ScenarioFactory.fromEncounter(
    request.payload,
    { party = party, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = runtime:startBattle({ request = request, scenario = scenario, presentation = headlessPort(portRecord) })

  local finished = driveToSettled(runtime, battle, 0, 1)

  Assert.equal(finished.phase, "complete")
  local swapped = false
  for _, event in ipairs(portRecord.frames) do
    if event.kind == "item-intent" and event.cause.key == "TRICK" then
      swapped = true
    end
  end
  Assert.isTrue(swapped, "the production move path executes Trick")
  Assert.equal(party:partyMon(0).heldItem, "CHERI_BERRY", "BattleRuntime commits the received held item")
end

function T.startBattle_runs_the_owned_lifetime_to_commit_and_return()
  local party = newPartyOwner()
  local runtime, battleFlags = fakeRuntime({ monService = party })
  local portRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local foe = foeRecord("TOTODILE", 4, 0x5EED0004)
  local request = { id = "launch-field-1", kind = "wild", payload = { species = "TOTODILE", level = 4, mon = foe } }
  -- The lifetime now runs through knockout rewards under the corrected
  -- battle laws, so the scenario carries the same detached player
  -- identity the resolution suites use.
  local scenario = ScenarioFactory.fromEncounter(
    request.payload,
    { party = party, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local battle = runtime:startBattle({
    request = request,
    scenario = scenario,
    presentation = headlessPort(portRecord),
  })
  Assert.isTrue(battleFlags[1], "launch freezes player input")
  local finished = driveToSettled(runtime, battle)
  Assert.equal(finished.phase, "complete")
  Assert.notNil(finished.outcomeReceipt)
  Assert.isTrue(finished.outcomeReceipt.committed)
  Assert.isNil(runtime.battleCoordinator:activeBattle(), "settlement releases the owned lifetime")
  Assert.isFalse(battleFlags[#battleFlags], "return releases player input")
  Assert.notNil(runtime:lastBattleResult(), "completion records its outcome words")
  Assert.equal(portRecord.disposed, 1)
end

function T.presented_battle_scenario_receives_the_captured_map_terrain()
  local runtime = fakeRuntime()
  local request = wildRequest("launch-terrain")
  local scenario = wildScenario()
  scenario.environment.weather = "rain"
  runtime.battleCoordinator._battleLaunch = {
    request = request,
    environment = { terrain = "grass" },
  }

  local battle = runtime:startBattle({ request = request, scenario = scenario })

  Assert.equal(battle._scenario.environment.terrain, "grass", "battle rules use the launch's map terrain")
  Assert.equal(battle._scenario.environment.weather, "rain", "encounter weather remains in the scenario")
  Assert.isNil(scenario.environment.terrain, "launch terrain does not mutate the caller's scenario")
end

function T.startBattle_rejects_a_second_launch_and_failed_battles_fault()
  local runtime = fakeRuntime()
  runtime:startBattle({ request = wildRequest("launch-a"), scenario = wildScenario() })
  Assert.isTrue(not pcall(runtime.startBattle, runtime, {
    request = wildRequest("launch-b"),
    scenario = wildScenario(),
  }), "only one battle runs at a time")

  local failedRuntime = fakeRuntime()
  local broken = failedRuntime:startBattle({ request = wildRequest("launch-broken"), scenario = {} })
  Assert.notNil(broken)
  local ok, failure
  for _ = 1, 10 do
    ok, failure = pcall(failedRuntime.updateBattle, failedRuntime)
    if not ok then
      break
    end
  end
  Assert.equal(broken:status().phase, "failed")
  Assert.isNil(failedRuntime.battleCoordinator:activeBattle(), "failures release the owned lifetime")
  Assert.isFalse(ok, "failed battles reach LÖVE's callback error handler")
  Assert.notNil(failure)
end

function T.host_launch_issues_unique_identities_and_reports_status()
  local runtime = fakeRuntime()
  local first = runtime:launchBattle({ kind = "wild", details = { species = "TOTODILE", level = 4 } })
  local secondLaunchFails = not pcall(runtime.launchBattle, runtime, {
    kind = "wild",
    details = { species = "TOTODILE", level = 4 },
  })
  Assert.isTrue(secondLaunchFails, "a running battle refuses its successor")
  Assert.isTrue(type(first) == "string" and first ~= "")
  local status = runtime:battleStatus(first)
  Assert.notNil(status)
  Assert.equal(status.phase, "leaving")
  Assert.isNil(runtime:battleStatus("no-such-launch"))
  for _ = 1, 10 do
    runtime.overworld:updateFixed()
    runtime:updateBattle()
  end
  local running = runtime:battleStatus(first)
  Assert.isTrue(running.phase == "active" or running.phase == "entering" or running.phase == "running")
end

function T.host_launch_identities_are_unique_across_runtime_instances()
  local firstRuntime = fakeRuntime()
  local secondRuntime = fakeRuntime()
  local first = firstRuntime:launchBattle({ kind = "wild", details = {} })
  local second = secondRuntime:launchBattle({ kind = "wild", details = {} })
  Assert.isTrue(first ~= second, "a later runtime cannot reuse a process-wide receipt identity")
end

function T.host_status_waits_for_the_native_lifecycle_boundary_by_outcome()
  local successful = { "win", "capture", "flee" }
  local absentOutcomes = { "loss", "draw" }

  local function runtimeFor(result)
    local phase = "absent"
    local overworld = {
      phase = function()
        return phase
      end,
      requestRestore = function()
        phase = "restoring"
      end,
      updateFixed = function()
        if phase == "restoring" then
          phase = "present"
        end
      end,
    }
    local runtime = fakeRuntime({ overworld = overworld })
    runtime.battleCoordinator._battleLaunch = { launchId = "matrix-" .. result, phase = "active" }
    runtime.battleCoordinator.battleRuntime = {
      update = function() end,
      dispose = function() end,
      status = function()
        return {
          phase = "complete",
          result = result,
          sourceResult = 1,
          outcomeReceipt = { committed = true },
        }
      end,
    }
    return runtime, overworld
  end

  for _, result in ipairs(absentOutcomes) do
    local runtime = runtimeFor(result)
    runtime:updateBattle()
    local status = runtime:battleStatus("matrix-" .. result)
    Assert.isTrue(status.committed, result .. " publishes after disposal while absent")
    Assert.equal(status.result, result)
  end

  for _, result in ipairs(successful) do
    local runtime, overworld = runtimeFor(result)
    runtime:updateBattle()
    local pending = runtime:battleStatus("matrix-" .. result)
    Assert.isFalse(pending.committed, result .. " remains pending while restore is in progress")
    overworld:updateFixed()
    runtime:updateBattle()
    local complete = runtime:battleStatus("matrix-" .. result)
    Assert.isTrue(complete.committed, result .. " publishes only after restore")
    Assert.equal(complete.result, result)
  end
end

function T.host_application_failure_never_publishes_a_battle_result()
  local runtime = fakeRuntime({ overworld = {
    phase = function()
      return "absent"
    end,
  } })
  runtime.battleCoordinator._battleLaunch = { launchId = "matrix-failure", phase = "active" }
  runtime.battleCoordinator.battleRuntime = {
    update = function() end,
    dispose = function() end,
    status = function()
      return { phase = "failed", error = "battle application failed" }
    end,
  }
  local ok, failure = pcall(runtime.updateBattle, runtime)
  local status = runtime:battleStatus("matrix-failure")
  Assert.isFalse(status.committed, "a failure has no committed battle result")
  Assert.notNil(status.error, "the task host retains the application failure")
  Assert.isFalse(ok, "the battle application failure reaches LÖVE's callback error handler")
  Assert.equal(tostring(failure), "battle application failed")
end

function T.complete_battle_without_committed_receipt_fails_in_both_field_modes()
  local function runtimeFor(presented)
    local disposed = 0
    local runtime = fakeRuntime({
      battleRuntime = {
        update = function() end,
        dispose = function()
          disposed = disposed + 1
        end,
        status = function()
          return { phase = "complete", result = "win", sourceResult = 1 }
        end,
      },
      session = {
        setBattleActive = function() end,
        setForegroundHold = function() end,
      },
    })
    runtime.battleCoordinator._battleLaunch = {
      launchId = "uncommitted-" .. tostring(presented),
      phase = "active",
      presented = presented,
      request = { id = "uncommitted-" .. tostring(presented) },
    }
    return runtime, function()
      return disposed
    end
  end

  local headless, headlessDisposals = runtimeFor(false)
  local headlessOk = pcall(headless.updateBattle, headless)
  Assert.isFalse(headlessOk, "headless completion without a receipt raises")
  Assert.equal(headlessDisposals(), 1, "headless failure disposes the battle once")
  Assert.isNil(headless.battleCoordinator:activeBattle(), "headless failure releases the battle owner")
  Assert.notNil(headless.battleCoordinator._battleReceipt, "headless failure remains visible to its caller")
  Assert.isNil(headless.battleCoordinator._battleLaunch, "headless failure releases the launch")

  local direct, directDisposals = runtimeFor(false)
  direct.battleCoordinator._battleLaunch = nil
  Assert.isFalse(pcall(direct.updateBattle, direct), "a direct headless battle also requires commitment")
  Assert.equal(directDisposals(), 1, "direct failure disposes the battle once")

  local presented = runtimeFor(true)
  local presentedOk, presentedErr = pcall(presented.updateBattle, presented)
  Assert.isFalse(presentedOk, "presented completion without a receipt raises")
  Assert.isTrue(
    tostring(presentedErr):find("without a committed outcome receipt", 1, true) ~= nil,
    "the presented failure names its cause: " .. tostring(presentedErr)
  )
end

-- Presented launch failures fault the runtime with their original cause:
-- a reported battle failure, an unaccepted completion, and a construction
-- failure under cover each raise instead of parking a failed launch.
function T.presented_failures_fault_with_their_original_cause()
  local function presentedRuntime(launch, battle)
    local runtime = fakeRuntime({
      session = {
        setBattleActive = function() end,
        setForegroundHold = function() end,
      },
      overworld = {
        phase = function()
          return "absent"
        end,
      },
    })
    runtime.battleCoordinator._battleLaunch = launch
    runtime.battleCoordinator.battleRuntime = battle
    return runtime
  end
  local function assertRaises(runtime, cause, label)
    local ok, err = pcall(runtime.updateBattle, runtime)
    Assert.isFalse(ok, label .. " faults the runtime")
    Assert.isTrue(tostring(err):find(cause, 1, true) ~= nil, label .. " keeps its cause: " .. tostring(err))
  end

  assertRaises(
    presentedRuntime({ launchId = "reported#1", phase = "active", presented = true, request = { id = "reported#1" } }, {
      update = function() end,
      dispose = function() end,
      status = function()
        return { phase = "failed", error = "the wild battle collapsed" }
      end,
    }),
    "the wild battle collapsed",
    "a reported battle failure"
  )
  assertRaises(
    presentedRuntime(
      { launchId = "unaccepted#1", phase = "active", presented = true, request = { id = "unaccepted#1" } },
      {
        update = function() end,
        dispose = function() end,
        status = function()
          return { phase = "complete", result = "win", sourceResult = 1 }
        end,
      }
    ),
    "without a committed outcome receipt",
    "an unaccepted completion"
  )
  local constructing = presentedRuntime({
    launchId = "construction#1",
    phase = "leaving",
    presented = true,
    request = { id = "construction#1", kind = "wild", payload = {} },
  }, nil)
  constructing.buildBattleScenario = function()
    error("probe-construction-boom", 0)
  end
  assertRaises(constructing, "probe-construction-boom", "a construction failure")
end

function T.prepared_encounters_are_consumed_exactly_once()
  local prepared = {
    id = 11,
    mons = { { mon = { species = "TOTODILE", level = 4 }, source = nil } },
    format = "wild-single",
    environment = { weather = "none" },
  }
  local consumed = {}
  local service = {
    attempt = function(_, _, _)
      return { kind = "prepared", attemptId = 11, encounter = prepared }
    end,
    consume = function(_, attemptId)
      consumed[#consumed + 1] = attemptId
      return prepared
    end,
  }
  local runtime = fakeRuntime({ _encounters = service, runtimeMap = { mapId = 11, mapSectionNativeId = 7 } })
  local result = runtime:attemptEncounter({ method = "grass" })
  Assert.equal(result.kind, "prepared")
  Assert.equal(runtime.pendingEncounterId, 11)
  Assert.isTrue(runtime:cancelPendingEncounter(), "a held preparation releases")
  Assert.deepEqual(consumed, { 11 }, "release consumes without rerolling")
  Assert.isNil(runtime.pendingEncounterId)
  Assert.isFalse(runtime:cancelPendingEncounter(), "release without a hold reports itself")

  runtime:attemptEncounter({ method = "grass" })
  local battle = runtime:startBattle({
    request = { id = "launch-pending", kind = "wild", payload = { species = "TOTODILE", level = 4 } },
  })
  Assert.deepEqual(consumed, { 11, 11 }, "launch consumes the held preparation")
  Assert.isNil(runtime.pendingEncounterId)
  Assert.equal(battle:status().phase, "preparing")
end

function T.attempts_wait_while_a_battle_or_preparation_owns_the_field()
  local attempts = 0
  local service = {
    attempt = function()
      attempts = attempts + 1
      return { kind = "miss", reason = "no_opportunity" }
    end,
  }
  local runtime = fakeRuntime({ _encounters = service, runtimeMap = { mapId = 11, mapSectionNativeId = 7 } })
  runtime:attemptEncounter({})
  Assert.equal(attempts, 1)
  runtime.pendingEncounterId = 9
  runtime.pendingEncounter = {}
  runtime:attemptEncounter({})
  Assert.equal(attempts, 1, "a held preparation skips further attempts")
  runtime.pendingEncounterId = nil
  runtime.pendingEncounter = nil
  runtime.battleCoordinator.battleRuntime = {}
  runtime:attemptEncounter({})
  Assert.equal(attempts, 1, "an active battle skips attempts")
  runtime.battleCoordinator.battleRuntime = nil
  runtime.battleCoordinator._battleLaunch = { launchId = "launch-covering", phase = "covering" }
  runtime:attemptEncounter({})
  Assert.equal(attempts, 1, "an in-progress launch skips attempts without sampling")
  runtime.battleCoordinator._battleLaunch = nil
  Assert.isNil(fakeRuntime()._encounters, "an absent service attempts nothing")
  local quiet = fakeRuntime()
  Assert.isNil(quiet:attemptEncounter({}), "an absent service attempts nothing")
end

function T.committed_steps_resolve_their_map_table_member()
  local seen = {}
  local service = {
    attempt = function(_, context, _)
      seen[#seen + 1] = context
      return { kind = "miss", reason = "no_opportunity" }
    end,
  }
  local runtime = fakeRuntime({
    _encounters = service,
    player = { fieldX = 665, fieldZ = 404 },
    playerData = { profile = {} },
    session = {
      setBattleActive = function() end,
      tick = 7,
      takeCommittedStep = function()
        return { serial = 1, fieldX = 665, fieldZ = 404 }
      end,
      mapEntryController = {
        isActive = function()
          return false
        end,
      },
      dialogue = {
        isModal = function()
          return false
        end,
      },
      currentMap = {
        mapId = 16,
        mapSectionNativeId = 77,
        coordinateOrigin = { x = 0, z = 0 },
        collision = {
          containsLocal = function()
            return true
          end,
          getLocal = function()
            return { behavior = 2 }
          end,
        },
        fieldData = { wildEncounterMemberId = 1 },
      },
    },
  })
  runtime:_consumeCommittedStep()
  Assert.equal(#seen, 1, "the committed step attempts once")
  Assert.equal(seen[1].mapId, 1, "the attempt resolves the map's table member, not its map identity")
end

-- The arrival tile selects the encounter method from terrain and travel
-- mode: source encounter land (tall grass and cave floors alike) walks
-- the grass tables, surfable encounter water surfs them only while
-- surfing, and standing water, dry ineligible tiles, or an unreadable
-- arrival never rolls. Cave floors are land: walking them must not be
-- silently suppressed while walking onto water must never read grass.
local function arrivalMapWithBehavior(cell)
  return {
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function()
        return cell.behavior ~= nil
      end,
      getLocal = function()
        return { behavior = cell.behavior }
      end,
    },
  }
end

local function walkingRuntime()
  return fakeRuntime({ playerAvatar = nil })
end

local function surfingRuntime()
  return fakeRuntime({
    playerAvatar = {
      status = function()
        return { durableState = "surfing" }
      end,
    },
  })
end

function T.walking_steps_use_grass_on_land_and_never_on_water()
  local runtime = walkingRuntime()
  local player = { fieldX = 665, fieldZ = 404 }
  local land = { 2, 3, 5, 8, 11, 37, 114, 119, 123, 166, 167 }
  for _, behavior in ipairs(land) do
    local cell = { behavior = behavior }
    Assert.equal(
      runtime:_stepEncounterMethod(arrivalMapWithBehavior(cell), player),
      "grass",
      "walking behavior " .. behavior .. " walks the grass tables"
    )
  end
  local water = { 16, 18, 21, 42 }
  for _, behavior in ipairs(water) do
    local cell = { behavior = behavior }
    Assert.isNil(
      runtime:_stepEncounterMethod(arrivalMapWithBehavior(cell), player),
      "walking behavior " .. behavior .. " never reads grass"
    )
  end
  for _, behavior in ipairs({ 0, 1, 4, 32, 105, 255 }) do
    local cell = { behavior = behavior }
    Assert.isNil(
      runtime:_stepEncounterMethod(arrivalMapWithBehavior(cell), player),
      "ineligible behavior " .. behavior .. " attempts nothing on foot"
    )
  end
  Assert.isNil(
    runtime:_stepEncounterMethod(arrivalMapWithBehavior({ behavior = nil }), player),
    "an unreadable arrival attempts nothing on foot"
  )
end

function T.surfing_steps_use_surf_only_on_encounter_water()
  local runtime = surfingRuntime()
  local player = { fieldX = 665, fieldZ = 404 }
  for _, behavior in ipairs({ 16, 18, 21, 42 }) do
    local cell = { behavior = behavior }
    Assert.equal(
      runtime:_stepEncounterMethod(arrivalMapWithBehavior(cell), player),
      "surf",
      "surfing behavior " .. behavior .. " surfs the water tables"
    )
  end
  for _, behavior in ipairs({ 2, 3, 8, 17, 1 }) do
    local cell = { behavior = behavior }
    Assert.isNil(
      runtime:_stepEncounterMethod(arrivalMapWithBehavior(cell), player),
      "surfing behavior " .. behavior .. " attempts no encounter"
    )
  end
end

-- A committed cave-floor step reaches the encounter service through the
-- grass method exactly once; stepping onto water on foot never draws an
-- opportunity, and a held preparation or a modal field consumes the step
-- without a second draw.
local function steppingRuntime(overrides)
  local base = {
    _encounters = overrides.service,
    player = { fieldX = 665, fieldZ = 404 },
    playerData = { profile = {} },
    session = {
      setBattleActive = function() end,
      tick = 7,
      takeCommittedStep = function()
        return { serial = 1, fieldX = 665, fieldZ = 404 }
      end,
      mapEntryController = {
        isActive = function()
          return (overrides.mapEntry or false)
        end,
      },
      dialogue = {
        isModal = function()
          return (overrides.modal or false)
        end,
      },
      currentMap = {
        mapId = 16,
        mapSectionNativeId = 77,
        coordinateOrigin = { x = 0, z = 0 },
        collision = {
          containsLocal = function()
            return true
          end,
          getLocal = function()
            return { behavior = overrides.behavior }
          end,
        },
        fieldData = { wildEncounterMemberId = 1 },
      },
    },
  }
  if overrides.pending == true then
    base.pendingEncounterId = 9
    base.pendingEncounter = {}
  end
  return fakeRuntime(base)
end

function T.cave_floor_steps_attempt_the_grass_tables_once()
  local seen = {}
  local service = {
    attempt = function(_, context, _)
      seen[#seen + 1] = context
      return { kind = "miss", reason = "no_opportunity" }
    end,
  }
  steppingRuntime({ service = service, behavior = 8 }):_consumeCommittedStep()
  Assert.equal(#seen, 1, "the cave-floor step attempts once")
  Assert.equal(seen[1].method, "grass", "cave floors walk the grass tables")
  Assert.equal(seen[1].mapId, 1, "the cave attempt keeps the map table member")
end

function T.water_modal_and_held_steps_draw_no_opportunity()
  local draws = 0
  local service = {
    attempt = function()
      draws = draws + 1
      return { kind = "miss", reason = "no_opportunity" }
    end,
  }
  steppingRuntime({ service = service, behavior = 16 }):_consumeCommittedStep()
  Assert.equal(draws, 0, "stepping onto water on foot draws nothing")
  steppingRuntime({ service = service, behavior = 8, modal = true }):_consumeCommittedStep()
  Assert.equal(draws, 0, "a modal field draws nothing")
  steppingRuntime({ service = service, behavior = 8, mapEntry = true }):_consumeCommittedStep()
  Assert.equal(draws, 0, "a map entry draws nothing")
  steppingRuntime({ service = service, behavior = 8, pending = true }):_consumeCommittedStep()
  Assert.equal(draws, 0, "a held preparation draws nothing further")
  steppingRuntime({ service = service, behavior = 2 }):_consumeCommittedStep()
  Assert.equal(draws, 1, "the next eligible step draws exactly once")
end

-- A bare species/level foe records the live native section and the host
-- clock date instead of the numeric map identity and a fixed placeholder.
function T.descriptor_foes_record_the_live_section_and_clock_date()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local ScriptRng = require("libs.hgss.src.script.ScriptRng")
  local runtime = fakeRuntime({
    versionId = "heartgold",
    monLanguage = "english",
    monCatalog = CatalogFixture.makeCatalog(),
    itemCatalog = ItemFixture.makeCatalog(),
    cacheFs = {
      loadLua = function(_)
        return { schema = FieldFontCache.SCHEMA, charmap = CatalogFixture.CHARMAP }
      end,
    },
    playerData = { profile = CatalogFixture.profile() },
    session = {
      setBattleActive = function() end,
      currentMap = { mapId = 16, mapSectionNativeId = 77 },
    },
    scripts = { worldState = { rng = ScriptRng.new(1234) } },
    localClock = {
      nowLocal = function()
        return { year = 2026, month = 10, day = 9, hour = 12 }
      end,
    },
  })
  local foe = runtime:_materializeDescriptorFoe({ species = "TOTODILE", level = 4 })
  Assert.notNil(foe, "the descriptor materializes through its composed catalogs")
  local met = assert(foe.met, "materialized foes carry their origin record")
  Assert.equal(met.location, 77, "the foe records the native section, not the numeric map identity")
  Assert.deepEqual(
    { year = met.date.year, month = met.date.month, day = met.date.day },
    { year = 2026, month = 10, day = 9 },
    "the foe records the host clock date, not a placeholder"
  )
  Assert.equal(met.terrain, 0, "neutral terrain stays until a sourced mapping exists")
  Assert.equal(foe.species, "TOTODILE")
  Assert.equal(met.level, 4)
end

-- Ordinary step attempts keep their encounter-table lookup while the
-- prepared mon records the live section and host clock date. Direct
-- service use without that context keeps its neutral record.
function T.field_attempts_keep_their_lookup_while_recording_live_provenance()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local EncounterFixture = require("libs.hgss.tests.encounter_fixture")
  local Errors = require("libs.errors.src.Errors")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local ScriptRng = require("libs.hgss.src.script.ScriptRng")

  local function liveService()
    local Catalog = EncounterFixture.requirePresent(
      "libs.hgss.src.encounters.HgssEncounterCatalog",
      "validated encounter-table lookup owns ordered slots"
    )
    local Service = EncounterFixture.requirePresent(
      "libs.hgss.src.encounters.HgssEncounterService",
      "encounter opportunity and retained preparation"
    )
    local WildMonFactory = EncounterFixture.requirePresent(
      "libs.hgss.src.encounters.WildMonFactory",
      "source wild identity and held-item generation"
    )
    return Service.new({
      catalog = Catalog.new(EncounterFixture.vectorCatalog()),
      wildFactory = WildMonFactory.new({
        catalog = CatalogFixture.makeCatalog(),
        items = ItemFixture.makeCatalog(),
        charmap = CatalogFixture.CHARMAP,
        games = CatalogFixture.GAMES,
        languages = CatalogFixture.LANGUAGES,
        game = "soulsilver",
        language = "english",
      }),
    })
  end

  local function attemptContext()
    return {
      eventId = 1,
      mapId = 11,
      method = "grass",
      movement = "step",
      modifiers = EncounterFixture.modifiers(),
      environment = { weather = "none" },
      timeOfDay = "day",
      playerProfile = CatalogFixture.profile(),
    }
  end

  local function liveField(seed)
    local service = liveService()
    local worldRng = ScriptRng.new(seed)
    local runtime = fakeRuntime({
      _encounters = service,
      playerData = { profile = CatalogFixture.profile() },
      session = {
        setBattleActive = function() end,
        currentMap = { mapId = 16, mapSectionNativeId = 77 },
      },
      scripts = { worldState = { rng = worldRng } },
      localClock = {
        nowLocal = function()
          return { year = 2026, month = 10, day = 9, hour = 12 }
        end,
      },
    })
    return runtime, service, worldRng
  end

  local runtime, _, _ = liveField(99)
  local context = attemptContext()
  local result = runtime:attemptEncounter(context)
  Assert.notNil(result, "the field attempt answers through its composed service")
  Assert.equal(result.kind, "prepared", "the eligible step prepares its encounter")
  local prepared = assert(result.encounter, "prepared attempts carry their encounter")
  local fieldMon = assert(prepared.mons[1].mon, "the encounter carries its wild mon")
  Assert.equal(prepared.provenance.mapId, 11, "selection still reads table 11")
  Assert.equal(fieldMon.met.location, 77, "the prepared mon records the native section, not the table member")
  Assert.deepEqual(
    { year = fieldMon.met.date.year, month = fieldMon.met.date.month, day = fieldMon.met.date.day },
    { year = 2026, month = 10, day = 9 },
    "the prepared mon records the host clock date, not a placeholder"
  )
  Assert.equal(fieldMon.met.terrain, 0, "neutral terrain stays until a sourced mapping exists")
  Assert.equal(context.mapId, 11, "the lookup identity rides through unchanged")
  Assert.isNil(context.met, "the field stages its own copy instead of mutating the caller")

  local authoredRuntime, _, _ = liveField(99)
  local authored = attemptContext()
  authored.met = { location = 5, date = { year = 2024, month = 2, day = 29 } }
  local authoredResult = authoredRuntime:attemptEncounter(authored)
  Assert.equal(authoredResult.kind, "prepared", "an authored record still prepares")
  local authoredMon = assert(authoredResult.encounter.mons[1].mon, "the encounter carries its wild mon")
  Assert.equal(authoredMon.met.location, 5, "an explicitly supplied record is never overwritten")
  Assert.deepEqual({
    year = authoredMon.met.date.year,
    month = authoredMon.met.date.month,
    day = authoredMon.met.date.day,
  }, { year = 2024, month = 2, day = 29 }, "an explicitly supplied date is never overwritten")

  local rejectedRuntime, _, rejectedRng = liveField(99)
  local rejected = attemptContext()
  rejected.met = { location = -1, date = { year = 2026, month = 10, day = 9 } }
  local drawsBefore = rejectedRng:serialize().calls
  local failure = Assert.throws(function()
    rejectedRuntime:attemptEncounter(rejected)
  end, "an invalid supplied record fails")
  Assert.isTrue(Errors.is(failure), "rejection uses the structured error path")
  Assert.equal(assert(failure).code, "ENCOUNTER_INVALID_INPUT", "rejection names its contract")
  Assert.equal(rejectedRng:serialize().calls, drawsBefore, "rejected input consumes no draws")
  Assert.isNil(rejectedRuntime.pendingEncounterId, "rejected input holds no preparation")

  local headless = liveService()
  local headlessRng = ScriptRng.new(99)
  local headlessStream = {
    nextU16 = function(_, _, _)
      return headlessRng:nextRaw() % 65536
    end,
  }
  local headlessResult = headless:attempt(attemptContext(), headlessStream)
  Assert.equal(headlessResult.kind, "prepared", "the same draws prepare without field context")
  local headlessMon = assert(headlessResult.encounter.mons[1].mon, "the encounter carries its wild mon")
  Assert.equal(headlessMon.species, fieldMon.species, "the lookup selects the same species")
  Assert.equal(headlessMon.personality, fieldMon.personality, "identical draws generate the identical mon")
  Assert.equal(headlessMon.met.location, 11, "callers without context keep the neutral record")
  Assert.deepEqual({
    year = headlessMon.met.date.year,
    month = headlessMon.met.date.month,
    day = headlessMon.met.date.day,
  }, { year = 2000, month = 1, day = 1 }, "callers without context keep the neutral date")
end

-- The token-guarded per-launch factory binding: one owner, monotonic
-- identities, and stale unbinds never detach a replacement.
function T.battle_presentation_binding_rejects_stale_teardown()
  local runtime = fakeRuntime()
  local first = runtime:bindBattlePresentation(function(_)
    return headlessPort({ enters = 0, frames = {}, leaves = 0, disposed = 0 })
  end)
  Assert.isTrue(type(first) == "number", "binding issues an identity")
  Assert.isTrue(not pcall(runtime.bindBattlePresentation, runtime, function(_) end), "one binding owns the lifetime")
  runtime:unbindBattlePresentation(first + 1)
  Assert.notNil(runtime.battleCoordinator._battlePresentationFactory, "a stale unbind never drops the owner")
  runtime:unbindBattlePresentation(first)
  Assert.isNil(runtime.battleCoordinator._battlePresentationFactory, "the matching unbind releases")
  runtime:unbindBattlePresentation(first)
  local second = runtime:bindBattlePresentation(function(_)
    return headlessPort({ enters = 0, frames = {}, leaves = 0, disposed = 0 })
  end)
  Assert.isTrue(second ~= first, "identities never recycle across bindings")
end

function T.disposed_field_ignores_retained_battle_callbacks()
  local runtime = fakeRuntime()
  local sessionCalls = 0
  local retainedHost
  runtime.session = {
    dispose = function() end,
    setBattleActive = function()
      sessionCalls = sessionCalls + 1
    end,
    setForegroundHold = function()
      sessionCalls = sessionCalls + 1
    end,
  }
  runtime.input = { clearAll = function() end }
  runtime.menuComposer = { releaseModalHosts = function() end }
  runtime.battleCoordinator._captureLaunchEnvironment = function()
    return {}
  end
  runtime.battleCoordinator._battleMusicRole = function()
    return nil
  end
  runtime:bindBattlePresentation(function(descriptor)
    retainedHost = descriptor.host
    return {}
  end)

  local launchId = runtime:launchBattle({ kind = "wild", details = {} })
  Assert.isTrue(type(retainedHost) == "table", "the admitted launch gives the screen its callbacks")
  Assert.equal(retainedHost.status().phase, "covering", "the host observes the live launch")
  local callsBeforeDispose = sessionCalls

  runtime:dispose()

  Assert.isNil(retainedHost.status(), "a retained screen loses its launch after field disposal")
  local accepted, submitFailure = retainedHost.submit({})
  Assert.isFalse(accepted, "a disposed launch cannot accept a screen reply")
  Assert.notNil(submitFailure, "the stale reply has the existing rejection shape")
  Assert.isFalse(retainedHost.recoveryInput({ pressedAction = true }), "a disposed launch cannot accept recovery input")
  retainedHost.notify("cover-complete")
  retainedHost.advance()
  Assert.isNil(runtime:battleStatus(launchId), "stale callbacks publish no battle result")
  Assert.isNil(runtime:lastBattleResult(), "stale callbacks publish no latest result")
  Assert.equal(sessionCalls, callsBeforeDispose, "stale callbacks never reacquire disposed field state")
end

-- A factory failure fails the admission loudly with no partial claim:
-- no launch record, no input hold, no music claim, and no battle.
function T.presented_admission_fails_closed_without_a_port()
  local holds = {}
  local runtime = fakeRuntime({
    playerData = { options = { textSpeed = "mid", textFrame = 0 }, profile = CatalogFixture.profile() },
    session = {
      setBattleActive = function(_, active)
        holds[#holds + 1] = active
      end,
      setForegroundHold = function(_, _)
        error("no hold may precede a constructed port", 2)
      end,
      currentMap = { mapId = 61, fieldData = { battleBackground = "general" } },
    },
    input = {
      clearAll = function()
        error("no input may clear before a constructed port", 2)
      end,
    },
    player = { fieldX = 1, fieldZ = 2, surfaceId = 0 },
  })
  runtime:bindBattlePresentation(function(_)
    error("composition lost its screen", 0)
  end)
  local ok, err = pcall(runtime.launchBattle, runtime, {
    kind = "wild",
    details = { species = "TOTODILE", level = 4 },
  })
  Assert.isFalse(ok, "admission without a port fails loudly")
  Assert.isTrue(tostring(err):find("admission failed", 1) ~= nil, "the failure names the admission")
  Assert.isNil(runtime.battleCoordinator._battleLaunch, "no launch record impersonates a battle")
  Assert.isNil(runtime.battleCoordinator:activeBattle(), "no battle constructs without a port")
  Assert.deepEqual(holds, {}, "no input hold precedes a constructed port")
end

-- Launch environments resolve from compiled map facts and live avatar
-- state without consuming randomness: surfing overrides to ocean,
-- standing behavior selects terrain ahead of the background default,
-- indoor backgrounds pin day, and explicit request overrides ride along.
local function environmentRuntime(overrides)
  local base = {
    session = { currentMap = { mapId = 33, fieldData = { battleBackground = "general" } } },
    player = { fieldX = 5, fieldZ = 6, surfaceId = 0 },
    playerAvatar = {
      status = function()
        return { durableState = "walking" }
      end,
    },
    localClock = {
      nowLocal = function()
        return { hour = 12 }
      end,
    },
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return fakeRuntime(base)
end

function T.launch_environments_resolve_from_compiled_facts()
  local runtime = environmentRuntime()
  local environment = runtime.battleCoordinator:_captureLaunchEnvironment({ kind = "wild", payload = {} }, "grass")
  Assert.equal(environment.background, "general", "the compiled background resolves")
  Assert.equal(environment.terrain, "plain", "general defaults to plain without a behavior")
  Assert.equal(environment.time, "day", "midday reads day")
  Assert.equal(environment.sceneKey, "general/plain/day", "the scene key joins its facts")
  Assert.equal(environment.method, "grass", "the step method rides along")
end

function T.launch_environments_apply_the_surfing_override()
  local runtime = environmentRuntime({
    playerAvatar = {
      status = function()
        return { durableState = "surfing" }
      end,
    },
  })
  local environment = runtime.battleCoordinator:_captureLaunchEnvironment({ kind = "wild", payload = {} }, "surf")
  Assert.equal(environment.background, "ocean", "surfing overrides to ocean")
  Assert.equal(environment.sceneKey, "ocean/water/day", "surfing water selects its scene")
end

function T.launch_environments_pin_indoor_time_and_keep_overrides()
  local runtime = environmentRuntime({
    session = { currentMap = { mapId = 61, fieldData = { battleBackground = "building_1" } } },
    localClock = {
      nowLocal = function()
        return { hour = 22 }
      end,
    },
  })
  local environment = runtime.battleCoordinator:_captureLaunchEnvironment({
    kind = "trainer",
    payload = { trainer = "rival", environment = { weather = "none" } },
  }, nil)
  Assert.equal(environment.background, "building_1", "interiors resolve their background")
  Assert.equal(environment.time, "day", "indoor backgrounds pin day")
  Assert.equal(environment.terrain, "building", "buildings default to building")
  Assert.deepEqual(environment.sourceEnvironment, { weather = "none" }, "explicit overrides ride untouched")
end

function T.launch_environments_reject_unknown_scenes_loudly()
  local runtime = environmentRuntime({
    session = { currentMap = { mapId = 7, fieldData = { battleBackground = "moon" } } },
  })
  local ok, err = pcall(
    runtime.battleCoordinator._captureLaunchEnvironment,
    runtime.battleCoordinator,
    { kind = "wild", payload = {} },
    "grass"
  )
  Assert.isFalse(ok, "an unmapped background fails the launch")
  Assert.isTrue(tostring(err):find("unknown scene context", 1) ~= nil, "the failure names the scene")
end

-- The standing metatile behavior selects the battle terrain ahead of the
-- compiled map background default, in native standing-tile precedence
-- (retail ROM behavior): ice, tall
-- and very tall grass, sand, snow, marsh mud, cave floor, then the native
-- surfable-water flag set. Every classified scene key passes the staged
-- scene parser instead of falling back to the background default.
local function standingMap(background, behavior)
  return {
    mapId = 33,
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function()
        return true
      end,
      getLocal = function()
        return { behavior = behavior }
      end,
    },
    fieldData = { battleBackground = background },
  }
end

function T.standing_tile_behavior_selects_terrain_before_background_default()
  local cases = {
    { behavior = 32, terrain = "ice" },
    { behavior = 2, terrain = "grass" },
    { behavior = 3, terrain = "grass" },
    { behavior = 33, terrain = "sand" },
    { behavior = 168, terrain = "snow" },
    { behavior = 164, terrain = "great_marsh" },
    { behavior = 8, terrain = "cave" },
    { behavior = 16, terrain = "water" },
    { behavior = 17, terrain = "water" },
    { behavior = 18, terrain = "water" },
    { behavior = 19, terrain = "water" },
    { behavior = 20, terrain = "water" },
    { behavior = 21, terrain = "water" },
    { behavior = 25, terrain = "water" },
    { behavior = 42, terrain = "water" },
    { behavior = 80, terrain = "water" },
    { behavior = 81, terrain = "water" },
    { behavior = 82, terrain = "water" },
    { behavior = 83, terrain = "water" },
    { behavior = 115, terrain = "water" },
    { behavior = 120, terrain = "water" },
    { behavior = 124, terrain = "water" },
  }
  for _, case in ipairs(cases) do
    local runtime = environmentRuntime({
      session = { currentMap = standingMap("general", case.behavior) },
    })
    local environment = runtime.battleCoordinator:_captureLaunchEnvironment({ kind = "wild", payload = {} }, "grass")
    Assert.equal(environment.behavior, case.behavior, "the launch reports its standing behavior")
    Assert.equal(environment.background, "general", "the compiled background resolves")
    Assert.equal(
      environment.terrain,
      case.terrain,
      "standing behavior " .. case.behavior .. " selects " .. case.terrain
    )
    Assert.equal(environment.sceneKey, "general/" .. case.terrain .. "/day", "the classified tile joins its scene")
    Assert.notNil(
      BattlePresentationCache.parseSceneKey(environment.sceneKey),
      "the classified scene passes the staged scene parser"
    )
  end
  -- An explicit class beats the compiled background default: ice on a
  -- forest map reads ice, not the forest grass default.
  local forestRuntime = environmentRuntime({
    session = { currentMap = standingMap("forest", 32) },
  })
  local forest = forestRuntime.battleCoordinator:_captureLaunchEnvironment({ kind = "wild", payload = {} }, "grass")
  Assert.equal(forest.terrain, "ice", "the standing tile overrides the background default")
  Assert.equal(forest.sceneKey, "forest/ice/day", "the override joins its scene")
  Assert.notNil(
    BattlePresentationCache.parseSceneKey(forest.sceneKey),
    "the override scene passes the staged scene parser"
  )
end

-- Committed money adopts into the live wallet exactly once: the live profile
-- keeps its identity (scripts, mart, and the run gate borrow it, so a later
-- award must land in the saved record), and a second observation changes
-- nothing.
function T.committed_money_adopts_into_the_live_wallet_once()
  local runtime = fakeRuntime({
    playerData = { profile = { money = 3000 } },
  })
  local launch = {}
  local liveProfile = runtime.playerData.profile
  runtime.battleCoordinator:adoptCommittedPlayerMoney(launch, { player = { profile = { money = 2928 } } })
  Assert.equal(runtime.playerData.profile, liveProfile, "adoption mutates the borrowed live profile in place")
  Assert.equal(runtime.playerData.profile.money, 2928, "the debit reaches the live wallet")
  runtime.playerData.profile.money = 2928
  runtime.battleCoordinator:adoptCommittedPlayerMoney(launch, { player = { profile = { money = 2000 } } })
  Assert.equal(runtime.playerData.profile.money, 2928, "a second observation publishes nothing")
  local untouched = fakeRuntime({ playerData = { profile = { money = 3000 } } })
  untouched.battleCoordinator:adoptCommittedPlayerMoney({}, {})
  Assert.equal(untouched.playerData.profile.money, 3000, "a receipt without a candidate changes nothing")
end

-- A failed screen faults the runtime with its original error on the next
-- launch pump, before or after commitment; repeats keep the first cause
-- and stale identities are ignored.
function T.screen_failures_fault_the_runtime_with_the_first_cause()
  for _, phase in ipairs({ "active", "terminal" }) do
    local runtime = fakeRuntime({
      battleRuntime = {
        update = function() end,
        dispose = function() end,
        status = function()
          return { phase = "running" }
        end,
      },
    })
    local launchId = "screen-fail-" .. phase
    runtime.battleCoordinator._battleLaunch =
      { launchId = launchId, phase = phase, presented = true, request = { id = launchId } }
    runtime.battleCoordinator:_presentedNotify("stale#0", "screen-failed", "stale probe failure")
    runtime.battleCoordinator:_presentedNotify(launchId, "screen-failed", "probe screen failure")
    runtime.battleCoordinator:_presentedNotify(launchId, "screen-failed", "second probe failure")
    local ok, err = pcall(runtime.updateBattle, runtime)
    Assert.isFalse(ok, "a failed screen faults the runtime at " .. phase)
    Assert.equal(err, "probe screen failure", "the fault carries the first screen error at " .. phase)
  end
end

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

local function validEntry(versionId)
  local entry = {
    saveId = "save-00000001",
    versionId = versionId,
    location = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      facing = "south",
    },
    playerData = {
      profile = {
        name = "GOLD",
        gender = 0,
        trainerId = 1,
        money = 3000,
        badges = 0,
        nationalDex = false,
        runningShoes = false,
        runningShoesLock = false,
        rivalName = "Silver",
      },
      options = { textSpeed = "mid", textFrame = 0 },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
    playTime = PlayTime.new(),
    worldState = FieldEventState.new(),
    mons = require("tests.support.MonBucket").emptyForVersion(versionId),
    bag = require("libs.hgss.src.save.BagSave").empty(),
    mart = require("libs.hgss.src.save.MartSave").empty(),
  }
  return entry
end

-- The smallest generated trainer identity in canonical order, so the
-- witness resolves whatever the prepared cache actually carries instead
-- of freezing one numeric identity into the suite.
local function firstTrainerKey(compiled)
  assert(type(compiled) == "table" and type(compiled.trainers) == "table", "generated trainers carry their records")
  local keys = {}
  for key in pairs(compiled.trainers) do
    keys[#keys + 1] = key
  end
  Assert.isTrue(#keys > 0, "generated trainers name at least one identity")
  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)
  return keys[1]
end

local function requireVersions(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("production battle boot needs a ready versioned cache", 0)
  end
  return versions
end

local function runtimeOptions()
  local Fixture = require("tests.support.FieldStatePresentationFixture")
  return { presentation = false, derivedAssets = Fixture.iconHost().derivedAssets }
end

-- A production boot reaches the real encounter service: an attempt on the
-- boot interior answers through composed generated data instead of the
-- absent-service nil. The interior table exists with zeroed rates, so the
-- composed service reports the zero-rate miss.
function T.boot_composes_the_live_encounter_service(context)
  local versions = requireVersions(context)
  for _, versionId in ipairs(versions) do
    local runtime = FieldRuntime.new(validEntry(versionId), runtimeOptions())
    local ok, err = xpcall(function()
      local result = runtime:attemptEncounter({
        eventId = 1,
        mapId = runtime.runtimeMap.mapId,
        method = "grass",
        movement = "step",
        modifiers = {},
        environment = {},
        timeOfDay = "day",
      })
      Assert.notNil(result, "production boot composes the live encounter service")
      Assert.equal(result.kind, "none", "a zero-rate interior table misses without an encounter")
      Assert.equal(result.reason, "no_opportunity", "zeroed rates miss instead of faulting")
    end, debug.traceback)
    local closeOk, closeErr = pcall(function()
      runtime:dispose()
    end)
    if ok and not closeOk then
      ok, err = false, closeErr
    end
    if not ok then
      error(err, 0)
    end
  end
end

-- A production boot launches a generated trainer identity through the
-- public battle seam: the numeric payload resolves through the composed
-- catalog and materializer into an owned battle lifetime that reports its
-- launch identity, with no caller-side scenario assembly. Production
-- scenarios fail loudly without conscious party members (and a native
-- double needs two openers), so the boot witness stocks two battle-eligible
-- members through the live mon service before the public launch; the
-- witness needs successful materialization and lifetime start, not a win.
function T.boot_resolves_a_generated_trainer_identity(context)
  local versions = requireVersions(context)
  for _, versionId in ipairs(versions) do
    local runtime = FieldRuntime.new(validEntry(versionId), runtimeOptions())
    local battle = nil
    local ok, err = xpcall(function()
      Assert.isTrue(
        runtime.monService:giveMon({ species = "CHIKORITA", level = 5 }),
        "the boot battle needs its first battle-eligible party member"
      )
      Assert.isTrue(
        runtime.monService:giveMon({ species = "CHIKORITA", level = 6 }),
        "the boot battle needs its second battle-eligible party member"
      )
      local compiled = BattleDataCache.loadTrainers(CacheFs.forVersion(versionId))
      local key = firstTrainerKey(compiled)
      -- The smallest generated identity is a rival template, which resolves
      -- its display name from the saved profile's rival name (non-rival
      -- templates ignore it).
      battle = runtime:startBattle({
        request = {
          id = "launch-boot-trainer",
          kind = "trainer",
          payload = { trainer = key },
        },
      })
      Assert.notNil(battle, "the public launch owns its battle lifetime")
      Assert.isTrue(runtime.battleCoordinator:activeBattle() == battle, "the launch publishes the owned lifetime")
      local launched = battle:status()
      Assert.isTrue(
        launched.phase == "preparing" or launched.phase == "entering" or launched.phase == "running",
        "the generated identity reaches a valid battle lifecycle"
      )
      Assert.notNil(runtime:battleStatus("launch-boot-trainer"), "the owned battle reports its launch identity")
    end, debug.traceback)
    local closeOk, closeErr = pcall(function()
      runtime:dispose()
    end)
    if ok and not closeOk then
      ok, err = false, closeErr
    end
    if ok and battle ~= nil and not battle:isReleased() then
      ok, err = false, "teardown releases the owned battle lifetime"
    end
    if not ok then
      error(err, 0)
    end
  end
end

-- A directly constructed battle over the live party suppresses field
-- input before the first fixed tick runs, and disposing it resumes
-- initiation on the next tick without any field-owned battle handle.
function T.direct_battle_blocks_the_first_tick_and_releases_the_next()
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local FieldSession = require("libs.hgss.src.field.FieldSession")
  local party = newPartyOwner()
  local gate = false
  local events = {}
  local session = {
    accumulator = 0,
    setBattleActive = function(_, active)
      gate = active == true
      events[#events + 1] = gate and "gate-true" or "gate-false"
    end,
    updateFixed = function()
      events[#events + 1] = gate and "tick-blocked" or "tick-initiated"
    end,
  }
  local runtime = fakeRuntime({
    monService = party,
    session = session,
    applicationHost = {
      error = function()
        return nil
      end,
    },
    transition = {
      error = nil,
      updateSourceFrame = function() end,
      consumeCompleted = function()
        return nil
      end,
    },
    screenFade = { updateSourceFrame = function() end },
  })
  local portRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = BattleRuntime.new({
    request = { id = "launch-direct-first-tick", kind = "wild", payload = { species = "TOTODILE", level = 4 } },
    party = party,
    presentation = headlessPort(portRecord),
  })
  runtime:update(FieldSession.FIXED_DT)
  Assert.equal(events[1], "gate-true", "the direct owner suppresses input before field simulation")
  local firstTick = nil
  for _, event in ipairs(events) do
    if event == "tick-blocked" or event == "tick-initiated" then
      firstTick = event
      break
    end
  end
  Assert.equal(firstTick, "tick-blocked", "held movement never initiates while the direct battle owns decisions")
  battle:dispose()
  for index = #events, 1, -1 do
    events[index] = nil
  end
  runtime:update(FieldSession.FIXED_DT)
  Assert.equal(events[1], "gate-false", "release publishes instead of latching the suppression")
  local releasedTick = nil
  for _, event in ipairs(events) do
    if event == "tick-blocked" or event == "tick-initiated" then
      releasedTick = event
      break
    end
  end
  Assert.equal(releasedTick, "tick-initiated", "the next tick resumes without a field-owned handle")
end

-- The owned launch and return interval stays suppressed from launch
-- through settlement: the gate never clears mid-interval and a normal
-- return publishes its release without re-suppressing.
function T.owned_battle_interval_stays_suppressed_through_return()
  local party = newPartyOwner()
  local runtime, battleFlags = fakeRuntime({ monService = party })
  local portRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local foe = foeRecord("TOTODILE", 4, 0x5EED0004)
  local request =
    { id = "launch-owned-interval", kind = "wild", payload = { species = "TOTODILE", level = 4, mon = foe } }
  local scenario = ScenarioFactory.fromEncounter(
    request.payload,
    { party = party, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local battle = runtime:startBattle({
    request = request,
    scenario = scenario,
    presentation = headlessPort(portRecord),
  })
  Assert.isTrue(battleFlags[1], "launch freezes player input")
  local finished = driveToSettled(runtime, battle)
  Assert.equal(finished.phase, "complete", "answered decisions finish the owned battle")
  Assert.isNil(runtime.battleCoordinator:activeBattle(), "settlement releases the owned lifetime")
  Assert.isFalse(battleFlags[#battleFlags], "return releases player input")
  local released = false
  for _, flag in ipairs(battleFlags) do
    if released then
      Assert.isFalse(flag, "release never re-suppresses the field")
    elseif flag == false then
      released = true
    end
  end
  Assert.isTrue(released, "settlement publishes its release")
end

-- A leaving launch suppresses input before any owned battle exists,
-- and a failed owned battle faults loudly instead of resuming the story.
function T.launch_suppresses_early_and_failed_battles_fault()
  local runtime, battleFlags = fakeRuntime()
  local launchId = runtime:launchBattle({ kind = "wild", details = { species = "TOTODILE", level = 4 } })
  Assert.notNil(launchId, "the host launch issues its identity")
  runtime:updateBattle()
  Assert.isTrue(battleFlags[#battleFlags], "the leaving launch suppresses input before the battle exists")
  local failedRuntime = fakeRuntime()
  local broken = failedRuntime:startBattle({ request = wildRequest("launch-interval-broken"), scenario = {} })
  Assert.notNil(broken, "the broken launch still owns its lifetime")
  local ok = true
  for _ = 1, 10 do
    ok = pcall(failedRuntime.updateBattle, failedRuntime)
    if not ok then
      break
    end
  end
  Assert.equal(broken:status().phase, "failed", "an unbuildable owned battle reports failure")
  Assert.isNil(failedRuntime.battleCoordinator:activeBattle(), "failures release the owned lifetime")
  Assert.isFalse(ok, "failed battles reach the field error handler instead of resuming")
end

local function syntheticFontDef()
  return { glyphs = { [0] = { advance = 8 } }, charmap = {}, lineHeight = 16 }
end

local function syntheticContinueCursor()
  return { cycle = { 0, 1, 2, 3 }, framePrinterTicks = 4 }
end

local function modalRecordingInput()
  local calls = { begun = 0, cleared = 0 }
  local input = { calls = calls }
  function input:beginUi(_)
    calls.begun = calls.begun + 1
  end
  function input:clearUi()
    calls.cleared = calls.cleared + 1
  end
  return input
end

local function modalBoot()
  return {
    fontDef = syntheticFontDef(),
    cacheFs = {
      loadLua = function()
        return nil
      end,
    },
    uiManifest = { dialogueFrames = { continueCursor = syntheticContinueCursor() } },
    loadedGame = nil,
    restoredAudio = nil,
  }
end

local function modalRuntime(topology)
  return {
    viewportWidth = 256,
    viewportHeight = 192,
    screenTopology = topology,
    input = modalRecordingInput(),
    displayContext = {
      measure = function(_, width, height)
        return { width = width, height = height }
      end,
    },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1 },
      options = { textSpeed = "mid", textFrame = 0 },
    },
    monCatalog = {},
    presentationOverrides = nil,
  }
end

local function modalCallbacks(audioBuilds, menuBox)
  return {
    buildAudio = function(_, _)
      audioBuilds.count = audioBuilds.count + 1
      return {
        play = function() end,
      }
    end,
    menuFactory = function(_)
      return menuBox.current
    end,
    fieldAction = function(_, _)
      error("composition must not admit field actions", 0)
    end,
  }
end

-- Teardown releases exactly the acquired modal hosts in construction order,
-- including an open menu, while later-lifetime hosts stay owned by the root.
function T.modal_release_disposes_only_acquired_hosts_in_order()
  local Coordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
  local runtime = modalRuntime(nil)
  local menuBox = { current = nil }
  local composer = Coordinator.new(runtime)
  Assert.isTrue(type(composer.releaseModalHosts) == "function", "the menu coordinator owns modal host release")
  composer:composeModalHosts(modalBoot(), modalCallbacks({ count = 0 }, menuBox))
  local released = {}
  local function recordDispose(host, name)
    local original = assert(host.dispose, name .. " owns disposal")
    host.dispose = function(self)
      local result = original(self)
      released[#released + 1] = name
      return result
    end
  end
  recordDispose(runtime.dialogue, "dialogue")
  recordDispose(runtime.signpost, "signpost")
  recordDispose(runtime.applicationHost, "applicationHost")
  menuBox.current = {
    dispose = function()
      released[#released + 1] = "menu"
    end,
  }
  Assert.isTrue(runtime.applicationHost:requestOpen(5), "the menu opens before teardown")
  Assert.isTrue(runtime.applicationHost:isActive(), "the open menu owns the tick")
  composer:releaseModalHosts()
  Assert.deepEqual(
    released,
    { "dialogue", "signpost", "menu", "applicationHost" },
    "teardown releases the acquired hosts with the open menu inside its owner"
  )
  Assert.isNil(runtime.dialogue, "release clears the dialogue field")
  Assert.isNil(runtime.signpost, "release clears the signpost field")
  Assert.isNil(runtime.applicationHost, "release clears the application host field")
  Assert.notNil(runtime.menuHost, "release keeps later-lifetime hosts")
  Assert.notNil(runtime.yesNoHost, "release keeps the choice host")
  Assert.notNil(runtime.starterChoice, "release keeps the starter host")
  Assert.notNil(runtime.monNaming, "release keeps the naming host")
  Assert.equal(runtime.input.calls.cleared, 1, "teardown releases the held menu input exactly once")
  composer:releaseModalHosts()
  Assert.deepEqual(released, { "dialogue", "signpost", "menu", "applicationHost" }, "repeated release stays a no-op")
end

-- A constructor failure after the early host groups propagates the original
-- error with the acquired hosts published, so the shared teardown releases
-- exactly those hosts.
function T.failed_modal_construction_publishes_acquired_hosts_for_teardown()
  local Coordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
  local StarterChoice = require("game.hgss.src.starters.StarterChoiceState")
  local originalStarterNew = StarterChoice.new
  StarterChoice.new = function()
    error("injected starter failure", 0)
  end
  local runtime = setmetatable(modalRuntime(nil), FieldRuntime)
  runtime.scriptHosts = {
    audio = {
      play = function() end,
    },
  }
  runtime.menuComposer = Coordinator.new(runtime)
  local ok, err = pcall(function()
    runtime:_composeFieldUi(modalBoot())
  end)
  StarterChoice.new = originalStarterNew
  Assert.isFalse(ok, "construction failure propagates")
  Assert.isTrue(tostring(err):find("injected starter failure", 1, true) ~= nil, "the original failure surfaces")
  Assert.notNil(runtime.menuHost, "acquired hosts publish before the failure")
  Assert.notNil(runtime.dialogue, "acquired dialogue publishes before the failure")
  Assert.notNil(runtime.signpost, "acquired signpost publishes before the failure")
  Assert.isNil(runtime.starterChoice, "the failed host stays unacquired")
  Assert.isNil(runtime.applicationHost, "later hosts stay unacquired")
  local disposed = {}
  local function recordDispose(host, name)
    local original = assert(host.dispose, name .. " owns disposal")
    host.dispose = function(self)
      disposed[#disposed + 1] = name
      return original(self)
    end
  end
  recordDispose(runtime.dialogue, "dialogue")
  recordDispose(runtime.signpost, "signpost")
  local releaseOk, releaseErr = pcall(function()
    runtime:_releaseAll()
  end)
  Assert.isTrue(releaseOk, "teardown completes after partial construction: " .. tostring(releaseErr))
  Assert.deepEqual(disposed, { "dialogue", "signpost" }, "teardown releases exactly the acquired hosts in order")
  Assert.isNil(runtime.dialogue, "teardown clears the released dialogue")
  Assert.isNil(runtime.signpost, "teardown clears the released signpost")
end

-- The fixed-tick, world-settle, and battle-pump order survives composition
-- changes: the gate reconciles before the first tick and again after the
-- pump, a held direct battle suppresses first, and release publishes.
function T.field_tick_keeps_battle_gate_positions()
  local FieldSession = require("libs.hgss.src.field.FieldSession")
  local events = {}
  local function clearEvents()
    for index = #events, 1, -1 do
      events[index] = nil
    end
  end
  local session = {
    accumulator = 0,
    setBattleActive = function(_, active)
      events[#events + 1] = active and "gate-true" or "gate-false"
    end,
    updateFixed = function()
      events[#events + 1] = "tick"
    end,
  }
  local runtime = fakeRuntime({
    session = session,
    applicationHost = {
      error = function()
        return nil
      end,
    },
    transition = {
      error = nil,
      updateSourceFrame = function() end,
      consumeCompleted = function()
        return nil
      end,
    },
    screenFade = {
      updateSourceFrame = function() end,
    },
    playTime = {
      advance = function() end,
    },
  })
  runtime:update(FieldSession.FIXED_DT)
  Assert.deepEqual(
    events,
    { "gate-false", "tick", "gate-false" },
    "the gate reconciles before the first tick and again after the pump"
  )
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local party = newPartyOwner()
  local battle = BattleRuntime.new({
    request = { id = "gate-direct", kind = "wild", payload = { species = "TOTODILE", level = 4 } },
    party = party,
    presentation = headlessPort({ enters = 0, frames = {}, leaves = 0, disposed = 0 }),
  })
  runtime.monService = party
  clearEvents()
  runtime:update(FieldSession.FIXED_DT)
  Assert.deepEqual(
    events,
    { "gate-true", "tick", "gate-true" },
    "a held direct battle suppresses before the first tick"
  )
  battle:dispose()
  clearEvents()
  runtime:update(FieldSession.FIXED_DT)
  Assert.deepEqual(
    events,
    { "gate-false", "tick", "gate-false" },
    "release publishes instead of latching the suppression"
  )
  local launchId = runtime:launchBattle({ kind = "wild", details = { species = "TOTODILE", level = 4 } })
  Assert.notNil(launchId, "the host launch issues its identity")
  clearEvents()
  runtime:updateBattle()
  Assert.isNil(runtime.battleCoordinator:activeBattle(), "no battle exists while leaving")
  Assert.equal(events[#events], "gate-true", "the leaving launch suppresses before the battle exists")
end

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = {
      "field-runtime",
      "map:64",
      "map-data:64",
      "trainers:global",
      "encounters:global",
      "audio-bank:702",
    },
  },
}
