-- Single-pane battle composition over the shared battle controller. One
-- 256x192 logical surface carries the battlefield scene above a framed
-- dock: the question on the left with a two-by-two text command grid on
-- the right, a taller move dock with a type/PP panel and a Back cell, a
-- full-width target dock, or a full-width narration dock. The scene keeps
-- both combatant HUDs from the selected source artwork with their dynamic
-- name, level, condition and health regions at the plan bounds. Framed
-- boxes derive from their outer allocations through the real dialogue theme
-- insets; borders come from the shared application-frame renderer after
-- text draws; pointer regions are the same half-open cells the drawing
-- uses. Selection, timeline, messages and reply submission stay with the
-- existing screen controller: this module only resolves geometry, draws
-- the scene HUD and the dock, and maps pointer input to the shared
-- semantic controls.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class BattleCompactInterface
local BattleCompactInterface = {}

BattleCompactInterface.NATIVE = { id = "compact", width = 256, height = 192 }

local INPUT_KEY = "battle-compact"
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }
local CURSOR = "‣"

-- Fixed single-pane allocations; all rect intervals are half-open.
local SCENE = { x = 0, y = 0, width = 256, height = 136 }
local PROMPT_OUTER = { x = 0, y = 136, width = 112, height = 56 }
local COMMAND_OUTER = { x = 112, y = 136, width = 144, height = 56 }
local MOVE_DOCK = { x = 0, y = 120, width = 256, height = 72 }
local MOVE_LEFT_OUTER = { x = 0, y = 120, width = 192, height = 72 }
local MOVE_RIGHT_OUTER = { x = 192, y = 120, width = 64, height = 72 }
local TARGET_OUTER = { x = 0, y = 120, width = 256, height = 72 }
local NARRATION_OUTER = { x = 0, y = 136, width = 256, height = 56 }
local PROMPT_ORIGIN = { x = 12, y = 146 }
local PROMPT_MAX_WIDTH = 88
local COMMAND_IDS = { "fight", "bag", "pokemon", "run" }
local COMMAND_LABELS = { fight = "FIGHT", bag = "BAG", pokemon = "POKEMON", run = "RUN" }
local COMMAND_CELL_WIDTH = 64
local COMMAND_CELL_HEIGHT = 20
local MOVE_GRID_X = 8
local MOVE_GRID_TOP = 128
local MOVE_COLUMN_WIDTH = 88
local MOVE_ROW_HEIGHT = 28
local MOVE_LABEL_WIDTH = 79
local MOVE_BACK_RECT = { x = 200, y = 164, width = 48, height = 20 }
local MOVE_BACK_LABEL = { x = 204, y = 166 }
local MOVE_INFO_TEXT_X = 202
local MOVE_INFO_TYPE_Y = 130
local MOVE_INFO_PP_Y = 148
local MOVE_INFO_MAX_WIDTH = 44
-- Planning advance per character for move information text. The draw path
-- re-fits with the live text service; this estimate keeps ordinary type
-- and PP representations on one row without a text boundary at resolve.
local MOVE_INFO_ADVANCE = 6
local TARGET_FIRST_Y = 130
local TARGET_ROW_HEIGHT = 16
local TARGET_ROW_X = 12
local TARGET_ROW_WIDTH = 232
local NARRATION_ORIGIN = { x = 12, y = 146 }
local NARRATION_WIDTH = 232
local CONTINUE_MARK = ">"
local CONTINUE_ORIGIN = { x = 232, y = 166 }
local HUD_ENEMY = { x = 4, y = 4 }
local HUD_PLAYER_RIGHT = 252
local HUD_PLAYER_BOTTOM = 132
-- Fixed single-pane HUD boxes: the enemy bounds sit at the left/top
-- anchor, the player bounds sit with their right/bottom edges at the
-- player anchors. Rows follow the paired name/level pitch with the
-- paired 48-pixel health bar; the player box adds an experience row.
local HUD_ENEMY_BOX = { width = 96, height = 36 }
local HUD_PLAYER_BOX = { width = 104, height = 48 }
local HUD_BAR_WIDTH = 48
local HUD_BAR_HEIGHT = 4
local HUD_ROW_HEIGHT = 12
local PLAYER_CENTER = { x = 60, y = 96 }
local ENEMY_CENTER = { x = 196, y = 44 }

---@param outer table<string, unknown> half-open outer allocation
---@return table<string, unknown> framed content box derived through the real theme insets
local function contentOf(outer)
  local insets = FieldDialogueTheme.applicationFrameInsets()
  return {
    x = outer.x + insets.left,
    y = outer.y + insets.top + 1,
    width = outer.width - insets.left - insets.right,
    height = outer.height - insets.top - insets.bottom - 2,
  }
end

