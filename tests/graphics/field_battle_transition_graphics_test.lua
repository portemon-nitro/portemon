-- Production FieldState composition keeps the selected field encounter
-- transition visible through multiple native source frames before battle reveal.

local Assert = require("tests.support.Assert")
local BagSave = require("libs.hgss.src.save.BagSave")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattleEncounterSelector = require("libs.hgss.src.transition.BattleEncounterSelector")
local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
local CacheFs = require("libs.storage.src.CacheFs")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldState = require("game.hgss.src.field.FieldState")
local LocalClock = require("game.src.LocalClock")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local MonBucket = require("tests.support.MonBucket")
local HgssTrainerCatalog = require("libs.hgss.src.battle.HgssTrainerCatalog")
local MonCache = require("libs.assets.src.MonCache")
local MonsSave = require("libs.mons.src.MonsSave")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local RomImporter = require("romdump.src.source.RomImporter")
local NavigationFacts = require("tests.rom.support.NavigationFacts")
local RomSourcePath = require("tests.rom.support.RomSourcePath")

local T = {}
local caveEncounterLocation

local function readyVersion()
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      return versionId
    end
  end
  error("a ready game dump and derived cache are required", 0)
end

local function freshGame(versionId, location)
  local cacheFs = CacheFs.forVersion(versionId)
  local catalog = MonBucket.openCatalogs(versionId)
  local fontDef = FieldFontLoader.load(cacheFs)
  local monService = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.empty(7),
    profile = { name = "GOLD", gender = 0, trainerId = 1 },
    game = versionId,
    language = MonCache.loadCatalog(cacheFs).version.language,
    charmap = assert(fontDef.charmap),
    mapSection = function()
      return 60
    end,
    date = { year = 2000, month = 1, day = 1 },
  })
  Assert.isTrue(monService:giveMon({ species = "CHIKORITA", level = 5, location = 60 }))
  return {
    saveId = "save-00000001",
    versionId = versionId,
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
      options = { textSpeed = "fastest", textFrame = 0 },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    fashionCase = FashionCaseState.empty(),
    playTime = PlayTime.new(),
    worldState = FieldEventState.new(),
    mons = monService:capture(),
    bag = BagSave.empty(),
    mart = require("libs.hgss.src.save.MartSave").empty(),
  }
end

local function render(scope, state)
  local target = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 0)
  state:draw()
  love.graphics.setCanvas()
  return scope:own(target:newImageData())
end

local function draw(state, target)
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 0)
  state:draw()
  love.graphics.setCanvas()
end

local function pixelDifference(left, right)
  local changed = 0
  for y = 0, 191 do
    for x = 0, 255 do
      local lr, lg, lb, la = left:getPixel(x, y)
      local rr, rg, rb, ra = right:getPixel(x, y)
      if lr ~= rr or lg ~= rg or lb ~= rb or la ~= ra then
        changed = changed + 1
      end
    end
  end
  return changed
end

