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

local function writeVisual(role, width, height)
  return {
    image = "assets/generated/pc/test-" .. role .. ".png",
    width = width,
    height = height,
    anchorX = 0,
    anchorY = 0,
  }
end

-- Minimal source-shaped write chrome per stationery type: the native
-- composite, the top backdrop, five cursor-ordered highlight frame sets,
-- and five rect-local binary touch masks.
local function writeRecord(stationeryType)
  local highlights, hitMasks = {}, {}
  local controls = {
    { x = 24, y = 24, width = 208, height = 32 },
    { x = 24, y = 64, width = 208, height = 32 },
    { x = 24, y = 104, width = 208, height = 32 },
    { x = 24, y = 148, width = 64, height = 24 },
    { x = 160, y = 148, width = 64, height = 24 },
  }
  for _, control in ipairs(controls) do
    local frames = {}
    for _ = 1, 14 do
      frames[#frames + 1] = writeVisual("stationery-" .. stationeryType .. "-highlight", control.width, control.height)
    end
    highlights[#highlights + 1] =
      { x = control.x, y = control.y, width = control.width, height = control.height, frames = frames }
    local rows = {}
    for _ = 1, control.height do
      rows[#rows + 1] = string.rep("1", control.width)
    end
    hitMasks[#hitMasks + 1] =
      { x = control.x, y = control.y, width = control.width, height = control.height, rows = rows }
  end
  return {
    background = writeVisual("stationery-" .. stationeryType .. "-write", 256, 192),
    backdrop = writeVisual("stationery-" .. stationeryType .. "-backdrop", 256, 192),
    highlights = highlights,
    hitMasks = hitMasks,
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
      write = writeRecord(stationeryType),
    }
  end
  local windowFrames = { standard = {}, accent = {} }
  for _, style in ipairs({ "standard", "accent" }) do
    for bank = 0, 1 do
      windowFrames[style]["paletteBank" .. bank] = sourceVisual("frame-" .. style .. "-" .. bank, 96, 8)
    end
  end
  local wallpaperSwatches = { colors = {}, locked = { r = 0, g = 0, b = 0 } }
  for logicalId = 0, 23 do
    wallpaperSwatches.colors[logicalId] = { r = 10 * logicalId, g = 20, b = 30 }
  end
  local markings = {}
  for bit = 0, 5 do
    markings[bit] = {
      clear = sourceVisual("mark-clear-" .. bit, 8, 8),
      set = sourceVisual("mark-set-" .. bit, 8, 8),
    }
  end
  local textBanks = {}
  for _, bankId in ipairs({ 0, 279, 280, 281, 282, 233 }) do
    local tokens = { { kind = "text", value = "fixture" } }
    if bankId == 233 then
      textBanks[bankId] = { [0] = tokens, [1] = tokens, [2] = tokens, [3] = tokens }
    else
      textBanks[bankId] = { [0] = tokens, [1] = tokens }
    end
  end
  local photoSprites = {}
  for index = 1, 5 do
    photoSprites[index] = { animationSpeed = 0x1000, initiallyAnimating = false, initiallyVisible = false }
  end
  local photoAnimations = {}
  for animationId = 0, 9 do
    photoAnimations[animationId] = {
      frames = {
        {
          image = "assets/generated/pc/photo-animation.png",
          width = 8,
          height = 8,
          anchorX = 0,
          anchorY = 0,
          duration = 1,
        },
      },
    }
  end
  -- The drawn Mailbox sprite roles every consumer draws: previous arrow
  -- 0, next arrow 1, static close 2, CLOSE cursor 4, row cursor 5, plus
  -- the compiled-but-undrawn role 3 the producer retains.
  local mailboxAnimations = {}
  for _, animationId in ipairs({ 0, 1, 2, 3, 4, 5 }) do
    mailboxAnimations[animationId] = {
      frames = {
        {
          image = "assets/generated/pc/test-mailbox-animation-" .. animationId .. ".png",
          width = 16,
          height = 16,
          anchorX = 0,
          anchorY = 0,
          duration = 1,
        },
      },
    }
  end
  return {
    schema = PcCache.SCHEMA,
    storage = {
      backgrounds = { default = visual("storage-background") },
      wallpapers = wallpapers,
      wallpaperSwatches = wallpaperSwatches,
      ui = {
        boxPane = sourceVisual("box-pane", 256, 192),
        infoPane = sourceVisual("info-pane", 256, 192),
        partyTray = sourceVisual("party-tray", 88, 144),
        markingPanel = sourceVisual("marking-panel", 88, 144),
        wallpaperBar = sourceVisual("wallpaper-bar", 256, 56),
        arrows = {
          left = sourceVisual("arrow-left", 16, 16),
          right = sourceVisual("arrow-right", 16, 16),
        },
        cursors = {
          browse = sourceVisual("cursor-browse", 20, 20),
          menu = sourceVisual("cursor-menu", 20, 20),
          carry = sourceVisual("cursor-carry", 20, 20),
        },
        windowFrames = windowFrames,
        markings = markings,
      },
      boxNames = boxNames,
      expansionNameFormat = { prefix = "BOX ", suffix = "", firstNumber = 1 },
      geometry = {
        wallpaperMap = { width = 168, height = 160, columns = 21, rows = 20, tileIdWrap = 64 },
      },
    },
    mailbox = {
      background = { main = visual("mailbox-background") },
      ui = { animations = mailboxAnimations },
      geometry = { visibleLetters = 10 },
      pageSize = 10,
    },
    mail = {
      stationery = stationery,
      geometry = { iconSlots = 3, iconLocations = { { x = 0, y = 0 }, { x = 8, y = 0 }, { x = 16, y = 0 } } },
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
      slots = {
        [0] = { role = "terminal.on", playMode = "forward" },
        [1] = { role = "terminal.off", playMode = "forward" },
      },
    },
  }
end

return PcPresentationFixture
