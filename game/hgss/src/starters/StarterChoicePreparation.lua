-- Owns one starter chooser's bounded asset acquisition and GPU lifetime.
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local Matrix4 = require("libs.math.src.Matrix4")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local MonCache = require("libs.assets.src.MonCache")
local FixedPoint = require("libs.math.src.FixedPoint")

---@class StarterChoicePreparation
---@field manifest table<string, unknown>
---@field cacheFs CacheFs
---@field portraits table[]
---@field pool GpuAssetPool?
---@field _sessionImages table<string, unknown>? borrowed session image owner behind leased 2D draws; nil fails loudly at the first texture acquisition (mesh-only and headless stand-in paths carry no textures)
---@field prepareQueue table<string, unknown>? borrowed queue
---@field plan table<string, unknown>[]?
---@field planIndex integer
---@field outstanding table<integer, boolean>
---@field pageHost table<string, function>?
---@field pageReady table<integer, boolean>
---@field _resources StarterChoicePreparation.Resources owned prepared resources
---@field ready boolean
---@field disposed boolean
local StarterChoicePreparation = {}
StarterChoicePreparation.__index = StarterChoicePreparation

---@class StarterChoicePreparation.Resources
---@field meshEntries table<string, StarterChoiceMeshEntry>
---@field imageEntries table<string, GpuAssetPool.Image?>
---@field definitions table<string, ModelDefinition>
---@field renderMeshes table<string, table<string, unknown>>
---@field wraps table<string, table<string, unknown>>
---@field instances table<string, ModelInstance>
---@field staticBatches table[]
---@field machineBackgroundImage GpuAssetPool.Image?
---@field infoBaseImage GpuAssetPool.Image?
---@field infoOverlayImage GpuAssetPool.Image?
---@field portraitImages table<integer, GpuAssetPool.Image>
---@field portraitQuads table[]
---@field imageLeases table<string, table<string, unknown>> session-pool leases by image path and sampler behind leased 2D draws
---@field imageHandles table<string, table<string, unknown>> stable sampling handles beside the leases behind material resolution
---@field machineBackgroundLease table<string, unknown>? session-pool lease behind the machine background draw
---@field infoBaseLease table<string, unknown>? session-pool lease behind the info base draw
---@field infoOverlayLease table<string, unknown>? session-pool lease behind the info overlay draw

local ROLES = { "tabletop", "turntable", "ballEffect", "ball1", "ball2", "ball3" }
local PREPARATION_WINDOW = 2

---@param descriptor table<string, unknown> static model descriptor
---@param acquire StarterChoiceAcquisition realized mesh/image entries behind the pool call shape
---@return table[] prepared batches
local function prepareStatic(descriptor, acquire)
  assert(type(descriptor.materials) == "table", "starter static model requires its materials")
  assert(type(descriptor.batches) == "table", "starter static model requires its batches")
  local materialById = {}
  for listIndex, record in ipairs(descriptor.materials) do
    local wrap = SceneDescriptor.wrap(record)
    -- Static materials skip the instance unpack, so sampling handles
    -- unpack here: indexed art binds its exact palette through the
    -- shared 3D sampler while bare images sample straight.
    local resolved = acquire:imageFor(record.texture, wrap.x, wrap.y)
    local image, palette, indexed = resolved, nil, nil
    if type(resolved) == "table" and resolved.image ~= nil then
      image, palette, indexed = resolved.image, resolved.palette, resolved.indexed
    end
    materialById[record.id] = {
      id = record.id,
      name = record.name,
      image = image,
      palette = palette,
      indexed = indexed,
      texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
      wrap = wrap,
      listIndex = listIndex,
    }
  end
  local batches = {}
  for _, batch in ipairs(descriptor.batches) do
    local mesh = acquire:meshFor(batch.geometry)
    batches[#batches + 1] = {
      mesh = mesh.mesh,
      material = materialById[batch.material],
      center = mesh.center,
      alphaClass = batch.alphaClass,
      cullMode = batch.cullMode,
      polygonAlpha = batch.polygonAlpha / FixedPoint.RGB5_MAX,
      polygonMode = batch.polygonMode,
      polygonId = batch.polygonId,
      translucentDepthWrite = batch.translucentDepthWrite,
      depthEqual = batch.depthEqual,
      lightMask = batch.lightMask,
      fogEnabled = batch.fogEnabled,
    }
  end
  return batches
