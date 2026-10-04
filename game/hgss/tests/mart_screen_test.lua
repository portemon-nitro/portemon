-- A real MartScreenState purchase journey over a live MartService session.
-- This owns the child boundary directly; field-host/opcode routing belongs
-- to the later field composition.

local Assert = require("tests.support.Assert")
local BagSave = require("libs.hgss.src.save.BagSave")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local MartAssetSchema = require("libs.assets.src.MartAssetSchema")
local MartCache = require("libs.assets.src.MartCache")
local MartSave = require("libs.hgss.src.save.MartSave")
local MartService = require("libs.hgss.src.items.MartService")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

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

local function control(name)
  return {
    anchor = { x = 0, y = 0 },
    hitbox = { x = 0, y = 0, width = 8, height = 8 },
    normalVisualKey = name,
    selectedVisualKey = name .. "Selected",
  }
end

local function manifest()
  local controls = {}
  for _, name in ipairs({
    "pagePrevious",
    "pageNext",
    "cancel",
    "increment10",
    "increment1",
    "decrement10",
    "decrement1",
    "confirm",
    "quantityCancel",
  }) do
    controls[name] = { normal = visual(name), selected = visual(name .. "Selected") }
    controls[name .. "Selected"] = {
      normal = visual(name .. "SelectedNormal"),
      selected = visual(name .. "Selected"),
    }
  end

  local slots = {}
  for slot = 1, 6 do
    slots[slot] = {
      hitbox = { x = 0, y = 0, width = 8, height = 8 },
      iconAnchor = { x = 0, y = 0 },
      labelBox = textBox(),
      priceAt = { x = 0, y = 0 },
      focusAnchor = { x = 0, y = 0 },
    }
  end
  local templates = {}
  for _, role in ipairs(MESSAGE_ROLES) do
    templates[role] = { parts = { { kind = "literal", value = "A" } } }
  end
  local function clip(name)
    return {
      playback = "once",
      frames = { { visual = visual(name), ticks = 1 } },
      totalTicks = 1,
    }
  end
  local result = {
    schema = MartCache.SCHEMA,
    upper = {
      backgrounds = { items = visual("upper-items"), legacy = visual("upper-legacy") },
      description = { items = textBox(), legacy = textBox() },
      itemAnchor = { x = 0, y = 0 },
    },
    lower = {
      backgrounds = {
        browse = {},
        quantity = visual("quantity"),
        confirm = visual("confirm"),
      },
      focus = { item = visual("focus-item"), cancel = visual("focus-cancel") },
      slots = slots,
      pagePrevious = control("pagePrevious"),
      pageNext = control("pageNext"),
      cancel = control("cancel"),
      cancelLabelBox = textBox(),
      quantity = {
        selectedItemAnchor = { x = 0, y = 0 },
        itemBox = textBox(),
        owned = { labelBox = textBox(), valueBox = textBox() },
        totalBox = textBox(),
        digitBoxes = { textBox(), textBox() },
        buyLabelBox = textBox(),
        increment10 = control("increment10"),
        increment1 = control("increment1"),
        decrement10 = control("decrement10"),
        decrement1 = control("decrement1"),
        confirm = control("confirm"),
        cancel = control("quantityCancel"),
      },
      balance = { labelBox = textBox(), valueBox = textBox() },
      pageBox = textBox(),
      messages = { short = textBox(), tall = textBox(), confirm = textBox() },
      yesNo = { anchor = { x = 0, y = 0 }, shape = "compact", initialChoice = "yes" },
    },
    controls = controls,
    animations = { selectionEntry = clip("selection"), increment = clip("increment"), decrement = clip("decrement") },
    feedback = { selectedTicks = 1, restoredTicks = 1, dispatchTicks = 1 },
    text = { palettes = { foreground = { 0, 0, 0, 255 } }, labels = { buyLabel = "Buy" }, templates = templates },
  }
  for count = 0, 6 do
    result.lower.backgrounds.browse[count] = visual("browse-" .. count)
  end
  MartAssetSchema.assertManifest(result)
  return result
end

local function serviceFixture()
  local itemCatalog = ItemFixture.makeCatalog()
  local bag = HgssBagService.new({ catalog = itemCatalog, bag = BagSave.empty() })
  local catalog = {
    cards = {},
    apricorns = { RED_APRICORN = "red" },
    seals = {},
    decorations = {},
  }
  for index = 0, 26 do
    local key = "CARD_" .. index
    catalog.cards[key] = { itemKey = key, ownershipIndex = index }
  end
  local profile = { money = 500, badges = 0, nationalDex = false }
  local service = MartService.new({
    profile = profile,
    bag = bag,
    itemCatalog = itemCatalog,
    catalog = catalog,
    bucket = MartSave.empty(),
  })
  local session = service:openBuy({
    key = "purchase-journey",
    currency = "money",
    presentationKind = "items",
    quantityMode = "multiple",
    bonusPolicy = "none",
    entries = {
      {
        key = "potion-offer",
        displayItemKey = "POTION",
        description = { kind = "item" },
        unitPrice = 25,
        destination = { kind = "bag", key = "POTION" },
      },
    },
  })
  return { bag = bag, profile = profile, service = service, session = session }
end

