-- The native party-screen renderer: draws one controller presentation
-- snapshot through manifest-backed 256x192 geometry. Panels paint their
-- compiled chrome; names print through the borrowed generated font while
-- HP and level numerals draw through the compiled digit/level/slash
-- glyphs; status text replaces the level line and eggs print names only.
-- Selected icons shift (2,2) off their stored base with a frame-driven
-- bob for healthy sequences; the menu-open panel slides through the
-- source show steps; swap ticks offset the two records leftward and
-- exchange their content at the visual midpoint. Held and capsule
-- indicators use their source sprites. Messages and context menus draw
-- through the shared window decoration with manifest rows; the yes/no
-- confirm draws through the owned source prompt renderer. The dual
-- detail pane and the info overlay reuse the same facts at the
-- source upper-screen anchors. Draw never advances controller clocks:
-- every offset here derives from the read-only presentation snapshot.
-- Restores the graphics color afterwards.

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

-- Uniform per-panel content offsets shared by every panel record.
local ICON_OFFSET = { x = 30, y = 16 }
local BALL_OFFSET = { x = 16, y = 14 }

-- Upper detail anchors in screen-local pixels: the source stored
-- coordinates minus the sub-screen offset, with the source vertical
-- parameter carried structurally (it rests at zero for party detail).
local DETAIL_DY = 0
local DETAIL_ICON = { x = 30, y = 200 }
local DETAIL_STATUS = { x = 50, y = 220 }

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
local HP_ZONE_COLORS = {
  full = { 0.25, 0.85, 0.35, 1 },
  green = { 0.25, 0.85, 0.35, 1 },
  yellow = { 0.95, 0.85, 0.25, 1 },
  red = { 0.9, 0.3, 0.25, 1 },
  fainted = { 0.3, 0.3, 0.35, 1 },
}
local HP_TROUGH = { 0.25, 0.1, 0.1, 1 }
local MENU_HIGHLIGHT = { 0.3, 0.3, 0.45, 1 }

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

