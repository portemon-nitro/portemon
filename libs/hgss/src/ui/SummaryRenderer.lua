-- Source-native Summary pane drawing over the generated Summary family:
-- two independent 256x192 surfaces with main content (trainer memo,
-- skills, performance) and sub content (info, battle moves, ribbons).
-- Group variants select their compiled backdrop; each group names the
-- group window roles it owns and draws generated labels and
-- display-ready facts through source palette roles; bars use their
-- compiled lengths, inks, and visual states; the
-- large picture draws centered on its anchor with
-- the current playback transform and palette operation. Static art stays
-- baked in its backings: tabs, titles, and decorative chrome are never
-- redrawn as generic rectangles. The renderer is observational: it reads
-- the stable status and the ready bundle only, advancing no clock,
-- requesting no resource, and realizing no image or shader from draw.
-- Quad lookups ride the bundle providers; image, shader, and decode work
-- stays in preparation. A visual role the family leaves unmapped skips
-- its layer while mapped roles stay strict.

local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class SummaryRenderer
---@field _graphics love.graphics
---@field _text table<string, unknown> the borrowed generated-font collaborator
local SummaryRenderer = {}
SummaryRenderer.__index = SummaryRenderer

SummaryRenderer.PANE_WIDTH = 256
SummaryRenderer.PANE_HEIGHT = 192
SummaryRenderer.PICTURE_ANCHOR = { x = 208, y = 104 }
SummaryRenderer.TEXT_PAD_X = 4
SummaryRenderer.TEXT_PAD_Y = 2
SummaryRenderer.LINE_STEP = 16
SummaryRenderer.MOVE_ROWS = 4

---@param opts { graphics?: love.graphics, text: table<string, unknown> }
---@return SummaryRenderer
function SummaryRenderer.new(opts)
  assert(type(opts) == "table", "the summary renderer requires options")
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(
    graphics and graphics.rectangle and graphics.draw and graphics.setColor,
    "SummaryRenderer requires love.graphics"
  )
  local text = assert(opts.text, "the summary renderer requires the generated font")
  assert(type(text) == "table", "the summary renderer borrows the generated font")
  return setmetatable({ _graphics = graphics, _text = text }, SummaryRenderer)
end

---@param status table<string, unknown>
---@param pane string
---@param assets table<string, unknown>
local function checkDrawArgs(status, pane, assets)
  assert(type(status) == "table", "the summary renderer needs its status")
  assert(pane == "main" or pane == "sub", "the summary renderer draws its main or sub pane")
  assert(type(assets) == "table", "the summary renderer needs its ready bundle")
  assert(type(assets.manifest) == "table", "the summary bundle carries the summary family")
  local portraits = assets.portraits
  if portraits ~= nil then
    assert(
      type(portraits.image) == "function"
        and type(portraits.quadFor) == "function"
        and type(portraits.dimensions) == "function",
      "portrait providers expose image, quadFor, and dimensions"
    )
  end
end

---@param assets table<string, unknown>
---@return table<string, unknown> the borrowed text collaborator
local function bundleText(self, assets)
  local text = assets.text or self._text
  assert(type(text.drawLineWithPalette) == "function", "summary text draws through palette roles")
  return text
end

---@param manifest table<string, unknown>
---@param group string
---@return table<string, unknown> the compiled group variants
local function groupVariants(manifest, group)
  local groups = assert(manifest.groups, "the summary family carries its groups")
  assert(type(groups) == "table", "summary groups are a record")
  local variants = assert(groups[group], "the summary family covers group " .. tostring(group))
  assert(type(variants) == "table", "summary group variants are a record")
  return variants
end

-- Selects the compiled backdrop index for one pane: eggs read the
-- restricted sub variant, a performance screen without computed rows
-- reads the locked or uncomputed variant, every other pane reads its
-- normal map. Numbers only; missing selections fail instead of guessing.
---@param variants table<string, unknown>
---@param pane string
---@param facts table<string, unknown>
---@return number backdrop index
local function backdropIndex(variants, pane, facts)
  if pane == "main" then
    local main = assert(variants.main, "summary group variants carry their main selection")
    assert(type(main) == "table", "main selections are records")
    if facts.isEgg ~= true and facts.performance ~= nil then
      local map = assert(main.map, "main selections carry their map")
      assert(type(map) == "number", "backdrop selections are numeric")
      return map
    end
    if type(main.locked) == "number" then
      return main.locked
    end
    local map = assert(main.map, "main selections carry their map")
    assert(type(map) == "number", "backdrop selections are numeric")
    return map
  end
  local sub = assert(variants.sub, "summary group variants carry their sub selection")
  assert(type(sub) == "table", "sub selections are records")
  if facts.isEgg == true and type(sub.restricted) == "number" then
    return sub.restricted
  end
  if facts.performance == nil and type(sub.noPerformance) == "number" then
    return sub.noPerformance
  end
  local normal = assert(sub.normal, "sub selections carry their normal map")
  assert(type(normal) == "number", "backdrop selections are numeric")
  return normal
end

