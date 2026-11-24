-- Strict decoder for the Nitro G2D container formats used by HGSS UI
-- resources: the "RGCN/RCSN/RECN/RNAN" containers (and their uncompressed
-- RLCN-wrapped siblings) plus the RAHC (char tiles), TTLP/PLTT (palette),
-- NRCS (screen), KBEC (cell) and KNBA (animation) chunks. Container magics
-- and chunk IDs are stored byte-swapped (e.g. "RGCN" for NCGR, "RAHC" for
-- CHAR) as documented by GBATEK's "Nitro Character Tiles / BG Maps Screens /
-- OBJ Animations / OBJ Metatile Cells" pages. The runtime never consumes
-- these structures; the FieldUiCompiler turns them into generated assets.
-- Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local Rgb555 = require("libs.codec.src.Rgb555")
local FieldFontDecoder = require("romdump.src.digest.ui.FieldFontDecoder")

local G2dDecoder = {}

-- Named ownership of the protocol error codes; tests assert the constants,
-- never the raw strings.
G2dDecoder.ERROR = {
  TRUNCATED = "G2D_TRUNCATED",
  MAGIC_INVALID = "G2D_MAGIC_INVALID",
  BYTE_ORDER_INVALID = "G2D_BYTE_ORDER_INVALID",
  BLOCK_INVALID = "G2D_BLOCK_INVALID",
  CHUNK_DUPLICATE = "G2D_CHUNK_DUPLICATE",
  CHUNK_MISSING = "G2D_CHUNK_MISSING",
  CHUNK_INVALID = "G2D_CHUNK_INVALID",
}

local function toScale(raw)
  -- Fixed-point s32 20.12 -> float scale factor. Normalize exactly once.
  if raw >= 2147483648 then
    raw = raw - 4294967296
  end
  return raw / 4096
end

-- The container/chunk IDs are stored byte-swapped; the swap yields the
-- canonical name.
local function swapped(reader, offset)
  return string.reverse(reader:ascii(offset, 4))
end

-- Parse the exact retail-tail envelope: the declared size exceeds the actual
-- bytes by exactly sixteen, every present block is complete inside the
-- actual bytes, and the missing sixteen bytes sit wholly after complete
-- blocks at EOF. Returns the parsed blocks plus the offset where the
-- missing tail starts so the caller can require its required chunk to end
-- before it. Anything else (a different over-declaration, a partially
-- present block, or no missing block at all) stays rejected.
local function tailBlocks(reader, magic, declaredSize, headerSize, blockCount)
  local actual = reader:length()
  if declaredSize - actual ~= 16 then
    Errors.raise(G2dDecoder.ERROR.TRUNCATED, "G2D resource declares " .. declaredSize .. " bytes but has " .. actual, {
      declared = declaredSize,
      size = actual,
    })
  end
  local blocks = {}
  local offset = headerSize
  local parsed = 0
  for _ = 1, blockCount do
    if offset + 8 > actual then
      break
    end
    local name = swapped(reader, offset)
    local size = reader:u32le(offset + 4)
    if size < 8 or offset + size > actual then
      Errors.raise(G2dDecoder.ERROR.BLOCK_INVALID, "G2D block " .. name .. " extends past the available bytes", {
        name = name,
        size = size,
        offset = offset,
      })
    end
    if blocks[name] ~= nil then
      Errors.raise(
        G2dDecoder.ERROR.CHUNK_DUPLICATE,
        "G2D resource carries duplicate " .. name .. " chunks",
        { chunk = name, offset = offset }
      )
    end
    blocks[name] = { offset = offset, payload = offset + 8, size = size - 8 }
    offset = offset + size
    parsed = parsed + 1
  end
  if parsed == blockCount then
    Errors.raise(G2dDecoder.ERROR.TRUNCATED, "G2D resource declares " .. declaredSize .. " bytes but has " .. actual, {
      declared = declaredSize,
      size = actual,
    })
  end
  return magic, blocks, offset
end

