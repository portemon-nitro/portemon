-- Production-composed graphics coverage for both Apricorn Box modes.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local ApricornBoxRenderer = require("libs.hgss.src.ui.ApricornBoxRenderer")
local ApricornBoxScreenState = require("game.hgss.src.apricorn.ApricornBoxScreenState")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local T = {}
local BACKGROUND = { 0.08, 0.08, 0.1 }

local function measurement(topology, width, height, signature)
  return { width = width, height = height, topology = topology, pixelRatio = 1, signature = signature }
end

local function stock(manifest)
  local apricorns = {}
  for index, row in ipairs(manifest.rows) do
    apricorns[row.apricornKey] = index * 3
  end
  return {
    capture = function()
      return { apricorns = apricorns }
    end,
  }
end

local function messageProvider(cacheFs)
  local provider = require("libs.hgss.src.interaction.FieldMessageProvider").new(cacheFs)
  return provider
end

-- Versions with an imported ROM and a prepared Apricorn Box manifest:
-- the smoke renders every ready version and skips cleanly when no
-- user-owned ROM is available, exactly like the other asset smokes.
local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      if cacheFs:exists(ApricornBoxAssetCache.manifestPath()) then
        versions[#versions + 1] = versionId
      end
    end
  end
  return versions
end

local function makeTopology(name)
  if name == "dual" then
    return ScreenTopology.dualDisplay(
      { id = "world", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "aux", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
      512,
      384
  end
  local width, height =
    name == "native" and 512 or name == "wide" and 1000 or 600,
    name == "native" and 384 or name == "wide" and 600 or 1000
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  }),
    width,
    height
end

local function writeCapture(image, filename)
  local directory = os.getenv("PORTEMON_APRICORN_BOX_CAPTURE_DIR")
  if directory == nil then
    return
  end
  local encoded = image:encode("png")
  local file = assert(io.open(directory .. "/" .. filename, "wb"))
  assert(file:write(encoded:getString()))
  assert(file:close())
end

local function assertVisiblePixels(pixels)
  local backgroundRed = math.floor(BACKGROUND[1] * 255 + 0.5)
  local backgroundGreen = math.floor(BACKGROUND[2] * 255 + 0.5)
  local backgroundBlue = math.floor(BACKGROUND[3] * 255 + 0.5)
  local changedPixels = 0
  for index = 1, #pixels, 4 do
    local red, green, blue = pixels:byte(index, index + 2)
    if
      math.abs(red - backgroundRed) > 8
      or math.abs(green - backgroundGreen) > 8
      or math.abs(blue - backgroundBlue) > 8
    then
      changedPixels = changedPixels + 1
    end
  end
  Assert.isTrue(changedPixels >= 1024, "the rendered capture contains at least 1024 visible pixels")
end

local function assertPromptButtons(image, cacheFs, uiManifest, placement, prompt)
  local origin = placement.origin or placement.frame
  local selected = assert(prompt.selected, "the active confirmation prompt identifies its focused choice")
  local highlighted = assert(prompt.selectionHighlighted, "the active prompt identifies its focus highlight")
  for _, choice in ipairs({ "yes", "no" }) do
    local state = choice == selected and highlighted and "selected" or "normal"
    local visual = assert(uiManifest.yesNoPrompt.shapes.compact[choice][state])
    local asset = assert(uiManifest.assets[visual.asset])
    local data = assert(cacheFs:read(asset.image), "the source prompt-button image exists")
    local source = love.image.newImageData(love.filesystem.newFileData(data, asset.image))
    local button = assert(prompt.buttons[choice], "the active prompt exposes its button rectangle")
    local matchingPixels = 0
    local opaquePixels = 0
    for sourceY = 0, visual.rect.height - 1 do
      for sourceX = 0, visual.rect.width - 1 do
        local red, green, blue, alpha = source:getPixel(visual.rect.x + sourceX, visual.rect.y + sourceY)
        if alpha > 0.95 then
          opaquePixels = opaquePixels + 1
          local hostX = math.floor(origin.x + (button.x + sourceX + 0.5) * placement.scale)
          local hostY = math.floor(origin.y + (button.y + sourceY + 0.5) * placement.scale)
          local actualRed, actualGreen, actualBlue = image:getPixel(hostX, hostY)
          if
            math.abs(actualRed - red) < 0.025
            and math.abs(actualGreen - green) < 0.025
            and math.abs(actualBlue - blue) < 0.025
          then
            matchingPixels = matchingPixels + 1
          end
        end
      end
    end
    Assert.isTrue(
      opaquePixels > 0 and matchingPixels >= opaquePixels * 0.9,
      choice .. " button matches its focused source art inside the transformed button rectangle"
    )
  end
end

local function render(scope, cacheFs, manifest, renderer, window, versionId, topologyName, mode)
  local topology, width, height = makeTopology(topologyName)
  local currentMeasurement = measurement(topology, width, height, topologyName)
  local provider = messageProvider(cacheFs)
  local fontDef = FieldFontLoader.load(cacheFs)
  local uiManifest = assert(cacheFs:loadLua(FieldUiAssetCache.manifestPath()))
  local screen = ApricornBoxScreenState.new({
    mode = mode,
    service = stock(manifest),
    effect = function() end,
    manifest = manifest,
    messageProvider = provider,
    fontDef = fontDef,
    uiManifest = uiManifest,
    measureDisplay = function()
      return currentMeasurement
    end,
  })
  scope:own({
    release = function()
      screen:dispose()
    end,
  })
  screen:updateFixed({ { type = "confirm" } })
  if mode == "kurt_select" then
    for _ = 1, 4 do
      screen:updateFixed({})
    end
    screen:updateFixed({ { type = "confirm" } })
    screen:updateFixed({ { type = "navigate", direction = "right" } })
    screen:updateFixed({ { type = "confirm" } })
  end
  local view = screen:status()
  Assert.equal(view.phase, mode == "browse" and "actions" or "confirm", "capture shows the mode's active Box controls")
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 1)
  view.presentation.render({ graphics = love.graphics, apricornBoxRenderer = renderer }, view, view.presentation)
  for _, frame in ipairs(view.presentation.frames) do
    LogicalSurface.draw(love.graphics, frame.placement, function()
      window:drawApplicationFrame(frame.contentBox, 0)
    end)
  end
  love.graphics.setCanvas()
  local image = scope:own(canvas:newImageData())
  assertVisiblePixels(image:getString())
  if mode == "kurt_select" then
    local lowerPane
    for _, pane in ipairs(view.presentation.panes) do
      if pane.id == "lower" then
        lowerPane = pane
        break
      end
    end
    assertPromptButtons(image, cacheFs, uiManifest, assert(lowerPane).placement, assert(view.confirmationPrompt))
  end
  writeCapture(image, versionId .. "-" .. mode .. "-" .. topologyName .. ".png")

  if mode == "kurt_select" then
    screen:updateFixed({ { type = "navigate", direction = "down" } })
    view = screen:status()
    Assert.equal(view.confirmationPrompt.selected, "no", "navigation changes the focused prompt choice")
    love.graphics.setCanvas(canvas)
    love.graphics.clear(BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 1)
    view.presentation.render({ graphics = love.graphics, apricornBoxRenderer = renderer }, view, view.presentation)
    for _, frame in ipairs(view.presentation.frames) do
      LogicalSurface.draw(love.graphics, frame.placement, function()
        window:drawApplicationFrame(frame.contentBox, 0)
      end)
    end
    love.graphics.setCanvas()
    local noImage = scope:own(canvas:newImageData())
    local lowerPane
    for _, pane in ipairs(view.presentation.panes) do
      if pane.id == "lower" then
        lowerPane = pane
        break
      end
    end
    assertPromptButtons(noImage, cacheFs, uiManifest, assert(lowerPane).placement, assert(view.confirmationPrompt))
    writeCapture(noImage, versionId .. "-" .. mode .. "-" .. topologyName .. "-no.png")
  end
