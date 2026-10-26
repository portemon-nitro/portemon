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
local PngWriter = require("tests.support.PngEncoder")

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

-- Same lifecycle as the default pool setup, but with an explicit idle
-- budget so a returned pair can stay resident across a revisit without an
-- intervening prune. Synthetic PNGs only; no user ROM content.
local function withIdlePool(tag, files, idleBytes, body)
  local cache = freshCache(tag)
  for path, bytes in pairs(files) do
    cache:write(path, bytes)
  end
  local graphics = fakeGraphics()
  local pool = owner().new(cache, { graphics = graphics, idleByteLimit = idleBytes })
  local ok, err = pcall(body, pool, graphics, cache)
  local disposeOk, disposeErr = pcall(pool.dispose, pool)
  local removeOk, removeErr = pcall(cache.removeTree, cache, "")
  if not ok then
    error(err, 0)
  end
  Assert.isTrue(disposeOk, "disposal after full release must succeed: " .. tostring(disposeErr))
  Assert.isTrue(removeOk, "fixture cleanup must succeed: " .. tostring(removeErr))
end

-- Counts entries in a private owner table without caring about values.
local function countKeys(value)
  local count = 0
  for _ in pairs(value or {}) do
    count = count + 1
  end
  return count
end

-- Counts worker-facing classification jobs filed through the pool's own
-- borrowed preparation queue from here on. The wrapper forwards every
-- call untouched; it only observes.
local function countQueueRequests(pool)
  local queue = assert(pool._queue, "the pool exposes its preparation queue")
  local inner = assert(queue.request, "the preparation queue exposes request")
  local calls = 0
  queue.request = function(self, kind, path, level)
    calls = calls + 1
    return inner(self, kind, path, level)
  end
  return function()
    return calls
  end
end

-- Runs body with pixel-decode construction counted. The wrapper forwards
-- every ImageData build untouched and restores the host namespace even
-- when body fails, so a red names the pool behavior, not the counter.
local function runWithDecodeCount(body)
  local host = assert(love.image, "observing pixel decoding requires love.image")
  local original = assert(host.newImageData, "observing pixel decoding requires love.image.newImageData")
  local calls = 0
  host.newImageData = function(...)
    calls = calls + 1
    return original(...)
  end
  local ok, err = pcall(body, function()
    return calls
  end)
  host.newImageData = original
  if not ok then
    error(err, 0)
  end
end

-- Deterministic synchronous stand-in for the background preparation
-- worker: every classification answer is ready immediately, so thousands
-- of request cycles stay fast while the pool still decodes, stages,
-- publishes, borrows, and evicts through its real main-thread path.
-- Alias paths share one pixel identity; every other path is distinct.
local function stubDerivativeQueue(hashForPath)
  local jobs = {}
  local nextJob = 0
  local queue = {}
  function queue:request(kind, path, level)
    assert(kind == "image-derivative", "the stub queue serves image derivatives only")
    assert(level == "demand" or level == "prefetch", "the stub queue needs a known priority")
    nextJob = nextJob + 1
    local pixels = string.rep("\7\11\13\255", 4)
    jobs[nextJob] = {
      state = "ready",
      payload = {
        sourceHash = "stub-source-for-" .. path,
        pixelHash = hashForPath(path),
        width = 2,
        height = 2,
        kind = "rgba8",
        colors = 0,
        indexData = love.data.newByteData(pixels),
        paletteData = nil,
      },
    }
    return nextJob
  end
  function queue:poll(job)
    local record = assert(jobs[job], "unknown preparation token")
    return record.state
  end
  function queue:take(job)
    local record = assert(jobs[job], "unknown preparation token")
    assert(record.state == "ready", "preparation result is not ready")
    jobs[job] = nil
    return record.payload
  end
  function queue:cancel(job)
    assert(jobs[job], "unknown preparation token")
    jobs[job] = nil
  end
  function queue:release() end
  return queue
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

