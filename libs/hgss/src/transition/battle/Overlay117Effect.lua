-- Owns one overlay 117 Team Rocket transition task.
--
-- The native family has two shapes behind one loader. The intro callback
-- runs an eight-phase task with six affine sprites, a cover wait, an indexed
-- reveal through six slots, and a single palette fade before deleting its
-- sprites. The trainer callbacks are parameter blocks over a shared
-- thirteen-phase worker: sprite and background setup, blend ramp, windowed
-- trainer-name text, a counted background scroll, brightness work, a second
-- background retoggle, and a final fade to black before teardown. Route data
-- selects the shape: routes with a trainer record block run the worker,
-- routes with only a sprite set run the intro.

local Overlay114Sprites = require("libs.hgss.src.transition.battle.Overlay114Sprites")

local Overlay117Effect = {}
Overlay117Effect.__index = Overlay117Effect

-- Shared cover sub-runner arm counts. These are the helper's own setup
-- counts, not per-site cover durations, so no site timing is asserted here.
local COVER_ARM_COUNT = 8
local COVER_REVERSE_COUNT = 3

-- Raw palette-fade words from the pinned intro callback. The first word
-- bounds the host-visible steps; the native completion gate is
-- hardware-side, so the words are reported raw, never converted.
local INTRO_FADE_ARGS = { 0xC, 1, 4, 0, 3, 0x22 }

-- Raw worker counts and coefficients. Single-tick entries in the thirteen
-- states without decoded bodies are host handoffs documented as such.
local WORKER_SCROLL_COUNT = 12
local WORKER_GATE_COUNT = 13
local WORKER_BLEND_START = 2
local WORKER_BLEND_STEP = 4
local WORKER_BLEND_MAX = 0x10
local WORKER_BRIGHTNESS_ARGS = { 8, 0, 0x10, 0x1E }
local WORKER_BRIGHTNESS_SENTINEL = 0x14A5
local WORKER_FINAL_FADE_ARGS = { 4, 1, 0, 4, 0, 0x7FFF }

local INTRO_SPRITE_COUNT = 6
local INTRO_REVEAL_SLOTS = 6

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

