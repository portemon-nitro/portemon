-- Production composition: the Bell Tower roof's scripts declare the Ho-Oh
-- scene's assets through the published script index, and the field prepares
-- them in the background from map entry, without any scene running. Maps
-- whose scripts declare nothing prepare nothing.

local Assert = require("tests.support.Assert")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local RomImporter = require("romdump.src.source.RomImporter")

local VERSION = "heartgold"

local function freshGame(location)
  return {
    saveId = "save-00000001",
    versionId = VERSION,
    location = location,
    playerData = {
      profile = {
        name = "GOLD",
        gender = 0,
        trainerId = 1,
        money = 3000,
        badges = 0,
        nationalDex = false,
        runningShoes = false,
        runningShoesLock = false,
        rivalName = "Silver",
      },
      options = { textSpeed = "fastest", textFrame = 1 },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    fashionCase = FashionCaseState.empty(),
    playTime = PlayTime.new(),
    worldState = FieldEventState.new(),
    mons = require("tests.support.MonBucket").emptyForVersion(VERSION),
    bag = require("libs.hgss.src.save.BagSave").empty(),
    mart = require("libs.hgss.src.save.MartSave").empty(),
  }
end

-- Counts the Ho-Oh part loads the field performs; the wrappers are removed by
-- the returned restore.
local function countingLoads()
  local counts = { core = 0, cinematic = {} }
  local core, cinematic = FieldEffectAssetCache.loadHoOhCore, FieldEffectAssetCache.loadHoOhCinematic
  FieldEffectAssetCache.loadHoOhCore = function(...)
    counts.core = counts.core + 1
    return core(...)
  end
  FieldEffectAssetCache.loadHoOhCinematic = function(cacheFs, shot, variant)
    local key = shot .. variant
    counts.cinematic[key] = (counts.cinematic[key] or 0) + 1
    return cinematic(cacheFs, shot, variant)
  end
  local function restore()
    FieldEffectAssetCache.loadHoOhCore = core
    FieldEffectAssetCache.loadHoOhCinematic = cinematic
  end
  return counts, restore
end

local function boot(scope, location)
  local state = FieldState.new(freshGame(location), {
    derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
  })
  scope:own({
    release = function()
      state:dispose()
    end,
  })
  return state
end

local function withCounts(body)
  local counts, restore = countingLoads()
  local ok, err = pcall(body, counts)
  restore()
  assert(ok, err)
end

local function testBellTowerPreloadsInTheBackground(scope)
  if not RomImporter.isReady(VERSION) then
    return
  end
  withCounts(function(counts)
    local state = boot(scope, { mapSymbol = "MAP_BELL_TOWER_ROOF", fieldX = 15, fieldZ = 21, facing = "north" })
    local variant = assert(state.runtime.hoOhAppearanceScene):currentVariant()
    local expected = { ["first" .. variant] = 1, ["second" .. variant] = 1 }
    local function prepared()
      return counts.core == 1 and counts.cinematic["first" .. variant] == 1 and counts.cinematic["second" .. variant] == 1
    end
    for _ = 1, 600 do
      if prepared() then
        break
      end
      state:update(1 / 60)
    end
    Assert.isTrue(prepared(), "the scene's parts are loaded in the background after map entry")
    Assert.equal(counts.core, 1, "the core loads once")
    Assert.deepEqual(counts.cinematic, expected, "only the live variant's two shots load")
    -- The remaining units are mesh and texture work; let them finish, then
    -- nothing further is loaded.
    for _ = 1, 120 do
      state:update(1 / 60)
    end
    Assert.equal(counts.core, 1)
    Assert.deepEqual(counts.cinematic, expected, "a finished preparation loads nothing more")
  end)
end

local function testOtherMapsPrepareNothing(scope)
  if not RomImporter.isReady(VERSION) then
    return
  end
  withCounts(function(counts)
    local state = boot(scope, { mapSymbol = "MAP_NEW_BARK", fieldX = 10, fieldZ = 10, facing = "south" })
    for _ = 1, 240 do
      state:update(1 / 60)
    end
    Assert.equal(counts.core, 0, "a map without the scene's scripts loads no Ho-Oh data")
    Assert.deepEqual(counts.cinematic, {})
  end)
end

local T = GraphicsSmoke.suite({
  ["the Bell Tower roof prepares the Ho-Oh scene in the background from map entry"] = testBellTowerPreloadsInTheBackground,
  ["a map without Ho-Oh scripts prepares nothing"] = testOtherMapsPrepareNothing,
})
T.metadata.capabilities = { "graphics", "rom_dump" }
T.metadata.derivedAssets = { "field-runtime", "map-data:340", "map:340", "map:60" }
T.metadata.tags = { "field", "ho-oh", "preload" }
return T
