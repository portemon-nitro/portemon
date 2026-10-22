-- Owns one overlay 119 trainer-fallback affine-wipe task and its two wipe sprites.
--
-- The native family runs an eight-phase task: allocate and load the
-- route-selected sprite set with engine-A planes on, wait on the shared
-- cover sub-runner, then drive the two-sprite affine wipe with blend,
-- brightness, and two-stage palette-fade layers before releasing everything
-- at completion. Per-callback motion differences beyond the pinned fade
-- words are not decoded, so all three fallback roles share this worker.

local Overlay114Sprites = require("libs.hgss.src.transition.battle.Overlay114Sprites")

local Overlay119Effect = {}
Overlay119Effect.__index = Overlay119Effect

local FALLBACK_ROLES = {
  ["plain-trainer-fallback"] = true,
  ["water-trainer-fallback"] = true,
  ["cave-trainer-fallback"] = true,
}

-- Raw palette-fade words from the pinned callback pair. The first word
-- bounds the host-visible steps; the native completion gate is
-- hardware-side, so the words are reported raw, never converted.
local OPEN_FADE_ARGS = { 8, 1, 4, 0, 3, 0x18 }
local CLOSE_FADE_ARGS = { 8, 1, 4, 0, 3, 0x12 }

-- Shared cover sub-runner arm counts. These are the helper's own setup
-- counts, not per-site cover durations, so no site timing is asserted here.
local COVER_ARM_COUNT = 8
local COVER_REVERSE_COUNT = 3

---@param sprites table[]
---@param uploadedImages table<unknown, unknown> image records to uploaded host handles
local function animateSprites(sprites, uploadedImages)
  for _, sprite in ipairs(sprites) do
    sprite.frameTicks = sprite.frameTicks + 1
    if sprite.frameTicks >= sprite.duration then
      sprite.frameTicks = 0
      sprite.frameIndex = sprite.frameIndex % #sprite.frames + 1
      local frame = sprite.frames[sprite.frameIndex]
      sprite.image = frame.image
      sprite.imageHandle = uploadedImages and uploadedImages[frame.image] or nil
      sprite.affine = frame.affine
      sprite.duration = frame.duration
    end
  end
end

