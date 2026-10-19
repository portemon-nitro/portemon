-- Field consumer facts over the single dex owner: the Start Menu
-- shows the dex entry exactly when the owner is enabled, phone counts
-- and national ownership read explicit display membership instead of
-- raw bucket lengths or completion, and the Box info panel follows a
-- current mode provider without rebuilding the menu composition. A
-- generic story-flag write never stands in for the owner. Uses the
-- small synthetic mon/catalog fixtures with the production menu, phone,
-- and storage composition; no ROM, GPU, or product cache is touched.

local Assert = require("tests.support.Assert")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeCache = require("tests.support.FakeCache")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldMenuCompositionCoordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local MenuProtocol = require("libs.assets.src.MenuProtocol")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyMenuComposition = require("game.hgss.src.field.PartyMenuComposition")
local PhoneWorldContext = require("game.hgss.src.pokegear.PhoneWorldContext")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local PcPresentationFixture = require("tests.support.PcPresentationFixture")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local SOURCE_LABEL_BANK = MenuProtocol.START_MENU_MESSAGE_BANK

local function manifestWithIcons()
  local manifest = FieldUiFixture.manifest()
  FieldUiFixture.addStartMenuIconContract(manifest)
  return manifest
end

local function seedLabelBank(cache)
  local messages = {
    [0] = "DEX-LABEL",
    [1] = "PARTY-LABEL",
    [2] = "BAG-LABEL",
    [4] = "SAVE-LABEL",
    [5] = "OPTIONS-LABEL",
    [14] = "GEAR-LABEL",
  }
  local bank = {}
  for id, text in pairs(messages) do
    bank[id] = { id = id, text = text, raw = {}, tokens = {} }
  end
  cache:writeLua(FieldMessageCache.bankPath(SOURCE_LABEL_BANK), {
    schema = FieldMessageCache.SCHEMA,
    bankId = SOURCE_LABEL_BANK,
    messageCount = 15,
    key = 0,
    messages = bank,
  })
end

local function providerWithLabels()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  seedLabelBank(cache)
  local provider = FieldMessageProvider.new(cache)
  local bank, err = provider:acquireBank(SOURCE_LABEL_BANK)
  assert(bank ~= nil, err and err.message or "the source label bank must acquire")
  return provider
end

local function worldWith(flagNames)
  local set = {}
  for _, name in ipairs(flagNames or {}) do
    set[assert(FieldScriptSymbols.flagsByName[name], "unknown world flag " .. name)] = true
  end
  return {
    isFlagSet = function(_, flag)
      return set[flag] == true
    end,
  }
end

local function openOwner()
  local monCatalog = PokedexDexFixture.makeCatalog()
  local pokedexCatalog = PokedexDexFixture.buildPokedexCatalog()
  local owner = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, pokedexCatalog))
  return owner
end

local function menuSelf(overrides)
  overrides = overrides or {}
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = false,
    role = "world",
  })
  return {
    scripts = { worldState = overrides.worldState or worldWith({}) },
    dexKnowledge = overrides.dexKnowledge,
    uiManifest = manifestWithIcons(),
    playerData = { profile = { name = "PLAYER", badges = 0, runningShoes = false, runningShoesLock = false } },
    playerAvatar = {
      durableState = function()
        return "walking"
      end,
    },
    messageProvider = providerWithLabels(),
    applications = {
      has = function()
        return true
      end,
    },
    monService = {
      partyCount = function()
        return 1
      end,
    },
    bagService = {},
    bagCursor = {},
    itemCatalog = {},
    saveStore = {},
    audio = nil,
    presentationDisplay = {
      width = 640,
      height = 480,
      topology = topology,
      pixelRatio = 1,
      signature = "consumer-facts",
    },
    applicationHost = {
      phase = function()
        return "menu"
      end,
    },
  }
end

local function hasMenuEntry(status, id)
  Assert.isTrue(status.open, "the start menu must stay open")
  for _, action in ipairs(status.actions) do
    if action.id == id then
      return true
    end
  end
  return false
end

function T.menu_visibility_follows_the_owner_not_the_story_flag()
  local owner = openOwner()
  owner:prepareChanges({ flags = { dexEnabled = true } }):publish()

  local enabled = FieldMenuCompositionCoordinator.new(menuSelf({
    worldState = worldWith({}),
    dexKnowledge = owner,
  })):composeStartMenu()
  Assert.isTrue(
    hasMenuEntry(enabled:status(), "vanilla.pokedex"),
    "an enabled owner shows the dex entry without the story flag"
  )

  local locked = openOwner()
  local flagged = FieldMenuCompositionCoordinator.new(menuSelf({
    worldState = worldWith({ "FLAG_GOT_POKEDEX" }),
    dexKnowledge = locked,
  })):composeStartMenu()
  Assert.isFalse(
    hasMenuEntry(flagged:status(), "vanilla.pokedex"),
    "a locked owner hides the dex entry despite the story flag"
  )
