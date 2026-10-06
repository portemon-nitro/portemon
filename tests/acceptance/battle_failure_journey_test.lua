-- Battle failure boundaries: stale result candidates refuse before any
-- swap, a repeated completion reuses its receipt instead of republishing,
-- refused presentation readiness publishes nothing, invalid replies return
-- typed errors without consuming the battle, a scenario-free lifecycle
-- ends without a result, and a full party refuses the capture batch
-- before any publication instead of storing the mon anywhere. Failing
-- operations leave revisions, quantities, order, and files unchanged.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local COMMITTER_MODULE = "libs.hgss.src.battle.HgssBattleCommitter"
local BATTLE_RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local SCENARIO_FACTORY_MODULE = "libs.hgss.src.battle.HgssBattleScenarioFactory"

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:7", "map-data:61", "map-data:111", "map:7", "map:61", "map:111" },
    tags = { "field", "battle", "failure" },
  },
  tests = {},
}

---@param name string module path under test
---@param behavior string missing owner under test
---@return table the loaded owner
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing battle owner: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the battle module loads")
  return loaded --[[@as table]]
end

---@param catalog table live mon catalog behind the journey
---@return table full enemy record detached from every live owner
local function enemyRecord(catalog, species, level, seed)
  local factory = CatalogFixture.makeFactory(seed, catalog)
  return factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
end

---@param record table full mon-domain record under test preparation
---@return table the same record striking with a single known move
local function tackleOnly(record)
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

