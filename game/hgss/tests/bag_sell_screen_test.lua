-- The existing Bag owns source-shaped selling, including its commit boundary.

local Assert = require("tests.support.Assert")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local BagSave = require("libs.hgss.src.save.BagSave")
local BagScreenState = require("game.hgss.src.field.BagScreenState")
local BagPresentationFixture = require("tests.support.BagPresentationFixture")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local ItemFixture = require("libs.items.tests.item_fixture")
local MartSave = require("libs.hgss.src.save.MartSave")
local MartService = require("libs.hgss.src.items.MartService")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function textBox()
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

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function visual(path)
  return { image = path, width = 32, height = 24 }
end

local function template(text)
  return { segments = { { kind = "text", value = text }, { kind = "item" } } }
end

local function manifest()
  local result = BagPresentationFixture.manifest()
  result.schema = "g4-bag-assets-v17"
  result.interactive.sale = {
    pressTicks = result.interactive.overlays.quantity.pressTicks,
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
    money = textBox(),
    total = textBox(),
    compactPrompt = { x = 200, y = 48, shape = "compact", initialSelection = "yes" },
    messages = {
      notSellable = template("Cannot sell "),
      quantity = template("How many? "),
      offer = template("Sell for? "),
      result = template("Sold "),
    },
  }
  return result
end

local function composition(quantity, effect)
  local itemRoot = ItemFixture.buildAssetRoot()
  itemRoot.items.POTION.price = 301
  local itemCatalog = ItemCatalog.new(itemRoot)
  local bag = HgssBagService.new({ catalog = itemCatalog, bag = BagSave.empty() })
  Assert.isTrue(bag:add("POTION", quantity), "the real Bag accepts the sale fixture")
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
    id = "bag-sale",
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
    monCatalog = {
      moveByNativeId = function()
        error("move lookup is outside this Bag journey", 0)
      end,
    },
    heroGender = "male",
    textPolicy = { interGlyphDelay = 2, glyphBudget = 1, abAcceleration = true },
    measureDisplay = function()
      return {
        width = 512,
        height = 384,
        topology = topology,
        pixelRatio = 1,
        signature = "bag-sale-screen:512x384",
      }
    end,
    effect = effect or function(_) end,
  })
  return { bag = bag, profile = profile, saleSession = saleSession, state = state }
end

local function step(state, event)
  state:updateFixed(event and { { type = event } } or {})
end


local function waitFor(state, predicate, message, limit)
  for _ = 1, limit or 512 do
    local status = state:status()
    if predicate(status) then
      return status
    end
    Assert.isNil(state:takeResult(), message .. " keeps the Bag child open")
    step(state)
  end
  error(message .. " was not reached", 2)
end

function T.result_print_commits_once_acknowledges_and_returns_to_the_open_bag()
  local resources = composition(1)
  local state = resources.state
  local ok, failure = xpcall(function()
    waitFor(state, function(status)
      return status.phase == "interactive"
    end, "Bag opening", 32)
    Assert.equal(state:status().state, "browsing", "the sale child opens on the existing Bag")

    step(state, "confirm")
    waitFor(state, function(status)
      return status.state == "sale_offer"
    end, "single-item offer", 512)
    Assert.equal(resources.bag:quantity("POTION"), 1, "opening the offer does not remove the item")
    Assert.equal(resources.profile.money, 0, "opening the offer does not credit money")

    step(state, "confirm")
    local resultPrint = waitFor(state, function(status)
      return status.state == "sale_result"
    end, "sale result printing", 512)
    Assert.isTrue(resultPrint.open, "the Bag remains open while the sale result prints")
    Assert.equal(resources.bag:quantity("POTION"), 1, "the result text precedes Bag mutation")
    Assert.equal(resources.profile.money, 0, "the result text precedes the wallet credit")

    waitFor(state, function(status)
      return status.state == "sale_ack"
    end, "fresh sale acknowledgement", 512)
    Assert.equal(resources.bag:quantity("POTION"), 0, "printer completion commits one sold item")
    Assert.equal(resources.profile.money, 150, "resale value truncates 301 to 150")
    Assert.isNil(state:takeResult(), "a completed sale is not a child close result")

    step(state, "confirm")
    waitFor(state, function(status)
      return status.state == "browsing"
    end, "Bag browse resumption", 512)
    Assert.equal(resources.bag:quantity("POTION"), 0, "acknowledgement cannot replay the sale")
    Assert.equal(resources.profile.money, 150, "acknowledgement cannot credit twice")
    Assert.isNil(state:takeResult(), "the Bag stays open for another sale")

    step(state, "dismiss")
    Assert.deepEqual(state:takeResult(), { kind = "close" }, "only dismissal closes the Bag child")
    Assert.isNil(state:takeResult(), "the Bag close result is one-shot")
  end, debug.traceback)

  state:dispose()
  resources.saleSession:close()
  if not ok then
    error(failure, 0)
  end
