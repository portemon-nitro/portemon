-- Lifecycle tests for the mon icon asset provider, driven against an
-- in-memory cache and the synchronous shared image owner, so no GPU
-- resource is created outside the pool. Covers per-page lease adoption,
-- per-key quad caching, unknown keys failing as structured errors (never
-- blank icons), and exactly-once lease return with idle-then-trim
-- reclamation through the shared idle limit.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local MonCache = require("libs.assets.src.MonCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")

local T = {}

local DEFAULT_PAGE_WIDTH = 256
local DEFAULT_PAGE_HEIGHT = 128

local function entry(pageId, x, y)
  return {
    x = x,
    y = y,
    width = 32,
    height = 32,
    frames = {
      { x = x, y = y, width = 32, height = 32, duration = 1 },
      { x = x + 32, y = y, width = 32, height = 32, duration = 1 },
    },
    pageId = pageId,
  }
end

local function manifest()
  return {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = MonCache.iconPagePath(0), width = 256, height = 128 },
    },
    pageIds = { 0 },
    entries = {
      ["CHIKORITA/f0"] = entry(0, 0, 0),
      ["CHIKORITA/egg"] = entry(0, 0, 32),
    },
    representative = { "CHIKORITA/f0", "CHIKORITA/egg" },
  }
end

local function seed(manifestOverride, imageBytes)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), manifestOverride or manifest())
  cache:write(MonCache.iconPagePath(0), imageBytes or "png-bytes")
  return cache
end

local function stubGraphics()
  return {
    newImage = function(_)
      error("icon pages borrow the shared image owner instead of constructing images", 0)
    end,
    newQuad = function(x, y, w, h, imgW, imgH)
      return { x = x, y = y, w = w, h = h, imgW = imgW, imgH = imgH }
    end,
  }
end

