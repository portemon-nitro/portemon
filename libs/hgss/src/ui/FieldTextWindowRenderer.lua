-- One field text window: the borrowed frame primitive paints the caller
-- content box, then the borrowed text primitive prints each supplied line
-- at its exact window-local origin with the caller palette. This owns no
-- images, frames, padding, or policy; every placement and color decision
-- arrives explicitly in the draw record.

local FieldTextWindowRenderer = {}

---@param box table<string, number> the caller content box
local function checkBox(box)
  assert(type(box.x) == "number" and type(box.y) == "number", "the content box carries its origin")
  assert(
    type(box.width) == "number" and type(box.height) == "number" and box.width > 0 and box.height > 0,
    "the content box carries its size"
  )
end

---@param background number[] the caller content fill color
local function checkBackground(background)
  assert(
    type(background[1]) == "number" and type(background[2]) == "number" and type(background[3]) == "number",
    "the content fill carries its color"
  )
end

---@param palette { foreground: { r: number, g: number, b: number }, shadow: { r: number, g: number, b: number }, background: { r: number, g: number, b: number, a: number? } } the caller text palette
local function checkPalette(palette)
  for _, role in ipairs({ "foreground", "shadow", "background" }) do
    local color = palette[role]
    assert(type(color) == "table", "the text palette carries its " .. role)
    assert(
      type(color.r) == "number" and type(color.g) == "number" and type(color.b) == "number",
      "the text palette " .. role .. " carries its color"
    )
  end
end

---@param lines { text: string, x: number, y: number }[] the exact window-local placements
local function checkLines(lines)
  assert(type(lines) == "table" and #lines >= 1, "at least one text line is required")
  for index, line in ipairs(lines) do
    assert(type(line) == "table", "text line " .. index .. " carries its placement")
    assert(type(line.text) == "string", "text line " .. index .. " carries its text")
    assert(
      type(line.x) == "number" and type(line.y) == "number",
      "text line " .. index .. " carries its window-local origin"
    )
  end
end

-- Draws one text window: the frame/fill first, then each line at
-- box.x + line.x, box.y + line.y with no implicit padding. Every input is
-- validated before anything draws, so a malformed record draws nothing.
---@param spec { window: table<string, unknown>, text: table<string, unknown>, box: { x: number, y: number, width: number, height: number }, frameIndex: integer?, background: number[], palette: { foreground: { r: number, g: number, b: number }, shadow: { r: number, g: number, b: number }, background: { r: number, g: number, b: number, a: number? } }, lines: { text: string, x: number, y: number }[] }
function FieldTextWindowRenderer.draw(spec)
  assert(type(spec) == "table", "a draw record is required")
  local window = assert(spec.window, "the borrowed window primitive is required")
  assert(type(window.drawWindow) == "function", "the borrowed window primitive draws framed windows")
  local text = assert(spec.text, "the borrowed text primitive is required")
  assert(type(text.drawTextWithPalette) == "function", "the borrowed text primitive prints palette text")
  local box = assert(spec.box, "the content box is required")
  checkBox(box)
  local background = assert(spec.background, "the content fill is required")
  checkBackground(background)
  local palette = assert(spec.palette, "the text palette is required")
  checkPalette(palette)
  local lines = assert(spec.lines, "the text lines are required")
  checkLines(lines)
  window:drawWindow(box, spec.frameIndex, background)
  for _, line in ipairs(lines) do
    text:drawTextWithPalette(line.text, box.x + line.x, box.y + line.y, palette)
  end
end

return FieldTextWindowRenderer
