-- One-shot prepared field-entry owner for the fresh New Game route. While
-- the Oak intro plays it stages the actual initial runtime map through the
-- authoritative FieldMapLoader (same presentation collaborators the field
-- runtime uses) and retains it without starting field simulation: no
-- session, no actors, no map-entry scripts, no play-time clock. At the Oak
-- handoff the route takes the transfer exactly once and the field runtime
-- claims the identical loader and queue, so the initial load hits the
-- already-resident entry instead of rebuilding the map behind a visible
-- preparation state.

local CacheFs = require("libs.storage.src.CacheFs")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local MapSceneLoader = require("libs.hgss.src.presentation.MapSceneLoader")
local NeighborRing = require("libs.hgss.src.presentation.NeighborRing")
local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")

-- Main-thread scene work advanced per Oak poll: enough to make steady
-- progress at 60Hz without blocking the intro timeline.
local POLL_WORK_UNITS = 8

---@class PreparedFieldEntry
---@field versionId string selected game version, carried for transfer validation
---@field location { mapSymbol: string, fieldX: integer, fieldZ: integer, facing: string } immutable opening identity
---@field _derivedAssets table<string, function> borrowed semantic derived-asset host
---@field _cacheFs table<string, unknown>? injected cache filesystem (production defaults to the version cache)
---@field _injectedQueue table<string, unknown>? adopted queue for fixture-driven tests (production builds its own)
---@field _imageAssets table<string, unknown>? session image owner adopted from options or built alongside the queue; moved exactly once on take
---@field _ownsImageAssets boolean true only when this entry built the image owner itself
---@field _sceneLoader table<string, unknown>? injected scene owner (production uses the presentation scene loader)
---@field _neighborLoader table<string, unknown>? injected neighbor owner (production uses the neighbor ring)
---@field _queue table<string, unknown>? owned preparation worker, present until take/dispose
---@field _loader FieldMapLoader? owned runtime-map assembler, present until take/dispose
---@field _task table<string, unknown>? outstanding staged load, present while preparation advances
---@field _ready boolean
---@field _failure unknown?
---@field _taken boolean
---@field _disposed boolean
local PreparedFieldEntry = {}
PreparedFieldEntry.__index = PreparedFieldEntry

---@param options { versionId: string, derivedAssets: table<string, function>, location: table<string, unknown>, cacheFs?: table<string, unknown>, sceneLoader?: table<string, unknown>, neighborLoader?: table<string, unknown>, assetPreparation?: table<string, unknown>, imageAssets?: table<string, unknown> }
---@return PreparedFieldEntry
function PreparedFieldEntry.new(options)
  assert(type(options) == "table", "prepared field entry requires its composition")
  local versionId = options.versionId
  assert(type(versionId) == "string" and versionId ~= "", "prepared field entry requires its selected version")
  local derivedAssets = options.derivedAssets
  assert(type(derivedAssets) == "table", "prepared field entry requires its borrowed derived host")
  local location = options.location
  assert(type(location) == "table", "prepared field entry requires its opening location")
  assert(type(location.mapSymbol) == "string", "prepared field entry requires a mapped opening location")
  assert(
    type(location.fieldX) == "number" and location.fieldX % 1 == 0,
    "prepared field entry requires an integer opening field position"
  )
  assert(
    type(location.fieldZ) == "number" and location.fieldZ % 1 == 0,
    "prepared field entry requires an integer opening field position"
  )
  return setmetatable({
    versionId = versionId,
    location = {
      mapSymbol = location.mapSymbol,
      fieldX = location.fieldX,
      fieldZ = location.fieldZ,
      facing = location.facing,
    },
    _derivedAssets = derivedAssets,
    _cacheFs = options.cacheFs,
    _sceneLoader = options.sceneLoader,
    _neighborLoader = options.neighborLoader,
    _injectedQueue = options.assetPreparation,
    _imageAssets = options.imageAssets,
    _ownsImageAssets = false,
    _queue = nil,
    _loader = nil,
    _task = nil,
    _ready = false,
    _failure = nil,
    _taken = false,
    _disposed = false,
  }, PreparedFieldEntry)
end

