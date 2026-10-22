-- Rasterizes the normalized Nitro OBJ resources consumed by overlay 114.

local Overlay114Sprites = {}

---@param charData {depth: integer, tiles: string}
---@param paletteData {colors: {r: integer, g: integer, b: integer}[]}
---@param cell {objs: {tile: integer, width: integer, height: integer, x: integer, y: integer, palette: integer, flipH: boolean?, flipV: boolean?}[]}
---@param mapping integer Nitro OBJ tile mapping mode
---@return {width: integer, height: integer, pixels: string, origin: {x: integer, y: integer}}
function Overlay114Sprites.renderCell(charData, paletteData, cell, mapping)
  assert(charData.depth == 3 or charData.depth == 4, "overlay sprites use decoded 4bpp or 8bpp characters")
  assert(
    type(charData.tiles) == "string" and type(paletteData.colors) == "table",
    "overlay sprite resources are decoded"
  )
  assert(type(cell.objs) == "table" and #cell.objs > 0, "overlay sprite cell carries OAM objects")
  assert(type(mapping) == "number" and mapping % 1 == 0 and mapping >= 0, "OBJ mapping is explicit")

  local first = cell.objs[1]
  local minX, minY = first.x, first.y
  local maxX, maxY = first.x + first.width, first.y + first.height
  for index = 2, #cell.objs do
    local obj = cell.objs[index]
    minX, minY = math.min(minX, obj.x), math.min(minY, obj.y)
    maxX, maxY = math.max(maxX, obj.x + obj.width), math.max(maxY, obj.y + obj.height)
  end
  local width, height = maxX - minX, maxY - minY
  assert(width > 0 and height > 0, "overlay cell has positive bounds")
  local pixels = {}
  for index = 1, width * height * 4 do
    pixels[index] = 0
  end

  local function writePixel(x, y, colorIndex, paletteBank)
    if colorIndex == 0 then
      return
    end
    local color = paletteData.colors[(charData.depth == 3 and paletteBank * 16 or paletteBank * 256) + colorIndex + 1]
    assert(color ~= nil, "overlay OBJ pixel is within its decoded palette")
    local offset = ((y * width + x) * 4)
    pixels[offset + 1], pixels[offset + 2], pixels[offset + 3], pixels[offset + 4] = color.r, color.g, color.b, 255
  end

  local tileBytes = charData.depth == 3 and 32 or 64
  local availableTiles = math.floor(#charData.tiles / tileBytes)
  for objIndex = #cell.objs, 1, -1 do
    local obj = cell.objs[objIndex]
    assert(
      obj.width > 0 and obj.height > 0 and obj.width % 8 == 0 and obj.height % 8 == 0,
      "overlay OAM object dimensions are tile aligned"
    )
    local tilesPerRow = obj.width / 8
    local tileRows = obj.height / 8
    local firstTile = charData.depth == 3 and obj.tile * 2 ^ mapping
      or (mapping >= 1 and obj.tile * 2 ^ (mapping - 1) or obj.tile)
    for row = 0, tileRows - 1 do
      for column = 0, tilesPerRow - 1 do
        local tile = firstTile + row * tilesPerRow + column
        assert(tile >= 0 and tile < availableTiles, "overlay OBJ tile is within its decoded characters")
        local destColumn = obj.flipH and (tilesPerRow - 1 - column) or column
        local destRow = obj.flipV and (tileRows - 1 - row) or row
        local baseX = obj.x - minX + destColumn * 8
        local baseY = obj.y - minY + destRow * 8
        for y = 0, 7 do
          for x = 0, (charData.depth == 3 and 3 or 7) do
            local byteIndex = tile * tileBytes + (charData.depth == 3 and y * 4 + x or y * 8 + x) + 1
            local byte = string.byte(charData.tiles, math.floor(byteIndex))
            local low = charData.depth == 3 and byte % 16 or byte
            local high = charData.depth == 3 and math.floor(byte / 16) or nil
            local px = obj.flipH and 7 - x * (charData.depth == 3 and 2 or 1) or x * (charData.depth == 3 and 2 or 1)
            local py = obj.flipV and 7 - y or y
            writePixel(baseX + px, baseY + py, low, obj.palette)
            if high ~= nil then
              writePixel(baseX + px + (obj.flipH and -1 or 1), baseY + py, high, obj.palette)
            end
          end
        end
      end
    end
  end

  local bytes = {}
  for index, value in ipairs(pixels) do
    bytes[index] = string.char(value)
  end
  return { width = width, height = height, pixels = table.concat(bytes), origin = { x = minX, y = minY } }
end

---@param graphics table<string, function> host graphics namespace enabling GPU upload
---@param records table[] distinct decoded image records behind the caller-owned sprites
---@return table<unknown, unknown> uploaded handle per decoded record
---@return unknown[] owned handles in upload order for single-pass release
function Overlay114Sprites.uploadImages(graphics, records)
  assert(type(graphics.newImage) == "function" and love.image ~= nil, "overlay sprites require LÖVE image upload")
  local uploaded = {}
  local handles = {}
  local ok, result = pcall(function()
    for _, record in ipairs(records) do
      if uploaded[record] == nil then
        local imageData = love.image.newImageData(record.width, record.height)
        for y = 0, record.height - 1 do
          for x = 0, record.width - 1 do
            local offset = (y * record.width + x) * 4
            imageData:setPixel(
              x,
              y,
              string.byte(record.pixels, offset + 1) / 255,
              string.byte(record.pixels, offset + 2) / 255,
              string.byte(record.pixels, offset + 3) / 255,
              string.byte(record.pixels, offset + 4) / 255
            )
          end
        end
        local image = assert(graphics.newImage(imageData), "graphics driver returns an overlay sprite image")
        image:setFilter("nearest", "nearest")
        uploaded[record] = image
        handles[#handles + 1] = image
      end
    end
  end)
  if not ok then
    for _, image in ipairs(handles) do
      image:release()
    end
    error(result, 0)
  end
  return uploaded, handles
end

---@param role string semantic selector role from C03
---@param resources { palette: { colors: { r: integer, g: integer, b: integer }[] }, characters: { depth: integer, tiles: string }, cells: { cells: { objs: { tile: integer, width: integer, height: integer, x: integer, y: integer, palette: integer, flipH: boolean?, flipV: boolean? }[] }[] }, animation: { anims: { frames: { cell: integer, translateX: number, translateY: number, scaleX: number, scaleY: number, rotation: number, duration: integer }[] }[] } } decoded source assets
---@return { image: { width: integer, height: integer, pixels: string, origin: { x: integer, y: integer } }, affine: { translateX: number, translateY: number, scaleX: number, scaleY: number, rotation: number }, duration: integer, position: { x: integer, y: integer } }[]
function Overlay114Sprites.createInitialSprites(role, resources)
  local spriteCount
  if role == "generic-trainer-transition" then
    spriteCount = 1
  elseif role == "generic-wild-transition" then
    spriteCount = 4
  else
    error("overlay 114 has no source sprite variant for " .. tostring(role))
  end
  local animation = assert(resources.animation.anims[1], "selected G2D animation contains its source sequence")
  local frames = {}
  for _, sourceFrame in ipairs(animation.frames) do
    local sourceCellIndex = sourceFrame.cell + 1
    local cell = assert(resources.cells.cells[sourceCellIndex], "G2D animation frame selects an available cell")
    frames[#frames + 1] = {
      image = Overlay114Sprites.renderCell(resources.characters, resources.palette, cell, 0),
      affine = {
        translateX = sourceFrame.translateX,
        translateY = sourceFrame.translateY,
        scaleX = sourceFrame.scaleX,
        scaleY = sourceFrame.scaleY,
        rotation = sourceFrame.rotation,
      },
      duration = sourceFrame.duration,
    }
  end
  local firstFrame = assert(frames[1], "selected G2D animation contains its opening frame")
  local sprites = {}
  for index = 1, spriteCount do
    sprites[index] = {
      image = firstFrame.image,
      affine = firstFrame.affine,
      duration = firstFrame.duration,
      frames = frames,
      position = { x = 0x80000, y = 0x60000 },
    }
  end
  return sprites
end

---@param route table<string, unknown> source-normalized transition route
---@param loadedResources table<string, unknown> resources selected and loaded by the owner
---@return { image: { width: integer, height: integer, pixels: string, origin: { x: integer, y: integer } }, affine: { translateX: number, translateY: number, scaleX: number, scaleY: number, rotation: number }, duration: integer, position: { x: integer, y: integer } }[]
function Overlay114Sprites.createForRoute(route, loadedResources)
  local group = assert(route.assetGroups and route.assetGroups.sprite, "overlay 114 route selects its sprite resources")
  local resources = {
    palette = assert(loadedResources[group.palette], "selected sprite palette is loaded"),
    characters = assert(loadedResources[group.character], "selected sprite characters are loaded"),
    cells = assert(loadedResources[group.cell], "selected sprite cells are loaded"),
    animation = assert(loadedResources[group.animation], "selected sprite animation is loaded"),
  }
  return Overlay114Sprites.createInitialSprites(route.role, resources)
end

return Overlay114Sprites
