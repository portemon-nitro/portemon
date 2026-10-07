-- Owns editor navigation, modal state, focus, and pointer capture.

local Controller = {}
Controller.__index = Controller

---@class SaveEditorController
---@field section string
---@field modal string?
---@field modalReturnFocus string?
---@field focus string
---@field focusVisible boolean
---@field focusByScope table<string, string?>
---@field focusByRegion table<string, table<string, string>>
---@field capturedTarget string?
---@field pointerId string?
---@field scrollOffset number
---@field query string
---@field partySlot0 integer?
---@field partyTab "Stats"|"Moves"|"Details"
---@field bagPocket string
---@field bagItemKey string?
---@field bagPage0 integer
---@field locationPage "root"|"group"|"grid"
---@field locationFocus "grid"|"map-list"|"navigation"
---@field locationGroupId string?
---@field locationMemory { root: { query: string, cursor: string?, scroll: number }, groups: table<string, { query: string, cursor: string?, scroll: number }> }
---@field locationMapId integer?
---@field locationCursorX integer?
---@field locationCursorZ integer?
---@field locationCenterX integer?
---@field locationCenterZ integer?
---@field locationMapOffset number
---@field locationPointerStart {x: number, y: number, targetId: string?, centerX: integer?, centerZ: integer?, grid: table<string, unknown>?, scrollViewportId: string?, scrollOffset: number?, scopeId: string?, scopeEpoch: integer?}?
---@field locationDragging boolean
---@field scrollOffsets table<string, number>
---@field listCursors table<string, string?>
---@field scopeId string
---@field scopeEpoch integer
---@field pointerScope string?
---@field setSection fun(self: SaveEditorController, section: string)
---@field listCursor fun(self: SaveEditorController, listId: string): string?
---@field setListCursor fun(self: SaveEditorController, listId: string, targetId: string?)
---@field setFocus fun(self: SaveEditorController, targetId: string)
---@field markKeyboardNavigation fun(self: SaveEditorController)
---@field markPointerModality fun(self: SaveEditorController)
---@field rememberRegionFocus fun(self: SaveEditorController, regionId: string, targetId: string)
---@field selectPartySlot fun(self: SaveEditorController, slot0: integer)
---@field selectPartyTab fun(self: SaveEditorController, tab: "Stats"|"Moves"|"Details")
---@field stepPartyTab fun(self: SaveEditorController, direction: "previous"|"next"): string?
---@field selectBagPocket fun(self: SaveEditorController, pocket: string)
---@field setBagPage fun(self: SaveEditorController, page0: integer)
---@field selectBagItem fun(self: SaveEditorController, itemKey: string)
---@field enterLocation fun(self: SaveEditorController, location: table<string, unknown>)
---@field openLocationMaps fun(self: SaveEditorController)
---@field enterLocationGroup fun(self: SaveEditorController, groupId: string, carriedQuery: string?)
---@field backLocation fun(self: SaveEditorController): boolean
---@field rememberLocationDestination fun(self: SaveEditorController, groupId: string, mapTargetId: string)
---@field chooseLocationMap fun(self: SaveEditorController, mapId: integer, centerX: integer, centerZ: integer)
---@field moveLocationCursor fun(self: SaveEditorController, direction: string, visibleWidth: integer, visibleHeight: integer)
---@field panLocation fun(self: SaveEditorController, direction: string, visibleWidth: integer, visibleHeight: integer)
---@field setLocationCursor fun(self: SaveEditorController, fieldX: integer, fieldZ: integer)
---@field locationSnapshot fun(self: SaveEditorController): table<string, unknown>
---@field snapshot fun(self: SaveEditorController): table<string, unknown>
---@field press fun(self: SaveEditorController, action: string): table<string, unknown>?
---@field openModal fun(self: SaveEditorController, kind: string)
---@field closeModal fun(self: SaveEditorController): string?
---@field pointer fun(self: SaveEditorController, event: table<string, unknown>): table<string, unknown>?
---@field cancelInteraction fun(self: SaveEditorController)

function Controller.new()
  return setmetatable({
    section = "Player",
    modal = nil,
    modalReturnFocus = nil,
    focus = "money",
    focusVisible = false,
    focusByScope = {},
    focusByRegion = {},
    capturedTarget = nil,
    pointerId = nil,
    scrollOffset = 0,
    query = "",
    partySlot0 = nil,
    partyTab = "Stats",
    bagPocket = "items",
    bagItemKey = nil,
    bagPage0 = 0,
    locationPage = "root",
    locationFocus = "map-list",
    locationGroupId = nil,
    locationMemory = { root = { query = "", cursor = nil, scroll = 0 }, groups = {} },
    locationMapId = nil,
    locationCursorX = nil,
    locationCursorZ = nil,
    locationCenterX = nil,
    locationCenterZ = nil,
    locationMapOffset = 0,
    locationPointerStart = nil,
    locationDragging = false,
    scrollOffsets = {},
    listCursors = {},
    scopeId = "section:Player",
    scopeEpoch = 0,
  }, Controller)
