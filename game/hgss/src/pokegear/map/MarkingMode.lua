-- The region map's marking mode for one location: four icon slots, four word
-- slots, the eight-icon pool, the trash can and the Back button, with the
-- source's key cursor graph and touch drag-and-drop rules. Follows
-- the retail ROM's marking input, cursor specs and slot geometry. The mode owns only its working
-- copy of the marking; the controller persists the copy after every edit.
-- Slots are one-based here (source index plus one); icon values are the
-- saved one-based icon identities with false for an empty slot, and words are
-- opaque word identities with false for empty. Pure module: no love, no I/O.

---@class MarkingMode.Marking
---@field icons table<integer, integer|false>
---@field words table<integer, string|false>

---@class MarkingMode
---@field _marking MarkingMode.Marking
---@field _effect fun(sequence: string)? source UI sound effect boundary
---@field _group string "main", "pool", or "trash": the active key cursor
---@field _mainPos integer zero-based main cursor spec
---@field _poolPos integer zero-based pool cursor spec
---@field _dragType string "none", "pool", or "set"
---@field _dragIcon integer zero-based pool icon, or the dragged slot (words offset by four)
---@field _dragOffset { x: number, y: number }
---@field _touch { x: number, y: number }? last touch point while dragging
---@field _trashOpen boolean
---@field _backPressed boolean
---@field _touchMode boolean true while the last input was touch (the key cursor hides)
local MarkingMode = {}
MarkingMode.__index = MarkingMode

local ICON_SLOTS = 4
local POOL_SIZE = 8
local NULL_ICON = false

-- Touch rects as {top, bottom, left, right}, half open (source
-- PokegearMap_HandleTouchInput_SelectMarkingsSlot).
local SLOT_RECTS = {
  { 24, 44, 24, 40 }, -- icon slot 0
  { 24, 44, 40, 128 }, -- word slot 0
  { 24, 44, 128, 144 }, -- icon slot 1
  { 24, 44, 144, 232 }, -- word slot 1
  { 44, 64, 24, 40 }, -- icon slot 2
  { 44, 64, 40, 128 }, -- word slot 2
  { 44, 64, 128, 144 }, -- icon slot 3
  { 44, 64, 144, 232 }, -- word slot 3
}
local BACK_RECT = { 64, 104, 192, 232 }
local TRASH_RECT = { 68, 96, 44, 100 }

-- Main key cursor specs: slot s of 0..7 then Back; neighbours as zero-based
-- spec indices (nil where the source marks none).
local MAIN_SPECS = {
  [0] = { x = 32, y = 32, left = 3, right = 1, up = 4, down = 4 },
  [1] = { x = 40, y = 31, left = 0, right = 2, up = 5, down = 5 },
  [2] = { x = 136, y = 32, left = 1, right = 3, up = 6, down = 6 },
  [3] = { x = 144, y = 31, left = 2, right = 0, up = 8, down = 7 },
  [4] = { x = 32, y = 53, left = 7, right = 5, up = 0, down = 0 },
  [5] = { x = 40, y = 52, left = 4, right = 6, up = 1, down = 1 },
  [6] = { x = 136, y = 53, left = 5, right = 7, up = 2, down = 2 },
  [7] = { x = 144, y = 52, left = 6, right = 4, up = 3, down = 8 },
  [8] = { x = 208, y = 84, up = 7, down = 3 },
}

-- Corner offsets of the bracket cursor per spec kind: left, right, top, bottom.
local ICON_CORNERS = { left = -6, right = 6, top = -6, bottom = 6 }
local WORD_CORNERS = { left = 6, right = 80, top = -6, bottom = 6 }
local BACK_CORNERS = { left = -16, right = 16, top = -9, bottom = 3 }
local POOL_CORNERS = { left = -8, right = 8, top = -8, bottom = 8 }
local TRASH_CORNERS = { left = -18, right = 18, top = -12, bottom = 6 }

---@param rect integer[] {top, bottom, left, right}
---@param x number
---@param y number
---@return boolean
local function inRect(rect, x, y)
  return x >= rect[3] and x < rect[4] and y >= rect[1] and y < rect[2]
end

---@param marking MarkingMode.Marking
---@return MarkingMode.Marking
local function copyMarking(marking)
  local copy = { icons = {}, words = {} }
  for index = 1, ICON_SLOTS do
    copy.icons[index] = marking.icons[index]
    copy.words[index] = marking.words[index]
  end
  return copy
end

---@return MarkingMode.Marking
function MarkingMode.emptyMarking()
  return { icons = { false, false, false, false }, words = { false, false, false, false } }
end

