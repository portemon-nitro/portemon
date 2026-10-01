-- Composes the source-backed Party content and detail panes from one
-- immutable controller snapshot. Panel chrome paints first, then the slot
-- cursor, then balls, then icons, then text and indicators, so later OBJ
-- content never sinks under earlier chrome. All source text uses the
-- generated palette roles through the font collaborator; numerals use the
-- generated glyph images at their fixed fields. Draw never advances
-- animation clocks.

local FieldTextWindowRenderer = require("libs.hgss.src.ui.FieldTextWindowRenderer")
local PartyScreenTheme = require("libs.hgss.src.ui.PartyScreenTheme")
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
  assert(
    type(graphics.setScissor) == "function" and type(graphics.getScissor) == "function",
    "PartyScreenRenderer clips travelling slots through the graphics scissor"
  )
  local text = assert(opts.text, "the party renderer requires the generated font")
  assert(
    type(text.drawText) == "function" and type(text.textWidth) == "function",
    "the party renderer borrows generated text drawing and measurement"
  )
  assert(
    type(text.drawTextWithPalette) == "function" and type(text.drawLineWithPalette) == "function",
    "the party renderer draws source text through palette roles"
  )
  assert(
    type(text.windowBackgroundColor) == "function",
    "the party renderer fills message windows with the generated window color"
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
    for _, state in ipairs({ "normal", "selected", "fainted", "selectedFainted", "switchSelection" }) do
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
  local contextMenu = assert(manifest.contextMenu, "the party manifest carries context menus")
  assert(type(contextMenu) == "table", "the party manifest carries context menus")
  local contextFrames = assert(contextMenu.frames, "context menus carry button frames")
  assert(type(contextFrames) == "table", "context menus carry button frames")
  for _, shape in ipairs({ "standard", "cancel" }) do
    local group = assert(contextFrames[shape], "context menus carry the " .. shape .. " frame")
    for _, state in ipairs({ "raised", "selected", "pressed" }) do
      local visual = assert(group[state], "context " .. shape .. " frames carry " .. state)
      acquire(assert(visual.image, "context frames carry image paths"))
    end
  end
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

-- Converts one generated byte-alpha color band to the normalized band
-- the font collaborator consumes. Fresh tables keep the validated
-- manifest shared; absent alpha stays absent so fixture and source
-- records compare by value.
---@param color table<string, unknown>
---@param what string
---@return table<string, unknown>
local function band(color, what)
  assert(type(color) == "table", what .. " is a color")
  local out = {
    r = assert(color.r, what .. " carries r"),
    g = assert(color.g, what .. " carries g"),
    b = assert(color.b, what .. " carries b"),
  }
  local alpha = color.a
  if alpha ~= nil then
    assert(type(alpha) == "number", what .. " alpha stays numeric")
    if alpha > 1 then
      alpha = alpha / 255
    end
    out.a = alpha
  end
  return out
end

-- Normalizes one generated foreground/shadow/background text role for the
-- font collaborator.
---@param role table<string, unknown>
---@param what string
---@return table<string, unknown>
local function roleFor(role, what)
  assert(type(role) == "table", what .. " is a text role")
  return {
    foreground = band(assert(role.foreground, what .. " carries foreground"), what .. ".foreground"),
    shadow = band(assert(role.shadow, what .. " carries shadow"), what .. ".shadow"),
    background = band(assert(role.background, what .. " carries background"), what .. ".background"),
  }
end

-- Source context menus brighten the already-rendered party content toward
-- white before the menu layers draw. The coefficient names the source
-- blend step on the sixteen-step scale.
local BRIGHTEN_ALPHA = 8 / 16

-- Resolves one swap slot's signed horizontal slide in units from the
-- controller-published per-slot map. Records without the map are a
-- programming fault and fail instead of sliding by a guessed offset.
---@param swap table<string, unknown>?
---@param slot0 integer
---@return number signed slide in units
local function swapSlideOf(swap, slot0)
  if type(swap) ~= "table" then
    return 0
  end
  local offsets = assert(swap.offsets, "swap records carry their per-slot slide map")
  assert(type(offsets) == "table", "swap records carry their per-slot slide map")
  local slide = assert(offsets[slot0], "swap records slide every travelling slot")
  assert(type(slide) == "number", "swap records slide every travelling slot")
  return slide
end

-- The cursor stays hidden while a swap record exists: the native task
-- hides cursors when the operation arms and restores them only after the
-- final task clears it.
---@param swap table<string, unknown>?
---@return boolean hides
local function swapHidesCursor(swap)
  return type(swap) == "table"
end

-- Returns true when the slot is the locked switch source or the current
-- switch candidate.
---@param switchSelect table<string, unknown>?
---@param slot0 integer
---@return boolean
local function switchSelected(switchSelect, slot0)
  if type(switchSelect) ~= "table" then
    return false
  end
  return slot0 == switchSelect.source or slot0 == switchSelect.candidate
end

-- Draws one string through its generated palette role.
---@param value string
---@param x number
---@param y number
---@param role table<string, unknown>
function PartyScreenRenderer:_paletteText(value, x, y, role)
  local text = self._text
  text.drawTextWithPalette(text, value, x, y, role)
end

-- Resolves one array-shape icon timeline at a sequence-local tick. Static
-- timelines hold their frame; loop timelines replay from their loop
-- origin; once timelines rest on their final frame.
---@param timeline table<string, unknown>
---@param tick integer
---@return integer iconFrame, integer translateX, integer translateY
local function iconFrameAt(timeline, tick)
  assert(type(tick) == "number" and tick % 1 == 0 and tick >= 0, "icon ticks stay non-negative")
  local playback = assert(timeline.playback, "icon timelines carry playback")
  local loopFrom = assert(timeline.loopFrom, "icon timelines carry a loop origin")
  local count = #timeline
  assert(count >= 1, "icon timelines carry frames")
  assert(loopFrom >= 1 and loopFrom <= count, "icon loop origins address a frame")
  local function values(frame)
    local iconFrame = assert(frame.iconFrame, "icon frames address the atlas")
    assert(iconFrame == 1 or iconFrame == 2, "icon frames address the two atlas frames")
    local translateX = assert(frame.translateX, "icon frames carry x translation")
    local translateY = assert(frame.translateY, "icon frames carry y translation")
    assert(translateX % 1 == 0 and translateY % 1 == 0, "icon translations stay integral")
    return iconFrame, translateX, translateY
  end
  if playback == "static" then
    return values(assert(timeline[1], "icon timelines carry frames"))
  end
  assert(playback == "loop" or playback == "once", "icon timelines play static, loop, or once")
  local prefix = 0
  for index = 1, loopFrom - 1 do
    prefix = prefix + assert(timeline[index].durationTicks, "icon frames carry duration")
  end
  local elapsed = tick
  local start = 1
  if elapsed >= prefix then
    elapsed = elapsed - prefix
    start = loopFrom
    if playback == "loop" then
      local span = 0
      for index = loopFrom, count do
        span = span + assert(timeline[index].durationTicks, "icon frames carry duration")
      end
      elapsed = elapsed % span
    end
  end
  for index = start, count do
    local frame = timeline[index]
    local duration = assert(frame.durationTicks, "icon frames carry duration")
    if elapsed < duration then
      return values(frame)
    end
    elapsed = elapsed - duration
  end
  return values(assert(timeline[count], "icon timelines carry frames"))
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

-- Draws current/max HP numerals through the compiled digit glyphs at
-- their fixed source fields: the current value right-aligns inside its
-- three-digit field, slash and max keep their fixed origins.
---@param currentHp integer
---@param maxHp integer
---@param rect ScreenTopology.Rectangle
function PartyScreenRenderer:_drawHpNumerals(currentHp, maxHp, rect)
  local graphics = self._graphics
  local glyphs = assert(self._manifest.numberGlyphs, "the party manifest carries number glyphs")
  local advance = assert(glyphs.advance, "digit glyphs carry their advance")
  local digits = assert(glyphs.digits, "the party manifest carries digit glyphs")
  local placement = assert(glyphs.placement, "number glyphs carry their placement")
  local currentOrigin = assert(placement.current, "number glyphs place the current field")
  local slashOrigin = assert(placement.slash, "number glyphs place the slash")
  local maxOrigin = assert(placement.max, "number glyphs place the max field")
  setColor(graphics, WHITE)
  local current = tostring(currentHp)
  local x = rect.x + currentOrigin.x + (3 - #current) * advance
  local y = rect.y + currentOrigin.y
  for index = 1, #current do
    local digit = tonumber(current:sub(index, index))
    assert(digit ~= nil, "HP numerals render decimal digits")
    assert(digits[digit + 1], "the party manifest carries digit glyphs")
    graphics.draw(assert(self._images["digit:" .. digit], "digit images resolve once"), x, y)
    x = x + advance
  end
  local slash = assert(glyphs.slash, "the party manifest carries the HP slash")
  assert(slash.width, "the HP slash carries its width")
  graphics.draw(assert(self._images.slash, "slash images resolve once"), rect.x + slashOrigin.x, rect.y + slashOrigin.y)
  local max = tostring(maxHp)
  x = rect.x + maxOrigin.x
  y = rect.y + maxOrigin.y
  for index = 1, #max do
    local digit = tonumber(max:sub(index, index))
    assert(digit ~= nil, "HP numerals render decimal digits")
    assert(digits[digit + 1], "the party manifest carries digit glyphs")
    graphics.draw(assert(self._images["digit:" .. digit], "digit images resolve once"), x, y)
    x = x + advance
  end
end

-- Draws the level prefix image with digit glyphs beside it at the
-- generated level origin.
---@param level integer
---@param rect ScreenTopology.Rectangle
function PartyScreenRenderer:_drawLevel(level, rect)
  local graphics = self._graphics
  local glyphs = assert(self._manifest.numberGlyphs, "the party manifest carries number glyphs")
  local prefix = assert(glyphs.level, "the party manifest carries the level prefix")
  local prefixWidth = assert(prefix.width, "the level prefix carries its width")
  local placement = assert(glyphs.placement, "number glyphs carry their placement")
  local origin = assert(placement.level, "number glyphs place the level prefix")
  local digits = assert(glyphs.digits, "the party manifest carries digit glyphs")
  local advance = assert(glyphs.advance, "digit glyphs carry their advance")
  setColor(graphics, WHITE)
  local x = rect.x + origin.x
  local y = rect.y + origin.y
  graphics.draw(assert(self._images.level, "level images resolve once"), x, y)
  x = x + prefixWidth
  for index = 1, #tostring(level) do
    local digit = tonumber(tostring(level):sub(index, index))
    assert(digit ~= nil, "levels render decimal digits")
    assert(digits[digit + 1], "the party manifest carries digit glyphs")
    graphics.draw(assert(self._images["digit:" .. digit], "digit images resolve once"), x, y)
    x = x + advance
  end
end

---@param record table<string, unknown>
---@param panel table<string, unknown>
---@param dx number
---@param selected boolean
---@param sequenceTick integer
---@param sequence integer
---@param icons table<string, unknown>
function PartyScreenRenderer:_drawIcon(record, panel, dx, selected, sequenceTick, sequence, icons)
  local graphics = self._graphics
  local iconKey = assert(record.iconKey, "occupied slots carry an icon key")
  local animations = assert(self._manifest.iconAnimations, "the party manifest carries icon timelines")
  local timelines = assert(animations.sequences, "icon timelines resolve six sequences")
  local timeline = assert(timelines[sequence + 1], "icon timelines cover sequence " .. tostring(sequence))
  local iconFrame, translateX, translateY = iconFrameAt(timeline, sequenceTick)
  local iconImage = icons:image(iconKey)
  local quad = icons:quadFor(iconKey, iconFrame)
  local dims = icons:dimensions(iconKey)
  assert(
    type(dims) == "table" and type(dims.width) == "number" and type(dims.height) == "number",
    "the icon provider reports image dimensions"
  )
  local anchor = assert(panel.iconAnchor, "party panels carry the icon anchor")
  local x = anchor.x + dx - dims.width / 2 + translateX
  local y = anchor.y - dims.height / 2 + translateY
  if selected then
    x = x + SELECT_SHIFT
    y = y + SELECT_SHIFT
    if sequence >= 1 and sequence <= 4 then
      if iconFrame == 1 then
        y = y + BOB_UP
      else
        y = y + BOB_DOWN
      end
    end
  end
  setColor(graphics, WHITE)
  graphics.draw(iconImage, quad, x, y)
end

---@param panel table<string, unknown>
---@param dx number
---@param selected boolean
---@param tick integer
function PartyScreenRenderer:_drawBall(panel, dx, selected, tick)
  local visuals = assert(self._manifest.visuals, "the party manifest carries visuals")
  local ballSequence =
    assert(visuals.balls.sequences[selected and 2 or 1], "party balls carry normal and selected states")
  local ballAnchor = assert(panel.ballAnchor, "party panels carry the ball anchor")
  self:_drawSequence(ballSequence, tick, { x = ballAnchor.x + dx, y = ballAnchor.y })
end

-- Draws held-item, mail, and capsule markers at their generated anchors.
-- Markers composite above the icon, preserving the long-standing sprite
-- layering the focus/ball/icon pass order does not otherwise disturb.
---@param record table<string, unknown>
---@param panel table<string, unknown>
---@param dx number
---@param tick integer
function PartyScreenRenderer:_drawHeldMarkers(record, panel, dx, tick)
  local visuals = assert(self._manifest.visuals, "the party manifest carries visuals")
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

-- Draws one panel chrome variant at its generated origin.
---@param visual table<string, unknown>
---@param x number
---@param y number
function PartyScreenRenderer:_drawChrome(visual, x, y)
  setColor(self._graphics, WHITE)
  self._graphics.draw(self:_image(assert(visual.image, "party panel states carry image paths")), x, y)
end

-- Draws one occupied slot's text row: the display name in the ordinary
-- role at the name origin, the gender mark in its role at the fixed
-- generated origin, the level for healthy non-eggs, and the fixed HP
-- fields for non-egg slots. The status sprite travels with the sprite
-- pass below, never inside this panel-clipped row.
---@param record table<string, unknown>
---@param panel table<string, unknown>
---@param dx number horizontal swap offset applied to every panel coordinate
function PartyScreenRenderer:_drawSlotTextRow(record, panel, dx)
  local roles = assert(self._manifest.text, "the party manifest carries text").roles
  assert(type(roles) == "table", "the party manifest carries text roles")
  local ordinary = roleFor(assert(roles.ordinary, "party text carries the ordinary role"), "ordinary")
  local displayName = assert(record.displayName, "occupied slots carry a display name")
  assert(type(displayName) == "string", "the display name renders as text")
  local nameRect = assert(panel.text.name, "party panels carry the name subrect")
  self:_paletteText(displayName, nameRect.x + dx, nameRect.y, ordinary)
  local symbol = record.genderSymbol
  if symbol == "male" or symbol == "female" then
    local labels = assert(self._manifest.text.labels, "party text carries labels")
    local mark = assert(labels[symbol], "party text carries gender labels")
    assert(type(mark) == "string", "gender labels render as text")
    local markRole = roleFor(assert(roles[symbol], "party text carries gender roles"), symbol)
    local genderPoint = assert(panel.text.gender, "party panels carry the fixed gender origin")
    self:_paletteText(mark, genderPoint.x + dx, genderPoint.y, markRole)
  end
  local status = assert(record.status, "occupied slots carry a status")
  local isEgg = record.isEgg == true
  if status == "ok" and not isEgg then
    local levelRect = assert(panel.text.level, "party panels carry the level subrect")
    self:_drawLevel(
      assert(record.level, "occupied slots carry a level"),
      { x = levelRect.x + dx, y = levelRect.y, width = levelRect.width, height = levelRect.height }
    )
  end
  if not isEgg then
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

-- Draws the status sprite at its generated rectangle with the same slide
-- as the travelling slot. Status markers move with the ball, icon, and
-- held markers under the viewport, outside the home-panel clip.
---@param record table<string, unknown>
---@param panel table<string, unknown>
---@param dx number horizontal swap offset applied to the panel coordinate
function PartyScreenRenderer:_drawStatusMarker(record, panel, dx)
  local status = assert(record.status, "occupied slots carry a status")
  if status == "ok" then
    return
  end
  local visual = assert(self._manifest.visuals.status[status], "party status carries its semantic visual")
  local statusRect = assert(panel.statusRect, "party panels carry the status rectangle")
  setColor(self._graphics, WHITE)
  self._graphics.draw(
    self:_image(assert(visual.image, "party status visuals carry image paths")),
    statusRect.x + dx,
    statusRect.y
  )
end

-- Draws the open context menu as independent generated buttons: one
-- frame, fill, and label per entry. Unfocused entries use the raised
-- treatment; the focused entry uses the depressed treatment; an armed
-- press shows the pressed frame with the raised treatment through its
-- first half and the depressed treatment through its second half. The
-- generated frame art carries the button chrome, so no enclosing window
-- or highlight rectangle is painted. Ink and fill follow the generated
-- semantic role the entry style selects; the fixed cancel entry keeps
-- command ink through its own role.
---@param menu table<string, unknown>[]
---@param menuIndex integer
---@param menuPress { index: integer, phase: "pressed"|"selected" }?
---@param kind "topLevel"|"subcontext"
---@param layout table<string, unknown>
function PartyScreenRenderer:_drawMenu(menu, menuIndex, menuPress, kind, layout)
  local graphics = self._graphics
  local lookup = assert(layout.menuLayout, "the party layout carries generated menu records")
  local entries = lookup(kind, #menu)
  assert(#entries == #menu, "generated menu records index every entry")
  local contextMenu = assert(self._manifest.contextMenu, "the party manifest carries context menus")
  local frames = assert(contextMenu.frames, "context menus carry button frames")
  local roles = assert(contextMenu.textRoles, "context menus carry semantic text roles")
  for index, entry in ipairs(menu) do
    local generated = assert(entries[index], "generated menu records index every entry")
    local frameRect = assert(generated.frameRect, "menu entries carry frame rectangles")
    local textRect = assert(generated.textRect, "menu entries carry text rectangles")
    local group = assert(
      frames[assert(generated.frameShape, "menu entries name their frame shape")],
      "context menus carry the entry frame"
    )
    local style = assert(generated.style, "menu entries carry their semantic style")
    local role = assert(roles[style], "context menus carry the " .. tostring(style) .. " role")
    local focused = index == menuIndex
    local pressPhase = nil
    if menuPress ~= nil and menuPress.index == index then
      pressPhase = menuPress.phase
    end
    local frameState = "raised"
    local treatment = "raised"
    if pressPhase == "pressed" then
      frameState = "pressed"
    elseif pressPhase == "selected" then
      frameState = "selected"
      treatment = "depressed"
    elseif focused then
      frameState = "selected"
      treatment = "depressed"
    end
    local ink = roleFor(
      assert(role[treatment], "context " .. tostring(style) .. " carries the " .. treatment .. " role"),
      "context text " .. tostring(style) .. " " .. treatment
    )
    local background = assert(ink.background, "context roles carry their background")
    setColor(graphics, { background.r / 255, background.g / 255, background.b / 255, 1 })
    graphics.rectangle("fill", frameRect.x, frameRect.y, frameRect.width, frameRect.height)
    local visual = assert(group[frameState], "context frames carry the " .. frameState .. " state")
    setColor(graphics, WHITE)
    graphics.draw(self:_image(assert(visual.image, "context frames carry image paths")), frameRect.x, frameRect.y)
    self:_paletteText(assert(entry.label, "menu entries carry display labels"), textRect.x, textRect.y, ink)
  end
end

-- Expands one generated message template into window-local text
-- placements through the ordinary role. Line breaks stack at the source
-- line height; name segments expand the supplied display name. Later
-- segments on one line keep their measured horizontal advance.
---@param segments table[]
---@param displayName string?
---@return { value: string, x: number, y: number }[]
function PartyScreenRenderer:_templateOps(segments, displayName)
  local text = self._text
  local ops = {}
  local cursorX, cursorY = 0, 0
  for _, segment in ipairs(assert(segments, "templates carry segments")) do
    assert(type(segment) == "table" and type(segment.kind) == "string", "template segments carry a kind")
    if segment.kind == "text" then
      local value = assert(segment.value, "text segments carry display text")
      ops[#ops + 1] = { value = value, x = cursorX, y = cursorY }
      cursorX = cursorX + text:textWidth(value)
    elseif segment.kind == "lineBreak" then
      cursorX = 0
      cursorY = cursorY + 16
    elseif segment.kind == "name" then
      local name = assert(displayName, "name segments expand the menu slot display name")
      ops[#ops + 1] = { value = name, x = cursorX, y = cursorY }
      cursorX = cursorX + text:textWidth(name)
    else
      error("party message templates render text, line breaks, and names", 0)
    end
  end
  return ops
end

-- Expands one generated message template at a window origin through the
-- ordinary role. Line breaks stack at the source line height; name
-- segments expand the supplied display name.
---@param segments table[]
---@param x number
---@param y number
---@param displayName string?
function PartyScreenRenderer:_drawTemplate(segments, x, y, displayName)
  local roles = assert(self._manifest.text, "the party manifest carries text").roles
  local ordinary = roleFor(assert(roles.ordinary, "party text carries the ordinary role"), "ordinary")
  for _, op in ipairs(self:_templateOps(segments, displayName)) do
    self:_paletteText(op.value, x + op.x, y + op.y, ordinary)
  end
end

-- Composes one lower message window through the shared frame/fill/text
-- order when the borrowed window decoration is available. Without it
-- only the text draws, still anchored at the source window-local
-- origins, so decorations never invent geometry the caller did not own.
---@param box ScreenTopology.Rectangle
---@param ops { value: string, x: number, y: number }[]
function PartyScreenRenderer:_drawLowerWindow(box, ops)
  local roles = assert(self._manifest.text, "the party manifest carries text").roles
  local ordinary = roleFor(assert(roles.ordinary, "party text carries the ordinary role"), "ordinary")
  local background = self._text:windowBackgroundColor()
  local window = self._window
  if window ~= nil then
    local lines = {}
    for _, op in ipairs(ops) do
      lines[#lines + 1] = { text = op.value, x = op.x, y = op.y }
    end
    FieldTextWindowRenderer.draw({
      window = window,
      text = self._text,
      box = box,
      frameIndex = self._frameIndex,
      background = background,
      palette = ordinary,
      lines = lines,
    })
    return
  end
  for _, op in ipairs(ops) do
    self:_paletteText(op.value, box.x + op.x, box.y + op.y, ordinary)
  end
end

-- Draws the browse message through the generated browse window and the
-- choose-mon template.
function PartyScreenRenderer:_drawBrowseMessage()
  local manifest = self._manifest
  local windows = assert(manifest.windows, "the party manifest carries windows")
  local box = assert(windows.browse, "the party manifest carries the browse window")
  local templates = assert(manifest.text.templates, "the party manifest carries templates")
  local template = assert(templates.chooseMon, "the party manifest carries chooseMon")
  self:_drawLowerWindow(box, self:_templateOps(assert(template.segments, "chooseMon carries segments"), nil))
end

-- Draws the open-menu message through the source context window with
-- the item-action template expanded from the menu slot's display name.
---@param displayName string
function PartyScreenRenderer:_drawContextMessage(displayName)
  local manifest = self._manifest
  local windows = assert(manifest.windows, "the party manifest carries windows")
  local box = assert(windows.context, "the party manifest carries the context window")
  local templates = assert(manifest.text.templates, "the party manifest carries templates")
  local template = assert(templates.itemAction, "the party manifest carries itemAction")
  self:_drawLowerWindow(box, self:_templateOps(assert(template.segments, "itemAction carries segments"), displayName))
end

-- Resolves a transient action message to window-local text placements:
-- either existing literal text or a generated-template descriptor
-- expanded with its display name.
---@param message string|{ templateKey: string, displayName: string? }
---@return { value: string, x: number, y: number }[]
function PartyScreenRenderer:_actionOps(message)
  if type(message) == "string" then
    return { { value = message, x = 0, y = 0 } }
  end
  assert(type(message) == "table", "messages carry display text")
  local key = assert(message.templateKey, "action descriptors name their template")
  assert(type(key) == "string", "action descriptors name their template")
  local templates = assert(self._manifest.text.templates, "the party manifest carries templates")
  local template = assert(templates[key], "the party manifest carries template " .. key)
  return self:_templateOps(assert(template.segments, key .. " carries segments"), message.displayName)
end

-- Draws a transient action message through the generated action window.
---@param message string|{ templateKey: string, displayName: string? }
function PartyScreenRenderer:_drawActionMessage(message)
  local manifest = self._manifest
  local windows = assert(manifest.windows, "the party manifest carries windows")
  local box = assert(windows.action, "the party manifest carries the action window")
  self:_drawLowerWindow(box, self:_actionOps(message))
end

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
  local roles = assert(self._manifest.text, "the party manifest carries text").roles
  local ordinary = roleFor(assert(roles.ordinary, "party text carries the ordinary role"), "ordinary")
  local nicknameTextOrigin = assert(detail.nicknameTextOrigin, "party detail carries the nickname origin")
  self:_paletteText(displayName, originX + nicknameTextOrigin.x, originY + nicknameTextOrigin.y - slide, ordinary)
  local heldName = assert(facts.heldItemName, "detail facts carry a held-item display name")
  local heldItemTextOrigin = assert(detail.heldItemTextOrigin, "party detail carries the held-item text origin")
  self:_paletteText(heldName, originX + heldItemTextOrigin.x, originY + heldItemTextOrigin.y - slide, ordinary)
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

-- Source G2_SetBlendBrightness(30, 8) affects BG1/BG2/BG3/OBJ across the main screen.
-- In the flattened renderer, base Party content is already composed here; BG0-like
-- context/message/menu layers are drawn afterward and therefore remain unbrightened.
function PartyScreenRenderer:_brightenContent()
  local graphics = self._graphics
  local visuals = assert(self._manifest.visuals, "the party manifest carries visuals")
  local backdrop = assert(visuals.backdropMain, "party visuals carry the main backdrop")
  local width = assert(backdrop.width, "the main backdrop carries its width")
  local height = assert(backdrop.height, "the main backdrop carries its height")
  assert(type(width) == "number" and width > 0, "the main backdrop width stays positive")
  assert(type(height) == "number" and height > 0, "the main backdrop height stays positive")
  setColor(graphics, { 1, 1, 1, BRIGHTEN_ALPHA })
  graphics.rectangle("fill", 0, 0, width, height)
end

-- Draws one travelling panel's tilemap content with its swap slide,
-- clipping to the home panel rectangle while displaced: the native panel
-- step clears and copies inside the fixed home rectangle while sprites
-- move freely under the viewport. Stationary slots draw directly so
-- settled frames match the unclipped browse path exactly. The previous
-- scissor restores even when the panel callback fails.
---@param swap table<string, unknown>?
---@param panel table<string, unknown>
---@param slot0 integer
---@param slide number signed slide in units
---@param drawPanel fun(slide: number)
function PartyScreenRenderer:_drawClippedPanel(swap, panel, slot0, slide, drawPanel)
  local involved = swap ~= nil and (slot0 == swap.source or slot0 == swap.destination)
  if not involved or slide == 0 then
    drawPanel(slide)
    return
  end
  local graphics = self._graphics
  local origin = assert(panel.origin, "party panels carry origins")
  local size = assert(panel.size, "party panels carry sizes")
  local saveX, saveY, saveWidth, saveHeight = graphics.getScissor()
  graphics.setScissor(
    assert(origin.x, "party origins carry x"),
    assert(origin.y, "party origins carry y"),
    assert(size.width, "party sizes carry width"),
    assert(size.height, "party sizes carry height")
  )
  local ok, err = pcall(drawPanel, slide)
  graphics.setScissor(saveX, saveY, saveWidth, saveHeight)
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
  local anim = assert(presentation.anim, "the presentation carries animation clocks")
  local tick = assert(anim.tick, "animation clocks carry the tick")
  assert(tick % 1 == 0 and tick >= 0, "animation ticks stay non-negative integral")
  local sequenceTicks = assert(anim.sequenceTicks, "animation clocks carry sequence-local ticks")
  assert(type(sequenceTicks) == "table", "animation clocks carry sequence-local ticks")
  local sequences = assert(anim.sequences, "animation clocks carry icon sequences")
  assert(type(sequences) == "table", "animation clocks carry icon sequences")
  local swap = presentation.swap
  local cursorNode = presentation.cursorNode
  local visuals = assert(self._manifest.visuals, "the party manifest carries visuals")
  local mainBackdrop = assert(visuals.backdropMain, "party visuals carry the main backdrop")
  setColor(graphics, WHITE)
  graphics.draw(self:_image(assert(mainBackdrop.image, "the main backdrop carries an image path")), 0, 0)
  -- Per-slot swap geometry resolves once: each travelling slot slides
  -- outward from its own column and exchanges its visible record at full
  -- exit while the domain order holds for the final commit.
  local factsOf = {}
  local slideOf = {}
  local selectedOf = {}
  for slot0 = 0, 5 do
    local record = assert(view.slots[slot0 + 1], "the view carries six slots")
    local facts = record
    local slide = 0
    if swap ~= nil and (slot0 == swap.source or slot0 == swap.destination) then
      slide = swapSlideOf(swap, slot0)
      if swap.exchanged == true then
        if slot0 == swap.source then
          facts = assert(view.slots[swap.destination + 1], "swap exchanges visible records")
        else
          facts = assert(view.slots[swap.source + 1], "swap exchanges visible records")
        end
      end
    end
    factsOf[slot0 + 1] = facts
    slideOf[slot0 + 1] = slide
    selectedOf[slot0 + 1] = cursorNode == slot0
  end
  -- Source-relative passes across all six slots: panel chrome first, then
  -- the focus cursor under the sprites, then balls under icons, then held
  -- markers over icons, then text, then status markers. Panel passes clip
  -- to the home rectangle while displaced; sprite passes share the same
  -- slide under the viewport.
  for slot0 = 0, 5 do
    local facts = factsOf[slot0 + 1]
    local panel = assert(panels[slot0 + 1], "the party manifest carries six panels")
    local chrome = assert(panel.chrome, "party panels carry chrome")
    local chromeKey = "normal"
    if switchSelected(presentation.switchSelect, slot0) then
      chromeKey = "switchSelection"
    elseif selectedOf[slot0 + 1] then
      chromeKey = facts.status == "faint" and "selectedFainted" or "selected"
    elseif facts.occupied and facts.status == "faint" then
      chromeKey = "fainted"
    end
    local panelVisual = facts.occupied and assert(chrome[chromeKey], "party panels carry state chrome")
      or assert(self._manifest.visuals.auxPanel, "party assets carry the empty-slot panel")
    local origin = assert(panel.origin, "party panels carry origins")
    self:_drawClippedPanel(swap, panel, slot0, slideOf[slot0 + 1], function(slide)
      self:_drawChrome(panelVisual, origin.x + slide, origin.y)
    end)
  end
  if type(cursorNode) == "number" and not swapHidesCursor(swap) then
    local panel = assert(panels[cursorNode + 1], "numeric focus addresses a Party panel")
    local cursorSequence = assert(visuals.cursor.sequences[panel.cursorSequence], "panel cursor sequence exists")
    local cursorPosition =
      assert(self._manifest.navigation.dpad.default[cursorNode + 1], "the default dpad carries the focused slot")
    self:_drawSequence(cursorSequence, tick, { x = cursorPosition.left, y = cursorPosition.top })
  end
  for slot0 = 0, 5 do
    local facts = factsOf[slot0 + 1]
    if facts.occupied then
      local panel = assert(panels[slot0 + 1], "the party manifest carries six panels")
      self:_drawBall(panel, slideOf[slot0 + 1], selectedOf[slot0 + 1], tick)
    end
  end
  for slot0 = 0, 5 do
    local facts = factsOf[slot0 + 1]
    if facts.occupied then
      local panel = assert(panels[slot0 + 1], "the party manifest carries six panels")
      local sequence = assert(sequences[slot0 + 1], "animation clocks sequence every slot")
      local sequenceTick = assert(sequenceTicks[slot0 + 1], "icon timelines need sequence-local ticks")
      assert(sequence % 1 == 0 and sequenceTick % 1 == 0, "icon clocks stay integral")
      self:_drawIcon(facts, panel, slideOf[slot0 + 1], selectedOf[slot0 + 1], sequenceTick, sequence, icons)
    end
  end
  for slot0 = 0, 5 do
    local facts = factsOf[slot0 + 1]
    if facts.occupied then
      local panel = assert(panels[slot0 + 1], "the party manifest carries six panels")
      self:_drawHeldMarkers(facts, panel, slideOf[slot0 + 1], tick)
    end
  end
  for slot0 = 0, 5 do
    local facts = factsOf[slot0 + 1]
    if facts.occupied then
      local panel = assert(panels[slot0 + 1], "the party manifest carries six panels")
      self:_drawClippedPanel(swap, panel, slot0, slideOf[slot0 + 1], function(slide)
        self:_drawSlotTextRow(facts, panel, slide)
      end)
    end
  end
  for slot0 = 0, 5 do
    local facts = factsOf[slot0 + 1]
    if facts.occupied then
      local panel = assert(panels[slot0 + 1], "the party manifest carries six panels")
      self:_drawStatusMarker(facts, panel, slideOf[slot0 + 1])
    end
  end
  if layout.cancelRect ~= nil then
    local cancel = assert(self._manifest.controls.cancel, "party controls carry Cancel")
    local anchor = assert(cancel.anchor, "party controls carry the Cancel anchor")
    local buttonSequenceIndex = cursorNode == "cancel" and 2 or 1
    local buttonSequence =
      assert(visuals.buttons.sequences[buttonSequenceIndex], "party buttons carry the Cancel state")
    self:_drawSequence(buttonSequence, tick, anchor)
    local label = assert(cancel.label, "Cancel carries its generated label")
    assert(type(label) == "string", "the Cancel label renders as text")
    local textRect = assert(cancel.textRect, "Cancel carries its text rectangle")
    local roles = assert(self._manifest.text, "the party manifest carries text").roles
    local ordinary = roleFor(assert(roles.ordinary, "party text carries the ordinary role"), "ordinary")
    local width = self._text:textWidth(label)
    self:_paletteText(label, textRect.x + (textRect.width - width) / 2, textRect.y, ordinary)
  end
  local inMenu = presentation.state == "context"
    or presentation.state == "item_context"
    or presentation.state == "mail_context"
  -- Messages composite first: independent button frames paint over the
  -- message window where source placement overlaps them.
  if inMenu then
    self:_brightenContent()
  end
  if presentation.message ~= nil then
    self:_drawActionMessage(presentation.message)
  elseif inMenu then
    local slot = assert(presentation.menuSlot, "menu states remember their slot")
    local record = assert(view.slots[slot + 1], "menu messages address a party slot")
    self:_drawContextMessage(assert(record.displayName, "menu slots carry a display name"))
  elseif presentation.state == "browse" or presentation.state == "swapping" then
    self:_drawBrowseMessage()
  end
  if inMenu then
    local menu = assert(presentation.menu, "menu states carry their entries")
    local kind = presentation.state == "context" and "topLevel" or "subcontext"
    self:_drawMenu(
      menu,
      assert(presentation.menuIndex, "menu states carry their focus"),
      presentation.menuPress,
      kind,
      layout
    )
  end
  if presentation.state == "confirm" then
    local promptStatus = assert(presentation.prompt, "confirm states carry the prompt status")
    self:_drawPrompt(promptStatus)
  end
end

return PartyScreenRenderer