local function assertPresentedRoute(scope, versionId, cacheFs, case)
  local derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets
  derivedAssets.requestBattleScene = function(sceneKey)
    Assert.equal(
      sceneKey,
      case.sceneKey,
      case.name .. " selects its source battle scene (expected " .. case.sceneKey .. ", got " .. sceneKey .. ")"
    )
    return true
  end
  local state = FieldState.new(freshGame(versionId, case.location), {
    derivedAssets = derivedAssets,
    localClock = LocalClock.new(function()
      return { year = 2000, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
    end),
  })
  scope:own({
    release = function()
      state:dispose()
    end,
  })
  state:resize(256, 192)
  local runtime = assert(state.runtime)
  local entryTarget = scope:own(love.graphics.newCanvas(256, 192))
  for _ = 1, 600 do
    if runtime.session.mapEntryStage == nil and runtime.transition.phase == "idle" then
      break
    end
    state:update(1 / 60)
    draw(state, entryTarget)
  end
  Assert.equal(runtime.session.mapEntryStage, nil, case.name .. " finishes production map entry")
  Assert.equal(runtime.transition.phase, "idle", case.name .. " settles before battle launch")

  runtime:launchBattle(case.request)
  local selected = nil
  for _ = 1, 120 do
    state:update(1 / 60)
    local status = state.battleEnvelope:transitionStatus()
    if status ~= nil and status.phase == "running" then
      selected = status
      break
    end
  end
  Assert.notNil(selected, case.name .. " starts its selected transition")
  local manifest = assert(cacheFs:loadLua(BattlePresentationCache.manifestPath()))
  local expected = BattleEncounterSelector.resolve(manifest.transitions, case.selectorContext)
  Assert.equal(selected.routeKey, expected.routeKey, case.name .. " uses the generated source selector")
  Assert.isNil(runtime.battleCoordinator:activeBattle(), case.name .. " transition precedes battle construction")

  local first = render(scope, state)
  Assert.equal(pixelDifference(first, render(scope, state)), 0, case.name .. " repeated draw does not advance")
  local beforeResize = state.battleEnvelope:transitionStatus()
  state:resize(512, 384)
  draw(state, scope:own(love.graphics.newCanvas(512, 384)))
  state:resize(256, 192)
  local afterResize = state.battleEnvelope:transitionStatus()
  Assert.equal(afterResize.phase, beforeResize.phase, case.name .. " resize does not advance the route")
  Assert.equal(afterResize.routeKey, beforeResize.routeKey, case.name .. " resize retains route identity")
  local previous = render(scope, state)
  Assert.equal(pixelDifference(first, previous), 0, case.name .. " native resize return preserves the frame")

  local changedFrames = 0
  local transitionCompleted = false
  for _ = 1, case.sampleTicks or 24 do
    state:update(1 / 60)
    local status = state.battleEnvelope:transitionStatus()
    if status == nil or status.phase ~= "running" then
      transitionCompleted = status ~= nil and status.phase == "complete"
      break
    end
    local current = render(scope, state)
    if pixelDifference(previous, current) > 0 then
      changedFrames = changedFrames + 1
    end
    previous = current
    if changedFrames >= 2 and case.sampleUntilComplete ~= true then
      break
    end
  end
  if case.expectChangingPixels ~= false then
    Assert.isTrue(changedFrames >= 2, case.name .. " changes native pixels across source ticks")
  end
  if case.sampleUntilComplete == true then
    Assert.isTrue(transitionCompleted, case.name .. " runs its source route to completion")
  else
    Assert.isNil(runtime.battleCoordinator:activeBattle(), case.name .. " remains before battle intro")
  end
end

function T.field_transition_composes_selected_native_frames_before_battle_intro(scope)
  local versionId = readyVersion()
  local cacheFs = CacheFs.forVersion(versionId)
  local romFs, romSource = RomSourcePath.openReader(versionId)
  assert(romFs, tostring(romSource))
  local okFacts, facts = pcall(NavigationFacts.discover, cacheFs, romFs)
  local route29 = assert(MapResolver.resolve(romFs, "MAP_ROUTE_29"))
  scope:own({
    release = function()
      romFs:close()
      romSource:release()
    end,
  })
  assert(okFacts, tostring(facts))

  local grassLocation = {
    mapSymbol = "MAP_ROUTE_29",
    fieldX = facts.grass.fieldX - route29.worldOriginX,
    fieldZ = facts.grass.fieldZ - route29.worldOriginZ,
    facing = "south",
  }
  local grassWildContext = {
    kind = "wild",
    wildSpecies = "CATERPIE",
    doubleBattle = false,
    specialBattle = false,
    alternateTransition = false,
    playerGender = "male",
    wildSetupFallback = false,
    terrain = "plain",
    timeOfDay = "day",
  }
  local request = { kind = "wild", details = { species = "CATERPIE", level = 3 } }
  assertPresentedRoute(scope, versionId, cacheFs, {
    name = "Route 29 grass wild",
    location = grassLocation,
    request = request,
    sceneKey = "general/grass/day",
    selectorContext = grassWildContext,
  })

  local newBark = assert(MapResolver.resolve(romFs, "MAP_NEW_BARK"))
  assertPresentedRoute(scope, versionId, cacheFs, {
    name = "New Bark water wild",
    location = {
      mapSymbol = "MAP_NEW_BARK",
      fieldX = facts.water.fieldX - newBark.worldOriginX,
      fieldZ = facts.water.fieldZ - newBark.worldOriginZ,
      facing = "south",
    },
    request = request,
    sceneKey = "general/water/day",
    selectorContext = {
      kind = "wild",
      wildSpecies = "CATERPIE",
      doubleBattle = false,
      specialBattle = false,
      alternateTransition = false,
      playerGender = "male",
      wildSetupFallback = false,
      terrain = "water",
      timeOfDay = "day",
    },
  })

  local caveMap = assert(MapResolver.resolve(romFs, "MAP_UNION_CAVE_1F"))
  local caveLocation = caveEncounterLocation(cacheFs, caveMap)
  assertPresentedRoute(scope, versionId, cacheFs, {
    name = "Union Cave floor wild",
    location = caveLocation,
    request = request,
    sceneKey = "cave_1/cave/day",
    selectorContext = {
      kind = "wild",
      wildSpecies = "CATERPIE",
      doubleBattle = false,
      specialBattle = false,
      alternateTransition = false,
      playerGender = "male",
      wildSetupFallback = false,
      terrain = "cave",
      timeOfDay = "day",
    },
  })

  local trainers = HgssTrainerCatalog.new(BattleDataCache.loadTrainers(cacheFs))
  local trainer = assert(HgssTrainerCatalog.trainer(trainers, 4), "staged trainer data includes trainer 4")
  assertPresentedRoute(scope, versionId, cacheFs, {
    name = "Route 29 trainer",
    expectChangingPixels = true,
    sampleTicks = 240,
    sampleUntilComplete = true,
    location = grassLocation,
    request = { kind = "trainer", details = { trainer = 4 } },
    sceneKey = "general/grass/day",
    selectorContext = {
      kind = "trainer",
      trainerClass = trainer.trainerClass,
      doubleBattle = trainer.doubleBattle == true,
      specialBattle = false,
      alternateTransition = false,
      playerGender = "male",
      terrain = "plain",
      timeOfDay = "day",
    },
  })
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_assets" }
suite.metadata.derivedAssets = {
  "field-runtime",
  "field-cell-index:global",
  "field-cell:42-0",
  "field-cell:42-1",
  "field-cell:42-2",
  "map-data:60",
  "map-data:48",
  "map-data:31",
  "map-data:47",
  "map-data:33",
  "map-data:67",
  "map-data:99",
  "map:60",
  "map:48",
  "map:31",
  "map:47",
  "map:33",
  "map:67",
  "map:99",
  "battle-presentation:global",
  "battle-scene:general/grass/day",
  "battle-scene:general/plain/day",
  "battle-scene:general/water/day",
  "battle-scene:cave_1/cave/day",
  "trainers:global",
  "mon-icon-page:0",
  "mon-portrait-page:0",
  "audio-bank:702",
  "audio-bank:709",
  "audio-bank:728",
}

-- Select a source cave-floor tile from the prepared Union Cave cells. The
-- field-cell index supplies its exact matrix/member identity; behavior 8 is
-- the HGSS cave-floor behavior used by the battle scene selector.
caveEncounterLocation = function(cacheFs, caveMap)
  local index = FieldCellCache.loadIndex(cacheFs)
  local descriptors = {}
  for _, matrix in ipairs(index.matrices) do
    for _, descriptor in ipairs(matrix.cells) do
      if descriptor.mapHeaderId == caveMap.map.id then
        descriptors[#descriptors + 1] = descriptor
      end
    end
  end
  table.sort(descriptors, function(left, right)
    if left.matrixMemberId == right.matrixMemberId then
      return left.index < right.index
    end
    return left.matrixMemberId < right.matrixMemberId
  end)

  for _, descriptor in ipairs(descriptors) do
    if cacheFs:exists(descriptor.file, "file") then
      local cell = assert(cacheFs:loadLua(descriptor.file))
      local collision = assert(cacheFs:read(cell.collision.file))
      local grid = assert(CollisionGridAsset.decode(collision, { cell = descriptor.file }))
      for tileIndex, tile in ipairs(grid.cells) do
        if tile.behavior == 8 and not tile.blocked then
          local fieldX = descriptor.x * 32 + (tileIndex - 1) % 32
          local fieldZ = descriptor.z * 32 + math.floor((tileIndex - 1) / 32)
          return {
            mapSymbol = "MAP_UNION_CAVE_1F",
            fieldX = fieldX - caveMap.worldOriginX,
            fieldZ = fieldZ - caveMap.worldOriginZ,
            facing = "south",
          }
        end
      end
    end
  end
  error("prepared Union Cave cells have no passable source cave-floor tile", 0)
end

return suite
