-- Synthetic G2D multi-cell and multi-animation banks (NCER/NANR containers)
-- for producer tests: compact encoders that mirror the source layouts the
-- decoder reads, so fixtures can carry many cells and animations.

local G2dBankFixture = {}

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end
local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function swap4(s)
  return s:reverse()
end

local function container(magic, blocks)
  local body = {}
  local size = 0x10
  for _, blk in ipairs(blocks) do
    body[#body + 1] = blk
    size = size + #blk
  end
  return magic .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(size) .. u16(0x10) .. u16(#blocks) .. table.concat(body)
end

local function block(magic, payload)
  return swap4(magic) .. u32(8 + #payload) .. payload
end

-- A multi-cell OBJ bank: each entry is one cell carrying its own object list.
---@param cellObjs table[][] one object list per cell
---@return string
function G2dBankFixture.cellBank(cellObjs)
  local meta, attr = {}, {}
  local offset = 0
  for _, objs in ipairs(cellObjs) do
    meta[#meta + 1] = u16(#objs) .. u16(0) .. u32(offset)
    offset = offset + #objs * 6
  end
  for _, objs in ipairs(cellObjs) do
    for _, o in ipairs(objs) do
      attr[#attr + 1] = u16((o.y % 256) + (o.shape or 0) * 16384)
        .. u16((o.x % 512) + (o.flipH and 4096 or 0) + (o.flipV and 8192 or 0) + (o.size or 0) * 16384)
        .. u16(o.tile + o.pal * 4096)
    end
  end
  return container("RECN", {
    block(
      "CEBK",
      u16(#cellObjs)
        .. u16(0)
        .. u32(0x18)
        .. u32(0)
        .. string.rep("\0", 12)
        .. table.concat(meta)
        .. table.concat(attr)
    ),
  })
end

-- A multi-animation bank: each entry is either a cell index or a list of
-- frames. Mirrors the source animation table while keeping simple fixtures
-- compact.
---@param animCells (integer|table[])[] one cell index or frame list per animation
---@return string
function G2dBankFixture.animBank(animCells)
  local count = #animCells
  local totalFrames = 0
  for _, frames in ipairs(animCells) do
    totalFrames = totalFrames + (type(frames) == "table" and #frames or 1)
  end
  local anims, frames, data = {}, {}, {}
  local frameCursor = 0
  local dataCursor = 0
  for _, sourceFrames in ipairs(animCells) do
    local animationFrames = type(sourceFrames) == "table" and sourceFrames or { { cell = sourceFrames, duration = 3 } }
    anims[#anims + 1] = u32(#animationFrames) .. u16(0) .. u16(1) .. u32(1) .. u32(frameCursor * 8)
    for _, frame in ipairs(animationFrames) do
      frames[#frames + 1] = u32(dataCursor * 2) .. u16(frame.duration) .. u16(0)
      data[#data + 1] = u16(frame.cell)
      frameCursor = frameCursor + 1
      dataCursor = dataCursor + 1
    end
  end
  local animsOffset = 0x18
  local framesOffset = animsOffset + 16 * count
  local dataOffset = framesOffset + 8 * totalFrames
  return container("RNAN", {
    block(
      "ABNK",
      u16(count)
        .. u16(totalFrames)
        .. u32(animsOffset)
        .. u32(framesOffset)
        .. u32(dataOffset)
        .. string.rep("\0", 8)
        .. table.concat(anims)
        .. table.concat(frames)
        .. table.concat(data)
    ),
  })
end

return G2dBankFixture
