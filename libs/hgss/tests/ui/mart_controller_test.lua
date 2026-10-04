-- Purchase controller behavior over a real MartService session. Manifest and
-- text are synthetic; transaction state and captures remain production-owned.

local Assert = require("tests.support.Assert")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local ItemFixture = require("libs.items.tests.item_fixture")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local BagSave = require("libs.hgss.src.save.BagSave")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local MartService = require("libs.hgss.src.items.MartService")
local MartSave = require("libs.hgss.src.save.MartSave")
local MartController = require("libs.hgss.src.ui.MartController")

local T = {}

local MartFixture = require("tests.support.MartFixture")
local manifest = MartFixture.manifest

local function resources(balance, potionName)
  local root = ItemFixture.buildAssetRoot()
  root.items.POTION.price = 100
  if potionName ~= nil then
    root.items.POTION.name = potionName
  end
  local items = ItemCatalog.new(root)
  local bag = HgssBagService.new({ catalog = items, bag = BagSave.empty() })
  local service = MartService.new({
    profile = { money = balance or 1000, badges = 0, nationalDex = false },
    bag = bag,
    itemCatalog = items,
    catalog = { cards = {}, apricorns = {}, seals = {}, decorations = {} },
    bucket = MartSave.empty(),
  })
  return service, bag
end

local function stock(_, entries)
  local price = 100
  local result = {}
  for index = 1, entries do
    result[index] = {
      key = "offer-" .. index,
      displayItemKey = "POTION",
      description = { kind = "item" },
      unitPrice = price,
      destination = { kind = "bag", key = "POTION" },
      restriction = { kind = "none" },
    }
  end
  return { key = "controller-test", currency = "money", presentationKind = "items", quantityMode = "multiple", bonusPolicy = "none", entries = result }
end

local function newController(session, martManifest)
  return MartController.new({
    session = session,
    manifest = martManifest or manifest(),
    promptShape = {
      width = 48,
      height = 32,
      yes = { normal = {}, selected = {} },
      no = { normal = {}, selected = {} },
    },
    fontDef = FieldDialogueFixture.fontDef(),
    continueCursor = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9 },
    textPolicy = { interGlyphDelay = 0, glyphBudget = 512, abAcceleration = true },
    effect = function() end,
  })
end

local function tap(control, x, y)
  control:step({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  control:step({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
end

function T.partial_pages_keep_source_focus_and_empty_activation_is_inert()
  local service = resources()
  local session = service:openBuy(stock(10, 7))
  local controller = newController(session)
  Assert.equal(controller:status().page, 0)
  Assert.equal(controller:status().pageCount, 2)
  tap(controller, 52, 176)
  Assert.equal(controller:status().page, 1)
  Assert.equal(controller:status().selection, 0, "page navigation retains the selected logical cell")
  tap(controller, 132, 55)
  Assert.equal(controller:status().selection, 1, "the partial page permits focus on an empty logical cell")
  local capture = service:capture()
  controller:step({ { type = "confirm" } })
  Assert.deepEqual(service:capture(), capture, "an empty logical cell cannot create a quote")
  controller:dispose()
  session:close()
end

function T.populated_cell_keeps_the_source_selection_clip_gate()
  local service = resources()
  local session = service:openBuy(stock(10, 1))
  local controller = newController(session)
  controller:step({ { type = "confirm" } })
  Assert.equal(controller:status().state, "selection_feedback")
  for _ = 1, 23 do
    controller:step({ { type = "confirm" } })
    Assert.equal(controller:status().state, "selection_feedback", "held confirmation cannot bypass the source clip")
  end
  controller:step({})
  Assert.equal(controller:status().state, "quantity_prompt", "the 24-tick selection clip unlocks the quantity prompt")
  Assert.equal(service:capture().statistics.currencySpent, 0, "selection animation never commits a purchase")
  controller:dispose()
  session:close()
end

function T.quantity_prompt_maps_the_service_item_name_to_the_rom_item_binding()
  local service = resources(nil, "A")
  local session = service:openBuy(stock(10, 1))
  local martManifest = manifest()
  martManifest.text.templates.quantityPrompt.parts = { { kind = "binding", name = "item" } }
  local controller = newController(session, martManifest)

  controller:step({ { type = "confirm" } })
  for _ = 1, 24 do
    controller:step({})
  end

  Assert.equal(controller:status().state, "quantity_prompt", "the ROM prompt receives the service item's name")
  controller:dispose()
  session:close()
end

function T.purchase_result_preserves_the_source_printer_callback()
  local service = resources(nil, "A")
  local session = service:openBuy(stock(10, 1))
  local martManifest = manifest()
  martManifest.text.templates.itemReceived.parts = {
    { kind = "callback", name = "transaction_received" },
    { kind = "binding", name = "item" },
  }
  local controller = newController(session, martManifest)

  controller:step({ { type = "confirm" } })
  for _ = 1, 24 do
    controller:step({})
  end
  for _ = 1, 20 do
    if controller:status().state == "quantity" then
      break
    end
    controller:step({ { type = "confirm" } })
  end
  Assert.equal(controller:status().state, "quantity")
  controller:step({ { type = "confirm" } })
  for _ = 1, 20 do
    if controller:status().state == "confirm" then
      break
    end
    controller:step({ { type = "confirm" } })
  end
  Assert.equal(controller:status().state, "confirm")
  for _ = 1, 12 do
    controller:step({ { type = "confirm" } })
    if controller:status().state == "success_print" then
      break
    end
  end

  Assert.equal(controller:status().state, "success_print", "the transaction message opens with its source callback")
  controller:dispose()
  session:close()
end

function T.quantity_keyboard_and_touch_use_their_distinct_endpoint_rules()
  for _, maximum in ipairs({ 1, 9, 10, 37, 99 }) do
    local service = resources(maximum * 100)
    local session = service:openBuy(stock(maximum, 1))
    local controller = newController(session)
    controller:step({ { type = "confirm" } })
    for _ = 1, 24 do
      controller:step({})
    end
    Assert.equal(controller:status().state, "quantity_prompt")
    for _ = 1, 16 do
      if controller:status().state == "quantity" then
        break
      end
      controller:step({ { type = "confirm" } })
    end
    Assert.equal(controller:status().state, "quantity")
    Assert.equal(controller:status().quantity, 1)
    if maximum > 1 then
      controller:step({ { type = "navigate", direction = "up" } })
      Assert.equal(controller:status().quantity, 2, "keyboard unit step increments")
      controller:step({ { type = "navigate", direction = "down" } })
      Assert.equal(controller:status().quantity, 1, "keyboard unit step wraps at one")
      controller:step({ { type = "navigate", direction = "left" } })
      Assert.equal(controller:status().quantity, 1, "keyboard ten-step clamps at one")
      controller:step({ { type = "navigate", direction = "right" } })
      Assert.equal(controller:status().quantity, math.min(maximum, 11), "keyboard ten-step increments without endpoint wrap")
      for _ = 1, 20 do
        controller:step({ { type = "navigate", direction = "right" } })
      end
      Assert.equal(controller:status().quantity, maximum, "keyboard ten-step clamps at the maximum")
    end
    local before = controller:status().quantity
    tap(controller, 136, 100)
    if maximum >= 10 then
      Assert.equal(controller:status().quantity, before == maximum and 1 or math.min(maximum, before + 10), "touch ten-step control uses endpoint wrap")
    else
      Assert.equal(controller:status().quantity, before, "disabled touch ten-step control is inert")
    end
    controller:dispose()
    session:close()
  end
end

return { tests = T }
