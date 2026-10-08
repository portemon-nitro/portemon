-- Source-defined battle drawing for one paired pane. The detail pane
-- draws the persistent compiled scene, the battler pictures with their
-- transient recoil offsets, the HUD composites with dynamic name, level,
-- HP and EXP facts, the selection arrow, and the narration window with
-- the selected frame. The interaction pane draws the selected menu
-- states with their labels, party gauges, and move facts in compiled
-- order. Images resolve through the injected asset holder; missing
-- images draw nothing, never substitutes. All coordinates are native
-- logical pixels; the pane transform is owned by the caller.

---@class BattleRenderer
local BattleRenderer = {}

-- Interim battler centers on the native canvas: a product baseline for
-- the idle pose, not a forensic claim about every species pose.
BattleRenderer.PLAYER_CENTER = { x = 64, y = 112 }
BattleRenderer.ENEMY_CENTER = { x = 192, y = 56 }

-- Native HUD anchors and the player arrow offset beside the player
-- anchor, in native logical pixels. The enemy anchor is used unclamped:
-- its composite starts offscreen like the source layout.
BattleRenderer.PLAYER_HUD = { x = 192, y = 116 }
BattleRenderer.ENEMY_HUD = { x = 58, y = 36 }
BattleRenderer.ARROW_OFFSET = 72

-- Staged sprite strips behind the battle keys: one 8-pixel tile row, so
-- each width is eight times the compiled tile count (both HUD strips 128
-- tiles, the arrow 26 tiles, the 16-pixel gauge family 16 tiles). The
-- ROM-backed captures pin these against the staged manifest; a producer
-- repagination fails there first.
local STRIP_HEIGHT = 8
local HUD_STRIP_WIDTH = 1024
local ARROW_STRIP_WIDTH = 208
local GAUGE_STRIP_WIDTH = 128

-- Authored HUD cells: two 64x64 objects each, drawn at the anchor with
-- the compiled local offsets.
local PLAYER_HUD_OBJECTS = {
  { tile = 0, width = 64, height = 64, x = -64, y = -32 },
  { tile = 32, width = 64, height = 64, x = 0, y = -32 },
}
local ENEMY_HUD_OBJECTS = {
  { tile = 0, width = 64, height = 64, x = -64, y = -28 },
  { tile = 32, width = 64, height = 64, x = 0, y = -28 },
}

-- Authored arrow cells in animation order: the zero-time opening cell
-- carries no objects and draws nothing, the rest hold their authored
-- counts through the selection clock the screen owns.
local ARROW_CELLS = {
  {},
  { { tile = 0, width = 16, height = 16, x = -8, y = -8 } },
  { { tile = 2, width = 16, height = 16, x = -8, y = -8 } },
  {
    { tile = 4, width = 16, height = 16, x = -16, y = -8 },
    { tile = 6, width = 8, height = 16, x = 0, y = -8 },
  },
  {
    { tile = 7, width = 16, height = 16, x = -16, y = -8 },
    { tile = 9, width = 8, height = 16, x = 0, y = -8 },
  },
  {
    { tile = 10, width = 16, height = 16, x = -16, y = -8 },
    { tile = 12, width = 8, height = 16, x = 0, y = -8 },
  },
}

-- 16-pixel gauge cells by roster visibility: 0 absent/unrevealed, 1
-- present/revealed, 2 fainted. The fourth authored state has no roster
-- meaning and stays unused, as does the 32-pixel family.
local GAUGE_CELL_TILES = { 0, 4, 8 }
local GAUGE_CELL_SIZE = 16
local GAUGE_CELL_OFFSET = -8

-- Dynamic content anchors inside the composite bounds, in native logical
-- pixels: the enemy box spans (-6,8)-(122,72), the player box
-- (128,84)-(256,148). Name, level, and numeric health keep their
-- established anchors; the condition rides beside the level, the enemy
-- bar mirrors the player bar row, and the numeric experience sits
-- beneath the player health row.
local ENEMY_CONDITION = { x = 40, y = 28 }
local ENEMY_BAR = { x = 8, y = 44, width = 48, height = 4 }
local PLAYER_CONDITION = { x = 176, y = 104 }
-- The numeric experience shares the health row right of the numbers: the
-- narration frame tiles cover rows 136 and below, so nothing dynamic
-- sits beneath the health row.
local PLAYER_EXP = { x = 192, y = 116 }

