-- Purchase controller behavior over a real MartService session. Manifest and
-- text are synthetic; transaction state and captures remain production-owned.

local Assert = require("tests.support.Assert")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local ItemFixture = require("libs.items.tests.item_fixture")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local BagSave = require("libs.hgss.src.save.BagSave")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local MartService = require("libs.hgss.src.items.MartService")
local MartSave = require("libs.hgss.src.save.MartSave")
local MartController = require("libs.hgss.src.ui.MartController")

local T = {}

local MartFixture = require("tests.support.MartFixture")
local manifest = MartFixture.manifest
local quantityController

local function resources(balance, potionName, medicinePocketName)
  local root = ItemFixture.buildAssetRoot()
  root.items.POTION.price = 100
  if potionName ~= nil then
    root.items.POTION.name = potionName
  end
  if medicinePocketName ~= nil then
    root.pocketNames.medicine = medicinePocketName
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
  return {
    key = "controller-test",
    currency = "money",
    presentationKind = "items",
    quantityMode = "multiple",
    bonusPolicy = "none",
    entries = result,
  }
end

local function newController(session, martManifest, effect)
  local fontDef = FieldDialogueFixture.fontDef()
  for _, character in ipairs({ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "/" }) do
    fontDef.charmap[character] = 1
  end
  return MartController.new({
    session = session,
    manifest = martManifest or manifest(),
    promptShape = {
      width = 48,
      height = 32,
      yes = { normal = {}, selected = {} },
      no = { normal = {}, selected = {} },
    },
    fontDef = fontDef,
    continueCursor = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9 },
    textPolicy = { interGlyphDelay = 0, glyphBudget = 512, abAcceleration = true },
    effect = effect or function() end,
  })
end

local function tokenText(tokens)
  return FieldMessageText.tokensToText(tokens)
end

local function clearEffects(effects)
  for index = #effects, 1, -1 do
    effects[index] = nil
  end
end

