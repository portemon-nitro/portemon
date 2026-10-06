-- Cross-system failure proof for the bounded Bag/Party/Summary menu flow:
-- stale revisions refuse without consuming, a full Bag refuses takes
-- without touching the mon, disposal abandons uncommitted work safely,
-- and the real save store rejects malformed records and incompatible
-- active script graphs while preserving the original file bytes. A v3
-- record migrates through the store load path. Faults are injected at
-- real boundaries (live services, real store backend, real validators);
-- failing operations leave revisions, quantities, order, and files
-- unchanged. Stops before GPU rendering like every acceptance path.
-- Deferred capabilities (evolution, level-up items, mail, contests,
-- storage, battles) stay refused and non-consuming by design; failures
-- below never convert them into successes.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local BagCache = require("libs.assets.src.BagCache")
local BagSave = require("libs.hgss.src.save.BagSave")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local MartSave = require("libs.hgss.src.save.MartSave")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local GameSave = require("libs.hgss.src.save.GameSave")
local GameSaveValidation = require("libs.hgss.src.save.GameSaveValidation")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local ItemFixture = require("libs.items.tests.item_fixture")
local MartSave = require("libs.hgss.src.save.MartSave")
local MonsSave = require("libs.mons.src.MonsSave")
local PartyActions = require("libs.hgss.src.field.PartyActions")
local PartyCache = require("libs.assets.src.PartyCache")

local FLOW_MODULE = "game.hgss.src.field.PokemonMenuFlow"

local T = {
  metadata = { capabilities = { "rom_dump" }, derivedAssets = { "field-runtime", "map:7" }, tags = { "party", "bag", "flow", "failure" } },
  tests = {},
}

local function requireVersions(context)
  if context ~= nil and type(context.hasCapability) == "function" then
    if not context:hasCapability("rom_dump") then
      context:skip("requires rom_dump and prepared assets")
    end
  end
  local versions = { AcceptanceHarness.defaultVersion() }
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("menu failure journeys need a ready ROM cache", 0)
  end
  return versions
end

local function withGame(fn)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    -- Headless composition binds the explicit no-image preparation fake:
    -- the party reports ready without realizing GPU icons it never draws.
    game.runtime:bindPartyIconPreparation(function(_)
      return true
    end, function() end)
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "menu failure acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function requireFlow()
  local ok, flowModule = pcall(require, FLOW_MODULE)
  Assert.isTrue(ok, "the menu flow owns Bag/Party/Summary round trips: " .. tostring(flowModule))
  return assert(flowModule)
end

local function heroGender(game)
  local avatar = assert(game.runtime.avatar, "field runtime owns the player avatar")
  assert(avatar.gender == 0 or avatar.gender == 1, "the hero gender is binary")
  return avatar.gender == 0 and "male" or "female"
end

local function openFlow(game, root)
  local Flow = requireFlow()
  local runtime = game.runtime
  local mons = assert(runtime.monService, "field runtime owns the live mon service")
  local bag = assert(runtime.bagService, "field runtime owns the live bag service")
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local cacheFs = assert(runtime.cacheFs, "field runtime owns its asset filesystem")
  return Flow.new({
    root = root,
    mons = mons,
    bag = bag,
    bagCursor = assert(runtime.bagCursor, "field runtime owns the live bag cursor"),
    partyActions = actions,
    mailActions = assert(runtime.pokemonMenu).mailActions,
    mailbox = assert(runtime.mailbox),
    pcManifest = assert(runtime.pokemonMenu).pcManifest,
    fieldMoves = {
      check = function(_)
        return { kind = "ok" }
      end,
    },
    assets = {
      bagManifest = BagCache.loadManifest(cacheFs),
      partyManifest = PartyCache.loadManifest(cacheFs),
      uiManifest = assert(runtime.uiManifest, "field runtime owns the field-UI manifest"),
      monCatalog = assert(runtime.monCatalog, "field runtime owns the mon catalog"),
      itemCatalog = assert(runtime.itemCatalog, "field runtime owns the item catalog"),
      heroGender = heroGender(game),
    },
    measureDisplay = function()
      return runtime.presentationDisplay
    end,
    prepareIcons = function(_)
      return true
    end,
    cancelIconPreparation = function() end,
    textPolicy = { interGlyphDelay = 0, glyphBudget = 512, abAcceleration = true },
  })
end

