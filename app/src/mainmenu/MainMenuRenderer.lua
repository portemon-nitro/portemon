-- Product-owned Main Menu presentation over the shared image-button chrome
-- and the generated field font. All drawing is logical pixels inside one
-- root placement: text, chrome and hit bounds share the transform, and no
-- inner helper multiplies by a presentation scale. Launcher colors live
-- here; the Oak selector owns its own tone recipe separately.

local LogicalSurface = require("libs.ui.src.LogicalSurface")
local ProductMenuSkin = require("app.src.ui.ProductMenuSkin")

---@class MainMenuRenderer
---@field text table<string, function>
---@field graphics love.graphics
---@field versionId string
---@field background number[]
---@field skin ProductMenuSkin
local MainMenuRenderer = {}
MainMenuRenderer.__index = MainMenuRenderer
local MARK = { 0.85, 0.88, 0.9, 1 }
local MARK_EDGE = { 0.35, 0.4, 0.45, 1 }

local CARD_INSET = 10

local function setColor(graphics, color)
  graphics.setColor(color[1], color[2], color[3], color[4] or 1)
end

-- Centered profile-block share of the Continue body width.
local PROFILE_BLOCK_WIDTH_FRACTION = 0.62

-- Generated font defs carry their ROM line advance (font-0: 16). Headless
-- text doubles carry no fontDef, so fall back to that same advance rather
-- than inventing per-scale offsets; every use below is logical units.
local FALLBACK_LINE_HEIGHT = 16

local function cardTitle(item)
  if item.canContinue then
    return item.playerName or "Save unavailable"
  end
  return item.errorSummary or "Save unavailable"
end

-- Continue-card profile rows in one centered block: labels share the block
-- left edge while values right-align to the block right edge through the
-- generated-font measure. The vertical area between the heading and the
-- card's bottom padding splits into three equal bands with each row
-- vertically centered by the canonical font line advance. The badge count
-- is the durable progression count supplied in the saved-game view.
---@param graphics love.graphics
---@param text table<string, function>
---@param skin ProductMenuSkin
---@param body { x: number, y: number, width: number, height: number }
---@param regionTop number
---@param lineHeight number
---@param playerName string
---@param playTimeLabel string
---@param badgeCount integer
local function drawProfileRows(graphics, text, skin, body, regionTop, lineHeight, playerName, playTimeLabel, badgeCount)
  local blockWidth = body.width * PROFILE_BLOCK_WIDTH_FRACTION
  local blockLeft = body.x + (body.width - blockWidth) / 2
  local blockRight = blockLeft + blockWidth
  local regionBottom = body.y + body.height - CARD_INSET
  local bandHeight = (regionBottom - regionTop) / 3
  local rows = {
    { label = "PLAYER", value = playerName },
    { label = "TIME", value = playTimeLabel },
    { label = "BADGES", value = tostring(badgeCount) },
  }
  for index, row in ipairs(rows) do
    local y = regionTop + (index - 1) * bandHeight + (bandHeight - lineHeight) / 2
    local valueWidth = text:textWidth(row.value)
    ProductMenuSkin.drawText(graphics, text, skin, "information", row.label, blockLeft, y)
    ProductMenuSkin.drawText(graphics, text, skin, "information", row.value, blockRight - valueWidth, y)
  end
end

-- Presentation-only ASCII casing: saved names and model values keep their
-- stored form; only the drawn copy is uppercased. Bytes without an ASCII
-- lowercase pair pass through unchanged.
local function displayUpper(value)
  return (value:gsub("[a-z]", function(c)
    return string.char(c:byte() - 32)
  end))
end

---@param options { text: table<string, function>, versionId: string, graphics?: love.graphics }
---@return MainMenuRenderer
function MainMenuRenderer.new(options)
  assert(type(options) == "table" and options.text, "Main Menu renderer requires FieldTextRenderer")
  local graphics = options.graphics or love.graphics
  ---@cast graphics love.graphics
  assert(graphics, "Main Menu renderer requires graphics")
  assert(type(options.text.drawTextWithPalette) == "function", "Main Menu renderer requires palette text drawing")
  local versionId = options.versionId
  assert(type(versionId) == "string" and versionId ~= "", "Main Menu renderer requires a game version")
  ---@cast versionId string
  local skin = ProductMenuSkin.forVersion(versionId)
  return setmetatable({
    text = options.text,
    graphics = graphics,
    versionId = versionId,
    background = skin.background,
    skin = skin,
  }, MainMenuRenderer)
end