local function _blocks(reader, opts)
  if reader:length() < 4 then
    Errors.raise(G2dDecoder.ERROR.TRUNCATED, "G2D resource is shorter than its magic", { size = reader:length() })
  end
  local magic = swapped(reader, 0)
  if not opts.magics[magic] then
    Errors.raise(G2dDecoder.ERROR.MAGIC_INVALID, "unknown G2D container magic", { magic = magic })
  end
  if reader:length() < 0x10 then
    Errors.raise(
      G2dDecoder.ERROR.TRUNCATED,
      "G2D resource is shorter than its 16-byte header",
      { size = reader:length() }
    )
  end
  local byteOrder = reader:u16le(4)
  if byteOrder ~= 0xFEFF then
    Errors.raise(G2dDecoder.ERROR.BYTE_ORDER_INVALID, "G2D byte order is not 0xFEFF", { byteOrder = byteOrder })
  end
  local declaredSize = reader:u32le(8)
  -- The evidenced retail background CHAR family declares sixteen bytes past
  -- its complete CHAR block. The producer opts into that exact envelope with
  -- allowRetailTail; every other caller keeps the strict truncation check.
  -- Only a wholly-missing trailing block is excused, never a short,
  -- over-declared, duplicated, or corrupt resource.
  local tail = opts.allowRetailTail == true and declaredSize > reader:length()
  if declaredSize > reader:length() and not tail then
    Errors.raise(
      G2dDecoder.ERROR.TRUNCATED,
      "G2D resource declares " .. declaredSize .. " bytes but has " .. reader:length(),
      {
        declared = declaredSize,
        size = reader:length(),
      }
    )
  end
  local headerSize = reader:u16le(12)
  local blockCount = reader:u16le(14)
  if headerSize < 0x10 or headerSize + 8 * blockCount > declaredSize then
    Errors.raise(G2dDecoder.ERROR.BLOCK_INVALID, "G2D header claims an invalid block table", {
      headerSize = headerSize,
      blockCount = blockCount,
    })
  end
  if tail then
    return tailBlocks(reader, magic, declaredSize, headerSize, blockCount)
  end
  local blocks = {}
  local offset = headerSize
  for _ = 1, blockCount do
    if offset + 8 > declaredSize then
      Errors.raise(
        G2dDecoder.ERROR.BLOCK_INVALID,
        "G2D block header extends past the declared size",
        { offset = offset }
      )
    end
    local name = swapped(reader, offset)
    local size = reader:u32le(offset + 4)
    if size < 8 or offset + size > declaredSize then
      Errors.raise(G2dDecoder.ERROR.BLOCK_INVALID, "G2D block " .. name .. " extends past the declared size", {
        name = name,
        size = size,
        offset = offset,
      })
    end
    if blocks[name] ~= nil then
      Errors.raise(
        G2dDecoder.ERROR.CHUNK_DUPLICATE,
        "G2D resource carries duplicate " .. name .. " chunks",
        { chunk = name, offset = offset }
      )
    end
    blocks[name] = { offset = offset, payload = offset + 8, size = size - 8 }
    offset = offset + size
  end
  return magic, blocks, nil
end

local function blocks(data, opts, label)
  local reader = BinaryReader.new(data, label)
  local ok, magic, blks, missingAt = pcall(_blocks, reader, opts)
  if not ok then
    error(magic, 0)
  end
  return magic, blks, reader, missingAt
end

local function mustBlock(blks, name)
  local blk = blks[name]
  if not blk then
    Errors.raise(G2dDecoder.ERROR.CHUNK_MISSING, "G2D resource has no " .. name .. " chunk", { chunk = name })
  end
  return blk
end

local CONTAINER_MAGICS = {
  NCGR = true,
  NSCR = true,
  NCER = true,
  NANR = true,
  NCLR = true,
  RLCN = true,
}

-- OBJ pixel dimensions per GBATEK's OAM size table, indexed by attr0 shape
-- (bits 14-15) then attr1 size (bits 14-15). Square objects are 8/16/32/64;
-- wide and tall objects cover the intermediate sizes. The decoder exposes
-- shape/size so consumers can reject geometries they do not support.
---@alias G2dDecoder.ObjMode "normal"|"translucent"|"window"|"bitmap"
---@alias G2dDecoder.ColorMode "16-color"|"256-color"
local OBJ_DIMENSIONS = {
  { { 8, 8 }, { 16, 16 }, { 32, 32 }, { 64, 64 } },
  { { 16, 8 }, { 32, 8 }, { 32, 16 }, { 64, 32 } },
  { { 8, 16 }, { 8, 32 }, { 16, 32 }, { 32, 64 } },
}

-- ATTR0 OBJ mode values from GBATEK's OAM attribute documentation.
local OBJ_MODE = {
  [0] = "normal",
  [1] = "translucent",
  [2] = "window",
  [3] = "bitmap",
}

-- Nitro animation play mode (NNSG2dAnimationPlayMode) normalized to
-- source-independent playback semantics at the format boundary.
local PLAY_MODE = {
  [1] = "forward",
  [2] = "forward_loop",
  [3] = "reverse",
  [4] = "reverse_loop",
}

local USER_ANIMATION_ATTRIBUTE_BLOCK = 0x55414154

