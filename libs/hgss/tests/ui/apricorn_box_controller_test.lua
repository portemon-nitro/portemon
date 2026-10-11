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
  local controller =
    ApricornBoxController.new({ mode = "browse", service = service, apricornKeys = KEYS, effect = silentEffect })
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
    ApricornBoxController.new({ mode = "kurt_select", service = service, apricornKeys = KEYS, effect = silentEffect })
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
  local controller = ApricornBoxController.new({
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
  controller:updateFixed({ { type = "confirm" }, { type = "confirm" }, { type = "confirm" } })
  local result = controller:takeResult()
  Assert.equal(result.selected.apricornKey, "WHT_APRICORN", "touch selection returns a semantic key")
  Assert.equal(result.selected.quantity, 1, "touch selection leaves quantity within available stock")
end

function T.tests.kurt_row_waits_then_adjusts_quantity_and_requires_confirmation()
  local sounds = {}
  local service = serviceWith({ WHT_APRICORN = 4 })
  local controller = ApricornBoxController.new({
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
  local result = controller:takeResult()
  Assert.equal(result.selected.apricornKey, "WHT_APRICORN")
  Assert.equal(result.selected.quantity, 2)
  Assert.equal(
    table.concat(sounds, ","),
    "1500,1500,1500,1500,1500,1500",
    "Kurt selection and controls use the source select cue"
  )
  Assert.equal(service:capture().apricorns.WHT_APRICORN, 4, "confirmation never spends stock")
end

function T.tests.kurt_confirmation_cancel_returns_to_quantity_without_result()
  local controller = ApricornBoxController.new({
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
  Assert.equal(controller:status().phase, "quantity")
  Assert.isNil(controller:takeResult())
end

function T.tests.browse_row_navigation_and_touch_produce_source_feedback()
  local sounds = {}
  local controller = ApricornBoxController.new({
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

return T