end

function T.dismiss_during_sale_result_printing_closes_before_mutation()
  local resources = composition(1)
  local state = resources.state
  local ok, failure = xpcall(function()
    waitFor(state, function(status)
      return status.phase == "interactive"
    end, "Bag opening", 32)
    step(state, "confirm")
    waitFor(state, function(status)
      return status.state == "sale_offer"
    end, "single-item offer", 512)
    step(state, "confirm")
    waitFor(state, function(status)
      return status.state == "sale_result"
    end, "sale result printing", 32)

    step(state, "dismiss")
    Assert.deepEqual(state:takeResult(), { kind = "close" }, "dismissal closes the Bag during the result print")
    Assert.equal(resources.bag:quantity("POTION"), 1, "a dismissed result never commits its staged item removal")
    Assert.equal(resources.profile.money, 0, "a dismissed result never credits its staged quote")
  end, debug.traceback)

  state:dispose()
  resources.saleSession:close()
  if not ok then
    error(failure, 0)
  end
end

function T.sound_failure_resumes_postcommit_without_replaying_the_sale()
  local soundCalls = 0
  local saleCueArmed = false
  local resources = composition(1, function(sequence)
    if saleCueArmed and sequence == "SEQ_SE_DP_SELECT" then
      soundCalls = soundCalls + 1
      error("injected sale sound failure", 0)
    end
  end)
  local state = resources.state
  local ok, failure = xpcall(function()
    waitFor(state, function(status)
      return status.phase == "interactive"
    end, "Bag opening", 32)
    step(state, "confirm")
    waitFor(state, function(status)
      return status.state == "sale_offer"
    end, "single-item offer", 512)
    saleCueArmed = true
    step(state, "confirm")

    local completed, thrown = pcall(function()
      waitFor(state, function(status)
        return status.state == "sale_ack"
      end, "committed sale acknowledgement", 512)
    end)
    Assert.isFalse(completed, "the injected sound failure reaches the caller")
    Assert.isTrue(string.find(tostring(thrown), "injected sale sound failure", 1, true) ~= nil, "the sound error is preserved")
    Assert.equal(resources.bag:quantity("POTION"), 0, "the successful sale commit happens before its sound")
    Assert.equal(resources.profile.money, 150, "the wallet is credited once before its sound")
    Assert.equal(soundCalls, 1, "the sale cue is attempted once")

    waitFor(state, function(status)
      return status.state == "sale_ack"
    end, "resumed committed sale acknowledgement", 8)
    Assert.equal(resources.bag:quantity("POTION"), 0, "resumption does not replay inventory removal")
    Assert.equal(resources.profile.money, 150, "resumption does not replay the credit")
    Assert.equal(soundCalls, 1, "resumption does not replay the sale cue")
  end, debug.traceback)

  state:dispose()
  resources.saleSession:close()
  if not ok then
    error(failure, 0)
  end
end

return { tests = T }
