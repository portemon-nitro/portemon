-- Pixel-check the battle renderer's Pokepic Z ordering with overlapping
-- synthetic portraits and the source slot depths.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local BattlePicturePass = require("libs.hgss.src.presentation.BattlePicturePass")

local T = {}

local function solidImage(scope, width, height, red, green, blue, alpha)
  local data = scope:own(love.image.newImageData(width, height))
  data:mapPixel(function()
    return red, green, blue, alpha
  end)
  return scope:own(love.graphics.newImage(data))
end

local function renderPictures(scope, graphics, pictures)
  local pass = scope:own(BattlePicturePass.new(graphics))
  return pass:render(graphics, pictures)
end

local function tileMap(tile)
  local entries = {}
  for _ = 1, 64 do
    entries[#entries + 1] = { tile = tile, flipH = false, flipV = false, palette = 0 }
  end
  return { width = 64, height = 64, entries = entries }
end

local function rasterImage(scope, raster)
  local data = scope:own(love.image.newImageData(raster.width, raster.height, "rgba8"))
  for y = 0, raster.height - 1 do
    for x = 0, raster.width - 1 do
      local r, g, b, a = raster:pixel(x, y)
      data:setPixel(x, y, r / 255, g / 255, b / 255, a / 255)
    end
  end
  return scope:own(love.graphics.newImage(data))
end

function T.transparent_effect_bg3_reveals_a_lower_priority_plane(scope)
  local manifest = ManifestFixture.manifest()
  local scene = BattleScene.new()
  local basePalette = {}
  for index = 0, 255 do
    basePalette[index + 1] = { r = 0, g = 0, b = 0 }
  end
  basePalette[2] = { r = 255, g = 0, b = 0 }
  scene:installBackground({
    characters = string.char(1) .. string.rep("\0", 63),
    colorMode = "8bpp",
    map = tileMap(0),
    palette = { colors = basePalette },
  })
  local effectPalette = {}
  for index = 0, 15 do
    effectPalette[index + 1] = { r = 0, g = 0, b = 0 }
  end
  effectPalette[2] = { r = 0, g = 255, b = 0 }
  scene:installBackgroundLayer("battle/effect", {
    character = { depth = 3, tiles = string.char(0x10) .. string.rep("\0", 31) },
    screen = tileMap(0),
    palette = { colors = effectPalette },
  })
  local effectImage = rasterImage(scope, scene:backgroundRaster())
  local lowerPlane = solidImage(scope, 256, 192, 0, 0, 1, 1)
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true, dpiscale = 1 }))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(lowerPlane, 0, 0)
  BattleRenderer.drawPane({
    graphics = love.graphics,
    text = { measure = function() return { width = 0, height = 0 } end, drawText = function() end },
    windows = { drawWindow = function() end, drawApplicationFrame = function() end },
    assets = {
      drawable = function(_, key)
        return key == "scene:transparent-effect" and lowerPlane or nil
      end,
      background = function()
        return effectImage
      end,
    },
    sceneImageKey = "scene:transparent-effect",
    frameKey = "default",
    doublesHud = manifest.hud.doubles,
  }, {
    slotGeometry = manifest.battlefield.slots,
    hudPatchSpans = manifest.hud.patchSpans,
    backgroundRaster = scene:backgroundRaster(),
    mode = "idle",
    message = "",
    battlers = {},
    effectInstances = {},
  }, "detail", {})
  love.graphics.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  local clearRed, clearGreen, clearBlue = pixels:getPixel(0, 0)
  Assert.deepEqual(
    { math.floor(clearRed * 255 + 0.5), math.floor(clearGreen * 255 + 0.5), math.floor(clearBlue * 255 + 0.5) },
    { 0, 0, 255 },
    "transparent effect-BG3 texels reveal the distinct lower-priority plane, not replaced BG3"
  )
  local effectRed, effectGreen, effectBlue = pixels:getPixel(1, 0)
  Assert.deepEqual(
    { math.floor(effectRed * 255 + 0.5), math.floor(effectGreen * 255 + 0.5), math.floor(effectBlue * 255 + 0.5) },
    { 0, 255, 0 },
    "nonzero source effect-BG3 texels replace the lower-priority plane"
  )
end

