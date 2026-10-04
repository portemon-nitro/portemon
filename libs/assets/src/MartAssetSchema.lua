-- Authoritative validation for the generated mart catalog and presentation
-- contract. The schema contains only normalized runtime meaning: source
-- indices and raw tile/OAM data remain producer-side.

local SchemaCheck = require("libs.assets.src.SchemaCheck")
local Validate = require("libs.assets.src.Validate")
local Contract = require("libs.assets.src.DerivedAssetContract")

---@class MartAssetSchema
local MartAssetSchema = {}

MartAssetSchema.CATALOG_SCHEMA = Contract.mart.catalogSchema
MartAssetSchema.MANIFEST_SCHEMA = Contract.mart.schema

local CATALOG_ERROR = "MART_CATALOG_INVALID"
local MANIFEST_ERROR = "MART_MANIFEST_INVALID"
local fail = SchemaCheck.fail

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
local MESSAGE_ROLE_SET = {}
for _, role in ipairs(MESSAGE_ROLES) do
  MESSAGE_ROLE_SET[role] = true
end

local function keys(value, allowed, code, what)
  if type(value) ~= "table" then
    fail(code, what .. " must be a record", {})
  end
  SchemaCheck.checkKeys(value, allowed, {}, code, what)
end

local function stringValue(value, code, what, allowEmpty)
  if type(value) ~= "string" or (not allowEmpty and value == "") then
    fail(code, what .. " must be " .. (allowEmpty and "text" or "a non-empty string"), {})
  end
end

local function integer(value, code, what, minimum, maximum)
  SchemaCheck.checkInteger(value, {}, code, what, minimum, maximum)
end

