-- Shared stateless geometry for the two option sliders and the current
-- discrete-choice rows: uniform stop placement with halfway-up pointer
-- rounding and even-gap control distribution with half-open hit regions.
-- Neither helper retains state, assets, or business-value mappings; the
-- volume and battle-speed mappings stay with the caller.

local Assert = require("tests.support.Assert")

local T = {}

local function sliderModule()
  local ok, mod = pcall(require, "libs.ui.src.Slider")
  Assert.isTrue(ok, "Slider missing: " .. tostring(mod))
  return mod
end

local function choiceModule()
  local ok, mod = pcall(require, "libs.ui.src.ChoiceGroup")
  Assert.isTrue(ok, "ChoiceGroup missing: " .. tostring(mod))
  return mod
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function sliderSpec(overrides)
  local result = { rect = rect(10, 20, 210, 30), count = 101, index = 81, knobExtent = 10 }
  for key, value in pairs(overrides or {}) do
    result[key] = value
  end
  return result
end

function T.volume_endpoints_map_to_track_ends()
  local Slider = sliderModule()
  local first = Slider.resolve(sliderSpec({ count = 101, index = 1, knobExtent = 10 }))
  Assert.equal(first.trackStartX, 15)
  Assert.equal(first.trackEndX, 215)
  Assert.equal(first.centerY, 35)
  Assert.equal(first.thumbRect.x, 15 - 5)
  Assert.equal(first.thumbRect.width, 10)
  local last = Slider.resolve(sliderSpec({ count = 101, index = 101, knobExtent = 10 }))
  Assert.equal(last.trackStartX, 15)
  Assert.equal(last.trackEndX, 215)
  Assert.equal(last.thumbRect.x, 215 - 5)
  Assert.equal(Slider.indexAt(first, 15), 1)
  Assert.equal(Slider.indexAt(first, 215), 101)
end

function T.battle_speed_middle_stop_sits_at_track_center()
  local Slider = sliderModule()
  local track = rect(0, 0, 210, 30)
  local stops = {}
  for index = 1, 3 do
    stops[index] = Slider.resolve({ rect = track, count = 3, index = index, knobExtent = 10 })
  end
  Assert.equal(stops[1].thumbRect.x + 5, stops[1].trackStartX)
  Assert.equal(stops[3].thumbRect.x + 5, stops[3].trackEndX)
  local middle = stops[2].thumbRect.x + 5
  Assert.equal(middle, (stops[2].trackStartX + stops[2].trackEndX) / 2)
  Assert.equal(Slider.indexAt(stops[1], middle), 2)
  Assert.equal(stops[2].index, 2)
end

function T.pointer_ties_round_toward_the_larger_stop_and_clamp_outside()
  local Slider = sliderModule()
  local resolved = Slider.resolve({ rect = rect(0, 0, 200, 20), count = 5, index = 1, knobExtent = 20 })
  Assert.equal(Slider.indexAt(resolved, 10), 1)
  Assert.equal(Slider.indexAt(resolved, 32), 1)
  Assert.equal(Slider.indexAt(resolved, 32.5), 2)
  Assert.equal(Slider.indexAt(resolved, 100), 3)
  Assert.equal(Slider.indexAt(resolved, 190), 5)
  Assert.equal(Slider.indexAt(resolved, -1000), 1)
  Assert.equal(Slider.indexAt(resolved, 100000), 5)
end

function T.slider_geometry_is_detached_from_its_inputs()
  local Slider = sliderModule()
  local spec = sliderSpec({ count = 11, index = 6 })
  local resolved = Slider.resolve(spec)
  local trackStartX, trackEndX = resolved.trackStartX, resolved.trackEndX
  local thumbX = resolved.thumbRect.x
  spec.rect.x = 999
  spec.rect.width = 3
  spec.count = 2
  spec.index = 1
  spec.knobExtent = 1
  Assert.equal(resolved.trackStartX, trackStartX)
  Assert.equal(resolved.trackEndX, trackEndX)
  Assert.equal(resolved.thumbRect.x, thumbX)
  Assert.equal(resolved.count, 11)
  Assert.equal(resolved.index, 6)
  Assert.isTrue(resolved.rect ~= spec.rect)
  Assert.isTrue(resolved.thumbRect ~= spec.rect)
end

function T.slider_thumb_snaps_to_logical_pixels()
  local Slider = sliderModule()
  local resolved = Slider.resolve({ rect = rect(0, 0, 103, 20), count = 3, index = 2, knobExtent = 10 })
  local center = resolved.thumbRect.x + resolved.thumbRect.width / 2
  Assert.equal(center % 1, 0)
end

