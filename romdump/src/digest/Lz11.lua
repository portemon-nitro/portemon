-- LZ11 decompression for compressed Nintendo DS NARC members.

local ffi = require("ffi")
local Errors = require("libs.errors.src.Errors")

local Lz11 = {}
Lz11.ERROR = {
  HEADER_INVALID = "LZ11_HEADER_INVALID",
  STREAM_INVALID = "LZ11_STREAM_INVALID",
}

local HEADER_BYTES = 4

-- Offsets here are zero-based positions into the immutable input.
local function requireSource(size, src, count)
  if src + count > size then
    Errors.raise(Lz11.ERROR.STREAM_INVALID, "LZ11 stream ends in the middle of a token", {
      src = src,
      needed = count,
      size = size,
    })
  end
end

---@param input ffi.cdata*
---@param size integer
---@return integer outputSize
---@return integer src zero-based offset of the first flag byte
local function decodeSize(input, size)
  -- Each input byte is an integer-valued uint8, so the assembled words below are integral.
  local declared = tonumber(input[1]) + tonumber(input[2]) * 256 + tonumber(input[3]) * 65536
  ---@cast declared integer
  if declared ~= 0 then
    return declared, HEADER_BYTES
  end
  requireSource(size, 4, 4)
  local b1, b2, b3, b4 = tonumber(input[4]), tonumber(input[5]), tonumber(input[6]), tonumber(input[7])
  local extended = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
  ---@cast extended integer
  if extended == 0 then
    Errors.raise(Lz11.ERROR.HEADER_INVALID, "LZ11 stream declares an empty output", { size = extended })
  end
  return extended, 8
end

local function decode(input, size, outputSize, src)
  local output = ffi.new("uint8_t[?]", outputSize)
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
        requireSource(size, src, 1)
        local first = tonumber(input[src])
        local prefix = math.floor(first / 16)
        local length, displacement
        if prefix == 0 then
          requireSource(size, src + 1, 2)
          local second, third = tonumber(input[src + 1]), tonumber(input[src + 2])
          length = (first % 16) * 16 + math.floor(second / 16) + 0x11
          displacement = (second % 16) * 256 + third + 1
          src = src + 3
        elseif prefix == 1 then
          requireSource(size, src + 1, 3)
          local second, third, fourth = tonumber(input[src + 1]), tonumber(input[src + 2]), tonumber(input[src + 3])
          length = (first % 16) * 4096 + second * 16 + math.floor(third / 16) + 0x111
          displacement = (third % 16) * 256 + fourth + 1
          src = src + 4
        else
          requireSource(size, src + 1, 1)
          local second = tonumber(input[src + 1])
          length = prefix + 1
          displacement = (first % 16) * 256 + second + 1
          src = src + 2
        end
        if displacement > dst then
          Errors.raise(Lz11.ERROR.STREAM_INVALID, "LZ11 match reaches before the decoded start", {
            dst = dst,
            displacement = displacement,
          })
        end
        if dst + length > outputSize then
          Errors.raise(Lz11.ERROR.STREAM_INVALID, "LZ11 match extends past the declared output size", {
            dst = dst,
            length = length,
            outputSize = outputSize,
          })
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
---@return string|nil decoded
---@return Errors.Error? err
function Lz11.decode(bytes)
  assert(type(bytes) == "string", "Lz11.decode requires a string")
  if #bytes < 4 or string.byte(bytes, 1) ~= 0x11 then
    return nil,
      Errors.new(Lz11.ERROR.HEADER_INVALID, "LZ11 payload lacks the 0x11 header", {
        size = #bytes,
        first = #bytes > 0 and string.byte(bytes, 1) or nil,
      })
  end
  -- The owning string stays reachable for the whole pointer use below, so the
  -- borrowed view can never outlive its bytes.
  local input = ffi.cast("const uint8_t *", bytes)
  local size = #bytes
  local ok, result = pcall(function()
    local outputSize, src = decodeSize(input, size)
    return decode(input, size, outputSize, src)
  end)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result, 0)
end

return Lz11
