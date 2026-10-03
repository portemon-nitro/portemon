-- Complete schema-valid synthetic mart presentation used by component tests.

local MartAssetSchema = require("libs.assets.src.MartAssetSchema")

local function point(x, y)
  return { x = x, y = y }
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function visual(key)
  return { image = "assets/generated/mart/" .. key .. ".png", width = 8, height = 8, offsetX = 0, offsetY = 0 }
end

local function textBox(x, y, width, height, textX, textY, alignment)
  return {
    x = x,
    y = y,
    width = width,
    height = height,
    fontId = 0,
    textX = textX or 0,
    textY = textY or 0,
    alignment = alignment or "left",
    paletteRole = "foreground",
  }
end

local function control(x, y, width, height, key, anchorX, anchorY)
  return {
    anchor = point(anchorX or x, anchorY or y),
    hitbox = rect(x, y, width, height),
    normalVisualKey = key .. ".normal",
    selectedVisualKey = key .. ".selected",
  }
end

local function clip(name, totalTicks)
  return {
    playback = "once",
    frames = { { visual = visual(name), ticks = totalTicks } },
    totalTicks = totalTicks,
  }
end

local function manifest()
  local controls = {}
  local function addControl(key)
    controls[key .. ".normal"] = { normal = visual(key .. "-normal"), selected = visual(key .. "-normal-selected") }
    controls[key .. ".selected"] = { normal = visual(key .. "-selected-normal"), selected = visual(key .. "-selected") }
  end
  for _, key in ipairs({ "previous", "next", "cancel", "inc10", "inc1", "dec10", "dec1", "buy", "quantity-cancel" }) do
    addControl(key)
  end
  local slots = {
    {
      hitbox = rect(0, 32, 128, 42),
      iconAnchor = point(22, 59),
      labelBox = textBox(32, 40, 88, 32),
      priceAt = point(68, 56),
      focusAnchor = point(48, 56),
    },
    {
      hitbox = rect(128, 32, 128, 42),
      iconAnchor = point(152, 59),
      labelBox = textBox(160, 40, 88, 32),
      priceAt = point(196, 56),
      focusAnchor = point(176, 56),
    },
    {
      hitbox = rect(0, 74, 128, 44),
      iconAnchor = point(22, 100),
      labelBox = textBox(32, 80, 88, 32),
      priceAt = point(68, 96),
      focusAnchor = point(48, 96),
    },
    {
      hitbox = rect(128, 74, 128, 44),
      iconAnchor = point(152, 100),
      labelBox = textBox(160, 80, 88, 32),
      priceAt = point(196, 96),
      focusAnchor = point(176, 96),
    },
    {
      hitbox = rect(0, 118, 128, 36),
      iconAnchor = point(22, 139),
      labelBox = textBox(32, 120, 88, 32),
      priceAt = point(68, 136),
      focusAnchor = point(48, 136),
    },
    {
      hitbox = rect(128, 118, 128, 36),
      iconAnchor = point(152, 139),
      labelBox = textBox(160, 120, 88, 32),
      priceAt = point(196, 136),
      focusAnchor = point(176, 136),
    },
  }
  local quantity = {
    selectedItemAnchor = point(86, 76),
    itemBox = textBox(96, 56, 88, 32),
    owned = {
      labelBox = textBox(8, 104, 64, 40, 0, 4),
      valueBox = textBox(8, 104, 64, 40, 0, 20, "right"),
    },
    totalBox = textBox(184, 112, 64, 24, 0, 4, "right"),
    digitBoxes = {
      textBox(128, 112, 16, 24, 0, 4, "right"),
      textBox(160, 112, 16, 24, 0, 4, "right"),
    },
    increment10 = control(120, 88, 32, 24, "inc10", 136, 104),
    increment1 = control(152, 88, 32, 24, "inc1", 168, 104),
    decrement10 = control(120, 136, 32, 24, "dec10", 136, 152),
    decrement1 = control(152, 136, 32, 24, "dec1", 168, 152),
    confirm = control(96, 168, 78, 24, "buy", 136, 176),
    cancel = control(178, 168, 78, 24, "quantity-cancel", 224, 176),
    buyLabelBox = textBox(112, 168, 56, 16, 4),
  }
  local templates = {}
  for _, role in ipairs({
    "insufficientMoney",
    "quantityPrompt",
    "moneyConfirm",
    "itemReceived",
    "noRoom",
    "cancelLabel",
    "moneyPrice",
    "pointsPrice",
    "premierBonus",
    "sealReceived",
    "sealFull",
    "boughtToday",
    "alreadyOwned",
    "moneyLabel",
    "moneyBalance",
    "pointsBalance",
    "pointsLabel",
    "ownedLabel",
    "ownedCount",
    "quantityTotal",
    "buyLabel",
    "pageNumber",
    "tensDigit",
    "unitsDigit",
    "pointsConfirm",
    "insufficientPoints",
    "pointsReceived",
  }) do
    templates[role] = { parts = { { kind = "literal", value = "A" } } }
  end
  local palette = { 255, 255, 255, 255 }
  local palettes = { stockName = palette, stockPrice = palette, balance = palette, description = palette }
  return {
    schema = MartAssetSchema.MANIFEST_SCHEMA,
    upper = {
      backgrounds = { items = visual("upper-items"), legacy = visual("upper-legacy") },
      description = { items = textBox(40, 144, 216, 48), legacy = textBox(8, 144, 216, 48) },
      itemAnchor = point(22, 172),
    },
    lower = {
      backgrounds = {
        browse = {
          [0] = visual("browse-0"),
          [1] = visual("browse-1"),
          [2] = visual("browse-2"),
          [3] = visual("browse-3"),
          [4] = visual("browse-4"),
          [5] = visual("browse-5"),
          [6] = visual("browse-6"),
        },
        quantity = visual("quantity"),
        confirm = visual("confirm"),
      },
      focus = {
        item = visual("focus-item"),
        cancel = visual("focus-cancel"),
      },
      slots = slots,
      pagePrevious = control(0, 168, 40, 24, "previous", 24, 176),
      pageNext = control(40, 168, 40, 24, "next", 64, 176),
      cancel = control(192, 168, 64, 24, "cancel", 224, 176),
      quantity = quantity,
      balance = {
        labelBox = textBox(8, 0, 72, 32),
        valueBox = textBox(8, 0, 72, 32, 0, 16, "right"),
      },
      cancelLabelBox = textBox(200, 168, 48, 16, 0, 0, "center"),
      pageBox = textBox(80, 168, 56, 16, 0, 0, "right"),
      messages = { short = textBox(16, 8, 216, 16), tall = textBox(16, 8, 216, 32), confirm = textBox(96, 8, 136, 32) },
      yesNo = { anchor = point(208, 48), shape = "compact", initialChoice = "yes" },
    },
    controls = controls,
    animations = {
      selectionEntry = clip("selection-entry", 24),
      increment = {
        playback = "once",
        frames = { { visual = visual("increment-pressed"), ticks = 2 }, { visual = visual("increment-idle"), ticks = 1 } },
        totalTicks = 3,
      },
      decrement = {
        playback = "once",
        frames = { { visual = visual("decrement-pressed"), ticks = 2 }, { visual = visual("decrement-idle"), ticks = 1 } },
        totalTicks = 3,
      },
    },
    feedback = { selectedTicks = 4, restoredTicks = 2, dispatchTicks = 1 },
    text = { palettes = palettes, labels = { currency = "Money" }, templates = templates },
  }
end

return { manifest = manifest }