-- Narration window: content origin with its size, wrapped by the
-- selected frame border.
local NARRATION_BOX = { x = 8, y = 144, width = 240, height = 40 }
local NARRATION_TEXT = { x = 16, y = 152 }

-- Command text anchors from the source bounds table.
local COMMAND_ANCHORS = {
  fight = { x = 128, y = 83 },
  bag = { x = 40, y = 169 },
  pokemon = { x = 216, y = 168 },
  run = { x = 128, y = 176 },
}
local COMMAND_LABELS = { fight = "FIGHT", bag = "BAG", pokemon = "POKEMON", run = "RUN" }

-- Move text anchors from the source two-by-two table. Move names keep
-- these anchors; the type and PP facts sit on the row beneath at their
-- own compiled anchors.
local MOVE_ANCHORS = {
  { x = 64, y = 45 },
  { x = 192, y = 44 },
  { x = 64, y = 108 },
  { x = 192, y = 107 },
}
local TYPE_ANCHORS = {
  { x = 32, y = 61 },
  { x = 160, y = 60 },
  { x = 32, y = 124 },
  { x = 160, y = 123 },
}
local PP_CURRENT_ANCHORS = {
  { x = 59, y = 61 },
  { x = 187, y = 60 },
  { x = 59, y = 124 },
  { x = 187, y = 123 },
}
local PP_MAX_ANCHORS = {
  { x = 76, y = 61 },
  { x = 204, y = 60 },
  { x = 76, y = 124 },
  { x = 204, y = 123 },
}
local CANCEL_ANCHOR = { x = 128, y = 175 }

-- Party gauge slots on the interaction pane, six per side. The 16-pixel
-- source cells center on these origins through their compiled offsets.
local GAUGE_PLAYER_X = 12
local GAUGE_PLAYER_Y = 13
local GAUGE_PLAYER_PITCH = 19
local GAUGE_ENEMY_RIGHT = 246
local GAUGE_ENEMY_Y = 9
local GAUGE_ENEMY_PITCH = 12
local GAUGE_CELL_WIDTH = 16

---@param graphics table<string, unknown> injected host graphics
---@return number, number, number, number borrowed color for restoration
local function saveColor(graphics)
  return graphics.getColor()
end

---@param graphics table<string, unknown>
---@param r number
---@param g number
---@param b number
---@param a number
local function restoreColor(graphics, r, g, b, a)
  graphics.setColor(r, g, b, a)
end

---@param view table<string, unknown> internal semantic snapshot
---@return table<string, unknown>? player-side battler facts
---@return table<string, unknown>? enemy-side battler facts
local function splitBattlers(view)
  local player, enemy = nil, nil
  if type(view.battlers) == "table" then
    for _, battler in ipairs(view.battlers) do
      if type(battler) == "table" then
        if battler.side == 1 and player == nil then
          player = battler
        elseif battler.side ~= 1 and enemy == nil then
          enemy = battler
        end
      end
    end
  end
  return player, enemy
end

---@param hp number
---@param maxHp number
---@return number fraction clamped to valid pixel bounds
local function barFraction(hp, maxHp)
  if type(maxHp) ~= "number" or maxHp <= 0 then
    return 0
  end
  local fraction = hp / maxHp
  if fraction < 0 then
    return 0
  end
  if fraction > 1 then
    return 1
  end
  return fraction
end

---@param graphics table<string, unknown>
---@param text table<string, unknown> borrowed text services
---@param name string
---@param level integer?
---@param x number
---@param y number
local function drawNameLevel(graphics, text, name, level, x, y)
  local _ = graphics
  text.drawText(tostring(name), x, y)
  if type(level) == "number" then
    text.drawText("Lv" .. tostring(level), x, y + 12)
  end
end