end

function Controller:snapshot()
  return {
    section = self.section,
    modal = self.modal,
    focus = self.focus,
    focusVisible = self.focusVisible,
    scrollOffset = self.scrollOffset,
    query = self.query,
    sections = { "Location", "Player", "Party", "Bag", "Progress" },
    partySlot0 = self.partySlot0,
    partyTab = self.partyTab,
    bagPocket = self.bagPocket,
    bagItemKey = self.bagItemKey,
    bagPage0 = self.bagPage0,
    location = self:locationSnapshot(),
    scope = {
      id = self.scopeId,
      epoch = self.scopeEpoch,
      kind = self.modal and "decision" or "section",
      focusId = self.focus,
    },
    scrollOffsets = self.scrollOffsets,
  }
end

function Controller:press(action)
  if self.modal then
    if action == "cancel" or action == "back" then
      local modal = self.modal
      self.modal = nil
      local returnFocus = self.modalReturnFocus
      self.modalReturnFocus = nil
      if returnFocus ~= nil then
        self:setFocus(returnFocus)
      end
      return { kind = "cancel", modal = modal, returnFocus = returnFocus }
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
  end
  return nil
end

function Controller:openModal(kind)
  self.modalReturnFocus = self.focus
  self.modal = kind
  self:setFocus("cancel")
end

function Controller:closeModal()
  local returnFocus = self.modalReturnFocus
  self.modal, self.modalReturnFocus = nil, nil
  if returnFocus ~= nil then
    self:setFocus(returnFocus)
  end
  return returnFocus
end

function Controller:setSection(section)
  assert(
    section == "Location" or section == "Player" or section == "Progress" or section == "Party" or section == "Bag"
  )
  if section == self.section then
    return
  end
  if self.section == "Location" then
    self:_rememberLocationLevel()
  end
  self.section = section
  self:closeModal()
  self.capturedTarget, self.pointerId = nil, nil
  if section == "Party" then
    self.partyTab = "Stats"
    self.partySlot0 = nil
    self:setFocus("party:slot:0")
  elseif section == "Bag" then
    self:setFocus("bag:pocket:" .. self.bagPocket)
  elseif section == "Player" then
    self:setFocus("money")
  elseif section == "Location" then
    local memory = self.locationMemory.root
    self.locationPage = "root"
    self.locationGroupId = nil
    self.locationFocus = "map-list"
    self.query = memory.query
    self.locationMapOffset = memory.scroll
    self.scrollOffset = memory.scroll
    self:setFocus(memory.cursor or "list:location:root")
  else
    self:setFocus("list:flags")
  end
end

---@param listId string
---@return string? targetId
function Controller:listCursor(listId)
  assert(type(listId) == "string" and listId ~= "", "list cursor identity needs a non-empty list id")
  return self.listCursors[listId]
end

---@param listId string
---@param targetId string?
function Controller:setListCursor(listId, targetId)
  assert(type(listId) == "string" and listId ~= "", "list cursor identity needs a non-empty list id")
  assert(targetId == nil or (type(targetId) == "string" and targetId ~= ""), "list cursor is a row target or nil")
  if targetId == nil then
    self.listCursors[listId] = nil
  else
    self.listCursors[listId] = targetId
  end
end

function Controller:enterLocation(location)
  assert(type(location) == "table")
  local mapId = location.mapId
  local fieldX, fieldZ = location.fieldX, location.fieldZ
  assert(type(mapId) == "number" and mapId % 1 == 0 and mapId >= 0)
  assert(type(fieldX) == "number" and fieldX % 1 == 0)
  assert(type(fieldZ) == "number" and fieldZ % 1 == 0)
  local changed = self.locationMapId ~= mapId
  self.locationMapId = mapId
  if changed then
    self.locationMapOffset = 0
  end
  self.locationCursorX, self.locationCursorZ = fieldX, fieldZ
  self.locationCenterX, self.locationCenterZ = fieldX, fieldZ
  if changed or self.section ~= "Location" then
    if self.locationPage == "grid" then
      self:_rememberLocationLevel()
    end
    self.locationPage = "root"
    self.locationGroupId = nil
    self.locationFocus = "map-list"
  end
  if self.section == "Location" and self.locationPage == "root" then
    self:setFocus("list:location:root")
  end
