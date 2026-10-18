local Assert = require("tests.support.Assert")
local Scene = require("libs.hgss.src.field.CelebiTimeTravelScene")

local T = {}

local function fixture()
  local actor = { position = { x = 12.5, y = 3, z = -8 }, visible = true }
  function actor:getWorldPosition()
    return self.position
  end
  local actors = {
    currentMapId = 7,
    actor = actor,
  }
  function actors:getById(actorId)
    return actorId == "partner" and self.actor or nil
  end
  function actors:partnerId()
    return self.actor and "partner" or nil
  end
  function actors:isVisible(actorId)
    assert(actorId == "partner")
    return self.actor.visible
  end
  function actors:hide(actorId)
    assert(actorId == "partner")
    self.actor.visible = false
  end
  function actors:show(actorId)
    assert(actorId == "partner")
    self.actor.visible = true
  end
  local follower = { _rejoinHidden = false }
  function follower:partnerActorId()
    return actors:partnerId()
  end
  function follower:isPartnerVisible()
    return actors.actor ~= nil and actors.actor.visible
  end
  function follower:hideUntilNextStep()
    local previous = self._rejoinHidden
    local previousVisible = actors.actor.visible
    self._rejoinHidden = true
    actors:hide("partner")
    return { actorId = "partner", previousLatch = previous, previousVisible = previousVisible }
  end
  function follower:restoreCutsceneHide(lease)
    if self:partnerActorId() ~= lease.actorId then
      return false
    end
    self._rejoinHidden = lease.previousLatch
    if lease.previousVisible then
      actors:show(lease.actorId)
    else
      actors:hide(lease.actorId)
    end
    return true
  end
  local map = {}
  local camera = {
    up = { x = 0, y = 1, z = 0 },
    zoom = 1.25,
    projectionAspect = 1.6,
    target = { x = 4, y = 2, z = -3 },
    eye = { x = 8, y = 7, z = 6 },
    perspective = 0x2345,
  }
  function camera:rawPerspective()
    return self.perspective
  end
  local currentCamera = camera
  local cameraProviderCalls = 0
  local scene = Scene.new({
    actors = actors,
    followingMon = follower,
    currentCamera = function()
      cameraProviderCalls = cameraProviderCalls + 1
      return currentCamera
    end,
    currentMap = function()
      return map
    end,
  })
  return scene, actors, follower, map, function(nextMap)
    map = nextMap
  end, function()
    return cameraProviderCalls
  end, camera, function(replacement)
    currentCamera = replacement
  end
end

function T.model_capture_hides_follower_without_repositioning_and_status_is_detached()
  local scene, actors, follower, _, _, cameraProviderCalls = fixture()
  local expected = actors.actor.position
  scene:beginModel()
  local status = scene:status()
  Assert.isTrue(status.active, "scene is active")
  Assert.isTrue(status.modelVisible, "captured model is visible")
  Assert.equal(status.modelPosition.x, expected.x, "world X is copied")
  Assert.equal(status.modelPosition.y, expected.y, "world elevation is copied")
  Assert.equal(status.modelPosition.z, expected.z, "world Z is copied")
  Assert.isFalse(actors.actor.visible, "the follower is hidden")
  Assert.isTrue(follower._rejoinHidden, "the existing next-step latch is armed")
  Assert.equal(cameraProviderCalls(), 0, "scene capture leaves camera access to the presentation owner")
  status.modelPosition.x = 0
  Assert.equal(scene:status().modelPosition.x, expected.x, "status position is detached")
end

function T.scene_rejects_bad_order_and_non_monotonic_frames()
  local scene = fixture()
  Assert.isFalse(pcall(function()
    scene:beginSwirl()
  end), "swirl cannot begin before model")
  scene:beginModel()
  Assert.isFalse(pcall(function()
    scene:beginModel()
  end), "a scene cannot be activated twice")
  scene:setAnimationFrame(4)
  Assert.isFalse(pcall(function()
    scene:setAnimationFrame(3)
  end), "animation source time cannot rewind")
  Assert.isFalse(pcall(function()
    scene:beginSwirl()
  end), "swirl requires an animation beat")
end

