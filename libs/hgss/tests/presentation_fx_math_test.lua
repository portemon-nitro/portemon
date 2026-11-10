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

return { tests = T }