end

---@param role string
---@param descriptor table<string, unknown> dynamic model descriptor
---@param acquire StarterChoiceAcquisition realized mesh/image entries behind the pool call shape
---@param preparation StarterChoicePreparation
local function realizeDynamic(role, descriptor, acquire, preparation)
  assert(type(descriptor.dynamic) == "table", "starter model " .. role .. " requires its dynamic batches")
  assert(type(descriptor.materials) == "table", "starter model " .. role .. " requires its materials")
  assert(type(descriptor.animations) == "table", "starter model " .. role .. " requires its clips")
  local nitroDescriptor = descriptor --[[@as ModelDefinition.Descriptor]]
  local definition = ModelDefinition.fromNitroDescriptor(nitroDescriptor, { key = "starter-choice:" .. role })
  local renderMeshes = {}
  for _, mesh in ipairs(definition.meshes) do
    local resource = acquire:meshFor(mesh.geometry)
    renderMeshes[mesh.id] = resource.mesh
    mesh.center = resource.center
  end
  local wraps = {}
  for listIndex, record in ipairs(descriptor.materials) do
    wraps[listIndex - 1] = SceneDescriptor.wrap(record)
  end
  ---@param path string
  ---@param materialId integer
  ---@return GpuAssetPool.Image?
  local function resolveImage(path, materialId)
    local wrap = assert(wraps[materialId], "starter model " .. role .. " has no sampler wrap")
    return acquire:imageFor(path, wrap.x, wrap.y)
  end
  local instance = ModelInstance.new(definition, {
    resolveImage = resolveImage,
  })
  preparation._resources.definitions[role] = definition
  preparation._resources.renderMeshes[role] = renderMeshes
  preparation._resources.wraps[role] = wraps
  preparation._resources.instances[role] = instance
end

-- The mesh/image entries behind the pool call shape once preparation has
-- realized them. Assembly reads only these entries, so draws and selection
-- changes after readiness never touch the cache, the queue, or the pool.
---@class StarterChoiceAcquisition
---@field meshFor fun(self: StarterChoiceAcquisition, path: string): StarterChoiceMeshEntry
---@field imageFor fun(self: StarterChoiceAcquisition, path: string?, wrapX: string, wrapY: string): table<string, unknown>? sampling handle or bare image behind the texture

---@class StarterChoiceMeshEntry
---@field mesh unknown
---@field triangles integer
---@field center number[]
---@field bounds table<string, unknown>

---@class StarterChoicePrepStep
---@field kind "mesh"|"image"|"models"|"finish"
---@field path string?
---@field wrapX string?
---@field wrapY string?
---@field width number?
---@field height number?
---@field pageId integer? portrait atlas page gating image submission while set
---@field token integer? live submitted token while the window holds this step
---@field requested boolean? whether this step was ever submitted to the queue

---@class StarterChoicePrepContext
---@field assetPreparation table<string, unknown>? borrowed preparation queue; nil prepares synchronously from the cache
---@field imageAssets table<string, unknown>? borrowed session image owner; nil fails loudly at the first texture acquisition (mesh-only and headless stand-in paths carry no textures)
---@field gxRenderer table<string, unknown> borrowed field graphics backend for the renderer wrapper
---@field derivedAssets table<string, function>? borrowed semantic host gating actual portrait pages

