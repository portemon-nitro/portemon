-- Battle lifecycle ownership: a prepared battle survives delayed
-- presentation readiness without regenerating its combatants, and every
-- normal and failure return path releases resources exactly once while the
-- result commits exactly once. A preparation failure reports the failure
-- instead of continuing the story as a success.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
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

---@param battle table<string, unknown> live application battle under test driving
---@param budget integer maximum update ticks before the driver gives up
---@return table<string, unknown> status once a player decision is open or the lifetime settled
local function driveToDecision(battle, budget)
  for _ = 1, budget do
    battle:update()
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      return current
    end
    if current.phase == "complete" or current.phase == "failed" then
      return current
    end
  end
  error("the battle never opened its player decision")
end

---@param battle table<string, unknown> live application battle under test driving
---@param requestId string open request identity already answered under test driving
---@param budget integer maximum update ticks before the driver gives up
local function drivePastRequest(battle, requestId, budget)
  for _ = 1, budget do
    battle:update()
    local current = battle:status()
    if current.phase ~= "running" then
      return
    end
    local pending = current.request
    if pending ~= nil and pending.requestId ~= requestId then
      return
    end
  end
  error("the battle never moved past its answered decision")
end

---@param request table<string, unknown> pending player decision request under inspection
---@return string[] admitted choice kinds for the request
local function admittedKinds(request)
  local legal = assert(request.legalChoices, "player decisions carry their admitted vocabulary")
  return assert(legal.kinds, "player decisions carry their admitted kinds")
end

---@param kinds string[] admitted choice kinds under inspection
---@param wanted string choice kind under search
---@return boolean
local function admits(kinds, wanted)
  for _, kind in ipairs(kinds) do
    if kind == wanted then
      return true
    end
  end
  return false
end

---@param scenario table<string, unknown> detached production scenario under inspection
---@param occupant integer combatant holding the opening position
---@return integer combatant identity of the living reserve
local function reserveOf(scenario, occupant)
  for _, seed in ipairs(scenario.participants[1].roster) do
    if seed.id ~= occupant then
      return seed.id
    end
  end
  error("the production roster carries no reserve")
end

---@param service table<string, unknown> live party owner under test preparation
---@param species string catalog species key under test preparation
---@param level integer battle level under test preparation
---@param seed integer fixed generator state under test preparation
---@param currentHp integer|nil wounded health under test preparation, full health when absent
local function addPartyMon(service, species, level, seed, currentHp)
  local factory = CatalogFixture.makeFactory(seed, service:catalog())
  local record = tackleOnly(factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level })))
  if currentHp ~= nil then
    record.condition.currentHp = currentHp
  end
  Assert.isTrue(service:addMon(record), "the production path needs its live party member")
end

---@return table party owner holding one fixed lead
local function newPartyOwner()
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local catalog = CatalogFixture.makeCatalog()
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
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
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

function T.production_reserves_enter_through_voluntary_switch()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with exactly-once completion")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  local SessionFixture = require("libs.battle.tests.session_fixture")

  local party = newPartyOwner()
  addPartyMon(party, "EEVEE", 20, 0x44444444)
  local foe = foeRecord("TOTODILE", 4, 0x5EED0004)
  local scenario = ScenarioFactory.fromEncounter({ attemptId = "attempt-reserve-switch", mon = foe }, { party = party })
  local portRecord = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = BattleRuntime.new({
    request = { id = "launch-reserve-switch", kind = "wild", payload = preparedWild() },
    scenario = scenario,
    party = party,
    presentation = headlessPort(portRecord),
  })
  local opening = driveToDecision(battle, 400)
  Assert.equal(opening.phase, "running", "the production battle asks for its opening decision")
  local request = assert(opening.request, "the opening decision is exposed")
  Assert.isTrue(admits(admittedKinds(request), "switch"), "the opening decision admits exchanges")
  local actor = assert(request.actors[1], "the opening decision addresses its lead")
  local reserve = reserveOf(scenario, actor.combatant)
  local accepted, replyErr = battle:submit(SessionFixture.replyFor(request, { SessionFixture.switchChoice(actor, reserve) }))
  Assert.isTrue(accepted, "the exchange into the production reserve is accepted")
  Assert.isNil(replyErr, "the accepted exchange carries no input error")
  local entered = false
  for _ = 1, 400 do
    battle:update()
    local current = battle:status()
    Assert.isTrue(current.phase ~= "failed", "the exchanged battle never fails")
    if current.phase ~= "running" then
      break
    end
    local pending = current.request
    if pending ~= nil and pending.requestId ~= request.requestId then
      local addressed = assert(pending.actors[1], "the following decision addresses its occupant")
      Assert.equal(addressed.combatant, reserve, "the reserve holds the field after the exchange")
      entered = true
      break
    end
  end
  Assert.isTrue(entered, "the production reserve enters through the voluntary exchange")
  battle:dispose()
