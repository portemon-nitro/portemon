-- LZ10 (LZSS) decompression as used by Nintendo DS resources: a 4-byte header
-- (0x10 marker plus a 24-bit little-endian output size), then flag bytes whose
-- bits are consumed most-significant first; a clear bit copies one literal
-- byte, a set bit copies a run from the already-decoded output (length = high
-- nibble + 3, displacement = low nibble * 256 + next byte + 1). The DS BIOS
-- LZ77UnCompWram implements the same scheme; GBATEK documents it under "DS
-- Files - LZSS, Yaz0, LZ11 - Decompression". Pure module: no love dependency.

local ffi = require("ffi")
local Errors = require("libs.errors.src.Errors")

local Lz10 = {}

-- Named ownership of the protocol error codes; tests assert the constants,
-- never the raw strings.
Lz10.ERROR = {
  HEADER_INVALID = "LZ10_HEADER_INVALID",
  STREAM_INVALID = "LZ10_STREAM_INVALID",
}

local HEADER_BYTES = 4
local MIN_MATCH_LENGTH = 3

-- Every source read is preceded by a bounds check: a stream that ends in the
-- middle of a token is malformed source, never a raw Lua indexing failure.
-- Offsets here are zero-based positions into the immutable input.
local function requireSource(size, src, count)
  if src + count > size then
    Errors.raise(
      Lz10.ERROR.STREAM_INVALID,
      "LZ10 stream ends in the middle of a token",
      { src = src, needed = count, size = size }
    )
  end
end

local function _decode(bytes)
  if #bytes < HEADER_BYTES or string.byte(bytes, 1) ~= 0x10 then
    Errors.raise(
      Lz10.ERROR.HEADER_INVALID,
      "LZ10 payload lacks the 0x10 header",
      { size = #bytes, first = #bytes >= 1 and string.byte(bytes, 1) or nil }
    )
  end
  -- The owning string stays reachable for the whole pointer use below, so the
  -- borrowed view can never outlive its bytes.
  local size = #bytes
  local input = ffi.cast("const uint8_t *", bytes)
  local outputSize = tonumber(input[1]) + tonumber(input[2]) * 256 + tonumber(input[3]) * 65536
  assert(outputSize == math.floor(outputSize) and outputSize >= 0, "LZ10 size must be a non-negative integer")
  -- The header word assembles three integer-valued bytes, so the validated size is integral.
  ---@cast outputSize integer
  if outputSize == 0 then
    return ""
  end
  local output = ffi.new("uint8_t[?]", outputSize)
  local src = HEADER_BYTES
  local dst = 0
  while dst < outputSize do
    requireSource(size, src, 1)
    local flags = tonumber(input[src])
    src = src + 1
    for bit = 7, 0, -1 do
      if dst >= outputSize then
        break
      end
      if math.floor(flags / 2 ^ bit) % 2 == 0 then
        requireSource(size, src, 1)
        output[dst] = input[src]
        src = src + 1
        dst = dst + 1
      else
        requireSource(size, src, 2)
        local b1 = tonumber(input[src])
        local b2 = tonumber(input[src + 1])
        src = src + 2
        local length = math.floor(b1 / 16) + MIN_MATCH_LENGTH
        local displacement = (b1 % 16) * 256 + b2 + 1
        if displacement > dst then
          Errors.raise(
            Lz10.ERROR.STREAM_INVALID,
            "LZ10 match at output byte " .. dst .. " reaches before the decoded start",
            { dst = dst, displacement = displacement }
          )
        end
        if dst + length > outputSize then
          Errors.raise(
            Lz10.ERROR.STREAM_INVALID,
            "LZ10 match at output byte " .. dst .. " extends past the declared output size",
            { dst = dst, length = length, outputSize = outputSize }
          )
        end
        -- Overlapping runs repeat the pattern, so the copy advances one byte
        -- at a time instead of moving a block.
        for offset = 0, length - 1 do
          output[dst + offset] = output[dst + offset - displacement]
        end
        dst = dst + length
      end
    end
  end
  return ffi.string(output, outputSize)
end

---@param bytes string
---@return string?
---@return Errors.Error?
function Lz10.decode(bytes)
  assert(type(bytes) == "string", "Lz10.decode requires a string")
  local ok, result = pcall(_decode, bytes)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

return Lz10
