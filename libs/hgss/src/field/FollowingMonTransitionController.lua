-- Owns transient follower-transition instances. Each instance captures the
-- live partner generation at start, holds a two-update prelude on the
-- companion part, then switches to the animated part, reveals the ordinary
-- partner exactly once, advances the source clip to completion, and retires.
-- Instances advance in fixed simulation ticks and never touch save state.

---@class FollowingMonAppearanceOwner
---@field repositionRelativeToPlayer fun(self: FollowingMonAppearanceOwner, offsetSelector: integer, directionRaw: integer)

---@class FollowingMonTransitionController
---@field actors table<string, unknown>
---@field definition table<string, unknown>
---@field initialDescriptor table<string, unknown>
---@field animatedDescriptor table<string, unknown>
---@field frameCount integer
---@field preludeTicks integer
---@field modelFactory fun(part: string, descriptor: table<string, unknown>): table<string, unknown>
---@field instances table<string, unknown>[]
---@field _pendingStart boolean accepted request retained until a partner is published
---@field _pendingTailTicks integer tail updates for a pending appearance request
---@field _pendingCompletion fun()|nil source-owned operation after the appearance tail
local FollowingMonTransitionController = {}
FollowingMonTransitionController.__index = FollowingMonTransitionController

local function finiteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function checkOffset(offset)
  assert(type(offset) == "table", "transition definition requires its placement offset")
  assert(
    finiteNumber(offset.x) and finiteNumber(offset.y) and finiteNumber(offset.z),
    "transition placement offset requires finite x, y, z"
  )
  return offset
end

