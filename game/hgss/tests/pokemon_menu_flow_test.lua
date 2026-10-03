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

local function resizedMeasurement()
  return {
    width = 512,
    height = 384,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 512, height = 384 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "menu-flow-test:512x384",
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
  local before = rig.flow:status()
  if before.transition ~= nil and before.transition.phase == "app_exit" and before.transition.step == 6 then
    rig.flow:updateFixed({})
    before = rig.flow:status()
  end
  if #events > 0 and before.transition == nil and before.child ~= nil and before.child.phase == "opening" then
    for _ = 1, 16 do
      if rig.flow:status().child.phase == "interactive" then
        break
      end
      rig.flow:updateFixed({})
    end
    rig.flow:updateFixed({})
    rig.flow:updateFixed({})
  end
  rig.flow:updateFixed(events)
  for _ = 1, 6 do
    if rig.flow:status().transition == nil then
      break
    end
    rig.flow:updateFixed({})
  end
  local after = rig.flow:status()
  if after.transition ~= nil and after.transition.phase == "app_exit" and after.transition.step == 6 then
    rig.flow:updateFixed({})
    after = rig.flow:status()
  end
  return liveStatus(rig)
end

local function settleBagOpening(rig)
  for _ = 1, 18 do
    local status = liveStatus(rig)
    if status.transition == nil and status.child ~= nil and status.child.phase == "interactive" then
      rig.flow:updateFixed({})
      rig.flow:updateFixed({})
      return
    end
    rig.flow:updateFixed({})
  end
  error("the Bag opening did not hand input to its interactive phase", 0)
end

local function driveUntil(rig, label, maxSteps, predicate)
  for _ = 1, maxSteps do
    local status = liveStatus(rig)
    if predicate(status) then
      return status
    end
    rig.flow:updateFixed({})
  end
  local status = rig.flow:status()
  error(
    "the flow never reaches " .. label .. "; page=" .. tostring(status.page)
      .. "; child state=" .. tostring(status.child and status.child.state),
    0
  )
end

local function recordChildLifecycle(child)
  local record = { disposals = 0, nonEmptyUpdates = 0 }
  local updateFixed = child.updateFixed
  local dispose = child.dispose
  child.updateFixed = function(self, events)
    if #events > 0 then
      record.nonEmptyUpdates = record.nonEmptyUpdates + 1
    end
    return updateFixed(self, events)
  end
  child.dispose = function(self)
    record.disposals = record.disposals + 1
    return dispose(self)
  end
  return record
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

-- Fresh party children reveal before accepting input: after any arrival
-- on a party page, wait out the reveal plus its handover/settling ticks
-- so driven input acts. Bag pages return immediately.
local function settleParty(rig)
  local status = liveStatus(rig)
  if type(status.page) ~= "string" or status.page:sub(1, 5) ~= "party" then
    return status
  end
  status = driveUntil(rig, "the party reveal", 30, function(current)
    local child = current.child
    return child ~= nil and child.phase == "interactive"
  end)
  drive(rig, {})
  return drive(rig, {})
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
      local dispatched = driveUntil(rig, "the gated menu dispatch", 10, function(current)
        local dispatched = partyChild(current)
        return dispatched.menuPress == nil and (dispatched.menu ~= menu or dispatched.state ~= "context")
      end)
      if kind == "give" then
        return driveUntil(rig, "the held-item picker", 30, function(current)
          return current.page == "bag_pick_held"
        end)
      end
      return dispatched
    end
    local direction = (child.menuIndex or 0) < index and "down" or "up"
    drive(rig, { { type = "navigate", direction = direction } })
  end
  error("the party menu never selects " .. kind, 0)
end

-- Opens the ordinary Item submenu over slot zero and answers its entry
-- kinds in display order. Slot zero carries the focused mon on a fresh
-- browse page, so no cursor travel is needed before opening the menu.
local function itemSubmenuKinds(rig)
  local status = drive(rig, {})
  status = settleParty(rig)
  status = drive(rig, { { type = "confirm" } })
  status = drivePartyMenu(rig, "item")
  local submenu = assert(partyChild(status).menu, "the item entry opens its submenu")
  local kinds = {}
  for _, entry in ipairs(submenu) do
    kinds[#kinds + 1] = assert(entry.kind, "submenu entries carry their kind")
  end
  return kinds
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

-- The Party child owns the replacement text, prompt, and result. Bag
-- callers return only after feedback; Party callers remain in that child.
local function answerYes(rig)
  settleParty(rig)
  drive(rig, { { type = "confirm" } }) -- acknowledge the generated replacement question
  drive(rig, {}) -- arm the prompt after the message handoff
  drive(rig, { { type = "navigate", direction = "down" } })
  drive(rig, { { type = "confirm" } })
  local status = driveUntil(rig, "the held-item result or safe Bag return", 30, function(current)
    return current.page == "bag_browse" or (current.child ~= nil and current.child.state == "message")
  end)
  if status.page == "bag_browse" then
    return status
  end
  status = drive(rig, { { type = "confirm" } })
  if status.page == "party_browse" then
    return driveUntil(rig, "ordinary Party browse", 10, function(current)
      return current.child ~= nil and current.child.state == "browse"
    end)
  end
  return driveUntil(rig, "the originating Bag", 30, function(current)
    return current.page == "bag_browse"
  end)
end

local function answerNo(rig)
  settleParty(rig)
  drive(rig, { { type = "confirm" } }) -- acknowledge the generated replacement question
  drive(rig, {}) -- arm the prompt after the message handoff
  local status = drive(rig, { { type = "cancel" } })
  if status.page == "party_browse" then
    return driveUntil(rig, "ordinary Party browse", 10, function(current)
      return current.child ~= nil and current.child.state == "browse"
    end)
  end
  return driveUntil(rig, "the originating Bag", 30, function(current)
    return current.page == "bag_browse"
  end)
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

function T.tests.item_submenu_always_lists_give_take_quit_in_order(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "party")
    Assert.deepEqual(
      itemSubmenuKinds(rig),
      { "give", "take", "quit" },
      "an empty holder still exposes Take between Give and Quit"
    )
    rig.flow:dispose()
    local held = liveComposition(versionId, "party")
    occupyHolder(held, 0, "CHERI_BERRY")
    Assert.deepEqual(
      itemSubmenuKinds(held),
      { "give", "take", "quit" },
      "a holder keeps Give, Take, Quit in the same order"
    )
    held.flow:dispose()
  end
end

function T.tests.empty_take_reports_the_generated_template_without_mutation(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "party")
    local partyRevision = rig.mons:partyRevision()
    local bagRevision = rig.bag:revision()
    local status = drive(rig, {})
    status = settleParty(rig)
    status = drive(rig, { { type = "confirm" } })
    status = drivePartyMenu(rig, "item")
    status = drivePartyMenu(rig, "take")
    local child = partyChild(status)
    Assert.equal(child.state, "message", "an empty Take answers with its message")
    local message = child.message
    Assert.equal(type(message), "table", "an empty Take renders the generated template")
    Assert.equal(message.templateKey, "takeNoItem", "an empty Take shows the empty-take template")
    Assert.equal(
      message.displayName,
      assert(child.view, "the party child carries its view").slots[1].displayName,
      "an empty Take names the acting mon the party screen shows"
    )
    Assert.equal(rig.mons:partyMon(0).heldItem, "NONE", "an empty Take holds nothing new")
    Assert.equal(rig.mons:partyRevision(), partyRevision, "an empty Take publishes no party revision")
    Assert.equal(rig.bag:revision(), bagRevision, "an empty Take publishes no bag revision")
    Assert.isNil(rig.flow:takeResult(), "an empty Take reports no terminal result")
    status = drive(rig, { { type = "confirm" } })
    status = driveUntil(rig, "the dismissed message", 30, function(current)
      return partyChild(current).state == "browse"
    end)
    Assert.equal(status.page, "party_browse", "dismissal stays on party browse")
    Assert.equal(partyChild(status).cursorNode, 0, "dismissal refocuses the same slot")
    Assert.isNil(rig.flow:takeResult(), "dismissal reports no terminal result")
    rig.flow:dispose()
  end
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
    status = settleParty(rig)
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
    rig.flow:_routeFieldMove({ move = "CUT", slot = 0, moveSlot = 0 })
    local status = rig.flow:status()
    Assert.equal(status.transition.phase, "app_exit", "a field action starts the source app exit")
    Assert.isNil(rig.flow:takeResult(), "the field action waits for app closure")
    for step = 1, 5 do
      rig.flow:updateFixed({})
      status = rig.flow:status()
      Assert.equal(status.transition.phase, "app_exit", "field-action exit stays in its source phase")
      Assert.equal(status.transition.step, step, "field-action exit advances one source step")
      Assert.isNil(rig.flow:takeResult(), "the field action waits through app exit")
    end
    rig.flow:updateFixed({})
    local result = rig.flow:takeResult()
    Assert.notNil(result, "field-action result publishes at full app closure")
    Assert.equal(result.kind, "field_action", "the terminal result carries the typed field action")
    Assert.equal(result.actionId, "pokemon.field_move", "the host receives the field-action id")
    status = rig.flow:status()
    Assert.isNil(status.transition, "field-action closure never starts menu return")
    Assert.isNil(rig.flow:takeResult(), "the field-action result drains exactly once")
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
    for _, root in ipairs({ "bag", "party" }) do
      local rig = liveComposition(versionId, root)
      local status = drive(rig, {})
      Assert.equal(status.root, root, "the flow remembers its root application")
      if root == "bag" then
        Assert.equal(status.page, "bag_browse", "a Bag root opens the bag browse page")
        settleBagOpening(rig)
      else
        Assert.equal(status.page, "party_browse", "a Party root opens the party browse page")
        status = settleParty(rig)
      end
      rig.flow:updateFixed({ { type = "cancel" } })
      status = rig.flow:status()
      Assert.isTrue(status.open, "the root child remains published during its outgoing fade")
      Assert.notNil(status.child, "the outgoing root child stays published through app exit")
      Assert.notNil(status.child.presentation, "the outgoing fade retains its presentation plan")
      local outgoingSnapshot = status.child
      local originalPlan = status.child.presentation
      Assert.isNil(rig.flow:takeResult(), "the host result waits until the outgoing fade completes")
      rig.flow._child._measureDisplay = resizedMeasurement
      rig.flow._measureDisplay = resizedMeasurement
      for index = 1, 6 do
        rig.flow:updateFixed({})
        status = rig.flow:status()
        if index == 1 then
          local pane = assert(status.child.presentation.panes[1], "the closing app keeps its current pane")
          Assert.equal(pane.placement.frame.width, 512, "terminal app exit re-resolves after resize")
          Assert.isFalse(status.child == outgoingSnapshot, "resolving an exit does not mutate its prior status snapshot")
          Assert.isTrue(outgoingSnapshot.presentation == originalPlan, "the prior snapshot keeps its original plan")
        elseif index < 6 then
          Assert.notNil(status.child.presentation, "the closing child remains drawable through app exit")
        else
          Assert.isNil(status.child, "menu return starts after the outgoing child is retired")
        end
      end
      Assert.isTrue(status.open, "the flow stays published during the menu return reveal")
      Assert.isNil(status.child, "menu return draws no stale child content")
      Assert.equal(status.transition.phase, "menu_return", "root close starts the retained-menu reveal")
      Assert.equal(status.transition.inputKey, root, "menu return keeps the matching root application")
      Assert.equal(status.transition.brightnessCoefficient, 16, "menu return begins fully covered")
      local retainedPane = assert(status.transition.panes[1], "menu return retains an app pane")
      retainedPane.placement.frame.width = 1
      status = rig.flow:status()
      Assert.equal(
        status.transition.panes[1].placement.frame.width,
        512,
        "menu-return status copies its retained placement facts"
      )
      Assert.isNil(rig.flow:takeResult(), "the terminal result waits for the menu reveal")
      for _, coefficient in ipairs({ 14, 11, 9, 6, 3, 0 }) do
        rig.flow:updateFixed({ { type = "confirm" } })
        status = rig.flow:status()
        Assert.equal(status.transition.brightnessCoefficient, coefficient, "menu return advances one brightness step")
        local pane = assert(status.transition.panes[1], "menu return retains a current app pane")
        Assert.equal(pane.placement.frame.width, 512, "menu return keeps the final app-exit placement")
        Assert.isNil(rig.flow:takeResult(), "the close is withheld through the reveal")
      end
      rig.flow:updateFixed({})
      local result = rig.flow:takeResult()
      Assert.notNil(result, "cancelling the root must report a terminal result")
      Assert.equal(result.kind, "close", "a root cancel closes back to the menu")
      Assert.isNil(rig.flow:takeResult(), "the terminal result drains exactly once")
      rig.flow:dispose()
      rig.flow:dispose()
    end
  end
end

function T.tests.sibling_handoffs_keep_the_outgoing_child_through_six_updates(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  local routes = {
    {
      root = "party",
      outgoingPage = "party_browse",
      incomingPage = "bag_pick_held",
      route = function(rig)
        rig.flow:_routeBrowseIntent({
          kind = "give",
          slot = 0,
          partyRevision = rig.mons:partyRevision(),
        })
      end,
    },
    {
      root = "bag",
      outgoingPage = "bag_browse",
      incomingPage = "party_give_target",
      route = function(rig)
        Assert.isTrue(rig.bag:add("GREAT_BALL", 1), "the fixture stocks the Bag handoff")
        rig.flow:_routeBagIntent({
          kind = "give",
          item = "GREAT_BALL",
          bagRevision = rig.bag:revision(),
        })
      end,
    },
  }
  for _, versionId in ipairs(versions) do
    for _, route in ipairs(routes) do
      local rig = liveComposition(versionId, route.root)
      if route.root == "bag" then
        settleBagOpening(rig)
      else
        settleParty(rig)
      end
      local outgoing = rig.flow._child
      local outgoingLifecycle = recordChildLifecycle(outgoing)
      local openPage = rig.flow._openPage
      local staged = nil
      local stagedLifecycle = nil
      rig.flow._openPage = function(self, page, continuation)
        staged = openPage(self, page, continuation)
        stagedLifecycle = recordChildLifecycle(staged)
        return staged
      end

      route.route(rig)
      local status = rig.flow:status()
      Assert.equal(status.page, route.outgoingPage, "the outgoing page stays published after staging")
      Assert.equal(status.transition.phase, "app_exit", "the staged handoff begins the source app exit")
      Assert.equal(status.transition.step, 0, "the shutter begins fully open")
      Assert.equal(status.transition.brightnessCoefficient, 0, "the sub pane begins at brightness zero")
      Assert.notNil(staged, "the incoming child is constructed before the fade")
      Assert.equal(outgoingLifecycle.disposals, 0, "the outgoing child stays alive while fading")
      outgoing._measureDisplay = resizedMeasurement
      local coefficients = { 2, 5, 7, 10, 13, 16 }
      for index, coefficient in ipairs(coefficients) do
        rig.flow:updateFixed({ { type = "confirm" } })
        status = rig.flow:status()
        if index < #coefficients then
          Assert.equal(status.transition.phase, "app_exit", "the outgoing app remains in its exit phase")
          Assert.notNil(status.child.presentation, "the outgoing child keeps its drawable snapshot")
          Assert.equal(status.transition.step, index, "the flow exposes each live source shutter step")
          Assert.equal(
            status.transition.brightnessCoefficient,
            coefficient,
            "the sub pane uses the standard fade recurrence"
          )
          Assert.equal(status.page, route.outgoingPage, "the outgoing page stays published before full black")
          if index == 1 then
            local plan = assert(status.child.presentation, "the resized outgoing child keeps its current plan")
            local pane = assert(plan.panes[1], "the outgoing plan has a transition pane")
            Assert.equal(pane.placement.frame.width, 512, "the outgoing transition maps to the resized host")
          end
        else
          Assert.equal(status.page, route.incomingPage, "the replacement publishes at full black")
          Assert.isNil(status.transition, "the outgoing phase ends at the closure handoff")
        end
      end
      Assert.equal(outgoingLifecycle.nonEmptyUpdates, 0, "fade input is not replayed to the outgoing child")
      Assert.equal(stagedLifecycle.nonEmptyUpdates, 0, "fade input never reaches the staged child")
      Assert.equal(outgoingLifecycle.disposals, 1, "handoff disposes the outgoing child exactly once")
      Assert.equal(stagedLifecycle.nonEmptyUpdates, 0, "the transition-completing batch is discarded")
      rig.flow:dispose()
      Assert.equal(stagedLifecycle.disposals, 1, "flow disposal releases the replacement exactly once")
    end
  end
end

function T.tests.failed_staging_and_mid_fade_disposal_preserve_child_ownership(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "bag")
    Assert.isTrue(rig.bag:add("GREAT_BALL", 1), "the fixture stocks the Bag handoff")
    local outgoing = rig.flow._child
    local outgoingLifecycle = recordChildLifecycle(outgoing)
    local openPage = rig.flow._openPage
    rig.flow._openPage = function(_, _page, _continuation)
      error("injected replacement staging failure", 0)
    end
    local ok, err = pcall(function()
      rig.flow:_routeBagIntent({
        kind = "give",
        item = "GREAT_BALL",
        bagRevision = rig.bag:revision(),
      })
    end)
    rig.flow._openPage = openPage
    Assert.isFalse(ok, "the injected construction failure must escape")
    Assert.notNil(tostring(err):find("injected replacement staging failure", 1, true))
    Assert.equal(rig.flow:status().page, "bag_browse", "failed staging preserves the outgoing page")
    Assert.equal(outgoingLifecycle.disposals, 0, "failed staging leaves the outgoing child alive")
    Assert.isNil(rig.flow:takeResult(), "failed staging publishes no terminal result")

    local staged = nil
    local stagedLifecycle = nil
    rig.flow._openPage = function(self, page, continuation)
      staged = openPage(self, page, continuation)
      stagedLifecycle = recordChildLifecycle(staged)
      return staged
    end
    rig.flow:_routeBagIntent({
      kind = "give",
      item = "GREAT_BALL",
      bagRevision = rig.bag:revision(),
    })
    Assert.equal(rig.flow:status().page, "bag_browse", "the outgoing child remains published during the fade")
    Assert.equal(outgoingLifecycle.disposals, 0, "the fade retains the outgoing child")
    Assert.notNil(staged, "the replacement remains staged during the fade")

    rig.flow:dispose()
    rig.flow:dispose()
    Assert.equal(outgoingLifecycle.disposals, 1, "mid-fade disposal releases the outgoing child once")
    Assert.equal(stagedLifecycle.disposals, 1, "mid-fade disposal releases the staged child once")
    Assert.isNil(rig.flow:takeResult(), "disposal during a fade publishes no result")
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
    status = settleParty(rig)
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "party_give_target", "the target child owns the replacement question")
    Assert.isNil(status.transition, "the occupied-item question does not create an app transition")
    Assert.equal(status.child.state, "message", "source msg79 appears before Yes/No")
    Assert.equal(status.child.message.templateKey, "switchHeldPrompt", "the held-item question uses its generated template")
    status = drive(rig, { { type = "confirm" } })
    Assert.isNil(status.transition, "entering Yes/No stays inside the existing Party app")
    status = drive(rig, {})
    Assert.equal(
      status.child.prompt and status.child.prompt.selected,
      "no",
      "the replacement question defaults to its safe answer"
    )
    Assert.equal(rig.mons:partyMon(0).heldItem, "CHERI_BERRY", "asking publishes nothing yet")
    Assert.equal(rig.mons:partyRevision(), partyRevision, "asking publishes no party revision")
    Assert.equal(rig.bag:revision(), bagRevision, "asking publishes no bag revision")
    Assert.isNil(status.transition, "the active replacement prompt remains transition-free")

    status = answerNo(rig)
    Assert.equal(status.page, "bag_browse", "declining returns to the originating bag")
    Assert.isNil(status.transition, "declining the occupied-item question stays transition-free")
    Assert.equal(rig.mons:partyMon(0).heldItem, "CHERI_BERRY", "declining keeps the held item")
    Assert.equal(rig.bag:quantity("SITRUS_BERRY"), 2, "declining consumes nothing")
    Assert.equal(rig.bag:quantity("CHERI_BERRY"), 0, "declining returns nothing")
    Assert.equal(rig.mons:partyRevision(), partyRevision, "declining publishes no party revision")
    Assert.equal(rig.bag:revision(), bagRevision, "declining publishes no bag revision")
    Assert.isNil(rig.flow:takeResult(), "declining reports no terminal result")

    status = drive(rig, { { type = "confirm" } })
    status = driveToAction(rig, "give")
    Assert.equal(status.page, "party_give_target", "the declined Give can be chosen again")
    status = settleParty(rig)
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "party_give_target", "the retry asks in the same target child")
    status = answerYes(rig)
    Assert.equal(status.page, "bag_browse", "accepting returns to the originating bag")
    Assert.isNil(status.transition, "accepting the occupied-item question stays transition-free")
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
    status = settleParty(rig)
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
    Assert.equal(status.page, "party_browse", "the continuation Party child owns the replacement question")
    Assert.equal(rig.mons:partyMon(0).heldItem, "CHERI_BERRY", "asking publishes nothing yet")

    status = answerNo(rig)
    Assert.equal(status.page, "party_browse", "declining returns to the originating party")
    status = settleParty(rig)
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
    Assert.equal(status.page, "party_browse", "the retry asks in the continuation Party child")
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

function T.tests.failed_party_give_continuation_keeps_picker_and_domains(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "party")
    Assert.isTrue(rig.bag:add("SITRUS_BERRY", 1), "the fixture stocks a held item")
    Assert.isTrue(rig.bag:add("CHERI_BERRY", 1), "a second row makes cursor adoption observable")
    rig.cursor:setPocket("berries")
    rig.cursor:setPosition("berries", 0)
    local partyRevision = rig.mons:partyRevision()
    local bagRevision = rig.bag:revision()
    local fieldPosition = rig.cursor:position("berries")

    local status = drive(rig, {})
    status = settleParty(rig)
    status = drive(rig, { { type = "confirm" } })
    status = drivePartyMenu(rig, "item")
    status = drivePartyMenu(rig, "give")
    Assert.equal(status.page, "bag_pick_held", "Party Give opens its temporary picker")
    status = drive(rig, { { type = "navigate", direction = "right" } })
    local pickerPosition = rig.flow._picker:position("berries")
    Assert.isTrue(pickerPosition ~= fieldPosition, "the temporary picker has moved independently")
    local outgoing = rig.flow._child
    local lifecycle = recordChildLifecycle(outgoing)
    local moduleName = "game.hgss.src.field.PartyScreenState"
    local partyState = assert(package.loaded[moduleName], "the flow holds the Party screen state")
    local realNew = partyState.new
    partyState.new = function(_)
      error("injected continuation construction fault", 0)
    end
    local ok, err = pcall(function()
      rig.flow:updateFixed({ { type = "confirm" } })
    end)
    partyState.new = realNew
    Assert.isFalse(ok, "the staged Party construction failure reaches its owner")
    Assert.notNil(tostring(err):find("injected continuation construction fault", 1, true))
    Assert.equal(rig.flow._child, outgoing, "the live picker remains published")
    Assert.equal(rig.flow:status().page, "bag_pick_held", "the picker remains the active page")
    Assert.equal(lifecycle.disposals, 0, "the picker stays alive after staging failure")
    Assert.equal(rig.mons:partyRevision(), partyRevision, "staging failure publishes no Party revision")
    Assert.equal(rig.bag:revision(), bagRevision, "staging failure publishes no Bag revision")
    Assert.equal(rig.mons:partyMon(0).heldItem, "NONE", "staging failure applies no held item")
    Assert.equal(rig.cursor:position("berries"), fieldPosition, "staging failure does not adopt picker movement")
    rig.flow:dispose()
    Assert.equal(lifecycle.disposals, 1, "disposing the surviving picker releases it once")
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
    status = settleParty(rig)
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
    local preview = rig.actions.preview
    local previewKind
    rig.actions.preview = function(actions, request)
      local decision = preview(actions, request)
      previewKind = decision.kind
      return decision
    end
    status = drive(rig, { { type = "confirm" } })
    rig.actions.preview = preview
    Assert.equal(previewKind, "no_effect", "the action owner classifies a same-item pick without committing")
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
    Assert.equal(status.page, "party_browse", "the continuation Party child owns the real replacement question")
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
    status = settleParty(rig)
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "party_give_target", "the target child asks before publishing")
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
    status = settleParty(rig)
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
    status = settleParty(rig)
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "party_give_target", "the freed pocket asks in the same target child")
    Assert.isTrue(rig.bag:add("POTION", 1), "the second race moves the bag revision")
    bagRevision = rig.bag:revision()
    status = answerYes(rig)
    Assert.equal(status.page, "bag_browse", "a stale Yes still returns to the originating bag")
    Assert.equal(rig.mons:partyMon(0).heldItem, "CHERI_BERRY", "a stale Yes moves no held item")
    Assert.equal(rig.bag:quantity("SITRUS_BERRY"), 2, "a stale Yes consumes no replacement")
    Assert.equal(rig.mons:partyRevision(), partyRevision, "a stale Yes publishes no party revision")
    Assert.equal(rig.bag:revision(), bagRevision, "a stale Yes publishes no bag revision of its own")
    Assert.isNil(rig.flow:takeResult(), "a stale Yes reports no terminal result")
    settleBagOpening(rig)
    rig.flow:updateFixed({ { type = "cancel" } })
    for _ = 1, 6 do
      if not rig.flow:status().open then
        break
      end
      rig.flow:updateFixed({})
    end
    status = rig.flow:status()
    Assert.isTrue(status.open, "cancelling the root keeps the flow during menu return")
    Assert.equal(status.transition.phase, "menu_return", "the root begins a retained-menu reveal")
    Assert.equal(status.transition.brightnessCoefficient, 16, "menu return starts fully covered")
    for _, coefficient in ipairs({ 14, 11, 9, 6, 3, 0 }) do
      rig.flow:updateFixed({})
      status = rig.flow:status()
      Assert.equal(status.transition.brightnessCoefficient, coefficient, "menu return reveals through source brightness steps")
      Assert.isNil(rig.flow:takeResult(), "root close waits through the transparent presentation frame")
    end
    rig.flow:updateFixed({})
    local result = rig.flow:takeResult()
    Assert.notNil(result, "cancelling the root still reports")
    Assert.equal(result.kind, "close", "a root cancel still closes back to the menu")
    rig.flow:dispose()
  end