local function tap(control, x, y)
  control:step({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  control:step({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
end

local function advanceControlFeedbackToRelease(controller, martManifest)
  local ticks = martManifest.feedback.dispatchTicks
    + martManifest.feedback.selectedTicks
    + martManifest.feedback.restoredTicks
  for _ = 1, ticks do
    controller:step({})
  end
  Assert.equal(
    controller:status().controlFeedback.phase,
    "release",
    "generic feedback retains its final dispatch boundary"
  )
end

local function finishControlFeedback(controller, martManifest)
  advanceControlFeedbackToRelease(controller, martManifest)
  for _ = 1, martManifest.feedback.dispatchTicks do
    controller:step({})
  end
  Assert.isNil(controller:status().controlFeedback, "generic control feedback releases its pending action")
end

function T.partial_pages_keep_source_focus_and_empty_activation_is_inert()
  local service = resources()
  local session = service:openBuy(stock(10, 7))
  local controller = newController(session)
  Assert.equal(controller:status().page, 0)
  Assert.equal(controller:status().pageCount, 2)
  tap(controller, 52, 176)
  finishControlFeedback(controller, manifest())
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

function T.status_consumes_the_named_source_bindings_for_numeric_and_page_roles()
  local service = resources(1000)
  local session = service:openBuy(stock(10, 7))
  local martManifest = manifest()
  local function bind(role, name)
    martManifest.text.templates[role].parts = { { kind = "binding", name = name } }
  end
  bind("moneyPrice", "price")
  bind("moneyBalance", "balance")
  bind("ownedCount", "owned")
  bind("quantityTotal", "total")
  bind("moneyConfirm", "total")
  martManifest.text.templates.pageNumber.parts = {
    { kind = "binding", name = "currentPage" },
    { kind = "literal", value = "/" },
    { kind = "binding", name = "pageCount" },
  }
  local controller = newController(session, martManifest)
  local status = controller:status()

  Assert.equal(tokenText(status.entries[1].priceTokens), "100", "price binds the unit price")
  Assert.equal(tokenText(status.balanceTokens), "1000", "balance binds the current balance")
  Assert.equal(tokenText(status.ownedTokens), "0", "owned count binds the current owned quantity")
  Assert.equal(tokenText(status.totalTokens), "100", "quantity total binds the initial total")
  Assert.equal(tokenText(status.pageTokens), "1/2", "page number binds current and total pages")

  local controllerForQuote = newController(session, martManifest)
  controllerForQuote:step({ { type = "navigate", direction = "right" } })
  controllerForQuote:step({ { type = "confirm" } })
  for _ = 1, 24 do
    controllerForQuote:step({})
  end
  for _ = 1, 20 do
    if controllerForQuote:status().state == "quantity" then
      break
    end
    controllerForQuote:step({ { type = "confirm" } })
  end
  Assert.equal(controllerForQuote:status().state, "quantity")
  controllerForQuote:step({ { type = "navigate", direction = "up" } })
  controllerForQuote:step({ { type = "navigate", direction = "up" } })
  controllerForQuote:step({ { type = "confirm" } })
  for _ = 1, 20 do
    if controllerForQuote:status().state == "confirm" then
      break
    end
    controllerForQuote:step({ { type = "confirm" } })
  end
  local quote = controllerForQuote:status()
  Assert.equal(quote.state, "confirm", "quantity three reaches money confirmation")
  Assert.equal(quote.total, 300, "three items at 100 each total 300")
  Assert.equal(tokenText(quote.messageLines[1].tokens), "300", "money confirmation binds the total")
  controllerForQuote:dispose()

  controller:dispose()
  session:close()
end

function T.item_received_message_binds_item_and_pocket_separately()
  local service = resources(nil, "A", "B")
  local session = service:openBuy(stock(10, 1))
  local martManifest = manifest()
  martManifest.text.templates.itemReceived.parts = {
    { kind = "binding", name = "item" },
    { kind = "literal", value = " " },
    { kind = "binding", name = "pocket" },
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
  controller:step({ { type = "confirm" } })
  for _ = 1, 20 do
    controller:step({})
  end
  local received = controller:status()
  Assert.equal(received.messageRole, "itemReceived")
  Assert.equal(
    tokenText(received.messageLines[1].tokens or received.messageLines[1]),
    "A B",
    "item and pocket have separate named bindings"
  )
  controller:dispose()
  session:close()
end

function T.touch_targets_use_inclusive_origins_and_exclusive_ends()
  local service = resources()
  local session = service:openBuy(stock(10, 7))
  local controller = newController(session)

  tap(controller, 0, 32)
  Assert.equal(controller:status().state, "selection_feedback", "browse hitbox includes its left/top origin")
  controller:dispose()
  session:close()

  service = resources()
  session = service:openBuy(stock(10, 7))
  controller = newController(session)
  tap(controller, 128, 118)
  Assert.equal(controller:status().selection, 5, "browse right edge belongs to the adjacent source slot")
  controller:dispose()
  session:close()

  service = resources()
  session = service:openBuy(stock(10, 7))
  controller = newController(session)
  tap(controller, 0, 154)
  Assert.equal(controller:status().selection, 0, "browse bottom edge is excluded from the source slot")

  tap(controller, 40, 168)
  Assert.equal(controller:status().page, 0, "page next hit starts feedback without publishing the page")
  finishControlFeedback(controller, manifest())
  Assert.equal(controller:status().page, 1, "page next includes its left/top origin")
  tap(controller, 80, 192)
  Assert.equal(controller:status().page, 1, "page next excludes its right/bottom end")
  tap(controller, 0, 168)
  finishControlFeedback(controller, manifest())
  Assert.equal(controller:status().page, 0, "page previous includes its left/top origin")

  controller:step({ { type = "navigate", direction = "right" } })
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
  tap(controller, 152, 88)
  Assert.equal(controller:status().quantity, 2, "quantity control includes its left/top origin")
  tap(controller, 184, 112)
  Assert.equal(controller:status().quantity, 2, "quantity control excludes its right/bottom end")
  controller:dispose()
  session:close()
end

function T.keyboard_browse_actions_emit_the_exact_source_cue_sequence()
  local service = resources()
  local session = service:openBuy(stock(10, 7))
  local effects = {}
  local controller = newController(session, nil, function(sequence)
    effects[#effects + 1] = sequence
  end)

  controller:step({ { type = "navigate", direction = "right" } })
  Assert.deepEqual(effects, { "SEQ_SE_DP_SELECT" }, "a focus move emits one selection cue")
  clearEffects(effects)
  controller:step({ { type = "confirm" } })
  Assert.deepEqual(effects, { "SEQ_SE_DP_SELECT" }, "keyboard item activation emits one selection cue")
  controller:dispose()
  session:close()
end

function T.touch_browse_actions_emit_the_exact_source_cue_sequence()
  local service = resources()
  local session = service:openBuy(stock(10, 7))
  local effects = {}
  local controller = newController(session, nil, function(sequence)
    effects[#effects + 1] = sequence
  end)

  tap(controller, 52, 55)
  Assert.deepEqual(effects, { "SEQ_SE_DP_SELECT" }, "touch capture and activation emit one selection cue total")
  controller:dispose()
  session:close()
end

function T.touch_page_activation_emits_one_selection_cue()
  local service = resources()
  local session = service:openBuy(stock(10, 7))
  local effects = {}
  local controller = newController(session, nil, function(sequence)
    effects[#effects + 1] = sequence
  end)
  tap(controller, 52, 176)
  Assert.deepEqual(effects, { "SEQ_SE_DP_SELECT" }, "a valid touch page action emits one selection cue")
  Assert.equal(controller:status().page, 0, "page publication waits after the initiating cue")
  finishControlFeedback(controller, manifest())
  Assert.equal(controller:status().page, 1)
  controller:dispose()
  session:close()
end

function T.keyboard_page_previous_and_next_each_emit_one_selection_cue()
  local service = resources()
  local session = service:openBuy(stock(10, 7))
  local effects = {}
  local controller = newController(session, nil, function(sequence)
    effects[#effects + 1] = sequence
  end)
  controller:step({ { type = "navigate", direction = "right" } })
  clearEffects(effects)
  controller:step({ { type = "navigate", direction = "right" } })
  Assert.equal(controller:status().page, 0, "keyboard page next remains pending during feedback")
  Assert.deepEqual(effects, { "SEQ_SE_DP_SELECT" }, "keyboard page next emits exactly one selection cue")
  finishControlFeedback(controller, manifest())
  Assert.equal(controller:status().page, 1)
  controller:dispose()
  session:close()

  service = resources()
  session = service:openBuy(stock(10, 7))
  effects = {}
  controller = newController(session, nil, function(sequence)
    effects[#effects + 1] = sequence
  end)
  tap(controller, 52, 176)
  finishControlFeedback(controller, manifest())
  clearEffects(effects)
  controller:step({ { type = "navigate", direction = "left" } })
  Assert.equal(controller:status().page, 1, "keyboard page previous remains pending during feedback")
  Assert.deepEqual(effects, { "SEQ_SE_DP_SELECT" }, "keyboard page previous emits exactly one selection cue")
  finishControlFeedback(controller, manifest())
  Assert.equal(controller:status().page, 0)
  controller:dispose()
  session:close()
end

function T.page_publication_waits_for_both_dispatch_boundaries()
  local service = resources()
  local session = service:openBuy(stock(10, 7))
  local martManifest = manifest()
  local effects = {}
  local controller = newController(session, martManifest, function(sequence)
    effects[#effects + 1] = sequence
  end)

  controller:step({ { type = "navigate", direction = "right" } })
  clearEffects(effects)
  controller:step({ { type = "navigate", direction = "right" } })
  Assert.equal(controller:status().page, 0, "page next stays pending after its source cue")
  Assert.deepEqual(effects, { "SEQ_SE_DP_SELECT" })
  local feedback = controller:status().controlFeedback
  Assert.equal(feedback.key, "pageNext")
  Assert.equal(feedback.phase, "dispatch")

  controller:step({ { type = "navigate", direction = "left" } })
  Assert.equal(controller:status().controlFeedback.phase, "selected", "the first gate step exposes selected feedback")
  for _ = 2, martManifest.feedback.selectedTicks do
    controller:step({ { type = "confirm" } })
    Assert.equal(controller:status().page, 0, "ordinary input cannot publish another action during selection")
    Assert.equal(controller:status().controlFeedback.phase, "selected")
  end
  controller:step({ { type = "cancel" } })
  Assert.equal(controller:status().controlFeedback.phase, "restored", "selected duration comes from the manifest")
  for _ = 2, martManifest.feedback.restoredTicks do
    controller:step({ { type = "navigate", direction = "right" } })
    Assert.equal(controller:status().controlFeedback.phase, "restored")
  end
  Assert.equal(controller:status().page, 0, "the pending page action remains unpublished through restored feedback")
  controller:step({ { type = "confirm" } })
  Assert.equal(
    controller:status().controlFeedback.phase,
    "release",
    "restored feedback enters the final task-state dispatch boundary"
  )
  Assert.equal(controller:status().page, 0, "the pending action remains unpublished during release")
  Assert.deepEqual(effects, { "SEQ_SE_DP_SELECT" }, "ignored input produces no extra cues during release")
  controller:step({ { type = "cancel" } })
  Assert.isNil(controller:status().controlFeedback)
  Assert.equal(controller:status().page, 1, "the pending page action publishes exactly after the gate")
  Assert.deepEqual(effects, { "SEQ_SE_DP_SELECT" }, "ignored input produces no extra cues")

  controller:dispose()
  session:close()
end

function T.browse_close_and_quantity_decisions_share_the_deferred_feedback_gate()
  local service = resources()
  local session = service:openBuy(stock(10, 7))
  local effects = {}
  local controller = newController(session, nil, function(sequence)
    effects[#effects + 1] = sequence
  end)
  tap(controller, 224, 176)
  Assert.isTrue(controller:status().open, "browse Cancel keeps the mart open until feedback completes")
  Assert.isNil(controller:takeResult(), "browse close is not released early")
  Assert.deepEqual(effects, { "SEQ_SE_GS_GEARCANCEL" })
  advanceControlFeedbackToRelease(controller, manifest())
  Assert.isTrue(controller:status().open, "browse Cancel remains pending through release")
  Assert.isNil(controller:takeResult(), "browse close has no result during release")
  controller:step({})
  Assert.isFalse(controller:status().open)
  Assert.equal(controller:takeResult().kind, "close")
  controller:dispose()
  session:close()

  effects = {}
  controller, session = quantityController(effects)
  controller:step({ { type = "confirm" } })
  Assert.equal(controller:status().state, "quantity", "quantity confirmation waits before opening the quote prompt")
  Assert.deepEqual(effects, { "SEQ_SE_DP_SELECT" })
  advanceControlFeedbackToRelease(controller, manifest())
  Assert.equal(controller:status().state, "quantity", "quantity quote remains pending through release")
  controller:step({})
  Assert.isFalse(controller:status().state == "quantity", "quantity confirmation releases after feedback")
  controller:dispose()
  session:close()

  effects = {}
  controller, session = quantityController(effects)
  controller:step({ { type = "cancel" } })
  Assert.equal(controller:status().state, "quantity", "quantity Cancel waits before returning to browse")
  Assert.deepEqual(effects, { "SEQ_SE_GS_GEARCANCEL" })
  advanceControlFeedbackToRelease(controller, manifest())
  Assert.equal(controller:status().state, "quantity", "quantity Cancel remains pending through release")
  controller:step({})
  Assert.equal(controller:status().state, "browse")
  Assert.equal(controller:status().lowerMode, "browse", "quantity message presentation is cleared on release")
  controller:dispose()
  session:close()
end

function T.touch_browse_cancel_emits_one_cancel_cue_without_a_focus_cue()
  local service = resources()
  local session = service:openBuy(stock(10, 7))
  local effects = {}
  local controller = newController(session, nil, function(sequence)
    effects[#effects + 1] = sequence
  end)
  tap(controller, 224, 176)
  Assert.deepEqual(effects, { "SEQ_SE_GS_GEARCANCEL" }, "touch browse cancel emits one cancel cue without a focus cue")
  controller:dispose()
  session:close()
end

quantityController = function(effects)
  local service = resources(3700)
  local session = service:openBuy(stock(37, 1))
  local controller = newController(session, nil, function(sequence)
    effects[#effects + 1] = sequence
  end)

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
  Assert.equal(controller:status().state, "quantity", "the production purchase flow reaches quantity selection")
  clearEffects(effects)
  return controller, session
end

function T.keyboard_quantity_actions_emit_only_their_source_cues()
  local effects = {}
  local controller, session = quantityController(effects)
  controller:step({ { type = "navigate", direction = "up" } })
  Assert.deepEqual(effects, { "SEQ_SE_DP_BAG_004" }, "an actual quantity change emits one bag-amount cue")
  Assert.deepEqual(controller:status().amountAnimations, {}, "keyboard unit changes do not animate touch controls")
  clearEffects(effects)
  controller:step({ { type = "navigate", direction = "right" } })
  Assert.deepEqual(effects, { "SEQ_SE_DP_BAG_004" }, "a ten-item keyboard change emits one bag-amount cue")
  Assert.deepEqual(controller:status().amountAnimations, {}, "keyboard ten changes do not animate touch controls")
  controller:dispose()
  session:close()
end

function T.touch_quantity_actions_emit_only_their_source_cues()
  local effects = {}
  local controller, session = quantityController(effects)
  tap(controller, 136, 100)
  Assert.deepEqual(effects, { "SEQ_SE_DP_BAG_004" }, "an actual touch quantity change emits one bag-amount cue")
  Assert.equal(controller:status().quantity, 11, "touch amount state changes immediately")
  Assert.equal(controller:status().amountAnimations.increment10.family, "increment")
  Assert.equal(controller:status().amountAnimations.increment10.frame, 1)
  Assert.isNil(controller:status().controlFeedback, "amount animation does not start the generic gate")
  controller:step({})
  Assert.equal(
    controller:status().amountAnimations.increment10.frame,
    1,
    "the generated pressed frame lasts its source duration"
  )
  controller:step({})
  Assert.equal(
    controller:status().amountAnimations.increment10.frame,
    2,
    "the generated clip advances to its idle frame"
  )
  controller:step({})
  Assert.isNil(controller:status().amountAnimations.increment10, "the amount clip disappears at totalTicks")
  controller:dispose()
  session:close()
end

function T.keyboard_quantity_confirmation_emits_one_selection_cue()
  local effects = {}
  local controller, session = quantityController(effects)
  controller:step({ { type = "confirm" } })
  Assert.deepEqual(effects, { "SEQ_SE_DP_SELECT" }, "quantity confirmation emits one selection cue")
  controller:dispose()
  session:close()
end

function T.yes_no_decisions_emit_only_the_prompt_owned_cue()
  local effects = {}
  local controller, session = quantityController(effects)
  controller:step({ { type = "confirm" } })
  for _ = 1, 20 do
    if controller:status().state == "confirm" then
      break
    end
    controller:step({ { type = "confirm" } })
  end
  Assert.equal(controller:status().state, "confirm")
  clearEffects(effects)
  controller:step({ { type = "confirm" } })
  Assert.deepEqual(effects, { "SEQ_SE_DP_BUTTON9" }, "Yes emits only the prompt-owned decision cue")
  controller:dispose()
  session:close()

  effects = {}
  controller, session = quantityController(effects)
  controller:step({ { type = "confirm" } })
  for _ = 1, 20 do
    if controller:status().state == "confirm" then
      break
    end
    controller:step({ { type = "confirm" } })
  end
  Assert.equal(controller:status().state, "confirm")
  controller:step({ { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().prompt.selected, "no")
  clearEffects(effects)
  controller:step({ { type = "confirm" } })
  Assert.deepEqual(effects, { "SEQ_SE_DP_BUTTON9" }, "No emits only the prompt-owned decision cue")
  controller:dispose()
  session:close()
end

function T.touch_quantity_confirmation_emits_one_selection_cue()
  local effects = {}
  local controller, session = quantityController(effects)
  tap(controller, 136, 176)
  Assert.deepEqual(effects, { "SEQ_SE_DP_SELECT" }, "touch quantity confirmation emits one selection cue")
  controller:dispose()
  session:close()
end

function T.keyboard_quantity_cancel_emits_one_cancel_cue()
  local effects = {}
  local controller, session = quantityController(effects)
  controller:step({ { type = "cancel" } })
  Assert.deepEqual(effects, { "SEQ_SE_GS_GEARCANCEL" }, "keyboard quantity cancel emits one cancel cue")
  controller:dispose()
  session:close()
end

function T.touch_quantity_cancel_emits_one_cancel_cue()
  local effects = {}
  local controller, session = quantityController(effects)
  tap(controller, 224, 176)
  Assert.deepEqual(effects, { "SEQ_SE_GS_GEARCANCEL" }, "touch quantity cancel emits one cancel cue")
  controller:dispose()
  session:close()
end

function T.inert_quantity_controls_and_status_reads_emit_no_cues()
  local effects = {}
  local service = resources(100)
  local session = service:openBuy(stock(1, 1))
  local controller = newController(session, nil, function(sequence)
    effects[#effects + 1] = sequence
  end)
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
  clearEffects(effects)
  controller:status()
  Assert.deepEqual(effects, {}, "status reads do not emit effects")
  tap(controller, 136, 100)
  Assert.deepEqual(effects, {}, "a disabled touch amount control is inert")
  Assert.deepEqual(controller:status().amountAnimations, {}, "an inert touch control starts no amount clip")
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
      Assert.equal(
        controller:status().quantity,
        math.min(maximum, 11),
        "keyboard ten-step increments without endpoint wrap"
      )
      for _ = 1, 20 do
        controller:step({ { type = "navigate", direction = "right" } })
      end
      Assert.equal(controller:status().quantity, maximum, "keyboard ten-step clamps at the maximum")
    end
    local before = controller:status().quantity
    tap(controller, 136, 100)
    if maximum >= 10 then
      Assert.equal(
        controller:status().quantity,
        before == maximum and 1 or math.min(maximum, before + 10),
        "touch ten-step control uses endpoint wrap"
      )
    else
      Assert.equal(controller:status().quantity, before, "disabled touch ten-step control is inert")
    end
    controller:dispose()
    session:close()
  end
end

local function watchedResources(balance, entryCount)
  local root = ItemFixture.buildAssetRoot()
  root.items.POTION.price = 100
  local items = ItemCatalog.new(root)
  local reads = { catalog = 0 }
  local rawItem = items.item
  items.item = function(self, key)
    reads.catalog = reads.catalog + 1
    return rawItem(self, key)
  end
  local bag = HgssBagService.new({ catalog = items, bag = BagSave.empty() })
  local profile = { money = balance or 1000, badges = 0, nationalDex = false }
  local service = MartService.new({
    profile = profile,
    bag = bag,
    itemCatalog = items,
    catalog = { cards = {}, apricorns = {}, seals = {}, decorations = {} },
    bucket = MartSave.empty(),
  })
  local session = service:openBuy(stock(10, entryCount or 7))
  reads.catalog = 0
  return { service = service, bag = bag, profile = profile, session = session, reads = reads }
end

function T.idle_status_and_selected_reads_reuse_the_session_projection()
  local state = watchedResources(1000, 7)
  local controller = newController(state.session)
  local first = controller:status()
  Assert.equal(first.entryCount, 7)
  Assert.equal(first.balance, 1000)
  local built = state.reads.catalog
  Assert.isTrue(built > 0, "the first status resolves catalog facts")

  controller:status()
  controller:status()
  Assert.equal(state.reads.catalog, built, "idle status reads do not reproject stock")

  local selected = controller:_entry()
  Assert.notNil(selected)
  Assert.equal(selected.entryKey, "offer-1")
  controller:_entry()
  Assert.equal(state.reads.catalog, built, "selected-entry reads do not rebuild all stock")
  controller:dispose()
  state.session:close()
end

function T.balance_bag_and_purchase_changes_refresh_controller_status()
  local state = watchedResources(1000, 2)
  local controller = newController(state.session)
  Assert.equal(controller:status().balance, 1000)
  Assert.equal(controller:status().entries[1].maxQuantity, 10)

  state.profile.money = 950
  local refreshed = controller:status()
  Assert.equal(refreshed.balance, 950, "a balance change alone refreshes the display")
  Assert.equal(refreshed.entries[1].maxQuantity, 9)

  Assert.isTrue(state.bag:add("POTION", 3))
  Assert.equal(controller:status().entries[1].ownedQuantity, 3, "a Bag change refreshes owned counts")

  local token = assert(state.session:quoteBuy("offer-1", 1))
  Assert.notNil(state.session:commit(token))
  local after = controller:status()
  Assert.equal(after.balance, 850)
  Assert.equal(after.entries[1].ownedQuantity, 4)

  state.profile.money = 50
  Assert.equal(controller:status().balance, 50)
  local retry, retryReason = state.session:quoteBuy("offer-1", 2)
  Assert.isNil(retry)
  Assert.equal(retryReason, "insufficient_money", "a stale affordable display cannot authorize a purchase")
  controller:dispose()
  state.session:close()
end

function T.mutated_status_cannot_reach_the_session_and_flows_close_cleanly()
  local state = watchedResources(1000, 7)
  local controller = newController(state.session)
  local status = controller:status()
  status.balance = 1
  status.entries[1].ownedQuantity = 77
  status.entries[1].bindings.itemName = "changed"
  status.entries[1].description = "changed"
  status.currentEntry.ownedQuantity = 77
  local fresh = controller:status()
  Assert.equal(fresh.balance, 1000, "mutated outputs cannot alter the retained projection")
  Assert.equal(fresh.entries[1].ownedQuantity, 0)
  Assert.equal(fresh.entries[1].bindings.itemName, "Potion")
  Assert.equal(fresh.description, "Potion description")
  Assert.equal(fresh.currentEntry.ownedQuantity, 0)

  local built = state.reads.catalog
  controller:step({ { type = "navigate", direction = "right" } })
  Assert.equal(controller:status().selection, 1)
  Assert.equal(state.reads.catalog, built, "presentation navigation needs no catalog work")
  controller:step({ { type = "navigate", direction = "left" } })

  controller:step({ { type = "confirm" } })
  for _ = 1, 60 do
    if controller:status().state == "quantity" then
      break
    end
    controller:step({ { type = "confirm" } })
  end
  Assert.equal(controller:status().state, "quantity", "the quantity flow progresses on schedule")
  controller:step({ { type = "cancel" } })
  finishControlFeedback(controller, manifest())
  Assert.equal(controller:status().state, "browse", "cancellation returns to browse")
  controller:dispose()
  controller:dispose()
  state.session:close()
end

return { tests = T }