end

function T.production_reserves_enter_through_faint_replacement()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with exactly-once completion")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  local SessionFixture = require("libs.battle.tests.session_fixture")

  local party = newPartyOwner()
  addPartyMon(party, "EEVEE", 20, 0x44444444)
  local foe = foeRecord("TOTODILE", 30, 0x5EED0005)
  local scenario = ScenarioFactory.fromEncounter({ attemptId = "attempt-reserve-faint", mon = foe }, { party = party })
  local portRecord = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = BattleRuntime.new({
    request = { id = "launch-reserve-faint", kind = "wild", payload = preparedWild() },
    scenario = scenario,
    party = party,
    presentation = headlessPort(portRecord),
  })
  -- The overpowering foe knocks the opener out and the bereaved side must
  -- be asked for its reserve before the next turn.
  local opening = driveToDecision(battle, 400)
  Assert.equal(opening.phase, "running", "the replacement battle asks for its opening decision")
  local first = assert(opening.request, "the opening decision is exposed")
  local opener = assert(first.actors[1], "the opening decision addresses its lead")
  local firstOk, firstErr = battle:submit(
    SessionFixture.replyFor(first, { SessionFixture.attackChoice(opener, 0, SessionFixture.positionTarget(2)) })
  )
  Assert.isTrue(firstOk, "the opening strike is accepted")
  Assert.isNil(firstErr, "the accepted opening strike carries no input error")
  local reserve = nil
  local replaced = false
  local seenReplacement = false
  local answeredId = first.requestId
  for _ = 1, 1200 do
    battle:update()
    local current = battle:status()
    Assert.isTrue(current.phase ~= "failed", "the replacement battle never fails")
    if current.phase ~= "running" then
      break
    end
    local pending = current.request
    if pending ~= nil and pending.requestId ~= answeredId then
      local kinds = admittedKinds(pending)
      local actor = assert(pending.actors[1], "every player decision addresses its combatant")
      if not admits(kinds, "attack") and admits(kinds, "switch") then
        seenReplacement = true
        reserve = reserve or reserveOf(scenario, actor.combatant)
        local accepted, replyErr =
          battle:submit(SessionFixture.replyFor(pending, { SessionFixture.switchChoice(actor, reserve) }))
        Assert.isTrue(accepted, "the faint replacement is accepted")
        Assert.isNil(replyErr, "the accepted replacement carries no input error")
        answeredId = pending.requestId
        replaced = true
      elseif replaced then
        Assert.equal(actor.combatant, reserve, "the following turn addresses the replacement")
        battle:dispose()
        Assert.isTrue(seenReplacement, "the reserve arrived through a replacement obligation")
        return
      else
        local accepted, replyErr = battle:submit(
          SessionFixture.replyFor(
            pending,
            { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)) }
          )
        )
        Assert.isTrue(accepted, "opening strikes are accepted while the lead stands")
        Assert.isNil(replyErr, "accepted strikes carry no input error")
        answeredId = pending.requestId
      end
    end
  end
  battle:dispose()
  Assert.isTrue(false, "the knocked-out lead is replaced before the next turn")
end

---@param species string catalog species key for the wild foe
---@param level integer foe battle level
---@param seed integer fixed generator state for the foe record
---@return table battle, table live party, table live bag, table port record
local function healingBattle(species, level, seed)
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local party = newPartyOwner()
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  Assert.isTrue(bag:add("POTION", 3), "setup potion stock enters the live bag")
  Assert.isTrue(bag:add("POKE_BALL", 2), "setup ball stock enters the live bag")
  -- Wound the live lead without touching the live bag: the session must
  -- heal from its detached stock and publish back exactly once. The party
  -- owner hands out detached copies, so the wound publishes through the
  -- ordinary preparation for the scenario and the battle to observe it.
  local wounded = party:partyMon(0)
  wounded.condition.currentHp = 1
  local wounding = party:preparePartyBatch(party:partyRevision(), { { slot = 0, mon = wounded } }, {})
  Assert.notNil(wounding, "the setup wound stages against the live party")
  wounding.publish()
  local foe = foeRecord(species, level, seed)
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = "attempt-item-" .. seed, mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = BattleRuntime.new({
    request = { id = "launch-item-" .. seed, kind = "wild", payload = preparedWild() },
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = headlessPort(portRecord),
  })
  return battle, party, bag, portRecord
