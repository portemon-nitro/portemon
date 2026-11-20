-- Title build lifecycle: a staged title build that is abandoned while one
-- preparation ticket is outstanding drops that interest before it disposes the
-- scene it had already started, so the session-scoped queue never keeps an
-- unclaimed packet charged to its ready budget. Model, renderer, and asset
-- collaborators are narrow recording doubles; no graphics, generated cache, or
-- ROM is required.

local Assert = require("tests.support.Assert")
local FakePreparationQueue = require("tests.support.FakePreparationQueue")

local TITLE_MODULE = "libs.hgss.src.presentation.HgssTitleScene"
local DOUBLE_NAMES = {
  "libs.assets.src.StartupAssetCache",
  "libs.hgss.src.presentation.GpuAssetPool",
  "libs.hgss.src.presentation.FieldRenderer",
  "libs.hgss.src.ui.FieldTextRenderer",
  "libs.hgss.src.presentation.ModelDefinition",
  "libs.hgss.src.presentation.ModelInstance",
  "libs.ui.src.DisplayContext",
}

local TITLE_GEOMETRY = "assets/generated/models/title-legend.g4mdl"

-- Recording doubles for the staged construction: the first model bank reaches
-- the preparation await, so the build suspends on its ticket before any GPU
-- object exists. Disposals record their own entry so the exit order is visible.
---@param log string[]
local function makeDoubles(log)
  local rec = { pools = {} }
  local startupAssetCache = {}
  function startupAssetCache.loadTitle()
    local descriptor = { kind = "nitro-dynamic", animations = {}, materials = {}, dynamic = {} }
    return {
      model = descriptor,
      clips = {},
      sparkle = { model = descriptor, clips = {} },
      surfaces = {},
      timeline = {},
      lighting = {},
      prompt = {},
    }
  end
  local poolModule = {}
  function poolModule.new()
    local pool = setmetatable({ releaseCount = 0 }, {})
    function pool:preparedMesh(_reference, await)
      await("g4gx", TITLE_GEOMETRY)
      error("the title build realizes a mesh only after its bank is prepared", 0)
    end
    function pool:release()
      self.releaseCount = self.releaseCount + 1
      log[#log + 1] = "pool-release"
    end
    rec.pools[#rec.pools + 1] = pool
    return pool
  end
  local fieldRendererModule = {}
  function fieldRendererModule.new()
    return { release = function() end }
  end
  local textRendererModule = {}
  function textRendererModule.new()
    return { release = function() end }
  end
  local definitionModule = {}
  function definitionModule.fromNitroDescriptor(_descriptor, opts)
    return {
      key = opts and opts.key,
      animations = {},
      materials = {},
      meshes = { { id = "title-mesh", geometry = TITLE_GEOMETRY } },
    }
  end
  local instanceModule = {}
  function instanceModule.new()
    return { play = function() end, evaluatePose = function() end }
  end
  local displayContextModule = {}
  function displayContextModule.new()
    return {}
  end
  return rec,
    {
      ["libs.assets.src.StartupAssetCache"] = startupAssetCache,
      ["libs.hgss.src.presentation.GpuAssetPool"] = poolModule,
      ["libs.hgss.src.presentation.FieldRenderer"] = fieldRendererModule,
      ["libs.hgss.src.ui.FieldTextRenderer"] = textRendererModule,
      ["libs.hgss.src.presentation.ModelDefinition"] = definitionModule,
      ["libs.hgss.src.presentation.ModelInstance"] = instanceModule,
      ["libs.ui.src.DisplayContext"] = displayContextModule,
    }
end

---@param fn fun(rec: { pools: table[] }, log: string[])
local function withDoubles(fn)
  local log = {}
  local rec, doubles = makeDoubles(log)
  local saved = {}
  for _, name in ipairs(DOUBLE_NAMES) do
    saved[name] = package.loaded[name]
    package.loaded[name] = doubles[name]
  end
  package.loaded[TITLE_MODULE] = nil
  local ok, err = pcall(fn, rec, log)
  for _, name in ipairs(DOUBLE_NAMES) do
    package.loaded[name] = saved[name]
  end
  package.loaded[TITLE_MODULE] = nil
  if not ok then
    error(err, 0)
  end
end

local function requireTitle()
  local ok, mod = pcall(require, TITLE_MODULE)
  Assert.isTrue(ok, "the title scene owns its staged build: " .. tostring(mod))
  return assert(mod)
end

-- One build suspended on its first model bank, with the queue's cancellation
-- recorded beside the scene disposals so an exit can prove what it did first.
---@param log string[]
---@return HgssTitleScene.Build build
---@return FakePreparationQueue queue
---@return integer token outstanding ticket the build is suspended on
local function suspendedBuild(log)
  local queue = FakePreparationQueue.new({ deferred = true, payloadBytes = 2048 })
  local cancelInterest = queue.cancel
  function queue:cancel(token)
    log[#log + 1] = "cancel"
    return cancelInterest(self, token)
  end
  local build = requireTitle().begin({
    versionId = "heartgold",
    cacheFs = { loadLua = function() end },
    width = 256,
    height = 192,
    graphics = {},
    assetPreparation = queue,
  })
  Assert.equal(build:advance(1), 0, "a pending title bank consumes no work unit")
  Assert.isFalse(build:isReady(), "the title build waits for the worker")
  Assert.equal(#queue.requests, 1, "the title build requests its first model bank")
  Assert.equal(queue.requests[1].kind, "g4gx", "title geometry arrives as a model bank")
  local token = assert(queue.requests[1].token)
  Assert.isTrue(queue:publish(token), "the worker publishes the pending bank")
  Assert.equal(queue.readyBytes, 2048, "the published packet is charged to the ready budget")
  return build, queue, token
end

---@param log string[]
---@param first string event that must happen first
---@param second string event that must happen after it
local function assertEventOrder(log, first, second)
  local firstAt, secondAt
  for index, entry in ipairs(log) do
    firstAt = firstAt or (entry == first and index or nil)
    secondAt = secondAt or (entry == second and index or nil)
  end
  Assert.isTrue(firstAt ~= nil and secondAt ~= nil, first .. " and " .. second .. " both happen")
  Assert.isTrue(firstAt < secondAt, first .. " happens before " .. second)
end

local T = {}

-- A queue fault while the title build is suspended on one bank fails the build:
-- it cancels that ticket exactly once, only then disposes the scene it had
-- started, and transfers nothing.
function T.title_build_failure_drops_its_outstanding_ticket_before_dispose()
  withDoubles(function(rec, log)
    local build, queue, token = suspendedBuild(log)
    queue:failPoll("preparation queue reply is malformed")
    local advanced, advanceErr = pcall(build.advance, build, 1)
    Assert.isFalse(advanced, "a queue fault fails the title build")
    Assert.isTrue(
      tostring(advanceErr):find("preparation queue reply is malformed", 1, true) ~= nil,
      "the queue cause propagates instead of a cancellation error"
    )
    Assert.equal(#queue.cancelCalls, 1, "the failed build cancels its outstanding ticket exactly once")
    Assert.equal(queue.cancelCalls[1], token, "the failed build cancels the ticket it was suspended on")
    Assert.equal(queue.readyBytes, 0, "the failed build leaves no ready payload charged")
    assertEventOrder(log, "cancel", "pool-release")
    Assert.equal(rec.pools[1].releaseCount, 1, "the failed build disposes its pool exactly once")
    local okTake = pcall(build.takeResult, build)
    Assert.isFalse(okTake, "a failed title build transfers no scene")
    local failedAgain = pcall(build.advance, build, 1)
    Assert.isFalse(failedAgain, "the failure stays sticky")
    Assert.equal(#queue.cancelCalls, 1, "later advances never cancel the same ticket twice")
    build:release()
    Assert.equal(#queue.cancelCalls, 1, "release after failure cancels nothing twice")
    Assert.equal(rec.pools[1].releaseCount, 1, "release after failure never disposes the pool twice")
  end)
end

-- Releasing a suspended title build (the launcher backing out before the title
-- arrives) drops the same interest exactly once and disposes the started scene.
function T.title_build_release_drops_its_outstanding_ticket_before_dispose()
  withDoubles(function(rec, log)
    local build, queue, token = suspendedBuild(log)
    build:release()
    build:release()
    Assert.equal(#queue.cancelCalls, 1, "release cancels the outstanding ticket exactly once")
    Assert.equal(queue.cancelCalls[1], token, "release cancels the ticket the build was suspended on")
    Assert.equal(queue.readyBytes, 0, "the released build leaves no ready payload charged")
    assertEventOrder(log, "cancel", "pool-release")
    Assert.equal(rec.pools[1].releaseCount, 1, "the released build disposes its pool exactly once")
    Assert.isFalse(build:isReady(), "a released title build never becomes ready")
    local okTake = pcall(build.takeResult, build)
    Assert.isFalse(okTake, "a released title build transfers no scene")
  end)
end

return { tests = T }
