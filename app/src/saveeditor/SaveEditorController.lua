-- Owns editor navigation, modal state, focus, and pointer capture.

local Controller = {}
Controller.__index = Controller

---@class SaveEditorController
---@field section string
---@field modal string?
---@field focus string
---@field capturedTarget string?
---@field pointerId string?
---@field scrollOffset number
---@field query string
---@field flagFilter string
---@field flagGroup string?
---@field snapshot fun(self: SaveEditorController): table<string, unknown>
---@field press fun(self: SaveEditorController, action: string): table<string, unknown>?
---@field openModal fun(self: SaveEditorController, kind: string)
---@field pointer fun(self: SaveEditorController, event: table<string, unknown>): table<string, unknown>?
---@field cancelInteraction fun(self: SaveEditorController)

function Controller.new()
  return setmetatable({
    section = "Player",
    modal = nil,
    focus = "money",
    capturedTarget = nil,
    pointerId = nil,
    scrollOffset = 0,
    query = "",
    flagFilter = "Named",
  }, Controller)
end

function Controller:snapshot()
  return {
    section = self.section,
    modal = self.modal,
    focus = self.focus,
    scrollOffset = self.scrollOffset,
    query = self.query,
    flagFilter = self.flagFilter,
    sections = { "Location", "Player", "Party", "Bag", "Progress" },
  }
end

function Controller:press(action)
  if self.modal then
    if action == "cancel" or action == "back" then
      self.modal = nil
      return { kind = "cancel" }
    elseif action == "up" or action == "down" or action == "left" or action == "right" then
      self.focus = action == "left" and "save" or action == "right" and "discard" or self.focus
      return nil
    elseif action == "confirm" or action == "activate" then
      return { kind = "action", action = self.focus }
    end
    return nil
  end
  if action == "back" or action == "cancel" then
    return { kind = "back" }
  end
  if action == "left" or action == "right" or action == "up" or action == "down" then
    return { kind = "move", direction = action }
  elseif action == "confirm" or action == "activate" then
    return { kind = "activate", targetId = self.focus }
  elseif action == "save" or action == "discard" then
    return { kind = "action", action = action }
  end
  return nil
end

function Controller:openModal(kind)
  self.modal = kind
  self.focus = "cancel"
end

function Controller:pointer(event)
  if event.type == "pointer_cancel" then
    self.capturedTarget, self.pointerId = nil, nil
    return nil
  end
  if event.type == "pointer_down" then
    self.capturedTarget, self.pointerId = event.targetId, event.pointerId
    if event.targetId ~= nil then
      self.focus = event.targetId
    end
    return nil
  elseif event.type == "pointer_up" then
    local target = event.targetId
    if self.pointerId == event.pointerId and self.capturedTarget ~= nil and target == self.capturedTarget then
      self.capturedTarget, self.pointerId = nil, nil
      return { kind = "activate", targetId = target }
    end
    self.capturedTarget, self.pointerId = nil, nil
  end
  return nil
end

function Controller:cancelInteraction()
  self.capturedTarget, self.pointerId = nil, nil
end

return Controller
