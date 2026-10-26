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
local BattleViewRoster = require("game.hgss.src.battle.BattleViewRoster")

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

-- Narration window (Battle_BattleInit's 27x4-tile window at tile 2,19):
-- content origin with its size, wrapped by the selected frame border.
local NARRATION_BOX = { x = 16, y = 152, width = 216, height = 32 }

-- Command text anchors and MAKE_TEXT_COLOR slots (lower OBJ palette bank
-- 2) from BattleInput_CreateMainMenuObjects.
local COMMAND_ANCHORS = {
  fight = { x = 128, y = 83 },
  bag = { x = 40, y = 169 },
  pokemon = { x = 216, y = 168 },
  run = { x = 128, y = 176 },
}
local COMMAND_SLOTS = {
  fight = { 1, 2, 3 },
  bag = { 4, 5, 6 },
  pokemon = { 7, 8, 9 },
  run = { 10, 11, 12 },
}

-- Fight menu text anchors from BattleInput_CreateFightMenuObjects: the
-- move name centers on its anchor, the "PP" label and the current/max
-- values print left-aligned on the row beneath; the type icon centers on
-- sTypeIconPositions.
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
-- sTargetPokemonMenuPositions, by target control index.
local TARGET_ANCHORS = {
  { x = 60, y = 116 },
  { x = 196, y = 32 },
  { x = 196, y = 116 },
  { x = 60, y = 32 },
}

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
  return #BattleViewRoster.claimedPositions(view, true) >= 2 or #BattleViewRoster.claimedPositions(view, false) >= 2
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

-- Resolves one live battler's stable sourced row: its index in the
-- side's claimed order, so a surviving slot never slides onto a hidden
-- neighbor's row; position-less records keep their live-order row.
---@param order integer[] canonical claimed positions in slot order
---@param battler table<string, unknown> live battler facts under drawing
---@param fallback integer live-order row behind position-less records
---@param rows table<integer, table<string, unknown>> sourced rows behind the side
---@param context string assertion context naming the sourced rows
---@return table<string, unknown> the battler's stable row
local function doublesRow(order, battler, fallback, rows, context)
  local row = rows[BattleViewRoster.claimedIndex(order, battler, fallback)]
  assert(row ~= nil, context)
  return row
end

-- Pairs every live doubles battler with its sourced row, foes before
-- allies in slot order: the insertion order the depth and HUD passes
-- keep for ties.
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param players table<integer, table<string, unknown>> live player-side battler facts in slot order
---@param enemies table<integer, table<string, unknown>> live enemy-side battler facts in slot order
---@return { battler: table<string, unknown>, role: table<string, unknown> }[] live battlers with their sourced rows
local function doublesRoles(view, players, enemies)
  local roles = {}
  local foeOrder = BattleViewRoster.claimedPositions(view, false)
  local allyOrder = BattleViewRoster.claimedPositions(view, true)
  for index, foe in ipairs(enemies) do
    local role = doublesRow(foeOrder, foe, index, DOUBLES_ROWS.enemy, "the sourced enemy rows cover every live foe")
    roles[#roles + 1] = { battler = foe, role = role }
  end
  for index, ally in ipairs(players) do
    local role =
      doublesRow(allyOrder, ally, index, DOUBLES_ROWS.player, "the sourced player rows cover every live ally")
    roles[#roles + 1] = { battler = ally, role = role }
  end
  return roles
end

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
-- Loud doubles occupancy: at most two live records per side and no
-- shared visible slot. Identity rides the message so a doubled claim
-- names both combatants.
---@param players table<integer, table<string, unknown>> live player-side battler facts
---@param enemies table<integer, table<string, unknown>> live enemy-side battler facts
local function checkDoublesSlots(players, enemies)
  assert(#players <= 2, "at most two live player battlers draw (got " .. tostring(#players) .. ")")
  assert(#enemies <= 2, "at most two live enemy battlers draw (got " .. tostring(#enemies) .. ")")
  local claimed = {}
  for _, side in ipairs({ players, enemies }) do
    for _, battler in ipairs(side) do
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

-- Resolves one source printer color triple through a staged text-role
-- palette: the bank is the printer's palette offset and the slots are its
-- MAKE_TEXT_COLOR entries. Slot zero is the transparent OBJ color.
---@param view table<string, unknown> internal semantic snapshot carrying the staged text palettes
---@param palette string staged printer palette ("narration", "hud", or "menu")
---@param bank integer sixteen-color bank under selection
---@param foreground integer source foreground slot
---@param shadow integer source shadow slot
---@param background integer source background slot
---@return table<string, table<string, number>> RGB triple for the palette-driven text path
local function sourcePalette(view, palette, bank, foreground, shadow, background)
  local palettes = assert(view.textPalettes, "the battle view carries its staged text palettes") --[[@as table<string, table<string, unknown>>]]
  local colors = assert(palettes[palette], "the battle view carries the " .. palette .. " text palette").colors --[[@as table[] ]]
  local function at(slot)
    if slot == 0 then
      return { r = 0, g = 0, b = 0, a = 0 }
    end
    local color = assert(colors[bank * 16 + slot + 1], "source text slots fall inside their palette bank")
    return { r = color.r, g = color.g, b = color.b }
  end
  return { foreground = at(foreground), shadow = at(shadow), background = at(background) }
end

---@param text table<string, unknown> borrowed text services
---@param role string source font role under drawing
---@param content string text under drawing
---@param x number horizontal origin under drawing
---@param y number vertical origin under drawing
---@param palette table<string, table<string, number>>? source RGB triple for this printer
local function drawRoleText(text, role, content, x, y, palette)
  local draw = text.drawTextForRole --[[@as fun(role: string, content: string, x: number, y: number, palette: table<string, table<string, number>>?)?]]
  if draw ~= nil then
    draw(role, content, x, y, palette)
  else
    text.drawText(content, x, y)
  end
end

-- GetPPTextColor: the PP printer's foreground and shadow slots in the
-- menu palette's PP bank, with a transparent background.
---@param pp integer current move PP
---@param maxPp integer maximum move PP
---@return integer, integer foreground and shadow slots
local function ppSlots(pp, maxPp)
  if pp == 0 then
    return 7, 8
  end
  if pp == maxPp then
    return 1, 2
  end
  if maxPp <= 2 then
    if pp == 1 then
      return 5, 6
    end
  elseif maxPp <= 7 then
    if pp == 1 then
      return 5, 6
    elseif pp == 2 then
      return 3, 4
    end
  else
    if pp <= maxPp / 4 then
      return 5, 6
    end
    if pp <= maxPp / 2 then
      return 3, 4
    end
  end
  return 1, 2
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

---@param value unknown optional numeric snapshot fact
---@param default number value standing in for an absent fact
---@return number
local function numberOr(value, default)
  return type(value) == "number" and value or default
end

---@param tint table<string, number>? optional picture tint
---@return number red multiplier
---@return number green multiplier
---@return number blue multiplier
---@return number alpha multiplier
local function tintOf(tint)
  if tint == nil then
    return 1, 1, 1, 1
  end
  return tint.r or 1, tint.g or 1, tint.b or 1, tint.a or 1
end

-- Battler picture fields that default to zero, keyed by picture field
-- with the snapshot fact behind each.
local PICTURE_OFFSETS = {
  zOffset = "zOffset",
  xOffset = "pictureXOffset",
  yOffset = "pictureYOffset",
  xOffset2 = "pictureXOffset2",
  yOffset2 = "pictureYOffset2",
  shadowHeight = "shadowHeight",
  pivotX = "pivotX",
  pivotY = "pivotY",
}

-- The GPU picture pass consumes staged image handles: leases and
-- wrappers resolve to their staged image while headless descriptors and
-- other pixel-less stand-ins never reach the isolated depth target.
---@param handle unknown resolved drawable handle, nil when unstaged
---@return unknown? staged image for the picture pass
local function pictureImage(handle)
  if type(handle) ~= "table" then
    -- Host images draw directly.
    return handle
  end
  local staged = handle.image or (handle.lease and handle.lease.image) or handle
  if type(staged.getDimensions) ~= "function" then
    return nil
  end
  return staged
end

-- Live battlers with their published slot rows in native depth order:
-- singles take the fixed source side types, doubles their claimed
-- sourced rows. Insertion order (foe first) breaks depth ties.
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param players table<integer, table<string, unknown>> live player-side battler facts in slot order
---@param enemies table<integer, table<string, unknown>> live enemy-side battler facts in slot order
---@param singles boolean true while the battle keeps its single layout
---@return { battler: table<string, unknown>, row: BattleRenderer.SlotGeometry, insertion: integer }[] depth-ordered records
local function pictureRecords(view, players, enemies, singles)
  local records = {}
  local function add(battler, row)
    records[#records + 1] = { battler = battler, row = row, insertion = #records + 1 }
  end
  if singles then
    if enemies[1] ~= nil then
      add(enemies[1], sourceSlotGeometry(view, 1))
    end
    if players[1] ~= nil then
      add(players[1], sourceSlotGeometry(view, 0))
    end
  else
    for _, entry in ipairs(doublesRoles(view, players, enemies)) do
      add(entry.battler, sourceSlotGeometry(view, entry.role.sideType))
    end
  end
  table.sort(records, function(left, right)
    if left.row.depth ~= right.row.depth then
      return left.row.depth < right.row.depth
    end
    return left.insertion < right.insertion
  end)
  return records
end

-- The native shadow plane under one battler: absent without a shadow
-- size, while hidden, or while the battler draws its own visible plane.
-- Adjusted shadows follow the picture center; fixed shadows keep their
-- source position.
---@param assets table<string, unknown> injected asset holder
---@param battler table<string, unknown> displayed battler facts under drawing
---@param row BattleRenderer.SlotGeometry the battler's published slot row
---@return table<string, unknown>? shadow picture for the picture pass
local function shadowPicture(assets, battler, row)
  local shadowSize = numberOr(battler.shadowSize, 0)
  if shadowSize == 0 or battler.shadowVisible == false or battler.pictureVisible == true then
    return nil
  end
  local shadow = pictureImage(assets:drawable("shadow"))
  if shadow == nil then
    return nil
  end
  local pictureCenterX = row.settledX + numberOr(battler.entryDx, 0) + numberOr(battler.shakeDx, 0)
  local pictureCenterY = row.settledY
    + numberOr(battler.height, 0)
    + numberOr(battler.sourceHeight, 0)
    + numberOr(battler.entryDy, 0)
  local shadowX = battler.shadowAdjustX == false
      and assert(type(battler.shadowX) == "number" and battler.shadowX, "fixed shadows carry their source X")
    or pictureCenterX + numberOr(battler.pictureXOffset, 0) + numberOr(battler.shadowOffsetX, 0)
  local shadowY = battler.shadowAdjustY == false
      and assert(type(battler.shadowY) == "number" and battler.shadowY, "fixed shadows carry their source Y")
    or pictureCenterY + numberOr(battler.pictureYOffset, 0) + numberOr(battler.shadowOffsetY, 0)
  local tintR, tintG, tintB = tintOf(battler.shadowTint --[[@as table<string, number>?]])
  return {
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
    affineWidth = numberOr(battler.affineWidth, 0x100),
    affineHeight = numberOr(battler.affineHeight, 0x100),
    tintR = tintR,
    tintG = tintG,
    tintB = tintB,
    alpha = numberOr(battler.polygonAlpha, 31) / 31,
    paletteFade = battler.paletteFade,
  }
end

-- One battler's own picture plane at its slot row with its transient
-- entry, shake, height, scale, and affine facts. The Substitute doll is
-- a transient native animation picture: the scene hides the replaced
-- mon and the animation owner supplies the doll through its effect.
---@param assets table<string, unknown> injected asset holder
---@param battler table<string, unknown> displayed battler facts under drawing
---@param row BattleRenderer.SlotGeometry the battler's published slot row
---@return table<string, unknown>? battler picture, nil while substituted or unstaged
local function battlerPicture(assets, battler, row)
  if battler.substitute == true then
    return nil
  end
  local image = pictureImage(battlerImage(assets, battler))
  if image == nil then
    return nil
  end
  local sourceHeight = numberOr(battler.height, 0) + numberOr(battler.sourceHeight, 0)
  local scaleX = numberOr(battler.scaleX, 1)
  local scaleY = numberOr(battler.scaleY, 1)
  if battler.affineMode == true then
    scaleX = scaleX
      * assert(type(battler.affineWidth) == "number" and battler.affineWidth, "affine pictures carry native width")
      / 0x100
    scaleY = scaleY
      * assert(type(battler.affineHeight) == "number" and battler.affineHeight, "affine pictures carry native height")
      / 0x100
  end
  local pictureVisible = battler.pictureVisible == true
  local tintR, tintG, tintB, tintA = tintOf(battler.pictureTint --[[@as table<string, number>?]])
  local picture = {
    image = image,
    centerX = row.settledX + numberOr(battler.entryDx, 0) + numberOr(battler.shakeDx, 0),
    centerY = row.settledY + sourceHeight + numberOr(battler.entryDy, 0),
    zCenter = row.depth,
    pictureVisible = pictureVisible,
    width = pictureVisible and numberOr(battler.pictureWidth, 80) or 80 * scaleX,
    height = pictureVisible and numberOr(battler.pictureHeight, 80) or 80 * scaleY,
    rotationX = battler.rotationX,
    rotationY = battler.rotationY,
    rotationZ = battler.rotationZ,
    rotation = battler.rotation,
    tintR = tintR,
    tintG = tintG,
    tintB = tintB,
    alpha = numberOr(battler.polygonAlpha, 31) / 31 * tintA,
    paletteFade = battler.paletteFade,
  }
  for field, fact in pairs(PICTURE_OFFSETS) do
    picture[field] = numberOr(battler[fact], 0)
  end
  return picture
end

-- One transient effect picture. Source cell bands crop their staged tile
-- strip through an exact pixel origin; whole-image pictures omit the
-- origin and flips.
---@param assets table<string, unknown> injected asset holder
---@param picture table<string, unknown> transient effect picture facts
---@return table<string, unknown> effect picture for the picture pass
local function effectPicture(assets, picture)
  local assetKey = assert(picture.assetKey, "transient pictures carry their staged drawable key")
  local image = assert(assets:drawable(assetKey), "transient effect drawables are staged before submission")
  return {
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
    pictureVisible = picture.xOffset2 ~= nil or picture.yOffset2 ~= nil,
    xOffset2 = picture.xOffset2,
    yOffset2 = picture.yOffset2,
    flipH = picture.flipH,
    flipV = picture.flipV,
  }
end

-- Submits every depth-ordered battler shadow and picture, then the
-- transient effect pictures, as one isolated picture pass composited
-- under the neutral tint. Vanished and undrawn battlers submit nothing.
---@param graphics table<string, unknown> injected host graphics
---@param assets table<string, unknown> injected asset holder
---@param view table<string, unknown> internal semantic snapshot under drawing
---@param players table<integer, table<string, unknown>> live player-side battler facts in slot order
---@param enemies table<integer, table<string, unknown>> live enemy-side battler facts in slot order
---@param singles boolean true while the battle keeps its single layout
local function drawPicturePlanes(graphics, assets, view, players, enemies, singles)
  local pictures = {}
  local function submit(picture)
    if picture ~= nil then
      pictures[#pictures + 1] = picture
    end
  end
  for _, record in ipairs(pictureRecords(view, players, enemies, singles)) do
    local battler = record.battler
    if battler.vanished ~= true and battler.dontDraw ~= true then
      submit(shadowPicture(assets, battler, record.row))
      submit(battlerPicture(assets, battler, record.row))
    end
  end
  for _, effect in ipairs(assert(view.effectInstances, "battle snapshots carry transient effect instances")) do
    local picture = effect.picture --[[@as table<string, unknown>?]]
    if picture ~= nil then
      submit(effectPicture(assets, picture))
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

---@param graphics table<string, unknown> injected host graphics
---@param assets table<string, unknown> generated battle assets
---@param view table<string, unknown> battle snapshot under drawing
---@param layout string active menu layout
---@param regions table<integer, table<string, unknown>> menu hit regions
local function drawKeypadCursor(graphics, assets, view, layout, regions)
  if view.cursorVisible ~= true or type(view.selection) ~= "string" then
    return
  end
  local selected = nil
  if layout == "command" and type(view.commands) == "table" then
    for index, command in ipairs(view.commands) do
      if command.id == view.selection then
        selected = regions[index]
        break
      end
    end
  else
    for _, region in ipairs(regions) do
      if region.id == view.selection then
        selected = region
        break
      end
    end
  end
  if selected == nil then
    return
  end
  local image = assets:drawable("cursor")
  if image == nil then
    return
  end
  local section = assert(view.cursor, "battle view carries the source keypad cursor cell and animations")
  local stripWidth = stripWidthOf(image)
  if stripWidth == nil then
    return
  end
  local left = selected.x + 8
  local right = selected.x + selected.w - 8
  local top = selected.y + 8
  local bottom = selected.y + selected.h - 8
  for corner = 1, 4 do
    local animation = assert(section.animations[corner], "the cursor stages four corner animations")
    local frame = assert(animation.frames[1], "each cursor corner animation has an initial frame")
    local cell = assert(section.cells[frame.cell + 1], "cursor animation selects a staged cell")
    local x = corner % 2 == 1 and left or right
    local y = corner <= 2 and top or bottom
    for _, object in ipairs(cell.objs) do
      drawSpriteObject(graphics, image, stripWidth --[[@as integer]], x, y, object)
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

---@param patchSpans table<string, unknown> published source HUD patch spans
---@param category string patch category under lookup
---@param sideType integer native health-box side type
---@return table<integer, { tile: integer, count: integer }> ordered character spans for the side type
local function sideSpans(patchSpans, category, sideType)
  for _, record in
    ipairs(patchSpans[category] --[[@as table<integer, table<string, unknown>>]])
  do
    if record.sideType == sideType then
      return record.spans or { record }
    end
  end
  error("the HUD patch map covers " .. category .. " for side type " .. tostring(sideType), 0)
end

-- Prints the health-box character writes the way battle_hp_bar.c does:
-- the nickname through an 8x2-tile font-0 window filled with HUD color
-- 15 and printed in colors 14/2/15, the level's printer digits shifted
-- half a tile down across two tile rows, and, on boxes showing numbers,
-- the right-aligned current and left-aligned maximum HP digits. Every
-- write lands on its source character tile wherever the cell places it.
---@param graphics table<string, unknown> injected host graphics
---@param text table<string, unknown> borrowed text services
---@param assets table<string, unknown> injected asset holder
---@param view table<string, unknown> internal semantic snapshot carrying the HUD patch spans and palettes
---@param artKey string staged strip identity under drawing
---@param section table<string, unknown> staged HUD section publishing its printer digits
---@param anchor table<string, number> composite anchor under drawing
---@param objects table<integer, table<string, unknown>> source cell objects
---@param battler table<string, unknown> displayed battler facts under drawing
---@param sideType integer native health-box side type
---@param hpNumbers boolean true when the box prints its HP digits
---@param compactTransform table<string, number>? transformed source cell placement in compact layout
local function drawHudPrinters(
  graphics,
  text,
  assets,
  view,
  artKey,
  section,
  anchor,
  objects,
  battler,
  sideType,
  hpNumbers,
  compactTransform
)
  local art = assets:drawable(artKey)
  local stripWidth = art ~= nil and stripWidthOf(art) or nil
  local stripHeight = art ~= nil and stripHeightOf(art) or nil
  if art == nil or stripWidth == nil or stripHeight == nil then
    return
  end
  local digitBase = assert(section.digitBase, "health-box strips publish their printer digits") --[[@as integer]]
  local patchSpans = assert(view.hudPatchSpans, "battle manifest carries source HUD patch spans")
  local function project(x, y)
    if compactTransform == nil then
      return x, y, 1
    end
    local scale = assert(compactTransform.scale, "compact printer layout carries its source scale")
    return compactTransform.x + x * scale, compactTransform.y + y * scale, scale
  end
  local function stripTile(index, x, y)
    local drawX, drawY, scale = project(x, y)
    drawArtwork(
      graphics,
      art,
      graphics.newQuad(index * 8, 0, 8, 8, stripWidth, stripHeight),
      drawX,
      drawY,
      0,
      scale,
      scale
    )
  end
  -- Printer cells: a decimal digit selects its tile, anything else the
  -- printer's fill tile.
  local function printerTile(character)
    local digit = character ~= nil and tonumber(character) or nil
    return digit ~= nil and digitBase + digit or digitBase + 10
  end

  local window = sideSpans(patchSpans, "nickname", sideType)
  local palette = sourcePalette(view, "hud", 0, 14, 2, 15)
  local name = tostring(assert(battler.name, "health boxes print their battler's name"))
  for row = 0, 1 do
    local leading = window[row + 1]
    for column = 0, 7 do
      local tile = column < leading.count and leading.tile + column or window[row + 3].tile + column - leading.count
      local sourceX, sourceY = hudTileOrigin(anchor, objects, tile)
      local x, y, scale = project(sourceX, sourceY)
      LogicalSurface.clip(graphics, { x = x, y = y, width = 8 * scale, height = 8 * scale }, function()
        stripTile(digitBase + 10, sourceX, sourceY)
        graphics.push("all")
        graphics.translate(x, y)
        graphics.scale(scale, scale)
        drawRoleText(text, "hud", name, -column * 8, -row * 8, palette)
        graphics.pop()
      end)
    end
  end

  if type(battler.level) == "number" then
    local level = sideSpans(patchSpans, "level", sideType)
    local digits = tostring(battler.level)
    for index = 0, 2 do
      local source = printerTile(digits:sub(index + 1, index + 1))
      local sourceTopX, sourceTopY = hudTileOrigin(anchor, objects, level[1].tile + index)
      local topX, topY, scale = project(sourceTopX, sourceTopY + 4)
      LogicalSurface.clip(graphics, { x = topX, y = topY, width = 8 * scale, height = 4 * scale }, function()
        stripTile(source, sourceTopX, sourceTopY + 4)
      end)
      local sourceBottomX, sourceBottomY = hudTileOrigin(anchor, objects, level[2].tile + index)
      local bottomX, bottomY, bottomScale = project(sourceBottomX, sourceBottomY)
      LogicalSurface.clip(
        graphics,
        { x = bottomX, y = bottomY, width = 8 * bottomScale, height = 4 * bottomScale },
        function()
          stripTile(source, sourceBottomX, sourceBottomY - 4)
        end
      )
    end
  end

  if hpNumbers then
    local current = string.format("%3d", assert(battler.hp, "player health boxes carry displayed HP"))
    local maximum = tostring(assert(battler.maxHp, "player health boxes carry maximum HP"))
    local currentTile = sideSpans(patchSpans, "currentHp", sideType)[1].tile
    local maximumTile = sideSpans(patchSpans, "maximumHp", sideType)[1].tile
    for index = 0, 2 do
      local currentX, currentY = hudTileOrigin(anchor, objects, currentTile + index)
      local maximumX, maximumY = hudTileOrigin(anchor, objects, maximumTile + index)
      stripTile(printerTile(current:sub(index + 1, index + 1)), currentX, currentY)
      stripTile(printerTile(maximum:sub(index + 1, index + 1)), maximumX, maximumY)
    end
  end
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
  -- Build one ordered native HUD pass. Its template draw priority is
  -- distinct from the battler's Pokepic depth and the BG priority.
  local hudRecords = {}
  for _, entry in ipairs(doublesRoles(view, players, enemies)) do
    hudRecords[#hudRecords + 1] = {
      battler = entry.battler,
      row = sourceSlotGeometry(view, entry.role.sideType),
      art = entry.role.art,
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
      drawHudPrinters(
        graphics,
        text,
        assets,
        view,
        art,
        section,
        { x = row.hudX, y = row.hudY },
        cell.objs,
        battler,
        row.sideType,
        playerMode == "numbers"
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
    local order = BattleViewRoster.claimedPositions(view, true)
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
  return numberOr(scroll.x, 0), numberOr(scroll.y, 0)
end

-- Resolves the battlefield scene layer: the snapshot's raster background
-- when the asset holder renders one, else the selected scene image. A
-- reported background failure draws no substitute scene.
---@param resources table<string, unknown> borrowed application collaborators
---@param assets table<string, unknown> injected asset holder
---@param view table<string, unknown> internal semantic snapshot
---@return table<string, unknown>? scene drawable, nil while unavailable
local function sceneLayer(resources, assets, view)
  local scene = nil
  local backgroundFailure = nil
  if type(view.backgroundRaster) == "table" and type(assets.background) == "function" then
    scene, backgroundFailure = assets:background(view.backgroundRaster --[[@as table<string, unknown>]])
  end
  if scene == nil and backgroundFailure == nil then
    scene = assets:drawable(resources.sceneImageKey --[[@as string]])
  end
  return scene
end

-- Draws one single-battle health box: the staged cell composite, the
-- native bar tile rows and icons, and the printed name, level, and HP
-- character writes. The foe box hides its private health facts and
-- carries no experience row; the player box prints its HP digits and
-- draws its experience tile row.
---@param graphics table<string, unknown> injected host graphics
---@param text table<string, unknown> borrowed text services
---@param assets table<string, unknown> injected asset holder
---@param view table<string, unknown> internal semantic snapshot
---@param battler table<string, unknown> displayed battler facts under drawing
---@param artKey string staged strip identity under drawing
---@param anchor table<string, number> composite anchor under drawing
---@param section table<string, unknown> staged source HUD section under drawing
---@param playerBox boolean true for the player box with numerals and experience
---@param sideType integer source HUD side type
local function drawSingleHud(graphics, text, assets, view, battler, artKey, anchor, section, playerBox, sideType)
  local patchSpans = assert(view.hudPatchSpans, "battle manifest carries source HUD patch spans")
  local gaugePatchTiles = view.gaugePatchTiles --[[@as table<string, unknown>?]]
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
  if not playerBox and view.battleKind == "wild" then
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
  drawHudPrinters(graphics, text, assets, view, artKey, section, anchor, objects, battler, sideType, playerBox)
end

-- Draws the selection arrow in the decision modes. The arrow OBJ uses
-- priority 0x11, behind the source HP box OBJ range; the opening cell and
-- out-of-range frames draw nothing.
---@param graphics table<string, unknown> injected host graphics
---@param assets table<string, unknown> injected asset holder
---@param view table<string, unknown> internal semantic snapshot
---@param players table<integer, table<string, unknown>> live player-side battler facts in slot order
---@param singles boolean true while the battle keeps its single layout
local function drawSelectionArrow(graphics, assets, view, players, singles)
  if view.mode ~= "command" and view.mode ~= "moves" and view.mode ~= "target" then
    return
  end
  local cell = view.arrowFrame --[[@as integer?]]
  if type(cell) ~= "number" or cell < 1 or cell > #ARROW_CELLS - 1 then
    return
  end
  local art = assets:drawable("arrow")
  if art == nil then
    return
  end
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

-- Single-battle health boxes in draw order: the foe box first, then the
-- player box with its numerals and experience row.
local SINGLE_HUDS = {
  { sideType = 1, art = "hud:enemy", section = "enemy", playerBox = false },
  { sideType = 0, art = "hud:player", section = "player", playerBox = true },
}

---@param graphics table<string, unknown> injected host graphics
---@param text table<string, unknown> borrowed text services
---@param assets table<string, unknown> injected asset holder
---@param view table<string, unknown> internal semantic snapshot
---@param players table<integer, table<string, unknown>> live player-side battler facts in slot order
---@param enemies table<integer, table<string, unknown>> live enemy-side battler facts in slot order
local function drawSinglesDetail(graphics, text, assets, view, players, enemies)
  local sections = view.hudSections --[[@as table<string, table<string, unknown>>]]
  local battlers = { [0] = players[1], [1] = enemies[1] }
  for _, hud in ipairs(SINGLE_HUDS) do
    local battler = battlers[hud.sideType]
    if battler ~= nil then
      assert(sections ~= nil, "the battle view carries staged single HUD cells")
      local row = sourceSlotGeometry(view, hud.sideType)
      drawSingleHud(
        graphics,
        text,
        assets,
        view,
        battler,
        hud.art,
        { x = row.hudX, y = row.hudY },
        sections[hud.section],
        hud.playerBox,
        row.sideType
      )
    end
  end
end

-- Battle_BattleInit fills the message window with color 15 and prints
-- with the font's default slots: foreground 1, shadow 2, background 15.
---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
local function drawNarration(resources, view)
  if type(view.message) ~= "string" or view.message == "" then
    return
  end
  local graphics = resources.graphics --[[@as table<string, unknown>]]
  local text = resources.text --[[@as table<string, unknown>]]
  local windows = resources.windows --[[@as table<string, unknown>]]
  local palette = sourcePalette(view, "narration", 0, 1, 2, 15)
  local fill = palette.background
  local messageBox = {
    x = NARRATION_BOX.x,
    y = NARRATION_BOX.y + numberOr(view.messageScrollY, 0),
    width = NARRATION_BOX.width,
    height = NARRATION_BOX.height,
  }
  windows.drawWindow(messageBox, resources.frameKey, { fill.r / 255, fill.g / 255, fill.b / 255, 1 })
  LogicalSurface.clip(graphics, messageBox, function()
    drawRoleText(text, "narration", view.message --[[@as string]], messageBox.x, messageBox.y, palette)
  end)
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
local function drawDetail(resources, view)
  local graphics = assert(resources.graphics, "the battle render borrows its host graphics")
  local text = assert(resources.text, "the battle render borrows its text services")
  assert(resources.windows, "the battle render borrows its window services")
  local assets = assert(resources.assets, "the battle render borrows its asset holder")
  local doublesHud = resources.doublesHud --[[@as table<string, unknown>?]]
  -- The battlefield draws under the neutral image tint however hostile
  -- the incoming graphics state is; the borrowed color returns on every
  -- path below.
  local r, g, b, a = saveColor(graphics)
  graphics.setColor(1, 1, 1, 1)
  -- The background layer honors the viewport scroll on its own decoded
  -- layer; portraits and health boxes stay layer-independent.
  local scene = sceneLayer(resources, assets, view)
  if scene ~= nil then
    local scrollX, scrollY = bgScrollOf(view)
    drawSceneLayer(graphics, scene, scrollX, scrollY)
  end
  local players, enemies = BattleViewRoster.liveSides(view)
  local singles = not doublesFormat(view, players, enemies)
  drawPicturePlanes(graphics, assets, view, players, enemies, singles)
  drawSelectionArrow(graphics, assets, view, players, singles)
  if singles then
    drawSinglesDetail(graphics, text, assets, view, players, enemies)
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
  drawNarration(resources, view)
  restoreColor(graphics, r, g, b, a)
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
  local menuText = assert(view.menuText, "the battle view carries its staged source menu labels") --[[@as table<string, string>]]
  -- BattleInput_CreateTextObject centers each label on its anchor when
  -- asked and lifts the 16-pixel text object eight pixels above it; a
  -- pressed button raises its label two more pixels.
  local function label(role, content, anchor, centered, pressed, palette)
    local x = anchor.x
    if centered then
      x = x - math.floor(measureRoleText(text, role, content) / 2)
    end
    drawRoleText(text, role, content, x, anchor.y - 8 - (pressed and 2 or 0), palette)
  end
  for _, region in ipairs(regions) do
    local box = region --[[@as table<string, unknown>]]
    local id = box.id --[[@as string]]
    local pressed = armed ~= nil and armed.id == id and armed.scope == layout
    local art = assets:drawable("menu:" .. layout .. ":" .. id)
    local slot = id:match("^move:(%d+)$")
    if slot ~= nil and movesBySlot[tonumber(slot)] == nil then
      -- Missing move slots stay visibly empty: no art, no label.
    else
      if art ~= nil then
        drawArtwork(graphics, art, nil, box.x --[[@as number]], box.y --[[@as number]])
      end
      if layout == "command" and COMMAND_ANCHORS[id] ~= nil then
        local entry = assert(commandsById[id], "command controls carry their source facts")
        local slots = COMMAND_SLOTS[id]
        if id == "fight" and type(view.commandIcon) == "table" then
          local iconFacts = view.commandIcon --[[@as table<string, unknown>]]
          local icon = assets:drawable(
            "battle:icon:" .. tostring(iconFacts.key) .. ":frame:" .. tostring(iconFacts.frameIndex or 1)
          )
          if icon ~= nil then
            local labelWidth =
              measureRoleText(text, "menu", assert(entry.label, "command controls carry their source label"))
            local labelLeft = COMMAND_ANCHORS.fight.x - math.floor(labelWidth / 2)
            local dimensions = icon.getDimensions --[[@as fun(self: table<string, unknown>): number, number]]
            local width, height = dimensions(icon)
            -- BattleInput positions the 32-pixel sprite by its center at
            -- the fight label's left edge minus sixteen pixels.
            local iconX = iconFacts.rightOfLabel == true and labelLeft + labelWidth or labelLeft - 32
            drawArtwork(graphics, icon, nil, iconX, COMMAND_ANCHORS.fight.y - 32 - (pressed and 2 or 0))
            assert(width == 32 and height == 32, "battle command icons use the native 32-pixel extent")
          end
        end
        label(
          "menu",
          assert(entry.label, "command controls carry their source label") --[[@as string]],
          COMMAND_ANCHORS[id],
          true,
          pressed,
          sourcePalette(view, "menu", 2, slots[1], slots[2], slots[3])
        )
      elseif slot ~= nil then
        local slotIndex = tonumber(slot) --[[@as integer]]
        local move = movesBySlot[slotIndex]
        local typeAnchor = TYPE_ANCHORS[slotIndex + 1]
        if move ~= nil and move.name ~= nil then
          label(
            "menu",
            move.name --[[@as string]],
            MOVE_ANCHORS[slotIndex + 1],
            true,
            pressed,
            sourcePalette(view, "menu", 3, 7, 8, 9)
          )
          local foreground, shadow = ppSlots(move.pp --[[@as integer]], move.maxPp --[[@as integer]])
          local ppPalette = sourcePalette(view, "menu", 4, foreground, shadow, 0)
          label("hud", menuText.pp, PP_CURRENT_ANCHORS[slotIndex + 1], false, pressed, ppPalette)
          label(
            "hud",
            string.format("%2d/%2d", move.pp, move.maxPp),
            PP_MAX_ANCHORS[slotIndex + 1],
            false,
            pressed,
            ppPalette
          )
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
              local offset = icon.offset --[[@as table<string, number>?]]
              drawArtwork(
                graphics,
                icon,
                nil,
                typeAnchor.x - math.floor(iconWidth / 2) + (offset and offset.x or 0),
                typeAnchor.y - math.floor(iconHeight / 2) + (offset and offset.y or 0) - (pressed and 2 or 0)
              )
            end
          end
        end
      elseif id == "cancel" then
        label("menu", menuText.cancel, CANCEL_ANCHOR, true, pressed, sourcePalette(view, "menu", 2, 10, 11, 12))
      elseif id:match("^target:") ~= nil then
        local index = tonumber(id:match("^target:(%d+)$")) --[[@as integer]]
        local opponent = index % 2 == 1
        label(
          "menu",
          targetName(view, id) or id,
          TARGET_ANCHORS[index + 1],
          true,
          pressed,
          sourcePalette(view, "menu", 6, opponent and 1 or 4, opponent and 2 or 5, opponent and 3 or 6)
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

-- Draws the party rows from their native source families by roster
-- visibility: the committed battle roster behind the player row, the
-- revealed active-foe count behind the trainer-battle enemy row. Unrevealed foes keep
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
  -- BattleInput_EnableBallGauge shows the opponent row only in trainer
  -- battles; a wild encounter draws the player row alone.
  if view.battleKind == "wild" then
    return
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
-- numbers, so a painted row and its tap target always agree.
local CHILD_TITLE = { x = 8, y = 8, maxWidth = 240 }
local CHILD_ROW_Y0 = 32
local CHILD_ROW_H = 20
local CHILD_LABEL_X = 12
local CHILD_DETAIL_X = 144
local CHILD_BACK_LABEL = { x = 12, y = 156 }
local CHILD_NOTICE = { x = 12, y = 172, maxWidth = 232 }
-- Tabular row columns: the entry name width, the level or quantity
-- column, and the health or legality column with its width. Bag rows
-- trade the level column for a wider item name.
local CHILD_COLUMNS = { nameWidth = 68, subX = 116, detailX = 156, detailWidth = 80 }
local CHILD_BAG_COLUMNS = { nameWidth = 100, subX = 146, detailX = 180, detailWidth = 56 }

---@param text table<string, unknown> borrowed text services
---@param child table<string, unknown> detached child view under drawing
---@param box table<string, unknown> projected learning row under drawing
---@param index integer one-based row number
---@param y number row top under drawing
local function drawLearnRow(text, child, box, index, y)
  local marker = (child.focusId == box.id) and "> " or "  "
  local label = marker .. tostring(index) .. ". " .. tostring(box.label or "")
  text.drawText(fitLabel(text, label, 128), CHILD_LABEL_X, y + 4)
  if type(box.detail) == "string" and box.detail ~= "" then
    text.drawText(fitLabel(text, box.detail, 100), CHILD_DETAIL_X, y + 4)
  end
end

-- Tabular rows share one column each for the focused number, the entry
-- name, its level or quantity, and its health or legality facts, so
-- every visible fact has its own draw.
---@param text table<string, unknown> borrowed text services
---@param child table<string, unknown> detached child view under drawing
---@param box table<string, unknown> projected party, target, or bag row under drawing
---@param index integer one-based row number
---@param y number row top under drawing
local function drawTabularRow(text, child, box, index, y)
  local columns = child.kind == "bag" and CHILD_BAG_COLUMNS or CHILD_COLUMNS
  local head = ((child.focusId == box.id) and "> " or "  ") .. tostring(index) .. "."
  text.drawText(head, CHILD_LABEL_X, y + 4)
  local name = tostring(box.label or "")
  if box.enabled ~= true and box.empty ~= true then
    name = name .. " [X]"
  end
  text.drawText(fitLabel(text, name, columns.nameWidth), 44, y + 4)
  if type(box.sub) == "string" and box.sub ~= "" then
    text.drawText(box.sub, columns.subX, y + 4)
  end
  if type(box.detail) == "string" and box.detail ~= "" then
    text.drawText(fitLabel(text, box.detail, columns.detailWidth), columns.detailX, y + 4)
  end
end

-- The modal footer: Back on learning and cancellable children, the
-- forced-choice notice on party and target children, bag pocket
-- stepping, and the notice or guidance caption outside learning.
---@param text table<string, unknown> borrowed text services
---@param child table<string, unknown> detached child view under drawing
local function drawChildFooter(text, child)
  if child.kind == "learn" then
    text.drawText("BACK", CHILD_NOTICE.x, CHILD_NOTICE.y)
    return
  end
  if child.cancellable == true then
    text.drawText("BACK", CHILD_BACK_LABEL.x, CHILD_BACK_LABEL.y)
  elseif child.kind == "party" or child.kind == "target" then
    text.drawText("No retreat!", CHILD_BACK_LABEL.x, CHILD_BACK_LABEL.y)
  end
  if child.kind == "bag" and child.empty ~= true then
    text.drawText("<", 100, CHILD_BACK_LABEL.y)
    text.drawText(">", 232, CHILD_BACK_LABEL.y)
  end
  local notice = child.notice
  if type(notice) ~= "string" or notice == "" then
    notice = BattleChildText.subtitle(child)
  end
  text.drawText(fitLabel(text, notice, CHILD_NOTICE.maxWidth), CHILD_NOTICE.x, CHILD_NOTICE.y)
end

-- Draws the open child as a battle-local modal over the lower pane: the
-- title, every projected row with its focus and disabled marks, and the
-- permitted Back and pocket controls. A staged learning confirmation
-- draws the two-option menu instead. Upper-battlefield drawing is
-- untouched.
---@param resources table<string, unknown> borrowed application collaborators
---@param child table<string, unknown> detached child view under drawing
local function drawChild(resources, child)
  local text = assert(resources.text, "the battle render borrows its text services")
  local windows = assert(resources.windows, "the battle render borrows its window services")
  windows.drawWindow({ x = 0, y = 0, width = 256, height = 192 }, resources.frameKey, { 0, 0, 0 })
  text.drawText(fitLabel(text, BattleChildText.title(child), CHILD_TITLE.maxWidth), CHILD_TITLE.x, CHILD_TITLE.y)
  local occupancy = BattleChildText.occupancy(child)
  if occupancy ~= nil then
    text.drawText(occupancy, 216, CHILD_TITLE.y)
  end
  if child.kind == "bag" and type(child.stock) == "number" then
    text.drawText("Stock: " .. tostring(child.stock), 184, CHILD_TITLE.y)
  end
  local rows = child.rows --[[@as table<integer, table<string, unknown>>?]]
  if type(rows) == "table" then
    local drawRow = child.kind == "learn" and drawLearnRow or drawTabularRow
    for index, row in ipairs(rows) do
      if index > 6 then
        break
      end
      drawRow(text, child, row, index, CHILD_ROW_Y0 + (index - 1) * CHILD_ROW_H)
    end
  end
  drawChildFooter(text, child)
end

-- Battle borrows the field session's native application renderers for
-- bag and party children. Their controller status and generated geometry
-- travel together from the same child composition.
---@param resources table<string, unknown>
---@param child table<string, unknown>
---@param placement LayoutGeometry.Placement resolved placement of the 256x192 pane the child covers
---@return boolean handled
function BattleRenderer.drawNativeChild(resources, child, placement)
  local menus = resources.battleMenus
  local native = child.native
  if type(menus) ~= "table" or type(native) ~= "table" or native.open == false then
    return false
  end
  if child.kind == "bag" then
    local bag = menus.bag --[[@as table<string, unknown>?]]
    if type(bag) ~= "table" or type(bag.renderer) ~= "table" then
      return false
    end
    local content = assert(native.layout, "the battle bag shares its native generated layout")
    bag.renderer:draw(native, {
      content = content,
      panes = {
        {
          id = "interaction",
          placement = placement,
          interactive = true,
        },
      },
    }, { icons = assert(bag.icons, "the native bag borrows field item icons") })
    return true
  end
  if child.kind == "party" or child.kind == "target" then
    local party = menus.party --[[@as table<string, unknown>?]]
    if type(party) ~= "table" or type(party.renderer) ~= "table" then
      return false
    end
    -- Opening the picker grows the battle icon demand by its roster; the
    -- picker stays blank until those pages are adopted, like the field party.
    local assets = assert(resources.assets, "the native party borrows the battle asset holder")
    if assets:state() ~= "ready" then
      return true
    end
    local layout = assert(native.layout, "the battle party shares its native generated layout")
    party.renderer:draw(native, layout, assert(party.icons, "the native party borrows field mon icons"))
    return true
  end
  return false
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
---@param child table<string, unknown> confirmed learning child view with source labels
local function drawTwoOptionConfirmation(resources, view, child)
  local graphics = assert(resources.graphics, "the battle render borrows its host graphics")
  local assets = assert(resources.assets, "the battle render borrows its asset holder")
  local text = assert(resources.text, "the battle render borrows its text services")
  local pressed = BattleMenuPresenter.drawChildTwoOption(graphics, assets, view)
  local labels = assert(child.twoOption, "learning confirmation carries source-selected labels") --[[@as table<string, unknown>]]
  local top = assert(labels.top, "the top option has its staged source label") --[[@as string]]
  local bottom = assert(labels.bottom, "the bottom option has its staged source label") --[[@as string]]
  -- Source text objects sit eight pixels above their centered anchors; a
  -- pressed option raises its label two more pixels.
  local function drawOption(label, anchorY, optionId, palette)
    local y = anchorY - (pressed == optionId and 2 or 0) - 8
    drawRoleText(text, "menu", label, 128 - math.floor(measureRoleText(text, "menu", label) / 2), y, palette)
  end
  drawOption(top, 67, "yes", sourcePalette(view, "menu", 2, 1, 2, 3))
  drawOption(bottom, 139, "cancel", sourcePalette(view, "menu", 2, 10, 11, 12))
end

-- Interaction-pane control regions by menu layout; any other layout
-- keeps the command regions. Read-only: drawing never mutates them.
local INTERACTION_REGIONS = {
  moves = {
    { id = "move:0", x = 0, y = 24, w = 128, h = 56 },
    { id = "move:1", x = 128, y = 24, w = 128, h = 56 },
    { id = "move:2", x = 0, y = 88, w = 128, h = 56 },
    { id = "move:3", x = 128, y = 88, w = 128, h = 56 },
    { id = "cancel", x = 8, y = 152, w = 240, h = 40 },
  },
  target = {
    { id = "target:0", x = 0, y = 88, w = 121, h = 57 },
    { id = "target:1", x = 136, y = 8, w = 120, h = 73 },
    { id = "target:2", x = 136, y = 88, w = 120, h = 57 },
    { id = "target:3", x = 0, y = 8, w = 121, h = 73 },
    { id = "cancel", x = 8, y = 152, w = 240, h = 40 },
  },
  command = {
    { id = "fight", x = 0, y = 24, w = 256, h = 120 },
    { id = "bag", x = 0, y = 144, w = 80, h = 48 },
    { id = "pokemon", x = 176, y = 144, w = 80, h = 48 },
    { id = "run", x = 88, y = 152, w = 80, h = 40 },
  },
}

-- Menu layer sections by drawable menu layout.
local MENU_SECTIONS = { command = "command", moves = "moves", target = "target", ["two-option"] = "twoOption" }

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
---@param content table<string, unknown> canonical plan content carrying the layout
---@param placement LayoutGeometry.Placement resolved placement of the interaction pane
local function drawInteraction(resources, view, content, placement)
  if view.mode == "child" and type(view.childView) == "table" then
    local child = view.childView --[[@as table<string, unknown>]]
    if BattleRenderer.drawNativeChild(resources, child, placement) then
      return
    end
    if child.kind == "learn" and type(child.confirmation) == "table" then
      drawTwoOptionConfirmation(resources, view, child)
    else
      drawChild(resources, child)
    end
    return
  end
  local graphics = assert(resources.graphics, "the battle render borrows its host graphics")
  local assets = assert(resources.assets, "the battle render borrows its asset holder")
  local text = assert(resources.text, "the battle render borrows its text services")
  local layout = content.layout --[[@as string]]
  if MENU_SECTIONS[layout] == nil then
    layout = "command"
  end
  local menuLayers = assert(view.menuLayers, "the battle view carries generated menu screen layers")
  local layers = assert(menuLayers[MENU_SECTIONS[layout]], "the battle view carries layers for its selected menu") --[[@as table[] ]]
  local regions = INTERACTION_REGIONS[layout] or INTERACTION_REGIONS.command
  local menuWindows = type(view.menuWindows) == "table" and view.menuWindows or nil
  BattleMenuPresenter.draw(graphics, assets, layout, layers, view, menuWindows)
  local function drawOverlay()
    -- Multi-actor turns name the acting battler above the menu so staged
    -- choices are never mistaken for the previous entry's selection.
    local acting = BattleViewRoster.actingName(view)
    if acting ~= nil then
      drawRoleText(text, "menu", fitLabel(text, acting, 44, "menu"), 128, 8)
    end
    drawControls(resources, view, layout, regions)
    drawKeypadCursor(graphics, assets, view, layout, regions)
  end
  local revealEdge = view.menuRevealEdge
  if type(revealEdge) == "number" then
    LogicalSurface.clip(graphics, { x = 0, y = 0, width = 256, height = revealEdge }, drawOverlay)
  else
    drawOverlay()
  end
  drawGauges(resources, view)
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
  local players, enemies = BattleViewRoster.liveSides(view)
  local live = {}
  for _, side in ipairs({ players, enemies }) do
    for _, battler in ipairs(side) do
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
  end
  for _, spot in ipairs(spots) do
    local battler = live[spot.position]
    local image = battler ~= nil and battlerImage(assets, battler) or nil
    if image ~= nil then
      local dx = numberOr(battler.shakeDx, 0) + numberOr(battler.pictureXOffset, 0)
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

-- Draws one visible singles battler portrait at its compact center with
-- its transient shake.
---@param graphics table<string, unknown> injected host graphics
---@param assets table<string, unknown> injected asset holder
---@param battler table<string, unknown>? first battler facts on the side
---@param center table<string, number> compact image center under drawing
local function drawCompactSingle(graphics, assets, battler, center)
  if battler == nil or battler.visible == false then
    return
  end
  local image = battlerImage(assets, battler)
  if image ~= nil then
    drawArtwork(graphics, image, image.quad, center.x + numberOr(battler.shakeDx, 0), center.y)
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
  local viewport = type(content.scene) == "table" and content.scene or { x = 0, y = 0, width = 256, height = 136 }
  local playerCenter = type(content.playerCenter) == "table" and content.playerCenter or BattleRenderer.PLAYER_CENTER
  local enemyCenter = type(content.enemyCenter) == "table" and content.enemyCenter or BattleRenderer.ENEMY_CENTER
  -- Compact images use ordinary alpha composition under an isolated
  -- neutral image tint, then restore the caller's complete graphics state.
  graphics.push("all")
  graphics.setBlendMode("alpha", "alphamultiply")
  graphics.setColor(1, 1, 1, 1)
  LogicalSurface.clip(graphics, viewport, function()
    local scene = sceneLayer(resources, assets, view)
    if scene ~= nil then
      local scrollX, scrollY = bgScrollOf(view)
      drawSceneLayer(graphics, scene, scrollX, scrollY)
    end
    local spots = content.spriteCenters
    if type(spots) == "table" then
      drawCompactSlots(graphics, assets, view, spots --[[@as table<integer, table<string, unknown>>]])
    else
      local player, enemy = BattleViewRoster.firstPerSide(view)
      drawCompactSingle(graphics, assets, enemy, enemyCenter)
      drawCompactSingle(graphics, assets, player, playerCenter)
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
---@param placement LayoutGeometry.Placement resolved placement the pane draws under
function BattleRenderer.drawPane(resources, view, paneId, content, placement)
  assert(type(resources) == "table", "pane drawing borrows its resources")
  assert(type(view) == "table", "pane drawing reads its snapshot")
  if paneId == "compact" then
    drawCompactScene(resources, view, content or {})
  elseif paneId == "detail" then
    drawDetail(resources, view)
  elseif paneId == "interaction" then
    drawInteraction(resources, view, content or {}, placement)
  end
end

-- Compact battle reuses the native HUD cell at a fitted scale, so its
-- printer writes use the same staged digit tiles and font role through
-- the cell's source coordinates.
---@param graphics table<string, unknown>
---@param text table<string, unknown>
---@param assets table<string, unknown>
---@param view table<string, unknown>
---@param artKey string
---@param section table<string, unknown>
---@param objects table<integer, table<string, unknown>>
---@param battler table<string, unknown>
---@param sideType integer
---@param hpNumbers boolean
---@param transform { x: number, y: number, scale: number }
function BattleRenderer.drawCompactHudPrinters(
  graphics,
  text,
  assets,
  view,
  artKey,
  section,
  objects,
  battler,
  sideType,
  hpNumbers,
  transform
)
  drawHudPrinters(
    graphics,
    text,
    assets,
    view,
    artKey,
    section,
    { x = 0, y = 0 },
    objects,
    battler,
    sideType,
    hpNumbers,
    transform
  )
end

return BattleRenderer
