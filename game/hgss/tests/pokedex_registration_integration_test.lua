-- Battle appearance facts and first-catch publication through the real
-- application runtime: only opponents that actually enter the field are
-- recorded, a successful first capture freezes its detached identity on
-- the terminal result, publication waits for presentation readiness, and
-- later failures never publish partial consequences. Real session,
-- runtime, and committer behind recording presentation ports; no
-- renderer, GPU, or save is involved.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local Mon = require("libs.mons.src.Mon")
local Personality = require("libs.mons.src.gen4.Personality")

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

---@param record table full mon-domain record under test preparation
---@return table the same record striking with a single known move
local function tackleOnly(record)
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record --[[@as table<string, unknown>]]
end

---@param species string catalog species key under test preparation
---@param level integer battle level under test preparation
---@param seed integer fixed generator state under test preparation
---@return table full mon-domain record
local function foeRecord(species, level, seed)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  return tackleOnly(factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level })))
end

---@param spec table lead description under test preparation
---@param reserve table reserve description under test preparation
---@return table live party owner holding the described pair
local function makeParty(spec, reserve)
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
  for _, entry in ipairs({ spec, reserve }) do
    local factory = CatalogFixture.makeFactory(entry.seed, catalog)
    local req = { species = entry.species, level = entry.level }
    local record = tackleOnly(factory:createNormal(CatalogFixture.normalRequest(req)))
    Assert.isTrue(owner:addMon(record), "the appearance lifetime needs its live party member")
  end
  return owner
end

---@param count integer balls the double stocks under test preparation
---@return table minimal recording bag double holding master balls
local function masterBallBag(count)
  local stock = { MASTER_BALL = count }
  local revision = 0
  local bag = {}
  function bag:capture()
    return { pockets = { balls = { { item = "MASTER_BALL", quantity = stock.MASTER_BALL } } } }
  end
  function bag:revision()
    return revision
  end
  function bag:quantity(item)
    return stock[item] or 0
  end
  function bag:prepareInventoryChanges(expected, deltas)
    Assert.equal(expected, revision, "the staged preparation carries the construction revision")
    local liveRevision = revision
    local spent = 0
    for _, delta in ipairs(deltas) do
      Assert.equal(delta.op, "take", "the capture spends its ball through a take delta")
      spent = spent + delta.quantity
    end
    local prep = {}
    function prep:isCurrent()
      return revision == liveRevision
    end
    function prep:publish()
      stock.MASTER_BALL = stock.MASTER_BALL - spent
      revision = revision + 1
    end
    return prep
  end
  return bag
end

