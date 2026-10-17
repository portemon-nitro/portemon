-- Behavior tests for the one session-scoped owner of physical GPU images:
-- logical generated-image requests resolve to shared immutable image and
-- palette objects keyed by exact pixel content plus sampler state, borrowers
-- hold explicit leases, the last release frees each physical object exactly
-- once, abandoned work never resurrects, and devices without indexed texture
-- support fall back to straight RGBA without losing a pixel. Synthetic PNGs
-- only; GPU construction goes through an injected fake namespace so these
-- run headless, while real-driver sampling identity lives in the graphics
-- image-sampling suite.

local Assert = require("tests.support.Assert")
local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
local CacheFs = require("libs.storage.src.CacheFs")
local PngWriter = require("libs.assets.src.PngWriter")

local T = {}

local FIXTURE_WIDTH = 4
local FIXTURE_HEIGHT = 2

local OPAQUE = string.char(200, 10, 20, 255)
local TRANSPARENT_RGB = string.char(10, 200, 30, 0)
local FRACTIONAL = string.char(10, 20, 30, 128)

local function fixturePixels()
  return OPAQUE .. TRANSPARENT_RGB .. FRACTIONAL .. OPAQUE .. TRANSPARENT_RGB .. FRACTIONAL .. OPAQUE .. TRANSPARENT_RGB
end

local function fixturePng()
  return PngWriter.encode(FIXTURE_WIDTH, FIXTURE_HEIGHT, fixturePixels())
end

local function matchingSampler()
  return { wrapX = "repeat", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }
end

local function otherWrapSampler()
  return { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }
end

local function otherFilterSampler()
  return { wrapX = "repeat", wrapY = "clamp", minFilter = "linear", magFilter = "linear" }
end

-- Loads the shared image owner. Every test below fails on this message --
-- naming the missing ownership behavior -- instead of failing the suite
-- load, so the red names the contract rather than a require path.
local function owner()
  local ok, mod = pcall(require, "libs.hgss.src.presentation.ImageAssetPool")
  Assert.isTrue(
    ok and type(mod) == "table",
    "the shared GPU image owner is not implemented: one session-scoped physical image "
      .. "and palette owner must serve every generated image consumer"
  )
  return mod
end

