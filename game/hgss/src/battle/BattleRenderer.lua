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
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local BattleMenuPresenter = require("game.hgss.src.battle.BattleMenuPresenter")

-- Interim battler anchors on the native canvas: retained for layout
-- compatibility while native picture geometry lives in the visual
-- scene owner. The foe picture center is one row above this anchor;
-- the renderer never uses these values as picture origins.
BattleRenderer.PLAYER_CENTER = { x = 64, y = 112 }
BattleRenderer.ENEMY_CENTER = { x = 192, y = 56 }

-- Native HUD anchors and the player arrow offset beside the player
-- anchor, in native logical pixels. The enemy anchor is used unclamped:
-- its composite starts offscreen like the source layout.
BattleRenderer.PLAYER_HUD = { x = 192, y = 116 }
BattleRenderer.ENEMY_HUD = { x = 58, y = 36 }
BattleRenderer.ARROW_OFFSET = 72

-- The arrow and gauge families are source-sized 8-pixel tile rows. HUD
-- strips use the staged drawable's actual width because appended source
-- component tiles extend past the character-cell payload.
local STRIP_HEIGHT = 8
local ARROW_STRIP_WIDTH = 208

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

-- Dynamic content anchors inside the composite bounds, in native logical
-- pixels: the enemy box spans (-6,8)-(122,72), the player box
-- (128,84)-(256,148). Name, level, and numeric health keep their
-- established anchors; the condition rides beside the level and the bar
-- rows carry tile work. The player experience tile row sits beneath the
-- health numerals; the narration frame tiles cover rows 136 and below,
-- so nothing dynamic sits beneath the experience row.
-- Narration window: content origin with its size, wrapped by the
-- selected frame border.
local NARRATION_BOX = { x = 16, y = 152, width = 216, height = 32 }
local NARRATION_TEXT = { x = 24, y = 160 }

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

-- Semantic art roles associated with the four doubled source side types.
-- Coordinates, entry points, depth, and HUD anchors come from the
-- producer-published battlefield geometry.
local DOUBLES_ROWS = {
  player = {
    { sideType = 2, art = "hud:player-left" },
    { sideType = 4, art = "hud:player-right" },
  },
  enemy = {
    { sideType = 3, art = "hud:enemy-left" },
    { sideType = 5, art = "hud:enemy-right" },
  },
}

---@class BattleRenderer.SlotGeometry
---@field sideType integer normalized source slot identity
---@field settledX integer
---@field settledY integer
---@field entryX integer
---@field entryY integer
---@field depth integer source Pokepic Z
---@field hudX integer
---@field hudY integer
---@field hudPriority integer native OBJ priority
---@field hudBgPriority integer native BG priority
local function sourceSlotGeometry(view, sideType)
  local rows = view.slotGeometry --[[@as table<integer, BattleRenderer.SlotGeometry>]]
  for _, row in ipairs(rows) do
    if row.sideType == sideType then
      return row
    end
  end
  error("the published battle geometry contains side type " .. tostring(sideType), 0)
end

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
---@return table<string, unknown>? image handle for the displayed battler, nil while unavailable
local function battlerImage(assets, record)
  -- Each displayed battler draws its own exact canonical portrait:
  -- the selector rides the displayed record, so a switch rebinds the
  -- image at its reveal instead of reusing a side-role picture.
  -- A record without a canonical selector draws nothing: nil means
  -- unavailable, never a substitute picture.
  local selector = record.portraitSelector
  if type(selector) == "string" and selector ~= "" then
    local portrait = assets:drawable("mon:" .. selector)
    if portrait == nil then
      return nil
    end
    local frames = portrait.frames --[[@as table<integer, table<string, unknown>>?]]
    if type(frames) == "table" then
      local frame = record.pictureFrame
      if type(frame) ~= "number" then
        frame = 0
      end
      return assert(frames[frame + 1], "portrait animation selects a staged source frame")
    end
    return portrait
  end
  return nil
end

-- Pool leases pair the staged image with the shared sampler while owned
-- and test images draw directly. Resolves the measurable staged image
-- behind a drawable handle, or nil when the handle carries no pixels:
-- headless descriptors and bare test stand-ins stay drawable-shaped so
-- recording views prove without GPU uploads, while pool leases resolve
-- to their staged image for measurement.
---@param art table<string, unknown> resolved drawable handle under drawing
---@return table<string, unknown>|userdata|nil measurable staged image behind the handle
local function stagedPixelsOf(art)
  if type(art.getWidth) == "function" then
    return art
  end
  local inner = art.image or (art.lease and art.lease.image)
  if inner ~= nil and type(inner.getWidth) == "function" then
    return inner
  end
  return nil
end

-- Draws one resolved scene layer: pool leases resolve to their staged
-- image for the raw host draw while owned, test, and descriptor handles
-- draw as resolved.
---@param graphics table<string, unknown> injected host graphics
---@param scene table<string, unknown> resolved scene drawable under drawing
---@param scrollX number background horizontal scroll in native pixels
---@param scrollY number background vertical scroll in native pixels
local function drawSceneLayer(graphics, scene, scrollX, scrollY)
  local staged = stagedPixelsOf(scene)
  graphics.draw(staged == nil and scene or staged, 0 - scrollX, 0 - scrollY)
end

---@param art table<string, unknown> resolved drawable handle under drawing
---@return number? strip width in pixels, nil for pixel-less stand-ins
local function stripWidthOf(art)
  if type(art.getWidth) == "function" then
    return art:getWidth()
  end
  if type(art.width) ~= "number" then
    return nil
  end
  local inner = art.image or (art.lease and art.lease.image)
  if inner == nil or type(inner.getWidth) ~= "function" then
    return nil
  end
  return art.width
end

---@param art table<string, unknown> resolved drawable handle under drawing
---@return number? strip height in pixels, nil for pixel-less stand-ins
local function stripHeightOf(art)
  if type(art.getHeight) == "function" then
    return art:getHeight()
  end
  if type(art.height) ~= "number" then
    return nil
  end
  local inner = art.image or (art.lease and art.lease.image)
  if inner == nil or type(inner.getHeight) ~= "function" then
    return nil
  end
  return art.height
end

-- Resolves the drawable sampler behind one handle: the handle itself
-- when it samples (pool and test leases), else its admitted effect
-- lease, else nothing. Pool borrows keep their sampler on the outer
-- handle while the inner borrow token only pins the physical entry,
-- so outer-first resolution draws pool art instead of crashing on the
-- token; raw images and recording stand-ins sample nothing and draw
-- directly.
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

-- Draws one resolved handle with a caller viewport through the shared
-- sampler when it samples, directly otherwise. Extra placement
-- arguments forward to the draw call.
---@param graphics table<string, unknown> injected host graphics
---@param art table<string, unknown> resolved drawable handle under drawing
---@param quad table<string, unknown>? caller-owned viewport, nil for whole-image draws
---@param x number draw position x
---@param y number draw position y
---@param ... unknown extra placement arguments forwarded to the draw call
local function drawArtwork(graphics, art, quad, x, y, ...)
  local sampler = samplerOf(art)
  if sampler ~= nil then
    if quad ~= nil then
      sampler:drawQuad(graphics, quad, x, y, ...)
    else
      sampler:draw(graphics, x, y, ...)
    end
    return
  end
  if quad ~= nil then
    graphics.draw(art, quad, x, y, ...)
  else
    graphics.draw(art, x, y, ...)
  end
