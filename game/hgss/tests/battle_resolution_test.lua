-- Application battle consequence staging: prize and blackout money,
-- captures, dex knowledge, roamer deltas, and planned bag consumption all
-- stage through the live owners and the battle committer on the production
-- runtime path. Unknown capture species and unstaged dex references fail
-- the resolution instead of publishing a partial result.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
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

---@param species string
---@param level integer
---@param seed integer
---@param hp integer? entry health override
---@return table full mon-domain record
local function foeRecord(species, level, seed, hp)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  if hp ~= nil then
    record.condition.currentHp = hp
  end
  return record
end

---@param leadHp integer? entry health override for the party lead
---@return table party owner holding one fixed mon
local function newPartyOwner(leadHp)
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
  local record = foeRecord("CHIKORITA", 5, 0x33333333, leadHp)
  Assert.isTrue(owner:addMon(record), "the resolution needs its live party lead")
  return owner
end


---@return table bag owner holding a fixed ball stock
local function newBagOwner()
  local HgssBagService = require("libs.hgss.src.items.HgssBagService")
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  Assert.isTrue(bag:add("POKE_BALL", 5))
  return bag
end

---@return table dex knowledge over the resolution species set
local function newDexOwner()
  local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
  return PokedexKnowledge.new({ species = { CHIKORITA = true, TOTODILE = true, EEVEE = true } })
end

---@return table roamer state with one roaming record
local function newRoamerOwner()
  local Fixture = require("libs.hgss.tests.encounter_fixture")
  local HgssRoamerState = require("libs.hgss.src.encounters.HgssRoamerState")
  local refs = Fixture.refs()
  return HgssRoamerState.new({
    records = { Fixture.roamerRecord(Fixture.roamerMon(), 11, "roaming", 0) },
    species = refs.species,
    maps = refs.maps,
  })
end

---@param money integer pocket money the player record carries
---@return table player record and its validation context
local function playerFacts(money)
  local record = {
    profile = { name = "RED", gender = 0, trainerId = 1, money = money, badges = 0, nationalDex = false },
    options = { textFrame = 0, textSpeed = "fastest" },
  }
  local context = { charmap = CatalogFixture.CHARMAP, frameIndexes = { [0] = true } }
  return { record = record, context = context }
end

---@param battle table running application battle lifetime
local function driveToSettlement(battle)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local ticks = 0
  while battle:status().phase ~= "complete" and battle:status().phase ~= "failed" and ticks < 1200 do
    battle:update()
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      local choices = {}
      for _, actor in ipairs(assert(current.request.actors, "a decision request names its actors")) do
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
      end
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "a legal decision is accepted: " .. tostring(replyErr))
    end
    ticks = ticks + 1
  end
end

---@param trainers table trainer entries fielding the enemy side
---@param ctx table scenario context carrying the live owners
---@return table trainer scenario fragment
local function trainerScenario(trainers, ctx)
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  return ScenarioFactory.fromTrainer({ id = "trainer-prize", trainers = trainers }, ctx)
end

function T.trainer_win_stages_prize_credit_through_the_committer()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with consequence staging")
  requirePresent(COMMITTER_MODULE, "end-to-end exactly-once result publication")

  local party = newPartyOwner()
  local facts = playerFacts(3000)
  local foe = foeRecord("TOTODILE", 4, 0x5EED0001, 1)
  local scenario = trainerScenario({
    {
      id = "rival-early",
      party = { foe },
      program = { key = "rival_opening", revision = "native-1", instructions = {}, entryPoints = {} },
    },
  }, { party = party })
  local battle = BattleRuntime.new({
    request = { id = "launch-prize-credit", kind = "trainer", payload = { trainer = "rival-early" } },
    scenario = scenario,
    party = party,
    player = facts,
    prize = { trainerClass = "YOUNGSTER", basePayout = 140 },
  })
  driveToSettlement(battle)
  Assert.equal(battle:status().phase, "complete", "answered decisions finish the trainer battle")
  Assert.equal(battle:status().result, "win", "a fainted enemy side reports the win")
  local receipt = assert(battle:status().outcomeReceipt, "completion carries its commit receipt")
  Assert.isTrue(receipt.committed, "the prize batch commits")
  Assert.equal(receipt.rewards.amount, 560, "the prize multiplies the base payout by the foe level")
  Assert.equal(receipt.player.profile.money, 3560, "the receipt carries the credited money candidate")
  Assert.equal(facts.record.profile.money, 3000, "staging never touches the input record")
  battle:dispose()
