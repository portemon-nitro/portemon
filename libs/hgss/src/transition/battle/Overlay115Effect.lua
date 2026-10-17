-- Runs the pinned leaders encounter tasks from `src/field/encounter_effect_leaders.c`.

local Overlay114Sprites = require("libs.hgss.src.transition.battle.Overlay114Sprites")

local Overlay115Effect = {}
Overlay115Effect.__index = Overlay115Effect

local function newParticleOwner()
  return {
    mode = false,
    waitState = 0,
    setupRequested = false,
    setupDone = false,
    graphicsReady = false,
    resource = nil,
    emitters = {},
    resourceLoads = 0,
    resourceFrees = 0,
  }
end

local FX32 = 4096

---@param value integer
---@return integer
local function roundFx(value)
  return math.floor((value + 2048) / FX32)
end

---@param numerator integer
---@param denominator integer
---@return integer
local function fxDivide(numerator, denominator)
  assert(denominator ~= 0, "overlay 115 fixed-point denominator is nonzero")
  return (math.modf(numerator * FX32 / denominator))
end

---@param value unknown
---@param name string
---@return integer
local function integer(value, name)
  assert(type(value) == "number" and value % 1 == 0, name .. " is an integer source value")
  return value
end

---@param reference unknown
---@param resources table<string, unknown>
---@return table<string, unknown>
local function loaded(reference, resources)
  assert(type(reference) == "string" and reference ~= "", "overlay 115 asset reference is semantic")
  local value = resources[reference]
  assert(type(value) == "table", "overlay 115 selected resource is loaded: " .. reference)
  return value
end

---@param group unknown
---@param resources table<string, unknown>
---@return { palette: { colors: { r: integer, g: integer, b: integer }[] }, characters: { depth: integer, tiles: string }, cell: { cells: { objs: { tile: integer, width: integer, height: integer, x: integer, y: integer, palette: integer, flipH: boolean?, flipV: boolean? }[] }[] }, animation: { anims: { frames: { cell: integer, translateX: number, translateY: number, scaleX: number, scaleY: number, rotation: number, duration: integer }[] }[] } }
local function spriteResources(group, resources)
  assert(type(group) == "table", "overlay 115 sprite quartet is declared")
  return {
    palette = loaded(group.palette, resources),
    characters = loaded(group.character, resources),
    cell = loaded(group.cell, resources),
    animation = loaded(group.animation, resources),
  }
end

---@param route table<string, unknown>
---@param resources table<string, unknown>
---@param group table<string, unknown>
---@param name string
---@param x integer
---@param y integer
---@param visible boolean
---@param sequence integer selected sprite animation sequence
---@param spriteCache table<unknown, unknown[]> per-group frame caches owned by the caller
---@return table<string, unknown>
local function makeSprite(route, resources, group, name, x, y, visible, sequence, spriteCache)
  local source = spriteResources(group, resources)
  local groupCache = spriteCache[group]
  if groupCache == nil then
    groupCache = {}
    spriteCache[group] = groupCache
  end
  local frameCache = groupCache[sequence or 1]
  if frameCache == nil then
    local animations = assert(source.animation.anims, "overlay 115 animation carries decoded sequences")
    local animation = assert(animations[sequence or 1], "overlay 115 sprite animation has its selected sequence")
    frameCache = {}
    for _, frame in ipairs(animation.frames) do
      local cell = assert(source.cell.cells[frame.cell + 1], "overlay 115 animation selects a decoded cell")
      frameCache[#frameCache + 1] = {
        image = Overlay114Sprites.renderCell(source.characters, source.palette, cell, 0),
        affine = {
          translateX = frame.translateX,
          translateY = frame.translateY,
          scaleX = frame.scaleX,
          scaleY = frame.scaleY,
          rotation = frame.rotation,
        },
        duration = frame.duration,
      }
    end
    groupCache[sequence or 1] = frameCache
  end
  local first = assert(frameCache[1], "overlay 115 sprite animation has a drawable frame")
  return {
    name = name,
    sourceRoute = route.key,
    image = first.image,
    affine = first.affine,
    frames = frameCache,
    frameIndex = 1,
    frameTicks = 0,
    duration = first.duration,
    position = { x = x * FX32, y = y * FX32 },
    visible = visible,
  }