-- The injected shared image owner behind icon demand: the synchronous
-- fake wrapped with per-path source geometry, so adopted leases carry
-- the decoded dimensions the provider validates and quads build over.
-- Sizes default to the manifest page geometry; tests override paths
-- that must decode smaller. Request paths are recorded for
-- demand-scoping assertions; uploads and the inner census prove
-- adoption bounds and exactly-once return.
---@param sizes table<string, integer[]>? decoded dimensions by icon page path
---@return table<string, unknown> pool double
---@return SharedImagePoolFake inner fake behind census assertions
---@return string[] enrolled request paths in order
local function iconPool(sizes)
  local inner = SharedImagePoolFake.new()
  local requested = {}
  local paths = {}
  local pool = {}
  function pool:request(path, sampler, priority)
    requested[#requested + 1] = path
    local token = inner:request(path, sampler, priority)
    paths[token] = path
    return token
  end
  function pool:poll(token)
    return inner:poll(token)
  end
  function pool:acquire(token)
    local lease = inner:acquire(token)
    local size = (sizes or {})[paths[token]] or { DEFAULT_PAGE_WIDTH, DEFAULT_PAGE_HEIGHT }
    lease.width = size[1]
    lease.height = size[2]
    lease.kind = "rgba8"
    local image = assert(lease.image, "shared leases carry their page image")
    if image.getWidth == nil then
      function image:getWidth()
        return size[1]
      end
      function image:getHeight()
        return size[2]
      end
    end
    return lease
  end
  function pool:release(lease)
    return inner:release(lease)
  end
  function pool:cancel(token)
    return inner:cancel(token)
  end
  function pool:prune()
    return inner:prune()
  end
  function pool:stats()
    return inner:stats()
  end
  return pool, inner, requested
end

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  if not ok and Errors.is(err) then
    Assert.equal((err --[[@as Errors.Error]]).code, code)
    return
  end
  error("expected structured error " .. code .. ", got: " .. tostring(err), 2)
end

local function readyDerivedAssets()
  return {
    requestIconPage = function(pageId, _)
      assert(type(pageId) == "number", "icon demand carries its page")
      return true
    end,
  }
end

local function preparedProvider(cache, pool)
  local provider = MonIconAssetProvider.new(cache, {
    graphics = stubGraphics(),
    imagePool = pool,
    derivedAssets = readyDerivedAssets(),
  })
  return provider
end

local function prepareUntilReady(provider, keys)
  local ready, failure = false, nil
  for _ = 1, 8 do
    ready, failure = provider:prepareKeys(keys)
    if ready or failure ~= nil then
      break
    end
  end
  Assert.isTrue(ready, "demanded pages prepare: " .. tostring(failure))
  Assert.isNil(failure, "preparation reports no failure")
  return provider
end

function T.atlas_loads_once_and_quads_cache_per_key()
  local pool, inner, _ = iconPool()
  local provider = preparedProvider(seed(), pool)
  Assert.equal(inner.uploads, 0, "construction borrows no page image")
  prepareUntilReady(provider, { "CHIKORITA/f0", "CHIKORITA/egg" })
  Assert.equal(inner.uploads, 1, "the page borrows once for the provider lifetime")
  local first = provider:quadFor("CHIKORITA/f0") --[[@as { x: number, y: number, w: number, h: number }]]
  Assert.isTrue(provider:quadFor("CHIKORITA/f0") == first, "quads reuse per icon key")
  Assert.equal(first.x, 0)
  Assert.equal(first.w, 32)
  local egg = provider:quadFor("CHIKORITA/egg") --[[@as { x: number, y: number, w: number, h: number }]]
  Assert.isTrue(egg ~= first)
  Assert.equal(egg.y, 32)
  Assert.deepEqual(provider:dimensions("CHIKORITA/f0"), { width = 32, height = 32 })
  provider:release()
end

function T.unknown_keys_fail_loudly()
  local pool, _, _ = iconPool()
  local provider = MonIconAssetProvider.new(seed(), { graphics = stubGraphics(), imagePool = pool })
  throwsCode("MON_ICON_UNKNOWN_KEY", function()
    provider:quadFor("MISSINGNO/f0")
  end)
  throwsCode("MON_ICON_UNKNOWN_KEY", function()
    provider:dimensions("MISSINGNO/f0")
  end)
  provider:release()
end

function T.release_returns_the_borrow_exactly_once_and_trim_reclaims_it()
  local pool, inner, _ = iconPool()
  local provider = preparedProvider(seed(), pool)
  prepareUntilReady(provider, { "CHIKORITA/f0" })
  provider:quadFor("CHIKORITA/f0")
  local image = provider:image("CHIKORITA/f0")
  provider:release()
  Assert.equal(inner:stats().outstandingLeases, 0, "release returns the adopted borrow")
  Assert.equal(image.releaseCount, 0, "the returned page rests idle instead of freeing synchronously")
  local trimmed = pool:prune()
  Assert.equal(trimmed, 1, "the idle trim reclaims the returned page")
  Assert.equal(image.releaseCount, 1, "the trim frees the page image exactly once")
  provider:release()
  Assert.equal(image.releaseCount, 1, "a second release stays a safe no-op")
  Assert.equal(pool:prune(), 0, "a second trim reclaims nothing again")
end

function T.missing_artifacts_fail_at_construction()
  local pool, inner, _ = iconPool()
  local cache = seed()
  cache:remove(MonCache.iconPagePath(0))
  local provider = preparedProvider(cache, pool)
  Assert.equal(inner.uploads, 0, "missing page bytes never fail metadata construction")
  local ready, failure = provider:prepareKeys({ "CHIKORITA/f0" })
  Assert.isFalse(ready, "a page without compiled bytes never reports ready")
  Assert.isTrue(
    tostring(failure):find("mon icon page missing", 1, true) ~= nil,
    "the missing page surfaces as a visible preparation error: " .. tostring(failure)
  )
  provider:release()
  throwsCode("MON_ICON_MANIFEST_UNAVAILABLE", function()
    MonIconAssetProvider.new(CacheFs.forVersion("heartgold", FakeCache.new()), {
      graphics = stubGraphics(),
      imagePool = pool,
    })
  end)
end

local function pagedManifest()
  local function pageEntry(pageId, x, y)
    return {
      x = x,
      y = y,
      width = 32,
      height = 32,
      frames = {
        { x = x, y = y, width = 32, height = 32, duration = 6 },
        { x = x + 32, y = y, width = 32, height = 32, duration = 6 },
      },
      pageId = pageId,
    }
  end
  return {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = MonCache.iconPagePath(0), width = 256, height = 128 },
      [1] = { pageId = 1, image = MonCache.iconPagePath(1), width = 256, height = 128 },
    },
    pageIds = { 0, 1 },
    entries = {
      ["CHIKORITA/f0"] = pageEntry(0, 0, 0),
      ["CHIKORITA/egg"] = pageEntry(0, 64, 0),
      ["TOTODILE/f0"] = pageEntry(1, 0, 0),
    },
    representative = { "CHIKORITA/f0", "TOTODILE/f0" },
  }
