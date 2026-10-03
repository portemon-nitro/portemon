local Assert = require("tests.support.Assert")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")

local T = {}

function T.background_events_require_hidden_item_collection_flags()
  local events = { background = {}, objects = {}, warps = {}, coordinates = {} }
  events.background[1] = { hiddenItem = true, hiddenItemFlagId = 800 }
  Assert.isTrue(FieldMapDataCache.hasRequiredEvents(events))

  events.background[1].hiddenItemFlagId = 1799
  Assert.isTrue(FieldMapDataCache.hasRequiredEvents(events))
  events.background[1].hiddenItemFlagId = 1800
  Assert.isFalse(FieldMapDataCache.hasRequiredEvents(events))

  events.background[1] = { hiddenItem = true }
  Assert.isFalse(FieldMapDataCache.hasRequiredEvents(events))
  events.background[1] = { hiddenItem = false, hiddenItemFlagId = 800 }
  Assert.isFalse(FieldMapDataCache.hasRequiredEvents(events))
end

return { tests = T }
