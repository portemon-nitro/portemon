-- The source number-entry keypad the Mom bank opens: its actual digit-cell
-- count for the maximum it was opened with, the source touch rectangles and
-- dpad grid, the fixed-cell value the player types, the BACK key that only
-- walks the cursor, the pressed-key blink and the one terminal result
-- (src/field/number_entry.c and its sRodata).

local Assert = require("tests.support.Assert")
local BankScreenState = require("game.hgss.src.bank.BankScreenState")

local T = {}

---@param status table
---@param role string "digit"|"clear"|"confirm"|"cancel"
---@param digit integer?
---@return table
local function key(status, role, digit)
  for _, candidate in ipairs(status.keys) do
    if candidate.role == role and (digit == nil or candidate.digit == digit) then
      return candidate
    end
  end
  error("the amount screen offers no " .. role .. " key", 0)
end

---@param screen BankScreenState
---@param rect table
---@param kind string? "down"|"up"
local function tap(screen, rect, kind)
  local x, y = rect.x + rect.width / 2, rect.y + rect.height / 2
  screen:step({ { type = kind or "pointer_down", pointerId = "test", x = x, y = y } })
end

---@param screen BankScreenState
---@param digits integer[]
local function typeDigits(screen, digits)
  for _, digit in ipairs(digits) do
    tap(screen, key(screen:status(), "digit", digit))
    tap(screen, key(screen:status(), "digit", digit), "pointer_up")
  end
end

