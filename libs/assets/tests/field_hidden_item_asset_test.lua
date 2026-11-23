local Assert = require("tests.support.Assert")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")

local T = {}

function T.background_events_require_a_strict_hidden_item_record()
  local events = { background = {}, objects = {}, warps = {}, coordinates = {} }
  events.background[1] = {
    type = 2,
    hiddenItem = { itemId = 17, quantity = 1, flagId = 800 },
  }
  Assert.isTrue(FieldMapDataCache.hasRequiredEvents(events))

  events.background[1].hiddenItem = { itemId = 65535, quantity = 255, flagId = 1030 }
  Assert.isTrue(FieldMapDataCache.hasRequiredEvents(events))

  events.background[1].hiddenItem = true
  Assert.isFalse(FieldMapDataCache.hasRequiredEvents(events))
  events.background[1].hiddenItem = { itemId = 17, quantity = 1 }
  Assert.isFalse(FieldMapDataCache.hasRequiredEvents(events))
  events.background[1].hiddenItem = { itemId = 17, quantity = 1, flagId = 800, index = 0 }
  Assert.isFalse(FieldMapDataCache.hasRequiredEvents(events))
  events.background[1].hiddenItem = { itemId = 0, quantity = 1, flagId = 800 }
  Assert.isFalse(FieldMapDataCache.hasRequiredEvents(events))
  events.background[1].hiddenItem = { itemId = 17, quantity = 0, flagId = 800 }
  Assert.isFalse(FieldMapDataCache.hasRequiredEvents(events))
  events.background[1].hiddenItem = { itemId = 17, quantity = 1, flagId = 1031 }
  Assert.isFalse(FieldMapDataCache.hasRequiredEvents(events))
  events.background[1] = { type = 2, hiddenItem = { itemId = 17, quantity = 1, flagId = 800 }, hiddenItemIndex = 0 }
  Assert.isFalse(FieldMapDataCache.hasRequiredEvents(events))
  events.background[1] = { type = 2, hiddenItem = { itemId = 17, quantity = 1, flagId = 800 }, hiddenItemFlagId = 800 }
  Assert.isFalse(FieldMapDataCache.hasRequiredEvents(events))
  events.background[1] = { type = 1, hiddenItem = { itemId = 17, quantity = 1, flagId = 800 } }
  Assert.isFalse(FieldMapDataCache.hasRequiredEvents(events))
  events.background[1] = { type = 1 }
  Assert.isTrue(FieldMapDataCache.hasRequiredEvents(events))
  events.background[1] = { type = 2 }
  Assert.isFalse(FieldMapDataCache.hasRequiredEvents(events))
end

return { tests = T }
