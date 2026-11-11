-- Exact shared integer arithmetic for visual paths: signed wrapping,
-- truncating division, exact fixed-point multiply/divide with the source
-- rounding bias, and indexed lookup trigonometry. Expected values below
-- are hand-derived from the source integer rules, never from an
-- implementation trace.

local Assert = require("tests.support.Assert")

local T = {}

local function arithmetic()
  local ok, Fx = pcall(require, "libs.hgss.src.presentation.PresentationFxMath")
  Assert.isTrue(ok, "visual paths share one exact integer arithmetic leaf")
  return assert(Fx)
end

function T.signed_and_unsigned_wrapping_matches_source_widths()
  local Fx = arithmetic()
  Assert.equal(Fx.s16(0xFFFF), -1, "16-bit sign extension wraps")
  Assert.equal(Fx.s16(0x8000), -32768, "16-bit minimum survives narrowing")
  Assert.equal(Fx.s16(0x7FFF), 32767, "16-bit maximum passes through")
  Assert.equal(Fx.u16(-1), 65535, "negative values wrap into 16 bits")
  Assert.equal(Fx.s32(0xFFFFFFFF), -1, "32-bit sign extension wraps")
  Assert.equal(Fx.s32(0x80000000), -2147483648, "32-bit minimum survives narrowing")
  Assert.equal(Fx.u32(-1), 4294967295, "negative values wrap into 32 bits")
  Assert.equal(Fx.u32(0x100000000), 0, "wide values wrap out of 32 bits")
end

function T.division_truncates_toward_zero_like_source_integers()
  local Fx = arithmetic()
  Assert.equal(Fx.truncDiv(7, 2), 3, "positive division truncates")
  Assert.equal(Fx.truncDiv(-7, 2), -3, "negative dividends truncate toward zero")
  Assert.equal(Fx.truncDiv(7, -2), -3, "negative divisors truncate toward zero")
  Assert.equal(Fx.truncDiv(-7, -2), 3, "two negatives truncate toward zero")
end

function T.fixed_multiply_keeps_source_precision_and_bias()
  local Fx = arithmetic()
  Assert.equal(Fx.fxMul(0x1000, 0x1000), 0x1000, "one times one stays one")
  Assert.equal(Fx.fxMul(-0x1000, 0x1000), -0x1000, "sign survives the multiply")
  Assert.equal(Fx.fxMul(2049, 1), 1, "the positive rounding bias carries a fractional product up")
  Assert.equal(Fx.fxMul(-2049, 1), -1, "negative products use the same positive bias")
  Assert.equal(Fx.fxMul(0x40000000, 0x40000000), 0, "a 64-bit intermediate wraps into 32 bits")
end

function T.fixed_divide_keeps_source_precision_and_sign()
  local Fx = arithmetic()
  Assert.equal(Fx.fxDiv(0x1000, 0x1000), 0x1000, "one divided by one stays one")
  Assert.equal(Fx.fxDiv(0x800, 0x1000), 0x800, "one half stays one half")
  Assert.equal(Fx.fxDiv(-0x1000, 0x1000), -0x1000, "sign survives the divide")
  Assert.equal(Fx.fxDiv(0x1000, -0x1000), -0x1000, "a negative divisor flips the sign")
end

function T.lookup_trigonometry_matches_the_source_table()
  local Fx = arithmetic()
  Assert.equal(Fx.sinIdx(0), 0, "sine starts at zero")
  Assert.equal(Fx.sinIdx(0x4000), 0x1000, "sine peaks at a quarter turn")
  Assert.equal(Fx.sinIdx(0x8000), 0, "sine crosses zero at a half turn")
  Assert.equal(Fx.sinIdx(0xC000), -0x1000, "sine bottoms at three quarters")
  Assert.equal(Fx.cosIdx(0), 0x1000, "cosine starts at one")
  Assert.equal(Fx.cosIdx(0x4000), 0, "cosine crosses zero at a quarter turn")
  Assert.equal(Fx.cosIdx(0x8000), -0x1000, "cosine bottoms at a half turn")
  Assert.equal(Fx.cosIdx(0xFFFF), Fx.cosIdx(0), "degree indices wrap like the source table")
