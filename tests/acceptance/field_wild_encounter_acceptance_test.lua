-- Real input-driven wild encounters on walkable terrain. Actual committed
-- movement on Route 29 grass and on Dark Cave floors reaches the encounter
-- service, admits one presented wild battle through the production
-- field-local envelope, and returns to a live field after flight. The run
-- boots the production field through the shared harness with the render
-- trap armed, binds the real envelope behind recording host boundaries, and
-- drives real movement: no step is injected, no encounter is prepared by
-- hand, and no draw call may fire. Flight closes the bout so the proof
-- covers admission and return without depending on native battle-effect
-- program execution.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local CacheFs = require("libs.storage.src.CacheFs")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local NavigationFacts = require("tests.rom.support.NavigationFacts")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {
  tests = {},
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = {
      "field-runtime",
      "map-data:31",
      "map-data:33",
      "map-data:34",
      "map-data:47",
      "map-data:48",
      "map-data:60",
      "map-data:61",
      "map-data:63",
      "map-data:67",
      "map-data:176",
      "map-data:384",
      "map:33",
      "map:34",
      "map:60",
      "map:61",
      "map:63",
      "map:67",
      "map:176",
      "encounters:global",
      "battle-presentation:global",
      "battle-scene:cave_1/cave/day",
    },
    tags = { "field", "battle", "acceptance" },
  },
}

local TICK = 1 / 60
local PRESENTATION_OWNER = "game.hgss.src.field.FieldBattlePresentation"
local PACING_BUDGET = 150
local SETTLE_BUDGET = 6000

---@param game table live acceptance game under test driving
local function freezeActors(game)
  local runtime = game.runtime
  for mapId in pairs(runtime.actors.maps) do
    for _, actor in ipairs(runtime.actors:actorsOf(mapId)) do
      runtime.actors:setMovementType(actor.actorId, "stationary")
    end
  end
end

---@param versionId string ready game version under test driving
---@return table harness
---@return table game live acceptance game with a settled field and a live party pair
local function bootNewBark(versionId)
  local harness = AcceptanceHarness.new({ versions = { versionId } })
  local game = harness:boot({ versionId = versionId, map = "MAP_NEW_BARK", save = "fresh" })
  game:waitForFieldEntry()
  freezeActors(game)
  Assert.isTrue(
    game.runtime.monService:giveMon({ species = "CHIKORITA", level = 9 }),
    "the walk needs its live party lead"
  )
  Assert.isTrue(
    game.runtime.monService:giveMon({ species = "CHIKORITA", level = 9 }),
    "the walk needs its live party reserve"
  )
  return harness, game
end

---@param versionId string ready game version under test driving
---@return table route facts carrying the grass pacing tile
local function routeFacts(versionId)
  local RomSourcePath = require("tests.rom.support.RomSourcePath")
  local romFs, romSource = RomSourcePath.openReader(versionId)
  assert(romFs, tostring(romSource))
  local ok, facts = pcall(NavigationFacts.discover, CacheFs.forVersion(versionId), romFs)
  romFs:close()
  romSource:release()
  if not ok then
    error(facts, 0)
  end
  assert(type(facts) == "table" and facts.grass ~= nil, "route facts carry a grass pacing tile")
  return facts
end

---@param game table live acceptance game under test driving
---@param facts table route facts carrying the grass pacing tile
local function walkToGrass(game, facts)
  game:moveTo({ fieldX = facts.grass.fieldX, fieldZ = facts.grass.fieldZ })
  game:advanceUntil("the grass tile settles", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 120)
end

---@param game table live acceptance game under test driving
---@return table player cell identity under inspection
local function playerCell(game)
  local player = game:snapshot().player
  return { fieldX = player.fieldX, fieldZ = player.fieldZ, facing = player.facing }
end

---@return table upload-capable graphics namespace behind presented launches
local function uploadCapableGraphics()
  local graphics = {}
  function graphics.newImage(source)
    local handle = {}
    function handle.setFilter(...) end
    function handle.getDimensions()
      local ok, width, height = pcall(function()
        return source:getDimensions()
      end)
      if ok and type(width) == "number" and type(height) == "number" then
        return width, height
      end
      return 1, 1
    end
    function handle.getWidth()
      local width = handle.getDimensions()
      return width
    end
    function handle.getHeight()
      local _, height = handle.getDimensions()
      return height
    end
    return handle
  end
  return graphics
