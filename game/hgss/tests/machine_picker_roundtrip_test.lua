-- The protected move picker round trip for machine teaching: an HM row
-- stays visible but unpickable, an ordinary row returns its
-- revision-qualified slot, cancellation stays explicit, and the ordinary
-- PP picker keeps its contract.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SummaryAcceptanceFixture = require("tests.support.SummaryAcceptanceFixture")
local SummaryPresentationFixture = require("tests.support.SummaryPresentationFixture")
local SummaryScreenState = require("game.hgss.src.field.SummaryScreenState")

local function openService(catalog, seed)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture(), catalog:fingerprint()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
end

local function gift(service, species, level)
  local added = service:giveMon({
    species = species,
    level = level or 5,
    heldItem = "NONE",
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(added, "setup gift must enter the party")
end

local function topology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = false,
    role = "world",
  })
end

local function composition(service, opts)
  local box = { width = 512, height = 384, topologyObject = topology(512, 384) }
  local family = SummaryPresentationFixture.manifest()
  local lease = {}
  function lease:prepare(demand)
    return { kind = "ready", key = demand.key, assets = { manifest = family } }
  end
  function lease:release()
  end
  return {
    mons = service,
    manifest = family,
    initialSlot = 0,
    measureDisplay = function()
      return {
        width = box.width,
        height = box.height,
        topology = box.topologyObject,
        pixelRatio = 1,
        signature = "machine-picker-roundtrip-test:512x384",
      }
    end,
    mode = "move_pick",
    request = opts.request,
    context = function()
      return SummaryPresentationFixture.context(service:partyCount())
    end,
    readNavigation = function()
      return nil
    end,
    acquirePreparation = function()
      return lease
    end,
  }
end

---@param state table<string, unknown> open picker wrapper
local function settle(state)
  for _ = 1, 12 do
    state:updateFixed({})
  end
end

local T = {}

function T.machine_picker_shows_hm_rejects_it_and_returns_an_ordinary_slot()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x77770001)
  gift(service, "TOTODILE", 5)
  service:setMove(0, 0, "SCRATCH")
  service:setMove(0, 1, "CUT")
  local revision = service:partyRevision()
  local state = SummaryScreenState.new(composition(service, {
    request = { context = "replace_machine", protected = { [2] = "hm" } },
  }))
  settle(state)
  Assert.equal(state:status().group, "skills", "the teaching picker opens on its move rows")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.isNil(state:takeResult(), "a protected HM row reports no terminal result")
  state:updateFixed({ { type = "cancel" } })
  Assert.isNil(state:takeResult(), "clearing the notice reports no terminal result")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  state:updateFixed({ { type = "confirm" } })
  local result = assert(state:takeResult(), "an ordinary row completes the pick")
  Assert.equal(result.kind, "move_selected", "the pick selects")
  Assert.equal(result.slot, 0, "the pick carries its member")
  Assert.equal(result.moveSlot, 0, "the pick carries the chosen row")
  Assert.equal(result.partyRevision, revision, "the pick carries the live revision")
  state:dispose()
end

function T.machine_picker_cancellation_stays_explicit()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x77770002)
  gift(service, "TOTODILE", 5)
  local revision = service:partyRevision()
  local state = SummaryScreenState.new(composition(service, {
    request = { context = "replace_machine" },
  }))
  settle(state)
  state:updateFixed({ { type = "dismiss" } })
  local result = assert(state:takeResult(), "dismissal reports its result")
  Assert.equal(result.kind, "cancelled", "cancellation stays explicit")
  Assert.equal(service:partyRevision(), revision, "cancellation publishes nothing")
  state:dispose()
end

function T.pp_picker_keeps_its_contract()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x77770003)
  gift(service, "TOTODILE", 5)
  local state = SummaryScreenState.new(composition(service, {
    request = { context = "pp_restore" },
  }))
  settle(state)
  Assert.equal(state:status().group, "skills", "the PP picker opens on its move rows")
  state:updateFixed({ { type = "confirm" } })
  local result = assert(state:takeResult(), "a terminal gesture reports its result")
  Assert.equal(result.kind, "move_selected", "the PP choice completes the pick")
  Assert.equal(result.slot, 0, "the pick carries its member")
  Assert.equal(result.partyRevision, service:partyRevision(), "the pick carries the live revision")
  state:dispose()
end

-- Machine-replacement preview through the production picker child: the
-- parent-supplied prospective move holds the source preview row without
-- becoming a fifth owned move, declining it stays an explicit
-- cancellation, and ordinary rows keep their revision-qualified picks.
local function openNativePicker(service, summaryManifest, context, request)
  local box = { width = 256, height = 192, topologyObject = topology(256, 192) }
  local prepares = 0
  local lease = {}
  function lease:prepare(demand)
    prepares = prepares + 1
    if prepares < 3 then
      return { kind = "pending" }
    end
    return { kind = "ready", key = demand.key, assets = { manifest = summaryManifest } }
  end
  function lease:release()
  end
  local state = SummaryScreenState.new({
    mons = service,
    manifest = summaryManifest,
    initialSlot = 0,
    measureDisplay = function()
      return {
        width = box.width,
        height = box.height,
        topology = box.topologyObject,
        pixelRatio = 1,
        signature = "machine-picker-acceptance:256x192",
      }
    end,
    mode = "move_pick",
    request = request,
    context = function()
      return context
    end,
    readNavigation = function()
      return nil
    end,
    acquirePreparation = function()
      return lease
    end,
  })
  for _ = 1, 24 do
    state:updateFixed({})
  end
  return state
end

function T.machine_prospective_row_stays_unowned_and_declines_explicitly()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  local versionId = versions[1]
  local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x77770010)
  gift(service, "TOTODILE", 5)
  service:setMove(0, 0, "SCRATCH")
  service:setMove(0, 1, "CUT")
  local revision = service:partyRevision()
  local context = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
  local state = openNativePicker(service, summaryManifest, context, {
    context = "replace_machine",
    protected = { [2] = "hm" },
    prospectiveMove = "THUNDERBOLT",
  })
  local status = state:status()
  Assert.equal(#status.facts.moves, 4, "the preview never inserts a fifth owned move")
  for _ = 1, 4 do
    state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(state:status().moveSlot, 4, "the prospective row is reachable past the owned rows")
  state:updateFixed({ { type = "confirm" } })
  local declined = assert(state:takeResult(), "declining the preview reports its result")
  Assert.equal(declined.kind, "cancelled", "the preview row declines instead of selecting")
  Assert.equal(service:partyRevision(), revision, "declining publishes nothing")
  state:dispose()
end

return {
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "summary:global" },
  },
  tests = T,
}
