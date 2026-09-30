-- Shared mon-icon fixture for graphics smoke: one synthetic MON0/f0
-- icon page in the current manifest shape, plus the immediate decoding
-- queue, the always-ready derived-asset host, and a provider prepared
-- for the demanded keys. One owner so the page contract (pageId on
-- every entry, per-page images, explicit preparation before draw) stays
-- in exactly one place instead of drifting across suites.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MonCache = require("libs.assets.src.MonCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local PngWriter = require("libs.assets.src.PngWriter")

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

---@param cache CacheFs backing cache the queue decodes from
---@return table<string, unknown> immediately-ready image decoding queue
function PreparedMonIcons.decodingQueue(cache)
  local nextToken = 0
  local live = {}
  local queue = {}
  function queue:request(kind, path, priority)
    assert(kind == "image", "icon pages decode as images")
    assert(priority == "demand", "visible party pages decode as demand")
    nextToken = nextToken + 1
    live[nextToken] = path
    return nextToken
  end
  function queue:poll(token)
    assert(live[token], "poll observes a live token")
    return "ready"
  end
  function queue:take(token)
    local path = assert(live[token], "take transfers a live token once")
    live[token] = nil
    local bytes = assert(cache:read(path), "the compiled icon page is present")
    local fileData = assert(love.filesystem.newFileData(bytes, "icon-page.png"), "page bytes form a file")
    return { imageData = assert(love.image.newImageData(fileData), "page bytes decode") }
  end
  function queue:cancel(token)
    live[token] = nil
  end
  return queue
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
---@return table<string, unknown> provider with the demanded pages ready
function PreparedMonIcons.preparedProvider(cache, keys)
  local provider = MonIconAssetProvider.new(cache, {
    preparationQueue = PreparedMonIcons.decodingQueue(cache),
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

return PreparedMonIcons
