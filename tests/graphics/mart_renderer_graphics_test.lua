-- ROM-backed MartRenderer proof against its generated backgrounds and focus layers.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ItemCache = require("libs.assets.src.ItemCache")
local ItemIconAssetProvider = require("libs.hgss.src.presentation.ItemIconAssetProvider")
local MartCache = require("libs.assets.src.MartCache")
local MartRenderer = require("libs.hgss.src.ui.MartRenderer")
local PixelScale = require("libs.ui.src.PixelScale")
local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local MartInterface = require("game.hgss.src.mart.MartInterface")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local marker = cacheFs:read(MartCache.markerPath())
      if
        marker ~= nil
        and MartCache.isReady(cacheFs, marker)
        and cacheFs:read(ItemCache.iconManifestPath()) ~= nil
        and cacheFs:read(ItemCache.iconImagePath()) ~= nil
        and cacheFs:read(FieldFontCache.atlasPath(0)) ~= nil
        and cacheFs:read(FieldUiAssetCache.manifestPath()) ~= nil
      then
        versions[#versions + 1] = versionId
      end
    end
  end
  return versions
end

local function pane(id, x)
  local placement = assert(PixelScale.placeFixed({ x = x, y = 0, width = 256, height = 192 }, 256, 192))
  return { id = id, placement = placement, interactive = id == "lower" }
end

local function plan()
  return {
    panes = { pane("upper", 0), pane("lower", 256) },
    content = {},
  }
end

local function decode(scope, cacheFs, path)
  local bytes = assert(cacheFs:read(path), "the prepared ROM cache contains the source image")
  return scope:own(love.image.newImageData(love.filesystem.newFileData(bytes, path)))
end

local function imageEntry(scope, cacheFs, image, x, y, width, height)
  local data = decode(scope, cacheFs, image)
  for sourceY = y, y + height - 1 do
    for sourceX = x, x + width - 1 do
      local _, _, _, alpha = data:getPixel(sourceX, sourceY)
      if alpha > 0 then
        return data, sourceX, sourceY
      end
    end
  end
  error("the generated source image has an opaque sample", 2)
end

local function opaqueImageEntry(scope, cacheFs, image, x, y, width, height)
  local data = decode(scope, cacheFs, image)
  for sourceY = y, y + height - 1 do
    for sourceX = x, x + width - 1 do
      local _, _, _, alpha = data:getPixel(sourceX, sourceY)
      if alpha >= 0.999 then
        return data, sourceX, sourceY
      end
    end
  end
  error("the generated source image has an opaque sample", 2)
end

local function pixelDiff(first, second, left, top, width, height)
  local changed = 0
  for y = top, top + height - 1 do
    for x = left, left + width - 1 do
      local r1, g1, b1, a1 = first:getPixel(x, y)
      local r2, g2, b2, a2 = second:getPixel(x, y)
      if
        math.floor(r1 * 255 + 0.5) ~= math.floor(r2 * 255 + 0.5)
        or math.floor(g1 * 255 + 0.5) ~= math.floor(g2 * 255 + 0.5)
        or math.floor(b1 * 255 + 0.5) ~= math.floor(b2 * 255 + 0.5)
        or math.floor(a1 * 255 + 0.5) ~= math.floor(a2 * 255 + 0.5)
      then
        changed = changed + 1
      end
    end
  end
  return changed
end

local function iconKey(cacheFs)
  local icons = assert(cacheFs:loadLua(ItemCache.iconManifestPath())).entries
  local keys = {}
  for key in pairs(icons) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local key = assert(keys[1], "the generated icon atlas carries semantic entries")
  return key, assert(icons[key])
end

local function countPalette(data, rect, paletteColor)
  local red, green, blue = paletteColor[1], paletteColor[2], paletteColor[3]
  local count = 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local r, g, b, a = data:getPixel(x, y)
      if
        a > 0
        and math.floor(r * 255 + 0.5) == red
        and math.floor(g * 255 + 0.5) == green
        and math.floor(b * 255 + 0.5) == blue
      then
        count = count + 1
      end
    end
  end
  return count
end

local function expectedPaletteColor(fontDef, index)
  local color = assert(fontDef.palette[index + 1])
  return {
    math.floor(tonumber(color.r or color[1]) + 0.5),
    math.floor(tonumber(color.g or color[2]) + 0.5),
    math.floor(tonumber(color.b or color[3]) + 0.5),
  }
end

local function assertSamePixel(actual, expected, ax, ay, ex, ey, label)
  local ar, ag, ab, aa = actual:getPixel(ax, ay)
  local er, eg, eb, ea = expected:getPixel(ex, ey)
  Assert.equal(math.floor(ar * 255 + 0.5), math.floor(er * 255 + 0.5), label .. " red")
  Assert.equal(math.floor(ag * 255 + 0.5), math.floor(eg * 255 + 0.5), label .. " green")
  Assert.equal(math.floor(ab * 255 + 0.5), math.floor(eb * 255 + 0.5), label .. " blue")
  Assert.equal(math.floor(aa * 255 + 0.5), math.floor(ea * 255 + 0.5), label .. " alpha")
end

local function assertCompositePixel(actual, background, source, x, y, sourceX, sourceY, label, backgroundX, backgroundY)
  local br, bg, bb, ba = background:getPixel(backgroundX or x, backgroundY or y)
  local sr, sg, sb, sa = source:getPixel(sourceX, sourceY)
  local ar, ag, ab, aa = actual:getPixel(x, y)
  local inverse = 1 - sa
  Assert.isTrue(math.abs(ar - (sr * sa + br * inverse)) < 0.01, label .. " red")
  Assert.isTrue(math.abs(ag - (sg * sa + bg * inverse)) < 0.01, label .. " green")
  Assert.isTrue(math.abs(ab - (sb * sa + bb * inverse)) < 0.01, label .. " blue")
  Assert.isTrue(math.abs(aa - (sa + ba * inverse)) < 0.01, label .. " alpha")
end

local function draw(scope, renderer, icons, status, renderPlan, width, height)
  local canvas = scope:own(love.graphics.newCanvas(width or 512, height or 192, { format = "rgba8", readable = true }))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:draw(status, renderPlan or plan(), { icons = icons })
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function saveCapture(data, name)
  local directory = os.getenv("PORTEMON_MART_CAPTURE_DIR")
  if directory == nil then
    return
  end
  local file = assert(io.open(directory .. "/" .. name .. ".png", "wb"))
  file:write(data:encode("png"):getString())
  file:close()
end

local function sourceLayout(measured)
  local set = MartInterface.defaults({ upper = {}, lower = {} })
  local selection = ApplicationLayout.selectSurfaces(measured)
  local context = {
    measurement = measured,
    configuration = measured.configuration,
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = set.nativeLike,
  }
  return set[measured.configuration](context, { state = "browse" })
end

local function layoutMeasurement(width, height, configuration, topology)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = 1,
    configuration = configuration,
    signature = "mart-graphics:" .. configuration .. ":" .. width .. "x" .. height,
  }
