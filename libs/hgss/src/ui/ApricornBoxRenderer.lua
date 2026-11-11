-- Draws source-derived Apricorn Box panes and seven animated stock rows.

local ImageSampling = require("libs.nds.src.love.ImageSampling")
local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")
local YesNoPromptRenderer = require("libs.hgss.src.ui.YesNoPromptRenderer")

---@class ApricornBoxRenderer
---@field _graphics love.graphics
---@field _cacheFs CacheFs
---@field _text table<string, unknown>
---@field _manifest table<string, unknown>
---@field _leases table<string, unknown> installed shared-image borrows by path; draws resolve through the lease sampler surface, never a bare image table
---@field _pool table<string, unknown> the borrowed shared image owner behind every visual
---@field _promptRenderer YesNoPromptRenderer
---@field _released boolean
local ApricornBoxRenderer = {}
ApricornBoxRenderer.__index = ApricornBoxRenderer

-- Box visuals sample point-filtered, matching the private construction
-- below, so pooled leases draw identically.
local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

-- Borrows one generated visual through the shared owner, waiting out its
-- classification without blocking the field longer than the bounded stall
-- budget. Failures name their path instead of drawing a blank visual.
---@param pool table<string, unknown>
---@param path string
---@return table<string, unknown> lease resolving the immutable visual
local function acquirePinned(pool, path)
  local token = pool:request(path, POOLED_SAMPLER, "demand")
  local stalled = 0
  while true do
    local status, failure = pool:poll(token)
    if status == "ready" then
      return pool:acquire(token)
    end
    if status == "failed" then
      error("generated Apricorn Box image missing at " .. path .. ": " .. tostring(failure), 0)
    end
    assert(status == "pending", "apricorn box preparation reports pending or ready")
    stalled = stalled + 1
    if stalled > 10000 then
      error("generated Apricorn Box image stalled at " .. path, 0)
    end
    local timer = love and love.timer
    if timer ~= nil and timer.sleep ~= nil then
      timer.sleep(0.001)
    end
  end
end

local function setWhite(graphics)
  graphics.setColor(1, 1, 1, 1)
end

local TEXT_LINE_HEIGHT = 16

-- Retail chrome ink follows the decomp color arguments: the title uses
-- MAKE_TEXT_COLOR(15,2,0) and the quantity buttons (15,3,0)/(15,5,0) from
-- sApricornBoxConfirmButtonColors, all indexing the runtime field font
-- palette, while CLOSE MAKE_TEXT_COLOR(1,2,0) indexes BG window palette 9
-- (compiled into the manifest as closeInk). Headless fakes without a font
-- palette fall back to these audited retail values. Entries stay in byte
-- range: the palette shader normalizes by 255.
local FALLBACK_INKS = {
  title = { foreground = { r = 255, g = 255, b = 255 }, shadow = { r = 173, g = 189, b = 189 } },
  ok = { foreground = { r = 255, g = 255, b = 255 }, shadow = { r = 239, g = 33, b = 16 } },
  cancel = { foreground = { r = 255, g = 255, b = 255 }, shadow = { r = 41, g = 214, b = 25 } },
}

-- One font palette slot as byte-valued RGB, or nil when the borrowed text
-- object carries no font palette (headless fakes fall back instead).
---@param slot integer 0-based palette slot
---@return { r: number, g: number, b: number }?
function ApricornBoxRenderer:_fontSlot(slot)
  local fontDef = self._text.fontDef
  local palette = fontDef and fontDef.palette
  local color = palette and palette[slot + 1]
  if color == nil then
    return nil
  end
  local r = assert(tonumber(color.r or color[1]))
  local g = assert(tonumber(color.g or color[2]))
  local b = assert(tonumber(color.b or color[3]))
  if r <= 1 and g <= 1 and b <= 1 then
    r, g, b = r * 255, g * 255, b * 255
  end
  return { r = r, g = g, b = b }
end