function T.abort_restores_only_the_same_follower_on_the_same_map()
  local scene, actors, follower, _, setMap = fixture()
  scene:beginModel()
  scene:abort()
  Assert.isTrue(actors.actor.visible, "abort restores visible follower")
  Assert.isFalse(follower._rejoinHidden, "abort restores previous latch")

  scene:beginModel()
  setMap({})
  actors.actor = { visible = false, getWorldPosition = function() return { x = 1, y = 1, z = 1 } end }
  scene:abort()
  Assert.isFalse(actors.actor.visible, "stale cleanup leaves replacement follower untouched")

  setMap({})
  actors.actor = { visible = true, getWorldPosition = function() return { x = 1, y = 1, z = 1 } end }
  scene:beginModel()
  scene:abort()
  Assert.isTrue(actors.actor.visible, "same-map cleanup restores the current captured follower")
end

function T.finished_scene_keeps_follower_hidden_until_next_step_and_reactivates_sequence()
  local scene, actors, follower = fixture()
  scene:beginModel()
  local firstSequence = scene:status().sequence
  scene:setAnimationFrame(30)
  scene:beginSwirl()
  scene:setSwirlFrame(1)
  scene:finish()
  Assert.isFalse(actors.actor.visible, "successful handoff leaves follower hidden")
  Assert.isTrue(follower._rejoinHidden, "successful handoff leaves next-step reveal armed")
  Assert.isFalse(scene:status().active, "finished scene is inactive")
  scene:beginModel()
  Assert.isTrue(scene:status().sequence > firstSequence, "replay receives a new sequence")
end

function T.swirl_rolls_camera_up_once_per_source_frame_without_changing_projection()
  local scene, _, _, _, _, _, camera = fixture()
  local originalUp = { x = camera.up.x, y = camera.up.y, z = camera.up.z }
  local perspective, zoom, aspect = camera:rawPerspective(), camera.zoom, camera.projectionAspect
  local target, eye = { x = camera.target.x, y = camera.target.y, z = camera.target.z },
    { x = camera.eye.x, y = camera.eye.y, z = camera.eye.z }
  scene:beginModel()
  scene:setAnimationFrame(30)
  scene:beginSwirl()
  Assert.isFalse(scene:status().blurActive, "capture waits for the first source swirl tick")
  local samples = {
    [45] = { x = 1, y = 0 },
    [90] = { x = 0, y = -1 },
    [135] = { x = -1, y = 0 },
    [180] = { x = 0, y = 1 },
  }
  for frame = 1, 180 do
    scene:setSwirlFrame(frame)
    if frame == 1 then
      Assert.isTrue(scene:status().blurActive, "capture activates with the first source swirl tick")
    end
    local expected = samples[frame]
    if expected then
      Assert.near(camera.up.x, expected.x, 1e-9, "source roll X at frame " .. frame)
      Assert.near(camera.up.y, expected.y, 1e-9, "source roll Y at frame " .. frame)
      Assert.near(camera.up.z, 0, 1e-9, "source roll remains in camera plane")
    end
  end
  Assert.equal(camera:rawPerspective(), perspective, "swirl leaves raw perspective untouched")
  Assert.equal(camera.zoom, zoom, "swirl leaves zoom untouched")
  Assert.equal(camera.projectionAspect, aspect, "swirl leaves layout aspect untouched")
  Assert.deepEqual(camera.target, target, "swirl leaves target untouched")
  Assert.deepEqual(camera.eye, eye, "swirl leaves eye untouched")
  scene:finish()
  Assert.deepEqual(camera.up, originalUp, "finish restores the borrowed camera up exactly")
  Assert.isFalse(scene:status().blurActive, "finish disables capture")
end

function T.abort_restores_only_the_borrowed_camera_after_camera_replacement()
  local scene, _, _, _, _, _, camera, setCurrentCamera = fixture()
  scene:beginModel()
  scene:setAnimationFrame(30)
  scene:beginSwirl()
  Assert.isFalse(scene:status().blurActive, "capture waits for the first source swirl tick")
  scene:setSwirlFrame(1)
  Assert.isTrue(scene:status().blurActive, "capture activates with the first source swirl tick")
  for frame = 2, 63 do
    scene:setSwirlFrame(frame)
  end
  local capturedUp = { x = camera.up.x, y = camera.up.y, z = camera.up.z }
  local replacement = { up = { x = 0, y = 1, z = 0 }, perspective = 0x4567 }
  function replacement:rawPerspective()
    return self.perspective
  end
  setCurrentCamera(replacement)
  scene:abort()
  Assert.deepEqual(camera.up, capturedUp, "abort does not write to a camera after replacement")
  Assert.deepEqual(replacement.up, { x = 0, y = 1, z = 0 }, "abort leaves the replacement camera untouched")
  Assert.isFalse(scene:status().active, "aborted scene is inactive")
  Assert.isFalse(scene:status().blurActive, "aborted scene releases capture state")
end

return { tests = T }
