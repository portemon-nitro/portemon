-- Presents the source models a gym mechanism loads at runtime: the Violet Gym
-- elevator car, the Azalea Gym Spinarak, the Ecruteak Gym candle and the
-- Blackthorn Gym platforms. All of them are normalized build models of their own
-- map that travel with the field-effect bundle because the map scene has no
-- placement for them (MapPropManager_LoadOne in src/field/gymmick/violet.c,
-- azalea.c, ecruteak.c and blackthorn.c). The Cianwood winch's animated props
-- are the map scene's own placements, so they draw through the scene; only their
-- donor clip travels with this bundle.
--
-- The same bundle carries the Rocket hideout's own script-driven effects: the
-- three trap models the trap command anchors to the player
-- (src/field/script_field_effects.c sTrapEffects) and the alarm's red overlay
-- tilemap (Task_ShowHideoutAlarm loads its palette, character data and tilemap
-- into the main BG1). Trap models draw through the world queue like the gym
-- props; the alarm overlay is a prepared screen image the field paints under
-- the alarm's own alpha pulse.
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
local LanceDepartureEffect = require("libs.hgss.src.presentation.LanceDepartureEffect")

-- One generated definition per source prop: the normalized nitro-dynamic
-- descriptor its own map's build model compiled.
---@class StoryEffectDefinition
---@field model ModelDefinition.Descriptor

-- The platform definitions by footprint role: the Blackthorn Gym loads build
-- model 120 on its two 5x7 platforms and 121 on its 4x8 one.
---@class StoryEffectPlatforms
---@field wide StoryEffectDefinition?
---@field narrow StoryEffectDefinition?

-- One prepared alarm overlay: the rasterized source tilemap the field paints
-- under the alarm's own alpha pulse.
---@class StoryEffectOverlay
---@field image table<string, unknown>
---@field width number
---@field height number

-- One prepared source prop: the runtime model, the single clip its source
-- anim-list record declares, and the pooled draws its instances share.
---@class StoryEffectResource
---@field model ModelDefinition
---@field clip table<string, unknown>
---@field renderMeshesById table<string, unknown>
---@field wraps table<number, { x: string, y: string }>

-- One prepared scene part: the runtime model, its pooled draws and the
-- material wraps the scene's phases resolve images through. A scene part has no
-- single clip, unlike the mechanism props above.
---@class StoryEffectSceneResource
---@field model ModelDefinition
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
---@field traps table<string, table<string, unknown>>
---@field overlay StoryEffectOverlay?
---@field _trap table<string, unknown>?
---@field _sceneResources table<string, table<integer, StoryEffectSceneResource>>?
---@field _montageImages table<string, unknown>?
---@field _lanceDeparture table<string, unknown>?
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

