-- Owns one overlay 114 source task and its rendered OBJ cells.

local Overlay114Sprites = require("libs.hgss.src.transition.battle.Overlay114Sprites")

local Overlay114Effect = {}
Overlay114Effect.__index = Overlay114Effect

---@param start integer
---@param finish integer
---@param duration integer
---@return { start: integer, finish: integer, duration: integer, tick: integer, value: integer }
local function linearTask(start, finish, duration)
  assert(duration > 0, "overlay transition task has a positive source duration")
  return { start = start, finish = finish, duration = duration, tick = 0, value = start }
end

---@param task { start: integer, finish: integer, duration: integer, tick: integer, value: integer }
---@return integer value
---@return boolean done
local function stepLinear(task)
  task.value = task.start + math.modf(task.tick * (task.finish - task.start) / task.duration)
  task.tick = task.tick + 1
  if task.tick > task.duration then
    task.tick = task.duration
    return task.finish, true
  end
  return task.value, false
end

---@param value integer
---@return integer
local function roundFx(value)
  return math.floor((value + 2048) / 4096)
end

---@param numerator integer
---@param denominator integer
---@return integer
local function fxDivide(numerator, denominator)
  assert(denominator ~= 0, "source fixed-point division has a nonzero denominator")
  return (math.modf(numerator * 4096 / denominator))
end

---@param start integer
---@param finish integer
---@param initialVelocity integer
---@param duration integer
---@return { start: integer, finish: integer, initialVelocity: integer, acceleration: integer, duration: integer, tick: integer, value: integer }
local function quadraticTask(start, finish, initialVelocity, duration)
  assert(duration > 0, "overlay affine task has a positive source duration")
  local remaining = finish - start - roundFx(initialVelocity * duration * 4096)
  local numerator = roundFx(remaining * 8192)
  local denominator = duration * duration * 4096
  return {
    start = start,
    finish = finish,
    initialVelocity = initialVelocity,
    acceleration = fxDivide(numerator, denominator),
    duration = duration,
    tick = 0,
    value = start,
  }
end

---@param task { start: integer, finish: integer, initialVelocity: integer, acceleration: integer, duration: integer, tick: integer, value: integer }
---@return integer value
---@return boolean done
local function stepQuadratic(task)
  local tick = task.tick
  local duration = task.duration
  local linear = roundFx(task.initialVelocity * tick * 4096)
  local square = tick * tick * 4096
  local curved = roundFx(task.acceleration * square)
  local quadratic = fxDivide(curved, 8192)
  task.value = task.start + linear + quadratic
  task.tick = tick + 1
  if task.tick > duration then
    task.tick = duration
    return task.value, true
  end
  return task.value, false
end

---@param angle integer HGSS screen-wipe angle in 1/65536 turns
---@return integer Q12 tangent from the Nitro 1024-entry trig table resolution
local function tangentQ12(angle)
  local tableAngle = math.floor(angle / 16) * 16
  local radians = tableAngle * (2 * math.pi / 65536)
  local sine = math.floor(math.sin(radians) * 4096 + 0.5)
  local cosine = math.floor(math.cos(radians) * 4096 + 0.5)
  assert(cosine ~= 0, "source wipe tangent table has nonzero cosine")
  return (math.modf(sine * 4096 / cosine))
end

---@param tangent integer Q12 tangent
---@param distance integer scanline distance from center
---@return integer
local function multiplyTangent(tangent, distance)
  return math.floor(tangent * distance / 4096)
end

---@param kind "circle"|"mirrored-sector"
---@param step integer source fade step
---@param steps integer source fade step count
---@return table[] rows of zero or more [left,right) spans
local function makeWipeRows(kind, step, steps)
  local rows = {}
  if kind == "circle" then
    local radiusDelta = math.modf((0 - 256) * 128 / steps)
    local radius = math.floor((256 * 128 + radiusDelta * step) / 128)
    for y = 0, 191 do
      local distance = math.abs(y - 96)
      local spans = {}
      if distance < radius then
        local halfWidth = math.floor(math.sqrt(radius * radius - distance * distance))
        local left = math.max(0, 128 - halfWidth)
        local right = math.min(255, left + halfWidth * 2)
        if right > left then
          spans[1] = { left, right }
        end
      end
      rows[y + 1] = spans
    end
    return rows
  end

  assert(kind == "mirrored-sector", "overlay fade has a pinned source wipe shape")
  local phase = math.modf(0x1FFF * step / steps)
  local inverse = 0x3FFF - phase
  local tangent = tangentQ12(phase)
  local inverseTangent = tangentQ12(inverse)
  for y = 0, 95 do
    local distance = 96 - y
    local x0 = math.min(127, multiplyTangent(tangent, distance))
    local x1 = math.min(127, multiplyTangent(inverseTangent, distance))
    local spans = {
      { 128 - x1, 128 - x0 },
      { 128 + x0, 128 + x1 },
    }
    rows[y + 1] = spans
    rows[192 - y] = { { spans[1][1], spans[1][2] }, { spans[2][1], spans[2][2] } }
  end
  return rows
