-- ROM-conformance test for canonical New Bark and Elm's Lab event members.

local Assert = require("tests.support.Assert")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local LuaWriter = require("libs.codec.src.LuaWriter")

local T = {}

local EXPECTED = {
  [60] = { counts = { 5, 10, 5, 4 } },
  [61] = { counts = { 11, 4, 1, 2 } },
}

function T.target_members_compile_completely_and_deterministically(romFs)
  for mapId = 60, 61 do
    local bundle = assert(FieldMapDataCompiler.compile(romFs, mapId))
    local expected = EXPECTED[mapId]
    local events = bundle.field.events
    Assert.equal(#events.background, expected.counts[1])
    Assert.equal(#events.objects, expected.counts[2])
    Assert.equal(#events.warps, expected.counts[3])
    Assert.equal(#events.coordinates, expected.counts[4])
    local warp = events.warps[1]
    Assert.equal(warp.index, 0)
    Assert.equal(warp.y, 0)
    Assert.equal(warp.destinationWarpId, 0)
    local again = assert(FieldMapDataCompiler.compile(romFs, mapId))
    Assert.equal(LuaWriter.encode(bundle.field), LuaWriter.encode(again.field))
    Assert.equal(bundle.marker, again.marker)
  end
end

function T.hidden_item_map_and_keyed_arm9_records_match_the_cartridge(romFs)
  local HiddenItemParams = require("romdump.src.digest.field.HiddenItemParams")
  local byIndex = assert(HiddenItemParams.load(romFs))
  local count, quantitySum = 0, 0
  for index = 0, 230 do
    local item = assert(byIndex[index], "missing hidden-item index " .. tostring(index))
    count = count + 1
    quantitySum = quantitySum + item.quantity
  end
  Assert.equal(count, 231)
  Assert.equal(quantitySum, 231)
  Assert.equal(byIndex[225].itemId, 92, "index 225 is resolved by its source index")
  Assert.equal(byIndex[230].itemId, 53)

  local bundle = assert(FieldMapDataCompiler.compile(romFs, 60))
  local matches = {}
  for _, event in ipairs(bundle.field.events.background) do
    if event.type == 2 and event.x == 682 and event.z == 391 then
      matches[#matches + 1] = event
    end
  end
  Assert.equal(#matches, 1)
  Assert.deepEqual(matches[1].hiddenItem, { itemId = 17, quantity = 1, flagId = 800 })
  Assert.equal(matches[1].scriptId, "common.hiddenitem_t20_potion")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
