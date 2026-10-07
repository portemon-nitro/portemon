-- Presents the source-generated transient Pokémon Center healing balls.

local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")

---@class PokemonCenterHealRenderer
---@field definition table<string, unknown>|nil
---@field modelDefinition table<string, unknown>|nil
---@field wraps table<string, unknown>|nil
---@field renderMeshesById table<string, unknown>|nil
---@field pool table<string, unknown>|nil
---@field instances table<integer, table<string, unknown>>
---@field newBall fun(self: PokemonCenterHealRenderer, position: table<string, number>, record: table<string, unknown>, index: integer): table<string, unknown>
---@field drawItems fun(self: PokemonCenterHealRenderer, status: table<string, unknown>): table<string, unknown>[]
---@field dispose fun(self: PokemonCenterHealRenderer)
local PokemonCenterHealRenderer = {}
PokemonCenterHealRenderer.__index = PokemonCenterHealRenderer

---@param options table<string, unknown>
---@param pool table<string, unknown> GpuAssetPool-shaped owner
---@return PokemonCenterHealRenderer
function PokemonCenterHealRenderer.new(options, pool)
  assert(type(options) == "table" and type(options.definition) == "table", "healing definition is required")
  assert(pool and pool.meshFor and pool.imageFor and pool.build, "healing asset pool is required")
  local definition = options.definition
  local descriptor = assert(definition.models and definition.models[1], "healing ball model is missing")
  local modelDefinition = ModelDefinition.fromNitroDescriptor(descriptor, { key = "pokemon-center-heal:ball" })
  local wraps = SceneDescriptor.wrapByMaterial(descriptor.materials)
  local renderMeshesById = {}
  pool:build(function()
    for _, mesh in ipairs(modelDefinition.meshes) do
      local resource = pool:meshFor(mesh.geometry)
      mesh.center = resource.center
      renderMeshesById[mesh.id] = resource.mesh
    end
    return renderMeshesById
  end)
  return setmetatable({
    definition = definition,
    modelDefinition = modelDefinition,
    wraps = wraps,
    renderMeshesById = renderMeshesById,
    pool = pool,
    instances = {},
  }, PokemonCenterHealRenderer)
end

function PokemonCenterHealRenderer:newBall(position, record, index)
  assert(type(position) == "table" and type(index) == "number", "healing ball placement is required")
  assert(self.instances[index] == nil, "healing ball index is already active")
  local renderer = self
  local function resolveImage(path, materialId)
    local wrap = assert(renderer.wraps[materialId], "healing material wrap is missing")
    return renderer.pool:imageFor(path, wrap.x, wrap.y)
  end
  local instance = ModelInstance.new(self.modelDefinition, { resolveImage = resolveImage })
  self.instances[index] = { instance = instance, animation = nil, position = position, role = record.role }
  local handle = {}
  function handle:startAnimation()
    local ball = assert(renderer.instances[index], "healing ball was released")
    assert(ball.animation == nil, "healing ball animation already started")
    ball.animation = ball.instance:play(renderer.definition.ballAnimation, { loopMode = "once" })
  end
  function handle:updateFixed()
    local ball = renderer.instances[index]
    if ball then
      ball.instance:updateFixed()
    end
  end
  function handle:isFinished()
    local ball = assert(renderer.instances[index], "healing ball was released")
    return ball.animation ~= nil and ball.animation.player:isComplete()
  end
  function handle:dispose()
    renderer.instances[index] = nil
  end
  return handle
end

---@param status table<string, unknown> read-only healing flow snapshot
---@return table<string, unknown>[]
function PokemonCenterHealRenderer:drawItems(status)
  local balls = assert(status.balls, "healing status requires its temporary balls")
  local items = {}
  for _, ball in ipairs(balls) do
    local record = assert(self.instances[ball.index], "healing status references an absent ball instance")
    local position = ball.position
    local transform = Matrix4.translate(position.x, position.y, position.z)
    record.instance.transform = transform
    record.instance:evaluatePose()
    for _, item in ipairs(record.instance:drawItems(self.renderMeshesById)) do
      item.worldSpace = true
      item.fieldEffect = "pokemon_center_heal"
      items[#items + 1] = item
    end
  end
  return items
end

function PokemonCenterHealRenderer:dispose()
  self.instances = {}
  self.definition = nil
  self.modelDefinition = nil
  self.wraps = nil
  self.renderMeshesById = nil
  self.pool = nil
end

return PokemonCenterHealRenderer
