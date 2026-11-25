-- The source number-entry keypad the Mom bank opens on the bottom display
-- (src/field/number_entry.c::NumberEntry_Init/NumberEntry_Task and its
-- sRodata). The screen keeps the source six-cell entry, its actual digit-cell
-- count for the maximum it was opened with, the ten digit keys and the
-- clear/confirm/cancel buttons at their source touch rectangles, the source
-- dpad grid, the input-driven 4+2-tick blink, and one terminal result. The
-- blink is the source's pressed-key feedback: it paints the two source frames
-- over the following ticks without gating the next key. The
-- screen owns input state only: it never moves a balance, and the terminal
-- amount is what the source's NumberEntry_ComputeValue reads out of the fixed
-- digit cells.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local BankScreenState = {}
BankScreenState.__index = BankScreenState

-- NUMBER_ENTRY_MAX_DIGITS: the entry never has more cells than this.
local MAX_DIGITS = 6
-- The source bottom display the keypad paints on.
BankScreenState.DISPLAY_WIDTH = 256
BankScreenState.DISPLAY_HEIGHT = 192

-- sRodata.padHitboxes: digits 0-4 on the first row, 5-9 on the second, each
-- cell 48x48 pixels starting at x 8 and y 56, then the three action buttons on
-- one 32-pixel row at y 160.
local DIGIT_ORIGIN_X = 8
local DIGIT_ORIGIN_Y = 56
local DIGIT_CELL = 48
local DIGIT_COLUMNS = 5
local ACTION_ROW_Y = 160
local ACTION_ROW_HEIGHT = 32
local ACTIONS = {
  { role = "clear", x = 0, width = 80 },
  { role = "confirm", x = 88, width = 80 },
  { role = "cancel", x = 176, width = 80 },
}

-- sRodata.padDpadBoxes: the walkable grid the source draws its cursor on. The
-- first two rows hold the ten digit keys and the last row the three buttons.
-- A neighbour value with bit 7 set names a digit-row position after the mode
-- switch (0x8A -> clear, 0x8B -> confirm, 0x8C -> cancel, 0x85/0x87/0x89 ->
-- the digit cell above the button), which the source resolves by masking the
-- flag; the table below records the destination positions.
local DPAD_BOXES = {
  { x = 32, y = 80, up = 0, down = 5, left = 4, right = 1 },
  { x = 80, y = 80, up = 1, down = 6, left = 0, right = 2 },
  { x = 128, y = 80, up = 2, down = 7, left = 1, right = 3 },
  { x = 176, y = 80, up = 3, down = 8, left = 2, right = 4 },
  { x = 224, y = 80, up = 4, down = 9, left = 3, right = 0 },
  { x = 32, y = 128, up = 0, down = 10, left = 9, right = 6 },
  { x = 80, y = 128, up = 1, down = 10, left = 5, right = 7 },
  { x = 128, y = 128, up = 2, down = 11, left = 6, right = 8 },
  { x = 176, y = 128, up = 3, down = 12, left = 7, right = 9 },
  { x = 224, y = 128, up = 4, down = 12, left = 8, right = 5 },
  { x = 40, y = 176, up = 5, down = 10, left = 12, right = 11 },
  { x = 128, y = 176, up = 7, down = 11, left = 10, right = 12 },
  { x = 216, y = 176, up = 9, down = 12, left = 11, right = 10 },
}
-- NUMBER_ENTRY_INPUT_CLEAR/CONFIRM/CANCEL: the grid results of the three
-- action keys, which are also their pad box indices.
local GRID_CLEAR = 10
local GRID_CONFIRM = 11
local GRID_CANCEL = 12

-- sRodata.xOffsets, indexed by the entry's digit count: the x of each entered
-- digit sprite and of the underline cursor under the selected cell.
local X_OFFSETS = {
  [1] = { 0x80 },
  [2] = { 0x70, 0x90 },
  [3] = { 0x60, 0x80, 0xA0 },
  [4] = { 0x50, 0x70, 0x90, 0xB0 },
  [5] = { 0x40, 0x60, 0x80, 0xA0, 0xC0 },
  [6] = { 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0 },
}
-- The entered digits and the underline cursor sit on their own display rows;
-- NumberEntry_CreateSprite offsets the whole sub-screen layer by 256 pixels.
local DIGIT_ROW_Y = 280 - 256
local CURSOR_ROW_Y = 292 - 256
-- The entry's cursor strips: the source hitboxes are one 32x32 rect per digit
-- cell around that cell's own x offset, on the entry row.
local CURSOR_STRIP_HEIGHT = 32
local CURSOR_STRIP_TOP = 8
local CURSOR_STRIP_WIDTH = 32

