-- Presentation-only animation for the PC Storage box screen.
-- The module diffs consecutive published views and advances one retail
-- VBlank step per call; it owns no love objects, no clock, and never mutates
-- a view. The renderer calls step once per presented lower pane.

---@class PcStorageAnimation.Slide
---@field x number
---@field y number
---@field toX number
---@field toY number
---@field stepX number
---@field stepY number
---@field xNegative boolean
---@field yNegative boolean
---@field frames integer

---@class PcStorageAnimation.Mon
---@field personality unknown?
---@field species unknown?
---@field trainerId unknown?
---@field otId unknown?
---@field nickname unknown?
---@field heldItem unknown?
---@field iconKey string?
---@field itemIconKey string?

---@class PcStorageAnimation.Move
---@field fromDomain string
---@field toDomain string
---@field from integer
---@field to integer
---@field sourceSide "left"|"right"|"closed"?
---@field mon PcStorageAnimation.Mon?
---@field timer integer

---@class PcStorageAnimation.ItemFlight
---@field domain string
---@field from integer
---@field to integer
---@field iconKey string
---@field fromX number
---@field fromY number
---@field toX number
---@field toY number
---@field timer integer

---@class PcStorageAnimation.Scroll
---@field direction integer
---@field frame integer
---@field previous table<string, unknown>
---@field view table<string, unknown>

---@class PcStorageAnimation
---@field private _prev table<string, unknown>?
---@field private _lastCursor { x: number, y: number }?
---@field private _cursorSlide PcStorageAnimation.Slide?
---@field private _moves PcStorageAnimation.Move[]?
---@field private _movesTransferGeneration integer?
---@field private _seenTransferGeneration integer?
---@field private _scroll PcStorageAnimation.Scroll?
---@field private _item PcStorageAnimation.ItemFlight?
---@field private _dip integer?
---@field private _frame PcStorageAnimation.Frame?
local PcStorageAnimation = {}
PcStorageAnimation.__index = PcStorageAnimation

local BOX_COLUMNS = 6
local BOX_ICON_CENTER_X = 24
local BOX_ICON_CENTER_Y = 48
local BOX_ICON_PITCH = 24
local PARTY_CENTERS = { { 40, 64 }, { 80, 72 }, { 40, 96 }, { 80, 104 }, { 40, 128 }, { 80, 136 } }
local PARTY_RIGHT_OFFSET = 152
local SCROLL_TICKS = 23
local SCROLL_STEP = 8
local SCROLL_SPAN = 184
local SCROLL_WRAP_RIGHT = 176
local SCROLL_WRAP_LEFT = -8
local MOVE_TICKS = 8
local ITEM_TICKS = 8
-- PCBox_AnimateTrayPickUp: four 2 px down steps then four back up (2..8,6..0).
local DIP = { 2, 4, 6, 8, 6, 4, 2, 0 }
-- PCBox_UpdateReleaseShrink/UpdateReleaseGrow: forty -0.025 shrink steps and
-- twenty +0.05 grow steps, both anchored eight pixels below the slot centre.
local RELEASE_SHRINK_STEP = 0.025
local RELEASE_GROW_STEP = 0.05

---@class PcStorageAnimation.Frame
---@field cursor { x: number, y: number }
---@field wallpaper { id: integer, x: integer }[]
---@field icons table<string, table<integer, { x: number, y: number, mon: PcStorageAnimation.Mon?, scale: number? }>>?
---@field release table<integer, { x: number, y: number, mon: PcStorageAnimation.Mon?, scale: number }>?
---@field item { iconKey: string, x: number, y: number }?
---@field cursorDip integer
---@field itemFrom { domain: string, slot: integer }?
---@field itemTo { domain: string, slot: integer }?
---@field transferComplete boolean?

---@return PcStorageAnimation
function PcStorageAnimation.new()
  return setmetatable({
    _prev = nil,
    _lastCursor = nil,
    _cursorSlide = nil,
    _moves = nil,
    _movesTransferGeneration = nil,
    _seenTransferGeneration = nil,
    _scroll = nil,
    _item = nil,
    _dip = nil,
    _frame = nil,
  }, PcStorageAnimation)