end

-- Finds a spare medicine item to serve as the exchange replacement: the
-- displaced potion stays absent from the bag while the replacement keeps
-- a stack of two, so its staged removal cannot free a medicine slot.
local function spareMedicineKey(bag, excluded)
  local catalog = bag:catalog()
  for nativeId = 0, 536 do
    local key = catalog:itemKeyByNativeId(nativeId)
    if key ~= excluded and catalog:item(key).pocket == "medicine" then
      return key
    end
  end
  error("the catalog carries no spare medicine item", 0)
end

-- Occupies every medicine slot while keeping the displaced item out, so
-- only a staged removal inside the same pocket could make room for it.
local function fillMedicinePocket(rig, excluded)
  local catalog = rig.bag:catalog()
  for nativeId = 0, 536 do
    if #rig.bag:pocketItems("medicine") >= catalog:pocket("medicine").capacity then
      break
    end
    local key = catalog:itemKeyByNativeId(nativeId)
    if key ~= excluded and catalog:item(key).pocket == "medicine" and rig.bag:quantity(key) == 0 then
      Assert.isTrue(rig.bag:add(key, 1), "the fixture must occupy the return pocket")
    end
  end
  Assert.equal(
    #rig.bag:pocketItems("medicine"),
    catalog:pocket("medicine").capacity,
    "the return pocket starts full"
  )