-- NumberEntry_UpdateBlink: the first sequence stays for four ticks, the second
-- for two, so one blink spans six ticks after the frame that starts it.
local BLINK_FIRST_TICKS = 4
local BLINK_SECOND_TICKS = 2

---@class BankScreenState
---@field private _max integer the amount the screen was opened with
---@field private _digits integer[] the source fixed digit cells
---@field private _cursor integer the cell the next digit lands in
---@field private _numDigits integer the source's actual digit-cell count
---@field private _gridCursor integer the dpad grid position
---@field private _blink table<string, unknown>? the running input blink
---@field private _result { amount: integer }? one terminal result
---@field private _taken boolean
---@field private _disposed boolean

---@param maxAmount number the lesser of the source funds and the destination capacity
---@return BankScreenState
function BankScreenState.new(maxAmount)
  if type(maxAmount) ~= "number" or maxAmount ~= maxAmount or maxAmount % 1 ~= 0 or maxAmount < 0 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the amount screen needs a whole maximum", {
      maxAmount = maxAmount,
    })
  end
  -- NumberEntry_Init walks a 100000 threshold down by tens to find the actual
  -- cell count, and never opens fewer than one cell.
  local numDigits = 0
  local threshold = 100000
  for index = 0, MAX_DIGITS - 1 do
    if maxAmount >= threshold then
      numDigits = MAX_DIGITS - index
      break
    end
    threshold = threshold / 10
  end
  if numDigits == 0 then
    numDigits = 1
  end
  local digits = {}
  for index = 1, MAX_DIGITS do
    digits[index] = 0
  end
  return setmetatable({
    _max = maxAmount,
    _digits = digits,
    _cursor = 0,
    _numDigits = numDigits,
    _gridCursor = 0,
    _blink = nil,
    _result = nil,
    _taken = false,
    _disposed = false,
  }, BankScreenState)
end

---@param self BankScreenState
---@return integer[]
local function offsets(self)
  return assert(X_OFFSETS[self._numDigits], "the entry has a source offset row")
end

-- NumberEntry_ComputeValue: the fixed cells, most significant first.
---@param self BankScreenState
---@return integer
local function computeValue(self)
  local value = 0
  for index = 0, self._numDigits - 1 do
    value = value * 10 + self._digits[index + 1]
  end
  return value
end

-- NumberEntry_MoveDigitCursor: the cursor clamps into the cells and reports
-- whether it moved.
---@param self BankScreenState
---@param delta integer
---@return boolean
local function moveCursor(self, delta)
  local previous = self._cursor
  self._cursor = self._cursor + delta
  if self._cursor < 0 then
    self._cursor = 0
  elseif self._cursor >= self._numDigits then
    self._cursor = self._numDigits - 1
  end
  if self._cursor == previous then
    return false
  end
  return true
end

-- NumberEntry_SetDigit writes the pressed digit into the selected cell.
---@param self BankScreenState
---@param digit integer
local function setDigit(self, digit)
  self._digits[self._cursor + 1] = digit
end

-- NumberEntry_StartSpriteBlink/StartBgBlink: one blink of the pressed key,
-- then the state the screen returns to.
---@param self BankScreenState
---@param target integer the pressed key whose feedback blinks
---@param seqA integer
---@param seqB integer
local function startBlink(self, target, seqA, seqB)
  self._blink = { target = target, seqA = seqA, seqB = seqB, phase = "start", timer = 0, visible = true }
end

-- NumberEntry_UpdateBlink: start paints the first frame, the timer holds it
-- for four ticks, then the second frame holds for two and the blink ends.
---@param self BankScreenState
---@return boolean whether the blink is still running
local function updateBlink(self)
  local blink = self._blink
  assert(blink ~= nil, "a blink update reads the running blink")
  if blink.phase == "start" then
    blink.phase = "first"
    return true
  end
  if blink.phase == "first" then
    blink.timer = (blink.timer --[[@as integer]]) + 1
    if blink.timer == BLINK_FIRST_TICKS then
      blink.phase = "second"
      blink.timer = 0
      blink.visible = false
    end
    return true
  end
  blink.timer = (blink.timer --[[@as integer]]) + 1
  if blink.timer == BLINK_SECOND_TICKS then
    self._blink = nil
    return false
  end
  return true
end

---@param self BankScreenState
---@param result { amount: integer }
local function finish(self, result)
  self._blink = nil
  self._result = result
  self._gridCursor = 0
end

