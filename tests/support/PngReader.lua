-- Test-side RGBA reader for staged PNG bytes. Decodes through LÖVE's
-- standard image pipeline, so suites assert the pixels the runtime loads
-- rather than any particular encoder framing. Returns width, height, and
-- the raw RGBA rows (4 bytes per pixel).

local PngReader = {}

-- Returns width, height, and the raw RGBA rows (4 bytes per pixel).
---@param png string staged PNG bytes
---@return integer width
---@return integer height
---@return string rgba row-major RGBA bytes, top-left origin, straight alpha
function PngReader.rgba(png)
  assert(type(png) == "string", "PngReader.rgba requires staged PNG bytes")
  local data = love.image.newImageData(love.filesystem.newFileData(png, "assertion.png"))
  local width, height = data:getWidth(), data:getHeight()
  assert(data:getFormat() == "rgba8", "PngReader requires RGBA8 decoded pixels")
  assert(data:getSize() == width * height * 4, "decoded RGBA8 byte length does not match dimensions")
  return width, height, data:getString()
end

-- One pixel as r, g, b, a from an rgba buffer returned by PngReader.rgba.
---@param rgba string raw RGBA bytes
---@param width integer image width in pixels
---@param x integer 0-based horizontal pixel
---@param y integer 0-based vertical pixel
---@return integer r
---@return integer g
---@return integer b
---@return integer a
function PngReader.pixel(rgba, width, x, y)
  local offset = (y * width + x) * 4 + 1
  return string.byte(rgba, offset),
    string.byte(rgba, offset + 1),
    string.byte(rgba, offset + 2),
    string.byte(rgba, offset + 3)
end

return PngReader