---@param manifest table<string, unknown>
---@param group string native group owning the role
---@param pane string native pane owning the role
---@param role string group window role naming its rendering purpose
---@return { rect: table<string, integer>, palette: integer, ink: string } the compiled window role
local function groupWindow(manifest, group, pane, role)
  local windows = assert(manifest.windows, "the summary family carries its windows")
  assert(type(windows) == "table", "summary windows arrive as a record")
  local groups = assert(windows.groups, "the summary family carries its group roles")
  assert(type(groups) == "table", "summary group roles arrive as a record")
  local one = assert(groups[group], "the summary family covers group " .. tostring(group))
  assert(type(one) == "table", "summary group roles arrive as records")
  local panes = assert(one[pane], "group " .. tostring(group) .. " carries its " .. tostring(pane) .. " roles")
  assert(type(panes) == "table", "group pane roles arrive as records")
  local window = assert(
    panes[role],
    "group " .. tostring(group) .. " " .. tostring(pane) .. " carries its " .. tostring(role) .. " role"
  )
  assert(type(window) == "table", "summary window roles are records")
  local rect = assert(window.rect, "summary window roles carry their rect")
  assert(type(rect) == "table", "window rects are records")
  local palette = assert(window.palette, "summary window roles carry their palette role")
  assert(type(palette) == "number", "window palette roles are numeric")
  return window
end

---@param text table<string, unknown>
---@return table<string, integer> code by character, empty without the generated charmap
local function charmapOf(text)
  local fontDef = text.fontDef
  if type(fontDef) == "table" and type(fontDef.charmap) == "table" then
    return fontDef.charmap
  end
  return {}
end