-- ScrCmd_BankTransaction's keypad result: a confirmed amount at most the
-- maximum, or zero for a cancel. A confirmed amount above the maximum only
-- blinks the confirm key, exactly like the source.
---@param self BankScreenState
---@param digitOrAction integer
---@return boolean whether the key produced a step
local function pressGridKey(self, key)
  if key >= 0 and key <= 9 then
    setDigit(self, key)
    moveCursor(self, 1)
    startBlink(self, key, key + 12, key + 1)
    return true
  end
  if key == GRID_CLEAR then
    -- The source button is labelled BACK and only walks the cursor left; the
    -- fixed cells keep their digits.
    startBlink(self, 2, 4, 3)
    moveCursor(self, -1)
    return true
  end
  if key == GRID_CONFIRM then
    local value = computeValue(self)
    startBlink(self, 3, 4, 3)
    if value > self._max then
      return true
    end
    finish(self, { amount = value })
    return true
  end
  if key == GRID_CANCEL then
    startBlink(self, 4, 4, 3)
    finish(self, { amount = 0 })
    return true
  end
  return false
end

-- The dpad grid walks to a neighbour, exactly like GridInputHandler's
-- directional neighbour lookup.
---@param self BankScreenState
---@param direction string "up"|"down"|"left"|"right"
---@return boolean whether the cursor moved
local function walkGrid(self, direction)
  local box = DPAD_BOXES[self._gridCursor + 1]
  assert(box ~= nil, "the dpad grid holds the cursor")
  local target = box[direction]
  if target == nil then
    return false
  end
  self._gridCursor = target
  return true
end

-- One source pointer tap lands on the source rectangle it hits: a digit cell,
-- the entry's own cursor strip, or one of the three action buttons.
---@param self BankScreenState
---@param x number
---@param y number
local function tap(self, x, y)
  for digit = 0, 9 do
    local column = digit % DIGIT_COLUMNS
    local row = (digit - column) / DIGIT_COLUMNS
    local left = DIGIT_ORIGIN_X + column * DIGIT_CELL
    local top = DIGIT_ORIGIN_Y + row * DIGIT_CELL
    if x >= left and x <= left + DIGIT_CELL - 1 and y >= top and y <= top + DIGIT_CELL - 1 then
      self._gridCursor = digit
      pressGridKey(self, digit)
      return
    end
  end
  for _, action in ipairs(ACTIONS) do
    if x >= action.x and x <= action.x + action.width - 1 and y >= ACTION_ROW_Y and y <= ACTION_ROW_Y + ACTION_ROW_HEIGHT - 1 then
      self._gridCursor = action.role == "clear" and GRID_CLEAR
        or action.role == "confirm" and GRID_CONFIRM
        or GRID_CANCEL
      pressGridKey(self, self._gridCursor)
      return
    end
  end
  local cursorOffsets = offsets(self)
  for index = 1, self._numDigits do
    local left = cursorOffsets[index] - CURSOR_STRIP_WIDTH / 2
    if
      x >= left
      and x <= left + CURSOR_STRIP_WIDTH - 1
      and y >= CURSOR_STRIP_TOP
      and y <= CURSOR_STRIP_TOP + CURSOR_STRIP_HEIGHT - 1
    then
      self._cursor = index - 1
      return
    end
  end
end

-- The source task's input state machine: while it waits for input a fresh
-- pointer, the START confirm and the B back-walk are read in that order, then
-- the grid handler; a running blink owns its own ticks.
---@param uiEvents table[]
function BankScreenState:step(uiEvents)
  assert(not self._disposed, "a disposed amount screen steps nothing")
  assert(type(uiEvents) == "table", "the amount screen consumes the scheduler event list")
  if self._result ~= nil then
    return
  end
  for _, event in ipairs(uiEvents) do
    if self._result ~= nil then
      return
    end
    if event.type == "pointer_down" then
      tap(self, event.x, event.y)
    elseif event.type == "pointer_up" then
      local target = self:_hintAt(event.x, event.y)
      if target ~= nil then
        self._gridCursor = target
      end
    elseif event.type == "confirm" then
      self._gridCursor = GRID_CONFIRM
      pressGridKey(self, GRID_CONFIRM)
    elseif event.type == "cancel" then
      moveCursor(self, -1)
    elseif event.type == "navigate" then
      walkGrid(self, event.direction)
    elseif event.type == "button" then
      if event.button == "start" then
        self._gridCursor = GRID_CONFIRM
        pressGridKey(self, GRID_CONFIRM)
      end
    end
  end
  -- The pressed-key blink is the source's visual feedback; it shows the two
  -- source frames over the following ticks and never holds a later key back.
  if self._blink ~= nil then
    updateBlink(self)
  end
end

