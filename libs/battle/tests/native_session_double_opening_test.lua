-- A source-marked double trainer reaches a live two-slot opening: the
-- composed trainer setup carries two slots per side and the production
-- battle exposes both player slots together in its first decision.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

local DOUBLE_SEED = 0x00D0B1E

---@param name string module path under test
---@param behavior string observable behavior the module owns
---@return table the loaded module
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing battle behavior: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the battle module loads")
  return loaded --[[@as table]]
end

---@param record table live mon-domain record under move assignment
---@return table the same record striking with a single known move
local function tackleOnly(record)
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

---@param species string
---@param level integer
---@param seed integer fixed generator state for the foe record
---@return table full mon-domain record
local function foeRecord(species, level, seed)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  return tackleOnly(factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level })))
end

---@return table party owner holding two fixed conscious leads
local function twoLeadParty()
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local Lcrng = require("libs.mons.src.gen4.Lcrng")
  local MonsSave = require("libs.mons.src.MonsSave")
  local Party = require("libs.mons.src.Party")
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
  Assert.isTrue(owner:addMon(foeRecord("CHIKORITA", 5, 0x33333333)), "the first conscious lead enters the live party")
  Assert.isTrue(owner:addMon(foeRecord("TOTODILE", 5, 0x44444444)), "the second conscious lead enters the live party")
  return owner
end

---@param money integer pocket money the player record carries
---@return table player record and its validation context
local function playerFacts(money)
  local record = {
    profile = { name = "RED", gender = 0, trainerId = 1, money = money, badges = 0 },
    options = { textFrame = 0, textSpeed = "fastest" },
  }
  local context = { charmap = CatalogFixture.CHARMAP, frameIndexes = { [0] = true } }
  return { record = record, context = context }
end

-- The marked double trainer opens through the production lifetime: the
-- first player decision addresses both player slots with distinct
-- combatants instead of a single opener.
function T.marked_double_trainer_reaches_a_two_slot_opening_decision()
  local BattleRuntime =
    requirePresent("game.hgss.src.battle.BattleRuntime", "the application battle lifetime runs composed scenarios")
  local ScenarioFactory =
    requirePresent("libs.hgss.src.battle.HgssBattleScenarioFactory", "field sources mapped to one detached scenario")
  local party = twoLeadParty()
  local facts = playerFacts(3000)
  local scenario = ScenarioFactory.fromTrainer({
    id = "double-opening",
    trainers = {
      {
        id = "rival-double",
        class = 2,
        party = { foeRecord("TOTODILE", 4, 0x5EED0001), foeRecord("CHIKORITA", 4, 0x5EED0002) },
        partyLevels = { 4, 4 },
        prizeMoney = { trainerClass = 2, classRate = 4 },
        aiPasses = {},
        doubleBattle = true,
      },
    },
  }, { party = party, player = { trainerId = 99, trainerName = "MINT", language = "french" } })
  local battle = BattleRuntime.new({
    request = { id = "launch-double-opening", kind = "trainer", payload = { trainer = "rival-double" } },
    scenario = scenario,
    party = party,
    player = facts,
  })
  local opening = nil ---@type table<string, unknown>?
  for _ = 1, 400 do
    battle:update()
    local current = battle:status()
    if current.phase == "failed" then
      local detail = current.error
      battle:dispose()
      error("the doubled battle failed before its opening decision: " .. tostring(detail))
    end
    if current.phase == "running" and current.request ~= nil then
      opening = current.request
      break
    end
    if current.phase == "complete" then
      break
    end
  end
  local request = opening
  battle:dispose()
  Assert.notNil(request, "the doubled session opens its player decision")
  assert(request ~= nil, "the opening decision is observed before assertions")
  local actors = request.actors --[[@as table<integer, table<string, unknown>>]]
  Assert.equal(#actors, 2, "both player slots decide the opening together")
  local first = assert(actors[1], "the opening names its first slot")
  local second = assert(actors[2], "the opening names its second slot")
  Assert.isTrue(first.combatant ~= second.combatant, "each opening slot fields its own combatant")
end

---@return table frozen battle content carrying the native ruleset with singles and doubles formats
local function doubleContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "the private native lifecycle owns HGSS ruleset sessions"
  )
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "native-session-double-opening")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "native-session-double-opening"
  )
  behaviors:registerFormat("single", { key = "single" }, "native-session-double-opening")
  behaviors:registerFormat("double", { key = "double" }, "native-session-double-opening")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, table<string, unknown>> immutable move facts for the fixture strikes
local function doubleMoveFacts(seeds)
  local catalog = CatalogFixture.makeCatalog()
  local facts = {
    TACKLE = catalog:move("TACKLE"),
    STRUGGLE = { power = 50, accuracy = 100, category = "physical", moveType = "normal", priority = 0 },
  }
  for _, seed in ipairs(seeds) do
    local learned = seed.mon --[[@as table<string, unknown>]]
    for _, entry in
      ipairs(learned.moves --[[@as table<integer, table<string, unknown>>]])
    do
      if type(entry) == "table" and type(entry.move) == "string" and facts[entry.move] == nil then
        facts[entry.move] = catalog:move(entry.move)
      end
    end
    local form = catalog:form(learned.species --[[@as string]], learned.form --[[@as integer]])
    for _, chance in ipairs(form.levelUpMoves) do
      if facts[chance.move] == nil then
        facts[chance.move] = catalog:move(chance.move)
      end
    end
  end
  return facts
