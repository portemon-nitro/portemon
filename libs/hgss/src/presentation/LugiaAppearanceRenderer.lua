-- Lazily realizes the original Whirl Islands eye-glimmer and Lugia
-- cinematic models and draws their live scene poses.

local LegendCutsceneModels = require("libs.hgss.src.presentation.LegendCutsceneModels")

local LugiaAppearanceRenderer = {}
LugiaAppearanceRenderer.__index = LugiaAppearanceRenderer

---@class LugiaAppearanceRenderer
---@field cacheFs CacheFs?
---@field imageAssets table<string, unknown>
---@field pool table<string, unknown>?
---@field definitions table<string, unknown>?
---@field instances table<string, unknown>?
---@field sequence integer?
---@field versionId string?
---@field lastFrames table<string, integer>?
---@field _cinematicEnvironment table<string, unknown>?
---@field new fun(cacheFs: CacheFs, imageAssets: table<string, unknown>): LugiaAppearanceRenderer
---@field drawItems fun(self: LugiaAppearanceRenderer, status: table<string, unknown>): table<string, unknown>[]
---@field cinematicEnvironment fun(self: LugiaAppearanceRenderer, base: table<string, unknown>): table<string, unknown>
---@field release fun(self: LugiaAppearanceRenderer)
---@field dispose fun(self: LugiaAppearanceRenderer)

-- The cinematic application's own edge marking (RGB555) and fog-less pipeline.
local CINEMATIC_EDGE_COLORS = { [0] = 0x0000, 0x7A89, 0x1084, 0x1084, 0x1084, 0x1084, 0x1084, 0x1084 }

local MODEL_KEYS = { "eyeGlimmer", "cinematic.lugia.0", "cinematic.lugia.1" }

local INSTANCE_SPECS = {
  { name = "eyeGlimmer", roles = { "eye.color", "eye.pattern", "eye.joint" } },
  {
    name = "cinematic.lugia",
    source = "cinematic.lugia.0",
    roles = { "lugia.joint", "lugia.color", "lugia.srt", "lugia.pattern" },
    loopMode = "once",
  },
  { name = "cinematic.lugia.far", source = "cinematic.lugia.1", roles = { "lugia.far.joint" }, loopMode = "once" },
}

-- The retail eye glimmer draws above and behind the dancer circle, in tiles.
local EYE_OFFSET = { x = 0, y = 100 / 16, z = -350 / 16 }

---@param cacheFs CacheFs
---@param imageAssets table<string, unknown>
---@return LugiaAppearanceRenderer
function LugiaAppearanceRenderer.new(cacheFs, imageAssets)
  assert(cacheFs and cacheFs.loadLua, "Lugia renderer requires the generated cache")
  assert(imageAssets, "Lugia renderer requires the shared image owner")
  return setmetatable({ cacheFs = cacheFs, imageAssets = imageAssets }, LugiaAppearanceRenderer)
end

function LugiaAppearanceRenderer:_build(sequence, versionId)
  local set = LegendCutsceneModels.buildSet(self.cacheFs, self.imageAssets, {
    definitionKind = "lugia_appearance",
    keyPrefix = "field%-effect:lugia%-appearance:",
    definitionKeyPrefix = "field-effect:lugia:",
    modelKeys = MODEL_KEYS,
    label = "Lugia",
  })
  self.pool, self.definitions = set.pool, set.definitions
  self.instances =
    LegendCutsceneModels.buildInstances({ pool = set.pool, definitions = set.definitions }, INSTANCE_SPECS, "Lugia")
  self.sequence, self.versionId, self.lastFrames = sequence, versionId, { eye = 0, lugia = 0, far = 0 }
end

---@param status table<string, unknown>
---@return table<string, unknown>[]
function LugiaAppearanceRenderer:drawItems(status)
  if status.active ~= true then
    self:release()
    return {}
  end
  if self.sequence ~= status.sequence or self.versionId ~= status.versionId then
    self:release()
    self:_build(status.sequence, assert(status.versionId))
  end
  local output, origin = {}, assert(status.origin)
  local instances, frames = assert(self.instances), assert(self.lastFrames)
  local advance, addDraws = LegendCutsceneModels.advance, LegendCutsceneModels.addDraws
  local effectTag = "lugia_appearance"
  if status.eyeGlimmerFrame ~= nil then
    local eyeFrame = assert(status.eyeGlimmerFrame)
    local eye = assert(instances.eyeGlimmer)
    advance(eye, frames.eye, eyeFrame)
    frames.eye = eyeFrame
    addDraws(output, eye, {
      x = origin.x + EYE_OFFSET.x,
      y = origin.y + EYE_OFFSET.y,
      z = origin.z + EYE_OFFSET.z,
    }, "eye_glimmer", effectTag)
  end
  if status.cinematicShot == "lugia" then
    local modelFrame = assert(status.cinematicModelFrame)
    local near = assert(instances["cinematic.lugia"])
    advance(near, frames.lugia, modelFrame)
    frames.lugia = modelFrame
    addDraws(output, near, origin, "lugia_cinematic", effectTag)
    local far = assert(instances["cinematic.lugia.far"])
    advance(far, frames.far, modelFrame)
    frames.far = modelFrame
    addDraws(output, far, origin, "lugia_cinematic_far", effectTag)
  end
  return output
end

-- The field render environment with the cinematic application's edge colors
-- and no fog: the cinematic is not drawn through the map's own atmosphere.
---@param base table<string, unknown>
---@return table<string, unknown>
function LugiaAppearanceRenderer:cinematicEnvironment(base)
  self._cinematicEnvironment = self._cinematicEnvironment or {}
  return LegendCutsceneModels.cinematicEnvironment(self._cinematicEnvironment, base, CINEMATIC_EDGE_COLORS)
end

function LugiaAppearanceRenderer:release()
  if self.pool ~= nil then
    self.pool:release()
  end
  self.pool, self.definitions, self.instances = nil, nil, nil
  self.sequence, self.versionId, self.lastFrames = nil, nil, nil
end

function LugiaAppearanceRenderer:dispose()
  self:release()
  self.cacheFs = nil
end

return LugiaAppearanceRenderer