-- The source reads a pointer tap on release as the grid key under it; the
-- cursor only follows it, because the source key was already pressed on the
-- touch edge.
---@param x number
---@param y number
---@return integer? grid position
function BankScreenState:_hintAt(x, y)
  for digit = 0, 9 do
    local column = digit % DIGIT_COLUMNS
    local row = (digit - column) / DIGIT_COLUMNS
    local left = DIGIT_ORIGIN_X + column * DIGIT_CELL
    local top = DIGIT_ORIGIN_Y + row * DIGIT_CELL
    if x >= left and x <= left + DIGIT_CELL - 1 and y >= top and y <= top + DIGIT_CELL - 1 then
      return digit
    end
  end
  for _, action in ipairs(ACTIONS) do
    if x >= action.x and x <= action.x + action.width - 1 and y >= ACTION_ROW_Y and y <= ACTION_ROW_Y + ACTION_ROW_HEIGHT - 1 then
      if action.role == "clear" then
        return GRID_CLEAR
      elseif action.role == "confirm" then
        return GRID_CONFIRM
      end
      return GRID_CANCEL
    end
  end
  return nil
end

---@class BankScreenState.Status
---@field amount integer the amount the fixed cells spell
---@field maxAmount integer the maximum the screen was opened with
---@field maxDigits integer the source's actual digit-cell count
---@field cursor integer the selected cell
---@field gridKey integer the source dpad grid position
---@field blinkVisible boolean whether the pressed-key blink shows its first frame
---@field blinkTarget integer? the pressed key the blink belongs to
---@field digits integer[] the entered digit cells
---@field digitCells { x: integer, y: integer }[] the entered digit sprite anchors
---@field cursorCell { x: integer, y: integer } the underline cursor anchor
---@field cursorKeys { x: integer, y: integer, width: integer, height: integer }[] the entry cursor strips
---@field keys table[] the ten digit keys and the three action keys

---@return BankScreenState.Status
function BankScreenState:status()
  assert(not self._disposed, "a disposed amount screen has no status")
  assert(not self._taken, "a consumed amount screen has no status")
  local keys = {}
  for digit = 0, 9 do
    local column = digit % DIGIT_COLUMNS
    local row = (digit - column) / DIGIT_COLUMNS
    keys[#keys + 1] = {
      role = "digit",
      digit = digit,
      x = DIGIT_ORIGIN_X + column * DIGIT_CELL,
      y = DIGIT_ORIGIN_Y + row * DIGIT_CELL,
      width = DIGIT_CELL,
      height = DIGIT_CELL,
    }
  end
  for _, action in ipairs(ACTIONS) do
    keys[#keys + 1] = {
      role = action.role,
      x = action.x,
      y = ACTION_ROW_Y,
      width = action.width,
      height = ACTION_ROW_HEIGHT,
    }
  end
  local digitCells = {}
  local cursorOffsets = offsets(self)
  for index = 1, self._numDigits do
    digitCells[index] = { x = cursorOffsets[index], y = DIGIT_ROW_Y + 16 }
  end
  local cursorKeys = {}
  for index = 1, self._numDigits do
    cursorKeys[index] = {
      x = cursorOffsets[index] - CURSOR_STRIP_WIDTH / 2,
      y = CURSOR_STRIP_TOP,
      width = CURSOR_STRIP_WIDTH,
      height = CURSOR_STRIP_HEIGHT,
    }
  end
  local blink = self._blink
  local digits = {}
  for index = 1, MAX_DIGITS do
    digits[index] = self._digits[index]
  end
  return {
    amount = computeValue(self),
    maxAmount = self._max,
    maxDigits = self._numDigits,
    cursor = self._cursor,
    gridKey = self._gridCursor,
    blinkVisible = blink ~= nil and blink.visible == true,
    blinkTarget = blink ~= nil and blink.target or nil,
    digits = digits,
    digitCells = digitCells,
    cursorCell = { x = cursorOffsets[self._cursor + 1], y = CURSOR_ROW_Y + 16 },
    cursorKeys = cursorKeys,
    keys = keys,
  }
end

-- ScrCmd_BankTransaction reads one terminal result: the accepted amount, or
-- zero for a cancel. A result is consumed exactly once.
---@return { amount: integer }?
function BankScreenState:takeResult()
  assert(not self._disposed, "a disposed amount screen has no result")
  if self._result == nil or self._taken then
    return nil
  end
  self._taken = true
  return { amount = self._result.amount }
end

-- Releasing the pointer capture drops only the transient press state.
function BankScreenState:cancelPointerCapture()
  self._gridCursor = 0
end

function BankScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._blink = nil
  self._result = nil
end

return BankScreenState
