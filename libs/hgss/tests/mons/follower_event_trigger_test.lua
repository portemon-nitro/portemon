-- Retail special follower events are selected from validated mon metadata.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local Personality = require("libs.mons.src.gen4.Personality")

local function copy(value)
  local result = {}
  for key, child in pairs(value) do
    result[key] = type(child) == "table" and copy(child) or child
  end
  return result
end

local function newService(species, options)
  options = options or {}
  local root = CatalogFixture.buildAssetRoot()
  for key, nativeId in pairs({ ARCEUS = 493, PICHU = 172, PIKACHU = 25, RAICHU = 26, CELEBI = 251 }) do
    local entry = copy(root.species.EEVEE)
    entry.nativeId = nativeId
    entry.name = key
    root.species[key] = entry
  end
  local catalog = MonCatalog.new(root, CatalogFixture.makeItemCatalog())
  local bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x4321):capture())
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = bucket,
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
  })
  local mon = CatalogFixture.makeFactory(0x8765, catalog)
    :createNormal(CatalogFixture.normalRequest({ species = species or "ARCEUS", level = 9 }))
  mon.fatefulEncounter = options.fatefulEncounter == true
  mon.isEgg = options.isEgg == true
  mon.egg.location = options.eggLocation or 0
  mon.met.location = options.metLocation or 86
  mon.origin.game = options.originGame or "diamond"
  mon.origin.trainerId = options.originTrainerId or 1
  mon.personality = options.personality or mon.personality
  Assert.isTrue(service:addMon(mon))
  return service, mon
end

local T = {}

function T.hall_of_origin_requires_traded_diamond_pearl_or_platinum_arceus()
  for _, game in ipairs({ "diamond", "pearl", "platinum" }) do
    local service = newService("ARCEUS", { originGame = game })
    Assert.isTrue(service:followerEventTrigger(1, 0))
    Assert.isFalse(service:followerEventTrigger(4, 0))
  end

  local wrongLocation = newService("ARCEUS", { metLocation = 85 })
  Assert.isFalse(wrongLocation:followerEventTrigger(1, 0))
  local sameTrainer = newService("ARCEUS", { originTrainerId = CatalogFixture.profile().trainerId })
  Assert.isFalse(sameTrainer:followerEventTrigger(1, 0))
end

function T.event_zero_requires_a_shiny_fateful_unevolved_pichu_line_mon()
  local trainerId = 1
  local shinyPersonality = 0
  while not Personality.shiny(trainerId, shinyPersonality) do
    shinyPersonality = shinyPersonality + 1
  end
  local service = newService("PIKACHU", { fatefulEncounter = true, personality = shinyPersonality })
  Assert.isTrue(service:followerEventTrigger(0, 0))

  local hatched = newService("PIKACHU", {
    fatefulEncounter = true,
    eggLocation = 1,
    personality = shinyPersonality,
  })
  Assert.isFalse(hatched:followerEventTrigger(0, 0))
  local unsupported = newService("EEVEE", { fatefulEncounter = true, personality = shinyPersonality })
  Assert.isFalse(unsupported:followerEventTrigger(0, 0))
end

function T.events_two_and_three_require_fateful_unknowable_encounters()
  local arceus = newService("ARCEUS", { fatefulEncounter = true })
  Assert.isTrue(arceus:followerEventTrigger(2, 0))
  local hatchedArceus = newService("ARCEUS", { fatefulEncounter = true, eggLocation = 1 })
  Assert.isFalse(hatchedArceus:followerEventTrigger(2, 0))

  local celebi = newService("CELEBI", { fatefulEncounter = true })
  Assert.isTrue(celebi:followerEventTrigger(3, 0))
  Assert.isFalse(arceus:followerEventTrigger(3, 0))
  Assert.isFalse(celebi:followerEventTrigger(2, 0))
end

function T.invalid_event_is_false_and_invalid_slot_still_fails()
  local service = newService()
  Assert.isFalse(service:followerEventTrigger(4, 0))
  Assert.throws(function()
    service:followerEventTrigger(4, 6)
  end)
end

return { tests = T }