---@private releases owned resources in runtime teardown order: loader before queue
function PreparedFieldEntry:_releaseOwned()
  local loader = self._loader
  local queue = self._queue
  local imageAssets = self._ownsImageAssets and self._imageAssets or nil
  self._loader = nil
  self._queue = nil
  self._imageAssets = nil
  self._ownsImageAssets = false
  self._task = nil
  if loader ~= nil then
    loader:release()
  end
  -- The session image owner is disposed after every scene lease has been
  -- returned through the loader release above. An adopted owner stays
  -- with its composer.
  if imageAssets ~= nil then
    imageAssets:dispose()
  end
  if queue ~= nil then
    queue:release()
  end
end

---@private builds the owned presentation loader on first poll; failures are terminal
---@return boolean built
function PreparedFieldEntry:_ensureLoader()
  if self._loader ~= nil then
    return true
  end
  local cacheFs = self._cacheFs
  if cacheFs == nil then
    local okFs, fsOrError = pcall(CacheFs.forVersion, self.versionId)
    if not okFs then
      self._failure = fsOrError
      return false
    end
    cacheFs = fsOrError
  end
  local okWorld, worldOrError = pcall(function()
    return assert(
      cacheFs:loadLua(MapAssetCache.worldPath()),
      "field world metadata is unavailable although entry preparation is running"
    )
  end)
  if not okWorld then
    self._failure = worldOrError
    return false
  end
  local queue = self._injectedQueue
  local ownsQueue = queue == nil
  if queue == nil then
    queue = AssetPreparationQueue.new(cacheFs)
  end
  -- The session image owner borrows the worker above -- an injected owner
  -- is adopted (its composer keeps disposal), while the default
  -- scene-loader path builds the production owner here so the prepared
  -- bedroom borrows it before the first scene starts. Either way the
  -- entry moves one worker, never two, on take.
  if self._imageAssets == nil and self._sceneLoader == nil then
    local okPool, poolOrError = pcall(ImageAssetPool.new, cacheFs, { queue = queue })
    if not okPool then
      if ownsQueue then
        pcall(function()
          queue:release()
        end)
      end
      self._failure = poolOrError
      return false
    end
    self._imageAssets = poolOrError
    self._ownsImageAssets = true
  end
  local okLoader, loaderOrError = pcall(FieldMapLoader.new, cacheFs, worldOrError, {
    sceneLoader = self._sceneLoader or MapSceneLoader,
    neighborLoader = self._neighborLoader or NeighborRing,
    assetPreparation = queue,
    imageAssets = self._imageAssets,
    derivedAssets = self._derivedAssets,
  })
  if not okLoader then
    -- Only the worker built here is owned here; an adopted queue is still
    -- the composer's to release.
    if ownsQueue then
      pcall(function()
        queue:release()
      end)
    end
    self._failure = loaderOrError
    return false
  end
  self._queue = queue
  self._loader = loaderOrError
  return true
end

-- Advances preparation without blocking: nonblocking location demand first,
-- then bounded staged scene work once the derived closure is ready. A
-- terminal preparation failure is sticky and surfaces here; it is never
-- retried into a second post-Oak loader.
---@param urgency string? derived demand urgency while the staged load is not yet started
---@return boolean ready
---@return unknown? failure
function PreparedFieldEntry:poll(urgency)
  if self._disposed then
    return false
  end
  if self._failure ~= nil then
    return false, self._failure
  end
  if self._ready then
    return true
  end
  if not self:_ensureLoader() then
    return false, self._failure
  end
  local loader = assert(self._loader)
  local location = self.location
  if self._task == nil then
    local position = loader:globalPosition(location.mapSymbol, location.fieldX, location.fieldZ)
    local ready, failure = loader:requestLocation(location.mapSymbol, position.x, position.z, urgency or "near")
    if failure ~= nil then
      self._failure = failure
      self:_releaseOwned()
      return false, self._failure
    end
    if not ready then
      return false
    end
    local okTask, taskOrError = pcall(loader.beginLoad, loader, location.mapSymbol)
    if not okTask then
      self._failure = taskOrError
      self:_releaseOwned()
      return false, self._failure
    end
    self._task = taskOrError
  end
  local task = assert(self._task)
  local okAdvance, advanceErr = pcall(task.advance, task, POLL_WORK_UNITS)
  if not okAdvance then
    self._failure = advanceErr
    self:_releaseOwned()
    return false, self._failure
  end
  if not task:isReady() then
    return false
  end
  task:takeResult()
  self._task = nil
  self._ready = true
  return true