---@param record table packet log and readiness flag owned by the test
---@return table five-operation recording presentation port
local function recordingPort(record)
  return {
    enter = function(_plan)
      record.enters = record.enters + 1
      return true
    end,
    present = function(packet)
      record.packets[#record.packets + 1] = packet
    end,
    ready = function()
      record.readyCalls = record.readyCalls + 1
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

---@return table fresh packet log with controllable readiness
local function newPortRecord()
  return { ready = true, enters = 0, packets = {}, leaves = 0, disposed = 0, readyCalls = 0 }
end

---@param keys string[] dex species the knowledge owner tracks
---@return table dex knowledge over the appearance species set
local function newDexOwner(keys)
  local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
  local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
  return PokedexKnowledge.new(PokedexDexFixture.refsForSpecies(keys))
end

---@param monCatalog table shared synthetic domain catalog
---@param species string catalog species key under test driving
---@param personality integer observed personality under test driving
---@return string the gender the shared personality authority derives
local function expectedGender(monCatalog, species, personality)
  local ratio = assert(monCatalog:species(species).genderRatio, "the catalog names the species gender ratio")
  return Personality.gender(ratio, personality)
end

---@param battle table running application battle lifetime
---@param scenario table detached battle setup carrying the player roster
local function driveToSettlement(battle, scenario)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local claimed = {} ---@type table<integer, boolean>
  ---@param actor table fainted entry owed a reserve
  ---@return integer unclaimed roster member sharing the player side
  local function reserveFor(actor)
    local roster = scenario.participants[1].roster
    for _, seed in ipairs(roster) do
      local id = (seed --[[@as table<string, unknown>]]).id --[[@as integer]]
      if id ~= actor.combatant and not claimed[id] then
        claimed[id] = true
        return id
      end
    end
    error("the replacement needs an unclaimed reserve")
  end
  local ticks = 0
  while battle:status().phase ~= "complete" and battle:status().phase ~= "failed" and ticks < 1200 do
    battle:update()
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      local kinds = {}
      if current.request.legalChoices ~= nil then
        kinds = current.request.legalChoices.kinds
      end
      local admitsSwitch = false
      local admitsAttack = false
      for _, kind in ipairs(kinds) do
        if kind == "switch" then
          admitsSwitch = true
        end
        if kind == "attack" then
          admitsAttack = true
        end
      end
      local choices = {}
      for _, actor in ipairs(assert(current.request.actors, "a decision request names its actors")) do
        if admitsSwitch and not admitsAttack then
          choices[#choices + 1] = SessionFixture.switchChoice(actor, reserveFor(actor))
        else
          choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
        end
      end
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "a legal decision is accepted: " .. tostring(replyErr))
    end
    ticks = ticks + 1
  end
end

---@param seed integer fixed generator state for the wild foe
---@return table wild foe record with the requested seed
local function wildFoe(seed)
  return foeRecord("TOTODILE", 4, seed)
end

-- Only opponents that actually enter the field are recorded: the opening
-- occupant and the reserve that replaces the fainted opener join history
-- in encounter order with their actual genders, while the reserve that
-- never enters stays absent and a later repeat observation never reorders
-- first history.
function T.opening_and_switch_appearances_replace_unused_roster_sightings()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with consequence staging")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  local SessionFixture = require("libs.battle.tests.session_fixture")

  local opener = foeRecord("TOTODILE", 4, 0xAAAA0011)
  local enteringReserve = foeRecord("EEVEE", 30, 0xAAAA0012)
  local untouchedReserve = foeRecord("CHIKORITA", 4, 0xAAAA0013)
  local party = makeParty({ species = "EEVEE", level = 5, seed = 0x33333333 }, { species = "EEVEE", level = 5, seed = 0x44444444 })
  local dex = newDexOwner({ "TOTODILE", "EEVEE", "CHIKORITA" })
  local trainers = {
    {
      id = "rival-early",
      class = 2,
      party = { opener, enteringReserve, untouchedReserve },
      partyLevels = { 4, 30, 4 },
      prizeMoney = { trainerClass = 2, classRate = 4 },
      program = { key = "rival_opening", revision = "native-1", instructions = {}, entryPoints = {} },
      aiPasses = {},
    },
  }
  local scenario =
    ScenarioFactory.fromTrainer({ id = "launch-appearance", trainers = trainers }, {
      party = party,
      player = { trainerId = 99, trainerName = "MINT", language = "french" },
    })
  local portRecord = newPortRecord()
  local battle = BattleRuntime.new({
    request = { id = "launch-appearance", kind = "trainer", payload = { trainer = "rival-early" } },
    scenario = scenario,
    party = party,
    presentation = recordingPort(portRecord),
    dex = dex,
    seed = 0x12345678,
  })
  driveToSettlement(battle, scenario)
  Assert.equal(battle:status().phase, "complete", "answered decisions settle the loss")
  Assert.equal(battle:status().result, "loss", "the overpowering reserve closes the battle as a loss")

  Assert.isTrue(dex:isSeen("TOTODILE"), "the opening opponent is recorded")
  Assert.isTrue(dex:isSeen("EEVEE"), "the reserve that enters on the faint is recorded")
  Assert.isFalse(
    dex:isSeen("CHIKORITA"),
    "the reserve that never enters stays absent instead of staging the whole roster"
  )

  local monCatalog = CatalogFixture.makeCatalog()
  Assert.deepEqual(
    dex:observedGenders("TOTODILE"),
    { expectedGender(monCatalog, "TOTODILE", opener.personality) },
    "the opener keeps its actual observed gender"
  )
  Assert.deepEqual(
    dex:observedGenders("EEVEE"),
    { expectedGender(monCatalog, "EEVEE", enteringReserve.personality) },
    "the entering reserve keeps its actual observed gender"
  )
  Assert.deepEqual(dex:observedGenders("CHIKORITA"), {}, "the absent reserve records no gender history")

  -- A repeat observation of the entering species with a new personality
  -- appends without reordering: the first personality stays first.
  local firstGender = expectedGender(monCatalog, "EEVEE", enteringReserve.personality)
  local repeatFoe = nil
  for offset = 1, 40 do
    local factory = CatalogFixture.makeFactory(0xBEEF0000 + offset, monCatalog)
    local candidate = factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", level = 4 }))
    if expectedGender(monCatalog, "EEVEE", candidate.personality) ~= firstGender then
      repeatFoe = tackleOnly(candidate)
      break
    end
  end
  repeatFoe = assert(repeatFoe, "the repeat observation needs a differing observed gender")
  local freshParty = makeParty(
    { species = "EEVEE", level = 5, seed = 0x55555555, ability = "RUN_AWAY" },
    { species = "EEVEE", level = 5, seed = 0x66666666, ability = "RUN_AWAY" }
  )
  local repeatLaunch = {
    id = "launch-appearance-repeat",
    kind = "wild",
    payload = { species = "EEVEE", level = 4, attemptId = "launch-appearance-repeat-attempt", mon = repeatFoe },
  }
  local repeatScenario = ScenarioFactory.fromEncounter(
    { attemptId = repeatLaunch.payload.attemptId, mon = repeatFoe },
    { party = freshParty, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local repeatRecord = newPortRecord()
  local repeatBattle = BattleRuntime.new({
    request = repeatLaunch,
    scenario = repeatScenario,
    party = freshParty,
    presentation = recordingPort(repeatRecord),
    dex = dex,
    seed = 0x12345678,
  })
  for _ = 1, 800 do
    repeatBattle:update()
    local current = repeatBattle:status()
    if current.phase == "complete" or current.phase == "failed" then
      break
    end
    if current.phase == "running" and current.request ~= nil then
      local actor = assert(current.request.actors[1], "the repeat battle addresses its lead")
      local accepted, replyErr = repeatBattle:submit(
        SessionFixture.replyFor(current.request, { { actor = actor, kind = "run", payload = {} } })
      )
      Assert.isTrue(accepted, "the repeat escape is accepted: " .. tostring(replyErr))
    end
  end
  Assert.equal(repeatBattle:status().phase, "complete", "the repeat escape settles")
  Assert.equal(repeatBattle:status().result, "flee", "the repeat leg escapes instead of refighting")
  Assert.deepEqual(
    dex:observedGenders("EEVEE"),
    { firstGender, expectedGender(monCatalog, "EEVEE", repeatFoe.personality) },
    "a repeat observation appends its gender after first history"
  )
  Assert.isNil(
    dex:firstPersonality("EEVEE"),
    "repeats never reorder the first observed personality"
  )
  repeatBattle:dispose()
  battle:dispose()
end

---@param battle table running application battle lifetime
---@param budget integer maximum update ticks before the driver gives up
local function driveToCompletion(battle, budget)
  for _ = 1, (budget or 1200) do
    battle:update()
    local current = battle:status()
    if current.phase == "complete" or current.phase == "failed" then
      return
    end
  end
  error("the held lifetime never settles", 0)
end

-- A successful first capture freezes its detached identity on the
-- terminal result and publishes nothing until presentation readiness:
-- capture facts, name, and number mode travel with the result, live
-- owners stay untouched through the hold, and one commit lands the
-- mon, history, and receipt exactly once.
function T.first_capture_freezes_a_detached_identity_and_waits_for_readiness()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with consequence staging")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")

  local foe = wildFoe(0xC0FFEE01)
  local monCatalog = CatalogFixture.makeCatalog()
  local party = makeParty({ species = "EEVEE", level = 20, seed = 0x33333333 }, { species = "EEVEE", level = 5, seed = 0x44444444 })
  local bag = masterBallBag(2)
  local dex = newDexOwner({ "CHIKORITA", "TOTODILE" })
  local launch = {
    id = "launch-first-catch",
    kind = "wild",
    payload = { species = "TOTODILE", level = 4, attemptId = "launch-first-catch-attempt", mon = foe },
  }
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.payload.attemptId, mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = newPortRecord()
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = recordingPort(portRecord),
    dex = dex,
    seed = 0x12345678,
  })

  -- Drive only to the terminal packet, then hold readiness back: the
  -- frozen facts must already be visible while publication waits.
  local terminal = nil
  do
    local SessionFixture = require("libs.battle.tests.session_fixture")
    local thrown = false
    for _ = 1, 1200 do
      battle:update()
      for _, packet in ipairs(portRecord.packets) do
        if type(packet) == "table" and type(packet.result) == "table" then
          terminal = packet
          break
        end
      end
      if terminal ~= nil then
        break
      end
      local current = battle:status()
      if current.phase == "complete" or current.phase == "failed" then
        break
      end
      if current.phase == "running" and current.request ~= nil and not thrown then
        local actor = assert(current.request.actors[1], "the capture battle addresses its lead")
        local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, {
          { actor = actor, kind = "item", payload = { item = "MASTER_BALL", target = { kind = "combatant", combatant = party:partyCount() + 1 } } },
        }))
        Assert.isTrue(accepted, "the guaranteed throw is accepted: " .. tostring(replyErr))
        thrown = true
      end
    end
  end
  terminal = assert(terminal, "the capture ships its terminal result before publication")
  local registration = terminal.result.registration
  Assert.notNil(registration, "the terminal result carries the frozen first-catch facts")
  Assert.isTrue(type(registration.mode) == "string" and registration.mode ~= "", "eligibility freezes the actual capture mode")
  Assert.equal(registration.dexMode, "johto", "the card numbers in the live national mode")
  Assert.equal(registration.displayName, Mon.displayName(foe, monCatalog), "the announcement names the actual capture")
  Assert.deepEqual(registration.specimen, dex:describe(foe), "the card carries the exact captured specimen")

  -- Mutating the delivered packet cannot reach the staged candidate: the
  -- frozen facts were copied before delivery.
  registration.specimen.species = "CHIKORITA"
  registration.displayName = "MUTATED"

  portRecord.ready = false
  for _ = 1, 10 do
    battle:update()
  end
  Assert.isNil(battle:status().outcomeReceipt, "publication waits for presentation readiness")
  Assert.equal(battle:status().phase, "resolving", "the lifetime holds in resolving without publishing")
  Assert.equal(party:partyCount(), 2, "no mon lands while readiness is held")
  Assert.isFalse(dex:isCaught("TOTODILE"), "no caught history lands while readiness is held")
  Assert.equal(bag:quantity("MASTER_BALL"), 2, "no ball is spent while readiness is held")

  portRecord.ready = true
  driveToCompletion(battle, 1200)
  Assert.equal(battle:status().phase, "complete", "readiness releases the held publication")
  local receipt = assert(battle:status().outcomeReceipt, "completion carries its commit receipt")
  Assert.isTrue(receipt.committed, "the capture batch commits")
  Assert.equal(party:partyCount(), 3, "the caught mon lands in the live party exactly once")
  local stored = party:partyMon(2)
  Assert.equal(stored.species, "TOTODILE", "the appended mon keeps its species")
  Assert.equal(stored.personality, foe.personality, "the appended mon keeps its captured identity")
  Assert.isTrue(dex:isCaught("TOTODILE"), "the capture registers caught knowledge")
  Assert.isTrue(dex:isSeen("TOTODILE"), "a caught mon counts as seen")
  Assert.equal(bag:quantity("MASTER_BALL"), 1, "the thrown ball publishes exactly once")
  battle:update()
  battle:update()
  Assert.deepEqual(battle:status().outcomeReceipt, receipt, "repeated terminal polls never republish")
  Assert.equal(bag:quantity("MASTER_BALL"), 1, "repeated terminal polls never spend again")
  battle:dispose()
