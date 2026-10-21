-- ROM smoke for the Summary asset producer and its consumer boundary.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
local RomSuite = require("tests.rom.support.RomSuite")

local compiledByVersion = {}

local function compileBundle(romFs, versionId)
  local compiler = require("romdump.src.digest.ui.SummaryAssetCompiler")
  local catalog = assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
  local portraits = assert(CacheFs.forVersion(versionId):loadLua(MonCache.portraitManifestPath()))
  return assert(compiler.compile(romFs, catalog, portraits))
end

local T = {}

function T.production_bundle_passes_the_consumer_gate_and_resolves_its_assets(romFs, versionId)
  local bundle = compiledByVersion[versionId]
  if bundle == nil then
    bundle = compileBundle(romFs, versionId)
    compiledByVersion[versionId] = bundle
  end

  local schema = require("libs.assets.src.SummaryAssetSchema")
  local ok, err = pcall(schema.assertManifest, bundle.manifest)
  Assert.isTrue(ok, "the compiled Summary bundle must pass its consumer schema: " .. tostring(err))

  local SummaryCache = require("libs.assets.src.SummaryCache")
  local paths = assert(SummaryCache.referencedPaths(bundle.manifest))
  Assert.isTrue(#paths > 0, "the Summary bundle publishes generated assets")
  for _, path in ipairs(paths) do
    Assert.notNil(bundle.assets[path], "generated asset resolves: " .. path)
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.derivedAssets = { "mon-catalog:global", "mon-layout:global" }
return suite
