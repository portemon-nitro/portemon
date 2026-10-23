-- Renders the generated title model through the production HGSS model renderer.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local DisplayContext = require("libs.ui.src.DisplayContext")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local RomImporter = require("romdump.src.source.RomImporter")

local function topology(kind)
  return function(width, height)
    local touch = true
    if kind ~= "dual" then
      return {
        surfaces = {
          { id = "main", rect = { x = 0, y = 0, width = width, height = height }, touch = touch, role = "world" },
        },
      }
    end
    local half = height / 2
    return {
      surfaces = {
        { id = "upper", rect = { x = 0, y = 0, width = width, height = half }, touch = false, role = "world" },
        { id = "lower", rect = { x = 0, y = half, width = width, height = half }, touch = true, role = "auxiliary" },
      },
    }
  end
end

local function drawBytes(scene, scope, width, height)
  local canvas = scope:own(love.graphics.newCanvas(width, height, { format = "rgba8", readable = true }))
  love.graphics.push("all")
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  scene:draw()
  love.graphics.setCanvas()
  love.graphics.pop()
  local imageData = scope:own(canvas:newImageData())
  return imageData:getString()
end

local function countTitleImageDraws(scene, scope, width, height)
  local counts = { canvas = 0, logo = 0, lower = 0, decor = 0 }
  local canvas = scene.canvas
  local surfaces = scene.surfaces or {}
  local logo, lower, decor = surfaces.editionLogo, surfaces.subscreenLower, surfaces.subscreenDecor
  local graphics = love.graphics
  local originalDraw = graphics.draw
  graphics.draw = function(drawable, ...)
    if drawable == canvas then
      counts.canvas = counts.canvas + 1
    elseif drawable == logo then
      counts.logo = counts.logo + 1
    elseif drawable == lower then
      counts.lower = counts.lower + 1
    elseif drawable == decor then
      counts.decor = counts.decor + 1
    end
    return originalDraw(drawable, ...)
  end
  local ok, failure = pcall(drawBytes, scene, scope, width, height)
  graphics.draw = originalDraw
  if not ok then
    error(failure, 0)
  end
  return counts
end

