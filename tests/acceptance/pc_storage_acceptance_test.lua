-- Production-composed Storage held-item selection through the live Bag child.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "audio-bank:700",
      "audio-bank:702",
      "audio-bank:730",
      "audio-bank:759",
      "map-data:7",
      "map:7",
      "pc:global",
    },
    tags = { "pc", "storage", "acceptance" },
  },
  tests = {},
}

local function withStorage(fn)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "Storage acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function stepPickerUntilClosed(game, handle, event)
  for _ = 1, 120 do
    local status = assert(game.runtime.pcApplicationHost:status())
    if status.childKind == nil then
      return
    end
    game.runtime.pcApplicationHost:step(handle, { event })
  end
  error("the composed held-item Bag picker did not close after input", 0)
end

local function pickerStaysOpenFor(game, handle, event, ticks)
  for _ = 1, ticks do
    local status = assert(game.runtime.pcApplicationHost:status())
    if status.childKind == nil then
      return false
    end
    game.runtime.pcApplicationHost:step(handle, { event })
  end
  return assert(game.runtime.pcApplicationHost:status()).childKind == "heldItemPicker"
end

local function openPicker(host)
  local handle = host:open({ app = "storage", mode = 3 })
  host:setPresentationReady(handle, true)
  local ok, err = pcall(function()
    host:step(handle, { { type = "action", action = "giveItem" } })
  end)
  Assert.isTrue(ok, "Give Item opens the production Bag held-item picker: " .. tostring(err))
  Assert.equal(host:status().childKind, "heldItemPicker", "Storage owns the nested held-item picker")
  return handle
end

function T.tests.give_item_uses_the_live_bag_picker_for_selection_and_cancellation()
  withStorage(function(game)
    local runtime = game.runtime
    local mons = assert(runtime.monService)
    Assert.isTrue(mons:giveMon({ species = "CHIKORITA", level = 5 }))
    local bag = assert(runtime.bagService)
    Assert.isTrue(bag:add("POTION", 1), "the live Bag accepts a holdable item for the journey")
    Assert.isTrue(bag:add("GRASS_MAIL", 1), "the live Bag carries a representative Mail item")
    Assert.isTrue(bag:add("HM03", 1), "the live Bag carries a representative HM item")
    local host = assert(runtime.pcApplicationHost)

    local cursor = assert(runtime.bagCursor)
    cursor:setPocket("mail")
    local mailHandle = openPicker(host)
    Assert.isTrue(
      pickerStaysOpenFor(game, mailHandle, { type = "confirm" }, 30),
      "the existing held-item policy leaves Mail unselected"
    )
    stepPickerUntilClosed(game, mailHandle, { type = "cancel" })
    host:close(mailHandle)

    cursor:setPocket("tmhm")
    local hmHandle = openPicker(host)
    Assert.isTrue(
      pickerStaysOpenFor(game, hmHandle, { type = "confirm" }, 30),
      "the existing held-item policy leaves an HM unselected"
    )
    stepPickerUntilClosed(game, hmHandle, { type = "cancel" })
    host:close(hmHandle)

    cursor:setPocket("medicine")

    local cancelHandle = openPicker(host)
    local beforeParty = mons:partyMon(0)
    local beforeBagRevision = bag:revision()
    stepPickerUntilClosed(game, cancelHandle, { type = "cancel" })
    Assert.equal(host:status().phase, "browse", "cancelling the picker returns to Storage")
    Assert.deepEqual(mons:partyMon(0), beforeParty, "picker cancellation leaves held item unchanged")
    Assert.equal(bag:quantity("POTION"), 1, "picker cancellation leaves Bag quantity unchanged")
    Assert.equal(bag:revision(), beforeBagRevision, "picker cancellation publishes no Bag revision")

    host:close(cancelHandle)
    local selectHandle = openPicker(host)
    local beforeSelectRevision = bag:revision()
    stepPickerUntilClosed(game, selectHandle, { type = "confirm" })
    Assert.equal(mons:partyMon(0).heldItem, "POTION", "the selected semantic item reaches the Pokemon")
    Assert.equal(bag:quantity("POTION"), 0, "the live Bag loses exactly one selected item")
    Assert.equal(bag:revision(), beforeSelectRevision + 1, "the committed picker intent publishes once")
    host:cancel("acceptance-complete")
  end)
end

return T