---@param reader BinaryReader
---@param block { payload: integer, size: integer }
---@param animations table[] decoded source animation sequences
local function decodeUserAnimationAttributes(reader, block, animations)
  if block.size < 0x18 then
    return
  end
  local extensionOffset = reader:u32le(block.payload + 20)
  if extensionOffset == 0 then
    return
  end
  if extensionOffset + 8 > block.size then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM user extension header exceeds the chunk", {
      extensionOffset = extensionOffset,
      chunkSize = block.size,
    })
  end
  local extension = block.payload + extensionOffset
  if reader:u32le(extension) ~= USER_ANIMATION_ATTRIBUTE_BLOCK then
    return
  end
  local extensionSize = reader:u32le(extension + 4)
  if extensionSize < 16 or extensionOffset + extensionSize > block.size then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "UAAT user animation data exceeds the chunk", {
      extensionOffset = extensionOffset,
      extensionSize = extensionSize,
      chunkSize = block.size,
    })
  end
  local bank = extension + 8
  local bankSize = extensionSize - 8
  local sequenceCount = reader:u16le(bank)
  local attributeCount = reader:u16le(bank + 2)
  local sequenceOffset = reader:u32le(bank + 4)
  if sequenceCount > #animations or attributeCount == 0 then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "UAAT sequence or attribute count is invalid", {
      sequenceCount = sequenceCount,
      animationCount = #animations,
      attributeCount = attributeCount,
    })
  end
  if sequenceOffset + sequenceCount * 12 > bankSize then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "UAAT sequence table exceeds the extension", {
      sequenceOffset = sequenceOffset,
      sequenceCount = sequenceCount,
      extensionSize = extensionSize,
    })
  end
  for sequenceIndex = 0, sequenceCount - 1 do
    local sequenceOffsetInBank = sequenceOffset + sequenceIndex * 12
    local frameCount = reader:u16le(bank + sequenceOffsetInBank)
    local attributeValuesOffset = reader:u32le(bank + sequenceOffsetInBank + 4)
    local frameAttributesOffset = reader:u32le(bank + sequenceOffsetInBank + 8)
    if frameCount ~= 0 and frameCount ~= #animations[sequenceIndex + 1].frames then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "UAAT frame count disagrees with its animation sequence", {
        sequence = sequenceIndex,
        attributeFrames = frameCount,
        animationFrames = #animations[sequenceIndex + 1].frames,
      })
    end
    if attributeValuesOffset + attributeCount * 4 > bankSize then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "UAAT sequence attribute values exceed the extension", {
        sequence = sequenceIndex,
        attributeValuesOffset = attributeValuesOffset,
        attributeCount = attributeCount,
      })
    end
    if frameAttributesOffset + frameCount * 4 > bankSize then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "UAAT frame attribute table exceeds the extension", {
        sequence = sequenceIndex,
        frameAttributesOffset = frameAttributesOffset,
        frameCount = frameCount,
      })
    end
    for frameIndex = 0, frameCount - 1 do
      local valueOffset = reader:u32le(bank + frameAttributesOffset + frameIndex * 4)
      if valueOffset + attributeCount * 4 > bankSize then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "UAAT frame attribute values exceed the extension", {
          sequence = sequenceIndex,
          frame = frameIndex,
          valueOffset = valueOffset,
          attributeCount = attributeCount,
        })
      end
      animations[sequenceIndex + 1].frames[frameIndex + 1].userAttr = reader:u32le(bank + valueOffset)
    end
  end
end

local function decodeCharBlock(data, opts)
  local _, blks, reader, missingAt =
    blocks(data, { magics = CONTAINER_MAGICS, allowRetailTail = opts.allowRetailTail }, opts.label or "g2d-char")
  local blk = mustBlock(blks, "CHAR")
  if missingAt ~= nil then
    -- The excused tail must sit wholly after the complete CHAR block; the
    -- exception never manufactures tile data for an incomplete CHAR.
    local charEnd = blk.offset + 8 + blk.size
    if charEnd > missingAt then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "CHAR block is incomplete inside the retail-tail envelope", {
        charEnd = charEnd,
        missingAt = missingAt,
      })
    end
  end
  if blk.size < 0x18 then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "CHAR chunk is shorter than its header", { size = blk.size })
  end
  local depth = reader:u32le(blk.payload + 4)
  if depth ~= 3 and depth ~= 4 then
    Errors.raise(
      G2dDecoder.ERROR.CHUNK_INVALID,
      "CHAR depth " .. depth .. " is not 3 (4bpp) or 4 (8bpp)",
      { depth = depth }
    )
  end
  local tileBytes = reader:u32le(blk.payload + 0x10)
  local tileOffset = reader:u32le(blk.payload + 0x14)
  local tileSize = depth == 3 and 32 or 64
  if tileBytes == 0 or tileBytes % tileSize ~= 0 then
    Errors.raise(
      G2dDecoder.ERROR.CHUNK_INVALID,
      "CHAR tile region must be an exact positive multiple of the " .. tileSize .. "-byte tile size",
      { tileBytes = tileBytes, tileSize = tileSize }
    )
  end
  if tileOffset + tileBytes > blk.size then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "CHAR tile region exceeds the chunk", {
      tileBytes = tileBytes,
      tileOffset = tileOffset,
      chunkSize = blk.size,
    })
  end
  return {
    depth = depth,
    tiles = reader:bytes(blk.payload + tileOffset, tileBytes),
  }
end

