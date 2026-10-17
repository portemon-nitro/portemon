-- FieldCamera is the pure gameplay camera for ROM-derived HGSS profiles. It
-- implements the camera behavior recovered from the retail ROM while routing Y movement through the original history ring.
-- Each fixed update keeps the previous eye/target so `view(alpha)` can
-- interpolate between simulation states, matching the player's interpolated
-- render position at lower simulation rates.
--
-- Matrix storage is constructor-owned: fixed updates and host-frame view and
-- projection preparation overwrite stable buffers and upload arrays instead of
-- allocating fresh vectors or matrices. Returned matrix arrays are live views;
-- callers must treat them as read-only until the next view calculation or
-- projection invalidation.

local CameraHistory = require("libs.hgss.src.field.CameraHistory")
local Matrix4 = require("libs.math.src.Matrix4")

-- HGSS renders billboards and field effects through a depth-biased copy of the
-- projection: the retail ROM copies the
-- active projection after drawing maps and props, bumps `_32` (the Z-row
-- translation) by `_22` (the Z-row scale) times `fieldSystem->unk11C = 8`
-- model units times cos(-camera.angle.x), draws FieldEffectManager_Render and
-- BillboardLists_Draw through it, then restores the original projection. The
-- pull lives entirely in the depth row, so billboards keep their screen
-- position and size but win depth ties against same-depth map geometry. With
-- 16 model units per tile, the 8 model units become 0.5 tiles.
local FIELD_BILLBOARD_DEPTH_OFFSET_TILES = 0.5

---@class FieldCamera
---@field cameraSourceY number
---@field cameraAppliedY number
---@field zoom number
---@field projectionType "perspective"|"orthographic"
---@field profile table<string, unknown>
---@field distance number
---@field near number
---@field far number
---@field sourceTarget { x: number, y: number, z: number }
---@field target { x: number, y: number, z: number }
---@field previousTarget { x: number, y: number, z: number }
---@field eye { x: number, y: number, z: number }
---@field previousEye { x: number, y: number, z: number }
---@field up { x: number, y: number, z: number }
---@field history table<string, unknown>
---@field historyEnabled boolean
---@field canonicalAspect number
---@field projectionAspect number
---@field _rawPerspective integer -- live perspective half angle in Nintendo raw units (65536 per turn)
---@field _rawPerspectiveBase integer -- raw angle matching the profile half angle exactly
---@field _transitionDistanceTiles number
---@field _transitionAngleXRaw integer
---@field _transitionAngleYRaw integer
---@field _billboardDepthOffset number
---@field _projectionDirty boolean
---@field _projectionCache number[]
---@field _billboardProjectionCache number[]
---@field _viewBuffer Matrix4.Buffer
---@field _projectionBuffer Matrix4.Buffer
---@field _billboardProjectionBuffer Matrix4.Buffer
---@field _viewArray number[]
---@field _projectionArray number[]
---@field _billboardProjectionArray number[]
local FieldCamera = {}
FieldCamera.__index = FieldCamera

---@class FieldCamera.TransitionState
---@field distanceTiles number
---@field angleXRaw integer
---@field angleYRaw integer
---@field rawPerspective integer
---@field eye {x: number, y: number, z: number}
---@field previousEye {x: number, y: number, z: number}
---@field target {x: number, y: number, z: number}
---@field previousTarget {x: number, y: number, z: number}

local TAU = 2 * math.pi

local function assertVectorComponents(vector, what)
  assert(type(vector) == "table", what .. " must be a table")
  assert(
    type(vector.x) == "number" and type(vector.y) == "number" and type(vector.z) == "number",
    what .. " must contain numeric x, y, and z"
  )
end

local function copyComponents(dst, src)
  dst.x, dst.y, dst.z = src.x, src.y, src.z
end

local function addDelta(vector, deltaX, deltaY, deltaZ)
  vector.x = vector.x + deltaX
  vector.y = vector.y + deltaY
  vector.z = vector.z + deltaZ
