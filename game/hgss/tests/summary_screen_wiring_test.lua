-- Summary composition over real collaborators: the live mon service,
-- a synthetic party manifest, and the measured display contract. The
-- wrapper borrows everything, publishes reorders through the owned
-- preparation path, and returns the displayed member on close.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SummaryScreenState = require("game.hgss.src.field.SummaryScreenState")

local T = {}

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
  opts = opts or {}
  local box = { width = 512, height = 384, topologyObject = topology(512, 384) }
  return {
    mons = service,
    manifest = manifest(),
    initialSlot = opts.initialSlot or 0,
    measureDisplay = function()
      return {
        width = box.width,
        height = box.height,
        topology = box.topologyObject,
        pixelRatio = 1,
        signature = "summary-screen-wiring-test:512x384",
      }
    end,
    mode = opts.mode or "summary",
    request = opts.request,
  }
end

function T.pages_turn_members_change_and_close_returns_the_displayed_slot()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x77777777)
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE")
  local state = SummaryScreenState.new(composition(service))
  state:updateFixed({})
  local status = state:status()
  Assert.isTrue(status.open, "the summary opens")
  Assert.equal(status.page, "overview", "the summary opens on overview")
  Assert.equal(status.slot, 0, "the summary opens on the requested member")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().page, "stats", "navigation turns the page")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().slot, 1, "navigation changes the member")
  state:updateFixed({ { type = "cancel" } })
  state:updateFixed({ { type = "cancel" } })
  local result = assert(state:takeResult(), "a terminal gesture reports its result")
  Assert.equal(result.kind, "return", "closing reports a return")
  Assert.equal(result.slot, 1, "party resumes on the displayed member")
  state:dispose()
end

function T.overview_only_badges_and_masks_survive_navigation()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x88888888)
  gift(service, "CHIKORITA")
  local revision = service:partyRevision()
  local copy = service:partyMon(0)
  copy.shinyLeaves = 21
  local preparation = assert(service:preparePartyChanges(revision, { { slot = 0, mon = copy } }))
  preparation.publish()
  local state = SummaryScreenState.new(composition(service))
  state:updateFixed({})
  local overview = state:status()
  Assert.isTrue(overview.facts.leaves.leaves[1], "mask 21 shows its first leaf")
  Assert.isTrue(overview.facts.leaves.leaves[3], "mask 21 shows its third leaf")
  Assert.isTrue(overview.facts.leaves.leaves[5], "mask 21 shows its fifth leaf")
  Assert.isFalse(overview.facts.leaves.crown, "mask 21 crowns nothing")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  local moves = state:status()
  Assert.equal(moves.page, "moves", "navigation reaches the moves page")
  Assert.deepEqual(
    moves.facts.leaves,
    overview.facts.leaves,
    "leaf visibility travels with the member, while only Overview renders badges"
  )
  Assert.equal(service:partyMon(0).shinyLeaves, 21, "navigation preserves the stored mask")
  state:dispose()
end

function T.reorder_publishes_whole_entries_and_preserves_the_rest()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x99999999)
  gift(service, "CHIKORITA", 5)
  service:setMove(0, 0, "TACKLE")
  service:setMove(0, 1, "GROWL")
  local copy = service:partyMon(0)
  copy.moves[1].pp = 20
  copy.moves[2].ppUps = 2
  copy.moves[2].pp = 30
  copy.shinyLeaves = 13
  copy.heldItem = "SITRUS_BERRY"
  local preparation = assert(service:preparePartyChanges(service:partyRevision(), { { slot = 0, mon = copy } }))
  preparation.publish()
  local before = service:partyRevision()
  local state = SummaryScreenState.new(composition(service))
  state:updateFixed({})
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(service:partyRevision(), before + 1, "one swap advances one revision")
  local after = service:partyMon(0)
  Assert.equal(after.moves[1].move, "GROWL", "the first entry travels to the front")
  Assert.equal(after.moves[1].pp, 30, "power points follow their move")
  Assert.equal(after.moves[1].ppUps, 2, "power-point ups follow their move")
  Assert.equal(after.moves[2].move, "TACKLE", "the second entry travels to the back")
  Assert.equal(after.moves[2].pp, 20, "the other entry keeps its power points")
  Assert.equal(after.shinyLeaves, 13, "leaves survive the reorder")
  Assert.equal(after.heldItem, "SITRUS_BERRY", "the held item survives the reorder")
  state:dispose()
end

function T.move_pick_returns_revision_qualified_selection()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xAAAAAAAA)
  gift(service, "TOTODILE", 5)
  local state = SummaryScreenState.new(composition(service, {
    mode = "move_pick",
    request = { context = "pp_restore" },
  }))
  state:updateFixed({})
  Assert.equal(state:status().page, "moves", "the picker opens on its move rows")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "confirm" } })
  local result = assert(state:takeResult(), "a terminal gesture reports its result")
  Assert.equal(result.kind, "move_selected", "choice completes the pick")
  Assert.equal(result.slot, 0, "the pick carries its member")
  Assert.equal(result.partyRevision, service:partyRevision(), "the pick carries the live revision")
  state:dispose()
end

function T.stale_reorder_aborts_without_publication()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xBBBBBBBB)
  gift(service, "CHIKORITA", 5)
  service:setMove(0, 0, "TACKLE")
  service:setMove(0, 1, "GROWL")
  local state = SummaryScreenState.new(composition(service))
  state:updateFixed({})
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "confirm" } })
  service:setMove(0, 0, "SCRATCH")
  local drifted = service:partyRevision()
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(service:partyRevision(), drifted, "a drifted gesture publishes nothing")
  Assert.isNil(state:takeResult(), "a drifted gesture reports no terminal result")
  state:dispose()
end

return { tests = T }
