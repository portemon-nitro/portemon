-- Battle lifecycle ownership: a prepared battle survives delayed
-- presentation readiness without regenerating its combatants, and every
-- normal and failure return path releases resources exactly once while the
-- result commits exactly once. A preparation failure reports the failure
-- instead of continuing the story as a success.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local SCENARIO_FACTORY_MODULE = "libs.hgss.src.battle.HgssBattleScenarioFactory"
local COMMITTER_MODULE = "libs.hgss.src.battle.HgssBattleCommitter"

local T = {}

---@param name string module path under test
---@param behavior string missing owner under test
---@return table the loaded battle owner
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing battle owner: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the battle module loads")
  return loaded --[[@as table]]
end

---@param record table readiness and call counters owned by the test
---@return table headless presentation port with controllable readiness
local function headlessPort(record)
  return {
    enter = function(_plan)
      record.enters = record.enters + 1
      return record.ready
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

local function preparedWild()
  return {
    attemptId = "attempt-opening-7",
    species = "TOTODILE",
    form = 0,
    level = 4,
    personality = 0x12345678,
    ability = "TORRENT",
  }
end

local function launchFor(suffix)
  return { id = "launch-cleanup-" .. suffix, kind = "wild", payload = preparedWild() }
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
  Assert.isTrue(owner:addMon(foeRecord("CHIKORITA", 20, 0x33333333)), "the production path needs its live party lead")
  return owner
end

function T.delayed_readiness_never_regenerates_the_prepared_battle()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with readiness waits")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")

  local launch = launchFor("readiness")
  local party = newPartyOwner()
  local foe = foeRecord("TOTODILE", 4, 0x5EED0002)
  local attemptId = launch.id .. "-attempt"
  local scenario = ScenarioFactory.fromEncounter({ attemptId = attemptId, mon = foe }, { party = party })
  local portRecord = { ready = false, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    presentation = headlessPort(portRecord),
  })

  -- Delayed presentation readiness waits without consuming the encounter:
  -- the attempt identity and the prepared combatant stay identical.
  for _ = 1, 20 do
    battle:update()
  end
  local waiting = battle:status()
  Assert.equal(waiting.launchId, launch.id, "the wait preserves the launch identity")
  Assert.isTrue(
    waiting.phase == "preparing" or waiting.phase == "entering",
    "unready presentation holds entry instead of running ahead"
  )
  Assert.isNil(waiting.outcomeReceipt, "no outcome exists while entry waits")
  Assert.equal(scenario.mon.personality, foe.personality, "the wait never rerolls the prepared mon")
  Assert.equal(scenario.attemptId, attemptId, "the wait preserves the attempt identity")

  portRecord.ready = true
  for _ = 1, 20 do
    battle:update()
  end
  local entered = battle:status()
  Assert.isTrue(entered.phase == "entering" or entered.phase == "running", "readiness lets entry proceed")
  Assert.equal(scenario.mon.personality, foe.personality, "entry still never rerolls the prepared mon")

  battle:dispose()
  Assert.equal(portRecord.disposed, 1, "entry teardown releases presentation resources exactly once")
end

