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

local BattleChildText = require("game.hgss.src.battle.BattleChildText")

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

---@param record table<string, unknown> displayed battler facts under drawing
---@return boolean true when the record owns a live battlefield slot
local function liveSlot(record)
  -- Only live active records draw: hidden (cue-withdrawn, fainted,
  -- unrevealed), inactive (benched) and historic records never own a
  -- current sprite or HUD.
  return type(record) == "table" and record.visible ~= false and record.active ~= false
end

---@param records table<integer, table<string, unknown>> one side live records under ordering
local function sortBySlot(records)
  -- Positions stay opaque: only the relative order within a side
  -- decides the left/right cell, never a hardcoded slot number. The
  -- combatant identity breaks ties deterministically.
  table.sort(records, function(a, b)
    local pa, pb = a.position, b.position
    if type(pa) == "number" and type(pb) == "number" and pa ~= pb then
      return pa < pb
    end
    return a.combatant < b.combatant
  end)
end

-- Canonical side slot order behind stable rows: every distinct native
-- position an active record claims on the side, hidden records
-- included, in slot order. Withdrawal, faint and reveal cues hide and
-- show records without moving slots, so the survivors keep their rows
-- while a neighbor transitions instead of reindexing onto its row.
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param playerSide boolean true for the near player side, false for the far foe side
---@return integer[] distinct claimed native positions in slot order
local function canonicalOrder(view, playerSide)
  local seen = {} ---@type table<integer, boolean>
  local order = {} ---@type integer[]
  if type(view.battlers) == "table" then
    for _, battler in ipairs(view.battlers) do
      if
        type(battler) == "table"
        and battler.active ~= false
        and type(battler.position) == "number"
        and (battler.side == 1) == playerSide
        and not seen[
          battler.position --[[@as integer]]
        ]
      then
        seen[
          battler.position --[[@as integer]]
        ] = true
        order[#order + 1] = battler.position --[[@as integer]]
      end
    end
  end
  table.sort(order)
  return order
end

-- Layout family follows occupied native slots, never transient
-- visibility: a single battle keeps its established anchors while a
-- lead hides mid-switch, and a double battle keeps its rows while a
-- neighbor hides mid-transition. The live-count fallback keeps
-- position-less views on their established layout.
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param players table<integer, table<string, unknown>> live player-side battler facts
---@param enemies table<integer, table<string, unknown>> live enemy-side battler facts
---@return boolean true while the battle occupies doubles slots
local function doublesFormat(view, players, enemies)
  if #players > 1 or #enemies > 1 then
    return true
  end
  return #canonicalOrder(view, true) >= 2 or #canonicalOrder(view, false) >= 2
end

-- Resolves one live battler's stable sourced row: its index in the
-- canonical claimed order, so a surviving slot never slides onto a
-- hidden neighbor's row. Records without a native position keep
-- their live-order row, matching the legacy layout.
---@param order integer[] canonical claimed positions in slot order
---@param battler table<string, unknown> live battler facts under drawing
---@param fallback integer live-order row behind position-less records
---@param rows table<integer, table<string, unknown>> sourced rows behind the side
---@param context string assertion context naming the sourced rows
---@return table<string, unknown> the battler's stable row
local function doublesRow(order, battler, fallback, rows, context)
  local position = battler.position
  if type(position) == "number" then
    for index, slot in ipairs(order) do
      if slot == position then
        assert(rows[index] ~= nil, context)
        return rows[index]
      end
    end
  end
  assert(rows[fallback] ~= nil, context)
  return rows[fallback]
end

-- Doubled battlefield rows from the retail source tables, in 256x192
-- upper-screen pixels. Settled X and the HUD anchors come from the
-- doubles layout tables; portrait anchors are center-style for nominal
-- 80x80 pictures (species height offsets from the retail picture
-- routine have no mon-fact counterpart here, so the vertical
-- composition uses the base row unshifted). Rows stay verbatim per
-- side: the enemy left row sits screen-right of the enemy right row.
-- Source: overlay_07 asm settled-X and entry/base/Z tables, the
-- opponent-controller construction and entry-to-settled move, the four
-- doubled health-bar sprite templates, and the picture-center
-- semantics (pret/pokeheartgold@9d8b7591). Positions stay opaque: the
-- first sorted slot of a side owns that side's left row, whatever
-- screen side that row lands on. Entry coordinates and depths are
-- source data, never 2D layering: paint order follows slot order.
local DOUBLES_ROWS = {
  player = {
    {
      type = 2,
      sprite = { x = 40, y = 112 },
      hud = { x = 192, y = 103 },
      art = "hud:player-left",
    },
    {
      type = 4,
      sprite = { x = 80, y = 120 },
      hud = { x = 198, y = 132 },
      art = "hud:player-right",
    },
  },
  enemy = {
    {
      type = 3,
      sprite = { x = 216, y = 50 },
      hud = { x = 64, y = 16 },
      art = "hud:enemy-left",
    },
    {
      type = 5,
      sprite = { x = 176, y = 42 },
      hud = { x = 58, y = 45 },
      art = "hud:enemy-right",
    },
  },
}

-- Half the nominal picture edge: sourced centers convert to top-left
-- draw origins through this inset. No per-species picture height rides
-- the mon facts, so no height shift applies; that gap stays open until
-- a sourced height counterpart lands.
local PORTRAIT_HALF = 40

local DOUBLES_HUD_SECTIONS = {
  ["hud:player-left"] = "playerLeft",
  ["hud:player-right"] = "playerRight",
  ["hud:enemy-left"] = "enemyLeft",
  ["hud:enemy-right"] = "enemyRight",
}
local DOUBLES_FIELDS = {
  ["hud:player-left"] = {
    name = { x = 144, y = 88 },
    level = { x = 224, y = 91 },
    condition = { x = 208, y = 91 },
    bar = { x = 192, y = 107 },
  },
  ["hud:player-right"] = {
    name = { x = 150, y = 117 },
    level = { x = 230, y = 120 },
    condition = { x = 214, y = 120 },
    bar = { x = 198, y = 136 },
  },
  ["hud:enemy-left"] = {
    name = { x = 14, y = 4 },
    level = { x = 88, y = 4 },
    condition = { x = 72, y = 4 },
    bar = { x = 56, y = 20 },
  },
  ["hud:enemy-right"] = {
    name = { x = 8, y = 33 },
    level = { x = 82, y = 33 },
    condition = { x = 66, y = 33 },
    bar = { x = 50, y = 49 },
  },
}
local DOUBLES_BAR_WIDTH = 48
local DOUBLES_BAR_HEIGHT = 4

-- Loud doubles occupancy: at most two live records per side and no
-- shared visible slot. Identity rides the message so a doubled claim
-- names both combatants.
---@param players table<integer, table<string, unknown>> live player-side battler facts
---@param enemies table<integer, table<string, unknown>> live enemy-side battler facts
local function checkDoublesSlots(players, enemies)
  assert(#players <= 2, "at most two live player battlers draw (got " .. tostring(#players) .. ")")
  assert(#enemies <= 2, "at most two live enemy battlers draw (got " .. tostring(#enemies) .. ")")
  local claimed = {}
  for _, battler in ipairs(players) do
    if type(battler.position) == "number" then
      local other = claimed[battler.position]
      assert(
        other == nil,
        "native slot "
          .. tostring(battler.position)
          .. " is visibly claimed twice (combatants "
          .. tostring(other)
          .. " and "
          .. tostring(battler.combatant)
          .. ")"
      )
      claimed[battler.position] = battler.combatant
    end
  end
  for _, battler in ipairs(enemies) do
    if type(battler.position) == "number" then
      local other = claimed[battler.position]
      assert(
        other == nil,
        "native slot "
          .. tostring(battler.position)
          .. " is visibly claimed twice (combatants "
          .. tostring(other)
          .. " and "
          .. tostring(battler.combatant)
          .. ")"
      )
      claimed[battler.position] = battler.combatant
    end
  end
end

---@param view table<string, unknown> internal semantic snapshot
---@return table<integer, table<string, unknown>> live player-side battler facts in slot order
---@return table<integer, table<string, unknown>> live enemy-side battler facts in slot order
local function splitBattlers(view)
  local players, enemies = {}, {}
  if type(view.battlers) == "table" then
    for _, battler in ipairs(view.battlers) do
      if liveSlot(battler) then
        if battler.side == 1 then
          players[#players + 1] = battler
        else
          enemies[#enemies + 1] = battler
        end
      end
    end
  end
  sortBySlot(players)
  sortBySlot(enemies)
  return players, enemies
end

---@param assets table<string, unknown> injected asset holder
---@param record table<string, unknown> displayed battler facts under drawing
---@return table<string, unknown>? portrait drawable for the displayed battler, nil while unavailable: the pool lease plus cell quad in production, the bare lease for whole images, or a headless descriptor under inspection
local function battlerImage(assets, record)
  -- Each displayed battler draws its own exact canonical portrait:
  -- the selector rides the displayed record, so a switch rebinds the
  -- cell at its reveal instead of reusing a side-role picture. The
  -- handle pairs the pooled atlas lease with its renderer-owned cell
  -- quad, so the drawn pixels are exactly the staged cell through the
  -- lease sampler surface.
  -- A record without a canonical selector draws nothing: nil means
  -- unavailable, never a substitute picture.
  local selector = record.portraitSelector
  if type(selector) == "string" and selector ~= "" then
    -- Production handles pair the pool lease with its cell quad;
    -- recording doubles answer the same lease-plus-quad shape instead.
    return assets:drawable("mon:" .. selector)
  end
  return nil
end

-- Draws one borrowed portrait cell at its anchor: the pooled page image
-- clipped to the staged cell quad, so the top-left of the drawn cell
-- lands exactly where the retired per-battler copy drew.
---@param graphics table<string, unknown> injected host graphics
---@param handle table<string, unknown> borrowed portrait cell or headless descriptor
---@param x number anchor horizontal origin under drawing
---@param y number anchor vertical origin under drawing
local function drawPortraitCell(graphics, handle, x, y)
  -- Headless inspection descriptors carry no lease or quad: they
  -- record their whole-draw exactly like the raw draws they replace.
  local lease = handle.lease or handle
  if handle.quad ~= nil then
    lease:drawQuad(graphics, handle.quad, x, y)
  else
    lease:draw(graphics, x, y)
  end
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
---@param lease table<string, unknown> staged strip lease under drawing
---@param stripWidth integer staged strip width in pixels
---@param baseX number anchor horizontal origin under drawing
---@param baseY number anchor vertical origin under drawing
---@param obj table<string, unknown> compiled object carrying tile, width, height, x, y
local function drawSpriteObject(graphics, lease, stripWidth, baseX, baseY, obj)
  local tile = obj.tile --[[@as integer]]
  local width = obj.width --[[@as integer]]
  local height = obj.height --[[@as integer]]
  local tilesPerRow = math.floor(width / 8)
  local rows = math.floor(height / 8)
  for row = 0, rows - 1 do
    local quad = graphics.newQuad((tile + row * tilesPerRow) * 8, 0, width, STRIP_HEIGHT, stripWidth, STRIP_HEIGHT)
    lease:drawQuad(graphics, quad, baseX + obj.x --[[@as number]], baseY + obj.y --[[@as number]] + row * 8)
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

-- Draws the opening cell of a staged native doubles HUD at its template
-- anchor. The source compiler normalizes cell-bank tile bases into staged
-- strip indices while preserving the existing cell shape.
---@param graphics table<string, unknown> injected host graphics
---@param assets table<string, unknown> injected asset holder
---@param sections table<string, unknown> staged role sections
---@param artKey string semantic doubles HUD image key
---@param anchor table<string, number> native sprite template anchor
local function drawDoublesHudCell(graphics, assets, sections, artKey, anchor)
  local sectionKey = assert(DOUBLES_HUD_SECTIONS[artKey], "doubles HUD rows name a source section")
  local section = assert(sections[sectionKey], "the doubled battle manifest carries " .. sectionKey)
  local animation = assert(section.animation, "the doubled HUD section carries its selected animation")
  local firstFrame = assert(animation.frames[1], "the doubled HUD animation carries its opening frame")
  local cell = assert(section.cells[firstFrame.cell + 1], "the doubled HUD animation selects a source cell")
  local art = assets:drawable(artKey)
  if art == nil then
    return
  end
  for index, obj in ipairs(cell.objs) do
    local context = sectionKey .. " source object " .. tostring(index)
    assert(not obj.affine, context .. " uses unsupported affine drawing")
    assert(not obj.flipH and not obj.flipV, context .. " uses unsupported object flipping")
    assert(obj.palette == 0, context .. " selects the staged role palette")
    assert(not obj.mosaic and obj.objMode == "normal", context .. " uses unsupported object display flags")
    assert(obj.colorMode == "16-color", context .. " uses unsupported color depth")
    if not obj.disabled then
      drawSpriteObject(graphics, art, HUD_STRIP_WIDTH, anchor.x, anchor.y, obj)
    end
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

---@param graphics table<string, unknown> injected host graphics
---@param text table<string, unknown> borrowed text services
---@param assets table<string, unknown> injected asset holder
---@param sections table<string, unknown> staged role sections
---@param r number borrowed red channel for restoration
---@param g number borrowed green channel for restoration
---@param b number borrowed blue channel for restoration
---@param a number borrowed alpha channel for restoration
---@param view table<string, unknown> internal semantic snapshot carrying claimed slots
---@param players table<integer, table<string, unknown>> live player-side battler facts in slot order
---@param enemies table<integer, table<string, unknown>> live enemy-side battler facts in slot order
local function drawDoublesDetail(graphics, text, assets, sections, r, g, b, a, view, players, enemies)
  -- Every live slot paints its own sprite and HUD at its canonical
  -- sourced row: the surviving partner never reindexes when a slot
  -- empties mid-transition, and a missing portrait or strip draws
  -- nothing under the existing missing-art pending path (never a
  -- fallback mon or a shared single-battle strip).
  checkDoublesSlots(players, enemies)
  local foeOrder = canonicalOrder(view, false)
  local allyOrder = canonicalOrder(view, true)
  for index, foe in ipairs(enemies) do
    local row = doublesRow(foeOrder, foe, index, DOUBLES_ROWS.enemy, "the sourced enemy rows cover every live foe")
    local front = battlerImage(assets, foe)
    if front ~= nil then
      local dx = (type(foe.shakeDx) == "number" and foe.shakeDx or 0) --[[@as number]]
      drawPortraitCell(graphics, front, row.sprite.x - PORTRAIT_HALF + dx, row.sprite.y - PORTRAIT_HALF)
    end
    drawDoublesHudCell(graphics, assets, sections, row.art, row.hud)
    local fields = assert(DOUBLES_FIELDS[row.art], "doubled enemy rows carry field bounds")
    text.drawText(tostring(foe.name or "FOE"), fields.name.x, fields.name.y)
    if type(foe.level) == "number" then
      text.drawText("Lv" .. tostring(foe.level), fields.level.x, fields.level.y)
    end
    if type(foe.condition) == "string" and foe.condition ~= "" then
      text.drawText(foe.condition --[[@as string]], fields.condition.x, fields.condition.y)
    end
    local foeHp = (type(foe.hp) == "number" and foe.hp or 0) --[[@as number]]
    local foeMaxHp = (type(foe.maxHp) == "number" and foe.maxHp or 1) --[[@as number]]
    local foeFraction = barFraction(foeHp, foeMaxHp)
    setBarColor(graphics, foeFraction)
    graphics.rectangle("fill", fields.bar.x, fields.bar.y, DOUBLES_BAR_WIDTH * foeFraction, DOUBLES_BAR_HEIGHT)
    restoreColor(graphics, r, g, b, a)
  end
  for index, ally in ipairs(players) do
    local row = doublesRow(allyOrder, ally, index, DOUBLES_ROWS.player, "the sourced player rows cover every live ally")
    local back = battlerImage(assets, ally)
    if back ~= nil then
      local dx = (type(ally.shakeDx) == "number" and ally.shakeDx or 0) --[[@as number]]
      drawPortraitCell(graphics, back, row.sprite.x - PORTRAIT_HALF + dx, row.sprite.y - PORTRAIT_HALF)
    end
    drawDoublesHudCell(graphics, assets, sections, row.art, row.hud)
    local fields = assert(DOUBLES_FIELDS[row.art], "doubled player rows carry field bounds")
    local hp = (type(ally.hp) == "number" and ally.hp or 0) --[[@as number]]
    local maxHp = (type(ally.maxHp) == "number" and ally.maxHp or 1) --[[@as number]]
    text.drawText(tostring(ally.name or "LEAD"), fields.name.x, fields.name.y)
    if type(ally.level) == "number" then
      text.drawText("Lv" .. tostring(ally.level), fields.level.x, fields.level.y)
    end
    if type(ally.condition) == "string" and ally.condition ~= "" then
      text.drawText(ally.condition --[[@as string]], fields.condition.x, fields.condition.y)
    end
    local fraction = barFraction(hp, maxHp)
    setBarColor(graphics, fraction)
    graphics.rectangle("fill", fields.bar.x, fields.bar.y, DOUBLES_BAR_WIDTH * fraction, DOUBLES_BAR_HEIGHT)
    restoreColor(graphics, r, g, b, a)
  end
end

-- The doubled arrow base follows the acting partner at draw time:
-- one arrow offset left of that slot's health-box anchor, never a
-- hardcoded column. Without an acting identity the first player row
-- anchors it. The single-battle base stays frozen for pixel identity.
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param players table<integer, table<string, unknown>> live player-side battler facts in slot order
---@return number base horizontal origin
---@return number base vertical origin
local function doublesArrowBase(view, players)
  local row = DOUBLES_ROWS.player[1]
  local actor = view.actor --[[@as table<string, unknown>?]]
  if type(actor) == "table" and actor.combatant ~= nil then
    local order = canonicalOrder(view, true)
    for index, ally in ipairs(players) do
      if ally.combatant == actor.combatant then
        row = doublesRow(order, ally, index, DOUBLES_ROWS.player, "the sourced player rows cover every live ally")
        break
      end
    end
  end
  return row.hud.x - BattleRenderer.ARROW_OFFSET, row.hud.y
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
local function drawDetail(resources, view)
  local graphics = assert(resources.graphics, "the battle render borrows its host graphics")
  local text = assert(resources.text, "the battle render borrows its text services")
  local windows = assert(resources.windows, "the battle render borrows its window services")
  local assets = assert(resources.assets, "the battle render borrows its asset holder")
  local doublesHud = resources.doublesHud --[[@as table<string, unknown>?]]
  local r, g, b, a = saveColor(graphics)
  local scene = assets:drawable(resources.sceneImageKey --[[@as string]])
  if scene ~= nil then
    scene:draw(graphics, 0, 0)
  end
  local players, enemies = splitBattlers(view)
  local singles = not doublesFormat(view, players, enemies)
  if not singles then
    drawDoublesDetail(
      graphics,
      text,
      assets,
      assert(doublesHud, "the doubled battle render borrows its verified HUD sections"),
      r,
      g,
      b,
      a,
      view,
      players,
      enemies
    )
  end
  local player = singles and players[1] or nil
  local enemy = singles and enemies[1] or nil
  if enemy ~= nil and enemy.visible ~= false then
    local front = battlerImage(assets, enemy)
    if front ~= nil then
      local dx = (type(enemy.shakeDx) == "number" and enemy.shakeDx or 0) --[[@as number]]
      drawPortraitCell(graphics, front, BattleRenderer.ENEMY_CENTER.x + dx, BattleRenderer.ENEMY_CENTER.y)
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
    local back = battlerImage(assets, player)
    if back ~= nil then
      local dx = (type(player.shakeDx) == "number" and player.shakeDx or 0) --[[@as number]]
      drawPortraitCell(graphics, back, BattleRenderer.PLAYER_CENTER.x + dx, BattleRenderer.PLAYER_CENTER.y)
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
        local baseX, baseY
        if singles then
          baseX = BattleRenderer.PLAYER_HUD.x - BattleRenderer.ARROW_OFFSET
          baseY = BattleRenderer.PLAYER_HUD.y - 2
        else
          baseX, baseY = doublesArrowBase(view, players)
        end
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

---@param view table<string, unknown> internal semantic snapshot under drawing
---@return string? acting battler display name, nil outside multi-actor decisions
local function actingName(view)
  local actor = view.actor --[[@as table<string, unknown>?]]
  if type(actor) ~= "table" or type(actor.total) ~= "number" or actor.total <= 1 then
    return nil
  end
  if type(view.battlers) == "table" then
    for _, battler in ipairs(view.battlers) do
      if
        type(battler) == "table"
        and battler.combatant == actor.combatant
        and type(battler.name) == "string"
        and battler.name ~= ""
      then
        return battler.name --[[@as string]]
      end
    end
  end
  return nil
end

---@param view table<string, unknown> internal semantic snapshot under drawing
---@param id string target control identity under drawing
---@return string? projected target display name, nil without its candidate
local function targetName(view, id)
  local candidates = view.targetCandidates --[[@as table<integer, table<string, unknown>>?]]
  if type(candidates) ~= "table" then
    return nil
  end
  for _, candidate in ipairs(candidates) do
    if type(candidate) == "table" and candidate.id == id then
      if type(candidate.name) == "string" and candidate.name ~= "" then
        return candidate.name --[[@as string]]
      end
      return id
    end
  end
  return nil
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
        art:draw(graphics, box.x --[[@as number]] + shift, box.y --[[@as number]] + shift)
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
        -- Target rows name their projected candidate with the focus
        -- marker, so the chosen foe never depends on sprite order.
        local name = targetName(view, id) or id
        if view.selection == id then
          name = "> " .. name
        end
        text.drawText(
          fitLabel(text, name, box.w --[[@as number]]),
          box.x --[[@as number]] + shift,
          box.y --[[@as number]] + shift
        )
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

-- Battle child modal geometry inside one 256x192 interaction surface.
-- The paired pointer mapper publishes hit regions from these same
-- numbers, and the compact fullscreen modal reuses them, so a painted
-- row and its tap target always agree.
local CHILD_TITLE = { x = 8, y = 8, maxWidth = 240 }
local CHILD_ROW_X = 8
local CHILD_ROW_Y0 = 32
local CHILD_ROW_H = 20
local CHILD_LABEL_X = 12
local CHILD_DETAIL_X = 144
local CHILD_CONFIRM_Y = 136
local CHILD_BACK_LABEL = { x = 12, y = 156 }
local CHILD_NOTICE = { x = 12, y = 172, maxWidth = 232 }

---@param child table<string, unknown> detached child view under titling
---@return string modal title wording
local function childTitle(child)
  local kind = child.kind
  if kind == "target" then
    return "Use " .. tostring(child.stagedItem or "the item") .. " on whom?"
  elseif kind == "bag" then
    if child.empty == true then
      return "The bag is empty."
    end
    local page = child.page --[[@as table<string, unknown>?]]
    local paging = ""
    if type(page) == "table" then
      paging = " " .. tostring(page.current or 1) .. "/" .. tostring(page.count or 1)
    end
    return "BAG: " .. tostring(child.currentPocket or "?") .. paging
  elseif kind == "learn" then
    return "Forget a move for " .. tostring(child.incomingMove or "?") .. "?"
  end
  if child.cancellable == true then
    return "Choose a Pokemon!"
  end
  return "Choose a replacement!"
end

---@param child table<string, unknown> detached child view under confirmation wording
---@return string staged confirmation wording
local function learnConfirmText(child)
  local confirmation = child.confirmation --[[@as table<string, unknown>?]]
  if type(confirmation) ~= "table" then
    return ""
  end
  if confirmation.kind == "stop" then
    return "Stop learning " .. tostring(child.incomingMove or "?") .. "?"
  end
  if confirmation.kind == "decline" then
    return "Do not learn " .. tostring(child.incomingMove or "?") .. "?"
  end
  local rows = child.rows --[[@as table<integer, table<string, unknown>>?]]
  local slot = confirmation.slot --[[@as integer?]]
  local name = "?"
  if type(rows) == "table" and type(slot) == "number" and type(rows[slot + 1]) == "table" then
    name = tostring(rows[slot + 1].label or "?")
  end
  return "Forget " .. name .. "?"
end

-- Draws the open child as a battle-local modal over the lower pane:
-- the title, every projected row with its focus and disabled marks,
-- the staged learning confirmation, and the permitted Back/Confirm
-- and pocket controls. Upper-battlefield drawing is untouched.
---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
---@param child table<string, unknown> detached child view under drawing
local function drawChild(resources, view, child)
  local text = assert(resources.text, "the battle render borrows its text services")
  local windows = assert(resources.windows, "the battle render borrows its window services")
  windows.drawWindow({ x = 0, y = 0, width = 256, height = 192 }, resources.frameKey, { 0, 0, 0 })
  text.drawText(fitLabel(text, childTitle(child), CHILD_TITLE.maxWidth), CHILD_TITLE.x, CHILD_TITLE.y)
  local occupancy = BattleChildText.occupancy(child)
  if occupancy ~= nil then
    text.drawText(occupancy, 216, CHILD_TITLE.y)
  end
  if child.kind == "bag" and type(child.stock) == "number" then
    text.drawText("Stock: " .. tostring(child.stock), 184, CHILD_TITLE.y)
  end
  local rows = child.rows --[[@as table<integer, table<string, unknown>>?]]
  if type(rows) == "table" then
    for index, row in ipairs(rows) do
      if index > 6 then
        break
      end
      local box = row --[[@as table<string, unknown>]]
      local y = CHILD_ROW_Y0 + (index - 1) * CHILD_ROW_H
      if child.kind == "learn" then
        local marker = (child.focusId == box.id) and "> " or "  "
        local label = marker .. tostring(index) .. ". " .. tostring(box.label or "")
        text.drawText(fitLabel(text, label, 128), CHILD_LABEL_X, y + 4)
        if type(box.detail) == "string" and box.detail ~= "" then
          text.drawText(fitLabel(text, box.detail, 100), CHILD_DETAIL_X, y + 4)
        end
      else
        -- Tabular rows share one column each for the focused number,
        -- the entry name, its level or quantity, and its health or
        -- legality facts, so every visible fact has its own draw.
        local head = ((child.focusId == box.id) and "> " or "  ") .. tostring(index) .. "."
        text.drawText(head, CHILD_LABEL_X, y + 4)
        local name = tostring(box.label or "")
        if box.enabled ~= true and box.empty ~= true then
          name = name .. " [X]"
        end
        local nameWidth = 68
        local subX = 116
        local detailX = 156
        local detailWidth = 80
        if child.kind == "bag" then
          nameWidth = 100
          subX = 146
          detailX = 180
          detailWidth = 56
        end
        text.drawText(fitLabel(text, name, nameWidth), 44, y + 4)
        if type(box.sub) == "string" and box.sub ~= "" then
          text.drawText(box.sub, subX, y + 4)
        end
        if type(box.detail) == "string" and box.detail ~= "" then
          text.drawText(fitLabel(text, box.detail, detailWidth), detailX, y + 4)
        end
      end
    end
  end
  if child.kind == "learn" and type(child.confirmation) == "table" then
    text.drawText(fitLabel(text, learnConfirmText(child), 240), CHILD_ROW_X, CHILD_CONFIRM_Y)
  end
  if child.kind == "learn" then
    if type(child.confirmation) == "table" then
      text.drawText("CONFIRM", CHILD_BACK_LABEL.x, CHILD_BACK_LABEL.y)
    end
    text.drawText("BACK", CHILD_NOTICE.x, CHILD_NOTICE.y)
  else
    if child.cancellable == true then
      text.drawText("BACK", CHILD_BACK_LABEL.x, CHILD_BACK_LABEL.y)
    elseif child.kind == "party" or child.kind == "target" then
      text.drawText("No retreat!", CHILD_BACK_LABEL.x, CHILD_BACK_LABEL.y)
    end
  end
  if child.kind == "bag" and child.empty ~= true then
    text.drawText("<", 100, CHILD_BACK_LABEL.y)
    text.drawText(">", 232, CHILD_BACK_LABEL.y)
  end
  if type(child.notice) == "string" and child.notice ~= "" then
    if child.kind ~= "learn" then
      text.drawText(fitLabel(text, child.notice, CHILD_NOTICE.maxWidth), CHILD_NOTICE.x, CHILD_NOTICE.y)
    end
  elseif child.kind ~= "learn" then
    text.drawText(
      fitLabel(text, BattleChildText.subtitle(child), CHILD_NOTICE.maxWidth),
      CHILD_NOTICE.x,
      CHILD_NOTICE.y
    )
  end
  local _ = view
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
---@param content table<string, unknown> canonical plan content carrying the layout
local function drawInteraction(resources, view, content)
  if view.mode == "child" and type(view.childView) == "table" then
    drawChild(resources, view, view.childView --[[@as table<string, unknown>]])
    return
  end
  local graphics = assert(resources.graphics, "the battle render borrows its host graphics")
  local assets = assert(resources.assets, "the battle render borrows its asset holder")
  local text = assert(resources.text, "the battle render borrows its text services")
  local layout = content.layout --[[@as string]]
  if layout ~= "command" and layout ~= "moves" and layout ~= "target" then
    layout = "command"
  end
  local background = assets:drawable("menu:" .. layout)
  if background ~= nil then
    background:draw(graphics, 0, 0)
  end
  -- Multi-actor turns name the acting battler above the menu so staged
  -- choices are never mistaken for the previous entry's selection.
  local acting = actingName(view)
  if acting ~= nil then
    text.drawText(fitLabel(text, acting, 44), 128, 8)
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

---@param view table<string, unknown> internal semantic snapshot
---@return table<string, unknown>? first player-side battler facts in view order
---@return table<string, unknown>? first enemy-side battler facts in view order
local function singleSlots(view)
  -- The legacy singles projection: first record per side in view
  -- order, visibility decided by the caller. Untouched so single-side
  -- pictures never move with or without native slots.
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

---@param graphics table<string, unknown> injected host graphics
---@param assets table<string, unknown> injected asset holder
---@param view table<string, unknown> internal semantic snapshot
---@param spots table<integer, table<string, unknown>> compact sprite anchors keyed by native position
local function drawCompactSlots(graphics, assets, view, spots)
  local LogicalSurface = require("libs.ui.src.LogicalSurface")
  -- One sprite per declared slot, matched by the opaque native
  -- position in the plan's paint order. Hidden, benched and historic
  -- records own no slot; a missing portrait draws nothing under the
  -- existing pending path, never a fallback picture. Draw never
  -- mutates engine or cue state.
  local players, enemies = splitBattlers(view)
  local live = {}
  for _, battler in ipairs(players) do
    if type(battler.position) == "number" then
      assert(
        live[battler.position] == nil,
        "compact slot "
          .. tostring(battler.position)
          .. " is visibly claimed twice (combatant "
          .. tostring(battler.combatant)
          .. ")"
      )
      live[battler.position] = battler
    end
  end
  for _, battler in ipairs(enemies) do
    if type(battler.position) == "number" then
      assert(
        live[battler.position] == nil,
        "compact slot "
          .. tostring(battler.position)
          .. " is visibly claimed twice (combatant "
          .. tostring(battler.combatant)
          .. ")"
      )
      live[battler.position] = battler
    end
  end
  for _, spot in ipairs(spots) do
    local battler = live[spot.position]
    if battler ~= nil then
      local cell = battlerImage(assets, battler)
      if cell ~= nil then
        local dx = (type(battler.shakeDx) == "number" and battler.shakeDx or 0) --[[@as number]]
        local scale = assert(spot.scale, "compact doubles portraits carry their authored presentation scale")
        local allocation = { x = spot.x, y = spot.y, width = spot.width, height = spot.height }
        LogicalSurface.clip(graphics, allocation, function()
          local lease = cell.lease or cell
          if cell.quad ~= nil then
            lease:drawQuad(graphics, cell.quad, spot.x + dx * scale, spot.y, 0, scale, scale)
          else
            lease:draw(graphics, spot.x + dx * scale, spot.y, 0, scale, scale)
          end
        end)
      end
    end
  end
end

-- Draws one compact scene inside the single-pane viewport: the same
-- selected source scene with the battler pictures at the plan's compact
-- image centers, clipped to the compact scene viewport without scaling.
-- The plan may supply compact centers; without them the native centers
-- apply. The auxiliary selection arrow and party gauges stay hidden in
-- compact mode because the text cursor and Party action provide the
-- corresponding interaction. The compact HUD draws its own region wording
-- through the text services at the plan anchors; this scene path draws
-- images only, never text or bars.
---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
---@param content table<string, unknown> canonical plan content carrying the compact anchors
local function drawCompactScene(resources, view, content)
  local graphics = assert(resources.graphics, "the battle render borrows its host graphics")
  local assets = assert(resources.assets, "the battle render borrows its asset holder")
  local LogicalSurface = require("libs.ui.src.LogicalSurface")
  local viewport = content.scene
  if type(viewport) ~= "table" then
    viewport = { x = 0, y = 0, width = 256, height = 136 }
  end
  local playerCenter = content.playerCenter
  if type(playerCenter) ~= "table" then
    playerCenter = BattleRenderer.PLAYER_CENTER
  end
  local enemyCenter = content.enemyCenter
  if type(enemyCenter) ~= "table" then
    enemyCenter = BattleRenderer.ENEMY_CENTER
  end
  LogicalSurface.clip(graphics, viewport, function()
    local scene = assets:drawable(resources.sceneImageKey --[[@as string]])
    if scene ~= nil then
      scene:draw(graphics, 0, 0)
    end
    local spots = content.spriteCenters
    if type(spots) == "table" then
      drawCompactSlots(graphics, assets, view, spots --[[@as table<integer, table<string, unknown>>]])
    else
      local player, enemy = singleSlots(view)
      if enemy ~= nil and enemy.visible ~= false then
        local front = battlerImage(assets, enemy)
        if front ~= nil then
          local dx = (type(enemy.shakeDx) == "number" and enemy.shakeDx or 0) --[[@as number]]
          drawPortraitCell(graphics, front, enemyCenter.x + dx, enemyCenter.y)
        end
      end
      if player ~= nil and player.visible ~= false then
        local back = battlerImage(assets, player)
        if back ~= nil then
          local dx = (type(player.shakeDx) == "number" and player.shakeDx or 0) --[[@as number]]
          drawPortraitCell(graphics, back, playerCenter.x + dx, playerCenter.y)
        end
      end
    end
  end)
end

-- Draws one pane in its logical space: "detail" for the battlefield,
-- "interaction" for the lower menu, or "compact" for the single-pane
-- scene viewport. Unknown pane identities draw nothing.
---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
---@param paneId string resolved pane identity
---@param content table<string, unknown> canonical plan content carrying the layout
function BattleRenderer.drawPane(resources, view, paneId, content)
  assert(type(resources) == "table", "pane drawing borrows its resources")
  assert(type(view) == "table", "pane drawing reads its snapshot")
  if paneId == "compact" then
    drawCompactScene(resources, view, content or {})
  elseif paneId == "detail" then
    drawDetail(resources, view)
  elseif paneId == "interaction" then
    drawInteraction(resources, view, content or {})
  end
end

return BattleRenderer
