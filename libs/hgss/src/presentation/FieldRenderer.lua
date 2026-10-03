-- Adapts HGSS field presentation state into the frame consumed by
-- the concrete Nintendo DS LÖVE renderer.

local FieldLightProfile = require("libs.assets.src.field.FieldLightProfile")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")

---@class FieldRenderer
---@field gxRenderer GxRenderer
---@field stats table<string, unknown>
---@field sceneColor GxRenderer.Canvas?
---@field renderState GxRenderer.Canvas?
---@field _ownsRenderer boolean
---@field _queueScratch RenderQueueScratch
---@field clearColor number[]?
local FieldRenderer = {}
FieldRenderer.__index = FieldRenderer

-- Selects the active time-of-day lighting record from a runtime render
-- environment: the normalized lighting profile plus the optional
-- presentation time override. Needs only environment state, never scene
-- geometry or map identity.
---@param renderEnvironment table<string, unknown>
---@return table<string, unknown>?
local function selectedLighting(renderEnvironment)
  local profile = renderEnvironment.lighting
  if profile == nil or profile.records == nil then
    return nil
  end
  return FieldLightProfile.select(profile, renderEnvironment.fieldTimeSeconds or FieldLightProfile.DEFAULT_TIME_SECONDS)
end

---@param opts table<string, unknown>?
---@return FieldRenderer
function FieldRenderer.new(opts)
  opts = opts or {}
  local gxRenderer = opts.gxRenderer
  local ownsRenderer = gxRenderer == nil
  if gxRenderer == nil then
    local backendOpts = {}
    for key, value in pairs(opts) do
      backendOpts[key] = value
    end
    if backendOpts.translucencyMode == nil then
      backendOpts.translucencyMode = GxRenderer.TRANSLUCENCY_EXACT
    end
    gxRenderer = GxRenderer.new(backendOpts)
  end
  return setmetatable({
    gxRenderer = gxRenderer,
    stats = gxRenderer.stats,
    _ownsRenderer = ownsRenderer,
    clearColor = opts.clearColor,
    _queueScratch = RenderQueue.newScratch(),
  }, FieldRenderer)
end

---@param renderEnvironment table<string, unknown> runtime lighting, edge-color, and fog state; a full scene runtime stays structurally valid here
---@param camera table<string, unknown>
---@param worldParts table[][]?
---@param spriteItems table[]?
---@param viewport table<string, unknown>
---@param alpha number
---@param presentationPixelScale integer?
function FieldRenderer:draw(renderEnvironment, camera, worldParts, spriteItems, viewport, alpha, presentationPixelScale)
  assert(type(renderEnvironment) == "table", "field render environment is required")
  assert(type(camera) == "table", "field presentation camera is required")
  assert(type(camera.far) == "number" and camera.far > 0, "FieldRenderer requires camera.far to be a positive number")
  local viewMatrix = camera:view(alpha)
  local worldProjection = camera:projection()
  local billboardProjection = camera:billboardProjection()
  local queue = RenderQueue.buildInto(worldParts or {}, viewMatrix, self._queueScratch)
  self.gxRenderer:draw({
    lighting = selectedLighting(renderEnvironment),
    edgeColors = renderEnvironment.edgeColors,
    fog = renderEnvironment.fog,
    viewMatrix = viewMatrix,
    cameraZoom = camera.zoom,
    presentationPixelScale = presentationPixelScale,
    worldProjection = worldProjection,
    billboardProjection = billboardProjection,
    clearColor = self.clearColor,
    queue = queue,
    spriteItems = spriteItems,
    viewport = viewport,
  })
  self.sceneColor = self.gxRenderer.sceneColor
  self.renderState = self.gxRenderer.renderState
end

function FieldRenderer:release()
  if self._ownsRenderer then
    self.gxRenderer:release()
    self._ownsRenderer = false
  end
end

return FieldRenderer
