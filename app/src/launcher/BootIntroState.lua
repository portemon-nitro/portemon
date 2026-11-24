-- One ROM-free foreground boot intro and its one-shot route decision.

local BootIntroState = {}
BootIntroState.__index = BootIntroState

local DURATION = 1.8
local MODIFIERS = {
  lshift = true,
  rshift = true,
  lctrl = true,
  rctrl = true,
  lalt = true,
  ralt = true,
  lgui = true,
  rgui = true,
}

local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

function BootIntroState.new(options)
  assert(type(options) == "table" and options.renderer and options.audio and type(options.onRoute) == "function")
  local width, height = love.graphics.getDimensions()
  local self = setmetatable({
    renderer = options.renderer,
    audio = options.audio,
    onRoute = options.onRoute,
    candidate = nil,
    elapsed = 0,
    foreground = true,
    latched = false,
    consumed = {},
    disposed = false,
    width = width,
    height = height,
    safeRect = copyRect(options.safeRect or { x = 0, y = 0, width = width, height = height }),
  }, BootIntroState)
  self.audio:play("boot")
  return self
end

function BootIntroState:setCandidate(candidate)
  if not self.latched then
    self.candidate = candidate
  end
end

function BootIntroState:_route(automatic)
  if self.latched or self.disposed then
    return
  end
  self.latched = true
  if not automatic then
    self.audio:fadeBoot(0.08)
  end
  self.onRoute(automatic, self.candidate)
end

function BootIntroState:update(dt)
  if self.latched or self.disposed then
    return
  end
  if not self.foreground then
    return
  end
  self.elapsed = self.elapsed + dt
  if self.elapsed >= DURATION then
    self:_route(true)
  end
end

function BootIntroState:draw()
  if not self.disposed then
    self.renderer:draw({ kind = "boot", elapsed = self.elapsed, safeRect = self.safeRect })
  end
end

function BootIntroState:resize(width, height, safeRect)
  self.width, self.height = width, height
  self.safeRect = copyRect(safeRect or { x = 0, y = 0, width = width, height = height })
  self.consumed = {}
end

function BootIntroState:_press(identity)
  if self.latched or self.disposed then
    return
  end
  self.consumed[identity] = true
  self:_route(false)
end

function BootIntroState:keypressed(key, _, isrepeat)
  if not isrepeat and not MODIFIERS[key] then
    self:_press("key:" .. key)
  end
end

function BootIntroState:gamepadpressed(joystick, button)
  self:_press("gamepad:" .. tostring(joystick) .. ":" .. button)
end

function BootIntroState:mousepressed(_, _, button)
  if button == 1 then
    self:_press("mouse:1")
  end
end

function BootIntroState:touchpressed(id)
  self:_press("touch:" .. tostring(id))
end

function BootIntroState:consumedInputs()
  local copy = {}
  for identity in pairs(self.consumed) do
    copy[identity] = true
  end
  return copy
end

function BootIntroState:focus(focused)
  self.foreground = focused
  if not focused then
    self.consumed = {}
  end
end

function BootIntroState:dispose()
  self.disposed = true
  self.consumed = {}
  self.renderer, self.audio, self.onRoute = nil, nil, nil
end

return BootIntroState
