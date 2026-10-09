-- Prepared New Game field-entry ownership tests. While the Oak intro plays,
-- the actual opening map is staged through the authoritative map loader and
-- retained without starting field simulation; at the handoff the transfer
-- moves the identical loader and queue into the field runtime exactly once.

local Assert = require("tests.support.Assert")
local CollisionFixture = require("tests.support.CollisionFixture")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local PreparedFieldEntry = require("game.hgss.src.field.PreparedFieldEntry")

local T = {}

local BEDROOM_SYMBOL = "MAP_NEW_BARK_PLAYER_HOUSE_2F"
local BEDROOM_ID = 5
local OPENING = { mapSymbol = BEDROOM_SYMBOL, fieldX = 6, fieldZ = 6, facing = "south" }

-- The synthesized bedroom record carries the current field-map schema with a
-- minimal valid render environment: the loader validates generated field
-- records before staging, so a stale or environment-less record never
-- reaches the scene build.
local function bedroomField(mapId, symbol)
  local density = {}
  for i = 1, 32 do
    density[i] = 0
  end
  return {
    schema = FieldMapDataCache.FIELD_SCHEMA,
    initScripts = {},
    mapId = mapId,
    mapSymbol = symbol,
    cameraType = 3,
    transitionEnvironment = "building",
    fieldUse = {
      flyAllowed = false,
      teleportAllowed = false,
      escapeAllowed = false,
      flashUsable = false,
      alphChamber = false,
      icePathB2F = false,
      cave = false,
      unionOrColosseum = false,
    },
    events = { background = {}, objects = {}, warps = {}, coordinates = {} },
    music = { day = "SEQ_X", night = "SEQ_X", flagOverrides = {}, traversalOverrides = {} },
    soundplates = {},
    renderEnvironment = {
      lighting = { records = { { endHalfSeconds = 0 } } },
      edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
      weatherId = 0,
      fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = density },
    },
  }
end

local function bedroomFixture()
  local files = {}
  local world = {
    schema = MapAssetCache.WORLD_SCHEMA,
    maps = {},
    byId = {},
    bySymbol = {},
    analysis = { mapHeaderCount = 1, excluded = {} },
  }
  local symbol = BEDROOM_SYMBOL
  local mapId = BEDROOM_ID
  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    mapId = mapId,
    mapSymbol = symbol,
    cameraType = 3,
    neighbors = {},
    buildingInstances = {},
    terrainAnimations = { textureSrt = false },
    collision = { file = string.format("data/generated/maps/%04d/collision.g4collision", mapId) },
    matrix = { width = 1, height = 1, x = 0, z = 0, worldOriginX = 96, worldOriginZ = 192 },
  }
  files[string.format("data/generated/maps/%04d/scene.lua", mapId)] = scene
  files[string.format("data/generated/maps/%04d/terrain.lua", mapId)] = {
    schema = "g4-terrain-surfaces-v1",
    source = { bdhcSha1 = "central-bedroom" },
    plates = {},
  }
  files[scene.collision.file] = CollisionFixture.asset(32, 32)
  files[string.format("data/generated/field/maps/%04d/field.lua", mapId)] = bedroomField(mapId, symbol)
  world.maps[1] = {
    id = mapId,
    symbol = symbol,
    mapSection = "NEW_BARK_TOWN",
    mapSectionNativeId = 126,
    followMode = "ALLOW",
    worldOriginX = 96,
    worldOriginZ = 192,
    cameraType = 3,
  }
  world.byId[mapId] = 1
  world.bySymbol[symbol] = mapId
  world.maps[1].matrix = { memberId = 0 }
  files[MapAssetCache.worldPath()] = world
  files[require("libs.assets.src.field.FieldCellCache").indexPath()] =
    { schema = require("libs.assets.src.field.FieldCellCache").INDEX_SCHEMA, matrices = {} }
  local cache = {
    loadLua = function(_, path)
      return files[path]
    end,
    read = function(_, path)
      return files[path]
    end,
  }
  return cache
end

