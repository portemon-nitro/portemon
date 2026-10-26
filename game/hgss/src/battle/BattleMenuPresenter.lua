-- Composes the generated lower BG planes for the native battle menu.

---@class BattleMenuPresenter
local BattleMenuPresenter = {}
local LogicalSurface = require("libs.ui.src.LogicalSurface")

-- Resolves the drawable sampler behind one handle: the handle itself
-- when it samples (pool and test leases), else its admitted effect
-- lease, else nothing. Pool borrows keep their sampler on the outer
-- handle while the inner borrow token only pins the physical entry.
---@param art unknown resolved drawable handle under drawing
---@return table<string, unknown>? drawable sampler, nil for raw images and recording stand-ins
local function samplerOf(art)
  if type(art) ~= "table" then
    return nil
  end
  if type(art.drawQuad) == "function" then
    return art
  end
  local inner = art.lease
  if type(inner) == "table" and type(inner.drawQuad) == "function" then
    return inner
  end
  return nil
end

-- Draws one resolved handle through the shared sampler when it samples,
-- directly otherwise.
---@param graphics table<string, unknown> injected host graphics
---@param art table<string, unknown> resolved drawable handle under drawing
---@param x number draw position x
---@param y number draw position y
local function drawArtwork(graphics, art, x, y)
  local sampler = samplerOf(art)
  if sampler ~= nil then
    sampler:draw(graphics, x, y)
  else
    graphics.draw(art, x, y)
  end
end

local BLEND_SHADER = [[
extern Image underlay;
vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
  vec4 top = Texel(texture, texture_coords);
  vec4 bottom = Texel(underlay, texture_coords);
  vec3 blended = mix(top.rgb, clamp((top.rgb * 8.0 + bottom.rgb * 12.0) / 16.0, 0.0, 1.0), bottom.a);
  return vec4(mix(bottom.rgb, blended, top.a), max(bottom.a, top.a)) * color;
}
]]

local PULSE_COLOR = { 0.741176, 0.549020, 1.0 }

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

  -- Source BG1 is the alpha blend's first target over the planes below
  -- it; planes above BG1 cover the blended result like any opaque plane.
  local blendIndex = nil
  for index, entry in ipairs(ordered) do
    if entry.layer.plane == 1 then
      blendIndex = index
    end
  end
  if blendIndex == nil then
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
    for index = 1, blendIndex - 1 do
      BattleMenuPresenter._drawWithWindows(graphics, assets, layout, view, ordered[index], menuWindows)
    end
    graphics.setCanvas(topCanvas)
    graphics.origin()
    graphics.setScissor()
    graphics.clear(0, 0, 0, 0)
    BattleMenuPresenter._drawWithWindows(graphics, assets, layout, view, ordered[blendIndex], menuWindows)
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
    for index = blendIndex + 1, #ordered do
      BattleMenuPresenter._drawWithWindows(graphics, assets, layout, view, ordered[index], menuWindows)
    end
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
---@param entry { index: integer, layer: { plane: integer, priority: number?, pulse?: boolean, feedback: table<string, table<string, { x: number, y: number }>>? }, priority: number } selected screen entry
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
---@param entry { index: integer, layer: { plane: integer, priority: number?, pulse?: boolean, feedback: table<string, table<string, { x: number, y: number }>>? }, priority: number } selected screen entry
function BattleMenuPresenter._drawLayer(graphics, assets, layout, view, entry)
  local layer = entry.layer
  local touch = view.touchFeedback == true and ":touch" or ""
  local art = assets:drawable("menu:" .. layout .. ":screen:" .. tostring(entry.index) .. touch)
  if art ~= nil then
    if layer.pulse == true and type(view.menuPulse) == "number" and view.menuPulse > 0 then
      local mask = assert(assets:drawable("menu:pulse-mask"), "the battle backdrop pulse carries its index mask")
      graphics.push("all")
      drawArtwork(graphics, art, 0, 0)
      graphics.setColor(PULSE_COLOR[1], PULSE_COLOR[2], PULSE_COLOR[3], view.menuPulse / 16)
      drawArtwork(graphics, mask, 0, 0)
      graphics.pop()
    else
      drawArtwork(graphics, art, 0, 0)
    end
  end
  local armed = type(view.armed) == "table" and view.armed or nil
  if armed ~= nil and (armed.scope ~= layout or type(armed.id) ~= "string") then
    armed = nil
  end
  -- Move buttons carry their move's type palette and an empty slot shows
  -- the blank button; a held move button shows its pressed tilemap.
  local moveButtons = layer.moveButtons --[[@as table<integer, table<string, unknown>>?]]
  if moveButtons ~= nil then
    local movesBySlot = {}
    for _, move in ipairs(type(view.moves) == "table" and view.moves or {}) do
      if type(move) == "table" and type(move.slot) == "number" then
        movesBySlot[move.slot] = move
      end
    end
    for slotIndex, button in ipairs(moveButtons) do
      local slot = slotIndex - 1
      -- Unlearned slots arrive as placeholder records without a move.
      local move = movesBySlot[slot]
      local variant = "empty"
      if move ~= nil and move.name ~= nil then
        local state = armed ~= nil and armed.id == "move:" .. slot and "pressed" or "normal"
        variant = assert(move.moveType, "displayed moves carry their type"):lower() .. ":" .. state
      end
      local buttonArt = assets:drawable("menu:moves:move-button:" .. slot .. ":" .. variant)
      if buttonArt ~= nil then
        drawArtwork(graphics, buttonArt, button.x, button.y)
      end
    end
  end
  if type(layer.feedback) ~= "table" then
    return
  end
  -- BattleInput_CopyButtonTilemap swaps in the pressed tilemap only while
  -- a touched control is held; keypad focus is the cursor's job.
  if armed == nil or (moveButtons ~= nil and armed.id:match("^move:") ~= nil) then
    return
  end
  local controls = layer.feedback[armed.id]
  local feedback = type(controls) == "table" and controls.pressed or nil
  if type(feedback) ~= "table" then
    return
  end
  local patchImage = assets:drawable("menu:" .. layout .. ":feedback:" .. armed.id .. ":pressed")
  if patchImage ~= nil then
    drawArtwork(graphics, patchImage, feedback.x, feedback.y)
  end
end

-- Child-scoped controls mapped onto the source two-option identities.
local CHILD_TWO_OPTION = { confirm = "yes", back = "cancel" }

-- Draws the learning confirmation's two-option planes with the armed
-- child control selecting and pressing its source option: Confirm the top
-- "yes" option and Back the bottom "cancel" option.
---@param graphics love.graphics borrowed renderer graphics
---@param assets table<string, unknown> generated image holder
---@param view table<string, unknown> semantic render snapshot carrying the menu layers and armed control
---@return string? pressed source option identity, nil while no child control is armed
function BattleMenuPresenter.drawChildTwoOption(graphics, assets, view)
  local menuLayers = assert(view.menuLayers, "the battle view carries generated menu screen layers")
  local layers = assert(menuLayers.twoOption, "the battle view carries source two-option layers") --[[@as table[] ]]
  local armed = view.armed
  local pressed = nil
  if type(armed) == "table" and armed.scope == "child" then
    pressed = CHILD_TWO_OPTION[armed.id]
  end
  BattleMenuPresenter.draw(graphics, assets, "two-option", layers, {
    selection = pressed,
    armed = pressed ~= nil and { scope = "two-option", id = pressed } or nil,
  })
  return pressed
end

return BattleMenuPresenter
