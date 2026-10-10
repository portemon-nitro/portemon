-- The gear companion's shared shell composition: the shell planes, the
-- civil clock strip, the fixed card strip, and the active child, drawn from
-- the plan's resolved image paths and the shell snapshot only. The child
-- renderer routes by closed semantic card, never by require strings in
-- generated data; brightness and window-mask composition stay explicit.
-- Borrows prepared images and draws with no allocation. Pure presentation:
-- no love globals, the host graphics namespace arrives through resources.

local LogicalSurface = require("libs.ui.src.LogicalSurface")
local PokegearConfigureRenderer = require("libs.hgss.src.presentation.PokegearConfigureRenderer")

---@class PokegearRenderer
local PokegearRenderer = {}

local CLOCK_TEXT_X = 70
local CLOCK_TEXT_Y = 44
local WEEKDAY_X = 173
local WEEKDAY_Y = 48
local SIGNAL_RECT = { x = 197, y = 48, width = 10, height = 10 }

---@param panes table[]
---@param id string
---@return table<string, unknown>? pane
local function findPane(panes, id)
  for _, pane in ipairs(panes) do
    if type(pane) == "table" and pane.id == id then
      return pane
    end
  end
  return nil
end

---@param graphics love.graphics
---@param images table<string, unknown>
---@param path unknown
---@param what string
local function drawPrepared(graphics, images, path, what)
  assert(type(path) == "string", "the companion plan resolves its " .. what .. " image")
  local image = images[path]
  assert(image ~= nil, "the companion render needs its prepared " .. what .. " image")
  graphics.setColor(1, 1, 1, 1)
  graphics.draw(image, 0, 0)
end

-- The civil clock strip in upper information-local coordinates: hour and
-- minute through text primitives with the native colon phase, the weekday
-- frame, and the outgoing-call reception indicator.
---@param graphics love.graphics
---@param text table<string, unknown>?
---@param clock table<string, unknown>
local function drawClock(graphics, text, clock)
  local hour = clock.hour
  local minute = clock.minute
  assert(type(hour) == "number" and type(minute) == "number", "the clock strip carries civil time")
  if text ~= nil and type(text.drawText) == "function" then
    local separator = clock.colon == 1 and ":" or " "
    graphics.setColor(1, 1, 1, 1)
    text:drawText(string.format("%02d%s%02d", hour, separator, minute), CLOCK_TEXT_X, CLOCK_TEXT_Y)
    if type(clock.weekday) == "number" then
      text:drawText(tostring(clock.weekday), WEEKDAY_X, WEEKDAY_Y)
    end
  end
  if clock.signal == true then
    graphics.setColor(1, 1, 1, 1)
    graphics.rectangle("fill", SIGNAL_RECT.x, SIGNAL_RECT.y, SIGNAL_RECT.width, SIGNAL_RECT.height)
  end
end

-- The fixed card strip over the lower controls band: every slot outlined,
-- slots selecting the active card highlighted, the focused slot framed.
---@param graphics love.graphics
---@param slots table[]
---@param tab string
---@param focus string
local function drawStrip(graphics, slots, tab, focus)
  for _, slot in ipairs(slots) do
    if type(slot) == "table" then
      local entry = slot --[[@as { tab: string, rect: table<string, number> }]]
      local rect = entry.rect
      if entry.tab == tab then
        graphics.setColor(1, 1, 1, 0.85)
        graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
        graphics.setColor(0.1, 0.1, 0.12, 1)
        graphics.rectangle("line", rect.x + 0.5, rect.y + 0.5, rect.width - 1, rect.height - 1)
      else
        graphics.setColor(1, 1, 1, 1)
        graphics.rectangle("line", rect.x + 0.5, rect.y + 0.5, rect.width - 1, rect.height - 1)
      end
      if entry.tab == focus and entry.tab ~= tab then
        graphics.setColor(1, 1, 1, 1)
        graphics.rectangle("line", rect.x - 1.5, rect.y - 1.5, rect.width + 3, rect.height + 3)
      end
    end
  end
  graphics.setColor(1, 1, 1, 1)
end

-- The active child inside the controls pane: the setup card through its
-- exact frame renderer, every other card as its resolved compiled plane
-- beneath the shared strip.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param text table<string, unknown>?
---@param content table<string, unknown>
---@param view table<string, unknown>
local function drawChild(graphics, images, text, content, view)
  local tab = view.tab
  local child = view.child
  if tab == "configure" and type(child) == "table" and type(child.view) == "table" then
    PokegearConfigureRenderer.drawPane(
      graphics,
      images,
      text,
      content,
      child.view --[[@as table<string, unknown>]],
      view.unlockedSkins --[[@as table<integer, integer>]]
    )
    return
  end
  local visuals = content.childVisuals
  local path = type(visuals) == "table" and visuals[
    tab --[[@as string]]
  ]
  if type(path) == "string" then
    local image = images[path]
    if image ~= nil then
      graphics.setColor(1, 1, 1, 1)
      graphics.draw(image, 0, 0)
    end
  end
end

-- Draws the published plan with borrowed collaborators: information carries
-- the shell information plane and the clock, controls carry the shell
-- foreground, the active child, and the strip. Runs inside one pushed
-- graphics scope per pane and leaves identity tint behind.
---@param resources table<string, unknown> borrowed host collaborators
---@param view table<string, unknown> the shell snapshot
---@param plan ApplicationPlan the already-resolved published plan
function PokegearRenderer.draw(resources, view, plan)
  local graphics = assert(resources.graphics, "the companion render borrows its host graphics")
  local images = assert(resources.images, "the companion render borrows its prepared images")
  assert(type(images) == "table", "the companion render borrows its prepared images")
  local text = resources.textRenderer
  if text ~= nil then
    assert(type(text) == "table", "the companion render borrows its text primitives")
  end
  local panes = assert(plan.panes, "the companion plan carries its panes")
  assert(type(panes) == "table", "the companion plan carries its panes")
  local content = assert(plan.content, "the companion plan carries its payload")
  assert(type(content) == "table", "the companion plan carries its payload")
  local information = findPane(panes --[[@as table[] ]], "information")
  local controls = findPane(panes --[[@as table[] ]], "controls")
  if information ~= nil then
    local placement = assert(information.placement, "the information pane carries its placement")
    LogicalSurface.draw(graphics, placement --[[@as LayoutGeometry.Placement]], function()
      drawPrepared(graphics, images --[[@as table<string, unknown>]], content.shellInformation, "shell information")
      local clock = view.clock
      if type(clock) == "table" then
        drawClock(graphics, text --[[@as table<string, unknown>?]], clock --[[@as table<string, unknown>]])
      end
    end)
  end
  if controls ~= nil then
    local placement = assert(controls.placement, "the controls pane carries its placement")
    LogicalSurface.draw(graphics, placement --[[@as LayoutGeometry.Placement]], function()
      drawPrepared(graphics, images --[[@as table<string, unknown>]], content.shellForeground, "shell")
      drawChild(
        graphics,
        images --[[@as table<string, unknown>]],
        text --[[@as table<string, unknown>?]],
        content --[[@as table<string, unknown>]],
        view
      )
      local slots = content.slots
      assert(type(slots) == "table", "the companion plan carries its strip slots")
      local tab = view.tab
      local focus = view.focus
      assert(type(tab) == "string" and type(focus) == "string", "the companion view carries its card identities")
      drawStrip(graphics, slots --[[@as table[] ]], tab, focus)
    end)
  end
  graphics.setColor(1, 1, 1, 1)
end

return PokegearRenderer
