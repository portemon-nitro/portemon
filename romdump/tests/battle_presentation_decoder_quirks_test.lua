-- Retail container compatibility for battle presentation sources: the
-- background tile family whose container declares sixteen bytes past its
-- complete CHAR block, and animation sequences whose opening frame holds
-- for zero ticks. Fixtures are hand-built from the GBATEK "Nitro Character
-- Tiles / OBJ Animations" layouts. Default decoding stays strict: short,
-- duplicated, or over-declared resources keep failing, and only the exact
-- complete-CHAR envelope decodes through the explicit producer option.

local Assert = require("tests.support.Assert")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")

local T = {}

---@param v integer
---@return string
local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

---@param v integer
---@return string
local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

---@param magic string four raw container bytes, e.g. "RGCN"
---@param blocks string[] encoded blocks
---@param declaredSize integer size written into the 16-byte file header
---@param blockCount integer block count written into the 16-byte file header
---@return string
local function container(magic, blocks, declaredSize, blockCount)
  return magic
    .. string.char(0xFF, 0xFE)
    .. u16(0x0100)
    .. u32(declaredSize)
    .. u16(0x10)
    .. u16(blockCount)
    .. table.concat(blocks)
end

---@param magic string four-character chunk name, e.g. "CHAR"
---@param payload string chunk payload without the 8-byte block header
---@return string
local function block(magic, payload)
  return magic:reverse() .. u32(8 + #payload) .. payload
end

---@param tileBytes string raw tile payload
---@param depth integer 3 for 4bpp, 4 for 8bpp
---@param tileByteCount integer tile region size written into the CHAR header
---@return string
local function charBlock(tileBytes, depth, tileByteCount)
  local payload = u16(8)
    .. u16(0x20)
    .. u32(depth)
    .. u16(0)
    .. u16(0)
    .. u32(0)
    .. u32(tileByteCount)
    .. u32(0x18)
    .. tileBytes
  return block("CHAR", payload)
end

-- The evidenced retail background shape: a complete 65568-byte CHAR block
-- carrying a full 65536-byte 8bpp tile region, inside a 65584-byte file
-- whose header declares 65600 bytes across two blocks while only the CHAR
-- block is present.
---@return string resource, integer actualSize
local function completeBackgroundResource()
  local tiles = string.rep("\2", 65536)
  local resource = container("RGCN", { charBlock(tiles, 4, #tiles) }, 65600, 2)
  assert(#resource == 65584, "the retail background envelope is 65584 bytes")
  return resource, #resource
end

---@param frames { cell: integer, duration: integer }[]
---@param playMode integer raw NNSG2dAnimationPlayMode value
---@return string
local function animBlock(frames, playMode)
  local header = u16(1)
    .. u16(#frames)
    .. u32(0x18)
    .. u32(0x18 + 16)
    .. u32(0x18 + 16 + 8 * #frames)
    .. string.rep("\0", 8)
  local entry = u32(#frames) .. u16(0) .. u16(1) .. u32(playMode) .. u32(0)
  local frameBlocks, frameData = {}, {}
  for i, frame in ipairs(frames) do
    frameBlocks[#frameBlocks + 1] = u32((i - 1) * 2) .. u16(frame.duration) .. u16(0)
    frameData[#frameData + 1] = u16(frame.cell)
  end
  return block("ABNK", header .. entry .. table.concat(frameBlocks) .. table.concat(frameData))
end

---@param frames { cell: integer, duration: integer }[]
---@param playMode integer raw NNSG2dAnimationPlayMode value
---@return string
local function animationResource(frames, playMode)
  local body = animBlock(frames, playMode)
  return container("RNAN", { body }, 0x10 + #body, 1)
end

function T.complete_background_tiles_decode_only_through_the_retail_tail_option()
  local resource = completeBackgroundResource()
  local decoded = assert(
    G2dDecoder.decodeChar(resource, { label = "retail-background", allowRetailTail = true }),
    "the complete retail background tiles must decode through the producer option"
  )
  Assert.equal(decoded.depth, 4, "the retail background tiles stay 8bpp")
  Assert.equal(#decoded.tiles, 65536, "the retail background keeps its full 1024-tile region")
  Assert.equal(math.floor(#decoded.tiles / 64), 1024, "the tile region is an exact tile multiple")
end

function T.retail_tail_option_keeps_default_decoding_strict()
  local resource = completeBackgroundResource()
  local out, err = G2dDecoder.decodeChar(resource, { label = "retail-background" })
  Assert.isNil(out, "the default caller must still reject the over-declared envelope")
  Assert.equal(assert(err).code, G2dDecoder.ERROR.TRUNCATED, "the default rejection stays a truncation error")
end

function T.damaged_or_mismatched_envelopes_stay_rejected()
  local resource = completeBackgroundResource()
  local function rejects(bytes, label)
    local out, err = G2dDecoder.decodeChar(bytes, { label = label, allowRetailTail = true })
    Assert.isNil(out, label .. " must stay rejected even with the producer option")
    Assert.notNil(err, label .. " must explain its rejection")
  end
  rejects(resource:sub(1, #resource - 1), "a background missing one CHAR tile byte")
  local oversized = container("RGCN", { charBlock(string.rep("\2", 65536), 4, 65536) }, #resource + 32, 2)
  rejects(oversized, "a declared size overshooting by anything but sixteen bytes")
  local badExtent = container("RGCN", { charBlock(string.rep("\2", 65536), 4, 65536 + 64) }, 65600, 2)
  rejects(badExtent, "a tile extent reaching past the complete CHAR block")
  local tiles = string.rep("\2", 64)
  local duplicated =
    container("RGCN", { charBlock(tiles, 4, #tiles), charBlock(tiles, 4, #tiles) }, 0x10 + 2 * (8 + 24 + 64), 2)
  local dupOut, dupErr = G2dDecoder.decodeChar(duplicated, { label = "duplicated-char", allowRetailTail = true })
  Assert.isNil(dupOut, "duplicate CHAR chunks stay rejected")
  Assert.equal(assert(dupErr).code, G2dDecoder.ERROR.CHUNK_DUPLICATE, "the duplicate rejection keeps its code")
end

function T.leading_zero_duration_frames_keep_their_cells_and_durations()
  local frames = {
    { cell = 0, duration = 0 },
    { cell = 1, duration = 4 },
    { cell = 2, duration = 4 },
    { cell = 3, duration = 4 },
    { cell = 4, duration = 16 },
    { cell = 5, duration = 6 },
  }
  local decoded = assert(
    G2dDecoder.decodeAnimation(animationResource(frames, 2), { label = "retail-arrow" }),
    "the six-cell arrow sequence with a zero opening frame must decode"
  )
  Assert.equal(#decoded.anims, 1, "the resource carries one animation")
  local sequence = decoded.anims[1]
  Assert.equal(sequence.playMode, "forward_loop", "the loop mode survives decoding")
  Assert.equal(#sequence.frames, 6, "no cell is dropped, including cell zero")
  local expected = { 0, 4, 4, 4, 16, 6 }
  for index, frame in ipairs(sequence.frames) do
    Assert.equal(frame.cell, index - 1, "cell order is preserved at frame " .. index)
    Assert.equal(frame.duration, expected[index], "the authored duration is preserved at frame " .. index)
  end
end

function T.positive_duration_sequences_decode_unchanged()
  local frames = {
    { cell = 0, duration = 6 },
    { cell = 1, duration = 6 },
  }
  local decoded = assert(
    G2dDecoder.decodeAnimation(animationResource(frames, 1), { label = "positive-durations" }),
    "ordinary positive-duration sequences keep decoding"
  )
  Assert.equal(#decoded.anims[1].frames, 2, "both frames survive")
  Assert.equal(decoded.anims[1].frames[1].duration, 6, "the first duration is intact")
  Assert.equal(decoded.anims[1].frames[2].duration, 6, "the second duration is intact")
  Assert.equal(decoded.anims[1].playMode, "forward", "the play mode is intact")
end

function T.looping_sequences_with_no_advanceable_frame_stay_rejected()
  local frames = {
    { cell = 0, duration = 0 },
    { cell = 1, duration = 0 },
    { cell = 2, duration = 0 },
  }
  local out, err =
    G2dDecoder.decodeAnimation(animationResource(frames, 2), { label = "zero-total-loop", allowRetailTail = true })
  Assert.isNil(out, "a looping sequence that can never advance stays rejected")
  Assert.equal(assert(err).code, G2dDecoder.ERROR.CHUNK_INVALID, "the zero-total rejection keeps its code")
end

function T.truncated_palette_blocks_stay_rejected()
  local colors = {}
  for _ = 1, 15 do
    colors[#colors + 1] = u16(0x7FFF)
  end
  local payload = string.char(3, 0) .. u16(16) .. u32(0) .. u32(12) .. table.concat(colors)
  local resource = container("RLCN", { block("PLTT", payload) }, 0x10 + 8 + #payload, 1)
  local out, err = G2dDecoder.decodePalette(resource, { label = "short-palette", allowRetailTail = true })
  Assert.isNil(out, "a palette missing one color stays rejected")
  Assert.notNil(err, "the short palette explains its rejection")
end

return { tests = T }