---@param definitions { car: StoryEffectDefinition?, spider: StoryEffectDefinition?, candle: StoryEffectDefinition?, platform: StoryEffectPlatforms?, trap: table<string, StoryEffectDefinition>?, overlay: table<string, unknown>?, legend: table<string, table<string, unknown>>?, montage: table<string, unknown>? } generated effect definitions
---@param pool table<string, unknown> GpuAssetPool-shaped mesh/image owner
---@return StoryEffectRenderer
function StoryEffectRenderer.new(definitions, pool)
  assert(
    type(definitions) == "table"
      and (definitions.car ~= nil or definitions.trap ~= nil or definitions.legend ~= nil or definitions.montage ~= nil),
    "story effect definitions are required for at least one source prop"
  )
  assert(pool and pool.meshFor and pool.sharedImage and pool.build, "field effect asset pool is required")
  local resources ---@type table<string, unknown>
  local traps = {}
  pool:build(function()
    resources = {}
    for _, role in ipairs(ROLES) do
      -- The candle model joins only a composition that publishes it; the car
      -- and the Spinarak join only a composition that presents their mechanism.
      local definition = definitions[role]
      if definition ~= nil then
        resources[role] = buildResource(pool, definition, role)
      end
    end
    -- The hideout trap models carry every clip their source anim-list record
    -- declares; the trap itself starts them all at once.
    for kind, definition in pairs(definitions.trap or {}) do
      traps[kind] = buildResource(pool, definition, "trap:" .. kind)
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
  local overlay = nil
  if definitions.overlay ~= nil then
    local overlayDefinition = definitions.overlay --[[@as table<string, unknown>]]
    local texture = assert(overlayDefinition.texture, "the alarm overlay carries its prepared texture")
    overlay = {
      image = pool:sharedImage(texture, "clamp", "clamp"),
      width = assert(overlayDefinition.width, "the alarm overlay carries its width"),
      height = assert(overlayDefinition.height, "the alarm overlay carries its height"),
    }
  end
  return setmetatable({
    definitions = definitions,
    resources = resources,
    pool = pool,
    car = nil,
    spiders = {},
    candles = {},
    platforms = {},
    traps = traps,
    overlay = overlay,
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

-- Claim one hideout trap model. The source starts every clip of its own
-- anim-list record together (FieldAnimModel_Animate advances all of them and
-- the effect ends when all finished), so the claim plays them all once and
-- reports completion only when the last of them reached its end.
---@param kind string "electric", "poison" or "rock"
---@return table<string, unknown> handle
function StoryEffectRenderer:newTrap(kind)
  assert(type(kind) == "string" and kind ~= "", "a trap kind is required")
  local resource = assert(self.traps[kind], "the story effect renderer has no " .. kind .. " trap model")
  assert(self._trap == nil, "the hideout trap model is already active")
  local instance = newInstanceFor(self, resource)
  local record = { instance = instance, resource = resource, plays = {}, kind = kind }
  self._trap = record
  local renderer = self
  local handle = {}
  function handle:start()
    local live = assert(renderer._trap, "the hideout trap model was released")
    for _, clip in ipairs(live.resource.model.animations) do
      live.plays[#live.plays + 1] = live.instance:play(clip.name, { loopMode = "once" })
    end
  end
  function handle:isComplete()
    local live = renderer._trap
    if live == nil then
      return true
    end
    for _, play in ipairs(live.plays) do
      if play.player ~= nil and play.player:isComplete() ~= true then
        return false
      end
    end
    return true
  end
  function handle:updateFixed()
    local live = assert(renderer._trap, "the hideout trap model was released")
    live.instance:updateFixed()
  end
  function handle:dispose()
    renderer._trap = nil
  end
  return handle
end

-- Paint the alarm's prepared source overlay under its own alpha pulse. The
-- snapshot carries the source blend level (0..12 of 31); nothing here reads a
-- cache or advances a clock.
---@param status RocketHideoutEffects.Presentation
---@return boolean drawn
function StoryEffectRenderer:drawAlarmOverlay(status)
  local overlay = self.overlay
  if overlay == nil or status == nil or status.alarm == nil then
    return false
  end
  local graphics = assert(love and love.graphics, "the alarm overlay requires the graphics boundary")
  local image = overlay.image and overlay.image.image or nil
  assert(image ~= nil, "the alarm overlay image is unavailable")
  local width, height = graphics.getDimensions()
  graphics.setColor(1, 1, 1, status.alarm.blend / 31)
  graphics.draw(image, 0, 0, 0, width / overlay.width, height / overlay.height)
  graphics.setColor(1, 1, 1, 1)
  return true
end

-- Draw the props one borrowed presentation snapshot places. The snapshot is
-- an owner's own per-tick record of where each source prop stands: the gym
-- mechanism's placements and the hideout's trap travel through this one draw,
-- and an absent prop draws nothing.
---@param status GymMechanism.Presentation|RocketHideoutEffects.Presentation|LegendEventScene.Presentation
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
  local trap = status.trap
  if trap ~= nil and self._trap ~= nil then
    appendInstance(items, self._trap, trap)
  end
  for _, placement in ipairs(status.parts or {}) do
    local handle = placement.model
    local record = type(handle) == "table" and handle.record or nil
    if record ~= nil and record.instance ~= nil then
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
  self.traps = {}
  self._trap = nil
  self.overlay = nil
  self._lanceDeparture = nil
  self._sceneResources = nil
  self._montageImages = nil
  self.resources = nil
  self.definitions = nil
  self.pool = nil
end

-- One legendary-story scene part realized over the shared pool: the source
-- model with every clip record its phases declare. Unlike the mechanism props,
-- a scene part carries several clips and the scene plays them phase by phase.
---@param kind string scene definition key
---@param index integer one-based part index
---@param partOverride table<string, unknown>? an effect that publishes one model instead of keyed parts
---@return StoryEffectSceneResource
function StoryEffectRenderer:_sceneResource(kind, index, partOverride)
  local definitions = assert(self.definitions and self.definitions.legend, "the renderer carries no legend scenes")
  local definition = assert(definitions[kind], "the renderer has no " .. tostring(kind) .. " scene definition")
  local part = partOverride
    or assert(definition.parts and definition.parts[index], "the scene definition has no such part")
  self._sceneResources = self._sceneResources or {}
  local resources = self._sceneResources[kind]
  if resources == nil then
    resources = {}
    self._sceneResources[kind] = resources
  end
  local resource = resources[index]
  if resource ~= nil then
    return resource
  end
  local descriptor = assert(part.model, "scene part carries its model descriptor")
  local model = ModelDefinition.fromNitroDescriptor(descriptor)
  local renderMeshesById = {}
  for _, mesh in ipairs(model.meshes) do
    local meshResource = self.pool:meshFor(mesh.geometry)
    mesh.center = meshResource.center
    renderMeshesById[mesh.id] = meshResource.mesh
  end
  resource = {
    model = model,
    renderMeshesById = renderMeshesById,
    wraps = SceneDescriptor.wrapByMaterial(descriptor.materials),
  }
  resources[index] = resource
  return resource
end

-- Claim one presented scene part. The scene owns the handle's lifetime and
-- plays its source clips; the renderer only holds the pooled resources.
---@param kind string scene definition key
---@param index integer one-based part index
---@param partOverride table<string, unknown>? an effect that publishes one model instead of keyed parts
---@return table<string, unknown> handle
function StoryEffectRenderer:newSceneModel(kind, index, partOverride)
  local resource = self:_sceneResource(kind, index, partOverride)
  local pool = self.pool
  local function resolveImage(path, materialId)
    local wrap = assert(resource.wraps[materialId], "scene material wrap is missing")
    return pool:sharedImage(path, wrap.x, wrap.y)
  end
  local instance = ModelInstance.new(resource.model, { resolveImage = resolveImage })
  local record = { instance = instance, resource = resource }
  local handle = { record = record }
  function handle:play(name, opts)
    return instance:play(name, opts)
  end
  function handle:stop(play)
    return instance:stop(play)
  end
  function handle:updateFixed()
    instance:updateFixed()
  end
  function handle:dispose()
    handle.record = nil
  end
  return handle
end

-- Claim the source Dragonite model and prepared trainer/flyer sprites for
-- Lance's departure. The returned effect owns their presentation lifetime and
-- publishes readiness/status to the script consumer.
---@param definition table<string, unknown>
---@param positions table<string, { x: number, y: number, z: number }>
---@return table<string, unknown>
function StoryEffectRenderer:newLanceDeparture(definition, positions)
  assert(self._lanceDeparture == nil, "a Lance departure already owns the cut-in resources")
  local model = self:newSceneModel("lance_departure", 1, { model = assert(definition.model) })
  local trainer = {}
  for _, frame in ipairs(assert(definition.trainer.frames)) do
    trainer[#trainer + 1] = {
      image = self.pool:sharedImage(frame.path, "clamp", "clamp"),
      width = frame.width,
      height = frame.height,
      offsetX = frame.offsetX,
      offsetY = frame.offsetY,
    }
  end
  local flyerFrame = assert(definition.flyer)
  local flyer = {
    image = self.pool:sharedImage(flyerFrame.path, "clamp", "clamp"),
    width = flyerFrame.width,
    height = flyerFrame.height,
    offsetX = flyerFrame.offsetX,
    offsetY = flyerFrame.offsetY,
  }
  local record = { trainer = trainer, flyer = flyer }
  self._lanceDeparture = record
  local renderer = self
  local function releaseDeparture()
    if renderer._lanceDeparture == record then
      renderer._lanceDeparture = nil
    end
  end
  return LanceDepartureEffect.new({
    model = model,
    clipIds = assert(definition.clipIds),
    trainerFrameDurations = assert(definition.trainerFrameDurations),
    screenOffset = LanceDepartureEffect.screenOffsetFor(assert(positions.player), assert(positions.lance)),
    onDispose = releaseDeparture,
  })
end

-- Paint the departure's source 2D sprite layer over the field. The Dragonite
-- model itself travels through the ordinary world queue.
---@param status table<string, unknown>
function StoryEffectRenderer:drawLanceDeparture(status)
  local resources = self._lanceDeparture
  if resources == nil then
    return
  end
  local graphics = assert(love and love.graphics, "the Lance departure requires the graphics boundary")
  local width, height = graphics.getDimensions()
  local scaleX, scaleY = width / 256, height / 192
  local function draw(frame, placement)
    if placement == nil or placement.visible ~= true then
      return
    end
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(
      frame.image,
      (placement.x + frame.offsetX) * scaleX,
      (placement.y + frame.offsetY) * scaleY,
      math.rad(placement.rotation or 0),
      (placement.scale or 1) * scaleX,
      (placement.scale or 1) * scaleY
    )
  end
  draw(resources.trainer[assert(status.trainer.frame)], status.trainer)
  if status.flyer ~= nil then
    draw(resources.flyer, status.flyer)
  end
  graphics.setColor(1, 1, 1, 1)
end

-- Claim the Arceus montage's prepared images. The layers are the source's own
-- rasterized screen records; the sprite is the application's own cell frame.
---@param definition table<string, unknown> the generated montage definition
---@return table<string, unknown> handle
function StoryEffectRenderer:newMontage(definition)
  assert(type(definition) == "table" and type(definition.layers) == "table", "a montage definition is required")
  local images = { layers = {}, sprite = nil }
  for fileId, layer in pairs(definition.layers) do
    images.layers[fileId] =
      { image = self.pool:sharedImage(layer.path, "clamp", "clamp"), width = layer.width, height = layer.height }
  end
  if definition.sprite ~= nil then
    images.sprite = {
      image = self.pool:sharedImage(definition.sprite.path, "clamp", "clamp"),
      width = definition.sprite.width,
      height = definition.sprite.height,
    }
  end
  self._montageImages = images
  local renderer = self
  local handle = {}
  function handle:dispose()
    renderer._montageImages = nil
  end
  return handle
end

-- Paint the montage the scene publishes this tick: the visible source layers in
-- their own priority order under the scene's blend level, then the application's
-- own sprite at its source position. Layer and sprite pixels are prepared; this
-- path only applies the snapshot.
---@param status LegendEventScene.CinematicPresentation?
---@return boolean whether the montage painted this tick
function StoryEffectRenderer:drawMontage(status)
  local images = self._montageImages
  if images == nil or status == nil then
    return false
  end
  local graphics = assert(love and love.graphics, "the Arceus montage requires the graphics boundary")
  local width, height = graphics.getDimensions()
  local blend = status.blend ~= nil and status.blend.ev or nil
  local alpha = blend ~= nil and math.max(0, math.min(1, blend / 15)) or 1
  local ordered = {}
  for layer, path in pairs(status.layers or {}) do
    ordered[#ordered + 1] = { layer = layer, path = path, priority = (status.priorities or {})[layer] or 0 }
  end
  table.sort(ordered, function(a, b)
    return a.priority < b.priority
  end)
  for _, entry in ipairs(ordered) do
    local image = images.layers[entry.layer]
    if image ~= nil then
      graphics.setColor(1, 1, 1, alpha)
      graphics.draw(image.image, 0, 0, 0, width / image.width, height / image.height)
    end
  end
  local sprite = status.sprite
  if sprite ~= nil and sprite.visible == true and images.sprite ~= nil then
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(
      images.sprite.image,
      sprite.x * (width / 256),
      sprite.y * (height / 192),
      0,
      width / 256,
      height / 192
    )
  end
  graphics.setColor(1, 1, 1, 1)
  return true
end

return StoryEffectRenderer
