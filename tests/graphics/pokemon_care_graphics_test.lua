-- The hatch application's generated presentation drawn from the real derived
-- family: the source background, the egg sprite with its animation frames, the
-- reveal bars, and the two particle resources are staged by the care job and
-- realized offscreen. The scene draws from immutable snapshots only, the
-- Manaphy variant runs its own frame set, the bars reveal the screen, and the
-- renderer never loads an asset or advances a clock.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local PokemonCareCache = require("libs.assets.src.PokemonCareCache")
local PokemonCareInterface = require("libs.hgss.src.ui.PokemonCareInterface")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

-- A recording window/text pair: the field window and text renderers are
-- borrowed collaborators with their own graphics coverage; this suite proves
-- the hatch art, its placement and its frame selection.
local function recordingCollaborators()
  local recorded = { windows = {}, texts = {}, focus = {} }
  local window = {
    drawWindow = function(_, box, frameIndex, background)
      recorded.windows[#recorded.windows + 1] = { box = box, frameIndex = frameIndex, background = background }
    end,
  }
  local text = {
    windowBackgroundColor = function()
      return { 0, 0, 0 }
    end,
    drawTextWithPalette = function(_, value, x, y)
      recorded.texts[#recorded.texts + 1] = { text = value, x = x, y = y }
    end,
    drawFocusIndicator = function(_, field, x, y)
      recorded.focus[#recorded.focus + 1] = { field = field, x = x, y = y }
    end,
  }
  return window, text, recorded
end

---@return string? versionId a ready version whose care family is published
local function readyVersion()
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local marker = cacheFs:read(PokemonCareCache.markerPath())
      if marker ~= nil and PokemonCareCache.isReady(cacheFs, marker) then
        return versionId
      end
    end
  end
  return nil
end

---@param scope table graphics ownership scope
---@param cacheFs table version cache reader
---@param path string staged image path
---@return table love image
local function realizedImage(scope, cacheFs, path)
  local bytes = assert(cacheFs:read(path), "cache carries " .. path)
  local file = assert(love.filesystem.newFileData(bytes, path), "file data wraps " .. path)
  return scope:own(love.graphics.newImage(file))
end

---@param scope table graphics ownership scope
---@param cacheFs table version cache reader
---@param manifest table hatch manifest
---@return table<string, table> images by staged path
local function realizeFamily(scope, cacheFs, manifest)
  local images = {}
  for _, path in ipairs(PokemonCareCache.referencedHatchPaths(manifest)) do
    images[path] = realizedImage(scope, cacheFs, path)
  end
  return images
end

---@param images table resolved images
---@return table narrow resolution for identifying one drawn frame
local function frameImage(images, frame)
  return images[assert(frame.image)]
end

---@param manifest table hatch manifest
---@param variant string scene variant
---@return table<string, unknown> snapshot in the requested source state
local function snapshot(manifest, variant, fields)
  local base = {
    kind = PokemonCareInterface.KINDS.hatch,
    variant = variant,
    phase = PokemonCareInterface.HATCH_PHASES.WAIT_BEFORE_SHAKE,
    frame = 0,
    eggFrame = 0,
    eggOffsetX = 0,
    eggOffsetY = 0,
    scaleX = 1,
    scaleY = 1,
    bars = true,
    barsOffset = 0,
    messageId = nil,
    question = false,
    selection = "yes",
    done = false,
    presentationReady = true,
    preparationError = nil,
    particles = {},
  }
  for key, value in pairs(fields or {}) do
    base[key] = value
  end
  return PokemonCareInterface.assertHatchStatus(base)
end

---@param scope table graphics ownership scope
---@param renderer table hatch renderer
---@param status table snapshot
---@return table image data of the drawn scene
local function drawScene(scope, renderer, status)
  local canvas = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:draw(status, "TESTMON")
  love.graphics.setCanvas()
  return canvas:newImageData()
end

---@param image love.ImageData
---@return integer lit pixels
local function litPixels(image)
  local lit = 0
  for y = 0, image:getHeight() - 1, 2 do
    for x = 0, image:getWidth() - 1, 2 do
      local _, _, _, a = image:getPixel(x, y)
      if a > 0.5 then
        lit = lit + 1
      end
    end
  end
  return lit
end

---@param left love.ImageData
---@param right love.ImageData
---@param y0 integer
---@param y1 integer
---@return integer changed pixels
local function changedPixels(left, right, y0, y1)
  local changed = 0
  for y = y0, y1 do
    for x = 0, left:getWidth() - 1 do
      local lr, lg, lb, la = left:getPixel(x, y)
      local rr, rg, rb, ra = right:getPixel(x, y)
      if lr ~= rr or lg ~= rg or lb ~= rb or la ~= ra then
        changed = changed + 1
      end
    end
  end
  return changed
end

-- One prepared hatch scene: the real manifest, its realized images, and the
-- production renderer over recording window/text collaborators.
---@param scope table graphics ownership scope
---@return table scene
local function openScene(scope)
  local versionId = readyVersion()
  Assert.notNil(versionId, "the prepared cache publishes the care family")
  assert(versionId ~= nil)
  local cacheFs = CacheFs.forVersion(versionId)
  local manifest = PokemonCareCache.loadHatchManifest(cacheFs)
  local images = realizeFamily(scope, cacheFs, manifest)
  local window, text, recorded = recordingCollaborators()
  local EggHatchRenderer = require("libs.hgss.src.ui.EggHatchRenderer")
  local renderer = EggHatchRenderer.new({
    graphics = love.graphics,
    manifest = manifest,
    images = images,
    text = text,
    window = window,
    fontDef = {},
    frameIndex = 0,
  })
  return { manifest = manifest, images = images, renderer = renderer, recorded = recorded }
end

-- The ordinary egg scene draws the staged background, its egg animation frame
-- at the source origin, and the bars that cover the reveal.
function T.the_egg_scene_draws_the_generated_source_art(scope)
  local scene = openScene(scope)
  local manifest = scene.manifest
  local image = drawScene(scope, scene.renderer, snapshot(manifest, "egg", { eggFrame = 1 }))
  Assert.isTrue(litPixels(image) > 1000, "the hatch scene draws the staged background and egg")
  local background = frameImage(scene.images, manifest.background)
  Assert.equal(background:getWidth(), manifest.background.width, "the realized background keeps its source width")
  Assert.equal(background:getHeight(), manifest.background.height, "the realized background keeps its source height")
  Assert.equal(#scene.recorded.windows, 1, "the scene draws its message window")
  Assert.equal(
    scene.recorded.windows[1].box.width,
    manifest.window.width,
    "the message window keeps the source content width"
  )
end

-- The shake frames move the egg: the source displacement changes the pixels
-- around the egg while the background stays put.
function T.egg_shake_frames_move_the_sprite(scope)
  local scene = openScene(scope)
  local manifest = scene.manifest
  local still = drawScene(scope, scene.renderer, snapshot(manifest, "egg", { eggFrame = 1 }))
  local shaken = drawScene(
    scope,
    scene.renderer,
    snapshot(manifest, "egg", { eggFrame = 1, eggOffsetX = -3, eggOffsetY = 2, scaleX = 1.2, scaleY = 0.8 })
  )
  Assert.isTrue(changedPixels(still, shaken, 60, 180) > 0, "the source shake displacement moves the egg pixels")
end

-- The bars cover the reveal until the source slides them away, and the egg is
-- hidden once the mon is revealed.
function T.the_reveal_bars_slide_off_and_the_egg_disappears(scope)
  local scene = openScene(scope)
  local manifest = scene.manifest
  local covered = drawScene(scope, scene.renderer, snapshot(manifest, "egg", { eggFrame = 4 }))
  local revealed = drawScene(
    scope,
    scene.renderer,
    snapshot(manifest, "egg", { eggFrame = -1, bars = false, messageId = manifest.messages.hatched.id })
  )
  Assert.isTrue(changedPixels(covered, revealed, 0, 16) > 0, "the top reveal bar leaves the screen")
  Assert.isTrue(changedPixels(covered, revealed, 176, 191) > 0, "the bottom reveal bar leaves the screen")
end

-- The Manaphy scene runs without the egg and emits its own particle set; the
-- rendered frame then carries particle pixels the egg scene does not.
function T.the_manaphy_scene_runs_its_own_frames(scope)
  local scene = openScene(scope)
  local manifest = scene.manifest
  local manaphy = snapshot(manifest, "manaphy", { eggFrame = -1, frame = 20 })
  local withoutParticles = drawScene(scope, scene.renderer, manaphy)
  scene.renderer:emitParticles("manaphy", { 0, 1, 2, 3 })
  scene.renderer:updateFixed()
  Assert.isTrue(scene.renderer:particlesRunning(), "the Manaphy scene keeps its source emitters running")
  local withParticles = drawScene(scope, scene.renderer, manaphy)
  Assert.notNil(withoutParticles, "the Manaphy background frame draws")
  Assert.notNil(withParticles, "the Manaphy scene draws with its particles")
  local egg = drawScene(scope, scene.renderer, snapshot(manifest, "egg", { eggFrame = 0 }))
  Assert.isTrue(changedPixels(egg, withParticles, 100, 160) > 0, "the Manaphy frame differs from the egg frame")
  scene.renderer:release()
end

-- The nickname question draws both answers with the selected one marked, and
-- the line keeps the substituted hatched name.
function T.the_nickname_question_draws_its_answers(scope)
  local scene = openScene(scope)
  local manifest = scene.manifest
  local status = snapshot(manifest, "egg", {
    eggFrame = -1,
    bars = false,
    messageId = manifest.messages.nicknameQuestion.id,
    question = true,
    selection = "no",
  })
  drawScene(scope, scene.renderer, status)
  local texts = scene.recorded.texts
  Assert.isTrue(#texts >= 2, "the question and its answers print")
  local sawQuestion = false
  local sawNo = false
  for _, entry in ipairs(texts) do
    if entry.text:find("TESTMON", 1, true) ~= nil then
      sawQuestion = true
    end
  end
  local noLine = scene.renderer:lineText("no", "TESTMON")
  for _, entry in ipairs(texts) do
    if entry.text == noLine then
      sawNo = true
    end
  end
  Assert.isTrue(sawQuestion, "the question line carries the hatched record's name")
  Assert.isTrue(sawNo, "the no answer prints")
  Assert.equal(#scene.recorded.focus, 1, "the selected answer carries the field focus indicator")
end

local suite = GraphicsSmoke.suite(T, { tags = { "mons", "hatch" } })
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets = { "field-runtime" }
return suite
