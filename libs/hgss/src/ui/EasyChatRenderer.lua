-- The native Easy Chat 2D composition: draws the committed static layers
-- and dynamic text over borrowed prepared collaborators. The renderer
-- owns its frame quads; it never allocates, prepares, or acquires during
-- draw, and never advances animation: all motion derives from the
-- fixed-tick view time. Missing text/window collaborators (stub leases)
-- draw their layers without glyphs; production bundles always carry the
-- borrowed owners. Pure drawing: no love acquisition, no input, no saves.

local LogicalSurface = require("libs.ui.src.LogicalSurface")

---@class EasyChatRenderer
---@field _manifest table<string, unknown> borrowed presentation manifest
---@field _images table<string, unknown> borrowed realized images by path
---@field _quads table<string, table<integer, unknown>> owned frame quads by sequence role and frame
---@field _text0 table<string, unknown>? borrowed Font0 renderer
---@field _text1 table<string, unknown>? borrowed Font1 renderer
---@field _text4 table<string, unknown>? borrowed Font4 renderer
---@field _window table<string, unknown>? borrowed window renderer
---@field _prompt table<string, unknown>? borrowed compact prompt renderer
local EasyChatRenderer = {}
EasyChatRenderer.__index = EasyChatRenderer

---@param fontDef table<string, unknown>
---@param slot integer zero-based palette slot
---@return table<string, number> rgb
local function slotBytes(fontDef, slot)
  local palette = assert(fontDef.palette, "text needs the field font palette")
  local entry = assert(palette[slot + 1], "field font palette has no slot " .. slot)
  local function byte(value)
    local number = assert(tonumber(value), "font palette slots carry RGB components")
    if number > 1 then
      number = number / 255
    end
    return number * 255
  end
  return { r = byte(entry.r or entry[1]), g = byte(entry.g or entry[2]), b = byte(entry.b or entry[3]) }
end

---@param fontDef table<string, unknown>
---@param foreground integer
---@param shadow integer
---@return table<string, table<string, number>> palette
local function rolePalette(fontDef, foreground, shadow)
  return {
    foreground = slotBytes(fontDef, foreground),
    shadow = slotBytes(fontDef, shadow),
    background = { r = 0, g = 0, b = 0, a = 0 },
  }
end

---@class EasyChatRenderer.Options
---@field manifest table<string, unknown> borrowed presentation manifest
---@field images table<string, unknown> borrowed realized images by path
---@field text0 table<string, unknown>? borrowed Font0 renderer
---@field text1 table<string, unknown>? borrowed Font1 renderer
---@field text4 table<string, unknown>? borrowed Font4 renderer
---@field window table<string, unknown>? borrowed window renderer
---@field prompt table<string, unknown>? borrowed compact prompt renderer

---@param opts EasyChatRenderer.Options
---@return EasyChatRenderer
function EasyChatRenderer.new(opts)
  assert(type(opts) == "table", "the editor renderer requires its options")
  assert(type(opts.manifest) == "table", "the editor renderer borrows its manifest")
  assert(type(opts.images) == "table", "the editor renderer borrows its images")
  local graphics = (love and love.graphics) or nil
  local textGraphics = opts.text0 ~= nil and opts.text0._graphics or nil
  if textGraphics ~= nil then
    graphics = textGraphics
  end
  assert(graphics and graphics.newQuad, "the editor renderer requires love.graphics")
  local quads = {}
  for _, sequence in ipairs(assert(opts.manifest.sequences, "the manifest carries its sequences")) do
    local frames = {}
    for index, frame in ipairs(sequence.frames or {}) do
      local image = opts.images[frame.image]
      if image ~= nil and type(image.getWidth) == "function" then
        local ok, quad =
          pcall(graphics.newQuad, 0, 0, image:getWidth(), image:getHeight(), image:getWidth(), image:getHeight())
        if ok then
          frames[index] = quad
        end
      end
    end
    quads[sequence.role] = frames
  end
  return setmetatable({
    _manifest = opts.manifest,
    _images = opts.images,
    _quads = quads,
    _text0 = opts.text0,
    _text1 = opts.text1,
    _text4 = opts.text4,
    _window = opts.window,
    _prompt = opts.prompt,
  }, EasyChatRenderer)
