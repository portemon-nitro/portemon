-- Save Editor map surveys summarize valid tiles without changing placement policy.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Service = require("app.src.saveeditor.SaveEditorLocationService")

local T = { tests = {} }

local function world()
  local map = {
    id = 11,
    symbol = "MAP_SURVEY",
    mapSection = "SURVEY",
    mapSectionNativeId = 1,
    followMode = "ALLOW",
    worldOriginX = 0,
    worldOriginZ = 0,
    matrix = { memberId = 0 },
  }
  return {
    schema = MapAssetCache.WORLD_SCHEMA,
    maps = { map },
    byId = { [11] = 1 },
    bySymbol = { MAP_SURVEY = 11 },
    analysis = { mapHeaderCount = 1, excluded = {} },
  }
end

local function makeService(options)
  local runtime = {
    scene = { type = "indoor" },
    coordinateOrigin = { x = 0, z = 0 },
    terrainDependencyHash = "survey-test-terrain",
    fieldRegion = { cells = { { collision = { width = 64, height = 64 } } } },
    fieldData = { events = options.events or { objects = {}, warps = {}, coordinates = {} } },
    collision = {},
    terrain = {
      candidatesAt = function()
        return { { id = 1 } }
      end,
      sampleHeight = function()
        return 0
      end,
      sample = function()
        return { surfaceId = 3, worldY = 0 }
      end,
    },
  }
  function runtime.collision:containsLocal(localX, localZ)
    return localX >= 0 and localX < 64 and localZ >= 0 and localZ < 64
  end
  function runtime.collision:getLocal(localX, localZ)
    local blocked = options.allBlocked == true
    if options.validTiles ~= nil then
      blocked = options.validTiles[localX .. ":" .. localZ] ~= true
    end
    return { blocked = blocked, behavior = 0 }
  end

  local loader = {}
  function loader:requestMapAssets()
    if options.assetError then
      return false, options.assetError
    end
    return not options.assetsPending
  end
  function loader:requestLocation()
    return true
  end
  function loader:beginLoad(mapId)
    local task = {}
    function task:advance()
      return 0
    end
    function task:isReady()
      return true
    end
    function task:takeResult()
      runtime.mapId = mapId
      return runtime
    end
    function task:release() end
    return task
  end
  function loader:protectMap() end
  function loader:definesMap(mapId)
    return mapId == 11
  end
  function loader:release() end

  local service = Service.new({
    cacheFs = { loadLua = function() return nil end },
    world = world(),
    derivedAssets = {},
    savedObjects = { actors = {} },
  })
  service.loader = loader
  return service
end

local function browse(service)
  service:openMap(11, { purpose = "browse" })
  local requestGeneration = assert(service:snapshot().initialCursor).generation
  service:setViewport(32, 32, 1, 1)
  local view = service:snapshot()
  local updates = 0
  while view.status.state == "pending" do
    updates = updates + 1
    Assert.isTrue(updates <= 100, "survey work reaches a semantic completion state")
    service:update()
    view = service:snapshot()
  end
  Assert.equal(view.status.state, "ready", "the selected map's ordinary preparation completes")
  return view, requestGeneration
end

function T.tests.valid_tile_survey_uses_the_exact_map_centroid_and_coordinate_tie_break()
  local validTiles = {
    ["31:31"] = true,
    ["32:31"] = true,
    ["31:32"] = true,
    ["32:32"] = true,
  }
  local service = makeService({ validTiles = validTiles })
  local ok, err = xpcall(function()
    local view, requestGeneration = browse(service)
    local suggestion = view.initialCursor
    Assert.notNil(suggestion, "a fresh map browse publishes its completed valid-tile survey")
    Assert.equal(suggestion.state, "ready", "the sparse selected-map domain has a valid initial cursor")
    Assert.equal(suggestion.validTileCount, 4, "every selectable tile contributes once")
    Assert.equal(suggestion.fieldX, 31, "centroid ties choose the lower fieldX after fieldZ")
    Assert.equal(suggestion.fieldZ, 31, "the nearest valid tile is selected without rounding the centroid")
    Assert.equal(suggestion.mapId, 11, "the survey is bound to its selected logical map")
    Assert.equal(suggestion.generation, requestGeneration, "the survey is bound to its browse request")
    Assert.equal(service:tileStatus(31, 31).selectable, true, "the selected suggestion uses ordinary placement facts")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.blocked_pending_and_failed_maps_never_receive_a_guessed_cursor()
  local blockedService = makeService({ allBlocked = true })
  local pendingService = makeService({ assetsPending = true })
  local failureService = makeService({ assetError = Errors.new("MAP_ASSET_FAILED", "survey fixture failure") })
  local ok, err = xpcall(function()
    local blocked = browse(blockedService)
    local unavailable = blocked.initialCursor
    Assert.notNil(unavailable, "an all-blocked survey publishes an explicit unavailable result")
    Assert.equal(unavailable.state, "unavailable", "zero valid tiles is a normal survey outcome")
    Assert.equal(unavailable.validTileCount, 0, "blocked tiles do not count as valid destinations")
    Assert.isNil(unavailable.fieldX, "an unavailable result has no guessed coordinate")
    Assert.isNil(unavailable.fieldZ, "an unavailable result has no guessed coordinate")
    Assert.isTrue(type(unavailable.reason) == "string" and unavailable.reason ~= "", "unavailable names its reason")

    pendingService:openMap(11, { purpose = "browse" })
    pendingService:setViewport(32, 32, 1, 1)
    pendingService:update()
    local pending = pendingService:snapshot()
    Assert.equal(pending.status.state, "pending", "pending assets pause classification")
    Assert.notNil(pending.initialCursor, "pending browse work remains explicitly observable")
    Assert.equal(pending.initialCursor.state, "pending", "pending tiles are not reported as blocked or valid")

    failureService:openMap(11, { purpose = "browse" })
    failureService:setViewport(32, 32, 1, 1)
    failureService:update()
    local failed = failureService:snapshot()
    Assert.equal(failed.status.state, "failed", "required asset failures retain the existing service failure")
    Assert.notNil(failed.status.reason, "the asset failure reason remains available to the caller")
    Assert.isNil(failed.initialCursor, "failed preparation publishes no usable suggestion")
  end, debug.traceback)
  blockedService:dispose()
  pendingService:dispose()
  failureService:dispose()
  if not ok then
    error(err, 0)
  end
end

return T