end

local function singleTopology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  })
end

local function dualTopology()
  return ScreenTopology.dualDisplay({
    id = "world",
    rect = { x = 400, y = 100, width = 256, height = 192 },
    role = "world",
    touch = false,
  }, {
    id = "aux",
    rect = { x = 100, y = 300, width = 256, height = 192 },
    role = "auxiliary",
    touch = true,
  })
end

local function browseStatus(entryCount, page, pageCount, key, glyph)
  local entries = {}
  for index = 1, 6 do
    local entryIndex = page * 6 + index
    if entryIndex <= entryCount then
      entries[index] = {
        entryKey = "capture-entry-" .. entryIndex,
        displayItemKey = key,
        bindings = { itemName = "POTION" },
        priceVisible = true,
        priceTokens = glyph,
      }
    else
      entries[index] = {}
    end
  end
  return {
    open = true,
    state = "browse",
    lowerMode = "browse",
    presentationKind = "items",
    page = page,
    pageCount = pageCount,
    entryCount = entryCount,
    entries = entries,
    selection = -1,
    balance = 12345,
    currency = "money",
    balanceTokens = glyph,
    pageTokens = glyph,
  }
end

function T.real_generated_backgrounds_and_focus_layers_reach_the_production_renderer(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the mart renderer smoke needs a ready user-owned ROM with derived assets")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = MartCache.loadManifest(cacheFs)
    local uiManifest = assert(cacheFs:loadLua(FieldUiAssetCache.manifestPath()))
    local text = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs }))
    local icons = scope:own(ItemIconAssetProvider.new(cacheFs))
    local window = scope:own(FieldWindowRenderer.new({ cacheFs = cacheFs, manifest = uiManifest }))
    local renderer = MartRenderer.new({
      cacheFs = cacheFs,
      manifest = manifest,
      uiManifest = uiManifest,
      text = text,
      window = window,
      frameIndex = 0,
    })
    scope:own(renderer)

    local status = {
      open = true,
      state = "browse",
      lowerMode = "browse",
      presentationKind = "items",
      page = 0,
      pageCount = 1,
      entryCount = 0,
      entries = { {}, {}, {}, {}, {}, {} },
      selection = -1,
      balance = 0,
      currency = "money",
    }
    local capture = draw(scope, renderer, icons, status)
    local upper = decode(scope, cacheFs, manifest.upper.backgrounds.items.image)
    local lower = decode(scope, cacheFs, manifest.lower.backgrounds.browse[0].image)
    Assert.equal(upper:getWidth(), 256, versionId .. " upper background keeps native width")
    Assert.equal(upper:getHeight(), 192, versionId .. " upper background keeps native height")
    for y = 0, 191 do
      for x = 0, 255 do
        assertSamePixel(capture, upper, x, y, x, y, versionId .. " upper source background at " .. x .. "," .. y)
      end
    end
    assertSamePixel(capture, lower, 256, 0, 0, 0, versionId .. " lower source background reaches its pane origin")

    status.presentationKind = "legacy_decorations"
    local legacy = draw(scope, renderer, icons, status)
    local legacyBackground = decode(scope, cacheFs, manifest.upper.backgrounds.legacy.image)
    for y = 0, 191 do
      for x = 0, 255 do
        assertSamePixel(legacy, legacyBackground, x, y, x, y, versionId .. " legacy source background at " .. x .. "," .. y)
      end
    end

    local key, icon = iconKey(cacheFs)
    local glyph = assert(FieldMessageText.parse("A", text.fontDef, { eos = false }))
    local entry = {
      entryKey = "smoke-entry",
      displayItemKey = key,
      descriptionText = "A",
      bindings = { itemName = "A" },
      ownedQuantity = 0,
      maxQuantity = 99,
    }
    local occupied = {
      open = true,
      state = "browse",
      lowerMode = "browse",
      presentationKind = "items",
      page = 0,
      pageCount = 1,
      entryCount = 1,
      entries = {
        {
          entryKey = entry.entryKey,
          displayItemKey = key,
          bindings = entry.bindings,
          price = 25,
          priceVisible = true,
          priceTokens = glyph,
        },
        {}, {}, {}, {}, {},
      },
      selection = -1,
      currentEntry = entry,
      balance = 0,
      currency = "money",
      balanceTokens = glyph,
      pageTokens = glyph,
    }
    local withEntry = draw(scope, renderer, icons, occupied)
    local iconAtlas = decode(scope, cacheFs, ItemCache.iconImagePath())
    local _, iconX, iconY = opaqueImageEntry(scope, cacheFs, ItemCache.iconImagePath(), icon.x, icon.y, icon.width, icon.height)
    local sampleX = manifest.upper.itemAnchor.x - math.floor(icon.width / 2) + iconX - icon.x
    local sampleY = manifest.upper.itemAnchor.y - math.floor(icon.height / 2) + iconY - icon.y
    assertSamePixel(withEntry, iconAtlas, sampleX, sampleY, iconX, iconY, versionId .. " selected icon uses the generated source crop and anchor")
    local noIconEntry = {
      open = true,
      state = "browse",
      lowerMode = "browse",
      presentationKind = "items",
      page = 0,
      pageCount = 1,
      entryCount = 0,
      entries = { {}, {}, {}, {}, {}, {} },
      selection = -1,
      currentEntry = { descriptionText = "A" },
      balance = 0,
      currency = "money",
      balanceTokens = glyph,
      pageTokens = glyph,
    }
    local descriptionOnly = draw(scope, renderer, icons, noIconEntry)
    Assert.isTrue(
      pixelDiff(withEntry, descriptionOnly, 0, 0, 256, 192) > 0,
      versionId .. " selected item painting adds its source icon beside the description"
    )

    local sealStatus = {
      open = true,
      state = "browse",
      lowerMode = "browse",
      presentationKind = "seals",
      page = 0,
      pageCount = 1,
      entryCount = 1,
      entries = occupied.entries,
      selection = 0,
      currentEntry = entry,
      balance = 0,
      currency = "money",
      balanceTokens = glyph,
      pageTokens = glyph,
    }
    local sealsWithEntry = draw(scope, renderer, icons, sealStatus)
    local legacyWithoutEntry = {
      open = true,
      state = "browse",
      lowerMode = "browse",
      presentationKind = "legacy_decorations",
      page = 0,
      pageCount = 1,
      entryCount = 0,
      entries = { {}, {}, {}, {}, {}, {} },
      selection = -1,
      currentEntry = { descriptionText = "A" },
      balance = 0,
      currency = "money",
      balanceTokens = glyph,
      pageTokens = glyph,
    }
    local legacyWithoutPreview = draw(scope, renderer, icons, legacyWithoutEntry)
    Assert.equal(
      pixelDiff(sealsWithEntry, legacyWithoutPreview, 0, 0, 256, 192),
      0,
      versionId .. " Seal upper presentation uses legacy art and suppresses its selected preview"
    )
    Assert.isTrue(
      pixelDiff(sealsWithEntry, legacyWithoutPreview, 256, 0, 256, 192) > 0,
      versionId .. " Seal stock keeps its lower list icon"
    )
    local itemBounds = manifest.lower.slots[1].labelBox
    local stockForeground = expectedPaletteColor(text.fontDef, 1)
    Assert.isTrue(
      countPalette(withEntry, { x = itemBounds.x + 256, y = itemBounds.y, width = itemBounds.width, height = 16 }, stockForeground) > 0,
      versionId .. " stock labels use the generated stock foreground palette slot"
    )
    local price = manifest.lower.slots[1].priceAt
    Assert.isTrue(
      countPalette(withEntry, { x = price.x + 256, y = price.y, width = 88, height = 16 }, stockForeground) > 0,
      versionId .. " compiled prices use the generated stock foreground palette slot"
    )
    local descriptionBox = manifest.upper.description.items
    local systemForeground = expectedPaletteColor(text.fontDef, 15)
    Assert.isTrue(
      countPalette(withEntry, { x = descriptionBox.x, y = descriptionBox.y, width = descriptionBox.width, height = 16 }, systemForeground) > 0,
      versionId .. " item descriptions use the generated system foreground palette slot"
    )
    local cancelLabel = assert(manifest.text.labels.cancelLabel)
    Assert.isTrue(cancelLabel ~= "", versionId .. " carries the sourced cancel label")
    local cancelWidth = text:textWidth(cancelLabel)
    local cancelBox = manifest.lower.cancelLabelBox
    Assert.isTrue(
      countPalette(withEntry, {
        x = cancelBox.x + 256,
        y = cancelBox.y,
        width = math.min(cancelWidth, cancelBox.width),
        height = cancelBox.height,
      }, systemForeground) > 0,
      versionId .. " cancel label uses its generated text box and system palette"
    )

    local cancelControl = manifest.lower.cancel
    local cancelVisual = manifest.controls[cancelControl.normalVisualKey].normal
    local cancelSource, cancelSourceX, cancelSourceY = opaqueImageEntry(
      scope,
      cacheFs,
      cancelVisual.image,
      0,
      0,
      cancelVisual.width,
      cancelVisual.height
    )
    assertSamePixel(
      withEntry,
      cancelSource,
      256 + cancelControl.anchor.x + cancelVisual.offsetX + cancelSourceX,
      cancelControl.anchor.y + cancelVisual.offsetY + cancelSourceY,
      cancelSourceX,
      cancelSourceY,
      versionId .. " browse cancel control uses its generated normal art"
    )

    local errorPrint = {
      open = true,
      state = "error_print",
      lowerMode = "browse",
      presentationKind = "items",
      page = 0,
      pageCount = 1,
      entryCount = 1,
      entries = occupied.entries,
      selection = 0,
      currentEntry = entry,
      balance = 500,
      currency = "money",
      messageRole = "noRoom",
      messageLines = { { tokens = glyph } },
    }
    local errorPaint = draw(scope, renderer, icons, errorPrint)
    Assert.isTrue(
      pixelDiff(withEntry, errorPaint, 272, 8, 216, 32) > 0,
      versionId .. " error printing adds the generated source window and message pixels"
    )

    occupied.state = "selection_feedback"
    occupied.selection = 0
    local focusFrame, focus, focusImage, focusX, focusY
    for frameIndex, frame in ipairs(manifest.animations.selectionEntry.frames) do
      local candidate = decode(scope, cacheFs, frame.visual.image)
      for y = 0, candidate:getHeight() - 1 do
        for x = 0, candidate:getWidth() - 1 do
          local _, _, _, alpha = candidate:getPixel(x, y)
          if alpha > 0 then
            focusFrame, focus, focusImage, focusX, focusY = frameIndex, frame.visual, candidate, x, y
            break
          end
        end
        if focusFrame ~= nil then
          break
        end
      end
      if focusFrame ~= nil then
        break
      end
    end
    Assert.isTrue(focusFrame ~= nil, versionId .. " source selection animation has a visible frame")
    occupied.animationFrame = focusFrame
    local focused = draw(scope, renderer, icons, occupied)
    local focusAtX = 256 + manifest.lower.slots[1].focusAnchor.x + focus.offsetX + focusX
    local focusAtY = manifest.lower.slots[1].focusAnchor.y + focus.offsetY + focusY
    assertCompositePixel(
      focused,
      withEntry,
      focusImage,
      focusAtX,
      focusAtY,
      focusX,
      focusY,
      versionId .. " selection animation uses its source frame at the item cell"
    )

    local quantity = {
      open = true,
      state = "quantity",
      lowerMode = "quantity",
      presentationKind = "items",
      page = 0,
      pageCount = 1,
      entryCount = 1,
      entries = occupied.entries,
      selection = 0,
      currentEntry = entry,
      balance = 500,
      currency = "money",
      quantity = 2,
      total = 50,
      ownedTokens = glyph,
      totalTokens = glyph,
    }
    local quantityPaint = draw(scope, renderer, icons, quantity)
    local quantityBackground = decode(scope, cacheFs, manifest.lower.backgrounds.quantity.image)
    assertSamePixel(quantityPaint, quantityBackground, 256, 0, 0, 0, versionId .. " quantity state uses the source quantity backdrop")
    local increment = manifest.lower.quantity.increment1
    local incrementVisual = manifest.controls[increment.normalVisualKey].normal
    local incrementSource, incrementX, incrementY = imageEntry(
      scope,
      cacheFs,
      incrementVisual.image,
      0,
      0,
      incrementVisual.width,
      incrementVisual.height
    )
    assertCompositePixel(
      quantityPaint,
      quantityBackground,
      incrementSource,
      256 + increment.anchor.x + incrementVisual.offsetX + incrementX,
      increment.anchor.y + incrementVisual.offsetY + incrementY,
      incrementX,
      incrementY,
      versionId .. " quantity control uses its generated source asset",
      increment.anchor.x + incrementVisual.offsetX + incrementX,
      increment.anchor.y + incrementVisual.offsetY + incrementY
    )

    local confirming = {
      open = true,
      state = "confirm_prompt",
      lowerMode = "confirm",
      presentationKind = "items",
      page = 0,
      pageCount = 1,
      entryCount = 1,
      entries = occupied.entries,
      selection = 0,
      currentEntry = entry,
      balance = 500,
      currency = "money",
      messageRole = "moneyConfirm",
      messageLines = { { tokens = glyph } },
      prompt = {
        active = true,
        selected = "yes",
        selectionHighlighted = true,
        buttons = {
          yes = { x = 24, y = 64, width = 40, height = 16 },
          no = { x = 24, y = 88, width = 40, height = 16 },
        },
      },
    }
    local confirmation = draw(scope, renderer, icons, confirming)
    local confirmBackground = decode(scope, cacheFs, manifest.lower.backgrounds.confirm.image)
    assertSamePixel(confirmation, confirmBackground, 256, 0, 0, 0, versionId .. " confirmation uses the source confirm backdrop")
    local promptVisual = uiManifest.yesNoPrompt.shapes.compact.yes.selected
    local promptAsset = assert(uiManifest.assets[promptVisual.asset])
    local promptData, promptX, promptY = opaqueImageEntry(
      scope,
      cacheFs,
      promptAsset.image,
      promptVisual.rect.x,
      promptVisual.rect.y,
      promptVisual.rect.width,
      promptVisual.rect.height
    )
    assertSamePixel(
      confirmation,
      promptData,
      256 + confirming.prompt.buttons.yes.x + promptX - promptVisual.rect.x,
      confirming.prompt.buttons.yes.y + promptY - promptVisual.rect.y,
      promptX,
      promptY,
      versionId .. " confirmation prompt uses its source selected-button crop"
    )

    local captureStates = {
      ["browse-count-0"] = browseStatus(0, 0, 1, key, glyph),
      ["browse-count-1"] = browseStatus(1, 0, 1, key, glyph),
      ["browse-count-5"] = browseStatus(5, 0, 1, key, glyph),
      ["browse-count-6"] = browseStatus(6, 0, 1, key, glyph),
      ["browse-page-2"] = browseStatus(13, 1, 3, key, glyph),
      quantity = quantity,
      confirmation = confirming,
    }
    for _, scenario in ipairs({
      { name = "money-error", role = "insufficientMoney", currency = "money" },
      { name = "points-error", role = "insufficientPoints", currency = "athlete_points" },
      { name = "daily-sold", role = "boughtToday", currency = "athlete_points" },
      { name = "card-owned", role = "alreadyOwned", currency = "athlete_points" },
    }) do
      captureStates[scenario.name] = {
        open = true,
        state = "error_print",
        lowerMode = "browse",
        presentationKind = "items",
        page = 0,
        pageCount = 1,
        entryCount = 1,
        entries = occupied.entries,
        selection = 0,
        currentEntry = entry,
        balance = 0,
        currency = scenario.currency,
        messageRole = scenario.role,
        messageLines = { { tokens = glyph } },
      }
    end
    captureStates.sale = {
      open = true,
      state = "success_print",
      lowerMode = "browse",
      presentationKind = "items",
      page = 0,
      pageCount = 1,
      entryCount = 1,
      entries = occupied.entries,
      selection = 0,
      currentEntry = entry,
      balance = 125,
      currency = "money",
      messageRole = "itemReceived",
      messageLines = { { tokens = glyph } },
    }
    for name, state in pairs(captureStates) do
      saveCapture(draw(scope, renderer, icons, state), versionId .. "-" .. name)
    end

    local layouts = {
      {
        name = "nativeLike",
        measured = layoutMeasurement(640, 480, "nativeLike", singleTopology(640, 480)),
        expectedPanes = 1,
      },
      {
        name = "wide",
        measured = layoutMeasurement(1280, 720, "wide", singleTopology(1280, 720)),
        expectedPanes = 2,
      },
      {
        name = "tall",
        measured = layoutMeasurement(600, 1000, "tall", singleTopology(600, 1000)),
        expectedPanes = 2,
      },
      {
        name = "dualDisplay",
        measured = layoutMeasurement(800, 600, "dualDisplay", dualTopology()),
        expectedPanes = 2,
      },
    }
    for _, layoutCase in ipairs(layouts) do
      local actualPlan = sourceLayout(layoutCase.measured)
      Assert.equal(#actualPlan.panes, layoutCase.expectedPanes, versionId .. " " .. layoutCase.name .. " uses its actual mart plan")
      local capture = draw(
        scope,
        renderer,
        icons,
        occupied,
        actualPlan,
        layoutCase.measured.width,
        layoutCase.measured.height
      )
      saveCapture(capture, versionId .. "-layout-" .. layoutCase.name)
      Assert.isTrue(pixelDiff(capture, scope:own(love.image.newImageData(layoutCase.measured.width, layoutCase.measured.height)), 0, 0, layoutCase.measured.width, layoutCase.measured.height) > 0, versionId .. " " .. layoutCase.name .. " paints the production mart plan")
    end

    local martReads = 0
    local created = 0
    local released = 0
    local martPrefix = MartCache.assetDir() .. "/"
    local cacheProbe = {
      read = function(_, path)
        if path:sub(1, #martPrefix) == martPrefix then
          martReads = martReads + 1
        end
        if martReads > 1 and path:sub(1, #martPrefix) == martPrefix then
          return nil
        end
        return assert(cacheFs:read(path))
      end,
    }
    local graphicsProbe = setmetatable({
      newImage = function(fileData)
        local image = love.graphics.newImage(fileData)
        created = created + 1
        return {
          setFilter = function(_, ...)
            image:setFilter(...)
          end,
          getDimensions = function()
            return image:getDimensions()
          end,
          getWidth = function()
            return image:getWidth()
          end,
          getHeight = function()
            return image:getHeight()
          end,
          release = function()
            released = released + 1
            image:release()
          end,
        }
      end,
      newQuad = function(...)
        return love.graphics.newQuad(...)
      end,
    }, { __index = love.graphics })
    local built = pcall(MartRenderer.new, {
      cacheFs = cacheProbe,
      manifest = manifest,
      text = text,
      window = window,
      frameIndex = 0,
      uiManifest = uiManifest,
      graphics = graphicsProbe,
    })
    Assert.isFalse(built, versionId .. " a missing later source visual rejects renderer construction")
    Assert.isTrue(created > 0, versionId .. " partial renderer construction acquired source images")
    Assert.equal(released, created, versionId .. " partial renderer construction releases every acquired image")

    renderer:release()
    renderer:release()
    Assert.isTrue(renderer._released, versionId .. " renderer disposal is idempotent")
    Assert.equal(next(renderer._images), nil, versionId .. " disposal releases owned mart images")
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets = { "mart:global", "items:global", "field-font:global", "field-ui:global" }
return suite