-- The source UI tones in marking mode: cursor motion, seal grabs and
-- stamps, trash drops, and cancellation. Exits close silently here; the
-- owning controller answers the exit itself, so Back stays silent while
-- every B press answers.
local CURSOR_SOUND = "SEQ_SE_GS_GEARCURSOR"
local GRAB_SOUND = "SEQ_SE_GS_GEARSEALGRAB"
local STAMP_SOUND = "SEQ_SE_GS_GEARSEALHAMERU"
local TRASH_SOUND = "SEQ_SE_GS_GEARGOMIBAKO"
local CANCEL_SOUND = "SEQ_SE_GS_GEARCANCEL"

---@param self MarkingMode
---@param sequence string
local function playEffect(self, sequence)
  if self._effect ~= nil then
    self._effect(sequence)
  end
end

---@class MarkingMode.Options
---@field marking MarkingMode.Marking? the location's saved marking, or nil
---@field wordSlot integer? zero-based word slot to focus, after a word hand-off
---@field effect fun(sequence: string)? source UI sound effect boundary

---@param opts MarkingMode.Options
---@return MarkingMode
function MarkingMode.new(opts)
  assert(opts.effect == nil or type(opts.effect) == "function", "the marking sound boundary must be a function")
  local self = setmetatable({
    _marking = copyMarking(opts.marking or MarkingMode.emptyMarking()),
    _effect = opts.effect,
    _group = "main",
    _mainPos = 0,
    _poolPos = 0,
    _dragType = "none",
    _dragIcon = 0,
    _dragOffset = { x = 0, y = 0 },
    _touch = nil,
    _trashOpen = false,
    _backPressed = false,
    _touchMode = true,
  }, MarkingMode)
  if opts.wordSlot ~= nil then
    self._mainPos = opts.wordSlot * 2 + 1
    self._touchMode = false
  end
  return self
end

---@return boolean true when no slot holds anything
function MarkingMode:isEmpty()
  for index = 1, ICON_SLOTS do
    if self._marking.icons[index] ~= NULL_ICON or self._marking.words[index] ~= false then
      return false
    end
  end
  return true
end

---@return MarkingMode.Marking a detached copy of the working marking
function MarkingMode:marking()
  return copyMarking(self._marking)
end

---@param slot integer zero-based slot s of 0..7 (even icon, odd word)
---@return boolean
function MarkingMode:_slotIsSet(slot)
  local index = math.floor(slot / 2) + 1
  if slot % 2 == 0 then
    return self._marking.icons[index] ~= NULL_ICON
  end
  return self._marking.words[index] ~= false
end

-- Marks the working copy as edited for the controller to persist.
---@param self MarkingMode
local function noteEdit(self)
  self._edited = true
end

---@return boolean edited and clears the flag
function MarkingMode:takeEdited()
  local edited = self._edited == true
  self._edited = false
  return edited
end

---@param slot integer one-based icon slot
---@param icon integer saved icon identity
function MarkingMode:_setIcon(slot, icon)
  self._marking.icons[slot] = icon
  noteEdit(self)
end

---@param kind string "icon" or "word"
---@param slot integer one-based
function MarkingMode:_remove(kind, slot)
  if kind == "icon" then
    self._marking.icons[slot] = NULL_ICON
  else
    self._marking.words[slot] = false
  end
  noteEdit(self)
end

---@param kind string
---@param a integer one-based
---@param b integer one-based
function MarkingMode:_swap(kind, a, b)
  local list = kind == "icon" and self._marking.icons or self._marking.words
  list[a], list[b] = list[b], list[a]
  noteEdit(self)
end

-- Applies a word chosen by the external selector to a word slot.
---@param slot integer zero-based word slot
---@param word string
function MarkingMode:applyWord(slot, word)
  self._marking.words[slot + 1] = word
  noteEdit(self)
end

function MarkingMode:_returnToTop()
  self._poolPos = 0
  self._group = "main"
  self._dragType = "none"
  self._trashOpen = false
end

-- Moves one spec along the key graph; blocked or absent neighbours stay
-- put and silent, while every real step answers with the cursor tone.
---@param direction string
function MarkingMode:_move(direction)
  if self._group == "main" then
    local next = MAIN_SPECS[self._mainPos][direction]
    if next ~= nil and next ~= self._mainPos then
      self._mainPos = next
      playEffect(self, CURSOR_SOUND)
    end
  elseif self._group == "pool" then
    if direction == "left" then
      self._poolPos = (self._poolPos + POOL_SIZE - 1) % POOL_SIZE
      playEffect(self, CURSOR_SOUND)
    elseif direction == "right" then
      self._poolPos = (self._poolPos + 1) % POOL_SIZE
      playEffect(self, CURSOR_SOUND)
    end
  end
