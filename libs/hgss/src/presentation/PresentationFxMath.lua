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

-- Signed arithmetic shift: floor division by 2^k after the written
-- expression's signed-width wrap, matching the sourceFx shifts.
---@param value number signed 32-bit value under shifting
---@param shift integer non-negative shift amount
---@return integer shifted signed 32-bit result
function PresentationFxMath.arithmeticShift(value, shift)
  assert(shift % 1 == 0 and shift >= 0, "source shift amount is a non-negative integer")
  return PresentationFxMath.s32(math.floor(PresentationFxMath.s32(value) / (2 ^ shift)))
end

-- Exact signed 64-bit product of two signed 32-bit factors, returned as
-- exact high/low halves. Magnitudes multiply through the exact limb
-- product above; the sign applies afterwards.
---@param a number signed 32-bit factor
---@param b number signed 32-bit factor
---@return integer high high 32 bits of the magnitude
---@return integer low low 32 bits of the magnitude
---@return boolean negative true when the signed product is negative
local function signedProductParts(a, b)
  local sa = PresentationFxMath.s32(a)
  local sb = PresentationFxMath.s32(b)
  local ma = sa < 0 and -sa or sa
  local mb = sb < 0 and -sb or sb
  local hi, lo = magnitudeProduct(ma, mb)
  return hi, lo, (sa < 0) ~= (sb < 0)
end

-- Floor-division split of one signed 64-bit product (given as magnitude
-- halves plus sign) by 4096: the quotient stays below 2^51 and the
-- remainder in 0..4095, so every value below is exactly representable.
-- The caller combines quotient/remainder parts across products, which
-- keeps the rounded sum exact without a 64-bit host integer.
---@param hi integer high 32 bits of the product magnitude
---@param lo integer low 32 bits of the product magnitude
---@param negative boolean true when the signed product is negative
---@return integer quotient floor(product / 4096)
---@return integer remainder product - quotient * 4096 in 0..4095
local function productQuotientRemainder(hi, lo, negative)
  local quotientMagnitude = hi * 1048576 + math.floor(lo / FX_ONE)
  local remainderMagnitude = lo - math.floor(lo / FX_ONE) * FX_ONE
  if not negative then
    return quotientMagnitude, remainderMagnitude
  end
  if remainderMagnitude == 0 then
    return -quotientMagnitude, 0
  end
  return -quotientMagnitude - 1, FX_ONE - remainderMagnitude
end

-- Rounded 12-fraction dot product of two fx32 vectors: the three exact
-- signed 64-bit products sum before the single +2048 rounding bias and
-- truncating shift, matching the source vector helper.
---@param a { x: number, y: number, z: number } first fx32 vector
---@param b { x: number, y: number, z: number } second fx32 vector
---@return integer signed 32-bit rounded dot product
function PresentationFxMath.vecDot32(a, b)
  local quotient, remainder = 0, 2048
  for _, axis in ipairs({ "x", "y", "z" }) do
    local hi, lo, negative = signedProductParts(a[axis], b[axis])
    local q, r = productQuotientRemainder(hi, lo, negative)
    quotient, remainder = quotient + q, remainder + r
  end
  return PresentationFxMath.s32(quotient + math.floor(remainder / FX_ONE))
end

-- Rounded 12-fraction cross product of two fx32 vectors: each axis takes
-- the exact signed 64-bit difference of two products before the single
-- +2048 rounding bias and truncating shift.
---@param a { x: number, y: number, z: number } first fx32 vector
---@param b { x: number, y: number, z: number } second fx32 vector
---@return { x: integer, y: integer, z: integer } signed 32-bit rounded cross product
function PresentationFxMath.vecCross32(a, b)
  local axes = { { "y", "z" }, { "z", "x" }, { "x", "y" } }
  local names = { "x", "y", "z" }
  local result = {}
  for index, pair in ipairs(axes) do
    local first, second = pair[1], pair[2]
    local hi1, lo1, neg1 = signedProductParts(a[first], b[second])
    local hi2, lo2, neg2 = signedProductParts(a[second], b[first])
    local q1, r1 = productQuotientRemainder(hi1, lo1, neg1)
    local q2, r2 = productQuotientRemainder(hi2, lo2, neg2)
    result[names[index]] = PresentationFxMath.s32((q1 - q2) + math.floor((r1 - r2 + 2048) / FX_ONE))
  end
  return result --[[@as { x: integer, y: integer, z: integer }]]