local function givePair(game)
  local service = assert(game.runtime.monService, "field runtime owns the live mon service")
  Assert.isTrue(service:giveMon({ species = "CHIKORITA", level = 5 }), "setup gift must enter the party")
  Assert.isTrue(service:giveMon({ species = "TOTODILE", level = 5 }), "setup gift must enter the party")
end

local function injureLead(game, amount)
  local service = assert(game.runtime.monService, "field runtime owns the live mon service")
  local mon = service:partyMon(0)
  local maxHp = service:derive(mon).maxHp
  Assert.isTrue(maxHp > amount, "the injured fixture needs headroom above the wound")
  mon.condition.currentHp = maxHp - amount
  local revision = service:partyRevision()
  local preparation, reason = service:preparePartyChanges(revision, { { slot = 0, mon = mon } })
  Assert.isNil(reason, "injury staging must prepare cleanly")
  assert(preparation).publish()
  Assert.equal(service:partyMon(0).condition.currentHp, maxHp - amount, "injury staging must stick")
  return maxHp
end

local function flowStatus(flow)
  local status = flow:status()
  Assert.isTrue(status.open, "the flow stays open through the fault")
  return status
end

local function drive(flow, events)
  flow:updateFixed(events)
  for _ = 1, 6 do
    if flow:status().transition == nil then
      break
    end
    flow:updateFixed({})
  end
  return flowStatus(flow)
end

local function driveUntil(flow, label, maxSteps, predicate)
  for _ = 1, maxSteps do
    local status = flowStatus(flow)
    if predicate(status) then
      return status
    end
    flow:updateFixed({})
  end
  error("the flow never reaches " .. label, 0)
end

local function bagChild(status)
  return assert(status.child, "the active page carries its child status")
end

-- A fresh party page clears its open before input: wait for the leaf
-- to turn interactive, then run out the handover ticks that still drop
-- input so the first navigation acts.
local function drainOpen(flow)
  driveUntil(flow, "the open clears before input", 30, function(current)
    local child = current.child
    return child ~= nil and child.phase == "interactive"
  end)
  drive(flow, {})
  drive(flow, {})
end

local BAG_NEIGHBORS = {
  [0] = { up = 2, down = 2, left = 1, right = 1 },
  [1] = { up = 3, down = 3, left = 0, right = 0 },
  [2] = { up = 0, down = 0, left = 4, right = 3 },
  [3] = { up = 1, down = 1, left = 2, right = 4 },
  [4] = { up = 4, down = 4, left = 3, right = 2 },
}

-- Confirming a browsed item parks in the source selection entry before
-- the stable action menu opens: settle the generated transition clock
-- before callers read the action state or its actions.
local function chooseBagAction(flow, id)
  driveUntil(flow, "the Bag opening settles", 30, function(current)
    return current.child ~= nil and current.child.phase == "interactive"
  end)
  local status = drive(flow, { { type = "confirm" } })
  status = driveUntil(flow, "the stable action menu", 30, function(current)
    return current.child ~= nil and current.child.state == "action_menu"
  end)
  local child = bagChild(status)
  Assert.equal(child.state, "action_menu", "confirming an item must open the action menu")
  local target = nil
  for _, action in ipairs(assert(child.actions, "the action menu lists its actions")) do
    if action.id == id then
      target = assert(action.slot, "menu actions carry their physical slot")
    end
  end
  Assert.notNil(target, "the action menu must offer " .. id)
  for _ = 1, 8 do
    status = flowStatus(flow)
    child = bagChild(status)
    if child.actionNode == target then
      drive(flow, { { type = "confirm" } })
      -- Activation latches behind feedback before the semantic transition
      -- runs, so settle until the menu leaves or the flow changes pages.
      return driveUntil(flow, "the chosen action", 30, function(current)
        return current.page ~= "bag_browse" or current.child == nil
      end)
    end
    local node = assert(child.actionNode, "the action menu exposes its node")
    local queue = { { node = node, path = {} } }
    local seen = { [node] = true }
    local path = nil
    local head = 1
    while head <= #queue and path == nil do
      local current = queue[head]
      head = head + 1
      for _, direction in ipairs({ "up", "down", "left", "right" }) do
        local nextNode = BAG_NEIGHBORS[current.node][direction]
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
    status = drive(flow, { { type = "navigate", direction = direction } })
  end
  error("the action menu never selects " .. id, 0)
end

