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
  Assert.equal(manifest.schema, "g4-party-presentation-v2", versionId .. " renders the current party manifest")
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
    anim = { tick = 0, sequences = {}, phases = {}, panelSlide = 0 },
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
    status.anim.phases[index] = 0
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
    local matches, opaque = matchingOpaquePixels(
      image,
      button,
      0,
      0,
      anchor.x + (frame.offset and frame.offset.x or 0),
      anchor.y + (frame.offset and frame.offset.y or 0),
      math.min(frame.width, 256 - anchor.x - (frame.offset and frame.offset.x or 0)),
      math.min(frame.height, 192 - anchor.y - (frame.offset and frame.offset.y or 0))
    )
    Assert.isTrue(
      opaque > 4 and matches == opaque,
      versionId .. " paints every visible opaque Cancel pixel at its generated anchor"
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
    local selectedImage, layout = renderPane(scope, cacheFs, manifest, selected)
    local cancel = presentation({ cursorNode = "cancel" })
    cancel.view.slots[5] = slot(4, { displayName = "FOUR" })
    local cancelImage, _ = renderPane(scope, cacheFs, manifest, cancel)
    Assert.equal(
      differingPixels(selectedImage, cancelImage, 16, 168, 160, 16),
      0,
      versionId .. " keeps the browse message stable while selection changes"
    )
    local info = presentation({ cursorNode = "cancel", infoOverlay = true })
    info.view.slots[5] = slot(4, { displayName = "FOUR" })
    local infoImage, _ = renderPane(scope, cacheFs, manifest, info)
    local infoRect = layout.infoRect
    Assert.isTrue(
      differingPixels(cancelImage, infoImage, infoRect.x, infoRect.y, infoRect.width, infoRect.height) > 0,
      versionId .. " keeps the one-display info affordance outside the message band"
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

local suite = GraphicsSmoke.suite(T, { capabilities = { "graphics", "rom_dump" } })
suite.metadata.derivedAssets = { "party:global" }
return suite