local function displayMeasurement(width, height)
  width, height = width or 256, height or 192
  local topology = ScreenTopology.oneDisplay({
    id = "interaction",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  })
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = 1,
    signature = "mart-screen-acceptance:" .. width .. "x" .. height,
  }
end

function T.live_resize_cancels_pointer_capture_and_disposal_is_idempotent()
  local loaded, MartScreenState = pcall(require, "game.hgss.src.mart.MartScreenState")
  Assert.isTrue(loaded, "the purchase screen lifecycle is required")

  local resources = serviceFixture()
  local width, height = 256, 192
  local state = MartScreenState.new({
    session = resources.session,
    manifest = manifest(),
    uiManifest = FieldUiFixture.manifest(),
    fontDef = FieldDialogueFixture.fontDef(),
    textPolicy = { interGlyphDelay = 2, glyphBudget = 1, abAcceleration = true },
    effect = function(_) end,
    measureDisplay = function()
      return displayMeasurement(width, height)
    end,
    frameIndex = 0,
  })

  Assert.equal(state:status().state, "browse", "the purchase child begins open")
  state:step({ { type = "pointer_down", pointerId = "mart-touch", x = 4, y = 4 } })
  width = 512
  state:refreshPresentation()
  local resized = state:status()
  Assert.equal(#resized.presentation.panes, 2, "the live wide display publishes both mart panes")
  state:step({ { type = "pointer_up", pointerId = "mart-touch", x = 4, y = 4 } })
  Assert.equal(state:status().state, "browse", "a pre-resize touch release cannot activate the selected offer")
  Assert.isNil(state:takeResult(), "a stale release does not close the purchase child")

  state:step({ { type = "pointer_down", pointerId = "mart-cancel", x = 4, y = 4 } })
  state:cancelPointerCapture()
  state:step({ { type = "pointer_up", pointerId = "mart-cancel", x = 4, y = 4 } })
  Assert.equal(state:status().state, "browse", "explicit capture cancellation discards its matching release")
  Assert.isNil(state:takeResult(), "capture cancellation has no transaction result")

  state:dispose()
  state:dispose()
  resources.session:close()
end

local function advanceUntil(state, label, expectedState, limit)
  for _ = 1, limit or 400 do
    local status = state:status()
    if status.state == expectedState then
      return status
    end
    Assert.isNil(state:takeResult(), label .. " must keep the child open")
    local printerActive =
      status.state == "quantity_prompt"
      or status.state == "confirm_prompt"
      or status.state == "success_print"
      or status.state == "bonus_print"
      or status.state == "error_print"
    state:step(printerActive and { { type = "confirm" } } or {})
  end
  error(label .. " did not reach " .. expectedState, 2)
end

function T.real_screen_and_session_commit_only_after_success_printing()
  local loaded, MartScreenState = pcall(require, "game.hgss.src.mart.MartScreenState")
  Assert.isTrue(loaded, "the purchase child is required for the customer flow")

  local resources = serviceFixture()
  local state = MartScreenState.new({
    session = resources.session,
    manifest = manifest(),
    uiManifest = FieldUiFixture.manifest(),
    fontDef = FieldDialogueFixture.fontDef(),
    textPolicy = { interGlyphDelay = 2, glyphBudget = 1, abAcceleration = true },
    effect = function(_) end,
    measureDisplay = displayMeasurement,
    frameIndex = 0,
  })

  local ok, failure = xpcall(function()
    Assert.equal(state:status().state, "browse", "the child opens in browse")
    state:step({ { type = "confirm" } })
    advanceUntil(state, "selection entry", "quantity", 400)
    Assert.equal(resources.profile.money, 500, "selection and quantity prompt do not spend money")
    Assert.equal(resources.bag:quantity("POTION"), 0, "selection and quantity prompt do not mutate Bag")

    state:step({ { type = "confirm" } })
    advanceUntil(state, "quantity confirmation", "confirm", 400)
    Assert.equal(resources.profile.money, 500, "staging confirmation does not spend money")

    state:step({ { type = "confirm" } })
    advanceUntil(state, "Yes/No prompt", "confirm", 400)
    state:step({ { type = "confirm" } })
    local printing = advanceUntil(state, "success printing", "success_print", 400)
    Assert.equal(printing.state, "success_print")
    Assert.equal(resources.profile.money, 500, "choosing Yes does not commit before success text finishes")
    Assert.equal(resources.bag:quantity("POTION"), 0, "success text owns the pre-commit boundary")

    advanceUntil(state, "success print completion", "success_ack", 400)
    Assert.equal(resources.profile.money, 475, "print completion commits the quoted price once")
    Assert.equal(resources.bag:quantity("POTION"), 1, "print completion delivers exactly one item")
    Assert.isNil(state:takeResult(), "receipt acknowledgement is a child state, not field completion")

    state:step({ { type = "confirm" } })
    advanceUntil(state, "receipt acknowledgement", "browse", 400)
    Assert.equal(resources.profile.money, 475, "acknowledgement does not charge again")
    Assert.equal(resources.bag:quantity("POTION"), 1, "acknowledgement does not deliver again")
    Assert.isNil(state:takeResult(), "the purchase child remains open for another purchase")
  end, debug.traceback)

  state:dispose()
  resources.session:close()
  if not ok then
    error(failure, 0)
  end
end

return { tests = T }