end

function PcStorageAnimation:beginSession()
  self._prev = nil
  self._lastCursor = nil
  self._cursorSlide = nil
  self._moves = nil
  self._movesTransferGeneration = nil
  self._seenTransferGeneration = nil
  self._scroll = nil
  self._item = nil
  self._dip = nil
  self._frame = nil
end

---@param domain "box"|"party"
---@param slot integer zero-based slot
---@param side "left"|"right"|"closed"
---@return number x
---@return number y
local function slotCenter(domain, slot, side)
  if domain == "box" then
    return BOX_ICON_CENTER_X + (slot % BOX_COLUMNS) * BOX_ICON_PITCH,
      BOX_ICON_CENTER_Y + math.floor(slot / BOX_COLUMNS) * BOX_ICON_PITCH
  end
  local center = assert(PARTY_CENTERS[slot + 1], "party slot is within the six-slot tray")
  local x = center[1]
  if side == "right" then
    x = x + PARTY_RIGHT_OFFSET
  end
  return x, center[2]
end

---@param view table<string, unknown>
---@return PcStorageAnimation.Frame
local function restedFrame(view)
  local cursor = view.cursor or { x = 0, y = 0 }
  return {
    cursor = { x = cursor.x, y = cursor.y },
    wallpaper = { { id = view.wallpaperId or 0, x = 0 } },
  }
end

---@param frame PcStorageAnimation.Frame
---@param domain "box"|"party"
---@param slot integer
---@return { x: number, y: number, mon: PcStorageAnimation.Mon?, scale: number? }?
local function iconAt(frame, domain, slot)
  local icons = frame.icons
  return icons and icons[domain] and icons[domain][slot] or nil
end

PcStorageAnimation.iconAt = iconAt

-- Starts the four-step cursor slide of the source grid handler.
---@param self PcStorageAnimation
---@param fromX number
---@param fromY number
---@param toX number
---@param toY number
function PcStorageAnimation:_startCursorSlide(fromX, fromY, toX, toY)
  local dx, dy = toX - fromX, toY - fromY
  self._cursorSlide = {
    x = fromX,
    y = fromY,
    toX = toX,
    toY = toY,
    stepX = math.floor(math.abs(dx) / 4),
    stepY = math.floor(math.abs(dy) / 4),
    xNegative = dx < 0,
    yNegative = dy < 0,
    frames = 4,
  }
end

-- Starts one linear mon move (eight equal source steps, then the snap).
---@param self PcStorageAnimation
---@param entries { fromDomain: string, toDomain: string, from: integer, to: integer, mon: PcStorageAnimation.Mon? }[]
---@param transferGeneration integer?
---@param sourceSide "left"|"right"|"closed"?
function PcStorageAnimation:_startMoves(entries, transferGeneration, sourceSide)
  local moves = {}
  for _, entry in ipairs(entries) do
    moves[#moves + 1] = {
      fromDomain = entry.fromDomain,
      toDomain = entry.toDomain,
      from = entry.from,
      to = entry.to,
      sourceSide = entry.fromDomain == "party" and sourceSide or nil,
      mon = entry.mon,
      timer = 0,
    }
  end
  self._moves = moves
  self._movesTransferGeneration = transferGeneration
end

---@param view table<string, unknown>
---@return boolean started
function PcStorageAnimation:_startPublishedTransfer(view)
  local transfer = view.transfer
  if type(transfer) ~= "table" or view.transferGeneration == self._seenTransferGeneration then
    return false
  end
  local entries = assert(transfer.moves, "published transfer has a move group")
  self:_startMoves(entries, view.transferGeneration, view.transferSide)
  self._seenTransferGeneration = view.transferGeneration
  return true
end

