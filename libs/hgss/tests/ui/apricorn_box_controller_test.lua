-- Covers the read-only browse view and value-only Kurt selection protocol.

local Assert = require("tests.support.Assert")
local ApricornBoxController = require("libs.hgss.src.ui.ApricornBoxController")

local T = { tests = {} }

local KEYS = {
  "RED_APRICORN",
  "BLU_APRICORN",
  "YLW_APRICORN",
  "GRN_APRICORN",
  "PNK_APRICORN",
  "WHT_APRICORN",
  "BLK_APRICORN",
}
local function silentEffect(_) end

local function promptShape()
  local row = { normal = {}, selected = {} }
  return { width = 48, height = 32, yes = row, no = row }
end

local function newController(options)
  options.promptShape = promptShape()
  options.promptPlacement = { x = 136, y = 96, shape = "compact", initialSelection = "yes" }
  return ApricornBoxController.new(options)
end

local function serviceWith(initial)
  local stock = initial
  local service = {}
  function service:capture()
    local copy = {}
    for key, quantity in pairs(stock) do
      copy[key] = quantity
    end
    return { apricorns = copy }
  end
  function service:replace(nextStock)
    stock = nextStock
  end
  return service
end

function T.tests.browse_reads_all_seven_keys_again_and_cancel_is_value_only()
  local service = serviceWith({ RED_APRICORN = 3, BLK_APRICORN = 99 })
  local controller = newController({ mode = "browse", service = service, apricornKeys = KEYS, effect = silentEffect })
  local first = controller:status()
  Assert.equal(#first.rows, 7, "browse retains empty colors")
  Assert.equal(first.rows[1].quantity, 3, "browse reads its first owned balance")
  Assert.equal(first.rows[2].quantity, 0, "browse shows an empty balance")
  service:replace({ RED_APRICORN = 5 })
  Assert.equal(controller:status().rows[1].quantity, 5, "each view reads the latest service snapshot")
  controller:updateFixed({ { type = "cancel" } })
  Assert.equal(controller:takeResult().kind, "closed", "cancel closes the application")
  Assert.isNil(controller:takeResult(), "close is delivered once")
  Assert.equal(service:capture().apricorns.RED_APRICORN, 5, "browsing never changes stock")
end

function T.tests.kurt_selection_is_bounded_and_does_not_spend_stock()
  local service = serviceWith({ GRN_APRICORN = 99 })
  local controller =
    newController({ mode = "kurt_select", service = service, apricornKeys = KEYS, effect = silentEffect })
  controller:updateFixed({ { type = "navigate", direction = "down" }, { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.isNil(controller:takeResult(), "an empty row cannot be selected")
  controller:updateFixed({ { type = "touch_row", index = 4 } })
  for _ = 1, 4 do
    controller:updateFixed({})
  end
  Assert.equal(controller:status().phase, "actions")
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  for _ = 1, 9 do
    controller:updateFixed({})
  end
  local result = controller:takeResult()
  Assert.equal(result.kind, "closed", "confirm closes with a selection")
  Assert.equal(result.selected.apricornKey, "GRN_APRICORN", "selection returns a semantic key")
  Assert.equal(result.selected.quantity, 2, "selection returns the bounded quantity")
  Assert.isNil(controller:takeResult(), "selection is delivered once")
  Assert.equal(service:capture().apricorns.GRN_APRICORN, 99, "selection does not spend stock")
  controller:updateFixed({ { type = "cancel" } })
  Assert.isNil(controller:takeResult(), "disposed selection state ignores stale input")
end

function T.tests.source_touch_row_selects_the_matching_semantic_apricorn()
  local controller = newController({
    mode = "kurt_select",
    service = serviceWith({ WHT_APRICORN = 4 }),
    apricornKeys = KEYS,
    effect = silentEffect,
  })
  controller:updateFixed({ { type = "touch_row", index = 6 } })
  Assert.equal(controller:status().selectedIndex, 6, "touch hitbox index selects its source row")
  for _ = 1, 4 do
    controller:updateFixed({})
  end
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  for _ = 1, 9 do
    controller:updateFixed({})
  end
  local result = controller:takeResult()
  Assert.equal(result.selected.apricornKey, "WHT_APRICORN", "touch selection returns a semantic key")
  Assert.equal(result.selected.quantity, 1, "touch selection leaves quantity within available stock")
end

function T.tests.kurt_row_waits_then_adjusts_quantity_and_requires_confirmation()
  local sounds = {}
  local service = serviceWith({ WHT_APRICORN = 4 })
  local controller = newController({
    mode = "kurt_select",
    service = service,
    apricornKeys = KEYS,
    effect = function(sequence)
      sounds[#sounds + 1] = sequence
    end,
  })
  controller:updateFixed({ { type = "touch_row", index = 6 } })
  Assert.equal(controller:status().phase, "selection_delay")
  Assert.equal(controller:status().cursorSequenceId, 4)
  for _ = 1, 3 do
    controller:updateFixed({})
  end
  Assert.equal(controller:status().phase, "selection_delay")
  controller:updateFixed({})
  Assert.equal(controller:status().phase, "actions")
  Assert.equal(controller:status().cursorSequenceId, 5)
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(controller:status().phase, "quantity")
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(controller:status().quantity, 2)
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(controller:status().phase, "confirm")
  Assert.isNil(controller:takeResult(), "quantity selection waits for the yes/no decision")
  controller:updateFixed({ { type = "confirm" } })
  for _ = 1, 9 do
    controller:updateFixed({})
  end
  local result = controller:takeResult()
  Assert.equal(result.selected.apricornKey, "WHT_APRICORN")
  Assert.equal(result.selected.quantity, 2)
  Assert.equal(
    table.concat(sounds, ","),
    "1500,1500,1500,1500,1500,SEQ_SE_DP_BUTTON9",
    "the source prompt owns its own confirmation sound"
  )
  Assert.equal(service:capture().apricorns.WHT_APRICORN, 4, "confirmation never spends stock")
end

function T.tests.kurt_confirmation_cancel_returns_to_quantity_without_result()
  local controller = newController({
    mode = "kurt_select",
    service = serviceWith({ RED_APRICORN = 2 }),
    apricornKeys = KEYS,
    effect = silentEffect,
  })
  controller:updateFixed({ { type = "touch_row", index = 1 } })
  for _ = 1, 4 do
    controller:updateFixed({})
  end
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(controller:status().phase, "confirm")
  controller:updateFixed({ { type = "cancel" } })
  for _ = 1, 9 do
    controller:updateFixed({})
  end
  Assert.equal(controller:status().phase, "quantity")
  Assert.isNil(controller:takeResult())
end

function T.tests.browse_row_navigation_and_touch_produce_source_feedback()
  local sounds = {}
  local controller = newController({
    mode = "browse",
    service = serviceWith({ RED_APRICORN = 1 }),
    apricornKeys = KEYS,
    effect = function(sequence)
      sounds[#sounds + 1] = sequence
    end,
  })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "touch_row", index = 1 } })
  Assert.equal(controller:status().selectedIndex, 1)
  Assert.equal(
    table.concat(sounds, ","),
    "1500,1515,1500",
    "navigation, row selection, and list open use their source cues"
  )
end

function T.tests.browse_action_menu_disables_use_and_taste_and_starts_on_cancel()
  local service = serviceWith({ RED_APRICORN = 4 })
  local controller = newController({ mode = "browse", service = service, apricornKeys = KEYS, effect = silentEffect })
  controller:updateFixed({ { type = "confirm" } })
  local status = controller:status()
  Assert.deepEqual(status.actionsEnabled, { false, false, true })
  Assert.equal(status.selectedAction, 3, "browse opens on its only implemented action")
  controller:updateFixed({ { type = "action_control", index = 1 } })
  Assert.equal(controller:status().phase, "actions", "stale USE activation leaves the menu open")
  Assert.isNil(controller:takeResult(), "disabled USE cannot publish a selected result")
  controller:updateFixed({ { type = "action_control", index = 2 } })
  Assert.equal(controller:status().phase, "actions", "disabled TASTE activation leaves the menu open")
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(controller:status().selectedAction, 3, "navigation cannot focus disabled entries")
  controller:updateFixed({ { type = "confirm" } })
  for _ = 1, 4 do
    controller:updateFixed({})
  end
  Assert.equal(controller:status().phase, "browse", "enabled CANCEL returns to the row list")
  Assert.equal(service:capture().apricorns.RED_APRICORN, 4, "browse actions never consume stock")
end

function T.tests.confirmation_owns_input_and_publishes_yes_after_prompt_blink()
  local service = serviceWith({ BLU_APRICORN = 3, RED_APRICORN = 2 })
  local controller =
    newController({ mode = "kurt_select", service = service, apricornKeys = KEYS, effect = silentEffect })
  controller:updateFixed({ { type = "touch_row", index = 2 } })
  for _ = 1, 4 do
    controller:updateFixed({})
  end
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(controller:status().phase, "confirm")
  Assert.equal(controller:status().quantity, 2)
  local prompt = controller:status().confirmationPrompt
  Assert.deepEqual(prompt.buttons.yes, { x = 136, y = 96, width = 48, height = 32 })
  Assert.deepEqual(prompt.buttons.no, { x = 136, y = 128, width = 48, height = 32 })
  controller:updateFixed({ { type = "touch_row", index = 1 } })
  Assert.equal(controller:status().selectedIndex, 2, "underlying row touch cannot replace the proposed color")
  Assert.equal(controller:status().quantity, 2, "underlying row touch cannot reset the proposed quantity")
  controller:updateFixed({ { type = "pointer_down", x = 150, y = 110 } })
  Assert.isNil(controller:takeResult(), "Yes waits for the existing prompt confirmation blink")
  for _ = 1, 8 do
    controller:updateFixed({ { type = "confirm" }, { type = "touch_row", index = 1 } })
    Assert.isNil(controller:takeResult(), "modal events cannot publish during its eight-tick blink")
  end
  controller:updateFixed({ { type = "confirm" } })
  local result = controller:takeResult()
  Assert.equal(result.selected.apricornKey, "BLU_APRICORN")
  Assert.equal(result.selected.quantity, 2)
  Assert.isNil(controller:takeResult(), "accepted selection is delivered once")
  Assert.equal(service:capture().apricorns.BLU_APRICORN, 3, "choice presentation never spends stock")
end

function T.tests.prompt_no_returns_to_quantity_with_the_same_selection()
  local controller = newController({
    mode = "kurt_select",
    service = serviceWith({ WHT_APRICORN = 3 }),
    apricornKeys = KEYS,
    effect = silentEffect,
  })
  controller:updateFixed({ { type = "touch_row", index = 6 } })
  for _ = 1, 4 do
    controller:updateFixed({})
  end
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "right" }, { type = "confirm" } })
  controller:updateFixed({ { type = "pointer_down", x = 150, y = 142 } })
  for _ = 1, 9 do
    controller:updateFixed({})
  end
  Assert.equal(controller:status().phase, "quantity")
  Assert.equal(controller:status().selectedIndex, 6)
  Assert.equal(controller:status().quantity, 2)
  Assert.isNil(controller:takeResult(), "No returns to editing without a selection result")
end

return T
