-- Post-selection Bag behavior: sound effects, activation feedback latching,
-- typed toss confirmation/result gating with inherited bases, and delayed
-- move mutation. Each scenario below drives the controller through a retail
-- post-selection journey and asserts the observable state, effect, and
-- mutation boundaries the current immediate-transition controller lacks.

local Assert = require("tests.support.Assert")
local BagActionPolicy = require("libs.hgss.src.ui.BagActionPolicy")
local BagController = require("libs.hgss.src.ui.BagController")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local BagLayout = require("libs.hgss.src.ui.BagLayout")
local BagModel = require("libs.hgss.src.ui.BagModel")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local YesNoPromptController = require("libs.hgss.src.ui.YesNoPromptController")

local T = {}

local TAB_RECTS = {
  { x = 0, y = 0, width = 32, height = 32 },
  { x = 32, y = 0, width = 32, height = 32 },
  { x = 64, y = 0, width = 32, height = 32 },
  { x = 96, y = 0, width = 32, height = 32 },
  { x = 128, y = 0, width = 32, height = 32 },
  { x = 160, y = 0, width = 32, height = 32 },
  { x = 192, y = 0, width = 32, height = 32 },
  { x = 224, y = 0, width = 32, height = 32 },
}

local SLOT_SHAPES = {
  { rect = { x = 0, y = 32, width = 128, height = 42 }, center = { x = 48, y = 56 } },
  { rect = { x = 128, y = 32, width = 128, height = 42 }, center = { x = 176, y = 56 } },
  { rect = { x = 0, y = 74, width = 128, height = 44 }, center = { x = 48, y = 96 } },
  { rect = { x = 128, y = 74, width = 128, height = 44 }, center = { x = 176, y = 96 } },
  { rect = { x = 0, y = 118, width = 128, height = 36 }, center = { x = 48, y = 136 } },
  { rect = { x = 128, y = 118, width = 128, height = 36 }, center = { x = 176, y = 136 } },
}

