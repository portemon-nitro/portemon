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
    -- The five-operation port delivers detached packets; the fake
    -- unwraps their ordered events so kernel-event probes keep reading
    -- the same payloads.
    present = function(packet)
      for _, event in ipairs(packet.events) do
        record.frames[#record.frames + 1] = event
      end
    end,
    ready = function()
      return record.ready
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
  local launch = launchFor("once")
  local party = newPartyOwner()
  local foe = foeRecord("TOTODILE", 4, 0x5EED0003)
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, player = { trainerId = 99, trainerName = "MINT", language = "french", trainerClassKey = "PKMN_TRAINER_ETHAN" } }
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
  Assert.deepEqual(battle:status().outcomeReceipt, receipt, "the lifecycle retains its own committed receipt")

  -- Duplicate completion and repeated disposal neither duplicate the
  -- publication nor release resources twice.
  battle:update()
  Assert.deepEqual(battle:status().outcomeReceipt, receipt, "a repeated completion reuses the recorded receipt")
  battle:dispose()
  battle:dispose()
  Assert.equal(portRecord.disposed, 1, "repeated disposal releases resources exactly once")
  Assert.deepEqual(battle:status().outcomeReceipt, receipt, "disposal after publication never republishes")

  -- A preparation failure reports instead of continuing as a success: no
  -- receipt exists and story continuation sees the failure.
  local badLaunch = { id = "launch-cleanup-broken", kind = "wild", payload = { species = "MISSING_NO" } }
  local failed, failure = pcall(BattleRuntime.new, { request = badLaunch, presentation = headlessPort(portRecord) })
  if failed then
    for _ = 1, 10 do
      failed:update()
    end
    Assert.equal(failed:status().phase, "failed", "an unbuildable battle reports failure")
    Assert.isNil(failed:status().outcomeReceipt, "a failed launch records no success receipt")
    failed:dispose()
  else
    Assert.isTrue(failure ~= nil, "an unbuildable launch reports its failure without a receipt")
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
  local accepted, replyErr =
    battle:submit(SessionFixture.replyFor(request, { SessionFixture.switchChoice(actor, reserve) }))
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
          SessionFixture.replyFor(pending, { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)) })
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
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french", trainerClassKey = "PKMN_TRAINER_ETHAN" } }
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
    {
      actor = actor,
      kind = "item",
      payload = { item = "POTION", target = { kind = "combatant", combatant = actor.combatant } },
    },
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
    { partyUse = catalog:item("POTION").partyUse, pocket = "medicine" },
    "the repeated key projects its generated party use once"
  )
  Assert.deepEqual(
    facts.CHERI_BERRY,
    { partyUse = catalog:item("CHERI_BERRY").partyUse, pocket = "berries" },
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
  Assert.equal(catalog:item("POTION").partyUse.restore.amount, 20, "projector edits never reach the live catalog")
  battle:dispose()
end

-- Battle-use riders project beside party use through the same
-- projector: a stub catalog carrying battle-use, throw, held-behavior, and
-- missing records proves each family lands detached without leaking
-- across. Trainer evaluation reads held effects through the session facts,
-- so every held entry carries its canonical held behavior, including
-- held-only entries with no throw facts at all.
function T.session_item_facts_project_battle_use_and_throw_facts()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with readiness waits")
  local stubCatalog = {
    item = function(_, key)
      if key == "X_ITEM" then
        return {
          partyUse = { kind = "deferred", reason = "battle_only" },
          battleUse = {
            cures = { confusion = false, infatuation = false },
            guardSpec = false,
            stages = {
              attack = 1,
              defense = 0,
              specialAttack = 0,
              specialDefense = 0,
              speed = 0,
              accuracy = 0,
              critical = 0,
            },
          },
          heldBehavior = { key = "no_hold_effect", params = { nativeId = 999, holdEffect = 0 } },
        }
      end
      if key == "BERRY" then
        return {
          partyUse = { kind = "medicine", cures = {}, revive = "none", mood = 0 },
          naturalGift = { power = 60, typeId = 14, type = "psychic" },
          fling = { effect = 10, power = 10 },
          heldBehavior = { key = "unmapped_hold_effect", params = { nativeId = 158, holdEffect = 5 } },
        }
      end
      if key == "CHARM" then
        return {
          heldBehavior = { key = "money_up", params = { nativeId = 223, holdEffect = 58 } },
        }
      end
      error("unknown item " .. tostring(key))
    end,
  }
  local projector = setmetatable({
    _party = {
      catalog = function()
        return stubCatalog
      end,
    },
  }, { __index = BattleRuntime })
  local record = {
    inventories = {
      { id = "pack", owners = { 1 }, quantities = { X_ITEM = 2 } },
    },
    participants = {
      { roster = { { mon = { heldItem = "BERRY" } }, { mon = { heldItem = "CHARM" } } } },
    },
  }
  local facts = BattleRuntime._sessionItemFacts(projector, record)
  Assert.deepEqual(facts.X_ITEM.partyUse, { kind = "deferred", reason = "battle_only" }, "party use projects")
  Assert.equal(facts.X_ITEM.battleUse.stages.attack, 1, "battle-use stages project beside party use")
  Assert.deepEqual(
    facts.X_ITEM.heldBehavior,
    { key = "no_hold_effect", params = { nativeId = 999, holdEffect = 0 } },
    "inventory entries carry their held behavior"
  )
  Assert.equal(facts.BERRY.naturalGift.power, 60, "held throw power projects")
  Assert.equal(facts.BERRY.fling.power, 10, "held fling power projects")
  Assert.deepEqual(
    facts.BERRY.heldBehavior,
    { key = "unmapped_hold_effect", params = { nativeId = 158, holdEffect = 5 } },
    "held entries carry their held behavior"
  )
  Assert.deepEqual(
    facts.BERRY.partyUse,
    { kind = "medicine", cures = {}, revive = "none", mood = 0 },
    "held berries also carry their generated party use"
  )
  Assert.deepEqual(
    facts.CHARM,
    { heldBehavior = { key = "money_up", params = { nativeId = 223, holdEffect = 58 } } },
    "a held-behavior record alone is a complete held family"
  )
  facts.X_ITEM.battleUse.stages.attack = 9
  local again = BattleRuntime._sessionItemFacts(projector, record)
  Assert.equal(again.X_ITEM.battleUse.stages.attack, 1, "projector edits never reach the catalog")
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
    {
      actor = actor,
      kind = "item",
      payload = { item = "POTION", target = { kind = "combatant", combatant = actor.combatant } },
    },
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
  local scenario = ScenarioFactory.fromEncounter({ attemptId = "attempt-unified-stream", mon = foe }, { party = party })
  -- Seed 1 keeps the wild miss-then-answer shape after native entry
  -- ordering, request ordering, and remainder-mapped damage draws.
  scenario.random.seed = 3
  local portRecord = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    seed = 3,
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
  Assert.equal(playerDamage, 6, "the wild answer advances the shared stream ahead of the player strike")
  print("DEBUG wild stream", playerDamage, foeMissed)
  Assert.isTrue(foeMissed, "the answering wild strike draws from the same advanced stream")
  battle:dispose()
end

-- One live party owner carries at most one unsettled battle: a second
-- direct construction for the same owner fails before replacing the
-- index or acquiring presentation resources, while a different owner
-- stays independent and a settled owner accepts its next battle.
function T.shared_party_owners_reject_a_second_unsettled_battle()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with owner-gated decisions")
  local firstParty = newPartyOwner()
  local secondParty = newPartyOwner()
  local firstPorts = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local first = BattleRuntime.new({
    request = launchFor("owner-first"),
    party = firstParty,
    presentation = headlessPort(firstPorts),
  })
  Assert.isTrue(BattleRuntime.isActiveFor(firstParty), "the constructed battle owns its party decisions")
  Assert.isFalse(BattleRuntime.isActiveFor(secondParty), "an unrelated party owner stays independent")
  local duplicatePorts = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local ok, secondOrFailure = pcall(BattleRuntime.new, {
    request = launchFor("owner-duplicate"),
    party = firstParty,
    presentation = headlessPort(duplicatePorts),
  })
  if ok then
    (secondOrFailure --[[@as table]]):dispose()
  end
  Assert.isFalse(ok, "a second unsettled battle for the same party fails before replacing the owner")
  Assert.isTrue(BattleRuntime.isActiveFor(firstParty), "the rejected duplicate never replaces the current owner")
  Assert.equal(duplicatePorts.disposed, 0, "the rejected duplicate acquires no presentation resources")
  local otherPorts = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local other = BattleRuntime.new({
    request = launchFor("owner-other"),
    party = secondParty,
    presentation = headlessPort(otherPorts),
  })
  Assert.isTrue(BattleRuntime.isActiveFor(secondParty), "a different owner runs its own battle")
  first:dispose()
  Assert.isFalse(BattleRuntime.isActiveFor(firstParty), "disposal releases its own owner")
  Assert.isTrue(BattleRuntime.isActiveFor(secondParty), "releasing one battle never clears another owner")
  other:dispose()
  local revivedPorts = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local revived = BattleRuntime.new({
    request = launchFor("owner-revived"),
    party = firstParty,
    presentation = headlessPort(revivedPorts),
  })
  Assert.isTrue(BattleRuntime.isActiveFor(firstParty), "a released owner accepts its next battle")
  revived:dispose()
end

-- Dex arrival fixtures ride the real kernel: a wild battle with benched
-- reserves on both sides produces authentic switch events whose
-- checkpoints are captured at emission. Both sides exchange twice with
-- no strikes, so every appearance, activation, and form asserted below
-- comes from kernel state rather than hand-written snapshots. Only the
-- delivery frame is composed: both turns' real switch events arrive in
-- one frame while the terminal capture already shows the first entrants
-- gone, which is exactly the rapid-switch ordering the arrival
-- projection must survive. Controller names are remapped to the
-- production player identity the scenario factory declares; the kernel
-- only ever routes the fixture's alpha/beta pair.
local DEX_WILD_FORMAT = "wild-single"
local DEX_NATIVE_SEED = 0xD0634001

---@return table loaded native session owner for dex arrival fixtures
local function dexExecutorOwner()
  local SessionFixture = require("libs.battle.tests.session_fixture")
  return SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "dex arrival fixtures observe native kernel switches"
  )
