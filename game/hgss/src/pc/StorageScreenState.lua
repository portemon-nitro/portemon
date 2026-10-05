-- Per-open Storage interaction and child lifetime owner.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local PcStorageActions = require("libs.hgss.src.field.PcStorageActions")
local StorageInterface = require("game.hgss.src.pc.StorageInterface")

---@class StorageScreenState
---@field _mode integer
---@field _mons HgssMonService
---@field _bag HgssBagService
---@field _actions PcStorageActions
---@field _manifest table<string, unknown>
---@field _measureDisplay fun(): DisplayMeasurement
---@field _session ApplicationPresentation
---@field _activeBox integer
---@field _focus table<string, unknown>
---@field _carry table<string, unknown>?
---@field _menu { actions: string[], selected: integer, address: table<string, unknown> }?
---@field _editor table<string, unknown>?
---@field _child table<string, unknown>?
---@field _childKind string?
---@field _childRequest table<string, unknown>?
---@field _pendingIntent table<string, unknown>?
---@field _children table<string, fun(request: table<string, unknown>): table<string, unknown>>
---@field _releaseCheck table<string, unknown>?
---@field _releaseIntent table<string, unknown>?
---@field _releaseRevisions table<string, integer>?
---@field _transitionTick integer
---@field _closed boolean
---@field _resultTaken boolean
---@field _disposed boolean
---@field _state string
local StorageScreenState = {}
StorageScreenState.__index = StorageScreenState

local COMPILED_BOX_NAME_COUNT = 18

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

function StorageScreenState.new(options)
  assert(type(options) == "table", "Storage opens with concrete collaborators")
  assert(
    type(options.mode) == "number" and options.mode % 1 == 0 and options.mode >= 0 and options.mode <= 3,
    "Storage mode is one of the retail modes"
  )
  assert(options.mons ~= nil and options.bag ~= nil, "Storage borrows the live mon and Bag services")
  assert(type(options.measureDisplay) == "function", "Storage reads current display measurement")
  local manifest = assert(options.manifest, "Storage borrows its compiled manifest")
  local self = setmetatable({
    _mode = options.mode,
    _mons = options.mons,
    _bag = options.bag,
    _actions = PcStorageActions.new({ mons = options.mons, bag = options.bag }),
    _manifest = manifest,
    _measureDisplay = options.measureDisplay,
    _audio = options.audio,
    _icons = options.icons,
    _portraits = options.portraits,
    _children = options.childFactories or {},
    _activeBox = options.mons:activeBox(),
    _focus = { domain = options.mode == 1 and "box" or "party", slot = 0 },
    _carry = nil,
    _menu = nil,
    _editor = nil,
    _child = nil,
    _childKind = nil,
    _childRequest = nil,
    _releaseCheck = nil,
    _releaseIntent = nil,
    _releaseRevisions = nil,
    _transitionTick = 0,
    _closed = false,
    _resultTaken = false,
    _disposed = false,
    _state = "browse",
  }, StorageScreenState)
  self._session = ApplicationPresentation.new(StorageInterface.defaults(manifest), options.overrides)
  self:_resolve()
  return self
end

function StorageScreenState:_view()
  local metadata = self._mons:boxMetadata(self._activeBox)
  local boxSlots, party = {}, {}
  for slot = 0, 29 do
    local mon = self._mons:boxMon(self._activeBox, slot)
    if mon ~= nil then
      mon.iconKey = self._mons:catalog():iconSelection(mon)
      mon.itemIconKey = self._bag:catalog():item(mon.heldItem).icon
    end
    boxSlots[slot + 1] = mon or false
  end
  for slot = 0, self._mons:partyCount() - 1 do
    local mon = self._mons:partyMon(slot)
    mon.iconKey = self._mons:catalog():iconSelection(mon)
    mon.itemIconKey = self._bag:catalog():item(mon.heldItem).icon
    party[slot + 1] = mon
  end
  return {
    mode = self._mode,
    state = self._state,
    activeBox = self._activeBox,
    wallpaperId = metadata.wallpaperId,
    boxName = metadata.name or self:_defaultBoxName(),
    boxSlots = boxSlots,
    party = party,
    focus = copy(self._focus),
    carry = copy(self._carry),
    menu = copy(self._menu),
    editor = copy(self._editor),
    wallpaperUnlocks = self._mons:boxSnapshot().bonusUnlocks,
  }
