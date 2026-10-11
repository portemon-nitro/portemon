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
  local size = options.size or 64
  local probes = options.probeCounter
  local runtime = {
    scene = { type = "indoor" },
    coordinateOrigin = { x = 0, z = 0 },
    terrainDependencyHash = "survey-test-terrain",
    fieldRegion = { cells = { { collision = { width = size, height = size } } } },
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
    return localX >= 0 and localX < size and localZ >= 0 and localZ < size
  end
  local baseGetLocal = function(localX, localZ)
    local blocked = options.allBlocked == true
    if options.validTiles ~= nil then
      blocked = options.validTiles[localX .. ":" .. localZ] ~= true
    end
    return { blocked = blocked, behavior = 0 }
  end
  function runtime.collision:getLocal(localX, localZ)
    if probes ~= nil then
      probes.n = probes.n + 1
    end
    return baseGetLocal(localX, localZ)
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
    cacheFs = {
      loadLua = function()
        return nil
      end,
    },
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

function T.tests.map_owned_seed_arrives_before_the_first_safe_tile()
  local validTiles = {
    ["31:31"] = true,
    ["32:31"] = true,
    ["31:32"] = true,
    ["32:32"] = true,
  }
  local service = makeService({ validTiles = validTiles })
  local ok, err = xpcall(function()
    service:openMap(11, { purpose = "browse" })
    local requestGeneration = assert(service:snapshot().initialCursor).generation
    service:setViewport(32, 32, 1, 1)
    local seed, ready, updates = nil, nil, 0
    local view = service:snapshot()
    while view.status.state == "pending" and updates < 100 do
      service:update()
      updates = updates + 1
      view = service:snapshot()
      if seed == nil and view.initialCursor ~= nil and view.initialCursor.state == "seeded" then
        seed = view.initialCursor
      end
      if view.initialCursor ~= nil and view.initialCursor.state == "ready" then
        ready = view.initialCursor
      end
    end
    Assert.equal(view.status.state, "ready", "the selected map's ordinary preparation completes")
    Assert.notNil(seed, "browsing publishes its map-owned seed before the safe-tile search completes")
    Assert.isTrue(
      seed.fieldX >= 0 and seed.fieldX < 64 and seed.fieldZ >= 0 and seed.fieldZ < 64,
      "the seed lies inside the real indoor collision rectangle"
    )
    Assert.notNil(ready, "the bounded search publishes its first safe tile")
    Assert.isTrue(
      validTiles[ready.fieldX .. ":" .. ready.fieldZ] == true,
      "the suggestion is a tile that passes placement policy"
    )
    Assert.equal(ready.mapId, 11, "the suggestion is bound to its selected logical map")
    Assert.equal(ready.generation, requestGeneration, "the suggestion is bound to its browse request")
    Assert.equal(service:tileStatus(ready.fieldX, ready.fieldZ).selectable, true, "the suggested tile is selectable")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.blocked_pending_and_failed_maps_keep_honest_cursors()
  local blockedService = makeService({ allBlocked = true })
  local pendingService = makeService({ assetsPending = true })
  local failureService = makeService({ assetError = Errors.new("MAP_ASSET_FAILED", "survey fixture failure") })
  local ok, err = xpcall(function()
    local blocked = browse(blockedService)
    local miss = blocked.initialCursor
    Assert.notNil(miss, "an all-blocked map publishes an explicit finite miss")
    Assert.equal(miss.state, "unavailable", "an exhausted local search is a normal preview outcome")
    Assert.equal(miss.reason, "no_nearby_safe_tile", "the miss names its bound instead of the whole map")
    Assert.isTrue(
      miss.fieldX ~= nil
        and miss.fieldX >= 0
        and miss.fieldX < 64
        and miss.fieldZ ~= nil
        and miss.fieldZ >= 0
        and miss.fieldZ < 64,
      "an unavailable hint retains its map-owned seed for manual browsing"
    )

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
    Assert.notNil(failed.initialCursor, "failed browse preparation publishes a terminal cursor")
    Assert.equal(failed.initialCursor.state, "failed", "failed preparation remains terminal")
    Assert.equal(failed.initialCursor.mapId, failed.mapId, "the failed cursor belongs to the selected map")
    Assert.equal(
      failed.initialCursor.generation,
      failureService.requestGeneration,
      "the failed cursor belongs to the request generation"
    )
  end, debug.traceback)
  blockedService:dispose()
  pendingService:dispose()
  failureService:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.local_safe_hint_is_bounded_cancelable_and_reports_a_finite_miss()
  local service = makeService({})
  Assert.equal(
    type(service.cancelInitialSuggestion),
    "function",
    "the optional safe-tile hint is canceled through its own owner without disturbing the viewport"
  )
  local probes = { n = 0 }
  local hinted = makeService({ probeCounter = probes })
  local ok, err = xpcall(function()
    hinted:openMap(11, { purpose = "browse" })
    local seed, updates = nil, 0
    while updates < 30 do
      hinted:update()
      updates = updates + 1
      local cursor = hinted:snapshot().initialCursor
      if cursor ~= nil and cursor.state == "seeded" then
        seed = cursor
        break
      end
    end
    Assert.notNil(seed, "the browser publishes its map-owned seed before the safe-tile search completes")
    Assert.isTrue(
      seed.fieldX >= 0 and seed.fieldX < 64 and seed.fieldZ >= 0 and seed.fieldZ < 64,
      "the seed lies inside the real indoor collision rectangle"
    )
    hinted:cancelInitialSuggestion()
    Assert.equal(hinted:snapshot().initialCursor.state, "canceled", "canceling retires the pending hint")
    for _ = 1, 10 do
      hinted:update()
    end
    Assert.equal(
      hinted:snapshot().initialCursor.state,
      "canceled",
      "a canceled hint never snaps back to a late suggestion"
    )
  end, debug.traceback)
  hinted:dispose()
  service:dispose()
  if not ok then
    error(err, 0)
  end

  local missProbes = { n = 0 }
  local blocked = makeService({ allBlocked = true, size = 96, probeCounter = missProbes })
  local missOk, missErr = xpcall(function()
    blocked:openMap(11, { purpose = "browse" })
    local miss, updates = nil, 0
    while updates < 2000 do
      blocked:update()
      updates = updates + 1
      local cursor = blocked:snapshot().initialCursor
      if cursor ~= nil and (cursor.state == "unavailable" or cursor.state == "ready") then
        miss = cursor
        break
      end
    end
    Assert.notNil(miss, "a fully blocked map finishes its finite local search")
    Assert.equal(miss.state, "unavailable", "an exhausted local search reports its miss")
    Assert.equal(
      miss.reason,
      "no_nearby_safe_tile",
      "a finite local miss names its bound instead of claiming the whole map"
    )
    Assert.notNil(miss.fieldX, "an unavailable hint retains its map-owned seed for manual browsing")
    Assert.notNil(miss.fieldZ, "an unavailable hint retains its map-owned seed for manual browsing")
    Assert.isTrue(
      missProbes.n <= 4096,
      "the bounded search inspects at most 4096 tile positions before reporting its miss"
    )
  end, debug.traceback)
  blocked:dispose()
  if not missOk then
    error(missErr, 0)
  end
end

return T