end

---@param species string wild species under test driving
---@param foeSeed integer fixed generator state for the wild foe
---@param battleSeed integer fixed battle stream seed under test driving
---@param party table live party owner under test driving
---@param bag table live bag owner under test driving
---@param dex table live dex knowledge under test driving
---@return table terminal packet carrying the capture outcome
local function captureWild(species, foeSeed, battleSeed, party, bag, dex)
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with consequence staging")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local foe = foeRecord(species, 4, foeSeed)
  local launchId = "launch-repeat-" .. tostring(foeSeed)
  local launch = {
    id = launchId,
    kind = "wild",
    payload = { species = species, level = 4, attemptId = launchId .. "-attempt", mon = foe },
  }
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.payload.attemptId, mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = newPortRecord()
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = recordingPort(portRecord),
    dex = dex,
    seed = battleSeed,
  })
  local thrown = false
  local terminal = nil
  for _ = 1, 1200 do
    battle:update()
    for _, packet in ipairs(portRecord.packets) do
      if type(packet) == "table" and type(packet.result) == "table" then
        terminal = packet
      end
    end
    local current = battle:status()
    if current.phase == "complete" or current.phase == "failed" then
      break
    end
    if terminal == nil and current.phase == "running" and current.request ~= nil and not thrown then
      local actor = assert(current.request.actors[1], "the capture battle addresses its lead")
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, {
        { actor = actor, kind = "item", payload = { item = "MASTER_BALL", target = { kind = "combatant", combatant = party:partyCount() + 1 } } },
      }))
      Assert.isTrue(accepted, "the guaranteed throw is accepted: " .. tostring(replyErr))
      thrown = true
    end
  end
  Assert.isTrue(thrown, "the capture leg throws its guaranteed ball")
  Assert.equal(battle:status().phase, "complete", "the capture settles")
  battle:dispose()
  return assert(terminal, "the settled capture ships its terminal result")
