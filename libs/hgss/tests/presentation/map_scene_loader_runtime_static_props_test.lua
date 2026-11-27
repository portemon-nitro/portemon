-- Runtime static-prop replacement resolves the requested owner's model record:
-- two generic owners with different descriptors replace independently, and an
-- unknown owner fails instead of falling back to another group's model.

local Assert = require("tests.support.Assert")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.hgss.src.presentation.MapSceneLoader")
local ScenePreparationFixture = require("tests.support.ScenePreparationFixture")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")

local T = {}

local function quad()
  local function v(x, z)
    return {
      x = x,
      y = 0,
      z = z,
      u = 0,
      v = 0,
      nx = 0,
      ny = 1,
      nz = 0,
      r = 255,
      g = 255,
      b = 255,
      a = 255,
      colorSource = 0,
    }
  end
  return { vertices = { v(0, 0), v(1, 0), v(1, 1), v(0, 1) }, indices = { 0, 1, 2, 0, 2, 3 } }
end

local function staticDescriptor(key, batchCount, geometryPrefix)
  local batches = {}
  for index = 1, batchCount do
    batches[index] = {
      geometry = "assets/generated/maps/geometry/" .. geometryPrefix .. index .. ".g4mesh",
      polygonAlpha = 31,
      alphaClass = "opaque",
    }
  end
  return {
    schema = ModelAsset.SCHEMA,
    key = key,
    memberId = 1,
    kind = "static",
    batches = batches,
    materials = {},
  }
end

local function placement(x, z)
  return { transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, 0, z, 1 } }
end

local function fakeMeshBuilder(_)
  return { release = function() end }
end

local function loadRuntime(descriptors, runtimeProps)
  local backend = FakeCache.new()
  local dir = MapAssetCache.mapDir(61)
  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    mapId = 61,
    mapBatches = {},
    materials = {},
    buildingInstances = {},
    neighbors = {},
    terrainAnimations = { textureSrt = false },
    matrix = { width = 1, height = 1, x = 0, z = 0, worldOriginX = 0, worldOriginZ = 0 },
    collision = { width = 32, height = 32, file = MapAssetCache.collisionPath(61) },
    lighting = {},
    edgeColors = {},
    fog = (function()
      local table32 = {}
      for i = 1, 32 do
        table32[i] = 0
      end
      return { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = table32 }
    end)(),
    runtimeProps = runtimeProps,
  }
  backend:write(dir .. "/scene.lua", LuaWriter.encode(scene))
  local cells = {}
  for index = 1, 32 * 32 do
    cells[index] = { behavior = 0, terrainResponseId = 0, blocked = false }
  end
  backend:write(MapAssetCache.collisionPath(61), CollisionGridAsset.encode({ width = 32, height = 32, cells = cells }))
  for _, desc in ipairs(descriptors) do
    backend:write(MapAssetCache.modelPath(desc.key), LuaWriter.encode(desc))
    for _, batch in ipairs(desc.batches) do
      backend:write(batch.geometry, MeshWriter.encode(quad()))
    end
  end
  local references = {}
  local cache = {
    read = function(_, path)
      return backend:read(path)
    end,
    loadLua = function(_, path)
      local data = assert(backend:read(path), "missing cache file " .. path)
      local chunk = assert(loadstring(data, path))
      setfenv(chunk, {})
      local ok, result = pcall(chunk)
      assert(ok, result)
      return result
    end,
    -- Presented collision borrows the resident compact bytes instead of a
    -- string copy, so the reader lends one immutable reference per payload.
    resolveAsset = function(_, path)
      local payload = backend:read(path)
      if type(payload) ~= "string" then
        return nil
      end
      local reference = references[path]
      if reference == nil then
        reference = {
          path = path,
          sourceId = "base:map-scene-static-props-test",
          contentId = "map-scene-static-props-test\0" .. path,
          size = #payload,
          data = assert(love.data.newByteData(payload)),
        }
        references[path] = reference
      end
      return reference
    end,
    acquireSource = function(reference)
      local lease = { value = assert(reference).data }
      function lease:release()
        self.value = nil
      end
      return lease
    end,
  }
  ---@cast cache CacheFs
  -- The staged build borrows the selected CPU pair: the fixture worker realizes
  -- the same packed upload shape the real worker publishes for these bytes.
  local assetPreparation, decoded = ScenePreparationFixture.new(cache)
  return MapSceneLoader.load(cache, scene, {
    meshBuilder = fakeMeshBuilder,
    acquireSource = cache.acquireSource,
    assetPreparation = assetPreparation,
    decoded = decoded,
  })
end

