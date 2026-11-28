-- Indexed encounter palette sampling through the battle-local drawable
-- owner: immutable source indices plus one tiny exact palette reproduce the
-- composed CPU reference for whole-image and quad placements, a palette-only
-- change keeps the shared source upload, and failed candidates never disturb
-- the published generation. Synthetic fixtures only; no ROM required.

local Assert = require("tests.support.Assert")
local BattleEncounterIndexedRaster = require("game.hgss.src.battle.BattleEncounterIndexedRaster")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local Rgb555 = require("libs.codec.src.Rgb555")

local T = {}

local WIDTH = 4
local HEIGHT = 2

---@return string synthetic source-index bytes covering every sampling edge case
local function indexBytes()
  return table.concat({
    string.char(0, 0, 0, 255),
    string.char(9, 0, 0, 0),
    string.char(5, 0, 0, 128),
    string.char(3, 0, 0, 255),
    string.char(5, 0, 0, 255),
    string.char(7, 0, 0, 255),
    string.char(0, 200, 77, 255),
    string.char(3, 0, 0, 0),
  })
end

---@return table<integer, integer> first displayed palette words, sparse by design
local function wordsA()
  return {
    [1] = Rgb555.encode(31, 0, 0),
    [4] = Rgb555.encode(0, 31, 0),
    [6] = Rgb555.encode(0, 31, 0),
    [8] = Rgb555.encode(31, 31, 0),
    [10] = Rgb555.encode(31, 0, 31),
  }
end

---@return table<integer, integer> second displayed palette words with differing values
local function wordsB()
  return {
    [1] = Rgb555.encode(0, 0, 31),
    [4] = Rgb555.encode(31, 31, 0),
    [6] = Rgb555.encode(31, 31, 0),
    [8] = Rgb555.encode(0, 0, 0),
  }
end

