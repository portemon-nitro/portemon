-- Cross-system visual proof for the native party screen: egg cards
-- print names without battle detail, status art uses its compiled frame,
-- line, context menus render one row per entry across counts, mid-swap
-- frames differ from steady state while the exchanged frame matches the
-- swapped records, and panes magnify uniformly across host scales with
-- slot geometry inverting consistently. Real manifests, real digit
-- glyphs, and fixture icons through the production renderer; assertions
-- are painted-pixel relationships inside manifest subrects, never goldens.
-- Deferred capabilities (contests, storage, battles) have no visuals here.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local PreparedMonIcons = require("tests.support.PreparedMonIcons")
local PartyCache = require("libs.assets.src.PartyCache")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local PartyScreenRenderer = require("libs.hgss.src.ui.PartyScreenRenderer")
local PixelScale = require("libs.ui.src.PixelScale")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local marker = cacheFs:read(PartyCache.markerPath())
      if marker ~= nil and PartyCache.isReady(cacheFs, marker) then
        versions[#versions + 1] = versionId
      end
    end
  end
  return versions
end

local function manifestFor(versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local manifest = PartyCache.loadManifest(cacheFs)
  Assert.equal(manifest.schema, "g4-party-presentation-v5", versionId .. " renders the current party manifest")
  return cacheFs, manifest
end

---@param slot0 integer
---@param overrides table<string, any>?
---@return table<string, any>
local function slot(slot0, overrides)
  local record = {
    slot = slot0,
    occupied = false,
    eligible = false,
    isEgg = false,
    heldItem = "NONE",
    capsule = nil,
    moves = {},
    shinyLeaves = 0,
  }
  if overrides ~= nil then
    record.occupied = true
    record.eligible = true
    record.iconKey = "MON0/f0"
    record.displayName = "MON" .. slot0
    record.level = 5
    record.gender = "male"
    record.status = "ok"
    record.currentHp = 20
    record.maxHp = 20
    record.hpFraction = 1
    for key, value in pairs(overrides) do
      record[key] = value
    end
  end
  return record
end

---@param overrides table<string, any>?
---@return table<string, any>
local function presentation(overrides)
  local status = {
    open = true,
    context = "browse",
    state = "browse",
    cursorNode = 0,
    menuIndex = nil,
    menu = nil,
    menuSlot = nil,
    message = nil,
    swap = nil,
    anim = { tick = 0, sequences = {}, sequenceTicks = {}, panelSlide = 0 },
    infoOverlay = false,
    view = { revision = 1, slots = {} },
    cancellable = true,
  }
  status.view.slots[1] = slot(0, {})
  status.view.slots[2] = slot(1, { status = "poison", currentHp = 4, maxHp = 20, hpFraction = 0.2 })
  for index = 3, 6 do
    status.view.slots[index] = slot(index - 1)
  end
  for index = 1, 6 do
    status.anim.sequences[index] = 1
    status.anim.sequenceTicks[index] = 0
  end
  for key, value in pairs(overrides or {}) do
    status[key] = value
  end
  return status
end

---@param value number
---@return integer
local function quantize(value)
  return math.floor(value * 255 + 0.5)
end

local function backgroundOf(image)
  local r0, g0, b0 = image:getPixel(0, 0)
  return quantize(r0), quantize(g0), quantize(b0)
end

local function activityIn(image, cornerR, cornerG, cornerB, x0, y0, width, height)
  local other = 0
  local seen = {}
  local distinct = 0
  for y = y0, y0 + height - 1 do
    for x = x0, x0 + width - 1 do
      local r, g, b = image:getPixel(x, y)
      local qr, qg, qb = quantize(r), quantize(g), quantize(b)
      if qr ~= cornerR or qg ~= cornerG or qb ~= cornerB then
        other = other + 1
        local key = qr * 65536 + qg * 256 + qb
        if not seen[key] then
          seen[key] = true
          distinct = distinct + 1
        end
      end
    end
  end
  return other, distinct
end

local function sourceImage(scope, cacheFs, visual)
  local bytes = assert(cacheFs:read(visual.image), "the generated Party visual is present")
  local fileData = love.filesystem.newFileData(bytes, visual.image)
  return scope:own(love.image.newImageData(fileData))
end

local function matchingOpaquePixels(rendered, source, x0, y0, width, height)
  local matches = 0
  local opaque = 0
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local sr, sg, sb, sa = source:getPixel(x, y)
      if quantize(sa) == 255 then
        opaque = opaque + 1
        local rr, rg, rb, ra = rendered:getPixel(x0 + x, y0 + y)
        if
          quantize(rr) == quantize(sr)
          and quantize(rg) == quantize(sg)
          and quantize(rb) == quantize(sb)
          and quantize(ra) == 255
        then
          matches = matches + 1
        end
      end
    end
  end
  return matches, opaque
end

local function renderPane(scope, cacheFs, manifest, status, width, height)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  local layout = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
  local provider = scope:own(PreparedMonIcons.preparedProvider(PreparedMonIcons.iconCache(), { "MON0/f0" }))
  local renderer =
    PartyScreenRenderer.new({ graphics = love.graphics, cacheFs = cacheFs, manifest = manifest, text = text })
  local canvas = scope:own(love.graphics.newCanvas(width or 256, height or 192))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:draw(status, layout, provider)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData()), layout
end

-- Egg cards print the name while the HP number rect skips numerals:
-- the same panel renders different number-rect content for an egg
-- than for a healthy mon, and the egg name still paints.
function T.egg_cards_print_names_without_battle_detail(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local healthy, _ = renderPane(scope, cacheFs, manifest, presentation())
    local cornerR, cornerG, cornerB = backgroundOf(healthy)
    local number = assert(manifest.panels[1].hp.number, versionId .. " carries the HP number subrect")
    local leadDigits, _ =
      activityIn(healthy, cornerR, cornerG, cornerB, number.x, number.y, number.width, number.height)
    Assert.isTrue(leadDigits > 4, versionId .. " paints HP glyphs for the healthy lead")
    local egged = presentation()
    egged.view.slots[1] = slot(0, { isEgg = true, displayName = "EGGY" })
    local eggImage, _ = renderPane(scope, cacheFs, manifest, egged)
    local delta = 0
    for y = number.y, number.y + number.height - 1 do
      for x = number.x, number.x + number.width - 1 do
        local r1, g1, b1 = healthy:getPixel(x, y)
        local r2, g2, b2 = eggImage:getPixel(x, y)
        if quantize(r1) ~= quantize(r2) or quantize(g1) ~= quantize(g2) or quantize(b1) ~= quantize(b2) then
          delta = delta + 1
        end
      end
    end
    Assert.isTrue(delta > 4, versionId .. " renders different number content for the egg")
    local eggName = assert(manifest.panels[1].text.name, versionId .. " carries the name subrect")
    local namePaint =
      activityIn(eggImage, cornerR, cornerG, cornerB, eggName.x, eggName.y, eggName.width, eggName.height)
    Assert.isTrue(namePaint > 4, versionId .. " still paints the egg name")
  end
end

-- Poison paints the compiled PSN sprite at the generated status rectangle;
-- level digits remain in their own panel subrect.
function T.status_uses_its_generated_sprite_frame(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local image, _ = renderPane(scope, cacheFs, manifest, presentation())
    local panel = manifest.panels[2]
    local rect = panel.statusRect
    local source = sourceImage(scope, cacheFs, manifest.visuals.status.poison)
    local matches, opaque = matchingOpaquePixels(image, source, rect.x, rect.y, rect.width, rect.height)
    Assert.isTrue(opaque > 4, versionId .. " compiles visible poison status pixels")
    Assert.equal(matches, opaque, versionId .. " draws the generated poison frame without tinting")
    local levelRect = assert(panel.text.level, versionId .. " carries its independent level subrect")
    local cornerR, cornerG, cornerB = backgroundOf(image)
    local levelPaint = activityIn(image, cornerR, cornerG, cornerB, levelRect.x, levelRect.y, levelRect.width, levelRect.height)
    Assert.isTrue(levelPaint > 2, versionId .. " keeps level numerals separate from status art")
  end
end

-- Context menus resolve one generated button record per entry: every
-- supported count carries per-entry frame/text rectangles inside the
-- native pane, and the eight-entry render paints different button pixels
-- than the two-entry render.
function T.context_menus_render_one_row_per_entry(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local layout = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
    for _, count in ipairs({ 2, 3, 5, 8 }) do
      local entries = layout.menuLayout("topLevel", count)
      Assert.equal(#entries, count, versionId .. " lays out one record per entry for " .. tostring(count))
      for index, entry in ipairs(entries) do
        for _, rect in ipairs({ entry.frameRect, entry.textRect }) do
          Assert.isTrue(
            rect.x >= 0
              and rect.y >= 0
              and rect.x + rect.width <= 256
              and rect.y + rect.height <= 192,
            versionId .. " keeps entry " .. tostring(index) .. " geometry inside the native pane"
          )
        end
      end
    end
    local twoEntries = {
      { kind = "summary", label = "SUMMARY" },
      { kind = "quit", label = "QUIT" },
    }
    local eightEntries = {
      { kind = "summary", label = "SUMMARY" },
      { kind = "switch", label = "SWITCH" },
      { kind = "item", label = "ITEM" },
      { kind = "f1", label = "F1" },
      { kind = "f2", label = "F2" },
      { kind = "f3", label = "F3" },
      { kind = "f4", label = "F4" },
      { kind = "quit", label = "QUIT" },
    }
    local function renderWindow(entries)
      local status = presentation({ state = "context", menu = entries, menuIndex = 1, menuSlot = 0 })
      local image, _ = renderPane(scope, cacheFs, manifest, status)
      return image
    end
    local twoImage = renderWindow(twoEntries)
    local eightImage = renderWindow(eightEntries)
    -- Button placement differs by count, so the renders differ across
    -- the union of both layouts' frame rectangles.
    local frames = {}
    for _, entries in ipairs({
      manifest.contextMenu.topLevel[2],
      manifest.contextMenu.topLevel[8],
    }) do
      for _, entry in ipairs(entries) do
        frames[#frames + 1] = entry.frameRect
      end
    end
    local delta = 0
    for _, rect in ipairs(frames) do
      for y = rect.y, rect.y + rect.height - 1 do
        for x = rect.x, rect.x + rect.width - 1 do
          local r1, g1, b1 = twoImage:getPixel(x, y)
          local r2, g2, b2 = eightImage:getPixel(x, y)
          if quantize(r1) ~= quantize(r2) or quantize(g1) ~= quantize(g2) or quantize(b1) ~= quantize(b2) then
            delta = delta + 1
          end
        end
      end
    end
    Assert.isTrue(delta > 20, versionId .. " paints different button content for eight entries than two")
  end
end

-- Mid-swap frames differ from steady state while the exchanged frame
-- matches the swapped records: the visual commit follows the domain
-- commit instead of anticipating it. The cursor stays hidden while a
-- swap record exists, so both compared frames suppress it to assert
-- panel and sprite content rather than cursor state.
function T.swap_midpoint_differs_from_committed(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local steady, _ = renderPane(scope, cacheFs, manifest, presentation())
    local mid, _ = renderPane(
      scope,
      cacheFs,
      manifest,
      presentation({
        swap = {
          source = 0,
          destination = 1,
          xOffset = 2,
          offsets = { [0] = -16, [1] = 16 },
          directions = { [0] = -1, [1] = 1 },
          exchanged = false,
        },
      })
    )
    local function difference(a, b)
      local delta = 0
      for y = 0, 191 do
        for x = 0, 255 do
          local r1, g1, b1 = a:getPixel(x, y)
          local r2, g2, b2 = b:getPixel(x, y)
          if quantize(r1) ~= quantize(r2) or quantize(g1) ~= quantize(g2) or quantize(b1) ~= quantize(b2) then
            delta = delta + 1
          end
        end
      end
      return delta
    end
    Assert.isTrue(difference(steady, mid) > 100, versionId .. " offsets panels mid-swap")
    local swapped = presentation()
    swapped.view.slots[1], swapped.view.slots[2] = swapped.view.slots[2], swapped.view.slots[1]
    swapped.cursorNode = nil
    local committed, _ = renderPane(scope, cacheFs, manifest, swapped)
    local exchangedStatus = presentation({
      swap = {
        source = 0,
        destination = 1,
        xOffset = 0,
        offsets = { [0] = 0, [1] = 0 },
        directions = { [0] = -1, [1] = 1 },
        exchanged = true,
      },
    })
    exchangedStatus.cursorNode = nil
    local exchanged, _ = renderPane(scope, cacheFs, manifest, exchangedStatus)
    Assert.isTrue(difference(steady, exchanged) > 100, versionId .. " shows swapped records after commit")
    Assert.equal(
      difference(committed, exchanged),
      0,
      versionId .. " renders the exchanged frame exactly like the swapped records"
    )
  end
end

-- Panes magnify uniformly across host scales and slot geometry inverts
-- consistently: doubled host coordinates are twice the single-scale ones.
function T.panes_magnify_uniformly_with_consistent_hit_geometry(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local image, layout = renderPane(scope, cacheFs, manifest, presentation())
    local cornerR, cornerG, cornerB = backgroundOf(image)
    local single = activityIn(image, cornerR, cornerG, cornerB, 0, 0, 128, 48)
    Assert.isTrue(single > 20, versionId .. " paints the lead panel at single scale")
    local doubled = scope:own(love.graphics.newCanvas(512, 384))
    love.graphics.setCanvas(doubled)
    love.graphics.clear(0, 0, 0, 0)
    local placement = assert(
      PixelScale.placeFixed({ x = 0, y = 0, width = 512, height = 384 }, 256, 192),
      "the doubled canvas fits its single pane"
    )
    local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
    local provider = scope:own(PreparedMonIcons.preparedProvider(PreparedMonIcons.iconCache(), { "MON0/f0" }))
    local renderer =
      PartyScreenRenderer.new({ graphics = love.graphics, cacheFs = cacheFs, manifest = manifest, text = text })
    LogicalSurface.draw(love.graphics, placement, function()
      renderer:draw(presentation(), layout, provider)
    end)
    love.graphics.setCanvas()
    local doubledImage = scope:own(doubled:newImageData())
    local dr, dg, db = doubledImage:getPixel(0, 0)
    local dCornerR, dCornerG, dCornerB = quantize(dr), quantize(dg), quantize(db)
    local scaled = activityIn(doubledImage, dCornerR, dCornerG, dCornerB, 0, 0, 256, 96)
    Assert.isTrue(scaled > single * 2, versionId .. " paints substantially more panel pixels doubled")
    -- Slot centers invert to host coordinates at twice the single-scale
    -- values through the same placement the renderer uses.
    local rect = assert(layout.slotRects[1], versionId .. " places the lead slot")
    local hx, hy = LayoutGeometry.logicalToHost(placement, rect.x + 8, rect.y + 8)
    Assert.notNil(hx, versionId .. " inverts the lead slot center to host coordinates")
    Assert.notNil(hy, versionId .. " inverts the lead slot center to host coordinates")
  end
end

-- Source-shaped menus through the real v3 bundle: the eight-entry menu
-- draws one generated button frame per entry with the focused entry
-- selected, and the press gate shows the pressed frame before the
-- selected one. Frame rectangles and shapes come from the manifest at
-- runtime, so no source geometry is baked into the suite.
local function menuPresentation(entries, menuIndex, overrides)
  local status = presentation({
    state = "context",
    menu = entries,
    menuIndex = menuIndex,
    menuSlot = 0,
  })
  for key, value in pairs(overrides or {}) do
    status[key] = value
  end
  return status
end

local function eightEntries()
  return {
    { kind = "summary", label = "SUMMARY" },
    { kind = "switch", label = "SWITCH" },
    { kind = "item", label = "ITEM" },
    { kind = "f1", label = "F1" },
    { kind = "f2", label = "F2" },
    { kind = "f3", label = "F3" },
    { kind = "f4", label = "F4" },
    { kind = "quit", label = "QUIT" },
  }
end

local function frameVisual(manifest, shape, state)
  local frames = assert(manifest.contextMenu.frames, "the manifest carries menu frames")
  local group = assert(frames[shape], "the manifest carries the " .. shape .. " frame")
  return assert(group[state], "the manifest carries the " .. state .. " frame")
end

function T.large_menus_draw_one_generated_button_per_entry(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local entries = eightEntries()
    local status = menuPresentation(entries, 3)
    local image, _ = renderPane(scope, cacheFs, manifest, status)
    local generated = assert(manifest.contextMenu.topLevel[8], versionId .. " carries the eight-entry layout")
    Assert.equal(#generated, 8, versionId .. " lays out eight generated entries")
    local matched = 0
    for index, entry in ipairs(generated) do
      local rect = assert(entry.frameRect, versionId .. " carries entry frame rectangles")
      local want = index == 3 and "selected" or "raised"
      local visual = frameVisual(manifest, entry.frameShape, want)
      local source = sourceImage(scope, cacheFs, visual)
      local matches, opaque = matchingOpaquePixels(image, source, rect.x, rect.y, rect.width, rect.height)
      Assert.isTrue(opaque > 100, versionId .. " compiles visible frame pixels for entry " .. index)
      if matches == opaque then
        matched = matched + 1
      end
    end
    Assert.equal(matched, 8, versionId .. " draws every entry through its generated button frame")
  end
end

function T.press_gate_shows_pressed_before_selected(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local generated = assert(manifest.contextMenu.topLevel[3], versionId .. " carries the three-entry layout")
    local first = assert(generated[1], versionId .. " carries its first entry")
    local rect = assert(first.frameRect, versionId .. " carries entry frame rectangles")
    local entries = {
      { kind = "summary", label = "SUMMARY" },
      { kind = "switch", label = "SWITCH" },
      { kind = "quit", label = "QUIT" },
    }
    local pressing = menuPresentation(entries, 1, { menuPress = { index = 1, phase = "pressed" } })
    local pressingImage, _ = renderPane(scope, cacheFs, manifest, pressing)
    local pressedVisual = frameVisual(manifest, first.frameShape, "pressed")
    local pressedSource = sourceImage(scope, cacheFs, pressedVisual)
    local pressedMatches, pressedOpaque =
      matchingOpaquePixels(pressingImage, pressedSource, rect.x, rect.y, rect.width, rect.height)
    Assert.isTrue(pressedOpaque > 100, versionId .. " compiles visible pressed-frame pixels")
    Assert.equal(
      pressedMatches,
      pressedOpaque,
      versionId .. " shows the pressed frame through the first press half"
    )
    local holding = menuPresentation(entries, 1, { menuPress = { index = 1, phase = "selected" } })
    local holdingImage, _ = renderPane(scope, cacheFs, manifest, holding)
    local selectedVisual = frameVisual(manifest, first.frameShape, "selected")
    local selectedSource = sourceImage(scope, cacheFs, selectedVisual)
    local selectedMatches, selectedOpaque =
      matchingOpaquePixels(holdingImage, selectedSource, rect.x, rect.y, rect.width, rect.height)
    Assert.equal(
      selectedMatches,
      selectedOpaque,
      versionId .. " shows the selected frame through the second press half"
    )
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets = { "party:global" }
return suite