end

local function seedDisplayHistory(owner)
  owner
    :prepareChanges({
      caught = { "CHIKORITA", "EEVEE", "CUSTOM_IN", "CUSTOM_OUT_A", "CUSTOM_OUT_B" },
    })
    :publish()
  owner:prepareChanges({ flags = { nationalDex = true } }):publish()
end

local function phoneRuntime(owner)
  return {
    session = { currentMap = { mapSectionNativeId = 7 } },
    playerData = { profile = { money = 3000 } },
    dexKnowledge = owner,
  }
end

local function phoneFlags()
  return {
    isFlagSet = function()
      return false
    end,
  }
end

function T.phone_facts_read_ownership_and_explicit_counts()
  local owner = openOwner()
  seedDisplayHistory(owner)
  local context = PhoneWorldContext.new({ state = {}, runtime = phoneRuntime(owner), flags = phoneFlags() })
  local facts = context:callFacts({ map = 7 })
  Assert.equal(facts.dexSeen, owner:countSeen("national"), "the seen fact counts explicit display members")
  Assert.equal(facts.dexSeen, 3, "outside keys never enter the seen fact")
  Assert.equal(facts.dexCaught, owner:countCaught("national"), "the caught fact counts explicit display members")
  Assert.equal(facts.dexCaught, 3, "outside keys never enter the caught fact")
  Assert.isTrue(facts.nationalDex, "national ownership reads true while the set stays incomplete")
  Assert.isFalse(owner:isNationalDexComplete(), "setup keeps the national set incomplete behind the ownership fact")
end

function T.phone_domain_reads_match_the_call_facts()
  local owner = openOwner()
  seedDisplayHistory(owner)
  local context = PhoneWorldContext.new({ state = {}, dex = owner })
  Assert.equal(context:read("dex.seen"), 3, "the seen domain read excludes outside keys")
  Assert.equal(context:read("dex.caught"), 3, "the caught domain read excludes outside keys")
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
    signature = "consumer-facts:256x192",
  }
end

local function openMons()
  local catalog = CatalogFixture.makeCatalog()
  local mons = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xC0FFEE):capture()),
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

local function worldPorts()
  return {
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
    events = FieldEventState.new(),
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
end

local function boxDeps(overrides)
  local mons = openMons()
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
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
    contextSources = function()
      return { badges = 0xFFFF, mapSymbol = "MAP_ROUTE_29", mapId = 200, fieldUse = fieldUse() }
    end,
    worldPorts = worldPorts(),
    summaryManifest = {
      dexNumbers = {
        CHIKORITA = { regional = 7, national = 152 },
      },
    },
    dexMode = "regional",
  }
  for key, item in pairs(overrides or {}) do
    deps[key] = item
  end
  return deps
end

local function partyInfoNumber(composition)
  local storage = composition.makeStorageChild(0)
  local info = assert(storage:status().visualView.info, "the focused party mon carries info-panel facts")
  local number = info.dexNumber
  storage:dispose()
  return number
end

function T.box_numbering_keeps_explicit_string_modes()
  local composition = PartyMenuComposition.create(boxDeps({ dexMode = "regional" }))
  Assert.equal(partyInfoNumber(composition), 7, "an explicit regional mode prints the regional number")
  composition.dispose()
  local national = PartyMenuComposition.create(boxDeps({ dexMode = "national" }))
  Assert.equal(partyInfoNumber(national), 152, "an explicit national mode prints the national number")
  national.dispose()
end

function T.box_numbering_follows_a_current_mode_provider_without_rebuilding()
  local owner = openOwner()
  local function currentMode()
    if owner:hasNationalDex() then
      return "national"
    end
    return "regional"
  end
  local composition = PartyMenuComposition.create(boxDeps({ dexMode = currentMode }))
  Assert.equal(partyInfoNumber(composition), 7, "a locked owner prints the regional number")
  owner:prepareChanges({ flags = { nationalDex = true } }):publish()
  Assert.equal(
    partyInfoNumber(composition),
    152,
    "a fresh Box context observes the unlock without rebuilding the composition"
  )
  composition.dispose()
end

return { tests = T }
