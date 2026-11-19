-- ROM conformance: the New Bark central map and its neighbor models carry no
-- unmatched cross-batch boundary T-junctions once their draws are decoded from
-- their native model banks.
--
-- Separately rendered terrain batches of one model can segment a shared
-- boundary span differently. The runtime decodes every terrain-eligible draw of
-- one source model bank together and repairs the group before any of them
-- reaches the GPU, so this suite compiles the real New Bark map through the
-- production compiler, replays the grouped draws exactly like the runtime, and
-- checks the invariant over the central scene batches and each neighbor model.
-- Material names identify the known grass02_r/grass01 exemplar only; production
-- behavior takes no per-material branch.

local Assert = require("tests.support.Assert")
local GxDisplayList = require("libs.nds.src.gx.GxDisplayList")
local GxGeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local NativeGxFormat = require("libs.assets.src.model.NativeGxFormat")

local T = {}

---@class NewBarkGeometrySlice: G4GxGeometrySlice
---@field materialIndex integer

local CONFORMER_MODULE = "libs.hgss.src.presentation.TerrainBoundaryConformer"

local function conformer()
  local ok, mod = pcall(require, CONFORMER_MODULE)
  Assert.isTrue(
    ok and type(mod) == "table" and type(mod.findTJunctions) == "function",
    "terrain boundary repair is missing: compiled New Bark batches keep unmatched T-junctions"
  )
  return mod --[[@as table]]
end

local bundles = {}

local function bundleFor(romFs, versionId)
  if bundles[versionId] == nil then
    bundles[versionId] = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  end
  return bundles[versionId]
end

-- Replay the terrain-eligible draws of each source-model bank the records
-- select, exactly like the runtime worker: one arena, the whole eligible group
-- decoded together, then the shared repair over that group. Returns the
-- repaired slices.
local function conformedSlices(bundle, records)
  local conformer = conformer()
  local arena = GxGeometryBuffer.new()
  local scratch = GxDisplayList.newScratch()
  local groups = {}
  local order = {}
  for _, record in ipairs(records) do
    local selector = record.geometry
    Assert.equal(type(selector), "table", "a terrain draw selects its native model bank")
    local key = assert(tostring(selector.file):match("([^/]+)%.g4gx$"), "terrain geometry names a model bank")
    if groups[key] == nil then
      local bank = assert(NativeGxFormat.read(assert(bundle.meshes[key], "the shared bank pool holds " .. key)))
      local eligible = {}
      for _, draw in ipairs(bank.draws) do
        if draw.terrainBoundaryEligible then
          local geom = assert(GxDisplayList.decode(draw.commands, {
            arena = arena,
            scratch = scratch,
            collectCommands = false,
            matrix = draw.matrix,
            restoreStack = draw.restoreStack,
          }))
          eligible[#eligible + 1] = {
            arena = geom.slice.arena,
            vertexOffset = geom.slice.vertexOffset,
            vertexCount = geom.slice.vertexCount,
            indexOffset = geom.slice.indexOffset,
            indexCount = geom.slice.indexCount,
            materialIndex = draw.materialIndex,
          }
        end
      end
      if #eligible > 1 then
        conformer.conform(eligible)
      end
      groups[key] = eligible
      order[#order + 1] = key
    end
  end
  local out = {}
  for _, key in ipairs(order) do
    for _, slice in ipairs(groups[key]) do
      out[#out + 1] = slice
    end
  end
  return out
end

local function meshBatches(bundle, records)
  return conformedSlices(bundle, records)
end

function T.grass_exemplar_seam_has_matching_breakpoints(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local wanted = { grass02_r = false, grass01 = false }
  local ids = {}
  for _, material in ipairs(bundle.scene.materials) do
    if wanted[material.name] ~= nil then
      wanted[material.name] = true
      ids[material.id] = true
    end
  end
  Assert.isTrue(wanted.grass02_r and wanted.grass01, "both exemplar materials are present in the scene")
  local pair = {}
  for _, record in ipairs(bundle.scene.mapBatches) do
    if ids[record.material] then
      pair[#pair + 1] = record
    end
  end
  Assert.isTrue(#pair > 0, "the exemplar materials draw batches")
  Assert.equal(
    #conformer().findTJunctions(meshBatches(bundle, pair)),
    0,
    "the grass02_r/grass01 seam shares matching breakpoints after compilation"
  )
end

function T.production_map_batches_have_no_unmatched_t_junctions(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  Assert.isTrue(#bundle.scene.mapBatches > 0, "the central scene draws terrain batches")
  Assert.equal(
    #conformer().findTJunctions(meshBatches(bundle, bundle.scene.mapBatches)),
    0,
    "zero unmatched cross-batch T-junctions in the production map batches"
  )
end

function T.compiled_neighbor_models_have_no_unmatched_t_junctions(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  Assert.isTrue(#bundle.scene.neighbors > 0, "the central scene carries compiled neighbors")
  for index, neighbor in ipairs(bundle.scene.neighbors) do
    Assert.equal(
      #conformer().findTJunctions(meshBatches(bundle, neighbor.batches)),
      0,
      "neighbor descriptor " .. index .. " has zero unmatched cross-batch T-junctions"
    )
  end
end

return require("tests.rom.support.RomSuite").fromFacts(T)