end

function StorageScreenState:_defaultBoxName()
  local storage = assert(self._manifest.storage, "Storage borrows its compiled storage manifest")
  local boxNames = assert(storage.boxNames, "Storage manifest carries source box names")
  if self._activeBox < COMPILED_BOX_NAME_COUNT then
    return assert(boxNames[self._activeBox + 1], "Storage manifest carries every compiled box name")
  end
  local format = assert(storage.expansionNameFormat, "Storage manifest carries its expansion name format")
  return format.prefix .. tostring(format.firstNumber + self._activeBox) .. format.suffix
end

function StorageScreenState:_address(target)
  if target.domain == "party" or target.kind == "party" then
    return { kind = "party", slot = target.slot }
  end
  return { kind = "box", box = self._activeBox, slot = target.slot }
end

function StorageScreenState:_monVisual(address)
  local mon = address.kind == "party" and self._mons:partyMon(address.slot)
    or self._mons:boxMon(address.box, address.slot)
  if mon == nil then
    return nil
  end
  mon.iconKey = self._mons:catalog():iconSelection(mon)
  mon.itemIconKey = self._bag:catalog():item(mon.heldItem).icon
  return mon
end

function StorageScreenState:_openMenu()
  local address = self:_address(self._focus)
  local mon = address.kind == "party" and self._mons:partyMon(address.slot)
    or self._mons:boxMon(address.box, address.slot)
  if mon == nil and address.kind == "party" then
    self._menu = nil
    return
  end
  local actions
  if self._mode == 0 then
    actions = address.kind == "party" and { "deposit", "summary", "markings" }
      or { "summary", "markings", "wallpaper", "boxName" }
  elseif self._mode == 1 then
    actions = address.kind == "box"
        and (mon ~= nil and { "withdraw", "move", "summary", "markings" } or { "wallpaper", "boxName" })
      or { "deposit", "move", "summary", "markings" }
  elseif self._mode == 2 then
    if mon == nil then
      self._menu = nil
      return
    end
    actions = { "move", "release", "summary", "markings" }
  else
    if mon == nil then
      self._menu = nil
      return
    end
    actions = { "takeItem", "giveItem", "swapItems", "summary" }
  end
  self._menu = { actions = actions, selected = 1, address = address }
end

function StorageScreenState:_beginAction(action, data)
  local source = assert(self._menu and self._menu.address, "Storage actions start at a selected address")
  self._menu = nil
  if action == "deposit" then
    self._focus = { domain = "box", slot = self._focus.slot }
    self._carry = {
      kind = "mon",
      action = action,
      source = source,
      mon = self:_monVisual(source),
    }
  elseif action == "withdraw" then
    self._carry = {
      kind = "mon",
      action = action,
      source = source,
      mon = self:_monVisual(source),
      destination = { kind = "party", slot = self._mons:partyCount() },
    }
  elseif action == "move" then
    self._carry = { kind = "mon", action = action, source = source, mon = self:_monVisual(source) }
  elseif action == "swapItems" then
    self._carry = { kind = "items", action = action, source = source, mon = self:_monVisual(source) }
  elseif action == "giveItem" then
    self:_openChild("heldItemPicker", { source = source })
  elseif action == "takeItem" then
    local intent = self._actions:preview({ kind = action, source = source, item = data and data.item })
    self._lastAction = intent.kind == "allowed" and self._actions:commit(intent) or intent
    if intent.kind == "confirm" then
      self._pendingIntent = intent
    end
  elseif action == "release" then
    self._releaseIntent = self._actions:preview({ kind = action, source = source })
    if self._releaseIntent.kind == "confirm" then
      self._releaseRevisions = copy(self._releaseIntent.expected)
      self._releaseCheck =
        { address = source, scanned = 0, total = self._mons:boxCount() * 30 + 6, outcome = "confirm" }
    end
  elseif action == "markings" then
    local mon = assert(self:_monVisual(source), "markings edit an occupied address")
    self._editor = { kind = "markings", source = source, mask = mon.markings, selected = 0 }
  elseif action == "wallpaper" then
    local wallpaperId = self._mons:boxMetadata(self._activeBox).wallpaperId
    local selected = wallpaperId >= 32 and wallpaperId - 16 or wallpaperId
    self._editor = { kind = "wallpaper", box = self._activeBox, selected = selected }
  elseif action == "summary" or action == "boxName" then
    self:_openChild(action, { source = source, box = self._activeBox })
  else
    error("unknown Storage action " .. tostring(action), 0)
  end
