-- Resize coupling: UI scale follows the field pixel-scale controller, not host
-- height proportion.

local Assert = require("tests.support.Assert")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local FieldPixelScale = require("libs.hgss.src.presentation.FieldPixelScale")
local FieldPresentation = require("data.manifests.field_presentation")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldYesNoHost = require("libs.hgss.src.ui.FieldYesNoHost")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local PixelScale = require("libs.ui.src.PixelScale")

local T = {}

-- No choice is ever presented on these resize draw paths: the shared host
-- stays idle and fails loudly if a choice layout is ever requested.
local function idleChoiceHost()
  return {
    isModal = function()
      return false
    end,
    presentation = function()
      return nil
    end,
    layoutFor = function()
      error("no choice is active in this fixture", 0)
    end,
  }
end

---@class ResizeTestRuntime
---@field resizeCalls integer?
---@field lastResize table?
---@field rendererObservations table?

local function drawState(topologyProvider, pollTopology)
  topologyProvider = topologyProvider
    or function(width, height)
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = width, height = height },
        touch = false,
        role = "world",
      })
    end
  ---@type ResizeTestRuntime
  local runtime = {
    session = {
      renderAlpha = function()
        return 0
      end,
    },
    destinationWorldPresentable = function()
      return true
    end,
    acknowledgeDestinationPresentation = function() end,
    runtimeMap = { sceneRuntime = {} },
    camera = { zoom = 1 },
    viewport = {
      width = 800,
      height = 600,
      worldViewport = {},
      referenceFrame = { height = 600 },
      fieldPixelScale = FieldPixelScale.new(FieldPresentation.fieldScale),
    },
    fieldPixelScale = FieldPixelScale.new(FieldPresentation.fieldScale),
    applicationHost = {
      isActive = function()
        return false
      end,
      status = function()
        return { fadeAlpha = 0 }
      end,
    },
    pcApplicationHost = {
      isActive = function()
        return false
      end,
      cancelPointerCapture = function() end,
    },
    transition = { fadeAlpha = 0 },
    dialogue = {
      isModal = function()
        return false
      end,
    },
    scripts = {
      dialogueHost = {
        yesNoPresentation = function()
          return nil
        end,
      },
    },
    contextChoiceProvider = {
      status = function()
        return nil
      end,
    },
    contextChoicePresentation = function()
      return nil
    end,
    signpost = {
      isModal = function()
        return false
      end,
    },
    menuHost = {
      presentation = function()
        return nil
      end,
    },
    yesNoHost = idleChoiceHost(),
    resizePresentation = function(self, width, height, topology)
      self.resizeCalls = (self.resizeCalls or 0) + 1
      self.lastResize = { width, height, topology }
      self.viewport.width = width
      self.viewport.height = height
    end,
  }
  local rendererObservations = {}
  local state = setmetatable({
    runtime = runtime,
    topologyProvider = topologyProvider,
    _pollPresentationTopology = pollTopology == true,
    presentationResources = {
      drawMart = function() end,
      renderer = {
        draw = function(_, _, _, _, _, viewport)
          rendererObservations[#rendererObservations + 1] = {
            width = viewport.width,
            height = viewport.height,
            resizeCalls = runtime.resizeCalls or 0,
          }
        end,
      },
    },
    actorPresentation = {
      drawItems = function()
        return {}
      end,
      records = function()
        return {}
      end,
    },
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
  }, FieldState)
  state._worldParts = function()
    return state.worldParts
  end
  runtime.rendererObservations = rendererObservations
  return state, runtime
end

local function oneDisplay(width, height, safeRect)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    safeRect = safeRect,
    touch = false,
    role = "world",
  })
end