local function decodeScreenBlock(data, opts)
  local _, blks, reader = blocks(data, { magics = CONTAINER_MAGICS }, opts.label or "g2d-screen")
  local blk = mustBlock(blks, "SCRN")
  if blk.size < 12 then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "SCRN chunk is shorter than its header", { size = blk.size })
  end
  local width = reader:u16le(blk.payload)
  local height = reader:u16le(blk.payload + 2)
  -- The header's colour mode describes the palette arrangement, not the map
  -- entry width: a 256-colour *text* background still stores two bytes per
  -- entry (tile index plus flips and a 256-colour bank index), while a
  -- 256-colour *affine* background stores the tile index alone in one byte.
  -- The map width therefore follows the caller's background template, which
  -- knows its own type (GfGfxLoader_LoadScrnData loads into a
  -- GF_BG_TYPE_TEXT or GF_BG_TYPE_AFFINE layer): pass entryBytes = 1 for an
  -- affine 256-colour map, and the default two bytes everywhere else.
  local colorMode = reader:u32le(blk.payload + 4) % 16
  local bytesPerEntry = opts.entryBytes == nil and 2 or opts.entryBytes
  if bytesPerEntry ~= 1 and bytesPerEntry ~= 2 then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "SCRN entry width must be one or two bytes", {
      entryBytes = bytesPerEntry,
    })
  end
  local dataSize = reader:u32le(blk.payload + 8)
  if width == 0 or height == 0 or width % 8 ~= 0 or height % 8 ~= 0 then
    Errors.raise(
      G2dDecoder.ERROR.CHUNK_INVALID,
      "SCRN dimensions must be multiples of 8 pixels",
      { width = width, height = height }
    )
  end
  -- The entry bytes must match the tile geometry and colour mode exactly:
  -- metadata describing one geometry while supplying another amount of map
  -- data is malformed.
  local expectedBytes = width / 8 * (height / 8) * bytesPerEntry
  if dataSize ~= expectedBytes then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "SCRN data size does not match the screen dimensions", {
      width = width,
      height = height,
      dataSize = dataSize,
      expectedBytes = expectedBytes,
      bytesPerEntry = bytesPerEntry,
    })
  end
  if 12 + dataSize > blk.size then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "SCRN entry data exceeds the chunk", {
      dataSize = dataSize,
      chunkSize = blk.size,
    })
  end
  -- A 512-pixel-wide text background stores its map as consecutive
  -- 32x32-tile screen blocks, the order the hardware reads VRAM in; decoded
  -- entries are row-major over the whole screen. Narrower maps are already
  -- row-major, and other widths are not hardware block layouts. Screens
  -- retail reads piece-wise through CopyToBgTilemapRect (stride = width/8)
  -- instead of a VRAM upload, such as the pokegear world map, store
  -- row-major: pass layout "linear" to keep the stored order. The blocked
  -- order belongs to the two-byte text form only: a 256-colour map stores one
  -- byte per entry and has no palette bits to split a screen block on.
  local layout = opts.layout or "hardware-blocks"
  assert(
    layout == "hardware-blocks" or layout == "linear",
    "screen layouts are hardware-blocks or linear, got " .. tostring(opts.layout)
  )
  local blocked = bytesPerEntry == 2 and width == 512 and height % 256 == 0 and layout == "hardware-blocks"
  local entries = {}
  local count = math.floor(dataSize / bytesPerEntry)
  for i = 0, count - 1 do
    local position = i
    if blocked then
      local blockIndex, within = math.floor(i / 1024), i % 1024
      local row = math.floor(blockIndex / 2) * 32 + math.floor(within / 32)
      position = row * 64 + (blockIndex % 2) * 32 + within % 32
    end
    if bytesPerEntry == 1 then
      entries[position + 1] = {
        tile = reader:u8(blk.payload + 12 + i),
        flipH = false,
        flipV = false,
        palette = 0,
      }
    else
      local e = reader:u16le(blk.payload + 12 + i * 2)
      entries[position + 1] = {
        tile = e % 1024,
        flipH = math.floor(e / 1024) % 2 == 1,
        flipV = math.floor(e / 2048) % 2 == 1,
        palette = math.floor(e / 4096),
      }
    end
  end
  return { width = width, height = height, entries = entries, colorMode = colorMode }
end

---@param data string
---@param opts? { label?: string, allowRetailTail?: boolean }
---@return { depth: integer, tiles: string }?
---@return Errors.Error?
function G2dDecoder.decodeChar(data, opts)
  assert(type(data) == "string", "G2dDecoder.decodeChar requires a string")
  opts = opts or {}
  local ok, result = pcall(decodeCharBlock, data, opts)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

---@param data string
---@param opts? { label?: string, layout?: string, entryBytes?: integer }
---@return { width: integer, height: integer, entries: table[], colorMode: integer }?
---@return Errors.Error?
function G2dDecoder.decodeScreen(data, opts)
  assert(type(data) == "string", "G2dDecoder.decodeScreen requires a string")
  opts = opts or {}
  local ok, result = pcall(decodeScreenBlock, data, opts)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