end

---@param mode integer
---@param offset integer
---@param loopCount integer
---@return { mode: integer, offset: integer, loopCount: integer, state: integer, loops: integer, output: { start: integer, finish: integer, duration: integer, tick: integer, value: integer }, movement: { start: integer, finish: integer, duration: integer, tick: integer, value: integer }|nil, complete: boolean, outputValue?: integer }
local function newChildTask(mode, offset, loopCount)
  return {
    mode = mode,
    offset = offset,
    loopCount = loopCount,
    state = 0,
    loops = 0,
    output = linearTask(0, 2, 8),
    movement = nil,
    complete = false,
  }
end

---@param task { mode: integer, offset: integer, loopCount: integer, state: integer, loops: integer, output: { start: integer, finish: integer, duration: integer, tick: integer, value: integer }, movement: { start: integer, finish: integer, duration: integer, tick: integer, value: integer }|nil, complete: boolean, outputValue?: integer }
---@return boolean
local function stepChildTask(task)
  if task.state == 0 then
    task.state = 1
  elseif task.state == 1 then
    task.movement = linearTask(0, task.mode, 3)
    task.state = 2
  elseif task.state == 2 then
    local _, done = stepLinear(assert(task.movement, "overlay child movement runs while assigned"))
    if done then
      task.movement = nil
      task.state = 3
    end
  elseif task.state == 3 then
    task.movement = linearTask(task.offset, 0, 3)
    task.state = 4
  elseif task.state == 4 then
    local _, done = stepLinear(assert(task.movement, "overlay child movement runs while assigned"))
    if done then
      task.movement = nil
      task.loops = task.loops + 1
      task.state = task.loops == task.loopCount and 5 or 1
    end
  elseif task.state == 5 then
    task.complete = true
  else
    error("overlay child task entered an unknown source state")
  end
  task.outputValue = stepLinear(task.output)
  if task.complete then
    return true
  end
  return false
end

---@param sprites table[]
---@param uploadedImages table<unknown, unknown>? image records to uploaded host handles
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
function Overlay114Effect.new(route, resources)
  assert(
    route.role == "generic-trainer-transition" or route.role == "generic-wild-transition",
    "overlay 114 family accepts its two semantic source roles"
  )
  local spriteData = Overlay114Sprites.createForRoute(route, resources)
  return setmetatable({
    _route = route,
    _resources = resources,
    _sourcePhase = 0,
    _spriteData = spriteData,
    _sprites = nil,
    _child = nil,
    _blendTask = nil,
    _paletteFade = nil,
    _affineTask = nil,
    _matrixTasks = nil,
    _matrices = nil,
    _wipe = nil,
    _uploadedImages = nil,
    _imageHandles = nil,
    _blendAlpha = 0,
    _paletteFadeAlpha = 0,
    _affineValue = 0,
    _disposed = false,
    _started = false,
  }, Overlay114Effect)
end