function T.draw_uses_settled_viewport_until_explicit_resize()
  local topologyCalls = 0
  local state, runtime = drawState(function(width, height)
    topologyCalls = topologyCalls + 1
    return ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      touch = false,
      role = "world",
    })
  end, true)
  state:resize(800, 600)
  runtime.resizeCalls = 0
  runtime.lastResize = nil
  local originalGetDimensions = love.graphics.getDimensions
  local dimensions = { width = 1600, height = 900 }
  rawset(love.graphics, "getDimensions", function()
    return dimensions.width, dimensions.height
  end)
  local ok, err = pcall(function()
    state:draw()
    state:resize(1600, 900)
    state:draw()
  end)
  Assert.isTrue(ok, "explicit resize must publish settled geometry: " .. tostring(err))
  Assert.equal(runtime.resizeCalls, 1)
  Assert.equal(runtime.lastResize[1], 1600)
  Assert.equal(runtime.lastResize[2], 900)
  Assert.deepEqual(runtime.rendererObservations, {
    { width = 800, height = 600, resizeCalls = 0 },
    { width = 1600, height = 900, resizeCalls = 1 },
  })
  Assert.equal(topologyCalls, 4)

  dimensions.width, dimensions.height = 800, 600
  ok, err = pcall(function()
    state:draw()
    state:resize(800, 600)
    state:draw()
  end)
  love.graphics.getDimensions = originalGetDimensions
  Assert.isTrue(ok, "missed restore resize should be repaired: " .. tostring(err))
  Assert.equal(runtime.resizeCalls, 2)
  Assert.equal(runtime.lastResize[1], 800)
  Assert.equal(runtime.lastResize[2], 600)
  Assert.deepEqual(runtime.rendererObservations[2], {
    width = 1600,
    height = 900,
    resizeCalls = 1,
  })
  Assert.deepEqual(runtime.rendererObservations[3], {
    width = 1600,
    height = 900,
    resizeCalls = 1,
  })
  Assert.deepEqual(runtime.rendererObservations[4], {
    width = 800,
    height = 600,
    resizeCalls = 2,
  })
  Assert.equal(topologyCalls, 7)
end

function T.resize_event_applies_presentation_geometry_once_before_an_unchanged_draw()
  local topology = oneDisplay(1280, 720)
  local state, runtime = drawState(function()
    return topology
  end)
  state:resize(1280, 720)
  Assert.equal(runtime.resizeCalls, 1)
  Assert.deepEqual(runtime.lastResize, { 1280, 720, topology })

  local originalGetDimensions = love.graphics.getDimensions
  rawset(love.graphics, "getDimensions", function()
    return 1280, 720
  end)
  local ok, err = pcall(function()
    state:draw()
    state:draw()
  end)
  rawset(love.graphics, "getDimensions", originalGetDimensions)
  Assert.isTrue(ok, "unchanged draw must use the event-synchronized geometry: " .. tostring(err))
  Assert.equal(runtime.resizeCalls, 1)
  Assert.deepEqual(runtime.rendererObservations, {
    { width = 1280, height = 720, resizeCalls = 1 },
    { width = 1280, height = 720, resizeCalls = 1 },
  })
end

function T.injected_topology_provider_publishes_one_same_size_structural_change()
  local current = oneDisplay(1280, 720, { x = 0, y = 0, width = 1280, height = 700 })
  local state, runtime = drawState(function()
    return current
  end, true)
  state:resize(1280, 720)
  runtime.resizeCalls = 0
  runtime.lastResize = nil
  state._lastGeometrySignature = state:_geometrySignature(1280, 720, current)
  current = oneDisplay(1280, 720, { x = 0, y = 20, width = 1280, height = 700 })

  local originalGetDimensions = love.graphics.getDimensions
  rawset(love.graphics, "getDimensions", function()
    return 1280, 720
  end)
  local ok, err = pcall(function()
    state:draw()
    state:draw()
  end)
  rawset(love.graphics, "getDimensions", originalGetDimensions)
  Assert.isTrue(ok, "injected topology polling must remain supported: " .. tostring(err))
  Assert.equal(runtime.resizeCalls, 1)
  Assert.deepEqual(runtime.lastResize, { 1280, 720, current })
end

local function effectiveScaleAtHeight(height)
  local viewport = FieldViewport.new(1280, height, { mode = "expanded" })
  local scale = FieldPixelScale.new(FieldPresentation.fieldScale)
  scale:resize(viewport.referenceFrame.height)
  return scale:resolvedScale(), scale:cameraZoom(), viewport
end

function T.field_scale_preserves_the_resize_curve_and_camera_projection()
  local scaleA, zoomA = effectiveScaleAtHeight(600)
  local scaleB, zoomB = effectiveScaleAtHeight(720)
  -- With resizeCompensation 0.7, zoom changes with height
  Assert.isTrue(zoomA ~= zoomB, "resize must change effective zoom per field_presentation.lua")
  Assert.equal(scaleA % 1, 0, "the resolved scale at the reference height is integral")
  Assert.equal(scaleB % 1, 0, "the resolved scale after resize is integral")
  Assert.near(scaleA, (600 / 192) * zoomA, 1e-9)
  Assert.near(scaleB, (720 / 192) * zoomB, 1e-9)