end

function Controller:openLocationMaps()
  assert(self.section == "Location")
  if self.locationPage == "grid" then
    self:backLocation()
    return
  end
  self.locationPage = "root"
  self.locationGroupId = nil
  local memory = self.locationMemory.root
  self.query = memory.query
  self.locationMapOffset = memory.scroll
  self:setFocus(memory.cursor or "list:location:root")
  self:cancelInteraction()
end

function Controller:rememberLocationDestination(groupId, mapTargetId)
  assert(type(groupId) == "string" and groupId ~= "")
  assert(type(mapTargetId) == "string" and mapTargetId ~= "")
  if self.locationMemory.root.cursor == nil then
    self.locationMemory.root.cursor = groupId
  end
  if self.locationMemory.groups[groupId] == nil then
    self.locationMemory.groups[groupId] = { query = "", cursor = mapTargetId, scroll = 0 }
  elseif self.locationMemory.groups[groupId].cursor == nil then
    self.locationMemory.groups[groupId].cursor = mapTargetId
  end
  if self.section == "Location" and self.locationPage == "root" and self.focus == "list:location:root" then
    self:setFocus(self.locationMemory.root.cursor)
  end
end

function Controller:_rememberLocationLevel()
  local memory
  local listId
  if self.locationPage == "root" then
    memory = self.locationMemory.root
    listId = "location:root"
  elseif self.locationPage == "group" then
    local groupId = assert(self.locationGroupId, "a map group page owns its group identity")
    self.locationMemory.groups[groupId] = self.locationMemory.groups[groupId]
      or { query = "", cursor = nil, scroll = 0 }
    memory = self.locationMemory.groups[groupId]
    listId = groupId
  else
    return
  end
  memory.query = self.query
  memory.cursor = self.focus
  memory.scroll = self.scrollOffset
  if self.listCursors[listId] ~= nil then
    memory.cursor = self.listCursors[listId]
  end
end

function Controller:_restoreLocationLevel(memory, listId)
  self.query = memory.query
  self.locationMapOffset = memory.scroll
  self.scrollOffset = memory.scroll
  self.focus = memory.cursor or ("list:" .. listId)
  self.focusByScope[self.scopeId] = self.focus
end

function Controller:enterLocationGroup(groupId, carriedQuery)
  assert(self.section == "Location", "map sections are entered from Location")
  assert(type(groupId) == "string" and groupId ~= "", "map section identity is stable")
  if self.locationPage == "group" and self.locationGroupId == groupId then
    return
  end
  if self.locationPage == "root" or self.locationPage == "group" then
    self:_rememberLocationLevel()
  end
  local memory = self.locationMemory.groups[groupId]
  if carriedQuery ~= nil then
    memory = { query = carriedQuery, cursor = nil, scroll = 0 }
    self.locationMemory.groups[groupId] = memory
  elseif memory == nil then
    memory = { query = "", cursor = nil, scroll = 0 }
    self.locationMemory.groups[groupId] = memory
  end
  self.locationPage = "group"
  self.locationGroupId = groupId
  self.locationFocus = "map-list"
  self.query = memory.query
  self.locationMapOffset = memory.scroll
  self.scrollOffset = memory.scroll
  self.focus = memory.cursor or ("list:" .. groupId)
  self.focusByScope[self.scopeId] = self.focus
  self:cancelInteraction()
end

function Controller:backLocation()
  assert(self.section == "Location", "Location Back requires its active section")
  if self.locationPage == "grid" then
    self:_rememberLocationLevel()
    local groupId = self.locationGroupId
    if groupId ~= nil then
      self.locationPage = "group"
      self:_restoreLocationLevel(assert(self.locationMemory.groups[groupId]), groupId)
    else
      self.locationPage = "root"
      self:_restoreLocationLevel(self.locationMemory.root, "location:root")
    end
    self.locationFocus = "map-list"
    self:cancelInteraction()
    return true
  elseif self.locationPage == "group" then
    self:_rememberLocationLevel()
    self.locationPage = "root"
    self.locationGroupId = nil
    self:_restoreLocationLevel(self.locationMemory.root, "location:root")
    self.locationFocus = "map-list"
    self:cancelInteraction()
    return true
  end
  return false
end

