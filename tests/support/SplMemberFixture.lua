-- Hand-built SPL particle members (layout per the retail SPL resource
-- structs) for synthetic compiler fixtures: self-destroying plain emitters
-- over blank 32x32 textures. No ROM bytes are involved.

local SplMemberFixture = {}

local SELF_DESTROY = 2 ^ 14

---@param value integer
---@return string
local function u16(value)
  value = value % 0x10000
  return string.char(value % 256, math.floor(value / 256) % 256)
end

---@param value integer
---@return string
local function u32(value)
  value = value % 0x100000000
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

-- An 88-byte emitter record with valid lifespans and generation interval.
---@param textureIndex integer
---@return string
local function emitter(textureIndex)
  return u32(SELF_DESTROY)
    .. string.rep("\0", 56)
    .. u16(18)
    .. u16(15)
    .. string.rep("\0", 4)
    .. string.char(1, 31, 0, textureIndex)
    .. u32(1)
    .. u32(0)
    .. u16(0)
    .. u16(0)
    .. u32(0)
end

---@return string
local function textureBlock()
  local texels = string.rep("\0", 1024)
  local palette = string.rep("\0", 2)
  return u32(0x53505420)
    .. u32(6 + 2 * 16 + 2 * 256)
    .. u32(#texels)
    .. u32(32 + #texels)
    .. u32(#palette)
    .. string.rep("\0", 8)
    .. u32(32 + #texels + #palette)
    .. texels
    .. palette
end

-- One member carrying `emitterCount` plain emitters over `textureCount`
-- blank textures, every emitter drawing texture 0.
---@param emitterCount integer
---@param textureCount integer
---@return string
function SplMemberFixture.member(emitterCount, textureCount)
  local parts = { " APS12_1" .. u16(emitterCount) .. u16(textureCount) .. string.rep("\0", 20) }
  for _ = 1, emitterCount do
    parts[#parts + 1] = emitter(0)
  end
  for _ = 1, textureCount do
    parts[#parts + 1] = textureBlock()
  end
  return table.concat(parts)
end

return SplMemberFixture
