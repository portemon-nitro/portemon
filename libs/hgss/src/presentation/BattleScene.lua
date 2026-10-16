-- Battle visual-state owner for one screen lifetime. Holds the source
-- slot geometry, picture entry and presentation state, background scroll
-- and transient effect records behind semantic operations; pure helpers
-- expose the exact slot centers, tile-bar arithmetic and shadow geometry
-- the paired and compact renderers sample. Simulation facts, layout and
-- input stay with their existing owners: this module only tracks what is
-- currently visible and where it sits.
--
-- Native geometry and task vectors follow pret/pokeheartgold@9d8b7591:
-- overlay_07.s ov07_022377F4, battle_hp_bar.c source templates and tile
-- arithmetic, unk_0208805C.c CalculateHpBarPixelsLength/HpBar_GetColorIdx,
-- and pokepic.c draw/shadow placement.

---@class BattleScene.BackgroundLayer
---@field key string semantic effect layer identity
---@field rasterizer NitroBg3 mutable indexed BG3 layer
---@class BattleScene
---@field _entries table<string, { visible: boolean, phase: string, x?: number, targetX?: number, stepX?: number, wait?: integer }> source entry task by combatant and activation identity
---@field _opened boolean true once the first observation installed the opening positions
---@field _scroll { x: number, y: number } background viewport scroll in native pixels
---@field _scrollAccum number accepted seconds banked toward the next source tick
---@field _background table<string, unknown>? mutable launch-owned BG3 layer
---@field _backgroundRasterizer table<string, unknown>? lazily composed BG3 surface
---@field _backgroundLayers table<integer, BattleScene.BackgroundLayer> replacement BG3 states, newest active until removed
---@field _pictureAnimations table<string, table<string, unknown>> native Pokepic tasks by activation
---@field _pictureStates table<string, { base: table<string, unknown>, current: table<string, unknown>, animation?: table<string, unknown> }> activation-scoped appearance, transform and animation snapshot
---@field _gaugeTasks table<string, table<string, unknown>> source-ticked displayed gauge tasks
---@field _healthBoxModes table<string, { sideType: integer, mode: string }> double-player native health-box mode by activation
---@field _effects table<integer, { id: integer, sourceKey: string, age: integer, picture?: table<string, unknown> }> live transient effect records
---@field _nextEffect integer next transient effect identity
---@field _released boolean launch-scoped release guard
local BattleScene = {}
BattleScene.__index = BattleScene
local NitroBg3 = require("libs.nds.src.nitro.NitroBg3")

-- Nominal picture edge half inset: the final 80x80 image origin is the
-- adjusted center minus this inset (pokepic.c NNS_G2dDrawSpriteFast path).
BattleScene.PICTURE_HALF = 40

-- Native shadow quad geometry in native pixels, drawn at depth -1000
-- behind every picture plane (pokepic.c shadow draw).
BattleScene.SHADOW_WIDTH = 64
BattleScene.SHADOW_HEIGHT = 16
BattleScene.SHADOW_DEPTH = -1000

-- Native bar capacities in pixels: six 8-pixel health tiles and twelve
-- 8-pixel experience tiles (battle_hp_bar.c tilesWide 6 and 12).
BattleScene.HP_TILES = 6
BattleScene.HP_PIXELS = 48
BattleScene.EXP_TILES = 12
BattleScene.EXP_PIXELS = 96

-- Source component tile bases behind dynamic bar patching: the tile
-- graphic index is the color base plus the 0..8 fill level
-- (battle_hp_bar.c tile patch path).
BattleScene.HP_GREEN_BASE = 2
BattleScene.HP_YELLOW_BASE = 11
BattleScene.HP_RED_BASE = 20
BattleScene.EXP_BASE = 29

-- The pinned send-out task (ov12_0225B494) waits 0x1c controller updates;
-- one source route advances its managed sprite by eight pixels per update.
BattleScene.ENTRY_WAIT_TICKS = 0x1c
BattleScene.ENTRY_STEP_X = 8

-- One accepted source tick in seconds, shared with the battle envelope.
BattleScene.SOURCE_FRAME = 1 / 30

---@return BattleScene empty visual state for one screen lifetime
function BattleScene.new()
  return setmetatable({
    _entries = {},
    _opened = false,
    _scroll = { x = 0, y = 0 },
    _scrollAccum = 0,
    _background = nil,
    _backgroundRasterizer = nil,
    _backgroundLayers = {},
    _pictureAnimations = {},
    _pictureStates = {},
    _gaugeTasks = {},
    _healthBoxModes = {},
    _effects = {},
    _nextEffect = 1,
    _released = false,
  }, BattleScene)
end

---@param row table<string, number> native slot row under reading
---@return number settled center horizontal origin
---@return number settled center vertical origin
function BattleScene.settledCenter(row)
  assert(type(row) == "table", "slot geometry reads its row")
  return assert(row.settledX, "slot rows carry their settled center"), --[[@as number]]
    assert(row.settledY, "slot rows carry their settled row") --[[@as number]]
end

-- Resolves one live battler's native slot row. Records without a native
-- position keep the single-battle row of their side; doubled records
-- take their side's row by sorted slot order, so a surviving slot never
-- slides onto a hidden neighbor's row.
---@param battler table<string, unknown> displayed battler facts under reading
---@param order integer[]? canonical claimed positions of the battler side in slot order
---@param rows table<integer, table<string, number>> semantic geometry published by the producer
---@return table<string, number> native slot row
function BattleScene.slotRow(battler, order, rows)
  assert(type(battler) == "table", "slot geometry reads its battler")
  assert(type(rows) == "table", "slot geometry reads the published geometry rows")
  local bySideType = {}
  for _, row in ipairs(rows) do
    bySideType[row.sideType] = row
  end
  local singleType = battler.side == 1 and 0 or 1
  local doubleTypes = battler.side == 1 and { 2, 4 } or { 3, 5 }
  local position = battler.position
  if type(position) == "number" and type(order) == "table" then
    for index, slot in ipairs(order) do
      if slot == position then
        local sideType = doubleTypes[index]
        assert(sideType ~= nil, "doubled slot order covers every live battler")
        return assert(bySideType[sideType], "published geometry covers the selected double side type")
      end
    end
  end
  return assert(bySideType[singleType], "published geometry covers the selected single side type")
end

---@param centerX number native settled center horizontal origin
---@param centerY number native settled center vertical origin
---@param height number|nil signed height displacement, baseline when absent
---@return number nominal image left edge
---@return number nominal image top edge
function BattleScene.originFor(centerX, centerY, height)
  assert(type(centerX) == "number", "picture origins read their center")
  assert(type(centerY) == "number", "picture origins read their row")
  local displacement = 0
  if type(height) == "number" then
    displacement = height
  end
  return centerX - BattleScene.PICTURE_HALF, centerY - BattleScene.PICTURE_HALF - displacement
end

-- Resolves the compiler's source-normalized picture selector for one
-- canonical portrait asset selector. Shiny and plain images share the
-- same source geometry and animation table; front and back never do.
---@param manifest table<string, unknown> immutable battle presentation manifest
---@param selector string canonical mon portrait selector
---@return table<string, unknown>? source attributes, absent for planning manifests or malformed selectors
function BattleScene.pictureAttributes(manifest, selector)
  assert(type(manifest) == "table", "picture attributes read their presentation manifest")
  assert(type(selector) == "string", "picture attributes read their canonical portrait selector")
  local species, form, gender, variant, facing = selector:match("^([A-Z0-9_]+)/f(%d+)/([a-z]+)/([a-z]+)/([a-z]+)$")
  if species == nil then
    species, form, gender, variant = selector:match("^([A-Z0-9_]+)/f(%d+)/([a-z]+)/([a-z]+)$")
    facing = "front"
  end
  if
    species == nil
    or (gender ~= "male" and gender ~= "female")
    or (variant ~= "plain" and variant ~= "shiny")
    or (facing ~= "front" and facing ~= "back")
  then
    return nil
  end
  local pictures = manifest.pictures
  if type(pictures) ~= "table" then
    return nil
  end
  local key = "pokemon/" .. species .. "/form-" .. form .. "/" .. gender .. "/" .. facing
  local selectors = pictures.selectors --[[@as table<string, table<string, unknown>>?]]
  local attributes = pictures.attributes --[[@as table<string, table<string, unknown>>?]]
  if type(selectors) ~= "table" or type(attributes) ~= "table" then
    return nil
  end
  local sourceSelector = selectors[key]
  if sourceSelector == nil then
    return nil
  end
  assert(
    sourceSelector.species == species
      and sourceSelector.form == tonumber(form)
      and sourceSelector.gender == gender
      and sourceSelector.facing == facing,
    "source picture selector identity matches the canonical portrait"
  )
  local attributeKey = assert(sourceSelector.attributes, "source picture selectors name their attributes")
  local record = attributes[
    attributeKey --[[@as string]]
  ]
  assert(type(record) == "table", "source picture selectors resolve published attributes")
  return record
