-- Composes the generated lower BG planes for the native battle menu.

---@class BattleMenuPresenter
local BattleMenuPresenter = {}

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

local PULSE_COLOR = { 0.741176, 0.549020, 1.0 }

-- Source lower BG planes ride fixed sub-engine roles: buttons on menu,
-- panels on window, the backdrop on transition. The unified sub-engine
-- frame owns visibility, priority, windows and blending; a plane entry
-- only forwards its staged content.
---@param plane integer source lower BG plane 0..3
---@return string sub-engine role behind the plane
function BattleMenuPresenter.roleForPlane(plane)
  if plane == 0 then
    return "menu"
  elseif plane == 1 then
    return "window"
  elseif plane == 2 then
    return "transition"
  elseif plane == 3 then
    return "battlefield"
  end
  error("unknown lower menu plane: " .. tostring(plane), 0)
end

-- Draws one already-generated menu layer's content into the pass-owned
-- target: staged tilemaps, move buttons and pressed-button feedback.
-- Visibility, priority, window, scroll and blend selection belong to
-- the unified sub-engine frame, never to this content callback.
---@param graphics love.graphics borrowed renderer graphics
---@param assets table<string, unknown> generated image holder
---@param layout string selected lower menu layout
---@param view table<string, unknown> semantic render snapshot
---@param entry { index: integer, layer: { plane: integer, priority: number?, pulse?: boolean, feedback: table<string, table<string, { x: number, y: number }>>? } } selected screen entry
function BattleMenuPresenter.drawPlane(graphics, assets, layout, view, entry)
  assert(type(entry) == "table", "menu plane draws carry their screen entry")
  assert(
    type(entry.layer) == "table" and type(entry.layer.plane) == "number",
    "menu plane draws name their source plane"
  )
  BattleMenuPresenter.roleForPlane(entry.layer.plane)
  BattleMenuPresenter._drawLayer(graphics, assets, layout, view, entry)
end

---@param graphics love.graphics borrowed renderer graphics
---@param assets table<string, unknown> generated image holder
---@param layout string selected lower menu layout
---@param view table<string, unknown> semantic render snapshot
---@param entry { index: integer, layer: { plane: integer, priority: number?, pulse?: boolean, feedback: table<string, table<string, { x: number, y: number }>>? } } selected screen entry
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
BattleMenuPresenter.CHILD_TWO_OPTION = { confirm = "yes", back = "cancel" }

return BattleMenuPresenter
