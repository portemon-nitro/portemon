-- Pure elapsed-time contract for the time-aware scenic area preview: it owns
-- the black brightness-in cover, the one-source-hold, the image alpha
-- reveal-out blend and the skip edge, with no map, GPU or input knowledge. The
-- preview is a pure controller, so its absence must fail as missing behavior
-- rather than as a suite load error.

local Assert = require("tests.support.Assert")

local T = {}

-- The controller is the module under test; its absence is the missing
-- behavior, never a load error.
local function previewModule(behavior)
  local ok, moduleOrError = pcall(require, "libs.hgss.src.transition.FieldAreaPreview")
  Assert.isTrue(ok, behavior .. " is missing: the area-preview controller is unavailable")
  local module = moduleOrError
  Assert.isTrue(type(module.new) == "function", behavior .. " is missing: the preview exposes no constructor")
  return module
end

---@return table
local function preview(imageKey, timeSlot)
  local module = previewModule("area-preview state")
  return module.new(imageKey, timeSlot)
end

local function status(preview)
  local status = preview:status()
  Assert.notNil(status, "an active preview always publishes a status")
  return status
end

-- Advances one source frame until the stage predicate holds or the bound is
-- exceeded; returns the number of frames consumed plus the stage it stopped at.
---@return integer framesTaken
local function advanceFrames(preview, limit, predicate)
  for frames = 0, limit do
    if predicate(preview) then
      return frames
    end
    if frames < limit then
      preview:updateSourceFrame()
    end
  end
  return limit
end

function T.a_new_preview_starts_fully_covered_over_its_selected_image()
  local instance = preview("preview.ilex.evening", 2)
  local initial = status(instance)
  Assert.equal(initial.stage, "fade_in", "the preview opens on its black cover")
  Assert.equal(initial.imageKey, "preview.ilex.evening", "the selected semantic image key is published")
  Assert.equal(initial.timeSlot, 2, "the sampled time slot is published")
  Assert.equal(initial.blackAlpha, 1, "the cover starts fully opaque")
  Assert.equal(initial.imageAlpha, 1, "the selected image starts fully opaque under the cover")
  Assert.isFalse(instance:isComplete(), "a fresh preview is not complete")
end

function T.the_black_cover_falls_to_zero_over_the_source_fade_in()
  local instance = preview("preview.ilex.evening", 2)
  local frames = advanceFrames(instance, 12, function(p)
    return status(p).stage ~= "fade_in"
  end)
  local settled = status(instance)
  Assert.equal(settled.stage, "hold", "the cover ends when it is fully transparent")
  Assert.equal(settled.blackAlpha, 0, "no black is left over the committed destination")
  Assert.equal(settled.imageAlpha, 1, "the image stays opaque while the cover clears")
  Assert.isTrue(
    frames >= 7 and frames <= 9,
    "the cover spans the source's sixteen display frames as eight ticks (" .. frames .. ")"
  )
end

function T.the_hold_outlasts_the_skip_window_at_two_display_frames_per_tick()
  local instance = preview("preview.union.day", 1)
  advanceFrames(instance, 12, function(p)
    return status(p).stage ~= "fade_in"
  end)
  Assert.equal(status(instance).stage, "hold", "the preview reaches its hold")
  local held = advanceFrames(instance, 40, function(p)
    return status(p).stage ~= "hold"
  end)
  Assert.equal(status(instance).stage, "blend_out", "the hold releases into the reveal blend")
  Assert.isTrue(held >= 30 and held <= 32, "the 61-frame hold is thirty fixed ticks, not sixty (" .. held .. ")")
end