end

---@return boolean
function PreparedFieldEntry:isReady()
  return self._ready == true and self._failure == nil and not self._disposed
end

-- Takes the one-shot ownership transfer for the field runtime. The entry
-- keeps nothing; disposing it afterwards is a no-op.
---@return table<string, unknown> transfer with claim/dispose lifetime
function PreparedFieldEntry:take()
  assert(not self._disposed, "prepared field entry is disposed")
  assert(self._failure == nil, "prepared field entry failed")
  assert(self._ready, "prepared field entry is not ready")
  assert(not self._taken, "prepared field entry is already taken")
  self._taken = true
  local loader = assert(self._loader)
  local queue = assert(self._queue)
  -- The session image owner moves with the loader even when the entry only
  -- adopted it: the entry keeps nothing after take, and a failed claim or
  -- disposition below never touches a scene the runtime already owns.
  local imageAssets = self._imageAssets
  local ownsImageAssets = self._ownsImageAssets
  self._loader = nil
  self._queue = nil
  self._imageAssets = nil
  self._ownsImageAssets = false
  self._task = nil
  local transfer = {
    versionId = self.versionId,
    location = {
      mapSymbol = self.location.mapSymbol,
      fieldX = self.location.fieldX,
      fieldZ = self.location.fieldZ,
      facing = self.location.facing,
    },
    _mapLoader = loader,
    _assetPreparation = queue,
    _imageAssets = imageAssets,
    _ownsImageAssets = ownsImageAssets,
    _claimed = false,
    _released = false,
  }
  -- Claims the owned loader, queue, and image owner into the field runtime
  -- exactly once. The expected version and map identity must match the
  -- prepared entry; a mismatch is a route/data invariant failure, never a
  -- silent rebuild. A failed claim keeps every resource with the transfer
  -- so disposition still releases them.
  ---@param expected { versionId: string, mapSymbol: string }
  ---@return { mapLoader: FieldMapLoader, assetPreparation: table<string, unknown>, imageAssets: table<string, unknown>? }
  function transfer:claim(expected)
    assert(not self._claimed, "prepared field transfer is already claimed")
    assert(not self._released, "prepared field transfer is released")
    assert(type(expected) == "table", "prepared field claim requires its expected identity")
    assert(expected.versionId == transfer.versionId, "prepared field entry belongs to another version")
    assert(expected.mapSymbol == transfer.location.mapSymbol, "prepared field entry belongs to another map")
    self._claimed = true
    local claimedLoader = self._mapLoader
    local claimedQueue = self._assetPreparation
    local claimedImageAssets = self._imageAssets
    self._mapLoader = nil
    self._assetPreparation = nil
    self._imageAssets = nil
    self._ownsImageAssets = false
    return {
      mapLoader = assert(claimedLoader),
      assetPreparation = assert(claimedQueue),
      imageAssets = claimedImageAssets,
    }
  end
  -- Releases an unclaimed transfer (route construction failure before the
  -- runtime adopted it). After a claim the runtime owns the resources and
  -- this is a no-op. An adopted image owner is returned to its composer
  -- undisposed; only an entry-built owner is disposed here.
  function transfer:dispose()
    if self._claimed or self._released then
      return
    end
    self._released = true
    local loaderToRelease = self._mapLoader
    local queueToRelease = self._assetPreparation
    local poolToRelease = self._ownsImageAssets and self._imageAssets or nil
    self._mapLoader = nil
    self._assetPreparation = nil
    self._imageAssets = nil
    self._ownsImageAssets = false
    if loaderToRelease ~= nil then
      loaderToRelease:release()
    end
    if poolToRelease ~= nil then
      poolToRelease:dispose()
    end
    if queueToRelease ~= nil then
      queueToRelease:release()
    end
  end
  return transfer
end

function PreparedFieldEntry:dispose()
  if self._taken or self._disposed then
    return
  end
  self._disposed = true
  self:_releaseOwned()
end

return PreparedFieldEntry
