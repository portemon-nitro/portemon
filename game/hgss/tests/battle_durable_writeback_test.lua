-- Durable battle writeback through the real application runtime: every
-- legitimate in-battle change reaches the committed party exactly once,
-- and nothing else does. A cure that touches neither health nor power
-- points still publishes, and a lone held-item change still stages its
-- writeback. Power-point-only, progression, no-change, and
-- volatile-exclusion legs guard the comparison from both sides, and
-- repeated terminal polls never duplicate a write.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

---@param record table readiness owned by the test
---@return table headless five-operation presentation port
local function headlessPort(record)
  return {
    enter = function(_plan)
      record.enters = record.enters + 1
      return true
    end,
    present = function(packet)
      record.packets[#record.packets + 1] = packet
    end,
    ready = function()
      return true
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

---@param record table<string, unknown> full mon-domain record under test preparation
---@param moves table explicit move set replacing the default single strike
---@return table<string, unknown> the same record carrying the requested moves
local function withMoves(record, moves)
  record.moves = moves
  return record
end

---@param species string catalog species key under test preparation
---@param level integer battle level under test preparation
---@param seed integer fixed generator state under test preparation
---@return table full mon-domain record striking with a single known move
local function tackleRecord(species, level, seed)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  return withMoves(record, { { move = "TACKLE", pp = 35, ppUps = 0 } })
end

---@param species string catalog species key under test preparation
---@param level integer battle level under test preparation
---@param seed integer fixed generator state under test preparation
---@param moves table explicit move set replacing the default single strike
---@return table battle foe record with the requested move set
local function foeWithMoves(species, level, seed, moves)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local foe = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  foe.moves = moves
  return foe
end

---@param spec table lead/reserve description under test preparation
---@return table live party owner holding the described pair
local function makeParty(leadSpec, reserveSpec)
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
  for _, spec in ipairs({ leadSpec, reserveSpec }) do
    local factory = CatalogFixture.makeFactory(spec.seed, catalog)
    local req = { species = spec.species, level = spec.level }
    if spec.ability ~= nil then
      req.ability = spec.ability
    end
    local record = withMoves(
      factory:createNormal(CatalogFixture.normalRequest(req)),
      spec.moves or { { move = "TACKLE", pp = 35, ppUps = 0 } }
    )
    Assert.isTrue(owner:addMon(record), "the writeback path needs its live party member")
  end
  return owner
end

---@param id string launch identity under test preparation
---@return table wild launch request carrying the required species payload
local function wildLaunch(id)
  return {
    id = id,
    kind = "wild",
    payload = {
      attemptId = id .. "-attempt",
      species = "EEVEE",
      form = 0,
      level = 4,
      personality = 1,
      ability = "RUN_AWAY",
    },
  }
end

---@param launch table launch request under test driving
---@param scenario table detached production scenario under test driving
---@param party table live party owner under test driving
---@param bag table live bag owner under test driving
---@param port table presentation port under test driving
---@param seed integer fixed battle stream seed under test driving
---@return table live application battle under test driving
local function startBattle(launch, scenario, party, bag, port, seed)
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  return BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = port,
    seed = seed,
  })
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
---@param budget integer maximum update ticks before the driver gives up
---@return table<string, unknown> status once the lifetime settled
local function driveToSettled(battle, budget)
  for _ = 1, budget do
    battle:update()
    local current = battle:status()
    if current.phase == "complete" or current.phase == "failed" then
      return current
    end
    if current.phase == "running" and current.request ~= nil then
      local SessionFixture = require("libs.battle.tests.session_fixture")
      local addressed = assert(current.request.actors[1], "every decision addresses its combatant")
      local fled, err = battle:submit(SessionFixture.replyFor(current.request, {
        { actor = addressed, kind = "run", payload = {} },
      }))
      Assert.isTrue(fled, "the writeback driver flees to settle: " .. tostring(err))
    end
  end
  error("the battle never settled")
end

---@param value unknown
---@return unknown detached copy without shared mutable state
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

