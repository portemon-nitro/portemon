-- Persistent scene composition from synthetic members: the terrain bake
-- writes nonzero nibbles through the two differently addressed halves,
-- installs the terrain palette at entries 0x70..0x7f, leaves zero nibbles
-- untouched, and rasters the common screen over the baked tiles. Unknown
-- scene keys and missing members fail precisely without touching the dump.

local Assert = require("tests.support.Assert")

local T = {}

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function container(magic, blocks, declaredSize, blockCount)
  return magic
    .. string.char(0xFF, 0xFE)
    .. u16(0x0100)
    .. u32(declaredSize)
    .. u16(0x10)
    .. u16(blockCount)
    .. table.concat(blocks)
end

local function block(magic, payload)
  return magic:reverse() .. u32(8 + #payload) .. payload
end

local function charBlock(tileBytes, depth)
  local payload = u16(8)
    .. u16(0x20)
    .. u32(depth)
    .. u16(0)
    .. u16(0)
    .. u32(0)
    .. u32(#tileBytes)
    .. u32(0x18)
    .. tileBytes
  local body = block("CHAR", payload)
  return container("RGCN", { body }, 0x10 + #body, 1)
end

local function paletteBlock(words)
  local parts = {}
  for _, word in ipairs(words) do
    parts[#parts + 1] = u16(word)
  end
  local payload = string.char(3, 0) .. u16(#words) .. u32(0) .. u32(12) .. table.concat(parts)
  local body = block("PLTT", payload)
  return container("NCLR", { body }, 0x10 + #body, 1)
end

local function screenBlock(tile, width, height)
  local count = (width / 8) * (height / 8)
  local entries = {}
  for _ = 1, count do
    entries[#entries + 1] = u16(tile)
  end
  local payload = u16(width) .. u16(height) .. u32(0) .. u32(count * 2) .. table.concat(entries)
  local body = block("SCRN", payload)
  return container("RCSN", { body }, 0x10 + #body, 1)
end

-- Base characters: every byte selects palette index 1, so untouched
-- destination bytes rasterize to the base color and every written nibble
-- stands out through the terrain palette.
local function baseChars()
  return charBlock(string.rep("\1", 65536), 4)
end

---@param word integer RGB555 word filling every palette entry
local function paletteWith(word, count)
  local words = {}
  for _ = 1, count do
    words[#words + 1] = word
  end
  return paletteBlock(words)
end

local function setByte(bytes, position, value)
  return bytes:sub(1, position - 1) .. string.char(value) .. bytes:sub(position + 1)
end

---@param overrides table<integer, integer> 0-based byte position to byte value
local function terrainCells(overrides)
  local bytes = string.rep("\0", 4096)
  for position, value in pairs(overrides) do
    bytes = setByte(bytes, position + 1, value)
  end
  return charBlock(bytes, 3)
end

local function romFsWith(members)
  local fs = {}
  function fs:openNarc(alias)
    local archive = {}
    function archive:readMember(memberId)
      local key = alias .. ":" .. memberId
      return members[key]
    end
    return archive
  end
  function fs:version()
    return "soulsilver"
  end
  function fs:metadata()
    return { sha1 = "synthetic-rom-sha" }
  end
  return fs
end

---@param screenTile integer baked tile every screen entry addresses
---@param type0overrides table<integer, integer>
---@param type1overrides table<integer, integer>
local function sceneRomFs(screenTile, type0overrides, type1overrides)
  return romFsWith({
    ["NARC_a_0_0_7:2"] = screenBlock(screenTile, 512, 256),
    ["NARC_a_0_0_7:3"] = baseChars(),
    ["NARC_a_0_0_7:176"] = paletteWith(31, 256),
    ["NARC_a_0_0_8:1"] = paletteWith(31 * 32, 16),
    ["NARC_a_0_0_8:127"] = terrainCells(type0overrides or {}),
    ["NARC_a_0_0_8:130"] = terrainCells(type1overrides or {}),
  })
end

local function compile(romFs, key)
  local Compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  return Compiler.compileScene(romFs, { versionId = "soulsilver" }, key or "general/grass/day")
end

---@param pixels string RGBA buffer, 512 wide
---@return integer, integer, integer, integer pixel bytes
local function pixel(pixels, x, y)
  local base = (y * 512 + x) * 4
  return string.byte(pixels, base + 1), string.byte(pixels, base + 2), string.byte(pixels, base + 3),
    string.byte(pixels, base + 4)
end

local function assertPixel(pixels, x, y, r, g, b, what)
  local pr, pg, pb, pa = pixel(pixels, x, y)
  Assert.equal(pr, r, what .. " red")
  Assert.equal(pg, g, what .. " green")
  Assert.equal(pb, b, what .. " blue")
  Assert.equal(pa, 255, what .. " alpha")
end

-- Any nonzero nibble selects a terrain color (installed at 0x70 plus the
-- nibble); nibble 0 leaves the base byte (palette index 1) alone. The
-- palettes above are uniform, so every written pixel reads terrain green
-- and every untouched pixel reads base red.
local BASE = { 255, 0, 0 }
local TERRAIN = { 0, 255, 0 }

function T.type1_left_chunk_writes_nibbles_and_keeps_zero_transparent()
  -- Destination tile (16, 20) is baked tile 20 * 32 + 16 = 656; its source
  -- is the left chunk at objY * 0x100 + objX * 0x20 + i / 2.
  local scene = assert(compile(sceneRomFs(656, {}, { [0] = 0x01 })))
  Assert.equal(scene.canvasWidth, 512, "the scene keeps its 512-wide canvas")
  Assert.equal(scene.canvasHeight, 256, "the scene keeps its 256-high canvas")
  assertPixel(scene.image, 0, 0, TERRAIN[1], TERRAIN[2], TERRAIN[3], "a nonzero low nibble writes palette 0x71")
  assertPixel(scene.image, 1, 0, BASE[1], BASE[2], BASE[3], "a zero high nibble leaves the base byte")
end

function T.type1_right_chunk_uses_the_additional_source_term()
  -- Destination tile (24, 20) is baked tile 664; objX 8 selects the right
  -- chunk whose source adds the 0x700 term before the tile addressing.
  local scene = assert(compile(sceneRomFs(664, {}, { [0x700] = 0x03, [0] = 0x00 })))
  assertPixel(scene.image, 0, 0, TERRAIN[1], TERRAIN[2], TERRAIN[3], "the right chunk reads past the 0x700 term")
end

function T.type0_first_pixels_land_at_the_documented_offset()
  -- The first 0x800 unpacked pixels start at byte 0x9800: baked tile 608.
  local scene = assert(compile(sceneRomFs(608, { [0] = 0x05 }, {})))
  assertPixel(scene.image, 0, 0, TERRAIN[1], TERRAIN[2], TERRAIN[3], "the first type-0 byte writes palette 0x75")
  assertPixel(scene.image, 1, 0, BASE[1], BASE[2], BASE[3], "a zero high nibble leaves the base byte")
end

function T.type0_remainder_groups_address_their_own_blocks()
  -- Destination tile (0, 28) is baked tile 896, reading group 0 at 0x400;
  -- tile (8, 28) is baked tile 904, reading group 1 at 0x800.
  local first = assert(compile(sceneRomFs(896, { [0x400] = 0x07 }, {})))
  assertPixel(first.image, 0, 0, TERRAIN[1], TERRAIN[2], TERRAIN[3], "remainder group zero reads at 0x400")
  local second = assert(compile(sceneRomFs(904, { [0x800] = 0x09 }, {})))
  assertPixel(second.image, 0, 0, TERRAIN[1], TERRAIN[2], TERRAIN[3], "remainder group one reads at 0x800")
end

function T.unknown_scene_keys_and_missing_members_fail_precisely()
  local scene, err = compile(sceneRomFs(656, {}, {}), "effect/flash/day")
  Assert.isNil(scene, "an effect background never compiles as a scene")
  Assert.notNil(err, "the rejected effect background explains itself")
  local badTime, badTimeErr = compile(sceneRomFs(656, {}, {}), "general/grass/dawn")
  Assert.isNil(badTime, "an unknown time never compiles")
  Assert.notNil(badTimeErr, "the rejected time explains itself")
  local fs = romFsWith({})
  local missing, missingErr = compile(fs)
  Assert.isNil(missing, "a missing source member never compiles")
  Assert.notNil(missingErr, "the missing member explains itself")
end

return { tests = T }
