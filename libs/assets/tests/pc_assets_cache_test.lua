-- A receipt and stale files never make an incomplete PC family ready.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local PcAssetSchema = require("libs.assets.src.PcAssetSchema")
local PcPresentationFixture = require("tests.support.PcPresentationFixture")
local PcCache = require("libs.assets.src.PcCache")

local T = {}

-- This explicit root-level fixture intentionally omits every semantic role.
-- It proves that matching metadata and a marker cannot make an incomplete
-- family ready without reverse-engineering a valid manifest from production.
local function incompletePcManifest()
  return {
    schema = "g4-pc-v2",
    storage = { wallpapers = {} },
    mailbox = {},
    mail = { stationery = {} },
    photoAlbum = {},
    text = {},
    sequences = {},
  }
end

function T.incomplete_pc_family_is_not_ready()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = PcCache.marker("source", "dependencies")
  cache:writeLua(PcCache.manifestPath(), incompletePcManifest())
  cache:writeLua(PcCache.provenancePath(), {})
  cache:write(PcCache.markerPath(), marker)

  Assert.isFalse(PcCache.isReady(cache, marker), "a marker cannot make an incomplete semantic family ready")
  Assert.isFalse(
    PcCache.isReady(cache, PcCache.marker("current-rom", "current-dependencies")),
    "a stale marker cannot make an incomplete family ready"
  )
end

function T.generated_terminal_policy_does_not_expose_source_selectors()
  local manifest = PcPresentationFixture.manifest()
  Assert.isTrue(PcAssetSchema.isValidManifest(manifest), "the runtime terminal policy contains animation slots")
  manifest.terminal.candidateBuildModelMembers = { 33, 138 }
  Assert.isFalse(
    PcAssetSchema.isValidManifest(manifest),
    "physical building-model selectors remain in the producer configuration"
  )
end

function T.asset_path_traversal_is_a_normal_readiness_refusal()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local manifest = PcPresentationFixture.manifest()
  local originalPath = manifest.storage.backgrounds.default.image
  local assetPaths = PcCache.referencedPaths(manifest)
  manifest.storage.backgrounds.default.image = "assets/generated/pc/../outside.png"
  local marker = PcCache.marker("source", "dependencies")
  for _, path in ipairs(assetPaths) do
    if path ~= originalPath then
      cache:write(path, "fixture asset")
    end
  end
  cache:writeLua(PcCache.manifestPath(), manifest)
  cache:writeLua(PcCache.provenancePath(), {
    schema = PcCache.SCHEMA,
    cacheFormat = PcCache.FORMAT,
    versionRomSha1 = "source",
    dependencyHash = "dependencies",
    archives = { content = { path = "source", fileId = 1, memberCount = 1, selectedMemberCount = 1 } },
    selections = {},
  })
  cache:write(PcCache.markerPath(), marker)

  local ok, ready = pcall(PcCache.isReady, cache, marker)
  Assert.isTrue(ok, "an invalid generated asset path is a readiness refusal, not an exception")
  Assert.isFalse(ready, "a generated asset cannot escape its PC asset family")
end

function T.readiness_accepts_generic_provenance_without_source_archive_knowledge()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local manifest = PcPresentationFixture.manifest()
  local marker = PcCache.marker("source", "dependencies")
  local provenance = {
    schema = PcCache.SCHEMA,
    cacheFormat = PcCache.FORMAT,
    versionRomSha1 = "source",
    dependencyHash = "dependencies",
    archives = {
      content = { path = "archive/source-specific-path", fileId = 9876, memberCount = 241, selectedMemberCount = 3 },
    },
    selections = { visual = { path = "archive/source-specific-path", fileId = 9876, members = { 17, 19 } } },
  }
  for _, path in ipairs(PcCache.referencedPaths(manifest)) do
    cache:write(path, "fixture asset")
  end
  cache:writeLua(PcCache.manifestPath(), manifest)
  cache:writeLua(PcCache.provenancePath(), provenance)
  cache:write(PcCache.markerPath(), marker)

  local assertManifest = PcAssetSchema.assertManifest
  local isValidManifest = PcAssetSchema.isValidManifest
  PcAssetSchema.assertManifest = function() end
  PcAssetSchema.isValidManifest = function() return true end
  local ok, ready = pcall(PcCache.isReady, cache, marker)
  PcAssetSchema.assertManifest = assertManifest
  PcAssetSchema.isValidManifest = isValidManifest

  Assert.isTrue(ok, "the cache readiness probe completes")
  Assert.isTrue(ready, "source-independent provenance metadata does not encode archive paths, IDs, or counts")

  local firstAssetPath = assert(PcCache.referencedPaths(manifest)[1], "the fixture references a PC asset")
  cache:remove(firstAssetPath)
  local missingAssetOk, missingAssetReady = pcall(PcCache.isReady, cache, marker)
  Assert.isTrue(missingAssetOk, "a missing generated asset is a readiness refusal, not an exception")
  Assert.isFalse(missingAssetReady, "a structurally valid cache still requires every referenced asset")
  cache:write(firstAssetPath, "fixture asset")

  local wrongMarkerOk, wrongMarkerReady = pcall(PcCache.isReady, cache, PcCache.marker("other", "dependencies"))
  Assert.isTrue(wrongMarkerOk, "a mismatched marker is a readiness refusal, not an exception")
  Assert.isFalse(wrongMarkerReady, "generic provenance remains bound to its marker identity")

  provenance.archives.content.fileId = "not-an-integer"
  cache:writeLua(PcCache.provenancePath(), provenance)
  local malformedOk, malformedReady = pcall(PcCache.isReady, cache, marker)
  Assert.isTrue(malformedOk, "malformed provenance is a readiness refusal, not an exception")
  Assert.isFalse(malformedReady, "malformed generic provenance is not ready")
end

return { tests = T }
