-- Pure producer RGBA operations: rectangular crops use the source row stride
-- while the destination packs exactly the requested rectangle, and layer
-- composition blends straight alpha bottom-to-top. Inputs are never mutated.

local Assert = require("tests.support.Assert")
local RgbaImage = require("romdump.src.digest.ui.RgbaImage")

local T = {}

local function pixel(r, g, b, a)
  return string.char(r, g, b, a)
end

-- A 3x2 asymmetric source with distinct pixels and nontrivial alpha. Width 3
-- matters: a crop that copies complete source rows instead of the requested
-- rectangle returns the wrong bytes here.
local function asymmetric()
  local pixels = table.concat({
    pixel(10, 20, 30, 255),
    pixel(40, 50, 60, 128),
    pixel(70, 80, 90, 0),
    pixel(11, 21, 31, 255),
    pixel(41, 51, 61, 200),
    pixel(71, 81, 91, 255),
  })
  return { width = 3, height = 2, pixels = pixels }
end

function T.narrow_crop_returns_only_the_requested_column()
  local source = asymmetric()
  local cropped = RgbaImage.crop(source, { x = 1, y = 0, width = 1, height = 2 }, "narrow")
  Assert.equal(cropped.width, 1)
  Assert.equal(cropped.height, 2)
  Assert.equal(#cropped.pixels, 8, "a 1x2 crop holds exactly two pixels")
  Assert.equal(cropped.pixels, pixel(40, 50, 60, 128) .. pixel(41, 51, 61, 200))
  Assert.equal(#source.pixels, 3 * 2 * 4, "the source keeps all six pixels")
end

function T.x_offset_crop_packs_destination_rows()
  local source = asymmetric()
  local cropped = RgbaImage.crop(source, { x = 1, y = 0, width = 2, height = 2 }, "offset")
  Assert.equal(cropped.width, 2)
  Assert.equal(cropped.height, 2)
  Assert.equal(#cropped.pixels, 2 * 2 * 4)
  Assert.equal(
    cropped.pixels,
    pixel(40, 50, 60, 128) .. pixel(70, 80, 90, 0) .. pixel(41, 51, 61, 200) .. pixel(71, 81, 91, 255)
  )
end

function T.crop_preserves_transparent_rgb_values()
  local source = asymmetric()
  local cropped = RgbaImage.crop(source, { x = 2, y = 0, width = 1, height = 1 }, "transparent")
  Assert.equal(cropped.pixels, pixel(70, 80, 90, 0), "transparent pixels keep their RGB channels")
end

function T.full_bounds_crop_returns_an_equal_copy()
  local source = asymmetric()
  local cropped = RgbaImage.crop(source, { x = 0, y = 0, width = 3, height = 2 }, "full")
  Assert.equal(cropped.width, 3)
  Assert.equal(cropped.height, 2)
  Assert.equal(cropped.pixels, source.pixels)
end

function T.crop_returns_last_row_last_column_pixel()
  local source = asymmetric()
  local cropped = RgbaImage.crop(source, { x = 2, y = 1, width = 1, height = 1 }, "corner")
  Assert.equal(cropped.width, 1)
  Assert.equal(cropped.height, 1)
  Assert.equal(cropped.pixels, pixel(71, 81, 91, 255))
end

function T.nonintegral_crop_rectangle_fails()
  local source = asymmetric()
  local ok, err = pcall(RgbaImage.crop, source, { x = 0.5, y = 0, width = 1, height = 1 }, "fraction")
  Assert.isFalse(ok, "a nonintegral rectangle must fail")
  Assert.notNil(tostring(err):find("BAG_GEOMETRY_INVALID"), "the failure must carry the protocol code")
end

function T.out_of_bounds_crop_fails()
  local source = asymmetric()
  local ok, err = pcall(RgbaImage.crop, source, { x = 2, y = 0, width = 2, height = 2 }, "overflow")
  Assert.isFalse(ok, "a rectangle escaping the source must fail")
  Assert.notNil(tostring(err):find("BAG_GEOMETRY_INVALID"), "the failure must carry the protocol code")
end

function T.malformed_source_pixels_fail()
  local broken = { width = 3, height = 2, pixels = "short" }
  local ok, err = pcall(RgbaImage.crop, broken, { x = 0, y = 0, width = 1, height = 1 }, "broken")
  Assert.isFalse(ok, "byte length mismatches must fail")
  Assert.notNil(tostring(err):find("BAG_GEOMETRY_INVALID"), "the failure must carry the protocol code")
end

function T.compose_keeps_opaque_top_and_transparent_bottom()
  local bottom = { width = 2, height = 1, pixels = pixel(10, 20, 30, 255) .. pixel(10, 20, 30, 255) }
  local top = { width = 2, height = 1, pixels = pixel(40, 50, 60, 255) .. pixel(0, 0, 0, 0) }
  local composed = RgbaImage.compose({ bottom, top }, "order")
  Assert.equal(composed.width, 2)
  Assert.equal(composed.height, 1)
  Assert.equal(composed.pixels, pixel(40, 50, 60, 255) .. pixel(10, 20, 30, 255))
  Assert.equal(top.pixels, pixel(40, 50, 60, 255) .. pixel(0, 0, 0, 0), "layer inputs are never mutated")
end

function T.compose_blends_boundary_alpha_values()
  local bottom = { width = 1, height = 1, pixels = pixel(10, 20, 30, 255) }
  local cases = {
    { alpha = 1, expected = { 11, 20, 30, 255 } },
    { alpha = 127, expected = { 105, 60, 40, 255 } },
    { alpha = 254, expected = { 199, 100, 50, 255 } },
    { alpha = 255, expected = { 200, 100, 50, 255 } },
  }
  for _, case in ipairs(cases) do
    local top = { width = 1, height = 1, pixels = pixel(200, 100, 50, case.alpha) }
    local composed = RgbaImage.compose({ bottom, top }, "boundary")
    Assert.deepEqual({ string.byte(composed.pixels, 1, 4) }, case.expected)
  end
  local halfBottom = { width = 1, height = 1, pixels = pixel(10, 20, 30, 128) }
  local halfTop = { width = 1, height = 1, pixels = pixel(200, 100, 50, 128) }
  local half = RgbaImage.compose({ halfBottom, halfTop }, "half")
  Assert.deepEqual({ string.byte(half.pixels, 1, 4) }, { 137, 73, 43, 192 })
  Assert.equal(bottom.pixels, pixel(10, 20, 30, 255), "bottom input is never mutated")
  Assert.equal(halfBottom.pixels, pixel(10, 20, 30, 128), "bottom input is never mutated")
end

function T.compose_blends_partial_alpha_over_opaque_bottom()
  local bottom = { width = 1, height = 1, pixels = pixel(10, 20, 30, 255) }
  local top = { width = 1, height = 1, pixels = pixel(40, 50, 60, 128) }
  local composed = RgbaImage.compose({ bottom, top }, "blend")
  Assert.deepEqual({ string.byte(composed.pixels, 1, 4) }, { 25, 35, 45, 255 })
end

function T.compose_stacks_multiple_layers_bottom_to_top()
  local bottom = { width = 1, height = 1, pixels = pixel(10, 20, 30, 255) }
  local middle = { width = 1, height = 1, pixels = pixel(40, 50, 60, 128) }
  local top = { width = 1, height = 1, pixels = pixel(70, 80, 90, 64) }
  local composed = RgbaImage.compose({ bottom, middle, top }, "stack")
  Assert.deepEqual({ string.byte(composed.pixels, 1, 4) }, { 36, 46, 56, 255 })
  Assert.equal(bottom.pixels, pixel(10, 20, 30, 255), "bottom input is never mutated")
  Assert.equal(middle.pixels, pixel(40, 50, 60, 128), "middle input is never mutated")
  Assert.equal(top.pixels, pixel(70, 80, 90, 64), "top input is never mutated")
end

function T.compose_rejects_mismatched_layers()
  local first = { width = 2, height = 1, pixels = string.rep("\0", 2 * 1 * 4) }
  local second = { width = 1, height = 1, pixels = string.rep("\0", 1 * 1 * 4) }
  local ok, err = pcall(RgbaImage.compose, { first, second }, "mismatch")
  Assert.isFalse(ok, "layers with different dimensions must fail")
  Assert.notNil(tostring(err):find("BAG_GEOMETRY_INVALID"), "the failure must carry the protocol code")
end

function T.compose_rejects_an_empty_layer_list()
  local ok, err = pcall(RgbaImage.compose, {}, "empty")
  Assert.isFalse(ok, "an empty layer list must fail")
  Assert.notNil(tostring(err):find("BAG_GEOMETRY_INVALID"), "the failure must carry the protocol code")
end

return { tests = T }
