-- Captures the field world into a temporary DS-sized recursive motion trail.

local SHADER_PATH = "libs/hgss/src/presentation/shaders/celebi_blur.glsl"
local CAPTURE_WIDTH = 256
local CAPTURE_HEIGHT = 192

---@class CelebiTimeTravelBlur.Canvas : love.Canvas
---@field release fun(self: CelebiTimeTravelBlur.Canvas)
---@field setFilter fun(self: CelebiTimeTravelBlur.Canvas, min: string, mag: string)
---@class CelebiTimeTravelBlur.Shader
---@field send fun(self: CelebiTimeTravelBlur.Shader, name: string, ...)
---@field release fun(self: CelebiTimeTravelBlur.Shader)
---@class CelebiTimeTravelBlur
---@field _scene CelebiTimeTravelBlur.Canvas?
---@field _historyA CelebiTimeTravelBlur.Canvas?
---@field _historyB CelebiTimeTravelBlur.Canvas?
---@field _previous CelebiTimeTravelBlur.Canvas?
---@field _next CelebiTimeTravelBlur.Canvas?
---@field _shader CelebiTimeTravelBlur.Shader?
---@field _quad love.Quad?
---@field _quadRect number[]?
---@field _width integer?
---@field _height integer?
---@field _sequence integer?
---@field _frame integer?
local CelebiTimeTravelBlur = {}
CelebiTimeTravelBlur.__index = CelebiTimeTravelBlur

local function release(resource)
  if resource ~= nil then
    resource:release()
  end
end

local function newCanvas(graphics, width, height)
  local canvas = graphics.newCanvas(width, height, {
    dpiscale = 1,
    format = "rgba8",
    readable = true,
    msaa = 0,
  })
  local ok, failure = pcall(function()
    canvas:setFilter("nearest", "nearest")
  end)
  if not ok then
    canvas:release()
    error(failure, 0)
  end
  return canvas
end

local function readShaderSource()
  local source = love.filesystem.read(SHADER_PATH)
  if source then
    return source
  end
  local file = io.open(love.filesystem.getSourceBaseDirectory() .. "/" .. SHADER_PATH, "rb")
  assert(file, "cannot read Celebi capture shader source")
  local contents = file:read("*a")
  file:close()
  return contents
end

function CelebiTimeTravelBlur.new()
  return setmetatable({}, CelebiTimeTravelBlur)
end

function CelebiTimeTravelBlur:draw(status, viewport, drawWorld)
  assert(status.active and status.blurActive, "Celebi capture requires an active swirl")
  assert(type(status.sequence) == "number" and type(status.swirlFrame) == "number", "Celebi capture frame is missing")
  assert(
    status.swirlFrame % 1 == 0 and status.swirlFrame >= 1 and status.swirlFrame <= 180,
    "Celebi swirl source frame must be an integer from 1 through 180"
  )
  assert(type(drawWorld) == "function", "Celebi capture requires the composed field draw")
  local graphics = love.graphics
  local width, height = viewport.width, viewport.height
  local rect = viewport.worldViewport
  assert(
    type(width) == "number"
      and width > 0
      and width % 1 == 0
      and type(height) == "number"
      and height > 0
      and height % 1 == 0,
    "Celebi capture requires positive integer viewport dimensions"
  )
  assert(
    type(rect) == "table"
      and rect.x >= 0
      and rect.y >= 0
      and rect.width > 0
      and rect.height > 0
      and rect.x + rect.width <= width
      and rect.y + rect.height <= height,
    "Celebi capture rectangle must fit the field viewport"
  )
  self:_ensureTargets(graphics, width, height)
  if self._sequence ~= status.sequence then
    self._sequence, self._frame = status.sequence, nil
  end

  local ok, failure = pcall(function()
    self:_capture(graphics, status, viewport, drawWorld)
  end)
  if not ok then
    self:release()
    error(failure, 0)
  end
end

