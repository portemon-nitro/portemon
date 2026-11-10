-- Contract scenarios for the generated field-bag presentation class. Fixtures
-- model the public manifest only; source archive/member identities belong to
-- the producer dependency record and are intentionally absent.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local Errors = require("libs.errors.src.Errors")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local BagCache = require("libs.assets.src.BagCache")
local T = {}
local POCKETS = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }
local function imageRef(path)
  return { image = path, width = 256, height = 192 }
end

local function visualRef(path)
  return imageRef(path)
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function constantChannel()
  return { source = "constant", value = 0 }
end

local function trsClip(id, semanticName)
  return {
    id = id,
    name = id,
    category = "joint",
    kind = "trs",
    frameCount = 4,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = { semanticName },
    compiled = {
      anmFlags = 0,
      rotData = {},
      pivotData = { { 0, 0, 0, 0, 0 } },
      targets = {
        {
          nodeIndex = 0,
          channels = {
            trans = { x = constantChannel(), y = constantChannel(), z = constantChannel() },
            rot = constantChannel(),
            scale = { x = constantChannel(), y = constantChannel(), z = constantChannel() },
          },
        },
      },
    },
  }
end

local function dynamicMaterial()
  return {
    id = 0,
    name = "widget",
    baseColor = { r = 255, g = 255, b = 255, a = 255 },
    colors = {
      diffuse = { r = 255, g = 255, b = 255 },
      ambient = { r = 255, g = 255, b = 255 },
      specular = { r = 255, g = 255, b = 255 },
      emission = { r = 0, g = 0, b = 0 },
    },
    alphaMode = "opaque",
    polygonMode = "modulation",
    doubleSided = false,
    polygonAlpha = 31,
    texMtxMode = 0,
    texWidth = 64,
    texHeight = 64,
    wrap = { x = "clamp", y = "clamp" },
    flip = { x = false, y = false },
    diffuse = { r = 255, g = 255, b = 255, a = 255 },
  }
end