end

function StorageScreenState:_updateEditor(events)
  local editor = assert(self._editor)
  local function submit()
    local action
    if editor.kind == "markings" then
      action = { kind = "markings", source = editor.source, mask = editor.mask }
    else
      local wallpaperId = editor.selected < 16 and editor.selected or editor.selected + 16
      local unlocks = self._mons:boxSnapshot().bonusUnlocks
      local unlocked = editor.selected < 16 or unlocks[editor.selected - 15] == true
      if unlocked then
        if wallpaperId ~= self._mons:boxMetadata(editor.box).wallpaperId then
          action = { kind = "wallpaper", box = editor.box, wallpaperId = wallpaperId }
        end
        self._editor = nil
      end
    end
    if action ~= nil then
      self._lastAction = self._actions:commit(self._actions:preview(action))
      self._editor = nil
    end
  end
  for _, event in ipairs(events) do
    if event.type == "cancel" then
      self._editor = nil
      return
    elseif event.type == "pointer_cancel" then
      -- Pointer capture cancellation does not change the local draft.
    elseif event.type == "submit" then
      submit()
      if self._editor == nil then
        return
      end
    elseif editor.kind == "markings" and event.type == "navigate" then
      local delta = (event.direction == "left" and -1) or (event.direction == "right" and 1) or 0
      editor.selected = math.max(0, math.min(5, editor.selected + delta))
    elseif editor.kind == "wallpaper" and event.type == "navigate" then
      local delta = (event.direction == "left" and -1)
        or (event.direction == "right" and 1)
        or (event.direction == "up" and -4)
        or (event.direction == "down" and 4)
        or 0
      local row, column = math.floor(editor.selected / 4), editor.selected % 4
      if delta == -1 then
        column = (column + 3) % 4
      elseif delta == 1 then
        column = (column + 1) % 4
      elseif delta == -4 then
        row = (row + 5) % 6
      elseif delta == 4 then
        row = (row + 1) % 6
      end
      editor.selected = row * 4 + column
    elseif event.type == "wallpaper_choice" and editor.kind == "wallpaper" then
      local choice = event.id
      if type(choice) == "number" and choice % 1 == 0 and choice >= 0 and choice < 24 then
        local unlocks = self._mons:boxSnapshot().bonusUnlocks
        if choice < 16 or unlocks[choice - 15] == true then
          local storedId = choice < 16 and choice or choice + 16
          if storedId ~= self._mons:boxMetadata(editor.box).wallpaperId then
            editor.selected = choice
          end
        end
      end
    elseif event.type == "marking_choice" and editor.kind == "markings" then
      local choice = event.id
      if type(choice) == "number" and choice % 1 == 0 and choice >= 0 and choice < 6 then
        editor.selected = choice
        local bit = 2 ^ choice
        local selected = math.floor(editor.mask / bit) % 2 == 1
        editor.mask = selected and editor.mask - bit or editor.mask + bit
      end
    elseif event.type == "confirm" then
      if editor.kind == "markings" then
        local bit = 2 ^ editor.selected
        local selected = math.floor(editor.mask / bit) % 2 == 1
        editor.mask = selected and editor.mask - bit or editor.mask + bit
      else
        submit()
        if self._editor == nil then
          return
        end
      end
    else
      assert(
        event.type == "navigate" or event.type == "wallpaper_choice" or event.type == "marking_choice",
        "unknown Storage editor input " .. event.type
      )
    end
  end
