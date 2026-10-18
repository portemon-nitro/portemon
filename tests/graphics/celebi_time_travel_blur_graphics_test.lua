-- Exercises the source-timed Celebi feedback shader with synthetic field pixels.

local Assert = require("tests.support.Assert")
local CelebiTimeTravelBlur = require("libs.hgss.src.presentation.CelebiTimeTravelBlur")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local T = GraphicsSmoke.suite({
  ["field capture recursively blends the composed main scene once per source frame"] = function(scope)
    local graphics = love.graphics
    local viewport = {
      width = 320,
      height = 240,
      worldViewport = { x = 32, y = 24, width = 256, height = 192 },
    }
    local target = scope:own(graphics.newCanvas(320, 240, { format = "rgba8", readable = true, dpiscale = 1 }))
    local blur = scope:own(CelebiTimeTravelBlur.new())
    local currentColor, actorX = { 208, 0, 0 }, 64
    local function drawWorld()
      graphics.setColor(currentColor[1] / 255, currentColor[2] / 255, currentColor[3] / 255, 1)
      graphics.rectangle("fill", 32, 24, 256, 192)
      graphics.setColor(1, 1, 1, 1)
      graphics.rectangle("fill", actorX, 72, 16, 16)
    end
    local function drawFrame(frame, sequence)
      graphics.setCanvas(target)
      graphics.clear(25 / 255, 34 / 255, 43 / 255, 1)
      blur:draw({ active = true, blurActive = true, sequence = sequence or 1, swirlFrame = frame }, viewport, drawWorld)
    end
    local function pixel(x, y)
      graphics.setCanvas()
      local data = target:newImageData()
      local r, g, b, a = data:getPixel(x, y)
      data:release()
      return { r * 255, g * 255, b * 255, a * 255 }
    end
    local function near(channel, expected, message)
      Assert.near(channel, expected, 2, message)
    end

    drawFrame(1)
    local first = pixel(40, 32)
    near(first[1], 208, "first capture copies current world without old-frame residue")
    near(first[2], 0, "first capture has no prior green channel")

    currentColor, actorX = { 0, 208, 0 }, 112
    drawFrame(2)
    local second = pixel(40, 32)
    near(second[1], 169, "second capture uses thirteen parts of previous red output")
    near(second[2], 39, "second capture uses three parts of current green world")
    local actorTrail = pixel(68, 76)
    Assert.isTrue(
      actorTrail[1] > 190 and actorTrail[2] > 220,
      "the previous billboard silhouette contributes to capture"
    )
    graphics.setCanvas(target)
    graphics.setColor(1, 0, 1, 1)
    graphics.rectangle("fill", 200, 100, 20, 20)
    local uiPixel = pixel(205, 105)
    near(uiPixel[1], 255, "UI drawn after capture remains sharp red")
    near(uiPixel[2], 0, "UI drawn after capture remains sharp green")
    near(uiPixel[3], 255, "UI drawn after capture remains sharp blue")

    drawFrame(2)
    local duplicate = pixel(40, 32)
    near(duplicate[1], 169, "repeated draw does not compound history red")
    near(duplicate[2], 39, "repeated draw does not compound history green")

    currentColor, actorX = { 0, 0, 208 }, 160
    drawFrame(3)
    local third = pixel(40, 32)
    near(third[1], 137, "third capture recursively retains blended red history")
    near(third[2], 32, "third capture recursively retains blended green history")
    near(third[3], 39, "third capture adds current blue world")
    local cleanUiHistory = pixel(205, 105)
    near(cleanUiHistory[1], 137, "prior UI red never enters capture history")
    near(cleanUiHistory[2], 32, "prior UI green never enters capture history")
    near(cleanUiHistory[3], 39, "prior UI blue never enters capture history")
    local outside = pixel(5, 5)
    near(outside[1], 25, "outside the main viewport retains caller red")
    near(outside[2], 34, "outside the main viewport retains caller green")
    near(outside[3], 43, "outside the main viewport retains caller blue")

    currentColor = { 48, 64, 80 }
    drawFrame(1, 2)
    local restarted = pixel(40, 32)
    near(restarted[1], 48, "new scene sequence resets red history")
    near(restarted[2], 64, "new scene sequence resets green history")
    near(restarted[3], 80, "new scene sequence resets blue history")

    viewport = { width = 400, height = 300, worldViewport = { x = 72, y = 54, width = 256, height = 192 } }
    local replacementTarget =
      scope:own(graphics.newCanvas(400, 300, { format = "rgba8", readable = true, dpiscale = 1 }))
    target = replacementTarget
    drawFrame(1, 3)
    local scene, historyA, historyB, shader = blur._scene, blur._historyA, blur._historyB, blur._shader
    blur:release()
    graphics.setCanvas()
    Assert.isFalse(
      pcall(function()
        scene:newImageData()
      end),
      "release invalidates the full-scene target"
    )
    Assert.isFalse(
      pcall(function()
        historyA:newImageData()
      end),
      "release invalidates the first history target"
    )
    Assert.isFalse(
      pcall(function()
        historyB:newImageData()
      end),
      "release invalidates the second history target"
    )
    Assert.isFalse(
      pcall(function()
        shader:send("hasPrevious", false)
      end),
      "release invalidates the capture shader"
    )
    Assert.isNil(blur._scene, "idle presenter owns no scene canvas")
    Assert.isNil(blur._shader, "idle presenter owns no shader")

    local originalNewCanvas = graphics.newCanvas
    local allocatedCanvas
    local allocationCount = 0
    graphics.newCanvas = function(width, height, options)
      allocationCount = allocationCount + 1
      if allocationCount == 2 then
        error("synthetic history canvas allocation failure")
      end
      allocatedCanvas = originalNewCanvas(width, height, options)
      return allocatedCanvas
    end
    local stagedBlur = CelebiTimeTravelBlur.new()
    local staged = pcall(function()
      stagedBlur:draw({ active = true, blurActive = true, sequence = 4, swirlFrame = 1 }, viewport, drawWorld)
    end)
    graphics.newCanvas = originalNewCanvas
    Assert.isFalse(staged, "history acquisition failure propagates")
    graphics.setCanvas()
    Assert.isFalse(
      pcall(function()
        allocatedCanvas:newImageData()
      end),
      "failed staging releases the earlier canvas"
    )
    Assert.isNil(stagedBlur._scene, "failed staging publishes no partial target set")

    local failedBlur = CelebiTimeTravelBlur.new()
    graphics.setCanvas(target)
    graphics.setColor(0.2, 0.3, 0.4, 0.5)
    local failed = pcall(function()
      failedBlur:draw({ active = true, blurActive = true, sequence = 4, swirlFrame = 1 }, viewport, function()
        error("synthetic field render failure")
      end)
    end)
    Assert.isFalse(failed, "capture rendering errors propagate")
    Assert.equal(graphics.getCanvas(), target, "capture failure restores the caller canvas")
    local red, green, blue, alpha = graphics.getColor()
    Assert.near(red, 0.2, 1e-6, "capture failure restores caller red")
    Assert.near(green, 0.3, 1e-6, "capture failure restores caller green")
    Assert.near(blue, 0.4, 1e-6, "capture failure restores caller blue")
    Assert.near(alpha, 0.5, 1e-6, "capture failure restores caller alpha")
    Assert.isNil(failedBlur._scene, "capture failure releases staged scene resources")
  end,
  ["skipped source ticks preserve recursive feedback decay"] = function(scope)
    local graphics = love.graphics
    local viewport = {
      width = 320,
      height = 240,
      worldViewport = { x = 32, y = 24, width = 256, height = 192 },
    }
    local target = scope:own(graphics.newCanvas(320, 240, { format = "rgba8", readable = true, dpiscale = 1 }))
    local blur = scope:own(CelebiTimeTravelBlur.new())
    local color = { 208, 0, 0 }
    local function drawWorld()
      graphics.setColor(color[1] / 255, color[2] / 255, color[3] / 255, 1)
      graphics.rectangle("fill", 32, 24, 256, 192)
      graphics.setColor(1, 1, 1, 1)
    end
    local function drawFrame(frame, sequence)
      graphics.setCanvas(target)
      graphics.clear(0, 0, 0, 1)
      blur:draw({ active = true, blurActive = true, sequence = sequence, swirlFrame = frame }, viewport, drawWorld)
      graphics.setCanvas()
    end
    local function pixel()
      local data = target:newImageData()
      local r, g, b, a = data:getPixel(40, 32)
      data:release()
      return { r * 255, g * 255, b * 255, a * 255 }
    end

    drawFrame(1, 1)
    color = { 0, 0, 208 }
    drawFrame(2, 1)
    drawFrame(3, 1)
    local consecutive = pixel()

    color = { 208, 0, 0 }
    drawFrame(1, 2)
    color = { 0, 0, 208 }
    drawFrame(3, 2)
    local skipped = pixel()
    Assert.near(skipped[1], consecutive[1], 2, "two elapsed source ticks retain the same red history weight")
    Assert.near(skipped[2], consecutive[2], 2, "two elapsed source ticks retain the same green history weight")
    Assert.near(skipped[3], consecutive[3], 2, "two elapsed source ticks retain the same blue history weight")
    Assert.near(skipped[4], consecutive[4], 2, "feedback keeps current-frame alpha")

    graphics.setCanvas()
  end,
  ["same-scene source frame rewind is rejected"] = function(scope)
    local graphics = love.graphics
    local viewport = {
      width = 320,
      height = 240,
      worldViewport = { x = 32, y = 24, width = 256, height = 192 },
    }
    local target = scope:own(graphics.newCanvas(320, 240, { format = "rgba8", readable = true, dpiscale = 1 }))
    local blur = CelebiTimeTravelBlur.new()
    scope:own(blur)
    local function drawFrame(frame)
      graphics.setCanvas(target)
      graphics.clear(0, 0, 0, 1)
      blur:draw({ active = true, blurActive = true, sequence = 1, swirlFrame = frame }, viewport, function()
        graphics.setColor(1, 0, 0, 1)
        graphics.rectangle("fill", 32, 24, 256, 192)
        graphics.setColor(1, 1, 1, 1)
      end)
      graphics.setCanvas()
    end

    drawFrame(3)
    local rewound = pcall(function()
      drawFrame(2)
    end)
    Assert.isFalse(rewound, "a source-frame rewind within one scene is rejected")
    Assert.isNil(blur._scene, "a rejected rewind releases the blur targets")
    graphics.setCanvas()
  end,
}, { capabilities = { "graphics" } })

return T
