-- Concrete selected-game appearance shared by Portemon product menus.

local ImageButton = require("libs.ui.src.ImageButton")

local ProductMenuSkin = {}

---@class ProductMenuSkin.CardColors
---@field face number[]
---@field border number[]
---@field rim number[]
---@field selectedRim number[]
---@field innerBorder number[]

---@class ProductMenuSkin.TextPalette
---@field foreground { r:number, g:number, b:number }
---@field shadow { r:number, g:number, b:number }
---@field background { r:number, g:number, b:number, a:number }

---@alias ProductMenuSkin.CardVariant "normal"|"inset"|"overflow"
---@alias ProductMenuSkin.TextRole "normal"|"information"|"hint"|"error"

---@class ProductMenuSkin
---@field background number[]
---@field cards { normal:ProductMenuSkin.CardColors, inset:ProductMenuSkin.CardColors, overflow:ProductMenuSkin.CardColors, disabled:{normal:ProductMenuSkin.CardColors, inset:ProductMenuSkin.CardColors, overflow:ProductMenuSkin.CardColors} }
---@field text { normal:ProductMenuSkin.TextPalette, information:ProductMenuSkin.TextPalette, hint:ProductMenuSkin.TextPalette, error:ProductMenuSkin.TextPalette }

local BACKGROUNDS = {
  heartgold = { 0xC3 / 255, 0x82 / 255, 0x30 / 255 },
  soulsilver = { 0x61 / 255, 0x61 / 255, 0xFB / 255 },
}

local CARD_FACE = { 0xFB / 255, 0xFB / 255, 0xFB / 255, 1 }
local CARD_INNER_BORDER = { 0xA2 / 255, 0xE3 / 255, 0xDB / 255, 1 }
local CARD_BORDER = { 0x30 / 255, 0x49 / 255, 0x61 / 255, 1 }
local CARD_SELECTED_RIM = { 1, 58 / 255, 58 / 255, 1 }
local DISABLED_FACE = { 0xE4 / 255, 0xE6 / 255, 0xE6 / 255, 1 }
local DISABLED_BORDER = { 0x70 / 255, 0x79 / 255, 0x7D / 255, 1 }
local DISABLED_RIM = { 0xB0 / 255, 0xB7 / 255, 0xB9 / 255, 1 }
local CARD_RADIUS = 6
local CARD_INNER_WIDTH = 2

local INK = { 0.12, 0.18, 0.25 }
local ERROR_INK = { 0.65, 0.22, 0.22 }

local function copyArray(source)
  local result = {}
  for index, value in ipairs(source) do
    result[index] = value
  end
  return result
end

local function textPalette(foreground, shadow)
  return {
    foreground = { r = foreground.r, g = foreground.g, b = foreground.b },
    shadow = { r = shadow.r, g = shadow.g, b = shadow.b },
    background = { r = 0, g = 0, b = 0, a = 0 },
  }
end

local function cardColors(face, border, rim, innerBorder)
  return {
    face = copyArray(face),
    border = copyArray(border),
    rim = copyArray(rim),
    selectedRim = copyArray(CARD_SELECTED_RIM),
    innerBorder = copyArray(innerBorder),
  }
end

local function createCards()
  return {
    normal = cardColors(CARD_FACE, CARD_BORDER, CARD_BORDER, CARD_INNER_BORDER),
    inset = cardColors(CARD_FACE, CARD_BORDER, CARD_BORDER, CARD_FACE),
    overflow = cardColors(CARD_FACE, CARD_FACE, CARD_FACE, CARD_FACE),
    disabled = {
      normal = cardColors(DISABLED_FACE, DISABLED_BORDER, DISABLED_RIM, DISABLED_BORDER),
      inset = cardColors(DISABLED_FACE, DISABLED_BORDER, DISABLED_RIM, DISABLED_FACE),
      overflow = cardColors(DISABLED_FACE, DISABLED_FACE, DISABLED_FACE, DISABLED_FACE),
    },
  }
end

local function createText()
  local normalForeground = { r = INK[1] * 255, g = INK[2] * 255, b = INK[3] * 255 }
  local shadow = { r = 140, g = 140, b = 140 }
  local palette = textPalette(normalForeground, shadow)
  return {
    normal = palette,
    hint = textPalette(normalForeground, shadow),
    information = {
      foreground = { r = 0, g = 113, b = 251 },
      shadow = { r = 0, g = 81, b = 251 },
      background = { r = 0, g = 0, b = 0, a = 0 },
    },
    error = textPalette({ r = ERROR_INK[1] * 255, g = ERROR_INK[2] * 255, b = ERROR_INK[3] * 255 }, shadow),
  }
end

---@param versionId string
---@return ProductMenuSkin skin an owned appearance record for one renderer
function ProductMenuSkin.forVersion(versionId)
  assert(type(versionId) == "string" and versionId ~= "", "product menu skin requires a game version")
  local background = assert(BACKGROUNDS[versionId], "product menu skin does not support game version: " .. versionId)
  return {
    background = copyArray(background),
    cards = createCards(),
    text = createText(),
  }
end

---@param graphics love.graphics
---@param skin ProductMenuSkin
---@param rect { x:number, y:number, width:number, height:number }
---@param variant ProductMenuSkin.CardVariant
---@param focused boolean
---@param disabled boolean
function ProductMenuSkin.drawCard(graphics, skin, rect, variant, focused, disabled)
  assert(type(skin) == "table" and type(skin.cards) == "table", "product menu card needs a skin")
  assert(variant == "normal" or variant == "inset" or variant == "overflow", "unknown product menu card variant")
  assert(type(focused) == "boolean", "product menu focus state must be boolean")
  assert(type(disabled) == "boolean", "product menu disabled state must be boolean")
  local styles = disabled and skin.cards.disabled or skin.cards
  local colors = assert(styles[variant], "product menu skin is missing a card variant")
  local resolved = ImageButton.resolve({
    rect = rect,
    scale = 1,
    cornerRadius = CARD_RADIUS,
    innerBorderWidth = CARD_INNER_WIDTH,
  })
  local content = assert(resolved.contentRect)
  ImageButton.draw(graphics, resolved, {
    selected = focused,
    colors = colors,
    imageRect = { x = content.x, y = content.y, width = content.width, height = content.height },
    drawImage = function() end,
  })
end

---@param graphics love.graphics
---@param textRenderer table<string, function>
---@param skin ProductMenuSkin
---@param role ProductMenuSkin.TextRole
---@param text string
---@param x number
---@param y number
function ProductMenuSkin.drawText(graphics, textRenderer, skin, role, text, x, y)
  assert(type(skin) == "table" and type(skin.text) == "table", "product menu text needs a skin")
  assert(
    role == "normal" or role == "information" or role == "hint" or role == "error",
    "unknown product menu text role"
  )
  local palette = assert(skin.text[role], "product menu skin is missing a text role")
  graphics.setColor(1, 1, 1, 1)
  local ok, err = pcall(textRenderer.drawTextWithPalette, textRenderer, text, x, y, palette)
  graphics.setColor(1, 1, 1, 1)
  if not ok then
    error(err, 0)
  end
end

return ProductMenuSkin
