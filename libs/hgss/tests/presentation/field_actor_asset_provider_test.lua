-- Lifecycle tests for the runtime actor asset provider, driven against an
-- in-memory cache and a stub graphics namespace so no GPU resource is created.
-- Covers sharing, reference balance, idle eviction, statistics, and the fatal
-- errors a missing or uncompiled sprite must produce.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldActorAssetProvider = require("libs.hgss.src.presentation.FieldActorAssetProvider")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")

local T = {}

-- Records every image it creates so a test can assert on releases.
local function stubGraphics(created, opts)
  opts = opts or {}
  local meshCalls = 0
  return {
    newImage = function()
      local image = { released = false, quads = 0 }
      function image:getWidth()
        return 64
      end
      function image:getHeight()
        return 32
      end
      function image:setFilter(min, mag)
        self.filter = { min, mag }
      end
      function image:release()
        self.released = true
      end
      created[#created + 1] = image
      return image
    end,
    newQuad = function(x, y, w, h)
      return { x = x, y = y, w = w, h = h }
    end,
    newMesh = function(_, vertices)
      meshCalls = meshCalls + 1
      if opts.failOnNewMesh == meshCalls then
        error("injected newMesh failure")
      end
      local mesh = { vertices = vertices, released = false }
      function mesh:setVertexMap(map)
        self.map = map
      end
      function mesh:release()
        self.released = true
      end
      return mesh
    end,
  }
end

local function seed(spriteIds)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    romVersion = "heartgold",
    spriteIds = spriteIds,
    runtime = { avatars = {}, variableSprites = { first = 1, last = 1, variableBase = 0 } },
    variableSprites = {},
    recordCount = #spriteIds,
  })
  for _, spriteId in ipairs(spriteIds) do
    cache:writeLua(FieldActorCache.visualPath(spriteId), FieldActorFixture.visual(spriteId, { frameCount = 8 }))
    cache:write(FieldActorCache.atlasPath(spriteId), "png-bytes")
  end
  return cache
end

local function provider(spriteIds, opts, created)
  opts = opts or {}
  opts.graphics = opts.graphics or stubGraphics(created or {})
  return FieldActorAssetProvider.new(seed(spriteIds), opts)
end

