-- Tests the copied item-key view, including the NONE catalog entry.

local Assert = require("tests.support.Assert")
local ItemFixture = require("libs.items.tests.item_fixture")

local T = {}

function T.item_key_view_is_native_ordered_and_cannot_mutate_catalog()
  local catalog = ItemFixture.makeCatalog()
  local keys = catalog:itemKeys()
  Assert.isTrue(#keys > 1)
  Assert.equal("NONE", keys[1])

  local previousId = -1
  for _, key in ipairs(keys) do
    local nativeId = catalog:item(key).nativeId
    Assert.isTrue(nativeId > previousId)
    previousId = nativeId
  end

  keys[1] = "changed"
  local fresh = catalog:itemKeys()
  Assert.equal("NONE", fresh[1])
  Assert.equal(#keys, #fresh)
end

return { tests = T }