end

function StorageScreenState:_openChild(kind, request)
  local factory = assert(self._children[kind], "Storage child factory is composed: " .. kind)
  self._child = assert(factory(request), "Storage child factory returns its state")
  self._childKind, self._childRequest = kind, copy(request)
end

function StorageScreenState:_disposeChild()
  local child = self._child
  self._child, self._childKind, self._childRequest = nil, nil, nil
  if child ~= nil then
    child:dispose()
  end
end

function StorageScreenState:_updateChild(events)
  local child = assert(self._child)
  child:updateFixed(events)
  local kind, request = assert(self._childKind), assert(self._childRequest)
  if kind == "heldItemPicker" then
    local intent = child:takeIntent()
    if intent ~= nil then
      assert(intent.kind == "pick", "held item picker returns a Bag pick intent")
      local decision = self._actions:preview({
        kind = "giveItem",
        source = request.source,
        item = intent.item,
      })
      if decision.kind == "allowed" then
        self._lastAction = self._actions:commit(decision)
      elseif decision.kind == "confirm" then
        self._pendingIntent = decision
        self._lastAction = decision
      else
        self._lastAction = decision
      end
      self:_disposeChild()
      return
    end
  end
  local result = child.result and child:result() or child.takeResult and child:takeResult()
  if result ~= nil then
    local action
    if result.kind == "submit" and kind == "boxName" then
      action = { kind = "boxName", box = self._activeBox, name = result.text }
    elseif result.kind == "submit" and kind == "markings" then
      action = { kind = "markings", source = request.source, mask = result.mask }
    elseif result.kind == "submit" and kind == "wallpaper" then
      action = { kind = "wallpaper", box = self._activeBox, wallpaperId = result.wallpaperId }
    end
    if action ~= nil then
      self._lastAction = self._actions:commit(self._actions:preview(action))
    end
    self:_disposeChild()
  end
end

function StorageScreenState:_confirmCarry()
  local carry = assert(self._carry)
  local destination = carry.destination or self:_address(self._focus)
  if
    destination.kind == carry.source.kind and destination.kind == "party" and destination.slot == carry.source.slot
    or destination.kind == "box"
      and carry.source.kind == "box"
      and destination.box == carry.source.box
      and destination.slot == carry.source.slot
  then
    self._carry = nil
    return
  end
  if carry.kind == "items" then
    local intent = self._actions:preview({ kind = "swapItems", source = carry.source, destination = destination })
    self._lastAction = self._actions:commit(intent)
    self._carry = nil
    if self._lastAction.kind == "changed" or self._lastAction.kind == "unchanged" then
      self._focus = { domain = destination.kind, slot = destination.slot }
    end
    return
  end
  local occupied = destination.kind == "box" and self._mons:boxMon(destination.box, destination.slot) ~= nil
    or destination.kind == "party" and destination.slot < self._mons:partyCount()
  local kind = carry.action == "deposit" and "deposit"
    or carry.action == "withdraw" and "withdraw"
    or occupied and "swap"
    or "move"
  local intent = self._actions:preview({ kind = kind, source = carry.source, destination = destination })
  self._lastAction = self._actions:commit(intent)
  if self._lastAction.kind == "changed" or self._lastAction.kind == "unchanged" then
    self._focus, self._carry = { domain = destination.kind, slot = destination.slot }, nil
  end
