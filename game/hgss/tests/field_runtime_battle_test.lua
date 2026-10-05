-- Field runtime battle ownership: explicit launches run the application
-- lifetime to commit and return, failed battles fault loudly instead of
-- resuming the story, prepared encounters are consumed exactly once, and
-- only one battle runs at a time. Most of the suite drives the runtime
-- through a focused composition fake; the two boot witnesses below
-- construct the real cache-backed runtime and prove field boot serves live
-- encounters and launches generated trainers through public behavior before
-- any field step or launch can ask for battle work.

local Assert = require("tests.support.Assert")
local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldOverworldLifecycle = require("libs.hgss.src.field.FieldOverworldLifecycle")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
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
    present = function(frame)
      record.frames[#record.frames + 1] = frame
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
  local runtime = setmetatable({
    battleRuntime = nil,
    _battleLaunch = nil,
    _battleReceipts = {},
    overworld = FieldOverworldLifecycle.new(),
    battlePresentation = nil,
    pendingEncounterId = nil,
    pendingEncounter = nil,
    _lastBattleResult = nil,
    errorText = nil,
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
  }, FieldRuntime)
  for key, value in pairs(overrides or {}) do
    runtime[key] = value
  end
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
local function newPartyOwner()
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local catalog = CatalogFixture.makeCatalog()
  local owner = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture(), catalog:fingerprint()),
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
  Assert.isTrue(owner:addMon(foeRecord("CHIKORITA", 5, 0x33333333)), "the owned lifetime needs its live party lead")
  return owner
end

local function wildRequest(id)
  return { id = id or "launch-field-1", kind = "wild", payload = { species = "TOTODILE", level = 4 } }
end

local function driveToSettled(runtime, battle)
  local ticks = 0
  while battle:status().phase ~= "complete" and battle:status().phase ~= "failed" and ticks < 200 do
    runtime:updateBattle()
    battle = runtime.battleRuntime or battle
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      local choices = {}
      for _, actor in ipairs(current.request.actors) do
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
      end
      local accepted, err = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "field-driven decisions answer: " .. tostring(err))
    end
    ticks = ticks + 1
  end
  return battle:status()
end

function T.startBattle_runs_the_owned_lifetime_to_commit_and_return()
  local party = newPartyOwner()
  local runtime, battleFlags = fakeRuntime({ monService = party })
  local portRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local foe = foeRecord("TOTODILE", 4, 0x5EED0004)
  local request = { id = "launch-field-1", kind = "wild", payload = { species = "TOTODILE", level = 4, mon = foe } }
  local scenario = ScenarioFactory.fromEncounter(request.payload, { party = party })
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
  Assert.isNil(runtime.battleRuntime, "settlement releases the owned lifetime")
  Assert.isFalse(battleFlags[#battleFlags], "return releases player input")
  Assert.notNil(runtime:lastBattleResult(), "completion records its outcome words")
  Assert.equal(portRecord.disposed, 1)
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
  for _ = 1, 10 do
    failedRuntime:updateBattle()
  end
  Assert.equal(broken:status().phase, "failed")
  Assert.isNil(failedRuntime.battleRuntime, "failures release the owned lifetime")
  Assert.notNil(failedRuntime.errorText, "failures fault loudly instead of resuming the story")
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
  Assert.isTrue(running.phase == "entering" or running.phase == "running")
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
    runtime._battleLaunch = { launchId = "matrix-" .. result, phase = "active" }
    runtime.battleRuntime = {
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
  runtime._battleLaunch = { launchId = "matrix-failure", phase = "active" }
  runtime.battleRuntime = {
    update = function() end,
    dispose = function() end,
    status = function()
      return { phase = "failed", error = "battle application failed" }
    end,
  }
  runtime:updateBattle()
  local status = runtime:battleStatus("matrix-failure")
  Assert.isFalse(status.committed, "a failure has no committed battle result")
  Assert.notNil(status.error, "the task host retains the application failure")
  Assert.notNil(runtime.errorText, "the existing application error remains visible")
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
  local runtime = fakeRuntime({ _encounters = service })
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
  local runtime = fakeRuntime({ _encounters = service })
  runtime:attemptEncounter({})
  Assert.equal(attempts, 1)
  runtime.pendingEncounterId = 9
  runtime.pendingEncounter = {}
  runtime:attemptEncounter({})
  Assert.equal(attempts, 1, "a held preparation skips further attempts")
  runtime.pendingEncounterId = nil
  runtime.pendingEncounter = nil
  runtime.battleRuntime = {}
  runtime:attemptEncounter({})
  Assert.equal(attempts, 1, "an active battle skips attempts")
  runtime.battleRuntime = nil
  Assert.isNil(fakeRuntime()._encounters, "an absent service attempts nothing")
  local quiet = fakeRuntime()
  Assert.isNil(quiet:attemptEncounter({}), "an absent service attempts nothing")
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
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
      options = { textSpeed = "mid", textFrame = 0 },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    playTime = PlayTime.new(),
    worldState = FieldEventState.new(),
    mons = require("tests.support.MonBucket").emptyForVersion(versionId),
    bag = require("libs.hgss.src.save.BagSave").empty(),
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

-- A production boot reaches the real encounter service: an attempt on the
-- boot interior answers through composed generated data instead of the
-- absent-service nil. The interior table exists with zeroed rates, so the
-- composed service reports the zero-rate miss.
function T.boot_composes_the_live_encounter_service(context)
  local versions = requireVersions(context)
  for _, versionId in ipairs(versions) do
    local runtime = FieldRuntime.new(validEntry(versionId), { presentation = false })
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
    local runtime = FieldRuntime.new(validEntry(versionId), { presentation = false })
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
      -- its display name from the saved rival name (non-rival templates
      -- ignore it); the suite supplies the canonical default.
      battle = runtime:startBattle({
        request = {
          id = "launch-boot-trainer",
          kind = "trainer",
          payload = { trainer = key, rivalName = "SILVER" },
        },
      })
      Assert.notNil(battle, "the public launch owns its battle lifetime")
      Assert.isTrue(runtime.battleRuntime == battle, "the launch publishes the owned lifetime")
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

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "field-runtime", "map:64", "trainers:global", "encounters:global" },
  },
}