function T.overlapping_pictures_resolve_by_source_z_under_hostile_color(scope)
  local images = {
    scene = solidImage(scope, 256, 192, 0, 0, 1, 1),
    shadow = solidImage(scope, 64, 64, 1, 1, 0, 1),
    foe = solidImage(scope, 80, 80, 1, 0, 0, 1),
    foe2 = solidImage(scope, 80, 80, 0, 1, 0, 1),
    transparent = solidImage(scope, 80, 80, 0, 0, 0, 0),
  }
  local manifest = ManifestFixture.manifest()
  local slots = manifest.battlefield.slots
  for _, row in ipairs(slots) do
    row.settledX, row.settledY = 140, 120
    row.hudX, row.hudY = 240, 180
  end
  local function battler(combatant, side, position, name, selector, image)
    return {
      combatant = combatant,
      side = side,
      position = position,
      name = name,
      level = 7,
      hp = 20,
      maxHp = 20,
      active = true,
      visible = true,
      portraitSelector = selector,
      picture = image,
    }
  end
  local imagesByKey = {
    ["mon:FOE/0/male/plain/front"] = images.foe,
    ["mon:FOE2/0/male/plain/front"] = images.foe2,
    ["mon:ALLY/0/male/plain/back"] = images.transparent,
    ["mon:ALLY2/0/male/plain/back"] = images.transparent,
  }
  local graphics = love.graphics
  local canvas = scope:own(graphics.newCanvas(256, 192, { format = "rgba8", readable = true, dpiscale = 1 }))
  local previousColor = { 0.2, 0.4, 0.6, 0.8 }
  graphics.setCanvas(canvas)
  graphics.clear(0, 0, 0, 0)
  graphics.setColor(previousColor[1], previousColor[2], previousColor[3], previousColor[4])
  BattleRenderer.drawPane({
    graphics = graphics,
    text = {
      measure = function(value)
        return { width = #tostring(value) * 8, height = 16 }
      end,
      drawText = function() end,
      drawTextWithPalette = function() end,
    },
    windows = { drawWindow = function() end, drawApplicationFrame = function() end },
    assets = {
      drawable = function(_, key)
        if key == "scene:depth-test" then
          return images.scene
        end
        if key == "shadow" then
          return images.shadow
        end
        if
          key == "hud:player-left"
          or key == "hud:player-right"
          or key == "hud:enemy-left"
          or key == "hud:enemy-right"
        then
          return nil
        end
        return imagesByKey[key]
      end,
      renderPictures = function(_, drawGraphics, pictures)
        return renderPictures(scope, drawGraphics, pictures)
      end,
      background = function()
        return nil
      end,
    },
    sceneImageKey = "scene:depth-test",
    frameKey = "frame",
    doublesHud = manifest.hud.doubles,
  }, {
    slotGeometry = slots,
    hudPatchSpans = manifest.hud.patchSpans,
    mode = "idle",
    message = "",
    battlers = {
      battler(1, 1, 0, "ALLY", "ALLY/0/male/plain/back"),
      battler(3, 1, 1, "ALLY2", "ALLY2/0/male/plain/back"),
      battler(2, 2, 2, "FOE", "FOE/0/male/plain/front"),
      battler(4, 2, 3, "FOE2", "FOE2/0/male/plain/front"),
    },
    effectInstances = {},
  }, "detail", {})
  local afterRed, afterGreen, afterBlue, afterAlpha = graphics.getColor()
  Assert.isTrue(math.abs(afterRed - previousColor[1]) < 1 / 255, "renderer restores incoming red tint")
  Assert.isTrue(math.abs(afterGreen - previousColor[2]) < 1 / 255, "renderer restores incoming green tint")
  Assert.isTrue(math.abs(afterBlue - previousColor[3]) < 1 / 255, "renderer restores incoming blue tint")
  Assert.isTrue(math.abs(afterAlpha - previousColor[4]) < 1 / 255, "renderer restores incoming alpha tint")
  graphics.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  local red, green, blue = pixels:getPixel(120, 120)
  Assert.equal(math.floor(red * 255 + 0.5), 255, "the less-negative native Pokepic Z is in front")
  Assert.equal(math.floor(green * 255 + 0.5), 0, "the farther source Z does not overwrite the front picture")
  Assert.equal(math.floor(blue * 255 + 0.5), 0, "the BG3 pixel remains behind both Pokepics")
end

function T.narration_text_is_clipped_to_the_source_window_content(scope)
  local scene = solidImage(scope, 256, 192, 0, 0, 1, 1)
  local effect = solidImage(scope, 256, 192, 0.5, 0, 0.5, 1)
  local hud = solidImage(scope, 1024, 64, 1, 1, 0, 1)
  local portrait = solidImage(scope, 80, 80, 1, 0, 0, 1)
  local manifest = ManifestFixture.manifest()
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true, dpiscale = 1 }))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  BattleRenderer.drawPane({
    graphics = love.graphics,
    text = {
      measure = function(value)
        return { width = #tostring(value) * 8, height = 16 }
      end,
      drawText = function(_, x, y)
        love.graphics.setColor(1, 0, 0, 1)
        love.graphics.rectangle("fill", x, y, 300, 16)
      end,
      drawTextWithPalette = function() end,
    },
    windows = {
      drawWindow = function(box)
        love.graphics.setColor(0, 1, 0, 1)
        love.graphics.rectangle("fill", box.x, box.y, box.width, box.height)
      end,
      drawApplicationFrame = function() end,
    },
    assets = {
      drawable = function(_, key)
        if key == "hud:player" then
          return hud
        end
        if key == "mon:ALLY/0/male/plain/back" then
          return portrait
        end
        return key == "scene:narration-mask" and scene or nil
      end,
      background = function()
        return effect
      end,
      renderPictures = function(_, drawGraphics, pictures)
        return renderPictures(scope, drawGraphics, pictures)
      end,
    },
    sceneImageKey = "scene:narration-mask",
    frameKey = "frame",
  }, {
    slotGeometry = manifest.battlefield.slots,
    hudPatchSpans = manifest.hud.patchSpans,
    hudSections = { player = manifest.hud.player, enemy = manifest.hud.enemy },
    backgroundRaster = { effect = true },
    mode = "idle",
    message = "A long message",
    battlers = {
      {
        combatant = 1,
        side = 1,
        position = 0,
        name = "ALLY",
        level = 7,
        hp = 20,
        maxHp = 20,
        active = true,
        visible = true,
        pictureYOffset = 20,
        portraitSelector = "ALLY/0/male/plain/back",
      },
    },
    effectInstances = {},
  }, "detail", {})
  love.graphics.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  local bgRed, bgGreen, bgBlue = pixels:getPixel(10, 10)
  Assert.equal(math.floor(bgRed * 255 + 0.5), 128, "the selected effect BG3 raster replaces the static scene")
  Assert.equal(math.floor(bgGreen * 255 + 0.5), 0, "the BG3 effect keeps its source green channel")
  Assert.equal(math.floor(bgBlue * 255 + 0.5), 128, "the BG3 effect keeps its source blue channel")
  local objRed, objGreen, objBlue = pixels:getPixel(239, 140)
  Assert.equal(math.floor(objRed * 255 + 0.5), 255, "the health-box OBJ remains visible above the effect BG3")
  Assert.equal(math.floor(objGreen * 255 + 0.5), 255, "the health-box OBJ keeps its source green channel")
  Assert.equal(math.floor(objBlue * 255 + 0.5), 0, "the health-box OBJ keeps its source blue channel")
  local innerRed, innerGreen = pixels:getPixel(223, 168)
  local outsideRed, outsideGreen = pixels:getPixel(224, 168)
  Assert.equal(math.floor(innerRed * 255 + 0.5), 255, "text remains visible at the last content column")
  Assert.equal(math.floor(innerGreen * 255 + 0.5), 0, "the content sample is not the window fill")
  Assert.equal(math.floor(outsideRed * 255 + 0.5), 0, "text is clipped at the source window content edge")
  Assert.equal(math.floor(outsideGreen * 255 + 0.5), 255, "the window fill remains visible outside its content")
  local portraitRed, portraitGreen = pixels:getPixel(64, 150)
  local maskedRed, maskedGreen, maskedBlue = pixels:getPixel(64, 156)
  Assert.equal(math.floor(portraitRed * 255 + 0.5), 255, "the source-Z Pokepic reaches the pixel immediately above the narration window")
  Assert.equal(math.floor(portraitGreen * 255 + 0.5), 0, "the visible Pokepic keeps its independent red source pixel")
  Assert.equal(math.floor(maskedRed * 255 + 0.5), 0, "the source window fill masks the underlying Pokepic")
  Assert.equal(math.floor(maskedGreen * 255 + 0.5), 255, "the native window layer owns the masked pixel")
  Assert.equal(math.floor(maskedBlue * 255 + 0.5), 0, "the window mask stays green over the effect BG and Pokepic")
end

function T.compact_composition_uses_native_blending_under_hostile_incoming_state(scope)
  local scene = solidImage(scope, 256, 192, 0, 0, 1, 1)
  local portrait = solidImage(scope, 80, 80, 1, 0, 0, 1)
  local manifest = ManifestFixture.manifest()
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true, dpiscale = 1 }))
  local graphics = love.graphics
  graphics.setCanvas(canvas)
  graphics.clear(0, 0, 0, 0)
  graphics.setColor(0.2, 0.3, 0.4, 0.5)
  graphics.setBlendMode("add", "alphamultiply")
  BattleRenderer.drawPane({
    graphics = graphics,
    assets = {
      drawable = function(_, key)
        if key == "scene:compact-composition" then
          return scene
        end
        if key == "mon:FOE/0/male/plain/front" then
          return portrait
        end
        return nil
      end,
      background = function()
        return nil
      end,
    },
    sceneImageKey = "scene:compact-composition",
  }, {
    battlers = {
      {
        combatant = 1,
        side = 2,
        position = 2,
        active = true,
        visible = true,
        portraitSelector = "FOE/0/male/plain/front",
      },
    },
    effectInstances = {},
  }, "compact", {
    scene = { x = 0, y = 0, width = 256, height = 136 },
    enemyCenter = { x = 80, y = 64 },
  })
  local restoredRed, restoredGreen, restoredBlue, restoredAlpha = graphics.getColor()
  Assert.isTrue(math.abs(restoredRed - 0.2) < 1 / 255, "compact drawing restores host red tint")
  Assert.isTrue(math.abs(restoredGreen - 0.3) < 1 / 255, "compact drawing restores host green tint")
  Assert.isTrue(math.abs(restoredBlue - 0.4) < 1 / 255, "compact drawing restores host blue tint")
  Assert.isTrue(math.abs(restoredAlpha - 0.5) < 1 / 255, "compact drawing restores host alpha tint")
  local restoredBlend, restoredAlphaMode = graphics.getBlendMode()
  Assert.equal(restoredBlend, "add", "compact drawing restores host blend mode")
  Assert.equal(restoredAlphaMode, "alphamultiply", "compact drawing restores host alpha mode")
  graphics.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  local red, green, blue = pixels:getPixel(90, 74)
  Assert.equal(math.floor(red * 255 + 0.5), 255, "compact portrait keeps its source red under normal alpha blending")
  Assert.equal(math.floor(green * 255 + 0.5), 0, "compact portrait does not inherit host tint")
  Assert.equal(math.floor(blue * 255 + 0.5), 0, "compact portrait composites over the scene instead of adding to it")
  local sceneRed, sceneGreen, sceneBlue = pixels:getPixel(10, 10)
  Assert.equal(math.floor(sceneRed * 255 + 0.5), 0, "compact BG3 keeps its source red channel")
  Assert.equal(math.floor(sceneGreen * 255 + 0.5), 0, "compact BG3 keeps its source green channel")
  Assert.equal(math.floor(sceneBlue * 255 + 0.5), 255, "compact BG3 survives hostile host color and blend state")