end

local function seedPaged()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), pagedManifest())
  cache:write(MonCache.iconPagePath(0), "page-0-bytes")
  cache:write(MonCache.iconPagePath(1), "page-1-bytes")
  return cache
end

function T.page_images_are_owned_per_selector_with_exact_return_on_late_failure()
  Assert.equal(type(MonCache.iconPagePath), "function", "icon pages have their own path constructor")
  local pool, inner, _ = iconPool()
  local provider = MonIconAssetProvider.new(seedPaged(), {
    graphics = stubGraphics(),
    imagePool = pool,
    derivedAssets = readyDerivedAssets(),
  })
  Assert.equal(inner.uploads, 0, "construction borrows no page image")
  prepareUntilReady(provider, { "CHIKORITA/f0", "CHIKORITA/egg", "TOTODILE/f0" })
  Assert.equal(inner.uploads, 2, "preparation borrows one physical image per demanded page")
  Assert.isTrue(
    provider:image("CHIKORITA/f0") ~= provider:image("TOTODILE/f0"),
    "selectors on different pages resolve to their own page image"
  )
  Assert.isTrue(
    provider:image("CHIKORITA/f0") == provider:image("CHIKORITA/egg"),
    "selectors sharing a page share its image"
  )
  local quad = provider:quadFor("TOTODILE/f0") --[[@as { x: number, y: number, w: number, h: number }]]
  Assert.equal(quad.x, 0)
  Assert.equal(quad.w, 32)
  local firstImage = provider:image("CHIKORITA/f0")
  local secondImage = provider:image("TOTODILE/f0")
  provider:release()
  Assert.equal(inner:stats().outstandingLeases, 0, "release returns every adopted borrow")
  pool:prune()
  Assert.equal(firstImage.releaseCount, 1, "the trim frees the first page image exactly once")
  Assert.equal(secondImage.releaseCount, 1, "the trim frees the second page image exactly once")

  -- A shared-owner staging failure after an earlier page succeeded keeps
  -- the earlier page and surfaces the failure instead of a half-ready icon.
  local failingPool, failingInner, _ = iconPool()
  failingInner:failAfterUploads(1, "injected shared image failure")
  local failing = MonIconAssetProvider.new(seedPaged(), {
    graphics = stubGraphics(),
    imagePool = failingPool,
    derivedAssets = readyDerivedAssets(),
  })
  local ready, failure = failing:prepareKeys({ "CHIKORITA/f0", "TOTODILE/f0" })
  for _ = 1, 8 do
    if ready or failure ~= nil then
      break
    end
    ready, failure = failing:prepareKeys({ "CHIKORITA/f0", "TOTODILE/f0" })
  end
  Assert.isFalse(ready, "a failed adoption never reports ready")
  Assert.notNil(failure, "the adoption failure carries a diagnosable cause")
  Assert.equal(failingInner.uploads, 1, "the earlier page borrowed before the failure")
  local kept = failing:image("CHIKORITA/f0")
  Assert.equal(kept.releaseCount, 0, "the earlier page stays live through the sibling failure")
  failing:release()
  failingPool:prune()
  Assert.equal(kept.releaseCount, 1, "release frees the earlier page exactly once")
end

-- Construction loads and validates layout metadata without borrowing any
-- page image: GPU leases are adopted only for pages the visible party
-- actually demands, one page per preparation update.
function T.construction_creates_no_page_images()
  local pool, inner, _ = iconPool()
  local provider = MonIconAssetProvider.new(seedPaged(), { graphics = stubGraphics(), imagePool = pool })
  Assert.equal(inner.uploads, 0, "construction loads metadata without borrowing page images")
  provider:release()