end

---@param centerX number native settled center horizontal origin
---@param centerY number native settled center vertical origin
---@return number shadow quad left edge
---@return number shadow quad top edge
function BattleScene.shadowOriginFor(centerX, centerY)
  assert(type(centerX) == "number", "shadow origins read their center")
  assert(type(centerY) == "number", "shadow origins read their row")
  return centerX - BattleScene.SHADOW_WIDTH / 2, centerY - BattleScene.SHADOW_HEIGHT / 2
end

-- Exact integer health pixels behind one checkpoint
-- (CalculateHpBarPixelsLength): integer division with the
-- minimum-visible-nonzero rule. The subpixel path (maxHp below capacity)
-- agrees exactly for settled checkpoints, since its fixed-point scale
-- cancels out of the final shift.
---@param hp unknown displayed health under reading
---@param maxHp unknown health ceiling under reading
---@return integer filled pixels in 0..48
function BattleScene.hpPixels(hp, maxHp)
  if type(hp) ~= "number" or type(maxHp) ~= "number" or maxHp <= 0 then
    return 0
  end
  local pixels = math.floor(hp * BattleScene.HP_PIXELS / maxHp)
  if pixels < 0 then
    pixels = 0
  elseif pixels > BattleScene.HP_PIXELS then
    pixels = BattleScene.HP_PIXELS
  end
  if pixels == 0 and hp > 0 then
    pixels = 1
  end
  return pixels
end

-- Exact color selection behind one pixel count (HpBar_GetColorIdx):
-- green above half capacity, yellow above one fifth, red above zero,
-- fainted at zero. Fixed-point compares keep the 9/10 boundary exact.
---@param pixels integer filled pixels under reading
---@return integer color index: 3 green, 2 yellow, 1 red, 0 fainted
function BattleScene.hpColorIdx(pixels)
  assert(type(pixels) == "number", "bar colors read their pixel count")
  local shifted = pixels * 256
  local wide = BattleScene.HP_PIXELS * 256
  if shifted > wide / 2 then
    return 3
  elseif shifted > math.floor(wide / 5) then
    return 2
  elseif shifted > 0 then
    return 1
  end
  return 0
end

---@param colorIdx integer color index from hpColorIdx under reading
---@return integer component tile base behind the bar tiles
function BattleScene.hpComponentBase(colorIdx)
  if colorIdx == 3 then
    return BattleScene.HP_GREEN_BASE
  elseif colorIdx == 2 then
    return BattleScene.HP_YELLOW_BASE
  end
  return BattleScene.HP_RED_BASE
end

-- Per-tile 0..8 fill levels behind one checkpoint
-- (BattleHpBar_Util_MakeHpBarPixelBuffer with settled values): full
-- tiles drain first, the minimum-visible rule seeds the first tile.
---@param hp unknown displayed health under reading
---@param maxHp unknown health ceiling under reading
---@return integer[] six fill levels
function BattleScene.hpTileFills(hp, maxHp)
  local pixels = BattleScene.hpPixels(hp, maxHp)
  local fills = { 0, 0, 0, 0, 0, 0 }
  local rest = pixels
  for index = 1, BattleScene.HP_TILES do
    if rest >= 8 then
      fills[index] = 8
      rest = rest - 8
    elseif rest > 0 then
      fills[index] = rest
      break
    else
      break
    end
  end
  return fills
end

-- Exact integer experience pixels behind one checkpoint
-- (BattleHpBar_Util_GetPixelsToGain settled form): integer division
-- over the level span, clamped to the twelve-tile capacity.
---@param into unknown progress within the level under reading
---@param span unknown level span under reading
---@return integer filled pixels in 0..96
function BattleScene.expPixels(into, span)
  if type(into) ~= "number" or type(span) ~= "number" or span <= 0 then
    return 0
  end
  local pixels = math.floor(into * BattleScene.EXP_PIXELS / span)
  if pixels < 0 then
    pixels = 0
  elseif pixels > BattleScene.EXP_PIXELS then
    pixels = BattleScene.EXP_PIXELS
  end
  return pixels
end

-- Per-tile 0..8 fill levels behind one experience checkpoint, using the
-- same settled pixel-buffer rule as health over twelve tiles.
---@param into unknown progress within the level under reading
---@param span unknown level span under reading
---@return integer[] twelve fill levels
function BattleScene.expTileFills(into, span)
  local pixels = BattleScene.expPixels(into, span)
  local fills = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  if pixels == 0 then
    return fills
  end
  local rest = pixels
  for index = 1, BattleScene.EXP_TILES do
    if rest >= 8 then
      fills[index] = 8
      rest = rest - 8
    else
      fills[index] = rest
      break
    end
  end
  return fills
end

-- Produces the six source character-buffer writes for one health-box side
-- type. Span starts are character-buffer tile indices emitted by C03.
---@param patchSpans table<string, unknown> normalized HUD patch map
---@param sideType integer native health-box side type
---@param hp unknown displayed health under reading
---@param maxHp unknown health ceiling under reading
---@return table<integer, { barIndex: integer, tile: integer, sourceTile: integer, fill: integer }> ordered character tile patches
function BattleScene.hpPatchTiles(patchSpans, sideType, hp, maxHp)
  assert(type(patchSpans) == "table", "health patches read the published patch map")
  assert(type(sideType) == "number" and sideType == math.floor(sideType), "health patches read a native side type")
  local record
  for _, candidate in
    ipairs(patchSpans.hp --[[@as table<integer, table<string, unknown>>]])
  do
    if candidate.sideType == sideType then
      record = candidate
      break
    end
  end
  local spans = assert(record, "the patch map covers the selected health-box side type").spans
  --[[@as table<integer, { tile: integer, count: integer }?>]]
  local fills = BattleScene.hpTileFills(hp, maxHp)
  local sourceBase = BattleScene.hpComponentBase(BattleScene.hpColorIdx(BattleScene.hpPixels(hp, maxHp)))
  local patches, barIndex = {}, 0
  for _, span in ipairs(spans) do
    for index = 0, span.count - 1 do
      barIndex = barIndex + 1
      patches[barIndex] = {
        barIndex = barIndex,
        tile = span.tile + index,
        sourceTile = sourceBase + fills[barIndex],
        fill = fills[barIndex],
      }
    end
  end
  assert(barIndex == BattleScene.HP_TILES, "health patch spans cover six displayed cells")
  return patches
end

-- Resolves source current/max HP numeral destinations inside one health-box
-- cell. The three character tiles in each span are the native printer window.
---@param patchSpans table<string, unknown> normalized HUD patch map
---@param sideType integer native health-box side type
---@return { current: table<integer, { tile: integer }>, maximum: table<integer, { tile: integer }> } HP numeral tiles
function BattleScene.hpNumberPatchTiles(patchSpans, sideType)
  assert(type(patchSpans) == "table", "HP numerals read the published patch map")
  assert(type(sideType) == "number" and sideType == math.floor(sideType), "HP numerals read a native side type")
  local function resolve(field)
    local record
    for _, candidate in
      ipairs(patchSpans[field] --[[@as table<integer, table<string, unknown>>]])
    do
      if candidate.sideType == sideType then
        record = candidate
        break
      end
    end
    local span = assert(record, "the patch map covers the selected health-box side type")
    assert(type(span.tile) == "number" and type(span.count) == "number", "HP numeral spans carry tile geometry")
    assert(span.count == 3, "native HP numeral windows contain three character tiles")
    return { { tile = span.tile }, { tile = span.tile + 1 }, { tile = span.tile + 2 } }
  end
  return { current = resolve("currentHp"), maximum = resolve("maximumHp") }