local function renderEdition(scope, versionId)
  local HgssTitleScene = require("libs.hgss.src.presentation.HgssTitleScene")
  local context = DisplayContext.new({ graphics = love.graphics, topologyProvider = topology("single") })
  local scene = HgssTitleScene.new({
    versionId = versionId,
    cacheFs = CacheFs.forVersion(versionId),
    width = 512,
    height = 384,
    displayContext = context,
  })
  scope:own({
    release = function()
      scene:dispose()
    end,
  })

  local button = scene:editionButtonBounds()
  Assert.isTrue(button.x >= 0 and button.y >= 0, "edition control stays inside the drawable")
  Assert.isTrue(
    button.x + button.width <= 512 and button.y + button.height <= 384,
    "edition control fits the safe bounds"
  )
  Assert.equal(versionId == "heartgold", button.x > 256, "HeartGold edition control is in the bottom-right corner")

  local firstFrame = drawBytes(scene, scope, 512, 384)
  for _ = 1, 45 do
    scene:updateFixed()
  end
  local laterFrame = drawBytes(scene, scope, 512, 384)
  Assert.isTrue(firstFrame ~= laterFrame, "source model and prompt animation change rendered title pixels")

  for _, layout in ipairs({
    { kind = "single", configuration = "nativeLike", width = 512, height = 384 },
    { kind = "single", configuration = "wide", width = 1200, height = 600 },
    { kind = "single", configuration = "tall", width = 600, height = 1000 },
    { kind = "dual", configuration = "dualDisplay", width = 512, height = 384 },
  }) do
    scene.displayContext = DisplayContext.new({ graphics = love.graphics, topologyProvider = topology(layout.kind) })
    scene:resize(layout.width, layout.height)
    Assert.equal(
      scene.layout.configuration,
      layout.configuration,
      "the measured host selects its intended title composition"
    )
    local composition = scene.layout.composition
    Assert.equal(
      composition.configuration,
      layout.configuration,
      "the selected composition controls production drawing"
    )
    local stageDraws = countTitleImageDraws(scene, scope, layout.width, layout.height)
    Assert.equal(stageDraws.decor, 0, "no layout paints the retired text art")
    if layout.configuration == "wide" then
      Assert.isFalse(
        composition.stageWidth == 512 and composition.stageHeight == 192,
        "wide title uses one panoramic stage, not two peer screens"
      )
      Assert.isFalse(composition.lowerPanel == true, "wide title has no peer lower panel")
      Assert.equal(stageDraws.canvas, 1, "wide title draws the live animated canvas exactly once")
      Assert.equal(stageDraws.logo, 0, "wide title carries no edition logo")
      Assert.equal(stageDraws.lower, 1, "wide title keeps the lower accent above the legendary")
      local beforeWide = drawBytes(scene, scope, layout.width, layout.height)
      for _ = 1, 30 do
        scene:updateFixed()
      end
      local afterWide = drawBytes(scene, scope, layout.width, layout.height)
      Assert.isTrue(beforeWide ~= afterWide, "wide title animation advances on the panoramic stage")
      local boundsCenter = composition.bounds.x + composition.bounds.width / 2
      local wideButton = scene:editionButtonBounds()
      local buttonCenter = wideButton.x + wideButton.width / 2
      if versionId == "heartgold" then
        Assert.isTrue(buttonCenter > boundsCenter, "HeartGold edition control stays in the bottom-right corner")
      else
        Assert.isTrue(buttonCenter < boundsCenter, "SoulSilver edition control stays in the bottom-left corner")
      end
    elseif layout.configuration == "tall" then
      Assert.isTrue(composition.lowerPanel == true, "tall title keeps its lower panel")
      Assert.isTrue(composition.upper ~= nil and composition.lower ~= nil, "tall title stacks two source roles")
      Assert.equal(stageDraws.canvas, 1, "tall upper stage renders the legendary exactly once")
      Assert.equal(stageDraws.logo, 1, "tall lower stage shows the edition mark")
      Assert.equal(stageDraws.lower, 1, "tall lower stage keeps its lower art")
    elseif layout.configuration == "nativeLike" then
      Assert.isFalse(composition.lowerPanel == true, "4:3 keeps a single 3D stage")
      Assert.equal(stageDraws.canvas, 1, "4:3 draws the live animated canvas exactly once")
      Assert.equal(stageDraws.logo, 0, "4:3 carries no edition logo")
      Assert.equal(stageDraws.lower, 1, "4:3 keeps the lower accent above the legendary")
    else
      local primary, secondary = scene.layout.primary, scene.layout.secondary
      Assert.isTrue(secondary ~= nil, "physical dual display preserves both source surfaces")
      Assert.isTrue(
        primary.y + primary.height <= secondary.y or secondary.y + secondary.height <= primary.y,
        "dual display keeps upper and lower source roles on separate surfaces"
      )
    end
    local resizedButton = scene:editionButtonBounds()
    Assert.isTrue(resizedButton.x >= 0 and resizedButton.y >= 0, "resizing preserves the edition control safe area")
    Assert.isTrue(
      resizedButton.x + resizedButton.width <= layout.width and resizedButton.y + resizedButton.height <= layout.height,
      "resized edition control stays visible"
    )
    drawBytes(scene, scope, layout.width, layout.height)
  end

  local originalDraw = scene.renderer.draw
  scene.renderer.draw = function()
    error("synthetic model renderer failure")
  end
  local drawOk = pcall(function()
    scene:draw()
  end)
  scene.renderer.draw = originalDraw
  Assert.isFalse(drawOk, "a renderer failure remains diagnosable by the title owner")
  Assert.equal(love.graphics.getCanvas(), nil, "a renderer failure restores the previous canvas")
  scene:draw()
end

local function renderAvailableEditions(scope, context)
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  if #versions == 0 then
    context:skip("no supported user-owned ROM is ready")
  end
  for _, versionId in ipairs(versions) do
    renderEdition(scope, versionId)
  end
end

local function readyVersionsOrSkip(context)
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  if #versions == 0 then
    context:skip("no supported user-owned ROM is ready")
  end
  return versions
end

local function openTitleScene(scope, versionId, width, height, kind)
  local HgssTitleScene = require("libs.hgss.src.presentation.HgssTitleScene")
  local context = DisplayContext.new({ graphics = love.graphics, topologyProvider = topology(kind) })
  local scene = HgssTitleScene.new({
    versionId = versionId,
    cacheFs = CacheFs.forVersion(versionId),
    width = width,
    height = height,
    displayContext = context,
  })
  scope:own({
    release = function()
      scene:dispose()
    end,
  })
  return scene
end

local function sourceVerticalFov(projection)
  return 2 * math.atan(1 / projection[6])
end

local function withRendererCapture(scene, fn)
  local seen = {}
  local renderer = assert(scene.renderer)
  local originalDraw = renderer.draw
  renderer.draw = function(self, environment, camera, ...)
    seen.environment = environment
    seen.camera = camera
    return originalDraw(self, environment, camera, ...)
  end
  local ok, failure = pcall(fn, seen)
  renderer.draw = originalDraw
  if not ok then
    error(failure, 0)
  end
  return seen
end