end

function StorageScreenState:_resolve()
  assert(not self._disposed, "disposed Storage has no plan")
  self._session:resolve(self._measureDisplay(), self:_view())
end

---@param events table<string, unknown>[] an ordered batch of normalized events
function StorageScreenState:updateFixed(events)
  assert(not self._disposed, "disposed Storage does not update")
  assert(type(events) == "table", "Storage updates use an ordered event batch")
  if self._closed then
    return
  end
  if self._child ~= nil then
    self:_updateChild(events)
    self:_resolve()
    return
  end
  local view = self:_view()
  self._session:resolve(self._measureDisplay(), view)
  events = self._session:mapInput(events, view)
  if self._editor ~= nil then
    self:_updateEditor(events)
    self:_resolve()
    return
  end
  local beganScan = false
  for _, event in ipairs(events) do
    assert(type(event) == "table" and type(event.type) == "string", "Storage events are tagged records")
    if event.type == "release" then
      assert(self._releaseCheck == nil, "only one release decision may be armed")
      local intent = self._actions:preview({ kind = "release", source = copy(assert(event.address)) })
      if intent.kind == "confirm" or intent.reason == "hm_return" then
        self._releaseIntent = intent
        self._releaseRevisions = copy(intent.expected)
        self._releaseCheck = {
          address = copy(event.address),
          scanned = 0,
          total = self._mons:boxCount() * 30 + 6,
          outcome = "confirm",
        }
      else
        self._releaseCheck = {
          address = copy(event.address),
          scanned = 0,
          total = self._mons:boxCount() * 30 + 6,
          outcome = intent.kind == "stale" and "stale" or "cancelled",
        }
      end
    elseif event.type == "confirm" and self._releaseCheck ~= nil and self._releaseCheck.outcome == "confirm" then
      self._releaseCheck.outcome = "pending"
      beganScan = true
    elseif event.type == "cancel" then
      if
        self._releaseCheck ~= nil
        and (self._releaseCheck.outcome == "confirm" or self._releaseCheck.outcome == "pending")
      then
        self._releaseCheck.outcome = "cancelled"
        self._releaseIntent = nil
        self._releaseRevisions = nil
      elseif self._pendingIntent ~= nil then
        self._pendingIntent = nil
      elseif self._carry ~= nil then
        self._carry = nil
      elseif self._menu ~= nil then
        self._menu = nil
      else
        self:cancel("input")
        return
      end
    elseif event.type == "storage_target" then
      local target = copy(assert(event.target, "mapped Storage inputs identify a target"))
      self._focus = { domain = target.domain or target.kind, slot = target.slot }
      if target.box ~= nil then
        self._activeBox = target.box
      end
    elseif event.type == "navigate" then
      local direction = assert(event.direction)
      if self._menu ~= nil and (direction == "up" or direction == "down") then
        local delta = direction == "up" and -1 or 1
        self._menu.selected = math.max(1, math.min(#self._menu.actions, self._menu.selected + delta))
      elseif direction == "up" or direction == "down" then
        local delta = direction == "up" and -1 or 1
        self._focus.slot = math.max(0, math.min(self._focus.domain == "party" and 5 or 29, self._focus.slot + delta))
      elseif direction == "left" or direction == "right" then
        self._activeBox = (self._activeBox + (direction == "right" and 1 or -1)) % self._mons:boxCount()
        self._focus = { domain = self._focus.domain, slot = 0 }
        self._actions:commit(self._actions:preview({ kind = "activeBox", box = self._activeBox }))
      end
    elseif event.type == "pointer_cancel" then
      -- The paired session has already discarded the invalid pointer capture.
    elseif event.type == "confirm" then
      if self._pendingIntent ~= nil then
        self._lastAction = self._actions:commit(self._pendingIntent, true)
        self._pendingIntent = nil
      elseif self._carry ~= nil then
        self:_confirmCarry()
      elseif self._menu ~= nil then
        local menu = assert(self._menu)
        local selectedAction = assert(menu.actions[menu.selected], "Storage selection resolves to a menu action")
        self:_beginAction(selectedAction)
      else
        self:_openMenu()
      end
    elseif event.type == "action" then
      if self._menu == nil then
        self:_openMenu()
      end
      self:_beginAction(assert(event.action), event)
    else
      assert(false, "unknown Storage input event " .. event.type)
    end
  end

  local check = self._releaseCheck
  if check ~= nil and check.outcome == "pending" then
    if
      self._releaseRevisions.partyRevision ~= self._mons:partyRevision()
      or self._releaseRevisions.boxRevision ~= self._mons:boxRevision()
    then
      check.outcome = "stale"
      self._releaseIntent = nil
    else
      check.scanned = math.min(check.total, check.scanned + 15)
      if check.scanned == check.total then
        local intent = assert(self._releaseIntent)
        local result = intent.reason == "hm_return" and intent or self._actions:commit(intent, true)
        if result.kind == "stale" then
          check.outcome = "stale"
        elseif result.reason == "hm_return" then
          check.outcome = "returned"
        elseif result.kind == "changed" then
          check.outcome = "removed"
        else
          check.outcome = "cancelled"
        end
        self._releaseIntent = nil
      end
    end
  end
  if not beganScan then
    self._transitionTick = self._transitionTick + 1
  end
  self:_resolve()
end

function StorageScreenState:status()
  local view = self:_view()
  return {
    mode = self._mode,
    activeBox = self._activeBox,
    focus = copy(self._focus),
    phase = self._childKind and "child"
      or self._editor and "editor"
      or self._menu and "menu"
      or self._carry and "carry"
      or "browse",
    editor = copy(self._editor),
    menu = copy(self._menu),
    lastAction = copy(self._lastAction),
    transitionTick = self._transitionTick,
    childKind = self._childKind,
    releaseCheck = copy(self._releaseCheck),
    boxName = view.boxName,
    boxSlots = view.boxSlots,
    party = view.party,
    carry = view.carry,
  }
end

function StorageScreenState:draw(resources)
  assert(not self._disposed, "disposed Storage draws nothing")
  assert(type(resources) == "table", "Storage draw borrows its renderer resources")
  if self._child ~= nil and self._childKind == "heldItemPicker" then
    local status = self._child:status()
    if status.presentation ~= nil then
      ApplicationPresentation.draw(assert(love.graphics), {
        graphics = love.graphics,
        bagRenderer = assert(resources.bagRenderer, "Storage borrows the Bag renderer"),
        heroRenderer = assert(resources.heroRenderer, "Storage borrows the Bag hero renderer"),
        icons = assert(resources.itemIcons, "Storage borrows the Bag item icon provider"),
        text = assert(resources.textRenderer, "Storage borrows the text renderer"),
      }, status, status.presentation)
    end
    return
  end
  ApplicationPresentation.draw(assert(love.graphics), resources, self:_view(), self._session:plan())
end

function StorageScreenState:result()
  if not self._closed or self._resultTaken then
    return nil
  end
  self._resultTaken = true
  return { kind = "closed" }
end

function StorageScreenState:isActive()
  return not self._closed and not self._disposed
end

function StorageScreenState:cancelPointerCapture()
  self._session:cancelPointers()
  local child = self._child
  if child ~= nil and type(child.cancelPointerCapture) == "function" then
    child:cancelPointerCapture()
  end
end

function StorageScreenState:cancel(_)
  if self._closed then
    return
  end
  self._closed = true
  self:_disposeChild()
  self._editor = nil
  if self._releaseCheck ~= nil and self._releaseCheck.outcome == "pending" then
    self._releaseCheck.outcome = "cancelled"
    self._releaseIntent = nil
  end
  self._session:cancelPointers()
end

function StorageScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self:_disposeChild()
  self._session:dispose()
end

return StorageScreenState