-- Draws one compiled sprite object from its staged tile strip: tiles lay
-- out row-major from the object base tile, so each 8-pixel band is one
-- quad over the single strip row.
---@param graphics table<string, unknown> injected host graphics
---@param image table<string, unknown> staged strip handle under drawing
---@param stripWidth integer staged strip width in pixels
---@param baseX number anchor horizontal origin under drawing
---@param baseY number anchor vertical origin under drawing
---@param obj table<string, unknown> compiled object carrying tile, width, height, x, y
local function drawSpriteObject(graphics, image, stripWidth, baseX, baseY, obj)
  local tile = obj.tile --[[@as integer]]
  local width = obj.width --[[@as integer]]
  local height = obj.height --[[@as integer]]
  local tilesPerRow = math.floor(width / 8)
  local rows = math.floor(height / 8)
  for row = 0, rows - 1 do
    local quad = graphics.newQuad((tile + row * tilesPerRow) * 8, 0, width, STRIP_HEIGHT, stripWidth, STRIP_HEIGHT)
    graphics.draw(image, quad, baseX + obj.x --[[@as number]], baseY + obj.y --[[@as number]] + row * 8)
  end
end

-- Draws one authored HUD composite at its anchor with the compiled local
-- offsets. A missing strip draws nothing, never a substitute.
---@param graphics table<string, unknown> injected host graphics
---@param assets table<string, unknown> injected asset holder
---@param artKey string staged strip identity under drawing
---@param anchor table<string, number> composite anchor under drawing
---@param objects table<integer, table<string, unknown>> compiled objects under drawing
local function drawHudComposite(graphics, assets, artKey, anchor, objects)
  local art = assets:drawable(artKey)
  if art == nil then
    return
  end
  for _, obj in ipairs(objects) do
    drawSpriteObject(graphics, art --[[@as table<string, unknown>]], HUD_STRIP_WIDTH, anchor.x, anchor.y, obj)
  end
end

