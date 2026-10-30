-- FieldCameraZoom: source FieldCameraZoom_Set semantics (zoom-by delta and
-- zoom-back over a frame count) driving the field camera's eye distance.

local Assert = require("tests.support.Assert")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldCameraZoom = require("libs.hgss.src.field.FieldCameraZoom")

local T = {}

local FX32 = 65536
local ZOOM_BY = -0x96000

local function newCamera()
  return FieldCamera.new({
    projectionType = "perspective",
    distanceTiles = 10,
    angleXRaw = -8192,
    angleYRaw = 0,
    halfFovRadians = math.rad(15),
    fullVerticalFovRadians = math.rad(30),
    nearTiles = 1,
    farTiles = 100,
    targetOffsetTiles = { x = 0, y = 0, z = 0 },
  }, { initialTarget = { x = 4, y = 5, z = 6 } })
end

local function trunc(value)
  if value >= 0 then
    return math.floor(value)
  end
  return math.ceil(value)
end

local function eyeDistance(camera)
  local dx = camera.eye.x - camera.target.x
  local dy = camera.eye.y - camera.target.y
  local dz = camera.eye.z - camera.target.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function T.zoom_by_moves_the_eye_in_equal_steps_and_lands_exactly()
  local camera = newCamera()
  local zoom = FieldCameraZoom.new(camera)
  zoom:set("by", ZOOM_BY, 15)
  Assert.isFalse(zoom:isDone(), "a fresh zoom command is not done")
  zoom:step()
  Assert.equal(camera:distanceTiles(), 10 + trunc(ZOOM_BY / 15) / FX32, "one equal fx32 step per tick")
  for _ = 2, 14 do
    zoom:step()
  end
  Assert.isFalse(zoom:isDone(), "the zoom runs its full duration")
  zoom:step()
  Assert.isTrue(zoom:isDone())
  Assert.equal(camera:distanceTiles(), 10 + ZOOM_BY / FX32, "the final tick lands on the exact target")
  Assert.isTrue(math.abs(eyeDistance(camera) - camera:distanceTiles()) < 1e-6, "the eye follows the distance")
end

function T.zoom_back_returns_to_the_distance_captured_at_start()
  local camera = newCamera()
  local zoom = FieldCameraZoom.new(camera)
  zoom:set("by", ZOOM_BY, 1)
  zoom:step()
  Assert.equal(camera:distanceTiles(), 10 + ZOOM_BY / FX32, "a one-tick zoom lands immediately")
  zoom:set("back", 0, 60)
  for _ = 1, 59 do
    zoom:step()
  end
  Assert.isFalse(zoom:isDone())
  zoom:step()
  Assert.isTrue(zoom:isDone())
  Assert.equal(camera:distanceTiles(), 10, "zoom back restores the initial distance exactly")
end

function T.release_restores_the_initial_distance_once()
  local camera = newCamera()
  local zoom = FieldCameraZoom.new(camera)
  zoom:set("by", ZOOM_BY, 15)
  zoom:step()
  zoom:release()
  Assert.equal(camera:distanceTiles(), 10, "an abandoned zoom puts the camera back")
  zoom:release()
  Assert.equal(camera:distanceTiles(), 10, "release is idempotent")
  Assert.throws(function()
    zoom:step()
  end, "a released zoom never moves the camera again")
end

return { tests = T }
