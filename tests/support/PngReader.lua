-- Test-side RGBA reader for staged PNG bytes or a compiled RGBA image record.
-- Staged bytes decode through LÖVE's standard image pipeline, so suites assert
-- the pixels the runtime loads rather than any particular encoder framing; a
-- compiled record already carries its finished rows. Returns width, height, and
-- the raw RGBA rows (4 bytes per pixel).

local PngReader = {}

-- Returns width, height, and the raw RGBA rows (4 bytes per pixel).
---@param image string|{ width: integer, height: integer, pixels: string } staged PNG bytes or a compiled RGBA image
---@return integer width
---@return integer height
---@return string rgba row-major RGBA bytes, top-left origin, straight alpha
function PngReader.rgba(image)
  if type(image) == "table" then
    local width, height, pixels = image.width, image.height, image.pixels
    assert(type(width) == "number" and width > 0, "a compiled image carries its width")
    assert(type(height) == "number" and height > 0, "a compiled image carries its height")
    assert(type(pixels) == "string" and #pixels == width * height * 4, "a compiled image carries RGBA rows")
    return width, height, pixels
  end
  assert(type(image) == "string", "PngReader.rgba requires staged PNG bytes or a compiled image")
  local data = love.image.newImageData(love.filesystem.newFileData(image, "assertion.png"))
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
