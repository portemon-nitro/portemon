-- Production Pokemon menu composition: the concrete factory over real
-- domain services. Covers collaborator assembly, partial-constructor
-- faults, and exactly-once disposal that releases owned field work while
-- sparing borrowed services. ROM-gated legs open real flows against the
-- versioned party manifest; pure legs use fixture services and synthetic
-- manifests. No planning vocabulary here: these are the composition's
-- own behavioral contracts.

local Assert = require("tests.support.Assert")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldMoveContext = require("game.hgss.src.field.FieldMoveContext")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GameVersion = require("romdump.src.source.GameVersion")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyCache = require("libs.assets.src.PartyCache")
local PcCache = require("libs.assets.src.PcCache")
local PcPresentationFixture = require("tests.support.PcPresentationFixture")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local COMPOSITION_MODULE = "game.hgss.src.field.PokemonMenuComposition"

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "bag:global", "party:global", "pc:global" },
    tags = { "menu", "composition" },
  },
  tests = {},
}

local function requireComposition()
  local ok, compositionModule = pcall(require, COMPOSITION_MODULE)
  Assert.isTrue(ok, "the production composition owns the menu collaborators: " .. tostring(compositionModule))
  return assert(compositionModule)
end

local function openMons(seed)
  local catalog = CatalogFixture.makeCatalog()
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
    signature = "menu-composition-test:256x192",
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

