-- Field-bag renderer: draws one controller presentation snapshot through
-- the resolved layout. The hero pane shows the gender-selected source
-- backdrop, the borrowed 3D hero model clipped to the hero placement, the
-- description frame, and the state-specific contextual text in the
-- source font; the interactive pane composites the semantic state background,
-- the active pocket strip with its persistent selected-pocket treatment,
-- six-cell item grid with icons, names, quantities, and
-- registration markers, source focus visuals at their generated targets, the
-- derived page, and the generated cancel label. Empty cells paint no icons, so the source cell art
-- stays authentic. The constrained description
-- overlay fills the canonical fallback frame with the selected icon, name,
-- description, and back hint; the same fallback surface carries the
-- contextual text when no hero pane exists. Action labels and move/toss
-- prompts come from the generated semantic text record, never from internal
-- action ids. The renderer owns no selection, layout, or
-- icon-selection policy and never queries the live bag service: quads
-- arrive through the icon provider, glyphs through the shared text
-- renderer. Draw advances no simulation state and restores every graphics
-- state it touches.

local LogicalSurface = require("libs.ui.src.LogicalSurface")
local MoveIconCache = require("libs.assets.src.MoveIconCache")
local ImageSampling = require("libs.nds.src.love.ImageSampling")
local NativeDisplay = require("libs.ui.src.NativeDisplay")
local BagSave = require("libs.hgss.src.save.BagSave")
local FieldTextWindowRenderer = require("libs.hgss.src.ui.FieldTextWindowRenderer")
local YesNoPromptRenderer = require("libs.hgss.src.ui.YesNoPromptRenderer")

---@class BagPathEntry
---@field path string the generated image path enrolled with the shared owner
---@field width integer the generated visual width draws place
---@field height integer the generated visual height draws place
---@field offset table<string, integer>? the generated visual offset draws place

---@class BagDemandVisual
---@field handle table<string, unknown> the installed lease handle draws resolve (image plus palette and kind)
---@field width integer the generated visual width draws place
---@field height integer the generated visual height draws place
---@field offset table<string, integer>? the generated visual offset draws place

---@class BagRenderer
---@field _graphics love.graphics
---@field _text table<string, unknown> the shared glyph atlas/text drawing collaborator
---@field _heroRenderer table<string, unknown> the borrowed hero model renderer owned by field presentation resources
---@field _manifest table<string, unknown>
---@field _images table<string, love.Image>
---@field _visuals table<string, BagDemandVisual>
---@field _promptRenderer table<string, unknown>? the owned modal prompt renderer for toss confirmation
---@field _window table<string, unknown>? the borrowed shared frame-strip atlas owner, never released here
---@field _frameIndex integer? the borrowed player-selected frame style, never owned here
---@field _pool table<string, unknown> the borrowed shared image owner; every bag visual resolves through its demand leases
---@field _paths table<string, BagPathEntry> the immutable semantic-key to generated-path map built at construction
---@field _readySignature string? the semantic demand key of the installed visual leases
---@field _readyLeases table<integer, table<string, unknown>> installed demand leases returned on swap or release
---@field _pending BagDemandPending? the enrolled demand resolving or draining its soft interest
local BagRenderer = {}
BagRenderer.__index = BagRenderer

local LINE_HEIGHT = 16
local WHITE = { 1, 1, 1, 1 }
local FALLBACK_COLORS = {
  fill = { 0.12, 0.12, 0.18, 1 },
  border = { 0.75, 0.75, 0.85, 1 },
}

---@param graphics love.graphics
---@param color number[]
local function setColor(graphics, color)
  graphics.setColor(color[1], color[2], color[3], color[4])
end

-- Source text forms carry import-time control tags (pocket names); plain
-- glyph output strips them so only readable text reaches the panes.
---@param value string
---@return string
local function plainText(value)
  return (value:gsub("{[^}]*}", ""))
end

-- Selects the compact lower-only contextual string: the ordinary selected
-- description renders only while browsing with the item grid focused.
-- Post-selection state messages own the lower message window below, never
-- this fallback, so constrained layouts draw them exactly once.
local function compactContextualText(presentation)
  if presentation.state ~= "browsing" then
    return nil
  end
  if presentation.focus ~= "items" then
    return nil
  end
  local selected = presentation.selected
  if selected == nil then
    return nil
  end
  assert(type(selected.description) == "string", "selected slots carry a description")
  return selected.description
end

-- Draws one realized static visual at its placement point plus its generated
-- offset, which already positions the image relative to the anchor the
-- producer composed it against. Placement points are sprite anchors (tab
-- rect centers) or pane origins, never image centers.
---@param graphics love.graphics
---@param visual table<string, unknown>
---@param x number
---@param y number
local function drawVisual(graphics, visual, x, y)
  local handle = assert(visual.handle, "static visuals carry their resolved lease handle")
  local offset = visual.offset or { x = 0, y = 0 }
  setColor(graphics, WHITE)
  -- Lease handles resolve through the shared exact sampling rule, so
  -- indexed sources draw through their palette exactly like straight RGBA.
  ImageSampling.draw(graphics, handle, nil, x + offset.x, y + offset.y)
end

-- Resolves one zero-based field-font palette slot to byte-valued RGB, exactly
-- like the Oak confirmation path: ROM palettes are byte-valued while
-- normalized fixture palettes may already be unit-scaled.
---@param fontDef table<string, unknown>
---@param slot integer
---@return { r: number, g: number, b: number }
local function fontSlot(fontDef, slot)
  local palette = assert(fontDef.palette, "bag text needs the shared field font palette")
  local color = assert(palette[slot + 1], "bag text needs field font palette slot " .. slot)
  local r, g, b =
    assert(tonumber(color.r or color[1])), assert(tonumber(color.g or color[2])), assert(tonumber(color.b or color[3]))
  if r > 1 or g > 1 or b > 1 then
    r, g, b = r / 255, g / 255, b / 255
  end
  return { r = r * 255, g = g * 255, b = b * 255 }
end

-- Builds one transparent-background text palette from explicit field-font
-- slots: the glyph background stays transparent so generated pixels remain
-- visible beneath glyph masks.
---@param fontDef table<string, unknown>
---@param foregroundSlot integer
---@param shadowSlot integer
---@param backgroundSlot integer
---@return table<string, unknown>
local function paletteRecord(fontDef, foregroundSlot, shadowSlot, backgroundSlot)
  local background = fontSlot(fontDef, backgroundSlot)
  return {
    foreground = fontSlot(fontDef, foregroundSlot),
    shadow = fontSlot(fontDef, shadowSlot),
    background = { r = background.r, g = background.g, b = background.b, a = 0 },
  }
end