function Controller:chooseLocationMap(mapId, centerX, centerZ)
  assert(type(mapId) == "number" and mapId % 1 == 0 and mapId >= 0)
  assert(type(centerX) == "number" and centerX % 1 == 0)
  assert(type(centerZ) == "number" and centerZ % 1 == 0)
  if self.locationPage == "group" then
    self:_rememberLocationLevel()
  end
  self.locationMapId = mapId
  self.locationPage = "grid"
  self.locationCursorX, self.locationCursorZ = centerX, centerZ
  self.locationCenterX, self.locationCenterZ = centerX, centerZ
  self.locationMapOffset = 0
  self:setFocus("location:grid")
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

function Controller:setLocationCursor(fieldX, fieldZ)
  assert(type(fieldX) == "number" and fieldX % 1 == 0)
  assert(type(fieldZ) == "number" and fieldZ % 1 == 0)
  self.locationCursorX, self.locationCursorZ = fieldX, fieldZ
  self.locationCenterX, self.locationCenterZ = fieldX, fieldZ
end

function Controller:locationSnapshot()
  return {
    page = self.locationPage,
    groupId = self.locationGroupId,
    contentFocus = self.locationFocus,
    mapId = self.locationMapId,
    cursor = self.locationCursorX and { fieldX = self.locationCursorX, fieldZ = self.locationCursorZ } or nil,
    center = self.locationCenterX and { fieldX = self.locationCenterX, fieldZ = self.locationCenterZ } or nil,
    mapOffset = self.locationMapOffset,
  }
end

function Controller:markKeyboardNavigation()
  self.focusVisible = true
end

function Controller:markPointerModality()
  self.focusVisible = false
end

function Controller:rememberRegionFocus(regionId, targetId)
  assert(type(regionId) == "string" and regionId ~= "")
  assert(type(targetId) == "string" and targetId ~= "")
  local remembered = self.focusByRegion[self.scopeId]
  if remembered == nil then
    remembered = {}
    self.focusByRegion[self.scopeId] = remembered
  end
  remembered[regionId] = targetId
end

function Controller:setFocus(targetId)
  assert(type(targetId) == "string" and targetId ~= "")
  self.focus = targetId
  self.focusByScope[self.scopeId] = targetId
  if self.section == "Location" then
    if targetId == "location:grid" or targetId:match("^location:tile:") then
      self.locationFocus = "grid"
    elseif
      targetId:match("^location:map:")
      or targetId:match("^location:group:")
      or targetId:match("^list:location:")
    then
      self.locationFocus = "map-list"
    elseif targetId:match("^section:") then
      self.locationFocus = "navigation"
    end
  end
end

local PARTY_TABS = { Stats = "Moves", Moves = "Details" }
local PARTY_TABS_REVERSE = { Moves = "Stats", Details = "Moves" }

function Controller:selectPartySlot(slot0)
  assert(type(slot0) == "number" and slot0 % 1 == 0 and slot0 >= 0 and slot0 < 6)
  self.partySlot0 = slot0
  self:setFocus("party:slot:" .. slot0)
  self:cancelInteraction()
end

function Controller:selectPartyTab(tab)
  assert(tab == "Stats" or tab == "Moves" or tab == "Details", "unknown party page: " .. tostring(tab))
  self.partyTab = tab
  self:cancelInteraction()
end

---@param direction "previous"|"next"
---@return string? stepped the newly selected page, or nil at a disabled end
function Controller:stepPartyTab(direction)
  assert(direction == "previous" or direction == "next")
  local tabs = direction == "next" and PARTY_TABS or PARTY_TABS_REVERSE
  local stepped = tabs[self.partyTab]
  if stepped ~= nil then
    self.partyTab = stepped
    self:setFocus(direction == "next" and "party:page:next" or "party:page:previous")
  end
  self:cancelInteraction()
  return stepped
end

function Controller:selectBagPocket(pocket)
  assert(type(pocket) == "string" and pocket ~= "")
  self.bagPocket = pocket
  self.bagItemKey = nil
  self.bagPage0 = 0
  self:setFocus("bag:pocket:" .. pocket)
  self:cancelInteraction()
end

function Controller:setBagPage(page0)
  assert(type(page0) == "number" and page0 % 1 == 0 and page0 >= 0)
  self.bagPage0 = page0
  self:cancelInteraction()
end

function Controller:selectBagItem(itemKey)
  assert(type(itemKey) == "string" and itemKey ~= "")
  self.bagItemKey = itemKey
  self:setFocus("bag:item:" .. itemKey)
  self:cancelInteraction()
end