local PARTY_DIRECTIONS = { "right", "down", "left", "up" }

local function choosePartySlot(flow, slot)
  -- A fresh screen reports no cursor while icon preparation pends:
  -- wait for the visible cursor before navigating, or the first
  -- navigation overshoots a cursor that already sits on target.
  for _ = 1, 30 do
    if bagChild(flowStatus(flow)).cursorNode ~= nil then
      break
    end
    drive(flow, {})
  end
  local probe = 1
  for _ = 1, 40 do
    local status = flowStatus(flow)
    local child = bagChild(status)
    if child.cursorNode == slot then
      return drive(flow, { { type = "confirm" } })
    end
    local direction = PARTY_DIRECTIONS[probe]
    probe = probe % #PARTY_DIRECTIONS + 1
    drive(flow, { { type = "navigate", direction = direction } })
  end
  error("the party cursor never reaches slot " .. tostring(slot), 0)
end

local function choosePartyMenu(flow, kind)
  for _ = 1, 40 do
    local status = flowStatus(flow)
    local child = bagChild(status)
    local menu = assert(child.menu, "the party context menu must be open")
    local index = nil
    for position, entry in ipairs(menu) do
      if entry.kind == kind then
        index = position
      end
    end
    Assert.notNil(index, "the party menu must offer " .. kind)
    if child.menuIndex == index then
      -- Menu activation rides the visual press cadence before its single
      -- dispatch: settle the gate so callers read the dispatched state.
      drive(flow, { { type = "confirm" } })
      return driveUntil(flow, "the gated menu dispatch", 10, function(current)
        local dispatched = bagChild(current)
        return dispatched.menuPress == nil and (dispatched.menu ~= menu or dispatched.state ~= "context")
      end)
    end
    local direction = child.menuIndex < index and "down" or "up"
    status = drive(flow, { { type = "navigate", direction = direction } })
  end
  error("the party menu never selects " .. kind, 0)
end

function T.tests.stale_bag_revision_at_flow_use_refuses_without_consuming(context)
  requireVersions(context)
  withGame(function(game)
    givePair(game)
    local maxHp = injureLead(game, 10)
    local wounded = maxHp - 10
    Assert.isTrue(wounded > 0, "the wound must leave the lead alive")
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.isTrue(bag:add("POTION", 3), "the medicine fixture must stock potions")
    local cursor = assert(game.runtime.bagCursor, "field runtime owns the live bag cursor")
    cursor:setPocket("medicine")
    cursor:setPosition("medicine", 0)
    local mons = assert(game.runtime.monService, "field runtime owns the live mon service")
    local partyRevision = mons:partyRevision()

    local flow = openFlow(game, "bag")
    driveUntil(flow, "the bag browse page", 30, function(current)
      return current.page == "bag_browse"
    end)
    local status = chooseBagAction(flow, "use")
    Assert.equal(status.page, "party_item_target", "choosing Use must open the party target page")
    -- Drift the bag behind the captured intent revision before confirming.
    Assert.isTrue(bag:add("POTION", 1), "setup drift must advance the bag revision")
    local driftedQuantity = bag:quantity("POTION")
    status = drive(flow, { { type = "confirm" } })
    Assert.isTrue(status.open, "a stale confirmation must not crash the flow")
    Assert.equal(
      mons:partyMon(0).condition.currentHp,
      wounded,
      "a stale confirmation must not heal through a drifted revision"
    )
    Assert.equal(bag:quantity("POTION"), driftedQuantity, "a stale confirmation consumes nothing")
    Assert.equal(mons:partyRevision(), partyRevision, "a stale confirmation publishes no party revision")
    Assert.isNil(flow:takeResult(), "a refused use reports no terminal result")
    flow:dispose()
  end)
end