-- Acquires every realized image this renderer draws: panel chrome, ball
-- and held indicators, cursor, numerals, and the yes/no prompt atlas.
-- Companion chrome (status frames, decoration, feedback, backdrops)
-- stays unloaded until its owning display lands.
---@param cacheFs CacheFs
---@param manifest table<string, unknown>
---@param uiManifest table<string, unknown>?
function PartyScreenRenderer:_acquire(cacheFs, manifest, uiManifest)
  local graphics = self._graphics
  local images = self._images
  local panels = manifestSection(manifest, "panels")
  local seen = {}
  for slot0 = 0, 5 do
    local panel = assert(panels[slot0 + 1], "the party manifest carries panel " .. slot0)
    local chrome = assert(panel.chrome, "party panels carry chrome")
    local normal = assert(chrome.normal, "party panels carry normal chrome")
    local path = assert(normal.image, "party chrome carries its image path")
    if seen[path] == nil then
      seen[path] = true
      acquireImage(graphics, cacheFs, path, images, "chrome:" .. path)
    end
  end
  local visuals = manifestSection(manifest, "visuals")
  local function acquireSequence(name)
    local visual = assert(visuals[name], "the party manifest carries " .. name)
    local sequences = assert(visual.sequences, "party visual " .. name .. " carries sequences")
    assert(type(sequences) == "table" and #sequences >= 1, "party visual " .. name .. " carries sequences")
    for index, sequence in ipairs(sequences) do
      local frames = assert(sequence.frames, "party visual sequences carry frames")
      assert(type(frames) == "table" and #frames >= 1, "party visual sequences carry frames")
      local frame = assert(frames[1], "party visuals draw their first frame")
      acquireImage(
        graphics,
        cacheFs,
        assert(frame.image, "party frames carry image paths"),
        images,
        name .. ":" .. index
      )
    end
  end
  acquireSequence("balls")
  acquireSequence("held")
  acquireSequence("cursor")
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
  local graphics = self._graphics
  local fill = PartyScreenTheme.fillLength(currentHp, maxHp)
  setColor(graphics, HP_TROUGH)
  graphics.rectangle("fill", bar.x, bar.y, bar.width, bar.height)
  if fill > 0 then
    local zone = PartyScreenTheme.hpZone(currentHp, maxHp)
    local zoneColors = HP_ZONE_COLORS[zone]
    assert(zoneColors ~= nil, "unknown HP zone " .. tostring(zone))
    setColor(graphics, zoneColors)
    graphics.rectangle("fill", bar.x, bar.y, fill, bar.height)
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
  local origin = assert(panel.origin, "party panels carry origins")
  local iconKey = assert(record.iconKey, "occupied slots carry an icon key")
  local iconImage = icons:image(iconKey)
  local quad = icons:quadFor(iconKey)
  local dims = icons:dimensions(record.iconKey)
  assert(
    type(dims) == "table" and type(dims.width) == "number" and type(dims.height) == "number",
    "the icon provider reports image dimensions"
  )
  local x = origin.x + dx + ICON_OFFSET.x
  local y = origin.y + ICON_OFFSET.y
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
function PartyScreenRenderer:_drawIndicators(record, panel, dx)
  local graphics = self._graphics
  local origin = assert(panel.origin, "party panels carry origins")
  setColor(graphics, WHITE)
  local ball = assert(self._images["balls:1"], "ball images resolve once")
  graphics.draw(ball, origin.x + dx + BALL_OFFSET.x, origin.y + BALL_OFFSET.y)
  if record.heldItem ~= nil and record.heldItem ~= "NONE" then
    local held = assert(self._images["held:1"], "held images resolve once")
    graphics.draw(held, origin.x + dx + BALL_OFFSET.x + 24, origin.y + BALL_OFFSET.y)
  end
  if record.capsule ~= nil then
    local capsuleBall = assert(self._images["balls:2"], "capsule ball images resolve once")
    graphics.draw(capsuleBall, origin.x + dx + BALL_OFFSET.x, origin.y + BALL_OFFSET.y)
  end
end

-- Shortens a card string to a measured width with an ellipsis at UTF-8
-- glyph boundaries; strings that already fit return unchanged.
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
---@param icons table<string, unknown>
---@param disabled boolean
function PartyScreenRenderer:_drawSlot(record, panel, dx, selected, phase, icons, disabled)
  local graphics = self._graphics
  local origin = assert(panel.origin, "party panels carry origins")
  local chrome = assert(panel.chrome, "party panels carry chrome")
  local normal = assert(chrome.normal, "party panels carry normal chrome")
  local chromeImage = assert(self._images["chrome:" .. normal.image], "panel chrome resolves once")
  setColor(graphics, WHITE)
  graphics.draw(chromeImage, origin.x + dx, origin.y)
  if not record.occupied then
    return
  end
  self:_drawIcon(record, panel, dx, selected, phase, icons, disabled)
  self:_drawIndicators(record, panel, dx)
  local displayName = assert(record.displayName, "occupied slots carry a display name")
  assert(type(displayName) == "string", "the display name renders as text")
  local nameRect = assert(panel.text.name, "party panels carry the name subrect")
  self:_drawSlotText(truncateToWidth(self._text, displayName, nameRect.width), nameRect.x + dx, nameRect.y, disabled)
  local status = assert(record.status, "occupied slots carry a status")
  local levelRect = assert(panel.text.level, "party panels carry the level subrect")
  if status ~= "ok" then
    local label = PartyScreenTheme.statusLabel(status)
    if label ~= nil then
      self:_drawSlotText(label, levelRect.x + dx, levelRect.y, disabled)
    end
  elseif not record.isEgg then
    local shiftedLevel = {
      x = levelRect.x + dx,
      y = levelRect.y,
      width = levelRect.width,
      height = levelRect.height,
    }
    self:_drawLevel(assert(record.level, "occupied slots carry a level"), shiftedLevel)
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
---@param layout table<string, unknown>
function PartyScreenRenderer:_drawMessage(message, layout)
  local manifest = self._manifest
  local windows = assert(manifest.windows, "the party manifest carries windows")
  local box = assert(windows.message, "the party manifest carries the message window")
  self:_drawSharedWindow({ x = box.x, y = box.y, width = box.width, height = box.height })
  self:_drawSlotText(message, box.x + 4, box.y + 4, false)
  local _ = layout
end

-- Draws the owned yes/no prompt through its controller status.
---@param promptStatus table<string, unknown>
function PartyScreenRenderer:_drawPrompt(promptStatus)
  local prompt = assert(self._prompt, "confirm prompts need the owned prompt renderer")
  prompt:draw(promptStatus)
end

-- Draws the selected mon's detail facts at the source upper-screen
-- anchors: icon, status label, name, and HP numerals with its indicators.
---@param facts table<string, unknown>
---@param originX number
---@param originY number
---@param icons table<string, unknown>
function PartyScreenRenderer:_drawDetailFacts(facts, originX, originY, icons)
  local graphics = self._graphics
  local iconKey = assert(facts.iconKey, "detail facts carry an icon key")
  local iconImage = icons:image(iconKey)
  local quad = icons:quadFor(iconKey)
  setColor(graphics, WHITE)
  graphics.draw(iconImage, quad, originX + DETAIL_ICON.x, originY + DETAIL_ICON.y - DETAIL_DY)
  local status = assert(facts.status, "detail facts carry a status")
  if status ~= "ok" then
    local label = PartyScreenTheme.statusLabel(status)
    if label ~= nil then
      self:_drawSlotText(label, originX + DETAIL_STATUS.x, originY + DETAIL_STATUS.y - DETAIL_DY, false)
    end
  end
  local displayName = assert(facts.displayName, "detail facts carry a display name")
  assert(type(displayName) == "string", "the detail name renders as text")
  self:_drawSlotText(displayName, originX + DETAIL_STATUS.x, originY + DETAIL_STATUS.y - DETAIL_DY - 16, false)
  if not facts.isEgg then
    self:_drawLevel(assert(facts.level, "detail facts carry a level"), {
      x = originX + DETAIL_STATUS.x,
      y = originY + DETAIL_STATUS.y - DETAIL_DY + 12,
      width = 48,
      height = 16,
    })
    self:_drawHpNumerals(
      assert(facts.currentHp, "detail facts carry current HP"),
      assert(facts.maxHp, "detail facts carry max HP"),
      { x = originX + DETAIL_STATUS.x, y = originY + DETAIL_STATUS.y - DETAIL_DY + 28, width = 64, height = 16 }
    )
  end
  if facts.heldItem ~= nil and facts.heldItem ~= "NONE" then
    local held = assert(self._images["held:1"], "held images resolve once")
    graphics.draw(held, originX + DETAIL_ICON.x + 32, originY + DETAIL_ICON.y - DETAIL_DY)
  end
end

---@param presentation table<string, unknown>
---@param placement table<string, unknown>
---@param icons table<string, unknown>
function PartyScreenRenderer:_drawDetailPane(presentation, placement, icons)
  local graphics = self._graphics
  local view = assert(presentation.view, "the presentation needs a view")
  assert(type(view.slots) == "table", "the presentation needs six slots")
  local cursor = presentation.cursorNode
  local facts
  if type(cursor) == "number" then
    facts = view.slots[cursor + 1]
  end
  setColor(graphics, { 0.08, 0.08, 0.12, 1 })
  graphics.rectangle("fill", placement.x, placement.y, placement.width, placement.height)
  if type(facts) == "table" and facts.occupied then
    self:_drawDetailFacts(facts, placement.x, placement.y, icons)
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
  local slide = anim ~= nil and anim.panelSlide or 0
  local swap = presentation.swap
  local menuSlot = presentation.menuSlot
  local cursorNode = presentation.cursorNode
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
    local origin = assert(panel.origin, "party panels carry origins")
    local slideX = 0
    if menuSlot == slot0 and slide ~= nil and slide ~= 0 then
      slideX = slide
    end
    local drawPanel = {
      origin = { x = origin.x, y = origin.y },
      size = panel.size,
      chrome = panel.chrome,
      text = panel.text,
      hp = panel.hp,
      compat = panel.compat,
    }
    if not hidden then
      local disabled = presentation.context == "pick" and record.occupied and not record.eligible
      self:_drawSlot(facts, drawPanel, offsetX + slideX, selected, phase, icons, disabled)
    end
  end
  -- The focus cursor draws over the focused panel through its compiled
  -- visual; cancel focus draws over the cancel rect when present.
  local cursorImage = assert(self._images["cursor:1"], "cursor images resolve once")
  local cursorRect
  if cursorNode == "cancel" then
    cursorRect = layout.cancelRect
  elseif type(cursorNode) == "number" then
    cursorRect = layout.slotRects[cursorNode + 1]
  end
  if cursorRect ~= nil then
    setColor(graphics, WHITE)
    graphics.draw(cursorImage, cursorRect.x, cursorRect.y)
  end
  if layout.cancelRect ~= nil then
    setColor(graphics, WHITE)
    self:_drawSlotText("Cancel", layout.cancelRect.x + 8, layout.cancelRect.y + 2, false)
  end
  if presentation.infoOverlay == true then
    self:_drawSlotText("i", layout.infoRect.x, layout.infoRect.y, false)
  else
    setColor(graphics, { 0.55, 0.55, 0.6, 1 })
    graphics.rectangle("fill", layout.infoRect.x, layout.infoRect.y, layout.infoRect.width, layout.infoRect.height)
  end
  local footerName = self:_footerName(presentation)
  if footerName ~= nil then
    self:_drawSlotText(
      truncateToWidth(self._text, footerName, layout.nameRect.width),
      layout.nameRect.x,
      layout.nameRect.y,
      false
    )
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
    self:_drawMessage(presentation.message, layout)
  end
  if presentation.state == "confirm" then
    local promptStatus = assert(presentation.prompt, "confirm states carry the prompt status")
    self:_drawPrompt(promptStatus)
  end
end

---@param presentation table<string, unknown>
---@return string? the footer name for the focused slot
function PartyScreenRenderer:_footerName(presentation)
  local view = assert(presentation.view, "the presentation needs a view")
  local cursorNode = presentation.cursorNode
  local named = cursorNode
  if named == "cancel" then
    named = 4
  end
  if type(named) ~= "number" then
    return nil
  end
  local record = assert(view.slots[named + 1], "the footer names a visible slot")
  if not record.occupied then
    return nil
  end
  local displayName = assert(record.displayName, "occupied slots carry a display name")
  assert(type(displayName) == "string", "the footer name renders as text")
  return displayName
end

return PartyScreenRenderer
