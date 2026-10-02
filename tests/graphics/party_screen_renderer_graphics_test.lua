-- Graphics coverage for Party pane composition, source visuals, generated
-- geometry, and the detail slide through the real renderer and icon provider.
-- Pixel checks pin relationships, not copyrighted screenshots.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
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

---@param value number
---@return integer
local function quantize(value)
  return math.floor(value * 255 + 0.5)
end

---@param data love.ImageData
---@param cornerR integer
---@param cornerG integer
---@param cornerB integer
---@param x0 integer
---@param y0 integer
---@param width integer
---@param height integer
---@return integer other
---@return integer distinct
local function scanRegion(data, cornerR, cornerG, cornerB, x0, y0, width, height)
  local other = 0
  local seen = {}
  local distinct = 0
  for y = y0, y0 + height - 1 do
    for x = x0, x0 + width - 1 do
      local r, g, b = data:getPixel(x, y)
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

local function visualPixels(scope, cacheFs, visual)
  local bytes = assert(cacheFs:read(visual.image), "the generated Party visual is present")
  local fileData = love.filesystem.newFileData(bytes, visual.image)
  return scope:own(love.image.newImageData(fileData))
end

local function matchingOpaquePixels(rendered, source, sourceX, sourceY, x0, y0, width, height)
  local matches = 0
  local opaque = 0
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local sr, sg, sb, sa = source:getPixel(sourceX + x, sourceY + y)
      if quantize(sa) == 255 then
        opaque = opaque + 1
        local rr, rg, rb, ra = rendered:getPixel(x0 + x, y0 + y)
        if quantize(rr) == quantize(sr) and quantize(rg) == quantize(sg) and quantize(rb) == quantize(sb) then
          if quantize(ra) == 255 then
            matches = matches + 1
          end
        end
      end
    end
  end
  return matches, opaque
end

local function differingPixels(left, right, x0, y0, width, height)
  local differences = 0
  for y = y0, y0 + height - 1 do
    for x = x0, x0 + width - 1 do
      local lr, lg, lb = left:getPixel(x, y)
      local rr, rg, rb = right:getPixel(x, y)
      if quantize(lr) ~= quantize(rr) or quantize(lg) ~= quantize(rg) or quantize(lb) ~= quantize(rb) then
        differences = differences + 1
      end
    end
  end
  return differences
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
    heldItemName = "None",
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

local function renderPane(scope, cacheFs, manifest, status)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  local layout = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
  local provider = scope:own(PreparedMonIcons.preparedProvider(PreparedMonIcons.iconCache(), { "MON0/f0" }))
  local renderer =
    PartyScreenRenderer.new({ graphics = love.graphics, cacheFs = cacheFs, manifest = manifest, text = text })
  local canvas = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:draw(status, layout, provider)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData()), layout
end

local function renderDetailPane(scope, cacheFs, manifest, status)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  local layout = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
  local provider = scope:own(PreparedMonIcons.preparedProvider(PreparedMonIcons.iconCache(), { "MON0/f0" }))
  local renderer =
    PartyScreenRenderer.new({ graphics = love.graphics, cacheFs = cacheFs, manifest = manifest, text = text })
  local canvas = scope:own(love.graphics.newCanvas(600, 440))
  local hostPlacement = assert(
    PixelScale.placeFixed({ x = 20, y = 12, width = 512, height = 384 }, 256, 192),
    "the detail pane fits at an offset two-times host placement"
  )
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  LogicalSurface.draw(love.graphics, hostPlacement, function()
    renderer:drawPane(status, {
      id = "detail",
      placement = { logicalWidth = 256, logicalHeight = 192 },
    }, layout, provider)
  end)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData()), hostPlacement
end

