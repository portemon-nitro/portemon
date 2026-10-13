-- Renders the Start Menu SUB selector through a resolved placement record.
-- The generated field-UI manifest carries the retail icon table, shared icon
-- atlas, animated source cursor, and SUB chrome. The renderer composes the
-- background, action art, and labels, then places the cursor's current source
-- frame over the focused action. Cursor frames retain their source cell
-- origin and NANR translation, while the fixed-tick state owner advances the
-- source durations and play mode. All other geometry comes from the manifest
-- as well; source coordinates are never repeated here. Drawing and input use
-- the same resolved placement record. Construction is failure-safe and
-- drawing restores every graphics state it touches.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local LogicalSurface = require("libs.ui.src.LogicalSurface")

---@class StartMenuRenderer
---@field _graphics love.graphics
---@field _text FieldTextRenderer the shared text collaborator (drawTextWithPalette/textWidth)
---@field _labelPalette { foreground: { r: number, g: number, b: number, a: number? }, shadow: { r: number, g: number, b: number, a: number? }, background: { r: number, g: number, b: number, a: number? } } the generated label roles from the manifest start menu record
---@field _images love.Image[] every acquired image, released exactly once
---@field _imageByAsset table<string, love.Image> acquired images by manifest asset id
---@field _quads table<string, love.Quad> quads by asset id plus rect
---@field _subImage love.Image?
---@field _subQuad love.Quad?
---@field _pokeImage love.Image?
---@field _pokeQuad love.Quad?
---@field _cursorImage love.Image
---@field _cursorQuads love.Quad[]
---@field menu StartMenuRenderer.Menu the resolved manifest surface geometry
local StartMenuRenderer = {}
StartMenuRenderer.__index = StartMenuRenderer

