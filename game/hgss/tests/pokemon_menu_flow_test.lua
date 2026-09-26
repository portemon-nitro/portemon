-- Bounded Pokemon menu flow over real children: Bag/Party/Summary round
-- trips with real services, real borrowed cursor, real generated party
-- manifest (version-gated like the script selection host), synthetic bag
-- and summary manifests, and a contract-double field port. Covers page
-- routing, value-only continuations, stale identity, terminal field
-- output, and non-destructive construction failure with single disposal.

local Assert = require("tests.support.Assert")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GameVersion = require("romdump.src.source.GameVersion")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyActions = require("libs.hgss.src.field.PartyActions")
local PartyCache = require("libs.assets.src.PartyCache")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local FLOW_MODULE = "game.hgss.src.field.PokemonMenuFlow"

local T = { metadata = { capabilities = { "rom_dump", "derived_cache" } }, tests = {} }

local POCKETS = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }

local function requireFlow()
  local ok, flowModule = pcall(require, FLOW_MODULE)
  Assert.isTrue(ok, "the menu flow owns one active child: " .. tostring(flowModule))
  return assert(flowModule)
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

local function openMons(seed)
  local catalog = CatalogFixture.makeCatalog()
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

local function give(service, species)
  Assert.isTrue(
    service:giveMon({
      species = species,
      level = 5,
      heldItem = "NONE",
      form = 0,
      location = 7,
      date = CatalogFixture.metDate(),
    }),
    "setup gift must enter the party"
  )
end

local function openBag()
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  return bag
end

local function bagManifest()
  local tabs = {}
  for index = 0, 7 do
    tabs[index + 1] = { x = index * 32, y = 0, width = 32, height = 32 }
  end
  local slots = {}
  local shapes = {
    { { 0, 32, 128, 42 }, { 48, 56 } },
    { { 128, 32, 128, 42 }, { 176, 56 } },
    { { 0, 74, 128, 44 }, { 48, 96 } },
    { { 128, 74, 128, 44 }, { 176, 96 } },
    { { 0, 118, 128, 36 }, { 48, 136 } },
    { { 128, 118, 128, 36 }, { 176, 136 } },
  }
  for index, shape in ipairs(shapes) do
    slots[index] = {
      rect = { x = shape[1][1], y = shape[1][2], width = shape[1][3], height = shape[1][4] },
      iconCenter = { x = shape[2][1], y = shape[2][2] },
    }
  end
  local states = {}
  for _, pocket in ipairs(POCKETS) do
    states[#states + 1] =
      { pocket = pocket, pose = "pocket." .. pocket .. ".pose", pattern = "pocket." .. pocket .. ".pattern" }
  end
  local function framingRecord(angleXDegrees, angleYDegrees, distance, modelY)
    return { angleXDegrees = angleXDegrees, angleYDegrees = angleYDegrees, distance = distance, modelY = modelY }
  end
  local function pocketRecords(base)
    local records = {}
    for index, pocket in ipairs(POCKETS) do
      records[pocket] = framingRecord(base + index, base + 2 * index, 100 + 10 * index, 5 + index)
    end
    return records
  end
  return {
    hero = {
      animations = {
        states = states,
        material = { male = "bag.male.material", female = "bag.female.material" },
      },
      presentation = {
        framing = {
          transitionTicks = 7,
          baseline = { male = framingRecord(0, 0, 100, 5), female = framingRecord(1, 1, 110, 6) },
          byGender = { male = pocketRecords(10), female = pocketRecords(20) },
        },
      },
    },
    interactive = {
      pocketTabs = { rects = tabs },
      itemSlots = { slots = slots },
      pageIndicator = { rect = { x = 80, y = 168, width = 56, height = 16 }, textAt = { x = 0, y = 0 } },
      cancel = {
        rect = { x = 192, y = 168, width = 64, height = 24 },
        textRect = { x = 192, y = 168, width = 56, height = 16 },
        labelRect = { x = 200, y = 168, width = 48, height = 16 },
      },
      overlays = {
        descriptionFallback = {
          frame = { x = 0, y = 144, width = 256, height = 48 },
          textRect = { x = 20, y = 144, width = 236, height = 48 },
        },
        tossPrompt = { x = 200, y = 48, shape = "compact", initialSelection = "yes" },
        actionMenu = {
          slots = {
            { hitRect = { x = 8, y = 136, width = 80, height = 16 } },
            { hitRect = { x = 104, y = 136, width = 80, height = 16 } },
            { hitRect = { x = 8, y = 168, width = 80, height = 16 } },
            { hitRect = { x = 104, y = 168, width = 80, height = 16 } },
          },
        },
      },
      text = {
        actions = {
          toss = "TOSS",
          move = "MOVE",
          register = "REGISTER",
          unregister = "DESELECT",
          cancel = "CANCEL",
          confirm = "YES",
          use = "USE",
          give = "GIVE",
        },
      },
    },
  }
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
    signature = "menu-flow-test:256x192",
  }