end

-- Repeat and failed captures never invent a card, while richer history
-- still accumulates: a failed throw leaves no caught observation, the
-- first success records its observed gender, and a second success with
-- a new gender appends without replaying the announcement or reordering
-- first history.
function T.repeat_and_failed_captures_extend_history_without_replaying_the_card()
  requirePresent(RUNTIME_MODULE, "application battle lifetime with consequence staging")
  requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local HgssBagService = require("libs.hgss.src.items.HgssBagService")

  local monCatalog = CatalogFixture.makeCatalog()
  local dex = newDexOwner({ "TOTODILE", "EEVEE" })

  -- A failed ordinary throw at full health breaks free and the knockout
  -- that follows wins without any caught observation or card.
  do
    local party = makeParty({ species = "EEVEE", level = 20, seed = 0x33333333 }, { species = "EEVEE", level = 5, seed = 0x44444444 })
    local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
    Assert.isTrue(bag:add("POKE_BALL", 2))
    local foe = wildFoe(0x5EED0002)
    local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with consequence staging")
    local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
    local launch = {
      id = "launch-failed-throw",
      kind = "wild",
      payload = { species = "TOTODILE", level = 4, attemptId = "launch-failed-throw-attempt", mon = foe },
    }
    local scenario = ScenarioFactory.fromEncounter(
      { attemptId = launch.payload.attemptId, mon = foe },
      { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
    )
    local portRecord = newPortRecord()
    local battle = BattleRuntime.new({
      request = launch,
      scenario = scenario,
      party = party,
      bag = bag,
      presentation = recordingPort(portRecord),
      dex = dex,
      seed = 0x12345678,
    })
    local thrown = false
    local brokeFree = false
    for _ = 1, 1200 do
      battle:update()
      for _, packet in ipairs(portRecord.packets) do
        for _, event in ipairs(packet.events or {}) do
          if type(event) == "table" and event.kind == "broke_free" then
            brokeFree = true
          end
          Assert.isTrue(event.kind ~= "caught", "the failed throw catches nothing")
        end
        if type(packet.result) == "table" then
          Assert.isNil(packet.result.registration, "no failed outcome presents a first-catch card")
        end
      end
      local current = battle:status()
      if current.phase == "complete" or current.phase == "failed" then
        break
      end
      if current.phase == "running" and current.request ~= nil then
        local actor = assert(current.request.actors[1], "the failed-throw battle addresses its lead")
        local choice
        if not thrown then
          choice = { actor = actor, kind = "item", payload = { item = "POKE_BALL", target = { kind = "combatant", combatant = party:partyCount() + 1 } } }
          thrown = true
        else
          choice = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
        end
        local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, { choice }))
        Assert.isTrue(accepted, "the failed-throw decisions are accepted: " .. tostring(replyErr))
      end
    end
    Assert.isTrue(thrown, "the failed leg throws its ordinary ball")
    Assert.isTrue(brokeFree, "the full-health ordinary throw breaks free")
    Assert.equal(battle:status().phase, "complete", "the knockout after the break settles")
    Assert.equal(battle:status().result, "win", "the failed throw still ends as a win")
    Assert.isFalse(dex:isCaught("TOTODILE"), "the failed throw records no caught observation")
    Assert.isTrue(dex:isSeen("TOTODILE"), "the appearing opener still records seen")
    battle:dispose()
  end

  -- The first success records its observed gender as rich history.
  local firstParty = makeParty({ species = "EEVEE", level = 20, seed = 0x77777777 }, { species = "EEVEE", level = 5, seed = 0x88888888 })
  captureWild("TOTODILE", 0xC0FFEE01, 0x12345678, firstParty, masterBallBag(1), dex)
  local firstFoePersonality = nil
  do
    local catalog = CatalogFixture.makeCatalog()
    local factory = CatalogFixture.makeFactory(0xC0FFEE01, catalog)
    local record = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 4 }))
    firstFoePersonality = record.personality
  end
  local firstGender = expectedGender(monCatalog, "TOTODILE", firstFoePersonality)
  Assert.deepEqual(
    dex:observedGenders("TOTODILE"),
    { firstGender },
    "the first capture records its actual observed gender"
  )
  Assert.isNil(dex:firstPersonality("TOTODILE"), "the first capture freezes first history")

  -- A second success with a new gender appends without a second card and
  -- without reordering first history.
  local secondSeed = nil
  local secondGender = nil
  for offset = 1, 60 do
    local factory = CatalogFixture.makeFactory(0xD0000000 + offset, monCatalog)
    local candidate = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 4 }))
    if expectedGender(monCatalog, "TOTODILE", candidate.personality) ~= firstGender then
      secondSeed = 0xD0000000 + offset
      secondGender = expectedGender(monCatalog, "TOTODILE", candidate.personality)
      break
    end
  end
  Assert.notNil(secondSeed, "the repeat leg needs a differing observed gender")
  local secondParty = makeParty({ species = "EEVEE", level = 20, seed = 0x99999999 }, { species = "EEVEE", level = 5, seed = 0xAAAAAAAA })
  local secondTerminal = captureWild("TOTODILE", assert(secondSeed), 0x12345678, secondParty, masterBallBag(1), dex)
  Assert.isNil(secondTerminal.result.registration, "a repeat capture of known species presents no second card")
  Assert.deepEqual(
    dex:observedGenders("TOTODILE"),
    { firstGender, assert(secondGender) },
    "the repeat capture appends its new gender after first history"
  )
  Assert.isNil(dex:firstPersonality("TOTODILE"), "repeats never reorder first history")