---@param value string
---@param charmap table<string, integer>
---@return table<string, unknown>[] glyph tokens for the palette text path
local function encodeLine(value, charmap)
  local tokens = {}
  for char in Utf8Glyphs.iter(value) do
    tokens[#tokens + 1] = { kind = "glyph", code = charmap[char] or 0 }
  end
  if #tokens == 0 then
    tokens[1] = { kind = "glyph", code = 0 }
  end
  return tokens
end

---@param graphics love.graphics
---@return number, number, number, number current color, defaulting to opaque white
local function currentColor(graphics)
  if type(graphics.getColor) == "function" then
    local red, green, blue, alpha = graphics.getColor()
    if type(red) == "number" then
      return red, green, blue, alpha
    end
  end
  return 1, 1, 1, 1
end

---@class SummaryRenderer.DrawScope
---@field graphics love.graphics
---@field text table<string, unknown>
---@field charmap table<string, integer>
---@field assets table<string, unknown>
---@field manifest table<string, unknown>
---@param self SummaryRenderer
---@param assets table<string, unknown>
---@return SummaryRenderer.DrawScope
local function drawScope(self, assets)
  local text = bundleText(self, assets)
  return {
    graphics = self._graphics,
    text = text,
    charmap = charmapOf(text),
    assets = assets,
    manifest = assert(assets.manifest, "the summary bundle carries the summary family"),
  }
end

-- Resolves one generated label key to its wording. Generated labels
-- carry static native copy; a missing label is a programming fault and
-- fails loudly instead of substituting handwritten text.
---@param manifest table<string, unknown>
---@param name string generated label key
---@return string the generated wording
local function labelText(manifest, name)
  local text = assert(manifest.text, "the summary family carries its text")
  assert(type(text) == "table", "summary text arrives as a record")
  local labels = assert(text.labels, "the summary family carries its labels")
  assert(type(labels) == "table", "summary labels arrive as a record")
  local value = labels[name]
  assert(type(value) == "string" and value ~= "", "the summary text carries label " .. tostring(name))
  return value
end

---@param color table<string, number> byte-denominated source color
---@param what string color owner for failure diagnostics
---@return table<string, number> the normalized triple channel
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

-- Normalizes one compiled ink triple for the font collaborator:
-- compiled channels stay byte-denominated while byte alpha normalizes
-- to the collaborator's unit range, returning a fresh triple so the
-- shared compiled family is never mutated per consumer.
---@param role table<string, table<string, number>> compiled ink triple
---@return table<string, unknown> the normalized fg/shadow/bg triple
local function normalizeTriple(role)
  assert(type(role) == "table", "summary text inks are records")
  assert(type(role.foreground) == "table", "text inks carry foreground")
  assert(type(role.shadow) == "table", "text inks carry shadow")
  assert(type(role.background) == "table", "text inks carry background")
  return {
    foreground = band(role.foreground, "summary text foreground"),
    shadow = band(role.shadow, "summary text shadow"),
    background = band(role.background, "summary text background"),
  }
end

-- Resolves one named text ink (a nature ink or a window default ink)
-- through the compiled text roles. The compiler publishes every ink the
-- renderer names, so a missing ink is a programming fault and fails
-- loudly instead of guessing.
---@param manifest table<string, unknown>
---@param name string compiled ink role
---@return table<string, unknown> the normalized fg/shadow/bg triple
local function inkRole(manifest, name)
  local text = assert(manifest.text, "the summary family carries its text")
  assert(type(text) == "table", "summary text arrives as a record")
  local roles = assert(text.roles, "the summary family carries its text roles")
  assert(type(roles) == "table", "summary text roles arrive as a record")
  local role = assert(roles[name], "the summary text carries its " .. tostring(name) .. " ink")
  ---@cast role table<string, table<string, number>>
  return normalizeTriple(role)
end

-- Resolves one numeric source window palette slot through the compiled
-- text roles to its foreground/shadow/background triple, immediately
-- before palette text drawing. The compiler binds every used window
-- slot, so an unbound slot is a programming fault and fails loudly
-- instead of guessing ink.
---@param scope SummaryRenderer.DrawScope
---@param palette integer numeric source window palette slot
---@return table<string, unknown> the normalized fg/shadow/bg triple
local function resolveTextRole(scope, palette)
  local text = assert(scope.manifest.text, "the summary family carries its text")
  assert(type(text) == "table", "summary text arrives as a record")
  local roles = assert(text.roles, "the summary family carries its text roles")
  assert(type(roles) == "table", "summary text roles arrive as a record")
  local role = roles["slot" .. palette]
  assert(type(role) == "table", "the summary window palette slot resolves through its text role: " .. tostring(palette))
  ---@cast role table<string, table<string, number>>
  assert(type(role.foreground) == "table", "text roles carry foreground")
  assert(type(role.shadow) == "table", "text roles carry shadow")
  assert(type(role.background) == "table", "text roles carry background")
  return {
    foreground = band(role.foreground, "summary text foreground"),
    shadow = band(role.shadow, "summary text shadow"),
    background = band(role.background, "summary text background"),
  }
end

-- Resolves one memo run ink to its triple. Runs name compiled inks; a
-- color selection the compiled roles leave unbound keeps its run and
-- prints through the window triple instead of dropping content or
-- failing the pane.
---@param scope SummaryRenderer.DrawScope
---@param window { rect: table<string, integer>, palette: integer }
---@param name string memo run ink
---@return table<string, unknown> the normalized fg/shadow/bg triple
local function memoInk(scope, window, name)
  local text = assert(scope.manifest.text, "the summary family carries its text")
  assert(type(text) == "table", "summary text arrives as a record")
  local roles = assert(text.roles, "the summary family carries its text roles")
  assert(type(roles) == "table", "summary text roles arrive as a record")
  local role = roles[name]
  if type(role) == "table" then
    ---@cast role table<string, table<string, number>>
    return normalizeTriple(role)
  end
  return resolveTextRole(scope, window.palette)
end

-- Draws one role line through its window role: width-based alignment
-- inside the window rect with source palette selection, clipped to the
-- window so longer mod text can never rewrite native layout. Overlong
-- lines keep their explicit scissor instead of heuristic pagination.
---@param scope SummaryRenderer.DrawScope
---@param window { rect: table<string, integer>, palette: integer }
---@param value string
---@param align "left"|"center"|"right"
---@param triple table<string, unknown>? caller ink triple; the window palette triple when absent
local function drawWindowLine(scope, window, value, align, triple)
  local graphics = scope.graphics
  local text = scope.text
  local rect = window.rect
  local width = 0
  if type(text.textWidth) == "function" then
    width = text:textWidth(value) or 0
  end
  local x = rect.x + SummaryRenderer.TEXT_PAD_X
  if align == "right" then
    x = rect.x + rect.width - SummaryRenderer.TEXT_PAD_X - width
  elseif align == "center" then
    x = rect.x + math.floor((rect.width - width) / 2)
  end
  -- Overlong lines keep their aligned origin: the window scissor below
  -- clips whatever falls outside, so mod text can never rewrite native
  -- layout and the aligned edge stays source-true.
  local y = rect.y + SummaryRenderer.TEXT_PAD_Y
  graphics.setScissor(rect.x, rect.y, rect.width, rect.height)
  text:drawLineWithPalette(encodeLine(value, scope.charmap), x, y, triple or resolveTextRole(scope, window.palette))
  graphics.setScissor()
end

-- Draws the authored memo blocks at their source line positions within
-- the memo body: y follows (line-1)*16 with source x padding, never a
-- measured reflow. Every run draws once, in order, through its own ink
-- role; runs advance by their measured width so later runs never move
-- before earlier runs. Control-token breaks stay the caller's line splits.
---@param scope SummaryRenderer.DrawScope
---@param window { rect: table<string, integer>, palette: integer }
---@param blocks table<number, table<string, unknown>> ordered memo line blocks
local function drawMemoRuns(scope, window, blocks)
  local graphics = scope.graphics
  local text = scope.text
  assert(type(blocks) == "table", "memos carry their line blocks")
  local rect = window.rect
  for _, block in ipairs(blocks) do
    assert(type(block) == "table", "memo blocks are records")
    local line = assert(block.line, "memo blocks carry their line")
    assert(type(line) == "number" and line % 1 == 0 and line >= 1, "memo lines stay positive")
    local y = rect.y + (line - 1) * SummaryRenderer.LINE_STEP
    local x = rect.x + SummaryRenderer.TEXT_PAD_X
    for _, run in ipairs(assert(block.runs, "memo blocks carry text runs")) do
      assert(type(run) == "table", "memo runs are records")
      local value = assert(run.text, "memo runs carry text")
      assert(type(value) == "string", "memo runs carry text")
      local width = 0
      if type(text.textWidth) == "function" then
        width = text:textWidth(value) or 0
      end
      graphics.setScissor(rect.x, rect.y, rect.width, rect.height)
      text:drawLineWithPalette(
        encodeLine(value, scope.charmap),
        x,
        y,
        memoInk(scope, window, assert(run.ink, "memo runs carry their ink"))
      )
      graphics.setScissor()
      local gap = 0
      if type(text.textWidth) == "function" then
        gap = text:textWidth(" ") or 0
      end
      x = x + width + gap
    end
  end
end

---@param scope SummaryRenderer.DrawScope
---@param name string compiled visual name
---@return table<string, unknown>? realized image; nil skips the layer
local function visualImage(scope, name)
  local visuals = assert(scope.manifest.visuals, "the summary family carries its visuals")
  assert(type(visuals) == "table", "summary visuals arrive as a record")
  if visuals[name] == nil then
    return nil
  end
  local imageFor = scope.assets.visualImage
  assert(type(imageFor) == "function", "the ready bundle resolves named visuals")
  return imageFor(name)
end

-- Borrows one canonical path-owned image through the ready bundle. Paths
-- arrive from compiled visual records; a missing prepared image is a
-- generated-contract failure and fails loudly.
---@param scope SummaryRenderer.DrawScope
---@param path string cache-relative image path
---@return table<string, unknown> realized image
local function imageForPath(scope, path)
  assert(type(path) == "string" and path ~= "", "path reads name their cache-relative path")
  local imageFor = scope.assets.imageForPath
  assert(type(imageFor) == "function", "the ready bundle resolves canonical paths")
  local image = imageFor(path)
  assert(image ~= nil, "no prepared image for path " .. tostring(path))
  return image
end

-- Draws the pane backing: the condition-selected backdrop over the whole
-- native surface. A backdrop role the family leaves unmapped skips its
-- layer while the manifest selection itself stays strict.
---@param scope SummaryRenderer.DrawScope
---@param index number backdrop index
local function drawBackdrop(scope, index)
  assert(type(index) == "number" and index % 1 == 0, "backdrop selections stay integral")
  local image = visualImage(scope, "backdrop" .. index)
  if image == nil then
    return
  end
  scope.graphics.draw(image, 0, 0)
end

---@param color table<string, integer> 8-bit source color
---@return number, number, number normalized channels
local function normalizeColor(color)
  return color.r / 255, color.g / 255, color.b / 255
end

-- Draws one dynamic bar: full, partial, and empty visual states with no
-- scaled-rectangle smoothing or label tint. Widths and inks track the
-- compiled rule, which is required content: the schema rejects families
-- without health and experience tracks. Fainted health shows the source
-- zero behavior: no full or partial tile. Missing realized tiles skip
-- bar pixels while the filled lengths and text stay strict. The tint
-- follows the source quotient rule over filled pixels against the track
-- length (green above one half, yellow above one fifth, red otherwise),
-- never over filled 8-pixel tiles: a 25-pixel fill on the 48-pixel
-- health track reads green at the source while a tile count would
-- misread yellow.
---@param scope SummaryRenderer.DrawScope
---@param ruleName string "hp" or "exp"
---@param pixels integer filled pixels from the facts projection
---@param originX number bar origin x
---@param originY number bar origin y
local function drawBar(scope, ruleName, pixels, originX, originY)
  local graphics = scope.graphics
  local manifest = scope.manifest
  local bars = assert(manifest.bars, "the summary family carries bar rules")
  assert(type(bars) == "table", "bar rules arrive as a record")
  local rule = assert(bars[ruleName], "the summary family carries its " .. ruleName .. " bar rule")
  assert(type(rule) == "table", "bar rules arrive as records")
  local length = assert(rule.length, "bar rules carry their pixel length")
  assert(type(length) == "number" and length > 0, "bar lengths stay positive")
  assert(type(pixels) == "number" and pixels % 1 == 0 and pixels >= 0, "bar fills count non-negative pixels")
  local empty = visualImage(scope, ruleName .. "-empty")
  local full = visualImage(scope, ruleName .. "-full")
  if empty == nil or full == nil then
    return
  end
  local tile = 8
  local tiles = math.floor(length / tile)
  local filled = math.floor(pixels / tile)
  local partial = pixels % tile
  local colors = assert(rule.colors, "bar rules carry their inks")
  assert(type(colors) == "table", "bar inks arrive as a record")
  local tint = nil
  if ruleName == "hp" then
    tint = assert(colors.critical, "health bars carry their critical ink")
    if pixels * 2 > length then
      tint = assert(colors.high, "health bars carry their high ink")
    elseif pixels * 5 > length then
      tint = assert(colors.low, "health bars carry their low ink")
    end
  end
  local red, green, blue, alpha = currentColor(graphics)
  for index = 0, tiles - 1 do
    local x = originX + index * tile
    if index < filled then
      if tint ~= nil then
        local r, g, b = normalizeColor(tint)
        graphics.setColor(r, g, b, 1)
      end
      graphics.draw(full, x, originY)
      if tint ~= nil then
        graphics.setColor(red, green, blue, alpha)
      end
    elseif index == filled and partial > 0 then
      if tint ~= nil then
        local r, g, b = normalizeColor(tint)
        graphics.setColor(r, g, b, 1)
      end
      local quad = graphics.newQuad(0, 0, partial, tile, tile, tile)
      graphics.draw(full, quad, x, originY)
      if tint ~= nil then
        graphics.setColor(red, green, blue, alpha)
      end
    else
      graphics.draw(empty, x, originY)
    end
  end
end

-- Draws the large main-pane picture: the 80x80 frame centered on anchor
-- (208,104) plus the single compiled offset and the current playback
-- transform (offsets, scale, rotation, visibility). Frame, flip, scale,
-- rotation, visibility, and the palette operation apply together; a
-- no-op palette state draws unshaded so identity stays pixel-exact. The
-- portrait selector arrives exact from display facts and is never
-- reconstructed here; the palette target keeps its compiled integer
-- units and reaches the shader unchanged.
---@param scope SummaryRenderer.DrawScope
---@param status table<string, unknown>
local function drawPicture(scope, status)
  local graphics = scope.graphics
  local facts = assert(status.facts, "open summaries carry their facts")
  local manifest = scope.manifest
  local pictures = assert(manifest.pictures, "the summary family carries pictures")
  local picture = pictures[assert(facts.pictureKey, "facts carry the picture selection")]
  assert(type(picture) == "table", "the picture selection exists in the summary family")
  local anchor = SummaryRenderer.PICTURE_ANCHOR
  if facts.isEgg == true then
    local image = imageForPath(scope, assert(picture.visual, "egg pictures carry their visual"))
    local width, height = 80, 80
    if type(image.getWidth) == "function" then
      width, height = image:getWidth(), image:getHeight()
    end
    graphics.draw(image, anchor.x - math.floor(width / 2), anchor.y - math.floor(height / 2))
    return
  end
  local selector = assert(facts.portraitSelector, "facts carry the portrait selection")
  assert(type(selector) == "string" and selector ~= "", "portrait selections name their variant")
  local portraits = assert(scope.assets.portraits, "the ready bundle carries its portrait provider")
  local sample = assert(status.picture, "open pictures carry their playback sample")
  if sample.visible == false then
    return
  end
  local frameIndex = assert(sample.frameIndex, "picture samples carry their frame") + 1
  local quad = portraits:quadFor(selector, frameIndex)
  local image = portraits:image(selector)
  local dims = portraits:dimensions(selector)
  local width = assert(dims.width, "portraits report dimensions")
  local height = assert(dims.height, "portraits report dimensions")
  local placement = picture.placement or { offsetX = 0, offsetY = 0 }
  local x = anchor.x + (placement.offsetX or 0) + (sample.offsetX or 0)
  local y = anchor.y + (placement.offsetY or 0) + (sample.offsetY or 0)
  local sx = sample.scaleX or 1
  local sy = sample.scaleY or 1
  local rotation = (sample.rotationTurns or 0) * math.pi * 2
  local blend = sample.paletteBlend
  local shader = nil
  if type(blend) == "table" and (blend.coefficient or 0) ~= 0 then
    shader = assert(scope.assets.shader, "palette blends draw through the picture shader")
  end
  local previousShader = nil
  if type(graphics.getShader) == "function" then
    previousShader = graphics.getShader()
  end
  if shader ~= nil then
    local target = assert(blend.target, "palette blends carry their target")
    shader:send("u_target", { target.r, target.g, target.b })
    shader:send("u_coefficient", blend.coefficient)
    graphics.setShader(shader)
  end
  local red, green, blue, alpha = currentColor(graphics)
  graphics.setColor(1, 1, 1, 1)
  graphics.draw(image, quad, x, y, rotation, sx, sy, width / 2, height / 2)
  graphics.setColor(red, green, blue, alpha)
  if shader ~= nil then
    if previousShader ~= nil then
      graphics.setShader(previousShader)
    else
      graphics.setShader()
    end
  end
end

-- The INFO sub pane: display-ready identity and experience values in
-- their named roles, with the dynamic health/experience bars below the
-- experience roles. Health bars need hatched skills; eggs carry no
-- skills record, so their health bar stays undrawn while the experience
-- track still fills from its projection.
---@param scope SummaryRenderer.DrawScope
---@param facts table<string, unknown>
local function drawInfo(scope, facts)
  local manifest = scope.manifest
  local info = assert(facts.info, "facts carry their info section")
  local identity = assert(facts.identity, "facts carry their identity")
  drawWindowLine(
    scope,
    groupWindow(manifest, "info", "sub", "dexNumber"),
    tostring(assert(info.dexText, "info carries dex text")),
    "left"
  )
  drawWindowLine(
    scope,
    groupWindow(manifest, "info", "sub", "speciesName"),
    tostring(assert(identity.speciesName, "identities carry a species name")),
    "left"
  )
  drawWindowLine(
    scope,
    groupWindow(manifest, "info", "sub", "otName"),
    tostring(assert(identity.otName, "identities carry an ot name")),
    "left"
  )
  drawWindowLine(
    scope,
    groupWindow(manifest, "info", "sub", "idNumber"),
    tostring(assert(info.otIdText, "info carries its id")),
    "left"
  )
  local expPoints = groupWindow(manifest, "info", "sub", "expPoints")
  drawWindowLine(scope, expPoints, tostring(assert(info.experience, "info carries experience")), "left")
  local expToNext = groupWindow(manifest, "info", "sub", "expToNext")
  drawWindowLine(scope, expToNext, tostring(assert(info.expToNext, "info carries exp to next")), "left")
  local skills = facts.skills
  if type(skills) == "table" then
    local hpBar = assert(skills.hpBar, "skills carry their health projection")
    local filled = assert(hpBar.length, "health projections carry their fill")
    assert(type(filled) == "number" and filled % 1 == 0, "health fills count integral pixels")
    ---@cast filled integer
    drawBar(scope, "hp", filled, expPoints.rect.x, expPoints.rect.y + expPoints.rect.height)
  end
  local expBar = assert(info.expBar, "info carries its experience projection")
  local expFilled = assert(expBar.length, "experience projections carry their fill")
  assert(type(expFilled) == "number" and expFilled % 1 == 0, "experience fills count integral pixels")
  ---@cast expFilled integer
  drawBar(scope, "exp", expFilled, expToNext.rect.x, expToNext.rect.y + expToNext.rect.height)
end

-- The TRAINER MEMO main pane: authored memo blocks at their source line
-- positions within the memo body role.
---@param scope SummaryRenderer.DrawScope
---@param facts table<string, unknown>
local function drawMemo(scope, facts)
  local window = groupWindow(scope.manifest, "info", "main", "memoBody")
  local memo = assert(facts.memo, "facts carry their memo")
  drawMemoRuns(scope, window, assert(memo.blocks, "memos carry their line blocks"))
end

-- The SKILLS main pane: health, battle stat, and ability values in
-- their named roles. Nature-raised values print through the raised ink
-- role and nature-lowered values through the lowered ink role; neutral
-- values print through the window default ink.
---@param scope SummaryRenderer.DrawScope
---@param facts table<string, unknown>
local function drawSkills(scope, facts)
  local manifest = scope.manifest
  local skills = assert(facts.skills, "hatched mons carry skills")
  local nature = skills.nature or {}
  local up, down = nature.up, nature.down
  local values = {
    hpValue = assert(skills.currentHp, "skills carry current health"),
    attackValue = assert(skills.attack, "skills carry attack"),
    defenseValue = assert(skills.defense, "skills carry defense"),
    spAttackValue = assert(skills.specialAttack, "skills carry special attack"),
    spDefenseValue = assert(skills.specialDefense, "skills carry special defense"),
    speedValue = assert(skills.speed, "skills carry speed"),
  }
  local shifted = {
    attackValue = "attack",
    defenseValue = "defense",
    spAttackValue = "specialAttack",
    spDefenseValue = "specialDefense",
    speedValue = "speed",
  }
  local order = { "hpValue", "attackValue", "defenseValue", "spAttackValue", "spDefenseValue", "speedValue" }
  for _, roleName in ipairs(order) do
    local window = groupWindow(manifest, "skills", "main", roleName)
    local key = shifted[roleName]
    local triple = nil
    if key ~= nil and up == key then
      triple = inkRole(manifest, "statRaised")
    elseif key ~= nil and down == key then
      triple = inkRole(manifest, "statLowered")
    else
      triple = inkRole(manifest, assert(window.ink, "window roles carry their default ink"))
    end
    drawWindowLine(scope, window, tostring(values[roleName]), "left", triple)
  end
  drawWindowLine(
    scope,
    groupWindow(manifest, "skills", "main", "abilityName"),
    tostring(assert(skills.abilityName, "skills carry an ability name")),
    "left"
  )
  drawWindowLine(
    scope,
    groupWindow(manifest, "skills", "main", "abilityDescription"),
    tostring(assert(skills.abilityDescription, "skills carry an ability description")),
    "left"
  )
end

-- Formats one learned move row from its generated name and power
-- points: the generated points label separates the current and maximum
-- counts with spacing, never punctuation the generated family does not
-- own.
---@param manifest table<string, unknown>
---@param move table<string, unknown> learned move row
---@return string move row text
local function moveSummaryText(manifest, move)
  return tostring(assert(move.name, "moves carry a name"))
    .. " "
    .. labelText(manifest, "ppLabel")
    .. " "
    .. tostring(assert(move.pp, "moves carry pp"))
    .. " "
    .. tostring(assert(move.ppMax, "moves carry max pp"))
end

-- The BATTLE MOVES sub pane: four named move rows keep their positions;
-- empty rows stay blank. The selected row opens its detail backing with
-- generated power, accuracy, category, and description text, and the
-- picker preview holds the pointed move name without becoming a fifth
-- owned move. The footer names the held move while reordering and the
-- pointed move otherwise; the generated warning preempts it.
---@param scope SummaryRenderer.DrawScope
---@param status table<string, unknown>
---@param facts table<string, unknown>
local function drawMoves(scope, status, facts)
  local manifest = scope.manifest
  local moves = assert(facts.moves, "facts carry their move rows")
  assert(#moves == SummaryRenderer.MOVE_ROWS, "move facts carry four logical rows")
  for row = 0, SummaryRenderer.MOVE_ROWS - 1 do
    local move = assert(moves[row + 1], "move rows stay addressable")
    if move.kind == "move" then
      drawWindowLine(
        scope,
        groupWindow(manifest, "skills", "sub", "moveRow" .. row),
        moveSummaryText(manifest, move),
        "left"
      )
    end
  end
  if status.mode == "move_pick" then
    local pointed = moves[(status.moveSlot or 0) + 1]
    if pointed ~= nil and pointed.kind == "move" then
      drawWindowLine(
        scope,
        groupWindow(manifest, "skills", "sub", "prospectiveRow"),
        tostring(assert(pointed.name, "moves carry a name")),
        "left"
      )
    end
  end
  if status.phase == "move_detail" or status.phase == "move_reorder" or status.phase == "move_opening" then
    -- The move-detail backing scrolls under the detail rows: one full
    -- native-scale copy per frame, wrapping across the transition ticks
    -- so repeated draws cycle instead of stretching.
    local backing = visualImage(scope, "moveBacking")
    if backing ~= nil then
      local shift = 0
      if type(status.transition) == "table" and type(status.transition.ticksLeft) == "number" then
        shift = (status.transition.ticksLeft * 32) % SummaryRenderer.PANE_WIDTH
      end
      scope.graphics.draw(backing, -shift, 0)
    end
    local selected = moves[(status.moveSlot or 0) + 1]
    if selected ~= nil and selected.kind == "move" then
      drawWindowLine(
        scope,
        groupWindow(manifest, "skills", "sub", "detailPower"),
        labelText(manifest, "powerLabel") .. " " .. tostring(assert(selected.powerText, "moves carry power")),
        "left"
      )
      drawWindowLine(
        scope,
        groupWindow(manifest, "skills", "sub", "detailAccuracy"),
        labelText(manifest, "accuracyLabel") .. " " .. tostring(assert(selected.accuracyText, "moves carry accuracy")),
        "left"
      )
      drawWindowLine(
        scope,
        groupWindow(manifest, "skills", "sub", "detailCategory"),
        labelText(manifest, "categoryLabel") .. " " .. tostring(assert(selected.category, "moves carry a category")),
        "left"
      )
      drawWindowLine(
        scope,
        groupWindow(manifest, "skills", "sub", "detailDescription"),
        tostring(assert(selected.description, "moves carry a description")),
        "left"
      )
    end
  end
  local footer = groupWindow(manifest, "skills", "sub", "moveFooter")
  local notice = status.notice
  if type(notice) == "table" and notice.reason == "hm" then
    drawWindowLine(scope, footer, labelText(manifest, "hmWarning"), "left")
  else
    local held = nil
    if status.phase == "move_reorder" and status.reorderSource ~= nil then
      held = moves[status.reorderSource + 1]
    elseif status.moveSlot ~= nil then
      held = moves[status.moveSlot + 1]
    end
    if held ~= nil and held.kind == "move" then
      drawWindowLine(scope, footer, moveSummaryText(manifest, held), "left")
    end
  end
end

-- The PERFORMANCE main pane: one generated name per contest row in
-- presentation order. Star and state visuals have no mapped image role,
-- so rows print names only and never numeric debug text. A locked
-- screen (no computed rows) keeps its locked backing and draws no
-- invented values.
---@param scope SummaryRenderer.DrawScope
---@param facts table<string, unknown>
local function drawPerformance(scope, facts)
  local rows = facts.performance
  if rows == nil then
    return
  end
  assert(type(rows) == "table", "performance rows arrive as records")
  local manifest = scope.manifest
  for _, stat in ipairs({ "speed", "power", "skill", "stamina", "jump" }) do
    drawWindowLine(
      scope,
      groupWindow(manifest, "performance", "main", stat),
      labelText(manifest, stat .. "Name"),
      "left"
    )
  end
end

-- The RIBBONS sub pane: one 3x3 page of earned ribbon art above the
-- count and selected-ribbon roles. Cells render around the
-- controller-owned selection: without a selection there is no proved
-- page, so only the count shows. Cell indices address page-local
-- positions bounded by the earned count; art resolves by its compiled
-- path and draws in rows above the selected name. The count, name, and
-- description roles carry display-ready facts text only.
---@param scope SummaryRenderer.DrawScope
---@param status table<string, unknown>
---@param facts table<string, unknown>
local function drawRibbons(scope, status, facts)
  local manifest = scope.manifest
  local ribbons = facts.ribbons or {}
  assert(type(ribbons) == "table", "ribbon records arrive as an array")
  local nameWindow = groupWindow(manifest, "performance", "sub", "ribbonName")
  drawWindowLine(scope, groupWindow(manifest, "performance", "sub", "ribbonCount"), tostring(#ribbons), "left")
  local selected = nil
  if status.ribbonIndex ~= nil then
    assert(
      type(status.ribbonIndex) == "number" and status.ribbonIndex % 1 == 0 and status.ribbonIndex >= 0,
      "ribbon selections stay non-negative"
    )
    selected = ribbons[status.ribbonIndex + 1]
  end
  if selected == nil then
    return
  end
  assert(type(selected) == "table", "earned ribbons are records")
  local page = status.ribbonPage or 0
  assert(type(page) == "number" and page % 1 == 0 and page >= 0, "ribbon pages stay non-negative")
  local nameRect = nameWindow.rect
  for cell = 0, 8 do
    local earned = ribbons[page * 9 + cell + 1]
    if earned ~= nil then
      assert(type(earned) == "table", "earned ribbons are records")
      local art = assert(earned.art, "ribbons carry art")
      assert(type(art) == "table", "ribbon art arrives as a record")
      local path = assert(art.image, "ribbon art carries its image")
      assert(type(path) == "string", "ribbon art images are paths")
      local width = assert(art.width, "ribbon art carries a width")
      local height = assert(art.height, "ribbon art carries a height")
      assert(type(width) == "number" and type(height) == "number", "ribbon art carries dimensions")
      local column = cell % 3
      local row = math.floor(cell / 3)
      scope.graphics.draw(imageForPath(scope, path), nameRect.x + column * width, nameRect.y - (3 - row) * height)
    end
  end
  drawWindowLine(scope, nameWindow, tostring(assert(selected.name, "ribbons carry a name")), "left")
  drawWindowLine(
    scope,
    groupWindow(manifest, "performance", "sub", "ribbonDescription"),
    tostring(assert(selected.description, "ribbons carry a description")),
    "left"
  )
end

-- Draws the producer-authored sprite roles at their anchors, in role
-- order. A sprite role whose visual the family leaves unmapped skips
-- its layer; mapped roles resolve through the ready bundle. Member and
-- focus chrome comes from these roles alone, never from touch boxes or
-- party-family presentation.
---@param scope SummaryRenderer.DrawScope
local function drawChrome(scope)
  local sprites = assert(scope.manifest.sprites, "the summary family carries its sprite roles")
  assert(type(sprites) == "table", "sprite roles arrive as a record")
  local ordered = {}
  for name, sprite in pairs(sprites) do
    assert(type(sprite) == "table", "sprite roles are records")
    local order = assert(sprite.order, "sprite roles carry their order")
    assert(type(order) == "number", "sprite orders stay numeric")
    ordered[#ordered + 1] = { name = name, sprite = sprite, order = order }
  end
  table.sort(ordered, function(a, b)
    if a.order ~= b.order then
      return a.order < b.order
    end
    return tostring(a.name) < tostring(b.name)
  end)
  for _, entry in ipairs(ordered) do
    local sprite = entry.sprite
    local visual = assert(sprite.visual, "sprite roles name their visual")
    assert(type(visual) == "string", "sprite visuals are names")
    local image = visualImage(scope, visual)
    if image ~= nil then
      local anchor = assert(sprite.anchor, "sprite roles carry their anchor")
      assert(type(anchor) == "table", "sprite anchors are records")
      local x = assert(anchor.x, "sprite anchors carry x")
      local y = assert(anchor.y, "sprite anchors carry y")
      assert(type(x) == "number" and type(y) == "number", "sprite anchors stay numeric")
      scope.graphics.draw(image, x, y)
    end
  end
end

-- Draws one native pane: the condition-selected backdrop, the pane role
-- content for the current group, the current picture on main, and state
-- sprites. Every text role uses its window palette, alignment, and
-- scissor; bars use compiled lengths and states; the picture applies its
-- full transform with the palette operation. Caller color, shader, and
-- scissor state is restored before returning.
---@param status table<string, unknown> stable controller status with facts
---@param pane string "main" or "sub"
---@param assets table<string, unknown> ready resource bundle with manifest and providers
function SummaryRenderer:drawPane(status, pane, assets)
  checkDrawArgs(status, pane, assets)
  if not status.open then
    return
  end
  local facts = assert(status.facts, "open summaries carry their facts")
  local group = assert(status.group, "open summaries carry their native group")
  assert(group == "info" or group == "skills" or group == "performance", "groups stay in the native set")
  local scope = drawScope(self, assets)
  local graphics = scope.graphics
  local red, green, blue, alpha = currentColor(graphics)
  local previousShader = nil
  if type(graphics.getShader) == "function" then
    previousShader = graphics.getShader()
  end
  local hasScissor = type(graphics.getScissor) == "function" and type(graphics.setScissor) == "function"
  local scissorX, scissorY, scissorWidth, scissorHeight = nil, nil, nil, nil
  if hasScissor then
    scissorX, scissorY, scissorWidth, scissorHeight = graphics.getScissor()
  end
  local ok, err = pcall(function()
    local variants = groupVariants(scope.manifest, group)
    graphics.setColor(0, 0, 0, 1)
    graphics.rectangle("fill", 0, 0, SummaryRenderer.PANE_WIDTH, SummaryRenderer.PANE_HEIGHT)
    graphics.setColor(red, green, blue, alpha)
    drawBackdrop(scope, backdropIndex(variants, pane, facts))
    if pane == "main" then
      drawPicture(scope, status)
      if group == "info" then
        drawMemo(scope, facts)
      elseif group == "skills" then
        drawSkills(scope, facts)
      else
        drawPerformance(scope, facts)
      end
    else
      if group == "info" then
        drawInfo(scope, facts)
        drawChrome(scope)
      elseif group == "skills" then
        drawMoves(scope, status, facts)
      else
        drawRibbons(scope, status, facts)
      end
    end
  end)
  graphics.setColor(red, green, blue, alpha)
  if type(graphics.setShader) == "function" then
    if previousShader ~= nil then
      graphics.setShader(previousShader)
    else
      graphics.setShader()
    end
  end
  if hasScissor then
    if scissorX == nil then
      graphics.setScissor()
    else
      graphics.setScissor(
        assert(scissorX, "scissors carry coordinates"),
        assert(scissorY, "scissors carry coordinates"),
        assert(scissorWidth, "scissors carry coordinates"),
        assert(scissorHeight, "scissors carry coordinates")
      )
    end
  end
  if not ok then
    error(err, 0)
  end
end

return SummaryRenderer
