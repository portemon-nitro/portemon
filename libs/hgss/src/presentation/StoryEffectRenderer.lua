-- Presents the source models a gym mechanism loads at runtime: the Violet Gym
-- elevator car, the Azalea Gym Spinarak, the Ecruteak Gym candle and the
-- Blackthorn Gym platforms. All of them are normalized build models of their own
-- map that travel with the field-effect bundle because the map scene has no
-- placement for them (MapPropManager_LoadOne in src/field/gymmick/violet.c,
-- azalea.c, ecruteak.c and blackthorn.c). The Cianwood winch's animated props
-- are the map scene's own placements, so they draw through the scene; only their
-- donor clip travels with this bundle.
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
-- The Blackthorn platforms are the exception: their area registers no anim-list
-- record at all, so their models are static and only the transform the mechanism
-- publishes ever changes.

local FieldStaticEffectRenderer = require("libs.hgss.src.presentation.FieldStaticEffectRenderer")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")

-- One generated definition per source prop: the normalized nitro-dynamic
-- descriptor its own map's build model compiled.
---@class StoryEffectDefinition
---@field model ModelDefinition.Descriptor

-- The platform definitions by footprint role: the Blackthorn Gym loads build
-- model 120 on its two 5x7 platforms and 121 on its 4x8 one.
---@class StoryEffectPlatforms
---@field wide StoryEffectDefinition?
---@field narrow StoryEffectDefinition?

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
---@class StoryEffectCandleRecord
---@field instance ModelInstance
---@class StoryEffectPlatformRecord
---@field static FieldStaticEffectRenderer the prepared static batches of the platform's footprint

---@class StoryEffectRenderer
---@field private definitions table<string, unknown>
---@field resources table<string, unknown>
---@field pool table<string, unknown>
---@field car StoryEffectCarRecord?
---@field spiders table<integer, StoryEffectSpiderRecord>
---@field candles table<integer, StoryEffectCandleRecord>
---@field platforms table<integer, StoryEffectPlatformRecord>
local StoryEffectRenderer = {}
StoryEffectRenderer.__index = StoryEffectRenderer

StoryEffectRenderer.SPIDER_SLOTS = 4
StoryEffectRenderer.CANDLE_SLOTS = 4
StoryEffectRenderer.PLATFORM_SLOTS = 3

-- The source props in their fixed construction order. The candle model only
-- joins a composition that publishes it.
local ROLES = { "car", "spider", "candle" }

-- The Blackthorn platform models in their fixed construction order.
StoryEffectRenderer.PLATFORM_KINDS = { "wide", "narrow" }

-- One generated definition realized over the shared pool: its meshes, its one
-- source clip and its material wraps.
---@param pool table<string, unknown>
---@param definition StoryEffectDefinition
---@param label string
---@return StoryEffectResource
local function buildResource(pool, definition, label)
  local descriptor = assert(definition.model, "story effect model is missing: " .. label)
  local model = ModelDefinition.fromNitroDescriptor(descriptor)
  local renderMeshesById = {}
  for _, mesh in ipairs(model.meshes) do
    local meshResource = pool:meshFor(mesh.geometry)
    mesh.center = meshResource.center
    renderMeshesById[mesh.id] = meshResource.mesh
  end
  return {
    model = model,
    clip = assert(model.animations[1], "story effect model carries no clip: " .. label),
    renderMeshesById = renderMeshesById,
    wraps = SceneDescriptor.wrapByMaterial(descriptor.materials),
  }
end

---@param definitions { car: StoryEffectDefinition, spider: StoryEffectDefinition, candle: StoryEffectDefinition?, platform: StoryEffectPlatforms? } generated effect definitions
---@param pool table<string, unknown> GpuAssetPool-shaped mesh/image owner
---@return StoryEffectRenderer
function StoryEffectRenderer.new(definitions, pool)
  assert(
    type(definitions) == "table" and definitions.car ~= nil and definitions.spider ~= nil,
    "story effect definitions are required for both source props"
  )
  assert(pool and pool.meshFor and pool.sharedImage and pool.build, "field effect asset pool is required")
  local resources ---@type table<string, unknown>
  pool:build(function()
    resources = {}
    for _, role in ipairs(ROLES) do
      -- The candle model joins only a composition that publishes it.
      local definition = definitions[role]
      if definition == nil and role ~= "candle" then
        error("story effect definition is missing: " .. role, 0)
      end
      if definition ~= nil then
        resources[role] = buildResource(pool, definition, role)
      end
    end
    -- The platform models join only a composition that publishes them. A
    -- platform is a plain placed prop of its area's build config with no
    -- anim-list record, so its model is static and realizes through the static
    -- effect adapter instead of a posed instance.
    local platforms = definitions.platform
    if platforms ~= nil then
      local built = {}
      for _, kind in ipairs(StoryEffectRenderer.PLATFORM_KINDS) do
        local definition = platforms[kind]
        if definition ~= nil then
          built[kind] = FieldStaticEffectRenderer.new(
            assert(definition.model, "story effect model is missing: platform:" .. kind),
            pool
          )
        end
      end
      resources.platform = built
    end
    return resources
  end)
  return setmetatable({
    definitions = definitions,
    resources = resources,
    pool = pool,
    car = nil,
    spiders = {},
    candles = {},
    platforms = {},
  }, StoryEffectRenderer)