local function manifest()
  local tabs = {}
  for index, rect in ipairs(TAB_RECTS) do
    tabs[index] = { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
  end
  local slots = {}
  for _, shape in ipairs(SLOT_SHAPES) do
    slots[#slots + 1] = {
      rect = { x = shape.rect.x, y = shape.rect.y, width = shape.rect.width, height = shape.rect.height },
      iconCenter = { x = shape.center.x, y = shape.center.y },
    }
  end
  return {
    interactive = {
      pocketTabs = { rects = tabs },
      itemSlots = { slots = slots },
      pageIndicator = { rect = { x = 80, y = 168, width = 56, height = 16 }, textAt = { x = 0, y = 0 } },
      cancel = {
        rect = { x = 192, y = 168, width = 64, height = 24 },
        textRect = { x = 192, y = 168, width = 56, height = 16 },
      },
      overlays = {
        descriptionFallback = {
          frame = { x = 0, y = 144, width = 256, height = 48 },
          textRect = { x = 20, y = 144, width = 236, height = 48 },
        },
        actionMenu = {
          slots = {
            { hitRect = { x = 8, y = 136, width = 80, height = 16 } },
            { hitRect = { x = 104, y = 136, width = 80, height = 16 } },
            { hitRect = { x = 8, y = 168, width = 80, height = 16 } },
            { hitRect = { x = 104, y = 168, width = 80, height = 16 } },
          },
        },
        quantity = {
          controls = {
            { delta = 100, role = "increment", hitRect = { x = 0, y = 128, width = 32, height = 32 } },
            { delta = 10, role = "increment", hitRect = { x = 32, y = 128, width = 32, height = 32 } },
            { delta = 1, role = "increment", hitRect = { x = 64, y = 128, width = 32, height = 32 } },
            { delta = -100, role = "decrement", hitRect = { x = 0, y = 160, width = 32, height = 32 } },
            { delta = -10, role = "decrement", hitRect = { x = 32, y = 160, width = 32, height = 32 } },
            { delta = -1, role = "decrement", hitRect = { x = 64, y = 160, width = 32, height = 32 } },
          },
          pressTicks = 2,
          cancelHitRect = { x = 178, y = 168, width = 78, height = 24 },
          confirm = { hitRect = { x = 112, y = 160, width = 64, height = 32 } },
        },
      },
    },
  }
end

local function service()
  return HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
end

local function promptShape()
  local visual = function()
    return {}
  end
  return {
    width = 48,
    height = 32,
    yes = { normal = visual(), selected = visual() },
    no = { normal = visual(), selected = visual() },
  }
end

local function tossPrompt()
  return { x = 200, y = 48, shape = "compact", initialSelection = "yes" }
end

local function textPolicy()
  return { interGlyphDelay = 2, glyphBudget = 2, abAcceleration = true }
end

-- Builds the controller with an effect spy plus a mid-speed text policy so
-- post-selection timing and sound boundaries are observable per tick.
local function controller(bag, cursor, effects)
  local layoutManifest = manifest()
  local function resolveLayout()
    return BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  end
  local control = BagController.new({
    model = {
      refresh = function()
        return BagModel.build(bag, cursor)
      end,
    },
    cursor = cursor,
    resolveLayout = resolveLayout,
    promptShape = promptShape(),
    tossPrompt = tossPrompt(),
    itemSelectTicks = 3,
    effect = function(sequence)
      effects[#effects + 1] = sequence
    end,
    textPolicy = textPolicy(),
    commands = {
      toss = function(itemKey, quantity)
        return bag:take(itemKey, quantity)
      end,
      move = function(pocketKey, fromIndex, toIndex)
        return bag:move(pocketKey, fromIndex, toIndex)
      end,
      register = function(itemKey)
        return bag:tryRegister(itemKey)
      end,
      unregister = function(itemKey)
        return bag:unregister(itemKey)
      end,
    },
    resolveActions = BagActionPolicy.forService(bag),
  })
  return control
end

local function navigate(direction)
  return { type = "navigate", direction = direction }
end

local function settleEntry(control)
  for _ = 1, 64 do
    if control:status().state == "action_menu" then
      return
    end
    Assert.equal(control:status().state, "item_select", "the entry settles into the action menu")
    control:updateFixed({})
  end
  Assert.equal(control:status().state, "action_menu", "the entry settles into the action menu")
end

local function openActionMenu(bag, pocket)
  local cursor = BagCursor.new()
  cursor:setPocket(pocket)
  local effects = {}
  local control = controller(bag, cursor, effects)
  control:updateFixed({ { type = "confirm" } })
  settleEntry(control)
  Assert.equal(control:status().state, "action_menu", "setup opens the action menu")
  return control, effects
end

local function hasEffect(effects, sequence)
  for _, seen in ipairs(effects) do
    if seen == sequence then
      return true
    end
  end
  return false
end

function T.confirming_an_occupied_item_emits_the_selection_effect()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5))
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local effects = {}
  local control = controller(bag, cursor, effects)
  control:updateFixed({ { type = "confirm" } })
  Assert.isTrue(hasEffect(effects, "SEQ_SE_DP_SELECT"), "confirming an occupied item plays the selection effect")
end

function T.action_activation_latches_feedback_before_entering_quantity()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5))
  local control, effects = openActionMenu(bag, "medicine")
  local before = #effects
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(
    control:status().state,
    "action_menu",
    "activating the toss action latches feedback instead of dispatching immediately"
  )
  Assert.isTrue(hasEffect(effects, "SEQ_SE_DP_SELECT"), "action activation plays the selection effect")
  local latched = #effects
  for _ = 1, 256 do
    if control:status().state ~= "action_menu" then
      break
    end
    control:updateFixed({})
  end
  Assert.equal(control:status().state, "toss_quantity", "the pending toss action runs after feedback completes")
  Assert.equal(#effects, latched, "feedback completion emits no second activation effect")
  Assert.isTrue(before < latched, "setup observed the activation effect")
end

function T.action_cancel_plays_the_cancel_effect()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5))
  local control, effects = openActionMenu(bag, "medicine")
  control:updateFixed({ { type = "dismiss" } })
  Assert.isTrue(hasEffect(effects, "SEQ_SE_GS_GEARCANCEL"), "action cancel plays the cancel effect")
end

