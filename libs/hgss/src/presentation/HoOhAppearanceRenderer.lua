-- Lazily realizes the original Ho-Oh cutscene models and draws their live scene poses.

local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local ImageSampling = require("libs.nds.src.love.ImageSampling")

local HoOhAppearanceRenderer = {}
HoOhAppearanceRenderer.__index = HoOhAppearanceRenderer

---@class HoOhAppearanceRenderer.Entry
---@field descriptor table<string, unknown> the generated model descriptor
---@field definition table<string, unknown> the ModelDefinition built from it
---@field meshes table<string, unknown> render meshes by mesh id
---@field pool table<string, unknown> the pool that owns this model's meshes and texture leases

---@class HoOhAppearanceRenderer
---@field cacheFs CacheFs?
---@field imageAssets table<string, unknown>
---@field versionId string?
---@field variant integer? the time-of-day variant whose cinematic is held
---@field corePool table<string, unknown>? owns the bell, shimmer, corner, bird and waves models and the leaf overlay
---@field cinematicPool table<string, unknown>? owns the held variant's cinematic models
---@field core table<string, unknown>? the loaded core record
---@field definitions table<string, HoOhAppearanceRenderer.Entry>? built models by role name
---@field leafHandles table<string, table<integer, table<string, unknown>>>?
---@field done table<string, true>? preparation units already run
---@field prepared boolean? every preparation unit has run for the held version and variant
---@field ready table<string, true>? draw groups known complete
---@field building table<string, table<string, unknown>>? models whose meshes are still being built, by role name
---@field leafWork table<string, unknown>? the leaf overlay frames still to load
---@field cinematicDescriptors table<string, table<string, unknown>>? loaded cinematic descriptors by shot
---@field sequence integer? the scene run whose animation state is held
---@field instances table<string, unknown>? per-run model instances by name
---@field lastFrames table<string, integer>? per-run animation frames already advanced
---@field bellAnimationSet string? per-run bell animation set
---@field _cinematicEnvironment { base: table<string, unknown>, environment: table<string, unknown> }?
---@field new fun(cacheFs: CacheFs, imageAssets: table<string, unknown>): HoOhAppearanceRenderer
---@field prepareStep fun(self: HoOhAppearanceRenderer, versionId: string, variant: integer): boolean
---@field cancel fun(self: HoOhAppearanceRenderer)
---@field drawItems fun(self: HoOhAppearanceRenderer, status: table<string, unknown>): table<string, unknown>[]
---@field backdropCopies fun(self: HoOhAppearanceRenderer, mapDraws: table<string, unknown>[], versionId: string): table<string, unknown>[]
---@field cinematicEnvironment fun(self: HoOhAppearanceRenderer, base: table<string, unknown>): table<string, unknown>
---@field endScene fun(self: HoOhAppearanceRenderer)
---@field release fun(self: HoOhAppearanceRenderer)
---@field dispose fun(self: HoOhAppearanceRenderer)

-- The cinematic application's own edge marking (RGB555) and fog-less pipeline.
local CINEMATIC_EDGE_COLORS = { [0] = 0x0000, 0x1084, 0x1084, 0x1084, 0x1084, 0x1084, 0x1084, 0x1084 }

-- The Bell Tower sky wall the cutscene cameras look at (HeartGold: building
-- 187, 68 tiles wide). Wide displays see past its ends, so the cutscene repeats
-- it once to each side.
local BACKDROP_WALLS = { heartgold = { modelKeyPrefix = "outdoor:187:", width = 68 } }

local CORE_MODEL_NAMES = { "bellRising", "bellShimmer", "cornerBells", "birdApproach", "wavesEffect" }
local SHOTS = { "first", "second" }

-- The most work one preparation step does in a heavy unit: meshes built for a
-- model, and leaf overlay images decoded.
HoOhAppearanceRenderer.MESHES_PER_STEP = 32
HoOhAppearanceRenderer.LEAF_IMAGES_PER_STEP = 1

---@param cacheFs CacheFs
---@param imageAssets table<string, unknown>
---@return HoOhAppearanceRenderer
function HoOhAppearanceRenderer.new(cacheFs, imageAssets)
  assert(cacheFs and cacheFs.loadLua, "Ho-Oh renderer requires the generated cache")
  assert(imageAssets, "Ho-Oh renderer requires the shared image owner")
  return setmetatable({ cacheFs = cacheFs, imageAssets = imageAssets }, HoOhAppearanceRenderer)