function T.replacement_resolves_each_owner_model_and_leaves_other_owners_untouched()
  local descA = staticDescriptor("indoor:1:propA", 1, "propA-")
  local descB = staticDescriptor("indoor:2:propB", 2, "propB-")
  local runtime = loadRuntime({ descA, descB }, {
    fountain_coin = { model = descA.key, placements = {} },
    harbor_lantern = { model = descB.key, placements = {} },
  })

  runtime:replaceRuntimeStaticProps("fountain_coin", { placement(1, 1) })
  Assert.equal(#runtime.runtimePropDrawsByOwner.fountain_coin, 1, "one batch per placement of the first model")

  runtime:replaceRuntimeStaticProps("harbor_lantern", { placement(7, 8) })
  local lanternDraws = runtime.runtimePropDrawsByOwner.harbor_lantern
  Assert.equal(#lanternDraws, 2, "two batches per placement of the second model")
  for _, draw in ipairs(lanternDraws) do
    Assert.equal(draw.transform[13], 7)
    Assert.equal(draw.transform[15], 8)
  end

  local coinDraws = runtime.runtimePropDrawsByOwner.fountain_coin
  Assert.equal(#coinDraws, 1, "replacing one owner leaves the other owner's draws untouched")
  Assert.equal(coinDraws[1].transform[13], 1)
  Assert.equal(#runtime.runtimePropDraws, 3)
  runtime:release()
end

function T.empty_selection_clears_only_the_named_owner()
  local descA = staticDescriptor("indoor:1:propA", 1, "propA-")
  local descB = staticDescriptor("indoor:2:propB", 1, "propB-")
  local runtime = loadRuntime({ descA, descB }, {
    fountain_coin = { model = descA.key, placements = {} },
    harbor_lantern = { model = descB.key, placements = {} },
  })

  runtime:replaceRuntimeStaticProps("fountain_coin", { placement(1, 1) })
  runtime:replaceRuntimeStaticProps("harbor_lantern", { placement(2, 2) })
  Assert.equal(#runtime.runtimePropDraws, 2)
  runtime:replaceRuntimeStaticProps("fountain_coin", {})
  Assert.equal(#runtime.runtimePropDrawsByOwner.fountain_coin, 0)
  Assert.equal(#runtime.runtimePropDrawsByOwner.harbor_lantern, 1)
  Assert.equal(#runtime.runtimePropDraws, 1)
  runtime:release()
end

function T.unknown_owner_fails_without_touching_existing_draws()
  local descA = staticDescriptor("indoor:1:propA", 1, "propA-")
  local runtime = loadRuntime({ descA }, {
    fountain_coin = { model = descA.key, placements = {} },
  })
  runtime:replaceRuntimeStaticProps("fountain_coin", { placement(1, 1) })
  local err = Assert.throws(function()
    runtime:replaceRuntimeStaticProps("harbor_lantern", { placement(2, 2) })
  end)
  Assert.isTrue(tostring(err):find("harbor_lantern", 1, true) ~= nil, "the failure names the unknown owner")
  Assert.equal(#runtime.runtimePropDrawsByOwner.fountain_coin, 1, "the failed replacement keeps prior draws")
  runtime:release()
end

-- A stub graphics namespace for the pool's mesh seam: each created mesh
-- records its own release, so the suite can prove shared ownership without
-- a real GPU context.
local function stubGraphics(failNewMesh)
  return {
    newImage = function()
      error("this scene uses no textures", 0)
    end,
    newMesh = function(_, vertexCount, _, _)
      if failNewMesh then
        error("injected mesh upload failure", 0)
      end
      local mesh = { vertexCount = vertexCount, released = false, releaseCount = 0 }
      function mesh:setVertices() end
      function mesh:setVertexMap() end
      function mesh:release()
        self.released = true
        self.releaseCount = self.releaseCount + 1
      end
      return mesh
    end,
  }
end

-- A minimal cache facade serving model descriptors, packed geometry, and
-- resident collision bytes for physical-cell builds.
local function cellCache(backend)
  local references = {}
  return {
    read = function(_, path)
      return backend:read(path)
    end,
    loadLua = function(_, path)
      local data = assert(backend:read(path), "missing cache file " .. path)
      local chunk = assert(loadstring(data, path))
      setfenv(chunk, {})
      local ok, result = pcall(chunk)
      assert(ok, result)
      return result
    end,
    resolveAsset = function(_, path)
      local payload = backend:read(path)
      if type(payload) ~= "string" then
        return nil
      end
      local reference = references[path]
      if reference == nil then
        reference = {
          path = path,
          sourceId = "base:cell-mesh-sharing-test",
          contentId = "cell-mesh-sharing-test\0" .. path,
          size = #payload,
          data = assert(love.data.newByteData(payload)),
        }
        references[path] = reference
      end
      return reference
    end,
    acquireSource = function(reference)
      local lease = { value = assert(reference).data }
      function lease:release()
        self.value = nil
      end
      return lease
    end,
  }
end

local function writeCellFixtures(backend, descriptors, collisionPaths)
  for _, desc in ipairs(descriptors) do
    backend:write(MapAssetCache.modelPath(desc.key), LuaWriter.encode(desc))
    for _, batch in ipairs(desc.batches) do
      backend:write(batch.geometry, MeshWriter.encode(quad()))
    end
  end
  local cells = {}
  for index = 1, 32 * 32 do
    cells[index] = { behavior = 0, terrainResponseId = 0, blocked = false }
  end
  for _, path in ipairs(collisionPaths) do
    backend:write(path, CollisionGridAsset.encode({ width = 32, height = 32, cells = cells }))
  end
end

local function physicalCell(modelKeys, collisionPath)
  local instances = {}
  for index, modelKey in ipairs(modelKeys) do
    instances[index] =
      { placementIndex = index - 1, modelKey = modelKey, transform = placement(index, index).transform }
  end
  return {
    mapHeaderId = 61,
    batches = {},
    materials = {},
    buildingInstances = instances,
    terrainAnimations = { textureSrt = false },
    collision = { file = collisionPath },
  }
end

-- Two live physical cells covering equal geometry resolve one shared mesh:
-- a distinct key keeps its own mesh, releasing one cell keeps the survivor
-- usable, only the final release frees the mesh exactly once, and a failed
-- sibling acquisition leaves the survivor untouched.
function T.two_physical_cells_share_one_live_mesh_until_the_last_owner_releases()
  local sharedKey = "shared:prop"
  local otherKey = "other:prop"
  local failingKey = "failing:prop"
  local descriptors = {
    staticDescriptor(sharedKey, 1, "shared-"),
    staticDescriptor(otherKey, 1, "other-"),
    staticDescriptor(failingKey, 1, "failing-"),
  }
  local backend = FakeCache.new()
  writeCellFixtures(backend, descriptors, {
    "test/cell-a.g4collision",
    "test/cell-b.g4collision",
    "test/cell-c.g4collision",
    "test/cell-d.g4collision",
  })
  local cache = cellCache(backend)
  local assetPreparation, decoded = ScenePreparationFixture.new(cache)
  local group = {}
  local function cellOptions(graphics)
    return {
      graphics = graphics,
      assetPreparation = assetPreparation,
      decoded = decoded,
      acquireSource = cache.acquireSource,
      meshGroup = group,
    }
  end
  local runtimeA = MapSceneLoader.loadCell(
    cache,
    physicalCell({ sharedKey }, "test/cell-a.g4collision"),
    cellOptions(stubGraphics(false))
  )
  local runtimeB = MapSceneLoader.loadCell(
    cache,
    physicalCell({ sharedKey }, "test/cell-b.g4collision"),
    cellOptions(stubGraphics(false))
  )
  local runtimeC = MapSceneLoader.loadCell(
    cache,
    physicalCell({ otherKey }, "test/cell-c.g4collision"),
    cellOptions(stubGraphics(false))
  )

  local meshA = runtimeA.staticBuildingDraws[1].mesh
  local meshB = runtimeB.staticBuildingDraws[1].mesh
  Assert.isTrue(meshA == meshB, "cells covering equal geometry resolve one live mesh")
  local meshC = runtimeC.staticBuildingDraws[1].mesh
  Assert.isTrue(meshC ~= meshA, "a distinct effective key keeps its own mesh")

  runtimeA:release()
  Assert.isFalse(meshB.released, "releasing one cell keeps the shared mesh alive for its sibling")

  local failed = Assert.throws(function()
    MapSceneLoader.loadCell(
      cache,
      physicalCell({ sharedKey, failingKey }, "test/cell-d.g4collision"),
      cellOptions(stubGraphics(true))
    )
  end)
  Assert.isTrue(
    tostring(failed):find("injected mesh upload failure", 1, true) ~= nil,
    "the failed acquisition reports its own upload failure"
  )
  Assert.isFalse(meshB.released, "a failed sibling acquisition keeps the survivor alive")

  runtimeB:release()
  Assert.isTrue(meshB.released, "the final owner releases the shared mesh")
  Assert.equal(meshB.releaseCount, 1, "the shared mesh is released exactly once")
  runtimeC:release()
end

-- Mesh groups are scoped to one live coverage: equal geometry under different
-- groups resolves to distinct Mesh objects, and releasing one coverage never
-- frees the other's mesh. The emptied group retains no idle entry.
function T.mesh_groups_are_scoped_to_one_coverage()
  local sharedKey = "shared:prop"
  local descriptors = { staticDescriptor(sharedKey, 1, "shared-") }
  local backend = FakeCache.new()
  writeCellFixtures(backend, descriptors, {
    "test/scope-a.g4collision",
    "test/scope-b.g4collision",
    "test/scope-c.g4collision",
  })
  local cache = cellCache(backend)
  local assetPreparation, decoded = ScenePreparationFixture.new(cache)
  local groupA = {}
  local groupB = {}
  local function cellOptions(group, graphics)
    return {
      graphics = graphics,
      assetPreparation = assetPreparation,
      decoded = decoded,
      acquireSource = cache.acquireSource,
      meshGroup = group,
    }
  end
  local runtimeA1 = MapSceneLoader.loadCell(
    cache,
    physicalCell({ sharedKey }, "test/scope-a.g4collision"),
    cellOptions(groupA, stubGraphics(false))
  )
  local runtimeA2 = MapSceneLoader.loadCell(
    cache,
    physicalCell({ sharedKey }, "test/scope-b.g4collision"),
    cellOptions(groupA, stubGraphics(false))
  )
  local runtimeB = MapSceneLoader.loadCell(
    cache,
    physicalCell({ sharedKey }, "test/scope-c.g4collision"),
    cellOptions(groupB, stubGraphics(false))
  )
  local meshA1 = runtimeA1.staticBuildingDraws[1].mesh
  local meshA2 = runtimeA2.staticBuildingDraws[1].mesh
  local meshB = runtimeB.staticBuildingDraws[1].mesh
  Assert.isTrue(meshA1 == meshA2, "cells in one coverage share one live mesh")
  Assert.isTrue(meshB ~= meshA1, "a separate coverage keeps its own mesh")
  runtimeA1:release()
  Assert.isFalse(meshA2.released, "releasing one owner keeps the coverage survivor alive")
  Assert.isFalse(meshB.released, "releasing one coverage never frees another coverage mesh")
  runtimeA2:release()
  Assert.isTrue(meshA1.released, "the final owner of the coverage releases its mesh")
  Assert.equal(meshA1.releaseCount, 1, "a coverage mesh is released exactly once")
  Assert.isFalse(meshB.released, "the other coverage survivor stays usable")
  Assert.isTrue(next(groupA.entries) == nil, "the emptied group retains no idle entry")
  runtimeB:release()
  Assert.isTrue(meshB.released, "the separate coverage releases its own mesh")
end

-- Sharing preserves per-scene statistics and exactly-once release: each pool
-- counts its own unique mesh, and a repeated release never frees twice.
function T.shared_mesh_counts_locally_and_releases_idempotently()
  local sharedKey = "shared:prop"
  local descriptors = { staticDescriptor(sharedKey, 1, "shared-") }
  local backend = FakeCache.new()
  writeCellFixtures(backend, descriptors, {
    "test/stats-a.g4collision",
    "test/stats-b.g4collision",
  })
  local cache = cellCache(backend)
  local assetPreparation, decoded = ScenePreparationFixture.new(cache)
  local group = {}
  local function cellOptions(graphics)
    return {
      graphics = graphics,
      assetPreparation = assetPreparation,
      decoded = decoded,
      acquireSource = cache.acquireSource,
      meshGroup = group,
    }
  end
  local runtimeA = MapSceneLoader.loadCell(
    cache,
    physicalCell({ sharedKey }, "test/stats-a.g4collision"),
    cellOptions(stubGraphics(false))
  )
  local runtimeB = MapSceneLoader.loadCell(
    cache,
    physicalCell({ sharedKey }, "test/stats-b.g4collision"),
    cellOptions(stubGraphics(false))
  )
  Assert.equal(runtimeA.stats.meshCount, 1, "a borrowing cell counts its own unique mesh")
  Assert.equal(runtimeB.stats.meshCount, 1, "the sibling counts its own unique mesh")
  Assert.isTrue(runtimeA.stats.triangleCount > 0, "shared triangles count locally")
  Assert.equal(
    runtimeA.stats.triangleCount,
    runtimeB.stats.triangleCount,
    "siblings report the same shared triangle count"
  )
  local mesh = runtimeA.staticBuildingDraws[1].mesh
  runtimeA:release()
  runtimeB:release()
  Assert.equal(mesh.releaseCount, 1, "the shared mesh is released exactly once")
  runtimeB:release()
  Assert.equal(mesh.releaseCount, 1, "a repeated release never frees twice")
end

return { tests = T }