end

local function stockFullPocketExchange(rig)
  occupyHolder(rig, 0, "POTION")
  local replacement = spareMedicineKey(rig.bag, "POTION")
  Assert.isTrue(rig.bag:add(replacement, 2), "the fixture must stock a replacement that keeps its stack")
  fillMedicinePocket(rig, "POTION")
  Assert.equal(rig.bag:quantity("POTION"), 0, "the held potion starts absent from the bag")
  Assert.isFalse(rig.bag:hasSpace("POTION", 1), "the return pocket starts full")
  rig.cursor:setPocket("medicine")
  rig.cursor:setPosition("medicine", 0)
  return replacement
end

-- Answers the held-item replacement question with Yes and settles until
-- the exchange resolves to visible feedback or a silent return.
local function answerYesAndSettle(rig)
  settleParty(rig)
  drive(rig, { { type = "confirm" } }) -- acknowledge the generated replacement question
  drive(rig, {}) -- arm the prompt after the message handoff
  drive(rig, { { type = "navigate", direction = "down" } })
  drive(rig, { { type = "confirm" } })
end

function T.tests.party_give_full_pocket_failure_shows_feedback_and_stays(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "party")
    local replacement = stockFullPocketExchange(rig)
    local partyRevision = rig.mons:partyRevision()
    local bagRevision = rig.bag:revision()

    local status = drive(rig, {})
    Assert.equal(status.page, "party_browse", "a party root opens the party browse page")
    status = settleParty(rig)
    status = drive(rig, { { type = "confirm" } })
    status = drivePartyMenu(rig, "item")
    status = drivePartyMenu(rig, "give")
    Assert.equal(status.page, "bag_pick_held", "party Give opens the held-item picker")
    Assert.equal(
      partyChild(status).selected and partyChild(status).selected.item,
      replacement,
      "the picker opens on the stocked replacement"
    )
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "party_browse", "the continuation Party child owns the replacement question")
    status = settleParty(rig)
    Assert.equal(status.child.state, "message", "the replacement question appears before Yes/No")
    Assert.equal(
      status.child.message.templateKey,
      "switchHeldPrompt",
      "the held-item question uses its generated template"
    )

    answerYesAndSettle(rig)
    status = driveUntil(rig, "the held-item result", 30, function(current)
      return current.child ~= nil and (current.child.state == "message" or current.child.state == "browse")
    end)
    Assert.equal(
      status.child.state,
      "message",
      "a genuine capacity failure shows feedback instead of finishing silently"
    )
    Assert.equal(status.child.message.templateKey, "bagFull", "the failure uses its generated full-bag template")
    Assert.equal(rig.mons:partyMon(0).heldItem, "POTION", "the failure moves no held item")
    Assert.equal(rig.bag:quantity(replacement), 2, "the failure consumes no replacement")
    Assert.equal(rig.bag:quantity("POTION"), 0, "the failure returns nothing")
    Assert.equal(rig.mons:partyRevision(), partyRevision, "the failure publishes no party revision")
    Assert.equal(rig.bag:revision(), bagRevision, "the failure publishes no bag revision")

    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "party_browse", "acknowledging returns to the originating party")
    status = driveUntil(rig, "ordinary Party browse", 10, function(current)
      return current.child ~= nil and current.child.state == "browse"
    end)
    Assert.equal(partyChild(status).cursorNode, 0, "acknowledging resumes on the original mon")
    Assert.equal(rig.mons:partyMon(0).heldItem, "POTION", "acknowledging retries nothing")
    Assert.isNil(rig.flow:takeResult(), "the failure reports no terminal result")
    rig.flow:dispose()
  end
