-- ROM smoke for the Bag asset producer and its consumer boundary.

local Assert = require("tests.support.Assert")
local BagAssetCompiler = require("romdump.src.digest.ui.BagAssetCompiler")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local BagCache = require("libs.assets.src.BagCache")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

function T.production_bundle_passes_the_consumer_gate_and_resolves_its_assets(romFs, versionId)
  local bundle, err = BagAssetCompiler.compile(romFs)
  Assert.notNil(bundle, "the Bag producer compiles its generated bundle: " .. tostring(err))
  bundle = assert(bundle)
  Assert.isTrue(BagAssetSchema.isValidManifest(bundle.manifest), "the Bag manifest passes its consumer schema")
  Assert.equal(bundle.manifest.schema, BagCache.SCHEMA)

  local paths = assert(BagCache.referencedPaths(bundle.manifest))
  Assert.isTrue(#paths > 0, "the Bag bundle publishes generated assets")
  for _, path in ipairs(paths) do
    Assert.notNil(bundle.assets[path], versionId .. " generated asset resolves: " .. path)
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
