-- Presents source-derived grass effects through the engine's dynamic model
-- stack. The controller owns each mutable ModelInstance; this adapter owns
-- immutable definitions and pooled meshes/images.

local Matrix4 = require("libs.math.src.Matrix4")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")

---@class FieldTerrainEffectRenderer
local FieldTerrainEffectRenderer = {}
FieldTerrainEffectRenderer.__index = FieldTerrainEffectRenderer

---@param assets table<string, unknown>
---@param pool table<string, unknown>
---@return FieldTerrainEffectRenderer
function FieldTerrainEffectRenderer.new(assets, pool)
  assert(type(assets) == "table" and type(assets.effects) == "table", "terrain effect assets are required")
  assert(pool and pool.meshFor and pool.imageFor and pool.build, "field effect asset pool is required")
  local resources = {}
  pool:build(function()
    local kinds = { "tall_grass", "very_tall_grass", "trainer_reveal" }
    for selector = 1, 14 do
      kinds[#kinds + 1] = "follower_reaction_" .. selector
    end
    for _, kind in ipairs(kinds) do
      local descriptor = assert(assets.effects[kind].model)
      local definition = ModelDefinition.fromNitroDescriptor(descriptor, { key = "field-effect:" .. kind })
      local renderMeshesById = {}
      for _, mesh in ipairs(definition.meshes) do
        local resource = pool:meshFor(mesh.geometry)
        renderMeshesById[mesh.id] = resource.mesh
        mesh.center = resource.center
      end
      resources[kind] = {
        definition = definition,
        placementOffset = assets.effects[kind].placementOffset or { x = 0, y = 0, z = 0 },
        renderMeshesById = renderMeshesById,
        wraps = SceneDescriptor.wrapByMaterial(descriptor.materials),
      }
    end
    return resources
  end)
  return setmetatable({ resources = resources, pool = pool }, FieldTerrainEffectRenderer)
end

function FieldTerrainEffectRenderer:newInstance(kind)
  local resource = assert(self.resources[kind], "terrain renderer is missing " .. kind)
  local function resolveImage(path, materialId)
    local wrap = assert(resource.wraps[materialId], "missing field effect material wrap")
    return self.pool:imageFor(path, wrap.x, wrap.y)
  end
  local instance = ModelInstance.new(resource.definition, {
    resolveImage = resolveImage,
  })
  instance.renderMeshesById = resource.renderMeshesById
  return instance
end

function FieldTerrainEffectRenderer:drawItems(status, runtimeMap)
  assert(status and type(status.instances) == "table", "terrain effect status instances are required")
  if #status.instances == 0 then
    return {}
  end
  assert(type(runtimeMap) == "table", "terrain effect runtime map is required")
  local items = {}
  for _, effect in ipairs(status.instances) do
    local anchorX, anchorY, anchorZ
    if effect.kind == "trainer_reveal" then
      local point = FieldCoordinates.fieldToWorld(runtimeMap, effect.fieldX, effect.fieldZ, effect.worldY)
      anchorX, anchorY, anchorZ = point.x, point.y, point.z
    elseif runtimeMap.projectPhysicalPoint ~= nil and effect.cellKey ~= nil and effect.sourceSurfaceId ~= nil then
      local point =
        runtimeMap:projectPhysicalPoint(effect.fieldX, effect.fieldZ, effect.cellKey, effect.sourceSurfaceId)
      anchorX, anchorY, anchorZ = point.worldX, point.worldY, point.worldZ
    else
      local point = FieldCoordinates.fieldToWorld(runtimeMap, effect.fieldX, effect.fieldZ, effect.worldY)
      anchorX, anchorY, anchorZ = point.x, point.y, point.z
    end
    local instance = assert(effect.modelInstance, "terrain effect model instance is missing")
    local resource = assert(self.resources[effect.kind], "terrain renderer is missing " .. effect.kind)
    local placementOffset = resource.placementOffset
    instance.transform =
      Matrix4.translate(anchorX + placementOffset.x, anchorY + placementOffset.y, anchorZ + placementOffset.z)
    instance:evaluatePose()
    for _, item in ipairs(instance:drawItems(resource.renderMeshesById)) do
      item.worldSpace = true
      item.fieldEffect = effect.kind
      items[#items + 1] = item
    end
  end
  return items
end

function FieldTerrainEffectRenderer:dispose()
  self.resources = nil
  self.pool = nil
end

return FieldTerrainEffectRenderer
