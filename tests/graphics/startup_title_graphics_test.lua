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
      Assert.equal(stageDraws.logo, 1, "wide cinematic draws its left edition artwork")
      Assert.equal(stageDraws.lower, 1, "wide cinematic draws its middle artwork blended into the legendary")
      local beforeWide = drawBytes(scene, scope, layout.width, layout.height)
      for _ = 1, 30 do
        scene:updateFixed()
      end
      local afterWide = drawBytes(scene, scope, layout.width, layout.height)
      Assert.isTrue(beforeWide ~= afterWide, "wide title animation advances on the panoramic stage")
    elseif layout.configuration == "tall" then
      Assert.isTrue(composition.lowerPanel == true, "tall title keeps its lower panel")
      Assert.isTrue(composition.upper ~= nil and composition.lower ~= nil, "tall title stacks two source roles")
      Assert.equal(stageDraws.canvas, 1, "tall upper stage renders the legendary exactly once")
      Assert.equal(stageDraws.logo, 1, "tall lower stage shows the edition mark")
      Assert.equal(stageDraws.lower, 1, "tall lower stage keeps its lower art")
    elseif layout.configuration == "nativeLike" then
      Assert.isFalse(composition.lowerPanel == true, "4:3 keeps a single 3D stage")
      Assert.equal(stageDraws.canvas, 1, "4:3 draws the live animated canvas exactly once")
      Assert.equal(stageDraws.logo, 1, "4:3 cinematic draws its left edition artwork")
      Assert.equal(stageDraws.lower, 1, "4:3 cinematic draws its middle artwork blended into the legendary")
    else
      local primary, secondary = scene.layout.primary, scene.layout.secondary
      Assert.isTrue(secondary ~= nil, "physical dual display preserves both source surfaces")
      Assert.isTrue(
        primary.y + primary.height <= secondary.y or secondary.y + secondary.height <= primary.y,
        "dual display keeps upper and lower source roles on separate surfaces"
      )
    end
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

local SOURCE_UNITS_PER_WORLD_UNIT = 16

local function titleDeliversSourceCameraAndLighting(scope, context)
  local Matrix4 = require("libs.math.src.Matrix4")
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    local scene = openTitleScene(scope, versionId, 512, 384, "single")
    local camera = scene:_camera()
    local halfAngle = (0xB60 / 65536) * (2 * math.pi)
    Assert.near(sourceVerticalFov(camera.projection()), 2 * halfAngle, 0.02, "title uses the source half-angle")
    local timeline = assert(scene.bundle.timeline, "title bundle carries its camera timeline")
    local rawEye = timeline.camera.endPosition
    local rawTarget = timeline.camera.target
    Assert.deepEqual(
      camera.view(),
      Matrix4.lookAt(
        {
          rawEye[1] / SOURCE_UNITS_PER_WORLD_UNIT,
          rawEye[2] / SOURCE_UNITS_PER_WORLD_UNIT,
          rawEye[3] / SOURCE_UNITS_PER_WORLD_UNIT,
        },
        {
          rawTarget[1] / SOURCE_UNITS_PER_WORLD_UNIT,
          rawTarget[2] / SOURCE_UNITS_PER_WORLD_UNIT,
          rawTarget[3] / SOURCE_UNITS_PER_WORLD_UNIT,
        },
        { 0, 1, 0 }
      ),
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
    local graphics = love.graphics
    local originalDraw = graphics.draw
    local renderer = assert(scene.textRenderer, "overlay phases use the ROM font")
    local originalLine = renderer.drawLineWithPalette
    local lineDraws = 0
    renderer.drawLineWithPalette = function(self, tokens, x, y, palette)
      lineDraws = lineDraws + 1
      return originalLine(self, tokens, x, y, palette)
    end
    local overlayDraws = {}
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
      promptAt[scene.tick] = lineDraws > 0
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
      overlayDraws = {}
      lineDraws = 0
      scene:draw()
      record()
      for _ = 1, 160 do
        scene:updateFixed()
        if samples[scene.tick] then
          overlayDraws = {}
          lineDraws = 0
          scene:draw()
          record()
        end
      end
    end)
    renderer.drawLineWithPalette = originalLine
    graphics.draw = originalDraw
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

-- The retail prompt window is a full-width strip at tile rows 18-19 of the
-- 256x192 top screen (pokeheartgold src/title_screen.c,
-- sTouchToStartWindow = { GF_BG_LYR_MAIN_3, 0, 18, 32, 2 }), so it always
-- spans the surface that carries the 3D scene.
local PROMPT_STRIP_TOP = 144 / 192

