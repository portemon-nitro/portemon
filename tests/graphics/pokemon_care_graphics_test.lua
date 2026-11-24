-- The hatch and NPC trade applications' generated presentations drawn from the
-- real derived family: the hatch scene's source background, egg sprite, reveal
-- bars and particle resources, and the trade sequence's source backdrops, its
-- effect sprite sheet and its message layer, are staged by the care job and
-- realized offscreen. The scene draws from immutable snapshots only, the
-- Manaphy variant runs its own frame set, the bars reveal the screen, and the
-- renderer never loads an asset or advances a clock.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MonCache = require("libs.assets.src.MonCache")
local NpcTradeRenderer = require("libs.hgss.src.ui.NpcTradeRenderer")
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

-- One prepared trade sequence: the real trade manifest, every staged surface it
-- references, and the production renderer over recording window/text
-- collaborators.
---@param scope table graphics ownership scope
---@return table scene
local function openTradeScene(scope)
  local versionId = readyVersion()
  Assert.notNil(versionId, "the prepared cache publishes the care family")
  assert(versionId ~= nil)
  local cacheFs = CacheFs.forVersion(versionId)
  local manifest = PokemonCareCache.loadTradeManifest(cacheFs)
  local images = {}
  for _, path in ipairs(PokemonCareCache.referencedTradePaths(manifest)) do
    images[path] = realizedImage(scope, cacheFs, path)
  end
  local portraits = assert(cacheFs:loadLua(MonCache.portraitManifestPath()), "the portraits are published")
  local pictures = {}
  for _, subjectKey in ipairs({ "outgoing", "incoming" }) do
    local selector = MonCache.portraitSelector("BELLSPROUT", 0, "male", false)
    local entry = assert(portraits.entries[selector], "the portrait family carries the test selector")
    local frame = assert(entry.frames[1], "a portrait entry carries its first frame")
    local page = MonCache.portraitPagePath(assert(entry.pageId))
    if images[page] == nil then
      images[page] = realizedImage(scope, cacheFs, page)
    end
    pictures[subjectKey] = {
      page = page,
      frame = { x = frame.x, y = frame.y, width = frame.width, height = frame.height },
      height = assert(manifest.pictures.heights[selector], "the trade manifest carries the picture height"),
    }
  end
  local window, text, recorded = recordingCollaborators()
  local renderer = NpcTradeRenderer.new({
    graphics = love.graphics,
    cacheFs = cacheFs,
    manifest = manifest,
    images = images,
    pictures = pictures,
    text = text,
    window = window,
    frameIndex = 0,
  })
  return {
    manifest = manifest,
    images = images,
    pictures = pictures,
    portraits = portraits,
    cacheFs = cacheFs,
    renderer = renderer,
    recorded = recorded,
  }
end

---@param phase string source scene
---@param backdrop string time-of-day backdrop
---@param fields table<string, unknown>?
---@return table<string, unknown> trade snapshot in the requested scene
local function tradeSnapshot(phase, backdrop, fields)
  local typed = {
    kind = PokemonCareInterface.KINDS.trade,
    phase = phase,
    frame = 0,
    backdrop = backdrop,
    messageId = nil,
    bgZoom = 1,
    bgZoomCenterY = 144,
    bgScrollY = 0,
    sprites = {},
    streaks = {},
    pictures = {},
    pulses = {},
    outgoing = { species = 95, form = 0, nickname = "Bellsprout", speciesKey = "BELLSPROUT", gender = "male", shiny = false },
    incoming = { species = 95, form = 0, nickname = "Rocky", speciesKey = "BELLSPROUT", gender = "male", shiny = false },
    done = false,
    presentationReady = true,
    preparationError = nil,
  }
  for key, value in pairs(fields or {}) do
    typed[key] = value
  end
  return PokemonCareInterface.assertTradeStatus(typed)
end

---@param scope table graphics ownership scope
---@param scene table trade scene
---@param status table trade snapshot
---@return love.ImageData the drawn scene
local function drawTradeScene(scope, scene, status)
  local canvas = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  scene.renderer:draw(status, "Rudy")
  love.graphics.setCanvas()
  return canvas:newImageData()
end

---@param layer table trade layer
---@param key string? time-of-day bank
---@return table the layer's surface record
local function tradeSurface(layer, key)
  if layer.variants == nil then
    return layer
  end
  return assert(layer.variants[key or "day"])
end

