-- Source-native Summary pane drawing over the generated Summary family:
-- two independent 256x192 surfaces with main content (trainer memo,
-- skills, performance) and sub content (info, battle moves, ribbons).
-- Group variants select their compiled backdrop; windows place and clip
-- role text through source palette roles; bars use their compiled lengths,
-- inks, and visual states; the
-- large picture draws centered on its anchor with
-- the current playback transform and palette operation. Static art stays
-- baked in its backings: tabs, titles, and decorative chrome are never
-- redrawn as generic rectangles. The renderer is observational: it reads
-- the stable status and the ready bundle only, advancing no clock,
-- requesting no resource, and realizing no image or shader from draw.
-- Quad lookups ride the bundle providers; image, shader, and decode work
-- stays in preparation. Test bundles may carry a subset of visual layers;
-- absent realized art skips its layer while manifest roles stay strict.

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
---@param pane string
---@return { name: string, rect: table<string, integer>, palette: integer }[] ordered pane windows
local function paneWindows(manifest, pane)
  local windows = assert(manifest.windows, "the summary family carries its windows")
  assert(type(windows) == "table", "summary windows are a record")
  local names = {}
  for name, window in pairs(windows) do
    assert(type(window) == "table", "summary windows are records")
    if window.pane == pane then
      names[#names + 1] = name
    end
  end
  table.sort(names, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local ordered = {}
  for _, name in ipairs(names) do
    local window = windows[name]
    local rect = assert(window.rect, "summary windows carry their rect")
    local palette = assert(window.palette, "summary windows carry their palette role")
    assert(type(palette) == "number", "window palette roles are numeric")
    ordered[#ordered + 1] = { name = name, rect = rect, palette = palette }
  end
  return ordered
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

-- Resolves one numeric source window palette slot through the compiled
-- text roles to its foreground/shadow/background triple, immediately
-- before palette text drawing. The compiler binds every used window
-- slot, so an unbound slot is a programming fault and fails loudly
-- instead of guessing ink. Compiled channels stay byte-denominated for
-- the font collaborator; byte alpha normalizes to the collaborator's
-- unit range at this consumer boundary (the Party renderer's band rule),
-- returning a fresh triple so the shared compiled family is never
-- mutated per consumer.
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
  assert(type(role.foreground) == "table", "text roles carry foreground")
  assert(type(role.shadow) == "table", "text roles carry shadow")
  assert(type(role.background) == "table", "text roles carry background")
  return {
    foreground = band(role.foreground, "summary text foreground"),
    shadow = band(role.shadow, "summary text shadow"),
    background = band(role.background, "summary text background"),
  }
end

-- Draws one role line through its window role: width-based alignment
-- inside the window rect with source palette selection, clipped to the
-- window so longer mod text can never rewrite native layout. Overlong
-- lines keep their explicit scissor instead of heuristic pagination.
---@param scope SummaryRenderer.DrawScope
---@param window { rect: table<string, integer>, palette: integer }
---@param value string
---@param align "left"|"center"|"right"
local function drawWindowLine(scope, window, value, align)
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
  text:drawLineWithPalette(encodeLine(value, scope.charmap), x, y, resolveTextRole(scope, window.palette))
  graphics.setScissor()
end

-- Draws one authored memo line at its source line position within its
-- window: y follows (line-1)*16 with source x padding, never a measured
-- reflow. Control-token breaks stay the caller's line splits.
---@param scope SummaryRenderer.DrawScope
---@param window { rect: table<string, integer>, palette: integer }
---@param line integer one-based source line
---@param value string
local function drawMemoLine(scope, window, line, value)
  local graphics = scope.graphics
  local text = scope.text
  local rect = window.rect
  local x = rect.x + SummaryRenderer.TEXT_PAD_X
  local y = rect.y + (line - 1) * SummaryRenderer.LINE_STEP
  graphics.setScissor(rect.x, rect.y, rect.width, rect.height)
  text:drawLineWithPalette(encodeLine(value, scope.charmap), x, y, resolveTextRole(scope, window.palette))
  graphics.setScissor()
end

---@param windows { name: string, rect: table<string, integer>, palette: integer }[]
---@param what string pane role drawing the lines
---@return { name: string, rect: table<string, integer>, palette: integer }[] ordered pane windows
local function requireWindows(windows, what)
  assert(type(windows) == "table" and #windows >= 1, what .. " needs its pane windows")
  return windows
end

---@param scope SummaryRenderer.DrawScope
---@param name string compiled visual name
---@return table<string, unknown>? realized image, or nil when the bundle carries selected layers only
local function visualImage(scope, name)
  local visuals = scope.assets.visuals
  if type(visuals) == "table" and visuals[name] ~= nil then
    return visuals[name]
  end
  local imageFor = scope.assets.visualImage
  if type(imageFor) == "function" then
    return imageFor(name)
  end
  return nil
end

-- Draws the pane backing: the condition-selected backdrop over the whole
-- native surface. Test bundles may carry selected layers only; a missing
-- realized backdrop skips its layer while the manifest selection itself
-- stays strict.
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

-- Resolves the drawn portrait selector: genderless records use the known
-- female-side generated alias before any draw, never an exception probe.
---@param facts table<string, unknown>
---@return string portrait selector
local function portraitSelector(facts)
  local identity = assert(facts.identity, "facts carry their identity")
  local species = assert(facts.pictureKey, "facts carry the picture selection")
  if species == "EGG" then
    return "EGG"
  end
  local form = assert(identity.form, "identities carry their form")
  local gender = assert(identity.gender, "identities carry their gender")
  local shiny = identity.shiny == true
  if gender == "genderless" then
    gender = "female"
  end
  assert(gender == "male" or gender == "female", "portrait genders stay binary")
  local selector = species .. "/f" .. tostring(form) .. "/" .. gender
  if shiny then
    return selector .. "/shiny"
  end
  return selector .. "/plain"
end

-- Draws the large main-pane picture: the 80x80 frame centered on anchor
-- (208,104) plus the single compiled offset and the current playback
-- transform (offsets, scale, rotation, visibility). Frame, flip, scale,
-- rotation, visibility, and the palette operation apply together; a
-- no-op palette state draws unshaded so identity stays pixel-exact.
---@param scope SummaryRenderer.DrawScope
---@param status table<string, unknown>
local function drawPicture(scope, status)
  local graphics = scope.graphics
  local facts = assert(status.facts, "open summaries carry their facts")
  local manifest = scope.manifest
  local pictures = assert(manifest.pictures, "the summary family carries pictures")
  local anchor = SummaryRenderer.PICTURE_ANCHOR
  if facts.isEgg == true then
    local egg = pictures.EGG
    if egg == nil then
      return
    end
    local image = visualImage(scope, "egg")
    if image == nil then
      return
    end
    local width, height = 80, 80
    if type(image.getWidth) == "function" then
      width, height = image:getWidth(), image:getHeight()
    end
    graphics.draw(image, anchor.x - math.floor(width / 2), anchor.y - math.floor(height / 2))
    return
  end
  local selector = portraitSelector(facts)
  local portraits = scope.assets.portraits
  if portraits == nil then
    return
  end
  local picture = pictures[facts.pictureKey]
  assert(type(picture) == "table", "the picture selection exists in the summary family")
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

---@param facts table<string, unknown>
---@return string display name line
local function nameLine(facts)
  local identity = assert(facts.identity, "facts carry their identity")
  if facts.isEgg == true then
    return "EGG"
  end
  local skills = facts.skills
  local level = skills and skills.level or "?"
  return tostring(assert(identity.displayName, "identities carry a display name")) .. " Lv" .. tostring(level)
end

-- The INFO sub pane: identity, dex, trainer, item, status, and health
-- lines with the dynamic health/experience bars.
---@param scope SummaryRenderer.DrawScope
---@param windows { name: string, rect: table<string, integer>, palette: integer }[]
---@param facts table<string, unknown>
local function drawInfo(scope, windows, facts)
  requireWindows(windows, "info")
  local lines = {}
  lines[#lines + 1] = { text = nameLine(facts), align = "left" }
  local info = assert(facts.info, "facts carry their info section")
  lines[#lines + 1] = { text = "DEX " .. tostring(assert(info.dexText, "info carries dex text")), align = "left" }
  lines[#lines + 1] = { text = "ID " .. tostring(assert(info.otIdText, "info carries its id")), align = "right" }
  lines[#lines + 1] = { text = "ITEM " .. tostring(assert(info.heldItem, "info carries its item")), align = "left" }
  lines[#lines + 1] = { text = "BALL " .. tostring(assert(info.ball, "info carries its ball")), align = "left" }
  local indicators = assert(facts.indicators, "facts carry their indicators")
  lines[#lines + 1] =
    { text = "STATUS " .. tostring(assert(indicators.status, "indicators carry status")), align = "left" }
  if facts.isEgg ~= true then
    local skills = assert(facts.skills, "hatched mons carry skills")
    lines[#lines + 1] = {
      text = "HP " .. tostring(skills.currentHp) .. "/" .. tostring(skills.maxHp),
      align = "right",
      bar = { rule = "hp", pixels = skills.hpBar.length },
    }
    lines[#lines + 1] = {
      text = "EXP " .. tostring(assert(info.expToNext, "info carries exp to next")),
      align = "right",
      bar = { rule = "exp", pixels = info.expBar.length },
    }
  end
  for index, line in ipairs(lines) do
    local window = windows[((index - 1) % #windows) + 1]
    drawWindowLine(scope, window, line.text, line.align)
    if line.bar ~= nil then
      local rect = window.rect
      drawBar(scope, line.bar.rule, line.bar.pixels, rect.x + SummaryRenderer.TEXT_PAD_X, rect.y + rect.height - 10)
    end
  end
end

-- The TRAINER MEMO main pane: authored memo blocks at their source line
-- positions within the memo window.
---@param scope SummaryRenderer.DrawScope
---@param windows { name: string, rect: table<string, integer>, palette: integer }[]
---@param facts table<string, unknown>
local function drawMemo(scope, windows, facts)
  requireWindows(windows, "memo")
  local memo = assert(facts.memo, "facts carry their memo")
  local blocks = assert(memo.blocks, "memos carry their line blocks")
  local window = assert(windows[1], "the memo pane carries its window")
  for _, block in ipairs(blocks) do
    local parts = {}
    for _, run in ipairs(assert(block.runs, "memo blocks carry text runs")) do
      parts[#parts + 1] = assert(run.text, "memo runs carry text")
    end
    drawMemoLine(scope, window, assert(block.line, "memo blocks carry their line"), table.concat(parts, " "))
  end
end

-- The SKILLS main pane: level, health, battle stats, ability, and nature
-- shift lines.
---@param scope SummaryRenderer.DrawScope
---@param windows { name: string, rect: table<string, integer>, palette: integer }[]
---@param facts table<string, unknown>
local function drawSkills(scope, windows, facts)
  requireWindows(windows, "skills")
  local skills = assert(facts.skills, "hatched mons carry skills")
  local lines = {
    "LV " .. tostring(assert(skills.level, "skills carry level")),
    "HP " .. tostring(skills.currentHp) .. "/" .. tostring(skills.maxHp),
    "ATK " .. tostring(skills.attack),
    "DEF " .. tostring(skills.defense),
    "SPD " .. tostring(skills.speed),
    "SPATK " .. tostring(skills.specialAttack),
    "SPDEF " .. tostring(skills.specialDefense),
    "ABILITY " .. tostring(skills.abilityName),
  }
  local nature = skills.nature or {}
  lines[#lines + 1] = "NATURE " .. tostring(nature.up or "none") .. "/" .. tostring(nature.down or "none")
  for index, text in ipairs(lines) do
    local window = windows[((index - 1) % #windows) + 1]
    drawWindowLine(scope, window, text, "left")
  end
end

---@param move table<string, unknown>
---@return string move row text
local function moveRowText(move)
  if move.kind == "empty" then
    return "-"
  end
  return tostring(assert(move.name, "moves carry a name"))
    .. " PP "
    .. tostring(assert(move.pp, "moves carry pp"))
    .. "/"
    .. tostring(assert(move.ppMax, "moves carry max pp"))
end

-- The BATTLE MOVES sub pane: four logical move rows keep their positions
-- even when empty, the selected row opens its detail backing with
-- type/category/power/accuracy and clipped description, and the picker
-- preview holds the source preview location without becoming a fifth
-- owned move.
---@param scope SummaryRenderer.DrawScope
---@param status table<string, unknown>
---@param windows { name: string, rect: table<string, integer>, palette: integer }[]
---@param facts table<string, unknown>
local function drawMoves(scope, status, windows, facts)
  requireWindows(windows, "moves")
  local moves = assert(facts.moves, "facts carry their move rows")
  assert(#moves == SummaryRenderer.MOVE_ROWS, "move facts carry four logical rows")
  for row = 1, SummaryRenderer.MOVE_ROWS do
    local window = windows[((row - 1) % #windows) + 1]
    drawWindowLine(scope, window, moveRowText(assert(moves[row], "move rows stay addressable")), "left")
  end
  if status.mode == "move_pick" and status.moveSlot == SummaryRenderer.MOVE_ROWS then
    local window = windows[(SummaryRenderer.MOVE_ROWS % #windows) + 1]
    drawWindowLine(scope, window, "-", "left")
  end
  if status.phase ~= "move_detail" and status.phase ~= "move_reorder" and status.phase ~= "move_opening" then
    return
  end
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
  if selected == nil or selected.kind == "empty" then
    return
  end
  local detail = {
    tostring(selected.type) .. "/" .. tostring(selected.category),
    "PWR " .. tostring(selected.powerText) .. " ACC " .. tostring(selected.accuracyText),
    tostring(selected.description),
  }
  for index, text in ipairs(detail) do
    local window = windows[((SummaryRenderer.MOVE_ROWS + index - 1) % #windows) + 1]
    drawWindowLine(scope, window, text, "left")
  end
end

-- The PERFORMANCE main pane: one line per computed performance row. A
-- locked screen (no computed rows) keeps its locked backing and draws no
-- invented values.
---@param scope SummaryRenderer.DrawScope
---@param windows { name: string, rect: table<string, integer>, palette: integer }[]
---@param facts table<string, unknown>
local function drawPerformance(scope, windows, facts)
  requireWindows(windows, "performance")
  local rows = facts.performance
  if rows == nil then
    return
  end
  assert(type(rows) == "table", "performance rows arrive as records")
  for index, row in ipairs(rows) do
    local window = windows[((index - 1) % #windows) + 1]
    drawWindowLine(
      scope,
      window,
      tostring(assert(row.stat, "performance rows carry their stat"))
        .. " "
        .. tostring(assert(row.stars, "performance rows carry stars")),
      "left"
    )
  end
end

-- The RIBBONS sub pane: earned ribbon names with their compiled art when
-- the bundle realizes it. No earned ribbon draws no invented row.
---@param scope SummaryRenderer.DrawScope
---@param windows { name: string, rect: table<string, integer>, palette: integer }[]
---@param facts table<string, unknown>
local function drawRibbons(scope, windows, facts)
  requireWindows(windows, "ribbons")
  local ribbons = facts.ribbons or {}
  assert(type(ribbons) == "table", "ribbon records arrive as an array")
  for index, ribbon in ipairs(ribbons) do
    local window = windows[((index - 1) % #windows) + 1]
    local art = ribbon.art
    if type(art) == "table" and type(art.image) == "string" then
      local image = visualImage(scope, art.image)
      if image ~= nil then
        scope.graphics.draw(image, window.rect.x + SummaryRenderer.TEXT_PAD_X, window.rect.y)
      end
    end
    drawWindowLine(scope, window, tostring(assert(ribbon.name, "ribbons carry a name")), "left")
  end
end

-- Draws the five anchored leaf frames or the explicit crown frame: source
-- anchors plus one frame offset, applied once, first animation frame, so
-- repeated draws stay identical. Absent badge art skips its layer.
---@param scope SummaryRenderer.DrawScope
---@param facts table<string, unknown>
local function drawBadges(scope, facts)
  local partyManifest = scope.assets.partyManifest
  local imageFor = scope.assets.badgeImage
  if type(partyManifest) ~= "table" or type(imageFor) ~= "function" then
    return
  end
  local leavesRecord = partyManifest.shinyLeaves
  if type(leavesRecord) ~= "table" then
    return
  end
  local graphics = scope.graphics
  local indicators = assert(facts.indicators, "facts carry their indicators")
  local leaves = assert(indicators.leaves, "indicators carry leaf visibility")
  if indicators.crown == true then
    local crown = assert(leavesRecord.crown, "the party manifest carries the crown visual")
    local frame = assert(crown.frames[1], "crown visuals carry frames")
    local anchor = assert(leavesRecord.crownAnchor, "the party manifest carries the crown anchor")
    local offset = frame.offset or { x = 0, y = 0 }
    local image = imageFor(frame)
    if image ~= nil then
      graphics.draw(image, anchor.x + offset.x, anchor.y + offset.y)
    end
    return
  end
  local visual = assert(leavesRecord.leaves, "the party manifest carries the leaf visual")
  local frame = assert(visual.frames[1], "leaf visuals carry frames")
  local offset = frame.offset or { x = 0, y = 0 }
  local anchors = assert(leavesRecord.anchors, "the party manifest carries five anchors")
  local image = imageFor(frame)
  if image == nil then
    return
  end
  for index = 1, 5 do
    if leaves[index] == true then
      local anchor = assert(anchors[index], "the party manifest carries five anchors")
      graphics.draw(image, anchor.x + offset.x, anchor.y + offset.y)
    end
  end
end

-- Draws the current party icon strip through the borrowed provider when
-- it rides the bundle. Icon positions follow roster order in one row.
---@param scope SummaryRenderer.DrawScope
---@param facts table<string, unknown>
local function drawRosterIcons(scope, facts)
  local icons = scope.assets.icons
  if type(icons) ~= "table" or type(icons.image) ~= "function" or type(icons.quadFor) ~= "function" then
    return
  end
  local roster = assert(facts.roster, "facts carry the party roster")
  local graphics = scope.graphics
  for index, row in ipairs(roster) do
    local key = assert(row.iconKey, "roster rows carry their icon key")
    graphics.draw(icons:image(key), icons:quadFor(key), (index - 1) * 32, 160)
  end
end

---@param reason string
---@return string notice copy in the closed vocabulary
local function noticeText(reason)
  if reason == "hm" then
    return "An HM move can't be forgotten here."
  end
  if reason == "stale" then
    return "The party changed; choose again."
  end
  if reason == "empty" then
    return "No move in that row."
  end
  error("notices stay in the closed vocabulary: " .. tostring(reason), 0)
end

---@param scope SummaryRenderer.DrawScope
---@param status table<string, unknown>
---@param windows { name: string, rect: table<string, integer>, palette: integer }[]
local function drawNotice(scope, status, windows)
  local notice = status.notice
  if type(notice) ~= "table" then
    return
  end
  requireWindows(windows, "notice")
  local window = assert(windows[#windows], "notices draw through the last pane window")
  drawWindowLine(scope, window, noticeText(assert(notice.reason, "notices carry their reason")), "left")
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
    local windows = paneWindows(scope.manifest, pane)
    if pane == "main" then
      drawPicture(scope, status)
      if group == "info" then
        drawMemo(scope, windows, facts)
      elseif group == "skills" then
        drawSkills(scope, windows, facts)
      else
        drawPerformance(scope, windows, facts)
      end
    else
      if group == "info" then
        drawInfo(scope, windows, facts)
        drawBadges(scope, facts)
        drawRosterIcons(scope, facts)
      elseif group == "skills" then
        drawMoves(scope, status, windows, facts)
      else
        drawRibbons(scope, windows, facts)
      end
      drawNotice(scope, status, windows)
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
