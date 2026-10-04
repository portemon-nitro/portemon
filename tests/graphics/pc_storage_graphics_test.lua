-- ROM-backed Storage graphics and hit geometry follow the published
-- ApplicationPresentation plan across each supported surface arrangement.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local ItemCache = require("libs.assets.src.ItemCache")
local ItemIconAssetProvider = require("libs.hgss.src.presentation.ItemIconAssetProvider")
local MonCache = require("libs.assets.src.MonCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local PcCache = require("libs.assets.src.PcCache")
local PcStorageRenderer = require("libs.hgss.src.ui.PcStorageRenderer")
local PreparedMonIcons = require("tests.support.PreparedMonIcons")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local StorageInterface = require("game.hgss.src.pc.StorageInterface")

local T = {}

local function iconKeyForPage(cacheFs, pageId)
  local manifest = cacheFs:loadLua(MonCache.iconManifestPath())
  for key, entry in pairs(manifest.entries) do
    if entry.pageId == pageId then
      return key
    end
  end
  error("compiled icon page has no semantic selector: " .. pageId, 0)
end

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local marker = cacheFs:read(PcCache.markerPath())
      if
        marker ~= nil
        and PcCache.isReady(cacheFs, marker)
        and cacheFs:read(ItemCache.iconManifestPath()) ~= nil
        and cacheFs:read(ItemCache.iconImagePath()) ~= nil
        and cacheFs:read(MonCache.iconManifestPath()) ~= nil
      then
        versions[#versions + 1] = versionId
      end
    end
  end
  return versions
end

local function measurement(configuration)
  local width, height
  local topology
  if configuration == "dualDisplay" then
    width, height = 800, 600
    topology = ScreenTopology.dualDisplay({
      id = "main",
      rect = { x = 400, y = 100, width = 256, height = 192 },
      role = "world",
      touch = false,
    }, {
      id = "sub",
      rect = { x = 100, y = 300, width = 256, height = 192 },
      role = "auxiliary",
      touch = true,
    })
  else
    local dimensions = {
      nativeLike = { 640, 480 },
      wide = { 1280, 720 },
      tall = { 600, 1000 },
    }
    width, height = dimensions[configuration][1], dimensions[configuration][2]
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = true,
    })
  end
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = 1,
    signature = "pc-storage-graphics:" .. configuration,
  }
end

local function pane(plan, id)
  for _, candidate in ipairs(plan.panes) do
    if candidate.id == id then
      return candidate
    end
  end
  error("missing " .. id .. " pane", 0)
end

local function drawPlan(scope, cacheFs, manifest, view, plan, width, height)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  local renderer = scope:own(PcStorageRenderer.new({
    graphics = love.graphics,
    cacheFs = cacheFs,
    manifest = manifest,
    text = text,
  }))
  local itemIcons = scope:own(ItemIconAssetProvider.new(cacheFs))
  local icons = scope:own(MonIconAssetProvider.new(cacheFs, {
    preparationQueue = PreparedMonIcons.decodingQueue(cacheFs),
    derivedAssets = PreparedMonIcons.readyDerivedAssets(),
  }))
  local iconKey = iconKeyForPage(cacheFs, 0)
  local prepared = false
  local prepareFailure = nil
  for _ = 1, 8 do
    prepared, prepareFailure = icons:prepareKeys({ iconKey })
    if prepared then
      break
    end
  end
  Assert.isTrue(
    prepared,
    "visible Storage mon icon page is prepared from the generated cache: " .. tostring(prepareFailure)
  )
  local draws = { monIcons = 0, itemIcons = 0, texts = {} }
  local textSpy = {
    drawText = function(_, value, x, y)
      draws.texts[#draws.texts + 1] = value
      text:drawText(value, x, y)
    end,
  }
  renderer._text = textSpy
  local iconSpy = {
    image = function(_, key)
      draws.monIcons = draws.monIcons + 1
      return icons:image(key)
    end,
    quadFor = function(_, key)
      return icons:quadFor(key)
    end,
    dimensions = function(_, key)
      return icons:dimensions(key)
    end,
  }
  local itemIconSpy = {
    image = function(_, key)
      draws.itemIcons = draws.itemIcons + 1
      return itemIcons:image()
    end,
    quadFor = function(_, key)
      return itemIcons:quadFor(key)
    end,
    dimensions = function(_, key)
      return itemIcons:dimensions(key)
    end,
  }
  local paneStates = {}
  local rendererSpy = {
    drawPane = function(_, snapshot, resources, paneId, placement, singlePane)
      paneStates[#paneStates + 1] = {
        id = paneId,
        single = singlePane,
        partyCount = #snapshot.party,
        boxCount = #snapshot.boxSlots,
        hasIcons = resources.icons ~= nil,
        boxIcon = snapshot.boxSlots[1].iconKey,
      }
      renderer:drawPane(snapshot, resources, paneId, placement, singlePane)
    end,
  }
  local canvas = scope:own(love.graphics.newCanvas(width, height, { format = "rgba8", readable = true }))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  ApplicationPresentation.draw(love.graphics, {
    storageRenderer = rendererSpy,
    icons = iconSpy,
    itemIcons = itemIconSpy,
    text = textSpy,
  }, view, plan)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData()), draws, paneStates