end

function T.tests.bag_give_full_pocket_failure_shows_feedback_then_rewinds(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("menu flow needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local rig = liveComposition(versionId, "bag")
    local replacement = stockFullPocketExchange(rig)
    local partyRevision = rig.mons:partyRevision()
    local bagRevision = rig.bag:revision()

    local status = drive(rig, {})
    Assert.equal(
      status.child.selected and status.child.selected.item,
      replacement,
      "the borrowed position selects the replacement"
    )
    status = drive(rig, { { type = "confirm" } })
    status = driveToActionMenu(rig)
    Assert.equal(status.child.state, "action_menu", "confirming opens the action menu")
    status = driveToAction(rig, "give")
    Assert.equal(status.page, "party_give_target", "choosing Give opens the party target page")
    status = settleParty(rig)
    status = drive(rig, { { type = "confirm" } })
    Assert.equal(status.page, "party_give_target", "the target child owns the replacement question")
    Assert.equal(status.child.state, "message", "the replacement question appears before Yes/No")
    Assert.equal(
      status.child.message.templateKey,
      "switchHeldPrompt",
      "the held-item question uses its generated template"
    )

    answerYesAndSettle(rig)
    status = driveUntil(rig, "the held-item result", 30, function(current)
      return (current.child ~= nil and current.child.state == "message") or current.page == "bag_browse"
    end)
    Assert.equal(
      status.page,
      "party_give_target",
      "a genuine capacity failure holds its feedback instead of rewinding silently"
    )
    Assert.equal(status.child.state, "message", "the failure shows feedback over the target page")
    Assert.equal(status.child.message.templateKey, "bagFull", "the failure uses its generated full-bag template")
    Assert.equal(rig.mons:partyMon(0).heldItem, "POTION", "the failure moves no held item")
    Assert.equal(rig.bag:quantity(replacement), 2, "the failure consumes no replacement")
    Assert.equal(rig.bag:quantity("POTION"), 0, "the failure returns nothing")
    Assert.equal(rig.mons:partyRevision(), partyRevision, "the failure publishes no party revision")
    Assert.equal(rig.bag:revision(), bagRevision, "the failure publishes no bag revision")

    status = drive(rig, { { type = "confirm" } })
    status = driveUntil(rig, "the originating Bag", 30, function(current)
      return current.page == "bag_browse"
    end)
    Assert.equal(rig.mons:partyMon(0).heldItem, "POTION", "acknowledging retries nothing")
    Assert.equal(rig.bag:quantity(replacement), 2, "acknowledging consumes nothing")
    Assert.isNil(rig.flow:takeResult(), "the failure reports no terminal result")
    rig.flow:dispose()
  end
end

return T