-- One RLCN-wrapped TTLP palette (NNS G2D compressed palette container):
-- header, TTLP chunk with its own depth and colour byte count, and an optional
-- PMCP chunk marking a truncated all-transparent palette tail.
local function decodeRlcnPalette(data, opts)
  local reader = BinaryReader.new(data, opts.label or "g2d-palette")
  local size = reader:length()
  if size < 0x10 or reader:ascii(0, 4) ~= "RLCN" then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "palette member lacks the RLCN header", { size = size })
  end
  if reader:u16le(4) ~= 0xFEFF then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "palette RLCN byte order is not 0xFEFF", {
      byteOrder = reader:u16le(4),
    })
  end
  local totalSize = reader:u32le(8)
  if totalSize ~= size then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "palette RLCN declares a different size", {
      declared = totalSize,
      size = size,
    })
  end
  local ttlpOffset = reader:u16le(0x0C)
  local chunkCount = reader:u16le(0x0E)
  if chunkCount < 1 or ttlpOffset + 0x18 > size or reader:ascii(ttlpOffset, 4) ~= "TTLP" then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "palette RLCN has no valid TTLP chunk", {
      ttlpOffset = ttlpOffset,
      size = size,
    })
  end
  local chunkSize = reader:u32le(ttlpOffset + 4)
  local depth = reader:u32le(ttlpOffset + 8)
  local paletteBytes = reader:u32le(ttlpOffset + 0x10)
  local dataOffset = reader:u32le(ttlpOffset + 0x14)
  -- Single-palette RLCN members carry the advisory depth word 0xA0004 with
  -- the same colour layout; retail's NNS loader consumes both forms.
  if depth ~= 3 and depth ~= 4 and depth ~= 0xA0004 then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "palette RLCN depth is not 4bpp, 8bpp or single-palette", {
      depth = depth,
    })
  end
  if chunkCount >= 2 then
    local pcmpOffset = ttlpOffset + chunkSize
    if pcmpOffset + 8 > size or reader:ascii(pcmpOffset, 4) ~= "PMCP" then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "palette RLCN compressed-palette chunk is invalid", {
        pcmpOffset = pcmpOffset,
        size = size,
      })
    end
    local fullPaletteBytes = depth == 3 and 0x200 or depth == 0xA0004 and 0x20 or 0x2000
    if ttlpOffset + 8 + dataOffset + paletteBytes > ttlpOffset + chunkSize then
      if paletteBytes >= fullPaletteBytes then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "compressed palette size exceeds the full palette", {
          paletteBytes = paletteBytes,
          fullPaletteBytes = fullPaletteBytes,
        })
      end
      paletteBytes = fullPaletteBytes - paletteBytes
    end
  end
  local colorsOffset = ttlpOffset + 8 + dataOffset
  if paletteBytes == 0 then
    -- An 8bpp TTLP member stores its whole palette and leaves the advisory
    -- byte count zero; the chunk bounds then carry the real colour count.
    -- Retail's trade-sequence backdrops are the evidenced case: their depth-4
    -- members hold a full 256-colour palette behind a zero byte count.
    if colorsOffset > ttlpOffset + chunkSize then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "palette colour offset exceeds the TTLP chunk", {
        colorsOffset = colorsOffset,
        chunkSize = chunkSize,
      })
    end
    paletteBytes = ttlpOffset + chunkSize - colorsOffset
    if paletteBytes % 2 ~= 0 then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "palette colour bytes are not whole colours", {
        paletteBytes = paletteBytes,
      })
    end
  end
  if dataOffset < 8 or colorsOffset + paletteBytes > ttlpOffset + chunkSize or colorsOffset + paletteBytes > size then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "palette data exceeds the TTLP chunk bounds", {
      colorsOffset = colorsOffset,
      paletteBytes = paletteBytes,
    })
  end
  local colorCount = math.floor(paletteBytes / 2)
  local colors = {}
  for i = 0, colorCount - 1 do
    colors[i + 1] = Rgb555.decode(reader:u16le(colorsOffset + i * 2))
  end
  return { colors = colors }
end

---@param data string
---@param opts? { label?: string }
---@return { colors: { r: integer, g: integer, b: integer }[] }?
---@return Errors.Error?
function G2dDecoder.decodePalette(data, opts)
  assert(type(data) == "string", "G2dDecoder.decodePalette requires a string")
  opts = opts or {}
  if data:sub(1, 4) == "RLCN" then
    -- RLCN-wrapped TTLP palette data (NNS_G2dGetUnpackedPaletteData). The
    -- container is the general Nitro compressed-palette form: an 8-bit or
    -- 4-bit palette of any bank count, whose trailing all-transparent entries
    -- the converter may have truncated. This is not the font's own palette
    -- limit: a BG palette carries sixteen 256-colour banks.
    local ok, pal = pcall(decodeRlcnPalette, data, opts)
    if not ok then
      if Errors.is(pal) then
        return nil, pal
      end
      error(pal)
    end
    return pal
  end
  local function decodePaletteBlock()
    local _, blks, reader = blocks(data, { magics = CONTAINER_MAGICS }, opts.label or "g2d-palette")
    local blk = mustBlock(blks, "PLTT")
    if blk.size < 12 then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "PLTT chunk is shorter than its header", { size = blk.size })
    end
    local depth = string.byte(reader:bytes(blk.payload, 1))
    local colorCount = reader:u16le(blk.payload + 2)
    local dataOffset = reader:u32le(blk.payload + 8)
    if depth ~= 3 and depth ~= 4 then
      Errors.raise(
        G2dDecoder.ERROR.CHUNK_INVALID,
        "PLTT depth " .. depth .. " is not 3 (4bpp) or 4 (8bpp)",
        { depth = depth }
      )
    end
    if colorCount == 0 or dataOffset + colorCount * 2 > blk.size then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "PLTT color data exceeds the chunk", {
        colorCount = colorCount,
        dataOffset = dataOffset,
        chunkSize = blk.size,
      })
    end
    local colors = {}
    for i = 0, colorCount - 1 do
      local word = reader:u16le(blk.payload + dataOffset + i * 2)
      colors[i + 1] = Rgb555.decode(word)
    end
    return { colors = colors }
  end
  local ok, result = pcall(decodePaletteBlock)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

