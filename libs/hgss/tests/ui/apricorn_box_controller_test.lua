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
  Assert.equal(controller:status().phase, "quantity")
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(controller:status().phase, "quantity", "the OK press holds its beat")
  for _ = 1, 5 do
    controller:updateFixed({})
  end
  Assert.equal(controller:status().phase, "confirm")
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
  Assert.equal(controller:status().phase, "quantity")
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(controller:status().phase, "quantity", "the OK press holds its beat")
  for _ = 1, 5 do
    controller:updateFixed({})
  end
  Assert.equal(controller:status().phase, "confirm")
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
  Assert.equal(controller:status().phase, "quantity")
  Assert.equal(controller:status().cursorSequenceId, 5)
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(controller:status().quantity, 2)
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(controller:status().phase, "quantity", "the OK press holds its beat")
  for _ = 1, 5 do
    controller:updateFixed({})
  end
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
    "1500,1500,1500,1500,SEQ_SE_DP_BUTTON9",
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
  Assert.equal(controller:status().phase, "quantity", "the OK press holds its beat")
  for _ = 1, 5 do
    controller:updateFixed({})
  end
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
    "1500,1515",
    "navigation and row selection use their source cues"
  )
end

function T.tests.confirmation_owns_input_and_publishes_yes_after_prompt_blink()
  local service = serviceWith({ BLU_APRICORN = 3, RED_APRICORN = 2 })
  local controller =
    newController({ mode = "kurt_select", service = service, apricornKeys = KEYS, effect = silentEffect })
  controller:updateFixed({ { type = "touch_row", index = 2 } })
  for _ = 1, 4 do
    controller:updateFixed({})
  end
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  controller:updateFixed({ { type = "confirm" } })
  for _ = 1, 5 do
    controller:updateFixed({})
  end
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

function T.tests.kurt_quantity_ok_press_holds_its_pressed_frame_before_confirm()
  local controller = newController({
    mode = "kurt_select",
    service = serviceWith({ WHT_APRICORN = 4 }),
    apricornKeys = KEYS,
    effect = silentEffect,
  })
  controller:updateFixed({ { type = "touch_row", index = 6 } })
  for _ = 1, 4 do
    controller:updateFixed({})
  end
  Assert.equal(controller:status().phase, "quantity")
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(controller:status().phase, "quantity", "the OK press holds quantity for its beat")
  Assert.equal(controller:status().pressedAction, 1, "the OK button shows pressed")
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(controller:status().quantity, 1, "edits wait out the pressed beat")
  for _ = 1, 3 do
    controller:updateFixed({})
    Assert.equal(controller:status().phase, "quantity")
    Assert.equal(controller:status().pressedAction, 1)
  end
  controller:updateFixed({})
  Assert.equal(controller:status().phase, "confirm", "the beat releases into confirmation")
  Assert.isNil(controller:status().pressedAction)
  Assert.isNil(controller:takeResult(), "confirmation still waits for the prompt decision")
end