local function heroDescriptor(gender)
  local clips = {}
  for _, pocket in ipairs(POCKETS) do
    clips[#clips + 1] = trsClip(gender .. ".pose." .. pocket, "pocket." .. pocket .. ".pose")
    clips[#clips + 1] = trsClip(gender .. ".pattern." .. pocket, "pocket." .. pocket .. ".pattern")
  end
  clips[#clips + 1] = trsClip(gender .. ".material", "bag.material")
  return {
    schema = ModelAsset.SCHEMA,
    kind = "nitro-dynamic",
    dynamic = { nodes = {}, transformProgram = {}, batches = {} },
    materials = { dynamicMaterial() },
    animations = clips,
  }
end

local function tabs()
  local out = {}
  for i = 0, 7 do
    out[#out + 1] = rect(i * 32, 0, 32, 32)
  end
  return out
end

local function slots()
  local fullRects = {
    rect(0, 32, 128, 42),
    rect(128, 32, 128, 42),
    rect(0, 74, 128, 44),
    rect(128, 74, 128, 44),
    rect(0, 118, 128, 36),
    rect(128, 118, 128, 36),
  }
  local textRects = {
    rect(32, 40, 88, 32),
    rect(160, 40, 88, 32),
    rect(32, 80, 88, 32),
    rect(160, 80, 88, 32),
    rect(32, 120, 88, 32),
    rect(160, 120, 88, 32),
  }
  local iconCenters = {
    { x = 48, y = 56 },
    { x = 176, y = 56 },
    { x = 48, y = 96 },
    { x = 176, y = 96 },
    { x = 48, y = 136 },
    { x = 176, y = 136 },
  }
  local out = {}
  for index = 1, 6 do
    out[index] = {
      rect = fullRects[index],
      textRect = textRects[index],
      iconCenter = iconCenters[index],
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    }
  end
  return out
end

local function markerImage(path)
  return { image = path, width = 40, height = 16 }
end

local function countKeyedBackgrounds(state)
  local pockets = {}
  for _, pocket in ipairs(POCKETS) do
    local variants = {}
    for count = 0, 6 do
      variants[count] =
        imageRef("assets/generated/bag/background-" .. state .. "-" .. pocket .. "-count-" .. count .. ".png")
    end
    pockets[pocket] = variants
  end
  return pockets
end

local function backgrounds()
  local out = {
    action = countKeyedBackgrounds("action"),
    quantity = countKeyedBackgrounds("quantity"),
  }
  local move = {}
  for _, pocket in ipairs(POCKETS) do
    local counts = {}
    for count = 0, 6 do
      local origins = {
        none = imageRef("assets/generated/bag/background-move-" .. pocket .. "-count-" .. count .. "-origin-none.png"),
      }
      for _, origin in ipairs({ "0", "1", "2", "3", "4", "5" }) do
        origins[origin] = imageRef(
          "assets/generated/bag/background-move-" .. pocket .. "-count-" .. count .. "-origin-" .. origin .. ".png"
        )
      end
      counts[count] = origins
    end
    move[pocket] = counts
  end
  out.move = move
  local browse = {}
  for _, pocket in ipairs(POCKETS) do
    local variants = {}
    for count = 0, 6 do
      variants[#variants + 1] =
        imageRef("assets/generated/bag/background-browse-" .. pocket .. "-count-" .. count .. ".png")
    end
    browse[pocket] = variants
  end
  out.browse = browse
  return out
end

-- Layered v20 backgrounds: browse resolves through one pocket base (blank
-- slots) plus the three opaque row patches placed at the six cell rects
-- (one row art serves both its cells; counts fill cells left-to-right,
-- top-to-bottom), while action/quantity resolve through one pocket overlay
-- each and move resolves through one count-variant base plus the two
-- origin-marker patches placed at the six origin rects.
local function browseCellRects()
  return {
    rect(2, 37, 124, 38),
    rect(130, 37, 124, 38),
    rect(2, 77, 124, 38),
    rect(130, 77, 124, 38),
    rect(2, 117, 124, 38),
    rect(130, 117, 124, 38),
  }
end

local function layeredBackgrounds()
  local out = {}
  local browse = {}
  for _, pocket in ipairs(POCKETS) do
    local rows = {}
    for row = 0, 2 do
      rows[#rows + 1] = {
        image = "assets/generated/bag/background-browse-row-" .. pocket .. "-" .. row .. ".png",
        width = 124,
        height = 38,
      }
    end
    browse[pocket] = {
      base = imageRef("assets/generated/bag/background-browse-base-" .. pocket .. ".png"),
      rows = rows,
    }
  end
  out.browse = browse
  out.browseCells = browseCellRects()
  local overlays = {}
  for _, state in ipairs({ "action", "quantity" }) do
    local pockets = {}
    for _, pocket in ipairs(POCKETS) do
      pockets[pocket] =
        imageRef("assets/generated/bag/background-" .. state .. "-overlay-" .. pocket .. ".png")
    end
    overlays[state] = pockets
  end
  do
    local pockets = {}
    for _, pocket in ipairs(POCKETS) do
      pockets[pocket] = imageRef("assets/generated/bag/background-sale-quantity-" .. pocket .. ".png")
    end
    overlays.sale = pockets
  end
  out.actionOverlay = overlays.action
  out.quantityOverlay = overlays.quantity
  out.saleOverlay = overlays.sale
  local move = {}
  for _, pocket in ipairs(POCKETS) do
    local counts = {}
    for count = 0, 4 do
      counts[count] = imageRef("assets/generated/bag/background-move-" .. pocket .. "-count-" .. count .. ".png")
    end
    counts[5] = counts[0]
    counts[6] = counts[0]
    move[pocket] = counts
  end
  out.move = move
  local function markerImage(pocket, band)
    return { image = "assets/generated/bag/move-marker-" .. pocket .. "-" .. band .. ".png", width = 128, height = 48 }
  end
  local images = {}
  for _, pocket in ipairs(POCKETS) do
    images[pocket] = { low = markerImage(pocket, "low"), high = markerImage(pocket, "high") }
  end
  out.moveMarker = {
    images = images,
    rects = {
      rect(0, 32, 128, 48),
      rect(128, 32, 128, 48),
      rect(0, 72, 128, 48),
      rect(128, 72, 128, 48),
      rect(0, 112, 128, 48),
      rect(128, 112, 128, 48),
    },
  }
  return out
end

local function semanticText()
  return {
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
  }
end

-- Previous highlight-shaped manifest: stale once the semantic focus
-- contract is current. Staleness scenarios use it directly; every other
-- scenario builds on the focus-shaped fixture below.
local function validManifest()
  local states = {}
  for _, pocket in ipairs(POCKETS) do
    states[#states + 1] = {
      pocket = pocket,
      pose = "pocket." .. pocket .. ".pose",
      pattern = "pocket." .. pocket .. ".pattern",
    }
  end
  return {
    schema = "g4-bag-assets-v5",
    logicalSize = { width = 256, height = 192 },
    hero = {
      background = {
        male = imageRef("assets/generated/bag/hero-backdrop-male.png"),
        female = imageRef("assets/generated/bag/hero-backdrop-female.png"),
      },
      description = {
        frame = {
          image = "assets/generated/bag/description-frame.png",
          rect = rect(0, 144, 256, 48),
        },
        textRect = rect(20, 144, 228, 40),
      },
      model = { male = heroDescriptor("male"), female = heroDescriptor("female") },
      animations = {
        states = states,
        material = { male = "male.material", female = "female.material" },
      },
      presentation = {
        camera = {
          target = { x = 0, y = 0, z = 0 },
          distance = 339.9,
          angleXDegrees = 328.4,
          angleYDegrees = 28.3,
          perspectiveType = 0,
          perspectiveAngle = 256,
          clipNear = 123.0,
          clipFar = 1700.0,
        },
        transform = {
          translation = { x = 0, y = -45, z = 0 },
          rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
          scale = { x = 1, y = 1, z = 1 },
        },
        lights = {
          count = 4,
          color = { r = 31, g = 31, b = 31 },
          vectors = {
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
          },
        },
        materials = {
          diffuse = { r = 15, g = 15, b = 15 },
          ambient = { r = 10, g = 10, b = 10 },
          specular = { r = 15, g = 15, b = 15 },
          emission = { r = 15, g = 15, b = 15 },
        },
      },
    },
    interactive = {
      backgrounds = backgrounds(),
      pocketTabs = {
        rects = tabs(),
        normal = {
          visualRef("assets/generated/bag/tab-normal-1.png"),
          visualRef("assets/generated/bag/tab-normal-2.png"),
          visualRef("assets/generated/bag/tab-normal-3.png"),
          visualRef("assets/generated/bag/tab-normal-4.png"),
          visualRef("assets/generated/bag/tab-normal-5.png"),
          visualRef("assets/generated/bag/tab-normal-6.png"),
          visualRef("assets/generated/bag/tab-normal-7.png"),
          visualRef("assets/generated/bag/tab-normal-8.png"),
        },
        highlight = visualRef("assets/generated/bag/tab-highlight-frame-1.png"),
      },
      itemSlots = {
        slots = slots(),
        registration = {
          slot1 = markerImage("assets/generated/bag/registration-slot-1.png"),
          slot2 = markerImage("assets/generated/bag/registration-slot-2.png"),
          offset = { x = 0, y = 16 },
        },
      },
      pageIndicator = { rect = rect(80, 168, 56, 16), textAt = { x = 0, y = 0 } },
      cancel = { rect = rect(192, 168, 64, 24), textRect = rect(192, 168, 56, 16) },
      text = semanticText(),
      overlays = {
        actionMenu = {
          face = visualRef("assets/generated/bag/action-face.png"),
          slots = {
            { center = { x = 48, y = 144 }, textRect = rect(8, 136, 80, 16), hitRect = rect(0, 128, 94, 32) },
            { center = { x = 144, y = 144 }, textRect = rect(104, 136, 80, 16), hitRect = rect(96, 128, 96, 32) },
            { center = { x = 48, y = 176 }, textRect = rect(8, 168, 80, 16), hitRect = rect(0, 160, 94, 32) },
            { center = { x = 144, y = 176 }, textRect = rect(104, 168, 80, 16), hitRect = rect(96, 160, 96, 32) },
          },
        },
        quantity = {
          digits = { rect(128, 112, 16, 24), rect(160, 112, 16, 24), rect(192, 112, 16, 24) },
          controls = {
            { delta = 100, role = "increment", center = { x = 136, y = 104 }, hitRect = rect(120, 88, 32, 24) },
            { delta = 10, role = "increment", center = { x = 168, y = 104 }, hitRect = rect(152, 88, 32, 24) },
            { delta = 1, role = "increment", center = { x = 200, y = 104 }, hitRect = rect(184, 88, 32, 24) },
            { delta = -100, role = "decrement", center = { x = 136, y = 152 }, hitRect = rect(120, 136, 32, 24) },
            { delta = -10, role = "decrement", center = { x = 168, y = 152 }, hitRect = rect(152, 136, 32, 24) },
            { delta = -1, role = "decrement", center = { x = 200, y = 152 }, hitRect = rect(184, 136, 32, 24) },
          },
          visuals = {
            increment = {
              normal = visualRef("assets/generated/bag/quantity-increment-normal.png"),
              pressed = visualRef("assets/generated/bag/quantity-increment-pressed.png"),
            },
            decrement = {
              normal = visualRef("assets/generated/bag/quantity-decrement-normal.png"),
              pressed = visualRef("assets/generated/bag/quantity-decrement-pressed.png"),
            },
          },
          pressTicks = 2,
          confirm = {
            visual = visualRef("assets/generated/bag/quantity-confirm.png"),
            center = { x = 136, y = 176 },
            hitRect = rect(96, 168, 78, 24),
            labelAt = { x = 117, y = 168 },
          },
          cancel = {
            visual = visualRef("assets/generated/bag/quantity-cancel.png"),
            center = { x = 224, y = 176 },
            labelAt = { x = 197, y = 168 },
          },
          cancelHitRect = rect(178, 168, 78, 24),
        },
        descriptionFallback = { frame = rect(0, 144, 256, 48), textRect = rect(20, 144, 228, 40) },
      },
    },
  }
end

-- The semantic focus contract: four focus classes with exact target
-- cardinalities (eight tab targets, six item targets, one Cancel target,
-- four action targets). Pocket tabs carry only rects and normal art; the
-- retired highlight has no place in the generated manifest.
local function focusVisual(path)
  return { image = path, width = 32, height = 32 }
end

local function focusTargets()
  local tabTargets = {}
  for k = 0, 7 do
    tabTargets[#tabTargets + 1] = { x = 16 + 32 * k, y = 16 }
  end
  local items = {}
  for _, y in ipairs({ 56, 96, 136 }) do
    items[#items + 1] = { x = 48, y = y }
    items[#items + 1] = { x = 176, y = y }
  end
  return {
    tabs = tabTargets,
    items = items,
    cancel = { x = 224, y = 176 },
    actions = {
      { x = 48, y = 144 },
      { x = 144, y = 144 },
      { x = 48, y = 176 },
      { x = 144, y = 176 },
    },
  }
end

local function framingRecord()
  return { angleXDegrees = 328.4, angleYDegrees = 28.3, distance = 21.2, modelY = -2.8 }
end

local function framingByGender()
  local byGender = {}
  for _, gender in ipairs({ "male", "female" }) do
    local records = {}
    for _, pocket in ipairs(POCKETS) do
      records[pocket] = framingRecord()
    end
    byGender[gender] = records
  end
  return byGender
end

local function stripVisual(pocket)
  return { image = "assets/generated/bag/tabs-" .. pocket .. ".png", width = 256, height = 32 }
end

local function retailEdgeColors()
  return {
    { r = 10, g = 10, b = 10 },
    { r = 15, g = 9, b = 4 },
    { r = 20, g = 20, b = 20 },
    { r = 0, g = 0, b = 0 },
    { r = 0, g = 0, b = 0 },
    { r = 0, g = 0, b = 0 },
    { r = 0, g = 0, b = 0 },
    { r = 0, g = 0, b = 0 },
  }
end

local function salePresentation()
  local function image(path)
    return { image = path, width = 256, height = 192 }
  end
  return {
    pressTicks = 2,
    digits = { rect(128, 112, 16, 24), rect(160, 112, 16, 24) },
    controls = {
      { delta = 10, role = "increment", center = { x = 136, y = 104 }, hitRect = rect(120, 88, 32, 24) },
      { delta = 1, role = "increment", center = { x = 168, y = 104 }, hitRect = rect(152, 88, 32, 24) },
      { delta = -10, role = "decrement", center = { x = 136, y = 152 }, hitRect = rect(120, 136, 32, 24) },
      { delta = -1, role = "decrement", center = { x = 168, y = 152 }, hitRect = rect(152, 136, 32, 24) },
    },
    confirm = {
      visual = visualRef("assets/generated/bag/quantity-confirm.png"),
      center = { x = 136, y = 176 },
      hitRect = rect(96, 168, 78, 24),
      labelAt = { x = 117, y = 168 },
    },
    cancel = {
      visual = visualRef("assets/generated/bag/quantity-cancel.png"),
      center = { x = 224, y = 176 },
      hitRect = rect(178, 168, 78, 24),
      labelAt = { x = 197, y = 168 },
    },
    selectedItem = {
      iconCenter = { x = 86, y = 76 },
      textRect = rect(96, 56, 88, 32),
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    },
    money = {
      x = 0,
      y = 16,
      width = 60,
      height = 16,
      fontId = 0,
      textX = 0,
      textY = 0,
      alignment = "right",
      paletteRole = "foreground",
    },
    moneyLabelAt = { x = 4, y = 0 },
    labels = { money = "Money", sell = "SELL" },
    total = {
      x = 192,
      y = 112,
      width = 64,
      height = 24,
      fontId = 0,
      textX = 0,
      textY = 4,
      alignment = "right",
      paletteRole = "foreground",
    },
    compactPrompt = { x = 200, y = 48, shape = "compact", initialSelection = "yes" },
    messages = {
      notSellable = { segments = { { kind = "item" }, { kind = "text", value = " cannot be sold." } } },
      quantity = { segments = { { kind = "item" }, { kind = "text", value = "? Quantity?" } } },
      offer = { segments = { { kind = "item" }, { kind = "text", value = " offer." }, { kind = "total" } } },
      result = {
        segments = {
          { kind = "quantity" },
          { kind = "text", value = " " },
          { kind = "item" },
          { kind = "text", value = " sold for " },
          { kind = "total" },
        },
      },
    },
  }
end

local function validFocusManifest()
  local manifest = validManifest()
  manifest.schema = BagAssetSchema.SCHEMA
  manifest.interactive.sale = salePresentation()
  manifest.interactive.overlays.tossPrompt = { x = 200, y = 48, shape = "compact", initialSelection = "yes" }
  manifest.interactive.overlays.selectedItem = {
    iconCenter = { x = 86, y = 76 },
    textRect = rect(96, 56, 88, 32),
    nameAt = { x = 0, y = 0 },
    quantityAt = { x = 48, y = 16 },
  }
  manifest.interactive.overlays.messages = {
    selected = { contentRect = rect(16, 8, 216, 16) },
    modal = { contentRect = rect(16, 8, 216, 32) },
    wide = { contentRect = rect(88, 8, 144, 32) },
  }
  manifest.interactive.feedback = {
    totalTicks = 4,
    actionFace = {
      normal = visualRef("assets/generated/bag/action-face.png"),
      selected = visualRef("assets/generated/bag/action-face-selected.png"),
    },
    cancelFace = {
      normal = visualRef("assets/generated/bag/cancel-face-selected-base.png"),
      selected = visualRef("assets/generated/bag/cancel-face-selected.png"),
    },
    quantityConfirm = {
      normal = visualRef("assets/generated/bag/quantity-confirm.png"),
      selected = visualRef("assets/generated/bag/quantity-confirm-selected.png"),
    },
    quantityCancel = {
      normal = visualRef("assets/generated/bag/quantity-cancel.png"),
      selected = visualRef("assets/generated/bag/quantity-cancel-selected.png"),
    },
  }
  local function moveClip(name, total)
    return {
      frames = {
        { image = "assets/generated/bag/" .. name .. "-0.png", width = 32, height = 32, durationTicks = total },
      },
      playback = "once",
      totalTicks = total,
    }
  end
  manifest.interactive.moveTransition =
    { unchanged = moveClip("move-unchanged", 2), changed = moveClip("move-changed", 3) }
  manifest.interactive.moveCursor = {
    original = visualRef("assets/generated/bag/move-cursor-original.png"),
    candidate = visualRef("assets/generated/bag/move-cursor-candidate.png"),
  }
  manifest.interactive.text.tossResult = {
    segments = {
      { kind = "text", value = "Threw away " },
      { kind = "quantity" },
      { kind = "text", value = " " },
      { kind = "item" },
      { kind = "text", value = "." },
    },
  }
  manifest.interactive.text.selectedItem = {
    segments = {
      { kind = "text", value = "The " },
      { kind = "item" },
      { kind = "text", value = " is selected." },
    },
  }
  manifest.interactive.selectionEntry = {
    frames = {
      { image = "assets/generated/bag/selection-entry-0.png", width = 96, height = 40, durationTicks = 2 },
      { image = "assets/generated/bag/selection-entry-1.png", width = 96, height = 40, durationTicks = 3 },
    },
    playback = "once",
    totalTicks = 5,
  }
  manifest.hero.moveSummary = {
    background = imageRef("assets/generated/bag/hero-move-summary.png"),
    labels = {
      type = "TYPE",
      pp = "PP",
      category = "CATEGORY",
      power = "POWER",
      accuracy = "ACCURACY",
      unavailable = "---",
    },
    text = {
      type = { x = 0, y = 104 },
      pp = { x = 16, y = 120 },
      category = { x = 72, y = 104 },
      power = { x = 168, y = 104 },
      accuracy = { x = 168, y = 120 },
      ppValue = { x = 48, y = 120 },
      powerValue = { x = 232, y = 104 },
      accuracyValue = { x = 232, y = 120 },
    },
    typeCenter = { x = 48, y = 112 },
    categoryCenter = { x = 144, y = 112 },
  }
  manifest.interactive.backgrounds = layeredBackgrounds()
  manifest.interactive.cancel = {
    rect = rect(192, 168, 64, 24),
    textRect = rect(192, 168, 56, 16),
    labelRect = rect(200, 168, 48, 16),
  }
  manifest.hero.presentation.framing = {
    transitionTicks = 7,
    baseline = { male = framingRecord(), female = framingRecord() },
    byGender = framingByGender(),
  }
  manifest.hero.presentation.edgeColors = retailEdgeColors()
  local strips = {}
  for _, pocket in ipairs(POCKETS) do
    strips[pocket] = stripVisual(pocket)
  end
  manifest.interactive.pocketTabs = {
    rects = manifest.interactive.pocketTabs.rects,
    strips = strips,
  }
  local targets = focusTargets()
  manifest.interactive.focus = {
    tabs = { visual = focusVisual("assets/generated/bag/focus-tabs.png"), targets = targets.tabs },
    items = { visual = focusVisual("assets/generated/bag/focus-items.png"), targets = targets.items },
    cancel = { visual = focusVisual("assets/generated/bag/focus-cancel.png"), target = targets.cancel },
    actions = { visual = focusVisual("assets/generated/bag/focus-actions.png"), targets = targets.actions },
  }
  return manifest
end

local function assertInvalid(manifest, why)
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), why)
end

local function validDynamicManifest()
  local manifest = validFocusManifest()
  return manifest
end

-- The strip contract is the current focus-manifest shape above.
local function validStripManifest()
  return validFocusManifest()
end

-- The toss contract under test: the current focus fixture plus the
-- semantic prompt placement and the post-choice result text on the
-- bumped schema. Only the new toss scenarios build on it; every other
-- scenario keeps the versioned focus fixture above.
local function validTossManifest()
  local manifest = validFocusManifest()
  manifest.schema = BagAssetSchema.SCHEMA
  manifest.interactive.overlays.tossPrompt = { x = 200, y = 48, shape = "compact", initialSelection = "yes" }
  manifest.interactive.text.tossResult = {
    segments = {
      { kind = "text", value = "Threw away " },
      { kind = "quantity" },
      { kind = "text", value = " " },
      { kind = "item" },
      { kind = "text", value = "." },
    },
  }
  return manifest
end

local function deepCopyManifest(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[deepCopyManifest(key)] = deepCopyManifest(item)
  end
  return out
end

function T.schema_rejects_out_of_bounds_rectangles()
  local manifest = validFocusManifest()
  manifest.interactive.cancel = rect(250, 168, 56, 16)
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "a rectangle escaping the pane must fail")
  manifest = validFocusManifest()
  manifest.interactive.pocketTabs.rects[8] = rect(224, 0, 33, 32)
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "an overflowing tab must fail")
end

function T.schema_rejects_wrong_tab_and_slot_cardinality()
  local manifest = validFocusManifest()
  manifest.interactive.pocketTabs.rects[8] = nil
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "seven tabs must fail")
  manifest = validFocusManifest()
  manifest.interactive.itemSlots.slots[7] = manifest.interactive.itemSlots.slots[1]
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "seven slots must fail")
end

function T.schema_rejects_source_identities_in_the_runtime_manifest()
  local manifest = validFocusManifest()
  manifest.hero.presentation.camera.target = { x = 0, y = 0, z = 0, memberId = 55 }
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "a member identity must fail")
  manifest = validFocusManifest()
  manifest.interactive.backgrounds.browse = {
    image = "assets/generated/bag/list-slots.png",
    width = 256,
    height = 192,
    narcId = 15,
  }
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "an archive identity must fail")
end

function T.cache_reports_ready_only_with_every_referenced_file()
  local manifest = validFocusManifest()
  local marker = BagCache.marker("deadbeef", "feedface")
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  cacheFs:writeLua(BagCache.manifestPath(), manifest)
  for _, path in ipairs(BagCache.referencedPaths(manifest)) do
    cacheFs:write(path, "payload")
  end
  cacheFs:writeLua(BagCache.provenancePath(), { cacheFormat = BagCache.FORMAT, schema = BagCache.SCHEMA })
  cacheFs:write(BagCache.markerPath(), marker)
  Assert.isTrue(BagCache.isReady(cacheFs, marker))
  cacheFs:remove("assets/generated/bag/tabs-mail.png")
  Assert.isFalse(BagCache.isReady(cacheFs, marker), "a missing tab image is not ready")
end

function T.manifest_validation_returns_expected_errors_and_propagates_unexpected_failures()
  local valid = BagAssetSchema.assertManifest
  local ok, failure = BagAssetSchema.isValidManifest({})
  Assert.isFalse(ok, "schema-invalid manifests remain ordinary validation negatives")
  Assert.isTrue(Errors.is(failure), "schema-invalid manifests preserve their typed reason")
  Assert.equal(failure.code, "BAG_MANIFEST_INVALID")

  local unexpected = {}
  BagAssetSchema.assertManifest = function()
    error(unexpected, 0)
  end
  local propagated, reason = pcall(BagAssetSchema.isValidManifest, {})
  BagAssetSchema.assertManifest = valid

  Assert.isFalse(propagated, "programming failures must not become stale-cache results")
  Assert.equal(reason, unexpected, "the original unexpected failure is propagated")
end

function T.cache_readiness_propagates_trusted_manifest_path_failures()
  local manifest = validFocusManifest()
  local marker = BagCache.marker("deadbeef", "feedface")
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  cacheFs:writeLua(BagCache.manifestPath(), manifest)
  for _, path in ipairs(BagCache.referencedPaths(manifest)) do
    cacheFs:write(path, "payload")
  end
  cacheFs:writeLua(BagCache.provenancePath(), { cacheFormat = BagCache.FORMAT, schema = BagCache.SCHEMA })
  cacheFs:write(BagCache.markerPath(), marker)

  local referencedPaths = BagCache.referencedPaths
  local unexpected = {}
  BagCache.referencedPaths = function()
    error(unexpected, 0)
  end
  local propagated, reason = pcall(BagCache.isReady, cacheFs, marker)
  BagCache.referencedPaths = referencedPaths

  Assert.isFalse(propagated, "trusted-path invariant failures must not become cache misses")
  Assert.equal(reason, unexpected, "the original unexpected failure is propagated")
end

function T.cache_reports_not_ready_without_the_quantity_cancel_visuals()
  local manifest = validFocusManifest()
  local marker = BagCache.marker("deadbeef", "feedface")
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  cacheFs:writeLua(BagCache.manifestPath(), manifest)
  for _, path in ipairs(BagCache.referencedPaths(manifest)) do
    cacheFs:write(path, "payload")
  end
  cacheFs:writeLua(BagCache.provenancePath(), { cacheFormat = BagCache.FORMAT, schema = BagCache.SCHEMA })
  cacheFs:write(BagCache.markerPath(), marker)
  Assert.isTrue(BagCache.isReady(cacheFs, marker), "the complete class is ready before damage")
  cacheFs:remove("assets/generated/bag/quantity-cancel.png")
  Assert.isFalse(BagCache.isReady(cacheFs, marker), "a missing quantity cancel visual is not ready")
  cacheFs:write("assets/generated/bag/quantity-cancel.png", "payload")
  cacheFs:remove("assets/generated/bag/quantity-cancel-selected.png")
  Assert.isFalse(BagCache.isReady(cacheFs, marker), "a missing quantity cancel flash is not ready")
end

function T.complete_manifest_with_text_and_registration_passes()
  local manifest = validFocusManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the complete fixture must pass")
end

function T.unknown_action_and_template_fields_are_rejected()
  local extraAction = validFocusManifest()
  extraAction.interactive.text.actions.inspect = "INSPECT"
  assertInvalid(extraAction, "an action outside the runtime vocabulary must fail")
  local extraTemplate = validFocusManifest()
  extraTemplate.interactive.text.inspectPrompt = { segments = { { kind = "text", value = "?" } } }
  assertInvalid(extraTemplate, "a template outside the runtime vocabulary must fail")
  local extraField = validFocusManifest()
  extraField.interactive.text.bank = 10
  assertInvalid(extraField, "producer-side message selection must not leak into the manifest")
end

function T.registration_markers_are_exactly_sized()
  local wide = validFocusManifest()
  wide.interactive.itemSlots.registration.slot1 = markerImage("assets/generated/bag/registration-slot-1.png")
  wide.interactive.itemSlots.registration.slot1.width = 41
  assertInvalid(wide, "a 41-pixel marker must fail")
  local short = validFocusManifest()
  short.interactive.itemSlots.registration.slot2 = markerImage("assets/generated/bag/registration-slot-2.png")
  short.interactive.itemSlots.registration.slot2.height = 15
  assertInvalid(short, "a 15-pixel marker must fail")
end

function T.semantic_focus_contract_validates_with_exact_target_counts()
  local manifest = validFocusManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the focus manifest must pass the schema")
  Assert.keySet(manifest.interactive.pocketTabs, "rects,strips", "pocket tabs carry only rects and strips")
  Assert.keySet(manifest.interactive.focus, "actions,cancel,items,tabs", "focus carries exactly four classes")
  Assert.equal(#manifest.interactive.focus.tabs.targets, 8, "eight tab targets are required")
  Assert.equal(#manifest.interactive.focus.items.targets, 6, "six item targets are required")
  Assert.equal(#manifest.interactive.focus.actions.targets, 4, "four action targets are required")
end

function T.control_visuals_are_current_and_each_is_referenced_once()
  local manifest = validFocusManifest()
  local paths = assert(BagCache.referencedPaths(manifest))
  local counts = {}
  for _, path in ipairs(paths) do
    counts[path] = (counts[path] or 0) + 1
  end
  -- The shared normal faces back both the stable controls and the
  -- feedback latch, so each appears twice; every flash, cursor, and
  -- move-clip visual appears once.
  for _, path in ipairs({
    "assets/generated/bag/action-face.png",
  }) do
    Assert.equal(counts[path], 2, path .. " backs its control and the feedback latch")
  end
  for _, path in ipairs({
    "assets/generated/bag/quantity-confirm.png",
    "assets/generated/bag/quantity-cancel.png",
  }) do
    Assert.equal(counts[path], 3, path .. " backs both quantity-mode controls and the feedback latch")
  end
  for _, path in ipairs({
    "assets/generated/bag/quantity-increment-normal.png",
    "assets/generated/bag/quantity-increment-pressed.png",
    "assets/generated/bag/quantity-decrement-normal.png",
    "assets/generated/bag/quantity-decrement-pressed.png",
    "assets/generated/bag/action-face-selected.png",
    "assets/generated/bag/cancel-face-selected-base.png",
    "assets/generated/bag/cancel-face-selected.png",
    "assets/generated/bag/quantity-confirm-selected.png",
    "assets/generated/bag/quantity-cancel-selected.png",
    "assets/generated/bag/move-cursor-original.png",
    "assets/generated/bag/move-cursor-candidate.png",
    "assets/generated/bag/move-unchanged-0.png",
    "assets/generated/bag/move-changed-0.png",
  }) do
    Assert.equal(counts[path], 1, path .. " is referenced exactly once")
  end
end

function T.layered_backgrounds_share_bases_rows_and_overlays_across_states()
  local manifest = validDynamicManifest()
  manifest.interactive.backgrounds = layeredBackgrounds()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the layered v20 backgrounds must validate")
  local ok, paths = pcall(BagCache.referencedPaths, manifest)
  Assert.isTrue(ok, "the cache must resolve the layered manifest")
  assert(paths ~= nil, "a resolvable manifest must list its paths")
  local counts = {}
  for _, path in ipairs(paths) do
    counts[path] = (counts[path] or 0) + 1
  end
  for _, pocket in ipairs(POCKETS) do
    local browseEntry = assert(
      manifest.interactive.backgrounds.browse[pocket],
      "browse covers pocket " .. pocket
    )
    Assert.equal(browseEntry.base.width, 256, "pocket " .. pocket .. " base keeps the pane width")
    Assert.equal(browseEntry.base.height, 192, "pocket " .. pocket .. " base keeps the pane height")
    Assert.equal(#browseEntry.rows, 3, "pocket " .. pocket .. " publishes three row patches")
    for row = 1, 3 do
      local patch = assert(browseEntry.rows[row], "pocket " .. pocket .. " publishes row patch " .. row)
      Assert.equal(patch.width, 124, "pocket " .. pocket .. " row " .. row .. " keeps the art width")
      Assert.equal(patch.height, 38, "pocket " .. pocket .. " row " .. row .. " keeps the art height")
    end
    for row = 0, 2 do
      local patch = "assets/generated/bag/background-browse-row-" .. pocket .. "-" .. row .. ".png"
      Assert.equal(counts[patch], 1, patch .. " must be referenced exactly once")
    end
    for count = 1, 4 do
      local moveBase = "assets/generated/bag/background-move-" .. pocket .. "-count-" .. count .. ".png"
      Assert.equal(counts[moveBase], 1, moveBase .. " must be referenced exactly once")
    end
    local sharedMove = "assets/generated/bag/background-move-" .. pocket .. "-count-0.png"
    Assert.equal(counts[sharedMove], 3, sharedMove .. " backs the identical counts 0, 5, and 6")
    for _, state in ipairs({ "action", "quantity" }) do
      local overlay = "assets/generated/bag/background-" .. state .. "-overlay-" .. pocket .. ".png"
      Assert.equal(counts[overlay], 1, overlay .. " must be referenced exactly once")
    end
  end
  local cells = assert(
    manifest.interactive.backgrounds.browseCells,
    "the layered manifest carries its six browse cell rects"
  )
  Assert.equal(#cells, 6, "browse publishes all six cell placements")
  for index, cell in ipairs(cells) do
    Assert.equal(cell.width, 124, "browse cell " .. index .. " keeps the audited art width")
    Assert.equal(cell.height, 38, "browse cell " .. index .. " keeps the audited art height")
  end
end

function T.hero_framing_carries_baseline_and_pocket_records_for_both_genders()
  local manifest = validDynamicManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the pocket-aware hero framing must validate")
  local framing = assert(manifest.hero.presentation.framing, "the hero presentation must publish its pocket framing")
  Assert.equal(framing.transitionTicks, 7, "the framing transition keeps its fixed-tick duration")
  for _, gender in ipairs({ "male", "female" }) do
    local baseline = assert(framing.baseline[gender], gender .. " publishes its baseline framing record")
    local pockets = assert(framing.byGender[gender], gender .. " publishes its pocket framing records")
    local seen = 0
    for _, pocket in ipairs(POCKETS) do
      local record = assert(pockets[pocket], gender .. " publishes the " .. pocket .. " framing record")
      seen = seen + 1
      for _, field in ipairs({ "angleXDegrees", "angleYDegrees", "distance", "modelY" }) do
        local value = record[field]
        Assert.isTrue(
          type(value) == "number" and value == value and value < math.huge and value > -math.huge,
          gender .. " " .. pocket .. " framing " .. field .. " must be a finite number"
        )
      end
    end
    Assert.equal(seen, 8, gender .. " publishes all eight pocket framing records")
    for _, field in ipairs({ "angleXDegrees", "angleYDegrees", "distance", "modelY" }) do
      local value = baseline[field]
      Assert.isTrue(
        type(value) == "number" and value == value and value < math.huge and value > -math.huge,
        gender .. " baseline framing " .. field .. " must be a finite number"
      )
    end
  end
end

-- The strip contract is the current focus-manifest shape above.

function T.pocket_strips_and_edge_colors_validate_as_the_current_contract()
  Assert.equal(BagAssetSchema.SCHEMA, "g4-bag-assets-v20")
  Assert.equal(DerivedAssetContract.bag.schema, "g4-bag-assets-v20")
  Assert.equal(BagCache.SCHEMA, "g4-bag-assets-v20")
  Assert.equal(BagCache.FORMAT, "bag-cache-v2")
  local manifest = validStripManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the pocket-strip manifest must pass the schema")
  Assert.keySet(manifest.interactive.pocketTabs, "rects,strips", "pocket tabs carry only rects and strips")
end

function T.quantity_cancel_and_label_origins_are_required()
  -- Each required quantity record is omitted on its own: every case
  -- starts from the valid contract and removes exactly one field.
  local withoutTossLabel = validFocusManifest()
  withoutTossLabel.interactive.overlays.quantity.confirm.labelAt = nil
  Assert.isFalse(BagAssetSchema.isValidManifest(withoutTossLabel), "a manifest without the toss label origin must fail")
  local withoutCancel = validFocusManifest()
  withoutCancel.interactive.overlays.quantity.cancel = nil
  Assert.isFalse(
    BagAssetSchema.isValidManifest(withoutCancel),
    "a manifest without the quantity cancel record must fail"
  )
  local withoutCancelLabel = validFocusManifest()
  withoutCancelLabel.interactive.overlays.quantity.cancel.labelAt = nil
  Assert.isFalse(
    BagAssetSchema.isValidManifest(withoutCancelLabel),
    "a manifest without the cancel label origin must fail"
  )
  local withoutCancelFeedback = validFocusManifest()
  withoutCancelFeedback.interactive.feedback.quantityCancel = nil
  Assert.isFalse(
    BagAssetSchema.isValidManifest(withoutCancelFeedback),
    "a manifest without quantity cancel activation feedback must fail"
  )
end

function T.toss_prompt_placement_and_result_text_are_required()
  local manifest = validTossManifest()
  Assert.deepEqual(
    manifest.interactive.overlays.tossPrompt,
    { x = 200, y = 48, shape = "compact", initialSelection = "yes" },
    "the toss prompt carries the audited semantic placement"
  )
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the prompt placement and result text must pass")
  local missingPlacement = validTossManifest()
  missingPlacement.interactive.overlays.tossPrompt = nil
  assertInvalid(missingPlacement, "a manifest without the toss prompt placement must fail")
  local missingResult = validTossManifest()
  missingResult.interactive.text.tossResult = nil
  assertInvalid(missingResult, "a manifest without the post-choice result text must fail")
end

function T.selection_entry_and_selected_item_presentation_are_required()
  local manifest = validFocusManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the selection entry and selected-item text must pass")
  local missingEntry = validFocusManifest()
  missingEntry.interactive.selectionEntry = nil
  assertInvalid(missingEntry, "a manifest without the selection entry must fail")
  local missingText = validFocusManifest()
  missingText.interactive.text.selectedItem = nil
  assertInvalid(missingText, "a manifest without the selected-item text must fail")
  local badTotal = validFocusManifest()
  badTotal.interactive.selectionEntry.totalTicks = 4
  assertInvalid(badTotal, "a manifest with a wrong selection total must fail")
  local looping = validFocusManifest()
  looping.interactive.selectionEntry.playback = "loop"
  assertInvalid(looping, "a manifest with a looping selection entry must fail")
  local zeroDuration = validFocusManifest()
  zeroDuration.interactive.selectionEntry.frames[1].durationTicks = 0
  assertInvalid(zeroDuration, "a manifest with a non-positive frame duration must fail")
end

function T.generic_contract_accepts_safe_presentation_variants()
  local timing = validDynamicManifest()
  timing.hero.presentation.framing.transitionTicks = 12
  Assert.isTrue(BagAssetSchema.isValidManifest(timing), "a positive framing cadence stays consumable")
  local moved = validTossManifest()
  moved.interactive.overlays.tossPrompt = { x = 100, y = 100, shape = "compact", initialSelection = "yes" }
  Assert.isTrue(BagAssetSchema.isValidManifest(moved), "a record-shaped prompt placement stays consumable")
  local alternate = validTossManifest()
  alternate.interactive.overlays.tossPrompt = { x = 200, y = 48, shape = "compact", initialSelection = "no" }
  Assert.isTrue(BagAssetSchema.isValidManifest(alternate), "either supported preselection stays consumable")
end

function T.validation_leaves_the_manifest_untouched_across_repeated_calls()
  local manifest = validFocusManifest()
  local snapshot = deepCopyManifest(manifest)
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the first validation must pass")
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the repeated validation must pass")
  Assert.deepEqual(manifest, snapshot, "validation must not normalize or mutate any record")
  local independent = deepCopyManifest(manifest)
  independent.logicalSize = { width = 512, height = 192 }
  Assert.isFalse(BagAssetSchema.isValidManifest(independent), "the mutated copy must fail")
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the original must stay valid after the copy mutates")
  Assert.deepEqual(manifest, snapshot, "the original must keep its shape after the copy mutates")
end

function T.path_enumeration_lists_referenced_files_without_reauditing_the_contract()
  local manifest = validDynamicManifest()
  manifest.hero.presentation.framing.transitionTicks = 12
  local paths = BagCache.referencedPaths(manifest)
  Assert.isTrue(type(paths) == "table" and #paths > 0, "traversal lists referenced files")
  local found = false
  for _, path in ipairs(paths) do
    if path == "assets/generated/bag/tabs-mail.png" then
      found = true
    end
  end
  Assert.isTrue(found, "traversal still reaches the tab images")
end

return { tests = T }
