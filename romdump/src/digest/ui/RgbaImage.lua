-- Pure producer RGBA operations shared by the bag and party presentation
-- compilers. Crops pack exactly the requested rectangle using the source row
-- stride, and layer composition blends straight alpha bottom-to-top. Inputs
-- stay owned by callers and are never mutated; outputs are fresh records.
-- Pure module: no love dependency, no I/O.

local Errors = require("libs.errors.src.Errors")

---@class RgbaImage
local RgbaImage = {}

-- The protocol code predates the extraction and stays identical so existing
-- bag callers observe the same attributed failures through the new owner.
RgbaImage.ERROR = {
  GEOMETRY_INVALID = "BAG_GEOMETRY_INVALID",
}

local function rgbaBuffer(pixels)
  local buffer = {}
  for index = 1, #pixels do
    buffer[index] = string.byte(pixels, index)
  end
  return buffer
end

local function rgbaPixels(buffer)
  local bytes = {}
  for index, value in ipairs(buffer) do
    bytes[index] = string.char(value)
  end
  return table.concat(bytes)
end

local function blendOver(buffer, offset, sourceR, sourceG, sourceB, sourceA)
  if sourceA == 0 then
    return
  end
  if sourceA == 255 then
    buffer[offset + 1], buffer[offset + 2], buffer[offset + 3], buffer[offset + 4] = sourceR, sourceG, sourceB, 255
    return
  end
  local destinationA = buffer[offset + 4]
  local outputA = sourceA + math.floor(destinationA * (255 - sourceA) / 255 + 0.5)
  if outputA == 0 then
    return
  end
  buffer[offset + 1] =
    math.floor((sourceR * sourceA + buffer[offset + 1] * destinationA * (255 - sourceA) / 255) / outputA + 0.5)
  buffer[offset + 2] =
    math.floor((sourceG * sourceA + buffer[offset + 2] * destinationA * (255 - sourceA) / 255) / outputA + 0.5)
  buffer[offset + 3] =
    math.floor((sourceB * sourceA + buffer[offset + 3] * destinationA * (255 - sourceA) / 255) / outputA + 0.5)
  buffer[offset + 4] = outputA
end

---@param image { width: integer, height: integer, pixels: string }
---@param role string
local function checkImage(image, role)
  if
    type(image) ~= "table"
    or type(image.width) ~= "number"
    or type(image.height) ~= "number"
    or image.width % 1 ~= 0
    or image.height % 1 ~= 0
    or image.width <= 0
    or image.height <= 0
    or type(image.pixels) ~= "string"
    or #image.pixels ~= image.width * image.height * 4
  then
    Errors.raise(RgbaImage.ERROR.GEOMETRY_INVALID, role .. " has malformed source pixels", {})
  end
end

-- Compose decoded source surfaces in bottom-to-top order and keep the result
-- source-independent. Transparent source pixels leave lower layers intact.
---@param layers { width: integer, height: integer, pixels: string }[]
---@param role string
---@return { width: integer, height: integer, pixels: string }
function RgbaImage.compose(layers, role)
  if type(layers) ~= "table" or #layers == 0 then
    Errors.raise(RgbaImage.ERROR.GEOMETRY_INVALID, role .. " has no source layers", {})
  end
  local first = layers[1]
  checkImage(first, role .. " has a malformed source layer")
  local width, height = first.width, first.height
  local output = rgbaBuffer(first.pixels)
  for layerIndex = 2, #layers do
    local layer = layers[layerIndex]
    if
      type(layer) ~= "table"
      or layer.width ~= width
      or layer.height ~= height
      or type(layer.pixels) ~= "string"
      or #layer.pixels ~= width * height * 4
    then
      Errors.raise(RgbaImage.ERROR.GEOMETRY_INVALID, role .. " has incompatible source layers", { layer = layerIndex })
    end
    for pixel = 0, width * height - 1 do
      local sourceOffset = pixel * 4
      blendOver(
        output,
        sourceOffset,
        string.byte(layer.pixels, sourceOffset + 1),
        string.byte(layer.pixels, sourceOffset + 2),
        string.byte(layer.pixels, sourceOffset + 3),
        string.byte(layer.pixels, sourceOffset + 4)
      )
    end
  end
  return { width = width, height = height, pixels = rgbaPixels(output) }
end

-- Crop an integer in-bounds rectangle out of a source image. The source row
-- stride stays image.width while destination rows pack rect.width, so narrow
-- crops contain exactly the requested pixels. Alpha channels, including
-- transparent RGB values, pass through untouched.
---@param image { width: integer, height: integer, pixels: string }
---@param rect { x: integer, y: integer, width: integer, height: integer }
---@param role string
---@return { width: integer, height: integer, pixels: string }
function RgbaImage.crop(image, rect, role)
  checkImage(image, role .. " cannot be cropped")
  if
    type(rect) ~= "table"
    or type(rect.x) ~= "number"
    or type(rect.y) ~= "number"
    or type(rect.width) ~= "number"
    or type(rect.height) ~= "number"
    or rect.x % 1 ~= 0
    or rect.y % 1 ~= 0
    or rect.width % 1 ~= 0
    or rect.height % 1 ~= 0
    or rect.x < 0
    or rect.y < 0
    or rect.width <= 0
    or rect.height <= 0
    or rect.x + rect.width > image.width
    or rect.y + rect.height > image.height
  then
    Errors.raise(RgbaImage.ERROR.GEOMETRY_INVALID, role .. " cannot be cropped to the requested rectangle", {})
  end
  assert(rect ~= nil, "the rectangle validates above")
  local rows = {}
  for y = 0, rect.height - 1 do
    local first = ((rect.y + y) * image.width + rect.x) * 4 + 1
    rows[#rows + 1] = image.pixels:sub(first, first + rect.width * 4 - 1)
  end
  return { width = rect.width, height = rect.height, pixels = table.concat(rows) }
end

return RgbaImage