local function assertTwoWhiteSceneLights(lighting, message)
  Assert.notNil(lighting, message or "title hands the renderer a lighting record")
  Assert.isTrue(type(lighting.records) == "table" and #lighting.records > 0, "title lighting carries records")
  local lights = assert(lighting.records[1].lights, "title lighting record carries lights")
  local enabled = {}
  for _, light in ipairs(lights) do
    if light.enabled ~= false then
      enabled[#enabled + 1] = light
    end
  end
  Assert.equal(#enabled, 2, "title enables exactly two scene lights")
  for _, light in ipairs(enabled) do
    local color = assert(light.color or light.colour, "title light carries a color")
    Assert.equal(color[1], color[2], "title light is neutral white")
    Assert.equal(color[2], color[3], "title light is neutral white")
    Assert.isTrue(color[1] > 0, "title light is on")
  end
end

local function titleDeliversSourceCameraAndLighting(scope, context)
  local Matrix4 = require("libs.math.src.Matrix4")
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    local scene = openTitleScene(scope, versionId, 512, 384, "single")
    local camera = scene:_camera()
    local halfAngle = (0xB60 / 65536) * (2 * math.pi)
    Assert.near(sourceVerticalFov(camera.projection()), 2 * halfAngle, 0.02, "title uses the source half-angle")
    local timeline = assert(scene.bundle.timeline, "title bundle carries its camera timeline")
    Assert.deepEqual(
      camera.view(),
      Matrix4.lookAt(timeline.camera.endPosition, timeline.camera.target, { 0, 1, 0 }),
      "title opens on its sourced end pose"
    )
    withRendererCapture(scene, function(seen)
      scene:_drawModel()
      assertTwoWhiteSceneLights(seen.environment and seen.environment.lighting)
    end)
    scene:dispose()
  end
end

local function titleOverlayPhasesFollowTheirSourcedSchedule(scope, context)
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    local scene = openTitleScene(scope, versionId, 512, 384, "single")
    local promptText = assert(scene.bundle.prompt.text, "title bundle carries its start prompt")
    local graphics = love.graphics
    local originalPrintf, originalDraw = graphics.printf, graphics.draw
    local printed, overlayDraws = {}, {}
    graphics.printf = function(text, ...)
      printed[#printed + 1] = text
      return originalPrintf(text, ...)
    end
    graphics.draw = function(drawable, ...)
      local surfaces = scene.surfaces or {}
      if
        drawable == surfaces.editionLogo
        or drawable == surfaces.subscreenLower
        or drawable == surfaces.subscreenDecor
      then
        local red, green, blue, alpha = graphics.getColor()
        overlayDraws[#overlayDraws + 1] = { drawable = drawable, color = { red, green, blue, alpha } }
      end
      return originalDraw(drawable, ...)
    end
    local promptAt, overlayAt = {}, {}
    local samples = {}
    for _, tick in ipairs({ 0, 1, 2, 20, 29, 30, 31, 40, 45, 59, 60, 74, 75, 100, 110, 143, 160 }) do
      samples[tick] = true
    end
    local function record()
      for _, text in ipairs(printed) do
        if text == promptText then
          promptAt[scene.tick] = true
          break
        end
      end
      if promptAt[scene.tick] == nil then
        promptAt[scene.tick] = false
      end
      local signature = {}
      for _, draw in ipairs(overlayDraws) do
        signature[#signature + 1] = string.format(
          "%s:%.2f,%.2f,%.2f,%.2f",
          tostring(draw.drawable),
          draw.color[1],
          draw.color[2],
          draw.color[3],
          draw.color[4]
        )
      end
      overlayAt[scene.tick] = table.concat(signature, "|")
    end
    local drawOk, drawFailure = pcall(function()
      printed, overlayDraws = {}, {}
      scene:draw()
      record()
      for _ = 1, 160 do
        scene:updateFixed()
        if samples[scene.tick] then
          printed, overlayDraws = {}, {}
          scene:draw()
          record()
        end
      end
    end)
    graphics.printf, graphics.draw = originalPrintf, originalDraw
    Assert.isTrue(drawOk, tostring(drawFailure))
    for _, tick in ipairs({ 0, 1, 2, 29 }) do
      Assert.isFalse(promptAt[tick], "start prompt stays hidden through its opening delay")
    end
    for _, tick in ipairs({ 30, 31, 45, 59 }) do
      Assert.isTrue(promptAt[tick], "start prompt shows after its opening delay")
    end
    for _, tick in ipairs({ 60, 74 }) do
      Assert.isFalse(promptAt[tick], "start prompt hides again after its visible window")
    end
    for _, tick in ipairs({ 75, 100 }) do
      Assert.isTrue(promptAt[tick], "start prompt repeats after its hidden window")
    end
    Assert.isTrue(overlayAt[1] ~= overlayAt[20], "title reveal executes across its transition")
    Assert.isTrue(overlayAt[40] ~= overlayAt[110], "title glow cycles instead of holding one palette")
    scene:dispose()
  end
end

local function rectOf(record, width, height)
  return { x = record.x, y = record.y, width = width * record.sx, height = height * record.sy }
end

local function covers(rect, region)
  return rect.x <= region.x
    and rect.y <= region.y
    and rect.x + rect.width >= region.x + region.width
    and rect.y + rect.height >= region.y + region.height
end

local function overlaps(a, b)
  return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

local function captureComposedDraws(scene, scope, width, height)
  local graphics = love.graphics
  local originalDraw, originalRectangle = graphics.draw, graphics.rectangle
  local draws, rectangles = {}, {}
  graphics.draw = function(drawable, x, y, rotation, sx, sy, ...)
    if type(x) == "number" then
      local red, green, blue, alpha = graphics.getColor()
      draws[#draws + 1] =
        { drawable = drawable, x = x, y = y, sx = sx or 1, sy = sy or sx or 1, color = { red, green, blue, alpha } }
    end
    return originalDraw(drawable, x, y, rotation, sx, sy, ...)
  end
  graphics.rectangle = function(mode, x, y, w, h, ...)
    local red, green, blue, alpha = graphics.getColor()
    rectangles[#rectangles + 1] = { mode = mode, x = x, y = y, w = w, h = h, color = { red, green, blue, alpha } }
    return originalRectangle(mode, x, y, w, h, ...)
  end
  local ok, failure = pcall(drawBytes, scene, scope, width, height)
  graphics.draw, graphics.rectangle = originalDraw, originalRectangle
  if not ok then
    error(failure, 0)
  end
  return draws, rectangles
end

local function drawsOf(draws, image)
  local found = {}
  for _, record in ipairs(draws) do
    if record.drawable == image then
      found[#found + 1] = record
    end
  end
  return found
end

local function compactAndWideFillWithTheLegend(scope, context)
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    for _, layout in ipairs({
      { width = 512, height = 384 },
      { width = 1280, height = 720 },
      { width = 1680, height = 720 },
    }) do
      local scene = openTitleScene(scope, versionId, layout.width, layout.height, "single")
      local bounds = assert(scene.layout.composition.bounds, "title composition has drawable bounds")
      local canvasWidth, canvasHeight = scene.canvas:getDimensions()
      Assert.isTrue(
        canvasWidth <= 1024 and canvasHeight <= 576,
        "title 3D target stays bounded instead of matching the window"
      )
      local draws, rectangles = captureComposedDraws(scene, scope, layout.width, layout.height)
      local surfaces = assert(scene.surfaces)
      Assert.equal(#drawsOf(draws, surfaces.editionLogo), 0, "compact and wide stages draw no edition logo")
      Assert.equal(#drawsOf(draws, surfaces.subscreenDecor), 0, "compact and wide stages draw no retired text art")
      for _, rectangle in ipairs(rectangles) do
        if rectangle.mode == "fill" then
          Assert.isTrue(
            rectangle.w * rectangle.h < bounds.width * bounds.height * 0.5,
            "compact and wide stages carry no fullscreen edition card"
          )
        end
      end
      local canvasDraws = drawsOf(draws, scene.canvas)
      Assert.isTrue(#canvasDraws >= 1, "compact and wide stages render the legendary")
      local legendRect = rectOf(canvasDraws[1], canvasWidth, canvasHeight)
      Assert.isTrue(covers(legendRect, bounds), "legendary fills the compositional stage")
      local lowerDraws = drawsOf(draws, surfaces.subscreenLower)
      Assert.isTrue(#lowerDraws >= 1, "compact and wide stages keep the lower accent")
      local lowerWidth, lowerHeight = surfaces.subscreenLower:getDimensions()
      local lowerRect = rectOf(lowerDraws[1], lowerWidth, lowerHeight)
      Assert.isFalse(overlaps(legendRect, lowerRect), "lower accent never covers the legendary")
      scene:dispose()
    end
  end
end

local function tallAndDualKeepTheirSourceRoles(scope, context)
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    local scene = openTitleScene(scope, versionId, 600, 1000, "single")
    local tick = scene.tick
    local draws = captureComposedDraws(scene, scope, 600, 1000)
    local surfaces = assert(scene.surfaces)
    local bounds = assert(scene.layout.composition.bounds, "tall composition has drawable bounds")
    local lowerHalf =
      { x = bounds.x, y = bounds.y + bounds.height / 2, width = bounds.width, height = bounds.height / 2 }
    local logoDraws = drawsOf(draws, surfaces.editionLogo)
    Assert.isTrue(#logoDraws >= 1, "tall lower stage shows the edition mark")
    local logoWidth, logoHeight = surfaces.editionLogo:getDimensions()
    Assert.isTrue(
      covers(rectOf(logoDraws[1], logoWidth, logoHeight), lowerHalf),
      "tall edition mark covers its half without edge bars"
    )
    local lowerDraws = drawsOf(draws, surfaces.subscreenLower)
    Assert.isTrue(#lowerDraws >= 1, "tall lower stage keeps its lower art")
    Assert.equal(lowerDraws[1].sx, math.floor(lowerDraws[1].sx), "tall lower art scales by an integer factor")
    Assert.isTrue(lowerDraws[1].sx >= 1, "tall lower art never shrinks when its native size fits")
    local lowerWidth, lowerHeight = surfaces.subscreenLower:getDimensions()
    local lowerRect = rectOf(lowerDraws[1], lowerWidth, lowerHeight)
    Assert.isTrue(
      lowerRect.x >= lowerHalf.x
        and lowerRect.y >= lowerHalf.y - 1
        and lowerRect.x + lowerRect.width <= lowerHalf.x + lowerHalf.width + 1
        and lowerRect.y + lowerRect.height <= lowerHalf.y + lowerHalf.height + 1,
      "tall lower art stays inside its half"
    )
    Assert.near(lowerRect.y, lowerHalf.y, 2, "tall lower art aligns to the top of its half")
    local canvasDraws = drawsOf(draws, scene.canvas)
    Assert.isTrue(#canvasDraws >= 1, "tall upper stage renders the legendary")
    local canvasWidth, canvasHeight = scene.canvas:getDimensions()
    Assert.isFalse(
      overlaps(rectOf(canvasDraws[1], canvasWidth, canvasHeight), lowerRect),
      "tall upper legendary never collides with its lower art"
    )
    scene:resize(700, 1200)
    Assert.equal(scene.tick, tick, "resizing never restarts title timing")
    captureComposedDraws(scene, scope, 700, 1200)
    scene:dispose()

    local dual = openTitleScene(scope, versionId, 512, 384, "dual")
    local dualDraws = captureComposedDraws(dual, scope, 512, 384)
    local dualSurfaces = assert(dual.surfaces)
    Assert.isTrue(#drawsOf(dualDraws, dual.canvas) >= 1, "dual principal renders the legendary")
    Assert.isTrue(#drawsOf(dualDraws, dualSurfaces.editionLogo) >= 1, "dual auxiliary keeps the edition mark")
    Assert.isTrue(#drawsOf(dualDraws, dualSurfaces.subscreenLower) >= 1, "dual auxiliary keeps its lower art")
    Assert.equal(#drawsOf(dualDraws, dualSurfaces.subscreenDecor), 0, "dual auxiliary draws no retired text art")
    local button = dual:editionButtonBounds()
    local center = button.x + button.width / 2
    if versionId == "heartgold" then
      Assert.isTrue(center > 256, "edition control stays in its edition corner")
    else
      Assert.isTrue(center < 256, "edition control stays in its edition corner")
    end
    dual:dispose()
  end
end

local function retiredTextArtHasNoRuntimeImageOrDraw(scope, context)
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    local scene = openTitleScene(scope, versionId, 512, 384, "single")
    local names = {}
    for name in pairs(assert(scene.surfaces)) do
      names[#names + 1] = name
    end
    table.sort(names)
    Assert.deepEqual(names, { "editionLogo", "subscreenLower" })
    scene:dispose()
    for _, layout in ipairs({
      { kind = "single", width = 512, height = 384 },
      { kind = "single", width = 1280, height = 720 },
      { kind = "single", width = 600, height = 1000 },
      { kind = "dual", width = 512, height = 384 },
    }) do
      local staged = openTitleScene(scope, versionId, layout.width, layout.height, layout.kind)
      local draws = captureComposedDraws(staged, scope, layout.width, layout.height)
      local canvasCount, logoCount, lowerCount, decorCount = 0, 0, 0, 0
      local surfaces = staged.surfaces or {}
      for _, record in ipairs(draws) do
        if record.drawable == staged.canvas then
          canvasCount = canvasCount + 1
        elseif record.drawable == surfaces.editionLogo then
          logoCount = logoCount + 1
        elseif record.drawable == surfaces.subscreenLower then
          lowerCount = lowerCount + 1
        elseif record.drawable == surfaces.subscreenDecor then
          decorCount = decorCount + 1
        end
      end
      Assert.equal(decorCount, 0, "retired text art is never drawn")
      Assert.isTrue(canvasCount + logoCount + lowerCount > 0, "title still draws its two retained roles")
      staged:dispose()
    end
  end
end

local function titleResizeKeepsSourceTimingAndCameraPose(scope, context)
  local Matrix4 = require("libs.math.src.Matrix4")
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    local scene = openTitleScene(scope, versionId, 512, 384, "single")
    for _ = 1, 45 do
      scene:updateFixed()
    end
    local tick, view = scene.tick, scene:_camera().view()
    scene.displayContext = DisplayContext.new({ graphics = love.graphics, topologyProvider = topology("single") })
    scene:resize(1280, 720)
    Assert.equal(scene.tick, tick, "resizing never restarts title timing")
    Assert.deepEqual(scene:_camera().view(), view, "resizing never moves the sourced camera")
    Assert.equal(scene.layout.configuration, "wide", "the resized host selects the wide composition")
    scene:resize(600, 1000)
    Assert.equal(scene.tick, tick, "a second resize still preserves title timing")
    Assert.deepEqual(scene:_camera().view(), view, "a second resize still preserves the camera pose")
    drawBytes(scene, scope, 600, 1000)
    scene:dispose()
  end
end

local function titleCanvasStaysBoundedOnLargeHosts(scope, context)
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    local scene = openTitleScene(scope, versionId, 3840, 2160, "single")
    local canvasWidth, canvasHeight = scene.canvas:getDimensions()
    Assert.isTrue(canvasWidth <= 1024 and canvasHeight <= 576, "no full-window 4K title canvas")
    local bounds = assert(scene.layout.composition.bounds, "large-host composition has drawable bounds")
    local draws, _ = captureComposedDraws(scene, scope, 3840, 2160)
    local canvasDraws = drawsOf(draws, scene.canvas)
    Assert.isTrue(#canvasDraws >= 1, "large hosts still render the legendary")
    Assert.isTrue(
      covers(rectOf(canvasDraws[1], canvasWidth, canvasHeight), bounds),
      "the bounded target fills the stage"
    )
    scene:dispose()
  end
end

local function titleCanvasFailureReleasesStagedAssets(scope, context)
  local versions = readyVersionsOrSkip(context)
  local graphics = love.graphics
  local realNewCanvas = graphics.newCanvas
  for _, versionId in ipairs(versions) do
    local before = graphics.getStats()
    graphics.newCanvas = function()
      error("injected title canvas failure")
    end
    local ok, failure = pcall(openTitleScene, scope, versionId, 512, 384, "single")
    graphics.newCanvas = realNewCanvas
    Assert.isFalse(ok, "a canvas allocation failure stops title construction")
    Assert.isTrue(tostring(failure):find("canvas") ~= nil, "the failure names the canvas allocation")
    local after = graphics.getStats()
    Assert.equal(after.images, before.images, "a failed construction releases its staged images")
    Assert.equal(after.canvases, before.canvases, "a failed construction releases its staged canvases")
  end
end

local function titleMissingSurfaceFailsCleanly(scope, context)
  local CacheFs = require("libs.storage.src.CacheFs")
  local HgssTitleScene = require("libs.hgss.src.presentation.HgssTitleScene")
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    local realFs = CacheFs.forVersion(versionId)
    local hollowFs = {
      loadLua = function(_, path)
        return realFs:loadLua(path)
      end,
      exists = function(_, path, kind)
        return realFs:exists(path, kind)
      end,
      read = function(_, path)
        if path:find("subscreen", 1, true) ~= nil then
          return nil
        end
        return realFs:read(path)
      end,
    }
    local before = love.graphics.getStats()
    local ok, failure = pcall(HgssTitleScene.new, {
      versionId = versionId,
      cacheFs = hollowFs,
      width = 512,
      height = 384,
      displayContext = DisplayContext.new({ graphics = love.graphics, topologyProvider = topology("single") }),
    })
    Assert.isFalse(ok, "a missing title surface stops title construction")
    Assert.isTrue(tostring(failure):find("subscreen") ~= nil, "the failure names the missing surface")
    local after = love.graphics.getStats()
    Assert.equal(after.images, before.images, "a failed construction releases its staged images")
    Assert.equal(after.canvases, before.canvases, "a failed construction leaves no canvas behind")
  end
end

local function titleDeliversItsCompiledLightingRecord(scope, context)
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    local scene = openTitleScene(scope, versionId, 512, 384, "single")
    withRendererCapture(scene, function(seen)
      scene:_drawModel()
      Assert.equal(
        seen.environment and seen.environment.lighting,
        scene.bundle.lighting,
        "the renderer receives the compiled lighting record untouched"
      )
    end)
    scene:dispose()
  end
end

local SOURCE_HALF_ANGLE = (0xB60 / 65536) * (2 * math.pi)
local SOURCE_ASPECT = 4 / 3
local SOURCE_NEAR, SOURCE_FAR = 1, 5000
local REFERENCE_WIDTH, REFERENCE_HEIGHT = 256, 192

local function expectedSourceProjection()
  local Matrix4 = require("libs.math.src.Matrix4")
  return Matrix4.perspective(2 * SOURCE_HALF_ANGLE, SOURCE_ASPECT, SOURCE_NEAR, SOURCE_FAR)
end

local function expectedSourceView(bundle)
  local Matrix4 = require("libs.math.src.Matrix4")
  local camera = assert(bundle.timeline.camera, "title bundle carries its camera timeline")
  return Matrix4.lookAt(camera.endPosition, camera.target, { 0, 1, 0 })
end

local function silhouetteFractions(canvas, label)
  local width, height = canvas:getDimensions()
  local bytes = canvas:newImageData():getString()
  local minX, minY = width, height
  local maxX, maxY = -1, -1
  local count, sumX, sumY = 0, 0, 0
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      if string.byte(bytes, (y * width + x) * 4 + 4) > 0 then
        if x < minX then
          minX = x
        end
        if y < minY then
          minY = y
        end
        if x > maxX then
          maxX = x
        end
        if y > maxY then
          maxY = y
        end
        count, sumX, sumY = count + 1, sumX + x, sumY + y
      end
    end
  end
  Assert.isTrue(count > 0, label .. " renders legendary pixels instead of an empty target")
  return {
    width = (maxX - minX + 1) / width,
    height = (maxY - minY + 1) / height,
    centerX = (sumX / count + 0.5) / width,
    centerY = (sumY / count + 0.5) / height,
  }
end

local function sourceReferenceSilhouette(scene, scope)
  local view = expectedSourceView(scene.bundle)
  local projection = expectedSourceProjection()
  local sourceCamera = {
    far = SOURCE_FAR,
    zoom = 1,
    view = function()
      return view
    end,
    projection = function()
      return projection
    end,
    billboardProjection = function()
      return projection
    end,
  }
  local function worldItems(instance)
    local items = instance:drawItems(instance.renderMeshesById)
    for _, item in ipairs(items) do
      item.worldSpace = true
    end
    return items
  end
  local canvas = scope:own(love.graphics.newCanvas(REFERENCE_WIDTH, REFERENCE_HEIGHT, {
    format = "rgba8",
    readable = true,
    dpiscale = 1,
  }))
  local graphics = love.graphics
  graphics.push("all")
  local ok, failure = pcall(function()
    graphics.setCanvas(canvas)
    graphics.setScissor()
    graphics.clear(0, 0, 0, 0)
    scene.renderer:draw(
      assert(scene.sourceEnvironment, "title scene carries its source environment"),
      sourceCamera,
      { worldItems(scene.legend), worldItems(scene.sparkle) },
      nil,
      {
        worldViewport = { x = 0, y = 0, width = REFERENCE_WIDTH, height = REFERENCE_HEIGHT },
        referenceFrame = { x = 0, y = 0, width = REFERENCE_WIDTH, height = REFERENCE_HEIGHT },
      },
      1
    )
  end)
  graphics.setCanvas()
  graphics.pop()
  if not ok then
    error(failure, 0)
  end
  return silhouetteFractions(canvas, "the sourced reference frame")
end

local function assertSilhouetteNearProduction(actual, expected, label)
  Assert.isTrue(expected.width > 0 and expected.height > 0, label .. " reference frame carries a measurable legendary")
  Assert.near(actual.width / expected.width, 1, 0.05, label .. " legendary width stays within its sourced size")
  Assert.near(actual.height / expected.height, 1, 0.05, label .. " legendary height stays within its sourced size")
  Assert.near(
    actual.centerX,
    expected.centerX,
    4 / REFERENCE_WIDTH,
    label .. " legendary stays centered on its sourced offset"
  )
  Assert.near(
    actual.centerY,
    expected.centerY,
    4 / REFERENCE_HEIGHT,
    label .. " legendary stays level with its sourced offset"
  )
end

local function legendaryMatchesItsSourcedReferenceFrame(scope, context)
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    local scene = openTitleScene(scope, versionId, REFERENCE_WIDTH, REFERENCE_HEIGHT, "single")
    local canvasWidth, canvasHeight = scene.canvas:getDimensions()
    Assert.near(
      canvasWidth / canvasHeight,
      SOURCE_ASPECT,
      1e-6,
      "the native reference keeps a source-shaped model target instead of a host-shaped one"
    )
    Assert.deepEqual(scene:_camera().projection(), expectedSourceProjection())
    Assert.deepEqual(scene:_camera().view(), expectedSourceView(scene.bundle))
    withRendererCapture(scene, function(seen)
      scene:_drawModel()
      Assert.deepEqual(
        seen.camera.projection(),
        expectedSourceProjection(),
        "the model render path keeps the source lens"
      )
    end)
    scene:_drawModel()
    assertSilhouetteNearProduction(
      silhouetteFractions(scene.canvas, "the native title frame"),
      sourceReferenceSilhouette(scene, scope),
      "the " .. versionId .. " legendary"
    )
    scene:dispose()
  end
end

local function legendStageOf(scene)
  local composition = assert(scene.layout.composition, "title composition has drawable bounds")
  if composition.configuration == "tall" then
    return assert(composition.upper, "tall title stages its legendary in the upper half")
  end
  if composition.configuration == "dualDisplay" then
    local principal = assert(composition.principal, "dual title keeps a principal stage")
    return assert(principal.bounds, "principal stage has drawable bounds")
  end
  return assert(composition.bounds, "title composition has drawable bounds")
end

local function assertSourceLensUnchanged(scene, view, projection, reference, tick, label)
  Assert.equal(scene.tick, tick, label .. " resizing never advances title timing")
  Assert.deepEqual(scene:_camera().view(), view)
  Assert.deepEqual(scene:_camera().projection(), projection)
  local lens = scene:_camera().projection()
  Assert.near(lens[6] / lens[1], SOURCE_ASPECT, 1e-9, label .. " host ratio never widens the 3D lens")
  local canvasWidth, canvasHeight = scene.canvas:getDimensions()
  Assert.near(canvasWidth / canvasHeight, SOURCE_ASPECT, 1e-6, label .. " host ratio never reshapes the model target")
  scene:_drawModel()
  assertSilhouetteNearProduction(silhouetteFractions(scene.canvas, label .. " host frame"), reference, label .. " host")
end

local function assertCenteredLegendPlacement(scene, scope, width, height, label)
  local stage = legendStageOf(scene)
  local draws = captureComposedDraws(scene, scope, width, height)
  local canvasDraws = drawsOf(draws, scene.canvas)
  Assert.equal(#canvasDraws, 1, label .. " host draws the legendary exactly once")
  local canvasWidth, canvasHeight = scene.canvas:getDimensions()
  local rect = rectOf(canvasDraws[1], canvasWidth, canvasHeight)
  Assert.near(
    rect.width / rect.height,
    canvasWidth / canvasHeight,
    0.01,
    label .. " host never stretches the legendary"
  )
  Assert.near(rect.x + rect.width / 2, stage.x + stage.width / 2, 1, label .. " host keeps the legendary centered")
  Assert.isTrue(covers(rect, stage), label .. " host keeps the legendary filling its stage")
  local scale = math.max(canvasDraws[1].sx, canvasDraws[1].sy)
  Assert.near(canvasDraws[1].sx, canvasDraws[1].sy, 0.01 * scale, label .. " host scales the legendary uniformly")
  local button = scene:editionButtonBounds()
  Assert.isTrue(button.x >= 0 and button.y >= 0, label .. " host keeps the edition control on screen")
  Assert.isTrue(
    button.x + button.width <= width and button.y + button.height <= height,
    label .. " host keeps the edition control reachable"
  )
end

local function hostResizingKeepsTheSourcedTitleLens(scope, context)
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    local scene = openTitleScene(scope, versionId, 512, 384, "single")
    local tick = scene.tick
    local view = scene:_camera().view()
    local projection = scene:_camera().projection()
    Assert.near(projection[6] / projection[1], SOURCE_ASPECT, 1e-9, "the 4:3 host starts on the source lens")
    scene:_drawModel()
    local reference = silhouetteFractions(scene.canvas, "the 4:3 host frame")
    assertSourceLensUnchanged(scene, view, projection, reference, tick, "the 4:3 host")
    assertCenteredLegendPlacement(scene, scope, 512, 384, "the 4:3 host")
    scene:resize(1280, 720)
    Assert.equal(scene.layout.configuration, "wide", "the resized host selects the wide composition")
    assertSourceLensUnchanged(scene, view, projection, reference, tick, "the wide host")
    assertCenteredLegendPlacement(scene, scope, 1280, 720, "the wide host")
    scene.displayContext = DisplayContext.new({ graphics = love.graphics, topologyProvider = topology("single") })
    scene:resize(600, 1000)
    Assert.equal(scene.layout.configuration, "tall", "the resized host selects the tall composition")
    assertSourceLensUnchanged(scene, view, projection, reference, tick, "the tall host")
    assertCenteredLegendPlacement(scene, scope, 600, 1000, "the tall host")
    scene.displayContext = DisplayContext.new({ graphics = love.graphics, topologyProvider = topology("dual") })
    scene:resize(512, 384)
    Assert.equal(scene.layout.configuration, "dualDisplay", "the resized host selects the dual composition")
    assertSourceLensUnchanged(scene, view, projection, reference, tick, "the dual host")
    assertCenteredLegendPlacement(scene, scope, 512, 384, "the dual host")
    scene:dispose()
  end
end

local T = GraphicsSmoke.suite({
  ["generated HGSS titles render, animate and fit each supported display"] = renderAvailableEditions,
  ["title scene delivers the sourced camera framing and lit legendary"] = titleDeliversSourceCameraAndLighting,
  ["title overlay phases follow their sourced schedule"] = titleOverlayPhasesFollowTheirSourcedSchedule,
  ["compact and wide stages fill with the legendary"] = compactAndWideFillWithTheLegend,
  ["tall and dual stages keep their source roles"] = tallAndDualKeepTheirSourceRoles,
  ["retired title text art has no runtime image or draw"] = retiredTextArtHasNoRuntimeImageOrDraw,
  ["title resize keeps source timing and camera pose"] = titleResizeKeepsSourceTimingAndCameraPose,
  ["title canvas stays bounded on large hosts"] = titleCanvasStaysBoundedOnLargeHosts,
  ["title canvas failure releases staged assets"] = titleCanvasFailureReleasesStagedAssets,
  ["title missing surface fails cleanly"] = titleMissingSurfaceFailsCleanly,
  ["title delivers its compiled lighting record"] = titleDeliversItsCompiledLightingRecord,
  ["legendary silhouette matches its sourced reference frame at native size"] = legendaryMatchesItsSourcedReferenceFrame,
  ["host resizing keeps the sourced title lens centered"] = hostResizingKeepsTheSourcedTitleLens,
})
T.metadata.capabilities = { "graphics", "rom_dump" }
T.metadata.derivedAssets = { "startup-title:global" }
T.metadata.tags = { "startup", "title", "lifecycle" }
return T