end

local function assertSourceLabels(cacheFs, manifest)
  local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
  local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
  local provider = FieldMessageProvider.new(cacheFs)
  Assert.isTrue(cacheFs:exists(FieldMessageCache.bankPath(21)), "the focused Box import publishes bank 21")
  local bank = assert(provider:acquireBank(manifest.messageBankId))
  Assert.equal(bank.bankId, 21)
  local labels = { "Red Apricorn", "Ylw Apricorn", "Blu Apricorn" }
  for rowIndex, expected in ipairs(labels) do
    local row = manifest.rows[rowIndex]
    Assert.equal(provider:get(manifest.messageBankId, row.nameMessageId).text, expected)
  end
  provider:releaseBank(manifest.messageBankId)
end

local function trackingGraphics(failAt, failFilterAt)
  local calls = { created = 0, released = 0, filters = 0 }
  local graphics = {
    newImage = function()
      calls.created = calls.created + 1
      if calls.created == failAt then
        error("injected Box image allocation failure")
      end
      return {
        setFilter = function()
          calls.filters = calls.filters + 1
          if calls.filters == failFilterAt then
            error("injected Box image filter failure")
          end
        end,
        getWidth = function()
          return 512
        end,
        getHeight = function()
          return 512
        end,
        release = function()
          calls.released = calls.released + 1
        end,
      }
    end,
    newQuad = function()
      return {}
    end,
    draw = function() end,
    setColor = function() end,
  }
  return graphics, calls
