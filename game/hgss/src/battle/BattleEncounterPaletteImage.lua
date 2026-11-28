-- Battle-private indexed drawable owner: one immutable source-index image
-- shared by every live generation of its source table plus one tiny exact
-- palette per generation, sampled through the shared exact rule with an
-- explicit coverage wrapper. Source bytes stay stable across palette
-- changes; only the 256x1 palette re-uploads. Zero coverage returns
-- transparent black regardless of the sampled slot, otherwise alpha is
-- the source coverage over the opaque palette color. Caller tint
-- multiplies exactly like the existing drawable path, and the caller
-- shader returns on every path below.

local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")

local PALETTE_SLOTS = 256
local PALETTE_IMAGE_WIDTH = 256
local PALETTE_IMAGE_HEIGHT = 1
local PALETTE_BYTES = PALETTE_SLOTS * 4

-- The shared snippet resolves the red byte through the exact RGBA
-- palette; the wrapper below keeps source coverage instead of palette
-- alpha so transparent texels stay transparent and partial coverage
-- keeps its own alpha over opaque palette colors.
local SHADER_SOURCE = [[
/*__portemon_shared_image_sampling__*/
vec4 effect(vec4 color, Image tex, vec2 texCoord, vec2 screenCoord) {
  vec4 raw = Texel(tex, texCoord);
  vec4 indexed = resolveExactTexel(raw);
  if (raw.a <= 0.0) {
    return vec4(0.0, 0.0, 0.0, 0.0);
  }
  return vec4(indexed.rgb, raw.a) * color;
}
]]

---@class BattleEncounterPaletteImage.Source
---@field id string diagnostic label; the source table itself is the identity shared across its generations
---@field width integer source width in pixels
---@field height integer source height in pixels
---@field pixels string packed index RGBA8 bytes (red slot, alpha coverage)

---@class BattleEncounterPaletteImage.Handle
---@field image table<string, unknown> shared source-index image behind the handle
---@field palette table<string, unknown> per-generation exact palette image
---@field kind string payload representation of the source image
---@field coverage boolean true: the source alpha is coverage over the palette colors, never palette alpha
---@field width integer source width in pixels
---@field height integer source height in pixels
---@field _owner table<string, unknown> owning palette image owner
---@field _entry table<string, unknown> shared live source entry behind the handle
---@field _source BattleEncounterPaletteImage.Source source table keying the shared entry behind the handle
---@field _released boolean true once the handle returned its images

---@class BattleEncounterPaletteImage
---@field _graphics table<string, unknown> host graphics namespace behind uploads and draws
---@field _sources table<BattleEncounterPaletteImage.Source, { image: table<string, unknown>?, refs: integer }> live source entries keyed by source table
---@field _shader table<string, unknown>? battle-local coverage sampler, built once per owner
---@field _disposed boolean true once the owner released its shader
local BattleEncounterPaletteImage = {}
BattleEncounterPaletteImage.__index = BattleEncounterPaletteImage

local Handle = {}
Handle.__index = Handle

-- Draws the sampled generation through the shared exact rule with the
-- owner coverage wrapper. Tint, canvas, blend, and caller shader state
-- are preserved; extra placement arguments pass through to the draw.
---@param graphics table<string, unknown> host graphics namespace behind the draw
---@param x number draw position x
---@param y number draw position y
---@param ... unknown optional extra placement arguments forwarded to the draw call
function Handle:draw(graphics, x, y, ...)
  assert(not self._released, "released encounter palette handles draw nothing")
  self._owner:_draw(self, graphics, nil, x, y, ...)
end

-- Draws the sampled generation through a caller-owned viewport under
-- the same coverage contract as draw.
---@param graphics table<string, unknown> host graphics namespace behind the draw
---@param quad table<string, unknown> source viewport, already transformed UVs owned by the caller
---@param x number draw position x
---@param y number draw position y
---@param ... unknown optional extra placement arguments forwarded to the draw call
function Handle:drawQuad(graphics, quad, x, y, ...)
  assert(not self._released, "released encounter palette handles draw nothing")
  assert(quad ~= nil, "encounter palette quad draws name their viewport")
  self._owner:_draw(self, graphics, quad, x, y, ...)
