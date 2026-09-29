-- Owns the semantic state of the field Yes/No command.

---@class FieldYesNoController
local FieldYesNoController = {}
FieldYesNoController.__index = FieldYesNoController

---@return FieldYesNoController
function FieldYesNoController.new()
  return setmetatable({ active = false, selectedIndex = 0, result = nil }, FieldYesNoController)
end

---@param request { yesText: string, noText: string, frameIndex: integer? }
function FieldYesNoController:open(request)
  assert(not self.active, "field yes/no choice is already active")
  assert(type(request) == "table", "field yes/no request is required")
  assert(type(request.yesText) == "string" and type(request.noText) == "string", "field yes/no labels are required")
  assert(
    request.frameIndex == nil
      or (type(request.frameIndex) == "number" and request.frameIndex % 1 == 0 and request.frameIndex >= 0),
    "field yes/no frame is invalid"
  )
  self.active = true
  self.selectedIndex = 0
  self.result = nil
  self.yesText = request.yesText
  self.noText = request.noText
  self.frameIndex = request.frameIndex
end

-- Semantic choice events translated by the live presentation host from the
-- fixed-tick input lane. Raw directional/action/cancel edges never reach
-- this controller directly.
---@param event { type: string, row: integer?, direction: string? }
function FieldYesNoController:handleEvent(event)
  if not self.active then
    return
  end
  assert(type(event) == "table" and type(event.type) == "string", "choice event is invalid")
  if event.type == "focus" then
    assert(event.row == 0 or event.row == 1, "choice focus is outside the two choices")
    self.selectedIndex = event.row
  elseif event.type == "navigate" then
    if event.direction == "up" then
      self.selectedIndex = math.max(0, self.selectedIndex - 1)
    elseif event.direction == "down" then
      self.selectedIndex = math.min(1, self.selectedIndex + 1)
    elseif event.direction == "left" or event.direction == "right" then
      -- Horizontal edges never move the two-row selection.
    else
      assert(false, "choice navigate direction is invalid")
    end
  elseif event.type == "confirm" then
    self.result = { accepted = self.selectedIndex == 0 }
  elseif event.type == "cancel" then
    self.result = { accepted = false }
  else
    assert(false, "unknown choice event " .. event.type)
  end
end

---@return table<string, unknown>
function FieldYesNoController:status()
  return {
    active = self.active,
    selectedIndex = self.selectedIndex,
    yesText = self.yesText,
    noText = self.noText,
    frameIndex = self.frameIndex,
    result = self.result and { accepted = self.result.accepted } or nil,
  }
end

---@return { accepted: boolean }?
function FieldYesNoController:takeResult()
  if not self.result then
    return nil
  end
  local result = self.result
  self.result = nil
  return { accepted = result.accepted }
end

function FieldYesNoController:close()
  self.active = false
  self.result = nil
  self.yesText = nil
  self.noText = nil
  self.frameIndex = nil
end

return FieldYesNoController
