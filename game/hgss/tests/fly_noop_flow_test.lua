-- Checked Fly no-op inside the bounded menu flow: a learned Fly passing
-- eligibility restores Party on the same slot with no mon, bag, PP, task,
-- or save mutation, and fresh input keeps working. Runs without a ROM by
-- extending the fixture catalogs locally (HM02, FLY, PIDGEY); shared
-- fixtures stay untouched.

local Assert = require("tests.support.Assert")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GameVersion = require("romdump.src.source.GameVersion")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyActions = require("libs.hgss.src.field.PartyActions")
local PartyCache = require("libs.assets.src.PartyCache")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local PokemonMenuFlow = require("game.hgss.src.field.PokemonMenuFlow")

local T = {
  metadata = { capabilities = { "rom_dump", "derived_assets" },
  derivedAssets = { "party:global" }, },
  tests = {},
}

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, child in pairs(value) do
    copy[key] = deepCopy(child)
  end
  return copy
end

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local marker = cacheFs:read(PartyCache.markerPath())
      if marker ~= nil and PartyCache.isReady(cacheFs, marker) then
        versions[#versions + 1] = versionId
      end
    end
  end
  return versions
end

local function extendedMonRoot()
  local root = deepCopy(CatalogFixture.buildAssetRoot())
  root.moves.FLY = {
    nativeId = 19,
    name = "Fly",
    description = "Flies to a known town.",
    effect = 0,
    category = "physical",
    power = 90,
    moveType = "flying",
    accuracy = 95,
    basePp = 15,
    effectChance = 0,
    range = 0,
    priority = 0,
    flags = 0,
    unknownC = 0,
    contestType = 0,
  }
  local pidgey = deepCopy(assert(root.species.TOTODILE, "fixture carries a donor species"))
  pidgey.nativeId = 16
  pidgey.name = "PIDGEY"
  pidgey.forms[0].types = { "normal", "flying" }
  pidgey.forms[0].tmhm[#pidgey.forms[0].tmhm + 1] = "FLY"
  root.species.PIDGEY = pidgey
  return root
end

local function openMons(seed, root, items)
  local catalog = MonCatalog.new(root, items)
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

local function openBag()
  local root = ItemFixture.buildAssetRoot()
  -- The 420..427 placeholders already carry HM-shaped machine records;
  -- retarget 421 to the Fly move locally instead of adding a key.
  root.items.ITEM_421.tmhmMoveNativeId = 19
  return HgssBagService.new({ catalog = ItemCatalog.new(root) })
end

local function stubMeasurement()
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "fly-noop-test:256x192",
  }
end

local function openFlow(Flow, opts)
  return Flow.new({
    root = "party",
    mons = assert(opts.mons, "the flow borrows the mon service"),
    bag = assert(opts.bag, "the flow borrows the bag service"),
    bagCursor = assert(opts.bagCursor, "the flow borrows the bag cursor"),
    partyActions = assert(opts.partyActions, "the flow borrows the action coordinator"),
    fieldMoves = {
      check = function(_)
        return { kind = "ok" }
      end,
    },
    assets = {
      bagManifest = {},
      partyManifest = assert(opts.partyManifest, "the flow borrows the party manifest"),
      uiManifest = FieldUiFixture.manifest(),
      monCatalog = {
        moveByNativeId = function()
          error("fly acceptance needs no move catalog lookup", 0)
        end,
      },
      itemCatalog = opts.bag:catalog(),
      heroGender = "male",
    },
    measureDisplay = stubMeasurement,
    prepareIcons = function(_)
      return true
    end,
    cancelIconPreparation = function() end,
  })
end

local function childView(flow)
  local status = flow:status()
  Assert.isTrue(status.open, "the party flow stays open")
  return assert(status.child, "the party flow holds a live child")
end

local function focusSlot(flow, slot)
  -- A fresh screen reports no cursor while icon preparation pends:
  -- wait for the visible cursor before navigating.
  for _ = 1, 30 do
    if childView(flow).cursorNode ~= nil then
      break
    end
    flow:updateFixed({})
  end
  for _ = 1, 12 do
    if childView(flow).cursorNode == slot then
      return
    end
    flow:updateFixed({ { type = "navigate", direction = "down" } })
  end
  error("slot focus never settled on " .. tostring(slot), 0)
end

local function activateMenuMove(flow, move)
  flow:updateFixed({ { type = "confirm" } })
  for _ = 1, 30 do
    local child = childView(flow)
    local menu = assert(child.menu, "slot confirm must open the action menu")
    local current = menu[child.menuIndex]
    if current ~= nil and current.move == move then
      flow:updateFixed({ { type = "confirm" } })
      return
    end
    flow:updateFixed({ { type = "navigate", direction = "down" } })
  end
  error("the action menu never offered " .. move, 0)
end

local function liveComposition(versionId)
  local Flow = PokemonMenuFlow
  local bag = openBag()
  local mons = openMons(0xF1700001, extendedMonRoot(), bag:catalog())
  Assert.isTrue(
    mons:giveMon({
      species = "PIDGEY",
      level = 5,
      heldItem = "NONE",
      form = 0,
      location = 7,
      date = CatalogFixture.metDate(),
    }),
    "setup gift must enter the party"
  )
  Assert.isTrue(bag:add("ITEM_421", 1), "setup must stock the fly HM")
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local outcome = actions:commit({
    kind = "teach_move",
    slot = 0,
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
    item = "ITEM_421",
  })
  Assert.equal(outcome.kind, "changed", "ITEM_421 must teach, got " .. tostring(outcome.kind))
  local cacheFs = CacheFs.forVersion(versionId)
  local flow = openFlow(Flow, {
    mons = mons,
    bag = bag,
    bagCursor = BagCursor.new(),
    partyActions = actions,
    partyManifest = PartyCache.loadManifest(cacheFs),
  })
  return { flow = flow, mons = mons, bag = bag }
end

function T.tests.checked_fly_restores_party_without_mutation(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("checked fly needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId)
    local flow = rig.flow
    local status = flow:status()
    Assert.isTrue(status.open, "the party flow opens")
    Assert.equal(status.page, "party_browse", "a party root opens the party page")
    local monRevision = rig.mons:partyRevision()
    local bagRevision = rig.bag:revision()
    local flyPp = nil
    for _, entry in ipairs(assert(rig.mons:partyMon(0).moves, "fly mon carries moves")) do
      if entry.move == "FLY" then
        flyPp = entry.pp
      end
    end
    Assert.notNil(flyPp, "the setup must teach fly before the no-op leg")
    focusSlot(flow, 0)
    activateMenuMove(flow, "FLY")
    status = flow:status()
    Assert.isTrue(status.open, "checked fly keeps the party flow open")
    Assert.equal(status.page, "party_browse", "checked fly returns to party browse")
    Assert.isNil(flow:takeResult(), "checked fly reports no terminal result")
    Assert.equal(rig.mons:partyRevision(), monRevision, "checked fly must not publish mon changes")
    Assert.equal(rig.bag:revision(), bagRevision, "checked fly must not consume items")
    local flyPpAfter = nil
    for _, entry in ipairs(assert(rig.mons:partyMon(0).moves, "fly mon carries moves")) do
      if entry.move == "FLY" then
        flyPpAfter = entry.pp
      end
    end
    Assert.equal(flyPpAfter, flyPp, "checked fly must not spend move PP")
    flow:updateFixed({ { type = "pointer_up", pointerId = "mouse:1", x = 0, y = 0 } })
    Assert.isNil(flow:takeResult(), "a stale release must not complete anything")
    focusSlot(flow, 0)
    flow:updateFixed({ { type = "confirm" } })
    Assert.notNil(childView(flow).menu, "fresh input opens a new action menu after the no-op")
    flow:updateFixed({ { type = "cancel" } })
    flow:dispose()
    flow:dispose()
  end
end

return { tests = T.tests }
