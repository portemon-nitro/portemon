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
---@field locationPage "grid"|"map-list"
---@field locationMapId integer?
---@field locationCursorX integer?
---@field locationCursorZ integer?
---@field locationCenterX integer?
---@field locationCenterZ integer?
---@field locationScale integer
---@field locationMapOffset integer
---@field locationPointerStart {x: number, y: number, targetId: string?, centerX: integer?, centerZ: integer?}?
---@field locationDragging boolean
---@field setSection fun(self: SaveEditorController, section: string)
---@field setFocus fun(self: SaveEditorController, targetId: string)
---@field moveFocus fun(self: SaveEditorController, focusable: string[], direction: string)
---@field selectPartySlot fun(self: SaveEditorController, slot0: integer)
---@field openPartyDraft fun(self: SaveEditorController)
---@field closePartyDetail fun(self: SaveEditorController)
---@field selectPartySubpage fun(self: SaveEditorController, subpage: string)
---@field selectBagPocket fun(self: SaveEditorController, pocket: string)
---@field selectBagItem fun(self: SaveEditorController, itemKey: string)
---@field enterLocation fun(self: SaveEditorController, location: table<string, unknown>)
---@field openLocationMaps fun(self: SaveEditorController)
---@field chooseLocationMap fun(self: SaveEditorController, mapId: integer, centerX: integer, centerZ: integer)
---@field moveLocationCursor fun(self: SaveEditorController, direction: string, visibleWidth: integer, visibleHeight: integer)
---@field panLocation fun(self: SaveEditorController, direction: string, visibleWidth: integer, visibleHeight: integer)
---@field zoomLocation fun(self: SaveEditorController, delta: integer)
---@field locationSnapshot fun(self: SaveEditorController): table<string, unknown>
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
    locationPage = "grid",
    locationMapId = nil,
    locationCursorX = nil,
    locationCursorZ = nil,
    locationCenterX = nil,
    locationCenterZ = nil,
    locationScale = 24,
    locationMapOffset = 0,
    locationPointerStart = nil,
    locationDragging = false,
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
    location = self:locationSnapshot(),
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
  if self.section == "Location" then
    if action == "back" or action == "cancel" then
      if self.locationPage == "map-list" then
        self.locationPage = "grid"
        self.focus = "location:map-picker"
        self:cancelInteraction()
        return { kind = "location-page", page = "grid" }
      end
      return { kind = "back" }
    elseif action == "up" or action == "down" or action == "left" or action == "right" then
      if self.locationPage == "map-list" then
        return { kind = "location-map-move", direction = action }
      end
      if action == "left" or action == "right" then
        return { kind = "location-pan", direction = action }
      end
      return { kind = "location-cursor-move", direction = action }
    elseif action == "confirm" or action == "activate" then
      if self.locationPage == "map-list" then
        local mapId = self.focus:match("^location:map:(%d+)$")
        return mapId and { kind = "location-map-select", mapId = tonumber(mapId) } or nil
      end
      if self.focus == "location:map-picker" then
        self:openLocationMaps()
        return { kind = "location-page", page = "map-list" }
      elseif self.focus == "location:map-back" then
        self.locationPage = "grid"
        self.focus = "location:map-picker"
        return { kind = "location-page", page = "grid" }
      elseif self.focus == "location:zoom-in" then
        self:zoomLocation(1)
        return { kind = "location-zoom", scale = self.locationScale }
      elseif self.focus == "location:zoom-out" then
        self:zoomLocation(-1)
        return { kind = "location-zoom", scale = self.locationScale }
      end
      local fieldX, fieldZ = self.focus:match("^location:tile:(%-?%d+):(%-?%d+)$")
      if fieldX ~= nil then
        return { kind = "select_tile", fieldX = tonumber(fieldX), fieldZ = tonumber(fieldZ) }
      end
      if self.locationCursorX ~= nil and self.locationCursorZ ~= nil then
        return { kind = "select_tile", fieldX = self.locationCursorX, fieldZ = self.locationCursorZ }
      end
      return nil
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
  assert(
    section == "Location" or section == "Player" or section == "Progress" or section == "Party" or section == "Bag"
  )
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
  elseif section == "Location" then
    self.focus = self.locationPage == "map-list" and "location:map-picker" or "location:map-picker"
  else
    self.focus = "flag:" .. (self.focus:match("^flag:(.+)$") or "")
  end