-- Injected graphics namespace: records every constructed image, the sampler
-- state it was configured with, and release calls. failOnCall makes the
-- Nth newImage call raise, so a staged upload can fail after its sibling
-- object already exists; formats controls the indexed-texture capability
-- the pool must probe instead of assuming.
local function fakeGraphics(opts)
  opts = opts or {}
  local formats = opts.formats
  if formats == nil then
    formats = { r8 = true }
  end
  local created = {}
  local calls = 0
  local graphics = { created = created }
  function graphics.getImageFormats()
    return formats
  end
  function graphics.newImage(_)
    calls = calls + 1
    if graphics.failOnCall == calls then
      error("injected image upload failure", 0)
    end
    local image = { released = false, releaseCount = 0, wrap = nil, filter = nil }
    function image:setFilter(min, mag)
      self.filter = { min, mag }
    end
    function image:setWrap(wrapX, wrapY)
      self.wrap = { wrapX, wrapY }
    end
    function image:release()
      self.released = true
      self.releaseCount = self.releaseCount + 1
    end
    created[#created + 1] = image
    return image
  end
  return graphics
end

local cacheSerial = 0

local function freshCache(tag)
  cacheSerial = cacheSerial + 1
  return CacheFs.forVersion("shared-image-owner-" .. tag .. "-" .. cacheSerial)
end

local function newPool(cache, graphics)
  -- These unit tests pin the historical evict-all cadence explicitly; the
  -- production default is the compiled first-pass idle budget.
  return owner().new(cache, { graphics = graphics, idleByteLimit = 0 })
end

-- Drives one logical request to a terminal state using only the pool's own
-- polling contract; a request that never resolves is a hung preparation,
-- not a pass.
local function awaitReady(pool, token)
  for _ = 1, 500 do
    local status, cause = pool:poll(token)
    if status == "ready" then
      return
    end
    Assert.isTrue(status ~= "failed", "image preparation failed: " .. tostring(cause))
    love.timer.sleep(0.005)
  end
  error("image preparation never reached a terminal state", 0)
end

local function requestReady(pool, path, sampler, priority)
  local token = pool:request(path, sampler, priority or "demand")
  awaitReady(pool, token)
  return token
end

local function liveImages(graphics)
  local live = {}
  for _, image in ipairs(graphics.created) do
    if not image.released then
      live[#live + 1] = image
    end
  end
  return live
end

local function withPool(tag, files, body)
  local cache = freshCache(tag)
  for path, bytes in pairs(files) do
    cache:write(path, bytes)
  end
  local graphics = fakeGraphics()
  local pool = newPool(cache, graphics)
  local ok, err = pcall(body, pool, graphics, cache)
  local disposeOk, disposeErr = pcall(pool.dispose, pool)
  local removeOk, removeErr = pcall(cache.removeTree, cache, "")
  if not ok then
    error(err, 0)
  end
  Assert.isTrue(disposeOk, "disposal after full release must succeed: " .. tostring(disposeErr))
  Assert.isTrue(removeOk, "fixture cleanup must succeed: " .. tostring(removeErr))
end

-- Two logical paths with byte-identical decoded pixels and matching sampler
-- state share one physical image and palette; a third path with the same
-- pixels under a different wrap pair -- and a fourth under a different
-- filter pair -- each resolve to their own physical image, and every lease
-- carries the same immutable resolved record.
function T.compatible_paths_share_one_physical_image_while_mismatched_samplers_do_not()
  withPool("dedup", {
    ["sprites/first.png"] = fixturePng(),
    ["sprites/second.png"] = fixturePng(),
    ["sprites/third.png"] = fixturePng(),
    ["sprites/fourth.png"] = fixturePng(),
  }, function(pool, graphics)
    local first = pool:acquire(requestReady(pool, "sprites/first.png", matchingSampler()))
    local second = pool:acquire(requestReady(pool, "sprites/second.png", matchingSampler()))
    local otherWrap = pool:acquire(requestReady(pool, "sprites/third.png", otherWrapSampler()))
    local otherFilter = pool:acquire(requestReady(pool, "sprites/fourth.png", otherFilterSampler()))

    Assert.equal(first.image, second.image, "identical pixels with matching sampler state share one image")
    Assert.equal(first.palette, second.palette, "compatible leases resolve the same palette handle")
    Assert.equal(first.physicalKey, second.physicalKey, "compatible leases resolve the same physical identity")
    Assert.equal(first.kind, second.kind, "compatible leases agree on the representation")
    Assert.equal(first.width, FIXTURE_WIDTH, "the lease carries the decoded width")
    Assert.equal(first.height, FIXTURE_HEIGHT, "the lease carries the decoded height")
    Assert.isTrue(otherWrap.image ~= first.image, "a different wrap pair must not alias the shared image")
    Assert.isTrue(
      otherWrap.physicalKey ~= first.physicalKey,
      "a different wrap pair resolves a different physical identity"
    )
    Assert.isTrue(otherFilter.image ~= first.image, "a different filter pair must not alias the shared image")
    Assert.isTrue(
      otherFilter.physicalKey ~= first.physicalKey,
      "a different filter pair resolves a different physical identity"
    )

    pool:release(first)
    pool:release(second)
    pool:release(otherWrap)
    pool:release(otherFilter)
    pool:prune()
    Assert.equal(#liveImages(graphics), 0, "releasing every lease and pruning frees all physical images")
    for _, image in ipairs(graphics.created) do
      Assert.equal(image.releaseCount, 1, "every physical image is released exactly once")
    end
  end)
end

-- Releasing overlapping compatible leases in either order keeps the shared
-- image alive until the last borrower lets go, then frees it exactly once.
function T.releasing_compatible_leases_in_either_order_frees_exactly_once_at_the_end()
  local png = fixturePng()
  withPool("release-order", { ["sprites/a.png"] = png, ["sprites/b.png"] = png }, function(pool, graphics)
    local first = pool:acquire(requestReady(pool, "sprites/a.png", matchingSampler()))
    local second = pool:acquire(requestReady(pool, "sprites/b.png", matchingSampler()))
    Assert.equal(first.image, second.image, "the setup shares one physical image")
    pool:release(first)
    Assert.isFalse(first.image.released, "releasing one of two borrowers must not free the shared image")
    pool:release(second)
    Assert.isTrue(second.image.released, "the last release frees the shared image")
    Assert.equal(second.image.releaseCount, 1, "forward-order release frees exactly once")
  end)
  withPool("release-reverse", { ["sprites/a.png"] = png, ["sprites/b.png"] = png }, function(pool, graphics)
    local first = pool:acquire(requestReady(pool, "sprites/a.png", matchingSampler()))
    local second = pool:acquire(requestReady(pool, "sprites/b.png", matchingSampler()))
    pool:release(second)
    Assert.isFalse(second.image.released, "release order must not matter while a borrower remains")
    pool:release(first)
    Assert.isTrue(first.image.released, "the last release frees the shared image in reverse order too")
    Assert.equal(first.image.releaseCount, 1, "reverse-order release frees exactly once")
  end)
end

-- A live borrower keeps its draw source usable while a peer comes and goes:
-- new demand for the same physical identity resolves to the same still-live
-- image instead of a duplicate or a freed object.
function T.a_live_borrower_keeps_its_draw_source_usable_after_a_peer_release()
  local png = fixturePng()
  withPool(
    "live-draw",
    { ["sprites/a.png"] = png, ["sprites/b.png"] = png, ["sprites/c.png"] = png },
    function(pool, graphics)
      local first = pool:acquire(requestReady(pool, "sprites/a.png", matchingSampler()))
      local second = pool:acquire(requestReady(pool, "sprites/b.png", matchingSampler()))
      pool:release(first)
      local late = pool:acquire(requestReady(pool, "sprites/c.png", matchingSampler()))
      Assert.equal(late.image, second.image, "new demand while a borrower lives reuses the live image")
      Assert.isFalse(late.image.released, "the live image stays usable after the peer release")
      Assert.equal(#liveImages(graphics), 2, "no duplicate physical image is built for live demand: one live pair")
      pool:release(second)
      Assert.isFalse(second.image.released, "the image stays alive while the late borrower holds it")
      pool:release(late)
      Assert.equal(late.image.releaseCount, 1, "the final release frees exactly once")
    end
  )
end

-- The pool reports its holdings through stats, pruning evicts only fully
-- released images, and disposal after full release is idempotent.
function T.idle_images_are_pruned_and_disposal_is_idempotent()
  withPool("lifecycle", { ["sprites/a.png"] = fixturePng() }, function(pool, graphics)
    local lease = pool:acquire(requestReady(pool, "sprites/a.png", matchingSampler()))
    Assert.equal(type(pool:stats()), "table", "the pool reports its holdings through stats")
    pool:release(lease)
    Assert.isFalse(lease.image.released, "a released-but-unpruned image stays resident until pruning")
    pool:prune()
    Assert.isTrue(lease.image.released, "pruning evicts the fully released image")
    pool:dispose()
    pool:dispose()
    Assert.equal(lease.image.releaseCount, 1, "disposal never releases twice")
  end)
end

-- A device without indexed texture support still prepares the image: the
-- lease falls back to straight RGBA with every source pixel -- including
-- transparent RGB and fractional alpha -- recovered exactly.
function T.devices_without_indexed_support_fall_back_to_straight_rgba()
  local cache = freshCache("fallback")
  cache:write("sprites/small.png", fixturePng())
  local graphics = fakeGraphics({ formats = {} })
  local pool = newPool(cache, graphics)
  local ok, err = pcall(function()
    local lease = pool:acquire(requestReady(pool, "sprites/small.png", matchingSampler()))
    Assert.equal(lease.kind, "rgba8", "missing indexed support selects the straight representation")
    Assert.equal(lease.width, FIXTURE_WIDTH, "the fallback lease carries the decoded width")
    Assert.equal(lease.height, FIXTURE_HEIGHT, "the fallback lease carries the decoded height")
    local realized = lease.image.data
    Assert.equal(type(realized), "userdata", "the fallback realizes a real pixel payload")
    Assert.equal(
      realized:getString(),
      fixturePixels(),
      "the fallback recovers every source pixel exactly, including transparent RGB and fractional alpha"
    )
    pool:release(lease)
    pool:prune()
  end)
  local disposeOk, disposeErr = pcall(pool.dispose, pool)
  local removeOk, removeErr = pcall(cache.removeTree, cache, "")
  if not ok then
    error(err, 0)
  end
  Assert.isTrue(disposeOk, "disposal must succeed: " .. tostring(disposeErr))
  Assert.isTrue(removeOk, "fixture cleanup must succeed: " .. tostring(removeErr))
end

-- A staged upload that fails partway releases only the objects its own
-- stage created: previously live images stay owned, no orphaned object is
-- left behind, and the same path succeeds on retry.
function T.a_failed_upload_releases_only_its_own_new_objects()
  local png = fixturePng()
  local cache = freshCache("failed-upload")
  cache:write("sprites/steady.png", png)
  cache:write("sprites/fragile.png", png)
  local graphics = fakeGraphics()
  local pool = newPool(cache, graphics)
  local ok, err = pcall(function()
    local steady = pool:acquire(requestReady(pool, "sprites/steady.png", matchingSampler()))
    Assert.equal(#graphics.created, 2, "an indexed realization stages the source and palette pair")
    local doomed = pool:request("sprites/fragile.png", matchingSampler())
    graphics.failOnCall = #graphics.created + 2
    local status = pool:poll(doomed)
    while status == "pending" do
      love.timer.sleep(0.005)
      status = pool:poll(doomed)
    end
    Assert.equal(status, "failed", "the staged upload reports its failure")
    Assert.throws(function()
      pool:acquire(doomed)
    end, "a failed request must not produce a lease")
    Assert.isFalse(steady.image.released, "the failure must not evict the previously live image")
    for _, image in ipairs(graphics.created) do
      local held = image == steady.image or image == steady.palette
      Assert.isTrue(image.released or held, "a failed stage leaves no orphaned GPU object behind")
    end
    graphics.failOnCall = nil
    local retried = pool:acquire(requestReady(pool, "sprites/fragile.png", matchingSampler()))
    local same = pool:acquire(requestReady(pool, "sprites/steady.png", matchingSampler()))
    Assert.equal(same.image, steady.image, "live leases survive the failed stage uncorrupted")
    pool:release(steady)
    pool:release(same)
    pool:release(retried)
    pool:prune()
  end)
  local disposeOk, disposeErr = pcall(pool.dispose, pool)
  local removeOk, removeErr = pcall(cache.removeTree, cache, "")
  if not ok then
    error(err, 0)
  end
  Assert.isTrue(disposeOk, "disposal must succeed: " .. tostring(disposeErr))
  Assert.isTrue(removeOk, "fixture cleanup must succeed: " .. tostring(removeErr))
end

-- Overlapping demand for one physical identity coalesces instead of
-- building duplicates, and one borrower leaving never disturbs the other.
function T.overlapping_demand_for_one_physical_image_coalesces()
  local png = fixturePng()
  withPool("coalesce", { ["sprites/a.png"] = png, ["sprites/b.png"] = png }, function(pool, graphics)
    local firstToken = pool:request("sprites/a.png", matchingSampler(), "prefetch")
    local secondToken = pool:request("sprites/b.png", matchingSampler(), "demand")
    awaitReady(pool, firstToken)
    awaitReady(pool, secondToken)
    local first = pool:acquire(firstToken)
    local second = pool:acquire(secondToken)
    Assert.equal(first.image, second.image, "in-flight identical identities coalesce to one physical image")
    Assert.equal(#liveImages(graphics), 2, "coalesced demand builds no duplicate: one live pair")
    pool:release(first)
    Assert.isFalse(first.image.released, "leaving one overlapping borrower keeps the image alive")
    pool:release(second)
    Assert.equal(second.image.releaseCount, 1, "the last overlapping release frees exactly once")
  end)
end

-- A pool built over a borrowed session queue routes its preparation
-- through that worker and leaves the worker to its owner: disposing the
-- pool frees its own images while the session queue keeps accepting work.
-- A pool that joined its borrowed worker on dispose would fail the final
-- enrollment below.
function T.a_borrowed_session_queue_outlives_the_pool_built_over_it()
  local cache = freshCache("borrowed-queue")
  cache:write("sprites/a.png", fixturePng())
  local graphics = fakeGraphics()
  local queue = AssetPreparationQueue.new(cache)
  local pool = owner().new(cache, { graphics = graphics, queue = queue })
  local ok, err = pcall(function()
    local lease = pool:acquire(requestReady(pool, "sprites/a.png", matchingSampler()))
    Assert.isTrue(lease.image ~= nil, "borrowed-queue preparation resolves an image")
    pool:release(lease)
    pool:prune()
    pool:dispose()
    local token = queue:request("image-derivative", "sprites/a.png", "demand")
    queue:cancel(token)
  end)
  local queueOk, queueErr = pcall(queue.release, queue)
  local disposeOk, disposeErr = pcall(pool.dispose, pool)
  local removeOk, removeErr = pcall(cache.removeTree, cache, "")
  if not ok then
    error(err, 0)
  end
  Assert.isTrue(queueOk, "session queue release must succeed: " .. tostring(queueErr))
  Assert.isTrue(disposeOk, "pool disposal must stay idempotent: " .. tostring(disposeErr))
  Assert.isTrue(removeOk, "fixture cleanup must succeed: " .. tostring(removeErr))
end

-- Disposal cancels pending interest: a request that never resolved adopts
-- nothing afterwards, publishes nothing, and builds no GPU object.
function T.disposal_cancels_pending_interest_without_late_adoption()
  local cache = freshCache("cancel-epoch")
  cache:write("sprites/late.png", fixturePng())
  local graphics = fakeGraphics()
  local pool = newPool(cache, graphics)
  local pending = pool:request("sprites/late.png", matchingSampler(), "prefetch")
  pool:dispose()
  Assert.throws(function()
    pool:acquire(pending)
  end, "a request cancelled by disposal must never adopt a lease")
  Assert.equal(#graphics.created, 0, "cancelled work builds no GPU object")
  pool:dispose()
  local removeOk, removeErr = pcall(cache.removeTree, cache, "")
  Assert.isTrue(removeOk, "fixture cleanup must succeed: " .. tostring(removeErr))
end

-- Cancelling unenrolled interest drops it before staging: the cancelled
-- token never resolves, never stages a GPU object, and cannot be
-- re-polled or re-cancelled, while a sibling request for the same path
-- still resolves and an already-acquired token refuses cancellation
-- because its outstanding lease owns the borrow.
function T.cancelled_interest_never_stages_or_resurrects()
  withPool("cancel", { ["sprites/a.png"] = fixturePng() }, function(pool, graphics, _)
    local dropped = pool:request("sprites/a.png", matchingSampler(), "prefetch")
    Assert.isTrue(pool:cancel(dropped), "unenrolled interest cancels")
    Assert.isFalse(pool:cancel(dropped), "a dropped token cancels only once")
    Assert.throws(function()
      pool:poll(dropped)
    end, "a cancelled token never resolves")
    local kept = requestReady(pool, "sprites/a.png", matchingSampler(), "demand")
    local lease = pool:acquire(kept)
    Assert.isTrue(lease.image ~= nil, "a sibling request still resolves after a cancellation")
    Assert.isFalse(pool:cancel(kept), "an acquired token keeps its record for outstanding leases")
    pool:release(lease)
    pool:prune()
    Assert.equal(#liveImages(graphics), 0, "cancelled work stages no GPU object")
  end)
end

-- A missing generated source fails exactly and loudly, and the pool keeps
-- serving valid sources afterwards.
function T.missing_sources_fail_without_poisoning_the_pool()
  withPool("missing", { ["sprites/good.png"] = fixturePng() }, function(pool, _)
    local missing = pool:request("sprites/absent.png", matchingSampler())
    local status, _ = pool:poll(missing)
    while status == "pending" do
      love.timer.sleep(0.005)
      status, _ = pool:poll(missing)
    end
    Assert.equal(status, "failed", "a missing source reports failure instead of substituting bytes")
    Assert.throws(function()
      pool:acquire(missing)
    end, "a missing source must not produce a lease")
    local recovered = pool:acquire(requestReady(pool, "sprites/good.png", matchingSampler()))
    Assert.equal(recovered.width, FIXTURE_WIDTH, "the pool keeps serving valid sources after a failure")
    pool:release(recovered)
    pool:prune()
  end)
end

return { tests = T }
