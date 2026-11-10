-- Exact source integer and fixed-point arithmetic for visual paths.
-- Native mechanism: the SDK fixed routines the battle animation helpers
-- call (FX_Mul, FX_Div, SinIdx/CosIdx against the 4096-entry signed fx16
-- lookup). Lua numbers cannot hold every intermediate product, so the
-- wide operations split operands into exact 16-bit limbs and reassemble
-- only the wrapped result. Narrowing, truncating division and the lookup
-- table match source widths and rounding exactly; no host double
-- multiplication beyond exact integer range and no unquantized host
-- trigonometry in task trajectories.

---@class PresentationFxMath
local PresentationFxMath = {}

local MOD32 = 4294967296
local HALF = 65536
local FX_ONE = 4096

---@param value number value under narrowing
---@return integer signed 16-bit result
function PresentationFxMath.s16(value)
  return ((math.floor(value) + 32768) % HALF) - 32768
end

---@param value number value under narrowing
---@return integer unsigned 16-bit result
function PresentationFxMath.u16(value)
  return math.floor(value) % HALF
end

---@param value number value under narrowing
---@return integer signed 32-bit result
function PresentationFxMath.s32(value)
  return ((math.floor(value) + 2147483648) % MOD32) - 2147483648
end

---@param value number value under narrowing
---@return integer unsigned 32-bit result
function PresentationFxMath.u32(value)
  return math.floor(value) % MOD32
end

-- C integer division truncates toward zero.
---@param numerator number dividend
---@param denominator number divisor, never zero
---@return integer truncated quotient
function PresentationFxMath.truncDiv(numerator, denominator)
  assert(denominator ~= 0, "source integer division names a nonzero divisor")
  local quotient = math.floor(numerator) / math.floor(denominator)
  if quotient >= 0 then
    return math.floor(quotient)
  end
  return math.ceil(quotient)
end

---@param value number unsigned 32-bit value under splitting
---@return integer high 16 bits
---@return integer low 16 bits
local function splitU32(value)
  local lo = math.floor(value % HALF)
  return math.floor((value - lo) / HALF), lo
end

-- Unsigned 64-bit magnitude product of two unsigned 32-bit values,
-- returned as exact high/low 32-bit halves. Every partial stays below
-- 2^33, so no host double rounding intrudes.
---@param a number unsigned 32-bit factor
---@param b number unsigned 32-bit factor
---@return integer high 32 bits of the product
---@return integer low 32 bits of the product
local function magnitudeProduct(a, b)
  local aHi, aLo = splitU32(a)
  local bHi, bLo = splitU32(b)
  local mid = aHi * bLo + aLo * bHi
  local midHi = math.floor(mid / HALF)
  local midLo = mid - midHi * HALF
  local lo = aLo * bLo + midLo * HALF
  local loCarry = math.floor(lo / MOD32)
  lo = lo - loCarry * MOD32
  local hi = (aHi * bHi + midHi + loCarry) % MOD32
  return hi, lo
end

-- FX_Mul: s32((s64(a*b)+2048) arithmetic-shift-right 12). The positive
-- bias applies to negative products too. The shift is a floor division,
-- so only the low 32 bits of the floored quotient survive, computed
-- from exact limb halves.
---@param a number signed 32-bit factor
---@param b number signed 32-bit factor
---@return integer signed 32-bit fixed product
function PresentationFxMath.fxMul(a, b)
  local sa = PresentationFxMath.s32(a)
  local sb = PresentationFxMath.s32(b)
  local ua = sa < 0 and (MOD32 + sa) or sa
  local ub = sb < 0 and (MOD32 + sb) or sb
  local negative = (sa < 0) ~= (sb < 0)
  local ma = sa < 0 and (MOD32 - ua) or ua
  local mb = sb < 0 and (MOD32 - ub) or ub
  local hi, lo = magnitudeProduct(ma, mb)
  local quotient
  if not negative then
    quotient = hi * 1048576 + math.floor((lo + 2048) / FX_ONE)
  else
    quotient = -hi * 1048576 + math.floor((2048 - lo) / FX_ONE)
  end
  return PresentationFxMath.s32(quotient)