end

-- A dex revision that moves between eligibility and preparation fails
-- the publication instead of silently preparing over changed facts: no
-- receipt, no party append, no ball spent, and no caught history for the
-- capture. A first catch that cannot be retained fails the same way,
-- with no card on its terminal result.
function T.stale_dex_revision_between_eligibility_and_preparation_fails_without_publication()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with consequence staging")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  local SessionFixture = require("libs.battle.tests.session_fixture")

  local foe = wildFoe(0xC0FFEE01)
  local party = makeParty({ species = "EEVEE", level = 20, seed = 0x33333333 }, { species = "EEVEE", level = 5, seed = 0x44444444 })
  local bag = masterBallBag(1)
  local dex = newDexOwner({ "CHIKORITA", "TOTODILE" })
  local launch = {
    id = "launch-stale-dex",
    kind = "wild",
    payload = { species = "TOTODILE", level = 4, attemptId = "launch-stale-dex-attempt", mon = foe },
  }
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.payload.attemptId, mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = newPortRecord()
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = recordingPort(portRecord),
    dex = dex,
    seed = 0x12345678,
  })
  local terminal = nil
  do
    local thrown = false
    for _ = 1, 1200 do
      battle:update()
      for _, packet in ipairs(portRecord.packets) do
        if type(packet) == "table" and type(packet.result) == "table" then
          terminal = packet
          break
        end
      end
      if terminal ~= nil then
        break
      end
      local current = battle:status()
      if current.phase == "complete" or current.phase == "failed" then
        break
      end
      if current.phase == "running" and current.request ~= nil and not thrown then
        local actor = assert(current.request.actors[1], "the capture battle addresses its lead")
        local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, {
          { actor = actor, kind = "item", payload = { item = "MASTER_BALL", target = { kind = "combatant", combatant = party:partyCount() + 1 } } },
        }))
        Assert.isTrue(accepted, "the guaranteed throw is accepted: " .. tostring(replyErr))
        thrown = true
      end
    end
  end
  terminal = assert(terminal, "the capture ships its terminal result before preparation")

  -- The live dex moves after eligibility froze: an unrelated caught
  -- observation bumps the revision before the battle prepares.
  do
    local catalog = CatalogFixture.makeCatalog()
    local factory = CatalogFixture.makeFactory(0xC11C0001, catalog)
    local record = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA", level = 5 }))
    local specimen = dex:describe(record)
    dex:prepareChanges({ observations = { { kind = "caught", specimen = specimen } } }):publish()
  end
  Assert.isTrue(dex:isCaught("CHIKORITA"), "the unrelated observation lands in live history")
  for _ = 1, 10 do
    battle:update()
  end
  Assert.equal(battle:status().phase, "failed", "a revision moved since eligibility fails the resolution")
  Assert.isNil(battle:status().outcomeReceipt, "the stale preparation publishes no receipt")
  Assert.equal(party:partyCount(), 2, "the refused capture appends no mon")
  Assert.equal(bag:quantity("MASTER_BALL"), 1, "the refused capture spends no ball")
  Assert.isFalse(dex:isCaught("TOTODILE"), "the refused capture records no caught history")
  Assert.notNil(battle:status().error, "the failure names its stale eligibility")
  battle:dispose()

  -- A first catch that cannot be retained fails the same way, and its
  -- failed terminal carries no card: no partial owner publication and
  -- no lost mon.
  do
    local HgssBagService = require("libs.hgss.src.items.HgssBagService")
    local fullParty = makeParty({ species = "EEVEE", level = 5, seed = 0xAAAA0001 }, { species = "EEVEE", level = 5, seed = 0xAAAA0002 })
    do
      local catalog = CatalogFixture.makeCatalog()
      local factory = CatalogFixture.makeFactory(0xAAAA0010, catalog)
      for _, key in ipairs({ "TOTODILE", "EEVEE", "CHIKORITA", "TOTODILE" }) do
        local record = tackleOnly(factory:createNormal(CatalogFixture.normalRequest({ species = key })))
        Assert.isTrue(fullParty:addMon(record), "the refused case needs a full party")
      end
    end
    Assert.equal(fullParty:partyCount(), 6, "the party starts full")
    local fullBag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
    Assert.isTrue(fullBag:add("POKE_BALL", 5))
    local fullDex = newDexOwner({ "CHIKORITA", "TOTODILE", "EEVEE" })
    local caughtFoe = foeRecord("EEVEE", 4, 0xAAAA0002)
    local standingFoe = tackleOnly(foeRecord("EEVEE", 4, 0xAAAA0004))
    local fullLaunch = {
      id = "launch-full-party-wire",
      kind = "wild",
      payload = { species = "EEVEE", level = 4, mon = standingFoe },
    }
    local fullScenario = ScenarioFactory.fromEncounter(
      fullLaunch.payload,
      { party = fullParty, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
    )
    local fullRecord = newPortRecord()
    local fullBattle = BattleRuntime.new({
      request = fullLaunch,
      scenario = fullScenario,
      party = fullParty,
      bag = fullBag,
      bagDeltas = { { op = "take", item = "POKE_BALL", quantity = 1 } },
      dex = fullDex,
      captures = { { captureId = 22, ball = "POKE_BALL", success = true, mon = caughtFoe } },
      presentation = recordingPort(fullRecord),
      seed = 0x12345678,
    })
    driveToSettlement(fullBattle, fullScenario)
    Assert.equal(fullBattle:status().phase, "failed", "the capture without retention fails the resolution")
    Assert.isNil(fullBattle:status().outcomeReceipt, "a refused batch carries no commit receipt")
    Assert.notNil(fullBattle:status().error, "the failure names its missing retention")
    Assert.equal(fullParty:partyCount(), 6, "the live party is unchanged")
    Assert.isFalse(fullDex:isCaught("EEVEE"), "the refused batch registers no caught knowledge")
    Assert.equal(fullBag:quantity("POKE_BALL"), 5, "the refused batch consumes no ball")
    local refusedTerminals = 0
    for _, packet in ipairs(fullRecord.packets) do
      if type(packet) == "table" and type(packet.result) == "table" then
        refusedTerminals = refusedTerminals + 1
        Assert.isNil(packet.result.registration, "a refused capture presents no card")
      end
    end
    Assert.isTrue(refusedTerminals >= 1, "the refused battle ships its terminal result")
    fullBattle:dispose()
  end
end

return { tests = T }