function T.acquire_loads_once_and_shares_the_entry()
  local created = {}
  local p = provider({ 0, 29 }, nil, created)
  local first = p:acquire(0)
  local second = p:acquire(0)
  Assert.isTrue(first == second, "the same entry is shared")
  Assert.equal(#created, 1, "one image per sprite while referenced")
  Assert.equal(p:stats().loads, 1)
  Assert.equal(p:stats().hits, 1)
  Assert.equal(p:stats().references, 2)
end

-- DS textures are point-sampled: nearest atlas sampling must survive into
-- the actual GPU image every actor draws with, never the host's smoothing
-- default.
function T.acquired_atlas_image_is_nearest_filtered()
  local created = {}
  local p = provider({ 0 }, nil, created)
  p:acquire(0)
  Assert.deepEqual(created[1].filter, { "nearest", "nearest" })
end

function T.builds_one_quad_and_one_billboard_mesh_per_frame()
  local p = provider({ 0 })
  local entry = p:acquire(0)
  Assert.equal(#entry.quads, 8)
  Assert.equal(entry.quads[2].x, 32)
  Assert.equal(entry.quads[2].w, 32)
  Assert.equal(#entry.meshes, 8, "one world mesh per atlas frame")
  Assert.isTrue(entry.meshes[2].vertices[2][4] > 0, "frame 2 slides its U range onto the strip")
end

function T.last_release_keeps_the_entry_resident_until_evicted()
  local created = {}
  local p = provider({ 0, 29 }, { idleLimit = 1 }, created)
  p:acquire(0)
  p:release(0)
  Assert.equal(p:stats().live, 1, "an idle entry stays resident under the limit")
  Assert.equal(p:stats().idle, 1)

  p:acquire(29)
  p:release(29)
  Assert.equal(p:stats().evictions, 1)
  Assert.equal(p:stats().live, 1)
  Assert.isTrue(created[1].released, "the evicted entry released its image")
end

function T.reacquiring_an_idle_entry_is_a_hit_and_leaves_the_idle_list()
  local p = provider({ 0 }, { idleLimit = 4 })
  p:acquire(0)
  p:release(0)
  p:acquire(0)
  Assert.equal(p:stats().loads, 1)
  Assert.equal(p:stats().hits, 1)
  Assert.equal(p:stats().idle, 0)
end

function T.resident_does_not_expose_an_idle_entry_as_owned()
  local p = provider({ 0 })
  p:acquire(0)
  p:release(0)
  Assert.isNil(p:resident(0), "an idle cache entry is not presentation residency")
end

function T.dispose_releases_every_image()
  local created = {}
  local p = provider({ 0, 29 }, nil, created)
  p:acquire(0)
  p:acquire(29)
  p:dispose()
  Assert.equal(#created, 2)
  Assert.isTrue(created[1].released and created[2].released, "all images released")
  Assert.equal(p:stats().live, 0)
end

function T.mesh_construction_failure_releases_the_acquired_atlas()
  local created = {}
  local p = FieldActorAssetProvider.new(seed({ 0 }), {
    graphics = stubGraphics(created, { failOnNewMesh = 1 }),
  })
  local err = Assert.throws(function()
    p:acquire(0)
  end)
  Assert.isTrue(tostring(err):find("injected newMesh failure", 1, true) ~= nil)
  Assert.equal(#created, 1)
  Assert.isTrue(created[1].released, "the atlas acquired before mesh construction must be released")
  Assert.equal(p:stats().live, 0)
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(err.code, code)
end

function T.acquires_a_visual_missing_from_the_compiled_index_and_evicts_it_once()
  local created = {}
  local cache = seed({ 0 })
  cache:writeLua(FieldActorCache.visualPath(900), FieldActorFixture.visual(900, { frameCount = 8 }))
  cache:write(FieldActorCache.atlasPath(900), "png-bytes")
  local p = FieldActorAssetProvider.new(cache, { graphics = stubGraphics(created), idleLimit = 1 })
  Assert.isFalse(p:knows(900), "the compiled index still omits the modded sprite")
  local first = p:acquire(900)
  local second = p:acquire(900)
  Assert.isTrue(first == second, "repeated acquires share one entry")
  Assert.equal(#created, 1, "one image per sprite while referenced")
  Assert.equal(p:stats().loads, 1)
  Assert.equal(p:stats().hits, 1)
  p:release(900)
  p:release(900)
  Assert.equal(p:stats().references, 0)
  Assert.equal(p:stats().live, 1, "the idle unindexed entry stays resident under the limit")
  p:acquire(0)
  p:release(0)
  Assert.equal(p:stats().evictions, 1)
  Assert.equal(p:stats().disposals, 1)
  Assert.isTrue(created[1].released, "the evicted unindexed entry released its image exactly once")
end

function T.unindexed_sprite_without_a_cached_visual_fails_without_leaking()
  local created = {}
  local p = provider({ 0 }, nil, created)
  Assert.isFalse(p:knows(900), "the compiled index omits the modded sprite")
  local err = Assert.throws(function()
    p:acquire(900)
  end)
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(err.code, "FIELD_ACTOR_VISUAL_UNAVAILABLE")
  Assert.equal(#created, 0, "no GPU image is created for a missing visual")
  Assert.equal(p:stats().loads, 0)
  Assert.equal(p:stats().live, 0)
  Assert.equal(p:stats().references, 0)
end

function T.knows_still_reports_compiled_index_membership_only()
  local p = provider({ 0 })
  Assert.isTrue(p:knows(0))
  Assert.isFalse(p:knows(1032), "knows is prewarm membership, not resolvability")
end

function T.rejects_unbalanced_release()
  local p = provider({ 0 })
  throwsCode("FIELD_ACTOR_RELEASE_UNKNOWN", function()
    p:release(0)
  end)
  p:acquire(0)
  p:release(0)
  throwsCode("FIELD_ACTOR_RELEASE_UNBALANCED", function()
    p:release(0)
  end)
end

function T.missing_artifacts_are_fatal()
  local cache = seed({ 0 })
  cache:remove(FieldActorCache.atlasPath(0))
  local p = FieldActorAssetProvider.new(cache, { graphics = stubGraphics({}) })
  throwsCode("FIELD_ACTOR_ATLAS_MISSING", function()
    p:acquire(0)
  end)

  local other = seed({ 0 })
  other:remove(FieldActorCache.visualPath(0))
  local q = FieldActorAssetProvider.new(other, { graphics = stubGraphics({}) })
  throwsCode("FIELD_ACTOR_VISUAL_UNAVAILABLE", function()
    q:acquire(0)
  end)
end

function T.rejects_a_cache_without_an_index()
  throwsCode("FIELD_ACTOR_INDEX_UNAVAILABLE", function()
    FieldActorAssetProvider.new(CacheFs.forVersion("heartgold", FakeCache.new()), {})
  end)
end

-- The pooled actor path borrows its atlas from the session image owner: two
-- compiled sprites sharing one generated atlas resolve one physical pair
-- through two independent leases, the provider-side cache is never asked
-- for the atlas bytes, and no private GPU image is constructed.
local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }
local SHARED_TEST_ATLAS = "assets/generated/field/actors/shared-test.png"

local function pooledTestImage(width, height)
  local image = { released = false, releaseCount = 0 }
  function image:getWidth()
    return width
  end
  function image:getHeight()
    return height
  end
  function image:setFilter() end
  function image:setWrap() end
  function image:release()
    self.released = true
    self.releaseCount = self.releaseCount + 1
  end
  return image
end

local function pooledTestGraphics(failOnNewMesh)
  local meshCalls = 0
  return {
    newImage = function()
      error("pooled actor load must not construct a private image", 0)
    end,
    newQuad = function(x, y, w, h)
      return { x = x, y = y, w = w, h = h }
    end,
    newMesh = function(_, vertices)
      meshCalls = meshCalls + 1
      if failOnNewMesh == meshCalls then
        error("injected newMesh failure")
      end
      local mesh = { vertices = vertices, released = false }
      function mesh:setVertexMap(map)
        self.map = map
      end
      function mesh:release()
        self.released = true
      end
      return mesh
    end,
  }
end

-- Two compiled sprites sharing one generated atlas, served by a seeded
-- session pool. Any provider-side read of the atlas bytes fails loudly so
-- the redundant pooled-path read cannot hide behind a passing cache.
---@return CacheFs cache, SharedImagePoolFake pool, table graphics
local function sharedAtlasSetup(spriteIds, failOnNewMesh)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    romVersion = "heartgold",
    spriteIds = spriteIds,
    runtime = { avatars = {}, variableSprites = { first = 1, last = 1, variableBase = 0 } },
    variableSprites = {},
    recordCount = #spriteIds,
  })
  for _, spriteId in ipairs(spriteIds) do
    local visual = FieldActorFixture.visual(spriteId, { frameCount = 2 })
    visual.render.image = SHARED_TEST_ATLAS
    cache:writeLua(FieldActorCache.visualPath(spriteId), visual)
    cache:write(FieldActorCache.atlasPath(spriteId), "png-bytes")
  end
  local innerRead = cache.read
  function cache.read(self, path)
    if path == SHARED_TEST_ATLAS then
      error("redundant provider-side atlas read for " .. path, 0)
    end
    return innerRead(self, path)
  end
  local pool = SharedImagePoolFake.new()
  pool:seedPhysical(SHARED_TEST_ATLAS, POOLED_SAMPLER, { image = pooledTestImage(64, 32) })
  return cache, pool, pooledTestGraphics(failOnNewMesh)
end

function T.pooled_branch_shares_one_leased_atlas_without_provider_side_png_read()
  local cache, pool, graphics = sharedAtlasSetup({ 0, 29 })
  local provider = FieldActorAssetProvider.new(cache, { graphics = graphics, imageAssets = pool })
  Assert.isTrue(provider:prepare(0), "a staged atlas reports ready")
  Assert.isTrue(provider:prepare(29), "every sprite holds its own staged ticket")
  local first = provider:acquire(0)
  local second = provider:acquire(29)
  Assert.isTrue(first.image == second.image, "sharing sprites resolve one physical atlas")
  Assert.equal(#first.quads, 2, "the leased atlas keeps stable quad geometry")
  Assert.equal(first.quads[2].x, 32, "the second frame still slides onto the shared strip")
  Assert.equal(#first.meshes, 2, "one world mesh per atlas frame")
  Assert.equal(pool:stats().physicalImages, 1, "one physical pair for matching content and sampler")
  Assert.equal(pool:stats().outstandingLeases, 2, "each presented sprite holds its own lease")
  provider:release(0)
  Assert.notNil(provider:resident(29), "the live peer survives its sibling release")
  Assert.isFalse(first.image.released, "the shared physical stays live while a peer holds it")
  Assert.equal(pool:stats().outstandingLeases, 2, "the idle-ringed sibling retains its lease until eviction or dispose")
  provider:release(29)
  provider:dispose()
  Assert.equal(pool:stats().outstandingLeases, 0, "teardown returns every borrowed lease")
  Assert.equal(pool:stats().physicalImages, 1, "the idle physical stays resident until pruned")
  Assert.isFalse(first.image.released, "disposal never releases the borrowed physical directly")
  Assert.equal(provider:stats().references, 0, "no presentation residency leaks")
  Assert.equal(pool:prune(), 1, "the idle physical is reclaimed exactly once by its owner")
  Assert.equal(first.image.releaseCount, 1, "the physical pair is released exactly once")
end

function T.pooled_mesh_failure_returns_the_borrowed_lease_once()
  local cache, pool, graphics = sharedAtlasSetup({ 0 }, 1)
  local provider = FieldActorAssetProvider.new(cache, { graphics = graphics, imageAssets = pool })
  Assert.isTrue(provider:prepare(0), "a staged atlas reports ready before the build")
  local err = Assert.throws(function()
    provider:acquire(0)
  end)
  Assert.isTrue(tostring(err):find("injected newMesh failure", 1, true) ~= nil)
  Assert.equal(pool:stats().outstandingLeases, 0, "the failed load returns its borrowed lease")
  Assert.notNil(pool:findPhysical(SHARED_TEST_ATLAS, POOLED_SAMPLER), "the pool-owned pair stays valid")
  Assert.equal(provider:stats().live, 0, "the failed entry publishes nothing")
  Assert.equal(provider:stats().loads, 0, "the failed load counts no completed load")
end

-- A session image owner whose worker-backed requests stay pending until the
-- test releases them, so readiness polling can be observed without blocking.
-- It counts every request and cancellation and otherwise behaves exactly
-- like the shared fake.
local function pendingImagePool()
  local inner = SharedImagePoolFake.new()
  local held = {} -- token -> true while the worker result is withheld
  local holdNext = false
  local pool = { requests = 0, cancels = 0 }
  function pool:holdNextRequest()
    holdNext = true
  end
  function pool:releasePending()
    for token in pairs(held) do
      held[token] = nil
    end
  end
  function pool:request(path, sampler, priority)
    self.requests = self.requests + 1
    local token = inner:request(path, sampler, priority)
    if holdNext then
      holdNext = false
      held[token] = true
    end
    return token
  end
  function pool:poll(token)
    if held[token] then
      return "pending"
    end
    return inner:poll(token)
  end
  function pool:acquire(token)
    held[token] = nil
    return inner:acquire(token)
  end
  function pool:cancel(token)
    self.cancels = self.cancels + 1
    held[token] = nil
    return inner:cancel(token)
  end
  function pool:release(lease)
    return inner:release(lease)
  end
  function pool:seedPhysical(path, sampler, handle)
    return inner:seedPhysical(path, sampler, handle)
  end
  function pool:failAfterUploads(count, message)
    return inner:failAfterUploads(count, message)
  end
  function pool:clearFailure()
    return inner:clearFailure()
  end
  function pool:stats()
    return inner:stats()
  end
  function pool:findPhysical(path, sampler)
    return inner:findPhysical(path, sampler)
  end
  function pool:prune()
    return inner:prune()
  end
  function pool:dispose()
    return inner:dispose()
  end
  function pool:uploadCount()
    return inner.uploads
  end
  return pool
end

-- Compiled sprites with per-sprite atlas paths, served by a pool whose
-- worker timing the test controls. Any provider-side read of the atlas
-- bytes fails loudly so the pooled path cannot hide behind a passing cache.
---@return CacheFs cache, table pool, table graphics
local function pendingAtlasSetup(spriteIds, failOnNewMesh)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    romVersion = "heartgold",
    spriteIds = spriteIds,
    runtime = { avatars = {}, variableSprites = { first = 1, last = 1, variableBase = 0 } },
    variableSprites = {},
    recordCount = #spriteIds,
  })
  for _, spriteId in ipairs(spriteIds) do
    cache:writeLua(FieldActorCache.visualPath(spriteId), FieldActorFixture.visual(spriteId, { frameCount = 2 }))
    cache:write(FieldActorCache.atlasPath(spriteId), "png-bytes")
  end
  local prefix = FieldActorCache.assetDir() .. "/"
  local innerRead = cache.read
  function cache.read(self, path)
    if path:sub(1, #prefix) == prefix then
      error("redundant provider-side atlas read for " .. path, 0)
    end
    return innerRead(self, path)
  end
  return cache, pendingImagePool(), pooledTestGraphics(failOnNewMesh)
end

-- Readiness polling never waits on the image worker: repeated checks while
-- the worker is stalled report not-ready at once, keep one outstanding
-- ticket, build no GPU entry, and the later ready check acquires exactly
-- one entry that releases exactly once.
function T.pending_atlas_reports_not_ready_without_blocking_then_builds_exactly_one_entry()
  local cache, pool, graphics = pendingAtlasSetup({ 0 })
  local provider = FieldActorAssetProvider.new(cache, { graphics = graphics, imageAssets = pool })
  pool:holdNextRequest()
  Assert.isFalse(provider:prepare(0), "the stalled worker reports not-ready")
  Assert.isFalse(provider:prepare(0), "a second check still returns at once")
  Assert.isFalse(provider:prepare(0), "a third check still returns at once")
  Assert.equal(pool.requests, 1, "repeated readiness checks reuse one outstanding ticket")
  Assert.isNil(provider:resident(0), "a preparing sprite is not a referenced entry")
  Assert.equal(provider:stats().live, 0, "no GPU entry is built before acquisition")
  Assert.equal(pool:stats().outstandingLeases, 0, "no lease is borrowed before acquisition")
  Assert.equal(pool:uploadCount(), 0, "the stalled worker stages nothing")
  pool:releasePending()
  Assert.isTrue(provider:prepare(0), "the completed worker reports ready")
  Assert.equal(pool.requests, 1, "readiness still rides the original ticket")
  local entry = provider:acquire(0)
  Assert.notNil(entry.image, "acquisition hands out the borrowed atlas")
  Assert.equal(#entry.quads, 2, "the leased atlas keeps stable quad geometry")
  Assert.equal(entry.quads[2].x, 32, "the second frame still slides onto the shared strip")
  Assert.equal(#entry.meshes, 2, "one world mesh per atlas frame")
  Assert.isTrue(provider:resident(0) == entry, "acquisition publishes a referenced entry")
  Assert.equal(pool:uploadCount(), 1, "one worker staging builds one physical pair")
  provider:release(0)
  Assert.equal(provider:stats().references, 0, "the release balances the acquire")
  Assert.equal(pool:stats().outstandingLeases, 1, "the idle entry retains its lease until eviction or dispose")
  provider:dispose()
  Assert.equal(provider:stats().live, 0, "teardown publishes nothing")
  Assert.equal(pool:stats().outstandingLeases, 0, "teardown returns every borrowed lease")
  Assert.equal(pool:prune(), 1, "the idle physical is reclaimed exactly once by its owner")
end

-- Compiled sprites sharing one generated atlas, served by a pool whose
-- worker timing the test controls. Any provider-side read of the atlas
-- bytes fails loudly so the pooled path cannot hide behind a passing cache.
---@return CacheFs cache, table pool, table graphics
local function sharedPendingAtlasSetup(spriteIds)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    romVersion = "heartgold",
    spriteIds = spriteIds,
    runtime = { avatars = {}, variableSprites = { first = 1, last = 1, variableBase = 0 } },
    variableSprites = {},
    recordCount = #spriteIds,
  })
  for _, spriteId in ipairs(spriteIds) do
    local visual = FieldActorFixture.visual(spriteId, { frameCount = 2 })
    visual.render.image = SHARED_TEST_ATLAS
    cache:writeLua(FieldActorCache.visualPath(spriteId), visual)
    cache:write(FieldActorCache.atlasPath(spriteId), "png-bytes")
  end
  local innerRead = cache.read
  function cache.read(self, path)
    if path == SHARED_TEST_ATLAS then
      error("redundant provider-side atlas read for " .. path, 0)
    end
    return innerRead(self, path)
  end
  return cache, pendingImagePool(), pooledTestGraphics()
end

-- Pending and ready-but-unconsumed tickets never outlive their
-- cancellation, and cancelling them never disturbs a live reference held
-- on the same shared physical pair.
function T.cancelled_preparations_return_their_tickets_without_touching_live_references()
  local cache, pool, graphics = sharedPendingAtlasSetup({ 0, 29, 7 })
  local provider = FieldActorAssetProvider.new(cache, { graphics = graphics, imageAssets = pool })
  Assert.isTrue(provider:prepare(7), "an unstalled worker reports ready at once")
  local live = provider:acquire(7)
  Assert.isTrue(provider:resident(7) == live, "the independent sprite holds a live reference")
  pool:holdNextRequest()
  Assert.isFalse(provider:prepare(0), "the stalled ticket reports not-ready")
  Assert.isTrue(provider:prepare(29), "the unstalled ticket reports ready")
  Assert.equal(pool.requests, 3, "every sprite holds exactly one outstanding ticket")
  Assert.isNil(provider:resident(0), "a preparing sprite is not a referenced entry")
  Assert.isNil(provider:resident(29), "a ready-but-unconsumed ticket is not a referenced entry")
  Assert.isTrue(provider:cancelPreparation(0), "cancelling the pending ticket drops it")
  Assert.isFalse(provider:cancelPreparation(0), "cancelling twice reports nothing left to drop")
  Assert.isTrue(provider:cancelPreparation(29), "cancelling the ready ticket returns it")
  Assert.equal(pool.cancels, 2, "each dropped live ticket reaches the image owner exactly once; the false repeat forwards nothing")
  pool:holdNextRequest()
  Assert.isFalse(provider:prepare(0), "re-expressing interest after cancel starts one fresh ticket")
  Assert.equal(pool.requests, 4, "the fresh interest is exactly one new request")
  Assert.isTrue(provider:resident(7) == live, "cancellations never disturb the live reference")
  Assert.equal(provider:stats().references, 1, "cancellations never mutate reference counts")
  pool:releasePending()
  Assert.isTrue(provider:prepare(0), "the completed worker reports ready")
  local entry = provider:acquire(0)
  Assert.isTrue(entry.image == live.image, "sharing sprites resolve one physical atlas")
  Assert.equal(pool:stats().physicalImages, 1, "one physical pair for the shared source")
  Assert.equal(pool:stats().outstandingLeases, 2, "each presented sprite holds its own lease")
  provider:release(7)
  provider:release(0)
  provider:dispose()
  provider:dispose()
  Assert.equal(provider:stats().references, 0, "no presentation residency leaks")
  Assert.equal(provider:stats().live, 0, "teardown publishes nothing")
  Assert.equal(pool:stats().outstandingLeases, 0, "teardown returns every borrowed lease")
  local physical = pool:findPhysical(SHARED_TEST_ATLAS, POOLED_SAMPLER)
  Assert.notNil(physical, "the shared physical stays valid until its owner reclaims it")
  Assert.equal(pool:prune(), 1, "the idle physical is reclaimed exactly once by its owner")
  Assert.equal(physical.releaseCount, 1, "the physical pair is released exactly once")
end

-- A failed atlas staging or a failed mesh build publishes no entry, keeps
-- no ticket, returns the borrowed image exactly once, and a fresh attempt
-- after repairing the failure succeeds.
function T.atlas_or_mesh_failure_leaves_no_entry_and_allows_a_clean_retry()
  local cache, pool, graphics = pendingAtlasSetup({ 0 })
  pool:failAfterUploads(0, "injected worker failure")
  local provider = FieldActorAssetProvider.new(cache, { graphics = graphics, imageAssets = pool })
  local atlasPath = FieldActorCache.atlasPath(0)
  local atlasErr = Assert.throws(function()
    provider:prepare(0)
  end, "a failed worker staging must raise")
  Assert.isTrue(Errors.is(atlasErr), "expected a typed failure, got " .. tostring(atlasErr))
  Assert.equal(atlasErr.code, "FIELD_ACTOR_ATLAS_MISSING")
  Assert.isTrue(
    tostring(atlasErr.message):find(atlasPath, 1, true) ~= nil,
    "the atlas failure names the offending path"
  )
  Assert.equal(pool:stats().outstandingLeases, 0, "the failed staging borrows no lease")
  Assert.isNil(provider:resident(0), "the failed staging publishes no entry")
  Assert.equal(provider:stats().live, 0, "the failed staging counts no live entry")
  Assert.throws(function()
    provider:acquire(0)
  end, "acquiring without a ready staging must fail loudly instead of waiting")
  pool:clearFailure()
  Assert.isTrue(provider:prepare(0), "repairing the worker allows a fresh attempt")
  local recovered = provider:acquire(0)
  Assert.notNil(recovered.image, "the fresh attempt builds a valid entry")
  provider:release(0)
  provider:dispose()

  local meshCache, meshPool, meshGraphics = pendingAtlasSetup({ 0 }, 1)
  local meshProvider = FieldActorAssetProvider.new(meshCache, { graphics = meshGraphics, imageAssets = meshPool })
  Assert.isTrue(meshProvider:prepare(0), "an unstalled worker reports ready at once")
  local meshErr = Assert.throws(function()
    meshProvider:acquire(0)
  end, "a failed mesh build must raise")
  Assert.isTrue(tostring(meshErr):find("injected newMesh failure", 1, true) ~= nil)
  Assert.equal(meshPool:stats().outstandingLeases, 0, "the failed build returns its borrowed lease")
  Assert.notNil(
    meshPool:findPhysical(atlasPath, POOLED_SAMPLER),
    "the pool-owned pair stays valid after the failed build"
  )
  Assert.isNil(meshProvider:resident(0), "the failed build publishes no entry")
  Assert.equal(meshProvider:stats().live, 0, "the failed build counts no live entry")
  Assert.equal(meshProvider:stats().loads, 0, "the failed build counts no completed load")
  Assert.isTrue(meshProvider:prepare(0), "repairing the builder allows a fresh attempt")
  local rebuilt = meshProvider:acquire(0)
  Assert.notNil(rebuilt.image, "the fresh attempt builds a valid entry")
  Assert.equal(#rebuilt.meshes, 2, "one world mesh per atlas frame")
  meshProvider:release(0)
  meshProvider:dispose()
  Assert.equal(meshPool:stats().outstandingLeases, 0, "teardown returns every borrowed lease")
end

return { tests = T }