-- Colors one health fill by its fraction: full, worn, then critical.
---@param graphics table<string, unknown> injected host graphics
---@param fraction number health fraction under coloring
local function setBarColor(graphics, fraction)
  if fraction > 0.5 then
    graphics.setColor(0.2, 0.8, 0.2, 1)
  elseif fraction > 0.2 then
    graphics.setColor(0.9, 0.8, 0.2, 1)
  else
    graphics.setColor(0.9, 0.2, 0.2, 1)
  end
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
local function drawDetail(resources, view)
  local graphics = assert(resources.graphics, "the battle render borrows its host graphics")
  local text = assert(resources.text, "the battle render borrows its text services")
  local windows = assert(resources.windows, "the battle render borrows its window services")
  local assets = assert(resources.assets, "the battle render borrows its asset holder")
  local r, g, b, a = saveColor(graphics)
  local scene = assets:drawable(resources.sceneImageKey --[[@as string]])
  if scene ~= nil then
    graphics.draw(scene, 0, 0)
  end
  local player, enemy = splitBattlers(view)
  if enemy ~= nil and enemy.visible ~= false then
    local front = assets:drawable("mon:enemy:front")
    if front ~= nil then
      local dx = (type(enemy.shakeDx) == "number" and enemy.shakeDx or 0) --[[@as number]]
      graphics.draw(front, BattleRenderer.ENEMY_CENTER.x + dx, BattleRenderer.ENEMY_CENTER.y)
    end
    drawHudComposite(graphics, assets, "hud:enemy", BattleRenderer.ENEMY_HUD, ENEMY_HUD_OBJECTS)
    drawNameLevel(graphics, text, enemy.name or "FOE", enemy.level --[[@as integer?]], 8, 16)
    if type(enemy.condition) == "string" and enemy.condition ~= "" then
      text.drawText(enemy.condition --[[@as string]], ENEMY_CONDITION.x, ENEMY_CONDITION.y)
    end
    local foeHp = (type(enemy.hp) == "number" and enemy.hp or 0) --[[@as number]]
    local foeMaxHp = (type(enemy.maxHp) == "number" and enemy.maxHp or 1) --[[@as number]]
    local foeFraction = barFraction(foeHp, foeMaxHp)
    setBarColor(graphics, foeFraction)
    graphics.rectangle("fill", ENEMY_BAR.x, ENEMY_BAR.y, ENEMY_BAR.width * foeFraction, ENEMY_BAR.height)
    restoreColor(graphics, r, g, b, a)
  end
  if player ~= nil and player.visible ~= false then
    local back = assets:drawable("mon:player:back")
    if back ~= nil then
      local dx = (type(player.shakeDx) == "number" and player.shakeDx or 0) --[[@as number]]
      graphics.draw(back, BattleRenderer.PLAYER_CENTER.x + dx, BattleRenderer.PLAYER_CENTER.y)
    end
    drawHudComposite(graphics, assets, "hud:player", BattleRenderer.PLAYER_HUD, PLAYER_HUD_OBJECTS)
    local hp = (type(player.hp) == "number" and player.hp or 0) --[[@as number]]
    local maxHp = (type(player.maxHp) == "number" and player.maxHp or 1) --[[@as number]]
    drawNameLevel(graphics, text, player.name or "LEAD", player.level --[[@as integer?]], 144, 92)
    if type(player.condition) == "string" and player.condition ~= "" then
      text.drawText(player.condition --[[@as string]], PLAYER_CONDITION.x, PLAYER_CONDITION.y)
    end
    text.drawText(tostring(hp) .. "/" .. tostring(maxHp), 144, 116)
    local fraction = barFraction(hp, maxHp)
    setBarColor(graphics, fraction)
    graphics.rectangle("fill", 144, 108, 48 * fraction, 4)
    restoreColor(graphics, r, g, b, a)
    if type(player.exp) == "number" then
      text.drawText(tostring(player.exp --[[@as number]]), PLAYER_EXP.x, PLAYER_EXP.y)
    end
  end
  if view.mode == "command" or view.mode == "moves" or view.mode == "target" then
    local cell = view.arrowFrame --[[@as integer?]]
    if type(cell) == "number" and cell >= 1 and cell <= #ARROW_CELLS - 1 then
      local art = assets:drawable("arrow")
      if art ~= nil then
        local baseX = BattleRenderer.PLAYER_HUD.x - BattleRenderer.ARROW_OFFSET
        local baseY = BattleRenderer.PLAYER_HUD.y - 2
        for _, obj in ipairs(ARROW_CELLS[cell + 1]) do
          drawSpriteObject(graphics, art --[[@as table<string, unknown>]], ARROW_STRIP_WIDTH, baseX, baseY, obj)
        end
      end
    end
  end
  if type(view.message) == "string" and view.message ~= "" then
    windows.drawWindow(NARRATION_BOX, resources.frameKey, { 0, 0, 0 })
    text.drawText(view.message --[[@as string]], NARRATION_TEXT.x, NARRATION_TEXT.y)
  end
  restoreColor(graphics, r, g, b, a)
end