end

-- Neutral health-box wording through the borrowed text services: the
-- field palette triple when the service carries the generated font
-- definition, a neutral caller palette otherwise. Every health-box word
-- carries its palette; no wording draws palette-less.
---@param text table<string, unknown> borrowed text services
---@param content string wording under drawing
---@param x number horizontal origin under drawing
---@param y number vertical origin under drawing
local function hudText(text, content, x, y)
  local wording = tostring(content)
  if type(text.drawTextWithPalette) == "function" then
    local palette = nil
    local fontDef = text.fontDef --[[@as table<string, unknown>?]]
    if type(fontDef) == "table" and type(fontDef.palette) == "table" then
      local slots = fontDef.palette --[[@as table[] ]]
      local function channel(slot)
        local color = slots[slot]
        assert(type(color) == "table", "health-box wording reads its font palette slot")
        local r = assert(tonumber(color.r or color[1]), "font palette slots carry red") --[[@as number]]
        local g = assert(tonumber(color.g or color[2]), "font palette slots carry green") --[[@as number]]
        local b = assert(tonumber(color.b or color[3]), "font palette slots carry blue") --[[@as number]]
        if r > 1 or g > 1 or b > 1 then
          r, g, b = r / 255, g / 255, b / 255
        end
        return { r = r * 255, g = g * 255, b = b * 255 }
      end
      local ok, triple = pcall(function()
        return {
          foreground = channel(2),
          shadow = channel(3),
          background = channel(16),
        }
      end)
      if ok then
        palette = triple
      end
    end
    if palette == nil then
      palette = {
        foreground = { r = 255, g = 255, b = 255 },
        shadow = { r = 0, g = 0, b = 0 },
        background = { r = 0, g = 0, b = 0, a = 0 },
      }
    end
    text.drawTextWithPalette(wording, x, y, palette)
    return
  end
  text.drawText(wording, x, y)
end

---@param text table<string, unknown> borrowed text services
---@param role string source text role under drawing
---@param content string text under drawing
---@param x number horizontal origin under drawing
---@param y number vertical origin under drawing
---@param colors table<string, integer>? source palette slots for this text role
local function drawRoleText(text, role, content, x, y, colors)
  local draw = text.drawTextForRole --[[@as fun(role: string, content: string, x: number, y: number, colors: table<string, integer>?)?]]
  if draw ~= nil then
    draw(role, content, x, y, colors)
  else
    text.drawText(content, x, y)
  end
end

local function movePpColors(pp, maxPp)
  if pp == 0 then
    return { foreground = 7, shadow = 8, background = 0 }
  end
  if pp == maxPp then
    return { foreground = 1, shadow = 2, background = 0 }
  end
  if (maxPp <= 2 and pp == 1) or (maxPp <= 7 and pp == 1) then
    return { foreground = 5, shadow = 6, background = 0 }
  end
  if maxPp <= 7 then
    if pp == 2 then
      return { foreground = 3, shadow = 4, background = 0 }
    end
  else
    if pp <= maxPp / 4 then
      return { foreground = 5, shadow = 6, background = 0 }
    end
    if pp <= maxPp / 2 then
      return { foreground = 3, shadow = 4, background = 0 }
    end
  end
  return { foreground = 1, shadow = 2, background = 0 }
end

---@param text table<string, unknown> borrowed text services
---@param role string source text role under measurement
---@param content string text under measurement
---@return number measured width
local function measureRoleText(text, role, content)
  local measure = text.measureForRole --[[@as fun(role: string, content: string): table<string, number>?]]
  if measure ~= nil then
    return measure(role, content).width
  end
  return text.measure(content).width
end

