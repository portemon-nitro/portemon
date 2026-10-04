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

local function textBox(x, y, width, height)
  return {
    x = x,
    y = y,
    width = width,
    height = height,
    fontId = 0,
    textX = 0,
    textY = 0,
    alignment = "left",
    paletteRole = "foreground",
  }
end

local function control(x, y, width, height, key)
  return {
    anchor = point(x, y),
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
  local slots = {}
  for index = 1, 6 do
    local x = index % 2 == 1 and 0 or 128
    local y = 32 + math.floor((index - 1) / 2) * 42
    slots[index] = {
      hitbox = rect(x, y, 128, 42),
      iconAnchor = point(x + 22, y + 24),
      labelBox = textBox(x + 32, y + 8, 88, 32),
      priceAt = point(x + 68, y + 24),
      focusAnchor = point(x + 48, y + 24),
    }
  end
  local quantity = {
    selectedItemAnchor = point(86, 76),
    itemBox = textBox(96, 56, 88, 32),
    ownedBox = textBox(8, 104, 64, 40),
    totalBox = textBox(184, 112, 64, 24),
    digitBoxes = { textBox(128, 112, 16, 24), textBox(160, 112, 16, 24) },
    increment10 = control(120, 88, 32, 24, "inc10"),
    increment1 = control(152, 88, 32, 24, "inc1"),
    decrement10 = control(120, 136, 32, 24, "dec10"),
    decrement1 = control(152, 136, 32, 24, "dec1"),
    confirm = control(96, 168, 78, 24, "buy"),
    cancel = control(178, 168, 78, 24, "quantity-cancel"),
  }
  local templates = {}
  for _, role in ipairs({
    "insufficientMoney", "quantityPrompt", "moneyConfirm", "itemReceived", "noRoom", "cancelLabel",
    "moneyPrice", "pointsPrice", "premierBonus", "sealReceived", "sealFull", "boughtToday",
    "alreadyOwned", "moneyLabel", "moneyBalance", "pointsBalance", "pointsLabel", "ownedLabel",
    "ownedCount", "quantityTotal", "buyLabel", "pageNumber", "tensDigit", "unitsDigit",
    "pointsConfirm", "insufficientPoints", "pointsReceived",
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
        browse = { [0] = visual("browse-0"), [1] = visual("browse-1"), [2] = visual("browse-2"), [3] = visual("browse-3"), [4] = visual("browse-4"), [5] = visual("browse-5"), [6] = visual("browse-6") },
        quantity = visual("quantity"),
        confirm = visual("confirm"),
      },
      slots = slots,
      pagePrevious = control(0, 168, 40, 24, "previous"),
      pageNext = control(40, 168, 40, 24, "next"),
      cancel = control(192, 168, 64, 24, "cancel"),
      quantity = quantity,
      balanceBox = textBox(8, 0, 72, 32),
      pageBox = textBox(80, 168, 56, 16),
      messages = { short = textBox(16, 8, 216, 16), tall = textBox(16, 8, 216, 32), confirm = textBox(96, 8, 136, 32) },
      yesNo = { anchor = point(208, 48), shape = "compact", initialChoice = "yes" },
    },
    controls = controls,
    animations = { selectionEntry = clip("selection-entry", 24), increment = clip("increment", 1), decrement = clip("decrement", 1) },
    feedback = { selectedTicks = 4, restoredTicks = 2, dispatchTicks = 1 },
    text = { palettes = palettes, labels = { currency = "Money" }, templates = templates },
  }
end


return { manifest = manifest }
