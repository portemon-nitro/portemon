-- Runtime owner of the compiled item icon atlas. It loads and validates
-- the generated icon manifest once, acquires the atlas image once, hands
-- out one cached quad per icon key, and releases the image exactly once.
-- Icon selection stays upstream (the catalog icon key); an unknown semantic
-- key is a structured error, never a blank icon. Mirrors the mon icon
-- provider for the item icon manifest shape (one atlas rectangle per key).

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local ItemCache = require("libs.assets.src.ItemCache")

---@class ItemIconAssetProvider
---@field _graphics love.graphics
---@field _manifest table<string, unknown>
---@field _image love.Image?
---@field _quads table<string, love.Quad>
---@field _pool table<string, unknown>? the borrowed shared image owner; nil keeps eager construction
---@field _lease table<string, unknown>? the installed atlas lease returned on release
---@field _released boolean
local ItemIconAssetProvider = {}
ItemIconAssetProvider.__index = ItemIconAssetProvider

-- The compiled atlas samples point-filtered and clamped, matching the
-- eager construction below, so pooled leases draw identically.
local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

-- The published icon manifest arrives through the staged writer boundary,
-- which already proved the full contract: construction only needs the
-- manifest present with the current schema and an entry record, mirroring
-- the mon icon provider. Per-realization bounds checks stay at the draw site.
---@param cacheFs CacheFs
---@return table<string, unknown>
local function loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(ItemCache.iconManifestPath())
  if type(manifest) ~= "table" then
    Errors.raise(
      FieldErrors.ITEM_ICON_MANIFEST_UNAVAILABLE,
      "no compiled item icon manifest at " .. ItemCache.iconManifestPath(),
      { path = ItemCache.iconManifestPath() }
    )
  end
  assert(type(manifest) == "table", "the icon manifest carries its entries")
  if manifest.schema ~= ItemCache.ICON_MANIFEST_SCHEMA or type(manifest.entries) ~= "table" then
    Errors.raise(
      FieldErrors.ITEM_ICON_MANIFEST_UNAVAILABLE,
      "the compiled item icon manifest is invalid: " .. ItemCache.iconManifestPath(),
      { path = ItemCache.iconManifestPath() }
    )
  end
  return manifest
end

---@param manifest table<string, unknown>
---@param iconKey string
---@return table<string, unknown>
local function entryFor(manifest, iconKey)
  assert(type(iconKey) == "string" and iconKey ~= "", "icon selection requires a semantic key")
  local entry = manifest.entries[iconKey]
  if entry == nil then
    Errors.raise(FieldErrors.ITEM_ICON_UNKNOWN_KEY, "unknown item icon key " .. iconKey, { iconKey = iconKey })
  end
  assert(entry ~= nil, "the manifest carries the resolved entry")
  return entry
end

