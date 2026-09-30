-- Composes the source-backed Party content and detail panes from one
-- immutable controller snapshot. Draw never advances animation clocks.

local PartyScreenTheme = require("libs.hgss.src.ui.PartyScreenTheme")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local YesNoPromptRenderer = require("libs.hgss.src.ui.YesNoPromptRenderer")

---@class PartyScreenRenderer
---@field _graphics love.graphics
---@field _text table<string, unknown> the borrowed generated-font collaborator
---@field _images table<string, love.Image> owned realized images, released exactly once
---@field _manifest table<string, unknown> the validated party presentation manifest
---@field _prompt YesNoPromptRenderer the owned source prompt renderer
---@field _window table<string, unknown>? the borrowed shared window decoration
---@field _frameIndex integer? the borrowed application frame choice for shared decoration
local PartyScreenRenderer = {}
PartyScreenRenderer.__index = PartyScreenRenderer

-- Selected-icon base shift and healthy bob amplitude in pixels.
local SELECT_SHIFT = 2
local BOB_UP = -3
local BOB_DOWN = 1

---@param graphics love.graphics
---@param path string
---@param data string
---@param images table<string, love.Image>
---@param key string
---@return love.Image
local function loadImage(graphics, path, data, images, key)
  local image = graphics.newImage(love.filesystem.newFileData(data, path))
  images[key] = image
  image:setFilter("nearest", "nearest")
  return image
end

---@param graphics love.graphics
---@param cacheFs CacheFs
---@param path string
---@param images table<string, love.Image>
---@param key string
---@return love.Image
local function acquireImage(graphics, cacheFs, path, images, key)
  assert(type(path) == "string" and path ~= "", "party visuals carry image paths")
  if images[key] ~= nil then
    return assert(images[key], "party images resolve once")
  end
  local data = cacheFs:read(path)
  assert(data, "party image missing at " .. path)
  return loadImage(graphics, path, data, images, key)
end

---@param graphics love.graphics
---@param color number[]
local function setColor(graphics, color)
  graphics.setColor(color[1], color[2], color[3], color[4])
end

local WHITE = { 1, 1, 1, 1 }
local DIMMED = { 1, 1, 1, 0.45 }
local MENU_HIGHLIGHT = { 0.3, 0.3, 0.45, 1 }
local ZERO_OFFSET = { x = 0, y = 0 }

local STATUS_KEYS = { "paralysis", "freeze", "sleep", "poison", "burn", "faint" }

---@param manifest table<string, unknown>
---@param section string
---@return table<string, unknown>
local function manifestSection(manifest, section)
  local value = assert(manifest[section], "the party manifest carries " .. section)
  assert(type(value) == "table", "the party manifest carries " .. section)
  return value
end

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, uiManifest: table<string, unknown>?, text: table<string, unknown>, window: table<string, unknown>?, frameIndex: integer?, graphics?: love.graphics }
---@return PartyScreenRenderer
function PartyScreenRenderer.new(opts)
  assert(type(opts) == "table", "party renderer options must be a table")
  local cacheFs = assert(opts.cacheFs, "the party renderer requires the version-scoped cache")
  assert(type(cacheFs.read) == "function", "the party renderer requires cache reads")
  local manifest = assert(opts.manifest, "the party renderer requires the validated party manifest")
  assert(type(manifest) == "table", "the party renderer requires the validated party manifest")
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(
    graphics and graphics.rectangle and graphics.draw and graphics.setColor and graphics.newImage,
    "PartyScreenRenderer requires love.graphics"
  )
  local text = assert(opts.text, "the party renderer requires the generated font")
  assert(
    type(text.drawText) == "function" and type(text.textWidth) == "function",
    "the party renderer borrows generated text drawing and measurement"
  )
  local renderer = setmetatable({
    _graphics = graphics,
    _text = text,
    _images = {},
    _hpQuads = {},
    _manifest = manifest,
    _window = opts.window,
    _frameIndex = opts.frameIndex,
  }, PartyScreenRenderer)
  local ok, err = pcall(function()
    renderer:_acquire(cacheFs, manifest, opts.uiManifest)
  end)
  if not ok then
    renderer:release()
    error(err, 0)
  end
  return renderer
end