-- NumberEntry_Init walks its 100000 threshold down by tens, so the cell count
-- follows the maximum the screen was opened with.
function T.the_digit_cell_count_follows_the_opening_maximum()
  for maximum, expected in pairs({ [0] = 1, [9] = 1, [99] = 2, [100] = 3, [3000] = 4, [99999] = 5, [999999] = 6 }) do
    local screen = BankScreenState.new(maximum)
    Assert.equal(screen:status().maxDigits, expected, "maximum " .. maximum .. " opens " .. expected .. " cells")
    Assert.equal(screen:status().maxAmount, maximum, "the screen keeps the maximum it was opened with")
    Assert.equal(screen:status().amount, 0, "the cells start empty")
    Assert.equal(#screen:status().keys, 13, "ten digit keys and the three action keys")
    screen:dispose()
  end
end

-- sRodata.padHitboxes: five 48-pixel columns from x 8, digits 0-4 on the first
-- row at y 56 and 5-9 on the second at y 104, then the three action buttons on
-- their own 32-pixel row at y 160.
function T.the_keys_keep_their_source_rectangles()
  local screen = BankScreenState.new(999999)
  local status = screen:status()
  for digit = 0, 9 do
    local rect = key(status, "digit", digit)
    local column = digit % 5
    local row = (digit - column) / 5
    Assert.deepEqual(rect, {
      role = "digit",
      digit = digit,
      x = 8 + column * 48,
      y = 56 + row * 48,
      width = 48,
      height = 48,
    }, "digit " .. digit .. " keeps its source rectangle")
  end
  Assert.deepEqual(key(status, "clear"), { role = "clear", x = 0, y = 160, width = 80, height = 32 })
  Assert.deepEqual(key(status, "confirm"), { role = "confirm", x = 88, y = 160, width = 80, height = 32 })
  Assert.deepEqual(key(status, "cancel"), { role = "cancel", x = 176, y = 160, width = 80, height = 32 })
  screen:dispose()
end

-- sRodata.xOffsets: the entered digits sit on the source x offsets for the
-- open cell count, and the underline cursor follows the selected cell.
function T.the_entered_digits_and_cursor_use_the_source_offsets()
  local screen = BankScreenState.new(3000)
  local shown = screen:status()
  Assert.deepEqual(shown.digitCells, { { x = 80, y = 40 }, { x = 112, y = 40 }, { x = 144, y = 40 }, { x = 176, y = 40 } })
  Assert.deepEqual(shown.cursorCell, { x = 80, y = 52 }, "the cursor starts under the first cell")
  typeDigits(screen, { 7 })
  Assert.equal(screen:status().cursor, 1, "a digit advances the cursor")
  Assert.deepEqual(screen:status().cursorCell, { x = 112, y = 52 }, "the cursor moves with the entry")
  Assert.deepEqual(screen:status().digits, { 7, 0, 0, 0, 0, 0 }, "the digit lands in the first cell")
  screen:dispose()
end

-- NumberEntry_SetDigit/ComputeValue: the value is the fixed cells, most
-- significant first, so two typed digits in a four-cell entry spell thousands.
function T.the_value_reads_the_fixed_cells()
  local screen = BankScreenState.new(3000)
  typeDigits(screen, { 5, 6 })
  Assert.equal(screen:status().amount, 5600, "typing 5 then 6 fills the first two of four cells")
  typeDigits(screen, { 0, 0 })
  Assert.equal(screen:status().amount, 5600, "the trailing cells keep the typed value")
  screen:dispose()
end

-- The cursor clamps into the cells, and the source BACK key only walks it left.
function T.the_back_key_walks_the_cursor_without_clearing_the_cells()
  local screen = BankScreenState.new(3000)
  typeDigits(screen, { 1, 2 })
  tap(screen, key(screen:status(), "clear"))
  tap(screen, key(screen:status(), "clear"), "pointer_up")
  Assert.equal(screen:status().cursor, 1, "BACK walks one cell left")
  Assert.deepEqual(screen:status().digits, { 1, 2, 0, 0, 0, 0 }, "BACK leaves the fixed cells alone")
  Assert.equal(screen:status().amount, 1200, "the value is unchanged")
  tap(screen, key(screen:status(), "clear"))
  tap(screen, key(screen:status(), "clear"), "pointer_up")
  tap(screen, key(screen:status(), "clear"))
  tap(screen, key(screen:status(), "clear"), "pointer_up")
  Assert.equal(screen:status().cursor, 0, "BACK clamps at the first cell")
  screen:dispose()
end

-- NumberEntry_UpdateBlink: one blink paints the first frame, holds it for four
-- ticks, then the second frame for two.
function T.a_pressed_key_blinks_for_the_source_frame_count()
  local screen = BankScreenState.new(3000)
  typeDigits(screen, { 1 })
  local shown = screen:status()
  Assert.isTrue(shown.blinkVisible, "the pressed key blinks its first frame")
  Assert.equal(shown.blinkTarget, 1, "the blink belongs to the pressed digit key")
  local phasesSeen = 0
  local last = shown.blinkVisible
  for _ = 1, 20 do
    screen:step({})
    local current = screen:status()
    if current.blinkVisible ~= last then
      phasesSeen = phasesSeen + 1
      last = current.blinkVisible
    end
    if current.blinkTarget == nil then
      break
    end
  end
  Assert.equal(phasesSeen, 1, "the blink toggles exactly once and then ends")
  Assert.isNil(screen:status().blinkTarget, "the blink ends after its two frames")
  screen:dispose()
end

-- ScrCmd_BankTransaction's result: a confirmed amount at most the maximum
-- completes once, a cancel reports zero, and an amount above the maximum only
-- blinks the confirm key.
function T.confirm_cancel_and_the_over_maximum_refusal_are_one_terminal_result()
  local accepted = BankScreenState.new(3000)
  typeDigits(accepted, { 1, 2, 0, 0 })
  tap(accepted, key(accepted:status(), "confirm"))
  Assert.deepEqual(accepted:takeResult(), { amount = 1200 }, "the confirmed amount is the terminal result")
  Assert.isNil(accepted:takeResult(), "the result is consumed exactly once")
  accepted:dispose()

  local cancelled = BankScreenState.new(3000)
  typeDigits(cancelled, { 7, 5, 0 })
  tap(cancelled, key(cancelled:status(), "cancel"))
  Assert.deepEqual(cancelled:takeResult(), { amount = 0 }, "a cancel reports the source zero")
  cancelled:dispose()

  local refused = BankScreenState.new(3000)
  typeDigits(refused, { 9, 0, 0, 0 })
  tap(refused, key(refused:status(), "confirm"))
  Assert.isNil(refused:takeResult(), "an amount above the maximum does not complete")
  Assert.equal(refused:status().blinkTarget, 3, "the confirm key blinks its refusal")
  refused:dispose()
end

-- The source grid walks with the dpad and answers START as confirm.
function T.the_dpad_grid_walks_and_start_confirms()
  local screen = BankScreenState.new(99)
  screen:step({ { type = "navigate", direction = "right" } })
  Assert.equal(screen:status().gridKey, 1, "the grid cursor walks right")
  screen:step({ { type = "navigate", direction = "down" } })
  Assert.equal(screen:status().gridKey, 6, "the second row sits below the first")
  screen:step({ { type = "navigate", direction = "down" } })
  Assert.equal(screen:status().gridKey, 10, "the second digit row walks down into the clear key")
  screen:step({ { type = "button", button = "start" } })
  Assert.deepEqual(screen:takeResult(), { amount = 0 }, "START confirms the entry")
  screen:dispose()
end

return { tests = T }