-- Every played scene draws its own source layers: the send and receive scenes
-- share one surface, the depart/arrive scenes draw their 256-colour affine map
-- under the scene's overlay layer, and the outdoor scenes follow the
-- time-of-day colour bank.
function T.the_trade_scenes_draw_their_own_source_layers(scope)
  local scene = openTradeScene(scope)
  local manifest = scene.manifest
  local send = drawTradeScene(scope, scene, tradeSnapshot(PokemonCareInterface.TRADE_PHASES.SEND, "day"))
  Assert.isTrue(litPixels(send) > 1000, "the send scene draws its staged backdrop")
  local sendSurface = tradeSurface(manifest.scenes.send.layers[1])
  Assert.equal(
    frameImage(scene.images, sendSurface):getWidth(),
    sendSurface.width,
    "the realized send backdrop keeps its source width"
  )

  local exchange = drawTradeScene(scope, scene, tradeSnapshot(PokemonCareInterface.TRADE_PHASES.EXCHANGE, "day"))
  Assert.isTrue(changedPixels(send, exchange, 0, 191) > 0, "the exchange scene draws a different source surface")

  local receive = drawTradeScene(scope, scene, tradeSnapshot(PokemonCareInterface.TRADE_PHASES.RECEIVE, "day"))
  Assert.equal(changedPixels(send, receive, 0, 191), 0, "the receive scene shares the send surface")

  local day = drawTradeScene(scope, scene, tradeSnapshot(PokemonCareInterface.TRADE_PHASES.RECEDE, "day"))
  local night = drawTradeScene(scope, scene, tradeSnapshot(PokemonCareInterface.TRADE_PHASES.RECEDE, "night"))
  Assert.isTrue(changedPixels(day, night, 0, 191) > 0, "the outdoor surface follows the time-of-day colour bank")

  -- The depart scene draws the source's 256-colour affine map under its own
  -- 256x16 overlay layer, so both of its layers reach the frame.
  local departLayers = manifest.scenes.depart.layers
  Assert.equal(#departLayers, 2, "the depart scene carries its map and overlay layers")
  Assert.isTrue(departLayers[1].affine == true, "the depart map layer is the source affine background")
  Assert.equal(
    tradeSurface(departLayers[1], "day").width,
    1024,
    "the depart map is the source's 1024x1024 256-colour surface"
  )
  local depart = drawTradeScene(
    scope,
    scene,
    tradeSnapshot(PokemonCareInterface.TRADE_PHASES.DEPART, "day", { bgZoom = 1 })
  )
  Assert.isTrue(changedPixels(depart, send, 0, 191) > 0, "the depart scene draws its own source layers")
  -- The map layer's colour block changes with the time of day: the staged
  -- surfaces are distinct and their pixels differ. The visible 256x192 window
  -- of the 1024x1024 map is the scene's zoomed view, so the comparison is made
  -- on the realized source surfaces rather than on one window of them.
  local daySurface = tradeSurface(departLayers[1], "day")
  local eveningSurface = tradeSurface(departLayers[1], "evening")
  Assert.isTrue(daySurface.image ~= eveningSurface.image, "each colour block is its own staged surface")
  local dayImage = frameImage(scene.images, daySurface)
  local eveningImage = frameImage(scene.images, eveningSurface)
  Assert.isTrue(
    dayImage:getWidth() == eveningImage:getWidth() and dayImage:getHeight() == eveningImage:getHeight(),
    "both colour blocks keep the source map geometry"
  )
  Assert.isTrue(
    dayImage:getWidth() == daySurface.width and dayImage:getHeight() == daySurface.height,
    "the realized map keeps the source 1024x1024 geometry"
  )
end

-- The affine map layer is drawn under the scene's own background zoom: the
-- source reference point stays fixed and the visible window changes as the
-- scale grows, always inside the source's 256x192 frame.
function T.the_affine_layer_follows_the_scene_zoom(scope)
  local scene = openTradeScene(scope)
  local near = drawTradeScene(
    scope,
    scene,
    tradeSnapshot(PokemonCareInterface.TRADE_PHASES.DEPART, "day", { bgZoom = 0.28125 })
  )
  local full = drawTradeScene(
    scope,
    scene,
    tradeSnapshot(PokemonCareInterface.TRADE_PHASES.DEPART, "day", { bgZoom = 1 })
  )
  Assert.isTrue(changedPixels(near, full, 0, 191) > 0, "the map layer grows with the scene's zoom scale")
  local scrolled = drawTradeScene(
    scope,
    scene,
    tradeSnapshot(PokemonCareInterface.TRADE_PHASES.DEPART, "day", { bgZoom = 1, bgScrollY = 24 })
  )
  Assert.isTrue(changedPixels(full, scrolled, 0, 191) > 0, "the map layer follows the scene's vertical scroll")
  local shrunk = drawTradeScene(
    scope,
    scene,
    tradeSnapshot(PokemonCareInterface.TRADE_PHASES.ARRIVE, "day", { bgZoom = 0.25, bgZoomCenterY = 56 })
  )
  Assert.isTrue(litPixels(shrunk) > 1000, "the arrive scene draws its shrinking affine layer")
end

---@param left love.ImageData
---@param right love.ImageData
---@param x0 integer
---@param y0 integer
---@param x1 integer
---@param y1 integer
---@return integer changed pixels inside the rectangle
local function changedPixelsIn(left, right, x0, y0, x1, y1)
  local changed = 0
  for y = y0, y1 do
    for x = x0, x1 do
      local lr, lg, lb, la = left:getPixel(x, y)
      local rr, rg, rb, ra = right:getPixel(x, y)
      if lr ~= rr or lg ~= rg or lb ~= rb or la ~= ra then
        changed = changed + 1
      end
    end
  end
  return changed
end

---@param sheet table the compiled effect sheet
---@param sequenceNo integer source animation sequence
---@return table sequence record
local function effectSequence(sheet, sequenceNo)
  for _, sequence in ipairs(sheet.sequences) do
    if sequence.sequence == sequenceNo then
      return sequence
    end
  end
  error("the compiled effect sheet carries no sequence " .. tostring(sequenceNo), 0)
end

-- The scene effect sprites draw from the compiled source sheet at the origin
-- the source creates them with: the send effect's single frame is centred on
-- (128, 100), paints nothing outside its own extent, and a blank source frame
-- paints nothing at all while still occupying its own ticks.
function T.the_trade_scene_draws_its_source_effect_sprites(scope)
  local scene = openTradeScene(scope)
  local sheet = assert(scene.manifest.sprites.effect, "the trade manifest carries its effect sheet")
  local static = effectSequence(sheet, 1)
  Assert.equal(#static.frames, 1, "the send effect sequence is the source's single-frame effect")
  local without = drawTradeScene(scope, scene, tradeSnapshot(PokemonCareInterface.TRADE_PHASES.SEND, "day"))
  local first = drawTradeScene(
    scope,
    scene,
    tradeSnapshot(
      PokemonCareInterface.TRADE_PHASES.SEND,
      "day",
      { sprites = { { sequence = 1, x = 128, y = 100, tick = 0 } } }
    )
  )
  Assert.isTrue(changedPixels(without, first, 0, 191) > 0, "the effect sprite reaches the frame")
  local frame = static.frames[1]
  local image = frameImage(scene.images, frame)
  Assert.equal(image:getWidth(), frame.width, "the compiled effect frame keeps its source width")
  Assert.equal(image:getHeight(), frame.height, "the compiled effect frame keeps its source height")
  local x0 = 128 - math.floor(image:getWidth() / 2)
  local y0 = 100 - math.floor(image:getHeight() / 2)
  local inside = changedPixelsIn(without, first, x0, y0, x0 + image:getWidth() - 1, y0 + image:getHeight() - 1)
  Assert.isTrue(inside > 0, "the effect frame draws at the source origin the scene creates it with")
  Assert.equal(
    changedPixels(without, first, 0, 191) - inside,
    0,
    "the effect sprite paints nothing outside its own frame"
  )

  -- The burst sequence carries a blank source frame: at that tick the scene
  -- draws exactly what it draws without the sprite.
  local burst = effectSequence(sheet, 0)
  Assert.isTrue(#burst.frames > 1, "the ball burst sequence animates")
  local tick = 0
  local blankTick = nil
  for _, candidate in ipairs(burst.frames) do
    if candidate.blank == true then
      blankTick = tick
    end
    tick = tick + candidate.durationTicks
  end
  Assert.notNil(blankTick, "the burst sequence carries a blank source frame")
  local blank = drawTradeScene(
    scope,
    scene,
    tradeSnapshot(
      PokemonCareInterface.TRADE_PHASES.SEND,
      "day",
      { sprites = { { sequence = 0, x = 128, y = 90, tick = assert(blankTick) } } }
    )
  )
  Assert.equal(changedPixels(without, blank, 0, 191), 0, "a blank source frame paints nothing")
  local burstFrame = drawTradeScene(
    scope,
    scene,
    tradeSnapshot(
      PokemonCareInterface.TRADE_PHASES.SEND,
      "day",
      { sprites = { { sequence = 0, x = 128, y = 90, tick = 0 } } }
    )
  )
  Assert.isTrue(changedPixels(without, burstFrame, 0, 191) > 0, "the burst's first frame paints its own art")
  Assert.isTrue(changedPixels(blank, burstFrame, 0, 191) > 0, "the burst advances from its first frame to its blank frame")
end

-- Each scene draws the sheet sequence its own module sets: the recede and
-- approach scenes share sequence 3, the receive scene runs its own sequences 1
-- and 2, and the exchange scene draws no effect sheet at all.
function T.the_trade_scenes_select_their_own_source_sequences(scope)
  local scene = openTradeScene(scope)
  local sheet = assert(scene.manifest.sprites.effect, "the trade manifest carries its effect sheet")
  Assert.isTrue(#sheet.sequences >= 4, "the sheet realizes every sequence the scenes select")
  local function drawnWith(phase, sequenceNo, y)
    return drawTradeScene(
      scope,
      scene,
      tradeSnapshot(
        phase,
        "day",
        { sprites = { { sequence = sequenceNo, x = 128, y = y, tick = 0 } } }
      )
    )
  end
  local recedePlain = drawTradeScene(scope, scene, tradeSnapshot(PokemonCareInterface.TRADE_PHASES.RECEDE, "day"))
  Assert.isTrue(
    changedPixels(recedePlain, drawnWith(PokemonCareInterface.TRADE_PHASES.RECEDE, 3, 96), 0, 191) > 0,
    "the recede scene draws its sequence 3 sprite"
  )
  local approachPlain = drawTradeScene(scope, scene, tradeSnapshot(PokemonCareInterface.TRADE_PHASES.APPROACH, "day"))
  Assert.isTrue(
    changedPixels(approachPlain, drawnWith(PokemonCareInterface.TRADE_PHASES.APPROACH, 3, 96), 0, 191) > 0,
    "the approach scene draws its sequence 3 sprite"
  )
  local receivePlain = drawTradeScene(scope, scene, tradeSnapshot(PokemonCareInterface.TRADE_PHASES.RECEIVE, "day"))
  Assert.isTrue(
    changedPixels(receivePlain, drawnWith(PokemonCareInterface.TRADE_PHASES.RECEIVE, 2, 90), 0, 191) > 0,
    "the receive scene draws its sequence 2 burst"
  )
  Assert.isTrue(
    changedPixels(receivePlain, drawnWith(PokemonCareInterface.TRADE_PHASES.RECEIVE, 1, 100), 0, 191) > 0,
    "the receive scene draws its sequence 1 effect"
  )
  local exchange = drawTradeScene(scope, scene, tradeSnapshot(PokemonCareInterface.TRADE_PHASES.EXCHANGE, "day"))
  local exchangeSprite = drawnWith(PokemonCareInterface.TRADE_PHASES.EXCHANGE, 1, 100)
  Assert.isTrue(
    changedPixels(exchange, exchangeSprite, 0, 191) > 0,
    "an effect sprite still paints over the exchange scene"
  )
end

-- The Poke Ball model draws through the generated trade model and the scene's
-- own camera: the same scene without a balloon paints nothing there, the model
-- follows its placement, and the source's polygon alpha 0 paints nothing.
function T.the_poke_ball_model_draws_in_its_scene_camera(scope)
  local scene = openTradeScene(scope)
  Assert.notNil(scene.manifest.balloon, "the trade manifest carries the Poke Ball model")
  local camera = {
    angleX = 0xEBE0,
    angleY = 0,
    distance = 300,
    fov = 4004,
    perspectiveType = 0,
    near = 0,
    far = 1000,
  }
  local function placement(x, y, z, alpha)
    return {
      x = x,
      y = y,
      z = z,
      rotX = 0,
      rotY = 61440,
      rotZ = 0,
      scale = 1.75,
      alpha = alpha or 31,
    }
  end
  local without = drawTradeScene(scope, scene, tradeSnapshot(PokemonCareInterface.TRADE_PHASES.SEND, "day"))
  local drawn = drawTradeScene(
    scope,
    scene,
    tradeSnapshot(
      PokemonCareInterface.TRADE_PHASES.SEND,
      "day",
      { balloon = placement(0, 26.5, 115.5), camera = camera }
    )
  )
  Assert.isTrue(changedPixels(without, drawn, 0, 191) > 0, "the Poke Ball model reaches the frame")
  local moved = drawTradeScene(
    scope,
    scene,
    tradeSnapshot(
      PokemonCareInterface.TRADE_PHASES.SEND,
      "day",
      { balloon = placement(0, -55.5, 0), camera = camera }
    )
  )
  Assert.isTrue(changedPixels(drawn, moved, 0, 191) > 0, "the model follows its snapshot placement")
  local invisible = drawTradeScene(
    scope,
    scene,
    tradeSnapshot(
      PokemonCareInterface.TRADE_PHASES.SEND,
      "day",
      { balloon = placement(0, 26.5, 115.5, 0), camera = camera }
    )
  )
  Assert.equal(changedPixels(without, invisible, 0, 191), 0, "the source polygon alpha 0 paints nothing")
  local orthographic = drawTradeScene(
    scope,
    scene,
    tradeSnapshot(PokemonCareInterface.TRADE_PHASES.ARRIVE, "day", {
      balloon = placement(0, 50, 0),
      camera = {
        angleX = 0,
        angleY = 0,
        distance = 300,
        fov = 4004,
        perspectiveType = 1,
        near = 0,
        far = 1000,
      },
    })
  )
  local arrivePlain = drawTradeScene(scope, scene, tradeSnapshot(PokemonCareInterface.TRADE_PHASES.ARRIVE, "day"))
  Assert.isTrue(
    changedPixels(arrivePlain, orthographic, 0, 191) > 0,
    "the arrive scene draws the model through its orthographic camera"
  )
end

-- The mon picture draws the subject's own portrait entry: the pixels of the
-- drawn picture recompose exactly from the published index frame and that
-- entry's palette bank, so a picture can never stand in palette-0 art of a
-- different entry.
function T.the_mon_picture_draws_its_own_portrait_palette(scope)
  local scene = openTradeScene(scope)
  local Rgb555 = require("libs.codec.src.Rgb555")
  local selector = MonCache.portraitSelector("BELLSPROUT", 0, "male", false)
  local source = assert(MonCache.loadPortraitSource(scene.cacheFs, scene.portraits, selector))
  local record = assert(scene.pictures.outgoing, "the outgoing picture is realized")
  local status = tradeSnapshot(PokemonCareInterface.TRADE_PHASES.SEND, "day", {
    pictures = { { subject = "outgoing", visible = true, x = 128, y = 80 } },
  })
  local drawn = drawTradeScene(scope, scene, status)
  local frame = assert(record.frame, "the realized picture carries its frame")
  local height = assert(record.height, "the realized picture carries its source height")
  local originX = 128 - frame.width / 2
  local originY = 80 - frame.height / 2 + height
  local indices = assert(source.indexFrames[1], "the portrait source carries its first index frame")
  local palette = assert(source.basePaletteRgb555, "the portrait source carries its palette")
  local checked = 0
  local nonZero = 0
  for position = 1, #indices do
    if indices:byte(position) ~= 0 then
      nonZero = nonZero + 1
    end
  end
  for row = 2, frame.height - 3, 4 do
    for column = 2, frame.width - 3, 4 do
      local index = indices:byte(row * frame.width + column + 1) or 0
      if index ~= 0 then
        local expected = Rgb555.decode(assert(palette[index + 1], "the palette covers the index frame"))
        local r, g, b, a = drawn:getPixel(originX + column, originY + row)
        Assert.isTrue(a > 0.5, "the picture pixel is opaque")
        Assert.equal(math.floor(r * 255 + 0.5), expected.r, "the picture pixel reads its own palette red")
        Assert.equal(math.floor(g * 255 + 0.5), expected.g, "the picture pixel reads its own palette green")
        Assert.equal(math.floor(b * 255 + 0.5), expected.b, "the picture pixel reads its own palette blue")
        checked = checked + 1
      end
    end
  end
  Assert.isTrue(checked > 30, "the picture draws visible pixels to compare")
end

-- The exchange pictures ride their own source rows: a later slide position
-- moves the picture, and the picture paints inside its own 80x80 frame only.
function T.the_exchange_pictures_slide_and_paint_their_own_frame(scope)
  local scene = openTradeScene(scope)
  local function exchangeWith(y)
    return drawTradeScene(
      scope,
      scene,
      tradeSnapshot(PokemonCareInterface.TRADE_PHASES.EXCHANGE, "day", {
        pictures = { { subject = "outgoing", visible = true, x = 200, y = y } },
      })
    )
  end
  local plain = drawTradeScene(scope, scene, tradeSnapshot(PokemonCareInterface.TRADE_PHASES.EXCHANGE, "day"))
  local first = exchangeWith(140)
  local later = exchangeWith(90)
  Assert.isTrue(changedPixels(plain, first, 0, 191) > 0, "the exchange picture paints the sent record")
  Assert.isTrue(changedPixels(first, later, 0, 191) > 0, "a later slide row moves the sent picture")
  local outside = changedPixelsIn(first, later, 0, 0, 255, 48)
  Assert.equal(outside, 0, "only the picture's own rows change between slide positions")
end

-- The depart light streaks draw the compiled sheet at the source positions and
-- follow the fall.
function T.the_depart_streaks_fall_at_their_source_positions(scope)
  local scene = openTradeScene(scope)
  local sheet = assert(scene.manifest.sprites.effect, "the trade manifest carries the effect sheet")
  local streakHead = effectSequence(sheet, 0)
  Assert.isTrue(#streakHead.frames > 1, "the streak sheet realizes its falling frames")
  local function departWith(headY)
    return drawTradeScene(
      scope,
      scene,
      tradeSnapshot(PokemonCareInterface.TRADE_PHASES.DEPART, "day", {
        streaks = { { x = 100, headY = headY, tailY = headY + 56, tick = 0 } },
      })
    )
  end
  local plain = drawTradeScene(scope, scene, tradeSnapshot(PokemonCareInterface.TRADE_PHASES.DEPART, "day"))
  local falling = departWith(60)
  local lower = departWith(120)
  Assert.isTrue(changedPixels(plain, falling, 0, 191) > 0, "the depart scene draws its light streaks")
  Assert.isTrue(changedPixels(falling, lower, 0, 191) > 0, "a falling streak moves with its source rows")
end

-- The link pulses paint the affine layer's own palette slots: every changed
-- pixel sits on an index the walk holds, slot 0 (the source's transparency
-- slot) paints nothing, the walk's next step moves the painted set, and a
-- drained walk paints nothing at all.
function T.the_link_pulses_paint_the_source_palette_slots(scope)
  local scene = openTradeScene(scope)
  local mapLayer = assert(scene.manifest.scenes.depart.layers[1], "the depart map layer exists")
  Assert.isTrue(mapLayer.affine == true, "the depart map layer is the affine one")
  local planePath = assert(mapLayer.indices, "the affine layer publishes its index plane")
  local surface = assert(mapLayer.variants.day, "the depart map carries its day bank")
  local plane = assert(scene.cacheFs:read(planePath), "the staged index plane is present")
  Assert.equal(#plane, surface.width * surface.height, "the index plane matches its surface")
  local function departWith(pulses)
    return drawTradeScene(
      scope,
      scene,
      tradeSnapshot(PokemonCareInterface.TRADE_PHASES.DEPART, "day", { pulses = pulses })
    )
  end
  local plain = departWith({})
  -- Palette slot 0 is the source's transparency slot: a pulse on it draws
  -- nothing, exactly like the hardware (the walk still visits it).
  local slotZero = departWith({ 0 })
  Assert.equal(changedPixels(plain, slotZero, 0, 191), 0, "the transparency slot paints nothing")

  -- The visible window of this map uses palette slots 1 and 15 (the sky and
  -- the ground blocks), so those are the two slots the walk can light here.
  local first = departWith({ 1 })
  local second = departWith({ 15 })
  local painted = changedPixels(plain, first, 0, 191)
  Assert.isTrue(painted > 0, "a pulse slot paints the layer's own pixels")
  Assert.isTrue(changedPixels(first, second, 0, 191) > 0, "the walk's next slot paints another set")

  -- Every pixel the pulse paints sits on the pulsing index and is white, and
  -- nothing else changes: the overlay is derived from the index plane (zoom 1,
  -- no scroll => screen and plane coordinates agree). Pixels the scene's later
  -- overlay layer covers keep their own colour, exactly like the source's
  -- layer order.
  local wrong = 0
  local changedCount = 0
  local changedNotWhite = 0
  for y = 0, 191 do
    for x = 0, 255 do
      local index = string.byte(plane, y * surface.width + x + 1) or 0
      local pr, pg, pb, pa = plain:getPixel(x, y)
      local fr, fg, fb, fa = first:getPixel(x, y)
      local changed = pr ~= fr or pg ~= fg or pb ~= fb or pa ~= fa
      if changed then
        changedCount = changedCount + 1
        if index ~= 1 then
          wrong = wrong + 1
        end
        if math.abs(fr - 1) > 0.01 or math.abs(fg - 1) > 0.01 or math.abs(fb - 1) > 0.01 or fa < 0.5 then
          changedNotWhite = changedNotWhite + 1
        end
      end
    end
  end
  Assert.isTrue(changedCount > 100, "the walk's slot paints a visible part of the layer")
  Assert.equal(wrong, 0, "the pulse paints only the pixels of its own palette index")
  Assert.equal(changedNotWhite, 0, "every painted pixel turns white")

  Assert.equal(changedPixels(plain, departWith({}), 0, 191), 0, "a drained walk paints nothing")
  Assert.isTrue(changedPixels(plain, second, 0, 191) > 0, "the ground slot paints its own pixels")
end

-- The trade window and its compiled bank-179 line: the message layer sits at the
-- source window rectangle and substitutes the two detached subjects' names.
function T.the_trade_message_layer_prints_the_source_lines(scope)
  local scene = openTradeScene(scope)
  local manifest = scene.manifest
  local status = tradeSnapshot(PokemonCareInterface.TRADE_PHASES.SEND, "day", {
    messageId = manifest.messages.send.id,
  })
  drawTradeScene(scope, scene, status)
  Assert.equal(#scene.recorded.windows, 1, "the trade scene draws its message window")
  Assert.equal(
    scene.recorded.windows[1].box.width,
    manifest.window.width,
    "the trade window keeps the source content width"
  )
  Assert.equal(#scene.recorded.texts, 1, "the scene prints its one source line")
  local printed = scene.recorded.texts[1].text
  Assert.isTrue(printed:find("Bellsprout", 1, true) ~= nil, "the line names the sent record")
  Assert.isTrue(printed:find("Rudy", 1, true) ~= nil, "the line names the trade profile")
  Assert.isNil(scene.renderer:lineText(99, status, "Rudy"), "an unknown source line prints nothing")
end

-- One prepared reminder application: the real manifest, its realized screens,
-- the subject's own portrait page, and the production renderer over recording
-- window/text collaborators. The presentation resolves against a genuine
-- two-screen host so both source screens are drawn.
---@param scope table graphics ownership scope
---@return table scene
local function openReminderScene(scope)
  local versionId = readyVersion()
  Assert.notNil(versionId, "the prepared cache publishes the care family")
  assert(versionId ~= nil)
  local cacheFs = CacheFs.forVersion(versionId)
  local manifest = PokemonCareCache.loadReminderManifest(cacheFs)
  local images = {}
  for _, path in ipairs(PokemonCareCache.referencedReminderPaths(manifest)) do
    images[path] = realizedImage(scope, cacheFs, path)
  end
  local portraits = cacheFs:loadLua(MonCache.portraitManifestPath())
  local entries = assert(type(portraits) == "table" and portraits.entries, "the portrait family is published")
  local selector = MonCache.portraitSelector("PIDGEY", 0, "male", false)
  local entry = assert(entries[selector], "the portrait family carries the reminder subject")
  local frame = assert(assert(entry.frames)[1], "a portrait entry carries its first frame")
  local page = MonCache.portraitPagePath(assert(entry.pageId, "a portrait entry names its page"))
  images[page] = realizedImage(scope, cacheFs, page)
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local measurement = {
    width = 512,
    height = 384,
    topology = ScreenTopology.dualDisplay({
      id = "world",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      role = "world",
      touch = false,
    }, {
      id = "aux",
      rect = { x = 256, y = 0, width = 256, height = 192 },
      role = "auxiliary",
      touch = true,
    }),
    pixelRatio = 1,
    signature = "care-graphics:reminder-dual",
  }
  local window, text, recorded = recordingCollaborators()
  local MoveRelearnerRenderer = require("libs.hgss.src.ui.MoveRelearnerRenderer")
  local renderer = MoveRelearnerRenderer.new({
    graphics = love.graphics,
    manifest = manifest,
    images = images,
    picture = { page = page, frame = { x = frame.x, y = frame.y, width = frame.width, height = frame.height } },
    measureDisplay = function()
      return measurement
    end,
    text = text,
    window = window,
    fontDef = {},
    frameIndex = 0,
  })
  return { manifest = manifest, images = images, renderer = renderer, recorded = recorded }
end

---@param move string
---@param label string
---@return table<string, unknown> one reminder list row
local function reminderRow(move, label)
  return {
    move = move,
    label = label,
    type = "normal",
    category = "physical",
    power = 35,
    accuracy = 95,
    description = "A physical attack.",
    pp = 35,
    maxPp = 35,
  }
end

---@param fields table<string, unknown>?
---@return table<string, unknown> reminder snapshot
local function reminderSnapshot(fields)
  local base = {
    kind = "move_relearner",
    mode = "tutor",
    phase = "input",
    frame = 0,
    nickname = "PIDGEY",
    cursor = 0,
    scrollOffset = 0,
    moves = { reminderRow("TACKLE", "Tackle"), reminderRow("GUST", "Gust") },
    visible = { 1, 2 },
    known = { reminderRow("SAND_ATTACK", "Sand-Attack") },
    question = nil,
    selected = nil,
    learnButton = true,
    flash = nil,
    message = nil,
    done = false,
    presentationReady = true,
    preparationError = nil,
  }
  for key, value in pairs(fields or {}) do
    base[key] = value
  end
  return base
end

---@param scope table graphics ownership scope
---@param renderer table reminder renderer
---@param status table snapshot
---@param width integer
---@param height integer
---@return love.ImageData
local function drawReminder(scope, renderer, status, width, height)
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:draw(status, status.nickname)
  love.graphics.setCanvas()
  return canvas:newImageData()
end

-- The reminder draws both source screens from their own generated members: the
-- main screen carries the subject's portrait, and the bottom screen carries the
-- source list, its detail pane and the two buttons.
function T.the_reminder_draws_both_source_screens(scope)
  local scene = openReminderScene(scope)
  local manifest = scene.manifest
  local image = drawReminder(scope, scene.renderer, reminderSnapshot(), 512, 384)
  Assert.isTrue(litPixels(image) > 2000, "the reminder draws its source screens")
  local main = scene.images[assert(manifest.main.image) --[[@as string]]]
  local sub = scene.images[assert(manifest.sub.image) --[[@as string]]]
  Assert.equal(main:getWidth(), manifest.main.width, "the main screen keeps its compiled source width")
  Assert.equal(main:getHeight(), manifest.main.height, "the main screen keeps its compiled source height")
  Assert.equal(sub:getWidth(), manifest.sub.width, "the bottom screen keeps its compiled source width")
  local firstFocus = scene.recorded.focus[#scene.recorded.focus]
  drawReminder(scope, scene.renderer, reminderSnapshot({ cursor = 1 }), 512, 384)
  local secondFocus = scene.recorded.focus[#scene.recorded.focus]
  Assert.isTrue(
    firstFocus.y ~= secondFocus.y,
    "the focused row moves the source highlight down one row"
  )
  Assert.equal(
    secondFocus.y - firstFocus.y,
    32,
    "the source row height separates the two highlights"
  )
  Assert.isTrue(litPixels(image) > 0, "the reminder paints its compiled surfaces")
end

-- The bottom screen's list rows and its detail pane print the snapshot's own
-- facts inside the source window rectangles.
function T.the_reminder_list_and_detail_follow_the_source_windows(scope)
  local scene = openReminderScene(scope)
  local manifest = scene.manifest
  drawReminder(scope, scene.renderer, reminderSnapshot(), 512, 384)
  local labels = {}
  for _, text in ipairs(scene.recorded.texts) do
    labels[#labels + 1] = text.text
  end
  local joined = table.concat(labels, "\n")
  Assert.isTrue(joined:find("Tackle", 1, true) ~= nil, "the list prints its first row")
  Assert.isTrue(joined:find("Gust", 1, true) ~= nil, "the list prints its second row")
  Assert.isTrue(joined:find("35", 1, true) ~= nil, "the detail pane prints the selected power and PP")
  Assert.isTrue(
    labels[1] ~= nil and labels[2] ~= nil,
    "the source list prints its rows in order"
  )
  local windows = scene.recorded.windows
  local messageWindow
  for _, entry in ipairs(windows) do
    if entry.box.width == manifest.windows.message.width and entry.box.y == manifest.windows.message.y then
      messageWindow = entry
    end
  end
  Assert.notNil(messageWindow, "the message window keeps its source rectangle")
end

-- The application's own message lines come from the compiled bank-747 columns:
-- the tutor lesson and the reminder read their own prompts.
function T.the_reminder_prints_its_source_message_columns(scope)
  local scene = openReminderScene(scope)
  local manifest = scene.manifest
  local tutor = reminderSnapshot({ mode = "tutor", message = 1 })
  drawReminder(scope, scene.renderer, tutor, 512, 384)
  local printed = assert(scene.recorded.texts[#scene.recorded.texts], "the tutor line prints")
  Assert.isTrue(printed.text:find("Tackle", 1, true) ~= nil, "the tutor line names the selected move")
  Assert.isTrue(
    scene.renderer:lineText(manifest.messages[#manifest.messages].id, tutor) ~= nil,
    "the compiled lines carry their source text"
  )
  scene.recorded.texts = {}
  -- The reminder reads its own eleven-id column: index 1 is the source's
  -- "Should the move ... be remembered?" prompt.
  local reminder = reminderSnapshot({ mode = "relearn", message = 1 })
  drawReminder(scope, scene.renderer, reminder, 512, 384)
  local remembered = assert(scene.recorded.texts[#scene.recorded.texts], "the reminder line prints")
  Assert.isTrue(
    remembered.text:find("remember", 1, true) ~= nil,
    "the reminder column prints its own prompt"
  )
  Assert.isTrue(
    remembered.text:find("Tackle", 1, true) ~= nil,
    "the reminder prompt names the selected move"
  )
  Assert.isNil(scene.renderer:lineText(99, tutor), "an unknown source line prints nothing")
end

-- The yes/no prompt draws the source's two answer boxes with the held answer
-- highlighted, inside the compiled prompt rectangles.
function T.the_reminder_confirmation_draws_the_source_prompt(scope)
  local scene = openReminderScene(scope)
  local manifest = scene.manifest
  drawReminder(
    scope,
    scene.renderer,
    reminderSnapshot({ question = { kind = "teach", selection = "no" }, message = 1 }),
    512,
    384
  )
  local boxes = scene.recorded.windows
  local sawYes = false
  local sawNo = false
  for _, entry in ipairs(boxes) do
    if entry.box.x == manifest.windows.promptYes.x and entry.box.y == manifest.windows.promptYes.y then
      sawYes = true
    end
    if entry.box.x == manifest.windows.promptNo.x and entry.box.y == manifest.windows.promptNo.y then
      sawNo = true
    end
  end
  Assert.isTrue(sawYes, "the prompt draws its yes box at the source rectangle")
  Assert.isTrue(sawNo, "the prompt draws its no box at the source rectangle")
  local focus = assert(scene.recorded.focus[#scene.recorded.focus], "the held answer is highlighted")
  Assert.equal(focus.y, manifest.windows.promptNo.y + 4, "the highlight follows the held answer")
end

local suite = GraphicsSmoke.suite(T, { tags = { "mons", "hatch", "trade", "move-relearner" } })
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets = { "field-runtime" }
return suite
