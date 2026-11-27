-- Independent synthetic Nintendo DS static-banner fixtures and a test-side
-- pixel oracle. Layout follows GBATEK's cartridge header and icon/title format:
-- a 512-byte 4bpp bitmap at banner+0x20 and 16 BGR555 colors at banner+0x220.

local NdsBuilder = require("tests.support.NdsBuilder")

local BannerIconFixture = {}

BannerIconFixture.SIZE = 0x240
BannerIconFixture.BITMAP_OFFSET = 0x20
BannerIconFixture.PALETTE_OFFSET = 0x220

local function u16le(value)
  return string.char(value % 0x100, math.floor(value / 0x100) % 0x100)
end

local function u32le(value)
  return string.char(
    value % 0x100,
    math.floor(value / 0x100) % 0x100,
    math.floor(value / 0x10000) % 0x100,
    math.floor(value / 0x1000000) % 0x100
  )
end

local function bgr555(red, green, blue, unusedBit)
  assert(red >= 0 and red <= 31 and green >= 0 and green <= 31 and blue >= 0 and blue <= 31)
  return red + green * 0x20 + blue * 0x400 + (unusedBit and 0x8000 or 0)
end

function BannerIconFixture.palette()
  local colors = {}
  for index = 0, 15 do
    colors[index] = bgr555(index, (index * 7) % 32, (index * 13) % 32, index == 15)
  end
  colors[0] = bgr555(31, 0, 31)
  colors[1] = bgr555(31, 0, 0)
  colors[2] = bgr555(0, 31, 0)
  colors[3] = bgr555(0, 0, 31)
  colors[4] = bgr555(1, 2, 3)
  colors[15] = bgr555(31, 31, 31, true)
  local bytes = {}
  for index = 0, 15 do
    bytes[#bytes + 1] = u16le(colors[index])
  end
  return table.concat(bytes), colors
end

local function indexGrid()
  local rows = {}
  for y = 0, 31 do
    local row = {}
    for x = 0, 31 do
      row[x + 1] = math.floor(y / 8) * 4 + math.floor(x / 8)
    end
    rows[y + 1] = row
  end
  local function put(x, y, index)
    rows[y + 1][x + 1] = index
  end
  put(0, 0, 4)
  put(1, 0, 5)
  put(7, 7, 15)
  put(8, 7, 1)
  put(7, 8, 2)
  put(8, 8, 3)
  put(31, 0, 15)
  put(0, 31, 1)
  put(31, 31, 15)
  return rows
end

local function encodeBitmap(rows)
  local tiles = {}
  for tileY = 0, 3 do
    for tileX = 0, 3 do
      local tile = {}
      for row = 0, 7 do
        local bytes = {}
        for pair = 0, 3 do
          local x = tileX * 8 + pair * 2
          local y = tileY * 8 + row
          local left = rows[y + 1][x + 1]
          local right = rows[y + 1][x + 2]
          bytes[#bytes + 1] = string.char(left + right * 16)
        end
        tile[#tile + 1] = table.concat(bytes)
      end
      tiles[#tiles + 1] = table.concat(tile)
    end
  end
  return table.concat(tiles)
end

local function expectedRgba(rows, colors)
  local rgba = {}
  for y = 0, 31 do
    for x = 0, 31 do
      local index = rows[y + 1][x + 1]
      if index == 0 then
        rgba[#rgba + 1] = string.char(0, 0, 0, 0)
      else
        local color = colors[index]
        local red = color % 0x20
        local green = math.floor(color / 0x20) % 0x20
        local blue = math.floor(color / 0x400) % 0x20
        rgba[#rgba + 1] = string.char(
          red * 8 + math.floor(red / 4),
          green * 8 + math.floor(green / 4),
          blue * 8 + math.floor(blue / 4),
          255
        )
      end
    end
  end
  return table.concat(rgba)
end

local function bannerBlock(rows, colors)
  local parts = { string.rep("\0", BannerIconFixture.BITMAP_OFFSET) }
  parts[#parts + 1] = encodeBitmap(rows)
  parts[#parts + 1] = string.rep("\0", BannerIconFixture.PALETTE_OFFSET - 0x20 - 512)
  for index = 0, 15 do
    parts[#parts + 1] = u16le(colors[index])
  end
  local block = table.concat(parts)
  assert(#block == BannerIconFixture.SIZE, "synthetic banner block has the wrong size")
  return block
end

function BannerIconFixture.staticBanner()
  local rows = indexGrid()
  local paletteBytes, colors = BannerIconFixture.palette()
  local block = bannerBlock(rows, colors)
  return {
    block = block,
    rgba = expectedRgba(rows, colors),
    paletteBytes = paletteBytes,
    rows = rows,
    colors = colors,
  }
end

function BannerIconFixture.transparentBanner()
  local rows = {}
  for y = 0, 31 do
    rows[y + 1] = {}
    for x = 0, 31 do
      rows[y + 1][x + 1] = 0
    end
  end
  local paletteBytes, colors = BannerIconFixture.palette()
  return {
    block = bannerBlock(rows, colors),
    rgba = expectedRgba(rows, colors),
    paletteBytes = paletteBytes,
    rows = rows,
    colors = colors,
  }
end

function BannerIconFixture.spec(gameCode, banner, token)
  return {
    gameCode = gameCode or "IPKE",
    title = token or "BANNERTEST",
    overlays9 = { "OVERLAY0-" .. (token or "BANNERTEST") },
    unmapped = { "UNMAPPED-" .. (token or "BANNERTEST") },
    banner = banner,
  }
end

function BannerIconFixture.build(gameCode, banner, token)
  return NdsBuilder.build(BannerIconFixture.spec(gameCode, banner, token))
end

local function readExact(romBytes, offset, length)
  assert(offset >= 0 and length >= 0 and offset + length <= #romBytes, "banner oracle read is outside the fixture")
  return romBytes:sub(offset + 1, offset + length)
end

local function readU16le(bytes, offset)
  local low, high = bytes:byte(offset + 1, offset + 2)
  return low + high * 0x100
end

-- Test-only independent oracle for real private sources. It reads documented
-- physical offsets directly and never imports the production decoder.
function BannerIconFixture.expectedRgbaFromRom(romBytes)
  local bannerOffsetBytes = readExact(romBytes, 0x68, 4)
  local bannerOffset = 0
  for index = 1, 4 do
    bannerOffset = bannerOffset + bannerOffsetBytes:byte(index) * 256 ^ (index - 1)
  end
  assert(bannerOffset ~= 0, "the private source has no static banner")
  local bitmap = readExact(romBytes, bannerOffset + BannerIconFixture.BITMAP_OFFSET, 512)
  local palette = readExact(romBytes, bannerOffset + BannerIconFixture.PALETTE_OFFSET, 32)
  local rgba = {}
  for y = 0, 31 do
    for x = 0, 31 do
      local tile = math.floor(y / 8) * 4 + math.floor(x / 8)
      local byteIndex = tile * 32 + (y % 8) * 4 + math.floor((x % 8) / 2)
      local packed = bitmap:byte(byteIndex + 1)
      local index = x % 2 == 0 and packed % 16 or math.floor(packed / 16)
      if index == 0 then
        rgba[#rgba + 1] = string.char(0, 0, 0, 0)
      else
        local color = readU16le(palette, index * 2)
        local red = color % 0x20
        local green = math.floor(color / 0x20) % 0x20
        local blue = math.floor(color / 0x400) % 0x20
        rgba[#rgba + 1] = string.char(
          red * 8 + math.floor(red / 4),
          green * 8 + math.floor(green / 4),
          blue * 8 + math.floor(blue / 4),
          255
        )
      end
    end
  end
  return table.concat(rgba)
end

function BannerIconFixture.withBannerOffset(romBytes, bannerOffset)
  return romBytes:sub(1, 0x68) .. u32le(bannerOffset) .. romBytes:sub(0x68 + 5)
end

return BannerIconFixture
