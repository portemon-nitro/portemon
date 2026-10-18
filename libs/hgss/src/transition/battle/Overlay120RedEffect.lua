-- Owns one overlay 120 Red trainer intro task.
--
-- The native callback runs a six-phase task: allocate the window array with
-- a BG3 window, build the trainer sprite, enable planes, and register three
-- sub-workers (a window mosaic stepper and two HBlank palette-fade stages);
-- wait on the shared cover sub-runner; then step the sub-workers to
-- completion before window teardown, sprite deletion, and loader release.
-- The two fade stages flash then settle over their raw durations.

local Overlay114Sprites = require("libs.hgss.src.transition.battle.Overlay114Sprites")

local Overlay120RedEffect = {}
Overlay120RedEffect.__index = Overlay120RedEffect

-- Shared cover sub-runner arm counts. These are the helper's own setup
-- counts, not per-site cover durations, so no site timing is asserted here.
local COVER_ARM_COUNT = 8
local COVER_REVERSE_COUNT = 3

-- Raw two-stage HBlank fade words. The first word of each pair bounds the
-- host-visible steps; the native completion gate is hardware-side, so the
-- words are reported raw, never converted. The closing stage carries the
-- opening target word.
local FLASH_FADE_ARGS = { 0x1C, 1, 4, 0, 3, 0x2A }
local SETTLE_FADE_ARGS = { 0x18, 1, 4, 0, 3, 0x2A }

-- Pinned BG3 window extent behind the trainer sprite.
local WINDOW_WIDTH = 0x20
local WINDOW_HEIGHT = 0x20

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
function Overlay120RedEffect.new(route, resources)
  assert(type(route) == "table" and type(resources) == "table", "overlay 120 Red requires its selected route")
  assert(route.role == "red-trainer-transition", "overlay 120 Red family accepts its trainer role")
  local groups = assert(route.assetGroups, "overlay 120 Red route selects its resource groups")
  local spriteGroup = assert(groups.sprite, "overlay 120 Red route selects its trainer sprite")
  local palette = assert(resources[spriteGroup.palette], "Red sprite palette is loaded")
  local characters = assert(resources[spriteGroup.character], "Red sprite characters are loaded")
  local cells = assert(resources[spriteGroup.cell], "Red sprite cells are loaded")
  local animation = assert(resources[spriteGroup.animation], "Red sprite animation is loaded")
  assert(type(palette.colors) == "table", "Red sprite palette is decoded")
  assert(type(characters.tiles) == "string", "Red sprite characters are decoded")
  assert(type(cells.cells) == "table" and #cells.cells > 0, "Red sprite cells are decoded")
  local sequences = assert(animation.anims, "Red sprite animation carries decoded sequences")
  local frames = {}
  for _, sourceFrame in ipairs(assert(sequences[1].frames, "Red sprite animation has frames")) do
    local cell = assert(cells.cells[sourceFrame.cell + 1], "Red animation frame selects a decoded cell")
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
  local first = assert(frames[1], "Red sprite animation has a drawable frame")
  return setmetatable({
    _route = route,
    _resources = resources,
    _sourcePhase = 0,
    _sprites = {
      {
        -- The native sprite coordinates are not decoded, so this centered
        -- carrier is host-visible only; tests pin counts, phases, and raw
        -- vectors rather than coordinates.
        image = first.image,
        affine = first.affine,
        frames = frames,
        frameIndex = 1,
        frameTicks = 0,
        duration = first.duration,
        position = { x = 128 * 4096, y = 96 * 4096 },
        visible = false,
      },
    },
    _uploadedImages = nil,
    _imageHandles = nil,
    _coverWait = nil,
    _mosaicStep = 0,
    _fade = nil,
    _whiteFadeAlpha = 0,
    _marker = 0,
    _window = nil,
    _planesEnabled = false,
    _disposed = false,
    _started = false,
  }, Overlay120RedEffect)
end

---@param graphics table<string, function> host graphics namespace
function Overlay120RedEffect:prepareGraphics(graphics)
  assert(not self._disposed and not self._started, "overlay 120 Red uploads sprite images before start")
  assert(self._uploadedImages == nil, "overlay 120 Red sprite images upload exactly once")
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

function Overlay120RedEffect:start()
  assert(not self._started, "overlay 120 Red task starts exactly once")
  self._started = true
end

---@return boolean complete when the native task has released its resources
function Overlay120RedEffect:stepSourceTick()
  assert(not self._disposed, "disposed overlay 120 Red task cannot advance")
  assert(self._started, "overlay 120 Red task advances after start")
  local phase = self._sourcePhase
  if phase == 0 then
    self._planesEnabled = true
    self._window = { width = WINDOW_WIDTH, height = WINDOW_HEIGHT, plane = "bg3" }
    self._sprites[1].visible = true
    self._mosaicStep = 0
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
    self._marker = 0
    self._sourcePhase = 4
  elseif phase == 4 then
    -- The mosaic stepper advances alongside both fade stages; its native
    -- bounds are not decoded, so only monotonic progress is pinned here.
    self._mosaicStep = self._mosaicStep + 1
    if self._fade == nil then
      self._fade = { args = FLASH_FADE_ARGS, frame = 0 }
    end
    local fade = assert(self._fade)
    fade.frame = fade.frame + 1
    if fade.args == FLASH_FADE_ARGS then
      self._whiteFadeAlpha = math.min(fade.frame / fade.args[1], 1)
    else
      self._whiteFadeAlpha = math.max(1 - fade.frame / fade.args[1], 0)
    end
    if fade.frame >= fade.args[1] then
      if fade.args == FLASH_FADE_ARGS then
        self._fade = { args = SETTLE_FADE_ARGS, frame = 0 }
      else
        self._whiteFadeAlpha = 0
        self._sourcePhase = 5
      end
    end
  elseif phase == 5 then
    self:dispose()
    return true
  else
    error("overlay 120 Red task entered an unknown phase")
  end
  animateSprites(self._sprites, self._uploadedImages)
  return false
end

---@return table<string, unknown> current source task outputs for the native compositor
function Overlay120RedEffect:frame()
  assert(not self._disposed, "disposed overlay 120 Red task has no frame")
  return {
    sourcePhase = self._sourcePhase,
    routeKey = self._route.key,
    family = "red",
    sprites = self._sprites,
    window = self._window,
    mosaicStep = self._mosaicStep,
    paletteFade = self._fade,
    whiteFadeAlpha = self._whiteFadeAlpha,
    marker = self._marker,
    planesEnabled = self._planesEnabled,
    coverWait = self._coverWait,
    requiresCurrentFieldLayers = true,
    ownsResources = not self._disposed and self._resources ~= nil,
  }
end

function Overlay120RedEffect:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._sprites = {}
  self._resources = nil
  self._coverWait = nil
  self._fade = nil
  self._window = nil
  if self._imageHandles ~= nil then
    for _, image in ipairs(self._imageHandles) do
      image:release()
    end
  end
  self._uploadedImages = nil
  self._imageHandles = nil
end

return Overlay120RedEffect
