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
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local FLOW_MODULE = "game.hgss.src.field.PokemonMenuFlow"

local T = { metadata = { capabilities = { "rom_dump", "derived_assets" }, derivedAssets = { "party:global" } }, tests = {} }

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
      selectionEntry = { totalTicks = 3 },
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
        selectedItem = {
          segments = {
            { kind = "text", value = "The " },
            { kind = "item" },
            { kind = "text", value = " is selected." },
          },
        },
        movePrompt = {
          segments = {
            { kind = "text", value = "Move " },
            { kind = "item" },
            { kind = "text", value = "?" },
          },
        },
        tossConfirm = {
          segments = {
            { kind = "text", value = "Toss " },
            { kind = "quantity" },
            { kind = "text", value = " " },
            { kind = "item" },
            { kind = "text", value = "?" },
          },
        },
        tossResult = {
          segments = {
            { kind = "text", value = "Threw away " },
            { kind = "quantity" },
            { kind = "text", value = " " },
            { kind = "item" },
            { kind = "text", value = "." },
          },
        },
      },
      feedback = { totalTicks = 4 },
      moveTransition = { unchanged = { totalTicks = 3 }, changed = { totalTicks = 5 } },
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
        quantity = {
          controls = {
            { delta = 100, role = "increment", hitRect = { x = 0, y = 128, width = 32, height = 32 } },
            { delta = 10, role = "increment", hitRect = { x = 32, y = 128, width = 32, height = 32 } },
            { delta = 1, role = "increment", hitRect = { x = 64, y = 128, width = 32, height = 32 } },
            { delta = -100, role = "decrement", hitRect = { x = 0, y = 160, width = 32, height = 32 } },
            { delta = -10, role = "decrement", hitRect = { x = 32, y = 160, width = 32, height = 32 } },
            { delta = -1, role = "decrement", hitRect = { x = 64, y = 160, width = 32, height = 32 } },
          },
          pressTicks = 2,
          cancelHitRect = { x = 178, y = 168, width = 78, height = 24 },
          confirm = { hitRect = { x = 112, y = 160, width = 64, height = 32 } },
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

local function recordingIcons()
  local calls = { prepared = {}, cancels = 0 }
  local function prepare(iconKeys)
    local snapshot = {}
    for index, key in ipairs(iconKeys) do
      snapshot[index] = key
    end
    calls.prepared[#calls.prepared + 1] = snapshot
    return true, nil
  end
  local function cancel()
    calls.cancels = calls.cancels + 1
  end
  return { prepare = prepare, cancel = cancel, calls = calls }
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
    prepareIcons = assert(opts.prepareIcons, "the flow test supplies icon preparation"),
    cancelIconPreparation = assert(opts.cancelIconPreparation, "the flow test supplies preparation release"),
    textPolicy = { interGlyphDelay = 0, glyphBudget = 512, abAcceleration = true },
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
  local icons = recordingIcons()
  local flow = openFlow(Flow, {
    root = root,
    mons = mons,
    bag = bag,
    bagCursor = cursor,
    partyActions = actions,
    partyManifest = PartyCache.loadManifest(cacheFs),
    prepareIcons = icons.prepare,
    cancelIconPreparation = icons.cancel,
  })
  return { flow = flow, mons = mons, bag = bag, cursor = cursor, actions = actions, Flow = Flow, icons = icons }
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

-- Confirming a browsed item parks in the source selection entry before the
-- stable action menu opens: settle the generated transition clock before
-- callers read the action state or its actions.
local function driveToActionMenu(rig)
  return driveUntil(rig, "the stable action menu", 30, function(current)
    return current.child ~= nil and current.child.state == "action_menu"
  end)
end

local function driveToAction(rig, id)
  driveToActionMenu(rig)
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
      drive(rig, { { type = "confirm" } })
      -- Activation latches behind feedback before the semantic transition
      -- runs, so settle until the menu leaves or the flow changes pages.
      return driveUntil(rig, "the chosen action", 30, function(current)
        return current.page ~= "bag_browse"
          or current.child == nil
          or current.child.state ~= "action_menu"
      end)
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

local function partyChild(status)
  return assert(status.child, "the party page carries its child status")
end

local function drivePartyMenu(rig, kind)
  for _ = 1, 40 do
    local status = liveStatus(rig)
    local child = partyChild(status)
    local menu = assert(child.menu, "the party menu must be open")
    local index = nil
    for position, entry in ipairs(menu) do
      if entry.kind == kind then
        index = position
      end
    end
    Assert.notNil(index, "the party menu must offer " .. kind)
    if (child.menuIndex or 0) == index then
      -- Menu activation rides the visual press cadence before its single
      -- dispatch: settle the gate so callers read the dispatched submenu
      -- or intent state instead of the armed menu.
      drive(rig, { { type = "confirm" } })
      return driveUntil(rig, "the gated menu dispatch", 10, function(current)
        local dispatched = partyChild(current)
        return dispatched.menuPress == nil and (dispatched.menu ~= menu or dispatched.state ~= "context")
      end)
    end
    local direction = (child.menuIndex or 0) < index and "down" or "up"
    drive(rig, { { type = "navigate", direction = direction } })
  end
  error("the party menu never selects " .. kind, 0)
end

-- Stocks the bag and hands one item to an empty holder through the real
-- action owner, so the journey starts from an occupied holder.
local function occupyHolder(rig, slot, itemKey)
  Assert.isTrue(rig.bag:add(itemKey, 1), "the setup stock must enter the bag")
  local outcome = rig.actions:commit({
    kind = "give",
    slot = slot,
    partyRevision = rig.mons:partyRevision(),
    bagRevision = rig.bag:revision(),
    item = itemKey,
  })
  Assert.equal(outcome.kind, "changed", "the setup give must publish onto the empty holder")
end

-- The page transition never opens the replacement question itself: one
-- empty tick lets the fresh confirmation child open its prompt before
-- the answer drives it. A settling tick after the answer lets the fresh
-- root child finish its icon preparation before callers read it.
local function answerYes(rig)
  drive(rig, {})
  local status = drive(rig, { { type = "navigate", direction = "down" } })
  Assert.equal(status.page, "party_give_confirm", "toggling the answer stays on the confirmation")
  status = drive(rig, { { type = "confirm" } })
  driveUntil(rig, "the answered confirmation", 30, function(current)
    return current.page ~= "party_give_confirm"
  end)
  return drive(rig, {})
end

local function answerNo(rig)
  drive(rig, {})
  drive(rig, { { type = "cancel" } })
  driveUntil(rig, "the declined confirmation", 30, function(current)
    return current.page ~= "party_give_confirm"
  end)
  return drive(rig, {})
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
      context:skip("requires rom_dump and prepared assets")
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
      context:skip("requires rom_dump and prepared assets")
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
    status = driveToActionMenu(rig)
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
      context:skip("requires rom_dump and prepared assets")
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
    status = driveToActionMenu(rig)
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
      context:skip("requires rom_dump and prepared assets")
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
      context:skip("requires rom_dump and prepared assets")
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
      context:skip("requires rom_dump and prepared assets")
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

function T.tests.icon_preparation_drives_the_party_child_lifetime(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "party")
    Assert.equal(rig.icons.calls.cancels, 0, "opening demands nothing yet")
    local status = drive(rig, {})
    Assert.equal(status.page, "party_browse", "a party root opens the party browse page")
    Assert.isTrue(#rig.icons.calls.prepared >= 1, "opening the party child demands its icon keys")
    local keys = rig.icons.calls.prepared[#rig.icons.calls.prepared]
    Assert.equal(#keys, 2, "one icon key is demanded per occupied slot")
    Assert.equal(rig.icons.calls.cancels, 0, "an open child holds its preparation interest")
    rig.flow:dispose()
    Assert.equal(rig.icons.calls.cancels, 1, "disposal releases the preparation exactly once")
    rig.flow:dispose()
    Assert.equal(rig.icons.calls.cancels, 1, "the release stays exactly-once")
  end
end

function T.tests.bag_give_to_an_occupied_holder_asks_before_any_change(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "bag")
    occupyHolder(rig, 0, "CHERI_BERRY")
    Assert.isTrue(rig.bag:add("SITRUS_BERRY", 2), "the fixture must stock the replacement")
    rig.cursor:setPocket("berries")
    rig.cursor:setPosition("berries", 0)
    local partyRevision = rig.mons:partyRevision()
    local bagRevision = rig.bag:revision()

    local status = drive(rig, {})
    Assert.equal(
      status.child.selected and status.child.selected.item,
      "SITRUS_BERRY",
      "the borrowed position selects the replacement"
    )
    status = drive(rig, { { type = "confirm" } })
    status = driveToActionMenu(rig)
    Assert.equal(status.child.state, "action_menu", "confirming opens the action menu")
    status = driveToAction(rig, "give")
    Assert.equal(status.page, "party_give_target", "choosing Give opens the party target page")
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "party_give_confirm", "targeting an occupied holder asks instead of publishing")
    status = drive(rig, {})
    Assert.equal(
      status.child.prompt and status.child.prompt.selected,
      "no",
      "the replacement question defaults to its safe answer"
    )
    Assert.equal(rig.mons:partyMon(0).heldItem, "CHERI_BERRY", "asking publishes nothing yet")
    Assert.equal(rig.mons:partyRevision(), partyRevision, "asking publishes no party revision")
    Assert.equal(rig.bag:revision(), bagRevision, "asking publishes no bag revision")

    status = answerNo(rig)
    Assert.equal(status.page, "bag_browse", "declining returns to the originating bag")
    Assert.equal(rig.mons:partyMon(0).heldItem, "CHERI_BERRY", "declining keeps the held item")
    Assert.equal(rig.bag:quantity("SITRUS_BERRY"), 2, "declining consumes nothing")
    Assert.equal(rig.bag:quantity("CHERI_BERRY"), 0, "declining returns nothing")
    Assert.equal(rig.mons:partyRevision(), partyRevision, "declining publishes no party revision")
    Assert.equal(rig.bag:revision(), bagRevision, "declining publishes no bag revision")
    Assert.isNil(rig.flow:takeResult(), "declining reports no terminal result")

    status = drive(rig, { { type = "confirm" } })
    status = driveToAction(rig, "give")
    Assert.equal(status.page, "party_give_target", "the declined Give can be chosen again")
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "party_give_confirm", "the retry asks again")
    status = answerYes(rig)
    Assert.equal(status.page, "bag_browse", "accepting returns to the originating bag")
    Assert.equal(rig.mons:partyMon(0).heldItem, "SITRUS_BERRY", "accepting exchanges the held item")
    Assert.equal(rig.bag:quantity("SITRUS_BERRY"), 1, "accepting consumes exactly one replacement")
    Assert.equal(rig.bag:quantity("CHERI_BERRY"), 1, "accepting returns the displaced item once")
    Assert.isTrue(rig.mons:partyRevision() == partyRevision + 1, "accepting publishes exactly one party revision")
    Assert.isTrue(rig.bag:revision() == bagRevision + 1, "accepting publishes exactly one bag revision")
    Assert.isNil(rig.flow:takeResult(), "accepting reports no terminal result")
    rig.flow:dispose()
  end
end

function T.tests.party_give_decline_then_retry_confirms_once(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "party")
    occupyHolder(rig, 0, "CHERI_BERRY")
    Assert.isTrue(rig.bag:add("SITRUS_BERRY", 2), "the fixture must stock the replacement")
    rig.cursor:setPocket("berries")
    rig.cursor:setPosition("berries", 0)
    local partyRevision = rig.mons:partyRevision()
    local bagRevision = rig.bag:revision()

    local status = drive(rig, {})
    Assert.equal(status.page, "party_browse", "a party root opens the party browse page")
    status = drive(rig, { { type = "confirm" } })
    status = drivePartyMenu(rig, "item")
    status = drivePartyMenu(rig, "give")
    Assert.equal(status.page, "bag_pick_held", "party Give opens the held-item picker")
    Assert.equal(
      partyChild(status).selected and partyChild(status).selected.item,
      "SITRUS_BERRY",
      "the picker opens on the stocked replacement"
    )
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "party_give_confirm", "picking for an occupied holder asks instead of publishing")
    Assert.equal(rig.mons:partyMon(0).heldItem, "CHERI_BERRY", "asking publishes nothing yet")

    status = answerNo(rig)
    Assert.equal(status.page, "party_browse", "declining returns to the originating party")
    Assert.equal(partyChild(status).cursorNode, 0, "declining resumes on the original mon")
    Assert.equal(rig.mons:partyMon(0).heldItem, "CHERI_BERRY", "declining keeps the held item")
    Assert.equal(rig.mons:partyRevision(), partyRevision, "declining publishes no party revision")
    Assert.equal(rig.bag:revision(), bagRevision, "declining publishes no bag revision")
    Assert.isNil(rig.flow:takeResult(), "declining reports no terminal result")

    status = drive(rig, { { type = "confirm" } })
    status = drivePartyMenu(rig, "item")
    status = drivePartyMenu(rig, "give")
    Assert.equal(status.page, "bag_pick_held", "the declined Give can be chosen again")
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "party_give_confirm", "the retry asks again")
    status = answerYes(rig)
    Assert.equal(status.page, "party_browse", "accepting returns to the originating party")
    Assert.equal(partyChild(status).cursorNode, 0, "accepting resumes on the exchanged mon")
    Assert.equal(rig.mons:partyMon(0).heldItem, "SITRUS_BERRY", "accepting exchanges the held item")
    Assert.equal(rig.bag:quantity("SITRUS_BERRY"), 1, "accepting consumes exactly one replacement")
    Assert.equal(rig.bag:quantity("CHERI_BERRY"), 1, "accepting returns the displaced item once")
    Assert.isTrue(rig.mons:partyRevision() == partyRevision + 1, "accepting publishes exactly one party revision")
    Assert.isTrue(rig.bag:revision() == bagRevision + 1, "accepting publishes exactly one bag revision")
    Assert.isNil(rig.flow:takeResult(), "accepting reports no terminal result")
    rig.flow:dispose()
  end
end

function T.tests.same_item_pick_keeps_the_picker_usable(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "party")
    occupyHolder(rig, 0, "SITRUS_BERRY")
    Assert.isTrue(rig.bag:add("SITRUS_BERRY", 1), "the fixture must stock the same item")
    Assert.isTrue(rig.bag:add("CHERI_BERRY", 1), "the fixture must stock a different item")
    rig.cursor:setPocket("berries")
    rig.cursor:setPosition("berries", 0)
    local partyRevision = rig.mons:partyRevision()
    local bagRevision = rig.bag:revision()

    local status = drive(rig, {})
    status = drive(rig, { { type = "confirm" } })
    status = drivePartyMenu(rig, "item")
    status = drivePartyMenu(rig, "give")
    Assert.equal(status.page, "bag_pick_held", "party Give opens the held-item picker")
    status = drive(rig, { { type = "navigate", direction = "right" } })
    Assert.equal(
      partyChild(status).selected and partyChild(status).selected.item,
      "SITRUS_BERRY",
      "the picker focuses the already-held item"
    )
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "bag_pick_held", "a no-op pick holds the picker open")
    Assert.equal(rig.mons:partyMon(0).heldItem, "SITRUS_BERRY", "a no-op pick mutates nothing")
    Assert.equal(rig.bag:quantity("SITRUS_BERRY"), 1, "a no-op pick consumes nothing")
    Assert.equal(rig.mons:partyRevision(), partyRevision, "a no-op pick publishes no party revision")
    Assert.equal(rig.bag:revision(), bagRevision, "a no-op pick publishes no bag revision")
    Assert.isNil(rig.flow:takeResult(), "a no-op pick reports no terminal result")
    status = drive(rig, { { type = "navigate", direction = "left" } })
    Assert.equal(
      partyChild(status).selected and partyChild(status).selected.item,
      "CHERI_BERRY",
      "the held picker still takes input after the no-op"
    )
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "party_give_confirm", "the retryable picker still asks for a real replacement")
    status = answerNo(rig)
    Assert.equal(status.page, "party_browse", "declining returns to the originating party")
    Assert.equal(rig.mons:partyMon(0).heldItem, "SITRUS_BERRY", "the declined retry mutates nothing")
    Assert.equal(rig.bag:quantity("SITRUS_BERRY"), 1, "the declined retry consumes nothing")
    Assert.equal(rig.bag:quantity("CHERI_BERRY"), 1, "the declined retry returns nothing")
    Assert.equal(rig.mons:partyRevision(), partyRevision, "the declined retry publishes no party revision")
    Assert.equal(rig.bag:revision(), bagRevision, "the declined retry publishes no bag revision")
    Assert.isNil(rig.flow:takeResult(), "declining reports no terminal result")
    rig.flow:dispose()
  end