---@param foregroundSlot integer
---@param shadowSlot integer
---@param fallback { foreground: { r: number, g: number, b: number }, shadow: { r: number, g: number, b: number } }
function ApricornBoxRenderer:_fontInk(foregroundSlot, shadowSlot, fallback)
  return {
    foreground = self:_fontSlot(foregroundSlot) or fallback.foreground,
    shadow = self:_fontSlot(shadowSlot) or fallback.shadow,
    background = { r = 0, g = 0, b = 0, a = 0 },
  }
end

function ApricornBoxRenderer:_closeInk()
  local ink = assert(self._manifest.closeInk, "the Box manifest carries its source close ink")
  return {
    foreground = assert(ink.foreground, "the close ink carries its foreground"),
    shadow = assert(ink.shadow, "the close ink carries its shadow"),
    background = { r = 0, g = 0, b = 0, a = 0 },
  }
end

local function imageFor(self, path)
  local lease = self._leases[path]
  if lease == nil then
    -- Box state visuals borrow the shared owner as installed leases held
    -- for presentation and relinquished together on exit or change.
    -- Draws resolve the lease itself; no bare image is retained.
    lease = acquirePinned(assert(self._pool, "Apricorn Box renderer borrows its shared image owner"), path)
    assert(lease.image, "shared leases carry their resolved image")
    self._leases[path] = lease
  end
  return lease
end

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, text: table<string, unknown>, uiManifest: table<string, unknown>, graphics?: love.graphics, imagePool: table<string, unknown> }
---@return ApricornBoxRenderer
function ApricornBoxRenderer.new(opts)
  assert(type(opts) == "table", "Apricorn Box renderer options are records")
  local cacheFs = assert(opts.cacheFs, "Apricorn Box rendering needs the generated cache")
  local manifest = assert(opts.manifest, "Apricorn Box rendering needs a validated manifest")
  local graphics = opts.graphics or (love and love.graphics)
  assert(type(graphics) == "table" and type(graphics.draw) == "function", "Apricorn Box rendering needs love.graphics")
  local text = assert(opts.text, "Apricorn Box rendering borrows the generated field font")
  assert(type(text.drawText) == "function", "Apricorn Box rendering borrows text drawing")
  assert(
    type(text.drawTextWithPalette) == "function",
    "Apricorn Box rendering borrows paletted text drawing for its chrome row"
  )
  local uiManifest = assert(opts.uiManifest, "Apricorn Box rendering borrows generated prompt art")
  local pool = assert(opts.imagePool, "Apricorn Box renderer borrows its shared image owner")
  assert(
    type(pool.request) == "function"
      and type(pool.poll) == "function"
      and type(pool.acquire) == "function"
      and type(pool.release) == "function",
    "Apricorn Box renderer drives request, poll, acquire, and release"
  )
  local self = setmetatable({
    _graphics = graphics,
    _cacheFs = cacheFs,
    _leases = {},
    _pool = pool,
    _manifest = manifest,
    _text = text,
    _released = false,
  }, ApricornBoxRenderer)
  local ok, err = pcall(function()
    for _, path in ipairs(ApricornBoxAssetCache.referencedPaths(manifest)) do
      imageFor(self, path)
    end
    self._promptRenderer = YesNoPromptRenderer.new({ cacheFs = cacheFs, manifest = uiManifest, graphics = graphics })
  end)
  if not ok then
    self:release()
    error(err, 0)
  end
  return self
end

-- Draws source message lines at a tile window origin, one text row per line.
---@param value string
---@param window { x: integer, y: integer }
function ApricornBoxRenderer:_drawMultiline(value, window)
  if value == "" then
    return
  end
  assert(type(value) == "string", "Box windows print source message text")
  local y = window.y * 8
  for line in (value .. "\n"):gmatch("(.-)\n") do
    setWhite(self._graphics)
    self._text:drawText(line, window.x * 8, y)
    y = y + TEXT_LINE_HEIGHT
  end
end

