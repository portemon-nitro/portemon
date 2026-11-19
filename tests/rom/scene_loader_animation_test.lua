-- Private target test: the real animated model descriptors of a map with
-- animated buildings reference one native model bank per source model by
-- stable draw index, and each selected draw decodes through the production
-- runtime replay to real geometry; the descriptor batches carry the
-- per-segment polygon draw state.
-- Runs against every ready dump through the ROM layer.

local Assert = require("tests.support.Assert")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local CompiledAsset = require("tests.rom.support.CompiledAsset")

local T = {}

function T.new_bark_animated_descriptors_reference_round_tripping_native_banks(romFs)
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local animatedCount = 0
  for _, desc in pairs(bundle.models) do
    if desc.kind == "nitro-dynamic" then
      animatedCount = animatedCount + 1
      for _, mesh in ipairs(desc.dynamic.batches) do
        Assert.isTrue(
          type(mesh.geometry) == "table" and tostring(mesh.geometry.file):sub(-5) == ".g4gx",
          "batch references a native model bank by selector"
        )
        local bank = CompiledAsset.bank(bundle, mesh.geometry)
        Assert.isTrue(
          mesh.geometry.drawIndex >= 0 and mesh.geometry.drawIndex < bank.drawCount,
          "batch draw index names a draw of its source model bank"
        )
        local decoded = CompiledAsset.draw(bundle, mesh.geometry)
        Assert.equal(decoded.vertexCount, #decoded.vertices)
        Assert.isTrue(decoded.vertexCount > 0, "the selected draw decodes to geometry")
        Assert.isTrue(mesh.cullMode ~= nil, "per-segment cull state compiled")
        Assert.isTrue(mesh.polygonMode ~= nil, "per-segment polygon mode compiled")
        Assert.isTrue(mesh.polygonId ~= nil, "per-segment polygon id compiled")
        -- The 4-bit light mask is part of the per-segment polygon draw state:
        -- the dynamic batches must emit it exactly like the static path, or
        -- the runtime draws the segment with every light gated off.
        Assert.isTrue(
          mesh.lightMask ~= nil and mesh.lightMask >= 0 and mesh.lightMask <= 15,
          "per-segment light mask compiled"
        )
      end
    end
  end
  Assert.isTrue(animatedCount > 0, "New Bark places animated door models")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