---@param text table<string, unknown> borrowed text services
---@param content string label wording under truncation
---@param maxWidth number region width under truncation
---@return string label fitting its region
local function fitLabel(text, content, maxWidth)
  local label = tostring(content)
  if type(text.measure) == "function" and maxWidth > 0 then
    while #label > 1 and text.measure(label).width > maxWidth do
      label = label:sub(1, #label - 1)
    end
  end
  return label
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
---@param layout string active menu layout under drawing
---@param regions table<string, unknown>[] hit regions under drawing
local function drawControls(resources, view, layout, regions)
  local graphics = assert(resources.graphics, "the battle render borrows its host graphics")
  local text = assert(resources.text, "the battle render borrows its text services")
  local assets = assert(resources.assets, "the battle render borrows its asset holder")
  local r, g, b, a = saveColor(graphics)
  local armed = view.armed --[[@as table<string, unknown>?]]
  local movesBySlot = {}
  if type(view.moves) == "table" then
    for _, move in ipairs(view.moves) do
      if type(move) == "table" and type(move.slot) == "number" then
        movesBySlot[
          move.slot --[[@as integer]]
        ] = move
      end
    end
  end
  local commandsById = {}
  if type(view.commands) == "table" then
    for _, command in ipairs(view.commands) do
      if type(command) == "table" and type(command.id) == "string" then
        commandsById[
          command.id --[[@as string]]
        ] = command
      end
    end
  end
  for _, region in ipairs(regions) do
    local box = region --[[@as table<string, unknown>]]
    local id = box.id --[[@as string]]
    local pressed = armed ~= nil and armed.id == id and armed.scope == layout
    local shift = pressed and 1 or 0
    local art = assets:drawable("menu:" .. layout .. ":" .. id)
    local slot = id:match("^move:(%d+)$")
    if slot ~= nil and movesBySlot[tonumber(slot)] == nil then
      -- Missing move slots stay visibly empty: no art, no label.
    else
      if art ~= nil then
        graphics.draw(art, box.x --[[@as number]] + shift, box.y --[[@as number]] + shift)
      end
      if layout == "command" and COMMAND_ANCHORS[id] ~= nil then
        local anchor = COMMAND_ANCHORS[id]
        local entry = commandsById[id]
        local enabled = entry == nil or entry.enabled ~= false
        if enabled or id == "fight" or id == "bag" or id == "pokemon" then
          text.drawText(COMMAND_LABELS[id] or id, anchor.x + shift, anchor.y + shift)
        else
          text.drawText(fitLabel(text, COMMAND_LABELS[id] or id, box.w --[[@as number]]), anchor.x, anchor.y)
        end
      elseif slot ~= nil then
        local slotIndex = tonumber(slot) --[[@as integer]]
        local move = movesBySlot[slotIndex]
        local anchor = MOVE_ANCHORS[slotIndex + 1]
        local typeAnchor = TYPE_ANCHORS[slotIndex + 1]
        local ppCurrent = PP_CURRENT_ANCHORS[slotIndex + 1]
        local ppMax = PP_MAX_ANCHORS[slotIndex + 1]
        if move ~= nil and anchor ~= nil and move.name ~= nil then
          text.drawText(fitLabel(text, move.name --[[@as string]], 120), anchor.x + shift, anchor.y + shift)
          if ppCurrent ~= nil and ppMax ~= nil then
            text.drawText(tostring(move.pp), ppCurrent.x + shift, ppCurrent.y + shift)
            text.drawText("/" .. tostring(move.maxPp), ppMax.x + shift, ppMax.y + shift)
          end
          if move.moveType ~= nil and typeAnchor ~= nil then
            text.drawText(tostring(move.moveType), typeAnchor.x + shift, typeAnchor.y + shift)
          end
        end
      elseif id == "cancel" then
        text.drawText("CANCEL", CANCEL_ANCHOR.x + shift, CANCEL_ANCHOR.y + shift)
      elseif id:match("^target:") ~= nil then
        text.drawText(">", box.x --[[@as number]] + shift, box.y --[[@as number]] + shift)
      end
    end
  end
  restoreColor(graphics, r, g, b, a)
end

-- Draws one party gauge cell from the 16-pixel family: tiles lay out
-- row-major from the state base tile in the single strip row.
---@param graphics table<string, unknown> injected host graphics
---@param image table<string, unknown> staged gauge strip handle under drawing
---@param slotX number slot horizontal origin under drawing
---@param slotY number slot vertical origin under drawing
---@param state integer roster visibility state under drawing: 0 absent, 1 present, 2 fainted
local function drawGaugeCell(graphics, image, slotX, slotY, state)
  local tile = GAUGE_CELL_TILES[state + 1] or GAUGE_CELL_TILES[1]
  drawSpriteObject(graphics, image, GAUGE_STRIP_WIDTH, slotX, slotY, {
    tile = tile,
    width = GAUGE_CELL_SIZE,
    height = GAUGE_CELL_SIZE,
    x = GAUGE_CELL_OFFSET,
    y = GAUGE_CELL_OFFSET,
  })
end

-- Draws both party rows from the 16-pixel source family by roster
-- visibility: the committed battle roster behind the player row, the
-- revealed active-foe count behind the enemy row. Unrevealed foes keep
-- the absent cell, so no unrevealed species ever shows. A missing strip
-- draws nothing, never a substitute.
---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
local function drawGauges(resources, view)
  local graphics = assert(resources.graphics, "the battle render borrows its host graphics")
  local assets = assert(resources.assets, "the battle render borrows its asset holder")
  local roster = {}
  if type(view.partyRoster) == "table" then
    roster = view.partyRoster --[[@as table[] ]]
  end
  local playerArt = assets:drawable("gauges:player")
  if playerArt ~= nil then
    for index = 0, 5 do
      local entry = roster[index + 1]
      local state = 0
      if entry ~= nil and type(entry.hp) == "number" then
        state = (
          entry.hp --[[@as number]]
          > 0
        ) and 1 or 2
      end
      drawGaugeCell(
        graphics,
        playerArt --[[@as table<string, unknown>]],
        GAUGE_PLAYER_X + GAUGE_PLAYER_PITCH * index,
        GAUGE_PLAYER_Y,
        state
      )
    end
  end
  local enemyArt = assets:drawable("gauges:enemy")
  if enemyArt ~= nil then
    local revealed = (type(view.foeCount) == "number" and view.foeCount or 1) --[[@as integer]]
    for index = 0, 5 do
      local state = 0
      if index < revealed then
        state = 1
      end
      drawGaugeCell(
        graphics,
        enemyArt --[[@as table<string, unknown>]],
        GAUGE_ENEMY_RIGHT - GAUGE_ENEMY_PITCH * index - GAUGE_CELL_WIDTH,
        GAUGE_ENEMY_Y,
        state
      )
    end
  end
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
---@param content table<string, unknown> canonical plan content carrying the layout
local function drawInteraction(resources, view, content)
  local graphics = assert(resources.graphics, "the battle render borrows its host graphics")
  local assets = assert(resources.assets, "the battle render borrows its asset holder")
  local layout = content.layout --[[@as string]]
  if layout ~= "command" and layout ~= "moves" and layout ~= "target" then
    layout = "command"
  end
  local background = assets:drawable("menu:" .. layout)
  if background ~= nil then
    graphics.draw(background, 0, 0)
  end
  local regions = {}
  if layout == "moves" then
    regions = {
      { id = "move:0", x = 0, y = 24, w = 128, h = 56 },
      { id = "move:1", x = 128, y = 24, w = 128, h = 56 },
      { id = "move:2", x = 0, y = 88, w = 128, h = 56 },
      { id = "move:3", x = 128, y = 88, w = 128, h = 56 },
      { id = "cancel", x = 8, y = 152, w = 240, h = 40 },
    }
  elseif layout == "target" then
    regions = {
      { id = "target:0", x = 28, y = 92, w = 64, h = 48 },
      { id = "target:1", x = 164, y = 8, w = 64, h = 48 },
      { id = "target:2", x = 164, y = 92, w = 64, h = 48 },
      { id = "target:3", x = 28, y = 8, w = 64, h = 48 },
      { id = "cancel", x = 8, y = 152, w = 240, h = 40 },
    }
  else
    regions = {
      { id = "fight", x = 0, y = 24, w = 256, h = 120 },
      { id = "bag", x = 0, y = 144, w = 80, h = 48 },
      { id = "pokemon", x = 176, y = 144, w = 80, h = 48 },
      { id = "run", x = 88, y = 152, w = 80, h = 40 },
    }
  end
  drawControls(resources, view, layout, regions)
  drawGauges(resources, view)
end

-- Draws one paired pane in its logical space: "detail" for the
-- battlefield or "interaction" for the lower menu. Unknown pane
-- identities draw nothing.
---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
---@param paneId string resolved pane identity
---@param content table<string, unknown> canonical plan content carrying the layout
function BattleRenderer.drawPane(resources, view, paneId, content)
  assert(type(resources) == "table", "pane drawing borrows its resources")
  assert(type(view) == "table", "pane drawing reads its snapshot")
  if paneId == "detail" then
    drawDetail(resources, view)
  elseif paneId == "interaction" then
    drawInteraction(resources, view, content or {})
  end
end

return BattleRenderer
