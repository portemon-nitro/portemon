-- App-owned Android virtual controller adapter.

local PixelScale = require("libs.ui.src.PixelScale")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local TouchGamepad = {}
TouchGamepad.__index = TouchGamepad

local BUTTONS = {
  "dpup",
  "dpdown",
  "dpleft",
  "dpright",
  "a",
  "b",
  "x",
  "y",
  "leftshoulder",
  "rightshoulder",
  "start",
  "back",
}

local controller = {
  getID = function()
    return -1
  end,
}

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function positive(value)
  return finite(value) and value > 0
end

local function rectangle(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function sameRectangle(a, b)
  return a ~= nil and b ~= nil and a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height
end

local function contains(rect, x, y)
  return x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height
end

local function copyRectangle(rect)
  return rectangle(rect.x, rect.y, rect.width, rect.height)
end

local function assertGeometry(width, height, safeRect, pixelRatio)
  assert(positive(width) and positive(height), "touch gamepad host dimensions must be positive and finite")
  assert(positive(pixelRatio), "touch gamepad pixel ratio must be positive and finite")
  assert(type(safeRect) == "table", "touch gamepad requires a safe rectangle")
  assert(finite(safeRect.x) and finite(safeRect.y), "touch gamepad safe origin must be finite")
  assert(
    positive(safeRect.width) and positive(safeRect.height),
    "touch gamepad safe dimensions must be positive and finite"
  )
  assert(safeRect.x >= 0 and safeRect.y >= 0, "touch gamepad safe rectangle must be inside the host")
  assert(
    safeRect.x + safeRect.width <= width and safeRect.y + safeRect.height <= height,
    "touch gamepad safe rectangle must be inside the host"
  )
end

local function addButton(plan, token, label, rect, arrow)
  plan.controls[#plan.controls + 1] = {
    token = token,
    label = label,
    rect = rect,
    arrow = arrow,
  }
end

local function addTopRow(plan, safe, dockY, scale)
  local x = safe.x + 8 * scale
  local y = dockY + 8 * scale
  local width = safe.width - 16 * scale
  local gap = 8 * scale
  local buttonWidth = (width - 3 * gap) / 4
  local labels = { "L", "SEL", "ST", "R" }
  local tokens = { "leftshoulder", "back", "start", "rightshoulder" }
  for index = 1, 4 do
    addButton(
      plan,
      tokens[index],
      labels[index],
      rectangle(x + (index - 1) * (buttonWidth + gap), y, buttonWidth, 48 * scale)
    )
  end
end

local function addRailButton(plan, rail, token, label, y)
  addButton(plan, token, label, rectangle(rail.x + 8 * plan.scale, y, rail.width - 16 * plan.scale, 48 * plan.scale))
end

local function addDpad(plan, x, y, scale)
  local size = 48 * scale
  plan.dpad = rectangle(x, y, 144 * scale, 144 * scale)
  addButton(plan, "dpup", "", rectangle(x, y, size, size), "up")
  addButton(plan, "dpleft", "", rectangle(x, y + size, size, size), "left")
  addButton(plan, "dpright", "", rectangle(x + 2 * size, y + size, size, size), "right")
  addButton(plan, "dpdown", "", rectangle(x, y + 2 * size, size, size), "down")
end

local function addFace(plan, x, y, scale)
  local size = 48 * scale
  local buttons = {
    a = rectangle(x + 2 * size, y + size, size, size),
    b = rectangle(x + size, y + 2 * size, size, size),
    x = rectangle(x + size, y, size, size),
    y = rectangle(x, y + size, size, size),
  }
  addButton(plan, "x", "X", buttons.x)
  addButton(plan, "y", "Y", buttons.y)
  addButton(plan, "a", "A", buttons.a)
  addButton(plan, "b", "B", buttons.b)
end

local function paintRectangle(placement)
  local inset = math.ceil(1 / placement.scale)
  local farX = math.floor(placement.logicalWidth)
  local farY = math.floor(placement.logicalHeight)
  assert(farX - 2 * inset > 0 and farY - 2 * inset > 0, "touch gamepad buttons must contain a paintable pixel grid")
  return rectangle(inset, inset, farX - 2 * inset, farY - 2 * inset)
end

local function buildPlan(width, height, safeRect, pixelRatio, renderer)
  assertGeometry(width, height, safeRect, pixelRatio)
  local safeWidth, safeHeight = safeRect.width, safeRect.height
  local portrait = safeHeight >= safeWidth
  local scale = portrait and math.min(1, safeWidth / 320, safeHeight / 432)
    or math.min(1, safeWidth / 640, safeHeight / 272)
  local regions
  local plan = { controls = {}, scale = scale, portrait = portrait, regions = {} }
  if portrait then
    local dockHeight = 216 * scale
    local dockY = safeRect.y + safeHeight - dockHeight
    regions = { rectangle(safeRect.x, dockY, safeWidth, dockHeight) }
    addTopRow(plan, safeRect, dockY, scale)
    local groupY = dockY + 64 * scale
    addDpad(plan, safeRect.x + 8 * scale, groupY, scale)
    addFace(plan, safeRect.x + safeWidth - 8 * scale - 144 * scale, groupY, scale)
  else
    local railWidth = 160 * scale
    regions = {
      rectangle(safeRect.x, safeRect.y, railWidth, safeHeight),
      rectangle(safeRect.x + safeWidth - railWidth, safeRect.y, railWidth, safeHeight),
    }
    addRailButton(plan, regions[1], "leftshoulder", "L", safeRect.y + 8 * scale)
    addRailButton(plan, regions[2], "rightshoulder", "R", safeRect.y + 8 * scale)
    addRailButton(plan, regions[1], "back", "SEL", safeRect.y + safeHeight - 56 * scale)
    addRailButton(plan, regions[2], "start", "ST", safeRect.y + safeHeight - 56 * scale)
    local groupY = safeRect.y + (safeHeight - 144 * scale) / 2
    addDpad(plan, regions[1].x + 8 * scale, groupY, scale)
    addFace(plan, regions[2].x + regions[2].width - 8 * scale - 144 * scale, groupY, scale)
  end
  plan.regions = regions

  local pitch = math.max(1, math.floor(pixelRatio * scale + 0.5))
  for _, control in ipairs(plan.controls) do
    control.placement = PixelScale.cover(control.rect, pitch, pixelRatio)
    control.paintRect = paintRectangle(control.placement.placement)
    if control.label == "ST" or control.label == "SEL" then
      local fullLabel = control.label == "ST" and "START" or "SELECT"
      local textWidth = 36
      local bold = renderer.fonts and renderer.fonts.bold
      if bold ~= nil and type(bold.getWidth) == "function" then
        textWidth = bold:getWidth(fullLabel)
      end
      if scale >= 1 and textWidth + 20 <= control.paintRect.width then
        control.label = fullLabel
      end
    end
  end
  return plan
end

local function directionAt(plan, x, y, previous)
  local dpad = plan.dpad
  if not contains(dpad, x, y) then
    return nil
  end
  local cell = 48 * plan.scale
  local localX, localY = x - dpad.x, y - dpad.y
  if localX >= cell and localX < 2 * cell and localY >= cell and localY < 2 * cell then
    return nil
  end
  local dx = localX - dpad.width / 2
  local dy = localY - dpad.height / 2
  if math.abs(dx) == math.abs(dy) then
    local vertical = dy >= 0 and "dpdown" or "dpup"
    local horizontal = dx >= 0 and "dpright" or "dpleft"
    if previous == vertical or previous == horizontal then
      return previous
    end
    return vertical
  end
  if math.abs(dx) > math.abs(dy) then
    return dx > 0 and "dpright" or "dpleft"
  end
  return dy > 0 and "dpdown" or "dpup"
end

local function controlAt(plan, x, y)
  for _, control in ipairs(plan.controls) do
    if contains(control.rect, x, y) then
      return control
    end
  end
  return nil
end

---@class TouchGamepadButtonRectangle
---@field x number
---@field y number
---@field width number
---@field height number

---@class TouchGamepadButtonVisualState
---@field focused boolean?
---@field pressed boolean?
---@field disabled boolean?

---@class TouchGamepadRendererFont
---@field getWidth fun(self: TouchGamepadRendererFont, text: string): number

---@class TouchGamepadRendererFonts
---@field bold TouchGamepadRendererFont?

---@alias TouchGamepadRenderer { drawButton: fun(self: TouchGamepadRenderer, rect: TouchGamepadButtonRectangle, label: string, iconKey: string?, visualState: TouchGamepadButtonVisualState?), fonts: TouchGamepadRendererFonts? }

---@class TouchGamepadModule
---@field new fun(renderer: TouchGamepadRenderer): TouchGamepad

---@class TouchGamepad
---@field renderer TouchGamepadRenderer
---@field setTarget fun(self: TouchGamepad, gameOrNil: Game?)
---@field setGeometry fun(self: TouchGamepad, width: number, height: number, safeRect: TouchGamepadButtonRectangle, pixelRatio: number): boolean
---@field topology fun(self: TouchGamepad): ScreenTopology?
---@field sync fun(self: TouchGamepad)
---@field cancel fun(self: TouchGamepad)
---@field touchpressed fun(self: TouchGamepad, id: unknown, x: number, y: number): boolean
---@field touchmoved fun(self: TouchGamepad, id: unknown, x: number, y: number): boolean
---@field touchreleased fun(self: TouchGamepad, id: unknown, x: number, y: number): boolean
---@field draw fun(self: TouchGamepad)
TouchGamepad.__index = TouchGamepad

---@param renderer TouchGamepadRenderer
---@return TouchGamepad
function TouchGamepad.new(renderer)
  assert(
    type(renderer) == "table" and type(renderer.drawButton) == "function",
    "touch gamepad requires a button renderer"
  )
  return setmetatable({
    renderer = renderer,
    controller = controller,
    target = nil,
    child = nil,
    generation = 0,
    facts = nil,
    plan = nil,
    captures = {},
    suppressed = {},
    counts = {},
  }, TouchGamepad)
end

function TouchGamepad:_live(game, child, generation)
  return self.target == game
    and game ~= nil
    and not game.terminal
    and game.state == child
    and child ~= nil
    and self.child == child
    and self.generation == generation
end

function TouchGamepad:_suppressCaptures()
  for id in pairs(self.captures) do
    self.suppressed[id] = true
  end
  self.captures = {}
  self.counts = {}
end

function TouchGamepad:_dispatch(kind, token)
  local game, child, generation = self.target, self.child, self.generation
  assert(self:_live(game, child, generation), "touch gamepad dispatch requires a live target")
  assert(game ~= nil, "touch gamepad dispatch requires a live target")
  game[kind](game, self.controller, token)
  self:sync()
end

function TouchGamepad:_press(token)
  local count = self.counts[token] or 0
  self.counts[token] = count + 1
  if count == 0 then
    self:_dispatch("gamepadpressed", token)
  end
end

function TouchGamepad:_release(token)
  local count = assert(self.counts[token], "touch gamepad token has an owner")
  self.counts[token] = count - 1
  if self.counts[token] == 0 then
    self.counts[token] = nil
    self:_dispatch("gamepadreleased", token)
  end
end

---@param gameOrNil Game?
function TouchGamepad:setTarget(gameOrNil)
  if gameOrNil ~= nil then
    assert(
      type(gameOrNil) == "table" and type(gameOrNil.gamepadpressed) == "function",
      "touch gamepad target must be a Game"
    )
    assert(type(gameOrNil.gamepadreleased) == "function", "touch gamepad target must be a Game")
  end
  self:cancel()
  self.target = gameOrNil
  self.child = gameOrNil and gameOrNil.state or nil
  self.generation = self.generation + 1
end

---@param width number
---@param height number
---@param safeRect { x: number, y: number, width: number, height: number }
---@param pixelRatio number
---@return boolean changed
function TouchGamepad:setGeometry(width, height, safeRect, pixelRatio)
  local facts = {
    width = width,
    height = height,
    safeRect = copyRectangle(assert(safeRect, "touch gamepad requires a safe rectangle")),
    pixelRatio = pixelRatio,
  }
  assertGeometry(width, height, facts.safeRect, pixelRatio)
  if
    self.facts ~= nil
    and facts.width == self.facts.width
    and facts.height == self.facts.height
    and facts.pixelRatio == self.facts.pixelRatio
    and sameRectangle(facts.safeRect, self.facts.safeRect)
  then
    return false
  end
  local plan = buildPlan(width, height, facts.safeRect, pixelRatio, self.renderer)
  self:cancel()
  self.facts = facts
  self.plan = plan
  self._topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = rectangle(0, 0, width, height),
    safeRect = copyRectangle(facts.safeRect),
    role = "world",
    touch = true,
    occupiedRegions = plan.regions,
  })
  return true