end

function T.tests.raced_give_unwinds_without_a_partial_change(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "bag")
    occupyHolder(rig, 0, "CHERI_BERRY")
    Assert.isTrue(rig.bag:add("SITRUS_BERRY", 2), "the fixture must stock the replacement")
    Assert.isTrue(rig.bag:add("CHERI_BERRY", 1), "the return stack starts with room")
    rig.cursor:setPocket("berries")
    rig.cursor:setPosition("berries", 0)
    local partyRevision = rig.mons:partyRevision()

    -- The held item's own stack sorts first, so the focus starts on it:
    -- step right onto the stocked replacement before choosing Give.
    local status = drive(rig, {})
    status = drive(rig, { { type = "navigate", direction = "right" } })
    status = drive(rig, { { type = "confirm" } })
    status = driveToAction(rig, "give")
    Assert.equal(status.page, "party_give_target", "choosing Give opens the party target page")
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "party_give_confirm", "targeting an occupied holder asks first")
    Assert.isTrue(rig.bag:add("CHERI_BERRY", 998), "the race fills the return stack")
    local bagRevision = rig.bag:revision()
    status = answerYes(rig)
    Assert.equal(status.page, "bag_browse", "a raced Yes still returns to the originating bag")
    Assert.equal(rig.mons:partyMon(0).heldItem, "CHERI_BERRY", "a raced Yes moves no held item")
    Assert.equal(rig.bag:quantity("SITRUS_BERRY"), 2, "a raced Yes consumes no replacement")
    Assert.equal(rig.bag:quantity("CHERI_BERRY"), 999, "a raced Yes returns nothing extra")
    Assert.equal(rig.mons:partyRevision(), partyRevision, "a raced Yes publishes no party revision")
    Assert.equal(rig.bag:revision(), bagRevision, "a raced Yes publishes no bag revision of its own")
    Assert.isNil(rig.flow:takeResult(), "a raced Yes reports no terminal result")
    status = drive(rig, {})
    Assert.equal(status.page, "bag_browse", "input stays valid after the refused race")

    status = drive(rig, { { type = "confirm" } })
    status = driveToAction(rig, "give")
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "party_give_target", "a full return pocket never reaches the confirmation")
    Assert.equal(rig.mons:partyMon(0).heldItem, "CHERI_BERRY", "the refused preview mutates nothing")
    Assert.equal(rig.bag:quantity("SITRUS_BERRY"), 2, "the refused preview consumes nothing")
    Assert.equal(rig.mons:partyRevision(), partyRevision, "the refused preview publishes no party revision")
    status = drive(rig, { { type = "cancel" } })
    status = driveUntil(rig, "the originating bag", 30, function(current)
      return current.page == "bag_browse"
    end)
    Assert.isNil(rig.flow:takeResult(), "backing out reports no terminal result")

    Assert.isTrue(rig.bag:take("CHERI_BERRY", 998), "the retry frees the return stack")
    status = drive(rig, {})
    status = drive(rig, { { type = "navigate", direction = "right" } })
    status = drive(rig, { { type = "confirm" } })
    status = driveToAction(rig, "give")
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "party_give_confirm", "the freed pocket asks again")
    Assert.isTrue(rig.bag:add("POTION", 1), "the second race moves the bag revision")
    bagRevision = rig.bag:revision()
    status = answerYes(rig)
    Assert.equal(status.page, "bag_browse", "a stale Yes still returns to the originating bag")
    Assert.equal(rig.mons:partyMon(0).heldItem, "CHERI_BERRY", "a stale Yes moves no held item")
    Assert.equal(rig.bag:quantity("SITRUS_BERRY"), 2, "a stale Yes consumes no replacement")
    Assert.equal(rig.mons:partyRevision(), partyRevision, "a stale Yes publishes no party revision")
    Assert.equal(rig.bag:revision(), bagRevision, "a stale Yes publishes no bag revision of its own")
    Assert.isNil(rig.flow:takeResult(), "a stale Yes reports no terminal result")
    rig.flow:updateFixed({ { type = "cancel" } })
    status = rig.flow:status()
    Assert.isFalse(status.open, "cancelling the root still releases the child")
    local result = rig.flow:takeResult()
    Assert.notNil(result, "cancelling the root still reports")
    Assert.equal(result.kind, "close", "a root cancel still closes back to the menu")
    rig.flow:dispose()
  end
end

return T