function T.quantity_adjustment_plays_the_bag_effect()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 25))
  local control, effects = openActionMenu(bag, "medicine")
  control:updateFixed({ { type = "confirm" } })
  for _ = 1, 256 do
    if control:status().state == "toss_quantity" then
      break
    end
    control:updateFixed({})
  end
  Assert.equal(control:status().state, "toss_quantity", "setup reaches the quantity picker")
  local before = #effects
  control:updateFixed({ navigate("right") })
  Assert.isTrue(hasEffect(effects, "SEQ_SE_DP_BAG_004"), "quantity adjustment plays the bag amount effect")
  Assert.isTrue(#effects > before, "setup observed the adjustment effect")
end

function T.single_copy_toss_types_its_confirmation_before_the_prompt_opens()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 1))
  local control, _ = openActionMenu(bag, "medicine")
  control:updateFixed({ { type = "confirm" } })
  for _ = 1, 256 do
    if control:status().state == "toss_confirm" then
      break
    end
    control:updateFixed({})
  end
  local status = control:status()
  Assert.equal(status.state, "toss_confirm", "a single copy confirms without the quantity picker")
  Assert.equal(status.tossBase, "action", "a single-item toss retains the action base")
  local message = assert(status.lowerMessage, "the toss confirmation publishes its lower message")
  Assert.isTrue(
    #message.visibleText < #message.fullText,
    "the confirmation message types out instead of appearing instantly"
  )
  Assert.isNil(status.yesNoPrompt, "the prompt stays closed while the confirmation message prints")
  control:updateFixed({ { type = "confirm" } })
  Assert.isNil(control:status().yesNoPrompt, "input that accelerates printing cannot open the prompt in the same tick")
  for _ = 1, 512 do
    if control:status().yesNoPrompt ~= nil then
      break
    end
    control:updateFixed({})
  end
  Assert.notNil(control:status().yesNoPrompt, "the prompt opens only after the confirmation message finishes")
end

function T.stacked_toss_mutates_only_after_the_result_message_and_acknowledgement()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5))
  local control, _ = openActionMenu(bag, "medicine")
  control:updateFixed({ { type = "confirm" } })
  for _ = 1, 256 do
    if control:status().state == "toss_quantity" then
      break
    end
    control:updateFixed({})
  end
  Assert.equal(control:status().state, "toss_quantity", "setup reaches the quantity picker")
  control:updateFixed({ { type = "confirm" } })
  for _ = 1, 256 do
    if control:status().state == "toss_confirm" then
      break
    end
    control:updateFixed({})
  end
  Assert.equal(control:status().tossBase, "quantity", "a stacked toss retains the quantity base")
  for _ = 1, 512 do
    if control:status().yesNoPrompt ~= nil then
      break
    end
    control:updateFixed({})
  end
  Assert.notNil(control:status().yesNoPrompt, "setup opens the confirmation prompt")
  local revision = bag:revision()
  control:updateFixed({ { type = "confirm" } })
  for _ = 1, 9 do
    control:updateFixed({})
  end
  Assert.equal(control:status().state, "toss_confirm", "choosing yes starts the result message, not the mutation")
  Assert.equal(bag:revision(), revision, "the yes choice changes no quantities while the result prints")
  local resultStatus = control:status()
  local result = assert(resultStatus.lowerMessage, "the toss result publishes its lower message")
  Assert.isTrue(#result.visibleText < #result.fullText, "the result message types out instead of mutating instantly")
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(bag:revision(), revision, "input that accelerates the result cannot acknowledge in the same tick")
  for _ = 1, 512 do
    local current = control:status().lowerMessage
    if current ~= nil and #current.visibleText >= #current.fullText then
      break
    end
    control:updateFixed({})
  end
  local done = control:status().lowerMessage
  Assert.notNil(done, "setup finishes the result message")
  Assert.equal(#done.visibleText, #done.fullText, "setup completes the result message")
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(bag:quantity("POTION"), 4, "acknowledgement after the result commits the picked copies once")
  Assert.equal(bag:revision(), revision + 1, "the toss mutates exactly once")
end

function T.move_confirm_waits_for_its_commit_clip_before_reordering()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5))
  Assert.isTrue(bag:add("ITEM_1", 2))
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local moved = 0
  local layoutManifest = manifest()
  local control = BagController.new({
    model = {
      refresh = function()
        return BagModel.build(bag, cursor)
      end,
    },
    cursor = cursor,
    resolveLayout = function()
      return BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
    end,
    promptShape = promptShape(),
    tossPrompt = tossPrompt(),
    itemSelectTicks = 3,
    effect = function(_) end,
    textPolicy = textPolicy(),
    commands = {
      toss = function(itemKey, quantity)
        return bag:take(itemKey, quantity)
      end,
      move = function(pocketKey, fromIndex, toIndex)
        moved = moved + 1
        return bag:move(pocketKey, fromIndex, toIndex)
      end,
      register = function(itemKey)
        return bag:tryRegister(itemKey)
      end,
      unregister = function(itemKey)
        return bag:unregister(itemKey)
      end,
    },
    resolveActions = BagActionPolicy.forService(bag),
  })
  control:updateFixed({ { type = "confirm" } })
  settleEntry(control)
  control:updateFixed({ navigate("down") })
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "move_select", "setup enters move targeting")
  control:updateFixed({ navigate("down") })
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(moved, 0, "confirming a new target starts the commit clip instead of mutating")
  for _ = 1, 256 do
    if control:status().state == "browsing" then
      break
    end
    control:updateFixed({})
  end
  Assert.equal(control:status().state, "browsing", "the commit clip returns to browsing")
  Assert.equal(moved, 1, "the changed-target reorder runs exactly once after its clip")