end

---@param self EasyChatRenderer
---@param role string
---@return table<string, unknown>? layer record
function EasyChatRenderer:_layer(role)
  for _, layer in ipairs(self._manifest.layers) do
    if layer.role == role then
      return layer
    end
  end
  return nil
end

---@param self EasyChatRenderer
---@param graphics love.graphics
---@param role string
function EasyChatRenderer:_drawLayer(graphics, role)
  local layer = self:_layer(role)
  if layer == nil then
    return
  end
  local image = self._images[layer.image]
  if image == nil then
    return
  end
  graphics.draw(image, 0, 0)
end

---@param self EasyChatRenderer
---@param role string
---@return table<string, unknown>? sequence record
function EasyChatRenderer:_sequence(role)
  for _, candidate in ipairs(self._manifest.sequences) do
    if candidate.role == role then
      return candidate
    end
  end
  return nil
end

---@param self EasyChatRenderer
---@param graphics love.graphics
---@param role string
---@param frameIndex integer
---@param x number
---@param y number
function EasyChatRenderer:_drawSequenceFrame(graphics, role, frameIndex, x, y)
  local sequence = self:_sequence(role)
  if sequence == nil then
    return
  end
  local frames = sequence.frames or {}
  local count = #frames
  if count == 0 then
    return
  end
  -- Source frame timing: frames advance by their decoded durations and
  -- loop over the total period, so fixed-tick time selects the same cell
  -- the retail animation shows.
  local total = 0
  for _, candidate in ipairs(frames) do
    total = total + (candidate.duration or 1)
  end
  if total <= 0 then
    return
  end
  local elapsed = frameIndex % total
  local slot = 1
  for index, candidate in ipairs(frames) do
    slot = index
    elapsed = elapsed - (candidate.duration or 1)
    if elapsed < 0 then
      break
    end
  end
  local frame = frames[slot]
  local image = self._images[frame.image]
  if image == nil then
    return
  end
  local quads = self._quads[role]
  local quad = quads ~= nil and quads[slot] or nil
  if quad ~= nil then
    graphics.draw(image, quad, x - (frame.originX or 0), y - (frame.originY or 0))
  else
    graphics.draw(image, x - (frame.originX or 0), y - (frame.originY or 0))
  end
end

---@param tokens table<integer, table<string, unknown>>
---@param fontDef table<string, unknown>
---@return number advance width
local function measureTokens(tokens, fontDef)
  local width = 0
  local glyphs = fontDef.glyphs or {}
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      local glyph = glyphs[token.code] or glyphs[0]
      width = width + (glyph and glyph.advance or 0) + (fontDef.letterSpacing or 0)
    end
  end
  return width
end

---@param text table<string, unknown>?
---@param tokens table<integer, table<string, unknown>>
---@param x number
---@param y number
---@param foreground integer
---@param shadow integer
local function drawTokens(text, tokens, x, y, foreground, shadow)
  if text == nil then
    return
  end
  text:drawLineWithPalette(tokens, x, y, rolePalette(text.fontDef, foreground, shadow))
end

---@param time integer fixed-tick view time
---@return boolean cursorVisible
local function blinkVisible(time)
  return (time % 32) < 16
end

---@param view table<string, unknown>
---@return table<string, unknown>? word payload behind the sentence
local function sentenceWords(view)
  if view.mode == 2 then
    return nil
  end
  return view.words
end

---@param assets table<string, unknown>? committed bundle carrying the per-open menu and interface text
---@return table<string, unknown>? per-open menu snapshot
local function bundleMenu(assets)
  if type(assets) == "table" and type(assets.menu) == "table" then
    return assets.menu
  end
  return nil
end