---@param data string
---@param opts? { label?: string }
---@return { cells: { objs: { x: integer, y: integer, tile: integer, flipH: boolean, flipV: boolean, palette: integer, shape: integer, size: integer, width: integer, height: integer, affine: boolean, disabled: boolean, objMode: G2dDecoder.ObjMode, mosaic: boolean, colorMode: G2dDecoder.ColorMode, priority: integer }[] }[] }?
---@return Errors.Error?
function G2dDecoder.decodeCell(data, opts)
  assert(type(data) == "string", "G2dDecoder.decodeCell requires a string")
  opts = opts or {}
  local function decodeCellBlock()
    local _, blks, reader = blocks(data, { magics = CONTAINER_MAGICS }, opts.label or "g2d-cell")
    local blk = mustBlock(blks, "CEBK")
    if blk.size < 0x20 then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "CELL chunk is shorter than its header", { size = blk.size })
    end
    local cellCount = reader:u16le(blk.payload)
    local entrySize = reader:u16le(blk.payload + 2)
    local tableOffset = reader:u32le(blk.payload + 4)
    if entrySize ~= 0 and entrySize ~= 1 then
      Errors.raise(
        G2dDecoder.ERROR.CHUNK_INVALID,
        "CELL entry size " .. entrySize .. " is not 0 (8 bytes) or 1 (16 bytes)",
        { entrySize = entrySize }
      )
    end
    local stride = entrySize == 0 and 8 or 16
    if cellCount == 0 or tableOffset + cellCount * stride > blk.size then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "CELL metatile table exceeds the chunk", {
        cellCount = cellCount,
        tableOffset = tableOffset,
        chunkSize = blk.size,
      })
    end
    local cells = {}
    local attrTable = blk.payload + tableOffset + cellCount * stride
    for c = 0, cellCount - 1 do
      local base = blk.payload + tableOffset + c * stride
      local numObjs = reader:u16le(base)
      local objOffset = reader:u32le(base + 4)
      if attrTable - blk.payload + objOffset + numObjs * 6 > blk.size then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "CELL OBJ table exceeds the chunk", {
          numObjs = numObjs,
          objOffset = objOffset,
          chunkSize = blk.size,
        })
      end
      local objs = {}
      for o = 0, numObjs - 1 do
        local obase = attrTable + objOffset + o * 6
        -- OAM-ordered attributes (GBATEK "OAM (Object Attribute Mapping)"):
        -- attr0 carries y and the shape bits (14-15), attr1 carries x, the
        -- flips (12-13) and the size bits (14-15), attr2 carries the tile
        -- index and the palette bank (12-15).
        local attr0 = reader:u16le(obase)
        local attr1 = reader:u16le(obase + 2)
        local attr2 = reader:u16le(obase + 4)
        local x = attr1 % 512
        if x >= 256 then
          x = x - 512
        end
        local y = attr0 % 256
        if y >= 128 then
          y = y - 256
        end
        local shape = math.floor(attr0 / 16384)
        if shape == 3 then
          Errors.raise(
            G2dDecoder.ERROR.CHUNK_INVALID,
            "CELL OBJ carries the reserved OAM shape bits",
            { attr0 = attr0 }
          )
        end
        local size = math.floor(attr1 / 16384)
        local dims = OBJ_DIMENSIONS[shape + 1][size + 1]
        local affine = math.floor(attr0 / 0x100) % 2 == 1
        local attr0Bit9 = math.floor(attr0 / 0x200) % 2 == 1
        objs[o + 1] = {
          x = x,
          y = y,
          tile = attr2 % 1024,
          flipH = math.floor(attr1 / 4096) % 2 == 1,
          flipV = math.floor(attr1 / 8192) % 2 == 1,
          palette = math.floor(attr2 / 4096),
          shape = shape,
          size = size,
          width = dims[1],
          height = dims[2],
          affine = affine,
          disabled = not affine and attr0Bit9,
          objMode = OBJ_MODE[math.floor(attr0 / 0x400) % 4],
          mosaic = math.floor(attr0 / 0x1000) % 2 == 1,
          colorMode = math.floor(attr0 / 0x2000) % 2 == 1 and "256-color" or "16-color",
          priority = math.floor(attr2 / 0x400) % 4,
        }
      end
      cells[c + 1] = { objs = objs }
    end
    return { cells = cells }
  end
  local ok, result = pcall(decodeCellBlock)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

