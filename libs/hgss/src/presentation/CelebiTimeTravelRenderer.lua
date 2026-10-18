-- Lazily realizes the generated Celebi model and reconciles it to source ticks.

local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")

---@class CelebiTimeTravelRenderer
---@field cacheFs CacheFs?
---@field imageAssets table<string, unknown>
---@field pool table<string, unknown>?
---@field instance table<string, unknown>?
---@field renderMeshesById table<string, unknown>?
---@field sequence integer?
---@field lastAppliedFrame integer
---@field new fun(cacheFs: CacheFs, imageAssets: table<string, unknown>): CelebiTimeTravelRenderer
---@field drawItems fun(self: CelebiTimeTravelRenderer, status: table<string, unknown>): table<string, unknown>[]
---@field release fun(self: CelebiTimeTravelRenderer)
---@field dispose fun(self: CelebiTimeTravelRenderer)
local CelebiTimeTravelRenderer = {}
CelebiTimeTravelRenderer.__index = CelebiTimeTravelRenderer

---@class CelebiDrawItem: ModelDrawItem
---@field worldSpace boolean
---@field fieldEffect string

---@param cacheFs CacheFs
---@param imageAssets table<string, unknown> session-scoped shared image owner the model textures are borrowed from
---@return CelebiTimeTravelRenderer
function CelebiTimeTravelRenderer.new(cacheFs, imageAssets)
  assert(cacheFs and cacheFs.loadLua, "Celebi renderer requires the generated cache")
  assert(imageAssets, "Celebi renderer requires the shared image owner")
  return setmetatable({
    cacheFs = cacheFs,
    imageAssets = imageAssets,
    pool = nil,
    instance = nil,
    renderMeshesById = nil,
    sequence = nil,
    lastAppliedFrame = 0,
  }, CelebiTimeTravelRenderer)
end

function CelebiTimeTravelRenderer:_build(sequence)
  local record = assert(
    self.cacheFs:loadLua(FieldEffectAssetCache.definitionPath("celebi_time_travel")),
    "Celebi model asset is missing from the field-effect cache"
  )
  local descriptor = assert(record.model, "Celebi field-effect record has no model")
  local definition = ModelDefinition.fromNitroDescriptor(descriptor, { key = "field-effect:celebi_time_travel" })
  local expected = { ["celebi.joint"] = "trs", ["celebi.pattern"] = "pattern", ["celebi.srt"] = "texsrt" }
  for role, kind in pairs(expected) do
    local clip = assert(definition:animation(role), "Celebi model is missing " .. role)
    assert(clip.kind == kind, "Celebi clip has an unexpected animation kind: " .. role)
  end
  assert(#definition.animations == 3, "Celebi model must have exactly three animation clips")
  local pool = GpuAssetPool.new(self.cacheFs, { imageAssets = self.imageAssets })
  local function buildInstance()
    local wraps = SceneDescriptor.wrapByMaterial(descriptor.materials)
    local meshes = {}
    pool:build(function()
      for _, mesh in ipairs(definition.meshes) do
        local resource = pool:meshFor(mesh.geometry)
        mesh.center = resource.center
        meshes[mesh.id] = resource.mesh
      end
      return meshes
    end)
    local function resolveImage(path, materialId)
      local wrap = assert(wraps[materialId], "Celebi material wrap is missing")
      return pool:imageFor(path, wrap.x, wrap.y)
    end
    local instance = ModelInstance.new(definition, { resolveImage = resolveImage })
    instance.renderMeshesById = meshes
    instance:play("celebi.joint", { loopMode = "once" })
    instance:play("celebi.pattern", { loopMode = "once" })
    instance:play("celebi.srt", { loopMode = "once" })
    return instance
  end
  local ok, result = pcall(buildInstance)
  if not ok then
    pool:release()
    error(result, 0)
  end
  self.pool = pool
  self.instance = result
  self.renderMeshesById = result.renderMeshesById
  self.sequence = sequence
  self.lastAppliedFrame = 0
end

---@param status table<string, unknown>
---@return table<string, unknown>[]
function CelebiTimeTravelRenderer:drawItems(status)
  if status.active ~= true or status.modelVisible ~= true then
    self:release()
    return {}
  end
  if self.sequence ~= status.sequence then
    self:release()
    self:_build(status.sequence)
  end
  local instance = assert(self.instance)
  local frame = assert(status.animationFrame)
  assert(type(frame) == "number" and frame % 1 == 0 and frame >= self.lastAppliedFrame, "Celebi render frame rewound")
  while self.lastAppliedFrame < frame do
    instance:updateFixed()
    self.lastAppliedFrame = self.lastAppliedFrame + 1
  end
  local position = assert(status.modelPosition)
  instance.transform = Matrix4.translate(position.x, position.y, position.z)
  instance:evaluatePose()
  local items = instance:drawItems(assert(self.renderMeshesById))
  for _, item in ipairs(items) do
    ---@cast item CelebiDrawItem
    item.worldSpace = true
    item.fieldEffect = "celebi_time_travel"
  end
  return items
end

function CelebiTimeTravelRenderer:release()
  if self.pool ~= nil then
    self.pool:release()
    self.pool = nil
  end
  self.instance = nil
  self.renderMeshesById = nil
  self.sequence = nil
  self.lastAppliedFrame = 0
end

function CelebiTimeTravelRenderer:dispose()
  self:release()
  self.cacheFs = nil
end

return CelebiTimeTravelRenderer
