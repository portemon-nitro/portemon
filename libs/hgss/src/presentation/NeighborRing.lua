-- Loads the presentation-only neighbour ring from the derived cache into GPU
-- draws. The ring is planned and compiled upstream (libs/assets NeighborPlan +
-- MapAssetCompiler), which digests the eight surrounding matrix cells into
-- scene.neighbors -- one descriptor per drawn cell carrying its 32-tile offset,
-- terrain batches (content-addressed .g4mesh paths), and scene-form materials.
-- load() reads those assets through the shared GpuAssetPool (one persistent
-- Mesh per unique geometry path, one Image per unique texture/wrap sampler
-- state, deduplicated across cells), and bakes each cell's world offset into
-- the draw transform while retaining each mesh's model-space sort center.
-- Material wrap resolution lives in
-- SceneDescriptor; each geometry path's sort center is the pool mesh
-- entry's cached model-space center. All GPU construction happens here, once;
-- the pool releases every owned mesh/image. Load is transactional: the whole
-- build runs inside pool:build(), so a failure -- including a malformed
-- cell descriptor or a terrain-animator construction failure -- releases
-- every GPU object the construction acquired.
-- Terrain animation spans the whole ring: one TerrainMaterialAnimator over
-- every cell's { record, runtime } bindings (the original descriptor records
-- are referenced directly -- cell material ids repeat per cell but nothing
-- needs a global id space) plays the central scene's area texture-SRT clip
-- -- passed as `opts.textureSrt`, the central scene owns the clip -- and
-- the shared per-name texture-swap clocks with one stepIndex/ticksInStep
-- pair per animation name across all cells, all step images acquired inside
-- the ring's own pool build. ring:updateAnimated() advances that one
-- animator; empty neighbours keep it a safe no-op. Neighbours are additive:
-- an empty descriptor list yields no draws and the central scene is
-- untouched.

local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local FixedPoint = require("libs.math.src.FixedPoint")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local SynchronousWait = require("libs.hgss.src.presentation.SynchronousWait")
local TerrainMaterialAnimator = require("libs.hgss.src.presentation.TerrainMaterialAnimator")

local NeighborRing = {}

-- Neighbor draws are translation-only, so every neighbor item shares the
-- same immutable identity normal transform.
local IDENTITY_MODEL_NORMAL = Matrix3.identity()

-- Private staged-work sentinel: the build coroutine yields WAIT while a
-- shared image is still pending. WAIT consumes no work budget; only a
-- checkpoint yield of 1 charges one unit. This mirrors MapSceneLoader's
-- BuildTask semantics without depending on it.
local WAIT = {}

-- Material assembly: acquire each normalized material record's sampling
-- handle under its resolved sampler wrap. The wrap pair is part of the
-- handle identity, so cells sharing a texture but sampling it differently get
-- independent handles, and the handle's image/palette/indexed fields ride
-- the material table so the renderer's shared sampler binds indexed sources
-- through their exact palette. The terrain animator initializes every
-- material's texMatrix at construction. `wait` yields the staged checkpoint
-- while a shared image is still pending; `checkpoint` charges one bounded
-- main-thread work unit after each acquisition.
---@param list table[]
---@param pool GpuAssetPool
---@param wait fun()
---@param checkpoint fun()
---@return table<number, table<string, unknown>> runtime materials by material id
local function materialsById(list, pool, wait, checkpoint)
  local byId = {}
  for id, record in pairs(SceneDescriptor.materials(list)) do
    local wrap = SceneDescriptor.wrap(record)
    local handle = pool:sharedImage(record.texture, wrap.x, wrap.y, wait)
    byId[id] = {
      id = record.id,
      name = record.name,
      image = handle and handle.image or nil,
      palette = handle and handle.palette or nil,
      indexed = handle and handle.indexed or nil,
      wrap = wrap,
    }
    checkpoint()
  end
  return byId
end