-- Builds the immutable semantic-key to generated-path map at construction:
-- every pocket/count/origin background variant, strip, focus visual,
-- control face, and marker the demand can resolve, validated exactly once
-- here. Construction reads no image
-- bytes and binds no GPU object; state visuals resolve through
-- prepare(status) demand leases.
---@param manifest table<string, unknown>
---@param moveIcons table<string, unknown>?
---@return table<string, BagPathEntry>
local function buildPathMap(manifest, moveIcons)
  local hero = assert(manifest.hero, "the bag manifest must carry its hero pane")
  local interactive = assert(manifest.interactive, "the bag manifest must carry its interactive pane")
  local quantity = assert(interactive.overlays.quantity, "the bag manifest carries its quantity overlay")
  local sale = assert(interactive.sale, "the bag manifest carries its sale presentation")
  assert(
    sale.confirm.visual.image == quantity.confirm.visual.image,
    "sale and quantity confirmation share their source confirm visual"
  )
  assert(
    sale.cancel.visual.image == quantity.cancel.visual.image,
    "sale and quantity cancellation share their source cancel visual"
  )
  local paths = {} ---@type table<string, BagPathEntry>
  local function add(key, visual, forcedWidth, forcedHeight)
    assert(type(visual) == "table", key .. " must be a semantic visual")
    local path = assert(visual.image, key .. " carries an image path")
    assert(type(path) == "string" and path ~= "", key .. " carries an image path")
    paths[key] = {
      path = path,
      width = forcedWidth or assert(visual.width, key .. " carries its image width"),
      height = forcedHeight or assert(visual.height, key .. " carries its image height"),
      offset = visual.offset,
    }
  end
  add("heroMale", hero.background.male)
  add("heroFemale", hero.background.female)
  add("descriptionFrame", {
    image = hero.description.frame.image,
    width = NativeDisplay.WIDTH,
    height = NativeDisplay.HEIGHT,
  })
  local moveSummary = hero.moveSummary
  if moveSummary ~= nil then
    add("moveSummaryBackground", moveSummary.background)
    local icons = assert(moveIcons, "the move icons resolve before the machine summary binds")
    for key, visual in pairs(assert(icons.types, "the move icons carry their types")) do
      add("moveType:" .. key, visual)
    end
    for key, visual in pairs(assert(icons.categories, "the move icons carry their categories")) do
      add("moveCategory:" .. key, visual)
    end
  end
  -- Seven realized count variants per pocket for browse, action, and
  -- quantity, plus seven count/origin variants per pocket for move: bind
  -- each variant under its count (and origin) so the state selection can
  -- resolve it. Anything else fails at the lookup below instead of
  -- borrowing another shape. Toss confirmation owns no background of its
  -- own; it retains its action/quantity base.
  do
    local browse = assert(interactive.backgrounds.browse, "the bag manifest carries its browse backgrounds")
    for _, pocket in ipairs(BagSave.POCKET_ORDER) do
      local published = assert(browse[pocket], "browse carries " .. pocket)
      for count = 0, 6 do
        add(
          "background:browse:" .. pocket .. ":" .. count,
          assert(published[count + 1], "browse carries " .. pocket .. " count " .. count)
        )
      end
    end
  end
  for _, state in ipairs({ "action", "quantity" }) do
    local pockets = assert(interactive.backgrounds[state], "the bag manifest carries its " .. state .. " backgrounds")
    for _, pocket in ipairs(BagSave.POCKET_ORDER) do
      local published = assert(pockets[pocket], state .. " carries " .. pocket)
      for count = 0, 6 do
        add(
          "background:" .. state .. ":" .. pocket .. ":" .. count,
          assert(published[count], state .. " carries " .. pocket .. " count " .. count)
        )
      end
    end
  end
  do
    local move = assert(interactive.backgrounds.move, "the bag manifest carries its move backgrounds")
    for _, pocket in ipairs(BagSave.POCKET_ORDER) do
      local published = assert(move[pocket], "move carries " .. pocket)
      for count = 0, 6 do
        local perCount = assert(published[count], "move carries " .. pocket .. " count " .. count)
        for _, origin in ipairs({ "none", "0", "1", "2", "3", "4", "5" }) do
          add(
            "background:move:" .. pocket .. ":" .. count .. ":" .. origin,
            assert(perCount[origin], "move carries " .. pocket .. " count " .. count .. " origin " .. origin)
          )
        end
      end
    end
  end
  local feedback = assert(interactive.feedback, "the bag manifest carries its activation feedback")
  add("feedback:action:normal", assert(feedback.actionFace.normal, "feedback carries its action face"))
  add("feedback:action:selected", assert(feedback.actionFace.selected, "feedback carries its action flash"))
  add("feedback:cancel:normal", assert(feedback.cancelFace.normal, "feedback carries its cancel face"))
  add("feedback:cancel:selected", assert(feedback.cancelFace.selected, "feedback carries its cancel flash"))
  add(
    "feedback:quantityConfirm:normal",
    assert(feedback.quantityConfirm.normal, "feedback carries its quantity confirm")
  )
  add(
    "feedback:quantityConfirm:selected",
    assert(feedback.quantityConfirm.selected, "feedback carries its quantity flash")
  )
  add(
    "feedback:quantityCancel:normal",
    assert(feedback.quantityCancel.normal, "feedback carries its quantity cancel face")
  )
  add(
    "feedback:quantityCancel:selected",
    assert(feedback.quantityCancel.selected, "feedback carries its quantity cancel flash")
  )
  local moveCursor = assert(interactive.moveCursor, "the bag manifest carries its move target cursor")
  add("moveCursor:original", assert(moveCursor.original, "the move cursor carries its original target"))
  add("moveCursor:candidate", assert(moveCursor.candidate, "the move cursor carries its candidate target"))
  assert(interactive.overlays.selectedItem ~= nil, "the bag manifest carries its retained selected-item panel")
  assert(interactive.overlays.messages ~= nil, "the bag manifest carries its lower-message geometry")
  -- One realized strip per active pocket, carrying the persistent
  -- selected-pocket treatment; the transient tab focus stays a separate
  -- visual drawn after the strip.
  local strips = assert(interactive.pocketTabs.strips, "the bag manifest carries its pocket strips")
  for _, pocket in ipairs(BagSave.POCKET_ORDER) do
    add("strip:" .. pocket, assert(strips[pocket], "the bag manifest carries the " .. pocket .. " strip"))
  end
  local focus = assert(interactive.focus, "the bag manifest must carry its focus visuals")
  add("focus:tabs", assert(focus.tabs.visual, "the bag manifest carries its tab focus"))
  add("focus:items", assert(focus.items.visual, "the bag manifest carries its item focus"))
  add("focus:cancel", assert(focus.cancel.visual, "the bag manifest carries its cancel focus"))
  add("focus:actions", assert(focus.actions.visual, "the bag manifest carries its action focus"))
  local selectionEntry = assert(interactive.selectionEntry, "the bag manifest carries its selection-entry sequence")
  local entryFrames = assert(selectionEntry.frames, "the selection entry carries its realized frames")
  assert(type(entryFrames) == "table" and #entryFrames >= 1, "the selection entry carries its frames")
  for index, frame in ipairs(entryFrames) do
    add("selectionEntry:" .. index, frame)
  end
  local actionMenu = assert(interactive.overlays.actionMenu, "the bag manifest carries its action menu")
  add("actionFace", assert(actionMenu.face, "the bag manifest carries its action face"))
  local quantityVisuals = assert(quantity.visuals, "the quantity overlay carries its controls")
  add("quantityIncrement", assert(quantityVisuals.increment.normal, "the quantity carries increment visuals"))
  add(
    "quantityIncrementPressed",
    assert(quantityVisuals.increment.pressed, "the quantity carries pressed increment visuals")
  )
  add("quantityDecrement", assert(quantityVisuals.decrement.normal, "the quantity carries decrement visuals"))
  add(
    "quantityDecrementPressed",
    assert(quantityVisuals.decrement.pressed, "the quantity carries pressed decrement visuals")
  )
  add("quantityConfirm", assert(quantity.confirm.visual, "the quantity carries its confirm visual"))
  add("quantityCancel", assert(quantity.cancel.visual, "the quantity carries its cancel visual"))
  add("saleQuantityBackground", sale.quantityBackground)
  paths.saleConfirm = assert(paths.quantityConfirm, "the bag presentation names its quantity controls")
  paths.saleCancel = assert(paths.quantityCancel, "the bag presentation names its quantity controls")
  local registration =
    assert(interactive.itemSlots.registration, "the bag manifest must carry its registration markers")
  local slot1 = assert(registration.slot1, "the bag manifest must carry its first registration marker")
  local slot2 = assert(registration.slot2, "the bag manifest must carry its second registration marker")
  assert(
    type(slot1.image) == "string" and slot1.image ~= "",
    "the first registration marker carries its generated image"
  )
  assert(
    type(slot2.image) == "string" and slot2.image ~= "",
    "the second registration marker carries its generated image"
  )
  assert(type(registration.offset) == "table", "the registration markers carry their generated offset")
  add("registrationSlot1", slot1)
  add("registrationSlot2", slot2)
  return paths
end

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, promptManifest: table<string, unknown>, text: table<string, unknown>, heroRenderer: table<string, unknown>, graphics?: love.graphics, window?: table<string, unknown>, frameIndex?: integer, imagePool?: table<string, unknown> }
---@return BagRenderer
function BagRenderer.new(opts)
  assert(type(opts) == "table", "bag renderer options must be a table")
  local cacheFs = assert(opts.cacheFs, "BagRenderer requires a CacheFs")
  local manifest = assert(opts.manifest, "BagRenderer requires the validated bag manifest")
  assert(
    opts.window == nil or type(opts.window.drawWindow) == "function",
    "the borrowed window renderer draws framed windows"
  )
  local promptManifest = assert(opts.promptManifest, "BagRenderer requires the validated field-UI prompt manifest")
  local text = assert(opts.text, "BagRenderer requires the shared text renderer")
  local heroRenderer = assert(opts.heroRenderer, "BagRenderer requires its borrowed hero model renderer")
  assert(type(heroRenderer.draw) == "function", "the borrowed hero model renderer draws the hero model")
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.push and graphics.setScissor, "BagRenderer requires love.graphics")
  -- Every bag visual resolves through shared demand leases: construction
  -- builds only the immutable semantic-key to generated-path map (no image
  -- bytes, no GPU object) plus the small fixed prompt chrome, while state
  -- visuals resolve through prepare(status).
  local pool = assert(opts.imagePool, "BagRenderer borrows its shared image owner")
  local hero = assert(manifest.hero, "the bag manifest must carry its hero pane")
  local moveIcons = nil
  if hero.moveSummary ~= nil then
    moveIcons = MoveIconCache.loadManifest(cacheFs)
  end
  local self = setmetatable({
    _graphics = graphics,
    _text = text,
    _manifest = manifest,
    _heroRenderer = heroRenderer,
    _window = opts.window,
    _frameIndex = opts.frameIndex,
    _images = {},
    _visuals = {},
    _pool = pool,
    _paths = buildPathMap(manifest, moveIcons),
    _readySignature = nil,
    _readyLeases = {},
    _pending = nil,
  }, BagRenderer)
  local ok, err = pcall(function()
    -- The modal prompt chrome binds at construction; every bag visual
    -- resolves through prepare(status) demand leases.
    self._promptRenderer = YesNoPromptRenderer.new({
      cacheFs = cacheFs,
      manifest = promptManifest,
      graphics = graphics,
    })
  end)
  if not ok then
    self:release()
    error(err, 0)
  end
  return self
end

---@param text string
---@param x number
---@param y number
---@param maxLines integer?
function BagRenderer:_drawLines(text, x, y, maxLines)
  local drawn = 0
  for line in (plainText(text) .. "\n"):gmatch("([^\n]*)\n") do
    if maxLines ~= nil and drawn >= maxLines then
      break
    end
    self._text:drawText(line, x, y + drawn * LINE_HEIGHT)
    drawn = drawn + 1
  end
end

---@param text string
---@param x number
---@param y number
---@param palette { foreground: { r: number, g: number, b: number }, shadow: { r: number, g: number, b: number }, background: { r: number, g: number, b: number, a: number } }
---@param maxLines integer?
function BagRenderer:_drawPaletteLines(text, x, y, palette, maxLines)
  local drawn = 0
  for line in (plainText(text) .. "\n"):gmatch("([^\n]*)\n") do
    if maxLines ~= nil and drawn >= maxLines then
      break
    end
    self._text:drawTextWithPalette(line, x, y + drawn * LINE_HEIGHT, palette)
    drawn = drawn + 1
  end
end

---@param text string
---@param rect table<string, number>
function BagRenderer:_drawCentered(text, rect)
  local content = plainText(text)
  local width = self._text:textWidth(content)
  self._text:drawText(content, rect.x + (rect.width - width) / 2, rect.y + 2)
end

---@param text string
---@param rect table<string, number>
---@param palette { foreground: { r: number, g: number, b: number }, shadow: { r: number, g: number, b: number }, background: { r: number, g: number, b: number, a: number } }
function BagRenderer:_drawCenteredWithPalette(text, rect, palette)
  local content = plainText(text)
  local width = self._text:textWidth(content)
  self._text:drawTextWithPalette(content, rect.x + (rect.width - width) / 2, rect.y + 2, palette)
end

-- Prints the Cancel label centered inside its source label area at the
-- source text-window top, through the description window colors. The label
-- area is narrower than the control face and carries no generic offset.
---@param label string
---@param labelRect table<string, number>
---@param palette { foreground: { r: number, g: number, b: number }, shadow: { r: number, g: number, b: number }, background: { r: number, g: number, b: number, a: number } }
function BagRenderer:_drawCancelLabel(label, labelRect, palette)
  local content = plainText(label)
  local width = self._text:textWidth(content)
  self._text:drawTextWithPalette(content, labelRect.x + math.floor((labelRect.width - width) / 2), labelRect.y, palette)
end

-- The three field-font slot triples the Bag uses: item rows, the count
-- readout, and the description window (whose colors Cancel shares). The
-- background role stays transparent so generated pixels remain visible
-- beneath glyph masks. Built once per draw, never per glyph.
---@return { item: table<string, unknown>, count: table<string, unknown>, description: table<string, unknown> }
function BagRenderer:_palettes()
  local fontDef = assert(self._text.fontDef, "bag text needs the shared field font definition")
  return {
    item = paletteRecord(fontDef, 1, 2, 0),
    count = paletteRecord(fontDef, 15, 1, 0),
    description = paletteRecord(fontDef, 15, 14, 0),
  }
end