-- The cell bank's OBJ VRAM mapping mode (GX_OBJVRAMMODE_CHAR_1D_32K..256K, 0..3):
-- OBJ tile indices count in 32 << mapping byte units. Kept out of the decoded
-- cell records, whose shape other producers publish.
---@param data string
---@param opts? { label?: string }
---@return integer?
---@return Errors.Error?
function G2dDecoder.decodeCellMapping(data, opts)
  assert(type(data) == "string", "G2dDecoder.decodeCellMapping requires a string")
  opts = opts or {}
  local function decodeMapping()
    local _, blks, reader = blocks(data, { magics = CONTAINER_MAGICS }, opts.label or "g2d-cell")
    local blk = mustBlock(blks, "CEBK")
    if blk.size < 0x20 then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "CELL chunk is shorter than its header", { size = blk.size })
    end
    local mapping = reader:u32le(blk.payload + 8)
    if mapping > 3 then
      Errors.raise(
        G2dDecoder.ERROR.CHUNK_INVALID,
        "CELL mapping type " .. mapping .. " is unsupported",
        { mapping = mapping }
      )
    end
    return mapping
  end
  local ok, result = pcall(decodeMapping)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

---@param data string
---@param opts? { label?: string }
---@return { anims: { frames: { cell: integer, duration: integer, element: string, translateX: integer, translateY: integer, scaleX: number, scaleY: number, rotation: number, userAttr?: integer }[], playMode: string, loopStartFrameIdx: integer }[] }?
---@return Errors.Error?
function G2dDecoder.decodeAnimation(data, opts)
  assert(type(data) == "string", "G2dDecoder.decodeAnimation requires a string")
  opts = opts or {}
  local function decodeAnimationBlock()
    local _, blks, reader = blocks(data, { magics = CONTAINER_MAGICS }, opts.label or "g2d-animation")
    local blk = mustBlock(blks, "ABNK")
    if blk.size < 0x18 then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM chunk is shorter than its header", { size = blk.size })
    end
    local animCount = reader:u16le(blk.payload)
    local frameCount = reader:u16le(blk.payload + 2)
    local animsOffset = reader:u32le(blk.payload + 4)
    local framesOffset = reader:u32le(blk.payload + 8)
    local dataOffset = reader:u32le(blk.payload + 12)
    if animCount == 0 or animsOffset + animCount * 16 > blk.size then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM animation table exceeds the chunk", {
        animCount = animCount,
        animsOffset = animsOffset,
        chunkSize = blk.size,
      })
    end
    if framesOffset + frameCount * 8 > blk.size then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM frame table exceeds the chunk", {
        frameCount = frameCount,
        framesOffset = framesOffset,
        chunkSize = blk.size,
      })
    end
    local anims = {}
    for a = 0, animCount - 1 do
      local abase = blk.payload + animsOffset + a * 16
      -- NNSG2dAnimSequenceData layout (g2d_Anim_data.h): u16 numFrames,
      -- u16 loopStartFrameIdx, u32 animType, u32 playMode, then the
      -- first-frame pointer.
      local numFrames = reader:u16le(abase)
      local loopStartFrameIdx = reader:u16le(abase + 2)
      local animType = reader:u32le(abase + 4)
      local animationType = animType % 65536
      local cellType = math.floor(animType / 65536) % 65536
      local playModeRaw = reader:u32le(abase + 8)
      local firstFrame = reader:u32le(abase + 12)
      local playMode = PLAY_MODE[playModeRaw]
      if playMode == nil then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM playMode is unsupported", {
          playMode = playModeRaw,
          animation = a,
        })
      end
      if loopStartFrameIdx >= numFrames then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM loop start is outside the animation", {
          loopStartFrameIdx = loopStartFrameIdx,
          numFrames = numFrames,
          animation = a,
        })
      end
      -- Animation element type is authoritative NANR metadata. The decoder must
      -- not infer transform size from frame-data length; it must use this type
      -- to decide how many bytes to read for each frame property.
      if animationType ~= 0 and animationType ~= 1 and animationType ~= 2 then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM animationType is unsupported", {
          animationType = animationType,
          animation = a,
        })
      end
      if cellType ~= 1 and cellType ~= 2 then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM cellType is unsupported", {
          cellType = cellType,
          animation = a,
        })
      end
      -- The HGSS exporter stores this field as a byte offset into the frame
      -- table. Normalize it once at the source-format boundary; treating the
      -- same value as either bytes or an index would make valid resources
      -- decode differently based on the total frame count.
      if firstFrame % 8 ~= 0 then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM first frame offset is not frame-aligned", {
          firstFrame = firstFrame,
          frameCount = frameCount,
        })
      end
      local firstFrameIndex = firstFrame / 8
      -- firstFrame is now a frame index and numFrames a frame count: the
      -- range must fit the frame table total, then its actual byte span must
      -- fit the chunk. Never mix frame indexes with chunk-byte sizes.
      if firstFrameIndex + numFrames > frameCount then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM animation frame range exceeds the frame table", {
          numFrames = numFrames,
          firstFrame = firstFrameIndex,
          frameCount = frameCount,
        })
      end
      if framesOffset + (firstFrameIndex + numFrames) * 8 > blk.size then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM animation frame range exceeds the chunk", {
          numFrames = numFrames,
          firstFrame = firstFrameIndex,
          chunkSize = blk.size,
        })
      end
      local frames = {}
      -- The retail arrow holds its opening cell for zero ticks: a legal
      -- zero duration is preserved, never rewritten. Only a cyclic
      -- sequence that can never advance stays rejected below.
      local totalDuration = 0
      for f = 0, numFrames - 1 do
        local fbase = blk.payload + framesOffset + (firstFrameIndex + f) * 8
        local frameData = reader:u32le(fbase)
        local duration = reader:u16le(fbase + 4)
        totalDuration = totalDuration + duration
        local propBase = blk.payload + dataOffset + frameData
        -- Validate property bounds according to the animation's element type.
        -- The property size is fixed per type: 2 for type 0 (plus dword padding),
        -- 8 for type 2 (translate), 16 for type 1 (SRT). The check must be
        -- type-aware rather than inferring from remaining bytes.
        local element, translateX, translateY, scaleX, scaleY, rotation
        if animationType == 0 then
          if dataOffset + frameData + 2 > blk.size then
            Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM frame data exceeds the chunk", {
              frameData = frameData,
              dataOffset = dataOffset,
              chunkSize = blk.size,
            })
          end
          local cell = reader:u16le(propBase)
          element = "none"
          translateX, translateY = 0, 0
          scaleX, scaleY = 1, 1
          rotation = 0
          frames[f + 1] = {
            cell = cell,
            duration = duration,
            element = element,
            translateX = translateX,
            translateY = translateY,
            scaleX = scaleX,
            scaleY = scaleY,
            rotation = rotation,
          }
        elseif animationType == 2 then
          if dataOffset + frameData + 8 > blk.size then
            Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM frame data exceeds the chunk", {
              frameData = frameData,
              dataOffset = dataOffset,
              chunkSize = blk.size,
            })
          end
          local cell = reader:u16le(propBase)
          local tx = reader:u16le(propBase + 4)
          local ty = reader:u16le(propBase + 6)
          if tx >= 32768 then
            tx = tx - 65536
          end
          if ty >= 32768 then
            ty = ty - 65536
          end
          element = "translate"
          translateX, translateY = tx, ty
          scaleX, scaleY = 1, 1
          rotation = 0
          frames[f + 1] = {
            cell = cell,
            duration = duration,
            element = element,
            translateX = translateX,
            translateY = translateY,
            scaleX = scaleX,
            scaleY = scaleY,
            rotation = rotation,
          }
        else -- animationType == 1 : SRT (scale, rotate, translate)
          if dataOffset + frameData + 16 > blk.size then
            Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM frame data exceeds the chunk", {
              frameData = frameData,
              dataOffset = dataOffset,
              chunkSize = blk.size,
            })
          end
          local cell = reader:u16le(propBase)
          local rotRaw = reader:u16le(propBase + 2)
          local scaleWRaw = reader:u32le(propBase + 4)
          local scaleHRaw = reader:u32le(propBase + 8)
          local tx = reader:u16le(propBase + 12)
          local ty = reader:u16le(propBase + 14)
          if tx >= 32768 then
            tx = tx - 65536
          end
          if ty >= 32768 then
            ty = ty - 65536
          end
          element = "affine"
          translateX, translateY = tx, ty
          scaleX = toScale(scaleWRaw)
          scaleY = toScale(scaleHRaw)
          -- Rotation unit: degrees (0..360) derived from uint16 full turn.
          rotation = rotRaw * 360 / 65536
          if scaleX ~= scaleX or scaleY ~= scaleY or rotation ~= rotation then
            Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM transform contains non-finite value", {
              scaleX = scaleX,
              scaleY = scaleY,
              rotation = rotation,
            })
          end
          frames[f + 1] = {
            cell = cell,
            duration = duration,
            element = element,
            translateX = translateX,
            translateY = translateY,
            scaleX = scaleX,
            scaleY = scaleY,
            rotation = rotation,
          }
        end
      end
      if totalDuration == 0 and (playMode == "forward_loop" or playMode == "reverse_loop") then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM looping sequence can never advance", {
          animation = a,
          playMode = playMode,
        })
      end
      anims[a + 1] = {
        frames = frames,
        animationType = animationType,
        cellType = cellType,
        playMode = playMode,
        loopStartFrameIdx = loopStartFrameIdx,
      }
    end
    decodeUserAnimationAttributes(reader, blk, anims)
    return { anims = anims }
  end
  local ok, result = pcall(decodeAnimationBlock)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

return G2dDecoder