---@param view table<string, unknown>
---@param plan ApplicationPlan the resolved interface plan carrying the content pane
function MainMenuRenderer:draw(view, plan)
  local graphics = self.graphics
  local layout = assert(view.layout)
  local shaped = layout --[[@as { viewport: table<string, number>, saves: table<string, unknown>, global: table<string, unknown> }]]
  local panes = assert(plan.panes, "Main Menu draws its content pane")
  local pane = assert(panes[1], "Main Menu draws its content pane")
  local placement = assert(pane.placement, "the menu pane carries its placement")
  local text = self.text
  local skin = self.skin
  ---@param rect { x:number, y:number, width:number, height:number }
  ---@param variant ProductMenuSkin.CardVariant
  ---@param focused boolean
  local function drawSkinCard(rect, variant, focused)
    local chromed = rect --[[@as { button: table<string, unknown> }]]
    ProductMenuSkin.drawCard(graphics, skin, chromed.button, variant, focused, false)
  end
  ---@param role ProductMenuSkin.TextRole
  ---@param value string
  ---@param x number
  ---@param y number
  local function drawSkinText(role, value, x, y)
    ProductMenuSkin.drawText(graphics, text, skin, role, value, x, y)
  end
  local shapedText = text --[[@as { fontDef: FieldFontDef|nil }]]
  local fontDef = shapedText.fontDef
  local lineHeight = (fontDef and fontDef.lineHeight) or FALLBACK_LINE_HEIGHT

  local red, green, blue, alpha = graphics.getColor()
  local lineWidth = graphics.getLineWidth()
  local background = self.background
  -- The startup surface has no paused field beneath it: paint the leaf-owned
  -- host background regions before the logical content.
  local content = assert(plan.content, "the menu plan carries its logical content")
  local hostBackgrounds = assert(content.hostBackgrounds, "the menu content carries its host backgrounds")
  graphics.setColor(0, 0, 0, 1)
  for _, rect in ipairs(hostBackgrounds) do
    graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  end
  graphics.setColor(red, green, blue, alpha)
  LogicalSurface.draw(graphics, placement, function()
    local ok, err = xpcall(function()
      -- The menu owns exactly its logical viewport: fill it, never clear
      -- an unrelated host surface.
      local viewport = shaped.viewport
      graphics.setColor(background[1], background[2], background[3], 1)
      graphics.rectangle("fill", 0, 0, viewport.width, viewport.height)

      local focus = assert(view.focus)
      local saves = assert(shaped.saves)
      local shapedSaves = saves --[[@as { viewport: table<string, number>, cards: table<string, table<string, unknown>> }]]
      LogicalSurface.clip(graphics, shapedSaves.viewport, function()
        if view.catalogError and view.catalogError ~= "" then
          local errorRect = assert(layout.catalogErrorRect)
          local shapedError = errorRect --[[@as table<string, number>]]
          drawSkinText(
            "error",
            displayUpper("Save catalog unavailable"),
            shapedError.x + CARD_INSET,
            shapedError.y + CARD_INSET
          )
        end
        for _, item in ipairs(assert(view.saves)) do
          local card = shapedSaves.cards[item.saveId or item.id]
          if card then
            local shapedCard = card --[[@as { frame: table<string, number>, body: table<string, number>, overflow: table<string, number>|nil }]]
            local bodyFocused = focus.region == "saves"
              and focus.saveId == (item.saveId or item.id)
              and focus.lane == "body"
            local overflowFocused = focus.region == "saves"
              and focus.saveId == (item.saveId or item.id)
              and focus.lane == "overflow"
            -- Body focus selects the outer card through the shared rounded rim;
            -- overflow focus leaves the parent neutral for its own inset chrome.
            drawSkinCard(shapedCard.frame, "normal", bodyFocused)
            local headingY = shapedCard.frame.y + CARD_INSET
            drawSkinText("normal", displayUpper("CONTINUE"), shapedCard.frame.x + CARD_INSET, headingY)
            if item.canContinue then
              -- Stored values keep their exact form; only headings and labels
              -- are uppercased presentation copy. The badge count is the
              -- durable progression count from the saved-game view.
              assert(type(item.badgeCount) == "number", "the saved-game view supplies the badge count")
              drawProfileRows(
                graphics,
                text,
                skin,
                shapedCard.body,
                headingY + lineHeight,
                lineHeight,
                item.playerName or "Save unavailable",
                item.playTimeLabel or "0:00",
                item.badgeCount
              )
            else
              drawSkinText("error", displayUpper(cardTitle(item)), shapedCard.frame.x + CARD_INSET, headingY + 20)
            end
            if shapedCard.overflow then
              drawSkinCard(shapedCard.overflow, "overflow", overflowFocused)
              drawSkinText("normal", "...", shapedCard.overflow.x + 3, shapedCard.overflow.y + 4)
            end
          end
        end
      end)

      self:_drawScrollIndicators(layout)

      local globalFocus = view.focus.region == "global"
      local global = assert(shaped.global)
      local shapedGlobal = global --[[@as { actions: table<string, table<string, number>> }]]
      local newGame = assert(shapedGlobal.actions["new-game"])
      drawSkinCard(newGame, "normal", globalFocus)
      drawSkinText("normal", displayUpper("NEW GAME"), newGame.x + CARD_INSET, newGame.y + 10)

      if view.popup then
        local popup = assert(layout.popup)
        local shapedPopup = popup --[[@as { box: table<string, number>, actions: { edit: table<string, number>|nil, delete: table<string, number>|nil } }]]
        graphics.setColor(0, 0, 0, 0.45)
        graphics.rectangle("fill", 0, 0, viewport.width, viewport.height)
        drawSkinCard(shapedPopup.box, "normal", false)
        if shapedPopup.actions.edit then
          local selected = view.popup.focusedAction == "edit"
          drawSkinCard(shapedPopup.actions.edit, "inset", selected)
          drawSkinText("normal", displayUpper("Edit"), shapedPopup.actions.edit.x + 4, shapedPopup.actions.edit.y + 4)
        end
        if shapedPopup.actions.delete then
          local selected = view.popup.focusedAction == "delete"
          drawSkinCard(shapedPopup.actions.delete, "inset", selected)
          drawSkinText(
            "normal",
            displayUpper("Delete"),
            shapedPopup.actions.delete.x + 4,
            shapedPopup.actions.delete.y + 4
          )
        end
      end
      if view.confirmation then
        local confirmation = assert(layout.confirmation)
        local shapedConfirm = confirmation --[[@as { box: table<string, number>, cancel: table<string, number>, delete: table<string, number> }]]
        graphics.setColor(0, 0, 0, 0.62)
        graphics.rectangle("fill", 0, 0, viewport.width, viewport.height)
        drawSkinCard(shapedConfirm.box, "normal", false)
        drawSkinText(
          "normal",
          displayUpper("Delete this save?"),
          shapedConfirm.box.x + CARD_INSET,
          shapedConfirm.box.y + CARD_INSET
        )
        local cancelFocus = view.confirmation.focusedAction == "cancel"
        local deleteFocus = view.confirmation.focusedAction == "delete"
        drawSkinCard(shapedConfirm.cancel, "inset", cancelFocus)
        drawSkinCard(shapedConfirm.delete, "inset", deleteFocus)
        drawSkinText("normal", displayUpper("Cancel"), shapedConfirm.cancel.x + 4, shapedConfirm.cancel.y + 4)
        drawSkinText("normal", displayUpper("Delete"), shapedConfirm.delete.x + 4, shapedConfirm.delete.y + 4)
      end
    end, debug.traceback)
    graphics.setColor(red, green, blue, alpha)
    graphics.setLineWidth(lineWidth)
    if not ok then
      error(err, 0)
    end
  end)
  graphics.setColor(red, green, blue, alpha)
  graphics.setLineWidth(lineWidth)
end

---@param layout table<string, unknown>
function MainMenuRenderer:_drawScrollIndicators(layout)
  local saves = assert(layout.saves)
  local marks = saves.scrollIndicators
  if marks and marks.up then
    self:_drawScrollMark(marks.up, true)
  end
  if marks and marks.down then
    self:_drawScrollMark(marks.down, false)
  end
end

---@param rect table<string, number>
---@param isUp boolean
function MainMenuRenderer:_drawScrollMark(rect, isUp)
  local graphics = self.graphics
  setColor(graphics, MARK)
  graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  setColor(graphics, MARK_EDGE)
  local middleX = rect.x + rect.width / 2
  if isUp then
    graphics.polygon(
      "fill",
      rect.x + 2,
      rect.y + rect.height - 2,
      middleX,
      rect.y + 2,
      rect.x + rect.width - 2,
      rect.y + rect.height - 2
    )
  else
    graphics.polygon(
      "fill",
      rect.x + 2,
      rect.y + 2,
      middleX,
      rect.y + rect.height - 2,
      rect.x + rect.width - 2,
      rect.y + 2
    )
  end
end

function MainMenuRenderer:dispose()
  if self.text and self.text.release then
    self.text:release()
  end
  self.text = nil
end

return MainMenuRenderer