function T.tests.take_into_full_bag_refuses_without_touching_the_mon(context)
  requireVersions(context)
  withGame(function(game)
    local mons = assert(game.runtime.monService, "field runtime owns the live mon service")
    Assert.isTrue(
      mons:giveMon({ species = "CHIKORITA", level = 5, heldItem = "POTION" }),
      "setup gift must enter the party holding a potion"
    )
    Assert.isTrue(mons:giveMon({ species = "TOTODILE", level = 5 }), "setup gift must enter the party")
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    -- Stack the potion to its source maximum so the held potion has
    -- nowhere to return to: the pocket has more distinct slots than the
    -- catalog has medicine keys, so only stack overflow refuses the take.
    Assert.isTrue(bag:add("POTION", 999), "setup must stack potions to the maximum")
    Assert.isFalse(bag:hasSpace("POTION", 1), "setup must leave no room for the held return")
    local monBefore = mons:partyMon(0)
    local monRevision = mons:partyRevision()
    local bagRevision = bag:revision()

    local flow = openFlow(game, "party")
    driveUntil(flow, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    drainOpen(flow)
    choosePartySlot(flow, 0)
    choosePartyMenu(flow, "item")
    choosePartyMenu(flow, "take")
    -- Take answers directly with no confirmation: settle the dispatch,
    -- then only a published refusal proves the conservation below.
    for _ = 1, 15 do
      flow:updateFixed({})
    end
    local status = flowStatus(flow)
    Assert.isTrue(status.open, "a refused take must not crash the flow")
    Assert.equal(mons:partyMon(0).heldItem, monBefore.heldItem, "a refused take preserves the held item")
    Assert.deepEqual(mons:partyMon(0), monBefore, "a refused take preserves the mon record")
    Assert.equal(mons:partyRevision(), monRevision, "a refused take publishes no mon revision")
    Assert.equal(bag:revision(), bagRevision, "a refused take publishes no bag revision")
    Assert.isNil(flow:takeResult(), "a refused take reports no terminal result")
    flow:dispose()
  end)
end

function T.tests.flow_dispose_with_uncommitted_swap_abandons_safely(context)
  requireVersions(context)
  withGame(function(game)
    givePair(game)
    local mons = assert(game.runtime.monService, "field runtime owns the live mon service")
    local orderBefore = { mons:partyMon(0).species, mons:partyMon(1).species }
    local revisionBefore = mons:partyRevision()
    local flow = openFlow(game, "party")
    driveUntil(flow, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    drainOpen(flow)
    choosePartySlot(flow, 0)
    choosePartyMenu(flow, "switch")
    -- Confirm the target but never tick the animation to commit.
    choosePartySlot(flow, 1)
    flow:dispose()
    Assert.deepEqual(
      { mons:partyMon(0).species, mons:partyMon(1).species },
      orderBefore,
      "disposing mid-swap abandons the uncommitted order"
    )
    Assert.equal(mons:partyRevision(), revisionBefore, "disposing mid-swap publishes no revision")
    flow:dispose()
  end)
end

-- Save-boundary legs below run against the real store, real validators,
-- and an isolated memory backend: no ROM, no graphics, no composed field.

local function fixtureContext()
  return {
    charmap = { G = 1, O = 2, L = 3, D = 4 },
    frameIndexes = { [0] = true },
    audioSequenceIds = { [7] = true },
    monCatalog = CatalogFixture.makeCatalog(),
    itemCatalog = ItemFixture.makeCatalog(),
    martCatalog = { cards = {}, apricorns = {}, seals = {} },
    scriptCompatibility = {
      validationOptions = function()
        return {
          expectedRegistryFingerprint = "registry",
          expectedTaskFingerprint = "tasks",
          resolveTask = function()
            return nil
          end,
          resolveComposition = function()
            return nil
          end,
        }
      end,
    },
  }
end

local function monsBucket()
  return MonsSave.empty(CatalogFixture.makeCatalog():fingerprint(), 7)
end

local function validPlayerData()
  return {
    profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0, nationalDex = false },
    options = { textFrame = 0, textSpeed = "mid" },
  }
end

local function validRecord(saveId)
  return {
    schema = GameSave.SCHEMA,
    saveId = saveId,
    versionId = "heartgold",
    playTimeSeconds = 0,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain-heartgold",
    facing = "south",
    playerData = validPlayerData(),
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    fashionCase = FashionCaseState.empty(),
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = {
      schema = "g4-script-save-v1",
      registryFingerprint = "registry",
      taskFingerprint = "tasks",
      capturedAtSimulationTick = 0,
      nextEnvironmentId = 0,
      nextInstanceId = 0,
      nextTaskId = 0,
      environments = {},
      instances = {},
      tasks = {},
    },
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = {},
    mons = monsBucket(),
    bag = BagSave.empty(),
    mart = MartSave.empty(),
    mailbox = Mailbox.new():capture(),
    photoAlbum = PhotoAlbum.new():capture(),
  }
end

local function quiescentScripts()
  return {
    schema = "g4-script-save-v1",
    registryFingerprint = "old-registry",
    taskFingerprint = "old-tasks",
    capturedAtSimulationTick = 41,
    nextEnvironmentId = 3,
    nextInstanceId = 5,
    nextTaskId = 7,
    environments = {},
    instances = {},
    tasks = {},
  }
end

local function v3record(saveId)
  local value = validRecord(saveId)
  value.schema = "g4-game-save-v3"
  value.mons.schema = MonsSave.LEGACY_SCHEMA
  value.mons.boxes = nil
  value.fieldTravel = nil
  value.fashionCase = nil
  value.mart = nil
  value.mailbox = nil
  value.photoAlbum = nil
  value.playerData = {
    profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
    options = { textFrame = 0, textSpeed = "mid" },
  }
  value.scripts = quiescentScripts()
  return value
end

local function newStore(backend)
  local loaded, GameSaveStore = pcall(require, "libs.hgss.src.save.GameSaveStore")
  Assert.isTrue(loaded, "global GameSave storage service is not implemented")
  local SaveFs = require("libs.storage.src.SaveFs")
  local service = GameSaveValidation.new({
    contextLoader = function()
      return fixtureContext()
    end,
  })
  return GameSaveStore.new(SaveFs.global(backend), {
    recordValidate = function(value)
      return service:validate(value)
    end,
  })
end

local function gamePath(saveId)
  return "saves/games/" .. saveId .. ".lua"
end

local function snapshotBytes(backend, saveId)
  local raw = assert(backend.files[gamePath(saveId)], "the payload file must exist before the fault")
  return raw
end

function T.tests.malformed_current_record_rejected_with_file_preserved()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local saveId = assert(store:reserve(), "reservation must succeed")
  Assert.isTrue(store:publishFirst(validRecord(saveId)), "a valid record must publish")
  local before = snapshotBytes(backend, saveId)
  local malformed = validRecord(saveId)
  malformed.fieldTravel = nil
  local ok, failure = pcall(function()
    return store:save(malformed)
  end)
  Assert.isFalse(ok, "a record without travel facts must not save")
  Assert.isTrue(Errors.is(failure), "the rejection must carry a structured error")
  Assert.equal(backend.files[gamePath(saveId)], before, "a rejected save must preserve the payload bytes")
  local loaded = assert(store:load(saveId), "the preserved record must still load")
  Assert.equal(loaded.fieldTravel.lastHealSpawn, "SPAWN_NEW_BARK", "the preserved record keeps its travel facts")
end

function T.tests.active_old_graph_rejected_with_file_preserved()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local saveId = assert(store:reserve(), "reservation must succeed")
  Assert.isTrue(store:publishFirst(validRecord(saveId)), "a valid record must publish")
  local before = snapshotBytes(backend, saveId)
  local active = validRecord(saveId)
  active.scripts.tasks = {
    {
      taskId = 1,
      taskType = "field_move",
      taskVersion = 1,
      ownerInstanceId = 1,
      environmentId = 1,
      state = {},
    },
  }
  local ok, failure = pcall(function()
    return store:save(active)
  end)
  Assert.isFalse(ok, "an incompatible active graph must not save")
  Assert.isTrue(Errors.is(failure), "the rejection must carry a structured error")
  Assert.equal(backend.files[gamePath(saveId)], before, "a rejected save must preserve the payload bytes")
  local loaded = assert(store:load(saveId), "the preserved record must still load")
  Assert.deepEqual(loaded.scripts.tasks, {}, "the preserved record keeps its quiescent graph")
end

function T.tests.v3_record_migrates_through_store_load()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local saveId = assert(store:reserve(), "reservation must succeed")
  Assert.isTrue(store:publishFirst(v3record(saveId)), "a quiescent v3 record must publish as migrated")
  local loaded = assert(store:load(saveId), "the migrated record must load")
  Assert.equal(loaded.schema, GameSave.SCHEMA, "load exposes the current migrated schema")
  Assert.equal(loaded.playerData.profile.badges, 0, "migration starts with zero badges")
  Assert.deepEqual(loaded.fieldTravel, { lastHealSpawn = "SPAWN_NEW_BARK" }, "migration seeds the mother spawn")
  Assert.equal(loaded.playerData.profile.name, "GOLD", "migration preserves the profile")
end

return { tests = T.tests, metadata = T.metadata }
