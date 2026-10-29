-- LZ11 member decompression, including overlapping references and extended sizes.

local Assert = require("tests.support.Assert")
local Lz11 = require("romdump.src.digest.Lz11")

local T = {}

function T.decompresses_literals_and_overlapping_backreferences()
  local bytes = string.char(0x11, 6, 0, 0, 0x20, 65, 66, 0x30, 1)
  Assert.equal(assert(Lz11.decode(bytes)), "ABABAB")
end

function T.decompresses_extended_length_backreferences()
  local payload = string.rep("Q", 18)
  local bytes = string.char(0x11, 0, 0, 0, 18, 0, 0, 0, 0x40, 81, 0x00, 0x00, 0x00)
  Assert.equal(assert(Lz11.decode(bytes)), payload)
end

-- The second match encoding carries a 12-bit length and a 12-bit
-- displacement across four token bytes; a long overlapping run using it must
-- land exactly on the declared output size.
function T.decompresses_four_byte_token_backreferences()
  local size = 275
  local header = string.char(0x11, size % 256, math.floor(size / 256) % 256, math.floor(size / 65536) % 256)
  local bytes = header .. string.char(0x20, 65, 66, 0x10, 0x00, 0x00, 0x01)
  Assert.equal(assert(Lz11.decode(bytes)), string.rep("AB", 138):sub(1, size))
end

-- A displacement of one repeats the previous byte; the decoder must copy
-- forward one byte at a time and stop exactly at the declared size.
function T.decompresses_distance_one_overlapping_runs()
  local bytes = string.char(0x11, 6, 0, 0, 0x40, 65, 0x40, 0x00)
  Assert.equal(assert(Lz11.decode(bytes)), string.rep("A", 6))
end

function T.rejects_matches_reaching_before_the_decoded_start()
  local bytes = string.char(0x11, 4, 0, 0, 0x80, 0x20, 0x00)
  local decoded, err = Lz11.decode(bytes)
  Assert.isNil(decoded)
  Assert.equal(assert(err).code, Lz11.ERROR.STREAM_INVALID)
end

function T.rejects_matches_extending_beyond_the_declared_size()
  local bytes = string.char(0x11, 4, 0, 0, 0x20, 65, 66, 0x40, 0x01)
  local decoded, err = Lz11.decode(bytes)
  Assert.isNil(decoded)
  Assert.equal(assert(err).code, Lz11.ERROR.STREAM_INVALID)
end

function T.rejects_truncated_backreferences_as_stream_errors()
  local bytes = string.char(0x11, 4, 0, 0, 0x80, 0x10)
  local decoded, err = Lz11.decode(bytes)
  Assert.isNil(decoded)
  Assert.equal(assert(err).code, Lz11.ERROR.STREAM_INVALID)
end

return { tests = T }
