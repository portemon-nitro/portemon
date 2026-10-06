-- Boxed Summary subjects use copied mon values and route a move reorder to
-- the exact box address without constructing or changing a surrogate Party.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")
local SummaryPresentationFixture = require("tests.support.SummaryPresentationFixture")
local SummaryScreenState = require("game.hgss.src.field.SummaryScreenState")

local T = {}

local function service()
  local catalog = CatalogFixture.makeCatalog()
  local mons = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xABCD1234):capture(), catalog:fingerprint()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
  local factory = CatalogFixture.makeFactory(0x1234ABCD, catalog)
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  mons:setMove(0, 0, "TACKLE")
  mons:setMove(0, 1, "GROWL")
  return mons
end

local function measurement()
  return {
    width = 512,
    height = 384,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 512, height = 384 },
      touch = false,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "pc-storage-summary-test:512x384",
  }
end

local function storeBoxCopy(mons)
  local boxed = mons:partyMon(0)
  boxed.shinyLeaves = 1
  local prepared = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 4, mon = boxed } } }))
  prepared.publish()
  return boxed
end

function T.mon_projection_accepts_a_detached_box_subject()
  local mons = service()
  local boxed = storeBoxCopy(mons)
  local revision = mons:boxRevision()
  local facts = SummaryModel.buildMon(boxed, {
    revision = revision,
    index = 0,
    count = 1,
    catalog = mons:catalog(),
    derive = function(mon)
      return mons:derive(mon)
    end,
  })
  local partyBefore = mons:partyMon(0)
  Assert.equal(facts.revision, revision)
  Assert.equal(facts.slot, 0, "summary controller index is the occupied-subject index")
  Assert.equal(facts.slotCount, 1)
  Assert.isTrue(facts.leaves.leaves[1], "facts come from the supplied boxed mon")
  Assert.equal(facts.moves[1].key, "TACKLE")
  Assert.deepEqual(mons:partyMon(0), partyBefore, "projecting a detached mon does not mutate Party")
end

function T.summary_reorders_whole_entries_at_the_box_subject_address()
  local mons = service()
  local partyBefore = mons:partyMon(0)
  storeBoxCopy(mons)
  local subjectPort = {
    count = function()
      return mons:boxMon(0, 4) ~= nil and 1 or 0
    end,
    revision = function()
      return mons:boxRevision()
    end,
    read = function(index)
      Assert.equal(index, 0)
      return assert(mons:boxMon(0, 4))
    end,
    publish = function(index, mon, expectedRevision)
      Assert.equal(index, 0)
      if expectedRevision ~= mons:boxRevision() then
        return { kind = "stale" }
      end
      local prepared, reason = mons:preparePcChanges({
        partyRevision = mons:partyRevision(),
        boxRevision = expectedRevision,
      }, { boxUpdates = { { box = 0, slot = 4, mon = mon } } })
      if prepared == nil then
        assert(reason == "stale", "box publication only refuses stale revisions")
        return { kind = "stale" }
      end
      prepared.publish()
      return { kind = "changed" }
    end,
  }
  local family = SummaryPresentationFixture.manifest()
  local lease = {}
  function lease:prepare(demand)
    return { kind = "ready", key = demand.key, assets = { manifest = family } }
  end
  function lease:release() end
  local state = SummaryScreenState.new({
    mons = mons,
    manifest = family,
    measureDisplay = measurement,
    subjectPort = subjectPort,
    mode = "summary",
    initialSlot = 0,
    context = function()
      return SummaryPresentationFixture.context(1)
    end,
    readNavigation = function()
      return nil
    end,
    acquirePreparation = function()
      return lease
    end,
  })
  for _ = 1, 12 do
    state:updateFixed({})
  end
  Assert.isTrue(state:status().facts.indicators.leaves[1], "initial facts belong to the selected box mon")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:updateFixed({ { type = "confirm" } })
  for _ = 1, 6 do
    if state:status().phase == "move_detail" then
      break
    end
    state:updateFixed({})
  end
  Assert.equal(state:status().phase, "move_detail", "the detail settles after its transition")
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "confirm" } })

  local moves = assert(mons:boxMon(0, 4)).moves
  Assert.equal(moves[1].move, "GROWL")
  Assert.equal(moves[2].move, "TACKLE")
  Assert.equal(mons:boxRevision(), 2, "one move reorder publishes one box revision")
  Assert.deepEqual(mons:partyMon(0), partyBefore, "the box subject never passes through Party")
  state:dispose()
end

return { tests = T }
