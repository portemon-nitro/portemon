-- The bank keypad's display-case resolver: the source 256x192 display in the
-- native, wide and tall cases, the exact source rectangles the keypad paints,
-- the immutable content plan (layer, entered digits, underline, pressed-key
-- feedback, labels) and the pointer inversion from host units into the source
-- pixel grid.

local Assert = require("tests.support.Assert")
local BankInterface = require("game.hgss.src.bank.BankInterface")

local T = {}

-- The validated presentation shape the compiled bundle carries; the rects are
-- the source sRodata geometry the compiled manifest also carries.
local function manifest()
  local digits = {}
  for digit = 0, 9 do
    local column = digit % 5
    local row = (digit - column) / 5
    digits[digit + 1] = { digit = digit, x = 8 + column * 48, y = 56 + row * 48, width = 48, height = 48 }
  end
  local dpad = {}
  for index = 1, 13 do
    dpad[index] = { x = 32, y = 80, up = 0, down = 0, left = 0, right = 0 }
  end
  local cursorStrips = {}
  for count = 1, 6 do
    cursorStrips[count] = {}
    for index = 1, count do
      cursorStrips[count][index] = { x = 48 + index * 4, y = 8, width = 32, height = 32 }
    end
  end
  local function frame(x, digit)
    return { image = "assets/generated/bank/sprites.png", x = x, y = 0, width = 32, height = 32, digit = digit }
  end
  local glyphs = {}
  for digit = 0, 9 do
    glyphs[digit + 1] = frame(digit * 32, digit)
  end
  return {
    schema = "g4-bank-presentation-v1",
    display = { width = 256, height = 192 },
    layer = { image = "assets/generated/bank/keypad.png", width = 256, height = 256 },
    sprites = {
      atlas = "assets/generated/bank/sprites.png",
      atlasWidth = 256,
      atlasHeight = 32,
      cursor = frame(0),
      cursorButton = frame(32),
      underline = frame(64),
      back = frame(96),
      confirm = frame(128),
      quit = frame(160),
      digits = glyphs,
    },
    keys = {
      digits = digits,
      actions = {
        { key = "back", x = 0, y = 160, width = 80, height = 32 },
        { key = "confirm", x = 88, y = 160, width = 80, height = 32 },
        { key = "quit", x = 176, y = 160, width = 80, height = 32 },
      },
      dpad = dpad,
      cursorStrips = cursorStrips,
    },
    labels = { back = "BACK", confirm = "CONFIRM", quit = "QUIT" },
    timing = { blinkFirstTicks = 4, blinkSecondTicks = 2, maxDigits = 6 },
  }
end

local function interface(measured)
  return BankInterface.new({
    manifest = manifest(),
    measureDisplay = function()
      return measured or { auxiliary = { x = 0, y = 0, width = 256, height = 192 } }
    end,
  })
end

---@return table a published screen status for the fixture
local function status(overrides)
  local cellOffsets = { 80, 112, 144, 176 }
  local digitCells = {}
  for index, x in ipairs(cellOffsets) do
    digitCells[index] = { x = x, y = 40 }
  end
  local value = {
    amount = 1200,
    maxAmount = 3000,
    maxDigits = 4,
    cursor = 0,
    gridKey = 1,
    blinkVisible = false,
    blinkTarget = nil,
    digits = { 1, 2, 0, 0, 0, 0 },
    digitCells = digitCells,
    cursorCell = { x = 80, y = 52 },
    keys = {},
  }
  for key, override in pairs(overrides or {}) do
    value[key] = override
  end
  return value
end