-- Build the ring against an already-created pool, inside the staged task
-- begin() opens. Raises on any failure; the owning task releases the pool
-- in that case. Draws carry no submission numbers: the final scene assembly
-- queue traversal orders every part and draw in source order, positionally. The
-- draw-state field set is the shared PolygonState schema the compiler emits on every batch
-- (lightMask included), with polygonAlpha normalized to the renderer's 0..1
-- unit. `clip` is the central scene's compiled texture-SRT clip (or false),
-- owned by the central scene: the ring never selects a clip per neighbour.
-- When the pool borrows the session image owner, every texture resolves to
-- the same pooled lease the scene loader borrows, and the ring holds no
-- image reference after release.
---@param pool GpuAssetPool
---@param descriptors table[]
---@param clip table<string, unknown>|false
---@param wait fun() staged checkpoint yielded while a shared image is pending
---@param checkpoint fun() charges one bounded main-thread work unit
---@param acquireMesh fun(geometry: string|ModelAsset.GeometryReference): table<string, unknown>
---@return table<string, unknown> ring with draws, stats, updateAnimated, release
local function buildRing(pool, descriptors, clip, wait, checkpoint, acquireMesh)
  -- One draw per (cell, batch), with the cell's 32-tile world offset baked into
  -- the transform only -- the mesh center stays in model space for queue
  -- sorting -- and one { record, runtime } binding per source material: the
  -- original descriptor records are immutable and are referenced directly,
  -- so no synthetic id space is needed.
  local draws = {}
  local bindings = {}
  for _, cell in ipairs(descriptors) do
    local ox, oy, oz = cell.offsetTilesX, cell.offsetTilesY, cell.offsetTilesZ
    local transform = Matrix4.translate(ox, oy, oz)
    local materials = materialsById(cell.materials, pool, wait, checkpoint)
    for _, record in ipairs(cell.materials) do
      bindings[#bindings + 1] = {
        record = record,
        runtime = assert(
          materials[record.id],
          "no runtime material table for neighbor material id " .. tostring(record.id)
        ),
      }
    end
    for _, batch in ipairs(cell.batches) do
      local entry = acquireMesh(batch.geometry)
      local c = entry.center
      local draw = {
        cullMode = batch.cullMode,
        polygonMode = batch.polygonMode,
        polygonId = batch.polygonId,
        translucentDepthWrite = batch.translucentDepthWrite,
        depthEqual = batch.depthEqual,
        lightMask = batch.lightMask,
        polygonAlpha = batch.polygonAlpha / FixedPoint.RGB5_MAX,
        alphaClass = batch.alphaClass,
        fogEnabled = batch.fogEnabled,
      }
      draw.mesh = entry.mesh
      draw.material = materials[batch.material]
      draw.transform = transform
      draw.modelNormal = IDENTITY_MODEL_NORMAL
      draw.center = c
      -- The cached model-space AABB of this geometry path, shared by every
      -- cell draw of the same path: the render queue projects it for its
      -- automatic screen-Y ordering without rescanning vertices per draw.
      draw.sortBounds = entry.bounds
      draws[#draws + 1] = draw
      checkpoint()
    end
  end

  -- One terrain animator across every cell, constructed unconditionally: all
  -- cells share the area SRT player and one stepIndex/ticksInStep pair per
  -- texture-swap name, every step image is acquired inside this build
  -- (deduplicated per path/wrap through the pool) before the transaction
  -- commits, and construction initializes every cell material's static
  -- texMatrix. ring:updateAnimated() stays a safe no-op on empty rings.
  local terrainAnimator = TerrainMaterialAnimator.new(bindings, clip or false, function(path, wrapX, wrapY)
    return pool:sharedImage(path, wrapX, wrapY, wait)
  end, checkpoint)

  local ring = {
    draws = draws,
    stats = {
      cellCount = #descriptors,
      meshCount = #pool.meshes,
      textureCount = pool:textureCount(),
    },
  }
  function ring:updateAnimated()
    terrainAnimator:updateFixed()
  end
  function ring:release()
    pool:release()
  end
  return ring
end

-- One resumable neighbor-ring build. The task owns its pool and its
-- outstanding preparation ticket until the completed ring is transferred or
-- the task is cancelled/failed. `advance` executes bounded main-thread work and
-- yields promptly (consuming no work unit) while the preparation worker is
-- still busy; `finish` is the explicitly blocking path for synchronous
-- callers. A failure releases everything the task acquired and cancels its
-- outstanding ticket exactly once, and stays loud on every later call.
---@class NeighborRing.BuildTask
---@field _pool GpuAssetPool
---@field _thread thread
---@field _state string "active", "ready", "transferred", "released", or "failed"
---@field _poolReleased boolean
---@field _queue table<string, unknown>? borrowed preparation queue
---@field _decoded table<string, unknown>? borrowed selected decoded CPU owner
---@field _outstanding integer? preparation token the suspended coroutine waits on
---@field _transfer table<string, unknown>? kernel lease a take or wait transferred but the build has not consumed
---@field _stashed table<integer, table<string, unknown>>? waited leases by token, consumed by the resumed coroutine
---@field _finishing boolean the explicit synchronous caller blocks instead of yielding
---@field _result table<string, unknown>?
---@field _failed unknown?
local NeighborBuildTask = {}
NeighborBuildTask.__index = NeighborBuildTask

---@param task NeighborRing.BuildTask
---@param err unknown
local function failBuildTask(task, err)
  if task._state == "active" then
    task._state = "failed"
    local token = task._outstanding
    task._outstanding = nil
    if token ~= nil and task._queue ~= nil then
      -- Cancellation must not mask the original failure (the queue may
      -- already be gone when unwinding through layered releases).
      pcall(task._queue.cancel, task._queue, token)
    end
    task:returnPreparedLeases()
    if not task._poolReleased then
      task._poolReleased = true
      task._pool:release()
    end
  end
  task._failed = err
  error(err, 0)
end

---@param maxWorkUnits integer main-thread work budget for this advance
---@return integer consumed work units within the caller budget
function NeighborBuildTask:advance(maxWorkUnits)
  if self._failed ~= nil then
    error(self._failed, 0)
  end
  assert(self._state == "active" or self._state == "ready", "neighbor build task is no longer active")
  assert(
    type(maxWorkUnits) == "number" and maxWorkUnits >= 0 and maxWorkUnits % 1 == 0,
    "neighbor advance requires non-negative integer work units"
  )
  if self._state == "ready" or maxWorkUnits == 0 then
    return 0
  end
  local consumed = 0
  while consumed < maxWorkUnits and self._state == "active" do
    local ok, yielded = coroutine.resume(self._thread)
    if not ok then
      failBuildTask(self, yielded)
    end
    if coroutine.status(self._thread) == "dead" then
      self._result = assert(yielded, "neighbor build returned no runtime")
      self._state = "ready"
    else
      -- WAIT means a shared image is still pending: return promptly
      -- without consuming a work unit, exactly like MapSceneLoader.
      if yielded == WAIT then
        break
      end
      assert(yielded == 1, "neighbor build yielded an invalid work unit")
      consumed = consumed + 1
    end
  end
  return consumed
end

---@return boolean
function NeighborBuildTask:isReady()
  return self._state == "ready"
end

---@return table<string, unknown> the completed ring; the runtime map owns its release after transfer
function NeighborBuildTask:takeResult()
  if self._failed ~= nil then
    error(self._failed, 0)
  end
  assert(self._state == "ready", "neighbor build result is not ready")
  local result = assert(self._result)
  self._result = nil
  self._state = "transferred"
  return result
end

-- Finish the build synchronously: the outstanding preparation ticket becomes
-- demand and blocks once for its payload, which the resumed build consumes
-- from the task stash. Later acquisitions while finishing request demand.
-- Only explicit synchronous owners call this; staged map assembly advances
-- cooperatively instead.
---@return table<string, unknown> the completed ring
function NeighborBuildTask:finish()
  if self._failed ~= nil then
    error(self._failed, 0)
  end
  self._finishing = true
  while self._state == "active" do
    -- A coroutine suspended on worker preparation block-waits its
    -- outstanding token instead of polling in a tight loop; the waited
    -- payload is stashed for the resumed build to consume.
    local outstanding = self._outstanding
    if outstanding ~= nil and self._queue ~= nil then
      -- The token stays owned until a wait consumed it: a failed promote or
      -- wait leaves the ticket with the queue, and the task's failure unwind
      -- cancels it.
      local promoteOk, promoteErr = pcall(self._queue.promote, self._queue, outstanding, "demand")
      if not promoteOk then
        failBuildTask(self, promoteErr)
      end
      local ok, payload = pcall(self._queue.wait, self._queue, outstanding)
      if not ok then
        failBuildTask(self, payload)
      end
      self._stashed = self._stashed or {}
      self._stashed[outstanding] = payload
      self._outstanding = nil
    end
    -- A coroutine suspended on a shared image yields without charging a work
    -- unit, so an empty advance means the worker still owes the payload: sleep
    -- instead of hot-polling it.
    if self:advance(1) == 0 then
      SynchronousWait.block()
    end
  end
  return self:takeResult()
end

-- Release the task: a pending build returns its borrows and drops pending
-- interest; after transfer the ring owns its release, so this is a no-op.
-- Idempotent, and safe after failure.
function NeighborBuildTask:release()
  if self._state == "transferred" or self._state == "released" or self._state == "failed" then
    return
  end
  self._state = "released"
  self._result = nil
  local token = self._outstanding
  self._outstanding = nil
  if token ~= nil and self._queue ~= nil then
    -- Release stays infallible even if the queue is already gone.
    pcall(self._queue.cancel, self._queue, token)
  end
  self:returnPreparedLeases()
  if not self._poolReleased then
    self._poolReleased = true
    self._pool:release()
  end
end

-- Return every decoded lease this task transferred out of the queue but whose
-- GPU realization has not consumed it yet: the in-flight transfer and any
-- lease the finishing wait stashed for a build that never resumed.
function NeighborBuildTask:returnPreparedLeases()
  local decoded = self._decoded
  if decoded == nil then
    return
  end
  local transfer = self._transfer
  self._transfer = nil
  if transfer ~= nil then
    decoded:returnLease(transfer)
    decoded:trim()
  end
  local stashed = self._stashed
  self._stashed = nil
  if stashed ~= nil then
    for _, lease in pairs(stashed) do
      decoded:returnLease(lease)
      decoded:trim()
    end
  end
end

-- Begin one resumable neighbor-ring build. The task owns a fresh pool until
-- the completed ring is transferred or the task is cancelled/failed.
-- `cacheFs` is a CacheFs.forVersion; `descriptors` is scene.neighbors;
-- `opts` passes through to the asset pool (injectable graphics for headless
-- tests), `opts.textureSrt` carries the central scene's compiled texture-SRT
-- clip (false/nil = no area animation), and `opts.assetPreparation` routes
-- geometry decode through the preparation worker exactly like the central
-- scene build.
---@param cacheFs table<string, unknown>
---@param descriptors table[]
---@param opts { graphics?: GpuAssetPool.Graphics, textureSrt?: table<string, unknown>|false, imageAssets?: table<string, unknown>, assetPreparation?: table<string, unknown>, decoded?: table<string, unknown> }?
---@return NeighborRing.BuildTask
function NeighborRing.begin(cacheFs, descriptors, opts)
  opts = opts or {}
  local pool = GpuAssetPool.new(cacheFs, opts)
  local queue = opts.assetPreparation
  local function waitShared()
    coroutine["yield"](WAIT)
  end
  local function checkpoint()
    coroutine["yield"](1)
  end
  -- Geometry arrives the same way the central scene's does: the preparation
  -- worker decodes a whole native bank once for every draw the ring selects,
  -- and this build only realizes the prepared upload packets, yielding WAIT
  -- while the worker is still busy. The task owns the outstanding ticket from
  -- the request until the queue consumed it, so finish() can block-wait it and
  -- every failure unwind can cancel it exactly once.
  local meshEntries = {}
  ---@type NeighborRing.BuildTask
  local task
  local function awaitPrepared(kind, path)
    local prepareQueue = assert(queue, "prepared mesh realization requires a preparation queue")
    local priority = task._finishing and "demand" or "prefetch"
    local token = prepareQueue:request(kind, path, priority)
    task._outstanding = token
    while true do
      if task._stashed ~= nil and task._stashed[token] ~= nil then
        -- The finishing wait already consumed the ticket.
        local stashed = task._stashed[token]
        task._stashed[token] = nil
        task._outstanding = nil
        task._transfer = stashed
        return stashed
      end
      local status, failure = prepareQueue:poll(token)
      if status == "ready" then
        local lease = prepareQueue:take(token)
        task._outstanding = nil
        task._transfer = lease
        return lease
      end
      if status == "failed" then
        error("prepared asset " .. tostring(path) .. " (" .. kind .. ") failed: " .. tostring(failure), 0)
      end
      coroutine["yield"](WAIT)
    end
  end
  local function acquireMesh(geometry)
    local entry = meshEntries[geometry]
    if entry == nil then
      if queue ~= nil then
        -- The pool borrows the awaited lease's shared value for the upload;
        -- the task returns that lease immediately afterwards, on success or
        -- failure.
        local realizedOk, realized = pcall(pool.preparedMesh, pool, geometry, awaitPrepared)
        task:returnPreparedLeases()
        if not realizedOk then
          error(realized, 0)
        end
        entry = realized
      else
        entry = pool:meshFor(geometry)
      end
      meshEntries[geometry] = entry
    end
    return entry
  end
  ---@type NeighborRing.BuildTask
  task = setmetatable({
    _pool = pool,
    _state = "active",
    _poolReleased = false,
    _queue = queue,
    _decoded = opts.decoded,
    _outstanding = nil,
    _transfer = nil,
    _stashed = nil,
    _finishing = false,
    _result = nil,
    _failed = nil,
  }, NeighborBuildTask)
  task._thread = coroutine.create(function()
    -- Enroll every distinct neighbor base texture and texture-swap frame
    -- under its immutable wrap state before the first readiness check so
    -- neighbor classification shares the scene's prefetch tickets instead
    -- of running a second enrollment pass.
    if opts.imageAssets ~= nil then
      for _, cell in ipairs(descriptors) do
        for _, record in pairs(SceneDescriptor.materials(cell.materials)) do
          local wrap = SceneDescriptor.wrap(record)
          pool:prefetchShared(record.texture, wrap.x, wrap.y)
          local swap = record.textureSwap
          if type(swap) == "table" and type(swap.steps) == "table" then
            for _, step in ipairs(swap.steps) do
              pool:prefetchShared(step.texture, wrap.x, wrap.y)
            end
          end
        end
      end
    end
    return buildRing(pool, descriptors, opts.textureSrt, waitShared, checkpoint, acquireMesh)
  end)
  return task
end

-- Load the compiled neighbour ring into GPU draw items. This is the
-- explicitly blocking wrapper over the staged task for standalone callers:
-- `cacheFs` is a CacheFs.forVersion; `descriptors` is scene.neighbors;
-- `opts` passes through to the asset pool (injectable graphics for headless
-- tests), `opts.textureSrt` carries the central scene's compiled
-- texture-SRT clip (false/nil = no area animation), and
-- `opts.assetPreparation` routes geometry decode through the preparation
-- worker exactly like the central scene build. Returns
-- { draws, stats, updateAnimated, release }. Any failure -- including a
-- malformed cell descriptor -- releases every GPU object the construction
-- acquired before the error propagates.
---@param cacheFs table<string, unknown>
---@param descriptors table[]
---@param opts { graphics?: GpuAssetPool.Graphics, textureSrt?: table<string, unknown>|false, imageAssets?: table<string, unknown>, assetPreparation?: table<string, unknown>, decoded?: table<string, unknown> }?
---@return table<string, unknown>
function NeighborRing.load(cacheFs, descriptors, opts)
  return NeighborRing.begin(cacheFs, descriptors, opts):finish()
end

return NeighborRing
