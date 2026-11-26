-- The bank keypad's display-case resolver: it places the source 256x192
-- number-entry display on the lower screen for the native, wide and tall
-- display cases, resolves the immutable content plan the draw site paints (the
-- composited source layer, the entered digit glyphs, the underline cursor and
-- the three button labels), and inverts pointer input from host units back into
-- the source display's own pixel coordinates. Nothing here mutates gameplay
-- state: the plan is a detached snapshot of the screen's published status.
--
-- Source authority: src/field/number_entry.c (the sRodata sprite anchors and
-- xOffsets the compiled manifest carries) and msg_0196's button labels.

local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

local BankInterface = {}
BankInterface.__index = BankInterface

-- The display cases the port presents: the native 1:1 lower display and the
-- windowed wide/tall cases that keep the source aspect.
BankInterface.DISPLAY_CASES = { "native", "wide", "tall" }

---@class BankInterface
---@field private _manifest table<string, unknown> the validated generated presentation
---@field private _measureDisplay fun(): table<string, unknown> live display measurement
---@field private _disposed boolean
---
---@param opts { manifest: table<string, unknown>, measureDisplay: fun(): table<string, unknown> }
---@return BankInterface
function BankInterface.new(opts)
  assert(type(opts) == "table", "the bank interface needs its options")
  local manifest = assert(opts.manifest, "the bank interface needs the generated presentation")
  assert(type(manifest.layer) == "table" and type(manifest.sprites) == "table", "the presentation carries its art")
  assert(type(opts.measureDisplay) == "function", "the bank interface needs live display measurement")
  return setmetatable({
    _manifest = manifest,
    _measureDisplay = opts.measureDisplay,
    _disposed = false,
  }, BankInterface)
end

---@return table<string, unknown>
function BankInterface:manifest()
  assert(not self._disposed, "a disposed bank interface has no manifest")
  return self._manifest
end

-- The source lower display the keypad paints, in its own pixels.
---@return { width: integer, height: integer }
function BankInterface:canvas()
  local display = assert(self._manifest.display, "the presentation carries its display size")
  return { width = display.width, height = display.height }
end

-- One display case's placement: the integer scale the lower display is drawn
-- at and its centered origin in the measured host bounds. The native case is
-- the source's own one-to-one surface.
---@param displayCase string "native"|"wide"|"tall"
---@return { case: string, scale: integer, x: number, y: number, width: integer, height: integer }
function BankInterface:placement(displayCase)
  assert(not self._disposed, "a disposed bank interface has no placement")
  local canvas = self:canvas()
  if displayCase == "native" then
    return { case = "native", scale = 1, x = 0, y = 0, width = canvas.width, height = canvas.height }
  end
  assert(displayCase == "wide" or displayCase == "tall", "the bank presents the native, wide or tall display case")
  local measured = self:_measureDisplay()
  local bounds = measured and (measured.auxiliary or measured.lower or measured.bounds) or nil
  if type(bounds) ~= "table" or type(bounds.width) ~= "number" then
    -- An unmeasured host still presents the source display one-to-one.
    return { case = displayCase, scale = 1, x = 0, y = 0, width = canvas.width, height = canvas.height }
  end
  local fit = LayoutGeometry.centeredFit(bounds, canvas.width, canvas.height)
  local scale = math.max(1, math.floor(fit.scale))
  local width, height = canvas.width * scale, canvas.height * scale
  return {
    case = displayCase,
    scale = scale,
    x = bounds.x + math.floor((bounds.width - width) / 2),
    y = bounds.y + math.floor((bounds.height - height) / 2),
    width = width,
    height = height,
  }
end

-- All three display cases in one pass, so a draw site or a test can assert the
-- complete presentation contract.
---@return table<string, { case: string, scale: integer, x: number, y: number, width: integer, height: integer }>
function BankInterface:placements()
  local result = {}
  for _, displayCase in ipairs(BankInterface.DISPLAY_CASES) do
    result[displayCase] = self:placement(displayCase)
  end
  return result
end

