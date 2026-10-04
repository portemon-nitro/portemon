-- Strict mart schema and family-readiness tests over synthetic generated data.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MartAssetSchema = require("libs.assets.src.MartAssetSchema")
local MartCache = require("libs.assets.src.MartCache")

local T = {}

local MESSAGE_ROLES = {
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
}

local function visual(name)
  return {
    image = MartCache.assetDir() .. "/" .. name .. ".png",
    width = 8,
    height = 8,
    offsetX = 0,
    offsetY = 0,
  }
end

local function textBox()
  return {
    x = 0,
    y = 0,
    width = 8,
    height = 8,
    fontId = 0,
    textX = 0,
    textY = 0,
    alignment = "left",
    paletteRole = "foreground",
  }
end

local function control(normal, selected)
  return {
    anchor = { x = 0, y = 0 },
    hitbox = { x = 0, y = 0, width = 8, height = 8 },
    normalVisualKey = normal,
    selectedVisualKey = selected or normal,
  }
end

local function catalog()
  local normalTiers = {}
  for index = 1, 19 do
    normalTiers[index] = { itemKey = "ITEM_" .. index, minimumTier = 1 }
  end
  local function stocks(count)
    local result = {}
    for index = 1, count do
      result[index] = {}
    end
    return result
  end
  local cards = {}
  for ownershipIndex = 0, 26 do
    local itemKey = "DATA_CARD_" .. ownershipIndex
    cards[itemKey] = { itemKey = itemKey, ownershipIndex = ownershipIndex }
  end
  return {
    schema = MartCache.CATALOG_SCHEMA,
    normalTiers = normalTiers,
    specialStocks = stocks(30),
    athleteStocks = stocks(14),
    dataCardStocks = stocks(5),
    sealStocks = stocks(7),
    decorationStocks = stocks(2),
    cards = cards,
    apricorns = { RED_APRICORN = "red" },
    seals = {},
    decorations = {},
  }
end

local function manifest()
  local controls = {}
  for _, name in ipairs({ "pagePrevious", "pageNext", "cancel", "increment", "decrement", "confirm", "quantityCancel" }) do
    controls[name] = { normal = visual(name .. "-normal"), selected = visual(name .. "-selected") }
  end
  local slots = {}
  for index = 1, 6 do
    slots[index] = {
      hitbox = { x = 0, y = 0, width = 8, height = 8 },
      iconAnchor = { x = 0, y = 0 },
      labelBox = textBox(),
      priceAt = { x = 0, y = 0 },
      focusAnchor = { x = 0, y = 0 },
    }
  end
  local browse = {}
  for count = 0, 6 do
    browse[count] = visual("browse-" .. count)
  end
  local templates = {}
  for _, role in ipairs(MESSAGE_ROLES) do
    templates[role] = { parts = {} }
  end
  return {
    schema = MartCache.SCHEMA,
    upper = {
      backgrounds = { items = visual("upper-items"), legacy = visual("upper-legacy") },
      description = { items = textBox(), legacy = textBox() },
      itemAnchor = { x = 0, y = 0 },
    },
    lower = {
      backgrounds = { browse = browse, quantity = visual("quantity"), confirm = visual("confirm") },
      slots = slots,
      pagePrevious = control("pagePrevious"),
      pageNext = control("pageNext"),
      cancel = control("cancel"),
      quantity = {
        selectedItemAnchor = { x = 0, y = 0 },
        itemBox = textBox(),
        owned = { labelBox = textBox(), valueBox = textBox() },
        totalBox = textBox(),
        digitBoxes = { textBox(), textBox() },
        buyLabelBox = textBox(),
        increment10 = control("increment"),
        increment1 = control("increment"),
        decrement10 = control("decrement"),
        decrement1 = control("decrement"),
        confirm = control("confirm"),
        cancel = control("quantityCancel"),
      },
      balance = { labelBox = textBox(), valueBox = textBox() },
      cancelLabelBox = textBox(),
      pageBox = textBox(),
      messages = { short = textBox(), tall = textBox(), confirm = textBox() },
      yesNo = { anchor = { x = 0, y = 0 }, shape = "compact", initialChoice = "yes" },
    },
    controls = controls,
    animations = {
      selectionEntry = { playback = "once", frames = { { visual = visual("selection"), ticks = 6 } }, totalTicks = 6 },
      increment = { playback = "once", frames = { { visual = visual("increment"), ticks = 1 } }, totalTicks = 1 },
      decrement = { playback = "once", frames = { { visual = visual("decrement"), ticks = 1 } }, totalTicks = 1 },
    },
    feedback = { selectedTicks = 4, restoredTicks = 2, dispatchTicks = 1 },
    text = {
      palettes = { foreground = { 255, 255, 255, 255 } },
      labels = { buy = "Buy" },
      templates = templates,
    },
  }
