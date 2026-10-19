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

function T.rejects_truncated_backreferences_as_stream_errors()
  local bytes = string.char(0x11, 4, 0, 0, 0x80, 0x10)
  local decoded, err = Lz11.decode(bytes)
  Assert.isNil(decoded)
  Assert.equal(assert(err).code, Lz11.ERROR.STREAM_INVALID)
end

return { tests = T }
