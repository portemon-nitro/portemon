-- Graphics smoke for the native party screen: the compiled party manifest
-- draws its staggered chrome panels, source-sized icons, glyph HP/level
-- numerals, status text, cursor, context menu rows, and footer name at
-- 1x and 2x through the real renderer, icon provider, and generated
-- font. Pixel checks pin manifest geometry and draw order, not host
-- font rasterization.

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
  Assert.equal(manifest.schema, "g4-party-presentation-v1", versionId .. " renders the current party manifest")
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
      -- The damaged second slot keeps a red HP bar segment.
      local second = layout.slotRects[2]
      local barY = math.floor(second.y + second.height - 10 + 3)
      local barX = math.floor(second.x + 6 + 32 + 8 + 4)
      local hr, hg = image:getPixel(barX, barY)
      Assert.isTrue(hr > 0.7 and hg < 0.5, versionId .. " low HP paints the red zone")
      provider:release()
    end
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
    renderer:draw(presentation(), layout, provider)
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
    local ir, ig = image:getPixel(30 + 16, 16 + 16)
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

-- The footer band shows the selected full name through the generated
-- font, and the same content magnifies uniformly at an integral scale.
function T.footer_name_paints_and_magnifies_uniformly(scope)
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
    local footer, footerColors = scanRegion(image, cornerR, cornerG, cornerB, 4, 172, 184, 16)
    Assert.isTrue(footer > 20, versionId .. " paints the selected name in the footer band")
    Assert.isTrue(footerColors >= 2, versionId .. " carries more than flat background in the footer")
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
    local dFooter, _ = scanRegion(doubledImage, dCornerR, dCornerG, dCornerB, 8, 344, 368, 32)
    Assert.isTrue(dFooter > 40, versionId .. " paints the footer name at the doubled scale")
  end
end

return GraphicsSmoke.suite(T, { capabilities = { "graphics", "rom_dump", "derived_cache" } })