end

-- Exact floor of (numerator * 2^32 / denominator) for magnitudes below
-- 2^32, via two exact 16-bit stages. The remainder of each stage stays
-- below 2^48, so every intermediate value is exactly representable.
---@param magnitude number unsigned 32-bit dividend magnitude
---@param divisor number unsigned 32-bit divisor magnitude, never zero
---@return integer floored unsigned quotient, below 2^48
local function magnitudeShiftedQuotient(magnitude, divisor)
  local stage = magnitude * HALF
  local first = math.floor(stage / divisor)
  local rest = stage - first * divisor
  local stage2 = rest * HALF
  local second = math.floor(stage2 / divisor)
  return first * HALF + second
end

-- FX_Div: q=trunc((s64(a)<<32)/s32(b)); s32((q+0x80000)
-- arithmetic-shift-right 20). Negative rounding uses the same positive
-- bias; the final shift is a floor division whose low 32 bits survive.
---@param a number signed 32-bit dividend
---@param b number signed 32-bit divisor, never zero
---@return integer signed 32-bit fixed quotient
function PresentationFxMath.fxDiv(a, b)
  local sa = PresentationFxMath.s32(a)
  local sb = PresentationFxMath.s32(b)
  assert(sb ~= 0, "source fixed division names a nonzero divisor")
  local negative = (sa < 0) ~= (sb < 0)
  local ma = sa < 0 and -sa or sa
  local mb = sb < 0 and -sb or sb
  local magnitude = magnitudeShiftedQuotient(ma, mb)
  local shifted
  if not negative then
    -- q >= 0: floor((q + 0x80000) / 2^20) from exact halves.
    local qHi = math.floor(magnitude / MOD32)
    local qLo = magnitude - qHi * MOD32
    shifted = qHi * FX_ONE + math.floor((qLo + 524288) / 1048576)
  else
    -- q < 0: arithmetic shift is floor division; split around the bias.
    local qHi = math.floor(magnitude / MOD32)
    local qLo = magnitude - qHi * MOD32
    if qLo <= 524288 then
      shifted = -qHi * FX_ONE + math.floor((524288 - qLo) / 1048576)
    else
      shifted = -qHi * FX_ONE - math.floor((qLo - 524288 + 1048575) / 1048576)
    end
  end
  return PresentationFxMath.s32(shifted)
end

-- The 4096-entry signed fx16 sine lookup, quantized once at load so task
-- trajectories never evaluate host trigonometry per tick. Entry i holds
-- round(sin(i * 2pi / 4096) * 4096); the cardinal entries land exactly.
local SINE_TABLE = {}
do
  for index = 0, 4095 do
    local sample = math.sin(index * math.pi * 2 / 4096) * 4096
    local rounded = sample >= 0 and math.floor(sample + 0.5) or math.ceil(sample - 0.5)
    if rounded > 32767 then
      rounded = 32767
    elseif rounded < -32768 then
      rounded = -32768
    end
    SINE_TABLE[index] = rounded
  end
end

---@param index integer table entry under validation
---@return integer sine value in signed fx16
local function lookupSine(index)
  return SINE_TABLE[index % 4096]
end

-- Indexed sine: lookup floor(u16(angle)/16) in the 4096-entry table.
---@param angle number source degree/radian index, wraps like the source table
---@return integer signed fx16 sine value
function PresentationFxMath.sinIdx(angle)
  return lookupSine(math.floor(PresentationFxMath.u16(angle) / 16))
end

-- Indexed cosine: the same table one quarter turn ahead.
---@param angle number source degree/radian index, wraps like the source table
---@return integer signed fx16 cosine value
function PresentationFxMath.cosIdx(angle)
  return lookupSine(math.floor(PresentationFxMath.u16(angle + 16384) / 16))
end

return PresentationFxMath