end

---@param id integer combatant identity under arrival observation
---@param seed integer fixed generator state for the underlying mon
---@param species string catalog species key under arrival observation
---@param form integer visible form at battle entry
---@return table combatant seed carrying a single known move
local function dexCombatant(id, seed, species, form)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = 5, form = form }))
  mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return { id = id, mon = mon }
end

---@return table<string, table<string, unknown>> immutable move facts for the arrival strikes
local function dexMoveFacts()
  local catalog = CatalogFixture.makeCatalog()
  return {
    TACKLE = catalog:move("TACKLE"),
    STRUGGLE = { power = 50, accuracy = 100, category = "physical", moveType = "normal", priority = 0 },
  }
end

---@param record table<string, unknown> catalog form record carrying its semantic types
---@return string[] detached semantic types for the form
local function dexCopyFormTypes(record)
  local types = {} ---@type string[]
  for _, key in
    ipairs(record.types --[[@as string[] ]])
  do
    types[#types + 1] = key --[[@as string]]
  end
  return types
end

---@param seeds table[] combatant seeds under fact resolution
---@return table<string, table<integer, table<string, unknown>>> static species facts for the arrival combatants
local function dexSpeciesFacts(seeds)
  local catalog = CatalogFixture.makeCatalog()
  local facts = {}
  for _, seed in ipairs(seeds) do
    local mon = seed.mon --[[@as table<string, unknown>]]
    local species = mon.species --[[@as string]]
    local form = mon.form --[[@as integer]]
    local speciesRecord = catalog:species(species)
    local bucket = facts[species]
    if bucket == nil then
      bucket = {}
      facts[species] = bucket
    end
    local formRecord = catalog:form(species, form)
    bucket[form] = {
      baseStats = formRecord.baseStats,
      growthCurve = catalog:growthCurve(speciesRecord.growthCurve --[[@as string]]),
      types = dexCopyFormTypes(formRecord),
      levelUpMoves = formRecord.levelUpMoves,
      baseExpYield = speciesRecord.baseExpYield,
      evYield = speciesRecord.evYield,
    }
  end
  return facts
end

---@return table frozen battle content carrying the native ruleset with the wild format
local function dexActionContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = dexExecutorOwner()
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "dex-arrival-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(Executor.RULESET, { key = Executor.RULESET, chart = Executor.RULESET }, "dex-arrival-tests")
  behaviors:registerFormat(DEX_WILD_FORMAT, { key = DEX_WILD_FORMAT }, "dex-arrival-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@param alpha table[] player-side combatant seeds in scenario order
---@param beta table[] opposing combatant seeds in scenario order
---@return table detached native battle setup record for arrival observation
local function dexActionScenario(alpha, beta)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local Executor = dexExecutorOwner()
  local seeds = {}
  for _, seed in ipairs(alpha) do
    seeds[#seeds + 1] = seed
  end
  for _, seed in ipairs(beta) do
    seeds[#seeds + 1] = seed
  end
  return {
    ruleset = Executor.RULESET,
    format = DEX_WILD_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", alpha),
      SessionFixture.participant(2, 2, "beta", beta),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, alpha[1].id),
      SessionFixture.position(2, 2, { 2 }, beta[1].id),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = DEX_NATIVE_SEED },
    formatState = {},
    moveFacts = dexMoveFacts(),
    speciesFacts = dexSpeciesFacts(seeds),
  }
end

---@param frame table waiting battle frame under inspection
---@param controller string decision producer owning the wanted request
---@return table the pending decision request for the controller
local function dexRequestFor(frame, controller)
  for _, request in ipairs(frame.request.requests) do
    if request.controller == controller then
      return request
    end
  end
  error("the arrival turn carries no request for " .. controller)
end

---@param session table live headless session under arrival observation
---@param collected table[] sink for every kernel event in emission order
---@return table the waiting frame once the answered turn settles
local function dexAdvanceCollecting(session, collected)
  for _ = 1, 64 do
    local frame = session:advance(64)
    Assert.notNil(frame, "advance publishes a battle frame")
    for _, event in ipairs(frame.events or {}) do
      collected[#collected + 1] = event
    end
    if frame.status == "waiting" or frame.status == "ended" then
      return frame
    end
  end
  error("the arrival exchange never settles")
end

---@param capture table<string, unknown> detached kernel capture under projection
---@return table<string, unknown> the same capture declaring the production player identity
local function asDexSnapshot(capture)
  capture.participants[1].controller = "player"
  return capture
end

---@return table kernel arrival fixture: live knowledge, projector, snapshots, and ordered switch events
local function driveArrivalSwitches()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime stages dex arrivals")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
  local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
  local monCatalog = PokedexDexFixture.makeCatalog()
  local knowledge = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, PokedexDexFixture.buildPokedexCatalog()))
  local alpha = {
    dexCombatant(1, 0xD06001, "CHIKORITA", 0),
    dexCombatant(3, 0xD06003, "TOTODILE", 0),
  }
  local beta = {
    dexCombatant(2, 0xD06002, "EEVEE", 0),
    dexCombatant(4, 0xD06004, "EEVEE", 1),
    dexCombatant(6, 0xD06006, "PICHU", 0),
  }
  local contracts = SessionFixture.sessionContracts()
  local session = contracts.Battle.newSession(dexActionScenario(alpha, beta), dexActionContent())
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the arrival battle opens on its decisions")
  local openingSnapshot = asDexSnapshot(session:capture())
  local turnEvents = {}
  local exchanges = {
    { outgoingAlpha = 1, incomingAlpha = 3, outgoingBeta = 2, incomingBeta = 4 },
    { outgoingAlpha = 3, incomingAlpha = 1, outgoingBeta = 4, incomingBeta = 2 },
  }
  for _, legs in ipairs(exchanges) do
    local pending = SessionFixture.driveUntilSettled(session)
    Assert.equal(pending.status, "waiting", "every arrival turn asks for its decisions")
    local alphaRequest = dexRequestFor(pending, "alpha")
    local betaRequest = dexRequestFor(pending, "beta")
    local alphaActor = assert(alphaRequest.actors[1], "the arrival turn addresses its alpha lead")
    local betaActor = assert(betaRequest.actors[1], "the arrival turn addresses its beta lead")
    Assert.equal(alphaActor.combatant, legs.outgoingAlpha, "the alpha exchange vacates its lead")
    Assert.equal(betaActor.combatant, legs.outgoingBeta, "the beta exchange vacates its lead")
    local alphaOk, alphaErr = session:submit(
      SessionFixture.replyFor(alphaRequest, { SessionFixture.switchChoice(alphaActor, legs.incomingAlpha) })
    )
    Assert.isTrue(alphaOk, "the alpha exchange is accepted: " .. tostring(alphaErr))
    local betaOk, betaErr = session:submit(
      SessionFixture.replyFor(betaRequest, { SessionFixture.switchChoice(betaActor, legs.incomingBeta) })
    )
    Assert.isTrue(betaOk, "the beta exchange is accepted: " .. tostring(betaErr))
    dexAdvanceCollecting(session, turnEvents)
  end
  local endSnapshot = asDexSnapshot(session:capture())
  -- The reserve changes form again after its appearance: the terminal
  -- mon no longer matches the entry checkpoint, so only the event-time
  -- facts can stage the correct physical variant.
  endSnapshot.combatants[4].mon.form = 0
  local box = { snapshot = openingSnapshot }
  local projector = setmetatable({
    _dex = knowledge,
    _session = {
      capture = function(_)
        return box.snapshot
      end,
    },
    _dexPlayerSide = nil,
    _dexOpened = false,
    _dexIdentities = {},
    _dexArrivals = {},
    _dexObservations = {},
    _dexPendingCaught = {},
    _dexProcessedCaptures = {},
  }, { __index = BattleRuntime })
  return {
    knowledge = knowledge,
    projector = projector,
    box = box,
    openingSnapshot = openingSnapshot,
    endSnapshot = endSnapshot,
    turnEvents = turnEvents,
    session = session,
  }
end

---@param events table[] kernel events in emission order
---@return table[] the switch events in emission order
local function switchEventsOf(events)
  local switches = {}
  for _, event in ipairs(events) do
    if type(event) == "table" and event.kind == "switch" then
      switches[#switches + 1] = event
    end
  end
  return switches
end

---@param value unknown
---@return unknown detached copy without shared mutable state
local function copyEvent(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyEvent(item)
  end
  return out
end

-- Switch arrivals stage from their event-time checkpoints: both turns'
-- real switch events arrive in one frame while the terminal capture
-- already shows the first entrants gone, so a terminal-state projection
-- has no active entry left to read for them.
function T.dex_switch_arrivals_stage_from_event_checkpoints()
  local fixture = driveArrivalSwitches()
  local projector = fixture.projector
  projector:_projectDexFacts({ events = {} })
  Assert.equal(#projector._dexObservations, 1, "the opening stages only the opposing lead")
  Assert.equal(projector._dexObservations[1].kind, "seen", "the opening sighting is a seen observation")
  Assert.equal(
    projector._dexObservations[1].specimen.species,
    "EEVEE",
    "the opening stages the actual opposing occupant"
  )
  Assert.equal(projector._dexObservations[1].specimen.form, 0, "the opening keeps its entry form")
  local switches = switchEventsOf(fixture.turnEvents)
  Assert.equal(#switches, 4, "both turns exchange on both sides")
  local betaEntry = nil
  for _, event in ipairs(switches) do
    if event.payload.to == 4 then
      betaEntry = event
    end
  end
  Assert.notNil(betaEntry, "the opposing reserve entry is observed")
  local checkpoint = assert(betaEntry.observation, "switch events carry their event-time checkpoint")
  local checkpointEntry = assert(checkpoint.combatants[4], "the checkpoint covers the incoming combatant")
  local expectedKey = "4:" .. tostring(assert(checkpointEntry.activation, "the checkpoint carries activation"))
  fixture.box.snapshot = fixture.endSnapshot
  projector:_projectDexFacts({ events = switches })
  Assert.equal(#projector._dexObservations, 3, "every genuine opposing appearance stages exactly once")
  Assert.equal(projector._dexObservations[2].kind, "seen", "the departed reserve still stages its sighting")
  Assert.equal(projector._dexObservations[2].specimen.species, "EEVEE", "the departed sighting names its species")
  Assert.equal(
    projector._dexObservations[2].specimen.form,
    1,
    "the departed sighting keeps its checkpoint form past the later change"
  )
  Assert.equal(projector._dexObservations[3].kind, "seen", "the returning lead stages its new appearance")
  Assert.equal(projector._dexObservations[3].specimen.form, 0, "the return keeps its own checkpoint form")
  Assert.isTrue(projector._dexArrivals[expectedKey] == true, "the departed entrant dedups by its checkpoint activation")
  for _, staged in ipairs(projector._dexObservations) do
    Assert.isFalse(staged.specimen.species == "PICHU", "the never-entered reserve stays unregistered")
    Assert.isFalse(
      staged.specimen.species == "CHIKORITA" or staged.specimen.species == "TOTODILE",
      "own-side appearances never stage sightings"
    )
  end
  for key in pairs(projector._dexArrivals) do
    Assert.isFalse(key:sub(1, 2) == "6:", "the never-entered reserve takes no dedup key")
  end
  fixture.knowledge:prepareChanges({ observations = projector._dexObservations }):publish()
  Assert.isTrue(fixture.knowledge:isSeen("EEVEE"), "the committed history sees the switched combatant")
  Assert.isFalse(fixture.knowledge:isSeen("PICHU"), "the committed history ignores unentered reserves")
  Assert.isFalse(fixture.knowledge:isCaught("EEVEE"), "sightings never invent a capture")
  projector:_projectDexFacts({ events = switches })
  Assert.equal(#projector._dexObservations, 3, "redelivery stages nothing twice")
  fixture.session:dispose()
end

-- The side policy survives the arrival refactor: the player's own Burmy
-- still contributes its caught appearance while every other own-side
-- arrival and every egg stays undescribed and unstaged, and the staged
-- copy carries the checkpoint form rather than the base identity.
function T.dex_arrival_side_policy_keeps_burmy_exception()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime stages dex arrivals")
  local described = {}
  local stubDex = {
    describe = function(_, mon)
      described[#described + 1] = mon.species
      return { species = mon.species, form = mon.form, isEgg = mon.isEgg == true, personality = 0 }
    end,
  }
  local projector = setmetatable({
    _dex = stubDex,
    _dexPlayerSide = 1,
    _dexIdentities = {},
    _dexArrivals = {},
    _dexObservations = {},
    _dexPendingCaught = {},
  }, { __index = BattleRuntime })
  projector:_recordDexArrival({
    combatantId = 3,
    activation = 7,
    form = 2,
    side = 1,
    mon = { species = "BURMY", form = 2 },
  })
  Assert.equal(#projector._dexObservations, 1, "the own-side Burmy stages its appearance")
  Assert.equal(projector._dexObservations[1].kind, "caught", "the Burmy appearance is a caught observation")
  Assert.equal(projector._dexObservations[1].specimen.form, 2, "the staged copy carries the checkpoint form")
  Assert.isTrue(projector._dexPendingCaught.BURMY == true, "the Burmy appearance marks its pending catch")
  Assert.isTrue(projector._dexArrivals["3:7"] == true, "the Burmy appearance takes its dedup key")
  projector:_recordDexArrival({
    combatantId = 1,
    activation = 5,
    form = 0,
    side = 1,
    mon = { species = "CHIKORITA", form = 0 },
  })
  Assert.equal(#projector._dexObservations, 1, "the ordinary own-side appearance stages nothing")
  Assert.isTrue(projector._dexArrivals["1:5"] == true, "the deliberate skip still takes its dedup key")
  for _, species in ipairs(described) do
    Assert.isFalse(species == "CHIKORITA", "the skipped own-side mon stays undescribed")
  end
  projector:_recordDexArrival({
    combatantId = 2,
    activation = 9,
    form = 0,
    side = 2,
    mon = { species = "EEVEE", form = 0, isEgg = true },
  })
  Assert.equal(#projector._dexObservations, 1, "the egg stages nothing")
  Assert.isTrue(projector._dexArrivals["2:9"] == true, "the egg skip still takes its dedup key")
  projector:_recordDexArrival({
    combatantId = 4,
    activation = 11,
    form = 1,
    side = 2,
    mon = { species = "EEVEE", form = 0 },
  })
  Assert.equal(#projector._dexObservations, 2, "the opposing appearance stages its sighting")
  Assert.equal(projector._dexObservations[2].kind, "seen", "the opposing appearance is a seen observation")
  Assert.equal(
    projector._dexObservations[2].specimen.form,
    1,
    "the staged copy carries the checkpoint form, not the base identity"
  )
end

-- A switch checkpoint without its activation errors loudly and never
-- poisons the dedup map: the corrected event still stages afterwards.
function T.dex_malformed_switch_checkpoints_fail_without_poisoning_dedup()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime stages dex arrivals")
  local fixture = driveArrivalSwitches()
  local projector = fixture.projector
  projector:_projectDexFacts({ events = {} })
  Assert.equal(#projector._dexObservations, 1, "the opening stages before the malformed event")
  local switches = switchEventsOf(fixture.turnEvents)
  local betaEntry = nil
  for _, event in ipairs(switches) do
    if event.payload.to == 4 then
      betaEntry = event
    end
  end
  Assert.notNil(betaEntry, "the opposing reserve entry is observed")
  local broken = copyEvent(betaEntry)
  broken.observation.combatants[4].activation = nil
  local ok, err = pcall(BattleRuntime._projectDexSwitch, projector, fixture.endSnapshot, broken)
  Assert.isFalse(ok, "the malformed checkpoint fails the switch projection")
  Assert.isTrue(tostring(err):find("activation") ~= nil, "the failure names the missing activation: " .. tostring(err))
  for key in pairs(projector._dexArrivals) do
    Assert.isFalse(key:sub(1, 2) == "4:", "the failed arrival takes no dedup key")
  end
  Assert.equal(#projector._dexObservations, 1, "the failed arrival stages nothing")
  projector:_projectDexSwitch(fixture.endSnapshot, betaEntry)
  Assert.equal(#projector._dexObservations, 2, "the corrected event still stages its sighting")
  Assert.equal(projector._dexObservations[2].specimen.species, "EEVEE", "the retry names its species")
  Assert.equal(projector._dexObservations[2].specimen.form, 1, "the retry keeps its checkpoint form")
  fixture.session:dispose()
end

return { tests = T }
