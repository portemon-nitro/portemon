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
  local function sourceVisualAt(role, width, height, anchorX, anchorY)
    return {
      image = "assets/generated/pc/test-" .. role .. ".png",
      width = width,
      height = height,
      anchorX = anchorX,
      anchorY = anchorY,
    }
  end
  local function sourceVisual(role, width, height)
    return sourceVisualAt(role, width, height, 0, 0)
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
  local windowFrames =
    { standard = {}, accent = {}, fill = { r = 255, g = 247, b = 222 }, accentFill = { r = 255, g = 247, b = 222 } }
  for _, style in ipairs({ "standard", "accent" }) do
    for bank = 0, 1 do
      windowFrames[style]["paletteBank" .. bank] = sourceVisual("frame-" .. style .. "-" .. bank, 96, 8)
    end
  end
  local wallpaperSwatches = { colors = {}, locked = { r = 0, g = 0, b = 0 } }
  for logicalId = 0, 23 do
    wallpaperSwatches.colors[logicalId] = { r = 10 * logicalId, g = 20, b = 30 }
  end
  local wallpaperSwatchArt = { variants = {}, locked = sourceVisual("wallpaper-swatch-locked", 24, 24) }
  for logicalId = 0, 23 do
    wallpaperSwatchArt.variants[logicalId] = sourceVisual("wallpaper-swatch-" .. logicalId, 24, 24)
  end
  local boxThumbnail = {
    variants = {},
    locked = sourceVisual("box-thumbnail-locked", 32, 32),
    dots = {},
    dotOrigin = { x = 10, y = 11 },
    dotStep = 2,
  }
  for logicalId = 0, 23 do
    boxThumbnail.variants[logicalId] = sourceVisual("box-thumbnail-" .. logicalId, 32, 32)
  end
  for color = 0, 9 do
    boxThumbnail.dots[color] = { r = 10 + color, g = 20, b = 30 }
  end
  local markings = {}
  local panelMarkings = {}
  for bit = 0, 5 do
    markings[bit] = {
      clear = sourceVisual("mark-clear-" .. bit, 8, 8),
      set = sourceVisual("mark-set-" .. bit, 8, 8),
    }
    panelMarkings[bit] = {
      clear = sourceVisual("panel-mark-clear-" .. bit, 8, 8),
      set = sourceVisual("panel-mark-set-" .. bit, 8, 8),
    }
  end
  local plates = {}
  for _, role in ipairs({ "tab", "summary" }) do
    plates[role] = {}
    for _, part in ipairs({ "left", "middle", "right" }) do
      plates[role][part] = sourceVisual("plate-" .. role .. "-" .. part, 8, 24)
    end
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
      wallpaperSwatchArt = wallpaperSwatchArt,
      boxThumbnail = boxThumbnail,
      ui = {
        boxPane = sourceVisual("box-pane", 256, 192),
        infoPane = sourceVisual("info-pane", 256, 192),
        partyTray = sourceVisual("party-tray", 88, 144),
        partyTrayMove = sourceVisual("party-tray-move", 88, 144),
        markingPanel = sourceVisual("marking-panel", 88, 144),
        wallpaperBar = sourceVisual("wallpaper-bar", 256, 56),
        movesPanel = sourceVisual("moves-panel", 96, 80),
        itemPanel = sourceVisual("item-panel", 256, 72),
        boxTray = sourceVisual("box-tray", 256, 48),
        depositBoxTray = sourceVisual("deposit-box-tray", 256, 56),
        itemPanelFill = { r = 13, g = 26, b = 39 },
        arrows = {
          left = sourceVisual("arrow-left", 16, 16),
          right = sourceVisual("arrow-right", 16, 16),
        },
        -- The browsing and menu hands are source two-frame pulses; the
        -- carrying hand is a single frame. Every pose names its rendered
        -- frames and their tick durations.
        cursors = {
          browse = {
            loop = true,
            frames = {
              {
                image = "assets/generated/pc/test-cursor-browse-0.png",
                width = 20,
                height = 20,
                anchorX = 0,
                anchorY = 0,
                duration = 20,
              },
              {
                image = "assets/generated/pc/test-cursor-browse-1.png",
                width = 20,
                height = 20,
                anchorX = 1,
                anchorY = 0,
                duration = 20,
              },
            },
          },
          menu = {
            loop = true,
            frames = {
              {
                image = "assets/generated/pc/test-cursor-menu-0.png",
                width = 20,
                height = 20,
                anchorX = 0,
                anchorY = 0,
                duration = 20,
              },
              {
                image = "assets/generated/pc/test-cursor-menu-1.png",
                width = 20,
                height = 20,
                anchorX = 1,
                anchorY = 0,
                duration = 20,
              },
            },
          },
          carry = {
            loop = true,
            frames = {
              {
                image = "assets/generated/pc/test-cursor-carry.png",
                width = 20,
                height = 20,
                anchorX = 0,
                anchorY = 0,
                duration = 1,
              },
            },
          },
        },
        tray = {
          prev = sourceVisualAt("tray-prev", 24, 24, -15, -12),
          next = sourceVisualAt("tray-next", 24, 24, -9, -12),
          marker = sourceVisualAt("tray-marker", 24, 24, -12, -12),
          cursor = sourceVisualAt("tray-cursor", 160, 16, -80, -8),
          wallpaperCursor = sourceVisualAt("tray-wallpaper-cursor", 88, 16, -44, -8),
          label = sourceVisualAt("tray-label", 16, 16, -8, -4),
        },
        -- Raw source bitmaps and the shared baked confirmation buttons.
        infoGlyphs = {
          lv = sourceVisual("info-lv", 16, 8),
          no = sourceVisual("info-no", 16, 8),
        },
        yesNo = {
          yesNormal = sourceVisual("yes-no-yes-normal", 48, 32),
          yesSelected = sourceVisual("yes-no-yes-selected", 48, 32),
          noNormal = sourceVisual("yes-no-no-normal", 48, 32),
          noSelected = sourceVisual("yes-no-no-selected", 48, 32),
        },
        windowFrames = windowFrames,
        plates = plates,
        markings = markings,
        panelMarkings = panelMarkings,
      },
      boxNames = boxNames,
      expansionNameFormat = { prefix = "BOX ", suffix = "", firstNumber = 1 },
      geometry = {
        wallpaperMap = { width = 168, height = 160, columns = 21, rows = 20, tileIdWrap = 64 },
      },
    },
    mailbox = {
      background = { main = visual("mailbox-background") },
      ui = {
        animations = mailboxAnimations,
        backgrounds = { subBg7 = visual("mailbox-sub-background") },
        listMenu = {
          tiles = writeVisual("list-menu-tiles", 8 * 22, 8),
          palette = (function()
            local colors = {}
            for index = 1, 16 do
              colors[index] = { r = index * 4, g = index * 4, b = index * 4 }
            end
            return colors
          end)(),
        },
      },
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