end

local function threePageManifest()
  local function pageEntry(pageId, x, y)
    return {
      x = x,
      y = y,
      width = 32,
      height = 32,
      frames = {
        { x = x, y = y, width = 32, height = 32, duration = 6 },
      },
      pageId = pageId,
    }
  end
  return {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = MonCache.iconPagePath(0), width = 256, height = 128 },
      [1] = { pageId = 1, image = MonCache.iconPagePath(1), width = 256, height = 128 },
      [2] = { pageId = 2, image = MonCache.iconPagePath(2), width = 256, height = 128 },
    },
    pageIds = { 0, 1, 2 },
    entries = {
      ["CHIKORITA/f0"] = pageEntry(0, 0, 0),
      ["CYNDAQUIL/f0"] = pageEntry(0, 64, 0),
      ["CHIKORITA/egg"] = pageEntry(1, 0, 0),
      ["TOTODILE/f0"] = pageEntry(1, 64, 0),
      ["MEW/f0"] = pageEntry(2, 0, 0),
    },
    representative = { "CHIKORITA/f0", "TOTODILE/f0", "MEW/f0" },
  }
end

local function seedThreePages()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), threePageManifest())
  cache:write(MonCache.iconPagePath(0), "page-0-bytes")
  cache:write(MonCache.iconPagePath(1), "page-1-bytes")
  cache:write(MonCache.iconPagePath(2), "page-2-bytes")
  return cache
end