end

function T.native_picture_depth_rejects_a_later_far_quad_and_restores_host_state(scope)
  local near = solidImage(scope, 80, 80, 1, 0, 0, 1)
  local far = solidImage(scope, 80, 80, 0, 1, 0, 1)
  local shadow = solidImage(scope, 64, 64, 1, 1, 0, 1)
  local pass = BattlePicturePass.new(love.graphics)
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true, dpiscale = 1 }))
  local graphics = love.graphics
  graphics.setCanvas(canvas)
  graphics.clear(0, 0, 0, 0)
  graphics.setColor(0.2, 0.3, 0.4, 0.5)
  graphics.setBlendMode("add", "alphamultiply")
  graphics.setDepthMode("greater", false)
  graphics.setScissor(8, 9, 210, 160)
  graphics.setWireframe(true)
  graphics.setMeshCullMode("back")
  local layer = pass:render(graphics, {
    {
      image = near,
      centerX = 128,
      centerY = 96,
      zCenter = -256,
      width = 80,
      height = 80,
      tintR = 1,
      tintG = 1,
      tintB = 1,
      alpha = 1,
    },
    {
      image = far,
      centerX = 128,
      centerY = 96,
      zCenter = -768,
      width = 80,
      height = 80,
      tintR = 1,
      tintG = 1,
      tintB = 1,
      alpha = 1,
    },
    {
      kind = "shadow",
      image = shadow,
      textureRegion = { x = 0, y = 0, width = 64, height = 16 },
      centerX = 128,
      centerY = 128,
      zCenter = -1000,
      width = 64,
      height = 16,
      shadowAffine = true,
      affineWidth = 0x100,
      affineHeight = 0x100,
      tintR = 1,
      tintG = 1,
      tintB = 1,
      alpha = 1,
    },
  })
  local red, green, blue, alpha = graphics.getColor()
  Assert.isTrue(math.abs(red - 0.2) < 1 / 255, "the pass restores host red tint")
  Assert.isTrue(math.abs(green - 0.3) < 1 / 255, "the pass restores host green tint")
  Assert.isTrue(math.abs(blue - 0.4) < 1 / 255, "the pass restores host blue tint")
  Assert.isTrue(math.abs(alpha - 0.5) < 1 / 255, "the pass restores host alpha tint")
  local blend, alphaMode = graphics.getBlendMode()
  Assert.deepEqual({ blend, alphaMode }, { "add", "alphamultiply" }, "the pass restores host blending")
  local depthMode, depthWrite = graphics.getDepthMode()
  Assert.deepEqual({ depthMode, depthWrite }, { "greater", false }, "the pass restores host depth")
  local sx, sy, sw, sh = graphics.getScissor()
  Assert.deepEqual({ sx, sy, sw, sh }, { 8, 9, 210, 160 }, "the pass restores host clipping")
  Assert.isTrue(graphics.isWireframe(), "the pass restores host wireframe state")
  Assert.equal(graphics.getMeshCullMode(), "back", "the pass restores host mesh culling")
  graphics.setScissor()
  graphics.setDepthMode()
  graphics.setBlendMode("alpha", "alphamultiply")
  graphics.setWireframe(false)
  graphics.setMeshCullMode("none")
  graphics.setColor(1, 1, 1, 1)
  graphics.draw(layer, 0, 0)
  graphics.setCanvas()
  local pixel = scope:own(canvas:newImageData())
  local r, g, b = pixel:getPixel(128, 128)
  Assert.deepEqual(
    { math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5) },
    { 255, 0, 0 },
    "the source shadow Z stays behind a near Pokepic even when submitted later"
  )
  graphics.setCanvas()
  pass:release()
  pass:release()
