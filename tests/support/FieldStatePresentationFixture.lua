-- Complete presentation cache for real FieldState construction tests: the
-- base field-UI font/frames plus the Trainer Card front, one minimal mon
-- icon class, the minimal item icon/atlas and Bag/Mart manifests/images
-- the eager child presentation resources require, the minimal party manifest
-- and images the eager party presentation resources require, and the
-- minimal field-actor
-- index/visual/atlas FieldState presentation loaders currently require.

local LuaWriter = require("libs.codec.src.LuaWriter")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")
local PartyCache = require("libs.assets.src.PartyCache")
local BagCache = require("libs.assets.src.BagCache")
local MartCache = require("libs.assets.src.MartCache")
local ItemCache = require("libs.assets.src.ItemCache")
local MonCache = require("libs.assets.src.MonCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local PcCache = require("libs.assets.src.PcCache")
local BagPresentationFixture = require("tests.support.BagPresentationFixture")
local MartFixture = require("tests.support.MartFixture")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local PcPresentationFixture = require("tests.support.PcPresentationFixture")

local FieldStatePresentationFixture = {}

---@param width integer
---@param height integer
---@return string
local function solidPng(width, height)
  local pixels = {}
  for _ = 1, width * height do
    pixels[#pixels + 1] = string.char(255, 255, 255, 255)
  end
  return PngWriter.encode(width, height, table.concat(pixels))
end

-- Minimal schema-valid party manifest: the same shapes the PartyCache test
-- proves in libs/assets/tests/party_cache_test.lua, with
-- fixture-local image paths. The eager party presentation resources
-- resolve panels, first-frame sequences, digit/level/slash glyphs and
-- prompt chrome from these records during FieldState construction.
---@return table<string, unknown>
local function partyManifest()
  local function imageRef(path, width, height)
    return { image = path, width = width, height = height }
  end
  local function frameRef(path, width, height, durationTicks)
    return { image = path, width = width, height = height, durationTicks = durationTicks }
  end
  local function rect(x, y, width, height)
    return { x = x, y = y, width = width, height = height }
  end
  local function touch(top, bottom, left, right)
    return { top = top, bottom = bottom, left = left, right = right }
  end
  local panels = {}
  local origins = { { 0, 0 }, { 128, 8 }, { 0, 48 }, { 128, 56 }, { 0, 96 }, { 128, 104 } }
  for slot, origin in ipairs(origins) do
    panels[slot] = {
      origin = { x = origin[1], y = origin[2] },
      size = { width = 128, height = 48 },
      iconAnchor = { x = origin[1] + 30, y = origin[2] + 16 },
      ballAnchor = { x = origin[1] + 16, y = origin[2] + 14 },
      heldAnchor = { x = origin[1] + 38, y = origin[2] + 24 },
      capsuleAnchor = { x = origin[1] + 46, y = origin[2] + 24 },
      statusRect = rect(origin[1] + 24, origin[2] + 40, 24, 8),
      cursorSequence = 1,
      chrome = {
        normal = imageRef("assets/generated/party/fixture-panel.png", 128, 48),
        selected = imageRef("assets/generated/party/fixture-panel.png", 128, 48),
        fainted = imageRef("assets/generated/party/fixture-panel.png", 128, 48),
        selectedFainted = imageRef("assets/generated/party/fixture-panel.png", 128, 48),
        switchSelection = imageRef("assets/generated/party/fixture-panel-switch-selection.png", 128, 48),
      },
      text = {
        name = rect(origin[1] + 48, origin[2] + 8, 72, 16),
        level = rect(origin[1] + 0, origin[2] + 32, 48, 16),
        gender = { x = origin[1] + 112, y = origin[2] + 8 },
      },
      hp = {
        bar = rect(origin[1] + 64, origin[2] + 24, 48, 8),
        number = rect(origin[1] + 56, origin[2] + 32, 64, 16),
      },
      compat = rect(origin[1] + 48, origin[2] + 32, 80, 16),
    }
  end
  local digits = {}
  for digit = 0, 9 do
    digits[digit + 1] = imageRef("assets/generated/party/fixture-digit-" .. digit .. ".png", 8, 8)
  end
  local anchors = {}
  for leaf = 0, 4 do
    anchors[leaf + 1] = { x = 91 + leaf * 10, y = 182 }
  end
  local dpadRow = {}
  for entry = 1, 8 do
    dpadRow[entry] =
      { left = 64, top = 25, width = 0, height = 0, up = 7, down = 2, leftNeighbor = 7, rightNeighbor = 1 }
  end
  local function sequences(path, width, height, count)
    local result = {}
    for sequenceIndex = 1, count or 1 do
      local sequencePath = sequenceIndex == 1 and path or path .. "-" .. sequenceIndex .. ".png"
      result[sequenceIndex] = {
        frames = { frameRef(sequencePath, width, height, 8) },
        loopFrom = 1,
        playback = "static",
      }
    end
    return { sequences = result }
  end
  local function textRole()
    return {
      foreground = { r = 248, g = 248, b = 248, a = 255 },
      shadow = { r = 88, g = 88, b = 88, a = 255 },
      background = { r = 0, g = 0, b = 0, a = 255 },
    }
  end
  local function menuLayout(count, lateral)
    local entries = {}
    for index = 1, count do
      entries[index] = {
        textRect = rect(8, 8, 112, 16),
        frameRect = rect(0, 0, 128, 32),
        frameShape = "standard",
        style = "raised",
        touch = { top = 0, bottom = 32, left = 0, right = 128 },
        up = 1,
        down = 1,
      }
      if lateral then
        entries[index].left = 1
        entries[index].right = 1
      end
    end
    return entries
  end
  local menuTopLevel = {}
  for count = 2, 8 do
    menuTopLevel[count] = menuLayout(count, true)
  end
  local menuSubcontext = {}
  for count = 2, 5 do
    menuSubcontext[count] = menuLayout(count, false)
  end
  return {
    schema = PartyCache.SCHEMA,
    panes = {
      main = { width = 256, height = 192 },
      sub = { width = 256, height = 192 },
    },
    panels = panels,
    windows = {
      browse = rect(16, 168, 160, 16),
      context = rect(16, 152, 104, 32),
      action = rect(16, 152, 216, 32),
      prompt = { x = 200, y = 80 },
    },
    visuals = {
      cursor = sequences("assets/generated/party/fixture-cursor-0.png", 32, 32),
      balls = sequences("assets/generated/party/fixture-ball-0.png", 32, 32, 2),
      buttons = sequences("assets/generated/party/fixture-button-0.png", 32, 32, 2),
      held = sequences("assets/generated/party/fixture-held-0.png", 8, 8, 3),
      status = {
        paralysis = imageRef("assets/generated/party/fixture-status-paralysis.png", 24, 8),
        freeze = imageRef("assets/generated/party/fixture-status-freeze.png", 24, 8),
        sleep = imageRef("assets/generated/party/fixture-status-sleep.png", 24, 8),
        poison = imageRef("assets/generated/party/fixture-status-poison.png", 24, 8),
        burn = imageRef("assets/generated/party/fixture-status-burn.png", 24, 8),
        faint = imageRef("assets/generated/party/fixture-status-faint.png", 24, 8),
      },
      feedback = {
        frames = {
          frameRef("assets/generated/party/fixture-feedback-0.png", 16, 16, 3),
          frameRef("assets/generated/party/fixture-feedback-1.png", 16, 16, 2),
        },
        loopFrom = 1,
        playback = "once",
        hideAtFrame = 3,
      },
      backdropMain = imageRef("assets/generated/party/fixture-backdrop-main.png", 256, 256),
      backdropSub = imageRef("assets/generated/party/fixture-backdrop-sub.png", 256, 256),
      detailSub = imageRef("assets/generated/party/fixture-detail-sub.png", 256, 256),
      decoration = imageRef("assets/generated/party/fixture-decoration.png", 128, 16),
      auxPanel = imageRef("assets/generated/party/fixture-panel-aux.png", 128, 48),
      hpBars = {
        green = imageRef("assets/generated/party/fixture-hp-green.png", 48, 4),
        yellow = imageRef("assets/generated/party/fixture-hp-yellow.png", 48, 4),
        red = imageRef("assets/generated/party/fixture-hp-red.png", 48, 4),
      },
    },
    controls = {
      cancel = {
        anchor = { x = 232, y = 176 },
        label = "Cancel",
        textRect = rect(200, 168, 48, 16),
        align = "center",
      },
    },
    detail = {
      iconAnchor = { x = 30, y = 200 },
      statusAnchor = { x = 50, y = 220 },
      nicknameTextOrigin = { x = 56, y = 192 },
      heldItemTextOrigin = { x = 138, y = 212 },
    },
    iconAnimations = {
      sequences = {
        { { iconFrame = 1, durationTicks = 1, translateX = 0, translateY = 0 }, loopFrom = 1, playback = "static" },
        { { iconFrame = 1, durationTicks = 8, translateX = 0, translateY = 0 }, loopFrom = 1, playback = "static" },
        { { iconFrame = 1, durationTicks = 12, translateX = 0, translateY = 0 }, loopFrom = 1, playback = "static" },
        { { iconFrame = 1, durationTicks = 24, translateX = 0, translateY = 0 }, loopFrom = 1, playback = "static" },
        { { iconFrame = 1, durationTicks = 40, translateX = 0, translateY = 0 }, loopFrom = 1, playback = "static" },
        { { iconFrame = 1, durationTicks = 32, translateX = 0, translateY = 0 }, loopFrom = 1, playback = "static" },
      },
    },
    contextMenu = {
      topLevel = menuTopLevel,
      subcontext = menuSubcontext,
      textRoles = {
        command = { raised = textRole(), depressed = textRole() },
        field = { raised = textRole(), depressed = textRole() },
        cancel = { raised = textRole(), depressed = textRole() },
      },
      frames = {
        standard = {
          raised = imageRef("assets/generated/party/fixture-context-standard-raised.png", 128, 32),
          selected = imageRef("assets/generated/party/fixture-context-standard-selected.png", 128, 32),
          pressed = imageRef("assets/generated/party/fixture-context-standard-pressed.png", 128, 32),
        },
        cancel = {
          raised = imageRef("assets/generated/party/fixture-context-cancel-raised.png", 56, 40),
          selected = imageRef("assets/generated/party/fixture-context-cancel-selected.png", 56, 40),
          pressed = imageRef("assets/generated/party/fixture-context-cancel-pressed.png", 56, 40),
        },
      },
    },
    navigation = { dpad = { default = dpadRow, alternate = dpadRow, union = dpadRow, contest = dpadRow } },
    hitboxes = {
      touch = {
        default = { touch(0, 48, 0, 128) },
        alternate = { touch(0, 48, 0, 128) },
        context = { touch(0, 48, 0, 128) },
      },
    },
    text = {
      labels = { cancel = "Cancel", male = "M", female = "F" },
      templates = {
        switchPrompt = { segments = { { kind = "text", value = "Switch?" } } },
        chooseMon = { segments = { { kind = "text", value = "Choose a POKEMON." } } },
        moveTarget = { segments = { { kind = "text", value = "Move to where?" } } },
        giveTarget = { segments = { { kind = "text", value = "Give to which POKEMON?" } } },
        useTarget = { segments = { { kind = "text", value = "Use on which POKEMON?" } } },
        teachTarget = { segments = { { kind = "text", value = "Teach which POKEMON?" } } },
        itemAction = { segments = { { kind = "text", value = "What to do with the item?" } } },
        takeNoItem = { segments = { { kind = "text", value = "Nothing held." } } },
        bagFull = { segments = { { kind = "text", value = "The Bag is full." } } },
        switchHeldPrompt = { segments = { { kind = "text", value = "Switch the held items?" } } },
        switchHeldResult = { segments = { { kind = "text", value = "Switched the held items." } } },
        giveHeldItem = { segments = { { kind = "text", value = "Gave the item to hold." } } },
      },
      roles = {
        ordinary = {
          foreground = { r = 248, g = 248, b = 248, a = 255 },
          shadow = { r = 88, g = 88, b = 88, a = 255 },
          background = { r = 0, g = 0, b = 0, a = 255 },
        },
        male = {
          foreground = { r = 248, g = 248, b = 248, a = 255 },
          shadow = { r = 88, g = 88, b = 88, a = 255 },
          background = { r = 0, g = 0, b = 0, a = 255 },
        },
        female = {
          foreground = { r = 248, g = 248, b = 248, a = 255 },
          shadow = { r = 88, g = 88, b = 88, a = 255 },
          background = { r = 0, g = 0, b = 0, a = 255 },
        },
      },
      messageRole = textRole(),
    },
    numberGlyphs = {
      advance = 8,
      height = 8,
      digits = digits,
      slash = imageRef("assets/generated/party/fixture-slash.png", 8, 8),
      level = imageRef("assets/generated/party/fixture-level.png", 16, 8),
      placement = {
        level = { x = 5, y = 2 },
        current = { x = 0, y = 2 },
        slash = { x = 28, y = 2 },
        max = { x = 36, y = 2 },
      },
    },
    shinyLeaves = {
      anchors = anchors,
      crownAnchor = { x = 111, y = 182 },
      leafSequence = 6,
      crownSequence = 7,
      paletteBank = 1,
      leaves = {
        frames = { frameRef("assets/generated/party/fixture-leaf-0.png", 16, 16, 4) },
        loopFrom = 1,
        playback = "loop",
      },
      crown = {
        frames = { frameRef("assets/generated/party/fixture-crown-0.png", 16, 16, 4) },
        loopFrom = 1,
        playback = "loop",
      },
    },
  }
end

---@return CacheFs
function FieldStatePresentationFixture.cache()
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  local pcManifest = PcPresentationFixture.manifest()
  cache:writeLua(PcCache.manifestPath(), pcManifest)
  for _, path in ipairs(PcCache.referencedPaths(pcManifest)) do
    cache:write(path, solidPng(256, 192))
  end
  FieldUiFixture.writeStartMenuSelectorPngs(cache)
  cache:write(FieldUiFixture.TRAINER_CARD_PATH, FieldUiFixture.cardBytes())
  cache:writeLua(MonCache.iconManifestPath(), {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = MonCache.iconPagePath(0), width = 256, height = 128 },
    },
    pageIds = { 0 },
    entries = {
      ["TEST/f0"] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = { { x = 0, y = 0, width = 32, height = 32, duration = 1 } },
        pageId = 0,
      },
    },
    representative = { "TEST/f0" },
  })
  local pixels = {}
  for _ = 1, 64 * 64 do
    pixels[#pixels + 1] = string.char(255, 0, 0, 255)
  end
  cache:write(MonCache.iconPagePath(0), PngWriter.encode(64, 64, table.concat(pixels)))
  -- Minimal item icon manifest/atlas and bag manifest/images so the eager
  -- bag presentation resources resolve during FieldState construction.
  cache:writeLua(ItemCache.iconManifestPath(), {
    schema = ItemCache.ICON_MANIFEST_SCHEMA,
    atlas = ItemCache.iconImagePath(),
    entries = {
      POTION = { x = 0, y = 0, width = 32, height = 32 },
    },
    representative = { "POTION" },
  })
  cache:write(ItemCache.iconImagePath(), solidPng(64, 64))
  local bagManifest = BagPresentationFixture.manifest()
  cache:writeLua(BagCache.manifestPath(), bagManifest)
  -- Every image the validated manifest references, so the eager bag
  -- presentation resources resolve during FieldState construction.
  for _, path in ipairs(BagCache.referencedPaths(bagManifest)) do
    cache:write(path, solidPng(32, 32))
  end
  local martManifest = MartFixture.manifest()
  cache:writeLua(MartCache.manifestPath(), martManifest)
  for _, path in ipairs(MartCache.referencedPaths(martManifest)) do
    cache:write(path, solidPng(32, 32))
  end
  -- Minimal party manifest and every image it references so the eager
  -- party presentation resources resolve during FieldState construction.
  local partyData = partyManifest()
  cache:writeLua(PartyCache.manifestPath(), partyData)
  for _, path in ipairs(PartyCache.referencedPaths(partyData)) do
    cache:write(path, solidPng(32, 32))
  end
  cache:write(
    FieldActorCache.indexPath(),
    LuaWriter.encode({ schema = FieldActorCache.INDEX_SCHEMA, spriteIds = { 0 } })
  )
  cache:writeLua(FieldActorCache.visualPath(0), FieldActorFixture.visual(0))
  cache:write(FieldActorCache.atlasPath(0), FieldDialogueFixture.atlasBytes())
  return cache
end

-- The terrain-effect bundle the real terrain renderer acquires during the
-- boot: one synthetic triangle mesh per effect kind, written into the same
-- presentation cache the boot reads through.
---@param cache CacheFs
---@return table<string, table<string, unknown>>
function FieldStatePresentationFixture.terrainEffects(cache)
  cache:write(
    "test/terrain-grass.mesh",
    MeshWriter.encode({
      vertices = {
        {
          x = 0,
          y = 0,
          z = 0,
          u = 0,
          v = 0,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 255,
          g = 255,
          b = 255,
          a = 255,
          colorSource = 0,
        },
        {
          x = 1,
          y = 0,
          z = 0,
          u = 1,
          v = 0,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 255,
          g = 255,
          b = 255,
          a = 255,
          colorSource = 0,
        },
        {
          x = 0,
          y = 0,
          z = 1,
          u = 0,
          v = 1,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 255,
          g = 255,
          b = 255,
          a = 255,
          colorSource = 0,
        },
      },
      indices = { 0, 1, 2 },
    })
  )
  local function effect()
    return {
      model = {
        dynamic = {
          nodes = {
            { name = "root", translation = { 0, 0, 0 }, rotation = { 0, 0, 0 }, scale = { 1, 1, 1 } },
          },
          batches = {
            {
              id = "grass",
              nodeIndex = 0,
              materialIndex = 0,
              geometry = "test/terrain-grass.mesh",
              alphaClass = "cutout",
              cullMode = "back",
              polygonAlpha = 31,
              polygonMode = "modulation",
              polygonId = 0,
              translucentDepthWrite = false,
              depthEqual = false,
              lightMask = 15,
              fogEnabled = false,
            },
          },
        },
        materials = { { id = 0, name = "grass", wrap = { x = "clamp", y = "clamp" } } },
        animations = {},
      },
      placementOffset = { x = 0, y = 0, z = 0 },
    }
  end
  return {
    tall_grass = effect(),
    very_tall_grass = effect(),
    trainer_reveal = effect(),
  }
end

-- Explicit headless semantic host for presentation fixtures: mirrors the
-- production derived-asset shapes, records every demand in the returned log,
-- and reports ready without compiling, decoding, or touching the GPU.
-- Fixtures boot from prepared caches where demanded artifacts are already
-- compiled, so ready mirrors successful reuse; demand stays visible in the
-- log instead of silently succeeding, so blanket enrollment would fail loudly.
---@return { derivedAssets: table<string, function>, demands: table<integer, table<string, unknown>> }
function FieldStatePresentationFixture.iconHost()
  local host = { demands = {} }
  local function note(kind, detail)
    host.demands[#host.demands + 1] = { kind = kind, detail = detail }
  end
  host.derivedAssets = {
    requestMilestone = function(name, _)
      note("milestone", name)
      return true
    end,
    milestoneStatus = function(name)
      note("milestone-status", name)
      return { state = "ready", ready = 1, total = 1, failure = nil }
    end,
    requestField = function(mapId, _)
      note("field", mapId)
      return true
    end,
    requestLogicalField = function(mapId, _)
      note("logical-field", mapId)
      return true
    end,
    ensureLogicalField = function(mapId)
      note("ensure-logical-field", mapId)
      return true
    end,
    ensureField = function(mapId)
      note("ensure-field", mapId)
      return true
    end,
    requestCell = function(descriptor, _)
      note("cell", descriptor)
      return true
    end,
    ensureCell = function(descriptor)
      note("ensure-cell", descriptor)
      return true
    end,
    requestMonPortraitPage = function(pageId, _)
      note("portrait", pageId)
      return true
    end,
    requestIconPage = function(pageId, urgency)
      assert(type(pageId) == "number", "icon demand carries its page")
      note("icon-page", { pageId = pageId, urgency = urgency })
      return true
    end,
    status = function()
      return { bootstrap = "ready" }
    end,
  }
  return host
end

return FieldStatePresentationFixture