end

---@param battle table<string, unknown> live application battle under test driving
---@param budget integer maximum update ticks before the driver gives up
local function finishBattle(battle, budget)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local answeredId = nil
  for _ = 1, budget do
    battle:update()
    local current = battle:status()
    if current.phase == "complete" or current.phase == "failed" then
      return
    end
    if current.phase == "running" and current.request ~= nil and current.request.requestId ~= answeredId then
      answeredId = current.request.requestId
      local kinds = admittedKinds(current.request)
      local actor = assert(current.request.actors[1], "every player decision addresses its combatant")
      local choices = nil
      if admits(kinds, "attack") then
        choices = { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)) }
      else
        choices = { SessionFixture.confirmChoice(actor) }
      end
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "the finishing driver answers every player decision")
      Assert.isNil(replyErr, "accepted finishing replies carry no input error")
    end
  end
  error("the battle never settled")
end

function T.session_healing_publishes_one_live_bag_decrement()
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local battle, party, bag, _ = healingBattle("TOTODILE", 4, 0x5EED0006)
  local bagRevision = bag:revision()
  local opening = driveToDecision(battle, 400)
  Assert.equal(opening.phase, "running", "the healing battle asks for its opening decision")
  local request = assert(opening.request, "the opening decision is exposed")
  local actor = assert(request.actors[1], "the opening decision addresses its lead")
  local accepted, replyErr = battle:submit(SessionFixture.replyFor(request, {
    { actor = actor, kind = "item", payload = { item = "POTION", target = { kind = "combatant", combatant = actor.combatant } } },
  }))
  Assert.isTrue(accepted, "the healing choice is accepted")
  Assert.isNil(replyErr, "the accepted healing choice carries no input error")
  finishBattle(battle, 1200)
  Assert.equal(battle:status().phase, "complete", "the healed battle finishes")
  Assert.equal(bag:quantity("POTION"), 2, "the consumed potion publishes exactly once")
  Assert.equal(bag:quantity("POKE_BALL"), 2, "untouched stock never publishes")
  Assert.equal(bag:revision(), bagRevision + 1, "one committed preparation advances the revision once")
  battle:update()
  Assert.equal(bag:quantity("POTION"), 2, "repeated settlement never consumes again")
  Assert.equal(bag:revision(), bagRevision + 1, "repeated settlement never republishes")
  Assert.isTrue(party:partyMon(0).condition.currentHp > 1, "the healed lead keeps its recovered health")
  battle:dispose()
end

-- Application fact projection resolves each distinct non-ball inventory
-- key through the item catalog and copies exactly its generated
-- party-use record: repeated keys project once, balls and unknown keys
-- stay absent for their own paths, no presentation or native field
-- crosses, and later projector edits never reach the live catalog.
function T.session_item_facts_project_exactly_the_referenced_party_use()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with readiness waits")
  local party = newPartyOwner()
  local portRecord = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = BattleRuntime.new({
    request = launchFor("item-facts"),
    party = party,
    presentation = headlessPort(portRecord),
  })
  local record = {
    inventories = {
      { id = "party", owners = { 1 }, quantities = { POTION = 3, POKE_BALL = 2, TONIC = 1 } },
      { id = "side", owners = { 1 }, quantities = { POTION = 1, CHERI_BERRY = 1 } },
    },
  }
  local facts = battle:_sessionItemFacts(record)
  local catalog = party:catalog()
  Assert.deepEqual(
    facts.POTION,
    { partyUse = catalog:item("POTION").partyUse },
    "the repeated key projects its generated party use once"
  )
  Assert.deepEqual(
    facts.CHERI_BERRY,
    { partyUse = catalog:item("CHERI_BERRY").partyUse },
    "the berry key projects its generated party use"
  )
  local projected = 0
  for _ in pairs(facts) do
    projected = projected + 1
  end
  Assert.equal(projected, 2, "only referenced non-ball catalog keys project")
  Assert.isNil(facts.POKE_BALL, "balls serve through the capture owner without facts")
  Assert.isNil(facts.TONIC, "unknown keys stay absent until their selection fails")
  facts.POTION.partyUse.restore.amount = 999
  Assert.equal(
    catalog:item("POTION").partyUse.restore.amount,
    20,
    "projector edits never reach the live catalog"
  )
  battle:dispose()
end