end

function Controller:enterLocation(location)
  assert(type(location) == "table")
  local mapId = location.mapId
  local fieldX, fieldZ = location.fieldX, location.fieldZ
  assert(type(mapId) == "number" and mapId % 1 == 0 and mapId >= 0)
  assert(type(fieldX) == "number" and fieldX % 1 == 0)
  assert(type(fieldZ) == "number" and fieldZ % 1 == 0)
  if self.locationMapId ~= mapId then
    self.locationMapId = mapId
    self.locationPage = "grid"
    self.locationMapOffset = 0
  end
  self.locationCursorX, self.locationCursorZ = fieldX, fieldZ
  self.locationCenterX, self.locationCenterZ = fieldX, fieldZ
  if self.section == "Location" then
    self.focus = "location:map-picker"
  end
end

function Controller:openLocationMaps()
  assert(self.section == "Location")
  self.locationPage = "map-list"
  self.locationMapOffset = 0
  self.focus = "location:map-picker"
  self:cancelInteraction()
end

function Controller:chooseLocationMap(mapId, centerX, centerZ)
  assert(type(mapId) == "number" and mapId % 1 == 0 and mapId >= 0)
  assert(type(centerX) == "number" and centerX % 1 == 0)
  assert(type(centerZ) == "number" and centerZ % 1 == 0)
  self.locationMapId = mapId
  self.locationPage = "grid"
  self.locationCursorX, self.locationCursorZ = centerX, centerZ
  self.locationCenterX, self.locationCenterZ = centerX, centerZ
  self.locationMapOffset = 0
  self.focus = "location:map-picker"
  self:cancelInteraction()
end

function Controller:moveLocationCursor(direction, visibleWidth, visibleHeight)
  assert(direction == "up" or direction == "down" or direction == "left" or direction == "right")
  assert(visibleWidth >= 1 and visibleHeight >= 1)
  if self.locationCursorX == nil or self.locationCursorZ == nil then
    return
  end
  if direction == "left" then
    self.locationCursorX = math.max(0, self.locationCursorX - 1)
  elseif direction == "right" then
    self.locationCursorX = math.min(65535, self.locationCursorX + 1)
  elseif direction == "up" then
    self.locationCursorZ = math.max(0, self.locationCursorZ - 1)
  else
    self.locationCursorZ = math.min(65535, self.locationCursorZ + 1)
  end
  local halfWidth, halfHeight = math.floor(visibleWidth / 2), math.floor(visibleHeight / 2)
  local centerX = self.locationCenterX or self.locationCursorX
  local centerZ = self.locationCenterZ or self.locationCursorZ
  local firstX, firstZ = centerX - halfWidth, centerZ - halfHeight
  if self.locationCursorX < firstX then
    centerX = self.locationCursorX + halfWidth
  elseif self.locationCursorX >= firstX + visibleWidth then
    centerX = self.locationCursorX - halfWidth
  end
  if self.locationCursorZ < firstZ then
    centerZ = self.locationCursorZ + halfHeight
  elseif self.locationCursorZ >= firstZ + visibleHeight then
    centerZ = self.locationCursorZ - halfHeight
  end
  self.locationCenterX = math.max(0, math.min(65535, centerX))
  self.locationCenterZ = math.max(0, math.min(65535, centerZ))
end

function Controller:panLocation(direction, visibleWidth, visibleHeight)
  assert(direction == "up" or direction == "down" or direction == "left" or direction == "right")
  assert(visibleWidth >= 1 and visibleHeight >= 1)
  if self.locationCenterX == nil or self.locationCenterZ == nil then
    return
  end
  local dx = direction == "left" and -1 or direction == "right" and 1 or 0
  local dz = direction == "up" and -1 or direction == "down" and 1 or 0
  self.locationCenterX =
    math.max(0, math.min(65535, self.locationCenterX + dx * math.max(1, math.floor(visibleWidth / 2))))
  self.locationCenterZ =
    math.max(0, math.min(65535, self.locationCenterZ + dz * math.max(1, math.floor(visibleHeight / 2))))
