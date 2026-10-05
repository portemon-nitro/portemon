-- Production menu/field handoff wiring: admission refusal can never look
-- like success, the host admits before releasing UI, busy saves are
-- denied, teardown releases exactly once, and the capability vocabulary
-- stays closed and honest. Pure legs run without a ROM over fixture
-- services and real leaves; ROM journeys live in the acceptance file
-- beside them. No planning vocabulary here.

local Assert = require("tests.support.Assert")
local BagActionPolicy = require("libs.hgss.src.ui.BagActionPolicy")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldMoveContext = require("game.hgss.src.field.FieldMoveContext")
local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")
local FieldMoveTask = require("libs.hgss.src.script.tasks.FieldMoveTask")
local FieldMenuCompositionCoordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldSaveCoordinator = require("game.hgss.src.field.FieldSaveCoordinator")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local PcCache = require("libs.assets.src.PcCache")
local BagCache = require("libs.assets.src.BagCache")
local PartyCache = require("libs.assets.src.PartyCache")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyActions = require("libs.hgss.src.field.PartyActions")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {
  metadata = { tags = { "menu", "wiring", "handoff" } },
  tests = {},
}

local function openMons(seed)
  local catalog = CatalogFixture.makeCatalog()
  local mons = HgssMonService.new({
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
  Assert.isTrue(
    mons:giveMon({
      species = "CHIKORITA",
      level = 5,
      heldItem = "NONE",
      form = 0,
      location = 7,
      date = CatalogFixture.metDate(),
    }),
    "setup gift must enter the party"
  )
  return mons
end

local function openBag()
  return HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
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
    signature = "menu-wiring-test:256x192",
  }
end

local function fieldUse()
  return {
    flyAllowed = true,
    teleportAllowed = true,
    escapeAllowed = true,
    flashUsable = true,
    unionOrColosseum = false,
    cave = false,
    icePathB2F = false,
    alphChamber = false,
    headbuttUsable = false,
    sweetScentUsable = false,
    rockSmashUsable = true,
    cutUsable = true,
    strengthUsable = true,
    surfUsable = true,
    waterfallUsable = true,
    whirlpoolUsable = true,
    rockClimbUsable = true,
    digUsable = true,
  }
end

local function sources(overrides)
  local value = {
    badges = 0xFFFF,
    mapSymbol = "MAP_ROUTE_29",
    mapId = 200,
    fieldUse = fieldUse(),
    avatarMode = "walking",
    humanFollower = false,
    followingMon = false,
    rocketCostume = false,
    safari = false,
    palPark = false,
    surfEdge = false,
    facingWaterfall = false,
    facingWhirlpool = false,
    climbTile = false,
    headbuttTree = false,
    foggy = false,
    chatterOpen = false,
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function cutTreeActor()
  return {
    identity = "map:200:object:4",
    obstacleKind = "cut_tree",
    mapSymbol = "MAP_ROUTE_29",
    fieldX = 9,
    fieldZ = 3,
  }
end

local function cutContext()
  return FieldMoveContext.capture(sources({ facingActor = cutTreeActor() }))
end

local function worldPorts(overrides)
  local ports = {
    actors = {
      getActor = function()
        return nil
      end,
      actorsOf = function()
        return {}
      end,
      getPosition = function()
        return nil
      end,
      getCollisionAt = function()
        return nil
      end,
      beginScriptedAction = function() end,
      advanceScriptedAction = function() end,
      commitScriptedAction = function() end,
      cancelScriptedMovement = function() end,
      isScriptedMoving = function()
        return false
      end,
      removePresence = function() end,
      syncEventStateChanges = function() end,
    },
    events = {
      setFlag = function() end,
      isFlagSet = function()
        return false
      end,
    },
    maps = {
      current = function()
        return { symbol = "test-map", id = 61, fieldUse = {} }
      end,
      runtimeMap = function()
        return {}
      end,
    },
    player = {
      position = function()
        return { fieldX = 4, fieldZ = 5, worldY = 0 }
      end,
      facing = function()
        return "south"
      end,
      beginScriptedAction = function() end,
      advanceScriptedAction = function() end,
      commitScriptedAction = function() end,
      cancelScriptedMovement = function() end,
      isScriptedMoving = function()
        return false
      end,
      queueAvatarTransition = function() end,
      applyAvatarTransitions = function() end,
    },
    profile = { badges = 0xFFFF },
    weather = {
      change = function() end,
    },
    reactions = {
      dispatch = function() end,
    },
  }
  for key, item in pairs(overrides or {}) do
    ports[key] = item
  end
  return ports
end

local function pcManifest()
  local stationery = {}
  for stationeryType = 0, 11 do
    stationery[stationeryType] = { itemKey = "MAIL_" .. stationeryType }
  end
  return {
    schema = "g4-pc-v2",
    mailbox = { background = {}, geometry = { visibleLetters = 10 }, pageSize = 10 },
    mail = { stationery = stationery, geometry = { iconSlots = 3 }, text = { templates = {} }, wordDictionary = {} },
  }
end

local function compositionDeps(overrides)
  local mons = openMons(90210)
  local bag = openBag()
  local deps = {
    mons = mons,
    bag = bag,
    bagCursor = BagCursor.new(),
    itemCatalog = bag:catalog(),
    monCatalog = CatalogFixture.makeCatalog(),
    mailbox = Mailbox.new(),
    photoAlbum = PhotoAlbum.new(),
    pcManifest = pcManifest(),
    bagManifest = {},
    partyManifest = {},
    uiManifest = FieldUiFixture.manifest(),
    profile = CatalogFixture.profile(),
    versionId = "heartgold",
    cacheFs = {},
    derivedAssets = {},
    charmap = CatalogFixture.CHARMAP,
    heroGender = "male",
    measureDisplay = stubMeasurement,
    prepareIcons = function(_)
      return true
    end,
    cancelIconPreparation = function() end,
    contextSources = function()
      return sources()
    end,
    worldPorts = worldPorts(),
  }
  for key, item in pairs(overrides or {}) do
    deps[key] = item
  end
  return deps
end

local function openComposition(overrides)
  local Composition = require("game.hgss.src.field.PokemonMenuComposition")
  return Composition.create(compositionDeps(overrides))
end

-- The closed capability vocabulary, asserted against the real policy.
-- Each row names the capability, the physical setup, and the honest
-- outcome class plus its explanation. Characterization of locked leaf
-- behavior: a flipped cell goes red (spot-checked by mutation during
-- authoring: an "ok" expectation for the badgeless cutter fails with
-- need_badge).
local function treeActor(kind)
  return {
    identity = "map:200:object:4",
    obstacleKind = kind,
    mapSymbol = "MAP_ROUTE_29",
    fieldX = 9,
    fieldZ = 3,
  }
end

local CAPABILITY_MATRIX = {
  { capability = "cut", setup = { badges = 0xFFFF, facingActor = treeActor("cut_tree") }, expect = "ok" },
  { capability = "cut", setup = { badges = 0 }, expect = "need_badge", reason = "hive" },
  { capability = "cut", setup = { badges = 0xFFFF }, expect = "not_here" },
  { capability = "surf", setup = { badges = 0xFFFF, surfEdge = true }, expect = "ok" },
  { capability = "surf", setup = { badges = 0, surfEdge = true }, expect = "need_badge", reason = "fog" },
  {
    capability = "surf",
    setup = { badges = 0xFFFF, surfEdge = true, avatarMode = "surfing" },
    expect = "already_surfing",
  },
  { capability = "fly", setup = { badges = 0xFFFF }, expect = "ok" },
  { capability = "fly", setup = { badges = 0 }, expect = "need_badge", reason = "storm" },
  {
    capability = "strength",
    setup = { badges = 0xFFFF, facingActor = treeActor("strength_boulder") },
    expect = "ok",
  },
  { capability = "flash", setup = { badges = 0xFFFF }, expect = "ok" },
  {
    capability = "rock_smash",
    setup = { badges = 0xFFFF, facingActor = treeActor("smash_rock") },
    expect = "ok",
  },
  { capability = "rock_smash", setup = { badges = 0 }, expect = "need_badge", reason = "zephyr" },
  { capability = "dig", setup = { badges = 0xFFFF, caveMap = true }, expect = "ok" },
  { capability = "dig", setup = { badges = 0xFFFF }, expect = "not_here" },
  { capability = "teleport", setup = { badges = 0xFFFF }, expect = "ok" },
  {
    capability = "waterfall",
    setup = { badges = 0xFFFF, avatarMode = "surfing", facingWaterfall = true },
    expect = "ok",
  },
  {
    capability = "whirlpool",
    setup = { badges = 0xFFFF, avatarMode = "surfing", facingWhirlpool = true },
    expect = "ok",
  },
  { capability = "rock_climb", setup = { badges = 0xFFFF, climbTile = true }, expect = "ok" },
  { capability = "headbutt", setup = { badges = 0xFFFF, headbuttTree = true }, expect = "feature_unavailable" },
  { capability = "headbutt", setup = { badges = 0xFFFF }, expect = "not_here" },
  { capability = "sweet_scent", setup = { badges = 0xFFFF }, expect = "feature_unavailable" },
  { capability = "chatter", setup = { badges = 0xFFFF, chatterOpen = true }, expect = "feature_unavailable" },
  { capability = "chatter", setup = { badges = 0xFFFF }, expect = "not_here" },
}

function T.tests.capability_limits_are_honest_and_closed()
  for _, row in ipairs(CAPABILITY_MATRIX) do
    local merged = {}
    for key, value in pairs(row.setup) do
      if key ~= "caveMap" then
        merged[key] = value
      end
    end
    if row.setup.caveMap == true then
      merged.fieldUse = fieldUse()
      merged.fieldUse.cave = true
      merged.fieldUse.escapeAllowed = true
    end
    local context = FieldMoveContext.capture(sources(merged))
    local decision = FieldMovePolicy.check(row.capability, context)
    local label = row.capability .. " must answer " .. row.expect
    Assert.equal(decision.kind, row.expect, label .. ", got " .. tostring(decision.kind))
    if row.reason ~= nil then
      Assert.equal(decision.badge, row.reason, label .. " names its badge")
    end
    if row.expect == "feature_unavailable" then
      Assert.isTrue(type(decision.reason) == "string", label .. " explains its limitation")
    end
  end
end

function T.tests.deferred_items_explain_without_consuming()
  local root = ItemFixture.buildAssetRoot()
  root.items.ITEM_421.partyUse = { kind = "deferred", reason = "level_up" }
  local catalog = ItemCatalog.new(root)
  local bag = HgssBagService.new({ catalog = catalog })
  local facts = BagActionPolicy.fieldFacts(bag, "ITEM_421")
  Assert.equal(facts.useKind, "deferred", "a deferred item keeps its Use entry point")
  Assert.equal(facts.featureReason, "level_up", "a deferred item names its stable limitation")
  local mons = openMons(90211)
  local actions = PartyActions.new({ mons = mons, bag = bag })
  Assert.isTrue(bag:add("ITEM_421", 1), "setup must stock the deferred item")
  local monRevision = mons:partyRevision()
  local bagRevision = bag:revision()
  local outcome = actions:commit({
    kind = "use_item",
    slot = 0,
    partyRevision = monRevision,
    bagRevision = bagRevision,
    item = "ITEM_421",
  })
  Assert.equal(outcome.kind, "feature_unavailable", "a deferred use reports its limit, got " .. tostring(outcome.kind))
  Assert.equal(bag:quantity("ITEM_421"), 1, "a deferred use consumes nothing")
  Assert.equal(mons:partyRevision(), monRevision, "a deferred use publishes no mon state")
  Assert.equal(bag:revision(), bagRevision, "a deferred use publishes no inventory state")
end

local function admissionRuntime(composition, client, readerOverrides)
  local readers = {
    playerData = { profile = { badges = 0 } },
    runtimeMap = {
      mapSymbol = "MAP_ROUTE_29",
      mapId = 200,
      fieldData = { fieldUse = fieldUse() },
      effectiveWeatherId = 11,
      coordinateOrigin = { x = 0, z = 0 },
      collision = {
        getLocal = function()
          return nil
        end,
        containsLocal = function()
          return true
        end,
      },
    },
    player = { fieldX = 4, fieldZ = 5, facing = "south" },
    actors = {
      actorsOf = function()
        return { { actorId = "test:tree", sourceEvent = { obstacleKind = "cut_tree" } } }
      end,
      getPosition = function(_, actorId)
        if actorId == "test:tree" then
          return { fieldX = 4, fieldZ = 6 }
        end
        return nil
      end,
    },
    playerAvatar = {
      status = function()
        return { durableState = "walking" }
      end,
    },
    followingMon = nil,
  }
  for key, item in pairs(readerOverrides or {}) do
    readers[key] = item
  end
  local runtime = setmetatable({
    session = { tick = 41 },
    pokemonMenu = composition,
    scripts = { client = client },
    playerData = readers.playerData,
    runtimeMap = readers.runtimeMap,
    player = readers.player,
    actors = readers.actors,
    playerAvatar = readers.playerAvatar,
    followingMon = readers.followingMon,
  }, FieldRuntime)
  runtime.menuComposer = FieldMenuCompositionCoordinator.new(runtime)
  return runtime
end

function T.tests.stale_admission_refusal_never_reaches_the_scheduler()
  local composition = openComposition()
  local calls = 0
  local client = {
    startApplicationScript = function()
      calls = calls + 1
      return "instance-1"
    end,
  }
  -- No badges on the live profile: facts changed since any earlier
  -- check, so the admission recheck refuses on the current record.
  local runtime = admissionRuntime(composition, client)
  local stale = { move = "cut", slot = 0 }
  local ok, err = pcall(runtime._admitFieldAction, runtime, "pokemon.field_move", stale)
  Assert.isFalse(ok, "a stale admission must raise, never return normally")
  Assert.equal(calls, 0, "a refused admission never reaches the scheduler")
  Assert.isFalse(composition.fieldMoves:isBusy(), "a refused admission holds nothing")
  local message = tostring(err)
  Assert.isTrue(
    message:find("_admitFieldAction", 1, true) ~= nil or message:find("admission", 1, true) ~= nil,
    "the refusal names the admission boundary: " .. message
  )
  composition.dispose()
end

function T.tests.busy_second_request_is_refused_without_touching_the_first()
  local composition = openComposition()
  local first = composition.fieldMoves:queue({
    move = "cut",
    slot = 0,
    context = cutContext(),
  })
  Assert.equal(first.kind, "accepted", "setup must queue, got " .. tostring(first.kind))
  -- Badged live facts: the recheck passes, so the refusal comes from
  -- the held first request rather than eligibility.
  local runtime = admissionRuntime(composition, {
    startApplicationScript = function()
      error("a busy admission must never schedule", 0)
    end,
  }, { playerData = { profile = { badges = 0xFFFF } } })
  local ok, err = pcall(runtime._admitFieldAction, runtime, "pokemon.field_move", { move = "cut", slot = 0 })
  Assert.isFalse(ok, "a busy second admission must raise")
  Assert.isTrue(tostring(err):find("busy", 1, true) ~= nil, "the refusal names the held operation: " .. tostring(err))
  Assert.isTrue(composition.fieldMoves:isBusy(), "the first request still holds the runtime")
  composition.fieldMoves:discardPending()
  composition.dispose()
end

local function menuDouble(launchResult, order)
  local launched = false
  return {
    updateFixed = function() end,
    takeResult = function()
      if launched then
        return nil
      end
      launched = true
      return launchResult
    end,
    dispose = function()
      order[#order + 1] = "dispose-menu"
    end,
    cancelPointerCapture = function() end,
    status = function()
      return { open = true }
    end,
  }
end

local function flowChildDouble(result, order)
  local terminal = result
  return {
    updateFixed = function() end,
    takeResult = function()
      local pending = terminal
      terminal = nil
      return pending
    end,
    dispose = function()
      order[#order + 1] = "dispose-child"
    end,
    cancelPointerCapture = function() end,
    status = function()
      return { open = true }
    end,
  }
end

local function hostWithDoubles(menu, child, fieldAction, order)
  local input = {
    beginUi = function()
      order[#order + 1] = "begin-ui"
    end,
    clearUi = function()
      order[#order + 1] = "release-ui"
    end,
  }
  local registry = {
    create = function()
      return child
    end,
  }
  return FieldApplicationHost.new({
    registry = registry,
    menuFactory = function()
      return menu
    end,
    input = input,
    fieldAction = fieldAction,
  })
end

function T.tests.application_child_field_action_admits_before_ui_release()
  local order = {}
  local child =
    flowChildDouble({ kind = "field_action", actionId = "pokemon.field_move", request = { move = "cut" } }, order)
  local menu = menuDouble({ kind = "launch", applicationId = "pokemon", actionId = "vanilla.pokemon" }, order)
  local host = hostWithDoubles(menu, child, function(actionId, request)
    order[#order + 1] = "admit:" .. tostring(actionId) .. ":" .. tostring(request.move)
  end, order)
  Assert.isTrue(host:requestOpen(0), "the menu opens")
  host:updateFixed({})
  Assert.equal(host:status().phase, FieldApplicationHost.PHASES.application, "the launch publishes the child")
  host:updateFixed({})
  Assert.equal(host:status().phase, FieldApplicationHost.PHASES.closed, "an admitted handoff closes the host")
  Assert.equal(order[1], "begin-ui", "the modal lifetime begins first")
  Assert.equal(order[2], "admit:pokemon.field_move:cut", "admission runs before any release")
  Assert.equal(order[#order], "release-ui", "UI releases last")
  local releases = 0
  for _, entry in ipairs(order) do
    if entry == "release-ui" then
      releases = releases + 1
    end
  end
  Assert.equal(releases, 1, "the modal lifetime releases exactly once")
end

function T.tests.unexpected_admission_errors_follow_the_host_failure_path()
  local order = {}
  local marker = {}
  local child =
    flowChildDouble({ kind = "field_action", actionId = "pokemon.field_move", request = { move = "cut" } }, order)
  local menu = menuDouble({ kind = "launch", applicationId = "pokemon", actionId = "vanilla.pokemon" }, order)
  local host = hostWithDoubles(menu, child, function()
    error(marker, 0)
  end, order)
  Assert.isTrue(host:requestOpen(0), "the menu opens")
  host:updateFixed({})
  host:updateFixed({})
  Assert.equal(host:status().phase, FieldApplicationHost.PHASES.failed, "an admission error fails the host")
  Assert.isTrue(host:error() == marker, "the original admission error propagates")
end

function T.tests.save_capture_is_denied_while_a_field_operation_is_pending()
  local PlayTime = require("libs.hgss.src.save.PlayTime")
  local composition = openComposition()
  local queued = composition.fieldMoves:queue({
    move = "cut",
    slot = 0,
    context = cutContext(),
  })
  Assert.equal(queued.kind, "accepted", "setup must queue, got " .. tostring(queued.kind))
  local runtime = setmetatable({
    game = { saveId = "save-wiring", versionId = "heartgold" },
    saveId = "save-wiring",
    versionId = "heartgold",
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
      options = { textSpeed = "mid", textFrame = 0 },
    },
    fieldTravel = require("libs.hgss.src.field.FieldTravelState").new({ lastHealSpawn = "SPAWN_NEW_BARK" }),
    session = {
      tick = 42,
      player = { motion = "idle", fieldX = 1, fieldZ = 2, worldY = 0, surfaceId = 1, facing = "south" },
      currentMap = { mapId = 60, terrainDependencyHash = "terrain-test", effectiveWeatherId = 11 },
    },
    scripts = {
      worldState = {
        capture = function(_, objects)
          return { flags = {}, variables = {}, objects = objects, rng = { state = 1, calls = 2 } }
        end,
      },
      scheduler = {},
      registryFingerprint = function()
        return "registry-fingerprint"
      end,
    },
    actors = {
      captureObjects = function()
        return { schema = "g4-field-objects-v1", rng = { state = 7, calls = 3 }, actors = {} }
      end,
    },
    auxiliaryFieldUi = {
      capture = function()
        return {}
      end,
    },
    audio = nil,
    playTime = PlayTime.new(17),
    monService = {
      capture = function()
        return require("libs.mons.src.MonsSave").empty("test-catalog-fingerprint", 7)
      end,
    },
    bagService = {
      capture = function()
        return require("libs.hgss.src.save.BagSave").empty()
      end,
    },
    saveValidation = {
      validate = function(_, record)
        return record
      end,
    },
    pokemonMenu = composition,
  }, FieldRuntime)
  runtime.saveCoordinator = FieldSaveCoordinator.new(runtime)
  local record, reason = runtime:captureGameSave()
  Assert.isNil(record, "a pending field operation denies capture")
  Assert.isTrue(type(reason) == "string" and reason ~= "", "the denial explains itself")
  composition.fieldMoves:discardPending()
  composition.dispose()
end

function T.tests.save_capture_is_denied_while_a_pc_application_owns_field_ui()
  local runtime = setmetatable({
    session = {
      player = { motion = "idle" },
      transition = { phase = "idle" },
      mapEntryController = { isActive = function() return false end },
    },
    pcApplicationHost = { isActive = function() return true end },
  }, FieldRuntime)
  runtime.saveCoordinator = FieldSaveCoordinator.new(runtime)
  local record, reason = runtime:captureGameSave()
  Assert.isNil(record, "an open PC application cannot publish a partial snapshot")
  Assert.isTrue(type(reason) == "string" and reason ~= "", "the denial explains itself")
end

function T.tests.context_free_cancel_marks_state_and_disposal_releases_once()
  local composition = openComposition()
  local state = { plan = { kind = "cut", phase = "acknowledge", ticksLeft = 3, committed = false } }
  FieldMoveTask.cancel(state, "test-teardown", nil)
  Assert.equal(state.cancelled, "test-teardown", "a context-free cancel marks the serializable state")
  composition.dispose()
  composition.dispose()
  Assert.isFalse(composition.fieldMoves:isBusy(), "repeated disposal never repolls work")
end

function T.tests.field_menu_coordinator_passes_its_runtime_mailbox_and_loaded_pc_manifest()
  local deps = compositionDeps()
  local mailbox = Mailbox.new()
  local pcManifest = pcManifest()
  local cacheFs = {}
  local originalPcLoad, originalBagLoad, originalPartyLoad =
    PcCache.loadManifest, BagCache.loadManifest, PartyCache.loadManifest
  local seenPcFs
  PcCache.loadManifest = function(fs)
    seenPcFs = fs
    return pcManifest
  end
  BagCache.loadManifest = function(fs)
    Assert.equal(fs, cacheFs, "Bag assets use the requested version cache")
    return deps.bagManifest
  end
  PartyCache.loadManifest = function(fs)
    Assert.equal(fs, cacheFs, "Party assets use the requested version cache")
    return deps.partyManifest
  end
  local runtime = {
    avatar = { gender = 0 },
    transition = {},
    mapLoader = {},
    runtimeMap = { mapSymbol = "MAP_ROUTE_29", mapId = 200, fieldData = { fieldUse = {} } },
    actors = deps.worldPorts.actors,
    eventState = deps.worldPorts.events,
    playerData = { profile = deps.worldPorts.profile, options = { textSpeed = "mid" } },
    player = {},
    playerAvatar = {},
    presentationDisplay = stubMeasurement(),
    versionId = "heartgold",
    derivedAssets = deps.derivedAssets,
    fontDef = { charmap = CatalogFixture.CHARMAP },
    monService = deps.mons,
    bagService = deps.bag,
    mailbox = mailbox,
    photoAlbum = PhotoAlbum.new(),
    bagCursor = deps.bagCursor,
    itemCatalog = deps.itemCatalog,
    monCatalog = deps.monCatalog,
    uiManifest = deps.uiManifest,
    _partyIconPreparation = { prepare = deps.prepareIcons, cancel = deps.cancelIconPreparation },
    applyAvatarTransitions = function() end,
  }
  local coordinator = FieldMenuCompositionCoordinator.new(runtime)
  coordinator.menuFieldSources = function()
    return deps.contextSources
  end
  coordinator.menuPlayerPort = function()
    return deps.worldPorts.player
  end
  local ok, message = pcall(function()
    coordinator:composePokemonMenu(cacheFs)
    Assert.equal(seenPcFs, cacheFs, "the production composition validates PC assets through its version cache")
    local child = runtime.pokemonMenu.makeMailboxChild()
    Assert.equal(child.mailbox, mailbox, "the child borrows the runtime Mailbox owner")
    Assert.equal(child.manifest, pcManifest, "the child receives PcCache's validated manifest")
    child:dispose()
    runtime.pokemonMenu.dispose()
  end)
  PcCache.loadManifest, BagCache.loadManifest, PartyCache.loadManifest =
    originalPcLoad, originalBagLoad, originalPartyLoad
  if not ok then
    error(message, 0)
  end
end

return T