end

---@param event table<string, unknown>
---@return string? result "exit" or "word"
---@return integer? wordSlot zero-based
function MarkingMode:_handleKey(event)
  local pressedConfirm = event.type == "confirm"
  local pressedCancel = event.type == "cancel"
  local direction = event.type == "navigate" and event.direction or nil
  if self._dragType == "none" then
    if direction ~= nil then
      self:_move(direction)
      return nil
    end
    if pressedCancel then
      playEffect(self, CANCEL_SOUND)
      return "exit"
    end
    if pressedConfirm then
      if self._mainPos == 8 then
        self._backPressed = true
        return "exit"
      end
      local slot = self._mainPos
      if self:_slotIsSet(slot) then
        self._dragType = "set"
        self._group = "trash"
        self._trashOpen = true
        playEffect(self, GRAB_SOUND)
      elseif slot % 2 == 0 then
        self._dragType = "pool"
        self._group = "pool"
        self._poolPos = 0
        playEffect(self, GRAB_SOUND)
      else
        return "word", math.floor(slot / 2)
      end
    end
  elseif self._dragType == "pool" then
    if direction == "left" or direction == "right" then
      self:_move(direction)
    elseif pressedConfirm then
      self:_setIcon(math.floor(self._mainPos / 2) + 1, self._poolPos + 1)
      playEffect(self, STAMP_SOUND)
    elseif pressedCancel then
      self:_returnToTop()
      playEffect(self, CANCEL_SOUND)
    end
  else
    if pressedConfirm then
      local slot = self._mainPos
      self:_remove(slot % 2 == 0 and "icon" or "word", math.floor(slot / 2) + 1)
      self:_returnToTop()
      playEffect(self, TRASH_SOUND)
    elseif pressedCancel then
      self:_returnToTop()
      playEffect(self, CANCEL_SOUND)
    end
  end
  return nil
end

---@param x number
---@param y number
---@return integer? zero-based slot hit, 0..7, 8..15 pool, 16 back
local function hitIndex(x, y)
  for index, rect in ipairs(SLOT_RECTS) do
    if inRect(rect, x, y) then
      return index - 1
    end
  end
  for pool = 0, POOL_SIZE - 1 do
    if inRect({ 124, 140, 32 + 24 * pool, 48 + 24 * pool }, x, y) then
      return 8 + pool
    end
  end
  if inRect(BACK_RECT, x, y) then
    return 16
  end
  return nil
end

-- Touch edges: a first contact starts a Back press, a pool or slot drag, or
-- a word request; a release drops the dragged item.
---@param event table<string, unknown>
---@return string? result
---@return integer? wordSlot
function MarkingMode:_handlePointer(event)
  local x, y = event.x, event.y
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil
  end
  if event.type == "pointer_down" then
    if self._dragType ~= "none" then
      -- A new touch cancels a key-driven drag state.
      self:_returnToTop()
    end
    local hit = hitIndex(x, y)
    if hit == nil then
      return nil
    end
    if hit == 16 then
      self._backPressed = true
      return "exit"
    elseif hit >= 8 then
      self._dragType = "pool"
      self._dragIcon = hit - 8
      self._dragOffset = { x = 0, y = 0 }
      self._touch = { x = x, y = y }
      playEffect(self, GRAB_SOUND)
    else
      if self:_slotIsSet(hit) then
        local index = math.floor(hit / 2)
        self._dragType = "set"
        self._touch = { x = x, y = y }
        if hit % 2 == 0 then
          self._dragIcon = index
          self._dragOffset = { x = 0, y = 0 }
        else
          self._dragIcon = index + 4
          self._dragOffset = { x = (index % 2) * 104 + 40 - x, y = math.floor(index / 2) * 21 + 31 - y }
        end
        playEffect(self, GRAB_SOUND)
      elseif hit % 2 == 1 then
        return "word", math.floor(hit / 2)
      end
    end
  elseif event.type == "pointer_move" then
    if self._dragType ~= "none" and self._touch ~= nil then
      self._touch = { x = x, y = y }
      if self._dragType == "set" then
        self._trashOpen = inRect(TRASH_RECT, x, y)
      end
    end
  elseif event.type == "pointer_up" then
    if self._dragType ~= "none" and self._touch ~= nil then
      self._touch = { x = x, y = y }
      self:_drop(x, y)
    end
  end
  return nil
end