end

function T.move_confirm_on_the_original_target_never_reorders()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5))
  Assert.isTrue(bag:add("ITEM_1", 2))
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local moved = 0
  local layoutManifest = manifest()
  local control = BagController.new({
    model = {
      refresh = function()
        return BagModel.build(bag, cursor)
      end,
    },
    cursor = cursor,
    resolveLayout = function()
      return BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
    end,
    promptShape = promptShape(),
    tossPrompt = tossPrompt(),
    itemSelectTicks = 3,
    effect = function(_) end,
    textPolicy = textPolicy(),
    commands = {
      toss = function(itemKey, quantity)
        return bag:take(itemKey, quantity)
      end,
      move = function(pocketKey, fromIndex, toIndex)
        moved = moved + 1
        return bag:move(pocketKey, fromIndex, toIndex)
      end,
      register = function(itemKey)
        return bag:tryRegister(itemKey)
      end,
      unregister = function(itemKey)
        return bag:unregister(itemKey)
      end,
    },
    resolveActions = BagActionPolicy.forService(bag),
  })
  control:updateFixed({ { type = "confirm" } })
  settleEntry(control)
  control:updateFixed({ navigate("down") })
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "move_select", "setup enters move targeting")
  control:updateFixed({ { type = "confirm" } })
  for _ = 1, 256 do
    if control:status().state == "browsing" then
      break
    end
    control:updateFixed({})
  end
  Assert.equal(control:status().state, "browsing", "confirming the origin returns cleanly")
  Assert.equal(moved, 0, "an identity reorder never calls the move command")
end