---@param cacheFs CacheFs
---@param opts { graphics?: love.graphics, imagePool?: table<string, unknown> }?
---@return ItemIconAssetProvider
function ItemIconAssetProvider.new(cacheFs, opts)
  assert(cacheFs ~= nil, "ItemIconAssetProvider requires a CacheFs")
  opts = opts or {}
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "ItemIconAssetProvider requires love.graphics")
  local manifest = loadManifest(cacheFs)
  local data = cacheFs:read(ItemCache.iconImagePath())
  if not data then
    Errors.raise(
      FieldErrors.ITEM_ICON_ATLAS_MISSING,
      "item icon atlas missing at " .. ItemCache.iconImagePath(),
      { path = ItemCache.iconImagePath() }
    )
  end
  local self = setmetatable({
    _graphics = graphics,
    _manifest = manifest,
    _image = nil,
    _quads = {},
    _pool = opts.imagePool,
    _lease = nil,
    _released = false,
  }, ItemIconAssetProvider)
  local imageData = assert(data, "the icon atlas bytes are required")
  local pool = opts.imagePool
  local ok, err = pcall(function()
    if pool ~= nil then
      -- The compiled atlas borrows the shared owner as one pinned lease;
      -- quads stay renderer-owned geometry over the leased dimensions.
      local token = pool:request(ItemCache.iconImagePath(), POOLED_SAMPLER, "demand")
      local stalled = 0
      while true do
        local status, failure = pool:poll(token)
        if status == "ready" then
          break
        end
        if status == "failed" then
          Errors.raise(
            FieldErrors.ITEM_ICON_ATLAS_MISSING,
            "item icon atlas missing at " .. ItemCache.iconImagePath() .. ": " .. tostring(failure),
            { path = ItemCache.iconImagePath() }
          )
        end
        assert(status == "pending", "item icon preparation reports pending or ready")
        stalled = stalled + 1
        if stalled > 10000 then
          error("item icon atlas stalled at " .. ItemCache.iconImagePath(), 0)
        end
        local timer = love and love.timer
        if timer ~= nil and timer.sleep ~= nil then
          timer.sleep(0.001)
        end
      end
      local lease = pool:acquire(token)
      self._lease = lease
      self._image = assert(lease.image, "shared leases carry their resolved image")
      self._image:setFilter("nearest", "nearest")
      local imageWidth, imageHeight = self._image:getWidth(), self._image:getHeight()
      for selector, entry in pairs(manifest.entries) do
        assert(
          entry.x + entry.width <= imageWidth and entry.y + entry.height <= imageHeight,
          "icon frame for " .. selector .. " exceeds the atlas"
        )
      end
      return
    end
    self._image = graphics.newImage(love.filesystem.newFileData(imageData, ItemCache.iconImagePath()))
    self._image:setFilter("nearest", "nearest")
    local imageWidth, imageHeight = self._image:getWidth(), self._image:getHeight()
    for selector, entry in pairs(manifest.entries) do
      assert(
        entry.x + entry.width <= imageWidth and entry.y + entry.height <= imageHeight,
        "icon frame for " .. selector .. " exceeds the atlas"
      )
    end
  end)
  if not ok then
    self:release()
    error(err, 0)
  end
  return self
end

---@return love.Image the shared atlas image for draw calls
function ItemIconAssetProvider:image()
  return assert(self._image, "the icon atlas is loaded")
end

-- The sampling handle over the pooled atlas lease for palette-aware
-- draws, or nil on the eager path (whose RGBA-direct image keeps its raw
-- draw). Read-only like image: a pooled atlas without a lease is a loud
-- error, never a blank icon.
---@return table<string, unknown>? sampling handle carrying image+palette+kind
function ItemIconAssetProvider:handle()
  if self._lease == nil then
    return nil
  end
  return assert(self._lease, "the icon atlas lease is installed")
end

---@param iconKey string
---@return love.Quad quad
function ItemIconAssetProvider:quadFor(iconKey)
  assert(not self._released, "the icon provider is released")
  local entry = entryFor(self._manifest, iconKey)
  local quad = self._quads[iconKey]
  if quad == nil then
    local image = assert(self._image, "the icon atlas is loaded")
    quad = self._graphics.newQuad(entry.x, entry.y, entry.width, entry.height, image:getWidth(), image:getHeight())
    self._quads[iconKey] = quad
  end
  return quad
end

---@param iconKey string
---@return { width: integer, height: integer }
function ItemIconAssetProvider:dimensions(iconKey)
  assert(not self._released, "the icon provider is released")
  local entry = entryFor(self._manifest, iconKey)
  return { width = entry.width, height = entry.height }
end

-- Releases the atlas image exactly once; quads reference no resources of
-- their own, so dropping the cache is sufficient. Safe to call repeatedly.
function ItemIconAssetProvider:release()
  local pool = self._pool
  self._pool = nil
  local lease = self._lease
  self._lease = nil
  local image = self._image
  self._image = nil
  self._quads = {}
  self._released = true
  if pool ~= nil then
    if lease ~= nil then
      pool:release(lease)
    end
    return
  end
  if image ~= nil and image.release then
    image:release()
  end
end

return ItemIconAssetProvider