-- Scripted derived-asset host: plain function fields following the loader
-- convention (dot calls, no receiver). Each demand answers ready, pending,
-- or failed according to the script.
local function derivedHost(script)
  script = script or {}
  local calls = {}
  local host = {}
  local function answer(kind, id, urgency)
    calls[#calls + 1] = { kind = kind, id = id, urgency = urgency }
    local verdict = script[kind]
    if verdict == nil then
      return true
    end
    if verdict == "pending" then
      return false
    end
    return false, verdict
  end
  function host.requestField(id, urgency)
    return answer("field", id, urgency)
  end
  function host.requestLogicalField(id, urgency)
    return answer("logical", id, urgency)
  end
  function host.ensureField(_)
    return true
  end
  function host.ensureLogicalField(_)
    return true
  end
  function host.requestCell(descriptor, urgency)
    return answer("cell", descriptor, urgency)
  end
  host.calls = calls
  return host
end

-- Controllable staged scene build. Pending until the test marks it ready;
-- the scene runtime release is recorded on the shared order log.
local function stagedSceneLoader(log)
  local builds = {}
  local loader = {}
  function loader.begin(_, scene, _)
    local build = { scene = scene, advances = 0, released = false, taken = false, ready = false }
    builds[#builds + 1] = build
    local task = {}
    function task:advance(workUnits)
      build.advances = build.advances + (workUnits or 0)
      return 0
    end
    function task:isReady()
      return build.ready
    end
    function task:takeResult()
      assert(build.ready, "staged scene result is not ready")
      build.taken = true
      return {
        scene = scene,
        release = function()
          build.released = true
          log[#log + 1] = "scene"
        end,
      }
    end
    function task:finish()
      build.ready = true
      return task:takeResult()
    end
    function task:release()
      build.released = true
    end
    build.task = task
    build.makeReady = function()
      build.ready = true
    end
    return task
  end
  return loader, builds
end

local function fakeQueue(log)
  local queue = { releases = 0 }
  function queue:release()
    self.releases = self.releases + 1
    log[#log + 1] = "queue"
  end
  return queue
end

local function stagedEntry(log, hostScript)
  local sceneLoader, builds = stagedSceneLoader(log)
  local host = derivedHost(hostScript)
  local queue = fakeQueue(log)
  local entry = PreparedFieldEntry.new({
    versionId = "heartgold",
    derivedAssets = host,
    location = OPENING,
    cacheFs = bedroomFixture(),
    sceneLoader = sceneLoader,
    assetPreparation = queue,
  })
  return entry, builds, host, queue
end

local function pollUntilReady(entry, builds, limit)
  for _ = 1, (limit or 10) do
    if #builds > 0 then
      builds[1].makeReady()
    end
    local ready, failure = entry:poll()
    Assert.isNil(failure, "preparation must not fail while polling to ready: " .. tostring(failure))
    if ready then
      return true
    end
  end
  return entry:isReady()
end

function T.staging_advances_the_bedroom_and_reports_readiness_once()
  local log = {}
  local entry, builds = stagedEntry(log)
  Assert.isFalse(entry:isReady(), "a fresh entry is not ready")
  local ready, failure = entry:poll()
  Assert.isNil(failure, "the first poll must not fail: " .. tostring(failure))
  Assert.isFalse(ready, "the staged scene stays pending until it completes")
  Assert.equal(#builds, 1, "the first poll starts exactly one staged scene build")
  Assert.isTrue(pollUntilReady(entry, builds), "repeated polls complete the staged bedroom")
  Assert.isTrue(entry:isReady(), "the entry reports ready once")
  local readyAgain, failureAgain = entry:poll()
  Assert.isTrue(readyAgain, "readiness observation is idempotent")
  Assert.isNil(failureAgain)
  Assert.equal(#builds, 1, "ready polls never rebuild the map")
  entry:dispose()
end

function T.derived_location_demand_precedes_the_scene_build()
  local log = {}
  local entry, builds, host = stagedEntry(log, { field = "pending" })
  local ready, failure = entry:poll()
  Assert.isFalse(ready, "a pending derived closure keeps preparation pending")
  Assert.isNil(failure, "pending demand is not a failure")
  Assert.equal(#builds, 0, "no scene build starts before the derived closure is ready")
  local demanded = false
  for _, call in ipairs(host.calls) do
    if call.kind == "field" and call.id == BEDROOM_ID then
      demanded = true
    end
  end
  Assert.isTrue(demanded, "the entry demands the bedroom closure first")
  entry:dispose()
end

function T.derived_failure_is_terminal_and_releases_owned_resources()
  local log = {}
  local entry, builds, _, queue = stagedEntry(log, { field = "bedroom bank missing" })
  local ready, failure = entry:poll()
  Assert.isFalse(ready, "a failed derived closure never reports ready")
  Assert.equal(failure, "bedroom bank missing", "the derived cause surfaces")
  Assert.equal(#builds, 0, "a failed demand starts no scene build")
  local readyAgain, failureAgain = entry:poll()
  Assert.isFalse(readyAgain, "the failure is sticky")
  Assert.equal(failureAgain, "bedroom bank missing", "the same cause surfaces again")
  Assert.equal(queue.releases, 1, "the owned queue is released exactly once")
  entry:dispose()
  Assert.equal(queue.releases, 1, "dispose after failure releases nothing again")
end

function T.take_transfers_the_prepared_loader_and_queue_exactly_once()
  local log = {}
  local entry, builds, _, queue = stagedEntry(log)
  Assert.isTrue(pollUntilReady(entry, builds), "the bedroom must stage to ready")
  local transfer = entry:take()
  Assert.equal(transfer.versionId, "heartgold", "the transfer carries the version identity")
  Assert.equal(transfer.location.mapSymbol, BEDROOM_SYMBOL, "the transfer carries the map identity")
  local claimed = transfer:claim({ versionId = "heartgold", mapSymbol = BEDROOM_SYMBOL })
  Assert.isTrue(claimed.assetPreparation == queue, "the claim moves the identical queue")
  local resident = claimed.mapLoader:get(BEDROOM_ID)
  Assert.notNil(resident, "the claimed loader already holds the staged bedroom")
  Assert.equal(resident.mapSymbol, BEDROOM_SYMBOL, "the resident entry is the staged map")
  local okTake = pcall(function()
    return entry:take()
  end)
  Assert.isFalse(okTake, "a second take is a programmer error")
  local okClaim = pcall(function()
    return transfer:claim({ versionId = "heartgold", mapSymbol = BEDROOM_SYMBOL })
  end)
  Assert.isFalse(okClaim, "a second claim is a programmer error")
  transfer:dispose()
end

function T.claim_rejects_version_and_map_mismatch()
  local log = {}
  local entry, builds = stagedEntry(log)
  Assert.isTrue(pollUntilReady(entry, builds), "the bedroom must stage to ready")
  local transfer = entry:take()
  local okVersion = pcall(function()
    return transfer:claim({ versionId = "soulsilver", mapSymbol = BEDROOM_SYMBOL })
  end)
  Assert.isFalse(okVersion, "a version mismatch is rejected, never rebuilt")
  local okMap = pcall(function()
    return transfer:claim({ versionId = "heartgold", mapSymbol = "MAP_OTHER_PLACE" })
  end)
  Assert.isFalse(okMap, "a map mismatch is rejected, never rebuilt")
  transfer:dispose()
end

function T.dispose_before_take_releases_the_loader_then_the_queue()
  local log = {}
  local entry, builds = stagedEntry(log)
  Assert.isTrue(pollUntilReady(entry, builds), "the bedroom must stage to ready")
  entry:dispose()
  Assert.deepEqual(log, { "scene", "queue" }, "dispose releases the loader before the queue exactly once")
  entry:dispose()
  Assert.deepEqual(log, { "scene", "queue" }, "a repeated dispose releases nothing again")
end

function T.dispose_after_take_releases_no_transferred_resources()
  local log = {}
  local entry, builds, _, queue = stagedEntry(log)
  Assert.isTrue(pollUntilReady(entry, builds), "the bedroom must stage to ready")
  local transfer = entry:take()
  entry:dispose()
  Assert.equal(#log, 0, "disposing after take releases no transferred resources")
  Assert.equal(queue.releases, 0, "the queue stays alive for the runtime claim")
  local claimed = transfer:claim({ versionId = "heartgold", mapSymbol = BEDROOM_SYMBOL })
  Assert.isTrue(claimed.mapLoader:get(BEDROOM_ID) ~= nil, "the transfer survives entry disposal")
  transfer:dispose()
end

return { tests = T }