-- One realized entry source over this preparation owner's entry tables.
---@param preparation StarterChoicePreparation
---@return StarterChoiceAcquisition
local function realizedSource(preparation)
  local source = {}
  function source:meshFor(path)
    local entry = preparation._resources.meshEntries[path]
    assert(entry ~= nil, "starter model geometry is not prepared: " .. tostring(path))
    return entry
  end
  function source:imageFor(path, wrapX, wrapY)
    if path == nil then
      return nil
    end
    local key = path .. "|" .. wrapX .. "|" .. wrapY
    -- The stable sampling handle when the session owner backs this
    -- identity (built once beside its lease, shared by every material
    -- so per-frame resolution allocates nothing); the bare entry from
    -- the same session borrow otherwise. ModelInstance unpacks either
    -- form. Without a session owner neither form is installed and the
    -- lookup below fails loudly.
    local handle = preparation._resources.imageHandles[key]
    if handle ~= nil then
      return handle
    end
    local entry = preparation._resources.imageEntries[key]
    assert(entry ~= nil, "starter texture is not prepared: " .. tostring(path))
    return entry
  end
  return source --[[@as StarterChoiceAcquisition]]
end

-- Stand-in records own no graphics objects and carry no animation state,
-- so their lifecycle operations do nothing.
local function updateStandIn() end

-- A model instance stand-in for descriptors with no drawable batches. It
-- keeps the assembly shape (transform, fixed-tick advance, pose evaluation,
-- and a stable live draw list) while drawing nothing.
---@return ModelInstance
local function stubInstance()
  local draws = {}
  local instance = { transform = Matrix4.identity() }
  function instance:updateFixed() end
  function instance:evaluatePose() end
  function instance:drawItems()
    return draws
  end
  function instance:play()
    return {
      player = {
        completed = false,
        updateFixed = updateStandIn,
      },
    }
  end
  function instance:stop()
    return 0
  end
  return instance --[[@as ModelInstance]]
end

-- A prepared payload carries upload buffers exactly when it came from the
-- preparation worker. Anything else is malformed generated data and fails
-- loudly below instead of rendering a blank scene.
---@param payload table<string, unknown>?
---@return boolean
local function isMeshPayload(payload)
  return type(payload) == "table" and payload.vertexData ~= nil and payload.indexData ~= nil
end

---@param payload table<string, unknown>?
---@return boolean
local function isImagePayload(payload)
  return type(payload) == "table" and payload.imageData ~= nil
end