function T.party_view_paints_frame_slots_icons_hp_and_cursor(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
    for _, size in ipairs({ { width = 320, height = 240 }, { width = 640, height = 480 } }) do
      local layout = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
      local provider = PreparedMonIcons.preparedProvider(PreparedMonIcons.iconCache(), { "MON0/f0" })
      local renderer =
        PartyScreenRenderer.new({ graphics = love.graphics, cacheFs = cacheFs, manifest = manifest, text = text })
      local canvas = scope:own(love.graphics.newCanvas(size.width, size.height))
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      renderer:draw(presentation(), layout, provider)
      love.graphics.setCanvas()
      local image = scope:own(canvas:newImageData())
      local lead = layout.slotRects[1]
      -- Region scans, not single pixels: panel art carries
      -- transparent corners, so the probes stay clear of the edges.
      local painted, _ = scanRegion(image, 0, 0, 0, lead.x + 8, lead.y + 8, lead.width - 16, 32)
      Assert.isTrue(painted > 100, versionId .. " the lead slot paints its chrome")
      -- The lead icon comes from the red fixture atlas.
      local iconRed = 0
      for y = lead.y, lead.y + lead.height - 1 do
        for x = lead.x, lead.x + lead.width - 1 do
          local ir, ig, ib = image:getPixel(x, y)
          if ir > 0.7 and ig < 0.3 and ib < 0.3 then
            iconRed = iconRed + 1
          end
        end
      end
      Assert.isTrue(iconRed > 10, versionId .. " the icon quad draws inside the lead slot")
      -- The damaged second slot paints the compiled red strip.
      local bar = manifest.panels[2].hp.bar
      local redStrip = visualPixels(scope, cacheFs, manifest.visuals.hpBars.red)
      local redMatches = matchingOpaquePixels(image, redStrip, 0, 0, bar.x, bar.y + 2, 9, 4)
      Assert.equal(redMatches, 36, versionId .. " low HP uses the generated four-row red strip")
      provider:release()
    end
  end
end

-- The upper left strip is uncovered by the staggered slot panels, so it
-- proves that the content backdrop is composed independently of card art.
-- An unoccupied card also must not reuse the normal occupied chrome.
function T.backdrop_and_empty_slot_use_their_generated_visuals(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local image, layout = renderPane(scope, cacheFs, manifest, presentation())
    local cornerR, cornerG, cornerB = 0, 0, 0
    local backdropPixels = scanRegion(image, cornerR, cornerG, cornerB, 128, 0, 128, 8)
    Assert.isTrue(backdropPixels > 10, versionId .. " paints the uncovered main-backdrop strip")

    local auxiliary = manifest.visuals.auxPanel
    local panelOrigin = manifest.panels[3].origin
    Assert.equal(auxiliary.width, 128, versionId .. " publishes canonical empty-panel width")
    Assert.equal(auxiliary.height, 48, versionId .. " publishes canonical empty-panel height")
    local emptyRect = layout.slotRects[3]
    local auxiliaryPixels = visualPixels(scope, cacheFs, auxiliary)
    local auxiliaryMatches =
      matchingOpaquePixels(image, auxiliaryPixels, 0, 0, emptyRect.x, emptyRect.y, auxiliary.width, auxiliary.height)
    Assert.isTrue(auxiliaryMatches > 100, versionId .. " composes the generated empty-panel art")
    local panelPixels = scanRegion(
      image,
      cornerR,
      cornerG,
      cornerB,
      emptyRect.x + 8,
      emptyRect.y + 8,
      emptyRect.width - 16,
      emptyRect.height - 16
    )
    Assert.isTrue(panelPixels > 100, versionId .. " paints a source empty-slot panel")
    Assert.deepEqual(
      { emptyRect.x, emptyRect.y },
      { panelOrigin.x, panelOrigin.y },
      versionId .. " places the empty panel at its generated origin"
    )
  end
end

-- A provider icon's painted bounds must be centered on the source anchor;
-- this checks geometry rather than a copyrighted screenshot.
function T.pokemon_icons_are_centered_on_generated_anchors(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local status = presentation({ cursorNode = 5 })
    local image, _ = renderPane(scope, cacheFs, manifest, status)
    local noIcon = presentation({ cursorNode = 5 })
    noIcon.view.slots[1] = slot(0)
    local background, _ = renderPane(scope, cacheFs, manifest, noIcon)
    local anchor = manifest.panels[1].iconAnchor
    local minX, minY, maxX, maxY
    for y = 0, 63 do
      for x = 0, 63 do
        local r, g, b = image:getPixel(x, y)
        local br, bg, bb = background:getPixel(x, y)
        if
          (quantize(r) ~= quantize(br) or quantize(g) ~= quantize(bg) or quantize(b) ~= quantize(bb))
          and r > 0.7
          and g < 0.3
          and b < 0.3
        then
          minX = minX and math.min(minX, x) or x
          minY = minY and math.min(minY, y) or y
          maxX = maxX and math.max(maxX, x) or x
          maxY = maxY and math.max(maxY, y) or y
        end
      end
    end
    Assert.notNil(minX, versionId .. " paints the fixture Pokémon icon")
    Assert.deepEqual(
      { minX + 16, minY + 16 },
      { anchor.x, anchor.y },
      versionId .. " centers the provider-sized icon on its generated anchor"
    )
  end
end

function T.focus_uses_selected_panel_chrome(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local focused = presentation({ cursorNode = 0 })
    local image, _ = renderPane(scope, cacheFs, manifest, focused)
    local panel = manifest.panels[1]
    local selected = visualPixels(scope, cacheFs, panel.chrome.selected)
    local matches = matchingOpaquePixels(image, selected, 64, 0, 64, 0, 40, 8)
    Assert.isTrue(matches > 50, versionId .. " paints selected chrome beneath the focused cursor")

    local focusCursor = manifest.visuals.cursor.sequences[panel.cursorSequence].frames[1]
    local cursorPixels = visualPixels(scope, cacheFs, focusCursor)
    local cursorAnchor = manifest.navigation.dpad.default[1]
    local cursorMatches = matchingOpaquePixels(
      image,
      cursorPixels,
      0,
      0,
      cursorAnchor.left + (focusCursor.offset and focusCursor.offset.x or 0),
      cursorAnchor.top + (focusCursor.offset and focusCursor.offset.y or 0),
      focusCursor.width,
      focusCursor.height
    )
    Assert.isTrue(cursorMatches > 4, versionId .. " paints the slot selector at its generated dpad anchor")
    local ballFrame = manifest.visuals.balls.sequences[2].frames[1]
    local ballPixels = visualPixels(scope, cacheFs, ballFrame)
    local ballAnchor = panel.ballAnchor
    local ballMatches = matchingOpaquePixels(
      image,
      ballPixels,
      0,
      0,
      ballAnchor.x + (ballFrame.offset and ballFrame.offset.x or 0),
      ballAnchor.y + (ballFrame.offset and ballFrame.offset.y or 0),
      ballFrame.width,
      ballFrame.height
    )
    Assert.isTrue(ballMatches > 4, versionId .. " paints the selected ball sequence at its generated anchor")

    local fainted = presentation({ cursorNode = 0 })
    fainted.view.slots[1] = slot(0, { status = "faint", currentHp = 0, maxHp = 20, hpFraction = 0 })
    local faintedImage, _ = renderPane(scope, cacheFs, manifest, fainted)
    local selectedFainted = visualPixels(scope, cacheFs, panel.chrome.selectedFainted)
    local faintMatches = matchingOpaquePixels(faintedImage, selectedFainted, 64, 0, 64, 0, 40, 8)
    Assert.isTrue(faintMatches > 50, versionId .. " paints selected-fainted chrome beneath the focused cursor")
  end
end

function T.cancel_focus_uses_the_generated_button_without_a_slot_cursor(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local focused = presentation({ cursorNode = "cancel" })
    local image, layout = renderPane(scope, cacheFs, manifest, focused)
    local buttonSequence = assert(manifest.visuals.buttons.sequences[2], versionId .. " carries focused Cancel art")
    local frame = assert(buttonSequence.frames[1], versionId .. " carries the focused Cancel frame")
    local button = visualPixels(scope, cacheFs, frame)
    local anchor = manifest.controls.cancel.anchor
    local drawX = anchor.x + (frame.offset and frame.offset.x or 0)
    local drawY = anchor.y + (frame.offset and frame.offset.y or 0)
    local drawW = math.min(frame.width, 256 - drawX)
    local drawH = math.min(frame.height, 192 - drawY)
    -- The generated Cancel label owns its text band over the button, so
    -- the frame-pixel proof covers the rows above and below that band;
    -- the label itself is proved through the unit suite.
    local labelRect = assert(manifest.controls.cancel.textRect, versionId .. " carries the Cancel text rectangle")
    Assert.deepEqual(
      labelRect,
      { x = 208, y = 168, width = 40, height = 16 },
      versionId .. " generates the Party Cancel text window from its source geometry"
    )
    local topH = math.max(labelRect.y - drawY, 0)
    local bottomY = math.max(labelRect.y + labelRect.height - drawY, 0)
    local totalMatches, totalOpaque = 0, 0
    if topH > 0 then
      local matches, opaque = matchingOpaquePixels(image, button, 0, 0, drawX, drawY, drawW, topH)
      totalMatches, totalOpaque = totalMatches + matches, totalOpaque + opaque
    end
    if bottomY < drawH then
      local matches, opaque =
        matchingOpaquePixels(image, button, 0, bottomY, drawX, drawY + bottomY, drawW, drawH - bottomY)
      totalMatches, totalOpaque = totalMatches + matches, totalOpaque + opaque
    end
    Assert.isTrue(
      totalOpaque > 4 and totalMatches == totalOpaque,
      versionId .. " paints every visible opaque Cancel pixel at its generated anchor outside the label band"
    )
    local rect = assert(layout.cancelRect, versionId .. " exposes the Cancel hit target")
    local cursor = visualPixels(scope, cacheFs, manifest.visuals.cursor.sequences[1].frames[1])
    local cursorMatches = matchingOpaquePixels(image, cursor, 0, 0, rect.x, rect.y, 8, 8)
    Assert.isTrue(cursorMatches < 4, versionId .. " does not paint the slot cursor over Cancel")
  end
end

function T.status_and_hp_use_source_shaped_visuals(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local poisoned = presentation()
    poisoned.view.slots[2] = slot(1, { status = "poison", currentHp = 4, maxHp = 20, hpFraction = 0.2 })
    local lowHp, layout = renderPane(scope, cacheFs, manifest, poisoned)
    local healthy = presentation()
    healthy.view.slots[2] = slot(1, { status = "ok", currentHp = 0, maxHp = 20, hpFraction = 0 })
    local noHp, _ = renderPane(scope, cacheFs, manifest, healthy)
    local panel = manifest.panels[2]
    local statusRect = panel.statusRect
    local statusDifferences =
      differingPixels(lowHp, noHp, statusRect.x, statusRect.y, statusRect.width, statusRect.height)
    Assert.isTrue(statusDifferences > 4, versionId .. " paints status art in the generated status rectangle")
    local bar = panel.hp.bar
    local rowChanges = {}
    for y = 0, bar.height - 1 do
      for x = 0, bar.width - 1 do
        local r1, g1, b1 = lowHp:getPixel(bar.x + x, bar.y + y)
        local r2, g2, b2 = noHp:getPixel(bar.x + x, bar.y + y)
        if quantize(r1) ~= quantize(r2) or quantize(g1) ~= quantize(g2) or quantize(b1) ~= quantize(b2) then
          rowChanges[y + 1] = true
        end
      end
    end
    Assert.isTrue(
      rowChanges[3] and rowChanges[4] and rowChanges[5] and rowChanges[6],
      versionId .. " paints four HP rows"
    )
    Assert.isFalse(
      rowChanges[1] or rowChanges[2] or rowChanges[7] or rowChanges[8],
      versionId .. " leaves HP trough rows clear"
    )
    Assert.equal(layout.slotRects[2].x, panel.origin.x, versionId .. " keeps status geometry pane-local")
  end
end

function T.mail_and_capsule_draw_at_generated_indicator_anchors(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local mailStatus = presentation()
    mailStatus.view.slots[2] = slot(1, {
      heldItem = "GRASS_MAIL",
      heldItemName = "Mail",
      heldMarkerKind = "mail",
    })
    local mailImage = renderPane(scope, cacheFs, manifest, mailStatus)
    local mailFrame = assert(manifest.visuals.held.sequences[2].frames[1], versionId .. " carries its mail visual")
    local mailAnchor = assert(manifest.panels[2].heldAnchor, versionId .. " carries the held marker anchor")
    local mailSource = visualPixels(scope, cacheFs, mailFrame)
    local mailMatches, mailOpaque = matchingOpaquePixels(
      mailImage,
      mailSource,
      0,
      0,
      mailAnchor.x + (mailFrame.offset and mailFrame.offset.x or 0),
      mailAnchor.y + (mailFrame.offset and mailFrame.offset.y or 0),
      mailFrame.width,
      mailFrame.height
    )
    Assert.isTrue(mailOpaque > 0, versionId .. " compiles visible mail marker pixels")
    Assert.equal(mailMatches, mailOpaque, versionId .. " paints mail at its generated anchor with frame offset")

    local capsuleStatus = presentation()
    capsuleStatus.view.slots[2] = slot(1, { capsule = { id = 3, seals = {} } })
    local capsuleImage = renderPane(scope, cacheFs, manifest, capsuleStatus)
    local capsuleFrame =
      assert(manifest.visuals.held.sequences[3].frames[1], versionId .. " carries its capsule visual")
    local capsuleAnchor = assert(manifest.panels[2].capsuleAnchor, versionId .. " carries the capsule anchor")
    local capsuleSource = visualPixels(scope, cacheFs, capsuleFrame)
    local capsuleMatches, capsuleOpaque = matchingOpaquePixels(
      capsuleImage,
      capsuleSource,
      0,
      0,
      capsuleAnchor.x + (capsuleFrame.offset and capsuleFrame.offset.x or 0),
      capsuleAnchor.y + (capsuleFrame.offset and capsuleFrame.offset.y or 0),
      capsuleFrame.width,
      capsuleFrame.height
    )
    Assert.isTrue(capsuleOpaque > 0, versionId .. " compiles visible capsule marker pixels")
    Assert.equal(
      capsuleMatches,
      capsuleOpaque,
      versionId .. " paints capsule at its generated anchor with frame offset"
    )
  end
end

function T.browse_message_does_not_follow_selection_and_info_stays_available(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local selected = presentation({ cursorNode = 0 })
    selected.view.slots[5] = slot(4, { displayName = "FOUR" })
    local selectedImage, _ = renderPane(scope, cacheFs, manifest, selected)
    local cancel = presentation({ cursorNode = "cancel" })
    cancel.view.slots[5] = slot(4, { displayName = "FOUR" })
    local cancelImage, _ = renderPane(scope, cacheFs, manifest, cancel)
    Assert.equal(
      differingPixels(selectedImage, cancelImage, 16, 168, 160, 16),
      0,
      versionId .. " keeps the browse message stable while selection changes"
    )
    -- Native content carries no host affordance: the overlay flag changes
    -- no pixel inside the pane.
    local flagged = presentation({ cursorNode = "cancel", infoOverlay = true })
    flagged.view.slots[5] = slot(4, { displayName = "FOUR" })
    local flaggedImage, _ = renderPane(scope, cacheFs, manifest, flagged)
    Assert.equal(
      differingPixels(cancelImage, flaggedImage, 0, 0, 256, 192),
      0,
      versionId .. " renders identical native pixels with or without the host overlay flag"
    )
  end
end

function T.panel_slide_moves_detail_only_inside_logical_panes(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local menu = {
      { kind = "summary", label = "SUMMARY" },
      { kind = "switch", label = "SWITCH" },
    }
    local before = presentation({ cursorNode = 0, menuSlot = 0, state = "context", menu = menu, menuIndex = 1 })
    before.view.slots[1] = slot(0, {})
    local after = presentation({ cursorNode = 0, menuSlot = 0, state = "context", menu = menu, menuIndex = 1 })
    after.view.slots[1] = slot(0, {})
    after.anim.panelSlide = 40
    local first, layout = renderPane(scope, cacheFs, manifest, before)
    local last, _ = renderPane(scope, cacheFs, manifest, after)
    local panel = assert(layout.slotRects[1], versionId .. " carries the lead panel")
    local contentDelta = differingPixels(first, last, panel.x, panel.y, panel.width, panel.height)
    Assert.equal(contentDelta, 0, versionId .. " keeps lower-panel pixels fixed during the detail slide")

    local slideImages = {}
    for _, slide in ipairs({ 12, 24, 36, 40 }) do
      local status = presentation({ cursorNode = 0, menuSlot = 0, state = "context", menu = menu, menuIndex = 1 })
      status.view.slots[1] = slot(0, {})
      status.anim.panelSlide = slide
      local image, placement = renderDetailPane(scope, cacheFs, manifest, status)
      slideImages[#slideImages + 1] = { image = image, placement = placement }
    end
    local function iconTop(entry)
      local frame = entry.placement.frame
      local minY
      for y = frame.y, frame.y + frame.height - 1 do
        for x = frame.x + 60, frame.x + 124 do
          local r, g, b = entry.image:getPixel(x, y)
          if r > 0.7 and g < 0.3 and b < 0.3 then
            minY = minY and math.min(minY, y) or y
          end
        end
      end
      return assert(minY, versionId .. " shows the selected detail icon during its slide")
    end
    local expectedDeltas = { 24, 24, 8 }
    for index = 2, #slideImages do
      Assert.equal(
        iconTop(slideImages[index - 1]) - iconTop(slideImages[index]),
        expectedDeltas[index - 1],
        versionId
          .. " advances the detail icon by 12 logical pixels per slide frame (observed "
          .. tostring(iconTop(slideImages[index - 1]) - iconTop(slideImages[index]))
          .. ")"
      )
    end
  end
end

function T.opened_context_moves_detail_facts_up_with_panel_slide(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local menu = {
      { kind = "summary", label = "SUMMARY" },
      { kind = "switch", label = "SWITCH" },
    }
    local function detailAt(slide)
      local status = presentation({
        cursorNode = 0,
        state = "context",
        menu = menu,
        menuIndex = 1,
        menuSlot = 0,
      })
      status.view.slots[1] = slot(0, { displayName = "MON0" })
      status.anim.panelSlide = slide
      local image, placement = renderDetailPane(scope, cacheFs, manifest, status)
      return { image = image, frame = placement.frame }
    end

    local before = detailAt(36)
    local after = detailAt(40)
    local function iconTop(entry)
      local minY
      for y = entry.frame.y, entry.frame.y + entry.frame.height - 1 do
        for x = entry.frame.x + 20, entry.frame.x + 112 do
          local r, g, b = entry.image:getPixel(x, y)
          if r > 0.7 and g < 0.3 and b < 0.3 then
            minY = minY and math.min(minY, y) or y
          end
        end
      end
      return assert(minY, versionId .. " draws selected detail facts at the panel-slide position")
    end

    Assert.equal(
      iconTop(before) - iconTop(after),
      8,
      versionId .. " moves the detail icon upward by 4 logical pixels from panel slide 36 to 40"
    )
  end
end

-- Six staggered source panels with source-sized icons, glyph numerals,
-- status text, and cursor: the lead panel sits at the pane origin while
-- its right neighbor staggers down eight pixels.
function T.native_panels_render_staggered_chrome_icons_and_glyphs(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
    local layout = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
    Assert.deepEqual(
      { layout.slotRects[1].x, layout.slotRects[1].y },
      { 0, 0 },
      versionId .. " leads at the pane origin"
    )
    Assert.deepEqual(
      { layout.slotRects[2].x, layout.slotRects[2].y },
      { 128, 8 },
      versionId .. " staggers the right column down eight pixels"
    )
    local provider = scope:own(PreparedMonIcons.preparedProvider(PreparedMonIcons.iconCache(), { "MON0/f0" }))
    local renderer =
      PartyScreenRenderer.new({ graphics = love.graphics, cacheFs = cacheFs, manifest = manifest, text = text })
    local canvas = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:draw(presentation({ cursorNode = 5 }), layout, provider)
    love.graphics.setCanvas()
    local image = scope:own(canvas:newImageData())
    -- Chrome paints across the full first panel: every corner differs
    -- from the cleared background.
    local r0, g0, b0 = image:getPixel(0, 0)
    local painted = 0
    for _, point in ipairs({ { 2, 2 }, { 125, 2 }, { 2, 45 }, { 125, 45 } }) do
      local r, g, b = image:getPixel(point[1], point[2])
      if quantize(r) ~= quantize(r0) or quantize(g) ~= quantize(g0) or quantize(b) ~= quantize(b0) then
        painted = painted + 1
      end
    end
    Assert.isTrue(painted >= 1, versionId .. " paints panel chrome over the background")
    -- The lead icon comes from the red fixture atlas inside its region.
    local anchor = manifest.panels[1].iconAnchor
    local ir, ig = image:getPixel(anchor.x, anchor.y)
    Assert.near(ir, 200 / 255, 0.08, versionId .. " draws the icon quad inside the lead panel")
    Assert.near(ig, 40 / 255, 0.08)
    -- The damaged second slot keeps painted HP numerals: its number
    -- rect carries more than flat chrome.
    local panel2 = manifest.panels[2]
    local number = assert(panel2.hp.number, versionId .. " carries the HP number subrect")
    local digits, _ = scanRegion(image, quantize(r0), quantize(g0), quantize(b0), number.x, number.y, 24, 8)
    Assert.isTrue(digits > 4, versionId .. " paints HP glyphs in the number rect")
  end
end

-- The context menu draws one text row per entry with the focused row
-- highlighted over the menu window.
function T.context_menu_covers_its_window_with_highlighted_focus(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
    local layout = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
    local provider = scope:own(PreparedMonIcons.preparedProvider(PreparedMonIcons.iconCache(), { "MON0/f0" }))
    local renderer =
      PartyScreenRenderer.new({ graphics = love.graphics, cacheFs = cacheFs, manifest = manifest, text = text })
    local menu = {
      { kind = "summary", label = "SUMMARY" },
      { kind = "switch", label = "SWITCH" },
      { kind = "quit", label = "QUIT" },
    }
    local status = presentation({ state = "context", menu = menu, menuIndex = 2, menuSlot = 0 })
    local canvas = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:draw(status, layout, provider)
    love.graphics.setCanvas()
    local image = scope:own(canvas:newImageData())
    local window = manifest.windows.context
    local r0, g0, b0 = image:getPixel(0, 0)
    local cornerR, cornerG, cornerB = quantize(r0), quantize(g0), quantize(b0)
    local rows, _ = scanRegion(image, cornerR, cornerG, cornerB, window.x, window.y, window.width, 24)
    Assert.isTrue(rows > 10, versionId .. " paints menu rows inside the context window")
  end
end

function T.context_menu_labels_match_the_source_font(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local menu = {
      { kind = "summary", label = "SUMMARY" },
      { kind = "switch", label = "SWITCH" },
      { kind = "quit", label = "QUIT" },
    }
    local status = presentation({ state = "context", menu = menu, menuIndex = 2, menuSlot = 0 })
    local image, layout = renderPane(scope, cacheFs, manifest, status)
    local generated = assert(layout.menuLayout("topLevel", #menu)[2], "the switch row has generated geometry")
    local textRect = generated.textRect
    local role = assert(manifest.contextMenu.textRoles[generated.style], "the switch row has a text role")
    local sourceInk = assert(role.depressed, "the focused switch row uses depressed ink")
    local function normalized(color)
      return { r = color.r, g = color.g, b = color.b, a = color.a and color.a / 255 or nil }
    end
    local ink = {
      foreground = normalized(sourceInk.foreground),
      shadow = normalized(sourceInk.shadow),
      background = normalized(sourceInk.background),
    }
    local font = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs, fontId = 4 }))
    local expectedCanvas = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(expectedCanvas)
    love.graphics.clear(0, 0, 0, 0)
    font:drawTextWithPalette("SWITCH", textRect.x, textRect.y, ink)
    love.graphics.setCanvas()
    local expected = scope:own(expectedCanvas:newImageData())
    local compared, matched = 0, 0
    for y = textRect.y, textRect.y + textRect.height - 1 do
      for x = textRect.x, textRect.x + textRect.width - 1 do
        local er, eg, eb, ea = expected:getPixel(x, y)
        if quantize(ea) > 0 then
          compared = compared + 1
          local ar, ag, ab, aa = image:getPixel(x, y)
          if
            quantize(aa) == quantize(ea)
            and quantize(ar) == quantize(er)
            and quantize(ag) == quantize(eg)
            and quantize(ab) == quantize(eb)
          then
            matched = matched + 1
          end
        end
      end
    end
    Assert.isTrue(compared > 10, versionId .. " provides font-4 source glyph pixels")
    Assert.equal(matched, compared, versionId .. " renders context labels with the font-4 glyph mask")
  end
end

-- The native browse message band paints through the generated font and
-- magnifies uniformly at an integral scale.
function T.browse_message_paints_and_magnifies_uniformly(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
    local layout = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
    local provider = scope:own(PreparedMonIcons.preparedProvider(PreparedMonIcons.iconCache(), { "MON0/f0" }))
    local renderer =
      PartyScreenRenderer.new({ graphics = love.graphics, cacheFs = cacheFs, manifest = manifest, text = text })
    local canvas = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:draw(presentation(), layout, provider)
    love.graphics.setCanvas()
    local image = scope:own(canvas:newImageData())
    local cr, cg, cb = image:getPixel(0, 0)
    local cornerR, cornerG, cornerB = quantize(cr), quantize(cg), quantize(cb)
    local message, messageColors = scanRegion(image, cornerR, cornerG, cornerB, 16, 168, 160, 16)
    Assert.isTrue(message > 20, versionId .. " paints the choose-mon message in its native window")
    Assert.isTrue(messageColors >= 2, versionId .. " carries more than flat background in the message band")
    local doubled = scope:own(love.graphics.newCanvas(512, 384))
    love.graphics.setCanvas(doubled)
    love.graphics.clear(0, 0, 0, 0)
    local placement = assert(
      PixelScale.placeFixed({ x = 0, y = 0, width = 512, height = 384 }, 256, 192),
      "the doubled canvas fits its single pane"
    )
    LogicalSurface.draw(love.graphics, placement, function()
      renderer:draw(presentation(), layout, provider)
    end)
    love.graphics.setCanvas()
    local doubledImage = scope:own(doubled:newImageData())
    local dr, dg, db = doubledImage:getPixel(0, 0)
    local dCornerR, dCornerG, dCornerB = quantize(dr), quantize(dg), quantize(db)
    local dMessage, _ = scanRegion(doubledImage, dCornerR, dCornerG, dCornerB, 32, 336, 320, 32)
    Assert.isTrue(dMessage > 40, versionId .. " paints the browse message at the doubled scale")
  end
end

function T.target_and_swap_states_keep_their_lower_prompts(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local empty, _ = renderPane(scope, cacheFs, manifest, presentation({ state = "message" }))
    local browse, _ = renderPane(scope, cacheFs, manifest, presentation({ state = "browse" }))
    local giveTarget, _ = renderPane(scope, cacheFs, manifest, presentation({ state = "choosing_item_target" }))
    local chooseSwap, _ = renderPane(scope, cacheFs, manifest, presentation({ state = "choose_swap" }))
    local swappingStatus = presentation({ state = "swapping" })
    swappingStatus.swap = {
      source = 0,
      destination = 1,
      xOffset = 0,
      offsets = { [0] = 0, [1] = 0 },
      directions = { [0] = -1, [1] = 1 },
      exchanged = false,
    }
    local swapping, _ = renderPane(scope, cacheFs, manifest, swappingStatus)
    local window = assert(manifest.windows.browse, "Party prompt text uses the lower window")
    local area = { window.x, window.y, window.width, window.height }
    Assert.isTrue(
      differingPixels(giveTarget, empty, area[1], area[2], area[3], area[4]) > 10,
      versionId .. " paints the Give-target prompt in the lower window"
    )
    Assert.isTrue(
      differingPixels(chooseSwap, empty, area[1], area[2], area[3], area[4]) > 10,
      versionId .. " paints the switch prompt before the swap"
    )
    Assert.equal(
      differingPixels(chooseSwap, swapping, area[1], area[2], area[3], area[4]),
      0,
      versionId .. " keeps the switch prompt visible for the full swap animation"
    )
    Assert.isTrue(
      differingPixels(swapping, browse, area[1], area[2], area[3], area[4]) > 10,
      versionId .. " returns to the browse prompt after the swap completes"
    )
  end
end

-- Source-faithful native behavior through the real v3 bundle: timeline
-- icon frames with selected bob, gender marks in source roles, fixed HP
-- fields, the generated Cancel label, action-window context copy, and no
-- host overlay pixels. Menu-open presentations still composite the slots
-- beneath, so slot-level behavior is proved without the retired v2
-- message window; the browse-window scenario below names that missing
-- consumption directly.
local function contextPresentation(overrides)
  local menu = {
    { kind = "summary", label = "SUMMARY" },
    { kind = "switch", label = "SWITCH" },
    { kind = "quit", label = "QUIT" },
  }
  local base = {
    state = "context",
    menu = menu,
    menuIndex = 1,
    menuSlot = 0,
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return presentation(base)
end

-- Top icon row through the brightened content: the fixture icon red
-- keeps its red dominance under the white step while brightened
-- chrome, cursor, and trough rows do not. Every pixel the old pure
-- channel test accepted still passes; only washed reds are added.
local function iconTopRow(image, x0, y0, width, height)
  for y = y0, y0 + height - 1 do
    local red = 0
    for x = x0, x0 + width - 1 do
      local ir, ig, ib = image:getPixel(x, y)
      if ir > 0.7 and (ir - ig) > 0.2 and (ir - ib) > 0.2 then
        red = red + 1
      end
    end
    if red > 4 then
      return y
    end
  end
  return nil
end

function T.selected_icons_follow_timeline_frames_with_source_bob(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local timeline = assert(manifest.iconAnimations.sequences[2], versionId .. " carries the healthy timeline")
    local total = 0
    for _, keyframe in ipairs(timeline) do
      total = total + keyframe.durationTicks
    end
    Assert.isTrue(total > 1, versionId .. " spans more than one tick")
    local firstDuration = timeline[1].durationTicks
    local function renderAt(tick)
      -- Controller sequences are 0-based (0 still, 1 full): sequence 1
      -- resolves the healthy timeline above.
      local status = contextPresentation({
        cursorNode = 0,
        anim = {
          tick = tick,
          sequences = { 1, 1, 1, 1, 1, 1 },
          sequenceTicks = { tick, 0, 0, 0, 0, 0 },
          panelSlide = 0,
        },
      })
      local image, _ = renderPane(scope, cacheFs, manifest, status)
      return image
    end
    local early = renderAt(0)
    local late = renderAt(firstDuration)
    local panel = manifest.panels[1]
    local earlyTop = iconTopRow(early, panel.origin.x, panel.origin.y, 128, 48)
    local lateTop = iconTopRow(late, panel.origin.x, panel.origin.y, 128, 48)
    Assert.notNil(earlyTop, versionId .. " draws the selected icon")
    Assert.notNil(lateTop, versionId .. " draws the selected icon after its frame changes")
    Assert.isTrue(earlyTop ~= lateTop, versionId .. " moves the icon when the timeline frame changes")
  end
end

function T.names_and_gender_use_source_roles_without_truncation(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local male = contextPresentation({ cursorNode = 5 })
    male.view.slots[1] = slot(0, { displayName = "LEADMON", gender = "male", genderSymbol = "male" })
    local maleImage, _ = renderPane(scope, cacheFs, manifest, male)
    local female = contextPresentation({ cursorNode = 5 })
    female.view.slots[1] = slot(0, { displayName = "LEADMON", gender = "female", genderSymbol = "female" })
    local femaleImage, _ = renderPane(scope, cacheFs, manifest, female)
    local name = assert(manifest.panels[1].text.name, versionId .. " carries the name subrect")
    local markWidth = math.min(name.width + 16, 256 - name.x)
    local delta = differingPixels(maleImage, femaleImage, name.x, name.y, markWidth, name.height)
    Assert.isTrue(delta > 2, versionId .. " paints distinct gender marks beside identical names")
  end
end

function T.hp_fields_hold_slash_and_max_steady_across_current_values(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local number = assert(manifest.panels[1].hp.number, versionId .. " carries the HP number subrect")
    local function renderCurrent(current)
      local status = contextPresentation({ cursorNode = 5 })
      status.view.slots[1] =
        slot(0, { currentHp = current, maxHp = 180, hpFraction = current / 180 })
      local image, _ = renderPane(scope, cacheFs, manifest, status)
      return image
    end
    local narrow = renderCurrent(5)
    local wide = renderCurrent(150)
    local steady = differingPixels(
      narrow,
      wide,
      number.x + 24,
      number.y,
      number.width - 24,
      number.height
    )
    Assert.equal(steady, 0, versionId .. " keeps the slash and max fields fixed while current varies")
  end
end

function T.context_message_names_its_slot_in_the_context_window(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local window = assert(manifest.windows.context, versionId .. " carries the context window")
    local action = assert(manifest.windows.action, versionId .. " carries the action window")
    local function renderNamed(name)
      local status = contextPresentation({ cursorNode = 5 })
      status.view.slots[1] = slot(0, { displayName = name })
      local image, _ = renderPane(scope, cacheFs, manifest, status)
      return image
    end
    -- Same-length names differing in the first glyph keep panel layout
    -- identical, so any context-window difference is the open-menu
    -- message naming its slot at the name start inside its window.
    local first = renderNamed("AEADMONA")
    local second = renderNamed("BEADMONA")
    local delta = differingPixels(first, second, window.x, window.y, window.width, window.height)
    Assert.isTrue(delta > 4, versionId .. " paints the context message naming its slot")
    -- The transient action window carries no open-menu copy: past the
    -- context window its pixels stay identical across slot names.
    local acted = differingPixels(
      first,
      second,
      window.x + window.width,
      action.y,
      action.x + action.width - window.x - window.width,
      action.height
    )
    Assert.equal(acted, 0, versionId .. " keeps the action window clear of the open-menu message")
  end
end

function T.native_content_ignores_the_host_overlay_flag(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local plain = contextPresentation({ cursorNode = 5 })
    local plainImage, _ = renderPane(scope, cacheFs, manifest, plain)
    local flagged = contextPresentation({ cursorNode = 5, infoOverlay = true })
    local flaggedImage, _ = renderPane(scope, cacheFs, manifest, flagged)
    Assert.equal(
      differingPixels(plainImage, flaggedImage, 0, 0, 256, 192),
      0,
      versionId .. " renders identical native pixels with or without the host overlay flag"
    )
  end
end

-- Opening the context menu brightens the underlying panel content while
-- the menu button frames keep their exact source pixels: the same
-- slots render different panel pixels than browse, but every opaque
-- frame pixel still matches the generated art.
function T.context_brightens_content_below_unbrightened_menu_buttons(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local browsingImage, _ = renderPane(scope, cacheFs, manifest, presentation({ cursorNode = 0 }))
    local menu = {
      { kind = "summary", label = "SUMMARY" },
      { kind = "switch", label = "SWITCH" },
      { kind = "quit", label = "QUIT" },
    }
    local opened = presentation({ cursorNode = 0, state = "context", menu = menu, menuIndex = 1, menuSlot = 0 })
    local openedImage, _ = renderPane(scope, cacheFs, manifest, opened)
    local panel = manifest.panels[1]
    local brightened = differingPixels(browsingImage, openedImage, panel.origin.x, panel.origin.y, 128, 48)
    Assert.isTrue(brightened > 100, versionId .. " brightens the underlying panel content with the menu open")
    local generated = assert(manifest.contextMenu.topLevel[3], versionId .. " carries the three-entry layout")
    local first = assert(generated[1], versionId .. " carries its first entry")
    local rect = assert(first.frameRect, versionId .. " carries entry frame rectangles")
    local frames = assert(manifest.contextMenu.frames, versionId .. " carries menu frames")
    local group = assert(frames[first.frameShape], versionId .. " carries the entry frame")
    local selected =
      visualPixels(scope, cacheFs, assert(group.selected, versionId .. " carries the selected frame"))
    local matches, opaque = matchingOpaquePixels(openedImage, selected, 0, 0, rect.x, rect.y, rect.width, rect.height)
    Assert.isTrue(opaque > 100, versionId .. " compiles visible selected-frame pixels")
    Assert.equal(matches, opaque, versionId .. " keeps menu button pixels at source ink under brightness")
  end
end

-- Switch selection paints the generated bank-7 chrome on both the
-- locked source and the current candidate with no runtime tint, even
-- when the source is fainted.
function T.switch_selection_paints_generated_bank_seven_chrome(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    -- Cancel focus parks the slot cursor away from both panels, so the
    -- proven top strip isolates the chrome under test.
    local status = presentation({
      cursorNode = "cancel",
      state = "choose_swap",
      switchSelect = { source = 0, candidate = 3 },
    })
    status.view.slots[1] = slot(0, { status = "faint", currentHp = 0, maxHp = 20, hpFraction = 0 })
    status.view.slots[4] = slot(3, {})
    local image, _ = renderPane(scope, cacheFs, manifest, status)
    for _, slot0 in ipairs({ 0, 3 }) do
      local panel = manifest.panels[slot0 + 1]
      local chrome = assert(panel.chrome.switchSelection, versionId .. " carries switch-selection chrome")
      local source = visualPixels(scope, cacheFs, chrome)
      -- The proven top strip stays clear of icons, balls, and text, so
      -- every opaque chrome pixel there must match exactly.
      local matches, opaque =
        matchingOpaquePixels(image, source, 64, 0, panel.origin.x + 64, panel.origin.y, 40, 8)
      Assert.isTrue(opaque > 50, versionId .. " compiles visible switch-selection pixels")
      Assert.equal(matches, opaque, versionId .. " paints generated switch chrome without tint")
    end
  end
end

-- Switch motion exits each slot outward from its own column and
-- empties both home panels at full exit: the even slot shifts left
-- while the odd slot shifts right, with the whole composition leaving
-- the home rectangles instead of lingering unmoved.
function T.switch_animation_exits_outward_and_empties_panels_at_full_exit(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local browsing, layout = renderPane(scope, cacheFs, manifest, presentation({ cursorNode = "cancel" }))
    local directions = { [0] = -1, [1] = 1 }
    local moving = presentation({
      cursorNode = "cancel",
      state = "swapping",
      swap = {
        source = 0,
        destination = 1,
        xOffset = 4,
        offsets = { [0] = -32, [1] = 32 },
        directions = directions,
        exchanged = false,
      },
    })
    local moved, _ = renderPane(scope, cacheFs, manifest, moving)
    for _, slot0 in ipairs({ 0, 1 }) do
      local rect = layout.slotRects[slot0 + 1]
      local changed = differingPixels(browsing, moved, rect.x, rect.y, rect.width, rect.height)
      Assert.isTrue(changed > 100, versionId .. " slot " .. slot0 .. " visibly leaves its home panel")
      local panel = manifest.panels[slot0 + 1]
      local chrome = assert(panel.chrome.normal, versionId .. " carries normal panel chrome")
      local source = visualPixels(scope, cacheFs, chrome)
      local direction = directions[slot0]
      -- Right-exiting slots compare the outer third: the travelling icon
      -- covers the middle third under whole-slot motion, while the outer
      -- band still proves chrome identity (it differs fully between normal
      -- and switch-selection art at this band).
      local matches, opaque =
        matchingOpaquePixels(moved, source, 64 - direction * 32, 0, panel.origin.x + 64 + (direction == 1 and 32 or 0), panel.origin.y, 32, 8)
      Assert.isTrue(opaque > 0, versionId .. " compiles chrome pixels for slot " .. slot0)
      Assert.equal(
        matches,
        opaque,
        versionId .. " slot " .. slot0 .. " shifts its chrome outward by column"
      )
    end
    local emptied = presentation({
      cursorNode = "cancel",
      state = "swapping",
      swap = {
        source = 0,
        destination = 1,
        xOffset = 16,
        offsets = { [0] = -128, [1] = 128 },
        directions = directions,
        exchanged = true,
      },
    })
    local empty, _ = renderPane(scope, cacheFs, manifest, emptied)
    for _, slot0 in ipairs({ 0, 1 }) do
      local rect = layout.slotRects[slot0 + 1]
      local iconRed = 0
      for y = rect.y, rect.y + rect.height - 1 do
        for x = rect.x, rect.x + rect.width - 1 do
          local ir, ig, ib = empty:getPixel(x, y)
          if ir > 0.7 and ig < 0.3 and ib < 0.3 then
            iconRed = iconRed + 1
          end
        end
      end
      Assert.equal(iconRed, 0, versionId .. " full exit clears slot " .. slot0 .. " of its icon")
    end
  end
end

-- Opening the context menu brightens the backdrop strip below the slot
-- panels while the menu button frames keep their exact source pixels:
-- a left-margin probe below the panel union and clear of later window
-- and menu chrome changes with the menu open, but every opaque frame
-- pixel still matches the generated art.
function T.context_brightness_reaches_below_panels_without_touching_menu_frames(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest = manifestFor(versionId)
    local browsingImage, layout = renderPane(scope, cacheFs, manifest, presentation({ cursorNode = 0 }))
    local menu = {
      { kind = "summary", label = "SUMMARY" },
      { kind = "switch", label = "SWITCH" },
      { kind = "quit", label = "QUIT" },
    }
    local opened = presentation({ cursorNode = 0, state = "context", menu = menu, menuIndex = 1, menuSlot = 0 })
    local openedImage, _ = renderPane(scope, cacheFs, manifest, opened)
    local panelBottom = 0
    for _, panel in ipairs(assert(manifest.panels, versionId .. " carries panels")) do
      local origin = assert(panel.origin, versionId .. " carries panel origins")
      local size = assert(panel.size, versionId .. " carries panel sizes")
      panelBottom = math.max(panelBottom, origin.y + size.height)
    end
    Assert.isTrue(panelBottom < 192, versionId .. " leaves a backdrop strip below the panels")
    local probeX, probeY, probeW, probeH = 4, panelBottom + 6, 8, 8
    local function intersects(ax, ay, aw, ah, box)
      return ax < box.x + box.width and box.x < ax + aw and ay < box.y + box.height and box.y < ay + ah
    end
    for _, box in ipairs({ manifest.windows.browse, manifest.windows.context, manifest.windows.action }) do
      Assert.isFalse(
        intersects(probeX, probeY, probeW, probeH, box),
        versionId .. " keeps the lower probe clear of message windows"
      )
    end
    local generated = assert(manifest.contextMenu.topLevel[3], versionId .. " carries the three-entry layout")
    for _, entry in ipairs(generated) do
      local rect = assert(entry.frameRect, versionId .. " carries entry frame rectangles")
      local box = { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
      Assert.isFalse(
        intersects(probeX, probeY, probeW, probeH, box),
        versionId .. " keeps the lower probe clear of menu frames"
      )
    end
    local cancelRect = assert(layout.cancelRect, versionId .. " exposes the Cancel hit target")
    local cancelBox = { x = cancelRect.x, y = cancelRect.y, width = cancelRect.width, height = cancelRect.height }
    Assert.isFalse(
      intersects(probeX, probeY, probeW, probeH, cancelBox),
      versionId .. " keeps the lower probe clear of Cancel"
    )
    local brightened = differingPixels(browsingImage, openedImage, probeX, probeY, probeW, probeH)
    Assert.isTrue(
      brightened > 10,
      versionId .. " brightens the backdrop strip below the panels with the menu open"
    )
    local first = assert(generated[1], versionId .. " carries its first entry")
    local rect = assert(first.frameRect, versionId .. " carries entry frame rectangles")
    local frames = assert(manifest.contextMenu.frames, versionId .. " carries menu frames")
    local group = assert(frames[first.frameShape], versionId .. " carries the entry frame")
    local selected =
      visualPixels(scope, cacheFs, assert(group.selected, versionId .. " carries the selected frame"))
    local matches, opaque = matchingOpaquePixels(openedImage, selected, 0, 0, rect.x, rect.y, rect.width, rect.height)
    Assert.isTrue(opaque > 100, versionId .. " compiles visible selected-frame pixels")
    Assert.equal(matches, opaque, versionId .. " keeps menu button pixels at source ink under brightness")
  end
end

local suite = GraphicsSmoke.suite(T, { capabilities = { "graphics", "rom_dump" } })
suite.metadata.derivedAssets = { "party:global", "field-font:global" }
return suite
