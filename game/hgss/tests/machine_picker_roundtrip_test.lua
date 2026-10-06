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
local SummaryScreenState = require("game.hgss.src.field.SummaryScreenState")

local function openService(catalog, seed)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture()),
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

local function badgeFrames()
  return {
    frames = { { image = "test-badge", width = 8, height = 8, durationTicks = 1 } },
    loopFrom = 1,
  }
end

local function manifest()
  local anchors = {}
  for index = 1, 5 do
    anchors[index] = { x = index * 8, y = 0 }
  end
  return {
    shinyLeaves = {
      anchors = anchors,
      crownAnchor = { x = 0, y = 0 },
      leaves = badgeFrames(),
      crown = badgeFrames(),
    },
  }
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
  return {
    mons = service,
    manifest = manifest(),
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
  }
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
  state:updateFixed({})
  Assert.equal(state:status().page, "moves", "the teaching picker opens on its move rows")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.isNil(state:takeResult(), "a protected HM row reports no terminal result")
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
  state:updateFixed({})
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
  state:updateFixed({})
  Assert.equal(state:status().page, "moves", "the PP picker opens on its move rows")
  state:updateFixed({ { type = "confirm" } })
  local result = assert(state:takeResult(), "a terminal gesture reports its result")
  Assert.equal(result.kind, "move_selected", "the PP choice completes the pick")
  Assert.equal(result.slot, 0, "the pick carries its member")
  Assert.equal(result.partyRevision, service:partyRevision(), "the pick carries the live revision")
  state:dispose()
end

return { tests = T }