end

-- Particle geometry needs the source vector/matrix layer on the same leaf:
-- rounded 12-fraction products, unrounded concatenation, and the exact
-- normalize/magnitude ladder. Host floating-point geometry cannot stand in.
function T.vector_products_keep_source_rounding_before_narrowing()
  local Fx = arithmetic()
  Assert.isTrue(
    type(Fx.vecDot32) == "function",
    "visual paths share the source rounded vector dot product on the arithmetic leaf"
  )
  Assert.equal(
    Fx.vecDot32({ x = 4096, y = 0, z = 0 }, { x = 4096, y = 0, z = 0 }),
    4096,
    "a unit-axis dot product keeps the rounded 12-fraction scale"
  )
  Assert.isTrue(
    type(Fx.vecCross32) == "function",
    "visual paths share the source rounded vector cross product on the arithmetic leaf"
  )
  local cross = Fx.vecCross32({ x = 4096, y = 0, z = 0 }, { x = 0, y = 4096, z = 0 })
  Assert.equal(cross.x, 0, "axis cross keeps x")
  Assert.equal(cross.y, 0, "axis cross keeps y")
  Assert.equal(cross.z, 4096, "axis cross resolves z at the rounded scale")
  Assert.isTrue(
    type(Fx.normalize32) == "function" and type(Fx.magnitude) == "function",
    "visual paths share the source normalize/magnitude ladder on the arithmetic leaf"
  )
end

function T.unrounded_matrix_products_shift_without_bias()
  local Fx = arithmetic()
  local moved = Fx.matVec3({ 2049, 0, 0, 0, 4096, 0, 0, 0, 4096 }, { x = 1, y = 0, z = 0 })
  Assert.equal(moved.x, 0, "a fractional matrix entry scales without the multiply bias")
  Assert.equal(Fx.fxMul(2049, 1), 1, "the rounded multiply carries the same entry up")
  local affine = Fx.matVec43({ 4096, 0, 0, 0, 4096, 0, 0, 0, 4096, 10, 20, 30 }, { x = 4096, y = 4096, z = 4096 })
  Assert.deepEqual(
    { x = affine.x, y = affine.y, z = affine.z },
    { x = 4106, y = 4116, z = 4126 },
    "affine translation adds after the unrounded rotation"
  )
end

function T.default_camera_looks_down_negative_depth_with_known_translation()
  local Fx = arithmetic()
  local view = Fx.lookAtView({ x = 0, y = 0, z = 16384 }, { x = 0, y = 0, z = 0 }, { x = 0, y = 4096, z = 0 })
  Assert.deepEqual(
    { view[1], view[2], view[3], view[4], view[5], view[6], view[7], view[8], view[9] },
    { 4096, 0, 0, 0, 4096, 0, 0, 0, 4096 },
    "the default camera keeps identity axes"
  )
  Assert.deepEqual(
    { view[10], view[11], view[12] },
    { 0, 0, -16384 },
    "the default camera translates depth by the eye distance"
  )
  local moved = Fx.viewPoint(view, { x = 0, y = 0, z = 0 })
  Assert.deepEqual(
    { x = moved.x, y = moved.y, z = moved.z },
    { x = 0, y = 0, z = -16384 },
    "the world origin lands on the negative depth axis"
  )
end

function T.orthographic_projection_matches_the_pixel_space_matrix()
  local Fx = arithmetic()
  local proj = Fx.orthoW(0, 786432, 0, 1048576, -4194304, 4194304, 4194304)
  Assert.deepEqual(
    { proj[1], proj[6], proj[11], proj[16] },
    { 32768, -43691, -4096, 4194304 },
    "the pixel-space orthographic diagonal keeps source quantization"
  )
  Assert.deepEqual(
    { proj[13], proj[14], proj[15] },
    { -4194304, 4194304, 0 },
    "the pixel-space orthographic translation keeps source rounding"
  )
end

return { tests = T }
