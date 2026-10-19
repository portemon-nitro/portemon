-- LZ11 decompression for compressed Nintendo DS NARC members.

local Errors = require("libs.errors.src.Errors")

local Lz11 = {}
Lz11.ERROR = {
  HEADER_INVALID = "LZ11_HEADER_INVALID",
  STREAM_INVALID = "LZ11_STREAM_INVALID",
}

local function requireSource(bytes, src, count)
  if src + count - 1 > #bytes then
    Errors.raise(Lz11.ERROR.STREAM_INVALID, "LZ11 stream ends in the middle of a token", {
      src = src,
      needed = count,
      size = #bytes,
    })
  end
end

local function decodeSize(bytes)
  local size = string.byte(bytes, 2) + string.byte(bytes, 3) * 256 + string.byte(bytes, 4) * 65536
  if size ~= 0 then
    return size, 5
  end
  requireSource(bytes, 5, 4)
  local b1, b2, b3, b4 = string.byte(bytes, 5, 8)
  size = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
  if size == 0 then
    Errors.raise(Lz11.ERROR.HEADER_INVALID, "LZ11 stream declares an empty output", { size = size })
  end
  return size, 9
end

local function decode(bytes)
  local outputSize, src = decodeSize(bytes)
  local output = {}
  local dst = 1
  while dst <= outputSize do
    requireSource(bytes, src, 1)
    local flags = string.byte(bytes, src)
    src = src + 1
    for bit = 7, 0, -1 do
      if dst > outputSize then
        break
      end
      if math.floor(flags / 2 ^ bit) % 2 == 0 then
        requireSource(bytes, src, 1)
        output[dst] = string.byte(bytes, src)
        src = src + 1
        dst = dst + 1
      else
        requireSource(bytes, src, 1)
        local first = string.byte(bytes, src)
        local prefix = math.floor(first / 16)
        local length, displacement
        if prefix == 0 then
          requireSource(bytes, src + 1, 2)
          local second, third = string.byte(bytes, src + 1, src + 2)
          length = (first % 16) * 16 + math.floor(second / 16) + 0x11
          displacement = (second % 16) * 256 + third + 1
          src = src + 3
        elseif prefix == 1 then
          requireSource(bytes, src + 1, 3)
          local second, third, fourth = string.byte(bytes, src + 1, src + 3)
          length = (first % 16) * 4096 + second * 16 + math.floor(third / 16) + 0x111
          displacement = (third % 16) * 256 + fourth + 1
          src = src + 4
        else
          requireSource(bytes, src + 1, 1)
          local second = string.byte(bytes, src + 1)
          length = prefix + 1
          displacement = (first % 16) * 256 + second + 1
          src = src + 2
        end
        if displacement > dst - 1 then
          Errors.raise(Lz11.ERROR.STREAM_INVALID, "LZ11 match reaches before the decoded start", {
            dst = dst,
            displacement = displacement,
          })
        end
        if dst + length - 1 > outputSize then
          Errors.raise(Lz11.ERROR.STREAM_INVALID, "LZ11 match extends past the declared output size", {
            dst = dst,
            length = length,
            outputSize = outputSize,
          })
        end
        for _ = 1, length do
          output[dst] = output[dst - displacement]
          dst = dst + 1
        end
      end
    end
  end
  local chunks = {}
  for index = 1, outputSize do
    chunks[index] = string.char(output[index])
  end
  return table.concat(chunks)
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
  local ok, result = pcall(decode, bytes)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result, 0)
end

return Lz11