-- A cure that touches neither health nor power points still publishes: a
-- paralyzed lead served its bagged Cheri Berry and fled keeps full health
-- and full power points, yet the cleared condition reaches the party.
function T.condition_only_change_publishes_without_touching_health()
  local Status = require("libs.battle.src.gen4.Status")
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local Committer = require("libs.hgss.src.battle.HgssBattleCommitter")
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333, ability = "RUN_AWAY" },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  do
    local lead = party:partyMon(0)
    Assert.isTrue(
      Status.apply(lead, "paralysis", { kind = "setup" }, {}),
      "the setup stages its persistent condition through the condition owner"
    )
    local prep = party:preparePartyBatch(party:partyRevision(), { { slot = 0, mon = lead } }, {})
    Assert.notNil(prep, "the staged condition reaches the live party")
    prep.publish()
    local stored = party:partyMon(0)
    Assert.equal(#stored.condition.effects, 1, "the lead enters paralyzed")
  end
  local entryRevision = party:partyRevision()
  local entryLead = copyValue(party:partyMon(0)) --[[@as table<string, unknown>]]
  local entryCondition = entryLead.condition --[[@as table<string, unknown>]]
  local maxHp = entryCondition.currentHp --[[@as integer]]
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  Assert.isTrue(bag:add("CHERI_BERRY", 1), "the cure stages through the live bag")
  local foe = foeWithMoves("TOTODILE", 4, 0x5EED0002, { { move = "GROWL", pp = 40, ppUps = 0 } })
  local launch = wildLaunch("launch-writeback-condition-only")
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = { enters = 0, packets = {}, leaves = 0, disposed = 0 }
  local battle = startBattle(launch, scenario, party, bag, headlessPort(portRecord), 0x12345678)

  local opening = driveToDecision(battle, 400)
  local request = assert(opening.request, "the cure battle asks for its opening decision")
  local actor = assert(request.actors[1], "the opening decision addresses its lead")
  local served, serveErr = battle:submit(SessionFixture.replyFor(request, {
    {
      actor = actor,
      kind = "item",
      payload = { item = "CHERI_BERRY", target = { kind = "combatant", combatant = actor.combatant } },
    },
  }))
  Assert.isTrue(served, "the cure serving is accepted: " .. tostring(serveErr))
  local following = nil
  for _ = 1, 400 do
    battle:update()
    local current = battle:status()
    Assert.isTrue(current.phase ~= "failed", "the cure battle never fails")
    if current.phase == "complete" then
      break
    end
    if current.phase == "running" and current.request ~= nil and current.request.requestId ~= request.requestId then
      following = current.request
      break
    end
  end
  following = assert(following, "the served turn returns to a fresh decision")
  local addressed = assert(following.actors[1], "the fresh decision addresses its lead")
  local fled, fledErr = battle:submit(SessionFixture.replyFor(following, {
    { actor = addressed, kind = "run", payload = {} },
  }))
  Assert.isTrue(fled, "the cured lead flees to settle: " .. tostring(fledErr))
  local final = driveToSettled(battle, 800)
  Assert.equal(final.phase, "complete", "the cure battle settles")

  -- The missing durable leg: health never moved and no progression was
  -- earned, so only the normalized condition comparison can stage this
  -- writeback.
  local receipt = assert(Committer.receipt(launch.id), "completion carries its committer receipt")
  Assert.isTrue(receipt.committed, "the cure commits through the existing committer")
  local stored = party:partyMon(0)
  local storedCondition = stored.condition --[[@as table<string, unknown>]]
  Assert.deepEqual(storedCondition.effects, {}, "the cleared condition reaches the committed party")
  Assert.equal(storedCondition.currentHp, maxHp, "untouched health stays untouched")
  local storedMoves = stored.moves --[[@as table<integer, table<string, unknown>>]]
  local entryMoves = entryLead.moves --[[@as table<integer, table<string, unknown>>]]
  Assert.deepEqual(storedMoves, entryMoves, "unspent power points stay unspent")
  Assert.equal(bag:quantity("CHERI_BERRY"), 0, "the serving publishes exactly once")
  Assert.equal(party:partyRevision(), entryRevision + 1, "the cure publishes exactly one revision")
  battle:dispose()
end

-- A lone held-item change still stages its writeback: the runtime
-- comparison covers normalized held items beside health and progression,
-- so a candidate differing only in its holding is published through the
-- existing committer batch.
function T.held_item_only_candidate_publishes_through_staged_writeback()
  local Committer = require("libs.hgss.src.battle.HgssBattleCommitter")
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  local entryRevision = party:partyRevision()
  local live = party:partyMon(0)
  local liveCondition = live.condition --[[@as table<string, unknown>]]
  local entryHp = liveCondition.currentHp --[[@as integer]]
  local staged = copyValue(live) --[[@as table<string, unknown>]]
  staged.heldItem = "AMULET_COIN"
  local launchId = "launch-writeback-held-only"
  local battle = BattleRuntime.new({
    request = { id = launchId, kind = "wild", payload = { species = "TOTODILE", level = 4 } },
    party = party,
  })
  battle._session = {
    dispose = function(_) end,
    capture = function(_self)
      return {
        combatants = {
          {
            participant = 1,
            hp = entryHp,
            entryHp = entryHp,
            source = { kind = "party", slot = 1 },
            mon = copyValue(staged),
          },
        },
        participants = { { controller = "player" } },
      }
    end,
  }
  -- Health never moved and no progression was earned, so only the
  -- normalized held-item comparison can stage this writeback.
  local updates = battle:_partyUpdates()
  Assert.equal(#updates, 1, "a lone held-item change still stages its writeback")
  local stagedUpdate = updates[1] --[[@as table<string, unknown>]]
  Assert.equal(stagedUpdate.slot, 0, "the staged writeback names the live slot")
  local stagedMon = stagedUpdate.mon --[[@as table<string, unknown>]]
  Assert.equal(stagedMon.heldItem, "AMULET_COIN", "the staged writeback carries the new holding")
  local prepared = Committer.prepare({
    outcome = { id = launchId, result = "win" },
    partyOwner = party,
    partyUpdates = updates,
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the held-item batch commits")
  Assert.equal(party:partyMon(0).heldItem, "AMULET_COIN", "the new holding reaches the committed party")
  Assert.equal(party:partyRevision(), entryRevision + 1, "the holding publishes exactly one revision")
  battle:dispose()
end

-- A lone condition change still stages its writeback through the same
-- normalized candidate path: a staged paralysis with full health is
-- published, proving the comparison reads major conditions.
function T.condition_only_candidate_publishes_through_staged_writeback()
  local Status = require("libs.battle.src.gen4.Status")
  local Committer = require("libs.hgss.src.battle.HgssBattleCommitter")
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  local entryRevision = party:partyRevision()
  local live = party:partyMon(0)
  local liveCondition = live.condition --[[@as table<string, unknown>]]
  local entryHp = liveCondition.currentHp --[[@as integer]]
  local staged = copyValue(live) --[[@as table<string, unknown>]]
  Assert.isTrue(
    Status.apply(staged, "paralysis", { kind = "setup" }, {}),
    "the staged candidate carries its persistent condition"
  )
  local launchId = "launch-writeback-condition-staged"
  local battle = BattleRuntime.new({
    request = { id = launchId, kind = "wild", payload = { species = "TOTODILE", level = 4 } },
    party = party,
  })
  battle._session = {
    dispose = function(_) end,
    capture = function(_self)
      return {
        combatants = {
          {
            participant = 1,
            hp = entryHp,
            entryHp = entryHp,
            source = { kind = "party", slot = 1 },
            mon = copyValue(staged),
          },
        },
        participants = { { controller = "player" } },
      }
    end,
  }
  local updates = battle:_partyUpdates()
  Assert.equal(#updates, 1, "a lone condition change still stages its writeback")
  local stagedUpdate = updates[1] --[[@as table<string, unknown>]]
  Assert.equal(stagedUpdate.slot, 0, "the staged writeback names the live slot")
  local prepared = Committer.prepare({
    outcome = { id = launchId, result = "win" },
    partyOwner = party,
    partyUpdates = updates,
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the condition batch commits")
  Assert.equal(#party:partyMon(0).condition.effects, 1, "the condition reaches the committed party")
  Assert.equal(party:partyRevision(), entryRevision + 1, "the condition publishes exactly one revision")
  battle:dispose()
end

-- Spent power points alone still publish: a harmless tail-whip and a
-- flee leave health, condition, and progression untouched, yet the move
-- record reaches the party without leaking the foe's volatile stage
-- drop. Repeated terminal polls never duplicate the write.
function T.pp_only_change_publishes_without_leaking_volatile_stages()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local Committer = require("libs.hgss.src.battle.HgssBattleCommitter")
  local party = makeParty({
    species = "EEVEE",
    level = 20,
    seed = 0x33333333,
    ability = "RUN_AWAY",
    moves = { { move = "TAIL_WHIP", pp = 30, ppUps = 0 } },
  }, { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" })
  local entryRevision = party:partyRevision()
  local entryLead = copyValue(party:partyMon(0)) --[[@as table<string, unknown>]]
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local foe = foeWithMoves("TOTODILE", 4, 0x5EED0002, { { move = "GROWL", pp = 40, ppUps = 0 } })
  local launch = wildLaunch("launch-writeback-pp-only")
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = { enters = 0, packets = {}, leaves = 0, disposed = 0 }
  local battle = startBattle(launch, scenario, party, bag, headlessPort(portRecord), 0x12345678)

  local opening = driveToDecision(battle, 400)
  local request = assert(opening.request, "the power-point battle asks for its opening decision")
  local actor = assert(request.actors[1], "the opening decision addresses its lead")
  local struck, struckErr = battle:submit(SessionFixture.replyFor(request, {
    SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)),
  }))
  Assert.isTrue(struck, "the harmless weakening is accepted: " .. tostring(struckErr))
  local following = nil
  for _ = 1, 400 do
    battle:update()
    local current = battle:status()
    Assert.isTrue(current.phase ~= "failed", "the power-point battle never fails")
    if current.phase == "complete" then
      break
    end
    if current.phase == "running" and current.request ~= nil and current.request.requestId ~= request.requestId then
      following = current.request
      break
    end
  end
  following = assert(following, "the weakened turn returns to a fresh decision")
  local addressed = assert(following.actors[1], "the fresh decision addresses its lead")
  local fled, fledErr = battle:submit(SessionFixture.replyFor(following, {
    { actor = addressed, kind = "run", payload = {} },
  }))
  Assert.isTrue(fled, "the weakened lead flees to settle: " .. tostring(fledErr))
  local final = driveToSettled(battle, 800)
  Assert.equal(final.phase, "complete", "the power-point battle settles")

  local receipt = assert(Committer.receipt(launch.id), "completion carries its committer receipt")
  Assert.isTrue(receipt.committed, "the power-point change commits")
  local stored = party:partyMon(0)
  local storedMoves = stored.moves --[[@as table<integer, table<string, unknown>>]]
  Assert.equal(storedMoves[1].pp, 29, "the spent power point reaches the committed party")
  local storedCondition = stored.condition --[[@as table<string, unknown>]]
  local entryCondition = entryLead.condition --[[@as table<string, unknown>]]
  Assert.equal(storedCondition.currentHp, entryCondition.currentHp, "untouched health stays untouched")
  Assert.deepEqual(storedCondition.effects, {}, "no condition leaks into the committed party")
  Assert.isNil(stored.stages, "battle-local stages never leak into the saved record")
  Assert.equal(party:partyRevision(), entryRevision + 1, "the power-point change publishes exactly one revision")
  battle:update()
  battle:update()
  Assert.deepEqual(Committer.receipt(launch.id), receipt, "repeated terminal polls never republish")
  Assert.equal(party:partyRevision(), entryRevision + 1, "repeated terminal polls never duplicate a write")
  battle:dispose()
  battle:dispose()
end

-- An untouched battle publishes nothing: fleeing on the opening turn
-- stages no party writeback, moves no revision, and still settles
-- through the existing committer.
function T.untouched_battle_publishes_no_writeback()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local Committer = require("libs.hgss.src.battle.HgssBattleCommitter")
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333, ability = "RUN_AWAY" },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  local entryRevision = party:partyRevision()
  local entryLead = copyValue(party:partyMon(0)) --[[@as table<string, unknown>]]
  local entryReserve = copyValue(party:partyMon(1)) --[[@as table<string, unknown>]]
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local foe = foeWithMoves("TOTODILE", 4, 0x5EED0007, { { move = "GROWL", pp = 40, ppUps = 0 } })
  local launch = wildLaunch("launch-writeback-untouched")
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = { enters = 0, packets = {}, leaves = 0, disposed = 0 }
  local battle = startBattle(launch, scenario, party, bag, headlessPort(portRecord), 0x12345678)
  local final = driveToSettled(battle, 800)
  Assert.equal(final.phase, "complete", "the untouched battle settles")

  local receipt = assert(Committer.receipt(launch.id), "completion carries its committer receipt")
  Assert.isTrue(receipt.committed, "the untouched battle still settles through the committer")
  Assert.deepEqual(party:partyMon(0), entryLead, "an unchanged lead is not rewritten")
  Assert.deepEqual(party:partyMon(1), entryReserve, "an unchanged reserve is not rewritten")
  Assert.equal(party:partyRevision(), entryRevision, "an untouched battle moves no revision")
  battle:dispose()
end

-- Nested packet records are detached too: mutating delivered events,
-- checkpoints, and views changes neither the kernel nor later packets,
-- and per-launch packet identities restart with every launch.
function T.delivery_packets_are_detached_at_every_nested_record()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 20, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local foe = foeWithMoves("EEVEE", 20, 0x5EED0002, { { move = "TACKLE", pp = 35, ppUps = 0 } })
  local launch = wildLaunch("launch-writeback-detached")
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = { enters = 0, packets = {}, leaves = 0, disposed = 0 }
  local battle = startBattle(launch, scenario, party, bag, headlessPort(portRecord), 0x12345678)
  local opening = driveToDecision(battle, 400)
  local request = assert(opening.request, "the detached battle asks for its opening decision")
  local actor = assert(request.actors[1], "the opening decision addresses its lead")
  Assert.isTrue(
    battle:submit(SessionFixture.replyFor(request, {
      SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)),
    })),
    "the opening strike is accepted"
  )
  for _ = 1, 120 do
    battle:update()
    local current = battle:status()
    if current.phase ~= "running" then
      break
    end
    if current.request ~= nil and current.request.requestId ~= request.requestId then
      break
    end
  end
  Assert.isTrue(#portRecord.packets > 0, "the answered turn delivers its packets")
  local first = portRecord.packets[1] --[[@as table<string, unknown>]]
  first.packetId = -1
  local firstEvents = first.events --[[@as table<integer, table<string, unknown>>]]
  if #firstEvents > 0 then
    firstEvents[1].payload = { damage = -9999 }
    firstEvents[1].after = {}
  end
  local firstAfter = first.after --[[@as table<string, unknown>]]
  local firstOwn = firstAfter.own --[[@as table<integer, table<string, unknown>>]]
  if #firstOwn > 0 then
    firstOwn[1].hp = -1
  end
  local beforeCount = #portRecord.packets
  for _ = 1, 1200 do
    battle:update()
    local current = battle:status()
    if current.phase == "complete" or current.phase == "failed" then
      break
    end
    if current.phase == "running" and current.request ~= nil then
      local pending = current.request
      local addressed = assert(pending.actors[1], "every later decision addresses its combatant")
      battle:submit(SessionFixture.replyFor(pending, {
        SessionFixture.attackChoice(addressed, 0, SessionFixture.positionTarget(2)),
      }))
    end
  end
  Assert.equal(battle:status().phase, "complete", "mutating nested records never disturbs the kernel")
  Assert.isTrue(#portRecord.packets > beforeCount, "later packets arrive intact after nested mutation")
  for index = 2, #portRecord.packets do
    local packet = portRecord.packets[index] --[[@as table<string, unknown>]]
    Assert.equal(packet.packetId, index, "per-launch packet identities increase in delivery order")
  end
  battle:dispose()
end

-- The port contract validates loudly: a port missing an operation is
-- rejected at construction, while an absent port stays an explicitly
-- synchronous headless lifetime.
function T.presentation_port_shape_validates_at_construction()
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local incomplete = {
    enter = function(_plan)
      return true
    end,
    present = function(_packet) end,
    leave = function(_plan)
      return true
    end,
    dispose = function() end,
  }
  local ok, _ = pcall(BattleRuntime.new, {
    request = { id = "launch-writeback-port-shape", kind = "wild", payload = { species = "TOTODILE", level = 4 } },
    presentation = incomplete,
  })
  Assert.isFalse(ok, "a port missing an operation never attaches silently")
  local headless = BattleRuntime.new({
    request = { id = "launch-writeback-headless", kind = "wild", payload = { species = "TOTODILE", level = 4 } },
  })
  for _ = 1, 20 do
    headless:update()
  end
  Assert.equal(headless:status().phase, "complete", "the headless lifetime stays synchronous")
  headless:dispose()
end

-- A legally selected serving may still refuse at execution: a potion on
-- a healthy holder is accepted, then refused without consuming stock,
-- health, or power points, and the battle continues.
function T.effect_less_serving_refuses_at_execution_without_consuming()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local Committer = require("libs.hgss.src.battle.HgssBattleCommitter")
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333, ability = "RUN_AWAY" },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  local entryLead = copyValue(party:partyMon(0)) --[[@as table<string, unknown>]]
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  Assert.isTrue(bag:add("POTION", 1), "the refused serving stages through the live bag")
  local foe = foeWithMoves("TOTODILE", 4, 0x5EED0002, { { move = "GROWL", pp = 40, ppUps = 0 } })
  local launch = wildLaunch("launch-writeback-refused-serving")
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = { enters = 0, packets = {}, leaves = 0, disposed = 0 }
  local battle = startBattle(launch, scenario, party, bag, headlessPort(portRecord), 0x12345678)
  local opening = driveToDecision(battle, 400)
  local request = assert(opening.request, "the serving battle asks for its opening decision")
  local actor = assert(request.actors[1], "the opening decision addresses its lead")
  local served, serveErr = battle:submit(SessionFixture.replyFor(request, {
    {
      actor = actor,
      kind = "item",
      payload = { item = "POTION", target = { kind = "combatant", combatant = actor.combatant } },
    },
  }))
  Assert.isTrue(served, "the effect-less serving is still a legal selection: " .. tostring(serveErr))
  local following = nil
  for _ = 1, 400 do
    battle:update()
    local current = battle:status()
    Assert.isTrue(current.phase ~= "failed", "the refused serving never fails the battle")
    if current.phase == "complete" then
      break
    end
    if current.phase == "running" and current.request ~= nil and current.request.requestId ~= request.requestId then
      following = current.request
      break
    end
  end
  following = assert(following, "the refused turn returns to a fresh decision")
  local refused = false
  for _, packet in ipairs(portRecord.packets) do
    for _, event in
      ipairs((packet --[[@as table<string, unknown>]]).events --[[@as table<integer, unknown>]])
    do
      local entry = event --[[@as table<string, unknown>]]
      local payload = entry.payload --[[@as table<string, unknown>]]
      if entry.kind == "item" and type(payload) == "table" and payload.refused == "no_effect" then
        refused = true
      end
    end
  end
  Assert.isTrue(refused, "execution refuses the effect-less serving without consuming it")
  local addressed = assert(following.actors[1], "the fresh decision addresses its lead")
  Assert.isTrue(
    battle:submit(SessionFixture.replyFor(following, {
      { actor = addressed, kind = "run", payload = {} },
    })),
    "the battle continues after the refusal"
  )
  local final = driveToSettled(battle, 800)
  Assert.equal(final.phase, "complete", "the refused-serving battle settles")
  Assert.equal(bag:quantity("POTION"), 1, "the refused serving consumes no stock")
  local stored = party:partyMon(0)
  local storedMoves = stored.moves --[[@as table<integer, table<string, unknown>>]]
  local entryMoves = entryLead.moves --[[@as table<integer, table<string, unknown>>]]
  Assert.deepEqual(storedMoves, entryMoves, "the refused turn spends no power points")
  local receipt = assert(Committer.receipt(launch.id), "completion carries its committer receipt")
  Assert.isTrue(receipt.committed, "the refused-serving battle still settles through the committer")
  battle:dispose()
end

-- Terminal presentation polls: a withholding leave holds the returning
-- lifetime without fabricating anything, and release completes it.
function T.withheld_leave_holds_returning_until_released()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333, ability = "RUN_AWAY" },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local foe = foeWithMoves("TOTODILE", 4, 0x5EED0007, { { move = "GROWL", pp = 40, ppUps = 0 } })
  local launch = wildLaunch("launch-writeback-leave")
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local record = { release = false, leaves = 0, disposed = 0 }
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = {
      enter = function(_plan)
        return true
      end,
      present = function(_packet) end,
      ready = function()
        return true
      end,
      leave = function(_plan)
        record.leaves = record.leaves + 1
        return record.release
      end,
      dispose = function()
        record.disposed = record.disposed + 1
      end,
    },
    seed = 0x12345678,
  })
  local final = nil
  for _ = 1, 800 do
    battle:update()
    local current = battle:status()
    if current.phase == "returning" or current.phase == "complete" or current.phase == "failed" then
      final = current
      break
    end
    if current.phase == "running" and current.request ~= nil then
      local SessionFixture = require("libs.battle.tests.session_fixture")
      local addressed = assert(current.request.actors[1], "every decision addresses its combatant")
      local fled, err = battle:submit(SessionFixture.replyFor(current.request, {
        { actor = addressed, kind = "run", payload = {} },
      }))
      Assert.isTrue(fled, "the leave-hold driver flees to settle: " .. tostring(err))
    end
  end
  final = assert(final, "the leave-hold battle settles its mechanics")
  Assert.equal(final.phase, "returning", "the leave-hold battle settles its mechanics but waits on leave")
  for _ = 1, 20 do
    battle:update()
  end
  Assert.equal(battle:status().phase, "returning", "a withheld leave holds the returning lifetime")
  Assert.isTrue(record.leaves > 1, "terminal presentation keeps polling while held")
  record.release = true
  battle:update()
  Assert.equal(battle:status().phase, "complete", "release completes the held lifetime")
  battle:dispose()
  Assert.equal(record.disposed, 1, "teardown still releases the port exactly once")
end

-- The product boundary filters: own entries carry party slots, moves,
-- and progression while visible opponents carry only identity, health,
-- and appearance; nested event checkpoints never carry move stores or
-- stock.
function T.product_boundary_filters_private_state_from_packets()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local foe = foeWithMoves("EEVEE", 20, 0x5EED0002, { { move = "TACKLE", pp = 35, ppUps = 0 } })
  local launch = wildLaunch("launch-writeback-filtering")
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = { enters = 0, packets = {}, leaves = 0, disposed = 0 }
  local battle = startBattle(launch, scenario, party, bag, headlessPort(portRecord), 0x12345678)
  local opening = driveToDecision(battle, 400)
  local request = assert(opening.request, "the filtering battle asks for its opening decision")
  local actor = assert(request.actors[1], "the opening decision addresses its lead")
  Assert.isTrue(
    battle:submit(SessionFixture.replyFor(request, {
      SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)),
    })),
    "the filtering strike is accepted"
  )
  for _ = 1, 200 do
    battle:update()
    local current = battle:status()
    if current.phase ~= "running" then
      break
    end
    if current.request ~= nil and current.request.requestId ~= request.requestId then
      break
    end
  end
  Assert.isTrue(#portRecord.packets > 0, "the answered turn delivers its packets")
  local packet = portRecord.packets[#portRecord.packets] --[[@as table<string, unknown>]]
  local after = packet.after --[[@as table<string, unknown>]]
  local own = after.own --[[@as table<integer, table<string, unknown>>]]
  Assert.isTrue(#own >= 1, "the view carries the own roster")
  Assert.equal(own[1].slot, 0, "own entries map to their party slot")
  Assert.isTrue(type(own[1].moves) == "table" and #own[1].moves >= 1, "own entries carry move facts")
  Assert.isTrue(type(own[1].species) == "string", "own entries carry visible species")
  local foes = after.foes --[[@as table<integer, table<string, unknown>>]]
  Assert.isTrue(#foes >= 1, "the view carries the visible opponents")
  for _, foeEntry in ipairs(foes) do
    local record = foeEntry --[[@as table<string, unknown>]]
    Assert.isNil(record.moves, "opponents never expose move sets")
    Assert.isNil(record.slot, "opponents never expose party slots")
    Assert.isNil(record.heldItem, "opponents never expose holdings")
    Assert.isTrue(type(record.hp) == "number", "opponents expose health")
    Assert.isTrue(type(record.species) == "string", "opponents expose visible species")
    Assert.equal(record.selector, "front", "opponents read from the front selector")
  end
  Assert.equal(own[1].selector, "back", "the owning side reads from the back selector")
  for _, event in
    ipairs(packet.events --[[@as table<integer, table<string, unknown>>]])
  do
    local checkpoint = event.after --[[@as table<string, unknown>]]
    Assert.isTrue(type(checkpoint) == "table", "packet events carry their event-time checkpoint")
    Assert.isNil(checkpoint.moves, "nested checkpoints never carry move stores")
    Assert.isNil(checkpoint.inventories, "nested checkpoints never carry stock")
  end
  battle:dispose()
end

-- Earned knockout progression still publishes beside untouched health:
-- felling the foe stages experience and effort writeback for the
-- undamaged earner through the same normalized comparison.
function T.progression_change_publishes_beside_untouched_health()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local Committer = require("libs.hgss.src.battle.HgssBattleCommitter")
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  local entryLead = copyValue(party:partyMon(0)) --[[@as table<string, unknown>]]
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local foe = foeWithMoves("TOTODILE", 4, 0x5EED0002, { { move = "TACKLE", pp = 35, ppUps = 0 } })
  local launch = wildLaunch("launch-writeback-progression")
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = { enters = 0, packets = {}, leaves = 0, disposed = 0 }
  local battle = startBattle(launch, scenario, party, bag, headlessPort(portRecord), 0x12345678)

  for _ = 1, 1200 do
    battle:update()
    local current = battle:status()
    Assert.isTrue(current.phase ~= "failed", "the progression battle never fails")
    if current.phase == "complete" then
      break
    end
    if current.phase == "running" and current.request ~= nil then
      local addressed = assert(current.request.actors[1], "every decision addresses its combatant")
      if current.request.kind == "learn_move" or current.request.incomingMove ~= nil then
        Assert.isTrue(
          battle:submit({
            requestId = current.request.requestId,
            epoch = current.request.epoch,
            controller = current.request.controller,
            choices = {
              { actor = addressed, kind = "confirm", payload = { decision = "decline" } },
            },
          }),
          "a learning prompt declines without an entry token"
        )
      else
        local ok, err = battle:submit(SessionFixture.replyFor(current.request, {
          SessionFixture.attackChoice(addressed, 0, SessionFixture.positionTarget(2)),
        }))
        Assert.isTrue(ok, "every strike is accepted: " .. tostring(err))
      end
    end
  end
  local final = battle:status()
  Assert.equal(final.phase, "complete", "the progression battle settles")

  local receipt = assert(Committer.receipt(launch.id), "completion carries its committer receipt")
  Assert.isTrue(receipt.committed, "the progression commits")
  local stored = party:partyMon(0)
  Assert.isTrue(
    stored.experience --[[@as integer]] > entryLead.experience --[[@as integer]],
    "earned experience reaches the committed party"
  )
  battle:dispose()
end

return { tests = T }
