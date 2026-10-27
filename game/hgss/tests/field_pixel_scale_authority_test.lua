-- Production field composition contracts for integer scale ownership.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldPresentation = require("data.manifests.field_presentation")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local DisplayContext = require("libs.ui.src.DisplayContext")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "field-runtime", "map:7" },
    tags = { "field", "presentation", "composition" },
  },
  tests = {},
}

local MAP = "MAP_BURNED_TOWER_1F"

local function topology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  })
end

local function resize(game, width, height)
  game.runtime:resizePresentation(width, height, topology(width, height))
end

local function withProductionRuntime(fn)
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({
      versionId = versionId,
      map = MAP,
      save = "fresh",
      fieldOptions = { viewportWidth = 1280, viewportHeight = 720 },
    })
    local ok, err = xpcall(function()
      game:waitForFieldReady()
      fn(game)
      Assert.equal(game:renderAttempts(), 0, "field scale composition must stop before GPU rendering")
    end, debug.traceback)
    local closed, closeError = pcall(function()
      game:close()
    end)
    if not closed then
      error(closeError, 0)
    end
    if not ok then
      error(err, 0)
    end
  end)
end

T.tests.production_projection_uses_the_resolved_scale_and_fitted_reference_height = function()
  withProductionRuntime(function(game)
    local runtime = game.runtime
    local scale = runtime.fieldPixelScale
    Assert.notNil(scale, "FieldRuntime must own the field pixel-scale controller")

    resize(game, 1280, 720)
    local expandedHeight = runtime.viewport.referenceFrame.height
    local expandedScale = scale:resolvedScale()
    Assert.near(
      (expandedHeight / 192) * runtime.camera.zoom,
      expandedScale,
      1e-9,
      "camera zoom must be derived from the expanded reference-frame height"
    )

    resize(game, 900, 900)
    Assert.equal(runtime.viewport.referenceFrame.height, 675, "narrow topology must use the fitted reference height")
    local narrowScale = scale:resolvedScale()
    Assert.near(
      (runtime.viewport.referenceFrame.height / 192) * runtime.camera.zoom,
      narrowScale,
      1e-9,
      "camera zoom must be derived from the fitted reference-frame height"
    )

    Assert.keySet(FieldViewport, "__index,new,resize,worldAspect", "FieldViewport must expose geometry only")
  end)
end

local function assertCameraFollowsAllocatedGrid(runtime, nominal, physical, allocW, allocH, ratio)
  Assert.notNil(
    runtime.viewport.pixelGrid,
    "the field viewport must publish one integer source grid before drawing"
  )
  local grid = runtime.viewport.pixelGrid
  Assert.equal(grid.allocationWidth, allocW, "the published grid must allocate the ceil-covered raster width")
  Assert.equal(
    grid.allocationHeight,
    allocH,
    "the published grid must allocate the ceil-covered raster height"
  )
  Assert.equal(
    grid.placement.pixelScale,
    physical,
    "the published grid must carry the whole-physical-pixel scale"
  )
  Assert.equal(grid.placement.pixelRatio, ratio, "the published grid must carry the measured pixel ratio")
  Assert.near(
    grid.placement.scale * grid.placement.pixelRatio,
    physical,
    1e-9,
    "host magnification times pixel ratio must equal the integer physical scale"
  )
  Assert.equal(
    runtime.fieldPixelScale:resolvedScale(),
    nominal,
    "the nominal reference scale must stay on its existing curve"
  )
  Assert.near(
    runtime.camera.projectionAspect,
    allocW / allocH,
    1e-9,
    "the live camera must project the allocated source aspect, not the host rectangle"
  )
  Assert.near(
    runtime.camera.zoom,
    192 / allocH,
    1e-9,
    "the live camera must zoom to the allocated source height"
  )
end

local function ratioDisplayContext(ratio, width, height)
  return DisplayContext.new({
    graphics = {
      getDimensions = function()
        return width, height
      end,
      getDPIScale = function()
        return ratio
      end,
    },
    topologyProvider = function(topologyWidth, topologyHeight)
      return topology(topologyWidth, topologyHeight)
    end,
  })
end

T.tests.wide_viewport_grid_matches_camera_projection_across_zoom = function()
  withProductionRuntime(function(game)
    local runtime = game.runtime
    resize(game, 1280, 720)
    assertCameraFollowsAllocatedGrid(runtime, 3, 3, 427, 240, 1)

    runtime.fieldPixelScale:zoomIn()
    runtime:applyFieldPixelScaleChange()
    assertCameraFollowsAllocatedGrid(runtime, 4, 4, 320, 180, 1)

    runtime.fieldPixelScale:zoomIn()
    runtime:applyFieldPixelScaleChange()
    assertCameraFollowsAllocatedGrid(runtime, 5, 5, 256, 144, 1)

    runtime.fieldPixelScale:reset()
    runtime:applyFieldPixelScaleChange()
    assertCameraFollowsAllocatedGrid(runtime, 3, 3, 427, 240, 1)

    resize(game, 1920, 1080)
    assertCameraFollowsAllocatedGrid(runtime, 4, 4, 480, 270, 1)
  end)
end