end

function Controller:zoomLocation(delta)
  assert(delta == -1 or delta == 1)
  local scales = { 16, 24, 32 }
  local index = 2
  for candidate, scale in ipairs(scales) do
    if self.locationScale == scale then
      index = candidate
      break
    end
  end
  index = math.max(1, math.min(#scales, index + delta))
  self.locationScale = scales[index]
end

function Controller:locationSnapshot()
  return {
    page = self.locationPage,
    mapId = self.locationMapId,
    cursor = self.locationCursorX and { fieldX = self.locationCursorX, fieldZ = self.locationCursorZ } or nil,
    center = self.locationCenterX and { fieldX = self.locationCenterX, fieldZ = self.locationCenterZ } or nil,
    scale = self.locationScale,
    mapOffset = self.locationMapOffset,
  }
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
    self.locationPointerStart, self.locationDragging = nil, false
    return nil
  end
  if event.type == "pointer_down" then
    self.capturedTarget, self.pointerId = event.targetId, event.pointerId
    if event.targetId ~= nil then
      self.focus = event.targetId
    end
    if self.section == "Location" then
      self.locationPointerStart = {
        x = event.x,
        y = event.y,
        targetId = event.targetId,
        centerX = self.locationCenterX,
        centerZ = self.locationCenterZ,
      }
      self.locationDragging = false
    end
    return nil
  elseif event.type == "pointer_move" then
    local start = self.locationPointerStart
    if self.section ~= "Location" or self.pointerId ~= event.pointerId or start == nil then
      return nil
    end
    local dx, dy = event.x - start.x, event.y - start.y
    if not self.locationDragging and dx * dx + dy * dy >= 36 then
      self.locationDragging = true
    end
    if self.locationDragging then
      local grid = event.grid
      local tileSize = grid and grid.tileSize or self.locationScale
      local shiftX, shiftZ = math.floor(-dx / tileSize), math.floor(-dy / tileSize)
      self.locationCenterX = math.max(0, math.min(65535, (start.centerX or 0) + shiftX))
      self.locationCenterZ = math.max(0, math.min(65535, (start.centerZ or 0) + shiftZ))
    end
    return nil
  elseif event.type == "pointer_up" then
    local target = event.targetId
    if self.pointerId == event.pointerId and self.capturedTarget ~= nil and target == self.capturedTarget then
      self.capturedTarget, self.pointerId = nil, nil
      local start = self.locationPointerStart
      if self.section == "Location" and start ~= nil then
        self.locationPointerStart = nil
        local dragged = self.locationDragging
        self.locationDragging = false
        if dragged then
          return { kind = "location-pan", centerX = self.locationCenterX, centerZ = self.locationCenterZ }
        end
        local fieldX, fieldZ = target:match("^location:tile:(%-?%d+):(%-?%d+)$")
        if fieldX ~= nil then
          self.locationCursorX, self.locationCursorZ = tonumber(fieldX), tonumber(fieldZ)
          return { kind = "select_tile", fieldX = self.locationCursorX, fieldZ = self.locationCursorZ }
        end
        if target == "location:map-picker" then
          self:openLocationMaps()
          return { kind = "location-page", page = "map-list" }
        elseif target == "location:map-back" then
          self.locationPage = "grid"
          self.focus = "location:map-picker"
          return { kind = "location-page", page = "grid" }
        elseif target == "location:zoom-in" or target == "location:zoom-out" then
          self:zoomLocation(target == "location:zoom-in" and 1 or -1)
          return { kind = "location-zoom", scale = self.locationScale }
        end
        local mapId = target:match("^location:map:(%d+)$")
        if mapId ~= nil then
          return { kind = "location-map-select", mapId = tonumber(mapId) }
        end
      end
      return { kind = "activate", targetId = target }
    end
    self.capturedTarget, self.pointerId = nil, nil
    self.locationPointerStart, self.locationDragging = nil, false
  end
  return nil
end

function Controller:cancelInteraction()
  self.capturedTarget, self.pointerId = nil, nil
  self.locationPointerStart, self.locationDragging = nil, false
end

return Controller
