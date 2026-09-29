local Assert = require("tests.support.Assert")
local Controller = require("libs.hgss.src.ui.FieldYesNoController")

local T = {}

local function open()
  local controller = Controller.new()
  controller:open({ yesText = "sim", noText = "nao", frameIndex = 2 })
  return controller
end

function T.initial_selection_and_no_wrap()
  local controller = open()
  Assert.equal(controller:status().selectedIndex, 0)
  controller:handleEvent({ type = "navigate", direction = "up" })
  Assert.equal(controller:status().selectedIndex, 0)
  controller:handleEvent({ type = "navigate", direction = "down" })
  controller:handleEvent({ type = "navigate", direction = "down" })
  Assert.equal(controller:status().selectedIndex, 1)
  controller:handleEvent({ type = "navigate", direction = "left" })
  Assert.equal(controller:status().selectedIndex, 1)
  controller:handleEvent({ type = "navigate", direction = "right" })
  Assert.equal(controller:status().selectedIndex, 1)
end

function T.focus_selects_the_touched_row()
  local controller = open()
  controller:handleEvent({ type = "focus", row = 1 })
  Assert.equal(controller:status().selectedIndex, 1)
  controller:handleEvent({ type = "focus", row = 0 })
  Assert.equal(controller:status().selectedIndex, 0)
end

function T.action_and_cancel_return_the_selected_semantics()
  local controller = open()
  controller:handleEvent({ type = "confirm" })
  Assert.deepEqual(controller:takeResult(), { accepted = true })
  Assert.isNil(controller:takeResult())
  controller:close()
  controller:open({ yesText = "sim", noText = "nao" })
  controller:handleEvent({ type = "navigate", direction = "down" })
  controller:handleEvent({ type = "confirm" })
  Assert.deepEqual(controller:takeResult(), { accepted = false })
  controller:close()
  controller:open({ yesText = "sim", noText = "nao" })
  controller:handleEvent({ type = "cancel" })
  Assert.deepEqual(controller:takeResult(), { accepted = false })
end

function T.closed_choice_ignores_events()
  local controller = open()
  controller:close()
  controller:handleEvent({ type = "confirm" })
  Assert.isNil(controller:takeResult())
end

return { tests = T }