---@param text table<string, unknown> borrowed text services
---@param content string label wording under truncation
---@param maxWidth number tile span width under truncation
---@return string label fitting its tile span
local function fitSpan(text, content, maxWidth)
  local label = tostring(content)
  if maxWidth > 0 then
    if type(text.measure) == "function" then
      while #label > 1 and text.measure(label).width > maxWidth do
        label = label:sub(1, #label - 1)
      end
    elseif type(text.textWidth) == "function" then
      while #label > 1 and text.textWidth(label) > maxWidth do
        label = label:sub(1, #label - 1)
      end
    elseif 8 * #label > maxWidth then
      label = label:sub(1, math.max(1, math.floor(maxWidth / 8)))
    end
  end
  return label
end

-- Draws one native bar row as tile work over the staged strip: each
-- 8-pixel tile samples the color base plus its 0..8 fill level, so the
-- selection and quantization follow the value with no painted
-- rectangles and no interim tints. Empty fills stay transparent like the
-- native patch, so only filled tiles draw. A missing strip draws
-- nothing.
---@param graphics table<string, unknown> injected host graphics
---@param assets table<string, unknown> injected asset holder
---@param artKey string staged strip identity under drawing
---@param anchor table<string, number> source HUD anchor under drawing
---@param objects table<integer, table<string, unknown>> source cell objects
---@param componentBase integer appended native component strip tile base, zero for bar tiles
---@param patches table<integer, { tile: integer, sourceTile: integer, fill?: integer }> source character-buffer patches
local function drawBarTiles(graphics, assets, artKey, anchor, objects, componentBase, patches)
  local art = assets:drawable(artKey)
  if art == nil then
    return
  end
  -- Headless descriptors and other pixel-less stand-ins carry no strip
  -- pixels: patch tiles stay missing exactly like an unstaged strip
  -- while anchors and wording still resolve.
  local stripWidth = stripWidthOf(art)
  local stripHeight = stripHeightOf(art)
  if stripWidth == nil or stripHeight == nil then
    return
  end
  for _, patch in ipairs(patches) do
    if patch.fill == nil or patch.fill > 0 then
      local quad = graphics.newQuad((componentBase + patch.sourceTile) * 8, 0, 8, 8, stripWidth, stripHeight)
      local found = false
      for _, obj in ipairs(objects) do
        if not obj.disabled then
          local columns = math.floor(obj.width / 8)
          local rows = math.floor(obj.height / 8)
          assert(columns > 0 and rows > 0, "source HUD objects contain character tiles")
          local tileOffset = patch.tile - obj.tile
          local tileCount = columns * rows
          if tileOffset >= 0 and tileOffset < tileCount then
            found = true
            drawArtwork(
              graphics,
              art,
              quad,
              anchor.x + obj.x + (tileOffset % columns) * 8,
              anchor.y + obj.y + math.floor(tileOffset / columns) * 8
            )
          end
        end
      end
      assert(found, "dynamic HUD tile " .. tostring(patch.tile) .. " belongs to a source NCER object")
    end
  end
end

local function gaugeTaskTiles(all, sideType, kind)
  all = all --[[@as table<integer, table<string, unknown>>?]]
  local bySide = all ~= nil and all[sideType] or nil
  return bySide ~= nil and bySide[kind] or nil
end

local function pictureRecord(records, battler, row)
  records[#records + 1] = { battler = battler, row = row, insertion = #records + 1 }
end

local function drawPicturePlanes(graphics, assets, view, players, enemies, singles)
  local records = {}
  if singles then
    local enemy, player = enemies[1], players[1]
    if enemy ~= nil then
      pictureRecord(records, enemy, sourceSlotGeometry(view, 1))
    end
    if player ~= nil then
      pictureRecord(records, player, sourceSlotGeometry(view, 0))
    end
  else
    local foeOrder = canonicalOrder(view, false)
    local allyOrder = canonicalOrder(view, true)
    for index, foe in ipairs(enemies) do
      local role = doublesRow(foeOrder, foe, index, DOUBLES_ROWS.enemy, "the sourced enemy rows cover every live foe")
      pictureRecord(records, foe, sourceSlotGeometry(view, role.sideType))
    end
    for index, ally in ipairs(players) do
      local role =
        doublesRow(allyOrder, ally, index, DOUBLES_ROWS.player, "the sourced player rows cover every live ally")
      pictureRecord(records, ally, sourceSlotGeometry(view, role.sideType))
    end
  end
  table.sort(records, function(left, right)
    local leftRow = left.row --[[@as BattleRenderer.SlotGeometry]]
    local rightRow = right.row --[[@as BattleRenderer.SlotGeometry]]
    if leftRow.depth ~= rightRow.depth then
      return leftRow.depth < rightRow.depth
    end
    return left.insertion < right.insertion
  end)
  local pictures = {}
  for _, record in ipairs(records) do
    local battler = record.battler --[[@as table<string, unknown>]]
    local row = record.row --[[@as BattleRenderer.SlotGeometry]]
    if battler.vanished ~= true and battler.dontDraw ~= true then
      local shadow
      local shadowSize = type(battler.shadowSize) == "number" and battler.shadowSize or 0
      if shadowSize ~= 0 and battler.shadowVisible ~= false and battler.pictureVisible ~= true then
        shadow = assets:drawable("shadow")
      end
      if shadow ~= nil then
        local entryDx = type(battler.entryDx) == "number" and battler.entryDx or 0
        local entryDy = type(battler.entryDy) == "number" and battler.entryDy or 0
        local pictureCenterX = row.settledX + entryDx + (type(battler.shakeDx) == "number" and battler.shakeDx or 0)
        local pictureCenterY = row.settledY
          - (type(battler.height) == "number" and battler.height or 0)
          - (type(battler.sourceHeight) == "number" and battler.sourceHeight or 0)
          + entryDy
        local shadowOffsetX = type(battler.shadowOffsetX) == "number" and battler.shadowOffsetX or 0
        local shadowOffsetY = type(battler.shadowOffsetY) == "number" and battler.shadowOffsetY or 0
        local shadowX = battler.shadowAdjustX == false
            and assert(type(battler.shadowX) == "number" and battler.shadowX, "fixed shadows carry their source X")
          or pictureCenterX
            + (type(battler.pictureXOffset) == "number" and battler.pictureXOffset or 0)
            + shadowOffsetX
        local shadowY = battler.shadowAdjustY == false
            and assert(type(battler.shadowY) == "number" and battler.shadowY, "fixed shadows carry their source Y")
          or pictureCenterY
            + (type(battler.pictureYOffset) == "number" and battler.pictureYOffset or 0)
            + shadowOffsetY
        pictures[#pictures + 1] = {
          kind = "shadow",
          image = shadow,
          centerX = shadowX,
          centerY = shadowY,
          zCenter = BattleScene.SHADOW_DEPTH,
          width = BattleScene.SHADOW_WIDTH,
          height = BattleScene.SHADOW_HEIGHT,
          textureRegion = assets:shadowRegion(shadowSize),
          shadowSize = shadowSize,
          shadowAffine = battler.shadowAffine ~= false,
          shadowOffsetX = type(battler.shadowOffsetX) == "number" and battler.shadowOffsetX or 0,
          shadowOffsetY = type(battler.shadowOffsetY) == "number" and battler.shadowOffsetY or 0,
          affineWidth = type(battler.affineWidth) == "number" and battler.affineWidth or 0x100,
          affineHeight = type(battler.affineHeight) == "number" and battler.affineHeight or 0x100,
          tintR = battler.shadowTint ~= nil and battler.shadowTint.r or 1,
          tintG = battler.shadowTint ~= nil and battler.shadowTint.g or 1,
          tintB = battler.shadowTint ~= nil and battler.shadowTint.b or 1,
          alpha = (type(battler.polygonAlpha) == "number" and battler.polygonAlpha or 31) / 31,
          paletteFade = battler.paletteFade,
        }
      end
      -- The Substitute doll is a transient native animation picture. The
      -- scene hides the replaced mon; the animation owner supplies the
      -- doll through its effect instance.
      -- The GPU picture pass consumes staged image handles: leases and
      -- wrappers resolve to their staged image while headless descriptors
      -- and other pixel-less stand-ins never reach the isolated depth target.
      local image = battler.substitute ~= true and battlerImage(assets, battler) or nil
      if image ~= nil then
        if type(image) ~= "table" then
          -- Host images draw directly.
        else
          local staged = image.image or (image.lease and image.lease.image) or image
          if type(staged.getDimensions) ~= "function" then
            image = nil
          else
            image = staged
          end
        end
      end
      if image ~= nil then
        local sourceHeight = (type(battler.height) == "number" and battler.height or 0)
          + (type(battler.sourceHeight) == "number" and battler.sourceHeight or 0)
        local tint = battler.pictureTint --[[@as table<string, number>?]]
        local scaleX = type(battler.scaleX) == "number" and battler.scaleX or 1
        local scaleY = type(battler.scaleY) == "number" and battler.scaleY or 1
        if battler.affineMode == true then
          scaleX = scaleX
            * assert(
              type(battler.affineWidth) == "number" and battler.affineWidth,
              "affine pictures carry native width"
            )
            / 0x100
          scaleY = scaleY
            * assert(
              type(battler.affineHeight) == "number" and battler.affineHeight,
              "affine pictures carry native height"
            )
            / 0x100
        end
        local alpha = (type(battler.polygonAlpha) == "number" and battler.polygonAlpha or 31) / 31
        local pictureVisible = battler.pictureVisible == true
        pictures[#pictures + 1] = {
          image = image,
          centerX = row.settledX + (type(battler.entryDx) == "number" and battler.entryDx or 0) + (type(
            battler.shakeDx
          ) == "number" and battler.shakeDx or 0),
          centerY = row.settledY - sourceHeight + (type(battler.entryDy) == "number" and battler.entryDy or 0),
          zCenter = row.depth,
          zOffset = type(battler.zOffset) == "number" and battler.zOffset or 0,
          xOffset = type(battler.pictureXOffset) == "number" and battler.pictureXOffset or 0,
          yOffset = type(battler.pictureYOffset) == "number" and battler.pictureYOffset or 0,
          xOffset2 = type(battler.pictureXOffset2) == "number" and battler.pictureXOffset2 or 0,
          yOffset2 = type(battler.pictureYOffset2) == "number" and battler.pictureYOffset2 or 0,
          pictureVisible = pictureVisible,
          shadowHeight = type(battler.shadowHeight) == "number" and battler.shadowHeight or 0,
          pivotX = type(battler.pivotX) == "number" and battler.pivotX or 0,
          pivotY = type(battler.pivotY) == "number" and battler.pivotY or 0,
          width = pictureVisible and (type(battler.pictureWidth) == "number" and battler.pictureWidth or 80)
            or 80 * scaleX,
          height = pictureVisible and (type(battler.pictureHeight) == "number" and battler.pictureHeight or 80)
            or 80 * scaleY,
          rotationX = battler.rotationX,
          rotationY = battler.rotationY,
          rotationZ = battler.rotationZ,
          rotation = battler.rotation,
          tintR = tint ~= nil and tint.r or 1,
          tintG = tint ~= nil and tint.g or 1,
          tintB = tint ~= nil and tint.b or 1,
          alpha = alpha * (tint ~= nil and tint.a or 1),
          paletteFade = battler.paletteFade,
        }
      end
    end
  end
  for _, effect in ipairs(assert(view.effectInstances, "battle snapshots carry transient effect instances")) do
    local picture = effect.picture --[[@as table<string, unknown>?]]
    if picture ~= nil then
      local assetKey = assert(picture.assetKey, "transient pictures carry their staged drawable key")
      local image = assert(assets:drawable(assetKey), "transient effect drawables are staged before submission")
      -- Source cell bands crop their staged tile strip through an exact
      -- pixel origin; whole-image pictures omit the origin and flips.
      local hasCrop = picture.xOffset2 ~= nil or picture.yOffset2 ~= nil
      pictures[#pictures + 1] = {
        kind = "effect",
        image = image,
        centerX = assert(picture.centerX, "transient pictures carry native X"),
        centerY = assert(picture.centerY, "transient pictures carry native Y"),
        zCenter = assert(picture.zCenter, "transient pictures carry native depth"),
        width = assert(picture.width, "transient pictures carry native width"),
        height = assert(picture.height, "transient pictures carry native height"),
        alpha = assert(picture.alpha, "transient pictures carry polygon alpha"),
        rotationX = picture.rotationX,
        rotationY = picture.rotationY,
        rotationZ = picture.rotationZ,
        tintR = picture.tintR or 1,
        tintG = picture.tintG or 1,
        tintB = picture.tintB or 1,
        paletteFade = picture.paletteFade,
        pictureVisible = hasCrop,
        xOffset2 = picture.xOffset2,
        yOffset2 = picture.yOffset2,
        flipH = picture.flipH,
        flipV = picture.flipV,
      }
    end
  end
  if #pictures > 0 then
    local layer = assets:renderPictures(graphics, pictures)
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(layer, 0, 0)
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
    -- Leases draw through the shared sampler so indexed pixels resolve
    -- exactly and records carry staged identity; owned, test, and
    -- descriptor handles draw directly, which records them in headless
    -- composition.
    local lease = samplerOf(image)
    if lease ~= nil then
      lease:drawQuad(graphics, quad, baseX + obj.x --[[@as number]], baseY + obj.y --[[@as number]] + row * 8)
    else
      graphics.draw(image, quad, baseX + obj.x --[[@as number]], baseY + obj.y --[[@as number]] + row * 8)
    end
  end
end

-- Draws one authored HUD composite at its anchor with the compiled local
-- offsets. A missing strip draws nothing, never a substitute.
---@param graphics table<string, unknown> injected host graphics
---@param assets table<string, unknown> injected asset holder
---@param artKey string staged strip identity under drawing
---@param anchor table<string, number> composite anchor under drawing
---@param objects table<integer, table<string, unknown>> staged source cell objects
local function drawHudComposite(graphics, assets, artKey, anchor, objects)
  local art = assets:drawable(artKey)
  if art == nil then
    return
  end
  -- Headless descriptors and other pixel-less stand-ins carry no strip
  -- pixels: the composite stays missing exactly like an unstaged strip
  -- while anchors and wording still resolve.
  local stripWidth = stripWidthOf(art)
  if stripWidth == nil then
    return
  end
  for _, obj in ipairs(objects) do
    drawSpriteObject(
      graphics,
      art --[[@as table<string, unknown>]],
      stripWidth --[[@as integer]],
      anchor.x,
      anchor.y,
      obj
    )
  end
end

---@param section table<string, unknown> staged HUD sprite section
---@return table<string, unknown> opening cell selected by the source animation
local function openingHudCell(section)
  local animation = assert(section.animation, "a staged HUD section carries its source animation")
  local firstFrame = assert(animation.frames[1], "a staged HUD animation carries its opening frame")
  return assert(section.cells[firstFrame.cell + 1], "a staged HUD animation selects a source cell")
end

---@param anchor table<string, number> source HUD anchor under drawing
---@param objects table<integer, table<string, unknown>> source cell objects under reading
---@param tile integer normalized source character tile
---@return number, number tile screen origin
local function hudTileOrigin(anchor, objects, tile)
  for _, obj in ipairs(objects) do
    if not obj.disabled then
      local columns = math.floor(obj.width / 8)
      local rows = math.floor(obj.height / 8)
      local offset = tile - obj.tile
      if offset >= 0 and offset < columns * rows then
        return anchor.x + obj.x + (offset % columns) * 8, anchor.y + obj.y + math.floor(offset / columns) * 8
      end
    end
  end
  error("native HUD number tile belongs to a source cell object", 0)
end

---@param text table<string, unknown> borrowed text services
---@param anchor table<string, number> source HUD anchor under drawing
---@param objects table<integer, table<string, unknown>> source cell objects under reading
---@param patches table<string, table<integer, { tile: integer }>> current/max native glyph spans
---@param hp integer displayed current HP
---@param maxHp integer displayed maximum HP
---@param graphics table<string, unknown> injected host graphics
local function drawHpNumbers(graphics, text, anchor, objects, patches, hp, maxHp)
  local current = tostring(hp)
  local maximum = tostring(maxHp)
  local currentX, currentY = hudTileOrigin(anchor, objects, patches.current[1].tile)
  local maximumX, maximumY = hudTileOrigin(anchor, objects, patches.maximum[1].tile)
  local currentLabel = fitSpan(text, current, 24)
  local maximumLabel = fitSpan(text, maximum, 24)
  local function width(value)
    if type(text.measure) == "function" then
      return text.measure(value).width
    elseif type(text.textWidth) == "function" then
      return text.textWidth(value)
    end
    return #value * 8
  end
  LogicalSurface.clip(graphics, { x = currentX, y = currentY, width = 24, height = 8 }, function()
    hudText(text, currentLabel, currentX + 24 - width(currentLabel), currentY)
  end)
  LogicalSurface.clip(graphics, { x = maximumX, y = maximumY, width = 24, height = 8 }, function()
    hudText(text, maximumLabel, maximumX, maximumY)
  end)
end

-- OAM priority is back-to-front in a painter, with the source object index
-- retaining the native tie order. Copy the records so staged cell arrays stay immutable.
---@param objects table<integer, table<string, unknown>> source cell objects
---@return table<integer, table<string, unknown>> objects ordered back to front
local function objectsByPriority(objects)
  local ordered = {}
  for index, object in ipairs(objects) do
    ordered[#ordered + 1] = { index = index, object = object }
  end
  table.sort(ordered, function(left, right)
    local leftObject = left.object --[[@as table<string, unknown>]]
    local rightObject = right.object --[[@as table<string, unknown>]]
    local leftPriority = assert(leftObject.priority, "staged cell objects carry native priority") --[[@as integer]]
    local rightPriority = assert(rightObject.priority, "staged cell objects carry native priority") --[[@as integer]]
    if leftPriority ~= rightPriority then
      return leftPriority > rightPriority
    end
    local leftIndex = left.index --[[@as integer]]
    local rightIndex = right.index --[[@as integer]]
    return leftIndex < rightIndex
  end)
  local result = {}
  for _, entry in ipairs(ordered) do
    result[#result + 1] = entry.object --[[@as table<string, unknown>]]
  end
  return result
end

-- Draws the opening cell of a staged native doubles HUD at its template
-- anchor. The source compiler normalizes cell-bank tile bases into staged
-- strip indices while preserving the existing cell shape.
---@param graphics table<string, unknown> injected host graphics
---@param assets table<string, unknown> injected asset holder
---@param sections table<string, unknown> staged role sections
---@param artKey string semantic doubles HUD image key
---@param anchor table<string, number> native sprite template anchor
---@return table<string, unknown>? selected source cell, absent without its staged drawable
---@return table<string, unknown> source section owning the selected cell
local function drawDoublesHudCell(graphics, assets, sections, artKey, anchor)
  local sectionKey = assert(DOUBLES_HUD_SECTIONS[artKey], "doubles HUD rows name a source section")
  local section = assert(sections[sectionKey], "the doubled battle manifest carries " .. sectionKey)
  local cell = openingHudCell(section)
  local art = assets:drawable(artKey)
  if art == nil then
    return nil, section
  end
  -- Headless descriptors and other pixel-less stand-ins carry no strip
  -- pixels: the HUD cell stays missing exactly like an unstaged strip
  -- while field bounds and wording still resolve.
  if stripWidthOf(art) == nil then
    return nil, section
  end
  for index, obj in ipairs(objectsByPriority(cell.objs)) do
    local context = sectionKey .. " source object " .. tostring(index)
    assert(not obj.affine, context .. " uses unsupported affine drawing")
    assert(not obj.flipH and not obj.flipV, context .. " uses unsupported object flipping")
    assert(obj.palette == 0, context .. " selects the staged role palette")
    assert(not obj.mosaic and obj.objMode == "normal", context .. " uses unsupported object display flags")
    assert(obj.colorMode == "16-color", context .. " uses unsupported color depth")
    if not obj.disabled then
      drawSpriteObject(
        graphics,
        art,
        assert(stripWidthOf(art), "doubled HUD strips carry their native width") --[[@as integer]],
        anchor.x,
        anchor.y,
        obj
      )
    end
  end
  return cell, section
end

---@param graphics table<string, unknown> injected host graphics
---@param text table<string, unknown> borrowed text services
---@param assets table<string, unknown> injected asset holder
---@param sections table<string, unknown> staged role sections
---@param view table<string, unknown> internal semantic snapshot carrying claimed slots
---@param players table<integer, table<string, unknown>> live player-side battler facts in slot order
---@param enemies table<integer, table<string, unknown>> live enemy-side battler facts in slot order
local function drawDoublesDetail(graphics, text, assets, sections, view, players, enemies)
  -- Every live slot paints its HUD at its canonical sourced row; picture
  -- planes were already submitted by depth before this OBJ pass.
  checkDoublesSlots(players, enemies)
  local foeOrder = canonicalOrder(view, false)
  local allyOrder = canonicalOrder(view, true)
  -- Build one ordered native HUD pass. Its template draw priority is
  -- distinct from the battler's Pokepic depth and the BG priority.
  local hudRecords = {}
  for index, foe in ipairs(enemies) do
    local role = doublesRow(foeOrder, foe, index, DOUBLES_ROWS.enemy, "the sourced enemy rows cover every live foe")
    hudRecords[#hudRecords + 1] = {
      battler = foe,
      row = sourceSlotGeometry(view, role.sideType),
      art = role.art,
      insertion = #hudRecords + 1,
    }
  end
  for index, ally in ipairs(players) do
    local role =
      doublesRow(allyOrder, ally, index, DOUBLES_ROWS.player, "the sourced player rows cover every live ally")
    hudRecords[#hudRecords + 1] = {
      battler = ally,
      row = sourceSlotGeometry(view, role.sideType),
      art = role.art,
      insertion = #hudRecords + 1,
    }
  end
  table.sort(hudRecords, function(left, right)
    local leftRow = left.row --[[@as BattleRenderer.SlotGeometry]]
    local rightRow = right.row --[[@as BattleRenderer.SlotGeometry]]
    local leftPriority = assert(leftRow.hudPriority, "published slot geometry carries HUD OBJ priority") --[[@as integer]]
    local rightPriority = assert(rightRow.hudPriority, "published slot geometry carries HUD OBJ priority") --[[@as integer]]
    if leftPriority ~= rightPriority then
      return leftPriority > rightPriority
    end
    local leftInsertion = left.insertion --[[@as integer]]
    local rightInsertion = right.insertion --[[@as integer]]
    return leftInsertion < rightInsertion
  end)
  for _, record in ipairs(hudRecords) do
    local row = record.row --[[@as BattleRenderer.SlotGeometry]]
    local art = record.art --[[@as string]]
    local cell, section = drawDoublesHudCell(graphics, assets, sections, art, { x = row.hudX, y = row.hudY })
    local battler = record.battler --[[@as table<string, unknown>]]
    local componentBase = assert(section.componentBase, "doubled HUD strips publish their native component tile base")
    if cell ~= nil then
      local patchSpans = assert(view.hudPatchSpans, "battle manifest carries source HUD patch spans")
      local playerMode = battler.side == 1 and (battler.healthBoxMode or "gauge") or nil
      if playerMode ~= nil then
        drawBarTiles(
          graphics,
          assets,
          art,
          { x = row.hudX, y = row.hudY },
          cell.objs,
          componentBase,
          BattleScene.healthBoxModePatchTiles(patchSpans, row.sideType, playerMode)
        )
      end
      if playerMode ~= "numbers" then
        local patches = gaugeTaskTiles(view.gaugePatchTiles, row.sideType, "health")
          or BattleScene.hpPatchTiles(patchSpans, row.sideType, battler.hp, battler.maxHp)
        -- Bar patches name component-relative source tiles like the
        -- icons below, so they ride the same staged component base.
        drawBarTiles(graphics, assets, art, { x = row.hudX, y = row.hudY }, cell.objs, componentBase, patches)
      end
      local caught = nil
      if view.battleKind == "wild" and battler.side == 2 then
        caught = battler.caught
      end
      local iconPatches =
        BattleScene.hudIconPatchTiles(patchSpans, row.sideType, battler.condition, battler.gender, caught)
      drawBarTiles(graphics, assets, art, { x = row.hudX, y = row.hudY }, cell.objs, componentBase, iconPatches)
    end
    record.cell = cell
  end
  for _, record in ipairs(hudRecords) do
    local battler = record.battler --[[@as table<string, unknown>]]
    local row = record.row --[[@as BattleRenderer.SlotGeometry]]
    local art = record.art --[[@as string]]
    local fields = assert(DOUBLES_FIELDS[art], "doubled HUD rows carry field bounds")
    local name = battler.side == 1 and "LEAD" or "FOE"
    hudText(text, fitSpan(text, tostring(battler.name or name), 72), fields.name.x, fields.name.y)
    if type(battler.level) == "number" then
      hudText(text, "Lv" .. tostring(battler.level), fields.level.x, fields.level.y)
    end
    if battler.side == 1 and battler.healthBoxMode == "numbers" and record.cell ~= nil then
      local numberPatches = BattleScene.hpNumberPatchTiles(
        assert(view.hudPatchSpans, "battle manifest carries source HUD patch spans"),
        row.sideType
      )
      drawHpNumbers(
        graphics,
        text,
        { x = row.hudX, y = row.hudY },
        record.cell.objs,
        numberPatches,
        assert(battler.hp, "player health boxes carry displayed HP"),
        assert(battler.maxHp, "player health boxes carry maximum HP")
      )
    end
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
  local sourceRow = sourceSlotGeometry(view, row.sideType)
  return sourceRow.hudX - BattleRenderer.ARROW_OFFSET, sourceRow.hudY
end

---@param view table<string, unknown> internal semantic snapshot
---@return number horizontal background scroll in native pixels
---@return number vertical background scroll in native pixels
local function bgScrollOf(view)
  local scroll = view.bgScroll --[[@as table<string, unknown>?]]
  if type(scroll) ~= "table" then
    return 0, 0
  end
  local x, y = scroll.x, scroll.y
  if type(x) ~= "number" then
    x = 0
  end
  if type(y) ~= "number" then
    y = 0
  end
  return x, --[[@as number]]
    y --[[@as number]]
end

-- Draws one single-battle health box: the staged cell composite, the
-- native bar tile row, and the palette-aware name, level, condition
-- and health facts inside the tile spans. The foe box hides its
-- private health facts and carries no experience row; the player box
-- keeps its numeric health and draws its experience tile row.
---@param graphics table<string, unknown> injected host graphics
---@param text table<string, unknown> borrowed text services
---@param assets table<string, unknown> injected asset holder
---@param battler table<string, unknown> displayed battler facts under drawing
---@param artKey string staged strip identity under drawing
---@param anchor table<string, number> composite anchor under drawing
---@param section table<string, unknown> staged source HUD section under drawing
---@param nameX number name row horizontal origin under drawing
---@param nameY number name row vertical origin under drawing
---@param levelY number level row vertical origin under drawing
---@param playerBox boolean true for the player box with numerals and experience
---@param sideType integer source HUD side type
---@param patchSpans table<string, unknown> normalized source HUD patch spans
---@param gaugePatchTiles table<string, unknown>? active source task tile writes
---@param battleKind string battle encounter kind controlling the caught marker
---@param textPass boolean true during the separate health-box wording pass
local function drawSingleHud(
  graphics,
  text,
  assets,
  battler,
  artKey,
  anchor,
  section,
  nameX,
  nameY,
  levelY,
  playerBox,
  sideType,
  patchSpans,
  gaugePatchTiles,
  battleKind,
  textPass
)
  if not textPass then
    local cell = openingHudCell(section)
    local objects = cell.objs --[[@as table<integer, table<string, unknown>>]]
    drawHudComposite(graphics, assets, artKey, anchor, objects)
    local componentBase = assert(section.componentBase, "single HUD strips publish their native component tile base")
    local healthPatches = gaugeTaskTiles(gaugePatchTiles, sideType, "health")
      or BattleScene.hpPatchTiles(patchSpans, sideType, battler.hp, battler.maxHp)
    -- Bar patches name component-relative source tiles like the icon
    -- patches below, so they ride the same staged component base.
    drawBarTiles(graphics, assets, artKey, anchor, objects, componentBase, healthPatches)
    local caught = nil
    if not playerBox and battleKind == "wild" then
      caught = battler.caught
    end
    drawBarTiles(
      graphics,
      assets,
      artKey,
      anchor,
      objects,
      componentBase,
      BattleScene.hudIconPatchTiles(patchSpans, sideType, battler.condition, battler.gender, caught)
    )
    if playerBox then
      local into = battler.expInto
      local span = battler.expSpan
      if type(battler.level) == "number" and battler.level >= 100 then
        into, span = 0, 0
      end
      drawBarTiles(
        graphics,
        assets,
        artKey,
        anchor,
        objects,
        componentBase,
        gaugeTaskTiles(gaugePatchTiles, sideType, "experience")
          or BattleScene.expPatchTiles(patchSpans, BattleScene.expTileFills(into, span))
      )
    end
    return
  end
  local name = fitSpan(text, tostring(battler.name or (playerBox and "LEAD" or "FOE")), 88)
  hudText(text, name, nameX, nameY)
  if type(battler.level) == "number" then
    hudText(text, "Lv" .. tostring(battler.level), nameX, levelY)
  end
  if playerBox then
    local numberPatches = BattleScene.hpNumberPatchTiles(patchSpans, sideType)
    drawHpNumbers(
      graphics,
      text,
      anchor,
      openingHudCell(section).objs,
      numberPatches,
      assert(battler.hp, "player health boxes carry displayed HP"),
      assert(battler.maxHp, "player health boxes carry maximum HP")
    )
  end
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
local function drawDetail(resources, view)
  local graphics = assert(resources.graphics, "the battle render borrows its host graphics")
  local text = assert(resources.text, "the battle render borrows its text services")
  local windows = assert(resources.windows, "the battle render borrows its window services")
  local assets = assert(resources.assets, "the battle render borrows its asset holder")
  local doublesHud = resources.doublesHud --[[@as table<string, unknown>?]]
  -- The battlefield draws under the neutral image tint however hostile
  -- the incoming graphics state is; the borrowed color returns on every
  -- path below.
  local r, g, b, a = saveColor(graphics)
  graphics.setColor(1, 1, 1, 1)
  -- The background layer honors the viewport scroll on its own decoded
  -- layer; portraits and health boxes stay layer-independent.
  local scrollX, scrollY = bgScrollOf(view)
  local scene = nil
  local backgroundFailure = nil
  if type(view.backgroundRaster) == "table" and type(assets.background) == "function" then
    scene, backgroundFailure = assets:background(view.backgroundRaster --[[@as table<string, unknown>]])
  end
  if scene == nil and backgroundFailure == nil then
    scene = assets:drawable(resources.sceneImageKey --[[@as string]])
  end
  if scene ~= nil then
    drawSceneLayer(graphics, scene, scrollX, scrollY)
  end
  local players, enemies = splitBattlers(view)
  local singles = not doublesFormat(view, players, enemies)
  drawPicturePlanes(graphics, assets, view, players, enemies, singles)
  local player = singles and players[1] or nil
  local enemy = singles and enemies[1] or nil
  -- The arrow OBJ uses priority 0x11, behind the source HP box OBJ range.
  if view.mode == "command" or view.mode == "moves" or view.mode == "target" then
    local cell = view.arrowFrame --[[@as integer?]]
    if type(cell) == "number" and cell >= 1 and cell <= #ARROW_CELLS - 1 then
      local art = assets:drawable("arrow")
      if art ~= nil then
        local baseX, baseY
        if singles then
          local row = sourceSlotGeometry(view, 0)
          baseX = row.hudX - BattleRenderer.ARROW_OFFSET
          baseY = row.hudY - 2
        else
          baseX, baseY = doublesArrowBase(view, players)
        end
        for _, obj in ipairs(ARROW_CELLS[cell + 1]) do
          drawSpriteObject(graphics, art --[[@as table<string, unknown>]], ARROW_STRIP_WIDTH, baseX, baseY, obj)
        end
      end
    end
  end
  if singles then
    local patchSpans = assert(view.hudPatchSpans, "battle manifest carries source HUD patch spans")
    for _, pass in ipairs({ false, true }) do
      if enemy ~= nil then
        local row = sourceSlotGeometry(view, 1)
        drawSingleHud(
          graphics,
          text,
          assets,
          enemy,
          "hud:enemy",
          { x = row.hudX, y = row.hudY },
          assert(view.hudSections, "the battle view carries staged single HUD cells").enemy,
          8,
          16,
          28,
          false,
          row.sideType,
          patchSpans,
          view.gaugePatchTiles,
          view.battleKind,
          pass
        )
      end
      if player ~= nil then
        local row = sourceSlotGeometry(view, 0)
        drawSingleHud(
          graphics,
          text,
          assets,
          player,
          "hud:player",
          { x = row.hudX, y = row.hudY },
          assert(view.hudSections, "the battle view carries staged single HUD cells").player,
          144,
          92,
          104,
          true,
          row.sideType,
          patchSpans,
          view.gaugePatchTiles,
          view.battleKind,
          pass
        )
      end
    end
  else
    drawDoublesDetail(
      graphics,
      text,
      assets,
      assert(doublesHud, "the doubled battle render borrows its verified HUD sections"),
      view,
      players,
      enemies
    )
  end
  if type(view.message) == "string" and view.message ~= "" then
    windows.drawWindow(NARRATION_BOX, resources.frameKey, { 0, 0, 0, 0 })
    LogicalSurface.clip(graphics, {
      x = NARRATION_BOX.x + 8,
      y = NARRATION_BOX.y + 8,
      width = NARRATION_BOX.width - 16,
      height = NARRATION_BOX.height - 16,
    }, function()
      drawRoleText(
        text,
        "narration",
        view.message --[[@as string]],
        NARRATION_TEXT.x,
        NARRATION_TEXT.y,
        { foreground = 1, shadow = 2, background = 0 }
      )
    end)
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
---@param role string? source text role under truncation
---@return string label fitting its region
local function fitLabel(text, content, maxWidth, role)
  local label = tostring(content)
  if (type(text.measureForRole) == "function" or type(text.measure) == "function") and maxWidth > 0 then
    while #label > 1 and measureRoleText(text, role or "menu", label) > maxWidth do
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
        drawArtwork(graphics, art, nil, box.x --[[@as number]] + shift, box.y --[[@as number]] + shift)
      end
      if layout == "command" and COMMAND_ANCHORS[id] ~= nil then
        local anchor = COMMAND_ANCHORS[id]
        local entry = commandsById[id]
        local enabled = entry == nil or entry.enabled ~= false
        if enabled or id == "fight" or id == "bag" or id == "pokemon" then
          local labelY = pressed and id == "fight" and layout == "command" and anchor.y - 2 or anchor.y
          local commandColors = id == "fight" and { foreground = 1, shadow = 2, background = 3 }
            or id == "bag" and { foreground = 4, shadow = 5, background = 6 }
            or id == "pokemon" and { foreground = 7, shadow = 8, background = 9 }
            or { foreground = 10, shadow = 11, background = 12 }
          drawRoleText(text, "menu", COMMAND_LABELS[id] or id, anchor.x + shift, labelY, commandColors)
        else
          drawRoleText(
            text,
            "menu",
            fitLabel(text, COMMAND_LABELS[id] or id, box.w --[[@as number]], "menu"),
            anchor.x,
            anchor.y,
            { foreground = 10, shadow = 11, background = 12 }
          )
        end
      elseif slot ~= nil then
        local slotIndex = tonumber(slot) --[[@as integer]]
        local move = movesBySlot[slotIndex]
        local anchor = MOVE_ANCHORS[slotIndex + 1]
        local typeAnchor = TYPE_ANCHORS[slotIndex + 1]
        local ppCurrent = PP_CURRENT_ANCHORS[slotIndex + 1]
        local ppMax = PP_MAX_ANCHORS[slotIndex + 1]
        if move ~= nil and anchor ~= nil and move.name ~= nil then
          drawRoleText(
            text,
            "menu",
            fitLabel(text, move.name --[[@as string]], 120, "menu"),
            anchor.x + shift,
            anchor.y + shift,
            { foreground = 7, shadow = 8, background = 9 }
          )
          if ppCurrent ~= nil and ppMax ~= nil then
            local ppColors = movePpColors(move.pp, move.maxPp)
            drawRoleText(text, "menu", tostring(move.pp), ppCurrent.x + shift, ppCurrent.y + shift, ppColors)
            drawRoleText(text, "menu", "/" .. tostring(move.maxPp), ppMax.x + shift, ppMax.y + shift, ppColors)
          end
          if type(move.moveType) == "string" and typeAnchor ~= nil then
            local icon = assets:drawable("battle:move-type-icon:" .. move.moveType:lower())
            if icon ~= nil then
              local iconWidth, iconHeight
              if type(icon.getDimensions) == "function" then
                iconWidth, iconHeight = icon:getDimensions()
              else
                iconWidth, iconHeight = icon.width, icon.height
              end
              assert(
                type(iconWidth) == "number" and type(iconHeight) == "number",
                "move-type icons carry measurable extents"
              )
              drawArtwork(
                graphics,
                icon,
                nil,
                typeAnchor.x + shift - math.floor(iconWidth / 2),
                typeAnchor.y + shift - math.floor(iconHeight / 2)
              )
            end
          end
        end
      elseif id == "cancel" then
        drawRoleText(
          text,
          "menu",
          "CANCEL",
          CANCEL_ANCHOR.x + shift,
          CANCEL_ANCHOR.y + shift,
          { foreground = 10, shadow = 11, background = 12 }
        )
      elseif id:match("^target:") ~= nil then
        -- Target rows name their projected candidate with the focus
        -- marker, so the chosen foe never depends on sprite order.
        local name = targetName(view, id) or id
        if view.selection == id then
          name = "> " .. name
        end
        drawRoleText(
          text,
          "menu",
          fitLabel(text, name, box.w --[[@as number]], "menu"),
          box.x --[[@as number]] + shift,
          box.y --[[@as number]] + shift,
          (id == "target:0" or id == "target:2") and { foreground = 4, shadow = 5, background = 6 }
            or { foreground = 1, shadow = 2, background = 3 }
        )
      end
    end
  end
  restoreColor(graphics, r, g, b, a)
end

-- Draws one party gauge cell from its source family and NCER cell.
---@param graphics table<string, unknown> injected host graphics
---@param image table<string, unknown> staged gauge strip handle under drawing
---@param family table<string, unknown> source family carrying cell geometry
---@param slotX number slot horizontal origin under drawing
---@param slotY number slot vertical origin under drawing
---@param state integer roster visibility state under drawing: 0 absent, 1 present, 2 fainted
local function drawGaugeCell(graphics, image, family, slotX, slotY, state)
  local cells = assert(family.cells, "a staged party gauge carries source NCER cells") --[[@as table[] ]]
  local cell = assert(cells[state + 1], "a staged party gauge has a source cell for each roster state")
  -- Headless descriptors and other pixel-less stand-ins carry no strip
  -- pixels: gauge cells stay missing exactly like an unstaged strip.
  local stripWidth = stripWidthOf(image)
  if stripWidth == nil then
    return
  end
  for _, object in ipairs(cell.objs) do
    drawSpriteObject(graphics, image, stripWidth --[[@as integer]], slotX, slotY, object)
  end
end

-- Draws both party rows from their native source families by roster
-- visibility: the committed battle roster behind the player row, the
-- revealed active-foe count behind the enemy row. Unrevealed foes keep
-- the absent cell, so no unrevealed species ever shows. A missing strip
-- draws nothing, never a substitute.
---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
local function drawGauges(resources, view)
  local graphics = assert(resources.graphics, "the battle render borrows its host graphics")
  local assets = assert(resources.assets, "the battle render borrows its asset holder")
  local families = assert(view.gaugeFamilies, "the battle view carries detached source gauge families")
  local roster = {}
  if type(view.partyRoster) == "table" then
    roster = view.partyRoster --[[@as table[] ]]
  end
  local playerArt = assets:drawable("gauges:player")
  local playerFamily = assert(families.player, "the battle view carries the player gauge family")
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
        playerFamily,
        GAUGE_PLAYER_X + GAUGE_PLAYER_PITCH * index,
        GAUGE_PLAYER_Y,
        state
      )
    end
  end
  local enemyArt = assets:drawable("gauges:enemy")
  local enemyFamily = assert(families.enemy, "the battle view carries the opponent gauge family")
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
        enemyFamily,
        GAUGE_ENEMY_RIGHT - GAUGE_ENEMY_PITCH * index,
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
---@param child table<string, unknown> confirmed learning child view with source labels
local function drawTwoOptionConfirmation(resources, view, child)
  local graphics = assert(resources.graphics, "the battle render borrows its host graphics")
  local assets = assert(resources.assets, "the battle render borrows its asset holder")
  local text = assert(resources.text, "the battle render borrows its text services")
  local menuLayers = assert(view.menuLayers, "the battle view carries generated menu screen layers")
  local layers = assert(menuLayers.twoOption, "the battle view carries source two-option layers") --[[@as table[] ]]
  local armed = type(view.armed) == "table" and view.armed or nil
  local selected = nil
  local pressedId = nil
  if type(armed) == "table" and armed.scope == "child" then
    if armed.id == "confirm" then
      selected, pressedId = "yes", "yes"
    elseif armed.id == "back" then
      selected, pressedId = "cancel", "cancel"
    end
  end
  BattleMenuPresenter.draw(graphics, assets, "two-option", layers, {
    selection = selected,
    armed = pressedId ~= nil and { scope = "two-option", id = pressedId } or nil,
  })
  local labels = assert(child.twoOption, "learning confirmation carries source-selected labels") --[[@as table<string, unknown>]]
  local top = assert(labels.top, "the top option has its staged source label") --[[@as string]]
  local bottom = assert(labels.bottom, "the bottom option has its staged source label") --[[@as string]]
  local topY = 67
  local bottomY = 139
  if armed ~= nil and armed.scope == "child" then
    if armed.id == "confirm" then
      topY = topY - 2
    elseif armed.id == "back" then
      bottomY = bottomY - 2
    end
  end
  drawRoleText(text, "menu", top, 128 - math.floor(measureRoleText(text, "menu", top) / 2), topY, {
    foreground = 1,
    shadow = 2,
    background = 3,
  })
  drawRoleText(text, "menu", bottom, 128 - math.floor(measureRoleText(text, "menu", bottom) / 2), bottomY, {
    foreground = 10,
    shadow = 11,
    background = 12,
  })
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
---@param content table<string, unknown> canonical plan content carrying the layout
local function drawInteraction(resources, view, content)
  if view.mode == "child" and type(view.childView) == "table" then
    local child = view.childView --[[@as table<string, unknown>]]
    if child.kind == "learn" and type(child.confirmation) == "table" then
      drawTwoOptionConfirmation(resources, view, child)
    else
      drawChild(resources, view, child)
    end
    return
  end
  local graphics = assert(resources.graphics, "the battle render borrows its host graphics")
  local assets = assert(resources.assets, "the battle render borrows its asset holder")
  local text = assert(resources.text, "the battle render borrows its text services")
  local layout = content.layout --[[@as string]]
  if layout ~= "command" and layout ~= "moves" and layout ~= "target" and layout ~= "two-option" then
    layout = "command"
  end
  local menuLayers = assert(view.menuLayers, "the battle view carries generated menu screen layers")
  local sectionKey = layout == "two-option" and "twoOption" or layout
  local layers = assert(menuLayers[sectionKey], "the battle view carries layers for its selected menu") --[[@as table[] ]]
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
      { id = "target:0", x = 0, y = 88, w = 121, h = 57 },
      { id = "target:1", x = 136, y = 8, w = 120, h = 73 },
      { id = "target:2", x = 136, y = 88, w = 120, h = 57 },
      { id = "target:3", x = 0, y = 8, w = 121, h = 73 },
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
  local function drawMenu()
    local revealEdge = type(view.menuRevealEdge) == "number" and view.menuRevealEdge or nil
    local menuWindows = type(view.menuWindows) == "table" and view.menuWindows or nil
    BattleMenuPresenter.draw(graphics, assets, layout, layers, view, menuWindows)
    local function drawOverlay()
      -- Multi-actor turns name the acting battler above the menu so staged
      -- choices are never mistaken for the previous entry's selection.
      local acting = actingName(view)
      if acting ~= nil then
        drawRoleText(text, "menu", fitLabel(text, acting, 44, "menu"), 128, 8)
      end
      drawControls(resources, view, layout, regions)
    end
    if revealEdge ~= nil then
      LogicalSurface.clip(graphics, { x = 0, y = 0, width = 256, height = revealEdge }, drawOverlay)
    else
      drawOverlay()
    end
  end
  drawMenu()
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
      local image = battlerImage(assets, battler)
      if image ~= nil then
        local dx = (type(battler.shakeDx) == "number" and battler.shakeDx or 0) --[[@as number]]
        if type(battler.pictureXOffset) == "number" then
          dx = dx + battler.pictureXOffset --[[@as number]]
        end
        local scale = assert(spot.scale, "compact doubles portraits carry their authored presentation scale")
        local allocation = { x = spot.x, y = spot.y, width = spot.width, height = spot.height }
        LogicalSurface.clip(graphics, allocation, function()
          -- Lease-paired cells draw through the shared sampler so the
          -- recorded draw carries the staged cell exactly; owned and
          -- test images draw directly.
          drawArtwork(graphics, image, image.quad, spot.x + dx * scale, spot.y, 0, scale, scale)
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
  -- Compact images use ordinary alpha composition under an isolated
  -- neutral image tint, then restore the caller's complete graphics state.
  graphics.push("all")
  graphics.setBlendMode("alpha", "alphamultiply")
  graphics.setColor(1, 1, 1, 1)
  LogicalSurface.clip(graphics, viewport, function()
    local scene = nil
    local backgroundFailure = nil
    if type(view.backgroundRaster) == "table" and type(assets.background) == "function" then
      scene, backgroundFailure = assets:background(view.backgroundRaster --[[@as table<string, unknown>]])
    end
    if scene == nil and backgroundFailure == nil then
      scene = assets:drawable(resources.sceneImageKey --[[@as string]])
    end
    if scene ~= nil then
      local scrollX, scrollY = bgScrollOf(view)
      drawSceneLayer(graphics, scene, scrollX, scrollY)
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
          drawArtwork(graphics, front, front.quad, enemyCenter.x + dx, enemyCenter.y)
        end
      end
      if player ~= nil and player.visible ~= false then
        local back = battlerImage(assets, player)
        if back ~= nil then
          local dx = (type(player.shakeDx) == "number" and player.shakeDx or 0) --[[@as number]]
          drawArtwork(graphics, back, back.quad, playerCenter.x + dx, playerCenter.y)
        end
      end
    end
  end)
  graphics.pop()
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
