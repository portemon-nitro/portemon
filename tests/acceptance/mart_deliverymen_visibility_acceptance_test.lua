-- Production-composed Poké Mart deliverymen visibility. Every mart map binds
-- the same source on-transition script, which asks the two gift queues and
-- hides the couriers that have nothing to hand over. A fresh profile queues
-- neither a Mystery Gift nor a parent purchase, so both couriers stay hidden
-- and the transition script must complete without an unsupported node.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:157", "map:157" },
    tags = { "field", "mart", "deliverymen" },
  },
  tests = {},
}

local MART = "MAP_VIOLET_POKEMART"
local HIDE_FLAGS = {
  FieldScriptSymbols.flagsByName.FLAG_HIDE_MYSTERY_GIFT_DELIVERYMAN,
  FieldScriptSymbols.flagsByName.FLAG_HIDE_MOM_GIFT_DELIVERYMAN,
}

---@return string[] the mart map's courier actor ids
local function courierActorIds(game)
  local runtimeMap = game.runtime.runtimeMap
  local ids = {}
  for _, event in ipairs(runtimeMap.fieldData.events.objects) do
    for _, flag in ipairs(HIDE_FLAGS) do
      if event.eventFlag == flag then
        ids[#ids + 1] = "map:" .. runtimeMap.mapId .. ":object:" .. event.objectEventId
      end
    end
  end
  return ids
end

function T.tests.a_mart_with_no_waiting_gift_hides_both_couriers()
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MART,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    local scriptId = assert(
      OpeningLifecycle.lifecycleScriptId(game.runtime, "on_transition"),
      "the mart must declare an on-transition lifecycle script"
    )
    game:waitForFieldEntry()
    game:advanceUntil("the mart transition lifecycle settles", function()
      return game.runtime.scripts.scheduler:foregroundEnvironmentId() == nil and not game:snapshot().fieldLocked
    end, 240)
    local faults = game:recordsForScript(scriptId, "script.error")
    Assert.equal(
      #faults,
      0,
      "the courier visibility script must not fault; got " .. (faults[1] and faults[1].payload.code or "no record")
    )
    for _, flag in ipairs(HIDE_FLAGS) do
      Assert.isTrue(
        game.runtime.scripts.worldState:isFlagSet(flag),
        "a mart with nothing to deliver hides courier flag " .. flag
      )
    end
    local couriers = courierActorIds(game)
    Assert.equal(#couriers, 2, "the prepared mart map declares both gift couriers")
    for _, actorId in ipairs(couriers) do
      Assert.isNil(game.runtime.actors:getById(actorId), "a courier with nothing to deliver stays out of the field")
    end
    Assert.equal(game:renderAttempts(), 0, "the transition flow must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
