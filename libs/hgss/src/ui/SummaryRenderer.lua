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
      -- Adjacent ink runs share an edge: the source color control
      -- inserts no spacing, so the next run starts exactly where the
      -- measured width of this one ends.
      x = x + width
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

-- Samples one generated frame sequence at a controller animation tick:
-- single-frame playbacks hold their first frame, one-shot playbacks
-- rest on their final frame, and looping playbacks run their prefix
-- once before cycling from their loop origin over summed frame
-- durations. Ticks count fixed summary updates, never wall-clock time.
---@param sequence table<string, unknown> generated animation descriptor
---@param tick integer non-negative animation tick
---@return table<string, unknown> the visible frame
local function frameAt(sequence, tick)
  assert(type(tick) == "number" and tick % 1 == 0 and tick >= 0, "animation ticks stay non-negative")
  local frames = assert(sequence.frames, "animations carry their frames")
  assert(type(frames) == "table" and #frames >= 1, "animations carry at least one frame")
  local playback = assert(sequence.playback, "animations carry their playback")
  if playback == "static" then
    return assert(frames[1], "single-frame animations carry their frame")
  end
  local loopFrom = assert(sequence.loopFrom, "animations carry their loop origin")
  assert(
    type(loopFrom) == "number" and loopFrom % 1 == 0 and loopFrom >= 1 and loopFrom <= #frames,
    "loop origins address a frame"
  )
  local start = 1
  if playback == "loop" then
    local prefixDuration = 0
    for index = 1, loopFrom - 1 do
      prefixDuration = prefixDuration + assert(frames[index].durationTicks, "animation frames carry their duration")
    end
    if tick < prefixDuration then
      local elapsed = tick
      for index = 1, loopFrom - 1 do
        local duration = assert(frames[index].durationTicks, "animation frames carry their duration")
        if elapsed < duration then
          return frames[index]
        end
        elapsed = elapsed - duration
      end
    end
    local loopDuration = 0
    for index = loopFrom, #frames do
      loopDuration = loopDuration + assert(frames[index].durationTicks, "animation frames carry their duration")
    end
    assert(loopDuration > 0, "looping animations carry loop duration")
    tick = (tick - prefixDuration) % loopDuration
    start = loopFrom
  end
  local elapsed = tick
  for index = start, #frames do
    local duration = assert(frames[index].durationTicks, "animation frames carry their duration")
    if elapsed < duration then
      return frames[index]
    end
    elapsed = elapsed - duration
  end
  if playback == "once" then
    return frames[#frames]
  end
  error("animation sequences use static, once, or loop playback", 0)
end

-- Resolves one named animation descriptor through the sprite roles. A
-- name the family does not publish is a generated-contract failure;
-- the owner names the chrome that needed it.
---@param manifest table<string, unknown> validated summary family
---@param name string generated animation name
---@param owner string chrome needing the animation for failure diagnostics
---@return table<string, unknown> the generated animation descriptor
local function animationFor(manifest, name, owner)
  local sprites = assert(manifest.sprites, owner .. " needs its sprite roles")
  assert(type(sprites) == "table", "sprite roles arrive as a record")
  local animations = assert(sprites.animations, "sprite roles carry their animations")
  assert(type(animations) == "table", "sprite animations arrive as a record")
  local sequence = animations[name]
  assert(type(sequence) == "table", "the family publishes animation " .. tostring(name) .. " for " .. owner)
  return sequence
end

---@param status table<string, unknown> stable controller status
---@return integer the animation tick, defaulting to the first frame
local function animationTick(status)
  local tick = status.spriteTick
  if tick == nil then
    return 0
  end
  assert(type(tick) == "number" and tick % 1 == 0 and tick >= 0, "animation ticks stay non-negative")
  return tick
end

-- Draws one named animation frame at its semantic anchor plus the
-- compiled visual offset at native scale. The frame visual resolves
-- through the ready bundle; a published animation whose visual was
-- never prepared fails loudly instead of substituting art.
---@param scope SummaryRenderer.DrawScope
---@param name string generated animation name
---@param owner string chrome needing the animation for failure diagnostics
---@param anchor table<string, integer> semantic draw position
---@param tick integer non-negative animation tick
local function drawAnimation(scope, name, owner, anchor, tick)
  assert(type(anchor) == "table", "animation anchors are records")
  local anchorX = assert(anchor.x, "animation anchors carry x")
  local anchorY = assert(anchor.y, "animation anchors carry y")
  assert(type(anchorX) == "number" and type(anchorY) == "number", "animation anchors stay numeric")
  local frame = frameAt(animationFor(scope.manifest, name, owner), tick)
  local visual = assert(frame.visual, "animation frames name their visual")
  assert(type(visual) == "string" and visual ~= "", "animation frames name their visual")
  local visuals = assert(scope.manifest.visuals, "the summary family carries its visuals")
  assert(type(visuals) == "table", "summary visuals arrive as a record")
  local record = assert(visuals[visual], "the family publishes visual " .. tostring(visual))
  assert(type(record) == "table", "summary visuals are records")
  local image = visualImage(scope, visual)
  assert(image ~= nil, "no prepared image for animation " .. tostring(name))
  local shiftX, shiftY = 0, 0
  if record.offset ~= nil then
    assert(type(record.offset) == "table", "visual offsets are records")
    shiftX = assert(record.offset.x, "visual offsets carry x")
    shiftY = assert(record.offset.y, "visual offsets carry y")
    assert(type(shiftX) == "number" and type(shiftY) == "number", "visual offsets stay numeric")
  end
  scope.graphics.draw(image, anchorX + shiftX, anchorY + shiftY)
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

-- The ordinary member focus: the primary cursor at the displayed
-- member's anchor on the sub pane. Picker launches keep the member
-- cursor hidden while nested states show their own row chrome instead.
---@param scope SummaryRenderer.DrawScope
---@param status table<string, unknown>
---@param tick integer non-negative animation tick
local function drawMemberCursor(scope, status, tick)
  -- Detached subjects never address the six Party cursor anchors: the
  -- controller reports the chrome capability explicitly and the renderer
  -- never infers it from the numeric slot.
  if status.showMemberCursor ~= true then
    return
  end
  if status.mode ~= "summary" or status.phase ~= "root" then
    return
  end
  local sprites = assert(scope.manifest.sprites, "member focus needs its sprite roles")
  assert(type(sprites) == "table", "sprite roles arrive as a record")
  local cursor = assert(sprites.primaryCursor, "sprite roles carry the member cursor")
  assert(type(cursor) == "table", "member cursors arrive as records")
  local anchors = assert(cursor.anchors, "the member cursor carries its member anchors")
  assert(type(anchors) == "table", "member anchors arrive as an array")
  local slot = assert(status.slot, "open summaries carry their member slot")
  assert(type(slot) == "number" and slot % 1 == 0 and slot >= 0, "member slots stay non-negative")
  local anchor = assert(anchors[slot + 1], "the member cursor covers member slot " .. tostring(slot))
  local animation = assert(cursor.rootFocus, "the member cursor names its focus animation")
  assert(type(animation) == "string" and animation ~= "", "member cursors name their focus animation")
  drawAnimation(scope, animation, "member focus", anchor, tick)
end

-- Resolves one move-row anchor from the nested move geometry: owned
-- rows hang off the first-row origin by the row step, while the
-- picker-only extra row uses its dedicated cancel anchor.
---@param geometry table<string, unknown> generated nested move geometry
---@param row integer zero-based move row
---@return table<string, integer> the semantic row anchor
local function moveRowAnchor(geometry, row)
  assert(type(row) == "number" and row % 1 == 0 and row >= 0, "move rows stay non-negative")
  if row < SummaryRenderer.MOVE_ROWS then
    local column = assert(geometry.x, "move geometry carries its column")
    local baseY = assert(geometry.rowBaseY, "move geometry carries its first row")
    local step = assert(geometry.rowStep, "move geometry carries its row step")
    assert(
      type(column) == "number" and type(baseY) == "number" and type(step) == "number",
      "move geometry stays numeric"
    )
    return { x = column, y = baseY + row * step }
  end
  local anchor = assert(geometry.cancelAnchor, "move geometry carries its cancel anchor")
  assert(type(anchor) == "table", "cancel anchors are records")
  return anchor
end

-- The nested move cursors on the sub pane: the primary cursor follows
-- the pointed row in detail, reorder, and sliding states as well as in
-- picker browsing, while reordering adds the secondary cursor on the
-- held source row.
---@param scope SummaryRenderer.DrawScope
---@param status table<string, unknown>
---@param tick integer non-negative animation tick
local function drawMoveCursors(scope, status, tick)
  local nested = status.phase == "move_detail"
    or status.phase == "move_reorder"
    or status.phase == "move_opening"
    or status.phase == "move_closing"
  local picking = status.mode == "move_pick" and status.phase == "root"
  if not nested and not picking then
    return
  end
  if status.moveSlot == nil then
    return
  end
  local cursor = assert(status.moveSlot, "move states carry their pointed row")
  assert(type(cursor) == "number" and cursor % 1 == 0 and cursor >= 0, "move rows stay non-negative")
  local sprites = assert(scope.manifest.sprites, "move focus needs its sprite roles")
  assert(type(sprites) == "table", "sprite roles arrive as a record")
  local primary = assert(sprites.primaryCursor, "sprite roles carry the move cursor")
  assert(type(primary) == "table", "move cursors arrive as records")
  local geometry = assert(sprites.secondaryMoveCursor, "sprite roles carry the nested move geometry")
  assert(type(geometry) == "table", "move geometry arrives as a record")
  local focus = assert(primary.moveRowFocus, "the move cursor names its row animation")
  assert(type(focus) == "string" and focus ~= "", "move cursors name their row animation")
  if cursor >= SummaryRenderer.MOVE_ROWS then
    focus = assert(primary.restrictedCancel, "the move cursor names its cancel animation")
    assert(type(focus) == "string" and focus ~= "", "move cursors name their cancel animation")
  end
  drawAnimation(scope, focus, "move focus", moveRowAnchor(geometry, cursor), tick)
  if nested and status.phase == "move_reorder" and status.reorderSource ~= nil then
    local source = assert(status.reorderSource, "reorder states carry their held row")
    assert(type(source) == "number" and source % 1 == 0 and source >= 0, "held rows stay non-negative")
    local follow = assert(geometry.moveFollow, "move geometry names its reorder animation")
    assert(type(follow) == "string" and follow ~= "", "move geometry names its reorder animation")
    drawAnimation(scope, follow, "move reorder", moveRowAnchor(geometry, source), tick)
  end
end

-- Draws the common nested-state backing translated along its generated
-- axis: the live transition offset while sliding, the terminal generated
-- offset once detail holds. The visual is translated, never wrapped or
-- stretched; pane clipping applies as usual.
---@param scope SummaryRenderer.DrawScope
---@param status table<string, unknown>
---@param key string "moveDetail" or "ribbonDetail"
local function drawDetailBacking(scope, status, key)
  local manifest = scope.manifest
  local transitions = assert(manifest.transitions, "the summary family carries its nested positions")
  assert(type(transitions) == "table", "nested positions arrive as a record")
  local track = assert(transitions[key], "the summary family carries its " .. key .. " positions")
  assert(type(track) == "table", "nested positions arrive as records")
  local positions = assert(track.positions, "nested positions carry their offsets")
  assert(type(positions) == "table" and #positions > 0, "nested positions carry at least one offset")
  local terminal = assert(positions[#positions], "nested positions carry their terminal offset")
  assert(type(terminal) == "number", "nested offsets stay numeric")
  local offset = terminal
  local transition = status.transition
  if type(transition) == "table" and transition.kind == key then
    offset = assert(transition.offset, "nested transitions carry their offset")
    assert(type(offset) == "number", "nested offsets stay numeric")
  end
  local axis = assert(track.axis, "nested positions carry their axis")
  assert(axis == "x" or axis == "y", "nested positions run along x or y")
  local image = visualImage(scope, "detailBacking")
  assert(image ~= nil, "no prepared image for the nested detail backing")
  if axis == "x" then
    scope.graphics.draw(image, offset, 0)
  else
    scope.graphics.draw(image, 0, offset)
  end
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
---@param tick integer non-negative animation tick
local function drawMoves(scope, status, facts, tick)
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
  if
    status.phase == "move_detail"
    or status.phase == "move_reorder"
    or status.phase == "move_opening"
    or status.phase == "move_closing"
  then
    drawDetailBacking(scope, status, "moveDetail")
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
  drawMoveCursors(scope, status, tick)
end

-- The INFO main-pane markers: the crown alone when earned, otherwise
-- one marker per earned leaf at its anchor. Marker facts arrive
-- crown-suppressed from the projection; a crown alongside true leaves
-- still draws the crown only. Other panes and groups draw no markers.
---@param scope SummaryRenderer.DrawScope
---@param facts table<string, unknown>
---@param tick integer non-negative animation tick
local function drawLeafCrown(scope, facts, tick)
  local indicators = assert(facts.indicators, "facts carry their indicators")
  assert(type(indicators) == "table", "indicators arrive as a record")
  local sprites = assert(scope.manifest.sprites, "leaf markers need their sprite roles")
  assert(type(sprites) == "table", "sprite roles arrive as a record")
  local roles = assert(sprites.leaves, "sprite roles carry leaf markers")
  assert(type(roles) == "table", "leaf markers arrive as records")
  local anchors = assert(roles.anchors, "leaf markers carry their anchors")
  assert(type(anchors) == "table", "leaf anchors arrive as an array")
  if indicators.crown == true then
    local crown = assert(roles.crown, "leaf markers name the crown")
    assert(type(crown) == "string" and crown ~= "", "leaf markers name the crown")
    local crownAnchor = assert(roles.crownAnchor, "leaf markers carry the crown anchor")
    drawAnimation(scope, crown, "crown marker", crownAnchor, tick)
    return
  end
  local leaf = assert(roles.leaf, "leaf markers name their leaf")
  assert(type(leaf) == "string" and leaf ~= "", "leaf markers name their leaf")
  local leaves = assert(indicators.leaves, "indicators carry their leaf slots")
  assert(type(leaves) == "table", "leaf slots arrive as an array")
  for index, earned in ipairs(leaves) do
    if earned then
      local anchor = assert(anchors[index], "leaf markers cover leaf slot " .. tostring(index))
      drawAnimation(scope, leaf, "leaf marker", anchor, tick)
    end
  end
end

-- The PERFORMANCE main pane: one generated name per contest row in
-- presentation order, then five star positions per row plus the
-- signed modifier marker. Positions past the row maximum draw
-- nothing; unfilled positions up to the maximum draw empty; filled
-- positions draw the row tone; a zero modifier draws no marker. A
-- locked screen (no computed rows) keeps its locked backing and draws
-- no invented values.
---@param scope SummaryRenderer.DrawScope
---@param facts table<string, unknown>
---@param tick integer non-negative animation tick
local function drawPerformance(scope, facts, tick)
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
  local sprites = assert(manifest.sprites, "performance stars need their sprite roles")
  assert(type(sprites) == "table", "sprite roles arrive as a record")
  local chrome = assert(sprites.performance, "sprite roles carry performance rows")
  assert(type(chrome) == "table", "performance chrome arrives as a record")
  local generated = assert(chrome.rows, "performance chrome carries its rows")
  assert(type(generated) == "table", "performance rows arrive as an array")
  for index, row in ipairs(rows) do
    assert(type(row) == "table", "performance rows are records")
    local generatedRow = assert(generated[index], "performance chrome covers row " .. tostring(index))
    assert(type(generatedRow) == "table", "performance rows are records")
    local starAnchors = assert(generatedRow.stars, "performance rows carry star anchors")
    assert(type(starAnchors) == "table", "star anchors arrive as an array")
    local max = assert(row.max, "performance rows carry their maximum")
    local stars = assert(row.stars, "performance rows carry their stars")
    local tone = assert(row.tone, "performance rows carry their tone")
    assert(type(max) == "number" and type(stars) == "number", "performance bounds stay numeric")
    assert(tone == "base" or tone == "above" or tone == "below", "performance tones stay in their set")
    for i = 0, 4 do
      local anchor = assert(starAnchors[i + 1], "performance rows carry five star anchors")
      if i > max then
        -- Positions past the row maximum draw nothing.
      elseif i > stars then
        local empty = assert(generatedRow.starEmpty, "performance rows name their empty state")
        assert(type(empty) == "string" and empty ~= "", "performance rows name their empty state")
        drawAnimation(scope, empty, "performance stars", anchor, tick)
      elseif tone == "above" then
        local above = assert(generatedRow.starAbove, "performance rows name their raised state")
        assert(type(above) == "string" and above ~= "", "performance rows name their raised state")
        drawAnimation(scope, above, "performance stars", anchor, tick)
      elseif tone == "below" then
        local below = assert(generatedRow.starBelow, "performance rows name their lowered state")
        assert(type(below) == "string" and below ~= "", "performance rows name their lowered state")
        drawAnimation(scope, below, "performance stars", anchor, tick)
      else
        local base = assert(generatedRow.starBase, "performance rows name their base state")
        assert(type(base) == "string" and base ~= "", "performance rows name their base state")
        drawAnimation(scope, base, "performance stars", anchor, tick)
      end
    end
    local modifier = assert(row.modifier, "performance rows carry their modifier")
    assert(type(modifier) == "number" and modifier % 1 == 0, "performance modifiers stay integral")
    local modifierAnchor = assert(generatedRow.modifier, "performance rows carry modifier anchors")
    if modifier > 0 then
      local positive = assert(generatedRow.modifierPositive, "performance rows name their positive marker")
      assert(type(positive) == "string" and positive ~= "", "performance rows name their positive marker")
      drawAnimation(scope, positive, "performance modifier", modifierAnchor, tick)
    elseif modifier < 0 then
      local negative = assert(generatedRow.modifierNegative, "performance rows name their negative marker")
      assert(type(negative) == "string" and negative ~= "", "performance rows name their negative marker")
      drawAnimation(scope, negative, "performance modifier", modifierAnchor, tick)
    end
  end
end

-- The ribbon grid cursor and page controls on the sub pane: the
-- cursor marks the page-local cell of the selected earned ribbon from
-- the grid origin and steps, the previous control shows only past the
-- first page, and the next control shows only while another earned
-- page exists.
---@param scope SummaryRenderer.DrawScope
---@param status table<string, unknown>
---@param ribbons table<string, unknown>[] earned ribbon facts
---@param tick integer non-negative animation tick
local function drawRibbonChrome(scope, status, ribbons, tick)
  local selected = status.ribbonIndex
  if selected == nil then
    return
  end
  assert(type(selected) == "number" and selected % 1 == 0 and selected >= 0, "ribbon selections stay non-negative")
  local sprites = assert(scope.manifest.sprites, "ribbon controls need their sprite roles")
  assert(type(sprites) == "table", "sprite roles arrive as a record")
  local roles = assert(sprites.ribbons, "sprite roles carry ribbon controls")
  assert(type(roles) == "table", "ribbon controls arrive as records")
  local origin = assert(roles.origin, "ribbon controls carry their grid origin")
  local columnStep = assert(roles.columnStep, "ribbon controls carry their column step")
  local rowStep = assert(roles.rowStep, "ribbon controls carry their row step")
  assert(type(origin) == "table", "grid origins are records")
  assert(type(columnStep) == "number" and type(rowStep) == "number", "grid steps stay numeric")
  local cell = selected % 9
  local cursor = {
    x = assert(origin.x, "grid origins carry x") + (cell % 3) * columnStep,
    y = assert(origin.y, "grid origins carry y") + math.floor(cell / 3) * rowStep,
  }
  local cursorAnimation = assert(roles.cursor, "ribbon controls name their cursor")
  assert(type(cursorAnimation) == "string" and cursorAnimation ~= "", "ribbon controls name their cursor")
  drawAnimation(scope, cursorAnimation, "ribbon cursor", cursor, tick)
  local page = status.ribbonPage
  if page == nil then
    page = math.floor(selected / 9)
  end
  assert(type(page) == "number" and page % 1 == 0 and page >= 0, "ribbon pages stay non-negative")
  if page > 0 then
    local previous = assert(roles.pagePrev, "ribbon controls carry the previous control")
    assert(type(previous) == "table", "page controls arrive as records")
    local previousAnimation = assert(previous.animation, "page controls name their animation")
    assert(type(previousAnimation) == "string" and previousAnimation ~= "", "page controls name animations")
    drawAnimation(
      scope,
      previousAnimation,
      "ribbon page control",
      assert(previous.anchor, "page controls carry anchors"),
      tick
    )
  end
  if (page + 1) * 9 < #ribbons then
    local following = assert(roles.pageNext, "ribbon controls carry the next control")
    assert(type(following) == "table", "page controls arrive as records")
    local followingAnimation = assert(following.animation, "page controls name their animation")
    assert(type(followingAnimation) == "string" and followingAnimation ~= "", "page controls name animations")
    drawAnimation(
      scope,
      followingAnimation,
      "ribbon page control",
      assert(following.anchor, "page controls carry anchors"),
      tick
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
---@param tick integer non-negative animation tick
local function drawRibbons(scope, status, facts, tick)
  local manifest = scope.manifest
  local ribbons = facts.ribbons or {}
  assert(type(ribbons) == "table", "ribbon records arrive as an array")
  if status.phase == "ribbon_opening" or status.phase == "ribbon_detail" or status.phase == "ribbon_closing" then
    drawDetailBacking(scope, status, "ribbonDetail")
  end
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
  drawRibbonChrome(scope, status, ribbons, tick)
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
    local tick = animationTick(status)
    if pane == "main" then
      drawPicture(scope, status)
      if group == "info" then
        drawMemo(scope, facts)
        drawLeafCrown(scope, facts, tick)
      elseif group == "skills" then
        drawSkills(scope, facts)
      else
        drawPerformance(scope, facts, tick)
      end
    else
      if group == "info" then
        drawInfo(scope, facts)
        drawMemberCursor(scope, status, tick)
      elseif group == "skills" then
        drawMoves(scope, status, facts, tick)
      else
        drawRibbons(scope, status, facts, tick)
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