-- Builds ordered identity occurrences across both custody domains. Including
-- species and trainer identity avoids treating personality collisions as the
-- same visual record.
---@param view table<string, unknown>
---@return table<string, { domain: string, slot: integer }[]>
local function slotsByIdentity(view)
  local map = {}
  for _, domain in ipairs({ "box", "party" }) do
    local slots = domain == "box" and view.boxSlots or view.party
    for index, mon in ipairs(slots or {}) do
      if mon ~= false and type(mon) == "table" and mon.personality ~= nil then
        local key = table.concat({
          tostring(mon.personality),
          tostring(mon.species),
          tostring(mon.trainerId or mon.otId),
          tostring(mon.nickname),
        }, "\31")
        map[key] = map[key] or {}
        map[key][#map[key] + 1] = { domain = domain, slot = index - 1 }
      end
    end
  end
  return map
end

-- Builds the slot -> held-item icon key map for one view and domain.
---@param view table<string, unknown>
---@param domain "box"|"party"
---@return table<string, { slot: integer, iconKey: string }>
local function itemByKey(view, domain)
  local map = {}
  local slots = domain == "box" and view.boxSlots or view.party
  for index, mon in ipairs(slots or {}) do
    if mon ~= false and type(mon) == "table" and mon.heldItem ~= nil and mon.heldItem ~= "NONE" then
      map[tostring(mon.heldItem) .. ":" .. tostring(mon.personality)] = {
        slot = index - 1,
        iconKey = assert(mon.itemIconKey, "held mons carry their item icon key"),
      }
    end
  end
  return map
end

---@param self PcStorageAnimation
---@param previous table<string, unknown>
---@param view table<string, unknown>
---@return { fromDomain: string, toDomain: string, from: integer, to: integer, mon: PcStorageAnimation.Mon? }[]
function PcStorageAnimation:_diffMons(previous, view)
  local entries = {}
  local before, after = slotsByIdentity(previous), slotsByIdentity(view)
  for identity, sources in pairs(before) do
    local destinations = after[identity] or {}
    for index, source in ipairs(sources) do
      local destination = destinations[index]
      if destination ~= nil and (source.domain ~= destination.domain or source.slot ~= destination.slot) then
        local slots = destination.domain == "box" and view.boxSlots or view.party
        entries[#entries + 1] = {
          fromDomain = source.domain,
          toDomain = destination.domain,
          from = source.slot,
          to = destination.slot,
          mon = slots and slots[destination.slot + 1] or nil,
        }
      end
    end
  end
  table.sort(entries, function(a, b)
    return a.fromDomain == b.fromDomain and a.from < b.from or a.fromDomain < b.fromDomain
  end)
  return entries
end

-- Starts the held-item icon flight when one item left a mon and one arrived.
---@param self PcStorageAnimation
---@param previous table<string, unknown>
---@param view table<string, unknown>
function PcStorageAnimation:_startItemFlight(previous, view)
  if view.carry ~= nil and view.carry.kind == "items" then
    return
  end
  for _, domain in ipairs({ "box", "party" }) do
    local before = itemByKey(previous, domain)
    local after = itemByKey(view, domain)
    local lost, gained
    local lostCount, gainedCount = 0, 0
    for key, entry in pairs(before) do
      if after[key] == nil then
        lost, lostCount = { slot = entry.slot, iconKey = entry.iconKey }, lostCount + 1
      end
    end
    for key, entry in pairs(after) do
      if before[key] == nil then
        gained, gainedCount = { slot = entry.slot, iconKey = entry.iconKey }, gainedCount + 1
      end
    end
    if lostCount == 1 and gainedCount == 1 then
      local fromX, fromY = slotCenter(domain, lost.slot, view.tray)
      local toX, toY = slotCenter(domain, gained.slot, view.tray)
      self._item = {
        domain = domain,
        from = lost.slot,
        to = gained.slot,
        iconKey = gained.iconKey,
        -- The item sprite sits at the slot centre + (8, 8) while carried and
        -- + (0, 4) once placed; the flight interpolates the carried offset.
        fromX = fromX + 8,
        fromY = fromY + 8,
        toX = toX + 8,
        toY = toY + 8,
        timer = 0,
      }
      return
    end
  end
end

---@param self PcStorageAnimation
---@param previous table<string, unknown>
---@param view table<string, unknown>
function PcStorageAnimation:_startScroll(previous, view)
  -- The source chooses the scroll side by numeric order: a higher target
  -- scrolls the walls left, a lower target scrolls them right, regardless of
  -- how many boxes the tray jump skipped.
  local direction = view.activeBox > previous.activeBox and -1 or 1
  self._scroll = {
    direction = direction,
    frame = 0,
    previous = previous,
    view = view,
  }
end

-- Applies one scroll tick to the outgoing and incoming icon sets.
---@param self PcStorageAnimation
---@return PcStorageAnimation.Frame
function PcStorageAnimation:_stepScroll()
  local scroll = assert(self._scroll)
  local k = scroll.frame + 1
  local direction = scroll.direction
  local previous, view = scroll.previous, scroll.view
  local frame = restedFrame(view)
  frame.cursor = { x = 0, y = 0 }
  frame.icons = { box = {}, party = {} }
  for slot = 0, 29 do
    local x = BOX_ICON_CENTER_X + (slot % BOX_COLUMNS) * BOX_ICON_PITCH
    local y = BOX_ICON_CENTER_Y + math.floor(slot / BOX_COLUMNS) * BOX_ICON_PITCH
    local sx = x + direction * SCROLL_STEP * k
    local fromIncoming = false
    if direction > 0 and sx >= SCROLL_WRAP_RIGHT then
      sx = sx - SCROLL_SPAN
      fromIncoming = true
    elseif direction < 0 and sx <= SCROLL_WRAP_LEFT then
      sx = sx + SCROLL_SPAN
      fromIncoming = true
    end
    local mon = fromIncoming and view.boxSlots[slot + 1] or previous.boxSlots[slot + 1]
    if mon ~= false and type(mon) == "table" then
      frame.icons.box[slot] = { x = sx, y = y, mon = mon }
    end
  end
  local offset = direction * SCROLL_STEP * k
  frame.wallpaper = {
    { id = previous.wallpaperId or 0, x = offset },
    { id = view.wallpaperId or 0, x = offset - direction * SCROLL_SPAN },
  }
  scroll.frame = scroll.frame + 1
  if scroll.frame == SCROLL_TICKS then
    self._scroll = nil
  end
  return frame
end

-- Advances one presented frame from the last observed view.
---@param view table<string, unknown>
---@return PcStorageAnimation.Frame
function PcStorageAnimation:step(view)
  local previous = self._prev
  if previous == nil then
    self._prev = view
    previous = view
    local cursor = view.cursor or { x = 0, y = 0 }
    self._lastCursor = { x = cursor.x, y = cursor.y }
  end
  if self._scroll ~= nil then
    local scrollView = self._scroll.view
    local frame = self:_stepScroll()
    if self._scroll == nil then
      -- A published transfer carries its source identity across a coalesced
      -- box switch, where the scroll target may already contain final custody.
      -- Otherwise retain the scroll-start baseline for changes during scroll.
      if self:_startPublishedTransfer(view) then
        self._prev = view
      else
        self._prev = scrollView
      end
      self._lastCursor = { x = view.cursor and view.cursor.x or 0, y = view.cursor and view.cursor.y or 0 }
    end
    self._frame = frame
    return frame
  end
  if view.activeBox ~= previous.activeBox then
    self:_startScroll(previous, view)
    if self._scroll ~= nil then
      local frame = self:_stepScroll()
      self._frame = frame
      return frame
    end
  end
  self:_startPublishedTransfer(view)
  local frame = restedFrame(view)
  -- Cursor slide.
  local cursor = view.cursor
  if cursor ~= nil and self._lastCursor ~= nil then
    if self._cursorSlide == nil and (cursor.x ~= self._lastCursor.x or cursor.y ~= self._lastCursor.y) then
      self:_startCursorSlide(self._lastCursor.x, self._lastCursor.y, cursor.x, cursor.y)
    end
  end
  if self._cursorSlide ~= nil then
    local slide = assert(self._cursorSlide)
    if slide.frames == 0 then
      frame.cursor = { x = slide.toX, y = slide.toY }
      self._lastCursor = { x = slide.toX, y = slide.toY }
      self._cursorSlide = nil
    else
      slide.frames = slide.frames - 1
      slide.x = slide.x + (slide.xNegative and -slide.stepX or slide.stepX)
      slide.y = slide.y + (slide.yNegative and -slide.stepY or slide.stepY)
      frame.cursor = { x = slide.x, y = slide.y }
    end
  elseif cursor ~= nil then
    self._lastCursor = { x = cursor.x, y = cursor.y }
  end
  -- Mon move entries.
  if self._moves == nil then
    local entries = self:_diffMons(previous, view)
    if #entries > 0 then
      self:_startMoves(entries, view.transferGeneration)
      self._prev = view
    end
    self:_startItemFlight(previous, view)
  end
  if self._moves ~= nil then
    local icons = { box = {}, party = {} }
    local settled = true
    local transferGeneration = view.transferGeneration
    local movesTransferGeneration = self._movesTransferGeneration
    for _, move in ipairs(self._moves) do
      move.timer = move.timer + 1
      local t = math.min(move.timer, MOVE_TICKS)
      if move.timer < MOVE_TICKS then
        settled = false
      end
      local sourceSide = move.sourceSide or previous.tray
      local fromX, fromY = slotCenter(move.fromDomain, move.from, sourceSide)
      local destinationSide = view.transferSide or view.tray
      local toX, toY = slotCenter(move.toDomain, move.to, destinationSide)
      icons[move.toDomain][move.to] = {
        x = fromX + (toX - fromX) * t / MOVE_TICKS,
        y = fromY + (toY - fromY) * t / MOVE_TICKS,
        mon = move.mon,
      }
    end
    frame.icons = icons
    if settled then
      self._moves = nil
      if view.transferSide ~= nil and movesTransferGeneration == transferGeneration then
        frame.transferComplete = true
      end
      self._movesTransferGeneration = nil
    end
    -- A newer transfer arrived while this move group was in flight. Retain
    -- the old baseline so the next frame can diff and animate that transfer.
    if movesTransferGeneration ~= transferGeneration then
      self._prev = previous
    else
      self._prev = view
    end
  end
  -- The screen state owns the release timeline; this projector renders the
  -- phase and tick it publishes. The shrink's affine anchor sits 8 px below
  -- the slot centre (ManagedSprite_SetAffineTranslation(..., 0, 8)).
  local release = view.release
  if type(release) == "table" and type(release.address) == "table" then
    local address = release.address
    local domain = address.kind
    local x, y = slotCenter(domain, address.slot, view.tray)
    local scale
    if release.phase == "shrink" then
      scale = math.max(0, 1 - (release.tick + 1) * RELEASE_SHRINK_STEP)
    elseif release.phase == "grow" then
      scale = math.min(1, (release.tick + 1) * RELEASE_GROW_STEP)
    end
    if scale ~= nil then
      frame.release = {
        { domain = domain, slot = address.slot, x = x, y = y + 8, mon = release.mon, scale = scale },
      }
    end
  end
  -- Held-item icon flight.
  if self._item ~= nil then
    local item = assert(self._item)
    item.timer = item.timer + 1
    local t = math.min(item.timer, ITEM_TICKS)
    frame.item = {
      iconKey = item.iconKey,
      x = item.fromX + (item.toX - item.fromX) * t / ITEM_TICKS,
      y = item.fromY + (item.toY - item.fromY) * t / ITEM_TICKS,
    }
    frame.itemFrom = { domain = item.domain, slot = item.from }
    frame.itemTo = { domain = item.domain, slot = item.to }
    if item.timer >= ITEM_TICKS then
      self._item = nil
    end
  end
  -- Pick-up dip: the source bobs the cursor once when a mon is first held.
  if previous.carry == nil and view.carry ~= nil then
    self._dip = 1
  end
  if self._dip ~= nil then
    local offset = DIP[self._dip]
    if offset ~= nil then
      frame.cursor = { x = frame.cursor.x, y = frame.cursor.y + offset }
      self._dip = self._dip + 1
    else
      self._dip = nil
    end
  end
  self._prev = view
  self._frame = frame
  return frame
end

---@return PcStorageAnimation.Frame
function PcStorageAnimation:frame()
  return self._frame
end

return PcStorageAnimation
