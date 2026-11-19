-- ROM-backed geometry compilation: representative map, neighbor, static-building,
-- and animated-building paths expose the same dense draw representation and
-- deterministic ordering to the downstream runtime decode.

local Assert = require("tests.support.Assert")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local RomSuite = require("tests.rom.support.RomSuite")
local CompiledAsset = require("tests/rom/support/CompiledAsset")

local T = {}

local function meshSnapshot(bundle)
  local snapshot = {}
  local drawCount = 0
  local bankKeys = {}
  for bankKey in pairs(bundle.meshes) do
    bankKeys[#bankKeys + 1] = bankKey
  end
  table.sort(bankKeys)
  for _, bankKey in ipairs(bankKeys) do
    local file = MapAssetCache.modelBankPath(bankKey)
    local bank = CompiledAsset.bank(bundle, file)
    for drawIndex = 0, bank.drawCount - 1 do
      drawCount = drawCount + 1
      local decoded = CompiledAsset.draw(bundle, { file = file, drawIndex = drawIndex })
      Assert.isTrue(decoded.vertexCount > 0, "ROM draw has emitted vertices")
      Assert.isTrue(decoded.indexCount > 0, "ROM draw has emitted indices")
      local record = {
        vertices = {},
        indices = {},
      }
      for _, vertex in ipairs(decoded.vertices) do
        record.vertices[#record.vertices + 1] = vertex
      end
      for _, index in ipairs(decoded.indices) do
        Assert.isTrue(index < decoded.vertexCount, "ROM draw indices remain local to the mesh")
        record.indices[#record.indices + 1] = index
      end
      snapshot[file .. "#" .. drawIndex] = record
    end
  end
  Assert.isTrue(drawCount > 0, "representative ROM map emits geometry draws")
  return snapshot
end

function T.representative_map_models_use_dense_geometry_deterministically(romFs)
  local first = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local second = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  Assert.isTrue(#first.scene.mapBatches > 0, "the representative map emits map batches")
  Assert.isTrue(next(first.models) ~= nil, "the representative map emits building model descriptors")
  Assert.deepEqual(meshSnapshot(second), meshSnapshot(first), "representative model geometry is deterministic")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.tags = { "geometry", "model", "determinism" }
return suite
