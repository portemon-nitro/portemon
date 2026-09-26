-- Current synthetic bag presentation manifest shared by the tests that
-- need a valid bag artifact: the schema-valid shapes the asset contract
-- requires, with synthetic image paths each consumer seeds itself.
-- Pure manifest data only; consumers own bytes, caches, and publication.

local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local BagPresentationFixture = {}

---@param path string
---@return table<string, unknown>
local function bagImageRef(path)
  return { image = path, width = 256, height = 192 }
end

---@param x integer
---@param y integer
---@param width integer
---@param height integer
---@return table<string, integer>
local function bagRect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function bagConstantChannel()
  return { source = "constant", value = 0 }
end

---@param id string
---@param semanticName string
---@return table<string, unknown>
local function bagClip(id, semanticName)
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
            trans = { x = bagConstantChannel(), y = bagConstantChannel(), z = bagConstantChannel() },
            rot = bagConstantChannel(),
            scale = { x = bagConstantChannel(), y = bagConstantChannel(), z = bagConstantChannel() },
          },
        },
      },
    },
  }
end

---@return table<string, unknown>
local function bagDynamicMaterial()
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

---@return table<string, unknown>
local function bagMoveSummary()
  local function icon(key)
    return { image = "assets/generated/bag/move-" .. key .. ".png", width = 64, height = 16 }
  end
  local typeIcons = {}
  for _, key in ipairs({
    "normal",
    "fighting",
    "flying",
    "poison",
    "ground",
    "rock",
    "bug",
    "ghost",
    "steel",
    "mystery",
    "fire",
    "water",
    "grass",
    "electric",
    "psychic",
    "ice",
    "dragon",
    "dark",
  }) do
    typeIcons[key] = icon(key)
  end
  return {
    background = bagImageRef("assets/generated/bag/hero-move-summary.png"),
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
    typeIcons = typeIcons,
    categoryIcons = { physical = icon("physical"), special = icon("special"), status = icon("status") },
  }
end