-- The lower header carries the mode instruction: Kurt phases reuse the flow
-- wording while browse prints its own collected header.
---@param view table<string, unknown>
function ApricornBoxRenderer:_drawHeader(view)
  local header = view.flowMessage or view.headerText
  assert(type(header) == "string", "the lower pane carries the mode header")
  ---@cast header string
  local window = assert(self._manifest.headerWindow, "the Box manifest carries its source header window")
  self:_drawMultiline(header, window)
end

-- The lower chrome row centers the source title and close labels in their
-- windows over the background bar and button.
---@param view table<string, unknown>
function ApricornBoxRenderer:_drawChrome(view)
  local title = assert(view.titleText, "the lower pane carries the source title")
  local close = assert(view.closeText, "the lower pane carries the source close label")
  local titleWindow = assert(self._manifest.titleWindow, "the Box manifest carries its source title window")
  local closeWindow = assert(self._manifest.closeWindow, "the Box manifest carries its source close window")
  self:_drawCloseButton(view)
  local titleX = titleWindow.x * 8 + math.floor((titleWindow.width * 8 - self._text:textWidth(title)) / 2)
  local closeX = closeWindow.x * 8 + math.floor((closeWindow.width * 8 - self._text:textWidth(close)) / 2)
  setWhite(self._graphics)
  self._text:drawTextWithPalette(title, titleX, titleWindow.y * 8, self:_fontInk(15, 2, FALLBACK_INKS.title))
  setWhite(self._graphics)
  self._text:drawTextWithPalette(close, closeX, closeWindow.y * 8, self:_closeInk())
end

