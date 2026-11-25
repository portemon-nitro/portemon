-- Bag hero 3D realization for the field bag: the GPU/model collaborator
-- behind the hero pane. The presenter owns pocket selection and the semantic
-- frame; this renderer only materializes that semantic time into animation
-- players through the shared model stack (GpuAssetPool, ModelDefinition,
-- ModelInstance, FieldRenderer), then composes the result through one private
-- canonical transparent target. Each gender realizes lazily on first draw,
-- animation catch-up is idempotent for one semantic frame, realization failure
-- unwinds the resources its own attempt acquired, and release is exactly-once.
-- No gameplay state is stored here: pocket and frame stay with the presenter.

local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local NativeDisplay = require("libs.ui.src.NativeDisplay")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local SynchronousWait = require("libs.hgss.src.presentation.SynchronousWait")
local BagCache = require("libs.assets.src.BagCache")

---@class BagHeroSync
---@field pocket string
---@field pose string
---@field pattern string
---@field frame integer
---@field attachments table[]

---@class BagHeroRealization
---@field definition ModelDefinition
---@field instance ModelInstance
---@field renderMeshes table<string, unknown>
---@field handleLeases table[] session-pool borrows behind the sampling handles, returned at release

---@class BagHeroRenderer
---@field _cacheFs table<string, unknown>
---@field _manifest table<string, unknown>
---@field _graphics unknown?
---@field _modelCanvas unknown?
---@field _cameraFacts table<string, unknown>
---@field _transformFacts table<string, unknown>
---@field _logicalSize table<string, unknown>?
---@field _view number[]
---@field _projection number[]
---@field _modelTransform number[]
---@field _sceneRuntime table<string, unknown>
---@field _cameraFar number
---@field _pool GpuAssetPool?
---@field _imageAssets table<string, unknown>? borrowed session image owner behind hero textures
---@field _assetPreparation table<string, unknown> borrowed presentation preparation worker
---@field _decoded table<string, unknown> borrowed selected decoded CPU owner
---@field _renderer FieldRenderer?
---@field _realized table<string, BagHeroRealization>
---@field _builds table<string, BagHeroBuild> staged realization per gender
---@field _sync table<string, BagHeroSync>
---@field _released boolean
local BagHeroRenderer = {}
BagHeroRenderer.__index = BagHeroRenderer

---@param value unknown
---@param what string
---@return number
local function finiteNumber(value, what)
  assert(type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge, what)
  return value --[[@as number]]
end

-- Immutable view/projection from the generated camera facts. Angles arrive in
-- degrees; the eye follows the repository camera convention (pitch around the
-- target for X, yaw for Y). The perspective angle is the source half-angle
-- index over the full circle, doubled to the full vertical field of view like
-- the field camera table. Only perspective type 0 is mapped; any other
-- validated type fails instead of guessing an orthographic mapping.
---@param camera table<string, unknown>
---@param logicalSize table<string, unknown>?
---@return { far: number, view: number[], projection: number[] }
local function buildCamera(camera, logicalSize)
  local target = assert(camera.target, "the hero camera must carry its target")
  local targetX = finiteNumber(target.x, "the hero camera target x must be finite")
  local targetY = finiteNumber(target.y, "the hero camera target y must be finite")
  local targetZ = finiteNumber(target.z, "the hero camera target z must be finite")
  local distance = finiteNumber(camera.distance, "the hero camera distance must be finite")
  assert(distance > 0, "the hero camera distance must be positive")
  local angleX = finiteNumber(camera.angleXDegrees, "the hero camera pitch must be finite")
  local angleY = finiteNumber(camera.angleYDegrees, "the hero camera yaw must be finite")
  local perspectiveType = assert(camera.perspectiveType, "the hero camera must carry its perspective type")
  assert(perspectiveType == 0, "the bag hero supports only perspective projection")
  local perspectiveAngle = assert(camera.perspectiveAngle, "the hero camera must carry its perspective angle")
  assert(
    type(perspectiveAngle) == "number" and perspectiveAngle % 1 == 0 and perspectiveAngle > 0,
    "the hero camera needs a positive perspective angle"
  )
  local clipNear = finiteNumber(camera.clipNear, "the hero camera near plane must be finite")
  local clipFar = finiteNumber(camera.clipFar, "the hero camera far plane must be finite")
  assert(clipNear > 0 and clipFar > clipNear, "the hero camera clipping range is invalid")
  local halfFov = perspectiveAngle * 2 * math.pi / 65536
  local pitch = math.rad(angleX)
  local yaw = math.rad(angleY)
  local horizontal = distance * math.cos(pitch)
  local eye = {
    targetX + math.sin(yaw) * horizontal,
    targetY + math.sin(-pitch) * distance,
    targetZ + math.cos(yaw) * horizontal,
  }
  local aspect = 4 / 3
  if
    type(logicalSize) == "table"
    and type(logicalSize.width) == "number"
    and type(logicalSize.height) == "number"
    and logicalSize.height > 0
  then
    aspect = logicalSize.width / logicalSize.height
  end
  return {
    far = clipFar,
    view = Matrix4.lookAt(eye, { targetX, targetY, targetZ }, { 0, 1, 0 }),
    projection = Matrix4.perspective(halfFov * 2, aspect, clipNear, clipFar),
  }