end

-- Returns the generation palette exactly once and drops the shared
-- source once its last generation releases. A second release raises so
-- retired handles never draw or alias silently.
function Handle:release()
  assert(not self._released, "released encounter palette handles release nothing")
  self._released = true
  self._owner:_releaseHandle(self)
end

---@class BattleEncounterPaletteImage.Options
---@field graphics table<string, unknown>? host graphics namespace (nil keeps love.graphics)

---@param opts BattleEncounterPaletteImage.Options
---@return BattleEncounterPaletteImage
function BattleEncounterPaletteImage.new(opts)
  assert(type(opts) == "table", "the indexed palette owner needs its options")
  local graphics = opts.graphics or love.graphics
  assert(type(graphics) == "table", "the indexed palette owner needs its host graphics")
  return setmetatable({
    _graphics = graphics,
    _sources = {},
    _shader = nil,
    _disposed = false,
  }, BattleEncounterPaletteImage)
end

---@param source BattleEncounterPaletteImage.Source immutable source indices behind the generation
local function checkSource(source)
  assert(type(source) == "table", "palette generations name their immutable source")
  assert(type(source.id) == "string" and source.id ~= "", "palette generations name a stable source identity")
  assert(
    type(source.width) == "number" and source.width % 1 == 0 and source.width > 0,
    "palette source indices carry their width"
  )
  assert(
    type(source.height) == "number" and source.height % 1 == 0 and source.height > 0,
    "palette source indices carry their height"
  )
  assert(
    type(source.pixels) == "string" and #source.pixels == source.width * source.height * 4,
    "palette source indices match their raster dimensions"
  )
end

-- Acquires one sampler handle for the immutable source under its exact
-- palette: the source image uploads once per live source table and stays
-- shared across generations, while the palette uploads per generation.
-- A different source table never aliases an existing entry even under the
-- same label, so a replacement coexists with the live generation until it
-- releases.
-- Failed creations roll back everything staged in that call and publish
-- nothing. An incomplete palette answers nil with its cause instead of
-- raising so the caller keeps its prior published generation.
---@param source BattleEncounterPaletteImage.Source immutable source indices behind the generation
---@param paletteBytes string exact 256-slot RGBA8 palette bytes, opaque colors
---@return BattleEncounterPaletteImage.Handle? sampler handle, nil with an incomplete palette or failed upload
---@return string? failure cause, nil on success
function BattleEncounterPaletteImage:acquire(source, paletteBytes)
  assert(not self._disposed, "a disposed palette owner acquires no generations")
  checkSource(source)
  if type(paletteBytes) ~= "string" or #paletteBytes ~= PALETTE_BYTES then
    return nil,
      "battle encounter palette image has an incomplete palette for source "
        .. tostring(source.id)
        .. ": expected "
        .. tostring(PALETTE_BYTES)
        .. " RGBA8 bytes"
  end
  local entry = self._sources[source]
  local freshEntry = entry == nil
  if freshEntry then
    entry = { image = nil, refs = 0 }
  end
  -- The battle-local sampler builds on the first draw, not here: staging
  -- stays an image-only operation so upload doubles without shader
  -- support keep proving the transactional contract.
  local sourceImage = entry.image
  local paletteImage = nil
  local ok, failure = pcall(function()
    if sourceImage == nil then
      local sourceData = love.image.newImageData(source.width, source.height, "rgba8", source.pixels)
      -- The staged upload lands in the outer local before filtering so
      -- a filter failure still rolls back exactly this image.
      sourceImage = self._graphics.newImage(sourceData)
      assert(sourceImage ~= nil, "the graphics driver handed out no source-index image")
      sourceImage:setFilter("nearest", "nearest")
    end
    local paletteData = love.image.newImageData(PALETTE_IMAGE_WIDTH, PALETTE_IMAGE_HEIGHT, "rgba8", paletteBytes)
    paletteImage = self._graphics.newImage(paletteData)
    assert(paletteImage ~= nil, "the graphics driver handed out no exact palette image")
    paletteImage:setFilter("nearest", "nearest")
  end)
  if not ok or sourceImage == nil or paletteImage == nil then
    if paletteImage ~= nil and type(paletteImage.release) == "function" then
      pcall(function()
        paletteImage:release()
      end)
    end
    if freshEntry and sourceImage ~= nil and type(sourceImage.release) == "function" then
      pcall(function()
        sourceImage:release()
      end)
    end
    return nil,
      "battle encounter palette image upload failed for source " .. tostring(source.id) .. ": " .. tostring(
        failure or "upload returned no image"
      )
  end
  ---@cast sourceImage table<string, unknown>
  ---@cast paletteImage table<string, unknown>
  if freshEntry then
    entry.image = sourceImage
    self._sources[source] = entry
  end
  entry.refs = entry.refs + 1
  local handle = setmetatable({
    image = sourceImage,
    palette = paletteImage,
    kind = "r8",
    coverage = true,
    width = source.width,
    height = source.height,
    _owner = self,
    _entry = entry,
    _source = source,
    _released = false,
  }, Handle)
  return handle
