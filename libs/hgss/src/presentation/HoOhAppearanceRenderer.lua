-- Lazily realizes the original Ho-Oh cutscene models and draws their live scene poses.

local ImageSampling = require("libs.nds.src.love.ImageSampling")

local LegendCutsceneModels = require("libs.hgss.src.presentation.LegendCutsceneModels")

local HoOhAppearanceRenderer = {}
HoOhAppearanceRenderer.__index = HoOhAppearanceRenderer

---@class HoOhAppearanceRenderer
---@field cacheFs CacheFs?
---@field imageAssets table<string, unknown>
---@field pool table<string, unknown>?
---@field definitions table<string, unknown>?
---@field instances table<string, unknown>?
---@field sequence integer?
---@field versionId string?
---@field lastFrames table<string, integer>?
---@field _cinematicEnvironment table<string, unknown>?
---@field leafHandles table<string, table<integer, table<string, unknown>>>?
---@field new fun(cacheFs: CacheFs, imageAssets: table<string, unknown>): HoOhAppearanceRenderer
---@field drawItems fun(self: HoOhAppearanceRenderer, status: table<string, unknown>): table<string, unknown>[]
---@field backdropCopies fun(self: HoOhAppearanceRenderer, mapDraws: table<string, unknown>[], versionId: string): table<string, unknown>[]
---@field cinematicEnvironment fun(self: HoOhAppearanceRenderer, base: table<string, unknown>): table<string, unknown>
---@field release fun(self: HoOhAppearanceRenderer)
---@field dispose fun(self: HoOhAppearanceRenderer)

-- The cinematic application's own edge marking (RGB555) and fog-less pipeline.
local CINEMATIC_EDGE_COLORS = { [0] = 0x0000, 0x1084, 0x1084, 0x1084, 0x1084, 0x1084, 0x1084, 0x1084 }

-- The Bell Tower sky wall the cutscene cameras look at (HeartGold: building
-- 187, 68 tiles wide). Wide displays see past its ends, so the cutscene repeats
-- it once to each side.
local BACKDROP_WALLS = { heartgold = { modelKeyPrefix = "outdoor:187:", width = 68 } }

local MODEL_KEYS = {
  "bellRising",
  "bellShimmer",
  "cornerBells",
  "birdApproach",
  "wavesEffect",
  "cinematic.first.0",
  "cinematic.first.1",
  "cinematic.first.2",
  "cinematic.second.0",
  "cinematic.second.1",
  "cinematic.second.2",
}

