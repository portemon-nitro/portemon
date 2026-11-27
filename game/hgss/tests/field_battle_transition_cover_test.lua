-- Encounter cover composition: the launch-owned spare slot reaches the
-- field renderer untouched, and the ordinary world draw suppresses only
-- under a proven full-replacement cover on an already presented map.

local Assert = require("tests.support.Assert")
local FieldState = require("game.hgss.src.field.FieldState")

local T = {}

local function stubRuntime()
  local runtimeMap = { renderEnvironment = { id = "environment" } }
  return {
    runtimeMap = runtimeMap,
    session = {
      renderAlpha = function()
        return 0.5
      end,
    },
    camera = { id = "camera" },
    viewport = { id = "viewport" },
    fieldPixelScale = {
      resolvedScale = function()
        return 3
      end,
    },
  }
end

local function captureState(runtime, renderer, envelope, presentedMap)
  return setmetatable({
    runtime = runtime,
    presentationResources = { renderer = renderer },
    spriteItems = { id = "sprites" },
    battleEnvelope = envelope,
    _presentedRuntimeMap = presentedMap,
    _worldParts = function(_, alpha)
      return { id = "world-parts", alpha = alpha }
    end,
  }, FieldState)
end

function T.capture_transition_layers_forwards_the_spare_slot_to_the_renderer()
  local runtime = stubRuntime()
  local seen = {}
  local published = { world = { id = "world" }, dispose = function() end }
  local renderer = {
    captureTransitionLayers = function(_, env, camera, worldParts, spriteItems, viewport, alpha, scale, slot)
      seen = {
        env = env,
        camera = camera,
        worldParts = worldParts,
        spriteItems = spriteItems,
        viewport = viewport,
        alpha = alpha,
        scale = scale,
        slot = slot,
      }
      return published
    end,
  }
  local spare = { id = "spare" }
  local state = captureState(runtime, renderer, nil, nil)

  local capture = state:_captureTransitionLayers(spare)
  Assert.isTrue(capture == published, "the capture publishes the renderer result")
  Assert.isTrue(seen.slot == spare, "the spare slot reaches the renderer untouched")
  Assert.isTrue(seen.env == runtime.runtimeMap.renderEnvironment, "the capture reads the active environment")
  Assert.isTrue(seen.camera == runtime.camera, "the capture reads the live camera")
  Assert.equal(seen.worldParts.id, "world-parts", "the capture reads the current world parts")
  Assert.equal(seen.worldParts.alpha, 0.5, "the capture reads the current interpolation alpha")
  Assert.isTrue(seen.spriteItems == state.spriteItems, "the capture reads the live object plane")
  Assert.isTrue(seen.viewport == runtime.viewport, "the capture reads the live viewport")
  Assert.equal(seen.alpha, 0.5, "the capture forwards the interpolation alpha")
  Assert.equal(seen.scale, 3, "the capture forwards the resolved pixel scale")

  local standalone = state:_captureTransitionLayers(nil)
  Assert.isTrue(standalone == published, "a nil slot keeps the standalone one-shot path")
  Assert.isNil(seen.slot, "a nil slot forwards as nil instead of synthesizing a record")
end

function T.envelope_replacement_decides_only_on_presented_map_and_proven_cover()
  local runtime = stubRuntime()
  local function stateWith(envelope, presentedMap)
    return setmetatable({
      runtime = runtime,
      battleEnvelope = envelope,
      _presentedRuntimeMap = presentedMap,
    }, FieldState)
  end
  local replacing = {
    replacesFieldWorld = function()
      return true
    end,
  }
  local exposed = {
    replacesFieldWorld = function()
      return false
    end,
  }

  Assert.isTrue(
    stateWith(replacing, runtime.runtimeMap):_envelopeReplacesFieldWorld(),
    "a proven cover on the presented map replaces the ordinary world draw"
  )
  Assert.isFalse(
    stateWith(exposed, runtime.runtimeMap):_envelopeReplacesFieldWorld(),
    "a non-replacing route keeps the ordinary world draw"
  )
  Assert.isFalse(
    stateWith(replacing, nil):_envelopeReplacesFieldWorld(),
    "the first destination draw always presents instead of suppressing"
  )
  Assert.isFalse(
    stateWith(replacing, { renderEnvironment = {} }):_envelopeReplacesFieldWorld(),
    "a new map presents once before any suppression"
  )
  Assert.isFalse(
    stateWith(nil, runtime.runtimeMap):_envelopeReplacesFieldWorld(),
    "no envelope keeps the ordinary world draw"
  )
  Assert.isFalse(
    stateWith({}, runtime.runtimeMap):_envelopeReplacesFieldWorld(),
    "a headless composition without the predicate keeps the ordinary draw"
  )
end

return { tests = T }