-- opts.cacheFs: version-scoped private cache holding the generated field-UI
-- class (Start Menu PNGs); opts.manifest: the already-validated generated
-- field-UI manifest the runtime loaded once (FieldRuntime.uiManifest);
-- opts.text: the shared text collaborator drawing caller-resolved labels;
-- opts.graphics: injectable LÖVE graphics namespace so tests can record draw
-- calls; LÖVE itself remains an allowed presentation-layer dependency (the
-- PNG bytes still enter through love.filesystem.newFileData).

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, text: unknown, graphics?: unknown }
---@return StartMenuRenderer
function StartMenuRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.read,
    "StartMenuRenderer requires a CacheFs-shaped object"
  )
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "StartMenuRenderer requires love.graphics")
  ---@cast graphics love.graphics
  local cacheFs = opts.cacheFs
  local manifest = opts.manifest
  assert(type(manifest) == "table", "StartMenuRenderer requires the runtime-validated field-UI manifest")
  local text = opts.text
  assert(
    text and type(text.drawTextWithPalette) == "function" and type(text.textWidth) == "function",
    "StartMenuRenderer requires the shared text collaborator"
  )
  -- The label colors are the generated start menu record, never the
  -- field font palette: the label windows resolve their retail slots
  -- through the SUB background palette bank, which the producer publishes
  -- as source-independent roles. The background role stays transparent so
  -- glyph background-class pixels reveal the already-rendered chrome.
  -- The generated field-UI class is a required renderer asset: the manifest
  -- names the SUB chrome and every icon visual atlas. The runtime boot
  -- already validated the full manifest; the renderer resolves what it
  -- draws.
  local startMenu = assert(manifest.startMenu, "the field-UI manifest must carry the start menu section")
  local labelPalette = assert(startMenu.labelPalette, "the field-UI manifest must carry the start menu label palette")
  assert(
    type(labelPalette.foreground) == "table"
      and type(labelPalette.shadow) == "table"
      and type(labelPalette.background) == "table",
    "the start menu label palette must carry its foreground, shadow, and background roles"
  )
  local interactive =
    assert(startMenu.interactive, "the field-UI manifest must carry the start menu interactive record")
  local iconTable = assert(startMenu.iconTable, "the field-UI manifest must carry the start menu icon table")
  local chrome = assert(startMenu.chrome and startMenu.chrome.sub, "the start menu must carry its sub chrome")
  local chromeAsset = assert(chrome.asset, "the start menu sub chrome must name an asset")

  local self = setmetatable({
    _graphics = graphics,
    _text = text,
    _labelPalette = labelPalette,
    _images = {},
    _imageByAsset = {},
    _quads = {},
    _subImage = nil,
    _subQuad = nil,
    _pokeImage = nil,
    _pokeQuad = nil,
    _cursorImage = nil,
    _cursorQuads = {},
    menu = {
      interactive = interactive,
      iconTable = iconTable,
      cursor = assert(startMenu.cursor, "the field-UI manifest must carry the cursor animation"),
      runningShoes = assert(startMenu.runningShoes, "the field-UI manifest must carry the Running Shoes toggle"),
    },
  }, StartMenuRenderer)

  local ok, err = pcall(function()
    self:_acquire(cacheFs, manifest, startMenu, chromeAsset)
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
end

-- Acquires the SUB chrome, every icon visual atlas, and the optional
-- poke-icon image, then builds every visual quad. Any failure releases
-- everything acquired so far before the constructor rethrows.
---@param cacheFs CacheFs
---@param manifest table<string, unknown>
---@param startMenu table<string, unknown>
---@param chromeAsset string
function StartMenuRenderer:_acquire(cacheFs, manifest, startMenu, chromeAsset)
  local graphics = assert(self._graphics)
  local function acquire(assetId, code, what)
    if self._imageByAsset[assetId] ~= nil then
      return assert(self._imageByAsset[assetId])
    end
    local entry = assert(manifest.assets[assetId], "the field-UI manifest must carry " .. what)
    local path = assert(entry.image, what .. " must name an image path")
    local data = cacheFs:read(path)
    if not data then
      Errors.raise(code, what .. " missing at " .. path, { path = path })
    end
    data = assert(data)
    local image = graphics.newImage(love.filesystem.newFileData(data, path))
    image:setFilter("nearest", "nearest")
    self._images[#self._images + 1] = image
    self._imageByAsset[assetId] = image
    return image
  end
  local subImage = acquire(chromeAsset, FieldErrors.FIELD_UI_START_MENU_CHROME_MISSING, "the start menu sub chrome")
  self._subImage = subImage
  self._subQuad =
    graphics.newQuad(0, 0, subImage:getWidth(), subImage:getHeight(), subImage:getWidth(), subImage:getHeight())
  local function quadFor(assetId, rect)
    local key = assetId .. "\0" .. rect.x .. "," .. rect.y .. "," .. rect.width .. "," .. rect.height
    local quad = self._quads[key]
    if quad == nil then
      local image = acquire(assetId, FieldErrors.FIELD_UI_START_MENU_ICONS_MISSING, "the start menu icon atlas")
      quad = graphics.newQuad(rect.x, rect.y, rect.width, rect.height, image:getWidth(), image:getHeight())
      self._quads[key] = quad
    end
    return quad
  end
  for _, row in ipairs(assert(startMenu.iconTable, "the start menu must carry its icon table")) do
    if row.art == "sprite" then
      local visual = assert(row.visual, "a sprite icon row must carry its composed visual")
      for _, state in ipairs({ visual.normal, visual.selected }) do
        quadFor(assert(state.asset, "an icon visual must name its atlas"), assert(state.rect))
      end
      if row.variants ~= nil and row.variants.female ~= nil then
        for _, state in ipairs({ row.variants.female.normal, row.variants.female.selected }) do
          quadFor(assert(state.asset, "an icon visual must name its atlas"), assert(state.rect))
        end
      end
    end
  end
  local shoes = assert(startMenu.runningShoes, "the start menu must carry its Running Shoes toggle")
  for _, part in ipairs({ shoes.button, shoes.indicator }) do
    for _, state in ipairs({ part.off, part.on }) do
      quadFor(assert(state.asset, "a Running Shoes visual must name its atlas"), assert(state.rect))
    end
  end
  self._cursorImage = acquire(
    FieldUiAssetCache.ASSET.START_MENU_CURSOR,
    FieldErrors.FIELD_UI_START_MENU_CURSOR_MISSING,
    "the start menu cursor"
  )
  for index, frame in ipairs(assert(self.menu.cursor.frames, "the cursor must carry animation frames")) do
    self._cursorQuads[index] = graphics.newQuad(
      frame.x,
      frame.y,
      frame.width,
      frame.height,
      self._cursorImage:getWidth(),
      self._cursorImage:getHeight()
    )
  end
  if startMenu.pokeIcons ~= nil and startMenu.pokeIcons.asset ~= nil then
    local pokeAsset = startMenu.pokeIcons.asset
    if manifest.assets[pokeAsset] ~= nil then
      self._pokeImage =
        acquire(pokeAsset, FieldErrors.FIELD_UI_START_MENU_POKE_ICONS_MISSING, "the start menu poke icons")
      local pokeImage = assert(self._pokeImage)
      self._pokeQuad =
        graphics.newQuad(0, 0, pokeImage:getWidth(), pokeImage:getHeight(), pokeImage:getWidth(), pokeImage:getHeight())
    end
  end
end

---@param cursor { position: integer, frameIndex: integer }?
function StartMenuRenderer:_drawCursor(cursor)
  if cursor == nil then
    return
  end
  local frame = assert(self.menu.cursor.frames[cursor.frameIndex], "the cursor frame is outside its sequence")
  local anchor = assert(
    self.menu.interactive.positions[cursor.position] and self.menu.interactive.positions[cursor.position].anchor,
    "the cursor position has a generated action anchor"
  )
  assert(type(frame.offset) == "table", "the source cursor frame must carry its position offset")
  assert(self._cursorImage ~= nil, "the cursor image is acquired with the other Start Menu art")
  self._graphics.draw(
    self._cursorImage,
    assert(self._cursorQuads[cursor.frameIndex]),
    anchor.x + frame.offset.x,
    anchor.y + frame.offset.y
  )
end

---@param assetId string
---@param rect FieldDialogueTheme.Rect
---@return love.Quad
function StartMenuRenderer:_quadFor(assetId, rect)
  local key = assetId .. "\0" .. rect.x .. "," .. rect.y .. "," .. rect.width .. "," .. rect.height
  return assert(self._quads[key], "a start menu icon visual must have a built quad")
end

-- One presented action's icon draw: the composed visual for the action's
-- source position at the position's source anchor plus the visual's
-- source-relative offset, through the gender-conditional variant when the
-- row carries one and the presentation selects the female art. The selected
-- action draws its selected visual; every other action draws its normal
-- visual. Text-only rows draw no shared icon art.
---@param action table<string, unknown>
---@param selectedPosition integer?
---@param gender string?
function StartMenuRenderer:_drawActionIcon(action, selectedPosition, gender)
  local lg = assert(self._graphics)
  local menu = self.menu
  local iconTable = assert(menu.iconTable, "the icon presentation requires the icon contract")
  local positions = assert(menu.interactive and menu.interactive.positions, "the icon presentation requires positions")
  assert(type(action.icon) == "number" and action.icon % 1 == 0, "a presented action needs an icon index")
  assert(type(action.position) == "number" and action.position % 1 == 0, "a presented action needs its position")
  local row = assert(iconTable[action.icon + 1], "icon " .. tostring(action.icon) .. " is outside the icon table")
  if row.art == "text" then
    return
  end
  local record =
    assert(positions[action.position], "position " .. tostring(action.position) .. " is outside the position set")
  if row.art == "poke_icon" then
    if self._pokeImage ~= nil then
      lg.draw(self._pokeImage, assert(self._pokeQuad), record.anchor.x, record.anchor.y)
    end
    return
  end
  local visual = assert(row.visual, "a sprite icon row must carry its composed visual")
  if gender == "female" and row.variants ~= nil and row.variants.female ~= nil then
    visual = row.variants.female
  end
  local state = action.position == selectedPosition and visual.selected or visual.normal
  local asset = assert(state.asset, "an icon visual must name its atlas")
  local rect = assert(state.rect, "an icon visual must carry its atlas rect")
  local offset = assert(state.offset, "an icon visual must carry its frame offset")
  lg.draw(
    assert(self._imageByAsset[asset]),
    self:_quadFor(asset, rect),
    record.anchor.x + offset.x,
    record.anchor.y + offset.y
  )
end

-- The Running Shoes toggle: the button body then the lock indicator, each
-- at its generated anchor plus the visual's source-relative offset, in the
-- off or on state of the live auto-run lock.
---@param locked boolean
function StartMenuRenderer:_drawRunningShoes(locked)
  local lg = assert(self._graphics)
  local shoes = assert(self.menu.runningShoes, "the Running Shoes presentation requires its record")
  for _, part in ipairs({ shoes.button, shoes.indicator }) do
    local state = locked and part.on or part.off
    lg.draw(
      assert(self._imageByAsset[state.asset]),
      self:_quadFor(state.asset, state.rect),
      part.anchor.x + state.offset.x,
      part.anchor.y + state.offset.y
    )
  end
end

---@param hitRect FieldDialogueTheme.Rect
function StartMenuRenderer:_drawRunningShoesFocus(hitRect)
  local lg = assert(self._graphics)
  lg.setColor(0, 0, 0, 1)
  lg.rectangle("line", hitRect.x - 1, hitRect.y - 1, hitRect.width + 2, hitRect.height + 2)
  lg.setColor(1, 1, 1, 1)
  lg.rectangle("line", hitRect.x, hitRect.y, hitRect.width, hitRect.height)
end

-- one presented action's resolved label in the action's own source label
-- window: windows are keyed by source position, never by presentation
-- order, so a sparse action list still labels the right row. Labels arrive
-- resolved (the dynamic player name is caller-resolved; static labels come
-- from the pinned source label bank); an action without a resolved label
-- draws its icon alone. Every label draws through the palette-driven text
-- path with the retail label roles, centered in its window as before.
---@param action table<string, unknown>
function StartMenuRenderer:_drawActionLabel(action)
  if action.label == nil then
    return
  end
  assert(type(action.label) == "string", "a presented label must be the caller-resolved string")
  local text = assert(self._text, "the icon presentation requires the shared text collaborator")
  local positions =
    assert(self.menu.interactive and self.menu.interactive.positions, "the icon presentation requires positions")
  assert(type(action.position) == "number" and action.position % 1 == 0, "a presented action needs its position")
  local window = assert(
    positions[action.position] and positions[action.position].labelWindow,
    "label window for position " .. tostring(action.position) .. " is outside the generated window set"
  )
  local width = text:textWidth(action.label)
  text:drawTextWithPalette(
    action.label,
    window.x + (window.width - width) / 2,
    window.y,
    assert(self._labelPalette, "the icon presentation requires the resolved label palette")
  )
end

-- Draws the canonical menu surface through the placement record: the SUB
-- chrome at the canonical origin, then per-action icons and labels keyed by
-- the same generated position records pointer input and navigation consume,
-- all inside the placement's logical coordinate space through the shared
-- surface scope, so the record's frame is exactly where the surface lands
-- and hostToLogical's inverse transform maps hit points back onto the same
-- canonical coordinates.
-- No-op (and no state touched) when this renderer has no images. Restores
-- canvas, shader, scissor, blend, depth, wireframe, cull, and color
-- afterwards so the HUD and host overlays draw normally.

---@param presentation { selectedPosition: integer, trainerGender?: string, actions?: table[], runningShoes?: { locked: boolean, focused: boolean }, cursor?: { position: integer, frameIndex: integer } }?
---@param placement LayoutGeometry.Placement the resolved content placement (frame, origin, scale, clip)
function StartMenuRenderer:draw(presentation, placement)
  if not presentation or not self._subImage then
    return
  end
  assert(
    placement ~= nil and type(placement.frame) == "table" and type(placement.scale) == "number",
    "the start menu surface requires the placement record"
  )
  local lg = assert(self._graphics)
  lg.push("all")
  LogicalSurface.draw(lg, placement, function()
    self:_drawSurface(presentation)
  end)
  lg.pop()
end

-- The source draws in canonical coordinates: validation first (a rejected
-- draw draws nothing), then the SUB chrome at the canonical origin plus
-- per-action icons and labels. The manifest rects are canonical, so
-- nothing is scaled twice.
---@param presentation { selectedPosition: integer, trainerGender?: string, actions?: table[], runningShoes?: { locked: boolean, focused: boolean }, cursor?: { position: integer, frameIndex: integer } }
function StartMenuRenderer:_drawSurface(presentation)
  local lg = assert(self._graphics)
  lg.setColor(1, 1, 1, 1)
  assert(
    type(presentation.selectedPosition) == "number" and presentation.selectedPosition % 1 == 0,
    "the start menu presentation requires the selected source position"
  )
  local positions = assert(
    self.menu.interactive and self.menu.interactive.positions,
    "the start menu presentation requires the generated positions"
  )
  assert(
    positions[presentation.selectedPosition] ~= nil,
    "selected position " .. tostring(presentation.selectedPosition) .. " is outside the generated position set"
  )
  local actions = presentation.actions
  if actions ~= nil then
    assert(type(actions) == "table", "the start menu presentation actions must be a table")
  end
  -- Presentation-dependent faults (unknown positions, unknown icons) are
  -- rejected before anything reaches the graphics namespace: a rejected
  -- draw draws nothing.
  if actions ~= nil then
    local iconTable = assert(self.menu.iconTable, "the start menu presentation requires the icon table")
    for _, action in ipairs(actions) do
      assert(
        type(action.position) == "number" and positions[action.position] ~= nil,
        "action position " .. tostring(action.position) .. " is outside the generated position set"
      )
      assert(
        type(action.icon) == "number" and iconTable[action.icon + 1] ~= nil,
        "action icon " .. tostring(action.icon) .. " is outside the icon table"
      )
    end
  end
  local shoes = presentation.runningShoes
  if shoes ~= nil then
    assert(
      type(shoes.locked) == "boolean" and type(shoes.focused) == "boolean",
      "Running Shoes presentation needs lock and focus"
    )
    assert(
      self.menu.runningShoes.hitRect ~= nil,
      "the Running Shoes focus outline requires its generated hit rectangle"
    )
  end
  local cursor = presentation.cursor
  if cursor ~= nil then
    assert(
      type(cursor.position) == "number" and positions[cursor.position] ~= nil,
      "the cursor position is outside the generated action positions"
    )
    assert(
      type(cursor.frameIndex) == "number"
        and cursor.frameIndex % 1 == 0
        and self.menu.cursor.frames[cursor.frameIndex] ~= nil,
      "the cursor frame index is outside its sequence"
    )
  end
  ---@type integer?
  local selectedPosition = presentation.selectedPosition
  if shoes ~= nil and shoes.focused then
    selectedPosition = nil
  end
  lg.draw(assert(self._subImage), assert(self._subQuad), 0, 0)
  if actions ~= nil then
    for _, action in ipairs(actions) do
      self:_drawActionIcon(action, selectedPosition, presentation.trainerGender)
      self:_drawActionLabel(action)
    end
  end
  if shoes ~= nil then
    self:_drawRunningShoes(shoes.locked)
    if shoes.focused then
      self:_drawRunningShoesFocus(self.menu.runningShoes.hitRect)
    end
  end
  if cursor ~= nil then
    self:_drawCursor(cursor)
  end
end

function StartMenuRenderer:release()
  for _, image in ipairs(self._images) do
    if image.release then
      image:release()
    end
  end
  self._images = {}
  self._imageByAsset = {}
  self._quads = {}
  self._subImage, self._subQuad, self._pokeImage, self._pokeQuad = nil, nil, nil, nil
  self._cursorImage = nil
  self._cursorQuads = {}
end

-- The resolved manifest surface: the SUB chrome asset, the icon table with
-- composed visuals, and the interactive position records. Entry art lives in
-- the shared icon atlas; the manifest carries no per-action background
-- rects.

---@class StartMenuRenderer.Position
---@field anchor { x: integer, y: integer }
---@field labelWindow FieldDialogueTheme.Rect
---@field hitRect FieldDialogueTheme.Rect
---@field navigation { up: integer[], down: integer[], left: integer[], right: integer[] }

---@class StartMenuRenderer.Interactive
---@field cancelHitRect FieldDialogueTheme.Rect
---@field positions table<integer, StartMenuRenderer.Position>

---@class StartMenuRenderer.Menu
---@field interactive StartMenuRenderer.Interactive the generated interactive record (cancel bound plus positions 0..6)
---@field iconTable table<integer, table<string, unknown>>
---@field cursor { frames: { x: integer, y: integer, width: integer, height: integer, offset: { x: integer, y: integer }, duration: integer }[] }
---@field runningShoes table<string, unknown> the generated Running Shoes toggle record (button and indicator visuals)

return StartMenuRenderer