end

local function clone(value)
  if type(value) ~= "table" then
    return value
  end
  local copied = {}
  for key, child in pairs(value) do
    copied[key] = clone(child)
  end
  return copied
end

local function readyCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local romSha1, dependencyHash = string.rep("a", 40), string.rep("b", 40)
  local expectedMarker = MartCache.marker(romSha1, dependencyHash)
  local presentation = manifest()
  for _, path in ipairs(MartCache.referencedPaths(presentation)) do
    cache:write(path, "image bytes")
  end
  cache:writeLua(MartCache.catalogPath(), catalog())
  cache:writeLua(MartCache.manifestPath(), presentation)
  cache:writeLua(MartCache.provenancePath(), {
    cacheFormat = MartCache.FORMAT,
    catalogSchema = MartCache.CATALOG_SCHEMA,
    schema = MartCache.SCHEMA,
    versionRomSha1 = romSha1,
    source = {},
    dependencies = {},
    dependencyHash = dependencyHash,
  })
  cache:write(MartCache.markerPath(), expectedMarker)
  return cache, expectedMarker, presentation
end

function T.manifest_requires_zero_based_browse_counts_and_rejects_unknown_counts()
  local valid = manifest()
  Assert.isTrue(MartAssetSchema.assertManifest(valid))

  local oneBased = clone(valid)
  for count = 0, 6 do
    oneBased.lower.backgrounds.browse[count + 1] = oneBased.lower.backgrounds.browse[count]
    oneBased.lower.backgrounds.browse[count] = nil
  end
  Assert.isFalse(MartAssetSchema.isValidManifest(oneBased), "browse variants use count keys 0 through 6")

  local extraCount = clone(valid)
  extraCount.lower.backgrounds.browse[7] = visual("unknown-count")
  Assert.isFalse(MartAssetSchema.isValidManifest(extraCount), "browse variants reject counts outside 0 through 6")
end

function T.manifest_requires_separate_source_text_boxes()
  local oldShape = manifest()
  oldShape.lower.balanceBox = oldShape.lower.balance.valueBox
  oldShape.lower.balance = nil
  oldShape.lower.quantity.ownedBox = textBox()
  oldShape.lower.quantity.owned = nil
  Assert.isFalse(MartAssetSchema.isValidManifest(oldShape), "the superseded single-box shape is rejected")

  local missingBalanceLabel = manifest()
  missingBalanceLabel.lower.balance.labelBox = nil
  Assert.isFalse(MartAssetSchema.isValidManifest(missingBalanceLabel), "balance requires its label baseline")

  local missingOwnedValue = manifest()
  missingOwnedValue.lower.quantity.owned.valueBox = nil
  Assert.isFalse(MartAssetSchema.isValidManifest(missingOwnedValue), "owned count requires its value baseline")

  local missingCancelLabel = manifest()
  missingCancelLabel.lower.cancelLabelBox = nil
  Assert.isFalse(MartAssetSchema.isValidManifest(missingCancelLabel), "browse Cancel text has its own box")

  local missingBuyLabel = manifest()
  missingBuyLabel.lower.quantity.buyLabelBox = nil
  Assert.isFalse(MartAssetSchema.isValidManifest(missingBuyLabel), "quantity BUY text has its own box")
end

function T.cache_readiness_requires_matching_provenance_and_every_referenced_image()
  local cache, marker, presentation = readyCache()
  Assert.isTrue(MartCache.isReady(cache, marker), "complete normalized family is ready")

  local paths = MartCache.referencedPaths(presentation)
  Assert.isTrue(#paths > 0, "manifest owns referenced images")
  cache:remove(paths[1])
  Assert.isFalse(MartCache.isReady(cache, marker), "a missing referenced image makes the family cold")
  cache:write(paths[1], "image bytes")
  Assert.isTrue(MartCache.isReady(cache, marker), "restoring the image restores readiness")

  local provenance = cache:loadLua(MartCache.provenancePath())
  provenance.dependencyHash = string.rep("c", 40)
  cache:writeLua(MartCache.provenancePath(), provenance)
  Assert.isFalse(MartCache.isReady(cache, marker), "provenance must identify the expected marker")
end

return { tests = T }