---@param graphics table<string, function> host graphics namespace
function Overlay114Effect:prepareGraphics(graphics)
  assert(not self._disposed, "disposed overlay task cannot upload sprites")
  assert(self._uploadedImages == nil, "overlay sprite images upload exactly once")
  assert(type(graphics.newImage) == "function" and love.image ~= nil, "overlay sprites require LÖVE image upload")
  local uploaded = {}
  local handles = {}
  local ok, result = pcall(function()
    for _, sourceSprite in ipairs(self._spriteData) do
      for _, frame in ipairs(sourceSprite.frames) do
        if uploaded[frame.image] == nil then
          local imageData = love.image.newImageData(frame.image.width, frame.image.height)
          for y = 0, frame.image.height - 1 do
            for x = 0, frame.image.width - 1 do
              local offset = (y * frame.image.width + x) * 4
              imageData:setPixel(
                x,
                y,
                string.byte(frame.image.pixels, offset + 1) / 255,
                string.byte(frame.image.pixels, offset + 2) / 255,
                string.byte(frame.image.pixels, offset + 3) / 255,
                string.byte(frame.image.pixels, offset + 4) / 255
              )
            end
          end
          local image = assert(graphics.newImage(imageData), "graphics driver returns an overlay sprite image")
          image:setFilter("nearest", "nearest")
          uploaded[frame.image] = image
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
  self._uploadedImages = uploaded
  self._imageHandles = handles
end

function Overlay114Effect:start()
  assert(not self._started, "overlay 114 source task starts exactly once")
  self._started = true
end

function Overlay114Effect:stepSourceTick()
  assert(not self._disposed, "disposed overlay 114 task cannot advance")
  assert(self._started, "overlay 114 source task advances after start")
  local phase = self._sourcePhase
  if phase == 0 then
    self._sprites = {}
    for index, sourceSprite in ipairs(self._spriteData) do
      self._sprites[index] = {
        image = sourceSprite.image,
        imageHandle = self._uploadedImages and self._uploadedImages[sourceSprite.image] or nil,
        affine = sourceSprite.affine,
        position = sourceSprite.position,
        frames = sourceSprite.frames,
        frameIndex = 1,
        frameTicks = 0,
        duration = sourceSprite.duration,
        visible = false,
      }
    end
    self._sourcePhase = 1
  elseif phase == 1 then
    self._child = newChildTask(1, -16, 2)
    self._sourcePhase = 2
  elseif phase == 2 then
    if stepChildTask(assert(self._child)) then
      self._child = nil
      self._sourcePhase = 3
    end
  elseif phase == 3 then
    for _, sprite in ipairs(assert(self._sprites)) do
      sprite.visible = true
    end
    if self._route.role == "generic-trainer-transition" then
      self._blendTask = linearTask(0, 16, 12)
    else
      self._matrixTasks = {
        quadraticTask(0, 0x80000, 410, 4),
        quadraticTask(0, 0xA0000, 410, 4),
      }
    end
    self._sourcePhase = 4
  elseif phase == 4 then
    if self._blendTask ~= nil then
      local value, done = stepLinear(self._blendTask)
      self._blendAlpha = value
      if done then
        self._blendTask = nil
        self._sourcePhase = 5
      end
    else
      local done = true
      for index, task in ipairs(assert(self._matrixTasks)) do
        local value, taskDone = stepQuadratic(task)
        self._matrixTasks[index] = task
        self._affineValue = value
        done = done and taskDone
      end
      local xOffset = self._matrixTasks[1].value
      local yOffset = self._matrixTasks[2].value
      self._matrices = {
        { 0x80000, 0x60000 - xOffset, 0 },
        { 0x80000, 0x60000 + xOffset, 0 },
        { 0x80000 - yOffset, 0x60000, 0 },
        { 0x80000 + yOffset, 0x60000, 0 },
      }
      for index, matrix in ipairs(self._matrices) do
        self._sprites[index].matrix = matrix
      end
      if done then
        self._matrixTasks = nil
        self._sourcePhase = 5
      end
    end
  elseif phase == 5 then
    local isTrainer = self._route.role == "generic-trainer-transition"
    if isTrainer then
      self._affineTask = quadraticTask(0x1000, 0x19A, 1, 6)
    end
    self._wipe = {
      kind = isTrainer and "circle" or "mirrored-sector",
      step = 0,
      steps = isTrainer and 6 or 8,
    }
    self._wipe.rows = makeWipeRows(self._wipe.kind, 0, self._wipe.steps)
    self._sourcePhase = 6
  elseif phase == 6 then
    local wipe = assert(self._wipe)
    wipe.step = math.min(wipe.step + 1, wipe.steps)
    wipe.rows = makeWipeRows(wipe.kind, wipe.step, wipe.steps)
    local fadeDone = wipe.step == wipe.steps
    local affineDone = true
    if self._affineTask ~= nil then
      local value
      value, affineDone = stepQuadratic(self._affineTask)
      self._affineValue = value
      if affineDone then
        self._affineTask = nil
      end
    end
    if fadeDone and affineDone then
      self._sourcePhase = 7
    end
  elseif phase == 7 then
    self:dispose()
    return true
  else
    error("overlay 114 source task entered an unknown phase")
  end
  animateSprites(assert(self._sprites), self._uploadedImages)
  return false
end

function Overlay114Effect:frame()
  return {
    sourcePhase = self._sourcePhase,
    requiresCurrentFieldLayers = true,
    blendAlpha = self._route.role == "generic-trainer-transition" and self._blendAlpha or nil,
    wipe = self._wipe,
    affineValue = self._affineValue,
    matrices = self._matrices,
    sprites = self._sprites or {},
    ownsResources = not self._disposed and (self._resources ~= nil or self._spriteData ~= nil),
  }
end

function Overlay114Effect:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._sprites = nil
  self._spriteData = nil
  self._resources = nil
  self._child = nil
  self._blendTask = nil
  self._wipe = nil
  self._affineTask = nil
  self._matrixTasks = nil
  if self._imageHandles ~= nil then
    for _, image in ipairs(self._imageHandles) do
      image:release()
    end
  end
  self._uploadedImages = nil
  self._imageHandles = nil
end

return Overlay114Effect
