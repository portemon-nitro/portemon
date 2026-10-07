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
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xABCD1234):capture()),
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

local function openBoxSummary(mons, occupied, captured, initialSlot)
  local family = SummaryPresentationFixture.manifest()
  local lease = {}
  function lease:prepare(demand)
    captured[#captured + 1] = demand
    return { kind = "ready", key = demand.key, assets = { manifest = family } }
  end
  function lease:release() end
  local subjectPort = {
    count = function()
      return #occupied
    end,
    revision = function()
      return mons:boxRevision()
    end,
    read = function(index)
      local slot = assert(occupied[index + 1], "boxed selections stay inside the occupied set")
      return assert(mons:boxMon(0, slot), "boxed selections stay occupied")
    end,
    publish = function(index, mon, expectedRevision)
      local slot = occupied[index + 1]
      if expectedRevision ~= mons:boxRevision() or slot == nil then
        return { kind = "stale" }
      end
      local prepared, reason = mons:preparePcChanges({
        partyRevision = mons:partyRevision(),
        boxRevision = expectedRevision,
      }, { boxUpdates = { { box = 0, slot = slot, mon = mon } } })
      if prepared == nil then
        assert(reason == "stale", "box publication only refuses stale revisions")
        return { kind = "stale" }
      end
      prepared.publish()
      return { kind = "changed" }
    end,
  }
  return SummaryScreenState.new({
    mons = mons,
    manifest = family,
    measureDisplay = measurement,
    subjectPort = subjectPort,
    mode = "summary",
    initialSlot = initialSlot or 0,
    context = function()
      return SummaryPresentationFixture.context(#occupied)
    end,
    readNavigation = function()
      return nil
    end,
    acquirePreparation = function()
      return lease
    end,
  })
end

local function settleToActive(state)
  for _ = 1, 30 do
    if state:status().wrapperPhase == "active" then
      break
    end
    state:updateFixed({})
  end
  Assert.equal(state:status().wrapperPhase, "active", "the boxed summary settles into its interactive state")
  -- Preparation and entry gate the controller: one live tick publishes its first snapshot.
  state:updateFixed({})
end

local function boxedService(entries, slots)
  local mons = service()
  local catalog = mons:catalog()
  local factory = CatalogFixture.makeFactory(0xB0517711, catalog)
  local updates = {}
  for index, entry in ipairs(entries) do
    local mon =
      factory:createNormal(CatalogFixture.normalRequest({ species = entry.species, form = entry.form or 0 }))
    updates[#updates + 1] = { box = 0, slot = slots[index], mon = mon }
  end
  local prepared = assert(
    mons:preparePcChanges({
      partyRevision = mons:partyRevision(),
      boxRevision = mons:boxRevision(),
    }, { boxUpdates = updates })
  )
  prepared.publish()
  return mons
end

function T.mon_projection_accepts_a_detached_box_subject()
  local mons = service()
  local boxed = storeBoxCopy(mons)
  local revision = mons:boxRevision()
  local reader = {
    partyCount = function()
      return 1
    end,
    partyRevision = function()
      return revision
    end,
    partyMon = function(_, index)
      Assert.equal(index, 0, "detached reads stay inside the occupied set")
      return boxed
    end,
    catalog = function()
      return mons:catalog()
    end,
    derive = function(_, mon)
      return mons:derive(mon)
    end,
  }
  local facts =
    SummaryModel.build(reader, 0, SummaryPresentationFixture.context(1), SummaryPresentationFixture.manifest())
  local partyBefore = mons:partyMon(0)
  Assert.equal(facts.revision, revision)
  Assert.equal(facts.slot, 0, "summary controller index is the occupied-subject index")
  Assert.equal(facts.slotCount, 1)
  Assert.equal(facts.identity.species, "CHIKORITA", "facts come from the supplied boxed mon")
  Assert.isTrue(facts.indicators.leaves[1], "facts come from the supplied boxed mon")
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

function T.boxed_summary_opens_returns_and_leaves_party_and_box_untouched()
  local mons = service()
  storeBoxCopy(mons)
  local partyBefore = mons:partyMon(0)
  local boxBefore = assert(mons:boxMon(0, 4))
  local captured = {}
  local state = openBoxSummary(mons, { 4 }, captured, 0)
  settleToActive(state)
  local status = state:status()
  Assert.equal(status.slot, 0, "the boxed summary selects the requested occupied subject")
  Assert.equal(status.facts.slotCount, 1, "the boxed summary spans the occupied set")
  Assert.equal(status.facts.moves[1].key, "TACKLE", "the boxed summary projects the boxed mon")
  Assert.isTrue(status.facts.indicators.leaves[1], "the displayed facts belong to the boxed mon")
  state:updateFixed({ { type = "cancel" } })
  local result = state:takeResult()
  Assert.notNil(result, "closing the boxed summary reports its child result")
  assert(result ~= nil, "closing reports above")
  Assert.equal(result.kind, "return", "a read-only close returns to the storage caller")
  Assert.deepEqual(mons:partyMon(0), partyBefore, "opening a boxed summary never rewrites Party")
  Assert.deepEqual(mons:boxMon(0, 4), boxBefore, "closing without edits never rewrites the box")
  state:dispose()
end

function T.boxed_summary_past_party_range_keeps_demand_on_the_selected_subject()
  local mons = boxedService({
    { species = "CHIKORITA" },
    { species = "TOTODILE" },
    { species = "EEVEE" },
    { species = "EEVEE", form = 1 },
    { species = "CHIKORITA" },
    { species = "TOTODILE" },
    { species = "SHEDINJA" },
  }, { 2, 5, 9, 14, 19, 24, 29 })
  local captured = {}
  local state = openBoxSummary(mons, { 2, 5, 9, 14, 19, 24, 29 }, captured, 0)
  settleToActive(state)
  Assert.equal(
    state:status().facts.identity.species,
    "CHIKORITA",
    "dense indexes start on the first occupied slot"
  )
  for _ = 1, 6 do
    state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  for _ = 1, 6 do
    state:updateFixed({})
  end
  local status = state:status()
  Assert.equal(status.slot, 6, "boxed navigation traverses the whole occupied set")
  Assert.equal(status.facts.slotCount, 7, "the boxed summary spans every occupied subject")
  Assert.equal(status.facts.identity.species, "SHEDINJA", "dense index six reads the seventh occupied slot")
  local demand = assert(captured[#captured], "the wrapper prepares demand for the selection")
  Assert.equal(#demand.portraitSelectors, 1, "boxed preparation carries only the selected portrait")
  Assert.equal(
    demand.portraitSelectors[1],
    status.facts.portraitSelector,
    "boxed demand follows the selection"
  )
  Assert.deepEqual(demand.iconKeys, { status.facts.iconKey }, "boxed preparation carries only the selected icon")
  Assert.equal(demand.revision, mons:boxRevision(), "boxed demand keys off the box revision")
  state:dispose()
end

function T.boxed_reorder_publishes_guarded_and_stale_attempts_write_nothing()
  local mons = service()
  storeBoxCopy(mons)
  local catalog = mons:catalog()
  local factory = CatalogFixture.makeFactory(0xB0517712, catalog)
  local unrelated =
    factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
  local stored = assert(
    mons:preparePcChanges({
      partyRevision = mons:partyRevision(),
      boxRevision = mons:boxRevision(),
    }, { boxUpdates = { { box = 0, slot = 10, mon = unrelated } } })
  )
  stored.publish()
  local partyBefore = mons:partyMon(0)
  local unrelatedBefore = assert(mons:boxMon(0, 10))
  local captured = {}
  local state = openBoxSummary(mons, { 4, 10 }, captured, 0)
  settleToActive(state)
  local fresh = mons:boxRevision()
  local first = state:reorderMoves(0, 0, 1, fresh)
  Assert.equal(first.kind, "changed", "the boxed reorder publishes through the box guard")
  local swapped = assert(mons:boxMon(0, 4))
  Assert.equal(swapped.moves[1].move, "GROWL", "the boxed reorder swaps whole move entries")
  Assert.equal(swapped.moves[2].move, "TACKLE", "the boxed reorder swaps whole move entries")
  Assert.equal(mons:boxRevision(), fresh + 1, "one boxed reorder advances the box revision once")
  Assert.deepEqual(mons:boxMon(0, 10), unrelatedBefore, "the boxed reorder leaves unrelated subjects alone")
  Assert.deepEqual(mons:partyMon(0), partyBefore, "the boxed reorder never passes through Party")
  local edited = {}
  for key, value in pairs(unrelatedBefore) do
    edited[key] = value
  end
  edited.markings = (assert(unrelatedBefore.markings, "stored mons carry markings") + 1) % 256
  local advanced = assert(
    mons:preparePcChanges({
      partyRevision = mons:partyRevision(),
      boxRevision = mons:boxRevision(),
    }, { boxUpdates = { { box = 0, slot = 10, mon = edited } } })
  )
  advanced.publish()
  Assert.equal(mons:boxRevision(), fresh + 2, "the external edit advances the box revision")
  local stale = state:reorderMoves(0, 1, 0, fresh + 1)
  Assert.equal(stale.kind, "stale", "a behind box revision refuses publication")
  Assert.equal(mons:boxRevision(), fresh + 2, "the stale attempt advances nothing")
  local kept = assert(mons:boxMon(0, 4))
  Assert.equal(kept.moves[1].move, "GROWL", "the stale attempt writes nothing to the selected subject")
  Assert.equal(kept.moves[2].move, "TACKLE", "the stale attempt writes nothing to the selected subject")
  state:dispose()
end

return { tests = T }
