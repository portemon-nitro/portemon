-- One ROM-free foreground boot presentation; App owns its route and lifetime.

local LauncherLayout = require("app.src.launcher.LauncherLayout")

---@class BootIntroState
---@field renderer table<string, unknown>
---@field audio table<string, unknown>
---@field displayContext DisplayContext
---@field width number
---@field height number
---@field safeRect { x: number, y: number, width: number, height: number }
---@field pixelRatio number
---@field surface table<string, unknown>
---@field elapsed number
---@field foreground boolean
---@field painted boolean
---@field disposed boolean
---@field update fun(self: BootIntroState, dt: number)
---@field draw fun(self: BootIntroState)
---@field resize fun(self: BootIntroState, width: number, height: number, safeRect: { x: number, y: number, width: number, height: number }, pixelRatio: number)
---@field focus fun(self: BootIntroState, focused: boolean)
---@field dispose fun(self: BootIntroState)

local BootIntroState = {}
BootIntroState.__index = BootIntroState

local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

---@param options table<string, unknown>
---@return BootIntroState
function BootIntroState.new(options)
  assert(type(options) == "table" and options.renderer and options.audio, "boot intro borrows process resources")
  assert(type(options.displayContext) == "table" and type(options.displayContext.measure) == "function")
  assert(
    type(options.width) == "number" and options.width > 0 and type(options.height) == "number" and options.height > 0
  )
  local self = setmetatable({
    renderer = options.renderer,
    audio = options.audio,
    displayContext = options.displayContext,
    width = options.width,
    height = options.height,
    safeRect = copyRect(options.safeRect or { x = 0, y = 0, width = options.width, height = options.height }),
    pixelRatio = options.pixelRatio or 1,
    elapsed = 0,
    foreground = true,
    painted = false,
    disposed = false,
  }, BootIntroState)
  self:_resolve()
  self.audio:play("boot")
  return self
end

function BootIntroState:_resolve()
  local usable = assert(self.displayContext:measure(self.width, self.height).topology.surfaces[1].safeRect)
  self.surface = LauncherLayout.surface(usable, self.pixelRatio)
end

function BootIntroState:update(dt)
  if not self.disposed and self.foreground and self.painted then
    self.elapsed = self.elapsed + dt
  end
end

function BootIntroState:draw()
  if self.disposed then
    return
  end
  self.renderer:drawBoot({ elapsed = self.elapsed, surface = self.surface }, self.surface)
  self.painted = true
end

function BootIntroState:resize(width, height, safeRect, pixelRatio)
  if self.disposed then
    return
  end
  self.width, self.height = width, height
  self.safeRect = copyRect(safeRect or { x = 0, y = 0, width = width, height = height })
  self.pixelRatio = pixelRatio or self.pixelRatio
  self:_resolve()
end

function BootIntroState:focus(focused)
  self.foreground = focused == true
end

function BootIntroState:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self.renderer, self.audio, self.displayContext, self.surface = nil, nil, nil, nil
end

return BootIntroState