function T.completion_and_disposal_commit_exactly_once_and_release_once()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with exactly-once completion")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  local Committer = requirePresent(COMMITTER_MODULE, "end-to-end exactly-once result publication")

  local launch = launchFor("once")
  local party = newPartyOwner()
  local foe = foeRecord("TOTODILE", 4, 0x5EED0003)
  local scenario = ScenarioFactory.fromEncounter({ attemptId = launch.id .. "-attempt", mon = foe }, { party = party })
  local portRecord = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    presentation = headlessPort(portRecord),
  })
  local SessionFixture = require("libs.battle.tests.session_fixture")

  local ticks = 0
  while battle:status().phase ~= "complete" and battle:status().phase ~= "failed" and ticks < 1200 do
    battle:update()
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      local reply = SessionFixture.replyFor(
        current.request,
        (function()
          local choices = {}
          for _, actor in ipairs(assert(current.request.actors, "a decision request names its actors")) do
            choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
          end
          return choices
        end)()
      )
      Assert.isTrue(battle:submit(reply), "a legal decision is accepted")
    end
    ticks = ticks + 1
  end
  Assert.equal(battle:status().phase, "complete", "answered decisions finish the battle")
  local receipt = assert(battle:status().outcomeReceipt, "completion carries its commit receipt")
  Assert.isTrue(receipt.committed, "completion publishes through the committer")
  Assert.deepEqual(Committer.receipt(launch.id), receipt, "the lifecycle receipt is the committer receipt")

  -- Duplicate completion and repeated disposal neither duplicate the
  -- publication nor release resources twice.
  battle:update()
  Assert.deepEqual(battle:status().outcomeReceipt, receipt, "a repeated completion reuses the recorded receipt")
  battle:dispose()
  battle:dispose()
  Assert.equal(portRecord.disposed, 1, "repeated disposal releases resources exactly once")
  Assert.deepEqual(Committer.receipt(launch.id), receipt, "disposal after publication never republishes")

  -- A preparation failure reports instead of continuing as a success: no
  -- receipt exists and story continuation sees the failure.
  local badLaunch = { id = "launch-cleanup-broken", kind = "wild", payload = { species = "MISSING_NO" } }
  local failed, failure = pcall(BattleRuntime.new, { request = badLaunch, presentation = headlessPort(portRecord) })
  if failed then
    for _ = 1, 10 do
      failed:update()
    end
    Assert.equal(failed:status().phase, "failed", "an unbuildable battle reports failure")
    Assert.isNil(Committer.receipt(badLaunch.id), "a failed launch records no success receipt")
    failed:dispose()
  else
    Assert.isTrue(failure ~= nil, "an unbuildable launch reports its failure")
    Assert.isNil(Committer.receipt(badLaunch.id), "a failed launch records no success receipt")
  end
end

function T.production_attacks_settle_through_move_mechanics_not_a_fixed_strike()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with readiness waits")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  local SessionFixture = require("libs.battle.tests.session_fixture")

  local party = newPartyOwner()
  local foe = foeRecord("TOTODILE", 20, 0x5EED0001)
  local launch = { id = "launch-production-strike", kind = "wild", payload = { species = "TOTODILE", level = 20 } }
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = "attempt-production-strike", mon = foe },
    { party = party }
  )
  local portRecord = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    seed = 0x1BADB002,
    presentation = headlessPort(portRecord),
  })

  local ticks = 0
  while ticks < 400 do
    battle:update()
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      local choices = {}
      for _, actor in ipairs(assert(current.request.actors, "a decision request names its actors")) do
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
      end
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "a legal production decision is accepted: " .. tostring(replyErr))
    end
    local settled = battle:status()
    if settled.phase == "complete" or settled.phase == "failed" then
      break
    end
    local struck = false
    for _, frame in ipairs(portRecord.frames) do
      if type(frame) == "table" and frame.kind == "struck" then
        struck = true
      end
    end
    if struck then
      break
    end
    ticks = ticks + 1
  end

  local fixed, mechanic, heavy = 0, 0, false
  for _, frame in ipairs(portRecord.frames) do
    if type(frame) == "table" then
      if frame.kind == "strike" then
        fixed = fixed + 1
      elseif frame.kind == "struck" then
        mechanic = mechanic + 1
        local payload = frame.payload --[[@as table<string, unknown>]]
        if type(payload) == "table" and type(payload.damage) == "number" and payload.damage > 1 then
          heavy = true
        end
      end
    end
  end
  Assert.equal(fixed, 0, "production attacks never settle as fixed one-point strikes")
  Assert.isTrue(mechanic > 0, "production attacks settle through move mechanics")
  Assert.isTrue(heavy, "a real strike with nontrivial combatants deals more than one point")
  battle:dispose()
end

return { tests = T }