---@param definition table<string, unknown> the compiled transition definition
---@return table<string, unknown> initialDescriptor, table<string, unknown> animatedDescriptor, integer frameCount, integer preludeTicks
local function resolveParts(definition)
  assert(type(definition) == "table", "transition definition is required")
  local models = definition.models
  assert(type(models) == "table", "transition definition requires its models")
  local initialDescriptor, animatedDescriptor = nil, nil
  for _, descriptor in ipairs(models) do
    assert(type(descriptor) == "table", "transition model descriptor is required")
    if descriptor.kind == "static" then
      assert(initialDescriptor == nil, "transition definition carries two companion models")
      initialDescriptor = descriptor
    elseif descriptor.kind == "nitro-dynamic" then
      assert(animatedDescriptor == nil, "transition definition carries two animated models")
      animatedDescriptor = descriptor
    else
      error("unknown transition model kind " .. tostring(descriptor.kind))
    end
  end
  assert(initialDescriptor ~= nil, "transition definition requires its companion model")
  assert(animatedDescriptor ~= nil, "transition definition requires its animated model")
  local animations = animatedDescriptor.animations
  assert(type(animations) == "table", "transition animated model requires its clip")
  assert(#animations == 1, "transition animated model requires exactly one clip")
  local clip = animations[1]
  assert(type(clip) == "table", "transition animated model requires its clip")
  assert(
    type(clip.frameCount) == "number" and clip.frameCount >= 1 and clip.frameCount == math.floor(clip.frameCount),
    "transition clip requires a positive integer frame count"
  )
  local lifecycle = definition.lifecycle
  assert(type(lifecycle) == "table", "transition definition requires its lifecycle")
  assert(lifecycle.mode == "once", "transition lifecycle must run once")
  assert(lifecycle.preludeTicks == 2, "transition prelude lasts exactly two updates")
  assert(lifecycle.frameCount == clip.frameCount, "transition lifecycle must match its clip frame count")
  checkOffset(definition.placementOffset)
  return initialDescriptor, animatedDescriptor, clip.frameCount, lifecycle.preludeTicks
end

---@class FollowingMonTransitionControllerOptions
---@field actors table<string, unknown> the field actor manager owning partner identity and visibility
---@field definition table<string, unknown> the compiled transition definition
---@field modelFactory (fun(part: string, descriptor: table<string, unknown>): table<string, unknown>)|nil builds one mutable part instance per start
---@param options FollowingMonTransitionControllerOptions
---@return FollowingMonTransitionController
function FollowingMonTransitionController.new(options)
  assert(type(options) == "table", "transition controller options are required")
  assert(options.actors ~= nil, "transition controller requires the actor manager")
  assert(options.definition ~= nil, "transition controller requires its definition")
  local initialDescriptor, animatedDescriptor, frameCount, preludeTicks = resolveParts(options.definition)
  return setmetatable({
    actors = options.actors,
    definition = options.definition,
    initialDescriptor = initialDescriptor,
    animatedDescriptor = animatedDescriptor,
    frameCount = frameCount,
    preludeTicks = preludeTicks,
    modelFactory = options.modelFactory,
    instances = {},
    _pendingStart = false,
    _pendingTailTicks = 0,
    _pendingCompletion = nil,
  }, FollowingMonTransitionController)
end

function FollowingMonTransitionController:setModelFactory(factory)
  assert(type(factory) == "function", "transition model factory is required")
  assert(#self.instances == 0, "transition model factory cannot change while effects are active")
  self.modelFactory = factory
end

---@param instance table<string, unknown>
local function release(instance)
  if instance.initialInstance ~= nil then
    instance.initialInstance:dispose()
    instance.initialInstance = nil
  end
  if instance.animatedInstance ~= nil then
    instance.animatedInstance:dispose()
    instance.animatedInstance = nil
  end
end

---@param self FollowingMonTransitionController
---@param instance table<string, unknown>
---@return FieldActorManager.Actor|nil the live partner when the captured generation still owns the stable id
local function liveTarget(self, instance)
  local current = self.actors:getById(instance.targetActorId)
  if current == nil or current ~= instance.targetActor then
    return nil
  end
  if current.mapId ~= instance.targetMapId or current.spriteId ~= instance.targetSpriteId then
    return nil
  end
  return current
end

-- Binds one transient instance to the current partner without consuming any
-- prelude update. Returns false without allocating anything when no partner
-- is available; model allocation failures propagate after releasing partial
-- state, exactly as the public start observes them.
---@param self FollowingMonTransitionController
---@param tailTicks integer
---@param onComplete fun()|nil
---@return boolean
local function tryStartOnCurrentPartner(self, tailTicks, onComplete)
  local partnerId = self.actors:partnerId()
  if partnerId == nil then
    return false
  end
  local partner = self.actors:getById(partnerId)
  if partner == nil then
    return false
  end
  local modelFactory = assert(self.modelFactory, "transition model factory is not configured")
  local initialInstance =
    assert(modelFactory("initial", self.initialDescriptor), "transition model factory returned no companion instance")
  local created, animatedInstance = pcall(modelFactory, "animated", self.animatedDescriptor)
  if not created then
    initialInstance:dispose()
    error(animatedInstance, 0)
  end
  if animatedInstance == nil then
    initialInstance:dispose()
    error("transition model factory returned no animated instance")
  end

  local committed = partner:getFieldPosition()
  local anchor = partner:getWorldPosition()
  local instance = {
    targetActor = partner,
    targetActorId = partnerId,
    targetMapId = partner.mapId,
    targetSpriteId = partner.spriteId,
    fieldX = committed.fieldX,
    fieldZ = committed.fieldZ,
    worldY = anchor.y,
    offset = self.definition.placementOffset,
    phase = "prelude",
    preludeAge = 0,
    initialInstance = initialInstance,
    animatedInstance = animatedInstance,
    initialActive = true,
    animatedActive = false,
    frame = 0,
    frameCount = self.frameCount,
    tailTicks = tailTicks,
    tailAge = 0,
    onComplete = onComplete,
  }
  if liveTarget(self, instance) == nil then
    release(instance)
    return false
  end
  self.instances[#self.instances + 1] = instance
  return true
end

-- Starts one transient instance on the current partner. When no partner is
-- published yet the request is retained as one pending start and bound on a
-- later update; repeated requests while unbound coalesce. Returns true when
-- the request was bound immediately or retained as pending.
---@return boolean
function FollowingMonTransitionController:start()
  local partnerId = self.actors:partnerId()
  if partnerId == nil or self.actors:getById(partnerId) == nil then
    self._pendingStart = true
    return true
  end
  return tryStartOnCurrentPartner(self, 0, nil)
end

-- Starts the source's asynchronous follower appearance: the generated
-- transition clip completes, holds for twenty fixed updates, then asks the
-- following-mon owner to snap/settle the live partner.
---@param follower FollowingMonAppearanceOwner
---@return boolean
function FollowingMonTransitionController:startAppearance(follower)
  assert(type(follower) == "table" and type(follower.repositionRelativeToPlayer) == "function")
  local function onComplete()
    follower:repositionRelativeToPlayer(4, 0)
  end
  local partnerId = self.actors:partnerId()
  if partnerId == nil or self.actors:getById(partnerId) == nil then
    self._pendingTailTicks = 20
    self._pendingCompletion = onComplete
    return true
  end
  return tryStartOnCurrentPartner(self, 20, onComplete)
end

function FollowingMonTransitionController:updateFixed()
  if self._pendingStart and self.actors:partnerId() ~= nil then
    local ok, bound = pcall(tryStartOnCurrentPartner, self, 0, nil)
    if not ok then
      self._pendingStart = false
      error(bound, 0)
    end
    if bound then
      self._pendingStart = false
    end
  end
  if self._pendingCompletion ~= nil and self.actors:partnerId() ~= nil then
    local ok, bound = pcall(tryStartOnCurrentPartner, self, self._pendingTailTicks, self._pendingCompletion)
    if not ok then
      self._pendingTailTicks = 0
      self._pendingCompletion = nil
      error(bound, 0)
    end
    if bound then
      self._pendingTailTicks = 0
      self._pendingCompletion = nil
    end
  end
  for index = #self.instances, 1, -1 do
    local instance = self.instances[index]
    local current = liveTarget(self, instance)
    if current == nil then
      release(instance)
      table.remove(self.instances, index)
    else
      local tracked = current:getFieldPosition()
      instance.fieldX = tracked.fieldX
      instance.fieldZ = tracked.fieldZ
      instance.worldY = current:getWorldPosition().y
      if instance.phase == "tail" then
        instance.tailAge = instance.tailAge + 1
        if instance.tailAge >= instance.tailTicks then
          local ok, err = pcall(instance.onComplete)
          release(instance)
          table.remove(self.instances, index)
          if not ok then
            error(err, 0)
          end
        end
      elseif instance.phase == "prelude" then
        instance.preludeAge = instance.preludeAge + 1
        if instance.preludeAge >= self.preludeTicks then
          instance.phase = "animated"
          instance.initialActive = false
          instance.animatedActive = true
          self.actors:show(instance.targetActorId)
          instance.animatedInstance:reset()
          instance.frame = 0
        end
      else
        instance.animatedInstance:updateFixed()
        instance.frame = instance.frame + 1
        if instance.animatedInstance:isComplete() then
          if instance.tailTicks > 0 then
            instance.phase = "tail"
          else
            release(instance)
            table.remove(self.instances, index)
          end
        end
      end
    end
  end
end

function FollowingMonTransitionController:status()
  local instances = {}
  for index, instance in ipairs(self.instances) do
    instances[index] = {
      phase = instance.phase,
      preludeAge = instance.preludeAge,
      frame = instance.frame,
      frameCount = instance.frameCount,
      fieldX = instance.fieldX,
      fieldZ = instance.fieldZ,
      worldY = instance.worldY,
      offset = instance.offset,
      targetActorId = instance.targetActorId,
      initialActive = instance.initialActive,
      animatedActive = instance.animatedActive,
      initialInstance = instance.initialInstance,
      animatedInstance = instance.animatedInstance,
    }
  end
  return { instances = instances }
end

---@return boolean
function FollowingMonTransitionController:isAppearanceSettled()
  if self._pendingCompletion ~= nil then
    return false
  end
  for _, instance in ipairs(self.instances) do
    if instance.onComplete ~= nil then
      return false
    end
  end
  return true
end

function FollowingMonTransitionController:cancelAppearance()
  self._pendingTailTicks = 0
  self._pendingCompletion = nil
  for index = #self.instances, 1, -1 do
    local instance = self.instances[index]
    if instance.onComplete ~= nil then
      release(instance)
      table.remove(self.instances, index)
    end
  end
end

function FollowingMonTransitionController:clear()
  self._pendingStart = false
  self._pendingTailTicks = 0
  self._pendingCompletion = nil
  for index = #self.instances, 1, -1 do
    release(self.instances[index])
    self.instances[index] = nil
  end
end

function FollowingMonTransitionController:dispose()
  self:clear()
end

return FollowingMonTransitionController
