-- Nintendo DS backwards-LZ overlay decompression.

local Assert = require("tests.support.Assert")
local OverlayCompression = require("libs.nds.src.rom.OverlayCompression")

local T = {}

-- OverlayCompression.decode returns its error unannotated, so err arrives
-- typed as the payload; cast to the Errors.Error contract the test has
-- already verified.
---@param e any
---@return { code: string }
local function asError(e)
  return e
end

local function u8(v)
  return string.char(v % 256)
end
local function u32(v)
  return u8(v) .. u8(math.floor(v / 256)) .. u8(math.floor(v / 65536)) .. u8(math.floor(v / 16777216))
end

function T.decodes_literals_and_backward_match()
  -- Decodes three trailing A literals, then a 13-byte distance-3 match.
  local packed = u8(0) .. u8(0xA0) .. "AAA" .. u8(0x10) .. u32(0x0800000E) .. u32(2)
  Assert.equal(OverlayCompression.decode(packed, 16), string.rep("A", 16))
end

-- Leading bytes outside the packed region pass through untouched while the
-- trailing backwards stream still decodes in reverse order.
function T.preserves_the_raw_prefix_before_the_packed_tail()
  local tail = u8(0) .. u8(0xA0) .. "AAA" .. u8(0x10) .. u32(0x0800000E) .. u32(2)
  Assert.equal(OverlayCompression.decode("XY" .. tail, 18), "XY" .. string.rep("A", 16))
end

-- A flag bit promising a literal with no source byte behind it is malformed
-- source, never a raw indexing failure.
function T.rejects_truncated_literals()
  local packed = u8(0x00) .. u32(0x08000009) .. u32(1)
  local bytes, err = OverlayCompression.decode(packed)
  Assert.isNil(bytes)
  Assert.equal(asError(err).code, "OVERLAY_COMPRESSION_STREAM_INVALID")
end

-- A backwards match that reads past the already-decoded bytes (or the raw
-- prefix) never writes out of bounds.
function T.rejects_out_of_bounds_backward_matches()
  local packed = u8(0xFF) .. u8(0xFF) .. "AAA" .. u8(0x10) .. u32(0x0800000E) .. u32(2)
  local bytes, err = OverlayCompression.decode(packed, 16)
  Assert.isNil(bytes)
  Assert.equal(asError(err).code, "OVERLAY_COMPRESSION_STREAM_INVALID")
end

-- A stream that runs out of source bytes before the declared output is
-- complete is malformed source even though every token parsed cleanly.
function T.rejects_streams_ending_before_the_declared_output()
  local packed = u8(0) .. u8(0xA0) .. "AAA" .. u8(0x10) .. u32(0x0800000E) .. u32(5)
  local bytes, err = OverlayCompression.decode(packed)
  Assert.isNil(bytes)
  Assert.equal(asError(err).code, "OVERLAY_COMPRESSION_STREAM_INVALID")
end

function T.rejects_expected_size_mismatch()
  local packed = u8(0) .. u8(0xA0) .. "AAA" .. u8(0x10) .. u32(0x0800000E) .. u32(2)
  local bytes, err = OverlayCompression.decode(packed, 17)
  Assert.isNil(bytes)
  Assert.equal(asError(err).code, "OVERLAY_COMPRESSION_SIZE_MISMATCH")
end

return { tests = T }