-- The hero background beneath the 3D model: the gender-selected source
-- backdrop in canonical coordinates.
---@param presentation table<string, unknown>
function BagRenderer:_drawHeroBackground(presentation)
  local graphics = self._graphics
  local gender = assert(presentation.heroGender, "the bag presentation names its hero gender")
  assert(gender == "male" or gender == "female", "the hero gender selects its backdrop")
  local key = gender == "male" and "heroMale" or "heroFemale"
  drawVisual(graphics, assert(self._visuals[key]), 0, 0)
end

-- The hero foreground above the 3D model: the description frame with the
-- state-specific contextual text in canonical coordinates, printed through
-- the description window colors.
---@param presentation table<string, unknown>
---@param descriptionPalette table<string, unknown>
function BagRenderer:_drawHeroForeground(presentation, descriptionPalette)
  local graphics = self._graphics
  local manifest = self._manifest
  local selected = presentation.selected
  if selected ~= nil and selected.moveSummary ~= nil then
    local summary = assert(manifest.hero.moveSummary)
    drawVisual(graphics, assert(self._visuals.moveSummaryBackground), 0, 0)
    local facts = assert(selected.moveSummary)
    local typeVisual =
      assert(self._visuals["moveType:" .. assert(facts.moveType)], "the move type visual is unavailable")
    local categoryVisual =
      assert(self._visuals["moveCategory:" .. assert(facts.category)], "the move category visual is unavailable")
    drawVisual(graphics, typeVisual, summary.typeCenter.x, summary.typeCenter.y)
    drawVisual(graphics, categoryVisual, summary.categoryCenter.x, summary.categoryCenter.y)
    local labels = assert(summary.labels)
    local text = assert(summary.text)
    local function printAt(value, point)
      self._text:drawTextWithPalette(plainText(value), point.x, point.y, descriptionPalette)
    end
    printAt(labels.type, text.type)
    printAt(labels.pp, text.pp)
    printAt(labels.category, text.category)
    printAt(labels.power, text.power)
    printAt(labels.accuracy, text.accuracy)
    printAt(tostring(facts.pp), text.ppValue)
    printAt(facts.power <= 1 and labels.unavailable or tostring(facts.power), text.powerValue)
    printAt(facts.accuracy == 0 and labels.unavailable or tostring(facts.accuracy), text.accuracyValue)
    return
  end
  drawVisual(graphics, assert(self._visuals.descriptionFrame), 0, 0)
  local textRect = manifest.hero.description.textRect
  local selectedItem = presentation.selected
  if selectedItem ~= nil and type(selectedItem.description) == "string" then
    setColor(self._graphics, WHITE)
    self:_drawPaletteLines(selectedItem.description, textRect.x, textRect.y, descriptionPalette, 3)
  end
end