-- Releases the dragged pool icon or slot item at a point.
---@param x number
---@param y number
function MarkingMode:_drop(x, y)
  if self._dragType == "pool" then
    local targets = { { 24, 44, 24, 40 }, { 24, 44, 128, 144 }, { 44, 64, 24, 40 }, { 44, 64, 128, 144 } }
    for index, rect in ipairs(targets) do
      if inRect(rect, x, y) then
        self:_setIcon(index, self._dragIcon + 1)
        playEffect(self, STAMP_SOUND)
        break
      end
    end
  else
    local source = self._dragIcon
    local sourceGroup, sourceIndex = math.floor(source / 4), source % 4
    local targets = {
      { 24, 44, 24, 40 },
      { 24, 44, 128, 144 },
      { 44, 64, 24, 40 },
      { 44, 64, 128, 144 },
      { 24, 44, 40, 128 },
      { 24, 44, 144, 232 },
      { 44, 64, 40, 128 },
      { 44, 64, 144, 232 },
      TRASH_RECT,
    }
    local hit = nil
    for index, rect in ipairs(targets) do
      if inRect(rect, x, y) then
        hit = index - 1
        break
      end
    end
    if hit == 8 then
      self:_remove(sourceGroup == 0 and "icon" or "word", sourceIndex + 1)
      playEffect(self, TRASH_SOUND)
    elseif hit ~= nil and math.floor(hit / 4) == sourceGroup and hit ~= source then
      self:_swap(sourceGroup == 0 and "icon" or "word", sourceIndex + 1, hit % 4 + 1)
      playEffect(self, STAMP_SOUND)
    end
  end
  self._dragType = "none"
  self._touch = nil
  self._trashOpen = false
end

-- One batch of semantic events. Returns "exit" when the mode closes, or
-- "word" with the zero-based slot that asks for a word.
---@param events table<integer, table<string, unknown>>
---@return string? result
---@return integer? wordSlot
function MarkingMode:updateFixed(events)
  for _, event in ipairs(events) do
    local kind = event.type
    local result, slot
    if kind == "pointer_down" or kind == "pointer_move" or kind == "pointer_up" then
      self._touchMode = true
      result, slot = self:_handlePointer(event)
    elseif kind == "navigate" or kind == "confirm" or kind == "cancel" then
      if self._touchMode then
        -- The first key press after touching only reveals the cursor.
        self._touchMode = false
      else
        result, slot = self:_handleKey(event)
      end
    end
    if result ~= nil then
      return result, slot
    end
  end
  return nil
end

---@return table<string, unknown>? the cursor spec centre and corner offsets, or nil when hidden
function MarkingMode:_cursor()
  if self._touchMode then
    return nil
  end
  if self._group == "pool" then
    return {
      group = "pool",
      x = 40 + 24 * self._poolPos,
      y = 132,
      corners = POOL_CORNERS,
    }
  elseif self._group == "trash" then
    return { group = "trash", x = 72, y = 84, corners = TRASH_CORNERS }
  end
  local spec = MAIN_SPECS[self._mainPos]
  local corners = ICON_CORNERS
  if self._mainPos == 8 then
    corners = BACK_CORNERS
  elseif self._mainPos % 2 == 1 then
    corners = WORD_CORNERS
  end
  return { group = "main", x = spec.x, y = spec.y, corners = corners }
end

-- The detached render view: slot items with their screen positions, the
-- pool, the key cursor, the drag ghost, and the trash and Back art states.
---@return table<string, unknown>
function MarkingMode:view()
  local slots = {}
  for index = 1, ICON_SLOTS do
    local column, row = (index - 1) % 2, math.floor((index - 1) / 2)
    slots[#slots + 1] = {
      kind = "icon",
      index = index,
      icon = self._marking.icons[index],
      x = 32 + 104 * column,
      y = 32 + 21 * row,
    }
    slots[#slots + 1] = {
      kind = "word",
      index = index,
      word = self._marking.words[index],
      x = 40 + 104 * column,
      y = 31 + 21 * row,
    }
  end
  local pool = {}
  for icon = 0, POOL_SIZE - 1 do
    pool[#pool + 1] = { icon = icon + 1, x = 40 + 24 * icon, y = 132 }
  end
  local drag = nil
  if self._dragType ~= "none" and self._touch ~= nil then
    drag = {
      type = self._dragType,
      icon = self._dragIcon,
      x = self._touch.x + self._dragOffset.x,
      y = self._touch.y + self._dragOffset.y,
    }
  end
  return {
    slots = slots,
    pool = pool,
    cursor = self:_cursor(),
    drag = drag,
    trashOpen = self._trashOpen,
    backPressed = self._backPressed,
  }
end

return MarkingMode