function CelebiTimeTravelBlur:_ensureTargets(graphics, width, height)
  if self._width == width and self._height == height then
    return
  end
  local staged = {}
  local ok, failure = pcall(function()
    staged.scene = newCanvas(graphics, width, height)
    staged.historyA = newCanvas(graphics, CAPTURE_WIDTH, CAPTURE_HEIGHT)
    staged.historyB = newCanvas(graphics, CAPTURE_WIDTH, CAPTURE_HEIGHT)
    if self._shader == nil then
      staged.shader = graphics.newShader(readShaderSource())
    end
  end)
  if not ok then
    release(staged.scene)
    release(staged.historyA)
    release(staged.historyB)
    release(staged.shader)
    error(failure, 0)
  end
  release(self._scene)
  release(self._historyA)
  release(self._historyB)
  self._scene, self._historyA, self._historyB = staged.scene, staged.historyA, staged.historyB
  self._shader = self._shader or staged.shader
  self._previous, self._next = self._historyA, self._historyB
  self._width, self._height = width, height
  self._sequence, self._frame = nil, nil
  self._quad, self._quadRect = nil, nil
end

function CelebiTimeTravelBlur:_capture(graphics, status, viewport, drawWorld)
  local scene = assert(self._scene)
  local shader = assert(self._shader)
  local previous = assert(self._previous)
  local nextFrame = assert(self._next)
  local rect = viewport.worldViewport
  local callerCanvas = graphics.getCanvas()
  local quadRect = self._quadRect
  if
    quadRect == nil
    or quadRect[1] ~= rect.x
    or quadRect[2] ~= rect.y
    or quadRect[3] ~= rect.width
    or quadRect[4] ~= rect.height
  then
    self._quad = graphics.newQuad(rect.x, rect.y, rect.width, rect.height, self._width, self._height)
    self._quadRect = { rect.x, rect.y, rect.width, rect.height }
  end

  local pushed = false
  local ok, failure = pcall(function()
    graphics.push("all")
    pushed = true
    graphics.origin()
    graphics.setScissor()
    graphics.setCanvas(scene)
    graphics.clear(0, 0, 0, 0)
    drawWorld()

    local hadHistory = self._frame ~= nil
    local skippedTicks = hadHistory and (status.swirlFrame - self._frame) or 0
    assert(not hadHistory or skippedTicks >= 0, "Celebi swirl source frames must not rewind")
    local isNewFrame = not hadHistory or skippedTicks > 0
    if isNewFrame then
      graphics.setCanvas(nextFrame)
      graphics.clear(0, 0, 0, 0)
      graphics.setBlendMode("replace", "premultiplied")
      graphics.setColor(1, 1, 1, 1)
      graphics.setShader(shader)
      shader:send("sceneImage", scene)
      shader:send("previousImage", previous)
      shader:send("sourceRect", {
        rect.x / self._width,
        rect.y / self._height,
        rect.width / self._width,
        rect.height / self._height,
      })
      shader:send("hasPrevious", hadHistory)
      shader:send("historyWeight", hadHistory and ((13 / 16) ^ skippedTicks) or 0)
      graphics.draw(scene, assert(self._quad), 0, 0, 0, CAPTURE_WIDTH / rect.width, CAPTURE_HEIGHT / rect.height)
      self._previous, self._next = nextFrame, previous
      self._frame = status.swirlFrame
      previous = nextFrame
    end

    graphics.setCanvas(callerCanvas)
    graphics.origin()
    graphics.setShader()
    graphics.setBlendMode("alpha", "alphamultiply")
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(scene, 0, 0)
    graphics.setBlendMode("replace", "premultiplied")
    graphics.draw(previous, rect.x, rect.y, 0, rect.width / CAPTURE_WIDTH, rect.height / CAPTURE_HEIGHT)
  end)
  if pushed then
    local restored, restoreFailure = pcall(graphics.pop)
    if not ok then
      error(failure, 0)
    end
    if not restored then
      error(restoreFailure, 0)
    end
  elseif not ok then
    error(failure, 0)
  end
end

function CelebiTimeTravelBlur:release()
  release(self._scene)
  release(self._historyA)
  release(self._historyB)
  release(self._shader)
  self._scene, self._historyA, self._historyB = nil, nil, nil
  self._previous, self._next, self._shader = nil, nil, nil
  self._width, self._height, self._sequence, self._frame = nil, nil, nil, nil
  self._quad, self._quadRect = nil, nil
end

return CelebiTimeTravelBlur