end

local function nonTransparentPixels(image, rect)
  local count = 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local _, _, _, alpha = image:getPixel(x, y)
      if alpha > 0 then
        count = count + 1
      end
    end
  end
  return count
end

local function placedRect(placement, x, y, width, height)
  local origin = placement.origin or placement.frame
  local scale = placement.scale
  return {
    x = math.floor(origin.x + x * scale),
    y = math.floor(origin.y + y * scale),
    width = math.ceil(width * scale),
    height = math.ceil(height * scale),
  }
end

local function colorsInSource(scope, cacheFs, visual)
  local bytes = assert(cacheFs:read(visual.image), "the generated Storage visual is present")
  local data = scope:own(love.image.newImageData(love.filesystem.newFileData(bytes, visual.image)))
  local colors = {}
  for y = 0, data:getHeight() - 1 do
    for x = 0, data:getWidth() - 1 do
      local red, green, blue, alpha = data:getPixel(x, y)
      if alpha > 0 then
        local key = table.concat({
          math.floor(red * 255 + 0.5),
          math.floor(green * 255 + 0.5),
          math.floor(blue * 255 + 0.5),
          math.floor(alpha * 255 + 0.5),
        }, ":")
        colors[key] = true
      end
    end
  end
  return colors
end

local function pixelsWithSourceColors(image, colors)
  local count = 0
  for y = 0, image:getHeight() - 1 do
    for x = 0, image:getWidth() - 1 do
      local red, green, blue, alpha = image:getPixel(x, y)
      local key = table.concat({
        math.floor(red * 255 + 0.5),
        math.floor(green * 255 + 0.5),
        math.floor(blue * 255 + 0.5),
        math.floor(alpha * 255 + 0.5),
      }, ":")
      if colors[key] then
        count = count + 1
      end
    end
  end
  return count
end

