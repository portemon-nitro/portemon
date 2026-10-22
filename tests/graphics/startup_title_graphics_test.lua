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
    if layout.configuration == "wide" then
      Assert.isFalse(
        composition.stageWidth == 512 and composition.stageHeight == 192,
        "wide title uses one panoramic stage, not two peer screens"
      )
      Assert.isFalse(composition.lowerPanel == true, "wide title has no peer lower panel")
      local wideDraws = countTitleImageDraws(scene, scope, layout.width, layout.height)
      Assert.equal(wideDraws.canvas, 1, "wide title draws the live animated canvas exactly once")
      Assert.equal(wideDraws.logo, 1, "wide title keeps the source edition mark visible as a subordinate accent")
      Assert.equal(wideDraws.lower, 0, "wide title does not paint a second full lower screen")
      Assert.equal(wideDraws.decor, 0, "wide title does not paint a second full decor screen")
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
      Assert.equal(composition.stageHeight, 384, "tall title stacks two source roles")
      Assert.equal(composition.legend.y, 0, "tall legend remains in the upper source role")
      Assert.equal(composition.lower.y, 192, "tall lower-screen art stays beneath the legend")
    elseif layout.configuration == "nativeLike" then
      Assert.equal(composition.stageWidth, 256, "4:3 keeps one native logical stage")
      Assert.equal(composition.stageHeight, 192, "4:3 keeps native logical height")
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

local T = GraphicsSmoke.suite({
  ["generated HGSS titles render, animate and fit each supported display"] = renderAvailableEditions,
})
T.metadata.capabilities = { "graphics", "rom_dump" }
T.metadata.derivedAssets = { "startup-title:global" }
T.metadata.tags = { "startup", "title", "lifecycle" }
return T