end

-- Immutable model matrix from the generated transform facts: uniform or
-- non-uniform scale first, then the source rotation, then translation. The
-- nine rotation entries read in row-major order.
---@param transform table<string, unknown>
---@return number[]
local function buildModelTransform(transform)
  local translation = assert(transform.translation, "the hero transform must carry its translation")
  local rotation = assert(transform.rotation, "the hero transform must carry its rotation")
  assert(type(rotation) == "table" and #rotation == 9, "the hero rotation must carry nine matrix entries")
  local scale = assert(transform.scale, "the hero transform must carry its scale")
  local linear = {
    finiteNumber(rotation[1], "hero rotation entries must be finite"),
    finiteNumber(rotation[4], "hero rotation entries must be finite"),
    finiteNumber(rotation[7], "hero rotation entries must be finite"),
    0,
    finiteNumber(rotation[2], "hero rotation entries must be finite"),
    finiteNumber(rotation[5], "hero rotation entries must be finite"),
    finiteNumber(rotation[8], "hero rotation entries must be finite"),
    0,
    finiteNumber(rotation[3], "hero rotation entries must be finite"),
    finiteNumber(rotation[6], "hero rotation entries must be finite"),
    finiteNumber(rotation[9], "hero rotation entries must be finite"),
    0,
    0,
    0,
    0,
    1,
  }
  return Matrix4.multiply(
    Matrix4.translate(
      finiteNumber(translation.x, "hero translation entries must be finite"),
      finiteNumber(translation.y, "hero translation entries must be finite"),
      finiteNumber(translation.z, "hero translation entries must be finite")
    ),
    Matrix4.multiply(
      linear,
      Matrix4.scale(
        finiteNumber(scale.x, "hero scale entries must be finite"),
        finiteNumber(scale.y, "hero scale entries must be finite"),
        finiteNumber(scale.z, "hero scale entries must be finite")
      )
    )
  )
end

-- Immutable scene record for the shared GX path. The generated lights carry
-- the four static retail direction vectors plus their white color, so the
-- scene selects a single field-lighting record with one enabled directional
-- slot per generated vector with the generated color. The material registers
-- are the generated retail setup values (mid-gray diffuse/specular/emission,
-- dimmer gray ambient) rather than an unlit white/zero assumption, so static
-- materials render lit the way the source global registers light them.
-- Manifest floats convert to the fx12 directional domain the GX record
-- shares with the field profiles; register colors pack to RGB555.
local FX12_SCALE = 4096

---@param value unknown
---@param what string
---@return integer
local function toFx12(value, what)
  local float = finiteNumber(value, what)
  return math.floor(float * FX12_SCALE + 0.5)
end

---@param register unknown
---@param what string
---@return integer
local function toRgb555(register, what)
  assert(type(register) == "table", what .. " must be a record")
  local channels = {}
  for _, channel in ipairs({ "r", "g", "b" }) do
    local value = register[channel]
    assert(
      type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 31,
      what .. " channel " .. channel .. " must be 0..31"
    )
    channels[#channels + 1] = value
  end
  return channels[1] + 32 * channels[2] + 1024 * channels[3]
end

---@param lights table<string, unknown>
---@param materials table<string, unknown>
---@param edgeFacts table<string, unknown>
---@return table<string, unknown>
local function buildSceneRuntime(lights, materials, edgeFacts)
  local count = assert(lights.count, "the hero presentation must carry its light count")
  assert(count == 4, "the hero light count must be exactly four")
  local color = assert(lights.color, "the hero presentation must carry its light color")
  local red = finiteNumber(color.r, "hero light channels must be finite")
  local green = finiteNumber(color.g, "hero light channels must be finite")
  local blue = finiteNumber(color.b, "hero light channels must be finite")
  local packedColor = red + 32 * green + 1024 * blue
  local vectors = assert(lights.vectors, "the hero presentation must carry its light vectors")
  assert(type(vectors) == "table" and #vectors == 4, "the hero presentation must carry four light vectors")
  local slots = {}
  for index = 1, 4 do
    local vector = assert(vectors[index], "the hero presentation must carry light vector " .. index)
    slots[index] = {
      enabled = true,
      colorRgb555 = packedColor,
      vectorFx12 = {
        toFx12(vector.x, "hero light vectors must be finite"),
        toFx12(vector.y, "hero light vectors must be finite"),
        toFx12(vector.z, "hero light vectors must be finite"),
      },
    }
  end
  local fogTable = {}
  for index = 1, 32 do
    fogTable[index] = 0
  end
  -- The generated edge records feed the shared edge-marking pass unchanged:
  -- each record packs to RGB555 at its zero-based scene index.
  assert(type(edgeFacts) == "table" and #edgeFacts == 8, "the hero presentation must carry eight edge colors")
  local edgeColors = {}
  for index = 1, 8 do
    edgeColors[index - 1] = toRgb555(edgeFacts[index], "the hero edge color")
  end
  return {
    lighting = {
      records = {
        {
          endHalfSeconds = 0,
          lights = slots,
          diffuseRgb555 = toRgb555(materials.diffuse, "the hero material diffuse register"),
          ambientRgb555 = toRgb555(materials.ambient, "the hero material ambient register"),
          specularRgb555 = toRgb555(materials.specular, "the hero material specular register"),
          emissionRgb555 = toRgb555(materials.emission, "the hero material emission register"),
        },
      },
    },
    edgeColors = edgeColors,
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
  }
end

---@class BagHeroRenderer.Options
---@field cacheFs table<string, unknown> generated-asset filesystem the model/texture bytes read through
---@field manifest table<string, unknown> the validated bag manifest carrying hero models and presentation
---@field graphics unknown? injectable graphics namespace (nil keeps love.graphics at realization)
---@field imageAssets table<string, unknown>? borrowed session image owner; nil fails loudly at the first texture acquisition (mesh-only and headless stand-in paths carry no textures)
---@field assetPreparation table<string, unknown> borrowed presentation preparation worker the hero's model bank decodes through
---@field decoded table<string, unknown> borrowed selected decoded CPU owner the taken leases return through

---@param opts BagHeroRenderer.Options
---@return BagHeroRenderer
function BagHeroRenderer.new(opts)
  assert(type(opts) == "table", "the bag hero renderer requires options")
  local cacheFs = assert(opts.cacheFs, "the bag hero renderer requires the asset filesystem")
  assert(type(cacheFs.read) == "function", "the bag hero renderer requires a readable asset filesystem")
  local manifest = assert(opts.manifest, "the bag hero renderer requires the bag manifest")
  assert(manifest.schema == BagCache.SCHEMA, "the bag hero renderer requires the current bag manifest")
  local hero = assert(manifest.hero, "the bag manifest must carry its hero pane")
  local model = assert(hero.model, "the hero pane must carry its gender models")
  assert(type(model.male) == "table", "the hero pane must carry its male model")
  assert(type(model.female) == "table", "the hero pane must carry its female model")
  local animations = assert(hero.animations, "the hero pane must carry its animation states")
  assert(type(animations.states) == "table", "the hero pane must carry its pocket states")
  assert(type(animations.material) == "table", "the hero pane must carry its material bindings")
  local presentation = assert(hero.presentation, "the hero pane must carry its presentation facts")
  local cameraFacts = assert(presentation.camera, "the hero presentation must carry its camera")
  local transformFacts = assert(presentation.transform, "the hero presentation must carry its transform")
  local lightFacts = assert(presentation.lights, "the hero presentation must carry its lights")
  local materialFacts = assert(presentation.materials, "the hero presentation must carry its material registers")
  local edgeFacts = assert(presentation.edgeColors, "the hero presentation must carry its edge colors")
  local camera = buildCamera(cameraFacts, manifest.logicalSize)
  local transform = buildModelTransform(transformFacts)
  local assetPreparation =
    assert(opts.assetPreparation, "the bag hero renderer requires the presentation preparation worker")
  assert(
    type(assetPreparation.request) == "function"
      and type(assetPreparation.poll) == "function"
      and type(assetPreparation.take) == "function"
      and type(assetPreparation.wait) == "function",
    "the bag hero renderer requires a preparation queue"
  )
  local decoded = assert(opts.decoded, "the bag hero renderer requires the selected decoded owner")
  return setmetatable({
    _cacheFs = cacheFs,
    _manifest = manifest,
    _graphics = opts.graphics,
    _imageAssets = opts.imageAssets,
    _assetPreparation = assetPreparation,
    _decoded = decoded,
    _modelCanvas = nil,
    _cameraFacts = cameraFacts,
    _transformFacts = transformFacts,
    _logicalSize = manifest.logicalSize,
    _view = camera.view,
    _projection = camera.projection,
    _modelTransform = transform,
    _sceneRuntime = buildSceneRuntime(lightFacts, materialFacts, edgeFacts),
    _cameraFar = camera.far,
    _pool = nil,
    _renderer = nil,
    _realized = {},
    _builds = {},
    _sync = {},
    _released = false,
  }, BagHeroRenderer)
end

---@param self BagHeroRenderer
---@return love.graphics
local function graphicsFor(self)
  local graphics = self._graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  return assert(graphics, "the bag hero renderer requires love.graphics")
end

---@param self BagHeroRenderer
local function ensureModelCanvas(self)
  if self._modelCanvas ~= nil then
    return
  end
  local graphics = graphicsFor(self)
  assert(type(graphics.newCanvas) == "function", "the bag hero renderer requires canvas creation")
  local canvas
  local ok, err = pcall(function()
    canvas =
      graphics.newCanvas(NativeDisplay.WIDTH, NativeDisplay.HEIGHT, { format = "rgba8", readable = true, dpiscale = 1 })
    canvas:setFilter("nearest", "nearest")
  end)
  if not ok then
    if canvas ~= nil then
      pcall(canvas.release, canvas)
    end
    error(err, 0)
  end
  self._modelCanvas = assert(canvas, "the bag hero renderer failed to create its model target")
end

---@param gender string
---@return table<string, unknown> gender model descriptor
local function genderDescriptor(self, gender)
  local hero = self._manifest.hero
  local descriptor = hero.model[gender]
  assert(type(descriptor) == "table", "the hero has no model for gender " .. tostring(gender))
  return descriptor
end

-- Borrow one session-pool sampling handle for a hero material texture: the
-- single borrow per texture feeds the instance unpack, so indexed hero
-- textures bind their exact palette with no second borrow beside it. Handles
-- are cached per shared asset identity and wrap -- a reference that travels as
-- a native bank selection keys the same way a PNG path does -- and the caller
-- owns the returned borrows through its lease sink. `wait` runs once per
-- pending poll, so a staged realization yields its frame instead of spinning on
-- the classification worker. `track` publishes the outstanding ticket to the
-- owning build (nil once nothing is pending), so a release or a failure exit
-- drops that interest instead of leaving a copy in this suspended frame. A
-- failed classification fails closed naming the texture.
---@param imageAssets table<string, unknown> borrowed session image owner
---@param wrap table<string, string> resolved sampler wrap behind the borrow
---@param reference string|ModelAsset.TextureReference material texture reference
---@param cache table<string, table<string, unknown>> identity-and-wrap-keyed handle cache, mutated
---@param owned table[] acquired-lease sink, mutated
---@param wait fun()
---@param track fun(token: integer?)
---@return table<string, unknown> sampling handle {image, palette?, indexed}
local function borrowSamplingHandle(imageAssets, wrap, reference, cache, owned, wait, track)
  local identity = ModelAsset.assetIdentity(reference)
  local key = wrap.x .. "|" .. wrap.y .. "|" .. identity
  local known = cache[key]
  if known ~= nil then
    return known
  end
  -- The sampler mirrors the scene pool's shared sampler exactly: same
  -- reference and wrap resolve the same physical pair scene draws share.
  local sampler = { wrapX = wrap.x, wrapY = wrap.y, minFilter = "nearest", magFilter = "nearest" }
  local token = imageAssets:request(reference, sampler, "demand")
  track(token)
  local status, failure = imageAssets:poll(token)
  while status == "pending" do
    wait()
    status, failure = imageAssets:poll(token)
  end
  if status ~= "ready" then
    -- A failed ticket is never claimed: drop the interest before the failure
    -- unwinds so its payload stops being charged to the session owner.
    imageAssets:cancel(token)
    track(nil)
    error("hero shared image " .. identity .. " is not ready: " .. tostring(failure), 0)
  end
  local lease = imageAssets:acquire(token)
  track(nil)
  owned[#owned + 1] = lease
  local handle = {
    image = assert(lease.image, "shared borrows carry their resolved image"),
    palette = lease.palette,
    indexed = lease.kind == "r8",
  }
  cache[key] = handle
  return handle
end

---@class BagHeroBuild
---@field thread thread staged realization coroutine
---@field state string "active", "ready", or "failed"
---@field queue table<string, unknown> borrowed presentation preparation queue
---@field imageAssets table<string, unknown>? borrowed session image owner behind hero textures
---@field token integer? preparation token the suspended coroutine waits on
---@field transfer table<string, unknown>? kernel lease a take or wait transferred but the upload has not consumed
---@field imageToken integer? shared-image ticket the suspended coroutine waits on
---@field finishing boolean the explicit synchronous caller blocks instead of yielding
---@field failure unknown?

-- Drop both pending interests of one build exactly once each: the geometry
-- preparation token and the shared-image ticket route back to their own owners,
-- so a released or failed realization leaves no live packet charged to the
-- session either way. Cancellation never masks the failure that triggered it.
---@param build BagHeroBuild
local function cancelBuildTokens(build)
  local token = build.token
  if token ~= nil then
    build.token = nil
    pcall(build.queue.cancel, build.queue, token)
  end
  local imageToken = build.imageToken
  if imageToken ~= nil then
    build.imageToken = nil
    if build.imageAssets ~= nil then
      pcall(build.imageAssets.cancel, build.imageAssets, imageToken)
    end
  end
end

-- Private staged-work sentinel: the realization coroutine yields it while the
-- preparation worker or the session image owner is still busy. It charges no
-- work budget; only one realized stage does.
local BAG_HERO_WAIT = {}

-- Realize one gender: definition, render meshes, material textures, and the
-- model instance. The presentation worker decodes the hero's native model bank
-- once, every material texture resolves through the session image owner, and
-- the staged caller realizes one upload per advance instead of stalling the
-- frame that opens the bag. Only the resources this attempt creates are
-- unwound on failure; a shared pool already owned for the other gender is never
-- released here.
---@param self BagHeroRenderer
---@param gender string
---@param awaitPrepared fun(kind: string, path: string): table<string, unknown>
---@param returnPrepared fun() returns the awaited lease to the selected decoded owner
---@param waitForImage fun()
---@param trackImageToken fun(token: integer?)
function BagHeroRenderer:_realizeGender(gender, awaitPrepared, returnPrepared, waitForImage, trackImageToken)
  if self._realized[gender] ~= nil then
    return
  end
  assert(not self._released, "the bag hero renderer is released")
  local poolWasOwned = self._pool ~= nil
  local rendererWasOwned = self._renderer ~= nil
  -- The resolver answers the borrowed sampling handle itself: one borrow
  -- per texture, unpacked onto the material record by the instance, so
  -- indexed hero textures bind their exact palette. Attempt-scoped, so
  -- a failed realization returns exactly what it borrowed.
  local imageAssets = self._imageAssets
  local samplingByKey = {}
  local handleLeases = {}
  local ok, err = pcall(function()
    local pool = self._pool
    if pool == nil then
      local graphics = graphicsFor(self)
      -- Hero textures borrow the session image owner instead of private
      -- ownership; a composition without one keeps the private textures.
      pool = GpuAssetPool.new(self._cacheFs, {
        graphics = graphics,
        imageAssets = self._imageAssets,
        assetPreparation = self._assetPreparation,
        decoded = self._decoded,
      })
      self._pool = pool
    end
    local descriptor = genderDescriptor(self, gender)
    local nitroDescriptor = descriptor --[[@as ModelDefinition.Descriptor]]
    local definition = ModelDefinition.fromNitroDescriptor(nitroDescriptor, { key = "bag-hero:" .. gender })
    local renderMeshes = {}
    for _, mesh in ipairs(definition.meshes) do
      local realizedOk, resource = pcall(pool.preparedMesh, pool, mesh.geometry, awaitPrepared)
      returnPrepared()
      if not realizedOk then
        error(resource, 0)
      end
      renderMeshes[mesh.id] = resource.mesh
      mesh.center = resource.center
      coroutine["yield"](1)
    end
    local materials = assert(descriptor.materials, "the hero model must carry its materials")
    local wrapsByMaterial = {}
    for _, record in ipairs(materials) do
      wrapsByMaterial[record.id] = SceneDescriptor.wrap(record)
    end
    ---@param path string|ModelAsset.TextureReference?
    ---@param materialId integer
    ---@return unknown
    local function resolveImage(path, materialId)
      if path == nil then
        return nil
      end
      local wrap = assert(wrapsByMaterial[materialId], "the hero model has no sampler wrap")
      if imageAssets == nil then
        return pool:imageFor(path, wrap.x, wrap.y)
      end
      return borrowSamplingHandle(
        assert(imageAssets),
        wrap,
        path,
        samplingByKey,
        handleLeases,
        waitForImage,
        trackImageToken
      )
    end
    local instance = ModelInstance.new(definition, { resolveImage = resolveImage })
    instance.transform = self._modelTransform
    -- Resolve every material's texture here, not on the first draw: the
    -- session owner classifies through its worker while the bag opens, so
    -- drawing binds the already-borrowed handle and performs no acquisition.
    instance:evaluateMaterials()
    for materialIndex = 0, #definition.materials - 1 do
      instance:effectiveMaterial(materialIndex)
    end
    coroutine["yield"](1)
    if self._renderer == nil then
      local graphics = graphicsFor(self)
      self._renderer = FieldRenderer.new({ clearColor = { 0, 0, 0, 0 }, graphics = graphics })
    end
    self._realized[gender] = {
      definition = definition,
      instance = instance,
      renderMeshes = renderMeshes,
      handleLeases = handleLeases,
    }
  end)
  if not ok then
    if not rendererWasOwned and self._renderer ~= nil then
      self._renderer:release()
      self._renderer = nil
    end
    if not poolWasOwned and self._pool ~= nil then
      self._pool:release()
      self._pool = nil
    end
    if imageAssets ~= nil then
      local owned = assert(imageAssets)
      for _, lease in ipairs(handleLeases) do
        owned:release(lease)
      end
    end
    error(err, 0)
  end
end

-- Start one gender's staged realization, once. The build owns its preparation
-- token so release can drop pending interest, and the coroutine body runs the
-- realization above.
---@param gender string
---@return BagHeroBuild
function BagHeroRenderer:_startBuild(gender)
  local existing = self._builds[gender]
  if existing ~= nil then
    return existing
  end
  assert(not self._released, "the bag hero renderer is released")
  assert(gender == "male" or gender == "female", "the hero gender selects its model")
  local queue = self._assetPreparation
  ---@type BagHeroBuild
  local build
  local selfRef = self
  local function awaitPrepared(kind, path)
    local token = queue:request(kind, path, "prefetch")
    -- The staged hero build blocks on this resource: promote it alone.
    queue:promote(token, "demand")
    build.token = token
    while true do
      local status, failure = queue:poll(token)
      if status == "ready" then
        local lease = queue:take(token)
        build.token = nil
        build.transfer = lease
        return lease
      end
      if status == "failed" then
        -- The failed ticket is never claimed; the failure exit cancels it.
        error("hero asset " .. tostring(path) .. " (" .. kind .. ") failed: " .. tostring(failure), 0)
      end
      if build.finishing then
        local waitOk, lease = pcall(queue.wait, queue, token)
        if not waitOk then
          error(lease, 0)
        end
        build.token = nil
        build.transfer = lease
        return lease
      end
      coroutine["yield"](BAG_HERO_WAIT)
    end
  end
  -- A staged build yields its frame budget while the session image owner is
  -- still working; the explicit synchronous caller has no checkpoint to yield,
  -- so it sleeps instead of polling the owner in a tight loop.
  local function waitForImage()
    if build.finishing then
      SynchronousWait.block()
      return
    end
    coroutine["yield"](BAG_HERO_WAIT)
  end
  local function trackImageToken(token)
    build.imageToken = token
  end
  -- Return the lease a take or wait transferred out of the queue but whose
  -- upload did not consume it: a failed realization, a build failure or a
  -- release returns it exactly once through the selected decoded owner.
  local function returnPrepared()
    local lease = build.transfer
    build.transfer = nil
    if lease ~= nil then
      selfRef:_returnLease(lease)
    end
  end
  build = {
    thread = coroutine.create(function()
      selfRef:_realizeGender(gender, awaitPrepared, returnPrepared, waitForImage, trackImageToken)
    end),
    state = "active",
    queue = queue,
    imageAssets = self._imageAssets,
    token = nil,
    transfer = nil,
    imageToken = nil,
    finishing = false,
    failure = nil,
  }
  self._builds[gender] = build
  return build
end

---@param owner BagHeroRenderer
---@param build BagHeroBuild
---@param maxWorkUnits integer
---@return integer consumed main-thread work units
local function advanceBuild(owner, build, maxWorkUnits)
  if build.failure ~= nil then
    error(build.failure, 0)
  end
  if build.state ~= "active" or maxWorkUnits == 0 then
    return 0
  end
  local consumed = 0
  while consumed < maxWorkUnits and build.state == "active" do
    local ok, yielded = coroutine.resume(build.thread)
    if not ok then
      build.state = "failed"
      cancelBuildTokens(build)
      local lease = build.transfer
      if lease ~= nil then
        build.transfer = nil
        owner:_returnLease(lease)
      end
      build.failure = yielded
      error(yielded, 0)
    end
    if coroutine.status(build.thread) == "dead" then
      build.state = "ready"
    elseif yielded == BAG_HERO_WAIT then
      break
    else
      assert(yielded == 1, "hero realization yielded an invalid work unit")
      consumed = consumed + 1
    end
  end
  return consumed
end

-- Advance one gender's staged realization by a bounded number of main-thread
-- work units (one realized mesh upload or material resolution each) and report
-- whether the hero can draw. The field presentation update phase calls this
-- before drawing, so the first painted bag frame performs no decode or upload.
---@param gender string
---@param maxWorkUnits integer?
---@return boolean ready
function BagHeroRenderer:prepare(gender, maxWorkUnits)
  assert(not self._released, "the bag hero renderer is released")
  if self._realized[gender] ~= nil then
    return true
  end
  local build = self:_startBuild(gender)
  advanceBuild(self, build, maxWorkUnits or 1)
  return self._realized[gender] ~= nil
end

-- Whether one gender's model is resident and drawable without any work.
---@param gender string
---@return boolean
function BagHeroRenderer:isReady(gender)
  return self._realized[gender] ~= nil
end

-- Realize one gender now: the explicit blocking entry for a caller that draws
-- without advancing preparation first. Staged callers use prepare instead.
---@param gender string
function BagHeroRenderer:_ensureGender(gender)
  if self._realized[gender] ~= nil then
    return
  end
  local build = self:_startBuild(gender)
  build.finishing = true
  while build.state == "active" do
    advanceBuild(self, build, 1)
  end
end

-- This leaf mutates depth, cull, and wireframe state the native "all" stack
-- does not cover, so it saves those three explicitly and restores them on
-- the successful path. Every other touched state rides the native stack. A
-- draw failure is terminal and propagates immediately with no cleanup.
---@param self BagHeroRenderer
---@param realized BagHeroRealization
---@param placement table<string, unknown> the complete hero placement selecting the full frame and visible clip
local function drawCanonicalModel(self, realized, placement)
  local graphics = graphicsFor(self)
  local target = assert(self._modelCanvas)
  local callerCanvas = graphics.getCanvas()
  local outerSX, outerSY, outerSW, outerSH = graphics.getScissor()
  local depthMode, depthWrite = graphics.getDepthMode()
  local cullMode = graphics.getMeshCullMode()
  local wireframe = graphics.isWireframe()
  graphics.push("all")
  graphics.setCanvas(target)
  graphics.setScissor()
  graphics.setShader()
  graphics.setDepthMode()
  graphics.setColor(1, 1, 1, 1)
  graphics.clear(0, 0, 0, 0)
  local view = self._view
  local projection = self._projection
  ---@return number[]
  local function cameraView()
    return view
  end
  ---@return number[]
  local function cameraProjection()
    return projection
  end
  ---@return number[]
  local function cameraBillboardProjection()
    return projection
  end
  assert(self._renderer, "the hero renderer is realized before drawing"):draw(
    self._sceneRuntime,
    {
      far = self._cameraFar,
      zoom = 1,
      view = cameraView,
      projection = cameraProjection,
      billboardProjection = cameraBillboardProjection,
    },
    { realized.instance:drawItems(realized.renderMeshes) },
    nil,
    {
      worldViewport = { x = 0, y = 0, width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT },
      referenceFrame = { x = 0, y = 0, width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT },
    },
    1
  )

  graphics.setCanvas(callerCanvas)
  graphics.setShader()
  graphics.setDepthMode()
  graphics.setWireframe(false)
  graphics.setBlendMode("alpha", "alphamultiply")
  graphics.setColor(1, 1, 1, 1)
  if outerSX ~= nil then
    graphics.setScissor(outerSX, outerSY, outerSW, outerSH)
  else
    graphics.setScissor()
  end
  -- One host composite at the full frame under the visible clip: the
  -- source-sized raster maps through the placement once, so neither the
  -- camera nor the 2D transform compensates for the crop.
  LogicalSurface.draw(graphics, placement, function()
    graphics.draw(target, 0, 0)
  end)
  if depthMode then
    graphics.setDepthMode(depthMode, depthWrite)
  end
  if cullMode then
    graphics.setMeshCullMode(cullMode)
  end
  graphics.setWireframe(wireframe)
  graphics.pop()
end

-- Restart the active clips for a new semantic state (or a backward frame):
-- resolve every clip first so a malformed binding leaves the previous
-- attachments playing, then stop the old clips, play pose, pattern, and the
-- gender material clip in looping mode, and reset the synchronized frame.
---@param realized BagHeroRealization
---@param gender string
---@param pocket string
---@param pose string
---@param pattern string
---@param materialId string
local function restartClips(self, realized, gender, pocket, pose, pattern, materialId)
  local instance = realized.instance
  local definition = realized.definition
  local poseClip = definition:animation(pose)
  assert(poseClip ~= nil, "the hero has no pose clip " .. tostring(pose))
  local patternClip = definition:animation(pattern)
  assert(patternClip ~= nil, "the hero has no pattern clip " .. tostring(pattern))
  local materialClip = definition:animation(materialId)
  assert(materialClip ~= nil, "the hero has no material clip " .. tostring(materialId))
  local previous = self._sync[gender]
  if previous ~= nil then
    for _, attachment in ipairs(previous.attachments) do
      instance:stop(attachment)
    end
  end
  local attachments = {}
  local ok, err = pcall(function()
    attachments[1] = instance:play(pose, { loopMode = "loop" })
    attachments[2] = instance:play(pattern, { loopMode = "loop" })
    attachments[3] = instance:play(materialId, { loopMode = "loop" })
  end)
  if not ok then
    for _, attachment in ipairs(attachments) do
      instance:stop(attachment)
    end
    self._sync[gender] = nil
    error(err, 0)
  end
  self._sync[gender] = { pocket = pocket, pose = pose, pattern = pattern, frame = 0, attachments = attachments }
end

-- Catch up the active players by exactly the outstanding fixed steps: every
-- attached clip advances by the full delta, matching ModelInstance:updateFixed
-- semantics. A repeated draw at the synchronized frame advances nothing.
---@param realized BagHeroRealization
---@param steps integer
local function advancePlayers(realized, steps)
  for _ = 1, steps do
    realized.instance:updateFixed()
  end
end

-- Draws the gender hero for one presenter status inside one complete hero
-- placement. The status record is only read: draws never advance the
-- semantic frame or reselect the pocket. The model itself always renders
-- at canonical size into its source-sized target before the placement
-- scales that raster once at the full frame under the visible clip. The
-- interpolated framing selects the per-draw camera distance/angles and the
-- model base height; the static target, perspective, clip, base X/Z,
-- rotation, and scale stay from the manifest.
---@param gender string
---@param heroStatus { pocket: string, pose: string, pattern: string, frame: integer, framing: { angleXDegrees: number, angleYDegrees: number, distance: number, modelY: number } }
---@param heroPlacement table<string, unknown>
function BagHeroRenderer:draw(gender, heroStatus, heroPlacement)
  assert(not self._released, "the bag hero renderer is released")
  assert(gender == "male" or gender == "female", "the hero gender selects its model")
  assert(type(heroStatus) == "table", "the hero draw requires its presenter status")
  local pocket = heroStatus.pocket
  assert(type(pocket) == "string" and pocket ~= "", "the hero status names its pocket")
  local pose = heroStatus.pose
  assert(type(pose) == "string" and pose ~= "", "the hero status names its pose clip")
  local pattern = heroStatus.pattern
  assert(type(pattern) == "string" and pattern ~= "", "the hero status names its pattern clip")
  local frame = heroStatus.frame
  assert(type(frame) == "number" and frame % 1 == 0 and frame >= 0, "the hero status carries its frame")
  local framing = assert(heroStatus.framing, "the hero status carries its interpolated framing")
  local angleX = finiteNumber(framing.angleXDegrees, "the hero framing pitch must be finite")
  local angleY = finiteNumber(framing.angleYDegrees, "the hero framing yaw must be finite")
  local distance = finiteNumber(framing.distance, "the hero framing distance must be finite")
  assert(distance > 0, "the hero framing distance must be positive")
  local modelY = finiteNumber(framing.modelY, "the hero framing model height must be finite")
  assert(type(heroPlacement) == "table", "the hero draw requires its placement")
  assert(type(heroPlacement.frame) == "table", "the hero placement carries its full frame")
  assert(
    type(heroPlacement.scale) == "number" and heroPlacement.scale > 0,
    "the hero placement carries its positive scale"
  )
  self:_ensureGender(gender)
  ensureModelCanvas(self)
  local realized = assert(self._realized[gender], "the hero model is realized before drawing")
  local cameraFacts = self._cameraFacts --[[@as table<string, unknown>]]
  local camera = buildCamera({
    target = cameraFacts.target,
    distance = distance,
    angleXDegrees = angleX,
    angleYDegrees = angleY,
    perspectiveType = cameraFacts.perspectiveType,
    perspectiveAngle = cameraFacts.perspectiveAngle,
    clipNear = cameraFacts.clipNear,
    clipFar = cameraFacts.clipFar,
  }, self._logicalSize)
  self._view = camera.view
  self._projection = camera.projection
  self._cameraFar = camera.far
  local transformFacts = self._transformFacts --[[@as table<string, unknown>]]
  local staticTranslation = assert(transformFacts.translation, "the hero transform must carry its translation")
  local translation = staticTranslation --[[@as table<string, unknown>]]
  self._modelTransform = buildModelTransform({
    translation = {
      x = assert(translation.x, "the hero transform must carry its translation x"),
      y = modelY,
      z = assert(translation.z, "the hero transform must carry its translation z"),
    },
    rotation = transformFacts.rotation,
    scale = transformFacts.scale,
  })
  realized.instance.transform = self._modelTransform
  local hero = self._manifest.hero
  local materialId = hero.animations.material[gender]
  assert(type(materialId) == "string" and materialId ~= "", "the hero carries its gender material binding")
  local sync = self._sync[gender]
  if sync == nil or sync.pocket ~= pocket or sync.pose ~= pose or sync.pattern ~= pattern or frame < sync.frame then
    restartClips(self, realized, gender, pocket, pose, pattern, materialId)
    sync = assert(self._sync[gender], "the hero restart synchronizes its clips")
  end
  if frame > sync.frame then
    advancePlayers(realized, frame - sync.frame)
    sync.frame = frame
  end
  realized.instance:evaluatePose()
  drawCanonicalModel(self, realized, heroPlacement)
end

-- Return one kernel lease through the selected decoded owner and trim idle
-- residency, matching every other prepared consumer.
---@param lease table<string, unknown>
function BagHeroRenderer:_returnLease(lease)
  local decoded = assert(self._decoded, "the bag hero renderer lost its selected decoded owner")
  decoded:returnLease(lease)
  decoded:trim()
end

-- Idempotent release of the owned pool and renderer. Borrowed manifest data
-- and per-gender instances (whose GPU objects the pool owns) need no further
-- disposal; sampling borrows return to the session owner with the
-- realization that holds them; a release after a failed realization stays
-- a safe no-op.
function BagHeroRenderer:release()
  if self._released then
    return
  end
  self._released = true
  local imageAssets = self._imageAssets
  if imageAssets ~= nil then
    local owned = assert(imageAssets)
    for _, realized in pairs(self._realized) do
      for _, lease in ipairs(realized.handleLeases or {}) do
        owned:release(lease)
      end
      realized.handleLeases = {}
    end
  end
  -- A build still in progress drops its pending preparation and shared-image
  -- interests; a running worker job is not preempted, its late payload is
  -- discarded.
  for _, build in pairs(self._builds) do
    cancelBuildTokens(build)
    local lease = build.transfer
    if lease ~= nil then
      build.transfer = nil
      self:_returnLease(lease)
    end
  end
  self._builds = {}
  self._realized = {}
  self._sync = {}
  if self._renderer ~= nil then
    self._renderer:release()
    self._renderer = nil
  end
  if self._pool ~= nil then
    self._pool:release()
    self._pool = nil
  end
  if self._modelCanvas ~= nil then
    self._modelCanvas:release()
    self._modelCanvas = nil
  end
end

return BagHeroRenderer
