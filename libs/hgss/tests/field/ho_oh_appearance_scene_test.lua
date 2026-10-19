-- HoOhAppearanceScene: the field cutscene camera poses must stay inside the
-- camera's view volume, in the tile units FieldCamera consumes.

local Assert = require("tests.support.Assert")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local HoOhAppearanceScene = require("libs.hgss.src.field.HoOhAppearanceScene")
local HoOhAppearanceFixture = require("tests.support.HoOhAppearanceFixture")

local FX32_PER_TILE = 4096 * 16
local FIELD_CAMERA_DISTANCE_FX32 = 0x29AEC1

local function newCamera()
  local camera = {
    target = { x = 0, y = 0, z = 0 },
    distance = 1,
    far = 1700 / 16,
    near = 150 / 16,
    profile = { angleXRaw = 0 },
    poses = {},
    collapses = 0,
  }
  function camera:collapseRenderInterpolation()
    self.collapses = self.collapses + 1
  end
  function camera:rawPerspective()
    return 0x5C1
  end
  function camera:setCutscenePose(target, distance, _, perspective, _, _, _, far)
    assert(type(perspective) == "number", "every pose carries its perspective")
    self.target = target
    self.distance = distance
    self.far = far or self.far
    self.poses[#self.poses + 1] = { distance = distance, far = self.far }
  end
  return camera
end

local function newScene(versionId, camera, birdHeights)
  local cacheFs = {
    loadLua = function(_, path)
      Assert.equal(path, FieldEffectAssetCache.definitionPath("ho_oh_appearance"), "scene loads its model definition")
      return HoOhAppearanceFixture.definition()
    end,
  }
  return HoOhAppearanceScene.new({
    versionId = versionId,
    playerPosition = function()
      return { x = 0, y = 0, z = 0 }
    end,
    currentCamera = function()
      return camera
    end,
    timeOfDayCode = function()
      return 2
    end,
    setBirdHeight = function(tiles)
      if birdHeights then
        birdHeights[#birdHeights + 1] = tiles
      end
    end,
    cacheFs = cacheFs,
  })
end

local T = { tests = {} }

function T.tests.camera_move_places_the_eye_inside_the_far_plane()
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local camera = newCamera()
    local scene = newScene(versionId, camera)
    scene:command("legend_cutscene_bell_begin")
    scene:command("legend_cutscene_camera_move", 1)
    local pose = camera.poses[#camera.poses]
    Assert.equal(
      pose.distance,
      FIELD_CAMERA_DISTANCE_FX32 / FX32_PER_TILE,
      versionId .. " cutscene camera keeps the field camera distance in tiles"
    )
    Assert.isTrue(pose.distance < pose.far, versionId .. " cutscene eye is inside the far plane")
  end
end

function T.tests.camera_pan_keeps_the_eye_inside_the_far_plane_every_tick()
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local camera = newCamera()
    local scene = newScene(versionId, camera)
    scene:command("legend_cutscene_bell_begin")
    scene:command("legend_cutscene_camera_pan", 0)
    for _ = 1, scene:cameraPanTicks() do
      scene:updateFixed()
    end
    Assert.isTrue(#camera.poses > 1, versionId .. " pan updates the camera pose")
    for _, pose in ipairs(camera.poses) do
      Assert.isTrue(pose.distance < pose.far, versionId .. " pan eye is inside the far plane")
    end
  end
end

local function riseBell(scene)
  scene:command("legend_cutscene_bell_begin")
  scene:command("legend_cutscene_bell_rise")
  for _ = 1, 10 do
    scene:updateFixed()
  end
end

function T.tests.shimmer_starts_without_waiting_for_the_glow()
  local scene = newScene("heartgold", newCamera())
  riseBell(scene)
  scene:command("legend_cutscene_bell_shimmer", 0)
  Assert.equal(scene:taskTicks("legend_cutscene_bell_shimmer"), 1, "the source command yields one tick")
  Assert.equal(scene:status().bellStage, "shimmer", "the glow starts at once")
end

function T.tests.shimmer_requested_mid_glow_waits_for_the_idle_loop_then_starts()
  local scene = newScene("heartgold", newCamera())
  riseBell(scene)
  scene:command("legend_cutscene_bell_shimmer", 0)
  for _ = 1, 4 do
    scene:updateFixed()
  end
  scene:command("legend_cutscene_bell_shimmer", 1)
  local wait = scene:taskTicks("legend_cutscene_bell_shimmer")
  Assert.equal(wait, 6, "the script waits out the glow already running, got " .. tostring(wait))
  for _ = 1, wait do
    scene:updateFixed()
  end
  Assert.equal(scene:status().bellStage, "shimmer", "the queued glow starts once the bell is idle")
  Assert.isTrue(scene:status().shimmerClearBellOnly, "the queued glow keeps its own selection")
end

function T.tests.camera_wait_runs_only_the_rest_of_the_pan()
  local scene = newScene("heartgold", newCamera())
  scene:command("legend_cutscene_bell_begin")
  scene:command("legend_cutscene_camera_pan", 0)
  for _ = 1, 150 do
    scene:updateFixed()
  end
  Assert.equal(scene:taskTicks("legend_cutscene_camera_wait"), 50, "the wait covers the unfinished pan")
  for _ = 1, 50 do
    scene:updateFixed()
  end
  Assert.equal(scene:taskTicks("legend_cutscene_camera_wait"), 1, "a finished pan costs the one-tick yield")
end

function T.tests.second_pan_targets_the_same_camera_point_on_both_versions()
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local scene = newScene(versionId, newCamera())
    scene:command("legend_cutscene_bell_begin")
    scene:command("legend_cutscene_camera_pan", 1)
    Assert.equal(scene:status().cameraDestination, 3, versionId .. " pans to the high camera point")
  end
end

function T.tests.legend_descends_to_its_tile_then_the_ring_plays()
  for versionId, descent in pairs({ heartgold = 120, soulsilver = 160 }) do
    local heights = {}
    local scene = newScene(versionId, newCamera(), heights)
    scene:command("legend_cutscene_bird_approach")
    Assert.equal(heights[1], descent / 16, versionId .. " the legend starts above its tile")
    for _ = 1, descent do
      scene:updateFixed()
    end
    Assert.equal(heights[#heights], 0, versionId .. " the legend lands on its tile")
    Assert.isNil(scene:status().birdRingFrame, versionId .. " the cry ring waits for the landing")
    for _ = 1, 110 do
      scene:updateFixed()
    end
    Assert.equal(scene:status().birdRingFrame, 0, versionId .. " the cry ring starts after the landing delays")
  end
end

function T.tests.cinematic_returns_the_ordinary_field_camera_not_the_script_pose()
  local camera = newCamera()
  local scene = newScene("heartgold", camera)
  scene:command("legend_cutscene_bell_begin")
  scene:command("legend_cutscene_camera_move", 2)
  scene:command("legend_cutscene_bell_end")
  Assert.isTrue(camera.target.y ~= 0, "the script left the camera away from the field view")
  scene:command("legend_cinematic", 0)
  for _ = 1, 2000 do
    if not scene:status().active then
      break
    end
    scene:updateFixed()
  end
  Assert.isFalse(scene:status().active, "the cinematic ends")
  Assert.equal(camera.target.y, 0, "the field view returns")
  Assert.isTrue(camera.collapses >= 3, "every camera cut skips render interpolation")
end

return T