end

-- Returns one generation palette and drops its shared source once the
-- last generation releases. Only the owner calls this, once per handle.
---@param handle BattleEncounterPaletteImage.Handle live generation handle under release
function BattleEncounterPaletteImage:_releaseHandle(handle)
  local palette = handle.palette
  if palette ~= nil and type(palette.release) == "function" then
    palette:release()
  end
  handle.palette = nil
  local entry = self._sources[handle._source]
  if entry ~= nil then
    entry.refs = entry.refs - 1
    assert(entry.refs >= 0, "palette source references release exactly once")
    if entry.refs == 0 then
      self._sources[handle._source] = nil
      local image = entry.image
      if image ~= nil and type(image.release) == "function" then
        image:release()
      end
    end
  end
end

-- Draws one live generation through the battle-local coverage sampler:
-- the source carries indices plus coverage, the palette carries exact
-- slot colors, and the caller shader returns on success and on failure.
---@param handle BattleEncounterPaletteImage.Handle live generation handle under drawing
---@param graphics table<string, unknown> host graphics namespace behind the draw
---@param quad table<string, unknown>? source viewport, nil for whole-image draws
---@param x number draw position x
---@param y number draw position y
---@param ... unknown optional extra placement arguments forwarded to the draw call
function BattleEncounterPaletteImage:_draw(handle, graphics, quad, x, y, ...)
  assert(type(graphics) == "table", "indexed palette draws name their host graphics")
  assert(not self._disposed, "a disposed palette owner draws nothing")
  local shader = self._shader
  if shader == nil then
    shader = graphics.newShader(ImageAssetPool.withSharedSampling(SHADER_SOURCE))
    assert(shader ~= nil, "the graphics driver handed out no indexed palette shader")
    self._shader = shader
  end
  local sourceImage = assert(handle.image, "indexed palette draws require their source image")
  local paletteImage = assert(handle.palette, "indexed palette draws require their exact palette")
  sourceImage:setFilter("nearest", "nearest")
  paletteImage:setFilter("nearest", "nearest")
  local previous = graphics.getShader()
  local args = { ... }
  local function issue()
    graphics.setShader(shader)
    shader:send("u_usePalette", true)
    shader:send("u_paletteCount", PALETTE_SLOTS)
    shader:send("u_palette", paletteImage)
    shader:send("u_paletteOffset", 0)
    if quad ~= nil then
      graphics.draw(sourceImage, quad, x, y, unpack(args))
    else
      graphics.draw(sourceImage, x, y, unpack(args))
    end
  end
  local ok, failure = pcall(issue)
  graphics.setShader(previous)
  if not ok then
    error(failure, 0)
  end
end

-- Releases the battle-local sampler. Live handles keep their own
-- images and still release exactly once; drawing after disposal fails
-- loudly instead of sampling through a retired shader.
function BattleEncounterPaletteImage:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  if self._shader ~= nil and type(self._shader.release) == "function" then
    self._shader:release()
  end
  self._shader = nil
end

return BattleEncounterPaletteImage
