-- Field runtime battle ownership: explicit launches run the application
-- lifetime to commit and return, failed battles fault loudly instead of
-- resuming the story, prepared encounters are consumed exactly once, and
-- only one battle runs at a time. The runtime is a focused composition
-- fake (no cache boot); the live-boot journey lives in the acceptance
-- layer.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
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
  Assert.equal(status.phase, "preparing")
  Assert.isNil(runtime:battleStatus("no-such-launch"))
  for _ = 1, 10 do
    runtime:updateBattle()
  end
  local running = runtime:battleStatus(first)
  Assert.isTrue(running.phase == "entering" or running.phase == "running")
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

return { tests = T }