function T.invalid_move_navigation_plays_the_error_effect()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5))
  Assert.isTrue(bag:add("ITEM_1", 2))
  local control, effects = openActionMenu(bag, "medicine")
  control:updateFixed({ navigate("down") })
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "move_select", "setup enters move targeting")
  local before = #effects
  control:updateFixed({ navigate("up") })
  control:updateFixed({ navigate("up") })
  Assert.isTrue(hasEffect(effects, "SEQ_SE_DP_BOX03"), "invalid move navigation plays the error effect")
  Assert.isTrue(#effects > before, "setup observed the error effect")
end

function T.prompt_navigation_and_decision_emit_prompt_effects_without_touching_the_blink()
  local shape = promptShape()
  local effects = {}
  local prompt = YesNoPromptController.new(shape, function(sequence)
    effects[#effects + 1] = sequence
  end)
  prompt:open(tossPrompt())
  prompt:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.isTrue(hasEffect(effects, "SEQ_SE_DP_SELECT"), "prompt selection change plays the selection effect")
  local latched = #effects
  prompt:updateFixed({ { type = "confirm" } })
  Assert.isTrue(hasEffect(effects, "SEQ_SE_DP_BUTTON9"), "a latched prompt decision plays the decision effect")
  for _ = 1, 7 do
    prompt:updateFixed({})
  end
  Assert.equal(#effects, latched + 1, "the confirmation blink emits no further prompt effects")
  local silent = YesNoPromptController.new(shape)
  silent:open(tossPrompt())
  silent:updateFixed({ { type = "navigate", direction = "down" } })
  silent:updateFixed({ { type = "confirm" } })
  for _ = 1, 9 do
    silent:updateFixed({})
  end
  Assert.notNil(silent:takeResult(), "a prompt without an effect callback keeps its prior lifecycle")
end

function T.typed_toss_messages_reveal_multi_byte_names_without_splitting_glyphs()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5))
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local effects = {}
  local layoutManifest = manifest()
  local function resolveLayout()
    return BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  end
  local control = BagController.new({
    model = {
      refresh = function()
        local view = BagModel.build(bag, cursor)
        local selected = assert(view.selected, "the multi-byte setup needs its selected item")
        selected.name = "Poké Ball"
        selected.namePlural = "Poké Balls"
        return view
      end,
    },
    cursor = cursor,
    resolveLayout = resolveLayout,
    promptShape = promptShape(),
    tossPrompt = tossPrompt(),
    itemSelectTicks = 3,
    effect = function(sequence)
      effects[#effects + 1] = sequence
    end,
    textPolicy = textPolicy(),
    commands = {
      toss = function(itemKey, quantity)
        return bag:take(itemKey, quantity)
      end,
      move = function(pocketKey, fromIndex, toIndex)
        return bag:move(pocketKey, fromIndex, toIndex)
      end,
      register = function(itemKey)
        return bag:tryRegister(itemKey)
      end,
      unregister = function(itemKey)
        return bag:unregister(itemKey)
      end,
    },
    resolveActions = BagActionPolicy.forService(bag),
  })
  control:updateFixed({ { type = "confirm" } })
  settleEntry(control)
  Assert.equal(control:status().state, "action_menu", "setup opens the action menu")
  control:updateFixed({ { type = "confirm" } })
  for _ = 1, 256 do
    if control:status().state == "toss_quantity" then
      break
    end
    control:updateFixed({})
  end
  Assert.equal(control:status().state, "toss_quantity", "setup reaches the quantity picker")
  control:updateFixed({ navigate("up") })
  Assert.equal(control:status().quantity, 2, "setup picks two copies")
  control:updateFixed({ { type = "confirm" } })
  for _ = 1, 256 do
    if control:status().state == "toss_confirm" then
      break
    end
    control:updateFixed({})
  end
  Assert.equal(control:status().state, "toss_confirm", "setup reaches toss confirmation")
  local confirmStatus = control:status()
  local message = assert(confirmStatus.lowerMessage, "the toss confirmation publishes its lower message")
  Assert.isTrue(message.fullText:find("Poké Balls", 1, true) ~= nil, "the confirmation names the multi-byte plural")
  local snapshots = {}
  for _ = 1, 512 do
    local current = control:status().lowerMessage
    assert(current, "the confirmation message stays published while printing")
    snapshots[#snapshots + 1] = current.visibleText
    if #current.visibleText >= #current.fullText then
      break
    end
    control:updateFixed({})
  end
  local done = assert(control:status().lowerMessage, "setup finishes the confirmation message")
  Assert.equal(#done.visibleText, #done.fullText, "setup completes the confirmation message")
  local fullText = done.fullText
  local boundaries = { [0] = true }
  local glyphCount = 0
  local covered = 0
  local nextGlyph = Utf8Glyphs.iter(fullText)
  while true do
    local glyph = nextGlyph()
    if glyph == nil then
      break
    end
    glyphCount = glyphCount + 1
    covered = covered + #glyph
    boundaries[covered] = true
  end
  Assert.equal(covered, #fullText, "glyph iteration covers the full message")
  Assert.isTrue(#fullText > glyphCount, "the message carries multi-byte glyphs")
  Assert.isTrue(#snapshots >= 1, "setup observed the typed reveal")
  for _, snapshot in ipairs(snapshots) do
    Assert.isTrue(boundaries[#snapshot] == true, "every reveal lands on a glyph boundary")
  end
end

return { tests = T }