-- The native case presents the source display one-to-one and the wide/tall
-- cases center an integral scale of it inside the measured bounds.
function T.the_three_display_cases_place_the_source_display()
  local native = interface():placement("native")
  Assert.deepEqual(native, { case = "native", scale = 1, x = 0, y = 0, width = 256, height = 192 })
  local wide = interface({ auxiliary = { x = 0, y = 0, width = 640, height = 480 } }):placement("wide")
  Assert.equal(wide.scale, 2, "the wide case scales the display by whole pixels")
  Assert.equal(wide.width, 512, "the placed display keeps its source aspect")
  Assert.equal(wide.x, 64, "the wide case centers the display")
  local tall = interface({ auxiliary = { x = 0, y = 0, width = 256, height = 192 } }):placement("tall")
  Assert.equal(tall.scale, 1, "an exactly fitting host keeps the source scale")
  Assert.deepEqual(
    (function()
      local names = {}
      for name in pairs(interface():placements()) do
        names[#names + 1] = name
      end
      table.sort(names)
      return names
    end)(),
    { "native", "tall", "wide" },
    "all three display cases resolve"
  )
end

-- The plan carries the layer, the entered digits at their source anchors, the
-- underline cursor, the labels and the pressed-key feedback.
function T.the_plan_carries_the_source_content()
  local plan = interface():plan(status())
  Assert.equal(plan.canvas.width, 256, "the plan paints the source display")
  Assert.equal(plan.layer.image, "assets/generated/bank/keypad.png", "the plan borrows the composited layer")
  Assert.equal(#plan.glyphs, 4, "the four entry cells paint their digits")
  Assert.deepEqual(plan.glyphs[1].dest, { x = 80, y = 40, width = 32, height = 32 }, "the first digit rides its cell")
  Assert.equal(plan.glyphs[2].digit, 2, "the glyphs are the entered digits in order")
  Assert.deepEqual(
    plan.underline.dest,
    { x = 80, y = 52, width = 32, height = 32 },
    "the underline sits under the selected cell"
  )
  Assert.equal(#plan.labels, 3, "the three source labels ride the action row")
  Assert.deepEqual(plan.labels[1], {
    key = "back",
    text = "BACK",
    rect = { x = 0, y = 160, width = 80, height = 32 },
  }, "the action row keeps its source rectangles")
  Assert.isFalse(plan.press.visible, "no key is pressed in this status")

  local blinking = interface():plan(status({ blinkVisible = true, blinkTarget = 3 }))
  Assert.isTrue(blinking.press.visible, "the pressed-key feedback is carried")
  Assert.equal(blinking.press.target, 3, "the feedback names its key")
end

-- The cursor frame follows the source grid: the pad cursor on the digit grid and
-- the button cursor on the action row.
function T.the_cursor_frame_follows_the_grid_position()
  local onPad = interface():plan(status({ gridKey = 4 }))
  Assert.equal(onPad.cursor.source.x, 0, "the digit grid uses the pad cursor frame")
  local onRow = interface():plan(status({ gridKey = 11 }))
  Assert.equal(onRow.cursor.source.x, 32, "the action row uses the button cursor frame")
end

-- Pointer events invert from host units into the source pixel grid, and a
-- pointer outside the placement is marked so the keypad ignores it.
function T.pointer_events_invert_into_source_pixels()
  local wide = interface({ auxiliary = { x = 0, y = 0, width = 640, height = 480 } }):placement("wide")
  local mapped = interface():mapInput({
    -- The wide placement centers the 512x384 display at (64,48).
    { type = "pointer_down", pointerId = "mouse:1", x = wide.x + wide.scale * 20, y = wide.y + wide.scale * 70 },
    { type = "pointer_up", pointerId = "mouse:1", x = 0, y = 0 },
    { type = "navigate", direction = "right" },
  }, wide)
  Assert.equal(mapped[1].x, 20, "the pointer x inverts through the placement scale")
  Assert.equal(mapped[1].y, 70, "the pointer y inverts through the placement scale")
  Assert.isNil(mapped[1].outside, "a pointer inside the placement is admitted")
  Assert.isTrue(mapped[2].outside, "a pointer at the host origin is outside the placed display")
  Assert.deepEqual(mapped[3], { type = "navigate", direction = "right" }, "navigation passes through unchanged")
end

return { tests = T }
