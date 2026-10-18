-- Owns the headless Celebi scene state and its temporary follower hide lease.

local CelebiTimeTravelScene = {}
CelebiTimeTravelScene.__index = CelebiTimeTravelScene

---@class CelebiTimeTravelScene
---@field _actors table<string, unknown>
---@field _followingMon table<string, unknown>
---@field _currentCamera fun(): table<string, unknown>?
---@field _currentMap fun(): table<string, unknown>?
---@field _sequence integer
---@field _state table<string, unknown>?
---@field new fun(options: table<string, unknown>): CelebiTimeTravelScene
---@field beginModel fun(self: CelebiTimeTravelScene)
---@field setAnimationFrame fun(self: CelebiTimeTravelScene, frame: integer)
---@field beginSwirl fun(self: CelebiTimeTravelScene)
---@field setSwirlFrame fun(self: CelebiTimeTravelScene, frame: integer)
---@field finish fun(self: CelebiTimeTravelScene)
---@field abort fun(self: CelebiTimeTravelScene)
---@field status fun(self: CelebiTimeTravelScene): table<string, unknown>

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function restoreCamera(state, currentCamera)
  local lease = state.cameraLease
  if lease == nil then
    return
  end
  local camera, up = lease.camera, lease.up
  if currentCamera() == camera then
    camera.up.x, camera.up.y, camera.up.z = up.x, up.y, up.z
  end
  state.cameraLease = nil
  state.blurActive = false
end

---@param options table<string, unknown>
---@return CelebiTimeTravelScene
function CelebiTimeTravelScene.new(options)
  assert(type(options) == "table", "Celebi scene requires options")
  assert(type(options.actors) == "table", "Celebi scene requires actors")
  assert(type(options.followingMon) == "table", "Celebi scene requires the follower owner")
  assert(type(options.currentCamera) == "function", "Celebi scene requires a current-camera provider")
  assert(type(options.currentMap) == "function", "Celebi scene requires a current-map provider")
  return setmetatable({
    _actors = options.actors,
    _followingMon = options.followingMon,
    _currentCamera = options.currentCamera,
    _currentMap = options.currentMap,
    _sequence = 0,
    _state = nil,
  }, CelebiTimeTravelScene)
end

function CelebiTimeTravelScene:beginModel()
  assert(self._state == nil, "Celebi scene is already active")
  local followingMon = self._followingMon
  local actorId = assert(followingMon:partnerActorId(), "Celebi scene requires a live follower")
  local actor = assert(self._actors:getById(actorId), "Celebi follower actor is missing")
  local map = assert(self._currentMap(), "Celebi scene requires a live map")
  assert(self._actors.currentMapId ~= nil, "Celebi scene requires an actor map identity")
  local position = actor:getWorldPosition()
  assert(
    type(position) == "table" and finite(position.x) and finite(position.y) and finite(position.z),
    "Celebi follower requires a finite world position"
  )
  local lease = followingMon:hideUntilNextStep()
  self._sequence = self._sequence + 1
  self._state = {
    active = true,
    modelVisible = true,
    animationFrame = 0,
    swirlFrame = nil,
    modelPosition = { x = position.x, y = position.y, z = position.z },
    blurActive = false,
    sequence = self._sequence,
    actorId = actorId,
    actorMapId = self._actors.currentMapId,
    map = map,
    followerLease = lease,
  }
end

function CelebiTimeTravelScene:setAnimationFrame(frame)
  local state = assert(self._state, "Celebi scene is inactive")
  assert(type(frame) == "number" and frame % 1 == 0 and frame >= state.animationFrame, "invalid Celebi animation frame")
  if state.swirlFrame == nil then
    assert(frame <= 31, "Celebi animation frame exceeds the beat")
  else
    assert(frame <= 211, "Celebi animation frame exceeds the swirl")
  end
  state.animationFrame = frame
end

function CelebiTimeTravelScene:beginSwirl()
  local state = assert(self._state, "Celebi scene is inactive")
  assert(state.swirlFrame == nil and state.animationFrame >= 31, "Celebi swirl requires the completed model beat")
  local camera = assert(self._currentCamera(), "Celebi swirl requires a live field camera")
  local up = assert(camera.up, "Celebi swirl requires a camera up vector")
  assert(finite(up.x) and finite(up.y) and finite(up.z), "Celebi camera up vector must be finite")
  assert(type(camera.rawPerspective) == "function", "Celebi swirl requires a field camera perspective")
  local perspective = camera:rawPerspective()
  assert(finite(perspective), "Celebi camera perspective must be finite")
  state.cameraLease = {
    camera = camera,
    up = { x = up.x, y = up.y, z = up.z },
    perspective = perspective,
  }
  state.swirlFrame = 0
  state.blurActive = false
end

function CelebiTimeTravelScene:setSwirlFrame(frame)
  local state = assert(self._state, "Celebi scene is inactive")
  assert(state.swirlFrame ~= nil, "Celebi swirl has not started")
  assert(type(frame) == "number" and frame % 1 == 0 and frame >= 1 and frame <= 180, "invalid Celebi swirl frame")
  assert(frame == state.swirlFrame + 1, "Celebi swirl must advance once per source frame")
  local lease = assert(state.cameraLease, "Celebi swirl camera lease is missing")
  assert(self._currentCamera() == lease.camera, "Celebi swirl camera ownership changed")
  assert(lease.camera:rawPerspective() == lease.perspective, "Celebi swirl perspective changed")
  local rawIndex = math.ceil((-0x10000 * frame) / 180) % 0x10000
  local angle = (rawIndex / 0x10000) * (2 * math.pi)
  lease.camera.up.x = -math.sin(angle)
  lease.camera.up.y = math.cos(angle)
  lease.camera.up.z = 0
  state.swirlFrame = frame
  state.blurActive = true
end

function CelebiTimeTravelScene:finish()
  if self._state == nil then
    return
  end
  restoreCamera(self._state, self._currentCamera)
  self._state = nil
end

function CelebiTimeTravelScene:abort()
  local state = self._state
  if state == nil then
    return
  end
  if self._actors.currentMapId == state.actorMapId and self._currentMap() == state.map then
    self._followingMon:restoreCutsceneHide(state.followerLease)
  end
  restoreCamera(state, self._currentCamera)
  self._state = nil
end

function CelebiTimeTravelScene:status()
  local state = self._state
  if state == nil then
    return {
      active = false,
      modelVisible = false,
      animationFrame = 0,
      swirlFrame = nil,
      modelPosition = nil,
      blurActive = false,
      sequence = self._sequence,
    }
  end
  local position = state.modelPosition
  return {
    active = true,
    modelVisible = true,
    animationFrame = state.animationFrame,
    swirlFrame = state.swirlFrame,
    modelPosition = { x = position.x, y = position.y, z = position.z },
    blurActive = state.blurActive,
    sequence = state.sequence,
  }
end

return CelebiTimeTravelScene