end

local function modelName(descriptor)
  return assert(
    descriptor.key:match("field%-effect:ho%-oh%-appearance:(.+)$"),
    "Ho-Oh model descriptor has no semantic key"
  )
end

-- Builds one model's definition and render meshes into `pool`, one slice of
-- MESHES_PER_STEP meshes per call. True once the model is complete and
-- published in `self.definitions`; false while slices remain.
---@param self HoOhAppearanceRenderer
---@param pool table<string, unknown>
---@param descriptor table<string, unknown>
---@return boolean complete
local function buildSlice(self, pool, descriptor)
  local name = modelName(descriptor)
  self.building = self.building or {}
  local work = self.building[name]
  if work == nil then
    work = {
      definition = ModelDefinition.fromNitroDescriptor(descriptor, { key = "field-effect:ho-oh:" .. name }),
      meshes = {},
      next = 1,
    }
    self.building[name] = work
  end
  local list = work.definition.meshes
  local last = math.min(#list, work.next + HoOhAppearanceRenderer.MESHES_PER_STEP - 1)
  for index = work.next, last do
    local mesh = list[index]
    local resource = pool:meshFor(mesh.geometry)
    mesh.center = resource.center
    work.meshes[mesh.id] = resource.mesh
  end
  work.next = last + 1
  if work.next <= #list then
    return false
  end
  self.building[name] = nil
  assert(self.definitions)[name] =
    { descriptor = descriptor, definition = work.definition, meshes = work.meshes, pool = pool }
  return true
end

-- The preparation units, in order. Each is idempotent through `self.done`, so
-- background preparation and a synchronous draw share one completion state.
---@param self HoOhAppearanceRenderer
---@param versionId string
---@return { name: string, run: fun(): boolean? }[]
local function unitsFor(self, versionId)
  local units = {}
  local function add(name, run)
    units[#units + 1] = { name = name, run = run }
  end
  add("core.record", function()
    self.core = FieldEffectAssetCache.loadHoOhCore(assert(self.cacheFs, "Ho-Oh renderer is disposed"))
  end)
  for index, name in ipairs(CORE_MODEL_NAMES) do
    add("core.model." .. name, function()
      local pool = assert(self.corePool)
      local descriptor = assert(assert(self.core).models[index], "Ho-Oh core model is missing: " .. name)
      assert(modelName(descriptor) == name, "Ho-Oh core model role order changed")
      return buildSlice(self, pool, descriptor)
    end)
  end
  if versionId == "heartgold" then
    add("core.leaves", function()
      local pool = assert(self.corePool)
      local work = self.leafWork
      if work == nil then
        local leaves = assert(assert(self.core).leaves, "HeartGold Ho-Oh record has no leaf overlay")
        work = { handles = { bg3 = {}, bg2 = {} }, queue = {}, next = 1 }
        for _, layerName in ipairs({ "bg3", "bg2" }) do
          local layer = assert(leaves[layerName], "Ho-Oh leaf layer is missing: " .. layerName)
          for frameIndex, frame in ipairs(layer.frames) do
            work.queue[#work.queue + 1] = { layerName = layerName, frameIndex = frameIndex, path = frame.path }
          end
        end
        self.leafWork = work
      end
      for _ = 1, HoOhAppearanceRenderer.LEAF_IMAGES_PER_STEP do
        local item = work.queue[work.next]
        if item == nil then
          break
        end
        work.handles[item.layerName][item.frameIndex] = assert(pool:sharedImage(item.path, "repeat", "repeat"))
        work.next = work.next + 1
      end
      if work.next <= #work.queue then
        return false
      end
      self.leafHandles = work.handles
      self.leafWork = nil
      return true
    end)
  end
  for _, shot in ipairs(SHOTS) do
    add("cinematic." .. shot .. ".load", function()
      local variant = assert(self.variant)
      self.cinematicDescriptors = self.cinematicDescriptors or {}
      self.cinematicDescriptors[shot] =
        FieldEffectAssetCache.loadHoOhCinematic(assert(self.cacheFs, "Ho-Oh renderer is disposed"), shot, variant)
    end)
    add("cinematic." .. shot .. ".build", function()
      local pool = assert(self.cinematicPool)
      local descriptor = assert(assert(self.cinematicDescriptors)[shot])
      local complete = buildSlice(self, pool, descriptor)
      if complete then
        self.cinematicDescriptors[shot] = nil
      end
      return complete
    end)
  end
  return units
end

---@param self HoOhAppearanceRenderer
local function ensurePools(self)
  self.definitions = self.definitions or {}
  self.done = self.done or {}
  if self.corePool == nil then
    self.corePool =
      GpuAssetPool.new(assert(self.cacheFs, "Ho-Oh renderer is disposed"), { imageAssets = self.imageAssets })
  end
  if self.cinematicPool == nil and self.variant ~= nil then
    self.cinematicPool =
      GpuAssetPool.new(assert(self.cacheFs, "Ho-Oh renderer is disposed"), { imageAssets = self.imageAssets })
  end
end

-- Drops the held cinematic variant: its pool, definitions and progress.
---@param self HoOhAppearanceRenderer
local function dropCinematic(self)
  local pool = self.cinematicPool
  if pool ~= nil then
    self.cinematicPool = nil
    pool:release()
  end
  for _, shot in ipairs(SHOTS) do
    for key in pairs(self.definitions or {}) do
      if key:find("^cinematic%." .. shot .. "%.") then
        self.definitions[key] = nil
      end
    end
    for _, suffix in ipairs({ ".load", ".build" }) do
      if self.done ~= nil then
        self.done["cinematic." .. shot .. suffix] = nil
      end
    end
  end
  self.cinematicDescriptors = nil
  self.variant = nil
  self.prepared, self.ready = nil, nil
  for name in pairs(self.building or {}) do
    if name:find("^cinematic%.") then
      self.building[name] = nil
    end
  end
  -- Instances built from the dropped models cannot outlive them.
  if self.instances ~= nil then
    for name in pairs(self.instances) do
      if name:find("^cinematic%.") then
        self.instances[name] = nil
      end
    end
  end
end

-- Aligns the held assets with the requested game version and variant: a new
-- version drops everything, a new variant drops only the cinematic.
---@param self HoOhAppearanceRenderer
---@param versionId string
---@param variant integer?
local function align(self, versionId, variant)
  if self.versionId ~= nil and self.versionId ~= versionId then
    self:release()
  end
  self.versionId = versionId
  if variant ~= nil and self.variant ~= variant then
    dropCinematic(self)
    self.variant = variant
  end
  ensurePools(self)
end

-- Runs one unit until it is complete, or for a single slice when `single`.
-- A unit reports false while it has slices left; anything else is complete.
---@param self HoOhAppearanceRenderer
---@param unit { name: string, run: fun(): boolean? }
---@param single boolean? stop after one slice
---@return boolean complete
local function runOnce(self, unit, single)
  if assert(self.done)[unit.name] then
    return true
  end
  repeat
    local ok, result = pcall(unit.run)
    if not ok then
      -- A failed unit leaves partial pool contents: drop everything so the
      -- renderer is consistent (unprepared) again.
      self:release()
      error(result, 0)
    end
    if result ~= false then
      self.done[unit.name] = true
      return true
    end
  until single
  return false
end

-- Runs the units for the core group, or the cinematic group of one shot, that
-- have not run yet; a group known complete costs nothing.
---@param self HoOhAppearanceRenderer
---@param group string "core" or "cinematic"
---@param shot string?
local function ensureGroup(self, group, shot)
  local key = group .. (shot or "")
  if self.ready ~= nil and self.ready[key] then
    return
  end
  for _, unit in ipairs(unitsFor(self, assert(self.versionId))) do
    local inGroup = unit.name:find("^" .. group .. "%.") ~= nil
    local forShot = shot == nil or group == "core" or unit.name:find("^cinematic%." .. shot .. "%.") ~= nil
    if inGroup and forShot then
      runOnce(self, unit, false)
    end
  end
  self.ready = self.ready or {}
  self.ready[key] = true
end

-- Runs one slice of preparation for the given game version and cinematic
-- variant and reports whether everything is prepared. The caller owns the time
-- budget by calling this as long as its budget lasts; a finished preparation
-- answers at once. A failed unit releases the pools it touched and raises.
---@param versionId string
---@param variant integer
---@return boolean complete
function HoOhAppearanceRenderer:prepareStep(versionId, variant)
  align(self, versionId, variant)
  if self.prepared then
    return true
  end
  local units = unitsFor(self, versionId)
  for index, unit in ipairs(units) do
    if not self.done[unit.name] then
      runOnce(self, unit, true)
      for rest = index, #units do
        if not self.done[units[rest].name] then
          return false
        end
      end
      break
    end
  end
  self.prepared = true
  return true
end

-- Drops unfinished and unneeded work: both pools, their models and progress.
-- An unprepared renderer stays consistent and rebuilds on demand.
function HoOhAppearanceRenderer:cancel()
  self:release()
end

---@param self HoOhAppearanceRenderer
---@param name string
---@return table<string, unknown> instance
local function instanceFor(self, name)
  local instances = assert(self.instances)
  local instance = instances[name]
  if instance ~= nil then
    return instance
  end
  local source, roles, loopMode = name, nil, nil
  if name == "bellRising" then
    roles, loopMode = { "bell.rise.joint", "bell.rise.pattern", "bell.rise.srt" }, "once"
  elseif name == "bellShimmer" then
    roles = { "bell.shimmer.joint", "bell.shimmer.srt" }
  elseif name:find("^cornerBells%d$") then
    source, roles = "cornerBells", { "corner_bells.srt" }
  elseif name == "birdApproach" then
    roles = { "bird.joint", "bird.color", "bird.pattern" }
  elseif name == "wavesEffect" then
    roles = { "waves.joint", "waves.srt" }
  else
    local shot = assert(name:match("^cinematic%.(%a+)%.%d$"), "unknown Ho-Oh instance: " .. name)
    roles = { name .. ".trs", name .. ".color", name .. ".texsrt" }
    if shot == "first" then
      roles = { name .. ".trs", name .. ".color", name .. ".pattern", name .. ".texsrt" }
    end
    loopMode = "once"
  end
  local entry = assert(assert(self.definitions)[source], "Ho-Oh model is not built: " .. source)
  local wraps = SceneDescriptor.wrapByMaterial(entry.descriptor.materials)
  local function resolveImage(path, materialId)
    local wrap = assert(wraps[materialId], "Ho-Oh material wrap is missing")
    return entry.pool:sharedImage(path, wrap.x, wrap.y)
  end
  instance = ModelInstance.new(entry.definition, { resolveImage = resolveImage })
  instance.renderMeshesById = entry.meshes
  for _, role in ipairs(roles) do
    instance:play(role, { loopMode = loopMode })
  end
  instances[name] = instance
  return instance
end

-- First tile origin at or before `edge` on a grid of `period` anchored at `origin`.
local function tileStart(origin, edge, period)
  return origin - math.ceil((origin - edge) / period) * period
end

---@param status table<string, unknown>
---@param viewport table<string, unknown>
function HoOhAppearanceRenderer:drawLeaves(status, viewport)
  if status.leavesActive ~= true then
    return
  end
  align(self, status.versionId or assert(self.versionId, "the leaf overlay needs a game version"))
  ensureGroup(self, "core")
  assert(self.versionId == "heartgold" and self.leafHandles, "HeartGold leaf overlay is not loaded")
  local bounds = assert(viewport.worldViewport)
  local frameRect = assert(viewport.referenceFrame)
  local scale = frameRect.width / 256
  local tileSize = 256 * scale
  local frame = assert(status.leafFrame)
  assert(type(frame) == "number" and frame >= 0 and frame % 1 == 0, "leaf frame is invalid")
  local frameIndex = math.floor(frame / 6) % 6 + 1
  local scroll = frame % 256
  local graphics = love.graphics
  graphics.push("all")
  graphics.setScissor(bounds.x, bounds.y, bounds.width, bounds.height)
  graphics.setColor(1, 1, 1, 1)
  for _, layerName in ipairs({ "bg3", "bg2" }) do
    local handle = assert(self.leafHandles[layerName][frameIndex])
    local scrollX = layerName == "bg2" and ((256 - scroll) % 256) or scroll
    local scrollY = (256 - scroll) % 256
    local startX = tileStart(frameRect.x - scrollX * scale, bounds.x, tileSize)
    local startY = tileStart(frameRect.y - scrollY * scale, bounds.y, tileSize)
    for y = startY, bounds.y + bounds.height - 1, tileSize do
      for x = startX, bounds.x + bounds.width - 1, tileSize do
        ImageSampling.draw(graphics, handle, nil, x, y, 0, scale, scale)
      end
    end
  end
  graphics.pop()
end

local function advance(instance, frames, count)
  for _ = frames + 1, count do
    instance:updateFixed()
  end
end

local function addDraws(output, instance, position, role)
  instance.transform = Matrix4.translate(position.x, position.y, position.z)
  instance:evaluatePose()
  for _, item in ipairs(instance:drawItems(assert(instance.renderMeshesById))) do
    -- The source animations hide unrevealed particles at polygon alpha zero,
    -- which the GX renderer would otherwise outline as wireframes.
    if item.polygonAlpha ~= 0 then
      item.worldSpace = true
      item.fieldEffect = "ho_oh_appearance"
      item.fieldEffectRole = role
      output[#output + 1] = item
    end
  end
end

---@param status table<string, unknown>
---@return table<string, unknown>[]
function HoOhAppearanceRenderer:drawItems(status)
  if status.active ~= true then
    self:endScene()
    return {}
  end
  align(self, assert(status.versionId), status.cinematicShot ~= nil and assert(status.cinematicVariant) or nil)
  if self.sequence ~= status.sequence then
    self.sequence = status.sequence
    self.instances = {}
    self.lastFrames = { bell = 0, loop = 0, shimmer = 0, corners = 0, bird = 0, waves = 0 }
    self.bellAnimationSet = "rise"
  end
  local output, origin = {}, assert(status.origin)
  local frames = assert(self.lastFrames)
  if status.bellStage ~= nil then
    ensureGroup(self, "core")
    local bellFrame = assert(status.bellFrame)
    local rising = instanceFor(self, "bellRising")
    local loopFrame = status.loopFrame
    if loopFrame ~= nil and self.bellAnimationSet == "rise" then
      for _, role in ipairs({ "bell.rise.joint", "bell.rise.pattern", "bell.rise.srt" }) do
        assert(rising:stop(role) == 1, "Ho-Oh rise animation is attached")
      end
      for _, role in ipairs({ "bell.loop.joint", "bell.loop.pattern", "bell.loop.srt" }) do
        rising:play(role, { loopMode = "loop" })
      end
      self.bellAnimationSet = "loop"
    end
    if self.bellAnimationSet == "rise" then
      advance(rising, frames.bell, bellFrame)
      frames.bell = bellFrame
    else
      advance(rising, frames.loop, assert(loopFrame))
      frames.loop = loopFrame
    end
    if status.bellVisible == true and status.shimmerFrame == nil then
      addDraws(output, rising, origin, "clear_bell_rising")
    end
    if status.shimmerFrame ~= nil then
      local shimmerFrame = assert(status.shimmerFrame)
      local shimmerInstance = instanceFor(self, "bellShimmer")
      advance(shimmerInstance, frames.shimmer, shimmerFrame)
      frames.shimmer = shimmerFrame
      addDraws(output, shimmerInstance, origin, "clear_bell_shimmer")
      if status.shimmerClearBellOnly ~= true then
        local offsets = assert(status.cornerOffsets)
        for index, offset in ipairs(offsets) do
          local corners = instanceFor(self, "cornerBells" .. index)
          advance(corners, frames.corners, shimmerFrame)
          local position = { x = origin.x + offset[1], y = origin.y + offset[2], z = origin.z + offset[3] }
          addDraws(output, corners, position, "corner_bells_" .. index)
        end
        frames.corners = shimmerFrame
      end
    end
  elseif status.birdFrame ~= nil then
    -- The model is the legend's cry ring: the legend itself is the map actor.
    local ringFrame = status.birdRingFrame
    if ringFrame ~= nil then
      ensureGroup(self, "core")
      local bird = instanceFor(self, "birdApproach")
      advance(bird, frames.bird, ringFrame)
      frames.bird = ringFrame
      local versionId = assert(status.versionId)
      local ringPosition = {
        x = origin.x,
        y = origin.y + (versionId == "heartgold" and 2.5 or 0),
        z = origin.z - (versionId == "heartgold" and 1 or 17.5),
      }
      addDraws(output, bird, ringPosition, "ho_oh_approach")
    end
  elseif status.cinematicShot ~= nil then
    local shot = assert(status.cinematicShot)
    assert(shot == "first" or shot == "second", "Ho-Oh cinematic shot is invalid")
    local variant = assert(status.cinematicVariant)
    assert(variant >= 0 and variant <= 2 and variant % 1 == 0, "Ho-Oh cinematic variant is invalid")
    local name = "cinematic." .. shot .. "." .. variant
    ensureGroup(self, "cinematic", shot)
    local instance = instanceFor(self, name)
    local frameKey = "cinematic:" .. name
    local modelFrame = assert(status.cinematicModelFrame)
    advance(instance, frames[frameKey] or 0, modelFrame)
    frames[frameKey] = modelFrame
    addDraws(output, instance, origin, "ho_oh_cinematic_" .. shot)
  end
  if status.effectsActive == true and status.versionId == "soulsilver" then
    ensureGroup(self, "core")
    local effectFrame = assert(status.effectFrame)
    local waves = instanceFor(self, "wavesEffect")
    advance(waves, frames.waves, effectFrame)
    frames.waves = effectFrame
    addDraws(output, waves, origin, "waves")
  end
  return output
end

-- Copies of the map's sky wall one wall width to each side.
---@param mapDraws table<string, unknown>[]
---@param versionId string
---@return table<string, unknown>[]
function HoOhAppearanceRenderer:backdropCopies(mapDraws, versionId)
  local wall = BACKDROP_WALLS[versionId]
  local copies = {}
  if wall == nil then
    return copies
  end
  for _, item in ipairs(mapDraws) do
    local key = item.modelKey
    if type(key) == "string" and key:sub(1, #wall.modelKeyPrefix) == wall.modelKeyPrefix then
      for _, side in ipairs({ -1, 1 }) do
        local copy = {}
        for field, value in pairs(item) do
          copy[field] = value
        end
        local transform = { unpack(item.transform, 1, 16) }
        transform[13] = transform[13] + side * wall.width
        copy.transform = transform
        copies[#copies + 1] = copy
      end
    end
  end
  return copies
end

-- The field render environment with the cinematic application's edge colors
-- and no fog: the cinematic is not drawn through the map's own atmosphere.
---@param base table<string, unknown>
---@return table<string, unknown>
function HoOhAppearanceRenderer:cinematicEnvironment(base)
  local cached = self._cinematicEnvironment
  if cached ~= nil and cached.base == base then
    return cached.environment
  end
  local fogTable = {}
  for index = 1, 32 do
    fogTable[index] = 0
  end
  local environment = setmetatable({
    edgeColors = CINEMATIC_EDGE_COLORS,
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
  }, { __index = base })
  self._cinematicEnvironment = { base = base, environment = environment }
  return environment
end

-- The scene is no longer drawn: release its cinematic model pool while the
-- core and its leaf textures remain available to field presentation.
function HoOhAppearanceRenderer:endScene()
  if self.sequence ~= nil then
    self.sequence, self.instances, self.lastFrames, self.bellAnimationSet = nil, nil, nil, nil
    dropCinematic(self)
  end
end

-- Drops every built model and pool, each released exactly once.
function HoOhAppearanceRenderer:release()
  self:endScene()
  local core, cinematic = self.corePool, self.cinematicPool
  self.corePool, self.cinematicPool = nil, nil
  self.core, self.definitions, self.leafHandles, self.done, self.cinematicDescriptors = nil, nil, nil, nil, nil
  self.prepared, self.ready, self.building, self.leafWork = nil, nil, nil, nil
  self.versionId, self.variant = nil, nil
  if cinematic ~= nil then
    cinematic:release()
  end
  if core ~= nil then
    core:release()
  end
end

function HoOhAppearanceRenderer:dispose()
  self:release()
  self.cacheFs = nil
end

return HoOhAppearanceRenderer