---@param versionId string
---@return table<integer, table<string, unknown>>
local function instanceSpecs(versionId)
  local specs = {
    { name = "bellRising", roles = { "bell.rise.joint", "bell.rise.pattern", "bell.rise.srt" }, loopMode = "once" },
    { name = "bellShimmer", roles = { "bell.shimmer.joint", "bell.shimmer.srt" } },
    { name = "birdApproach", roles = { "bird.joint", "bird.color", "bird.pattern" } },
    { name = "wavesEffect", roles = { "waves.joint", "waves.srt" } },
  }
  for index = 1, (versionId == "heartgold" and 4 or 2) do
    specs[#specs + 1] = { name = "cornerBells" .. index, source = "cornerBells", roles = { "corner_bells.srt" } }
  end
  for variant = 0, 2 do
    local first = "cinematic.first." .. variant
    specs[#specs + 1] = {
      name = first,
      roles = { first .. ".trs", first .. ".color", first .. ".pattern", first .. ".texsrt" },
      loopMode = "once",
    }
    local second = "cinematic.second." .. variant
    specs[#specs + 1] =
      { name = second, roles = { second .. ".trs", second .. ".color", second .. ".texsrt" }, loopMode = "once" }
  end
  return specs
end

---@param cacheFs CacheFs
---@param imageAssets table<string, unknown>
---@return HoOhAppearanceRenderer
function HoOhAppearanceRenderer.new(cacheFs, imageAssets)
  assert(cacheFs and cacheFs.loadLua, "Ho-Oh renderer requires the generated cache")
  assert(imageAssets, "Ho-Oh renderer requires the shared image owner")
  return setmetatable({ cacheFs = cacheFs, imageAssets = imageAssets }, HoOhAppearanceRenderer)
end

function HoOhAppearanceRenderer:_build(sequence, versionId)
  local set = LegendCutsceneModels.buildSet(self.cacheFs, self.imageAssets, {
    definitionKind = "ho_oh_appearance",
    keyPrefix = "field%-effect:ho%-oh%-appearance:",
    definitionKeyPrefix = "field-effect:ho-oh:",
    modelKeys = MODEL_KEYS,
    label = "Ho-Oh",
  })
  local pool, definitions, record = set.pool, set.definitions, set.record

  local leafHandles = {}
  local leavesOk, leavesErr = pcall(function()
    if versionId == "heartgold" then
      local leaves = assert(record.leaves, "HeartGold Ho-Oh record has no leaf overlay")
      for _, layerName in ipairs({ "bg3", "bg2" }) do
        local layer = assert(leaves[layerName], "Ho-Oh leaf layer is missing: " .. layerName)
        local handles = {}
        for frameIndex, frame in ipairs(layer.frames) do
          handles[frameIndex] = assert(pool:sharedImage(frame.path, "repeat", "repeat"))
        end
        leafHandles[layerName] = handles
      end
    end
  end)
  if not leavesOk then
    pool:release()
    error(leavesErr, 0)
  end

  local instances =
    LegendCutsceneModels.buildInstances({ pool = pool, definitions = definitions }, instanceSpecs(versionId), "Ho-Oh")
  self.pool, self.definitions, self.instances, self.leafHandles = pool, definitions, instances, leafHandles
  self.sequence, self.versionId, self.lastFrames =
    sequence, versionId, { bell = 0, loop = 0, shimmer = 0, corners = 0, bird = 0, waves = 0 }
  self.bellAnimationSet = "rise"
end

-- First tile origin at or before `edge` on a grid of `period` anchored at `origin`.
local function tileStart(origin, edge, period)
  return origin - math.ceil((origin - edge) / period) * period
end

---@param status table<string, unknown>
---@param viewport table<string, unknown>
function HoOhAppearanceRenderer:drawLeaves(status, viewport)
  if status.leavesActive ~= true then
    return
  end
  assert(self.versionId == "heartgold" and self.leafHandles, "HeartGold leaf overlay is not loaded")
  local bounds = assert(viewport.worldViewport)
  local frameRect = assert(viewport.referenceFrame)
  local scale = frameRect.width / 256
  local tileSize = 256 * scale
  local frame = assert(status.leafFrame)
  assert(type(frame) == "number" and frame >= 0 and frame % 1 == 0, "leaf frame is invalid")
  local frameIndex = math.floor(frame / 6) % 6 + 1
  local scroll = frame % 256
  local graphics = love.graphics
  graphics.push("all")
  graphics.setScissor(bounds.x, bounds.y, bounds.width, bounds.height)
  graphics.setColor(1, 1, 1, 1)
  for _, layerName in ipairs({ "bg3", "bg2" }) do
    local handle = assert(self.leafHandles[layerName][frameIndex])
    local scrollX = layerName == "bg2" and ((256 - scroll) % 256) or scroll
    local scrollY = (256 - scroll) % 256
    local startX = tileStart(frameRect.x - scrollX * scale, bounds.x, tileSize)
    local startY = tileStart(frameRect.y - scrollY * scale, bounds.y, tileSize)
    for y = startY, bounds.y + bounds.height - 1, tileSize do
      for x = startX, bounds.x + bounds.width - 1, tileSize do
        ImageSampling.draw(graphics, handle, nil, x, y, 0, scale, scale)
      end
    end
  end
  graphics.pop()
end

---@param status table<string, unknown>
---@return table<string, unknown>[]
function HoOhAppearanceRenderer:drawItems(status)
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
  local effectTag = "ho_oh_appearance"
  if status.bellStage ~= nil then
    local bellFrame = assert(status.bellFrame)
    local rising = assert(instances.bellRising)
    local loopFrame = status.loopFrame
    if loopFrame ~= nil and self.bellAnimationSet == "rise" then
      for _, role in ipairs({ "bell.rise.joint", "bell.rise.pattern", "bell.rise.srt" }) do
        assert(rising:stop(role) == 1, "Ho-Oh rise animation is attached")
      end
      for _, role in ipairs({ "bell.loop.joint", "bell.loop.pattern", "bell.loop.srt" }) do
        rising:play(role, { loopMode = "loop" })
      end
      self.bellAnimationSet = "loop"
    end
    if self.bellAnimationSet == "rise" then
      advance(rising, frames.bell, bellFrame)
      frames.bell = bellFrame
    else
      advance(rising, frames.loop, assert(loopFrame))
      frames.loop = loopFrame
    end
    if status.bellVisible == true and status.shimmerFrame == nil then
      addDraws(output, rising, origin, "clear_bell_rising", effectTag)
    end
    if status.shimmerFrame ~= nil then
      local shimmerFrame = assert(status.shimmerFrame)
      advance(assert(instances.bellShimmer), frames.shimmer, shimmerFrame)
      frames.shimmer = shimmerFrame
      addDraws(output, instances.bellShimmer, origin, "clear_bell_shimmer", effectTag)
      if status.shimmerClearBellOnly ~= true then
        local offsets = assert(status.cornerOffsets)
        for index, offset in ipairs(offsets) do
          local corners = assert(instances["cornerBells" .. index])
          advance(corners, frames.corners, shimmerFrame)
          local position = { x = origin.x + offset[1], y = origin.y + offset[2], z = origin.z + offset[3] }
          addDraws(output, corners, position, "corner_bells_" .. index, effectTag)
        end
        frames.corners = shimmerFrame
      end
    end
  elseif status.birdFrame ~= nil then
    -- The model is the legend's cry ring: the legend itself is the map actor.
    local ringFrame = status.birdRingFrame
    if ringFrame ~= nil then
      local bird = assert(instances.birdApproach)
      advance(bird, frames.bird, ringFrame)
      frames.bird = ringFrame
      local versionId = assert(status.versionId)
      local ringPosition = {
        x = origin.x,
        y = origin.y + (versionId == "heartgold" and 2.5 or 0),
        z = origin.z - (versionId == "heartgold" and 1 or 17.5),
      }
      addDraws(output, bird, ringPosition, "ho_oh_approach", effectTag)
    end
  elseif status.cinematicShot == "first" or status.cinematicShot == "second" then
    local shot = assert(status.cinematicShot)
    local variant = assert(status.cinematicVariant)
    assert(variant >= 0 and variant <= 2 and variant % 1 == 0, "Ho-Oh cinematic variant is invalid")
    local name = "cinematic." .. shot .. "." .. variant
    local instance = assert(instances[name], "Ho-Oh cinematic model variant is missing")
    local frameKey = "cinematic:" .. name
    local modelFrame = assert(status.cinematicModelFrame)
    advance(instance, frames[frameKey] or 0, modelFrame)
    frames[frameKey] = modelFrame
    addDraws(output, instance, origin, "ho_oh_cinematic_" .. shot, effectTag)
  end
  if status.effectsActive == true and status.versionId == "soulsilver" then
    local effectFrame = assert(status.effectFrame)
    local waves = assert(instances.wavesEffect)
    advance(waves, frames.waves, effectFrame)
    frames.waves = effectFrame
    addDraws(output, waves, origin, "waves", effectTag)
  end
  return output
end

-- Copies of the map's sky wall one wall width to each side.
---@param mapDraws table<string, unknown>[]
---@param versionId string
---@return table<string, unknown>[]
function HoOhAppearanceRenderer:backdropCopies(mapDraws, versionId)
  local wall = BACKDROP_WALLS[versionId]
  local copies = {}
  if wall == nil then
    return copies
  end
  for _, item in ipairs(mapDraws) do
    local key = item.modelKey
    if type(key) == "string" and key:sub(1, #wall.modelKeyPrefix) == wall.modelKeyPrefix then
      for _, side in ipairs({ -1, 1 }) do
        local copy = {}
        for field, value in pairs(item) do
          copy[field] = value
        end
        local transform = { table.unpack(item.transform, 1, 16) }
        transform[13] = transform[13] + side * wall.width
        copy.transform = transform
        copies[#copies + 1] = copy
      end
    end
  end
  return copies
end

-- The field render environment with the cinematic application's edge colors
-- and no fog: the cinematic is not drawn through the map's own atmosphere.
---@param base table<string, unknown>
---@return table<string, unknown>
function HoOhAppearanceRenderer:cinematicEnvironment(base)
  self._cinematicEnvironment = self._cinematicEnvironment or {}
  return LegendCutsceneModels.cinematicEnvironment(self._cinematicEnvironment, base, CINEMATIC_EDGE_COLORS)
end

function HoOhAppearanceRenderer:release()
  if self.pool ~= nil then
    self.pool:release()
  end
  self.pool, self.definitions, self.instances, self.leafHandles = nil, nil, nil, nil
  self.sequence, self.versionId, self.lastFrames = nil, nil, nil
end

function HoOhAppearanceRenderer:dispose()
  self:release()
  self.cacheFs = nil
end

return HoOhAppearanceRenderer
