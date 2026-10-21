-- Shared generated-model set behind the Bell Tower and Whirl Islands legend
-- cutscene renderers. Both effects compile Nitro models with role-named
-- clips out of the field-effect cache; this module only moves the pool,
-- definition, and instance bookkeeping both renderers must agree on. Role
-- lists, draw gating, and effect-specific overlays stay with each renderer.

local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")

local LegendCutsceneModels = {}

-- Realizes every model of one generated legend definition on a fresh GPU
-- pool. `spec.modelKeys` pins the definition's role order; anything else is
-- a source change the renderer must adopt deliberately.
---@param cacheFs CacheFs
---@param imageAssets table<string, unknown>
---@param spec { definitionKind: string, keyPrefix: string, definitionKeyPrefix: string, modelKeys: string[], label: string }
---@return table<string, unknown> handle { pool, definitions }
function LegendCutsceneModels.buildSet(cacheFs, imageAssets, spec)
  assert(cacheFs and cacheFs.loadLua, spec.label .. " renderer requires the generated cache")
  assert(imageAssets, spec.label .. " renderer requires the shared image owner")
  local record = assert(
    cacheFs:loadLua(FieldEffectAssetCache.definitionPath(spec.definitionKind)),
    spec.label .. " model asset is missing from the field-effect cache"
  )
  local descriptors = assert(record.models, spec.label .. " record has no models")
  assert(#descriptors == #spec.modelKeys, spec.label .. " model role list changed")
  local pool = GpuAssetPool.new(cacheFs, { imageAssets = imageAssets })
  local definitions = {}
  local function buildModels()
    for index, descriptor in ipairs(descriptors) do
      local name =
        assert(descriptor.key:match(spec.keyPrefix .. "(.+)$"), spec.label .. " model descriptor has no semantic key")
      assert(name == spec.modelKeys[index], spec.label .. " field model role order changed")
      local definition = ModelDefinition.fromNitroDescriptor(descriptor, { key = spec.definitionKeyPrefix .. name })
      local modelMeshes = {}
      for _, mesh in ipairs(definition.meshes) do
        local resource = pool:meshFor(mesh.geometry)
        mesh.center = resource.center
        modelMeshes[mesh.id] = resource.mesh
      end
      definitions[name] = { descriptor = descriptor, definition = definition, meshes = modelMeshes }
    end
  end
  local ok, err = pcall(function()
    pool:build(buildModels)
  end)
  if not ok then
    pool:release()
    error(err, 0)
  end
  return { pool = pool, definitions = definitions, record = record }
end

-- Plays every role list of `specs` ({ name, source?, roles, loopMode? }).
-- Instance names are renderer-local; `source` selects the shared model.
---@param handle table<string, unknown>
---@param specs table<integer, table<string, unknown>>
---@param label string
---@return table<string, unknown> instances
function LegendCutsceneModels.buildInstances(handle, specs, label)
  local pool, definitions = assert(handle.pool), assert(handle.definitions)
  local instances = {}
  local function buildInstance(entry)
    local model = assert(definitions[entry.source or entry.name], label .. " cutscene model is missing")
    local wraps = SceneDescriptor.wrapByMaterial(model.descriptor.materials)
    local function resolveImage(path, materialId)
      local wrap = assert(wraps[materialId], label .. " material wrap is missing")
      return pool:sharedImage(path, wrap.x, wrap.y)
    end
    local instance = ModelInstance.new(model.definition, {
      resolveImage = resolveImage,
    })
    instance.renderMeshesById = model.meshes
    for _, role in ipairs(assert(entry.roles)) do
      instance:play(role, { loopMode = entry.loopMode })
    end
    instances[entry.name] = instance
  end
  local ok, err = pcall(function()
    for _, entry in ipairs(specs) do
      buildInstance(entry)
    end
  end)
  if not ok then
    pool:release()
    error(err, 0)
  end
  return instances
end

---@param instance table<string, unknown>
---@param frames integer
---@param count integer
function LegendCutsceneModels.advance(instance, frames, count)
  for _ = frames + 1, count do
    instance:updateFixed()
  end
end

---@param output table<string, unknown>[]
---@param instance table<string, unknown>
---@param position table<string, number>
---@param role string
---@param effectTag string
function LegendCutsceneModels.addDraws(output, instance, position, role, effectTag)
  instance.transform = Matrix4.translate(position.x, position.y, position.z)
  instance:evaluatePose()
  for _, item in ipairs(instance:drawItems(assert(instance.renderMeshesById))) do
    item.worldSpace = true
    item.fieldEffect = effectTag
    item.fieldEffectRole = role
    output[#output + 1] = item
  end
end

-- The cinematic application's fog-less render environment with its own edge
-- marking: the cinematic is not drawn through the map's own atmosphere.
---@param cached table<string, unknown>
---@param base table<string, unknown>
---@param edgeColors table<integer, integer>
---@return table<string, unknown>
function LegendCutsceneModels.cinematicEnvironment(cached, base, edgeColors)
  if cached.base == base and cached.edgeColors == edgeColors then
    return assert(cached.environment)
  end
  local fogTable = {}
  for index = 1, 32 do
    fogTable[index] = 0
  end
  local environment = setmetatable({
    edgeColors = edgeColors,
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
  }, { __index = base })
  cached.base, cached.edgeColors, cached.environment = base, edgeColors, environment
  return environment
end

return LegendCutsceneModels