function T.invalid_slider_specs_are_rejected()
  local Slider = sliderModule()
  local function rejects(candidate)
    Assert.throws(function()
      Slider.resolve(candidate)
    end)
  end
  rejects(nil)
  rejects(sliderSpec({ rect = rect(0, 0, 0, 20) }))
  rejects(sliderSpec({ rect = { x = 0, y = 0, width = 100 } }))
  rejects(sliderSpec({ count = 1, index = 1 }))
  rejects(sliderSpec({ count = 2.5, index = 1 }))
  rejects(sliderSpec({ count = 11, index = 0 }))
  rejects(sliderSpec({ count = 11, index = 12 }))
  rejects(sliderSpec({ count = 11, index = 1.5 }))
  rejects(sliderSpec({ knobExtent = 0 }))
  rejects(sliderSpec({ knobExtent = -4 }))
  rejects(sliderSpec({ knobExtent = math.huge }))
  rejects(sliderSpec({ rect = rect(0, 0, 10, 20), knobExtent = 10 }))
  rejects(sliderSpec({ rect = rect(0, 0, 5, 20), knobExtent = 10 }))
  local resolved = Slider.resolve(sliderSpec({ count = 11, index = 6 }))
  for _, x in ipairs({ 0 / 0, math.huge, -math.huge, "100" }) do
    Assert.throws(function()
      Slider.indexAt(resolved, x)
    end)
  end
  Assert.throws(function()
    Slider.indexAt({}, 10)
  end)
end

local function groupSpec(overrides)
  local result = { rect = rect(0, 0, 100, 20), widths = { 20, 20 }, height = 10 }
  for key, value in pairs(overrides or {}) do
    result[key] = value
  end
  return result
end

function T.even_gaps_distribute_controls_without_shrinking_art()
  local ChoiceGroup = choiceModule()
  local resolved = ChoiceGroup.resolve(groupSpec())
  Assert.equal(#resolved.rects, 2)
  Assert.deepEqual(resolved.rects[1], { x = 20, y = 5, width = 20, height = 10 })
  Assert.deepEqual(resolved.rects[2], { x = 60, y = 5, width = 20, height = 10 })
  Assert.equal(ChoiceGroup.hitTest(resolved, 20, 5), 1)
  Assert.equal(ChoiceGroup.hitTest(resolved, 60, 5), 2)
end

function T.three_choice_group_keeps_the_rightmost_control_inside()
  local ChoiceGroup = choiceModule()
  local resolved = ChoiceGroup.resolve(groupSpec({ rect = rect(0, 0, 100, 20), widths = { 30, 30, 30 }, height = 10 }))
  Assert.equal(#resolved.rects, 3)
  local last = resolved.rects[3]
  Assert.isTrue(last.x + last.width <= 100)
  for _, entry in ipairs(resolved.rects) do
    Assert.isTrue(entry.x % 1 == 0)
  end
  Assert.equal(ChoiceGroup.hitTest(resolved, 97, 10), 3)
  Assert.isNil(ChoiceGroup.hitTest(resolved, 99, 10))
  Assert.isNil(ChoiceGroup.hitTest(resolved, 100, 10))
end

function T.hit_regions_are_half_open_with_gaps_and_outside_returning_nil()
  local ChoiceGroup = choiceModule()
  local resolved = ChoiceGroup.resolve(groupSpec())
  Assert.equal(ChoiceGroup.hitTest(resolved, 20, 5), 1)
  Assert.isNil(ChoiceGroup.hitTest(resolved, 40, 5))
  Assert.equal(ChoiceGroup.hitTest(resolved, 39, 5), 1)
  Assert.isNil(ChoiceGroup.hitTest(resolved, 19, 5))
  Assert.isNil(ChoiceGroup.hitTest(resolved, 25, 4))
  Assert.isNil(ChoiceGroup.hitTest(resolved, 25, 15))
  Assert.isNil(ChoiceGroup.hitTest(resolved, -1, 5))
  Assert.isNil(ChoiceGroup.hitTest(resolved, 200, 5))
end

function T.choice_geometry_is_detached_from_its_inputs()
  local ChoiceGroup = choiceModule()
  local spec = groupSpec()
  local resolved = ChoiceGroup.resolve(spec)
  spec.rect.x = 500
  spec.widths[1] = 1
  spec.height = 1
  Assert.deepEqual(resolved.rects[1], { x = 20, y = 5, width = 20, height = 10 })
  Assert.deepEqual(resolved.rects[2], { x = 60, y = 5, width = 20, height = 10 })
  Assert.equal(resolved.rect.x, 0)
end

function T.unfittable_or_invalid_groups_fail_for_the_compact_layout()
  local ChoiceGroup = choiceModule()
  local function rejects(candidate)
    Assert.throws(function()
      ChoiceGroup.resolve(candidate)
    end)
  end
  rejects(nil)
  rejects(groupSpec({ widths = { 20 } }))
  rejects(groupSpec({ widths = {} }))
  rejects(groupSpec({ widths = { 60, 60 } }))
  rejects(groupSpec({ widths = { 20, -5 } }))
  rejects(groupSpec({ widths = { 20, 0 } }))
  rejects(groupSpec({ widths = { 20, math.huge } }))
  rejects(groupSpec({ height = 21 }))
  rejects(groupSpec({ height = 0 }))
  rejects(groupSpec({ rect = rect(0, 0, 0, 20) }))
  local sparse = { 20, 20 }
  sparse[3] = 20
  sparse[2] = nil
  rejects(groupSpec({ widths = sparse }))
  local resolved = ChoiceGroup.resolve(groupSpec())
  for _, point in ipairs({ { 0 / 0, 5 }, { 25, math.huge } }) do
    Assert.throws(function()
      ChoiceGroup.hitTest(resolved, point[1], point[2])
    end)
  end
end

return { tests = T }