end

---@param start integer
---@param finish integer
---@param duration integer
---@return table<string, integer>
local function newInterpolation(start, finish, duration)
  return { start = start, finish = finish, duration = duration, tick = 0, value = start }
end

---@param task table<string, integer>
---@return integer
---@return boolean
local function stepInterpolation(task)
  task.value = task.start + math.modf(task.tick * (task.finish - task.start) / task.duration)
  task.tick = task.tick + 1
  if task.tick > task.duration then
    task.tick = task.duration
    return task.finish, true
  end
  return task.value, false
end

---@param start integer
---@param finish integer
---@param velocity integer
---@param duration integer
---@return table<string, integer>
local function newQuadratic(start, finish, velocity, duration)
  local remaining = finish - start - roundFx(velocity * duration * FX32)
  local numerator = roundFx(remaining * 8192)
  local acceleration = fxDivide(numerator, duration * duration * FX32)
  return {
    start = start,
    finish = finish,
    velocity = velocity,
    acceleration = acceleration,
    duration = duration,
    tick = 0,
    value = start,
  }
end

---@param task table<string, integer>
---@return integer
---@return boolean
local function stepQuadratic(task)
  local tick = task.tick
  local linear = roundFx(task.velocity * tick * FX32)
  local square = tick * tick * FX32
  local curved = roundFx(task.acceleration * square)
  task.value = task.start + linear + fxDivide(curved, 8192)
  task.tick = tick + 1
  if task.tick > task.duration then
    task.tick = task.duration
    return task.value, true
  end
  return task.value, false
end

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
      sprite.imageHandle = uploadedImages[frame.image]
      sprite.affine = frame.affine
      sprite.duration = frame.duration
    end
  end
end

---@param edge integer current source wipe edge
---@return table[] native 256x192 scanline spans
local function zigzagRows(edge)
  local rows = {}
  for y = 0, 191 do
    local offset = math.floor((y % 8) * 16 / 8)
    if math.floor(y / 8) % 2 ~= 0 then
      offset = 16 - offset
    end
    rows[y + 1] = { { math.max(0, edge - offset), 256 } }
  end
  return rows
end

---@param route table<string, unknown> source-normalized route
---@param resources table<string, unknown> prepared immutable source assets
---@param context table<string, unknown>? captured semantic launch context
---@param _ table<string, unknown>? unused source callback services
---@return table<string, unknown>
function Overlay115Effect.new(route, resources, context, _)
  assert(type(route) == "table" and type(resources) == "table", "overlay 115 requires its selected route and resources")
  local task = assert(route.task, "overlay 115 route carries its source intro task")
  local groups = assert(route.assetGroups, "overlay 115 route carries normalized asset groups")
  local state = {
    route = route,
    resources = resources,
    groups = groups,
    task = task,
    phase = "new",
    sprites = {},
    imageHandles = {},
    uploadedImages = {},
    disposed = false,
    started = false,
    complete = false,
    sourceTick = 0,
  }
  if task.kind == "overlay115-gym-rival-intro" then
    assert(
      route.role == "trainer-transition" or route.role == "rival-transition",
      "gym task matches a native trainer or rival role"
    )
    assert(
      integer(task.parameters.endXFx32, "gym leader endpoint") == 214 * FX32,
      "gym leader uses the native 214 pixel endpoint"
    )
    state.kind = "gym-rival"
    spriteResources(groups.record, resources)
    spriteResources(groups.fixedSprite, resources)
    loaded(assert(groups.background).palette, resources)
    loaded(groups.background.character, resources)
    loaded(groups.background.map, resources)
  elseif task.kind == "overlay115-elite-intro" then
    assert(route.role == "trainer-intro", "Elite Four task matches the native trainer intro role")
    local gender = assert(context and context.playerGender, "Elite Four intro requires captured player trainer gender")
    assert(gender == "male" or gender == "female", "captured trainer gender selects an authored source variant")
    state.kind = "elite"
    state.gender = gender
    spriteResources(assert(groups.spriteVariants)[gender], resources)
    spriteResources(groups.opponent, resources)
    spriteResources(groups.nameplate, resources)
    spriteResources(groups.fixedSprite, resources)
    local particles = assert(groups.particles, "Elite Four intro declares both particle resources")
    local intro = loaded(particles.intro, resources)
    local followup = loaded(particles.followup, resources)
    assert(
      intro.format == "APS12_1" and followup.format == "APS12_1",
      "elite particle groups are decoded APS 12.1 resources"
    )
    integer(task.parameters.shakeTicks, "Elite Four source shake duration")
    state._particles = newParticleOwner()
  else
    error("overlay 115 received an unknown normalized intro task", 2)
  end
  local effect = setmetatable(state, Overlay115Effect)
  if state.kind == "gym-rival" then
    effect:_createGymSprites()
  else
    effect:_createEliteSprites()
  end
  return effect