-- The retail close button is an always-drawn sprite behind its label at the
-- source template anchor. It rests on sequence 0 and dims to sequence 2
-- while the apricorns hold focus; sequence 1 is the brief close press.
---@param view table<string, unknown>
function ApricornBoxRenderer:_drawCloseButton(view)
  local anchor = assert(self._manifest.closeButton, "the Box manifest carries its source close anchor")
  local cursor = assert(self._manifest.selectionCursor, "the Box manifest carries its source cursor art")
  local phase = view.phase
  local sequenceId = (phase == "browse" or phase == "rows") and 0 or 2
  local state = assert(cursor.states[sequenceId], "the source close sequence is compiled")
  local tick = assert(view.animationTick, "Box presentation carries its fixed animation tick")
  local elapsed = tick % state.totalTicks
  local frame = state.frames[#state.frames]
  for _, candidate in ipairs(state.frames) do
    if elapsed < candidate.durationTicks then
      frame = candidate
      break
    end
    elapsed = elapsed - candidate.durationTicks
  end
  local lease = imageFor(self, frame.image)
  setWhite(self._graphics)
  ImageSampling.draw(self._graphics, lease, nil, anchor.x + frame.offsetX, anchor.y + frame.offsetY)
end

---@param row table<string, unknown> compiled row icon geometry
---@param tick integer fixed animation tick
---@param dimmed boolean? translucent pass behind overlay chrome
function ApricornBoxRenderer:_drawRowSprite(row, tick, dimmed)
  local icon = assert(row.icon, "Box rows carry source icon geometry")
  local elapsed = tick % icon.totalTicks
  local frame = icon.frames[#icon.frames]
  for _, candidate in ipairs(icon.frames) do
    if elapsed < candidate.durationTicks then
      frame = candidate
      break
    end
    elapsed = elapsed - candidate.durationTicks
  end
  local sprite = imageFor(self, frame.image)
  if dimmed then
    self._graphics.setColor(1, 1, 1, 0.5)
  else
    setWhite(self._graphics)
  end
  -- Slot centers carry the sprite anchor while compiled frame offsets
  -- already encode centering, so the draw lands at anchor plus offset.
  ImageSampling.draw(self._graphics, sprite, nil, icon.x + frame.offsetX, icon.y + frame.offsetY)
end

-- One quantity chrome sprite at its source anchor: its resting frame without
-- playback, or the frame an elapsed bounce or press has reached. Forward
-- playback holds its last frame once the elapsed ticks run past the total.
---@param sequenceId integer compiled cursor-resource sequence
---@param x integer source anchor x
---@param y integer source anchor y
---@param elapsed integer? playback ticks since the press or touch, absent for rest
function ApricornBoxRenderer:_drawChromeSprite(sequenceId, x, y, elapsed)
  local cursor = assert(self._manifest.selectionCursor, "the Box manifest carries its source cursor art")
  local state = assert(cursor.states[sequenceId], "quantity chrome sequence is compiled")
  local frame = state.frames[#state.frames]
  if elapsed == nil then
    frame = assert(state.frames[1], "quantity chrome shows its resting frame")
  else
    local remaining = elapsed
    for _, candidate in ipairs(state.frames) do
      if remaining < candidate.durationTicks then
        frame = candidate
        break
      end
      remaining = remaining - candidate.durationTicks
    end
  end
  local lease = imageFor(self, frame.image)
  setWhite(self._graphics)
  ImageSampling.draw(self._graphics, lease, nil, x + frame.offsetX, y + frame.offsetY)
end

-- The Kurt quantity overlay: the panel, the dimmed stock chrome showing
-- through it, and the name, digits, message, and button chrome above it.
---@param view table<string, unknown>
---@param rows table<string, unknown>[] stock snapshots
---@param tick integer fixed animation tick
function ApricornBoxRenderer:_drawQuantity(view, rows, tick)
  local graphics = self._graphics
  local layout = assert(self._manifest.quantityLayout, "the Box manifest carries its quantity layout")
  local panel = assert(self._manifest.quantityPanel, "the Box manifest carries its quantity panel")
  -- The overlay dims the stock chrome exactly like the retail focus mode.
  -- MAIN_1 carries the panel above the priority-2 stock sprites, so the
  -- dimmed rows and cursor draw first and the panel occludes them.
  for index, row in ipairs(self._manifest.rows) do
    local stock = assert(rows[index], "stock snapshots preserve the canonical row order")
    if stock.quantity ~= 0 then
      self:_drawRowSprite(row, tick, true)
    end
  end
  local selectedIndex = assert(view.selectedIndex, "Box presentation carries selected row")
  assert(rows[selectedIndex], "selected stock belongs to one canonical row")
  self:_drawCursor(view, assert(self._manifest.rows[selectedIndex], "selected row has source icon geometry"), tick)
  local panelLease = imageFor(self, panel.image)
  setWhite(graphics)
  ImageSampling.draw(graphics, panelLease, nil, 0, 0)
  setWhite(graphics)
  local name = assert(view.selectedName, "the quantity panel names its selected Apricorn")
  self._text:drawText(name, layout.name.x, layout.name.y)
  local quantity = assert(view.quantity, "the quantity panel carries its edited quantity")
  local maximum = assert(view.maximum, "the quantity panel carries its selected stock")
  assert(quantity >= 1 and quantity <= maximum, "the edited quantity stays inside its selected stock")
  setWhite(graphics)
  self._text:drawText(tostring(quantity % 10), layout.unitsDigit.x, layout.unitsDigit.y)
  if maximum >= 10 then
    setWhite(graphics)
    self._text:drawText(tostring(math.floor(quantity / 10)), layout.tensDigit.x, layout.tensDigit.y)
  end
  local panelMessage = assert(view.panelMessage, "the quantity panel carries its message line")
  if panelMessage ~= "" then
    setWhite(graphics)
    self._text:drawText(panelMessage, layout.extraMessage.x, layout.extraMessage.y)
  end
  local kurtMenu =
    assert(self._manifest.controls.actions.kurtSelect, "the quantity confirm labels use the Kurt action menu")
  local okLabel = assert(view.actionLabels[kurtMenu.messageIds[1]], "the panel labels its confirm button")
  local closeLabel = assert(view.actionLabels[kurtMenu.messageIds[2]], "the panel labels its cancel button")
  -- The button art sits behind its labels, matching the window above sprite order.
  local pressed = view.pressedAction
  local okSprite = layout.buttonOkSprite
  local closeSprite = layout.buttonCloseSprite
  self:_drawChromeSprite(
    pressed == 1 and okSprite.pressedSequence or okSprite.sequence,
    okSprite.x,
    okSprite.y,
    pressed == 1 and view.pressedElapsed or nil
  )
  self:_drawChromeSprite(
    pressed == 2 and closeSprite.pressedSequence or closeSprite.sequence,
    closeSprite.x,
    closeSprite.y,
    pressed == 2 and view.pressedElapsed or nil
  )
  local okX = layout.confirmOk.x + math.floor((layout.confirmOk.width - self._text:textWidth(okLabel)) / 2)
  local closeX = layout.confirmClose.x + math.floor((layout.confirmClose.width - self._text:textWidth(closeLabel)) / 2)
  setWhite(graphics)
  self._text:drawTextWithPalette(okLabel, okX, layout.confirmOk.y, self:_fontInk(15, 3, FALLBACK_INKS.ok))
  setWhite(graphics)
  self._text:drawTextWithPalette(closeLabel, closeX, layout.confirmClose.y, self:_fontInk(15, 5, FALLBACK_INKS.cancel))
  local flashes = assert(view.arrowFlashes, "the quantity panel carries its arrow bounce state")
  for slot, arrow in ipairs(assert(layout.arrows, "the quantity panel carries its arrow anchors")) do
    self:_drawChromeSprite(arrow.sequence, arrow.x, arrow.y, flashes[slot])
  end
end

---@param view table<string, unknown>
---@param selectedRow table<string, unknown> compiled selected row geometry
---@param tick integer fixed animation tick
function ApricornBoxRenderer:_drawCursor(view, selectedRow, tick)
  local cursor = assert(self._manifest.selectionCursor, "the Box manifest carries its source cursor art")
  local cursorState = assert(cursor.states[view.cursorSequenceId], "source cursor sequence is compiled")
  local cursorElapsed = tick % cursorState.totalTicks
  local cursorFrame = cursorState.frames[#cursorState.frames]
  for _, candidate in ipairs(cursorState.frames) do
    if cursorElapsed < candidate.durationTicks then
      cursorFrame = candidate
      break
    end
    cursorElapsed = cursorElapsed - candidate.durationTicks
  end
  local cursorLease = imageFor(self, cursorFrame.image)
  setWhite(self._graphics)
  -- The retail cursor hovers up and left of the slot center; the fixed hover
  -- offset comes from ApricornBoxScreen_UpdateCursor while the tick offset
  -- replays the hand lift.
  ImageSampling.draw(
    self._graphics,
    cursorLease,
    nil,
    selectedRow.icon.x + 4 + cursorFrame.offsetX,
    selectedRow.icon.y - 16 + cursorFrame.offsetY + view.cursorOffsetY
  )
end

---@param view table<string, unknown>
---@param pane { id: string, placement: table<string, unknown> }
function ApricornBoxRenderer:drawPane(view, pane)
  if self._released then
    return
  end
  assert(pane.id == "upper" or pane.id == "lower", "Apricorn Box pane identity is source-defined")
  local manifest = self._manifest
  local paneLease = imageFor(self, manifest[pane.id].image)
  local graphics = self._graphics
  setWhite(graphics)
  ImageSampling.draw(graphics, paneLease, nil, 0, 0)
  -- Retail splits the chrome across the two displays: the upper screen ends
  -- with the selected description while the lower touchscreen carries the
  -- header, the stock rows, and the title/close chrome.
  if pane.id ~= "lower" then
    self:_drawMultiline(
      assert(view.descriptionText, "the upper pane carries the selected description"),
      self._manifest.selectedDetail.window
    )
    return
  end
  self:_drawHeader(view)
  self:_drawChrome(view)
  local rows = assert(view.rows, "Box presentation carries the seven stock rows")
  local tick = assert(view.animationTick, "Box presentation carries its fixed animation tick")
  for index, row in ipairs(manifest.rows) do
    local stock = assert(rows[index], "stock snapshots preserve the canonical row order")
    if stock.quantity ~= 0 then
      self:_drawRowSprite(row, tick)
      local count = tostring(stock.quantity)
      local countWidth = self._text:textWidth(count)
      local countX = row.quantity.window.x * 8 + (row.quantity.textWidth - countWidth) / 2
      setWhite(graphics)
      self._text:drawText(count, countX, row.quantity.window.y * 8)
    end
  end
  local selectedIndex = assert(view.selectedIndex, "Box presentation carries selected row")
  assert(rows[selectedIndex], "selected stock belongs to one canonical row")
  local selectedRow = assert(manifest.rows[selectedIndex], "selected row has source icon geometry")
  self:_drawCursor(view, selectedRow, tick)
  if view.phase == "quantity" then
    self:_drawQuantity(view, rows, tick)
  end
  if view.phase == "confirm" then
    self._promptRenderer:draw(assert(view.confirmationPrompt, "confirmation renders its active prompt status"))
  end
  if view.phase == "actions" then
    local modeName = view.mode == "browse" and "browse" or "kurtSelect"
    local menu = assert(self._manifest.controls.actions[modeName])
    local x = menu.x * 8
    local y = menu.y * 8
    local atlas = imageFor(self, self._manifest.actionMenu.image)
    local atlasWidth = assert(atlas.width, "shared leases carry their menu atlas width")
    local atlasHeight = assert(atlas.height, "shared leases carry their menu atlas height")
    local function drawTile(tileIndex, tileX, tileY)
      local quad = graphics.newQuad(tileIndex * 8, 0, 8, 8, atlasWidth, atlasHeight)
      setWhite(graphics)
      ImageSampling.draw(graphics, atlas, quad, tileX, tileY)
    end
    local function drawRowTiles(tileIndex, tileY)
      drawTile(tileIndex, x, tileY)
      for column = 1, menu.width do
        drawTile(tileIndex + 1, x + column * 8, tileY)
      end
      drawTile(tileIndex + 2, x + (menu.width + 1) * 8, tileY)
    end
    local selectedAction = assert(view.selectedAction, "the active Box action list carries its selection")
    drawRowTiles(selectedAction == 1 and 12 or 0, y)
    for index = 1, menu.windowCount do
      local rowY = y + 8 + (index - 1) * 24
      local side = 3 + (selectedAction == index and 12 or 0)
      drawTile(side, x, rowY)
      drawTile(side + 2, x + (menu.width + 1) * 8, rowY)
      drawTile(side, x, rowY + 8)
      drawTile(side + 2, x + (menu.width + 1) * 8, rowY + 8)
      local actionLabel = assert(view.actionLabels[menu.messageIds[index]], "source action message resolves")
      if view.actionsEnabled[index] then
        self._text:drawText(actionLabel, x + 8 + 2, rowY)
      else
        graphics.setColor(0.45, 0.45, 0.45, 1)
        self._text:drawText(actionLabel, x + 8 + 2, rowY)
        setWhite(graphics)
      end
    end
    for index = 1, menu.windowCount - 1 do
      local separatorIndex = 6
      if (selectedAction == 1 and index == 1) or selectedAction == index then
        separatorIndex = separatorIndex + 12
      elseif (selectedAction == menu.windowCount and index == menu.windowCount - 1) or selectedAction == index + 1 then
        separatorIndex = separatorIndex + 18
      end
      drawRowTiles(separatorIndex, y + index * 24)
    end
    local bottom = selectedAction == menu.windowCount and 21 or 9
    drawRowTiles(bottom, y + menu.windowCount * 24)
    -- The rounded tile art and selected variants come from NARC165. The menu
    -- text sits in the source list windows, one line inset from each border.
  end
end

function ApricornBoxRenderer:release()
  if self._released then
    return
  end
  self._released = true
  if self._promptRenderer ~= nil then
    self._promptRenderer:release()
    self._promptRenderer = nil
  end
  local pool = assert(self._pool, "Apricorn Box renderer borrows its shared image owner")
  self._pool = nil
  for _, lease in pairs(self._leases) do
    pool:release(lease)
  end
  self._leases = {}
end

return ApricornBoxRenderer