end

-- 16-bit dot product: the source accumulates the x/y products and the
-- z product plus the rounding bias as separate s32 values before the
-- single truncating shift.
---@param a { x: number, y: number, z: number } first fx16 vector
---@param b { x: number, y: number, z: number } second fx16 vector
---@return integer signed 32-bit dot product
function PresentationFxMath.vecDot16(a, b)
  local temp1 = PresentationFxMath.s32(a.x * b.x + a.y * b.y)
  local temp2 = PresentationFxMath.s32(a.z * b.z + 2048)
  return PresentationFxMath.s32(math.floor((temp1 + temp2) / FX_ONE))
end

-- 16-bit cross product: each axis differences two s16 products with the
-- rounding bias as s32, shifts arithmetically by 12, then narrows to s16.
---@param a { x: number, y: number, z: number } first fx16 vector
---@param b { x: number, y: number, z: number } second fx16 vector
---@return { x: integer, y: integer, z: integer } signed 16-bit cross product
function PresentationFxMath.vecCross16(a, b)
  local axes = { { "y", "z" }, { "z", "x" }, { "x", "y" } }
  local names = { "x", "y", "z" }
  local result = {}
  for index, pair in ipairs(axes) do
    local first, second = pair[1], pair[2]
    local difference = PresentationFxMath.s32(a[first] * b[second] - a[second] * b[first] + 2048)
    result[names[index]] = PresentationFxMath.s16(PresentationFxMath.arithmeticShift(difference, 12))
  end
  return result --[[@as { x: integer, y: integer, z: integer }]]
end

-- Source vector normalization: the squared length accumulates in signed
-- 64-bit arithmetic, the reciprocal scales by 2^56 with truncation, and
-- the root path rescales through the 2^44/2^45 shifts. A zero vector
-- normalizes to zero components instead of dividing by zero.
---@param x number fx32 x component
---@param y number fx32 y component
---@param z number fx32 z component
---@return integer nx, integer ny, integer nz normalized fx32 components
function PresentationFxMath.normalize32(x, y, z)
  local length = x * x + y * y + z * z
  if length == 0 then
    return 0, 0, 0
  end
  local reciprocal = math.floor((2 ^ 56) / length)
  local root = math.floor(math.sqrt(length * 4))
  local factor = reciprocal * root
  local scale = 2 ^ 45
  local bias = 2 ^ 44
  local function axis(value)
    return PresentationFxMath.s32(math.floor((factor * value + bias) / scale))
  end
  return axis(x), axis(y), axis(z)
end

-- 16-bit normalization: same ladder with s16 narrowing on input and output.
---@param x number fx16 x component
---@param y number fx16 y component
---@param z number fx16 z component
---@return integer nx, integer ny, integer nz normalized fx16 components
function PresentationFxMath.normalize16(x, y, z)
  local sx = PresentationFxMath.s16(x)
  local sy = PresentationFxMath.s16(y)
  local sz = PresentationFxMath.s16(z)
  local length = sx * sx + sy * sy + sz * sz
  if length == 0 then
    return 0, 0, 0
  end
  local reciprocal = math.floor((2 ^ 56) / length)
  local root = math.floor(math.sqrt(length * 4))
  local factor = reciprocal * root
  local scale = 2 ^ 45
  local bias = 2 ^ 44
  local function axis(value)
    return PresentationFxMath.s16(PresentationFxMath.s32(math.floor((factor * value + bias) / scale)))
  end
  return axis(sx), axis(sy), axis(sz)
end

-- Source vector magnitude: s32 quantized half-root of the squared length.
---@param x number fx32 x component
---@param y number fx32 y component
---@param z number fx32 z component
---@return integer signed 32-bit magnitude
function PresentationFxMath.magnitude(x, y, z)
  local length = x * x + y * y + z * z
  local root = math.floor(math.sqrt(length * 4))
  return PresentationFxMath.s32(math.floor((root + 1) / 2))
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

-- Signed 64-bit division toward zero for projection reciprocals. Callers
-- keep magnitudes below the exact-integer range of host doubles.
---@param numerator number signed 64-bit dividend, exactly represented
---@param denominator number signed 64-bit divisor, never zero
---@return integer truncated quotient
function PresentationFxMath.wideDiv(numerator, denominator)
  assert(denominator ~= 0, "source projection names a nonzero divisor")
  local quotient = math.floor(numerator) / math.floor(denominator)
  if quotient >= 0 then
    return math.floor(quotient)
  end
  return math.ceil(quotient)
