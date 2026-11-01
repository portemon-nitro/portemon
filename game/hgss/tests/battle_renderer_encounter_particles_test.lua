-- The encounter terrain particles draw over the main screen after the fade
-- overlay, and the move particle systems draw in the detail pane, from the
-- live systems the screen publishes in its view.

local Assert = require("tests.support.Assert")
local BattleEncounterParticles = require("game.hgss.src.battle.BattleEncounterParticles")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
local Fixture = require("tests.support.BattleEncounterParticlesFixture")

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
  drawDetail(recordingGraphics(log), { moveParticleSystems = { { simulation = simulation, textures = { [0] = image } } } })
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

return { tests = T }