---@param group table<string, string> semantic sprite resource references
---@param resources table<string, unknown> decoded route resources
---@param label string owner behind diagnostics
---@return table[] rendered sprite frames
local function renderFrames(group, resources, label)
  local palette = assert(resources[group.palette], label .. " sprite palette is loaded")
  local characters = assert(resources[group.character], label .. " sprite characters are loaded")
  local cells = assert(resources[group.cell], label .. " sprite cells are loaded")
  local animation = assert(resources[group.animation], label .. " sprite animation is loaded")
  assert(type(palette.colors) == "table", label .. " sprite palette is decoded")
  assert(type(characters.tiles) == "string", label .. " sprite characters are decoded")
  assert(type(cells.cells) == "table" and #cells.cells > 0, label .. " sprite cells are decoded")
  local sequences = assert(animation.anims, label .. " sprite animation carries decoded sequences")
  local frames = {}
  for _, sourceFrame in ipairs(assert(sequences[1].frames, label .. " sprite animation has frames")) do
    local cell = assert(cells.cells[sourceFrame.cell + 1], label .. " animation frame selects a decoded cell")
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
  assert(#frames > 0, label .. " sprite animation has a drawable frame")
  return frames
end

---@param route table<string, unknown> source-normalized route
---@param resources table<string, unknown> decoded route resources
---@return table<string, unknown>
function Overlay117Effect.new(route, resources)
  assert(type(route) == "table" and type(resources) == "table", "overlay 117 requires its selected route and resources")
  assert(
    route.role == "trainer-transition" and route.task == nil,
    "overlay 117 family accepts trainer routes without an intro task"
  )
  local groups = assert(route.assetGroups, "overlay 117 route selects its resource groups")
  if groups.record ~= nil then
    assert(type(resources[groups.background.palette]) == "table", "rocket background palette is loaded")
    local maps = groups.background.maps or groups.background.map
    assert(maps ~= nil, "rocket background map selection is declared")
    local frames = renderFrames(groups.record, resources, "rocket trainer")
    local sprites = {
      {
        image = frames[1].image,
        affine = frames[1].affine,
        frames = frames,
        frameIndex = 1,
        frameTicks = 0,
        duration = frames[1].duration,
        position = { x = 128 * 4096, y = 96 * 4096 },
        visible = false,
      },
    }
    return setmetatable({
      _route = route,
      _resources = resources,
      _shape = "worker",
      _sourcePhase = 0,
      _sprites = sprites,
      _uploadedImages = nil,
      _imageHandles = nil,
      _coverWait = nil,
      _scroll = nil,
      _blendAlpha = WORKER_BLEND_START,
      _brightness = nil,
      _fade = nil,
      _planesEnabled = false,
      _disposed = false,
      _started = false,
    }, Overlay117Effect)
  end
  local spriteGroup = assert(groups.sprite, "overlay 117 intro route selects its sprite set")
  local frames = renderFrames(spriteGroup, resources, "rocket intro")
  local first = frames[1]
  local sprites = {}
  for index = 1, INTRO_SPRITE_COUNT do
    sprites[index] = {
      image = first.image,
      affine = first.affine,
      frames = frames,
      frameIndex = 1,
      frameTicks = 0,
      duration = first.duration,
      position = { x = (32 + (index - 1) * 38) * 4096, y = 96 * 4096 },
      visible = false,
    }
  end
  return setmetatable({
    _route = route,
    _resources = resources,
    _shape = "intro",
    _sourcePhase = 0,
    _sprites = sprites,
    _uploadedImages = nil,
    _imageHandles = nil,
    _coverWait = nil,
    _revealIndex = 0,
    _fade = nil,
    _planesEnabled = false,
    _disposed = false,
    _started = false,
  }, Overlay117Effect)
end

---@param graphics table<string, function> host graphics namespace
function Overlay117Effect:prepareGraphics(graphics)
  assert(not self._disposed and not self._started, "overlay 117 uploads sprite images before start")
  assert(self._uploadedImages == nil, "overlay 117 sprite images upload exactly once")
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

function Overlay117Effect:start()
  assert(not self._started, "overlay 117 source task starts exactly once")
  self._started = true
end

---@return boolean complete when the native task has released its resources
function Overlay117Effect:stepSourceTick()
  assert(not self._disposed, "disposed overlay 117 task cannot advance")
  assert(self._started, "overlay 117 source task advances after start")
  if self._shape == "intro" then
    return self:_stepIntro()
  end
  return self:_stepWorker()
end

---@return boolean complete
function Overlay117Effect:_stepIntro()
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
      self._revealIndex = 0
      self._sourcePhase = 3
    end
  elseif phase == 3 then
    -- The native handoff arms the reveal index before stepping slots; the
    -- per-slot pacing is data-driven and undecoded, so one slot advances
    -- per host-visible tick.
    self._sprites[self._revealIndex + 1].visible = true
    self._revealIndex = self._revealIndex + 1
    if self._revealIndex >= INTRO_REVEAL_SLOTS then
      self._fade = { args = INTRO_FADE_ARGS, frame = 0 }
      self._sourcePhase = 4
    end
  elseif phase == 4 then
    if self._fade == nil then
      self._fade = { args = INTRO_FADE_ARGS, frame = 0 }
    end
    self._fade.frame = self._fade.frame + 1
    if self._fade.frame >= self._fade.args[1] then
      self._sourcePhase = 5
    end
  elseif phase == 5 then
    -- Single-tick host handoff for the hardware palette-finish gate.
    self._sourcePhase = 6
  elseif phase == 6 then
    self._sourcePhase = 7
  elseif phase == 7 then
    self:dispose()
    return true
  else
    error("overlay 117 intro task entered an unknown phase")
  end
  animateSprites(self._sprites, self._uploadedImages)
  return false
end

---@return boolean complete
function Overlay117Effect:_stepWorker()
  local phase = self._sourcePhase
  if phase == 0 then
    self._planesEnabled = true
    for _, sprite in ipairs(self._sprites) do
      sprite.visible = true
    end
    self._sourcePhase = 1
  elseif phase == 1 then
    self._coverWait = { stage = 0, tick = 0 }
    self._sourcePhase = 2
  elseif phase == 2 then
    if self._scroll == nil then
      -- Raw background-scroll count from the pinned worker.
      self._scroll = { counter = WORKER_SCROLL_COUNT, offset = 0 }
    end
    local scroll = assert(self._scroll)
    scroll.counter = scroll.counter - 1
    -- The native scroll parks the background layers progressively; the host
    -- advances a linear offset over the raw count.
    scroll.offset = (WORKER_SCROLL_COUNT - math.max(scroll.counter, 0)) * 4096
    if scroll.counter <= 0 then
      self._scroll = nil
      self._sourcePhase = 3
    end
  elseif phase == 3 then
    -- Wipe arm handoff for the hardware scanline pass.
    self._sourcePhase = 4
  elseif phase == 4 then
    -- Single-tick host handoff; the native state body is not decoded.
    self._sourcePhase = 5
  elseif phase == 5 then
    if self._scroll == nil then
      self._scroll = { counter = WORKER_GATE_COUNT, offset = 0 }
    end
    local scroll = assert(self._scroll)
    scroll.counter = scroll.counter - 1
    if scroll.counter <= 0 then
      self._scroll = nil
      self._sourcePhase = 6
    end
  elseif phase == 6 then
    self._blendAlpha = math.min(self._blendAlpha + WORKER_BLEND_STEP, WORKER_BLEND_MAX)
    if self._brightness == nil then
      self._brightness = { args = WORKER_BRIGHTNESS_ARGS, frame = 0, sentinel = WORKER_BRIGHTNESS_SENTINEL }
    end
    local brightness = assert(self._brightness)
    brightness.frame = math.min(brightness.frame + 1, brightness.args[1])
    if self._blendAlpha >= WORKER_BLEND_MAX and brightness.frame >= brightness.args[1] then
      self._sourcePhase = 7
    end
  elseif phase == 7 then
    -- Single-tick host handoff; the native state body is not decoded.
    self._sourcePhase = 8
  elseif phase == 8 then
    -- Background retoggle handoff.
    self._brightness = nil
    self._sourcePhase = 9
  elseif phase == 9 then
    -- Single-tick host handoff; the native state body is not decoded.
    self._sourcePhase = 10
  elseif phase == 10 then
    if self._fade == nil then
      self._fade = { args = WORKER_FINAL_FADE_ARGS, frame = 0 }
    end
    self._fade.frame = self._fade.frame + 1
    if self._fade.frame >= self._fade.args[1] then
      self._sourcePhase = 11
    end
  elseif phase == 11 then
    -- Single-tick host handoff for the hardware palette-finish gate.
    self._sourcePhase = 12
  elseif phase == 12 then
    self:dispose()
    return true
  else
    error("overlay 117 worker task entered an unknown phase")
  end
  animateSprites(self._sprites, self._uploadedImages)
  return false
end

---@return table<string, unknown> current source task outputs for the native compositor
function Overlay117Effect:frame()
  assert(not self._disposed, "disposed overlay 117 task has no frame")
  local output = {
    sourcePhase = self._sourcePhase,
    routeKey = self._route.key,
    shape = self._shape,
    sprites = self._sprites,
    coverWait = self._coverWait,
    planesEnabled = self._planesEnabled,
    requiresCurrentFieldLayers = true,
    ownsResources = not self._disposed and self._resources ~= nil,
  }
  if self._shape == "intro" then
    output.family = "rocket-intro"
    output.revealIndex = self._revealIndex
    output.paletteFade = self._fade
  else
    output.family = "rocket-trainer"
    -- Window geometry is not decoded; only the selected message route is
    -- reported. The renderer has no window consumer.
    output.window = { messageRoute = self._route.messages and self._route.messages[1] or nil }
    output.scroll = self._scroll
    output.blendAlpha = self._blendAlpha
    output.brightness = self._brightness
    output.paletteFade = self._fade
  end
  return output
end

function Overlay117Effect:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._sprites = {}
  self._resources = nil
  self._coverWait = nil
  self._scroll = nil
  self._brightness = nil
  self._fade = nil
  if self._imageHandles ~= nil then
    for _, image in ipairs(self._imageHandles) do
      image:release()
    end
  end
  self._uploadedImages = nil
  self._imageHandles = nil
end

return Overlay117Effect