---@param words table<integer, integer>? RGB555 words keyed by one-based palette slot
---@return string exact 256-slot RGBA8 palette bytes, opaque colors, zeroed gaps
local function paletteBytes(words)
  words = words or {}
  local out = {}
  for slot = 0, 255 do
    local word = words[slot + 1]
    if word == nil then
      out[#out + 1] = "\0\0\0\0"
    else
      local color = Rgb555.decode(word)
      out[#out + 1] = string.char(color.r, color.g, color.b, 255)
    end
  end
  return table.concat(out)
end

---@param bytes string packed RGBA8 pixels under inspection
---@param index integer zero-based pixel index under inspection
---@return integer red
---@return integer green
---@return integer blue
---@return integer alpha
local function pixelOf(bytes, index)
  local base = index * 4 + 1
  return bytes:byte(base, base + 3)
end

---@param bytes string packed RGBA8 pixels under inspection
---@param index integer zero-based pixel index under inspection
---@return integer red channel of the pixel
local function redOf(bytes, index)
  return bytes:byte(index * 4 + 1)
end

---@param scope table graphics scope owning the canvas under drawing
---@param width integer canvas width under drawing
---@param height integer canvas height under drawing
---@param draw fun() one production-style frame under measurement
---@return string readback pixels of the drawn canvas
local function renderBytes(scope, width, height, draw)
  local canvas = scope:own(love.graphics.newCanvas(width, height, { format = "rgba8", readable = true }))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setBlendMode("alpha")
  draw()
  love.graphics.setCanvas()
  return canvas:newImageData():getString()
end

---@param scope table graphics scope owning the reference image
---@param oracle string composed CPU reference pixels under uploading
---@return table straight RGBA image carrying the reference pixels
local function straightImage(scope, oracle)
  local data = love.image.newImageData(WIDTH, HEIGHT, "rgba8", oracle)
  local image = scope:own(love.graphics.newImage(data))
  image:setFilter("nearest", "nearest")
  return image
end

-- Indexed sampling matches the exact CPU reference: the oracle resolves
-- every edge case, then two differing palettes render pixel-identical
-- frames to the straight reference for whole-image and quad placements
-- while the source upload stays shared; a failed candidate keeps the
-- published generation, and the intro plane exposes matching flipped and
-- banked source indices.
function T.indexed_palette_sampling_matches_cpu_reference_with_stable_sources(scope)
  local indices = indexBytes()
  local referenceA = BattleEncounterIndexedRaster.render(indices, WIDTH, HEIGHT, wordsA())
  Assert.equal(referenceA.width, WIDTH, "the indexed mapping retains its width")
  Assert.equal(referenceA.height, HEIGHT, "the indexed mapping retains its height")
  Assert.deepEqual({ pixelOf(referenceA.pixels, 0) }, { 255, 0, 0, 255 }, "opaque slot zero samples its word")
  Assert.deepEqual({ pixelOf(referenceA.pixels, 1) }, { 0, 0, 0, 0 }, "transparent pixels need no palette word")
  Assert.deepEqual({ pixelOf(referenceA.pixels, 2) }, { 0, 255, 0, 128 }, "partial coverage keeps its own alpha")
  Assert.deepEqual({ pixelOf(referenceA.pixels, 3) }, { 0, 255, 0, 255 }, "indices select words, not colors")
  Assert.deepEqual(
    { pixelOf(referenceA.pixels, 4) },
    { pixelOf(referenceA.pixels, 3) },
    "repeated colors match across differing slots"
  )
  Assert.deepEqual({ pixelOf(referenceA.pixels, 6) }, { 255, 0, 0, 255 }, "non-semantic channels never tint")
  Assert.deepEqual({ pixelOf(referenceA.pixels, 7) }, { 0, 0, 0, 0 }, "transparent coverage stays zero")
  local referenceB = BattleEncounterIndexedRaster.render(indices, WIDTH, HEIGHT, wordsB())
  Assert.deepEqual({ pixelOf(referenceB.pixels, 0) }, { 0, 0, 255, 255 }, "a new palette recolors slot zero")
  Assert.deepEqual({ pixelOf(referenceB.pixels, 3) }, { 255, 255, 0, 255 }, "a new palette recolors slot three")
  local reslotted = indices:sub(1, 12) .. string.char(5, 0, 0, 200) .. indices:sub(17, 32)
  local reslottedReference = BattleEncounterIndexedRaster.render(reslotted, WIDTH, HEIGHT, wordsA())
  Assert.deepEqual(
    { pixelOf(reslottedReference.pixels, 3) },
    { 0, 255, 0, 200 },
    "a reslotted source keeps the shared displayed color with its own coverage"
  )
  Assert.deepEqual(
    { pixelOf(referenceA.pixels, 3) },
    { 0, 255, 0, 255 },
    "each source keeps its own coverage for the shared color"
  )
  local missing = string.char(11, 0, 0, 255)
  local ok, failure = pcall(BattleEncounterIndexedRaster.render, missing, 1, 1, wordsA())
  Assert.isFalse(ok, "a visible index without a displayed word fails")
  Assert.isTrue(tostring(failure):find("displayed palette word", 1, true) ~= nil, "the missing slot is diagnosed")

  local okOwner, Owner = pcall(require, "game.hgss.src.battle.BattleEncounterPaletteImage")
  Assert.isTrue(
    okOwner and type(Owner) == "table" and type(Owner.new) == "function",
    "encounter palette substitutions sample immutable source indices through a battle-local indexed drawable owner"
  )
  local owner = Owner.new({ graphics = love.graphics })
  local disposed = false
  local function disposeOnce()
    if not disposed then
      disposed = true
      owner:dispose()
    end
  end
  local realNewImageData = love.image.newImageData
  local okSteps, stepFailure = pcall(function()
    local source = { id = "probe-source", width = WIDTH, height = HEIGHT, pixels = indices }
    local payloads = {}
    love.image.newImageData = function(width, height, format, bytes, ...)
      payloads[#payloads + 1] = { width = width, height = height, format = format }
      return realNewImageData(width, height, format, bytes, ...)
    end
    local handleA = owner:acquire(source, paletteBytes(wordsA()))
    Assert.notNil(handleA, "the first generation acquires its sampler handle")
    local fullUploads = 0
    local paletteUploads = 0
    for _, payload in ipairs(payloads) do
      if payload.width == WIDTH and payload.height == HEIGHT then
        fullUploads = fullUploads + 1
      elseif payload.width == 256 and payload.height == 1 then
        paletteUploads = paletteUploads + 1
      end
    end
    Assert.equal(fullUploads, 1, "the first generation uploads its source indices once")
    Assert.equal(paletteUploads, 1, "the first generation uploads its small exact palette once")
    payloads = {}
    local handleB = owner:acquire(source, paletteBytes(wordsB()))
    Assert.notNil(handleB, "a palette-only change acquires its generation handle")
    fullUploads = 0
    paletteUploads = 0
    for _, payload in ipairs(payloads) do
      if payload.width == WIDTH and payload.height == HEIGHT then
        fullUploads = fullUploads + 1
      elseif payload.width == 256 and payload.height == 1 then
        paletteUploads = paletteUploads + 1
      end
    end
    Assert.equal(fullUploads, 0, "a palette-only change shares the stable source upload")
    Assert.equal(paletteUploads, 1, "a palette-only change uploads only its small exact palette")
    love.image.newImageData = realNewImageData

    local straightA = straightImage(scope, referenceA.pixels)
    local straightB = straightImage(scope, referenceB.pixels)
    local lg = love.graphics
    Assert.equal(
      renderBytes(scope, WIDTH, HEIGHT, function()
        handleA:draw(lg, 0, 0)
      end),
      renderBytes(scope, WIDTH, HEIGHT, function()
        lg.draw(straightA, 0, 0)
      end),
      "the whole indexed frame matches its straight reference"
    )
    Assert.equal(
      renderBytes(scope, WIDTH, HEIGHT, function()
        handleB:draw(lg, 0, 0)
      end),
      renderBytes(scope, WIDTH, HEIGHT, function()
        lg.draw(straightB, 0, 0)
      end),
      "the second palette frame matches its straight reference"
    )
    local viewport = lg.newQuad(1, 0, 2, 2, WIDTH, HEIGHT)
    Assert.equal(
      renderBytes(scope, 2, 2, function()
        handleA:drawQuad(lg, viewport, 0, 0)
      end),
      renderBytes(scope, 2, 2, function()
        lg.draw(straightA, viewport, 0, 0)
      end),
      "an indexed quad matches its straight reference placement"
    )
    Assert.equal(
      renderBytes(scope, WIDTH, HEIGHT, function()
        handleA:draw(lg, 0, 0)
      end),
      renderBytes(scope, WIDTH, HEIGHT, function()
        lg.draw(straightA, 0, 0)
      end),
      "the prior generation still matches while both generations stay live"
    )
    local tintShader = scope:own(lg.newShader([[
vec4 effect(vec4 color, Image tex, vec2 texCoord, vec2 screenCoord) {
  return color;
}
]]))
    lg.setShader(tintShader)
    lg.setColor(0.2, 0.4, 0.6, 0.8)
    handleB:draw(lg, 0, 0)
    Assert.isTrue(lg.getShader() == tintShader, "an indexed draw restores the caller shader")
    local r, g, b, a = lg.getColor()
    Assert.near(r, 0.2, 1e-6, "an indexed draw restores the caller tint red")
    Assert.near(g, 0.4, 1e-6, "an indexed draw restores the caller tint green")
    Assert.near(b, 0.6, 1e-6, "an indexed draw restores the caller tint blue")
    Assert.near(a, 0.8, 1e-6, "an indexed draw restores the caller tint alpha")
    lg.setShader()
    lg.setColor(1, 1, 1, 1)

    local rejected, cause = owner:acquire(source, "short")
    Assert.isNil(rejected, "an incomplete palette publishes nothing")
    Assert.isTrue(
      type(cause) == "string" and cause:find("palette", 1, true) ~= nil,
      "an incomplete palette is diagnosed"
    )
    Assert.equal(
      renderBytes(scope, WIDTH, HEIGHT, function()
        handleA:draw(lg, 0, 0)
      end),
      renderBytes(scope, WIDTH, HEIGHT, function()
        lg.draw(straightA, 0, 0)
      end),
      "a failed candidate never disturbs the published generation"
    )
    handleA:release()
    Assert.throws(function()
      handleA:release()
    end, "a released indexed handle draws nothing further")
    handleB:release()
    local handleC = owner:acquire(source, paletteBytes(wordsA()))
    Assert.notNil(handleC, "a new generation acquires after every handle released")
    Assert.equal(
      renderBytes(scope, WIDTH, HEIGHT, function()
        handleC:draw(lg, 0, 0)
      end),
      renderBytes(scope, WIDTH, HEIGHT, function()
        lg.draw(straightA, 0, 0)
      end),
      "a reacquired generation matches after the source outlived its handles"
    )
    handleC:release()
  end)
  love.image.newImageData = realNewImageData
  disposeOnce()
  if not okSteps then
    error(stepFailure, 0)
  end

  local BattleScene = require("libs.hgss.src.presentation.BattleScene")
  local scene = BattleScene.new()
  local colors = {}
  for index = 1, 32 do
    colors[index] = { r = index % 256, g = (index + 10) % 256, b = (index + 20) % 256 }
  end
  scene:installBackground({
    characters = string.rep("\0", 32),
    baseCharacters = string.char(0x12, 0x34, 0x56, 0x78) .. string.rep("\0", 28),
    colorMode = "4bpp",
    map = {
      width = 16,
      height = 8,
      entries = {
        { tile = 0, flipH = false, flipV = false, palette = 0 },
        { tile = 0, flipH = true, flipV = true, palette = 1 },
      },
    },
    palette = { colors = colors },
  })
  local okIndex, indexRaster = pcall(function()
    return scene:introIndexRaster()
  end)
  Assert.isTrue(
    okIndex and type(indexRaster) == "table",
    "the battle scene exposes its immutable intro source indices without composing colors"
  )
  Assert.equal(indexRaster.width, 16, "the intro index raster keeps its width")
  Assert.equal(indexRaster.height, 8, "the intro index raster keeps its height")
  Assert.equal(#indexRaster.pixels, 16 * 8 * 4, "the intro index raster packs one RGBA8 texel per pixel")
  Assert.equal(redOf(indexRaster.pixels, 0), 2, "an unflipped bank-zero texel keeps its effective index")
  Assert.equal(redOf(indexRaster.pixels, 120), 23, "a flipped banked texel keeps its effective index")
  Assert.equal(redOf(indexRaster.pixels, 127), 18, "a flipped banked corner texel keeps its effective index")
  for pixel = 0, 16 * 8 - 1 do
    local _, green, blue, alpha = pixelOf(indexRaster.pixels, pixel)
    Assert.equal(green, 0, "intro index texels carry no composed green")
    Assert.equal(blue, 0, "intro index texels carry no composed blue")
    Assert.equal(alpha, 255, "intro coverage stays opaque under the intro transparency policy")
  end
  Assert.isTrue(
    scene:introIndexRaster() == indexRaster,
    "steady intro reads reuse the cached index raster instead of recomposing"
  )
end

-- A source replaced under the same descriptor label with different
-- indices and coverage acquires beside the live generation: each handle
-- keeps drawing its own bytes, a rejected candidate raises nothing and
-- disturbs neither, and releasing the old generation leaves the new one.
function T.same_label_source_replacement_keeps_both_generations_until_release(scope)
  local Owner = require("game.hgss.src.battle.BattleEncounterPaletteImage")
  local owner = Owner.new({ graphics = love.graphics })
  scope:own({
    release = function()
      owner:dispose()
    end,
  })
  local lg = love.graphics
  local indicesA = indexBytes()
  local indicesB = table.concat({
    string.char(5, 0, 0, 255),
    string.char(0, 0, 0, 0),
    string.char(3, 0, 0, 90),
    string.char(0, 0, 0, 255),
    string.char(7, 0, 0, 0),
    string.char(5, 0, 0, 255),
    string.char(3, 0, 0, 255),
    string.char(9, 0, 0, 255),
  })
  local words = wordsA()
  words[10] = Rgb555.encode(0, 31, 31)
  local referenceA = straightImage(scope, BattleEncounterIndexedRaster.render(indicesA, WIDTH, HEIGHT, words).pixels)
  local referenceB = straightImage(scope, BattleEncounterIndexedRaster.render(indicesB, WIDTH, HEIGHT, words).pixels)
  local function drawn(image)
    return renderBytes(scope, WIDTH, HEIGHT, function()
      lg.draw(image, 0, 0)
    end)
  end
  local function drawnHandle(handle)
    return renderBytes(scope, WIDTH, HEIGHT, function()
      handle:draw(lg, 0, 0)
    end)
  end
  local sourceA = { id = "shared-label", width = WIDTH, height = HEIGHT, pixels = indicesA }
  local sourceB = { id = "shared-label", width = WIDTH, height = HEIGHT, pixels = indicesB }
  local handleA = assert(owner:acquire(sourceA, paletteBytes(words)))
  local handleB, failure = owner:acquire(sourceB, paletteBytes(words))
  Assert.notNil(handleB, "a replaced source acquires beside the live generation: " .. tostring(failure))
  ---@cast handleB -nil
  Assert.equal(drawnHandle(handleA), drawn(referenceA), "the old source keeps drawing its own indices and coverage")
  Assert.equal(drawnHandle(handleB), drawn(referenceB), "the replacement draws its own indices and coverage")
  local rejected, cause =
    owner:acquire({ id = "shared-label", width = WIDTH, height = HEIGHT, pixels = indicesB:reverse() }, "short")
  Assert.isNil(rejected, "a rejected replacement publishes nothing")
  Assert.notNil(cause, "a rejected replacement is diagnosed")
  Assert.equal(drawnHandle(handleA), drawn(referenceA), "a rejected replacement leaves the old generation")
  Assert.equal(drawnHandle(handleB), drawn(referenceB), "a rejected replacement leaves the live replacement")
  handleA:release()
  Assert.equal(drawnHandle(handleB), drawn(referenceB), "releasing the old source keeps the replacement drawable")
  handleB:release()
end

-- The send-out ball flash blends the sampled palette color toward its
-- target and keeps the source's own coverage: a texel sharing a palette
-- slot with an opaque one stays transparent at zero coverage and keeps
-- its partial alpha, exactly like the unflashed coverage sampler.
function T.ball_flash_keeps_indexed_source_coverage(scope)
  local BattlePicturePass = require("libs.hgss.src.presentation.BattlePicturePass")
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local Owner = require("game.hgss.src.battle.BattleEncounterPaletteImage")
  local owner = Owner.new({ graphics = love.graphics })
  scope:own({
    release = function()
      owner:dispose()
    end,
  })
  local size = 16
  local pixels = {}
  for y = 0, size - 1 do
    for x = 0, size - 1 do
      -- Four coverage bands share palette slot 3: opaque, clear,
      -- partial, opaque again.
      local band = math.floor(x / 4)
      local coverage = ({ 255, 0, 128, 255 })[band + 1]
      pixels[#pixels + 1] = string.char(3, 0, 0, coverage)
    end
  end
  local source = { id = "ball-probe", width = size, height = size, pixels = table.concat(pixels) }
  local handle = assert(owner:acquire(source, paletteBytes({ [4] = Rgb555.encode(31, 0, 0) })))
  local pass = scope:own(BattlePicturePass.new(love.graphics))
  local resources = {
    graphics = love.graphics,
    text = {},
    windows = { drawWindow = function() end },
    assets = {
      drawable = function()
        return handle
      end,
      renderPictures = function(_, graphics, pictures)
        return pass:render(graphics, pictures)
      end,
    },
    frameKey = "unused",
    sceneImageKey = "unused",
  }
  ---@param flash integer? source blend coefficient, nil while unflashed
  ---@param visible boolean false renders the pane backdrop alone
  ---@return love.ImageData rendered detail pane
  local function render(flash, visible)
    local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    BattleRenderer.drawPane(resources, {
      battlers = {},
      effectInstances = {},
      slotGeometry = {},
      hudSections = {},
      message = "",
      openingPresentation = {
        playerTrainerVisible = false,
        foeTrainerVisible = false,
        trainerSlides = {},
        terrainSlides = {},
        ballThrow = {
          selector = "ball:POKE_BALL",
          x = 128,
          y = 96,
          drawableKey = "battle-ball:POKE_BALL:0",
          rotation = 0,
          visible = visible,
          paletteFlash = flash,
        },
      },
    }, "detail", {}, { x = 0, y = 0, width = 256, height = 192 })
    love.graphics.setCanvas()
    return scope:own(canvas:newImageData())
  end
  local backdrop = render(nil, false)
  local flashed = render(8, true)
  local TOLERANCE = 4 / 255
  -- The ball draws centered on its anchor: source column zero lands at x = 120.
  local left, top = 120, 88
  local function at(image, column)
    return image:getPixel(left + column, top + 8)
  end
  -- Pure red blended halfway toward white keeps red full while green and
  -- blue rise to the native floor of half the remaining span. Zero
  -- coverage reproduces the backdrop; partial coverage mixes the blended
  -- color over it by its own alpha.
  local blendRed, blendGreen = 1, math.floor(31 * 8 / 16) / 31
  for _, column in ipairs({ 5, 6 }) do
    local fr, fg, fb = at(flashed, column)
    local br, bg, bb = at(backdrop, column)
    Assert.near(fr, br, TOLERANCE, "a zero-coverage texel keeps the backdrop red under the flash")
    Assert.near(fg, bg, TOLERANCE, "a zero-coverage texel keeps the backdrop green under the flash")
    Assert.near(fb, bb, TOLERANCE, "a zero-coverage texel keeps the backdrop blue under the flash")
  end
  local fr, fg = at(flashed, 1)
  Assert.near(fr, blendRed, TOLERANCE, "an opaque texel blends its palette red")
  Assert.near(fg, blendGreen, TOLERANCE, "an opaque texel blends its palette green")
  local alpha = 128 / 255
  local br, bg, bb = at(backdrop, 9)
  local mr, mg, mb = at(flashed, 9)
  local expectedR = br * (1 - alpha) + blendRed * alpha
  local expectedG = bg * (1 - alpha) + blendGreen * alpha
  local expectedB = bb * (1 - alpha) + blendGreen * alpha
  Assert.near(mr, expectedR, TOLERANCE * 2, "a partial texel mixes the blended red by its own coverage")
  Assert.near(mg, expectedG, TOLERANCE * 2, "a partial texel mixes the blended green by its own coverage")
  Assert.near(mb, expectedB, TOLERANCE * 2, "a partial texel mixes the blended blue by its own coverage")
end

return GraphicsSmoke.suite(T)