end

local function angleIndexToRadians(raw)
  return raw * TAU / 65536
end

local function halfFovToRaw(halfFovRadians)
  return math.floor(halfFovRadians * 65536 / TAU + 0.5)
end

-- The live perspective half angle tracks the profile value exactly until a
-- whole-raw-unit step moves it: the base float is kept alongside the integer
-- so an untouched camera derives its projection from the exact profile
-- value, while any stepped angle derives deterministically from the same
-- base plus its integer offset. Restoring the offset restores the exact
-- projection bits.
local function liveHalfFovRadians(camera)
  return camera.profile.halfFovRadians + (camera._rawPerspective - camera._rawPerspectiveBase) * (TAU / 65536)
end

local function writeEyeFromTarget(target, profile, out, distance, angleXRaw, angleYRaw)
  local cameraDistance = distance or profile.distanceTiles
  local angleX = angleIndexToRadians(angleXRaw or profile.angleXRaw)
  local yaw = angleIndexToRadians(angleYRaw or profile.angleYRaw)
  local horizontalDistance = cameraDistance * math.cos(angleX)
  out.x = target.x + math.sin(yaw) * horizontalDistance
  out.y = target.y + math.sin(-angleX) * cameraDistance
  out.z = target.z + math.cos(yaw) * horizontalDistance
end