local function fakeDerivedAssets(requested)
  return {
    requestIconPage = function(pageId, _)
      requested[#requested + 1] = pageId
      return true
    end,
  }
end

-- Only the pages behind the given icon keys become compilation and image
-- work: two slots sharing a page deduplicate to one request, egg and form
-- variants on another page share that page, and the unrelated third page
-- is never requested, borrowed, or adopted. Every ready page adopts
-- together.
function T.preparation_requests_only_the_pages_behind_the_given_keys()
  local compiled = {}
  local pool, inner, requested = iconPool()
  local provider = MonIconAssetProvider.new(seedThreePages(), {
    graphics = stubGraphics(),
    imagePool = pool,
    derivedAssets = fakeDerivedAssets(compiled),
  })
  local uploadsBefore = inner.uploads
  local ready, failure = provider:prepareKeys({ "CHIKORITA/f0", "CYNDAQUIL/f0", "CHIKORITA/egg", "TOTODILE/f0" })
  table.sort(compiled)
  Assert.deepEqual(compiled, { 0, 1 }, "two slots sharing a page deduplicate; the unrelated page is never compiled")
  Assert.equal(#requested, 2, "only demanded pages reach image enrollment")
  Assert.isTrue(ready == true or ready == false, "preparation reports its readiness")
  Assert.isNil(failure, "no failure while demanded pages prepare: " .. tostring(failure))
  Assert.equal(inner.uploads - uploadsBefore, 2, "both ready pages adopt together on one preparation update")
  provider:release()
end

-- Draw-time getters must not synthesize unprepared pages: a page the
-- visible party never demanded stays unavailable until preparation, so a
-- missing page can never silently render as another page or blank icon.
function T.getters_require_prepared_pages_instead_of_loading_on_draw()
  local pool, _, _ = iconPool()
  local provider = MonIconAssetProvider.new(seedPaged(), { graphics = stubGraphics(), imagePool = pool })
  local ok = pcall(function()
    return provider:quadFor("TOTODILE/f0")
  end)
  Assert.isFalse(ok, "draw-time getters must not synthesize unprepared pages")
  provider:release()
end

-- An unknown icon key fails the round as a visible error instead of
-- enrolling partial page work or raising through the update boundary.
function T.unknown_keys_fail_preparation_loudly()
  local pool, inner, requested = iconPool()
  local compiled = {}
  local provider = MonIconAssetProvider.new(seedThreePages(), {
    graphics = stubGraphics(),
    imagePool = pool,
    derivedAssets = fakeDerivedAssets(compiled),
  })
  local ready, failure = provider:prepareKeys({ "MISSINGNO/f0" })
  Assert.isFalse(ready, "an unknown key never reports ready")
  Assert.isTrue(
    tostring(failure):find("MON_ICON_UNKNOWN_KEY", 1, true) ~= nil,
    "the unknown key carries its structured cause: " .. tostring(failure)
  )
  Assert.equal(#compiled, 0, "an unknown key enrolls no compilation work")
  Assert.equal(#requested, 0, "an unknown key enrolls no image work")
  Assert.equal(inner.uploads, 0, "an unknown key borrows no image")
  provider:release()
end

-- Bounds validate per adopted page against the decoded lease dimensions:
-- an undersized page image fails its own pages while healthy pages still
-- prepare, and an undemanded page never blocks the demanded ones.
function T.bounds_validate_only_the_adopted_page()
  local fresh = function(pool)
    return MonIconAssetProvider.new(seedThreePages(), {
      graphics = stubGraphics(),
      imagePool = pool,
      derivedAssets = fakeDerivedAssets({}),
    })
  end
  local healthyPool, healthyInner, _ = iconPool()
  local healthy = fresh(healthyPool)
  local ready, failure = false, nil
  for _ = 1, 8 do
    ready, failure = healthy:prepareKeys({ "CHIKORITA/f0", "TOTODILE/f0" })
    if ready or failure ~= nil then
      break
    end
  end
  Assert.isTrue(ready, "demanded pages prepare: " .. tostring(failure))
  Assert.equal(healthyInner.uploads, 2, "healthy pages adopt their leases")
  healthy:release()
  local smallPool, _, _ = iconPool({ [MonCache.iconPagePath(0)] = { 16, 16 } })
  local broken = fresh(smallPool)
  local brokenReady, brokenFailure = broken:prepareKeys({ "CHIKORITA/f0" })
  Assert.isFalse(brokenReady, "the undersized page image never reports ready")
  Assert.notNil(brokenFailure, "the bounds failure carries a cause")
  broken:release()
end

-- Visits many icon pages across box close/open cycles, then narrows back to
-- the active box: only the currently demanded pages stay borrowed, stale
-- pages return to idle and the explicit trim reclaims them exactly once, a
-- revisited box re-borrows only its own pages, and getters never alias
-- freed art. Every borrow rides the single shared image owner with no
-- prefetch beyond demand.
local function eightPageManifest()
  local pages = {}
  local pageIds = {}
  local entries = {}
  local representative = {}
  for pageId = 0, 7 do
    pages[pageId] = { pageId = pageId, image = MonCache.iconPagePath(pageId), width = 256, height = 128 }
    pageIds[#pageIds + 1] = pageId
    local key = "BOXMON" .. pageId .. "/f0"
    entries[key] = {
      x = 0,
      y = 0,
      width = 32,
      height = 32,
      frames = {
        { x = 0, y = 0, width = 32, height = 32, duration = 6 },
      },
      pageId = pageId,
    }
    representative[#representative + 1] = key
  end
  return {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    version = { id = "heartgold", language = "english" },
    pages = pages,
    pageIds = pageIds,
    entries = entries,
    representative = representative,
  }
end

local function seedEightPages()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), eightPageManifest())
  for pageId = 0, 7 do
    cache:write(MonCache.iconPagePath(pageId), "page-" .. pageId .. "-bytes")
  end
  return cache
end

function T.visited_pages_stay_bounded_by_current_demand_across_close_open_cycles()
  local compiled = {}
  local pool, inner, requested = iconPool()
  local provider = MonIconAssetProvider.new(seedEightPages(), {
    graphics = stubGraphics(),
    imagePool = pool,
    derivedAssets = fakeDerivedAssets(compiled),
  })
  Assert.equal(inner.uploads, 0, "construction borrows no page image")
  local demandedPaths = {}
  local function keysFor(pages)
    local keys = {}
    for _, pageId in ipairs(pages) do
      keys[#keys + 1] = "BOXMON" .. pageId .. "/f0"
      demandedPaths[MonCache.iconPagePath(pageId)] = true
    end
    return keys
  end
  local function prepareBox(pages)
    local ready, failure = false, nil
    for _ = 1, 8 do
      ready, failure = provider:prepareKeys(keysFor(pages))
      if ready or failure ~= nil then
        break
      end
    end
    Assert.isTrue(ready, "the visited box prepares: " .. tostring(failure))
    Assert.isNil(failure, "preparation reports no failure")
  end
  prepareBox({ 0, 1 })
  local zeroFirst = provider:image("BOXMON0/f0")
  for _, pages in ipairs({ { 2, 3 }, { 4, 5 }, { 6, 7 } }) do
    prepareBox(pages)
    provider:cancelPreparation()
  end
  Assert.equal(inner.uploads, 8, "every visited page borrows exactly once with no duplicates")
  prepareBox({ 6, 7 })
  -- Narrowing the demand returns the stale borrows without freeing them:
  -- the active box stays borrowed while replaced pages rest idle.
  Assert.equal(inner:stats().outstandingLeases, 2, "only the active box pages stay borrowed after close/open cycles")
  local staleReclaimed = pool:prune()
  Assert.equal(staleReclaimed, 6, "the idle trim reclaims the six stale box pages")
  Assert.equal(inner:stats().outstandingLeases, 2, "the active box pages stay borrowed across the trim")
  local activeSix = provider:image("BOXMON6/f0")
  local activeSeven = provider:image("BOXMON7/f0")
  Assert.isTrue(activeSix == provider:image("BOXMON6/f0"), "the active box resolves its live page image")
  local activeQuad = provider:quadFor("BOXMON6/f0") --[[@as { x: number, y: number, w: number, h: number }]]
  Assert.equal(activeQuad.w, 32, "the active box keeps exact quad geometry")
  Assert.deepEqual(provider:dimensions("BOXMON7/f0"), { width = 32, height = 32 })
  Assert.isTrue(activeSeven == provider:image("BOXMON7/f0"), "the reopened box resolves its live page image")
  Assert.isFalse(
    pcall(function()
      return provider:quadFor("BOXMON2/f0")
    end),
    "a trimmed box page never draws stale or blank art"
  )
  local freedZero = zeroFirst
  prepareBox({ 0, 1 })
  Assert.equal(inner.uploads, 10, "revisiting a trimmed box re-borrows only its own pages")
  local zeroNew = provider:image("BOXMON0/f0")
  Assert.isTrue(zeroNew ~= freedZero, "the revisited box resolves a fresh image instead of resurrecting")
  Assert.equal(freedZero.releaseCount, 1, "revisiting never resurrects the released handle")
  for _, path in ipairs(requested) do
    Assert.isTrue(demandedPaths[path] == true, "borrowing never prefetches beyond demand: " .. path)
  end
  local ready, failure = provider:prepareKeys({ "MISSINGNO/f0" })
  Assert.isFalse(ready, "an unknown key never reports ready")
  Assert.isTrue(
    tostring(failure):find("MON_ICON_UNKNOWN_KEY", 1, true) ~= nil,
    "the unknown key keeps its structured cause: " .. tostring(failure)
  )
  local liveZero = provider:image("BOXMON0/f0")
  local liveOne = provider:image("BOXMON1/f0")
  Assert.isTrue(liveZero == zeroNew, "the live box keeps its adopted image")
  -- Narrowing the demand a second time idles the superseded active
  -- pages; the explicit trim reclaims them exactly once.
  local supersededTrim = pool:prune()
  Assert.equal(supersededTrim, 2, "the trim reclaims the two superseded active pages")
  Assert.equal(activeSix.releaseCount, 1, "a superseded active page frees exactly once on trim")
  Assert.equal(activeSeven.releaseCount, 1, "a superseded active page frees exactly once on trim")
  provider:release()
  Assert.equal(inner:stats().outstandingLeases, 0, "release returns every adopted borrow")
  local trimmed = pool:prune()
  Assert.equal(trimmed, 2, "the final trim reclaims the two live pages")
  Assert.equal(liveZero.releaseCount, 1, "every page image frees exactly once")
  Assert.equal(liveOne.releaseCount, 1, "every page image frees exactly once")
end

return { tests = T }