end

-- Unrounded row-vector 3x3 product: each output sums one row of the
-- matrix against the vector with an arithmetic shift by 12 and no
-- rounding bias, unlike the fixed multiply above.
---@param m number[] row-major 3x3 entries in fx32 units, 9 values
---@param v { x: number, y: number, z: number } fx32 vector
---@return { x: integer, y: integer, z: integer } fx32 result
function PresentationFxMath.matVec3(m, v)
  assert(#m == 9, "unrounded products use a row-major 3x3 matrix")
  local function lane(a0, a1, a2)
    return PresentationFxMath.s32(math.floor((v.x * a0 + v.y * a1 + v.z * a2) / 4096))
  end
  return {
    x = lane(m[1], m[4], m[7]),
    y = lane(m[2], m[5], m[8]),
    z = lane(m[3], m[6], m[9]),
  }
end

-- Unrounded row-vector affine 4x3 product: the 3x3 part applies without
-- bias, then the translation adds with s32 wrapping.
---@param m number[] row-major 3x3 plus translation, 12 values
---@param v { x: number, y: number, z: number } fx32 vector
---@return { x: integer, y: integer, z: integer } fx32 result
function PresentationFxMath.matVec43(m, v)
  assert(#m == 12, "affine products use a 3x3 matrix plus translation")
  local rotated = PresentationFxMath.matVec3({ m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9] }, v)
  return {
    x = PresentationFxMath.s32(rotated.x + m[10]),
    y = PresentationFxMath.s32(rotated.y + m[11]),
    z = PresentationFxMath.s32(rotated.z + m[12]),
  }
end

-- View-space transform from stored axes: each output dots the world
-- point against one camera axis without bias, then adds the stored
-- rounded translation.
---@param view number[] camera axes plus translation, 12 values
---@param world { x: number, y: number, z: number } raw fx32 world point
---@return { x: integer, y: integer, z: integer } raw fx32 view point
function PresentationFxMath.viewPoint(view, world)
  assert(#view == 12, "view transforms use camera axes plus translation")
  local function dot(ax, ay, az)
    return math.floor((world.x * ax + world.y * ay + world.z * az) / 4096)
  end
  return {
    x = PresentationFxMath.s32(dot(view[1], view[2], view[3]) + view[10]),
    y = PresentationFxMath.s32(dot(view[4], view[5], view[6]) + view[11]),
    z = PresentationFxMath.s32(dot(view[7], view[8], view[9]) + view[12]),
  }
end

-- Unrounded 3x3 concatenation: each entry sums three exact products and
-- shifts arithmetically by 12 with no bias.
---@param a number[] row-major left 3x3, 9 values
---@param b number[] row-major right 3x3, 9 values
---@return number[] row-major product, 9 values
function PresentationFxMath.concat33(a, b)
  assert(#a == 9 and #b == 9, "concatenation uses two row-major 3x3 matrices")
  local out = {}
  for row = 0, 2 do
    for col = 0, 2 do
      local sum = 0
      for k = 0, 2 do
        sum = sum + a[row * 3 + k + 1] * b[k * 3 + col + 1]
      end
      out[row * 3 + col + 1] = PresentationFxMath.s32(math.floor(sum / 4096))
    end
  end
  return out
end

-- Unrounded affine concatenation for row vectors: the 3x3 part
-- concatenates without bias; the translation is the left translation
-- transformed by the right rotation plus the right translation.
---@param a number[] left affine matrix, 12 values
---@param b number[] right affine matrix, 12 values
---@return number[] affine product, 12 values
function PresentationFxMath.concat43(a, b)
  assert(#a == 12 and #b == 12, "affine concatenation uses two 12-value matrices")
  local rotation = PresentationFxMath.concat33(
    { a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9] },
    { b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9] }
  )
  local moved = PresentationFxMath.matVec3(
    { b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9] },
    { x = a[10], y = a[11], z = a[12] }
  )
  return {
    rotation[1],
    rotation[2],
    rotation[3],
    rotation[4],
    rotation[5],
    rotation[6],
    rotation[7],
    rotation[8],
    rotation[9],
    PresentationFxMath.s32(moved.x + b[10]),
    PresentationFxMath.s32(moved.y + b[11]),
    PresentationFxMath.s32(moved.z + b[12]),
  }
end

-- Camera eye from stored angles around its target at its distance. The z
-- angle is stored but never rolls the camera.
---@param angleX integer raw u16 stored x angle
---@param angleY integer raw u16 stored y angle
---@param target { x: number, y: number, z: number } raw fx32 target
---@param distance number raw fx32 distance
---@return { x: integer, y: integer, z: integer } raw fx32 eye
function PresentationFxMath.cameraEye(angleX, angleY, target, distance)
  local sinY = PresentationFxMath.sinIdx(angleY)
  local cosY = PresentationFxMath.cosIdx(angleY)
  local cosX = PresentationFxMath.cosIdx(angleX)
  local sinNegX = PresentationFxMath.sinIdx(PresentationFxMath.u16(-angleX))
  local x = PresentationFxMath.s32(PresentationFxMath.fxMul(PresentationFxMath.fxMul(sinY, distance), cosX) + target.x)
  local z = PresentationFxMath.s32(PresentationFxMath.fxMul(PresentationFxMath.fxMul(cosY, distance), cosX) + target.z)
  local y = PresentationFxMath.s32(PresentationFxMath.fxMul(sinNegX, distance) + target.y)
  return { x = x, y = y, z = z }
end

-- View matrix from eye/target/up triples in raw fx32 units. Axes use the
-- rounded normalize/cross ladder; translation is the negated rounded
-- dot products. Returned as row-major 3x3 plus translation.
---@param eye { x: number, y: number, z: number } raw fx32 eye
---@param target { x: number, y: number, z: number } raw fx32 target
---@param up { x: number, y: number, z: number } raw fx16 up
---@return number[] affine view matrix, 12 values
function PresentationFxMath.lookAtView(eye, target, up)
  local zx, zy, zz = PresentationFxMath.normalize32(eye.x - target.x, eye.y - target.y, eye.z - target.z)
  local cx = PresentationFxMath.vecCross32(up, { x = zx, y = zy, z = zz })
  local xx, xy, xz = PresentationFxMath.normalize32(cx.x, cx.y, cx.z)
  local yAxis = PresentationFxMath.vecCross32({ x = zx, y = zy, z = zz }, { x = xx, y = xy, z = xz })
  return {
    xx,
    xy,
    xz,
    yAxis.x,
    yAxis.y,
    yAxis.z,
    zx,
    zy,
    zz,
    PresentationFxMath.s32(-PresentationFxMath.vecDot32(eye, { x = xx, y = xy, z = xz })),
    PresentationFxMath.s32(-PresentationFxMath.vecDot32(eye, yAxis)),
    PresentationFxMath.s32(-PresentationFxMath.vecDot32(eye, { x = zx, y = zy, z = zz })),
  }
end

-- Perspective projection with explicit fixed scale. All inputs and entries
-- are raw fx32; unspecified entries are zero. Uses the row-vector
-- convention with translation in the last row.
---@param nearPlane number raw fx32 near distance
---@param farPlane number raw fx32 far distance
---@param sinHalf integer raw fx16 sine of the half field of view
---@param cosHalf integer raw fx16 cosine of the half field of view
---@param aspect integer raw fx16 width over height
---@param scaleW number raw fx32 fixed scale
---@return number[] row-major 4x4 projection, 16 values
function PresentationFxMath.perspectiveW(nearPlane, farPlane, sinHalf, cosHalf, aspect, scaleW)
  local cot = PresentationFxMath.fxDiv(cosHalf, sinHalf)
  local distance = PresentationFxMath.s32(nearPlane - farPlane)
  local quotient = PresentationFxMath.wideDiv(4096 * 4294967296, distance)
  if scaleW ~= 4096 then
    cot = PresentationFxMath.truncDiv(PresentationFxMath.s32(cot * scaleW), 4096)
    quotient = PresentationFxMath.wideDiv(quotient * scaleW, 4096)
  end
  local m00 = PresentationFxMath.fxDiv(cot, aspect)
  local m11 = cot
  local sum = PresentationFxMath.s32(farPlane + nearPlane)
  local m22 = PresentationFxMath.s32(math.floor((quotient * sum + 2147483648) / 4294967296))
  local twiceNearFar = PresentationFxMath.fxMul(PresentationFxMath.s32(nearPlane * 2), farPlane)
  local m32 = PresentationFxMath.s32(math.floor((quotient * twiceNearFar + 2147483648) / 4294967296))
  return {
    m00,
    0,
    0,
    0,
    0,
    m11,
    0,
    0,
    0,
    0,
    m22,
    PresentationFxMath.s32(-scaleW),
    0,
    0,
    m32,
    0,
  }
end

-- Orthographic projection with explicit fixed scale. Symmetric extents
-- pass top/bottom/left/right directly; translation lands in the last row.
---@param top number raw fx32 top extent
---@param bottom number raw fx32 bottom extent
---@param left number raw fx32 left extent
---@param right number raw fx32 right extent
---@param nearPlane number raw fx32 near distance
---@param farPlane number raw fx32 far distance
---@param scaleW number raw fx32 fixed scale
---@return number[] row-major 4x4 projection, 16 values
function PresentationFxMath.orthoW(top, bottom, left, right, nearPlane, farPlane, scaleW)
  local function reciprocal(span)
    local quotient = PresentationFxMath.wideDiv(4096 * 4294967296, PresentationFxMath.s32(span))
    if scaleW ~= 4096 then
      quotient = PresentationFxMath.wideDiv(quotient * scaleW, 4096)
    end
    return quotient
  end
  local qx = reciprocal(right - left)
  local qy = reciprocal(top - bottom)
  local qz = reciprocal(nearPlane - farPlane)
  local m00 = PresentationFxMath.s32(math.floor((qx * 8192 + 2147483648) / 4294967296))
  local m11 = PresentationFxMath.s32(math.floor((qy * 8192 + 2147483648) / 4294967296))
  local m22 = PresentationFxMath.s32(math.floor((qz * 8192 + 2147483648) / 4294967296))
  local m30 =
    PresentationFxMath.s32(math.floor((qx * PresentationFxMath.s32(-(right + left)) + 2147483648) / 4294967296))
  local m31 =
    PresentationFxMath.s32(math.floor((qy * PresentationFxMath.s32(-(top + bottom)) + 2147483648) / 4294967296))
  local m32 =
    PresentationFxMath.s32(math.floor((qz * PresentationFxMath.s32(farPlane + nearPlane) + 2147483648) / 4294967296))
  return {
    m00,
    0,
    0,
    0,
    0,
    m11,
    0,
    0,
    0,
    0,
    m22,
    0,
    m30,
    m31,
    m32,
    PresentationFxMath.s32(scaleW),
  }
end

-- Projects one view-space point through a row-major projection. The 3x3
-- part scales arithmetically by 12; translation adds directly. W is
-- preserved for the host divide.
---@param point { x: number, y: number, z: number } raw view-space point
---@param proj number[] row-major 4x4 projection, 16 values
---@return { x: integer, y: integer, z: integer, w: integer } raw clip point
function PresentationFxMath.projectViewPoint(point, proj)
  local function scaled(value, entry)
    return math.floor((value * entry) / 4096)
  end
  return {
    x = PresentationFxMath.s32(
      scaled(point.x, proj[1]) + scaled(point.y, proj[5]) + scaled(point.z, proj[9]) + proj[13]
    ),
    y = PresentationFxMath.s32(
      scaled(point.x, proj[2]) + scaled(point.y, proj[6]) + scaled(point.z, proj[10]) + proj[14]
    ),
    z = PresentationFxMath.s32(
      scaled(point.x, proj[3]) + scaled(point.y, proj[7]) + scaled(point.z, proj[11]) + proj[15]
    ),
    w = PresentationFxMath.s32(
      scaled(point.x, proj[4]) + scaled(point.y, proj[8]) + scaled(point.z, proj[12]) + proj[16]
    ),
  }
end

-- Hardware quad packing: each local component narrows to s16, drops six
-- fractional bits, wraps to signed 10 bits, and scales back. Small
-- offsets quantize to 1/64 and large values wrap like the hardware.
-- Packing keeps the low 10 bits of the shifted value ((x >> 6) & 0x3FF)
-- and unpacking sign-extends them, so the wrap is a plain signed-10-bit
-- reduction of the shifted value with no additional bias.
---@param value number raw local component
---@return integer quantized raw component
function PresentationFxMath.vtx10Quantize(value)
  local narrowed = PresentationFxMath.s16(value)
  local dropped = PresentationFxMath.arithmeticShift(narrowed, 6)
  local unsigned = ((dropped % 1024) + 1024) % 1024
  if unsigned >= 512 then
    unsigned = unsigned - 1024
  end
  return PresentationFxMath.s32(unsigned * 64)
end

return PresentationFxMath