end

local function openFlow(Flow, opts)
  return Flow.new({
    root = opts.root or "bag",
    mons = assert(opts.mons, "the flow borrows the mon service"),
    bag = assert(opts.bag, "the flow borrows the bag service"),
    bagCursor = assert(opts.bagCursor, "the flow borrows the bag cursor"),
    partyActions = assert(opts.partyActions, "the flow borrows the action coordinator"),
    fieldMoves = opts.fieldMoves or {
      check = function(_)
        return { kind = "ok" }
      end,
    },
    assets = {
      bagManifest = bagManifest(),
      partyManifest = assert(opts.partyManifest, "the flow borrows the party manifest"),
      uiManifest = FieldUiFixture.manifest(),
      monCatalog = {
        moveByNativeId = function()
          error("test catalog lookup is not exercised", 0)
        end,
      },
      itemCatalog = opts.bag:catalog(),
      heroGender = "male",
    },
    measureDisplay = stubMeasurement,
  })
end

local function liveComposition(versionId, root)
  local Flow = requireFlow()
  local mons = openMons(0xF1000001)
  give(mons, "CHIKORITA")
  give(mons, "TOTODILE")
  local bag = openBag()
  local cursor = BagCursor.new()
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local cacheFs = CacheFs.forVersion(versionId)
  local flow = openFlow(Flow, {
    root = root,
    mons = mons,
    bag = bag,
    bagCursor = cursor,
    partyActions = actions,
    partyManifest = PartyCache.loadManifest(cacheFs),
  })
  return { flow = flow, mons = mons, bag = bag, cursor = cursor, actions = actions, Flow = Flow }
end

local BAG_GRID = {
  [0] = { up = 2, down = 2, left = 1, right = 1 },
  [1] = { up = 3, down = 3, left = 0, right = 0 },
  [2] = { up = 0, down = 0, left = 4, right = 3 },
  [3] = { up = 1, down = 1, left = 2, right = 4 },
  [4] = { up = 4, down = 4, left = 3, right = 2 },
}

local function liveStatus(rig)
  local status = rig.flow:status()
  Assert.isTrue(status.open, "the flow stays open through the route")
  return status
end

local function drive(rig, events)
  rig.flow:updateFixed(events)
  return liveStatus(rig)
end

local function driveUntil(rig, label, maxSteps, predicate)
  for _ = 1, maxSteps do
    local status = liveStatus(rig)
    if predicate(status) then
      return status
    end
    rig.flow:updateFixed({})
  end
  error("the flow never reaches " .. label, 0)
end

