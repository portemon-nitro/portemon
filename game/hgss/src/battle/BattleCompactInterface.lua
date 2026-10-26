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
local BattleChildText = require("game.hgss.src.battle.BattleChildText")
local BattleMenuPresenter = require("game.hgss.src.battle.BattleMenuPresenter")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local BattleViewRoster = require("game.hgss.src.battle.BattleViewRoster")
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
local HUD_PLAYER_TOP = 4
-- Fixed single-pane HUD boxes: the enemy bounds sit at the left/top
-- anchor, the player bounds sit at the upper-right. Rows follow the paired
-- name/level pitch with the paired 48-pixel health bar; the player box adds
-- an experience row.
local HUD_ENEMY_BOX = { width = 96, height = 36 }
local HUD_PLAYER_BOX = { width = 104, height = 36 }
local HUD_BAR_WIDTH = 48
local HUD_BAR_HEIGHT = 4
local HUD_ROW_HEIGHT = 12
local DOUBLES_HUD_CELLS = {
  enemy = { { x = 4, y = 0 }, { x = 132, y = 0 } },
  player = { { x = 4, y = 80 }, { x = 132, y = 80 } },
}
local DOUBLES_PICTURE_CELLS = {
  enemy = { { x = 24, y = 40 }, { x = 152, y = 40 } },
  player = { { x = 72, y = 40 }, { x = 200, y = 40 } },
}
local DOUBLES_HUD_WIDTH = 120
local DOUBLES_HUD_HEIGHT = 40
local DOUBLES_BAR_X = 4
local DOUBLES_BAR_Y = 35
local DOUBLES_BAR_WIDTH = 48
local DOUBLES_NAME_WIDTH = 76
local DOUBLES_LEVEL_WIDTH = 32
local DOUBLES_CONDITION_WIDTH = 44
local DOUBLES_HEALTH_WIDTH = 59
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

---@param rows table<integer, table<string, unknown>> target rows under layout
---@return table<integer, table<string, unknown>> positioned target rows with a Back row beneath
local function dockRows(rows)
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

---@param view table<string, unknown> internal semantic snapshot under resolution
---@return table<integer, table<string, unknown>> admitted target rows with a Back row beneath
local function targetRows(view)
  local candidates = view.targetCandidates --[[@as table<integer, table<string, unknown>>?]]
  if type(candidates) == "table" then
    -- Projected candidate order owns the rows: the kernel's admitted foe
    -- positions map to hit regions in exactly this order.
    local rows = {}
    for _, candidate in ipairs(candidates) do
      if type(candidate) == "table" and candidate.enabled == true and type(candidate.id) == "string" and #rows < 2 then
        rows[#rows + 1] = {
          id = candidate.id,
          name = candidate.name,
          level = candidate.level,
        }
      end
    end
    return dockRows(rows)
  end
  -- Without admitted candidates the dock offers only Back: rows never
  -- infer targets from the party layout.
  return dockRows({})
end

---@param mode string controller mode under resolution
---@param view table<string, unknown>? active screen view under resolution
---@return string layout scope behind the current mode
local function scopeFor(mode, view)
  if mode == "moves" then
    return "moves"
  elseif mode == "target" then
    return "target"
  elseif mode == "narration" then
    return "narration"
  elseif mode == "child" and type(view) == "table" and type(view.childView) == "table" then
    local child = view.childView --[[@as table<string, unknown>]]
    if child.kind == "learn" and type(child.confirmation) == "table" then
      return "two-option"
    end
  end
  return "command"
end

-- Layout family follows occupied native slots, never transient
-- visibility: a double battle keeps its four cells while a neighbor
-- hides mid-transition. Single battles never reach doubles occupancy,
-- so their legacy geometry stays untouched.
---@param view table<string, unknown> internal semantic snapshot under resolution
---@param players table<integer, table<string, unknown>> live allies in slot order
---@param enemies table<integer, table<string, unknown>> live foes in slot order
---@return boolean true while the battle occupies doubles slots
local function doublesFormat(view, players, enemies)
  if #BattleViewRoster.claimedPositions(view, true) >= 2 or #BattleViewRoster.claimedPositions(view, false) >= 2 then
    return true
  end
  if #players == 2 and #enemies == 2 then
    for _, battler in ipairs({ players[1], players[2], enemies[1], enemies[2] }) do
      if type(battler.position) ~= "number" then
        return false
      end
    end
    return true
  end
  return false
end

-- Adapted compact doubles geometry: a modern one-screen arrangement
-- inside the 256x136 scene, explicitly NOT a copy of DS positions.
-- Foe boxes share the top row, ally boxes the bottom row above the
-- dock; every box stays inside the scene and pairwise disjoint while
-- the lower dock keeps its full interactive bounds. Sprite anchors sit
-- in the free middle band in deterministic slot order.

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

---@param battler table<string, unknown>? combatant facts under resolution
---@return string gender mark wording, empty without a binary gender fact
local function hudGender(battler)
  if battler ~= nil and battler.gender == "male" then
    return "\226\153\130"
  elseif battler ~= nil and battler.gender == "female" then
    return "\226\153\128"
  end
  return ""
end

---@param battler table<string, unknown>? combatant facts under resolution
---@return string caught mark wording, empty without the caught fact
local function hudCaught(battler)
  if battler ~= nil and battler.caught == true then
    return "\226\151\143"
  end
  return ""
end