end

---@param self StoryEffectRenderer
---@param resource StoryEffectResource
---@return ModelInstance instance
local function newInstanceFor(self, resource)
  local pool = self.pool
  local function resolveImage(path, materialId)
    local wrap = assert(resource.wraps[materialId], "story effect material wrap is missing")
    return pool:sharedImage(path, wrap.x, wrap.y)
  end
  return ModelInstance.new(resource.model, { resolveImage = resolveImage })
end

---@param self StoryEffectRenderer
---@param role string
---@return ModelInstance instance
local function newInstance(self, role)
  return newInstanceFor(self, assert(self.resources[role], "story effect renderer has no " .. role))
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
  local record = { instance = instance, resource = resource }
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
  local record = { instance = instance, resource = resource, clip = nil }
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

---@param items table[]
---@param record table<string, unknown>
---@param placement { x: number, y: number, z: number, rotationDegrees: number, scale: number? }
local function appendInstance(items, record, placement)
  local resource = assert(record.resource, "story effect record is missing its resource")
  local instance = assert(record.instance, "story effect instance is missing")
  local transform = Matrix4.multiply(
    Matrix4.translate(placement.x, placement.y, placement.z),
    Matrix4.rotateY(math.rad(placement.rotationDegrees))
  )
  local scale = placement.scale
  instance.transform = scale ~= nil and scale ~= 1 and Matrix4.multiply(transform, Matrix4.scale(scale, scale, scale))
    or transform
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
    appendInstance(items, self.car, status.car)
  end
  for _, placement in ipairs(status.spiders or {}) do
    local record = self.spiders[assert(placement.slot, "a spider placement carries its slot")]
    if record ~= nil then
      appendInstance(items, record, placement)
    end
  end
  -- A culled candle is the source's own hidden prop: its model stays owned but
  -- nothing of it draws.
  for _, placement in ipairs(status.candles or {}) do
    local record = self.candles[assert(placement.index, "a candle placement carries its index")]
    if record ~= nil and placement.culled ~= true then
      appendInstance(items, record, placement)
    end
  end
  for _, placement in ipairs(status.platforms or {}) do
    local record = self.platforms[assert(placement.slot, "a platform placement carries its slot")]
    if record ~= nil then
      local static = assert(record.static, "a platform record is missing its model")
      for _, item in
        ipairs(static:drawItems({
          visible = true,
          position = { x = placement.x, y = placement.y, z = placement.z },
          rotationDegrees = placement.rotationDegrees,
          scale = 1,
        }))
      do
        -- A platform is solid world geometry: it draws through the world
        -- projection like any placed map model, never through the flat
        -- billboard pull the field effects use.
        item.fieldEffect = nil
        items[#items + 1] = item
      end
    end
  end
  return items
end

-- Claim one candle prop. It stands on its trainer object with no clip of its
-- own: the source loads the candle's model without starting an animation.
---@param index integer one-based source candle index
---@return table<string, unknown> handle
function StoryEffectRenderer:newCandle(index)
  assert(type(index) == "number" and index % 1 == 0, "a candle index is required")
  assert(index >= 1 and index <= StoryEffectRenderer.CANDLE_SLOTS, "a candle index is outside the source quartet")
  assert(self.candles[index] == nil, "candle " .. index .. " already owns a model")
  local resource = assert(self.resources.candle, "story effect renderer has no candle model")
  local instance = newInstance(self, "candle")
  self.candles[index] = { instance = instance, resource = resource }
  local renderer = self
  local handle = {}
  function handle:updateFixed()
    local live = assert(renderer.candles[index], "the candle model was released")
    live.instance:updateFixed()
  end
  function handle:dispose()
    renderer.candles[index] = nil
  end
  return handle
end

-- Claim one platform prop. Two platforms of one footprint share the same
-- source build model, so the claim holds the prepared static model and only the
-- transform the mechanism publishes differs per slot.
---@param slot integer one-based source platform index
---@param kind string "wide" or "narrow"
---@return table<string, unknown> handle
function StoryEffectRenderer:newPlatform(slot, kind)
  assert(type(slot) == "number" and slot % 1 == 0, "a platform slot is required")
  assert(slot >= 1 and slot <= StoryEffectRenderer.PLATFORM_SLOTS, "a platform slot is outside the source triple")
  assert(self.platforms[slot] == nil, "platform " .. slot .. " already owns a model")
  local platforms = assert(self.resources.platform, "story effect renderer has no platform models")
  local static = assert(platforms[kind], "story effect renderer has no " .. tostring(kind) .. " platform model")
  self.platforms[slot] = { static = static }
  local renderer = self
  local handle = {}
  -- A static platform prop has no clip clock: only its transform changes.
  function handle:updateFixed() end
  function handle:dispose()
    renderer.platforms[slot] = nil
  end
  return handle
end

function StoryEffectRenderer:dispose()
  for _, static in pairs(self.resources ~= nil and self.resources.platform or {}) do
    static:dispose()
  end
  self.car = nil
  self.spiders = {}
  self.candles = {}
  self.platforms = {}
  self.resources = nil
  self.definitions = nil
  self.pool = nil
end

return StoryEffectRenderer