end

function T.loss_stages_blackout_debit_through_the_committer()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with consequence staging")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")

  local party = newPartyOwner(1)
  local facts = playerFacts(3000)
  local launch = { id = "launch-blackout-debit", kind = "wild", payload = { species = "TOTODILE", level = 4 } }
  local scenario = ScenarioFactory.fromEncounter(launch.payload, { party = party })
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    player = facts,
  })
  driveToSettlement(battle)
  Assert.equal(battle:status().phase, "complete", "answered decisions finish the lost battle")
  Assert.equal(battle:status().result, "loss", "a fainted player side reports the loss")
  local receipt = assert(battle:status().outcomeReceipt, "completion carries its commit receipt")
  Assert.isTrue(receipt.committed, "the loss batch commits")
  Assert.equal(receipt.rewards.kind, "loss", "the loss plans through the money planning owner")
  Assert.equal(receipt.player.profile.money, 2960, "the receipt carries the debited money candidate")
  battle:dispose()
end

function T.capture_stages_party_dex_and_bag_through_the_committer()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with consequence staging")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")

  local party = newPartyOwner()
  local bag = newBagOwner()
  local dex = newDexOwner()
  local caught = foeRecord("TOTODILE", 4, 0xC0FFEE01)
  local launch = { id = "launch-capture-wire", kind = "wild", payload = { species = "TOTODILE", level = 4 } }
  local scenario = ScenarioFactory.fromEncounter(launch.payload, { party = party })
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    bagDeltas = { { op = "take", item = "POKE_BALL", quantity = 1 } },
    dex = dex,
    captures = { { captureId = 21, ball = "POKE_BALL", success = true, mon = caught } },
  })
  driveToSettlement(battle)
  Assert.equal(battle:status().phase, "complete", "answered decisions finish the capture battle")
  local receipt = assert(battle:status().outcomeReceipt, "completion carries its commit receipt")
  Assert.isTrue(receipt.committed, "the capture batch commits")
  Assert.equal(#receipt.placements, 1, "the capture reports its placement")
  Assert.isTrue(receipt.placements[1].retained, "room in the party retains the capture")
  Assert.equal(party:partyCount(), 2, "the caught mon lands in the live party")
  local stored = party:partyMon(1)
  Assert.equal(stored.species, "TOTODILE", "the appended mon keeps its species")
  Assert.equal(stored.personality, caught.personality, "the appended mon keeps its identity")
  Assert.isTrue(dex:isCaught("TOTODILE"), "the capture registers caught knowledge")
  Assert.isTrue(dex:isSeen("TOTODILE"), "a caught mon counts as seen")
  Assert.equal(bag:quantity("POKE_BALL"), 4, "the planned ball consumption lands in the live bag")
  battle:dispose()
end

function T.full_party_capture_stays_an_honest_noop_while_consuming_the_ball()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with consequence staging")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")

  local party = newPartyOwner()
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0xAAAA0001, catalog)
  local species = { "TOTODILE", "EEVEE", "CHIKORITA", "TOTODILE", "EEVEE" }
  for _, key in ipairs(species) do
    local record = factory:createNormal(CatalogFixture.normalRequest({ species = key }))
    Assert.isTrue(party:addMon(record), "the no-op case needs a full party")
  end
  Assert.equal(party:partyCount(), 6, "the party starts full")
  local bag = newBagOwner()
  local dex = newDexOwner()
  local launch = { id = "launch-full-party-wire", kind = "wild", payload = { species = "EEVEE", level = 4 } }
  local scenario = ScenarioFactory.fromEncounter(launch.payload, { party = party })
  local caught = foeRecord("EEVEE", 4, 0xAAAA0002)
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    bagDeltas = { { op = "take", item = "POKE_BALL", quantity = 1 } },
    dex = dex,
    captures = { { captureId = 22, ball = "POKE_BALL", success = true, mon = caught } },
  })
  driveToSettlement(battle)
  Assert.equal(battle:status().phase, "complete", "answered decisions finish the full-party battle")
  local receipt = assert(battle:status().outcomeReceipt, "completion carries its commit receipt")
  Assert.isTrue(receipt.committed, "the full-party batch commits")
  Assert.equal(#receipt.placements, 1, "the capture reports its placement")
  Assert.isFalse(receipt.placements[1].retained, "a full party retains nothing")
  Assert.equal(receipt.placements[1].destination, "pc", "the placement names the unimplemented backend")
  Assert.equal(receipt.placements[1].reason, "pc_unimplemented", "the placement stays honest")
  Assert.equal(party:partyCount(), 6, "the live party is unchanged")
  Assert.isTrue(dex:isCaught("EEVEE"), "the capture still registers caught knowledge")
  Assert.equal(bag:quantity("POKE_BALL"), 4, "the ball stays consumed")
  battle:dispose()
end

function T.roamer_battle_advances_the_roamer_revision()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with consequence staging")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")

  local party = newPartyOwner()
  local roamer = newRoamerOwner()
  local standin = foeRecord("EEVEE", 20, 0x90A4E001, 1)
  local launch =
    { id = "launch-roamer-wire", kind = "wild", payload = { species = "EEVEE", level = 20, mon = standin } }
  local scenario = ScenarioFactory.fromEncounter(launch.payload, { party = party })
  -- The roaming record tracks its own battle health; the scenario foe is a
  -- 1-HP stand-in so the executed battle settles the standing.
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    roamer = { owner = roamer, key = "roamer-eevee", expectedRevision = 0, details = {} },
  })
  driveToSettlement(battle)
  Assert.equal(battle:status().phase, "complete", "answered decisions finish the roamer battle")
  local receipt = assert(battle:status().outcomeReceipt, "completion carries its commit receipt")
  Assert.isTrue(receipt.committed, "the roamer batch commits")
  Assert.equal(receipt.roamer.lifecycle, "defeated", "the receipt carries the settled roamer")
  Assert.equal(receipt.roamer.revision, 1, "the roamer revision advances exactly once")
  local ok = pcall(roamer.prepareEncounter, roamer, "roamer-eevee")
  Assert.isFalse(ok, "a defeated roamer no longer offers encounters")
  battle:dispose()