-- One side HUD box with its dynamic regions and health bar: the bounds
-- anchor the complete box while every region carries the resolved
-- snapshot wording for the draw clip. The name row reserves two mark
-- cells for the gender and caught facts; the player box keeps an
-- experience row that carries no numeric wording because experience is
-- bar work, never printed totals.
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
  local levelWidth = size.width
  local markWidth = 14
  local rowHeight = withExp and 7 or HUD_ROW_HEIGHT
  local regions = {
    {
      id = "name",
      x = origin.x,
      y = origin.y,
      width = size.width - 2 * markWidth,
      height = rowHeight,
      text = hudName(battler, fallback),
    },
    {
      id = "gender",
      x = origin.x + size.width - 2 * markWidth,
      y = origin.y,
      width = markWidth,
      height = rowHeight,
      text = hudGender(battler),
    },
    {
      id = "caught",
      x = origin.x + size.width - markWidth,
      y = origin.y,
      width = markWidth,
      height = rowHeight,
      text = hudCaught(battler),
    },
    {
      id = "level",
      x = origin.x,
      y = origin.y + rowHeight,
      width = levelWidth,
      height = rowHeight,
      text = hudLevel(battler),
    },
    {
      id = "condition",
      x = origin.x + levelWidth,
      y = origin.y + rowHeight,
      width = size.width - levelWidth,
      height = rowHeight,
      text = hudCondition(battler),
    },
  }
  regions[#regions + 1] = {
    id = "hp",
    x = origin.x + HUD_BAR_WIDTH + 4,
    y = origin.y + 2 * rowHeight,
    width = size.width - HUD_BAR_WIDTH - 4,
    height = rowHeight,
    text = withExp and hudHealth(battler) or "",
  }
  if withExp then
    regions[#regions + 1] = {
      id = "exp",
      x = origin.x,
      y = origin.y + 3 * rowHeight,
      width = size.width,
      height = rowHeight,
      text = "",
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
      y = origin.y + 2 * rowHeight,
      width = HUD_BAR_WIDTH * fraction,
      height = HUD_BAR_HEIGHT,
      fraction = fraction,
    },
  }
end

---@param battler table<string, unknown>? current owner of one compact doubles slot
---@param fallback string fallback wording when the slot is temporarily ownerless
---@param origin table<string, number> authored panel origin
---@param position integer opaque source slot identity
---@param side integer side identity for an ownerless transition slot
---@return table<string, unknown> compact doubles panel geometry and its own semantic fields
local function compactDoublesHudBox(battler, fallback, origin, position, side)
  local hp = battler ~= nil and battler.hp or 0
  local maxHp = battler ~= nil and battler.maxHp or 0
  local fraction = hudFraction(hp, maxHp)
  return {
    x = origin.x,
    y = origin.y,
    width = DOUBLES_HUD_WIDTH,
    height = DOUBLES_HUD_HEIGHT,
    position = position,
    side = battler ~= nil and battler.side or side,
    regions = {
      {
        id = "name",
        x = origin.x + 4,
        y = origin.y + 1,
        width = DOUBLES_NAME_WIDTH,
        height = 16,
        text = hudName(battler, fallback),
      },
      {
        id = "level",
        x = origin.x + 84,
        y = origin.y + 1,
        width = DOUBLES_LEVEL_WIDTH,
        height = 16,
        text = hudLevel(battler),
      },
      {
        id = "condition",
        x = origin.x + 4,
        y = origin.y + 17,
        width = DOUBLES_CONDITION_WIDTH,
        height = 16,
        text = hudCondition(battler),
      },
      {
        id = "hp",
        x = origin.x + 57,
        y = origin.y + 17,
        width = DOUBLES_HEALTH_WIDTH,
        height = 16,
        text = battler ~= nil and battler.side == 2 and "" or hudHealth(battler),
      },
    },
    bar = {
      x = origin.x + DOUBLES_BAR_X,
      y = origin.y + DOUBLES_BAR_Y,
      width = DOUBLES_BAR_WIDTH * fraction,
      height = HUD_BAR_HEIGHT,
      fraction = fraction,
    },
  }
end

-- Canonical child plan content with the same row numbers the modal
-- paint uses: six rows, a footer Back, and bag pocket stepping. Draw
-- and input mapping consume these same rects.
---@param child table<string, unknown> detached child view under resolution
---@return table<string, unknown> canonical child plan content
local function childContent(child)
  local twoOption = child.kind == "learn" and type(child.confirmation) == "table"
  local rows = {}
  local source = child.rows --[[@as table<integer, table<string, unknown>>?]]
  if not twoOption and type(source) == "table" then
    for index, row in ipairs(source) do
      if index <= 6 then
        local box = row --[[@as table<string, unknown>]]
        rows[#rows + 1] = {
          id = box.id,
          x = 8,
          y = 32 + (index - 1) * 20,
          width = 240,
          height = 20,
          label = box.label,
          sub = box.sub,
          detail = box.detail,
          enabled = box.enabled,
          empty = box.empty,
        }
      end
    end
  end
  local backRect = { x = 8, y = 152, width = 80, height = 40 }
  if child.kind == "learn" then
    backRect = { x = 8, y = 172, width = 240, height = 20 }
  end
  return {
    kind = child.kind,
    focusId = child.focusId,
    title = BattleChildText.title(child),
    rows = rows,
    hasBack = not twoOption and (child.cancellable == true or child.kind == "learn"),
    twoOption = twoOption,
    hasPocketNav = child.kind == "bag" and child.empty ~= true,
    back = backRect,
    pocketPrev = { x = 96, y = 152, width = 76, height = 40 },
    pocketNext = { x = 176, y = 152, width = 72, height = 40 },
  }
end

---@param players table<integer, table<string, unknown>> live allies in slot order
---@param enemies table<integer, table<string, unknown>> live foes in slot order
---@return table<integer, table<string, unknown>> live battlers keyed by their native position
local function livePositions(players, enemies)
  local live = {} ---@type table<integer, table<string, unknown>>
  for _, side in ipairs({ players, enemies }) do
    for _, battler in ipairs(side) do
      if type(battler.position) == "number" then
        live[
          battler.position --[[@as integer]]
        ] = battler
      end
    end
  end
  return live
end