function Controller:pointer(event)
  if event.type == "pointer_cancel" then
    self:cancelInteraction()
    return nil
  end
  if event.type == "pointer_down" then
    if
      event.x == nil
      or event.y == nil
      or (event.targetId == nil and event.scrollViewportId == nil and event.grid == nil)
    then
      self:cancelInteraction()
      return nil
    end
    if event.scopeId ~= nil and event.scopeId ~= self.scopeId then
      return nil
    end
    self.focusVisible = false
    self.capturedTarget, self.pointerId = event.targetId, event.pointerId
    self.capturedScopeEpoch = event.scopeEpoch
    self.pointerScope = table.concat({ self.modal or "", self.section, self.partyTab, self.locationPage }, ":")
    if event.targetId ~= nil then
      self:setFocus(event.targetId)
      if event.targetId == "location:grid" or event.targetId:match("^location:tile:") then
        self:setFocus(event.targetId)
      elseif event.targetId:match("^location:map:") then
        self:setFocus(event.targetId)
      else
        self.focusByScope[self.scopeId] = event.targetId
      end
    end
    self.locationPointerStart = {
      x = event.x,
      y = event.y,
      targetId = event.targetId,
      centerX = self.locationCenterX,
      centerZ = self.locationCenterZ,
      grid = event.grid,
      scrollViewportId = event.scrollViewportId,
      scrollOffset = event.scrollOffset,
      scopeId = event.scopeId,
      scopeEpoch = event.scopeEpoch,
    }
    self.locationDragging = false
    return nil
  elseif event.type == "pointer_move" then
    local start = self.pointerId == event.pointerId and self.locationPointerStart or nil
    if start == nil or event.x == nil or event.y == nil then
      return nil
    end
    local dx, dy = event.x - start.x, event.y - start.y
    if
      (event.scopeId ~= nil and event.scopeId ~= start.scopeId)
      or (event.scopeEpoch ~= nil and event.scopeEpoch ~= start.scopeEpoch)
    then
      self:cancelInteraction()
      return nil
    end
    if not self.locationDragging and dx * dx + dy * dy >= 36 then
      self.locationDragging = true
    end
    if self.locationDragging then
      if start.scrollViewportId ~= nil then
        return {
          kind = "scroll-drag",
          viewportId = start.scrollViewportId,
          offset = assert(start.scrollOffset) - dy,
          scopeId = start.scopeId,
          scopeEpoch = start.scopeEpoch,
        }
      elseif start.grid ~= nil then
        local tileSize = start.grid.tileSize or 16
        local shiftX, shiftZ = math.floor(-dx / tileSize), math.floor(-dy / tileSize)
        self.locationCenterX = math.max(0, math.min(65535, (start.centerX or 0) + shiftX))
        self.locationCenterZ = math.max(0, math.min(65535, (start.centerZ or 0) + shiftZ))
      end
    end
    return nil
  elseif event.type == "pointer_up" then
    local target = event.targetId
    local currentScope = table.concat({ self.modal or "", self.section, self.partyTab, self.locationPage }, ":")
    if self.pointerScope ~= nil and self.pointerScope ~= currentScope then
      self:cancelInteraction()
      return nil
    end
    if self.pointerId ~= event.pointerId then
      return nil
    end
    if
      (event.scopeId ~= nil and event.scopeId ~= self.scopeId)
      or (event.scopeEpoch ~= nil and event.scopeEpoch ~= self.capturedScopeEpoch)
    then
      self:cancelInteraction()
      return nil
    end
    local start = self.locationPointerStart
    local dragged = self.locationDragging
    local capturedTarget = self.capturedTarget
    self.capturedTarget, self.pointerId = nil, nil
    self.locationPointerStart, self.locationDragging = nil, false
    if dragged then
      if start ~= nil and start.grid ~= nil then
        return { kind = "location-pan", centerX = self.locationCenterX, centerZ = self.locationCenterZ }
      end
      return nil
    end
    if target == nil or capturedTarget == nil or target ~= capturedTarget then
      return nil
    end
    if start ~= nil and self.section == "Location" then
      local fieldX, fieldZ = target:match("^location:tile:(%-?%d+):(%-?%d+)$")
      if fieldX ~= nil then
        self:setFocus("location:grid")
        self.locationCursorX, self.locationCursorZ = tonumber(fieldX), tonumber(fieldZ)
        return { kind = "select_tile", fieldX = self.locationCursorX, fieldZ = self.locationCursorZ }
      end
      local mapId = target:match("^location:map:(%d+)$")
      if mapId ~= nil then
        return { kind = "location-map-select", mapId = tonumber(mapId) }
      end
    end
    return { kind = "activate", targetId = target }
  end
  return nil
end

function Controller:cancelInteraction()
  self.capturedTarget, self.pointerId = nil, nil
  self.capturedScopeEpoch = nil
  self.pointerScope = nil
  self.locationPointerStart, self.locationDragging = nil, false
end

return Controller
