-- Production-path battle consequence journeys: a lost wild battle debits
-- blackout money, a caught wild mon lands in the live party and dex while
-- the thrown ball leaves the live bag, a trainer win credits prize money
-- derived from the native trainer class data, and a roamer battle advances
-- the roamer revision. Every leg runs through the live field owners, the
-- application battle lifetime, and the battle committer; the headless
-- presentation port acknowledges immediately and never authors decisions.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local BATTLE_RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local SCENARIO_FACTORY_MODULE = "libs.hgss.src.battle.HgssBattleScenarioFactory"

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

---@param game table live acceptance game behind the battle
---@param battle table running application battle lifetime
local function driveToCompletion(game, battle)
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
end

---@param catalog table live mon catalog behind the journey
---@return table full enemy record detached from every live owner
local function enemyRecord(catalog, species, level, seed, hp)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  if hp ~= nil then
    record.condition.currentHp = hp
  end
  return record
end

---@param record table full mon-domain record under test preparation
---@return table the same record striking with a single known move
local function tackleOnly(record)
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

---@return table player money facts over the live player record
local function playerFacts(game)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  return {
    record = game.runtime.playerData,
    context = { charmap = CatalogFixture.CHARMAP, frameIndexes = { [0] = true } },
  }
end

---@param versionId string booted game version behind the journey
---@return table trainer template from the native compiled catalog with its class, final member, and prize facts
local function nativeTrainer(versionId)
  local RomFs = require("romdump.src.source.RomFs")
  local romFs = assert(RomFs.open(versionId), "the prize leg needs its ready dump")
  local Compiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local compiled = assert(Compiler.compileFromDump(romFs, { versionId = versionId }))
  romFs:close()
  local Catalog = require("libs.hgss.src.battle.HgssTrainerCatalog")
  local catalog = Catalog.new(compiled)
  local keys = {}
  for key in pairs(compiled.trainers) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    local template = Catalog.trainer(catalog, key)
    assert(template ~= nil, "the compiled trainer loads")
    local record = template --[[@as table<string, unknown>]]
    local reference = record.nameReference --[[@as table<string, unknown>]]
    local party = record.party --[[@as table<integer, unknown>]]
    local prize = record.prizeMoney --[[@as table<string, unknown>]]
    if
      type(reference) == "table"
      and reference.rival ~= true
      and #party > 0
      and type(record.trainerClass) == "number"
      and type(prize) == "table"
      and type(prize.classRate) == "number"
    then
      -- The prize level is the final ordered party member, even when a
      -- stronger member stands earlier in the native party.
      local final = party[#party] --[[@as table<string, unknown>]]
      if type(final.species) == "string" and type(final.level) == "number" then
        return {
          key = key,
          trainerClass = record.trainerClass,
          classRate = prize.classRate,
          species = final.species,
          level = final.level,
          partyLevels = { final.level },
        }
      end
    end
  end
  error("the native catalog carries no trainer party to field", 0)
end

---@param versionId string booted game version behind the journey
---@param mapSymbol string map the game stands on
---@return integer numeric map identity from the prepared world catalog
local function mapIdentity(versionId, mapSymbol)
  local CacheFs = require("libs.storage.src.CacheFs")
  local MapAssetCache = require("libs.assets.src.MapAssetCache")
  local cacheFs = CacheFs.forVersion(versionId)
  local world = assert(cacheFs:loadLua(MapAssetCache.worldPath()), "the roamer leg needs its world catalog")
  assert(type(world) == "table", "the world catalog loads")
  local bySymbol = (world --[[@as table<string, unknown>]]).bySymbol --[[@as table<string, integer>]]
  assert(type(bySymbol) == "table", "the world catalog indexes its map symbols")
  local id = bySymbol[mapSymbol]
  assert(type(id) == "number", "the standing map resolves to its numeric identity")
  return id --[[@as integer]]
end

function T.tests.post_battle_consequences_commit_through_the_live_owners()
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
    local liveCatalog = game.runtime.monService:catalog()
    local dex = assert(game.runtime.dexKnowledge, "the journey needs its live dex knowledge")

    -- The loss comes first with a solo lead: repeated wild battles wear
    -- the lead down through committed writebacks until the standings
    -- report the loss, and the blackout debit stages against the live
    -- money facts. The debit depends only on the lead level, so the wear
    -- count adapts without pinning hit points.
    Assert.isTrue(
      game.runtime.monService:giveMon({ species = "CHIKORITA", level = 5, heldItem = "NONE", form = 0 }),
      "the journey needs its faint-bound lead"
    )
    local moneyBefore = game.runtime.playerData.profile.money
    local lossReceipt = nil ---@type table<string, unknown>?
    local wear = 0
    while lossReceipt == nil do
      wear = wear + 1
      Assert.isTrue(wear <= 12, "the solo lead faints within its hit-point budget")
      local lossRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
      local lossFoe = tackleOnly(enemyRecord(liveCatalog, "TOTODILE", 4, 0xB1AC0001 + wear))
      local lossLaunch = {
        id = "launch-consequence-loss-" .. wear,
        kind = "wild",
        payload = { species = "TOTODILE", level = 4, mon = lossFoe },
      }
      local lossScenario = ScenarioFactory.fromEncounter(lossLaunch.payload, { party = game.runtime.monService })
      local loss = BattleRuntime.new({
        request = lossLaunch,
        scenario = lossScenario,
        presentation = headlessPort(lossRecord),
        party = game.runtime.monService,
        dex = dex,
        player = playerFacts(game),
      })
      driveToCompletion(game, loss)
      Assert.equal(loss:status().phase, "complete", "answered decisions finish the wearing battle")
      local receipt = assert(loss:status().outcomeReceipt, "the wearing battle carries its receipt")
      Assert.isTrue(receipt.committed, "every wearing battle commits")
      local word = loss:status().result
      if word == "loss" then
        lossReceipt = receipt
      else
        Assert.equal(word, "draw", "standing battles settle without a victor")
      end
      loss:dispose()
    end
    Assert.isTrue(lossReceipt ~= nil, "the standings eventually report the loss")
    local settled = lossReceipt --[[@as table<string, unknown>]]
    local rewards = settled.rewards --[[@as table<string, unknown>]]
    local settledPlayer = settled.player --[[@as table<string, unknown>]]
    local settledProfile = settledPlayer.profile --[[@as table<string, unknown>]]
    Assert.equal(rewards.kind, "loss", "the loss plans through the money planning owner")
    Assert.equal(rewards.amount, 40, "the debit scales the lead level without badges")
    Assert.equal(settledProfile.money, moneyBefore - 40, "the receipt carries the debited money candidate")
    Assert.isTrue(dex:isSeen("TOTODILE"), "the lost battle still registers the sighting")

    -- A healthy lead and stocked balls set up the capture: the caught wild
    -- mon must land in the live party and dex while the ball leaves the bag.
    Assert.isTrue(
      game.runtime.monService:giveMon({ species = "CHIKORITA", level = 5, heldItem = "NONE", form = 0 }),
      "the journey needs its healthy lead"
    )
    Assert.isTrue(game.runtime.bagService:add("POKE_BALL", 5), "the capture needs its live ball stock")
    local ballsBefore = game.runtime.bagService:quantity("POKE_BALL")
    local partyBefore = game.runtime.monService:partyCount()
    local catchRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
    local wildFoe = tackleOnly(enemyRecord(liveCatalog, "TOTODILE", 4, 0xCA7C4001))
    local catchLaunch =
      { id = "launch-consequence-catch", kind = "wild", payload = { species = "TOTODILE", level = 4, mon = wildFoe } }
    local catchScenario =
      ScenarioFactory.fromEncounter(catchLaunch.payload, { party = game.runtime.monService })
    local wildMon = catchScenario.participants[2].roster[1].mon
    local capture = BattleRuntime.new({
      request = catchLaunch,
      scenario = catchScenario,
      presentation = headlessPort(catchRecord),
      party = game.runtime.monService,
      bag = game.runtime.bagService,
      bagDeltas = { { op = "take", item = "POKE_BALL", quantity = 1 } },
      dex = dex,
      captures = { { captureId = 41, ball = "POKE_BALL", success = true, mon = wildMon } },
    })
    driveToCompletion(game, capture)
    Assert.equal(capture:status().phase, "complete", "answered decisions finish the capture battle")
    local catchReceipt = assert(capture:status().outcomeReceipt, "the capture carries its commit receipt")
    Assert.isTrue(catchReceipt.committed, "the capture batch commits")
    Assert.equal(#catchReceipt.placements, 1, "the capture reports its placement")
    Assert.isTrue(catchReceipt.placements[1].retained, "room in the party retains the capture")
    Assert.equal(game.runtime.monService:partyCount(), partyBefore + 1, "the caught mon lands in the live party")
    local stored = game.runtime.monService:partyMon(partyBefore)
    Assert.equal(stored.species, "TOTODILE", "the appended mon keeps its species")
    Assert.equal(stored.personality, wildMon.personality, "the appended mon keeps its wild identity")
    Assert.isTrue(dex:isCaught("TOTODILE"), "the capture registers caught knowledge")
    Assert.equal(
      game.runtime.bagService:quantity("POKE_BALL"),
      ballsBefore - 1,
      "the planned ball consumption lands in the live bag"
    )
    capture:dispose()

    -- The trainer win credits the exact native prize: the staged entry
    -- carries the compiled trainer's class, final-member level, and
    -- pinned class rate, so the win settles level * 4 * class rate for a
    -- single battle with no money-up holder, published once through the
    -- player owner with no injected prize inputs.
    local trainer = nativeTrainer(versionId)
    local champion = enemyRecord(liveCatalog, trainer.species, trainer.level, 0x7EA00001, 1)
    local prizeRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
    local prizeLaunch =
      { id = "launch-consequence-prize", kind = "trainer", payload = { trainer = tostring(trainer.key) } }
    local prizeScenario = ScenarioFactory.fromTrainer({
      id = prizeLaunch.id,
      trainers = {
        {
          id = tostring(trainer.key),
          class = trainer.trainerClass,
          party = { champion },
          partyLevels = trainer.partyLevels,
          prizeMoney = { trainerClass = trainer.trainerClass, classRate = trainer.classRate },
          program = { key = "consequence_opening", revision = "native-1", instructions = {}, entryPoints = {} },
        },
      },
    }, { party = game.runtime.monService })
    -- Derived independently from the pinned class rate and the final
    -- member level, never through the production reward planner.
    local expectedPrize = trainer.level * 4 * trainer.classRate
    local prize = BattleRuntime.new({
      request = prizeLaunch,
      scenario = prizeScenario,
      presentation = headlessPort(prizeRecord),
      party = game.runtime.monService,
      dex = dex,
      player = playerFacts(game),
    })
    driveToCompletion(game, prize)
    Assert.equal(prize:status().phase, "complete", "answered decisions finish the trainer battle")
    Assert.equal(prize:status().result, "win", "a fainted trainer side reports the win")
    local prizeReceipt = assert(prize:status().outcomeReceipt, "the trainer win carries its commit receipt")
    Assert.isTrue(prizeReceipt.committed, "the prize batch commits")
    Assert.equal(
      prizeReceipt.rewards.amount,
      expectedPrize,
      "the prize follows the native class rate and the final member level"
    )
    Assert.equal(
      prizeReceipt.player.profile.money,
      moneyBefore + expectedPrize,
      "the receipt carries the credited money candidate"
    )
    prize:dispose()

    -- The roamer battle advances the roaming revision through the live
    -- commit path. The record itself is journey setup: production owns no
    -- story-release flow yet, but its reference sets come from live data.
    local HgssRoamerState = require("libs.hgss.src.encounters.HgssRoamerState")
    local roamerMon = enemyRecord(liveCatalog, "EEVEE", 20, 0x90A4CE01)
    local location = mapIdentity(versionId, MAP)
    local roamer = HgssRoamerState.new({
      records = {
        { key = "roamer-eevee", stateVersion = 1, mon = roamerMon, location = location, lifecycle = "roaming", revision = 0 },
      },
      species = { EEVEE = true },
      maps = { [location] = true },
    })
    local roamerRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
    local roamerFoe = tackleOnly(enemyRecord(liveCatalog, "EEVEE", 20, 0x90A4CE02, 1))
    local roamerLaunch =
      { id = "launch-consequence-roamer", kind = "wild", payload = { species = "EEVEE", level = 20, mon = roamerFoe } }
    local roamerScenario =
      ScenarioFactory.fromEncounter(roamerLaunch.payload, { party = game.runtime.monService })
    local roamerBattle = BattleRuntime.new({
      request = roamerLaunch,
      scenario = roamerScenario,
      presentation = headlessPort(roamerRecord),
      party = game.runtime.monService,
      dex = dex,
      roamer = { owner = roamer, key = "roamer-eevee", expectedRevision = 0, details = {} },
    })
    driveToCompletion(game, roamerBattle)
    Assert.equal(roamerBattle:status().phase, "complete", "answered decisions finish the roamer battle")
    local roamerReceipt = assert(roamerBattle:status().outcomeReceipt, "the roamer battle carries its receipt")
    Assert.isTrue(roamerReceipt.committed, "the roamer batch commits")
    Assert.equal(roamerReceipt.roamer.lifecycle, "defeated", "the receipt carries the settled roamer")
    Assert.equal(roamerReceipt.roamer.revision, 1, "the roamer revision advances exactly once")
    local stillOffered = pcall(roamer.prepareEncounter, roamer, "roamer-eevee")
    Assert.isFalse(stillOffered, "a defeated roamer no longer offers encounters")
    Assert.isTrue(dex:isSeen("EEVEE"), "the roamer battle registers the sighting")
    roamerBattle:dispose()

    -- The same live field resumes after every committed consequence.
    Assert.isNil(game.runtime.errorText, "the consequence legs run without a runtime fault")
    game:waitForFieldReady()
    Assert.equal(game:snapshot().mapSymbol, MAP, "the battles return to the map they launched from")
    Assert.isTrue(game.runtime.monService:partyCount() >= 2, "the live party survives the consequence legs")
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