function T.source_modes_keep_distinct_storage_geometry_and_live_hit_regions(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = PcCache.loadManifest(cacheFs)
    local wallpaperMap = manifest.storage.geometry.wallpaperMap
    Assert.deepEqual(wallpaperMap, {
      width = 168,
      height = 160,
      columns = 21,
      rows = 20,
      tileIdWrap = 64,
    }, versionId .. " uses the source BG3 wallpaper-map shape")

    local session = ApplicationPresentation.new(StorageInterface.defaults(manifest))
    local modeGeometry = {}
    for mode = 0, 3 do
      local view = {
        mode = mode,
        state = "browse",
        activeBox = 0,
        wallpaperId = 0,
      }
      local plan = session:resolve(measurement("nativeLike"), view)
      Assert.equal(plan.content.mode, mode, "the published plan retains the source mode")
      Assert.deepEqual(
        plan.content.wallpaperMap,
        wallpaperMap,
        "the source wallpaper tile map reaches the paired plan unchanged"
      )
      local hit = assert(plan.content.hitRegions.boxSlots[1], "the visible box slot has a paired hit region")
      local rect = hit.rect
      Assert.isTrue(rect.width > 0 and rect.height > 0, "drawn box slots have positive hit geometry")
      local mapped = plan.mapInput({
        type = "pointer_down",
        pointerId = "touch:0",
        x = rect.x + rect.width / 2,
        y = rect.y + rect.height / 2,
      }, view, plan)
      Assert.equal(mapped.target, hit.target, "the box slot hit maps through the same resolved plan")
      modeGeometry[mode] = plan.content.modeGeometry
    end
    for mode = 1, 3 do
      Assert.throws(function()
        Assert.deepEqual(modeGeometry[mode], modeGeometry[mode - 1])
      end, "each retail mode publishes its own source geometry")
    end
    local splitView = { mode = 0, state = "browse", activeBox = 0, wallpaperId = 0 }
    local splitPlan = session:resolve(measurement("dualDisplay"), splitView)
    Assert.equal(#splitPlan.content.hitRegions.partySlots, 0, "the lower touch pane does not hit upper Party content")
    Assert.equal(#splitPlan.content.hitRegions.boxSlots, 30, "the lower touch pane exposes active box slots")
    local singlePlan = session:resolve(measurement("nativeLike"), splitView)
    Assert.equal(#singlePlan.content.hitRegions.partySlots, 6, "single-pane layouts expose the visible Party slots")
    session:dispose()
  end
end

function T.actual_wallpaper_and_window_art_draw_through_each_paired_layout(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = PcCache.loadManifest(cacheFs)
    local session = ApplicationPresentation.new(StorageInterface.defaults(manifest))
    for _, configuration in ipairs({ "nativeLike", "wide", "tall", "dualDisplay" }) do
      local measured = measurement(configuration)
      local iconKey = iconKeyForPage(cacheFs, 0)
      local view = {
        mode = 2,
        state = "browse",
        activeBox = 0,
        wallpaperId = 0,
        boxName = "STORAGE",
        boxSlots = {
          { iconKey = iconKey, nickname = "BOXMON", heldItem = "POTION", itemIconKey = "POTION", markings = 17 },
        },
        party = { { iconKey = iconKey, nickname = "PARTYMON", heldItem = "NONE", markings = 2 } },
      }
      local plan = session:resolve(measured, view)
      local image, draws, paneStates = drawPlan(scope, cacheFs, manifest, view, plan, measured.width, measured.height)
      Assert.equal(
        draws.monIcons,
        2,
        configuration
          .. " draws two mon icons; saw "
          .. draws.monIcons
          .. " panes="
          .. table.concat({ paneStates[1].id, tostring(paneStates[1].single) }, "/")
          .. " slots="
          .. paneStates[1].partyCount
          .. "/"
          .. paneStates[1].boxCount
          .. " icon="
          .. tostring(paneStates[1].hasIcons)
          .. "/"
          .. tostring(paneStates[1].boxIcon)
          .. " texts="
          .. table.concat(draws.texts, ",")
      )
      Assert.equal(draws.itemIcons, 1, "the box held item icon is drawn on the box pane once")
      Assert.isTrue(table.concat(draws.texts, " "):find("PARTYMON", 1, true) ~= nil, "Party name is rendered")
      Assert.isTrue(table.concat(draws.texts, " "):find("BOXMON", 1, true) ~= nil, "box name is rendered")
      Assert.isTrue(table.concat(draws.texts, " "):find("STORAGE", 1, true) ~= nil, "active box name is rendered")
      Assert.isTrue(
        nonTransparentPixels(image, pane(plan, "lower").placement.frame) > 0,
        versionId .. " " .. configuration .. " paints the interactive storage pane"
      )
      local wallpaperColors = colorsInSource(scope, cacheFs, manifest.storage.wallpapers[0])
      Assert.isTrue(
        pixelsWithSourceColors(image, wallpaperColors) > 100,
        versionId .. " " .. configuration .. " paints pixels from the selected source wallpaper"
      )
      local frameColors = colorsInSource(scope, cacheFs, manifest.storage.ui.windowFrames.standard.paletteBank0)
      Assert.isTrue(
        pixelsWithSourceColors(image, frameColors) > 8,
        versionId .. " " .. configuration .. " paints source frame tiles"
      )
      Assert.isTrue(
        nonTransparentPixels(image, placedRect(pane(plan, "lower").placement, 80, 16, 56, 56)) > 100,
        versionId .. " " .. configuration .. " paints the visible mon, item, markings and label"
      )
      local expectedPanes = configuration == "nativeLike" and 1 or 2
      Assert.equal(#plan.panes, expectedPanes, versionId .. " " .. configuration .. " retains paired source screens")
      local upper = nil
      for _, candidate in ipairs(plan.panes) do
        if candidate.id == "upper" then
          upper = candidate
        end
      end
      if upper ~= nil then
        Assert.isFalse(upper.interactive, "the source upper screen never steals touch input")
        Assert.isTrue(nonTransparentPixels(image, upper.placement.frame) > 0, "the source upper screen is painted")
      end
    end
    session:dispose()
  end
end

local suite = GraphicsSmoke.suite(T, { capabilities = { "graphics", "rom_dump", "derived_assets" } })
suite.metadata.derivedAssets = {
  "pc:global",
  "mon-catalog:global",
  "mon-icon-page:0",
  "items:global",
  "field-font:global",
}
return suite