end

-- Produces the twelve source character-buffer writes for the experience
-- row; source spans split after the fifth cell.
---@param patchSpans table<string, unknown> normalized HUD patch map
---@param fills integer[] twelve fill levels from the displayed task
---@return table<integer, { barIndex: integer, tile: integer, sourceTile: integer, fill: integer }> ordered character tile patches
function BattleScene.expPatchTiles(patchSpans, fills)
  assert(type(patchSpans) == "table", "experience patches read the published patch map")
  assert(#fills == BattleScene.EXP_TILES, "experience patches cover twelve displayed cells")
  local patches, barIndex = {}, 0
  local spans = patchSpans.experience --[[@as table<integer, { tile: integer, count: integer }?>]]
  for _, span in ipairs(spans) do
    for index = 0, span.count - 1 do
      barIndex = barIndex + 1
      local fill = fills[barIndex]
      assert(fill >= 0 and fill <= 8 and fill == math.floor(fill), "experience tiles use native fill values")
      patches[barIndex] = {
        barIndex = barIndex,
        tile = span.tile + index,
        sourceTile = BattleScene.EXP_BASE + fill,
        fill = fill,
      }
    end
  end
  assert(barIndex == BattleScene.EXP_TILES, "experience patch spans cover twelve displayed cells")
  return patches
end

local HUD_STATUS_COMPONENT = {
  healthy = 38,
  paralysis = 47,
  freeze = 50,
  sleep = 53,
  poison = 44,
  burn = 41,
}
local HUD_GENDER_COMPONENT = {
  male = { 62, 63, 74, 75 },
  female = { 60, 61, 72, 73 },
  genderless = { 64, 65, 76, 77 },
}

-- Resolves source HUD icon component tiles and the native character-buffer
-- destinations. Tile spans are normalized by the ROM producer from the
-- battle_hp_bar.c write tables; the component ids follow
-- battle_hp_bar.c::ov12_0226498C/ov12_022652D0/ov12_02265560.
---@param patchSpans table<string, unknown> normalized native icon destinations
---@param sideType integer native health-box side type
---@param condition string? displayed major condition key
---@param gender string? displayed gender category
---@param caught boolean? native caught marker, when exposed by the event snapshot
---@return table<integer, { tile: integer, sourceTile: integer }> destination/source tile pairs
function BattleScene.hudIconPatchTiles(patchSpans, sideType, condition, gender, caught)
  assert(type(patchSpans) == "table", "HUD icons read the published patch map")
  assert(type(sideType) == "number" and sideType == math.floor(sideType), "HUD icons read a native side type")
  local patches = {}
  local function append(field, sourceTiles, required)
    local bySide = patchSpans[field]
    local spansBySide = nil
    for _, candidate in
      ipairs(bySide --[[@as table<integer, table<string, unknown>>]])
    do
      if candidate.sideType == sideType then
        spansBySide = candidate
        break
      end
    end
    assert(spansBySide ~= nil, "icon spans cover the selected side type")
    local spans = spansBySide.spans or (spansBySide.tile and { spansBySide } or spansBySide)
    local index = 0
    for _, span in ipairs(spans) do
      for offset = 0, span.count - 1 do
        local sourceTile = sourceTiles[index + 1]
        assert(sourceTile ~= nil, "source component art covers every native write tile")
        patches[#patches + 1] = { tile = span.tile + offset, sourceTile = sourceTile }
        index = index + 1
      end
    end
    assert(not required or index > 0, "visible icon fields have a source character span")
  end

  local status = condition == nil and HUD_STATUS_COMPONENT.healthy or HUD_STATUS_COMPONENT[condition]
  assert(status ~= nil, "displayed battle conditions have a native health-box icon")
  append("status", { status, status + 1, status + 2 }, true)
  if gender ~= nil then
    local component = HUD_GENDER_COMPONENT[gender]
    assert(component ~= nil, "displayed gender uses a native health-box icon")
    append("gender", component, true)
  end
  if caught ~= nil then
    assert(type(caught) == "boolean", "native caught marker is boolean")
    append("caught", { caught and 59 or 38 }, true)
  end
  return patches
end

-- Resolves the source double-player health-box character writes.
---@param patchSpans table<string, unknown> normalized native HUD patch map
---@param sideType integer double-player native side type
---@param mode string source health-box mode
---@return table<integer, { tile: integer, sourceTile: integer }> destination/source tile pairs
function BattleScene.healthBoxModePatchTiles(patchSpans, sideType, mode)
  assert(type(patchSpans) == "table", "health-box mode reads the published patch map")
  assert(sideType == 2 or sideType == 4, "health-box mode applies to a double-player row")
  assert(mode == "gauge" or mode == "numbers", "health-box mode is source selected")
  local records = patchSpans.playerDoubleMode
  assert(type(records) == "table", "manifest publishes double-player mode writes")
  for _, record in ipairs(records) do
    if record.sideType == sideType then
      local writes = assert(record[mode], "manifest publishes writes for the selected mode")
      local patches = {}
      for index, write in ipairs(writes) do
        patches[index] = { tile = write.tile, sourceTile = write.sourceTile }
      end
      return patches
    end
  end
  error("double-player health-box mode has no row for side type " .. tostring(sideType), 0)
end

---@param layers table<integer, BattleScene.BackgroundLayer> installed effect layers
---@param key string semantic effect layer identity
---@return BattleScene.BackgroundLayer installed effect layer
local function backgroundLayer(layers, key)
  for _, layer in ipairs(layers) do
    if layer.key == key then
      return layer
    end
  end
  error("unknown effect BG layer: " .. key, 0)
end

---@param battler table<string, unknown> displayed battler facts under reading
---@return string entry identity scoping the visual progress
local function entryKey(battler)
  return tostring(battler.combatant) .. ":" .. tostring(battler.activation)
end

local PICTURE_STATE_FIELDS = {
  portraitSelector = true,
  substitute = true,
  rotation = true,
  rotationX = true,
  rotationY = true,
  rotationZ = true,
  scaleX = true,
  scaleY = true,
  affineMode = true,
  affineWidth = true,
  affineHeight = true,
  pictureVisible = true,
  pictureXOffset2 = true,
  pictureYOffset2 = true,
  pictureWidth = true,
  pictureHeight = true,
  pictureYOffset = true,
  zOffset = true,
  shadowHeight = true,
  shadowSize = true,
  shadowAffine = true,
  shadowAdjustX = true,
  shadowAdjustY = true,
  shadowX = true,
  shadowY = true,
  shadowOffsetX = true,
  shadowOffsetY = true,
  shadowTint = true,
  vanished = true,
  dontDraw = true,
  pictureTint = true,
  polygonAlpha = true,
  paletteFade = true,
  shadowVisible = true,
}

local function copyPictureState(state)
  local copy = {}
  for key, value in pairs(state) do
    if (key == "pictureTint" or key == "shadowTint") and type(value) == "table" then
      copy[key] = { r = value.r, g = value.g, b = value.b, a = value.a }
    elseif key == "paletteFade" and type(value) == "table" then
      copy[key] = {
        intensity = value.intensity,
        current = value.current,
        finish = value.finish,
        delayCounter = value.delayCounter,
        delayLength = value.delayLength,
        targetColor = value.targetColor,
        active = value.active,
        applied = value.applied,
      }
    else
      copy[key] = value
    end
  end
  return copy
end

local function copyPictureTask(task)
  local loops = {}
  for index, count in ipairs(task.loops) do
    loops[index] = count
  end
  return {
    animation = task.animation,
    step = task.step,
    frame = task.frame,
    delay = task.delay,
    xOffset = task.xOffset,
    active = task.active,
    loops = loops,
  }
end

local function pictureStateFrom(record)
  local state = {}
  for key in pairs(PICTURE_STATE_FIELDS) do
    if record[key] ~= nil then
      state[key] = record[key]
    end
  end
  return state
end

-- Applies source-authored appearance and affine facts to one activation.
-- The first application saves its presented values so a later restore
-- can return to that exact appearance without changing simulation state.
---@param battler table<string, unknown> activation receiving source presentation data
---@param patch table<string, unknown> source picture attributes to apply
---@return table<string, unknown> detached immutable presentation view
function BattleScene:applyPictureState(battler, patch)
  assert(not self._released, "released scenes apply no picture state")
  assert(type(battler) == "table" and type(battler.combatant) == "number", "picture state uses an activation identity")
  assert(type(patch) == "table", "picture state reads source attributes")
  local key = entryKey(battler)
  assert(self._entries[key] ~= nil, "picture attributes target an installed activation")
  local owned = self._pictureStates[key]
  if owned == nil then
    local base = pictureStateFrom(battler)
    local animation = self._pictureAnimations[key]
    owned = {
      base = base,
      current = copyPictureState(base),
      animation = animation ~= nil and copyPictureTask(animation) or nil,
    }
    self._pictureStates[key] = owned
  end
  local current = copyPictureState(owned.current)
  for field, value in pairs(patch) do
    assert(PICTURE_STATE_FIELDS[field] == true, "picture state accepts only rendered appearance attributes")
    if field == "portraitSelector" then
      assert(type(value) == "string" and value ~= "", "picture appearance uses a canonical selector")
    elseif
      field == "substitute"
      or field == "shadowVisible"
      or field == "affineMode"
      or field == "pictureVisible"
      or field == "shadowAffine"
      or field == "shadowAdjustX"
      or field == "shadowAdjustY"
      or field == "vanished"
      or field == "dontDraw"
    then
      assert(type(value) == "boolean", "picture visibility attributes are boolean")
    elseif field == "rotation" or field == "scaleX" or field == "scaleY" then
      assert(type(value) == "number" and value == value, "picture affine attributes are finite numbers")
    elseif field == "rotationX" or field == "rotationY" or field == "rotationZ" then
      assert(
        type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 0xFFFF,
        "native picture rotation is a 16-bit angle index"
      )
    elseif
      field == "pictureXOffset2"
      or field == "pictureYOffset2"
      or field == "pictureWidth"
      or field == "pictureHeight"
    then
      assert(
        type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 0xFF,
        "visible picture crop fields are unsigned bytes"
      )
    elseif
      field == "pictureYOffset"
      or field == "shadowHeight"
      or field == "shadowX"
      or field == "shadowY"
      or field == "shadowOffsetX"
      or field == "shadowOffsetY"
    then
      assert(
        type(value) == "number" and value % 1 == 0 and value >= -0x8000 and value <= 0x7FFF,
        "picture vertical offsets are signed native pixel values"
      )
    elseif field == "shadowSize" then
      assert(
        type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 3,
        "Pokepic shadow size selects one native UV region"
      )
    elseif field == "zOffset" then
      assert(type(value) == "number" and value % 1 == 0, "picture depth offset uses native integer units")
    elseif field == "polygonAlpha" then
      assert(
        type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 31,
        "picture polygon alpha is a five-bit integer"
      )
    elseif field == "affineWidth" or field == "affineHeight" then
      assert(
        type(value) == "number" and value % 1 == 0 and value >= -32768 and value <= 32767,
        "picture affine dimensions are signed 16-bit 8.8 values"
      )
    end
    if field == "pictureTint" then
      assert(type(value) == "table", "picture tint is a normalized color record")
      for _, channel in ipairs({ "r", "g", "b", "a" }) do
        assert(
          type(value[channel]) == "number" and value[channel] >= 0 and value[channel] <= 1,
          "picture tint has four normalized numeric channels"
        )
      end
    end
    if field == "shadowTint" then
      assert(type(value) == "table", "shadow palette changes use an explicit color")
      for _, channel in ipairs({ "r", "g", "b", "a" }) do
        assert(
          type(value[channel]) == "number" and value[channel] >= 0 and value[channel] <= 1,
          "shadow color has four normalized channels"
        )
      end
    end
    if field == "paletteFade" then
      assert(type(value) == "table", "palette fades carry their source task parameters")
      assert(
        type(value.start) == "number" and value.start % 1 == 0 and value.start >= 0 and value.start <= 16,
        "palette fade start is a native blend coefficient"
      )
      assert(
        type(value.finish) == "number" and value.finish % 1 == 0 and value.finish >= 0 and value.finish <= 16,
        "palette fade end is a native blend coefficient"
      )
      assert(
        type(value.framesPer) == "number"
          and value.framesPer % 1 == 0
          and value.framesPer >= 0
          and value.framesPer <= 0xFF,
        "palette fade delay is an unsigned source byte"
      )
      assert(
        type(value.targetColor) == "number"
          and value.targetColor % 1 == 0
          and value.targetColor >= 0
          and value.targetColor <= 0x7FFF,
        "palette fade target is a native RGB555 color"
      )
      value = {
        intensity = value.start,
        current = value.start,
        finish = value.finish,
        delayCounter = 0,
        delayLength = value.framesPer,
        targetColor = value.targetColor,
        active = true,
        applied = false,
      }
    end
    current[field] = (field == "pictureTint" or field == "shadowTint") and copyPictureState({ [field] = value })[field]
      or value
  end
  owned.current = current
  return copyPictureState(current)
end

-- Returns a detached per-activation presentation view, if one is active.
---@param battler table<string, unknown> activation whose view is read
---@return table<string, unknown>? detached presentation view
function BattleScene:pictureState(battler)
  assert(not self._released, "released scenes expose no picture state")
  assert(type(battler) == "table" and type(battler.combatant) == "number", "picture state uses an activation identity")
  local owned = self._pictureStates[entryKey(battler)]
  return owned ~= nil and copyPictureState(owned.current) or nil
end

-- Restores the presentation snapshot captured by the first source patch.
---@param battler table<string, unknown> activation being restored
---@return table<string, unknown>? detached restored presentation snapshot
function BattleScene:restorePictureState(battler)
  assert(not self._released, "released scenes restore no picture state")
  assert(
    type(battler) == "table" and type(battler.combatant) == "number",
    "picture restore uses an activation identity"
  )
  local key = entryKey(battler)
  local owned = self._pictureStates[key]
  if owned == nil then
    return nil
  end
  owned.current = copyPictureState(owned.base)
  if owned.animation ~= nil then
    self._pictureAnimations[key] = copyPictureTask(owned.animation)
  else
    self._pictureAnimations[key] = nil
  end
  return copyPictureState(owned.base)
end

-- Observes displayed battlers without advancing or starting controller tasks.
-- Send-out policy calls startEntry at its source event boundary.
---@param battlers table<integer, table<string, unknown>> displayed battler facts under observation
function BattleScene:observe(battlers)
  assert(not self._released, "released scenes observe nothing")
  assert(type(battlers) == "table", "observation reads its displayed battlers")
  if not self._opened then
    if #battlers == 0 then
      return
    end
    for _, battler in ipairs(battlers) do
      if type(battler) == "table" and type(battler.combatant) == "number" then
        self._entries[entryKey(battler)] = { visible = battler.visible ~= false, phase = "complete" }
      end
    end
    self._opened = true
    return
  end
  for _, battler in ipairs(battlers) do
    if type(battler) == "table" and type(battler.combatant) == "number" then
      local key = entryKey(battler)
      local visible = battler.visible ~= false
      local known = self._entries[key]
      if known == nil then
        self._entries[key] = { visible = visible, phase = "complete" }
      elseif known.visible == true and not visible then
        known.visible = false
      end
    end
  end
end

-- Installs the native Pokepic task for an appearance and returns its
-- current frame/offset. The source script is immutable C03 data; task
-- timers and loop counters belong to this activation.
---@param battler table<string, unknown> displayed battler identity
---@param animation table<string, unknown> ten source PokepicAnimScript records
---@return { frame: integer, xOffset: integer, active: boolean, step: integer, delay: integer }
function BattleScene:picturePose(battler, animation)
  assert(not self._released, "released scenes expose no picture pose")
  assert(type(battler) == "table" and type(battler.combatant) == "number", "picture tasks use an activation identity")
  assert(
    type(animation) == "table" and type(animation.steps) == "table" and #animation.steps == 10,
    "picture tasks use ten source steps"
  )
  local key = entryKey(battler)
  local task = self._pictureAnimations[key]
  if task == nil or task.animation ~= animation then
    local first = animation.steps[1]
    local stopped = first.next == -1
    task = {
      animation = animation,
      step = 0,
      frame = stopped and 0 or first.next,
      delay = stopped and 0 or first.duration,
      xOffset = stopped and 0 or first.xOffset,
      active = not stopped,
      loops = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    }
    self._pictureAnimations[key] = task
  end
  return {
    frame = task.frame,
    xOffset = task.xOffset,
    active = task.active,
    step = task.step,
    delay = task.delay,
  }
end

---@param task table<string, unknown> native picture task under stepping
local function stepPictureTask(task)
  if task.active ~= true then
    return
  end
  local delay = task.delay --[[@as number]]
  if delay > 0 then
    task.delay = delay - 1
    return
  end
  local animation = task.animation --[[@as table<string, unknown>]]
  local steps = animation.steps --[[@as table[] ]]
  local stepIndex = task.step --[[@as number]] + 1
  while stepIndex < 10 do
    local step = steps[stepIndex + 1]
    if step.next >= -1 then
      break
    end
    local loops = task.loops --[[@as integer[] ]]
    local count = loops[stepIndex + 1] + 1
    loops[stepIndex + 1] = count
    if step.duration == 0 or count == step.duration then
      loops[stepIndex + 1] = 0
      stepIndex = stepIndex + 1
    else
      stepIndex = -2 - step.next
    end
  end
  task.step = stepIndex
  if stepIndex >= 10 or steps[stepIndex + 1].next == -1 then
    task.frame = 0
    task.active = false
    task.xOffset = 0
    task.delay = 0
    return
  end
  local step = steps[stepIndex + 1]
  task.frame = step.next
  task.delay = step.duration
  task.xOffset = step.xOffset
end

---@param fade table<string, unknown> native Pokepic palette-fade task
local function stepPaletteFade(fade)
  if fade.active ~= true then
    return
  end
  local delayCounter = fade.delayCounter --[[@as number]]
  if delayCounter > 0 then
    fade.delayCounter = delayCounter - 1
    return
  end
  local current = fade.current --[[@as number]]
  local finish = fade.finish --[[@as number]]
  fade.intensity = current
  fade.applied = true
  if current == finish then
    fade.active = false
  elseif current > finish then
    fade.current = current - 1
  else
    fade.current = current + 1
  end
  fade.delayCounter = fade.delayLength
end

-- Advances entry and effect tasks by exactly one accepted source tick.
function BattleScene:stepSourceTick()
  assert(not self._released, "released scenes step nothing")
  for _, entry in pairs(self._entries) do
    if entry.phase == "waiting" then
      if assert(entry.wait, "entry wait has its source counter") > 1 then
        entry.wait = entry.wait - 1
      else
        entry.wait = 0
        entry.phase = "moving"
      end
    end
    if entry.phase == "moving" then
      local x = entry.x + assert(entry.stepX, "entry task has its source movement step")
      local targetX = assert(entry.targetX, "entry task has its settled center")
      if (entry.stepX > 0 and x >= targetX) or (entry.stepX < 0 and x <= targetX) then
        entry.x = targetX
        entry.phase = "awaiting-completion"
      else
        entry.x = x
      end
    end
  end
  for _, effect in pairs(self._effects) do
    effect.age = effect.age + 1
  end
  for _, task in pairs(self._pictureAnimations) do
    stepPictureTask(task)
  end
  for _, state in pairs(self._pictureStates) do
    local fade = state.current.paletteFade
    if fade ~= nil then
      stepPaletteFade(fade)
    end
  end
  for _, task in pairs(self._gaugeTasks) do
    if task.active then
      local target = task.target --[[@as number]]
      local current = task.calc --[[@as number]]
      local amount = task.amount --[[@as number]]
      if task.fixedPoint then
        local now = current / 256
        if now == target and current % 256 == 0 then
          task.active = false
        else
          local perPixel = math.floor(
            task.maximum --[[@as number]]
              * 256
              / (
                task.tiles --[[@as number]]
                * 8
              )
          )
          if
            task.delta --[[@as number]]
            < 0
          then
            current = current + perPixel
            if math.floor(current / 256) >= target then
              current = target * 256
            end
          else
            current = current - perPixel
            if current % 256 > 0 then
              now = math.floor(current / 256) + 1
            else
              now = math.floor(current / 256)
            end
            if now <= target then
              current = target * 256
            end
          end
          task.calc = current
          if current == target * 256 then
            task.active = false
          end
        end
      else
        if current == target then
          task.active = false
        elseif
          task.delta --[[@as number]]
          < 0
        then
          task.calc = math.min(target, current + amount)
          if task.calc == target then
            task.active = false
          end
        else
          task.calc = math.max(target, current - amount)
          if task.calc == target then
            task.active = false
          end
        end
      end
    end
  end
end

---@param key string stable task identity under installation
---@param spec { maximum: number, current: number, delta: number, tiles: integer, amount: integer? } source gauge task inputs
function BattleScene:startGaugeTask(key, spec)
  assert(not self._released, "released scenes start no gauge tasks")
  assert(type(key) == "string" and key ~= "", "gauge tasks have a stable identity")
  assert(type(spec) == "table", "gauge tasks read their source parameters")
  assert(spec.maximum > 0 and spec.maximum == math.floor(spec.maximum), "gauge maximum is a positive integer")
  assert(spec.current == math.floor(spec.current), "gauge checkpoint is an integer")
  assert(spec.delta == math.floor(spec.delta), "gauge delta is an integer")
  assert(spec.tiles > 0 and spec.tiles == math.floor(spec.tiles), "gauge tile count is a positive integer")
  local current = math.max(0, math.min(spec.maximum, spec.current))
  local target = math.max(0, math.min(spec.maximum, current - spec.delta))
  local fixedPoint = spec.maximum < spec.tiles * 8
  local amount = spec.amount or 1
  assert(amount > 0 and amount == math.floor(amount), "gauge tick amount is a positive integer")
  self._gaugeTasks[key] = {
    maximum = spec.maximum,
    tiles = spec.tiles,
    delta = spec.delta,
    target = target,
    calc = fixedPoint and current * 256 or current,
    fixedPoint = fixedPoint,
    amount = amount,
    active = current ~= target,
  }
end

-- The source experience task chooses its per-update amount from the
-- integer pixel distance between the current and target checkpoints.
---@param key string stable task identity under installation
---@param spec { maximum: number, current: number, delta: number } source experience task inputs
function BattleScene:startExpGaugeTask(key, spec)
  assert(type(spec) == "table", "experience tasks read their source parameters")
  assert(spec.maximum > 0 and spec.maximum == math.floor(spec.maximum), "experience span is a positive integer")
  assert(spec.current == math.floor(spec.current), "experience checkpoint is an integer")
  assert(spec.delta == math.floor(spec.delta), "experience delta is an integer")
  local current = math.max(0, math.min(spec.maximum, spec.current))
  local target = math.max(0, math.min(spec.maximum, current - spec.delta))
  local currentPixels = math.floor(current * BattleScene.EXP_PIXELS / spec.maximum)
  local targetPixels = math.floor(target * BattleScene.EXP_PIXELS / spec.maximum)
  local pixelsToGain = math.abs(currentPixels - targetPixels)
  local amount = math.abs(math.modf(spec.delta / math.max(1, pixelsToGain)))
  if amount == 0 then
    amount = 1
  end
  self:startGaugeTask(key, {
    maximum = spec.maximum,
    current = current,
    delta = spec.delta,
    tiles = BattleScene.EXP_TILES,
    amount = amount,
  })
end

---@param key string stable task identity under reading
---@return boolean true when a gauge task is still moving
function BattleScene:gaugeTaskActive(key)
  local task = assert(self._gaugeTasks[key], "gauge task identity is installed")
  return task.active --[[@as boolean]]
end

-- Releases the task only after its owner has observed the final checkpoint.
---@param key string completed task identity
function BattleScene:completeGaugeTask(key)
  local task = assert(self._gaugeTasks[key], "gauge task identity is installed")
  assert(not task.active, "gauge tasks complete only after reaching their endpoint")
  self._gaugeTasks[key] = nil
end

---@param key string stable task identity under reading
---@return number displayed integer checkpoint
function BattleScene:gaugeTaskValue(key)
  local task = assert(self._gaugeTasks[key], "gauge task identity is installed")
  local calc = task.calc --[[@as number]]
  return task.fixedPoint and math.floor(calc / 256) or calc
end

---@param key string stable task identity under reading
---@return integer quantized source pixels
function BattleScene:gaugeTaskPixels(key)
  local task = assert(self._gaugeTasks[key], "gauge task identity is installed")
  local maximum = task.maximum --[[@as number]]
  local width = task.tiles --[[@as number]] * 8
  local calc = task.calc --[[@as number]]
  local pixels
  if task.fixedPoint then
    pixels = math.floor(math.floor(calc * width / maximum) / 256)
  else
    pixels = math.floor(calc * width / maximum)
  end
  if
    pixels == 0
    and task.target --[[@as number]]
      > 0
  then
    return 1
  end
  return math.max(0, math.min(width, pixels))
end

-- Turns the task's quantized pixel state into exact character-buffer
-- writes. The caller owns when a task is started and which displayed
-- event checkpoint it receives.
---@param patchSpans table<string, unknown> normalized HUD patch map
---@param key string stable task identity under reading
---@param sideType integer? native health-box side type; required for six-tile health rows
---@return table<integer, { barIndex: integer, tile: integer, sourceTile: integer, fill: integer }> ordered character tile patches
function BattleScene:gaugeTaskPatchTiles(patchSpans, key, sideType)
  local task = assert(self._gaugeTasks[key], "gauge task identity is installed")
  local tileCount = task.tiles --[[@as integer]]
  assert(tileCount == BattleScene.HP_TILES or tileCount == BattleScene.EXP_TILES, "gauge tasks use native bar widths")
  local pixels = self:gaugeTaskPixels(key)
  local fills, remaining = {}, pixels
  for index = 1, tileCount do
    fills[index] = math.min(8, remaining)
    remaining = remaining - fills[index]
  end
  if tileCount == BattleScene.HP_TILES then
    assert(sideType ~= nil, "health patch tasks identify their side type")
    local spanRecord
    for _, candidate in
      ipairs(patchSpans.hp --[[@as table<integer, table<string, unknown>>]])
    do
      if candidate.sideType == sideType then
        spanRecord = candidate
        break
      end
    end
    local spans = assert(spanRecord, "the patch map covers the selected health-box side type").spans
    --[[@as table<integer, { tile: integer, count: integer }?>]]
    local sourceBase = BattleScene.hpComponentBase(BattleScene.hpColorIdx(pixels))
    local patches, barIndex = {}, 0
    for _, span in ipairs(spans) do
      for index = 0, span.count - 1 do
        barIndex = barIndex + 1
        patches[barIndex] = {
          barIndex = barIndex,
          tile = span.tile + index,
          sourceTile = sourceBase + fills[barIndex],
          fill = fills[barIndex],
        }
      end
    end
    assert(barIndex == tileCount, "health patch spans cover the native gauge width")
    return patches
  end

  local patches, barIndex = {}, 0
  local spans = patchSpans.experience --[[@as table<integer, { tile: integer, count: integer }?>]]
  for _, span in ipairs(spans) do
    for index = 0, span.count - 1 do
      barIndex = barIndex + 1
      patches[barIndex] = {
        barIndex = barIndex,
        tile = span.tile + index,
        sourceTile = BattleScene.EXP_BASE + fills[barIndex],
        fill = fills[barIndex],
      }
    end
  end
  assert(barIndex == tileCount, "experience patch spans cover the native gauge width")
  return patches
end

-- Banks accepted seconds toward whole source ticks, stepping once per
-- tick so draws, polls and partial frames never advance the clock.
---@param dt number accepted seconds under banking
function BattleScene:advance(dt)
  assert(not self._released, "released scenes advance nothing")
  assert(type(dt) == "number" and dt == dt and dt >= 0, "scene updates take accepted seconds")
  self._scrollAccum = self._scrollAccum + dt
  while self._scrollAccum + 1e-12 >= BattleScene.SOURCE_FRAME do
    self._scrollAccum = self._scrollAccum - BattleScene.SOURCE_FRAME
    self:stepSourceTick()
  end
end

-- Returns the current source-controller X displacement for one battler.
-- The local controller waits 0x1c updates, steps X by eight pixels, then
-- snaps to the settled edge; the row supplies its direction and endpoint.
---@param battler table<string, unknown> displayed battler facts under reading
---@param row table<string, number> native slot row under reading
---@return number horizontal displacement in native pixels
---@return number vertical displacement in native pixels
function BattleScene:entryOffsetFor(battler, row)
  assert(type(battler) == "table", "entry reads its battler")
  assert(type(row) == "table", "entry reads its slot row")
  local known = nil
  if type(battler.combatant) == "number" then
    known = self._entries[entryKey(battler)]
  end
  if known == nil or known.phase == "complete" then
    return 0, 0
  end
  local settledX = assert(row.settledX, "slot rows carry their settled X") --[[@as number]]
  if known.x == nil then
    return 0, 0
  end
  return known.x - settledX, 0
end

-- Starts the visual part of the native send-out controller when orchestration
-- supplies its source-selected event and movement step.
---@param battler table<string, unknown> activation installed for send-out
---@param row table<string, number> source slot geometry
---@param stepX number signed source horizontal step in native pixels
function BattleScene:startEntry(battler, row, stepX)
  assert(not self._released, "released scenes start no entry task")
  assert(type(battler) == "table" and type(battler.combatant) == "number", "entry tasks use activation identity")
  assert(type(row) == "table", "entry tasks use source slot geometry")
  assert(type(stepX) == "number" and stepX % 1 == 0 and stepX ~= 0, "entry tasks use a signed integer source step")
  local key = entryKey(battler)
  local entry = assert(self._entries[key], "entry tasks target an installed activation")
  entry.visible = true
  entry.phase = "waiting"
  entry.x = assert(row.entryX, "slot geometry carries the spawn X")
  entry.targetX = assert(row.settledX, "slot geometry carries the settled X")
  entry.stepX = stepX
  entry.wait = BattleScene.ENTRY_WAIT_TICKS
end

-- Reports the visual controller phase for the orchestration completion gate.
---@param battler table<string, unknown> activation whose task is read
---@return string phase "waiting", "moving", "awaiting-completion", or "complete"
---@return integer remaining source wait ticks
function BattleScene:entryStatus(battler)
  assert(type(battler) == "table" and type(battler.combatant) == "number", "entry status uses activation identity")
  local entry = self._entries[entryKey(battler)]
  if entry == nil then
    return "complete", 0
  end
  return entry.phase, entry.wait or 0
end

-- Completes the visual controller only after orchestration observes every
-- source completion gate, including an optional follow-up task.
---@param battler table<string, unknown> activation whose task is completed
---@param readiness { battlerReady: boolean, pictureAnimationActive: boolean, followupTaskRequired: boolean, followupTaskComplete: boolean } detached controller observations
---@return boolean true when the entry task completed
function BattleScene:completeEntry(battler, readiness)
  assert(not self._released, "released scenes complete no entry task")
  assert(type(battler) == "table" and type(battler.combatant) == "number", "entry completion uses activation identity")
  assert(type(readiness) == "table", "entry completion receives source controller observations")
  assert(type(readiness.battlerReady) == "boolean", "entry completion carries battler readiness")
  assert(type(readiness.pictureAnimationActive) == "boolean", "entry completion carries picture task state")
  assert(type(readiness.followupTaskRequired) == "boolean", "entry completion carries the source follow-up flag")
  assert(type(readiness.followupTaskComplete) == "boolean", "entry completion carries follow-up task state")
  local entry = assert(self._entries[entryKey(battler)], "entry completion targets an installed activation")
  assert(entry.phase == "awaiting-completion", "entry movement reaches its source completion gate")
  if
    not readiness.battlerReady
    or readiness.pictureAnimationActive
    or (readiness.followupTaskRequired and not readiness.followupTaskComplete)
  then
    return false
  end
  entry.phase = "complete"
  entry.x = nil
  entry.targetX = nil
  entry.stepX = nil
  entry.wait = nil
  return true
end

-- Applies a source background scroll patch to the decoded layer state.
-- Values are native pixels; the layer draws shifted by their negation.
---@param x number horizontal scroll under patching
---@param y number vertical scroll under patching
function BattleScene:applyScrollPatch(x, y)
  assert(not self._released, "released scenes patch nothing")
  assert(type(x) == "number", "scroll patches carry their horizontal pixels")
  assert(type(y) == "number", "scroll patches carry their vertical pixels")
  self._scroll.x = x
  self._scroll.y = y
end

---@return { x: number, y: number } current background scroll in native pixels
function BattleScene:scroll()
  return { x = self._scroll.x, y = self._scroll.y }
end

-- Installs the staged BG3 payload without retaining mutable aliases to its
-- decoded map or palette. Character bytes are immutable and remain shared.
---@param payload { characters: string, map: { width: integer, height: integer, entries: table[] }, palette: { colors: table[] }, colorMode: "4bpp"|"8bpp" } staged BG3 layer
function BattleScene:installBackground(payload)
  assert(not self._released, "released scenes install nothing")
  assert(type(payload) == "table", "background installation takes staged payload")
  assert(type(payload.characters) == "string", "BG3 payload carries decoded character bytes")
  assert(payload.colorMode == "4bpp" or payload.colorMode == "8bpp", "BG3 payload declares character encoding")
  assert(type(payload.map) == "table" and type(payload.map.entries) == "table", "BG3 payload carries its map")
  assert(
    type(payload.palette) == "table" and type(payload.palette.colors) == "table",
    "BG3 payload carries its palette"
  )
  local entries = {}
  for index, entry in ipairs(payload.map.entries) do
    entries[index] = {
      tile = entry.tile,
      flipH = entry.flipH,
      flipV = entry.flipV,
      palette = entry.palette,
    }
  end
  local colors = {}
  for index, color in ipairs(payload.palette.colors) do
    colors[index] = { r = color.r, g = color.g, b = color.b }
  end
  self._background = {
    characters = payload.characters,
    colorMode = payload.colorMode,
    map = { width = payload.map.width, height = payload.map.height, entries = entries },
    palette = { colors = colors },
  }
  self._backgroundRasterizer = nil
end

-- Patches one zero-based SCRN entry, matching the source hardware index.
---@param index integer zero-based tilemap entry
---@param entry table<string, unknown> normalized BG3 map entry
function BattleScene:patchBackgroundMap(index, entry)
  assert(not self._released, "released scenes patch nothing")
  assert(type(index) == "number" and index % 1 == 0 and index >= 0, "map patches use nonnegative source indices")
  assert(type(entry) == "table", "map patches carry normalized entries")
  local background = assert(self._background, "map patches require an installed BG3 layer")
  local map = background.map --[[@as table<string, unknown>]]
  local entries = map.entries --[[@as table[] ]]
  assert(entries[index + 1] ~= nil, "map patch index lies within the staged tilemap")
  assert(
    type(entry.tile) == "number" and entry.tile % 1 == 0 and entry.tile >= 0 and entry.tile < 1024,
    "map patches carry a 10-bit tile index"
  )
  assert(
    type(entry.palette) == "number" and entry.palette % 1 == 0 and entry.palette >= 0 and entry.palette < 16,
    "map patches carry a 4-bit palette bank"
  )
  assert(type(entry.flipH) == "boolean" and type(entry.flipV) == "boolean", "map patches carry both flip bits")
  entries[index + 1] = { tile = entry.tile, flipH = entry.flipH, flipV = entry.flipV, palette = entry.palette }
  if self._backgroundRasterizer ~= nil then
    self._backgroundRasterizer:patchMap(index, entry)
  end
end

-- Patches one zero-based RGB888 palette entry.
---@param index integer zero-based color index
---@param color table<string, unknown> RGB888 color
function BattleScene:patchBackgroundPalette(index, color)
  assert(not self._released, "released scenes patch nothing")
  assert(type(index) == "number" and index % 1 == 0 and index >= 0, "palette patches use nonnegative source indices")
  assert(type(color) == "table", "palette patches carry RGB colors")
  local background = assert(self._background, "palette patches require an installed BG3 layer")
  local palette = background.palette --[[@as table<string, unknown>]]
  local colors = palette.colors --[[@as table[] ]]
  assert(colors[index + 1] ~= nil, "palette patch index lies within the staged palette")
  for _, channel in ipairs({ color.r, color.g, color.b }) do
    assert(
      type(channel) == "number" and channel % 1 == 0 and channel >= 0 and channel <= 255,
      "RGB888 channels are bytes"
    )
  end
  colors[index + 1] = { r = color.r, g = color.g, b = color.b }
  if self._backgroundRasterizer ~= nil then
    self._backgroundRasterizer:patchPalette(index, color)
  end
end

-- Supplies a detached read snapshot to the local compositor.
---@return table<string, unknown> BG3 payload after source patches
function BattleScene:background()
  local background = assert(self._background, "BG3 access requires an installed layer")
  local entries = {}
  for index, entry in
    ipairs(background.map.entries --[[@as table[] ]])
  do
    entries[index] = { tile = entry.tile, flipH = entry.flipH, flipV = entry.flipV, palette = entry.palette }
  end
  local colors = {}
  for index, color in
    ipairs(background.palette.colors --[[@as table[] ]])
  do
    colors[index] = { r = color.r, g = color.g, b = color.b }
  end
  return {
    characters = background.characters,
    colorMode = background.colorMode,
    map = { width = background.map.width, height = background.map.height, entries = entries },
    palette = { colors = colors },
  }
end

-- Replaces the active BG3 content with one decoded effect load. Removing
-- it restores the prior BG3 payload; color index zero stays transparent to
-- lower hardware planes, never to the old content of the replaced plane.
---@param key string semantic layer identity from the staged effect
---@param payload { character: { depth: integer, tiles: string }, screen: { width: integer, height: integer, entries: table[] }, palette: { colors: table[] } } decoded BG3 slots selected by the animation instruction
function BattleScene:installBackgroundLayer(key, payload)
  assert(not self._released, "released scenes install no layers")
  assert(type(key) == "string" and key ~= "", "effect layers carry a semantic key")
  for _, layer in ipairs(self._backgroundLayers) do
    assert(layer.key ~= key, "effect layer keys are unique within the scene")
  end
  assert(payload.character.depth == 3, "battle effect backgrounds use 4bpp tiled characters")
  assert(type(payload.character.tiles) == "string", "effect BG character slots carry packed tile bytes")
  local screen = payload.screen
  local base = assert(self._background, "effect layers require the persistent BG3 scene")
  local baseMap = base.map --[[@as table<string, unknown>]]
  assert(screen.width == baseMap.width and screen.height == baseMap.height, "effect layers share the native canvas")
  self._backgroundLayers[#self._backgroundLayers + 1] = {
    key = key,
    rasterizer = NitroBg3.new({
      characters = payload.character.tiles,
      map = screen,
      palette = payload.palette,
      colorMode = "4bpp",
      transparentZero = true,
    }),
  }
end

-- Removes a launch-owned effect layer without changing the persistent BG3.
---@param key string semantic layer identity from the staged effect
function BattleScene:removeBackgroundLayer(key)
  assert(not self._released, "released scenes remove no layers")
  for index, layer in ipairs(self._backgroundLayers) do
    if layer.key == key then
      table.remove(self._backgroundLayers, index)
      return
    end
  end
  error("unknown effect BG layer: " .. key, 0)
end

-- Applies a source-indexed patch to one installed effect layer.
---@param key string semantic layer identity from the staged effect
---@param index integer zero-based SCRN entry
---@param entry table<string, unknown> normalized map entry
function BattleScene:patchBackgroundLayerMap(key, index, entry)
  assert(not self._released, "released scenes patch no layers")
  local layer = backgroundLayer(self._backgroundLayers, key)
  layer.rasterizer:patchMap(index, entry)
end

-- Applies a source-indexed palette patch to one installed effect layer.
---@param key string semantic layer identity from the staged effect
---@param index integer zero-based palette color
---@param color table<string, unknown> RGB888 color
function BattleScene:patchBackgroundLayerPalette(key, index, color)
  assert(not self._released, "released scenes patch no layers")
  local layer = backgroundLayer(self._backgroundLayers, key)
  layer.rasterizer:patchPalette(index, color)
end

---@return table<string, unknown> active BG3 raster
function BattleScene:backgroundRaster()
  local active = self._backgroundLayers[#self._backgroundLayers]
  if active ~= nil then
    return active.rasterizer:render()
  end
  if self._backgroundRasterizer == nil then
    local background = self:background()
    self._backgroundRasterizer = NitroBg3.new({
      characters = background.characters,
      map = background.map,
      palette = background.palette,
      colorMode = background.colorMode,
      transparentZero = false,
    })
  end
  return self._backgroundRasterizer:render()
end

---@return boolean true when a staged BG3 layer is installed
function BattleScene:hasBackground()
  return self._background ~= nil
end

-- Installs one activation's visual record explicitly: unseen hidden
-- arrivals arm their entry, everything else installs settled.
---@param battler table<string, unknown> displayed battler facts under installing
function BattleScene:install(battler)
  assert(not self._released, "released scenes install nothing")
  assert(type(battler) == "table" and type(battler.combatant) == "number", "install takes its battler")
  local key = entryKey(battler)
  if self._entries[key] == nil then
    local visible = battler.visible ~= false
    self._entries[key] = { visible = visible, phase = "complete" }
    self._opened = true
  end
end

-- Applies the controller-selected double-player health-box mode to one activation.
---@param battler table<string, unknown> active player activation
---@param sideType integer native side type 2 or 4
---@param mode string source health-box mode
function BattleScene:setHealthBoxMode(battler, sideType, mode)
  assert(not self._released, "released scenes update no health-box modes")
  assert(type(battler) == "table" and type(battler.combatant) == "number", "health-box mode names its activation")
  assert(self._entries[entryKey(battler)] ~= nil, "health-box mode updates an installed activation")
  assert(battler.side == 1, "double-player health-box mode applies to a player activation")
  assert(sideType == 2 or sideType == 4, "health-box mode names a double-player row")
  assert(mode == "gauge" or mode == "numbers", "health-box mode uses a source state")
  self._healthBoxModes[entryKey(battler)] = { sideType = sideType, mode = mode }
end

---@param battler table<string, unknown> active activation whose mode is read
---@return string current source health-box mode
function BattleScene:healthBoxMode(battler)
  assert(not self._released, "released scenes expose no health-box mode")
  assert(type(battler) == "table" and type(battler.combatant) == "number", "health-box mode reads its activation")
  local state = self._healthBoxModes[entryKey(battler)]
  return state ~= nil and state.mode or "gauge"
end

---@param battler table<string, unknown> active activation whose row is read
---@return integer? source side type when an explicit mode is installed
function BattleScene:healthBoxModeSideType(battler)
  assert(not self._released, "released scenes expose no health-box row")
  assert(type(battler) == "table" and type(battler.combatant) == "number", "health-box mode reads its activation")
  local state = self._healthBoxModes[entryKey(battler)]
  return state ~= nil and state.sideType or nil
end

-- Removes one activation's visual record; unknown identities stay silent.
---@param combatant integer combatant identity under removing
---@param activation unknown activation identity under removing
function BattleScene:remove(combatant, activation)
  assert(not self._released, "released scenes remove nothing")
  assert(type(combatant) == "number", "removal takes its combatant")
  self._entries[tostring(combatant) .. ":" .. tostring(activation)] = nil
  self._pictureAnimations[tostring(combatant) .. ":" .. tostring(activation)] = nil
  self._pictureStates[tostring(combatant) .. ":" .. tostring(activation)] = nil
  self._healthBoxModes[tostring(combatant) .. ":" .. tostring(activation)] = nil
end

-- Allocates one launch-scoped transient effect instance behind a
-- concrete record. Effect visuals stay with their kind owner; the scene
-- only tracks the lifetime.
---@param sourceKey string semantic source route under allocating
---@return { id: integer, sourceKey: string, age: integer } owned effect record
function BattleScene:allocEffect(sourceKey)
  assert(not self._released, "released scenes allocate nothing")
  assert(type(sourceKey) == "string" and sourceKey ~= "", "effects allocate under their source key")
  local record = { id = self._nextEffect, sourceKey = sourceKey, age = 0 }
  self._effects[record.id] = record
  self._nextEffect = self._nextEffect + 1
  return record
end

-- Assigns one staged picture to a launch-owned effect slot. The effect
-- producer owns its animation policy and chooses the staged resource;
-- this scene only carries native placement and appearance into rendering.
---@param id integer live effect identity under updating
---@param picture { assetKey: string, selector: string, centerX: number, centerY: number, zCenter: number, width: number, height: number, alpha: number, rotationX?: integer, rotationY?: integer, rotationZ?: integer, tintR?: number, tintG?: number, tintB?: number, paletteFade?: table<string, unknown> } staged picture state
function BattleScene:setEffectPicture(id, picture)
  assert(not self._released, "released scenes update no effects")
  assert(type(picture) == "table", "transient pictures carry staged state")
  local record = assert(self._effects[id], "transient pictures target a live effect")
  assert(type(picture.assetKey) == "string" and picture.assetKey ~= "", "transient pictures name a staged drawable")
  assert(
    type(picture.selector) == "string" and picture.selector ~= "",
    "transient pictures carry their launch selector"
  )
  for _, field in ipairs({ "centerX", "centerY", "zCenter", "width", "height", "alpha" }) do
    assert(type(picture[field]) == "number", "transient pictures carry numeric " .. field)
  end
  assert(picture.width > 0 and picture.height > 0, "transient pictures have visible dimensions")
  assert(picture.alpha >= 0 and picture.alpha <= 1, "transient picture alpha is normalized")
  local copy = {}
  for key, value in pairs(picture) do
    if type(value) == "table" then
      local nested = {}
      for nestedKey, nestedValue in pairs(value) do
        nested[nestedKey] = nestedValue
      end
      copy[key] = nested
    else
      copy[key] = value
    end
  end
  record.picture = copy
end

-- Publishes detached effect records in launch allocation order.
---@return table<integer, { id: integer, sourceKey: string, age: integer, picture?: table<string, unknown> }> renderable effect snapshot
function BattleScene:effectViews()
  local ids = {}
  for id in pairs(self._effects) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local views = {}
  for _, id in ipairs(ids) do
    local record = self._effects[id]
    local picture = nil
    if record.picture ~= nil then
      picture = {}
      for key, value in pairs(record.picture) do
        if type(value) == "table" then
          local nested = {}
          for nestedKey, nestedValue in pairs(value) do
            nested[nestedKey] = nestedValue
          end
          picture[key] = nested
        else
          picture[key] = value
        end
      end
    end
    views[#views + 1] = { id = record.id, sourceKey = record.sourceKey, age = record.age, picture = picture }
  end
  return views
end

-- Releases one transient effect instance exactly once; unknown or
-- repeated identities stay silent.
---@param id integer effect identity under releasing
function BattleScene:releaseEffect(id)
  assert(not self._released, "released scenes release nothing")
  self._effects[id] = nil
end

-- Launch-scoped idempotent release: owned entry and effect records drop
-- exactly once, borrowed layers stay usable.
function BattleScene:release()
  if self._released then
    return
  end
  self._released = true
  self._entries = {}
  self._effects = {}
  self._background = nil
  self._backgroundRasterizer = nil
  self._backgroundLayers = {}
  self._pictureAnimations = {}
  self._pictureStates = {}
  self._gaugeTasks = {}
  self._healthBoxModes = {}
end

return BattleScene
