-- Synthetic source-independent PC manifest for consumer component tests.

local PcPresentationFixture = {}
local PcCache = require("libs.assets.src.PcCache")

local function visual(role)
  return {
    image = "assets/generated/pc/test-" .. role .. ".png",
    width = 256,
    height = 192,
    anchorX = 0,
    anchorY = 0,
  }
end

function PcPresentationFixture.manifest()
  local function sourceVisual(role, width, height)
    return {
      image = "assets/generated/pc/test-" .. role .. ".png",
      width = width,
      height = height,
      anchorX = 0,
      anchorY = 0,
    }
  end
  local wallpapers = {}
  for wallpaperId = 0, 15 do
    wallpapers[wallpaperId] = visual("wallpaper-" .. wallpaperId)
  end
  for wallpaperId = 32, 39 do
    wallpapers[wallpaperId] = visual("wallpaper-" .. wallpaperId)
  end
  local boxNames = {}
  for box = 1, 18 do
    boxNames[box] = "BOX " .. box
  end
  local stationery = {}
  local stationeryItems = {
    "GRASS_MAIL",
    "FLAME_MAIL",
    "BUBBLE_MAIL",
    "BLOOM_MAIL",
    "TUNNEL_MAIL",
    "STEEL_MAIL",
    "HEART_MAIL",
    "SNOW_MAIL",
    "SPACE_MAIL",
    "AIR_MAIL",
    "MOSAIC_MAIL",
    "BRICK_MAIL",
  }
  for stationeryType = 0, 11 do
    stationery[stationeryType] = {
      background = visual("stationery-" .. stationeryType),
      itemKey = stationeryItems[stationeryType + 1],
    }
  end
  local windowFrames = { standard = {}, accent = {} }
  for _, style in ipairs({ "standard", "accent" }) do
    for bank = 0, 1 do
      windowFrames[style]["paletteBank" .. bank] = sourceVisual("frame-" .. style .. "-" .. bank, 96, 8)
    end
  end
  local markings = {}
  for bit = 0, 5 do
    markings[bit] = {
      clear = sourceVisual("mark-clear-" .. bit, 8, 8),
      set = sourceVisual("mark-set-" .. bit, 8, 8),
    }
  end
  local textBanks = {}
  local sourceBanks = { 0, 279, 280, 281, 282 }
  local mailTemplates = {}
  for mailBankIndex, bankId in ipairs(sourceBanks) do
    local tokens = { { kind = "text", value = "fixture" } }
    textBanks[bankId] = { [0] = tokens, [1] = tokens }
    mailTemplates["mail-template:" .. (mailBankIndex - 1) .. ":0"] = tokens
  end
  local wordDictionary = {}
  for wordId = 0, 1494 do
    wordDictionary[tostring(wordId)] = { { kind = "text", value = "fixture" } }
  end
  local photoSprites = {}
  for index = 1, 5 do
    photoSprites[index] = { animationSpeed = 0x1000, initiallyAnimating = false, initiallyVisible = false }
  end
  local photoAnimations = {}
  for animationId = 0, 9 do
    photoAnimations[animationId] = {
      frames = { { image = "assets/generated/pc/photo-animation.png", width = 8, height = 8, anchorX = 0, anchorY = 0, duration = 1 } },
    }
  end
  return {
    schema = PcCache.SCHEMA,
    storage = {
      backgrounds = { default = visual("storage-background") },
      wallpapers = wallpapers,
      ui = {
        boxPane = sourceVisual("box-pane", 256, 192),
        partyPane = sourceVisual("party-pane", 256, 192),
        windowFrames = windowFrames,
        markings = markings,
      },
      boxNames = boxNames,
      expansionNameFormat = { prefix = "BOX ", suffix = "", firstNumber = 19 },
      geometry = {
        wallpaperMap = { width = 168, height = 160, columns = 21, rows = 20, tileIdWrap = 64 },
      },
    },
    mailbox = {
      background = { main = visual("mailbox-background") },
      ui = {},
      geometry = { visibleLetters = 10 },
      pageSize = 10,
    },
    mail = {
      stationery = stationery,
      geometry = { iconSlots = 3, iconLocations = { { x = 0, y = 0 }, { x = 8, y = 0 }, { x = 16, y = 0 } } },
      text = { sourceBanks = sourceBanks, templates = mailTemplates },
      wordDictionary = wordDictionary,
    },
    photoAlbum = {
      ui = {
        sprites = photoSprites,
        animations = photoAnimations,
        backgrounds = { [0] = visual("photo-background-0"), [1] = visual("photo-background-1") },
      },
    },
    text = { banks = textBanks },
    sequences = {},
    terminal = {
      animationTag = 90,
      candidateBuildModelMembers = { 33, 138 },
      slots = { [0] = { role = "terminal.on", playMode = "forward" }, [1] = { role = "terminal.off", playMode = "forward" } },
    },
  }
end

return PcPresentationFixture
