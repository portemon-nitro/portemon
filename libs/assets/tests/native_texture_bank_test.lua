-- The engine-owned native texture bank keeps one source texture pack's named
-- texels and named palettes together, exactly as the source grouped them:
-- a visible material resolves a texture name and a palette name independently
-- against the bank, so one indexed texture serves several palettes without a
-- separate expanded image per pairing. These scenarios pin the published
-- contract (named lookup, byte-exact texel and palette payloads including the
-- 4x4 compressed index region, direct-colour textures without a palette) and
-- the loud rejection of malformed banks.

local Assert = require("tests.support.Assert")

local T = {}

local BANK_MODULE = "libs.assets.src.model.NativeTextureBank"

-- The bank format under test, required lazily so a missing format reports the
-- missing behavior instead of a load error.
local function nativeBank()
  local ok, mod = pcall(require, BANK_MODULE)
  Assert.isTrue(
    ok and type(mod) == "table",
    "the native texture bank format is missing: a source texture pack must persist "
      .. "one named bank of compact texels and palettes instead of one expanded image per material pairing"
  )
  Assert.equal(type(mod.encode), "function", "the native texture bank format must expose encode(record)")
  Assert.equal(type(mod.read), "function", "the native texture bank format must expose read(bytes)")
  return mod --[[@as table]]
end

-- Published bytes cross as a string or as love Data; both satisfy the reader.
---@param value unknown
---@return string
local function rawBytes(value)
  if type(value) == "string" then
    return value
  end
  Assert.equal(type(value), "userdata", "the texture bank is published as bytes")
  ---@cast value love.Data
  return value:getString()
end

local INDEXED_TEXELS = string.rep(string.char(0x11), 32) -- 8x8 palette16: 32 bytes
local DIRECT_TEXELS = string.rep(string.char(0x1F, 0x00), 64) -- 8x8 direct colour: 128 bytes
local COMPRESSED_TEXELS = string.rep(string.char(0x22), 16) -- 8x8 compressed 4x4 blocks
local COMPRESSED_INDEX = string.rep(string.char(0x21, 0x00), 8) -- one u16 control word per block
local PALETTE_ONE = string.rep(string.char(0x1F, 0x00), 16) -- 16 BGR555 colours, red
local PALETTE_TWO = string.rep(string.char(0xE0, 0x03), 16) -- 16 BGR555 colours, green

local function record()
  return {
    textures = {
      {
        name = "flower01",
        formatRaw = 3,
        width = 8,
        height = 8,
        color0Transparent = true,
        texels = INDEXED_TEXELS,
      },
      {
        name = "sky",
        formatRaw = 7,
        width = 8,
        height = 8,
        color0Transparent = false,
        texels = DIRECT_TEXELS,
      },
      {
        name = "cloud",
        formatRaw = 5,
        width = 8,
        height = 8,
        color0Transparent = true,
        texels = COMPRESSED_TEXELS,
        indexData = COMPRESSED_INDEX,
      },
    },
    palettes = {
      { name = "map_pal", data = PALETTE_ONE },
      { name = "dusk_pal", data = PALETTE_TWO },
    },
  }
end

function T.named_texels_and_palettes_resolve_independently()
  local Bank = nativeBank()
  local encoded = rawBytes(Bank.encode(record()))

  Assert.equal(encoded:sub(1, 4), "G4TX", "the published bank carries its own magic")
  Assert.isNil(encoded:find("map_textures", 1, true), "a published bank carries no source archive identity")

  local bank, err = Bank.read(encoded)
  Assert.isNil(err, "a well-formed bank reads without error")
  Assert.notNil(bank, "a well-formed bank yields a reader")
  Assert.equal(bank.textureCount, 3, "one bank keeps every texture of its source pack")
  Assert.equal(bank.paletteCount, 2, "one bank keeps every palette of its source pack")

  local indexed = assert(bank:texture("flower01"), "textures resolve by their source name")
  Assert.equal(rawBytes(indexed.texels), INDEXED_TEXELS, "indexed texels are preserved byte for byte")
  Assert.equal(indexed.formatRaw, 3, "the texture record keeps its DS texture format")
  Assert.equal(indexed.width, 8, "the texture record keeps its width")
  Assert.equal(indexed.height, 8, "the texture record keeps its height")
  Assert.isTrue(indexed.color0Transparent, "the texture record keeps colour-0 transparency")

  local direct = assert(bank:texture("sky"), "direct-colour textures live in the same bank")
  Assert.equal(rawBytes(direct.texels), DIRECT_TEXELS, "direct-colour texels are preserved byte for byte")
  Assert.equal(direct.formatRaw, 7, "a direct-colour texture needs no palette record")

  local compressed = assert(bank:texture("cloud"), "compressed textures live in the same bank")
  Assert.equal(rawBytes(compressed.texels), COMPRESSED_TEXELS, "compressed texels are preserved byte for byte")
  Assert.equal(rawBytes(compressed.indexData), COMPRESSED_INDEX, "the 4x4 index region is preserved")

  local first = assert(bank:palette("map_pal"), "palettes resolve by their source name")
  local second = assert(bank:palette("dusk_pal"), "palettes resolve by their source name")
  Assert.equal(rawBytes(first.data), PALETTE_ONE, "a palette is preserved byte for byte")
  Assert.equal(rawBytes(second.data), PALETTE_TWO, "a palette is preserved byte for byte")
  Assert.equal(first.data ~= second.data, true, "the two palettes stay distinct records of one bank")
  Assert.isNil(bank:texture("missing"), "an unknown texture name resolves nothing")
  Assert.isNil(bank:palette("missing"), "an unknown palette name resolves nothing")

  -- No expanded image copy is persisted: the bank stays far below one RGBA
  -- copy per texture, which is what the deleted per-pair images would cost.
  local rgbaCost = 3 * 8 * 8 * 4
  Assert.isTrue(
    #encoded < rgbaCost,
    "the bank stores compact source texels, not expanded RGBA copies: " .. #encoded .. " bytes"
  )
end

---@param Bank table
---@param value table
---@param label string
local function assertRejected(Bank, value, label)
  local ok, encoded = pcall(Bank.encode, value)
  Assert.isTrue(not ok or encoded == nil, "a malformed texture bank is rejected: " .. label)
end

function T.malformed_banks_and_duplicate_names_are_rejected()
  local Bank = nativeBank()

  local duplicates = record()
  duplicates.textures[2].name = duplicates.textures[1].name
  assertRejected(Bank, duplicates, "two textures share one name")

  local palettesClash = record()
  palettesClash.palettes[2].name = palettesClash.palettes[1].name
  assertRejected(Bank, palettesClash, "two palettes share one name")

  local valid = rawBytes(Bank.encode(record()))
  local okVersion, bankVersion = pcall(Bank.read, valid:sub(1, 4) .. string.char(9, 0) .. valid:sub(7))
  Assert.isTrue(not okVersion or bankVersion == nil, "an unsupported bank version is rejected")
  local okTruncated, bankTruncated = pcall(Bank.read, valid:sub(1, #valid - 8))
  Assert.isTrue(not okTruncated or bankTruncated == nil, "a truncated bank is rejected")
end

return { tests = T }