end

-- Field dialogue shares one resolved presentation contract with Oak: the host
-- supplies real bounds plus the resolved field pixel scale as a cap, and the
-- renderer draws exactly the resulting presentation. The signpost keeps its
-- existing exact-scale contract.
local function fieldStateWithCapturedUi(worldViewport, cameraZoom, viewportWidth, viewportHeight, yesNoStatus)
  viewportWidth = viewportWidth or 1280
  viewportHeight = viewportHeight or 600
  local viewport = FieldViewport.new(viewportWidth, viewportHeight, { mode = "expanded" })
  local scale = FieldPixelScale.new(FieldPresentation.fieldScale)
  scale:resize(viewport.referenceFrame.height)
  local fieldScale = scale:resolvedScale()
  viewport.worldViewport = {
    x = worldViewport.x,
    y = worldViewport.y,
    width = worldViewport.width,
    height = worldViewport.height,
  }
  local uiManifest = FieldUiFixture.manifest()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = viewportWidth, height = viewportHeight },
    touch = false,
    role = "world",
  })
  local fakeRuntimeMap = {
    mapId = 1,
    mapSymbol = "MAP_FAKE",
    sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} },
  }
  local state = setmetatable({
    runtime = {
      viewport = viewport,
      fieldPixelScale = scale,
      uiManifest = uiManifest,
      camera = { zoom = cameraZoom },
      runtimeMap = fakeRuntimeMap,
      player = { fieldX = 0, fieldZ = 0, worldY = 0, surfaceId = 0, facing = "south", motion = "idle" },
      playerVisual = {
        drawRecord = function()
          return { visible = false }
        end,
      },
      actors = {
        drawRecords = function()
          return {}
        end,
      },
      dialogue = {
        isModal = function()
          return true
        end,
      },
      scripts = {
        dialogueHost = {
          yesNoPresentation = function()
            return yesNoStatus
          end,
        },
      },
      contextChoiceProvider = {
        isActive = function()
          return false
        end,
        status = function()
          return nil
        end,
      },
      contextChoicePresentation = function()
        return nil
      end,
      screenTopology = topology,
      signpost = {
        isModal = function()
          return true
        end,
      },
      session = {
        renderAlpha = function()
          return 0
        end,
      },
      destinationWorldPresentable = function()
        return true
      end,
      acknowledgeDestinationPresentation = function() end,
      applicationHost = {
        isActive = function()
          return false
        end,
        status = function()
          return { fadeAlpha = 0 }
        end,
      },
      pcApplicationHost = {
        isActive = function()
          return false
        end,
        cancelPointerCapture = function() end,
      },
      transition = { fadeAlpha = 0 },
      menuHost = {
        presentation = function()
          return nil
        end,
      },
      resizePresentation = function() end,
    },
    topologyProvider = function()
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = viewportWidth, height = viewportHeight },
        touch = false,
        role = "world",
      })
    end,
    presentationResources = {
      drawMart = function() end,
      renderer = { draw = function() end },
    },
    actorPresentation = {
      drawItems = function()
        return {}
      end,
      records = function()
        return {}
      end,
    },
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    _lastGeometrySignature = string.format(
      "%d:%d:main:world:0:0:%d:%d",
      viewportWidth,
      viewportHeight,
      viewportWidth,
      viewportHeight
    ),
  }, FieldState)
  state._worldParts = function()
    return {}
  end
  local dialogueCalls = {}
  local yesNoDraws = {}
  local choiceContext = nil
  -- The fixture shares a live choice host exactly as production does: the
  -- host pulls the dialogue-derived metrics through its presentation
  -- callback, mirroring the runtime choice context, and FieldState draws
  -- the resulting host presentation.
  local yesNoHost = FieldYesNoHost.new({
    width = viewportWidth,
    height = viewportHeight,
    input = {
      beginUi = function() end,
      clearUi = function() end,
    },
    screenTopology = topology,
    measureText = function(text)
      return #text * 8
    end,
    presentation = function()
      local dialogueScale = PixelScale.fitPreferred(viewport.worldViewport, 256, 48, fieldScale)
      local dialogueBox = DialoguePresentationLayout.compute(viewport.worldViewport, {
        scale = dialogueScale,
        allowClipping = true,
        cursorPlacement = uiManifest.dialogueFrames.continueCursor.placement,
      }).outerRect
      choiceContext = {
        topology = topology,
        bounds = viewport.worldViewport,
        dialogueBox = dialogueBox,
        preferredScale = dialogueScale,
      }
      return choiceContext
    end,
  })
  if yesNoStatus ~= nil then
    yesNoHost:openChoice({
      yesText = yesNoStatus.yesText,
      noText = yesNoStatus.noText,
      frameIndex = yesNoStatus.frameIndex,
      selectedIndex = yesNoStatus.selectedIndex or 0,
    }, 0)
  end
  state.runtime.yesNoHost = yesNoHost
  state.presentationResources.dialogueRenderer = {
    draw = function(_, a, b, c, d)
      dialogueCalls[#dialogueCalls + 1] = { controller = a, second = b, third = c, fourth = d }
    end,
  } --[[@as any]]
  local signpostScales = {}
  local presentationResources = state.presentationResources --[[@as any]]
  presentationResources.yesNoRenderer = {
    draw = function(_, status, layout)
      yesNoDraws[#yesNoDraws + 1] = { status = status, layout = layout }
    end,
  }
  presentationResources.signpostRenderer = {
    draw = function(_, _, _, alphaOrScale, maybeScale)
      if type(maybeScale) == "number" then
        signpostScales[#signpostScales + 1] = maybeScale
      elseif type(alphaOrScale) == "number" and alphaOrScale ~= 0 then
        signpostScales[#signpostScales + 1] = alphaOrScale
      end
    end,
  }
  local oldGetDimensions = love.graphics.getDimensions
  rawset(love.graphics, "getDimensions", function()
    return viewportWidth, viewportHeight
  end)
  local ok, err = pcall(function()
    state:draw()
  end)
  love.graphics.getDimensions = oldGetDimensions
  Assert.isTrue(ok, "FieldState draw should not throw: " .. tostring(err))
  return fieldScale, dialogueCalls, signpostScales, yesNoDraws, choiceContext
end

local function assertOuterRectInsideBounds(outerRect, bounds)
  Assert.isTrue(outerRect.x >= bounds.x - 1e-9, "dialogue stays inside the real host horizontally")
  Assert.isTrue(
    outerRect.x + outerRect.width <= bounds.x + bounds.width + 1e-9,
    "dialogue stays inside the real host horizontally"
  )
  Assert.isTrue(outerRect.y >= bounds.y - 1e-9, "dialogue stays inside the real host vertically")
  Assert.isTrue(
    outerRect.y + outerRect.height <= bounds.y + bounds.height + 1e-9,
    "dialogue stays inside the real host vertically"
  )
end

function T.constrained_dialogue_shrinks_to_fit_the_real_world_viewport()
  local realBounds = { x = 5, y = 7, width = 256, height = 48 }
  local fieldScale, dialogueCalls, signpostScales = fieldStateWithCapturedUi(realBounds, 1.25)
  Assert.equal(#dialogueCalls, 1, "field dialogue draws once per frame")
  local call = dialogueCalls[1]
  Assert.isNil(call.third, "dialogue renders from one resolved presentation, not viewport plus scale")
  Assert.isNil(call.fourth, "dialogue renders from one resolved presentation, not a four-argument call")
  local presentation = call.second
  Assert.deepEqual(
    presentation.bounds,
    realBounds,
    "field passes its real bounds unchanged: no inflated stand-in width or height"
  )
  local expectedScale = PixelScale.fitPreferred(realBounds, 256, 48, fieldScale)
  Assert.isTrue(expectedScale < fieldScale, "the fixture host must be too small for the field scale")
  Assert.equal(expectedScale % 1, 0, "a constrained dialogue must use an integer scale")
  Assert.near(presentation.scale, expectedScale, 1e-9)
  Assert.near(presentation.outerRect.width, 256 * expectedScale, 1e-9)
  Assert.near(presentation.outerRect.height, 48 * expectedScale, 1e-9)
  assertOuterRectInsideBounds(presentation.outerRect, realBounds)
  Assert.near(
    presentation.outerRect.x,
    realBounds.x + (realBounds.width - 256 * expectedScale) / 2,
    1e-9,
    "the shrunken dialogue stays horizontally centered"
  )
  Assert.near(
    presentation.outerRect.y,
    realBounds.y + realBounds.height - 48 * expectedScale,
    1e-9,
    "the shrunken dialogue stays bottom-aligned"
  )
  Assert.equal(#signpostScales, 1, "the signpost still draws in the same frame")
  local expectedSignpostScale = PixelScale.fitPreferred(realBounds, 256, 192, fieldScale)
  Assert.equal(signpostScales[1], expectedSignpostScale, "the signpost uses its own integer fit")
end

function T.dialogue_and_signpost_fit_the_640_by_480_field_view()
  local fieldScale, dialogueCalls, signpostScales =
    fieldStateWithCapturedUi({ x = 0, y = 0, width = 640, height = 480 }, 0.25, 640, 480)
  local dialogue = dialogueCalls[1].second
  local expectedDialogueScale = PixelScale.fitPreferred(dialogue.bounds, 256, 48, fieldScale)
  local expectedSignpostScale =
    PixelScale.fitPreferred({ x = 0, y = 0, width = 640, height = 480 }, 256, 192, fieldScale)
  Assert.equal(expectedDialogueScale, 2, "the 640x480 dialogue uses the greatest fitting integer")
  Assert.equal(expectedSignpostScale, 2, "the 640x480 signpost uses the greatest fitting integer")
  Assert.equal(dialogue.scale, expectedDialogueScale, "FieldState publishes the fitted dialogue scale")
  Assert.equal(signpostScales[1], expectedSignpostScale, "FieldState publishes the fitted signpost scale")
  Assert.equal(dialogue.scale % 1, 0, "the dialogue scale is integral")
  Assert.equal(signpostScales[1] % 1, 0, "the signpost scale is integral")
end

function T.yes_no_receives_the_dialogue_bounds_and_fitted_scale()
  local bounds = { x = 40, y = 30, width = 640, height = 480 }
  local yesNoStatus = { active = true, selectedIndex = 0, yesText = "YES", noText = "NO" }
  local fieldScale, dialogueCalls, _, yesNoDraws, choiceContext =
    fieldStateWithCapturedUi(bounds, 0.25, 720, 540, yesNoStatus)
  local dialogueScale = PixelScale.fitPreferred(bounds, 256, 48, fieldScale)
  Assert.equal(#yesNoDraws, 1, "active field choice is drawn once")
  local drawn = assert(yesNoDraws[1])
  Assert.equal(drawn.status.selectedIndex, 0, "the drawn choice keeps the opened selection")
  Assert.notNil(drawn.layout, "the drawn choice carries its host layout")
  local context = assert(choiceContext, "the live host resolves its presentation while drawing")
  Assert.deepEqual(context.bounds, bounds, "the host observes the real field bounds")
  Assert.equal(context.preferredScale, dialogueScale, "the host observes the fitted dialogue scale")
  Assert.deepEqual(context.dialogueBox, dialogueCalls[1].second.outerRect)
end

function T.roomy_dialogue_keeps_the_field_scale_bottom_centered()
  local viewport = FieldViewport.new(1280, 600, { mode = "expanded" })
  local realBounds = {
    x = viewport.worldViewport.x,
    y = viewport.worldViewport.y,
    width = viewport.worldViewport.width,
    height = viewport.worldViewport.height,
  }
  local fieldScale, dialogueCalls, signpostScales = fieldStateWithCapturedUi(realBounds, 1.25)
  Assert.equal(#dialogueCalls, 1, "field dialogue draws once per frame")
  local call = dialogueCalls[1]
  Assert.isNil(call.third, "dialogue renders from one resolved presentation, not viewport plus scale")
  Assert.isNil(call.fourth, "dialogue renders from one resolved presentation, not a four-argument call")
  local presentation = call.second
  Assert.deepEqual(presentation.bounds, realBounds, "field passes its real bounds unchanged")
  Assert.near(presentation.scale, PixelScale.fitPreferred(realBounds, 256, 48, fieldScale), 1e-9)
  assertOuterRectInsideBounds(presentation.outerRect, realBounds)
  Assert.near(
    presentation.outerRect.x,
    realBounds.x + (realBounds.width - 256 * fieldScale) / 2,
    1e-9,
    "dialogue stays horizontally centered"
  )
  Assert.near(
    presentation.outerRect.y,
    realBounds.y + realBounds.height - 48 * fieldScale,
    1e-9,
    "dialogue stays bottom-aligned"
  )
  Assert.equal(#signpostScales, 1, "the signpost still draws in the same frame")
  Assert.equal(signpostScales[1], PixelScale.fitPreferred(realBounds, 256, 192, fieldScale))
end

function T.undersized_dialogue_width_keeps_one_x_and_exposes_only_the_overflow()
  local bounds = { x = 0, y = 0, width = 255, height = 48 }
  local _, dialogueCalls = fieldStateWithCapturedUi(bounds, 1.25)
  Assert.equal(#dialogueCalls, 1, "field dialogue draws once at the undersized width")

  local presentation = dialogueCalls[1].second
  Assert.equal(presentation.scale, 1, "the minimum presentation scale remains integer 1")
  Assert.deepEqual(presentation.bounds, bounds, "field passes the real undersized bounds")
  Assert.deepEqual(presentation.outerRect, { x = 0, y = 0, width = 256, height = 48 })
  Assert.equal(presentation.origin.x, 0, "the one-pixel width overflow starts on the host pixel lattice")
end

function T.undersized_dialogue_height_keeps_one_x_and_bottom_anchors_the_overflow()
  local bounds = { x = 11, y = 13, width = 256, height = 47 }
  local _, dialogueCalls = fieldStateWithCapturedUi(bounds, 1.25)
  Assert.equal(#dialogueCalls, 1, "field dialogue draws once at the undersized height")

  local presentation = dialogueCalls[1].second
  Assert.equal(presentation.scale, 1, "the minimum presentation scale remains integer 1")
  Assert.deepEqual(presentation.bounds, bounds, "field passes the real undersized bounds")
  Assert.deepEqual(presentation.outerRect, { x = 11, y = 12, width = 256, height = 48 })
  Assert.equal(presentation.origin.y, 12, "the one-pixel height overflow stays bottom anchored")
end

function T.undersized_dialogue_on_both_axes_keeps_one_x_and_real_bounds()
  local bounds = { x = 7, y = 9, width = 255, height = 47 }
  local _, dialogueCalls = fieldStateWithCapturedUi(bounds, 1.25)
  local presentation = dialogueCalls[1].second
  Assert.equal(presentation.scale, 1)
  Assert.deepEqual(presentation.bounds, bounds)
  Assert.deepEqual(presentation.outerRect, { x = 7, y = 8, width = 256, height = 48 })
end

-- Dialogue presentation geometry follows topology/scale invalidation, not the
-- frame clock: repeated draws at unchanged bounds and pixel scale resolve
-- the layout once, while a resize or pixel-scale change rebuilds it before
-- the next draw with the same placement a fresh computation produces.
function T.dialogue_layout_resolves_once_per_topology_scale_invalidation()
  local PixelScaleModule = require("libs.ui.src.PixelScale")
  local LayoutModule = require("libs.hgss.src.ui.DialoguePresentationLayout")
  local originalFit = PixelScaleModule.fitPreferred
  local originalCompute = LayoutModule.compute
  local fitCalls, computeCalls = 0, 0
  PixelScaleModule.fitPreferred = function(...)
    fitCalls = fitCalls + 1
    return originalFit(...)
  end
  LayoutModule.compute = function(...)
    computeCalls = computeCalls + 1
    return originalCompute(...)
  end
  local ok, err = pcall(function()
    local viewport = FieldViewport.new(640, 480, { mode = "expanded" })
    local scale = FieldPixelScale.new(FieldPresentation.fieldScale)
    scale:resize(viewport.referenceFrame.height)
    local uiManifest = FieldUiFixture.manifest()
    local manifestPlacement = uiManifest.dialogueFrames.continueCursor.placement
    local worldDraws = 0
    local presentations = {}
    local runtime = {
      session = {
        renderAlpha = function()
          return 0
        end,
      },
      destinationWorldPresentable = function()
        return true
      end,
      acknowledgeDestinationPresentation = function() end,
      runtimeMap = { sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} } },
      camera = { zoom = 1 },
      viewport = viewport,
      fieldPixelScale = scale,
      uiManifest = uiManifest,
      applicationHost = {
        isActive = function()
          return false
        end,
        status = function()
          return {}
        end,
      },
      pcApplicationHost = {
        isActive = function()
          return false
        end,
        cancelPointerCapture = function() end,
      },
      transition = { fadeAlpha = 0 },
      dialogue = {
        isModal = function()
          return true
        end,
      },
      contextChoicePresentation = function()
        return nil
      end,
      signpost = {
        isModal = function()
          return false
        end,
      },
      menuHost = {
        presentation = function()
          return nil
        end,
      },
      yesNoHost = idleChoiceHost(),
      fieldEntranceIndicator = {
        status = function()
          return { visible = false }
        end,
      },
      resizePresentation = function(self, width, height)
        viewport.width = width
        viewport.height = height
        viewport.worldViewport = { x = 0, y = 0, width = width, height = height }
      end,
    }
    local state = setmetatable({
      runtime = runtime,
      topologyProvider = function(width, height)
        return oneDisplay(width, height)
      end,
      _pollPresentationTopology = false,
      presentationResources = {
        drawMart = function() end,
        renderer = {
          draw = function()
            worldDraws = worldDraws + 1
          end,
        },
        dialogueRenderer = {
          draw = function(_, _, presentation)
            presentations[#presentations + 1] = presentation
          end,
        },
        fieldEntranceIndicatorRenderer = {
          drawItems = function()
            return {}
          end,
        },
        fieldEmoteRenderer = {
          drawItems = function()
            return {}
          end,
        },
      },
      actorPresentation = {
        drawItems = function()
          return {}
        end,
        records = function()
          return {}
        end,
      },
      worldParts = {},
      worldActorItems = {},
      spriteItems = {},
    }, FieldState)
    local function referencePlacement()
      local bounds = viewport.worldViewport
      local fitted = originalFit(bounds, 256, 48, scale:resolvedScale())
      return originalCompute(bounds, {
        scale = fitted,
        allowClipping = true,
        cursorPlacement = manifestPlacement,
      })
    end
    state:draw()
    state:draw()
    state:draw()
    Assert.equal(worldDraws, 3, "every frame still renders the world")
    Assert.equal(computeCalls, 1, "unchanged topology and scale resolve the dialogue layout once")
    Assert.equal(fitCalls, 1, "unchanged topology and scale fit the dialogue scale once")
    Assert.equal(#presentations, 3, "every frame still presents the dialogue")
    Assert.deepEqual(presentations[2].outerRect, presentations[1].outerRect)
    Assert.deepEqual(presentations[3].outerRect, presentations[1].outerRect)

    state:resize(800, 600)
    state:draw()
    Assert.equal(computeCalls, 2, "a resize rebuilds the dialogue layout exactly once")
    Assert.equal(fitCalls, 2, "a resize refits the dialogue scale exactly once")
    Assert.deepEqual(
      presentations[#presentations].outerRect,
      referencePlacement().outerRect,
      "the rebuilt dialogue keeps the freshly computed placement"
    )
    state:draw()
    Assert.equal(computeCalls, 2, "the rebuilt layout is reused until the next invalidation")

    local scaleBeforeZoom = scale:resolvedScale()
    scale:zoomIn()
    if scale:resolvedScale() == scaleBeforeZoom then
      scale:zoomOut()
    end
    Assert.isTrue(scale:resolvedScale() ~= scaleBeforeZoom, "the fixture pixel-scale change takes effect")
    state:draw()
    Assert.equal(computeCalls, 3, "a pixel-scale change rebuilds the dialogue layout exactly once")
    Assert.deepEqual(
      presentations[#presentations].outerRect,
      referencePlacement().outerRect,
      "the rescaled dialogue keeps the freshly computed placement"
    )
    state:draw()
    state:draw()
    Assert.equal(computeCalls, 3, "the rescaled layout is reused until the next invalidation")
  end)
  PixelScaleModule.fitPreferred = originalFit
  LayoutModule.compute = originalCompute
  if not ok then
    error(err, 0)
  end
end

-- Screen-fade cover rectangles follow the topology, not the frame clock or
-- the fade coefficient: repeated draws at unchanged topology read the
-- surface geometry once and repaint identical rectangles while only the
-- alpha changes, while a topology change rebuilds the cover before the
-- next draw.
function T.screen_fade_cover_rects_reused_until_topology_changes()
  local state, runtime = drawState()
  runtime.viewport.worldViewport = { x = 0, y = 0, width = 800, height = 600 }
  local alpha = 0.5
  runtime.screenFade = {
    presentationOverlay = function()
      return { r = 0, g = 0, b = 0, a = alpha }
    end,
  }
  local rectReads = 0
  local function countedSurface(id, rect)
    return setmetatable({ id = id, role = "world" }, {
      __index = function(_, key)
        if key == "rect" then
          rectReads = rectReads + 1
          return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
        end
        return nil
      end,
    })
  end
  local surfaces = {
    countedSurface("left", { x = 0, y = 0, width = 400, height = 600 }),
    countedSurface("right", { x = 400, y = 0, width = 400, height = 600 }),
  }
  runtime.screenTopology = { surfaces = surfaces }
  local lg = love.graphics
  local originalRectangle, originalSetColor = lg.rectangle, lg.setColor
  local fills, paintColors = {}, {}
  lg.rectangle = function(mode, x, y, width, height)
    fills[#fills + 1] = { mode = mode, x = x, y = y, width = width, height = height }
    return originalRectangle(mode, x, y, width, height)
  end
  lg.setColor = function(red, green, blue, opacity)
    paintColors[#paintColors + 1] = { red, green, blue, opacity }
    return originalSetColor(red, green, blue, opacity)
  end
  local ok, err = pcall(function()
    local function fadeFillsSince(mark)
      local rects = {}
      for index = mark + 1, #fills do
        rects[#rects + 1] = fills[index]
      end
      return rects
    end
    local mark = #fills
    state:draw()
    state:draw()
    state:draw()
    Assert.equal(rectReads, 2, "unchanged topology reads each fade surface rectangle once")
    local firstCover = fadeFillsSince(mark)
    Assert.equal(#firstCover, 6, "three frames repaint the two-rectangle cover")
    Assert.deepEqual({ firstCover[3], firstCover[4] }, { firstCover[1], firstCover[2] })
    Assert.deepEqual({ firstCover[5], firstCover[6] }, { firstCover[1], firstCover[2] })

    alpha = 0.8
    mark = #fills
    local colorsBefore = #paintColors
    state:draw()
    Assert.equal(rectReads, 2, "an alpha change alone rereads no surface geometry")
    local alphaCover = fadeFillsSince(mark)
    Assert.deepEqual(alphaCover, { firstCover[1], firstCover[2] }, "the cover geometry is reused while alpha changes")
    Assert.isTrue(#paintColors > colorsBefore, "the alpha change still repaints")
    Assert.equal(paintColors[#paintColors - 1][4], 0.8, "the repaint carries the new fade alpha")

    runtime.screenTopology = {
      surfaces = {
        countedSurface("left", { x = 0, y = 0, width = 400, height = 600 }),
        countedSurface("bottom", { x = 0, y = 400, width = 800, height = 200 }),
      },
    }
    mark = #fills
    state:draw()
    Assert.equal(rectReads, 4, "a topology change rebuilds the cover exactly once")
    local rebuiltCover = fadeFillsSince(mark)
    Assert.equal(#rebuiltCover, 2, "the rebuilt cover paints once for the new topology")
    Assert.deepEqual(rebuiltCover[1], { mode = "fill", x = 0, y = 0, width = 400, height = 600 })
    Assert.deepEqual(
      rebuiltCover[2],
      { mode = "fill", x = 400, y = 400, width = 400, height = 200 },
      "the union keeps the first surface whole and clips the overlap from the second"
    )
    mark = #fills
    state:draw()
    Assert.equal(rectReads, 4, "the rebuilt cover is reused until the next topology change")
    Assert.deepEqual(fadeFillsSince(mark), rebuiltCover)
  end)
  lg.rectangle = originalRectangle
  lg.setColor = originalSetColor
  if not ok then
    error(err, 0)
  end
end

function T.field_yes_no_layout_receives_the_resolved_dialogue_outer_rect()
  local _, dialogueCalls, _, yesNoDraws, choiceContext = fieldStateWithCapturedUi(
    { x = 20, y = 30, width = 500, height = 300 },
    1,
    640,
    480,
    { active = true, selectedIndex = 0, yesText = "YES", noText = "NO", frameIndex = 1 }
  )
  Assert.equal(#yesNoDraws, 1, "active field choice is drawn once")
  local context = assert(choiceContext, "the live host resolves its presentation while drawing")
  Assert.deepEqual(
    context.dialogueBox,
    dialogueCalls[1].second.outerRect,
    "single-display choice placement receives the exact rendered dialogue rectangle"
  )
  Assert.isFalse(
    context.dialogueBox == dialogueCalls[1].second.bounds,
    "the choice does not receive generic field bounds"
  )
end

return { tests = T }
