-- Presents the source models a gym mechanism loads at runtime: the Violet Gym
-- elevator car and the Azalea Gym Spinarak. Both are normalized build models of
-- their own map that travel with the field-effect bundle because the map scene
-- has no placement for them (MapPropManager_LoadOne in
-- src/field/gymmick/violet.c and azalea.c).
--
-- The renderer owns the immutable model definitions, their pooled meshes and
-- material wraps, and one model instance per source prop. The mechanism owns
-- each instance's lifetime through the returned handle and publishes every
-- transform it draws from, so drawing never reads the field cache, converts
-- coordinates, simulates motion, or advances a clock.
--
-- Clip policy is the source's own: the car's anim-list record is registered as
-- an ambient loop by the area loader, so its instance plays that clip for the
-- whole map visit; the Spinarak's record is only ever played explicitly, once
-- per ride (MapPropOneShotAnimationManager_LoadPropAnimations/PlayAnimation).

local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")

-- One generated definition per source prop: the normalized nitro-dynamic
-- descriptor its own map's build model compiled.
---@class StoryEffectDefinition
---@field model ModelDefinition.Descriptor

-- One prepared source prop: the runtime model, the single clip its source
-- anim-list record declares, and the pooled draws its instances share.
---@class StoryEffectResource
---@field model ModelDefinition
---@field clip table<string, unknown>
---@field renderMeshesById table<string, unknown>
---@field wraps table<number, { x: string, y: string }>

-- The live record one claim holds: the claimed model instance and, for a
-- spider, the one-shot clip its ride is playing.
---@class StoryEffectCarRecord
---@field instance ModelInstance
---@class StoryEffectSpiderRecord
---@field instance ModelInstance
---@field clip table<string, unknown>?

---@class StoryEffectRenderer
---@field private definitions table<string, StoryEffectDefinition>
---@field resources table<string, StoryEffectResource>
---@field pool table<string, unknown>
---@field car StoryEffectCarRecord?
---@field spiders table<integer, StoryEffectSpiderRecord>
local StoryEffectRenderer = {}
StoryEffectRenderer.__index = StoryEffectRenderer

StoryEffectRenderer.SPIDER_SLOTS = 4

-- The two source props in their fixed construction order.
local ROLES = { "car", "spider" }

---@param definitions { car: StoryEffectDefinition, spider: StoryEffectDefinition } generated effect definitions
---@param pool table<string, unknown> GpuAssetPool-shaped mesh/image owner
---@return StoryEffectRenderer
function StoryEffectRenderer.new(definitions, pool)
  assert(
    type(definitions) == "table" and definitions.car ~= nil and definitions.spider ~= nil,
    "story effect definitions are required for both source props"
  )
  assert(pool and pool.meshFor and pool.sharedImage and pool.build, "field effect asset pool is required")
  local resources = {}
  pool:build(function()
    for _, role in ipairs(ROLES) do
      local definition = assert(definitions[role], "story effect definition is missing: " .. role)
      local descriptor = assert(definition.model, "story effect model is missing: " .. role)
      local model = ModelDefinition.fromNitroDescriptor(descriptor)
      local renderMeshesById = {}
      for _, mesh in ipairs(model.meshes) do
        local resource = pool:meshFor(mesh.geometry)
        mesh.center = resource.center
        renderMeshesById[mesh.id] = resource.mesh
      end
      resources[role] = {
        model = model,
        clip = assert(model.animations[1], "story effect model carries no clip: " .. role),
        renderMeshesById = renderMeshesById,
        wraps = SceneDescriptor.wrapByMaterial(descriptor.materials),
      }
    end
    return resources
  end)
  return setmetatable({
    definitions = definitions,
    resources = resources,
    pool = pool,
    car = nil,
    spiders = {},
  }, StoryEffectRenderer)
end

---@param self StoryEffectRenderer
---@param role string
---@return ModelInstance instance
local function newInstance(self, role)
  local resource = assert(self.resources[role], "story effect renderer has no " .. role)
  local pool = self.pool
  local function resolveImage(path, materialId)
    local wrap = assert(resource.wraps[materialId], "story effect material wrap is missing")
    return pool:sharedImage(path, wrap.x, wrap.y)
  end
  return ModelInstance.new(resource.model, { resolveImage = resolveImage })
