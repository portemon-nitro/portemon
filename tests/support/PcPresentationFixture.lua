-- Synthetic source-independent PC manifest for consumer component tests.

local PcPresentationFixture = {}

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
  for stationeryType = 0, 11 do
    stationery[stationeryType] = visual("stationery-" .. stationeryType)
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
  return {
    schema = "g4-pc-v1",
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
      geometry = { iconSlots = 3 },
      text = { sourceBanks = {} },
    },
    photoAlbum = { ui = {}, geometry = { screen = { width = 256, height = 192 } } },
    text = {},
    sequences = {},
  }
end

return PcPresentationFixture