---@param text string label wording under fitting
---@param maxWidth number region width under fitting
---@return string label fitting its region under the planning advance
local function fitPlanning(text, maxWidth)
  local label = tostring(text)
  local glyphs = {}
  for char in Utf8Glyphs.iter(label) do
    glyphs[#glyphs + 1] = char
  end
  while #glyphs > 1 and #glyphs * MOVE_INFO_ADVANCE > maxWidth do
    glyphs[#glyphs] = nil
    label = table.concat(glyphs)
  end
  return label
end

---@param view table<string, unknown> internal semantic snapshot under resolution
---@return table<string, unknown>? named move entry behind the current selection
local function selectedMove(view)
  local moves = {}
  if type(view.moves) == "table" then
    for _, move in ipairs(view.moves) do
      if type(move) == "table" and type(move.slot) == "number" and type(move.name) == "string" then
        moves[move.slot] = move
      end
    end
  end
  local slot = nil
  if type(view.selection) == "string" then
    slot = tonumber((view.selection --[[@as string]]):match("^move:(%d+)$") or "")
  end
  if slot ~= nil and moves[slot] ~= nil then
    return moves[slot]
  end
  for index = 0, 3 do
    if moves[index] ~= nil then
      return moves[index]
    end
  end
  return nil
end

---@param view table<string, unknown> internal semantic snapshot under resolution
---@return table<string, unknown> typed move information rows for the information panel
local function moveInfo(view)
  local entry = selectedMove(view)
  local moveType = "---"
  local ppText = "--/--"
  if entry ~= nil then
    if type(entry.moveType) == "string" and entry.moveType ~= "" then
      moveType = entry.moveType --[[@as string]]
    end
    ppText = tostring(entry.pp or "--") .. "/" .. tostring(entry.maxPp or "--")
  end
  local typeText = fitPlanning(moveType, MOVE_INFO_MAX_WIDTH)
  local fittedPp = fitPlanning(ppText, MOVE_INFO_MAX_WIDTH)
  return {
    typeRowY = MOVE_INFO_TYPE_Y,
    ppRowY = MOVE_INFO_PP_Y,
    typeText = typeText,
    ppText = fittedPp,
    typeWidth = #typeText * MOVE_INFO_ADVANCE,
    ppWidth = #fittedPp * MOVE_INFO_ADVANCE,
  }
end

---@param view table<string, unknown> internal semantic snapshot under resolution
---@return table<integer, table<string, unknown>> admitted target rows with a Back row beneath
local function targetRows(view)
  local rows = {}
  if type(view.battlers) == "table" then
    for _, battler in ipairs(view.battlers) do
      if type(battler) == "table" and battler.side ~= 1 and battler.visible ~= false and #rows < 2 then
        rows[#rows + 1] = {
          id = "target:" .. tostring(#rows),
          name = battler.name,
          level = battler.level,
        }
      end
    end
  end
  local out = {}
  for index, row in ipairs(rows) do
    out[#out + 1] = {
      id = row.id,
      name = row.name,
      level = row.level,
      x = TARGET_ROW_X,
      y = TARGET_FIRST_Y + (index - 1) * TARGET_ROW_HEIGHT,
      width = TARGET_ROW_WIDTH,
      height = TARGET_ROW_HEIGHT,
    }
  end
  out[#out + 1] = {
    id = "cancel",
    x = TARGET_ROW_X,
    y = TARGET_FIRST_Y + #rows * TARGET_ROW_HEIGHT,
    width = TARGET_ROW_WIDTH,
    height = TARGET_ROW_HEIGHT,
  }
  return out
end

---@param mode string controller mode under resolution
---@return string layout scope behind the current mode
local function scopeFor(mode)
  if mode == "moves" then
    return "moves"
  elseif mode == "target" then
    return "target"
  elseif mode == "narration" then
    return "narration"
  end
  return "command"
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

---@param hp unknown health value under bounding
---@param maxHp unknown health ceiling under bounding
---@return number fraction clamped to valid pixel bounds
local function hudFraction(hp, maxHp)
  if type(maxHp) ~= "number" or maxHp <= 0 or type(hp) ~= "number" then
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

---@param battler table<string, unknown>? combatant facts under resolution
---@param fallback string name wording when the snapshot carries none
---@return string resolved display name
local function hudName(battler, fallback)
  if battler ~= nil and type(battler.name) == "string" and battler.name ~= "" then
    return battler.name --[[@as string]]
  end
  return fallback
end

---@param battler table<string, unknown>? combatant facts under resolution
---@return string level wording, empty when the snapshot carries no level
local function hudLevel(battler)
  if battler ~= nil and type(battler.level) == "number" then
    return "Lv" .. tostring(battler.level)
  end
  return ""
end

---@param battler table<string, unknown>? combatant facts under resolution
---@return string condition wording, empty when healthy
local function hudCondition(battler)
  if battler ~= nil and type(battler.condition) == "string" and battler.condition ~= "" then
    return battler.condition --[[@as string]]
  end
  return ""
end

---@param battler table<string, unknown>? combatant facts under resolution
---@return string numeric health wording, empty without both facts
local function hudHealth(battler)
  if battler ~= nil and type(battler.hp) == "number" and type(battler.maxHp) == "number" then
    return tostring(battler.hp) .. "/" .. tostring(battler.maxHp)
  end
  return ""
end

-- One side HUD box with its dynamic regions and health bar: the bounds
-- anchor the complete box while every region carries the resolved
-- snapshot wording for the draw clip. The player box adds the numeric
-- experience row beneath the health row.
---@param battler table<string, unknown>? combatant facts under resolution
---@param fallback string name wording when the snapshot carries none
---@param origin table<string, number> bounds left/top under resolution
---@param size table<string, number> bounds width/height under resolution
---@param withExp boolean true for the player experience row
---@return table<string, unknown> anchored HUD box content
local function hudBox(battler, fallback, origin, size, withExp)
  local hp = (battler ~= nil and type(battler.hp) == "number" and battler.hp or 0) --[[@as number]]
  local maxHp = (battler ~= nil and type(battler.maxHp) == "number" and battler.maxHp or 0) --[[@as number]]
  local fraction = hudFraction(hp, maxHp)
  local levelWidth = math.floor(size.width / 2)
  local regions = {
    {
      id = "name",
      x = origin.x,
      y = origin.y,
      width = size.width,
      height = HUD_ROW_HEIGHT,
      text = hudName(battler, fallback),
    },
    {
      id = "level",
      x = origin.x,
      y = origin.y + HUD_ROW_HEIGHT,
      width = levelWidth,
      height = HUD_ROW_HEIGHT,
      text = hudLevel(battler),
    },
    {
      id = "condition",
      x = origin.x + levelWidth,
      y = origin.y + HUD_ROW_HEIGHT,
      width = size.width - levelWidth,
      height = HUD_ROW_HEIGHT,
      text = hudCondition(battler),
    },
    {
      id = "hp",
      x = origin.x + HUD_BAR_WIDTH + 4,
      y = origin.y + 2 * HUD_ROW_HEIGHT,
      width = size.width - HUD_BAR_WIDTH - 4,
      height = HUD_ROW_HEIGHT,
      text = hudHealth(battler),
    },
  }
  if withExp then
    local expText = ""
    if battler ~= nil and type(battler.exp) == "number" then
      expText = tostring(battler.exp)
    end
    regions[#regions + 1] = {
      id = "exp",
      x = origin.x,
      y = origin.y + 3 * HUD_ROW_HEIGHT,
      width = size.width,
      height = HUD_ROW_HEIGHT,
      text = expText,
    }
  end
  return {
    x = origin.x,
    y = origin.y,
    width = size.width,
    height = size.height,
    regions = regions,
    bar = {
      x = origin.x,
      y = origin.y + 2 * HUD_ROW_HEIGHT,
      width = HUD_BAR_WIDTH * fraction,
      height = HUD_BAR_HEIGHT,
      fraction = fraction,
    },
  }
end

-- Pure single-pane geometry for one semantic snapshot: dock allocations,
-- framed content boxes, hit cells, cursor and label origins, HUD anchors
-- and image centers. The controller owns no rectangles; draw and input
-- mapping consume these same regions.
---@param view table<string, unknown> internal semantic snapshot under resolution
---@return table<string, unknown> canonical compact plan content
function BattleCompactInterface.contentFor(view)
  local mode = view.mode
  local dock = NARRATION_OUTER
  if mode == "moves" or mode == "target" then
    dock = MOVE_DOCK
  elseif mode == "command" then
    dock = { x = 0, y = 136, width = 256, height = 56 }
  end
  local commandsContent = contentOf(COMMAND_OUTER)
  local cells = {}
  local cursors = {}
  for index, id in ipairs(COMMAND_IDS) do
    local column = (index - 1) % 2
    local row = math.floor((index - 1) / 2)
    local x = commandsContent.x + column * COMMAND_CELL_WIDTH
    local y = commandsContent.y + row * COMMAND_CELL_HEIGHT
    cells[#cells + 1] = { id = id, x = x, y = y, width = COMMAND_CELL_WIDTH, height = COMMAND_CELL_HEIGHT }
    cursors[#cursors + 1] = { x = x, y = y + 2 }
  end
  local moveLabels = {}
  for index = 1, 4 do
    local column = (index - 1) % 2
    local row = math.floor((index - 1) / 2)
    local cellX = MOVE_GRID_X + column * MOVE_COLUMN_WIDTH
    local cellY = MOVE_GRID_TOP + row * MOVE_ROW_HEIGHT
    moveLabels[#moveLabels + 1] = { x = cellX + 8, y = cellY + 6, width = MOVE_LABEL_WIDTH, height = 16 }
  end
  return {
    kind = "battle",
    layout = scopeFor(type(mode) == "string" and mode or "command"),
    compact = true,
    scene = { x = SCENE.x, y = SCENE.y, width = SCENE.width, height = SCENE.height },
    dock = { x = dock.x, y = dock.y, width = dock.width, height = dock.height },
    prompt = {
      outer = { x = PROMPT_OUTER.x, y = PROMPT_OUTER.y, width = PROMPT_OUTER.width, height = PROMPT_OUTER.height },
      content = contentOf(PROMPT_OUTER),
    },
    promptOrigin = { x = PROMPT_ORIGIN.x, y = PROMPT_ORIGIN.y },
    commands = {
      outer = { x = COMMAND_OUTER.x, y = COMMAND_OUTER.y, width = COMMAND_OUTER.width, height = COMMAND_OUTER.height },
      content = commandsContent,
      cells = cells,
      cursors = cursors,
    },
    movePanels = { left = contentOf(MOVE_LEFT_OUTER), right = contentOf(MOVE_RIGHT_OUTER) },
    moveGrid = { x = MOVE_GRID_X, columnWidth = MOVE_COLUMN_WIDTH, rowHeight = MOVE_ROW_HEIGHT },
    moveBack = {
      rect = {
        x = MOVE_BACK_RECT.x,
        y = MOVE_BACK_RECT.y,
        width = MOVE_BACK_RECT.width,
        height = MOVE_BACK_RECT.height,
      },
      label = { x = MOVE_BACK_LABEL.x, y = MOVE_BACK_LABEL.y },
    },
    moveInfo = moveInfo(view),
    moveLabels = moveLabels,
    targetBox = contentOf(TARGET_OUTER),
    targetRows = targetRows(view),
    narration = {
      content = contentOf(NARRATION_OUTER),
      origin = { x = NARRATION_ORIGIN.x, y = NARRATION_ORIGIN.y },
      width = NARRATION_WIDTH,
    },
    hud = (function()
      local player, enemy = splitBattlers(view)
      local foe = hudBox(enemy, "FOE", { x = HUD_ENEMY.x, y = HUD_ENEMY.y }, HUD_ENEMY_BOX, false)
      local ally = hudBox(
        player,
        "LEAD",
        { x = HUD_PLAYER_RIGHT - HUD_PLAYER_BOX.width, y = HUD_PLAYER_BOTTOM - HUD_PLAYER_BOX.height },
        HUD_PLAYER_BOX,
        true
      )
      ally.rightEdge = HUD_PLAYER_RIGHT
      ally.bottomEdge = HUD_PLAYER_BOTTOM
      return { enemy = foe, player = ally }
    end)(),
    playerCenter = { x = PLAYER_CENTER.x, y = PLAYER_CENTER.y },
    enemyCenter = { x = ENEMY_CENTER.x, y = ENEMY_CENTER.y },
  }
end

---@param regions table<integer, table<string, unknown>> half-open logical hit regions
---@param x number logical horizontal position under test
---@param y number logical vertical position under test
---@return table<string, unknown>? hit region, nil outside every region
local function hitRegion(regions, x, y)
  for _, region in ipairs(regions) do
    if x >= region.x and x < region.x + region.width and y >= region.y and y < region.y + region.height then
      return region
    end
  end
  return nil
end

---@param content table<string, unknown> canonical compact plan content
---@param mode string controller mode under mapping
---@return table<integer, table<string, unknown>>? active hit regions with their scopes
local function regionsFor(content, mode)
  if mode == "command" then
    local regions = {}
    for _, cell in ipairs(content.commands.cells) do
      regions[#regions + 1] =
        { id = cell.id, x = cell.x, y = cell.y, width = cell.width, height = cell.height, scope = "command" }
    end
    return regions
  elseif mode == "moves" then
    local regions = {}
    for slot = 0, 3 do
      local column = slot % 2
      local row = math.floor(slot / 2)
      regions[#regions + 1] = {
        id = "move:" .. tostring(slot),
        x = MOVE_GRID_X + column * MOVE_COLUMN_WIDTH,
        y = MOVE_GRID_TOP + row * MOVE_ROW_HEIGHT,
        width = MOVE_COLUMN_WIDTH,
        height = MOVE_ROW_HEIGHT,
        scope = "moves",
      }
    end
    regions[#regions + 1] = {
      id = "cancel",
      x = MOVE_BACK_RECT.x,
      y = MOVE_BACK_RECT.y,
      width = MOVE_BACK_RECT.width,
      height = MOVE_BACK_RECT.height,
      scope = "moves",
    }
    return regions
  elseif mode == "target" then
    local regions = {}
    for _, row in ipairs(content.targetRows) do
      regions[#regions + 1] =
        { id = row.id, x = row.x, y = row.y, width = row.width, height = row.height, scope = "target" }
    end
    return regions
  end
  return nil
end

-- Maps session-inverted logical input to the shared semantic battle
-- input: presses arm, slides track, releases confirm through the same
-- press convention as the paired panes. Regions outside every control
-- map to nothing; semantic keys pass through to the shared controller.
---@param event table<string, unknown> session-inverted logical input
---@param view table<string, unknown> internal semantic snapshot carrying the mode scope
---@param plan table<string, unknown> resolved plan carrying the canonical content
---@return table<string, unknown>? semantic battle input, nil when the battle ignores it
function BattleCompactInterface.mapInput(event, view, plan)
  local content = plan.content
  if type(content) ~= "table" or content.compact ~= true then
    return nil
  end
  local eventType = event.type
  if eventType == "pointer_down" and event.outside == true then
    return nil
  end
  local regions = regionsFor(content, view.mode)
  if regions == nil then
    if eventType == "pointer_cancel" then
      return { type = "pointer_cancel", pointerId = event.pointerId }
    end
    return nil
  end
  if eventType == "pointer_down" and type(event.x) == "number" and type(event.y) == "number" then
    local region = hitRegion(regions, event.x, event.y)
    if region == nil then
      return nil
    end
    return { type = "battle_press", control = { scope = region.scope, id = region.id }, pointerId = event.pointerId }
  end
  if eventType == "pointer_move" and type(event.x) == "number" and type(event.y) == "number" then
    local region = hitRegion(regions, event.x, event.y)
    local control = nil
    if region ~= nil then
      control = { scope = region.scope, id = region.id }
    end
    return { type = "battle_slide", control = control, pointerId = event.pointerId }
  end
  if eventType == "pointer_up" and type(event.x) == "number" and type(event.y) == "number" then
    local region = hitRegion(regions, event.x, event.y)
    -- Move and target slots focus on the first tap and submit on a
    -- release over the already-focused slot through the shared confirm
    -- semantic; the command grid keeps the press convention because the
    -- controller acts on command releases directly.
    if region ~= nil and (view.mode == "moves" or view.mode == "target") and view.selection == region.id then
      return { type = "confirm" }
    end
    local control = nil
    if region ~= nil then
      control = { scope = region.scope, id = region.id }
    end
    return { type = "battle_activate", control = control, pointerId = event.pointerId }
  end
  if eventType == "pointer_cancel" then
    return { type = "pointer_cancel", pointerId = event.pointerId }
  end
  if eventType == "confirm" or eventType == "cancel" then
    return { type = eventType }
  end
  if eventType == "navigate" then
    return { type = "navigate", direction = event.direction, pointerId = event.pointerId }
  end
  return nil
end

---@param resources table<string, unknown> borrowed application collaborators
---@return number[] shared window background behind dock fills and text
local function backgroundOf(resources)
  local windows = resources.windows
  if type(windows) == "table" and type(windows.background) == "table" then
    return windows.background --[[@as table]]
  end
  local text = resources.text
  if type(text) == "table" and type(text.windowBackgroundColor) == "function" then
    local ok, color = pcall(text.windowBackgroundColor, text)
    if ok and type(color) == "table" then
      return color --[[@as table]]
    end
  end
  return { 0, 0, 0, 1 }
end

---@param text table<string, unknown> borrowed text services
---@param content string label wording under fitting
---@param maxWidth number region width under fitting
---@return string label fitting its region through the live service when available
local function fitText(text, content, maxWidth)
  local label = tostring(content)
  if type(text.measure) ~= "function" or maxWidth <= 0 then
    return label
  end
  local glyphs = {}
  for char in Utf8Glyphs.iter(label) do
    glyphs[#glyphs + 1] = char
  end
  local ok, measured = pcall(text.measure, label)
  if not ok or type(measured) ~= "table" or type(measured.width) ~= "number" then
    return label
  end
  while #glyphs > 1 do
    local probe = table.concat(glyphs)
    local probeOk, probeMeasured = pcall(text.measure, probe)
    if probeOk and type(probeMeasured) == "table" and type(probeMeasured.width) == "number" then
      if probeMeasured.width <= maxWidth then
        return probe
      end
    else
      return probe
    end
    glyphs[#glyphs] = nil
  end
  return table.concat(glyphs)
end

---@param text table<string, unknown> borrowed text services
---@param content string label wording under drawing
---@param x number logical horizontal origin under drawing
---@param y number logical vertical origin under drawing
local function drawLabel(text, content, x, y)
  -- The adapted choice treatment draws through the dialogue copy triple
  -- when the service carries the field font definition; recording and
  -- battle doubles without a font definition take the plain entry.
  if type(text.drawTextWithPalette) == "function" and type(text.fontDef) == "table" then
    local palette = text.fontDef.palette
    if type(palette) == "table" and palette[2] ~= nil and palette[3] ~= nil and palette[16] ~= nil then
      local function channel(color)
        local r = assert(tonumber(color.r or color[1]))
        local g = assert(tonumber(color.g or color[2]))
        local b = assert(tonumber(color.b or color[3]))
        if r > 1 or g > 1 or b > 1 then
          r, g, b = r / 255, g / 255, b / 255
        end
        return { r = r * 255, g = g * 255, b = b * 255 }
      end
      text.drawTextWithPalette(content, x, y, {
        foreground = channel(palette[2]),
        shadow = channel(palette[3]),
        background = channel(palette[16]),
      })
      return
    end
  end
  text.drawText(content, x, y)
end

---@param text table<string, unknown> borrowed text services
---@param message string prompt wording under wrapping
---@param maxWidth number line width under wrapping
---@param maxLines integer line count under wrapping
---@return string[] wrapped lines fitting the prompt panel
local function wrapPrompt(text, message, maxWidth, maxLines)
  local lines = {}
  local words = {}
  for word in tostring(message):gmatch("%S+") do
    words[#words + 1] = word
  end
  if #words == 0 then
    return lines
  end
  local current = ""
  local function widthOf(candidate)
    if type(text.measure) ~= "function" then
      return #candidate * 8
    end
    local ok, measured = pcall(text.measure, candidate)
    if ok and type(measured) == "table" and type(measured.width) == "number" then
      return measured.width
    end
    return #candidate * 8
  end
  for _, word in ipairs(words) do
    local candidate = current == "" and word or (current .. " " .. word)
    if widthOf(candidate) <= maxWidth or current == "" then
      current = candidate
    else
      lines[#lines + 1] = current
      if #lines >= maxLines then
        return lines
      end
      current = word
    end
  end
  if current ~= "" and #lines < maxLines then
    lines[#lines + 1] = current
  end
  return lines
end

---@param view table<string, unknown> internal semantic snapshot under drawing
---@param id string command identity under drawing
---@return string label wording for one command
local function commandLabel(view, id)
  if type(view.commands) == "table" then
    for _, command in ipairs(view.commands) do
      if type(command) == "table" and command.id == id then
        if type(command.label) == "string" and command.label ~= "" then
          return command.label
        end
        if type(command.name) == "string" and command.name ~= "" then
          return command.name
        end
      end
    end
  end
  return COMMAND_LABELS[id] or id
end

---@param graphics table<string, unknown> injected host graphics
---@param background number[] shared window background under filling
---@param box table<string, unknown> half-open rect under filling
local function fillBox(graphics, background, box)
  graphics.setColor(background[1], background[2], background[3], background[4] or 1)
  graphics.rectangle("fill", box.x, box.y, box.width, box.height)
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param content table<string, unknown> canonical compact plan content under drawing
local function drawCommandDock(resources, view, content)
  local text = assert(resources.text, "the compact render borrows its text services")
  local windows = assert(resources.windows, "the compact render borrows its window services")
  local background = backgroundOf(resources)
  local frame = resources.frameKey
  fillBox(resources.graphics, background, content.prompt.outer)
  fillBox(resources.graphics, background, content.commands.outer)
  local promptLines = wrapPrompt(text, view.message or "", PROMPT_MAX_WIDTH, 2)
  for index, line in ipairs(promptLines) do
    drawLabel(text, line, PROMPT_ORIGIN.x, PROMPT_ORIGIN.y + (index - 1) * 16)
  end
  for index, id in ipairs(COMMAND_IDS) do
    local column = (index - 1) % 2
    local row = math.floor((index - 1) / 2)
    local label = commandLabel(view, id)
    if view.selection == id then
      label = CURSOR .. " " .. label
    end
    drawLabel(
      text,
      label,
      COMMAND_OUTER.x + 16 + column * COMMAND_CELL_WIDTH,
      COMMAND_OUTER.y + 10 + row * COMMAND_CELL_HEIGHT
    )
  end
  windows.drawApplicationFrame(content.prompt.content, frame)
  windows.drawApplicationFrame(content.commands.content, frame)
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param content table<string, unknown> canonical compact plan content under drawing
local function drawMoveDock(resources, view, content)
  local text = assert(resources.text, "the compact render borrows its text services")
  local windows = assert(resources.windows, "the compact render borrows its window services")
  local background = backgroundOf(resources)
  local frame = resources.frameKey
  fillBox(resources.graphics, background, MOVE_LEFT_OUTER)
  fillBox(resources.graphics, background, MOVE_RIGHT_OUTER)
  local movesBySlot = {}
  if type(view.moves) == "table" then
    for _, move in ipairs(view.moves) do
      if type(move) == "table" and type(move.slot) == "number" then
        movesBySlot[move.slot] = move
      end
    end
  end
  for slot = 0, 3 do
    local column = slot % 2
    local row = math.floor(slot / 2)
    local entry = movesBySlot[slot]
    if entry ~= nil and type(entry.name) == "string" and entry.name ~= "" then
      local label = fitText(text, entry.name, MOVE_LABEL_WIDTH)
      if view.selection == "move:" .. tostring(slot) then
        label = fitText(text, CURSOR .. " " .. entry.name, MOVE_LABEL_WIDTH)
      end
      drawLabel(text, label, MOVE_GRID_X + 8 + column * MOVE_COLUMN_WIDTH, MOVE_GRID_TOP + 6 + row * MOVE_ROW_HEIGHT)
    end
  end
  local info = content.moveInfo
  drawLabel(text, fitText(text, info.typeText, MOVE_INFO_MAX_WIDTH), MOVE_INFO_TEXT_X, info.typeRowY)
  drawLabel(text, fitText(text, info.ppText, MOVE_INFO_MAX_WIDTH), MOVE_INFO_TEXT_X, info.ppRowY)
  drawLabel(text, "BACK", MOVE_BACK_LABEL.x, MOVE_BACK_LABEL.y)
  windows.drawApplicationFrame(content.movePanels.left, frame)
  windows.drawApplicationFrame(content.movePanels.right, frame)
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param content table<string, unknown> canonical compact plan content under drawing
local function drawTargetDock(resources, view, content)
  local text = assert(resources.text, "the compact render borrows its text services")
  local windows = assert(resources.windows, "the compact render borrows its window services")
  local background = backgroundOf(resources)
  fillBox(resources.graphics, background, TARGET_OUTER)
  for _, row in ipairs(content.targetRows) do
    local label = "BACK"
    if row.id ~= "cancel" then
      label = tostring(row.name or row.id)
      if type(row.level) == "number" then
        label = label .. " Lv" .. tostring(row.level)
      end
    end
    if view.selection == row.id then
      label = CURSOR .. " " .. label
    end
    drawLabel(text, fitText(text, label, row.width - 8), row.x + 8, row.y)
  end
  windows.drawApplicationFrame(content.targetBox, resources.frameKey)
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param content table<string, unknown> canonical compact plan content under drawing
local function drawNarrationDock(resources, view, content)
  local text = assert(resources.text, "the compact render borrows its text services")
  local windows = assert(resources.windows, "the compact render borrows its window services")
  local background = backgroundOf(resources)
  fillBox(resources.graphics, background, NARRATION_OUTER)
  local lines = wrapPrompt(text, view.message or "", NARRATION_WIDTH, 2)
  for index, line in ipairs(lines) do
    drawLabel(text, line, NARRATION_ORIGIN.x, NARRATION_ORIGIN.y + (index - 1) * 16)
  end
  if view.mode == "narration" then
    drawLabel(text, CONTINUE_MARK, CONTINUE_ORIGIN.x, CONTINUE_ORIGIN.y)
  end
  windows.drawApplicationFrame(content.narration.content, resources.frameKey)
end

-- Draws one side HUD inside the scene clip: the selected source artwork
-- composite unscaled at the plan bounds with the health bar beside the
-- numeric health region. Missing artwork draws nothing, never a
-- substitute, and the bar always draws so actual health stays visible.
-- Glyph regions resolve through the plan content; this path issues only
-- graphics-service draws, never text-service draws.
---@param graphics table<string, unknown> injected host graphics
---@param assets table<string, unknown> injected asset holder
---@param artKey string artwork identity under drawing
---@param battler table<string, unknown>? combatant facts under drawing
---@param side table<string, unknown>? anchored HUD box content under drawing
local function drawHudSide(graphics, assets, artKey, battler, side)
  if type(side) ~= "table" then
    return
  end
  if battler == nil or battler.visible == false then
    return
  end
  local art = assets:drawable(artKey)
  if art ~= nil then
    graphics.draw(art, side.x, side.y)
  end
  local bar = side.bar
  if type(bar) == "table" then
    local fraction = 0
    if type(bar.fraction) == "number" then
      fraction = bar.fraction --[[@as number]]
    end
    local r, g, b, a = graphics.getColor()
    if fraction > 0.5 then
      graphics.setColor(0.2, 0.8, 0.2, 1)
    elseif fraction > 0.2 then
      graphics.setColor(0.9, 0.8, 0.2, 1)
    else
      graphics.setColor(0.9, 0.2, 0.2, 1)
    end
    graphics.rectangle("fill", bar.x, bar.y, bar.width, bar.height)
    graphics.setColor(r, g, b, a)
  end
end

-- Draws both combatant HUDs at the plan bounds clipped to the scene
-- viewport. Hidden battlers draw neither artwork nor bar; the selection
-- arrow and party gauges stay hidden because the text cursor and the
-- Party action carry the corresponding interaction.
---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param content table<string, unknown> canonical compact plan content under drawing
local function drawCompactHud(resources, view, content)
  local graphics = assert(resources.graphics, "the compact render borrows its host graphics")
  local assets = assert(resources.assets, "the compact render borrows its asset holder")
  local hud = content.hud
  if type(hud) ~= "table" then
    return
  end
  local viewport = content.scene
  if type(viewport) ~= "table" then
    viewport = { x = 0, y = 0, width = 256, height = 136 }
  end
  local player, enemy = splitBattlers(view)
  LogicalSurface.clip(graphics, viewport, function()
    drawHudSide(graphics, assets, "hud:enemy", enemy, hud.enemy --[[@as table<string, unknown>?]])
    drawHudSide(graphics, assets, "hud:player", player, hud.player --[[@as table<string, unknown>?]])
  end)
end

-- Draws the resolved compact plan inside its placement: the source scene
-- and battler images clipped to the scene viewport through the shared
-- battle renderer, the combatant HUDs at the plan bounds, then the mode
-- dock with background fills, text and the shared application borders.
-- Read-only like every plan render.
---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param plan table<string, unknown> resolved plan carrying the canonical content
function BattleCompactInterface.render(resources, view, plan)
  local graphics = assert(resources.graphics, "the compact render borrows its host graphics")
  local content = assert(plan.content, "the compact plan carries its content")
  local pane = assert(plan.panes[1], "the compact plan carries its one pane")
  local placement = assert(pane.placement, "the compact pane carries its placement")
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  LogicalSurface.draw(graphics, placement, function()
    BattleRenderer.drawPane(resources, view, BattleCompactInterface.NATIVE.id, content)
    drawCompactHud(resources, view, content)
    local mode = view.mode
    if mode == "command" then
      drawCommandDock(resources, view, content)
    elseif mode == "moves" then
      drawMoveDock(resources, view, content)
    elseif mode == "target" then
      drawTargetDock(resources, view, content)
    else
      drawNarrationDock(resources, view, content)
    end
  end)
end

---@param mode string controller mode under resolution
---@param requestId integer? open request identity under resolution
---@param selection string? highlighted semantic identity under resolution
---@param signature string? measurement signature under resolution
---@return string stable input-geometry identity for the semantic state
local function inputKey(mode, requestId, selection, signature)
  return table.concat(
    { INPUT_KEY, mode, tostring(selection), tostring(requestId or 0), tostring(signature or "-") },
    ":"
  )
end

---@return nil
local function noopRender(_, _, _) end

---@return nil
local function noopMap(_, _, _)
  return nil
end

---@return table<string, unknown> valid inactive plan: no panes, no targets, cancellation still deliverable
local function inactivePlan()
  return {
    panes = {},
    frames = {},
    content = { kind = "battle" },
    inputKey = INPUT_KEY .. "-inactive",
    render = noopRender,
    mapInput = noopMap,
  }
end

---@param placement table<string, unknown> resolved compact placement
---@param frames table[] resolved outer frames
---@param view table<string, unknown> internal semantic snapshot under resolution
---@param signature string? measurement signature under resolution
---@return table<string, unknown> complete compact plan
local function compactPlan(placement, frames, view, signature)
  return {
    panes = { { id = BattleCompactInterface.NATIVE.id, placement = placement, interactive = true } },
    frames = frames,
    content = BattleCompactInterface.contentFor(view),
    inputKey = inputKey(
      type(view.mode) == "string" and view.mode or "command",
      view.requestId --[[@as integer?]],
      type(view.selection) == "string" and view.selection or nil,
      signature
    ),
    render = BattleCompactInterface.render,
    mapInput = BattleCompactInterface.mapInput,
  }
end

---@param pixelRatio number context pixel ratio under placement
---@return table<string, unknown> integer single-pane placement at the logical origin
local function integerPlacement(pixelRatio)
  return {
    frame = { x = 0, y = 0, width = BattleCompactInterface.NATIVE.width, height = BattleCompactInterface.NATIVE.height },
    origin = { x = 0, y = 0 },
    scale = 1,
    logicalWidth = BattleCompactInterface.NATIVE.width,
    logicalHeight = BattleCompactInterface.NATIVE.height,
    clipRect = {
      x = 0,
      y = 0,
      width = BattleCompactInterface.NATIVE.width,
      height = BattleCompactInterface.NATIVE.height,
    },
    pixelScale = 1,
    pixelRatio = pixelRatio,
    visibleLogicalRect = {
      x = 0,
      y = 0,
      width = BattleCompactInterface.NATIVE.width,
      height = BattleCompactInterface.NATIVE.height,
    },
    crop = { left = 0, right = 0, top = 0, bottom = 0 },
  }
end

-- Single-surface compact resolution: one fitted 256x192 pane through the
-- shared cover-or-frame helper, with the whole-canvas fractional downfit
-- below the one-times fit floor.
---@param context table<string, unknown> layout context carrying the measurement
---@param view table<string, unknown> internal semantic snapshot under resolution
---@return table<string, unknown> complete compact plan
function BattleCompactInterface.nativeLike(context, view)
  local ApplicationLayoutRef = ApplicationLayout
  local geometry =
    ApplicationLayoutRef.coverOrFrame(context --[[@as ApplicationLayout.Context]], BattleCompactInterface.NATIVE, {
      maxOverdraw = ZERO_CROP,
    })
  local placement = geometry.placements[BattleCompactInterface.NATIVE.id]
  if placement == nil then
    return inactivePlan()
  end
  local measurement = context.measurement --[[@as table<string, unknown>]]
  return compactPlan(placement, geometry.frames or {}, view, measurement.signature --[[@as string?]])
end

-- Pair-too-small compact fallback: when a paired composition cannot fit,
-- the same compact pane resolves instead of a clipped battle. Below the
-- one-times fit floor the pane keeps integer mapping at the logical
-- origin so every control stays addressable through one transform.
---@param context table<string, unknown> layout context carrying the measurement
---@param view table<string, unknown> internal semantic snapshot under resolution
---@return table<string, unknown> complete compact plan
function BattleCompactInterface.fallback(context, view)
  local ApplicationLayoutRef = ApplicationLayout
  local geometry =
    ApplicationLayoutRef.coverOrFrame(context --[[@as ApplicationLayout.Context]], BattleCompactInterface.NATIVE, {
      maxOverdraw = ZERO_CROP,
    })
  local measurement = context.measurement --[[@as table<string, unknown>]]
  local placement = geometry.placements[BattleCompactInterface.NATIVE.id]
  local ratio = measurement.pixelRatio
  if type(ratio) ~= "number" or ratio <= 0 then
    ratio = 1
  end
  if placement == nil or (placement.pixelScale ~= nil and placement.pixelScale < 1) then
    return compactPlan(integerPlacement(ratio --[[@as number]]), {}, view, measurement.signature --[[@as string?]])
  end
  return compactPlan(placement, geometry.frames or {}, view, measurement.signature --[[@as string?]])
end

return BattleCompactInterface