end

-- Claim the elevator car. The source area loader registers this model's
-- ambient loop for every build-config prop, so the car's own clip runs from
-- map load until the model is released.
---@return table<string, unknown> handle
function StoryEffectRenderer:newCar()
  assert(self.car == nil, "the elevator car model is already active")
  local resource = assert(self.resources.car)
  local instance = newInstance(self, "car")
  instance:play(resource.clip.name, { loopMode = "loop" })
  local record = { instance = instance }
  self.car = record
  local renderer = self
  local handle = {}
  function handle:updateFixed()
    local live = assert(renderer.car, "the elevator car model was released")
    live.instance:updateFixed()
  end
  function handle:dispose()
    renderer.car = nil
  end
  return handle
end

-- Claim one Spinarak. It stands at its route node without a clip until a ride
-- plays the source one-shot, which the ride itself starts and stops.
---@param slot integer one-based spider slot
---@return table<string, unknown> handle
function StoryEffectRenderer:newSpider(slot)
  assert(type(slot) == "number" and slot % 1 == 0, "a spider slot is required")
  assert(slot >= 1 and slot <= StoryEffectRenderer.SPIDER_SLOTS, "a spider slot is outside the source quartet")
  assert(self.spiders[slot] == nil, "spider slot " .. slot .. " already owns a model")
  local resource = assert(self.resources.spider)
  local instance = newInstance(self, "spider")
  local record = { instance = instance, clip = nil }
  self.spiders[slot] = record
  local renderer = self
  local handle = {}
  function handle:startRideAnimation()
    local live = assert(renderer.spiders[slot], "the spider model was released")
    if live.clip then
      return
    end
    live.clip = live.instance:play(resource.clip.name, { loopMode = "once" })
  end
  function handle:stopRideAnimation()
    local live = renderer.spiders[slot]
    if live == nil or live.clip == nil then
      return
    end
    -- The source unloads the one-shot at arrival, which returns the prop to
    -- its first frame: detaching the only joint attachment does the same.
    live.instance:stop(live.clip)
    live.clip = nil
  end
  function handle:updateFixed()
    local live = assert(renderer.spiders[slot], "the spider model was released")
    live.instance:updateFixed()
  end
  function handle:dispose()
    renderer.spiders[slot] = nil
  end
  return handle
end

---@param self StoryEffectRenderer
---@param items table[]
---@param record table<string, unknown>
---@param placement { x: number, y: number, z: number, rotationDegrees: number }
---@param role string "car" or "spider"
local function appendInstance(self, items, record, placement, role)
  local resource = assert(self.resources[role])
  local instance = assert(record.instance, "story effect instance is missing")
  instance.transform = Matrix4.multiply(
    Matrix4.translate(placement.x, placement.y, placement.z),
    Matrix4.rotateY(math.rad(placement.rotationDegrees))
  )
  instance:evaluatePose()
  for _, item in ipairs(instance:drawItems(resource.renderMeshesById)) do
    -- A source prop is solid world geometry: it draws through the world
    -- projection like any placed map model, never through the flat-billboard
    -- pull the field effects use.
    item.worldSpace = true
    items[#items + 1] = item
  end
end

-- Draw the props one borrowed presentation snapshot places. The snapshot is
-- the mechanism's own per-tick record of where each source prop stands; an
-- absent prop draws nothing.
---@param status GymMechanism.Presentation
---@return table[]
function StoryEffectRenderer:drawItems(status)
  assert(type(status) == "table", "story effect status is required")
  local items = {}
  if status.car ~= nil and self.car ~= nil then
    appendInstance(self, items, self.car, status.car, "car")
  end
  for _, placement in ipairs(status.spiders or {}) do
    local record = self.spiders[assert(placement.slot, "a spider placement carries its slot")]
    if record ~= nil then
      appendInstance(self, items, record, placement, "spider")
    end
  end
  return items
end

function StoryEffectRenderer:dispose()
  self.car = nil
  self.spiders = {}
  self.resources = nil
  self.definitions = nil
  self.pool = nil
end

return StoryEffectRenderer