end

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, table<integer, table<string, unknown>>> static species facts for the fixture combatants
local function doubleSpeciesFacts(seeds)
  local catalog = CatalogFixture.makeCatalog()
  local facts = {}
  for _, seed in ipairs(seeds) do
    local mon = seed.mon --[[@as table<string, unknown>]]
    local species = mon.species --[[@as string]]
    local form = mon.form --[[@as integer]]
    local bucket = facts[species]
    if bucket == nil then
      bucket = {}
      facts[species] = bucket
    end
    local formRecord = catalog:form(species, form)
    local speciesRecord = catalog:species(species)
    bucket[form] = {
      baseStats = formRecord.baseStats,
      growthCurve = catalog:growthCurve(speciesRecord.growthCurve --[[@as string]]),
      types = formRecord.types,
      levelUpMoves = formRecord.levelUpMoves,
      baseExpYield = speciesRecord.baseExpYield,
      evYield = speciesRecord.evYield,
    }
  end
  return facts
end

-- A fainted opener is replaced from its own trainer's bench: the lone
-- double trainer answers its vacated slot with its remaining reserve
-- while the standing slot keeps its occupant.
function T.fainted_double_opener_is_replaced_from_its_own_bench()
  local ScenarioFactory =
    requirePresent("libs.hgss.src.battle.HgssBattleScenarioFactory", "field sources mapped to one detached scenario")
  local contracts = SessionFixture.sessionContracts()
  local Executor = requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "the private native lifecycle owns HGSS ruleset sessions"
  )
  local wounded = foeRecord("TOTODILE", 4, 0x5EED0001)
  wounded.condition.currentHp = 1
  local fragment = ScenarioFactory.fromTrainer({
    id = "double-replacement",
    seed = DOUBLE_SEED,
    trainers = {
      {
        id = "rival-double",
        class = 2,
        party = { wounded, foeRecord("CHIKORITA", 4, 0x5EED0002), foeRecord("TOTODILE", 4, 0x5EED0003) },
        partyLevels = { 4, 4, 4 },
        prizeMoney = { trainerClass = 2, classRate = 4 },
        aiPasses = {},
        doubleBattle = true,
      },
    },
  }, { party = twoLeadParty(), player = { trainerId = 99, trainerName = "MINT", language = "french" } })
  local foe = assert(fragment.participants[2], "the lone trainer fields the enemy side")
  local faintedId = foe.roster[1].id
  local standingId = foe.roster[2].id
  local reserveId = foe.roster[3].id
  local seeds = {}
  for _, participant in ipairs(fragment.participants) do
    for _, seed in
      ipairs((participant --[[@as table<string, unknown>]]).roster --[[@as table]])
    do
      seeds[#seeds + 1] = seed
    end
  end
  fragment.ruleset = Executor.RULESET
  fragment.moveFacts = doubleMoveFacts(seeds --[[@as table<integer, table<string, unknown>>]])
  fragment.speciesFacts = doubleSpeciesFacts(seeds --[[@as table<integer, table<string, unknown>>]])
  local session = contracts.Battle.newSession(fragment, doubleContent())
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the doubled battle opens its decision batch")
  for _, request in ipairs(opening.request.requests) do
    local reply = nil ---@type table<string, unknown>?
    if request.controller == "player" then
      local choices = {}
      for index, actor in ipairs(request.actors) do
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2 + index))
      end
      reply = SessionFixture.replyFor(request, choices)
    else
      reply = session:answerTrainer(request)
    end
    local accepted, replyErr = session:submit(reply)
    Assert.isTrue(accepted, "opening replies are accepted: " .. tostring(replyErr))
  end
  session:advance(64)
  Assert.equal(session:capture().combatants[faintedId].hp, 0, "the opening strike knocks out the wounded opener")
  for _ = 1, 6 do
    if session:capture().positions[3].occupant == reserveId then
      break
    end
    local boundary = SessionFixture.driveUntilSettled(session)
    Assert.isTrue(boundary.status ~= "ended", "the battle does not end on a replaceable faint")
    for _, request in ipairs(boundary.request.requests) do
      local reply = nil ---@type table<string, unknown>?
      if request.controller == "player" then
        local choices = {}
        for _, actor in ipairs(request.actors) do
          choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(3))
        end
        reply = SessionFixture.replyFor(request, choices)
      else
        reply = session:answerTrainer(request)
      end
      local accepted, replyErr = session:submit(reply)
      Assert.isTrue(accepted, "standing-side replies are accepted: " .. tostring(replyErr))
    end
    session:advance(64)
  end
  local replaced = session:capture()
  Assert.equal(replaced.positions[3].occupant, reserveId, "the same trainer's reserve takes the vacated slot")
  Assert.equal(replaced.positions[4].occupant, standingId, "the standing slot keeps its occupant")
  Assert.isNil(replaced.combatants[faintedId].active, "the fainted opener stays out of the field")
  Assert.notNil(replaced.combatants[reserveId].active, "the reserve enters the field")
  Assert.equal(replaced.combatants[reserveId].participant, 2, "the reserve answers for the same trainer")
  session:dispose()
end

return { tests = T }