local function dependencies(overrides)
  local mons = openMons(0xC00517)
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
  local bag = openBag()
  local deps = {
    mons = mons,
    bag = bag,
    bagCursor = BagCursor.new(),
    itemCatalog = bag:catalog(),
    monCatalog = CatalogFixture.makeCatalog(),
    bagManifest = {},
    partyManifest = {},
    uiManifest = FieldUiFixture.manifest(),
    mailbox = Mailbox.new(),
    photoAlbum = PhotoAlbum.new(),
    pcManifest = PcPresentationFixture.manifest(),
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
    textPolicy = { interGlyphDelay = 0, glyphBudget = 512, abAcceleration = true },
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

function T.tests.create_assembles_the_complete_collaborator_set()
  local Composition = requireComposition()
  local deps = dependencies()
  local composition = Composition.create(deps)
  Assert.isTrue(type(composition.partyActions.commit) == "function", "composition exposes action publication")
  Assert.isTrue(type(composition.fieldMoves.queue) == "function", "composition exposes the field queue")
  Assert.isTrue(type(composition.fieldMoves.isBusy) == "function", "composition exposes the busy surface")
  Assert.isFalse(composition.fieldMoves:isBusy(), "a fresh composition holds no field operation")
  Assert.isTrue(type(composition.makeBagFlow) == "function", "composition exposes the bag flow factory")
  Assert.isTrue(type(composition.makePartyFlow) == "function", "composition exposes the party flow factory")
  Assert.isTrue(type(composition.makeMailboxChild) == "function", "composition exposes the Mailbox child factory")
  Assert.isTrue(type(composition.makeStorageChild) == "function", "composition exposes the Storage child factory")
  Assert.isTrue(
    type(composition.makePhotoAlbumChild) == "function",
    "composition exposes the Photo Album child factory"
  )
  local storage = composition.makeStorageChild(0)
  Assert.equal(storage:status().mode, 0, "Storage opens through the production composition")
  local photoAlbum = composition.makePhotoAlbumChild()
  Assert.equal(photoAlbum:status().presentation.inputKey, "photo-album", "Photo Album opens with its interface plan")
  storage:dispose()
  photoAlbum:dispose()
  Assert.isTrue(type(composition.dispose) == "function", "composition exposes disposal")
  composition.dispose()
end

function T.tests.missing_required_collaborators_fail_before_any_window_opens()
  local Composition = requireComposition()
  local required = {
    "mons",
    "bag",
    "bagCursor",
    "itemCatalog",
    "monCatalog",
    "bagManifest",
    "partyManifest",
    "uiManifest",
    "heroGender",
    "measureDisplay",
    "prepareIcons",
    "cancelIconPreparation",
    "contextSources",
    "worldPorts",
  }
  for _, key in ipairs(required) do
    local deps = dependencies()
    deps[key] = nil
    local ok = pcall(Composition.create, deps)
    Assert.isFalse(ok, "a missing " .. key .. " must fail composition")
  end
end

function T.tests.queued_work_flows_through_the_real_policy()
  local Composition = requireComposition()
  local composition = Composition.create(dependencies())
  local accepted = composition.fieldMoves:queue({
    move = "cut",
    slot = 0,
    context = cutContext(),
  })
  Assert.equal(accepted.kind, "accepted", "a badged cutter queues, got " .. tostring(accepted.kind))
  composition.fieldMoves:discardPending()
  local refused = composition.fieldMoves:queue({
    move = "cut",
    slot = 0,
    context = FieldMoveContext.capture(sources({ badges = 0 })),
  })
  Assert.equal(refused.kind, "need_badge", "a badgeless cutter is refused, got " .. tostring(refused.kind))
  composition.dispose()
end

function T.tests.dispose_cancels_owned_work_once_and_spares_borrowed_services()
  local Composition = requireComposition()
  local deps = dependencies()
  local monRevision = deps.mons:partyRevision()
  local bagRevision = deps.bag:revision()
  local composition = Composition.create(deps)
  local queued = composition.fieldMoves:queue({
    move = "cut",
    slot = 0,
    context = cutContext(),
  })
  Assert.equal(queued.kind, "accepted", "setup must queue, got " .. tostring(queued.kind))
  Assert.isTrue(composition.fieldMoves:isBusy(), "the queued request holds the runtime")
  composition.dispose()
  Assert.isFalse(composition.fieldMoves:isBusy(), "disposal releases the owned pending request")
  composition.dispose()
  Assert.isFalse(composition.fieldMoves:isBusy(), "a second disposal stays released")
  Assert.equal(deps.mons:partyRevision(), monRevision, "disposal never publishes mon state")
  Assert.equal(deps.bag:revision(), bagRevision, "disposal never publishes inventory state")
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

function T.tests.flow_factories_open_through_the_borrowed_manifests(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("flow roots need a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local Composition = requireComposition()
    local cacheFs = CacheFs.forVersion(versionId)
    local deps = dependencies({
      bagManifest = require("libs.assets.src.BagCache").loadManifest(cacheFs),
      partyManifest = PartyCache.loadManifest(cacheFs),
    })
    local composition = Composition.create(deps)
    local bagFlow = composition.makeBagFlow()
    Assert.isTrue(bagFlow:status().open, "the bag root opens")
    Assert.equal(bagFlow:status().page, "bag_browse", "a bag root opens the bag page")
    bagFlow:dispose()
    local partyFlow = composition.makePartyFlow()
    Assert.isTrue(partyFlow:status().open, "the party root opens")
    Assert.equal(partyFlow:status().page, "party_browse", "a party root opens the party page")
    partyFlow:dispose()
    composition.dispose()
  end
end

function T.tests.box_summary_moves_publish_to_the_selected_box()
  local versionId = "heartgold"
  local cacheFs = CacheFs.forVersion(versionId)
  local mons = openMons(0xC00517)
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
  mons:setMove(0, 0, "TACKLE")
  mons:setMove(0, 1, "GROWL")
  local partyBefore = mons:partyMon(0)
  local boxed = mons:partyMon(0)
  local prepared = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 0, mon = boxed } } }))
  prepared.publish()

  local bag = openBag()
  local composition = requireComposition().create(dependencies({
    mons = mons,
    bag = bag,
    pcManifest = PcCache.loadManifest(cacheFs),
    partyManifest = PartyCache.loadManifest(cacheFs),
    versionId = versionId,
    cacheFs = cacheFs,
    derivedAssets = {},
  }))
  local storage = composition.makeStorageChild(1)
  storage:updateFixed({ { type = "confirm" } })
  storage:updateFixed({ { type = "navigate", direction = "down" } })
  storage:updateFixed({ { type = "navigate", direction = "down" } })
  storage:updateFixed({ { type = "confirm" } })
  Assert.equal(storage:status().childKind, "summary", "Storage opens Summary for the selected box mon")
  for _, batch in ipairs({
    {},
    { { type = "navigate", direction = "down" } },
    { { type = "navigate", direction = "down" } },
    { { type = "confirm" } },
    { { type = "navigate", direction = "down" } },
    { { type = "confirm" } },
  }) do
    storage:updateFixed(batch)
  end
  local moved = assert(mons:boxMon(0, 0)).moves
  Assert.equal(moved[1].move, "GROWL", "the boxed subject publishes its move reordering")
  Assert.equal(moved[2].move, "TACKLE")
  Assert.deepEqual(mons:partyMon(0), partyBefore, "boxed Summary never routes through Party")
  storage:dispose()
  composition.dispose()
end

return T