end

---@param game table live acceptance game under test driving
---@param versionId string ready game version under test driving
---@return table envelope live field-local presented-battle envelope
---@return integer binding token-guarded factory binding identity
local function bindEnvelope(game, versionId)
  local doubles = {
    audio = {
      plays = {},
      play = function(self, name)
        self.plays[#self.plays + 1] = name
        return true
      end,
    },
    windows = {
      calls = {},
      drawWindow = function(self, box, frameKey, background)
        self.calls[#self.calls + 1] = { box = box, frame = frameKey, background = background }
      end,
      drawApplicationFrame = function(self, box, frameKey)
        self.calls[#self.calls + 1] = { box = box, frame = frameKey }
      end,
    },
    text = {
      draws = {},
      measure = function(_, content)
        return { width = 8 * #tostring(content), height = 16 }
      end,
      drawText = function(self, content, x, y)
        self.draws[#self.draws + 1] = { content = tostring(content), x = x, y = y }
      end,
    },
  }
  local Presentation = require(PRESENTATION_OWNER)
  local envelope = Presentation.new({
    cacheFs = CacheFs.forVersion(versionId),
    graphics = uploadCapableGraphics(),
    windows = doubles.windows,
    text = doubles.text,
    audio = doubles.audio,
    measureDisplay = function()
      return {
        width = 256,
        height = 384,
        topology = ScreenTopology.dualDisplay(
          { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
          { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
        ),
        pixelRatio = 1,
        signature = "wild-encounter:dual",
      }
    end,
  })
  local factory = envelope:factory()
  local binding = game.runtime:bindBattlePresentation(function(descriptor)
    return factory(descriptor)
  end)
  return envelope, binding
end

---@param game table live acceptance game under test driving
---@param envelope table live presented-battle envelope under test driving
---@param ticks integer fixed ticks to advance under test driving
local function pump(game, envelope, ticks)
  for _ = 1, ticks do
    game:step()
    envelope:updateFixed(TICK)
  end
end

---@param request table<string, unknown> pending player decision under inspection
---@return boolean true when flight is a legal answer now
local function admitsRun(request)
  local legal = request.legalChoices
  if type(legal) ~= "table" or type(legal.kinds) ~= "table" then
    return false
  end
  for _, kind in ipairs(legal.kinds) do
    if kind == "run" then
      return true
    end
  end
  return false
end

-- Settles one admitted presented battle by flight: answers the opening
-- decision with a run, pumps field and envelope until the receipt
-- publishes, and reports the observed stage facts. A stuck launch fails
-- loudly with its last phase instead of timing out silently.
---@param game table live acceptance game under test driving
---@param envelope table live presented-battle envelope under test driving
---@return table stage facts carrying the encountered species and launch method
local function fleeAndReturn(game, envelope)
  local runtime = game.runtime
  local launch = assert(runtime.battleCoordinator._battleLaunch, "flight settles an admitted presented launch")
  local environment = assert(launch.environment, "the admitted launch captures its environment")
  local prepared = assert(runtime.pendingEncounter, "the admitted launch holds its prepared encounter")
  local wildMon = assert(prepared.mons[1].mon, "the prepared encounter carries its wild mon")
  local species = assert(wildMon.species, "the prepared wild mon names its species")
  Assert.isTrue(type(species) == "string" and species ~= "", "the encounter species comes from the source table")
  local fled = false
  local ticks = 0
  while
    (runtime.battleCoordinator:activeBattle() ~= nil or runtime.battleCoordinator._battleLaunch ~= nil)
    and ticks < SETTLE_BUDGET
  do
    local battle = runtime.battleCoordinator:activeBattle()
    if battle ~= nil then
      local current = battle:status()
      if current.phase == "failed" then
        error("the walking battle failed: " .. tostring(current.error), 0)
      end
      if current.phase == "running" and current.request ~= nil then
        local actor = assert(current.request.actors[1], "the flight decision addresses its combatant")
        Assert.isTrue(admitsRun(current.request), "the wild bout admits flight")
        Assert.isFalse(fled, "flight answers the opening decision once")
        fled = true
        local accepted, replyErr = battle:submit(
          SessionFixture.replyFor(current.request, { { actor = actor, kind = "run", payload = {} } })
        )
        Assert.isTrue(accepted, "the flight decision is accepted: " .. tostring(replyErr))
      end
    end
    local pending = runtime.battleCoordinator._battleLaunch
    if pending ~= nil and pending.phase == "failed" then
      error("the presented launch failed: " .. tostring(pending.error or runtime.errorText), 0)
    end
    local screen = envelope:liveScreen()
    if screen ~= nil then
      local shown = screen:status()
      if shown.mode == "intro" or shown.mode == "narration" or shown.mode == "outcome" then
        envelope:input({ { type = "confirm" } })
      end
    end
    game:step()
    envelope:updateFixed(TICK)
    ticks = ticks + 1
  end
  Assert.isTrue(fled, "the bout answers its opening decision with flight")
  Assert.isNil(runtime.battleCoordinator:activeBattle(), "flight settles the owned lifetime")
  Assert.isNil(runtime.battleCoordinator._battleLaunch, "the return publishes its receipt")
  local words = assert(runtime:lastBattleResult(), "flight publishes its outcome words")
  Assert.equal(words.result, "flee", "flight reports its exact word")
  return { species = species, method = environment.method }
end

-- Paces the walkable grass axis around the anchor until the first prepared
-- encounter reaches the real envelope on its own. Turning in place and
-- idle polling never complete a step, so only real arrival tiles consume
-- opportunity draws; the service attempt count is observed through a
-- test-owned recorder around the production call.
---@param game table live acceptance game under test driving
---@param envelope table live presented-battle envelope under test driving
---@return table stage facts from the settled bout
---@return integer service attempts observed during the walk
local function walkUntilEncounter(game, envelope)
  local runtime = game.runtime
  local attempts = 0
  local realAttempt = runtime.attemptEncounter
  runtime.attemptEncounter = function(self, context)
    attempts = attempts + 1
    return realAttempt(self, context)
  end
  local ok, facts, observed = xpcall(function()
    local anchor = playerCell(game)
    for _ = 1, PACING_BUDGET do
      if runtime.battleCoordinator._battleLaunch ~= nil then
        break
      end
      -- The grass tile east of the anchor is a wall, so pace the
      -- walkable westward axis instead: west off the anchor and back.
      if playerCell(game).fieldX >= anchor.fieldX then
        game:move("west")
      else
        game:move("east")
      end
      envelope:updateFixed(TICK)
      -- A host update spanning several fixed ticks still consumes the
      -- committed step exactly once.
      runtime:update(3 * TICK)
      envelope:updateFixed(TICK)
    end
    Assert.notNil(runtime.battleCoordinator._battleLaunch, "an eligible walk admits its presented launch")
    local settled = fleeAndReturn(game, envelope)
    return settled, attempts
  end, debug.traceback)
  runtime.attemptEncounter = realAttempt
  if not ok then
    error(facts, 0)
  end
  Assert.isTrue(observed > 0, "committed walking steps evaluate encounters")
  return facts, observed
end

function T.tests.walking_grass_reaches_a_presented_battle_and_returns()
  local versionId = AcceptanceHarness.defaultVersion()
  local _, game = bootNewBark(versionId)
  local runtime = game.runtime
  local facts = nil
  local ok, failure = xpcall(function()
    OpeningLifecycle.seedNewBarkWestExitScene(game)
    OpeningLifecycle.settleNewBarkFriendScene(game)
    freezeActors(game)
    local route = routeFacts(versionId)
    walkToGrass(game, route)
    Assert.isNil(runtime.battleCoordinator:activeBattle(), "the walk to the grass stays outside battle")
    local envelope, binding = bindEnvelope(game, versionId)
    local bound, boundFailure = xpcall(function()
      facts, _ = walkUntilEncounter(game, envelope)
    end, debug.traceback)
    pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    if not bound then
      error(boundFailure, 0)
    end
    Assert.equal(facts.method, "grass", "the grass walk selects the grass method")
    Assert.isTrue(type(facts.species) == "string" and facts.species ~= "", "the grass bout names its wild species")
    -- After the continuing return, ordinary input walks again. The
    -- resumed step may itself admit a fresh encounter on the same
    -- eligible grass; flight closes that bout too before asserting.
    local before = playerCell(game)
    game:face("west")
    pump(game, envelope, 10)
    Assert.isNil(runtime.battleCoordinator:activeBattle(), "turning after return launches nothing")
    game:move("west")
    game:advanceUntil("the resumed step resolves", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 120)
    if runtime.battleCoordinator._battleLaunch ~= nil then
      fleeAndReturn(game, envelope)
    end
    local after = playerCell(game)
    Assert.isTrue(
      after.fieldX ~= before.fieldX or after.fieldZ ~= before.fieldZ,
      "ordinary input walks again after the return"
    )
    Assert.equal(game:renderAttempts(), 0, "the walk stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(failure, 0)
  end
  Assert.notNil(facts, "the walk reports its stage facts")
end

function T.tests.walking_cave_floor_reaches_a_presented_battle_and_returns()
  local versionId = AcceptanceHarness.defaultVersion()
  -- Dark Cave floor tiles are discovered from the prepared physical
  -- cells before boot: the boot itself then proves whether the interior
  -- map admits a direct arrival, and every step after that is real.
  local cacheFs = CacheFs.forVersion(versionId)
  local RomSourcePath = require("tests.rom.support.RomSourcePath")
  local romFs, romSource = RomSourcePath.openReader(versionId)
  assert(romFs, tostring(romSource))
  local okScan, floors = pcall(function()
    local resolved = assert(MapResolver.resolve(romFs, "MAP_DARK_CAVE_ROUTE_31_SIDE"))
    local index = FieldCellCache.loadIndex(cacheFs)
    local found = {}
    for _, matrix in ipairs(index.matrices) do
      for _, cell in ipairs(matrix.cells or {}) do
        if cell.mapHeaderId == resolved.map.id and cell.matrixMemberId == resolved.matrixMemberId then
          if cacheFs:exists(cell.file, "file") then
            local record = assert(cacheFs:loadLua(cell.file))
            local grid = assert(CollisionGridAsset.decode(assert(cacheFs:read(record.collision.file))))
            for localZ = 0, 31 do
              for localX = 0, 31 do
                local tile = grid.cells[localZ * 32 + localX + 1]
                if tile ~= nil and tile.behavior == 8 and tile.blocked ~= true then
                  found[#found + 1] = { fieldX = cell.x * 32 + localX, fieldZ = cell.z * 32 + localZ }
                end
              end
            end
          end
        end
      end
    end
    table.sort(found, function(left, right)
      if left.fieldX ~= right.fieldX then
        return left.fieldX < right.fieldX
      end
      return left.fieldZ < right.fieldZ
    end)
    return found
  end)
  romFs:close()
  romSource:release()
  if not okScan then
    error(floors, 0)
  end
  Assert.isTrue(#floors > 0, "Dark Cave prepares walkable behavior-8 floor")
  local bootTile = floors[1]
  local harness = AcceptanceHarness.new({
    versions = { versionId },
    gameFactory = function(bootVersionId, bootMap)
      return {
        saveId = "save-00000001",
        versionId = bootVersionId,
        location =
          { mapSymbol = bootMap, fieldX = bootTile.fieldX, fieldZ = bootTile.fieldZ, facing = "south" },
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
        fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(bootVersionId, 7),
        bag = require("libs.hgss.src.save.BagSave").empty(),
        mart = require("libs.hgss.src.save.MartSave").empty(),
      }
    end,
  })
  local game = harness:boot({ versionId = versionId, map = "MAP_DARK_CAVE_ROUTE_31_SIDE", save = "fresh" })
  local facts = nil
  local ok, failure = xpcall(function()
    game:waitForFieldEntry()
    freezeActors(game)
    local runtime = game.runtime
    Assert.isTrue(runtime.monService:giveMon({ species = "CHIKORITA", level = 9 }), "the cave walk needs its lead")
    Assert.isTrue(
      runtime.monService:giveMon({ species = "CHIKORITA", level = 9 }),
      "the cave walk needs its reserve"
    )
    -- The pacing pair is observed through the live arrival behavior
    -- around the arrival: two adjacent behavior-8 tiles pace without a
    -- single injected step.
    local map = assert(runtime.session.currentMap, "the cave boot resolves its map")
    local at = playerCell(game)
    local function behaviorAt(fieldX, fieldZ)
      return runtime:arrivalBehavior(map, { fieldX = fieldX, fieldZ = fieldZ })
    end
    local pair = nil
    for radius = 0, 6 do
      for dz = -radius, radius do
        for dx = -radius, radius do
          if behaviorAt(at.fieldX + dx, at.fieldZ + dz) == 8 then
            for _, step in ipairs({ { x = 1, z = 0 }, { x = 0, z = 1 } }) do
              if behaviorAt(at.fieldX + dx + step.x, at.fieldZ + dz + step.z) == 8 then
                pair = {
                  anchor = { fieldX = at.fieldX + dx, fieldZ = at.fieldZ + dz },
                  direction = step.x == 1 and "east" or "south",
                }
                break
              end
            end
          end
          if pair ~= nil then
            break
          end
        end
        if pair ~= nil then
          break
        end
      end
      if pair ~= nil then
        break
      end
    end
    Assert.notNil(pair, "the cave arrival neighbors a pacable behavior-8 pair")
    game:moveTo({ fieldX = pair.anchor.fieldX, fieldZ = pair.anchor.fieldZ })
    local envelope, binding = bindEnvelope(game, versionId)
    local bound, boundFailure = xpcall(function()
      local anchor = playerCell(game)
      local runtimeInner = game.runtime
      local attempts = 0
      local realAttempt = runtimeInner.attemptEncounter
      runtimeInner.attemptEncounter = function(self, context)
        attempts = attempts + 1
        return realAttempt(self, context)
      end
      local attemptOk, settled, observed = xpcall(function()
        for _ = 1, PACING_BUDGET do
          if runtimeInner.battleCoordinator._battleLaunch ~= nil then
            break
          end
          local cell = playerCell(game)
          if cell.fieldX == anchor.fieldX and cell.fieldZ == anchor.fieldZ then
            game:move(pair.direction)
          elseif pair.direction == "east" or pair.direction == "west" then
            game:move(cell.fieldX > anchor.fieldX and "west" or "east")
          else
            game:move(cell.fieldZ > anchor.fieldZ and "north" or "south")
          end
          envelope:updateFixed(TICK)
          runtimeInner:update(3 * TICK)
          envelope:updateFixed(TICK)
        end
        Assert.notNil(
          runtimeInner.battleCoordinator._battleLaunch,
          "a cave-floor walk admits its presented launch"
        )
        local fled = fleeAndReturn(game, envelope)
        return fled, attempts
      end, debug.traceback)
      runtimeInner.attemptEncounter = realAttempt
      if not attemptOk then
        error(settled, 0)
      end
      Assert.isTrue(observed > 0, "committed cave steps evaluate encounters")
      facts = settled
    end, debug.traceback)
    pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    if not bound then
      error(boundFailure, 0)
    end
    Assert.equal(facts.method, "grass", "the cave walk selects the grass method")
    Assert.isTrue(type(facts.species) == "string" and facts.species ~= "", "the cave bout names its species")
    local before = playerCell(game)
    game:face("north")
    pump(game, envelope, 10)
    Assert.isNil(runtime.battleCoordinator:activeBattle(), "turning after the cave return launches nothing")
    Assert.equal(game:renderAttempts(), 0, "the cave walk stops before GPU rendering")
    Assert.isTrue(
      playerCell(game).fieldX == before.fieldX and playerCell(game).fieldZ == before.fieldZ,
      "turning never steps"
    )
  end, debug.traceback)
  game:close()
  if not ok then
    error(failure, 0)
  end
  Assert.notNil(facts, "the cave walk reports its stage facts")
end

return T
