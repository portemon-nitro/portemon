-- ROM conformance for the 31 worldwide tree identities and their generated
-- semantic map records, including the neighboring Route 30 trees.

local Assert = require("tests.support.Assert")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local RomSuite = require("tests.rom.support.RomSuite")
local ZoneEvents = require("romdump.src.digest.map.ZoneEvents")

local T = {}

local APRICORN_KEYS = {
  RED_APRICORN = true,
  YLW_APRICORN = true,
  BLU_APRICORN = true,
  GRN_APRICORN = true,
  PNK_APRICORN = true,
  WHT_APRICORN = true,
  BLK_APRICORN = true,
}

function T.all_source_trees_compile_with_unique_world_identity_and_color(romFs)
  local rawArchive = assert(romFs:openNarc("zone_events"))
  local treeMaps = {}
  local rawTreeIndexes = {}
  local route30Indexes = {}
  for map in MapCatalog.all() do
    local bytes = assert(rawArchive:readMember(map.eventMemberId))
    local decoded = assert(ZoneEvents.decode(bytes, {
      mapId = map.id,
      eventMemberId = map.eventMemberId,
    }))
    for _, object in ipairs(decoded.objectEvents) do
      if object.scriptId == 2800 then
        treeMaps[map.id] = true
        Assert.isTrue(object.param0 >= 0 and object.param0 <= 30, "source param0 is a global tree index")
        Assert.isNil(rawTreeIndexes[object.param0], "source tree index is unique across the ROM")
        rawTreeIndexes[object.param0] = true
        if map.symbol == "MAP_ROUTE_30" then
          route30Indexes[object.param0] = true
        end
      end
    end
  end
  Assert.equal(MapCatalog.require("MAP_ROUTE_30").eventMemberId, 31)
  Assert.isTrue(route30Indexes[6], "Route 30 carries the source tree with global index 6")
  Assert.isTrue(route30Indexes[7], "Route 30 carries the neighboring source tree with global index 7")
  local rawTreeCount = 0
  for _ in pairs(rawTreeIndexes) do
    rawTreeCount = rawTreeCount + 1
  end
  Assert.equal(rawTreeCount, 31, "the user ROM contains 31 distinct global tree indices")

  local session = FieldMapDataCompiler.newSession(romFs)
  local seen = {}
  local treeCount = 0
  local route30
  for mapId in pairs(treeMaps) do
    local bundle = assert(session:compile(mapId))
    if mapId == MapCatalog.require("MAP_ROUTE_30").id then
      route30 = bundle.field.events.objects
    end
    for _, object in ipairs(bundle.field.events.objects) do
      if object.scriptId == "common.apricorn_tree" then
        local apricorn = assert(object.apricorn, "source Apricorn tree has generated semantic identity")
        Assert.equal(apricorn.treeIndex, object.param0, "global identity comes from source param0")
        Assert.isTrue(apricorn.treeIndex >= 0 and apricorn.treeIndex <= 30, "tree index is in the worldwide range")
        Assert.isTrue(APRICORN_KEYS[apricorn.apricornKey], "tree color resolves to a semantic Apricorn key")
        Assert.isNil(seen[apricorn.treeIndex], "tree index occurs once across the generated world")
        seen[apricorn.treeIndex] = apricorn.apricornKey
        treeCount = treeCount + 1
      else
        Assert.isNil(object.apricorn, "unrelated object events carry no Apricorn semantics")
      end
    end
  end
  session:close()

  Assert.equal(treeCount, 31, "the generated world contains all 31 source trees")
  for treeIndex = 0, 30 do
    Assert.notNil(seen[treeIndex], "world tree index " .. treeIndex .. " is generated")
  end

  local routeTrees = {}
  for _, object in ipairs(assert(route30, "Route 30 is one of the source tree maps")) do
    if object.scriptId == "common.apricorn_tree" then
      routeTrees[object.param0] = object.apricorn.apricornKey
    end
  end
  Assert.equal(routeTrees[6], "GRN_APRICORN", "the first Route 30 tree is green")
  Assert.equal(routeTrees[7], "PNK_APRICORN", "the neighboring Route 30 tree is pink")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.derivedAssets = {}
return suite
