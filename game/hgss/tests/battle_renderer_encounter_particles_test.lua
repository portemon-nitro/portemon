-- The encounter terrain particles draw over the palette-faded main scene,
-- untinted by its per-plane fades, and the move particle systems draw in
-- the detail pane, from the live systems the screen publishes in its view.

local Assert = require("tests.support.Assert")
local BattleEncounterParticles = require("game.hgss.src.battle.BattleEncounterParticles")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
local Fixture = require("tests.support.BattleEncounterParticlesFixture")
local FakeGraphics = require("tests.support.FakeGraphics")

local T = {}

local function recordingGraphics(log)
  local graphics = {}
  function graphics.getColor()
    return 1, 1, 1, 1
  end
  function graphics.setColor() end
  function graphics.transformPoint(x, y)
    return x, y
  end
  function graphics.push() end
  function graphics.pop() end
  function graphics.intersectScissor() end
  function graphics.newQuad()
    return {}
  end
  function graphics.rectangle(mode, x, y, w, h)
    log[#log + 1] = { kind = "rectangle", mode = mode, x = x, y = y, w = w, h = h }
  end
  function graphics.draw(image, quad, x, y)
    if type(quad) == "number" then
      quad, x, y = nil, quad, x
    end
    log[#log + 1] = { kind = "draw", image = image, quad = quad, x = x, y = y }
  end
  return graphics
end

---@param graphics table<string, unknown> injected host graphics
---@param view table<string, unknown> internal semantic snapshot
---@param scene table<string, unknown>? staged scene drawable, nil while unavailable
local function drawDetail(graphics, view, scene)
  local palette = {}
  for index = 0, 15 do
    palette[index + 1] = { r = index, g = index, b = index }
  end
  view.battlers = {}
  view.effectInstances = {}
  view.hudPatchSpans = {}
  view.message = ""
  view.textPalettes = { narration = { colors = palette } }
  BattleRenderer.drawPane({
    graphics = graphics,
    text = { drawTextForRole = function() end },
    windows = { drawWindow = function() end },
    assets = {
      drawable = function(_, key)
        return (view.drawables ~= nil and view.drawables[key]) or scene
      end,
    },
    frameKey = "default",
  }, view, "detail", {})
end

local function runningSystems()
  local sets = Fixture.sets("grass/day/forest")
  local images = {}
  for index, set in ipairs(sets) do
    for _, texture in ipairs(set.textures) do
      images[index] = images[index]
        or {
          getWidth = function()
            return 32
          end,
          getHeight = function()
            return 32
          end,
        }
      texture.drawable = images[index]
    end
  end
  local owner = BattleEncounterParticles.new()
  for frame = 1, 8 do
    owner:step(frame, sets)
  end
  return owner:systems(), images
end

function T.live_particles_draw_over_the_palette_faded_scene()
  local idle = {}
  drawDetail(recordingGraphics(idle), { encounterParticleSystems = {} })
  for _, entry in ipairs(idle) do
    Assert.isTrue(entry.kind ~= "draw", "an idle encounter draws no particle quads")
  end
  local systems, images = runningSystems()
  local scene = {}
  local log = {}
  drawDetail(recordingGraphics(log), {
    encounterParticleSystems = systems,
    openingPresentation = {
      playerTrainerVisible = false,
      foeTrainerVisible = false,
      encounterFlash = { color = "white", coefficient = 8, mainBgMask = 0xF3FF, mainObjMask = 0x3FFF },
    },
  }, scene)
  local sceneDraw, firstParticle = nil, nil
  for index, entry in ipairs(log) do
    if entry.kind == "draw" and entry.image == scene then
      sceneDraw = index
    elseif entry.kind == "draw" and entry.image == images[1] and firstParticle == nil then
      firstParticle = index
    end
  end
  Assert.notNil(sceneDraw, "the palette-faded scene stages under the encounter fade")
  Assert.notNil(firstParticle, "live particles draw their staged texture")
  Assert.isTrue(firstParticle > (sceneDraw or 0), "particles draw over the faded scene, untinted by it")
  for _, entry in ipairs(log) do
    Assert.isTrue(entry.kind ~= "rectangle", "no fullscreen wash covers the palette-faded scene")
  end
end

function T.move_particle_systems_draw_their_textures_in_the_detail_pane()
  local SplParticleSimulation = require("libs.hgss.src.presentation.SplParticleSimulation")
  local BattleParticleLeaseFixture = require("tests.support.BattleParticleLeaseFixture")
  local simulation = SplParticleSimulation.new(0, 0)
  local record = BattleParticleLeaseFixture.payload(1).emitters[1]
  SplParticleSimulation.addEmitter(simulation, 0, nil, record)
  SplParticleSimulation.advance(simulation)
  local image = {
    getWidth = function()
      return 8
    end,
    getHeight = function()
      return 8
    end,
  }
  local log = {}
  drawDetail(
    recordingGraphics(log),
    { moveParticleSystems = { { simulation = simulation, textures = { [0] = image } } } }
  )
  local drawn = 0
  for _, entry in ipairs(log) do
    if entry.kind == "draw" and entry.image == image then
      drawn = drawn + 1
    end
  end
  Assert.isTrue(drawn >= 1, "a live move particle draws its staged texture")
end

function T.evolution_panes_draw_staged_layers_pictures_window_and_live_particles()
  local SplParticleSimulation = require("libs.hgss.src.presentation.SplParticleSimulation")
  local BattleParticleLeaseFixture = require("tests.support.BattleParticleLeaseFixture")
  local simulation = SplParticleSimulation.new(0, 0)
  local record = BattleParticleLeaseFixture.payload(1).emitters[1]
  SplParticleSimulation.addEmitter(simulation, 0, nil, record)
  SplParticleSimulation.advance(simulation)

  local function image(width, height)
    return {
      width = width,
      height = height,
      getDimensions = function(self)
        return self.width, self.height
      end,
      getWidth = function(self)
        return self.width
      end,
      getHeight = function(self)
        return self.height
      end,
    }
  end
  local mainBg, subBg, menuBg = image(256, 192), image(256, 192), image(256, 192)
  local oldFrame0, oldFrame1 = image(80, 80), image(80, 80)
  local newFrame = image(80, 80)
  local oldPortrait = { frames = { oldFrame0, oldFrame1 } }
  local newPortrait = { frames = { newFrame } }
  local particleTexture = image(8, 8)
  local cursorImage = image(8, 8)
  local art = {
    ["battle:evolution:main"] = mainBg,
    ["battle:evolution:sub"] = subBg,
    ["battle:evolution:menu"] = menuBg,
    ["battle:evolution-cursor:idle:0"] = cursorImage,
    ["mon:old"] = oldPortrait,
    ["mon:new"] = newPortrait,
  }
  local requested, windows, menuText, summaryPanes = {}, {}, {}, {}
  local graphics = FakeGraphics.new()
  local resources = {
    graphics = graphics,
    assets = {
      drawable = function(_, key)
        requested[#requested + 1] = key
        return art[key]
      end,
    },
    windows = {
      drawWindow = function(box)
        windows[#windows + 1] = box
      end,
    },
    text = {
      drawTextForRole = function(role, content, x, y, palette)
        menuText[#menuText + 1] = { role = role, content = content, x = x, y = y, palette = palette }
      end,
    },
    summaryRenderer = {
      drawPane = function(_, status, pane, bundle)
        summaryPanes[#summaryPanes + 1] = { status = status, pane = pane, bundle = bundle }
      end,
    },
    frameKey = "user_frame",
  }
  local evolution = {
    kind = "evolution",
    mode = "child",
    childView = {
      kind = "evolution",
      presentation = {
        assetsReady = true,
        phase = "learn",
        menuTextPalette = {
          { r = 0, g = 0, b = 0 },
          { r = 10, g = 20, b = 30 },
          { r = 40, g = 50, b = 60 },
        },
        pokepicSelectors = { old = "old", new = "new" },
        presentation = {
          window = { left = 0, top = 40, right = 255, bottom = 120 },
          pictureCenter = { x = 128, y = 80 },
          oldPictureScale = 128,
          newPictureScale = 256,
          oldPictureFrame = 1,
          oldPictureXOffset = 4,
          newPictureFrame = 0,
          particleSystems = { { simulation = simulation, textures = { [0] = particleTexture } } },
        },
      },
    },
  }

  BattleRenderer.drawPane(resources, evolution, "detail", {}, {})
  Assert.deepEqual(
    graphics.scissorIntersections[1].requested,
    { 0, 40, 256, 80 },
    "evolution Pokepics and particles use the moving retail window"
  )
  Assert.isTrue(
    graphics.draws[1].image == mainBg,
    "the source BG2 gradient spans the main display outside the moving OBJ window"
  )
  local pictures = {}
  local particleDrawn = false
  for _, draw in ipairs(graphics.draws) do
    if draw.image == oldFrame0 or draw.image == oldFrame1 or draw.image == newFrame then
      pictures[draw.image] = draw
    elseif draw.image == particleTexture then
      particleDrawn = true
    end
  end
  Assert.equal(pictures[oldFrame1].x, 132, "the old portrait uses its source animation offset")
  Assert.equal(pictures[oldFrame1].y, 80, "the old portrait uses the retail y center")
  Assert.equal(pictures[oldFrame1].sx, 0.5, "the old portrait applies its affine scale")
  Assert.equal(pictures[newFrame].x, 128, "the new portrait uses the retail x center")
  Assert.equal(pictures[newFrame].y, 80, "the new portrait uses the retail y center")
  Assert.equal(pictures[newFrame].sx, 1, "the new portrait applies its affine scale")
  Assert.isTrue(pictures[oldFrame0] == nil, "the old portrait selects the live source animation frame")
  Assert.isTrue(particleDrawn, "the live SPL system draws over the main evolution scene")
  Assert.deepEqual(
    windows[1],
    { x = 16, y = 152, width = 216, height = 32 },
    "the evolution scene draws its retail message window"
  )

  BattleRenderer.drawPane(resources, evolution, "interaction", {}, {})
  local requestedSubBackground = false
  for _, key in ipairs(requested) do
    requestedSubBackground = requestedSubBackground or key == "battle:evolution:sub"
  end
  Assert.isTrue(requestedSubBackground, "the lower pane resolves its sub-screen art")

  evolution.childView.presentation.learnMenu = {
    kind = "delete",
    focus = 0,
    topText = "Forget a move!",
    bottomText = "Keep old moves!",
    cursor = {
      role = "idle",
      sourceFrame = 0,
      rasterOffset = { x = -4, y = -4 },
      position = { x = 128, y = 72 },
    },
  }
  BattleRenderer.drawPane(resources, evolution, "interaction", {}, {})
  Assert.equal(requested[#requested - 1], "battle:evolution:menu", "the learn phase resolves its lower menu art")
  Assert.deepEqual(menuText, {
    {
      role = "menu",
      content = "Forget a move!",
      x = 24,
      y = 64,
      palette = {
        foreground = { r = 10, g = 20, b = 30 },
        shadow = { r = 40, g = 50, b = 60 },
        background = { r = 0, g = 0, b = 0, a = 0 },
      },
    },
    {
      role = "menu",
      content = "Keep old moves!",
      x = 24,
      y = 112,
      palette = {
        foreground = { r = 10, g = 20, b = 30 },
        shadow = { r = 40, g = 50, b = 60 },
        background = { r = 0, g = 0, b = 0, a = 0 },
      },
    },
  }, "the evolution menu uses the source window positions and ordered labels")
  Assert.equal(
    requested[#requested],
    "battle:evolution-cursor:idle:0",
    "the source cursor frame is selected for the focused option"
  )
  local cursorDraw = nil
  for _, draw in ipairs(graphics.draws) do
    if draw.image == cursorImage then
      cursorDraw = draw
    end
  end
  Assert.equal(cursorDraw.x, 124, "the cursor uses its source raster x origin")
  Assert.equal(cursorDraw.y, 68, "the cursor uses its source raster y origin")

  evolution.childView.presentation.picturePaletteFade = { color = "white", coefficient = 8 }
  evolution.childView.presentation.scenePaletteFade = { color = "black", coefficient = 4 }
  BattleRenderer.drawPane(resources, evolution, "detail", {}, {})
  local fadedPortrait = nil
  for _, draw in ipairs(graphics.draws) do
    if draw.image == oldFrame1 and draw.color[1] == 1 and draw.color[2] == 1 and draw.color[3] == 1 then
      fadedPortrait = draw
    end
  end
  Assert.deepEqual(
    fadedPortrait.color,
    { 1, 1, 1, 0.5 },
    "the source white Pokepic fade overlays the old picture at its current coefficient"
  )
  local sceneFade = graphics.rectangles[#graphics.rectangles]
  Assert.deepEqual(
    { sceneFade.x, sceneFade.y, sceneFade.w, sceneFade.h, sceneFade.color },
    { 0, 0, 256, 192, { 0, 0, 0, 0.25 } },
    "the source scene palette fade covers both screens with its current black coefficient"
  )

  evolution.childView.presentation.phase = "summary"
  evolution.childView.presentation.summaryStatus = { preparationState = "ready", resources = { id = "bundle" } }
  BattleRenderer.drawPane(resources, evolution, "detail", {}, {})
  BattleRenderer.drawPane(resources, evolution, "interaction", {}, {})
  Assert.deepEqual(
    { summaryPanes[1].pane, summaryPanes[2].pane },
    { "main", "sub" },
    "mode-2 move replacement renders the native Summary panes"
  )
end

function T.encounter_particles_draw_pooled_leases_without_raw_draws()
  local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local sets = Fixture.sets("grass/day/forest")
  local sources, leases = {}, {}
  for _, set in ipairs(sets) do
    for _, texture in ipairs(set.textures) do
      local source = {}
      function source.setFilter() end
      local palette = {}
      function palette.setFilter() end
      function palette.getWidth()
        return 4
      end
      -- Production leases expose only width/height/drawQuad: no raw
      -- getWidth/getHeight/setWrap for shared drawing to misuse.
      local lease = setmetatable({
        image = source,
        palette = palette,
        kind = "r8",
        width = texture.width,
        height = texture.height,
      }, ImageAssetPool.Lease)
      texture.drawable = lease
      sources[#sources + 1] = source
      leases[#leases + 1] = lease
    end
  end
  local owner = BattleEncounterParticles.new()
  for frame = 1, 8 do
    owner:step(frame, sets)
  end
  local graphics = FakeGraphics.new()
  drawDetail(graphics, {
    encounterParticleSystems = owner:systems(),
    openingPresentation = {
      playerTrainerVisible = false,
      foeTrainerVisible = false,
      encounterFlash = { color = "white", coefficient = 8 },
    },
  })
  Assert.isTrue(#graphics.draws >= 1, "live pooled particles draw")
  for _, draw in ipairs(graphics.draws) do
    for _, lease in ipairs(leases) do
      Assert.isTrue(draw.image ~= lease, "shared drawing never draws a lease as a raw image")
    end
  end
  local pooled = 0
  for _, draw in ipairs(graphics.draws) do
    for _, source in ipairs(sources) do
      if draw.image == source then
        pooled = pooled + 1
        Assert.equal(draw.quad.w, 32, "the pooled quad spans its lease width")
        Assert.equal(draw.quad.imgW, 32, "the pooled quad keeps its source reference width")
      end
    end
  end
  Assert.isTrue(pooled >= 1, "pooled index images draw through their palette shader")
  local paletteBound = false
  for _, shader in ipairs(graphics.shaders) do
    for _, send in ipairs(shader.sends) do
      if send.name == "u_usePalette" and send.value == true then
        paletteBound = true
      end
    end
  end
  Assert.isTrue(paletteBound, "an indexed lease enables palette sampling")
  Assert.isTrue(graphics.getShader() == nil, "particle drawing restores the caller shader")
end

---@param graphics table<string, unknown> injected host graphics
---@param view table<string, unknown> internal semantic snapshot
---@param scene table<string, unknown>? staged scene drawable, nil while unavailable
---@param Content table<string, unknown>? compact viewport content carrying the scene clip
local function drawCompactPane(graphics, view, scene, content)
  local palette = {}
  for index = 0, 15 do
    palette[index + 1] = { r = index, g = index, b = index }
  end
  view.battlers = {}
  view.effectInstances = {}
  view.hudPatchSpans = {}
  view.message = ""
  view.textPalettes = { narration = { colors = palette } }
  BattleRenderer.drawPane({
    graphics = graphics,
    text = { drawTextForRole = function() end },
    windows = { drawWindow = function() end },
    assets = {
      drawable = function(_, key)
        return (view.drawables ~= nil and view.drawables[key]) or scene
      end,
    },
    frameKey = "default",
  }, view, "compact", content or {})
end

---@param log table[] recorded draw log under inspection
---@param images table<string, unknown>[] staged images under inspection
---@return table[] draws carrying one of the staged images
local function drawsOfImages(log, images)
  local wanted = {}
  for _, image in ipairs(images) do
    wanted[image] = true
  end
  local found = {}
  for _, entry in ipairs(log) do
    if entry.kind == "draw" and wanted[entry.image] == true then
      found[#found + 1] = entry
    end
  end
  return found
end

-- The compact single-pane viewport presents the same source intro layers
-- as the detail battlefield: terrain slides, trainer pictures and the
-- live encounter particle systems draw from the same staged snapshot at
-- the native main-screen origin, subject only to the compact clip.
function T.compact_pane_presents_live_grass_burst_over_its_clipped_scene()
  local systems, images = runningSystems()
  local moveSystems, moveImages = runningSystems()
  local ballSystems, ballImages = runningSystems()
  local sceneImage = {}
  local trainerImage = {}
  local playerTerrain = {}
  local foeTerrain = {}
  local view = {
    encounterParticleSystems = systems,
    moveParticleSystems = moveSystems,
    ballParticleSystems = ballSystems,
    introScene = sceneImage,
    terrainSprites = {
      player = { drawable = playerTerrain, origin = { x = 0, y = 0 } },
      foe = { drawable = foeTerrain, origin = { x = 0, y = 0 } },
    },
    drawables = {
      ["trainer:back:PKMN_TRAINER_ETHAN"] = trainerImage,
    },
    playerTrainer = { classKey = "PKMN_TRAINER_ETHAN" },
    openingPresentation = {
      playerTrainerVisible = true,
      foeTrainerVisible = false,
      terrainSlides = {
        { role = "player", visible = true, x = 10, y = 100 },
        { role = "foe", visible = true, x = 200, y = 40 },
      },
      encounterFlash = { color = "white", coefficient = 8, mainBgMask = 0xF3FF, mainObjMask = 0x3FFF },
    },
  }
  local detailGraphics = FakeGraphics.new()
  drawDetail(detailGraphics, view, sceneImage)
  Assert.isTrue(#drawsOfImages(detailGraphics.draws, { sceneImage }) >= 1, "the detail baseline stages the intro scene")
  Assert.isTrue(
    #drawsOfImages(detailGraphics.draws, { playerTerrain, foeTerrain }) >= 2,
    "the detail baseline stages both terrain sprites"
  )
  Assert.isTrue(
    #drawsOfImages(detailGraphics.draws, { trainerImage }) >= 1,
    "the detail baseline stages the trainer back picture"
  )
  local detailParticles = drawsOfImages(detailGraphics.draws, images)
  Assert.isTrue(#detailParticles >= 1, "the detail baseline stages live encounter particles")
  Assert.isTrue(#drawsOfImages(detailGraphics.draws, moveImages) >= 1, "the detail baseline stages live move particles")
  Assert.isTrue(#drawsOfImages(detailGraphics.draws, ballImages) >= 1, "the detail baseline stages live ball particles")
  local compactGraphics = FakeGraphics.new()
  drawCompactPane(compactGraphics, view, sceneImage, {
    scene = { x = 0, y = 0, width = 256, height = 136 },
  })
  Assert.isTrue(
    #drawsOfImages(compactGraphics.draws, { sceneImage }) >= 1,
    "the compact viewport stages the same intro scene"
  )
  Assert.isTrue(
    #drawsOfImages(compactGraphics.draws, { playerTerrain, foeTerrain }) >= 2,
    "the compact viewport stages both terrain sprites"
  )
  Assert.isTrue(
    #drawsOfImages(compactGraphics.draws, { trainerImage }) >= 1,
    "the compact viewport stages the trainer back picture"
  )
  local compactParticles = drawsOfImages(compactGraphics.draws, images)
  Assert.isTrue(#compactParticles >= 1, "the compact viewport stages the live encounter particles")
  Assert.isTrue(
    #drawsOfImages(compactGraphics.draws, moveImages) >= 1,
    "the compact viewport stages the live move particles"
  )
  Assert.isTrue(
    #drawsOfImages(compactGraphics.draws, ballImages) >= 1,
    "the compact viewport stages the live ball particles"
  )
  local function positions(draws)
    local points = {}
    for _, entry in ipairs(draws) do
      points[#points + 1] = tostring(entry.x) .. "," .. tostring(entry.y)
    end
    table.sort(points)
    return table.concat(points, ";")
  end
  Assert.equal(
    positions(compactParticles),
    positions(detailParticles),
    "compact particles keep the native 24px/unit main-screen origin under the clip"
  )
end

-- The detail main screen draws its scene sampler with plain placement
-- even while a staged encounter palette snapshot is present: pool leases
-- forward extras to the host draw, where a snapshot table raises bad
-- argument #4, so the snapshot never rides the sampler draw. The 3D
-- particle draws stay exact with or without it, and no fullscreen wash
-- covers the composed scene.
function T.detail_main_scene_samples_staged_plane_palette_while_particles_stay_exact()
  local BattleEncounterPalette = require("game.hgss.src.battle.BattleEncounterPalette")
  local words = {}
  for index = 0, 255 do
    local bank = math.floor(index / 16)
    local red = bank % 32
    local green = (bank * 2) % 32
    local blue = (bank * 3) % 32
    words[#words + 1] = red + green * 32 + blue * 1024
  end
  local mainObjectWords = {}
  for index = 1, 224 do
    mainObjectWords[index] = words[index]
  end
  local palette = BattleEncounterPalette.new({
    battleType = "wild",
    source = {
      mainBg = words,
      mainObj = mainObjectWords,
      mainObjPostFill = {},
      subBgOpaque = words,
      subObjOpaque = words,
      initialDisplayed = { subBg = words, subObj = words },
      fill = 0,
    },
  })
  palette:tick(20)
  local snapshot = palette:snapshot()
  Assert.isTrue(
    snapshot.mainBg[2 * 16 + 1] ~= words[2 * 16 + 1],
    "the staged snapshot fades the selected main background bank at the task fade"
  )
  Assert.equal(
    snapshot.mainBg[10 * 16 + 1],
    0,
    "the staged snapshot preserves the unselected transparent main background bank"
  )
  -- Lease-shaped sampler: forwards placement straight to the host draw
  -- and rejects non-numeric extras exactly like love.graphics.draw, so
  -- a leaked snapshot table fails here instead of only in production.
  local sceneImage = {}
  local sampled = {}
  local sceneSampler = {
    draw = function(_, graphics, x, y, seen, ...)
      Assert.isTrue(type(x) == "number", "the scene sampler draws at a numeric x")
      Assert.isTrue(type(y) == "number", "the scene sampler draws at a numeric y")
      Assert.isTrue(seen == nil and select("#", ...) == 0, "no palette state rides the scene sampler draw")
      sampled[#sampled + 1] = { graphics = graphics, x = x, y = y }
      graphics.draw(sceneImage, x, y)
    end,
    drawQuad = function(_, graphics, quad, x, y, seen, ...)
      Assert.isTrue(type(x) == "number", "the scene sampler draws its quad at a numeric x")
      Assert.isTrue(type(y) == "number", "the scene sampler draws its quad at a numeric y")
      Assert.isTrue(seen == nil and select("#", ...) == 0, "no palette state rides the scene sampler quad draw")
      sampled[#sampled + 1] = { graphics = graphics, x = x, y = y }
      graphics.draw(sceneImage, quad, x, y)
    end,
  }
  local systems, images = runningSystems()
  local view = {
    encounterParticleSystems = systems,
    backgroundRaster = nil,
    openingPresentation = {
      playerTrainerVisible = false,
      foeTrainerVisible = false,
      encounterFlash = { color = "white", coefficient = 8, mainBgMask = 0xF3FF, mainObjMask = 0x3FFF },
      encounterPalette = snapshot,
    },
  }
  local graphics = FakeGraphics.new()
  drawDetail(graphics, view, sceneSampler)
  Assert.isTrue(#sampled >= 1, "the main scene sampler draws with the palette snapshot present")
  local function particleDraws()
    local found = {}
    for _, draw in ipairs(graphics.draws) do
      for _, image in ipairs(images) do
        if draw.image == image then
          found[#found + 1] = { image = draw.image, x = draw.x, y = draw.y }
        end
      end
    end
    return found
  end
  local withSnapshot = particleDraws()
  Assert.isTrue(#withSnapshot >= 1, "live particles draw over the sampled scene")
  view.openingPresentation.encounterPalette = nil
  local plainGraphics = FakeGraphics.new()
  drawDetail(plainGraphics, view, sceneSampler)
  local withoutSnapshot = {}
  for _, draw in ipairs(plainGraphics.draws) do
    for _, image in ipairs(images) do
      if draw.image == image then
        withoutSnapshot[#withoutSnapshot + 1] = { image = draw.image, x = draw.x, y = draw.y }
      end
    end
  end
  Assert.deepEqual(withSnapshot, withoutSnapshot, "the plane snapshot never recolors the 3D particle draws")
  Assert.equal(#graphics.rectangles, 0, "no fullscreen wash covers the composed main scene")
  Assert.equal(graphics.pushDepth(), 0, "main drawing restores its borrowed graphics depth")
  Assert.isTrue(graphics.getShader() == nil, "main drawing restores the caller shader")
end

return { tests = T }