function T.thrown_balls_consume_stock_whether_the_capture_lands_or_not()
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local battle, _party, bag, _port = healingBattle("TOTODILE", 4, 0x5EED0007)
  local bagRevision = bag:revision()
  local opening = driveToDecision(battle, 400)
  local request = assert(opening.request, "the opening decision is exposed")
  local actor = assert(request.actors[1], "the opening decision addresses its lead")
  local accepted, replyErr = battle:submit(SessionFixture.replyFor(request, {
    { actor = actor, kind = "item", payload = { item = "POKE_BALL", target = { kind = "combatant", combatant = 2 } } },
  }))
  Assert.isTrue(accepted, "the thrown ball is accepted")
  Assert.isNil(replyErr, "the accepted throw carries no input error")
  finishBattle(battle, 1200)
  Assert.equal(battle:status().phase, "complete", "the throwing battle settles either way")
  Assert.equal(bag:quantity("POKE_BALL"), 1, "the thrown ball publishes exactly once")
  Assert.equal(bag:revision(), bagRevision + 1, "one committed preparation advances the revision once")
  battle:update()
  Assert.equal(bag:quantity("POKE_BALL"), 1, "repeated settlement never consumes again")
  battle:dispose()
end

function T.a_stale_live_bag_blocks_every_publication()
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local battle, party, bag, _ = healingBattle("TOTODILE", 4, 0x5EED0008)
  local partyRevision = party:partyRevision()
  local bagRevision = bag:revision()
  local opening = driveToDecision(battle, 400)
  local request = assert(opening.request, "the opening decision is exposed")
  local actor = assert(request.actors[1], "the opening decision addresses its lead")
  local accepted, replyErr = battle:submit(SessionFixture.replyFor(request, {
    { actor = actor, kind = "item", payload = { item = "POTION", target = { kind = "combatant", combatant = actor.combatant } } },
  }))
  Assert.isTrue(accepted, "the healing choice is accepted")
  Assert.isNil(replyErr, "the accepted healing choice carries no input error")
  -- Let the healing turn execute, then move the live bag under the battle.
  drivePastRequest(battle, request.requestId, 400)
  Assert.isTrue(bag:add("POTION", 5), "a concurrent restock moves the live bag")
  finishBattle(battle, 1200)
  Assert.equal(battle:status().phase, "failed", "the stale bag fails the resolution")
  Assert.equal(bag:quantity("POTION"), 8, "only the live restock lands")
  Assert.equal(bag:revision(), bagRevision + 1, "no battle preparation publishes")
  Assert.equal(party:partyRevision(), partyRevision, "no party consequence publishes either")
  battle:dispose()
end

-- Opponent decisions share the session battle stream: with a fixed seed
-- the wild answer consumes the opening draw, so the turn that follows
-- draws order, accuracy, critical, and damage from the advanced position.
-- Under that unified order the opening player strike deals exactly 7 and
-- the answering wild strike misses; a split selection stream would deal 6
-- and land the answer for 7 instead. The battle runs through production
-- composition with a live party owner and the generated scenario factory.
function T.internal_opponent_answers_advance_the_session_stream()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with readiness waits")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  local SessionFixture = require("libs.battle.tests.session_fixture")

  local party = newPartyOwner()
  local foe = foeRecord("TOTODILE", 20, 0x5EED0001)
  local launch = { id = "launch-unified-stream", kind = "wild", payload = { species = "TOTODILE", level = 20 } }
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = "attempt-unified-stream", mon = foe },
    { party = party }
  )
  scenario.random.seed = 7
  local portRecord = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    seed = 7,
    presentation = headlessPort(portRecord),
  })

  local ticks = 0
  local playerDamage = nil
  local foeMissed = false
  while ticks < 400 and (playerDamage == nil or not foeMissed) do
    battle:update()
    local current = battle:status()
    Assert.isTrue(current.phase ~= "failed", "the unified stream never fails the battle")
    if current.phase == "running" and current.request ~= nil then
      local choices = {}
      for _, actor in ipairs(assert(current.request.actors, "a decision request names its actors")) do
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
      end
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "a legal production decision is accepted: " .. tostring(replyErr))
    end
    for _, frame in ipairs(portRecord.frames) do
      if type(frame) == "table" then
        local payload = frame.payload --[[@as table<string, unknown>]]
        if frame.kind == "struck" and type(payload) == "table" and payload.target == 2 then
          playerDamage = payload.damage
        end
        if frame.kind == "missed" and type(payload) == "table" and payload.target == 1 then
          foeMissed = true
        end
      end
    end
    if current.phase == "complete" then
      break
    end
    ticks = ticks + 1
  end
  Assert.equal(playerDamage, 7, "the wild answer advances the shared stream ahead of the player strike")
  Assert.isTrue(foeMissed, "the answering wild strike draws from the same advanced stream")
  battle:dispose()
end


return { tests = T }
