-- Production PC Storage mutations are denied during a modal child and are
-- written only through the field save owner after the child returns.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local MonBucket = require("tests.support.MonBucket")
local MonsSave = require("libs.mons.src.MonsSave")

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
    tags = { "field", "pc", "acceptance", "save" },
  },
  tests = {},
}

local function withGame(fn)
  local harness = AcceptanceHarness.new()
  local createGame = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = createGame(versionId, map)
    local catalog = MonBucket.openCatalogs(versionId)
    game.mons = MonsSave.empty(7, { configuredCount = 37 })
    return game
  end
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = { derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "PC save acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.storage_changes_publish_through_the_canonical_save_and_reload()
  withGame(function(game)
    local runtime = game.runtime
    local mons = assert(runtime.monService, "field runtime owns the live mon service")
    Assert.isTrue(mons:giveMon({ species = "CHIKORITA", level = 5 }), "setup mon enters through the live service")
    Assert.isTrue(mons:giveMon({ species = "CYNDAQUIL", level = 5 }), "Storage keeps one party mon behind")

    local host = assert(runtime.pcApplicationHost, "field runtime owns the PC application host")
    local handle = host:open({ app = "storage", mode = 0 })
    host:setPresentationReady(handle, true)
    Assert.isNil(runtime:captureGameSave(), "an open PC child refuses implicit save capture")

    host:step(handle, { { type = "confirm" } }) -- open the party-slot menu
    Assert.equal(host:status().phase, "menu")
    host:step(handle, { { type = "confirm" } }) -- begin Deposit
    Assert.equal(host:status().phase, "carry")
    host:step(handle, { { type = "confirm" } }) -- publish the prepared move
    Assert.equal(mons:partyCount(), 1, "deposit retains the last party mon")
    Assert.notNil(mons:boxMon(0, 0), "deposit publishes into the canonical box slot")

    host:step(handle, { { type = "cancel" } })
    Assert.notNil(host:result(handle), "closed child returns once to the source shell")
    host:close(handle)
    runtime.saveCoordinator:save()

    local saveId = runtime.saveId
    local stored = assert(runtime.saveStore:load(saveId), "the production save store returns the published record")
    Assert.equal(stored.mons.boxes.boxes[1].slots[1].species, "CHIKORITA")
    Assert.equal(stored.mons.party.mons[1].species, "CYNDAQUIL")

    game:_disposeRuntime()
    local reloaded =
      game.harness:_newRuntime(stored, game.saveNamespace, game.faults, game.lifecycle, game.fieldOptions, false)
    game.runtime = reloaded
    game.hosts = reloaded.scriptHosts or {}
    game.runtimeDisposed = false
    game.disposeErr = nil
    game.saveStatus = reloaded.saveStatus
    Assert.equal(reloaded.monService:boxMon(0, 0).species, "CHIKORITA", "reload restores boxed Storage custody")
    Assert.equal(reloaded.monService:partyMon(0).species, "CYNDAQUIL", "reload restores remaining Party custody")
    Assert.equal(reloaded.monService:boxCount(), 37, "reload retains the expanded box count over the smaller default")
    Assert.isFalse(reloaded.pcApplicationHost:isActive(), "modal state is not persisted")
  end)
end

return T
