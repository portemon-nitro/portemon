-- The encounter terrain particles draw over the main screen after the fade
-- overlay, and the move particle systems draw in the detail pane, from the
-- live systems the screen publishes in its view.

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
  function graphics.rectangle(mode)
    log[#log + 1] = { kind = "rectangle", mode = mode }
  end
  function graphics.draw(image)
    log[#log + 1] = { kind = "draw", image = image }
  end
  return graphics
end

local function drawDetail(graphics, view)
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
      drawable = function()
        return nil
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

function T.live_particles_draw_after_the_encounter_fade_overlay()
  local systems, images = runningSystems()
  local log = {}
  drawDetail(recordingGraphics(log), {
    encounterParticleSystems = systems,
    openingPresentation = {
      playerTrainerVisible = false,
      foeTrainerVisible = false,
      encounterFlash = { color = "white", coefficient = 8 },
    },
  })
  local overlayIndex, firstParticle = nil, nil
  for index, entry in ipairs(log) do
    if entry.kind == "rectangle" then
      overlayIndex = overlayIndex or index
    elseif entry.kind == "draw" and entry.image == images[1] and firstParticle == nil then
      firstParticle = index
    end
  end
  Assert.notNil(overlayIndex, "the fade overlay draws")
  Assert.notNil(firstParticle, "live particles draw their staged texture")
  Assert.isTrue(firstParticle > overlayIndex, "particles draw over the fade, untinted by it")
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

function T.no_live_systems_draw_no_particles()
  local log = {}
  drawDetail(recordingGraphics(log), { encounterParticleSystems = {} })
  for _, entry in ipairs(log) do
    Assert.isTrue(entry.kind ~= "draw", "an idle encounter draws no particle quads")
  end
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

return { tests = T }
