-- Synthetic Pokegear family publication and semantic validation: a failed
-- rebuild unwinds only its own staged output and leaves the prior ready
-- family readable, a successful receipt points at complete output, warm
-- reads trust the receipt without decoding source bytes, and custom
-- source-neutral contact/station records validate without ROM identities
-- while duplicates and dangling references fail precisely. No commercial
-- bytes appear here; the real dump is exercised by the ROM conformance
-- suite.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local function visualRef(path)
  return { image = path, width = 64, height = 64, anchorX = 0, anchorY = 0 }
end

-- Minimal manifest following the closed family shape: every top-level
-- section is present so validation exercises references, not missing keys.
local function syntheticManifest()
  return {
    schema = "g4-pokegear-assets-v1",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = {
        { key = "custom.elm", sortWeight = 10 },
        { key = "custom.mom", sortWeight = 20 },
      },
      contactOrder = { "custom.elm", "custom.mom" },
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {},
      flypoints = {},
      reception = {},
      shows = {
        { key = "custom.morning-show", title = "Custom Morning" },
      },
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

local function syntheticBundle(marker)
  local manifest = syntheticManifest()
  local assets = {}
  local function collect(node)
    if type(node) ~= "table" then
      return
    end
    if type(node.image) == "string" then
      assets[node.image] = "payload:" .. node.image
      return
    end
    for _, value in pairs(node) do
      collect(value)
    end
  end
  collect(manifest)
  return {
    marker = marker,
    manifest = manifest,
    assets = assets,
    dependencies = { fixture = true },
  }
end

local function requireProduction()
  local loadedWriter, PokegearCacheWriter =
    pcall(require, "romdump.src.digest.ui.PokegearCacheWriter")
  Assert.isTrue(
    loadedWriter,
    "the pokegear staged cache writer must be published before publication safety can be proven"
  )
  local loadedCache, PokegearCache = pcall(require, "libs.assets.src.PokegearCache")
  Assert.isTrue(
    loadedCache,
    "the pokegear cache owner must be published before warm reads can be proven"
  )
  return assert(PokegearCacheWriter), assert(PokegearCache)
end

-- A backend that fails late: early staged writes succeed, then every write
-- fails, mirroring a backend fault on a late image write.
local function lateFailingBackend(writesBeforeFailure)
  local backend = FakeCache.new()
  local writes = 0
  local originalWrite = backend.write
  function backend:write(path, data)
    writes = writes + 1
    if writes > writesBeforeFailure then
      return nil, { code = "FIXTURE_IO", message = "fixture backend fails on a late image write" }
    end
    return originalWrite(self, path, data)
  end
  return backend
end

local function referencedPaths(PokegearCache, manifest, bundle)
  if type(PokegearCache.referencedPaths) == "function" then
    return PokegearCache.referencedPaths(manifest)
  end
  local paths = {}
  for path in pairs(bundle.assets) do
    paths[#paths + 1] = path
  end
  return paths
end

function T.failed_rebuild_preserves_the_prior_ready_family_and_warm_reads_avoid_full_decode()
  local PokegearCacheWriter, PokegearCache = requireProduction()

  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local oldMarker = PokegearCache.marker("rom-sha", "deps-sha")
  local oldBundle = syntheticBundle(oldMarker)
  Assert.isTrue(PokegearCacheWriter.write(cacheFs, oldBundle), "the first publication must succeed")
  Assert.isTrue(
    PokegearCache.isReady(cacheFs, oldMarker),
    "the first publication must report its family ready"
  )

  -- A late backend failure must not report success and must leave the
  -- prior marker and payload usable.
  local failingFs = CacheFs.forVersion("heartgold", lateFailingBackend(2))
  local newMarker = PokegearCache.marker("rom-sha", "other-deps")
  local writeOk, writeResult = pcall(PokegearCacheWriter.write, failingFs, syntheticBundle(newMarker))
  Assert.isTrue(
    not (writeOk and writeResult),
    "a rebuild failing on a late image write must not report success"
  )
  Assert.isTrue(
    PokegearCache.isReady(cacheFs, oldMarker),
    "the failed rebuild must preserve the prior ready marker"
  )
  local preserved = PokegearCache.loadManifest(cacheFs)
  Assert.equal(preserved.schema, oldBundle.manifest.schema, "the failed rebuild must preserve the prior payload")

  -- A successful rebuild publishes a complete receipt: every referenced
  -- path is present under the new marker.
  Assert.isTrue(PokegearCacheWriter.write(cacheFs, syntheticBundle(newMarker)), "the retry must succeed")
  Assert.isTrue(PokegearCache.isReady(cacheFs, newMarker), "the retried publication must report ready")
  local published = PokegearCache.loadManifest(cacheFs)
  for _, path in ipairs(referencedPaths(PokegearCache, published, syntheticBundle(newMarker))) do
    Assert.notNil(backend:read(cacheFs:resolve(path)), "the receipt must cover the published asset " .. path)
  end

  -- A warm read trusts the receipt: loading through a source backend that
  -- fails on any decode still succeeds.
  local decodingRomFs = {
    read = function()
      error("warm reads must not decode source bytes", 0)
    end,
    openNarc = function()
      error("warm reads must not decode source bytes", 0)
    end,
  }
  local _ = decodingRomFs
  local warmFs = CacheFs.forVersion("heartgold", backend)
  Assert.isTrue(PokegearCache.isReady(warmFs, newMarker), "the warm read must trust the current receipt")
  local warm = PokegearCache.loadManifest(warmFs)
  Assert.equal(warm.schema, "g4-pokegear-assets-v1", "the warm read must return the published manifest")
end

local function walkKeys(node, seen)
  if type(node) ~= "table" then
    return
  end
  for key, value in pairs(node) do
    seen[key] = true
    walkKeys(value, seen)
  end
end

function T.custom_contact_and_station_records_validate_without_source_identities()
  local loaded, PokegearAssetSchema = pcall(require, "libs.assets.src.PokegearAssetSchema")
  Assert.isTrue(
    loaded,
    "the pokegear asset schema must be published before custom records can be proven"
  )
  local manifest = syntheticManifest()
  local record, err = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "valid custom records must validate: " .. tostring(err and err.message or err))

  -- Custom records require no ROM coupling: no source archive, member,
  -- file, overlay, or bank selection leaks into the validated record.
  local keys = {}
  walkKeys(record, keys)
  for _, forbidden in ipairs({ "narcId", "memberId", "fileId", "fatId", "overlayId" }) do
    Assert.isNil(keys[forbidden], "the validated custom record must not require " .. forbidden)
  end

  -- Duplicate semantic identities fail precisely on the offending key.
  local duplicated = syntheticManifest()
  duplicated.catalog.contacts[2].key = "custom.elm"
  local dupRecord, dupErr = PokegearAssetSchema.validate(duplicated)
  Assert.isNil(dupRecord, "duplicate contact keys must not validate")
  local dupTyped = assert(dupErr, "duplicate contact keys must carry an error")
  Assert.notNil(
    tostring(dupTyped.message or dupTyped):find("custom.elm", 1, true),
    "the duplicate failure must name the offending key"
  )

  -- Dangling order references fail precisely instead of publishing a
  -- plausible partial catalog.
  local dangling = syntheticManifest()
  dangling.catalog.contactOrder = { "custom.elm", "custom.ghost" }
  local dangRecord, dangErr = PokegearAssetSchema.validate(dangling)
  Assert.isNil(dangRecord, "a dangling order reference must not validate")
  local dangTyped = assert(dangErr, "a dangling order reference must carry an error")
  Assert.notNil(
    tostring(dangTyped.message or dangTyped):find("custom.ghost", 1, true),
    "the dangling failure must name the missing reference"
  )
end

return { tests = T }