-- Every concrete mesh path and image (path plus sampler) the manifest
-- needs, in first-use order with shared resources listed once. Mirrors the
-- acquisition the first-draw path performed, so nothing drawable is missed.
-- Portraits resolve to the deduplicated page images of the actual candidate
-- descriptors: the whole portrait atlas is never requested.
---@param manifest table<string, unknown>
---@param portraits table[] per-candidate portrait descriptors ({ selector: string, pageId: integer })
---@return string[] meshPaths, StarterChoicePrepStep[] imageSteps
local function collectResources(manifest, portraits)
  local models = assert(manifest.models, "starter manifest is missing its models")
  local meshPaths, seenMesh = {}, {}
  local function addMesh(path)
    assert(type(path) == "string", "starter model batch references no geometry path")
    if not seenMesh[path] then
      seenMesh[path] = true
      meshPaths[#meshPaths + 1] = path
    end
  end
  local imageSteps, seenImage = {}, {}
  local function addImage(path, wrapX, wrapY, width, height, pageId)
    assert(type(path) == "string", "starter image reference carries no path")
    local key = path .. "|" .. wrapX .. "|" .. wrapY
    if not seenImage[key] then
      seenImage[key] = true
      imageSteps[#imageSteps + 1] =
        { kind = "image", path = path, wrapX = wrapX, wrapY = wrapY, width = width, height = height, pageId = pageId }
    end
  end
  local function addMaterialImages(materials)
    assert(type(materials) == "table", "starter model carries no materials")
    for _, record in ipairs(materials) do
      local wrap = SceneDescriptor.wrap(record)
      if record.texture ~= nil then
        addImage(record.texture, wrap.x, wrap.y)
      end
      for _, variant in ipairs(record.variants or {}) do
        if variant.texture ~= nil then
          addImage(variant.texture, wrap.x, wrap.y)
        end
      end
    end
  end
  for _, role in ipairs(ROLES) do
    local descriptor = assert(models[role], "starter manifest is missing model role " .. role)
    if descriptor.kind == "static" then
      for _, batch in ipairs(assert(descriptor.batches, "starter static model " .. role .. " carries no batches")) do
        addMesh(batch.geometry)
      end
      addMaterialImages(descriptor.materials)
    else
      local dynamic = assert(descriptor.dynamic, "starter model " .. role .. " requires its dynamic batches")
      for _, batch in ipairs(assert(dynamic.batches, "starter model " .. role .. " carries no batches")) do
        addMesh(batch.geometry)
      end
      addMaterialImages(descriptor.materials)
    end
  end
  local backgrounds = assert(manifest.backgrounds, "starter manifest is missing its backgrounds")
  local machineBackground = assert(backgrounds.machine, "starter manifest is missing its machine background")
  addImage(
    assert(machineBackground.image, "starter manifest is missing its machine background image"),
    "clamp",
    "clamp",
    machineBackground.width,
    machineBackground.height
  )
  local infoArtwork = assert(backgrounds.info, "starter manifest is missing its info artwork")
  local infoBase = assert(infoArtwork.base, "starter manifest is missing its info base layer")
  addImage(
    assert(infoBase.image, "starter manifest is missing its info base image"),
    "clamp",
    "clamp",
    infoBase.width,
    infoBase.height
  )
  local infoOverlay = assert(infoArtwork.overlay, "starter manifest is missing its info overlay layer")
  addImage(
    assert(infoOverlay.image, "starter manifest is missing its info overlay image"),
    "clamp",
    "clamp",
    infoOverlay.width,
    infoOverlay.height
  )
  local seenPages = {}
  for index, descriptor in ipairs(portraits) do
    assert(type(descriptor) == "table", "starter portrait descriptor " .. index .. " carries its page")
    local rawPageId = assert(descriptor.pageId, "starter portrait descriptor " .. index .. " carries its page")
    assert(
      type(rawPageId) == "number" and rawPageId % 1 == 0 and rawPageId >= 0,
      "starter portrait descriptor " .. index .. " carries its page"
    )
    local pageId = math.floor(rawPageId)
    if not seenPages[pageId] then
      seenPages[pageId] = true
      addImage(MonCache.portraitPagePath(pageId), "clamp", "clamp", nil, nil, pageId)
    end
  end
  return meshPaths, imageSteps
end

---@param manifest table<string, unknown>
---@param cacheFs table<string, unknown>
---@param portraits table[]
---@return StarterChoicePreparation
function StarterChoicePreparation.new(manifest, cacheFs, portraits)
  assert(type(manifest) == "table", "starter preparation requires its manifest")
  assert(type(cacheFs) == "table", "starter preparation requires its cache filesystem")
  assert(type(portraits) == "table", "starter preparation requires candidate portraits")
  return setmetatable({
    manifest = manifest,
    cacheFs = cacheFs,
    portraits = portraits,
    pool = nil,
    prepareQueue = nil,
    plan = nil,
    planIndex = 1,
    outstanding = {},
    pageHost = nil,
    pageReady = {},
    _resources = {
      meshEntries = {},
      imageEntries = {},
      imageLeases = {},
      imageHandles = {},
      definitions = {},
      renderMeshes = {},
      wraps = {},
      instances = {},
      staticBatches = {},
      portraitImages = {},
      portraitQuads = {},
    },
    ready = false,
    disposed = false,
  }, StarterChoicePreparation)
end

-- The distinct actual portrait pages this chooser's candidates select,
-- in first-use order. The whole atlas is never requested.
---@return integer[]
function StarterChoicePreparation:_portraitPages()
  local pages, seen = {}, {}
  for _, descriptor in ipairs(self.portraits) do
    local pageId = assert(descriptor.pageId, "starter portrait descriptor carries its page")
    if not seen[pageId] then
      seen[pageId] = true
      pages[#pages + 1] = pageId
    end
  end
  return pages
end

-- Requests each distinct actual portrait page as required and records
-- current pages. A nil host leaves readiness untouched, preserving the
-- established hostless preparation path. A page failure is malformed or
-- missing generated data and fails loudly: no absent page is ever loaded
-- as an old-generation file or replaced with a default portrait.
---@param host table<string, function>?
---@return boolean allReady
function StarterChoicePreparation:_pollPortraitPages(host)
  if host == nil then
    return true
  end
  self.pageHost = host
  local allReady = true
  for _, pageId in ipairs(self:_portraitPages()) do
    if not self.pageReady[pageId] then
      local ready, failure = host.requestMonPortraitPage(pageId, "required")
      if failure ~= nil then
        error("starter portrait page " .. tostring(pageId) .. " is unavailable: " .. tostring(failure), 0)
      end
      if ready then
        self.pageReady[pageId] = true
      else
        allReady = false
      end
    end
  end
  return allReady
end

---@return boolean
function StarterChoicePreparation:isReady()
  return self.ready
end

---@return table<string, unknown> borrowed finalized resource view
function StarterChoicePreparation:resources()
  assert(self.ready, "starter resources are available only after preparation")
  return self._resources
end

---@param context StarterChoicePrepContext
---@param maxWorkUnits integer?
---@return integer completedUnits
function StarterChoicePreparation:advance(context, maxWorkUnits)
  assert(not self.disposed, "starter preparation is disposed")
  if self.ready then
    return 0
  end
  assert(type(context) == "table", "starter preparation requires its composition")
  maxWorkUnits = maxWorkUnits or 1
  assert(
    type(maxWorkUnits) == "number" and maxWorkUnits >= 0 and maxWorkUnits % 1 == 0,
    "starter preparation requires a non-negative integer step budget"
  )
  if maxWorkUnits == 0 then
    return 0
  end
  if context.derivedAssets ~= nil then
    local ok, failure = pcall(self._pollPortraitPages, self, context.derivedAssets)
    if not ok then
      self:dispose()
      error(failure, 0)
    end
  end
  if self.plan == nil then
    local meshPaths, imageSteps = collectResources(self.manifest, self.portraits)
    -- The chooser draws through the session image owner when the field
    -- composition provides one, instead of privately owned textures.
    -- The session owner behind leased 2D draws is remembered beside
    -- the pool: pool entries stay bare for assembly while 2D draws
    -- borrow the same identities directly, landing on the identical
    -- physical pair through the matching sampler below.
    self._sessionImages = context.imageAssets
    self.pool = GpuAssetPool.new(self.cacheFs, { imageAssets = context.imageAssets })
    self.prepareQueue = context.assetPreparation
    self.pageHost = context.derivedAssets
    local plan = {}
    for _, path in ipairs(meshPaths) do
      plan[#plan + 1] = { kind = "mesh", path = path }
    end
    for _, step in ipairs(imageSteps) do
      plan[#plan + 1] = step
    end
    plan[#plan + 1] = { kind = "models" }
    plan[#plan + 1] = { kind = "finish" }
    self.plan = plan
    if self.prepareQueue ~= nil then
      local ok, failure = pcall(self._submitWindow, self)
      if not ok then
        self:dispose()
        error(failure, 0)
      end
    end
  end
  local completed = 0
  while completed < maxWorkUnits and not self.ready do
    local ok, progressed = pcall(self._advancePlanStep, self)
    if not ok then
      self:dispose()
      error(progressed, 0)
    end
    if not progressed then
      break
    end
    completed = completed + 1
  end
  return completed
end

-- Submits the earliest never-submitted resource steps until the
-- submitted-but-unconsumed window is full. Portrait image steps wait for
-- their page receipt before submission, so already-derived resources keep
-- flowing through the window while a page compiles. Runs once when the plan
-- is created and again after every consumed payload, so at most
-- PREPARATION_WINDOW tokens stay outstanding while every staged asset is
-- still eventually requested.
function StarterChoicePreparation:_submitWindow()
  local queue = assert(self.prepareQueue, "starter preparation owns no queue")
  local plan = assert(self.plan, "starter preparation owns no plan")
  local outstanding = 0
  for _ in pairs(self.outstanding) do
    outstanding = outstanding + 1
  end
  for _, step in ipairs(plan) do
    if outstanding >= PREPARATION_WINDOW then
      return
    end
    if (step.kind == "mesh" or step.kind == "image") and not step.requested then
      if step.pageId ~= nil and self.pageHost ~= nil and not self.pageReady[step.pageId] then
        -- The page is not current yet: later ready steps may still fill the
        -- window, and this step submits once its receipt arrives.
      else
        step.token = queue:request(step.kind, assert(step.path, "starter preparation step carries no path"), "demand")
        assert(step.token ~= nil, "starter preparation request returned no token")
        step.requested = true
        self.outstanding[step.token] = true
        outstanding = outstanding + 1
      end
    end
  end
end

-- Runs the next plan step. Returns true when a step completed and false
-- while preparation work is still outstanding.
---@return boolean
function StarterChoicePreparation:_advancePlanStep()
  local plan = assert(self.plan, "starter preparation owns no plan")
  local step = plan[self.planIndex]
  if step == nil then
    return false
  end
  if step.pageId ~= nil and self.pageHost ~= nil and not self.pageReady[step.pageId] then
    -- The page receipt is still pending: other already-derived steps ahead
    -- of it completed in order, and preparation resumes here once it is
    -- current. No absent path reaches the queue or the pool.
    return false
  end
  if step.kind == "models" then
    self:_assembleModels()
    self.planIndex = self.planIndex + 1
    return true
  end
  if step.kind == "finish" then
    self:_finishResources()
    self.planIndex = self.planIndex + 1
    return true
  end
  local queue = self.prepareQueue
  if queue ~= nil then
    if step.token == nil then
      -- Skipped while its page was pending and never submitted since: submit
      -- now that the receipt is current, or wait when the window is full.
      self:_submitWindow()
      if step.token == nil then
        return false
      end
    end
    local token = assert(step.token, "starter preparation step owns no token")
    local status, failure = queue:poll(token)
    if status == "pending" then
      return false
    end
    step.token = nil
    self.outstanding[token] = nil
    if status ~= "ready" then
      error(
        "starter preparation failed for "
          .. tostring(step.path)
          .. " ("
          .. tostring(step.kind)
          .. "): "
          .. tostring(failure),
        0
      )
    end
    self:_realizePrepared(step, queue:take(token))
    self.planIndex = self.planIndex + 1
    self:_submitWindow()
    return true
  else
    self:_realizeSynchronous(step)
  end
  self.planIndex = self.planIndex + 1
  return true
end

-- Borrows one image identity from the session owner for leased 2D
-- draws, under the exact sampler the pool resolves it with, so the
-- borrow lands on the identical physical pair. Without a session owner
-- there is nothing to borrow and the function answers nil; texture
-- acquisition itself then fails loudly instead of falling back to raw
-- draws. Idempotent per path and sampler.
---@param path string generated image path behind the borrow
---@param wrapX string
---@param wrapY string
---@return table<string, unknown>? session-pool lease behind the identity
local function borrowImageLease(self, path, wrapX, wrapY)
  local key = path .. "|" .. wrapX .. "|" .. wrapY
  local known = self._resources.imageLeases[key]
  if known ~= nil then
    return known
  end
  local session = self._sessionImages
  if session == nil then
    return nil
  end
  local token =
    session:request(path, { wrapX = wrapX, wrapY = wrapY, minFilter = "nearest", magFilter = "nearest" }, "demand")
  local stalled = 0
  while true do
    local status, _ = session:poll(token)
    if status == "ready" then
      local lease = session:acquire(token)
      self._resources.imageLeases[key] = lease
      -- The stable sampling handle beside its lease: materials share
      -- this one record instead of building per-resolution tables.
      self._resources.imageHandles[key] = { image = lease.image, palette = lease.palette, indexed = lease.kind == "r8" }
      return lease
    end
    if status == "failed" then
      return nil
    end
    assert(status == "pending", "starter preparation reports pending or ready")
    stalled = stalled + 1
    if stalled > 10000 then
      return nil
    end
    local timer = love and love.timer
    if timer ~= nil and timer.sleep ~= nil then
      timer.sleep(0.001)
    end
  end
end

-- Realizes one taken payload through the owned pool. A payload without
-- upload buffers is malformed and fails instead of rendering a blank scene.
---@param step StarterChoicePrepStep
---@param payload table<string, unknown>
function StarterChoicePreparation:_realizePrepared(step, payload)
  local pool = assert(self.pool, "starter preparation owns no pool")
  local path = assert(step.path, "starter preparation step carries no path")
  if step.kind == "mesh" then
    if not isMeshPayload(payload) then
      error("starter preparation produced no mesh upload buffers for " .. tostring(path), 0)
    end
    self._resources.meshEntries[path] = pool:meshFromPrepared(path, payload --[[@as SceneMesh.PreparedMesh]])
    return
  end
  assert(step.kind == "image", "starter preparation step carries an unknown kind " .. tostring(step.kind))
  local wrapX, wrapY =
    assert(step.wrapX, "starter image step carries no wrap"), assert(step.wrapY, "starter image step carries no wrap")
  if not isImagePayload(payload) then
    error("starter preparation produced no image upload buffers for " .. tostring(path), 0)
  end
  self._resources.imageEntries[path .. "|" .. wrapX .. "|" .. wrapY] =
    pool:imageFromPrepared(path, wrapX, wrapY, payload --[[@as { imageData: unknown }]])
  borrowImageLease(self, path, wrapX, wrapY)
end

-- Realizes one resource synchronously from the cache for compositions
-- without a preparation queue.
---@param step StarterChoicePrepStep
function StarterChoicePreparation:_realizeSynchronous(step)
  local pool = assert(self.pool, "starter preparation owns no pool")
  local path = assert(step.path, "starter preparation step carries no path")
  if step.kind == "mesh" then
    self._resources.meshEntries[path] = pool:meshFor(path)
    return
  end
  assert(step.kind == "image", "starter preparation step carries an unknown kind " .. tostring(step.kind))
  local wrapX, wrapY =
    assert(step.wrapX, "starter image step carries no wrap"), assert(step.wrapY, "starter image step carries no wrap")
  self._resources.imageEntries[path .. "|" .. wrapX .. "|" .. wrapY] = pool:imageFor(path, wrapX, wrapY)
  borrowImageLease(self, path, wrapX, wrapY)
end

-- Builds every model definition and instance from the realized entries. A
-- dynamic role with no drawable batches keeps a stand-in instance so the
-- draw composition holds its shape; anything malformed fails loudly here,
-- before the first visible draw.
function StarterChoicePreparation:_assembleModels()
  local acquire = realizedSource(self)
  local models = assert(self.manifest.models, "starter manifest is missing its models")
  for _, role in ipairs(ROLES) do
    local descriptor = assert(models[role], "starter manifest is missing model role " .. role)
    local roleOk, roleErr = pcall(function()
      if descriptor.kind == "static" then
        self._resources.staticBatches = prepareStatic(descriptor, acquire)
      else
        local dynamic = descriptor.dynamic
        local batches = type(dynamic) == "table" and dynamic.batches or nil
        if type(batches) == "table" and #batches == 0 then
          self._resources.instances[role] = stubInstance()
          self._resources.renderMeshes[role] = {}
          self._resources.wraps[role] = {}
        else
          realizeDynamic(role, descriptor, acquire, self)
        end
      end
    end)
    if not roleOk then
      error("starter presentation cannot prepare " .. role .. ": " .. tostring(roleErr), 0)
    end
  end
end

-- Finalizes borrowed image, model, and portrait resources; rendering and
-- semantic playback remain with StarterChoicePresentation.
function StarterChoicePreparation:_finishResources()
  local resources = self._resources
  local backgrounds = assert(self.manifest.backgrounds, "starter manifest is missing its backgrounds")
  local machineBackground = assert(backgrounds.machine, "starter manifest is missing its machine background")
  resources.machineBackgroundImage = assert(
    resources.imageEntries[assert(machineBackground.image, "starter manifest is missing its machine background image") .. "|clamp|clamp"],
    "starter preparation owns no machine background image"
  )
  resources.machineBackgroundLease = resources.imageLeases[assert(
    machineBackground.image,
    "starter manifest is missing its machine background image"
  ) .. "|clamp|clamp"]
  local infoArtwork = assert(backgrounds.info, "starter manifest is missing its info artwork")
  resources.infoBaseImage = assert(
    resources.imageEntries[assert(infoArtwork.base, "starter manifest is missing its info base layer").image .. "|clamp|clamp"],
    "starter preparation owns no info base layer"
  )
  resources.infoOverlayImage = assert(
    resources.imageEntries[assert(infoArtwork.overlay, "starter manifest is missing its info overlay layer").image .. "|clamp|clamp"],
    "starter preparation owns no info overlay layer"
  )
  resources.infoBaseLease = resources.imageLeases[assert(
    infoArtwork.base,
    "starter manifest is missing its info base layer"
  ).image .. "|clamp|clamp"]
  resources.infoOverlayLease = resources.imageLeases[assert(
    infoArtwork.overlay,
    "starter manifest is missing its info overlay layer"
  ).image .. "|clamp|clamp"]
  for _, descriptor in ipairs(self.portraits) do
    local pageId = assert(descriptor.pageId, "starter portrait descriptor carries its page")
    if resources.portraitImages[pageId] == nil then
      resources.portraitImages[pageId] = assert(
        resources.imageEntries[MonCache.portraitPagePath(pageId) .. "|clamp|clamp"],
        "starter preparation owns no portrait page " .. pageId
      )
    end
  end
  local portraitManifest = self.cacheFs:loadLua(MonCache.portraitManifestPath())
  assert(portraitManifest ~= nil, "starter preparation requires the mon portrait entries")
  local entries = assert(portraitManifest.entries, "starter preparation requires the mon portrait entries")
  local graphics = love and love.graphics
  for index, descriptor in ipairs(self.portraits) do
    local entry = assert(
      entries[descriptor.selector],
      "starter candidate has no portrait entry for " .. tostring(descriptor.selector)
    )
    local pageImage = assert(
      resources.portraitImages[descriptor.pageId],
      "starter preparation owns no portrait page for " .. tostring(descriptor.selector)
    )
    local atlasWidth, atlasHeight = pageImage:getWidth(), pageImage:getHeight()
    local quad
    if graphics ~= nil and graphics.newQuad ~= nil then
      quad = graphics.newQuad(entry.x, entry.y, entry.width, entry.height, atlasWidth, atlasHeight)
    else
      quad = { x = entry.x, y = entry.y, width = entry.width, height = entry.height }
    end
    resources.portraitQuads[index] = {
      lease = resources.imageLeases[MonCache.portraitPagePath(descriptor.pageId) .. "|clamp|clamp"],
      image = pageImage,
      quad = quad,
    }
  end
  self.ready = true
end

function StarterChoicePreparation:_cancelTokens()
  local queue = self.prepareQueue
  local outstanding = self.outstanding
  self.outstanding = {}
  self.prepareQueue = nil
  if queue == nil then
    return
  end
  for token in pairs(outstanding) do
    pcall(queue.cancel, queue, token)
  end
end

function StarterChoicePreparation:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self:_cancelTokens()
  -- Session-pool 2D borrows return to their owner exactly once; the
  -- pool below owns only its own entries and private textures.
  local session = self._sessionImages
  self._sessionImages = nil
  if session ~= nil then
    for key, lease in pairs(self._resources.imageLeases) do
      self._resources.imageLeases[key] = nil
      session:release(lease)
    end
  end
  if self.pool ~= nil then
    self.pool:release()
    self.pool = nil
  end
  self._resources = {
    meshEntries = {},
    imageEntries = {},
    imageLeases = {},
    imageHandles = {},
    definitions = {},
    renderMeshes = {},
    wraps = {},
    instances = {},
    staticBatches = {},
    portraitImages = {},
    portraitQuads = {},
  }
  self.plan, self.planIndex, self.pageHost, self.pageReady = nil, 1, nil, {}
  self.ready = false
end

return StarterChoicePreparation