-- The content plan for one published screen status: the source layer, the
-- entered digits, the underline cursor, the pressed-key feedback and the three
-- labels. Every rect is in source display pixels.
---@param status table<string, unknown>
---@return table<string, unknown>
function BankInterface:plan(status)
  assert(not self._disposed, "a disposed bank interface draws nothing")
  assert(type(status) == "table", "the bank plan reads the screen status")
  local manifest = self._manifest
  local canvas = self:canvas()
  local layer = assert(manifest.layer, "the presentation carries its layer")
  local sprites = assert(manifest.sprites, "the presentation carries its sprites")
  local timing = assert(manifest.timing, "the presentation carries its timing")
  local digits = assert(status.digits, "the status carries the entered digit cells")
  local cells = assert(status.digitCells, "the status carries its digit anchors")

  local glyphs = {}
  for index = 1, math.min(timing.maxDigits, #digits) do
    local value = digits[index]
    local cell = cells[index]
    if type(value) == "number" and type(cell) == "table" and index - 1 < (status.maxDigits or 0) then
      local frame = sprites.digits[value + 1]
      if frame ~= nil then
        glyphs[#glyphs + 1] = {
          image = frame.image,
          source = { x = frame.x, y = frame.y, width = frame.width, height = frame.height },
          dest = { x = cell.x, y = cell.y, width = frame.width, height = frame.height },
          digit = value,
        }
      end
    end
  end

  local cursorFrame = sprites.cursor
  if type(status.gridKey) == "number" and status.gridKey >= 10 then
    cursorFrame = sprites.cursorButton
  end
  local gridKey = status.gridKey or 0
  local grid = assert(manifest.keys, "the presentation carries its key geometry")
  local cursorRect = nil
  if type(gridKey) == "number" and gridKey >= 0 and gridKey <= 9 then
    local cell = grid.digits[gridKey + 1]
    cursorRect = cell and { x = cell.x, y = cell.y, width = cell.width, height = cell.height } or nil
  elseif type(gridKey) == "number" then
    local position = grid.dpad[gridKey + 1]
    cursorRect = position
        and { x = position.x - 8, y = position.y - 8, width = cursorFrame.width, height = cursorFrame.height }
      or nil
  end

  local labels = {}
  for _, action in ipairs(assert(grid.actions, "the presentation carries its action row")) do
    local text = assert(manifest.labels[action.key], "the presentation carries its button labels")
    labels[#labels + 1] = {
      key = action.key,
      text = text,
      rect = { x = action.x, y = action.y, width = action.width, height = action.height },
    }
  end

  return {
    canvas = canvas,
    layer = { image = layer.image, width = layer.width, height = layer.height },
    glyphs = glyphs,
    cursor = {
      image = cursorFrame.image,
      source = { x = cursorFrame.x, y = cursorFrame.y, width = cursorFrame.width, height = cursorFrame.height },
      dest = cursorRect or { x = 0, y = 0, width = cursorFrame.width, height = cursorFrame.height },
    },
    underline = {
      image = sprites.underline.image,
      source = {
        x = sprites.underline.x,
        y = sprites.underline.y,
        width = sprites.underline.width,
        height = sprites.underline.height,
      },
      dest = {
        x = assert(status.cursorCell, "the status carries its cursor anchor").x,
        y = assert(status.cursorCell, "the status carries its cursor anchor").y,
        width = sprites.underline.width,
        height = sprites.underline.height,
      },
    },
    press = {
      visible = status.blinkVisible == true,
      target = status.blinkTarget,
      cells = assert(grid.digits, "the presentation carries its digit cells"),
    },
    labels = labels,
  }
end

-- One keypad cell's rectangle, exposed for the draw site's label measurements.
---@param key integer the pressed grid cell
---@return { x: integer, y: integer, width: integer, height: integer }
function BankInterface:labelRect(key)
  local grid = assert(self._manifest.keys, "the presentation carries its key geometry")
  for _, action in ipairs(assert(grid.actions, "the presentation carries its action row")) do
    if action.key == key then
      return { x = action.x, y = action.y, width = action.width, height = action.height }
    end
  end
  error("the bank presentation carries no " .. tostring(key) .. " button", 0)
end

-- Pointer events arrive in host units; the source screen's own pixel grid is
-- what the keypad's rectangles are written in. A pointer outside the placement
-- is marked `outside` so the screen ignores it, and a pointer inside carries the
-- inverted source coordinates.
---@param events table[]
---@param placement { scale: integer, x: number, y: number, width: integer, height: integer }
---@return table[]
function BankInterface:mapInput(events, placement)
  assert(not self._disposed, "a disposed bank interface takes no input")
  assert(type(events) == "table", "the bank interface consumes the scheduler event list")
  local resolved = placement or self:placement("native")
  local scale = math.max(1, resolved.scale or 1)
  local canvas = self:canvas()
  local mapped = {}
  for _, event in ipairs(events) do
    if event.type == "pointer_down" or event.type == "pointer_move" or event.type == "pointer_up" then
      local localX = (event.x - resolved.x) / scale
      local localY = (event.y - resolved.y) / scale
      local copy = {
        type = event.type,
        pointerId = event.pointerId,
        x = localX,
        y = localY,
      }
      if localX < 0 or localY < 0 or localX >= canvas.width or localY >= canvas.height then
        copy.outside = true
      end
      mapped[#mapped + 1] = copy
    else
      mapped[#mapped + 1] = event
    end
  end
  return mapped
end

-- Draw the resolved plan into the current render target. The bank renderer
-- borrows the leased images by generated path and never mutates the plan.
---@param plan table<string, unknown>
---@param images fun(path: string): table<string, unknown>?
function BankInterface.draw(plan, images)
  local lg = assert(love and love.graphics, "the bank keypad draws through its host graphics namespace")
  local layer = assert(images(plan.layer.image), "the keypad layer image is leased")
  lg.setColor(1, 1, 1, 1)
  lg.draw(layer, 0, 0)
  for _, glyph in ipairs(plan.glyphs) do
    local image = images(glyph.image)
    if image ~= nil then
      local quad =
        lg.newQuad(glyph.source.x, glyph.source.y, glyph.source.width, glyph.source.height, image:getDimensions())
      lg.draw(image, quad, glyph.dest.x, glyph.dest.y)
      quad:release()
    end
  end
  local underline = images(plan.underline.image)
  if underline ~= nil then
    local quad = lg.newQuad(
      plan.underline.source.x,
      plan.underline.source.y,
      plan.underline.source.width,
      plan.underline.source.height,
      underline:getDimensions()
    )
    lg.draw(underline, quad, plan.underline.dest.x, plan.underline.dest.y)
    quad:release()
  end
  if plan.press.visible then
    -- NumberEntry_StartBgBlink flips the pressed cell's palette: the port
    -- paints the same cell rect with the highlight tint for the two source
    -- frames instead of re-uploading the tilemap.
    for _, cell in ipairs(plan.press.cells) do
      if plan.press.target == cell.digit then
        local r, g, b, a = lg.getColor()
        lg.setColor(0.85, 0.85, 1, 0.45)
        lg.rectangle("fill", cell.x, cell.y, cell.width, cell.height)
        lg.setColor(r, g, b, a)
      end
    end
    if plan.press.target == "back" or plan.press.target == 2 then
      local rect = plan.labels[1] and plan.labels[1].rect
      if rect ~= nil then
        local r, g, b, a = lg.getColor()
        lg.setColor(0.85, 0.85, 1, 0.45)
        lg.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
        lg.setColor(r, g, b, a)
      end
    end
  end
  local cursor = images(plan.cursor.image)
  if cursor ~= nil then
    local quad = lg.newQuad(
      plan.cursor.source.x,
      plan.cursor.source.y,
      plan.cursor.source.width,
      plan.cursor.source.height,
      cursor:getDimensions()
    )
    lg.draw(cursor, quad, plan.cursor.dest.x, plan.cursor.dest.y)
    quad:release()
  end
end

function BankInterface:dispose()
  self._disposed = true
end

return BankInterface