end

function T.unknown_capture_species_fails_the_resolution()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with consequence staging")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  local Committer = requirePresent(COMMITTER_MODULE, "end-to-end exactly-once result publication")

  local party = newPartyOwner()
  local launch = { id = "launch-unknown-capture", kind = "wild", payload = { species = "TOTODILE", level = 4 } }
  local scenario = ScenarioFactory.fromEncounter(launch.payload, { party = party })
  local bogus = foeRecord("EEVEE", 4, 0xAAAA0003)
  bogus.species = "MISSINGNO"
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    captures = { { captureId = 23, ball = "POKE_BALL", success = true, mon = bogus } },
  })
  driveToSettlement(battle)
  Assert.equal(battle:status().phase, "failed", "an unknown capture never stages")
  Assert.isNil(battle:status().outcomeReceipt, "a failed resolution records no receipt")
  Assert.isNil(Committer.receipt(launch.id), "a failed resolution records no success receipt")
  Assert.equal(party:partyCount(), 1, "the live party is unchanged")
  battle:dispose()
end

function T.unstaged_dex_reference_fails_the_resolution()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime with consequence staging")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  local Committer = requirePresent(COMMITTER_MODULE, "end-to-end exactly-once result publication")
  local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")

  local party = newPartyOwner()
  local dex = PokedexKnowledge.new({ species = { CHIKORITA = true } })
  local launch = { id = "launch-unstaged-dex", kind = "wild", payload = { species = "TOTODILE", level = 4 } }
  local scenario = ScenarioFactory.fromEncounter(launch.payload, { party = party })
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    dex = dex,
  })
  driveToSettlement(battle)
  Assert.equal(battle:status().phase, "failed", "an unstaged dex reference never publishes silently")
  Assert.isNil(battle:status().outcomeReceipt, "a failed resolution records no receipt")
  Assert.isNil(Committer.receipt(launch.id), "a failed resolution records no success receipt")
  battle:dispose()
end

return { tests = T }
