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
---@field partyPage string
---@field partySlot0 integer?
---@field partySubpage string
---@field bagPocket string
---@field bagItemKey string?
---@field setSection fun(self: SaveEditorController, section: string)
---@field setFocus fun(self: SaveEditorController, targetId: string)
---@field moveFocus fun(self: SaveEditorController, focusable: string[], direction: string)
---@field selectPartySlot fun(self: SaveEditorController, slot0: integer)
---@field openPartyDraft fun(self: SaveEditorController)
---@field closePartyDetail fun(self: SaveEditorController)
---@field selectPartySubpage fun(self: SaveEditorController, subpage: string)
---@field selectBagPocket fun(self: SaveEditorController, pocket: string)
---@field selectBagItem fun(self: SaveEditorController, itemKey: string)
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
    partyPage = "list",
    partySlot0 = nil,
    partySubpage = "Identity",
    bagPocket = "items",
    bagItemKey = nil,
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
    partyPage = self.partyPage,
    partySlot0 = self.partySlot0,
    partySubpage = self.partySubpage,
    bagPocket = self.bagPocket,
    bagItemKey = self.bagItemKey,
  }
end

function Controller:press(action)
  if self.modal then
    if action == "cancel" or action == "back" then
      local modal = self.modal
      self.modal = nil
      return { kind = "cancel", modal = modal }
    elseif action == "up" or action == "down" or action == "left" or action == "right" then
      local choices = self.modal == "leave" and { "save", "discard", "cancel" }
        or self.modal == "draft" and { "apply", "discard", "cancel" }
        or { "remove", "cancel" }
      local index = 1
      for choiceIndex, choice in ipairs(choices) do
        if self.focus == choice then
          index = choiceIndex
          break
        end
      end
      local delta = 1
      if action == "left" or action == "up" then
        delta = -1
      end
      self.focus = choices[(index - 1 + delta) % #choices + 1]
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

function Controller:setSection(section)
  assert(section == "Player" or section == "Progress" or section == "Party" or section == "Bag")
  self.section = section
  self.modal = nil
  self.capturedTarget, self.pointerId = nil, nil
  if section == "Party" then
    self.partyPage = "list"
    self.partySlot0 = nil
    self.focus = "party:add"
  elseif section == "Bag" then
    self.focus = "bag:pocket:" .. self.bagPocket
  elseif section == "Player" then
    self.focus = "money"
  else
    self.focus = "flag:" .. (self.focus:match("^flag:(.+)$") or "")
  end
end

function Controller:setFocus(targetId)
  assert(type(targetId) == "string" and targetId ~= "")
  self.focus = targetId
end

function Controller:moveFocus(focusable, direction)
  if #focusable == 0 then
    return
  end
  local current = 1
  for index, targetId in ipairs(focusable) do
    if targetId == self.focus then
      current = index
      break
    end
  end
  local delta = (direction == "up" or direction == "left") and -1 or 1
  self.focus = focusable[(current - 1 + delta) % #focusable + 1]
end

function Controller:selectPartySlot(slot0)
  assert(type(slot0) == "number" and slot0 % 1 == 0 and slot0 >= 0 and slot0 < 6)
  self.partySlot0 = slot0
  self.partyPage = "detail"
  self.partySubpage = "Identity"
  self.focus = "party:field:species"
  self:cancelInteraction()
end

function Controller:openPartyDraft()
  assert(self.partySlot0 ~= nil or self.focus == "party:add")
  self.partyPage = "draft"
  self.focus = "party:apply"
  self:cancelInteraction()
end

function Controller:closePartyDetail()
  self.partyPage = "list"
  self.focus = self.partySlot0 and ("party:slot:" .. self.partySlot0) or "party:add"
  self.partySlot0 = nil
  self:cancelInteraction()
end

function Controller:selectPartySubpage(subpage)
  assert(
    subpage == "Identity" or subpage == "Training" or subpage == "Stats" or subpage == "Moves" or subpage == "Origin"
  )
  self.partySubpage = subpage
  self.focus = "party:subpage:" .. subpage
  self:cancelInteraction()
end

function Controller:selectBagPocket(pocket)
  assert(type(pocket) == "string" and pocket ~= "")
  self.bagPocket = pocket
  self.bagItemKey = nil
  self.focus = "bag:pocket:" .. pocket
  self:cancelInteraction()
end

function Controller:selectBagItem(itemKey)
  assert(type(itemKey) == "string" and itemKey ~= "")
  self.bagItemKey = itemKey
  self.focus = "bag:item:" .. itemKey
  self:cancelInteraction()
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
