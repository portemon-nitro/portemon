-- Panel-slide renderer wiring at the recording boundary: a stripe
-- snapshot draws its uploaded tilemap on the transition plane with the
-- compiled scroll, and a silhouette request submits one window-mode
-- coverage fragment shaped like the affected battler, so the
-- compositor window reveals stripes exactly through the mon. No GPU:
-- the recording boundary observes draws, and the shared drain replays
-- planes and OBJ fragments like production.

local Assert = require("tests.support.Assert")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")

local T = {}

local COMPOSITE_LAYER = { handle = "picture-composite" }

local function drainPictures(graphics, captured)
  return function(_, drawGraphics, frame)
    captured.frame = frame
    local CompositionFrameDrain = require("tests.support.CompositionFrameDrain")
    CompositionFrameDrain.drain(drawGraphics, frame)
    return COMPOSITE_LAYER
  end
end

local function recordingGraphics(log)
  local graphics = {}
  function graphics.getColor()
    return 1, 1, 1, 1
  end
  function graphics.setColor() end
  function graphics.push() end
  function graphics.pop() end
  function graphics.newQuad()
    return {}
  end
  function graphics.draw(image, quad, x, y)
    if type(quad) == "number" then
      quad, x, y = nil, quad, x
    end
    log[#log + 1] = { kind = "draw", image = image, quad = quad, x = x, y = y }
  end
  function graphics.rectangle(mode, x, y, w, h)
    log[#log + 1] = { kind = "rectangle", mode = mode, x = x, y = y, w = w, h = h }
  end
  return graphics
end

local function stripeImage()
  return { handle = "stripe-tilemap" }
end

local function portraitImage()
  return {
    handle = "mon-portrait",
    width = 80,
    height = 80,
    getDimensions = function()
      return 80, 80
    end,
  }
end

local function testView()
  return {
    battlers = {
      {
        combatant = 1,
        activation = 1,
        side = 1,
        position = 1,
        portraitSelector = "TESTMON",
        pictureVisible = true,
        hudVisible = false,
        pictureWidth = 80,
        pictureHeight = 80,
        sourceHeight = 40,
        polygonAlpha = 31,
      },
    },
    effectInstances = {},
    hudPatchSpans = {},
    hudSections = {},
    message = "",
    textPalettes = { narration = { colors = {} } },
    encounterParticleSystems = {},
    moveParticleSystems = {},
    ballParticleSystems = {},
    slotGeometry = {
      {
        sideType = 0,
        settledX = 64,
        settledY = 112,
        entryX = 64,
        entryY = 112,
        depth = -512,
        hudX = 0,
        hudY = 0,
        hudPriority = 0,
        hudBgPriority = 0,
      },
    },
    sceneAnimation = {
      main = {
        compositor = {
          blend = { mode = "alpha", eva = 12, evb = 4, evy = 0 },
          firstTarget = { transition = true },
          secondTarget = { world3d = true, battlefield = true },
          priority = { world3d = 2, window = 0, transition = 1, battlefield = 3 },
          windows = {
            objWindow = {
              mask = { world3d = true, window = true, transition = true, battlefield = false },
            },
            outside = {
              mask = { world3d = true, window = true, transition = false, battlefield = true },
            },
          },
        },
        planes = {},
      },
      stripe = {
        raster = { width = 64, height = 64 },
        scrollX = 0,
        scrollY = 6,
      },
      objWindowSilhouette = { combatant = 1, activation = 1 },
    },
  }
end

local function testAssets(view, captured)
  return {
    drawable = function(_, key)
      if key == "mon:TESTMON" then
        return portraitImage()
      end
      return (view.drawables ~= nil and view.drawables[key]) or nil
    end,
    stripeBackground = function(_raster)
      captured.stripeUploaded = true
      return stripeImage()
    end,
    renderPictures = drainPictures(captured.graphics, captured),
  }
end

function T.panel_run_drives_the_transition_plane_and_nothing_without_it()
  -- Without a panel run the renderer uploads no stripe tilemap and
  -- submits no window-mode coverage; with one, the stripe snapshot
  -- draws on the transition plane and exactly one coverage fragment
  -- shaped like the affected battler follows it through the compositor.
  local idle = {}
  local idleLog = {}
  idle.graphics = recordingGraphics(idleLog)
  local idleView = testView()
  idleView.sceneAnimation.stripe = nil
  idleView.sceneAnimation.objWindowSilhouette = nil
  BattleRenderer.drawPane({
    graphics = idle.graphics,
    text = { drawTextForRole = function() end },
    windows = { drawWindow = function() end },
    assets = testAssets(idleView, idle),
    frameKey = "default",
  }, idleView, "detail", {})
  Assert.isTrue(idle.stripeUploaded ~= true, "no stripe run uploads no stripe tilemap")
  local idleFrame = assert(idle.frame, "the composition frame reaches the drain")
  for _, fragment in ipairs(idleFrame.objects or {}) do
    Assert.isTrue(fragment.oamMode ~= "object-window", "no silhouette submits no window coverage")
  end

  -- Pooled battle portraits are indexed atlas windows: the raw page
  -- image draws opaque, so the silhouette must sample through its
  -- lease. A raw page draw would mask the stripe as a rectangle
  -- instead of the mon shape.
  local captured = {}
  local log = {}
  captured.graphics = recordingGraphics(log)
  local view = testView()
  local drewSampler = false
  local pageImage = {
    handle = "portrait-page",
    width = 256,
    height = 256,
    getDimensions = function()
      return 256, 256
    end,
  }
  local lease = {
    image = pageImage,
    palette = { handle = "portrait-palette" },
    kind = "r8",
  }
  function lease.drawQuad(self, graphics, quad, x, y)
    drewSampler = true
    graphics.draw(self.image, quad, x, y)
  end
  local assets = testAssets(view, captured)
  local baseDrawable = assets.drawable
  assets.drawable = function(_, key)
    if key == "mon:TESTMON" then
      return {
        frames = {
          {
            image = pageImage,
            lease = lease,
            frameX = 8,
            frameY = 16,
            frameW = 80,
            frameH = 80,
            width = 80,
            height = 80,
          },
        },
      }
    end
    return baseDrawable(_, key)
  end
  BattleRenderer.drawPane({
    graphics = captured.graphics,
    text = { drawTextForRole = function() end },
    windows = { drawWindow = function() end },
    assets = assets,
    frameKey = "default",
  }, view, "detail", {})
  Assert.isTrue(captured.stripeUploaded == true, "the stripe raster uploads through the stripe seam")
  local drewStripe = false
  for _, entry in ipairs(log) do
    if entry.kind == "draw" and type(entry.image) == "table" and entry.image.handle == "stripe-tilemap" then
      drewStripe = true
    end
  end
  Assert.isTrue(drewStripe, "the stripe tilemap draws on the transition plane")
  local frame = assert(captured.frame, "the composition frame reaches the drain")
  local coverage = nil
  for _, fragment in ipairs(frame.objects or {}) do
    if fragment.oamMode == "object-window" then
      coverage = fragment
    end
  end
  Assert.notNil(coverage, "the silhouette submits one window-mode coverage fragment")
  Assert.isTrue(drewSampler, "the silhouette draws its indexed portrait through the lease sampler")
end

return { tests = T }
