-- The standalone Fly map presentation: the source plane/window/sprite
-- stack from the shared asset family Fly section, drawn from the
-- controller snapshot only. The prepared planes paint first unmodulated
-- from the shared source art, then destination markers at their snapshot
-- points, then the confirmation window with its control in Fly mode.
-- Absent planes are a composition error, never procedural geography.
-- Shares geometry and semantic keys with the Map tab; draws no shell
-- chrome, tab strip, or marking controls. Pure presentation: no love
-- globals, the host graphics namespace arrives through resources.

---@class PokegearFlyMapRenderer
local PokegearFlyMapRenderer = {}

-- Confirmation chrome behind the title and window bands: six distinct
-- panel colors so the standalone entry never paints as a fifth tab.
-- The prepared planes themselves carry the single shared source palette
-- and always paint unmodulated.
local FLY_PANEL = {
  { 0.1, 0.22, 0.38 },
  { 0.09, 0.2, 0.36 },
  { 0.14, 0.24, 0.36 },
  { 0.08, 0.26, 0.34 },
  { 0.16, 0.18, 0.4 },
  { 0.1, 0.28, 0.3 },
}

local TITLE_RECT = { x = 8, y = 8, width = 240, height = 24 }
local WINDOW_RECT = { x = 8, y = 140, width = 240, height = 44 }
local MARKER_COLOR = { 0.98, 0.75, 0.2, 1 }
local BUTTON_FILL = { 0.94, 0.94, 0.88, 1 }
local BUTTON_LINE = { 0.08, 0.08, 0.1, 1 }

---@param skin integer
---@return table<integer, number> panel fill
local function flyPanel(skin)
  return FLY_PANEL[(skin % 6) + 1]
end

---@param images table<string, unknown>
---@param path unknown
---@return table<string, unknown> image
local function preparedImage(images, path)
  assert(type(path) == "string", "the fly view carries its prepared planes")
  local image = images[path]
  assert(image ~= nil, "the fly render needs its prepared plane image")
  return image
end

-- The Fly planes at the snapshot pan and discrete zoom: the resolved
-- background with the remaining section planes stacked over it, all
-- drawn unmodulated from prepared art. A missing background or plane is
-- a composition error, never procedural geography.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param content table<string, unknown>
local function drawPlanes(graphics, images, content)
  local background = preparedImage(images, content.background)
  graphics.setColor(1, 1, 1, 1)
  graphics.draw(background, 0, 0)
  local planes = content.planes
  if type(planes) == "table" then
    for _, path in ipairs(planes) do
      if path ~= content.background then
        local plane = preparedImage(images, path)
        graphics.setColor(1, 1, 1, 1)
        graphics.draw(plane, 0, 0)
      end
    end
  end
end

-- The entry title band in the skin panel color.
---@param graphics love.graphics
---@param skin integer
local function drawTitle(graphics, skin)
  local panel = flyPanel(skin)
  graphics.setColor(panel[1], panel[2], panel[3], 1)
  graphics.rectangle("fill", TITLE_RECT.x, TITLE_RECT.y, TITLE_RECT.width, TITLE_RECT.height)
end

---@param graphics love.graphics
---@param point table<string, number>
---@param size number
local function drawDiamond(graphics, point, size)
  graphics.polygon("fill", {
    point.x,
    point.y - size,
    point.x + size,
    point.y,
    point.x,
    point.y + size,
    point.x - size,
    point.y,
  })
end

-- One destination marker per permitted flypoint at its snapshot point:
-- markers without a resolvable pane point stay out of the plane layer.
---@param graphics love.graphics
---@param view table<string, unknown>
local function drawMarkers(graphics, view)
  local markers = view.markers
  assert(type(markers) == "table", "the fly view carries its destination markers")
  graphics.setColor(MARKER_COLOR[1], MARKER_COLOR[2], MARKER_COLOR[3], MARKER_COLOR[4])
  for _, marker in ipairs(markers) do
    if type(marker) == "table" then
      local point = marker.point
      if type(point) == "table" then
        assert(type(point.x) == "number" and type(point.y) == "number", "marker points carry coordinates")
        drawDiamond(graphics, point --[[@as table<string, number>]], 6)
      end
    end
  end
end

-- The confirmation window with its control at the snapshot button rect:
-- the skin panel color behind the button frame. The window plane itself
-- already paints in the planes stack, so this pass adds only the
-- confirmation composition.
---@param graphics love.graphics
---@param view table<string, unknown>
---@param skin integer
local function drawConfirm(graphics, view, skin)
  local panel = flyPanel(skin)
  graphics.setColor(panel[1], panel[2], panel[3], 1)
  graphics.rectangle("fill", WINDOW_RECT.x, WINDOW_RECT.y, WINDOW_RECT.width, WINDOW_RECT.height)
  local button = view.confirmButton
  assert(type(button) == "table", "fly mode carries its confirmation control")
  assert(
    type(button.x) == "number"
      and type(button.y) == "number"
      and type(button.width) == "number"
      and type(button.height) == "number",
    "the confirmation control carries its hit area"
  )
  graphics.setColor(BUTTON_FILL[1], BUTTON_FILL[2], BUTTON_FILL[3], BUTTON_FILL[4])
  graphics.rectangle("fill", button.x, button.y, button.width, button.height)
  graphics.setColor(BUTTON_LINE[1], BUTTON_LINE[2], BUTTON_LINE[3], BUTTON_LINE[4])
  graphics.rectangle("line", button.x + 0.5, button.y + 0.5, button.width - 1, button.height - 1)
end

---@param resources table<string, unknown> the borrowed host resources
---@param status table<string, unknown> the controller snapshot
---@param skin integer the source skin identity
function PokegearFlyMapRenderer.draw(resources, status, skin)
  assert(resources ~= nil, "the fly render borrows its host resources")
  local graphics = resources.graphics
  assert(graphics ~= nil, "the fly render borrows its host graphics")
  assert(type(resources.images) == "table", "the fly render borrows its prepared images")
  local images = resources.images --[[@as table<string, unknown>]]
  assert(type(skin) == "number" and skin % 1 == 0 and skin >= 0 and skin <= 5, "the fly render needs its skin")
  local view = status.view
  assert(type(view) == "table", "the fly render reads the controller view")
  local content = view.content
  assert(type(content) == "table", "the fly view carries its resolved content")
  drawPlanes(graphics --[[@as love.graphics]], images, content --[[@as table<string, unknown>]])
  drawTitle(graphics --[[@as love.graphics]], skin)
  drawMarkers(graphics --[[@as love.graphics]], view --[[@as table<string, unknown>]])
  if view.confirmButton ~= nil then
    drawConfirm(graphics --[[@as love.graphics]], view --[[@as table<string, unknown>]], skin)
  end
  graphics.setColor(1, 1, 1, 1)
end

return PokegearFlyMapRenderer