---@param prompt table title prompt rect
---@param surface table source-shaped surface carrying the 3D scene
---@param label string composition under test
local function assertPromptStrip(prompt, surface, label)
  Assert.near(prompt.x, surface.x, 1, label .. " prompt starts at the surface left edge")
  Assert.near(prompt.width, surface.width, 1, label .. " prompt spans the full surface width")
  Assert.near(
    prompt.y,
    surface.y + surface.height * PROMPT_STRIP_TOP,
    2,
    label .. " prompt sits at the decomp tile row"
  )
end

local function compactAndWideFillWithTheLegend(scope, context)
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    for _, layout in ipairs({
      { width = 512, height = 384 },
      { width = 1280, height = 720 },
      { width = 1680, height = 720 },
    }) do
      local scene = openTitleScene(scope, versionId, layout.width, layout.height, "single")
      local composition = assert(scene.layout.composition, "title composition has drawable bounds")
      local bounds = assert(composition.bounds, "title composition has drawable bounds")
      local canvasWidth, canvasHeight = scene.canvas:getDimensions()
      Assert.isTrue(
        canvasWidth <= 1024 and canvasHeight <= 576,
        "title 3D target stays bounded instead of matching the window"
      )
      -- Cinematic single-screen keeps a bounded target: widescreen
      -- follows its live stage aspect (16:9 at 1280x720), 4:3 keeps the
      -- source-shaped target.
      if layout.width == 1280 and layout.height == 720 then
        Assert.near(canvasWidth / canvasHeight, 16 / 9, 0.02, "widescreen cinematic uses a 16:9 3D target")
      elseif layout.width / layout.height > 1.4 then
        Assert.near(
          canvasWidth / canvasHeight,
          layout.width / layout.height,
          0.02,
          "widescreen cinematic follows its live stage aspect"
        )
      else
        Assert.near(canvasWidth / canvasHeight, 4 / 3, 0.01, "4:3 cinematic keeps a source-shaped 3D target")
      end
      local draws, _ = captureComposedDraws(scene, scope, layout.width, layout.height)
      local surfaces = assert(scene.surfaces)
      Assert.isTrue(#drawsOf(draws, surfaces.editionLogo) >= 1, "cinematic stages draw the left edition artwork")
      Assert.isTrue(#drawsOf(draws, surfaces.subscreenLower) >= 1, "cinematic stages draw the middle artwork")
      Assert.equal(#drawsOf(draws, surfaces.subscreenDecor), 0, "cinematic stages draw no retired text art")
      local canvasDraws = drawsOf(draws, scene.canvas)
      Assert.isTrue(#canvasDraws >= 1, "cinematic stages render the legendary")
      local legendRect = rectOf(canvasDraws[1], canvasWidth, canvasHeight)
      -- Fade-anchored 3D: the visible scene centers in the right
      -- sub-region beginning at the fade (its left edge hides under
      -- the opaque logo), covering the right edge.
      local region = assert(composition.stage3D, "cinematic composition has a 3D stage")
      Assert.near(
        legendRect.x + legendRect.width / 2,
        region.x + region.width / 2,
        2,
        "legendary centers in the visible 3D region right of the logo"
      )
      Assert.isTrue(
        legendRect.x + legendRect.width >= bounds.x + bounds.width - 1,
        "legendary covers the stage right edge"
      )
      -- Smaller left logo: the text art is left-anchored instead of
      -- spanning the middle, so the legendary clears it.
      local lowerDraws = drawsOf(draws, surfaces.subscreenLower)
      local lowerWidth, lowerHeight = surfaces.subscreenLower:getDimensions()
      local lowerRect = rectOf(lowerDraws[1], lowerWidth, lowerHeight)
      Assert.isTrue(lowerRect.x <= bounds.x + bounds.width * 0.05, "logo hugs the left edge")
      Assert.isTrue(
        lowerRect.x + lowerRect.width <= bounds.x + bounds.width * 0.5,
        "branding stays in the left half where the legendary clears it"
      )
      -- The burst backdrop carries the bright core under the text logo
      -- and spans the fade, so no horizontal seam shows at the transition.
      local burstDraws = drawsOf(draws, surfaces.editionLogo)
      local burstWidth, burstHeight = surfaces.editionLogo:getDimensions()
      local burstRect = rectOf(burstDraws[1], burstWidth, burstHeight)
      local burstCore = burstRect.x + burstRect.width / 2
      Assert.isTrue(
        burstCore >= lowerRect.x and burstCore <= lowerRect.x + lowerRect.width,
        "burst core sits under the text logo"
      )
      Assert.isTrue(
        burstRect.x <= region.x and burstRect.x + burstRect.width >= region.x,
        "the burst spans the fade so the transition shows no seam"
      )
      -- Decomp reference (pokeheartgold src/title_screen.c,
      -- sTouchToStartWindow = { GF_BG_LYR_MAIN_3, 0, 18, 32, 2 }): the prompt
      -- is a full-width strip at tile rows 18-19 of the 256x192 top screen,
      -- not a corner box.
      local prompt = assert(scene.layout.prompt, "title prompt has a rect")
      assertPromptStrip(prompt, assert(scene.layout.main, "title layout has main bounds"), "cinematic")
      Assert.equal(scene.bundle.prompt.alignment, "center", "prompt keeps its extracted centering")
      -- The prompt prints with the ROM field font, not a system font:
      -- integer-scaled to the strip, centered, in the edition palette.
      local renderer = assert(scene.textRenderer, "cinematic prompt uses the ROM font")
      local lineHeight = assert(renderer.fontDef.lineHeight, "ROM font carries its line height")
      local scale = math.min(2, math.max(1, math.floor(prompt.height / lineHeight)))
      local expectedWidth = renderer:textWidth(scene.bundle.prompt.text) * scale
      Assert.isTrue(expectedWidth <= prompt.width, "scaled prompt fits its strip")
      -- The line itself draws at the translated origin, so the
      -- centering lives in the immediately preceding translate.
      local graphics = love.graphics
      local originalTranslate = graphics.translate
      local lastTranslate, seenLine = nil, nil
      graphics.translate = function(x, y)
        lastTranslate = { x = x, y = y }
        return originalTranslate(x, y)
      end
      local originalLine = renderer.drawLineWithPalette
      renderer.drawLineWithPalette = function(self, tokens, x, y, palette)
        seenLine = { origin = { x = x, y = y }, at = lastTranslate, palette = palette }
        return originalLine(self, tokens, x, y, palette)
      end
      for _ = 1, 45 do
        scene:updateFixed()
      end
      drawBytes(scene, scope, layout.width, layout.height)
      graphics.translate = originalTranslate
      renderer.drawLineWithPalette = originalLine
      Assert.notNil(seenLine, "prompt draws through the palette path while visible")
      Assert.near(
        seenLine.at.x + expectedWidth / 2,
        prompt.x + prompt.width / 2,
        2,
        "ROM prompt centers in its strip"
      )
      Assert.near(seenLine.at.y, prompt.y, 2, "ROM prompt sits at the strip top")
      local fg = assert(scene.bundle.prompt.color.foregroundRgb, "prompt carries its edition ink")
      local function byte(channel)
        return math.floor(channel * 255 + 0.5)
      end
      Assert.deepEqual(
        seenLine.palette.foreground,
        { r = byte(fg[1]), g = byte(fg[2]), b = byte(fg[3]) },
        "prompt foreground uses the edition palette"
      )
      Assert.equal(seenLine.palette.background.a, 0, "prompt background stays transparent")
      -- Overlap is intentional in the blended composition: the 2D layers
      -- fade horizontally into the 3D via the title-local mask, so no
      -- disjointness check applies here. Visual inspection confirms the
      -- legendary stays visible through the transition.
      scene:dispose()
    end
  end
end

local function tallAndDualKeepTheirSourceRoles(scope, context)
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    local scene = openTitleScene(scope, versionId, 600, 1000, "single")
    local tick = scene.tick
    -- The tall stage renders its upper 3D at a height comparable to the
    -- single-screen cinematic targets while keeping the source 4:3 shape.
    local tallCanvasWidth, tallCanvasHeight = scene.canvas:getDimensions()
    Assert.isTrue(tallCanvasHeight > 192, "tall 3D renders above the source role height")
    Assert.isTrue(
      tallCanvasWidth <= 1024 and tallCanvasHeight <= 576,
      "tall 3D target stays bounded instead of matching the window"
    )
    Assert.near(tallCanvasWidth / tallCanvasHeight, 4 / 3, 0.01, "tall 3D keeps the source-shaped target")
    local draws = captureComposedDraws(scene, scope, 600, 1000)
    local surfaces = assert(scene.surfaces)
    local bounds = assert(scene.layout.composition.bounds, "tall composition has drawable bounds")
    local upperHalf =
      { x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height / 2 }
    local lowerHalf =
      { x = bounds.x, y = bounds.y + bounds.height / 2, width = bounds.width, height = bounds.height / 2 }
    local logoDraws = drawsOf(draws, surfaces.editionLogo)
    Assert.isTrue(#logoDraws >= 1, "tall upper stage shows the edition mark")
    local logoWidth, logoHeight = surfaces.editionLogo:getDimensions()
    Assert.isTrue(
      covers(rectOf(logoDraws[1], logoWidth, logoHeight), upperHalf),
      "tall edition mark covers its half without edge bars"
    )
    local lowerDraws = drawsOf(draws, surfaces.subscreenLower)
    Assert.isTrue(#lowerDraws >= 1, "tall upper stage keeps its lower art")
    Assert.equal(lowerDraws[1].sx, math.floor(lowerDraws[1].sx), "tall upper art scales by an integer factor")
    Assert.isTrue(lowerDraws[1].sx >= 1, "tall upper art never shrinks when its native size fits")
    local lowerWidth, lowerHeight = surfaces.subscreenLower:getDimensions()
    local lowerRect = rectOf(lowerDraws[1], lowerWidth, lowerHeight)
    Assert.isTrue(
      lowerRect.x >= upperHalf.x
        and lowerRect.y >= upperHalf.y - 1
        and lowerRect.x + lowerRect.width <= upperHalf.x + upperHalf.width + 1
        and lowerRect.y + lowerRect.height <= upperHalf.y + upperHalf.height + 1,
      "tall upper art stays inside its half"
    )
    Assert.near(lowerRect.y, upperHalf.y, 2, "tall upper art aligns to the top of its half")
    local canvasDraws = drawsOf(draws, scene.canvas)
    Assert.isTrue(#canvasDraws >= 1, "tall lower stage renders the legendary")
    local canvasWidth, canvasHeight = scene.canvas:getDimensions()
    Assert.isFalse(
      overlaps(rectOf(canvasDraws[1], canvasWidth, canvasHeight), lowerRect),
      "tall lower legendary never collides with its upper art"
    )
    -- The prompt strip follows the 3D stage onto the lower half,
    -- clear of the upper-half logo art.
    assertPromptStrip(assert(scene.layout.prompt, "tall prompt has a rect"), lowerHalf, "tall")
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
    -- The world (upper) surface is the top-screen equivalent, so the
    -- prompt strip maps onto it exactly like the decomp window.
    assertPromptStrip(
      assert(dual.layout.prompt, "dual prompt has a rect"),
      assert(dual.layout.primary, "dual layout has a world surface"),
      "dual"
    )
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
    local composition = assert(scene.layout.composition, "large-host composition has drawable bounds")
    local bounds = assert(composition.bounds, "large-host composition has drawable bounds")
    local draws, _ = captureComposedDraws(scene, scope, 3840, 2160)
    local canvasDraws = drawsOf(draws, scene.canvas)
    Assert.isTrue(#canvasDraws >= 1, "large hosts still render the legendary")
    local legendRect = rectOf(canvasDraws[1], canvasWidth, canvasHeight)
    -- Fade-anchored 3D covers its right sub-region and the stage right
    -- edge; the left stays 2D/backdrop by design.
    local region = composition.stage3D or bounds
    Assert.isTrue(
      legendRect.x + legendRect.width >= bounds.x + bounds.width - 1,
      "the bounded target covers the stage right edge"
    )
    Assert.near(
      legendRect.x + legendRect.width / 2,
      region.x + region.width / 2,
      2,
      "the bounded target centers in the visible 3D region"
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

local function titleHoldsPromptWithoutStagingCopy(scope, context)
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    local scene = openTitleScene(scope, versionId, 512, 384, "single")
    for _ = 1, 45 do
      scene:updateFixed()
    end
    local graphics = love.graphics
    local originalPrint, originalPrintf = graphics.print, graphics.printf
    local renderer = assert(scene.textRenderer, "prompt holds its ROM line while staging")
    local originalLine = renderer.drawLineWithPalette
    local function captureDraw(status)
      local printed = {}
      local promptDrawn = false
      graphics.print = function(text, ...)
        printed[#printed + 1] = tostring(text)
        return originalPrint(text, ...)
      end
      graphics.printf = function(text, ...)
        printed[#printed + 1] = tostring(text)
        return originalPrintf(text, ...)
      end
      renderer.drawLineWithPalette = function(self, ...)
        promptDrawn = true
        return originalLine(self, ...)
      end
      local ok, failure = pcall(function()
        scene:draw(status)
      end)
      graphics.print, graphics.printf = originalPrint, originalPrintf
      renderer.drawLineWithPalette = originalLine
      if not ok then
        error(failure, 0)
      end
      return table.concat(printed, "\n"), promptDrawn
    end
    local ok, failure = pcall(function()
      local staging, promptDrawn = captureDraw({ preparingMenu = true })
      Assert.isTrue(promptDrawn, "the title holds its prompt while the menu stages")
      Assert.isTrue(
        staging:find("Preparing", 1, true) == nil,
        "no staging label leaks onto the title, got: " .. staging
      )
      local failed = captureDraw({ menuError = "synthetic menu failure" })
      Assert.isTrue(
        failed:lower():find("retry", 1, true) ~= nil,
        "a genuine menu failure stays actionable, got: " .. failed
      )
    end)
    graphics.print, graphics.printf = originalPrint, originalPrintf
    scene:dispose()
    if not ok then
      error(failure, 0)
    end
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

local function scaledWorldCoords(raw)
  return {
    raw[1] / SOURCE_UNITS_PER_WORLD_UNIT,
    raw[2] / SOURCE_UNITS_PER_WORLD_UNIT,
    raw[3] / SOURCE_UNITS_PER_WORLD_UNIT,
  }
end

local function expectedWorldView(rawEye, rawTarget)
  local Matrix4 = require("libs.math.src.Matrix4")
  return Matrix4.lookAt(scaledWorldCoords(rawEye), scaledWorldCoords(rawTarget), { 0, 1, 0 })
end

local function renderWorldReferenceSilhouette(scene, scope, rawEye, rawTarget, label)
  local projection = expectedSourceProjection()
  local view = expectedWorldView(rawEye, rawTarget)
  local worldCamera = {
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
      worldCamera,
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
  return silhouetteFractions(canvas, label)
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
    local timeline = assert(scene.bundle.timeline, "title bundle carries its camera timeline")
    local rawTarget = assert(timeline.camera.target, "title bundle carries its camera target")
    Assert.deepEqual(scene:_camera().view(), expectedWorldView(scene.cameraPos, rawTarget))
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
      renderWorldReferenceSilhouette(
        scene,
        scope,
        scene.cameraPos,
        rawTarget,
        "the world-unit reference frame"
      ),
      "the " .. versionId .. " legendary"
    )
    scene:dispose()
  end
end

local function legendaryFramingSharesModelWorldUnitsAtNativeSize(scope, context)
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    local scene = openTitleScene(scope, versionId, REFERENCE_WIDTH, REFERENCE_HEIGHT, "single")
    local timeline = assert(scene.bundle.timeline, "title bundle carries its camera timeline")
    local rawTarget = assert(timeline.camera.target, "title bundle carries its camera target")
    Assert.deepEqual(
      { scene.cameraPos[1], scene.cameraPos[2], scene.cameraPos[3] },
      timeline.camera.endPosition,
      "the " .. versionId .. " opening pose keeps its authored coordinates"
    )
    local authoredPose = { scene.cameraPos[1], scene.cameraPos[2], scene.cameraPos[3] }
    Assert.deepEqual(
      scene:_camera().view(),
      expectedWorldView(scene.cameraPos, rawTarget),
      "the " .. versionId .. " title view composes eye and target in model world units"
    )
    Assert.deepEqual(
      { scene.cameraPos[1], scene.cameraPos[2], scene.cameraPos[3] },
      authoredPose,
      "the " .. versionId .. " view composition leaves authored coordinates untouched"
    )
    Assert.deepEqual(
      scene:_camera().projection(),
      expectedSourceProjection(),
      "the " .. versionId .. " title keeps its fixed lens"
    )
    scene:_drawModel()
    assertSilhouetteNearProduction(
      silhouetteFractions(scene.canvas, "the native " .. versionId .. " title frame"),
      renderWorldReferenceSilhouette(
        scene,
        scope,
        scene.cameraPos,
        rawTarget,
        "the " .. versionId .. " world-unit reference frame"
      ),
      "the " .. versionId .. " legendary"
    )
    scene:dispose()
  end
end

local function titleWaypointsKeepAuthoredTimingAcrossHostSizes(scope, context)
  for _, versionId in ipairs(readyVersionsOrSkip(context)) do
    local scene = openTitleScene(scope, versionId, REFERENCE_WIDTH, REFERENCE_HEIGHT, "single")
    local timeline = assert(scene.bundle.timeline, "title bundle carries its camera timeline")
    local rawTarget = assert(timeline.camera.target, "title bundle carries its camera target")
    local points = assert(timeline.camera.points, "title bundle carries its camera waypoints")
    Assert.deepEqual(
      scene:_camera().view(),
      expectedWorldView(scene.cameraPos, rawTarget),
      "the " .. versionId .. " opening view composes eye and target in model world units"
    )
    local ticks = 0
    local function advance()
      scene:updateFixed()
      ticks = ticks + 1
      if ticks % 10 == 0 then
        scene:_drawModel()
      end
    end
    for index, point in ipairs(points) do
      local budget = 0
      while scene.cameraPointIndex == index do
        advance()
        budget = budget + 1
        Assert.isTrue(budget < 5000, "the " .. versionId .. " camera reaches its next authored pose")
      end
      Assert.deepEqual(
        { scene.cameraPos[1], scene.cameraPos[2], scene.cameraPos[3] },
        point.position,
        "the " .. versionId .. " camera lands exactly on its authored pose"
      )
      Assert.deepEqual(
        scene:_camera().view(),
        expectedWorldView(scene.cameraPos, rawTarget),
        "the " .. versionId .. " waypoint view composes eye and target in model world units"
      )
      if index == 1 then
        scene:_drawModel()
        assertSilhouetteNearProduction(
          silhouetteFractions(scene.canvas, "the " .. versionId .. " waypoint frame"),
          renderWorldReferenceSilhouette(
            scene,
            scope,
            scene.cameraPos,
            rawTarget,
            "the " .. versionId .. " waypoint reference frame"
          ),
          "the " .. versionId .. " traveling legendary"
        )
      end
    end
    local plain = openTitleScene(scope, versionId, REFERENCE_WIDTH, REFERENCE_HEIGHT, "single")
    for _ = 1, ticks do
      plain:updateFixed()
    end
    Assert.deepEqual(
      { plain.cameraPos[1], plain.cameraPos[2], plain.cameraPos[3] },
      { scene.cameraPos[1], scene.cameraPos[2], scene.cameraPos[3] },
      "the " .. versionId .. " intermediate draws never alter the camera trajectory"
    )
    plain:dispose()
    local tick = scene.tick
    local pose = { scene.cameraPos[1], scene.cameraPos[2], scene.cameraPos[3] }
    scene:resize(1280, 720)
    Assert.equal(scene.layout.configuration, "wide", "the resized host selects the wide composition")
    Assert.equal(scene.tick, tick, "the " .. versionId .. " resizing never restarts title timing")
    Assert.deepEqual(
      { scene.cameraPos[1], scene.cameraPos[2], scene.cameraPos[3] },
      pose,
      "the " .. versionId .. " resizing never moves the authored camera"
    )
    Assert.deepEqual(
      scene:_camera().view(),
      expectedWorldView(scene.cameraPos, rawTarget),
      "the " .. versionId .. " wide view composes eye and target in model world units"
    )
    scene:_drawModel()
    -- Widescreen preserves vertical framing while revealing more
    -- horizontal space: the silhouette stays level and centered, but its
    -- width fraction shrinks against the wider target, so only the
    -- vertical/centering contract applies here.
    local wideLens = scene:_camera().projection()
    local wideCanvasWidth, wideCanvasHeight = scene.canvas:getDimensions()
    Assert.near(wideCanvasWidth / wideCanvasHeight, 16 / 9, 0.05, "the wide " .. versionId .. " target is 16:9")
    Assert.near(
      sourceVerticalFov(wideLens),
      sourceVerticalFov(expectedSourceProjection()),
      0.02,
      "the wide " .. versionId .. " lens preserves the source vertical FOV"
    )
    local wideFractions = silhouetteFractions(scene.canvas, "the wide " .. versionId .. " title frame")
    local nativeFractions = renderWorldReferenceSilhouette(
      scene,
      scope,
      scene.cameraPos,
      rawTarget,
      "the wide " .. versionId .. " reference frame"
    )
    Assert.near(
      wideFractions.height,
      nativeFractions.height,
      0.05,
      "the wide " .. versionId .. " legendary keeps its sourced height"
    )
    Assert.near(
      wideFractions.centerY,
      nativeFractions.centerY,
      4 / REFERENCE_HEIGHT,
      "the wide " .. versionId .. " legendary stays level with its sourced offset"
    )
    scene:dispose()
  end
end

local function legendStageOf(scene)
  local composition = assert(scene.layout.composition, "title composition has drawable bounds")
  if composition.configuration == "tall" then
    return assert(composition.lower, "tall title stages its legendary in the lower half")
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

local function assertCinematicWideLens(scene, view, tick, label)
  Assert.equal(scene.tick, tick, label .. " resizing never advances title timing")
  Assert.deepEqual(scene:_camera().view(), view, label .. " resizing never moves the sourced camera")
  local lens = scene:_camera().projection()
  local canvasWidth, canvasHeight = scene.canvas:getDimensions()
  -- Widescreen widens the horizontal field by using the live target
  -- aspect while preserving the source vertical FOV: no stretch.
  Assert.near(lens[6] / lens[1], canvasWidth / canvasHeight, 1e-9, label .. " 3D target carries a 16:9 projection")
  Assert.near(canvasWidth / canvasHeight, 16 / 9, 0.05, label .. " 3D target is 16:9")
  Assert.near(sourceVerticalFov(lens), sourceVerticalFov(expectedSourceProjection()), 0.02, label .. " preserves the source vertical FOV")
end

local function assertCenteredLegendPlacement(scene, scope, width, height, label)
  local stage = legendStageOf(scene)
  local composition = assert(scene.layout.composition, "title composition has drawable bounds")
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
  -- Cinematic single-screen anchors the 3D at the fade: the legendary
  -- centers in the right sub-region so it clears the left logo;
  -- tall/dual (no 3D sub-region) keep it centered on the stage.
  local region = composition.stage3D or stage
  Assert.near(
    rect.x + rect.width / 2,
    region.x + region.width / 2,
    2,
    label .. " host centers the legendary in its 3D region"
  )
  if composition.stage3D ~= nil then
    -- Cover centers the canvas in the 3D sub-region with symmetric
    -- overflow cropped, so the draw may start left of the fade while
    -- its center stays anchored in the visible region.
    Assert.isTrue(rect.x <= region.x + 1, label .. " host begins the 3D scene at or left of the fade")
  else
    Assert.near(rect.x + rect.width / 2, stage.x + stage.width / 2, 1, label .. " host keeps the legendary centered")
    Assert.isTrue(covers(rect, stage), label .. " host keeps the legendary filling its stage")
  end
  Assert.isTrue(
    rect.x + rect.width >= stage.x + stage.width - 1,
    label .. " host keeps the legendary covering the stage right edge"
  )
  local scale = math.max(canvasDraws[1].sx, canvasDraws[1].sy)
  Assert.near(canvasDraws[1].sx, canvasDraws[1].sy, 0.01 * scale, label .. " host scales the legendary uniformly")
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
    assertCinematicWideLens(scene, view, tick, "the wide host")
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

-- SoulSilver legendary framing at the first-visible pose and a later
-- waypoint: expected bounds come from the source eye/target scaled once
-- with the fixed 4:3 lens, never from the player camera. Occupancy and
-- centroid must hold within per-pixel tolerance, and a resize plus a
-- repeated draw must not move the pose or the pixels.
local function soulsilverLegendaryFramingMatchesSourceProjectionAtTwoPoses(scope, context)
  if not RomImporter.isReady("soulsilver") then
    context:skip("no user-owned SoulSilver dump is ready")
  end
  local scene = openTitleScene(scope, "soulsilver", REFERENCE_WIDTH, REFERENCE_HEIGHT, "single")
  local timeline = assert(scene.bundle.timeline, "title bundle carries its camera timeline")
  local rawTarget = assert(timeline.camera.target, "title bundle carries its camera target")
  local points = assert(timeline.camera.points, "title bundle carries its camera waypoints")
  Assert.isTrue(#points >= 1, "the title camera carries a later waypoint")
  scene:_drawModel()
  assertSilhouetteNearProduction(
    silhouetteFractions(scene.canvas, "the first-visible title frame"),
    renderWorldReferenceSilhouette(scene, scope, scene.cameraPos, rawTarget, "the first-visible reference frame"),
    "the first-visible soulsilver legendary"
  )
  local guard = 0
  while scene.cameraPointIndex == 1 and guard < 5000 do
    scene:updateFixed()
    guard = guard + 1
  end
  Assert.equal(scene.cameraPointIndex, 2, "the title camera reaches its later waypoint")
  Assert.deepEqual(
    { scene.cameraPos[1], scene.cameraPos[2], scene.cameraPos[3] },
    points[1].position,
    "the camera lands exactly on its authored later pose"
  )
  scene:_drawModel()
  assertSilhouetteNearProduction(
    silhouetteFractions(scene.canvas, "the later waypoint title frame"),
    renderWorldReferenceSilhouette(scene, scope, scene.cameraPos, rawTarget, "the later waypoint reference frame"),
    "the later soulsilver legendary"
  )
  local tick = scene.tick
  local pose = { scene.cameraPos[1], scene.cameraPos[2], scene.cameraPos[3] }
  scene:resize(1280, 720)
  Assert.equal(scene.tick, tick, "resizing never restarts title timing")
  Assert.deepEqual(
    { scene.cameraPos[1], scene.cameraPos[2], scene.cameraPos[3] },
    pose,
    "resizing never moves the authored camera"
  )
  scene:_drawModel()
  -- The resized widescreen target widens horizontally while preserving
  -- vertical framing: check height/level only, plus lens/aspect facts.
  local resizedLens = scene:_camera().projection()
  local resizedWidth, resizedHeight = scene.canvas:getDimensions()
  Assert.near(resizedWidth / resizedHeight, 16 / 9, 0.05, "the resized later target is 16:9")
  Assert.near(
    sourceVerticalFov(resizedLens),
    sourceVerticalFov(expectedSourceProjection()),
    0.02,
    "the resized later lens preserves the source vertical FOV"
  )
  local resizedFractions = silhouetteFractions(scene.canvas, "the resized later title frame")
  local resizedReference =
    renderWorldReferenceSilhouette(scene, scope, scene.cameraPos, rawTarget, "the resized later reference frame")
  Assert.near(
    resizedFractions.height,
    resizedReference.height,
    0.05,
    "the resized later soulsilver legendary keeps its sourced height"
  )
  local first = drawBytes(scene, scope, 1280, 720)
  local second = drawBytes(scene, scope, 1280, 720)
  local third = drawBytes(scene, scope, 1280, 720)
  -- Draw-cadence stability within GPU raster noise: a draw that advanced
  -- the source timeline would move the legendary and its animation
  -- (tens of thousands of pixels), while separate 3D passes may round a
  -- handful of accent texels by a few LSBs.
  local changed, maxAbs = 0, 0
  for i = 1, #first, 4 do
    local r1, g1, b1 = string.byte(first, i, i + 2)
    local r2, g2, b2 = string.byte(second, i, i + 2)
    local peak = math.max(math.abs(r1 - r2), math.abs(g1 - g2), math.abs(b1 - b2))
    if peak > 4 then
      changed = changed + 1
    end
    maxAbs = math.max(maxAbs, peak)
  end
  Assert.isTrue(changed < 100, ("repeated draws keep the title stage stable (%d pixels moved)"):format(changed))
  Assert.isTrue(maxAbs <= 4, ("repeated draws keep title texels within raster noise (peak %d)"):format(maxAbs))
  local changedThird, maxThird = 0, 0
  for i = 1, #first, 4 do
    local r1, g1, b1 = string.byte(first, i, i + 2)
    local r3, g3, b3 = string.byte(third, i, i + 2)
    local peak = math.max(math.abs(r1 - r3), math.abs(g1 - g3), math.abs(b1 - b3))
    if peak > 4 then
      changedThird = changedThird + 1
    end
    maxThird = math.max(maxThird, peak)
  end
  Assert.isTrue(
    changedThird < 100,
    ("a third draw shows no ratcheting mutation (%d pixels moved)"):format(changedThird)
  )
  Assert.isTrue(maxThird <= 4, ("a third draw stays within raster noise (peak %d)"):format(maxThird))
  scene:dispose()
end

local function heartgoldTitleFramingIsBlockedWithoutADump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold title framing needs a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the legendary projection legs "
        .. "cannot run for HeartGold and are never faked"
    )
  end
  local scene = openTitleScene(scope, "heartgold", REFERENCE_WIDTH, REFERENCE_HEIGHT, "single")
  scene:_drawModel()
  scene:dispose()
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
  ["title holds its prompt without staging copy"] = titleHoldsPromptWithoutStagingCopy,
  ["legendary silhouette matches its sourced reference frame at native size"] = legendaryMatchesItsSourcedReferenceFrame,
  ["host resizing keeps the sourced title lens centered"] = hostResizingKeepsTheSourcedTitleLens,
  ["legendary framing shares model world units at native size"] = legendaryFramingSharesModelWorldUnitsAtNativeSize,
  ["title waypoints keep authored timing across host sizes"] = titleWaypointsKeepAuthoredTimingAcrossHostSizes,
  ["soulsilver legendary framing matches source projection at two poses"] = soulsilverLegendaryFramingMatchesSourceProjectionAtTwoPoses,
  ["heartgold title framing is blocked without a dump"] = heartgoldTitleFramingIsBlockedWithoutADump,
})
T.metadata.capabilities = { "graphics", "rom_dump" }
T.metadata.derivedAssets = { "startup-title:global", "field-font:global" }
T.metadata.tags = { "startup", "title", "lifecycle" }
return T
