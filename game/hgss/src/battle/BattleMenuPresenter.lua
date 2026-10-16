-- Composes the generated lower BG planes for the native battle menu.

---@class BattleMenuPresenter
local BattleMenuPresenter = {}
local LogicalSurface = require("libs.ui.src.LogicalSurface")

local BLEND_SHADER = [[
extern Image underlay;
vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
  vec4 top = Texel(texture, texture_coords);
  vec4 bottom = Texel(underlay, texture_coords);
  vec3 blended = clamp((top.rgb * 8.0 + bottom.rgb * 12.0) / 16.0, 0.0, 1.0);
  return vec4(mix(bottom.rgb, blended, top.a), max(bottom.a, top.a)) * color;
}
]]

---@param graphics love.graphics borrowed renderer graphics
---@param assets table<string, unknown> generated image holder
---@param layout string selected lower menu layout
---@param layers table[] source screen records with plane and priority
---@param view table<string, unknown> semantic render snapshot
---@param menuWindows table<string, unknown>? native window and lower BG scroll snapshot
function BattleMenuPresenter.draw(graphics, assets, layout, layers, view, menuWindows)
  local ordered = {}
  for index, layer in ipairs(layers) do
    ordered[#ordered + 1] = { index = index, layer = layer, priority = layer.priority or index }
  end
  table.sort(ordered, function(a, b)
    if a.priority == b.priority then
      return a.layer.plane > b.layer.plane
    end
    return a.priority > b.priority
  end)

  local planeOne
  for _, entry in ipairs(ordered) do
    if entry.layer.plane == 1 then
      planeOne = entry.layer
    end
  end
  if planeOne == nil then
    for _, entry in ipairs(ordered) do
      BattleMenuPresenter._drawWithWindows(graphics, assets, layout, view, entry, menuWindows)
    end
    return
  end

  local bottomCanvas, topCanvas, shader
  local acquired, acquireError = pcall(function()
    bottomCanvas = graphics.newCanvas(256, 192)
    topCanvas = graphics.newCanvas(256, 192)
    shader = graphics.newShader(BLEND_SHADER)
    assert(
      bottomCanvas ~= nil and topCanvas ~= nil and shader ~= nil,
      "native menu composition allocates its render targets"
    )
  end)
  if not acquired then
    if bottomCanvas ~= nil then
      bottomCanvas:release()
    end
    if topCanvas ~= nil then
      topCanvas:release()
    end
    if shader ~= nil then
      shader:release()
    end
    error(acquireError, 0)
  end

  local previousCanvas = graphics.getCanvas()
  graphics.push("all")
  local planeScopeOpen = true
  local outputScopeOpen = false
  local ok, err = pcall(function()
    graphics.setCanvas(bottomCanvas)
    graphics.origin()
    graphics.setScissor()
    graphics.clear(0, 0, 0, 0)
    for _, entry in ipairs(ordered) do
      if entry.layer.plane ~= 1 then
        BattleMenuPresenter._drawWithWindows(graphics, assets, layout, view, entry, menuWindows)
      end
    end
    graphics.setCanvas(topCanvas)
    graphics.origin()
    graphics.setScissor()
    graphics.clear(0, 0, 0, 0)
    for _, entry in ipairs(ordered) do
      if entry.layer.plane == 1 then
        BattleMenuPresenter._drawWithWindows(graphics, assets, layout, view, entry, menuWindows)
      end
    end
    graphics.setCanvas(previousCanvas)
    graphics.pop()
    planeScopeOpen = false
    graphics.push("all")
    outputScopeOpen = true
    shader:send("underlay", bottomCanvas)
    graphics.setShader(shader)
    graphics.draw(topCanvas, 0, 0)
    graphics.pop()
    outputScopeOpen = false
  end)
  if outputScopeOpen then
    graphics.pop()
  end
  if planeScopeOpen then
    graphics.pop()
  end
  bottomCanvas:release()
  topCanvas:release()
  shader:release()
  if not ok then
    error(err, 0)
  end
end

---@param graphics love.graphics borrowed renderer graphics
---@param assets table<string, unknown> generated image holder
---@param layout string selected lower menu layout
---@param view table<string, unknown> semantic render snapshot
---@param entry { index: integer, layer: { plane: integer, priority: number?, feedback: table<string, table<string, { x: number, y: number }>>? }, priority: number } selected screen entry
---@param menuWindows table<string, unknown>? native window and lower BG scroll snapshot
function BattleMenuPresenter._drawWithWindows(graphics, assets, layout, view, entry, menuWindows)
  local plane = entry.layer.plane
  if menuWindows == nil or (plane ~= 0 and plane ~= 1) then
    BattleMenuPresenter._drawLayer(graphics, assets, layout, view, entry)
    return
  end
  local top = assert(menuWindows.outsideTop, "menu window snapshot carries the upper outside region") --[[@as table<string, number>]]
  local bottom = assert(menuWindows.outsideBottom, "menu window snapshot carries the lower outside region") --[[@as table<string, number>]]
  local scroll = assert(menuWindows.scroll, "menu window snapshot carries per-plane BG offsets") --[[@as table<integer, table<string, number>>]]
  local offset = assert(scroll[plane], "menu window snapshot carries each composited plane offset")
  local function drawRegion(region, yOffset)
    if region.width == 0 or region.height == 0 then
      return
    end
    LogicalSurface.clip(graphics, region, function()
      graphics.translate(-offset.x, -yOffset)
      BattleMenuPresenter._drawLayer(graphics, assets, layout, view, entry)
    end)
  end
  drawRegion(top, offset.topY)
  drawRegion(bottom, offset.bottomY)
end

---@param graphics love.graphics borrowed renderer graphics
---@param assets table<string, unknown> generated image holder
---@param layout string selected lower menu layout
---@param view table<string, unknown> semantic render snapshot
---@param entry { index: integer, layer: { plane: integer, priority: number?, feedback: table<string, table<string, { x: number, y: number }>>? }, priority: number } selected screen entry
function BattleMenuPresenter._drawLayer(graphics, assets, layout, view, entry)
  local layer = entry.layer
  local art = assets:drawable("menu:" .. layout .. ":screen:" .. tostring(entry.index))
  if art ~= nil then
    graphics.draw(art, 0, 0)
  end
  if type(layer.feedback) ~= "table" then
    return
  end
  local selection = type(view.selection) == "string" and view.selection or nil
  local armed = type(view.armed) == "table" and view.armed or nil
  local feedbackState = armed ~= nil and armed.scope == layout and armed.id == selection and "pressed" or "selected"
  local controls = selection ~= nil and layer.feedback[selection] or nil
  local feedback = type(controls) == "table" and controls[feedbackState] or nil
  if type(feedback) ~= "table" then
    return
  end
  local patchImage = assets:drawable("menu:" .. layout .. ":feedback:" .. selection .. ":" .. feedbackState)
  if patchImage ~= nil then
    graphics.draw(patchImage, feedback.x, feedback.y)
  end
end

return BattleMenuPresenter