local function array(value, code, what, count)
  if not Validate.isArray(value) or (count ~= nil and #value ~= count) then
    fail(
      code,
      what .. (count and (" must contain exactly " .. count .. " entries") or " must be a contiguous array"),
      {}
    )
  end
end

local function semanticMap(value, code, what, checkValue)
  if type(value) ~= "table" then
    fail(code, what .. " must be a record", {})
  end
  for key, entry in pairs(value) do
    stringValue(key, code, what .. " key")
    checkValue(entry, key)
  end
end

local function checkPrice(value, code, what)
  keys(value, { kind = true, value = true }, code, what)
  if value.kind == "catalog" then
    if value.value ~= nil then
      fail(code, what .. " catalog price carries no fixed value", {})
    end
  elseif value.kind == "fixed" then
    integer(value.value, code, what .. ".value", 0)
  else
    fail(code, what .. ".kind must be catalog or fixed", {})
  end
end

local function checkStockList(value, code, what)
  array(value, code, what)
  for index, entry in ipairs(value) do
    local entryWhat = what .. "[" .. index .. "]"
    keys(entry, { subjectKey = true, price = true }, code, entryWhat)
    stringValue(entry.subjectKey, code, entryWhat .. ".subjectKey")
    checkPrice(entry.price, code, entryWhat .. ".price")
  end
end

local function checkSubjectMap(value, code, what, checkEntry)
  semanticMap(value, code, what, function(entry, key)
    checkEntry(entry, what .. "." .. key)
  end)
end

function MartAssetSchema.assertCatalog(catalog)
  local context = {}
  if type(catalog) ~= "table" then
    fail(CATALOG_ERROR, "catalog must be a record", context)
  end
  SchemaCheck.checkKeys(catalog, {
    schema = true,
    normalTiers = true,
    specialStocks = true,
    athleteStocks = true,
    dataCardStocks = true,
    sealStocks = true,
    decorationStocks = true,
    cards = true,
    apricorns = true,
    seals = true,
    decorations = true,
  }, context, CATALOG_ERROR, "catalog")
  if catalog.schema ~= MartAssetSchema.CATALOG_SCHEMA then
    fail(CATALOG_ERROR, "catalog schema is not current", context)
  end

  array(catalog.normalTiers, CATALOG_ERROR, "normalTiers", 19)
  local tierKeys = {}
  for index, tier in ipairs(catalog.normalTiers) do
    local what = "normalTiers[" .. index .. "]"
    keys(tier, { itemKey = true, minimumTier = true }, CATALOG_ERROR, what)
    stringValue(tier.itemKey, CATALOG_ERROR, what .. ".itemKey")
    integer(tier.minimumTier, CATALOG_ERROR, what .. ".minimumTier", 1, 6)
    if tierKeys[tier.itemKey] then
      fail(CATALOG_ERROR, "normalTiers item keys must be unique", context)
    end
    tierKeys[tier.itemKey] = true
  end
  for _, role in ipairs({ "specialStocks", "athleteStocks", "dataCardStocks", "sealStocks", "decorationStocks" }) do
    local count = role == "specialStocks" and 30
      or role == "athleteStocks" and 14
      or role == "dataCardStocks" and 5
      or role == "sealStocks" and 7
      or 2
    local stocks = catalog[role]
    array(stocks, CATALOG_ERROR, role, count)
    for index, stock in ipairs(stocks) do
      checkStockList(stock, CATALOG_ERROR, role .. "[" .. index .. "]")
    end
  end

  local cardIndices = {}
  checkSubjectMap(catalog.cards, CATALOG_ERROR, "cards", function(card, what)
    keys(card, { itemKey = true, ownershipIndex = true }, CATALOG_ERROR, what)
    stringValue(card.itemKey, CATALOG_ERROR, what .. ".itemKey")
    integer(card.ownershipIndex, CATALOG_ERROR, what .. ".ownershipIndex", 0, 26)
    if cardIndices[card.ownershipIndex] then
      fail(CATALOG_ERROR, "card ownershipIndex values must be unique", context)
    end
    cardIndices[card.ownershipIndex] = true
  end)
  for index = 0, 26 do
    if not cardIndices[index] then
      fail(CATALOG_ERROR, "cards must cover ownership indices 0..26", context)
    end
  end
  checkSubjectMap(catalog.apricorns, CATALOG_ERROR, "apricorns", function(key, what)
    stringValue(key, CATALOG_ERROR, what)
  end)
  checkSubjectMap(catalog.seals, CATALOG_ERROR, "seals", function(seal, what)
    keys(seal, { displayItemKey = true, description = true }, CATALOG_ERROR, what)
    stringValue(seal.displayItemKey, CATALOG_ERROR, what .. ".displayItemKey")
    stringValue(seal.description, CATALOG_ERROR, what .. ".description", true)
  end)
  checkSubjectMap(catalog.decorations, CATALOG_ERROR, "decorations", function(decoration, what)
    keys(decoration, { displayItemKey = true, description = true }, CATALOG_ERROR, what)
    stringValue(decoration.displayItemKey, CATALOG_ERROR, what .. ".displayItemKey")
    stringValue(decoration.description, CATALOG_ERROR, what .. ".description", true)
  end)
  return true
end

local function checkPoint(value, code, what)
  keys(value, { x = true, y = true }, code, what)
  for _, axis in ipairs({ "x", "y" }) do
    integer(value[axis], code, what .. "." .. axis, 0)
  end
end

local function checkRect(value, code, what)
  keys(value, { x = true, y = true, width = true, height = true }, code, what)
  integer(value.x, code, what .. ".x", 0)
  integer(value.y, code, what .. ".y", 0)
  integer(value.width, code, what .. ".width", 1)
  integer(value.height, code, what .. ".height", 1)
end

local function checkTextBox(value, code, what)
  keys(value, {
    x = true,
    y = true,
    width = true,
    height = true,
    fontId = true,
    textX = true,
    textY = true,
    alignment = true,
    paletteRole = true,
  }, code, what)
  for _, field in ipairs({ "x", "y", "width", "height", "fontId", "textX", "textY" }) do
    integer(value[field], code, what .. "." .. field, 0)
  end
  if value.width == 0 or value.height == 0 then
    fail(code, what .. " must have positive dimensions", {})
  end
  if value.alignment ~= "left" and value.alignment ~= "center" and value.alignment ~= "right" then
    fail(code, what .. ".alignment must be left, center or right", {})
  end
  stringValue(value.paletteRole, code, what .. ".paletteRole")
end

local function checkVisual(value, code, what)
  keys(value, { image = true, width = true, height = true, offsetX = true, offsetY = true }, code, what)
  stringValue(value.image, code, what .. ".image")
  integer(value.width, code, what .. ".width", 1)
  integer(value.height, code, what .. ".height", 1)
  integer(value.offsetX, code, what .. ".offsetX")
  integer(value.offsetY, code, what .. ".offsetY")
end

local function checkControl(value, code, what)
  keys(value, { anchor = true, hitbox = true, normalVisualKey = true, selectedVisualKey = true }, code, what)
  checkPoint(value.anchor, code, what .. ".anchor")
  checkRect(value.hitbox, code, what .. ".hitbox")
  stringValue(value.normalVisualKey, code, what .. ".normalVisualKey")
  stringValue(value.selectedVisualKey, code, what .. ".selectedVisualKey")
end

local function checkControlReferences(value, controls, code, what)
  for _, field in ipairs({ "normalVisualKey", "selectedVisualKey" }) do
    if controls[value[field]] == nil then
      fail(code, what .. "." .. field .. " has no control visual pair", {})
    end
  end
end

local function checkClip(value, code, what)
  keys(value, { playback = true, frames = true, totalTicks = true }, code, what)
  if value.playback ~= "once" and value.playback ~= "loop" then
    fail(code, what .. ".playback must be once or loop", {})
  end
  array(value.frames, code, what .. ".frames")
  if #value.frames == 0 then
    fail(code, what .. ".frames must not be empty", {})
  end
  local total = 0
  for index, frame in ipairs(value.frames) do
    local frameWhat = what .. ".frames[" .. index .. "]"
    keys(frame, { visual = true, ticks = true }, code, frameWhat)
    checkVisual(frame.visual, code, frameWhat .. ".visual")
    integer(frame.ticks, code, frameWhat .. ".ticks", 1)
    total = total + frame.ticks
  end
  integer(value.totalTicks, code, what .. ".totalTicks", 1)
  if value.totalTicks ~= total then
    fail(code, what .. ".totalTicks must equal the sum of frame ticks", {})
  end
end

local function checkMessageProgram(value, code, what)
  keys(value, { parts = true }, code, what)
  array(value.parts, code, what .. ".parts")
  for index, part in ipairs(value.parts) do
    local partWhat = what .. ".parts[" .. index .. "]"
    if type(part) ~= "table" then
      fail(code, partWhat .. " must be a record", {})
    end
    if part.kind == "literal" then
      keys(part, { kind = true, value = true }, code, partWhat)
      stringValue(part.value, code, partWhat .. ".value", true)
    elseif part.kind == "binding" then
      keys(part, { kind = true, name = true }, code, partWhat)
      stringValue(part.name, code, partWhat .. ".name")
    elseif part.kind == "line" or part.kind == "clear" or part.kind == "scroll" then
      keys(part, { kind = true }, code, partWhat)
    elseif part.kind == "callback" then
      keys(part, { kind = true, name = true }, code, partWhat)
      if part.name ~= "transaction_received" then
        fail(code, partWhat .. ".name must be transaction_received", {})
      end
    else
      fail(code, partWhat .. " has an unknown kind", {})
    end
  end
end

function MartAssetSchema.assertManifest(manifest)
  local context = {}
  if type(manifest) ~= "table" then
    fail(MANIFEST_ERROR, "manifest must be a record", context)
  end
  SchemaCheck.checkKeys(manifest, {
    schema = true,
    upper = true,
    lower = true,
    controls = true,
    animations = true,
    feedback = true,
    text = true,
  }, context, MANIFEST_ERROR, "manifest")
  if manifest.schema ~= MartAssetSchema.MANIFEST_SCHEMA then
    fail(MANIFEST_ERROR, "manifest schema is not current", context)
  end

  local upper = manifest.upper
  keys(upper, { backgrounds = true, description = true, itemAnchor = true }, MANIFEST_ERROR, "upper")
  keys(upper.backgrounds, { items = true, legacy = true }, MANIFEST_ERROR, "upper.backgrounds")
  checkVisual(upper.backgrounds.items, MANIFEST_ERROR, "upper.backgrounds.items")
  checkVisual(upper.backgrounds.legacy, MANIFEST_ERROR, "upper.backgrounds.legacy")
  keys(upper.description, { items = true, legacy = true }, MANIFEST_ERROR, "upper.description")
  checkTextBox(upper.description.items, MANIFEST_ERROR, "upper.description.items")
  checkTextBox(upper.description.legacy, MANIFEST_ERROR, "upper.description.legacy")
  checkPoint(upper.itemAnchor, MANIFEST_ERROR, "upper.itemAnchor")

  local lower = manifest.lower
  keys(lower, {
    backgrounds = true,
    focus = true,
    slots = true,
    pagePrevious = true,
    pageNext = true,
    cancel = true,
    cancelLabelBox = true,
    quantity = true,
    balance = true,
    pageBox = true,
    messages = true,
    yesNo = true,
  }, MANIFEST_ERROR, "lower")
  keys(lower.backgrounds, { browse = true, quantity = true, confirm = true }, MANIFEST_ERROR, "lower.backgrounds")
  if type(lower.backgrounds.browse) ~= "table" then
    fail(MANIFEST_ERROR, "lower.backgrounds.browse must be a record", context)
  end
  for count = 0, 6 do
    checkVisual(lower.backgrounds.browse[count], MANIFEST_ERROR, "lower.backgrounds.browse[" .. count .. "]")
  end
  for count in pairs(lower.backgrounds.browse) do
    if type(count) ~= "number" or count % 1 ~= 0 or count < 0 or count > 6 then
      fail(MANIFEST_ERROR, "lower.backgrounds.browse contains an unknown count", { count = count })
    end
  end
  checkVisual(lower.backgrounds.quantity, MANIFEST_ERROR, "lower.backgrounds.quantity")
  checkVisual(lower.backgrounds.confirm, MANIFEST_ERROR, "lower.backgrounds.confirm")
  keys(lower.focus, { item = true, page = true, cancel = true }, MANIFEST_ERROR, "lower.focus")
  for _, name in ipairs({ "item", "page", "cancel" }) do
    checkVisual(lower.focus[name], MANIFEST_ERROR, "lower.focus." .. name)
  end
  if type(lower.slots) ~= "table" then
    fail(MANIFEST_ERROR, "lower.slots must be a record", context)
  end
  for slot = 1, 6 do
    local what = "lower.slots[" .. slot .. "]"
    local value = lower.slots[slot]
    keys(
      value,
      { hitbox = true, iconAnchor = true, labelBox = true, priceAt = true, focusAnchor = true },
      MANIFEST_ERROR,
      what
    )
    checkRect(value.hitbox, MANIFEST_ERROR, what .. ".hitbox")
    checkPoint(value.iconAnchor, MANIFEST_ERROR, what .. ".iconAnchor")
    checkTextBox(value.labelBox, MANIFEST_ERROR, what .. ".labelBox")
    checkPoint(value.priceAt, MANIFEST_ERROR, what .. ".priceAt")
    checkPoint(value.focusAnchor, MANIFEST_ERROR, what .. ".focusAnchor")
  end
  for key in pairs(lower.slots) do
    if type(key) ~= "number" or key < 1 or key > 6 or key % 1 ~= 0 then
      fail(MANIFEST_ERROR, "lower.slots must contain only slots 1..6", context)
    end
  end
  for slot = 1, 6 do
    if lower.slots[slot] == nil then
      fail(MANIFEST_ERROR, "lower.slots must contain slots 1..6", context)
    end
  end
  checkControl(lower.pagePrevious, MANIFEST_ERROR, "lower.pagePrevious")
  checkControl(lower.pageNext, MANIFEST_ERROR, "lower.pageNext")
  checkControl(lower.cancel, MANIFEST_ERROR, "lower.cancel")
  checkTextBox(lower.cancelLabelBox, MANIFEST_ERROR, "lower.cancelLabelBox")
  keys(lower.balance, { labelBox = true, valueBox = true }, MANIFEST_ERROR, "lower.balance")
  checkTextBox(lower.balance.labelBox, MANIFEST_ERROR, "lower.balance.labelBox")
  checkTextBox(lower.balance.valueBox, MANIFEST_ERROR, "lower.balance.valueBox")
  keys(lower.quantity, {
    selectedItemAnchor = true,
    itemBox = true,
    owned = true,
    totalBox = true,
    digitBoxes = true,
    buyLabelBox = true,
    increment10 = true,
    increment1 = true,
    decrement10 = true,
    decrement1 = true,
    confirm = true,
    cancel = true,
  }, MANIFEST_ERROR, "lower.quantity")
  checkPoint(lower.quantity.selectedItemAnchor, MANIFEST_ERROR, "lower.quantity.selectedItemAnchor")
  for _, field in ipairs({ "itemBox", "totalBox", "buyLabelBox" }) do
    checkTextBox(lower.quantity[field], MANIFEST_ERROR, "lower.quantity." .. field)
  end
  keys(lower.quantity.owned, { labelBox = true, valueBox = true }, MANIFEST_ERROR, "lower.quantity.owned")
  checkTextBox(lower.quantity.owned.labelBox, MANIFEST_ERROR, "lower.quantity.owned.labelBox")
  checkTextBox(lower.quantity.owned.valueBox, MANIFEST_ERROR, "lower.quantity.owned.valueBox")
  array(lower.quantity.digitBoxes, MANIFEST_ERROR, "lower.quantity.digitBoxes", 2)
  for index, box in ipairs(lower.quantity.digitBoxes) do
    checkTextBox(box, MANIFEST_ERROR, "lower.quantity.digitBoxes[" .. index .. "]")
  end
  for _, field in ipairs({ "increment10", "increment1", "decrement10", "decrement1", "confirm", "cancel" }) do
    checkControl(lower.quantity[field], MANIFEST_ERROR, "lower.quantity." .. field)
  end
  checkTextBox(lower.pageBox, MANIFEST_ERROR, "lower.pageBox")
  keys(lower.messages, { short = true, tall = true, confirm = true }, MANIFEST_ERROR, "lower.messages")
  for _, field in ipairs({ "short", "tall", "confirm" }) do
    checkTextBox(lower.messages[field], MANIFEST_ERROR, "lower.messages." .. field)
  end
  keys(lower.yesNo, { anchor = true, shape = true, initialChoice = true }, MANIFEST_ERROR, "lower.yesNo")
  checkPoint(lower.yesNo.anchor, MANIFEST_ERROR, "lower.yesNo.anchor")
  if lower.yesNo.shape ~= "compact" or lower.yesNo.initialChoice ~= "yes" then
    fail(MANIFEST_ERROR, "lower.yesNo must use compact shape and initially select yes", context)
  end

  if type(manifest.controls) ~= "table" then
    fail(MANIFEST_ERROR, "controls must be a record", context)
  end
  for name, pair in pairs(manifest.controls) do
    stringValue(name, MANIFEST_ERROR, "control name")
    keys(pair, { normal = true, selected = true }, MANIFEST_ERROR, "controls." .. name)
    checkVisual(pair.normal, MANIFEST_ERROR, "controls." .. name .. ".normal")
    checkVisual(pair.selected, MANIFEST_ERROR, "controls." .. name .. ".selected")
  end
  if next(manifest.controls) == nil then
    fail(MANIFEST_ERROR, "controls must include named normal/selected pairs", context)
  end
  for _, pair in ipairs({ lower.pagePrevious, lower.pageNext, lower.cancel }) do
    checkControlReferences(pair, manifest.controls, MANIFEST_ERROR, "lower control")
  end
  for _, name in ipairs({ "increment10", "increment1", "decrement10", "decrement1", "confirm", "cancel" }) do
    checkControlReferences(lower.quantity[name], manifest.controls, MANIFEST_ERROR, "lower.quantity." .. name)
  end
  keys(manifest.animations, { selectionEntry = true, increment = true, decrement = true }, MANIFEST_ERROR, "animations")
  for _, name in ipairs({ "selectionEntry", "increment", "decrement" }) do
    checkClip(manifest.animations[name], MANIFEST_ERROR, "animations." .. name)
  end
  keys(
    manifest.feedback,
    { selectedTicks = true, restoredTicks = true, dispatchTicks = true },
    MANIFEST_ERROR,
    "feedback"
  )
  for _, name in ipairs({ "selectedTicks", "restoredTicks", "dispatchTicks" }) do
    integer(manifest.feedback[name], MANIFEST_ERROR, "feedback." .. name, 1)
  end
  keys(manifest.text, { palettes = true, labels = true, templates = true }, MANIFEST_ERROR, "text")
  semanticMap(manifest.text.palettes, MANIFEST_ERROR, "text.palettes", function(color, what)
    array(color, MANIFEST_ERROR, what, 4)
    for channel = 1, 4 do
      integer(color[channel], MANIFEST_ERROR, what .. "[" .. channel .. "]", 0, 255)
    end
  end)
  semanticMap(manifest.text.labels, MANIFEST_ERROR, "text.labels", function(label, what)
    stringValue(label, MANIFEST_ERROR, what)
  end)
  semanticMap(manifest.text.templates, MANIFEST_ERROR, "text.templates", function(program, what)
    checkMessageProgram(program, MANIFEST_ERROR, what)
  end)
  for _, role in ipairs(MESSAGE_ROLES) do
    if manifest.text.templates[role] == nil then
      fail(MANIFEST_ERROR, "text.templates is missing required role " .. role, context)
    end
  end
  for role in pairs(manifest.text.templates) do
    if MESSAGE_ROLE_SET[role] ~= true then
      fail(MANIFEST_ERROR, "text.templates carries unknown role " .. tostring(role), context)
    end
  end
  return true
end

function MartAssetSchema.isValidCatalog(catalog)
  return pcall(MartAssetSchema.assertCatalog, catalog)
end

function MartAssetSchema.isValidManifest(manifest)
  return pcall(MartAssetSchema.assertManifest, manifest)
end

return MartAssetSchema