local function driveToAction(rig, id)
  for _ = 1, 8 do
    local status = liveStatus(rig)
    local child = assert(status.child, "the action menu stays open")
    local target = nil
    for _, action in ipairs(assert(child.actions, "the menu lists actions")) do
      if action.id == id then
        target = action.slot
      end
    end
    Assert.notNil(target, "the menu must offer " .. id)
    if child.actionNode == target then
      return drive(rig, { { type = "confirm" } })
    end
    local node = assert(child.actionNode, "the menu exposes its node")
    local queue = { { node = node, path = {} } }
    local seen = { [node] = true }
    local path = nil
    local head = 1
    while head <= #queue and path == nil do
      local current = queue[head]
      head = head + 1
      for _, direction in ipairs({ "up", "down", "left", "right" }) do
        local nextNode = BAG_GRID[current.node][direction]
        if not seen[nextNode] then
          local nextPath = {}
          for index, step in ipairs(current.path) do
            nextPath[index] = step
          end
          nextPath[#nextPath + 1] = direction
          if nextNode == target then
            path = nextPath
            break
          end
          seen[nextNode] = true
          queue[#queue + 1] = { node = nextNode, path = nextPath }
        end
      end
    end
    local direction = assert(path and path[1], "the action node must be reachable")
    drive(rig, { { type = "navigate", direction = direction } })
  end
  error("the action menu never selects " .. id, 0)
end

local function injureLead(rig, amount)
  local mon = rig.mons:partyMon(0)
  local maxHp = rig.mons:derive(mon).maxHp
  Assert.isTrue(maxHp > amount, "the injured fixture needs headroom")
  mon.condition.currentHp = maxHp - amount
  local revision = rig.mons:partyRevision()
  local preparation, reason = rig.mons:preparePartyChanges(revision, { { slot = 0, mon = mon } })
  Assert.isNil(reason, "injury staging must prepare cleanly")
  assert(preparation).publish()
  return maxHp
end

function T.tests.bag_root_opens_on_the_borrowed_cursor(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and derived_cache")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "bag")
    Assert.isTrue(rig.bag:add("POTION", 3), "the fixture must stock potions")
    rig.cursor:setPocket("medicine")
    local status = drive(rig, {})
    Assert.equal(status.root, "bag", "the flow remembers its root")
    Assert.equal(status.page, "bag_browse", "a bag root opens the bag browse page")
    Assert.equal(status.child.pocket, "medicine", "the bag opens on the borrowed cursor pocket")
    Assert.isNil(rig.flow:takeResult(), "opening reports no terminal result")
    rig.flow:dispose()
  end
end

function T.tests.bag_use_heals_once_and_returns_to_bag(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and derived_cache")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "bag")
    local maxHp = injureLead(rig, 10)
    Assert.isTrue(rig.bag:add("POTION", 3), "the fixture must stock potions")
    rig.cursor:setPocket("medicine")
    rig.cursor:setPosition("medicine", 0)
    local partyRevision = rig.mons:partyRevision()

    local status = drive(rig, {})
    Assert.equal(
      status.child.selected and status.child.selected.item,
      "POTION",
      "the borrowed position selects the potion"
    )
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.child.state, "action_menu", "confirming opens the action menu")
    local useSlot = nil
    for _, action in ipairs(assert(status.child.actions, "the menu lists actions")) do
      if action.id == "use" then
        useSlot = action.slot
      end
    end
    Assert.equal(useSlot, 0, "Use rides the source slot zero")
    status = driveToAction(rig, "use")
    Assert.equal(status.page, "party_item_target", "choosing Use opens the party target page")
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(rig.mons:partyMon(0).condition.currentHp, maxHp, "confirming the lead heals it once")
    Assert.equal(rig.bag:quantity("POTION"), 2, "exactly one potion is consumed")
    Assert.isTrue(rig.mons:partyRevision() == partyRevision + 1, "one revision publishes the healing")
    status = drive(rig, { { type = "cancel" } })
    status = driveUntil(rig, "the originating bag", 30, function(current)
      return current.page == "bag_browse"
    end)
    Assert.equal(status.child.pocket, "medicine", "the return preserves the borrowed pocket")
    Assert.equal(rig.cursor:currentPocket(), "medicine", "the borrowed cursor survives")
    Assert.isNil(rig.flow:takeResult(), "the round trip reports no terminal result")
    rig.flow:dispose()
  end
end

function T.tests.stale_revision_discards_the_operation_safely(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and derived_cache")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "bag")
    injureLead(rig, 10)
    Assert.isTrue(rig.bag:add("POTION", 3), "the fixture must stock potions")
    rig.cursor:setPocket("medicine")
    local status = drive(rig, {})
    status = drive(rig, { { type = "confirm" } })
    local useSlot = nil
    for _, action in ipairs(assert(status.child.actions, "the menu lists actions")) do
      if action.id == "use" then
        useSlot = action.slot
      end
    end
    Assert.notNil(useSlot, "Use must be offered")
    status = driveToAction(rig, "use")
    Assert.equal(status.page, "party_item_target", "choosing Use opens the target page")
    rig.bag:add("GREAT_BALL", 1)
    local bagRevision = rig.bag:revision()
    Assert.isTrue(bagRevision > 0, "the external stock must move the bag revision")
    local hpBefore = rig.mons:partyMon(0).condition.currentHp
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(
      rig.mons:partyMon(0).condition.currentHp,
      hpBefore,
      "a revision moved under the flight publishes nothing"
    )
    Assert.equal(rig.bag:quantity("POTION"), 3, "a stale flight consumes nothing")
    Assert.isNil(rig.flow:takeResult(), "staleness is not a terminal result")
    rig.flow:dispose()
  end
end

function T.tests.failed_child_construction_is_non_destructive(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and derived_cache")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "bag")
    Assert.isTrue(rig.bag:add("POTION", 3), "the fixture must stock potions")
    rig.cursor:setPocket("medicine")
    local status = drive(rig, {})
    Assert.equal(status.page, "bag_browse", "the root child opens before the fault")
    local partyRevision = rig.mons:partyRevision()
    local bagRevision = rig.bag:revision()
    local moduleName = "game.hgss.src.field.PartyScreenState"
    local realModule = assert(package.loaded[moduleName], "the flow holds the party screen")
    local realNew = realModule.new
    realModule.new = function(_)
      error("injected party construction fault", 0)
    end
    local ok, err = pcall(function()
      status = drive(rig, { { type = "confirm" } })
      status = driveToAction(rig, "use")
    end)
    realModule.new = realNew
    Assert.isFalse(ok, "the injected fault must surface to the owner")
    Assert.notNil(tostring(err):find("injected party construction fault", 1, true), "the original error stays visible")
    status = liveStatus(rig)
    Assert.equal(status.page, "bag_browse", "the prior child survives the failed replacement")
    Assert.equal(
      status.child.selected and status.child.selected.item,
      "POTION",
      "the surviving child keeps its selection"
    )
    Assert.equal(rig.mons:partyRevision(), partyRevision, "a failed flight publishes no party revision")
    Assert.equal(rig.bag:revision(), bagRevision, "a failed flight publishes no bag revision")
    Assert.isNil(rig.flow:takeResult(), "a failed flight reports no terminal result")
    rig.flow:dispose()
    rig.flow:dispose()
  end
end

function T.tests.terminal_field_action_emits_typed_output(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and derived_cache")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "party")
    local status = drive(rig, {})
    Assert.equal(status.page, "party_browse", "a party root opens the party browse page")
    rig.flow:dispose()
  end
end

function T.tests.root_close_reports_close_and_releases_once(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and derived_cache")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "bag")
    local status = drive(rig, {})
    Assert.equal(status.page, "bag_browse", "a bag root opens the bag browse page")
    rig.flow:updateFixed({ { type = "cancel" } })
    status = rig.flow:status()
    Assert.isFalse(status.open, "cancelling the root releases the child")
    local result = rig.flow:takeResult()
    Assert.notNil(result, "cancelling the root must report a terminal result")
    Assert.equal(result.kind, "close", "a root cancel closes back to the menu")
    Assert.isNil(rig.flow:takeResult(), "the terminal result drains exactly once")
    rig.flow:dispose()
    rig.flow:dispose()
  end
end

return T