-- Counts the occupied cells in the six-cell visible window. Bag rows are
-- contiguous, so the count is the occupied prefix length; an occupied cell
-- behind an empty one fails instead of guessing a count mapping.
---@param visibleSlots table<integer, table<string, unknown>>
---@return integer
local function visibleOccupiedCount(visibleSlots)
  assert(type(visibleSlots) == "table" and #visibleSlots == 6, "the presentation carries six visible cells")
  local count = 0
  for index = 1, 6 do
    local cell = visibleSlots[index]
    if cell ~= nil and cell.empty ~= true then
      assert(count == index - 1, "visible Bag cells stay contiguously occupied")
      count = index
    end
  end
  assert(count >= 0 and count <= 6, "the visible occupied count fits its six cells")
  return count
end

-- Resolves the visible occupied prefix of the six-cell window for
-- count-aware background selection.
---@param presentation table<string, unknown>
---@return integer
local function backgroundCount(presentation)
  local visibleSlots = assert(presentation.visibleSlots, "the bag presentation lists its visible cells")
  return visibleOccupiedCount(visibleSlots)
end

-- Resolves the move origin key for background selection: the visible
-- zero-based original-item cell, or the origin-absent variant when the
-- original item scrolled outside the current six-cell window.
---@param presentation table<string, unknown>
---@return string
local function moveOriginKey(presentation)
  local origin = assert(presentation.moveOrigin, "move selection carries its origin")
  local start = assert(presentation.visibleStart, "the presentation carries its window start")
  assert(type(origin) == "number" and type(start) == "number", "move origin indexes are numbers")
  local cell = origin - start
  if cell >= 0 and cell <= 5 then
    return tostring(cell)
  end
  return "none"
end

---@class BagDemandEntry
---@field key string the visual key draws resolve, matching the construction path map keys
---@field path string the generated image path enrolled with the shared owner
---@field width integer the generated visual width draws place
---@field height integer the generated visual height draws place
---@field offset table<string, integer>? the generated visual offset draws place

---@class BagDemandPending
---@field signature string the semantic demand key this enrollment resolves
---@field requiredTokens table<integer, integer> demand tokens for the current state in enrollment order
---@field softTokens table<integer, integer> one-step-ahead prefetch tokens, never published
---@field tokenByPath table<string, integer> enrolled tokens by generated path
---@field entries table<integer, BagDemandEntry> current-state visual keys in enrollment order
---@field stagedByToken table<integer, table<string, unknown>> acquired required leases by token
---@field acquiredRequired integer count of acquired required leases
---@field published boolean true once the complete current state installed

-- Every bag visual samples point-filtered and clamped: pooled leases
-- draw under this exact sampler state.
local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

-- Required GPU acquisitions completed in one update round. A cold Bag
-- opening spreads its uploads across frames instead of stalling one
-- update; the next update continues from the remaining tokens.
local MAX_REQUIRED_ACQUISITIONS = 8

-- Resolves the one-step-ahead pocket following the current pocket in the
-- canonical pocket order, wrapping around the end of the list.
---@param pocket string the current pocket key
---@return string the prefetched neighbor pocket key
local function nextPocket(pocket)
  local order = BagSave.POCKET_ORDER
  local at = nil
  for index, key in ipairs(order) do
    if key == pocket then
      at = index
      break
    end
  end
  assert(at ~= nil, "the bag presentation names a known pocket")
  return order[(at % #order) + 1]
end

-- The immutable semantic key of one bag status: pocket, occupied count,
-- background class, move origin, toss base, and machine summary identity.
-- Animation clocks, focus positions, labels, quantities, and messages never
-- change the enrolled visuals, so redraws and animation ticks reuse the
-- installed leases without re-enrolling.
---@param presentation table<string, unknown>
---@return string
local function demandSignature(presentation)
  local pocket = assert(presentation.pocket, "the bag presentation names its pocket")
  local count = backgroundCount(presentation)
  local state = assert(presentation.state, "the bag presentation names its state")
  local parts = { "pocket:", pocket, "|count:", tostring(count), "|state:", state }
  if state == "move_select" then
    parts[#parts + 1] = "|origin:" .. moveOriginKey(presentation)
  elseif state == "toss_confirm" or state == "toss_ack" then
    local base = assert(presentation.tossBase, "toss confirmation retains its action/quantity base")
    parts[#parts + 1] = "|base:" .. tostring(base)
  end
  local selected = presentation.selected
  if type(selected) == "table" then
    local summary = selected.moveSummary
    if type(summary) == "table" then
      parts[#parts + 1] = "|machine:" .. tostring(assert(summary.moveType)) .. "/" .. tostring(assert(summary.category))
    end
  end
  return table.concat(parts)
end

-- Resolves the move origin key for one background lookup: the live origin
-- for the current pocket, the origin-absent variant for prefetched
-- pockets whose target is not yet known.
---@param presentation table<string, unknown>
---@param targetPocket string
---@param pocket string
---@return string
local function targetPocketOrigin(presentation, targetPocket, pocket)
  if targetPocket == pocket and presentation.state == "move_select" then
    return moveOriginKey(presentation)
  end
  return "none"
end

-- Collects the current-state visual keys one bag status draws, in a stable
-- enrollment order: shared chrome first, then the state background and
-- pocket strip, plus the bounded one-step-ahead pocket visuals as soft
-- interest. Current art enrolls as demand and alone gates readiness; the
-- predicted strip/background enroll as prefetch and never delay the
-- current pocket. A predicted path that duplicates a current path stays
-- required. Mirrors the construction path map keys exactly; an unknown
-- state/pocket/count fails here instead of borrowing another screen.
---@param self BagRenderer
---@param presentation table<string, unknown>
---@param signature string
---@return BagDemandPending
local function enrollDemand(self, presentation, signature)
  local paths = assert(self._paths, "bag state preparation resolves its construction path map")
  local pocket = assert(presentation.pocket, "the bag presentation names its pocket")
  local count = backgroundCount(presentation)
  local state = assert(presentation.state, "the bag presentation names its state")
  local entries = {} ---@type BagDemandEntry[]
  local softKeys = {} ---@type string[]
  local function add(key)
    local pathEntry = assert(paths[key], "the demand resolves " .. key .. " through the construction path map")
    entries[#entries + 1] = {
      key = key,
      path = pathEntry.path,
      width = pathEntry.width,
      height = pathEntry.height,
      offset = pathEntry.offset,
    }
  end
  add("focus:tabs")
  add("focus:items")
  add("focus:cancel")
  add("focus:actions")
  local selectionIndex = 1
  while paths["selectionEntry:" .. selectionIndex] ~= nil do
    add("selectionEntry:" .. selectionIndex)
    selectionIndex = selectionIndex + 1
  end
  add("heroMale")
  add("heroFemale")
  add("descriptionFrame")
  add("registrationSlot1")
  add("registrationSlot2")
  add("actionFace")
  add("feedback:action:normal")
  add("feedback:action:selected")
  add("feedback:cancel:normal")
  add("feedback:cancel:selected")
  add("feedback:quantityConfirm:normal")
  add("feedback:quantityConfirm:selected")
  add("feedback:quantityCancel:normal")
  add("feedback:quantityCancel:selected")
  add("quantityIncrement")
  add("quantityIncrementPressed")
  add("quantityDecrement")
  add("quantityDecrementPressed")
  add("quantityConfirm")
  add("quantityCancel")
  add("saleQuantityBackground")
  add("moveCursor:original")
  add("moveCursor:candidate")
  local function backgroundKey(targetPocket, origin)
    if state == "browsing" or state == "description_overlay" or state == "item_select" then
      return "background:browse:" .. targetPocket .. ":" .. count
    elseif
      state == "action_menu"
      or state == "sale_offer"
      or state == "sale_result"
      or state == "sale_refusal"
      or state == "sale_ack"
    then
      return "background:action:" .. targetPocket .. ":" .. count
    elseif state == "toss_quantity" then
      return "background:quantity:" .. targetPocket .. ":" .. count
    elseif state == "sale_quantity" then
      return ""
    elseif state == "toss_confirm" or state == "toss_ack" then
      local base = assert(presentation.tossBase, "toss confirmation retains its action/quantity base")
      assert(base == "action" or base == "quantity", "toss confirmation retains a known base")
      return "background:" .. base .. ":" .. targetPocket .. ":" .. count
    elseif state == "move_select" then
      return "background:move:" .. targetPocket .. ":" .. count .. ":" .. origin
    end
    error("the bag renderer draws a known lower-pane state", 0)
  end
  -- The sale quantity state draws the sale chrome without a lower-pane
  -- background: the empty key enrolls nothing below.
  local stateBackgroundKey = backgroundKey(pocket, targetPocketOrigin(presentation, pocket, pocket))
  if stateBackgroundKey ~= "" then
    add(stateBackgroundKey)
  end
  add("strip:" .. pocket)
  local ahead = nextPocket(pocket)
  local aheadBackgroundKey = backgroundKey(ahead, "none")
  if aheadBackgroundKey ~= "" then
    softKeys[#softKeys + 1] = aheadBackgroundKey
  end
  softKeys[#softKeys + 1] = "strip:" .. ahead
  local selected = presentation.selected
  if type(selected) == "table" and type(selected.moveSummary) == "table" then
    local facts = assert(selected.moveSummary)
    local moveType = assert(facts.moveType, "the move summary carries its type")
    local category = assert(facts.category, "the move summary carries its category")
    add("moveSummaryBackground")
    add("moveType:" .. moveType)
    add("moveCategory:" .. category)
  end
  local pool = assert(self._pool, "bag state preparation borrows its shared image owner")
  local requiredTokens = {} ---@type table<integer, integer>
  local tokenByPath = {} ---@type table<string, integer>
  for _, entry in ipairs(entries) do
    if tokenByPath[entry.path] == nil then
      local token = pool:request(entry.path, POOLED_SAMPLER, "demand")
      tokenByPath[entry.path] = token
      requiredTokens[#requiredTokens + 1] = token
    end
  end
  local softTokens = {} ---@type table<integer, integer>
  for _, key in ipairs(softKeys) do
    local pathEntry = assert(paths[key], "the demand resolves " .. key .. " through the construction path map")
    if tokenByPath[pathEntry.path] == nil then
      local token = pool:request(pathEntry.path, POOLED_SAMPLER, "prefetch")
      tokenByPath[pathEntry.path] = token
      softTokens[#softTokens + 1] = token
    end
  end
  return {
    signature = signature,
    requiredTokens = requiredTokens,
    softTokens = softTokens,
    tokenByPath = tokenByPath,
    entries = entries,
    stagedByToken = {},
    acquiredRequired = 0,
    published = false,
  }
end

-- Releases staged required leases and cancels every unconsumed token of
-- a pending group without touching installed state. Cancelling an already
-- consumed token is a harmless no-op; each staged lease returns exactly
-- once here. Used on failure, supersede, and release.
---@param pool table<string, unknown> the borrowed shared image owner
---@param pending BagDemandPending the group to forget
local function abandonPending(pool, pending)
  for _, lease in pairs(pending.stagedByToken) do
    pool:release(lease)
  end
  pending.stagedByToken = {}
  pending.acquiredRequired = 0
  for _, token in ipairs(pending.requiredTokens) do
    pool:cancel(token)
  end
  for _, token in ipairs(pending.softTokens) do
    pool:cancel(token)
  end
  pending.softTokens = {}
end

-- Installs the complete required group atomically once every required
-- lease is acquired: builds the visual map from staged leases, swaps it
-- in, and returns the previous installed leases exactly once. Ownership
-- of the staged leases moves to the installed group; the pending record
-- keeps only its soft interest afterwards.
---@param self BagRenderer
---@param pool table<string, unknown> the borrowed shared image owner
---@param pending BagDemandPending the fully acquired group to publish
local function publishRequired(self, pool, pending)
  local leaseByPath = {} ---@type table<string, table<string, unknown>>
  for path, token in pairs(pending.tokenByPath) do
    local lease = pending.stagedByToken[token]
    if lease ~= nil then
      leaseByPath[path] = lease
    end
  end
  local visuals = {} ---@type table<string, BagDemandVisual>
  local images = {} ---@type table<string, unknown>
  for _, entry in ipairs(pending.entries) do
    local lease = assert(leaseByPath[entry.path], "the resolved demand carries " .. entry.key)
    assert(lease.image, "shared leases carry their resolved image")
    visuals[entry.key] = { handle = lease, width = entry.width, height = entry.height, offset = entry.offset }
    images[entry.key] = lease.image
  end
  local aliases = { { "saleConfirm", "quantityConfirm" }, { "saleCancel", "quantityCancel" } }
  for _, alias in ipairs(aliases) do
    visuals[alias[1]] = assert(visuals[alias[2]], "the bag presentation names its quantity controls")
  end
  local staged = {} ---@type table<integer, table<string, unknown>>
  for _, token in ipairs(pending.requiredTokens) do
    staged[#staged + 1] = assert(pending.stagedByToken[token], "every required token staged its lease")
  end
  pending.stagedByToken = {}
  pending.acquiredRequired = 0
  pending.published = true
  for _, lease in ipairs(self._readyLeases) do
    pool:release(lease)
  end
  self._visuals = visuals
  self._images = images --[[@as table<string, love.Image>]]
  self._readyLeases = staged
  self._readySignature = pending.signature
end

-- Polls every required token once without blocking and acquires at most a
-- bounded batch of ready leases. Returns true once the whole current
-- demand installed. A failed required visual abandons the partial group
-- loudly while the installed state stays drawable; optional work is never
-- consulted here, so a stalled predicted pocket cannot delay readiness.
-- Never enrolls: callers promote the pending group across rounds.
---@param self BagRenderer
---@param pool table<string, unknown> the borrowed shared image owner
---@param pending BagDemandPending the group to advance
---@return boolean published
---@return boolean progressed
local function progressRequired(self, pool, pending)
  local acquired = 0
  for _, token in ipairs(pending.requiredTokens) do
    if pending.stagedByToken[token] == nil then
      local status, failure = pool:poll(token)
      if status == "failed" then
        abandonPending(pool, pending)
        self._pending = nil
        error("bag state image is not ready: " .. tostring(failure), 0)
      end
      assert(status == "pending" or status == "ready", "bag state preparation reports pending or ready")
      if status == "ready" and acquired < MAX_REQUIRED_ACQUISITIONS then
        local ok, lease = pcall(pool.acquire, pool, token)
        if not ok then
          abandonPending(pool, pending)
          self._pending = nil
          error(lease, 0)
        end
        pending.stagedByToken[token] = lease
        pending.acquiredRequired = pending.acquiredRequired + 1
        acquired = acquired + 1
      end
    end
  end
  if pending.acquiredRequired == #pending.requiredTokens then
    publishRequired(self, pool, pending)
    return true, true
  end
  return false, acquired > 0
end

-- Settles one-step-ahead interest after the current state installed, with
-- at most one optional adoption per update. Adopted leases return to idle
-- immediately and are never drawn; failed optional work is discarded
-- silently so prefetch can never surface a visible Bag error. Readiness
-- is never consulted or changed here.
---@param pool table<string, unknown> the borrowed shared image owner
---@param pending BagDemandPending the published group whose soft tokens drain
local function progressSoft(pool, pending)
  local kept = {} ---@type table<integer, integer>
  local adopted = false
  for _, token in ipairs(pending.softTokens) do
    if adopted then
      kept[#kept + 1] = token
    else
      local status = pool:poll(token)
      assert(status == "pending" or status == "ready" or status == "failed", "soft interest reports a known state")
      if status == "failed" then
        pool:cancel(token)
      elseif status == "ready" then
        local ok, lease = pcall(pool.acquire, pool, token)
        if ok then
          pool:release(lease)
        else
          pool:cancel(token)
        end
        adopted = true
      else
        kept[#kept + 1] = token
      end
    end
  end
  pending.softTokens = kept
end

-- Advances the demand for one bag status by a single enrollment and poll
-- round: enrolls the whole required path set before the first readiness
-- probe, promotes outstanding tokens across rounds, and abandons stale
-- interest that a newer status superseded. Publishes the complete
-- current state as soon as its required leases are acquired, then drains
-- soft interest without ever changing readiness. Returns readiness plus
-- whether this round made progress.
---@param self BagRenderer
---@param presentation table<string, unknown>
---@return boolean ready
---@return boolean progressed
local function advanceDemand(self, presentation)
  local signature = demandSignature(presentation)
  local pool = assert(self._pool, "bag state preparation borrows its shared image owner")
  local pending = self._pending
  if pending ~= nil and pending.signature ~= signature then
    -- A superseded pending never publishes: its staged leases return and
    -- its unconsumed tokens cancel, while the installed group stays
    -- drawable until a complete replacement arrives.
    abandonPending(pool, pending)
    self._pending = nil
    pending = nil
  end
  if pending == nil then
    if self._readySignature == signature then
      return true, false
    end
    -- A fresh enrollment enrolls every required path before the first
    -- readiness probe, then falls through to the progress logic below
    -- in the same call, so a fully warm hit publishes immediately
    -- instead of idling one round.
    pending = enrollDemand(self, presentation, signature)
    self._pending = pending
  end
  if pending.published then
    progressSoft(pool, pending)
    if #pending.softTokens == 0 then
      self._pending = nil
    end
    return true, true
  end
  local published, progressed = progressRequired(self, pool, pending)
  if published then
    progressSoft(pool, pending)
    if #pending.softTokens == 0 then
      self._pending = nil
    end
    return true, true
  end
  return false, progressed
end

-- Draws the one generated lower-pane background for the current state and
-- pocket. Browse, action, and quantity states resolve the realized count
-- variant from the visible occupied prefix; move resolves the count/origin
-- variant; toss confirmation owns no background of its own and retains its
-- recorded action/quantity base. Every image is asserted at construction,
-- so an unknown state/pocket fails instead of borrowing another screen.
---@param state string
---@param pocket string
---@param presentation table<string, unknown>
function BagRenderer:_drawStateBackground(state, pocket, presentation)
  local count = backgroundCount(presentation)
  local key
  if state == "browsing" or state == "description_overlay" or state == "item_select" then
    key = "background:browse:" .. pocket .. ":" .. count
  elseif state == "action_menu" then
    key = "background:action:" .. pocket .. ":" .. count
  elseif state == "toss_quantity" then
    key = "background:quantity:" .. pocket .. ":" .. count
  elseif state == "sale_quantity" then
    drawVisual(self._graphics, assert(self._visuals.saleQuantityBackground), 0, 0)
    return
  elseif state == "sale_offer" or state == "sale_result" or state == "sale_refusal" or state == "sale_ack" then
    key = "background:action:" .. pocket .. ":" .. count
  elseif state == "toss_confirm" or state == "toss_ack" then
    local base = assert(presentation.tossBase, "toss confirmation retains its action/quantity base")
    assert(base == "action" or base == "quantity", "toss confirmation retains a known base")
    key = "background:" .. base .. ":" .. pocket .. ":" .. count
  elseif state == "move_select" then
    key = "background:move:" .. pocket .. ":" .. count .. ":" .. moveOriginKey(presentation)
  else
    error("the bag renderer draws a known lower-pane state", 0)
  end
  drawVisual(self._graphics, assert(self._visuals[key], "the bag presentation names its pocket"), 0, 0)
end

-- Resolves the one-based pocket index of a supplied pocket key. Pocket
-- identity alone never implies focus; callers draw the tab visual only
-- while tabs are semantically focused.
---@param presentation table<string, unknown>
---@param pocketKey string
---@return integer
local function pocketIndex(presentation, pocketKey)
  assert(type(pocketKey) == "string", "the bag presentation names its tab focus pocket")
  local pockets = assert(presentation.pockets, "the bag presentation lists its pockets")
  for index, tab in ipairs(pockets) do
    if tab.pocket == pocketKey then
      return index
    end
  end
  error("the pocket has no generated tab", 0)
end

-- Which browse dynamic layers stay visible in each presentation state.
-- Browsing keeps the full list chrome; the description overlay keeps the
-- browse base it covers; move selection keeps the item cells that identify
-- the target while hiding page, cancel, and browse focus chrome; every
-- other modal state draws only its own layers over its state background.
local INTERACTIVE_LAYERS = {
  browsing = { cells = true, browseFocus = true, moveFocus = false, page = true, cancelLabel = true },
  description_overlay = { cells = true, browseFocus = true, moveFocus = false, page = true, cancelLabel = true },
  item_select = { cells = true, browseFocus = false, moveFocus = false, page = true, cancelLabel = true },
  move_select = { cells = true, browseFocus = false, moveFocus = true, page = false, cancelLabel = true },
  action_menu = { cells = false, browseFocus = false, moveFocus = false, page = false, cancelLabel = true },
  toss_quantity = { cells = false, browseFocus = false, moveFocus = false, page = false, cancelLabel = false },
  sale_quantity = { cells = false, browseFocus = false, moveFocus = false, page = false, cancelLabel = false },
  sale_offer = { cells = false, browseFocus = false, moveFocus = false, page = false, cancelLabel = false },
  sale_result = { cells = false, browseFocus = false, moveFocus = false, page = false, cancelLabel = false },
  sale_refusal = { cells = false, browseFocus = false, moveFocus = false, page = false, cancelLabel = false },
  sale_ack = { cells = false, browseFocus = false, moveFocus = false, page = false, cancelLabel = false },
  toss_confirm = { cells = false, browseFocus = false, moveFocus = false, page = false, cancelLabel = false },
  toss_ack = { cells = false, browseFocus = false, moveFocus = false, page = false, cancelLabel = false },
}

-- Resolves the visible dynamic layers for a presentation state. An unknown
-- state is a composition error, never an empty or borrowed screen.
---@param state string
---@return { cells: boolean, browseFocus: boolean, moveFocus: boolean, page: boolean, cancelLabel: boolean }
local function interactiveLayers(state)
  local layers = INTERACTIVE_LAYERS[state]
  assert(layers ~= nil, "the bag renderer draws a known lower-pane state")
  return layers
end

-- Resolves the one-based selection-entry frame for an elapsed clock:
-- the first frame whose cumulative source duration exceeds the elapsed
-- ticks. Elapsed ticks at or past the generated total clamp to the final
-- frame; drawing never advances time.
---@param entry table<string, unknown> the generated one-shot sequence
---@param elapsed integer controller ticks elapsed in the entry
---@return integer
local function selectionFrameIndex(entry, elapsed)
  assert(type(elapsed) == "number" and elapsed % 1 == 0 and elapsed >= 0, "the entry clock is a tick count")
  local frames = assert(entry.frames, "the selection entry carries its realized frames")
  assert(type(frames) == "table" and #frames >= 1, "the selection entry carries its frames")
  local cursor = 0
  for index, frame in ipairs(frames) do
    cursor = cursor + assert(frame.durationTicks, "selection frames carry their source duration")
    if elapsed < cursor then
      return index
    end
  end
  return #frames
end

-- Draws the generated item focus visual at a one-based visible cell.
---@param cell integer
function BagRenderer:_drawItemFocusCell(cell)
  local focus = assert(self._manifest.interactive.focus, "the bag manifest must carry its focus visuals")
  local itemFocus = assert(focus.items, "the bag manifest carries its item focus")
  local targets = assert(itemFocus.targets, "the item focus carries its targets")
  assert(type(targets) == "table" and #targets == 6, "the item focus targets its six visible cells")
  local target = assert(targets[cell], "the visible cell resolves a focus target")
  drawVisual(self._graphics, assert(self._visuals["focus:items"]), target.x, target.y)
end

-- Draws the source selection-entry animation over the focused item's
-- generated target while the browse composition stays up: the frame is a
-- pure function of the controller clock and the generated durations.
---@param presentation table<string, unknown>
function BagRenderer:_drawSelectionEntry(presentation)
  local entry =
    assert(self._manifest.interactive.selectionEntry, "the bag manifest carries its selection-entry sequence")
  local elapsed = assert(presentation.itemSelectElapsed, "the selection entry presentation carries its elapsed ticks")
  local index = selectionFrameIndex(entry, elapsed)
  local focus = assert(self._manifest.interactive.focus, "the bag manifest must carry its focus visuals")
  local itemFocus = assert(focus.items, "the bag manifest carries its item focus")
  local targets = assert(itemFocus.targets, "the item focus carries its targets")
  assert(type(targets) == "table" and #targets == 6, "the item focus targets its six visible cells")
  local visibleIndex =
    assert(presentation.focusedVisibleIndex, "the selection entry presentation carries its focused cell")
  assert(
    type(visibleIndex) == "number" and visibleIndex >= 0 and visibleIndex <= 5,
    "the focused cell indexes the visible grid"
  )
  local target = assert(targets[visibleIndex + 1], "the focused cell resolves a selection target")
  drawVisual(
    self._graphics,
    assert(self._visuals["selectionEntry:" .. index], "the bag presentation names its selection frame"),
    target.x,
    target.y
  )
end

-- Draws the item focus visual beneath the cell content it frames, so icons,
-- names, quantities, and registration markers stay visible above the movable
-- cursor. Browse focus resolves from the controller's focused visible cell,
-- independently of occupied selection, so an empty focused cell draws the
-- same chrome. Nothing is drawn for a control that is not semantically
-- focused.
---@param presentation table<string, unknown>
function BagRenderer:_drawCellFocus(presentation)
  local layers = interactiveLayers(assert(presentation.state, "the bag presentation names its state"))
  if layers.moveFocus then
    local moveTarget = assert(presentation.moveTarget, "move selection carries its target")
    local start = assert(presentation.visibleStart, "the presentation carries its window start")
    assert(type(moveTarget) == "number" and type(start) == "number", "move target indexes are numbers")
    local cell = moveTarget - start + 1
    if cell < 1 or cell > 6 then
      return
    end
    self:_drawItemFocusCell(cell)
    return
  end
  if not layers.browseFocus then
    return
  end
  if presentation.focus == "items" then
    local visibleIndex = presentation.focusedVisibleIndex
    if type(visibleIndex) == "number" then
      local cell = visibleIndex + 1
      if cell >= 1 and cell <= 6 then
        self:_drawItemFocusCell(cell)
      end
    end
  end
end

-- Draws the transient tab focus visual after the persistent selected
-- strip, at the candidate pocket target. The strip carries the committed
-- selection independently of this movable cursor. Nothing is drawn unless
-- the tab strip is semantically focused.
---@param presentation table<string, unknown>
function BagRenderer:_drawTabFocus(presentation)
  local layers = interactiveLayers(assert(presentation.state, "the bag presentation names its state"))
  if not layers.browseFocus then
    return
  end
  if presentation.focus ~= "tabs" then
    return
  end
  local focus = assert(self._manifest.interactive.focus, "the bag manifest must carry its focus visuals")
  local candidate = assert(presentation.tabFocusPocket, "the bag presentation names its tab focus pocket")
  local targetIndex = pocketIndex(presentation, candidate)
  local tabFocus = assert(focus.tabs, "the bag manifest carries its tab focus")
  local targets = assert(tabFocus.targets, "the tab focus carries its targets")
  assert(type(targets) == "table" and #targets == 8, "the tab focus targets its eight pockets")
  local target = assert(targets[targetIndex], "the focused pocket resolves a focus target")
  drawVisual(self._graphics, assert(self._visuals["focus:tabs"]), target.x, target.y)
end

-- Draws the Cancel focus visual above the item grid. Its target never
-- overlaps item content, so it stays above the cell art while remaining
-- beneath the text labels drawn later.
---@param presentation table<string, unknown>
function BagRenderer:_drawChromeFocus(presentation)
  local layers = interactiveLayers(assert(presentation.state, "the bag presentation names its state"))
  if not layers.browseFocus then
    return
  end
  if presentation.focus ~= "cancel" then
    return
  end
  local focus = assert(self._manifest.interactive.focus, "the bag manifest must carry its focus visuals")
  local cancelFocus = assert(focus.cancel, "the bag manifest carries its cancel focus")
  local target = assert(cancelFocus.target, "the cancel focus carries its target")
  drawVisual(self._graphics, assert(self._visuals["focus:cancel"]), target.x, target.y)
end

-- Draws the action-menu focus visual beneath the action labels at the
-- selected action's generated target. A selection outside the offered
-- actions or the generated targets is a composition error, never clamped.
---@param presentation table<string, unknown>
function BagRenderer:_drawActionFocus(presentation)
  local focus = assert(self._manifest.interactive.focus, "the bag manifest must carry its focus visuals")
  local selectedNode = assert(presentation.actionNode, "the action menu carries its physical selection")
  assert(
    type(selectedNode) == "number"
      and selectedNode == math.floor(selectedNode)
      and selectedNode >= 0
      and selectedNode <= 4,
    "the selected action node is valid"
  )
  if selectedNode == 4 then
    local cancel = assert(focus.cancel, "the manifest carries its cancel focus")
    local target = assert(cancel.target, "the cancel focus carries its target")
    drawVisual(self._graphics, assert(self._visuals["focus:cancel"]), target.x, target.y)
    return
  end
  local actionFocus = assert(focus.actions, "the bag manifest carries its action focus")
  local targets = assert(actionFocus.targets, "the action focus carries its targets")
  assert(type(targets) == "table" and #targets == 4, "the action focus targets its four nodes")
  local target = assert(targets[selectedNode + 1], "the selected action maps to a generated target")
  drawVisual(self._graphics, assert(self._visuals["focus:actions"]), target.x, target.y)
end

-- Draws the six-cell item grid: icons at their generated centers, names
-- and quantities at their text-window anchors, and registration badges
-- above the icons they overlap. Only states whose visibility policy owns
-- the list call this; other states leave the cells off their backgrounds.
---@param presentation table<string, unknown>
---@param icons table<string, unknown>
---@param iconImage love.Image
---@param palettes { item: table<string, unknown>, count: table<string, unknown>, description: table<string, unknown> }
function BagRenderer:_drawItemCells(presentation, icons, iconImage, palettes)
  local graphics = self._graphics
  local slots = self._manifest.interactive.itemSlots.slots
  local visibleSlots = assert(presentation.visibleSlots, "the bag presentation lists its visible cells")
  assert(type(visibleSlots) == "table" and #visibleSlots == 6, "the presentation carries six visible cells")
  local registrationOffset = assert(
    self._manifest.interactive.itemSlots.registration and self._manifest.interactive.itemSlots.registration.offset,
    "the registration markers carry their generated offset"
  )
  for index = 1, 6 do
    local cell = visibleSlots[index]
    local slot = assert(slots[index], "the presentation carries six generated cells")
    local rect = assert(slot.rect, "every cell needs its control rectangle")
    if cell ~= nil and cell.empty ~= true then
      local iconKey = assert(cell.icon, "occupied cells carry an icon key")
      local quad = icons:quadFor(iconKey)
      local dims = icons:dimensions(iconKey)
      local center = assert(slot.iconCenter, "every cell needs its icon center")
      setColor(graphics, WHITE)
      local handle = icons:handle()
      if handle ~= nil then
        ImageSampling.draw(graphics, handle, quad, center.x - dims.width / 2, center.y - dims.height / 2)
      else
        graphics.draw(iconImage, quad, center.x - dims.width / 2, center.y - dims.height / 2)
      end
      setColor(graphics, WHITE)
      -- The registration badge composites above the icon it overlaps
      -- under
      -- the corrected icon anchor, so the slot distinction stays visible;
      -- cell text still prints above the badge.
      local registrationSlot = cell.registrationSlot
      if registrationSlot ~= nil then
        assert(
          registrationSlot == 1 or registrationSlot == 2,
          "occupied cells carry a registration slot of 1, 2, or nil"
        )
        local marker = registrationSlot == 1 and self._visuals.registrationSlot1 or self._visuals.registrationSlot2
        drawVisual(
          graphics,
          assert(marker, "occupied cells carry a registration slot of 1, 2, or nil"),
          rect.x + registrationOffset.x,
          rect.y + registrationOffset.y
        )
      end
      -- Item strings come from the text window and its explicit anchors,
      -- never from the control rect.
      local textRect = assert(slot.textRect, "every cell needs its text window")
      local nameAt = assert(slot.nameAt, "every cell needs its name anchor")
      local quantityAt = assert(slot.quantityAt, "every cell needs its quantity anchor")
      assert(type(cell.name) == "string", "occupied cells carry a name")
      self._text:drawTextWithPalette(plainText(cell.name), textRect.x + nameAt.x, textRect.y + nameAt.y, palettes.item)
      assert(type(cell.quantity) == "number", "occupied cells carry a quantity")
      self._text:drawTextWithPalette(
        "x" .. cell.quantity,
        textRect.x + quantityAt.x,
        textRect.y + quantityAt.y,
        palettes.item
      )
    end
  end
end

-- Draws the retained selected-item panel of the action-derived states:
-- the selected icon at its canonical center plus the name and quantity in
-- the dedicated text window, through the same item palette and anchors as
-- the browse cells.
---@param presentation table<string, unknown>
---@param icons table<string, unknown>
---@param iconImage love.Image
---@param itemPalette table<string, unknown>
function BagRenderer:_drawSelectedItemPanel(presentation, icons, iconImage, itemPalette)
  local graphics = self._graphics
  local saleState = presentation.state == "sale_quantity"
    or presentation.state == "sale_offer"
    or presentation.state == "sale_result"
    or presentation.state == "sale_refusal"
    or presentation.state == "sale_ack"
  local panel = saleState
      and assert(self._manifest.interactive.sale.selectedItem, "the sale carries its selected-item panel")
    or assert(self._manifest.interactive.overlays.selectedItem, "the bag manifest carries its selected-item panel")
  local center = assert(panel.iconCenter, "the selected-item panel carries its icon center")
  local textRect = assert(panel.textRect, "the selected-item panel carries its text window")
  local selected = assert(presentation.selected, "the panel states carry their selected item")
  local iconKey = assert(selected.icon, "the selected item carries its icon key")
  local quad = icons:quadFor(iconKey)
  local dims = icons:dimensions(iconKey)
  setColor(graphics, WHITE)
  local handle = icons:handle()
  if handle ~= nil then
    ImageSampling.draw(graphics, handle, quad, center.x - dims.width / 2, center.y - dims.height / 2)
  else
    graphics.draw(iconImage, quad, center.x - dims.width / 2, center.y - dims.height / 2)
  end
  local nameAt = assert(panel.nameAt, "the selected-item panel carries its name anchor")
  local quantityAt = assert(panel.quantityAt, "the selected-item panel carries its quantity anchor")
  assert(type(selected.name) == "string", "the selected item carries a name")
  self._text:drawTextWithPalette(plainText(selected.name), textRect.x + nameAt.x, textRect.y + nameAt.y, itemPalette)
  assert(type(selected.quantity) == "number", "the selected item carries a quantity")
  self._text:drawTextWithPalette(
    "x" .. selected.quantity,
    textRect.x + quantityAt.x,
    textRect.y + quantityAt.y,
    itemPalette
  )
end

-- Draws the controller-owned lower message in its generated framed window:
-- the short window for action/move messages, the tall window for toss
-- confirmation/result. The message fills with the field-window slot and
-- prints through the list roles at explicit window-local origins: the
-- selected message starts at the content-box origin, while the two-line
-- confirmation/result keeps its state rows. The borrowed shared window
-- renderer draws the player-selected frame; without it the content box
-- fills flat. Visible text arrives fully revealed from the controller;
-- this draws and never advances clocks.
---@param presentation table<string, unknown>
function BagRenderer:_drawLowerMessage(presentation)
  local message = presentation.lowerMessage
  if message == nil then
    return
  end
  local visibleText = assert(message.visibleText, "lower messages carry their visible text")
  if visibleText == "" then
    return
  end
  local messages = assert(self._manifest.interactive.overlays.messages, "the bag manifest carries its message windows")
  local state = assert(presentation.state, "the bag presentation names its state")
  local windowKey = (state == "toss_confirm" or state == "toss_ack" or state == "sale_offer" or state == "sale_result")
      and "modal"
    or "selected"
  local contentRect = assert(messages[windowKey].contentRect, "the bag manifest carries its message content rect")
  local box = { x = contentRect.x, y = contentRect.y, width = contentRect.width, height = contentRect.height }
  local background = self._text:windowBackgroundColor()
  local fontDef = assert(self._text.fontDef, "bag text needs the shared field font definition")
  local palette = paletteRecord(fontDef, 1, 2, 15)
  local maxLines = windowKey == "modal" and 2 or 1
  local lines = {}
  for line in (plainText(visibleText) .. "\n"):gmatch("([^\n]*)\n") do
    if #lines >= maxLines then
      break
    end
    if windowKey == "modal" then
      lines[#lines + 1] = { text = line, x = 0, y = #lines * LINE_HEIGHT }
    else
      lines[#lines + 1] = { text = line, x = 0, y = 0 }
    end
  end
  local window = self._window
  if window ~= nil then
    FieldTextWindowRenderer.draw({
      window = window,
      text = self._text,
      box = box,
      frameIndex = self._frameIndex,
      background = background,
      palette = palette,
      lines = lines,
    })
  else
    setColor(self._graphics, background)
    self._graphics.rectangle("fill", box.x, box.y, box.width, box.height)
    setColor(self._graphics, WHITE)
    for _, line in ipairs(lines) do
      self._text:drawTextWithPalette(line.text, box.x + line.x, box.y + line.y, palette)
    end
  end
end

---@param presentation table<string, unknown>
---@param icons table<string, unknown>
---@param content table<string, unknown> the canonical logical content selecting compact fallbacks
---@param palettes { item: table<string, unknown>, count: table<string, unknown>, description: table<string, unknown> }
function BagRenderer:_drawInteractive(presentation, icons, content, palettes)
  local graphics = self._graphics
  local manifest = self._manifest
  local interactive = manifest.interactive
  local state = assert(presentation.state, "the bag presentation names its state")
  local pocket = assert(presentation.pocket, "the bag presentation names its pocket")
  -- The state background always paints first; the policy lookup is
  -- exhaustive, so an unknown state fails before borrowing other layers.
  local layers = interactiveLayers(state)
  self:_drawStateBackground(state, pocket, presentation)
  drawVisual(graphics, assert(self._visuals["strip:" .. pocket]), 0, 0)
  self:_drawTabFocus(presentation)
  -- The movable item cursor draws beneath the cell content it frames, so
  -- icons, names, quantities, and registration markers stay visible above it.
  self:_drawCellFocus(presentation)
  local iconImage = icons:image()
  -- Only states that own the list paint cells, icons, names, quantities,
  -- and registration markers; other states cover the list with their own
  -- background and layers instead.
  if layers.cells then
    self:_drawItemCells(presentation, icons, iconImage, palettes)
  end
  -- Cancel focus sits above the grid art it frames; its target never
  -- overlaps item content.
  self:_drawChromeFocus(presentation)
  local page = assert(presentation.page, "the bag presentation derives its page")
  if layers.page then
    setColor(graphics, WHITE)
    self:_drawCenteredWithPalette(page.current .. "/" .. page.count, interactive.pageIndicator.rect, palettes.count)
  end
  local cancelLabel = assert(interactive.text.actions.cancel, "the bag manifest carries its cancel label")
  if layers.cancelLabel then
    -- Cancel chrome lives in the selected background pixels; only the label
    -- prints, placed by the label window rather than the control rect.
    local cancelGeometry = assert(interactive.cancel, "the bag manifest must carry its cancel geometry")
    local labelRect = assert(cancelGeometry.labelRect, "the bag manifest carries its cancel label area")
    self:_drawCancelLabel(cancelLabel, labelRect, palettes.description)
  end
  if state == "description_overlay" then
    if content.heroVisible == false then
      self:_drawDescriptionOverlay(presentation, icons, iconImage)
    end
  elseif state == "action_menu" then
    self:_drawActionFaces(presentation)
    self:_drawActionFocus(presentation)
    self:_drawActionLabels(presentation)
    self:_drawSelectedItemPanel(presentation, icons, iconImage, palettes.item)
    self:_drawLowerMessage(presentation)
  elseif state == "item_select" then
    self:_drawSelectionEntry(presentation)
  elseif state == "toss_quantity" then
    self:_drawSelectedItemPanel(presentation, icons, iconImage, palettes.item)
    self:_drawQuantityState(presentation)
  elseif state == "sale_quantity" then
    self:_drawSelectedItemPanel(presentation, icons, iconImage, palettes.item)
    self:_drawSaleQuantityState(presentation)
    self:_drawLowerMessage(presentation)
  elseif state == "sale_offer" or state == "sale_result" or state == "sale_refusal" or state == "sale_ack" then
    self:_drawSelectedItemPanel(presentation, icons, iconImage, palettes.item)
    self:_drawSaleValues(presentation)
    self:_drawLowerMessage(presentation)
    if state == "sale_offer" then
      self:_drawTossPrompt(presentation)
    end
  elseif state == "toss_confirm" or state == "toss_ack" then
    -- The acknowledgement carries no interactive widgets beyond the
    -- retained panel, the result message, and the open prompt.
    self:_drawSelectedItemPanel(presentation, icons, iconImage, palettes.item)
    self:_drawLowerMessage(presentation)
    self:_drawTossPrompt(presentation)
  elseif state == "move_select" then
    self:_drawMoveHighlight(presentation)
    self:_drawLowerMessage(presentation)
  elseif state ~= "browsing" then
    error("the bag renderer draws a known lower-pane state", 0)
  end
  self:_drawConstrainedContextual(presentation, content, palettes.description)
end

-- The action menu draws the generated semantic label for each offered
-- action into its generated button rectangle. An offered action without a
-- generated label, or more actions than generated buttons, fails instead
-- of printing an internal id or inventing geometry.
---@return table<integer, table<string, unknown>>
function BagRenderer:_actionSlots()
  local menu = assert(self._manifest.interactive.overlays.actionMenu, "the action menu needs its generated slots")
  local slots = assert(menu.slots, "the action menu needs its generated slots")
  assert(type(slots) == "table" and #slots == 4, "the action menu needs its four generated slots")
  return slots
end

---@param presentation table<string, unknown>
function BagRenderer:_drawActionFaces(presentation)
  local actions = assert(presentation.actions, "the action menu carries its actions")
  assert(type(actions) == "table", "the action menu carries its actions")
  local slots = self:_actionSlots()
  local feedbackKind = type(presentation.feedback) == "table" and presentation.feedback.kind or nil
  for _, action in ipairs(actions) do
    assert(type(action.slot) == "number" and action.slot >= 0 and action.slot <= 3, "actions carry physical slots")
    local slot = assert(slots[action.slot + 1], "the action maps to a generated slot")
    local center = assert(slot.center, "action slots carry centers")
    local key = "actionFace"
    if feedbackKind == "action:" .. action.slot then
      key = "feedback:action:selected"
    end
    drawVisual(self._graphics, assert(self._visuals[key]), center.x, center.y)
  end
  if feedbackKind == "cancel" then
    local focus = assert(self._manifest.interactive.focus, "the bag manifest must carry its focus visuals")
    local cancelFocus = assert(focus.cancel, "the bag manifest carries its cancel focus")
    local target = assert(cancelFocus.target, "the cancel focus carries its target")
    local flash = assert(self._visuals["feedback:cancel:selected"], "feedback carries its cancel flash")
    -- Feedback visual descriptors own their own generated offset.
    drawVisual(self._graphics, flash, target.x, target.y)
  end
end

---@param presentation table<string, unknown>
function BagRenderer:_drawActionLabels(presentation)
  local actions = assert(presentation.actions, "the action menu carries its actions")
  assert(type(actions) == "table", "the action menu carries its actions")
  local slots = self:_actionSlots()
  local manifest = self._manifest
  local labels = assert(
    manifest.interactive.text and manifest.interactive.text.actions,
    "the action menu needs its generated labels"
  )
  local palette = self:_palettes().description
  for _, action in ipairs(actions) do
    assert(type(action.slot) == "number" and action.slot >= 0 and action.slot <= 3, "actions carry physical slots")
    local slot = assert(slots[action.slot + 1], "the action maps to a generated slot")
    assert(type(action.id) == "string", "menu actions carry a semantic id")
    local label = labels[action.id]
    assert(type(label) == "string" and label ~= "", "every offered action carries a generated label")
    setColor(self._graphics, WHITE)
    local rect = assert(slot.textRect, "action slots carry label rectangles")
    local content = plainText(label)
    local width = self._text:textWidth(content)
    self._text:drawTextWithPalette(content, rect.x + (rect.width - width) / 2, rect.y, palette)
  end
end

-- The quantity picker draws the picked decimal amount right-aligned over
-- the three generated digit cells; unused leading cells stay blank. Amounts
-- outside the controller's validated range or beyond three cells fail
-- instead of clipping into the generated art.
---@param presentation table<string, unknown>
function BagRenderer:_drawQuantityState(presentation)
  local quantity = assert(presentation.quantity, "the quantity picker carries its amount")
  assert(type(quantity) == "number", "the quantity picker carries its amount")
  assert(
    quantity == math.floor(quantity) and quantity >= 1 and quantity <= 999,
    "the picked amount fits three digit cells"
  )
  local quantityMax = presentation.quantityMax
  if quantityMax ~= nil then
    assert(
      type(quantityMax) == "number" and quantity <= quantityMax,
      "the picked amount stays within its validated range"
    )
  end
  local digits = assert(
    self._manifest.interactive.overlays.quantity.digits,
    "the quantity picker needs its generated digit geometry"
  )
  local picked = tostring(quantity)
  assert(#picked <= #digits, "the picked amount fits three digit cells")
  for position = 1, #picked do
    local glyph = picked:sub(position, position)
    local cell = digits[#digits - #picked + position]
    local width = self._text:textWidth(glyph)
    self._text:drawText(glyph, cell.x + (cell.width - width) / 2, cell.y + 2)
  end
  local overlay = assert(self._manifest.interactive.overlays.quantity, "the quantity overlay is required")
  local controls = assert(overlay.controls, "the quantity overlay carries controls")
  local pressed = presentation.quantityPressedControl
  if pressed ~= nil then
    assert(type(pressed) == "number" and pressed >= 0 and pressed < #controls, "the pressed quantity control is valid")
  end
  for index, control in ipairs(controls) do
    local key = control.role == "increment" and "quantityIncrement" or "quantityDecrement"
    if pressed == index - 1 then
      key = key .. "Pressed"
    end
    local center = assert(control.center, "quantity controls carry centers")
    drawVisual(self._graphics, assert(self._visuals[key]), center.x, center.y)
  end
  local feedbackKind = type(presentation.feedback) == "table" and presentation.feedback.kind or nil
  local confirm = assert(overlay.confirm, "the quantity overlay carries confirm")
  local cancel = assert(overlay.cancel, "the quantity overlay carries cancel")
  -- Each face draws exactly once: the selected activation visual replaces
  -- its normal twin, never alongside it.
  if feedbackKind == "quantityConfirm" then
    local center = assert(confirm.center, "quantity confirm carries a center")
    drawVisual(self._graphics, assert(self._visuals["feedback:quantityConfirm:selected"]), center.x, center.y)
  else
    local center = assert(confirm.center, "quantity confirm carries a center")
    drawVisual(self._graphics, assert(self._visuals.quantityConfirm), center.x, center.y)
  end
  if feedbackKind == "quantityCancel" then
    local center = assert(cancel.center, "quantity cancel carries a center")
    drawVisual(self._graphics, assert(self._visuals["feedback:quantityCancel:selected"]), center.x, center.y)
  else
    local center = assert(cancel.center, "quantity cancel carries a center")
    drawVisual(self._graphics, assert(self._visuals.quantityCancel), center.x, center.y)
  end
  -- The confirm control prints TOSS and the quantity Cancel control prints
  -- CANCEL through the generated semantic labels at their generated text
  -- origins. Both hide once toss confirmation owns the retained base.
  local labels = assert(
    self._manifest.interactive.text and self._manifest.interactive.text.actions,
    "the quantity picker needs its generated labels"
  )
  local palette = self:_palettes().description
  local tossLabel = assert(labels.toss, "the bag manifest carries its toss label")
  local confirmLabelAt = assert(confirm.labelAt, "quantity confirm carries its label origin")
  setColor(self._graphics, WHITE)
  self._text:drawTextWithPalette(plainText(tossLabel), confirmLabelAt.x, confirmLabelAt.y, palette)
  local cancelLabel = assert(labels.cancel, "the bag manifest carries its cancel label")
  local cancelLabelAt = assert(cancel.labelAt, "quantity cancel carries its label origin")
  self._text:drawTextWithPalette(plainText(cancelLabel), cancelLabelAt.x, cancelLabelAt.y, palette)
end

---@param box table<string, unknown>
---@param value integer
---@param palette table<string, unknown>
function BagRenderer:_drawSaleAmount(box, value, palette)
  local rect = assert(box, "sale amounts carry text boxes")
  local text = tostring(value)
  local width = self._text:textWidth(text)
  local alignment = assert(rect.alignment, "sale amount boxes carry alignment")
  local x = rect.x + (alignment == "right" and rect.width - width or 0) + rect.textX
  self._text:drawTextWithPalette(text, x, rect.y + rect.textY, palette)
end

---@param presentation table<string, unknown>
function BagRenderer:_drawSaleValues(presentation)
  local sale = assert(self._manifest.interactive.sale, "the bag manifest carries sale geometry")
  local balance = assert(presentation.saleBalance, "sale presentation carries the money balance")
  local total = assert(presentation.saleTotal, "sale presentation carries the quoted total")
  local palette = self:_palettes().item
  setColor(self._graphics, WHITE)
  self:_drawSaleAmount(sale.money, balance, palette)
  self:_drawSaleAmount(sale.total, total, palette)
end

---@param presentation table<string, unknown>
function BagRenderer:_drawSaleQuantityState(presentation)
  local sale = assert(self._manifest.interactive.sale, "the bag manifest carries sale geometry")
  local quantity = assert(presentation.quantity, "sale quantity carries its amount")
  local quantityMax = assert(presentation.quantityMax, "sale quantity carries its cap")
  assert(quantity >= 1 and quantity <= quantityMax and quantity <= 99, "sale amount fits two digits and its cap")
  local digits = assert(sale.digits, "sale quantity carries two digit placements")
  local picked = tostring(quantity)
  assert(#digits == 2 and #picked <= 2, "sale quantity uses two digit cells")
  for position = 1, #picked do
    local glyph = picked:sub(position, position)
    local cell = digits[#digits - #picked + position]
    local width = self._text:textWidth(glyph)
    self._text:drawText(glyph, cell.x + (cell.width - width) / 2, cell.y + 2)
  end
  local pressed = presentation.quantityPressedControl
  for index, control in ipairs(sale.controls) do
    local hiddenTens = (control.delta == 10 or control.delta == -10) and quantityMax < 10
    if not hiddenTens then
      local key = control.role == "increment" and "quantityIncrement" or "quantityDecrement"
      if pressed == index - 1 then
        key = key .. "Pressed"
      end
      drawVisual(self._graphics, assert(self._visuals[key]), control.center.x, control.center.y)
    end
  end
  local confirm = sale.confirm
  local cancel = sale.cancel
  drawVisual(self._graphics, assert(self._visuals.saleConfirm), confirm.center.x, confirm.center.y)
  drawVisual(self._graphics, assert(self._visuals.saleCancel), cancel.center.x, cancel.center.y)
  local labels = assert(self._manifest.interactive.text.actions, "the Bag carries CONFIRM and CANCEL labels")
  local palette = self:_palettes().description
  self._text:drawTextWithPalette(plainText(assert(labels.confirm)), confirm.labelAt.x, confirm.labelAt.y, palette)
  self._text:drawTextWithPalette(plainText(assert(labels.cancel)), cancel.labelAt.x, cancel.labelAt.y, palette)
  self:_drawSaleValues(presentation)
end

-- The toss confirmation retains its action/quantity base with the
-- selected-item panel while the modal prompt renderer owns both button
-- rows, and only while the controller reports the prompt open. The item
-- and amount travel in the lower message window, so no digit widgets,
-- quantity layers, or action-slot labels belong here.
---@param presentation table<string, unknown>
function BagRenderer:_drawTossPrompt(presentation)
  if presentation.yesNoPrompt == nil then
    return
  end
  local prompt = assert(self._promptRenderer, "the toss confirmation owns its modal prompt renderer")
  prompt:draw(presentation.yesNoPrompt)
end

-- Without a hero pane the state-specific contextual text would be lost, so
-- the constrained single-pane mode keeps it in the canonical fallback
-- region through the source Bag description frame and the generated
-- fallback text rectangle. This is the only mode where that fallback
-- surface is valid; two-pane modes already carry the same text in the hero
-- description rect. The source frame visual is a 256x192 visual whose frame
-- pixels sit at their generated source location, so it draws at the
-- canonical origin while text uses the generated text rectangle.
---@param presentation table<string, unknown>
---@param content table<string, unknown> the canonical logical content selecting compact fallbacks
---@param descriptionPalette table<string, unknown>
function BagRenderer:_drawConstrainedContextual(presentation, content, descriptionPalette)
  if content.heroVisible ~= false then
    return
  end
  if presentation.state == "description_overlay" then
    return
  end
  local contextual = compactContextualText(presentation)
  if contextual == nil then
    return
  end
  local graphics = self._graphics
  assert(content.descriptionFallback ~= nil, "the constrained layout carries its fallback frame")
  local textRect = assert(content.descriptionTextRect, "the constrained layout carries its fallback text rectangle")
  drawVisual(graphics, assert(self._visuals.descriptionFrame), 0, 0)
  setColor(graphics, WHITE)
  self:_drawPaletteLines(contextual, textRect.x, textRect.y, descriptionPalette, 3)
end

-- The move target cursor uses the source original-target visual while the
-- target equals the origin and the alternate valid-target visual
-- otherwise, drawn at the target cell's generated focus point. No
-- standalone confirm button exists.
---@param presentation table<string, unknown>
function BagRenderer:_drawMoveHighlight(presentation)
  assert(presentation.moveTarget ~= nil, "move selection carries its target")
  assert(presentation.visibleStart ~= nil, "the presentation carries its window start")
  local key = presentation.moveTarget == presentation.moveOrigin and "moveCursor:original" or "moveCursor:candidate"
  local focus = assert(self._manifest.interactive.focus, "the bag manifest must carry its focus visuals")
  local itemFocus = assert(focus.items, "the bag manifest carries its item focus")
  local targets = assert(itemFocus.targets, "the item focus carries its targets")
  assert(type(targets) == "table" and #targets == 6, "the item focus targets its six visible cells")
  local start = assert(presentation.visibleStart, "the presentation carries its window start")
  assert(type(start) == "number", "the bag view needs its window start")
  local cell = presentation.moveTarget - start + 1
  if cell < 1 or cell > 6 then
    return
  end
  local target = assert(targets[cell], "the move target resolves a focus target")
  drawVisual(
    self._graphics,
    assert(self._visuals[key], "the bag presentation names its move cursor"),
    target.x,
    target.y
  )
end

---@param presentation table<string, unknown>
---@param icons table<string, unknown>
---@param iconImage love.Image
function BagRenderer:_drawDescriptionOverlay(presentation, icons, iconImage)
  local graphics = self._graphics
  local manifest = self._manifest
  local frame = assert(manifest.interactive.overlays.descriptionFallback.frame, "the overlay needs its frame")
  local selected = assert(presentation.selected, "the description overlay needs its selected item")
  setColor(graphics, FALLBACK_COLORS.fill)
  graphics.rectangle("fill", frame.x, frame.y, frame.width, frame.height)
  setColor(graphics, FALLBACK_COLORS.border)
  graphics.rectangle("line", frame.x, frame.y, frame.width, frame.height)
  local iconKey = assert(selected.icon, "the overlay item carries an icon key")
  local quad = icons:quadFor(iconKey)
  local dims = icons:dimensions(iconKey)
  setColor(graphics, { 1, 1, 1, 1 })
  local handle = icons:handle()
  if handle ~= nil then
    ImageSampling.draw(graphics, handle, quad, frame.x + 4, frame.y + (frame.height - dims.height) / 2)
  else
    graphics.draw(iconImage, quad, frame.x + 4, frame.y + (frame.height - dims.height) / 2)
  end
  setColor(graphics, WHITE)
  assert(type(selected.name) == "string", "the overlay item carries a name")
  self._text:drawText(plainText(selected.name), frame.x + 44, frame.y + 2)
  assert(type(selected.description) == "string", "the overlay item carries a description")
  self:_drawLines(selected.description, frame.x + 44, frame.y + 2 + LINE_HEIGHT, 2)
  local hint = "B Back"
  self._text:drawText(hint, frame.x + frame.width - self._text:textWidth(hint) - 4, frame.y + frame.height - 14)
end

-- Resolves the current-state visuals for one bag status through the
-- shared image owner without blocking: enrolls every current path as
-- demand before the first readiness probe, promotes outstanding work
-- across bounded acquisition rounds, and swaps the installed leases only
-- once the whole replacement resolved. Soft one-step-ahead interest
-- drains after the current state installed and never gates readiness.
-- Returns true once the status is drawable. A superseded pending demand
-- is abandoned without uploading; a failed required visual fails loudly
-- while the installed state stays drawable.
---@param status table<string, unknown> the controller status selecting the demand
---@return boolean ready
function BagRenderer:prepare(status)
  assert(type(status) == "table", "the bag renderer requires a presentation")
  assert(self._pool ~= nil, "bag state preparation borrows its shared image owner")
  local ready = advanceDemand(self, status)
  return ready
end

-- Draws one presentation snapshot through the resolved plan with quads
-- from the icon provider. A closed presentation is a no-op. Each pane
-- draws through the shared logical scope under its own placement, so
-- icons, text, and cursors never escape their logical pane. The borrowed
-- 3D hero composites once at the full frame under the visible clip; the
-- canonical transform never applies twice. Restores the graphics color,
-- scissor, and transform state afterwards.
---@param presentation table<string, unknown>
---@param plan table<string, unknown> the resolved plan carrying panes and canonical content
---@param collaborators { icons: table<string, unknown> }
function BagRenderer:draw(presentation, plan, collaborators)
  assert(type(presentation) == "table", "the bag renderer requires a presentation")
  assert(type(plan) == "table", "the bag renderer requires its resolved plan")
  if not presentation.open then
    return
  end
  -- Only the admitted current signature paints: preparation resolved its
  -- leases during the update phase, so drawing performs no worker waits,
  -- polls, or acquisitions. A pending or superseded status paints nothing
  -- instead of a partial menu while the field keeps rendering beneath it.
  if self._readySignature ~= demandSignature(presentation) then
    return
  end
  local icons = assert(collaborators and collaborators.icons, "occupied cells need the icon provider")
  local content = assert(plan.content, "the bag plan carries its canonical content")
  local panes = assert(plan.panes, "the bag plan orders its panes")
  local heroPane
  local interactivePane
  for _, pane in ipairs(panes) do
    if pane.interactive then
      assert(interactivePane == nil, "the bag plan carries exactly one interactive pane")
      interactivePane = pane
    else
      assert(heroPane == nil, "the bag plan carries at most one hero pane")
      heroPane = pane
    end
  end
  local interactive = assert(interactivePane, "every plan places the interactive pane")
  local graphics = self._graphics
  local palettes = self:_palettes()
  graphics.push("all")
  if heroPane ~= nil then
    local hero = assert(heroPane.placement, "the hero pane carries its placement")
    LogicalSurface.draw(graphics, hero, function()
      self:_drawHeroBackground(presentation)
    end)
    local heroRenderer = assert(self._heroRenderer, "the hero pane borrows its model renderer")
    heroRenderer:draw(
      assert(presentation.heroGender, "the bag presentation names its hero gender"),
      assert(presentation.hero, "the bag presentation carries its hero status"),
      hero
    )
    LogicalSurface.draw(graphics, hero, function()
      self:_drawHeroForeground(presentation, palettes.description)
    end)
  end
  local placement = assert(interactive.placement, "the interactive pane carries its placement")
  LogicalSurface.draw(graphics, placement, function()
    self:_drawInteractive(presentation, icons, content, palettes)
  end)
  graphics.pop()
end

function BagRenderer:release()
  local pool = assert(self._pool, "bag state visuals borrow their shared image owner")
  local pending = self._pending
  self._pending = nil
  if pending ~= nil then
    abandonPending(pool, pending)
  end
  local leases = self._readyLeases
  self._readyLeases = {}
  self._readySignature = nil
  for _, lease in ipairs(leases) do
    pool:release(lease)
  end
  self._images = {}
  self._visuals = {}
  -- Demand visuals arrive as borrowed leases returned above; only the small
  -- fixed prompt chrome below stays renderer-owned.
  local promptRenderer = self._promptRenderer
  self._promptRenderer = nil
  if promptRenderer ~= nil then
    promptRenderer:release()
  end
  -- The shared window renderer is a borrowed collaborator owned by field
  -- presentation resources: this releases it never, only drops the reference.
  self._window = nil
end

return BagRenderer
