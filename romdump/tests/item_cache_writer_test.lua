-- Marker-last publication tests for the item cache writer, against an
-- in-memory cache and synthetic bundles. Covers readiness, rejection of a
-- malformed class, and failed-rebuild preservation of the previous artifact.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("tests.support.PngEncoder")
local ItemFixture = require("libs.items.tests.item_fixture")
local ResidentArtifactFixture = require("tests.support.ResidentArtifactFixture")

local T = {}

local function contracts()
  local ItemCache = require("libs.assets.src.ItemCache")
  local ItemCacheWriter = require("romdump.src.digest.items.ItemCacheWriter")
  return ItemCache, ItemCacheWriter
end

local function bundle(marker)
  local ItemCache = require("libs.assets.src.ItemCache")
  local pixels = string.rep("\0", 32 * 32 * 4)
  local catalog = ItemFixture.buildAssetRoot()
  local entries = {}
  for key in pairs(catalog.items) do
    entries[key] = { x = 0, y = 0, width = 32, height = 32 }
  end
  local iconManifest = {
    schema = "g4-item-icons-v1",
    atlas = ItemCache.iconImagePath(),
    entries = entries,
    representative = { "POTION" },
  }
  return {
    marker = marker,
    index = {
      schema = "g4-item-index-v1",
      version = { id = "heartgold", language = "en" },
      catalogHash = Hashing.hashLua(catalog),
      iconHash = Hashing.sha1hex(pixels),
      catalog = ItemCache.catalogPath(),
      icons = ItemCache.iconImagePath(),
      iconManifest = ItemCache.iconManifestPath(),
    },
    catalog = catalog,
    icons = { width = 32, height = 32, pixels = pixels },
    iconManifest = iconManifest,
    provenance = {},
  }
end

function T.writes_the_class_and_reports_ready()
  local ItemCache, ItemCacheWriter = contracts()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = ItemCache.marker("abc", "dep")
  Assert.equal(
    ResidentArtifactFixture.publish(cache, "items", "global", function(artifact)
      return ItemCacheWriter.stage(artifact, bundle(marker))
    end),
    marker
  )
  Assert.isTrue(ItemCache.isReady(cache, marker), "ready after write")
  local catalog = ItemCache.loadCatalog(cache)
  Assert.equal(catalog.items.POTION.nativeId, 17, "the published catalog loads back")
end

function T.rejects_a_malformed_class_without_publishing()
  local ItemCache, ItemCacheWriter = contracts()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local bad = bundle(ItemCache.marker("abc", "dep"))
  bad.catalog = { items = {} }
  local err = Assert.throws(function()
    ResidentArtifactFixture.publish(cache, "items", "global", function(artifact)
      return ItemCacheWriter.stage(artifact, bad)
    end)
  end)
  Assert.isTrue(Errors.is(err), "malformed class must fail structurally")
  Assert.isNil(cache:read(ItemCache.markerPath()), "no ready marker after rejection")
end

-- A malformed rebuild cannot replace ready content: the rebuild fails
-- structurally, the stage is cleaned, and the prior ready tree stays
-- unchanged and loadable with no new ready marker.
function T.failed_rebuild_preserves_the_previous_artifact()
  local ItemCache, ItemCacheWriter = contracts()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local firstMarker = ItemCache.marker("abc", "dep")
  ResidentArtifactFixture.publish(cache, "items", "global", function(artifact)
    return ItemCacheWriter.stage(artifact, bundle(firstMarker))
  end)

  local broken = bundle(ItemCache.marker("abc", "new-dep"))
  broken.catalog = nil
  Assert.throws(function()
    ResidentArtifactFixture.publish(cache, "items", "global", function(artifact)
      return ItemCacheWriter.stage(artifact, broken)
    end)
  end)
  Assert.isTrue(ItemCache.isReady(cache, firstMarker), "the previous artifact remains ready")
  Assert.equal(cache:read(ItemCache.markerPath()), firstMarker, "the new marker never reached the live tree")
  Assert.isNil(backend:getInfo("staging/heartgold/items"), "the stage is cleaned on failure")
end

function T.v3_item_marker_is_not_ready_under_the_current_item_identity()
  local ItemCache = require("libs.assets.src.ItemCache")
  local ItemCacheWriter = require("romdump.src.digest.items.ItemCacheWriter")
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local previousMarker = "item-cache-v3:abc:dep"
  ResidentArtifactFixture.publish(cache, "items", "global", function(artifact)
    return ItemCacheWriter.stage(artifact, bundle(previousMarker))
  end)

  Assert.isFalse(
    ItemCache.isReady(cache, ItemCache.marker("abc", "dep")),
    "a v3 item catalog must rebuild under the current item identity"
  )
end