-- A failed acquire releases only the objects its own stage created:
-- previously live images stay owned, no orphaned object is left behind, and
-- distinct content succeeds on retry. The doomed path carries different
-- pixels from the steady pair so its upload is genuinely attempted instead
-- of borrowing the live pair.
function T.a_failed_upload_releases_only_its_own_new_objects()
  local png = fixturePng()
  local fragilePng =
    PngWriter.encode(FIXTURE_WIDTH, FIXTURE_HEIGHT, string.char(201, 10, 20, 255) .. string.sub(fixturePixels(), 5))
  local cache = freshCache("failed-upload")
  cache:write("sprites/steady.png", png)
  cache:write("sprites/fragile.png", fragilePng)
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
    Assert.equal(status, "ready", "the upload waits for the consuming acquire instead of failing inside poll")
    Assert.throws(function()
      pool:acquire(doomed)
    end, "a failed acquire must not produce a lease")
    Assert.throws(function()
      pool:poll(doomed)
    end, "a failed acquire consumes its ticket")
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

-- A revisit of a still-resident logical image under the same sampler is a
-- true fast path: the second ticket is ready at once and borrows the
-- identical live pair with no new worker job, no pixel decode, and no GPU
-- upload. Synthetic PNG only; idle budget comfortably above the pair.
function T.resident_revisit_borrows_without_worker_decode_or_upload()
  runWithDecodeCount(function(decodeCalls)
    withIdlePool("resident-revisit", { ["sprites/icon.png"] = fixturePng() }, 1024 * 1024, function(pool, graphics)
      local queueCalls = countQueueRequests(pool)
      local sampler = matchingSampler()
      local first = pool:request("sprites/icon.png", sampler)
      awaitReady(pool, first)
      local queuedAfterCold = queueCalls()
      Assert.isTrue(queuedAfterCold >= 1, "the cold first pass classifies through the worker")
      local firstLease = pool:acquire(first)
      pool:release(firstLease)
      local decodesAfterCold = decodeCalls()
      local uploadsAfterCold = #graphics.created
      local second = pool:request("sprites/icon.png", sampler)
      local status = pool:poll(second)
      Assert.equal(status, "ready", "a resident revisit is ready without another worker roundtrip")
      Assert.equal(queueCalls(), queuedAfterCold, "the resident revisit files no new worker job")
      local secondLease = pool:acquire(second)
      Assert.equal(decodeCalls(), decodesAfterCold, "the resident revisit decodes no pixels again")
      Assert.equal(#graphics.created, uploadsAfterCold, "the resident revisit uploads no new GPU pair")
      Assert.equal(secondLease.image, firstLease.image, "the revisit borrows the identical still-live image")
      Assert.equal(secondLease.palette, firstLease.palette, "the revisit borrows the identical still-live palette")
      pool:release(secondLease)
      pool:prune()
    end)
  end)
end

-- Two cold tickets for different logical paths with identical decoded
-- pixels resolve one shared physical pair: both polls may complete first,
-- but only one source and palette upload ever happens and both leases
-- borrow the same objects.
function T.concurrent_identical_content_publishes_a_single_physical_pair()
  local png = fixturePng()
  withPool("single-upload", { ["sprites/a.png"] = png, ["sprites/b.png"] = png }, function(pool, graphics)
    local sampler = matchingSampler()
    local firstToken = pool:request("sprites/a.png", sampler)
    local secondToken = pool:request("sprites/b.png", sampler)
    awaitReady(pool, firstToken)
    awaitReady(pool, secondToken)
    local first = pool:acquire(firstToken)
    local second = pool:acquire(secondToken)
    Assert.equal(first.image, second.image, "cold aliases borrow one shared source image")
    Assert.equal(first.palette, second.palette, "cold aliases borrow one shared palette")
    Assert.equal(#graphics.created, 2, "one content identity uploads exactly one source and palette pair")
    pool:release(second)
    Assert.isFalse(first.image.released, "releasing one alias borrower keeps the shared pair alive")
    pool:release(first)
    pool:prune()
    Assert.equal(first.image.releaseCount, 1, "the shared pair is released exactly once")
  end)
end

-- Eviction invalidates every reference to the evicted pair for a ticket
-- that was already consumed: the consumed ticket never reports ready
-- again and never produces a second lease, while a fresh ticket for the
-- same path misses cleanly and uploads a new pair. Tickets that are still
-- held without an acquire are covered separately below.
function T.evicted_entries_leave_no_stale_ready_tickets()
  withPool("no-stale-ready", { ["sprites/icon.png"] = fixturePng() }, function(pool, graphics)
    local sampler = matchingSampler()
    local token = requestReady(pool, "sprites/icon.png", sampler)
    local lease = pool:acquire(token)
    local evictedImage = lease.image
    pool:release(lease)
    pool:prune()
    Assert.isTrue(evictedImage.released, "the returned idle pair is evicted by the prune")
    local pollOk, pollStatus = pcall(pool.poll, pool, token)
    Assert.isTrue(not pollOk or pollStatus ~= "ready", "a consumed ticket never reports a pruned pair ready")
    Assert.throws(function()
      pool:acquire(token)
    end, "a consumed ticket never produces a second lease")
    local fresh = pool:request("sprites/icon.png", sampler)
    awaitReady(pool, fresh)
    local renewed = pool:acquire(fresh)
    Assert.isTrue(renewed.image ~= evictedImage, "reuse after eviction uploads a new physical image")
    Assert.equal(evictedImage.releaseCount, 1, "the evicted pair is released exactly once")
    pool:release(renewed)
    pool:prune()
    Assert.equal(#liveImages(graphics), 0, "reuse after eviction leaves no resident pair behind")
  end)
end

-- A revisit of a released-but-still-resident pair through the same path
-- and sampler stays borrowable across a prune that would otherwise evict
-- it: the live ready ticket keeps its backing alive until its own
-- acquire, which reuses the original pair with no new decode or upload.
-- The same lifecycle runs for the indexed source-plus-palette form and
-- the straight fallback form.
function T.a_released_resident_revisit_stays_borrowable_across_prune()
  local cases = {
    { label = "indexed", formats = { r8 = true } },
    { label = "straight", formats = {} },
  }
  for _, case in ipairs(cases) do
    local cache = freshCache("held-ready-" .. case.label)
    cache:write("sprites/icon.png", fixturePng())
    local graphics = fakeGraphics({ formats = case.formats })
    local pool = owner().new(cache, { graphics = graphics, idleByteLimit = 0 })
    local ok, err = pcall(function()
      local sampler = matchingSampler()
      local seed = pool:acquire(requestReady(pool, "sprites/icon.png", sampler))
      local originalImage = seed.image
      local originalPalette = seed.palette
      local uploadsAfterSeed = #graphics.created
      pool:release(seed)
      local revisit = pool:request("sprites/icon.png", sampler)
      Assert.equal(pool:poll(revisit), "ready", "a resident revisit is ready without new work")
      Assert.equal(#graphics.created, uploadsAfterSeed, "the revisit uploads nothing before prune")
      pool:prune()
      -- The prune above must not free the pair behind the live ticket;
      -- that is proved by the acquire below reusing the original image.
      local lease = pool:acquire(revisit)
      Assert.isFalse(originalImage.released, "pruning kept the pair behind the live ready ticket")
      Assert.equal(lease.image, originalImage, "acquire after prune reuses the original image")
      Assert.equal(#graphics.created, uploadsAfterSeed, "acquire after prune uploads no new pair")
      if case.label == "indexed" then
        Assert.equal(lease.palette, originalPalette, "the indexed revisit keeps its palette")
      else
        Assert.equal(lease.kind, "rgba8", "the fallback revisit stays straight")
      end
      pool:release(lease)
      pool:prune()
      Assert.isTrue(originalImage.released, "balanced release plus prune frees the pair")
      Assert.equal(originalImage.releaseCount, 1, "the pair is released exactly once")
      Assert.equal(#liveImages(graphics), 0, "no resident pair is left behind")
    end)
    local disposeOk, disposeErr = pcall(pool.dispose, pool)
    local removeOk, removeErr = pcall(cache.removeTree, cache, "")
    if not ok then
      error(err, 0)
    end
    Assert.isTrue(disposeOk, "disposal must succeed: " .. tostring(disposeErr))
    Assert.isTrue(removeOk, "fixture cleanup must succeed: " .. tostring(removeErr))
  end
end

-- A worker result that resolves to an already-resident physical identity
-- adopts that pair instead of uploading a duplicate, and the adopting
-- ticket keeps it alive across a prune that would otherwise evict it. A
-- later adopting ticket that is cancelled instead leaves no record behind.
function T.a_worker_result_adopting_a_resident_pair_stays_borrowable_across_prune()
  local cache = freshCache("adopt-resident")
  local graphics = fakeGraphics()
  local function hashForPath(path)
    if path == "sprites/first.png" or path == "sprites/second.png" then
      return "shared-adopted-pixels"
    end
    return "pixels-for-" .. path
  end
  local pool = owner().new(cache, {
    graphics = graphics,
    queue = stubDerivativeQueue(hashForPath),
    idleByteLimit = 0,
  })
  local ok, err = pcall(function()
    local sampler = matchingSampler()
    local seedToken = pool:request("sprites/first.png", sampler, "demand")
    Assert.equal(pool:poll(seedToken), "ready", "synchronous preparation resolves without blocking")
    local seed = pool:acquire(seedToken)
    local originalImage = seed.image
    local uploadsAfterSeed = #graphics.created
    pool:release(seed)
    local adopter = pool:request("sprites/second.png", sampler, "demand")
    Assert.equal(pool:poll(adopter), "ready", "adoption of the resident pair is ready without new work")
    Assert.equal(#graphics.created, uploadsAfterSeed, "adoption uploads no second pair")
    pool:prune()
    -- The prune above must not free the adopted pair; the acquire below
    -- reusing the original image proves it.
    local lease = pool:acquire(adopter)
    Assert.isFalse(originalImage.released, "pruning kept the adopted pair behind the live ticket")
    Assert.equal(lease.image, originalImage, "acquire after prune reuses the adopted pair")
    Assert.equal(#graphics.created, uploadsAfterSeed, "acquire after prune still uploads no second pair")
    pool:release(lease)
    pool:prune()
    Assert.isTrue(originalImage.released, "balanced release plus prune frees the adopted pair")
    Assert.equal(originalImage.releaseCount, 1, "the adopted pair is released exactly once")
    local doomed = pool:request("sprites/second.png", sampler, "demand")
    Assert.equal(pool:poll(doomed), "ready", "a second adoption resolves its pair")
    Assert.isTrue(pool:cancel(doomed), "the second adoption cancels")
    Assert.isFalse(pool:cancel(doomed), "a cancelled adoption cancels only once")
    local stats = pool:stats()
    Assert.equal(stats.ready, 0, "no ready record survives cancellation")
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

-- Two ready tickets for one physical pair plus a live lease keep that
-- pair alive through cancellation, release, and prune in any order:
-- cancelling one ticket never disturbs the other, returning the lease
-- never evicts under the surviving ticket, and disposal after balanced
-- release frees the pair exactly once with no outstanding interest.
function T.two_ready_tickets_and_a_live_lease_balance_across_cancel_and_dispose()
  local otherPng =
    PngWriter.encode(FIXTURE_WIDTH, FIXTURE_HEIGHT, string.char(201, 10, 20, 255) .. string.sub(fixturePixels(), 5))
  withPool("held-pair-balance", {
    ["sprites/shared.png"] = fixturePng(),
    ["sprites/other.png"] = otherPng,
  }, function(pool, graphics)
    local sampler = matchingSampler()
    local seed = pool:acquire(requestReady(pool, "sprites/shared.png", sampler))
    local originalImage = seed.image
    local uploadsAfterSeed = #graphics.created
    local first = pool:request("sprites/shared.png", sampler)
    Assert.equal(pool:poll(first), "ready", "the first held ticket is ready without new work")
    local second = pool:request("sprites/shared.png", sampler)
    Assert.equal(pool:poll(second), "ready", "the second held ticket is ready without new work")
    local pending = pool:request("sprites/other.png", sampler, "prefetch")
    Assert.isTrue(pool:cancel(first), "the first held ticket cancels")
    Assert.isFalse(pool:cancel(first), "a cancelled ticket cancels only once")
    pool:release(seed)
    pool:prune()
    -- The prune above must not free the pair behind the surviving ticket;
    -- the acquire below reusing the original image proves it.
    local lease = pool:acquire(second)
    Assert.isFalse(originalImage.released, "pruning kept the pair behind the surviving ticket")
    Assert.equal(lease.image, originalImage, "the surviving ticket reuses the original image")
    Assert.equal(#graphics.created, uploadsAfterSeed, "no new upload across the hold window")
    pool:release(lease)
    pool:prune()
    Assert.isTrue(originalImage.released, "balanced release plus prune frees the pair")
    Assert.equal(originalImage.releaseCount, 1, "the pair is released exactly once")
    Assert.isTrue(pool:cancel(pending), "the unrelated pending interest cancels")
    Assert.equal(countKeys(pool._requests), 0, "no ticket record survives the settled window")
    local stats = pool:stats()
    Assert.equal(stats.ready, 0, "no ready record survives the settled window")
    Assert.equal(stats.staged, 0, "no staged payload survives the settled window")
    Assert.equal(#liveImages(graphics), 0, "no resident pair is left behind")
  end)
end

-- Thousands of acquire, return, and evict cycles over a fixed path set --
-- mixing direct, alias, and cancelled prepared tickets -- retain no ticket
-- history: after every settled interval no completed record remains and
-- ready/staged census counts are zero, independent of operation count.
function T.long_sessions_retain_only_live_request_metadata()
  local cache = freshCache("bounded-tickets")
  local graphics = fakeGraphics()
  local paths = {
    "sprites/direct-a.png",
    "sprites/direct-b.png",
    "sprites/alias-a.png",
    "sprites/alias-b.png",
    "sprites/direct-c.png",
    "sprites/direct-d.png",
  }
  local function hashForPath(path)
    if path == "sprites/alias-a.png" or path == "sprites/alias-b.png" then
      return "shared-alias-pixels"
    end
    return "pixels-for-" .. path
  end
  local pool = owner().new(cache, {
    graphics = graphics,
    queue = stubDerivativeQueue(hashForPath),
    idleByteLimit = 0,
  })
  local ok, err = pcall(function()
    local sampler = matchingSampler()
    for step = 1, 10000 do
      local path = paths[(step - 1) % #paths + 1]
      local token = pool:request(path, sampler, "demand")
      local status = pool:poll(token)
      Assert.equal(status, "ready", "synchronous preparation resolves without blocking")
      if step % 7 == 0 then
        Assert.isTrue(pool:cancel(token), "prepared-but-unclaimed interest cancels")
      else
        local lease = pool:acquire(token)
        pool:release(lease)
        pool:prune()
      end
      if step % 1000 == 0 then
        Assert.equal(countKeys(pool._requests), 0, "no completed-ticket record survives a settled interval")
        local settled = pool:stats()
        Assert.equal(settled.ready, 0, "no ready-ticket history survives a settled interval")
        Assert.equal(settled.staged, 0, "no staged-payload history survives a settled interval")
      end
    end
    Assert.equal(countKeys(pool._requests), 0, "thousands of cycles retain no ticket history")
    local stats = pool:stats()
    Assert.equal(stats.ready, 0, "no ready-ticket history survives thousands of cycles")
    Assert.equal(stats.staged, 0, "no staged-payload history survives thousands of cycles")
    Assert.equal(stats.failed, 0, "no cycle failed")
    local residentAliases = 0
    if type(pool._residentByLogical) == "table" then
      residentAliases = countKeys(pool._residentByLogical)
    end
    Assert.isTrue(
      residentAliases <= #paths,
      "resident alias entries stay bounded by distinct paths, not by operation count"
    )
    pool:prune()
  end)
  local disposeOk, disposeErr = pcall(pool.dispose, pool)
  local removeOk, removeErr = pcall(cache.removeTree, cache, "")
  if not ok then
    error(err, 0)
  end
  Assert.isTrue(disposeOk, "disposal after thousands of cycles must succeed: " .. tostring(disposeErr))
  Assert.isTrue(removeOk, "fixture cleanup must succeed: " .. tostring(removeErr))
end

-- GPU upload belongs to the consuming acquire, never to the readiness
-- probe: a doomed upload of distinct content still polls ready, then acquire
-- reports the failure, releases exactly the pair it partially created, and
-- leaves the unrelated live pair drawable. Retry afterwards uploads a fresh
-- pair for its distinct content while the live pair stays intact.
function T.upload_failures_surface_at_acquire_leaving_live_pairs_intact()
  local png = fixturePng()
  local fragilePng =
    PngWriter.encode(FIXTURE_WIDTH, FIXTURE_HEIGHT, string.char(201, 10, 20, 255) .. string.sub(fixturePixels(), 5))
  withIdlePool(
    "acquire-failure",
    { ["sprites/steady.png"] = png, ["sprites/fragile.png"] = fragilePng },
    1024 * 1024,
    function(pool, graphics)
      local sampler = matchingSampler()
      local steady = pool:acquire(requestReady(pool, "sprites/steady.png", sampler))
      local baseline = #graphics.created
      Assert.equal(baseline, 2, "an indexed realization stages one source and palette pair")
      local doomed = pool:request("sprites/fragile.png", sampler)
      graphics.failOnCall = baseline + 2
      local status = pool:poll(doomed)
      while status == "pending" do
        love.timer.sleep(0.005)
        status = pool:poll(doomed)
      end
      Assert.equal(status, "ready", "upload work waits for the consuming acquire instead of failing inside poll")
      local acquireOk, _ = pcall(pool.acquire, pool, doomed)
      Assert.isFalse(acquireOk, "the failed upload surfaces through acquire")
      Assert.throws(function()
        pool:poll(doomed)
      end, "a failed acquire consumes its ticket")
      for _, image in ipairs(graphics.created) do
        local held = image == steady.image or image == steady.palette
        Assert.isTrue(image.released or held, "a failed acquire leaves no orphaned GPU object behind")
      end
      local failedSource = graphics.created[baseline + 1]
      Assert.notNil(failedSource, "the failed upload created its source before failing")
      Assert.equal(failedSource.releaseCount, 1, "the failed source is released exactly once")
      Assert.isFalse(steady.image.released, "the failure never evicts the unrelated live image")
      Assert.isFalse(steady.palette.released, "the failure never evicts the unrelated live palette")
      graphics.failOnCall = nil
      local retried = pool:acquire(requestReady(pool, "sprites/fragile.png", sampler))
      Assert.isTrue(retried.image ~= steady.image, "retry uploads a fresh pair for its distinct content")
      Assert.isFalse(retried.image.released, "the retried distinct pair stays drawable")
      Assert.isFalse(steady.image.released, "the live pair stays drawable beside the retry")
      pool:release(steady)
      pool:release(retried)
      pool:prune()
      Assert.equal(#liveImages(graphics), 4, "both distinct pairs rest idle after balanced release")
    end
  )
end

-- Cancelling prepared-but-unclaimed interest drops its payload before any
-- GPU object exists: the token never resolves afterwards, census counts
-- stay clean, and a sibling request for the same path still resolves.
function T.cancelling_prepared_interest_builds_no_gpu_objects()
  withPool("cancel-prepared", { ["sprites/a.png"] = fixturePng() }, function(pool, graphics)
    local uploadsBefore = #graphics.created
    local token = pool:request("sprites/a.png", matchingSampler(), "prefetch")
    awaitReady(pool, token)
    Assert.isTrue(pool:cancel(token), "prepared-but-unclaimed interest cancels")
    Assert.equal(#graphics.created, uploadsBefore, "cancelling prepared interest uploads nothing")
    Assert.throws(function()
      pool:poll(token)
    end, "a cancelled prepared token never resolves")
    local stats = pool:stats()
    Assert.equal(stats.ready, 0, "no ready record survives cancellation")
    Assert.equal(stats.staged, 0, "no staged payload survives cancellation")
    local kept = requestReady(pool, "sprites/a.png", matchingSampler(), "demand")
    local lease = pool:acquire(kept)
    Assert.isTrue(lease.image ~= nil, "a sibling request still resolves after a prepared cancellation")
    pool:release(lease)
    pool:prune()
  end)
end

return { tests = T }