local function freshUploadArray()
  return { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
end

local function validateProfile(profile)
  assert(type(profile) == "table", "camera profile is required")
  assert(
    profile.projectionType == "perspective" or profile.projectionType == "orthographic",
    "unsupported camera projection type"
  )
  assert(type(profile.distanceTiles) == "number" and profile.distanceTiles > 0, "camera distance must be positive")
  assert(type(profile.angleXRaw) == "number" and type(profile.angleYRaw) == "number", "camera angles are required")
  assert(type(profile.halfFovRadians) == "number" and profile.halfFovRadians > 0, "camera half FOV is required")
  assert(
    type(profile.fullVerticalFovRadians) == "number" and profile.fullVerticalFovRadians > 0,
    "camera full vertical FOV is required"
  )
  assert(
    type(profile.nearTiles) == "number"
      and type(profile.farTiles) == "number"
      and profile.nearTiles > 0
      and profile.farTiles > profile.nearTiles,
    "invalid camera clipping planes"
  )
  assertVectorComponents(profile.targetOffsetTiles, "camera target offset")
end

function FieldCamera.new(profile, options)
  validateProfile(profile)
  options = options or {}
  local canonicalAspect = options.canonicalAspect or (4 / 3)
  assert(canonicalAspect > 0, "canonical aspect must be positive")
  local initial = options.initialTarget or { x = 0, y = 0, z = 0 }
  assertVectorComponents(initial, "camera initial target")
  local sourceTarget = { x = initial.x, y = initial.y, z = initial.z }
  local offset = profile.targetOffsetTiles
  local target = {
    x = sourceTarget.x + offset.x,
    y = sourceTarget.y + offset.y,
    z = sourceTarget.z + offset.z,
  }
  local eye = { x = 0, y = 0, z = 0 }
  writeEyeFromTarget(target, profile, eye)
  local viewBuffer = Matrix4.newBuffer()
  local projectionBuffer = Matrix4.newBuffer()
  local billboardProjectionBuffer = Matrix4.newBuffer()
  local viewArray = freshUploadArray()
  local projectionArray = freshUploadArray()
  local billboardProjectionArray = freshUploadArray()
  return setmetatable({
    profile = profile,
    projectionType = profile.projectionType,
    distance = profile.distanceTiles,
    near = profile.nearTiles,
    far = profile.farTiles,
    sourceTarget = sourceTarget,
    cameraSourceY = sourceTarget.y,
    cameraAppliedY = sourceTarget.y,
    target = target,
    previousTarget = { x = target.x, y = target.y, z = target.z },
    eye = eye,
    previousEye = { x = eye.x, y = eye.y, z = eye.z },
    up = { x = 0, y = 1, z = 0 },
    history = CameraHistory.new(7, 6),
    historyEnabled = options.historyEnabled ~= false,
    canonicalAspect = canonicalAspect,
    projectionAspect = canonicalAspect,
    zoom = 1,
    _rawPerspective = halfFovToRaw(profile.halfFovRadians),
    _rawPerspectiveBase = halfFovToRaw(profile.halfFovRadians),
    _transitionDistanceTiles = profile.distanceTiles,
    _transitionAngleXRaw = profile.angleXRaw,
    _transitionAngleYRaw = profile.angleYRaw,
    _billboardDepthOffset = FIELD_BILLBOARD_DEPTH_OFFSET_TILES * math.cos(angleIndexToRadians(profile.angleXRaw)),
    _projectionDirty = true,
    _projectionCache = projectionArray,
    _billboardProjectionCache = billboardProjectionArray,
    _viewBuffer = viewBuffer,
    _projectionBuffer = projectionBuffer,
    _billboardProjectionBuffer = billboardProjectionBuffer,
    _viewArray = viewArray,
    _projectionArray = projectionArray,
    _billboardProjectionArray = billboardProjectionArray,
  }, FieldCamera)
end

---@return FieldCamera.TransitionState snapshot used to restore one source transition's camera changes
function FieldCamera:captureTransitionState()
  return {
    distanceTiles = self._transitionDistanceTiles,
    angleXRaw = self._transitionAngleXRaw,
    angleYRaw = self._transitionAngleYRaw,
    rawPerspective = self._rawPerspective,
    eye = { x = self.eye.x, y = self.eye.y, z = self.eye.z },
    previousEye = { x = self.previousEye.x, y = self.previousEye.y, z = self.previousEye.z },
    target = { x = self.target.x, y = self.target.y, z = self.target.z },
    previousTarget = { x = self.previousTarget.x, y = self.previousTarget.y, z = self.previousTarget.z },
  }
end

---@param pose {distanceFx32: integer, angleXRaw: integer, angleYRaw: integer, perspectiveRaw: integer}
function FieldCamera:setTransitionPose(pose)
  assert(type(pose) == "table", "source transition camera pose is required")
  assert(type(pose.distanceFx32) == "number" and pose.distanceFx32 > 0, "source camera distance is positive fx32")
  assert(type(pose.angleXRaw) == "number" and pose.angleXRaw % 1 == 0, "source camera pitch is an integer")
  assert(type(pose.angleYRaw) == "number" and pose.angleYRaw % 1 == 0, "source camera yaw is an integer")
  assert(type(pose.perspectiveRaw) == "number" and pose.perspectiveRaw % 1 == 0, "source perspective is an integer")
  self._transitionDistanceTiles = pose.distanceFx32 / 65536
  self._transitionAngleXRaw = pose.angleXRaw
  self._transitionAngleYRaw = pose.angleYRaw
  self.distance = self._transitionDistanceTiles
  self._rawPerspective = pose.perspectiveRaw
  self._billboardDepthOffset = FIELD_BILLBOARD_DEPTH_OFFSET_TILES
    * math.cos(angleIndexToRadians(self._transitionAngleXRaw))
  self._projectionDirty = true
  writeEyeFromTarget(
    self.target,
    self.profile,
    self.eye,
    self._transitionDistanceTiles,
    self._transitionAngleXRaw,
    self._transitionAngleYRaw
  )
  copyComponents(self.previousEye, self.eye)
end

---@param state FieldCamera.TransitionState state returned by captureTransitionState
function FieldCamera:restoreTransitionState(state)
  assert(type(state) == "table", "captured source camera state is required")
  self._transitionDistanceTiles = state.distanceTiles
  self._transitionAngleXRaw = state.angleXRaw
  self._transitionAngleYRaw = state.angleYRaw
  self.distance = state.distanceTiles
  self._rawPerspective = state.rawPerspective
  self._billboardDepthOffset = FIELD_BILLBOARD_DEPTH_OFFSET_TILES
    * math.cos(angleIndexToRadians(self._transitionAngleXRaw))
  self._projectionDirty = true
  copyComponents(self.eye, state.eye)
  copyComponents(self.previousEye, state.previousEye)
  copyComponents(self.target, state.target)
  copyComponents(self.previousTarget, state.previousTarget)
end

function FieldCamera:updateFixed(playerTarget)
  assertVectorComponents(playerTarget, "camera player target")
  local eye, target = self.eye, self.target
  local previousEye, previousTarget, sourceTarget = self.previousEye, self.previousTarget, self.sourceTarget
  previousEye.x, previousEye.y, previousEye.z = eye.x, eye.y, eye.z
  previousTarget.x, previousTarget.y, previousTarget.z = target.x, target.y, target.z
  local deltaX = playerTarget.x - sourceTarget.x
  local deltaY = playerTarget.y - sourceTarget.y
  local deltaZ = playerTarget.z - sourceTarget.z
  local appliedY = self.historyEnabled and self.history:push(deltaY) or deltaY
  target.x = target.x + deltaX
  target.y = target.y + appliedY
  target.z = target.z + deltaZ
  eye.x = eye.x + deltaX
  eye.y = eye.y + appliedY
  eye.z = eye.z + deltaZ
  sourceTarget.x, sourceTarget.y, sourceTarget.z = playerTarget.x, playerTarget.y, playerTarget.z
  self.cameraSourceY = playerTarget.y
  self.cameraAppliedY = target.y - self.profile.targetOffsetTiles.y
end

-- Applies a retail field cutscene camera pose while leaving the normal field
-- camera profile intact for restoration when the scene releases its lease.
function FieldCamera:setCutscenePose(target, distance, angleXRaw, perspectiveRaw, playerTarget, angleYRaw, near, far)
  assertVectorComponents(target, "cutscene camera target")
  assertVectorComponents(playerTarget, "cutscene camera player target")
  assert(type(distance) == "number" and distance > 0, "cutscene camera distance must be positive")
  assert(type(angleXRaw) == "number" and type(perspectiveRaw) == "number", "cutscene camera angles are required")
  copyComponents(self.previousTarget, self.target)
  copyComponents(self.previousEye, self.eye)
  copyComponents(self.target, target)
  self.distance = distance
  self.near, self.far = near or (150 / 16), far or (1700 / 16)
  local angleX = angleIndexToRadians(angleXRaw)
  local yaw = angleIndexToRadians(angleYRaw or self.profile.angleYRaw)
  local horizontalDistance = distance * math.cos(angleX)
  self.eye.x = target.x + math.sin(yaw) * horizontalDistance
  self.eye.y = target.y + math.sin(-angleX) * distance
  self.eye.z = target.z + math.cos(yaw) * horizontalDistance
  copyComponents(self.sourceTarget, playerTarget)
  self.cameraSourceY = playerTarget.y
  self.cameraAppliedY = target.y - self.profile.targetOffsetTiles.y
  self._rawPerspective = perspectiveRaw
  self._projectionDirty = true
end

-- Translate the local coordinate frame after physical coverage changes. This
-- is a coordinate-system event, not terrain motion, so it never writes the Y
-- history ring.
function FieldCamera:rebase(deltaX, deltaY, deltaZ)
  assert(
    type(deltaX) == "number" and type(deltaY) == "number" and type(deltaZ) == "number",
    "camera rebase delta required"
  )
  addDelta(self.sourceTarget, deltaX, deltaY, deltaZ)
  addDelta(self.target, deltaX, deltaY, deltaZ)
  addDelta(self.previousTarget, deltaX, deltaY, deltaZ)
  addDelta(self.eye, deltaX, deltaY, deltaZ)
  addDelta(self.previousEye, deltaX, deltaY, deltaZ)
  self.cameraSourceY = self.cameraSourceY + deltaY
  self.cameraAppliedY = self.cameraAppliedY + deltaY
end

function FieldCamera:setProjectionAspect(aspect)
  assert(type(aspect) == "number" and aspect > 0, "projection aspect must be positive")
  if self.projectionAspect == aspect then
    return
  end
  self.projectionAspect = aspect
  self._projectionDirty = true
end

function FieldCamera:setZoom(zoom)
  assert(type(zoom) == "number" and zoom > 0, "camera zoom must be positive")
  if self.zoom == zoom then
    return
  end
  self.zoom = zoom
  self._projectionDirty = true
end

-- Applies the camera-side part of a non-ordinary field transition. The
-- transition family remains observable after the swap, while the camera
-- keeps ownership of its own adjustment state. This only reanchors the
-- camera to the transition player; timed angle choreography belongs to the
-- transition and reaches the camera through the raw perspective port below.
function FieldCamera:adjustTransition(profile, adjustment)
  assert(type(profile) == "number", "transition camera profile required")
  assert(type(adjustment) == "string", "transition camera adjustment required")
  local anchorX, anchorY, anchorZ = self.sourceTarget.x, self.sourceTarget.y, self.sourceTarget.z
  if self.transitionPlayer then
    local renderPosition = self.transitionPlayer:renderPosition()
    assertVectorComponents(renderPosition, "transition player render position")
    anchorX, anchorY, anchorZ = renderPosition.x, renderPosition.y, renderPosition.z
  end
  local sourceTarget = self.sourceTarget
  sourceTarget.x, sourceTarget.y, sourceTarget.z = anchorX, anchorY, anchorZ
  local offset = self.profile.targetOffsetTiles
  local target = self.target
  target.x = anchorX + offset.x
  target.y = anchorY + offset.y
  target.z = anchorZ + offset.z
  writeEyeFromTarget(target, self.profile, self.eye)
  copyComponents(self.previousTarget, target)
  copyComponents(self.previousEye, self.eye)
  self.cameraSourceY = anchorY
  self.cameraAppliedY = target.y - offset.y
end

-- Observes the live perspective half angle in whole Nintendo raw units
-- (65536 per turn). Field transitions capture and restore this value
-- around their white-fade angle choreography.
---@return integer
function FieldCamera:rawPerspective()
  return self._rawPerspective
end

-- Steps the live perspective half angle by whole Nintendo raw units and
-- invalidates the world and billboard projections. Fractional,
-- non-finite, or non-numeric deltas are programming faults and raise
-- before moving anything.
---@param delta integer
function FieldCamera:adjustRawPerspective(delta)
  assert(
    type(delta) == "number" and delta == delta and delta ~= math.huge and delta ~= -math.huge,
    "raw perspective step must be a finite number"
  )
  assert(delta % 1 == 0, "raw perspective step must stay in whole raw units")
  self._rawPerspective = self._rawPerspective + delta
  self._projectionDirty = true
end

function FieldCamera:setTransitionPlayer(player)
  assert(type(player) == "table", "transition player required")
  self.transitionPlayer = player
end

function FieldCamera:collapseRenderInterpolation()
  copyComponents(self.previousTarget, self.target)
  copyComponents(self.previousEye, self.eye)
end

-- `alpha` is the render interpolation factor of the current fixed step: 0 shows
-- the state the previous fixed update left behind, 1 the latest one, and values
-- between are smoothed so the camera cannot jump between simulation ticks.
-- Returns the camera-owned live view array; its contents are overwritten by
-- the next `view` call, so callers must copy values they need to keep.
function FieldCamera:view(alpha)
  alpha = alpha == nil and 1 or math.max(0, math.min(1, alpha))
  local previousEye, eye = self.previousEye, self.eye
  local previousTarget, target = self.previousTarget, self.target
  local eyeX = previousEye.x + (eye.x - previousEye.x) * alpha
  local eyeY = previousEye.y + (eye.y - previousEye.y) * alpha
  local eyeZ = previousEye.z + (eye.z - previousEye.z) * alpha
  local targetX = previousTarget.x + (target.x - previousTarget.x) * alpha
  local targetY = previousTarget.y + (target.y - previousTarget.y) * alpha
  local targetZ = previousTarget.z + (target.z - previousTarget.z) * alpha
  local up = self.up
  Matrix4.lookAtInto(self._viewBuffer, eyeX, eyeY, eyeZ, targetX, targetY, targetZ, up.x, up.y, up.z)
  Matrix4.toArrayBufferInto(self._viewArray, self._viewBuffer)
  return self._viewArray
end

local function fillProjectionBuffer(out, camera, aspect, zoom)
  -- The perspective derives from the live half angle so transition angle
  -- choreography moves the real projection; an unstepped camera keeps the
  -- exact profile value (see liveHalfFovRadians).
  local liveHalfFov = liveHalfFovRadians(camera)
  if camera.projectionType == "perspective" then
    Matrix4.perspectiveInto(out, liveHalfFov * 2, aspect, camera.near, camera.far)
  else
    local halfY = math.tan(liveHalfFov) * camera.distance
    local halfX = halfY * aspect
    Matrix4.orthographicInto(out, -halfX, halfX, -halfY, halfY, camera.near, camera.far)
  end
  local m = out.m
  m[0] = m[0] * zoom
  m[5] = m[5] * zoom
  return out
end

function FieldCamera:_refreshProjectionCache()
  if not self._projectionDirty then
    return
  end

  fillProjectionBuffer(self._projectionBuffer, self, self.projectionAspect, self.zoom)
  Matrix4.toArrayBufferInto(self._projectionArray, self._projectionBuffer)
  Matrix4.copyInto(self._billboardProjectionBuffer, self._projectionBuffer)
  local billboard = self._billboardProjectionBuffer.m
  billboard[14] = billboard[14] + billboard[10] * self._billboardDepthOffset
  Matrix4.toArrayBufferInto(self._billboardProjectionArray, self._billboardProjectionBuffer)

  self._projectionCache = self._projectionArray
  self._billboardProjectionCache = self._billboardProjectionArray
  self._projectionDirty = false
end

-- The returned matrix is persistent camera-owned state. Callers must treat it
-- as immutable and read-only until the next projection invalidation.
---@return number[] projection matrix
function FieldCamera:projection()
  self:_refreshProjectionCache()
  return self._projectionCache
end

-- The projection field billboards draw through: the normal projection with the
-- DS's fixed depth pull added to the Z-row translation. Cos is even, so
-- cos(-angleX) and cos(angleX) agree and the profile's raw pitch is enough.
-- The returned matrix is persistent camera-owned state. Callers must treat it
-- as immutable and read-only until the next projection invalidation.
---@return number[] billboard projection matrix
function FieldCamera:billboardProjection()
  self:_refreshProjectionCache()
  return self._billboardProjectionCache
end

function FieldCamera:canonicalProjection()
  local buffer = Matrix4.newBuffer()
  fillProjectionBuffer(buffer, self, self.canonicalAspect, 1)
  return Matrix4.toArrayBuffer(buffer)
end

function FieldCamera:canonicalBillboardProjection()
  local projection = self:canonicalProjection()
  projection[15] = projection[15] + projection[11] * self._billboardDepthOffset
  return projection
end

FieldCamera.FIELD_BILLBOARD_DEPTH_OFFSET_TILES = FIELD_BILLBOARD_DEPTH_OFFSET_TILES

return FieldCamera
