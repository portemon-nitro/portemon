-- Test-only PNG encoding over the shared source-independent image writer.
-- Synthetic fixtures need the same three-argument encoding operation as the
-- ROM producers without depending on the producer implementation, so this
-- adapter supplies the LÖVE zlib compressor on each call. Production code
-- must never import this module.

local PngWriter = require("libs.assets.src.PngWriter")

local PngEncoder = {}

---@param raw string filter-zero PNG scanlines
---@return string zlib-wrapped compressed bytes
local function compressZlib(raw)
  local compressed = love.data.compress("string", "zlib", raw)
  assert(type(compressed) == "string", "string-container compression returns its bytes as a string")
  return compressed
end

---@param width integer
---@param height integer
---@param rgba string row-major top-left RGBA bytes
---@return string png encoded image bytes
function PngEncoder.encode(width, height, rgba)
  return PngWriter.encode(width, height, rgba, compressZlib)
end

PngEncoder.validateDimensions = PngWriter.validateDimensions
PngEncoder.completeDimensions = PngWriter.completeDimensions

return PngEncoder
