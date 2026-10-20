-- The Ho-Oh preparer adapts the scene renderer to the asset-needs registry:
-- it prepares the live game version and time-of-day variant one unit per step
-- and releases the renderer's assets when its need goes away.

local Assert = require("tests.support.Assert")
local HoOhAssetPreparer = require("game.hgss.src.field.HoOhAssetPreparer")

local T = { tests = {} }

local function fakeRenderer(log, stepsToFinish)
  local renderer = {}
  function renderer.prepareStep(_, versionId, variant)
    log[#log + 1] = string.format("prepare:%s:%d", versionId, variant)
    return #log >= stepsToFinish
  end
  function renderer.cancel()
    log[#log + 1] = "cancel"
  end
  return renderer
end

local function fakeRuntime(variantRef)
  return {
    versionId = "heartgold",
    hoOhAppearanceScene = {
      currentVariant = function()
        return variantRef.variant
      end,
      status = function()
        return { active = variantRef.sceneActive == true }
      end,
    },
  }
end

function T.tests.declines_ids_it_does_not_prepare()
  local preparer = HoOhAssetPreparer.new(fakeRuntime({ variant = 0 }), fakeRenderer({}, 1))
  Assert.isNil(preparer.start("celebi_time_travel"))
end

function T.tests.declines_when_the_runtime_has_no_scene()
  local runtime = fakeRuntime({ variant = 0 })
  runtime.hoOhAppearanceScene = nil
  local preparer = HoOhAssetPreparer.new(runtime, fakeRenderer({}, 1))
  Assert.isNil(preparer.start("ho_oh_appearance"))
end

function T.tests.each_step_prepares_the_live_version_and_variant()
  local log, variantRef = {}, { variant = 1 }
  local preparer = HoOhAssetPreparer.new(fakeRuntime(variantRef), fakeRenderer(log, 3))
  local job = assert(preparer.start("ho_oh_appearance"))
  Assert.isFalse(job.step())
  variantRef.variant = 2
  Assert.isFalse(job.step())
  Assert.isTrue(job.step())
  Assert.deepEqual(log, { "prepare:heartgold:1", "prepare:heartgold:2", "prepare:heartgold:2" })
end

function T.tests.a_running_scene_is_never_touched_by_background_preparation()
  local log, variantRef = {}, { variant = 1, sceneActive = true }
  local preparer = HoOhAssetPreparer.new(fakeRuntime(variantRef), fakeRenderer(log, 9))
  local job = assert(preparer.start("ho_oh_appearance"))
  Assert.isTrue(job.step(), "the job reports ready without preparing while the scene runs")
  Assert.deepEqual(log, {}, "the renderer is left alone while its scene draws")
  variantRef.sceneActive = false
  job.step()
  Assert.deepEqual(log, { "prepare:heartgold:1" }, "preparation resumes once the scene is over")
end

function T.tests.cancel_releases_the_renderer()
  local log = {}
  local preparer = HoOhAssetPreparer.new(fakeRuntime({ variant = 0 }), fakeRenderer(log, 9))
  local job = assert(preparer.start("ho_oh_appearance"))
  job.cancel()
  Assert.deepEqual(log, { "cancel" })
end

return T