end

---@return ScreenTopology?
function TouchGamepad:topology()
  if self._topology == nil then
    return nil
  end
  return ScreenTopology.new({ surfaces = self._topology.surfaces })
end

function TouchGamepad:sync()
  local game = self.target
  if game == nil then
    return
  end
  local child = not game.terminal and game.state or nil
  if child == self.child then
    return
  end
  self:_suppressCaptures()
  self.child = child
  self.generation = self.generation + 1
end

function TouchGamepad:cancel()
  local held = {}
  for _, token in ipairs(BUTTONS) do
    if self.counts[token] ~= nil then
      held[#held + 1] = token
    end
  end
  self:_suppressCaptures()
  if self.target == nil or self.target.terminal or self.child == nil then
    return
  end
  local game, child, generation = self.target, self.child, self.generation
  for _, token in ipairs(held) do
    if not self:_live(game, child, generation) then
      break
    end
    assert(game ~= nil, "touch gamepad cancellation requires a live target")
    game:gamepadreleased(self.controller, token)
    self:sync()
  end
end

---@param id unknown
---@param x number
---@param y number
---@return boolean consumed
function TouchGamepad:touchpressed(id, x, y)
  self:sync()
  self.suppressed[id] = nil
  local capture = self.captures[id]
  if capture ~= nil then
    if capture.token ~= nil then
      self:_release(capture.token)
    end
    self.captures[id] = nil
  end
  if self.target == nil or self.target.terminal or self.child == nil or self.plan == nil then
    return false
  end
  local reserved = false
  for _, region in ipairs(self.plan.regions) do
    if contains(region, x, y) then
      reserved = true
      break
    end
  end
  if not reserved then
    return false
  end
  capture = { kind = "blank" }
  if contains(self.plan.dpad, x, y) then
    capture = { kind = "dpad", token = directionAt(self.plan, x, y, nil) }
  else
    local control = controlAt(self.plan, x, y)
    if control ~= nil then
      capture = { kind = "button", token = control.token, button = control.token, rect = control.rect }
    end
  end
  self.captures[id] = capture
  if capture.token ~= nil then
    self:_press(capture.token)
  end
  return true
end

---@param id unknown
---@param x number
---@param y number
---@return boolean consumed
function TouchGamepad:touchmoved(id, x, y)
  self:sync()
  local capture = self.captures[id]
  if capture == nil then
    return self.suppressed[id] == true
  end
  if capture.kind == "button" then
    local previous = capture.token
    local token = contains(capture.rect, x, y) and capture.button or nil
    if token ~= previous then
      capture.token = token
      if previous ~= nil then
        local game, child, generation = self.target, self.child, self.generation
        self:_release(previous)
        if not self:_live(game, child, generation) then
          return true
        end
      end
      if token ~= nil then
        self:_press(token)
      end
    end
  elseif capture.kind == "dpad" then
    local game, child, generation = self.target, self.child, self.generation
    local previous = capture.token
    local token = directionAt(self.plan, x, y, previous)
    if token ~= previous then
      capture.token = token
      if previous ~= nil then
        self:_release(previous)
        if not self:_live(game, child, generation) then
          return true
        end
      end
      if token ~= nil then
        self:_press(token)
      end
    end
  end
  return true
end

---@param id unknown
---@return boolean consumed
function TouchGamepad:touchreleased(id, _, _)
  self:sync()
  local capture = self.captures[id]
  if capture == nil then
    local consumed = self.suppressed[id] == true
    self.suppressed[id] = nil
    return consumed
  end
  self.captures[id] = nil
  if capture.token ~= nil then
    self:_release(capture.token)
  end
  return true
end

local function drawArrow(graphics, direction, rect)
  local cx = math.floor(rect.x + rect.width / 2)
  local cy = math.floor(rect.y + rect.height / 2)
  local size = math.max(2, math.floor(rect.width / 4))
  local half = math.max(1, math.floor(size / 3))
  local points
  if direction == "up" then
    points = {
      cx,
      cy - size,
      cx + size,
      cy + half,
      cx + half,
      cy + half,
      cx + half,
      cy + size,
      cx - half,
      cy + size,
      cx - half,
      cy + half,
      cx - size,
      cy + half,
    }
  elseif direction == "down" then
    points = {
      cx,
      cy + size,
      cx - size,
      cy - half,
      cx - half,
      cy - half,
      cx - half,
      cy - size,
      cx + half,
      cy - size,
      cx + half,
      cy - half,
      cx + size,
      cy - half,
    }
  elseif direction == "left" then
    points = {
      cx - size,
      cy,
      cx + half,
      cy - size,
      cx + half,
      cy - half,
      cx + size,
      cy - half,
      cx + size,
      cy + half,
      cx + half,
      cy + half,
      cx + half,
      cy + size,
    }
  else
    points = {
      cx + size,
      cy,
      cx - half,
      cy + size,
      cx - half,
      cy + half,
      cx - size,
      cy + half,
      cx - size,
      cy - half,
      cx - half,
      cy - half,
      cx - half,
      cy - size,
    }
  end
  graphics.setColor(0.157, 0.157, 0.157, 1)
  graphics.polygon("fill", points)
end

function TouchGamepad:draw()
  self:sync()
  if self.target == nil or self.target.terminal or self.child == nil or self.plan == nil then
    return
  end
  local graphics = love.graphics
  graphics.push("all")
  local ok, failure = pcall(function()
    for _, control in ipairs(self.plan.controls) do
      local placement = control.placement.placement
      graphics.push()
      local drawn, drawFailure = pcall(function()
        graphics.translate(placement.origin.x, placement.origin.y)
        graphics.scale(placement.scale, placement.scale)
        self.renderer:drawButton(control.paintRect, control.label, nil, {
          pressed = control.token ~= nil and self.counts[control.token] ~= nil,
        })
        if control.arrow ~= nil then
          drawArrow(graphics, control.arrow, control.paintRect)
        end
      end)
      graphics.pop()
      if not drawn then
        error(drawFailure, 0)
      end
    end
  end)
  graphics.pop()
  if not ok then
    error(failure, 0)
  end
end

---@return TouchGamepadModule
return TouchGamepad