end

function T.shadow_size_uses_the_compiled_source_uv_region(scope)
  local data = scope:own(love.image.newImageData(64, 64))
  data:mapPixel(function(_, y)
    if y < 16 then
      return 1, 0, 0, 1
    elseif y < 32 then
      return 0, 1, 0, 1
    elseif y < 48 then
      return 0, 0, 1, 1
    end
    return 1, 1, 1, 1
  end)
  local image = scope:own(love.graphics.newImage(data))
  local pass = scope:own(BattlePicturePass.new(love.graphics))
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true, dpiscale = 1 }))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  local layer = pass:render(love.graphics, {
    {
      kind = "shadow",
      image = image,
      centerX = 128,
      centerY = 96,
      zCenter = BattleScene.SHADOW_DEPTH,
      width = 64,
      height = 16,
      textureRegion = { size = 2, x = 0, y = 32, width = 64, height = 16 },
      shadowAffine = false,
      tintR = 1,
      tintG = 1,
      tintB = 1,
      alpha = 1,
    },
  })
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.draw(layer)
  love.graphics.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  local r, g, b = pixels:getPixel(128, 96)
  Assert.deepEqual(
    { math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5) },
    { 0, 0, 255 },
    "shadow size two samples its normalized source UV region"
  )
end

function T.native_picture_crop_uses_source_offsets_and_extent(scope)
  local image = scope:own(love.image.newImageData(80, 80))
  image:mapPixel(function(x)
    if x < 16 then
      return 1, 0, 0, 1
    end
    return 0, 1, 0, 1
  end)
  local texture = scope:own(love.graphics.newImage(image))
  local pass = scope:own(BattlePicturePass.new(love.graphics))
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true, dpiscale = 1 }))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  local layer = pass:render(love.graphics, {
    {
      image = texture,
      centerX = 128,
      centerY = 96,
      zCenter = -256,
      width = 32,
      height = 24,
      pictureVisible = true,
      xOffset2 = 16,
      yOffset2 = 8,
      tintR = 1,
      tintG = 1,
      tintB = 1,
      alpha = 1,
    },
  })
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.draw(layer)
  love.graphics.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  local croppedRed, croppedGreen = pixels:getPixel(120, 70)
  Assert.deepEqual({ math.floor(croppedRed * 255 + 0.5), math.floor(croppedGreen * 255 + 0.5) }, { 0, 255 })
  local outsideRed, outsideGreen = pixels:getPixel(100, 70)
  Assert.deepEqual({ math.floor(outsideRed * 255 + 0.5), math.floor(outsideGreen * 255 + 0.5) }, { 0, 0 })