---@param gender string
---@return table<string, unknown>
local function bagHeroDescriptor(gender)
  local clips = {}
  for _, pocket in ipairs(BagAssetSchema.POCKETS) do
    clips[#clips + 1] = bagClip(gender .. ".pose." .. pocket, "pocket." .. pocket .. ".pose")
    clips[#clips + 1] = bagClip(gender .. ".pattern." .. pocket, "pocket." .. pocket .. ".pattern")
  end
  clips[#clips + 1] = bagClip(gender .. ".material", "bag.material")
  return {
    schema = ModelAsset.SCHEMA,
    kind = "nitro-dynamic",
    dynamic = { nodes = {}, transformProgram = {}, batches = {} },
    materials = { bagDynamicMaterial() },
    animations = clips,
  }
end

-- Fresh schema-valid bag manifest on every call: every nested array and
-- map is newly allocated, so callers own the returned graph and may
-- mutate it without affecting later calls.
---@return table<string, unknown>
function BagPresentationFixture.manifest()
  local states = {}
  for _, pocket in ipairs(BagAssetSchema.POCKETS) do
    states[#states + 1] = {
      pocket = pocket,
      pose = "pocket." .. pocket .. ".pose",
      pattern = "pocket." .. pocket .. ".pattern",
    }
  end
  local tabs = {}
  for i = 0, 7 do
    tabs[#tabs + 1] = bagRect(i * 32, 0, 32, 32)
  end
  local tabStrips = {}
  for _, pocket in ipairs(BagAssetSchema.POCKETS) do
    tabStrips[pocket] = { image = "assets/generated/bag/tabs-" .. pocket .. ".png", width = 256, height = 32 }
  end
  local slotShapes = {
    { rect = { 0, 32, 128, 42 }, text = { 32, 40, 88, 32 }, center = { 48, 56 } },
    { rect = { 128, 32, 128, 42 }, text = { 160, 40, 88, 32 }, center = { 176, 56 } },
    { rect = { 0, 74, 128, 44 }, text = { 32, 80, 88, 32 }, center = { 48, 96 } },
    { rect = { 128, 74, 128, 44 }, text = { 160, 80, 88, 32 }, center = { 176, 96 } },
    { rect = { 0, 118, 128, 36 }, text = { 32, 120, 88, 32 }, center = { 48, 136 } },
    { rect = { 128, 118, 128, 36 }, text = { 160, 120, 88, 32 }, center = { 176, 136 } },
  }
  local slots = {}
  for _, shape in ipairs(slotShapes) do
    slots[#slots + 1] = {
      rect = bagRect(shape.rect[1], shape.rect[2], shape.rect[3], shape.rect[4]),
      textRect = bagRect(shape.text[1], shape.text[2], shape.text[3], shape.text[4]),
      iconCenter = { x = shape.center[1], y = shape.center[2] },
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    }
  end
  local backgrounds = {}
  for _, state in ipairs({ "action", "quantity", "confirmation" }) do
    local pockets = {}
    for _, pocket in ipairs(BagAssetSchema.POCKETS) do
      pockets[pocket] = bagImageRef("assets/generated/bag/background-" .. state .. "-" .. pocket .. ".png")
    end
    backgrounds[state] = pockets
  end
  do
    local browse = {}
    for _, pocket in ipairs(BagAssetSchema.POCKETS) do
      local variants = {}
      for count = 0, 6 do
        variants[#variants + 1] =
          bagImageRef("assets/generated/bag/background-browse-" .. pocket .. "-count-" .. count .. ".png")
      end
      browse[pocket] = variants
    end
    backgrounds.browse = browse
  end
  local function framingRecord()
    return { angleXDegrees = 328.4, angleYDegrees = 28.3, distance = 21.2, modelY = -2.8 }
  end
  local framingByGender = {}
  for _, gender in ipairs({ "male", "female" }) do
    local records = {}
    for _, pocket in ipairs(BagAssetSchema.POCKETS) do
      records[pocket] = framingRecord()
    end
    framingByGender[gender] = records
  end
  return {
    schema = BagAssetSchema.SCHEMA,
    logicalSize = { width = 256, height = 192 },
    hero = {
      background = {
        male = bagImageRef("assets/generated/bag/hero-male.png"),
        female = bagImageRef("assets/generated/bag/hero-female.png"),
      },
      description = {
        frame = {
          image = "assets/generated/bag/description-frame.png",
          rect = bagRect(0, 144, 256, 48),
        },
        textRect = bagRect(20, 144, 228, 40),
      },
      moveSummary = bagMoveSummary(),
      model = { male = bagHeroDescriptor("male"), female = bagHeroDescriptor("female") },
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
        framing = {
          transitionTicks = 7,
          baseline = { male = framingRecord(), female = framingRecord() },
          byGender = framingByGender,
        },
        edgeColors = {
          { r = 10, g = 10, b = 10 },
          { r = 15, g = 9, b = 4 },
          { r = 20, g = 20, b = 20 },
          { r = 0, g = 0, b = 0 },
          { r = 0, g = 0, b = 0 },
          { r = 0, g = 0, b = 0 },
          { r = 0, g = 0, b = 0 },
          { r = 0, g = 0, b = 0 },
        },
      },
    },
    interactive = {
      backgrounds = backgrounds,
      pocketTabs = {
        rects = tabs,
        strips = tabStrips,
      },
      focus = {
        tabs = {
          visual = { image = "assets/generated/bag/focus-tabs.png", width = 32, height = 32 },
          targets = {
            { x = 16, y = 16 },
            { x = 48, y = 16 },
            { x = 80, y = 16 },
            { x = 112, y = 16 },
            { x = 144, y = 16 },
            { x = 176, y = 16 },
            { x = 208, y = 16 },
            { x = 240, y = 16 },
          },
        },
        items = {
          visual = { image = "assets/generated/bag/focus-items.png", width = 96, height = 40 },
          targets = {
            { x = 16, y = 48 },
            { x = 144, y = 48 },
            { x = 16, y = 88 },
            { x = 144, y = 88 },
            { x = 16, y = 128 },
            { x = 144, y = 128 },
          },
        },
        cancel = {
          visual = { image = "assets/generated/bag/focus-cancel.png", width = 64, height = 24 },
          target = { x = 224, y = 176 },
        },
        actions = {
          visual = { image = "assets/generated/bag/focus-actions.png", width = 96, height = 24 },
          targets = {
            { x = 48, y = 144 },
            { x = 144, y = 144 },
            { x = 48, y = 176 },
            { x = 144, y = 176 },
          },
        },
      },
      itemSlots = {
        slots = slots,
        registration = {
          slot1 = { image = "assets/generated/bag/registration-slot-1.png", width = 40, height = 16 },
          slot2 = { image = "assets/generated/bag/registration-slot-2.png", width = 40, height = 16 },
          offset = { x = 0, y = 16 },
        },
      },
      pageIndicator = { rect = bagRect(80, 168, 56, 16), textAt = { x = 0, y = 0 } },
      cancel = {
        rect = bagRect(192, 168, 64, 24),
        textRect = bagRect(192, 168, 56, 16),
        labelRect = bagRect(200, 168, 48, 16),
      },
      text = {
        actions = {
          toss = "TOSS",
          move = "MOVE",
          register = "REGISTER",
          unregister = "DESELECT",
          cancel = "CANCEL",
          confirm = "YES",
        },
        movePrompt = {
          segments = { { kind = "text", value = "Move " }, { kind = "item" }, { kind = "text", value = "?" } },
        },
        tossQuantity = {
          segments = { { kind = "text", value = "Toss " }, { kind = "item" }, { kind = "text", value = "?" } },
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
        tossResult = {
          segments = {
            { kind = "text", value = "Threw away " },
            { kind = "quantity" },
            { kind = "text", value = " " },
            { kind = "item" },
            { kind = "text", value = "." },
          },
        },
      },
      overlays = {
        actionMenu = {
          face = bagImageRef("assets/generated/bag/action-face.png"),
          slots = {
            { center = { x = 48, y = 144 }, textRect = bagRect(8, 136, 80, 16), hitRect = bagRect(0, 128, 94, 32) },
            { center = { x = 144, y = 144 }, textRect = bagRect(104, 136, 80, 16), hitRect = bagRect(96, 128, 96, 32) },
            { center = { x = 48, y = 176 }, textRect = bagRect(8, 168, 80, 16), hitRect = bagRect(0, 160, 94, 32) },
            { center = { x = 144, y = 176 }, textRect = bagRect(104, 168, 80, 16), hitRect = bagRect(96, 160, 96, 32) },
          },
        },
        quantity = {
          digits = { bagRect(128, 112, 16, 24), bagRect(160, 112, 16, 24), bagRect(192, 112, 16, 24) },
          controls = {
            { delta = 100, role = "increment", center = { x = 136, y = 104 }, hitRect = bagRect(120, 88, 32, 24) },
            { delta = 10, role = "increment", center = { x = 168, y = 104 }, hitRect = bagRect(152, 88, 32, 24) },
            { delta = 1, role = "increment", center = { x = 200, y = 104 }, hitRect = bagRect(184, 88, 32, 24) },
            { delta = -100, role = "decrement", center = { x = 136, y = 152 }, hitRect = bagRect(120, 136, 32, 24) },
            { delta = -10, role = "decrement", center = { x = 168, y = 152 }, hitRect = bagRect(152, 136, 32, 24) },
            { delta = -1, role = "decrement", center = { x = 200, y = 152 }, hitRect = bagRect(184, 136, 32, 24) },
          },
          visuals = {
            increment = {
              normal = bagImageRef("assets/generated/bag/quantity-increment-normal.png"),
              pressed = bagImageRef("assets/generated/bag/quantity-increment-pressed.png"),
            },
            decrement = {
              normal = bagImageRef("assets/generated/bag/quantity-decrement-normal.png"),
              pressed = bagImageRef("assets/generated/bag/quantity-decrement-pressed.png"),
            },
          },
          pressTicks = 2,
          confirm = {
            visual = bagImageRef("assets/generated/bag/quantity-confirm.png"),
            center = { x = 136, y = 176 },
            hitRect = bagRect(96, 168, 78, 24),
          },
          cancelHitRect = bagRect(178, 168, 78, 24),
        },
        descriptionFallback = { frame = bagRect(0, 144, 256, 48), textRect = bagRect(20, 144, 228, 40) },
        tossPrompt = { x = 200, y = 48, shape = "compact", initialSelection = "yes" },
      },
    },
  }
end

return BagPresentationFixture