end

function T.box_renderer_releases_prompt_and_source_images_once(_, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the Box smoke needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = ApricornBoxAssetCache.loadManifest(cacheFs)
    local uiManifest = assert(cacheFs:loadLua(FieldUiAssetCache.manifestPath()))
    local promptAssets = {}
    local compact = uiManifest.yesNoPrompt.shapes.compact
    for _, row in ipairs({ compact.yes, compact.no }) do
      for _, state in ipairs({ row.normal, row.selected }) do
        promptAssets[state.asset] = true
      end
    end
    local promptAssetCount = 0
    for _ in pairs(promptAssets) do
      promptAssetCount = promptAssetCount + 1
    end
    local successGraphics, successCalls = trackingGraphics()
    local renderer = ApricornBoxRenderer.new({
      cacheFs = cacheFs,
      manifest = manifest,
      text = { drawText = function() end },
      uiManifest = uiManifest,
      graphics = successGraphics,
    })
    renderer:release()
    renderer:release()
    Assert.equal(successCalls.released, successCalls.created, "successful construction releases every owned image once")

    local boxAssetCount = #ApricornBoxAssetCache.referencedPaths(manifest)
    local failureGraphics, failureCalls = trackingGraphics(boxAssetCount + 1)
    local ok, err = pcall(ApricornBoxRenderer.new, {
      cacheFs = cacheFs,
      manifest = manifest,
      text = { drawText = function() end },
      uiManifest = uiManifest,
      graphics = failureGraphics,
    })
    Assert.isFalse(ok, "a prompt image allocation failure propagates")
    Assert.isTrue(tostring(err):find("injected Box image allocation failure", 1, true) ~= nil)
    Assert.equal(
      failureCalls.created,
      boxAssetCount + 1,
      "failure occurs after source Box images were acquired"
    )
    Assert.equal(failureCalls.released, boxAssetCount, "partial construction releases every source image once")

    local filterFailureGraphics, filterFailureCalls = trackingGraphics(nil, 1)
    local filterOk, filterErr = pcall(ApricornBoxRenderer.new, {
      cacheFs = cacheFs,
      manifest = manifest,
      text = { drawText = function() end },
      uiManifest = uiManifest,
      graphics = filterFailureGraphics,
    })
    Assert.isFalse(filterOk, "an image filter failure propagates")
    Assert.isTrue(tostring(filterErr):find("injected Box image filter failure", 1, true) ~= nil)
    Assert.equal(filterFailureCalls.created, 1, "filter failure follows image acquisition")
    Assert.equal(filterFailureCalls.released, 1, "filter failure releases the acquired image once")

    local promptFilterGraphics, promptFilterCalls = trackingGraphics(nil, boxAssetCount + 1)
    local promptFilterOk, promptFilterErr = pcall(ApricornBoxRenderer.new, {
      cacheFs = cacheFs,
      manifest = manifest,
      text = { drawText = function() end },
      uiManifest = uiManifest,
      graphics = promptFilterGraphics,
    })
    Assert.isFalse(promptFilterOk, "a prompt image filter failure propagates")
    Assert.isTrue(tostring(promptFilterErr):find("injected Box image filter failure", 1, true) ~= nil)
    Assert.equal(promptFilterCalls.created, boxAssetCount + 1, "prompt filter failure follows image acquisition")
    Assert.equal(
      promptFilterCalls.released,
      boxAssetCount + 1,
      "prompt filter failure releases source and prompt images once"
    )
  end
end

function T.source_box_renders_browse_and_kurt_modes_for_each_layout(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the Box smoke needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = ApricornBoxAssetCache.loadManifest(cacheFs)
    assertSourceLabels(cacheFs, manifest)
    local text = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs, graphics = love.graphics }))
    local uiManifest = assert(cacheFs:loadLua(FieldUiAssetCache.manifestPath()))
    local window = scope:own(FieldWindowRenderer.new({
      cacheFs = cacheFs,
      manifest = uiManifest,
      graphics = love.graphics,
    }))
    local renderer = scope:own(ApricornBoxRenderer.new({
      cacheFs = cacheFs,
      manifest = manifest,
      text = text,
      uiManifest = uiManifest,
      graphics = love.graphics,
    }))
    for _, topology in ipairs({ "native", "wide", "tall", "dual" }) do
      for _, mode in ipairs({ "browse", "kurt_select" }) do
        render(scope, cacheFs, manifest, renderer, window, versionId, topology, mode)
      end
    end
  end
end

local suite = GraphicsSmoke.suite(T, {
  tags = { "apricorn" },
  capabilities = { "graphics", "derived_assets" },
})
suite.metadata.derivedAssets = { "apricorn-box:global", "field-font:global", "field-ui:global" }

return suite
