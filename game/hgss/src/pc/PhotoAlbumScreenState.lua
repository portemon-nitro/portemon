-- Owns the retained Photo Album selection and private viewer child.

local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local PhotoScene = require("game.hgss.src.pc.PhotoScene")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local PhotoAlbumInterface = require("game.hgss.src.pc.PhotoAlbumInterface")

local PhotoAlbumScreenState = {}
PhotoAlbumScreenState.__index = PhotoAlbumScreenState
---@class PhotoAlbumScreenState

local ACTIONS = { "view", "delete", "move", "cancel" }

local function occupied(album)
  local result = {}
  for slot = 0, PhotoAlbum.CAPACITY - 1 do
    if album:get(slot) ~= nil then
      result[#result + 1] = slot
    end
  end
  return result
end

local function copyRecord(value)
  local copy = {}
  for key, child in pairs(value) do
    if type(child) == "table" then
      local nested = {}
      for nestedKey, nestedValue in pairs(child) do
        if type(nestedValue) == "table" then
          local row = {}
          for k, v in pairs(nestedValue) do
            row[k] = v
          end
          nested[nestedKey] = row
        else
          nested[nestedKey] = nestedValue
        end
      end
      copy[key] = nested
    else
      copy[key] = child
    end
  end
  return copy
end

---@param options table<string, unknown>
---@return PhotoAlbumScreenState
function PhotoAlbumScreenState.new(options)
  assert(type(options) == "table", "Photo Album screen requires options")
  assert(type(options.album) == "table", "Photo Album screen requires its persisted album owner")
  assert(type(options.manifest) == "table", "Photo Album screen requires C02 visual assets")
  assert(type(options.measureDisplay) == "function", "Photo Album screen requires display measurement")
  local self = setmetatable({
    album = options.album,
    manifest = options.manifest,
    measureDisplay = options.measureDisplay,
    profile = options.profile,
    createScene = options.createScene or function(_)
      return PhotoScene.new({
        versionId = options.versionId,
        derivedAssets = options.derivedAssets,
        profile = options.profile,
        monCatalog = options.monCatalog,
        cacheFs = options.cacheFs,
        createScene = options.createScene,
      })
    end,
    phase = "list",
    selectedSlot = occupied(options.album)[1],
    actionIndex = 1,
    animationTick = 0,
    viewer = nil,
    viewerView = nil,
    deleteChoice = "yes",
    moveSourceSlot = nil,
    resultMessageId = nil,
    closed = false,
    resultTaken = false,
    disposed = false,
  }, PhotoAlbumScreenState)
  self.presentation = ApplicationPresentation.new(PhotoAlbumInterface.defaults(options.manifest), options.overrides)
  return self
end

local function indexOf(slots, selected)
  for index, slot in ipairs(slots) do
    if slot == selected then
      return index
    end
  end
end

function PhotoAlbumScreenState:_moveSlot(direction)
  local slots = occupied(self.album)
  if #slots == 0 then
    self.selectedSlot = nil
    return
  end
  local index = indexOf(slots, self.selectedSlot) or 1
  local delta = (direction == "left" or direction == "up") and -1 or 1
  index = ((index - 1 + delta) % #slots) + 1
  self.selectedSlot = slots[index]
end

function PhotoAlbumScreenState:_moveViewer(direction)
  local slots = occupied(self.album)
  local index = indexOf(slots, self.selectedSlot)
  if index == nil then
    return
  end
  local nextIndex = index + (direction == "left" and -1 or 1)
  local nextSlot = slots[nextIndex]
  if nextSlot == nil then
    return
  end
  self.viewer:cancel()
  self.viewer:dispose()
  self.selectedSlot = nextSlot
  self:_openViewer()
end

function PhotoAlbumScreenState:_openViewer()
  local record = assert(self.album:get(assert(self.selectedSlot)))
  local scene = self.createScene(copyRecord(record), self.selectedSlot)
  scene:request(record)
  self.viewer = scene
  self.viewerView = nil
  self.phase = "viewer"
  self:_adoptReady()
end

function PhotoAlbumScreenState:_closeViewer()
  if self.viewer then
    self.viewer:cancel()
    self.viewer:dispose()
  end
  self.viewer, self.viewerView = nil, nil
  self.phase = "list"
end

function PhotoAlbumScreenState:_deleteSelected()
  local slot = assert(self.selectedSlot)
  local revision = self.album:revision()
  local change, err = self.album:prepareChanges(revision, { { slot = slot, value = false } })
  assert(change, "photo album changed during confirmed deletion: " .. tostring(err))
  change.publish()
  local slots = occupied(self.album)
  self.selectedSlot = slots[math.min(indexOf(slots, slot) or #slots, #slots)]
  self.phase = "list"
end

function PhotoAlbumScreenState:_moveSelected()
  local sourceSlot = assert(self.moveSourceSlot)
  local targetSlot = assert(self.selectedSlot)
  if sourceSlot ~= targetSlot then
    local sourcePhoto = assert(self.album:get(sourceSlot))
    local targetPhoto = assert(self.album:get(targetSlot))
    local revision = self.album:revision()
    local change, err = self.album:prepareChanges(revision, {
      { slot = sourceSlot, value = targetPhoto },
      { slot = targetSlot, value = sourcePhoto },
    })
    assert(change, "photo album changed during move: " .. tostring(err))
    change.publish()
  end
  self.selectedSlot = targetSlot
  self.moveSourceSlot = nil
  self.resultMessageId = 8
  self.phase = "list"
end

function PhotoAlbumScreenState:_selectAction(action)
  self.actionIndex = indexOf(ACTIONS, action) or self.actionIndex
  if action == "view" then
    self:_openViewer()
  elseif action == "delete" then
    self.deleteChoice, self.phase = "yes", "delete_confirm"
  elseif action == "move" then
    self.moveSourceSlot, self.phase = assert(self.selectedSlot), "move_target"
  else
    self.phase = "list"
  end
end

function PhotoAlbumScreenState:updateFixed(events)
  assert(not self.disposed, "disposed Photo Album cannot update")
  if self.closed then
    return
  end
  self.animationTick = self.animationTick + 1
  if #events > 0 then
    self.resultMessageId = nil
  end
  local view = self:_view()
  view.presentation = self.presentation:resolve(self.measureDisplay(), view)
  events = self.presentation:mapInput(events, view)
  for _, event in ipairs(events) do
    if self.phase == "list" then
      if event.type == "cancel" then
        self.closed = true
        return
      elseif event.type == "navigate" then
        self:_moveSlot(event.direction)
      elseif event.type == "confirm" and self.selectedSlot ~= nil then
        self.actionIndex, self.phase = 1, "actions"
      elseif event.type == "activate" and event.target == "photo" then
        if self.selectedSlot == event.slot then
          self.actionIndex, self.phase = 1, "actions"
        else
          self.selectedSlot = event.slot
        end
      end
    elseif self.phase == "actions" then
      if event.type == "navigate" then
        local delta = (event.direction == "up" or event.direction == "left") and -1 or 1
        self.actionIndex = ((self.actionIndex - 1 + delta) % #ACTIONS) + 1
      elseif event.type == "confirm" then
        self:_selectAction(ACTIONS[self.actionIndex])
      elseif event.type == "cancel" then
        self.phase = "list"
      elseif event.type == "activate" and event.target == "action" then
        self:_selectAction(event.action)
      end
    elseif self.phase == "delete_confirm" then
      if event.type == "navigate" then
        self.deleteChoice = self.deleteChoice == "yes" and "no" or "yes"
      elseif event.type == "confirm" then
        if self.deleteChoice == "yes" then
          self:_deleteSelected()
        else
          self.phase = "list"
        end
      elseif event.type == "cancel" then
        self.phase = "list"
      elseif event.type == "activate" and event.target == "delete-choice" then
        self.deleteChoice = event.choice
        if self.deleteChoice == "yes" then
          self:_deleteSelected()
        else
          self.phase = "list"
        end
      end
    elseif self.phase == "move_target" then
      if event.type == "navigate" then
        self:_moveSlot(event.direction)
      elseif event.type == "confirm" and self.selectedSlot ~= nil then
        self:_moveSelected()
      elseif event.type == "cancel" then
        self.moveSourceSlot = nil
        self.phase = "list"
      elseif event.type == "activate" and event.target == "photo" then
        if self.selectedSlot == event.slot then
          self:_moveSelected()
        else
          self.selectedSlot = event.slot
        end
      end
    elseif self.phase == "viewer" then
      if event.type == "cancel" then
        self:_closeViewer()
      elseif event.type == "navigate" and (event.direction == "right" or event.direction == "left") then
        self:_moveViewer(event.direction)
      elseif event.type == "activate" and event.target == "viewer" then
        if event.action == "back" then
          self:_closeViewer()
        elseif event.action == "previous" then
          self:_moveViewer("left")
        elseif event.action == "next" then
          self:_moveViewer("right")
        end
      end
    end
  end
end

function PhotoAlbumScreenState:takeResult()
  if not self.closed or self.resultTaken then
    return nil
  end
  self.resultTaken = true
  return { kind = "closed" }
end

function PhotoAlbumScreenState:advance(ticks)
  if self.disposed or self.phase ~= "viewer" then
    return
  end
  self.viewer:advance(ticks)
  self:_adoptReady()
end

function PhotoAlbumScreenState:_adoptReady()
  local status = self.viewer:status()
  if status.phase == "ready" and self.viewerView == nil then
    self.viewerView = self.viewer:takeReady()
  elseif status.phase == "failed" then
    self.failure = status.failure
  end
end

function PhotoAlbumScreenState:_view()
  assert(not self.disposed, "disposed Photo Album has no status")
  local slots = occupied(self.album)
  local viewer
  if self.phase == "viewer" then
    local child = self.viewer:status()
    viewer = { phase = child.phase }
    if self.viewerView then
      viewer.view = self.viewerView
    end
    if child.failure then
      viewer.failure = child.failure
    end
  end
  local visiblePhotos = {}
  local selectedIndex = indexOf(slots, self.selectedSlot) or 1
  local firstIndex = math.floor((selectedIndex - 1) / 12) * 12 + 1
  for index = firstIndex, math.min(firstIndex + 11, #slots) do
    local slot = slots[index]
    visiblePhotos[#visiblePhotos + 1] = { slot = slot, photo = copyRecord(assert(self.album:get(slot))) }
  end
  return {
    phase = self.phase,
    occupiedSlots = slots,
    selectedSlot = self.selectedSlot,
    selectedIndex = self.selectedSlot and (indexOf(slots, self.selectedSlot) or 1) or 0,
    selectedPhoto = self.selectedSlot and copyRecord(assert(self.album:get(self.selectedSlot))) or nil,
    visiblePhotos = visiblePhotos,
    animationTick = self.animationTick,
    selectedAction = self.phase == "actions" and ACTIONS[self.actionIndex] or nil,
    sourceMessageId = self.phase == "list" and self.resultMessageId
      or self.phase == "actions" and 6
      or self.phase == "move_target" and 7
      or self.phase == "delete_confirm" and 9
      or self.phase == "list" and #slots == 0 and 5
      or nil,
    viewer = viewer,
    deleteChoice = self.deleteChoice,
    failure = self.failure,
  }
end

function PhotoAlbumScreenState:status()
  local view = self:_view()
  view.presentation = self.presentation:resolve(self.measureDisplay(), view)
  return view
end

function PhotoAlbumScreenState:draw(resources, status)
  assert(not self.disposed, "disposed Photo Album cannot draw")
  local snapshot = status or self:status()
  ApplicationPresentation.draw(assert(love.graphics), resources, snapshot, snapshot.presentation)
end

function PhotoAlbumScreenState:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  if self.viewer then
    self.viewer:cancel()
    self.viewer:dispose()
    self.viewer = nil
  end
  self.presentation:dispose()
end

return PhotoAlbumScreenState