---@return table party owner holding one fixed mon
local function newPartyOwner()
  local catalog = CatalogFixture.makeCatalog()
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
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
  local factory = CatalogFixture.makeFactory(0x33333333, catalog)
  Assert.isTrue(owner:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  return owner
end

---@return table bag owner holding a fixed ball stock
local function newBagOwner()
  local HgssBagService = require("libs.hgss.src.items.HgssBagService")
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  Assert.isTrue(bag:add("POKE_BALL", 5))
  return bag
end

local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-00000201",
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

---@return table presentation port that never reports readiness
local function refusingPort(record)
  return {
    enter = function(_plan)
      record.enters = record.enters + 1
      return false
    end,
    present = function(frame)
      record.frames[#record.frames + 1] = frame
    end,
    leave = function(_plan)
      record.leaves = record.leaves + 1
      return false
    end,
    dispose = function()
      record.disposed = record.disposed + 1
    end,
  }
end

---@return table presentation port acknowledging immediately
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

function T.tests.stale_party_and_bag_candidates_refuse_without_consuming()
  local party = newPartyOwner()
  local bag = newBagOwner()
  local partyBefore = party:partyMon(0)
  local partyRevision = party:partyRevision()
  local bagRevision = bag:revision()
  local badUpdate = party:partyMon(0)
  badUpdate.heldItem = "SITRUS_BERRY"

  local staleParty, partyReason = party:preparePartyChanges(partyRevision + 1, { { slot = 0, mon = badUpdate } })
  Assert.isNil(staleParty)
  Assert.equal(partyReason, "stale")
  local staleBag, bagReason =
    bag:prepareInventoryChanges(bagRevision + 1, { { op = "take", item = "POKE_BALL", quantity = 1 } })
  Assert.isNil(staleBag)
  Assert.equal(bagReason, "stale")

  local Committer = requirePresent(COMMITTER_MODULE, "cross-owner result publication")
  local outcome = { id = "outcome-stale-refuses", result = "win" }
  local ok, err = pcall(Committer.prepare, { outcome = outcome, party = staleParty, bag = staleBag })
  Assert.isFalse(ok, "an invalid candidate batch never reaches publication: " .. tostring(err))
  Assert.deepEqual(party:partyMon(0), partyBefore, "a stale party staging touches nothing")
  Assert.equal(party:partyRevision(), partyRevision, "a stale party staging moves no revision")
  Assert.equal(bag:quantity("POKE_BALL"), 5, "a stale bag staging touches nothing")
  Assert.equal(bag:revision(), bagRevision, "a stale bag staging moves no revision")
  Assert.isNil(Committer.receipt("outcome-stale-refuses"), "a refused batch records no receipt")
end

function T.tests.duplicate_completion_reuses_the_receipt_without_republishing()
  local party = newPartyOwner()
  local bag = newBagOwner()
  local partyRevision = party:partyRevision()
  local bagRevision = bag:revision()
  local update = party:partyMon(0)
  update.heldItem = "SITRUS_BERRY"
  local partyPrep = assert(party:preparePartyChanges(partyRevision, { { slot = 0, mon = update } }))
  local bagPrep =
    assert(bag:prepareInventoryChanges(bagRevision, { { op = "take", item = "POKE_BALL", quantity = 1 } }))

  local Committer = requirePresent(COMMITTER_MODULE, "cross-owner result publication")
  local prepared = Committer.prepare({ outcome = { id = "outcome-duplicate-once", result = "win" }, party = partyPrep, bag = bagPrep })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the first commit publishes the staged owners")
  local repeatReceipt = Committer.commit(prepared)
  Assert.equal(repeatReceipt.outcomeId, receipt.outcomeId, "a repeated completion reuses the recorded receipt")
  Assert.equal(party:partyRevision(), partyRevision + 1, "a repeated completion never duplicates the party")
  Assert.equal(bag:revision(), bagRevision + 1, "a repeated completion never duplicates inventory")
  Assert.equal(bag:quantity("POKE_BALL"), 4, "a repeated completion never consumes a second ball")
  Assert.equal(party:partyMon(0).heldItem, "SITRUS_BERRY", "the staged party update lands exactly once")
end

function T.tests.refused_presentation_readiness_publishes_nothing()
  local BattleRuntime = requirePresent(BATTLE_RUNTIME_MODULE, "application battle lifetime from launch to return")
  local record = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = BattleRuntime.new({
    request = { id = "launch-refused-entry", kind = "wild", payload = { species = "TOTODILE", level = 4 } },
    scenario = nil,
    presentation = refusingPort(record),
  })
  for _ = 1, 30 do
    battle:update()
  end
  local held = battle:status()
  Assert.equal(held.phase, "preparing", "refused readiness holds the lifecycle before entry")
  Assert.isNil(held.outcomeReceipt, "a held lifecycle reports no receipt")
  Assert.isTrue(record.enters >= 1, "entry keeps polling readiness")
  Assert.equal(#record.frames, 0, "no semantic frame presents before entry")
  local saveable, busy = battle:canSave()
  Assert.isFalse(saveable, "a held battle never re-enables durable saves")
  Assert.equal(busy.phase, "preparing", "the busy reason names the owning phase")
  battle:dispose()
  Assert.equal(record.disposed, 1, "teardown still releases the port exactly once")
  Assert.isNil(battle:status().outcomeReceipt, "disposal publishes nothing on the way out")
end

function T.tests.lifecycle_without_a_scenario_ends_without_a_result()
  local BattleRuntime = requirePresent(BATTLE_RUNTIME_MODULE, "application battle lifetime from launch to return")
  local record = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = BattleRuntime.new({
    request = { id = "launch-lifecycle-only", kind = "wild", payload = { species = "TOTODILE", level = 4 } },
    scenario = nil,
    presentation = headlessPort(record),
  })
  local ticks = 0
  while battle:status().phase ~= "complete" and battle:status().phase ~= "failed" and ticks < 60 do
    battle:update()
    ticks = ticks + 1
  end
  local finished = battle:status()
  Assert.equal(finished.phase, "complete", "a scenario-free lifecycle still drains")
  Assert.isNil(finished.outcomeReceipt, "a scenario-free lifecycle never reports a receipt")
  Assert.isNil(finished.result, "a scenario-free lifecycle invents no outcome word")
  local saveable = battle:canSave()
  Assert.isFalse(saveable, "an uncommitted lifecycle never re-enables durable saves")
  battle:dispose()
  Assert.equal(record.disposed, 1, "teardown releases the port exactly once")
end

function T.tests.invalid_replies_return_typed_errors_and_the_battle_still_completes()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({
    versionId = versionId,
    map = MAP,
    save = "fresh",
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local BattleRuntime = requirePresent(BATTLE_RUNTIME_MODULE, "application battle lifetime from launch to return")
    local ScenarioFactory =
      requirePresent(SCENARIO_FACTORY_MODULE, "field, trainer, and wild sources mapped to one scenario")
    Assert.isTrue(
      game.runtime.monService:giveMon({ species = "CHIKORITA", level = 5, heldItem = "NONE", form = 0 }),
      "the journey needs a live party lead"
    )
    local partyRevisionBefore = game.runtime.monService:partyRevision()
    local record = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
    local liveCatalog = game.runtime.monService:catalog()
    local typedFoe = tackleOnly(enemyRecord(liveCatalog, "TOTODILE", 4, 0x7E401001))
    local launch = {
      id = "launch-typed-replies",
      kind = "wild",
      payload = { species = "TOTODILE", level = 4, mon = typedFoe },
    }
    local battle = BattleRuntime.new({
      request = launch,
      scenario = ScenarioFactory.fromEncounter(launch.payload, {
        party = game.runtime.monService,
        bag = game.runtime.bagService,
        world = game.runtime.scripts.worldState,
        player = { trainerId = 99, trainerName = "MINT", language = "french" },
      }),
      presentation = headlessPort(record),
      party = game.runtime.monService,
      bag = game.runtime.bagService,
    })

    local SessionFixture = require("libs.battle.tests.session_fixture")
    local openSeen = false
    local ticks = 0
    while battle:status().phase ~= "complete" and battle:status().phase ~= "failed" and ticks < 1200 do
      game:step()
      battle:update()
      local current = battle:status()
      if current.phase == "running" and current.request ~= nil then
        if not openSeen then
          openSeen = true
          local accepted, replyErr = battle:submit({ requestId = -1 })
          Assert.isFalse(accepted, "a reply outside the open request is rejected")
          Assert.notNil(replyErr, "the rejection carries its typed error")
          local garbageAccepted, garbageErr = battle:submit("not-a-reply")
          Assert.isFalse(garbageAccepted, "a non-record reply is rejected")
          Assert.notNil(garbageErr, "the non-record rejection carries its typed error")
        end
        local request = current.request
        local choices = {}
        for _, actor in ipairs(assert(request.actors, "a decision request names its actors")) do
          choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
        end
        local accepted, replyErr = battle:submit(SessionFixture.replyFor(request, choices))
        Assert.isTrue(accepted, "the legal reply after rejections is accepted: " .. tostring(replyErr))
      end
      ticks = ticks + 1
    end
    Assert.isTrue(openSeen, "the battle exposed a real request to refuse against")
    local finished = battle:status()
    Assert.equal(finished.phase, "complete", "rejected replies never stall the battle")
    Assert.notNil(finished.outcomeReceipt, "the battle still commits after rejections")
    Assert.isTrue(finished.outcomeReceipt.committed, "the receipt proves publication")
    Assert.equal(finished.outcomeReceipt.outcomeId, launch.id, "the receipt binds the exact launch")
    Assert.isTrue(
      game.runtime.monService:partyRevision() >= partyRevisionBefore,
      "rejected replies publish no phantom party state"
    )
    battle:dispose()
    game:waitForFieldReady()
    Assert.equal(game:snapshot().mapSymbol, MAP, "the battle returns to the map it launched from")
    Assert.equal(game:renderAttempts(), 0, "the journey must stop before GPU rendering")
  end, debug.traceback)
  local namespace = game.saveNamespace
  game:close()
  if not ok then
    error(err, 0)
  end
  Assert.isNil(love.filesystem.getInfo(namespace), "teardown removes the isolated save namespace")
end

function T.tests.full_party_capture_fails_before_any_publication()
  local Committer = requirePresent(COMMITTER_MODULE, "cross-owner result publication without hidden storage")
  local party = newPartyOwner()
  local species = { "CHIKORITA", "TOTODILE", "EEVEE", "CHIKORITA", "TOTODILE", "EEVEE" }
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0x77777777, catalog)
  for _, name in ipairs(species) do
    if party:partyCount() < 6 then
      Assert.isTrue(party:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = name }))))
    end
  end
  Assert.equal(party:partyCount(), 6, "the refusal needs a genuinely full party")
  local revisionBefore = party:partyRevision()
  local caught = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 4 }))

  local ok, err = pcall(Committer.prepare, {
    outcome = { id = "outcome-full-party-refused", result = "capture" },
    partyOwner = party,
    captures = { { captureId = 41, ball = "POKE_BALL", success = true, mon = caught } },
  })
  Assert.isFalse(ok, "a capture without retention never stages: " .. tostring(err))
  Assert.equal(party:partyCount(), 6, "the refusal stores the mon nowhere")
  Assert.equal(party:partyRevision(), revisionBefore, "the refusal moves no live revision")
  Assert.isNil(Committer.receipt("outcome-full-party-refused"), "a refused batch records no receipt")
end

return T