end

---@param graphics table<string, function> host graphics namespace
function Overlay115Effect:prepareGraphics(graphics)
  assert(not self.disposed and self.started == false, "overlay 115 uploads graphics before start")
  assert(type(graphics.newImage) == "function" and love.image ~= nil, "overlay 115 sprites require LÖVE image upload")
  local uploaded, handles = {}, {}
  local ok, result = pcall(function()
    for _, sprite in ipairs(self.sprites) do
      for _, frame in ipairs(sprite.frames) do
        local sourceImage = frame.image
        if uploaded[sourceImage] == nil then
          local imageData = love.image.newImageData(sourceImage.width, sourceImage.height)
          for y = 0, sourceImage.height - 1 do
            for x = 0, sourceImage.width - 1 do
              local offset = (y * sourceImage.width + x) * 4
              imageData:setPixel(
                x,
                y,
                string.byte(sourceImage.pixels, offset + 1) / 255,
                string.byte(sourceImage.pixels, offset + 2) / 255,
                string.byte(sourceImage.pixels, offset + 3) / 255,
                string.byte(sourceImage.pixels, offset + 4) / 255
              )
            end
          end
          local image = assert(graphics.newImage(imageData), "graphics driver uploads an overlay 115 cell")
          image:setFilter("nearest", "nearest")
          uploaded[sourceImage] = image
          handles[#handles + 1] = image
        end
      end
    end
  end)
  if not ok then
    for _, image in ipairs(handles) do
      image:release()
    end
    error(result, 0)
  end
  self.uploadedImages = uploaded
  self.imageHandles = handles
  for _, sprite in ipairs(self.sprites) do
    sprite.imageHandle = uploaded[sprite.image]
  end
end

function Overlay115Effect:start()
  assert(not self.disposed and not self.started, "overlay 115 source task starts once")
  self.started = true
  self.phase = 0
end

---@return boolean complete when the native task has cleaned up its temporary state
function Overlay115Effect:stepSourceTick()
  assert(self.started and not self.disposed, "overlay 115 advances only while active")
  assert(not self.complete, "completed overlay 115 task cannot advance")
  self.sourceTick = self.sourceTick + 1
  if self.kind == "gym-rival" then
    self:_stepGymRival()
  else
    self:_stepElite()
  end
  if not self.complete then
    animateSprites(self.sprites, self.uploadedImages)
  end
  return self.complete
end

---@return table<string, unknown> current source task outputs for the native compositor
function Overlay115Effect:frame()
  assert(not self.disposed, "disposed overlay 115 task has no frame")
  return {
    sourcePhase = self.phase,
    sourceTick = self.sourceTick,
    routeKey = self.route.key,
    family = self.kind,
    sprites = self.sprites,
    screenBrightness = self.brightness,
    paletteFade = self.paletteFade,
    whiteFadeAlpha = self.whiteFadeAlpha,
    background = self.background,
    blend = self.blend,
    window = self.window,
    wipe = self.wipe,
    particleMode = self.particleMode,
    particleSystem = self._particles and {
      mode = self._particles.mode,
      setupDone = self._particles.setupDone,
      graphicsReady = self._particles.graphicsReady,
      resource = self._particles.resource,
      emitters = self._particles.emitters,
      resourceLoads = self._particles.resourceLoads,
      resourceFrees = self._particles.resourceFrees,
      rendererSupport = "APS simulation and Nitro 3D particle drawing are unavailable",
    } or nil,
    requiresCurrentFieldLayers = true,
  }
end

function Overlay115Effect:dispose()
  if self.disposed then
    return
  end
  self:_release()
  self.disposed = true
  self.phase = "disposed"
end

function Overlay115Effect:_stepGymRival()
  local state = self.phase
  if state == 0 then
    self.phase = 1
  elseif state == 1 then
    self:_startFlash()
    self.phase = 2
  elseif state == 2 then
    if self:_stepFlash() then
      self.phase = 3
    end
  elseif state == 3 then
    self.background = { group = self.groups.background, priority = 1, visible = true }
    self.wipe = { duration = 6, period = 8, width = 16, insidePlanes = 31, outsidePlanes = 23, frame = 0 }
    self._wipe = newInterpolation(255, 0, 6)
    self.wipe.rows = zigzagRows(255)
    self._scrolling = true
    self._scroll = 0
    self.phase = 4
  elseif state == 4 then
    local _, done = stepInterpolation(self._wipe)
    self.wipe.frame = self._wipe.tick
    self.wipe.rows = zigzagRows(self._wipe.value)
    if done then
      self.wipe = nil
      self._wipe = nil
      self._timer = 10
      self.phase = 5
    end
  elseif state == 5 then
    self._timer = self._timer - 1
    if self._timer < 0 then
      self.objVisible = true
      if self:_stepScaleSprites(72, 74) then
        self.phase = 6
      end
    end
  elseif state == 6 then
    self._slide = newQuadratic(272 * FX32, self.task.parameters.endXFx32, -64 * FX32, 4)
    self.sprites[1].visible = true
    self.sprites[1].priority = 1
    self:_setPosition(self.sprites[1], self._slide.value, 66 * FX32)
    self.phase = 7
  elseif state == 7 then
    local x, done = stepQuadratic(self._slide)
    self:_setPosition(self.sprites[1], x, 66 * FX32)
    if done then
      self.phase = 8
    end
  elseif state == 8 then
    self._brightness = newInterpolation(0, 16, 3)
    self._timer = 10
    self.phase = 9
  elseif state == 9 then
    self._timer = self._timer - 1
    if self._timer < 0 then
      local value, done = stepInterpolation(self._brightness)
      self.brightness = value
      if done then
        self._brightness = nil
        self.blend = { brightness = -14, planes = { "bg0", "backdrop" } }
        self.background.scrollX = -((self._slide.value / FX32) - 92)
        self.phase = 10
      end
    end
  elseif state == 10 then
    self._brightness = newInterpolation(16, 0, 3)
    self.phase = 11
  elseif state == 11 then
    local value, done = stepInterpolation(self._brightness)
    self.brightness = value
    if done then
      self._brightness = nil
      self._timer = 26
      self.phase = 12
    end
  elseif state == 12 then
    self._timer = self._timer - 1
    if self._timer < 0 then
      self.phase = 13
    end
  elseif state == 13 then
    self.paletteFade = { color = "white", duration = 15, frame = 0 }
    self._fadeTick = 0
    self.phase = 14
  elseif state == 14 then
    self._fadeTick = self._fadeTick + 1
    self.paletteFade.frame = self._fadeTick
    self.whiteFadeAlpha = math.min(1, self._fadeTick / self.paletteFade.duration)
    if self._fadeTick > self.paletteFade.duration then
      self.phase = 15
    end
  elseif state == 15 then
    self.brightness = 16
    self.complete = true
    self:_release()
  else
    error("overlay 115 gym task entered an unknown native state")
  end
  if self._scrolling and not self.complete then
    self.background.scrollX = self._scroll
    self._scroll = (self._scroll + 30) % 512
  end
end

function Overlay115Effect:_createGymSprites()
  local spriteCache = {}
  self.sprites = {
    makeSprite(self.route, self.resources, self.groups.record, "trainer", 272, 66, false, 1, spriteCache),
  }
  for index = 1, 4 do
    local star = makeSprite(
      self.route,
      self.resources,
      self.groups.fixedSprite,
      "scale-" .. index,
      72,
      74,
      false,
      index < 4 and 2 or 1,
      spriteCache
    )
    star.affine =
      { translateX = 0, translateY = 0, scaleX = index == 4 and 1 or 2, scaleY = index == 4 and 1 or 2, rotation = 0 }
    self.sprites[#self.sprites + 1] = star
  end
  self.sprites[1].paletteBlend = 14
  self.window = { x = 0, y = 10, width = 16, height = 2, messageRoute = self.route.messages and self.route.messages[1] }
end

function Overlay115Effect:_stepScaleSprites(x, y)
  if self._scale == nil then
    self._scale = { count = 0, timer = 0, tasks = {} }
  end
  local scale = self._scale
  if scale.count < 4 then
    scale.timer = scale.timer - 1
    if scale.timer <= 0 then
      scale.timer = 3
      scale.count = scale.count + 1
    end
  end
  local done = scale.count == 4
  for index = 1, scale.count do
    local sprite = self.sprites[index + 1]
    sprite.visible = true
    self:_setPosition(sprite, x * FX32, y * FX32)
    if index < 4 then
      local task = scale.tasks[index]
      if task == nil then
        task = newInterpolation(2 * FX32, FX32, 6)
        scale.tasks[index] = task
      end
      local value, taskDone = stepInterpolation(task)
      sprite.affine = { translateX = 0, translateY = 0, scaleX = value / FX32, scaleY = value / FX32, rotation = 0 }
      if taskDone then
        sprite.visible = false
      else
        done = false
      end
    end
  end
  return done
end

function Overlay115Effect:_stepElite()
  local state = self.phase
  local particles = assert(self._particles)
  self:_stepParticleTasks()
  if state == 0 then
    self.phase = 1
  elseif state == 1 then
    self.sprites[1].paletteBlend = 14
    self.sprites[2].paletteBlend = 14
    self.objVisible = true
    particles.mode = true
    particles.waitState = 0
    self.particleMode = true
    self.phase = 2
  elseif state == 2 then
    self:_startFlash()
    self._timer = 0
    self.phase = 3
  elseif state == 3 then
    self._timer = self._timer + 1
    if self._timer == 8 then
      particles.setupRequested = true
    end
    if self:_stepFlash() then
      self.phase = 4
    end
  elseif state == 4 then
    if particles.setupDone then
      self:_loadParticles("intro")
      self.particleResource = "intro"
      self.blend = {
        source = "bg0",
        destinations = { "bg1", "bg2", "bg3", "obj" },
        sourceAlpha = 0,
        destinationAlpha = 8,
      }
      self.phase = 5
    end
  elseif state == 5 then
    self._playerSlide = newQuadratic(-128 * FX32, 56 * FX32, 80 * FX32, 6)
    self._opponentSlide = newQuadratic(384 * FX32, 200 * FX32, -80 * FX32, 6)
    self:_placeEliteSprites(self._playerSlide.value, self._opponentSlide.value)
    self.sprites[1].visible, self.sprites[2].visible = true, true
    self.sprites[3].visible, self.sprites[4].visible = true, true
    self.window =
      { x = 21, y = 13, width = 11, height = 2, messageRoute = self.route.messages and self.route.messages[1] }
    self._counter = 3
    self.phase = 6
  elseif state == 6 then
    if self._counter > 0 then
      self._counter = self._counter - 1
      if self._counter == 0 then
        self:_createParticleEmitters(3)
        self.planes = { bg0 = true, bg2 = true }
      end
    else
      self:_stepScaleSprites(128, 96)
    end
    local playerX = stepQuadratic(self._playerSlide)
    local opponentX, done = stepQuadratic(self._opponentSlide)
    self:_placeEliteSprites(playerX, opponentX)
    if done then
      self.phase = 7
    end
  elseif state == 7 then
    local scaleDone = self:_stepScaleSprites(128, 96)
    if scaleDone and self:_areParticlesDone() then
      self._brightness = newInterpolation(0, 16, 3)
      self:_freeParticles()
      self.phase = 8
    end
  elseif state == 8 then
    local value, done = stepInterpolation(self._brightness)
    self.brightness = value
    if done then
      self._brightness = nil
      self.sprites[1].paletteBlend = 0
      self.sprites[2].paletteBlend = 0
      self.sprites[3].animationSpeed = 2
      self.sprites[4].animationSpeed = 2
      self:_loadParticles("followup")
      self.particleResource = "followup"
      self.phase = 9
    end
  elseif state == 9 then
    self._brightness = newInterpolation(16, 0, 6)
    self:_createParticleEmitters(4)
    self.priority = { bg0 = 1 }
    self.phase = 10
  elseif state == 10 then
    local value, done = stepInterpolation(self._brightness)
    self.brightness = value
    if done then
      self._brightness = nil
      self._counter = 8
      self.phase = 11
    end
  elseif state == 11 then
    if self._counter > 0 then
      self._counter = self._counter - 1
    else
      local duration = self.task.parameters.shakeTicks
      self._shakeX = newQuadratic(0, -2 * FX32, 0, duration)
      self._shakeY = newQuadratic(0, -2 * FX32, 0, duration)
      self._shakeTick = 0
      self.phase = 12
    end
  elseif state == 12 then
    self._shakeTick = self._shakeTick + 1
    local x = stepQuadratic(self._shakeX)
    local y = stepQuadratic(self._shakeY)
    local playerX, opponentX = self._eliteBase.playerX, self._eliteBase.opponentX
    if math.floor(self._shakeTick / 2) % 2 == 0 then
      playerX, opponentX = playerX + x, opponentX - x
    else
      playerX, opponentX = playerX - x, opponentX + x
    end
    self:_placeEliteSprites(playerX, opponentX, y)
    if self._shakeX.tick > self._shakeX.duration then
      self._eliteBase.playerX, self._eliteBase.opponentX = playerX, opponentX
      self.planes = { bg2 = false }
      self._outwardX = newQuadratic(0, 192 * FX32, 24 * FX32, 16)
      self._outwardY = newQuadratic(0, 192 * FX32, 24 * FX32, 16)
      self.paletteFade = { color = "white", duration = 8, frame = 0 }
      self._fadeTick = 0
      self.phase = 13
    end
  elseif state == 13 then
    local x = stepQuadratic(self._outwardX)
    local y = stepQuadratic(self._outwardY)
    self._fadeTick = self._fadeTick + 1
    self.paletteFade.frame = self._fadeTick
    self.whiteFadeAlpha = math.min(1, self._fadeTick / self.paletteFade.duration)
    self:_placeEliteSprites(self._eliteBase.playerX - x, self._eliteBase.opponentX + x, y)
    if self._fadeTick > self.paletteFade.duration then
      self.phase = 14
    end
  elseif state == 14 then
    self.brightness = 16
    self:_freeParticles()
    if self.particleMode then
      particles.mode = false
    end
    self.particleMode = false
    self.complete = true
    self:_release()
  else
    error("overlay 115 Elite Four task entered an unknown native state")
  end
  if self.phase > 4 and self.phase < 14 then
    if particles.resource ~= nil then
      particles.updates = (particles.updates or 0) + 1
    end
  end
end

function Overlay115Effect:_stepParticleTasks()
  local particles = self._particles
  if not particles.mode then
    return
  end
  if particles.waitState == 0 then
    particles.waitState = 1
  elseif particles.waitState == 1 and particles.setupRequested then
    particles.graphicsReady = true
    particles.waitState = 2
  elseif particles.waitState == 2 then
    particles.setupDone = true
    particles.waitState = 3
  end
end

function Overlay115Effect:_loadParticles(name)
  local particles = self._particles
  assert(particles.mode and particles.setupDone, "native particle loading follows graphics setup")
  assert(particles.resource == nil, "native particle system has only one loaded set")
  local key = assert(self.groups.particles[name], "selected particle resource is declared")
  local data = loaded(key, self.resources)
  assert(data.format == "APS12_1", "transition particles use decoded APS 12.1 resources")
  particles.resource = name
  particles.resourceData = data
  particles.emitters = {}
  particles.resourceLoads = particles.resourceLoads + 1
  self.particleResource = name
end

function Overlay115Effect:_createParticleEmitters(count)
  local particles = self._particles
  assert(particles.resourceData ~= nil, "native emitter creation follows APS loading")
  assert(#particles.resourceData.emitters >= count, "APS declares every source emitter index")
  particles.emitters = {}
  for index = 1, count do
    particles.emitters[index] = { resourceIndex = index - 1, active = true }
  end
  particles.activeEmitterCount = count
end

function Overlay115Effect:_areParticlesDone()
  return (self._particles.activeEmitterCount or 0) == 0
end

function Overlay115Effect:_freeParticles()
  local particles = self._particles
  if particles.resource == nil then
    return
  end
  particles.resource = nil
  particles.resourceData = nil
  particles.emitters = {}
  particles.activeEmitterCount = 0
  particles.resourceFrees = particles.resourceFrees + 1
  self.particleResource = nil
end

function Overlay115Effect:_createEliteSprites()
  local spriteCache = {}
  self.sprites = {
    makeSprite(
      self.route,
      self.resources,
      self.groups.spriteVariants[self.gender],
      "player",
      -128,
      92,
      false,
      1,
      spriteCache
    ),
    makeSprite(self.route, self.resources, self.groups.opponent, "opponent", 384, 92, false, 1, spriteCache),
    makeSprite(self.route, self.resources, self.groups.nameplate, "player-nameplate", -112, 96, false, 1, spriteCache),
    makeSprite(self.route, self.resources, self.groups.nameplate, "opponent-nameplate", 368, 96, false, 1, spriteCache),
  }
  for index = 1, 4 do
    local star = makeSprite(
      self.route,
      self.resources,
      self.groups.fixedSprite,
      "scale-" .. index,
      128,
      96,
      false,
      index < 4 and 2 or 1,
      spriteCache
    )
    star.affine =
      { translateX = 0, translateY = 0, scaleX = index == 4 and 1 or 2, scaleY = index == 4 and 1 or 2, rotation = 0 }
    self.sprites[#self.sprites + 1] = star
  end
  self._eliteBase = { playerX = 56 * FX32, opponentX = 200 * FX32 }
  self.window = nil
end

---@param playerX integer
---@param opponentX integer
---@param shakeY integer?
function Overlay115Effect:_placeEliteSprites(playerX, opponentX, shakeY)
  local y = (shakeY or 0) + 92 * FX32
  self:_setPosition(self.sprites[1], playerX, y)
  self:_setPosition(self.sprites[2], opponentX, y)
  self:_setPosition(self.sprites[3], playerX + 16 * FX32, y + 4 * FX32)
  self:_setPosition(self.sprites[4], opponentX - 16 * FX32, y + 4 * FX32)
end

function Overlay115Effect:_startFlash()
  self._flash = { state = 0, frame = 0, start = 0, finish = 0, done = false }
end

function Overlay115Effect:_stepFlash()
  local task = assert(self._flash)
  if task.state == 0 then
    task.state = 1
  elseif task.state == 1 then
    task.start, task.finish, task.frame, task.state = 0, 16, 0, 2
  elseif task.state == 2 then
    self.brightness = task.start + (task.finish - task.start) * task.frame / 3
    self.whiteFadeAlpha = self.brightness / 16
    task.frame = task.frame + 1
    if task.frame > 3 then
      task.state = 3
    end
  elseif task.state == 3 then
    task.start, task.finish, task.frame, task.state = 16, 0, 0, 4
  elseif task.state == 4 then
    self.brightness = task.start + (task.finish - task.start) * task.frame / 3
    self.whiteFadeAlpha = self.brightness / 16
    task.frame = task.frame + 1
    if task.frame > 3 then
      task.state = 5
    end
  elseif task.state == 5 then
    task.done = true
  else
    error("overlay 115 flash task entered an unknown native state")
  end
  return task.done
end

---@param sprite table<string, unknown>
---@param x integer
---@param y integer
function Overlay115Effect:_setPosition(sprite, x, y)
  sprite.position = { x = x, y = y }
end

function Overlay115Effect:_release()
  if self.kind == "elite" then
    self:_freeParticles()
    self._particles.mode = false
    self.particleMode = false
  end
  self.sprites = {}
  for _, image in ipairs(self.imageHandles) do
    image:release()
  end
  self.imageHandles = {}
  self.uploadedImages = {}
  self.resources = {}
  self._scale = nil
  self._slide = nil
  self._wipe = nil
  self._brightness = nil
  self._flash = nil
  self.wipe = nil
  self._scrolling = false
  self.window = nil
  self.background = nil
  self.blend = nil
end

return Overlay115Effect
