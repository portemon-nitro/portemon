-- Shared mon-icon fixture for graphics smoke: one synthetic MON0/f0
-- icon page in the current manifest shape, the always-ready
-- derived-asset host, session image owners for real and synthetic
-- caches, and providers prepared for the demanded keys. One owner so the
-- page contract (pageId on every entry, per-page images, explicit
-- preparation before draw) stays in exactly one place instead of drifting
-- across suites.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MonCache = require("libs.assets.src.MonCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local PngWriter = require("tests.support.PngEncoder")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")

local PreparedMonIcons = {}

---@return CacheFs version-scoped cache carrying the synthetic icon page
function PreparedMonIcons.iconCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = MonCache.iconPagePath(0), width = 256, height = 128 },
    },
    pageIds = { 0 },
    entries = {
      ["MON0/f0"] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = {
          { x = 0, y = 0, width = 32, height = 32, duration = 1 },
          { x = 32, y = 0, width = 32, height = 32, duration = 1 },
        },
        pageId = 0,
      },
    },
    representative = { "MON0/f0" },
  })
  local pixels = {}
  for _ = 1, 64 * 64 do
    pixels[#pixels + 1] = string.char(200, 40, 40, 255)
  end
  cache:write(MonCache.iconPagePath(0), PngWriter.encode(64, 64, table.concat(pixels)))
  return cache
end

---@param cache CacheFs backing cache the pool classifies from
---@return table<string, unknown> session image owner for graphics icon preparation
function PreparedMonIcons.imagePool(cache)
  local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
  return ImageAssetPool.new(cache)
end

---@param scope table<string, unknown> graphics ownership scope disposing the pool
---@param cache CacheFs backing cache the pool classifies from
---@return table<string, unknown> session image owner disposed with the scope
function PreparedMonIcons.scopedImagePool(scope, cache)
  local pool = PreparedMonIcons.imagePool(cache)
  scope:own({
    release = function()
      pool:dispose()
    end,
  })
  return pool
end

-- The sampler icon pages borrow under: an exact copy of the provider's
-- own sampler state, so seeded physicals adopt instead of duplicating.
-- A mismatch fails loudly at draw instead of aliasing.
local SEEDED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

---@param scope table<string, unknown> graphics ownership scope owning realized images
---@param cache CacheFs synthetic cache carrying the icon manifest and pages
---@param keys string[] icon selectors to prepare
---@return table<string, unknown> provider with the demanded pages ready
function PreparedMonIcons.seededProvider(scope, cache, keys)
  -- Synthetic pages live in a main-thread-only test cache the pool worker
  -- cannot see, so their exact pixels realize on the main thread and seed
  -- the injected owner as already-classified straight content: borrow,
  -- return, and prune semantics stay real, and only worker classification
  -- is out of scope (proven over real caches elsewhere).
  local manifest = assert(cache:loadLua(MonCache.iconManifestPath()), "the synthetic icon manifest loads")
  local pool = SharedImagePoolFake.new()
  local seenPages = {}
  for _, entry in pairs(assert(manifest.entries, "the synthetic icon manifest carries entries")) do
    local pageId = assert(entry.pageId, "synthetic icon entries carry their page")
    if seenPages[pageId] ~= true then
      seenPages[pageId] = true
      local path = MonCache.iconPagePath(pageId)
      local bytes = assert(cache:read(path), "the synthetic icon page is present: " .. path)
      local data = love.image.newImageData(love.filesystem.newFileData(bytes, path))
      local image = scope:own(love.graphics.newImage(data))
      pool:seedPhysical(path, SEEDED_SAMPLER, {
        image = image,
        kind = "rgba8",
        width = image:getWidth(),
        height = image:getHeight(),
      })
    end
  end
  local provider = MonIconAssetProvider.new(cache, {
    imagePool = pool,
    derivedAssets = PreparedMonIcons.readyDerivedAssets(),
  })
  local ready, failure
  for _ = 1, 8 do
    ready, failure = provider:prepareKeys(keys)
    if ready or failure ~= nil then
      break
    end
  end
  Assert.isTrue(ready, "demanded icon pages prepare: " .. tostring(failure))
  return provider
end

---@return table<string, unknown> derived-asset host that always grants icon pages
function PreparedMonIcons.readyDerivedAssets()
  return {
    requestIconPage = function(pageId, _)
      assert(type(pageId) == "number", "icon demand carries its page")
      return true
    end,
  }
end

---@param cache CacheFs backing cache carrying the icon page
---@param keys string[] icon selectors to prepare
---@param pool table<string, unknown> session image owner borrowing the pages
---@return table<string, unknown> provider with the demanded pages ready
function PreparedMonIcons.preparedProvider(cache, keys, pool)
  assert(pool ~= nil, "icon preparation borrows its session image owner")
  local provider = MonIconAssetProvider.new(cache, {
    imagePool = pool,
    derivedAssets = PreparedMonIcons.readyDerivedAssets(),
  })
  -- The session owner classifies off-thread: yield between rounds instead
  -- of spinning the preparation update, with a bounded stall budget.
  local deadline = os.clock() + 120
  local ready, failure
  while true do
    ready, failure = provider:prepareKeys(keys)
    if ready or failure ~= nil then
      break
    end
    Assert.isTrue(os.clock() < deadline, "demanded icon pages prepare without stalling")
    if love.timer ~= nil and love.timer.sleep ~= nil then
      love.timer.sleep(0.005)
    end
  end
  Assert.isTrue(ready, "demanded icon pages prepare: " .. tostring(failure))
  return provider
end

return PreparedMonIcons
