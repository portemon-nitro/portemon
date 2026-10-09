-- Pure profile selector, confirmation, and name-editor geometry for Oak intro.

local ImageButton = require("libs.ui.src.ImageButton")

---@class OakGenderCardEntry
---@field key string
---@field rect table<string, number>
---@field scale number
---@field portraitId string
---@field portraitRect table<string, number>
---@field button table<string, unknown>

local OakProfileLayout = {}

local function rect(x, y, width, height)
  assert(width > 0 and height > 0, "Oak layout rectangle must be positive")
  return { x = x, y = y, width = width, height = height }
end

---@param selectorCanvas { scale: number, origin: { x: number, y: number } }
---@param manifest table<string, unknown>
---@return table<integer, OakGenderCardEntry>
function OakProfileLayout.genderSelectionEntries(selectorCanvas, manifest)
  local entries = {}
  for index, sourceGender in ipairs({ "male", "female" }) do
    local sourceCard = assert(manifest.genderSelector.buttons[sourceGender]).bounds
    local cardRect = rect(
      selectorCanvas.origin.x + sourceCard.x * selectorCanvas.scale,
      selectorCanvas.origin.y + sourceCard.y * selectorCanvas.scale,
      sourceCard.width * selectorCanvas.scale,
      sourceCard.height * selectorCanvas.scale
    )
    local widget = assert(manifest.widgets["gender_" .. sourceGender])
    local center = assert(widget.sourceCenter)
    local portrait = {
      x = selectorCanvas.origin.x + center.x * selectorCanvas.scale - widget.anchor.x * selectorCanvas.scale,
      y = selectorCanvas.origin.y + center.y * selectorCanvas.scale - widget.anchor.y * selectorCanvas.scale,
      width = widget.width * selectorCanvas.scale,
      height = widget.height * selectorCanvas.scale,
      scale = selectorCanvas.scale,
    }
    -- The source card is taller above the portrait than below it; keep the
    -- correct bottom edge fixed and lift the top so both paddings match.
    local bottomPad = (cardRect.y + cardRect.height) - (portrait.y + portrait.height)
    assert(bottomPad >= 0, "Oak gender portrait must fit inside its card")
    local cardTop = portrait.y - bottomPad
    cardRect = rect(cardRect.x, cardTop, cardRect.width, (cardRect.y + cardRect.height) - cardTop)
    entries[index - 1] = {
      key = sourceGender,
      rect = cardRect,
      scale = selectorCanvas.scale,
      portraitId = "gender_" .. sourceGender,
      portraitRect = portrait,
      button = ImageButton.resolve({ rect = cardRect, scale = selectorCanvas.scale, cornerRadius = 6 }),
    }
  end
  return entries
end

return OakProfileLayout