-- Acquires each realized Party asset once; prompt imagery remains owned by
-- the shared prompt renderer.
---@param cacheFs CacheFs
---@param manifest table<string, unknown>
---@param uiManifest table<string, unknown>?
function PartyScreenRenderer:_acquire(cacheFs, manifest, uiManifest)
  local graphics = self._graphics
  local images = self._images
  local panels = manifestSection(manifest, "panels")
  local seen = {}
  local function acquire(path)
    if seen[path] == nil then
      seen[path] = true
      acquireImage(graphics, cacheFs, path, images, "asset:" .. path)
    end
  end
  for slot0 = 0, 5 do
    local panel = assert(panels[slot0 + 1], "the party manifest carries panel " .. slot0)
    local chrome = assert(panel.chrome, "party panels carry chrome")
    for _, state in ipairs({ "normal", "selected", "fainted", "selectedFainted" }) do
      acquire(assert(chrome[state], "party panels carry " .. state .. " chrome").image)
    end
  end
  local visuals = manifestSection(manifest, "visuals")
  for _, name in ipairs({ "backdropMain", "backdropSub", "detailSub", "auxPanel" }) do
    acquire(assert(visuals[name], "the party manifest carries " .. name).image)
  end
  local function acquireSequence(name)
    local visual = assert(visuals[name], "the party manifest carries " .. name)
    local sequences = assert(visual.sequences, "party visual " .. name .. " carries sequences")
    assert(type(sequences) == "table" and #sequences >= 1, "party visual " .. name .. " carries sequences")
    for _, sequence in ipairs(sequences) do
      local frames = assert(sequence.frames, "party visual sequences carry frames")
      assert(type(frames) == "table" and #frames >= 1, "party visual sequences carry frames")
      for _, frame in ipairs(frames) do
        acquire(assert(frame.image, "party frames carry image paths"))
      end
    end
  end
  acquireSequence("balls")
  acquireSequence("held")
  acquireSequence("cursor")
  acquireSequence("buttons")
  local status = assert(visuals.status, "the party manifest carries status visuals")
  for _, key in ipairs(STATUS_KEYS) do
    local visual = assert(status[key], "party status visuals carry " .. key)
    acquire(assert(visual.image, "party status visuals carry image paths"))
  end
  local hpBars = assert(visuals.hpBars, "the party manifest carries HP bars")
  for _, zone in ipairs({ "green", "yellow", "red" }) do
    acquire(assert(hpBars[zone], "party HP bars carry " .. zone).image)
  end
  local glyphs = manifestSection(manifest, "numberGlyphs")
  local digits = assert(glyphs.digits, "the party manifest carries digit glyphs")
  assert(type(digits) == "table" and #digits == 10, "the party manifest carries ten digit glyphs")
  for digit = 0, 9 do
    local glyph = assert(digits[digit + 1], "the party manifest carries digit " .. digit)
    acquireImage(graphics, cacheFs, assert(glyph.image, "digit glyphs carry image paths"), images, "digit:" .. digit)
  end
  local level = assert(glyphs.level, "the party manifest carries the level prefix")
  acquireImage(graphics, cacheFs, assert(level.image, "level prefix carries its image path"), images, "level")
  local slash = assert(glyphs.slash, "the party manifest carries the HP slash")
  acquireImage(graphics, cacheFs, assert(slash.image, "the HP slash carries its image path"), images, "slash")
  if uiManifest ~= nil then
    self._prompt = YesNoPromptRenderer.new({ cacheFs = cacheFs, manifest = uiManifest, graphics = graphics })
  end
end

---@param path string
---@return love.Image
function PartyScreenRenderer:_image(path)
  return assert(self._images["asset:" .. path], "party image resolves once: " .. path)
end

---@param sequence table<string, unknown>
---@param tick integer
---@return table<string, unknown>
local function frameAt(sequence, tick)
  assert(type(tick) == "number" and tick % 1 == 0 and tick >= 0, "party animation tick is non-negative")
  local frames = assert(sequence.frames, "party sequences carry frames")
  local playback = assert(sequence.playback, "party sequences carry playback")
  if playback == "static" then
    return assert(frames[1], "static party sequences carry a frame")
  end
  local loopFrom = assert(sequence.loopFrom, "party sequences carry a loop frame")
  local start = 1
  if playback == "loop" then
    local prefixDuration = 0
    for index = 1, loopFrom - 1 do
      prefixDuration = prefixDuration + assert(frames[index].durationTicks, "party frames carry duration")
    end
    if tick < prefixDuration then
      local elapsed = tick
      for index = 1, loopFrom - 1 do
        local frame = frames[index]
        local duration = assert(frame.durationTicks, "party frames carry duration")
        if elapsed < duration then
          return frame
        end
        elapsed = elapsed - duration
      end
    end
    tick = (tick - prefixDuration)
      % (function()
        local duration = 0
        for index = loopFrom, #frames do
          duration = duration + assert(frames[index].durationTicks, "party frames carry duration")
        end
        return duration
      end)()
    start = loopFrom
  end
  local elapsed = tick
  for index = start, #frames do
    local frame = frames[index]
    local duration = assert(frame.durationTicks, "party frames carry duration")
    if elapsed < duration then
      return frame
    end
    elapsed = elapsed - duration
  end
  if playback == "once" then
    return frames[#frames]
  end
  error("party animation sequence has no frame at tick", 0)
end

---@param sequence table<string, unknown>
---@param tick integer
---@param anchor { x: number, y: number }
function PartyScreenRenderer:_drawSequence(sequence, tick, anchor)
  local frame = frameAt(sequence, tick)
  local offset = frame.offset or ZERO_OFFSET
  setColor(self._graphics, WHITE)
  self._graphics.draw(
    self:_image(assert(frame.image, "party frames carry image paths")),
    anchor.x + assert(offset.x, "party frame offset carries x"),
    anchor.y + assert(offset.y, "party frame offset carries y")
  )
end

-- Releases every owned image exactly once; draw-after-release is a no-op
-- through the cleared table.
function PartyScreenRenderer:release()
  local images = self._images
  self._images = {}
  for _, image in pairs(images) do
    if image ~= nil and image.release then
      image:release()
    end
  end
  local hpQuads = self._hpQuads
  self._hpQuads = {}
  for _, quad in pairs(hpQuads) do
    if quad ~= nil and quad.release then
      quad:release()
    end
  end
  if self._prompt ~= nil then
    self._prompt:release()
    self._prompt = nil
  end
end

---@param value string
---@param x number
---@param y number
---@param dimmed boolean
function PartyScreenRenderer:_drawSlotText(value, x, y, dimmed)
  local graphics = self._graphics
  if dimmed then
    setColor(graphics, { 0.55, 0.55, 0.6, 1 })
  else
    setColor(graphics, { 0.95, 0.95, 0.95, 1 })
  end
  local text = self._text
  text.drawText(text, value, x, y)
end

-- Draws one decimal value through the compiled digit glyphs, advancing
-- the shared glyph advance per digit. Returns the drawn width.
---@param value integer
---@param x number
---@param y number
---@return integer width
function PartyScreenRenderer:_drawDigits(value, x, y)
  local graphics = self._graphics
  local glyphs = assert(self._manifest.numberGlyphs, "the party manifest carries number glyphs")
  local digits = assert(glyphs.digits, "the party manifest carries digit glyphs")
  local advance = assert(glyphs.advance, "digit glyphs carry their advance")
  local text = tostring(value)
  setColor(graphics, WHITE)
  local width = 0
  for index = 1, #text do
    local digit = tonumber(text:sub(index, index))
    assert(digit ~= nil, "HP numerals render decimal digits")
    assert(digits[digit + 1], "the party manifest carries digit glyphs")
    local image = assert(self._images["digit:" .. digit], "digit images resolve once")
    graphics.draw(image, x + width, y)
    width = width + advance
  end
  return width
end

-- Draws current/max HP numerals with the compiled slash between them,
-- right-aligned inside the panel HP number rect.
---@param currentHp integer
---@param maxHp integer
---@param rect ScreenTopology.Rectangle
function PartyScreenRenderer:_drawHpNumerals(currentHp, maxHp, rect)
  local graphics = self._graphics
  local glyphs = assert(self._manifest.numberGlyphs, "the party manifest carries number glyphs")
  local advance = assert(glyphs.advance, "digit glyphs carry their advance")
  local slash = assert(glyphs.slash, "the party manifest carries the HP slash")
  local slashWidth = assert(slash.width, "the HP slash carries its width")
  local function digitsWidth(value)
    return #tostring(value) * advance
  end
  local total = digitsWidth(currentHp) + slashWidth + digitsWidth(maxHp)
  local x = rect.x + rect.width - total
  setColor(graphics, WHITE)
  x = x + self:_drawDigits(currentHp, x, rect.y)
  local slashImage = assert(self._images.slash, "slash images resolve once")
  graphics.draw(slashImage, x, rect.y)
  x = x + slashWidth
  self:_drawDigits(maxHp, x, rect.y)
end

-- Draws the level prefix image with digit glyphs beside it.
---@param level integer
---@param rect ScreenTopology.Rectangle
function PartyScreenRenderer:_drawLevel(level, rect)
  local graphics = self._graphics
  local glyphs = assert(self._manifest.numberGlyphs, "the party manifest carries number glyphs")
  local prefix = assert(glyphs.level, "the party manifest carries the level prefix")
  local prefixWidth = assert(prefix.width, "the level prefix carries its width")
  setColor(graphics, WHITE)
  graphics.draw(assert(self._images.level, "level images resolve once"), rect.x, rect.y)
  self:_drawDigits(level, rect.x + prefixWidth, rect.y)
end

---@param bar ScreenTopology.Rectangle
---@param currentHp integer
---@param maxHp integer
function PartyScreenRenderer:_drawHpBar(bar, currentHp, maxHp)
  if currentHp == 0 then
    return
  end
  local graphics = self._graphics
  local zone = PartyScreenTheme.hpZone(currentHp, maxHp)
  if zone == "full" then
    zone = "green"
  end
  assert(zone == "green" or zone == "yellow" or zone == "red", "living HP bars have a source color")
  local fill = PartyScreenTheme.fillLength(currentHp, maxHp)
  local visual = assert(self._manifest.visuals.hpBars[zone], "party HP bars carry their source zone")
  local image = self:_image(assert(visual.image, "party HP bars carry image paths"))
  local quad = nil
  if fill < bar.width then
    local key = zone .. ":" .. fill
    quad = self._hpQuads[key]
    if quad == nil then
      quad = graphics.newQuad(0, 0, fill, visual.height, visual.width, visual.height)
      self._hpQuads[key] = quad
    end
  end
  setColor(graphics, WHITE)
  local x = bar.x
  local y = bar.y + math.floor((bar.height - visual.height) / 2)
  if quad == nil then
    graphics.draw(image, x, y)
  else
    graphics.draw(image, quad, x, y)
  end
end

---@param record table<string, unknown>
---@param panel table<string, unknown>
---@param dx number
---@param selected boolean
---@param phase integer
---@param icons table<string, unknown>
---@param disabled boolean
function PartyScreenRenderer:_drawIcon(record, panel, dx, selected, phase, icons, disabled)
  local graphics = self._graphics
  local iconKey = assert(record.iconKey, "occupied slots carry an icon key")
  local iconImage = icons:image(iconKey)
  local quad = icons:quadFor(iconKey)
  local dims = icons:dimensions(record.iconKey)
  assert(
    type(dims) == "table" and type(dims.width) == "number" and type(dims.height) == "number",
    "the icon provider reports image dimensions"
  )
  local anchor = assert(panel.iconAnchor, "party panels carry the icon anchor")
  local x = anchor.x + dx - dims.width / 2
  local y = anchor.y - dims.height / 2
  if selected then
    x = x + SELECT_SHIFT
    y = y + SELECT_SHIFT
    local status = assert(record.status, "occupied slots carry a status")
    if status == "ok" then
      if phase % 2 == 0 then
        y = y + BOB_UP
      else
        y = y + BOB_DOWN
      end
    end
  end
  if disabled then
    setColor(graphics, DIMMED)
  else
    setColor(graphics, WHITE)
  end
  graphics.draw(iconImage, quad, x, y)
end

---@param record table<string, unknown>
---@param panel table<string, unknown>
---@param dx number
---@param selected boolean
---@param tick integer
function PartyScreenRenderer:_drawIndicators(record, panel, dx, selected, tick)
  local visuals = assert(self._manifest.visuals, "the party manifest carries visuals")
  local ballSequence =
    assert(visuals.balls.sequences[selected and 2 or 1], "party balls carry normal and selected states")
  local ballAnchor = assert(panel.ballAnchor, "party panels carry the ball anchor")
  self:_drawSequence(ballSequence, tick, { x = ballAnchor.x + dx, y = ballAnchor.y })
  if record.heldItem ~= nil and record.heldItem ~= "NONE" then
    local sequenceIndex = record.heldMarkerKind == "item" and 1 or record.heldMarkerKind == "mail" and 2
    assert(sequenceIndex ~= nil, "held items carry a semantic marker kind")
    local heldSequence = assert(visuals.held.sequences[sequenceIndex], "party held visuals carry the marker")
    local heldAnchor = assert(panel.heldAnchor, "party panels carry the held-item anchor")
    self:_drawSequence(heldSequence, tick, { x = heldAnchor.x + dx, y = heldAnchor.y })
  end
  if record.capsule ~= nil then
    local capsuleSequence = assert(visuals.held.sequences[3], "party held visuals carry the capsule marker")
    local capsuleAnchor = assert(panel.capsuleAnchor, "party panels carry the capsule anchor")
    self:_drawSequence(capsuleSequence, tick, { x = capsuleAnchor.x + dx, y = capsuleAnchor.y })
  end
end

-- Shortens a card string to a measured width with an ellipsis.
---@param text table<string, unknown> the borrowed generated-font collaborator
---@param value string
---@param maxWidth number
---@return string
local function truncateToWidth(text, value, maxWidth)
  local measure = assert(text.textWidth, "truncation measures through the generated font")
  if measure(text, value) <= maxWidth then
    return value
  end
  local glyphs = {}
  for glyph in Utf8Glyphs.iter(value) do
    glyphs[#glyphs + 1] = glyph
  end
  for kept = #glyphs - 1, 0, -1 do
    local candidate = table.concat(glyphs, "", 1, kept) .. "…"
    if measure(text, candidate) <= maxWidth then
      return candidate
    end
  end
  return ""
end

---@param record table<string, unknown>
---@param panel table<string, unknown>
---@param dx number horizontal swap/slide offset applied to every panel coordinate
---@param selected boolean
---@param phase integer
---@param tick integer
---@param icons table<string, unknown>
---@param disabled boolean
function PartyScreenRenderer:_drawSlot(record, panel, dx, selected, phase, tick, icons, disabled)
  local graphics = self._graphics
  local origin = assert(panel.origin, "party panels carry origins")
  local chrome = assert(panel.chrome, "party panels carry chrome")
  local chromeKey = selected and (record.status == "faint" and "selectedFainted" or "selected")
    or (record.occupied and record.status == "faint" and "fainted" or "normal")
  local panelVisual = record.occupied and assert(chrome[chromeKey], "party panels carry state chrome")
    or assert(self._manifest.visuals.auxPanel, "party assets carry the empty-slot panel")
  local chromeImage = self:_image(assert(panelVisual.image, "party panel states carry image paths"))
  setColor(graphics, WHITE)
  graphics.draw(chromeImage, origin.x + dx, origin.y)
  if not record.occupied then
    return
  end
  self:_drawIcon(record, panel, dx, selected, phase, icons, disabled)
  self:_drawIndicators(record, panel, dx, selected, tick)
  local displayName = assert(record.displayName, "occupied slots carry a display name")
  assert(type(displayName) == "string", "the display name renders as text")
  local nameRect = assert(panel.text.name, "party panels carry the name subrect")
  self:_drawSlotText(truncateToWidth(self._text, displayName, nameRect.width), nameRect.x + dx, nameRect.y, disabled)
  local status = assert(record.status, "occupied slots carry a status")
  local levelRect = assert(panel.text.level, "party panels carry the level subrect")
  if status ~= "faint" and not record.isEgg then
    local shiftedLevel = {
      x = levelRect.x + dx,
      y = levelRect.y,
      width = levelRect.width,
      height = levelRect.height,
    }
    self:_drawLevel(assert(record.level, "occupied slots carry a level"), shiftedLevel)
  end
  if status ~= "ok" then
    local visual = assert(self._manifest.visuals.status[status], "party status carries its semantic visual")
    local statusRect = assert(panel.statusRect, "party panels carry the status rectangle")
    setColor(graphics, WHITE)
    graphics.draw(
      self:_image(assert(visual.image, "party status visuals carry image paths")),
      statusRect.x + dx,
      statusRect.y
    )
  end
  if not record.isEgg then
    local hpNumber = assert(panel.hp.number, "party panels carry the HP number subrect")
    self:_drawHpNumerals(
      assert(record.currentHp, "occupied slots carry current HP"),
      assert(record.maxHp, "occupied slots carry max HP"),
      { x = hpNumber.x + dx, y = hpNumber.y, width = hpNumber.width, height = hpNumber.height }
    )
    local hpBar = assert(panel.hp.bar, "party panels carry the HP bar subrect")
    self:_drawHpBar(
      { x = hpBar.x + dx, y = hpBar.y, width = hpBar.width, height = hpBar.height },
      assert(record.currentHp, "occupied slots carry current HP"),
      assert(record.maxHp, "occupied slots carry max HP")
    )
  end
end

-- Draws the context menu over its manifest window: shared decoration
-- with one text row per entry, the focused row highlighted.
---@param menu table<string, unknown>[]
---@param menuIndex integer
---@param window ScreenTopology.Rectangle
---@param layout table<string, unknown>
function PartyScreenRenderer:_drawMenu(menu, menuIndex, window, layout)
  local graphics = self._graphics
  self:_drawSharedWindow(window)
  local rows = assert(layout.menuRows, "the party layout carries menu rows")
  local rects = rows(#menu)
  assert(#rects == #menu, "menu rows index every entry")
  for index, entry in ipairs(menu) do
    local row = rects[index]
    if index == menuIndex then
      setColor(graphics, MENU_HIGHLIGHT)
      graphics.rectangle("fill", row.x, row.y, row.width, row.height)
    end
    self:_drawSlotText(assert(entry.label, "menu entries carry display labels"), row.x + 4, row.y, false)
  end
end

-- Draws one shared-decoration window: the player frame around a filled
-- content box, or the fill alone while its collaborators stay absent.
---@param box ScreenTopology.Rectangle
function PartyScreenRenderer:_drawSharedWindow(box)
  local graphics = self._graphics
  local window = self._window
  local frameIndex = self._frameIndex
  if window == nil or frameIndex == nil then
    setColor(graphics, { 0.12, 0.12, 0.18, 1 })
    graphics.rectangle("fill", box.x, box.y, box.width, box.height)
    return
  end
  window:drawWindow(box, frameIndex, { 0.12, 0.12, 0.18, 1 })
end

-- Draws the message window with its text through the borrowed font.
---@param message string
function PartyScreenRenderer:_drawMessage(message)
  local manifest = self._manifest
  local windows = assert(manifest.windows, "the party manifest carries windows")
  local box = assert(windows.message, "the party manifest carries the message window")
  self:_drawSharedWindow({ x = box.x, y = box.y, width = box.width, height = box.height })
  self:_drawSlotText(message, box.x + 4, box.y + 4, false)
end

function PartyScreenRenderer:_drawBrowseMessage()
  local box = assert(self._manifest.windows.message, "the party manifest carries its message window")
  local template = assert(self._manifest.text.templates.chooseMon, "the party manifest carries chooseMon")
  local segments = assert(template.segments, "chooseMon carries compiled segments")
  self:_drawSharedWindow({ x = box.x, y = box.y, width = box.width, height = box.height })
  local x, y = box.x + 4, box.y + 4
  if segments[1] ~= nil and segments[1].kind == "glyph" and self._text.drawLine ~= nil then
    self._text:drawLine(segments, x, y)
    return
  end
  for _, segment in ipairs(segments) do
    if segment.kind == "text" then
      local value = assert(segment.value, "text segments carry display text")
      self._text:drawText(value, x, y)
      x = x + self._text:textWidth(value)
    elseif segment.kind == "lineBreak" then
      x = box.x + 4
      y = y + 16
    end
  end
end

-- Draws the owned yes/no prompt through its controller status.
---@param promptStatus table<string, unknown>
function PartyScreenRenderer:_drawPrompt(promptStatus)
  local prompt = assert(self._prompt, "confirm prompts need the owned prompt renderer")
  prompt:draw(promptStatus)
end

-- Draws selected mon facts at the generated upper-detail rest geometry.
---@param facts table<string, unknown>
---@param originX number
---@param originY number
---@param slide number
---@param icons table<string, unknown>
function PartyScreenRenderer:_drawDetailFacts(facts, originX, originY, slide, icons)
  local graphics = self._graphics
  local iconKey = assert(facts.iconKey, "detail facts carry an icon key")
  local iconImage = icons:image(iconKey)
  local quad = icons:quadFor(iconKey)
  setColor(graphics, WHITE)
  local dims = icons:dimensions(iconKey)
  local detail = assert(self._manifest.detail, "the party manifest carries detail geometry")
  local iconAnchor = assert(detail.iconAnchor, "party detail carries the icon anchor")
  graphics.draw(
    iconImage,
    quad,
    originX + iconAnchor.x - dims.width / 2,
    originY + iconAnchor.y - slide - dims.height / 2
  )
  local status = assert(facts.status, "detail facts carry a status")
  if status ~= "ok" then
    local visual = assert(self._manifest.visuals.status[status], "detail status carries its semantic visual")
    local statusAnchor = assert(detail.statusAnchor, "party detail carries the status anchor")
    local width = assert(visual.width, "party status visuals carry widths")
    local height = assert(visual.height, "party status visuals carry heights")
    setColor(graphics, WHITE)
    graphics.draw(
      self:_image(assert(visual.image, "party status visuals carry image paths")),
      originX + statusAnchor.x - width / 2,
      originY + statusAnchor.y - slide - height / 2
    )
  end
  local displayName = assert(facts.displayName, "detail facts carry a display name")
  assert(type(displayName) == "string", "the detail name renders as text")
  local nicknameTextOrigin = assert(detail.nicknameTextOrigin, "party detail carries the nickname origin")
  self:_drawSlotText(displayName, originX + nicknameTextOrigin.x, originY + nicknameTextOrigin.y - slide, false)
  local heldName = assert(facts.heldItemName, "detail facts carry a held-item display name")
  local heldItemTextOrigin = assert(detail.heldItemTextOrigin, "party detail carries the held-item text origin")
  self:_drawSlotText(heldName, originX + heldItemTextOrigin.x, originY + heldItemTextOrigin.y - slide, false)
end

---@param presentation table<string, unknown>
---@param placement LayoutGeometry.Placement the resolved detail-pane placement
---@param icons table<string, unknown>
function PartyScreenRenderer:_drawDetailPane(presentation, placement, icons)
  local graphics = self._graphics
  local view = assert(presentation.view, "the presentation needs a view")
  assert(type(view.slots) == "table", "the presentation needs six slots")
  local slide = presentation.anim and presentation.anim.panelSlide or 0
  local facts
  if slide > 0 and type(presentation.menuSlot) == "number" then
    facts = assert(view.slots[presentation.menuSlot + 1], "context detail addresses a party slot")
  end
  -- The caller scopes drawing to the pane's logical surface, so the
  -- background and the source upper-screen anchors sit at the
  -- pane-local logical origin sized by the placement's logical
  -- dimensions, never at host frame coordinates.
  assert(placement.logicalWidth == 256, "detail panes use the canonical 256-pixel width")
  assert(placement.logicalHeight == 192, "detail panes use the canonical 192-pixel height")
  local visuals = assert(self._manifest.visuals, "the party manifest carries visuals")
  setColor(graphics, WHITE)
  graphics.draw(self:_image(assert(visuals.backdropSub.image, "the sub backdrop carries an image path")), 0, 0)
  graphics.draw(self:_image(assert(visuals.detailSub.image, "the detail layer carries an image path")), 0, -slide)
  if slide > 0 and type(facts) == "table" and facts.occupied then
    self:_drawDetailFacts(facts, 0, 0, slide, icons)
  end
end

-- Draws one scoped pane through the resolved layout: the interaction
-- content pane draws the full snapshot, every other pane draws the
-- selected mon's detail facts.
---@param presentation table<string, unknown>
---@param pane table<string, unknown>
---@param layout table<string, unknown>
---@param icons table<string, unknown>
function PartyScreenRenderer:drawPane(presentation, pane, layout, icons)
  assert(type(presentation) == "table", "the party renderer requires a presentation")
  assert(type(pane) == "table", "the party renderer requires its pane")
  assert(type(layout) == "table", "the party renderer requires a resolved layout")
  if not presentation.open then
    return
  end
  assert(
    type(presentation.view) == "table" and type(presentation.view.slots) == "table",
    "the presentation needs a view"
  )
  local graphics = self._graphics
  local red, green, blue, alpha = 1, 1, 1, 1
  if graphics.getColor then
    red, green, blue, alpha = graphics.getColor()
  end
  local ok, err = pcall(function()
    if pane.id == "content" then
      self:_drawContent(presentation, layout, assert(icons, "content needs the icon provider"))
    else
      local placement = assert(pane.placement, "detail panes carry placements")
      self:_drawDetailPane(presentation, placement, assert(icons, "detail needs the icon provider"))
    end
  end)
  if graphics.setColor then
    graphics.setColor(red, green, blue, alpha)
  end
  if not ok then
    error(err, 0)
  end
end

-- Draws one presentation snapshot through the resolved layout with quads
-- from the icon provider. A matched interface plan carries its canonical
-- content; a resolved layout draws directly. Multi-pane plans draw the
-- interaction content in the content pane and detail facts in every
-- additional pane. A closed presentation is a no-op. Restores the
-- graphics color afterwards.
---@param presentation table<string, unknown>
---@param planOrLayout table<string, unknown> the matched plan or a resolved layout
---@param icons table<string, unknown>?
function PartyScreenRenderer:draw(presentation, planOrLayout, icons)
  assert(type(presentation) == "table", "the party renderer requires a presentation")
  assert(type(planOrLayout) == "table", "the party renderer requires a plan or resolved layout")
  local panes = planOrLayout.panes
  local layout = planOrLayout
  if type(panes) == "table" then
    layout = assert(planOrLayout.content, "the party plan carries its canonical content")
  end
  assert(type(layout.slotRects) == "table", "the party renderer requires a resolved layout")
  if not presentation.open then
    return
  end
  assert(
    type(presentation.view) == "table" and type(presentation.view.slots) == "table",
    "the presentation needs a view"
  )
  local graphics = self._graphics
  local red, green, blue, alpha = 1, 1, 1, 1
  if graphics.getColor then
    red, green, blue, alpha = graphics.getColor()
  end
  local ok, err = pcall(function()
    self:_drawContent(presentation, layout, assert(icons, "occupied slots need the icon provider"))
    if type(panes) == "table" then
      for _, pane in ipairs(panes) do
        if pane.id ~= "content" then
          local placement = assert(pane.placement, "detail panes carry placements")
          self:_drawDetailPane(presentation, placement, assert(icons, "detail needs the icon provider"))
        end
      end
    end
  end)
  if graphics.setColor then
    graphics.setColor(red, green, blue, alpha)
  end
  if not ok then
    error(err, 0)
  end
end

---@param presentation table<string, unknown>
---@param layout table<string, unknown>
---@param icons table<string, unknown>
function PartyScreenRenderer:_drawContent(presentation, layout, icons)
  local graphics = self._graphics
  local view = assert(presentation.view, "the presentation needs a view")
  local panels = assert(self._manifest.panels, "the party manifest carries panels")
  local anim = presentation.anim
  local phases = anim ~= nil and anim.phases or nil
  local tick = anim ~= nil and anim.tick or 0
  local swap = presentation.swap
  local cursorNode = presentation.cursorNode
  local visuals = assert(self._manifest.visuals, "the party manifest carries visuals")
  local mainBackdrop = assert(visuals.backdropMain, "party visuals carry the main backdrop")
  setColor(graphics, WHITE)
  graphics.draw(self:_image(assert(mainBackdrop.image, "the main backdrop carries an image path")), 0, 0)
  for slot0 = 0, 5 do
    local record = assert(view.slots[slot0 + 1], "the view carries six slots")
    local panel = assert(panels[slot0 + 1], "the party manifest carries six panels")
    -- Swap ticks offset the two records leftward and exchange their
    -- content at the visual midpoint; the start tick hides the source.
    local facts = record
    local offsetX = 0
    local hidden = false
    if swap ~= nil and (slot0 == swap.source or slot0 == swap.destination) then
      offsetX = swap.offsetPx or 0
      if swap.stage == "start" and slot0 == swap.source then
        hidden = true
      end
      if swap.exchanged == true then
        if slot0 == swap.source then
          facts = assert(view.slots[swap.destination + 1], "swap exchanges visible records")
        else
          facts = assert(view.slots[swap.source + 1], "swap exchanges visible records")
        end
      end
    end
    local selected = cursorNode == slot0
    local phase = 0
    if phases ~= nil and type(phases[slot0 + 1]) == "number" then
      phase = phases[slot0 + 1]
    end
    if not hidden then
      local disabled = presentation.context == "pick" and record.occupied and not record.eligible
      self:_drawSlot(facts, panel, offsetX, selected, phase, tick, icons, disabled)
    end
  end
  if type(cursorNode) == "number" then
    local panel = assert(panels[cursorNode + 1], "numeric focus addresses a Party panel")
    local cursorSequence = assert(visuals.cursor.sequences[panel.cursorSequence], "panel cursor sequence exists")
    local cursorPosition =
      assert(self._manifest.navigation.dpad.default[cursorNode + 1], "the default dpad carries the focused slot")
    self:_drawSequence(cursorSequence, tick, { x = cursorPosition.left, y = cursorPosition.top })
  end
  if layout.cancelRect ~= nil then
    local anchor = assert(self._manifest.controls.cancel.anchor, "Party controls carry the Cancel anchor")
    local buttonSequenceIndex = cursorNode == "cancel" and 2 or 1
    local buttonSequence =
      assert(visuals.buttons.sequences[buttonSequenceIndex], "Party buttons carry the Cancel state")
    self:_drawSequence(buttonSequence, tick, anchor)
  end
  if presentation.infoOverlay == true then
    self:_drawSlotText("i", layout.infoRect.x, layout.infoRect.y, false)
  else
    setColor(graphics, { 0.55, 0.55, 0.6, 1 })
    graphics.rectangle("fill", layout.infoRect.x, layout.infoRect.y, layout.infoRect.width, layout.infoRect.height)
  end
  if
    presentation.state == "context"
    or presentation.state == "item_context"
    or presentation.state == "mail_context"
  then
    local menu = assert(presentation.menu, "menu states carry their entries")
    local window = assert(layout.contextWindow, "the party layout carries the context window")
    self:_drawMenu(menu, assert(presentation.menuIndex, "menu states carry their focus"), window, layout)
  end
  if presentation.message ~= nil then
    self:_drawMessage(presentation.message)
  elseif presentation.state == "browse" or presentation.state == "swapping" then
    self:_drawBrowseMessage()
  end
  if presentation.state == "confirm" then
    local promptStatus = assert(presentation.prompt, "confirm states carry the prompt status")
    self:_drawPrompt(promptStatus)
  end
end

return PartyScreenRenderer