---@param assets table<string, unknown>? committed bundle carrying the per-open menu and interface text
---@return table<string, unknown>? borrowed interface text
local function bundleInterface(assets)
  if type(assets) == "table" and type(assets.interface) == "table" then
    return assets.interface
  end
  return nil
end

---@param self EasyChatRenderer
---@param _ love.graphics unused host graphics namespace
---@param view table<string, unknown>
---@param catalog table<string, unknown>
function EasyChatRenderer:_drawSentenceWords(_, view, catalog)
  local text = self._text1
  if text == nil then
    return
  end
  local mode = view.mode
  if mode == 0 then
    local words = sentenceWords(view)
    local wordId = words ~= nil and words[1] or 0xFFFF
    if wordId ~= nil and wordId ~= 0xFFFF then
      local tokens = catalog:wordTokens(wordId)
      local width = measureTokens(tokens, text.fontDef)
      drawTokens(text, tokens, 80 + (96 - width) / 2, 16, 5, 6)
    end
  elseif mode == 1 then
    local words = sentenceWords(view) or { 0xFFFF, 0xFFFF }
    local origins = { 24, 136 }
    for slot = 1, 2 do
      local wordId = words[slot]
      if wordId ~= nil and wordId ~= 0xFFFF then
        local tokens = catalog:wordTokens(wordId)
        local width = measureTokens(tokens, text.fontDef)
        drawTokens(text, tokens, origins[slot] + (96 - width) / 2, 16, 5, 6)
      end
    end
  elseif mode == 2 then
    local ref = view.template
    if type(ref) ~= "table" then
      return
    end
    local template = catalog:template(ref.bank, ref.number)
    if template == nil then
      return
    end
    local words = view.words or { 0xFFFF, 0xFFFF }
    -- The expanded fragment stream resolves loudly: admission guarantees
    -- known words and templates, so corruption fails instead of blanking.
    local expanded = catalog:expandMessage({ bank = ref.bank, number = ref.number, words = { words[1], words[2] } })
    if #expanded == 0 then
      return
    end
    -- Newline controls stack lines 16px apart; each line centers in the
    -- 216px strip. Reserved slots advance 100px in the source layout, so
    -- centered fragments keep their relative order across wrapped lines.
    local lines = { {} }
    for _, token in ipairs(expanded) do
      if token.kind == "line_break" then
        lines[#lines + 1] = {}
      else
        local line = lines[#lines]
        line[#line + 1] = token
      end
    end
    local baseY = 16 - (#lines - 1) * 8
    for index, line in ipairs(lines) do
      if #line > 0 then
        local width = measureTokens(line, text.fontDef)
        drawTokens(text, line, 24 + (216 - width) / 2, baseY + (index - 1) * 16, 5, 6)
      end
    end
  end
end

---@param self EasyChatRenderer
---@param graphics love.graphics
---@param view table<string, unknown>
---@param catalog table<string, unknown>
---@param assets table<string, unknown>? committed bundle carrying the per-open menu and interface text
---@param pane string information or controls
function EasyChatRenderer:_drawControls(graphics, view, catalog, assets, pane)
  if pane ~= "controls" then
    return
  end
  local time = view.time or 0
  local visible = blinkVisible(time)
  local level = view.level
  if level == "categories" or level == "abc" then
    self:_drawLayer(graphics, "categories")
    local menu = bundleMenu(assets)
    local interface = bundleInterface(assets)
    if interface ~= nil and interface.tabs ~= nil and self._text4 ~= nil then
      local tabFont = assert(self._text4, "editor tabs need their Font4 renderer")
      local tabs = interface.tabs
      for index = 1, 2 do
        local label = tabs[index]
        if label ~= nil then
          local width = measureTokens(label, tabFont.fontDef)
          local origin = index == 1 and 24 or 160
          drawTokens(tabFont, label, origin + (72 - width) / 2, 6, 14, 15)
        end
      end
    end
    if menu ~= nil and self._text0 ~= nil then
      local font = assert(self._text0, "editor categories need their Font0 renderer")
      if level == "categories" then
        for index, group in ipairs(menu.groups or {}) do
          local column = (index - 1) % 3
          local row = math.floor((index - 1) / 3)
          local empty = #(group.wordIds or {}) == 0
          local label = group.labelTokens or {}
          local width = measureTokens(label, font.fontDef)
          local color = empty and { 3, 4 } or { 1, 2 }
          drawTokens(font, label, 12 + column * 80 + (72 - width) / 2, 56 + row * 24, color[1], color[2])
        end
      else
        for index, initial in ipairs(menu.initials or {}) do
          local label = initial.labelTokens or {}
          local width = measureTokens(label, font.fontDef)
          drawTokens(font, label, 20 + ((index - 1) % 10) * 16 + (16 - width) / 2, 64, 1, 2)
        end
      end
    end
    if visible and view.browser ~= nil then
      local group = view.browser.group
      if type(group) == "number" and group ~= 0xFE then
        local column = group % 3
        local row = math.floor(group / 3)
        self:_drawSequenceFrame(graphics, "categoryCursorActive", math.floor(time / 1), 48 + column * 80, 64 + row * 24)
      end
    end
  elseif level == "list" then
    self:_drawLayer(graphics, "backdrop")
    local menu = bundleMenu(assets)
    local list = view.list or {}
    if menu ~= nil and self._text0 ~= nil then
      local font = self._text0
      local offered = {}
      if view.browser ~= nil then
        if view.browser.tab == "groups" then
          local group = (menu.groups or {})[(view.browser.group or 0) + 1]
          offered = (group and group.wordIds) or {}
        else
          local initial = (menu.initials or {})[(view.browser.group or 0) + 1]
          offered = (initial and initial.candidates) or {}
        end
      end
      local topRow = list.topRow or 0
      for row = 0, 4 do
        for col = 0, 1 do
          local index = topRow * 2 + row * 2 + col
          local wordId = offered[index + 1]
          if wordId ~= nil then
            local tokens = catalog:wordTokens(wordId)
            drawTokens(font, tokens, 32 + col * 112, 48 + row * 24, 3, 1)
          end
        end
      end
    end
    if visible and not list.quit then
      local row, col = list.row or 0, list.col or 0
      self:_drawSequenceFrame(graphics, "listWordCursorActive", math.floor(time / 1), 72 + col * 112, 56 + row * 24)
    end
  else
    self:_drawLayer(graphics, "compositionMain")
    self:_drawSentenceWords(graphics, view, catalog)
    local interface = bundleInterface(assets)
    if self._text4 ~= nil and interface ~= nil and interface.buttons ~= nil then
      local labels = interface.buttons
      if labels[1] ~= nil then
        drawTokens(self._text4, labels[1], 196, 116, 3, 1)
      end
      if labels[2] ~= nil then
        drawTokens(self._text4, labels[2], 196, 140, 3, 1)
      end
    end
    if visible then
      local focus = view.focus
      if focus == "confirm" then
        self:_drawSequenceFrame(graphics, "mainButtonCursorActive", math.floor(time / 1), 220, 120)
      elseif focus == "cancel" then
        self:_drawSequenceFrame(graphics, "mainButtonCursorActive", math.floor(time / 1), 220, 144)
      elseif view.mode == 2 then
        local ref = view.template
        local arity = 1
        if type(ref) == "table" then
          local template = catalog:template(ref.bank, ref.number)
          if template ~= nil then
            arity = template.wordCount
          end
        end
        if arity == 0 then
          self:_drawSequenceFrame(graphics, "sentenceCursorActive", math.floor(time / 1), 128, 24)
        else
          self:_drawSequenceFrame(graphics, "wordSlotCursorActive", math.floor(time / 1), 128, 24)
        end
      else
        self:_drawSequenceFrame(graphics, "wordSlotCursorActive", math.floor(time / 1), 128, 24)
      end
    end
    if level == "prompt" then
      local kind = view.prompt ~= nil and view.prompt.kind or nil
      if kind == "incomplete" then
        self:_drawNoticeOverlay(graphics, assets)
      else
        self:_drawPromptOverlay(graphics, view, assets)
      end
    elseif level == "notice" then
      self:_drawNoticeOverlay(graphics, assets)
    end
  end
end

---@param self EasyChatRenderer
---@param graphics love.graphics
---@param view table<string, unknown>
---@param assets table<string, unknown>? committed bundle carrying the per-open menu and interface text
function EasyChatRenderer:_drawPromptOverlay(graphics, view, assets)
  local text = self._text1
  if text == nil then
    return
  end
  local interface = bundleInterface(assets)
  local prompts = interface ~= nil and interface.prompts or nil
  if type(prompts) ~= "table" then
    return
  end
  local kind = view.prompt ~= nil and view.prompt.kind or "answer"
  local promptTokens = prompts[kind] or prompts.answer
  if promptTokens == nil then
    return
  end
  drawTokens(text, promptTokens, 24, 172, 1, 2)
  local selected = view.prompt ~= nil and view.prompt.selected or "yes"
  local selectedY = selected == "yes" and 96 or 128
  if self._prompt ~= nil and self._prompt.draw then
    self._prompt:draw(graphics, selected)
  else
    graphics.setColor(1, 1, 1, 1)
    graphics.rectangle("line", 200, selectedY, 48, 32)
  end
end

---@param self EasyChatRenderer
---@param _ love.graphics unused host graphics namespace
---@param assets table<string, unknown>? committed bundle carrying the per-open menu and interface text
function EasyChatRenderer:_drawNoticeOverlay(_, assets)
  local text = self._text1
  if text == nil then
    return
  end
  local interface = bundleInterface(assets)
  local prompts = interface ~= nil and interface.prompts or nil
  if type(prompts) ~= "table" or prompts.incomplete == nil then
    return
  end
  drawTokens(text, prompts.incomplete, 24, 172, 1, 2)
end

-- Draws one committed editor status across the plan's native panes. The
-- information pane carries the sentence strip; the controls pane carries
-- the composition, browser, or list surface. Brightness covers both panes
-- after content, matching the source fade order.
---@param graphics love.graphics host graphics namespace
---@param status table<string, unknown> committed screen status
---@param plan table<string, unknown> published application plan
function EasyChatRenderer:drawPair(graphics, status, plan)
  local view = assert(status.view, "editor drawing requires its view")
  local catalog = status.catalog
  local panes = assert(plan.panes, "editor drawing requires its panes")
  local information, controls = nil, nil
  for _, pane in ipairs(panes) do
    if pane.id == "information" then
      information = pane
    elseif pane.id == "controls" then
      controls = pane
    end
  end
  if information ~= nil then
    LogicalSurface.draw(graphics, information.placement, function()
      self:_drawLayer(graphics, "compositionSub")
      if catalog ~= nil then
        self:_drawSentenceWords(graphics, view, catalog)
      end
    end)
  end
  if controls ~= nil then
    LogicalSurface.draw(graphics, controls.placement, function()
      if catalog ~= nil then
        self:_drawControls(graphics, view, catalog, status.assets, "controls")
      else
        self:_drawLayer(graphics, "compositionMain")
      end
    end)
  end
  local brightness = status.brightness
  if type(brightness) == "number" and brightness > 0 then
    for _, pane in ipairs(panes) do
      local placement = pane.placement
      if placement ~= nil and placement.frame ~= nil then
        LogicalSurface.draw(graphics, placement, function()
          graphics.setColor(0, 0, 0, math.min(1, brightness / 16))
          graphics.rectangle("fill", 0, 0, 256, 192)
          graphics.setColor(1, 1, 1, 1)
        end)
      end
    end
  end
end

-- Idempotent release of the owned frame quads; borrowed images, fonts,
-- window, and prompt owners stay alive.
function EasyChatRenderer:release()
  self._quads = {}
end

function EasyChatRenderer:dispose()
  self:release()
end

return EasyChatRenderer
