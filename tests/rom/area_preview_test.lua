-- ROM-conformance facts for the generated location-preview class: the
-- compiled field-entry manifest advertises exactly the pinned 25 destination
-- map ids with one semantic image key per time slot, every slot names an
-- indexed 256x192 PNG under the entry root, slots that share a pinned source
-- triple resolve to one image while distinct triples stay distinct, and
-- preview membership does not depend on the destination's own map type.
-- Asserts only structural facts, never retail pixels.

local Assert = require("tests.support.Assert")
local FieldEntryAssetCache = require("libs.assets.src.field.FieldEntryAssetCache")
local FieldEntryAssetCompiler = require("romdump.src.digest.ui.FieldEntryAssetCompiler")
local FieldEntryFixture = require("tests.support.FieldEntryFixture")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local maps = require("romdump.src.catalog.hgss.maps")

local T = {}

-- Compiling the class is the expensive ROM read; one bundle per source dump is
-- reused across this suite's facts.
local bundles = {}
local function manifest(romFs)
  local sha1 = romFs:metadata().sha1
  local bundle = bundles[sha1]
  if bundle == nil then
    bundle = assert(FieldEntryAssetCompiler.compile(romFs))
    bundles[sha1] = bundle
  end
  return bundle.manifest
end

local function destinationMapId(symbol)
  return assert(MapCatalog.idForSymbol(symbol), symbol)
end

local function slotsOf(manifest_, symbol)
  return assert(manifest_.previewByMapId[destinationMapId(symbol)], symbol .. " must be a preview destination")
end

function T.every_pinned_destination_carries_four_indexed_256x192_slots(romFs, _)
  local m = manifest(romFs)
  Assert.isTrue(FieldEntryAssetCache.validateManifest(m), "the compiled manifest validates")

  local pinned = 0
  for _, destination in ipairs(FieldEntryFixture.DESTINATIONS) do
    local mapId = destinationMapId(destination.symbol)
    local slots = assert(m.previewByMapId[mapId], destination.symbol .. " advertises its time slots")
    for slot = 0, FieldEntryAssetCache.PREVIEW_SLOTS - 1 do
      local key = slots[slot]
      Assert.isTrue(
        type(key) == "string" and #key > 0,
        destination.symbol .. " slot " .. slot .. " names a non-empty semantic key"
      )
      local asset = assert(m.assets[key], destination.symbol .. " slot " .. slot .. " indexes an asset")
      Assert.equal(asset.width, FieldEntryAssetCache.PREVIEW_WIDTH, key .. " width")
      Assert.equal(asset.height, FieldEntryAssetCache.PREVIEW_HEIGHT, key .. " height")
      Assert.equal(
        asset.image:sub(1, #FieldEntryAssetCache.assetDir()),
        FieldEntryAssetCache.assetDir(),
        key .. " image stays under the entry root"
      )
    end
    pinned = pinned + 1
  end
  Assert.equal(pinned, 25, "the selector carries the pinned 25 destination map ids")

  local advertised = 0
  for _ in pairs(m.previewByMapId) do
    advertised = advertised + 1
  end
  Assert.equal(advertised, 25, "the manifest advertises exactly the pinned destinations")
end

-- The compiler emits one image per distinct pinned source triple: slots that
-- share a base must alias one image, and slots with different bases must not.
-- This is the dedup contract expressed over the pinned source table, so it
-- covers Ilex's unique evening art and Union Cave's day/evening alias without
-- re-deriving the compiler's ordinal mapping.
function T.shared_source_triples_alias_and_distinct_triples_do_not(romFs, _)
  local m = manifest(romFs)

  for _, destination in ipairs(FieldEntryFixture.DESTINATIONS) do
    local slots = slotsOf(m, destination.symbol)
    local slotsByBase = {}
    for slot = 0, FieldEntryAssetCache.PREVIEW_SLOTS - 1 do
      local base = assert(destination.bases[slot + 1], destination.symbol .. " slot " .. slot .. " base")
      slotsByBase[base] = slotsByBase[base] or {}
      table.insert(slotsByBase[base], slot)
    end
    local keyByBase = {}
    for base, shared in pairs(slotsByBase) do
      local first = slots[shared[1]]
      keyByBase[base] = first
      for _, slot in ipairs(shared) do
        Assert.equal(
          slots[slot],
          first,
          destination.symbol .. " slots sharing source base " .. base .. " alias one image"
        )
      end
    end
    for baseA, keyA in pairs(keyByBase) do
      for baseB, keyB in pairs(keyByBase) do
        if baseA < baseB then
          Assert.isTrue(
            keyA ~= keyB,
            destination.symbol .. " distinct source bases " .. baseA .. "/" .. baseB .. " render distinct images"
          )
        end
      end
    end
  end

  -- Named seams from the acceptance contract, asserted directly.
  local ilex = slotsOf(m, "MAP_ILEX_FOREST")
  Assert.isTrue(ilex[1] ~= ilex[2], "Ilex Forest evening is distinct from daytime")
  local union = slotsOf(m, "MAP_UNION_CAVE_1F")
  Assert.equal(union[1], union[2], "Union Cave evening aliases daytime")

  local route45 = slotsOf(m, "MAP_DARK_CAVE_ROUTE_45_SIDE")
  local route31 = slotsOf(m, "MAP_DARK_CAVE_ROUTE_31_SIDE")
  for slot = 0, FieldEntryAssetCache.PREVIEW_SLOTS - 1 do
    Assert.isTrue(
      route45[slot] ~= route31[slot],
      "the two Dark Cave sides render different images in slot " .. slot
    )
  end
end

-- Preview membership is the pinned graphic table, never the destination's own
-- environment: eligible destinations include interior cave maps. The nearest
-- outdoor neighbour of the live acceptance journey is not listed, so its
-- arrival can only be an ordinary warp and the reverse warp can only be
-- ineligible.
function T.preview_membership_is_independent_of_the_destination_map_type(romFs, _)
  local m = manifest(romFs)

  for _, symbol in ipairs({
    "MAP_DARK_CAVE_ROUTE_45_SIDE",
    "MAP_DARK_CAVE_ROUTE_31_SIDE",
    "MAP_UNION_CAVE_1F",
  }) do
    local mapId = destinationMapId(symbol)
    local record = assert(maps.byId[mapId], symbol)
    Assert.equal(record.mapType, "CAVE", symbol .. " is an interior cave map")
    Assert.notNil(m.previewByMapId[mapId], symbol .. " is still an eligible preview destination")
  end

  Assert.isNil(
    m.previewByMapId[destinationMapId("MAP_ROUTE_46")],
    "Route 46 is not a preview destination"
  )
end

return require("tests.rom.support.RomSuite").fromFacts(T)
