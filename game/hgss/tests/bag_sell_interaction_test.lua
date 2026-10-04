-- The live Bag quantity/offer interaction is the only route to repeated sales.

local Assert = require("tests.support.Assert")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local BagSave = require("libs.hgss.src.save.BagSave")
local BagScreenState = require("game.hgss.src.field.BagScreenState")
local BagPresentationFixture = require("tests.support.BagPresentationFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local ItemFixture = require("libs.items.tests.item_fixture")
local MartSave = require("libs.hgss.src.save.MartSave")
local MartService = require("libs.hgss.src.items.MartService")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function box()
  return {
    x = 16,
    y = 8,
    width = 216,
    height = 16,
    fontId = 0,
    textX = 0,
    textY = 0,
    alignment = "left",
    paletteRole = "foreground",
  }
end

local function visual(path)
  return { image = path, width = 32, height = 24 }
end

local function message(value)
  return { segments = { { kind = "text", value = value }, { kind = "item" } } }
end

local function manifest()
  local result = BagPresentationFixture.manifest()
  result.schema = "g4-bag-assets-v17"
  result.interactive.sale = {
    pressTicks = 2,
    quantityBackground = visual("test/bag/sale-quantity.png"),
    digits = { rect(128, 112, 16, 24), rect(160, 112, 16, 24) },
    controls = {
      { delta = 10, role = "increment", center = { x = 136, y = 104 }, hitRect = rect(120, 88, 32, 24) },
      { delta = 1, role = "increment", center = { x = 168, y = 104 }, hitRect = rect(152, 88, 32, 24) },
      { delta = -10, role = "decrement", center = { x = 136, y = 152 }, hitRect = rect(120, 136, 32, 24) },
      { delta = -1, role = "decrement", center = { x = 168, y = 152 }, hitRect = rect(152, 136, 32, 24) },
    },
    confirm = {
      visual = visual("test/bag/sale-confirm.png"),
      center = { x = 136, y = 176 },
      hitRect = rect(96, 168, 78, 24),
      labelAt = { x = 117, y = 168 },
    },
    cancel = {
      visual = visual("test/bag/sale-cancel.png"),
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
    money = box(),
    total = box(),
    compactPrompt = { x = 200, y = 48, shape = "compact", initialSelection = "yes" },
    messages = {
      notSellable = message("Cannot sell "),
      quantity = message("How many? "),
      offer = message("Sell for? "),
      result = message("Sold "),
    },
  }
  return result
end

local function composition()
  local itemRoot = ItemFixture.buildAssetRoot()
  itemRoot.items.POTION.price = 301
  local itemCatalog = ItemCatalog.new(itemRoot)
  local bag = HgssBagService.new({ catalog = itemCatalog, bag = BagSave.empty() })
  Assert.isTrue(bag:add("POTION", 120), "the Bag fixture contains a stack beyond the sale limit")
  local profile = { money = 0, badges = 0, nationalDex = false }
  local service = MartService.new({
    profile = profile,
    bag = bag,
    itemCatalog = itemCatalog,
    catalog = { cards = {}, apricorns = {}, seals = {}, decorations = {} },
    bucket = MartSave.empty(),
  })
  local saleSession = service:openSell()
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local topology = ScreenTopology.oneDisplay({
    id = "bag-sale-interaction",
    rect = { x = 0, y = 0, width = 512, height = 384 },
    role = "world",
    touch = false,
  })
  local state = BagScreenState.new({
    service = bag,
    cursor = cursor,
    context = "sell",
    saleSession = saleSession,
    manifest = manifest(),
    uiManifest = FieldUiFixture.manifest(),
    monCatalog = { moveByNativeId = function() error("move lookup is outside this interaction", 0) end },
    heroGender = "male",
    textPolicy = { interGlyphDelay = 2, glyphBudget = 1, abAcceleration = true },
    measureDisplay = function()
      return {
        width = 512,
        height = 384,
        topology = topology,
        pixelRatio = 1,
        signature = "bag-sale-interaction:512x384",
      }
    end,
    effect = function(_) end,
  })
  return { bag = bag, profile = profile, saleSession = saleSession, state = state }
end

local function tick(state, event)
  state:updateFixed(event and { { type = event } } or {})
end

local function untilState(state, expected, limit)
  for _ = 1, limit or 512 do
    local status = state:status()
    if status.state == expected then
      return status
    end
    Assert.isNil(state:takeResult(), "the sale remains inside its Bag child")
    tick(state)
  end
  error("Bag sale did not reach " .. expected, 2)
end

local function untilMessageReady(state)
  for _ = 1, 512 do
    local status = state:status()
    if status.lowerMessage == nil then
      return status
    end
    Assert.isNil(state:takeResult(), "message printing keeps the Bag child open")
    tick(state)
  end
  error("sale message did not finish printing", 2)
end

local function untilOfferPrompt(state)
  for _ = 1, 512 do
    local status = state:status()
    if status.state == "sale_offer" and status.yesNoPrompt ~= nil then
      return status
    end
    Assert.isNil(state:takeResult(), "the sale offer remains inside the Bag child")
    tick(state)
  end
  error("sale offer prompt did not open", 2)
end

local function openSellContext(state)
  for _ = 1, 32 do
    if state:status().phase == "interactive" then
      break
    end
    tick(state)
  end
  Assert.equal(state:status().phase, "interactive", "the Bag completes its opening before accepting sale input")
  tick(state, "confirm")
  untilState(state, "sale_quantity")
  untilMessageReady(state)
end

local function chooseQuantity(state, amount)
  local status = state:status()
  Assert.equal(status.quantityMax, 99, "a large stack is capped at 99 sale units")
  local increments = math.ceil((amount - status.quantity) / 10)
  for _ = 1, increments do
    state:updateFixed({ { type = "navigate", direction = "right" } })
  end
  status = state:status()
  Assert.equal(status.quantity, amount, "the sale controls clamp the selected quantity")
  tick(state, "confirm")
  untilState(state, "sale_offer")
end

function T.sale_quantity_is_capped_cancellable_and_repeatable_in_one_bag_child()
  local resources = composition()
  local state = resources.state
  local ok, failure = xpcall(function()
    openSellContext(state)
    local quantityState = state:status()
    Assert.equal(quantityState.quantityMax, 99, "the 120-unit stack presents at most 99")
    Assert.equal(quantityState.quantity, 1, "a new sale starts at one item")
    Assert.equal(resources.bag:quantity("POTION"), 120, "opening the quantity prompt is read-only")
    Assert.equal(resources.profile.money, 0, "opening the quantity prompt leaves the wallet unchanged")

    tick(state, "cancel")
    untilState(state, "browsing")
    Assert.equal(resources.bag:quantity("POTION"), 120, "quantity cancellation preserves the whole stack")
    Assert.equal(resources.profile.money, 0, "quantity cancellation does not credit money")

    openSellContext(state)
    chooseQuantity(state, 99)
    Assert.equal(resources.bag:quantity("POTION"), 120, "staging the offer does not mutate the Bag")
    Assert.equal(resources.profile.money, 0, "staging the offer does not credit the wallet")

    untilOfferPrompt(state)
    tick(state, "cancel")
    untilState(state, "browsing")
    Assert.equal(resources.bag:quantity("POTION"), 120, "offer cancellation preserves the whole stack")
    Assert.equal(resources.profile.money, 0, "offer cancellation leaves the wallet unchanged")
    Assert.isNil(state:takeResult(), "cancelled offers do not close the Bag child")

    openSellContext(state)
    chooseQuantity(state, 99)
    untilOfferPrompt(state)
    tick(state, "confirm")
    untilState(state, "sale_result")
    untilState(state, "sale_ack")
    Assert.equal(resources.bag:quantity("POTION"), 21, "the confirmed sale removes the capped 99")
    Assert.equal(resources.profile.money, 14850, "99 units sell for 99 times the 150-unit price")
    Assert.isNil(state:takeResult(), "the first completed sale keeps the Bag open")

    tick(state, "confirm")
    untilState(state, "browsing")
    openSellContext(state)
    tick(state, "confirm")
    untilOfferPrompt(state)
    tick(state, "confirm")
    untilState(state, "sale_result")
    untilState(state, "sale_ack")
    Assert.equal(resources.bag:quantity("POTION"), 20, "a second sale runs in the same Bag child")
    Assert.equal(resources.profile.money, 15000, "the second sale credits once")
    Assert.isNil(state:takeResult(), "repeated sales do not return a child result")
  end, debug.traceback)

  state:dispose()
  resources.saleSession:close()
  if not ok then
    error(failure, 0)
  end
end

function T.stale_offer_is_refused_after_result_text_without_selling_or_closing_bag()
  local resources = composition()
  local state = resources.state
  local ok, failure = xpcall(function()
    openSellContext(state)
    chooseQuantity(state, 1)
    untilOfferPrompt(state)

    Assert.isTrue(resources.bag:add("POKE_BALL", 1), "an external inventory revision is published")
    Assert.equal(resources.bag:quantity("POTION"), 120, "the offered item remains until commit")
    Assert.equal(resources.bag:quantity("POKE_BALL"), 1, "the concurrent Bag mutation is visible")
    Assert.equal(resources.profile.money, 0, "the offer has not credited money")

    tick(state, "confirm")
    local result = untilState(state, "sale_result")
    Assert.isTrue(
      string.find(result.lowerMessage.fullText, "Sold", 1, true) ~= nil,
      "the success result begins printing before commit is attempted"
    )
    Assert.equal(resources.bag:quantity("POTION"), 120, "the result printer precedes Bag mutation")
    Assert.equal(resources.bag:quantity("POKE_BALL"), 1, "only the external mutation has changed inventory")
    Assert.equal(resources.profile.money, 0, "the displayed result has not credited the wallet")

    local reachedRefusal = false
    for _ = 1, 512 do
      tick(state)
      local status = state:status()
      Assert.equal(resources.bag:quantity("POTION"), 120, "printing a stale sale removes nothing")
      Assert.equal(resources.bag:quantity("POKE_BALL"), 1, "printing preserves the external Bag mutation")
      Assert.equal(resources.profile.money, 0, "printing a stale sale credits no money")
      if status.state == "sale_refusal" then
        reachedRefusal = true
        break
      end
      Assert.equal(status.state, "sale_result", "a stale quote cannot become a completed sale")
      Assert.isNil(state:takeResult(), "the stale result remains inside the Bag child")
    end
    Assert.isTrue(reachedRefusal, "finished stale result text is replaced with a refusal")
    local refusal = state:status()
    Assert.isTrue(
      string.find(refusal.lowerMessage.fullText, "Cannot sell", 1, true) ~= nil,
      "a stale quote replaces the success claim with a visible refusal"
    )
    Assert.equal(resources.bag:quantity("POTION"), 120, "the stale transaction removes no sale quantity")
    Assert.equal(resources.bag:quantity("POKE_BALL"), 1, "refusal preserves the external Bag mutation")
    Assert.equal(resources.profile.money, 0, "a stale quote never credits money")

    untilState(state, "sale_ack")
    Assert.isTrue(state:status().open, "the failure acknowledgement remains in the Bag child")
    Assert.equal(resources.bag:quantity("POTION"), 120, "failure acknowledgement cannot remove items")
    Assert.equal(resources.profile.money, 0, "failure acknowledgement cannot credit money")
    Assert.isNil(state:takeResult(), "a stale quote is not a completed sale or a Bag close")

    tick(state, "confirm")
    untilState(state, "browsing")
    Assert.equal(resources.bag:quantity("POTION"), 120, "the Bag resumes after acknowledging the refusal")
    Assert.equal(resources.profile.money, 0, "browsing after refusal preserves the wallet")
    Assert.isNil(state:takeResult(), "the field child remains open after stale-sale recovery")
  end, debug.traceback)

  state:dispose()
  resources.saleSession:close()
  if not ok then
    error(failure, 0)
  end
end

return { tests = T }