---@param route table<string, unknown> source-normalized route
---@param resources table<string, unknown> decoded route resources
---@return table<string, unknown>
function Overlay119Effect.new(route, resources)
  assert(type(route) == "table" and type(resources) == "table", "overlay 119 requires its selected route and resources")
  assert(FALLBACK_ROLES[route.role] == true, "overlay 119 family accepts its three semantic fallback roles")
  local group = assert(route.assetGroups and route.assetGroups.sprite, "overlay 119 route selects its sprite resources")
  local palette = assert(resources[group.palette], "selected sprite palette is loaded")
  local characters = assert(resources[group.character], "selected sprite characters are loaded")
  local cells = assert(resources[group.cell], "selected sprite cells are loaded")
  local animation = assert(resources[group.animation], "selected sprite animation is loaded")
  assert(type(palette.colors) == "table", "overlay 119 sprite palette is decoded")
  assert(type(characters.tiles) == "string", "overlay 119 sprite characters are decoded")
  assert(type(cells.cells) == "table" and #cells.cells > 0, "overlay 119 sprite cells are decoded")
  local sequences = assert(animation.anims, "overlay 119 sprite animation carries decoded sequences")
  assert(type(sequences) == "table" and #sequences > 0, "overlay 119 sprite animation has a drawable sequence")
  local frames = {}
  for _, sourceFrame in ipairs(assert(sequences[1].frames, "overlay 119 sprite animation has frames")) do
    local cell = assert(cells.cells[sourceFrame.cell + 1], "overlay 119 animation frame selects a decoded cell")
    frames[#frames + 1] = {
      image = Overlay114Sprites.renderCell(characters, palette, cell, 0),
      affine = {
        translateX = sourceFrame.translateX,
        translateY = sourceFrame.translateY,
        scaleX = sourceFrame.scaleX,
        scaleY = sourceFrame.scaleY,
        rotation = sourceFrame.rotation,
      },
      duration = sourceFrame.duration,
    }
  end
  local first = assert(frames[1], "overlay 119 sprite animation has a drawable frame")
  local sprites = {}
  for index = 1, 2 do
    sprites[index] = {
      -- Wipe carriers enter from opposite edges and cross the field. Their
      -- native OBJ coordinates are not decoded, so these host-visible
      -- endpoints are carriers only; behavior tests pin counts, phases,
      -- and raw vectors rather than coordinates.
      image = first.image,
      affine = first.affine,
      frames = frames,
      frameIndex = 1,
      frameTicks = 0,
      duration = first.duration,
      position = { x = (index == 1 and -64 or 320) * 4096, y = 96 * 4096 },
      visible = false,
    }
  end
  return setmetatable({
    _route = route,
    _resources = resources,
    _sourcePhase = 0,
    _sprites = sprites,
    _uploadedImages = nil,
    _imageHandles = nil,
    _coverWait = nil,
    _fade = nil,
    _sweep = 0,
    _blendAlpha = 0,
    _brightness = 0,
    _planesEnabled = false,
    _disposed = false,
    _started = false,
  }, Overlay119Effect)
end

---@param graphics table<string, function> host graphics namespace
function Overlay119Effect:prepareGraphics(graphics)
  assert(not self._disposed and not self._started, "overlay 119 uploads sprite images before start")
  assert(self._uploadedImages == nil, "overlay 119 sprite images upload exactly once")
  local records = {}
  for _, sprite in ipairs(self._sprites) do
    for _, frame in ipairs(sprite.frames) do
      records[#records + 1] = frame.image
    end
  end
  local uploaded, handles = Overlay114Sprites.uploadImages(graphics, records)
  self._uploadedImages = uploaded
  self._imageHandles = handles
  for _, sprite in ipairs(self._sprites) do
    sprite.imageHandle = uploaded[sprite.image]
  end
end

function Overlay119Effect:start()
  assert(not self._started, "overlay 119 source task starts exactly once")
  self._started = true
end

---@return boolean complete when the native task has released its resources
function Overlay119Effect:stepSourceTick()
  assert(not self._disposed, "disposed overlay 119 task cannot advance")
  assert(self._started, "overlay 119 source task advances after start")
  local phase = self._sourcePhase
  if phase == 0 then
    self._planesEnabled = true
    self._sourcePhase = 1
  elseif phase == 1 then
    self._coverWait = { stage = 0, tick = 0 }
    self._sourcePhase = 2
  elseif phase == 2 then
    local cover = assert(self._coverWait)
    cover.tick = cover.tick + 1
    if cover.stage == 0 and cover.tick >= COVER_ARM_COUNT then
      cover.stage = 1
      cover.tick = 0
    elseif cover.stage == 1 and cover.tick >= COVER_REVERSE_COUNT then
      self._coverWait = nil
      self._sourcePhase = 3
    end
  elseif phase == 3 then
    if self._fade == nil then
      for _, sprite in ipairs(self._sprites) do
        sprite.visible = true
      end
      self._fade = { args = OPEN_FADE_ARGS, frame = 0 }
    end
    self._fade.frame = self._fade.frame + 1
    local progress = math.min(self._fade.frame / self._fade.args[1], 1)
    self._blendAlpha = math.floor(progress * 16 + 0.5)
    self._sweep = progress / 2
    self:_placeSweepSprites()
    if self._fade.frame >= self._fade.args[1] then
      self._sourcePhase = 4
    end
  elseif phase == 4 then
    self._brightness = 16
    self._sourcePhase = 5
  elseif phase == 5 then
    if self._fade == nil or self._fade.args ~= CLOSE_FADE_ARGS then
      self._fade = { args = CLOSE_FADE_ARGS, frame = 0 }
    end
    self._fade.frame = self._fade.frame + 1
    local progress = math.min(self._fade.frame / self._fade.args[1], 1)
    self._sweep = 0.5 + progress / 2
    self:_placeSweepSprites()
    self._brightness = 16 - math.floor(progress * 16 + 0.5)
    if self._fade.frame >= self._fade.args[1] then
      self._sourcePhase = 6
    end
  elseif phase == 6 then
    self._brightness = 0
    self._sourcePhase = 7
  elseif phase == 7 then
    self:dispose()
    return true
  else
    error("overlay 119 source task entered an unknown phase")
  end
  animateSprites(self._sprites, self._uploadedImages)
  return false
end

function Overlay119Effect:_placeSweepSprites()
  local left = math.floor((-64 + self._sweep * 384) * 4096)
  local right = math.floor((320 - self._sweep * 384) * 4096)
  self._sprites[1].position = { x = left, y = 96 * 4096 }
  self._sprites[2].position = { x = right, y = 96 * 4096 }
end

---@return table<string, unknown> current source task outputs for the native compositor
function Overlay119Effect:frame()
  assert(not self._disposed, "disposed overlay 119 task has no frame")
  return {
    sourcePhase = self._sourcePhase,
    routeKey = self._route.key,
    family = "trainer-fallback",
    sprites = self._sprites,
    blendAlpha = self._blendAlpha,
    brightness = self._brightness,
    paletteFade = self._fade,
    planesEnabled = self._planesEnabled,
    coverWait = self._coverWait,
    requiresCurrentFieldLayers = true,
    ownsResources = not self._disposed and self._resources ~= nil,
  }
end

function Overlay119Effect:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._sprites = {}
  self._resources = nil
  self._coverWait = nil
  self._fade = nil
  if self._imageHandles ~= nil then
    for _, image in ipairs(self._imageHandles) do
      image:release()
    end
  end
  self._uploadedImages = nil
  self._imageHandles = nil
end

return Overlay119Effect
