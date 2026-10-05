-- PC child cancellation releases modal ownership and discards staged intent.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")

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
    tags = { "field", "pc", "acceptance", "lifecycle" },
  },
  tests = {},
}

function T.tests.cancel_during_carry_and_nested_summary_releases_the_field()
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = { derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local runtime = game.runtime
    local mons = assert(runtime.monService, "field runtime owns the live mon service")
    Assert.isTrue(mons:giveMon({ species = "CHIKORITA", level = 5 }), "setup mon enters through the live service")
    Assert.isTrue(mons:giveMon({ species = "CYNDAQUIL", level = 5 }), "setup mon enters through the live service")
    local beforeParty = mons:partyMon(0)
    local beforeBoxRevision = mons:boxRevision()
    local host = assert(runtime.pcApplicationHost, "field runtime owns the PC application host")

    local carry = host:open({ app = "storage", mode = 0 })
    host:setPresentationReady(carry, true)
    host:step(carry, { { type = "confirm" }, { type = "confirm" } })
    Assert.equal(host:status().phase, "carry", "Storage holds an uncommitted Deposit intent")
    Assert.isNil(runtime:captureGameSave(), "an active carry keeps field save capture refused")
    host:cancel("focus-lost")
    Assert.isFalse(host:isActive(), "cancellation closes the retained child")
    Assert.deepEqual(mons:partyMon(0), beforeParty, "cancel discards carry without changing Party")
    Assert.equal(mons:boxRevision(), beforeBoxRevision, "cancel publishes no box revision")
    Assert.notNil(runtime:captureGameSave(), "field save capture recovers after cancellation")

    local summary = host:open({ app = "storage", mode = 0 })
    host:setPresentationReady(summary, true)
    host:step(summary, { { type = "action", action = "summary" } })
    Assert.equal(host:status().phase, "child", "Summary is a nested Storage child")
    host:cancel("field-teardown")
    Assert.isFalse(host:isActive(), "field teardown closes nested children")
    Assert.notNil(runtime:captureGameSave(), "field ownership is available after nested teardown")
    Assert.equal(game:renderAttempts(), 0, "lifecycle acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