-- The session worker path stages through a caller-owned prepared artifact:
-- staging alone never reads ready, and publication makes the class ready
-- with the marker last.
function T.stages_through_a_prepared_artifact_without_touching_live_before_publish()
  local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
  local ItemCache, ItemCacheWriter = contracts()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = ItemCache.marker("abc", "dep")
  local artifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = "test-generation",
    epoch = 1,
    kind = "items",
    key = "global",
    jobKey = "items:global",
  })
  Assert.equal(ItemCacheWriter.stage(artifact, bundle(marker)), marker)
  Assert.isFalse(ItemCache.isReady(cache, marker), "staging alone never reads ready before publication")
  Assert.isFalse(
    artifact:exists(ItemCache.iconImagePath(), "file"),
    "the source phase stages no PNG before its deferred continuation runs"
  )
  local deferred = assert(artifact:pendingImages()[1], "the icon atlas is deferred to the continuation")
  Assert.equal(deferred.relativePath, ItemCache.iconImagePath())
  artifact:write(deferred.relativePath, PngWriter.encode(deferred.width, deferred.height, deferred.rgba:getString()))
  artifact:finishSuccess({ marker = marker })
  ResidentArtifactFixture.materialize(artifact)
  Assert.isTrue(ItemCache.isReady(cache, marker), "the published class reads ready")
end

-- A purpose-built 2D atlas stays a plain, human-editable PNG with exactly the
-- pixels and rectangle identities the compiler produced: publishing emits no
-- replacement representation, no palette-index sidecar, and the same input
-- keeps producing the same image, so the deferred encode/write path cannot
-- change what a mod author or the runtime image pool sees.
function T.icon_atlas_stays_a_plain_png_with_identical_pixels_and_rectangles()
  local ItemCache, ItemCacheWriter = contracts()
  local colors = {
    string.char(200, 20, 30, 255),
    string.char(20, 200, 30, 128),
    string.char(20, 30, 200, 0),
    string.char(240, 240, 240, 255),
  }
  local rows = {}
  for y = 0, 31 do
    local row = {}
    for x = 0, 31 do
      row[#row + 1] = colors[(math.floor(y / 16) * 2 + math.floor(x / 16)) % 4 + 1]
    end
    rows[#rows + 1] = table.concat(row)
  end
  local atlasPixels = table.concat(rows)
  local function builtBundle()
    local value = bundle(ItemCache.marker("abc", "dep"))
    value.icons.pixels = atlasPixels
    value.index.iconHash = Hashing.sha1hex(atlasPixels)
    local names = {}
    for name in pairs(value.iconManifest.entries) do
      names[#names + 1] = name
    end
    table.sort(names)
    for offset, name in ipairs(names) do
      local cell = (offset - 1) % 4
      value.iconManifest.entries[name] = {
        x = (cell % 2) * 16,
        y = math.floor(cell / 2) * 16,
        width = 16,
        height = 16,
      }
    end
    return value
  end
  local first = builtBundle()
  local second = builtBundle()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  ResidentArtifactFixture.publish(cache, "items", "global", function(artifact)
    return ItemCacheWriter.stage(artifact, first)
  end)
  local published = assert(cache:read(ItemCache.iconImagePath()), "the atlas image is published")
  Assert.equal(published:sub(1, 4), "\137PNG", "the atlas is one plain PNG file on disk")

  local imageData, imageErr = love.image.newImageData(love.filesystem.newFileData(published, "icons.png"))
  Assert.notNil(imageData, "the published atlas decodes through the standard image path: " .. tostring(imageErr))
  Assert.equal(imageData:getWidth(), first.icons.width, "the published atlas keeps the compiled width")
  Assert.equal(imageData:getHeight(), first.icons.height, "the published atlas keeps the compiled height")
  local decoded = imageData:getString()
  Assert.equal(#decoded, #first.icons.pixels, "every pixel of the atlas survives the publish")
  Assert.equal(decoded, first.icons.pixels, "the published atlas carries the compiled pixels byte for byte")

  local manifest = assert(cache:loadLua(ItemCache.iconManifestPath()), "the atlas rectangles are published")
  Assert.equal(manifest.atlas, ItemCache.iconImagePath(), "the manifest points at the published PNG")
  for name, rectangle in pairs(first.iconManifest.entries) do
    Assert.deepEqual(manifest.entries[name], rectangle, "the atlas keeps rectangle " .. tostring(name))
  end
  Assert.deepEqual(manifest.representative, first.iconManifest.representative)

  local otherCache = CacheFs.forVersion("heartgold", FakeCache.new())
  ResidentArtifactFixture.publish(otherCache, "items", "global", function(artifact)
    return ItemCacheWriter.stage(artifact, second)
  end)
  Assert.equal(
    assert(otherCache:read(ItemCache.iconImagePath())),
    published,
    "an unchanged atlas input produces the identical PNG bytes"
  )
end

return { tests = T }