end

function T.native_picture_crop_must_remain_inside_the_staged_selector_frame(scope)
  local image = solidImage(scope, 80, 80, 1, 1, 1, 1)
  local pass = scope:own(BattlePicturePass.new(love.graphics))
  local ok = pcall(function()
    pass:render(love.graphics, {
      {
        image = image,
        centerX = 128,
        centerY = 96,
        zCenter = -256,
        width = 32,
        height = 24,
        pictureVisible = true,
        xOffset2 = 64,
        yOffset2 = 0,
        tintR = 1,
        tintG = 1,
        tintB = 1,
        alpha = 1,
      },
    })
  end)
  Assert.isFalse(ok, "a crop cannot address pixels omitted from the staged two-frame selector")
end

function T.picture_state_applies_affine_tint_and_shadow_visibility(scope)
  local images = {
    scene = solidImage(scope, 256, 192, 0, 0, 1, 1),
    shadow = solidImage(scope, 64, 16, 1, 1, 0, 1),
    portrait = solidImage(scope, 80, 80, 1, 1, 1, 1),
    transformed = solidImage(scope, 80, 80, 1, 1, 0, 1),
  }
  local manifest = ManifestFixture.manifest()
  local battler = {
    combatant = 1,
    activation = "activation-1",
    side = 1,
    position = 0,
    name = "LEAD",
    level = 7,
    hp = 20,
    maxHp = 20,
    active = true,
    visible = true,
    portraitSelector = "LEAD/0/male/plain/back",
  }
  local scene = BattleScene.new()
  scene:install(battler)
  scene:applyPictureState(battler, {
    portraitSelector = "LEAD/f1/male/plain/back",
    rotation = 0,
    rotationX = 0x2AAA,
    scaleX = 0.5,
    scaleY = 0.5,
    pictureTint = { r = 1, g = 0, b = 0, a = 1 },
    paletteFade = { start = 8, finish = 8, framesPer = 0, targetColor = 0x7C00 },
    shadowVisible = false,
  })
  scene:stepSourceTick()
  local pictureState = assert(scene:pictureState(battler), "the active palette task publishes its visual state")
  for key, value in pairs(pictureState) do
    battler[key] = value
  end
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true, dpiscale = 1 }))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  BattleRenderer.drawPane({
    graphics = love.graphics,
    text = {
      measure = function(value)
        return { width = #tostring(value) * 8, height = 16 }
      end,
      drawText = function() end,
      drawTextWithPalette = function() end,
    },
    windows = { drawWindow = function() end, drawApplicationFrame = function() end },
    assets = {
      drawable = function(_, key)
        if key == "scene:picture-state" then
          return images.scene
        end
        if key == "shadow" then
          return images.shadow
        end
        if key == "mon:LEAD/0/male/plain/back" then
          return images.portrait
        end
        if key == "mon:LEAD/f1/male/plain/back" then
          return images.transformed
        end
        return nil
      end,
      renderPictures = function(_, drawGraphics, pictures)
        return renderPictures(scope, drawGraphics, pictures)
      end,
      background = function()
        return nil
      end,
    },
    sceneImageKey = "scene:picture-state",
    frameKey = "frame",
    doublesHud = manifest.hud.doubles,
  }, {
    slotGeometry = manifest.battlefield.slots,
    hudPatchSpans = manifest.hud.patchSpans,
    hudSections = { player = manifest.hud.player, enemy = manifest.hud.enemy },
    mode = "idle",
    message = "",
    battlers = { battler },
    effectInstances = {},
  }, "detail", {})
  love.graphics.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  local centerRed, centerGreen, centerBlue = pixels:getPixel(64, 112)
  Assert.equal(math.floor(centerRed * 255 + 0.5), 123, "native RGB555 palette fade blends before material tint")
  Assert.equal(math.floor(centerGreen * 255 + 0.5), 0, "picture tint changes the source green channel")
  local tiltedRed, tiltedGreen, tiltedBlue = pixels:getPixel(64, 95)
  Assert.deepEqual(
    { math.floor(tiltedRed * 255 + 0.5), math.floor(tiltedGreen * 255 + 0.5), math.floor(tiltedBlue * 255 + 0.5) },
    { 0, 0, 255 },
    "source X rotation foreshortens the picture around its center"
  )
  local outsideRed = pixels:getPixel(30, 112)
  Assert.equal(math.floor(outsideRed * 255 + 0.5), 0, "affine scale uses the native picture center")
  local shadowRed, shadowGreen = pixels:getPixel(40, 108)
  Assert.deepEqual(
    { math.floor(shadowRed * 255 + 0.5), math.floor(shadowGreen * 255 + 0.5) },
    { 0, 0 },
    "the source presentation state can suppress its shadow independently"
  )

  local restored = scene:restorePictureState(battler)
  Assert.deepEqual(restored, {
    portraitSelector = "LEAD/0/male/plain/back",
  }, "restore recovers the activation's original appearance")
  for key in pairs(pictureState) do
    battler[key] = nil
  end
  for key, value in pairs(restored) do
    battler[key] = value
  end
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  BattleRenderer.drawPane({
    graphics = love.graphics,
    text = {
      measure = function(value)
        return { width = #tostring(value) * 8, height = 16 }
      end,
      drawText = function() end,
      drawTextWithPalette = function() end,
    },
    windows = { drawWindow = function() end, drawApplicationFrame = function() end },
    assets = {
      drawable = function(_, key)
        if key == "scene:picture-state" then
          return images.scene
        end
        if key == "shadow" then
          return images.shadow
        end
        if key == "mon:LEAD/0/male/plain/back" then
          return images.portrait
        end
        if key == "mon:LEAD/f1/male/plain/back" then
          return images.transformed
        end
        return nil
      end,
      renderPictures = function(_, drawGraphics, pictures)
        return renderPictures(scope, drawGraphics, pictures)
      end,
      background = function()
        return nil
      end,
    },
    sceneImageKey = "scene:picture-state",
    frameKey = "frame",
    doublesHud = manifest.hud.doubles,
  }, {
    slotGeometry = manifest.battlefield.slots,
    hudPatchSpans = manifest.hud.patchSpans,
    hudSections = { player = manifest.hud.player, enemy = manifest.hud.enemy },
    mode = "idle",
    message = "",
    battlers = { battler },
    effectInstances = {},
  }, "detail", {})
  love.graphics.setCanvas()
  pixels = scope:own(canvas:newImageData())
  local restoredRed, restoredGreen, restoredBlue = pixels:getPixel(64, 112)
  Assert.deepEqual(
    { math.floor(restoredRed * 255 + 0.5), math.floor(restoredGreen * 255 + 0.5), math.floor(restoredBlue * 255 + 0.5) },
    { 255, 255, 255 },
    "restored source appearance draws with neutral tint"
  )
  local restoredShadowRed, restoredShadowGreen = pixels:getPixel(40, 108)
  Assert.deepEqual(
    { math.floor(restoredShadowRed * 255 + 0.5), math.floor(restoredShadowGreen * 255 + 0.5) },
    { 255, 255 },
    "restored source presentation shows its original shadow"
  )
end

return GraphicsSmoke.suite(T)