---@param view table<string, unknown> internal semantic snapshot under resolution
---@param players table<integer, table<string, unknown>> live allies in slot order under resolution
---@param enemies table<integer, table<string, unknown>> live foes in slot order under resolution
---@return table<string, unknown> position-keyed HUD boxes in deterministic slot order
local function doublesHud(view, players, enemies)
  -- Cells follow the canonical claimed order, keyed by the opaque
  -- native position of each row. A hidden transition slot keeps its
  -- cell with no live owner: paint skips ownerless boxes while the
  -- survivors stay on their rows. Draw and hit regions consume these
  -- same bounds.
  local live = livePositions(players, enemies)
  -- Side identity behind an ownerless transition cell comes from the
  -- side's live records; every doubles view fields one, so the plan
  -- keeps the owner's side without guessing it.
  local function sideOf(list, playerSide)
    for _, battler in ipairs(list) do
      if type(battler.side) == "number" then
        return battler.side --[[@as integer]]
      end
    end
    if type(view.battlers) == "table" then
      for _, battler in ipairs(view.battlers) do
        if type(battler) == "table" and (battler.side == 1) == playerSide and type(battler.side) == "number" then
          return battler.side --[[@as integer]]
        end
      end
    end
    return playerSide and 1 or 2
  end
  local foeSide = sideOf(enemies, false)
  local allySide = sideOf(players, true)
  local boxes = {} ---@type table<integer, table<string, unknown>>
  local function add(order, cells, fallback, side)
    for index, position in ipairs(order) do
      local cell = cells[index]
      assert(cell ~= nil, "the compact doubles cells cover every claimed slot")
      local owner = live[position]
      boxes[#boxes + 1] = compactDoublesHudBox(owner, fallback, cell, position, side)
    end
  end
  add(BattleViewRoster.claimedPositions(view, false), DOUBLES_HUD_CELLS.enemy, "FOE", foeSide)
  add(BattleViewRoster.claimedPositions(view, true), DOUBLES_HUD_CELLS.player, "LEAD", allySide)
  table.sort(boxes, function(a, b)
    if a.y ~= b.y then
      return a.y < b.y
    end
    return a.x < b.x
  end)
  return { boxes = boxes }
end

---@param view table<string, unknown> internal semantic snapshot under resolution
---@param players table<integer, table<string, unknown>> live allies in slot order under resolution
---@param enemies table<integer, table<string, unknown>> live foes in slot order under resolution
---@return table<integer, table<string, unknown>> compact sprite anchors keyed by native position
local function doublesSpriteCenters(view, players, enemies)
  -- Anchors follow the canonical claimed order so a surviving slot
  -- never slides onto a hidden neighbor's anchor mid-transition.
  -- Records without a native position keep their live-order anchor.
  local spots = {} ---@type table<integer, table<string, unknown>>
  local function add(list, order, cells)
    for index, battler in ipairs(list) do
      local cell = cells[BattleViewRoster.claimedIndex(order, battler, index)]
      assert(cell ~= nil, "the compact doubles anchors cover every live battler")
      spots[#spots + 1] = {
        position = battler.position,
        x = cell.x,
        y = cell.y,
        width = 40,
        height = 40,
        scale = 0.5,
      }
    end
  end
  add(enemies, BattleViewRoster.claimedPositions(view, false), DOUBLES_PICTURE_CELLS.enemy)
  add(players, BattleViewRoster.claimedPositions(view, true), DOUBLES_PICTURE_CELLS.player)
  table.sort(spots, function(a, b)
    local pa = a.position
    local pb = b.position
    assert(type(pa) == "number" and type(pb) == "number", "doubles sprite anchors key on native positions")
    return pa < pb
  end)
  return spots
end

---@param rect table<string, unknown> fixed half-open rect
---@return table<string, unknown> caller-owned copy of the rect
local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

-- The legacy single-side HUD boxes: the foe box at the left/top anchor
-- and the player box at the upper-right with its experience row.
---@param view table<string, unknown> internal semantic snapshot under resolution
---@return table<string, unknown> side-keyed HUD boxes
local function singlesHud(view)
  local player, enemy = BattleViewRoster.firstPerSide(view)
  local foe = hudBox(enemy, "FOE", { x = HUD_ENEMY.x, y = HUD_ENEMY.y }, HUD_ENEMY_BOX, false)
  local ally =
    hudBox(player, "LEAD", { x = HUD_PLAYER_RIGHT - HUD_PLAYER_BOX.width, y = HUD_PLAYER_TOP }, HUD_PLAYER_BOX, true)
  ally.rightEdge = HUD_PLAYER_RIGHT
  ally.bottomEdge = HUD_PLAYER_TOP + HUD_PLAYER_BOX.height
  return { enemy = foe, player = ally }
end

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
  local childPlan = nil
  if mode == "child" and type(view.childView) == "table" then
    childPlan = childContent(view.childView --[[@as table<string, unknown>]])
  end
  -- Doubles take the position-keyed layout whenever some side claims
  -- doubles slots, even while a neighbor hides mid-transition; hidden
  -- slots keep their cells with no live owner. Every other occupancy
  -- keeps the legacy single-side geometry untouched.
  local players, enemies = BattleViewRoster.liveSides(view)
  local doubles = doublesFormat(view, players, enemies)
  return {
    kind = "battle",
    layout = scopeFor(type(mode) == "string" and mode or "command", view),
    compact = true,
    scene = copyRect(SCENE),
    dock = copyRect(dock),
    prompt = {
      outer = copyRect(PROMPT_OUTER),
      content = contentOf(PROMPT_OUTER),
    },
    promptOrigin = { x = PROMPT_ORIGIN.x, y = PROMPT_ORIGIN.y },
    commands = {
      outer = copyRect(COMMAND_OUTER),
      content = commandsContent,
      cells = cells,
      cursors = cursors,
    },
    movePanels = { left = contentOf(MOVE_LEFT_OUTER), right = contentOf(MOVE_RIGHT_OUTER) },
    moveGrid = { x = MOVE_GRID_X, columnWidth = MOVE_COLUMN_WIDTH, rowHeight = MOVE_ROW_HEIGHT },
    moveBack = {
      rect = copyRect(MOVE_BACK_RECT),
      label = { x = MOVE_BACK_LABEL.x, y = MOVE_BACK_LABEL.y },
    },
    moveInfo = moveInfo(view),
    moveLabels = moveLabels,
    child = childPlan,
    targetBox = contentOf(TARGET_OUTER),
    targetRows = targetRows(view),
    narration = {
      content = contentOf(NARRATION_OUTER),
      origin = { x = NARRATION_ORIGIN.x, y = NARRATION_ORIGIN.y },
      width = NARRATION_WIDTH,
    },
    hud = doubles and doublesHud(view, players, enemies) or singlesHud(view),
    playerCenter = { x = PLAYER_CENTER.x, y = PLAYER_CENTER.y },
    enemyCenter = { x = ENEMY_CENTER.x, y = ENEMY_CENTER.y },
    spriteCenters = doubles and doublesSpriteCenters(view, players, enemies) or nil,
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

-- Child hit regions from the same canonical rows the modal paints,
-- plus the footer Back and bag pocket stepping; a staged learning
-- confirmation maps its two source options.
---@param child table<string, unknown>? canonical child plan content under mapping
---@return table<integer, table<string, unknown>>? active hit regions with their scopes
local function childRegions(child)
  if type(child) ~= "table" then
    return nil
  end
  if child.twoOption == true then
    return {
      { id = "confirm", x = 0, y = 32, width = 256, height = 64, scope = "child" },
      { id = "back", x = 0, y = 104, width = 256, height = 64, scope = "child" },
    }
  end
  local regions = {}
  local function add(id, rect)
    regions[#regions + 1] =
      { id = id, x = rect.x, y = rect.y, width = rect.width, height = rect.height, scope = "child" }
  end
  local rows = child.rows --[[@as table<integer, table<string, unknown>>?]]
  if type(rows) == "table" then
    for _, row in ipairs(rows) do
      local box = row --[[@as table<string, unknown>]]
      if box.empty ~= true and type(box.id) == "string" then
        add(box.id, box)
      end
    end
  end
  if child.hasBack == true then
    add("back", child.back)
  end
  if child.hasPocketNav == true then
    add("pocket_prev", child.pocketPrev)
    add("pocket_next", child.pocketNext)
  end
  return regions
end

---@param content table<string, unknown> canonical compact plan content
---@param mode string controller mode under mapping
---@return table<integer, table<string, unknown>>? active hit regions with their scopes
local function regionsFor(content, mode)
  if mode == "child" then
    return childRegions(content.child --[[@as table<string, unknown>?]])
  end
  if mode == "narration" or mode == "outcome" then
    return { { id = "dialogue", x = 0, y = 0, width = 256, height = 192, scope = mode } }
  end
  local regions = {}
  local function add(id, rect)
    regions[#regions + 1] = { id = id, x = rect.x, y = rect.y, width = rect.width, height = rect.height, scope = mode }
  end
  if mode == "command" then
    for _, cell in ipairs(content.commands.cells) do
      add(cell.id, cell)
    end
    return regions
  elseif mode == "moves" then
    for slot = 0, 3 do
      add("move:" .. tostring(slot), {
        x = MOVE_GRID_X + slot % 2 * MOVE_COLUMN_WIDTH,
        y = MOVE_GRID_TOP + math.floor(slot / 2) * MOVE_ROW_HEIGHT,
        width = MOVE_COLUMN_WIDTH,
        height = MOVE_ROW_HEIGHT,
      })
    end
    add("cancel", MOVE_BACK_RECT)
    return regions
  elseif mode == "target" then
    for _, row in ipairs(content.targetRows) do
      add(row.id, row)
    end
    return regions
  end
  return nil
end

-- Semantic input types behind the pointer gestures: the open child
-- drives its bound child owner, every other mode the battle controller.
local CHILD_INPUT = {
  pointer_down = "child_press",
  pointer_move = "child_slide",
  pointer_up = "child_activate",
  pointer_cancel = "child_cancel",
}
local BATTLE_INPUT = {
  pointer_down = "battle_press",
  pointer_move = "battle_slide",
  pointer_up = "battle_activate",
  pointer_cancel = "pointer_cancel",
}

-- Maps session-inverted logical input to the shared semantic battle
-- input: presses arm, slides track, releases confirm through the same
-- press convention as the paired panes, each control carrying its hit
-- region's scope. Presses outside every control map to nothing; semantic
-- keys pass through to the shared controller. Narration and outcome
-- share one full-surface dialogue tap, so the screen acknowledges the
-- shown page on a matched gesture only.
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
  local kinds = view.mode == "child" and CHILD_INPUT or BATTLE_INPUT
  local regions = nil
  if view.mode == "child" then
    local child = content.child
    local childView = view.childView
    local native = type(childView) == "table" and childView.native or nil
    local nativeChild = type(child) == "table"
      and (child.kind == "bag" or child.kind == "party" or child.kind == "target")
      and type(native) == "table"
      and type(native.layout) == "table"
    if nativeChild then
      regions = { { id = "native", x = 0, y = 0, width = 256, height = 192, scope = "child" } }
    else
      regions = regionsFor(content, view.mode --[[@as string]])
    end
  else
    regions = regionsFor(content, view.mode --[[@as string]])
  end
  if eventType == "pointer_cancel" then
    return { type = kinds.pointer_cancel, pointerId = event.pointerId }
  end
  if regions == nil then
    return nil
  end
  local gesture = kinds[eventType]
  if gesture ~= nil and type(event.x) == "number" and type(event.y) == "number" then
    local region = hitRegion(regions, event.x, event.y)
    if region == nil and eventType == "pointer_down" then
      return nil
    end
    local control = region ~= nil and { scope = region.scope, id = region.id } or nil
    return { type = gesture, control = control, pointerId = event.pointerId }
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
  assert(type(windows) == "table", "compact battle presentation requires its window service")
  if type(windows.background) == "table" then
    return windows.background --[[@as table]]
  end
  local text = resources.text
  assert(
    type(text) == "table" and type(text.windowBackgroundColor) == "function",
    "compact battle windows publish their fill color"
  )
  local color = text.windowBackgroundColor(text)
  assert(type(color) == "table", "compact battle windows publish an RGBA fill color")
  return color --[[@as table]]
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
  -- Multi-actor turns name the acting battler first so staged choices
  -- are never mistaken for the previous entry's selection.
  local acting = BattleViewRoster.actingName(view)
  local promptLines = wrapPrompt(text, view.message or "", PROMPT_MAX_WIDTH, acting ~= nil and 1 or 2)
  local promptY = PROMPT_ORIGIN.y
  if acting ~= nil then
    drawLabel(text, fitText(text, acting, PROMPT_MAX_WIDTH), PROMPT_ORIGIN.x, promptY)
    promptY = promptY + 16
  end
  for index, line in ipairs(promptLines) do
    drawLabel(text, line, PROMPT_ORIGIN.x, promptY + (index - 1) * 16)
  end
  for index, id in ipairs(COMMAND_IDS) do
    local column = (index - 1) % 2
    local row = math.floor((index - 1) / 2)
    local label = commandLabel(view, id)
    if view.selection == id then
      label = CURSOR .. " " .. label
    end
    local x = COMMAND_OUTER.x + 16 + column * COMMAND_CELL_WIDTH
    local y = COMMAND_OUTER.y + 10 + row * COMMAND_CELL_HEIGHT
    if id == "fight" and type(view.commandIcon) == "table" then
      local iconFacts = view.commandIcon --[[@as table<string, unknown>]]
      local assets = assert(resources.assets, "the compact render borrows its icon assets")
      local icon =
        assets:drawable("battle:icon:" .. tostring(iconFacts.key) .. ":frame:" .. tostring(iconFacts.frameIndex or 1))
      if icon ~= nil then
        local draw = assert(icon.draw, "the party icon uses the shared palette-exact draw handle")
        LogicalSurface.clip(
          resources.graphics,
          { x = x, y = y, width = COMMAND_CELL_WIDTH, height = COMMAND_CELL_HEIGHT },
          function()
            draw(icon, resources.graphics, x + 2, y + 2, 0, 0.5, 0.5)
          end
        )
        x = x + 20
      end
    end
    drawLabel(text, label, x, y)
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
  local acting = BattleViewRoster.actingName(view)
  if acting ~= nil then
    drawLabel(text, fitText(text, acting, MOVE_LABEL_WIDTH), MOVE_GRID_X + 8, MOVE_GRID_TOP - 16)
  end
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
  local acting = BattleViewRoster.actingName(view)
  if acting ~= nil then
    drawLabel(text, fitText(text, acting, TARGET_ROW_WIDTH), TARGET_ROW_X + 8, TARGET_FIRST_Y - 18)
  end
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
-- sampled through quads at the plan bounds, the resolved name, level,
-- condition and health wording through the borrowed text services at the
-- plan region origins, and the health bar as native tile work beside the
-- numeric health region. Missing artwork draws nothing, never a
-- substitute, and the wording always draws so actual health stays
-- visible. Empty bar tiles stay transparent like the native patch: only
-- filled tiles sample the strip. Artwork draws under the neutral image
-- tint however hostile the incoming graphics state is.
---@param graphics table<string, unknown> injected host graphics
---@param text table<string, unknown> borrowed text services
---@param assets table<string, unknown> generated battle assets
---@param art table<string, unknown> staged source character strip
---@param section table<string, unknown> staged source HUD section
---@param side table<string, unknown> anchored HUD box content under drawing
---@param battler table<string, unknown>? combatant facts under drawing
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param artKey string semantic HUD art key to pass to the printer
---@param sideType integer native side type used by source HUD spans
---@param wildEnemy boolean whether caught-marker art is source-visible
local function drawCompactHudCell(
  graphics,
  text,
  assets,
  art,
  section,
  side,
  battler,
  view,
  artKey,
  sideType,
  wildEnemy
)
  local layout = assert(side, "compact HUD artwork has an anchored box")
  local displayed = assert(battler, "compact HUD artwork belongs to a visible battler")
  local animation = assert(section.animation, "compact HUD artwork carries its native animation")
  local frame = assert(animation.frames[1], "compact HUD artwork carries its opening frame")
  local cell = assert(section.cells[frame.cell + 1], "compact HUD animation selects its opening cell")
  local objects = cell.objs
  local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
  for _, object in ipairs(objects) do
    if not object.disabled then
      left = math.min(left, object.x)
      top = math.min(top, object.y)
      right = math.max(right, object.x + object.width)
      bottom = math.max(bottom, object.y + object.height)
    end
  end
  local width, height = right - left, bottom - top
  local layoutX, layoutY = layout.x, layout.y
  local layoutWidth, layoutHeight = layout.width, layout.height
  assert(type(layoutX) == "number" and type(layoutY) == "number", "compact HUD box has native coordinates")
  assert(type(layoutWidth) == "number" and type(layoutHeight) == "number", "compact HUD box has native dimensions")
  local scale = math.min(layoutWidth / width, layoutHeight / height)
  local originX = layoutX + (layoutWidth - width * scale) / 2 - left * scale
  local originY = layoutY + (layoutHeight - height * scale) / 2 - top * scale
  -- Pool leases resolve to their staged image for the raw sampler calls
  -- while owned and test handles draw as resolved; pixel-less stand-ins
  -- skip the cell exactly like an unstaged strip.
  local source = art.image or (art.lease and art.lease.image) or art
  if type(source.setFilter) ~= "function" or type(source.getWidth) ~= "function" then
    return
  end
  source:setFilter("nearest", "nearest")
  local stripWidth = source:getWidth()
  local stripHeight = source:getHeight()
  local stripArt = source
  -- The drawable sampler is the handle itself when it samples (pool
  -- and test leases), else its admitted effect lease: pool borrows
  -- keep the sampler on the outer handle while the inner borrow token
  -- only pins the physical entry. Sampling through the shared rule
  -- resolves indexed strips exactly; raw images and recording
  -- stand-ins draw directly.
  local sampler = nil
  if type(art) == "table" then
    if type(art.drawQuad) == "function" then
      sampler = art
    elseif type(art.lease) == "table" and type(art.lease.drawQuad) == "function" then
      sampler = art.lease
    end
  end
  local function drawStripTile(quad, x, y, sx, sy)
    if sampler ~= nil then
      sampler:drawQuad(graphics, quad, x, y, 0, sx, sy)
    else
      graphics.draw(stripArt, quad, x, y, 0, sx, sy)
    end
  end

  local function drawObjects()
    for _, object in ipairs(objects) do
      if not object.disabled then
        local columns = object.width / 8
        for row = 0, object.height / 8 - 1 do
          local sourceTile = object.tile + row * columns
          local quad = graphics.newQuad(sourceTile * 8, 0, object.width, 8, stripWidth, stripHeight)
          drawStripTile(quad, originX + object.x * scale, originY + (object.y + row * 8) * scale, scale, scale)
        end
      end
    end
  end

  local function drawPatches(patches, componentBase)
    for _, patch in ipairs(patches) do
      if patch.fill == nil or patch.fill > 0 then
        local tile = patch.tile
        for _, object in ipairs(objects) do
          if not object.disabled then
            local columns = object.width / 8
            local offset = tile - object.tile
            if offset >= 0 and offset < columns * (object.height / 8) then
              local quad = graphics.newQuad((componentBase + patch.sourceTile) * 8, 0, 8, 8, stripWidth, stripHeight)
              drawStripTile(
                quad,
                originX + (object.x + offset % columns * 8) * scale,
                originY + (object.y + math.floor(offset / columns) * 8) * scale,
                scale,
                scale
              )
            end
          end
        end
      end
    end
  end

  drawObjects()
  local patchSpans = assert(view.hudPatchSpans, "compact HUD uses the source patch spans")
  local gaugePatches = view.gaugePatchTiles --[[@as table<integer, table<string, table<integer, table>>>?]]
  local sidePatches = gaugePatches ~= nil and gaugePatches[sideType] or nil
  local hp, maxHp = displayed.hp, displayed.maxHp
  assert(type(hp) == "number" and type(maxHp) == "number", "compact HUD carries numeric HP values")
  local health = sidePatches ~= nil and sidePatches.health or BattleScene.hpPatchTiles(patchSpans, sideType, hp, maxHp)
  -- Bar patches name component-relative source tiles like the icon
  -- patches below, so they ride the same staged component base.
  local componentBase = assert(section.componentBase, "compact HUD publishes the native component tile base")
  drawPatches(health, componentBase)
  local condition, gender, caught = displayed.condition, displayed.gender, displayed.caught
  assert(condition == nil or type(condition) == "string", "compact HUD status is a source status name")
  assert(gender == nil or type(gender) == "string", "compact HUD gender is a source category when present")
  assert(caught == nil or type(caught) == "boolean", "compact HUD caught marker is a source flag")
  caught = wildEnemy and caught or nil
  drawPatches(BattleScene.hudIconPatchTiles(patchSpans, sideType, condition, gender, caught), componentBase)
  if sideType == 0 then
    local into, span, level = displayed.expInto, displayed.expSpan, displayed.level
    if type(level) == "number" and level >= 100 then
      into, span = 0, 0
    end
    drawPatches(
      sidePatches ~= nil and sidePatches.experience
        or BattleScene.expPatchTiles(patchSpans, BattleScene.expTileFills(into, span)),
      componentBase
    )
  end
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  BattleRenderer.drawCompactHudPrinters(
    graphics,
    text,
    assets,
    view,
    artKey,
    section,
    objects,
    displayed,
    sideType,
    sideType == 0,
    { x = originX, y = originY, scale = scale }
  )
end

-- HUD regions the native cell printers write once the strip carries
-- pixels; the remaining regions always draw through the text services.
local PRINTED_HUD_REGIONS = { name = true, level = true, hp = true, gender = true, caught = true }

---@param graphics table<string, unknown> injected host graphics
---@param assets table<string, unknown> injected asset holder
---@param text table<string, unknown> borrowed text services
---@param artKey string artwork identity under drawing
---@param battler table<string, unknown>? combatant facts under drawing
---@param side table<string, unknown>? anchored HUD box content under drawing
---@param section table<string, unknown> staged source HUD section
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param sideType integer native side type used by source HUD spans
---@param wildEnemy boolean whether caught-marker art is source-visible
local function drawHudSide(graphics, assets, text, artKey, battler, side, section, view, sideType, wildEnemy)
  if type(side) ~= "table" then
    return
  end
  if battler == nil or battler.visible == false then
    return
  end
  local r, g, b, a = graphics.getColor()
  graphics.setColor(1, 1, 1, 1)
  local art = assets:drawable(artKey)
  local printerReady = false
  if art ~= nil then
    local source = art.image or (art.lease and art.lease.image) or art
    printerReady = type(source.getWidth) == "function"
    drawCompactHudCell(graphics, text, assets, art, section, side, battler, view, artKey, sideType, wildEnemy)
  end
  if type(side.regions) == "table" then
    for _, region in ipairs(side.regions) do
      if
        not (printerReady and PRINTED_HUD_REGIONS[region.id])
        and type(region.text) == "string"
        and region.text ~= ""
      then
        -- Wording never overflows its resolved region into the
        -- neighboring marks: the paired doubles panels fit the same
        -- way, so an overlong name truncates instead of painting over
        -- the gender and caught facts.
        text.drawText(fitText(text, region.text, region.width), region.x, region.y)
      end
    end
  end
  graphics.setColor(r, g, b, a)
end

---@param resources table<string, unknown> borrowed presentation services
---@param box table<string, unknown> one live, position-matched compact doubles panel
local function drawCompactDoublesPanel(resources, box)
  local graphics = assert(resources.graphics, "the compact render borrows its host graphics")
  local text = assert(resources.text, "the compact render borrows its text services")
  local windows = assert(resources.windows, "the compact render borrows its window services")
  local background = backgroundOf(resources)
  LogicalSurface.clip(graphics, box, function()
    fillBox(graphics, background, box)
    for _, region in ipairs(box.regions) do
      if not (box.side == 2 and region.id == "hp") and type(region.text) == "string" and region.text ~= "" then
        drawLabel(text, fitText(text, region.text, region.width), region.x, region.y)
      end
    end
    local bar = box.bar
    local fraction = assert(bar.fraction, "a compact doubles bar carries its own fraction")
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
    windows.drawApplicationFrame(contentOf(box), resources.frameKey)
  end)
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
  local text = assert(resources.text, "the compact render borrows its text services")
  local hud = content.hud
  if type(hud) ~= "table" then
    return
  end
  local viewport = content.scene
  if type(viewport) ~= "table" then
    viewport = { x = 0, y = 0, width = 256, height = 136 }
  end
  local boxes = (type(hud.boxes) == "table" and hud.boxes or nil) --[[@as table<integer, table<string, unknown>>?]]
  if boxes ~= nil then
    -- Doubles: one HUD box per live slot, matched by native position
    -- in the plan's box order with its own name, health and bar. The
    -- same resolved bounds drive paint; hidden slots draw nothing.
    local live = livePositions(BattleViewRoster.liveSides(view))
    for _, box in ipairs(boxes) do
      if live[box.position] ~= nil then
        drawCompactDoublesPanel(resources, box)
      end
    end
    return
  end
  local player, enemy = BattleViewRoster.firstPerSide(view)
  LogicalSurface.clip(graphics, viewport, function()
    local sections = assert(view.hudSections, "compact HUD carries staged native cell sections")
    drawHudSide(
      graphics,
      assets,
      text,
      "hud:enemy",
      enemy,
      hud.enemy --[[@as table<string, unknown>?]],
      sections.enemy,
      view,
      1,
      view.battleKind == "wild"
    )
    drawHudSide(
      graphics,
      assets,
      text,
      "hud:player",
      player,
      hud.player --[[@as table<string, unknown>?]],
      sections.player,
      view,
      0,
      false
    )
  end)
end

-- Draws the staged learning confirmation as the source two-option menu
-- with its staged labels centered on the option anchors; a pressed
-- option raises its label two pixels.
---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param childView table<string, unknown>? detached child view carrying the staged labels
local function drawTwoOptionModal(resources, view, childView)
  local text = resources.text --[[@as table<string, unknown>]]
  local graphics = assert(resources.graphics, "the compact render borrows its host graphics")
  local assets = assert(resources.assets, "the compact render borrows its asset holder")
  local pressed = BattleMenuPresenter.drawChildTwoOption(graphics, assets, view)
  local sourceLabels = assert(childView, "the child snapshot carries source text") --[[@as table<string, unknown>]]
  local labels = assert(sourceLabels.twoOption, "learning confirmation carries staged source labels") --[[@as table<string, unknown>]]
  local drawText = text.drawTextForRole --[[@as fun(role: string, content: string, x: number, y: number, colors: table<string, integer>?)?]]
  local measureText = text.measureForRole --[[@as fun(role: string, content: string): table<string, number>?]]
  local function drawOption(value, anchorY, colors, optionId)
    local label = assert(value, "the two-option source label is staged") --[[@as string]]
    local width = measureText ~= nil and measureText("menu", label).width or text.measure(label).width
    local y = pressed == optionId and anchorY - 2 or anchorY
    if drawText ~= nil then
      drawText("menu", label, 128 - math.floor(width / 2), y, colors)
    else
      text.drawText(label, 128 - math.floor(width / 2), y)
    end
  end
  drawOption(labels.top, 67, { foreground = 1, shadow = 2, background = 3 }, "yes")
  drawOption(labels.bottom, 139, { foreground = 10, shadow = 11, background = 12 }, "cancel")
end

-- Tabular row columns relative to the row origin: the entry name width,
-- the level or quantity column, and the health or legality column with
-- its width. Bag rows trade the level column for a wider item name.
local CHILD_ROW_COLUMNS = { nameWidth = 68, subX = 116, detailX = 156, detailWidth = 80 }
local CHILD_BAG_ROW_COLUMNS = { nameWidth = 100, subX = 146, detailX = 180, detailWidth = 56 }

---@param text table<string, unknown> borrowed text services
---@param box table<string, unknown> canonical learning row under drawing
---@param index integer one-based row number
---@param focused boolean true when the row holds the child focus
local function drawLearnRow(text, box, index, focused)
  local x, y =
    box.x, --[[@as number]]
    box.y --[[@as number]]
  local label = tostring(box.label or "")
  if focused then
    label = CURSOR .. " " .. label
  end
  label = tostring(index) .. ". " .. label
  if box.enabled ~= true and box.empty ~= true then
    label = label .. " [X]"
  end
  drawLabel(text, fitText(text, label, 128), x + 4, y + 4)
  if type(box.detail) == "string" and box.detail ~= "" then
    drawLabel(text, fitText(text, box.detail, 96), x + 136, y + 4)
  end
end

---@param text table<string, unknown> borrowed text services
---@param box table<string, unknown> canonical party, target, or bag row under drawing
---@param index integer one-based row number
---@param focused boolean true when the row holds the child focus
---@param columns table<string, number> tabular columns relative to the row origin
local function drawTabularRow(text, box, index, focused, columns)
  local x, y =
    box.x, --[[@as number]]
    box.y --[[@as number]]
  drawLabel(text, (focused and CURSOR or " ") .. " " .. tostring(index) .. ".", x + 4, y + 4)
  local name = tostring(box.label or "")
  if box.enabled ~= true and box.empty ~= true then
    name = name .. " [X]"
  end
  drawLabel(text, fitText(text, name, columns.nameWidth), x + 36, y + 4)
  if type(box.sub) == "string" and box.sub ~= "" then
    drawLabel(text, tostring(box.sub), x + columns.subX, y + 4)
  end
  if type(box.detail) == "string" and box.detail ~= "" then
    drawLabel(text, fitText(text, box.detail, columns.detailWidth), x + columns.detailX, y + 4)
  end
end

---@param childView table<string, unknown> detached child view carrying the staged confirmation
---@return string staged confirmation wording
local function learnConfirmation(childView)
  local confirmation = childView.confirmation --[[@as table<string, unknown>]]
  if confirmation.kind == "stop" then
    return "Stop learning " .. tostring(childView.incomingMove or "?") .. "?"
  elseif confirmation.kind == "decline" then
    return "Do not learn " .. tostring(childView.incomingMove or "?") .. "?"
  end
  local rows = childView.rows --[[@as table<integer, table<string, unknown>>?]]
  local slot = confirmation.slot --[[@as integer?]]
  local name = "?"
  if type(rows) == "table" and type(slot) == "number" and type(rows[slot + 1]) == "table" then
    name = tostring(rows[slot + 1].label or "?")
  end
  return "Forget " .. name .. "?"
end

-- The modal footer: the staged learning confirmation wording, Back or
-- the forced-choice notice, bag pocket stepping, and the notice or
-- guidance caption outside learning.
---@param text table<string, unknown> borrowed text services
---@param childPlan table<string, unknown> canonical child plan content
---@param childView table<string, unknown>? detached child view under drawing
local function drawChildFooter(text, childPlan, childView)
  local view = type(childView) == "table" and childView or nil
  if view ~= nil and view.kind == "learn" and type(view.confirmation) == "table" then
    drawLabel(text, fitText(text, learnConfirmation(view), 232), 12, 136)
  end
  if childPlan.hasBack == true then
    local back = childPlan.back --[[@as table<string, unknown>]]
    drawLabel(text, "BACK", back.x --[[@as number]] + 4, back.y --[[@as number]] + 4)
  elseif view ~= nil and (view.kind == "party" or view.kind == "target") then
    drawLabel(text, "No retreat!", 12, 156)
  end
  if childPlan.hasPocketNav == true then
    drawLabel(text, "<", 100, 156)
    drawLabel(text, ">", 232, 156)
  end
  if view == nil or view.kind == "learn" then
    return
  end
  local notice = view.notice
  if type(notice) ~= "string" or notice == "" then
    notice = BattleChildText.subtitle(view)
  end
  drawLabel(text, fitText(text, notice, 232), 12, 172)
end

-- Draws the open child as a fullscreen 256x192 modal: the title,
-- every projected row with its focus and disabled marks, the staged
-- learning confirmation, and the permitted Back and pocket controls.
-- The battlefield stays hidden behind the modal while open.
---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param content table<string, unknown> canonical compact plan content under drawing
---@param placement LayoutGeometry.Placement resolved placement of the compact pane
local function drawChildModal(resources, view, content, placement)
  local text = assert(resources.text, "the compact render borrows its text services")
  local windows = assert(resources.windows, "the compact render borrows its window services")
  local background = backgroundOf(resources)
  local childPlan = assert(content.child, "the child modal carries its plan")
  local childView = view.childView --[[@as table<string, unknown>?]]
  if type(childView) == "table" then
    local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
    if BattleRenderer.drawNativeChild(resources, childView, placement) then
      return
    end
  end
  if childPlan.twoOption == true then
    drawTwoOptionModal(resources, view, childView)
    return
  end
  fillBox(resources.graphics, background, { x = 0, y = 0, width = 256, height = 192 })
  drawLabel(text, fitText(text, tostring(childPlan.title or ""), 200), 12, 10)
  if type(childView) == "table" then
    local occupancy = BattleChildText.occupancy(childView)
    if occupancy ~= nil then
      drawLabel(text, occupancy, 216, 10)
    end
    if childView.kind == "bag" and type(childView.stock) == "number" then
      drawLabel(text, "Stock: " .. tostring(childView.stock), 176, 10)
    end
  end
  local rows = childPlan.rows --[[@as table<integer, table<string, unknown>>?]]
  local focusId = type(childView) == "table" and childView.focusId or nil
  if type(rows) == "table" then
    local columns = childPlan.kind == "bag" and CHILD_BAG_ROW_COLUMNS or CHILD_ROW_COLUMNS
    for index, row in ipairs(rows) do
      if childPlan.kind == "learn" then
        drawLearnRow(text, row, index, focusId == row.id)
      else
        drawTabularRow(text, row, index, focusId == row.id, columns)
      end
    end
  end
  drawChildFooter(text, childPlan, childView)
  windows.drawApplicationFrame({ x = 8, y = 8, width = 240, height = 176 }, resources.frameKey)
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
    if view.mode == "child" and type(content.child) == "table" and type(view.childView) == "table" then
      drawChildModal(resources, view, content, placement)
      return
    end
    BattleRenderer.drawPane(resources, view, BattleCompactInterface.NATIVE.id, content, placement)
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
---@param view table<string, unknown>? internal semantic snapshot under resolution
---@return string stable input-geometry identity for the semantic state
local function inputKey(mode, requestId, selection, signature, view)
  local parts = { INPUT_KEY, mode, tostring(selection), tostring(requestId or 0), tostring(signature or "-") }
  if type(view) == "table" and type(view.childView) == "table" then
    local child = view.childView --[[@as table<string, unknown>]]
    parts[#parts + 1] = tostring(child.kind or "-") .. ":" .. tostring(child.focusId or "-")
    local confirmation = child.confirmation
    if type(confirmation) == "table" then
      parts[#parts + 1] = tostring(confirmation.kind or "-")
    end
  end
  return table.concat(parts, ":")
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
      signature,
      view
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
-- shared cover-or-frame helper. Below the one-times fit floor the pane
-- keeps integer mapping at the logical origin so every control stays
-- addressable through one transform.
---@param context table<string, unknown> layout context carrying the measurement
---@param view table<string, unknown> internal semantic snapshot under resolution
---@return table<string, unknown> complete compact plan
function BattleCompactInterface.nativeLike(context, view)
  local geometry =
    ApplicationLayout.coverOrFrame(context --[[@as ApplicationLayout.Context]], BattleCompactInterface.NATIVE, {
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

-- Pair-too-small compact fallback: when a paired composition cannot fit,
-- the same compact pane resolves instead of a clipped battle.
BattleCompactInterface.fallback = BattleCompactInterface.nativeLike

return BattleCompactInterface