function T.tests.kurt_quantity_cancel_press_returns_to_rows_after_its_beat()
  local sounds = {}
  local controller = newController({
    mode = "kurt_select",
    service = serviceWith({ WHT_APRICORN = 4 }),
    apricornKeys = KEYS,
    effect = function(sequence)
      sounds[#sounds + 1] = sequence
    end,
  })
  controller:updateFixed({ { type = "touch_row", index = 6 } })
  for _ = 1, 4 do
    controller:updateFixed({})
  end
  controller:updateFixed({ { type = "quantity_control", index = 2 } })
  Assert.equal(controller:status().phase, "quantity", "the CANCEL press holds quantity for its beat")
  Assert.equal(controller:status().pressedAction, 2, "the CANCEL button shows pressed")
  Assert.equal(sounds[#sounds], 1500, "the CANCEL button uses the source select cue")
  for _ = 1, 4 do
    controller:updateFixed({})
    Assert.equal(controller:status().phase, "quantity")
  end
  controller:updateFixed({})
  Assert.equal(controller:status().phase, "rows", "the beat releases back to row selection")
  Assert.isNil(controller:status().pressedAction)
  Assert.isNil(controller:takeResult(), "canceling quantity publishes no selection")
end

function T.tests.kurt_quantity_b_key_mirrors_the_cancel_button()
  local controller = newController({
    mode = "kurt_select",
    service = serviceWith({ WHT_APRICORN = 4 }),
    apricornKeys = KEYS,
    effect = silentEffect,
  })
  controller:updateFixed({ { type = "touch_row", index = 6 } })
  for _ = 1, 4 do
    controller:updateFixed({})
  end
  controller:updateFixed({ { type = "cancel" } })
  Assert.equal(controller:status().phase, "quantity", "B mirrors the CANCEL button beat")
  Assert.equal(controller:status().pressedAction, 2)
  for _ = 1, 5 do
    controller:updateFixed({})
  end
  Assert.equal(controller:status().phase, "rows")
end

function T.tests.quantity_arrow_touch_replays_its_bounce()
  local controller = newController({
    mode = "kurt_select",
    service = serviceWith({ WHT_APRICORN = 4 }),
    apricornKeys = KEYS,
    effect = silentEffect,
  })
  controller:updateFixed({ { type = "touch_row", index = 6 } })
  for _ = 1, 4 do
    controller:updateFixed({})
  end
  controller:updateFixed({ { type = "quantity_control", index = 4 } })
  Assert.deepEqual(
    controller:status().arrowFlashes,
    { [2] = 0 },
    "the touched arrow restarts its bounce"
  )
  controller:updateFixed({})
  controller:updateFixed({})
  Assert.equal(controller:status().arrowFlashes[2], 2, "the bounce advances on fixed ticks")
  Assert.isNil(controller:status().arrowFlashes[1], "untouched arrows stay on their resting frame")
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
  controller:updateFixed({ { type = "navigate", direction = "up" }, { type = "confirm" } })
  Assert.equal(controller:status().phase, "quantity", "the OK press holds its beat")
  for _ = 1, 5 do
    controller:updateFixed({})
  end
  Assert.equal(controller:status().phase, "confirm")
  controller:updateFixed({ { type = "pointer_down", x = 150, y = 142 } })
  for _ = 1, 9 do
    controller:updateFixed({})
  end
  Assert.equal(controller:status().phase, "quantity")
  Assert.equal(controller:status().selectedIndex, 6)
  Assert.equal(controller:status().quantity, 2)
  Assert.isNil(controller:takeResult(), "No returns to editing without a selection result")
end

function T.tests.browse_and_kurt_selection_share_the_retail_row_contract()
  local browse = newController({
    mode = "browse",
    service = serviceWith({ RED_APRICORN = 1 }),
    apricornKeys = KEYS,
    effect = silentEffect,
  })
  Assert.equal(browse:status().cursorSequenceId, 3, "idle browse draws the hand, never the close button")
  browse:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(browse:status().selectedIndex, 2, "right moves from left column to right column")
  browse:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(browse:status().selectedIndex, 1, "left returns to the left column")
  browse:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(browse:status().selectedIndex, 1, "left at the left edge stays put")
  browse:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(browse:status().selectedIndex, 3, "down stays inside the left column")
  browse:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(browse:status().selectedIndex, 1, "up stays inside the left column")
  browse:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(browse:status().selectedIndex, 1, "up at the top stays put instead of wrapping")
  browse:updateFixed({ { type = "confirm" } })
  Assert.equal(browse:status().phase, "browse", "retail view has no USE/TASTE/CANCEL menu")
  local kurt = newController({
    mode = "kurt_select",
    service = serviceWith({ WHT_APRICORN = 30 }),
    apricornKeys = KEYS,
    effect = silentEffect,
  })
  kurt:updateFixed({ { type = "touch_row", index = 6 } })
  for _ = 1, 4 do
    kurt:updateFixed({})
  end
  Assert.equal(kurt:status().phase, "quantity", "Kurt goes straight to quantity")
  kurt:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(kurt:status().quantity, 2, "up steps one")
  kurt:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(kurt:status().quantity, 1, "down steps one")
  kurt:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(kurt:status().quantity, 11, "right steps ten")
  kurt:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(kurt:status().quantity, 1, "left steps ten")
end

return T