function T.the_image_alpha_reveals_the_committed_world_in_sixteen_alpha_steps()
  local instance = preview("preview.union.day", 1)
  advanceFrames(instance, 12, function(p)
    return status(p).stage ~= "fade_in"
  end)
  advanceFrames(instance, 40, function(p)
    return status(p).stage ~= "hold"
  end)
  Assert.equal(status(instance).stage, "blend_out", "the preview reaches its blend")

  local previous = status(instance).imageAlpha
  local frames = 0
  while not instance:isComplete() and frames <= 24 do
    instance:updateSourceFrame()
    frames = frames + 1
    local alpha = status(instance).imageAlpha
    Assert.isTrue(alpha <= previous, "the image alpha must fall monotonically (" .. alpha .. " > " .. previous .. ")")
    previous = alpha
  end
  Assert.isTrue(instance:isComplete(), "the blend completes")
  local final = instance:status()
  Assert.isTrue(
    final == nil or final.imageAlpha == 0 or final.stage == "complete",
    "a complete preview reveals the world"
  )
  Assert.isTrue(
    frames >= 15 and frames <= 17,
    "the blend spans thirty-two display frames as sixteen ticks (" .. frames .. ")"
  )
end

function T.skip_shortens_only_the_hold_and_never_the_cover_or_blend()
  local instance = preview("preview.ilex.evening", 2)

  -- The cover and the reveal are not skippable; a skip during the fade-in must
  -- leave the covered stage untouched.
  instance:skipHold()
  Assert.equal(status(instance).stage, "fade_in", "a skip during the cover changes nothing")

  advanceFrames(instance, 12, function(p)
    return status(p).stage ~= "fade_in"
  end)
  Assert.equal(status(instance).stage, "hold", "the preview reaches its hold")
  instance:skipHold()
  instance:updateSourceFrame()
  Assert.equal(status(instance).stage, "blend_out", "a fresh skip ends the remaining hold")

  -- A skip during the blend cannot force the world faster.
  instance:skipHold()
  local before = status(instance).imageAlpha
  instance:updateSourceFrame()
  Assert.equal(status(instance).stage, "blend_out", "a skip during the blend changes nothing")
  Assert.isTrue(status(instance).imageAlpha < before, "the blend still advances one alpha step per tick")

  while not instance:isComplete() do
    instance:updateSourceFrame()
  end
  instance:skipHold()
  instance:updateSourceFrame()
  Assert.isTrue(instance:isComplete(), "a completed preview stays complete")
end

function T.a_completed_preview_never_advances_past_completion()
  local instance = preview("preview.union.day", 1)
  while not instance:isComplete() do
    instance:updateSourceFrame()
  end
  for _ = 1, 5 do
    instance:updateSourceFrame()
  end
  Assert.isTrue(instance:isComplete(), "a complete preview is terminal")
  local final = instance:status()
  Assert.isTrue(final == nil or final.imageKey == "preview.union.day", "completion never reselects an image")
end

function T.the_selected_image_key_and_time_slot_are_immutable_across_the_preview()
  local instance = preview("preview.ilex.evening", 2)
  local observed = {}
  for _ = 1, 80 do
    local current = status(instance)
    observed[current.imageKey] = true
    observed["slot:" .. tostring(current.timeSlot)] = true
    if instance:isComplete() then
      break
    end
    instance:updateSourceFrame()
  end
  Assert.keySet(observed, "preview.ilex.evening,slot:2", "the snapshot never changes while the preview runs")
end

function T.the_controller_has_no_love_dependency()
  local savedLove = rawget(_G, "love")
  local savedModule = package.loaded["libs.hgss.src.transition.FieldAreaPreview"]
  package.loaded["libs.hgss.src.transition.FieldAreaPreview"] = nil
  rawset(_G, "love", nil)
  local ok, err = pcall(function()
    local module = previewModule("headless area-preview state")
    local instance = module.new("preview.union.day", 1)
    instance:updateSourceFrame()
  end)
  rawset(_G, "love", savedLove)
  package.loaded["libs.hgss.src.transition.FieldAreaPreview"] = savedModule
  Assert.isTrue(ok, "the preview must advance without LÖVE loaded: " .. tostring(err))
end

return { tests = T }