T.tests.portrait_narrow_and_hidpi_viewports_share_one_integer_grid_rule = function()
  withProductionRuntime(function(game)
    local runtime = game.runtime
    resize(game, 750, 900)
    assertCameraFollowsAllocatedGrid(runtime, 3, 5, 150, 180, 1)

    resize(game, 1366, 768)
    assertCameraFollowsAllocatedGrid(runtime, 3, 3, 456, 256, 1)

    runtime.displayContext = ratioDisplayContext(2, 1280, 720)
    resize(game, 1280, 720)
    assertCameraFollowsAllocatedGrid(runtime, 3, 6, 427, 240, 2)
    Assert.near(
      runtime.viewport.pixelGrid.placement.scale,
      3,
      1e-9,
      "doubled density must present three host units per source pixel"
    )

    runtime.displayContext = ratioDisplayContext(1, 1280, 720)
    resize(game, 1280, 720)
    assertCameraFollowsAllocatedGrid(runtime, 3, 3, 427, 240, 1)
  end)
end

T.tests.staged_map_camera_reuses_the_published_grid_projection = function()
  withProductionRuntime(function(game)
    local runtime = game.runtime
    resize(game, 1366, 768)
    Assert.notNil(
      runtime.viewport.pixelGrid,
      "the live viewport must publish its source grid before staging a swap"
    )
    runtime.fieldPixelScale:zoomIn()
    runtime:applyFieldPixelScaleChange()
    local grid = runtime.viewport.pixelGrid
    local nominal = runtime.fieldPixelScale:resolvedScale()

    local player = runtime.player
    local resolution = {
      destinationMap = runtime.runtimeMap,
      fieldX = player.fieldX,
      fieldZ = player.fieldZ,
      surfaceId = player.surfaceId,
      worldY = player.worldY,
    }
    local coordinator =
      assert(runtime.worldSwapCoordinator, "the field runtime must own its world-swap coordinator")
    local previousFade = runtime.transition.fadeAlpha
    runtime.transition.fadeAlpha = 1
    local preparedOk, prepared = pcall(function()
      return coordinator:prepare(resolution, "south")
    end)
    if not preparedOk then
      runtime.transition.fadeAlpha = previousFade
      error(prepared, 0)
    end
    local swapOk, swapError = pcall(function()
      local camera = assert(prepared.camera, "a staged swap must publish its replacement camera")
      Assert.near(
        camera.projectionAspect,
        grid.allocationWidth / grid.allocationHeight,
        1e-9,
        "the staged camera must project the allocated source aspect"
      )
      Assert.near(
        camera.zoom,
        192 / grid.allocationHeight,
        1e-9,
        "the staged camera must zoom to the allocated source height"
      )
      Assert.near(
        camera.projectionAspect,
        runtime.camera.projectionAspect,
        1e-12,
        "the staged and live cameras must agree exactly at one grid"
      )
      Assert.near(
        camera.zoom,
        runtime.camera.zoom,
        1e-12,
        "the staged and live cameras must agree exactly at one grid"
      )
      Assert.equal(
        runtime.fieldPixelScale:resolvedScale(),
        nominal,
        "staging a swap must not disturb the manual scale offset"
      )
      coordinator:commit(resolution, "south", prepared)
      Assert.equal(runtime.camera, camera, "committing the swap must install the staged camera")
      Assert.near(
        runtime.camera.projectionAspect,
        grid.allocationWidth / grid.allocationHeight,
        1e-9,
        "the committed camera must keep the allocated source aspect"
      )
      Assert.near(
        runtime.camera.zoom,
        192 / grid.allocationHeight,
        1e-9,
        "the committed camera must keep the allocated source zoom"
      )
    end)
    if not swapOk then
      pcall(function()
        coordinator:abort(resolution, prepared)
      end)
      runtime.transition.fadeAlpha = previousFade
      error(swapError, 0)
    end
    runtime.transition.fadeAlpha = previousFade
  end)
end

T.tests.field_presentation_publishes_one_scale_authority = function()
  Assert.isTrue(type(FieldPresentation.fieldScale) == "table", "field presentation must publish scale tuning")
  Assert.equal(FieldPresentation.fieldScale.baseCameraZoom, 1)
  Assert.equal(FieldPresentation.fieldScale.minCameraZoom, 0.5)
  Assert.equal(FieldPresentation.fieldScale.maxCameraZoom, 1.5)
  Assert.equal(FieldPresentation.fieldScale.referenceHeight, 600)
  Assert.equal(FieldPresentation.fieldScale.resizeCompensation, 0.7)

  withProductionRuntime(function(game)
    local runtime = game.runtime
    local scale = runtime.fieldPixelScale
    Assert.notNil(scale, "FieldRuntime must publish its scale authority")
    local before = scale:resolvedScale()
    scale:zoomIn()
    Assert.equal(scale:resolvedScale(), before + 1, "the scale control must move one integer level")
    runtime:applyFieldPixelScaleChange()
    Assert.near(
      (runtime.viewport.referenceFrame.height / 192) * runtime.camera.zoom,
      scale:resolvedScale(),
      1e-9,
      "refreshing the scale control must refresh the derived camera projection"
    )
  end)
end

return T
