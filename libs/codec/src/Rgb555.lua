-- Conversion from Nintendo DS RGB555 (red bits 0..4, green bits 5..9, blue bits
-- 10..14) to 8-bit sRGB. Canonical source: pret/pokeheartgold,
-- lib/include/nitro/gx/gxcommon.h

local Rgb555 = {}

local function expand5(value)
  return math.floor((value * 255 + 15) / 31)
end

local function assertChannel(value, name)
  assert(
    type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 31,
    name .. " must be a 5-bit channel (0..31)"
  )
end

---@param r5 integer 0..31
---@param g5 integer 0..31
---@param b5 integer 0..31
---@return integer word
function Rgb555.encode(r5, g5, b5)
  assertChannel(r5, "red")
  assertChannel(g5, "green")
  assertChannel(b5, "blue")
  return r5 + g5 * 32 + b5 * 1024
end

---@param word integer
---@return { r: integer, g: integer, b: integer }
function Rgb555.decode(word)
  assert(
    type(word) == "number" and word % 1 == 0 and word >= 0 and word <= 0xFFFF,
    "RGB555 word must be an unsigned 16-bit integer"
  )

  local r5 = word % 32
  local g5 = math.floor(word / 32) % 32
  local b5 = math.floor(word / 1024) % 32

  return {
    r = expand5(r5),
    g = expand5(g5),
    b = expand5(b5),
  }
end

return Rgb555
