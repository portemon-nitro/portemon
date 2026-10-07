-- Adapts HGSS field presentation state into the frame consumed by
-- the concrete Nintendo DS LÖVE renderer.

local FieldLightProfile = require("libs.assets.src.field.FieldLightProfile")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")

---@class FieldRenderer
---@field gxRenderer GxRenderer
---@field stats table<string, unknown>
---@field _ownsRenderer boolean
---@field _queueScratch RenderQueueScratch
---@field _frame table<string, unknown> retained Gx frame record, overwritten every draw
---@field _lightingProfile table<string, unknown>? profile identity of the cached lighting selection
---@field _lightingBucket integer? effective half-second bucket of the cached lighting selection
---@field _lightingRecord table<string, unknown>? cached lighting selection
---@field clearColor number[]?
local FieldRenderer = {}
FieldRenderer.__index = FieldRenderer

-- Selects the active time-of-day lighting record from a runtime render
-- environment: the normalized lighting profile plus the optional
-- presentation time override. Needs only environment state, never scene
-- geometry or map identity. The selection is cached by profile identity
-- plus the effective half-second bucket and reused while both are stable.
---@param renderEnvironment table<string, unknown>
---@return table<string, unknown>?
function FieldRenderer:_selectedLighting(renderEnvironment)
  local profile = renderEnvironment.lighting
  if profile == nil or profile.records == nil then
    return nil
  end
  local timeSeconds = renderEnvironment.fieldTimeSeconds or FieldLightProfile.DEFAULT_TIME_SECONDS
  local bucket = FieldLightProfile.bucket(timeSeconds)
  if self._lightingProfile == profile and self._lightingBucket == bucket then
    return self._lightingRecord
  end
  local record = FieldLightProfile.select(profile, timeSeconds)
  self._lightingProfile = profile
  self._lightingBucket = bucket
  self._lightingRecord = record
  return record
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
    gxRenderer = GxRenderer.new(backendOpts)
  end
  return setmetatable({
    gxRenderer = gxRenderer,
    stats = gxRenderer.stats,
    _ownsRenderer = ownsRenderer,
    clearColor = opts.clearColor,
    _queueScratch = RenderQueue.newScratch(),
    _frame = {},
    _lightingProfile = nil,
    _lightingBucket = nil,
    _lightingRecord = nil,
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
  local viewMatrix = camera:view(alpha)
  local worldProjection = camera:projection()
  local billboardProjection = camera:billboardProjection()
  local queue = RenderQueue.buildInto(worldParts or {}, viewMatrix, self._queueScratch)
  -- The retained Gx frame record is overwritten every draw: no per-frame
  -- frame allocation remains on the steady 3D path. Assigning nil clears
  -- the optional presentation scale on sprite-less frames.
  local frame = self._frame
  frame.lighting = self:_selectedLighting(renderEnvironment)
  frame.edgeColors = renderEnvironment.edgeColors
  frame.fog = renderEnvironment.fog
  frame.viewMatrix = viewMatrix
  frame.cameraZoom = camera.zoom
  frame.presentationPixelScale = presentationPixelScale
  frame.worldProjection = worldProjection
  frame.billboardProjection = billboardProjection
  frame.clearColor = self.clearColor
  frame.queue = queue
  frame.spriteItems = spriteItems
  frame.viewport = viewport
  self.gxRenderer:draw(frame)
end

function FieldRenderer:release()
  if self._ownsRenderer then
    self.gxRenderer:release()
    self._ownsRenderer = false
  end
end

return FieldRenderer
