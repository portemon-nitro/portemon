-- Native encounter fades resolve per-plane RGB555 palette banks instead of
-- washing the composed frame: the main background/object buffers start from
-- the staged source colors with the background fill applied to its source
-- ranges, masked fades advance two blend units per accepted tick with integer
-- five-bit BlendColor math, the lower screen ramps its own gray buffer apart
-- from lower object pixels, and a late background bank operation touches only
-- banks 10 and 11. 3D particle geometry keeps its own plane throughout.

local Assert = require("tests.support.Assert")
local BattleEncounterPalette = require("game.hgss.src.battle.BattleEncounterPalette")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
local BattleTimelineFixture = require("game.hgss.tests.support.BattleTimelineFixture")
local FakeGraphics = require("tests.support.FakeGraphics")
local SourceTick = require("libs.hgss.src.field.SourceTick")

local T = {}
local TICK = SourceTick.DT

local FILL = 24 + 12 * 32 + 3 * 1024
local SUB_BG_CLEARED = 0
local SUB_OBJ_CLEARED = 31 + 31 * 32 + 31 * 1024
local GRAY_UNIT = 1 + 1 * 32 + 1 * 1024
local MAIN_BG_MASK = 62463
local MAIN_OBJ_MASK = 16383
local LATE_BG_MASK = 3072

---@param word integer RGB555 word under test
---@return integer r five-bit red component
---@return integer g five-bit green component
---@return integer b five-bit blue component
local function splitWord(word)
  local r = word % 32
  local g = math.floor(word / 32) % 32
  local b = math.floor(word / 1024) % 32
  return r, g, b
end

---@param source integer five-bit source component
---@param target integer five-bit target component
---@param coefficient integer blend units from 0 to 16
---@return integer blended five-bit component
local function blendComponent(source, target, coefficient)
  return source + math.floor(((target - source) * coefficient) / 16)
end

---@param source integer RGB555 source word
---@param target integer RGB555 target word
---@param coefficient integer blend units from 0 to 16
---@return integer blended RGB555 word
local function blendWord(source, target, coefficient)
  local sr, sg, sb = splitWord(source)
  local tr, tg, tb = splitWord(target)
  return blendComponent(sr, tr, coefficient)
    + blendComponent(sg, tg, coefficient) * 32
    + blendComponent(sb, tb, coefficient) * 1024
end

---@param step integer gray ramp step from 1 to 16
---@return integer RGB555 gray word for the lower background buffer
local function grayWord(step)
  return math.floor((31 * step) / 16) * GRAY_UNIT
end

---@param index integer zero-based source color index
---@return integer containing sixteen-color bank
local function bankOf(index)
  return math.floor(index / 16)
end

---@param mask integer sixteen-bit bank selector
---@param bank integer bank under test
---@return boolean true while the mask selects the bank
local function maskSelects(mask, bank)
  return math.floor(mask / (2 ^ bank)) % 2 == 1
end

---@param seed integer bank-distinct seed word
---@return table synthetic 256-entry RGB555 source buffer with distinct banks
local function stagedBuffer(seed)
  local buffer = {}
  for index = 0, 255 do
    local bank = bankOf(index)
    buffer[index + 1] = (seed + bank * 173 + index * 7) % 32768
  end
  return buffer
end

---@return table staged source buffers with an equal-RGB pair across two banks
local function stagedSource()
  local source = {
    mainBg = stagedBuffer(11),
    mainObj = stagedBuffer(409),
    subBg = stagedBuffer(97),
    subObj = stagedBuffer(501),
    fill = FILL,
  }
  local shared = 7 + 13 * 32 + 29 * 1024
  source.mainObj[41] = shared
  source.mainObj[89] = shared
  source.mainBg[1] = SUB_BG_CLEARED
  source.subBg[1] = SUB_BG_CLEARED
  source.subObj[1] = SUB_OBJ_CLEARED
  return source
end

---@param wild boolean true for a wild encounter, false for a trainer battle
---@param ticks integer fixed ticks to advance
---@return table timeline, table log per-tick presentation facts
local function runOpening(wild, ticks)
  local sounds = {}
  local timeline = BattleTimelineFixture.new({
    encounterFadeColor = "white",
    sound = function(cue)
      if type(cue) == "table" and cue.kind == "effect" then
        sounds[#sounds + 1] = true
      end
    end,
  })
  local view = {
    round = 1,
    status = "running",
    own = {
      {
        combatant = 1,
        participant = 1,
        side = 1,
        controller = "player",
        active = true,
        position = 1,
        activation = 1,
        hp = 20,
        maxHp = 20,
        species = "EEVEE",
        form = 0,
        name = "LEAD",
        level = 5,
      },
    },
    foes = {
      {
        combatant = 3,
        participant = 3,
        side = 2,
        controller = wild and "wild" or "trainer:3",
        active = true,
        position = 3,
        activation = 3,
        hp = 20,
        maxHp = 20,
        species = "CHIKORITA",
        form = 0,
        name = "FOE",
        level = 5,
      },
    },
    participants = {},
  }
  timeline:reset(view)
  timeline:intro(view, wild)
  local log = { flash = {}, lower = {}, frame = {}, opening = {} }
  for tick = 1, ticks do
    timeline:update(TICK, function(_)
      return true
    end)
    local opening = timeline:openingPresentation() or {}
    log.flash[tick] = opening.encounterFlash
    log.lower[tick] = opening.encounterLower
    log.frame[tick] = opening.encounterFrame
    log.opening[tick] = opening
  end
  return timeline, log
end

---@param opening table encounter opening presentation under test
---@return table palette per-plane source palette buffers
local function encounterPalette(opening)
  local encounter = assert(
    type(opening) == "table" and opening.encounterPalette,
    "the encounter publishes its per-plane source palette buffers; only an RGBA splash exists"
  )
  assert(type(encounter) == "table", "the encounter palette arrives as a record")
  for _, plane in ipairs({ "mainBg", "mainObj", "subBg", "subObj" }) do
    assert(
      type(encounter[plane]) == "table" and #encounter[plane] == 256,
      "the encounter palette carries 256 source colors for " .. plane
    )
  end
  return encounter
end

---@param flash table|nil recorded main fade state
---@return table graphics fake graphics that drew the detail pane
local function drawDetailPane(flash)
  local graphics = FakeGraphics.new()
  local view = {
    battlers = {},
    effectInstances = {},
    hudPatchSpans = {},
    message = "",
    textPalettes = { narration = { colors = {} } },
    openingPresentation = {
      playerTrainerVisible = false,
      foeTrainerVisible = false,
      encounterFlash = flash,
    },
  }
  BattleRenderer.drawPane({
    graphics = graphics,
    text = { drawTextForRole = function() end },
    windows = { drawWindow = function() end },
    assets = {
      drawable = function()
        return {}
      end,
    },
    frameKey = "default",
    sceneImageKey = "scene:test",
  }, view, "detail", {})
  return graphics
end

---@param lower table|nil recorded lower fade state
---@return table graphics fake graphics that drew the interaction pane
local function drawChildInteractionPane(lower)
  local graphics = FakeGraphics.new()
  local view = {
    mode = "child",
    childView = { kind = "bag", empty = true },
    openingPresentation = {
      playerTrainerVisible = false,
      foeTrainerVisible = false,
      encounterLower = lower,
    },
  }
  BattleRenderer.drawPane({
    graphics = graphics,
    text = { drawText = function() end },
    windows = { drawWindow = function() end },
    assets = {
      drawable = function()
        return nil
      end,
    },
    frameKey = "default",
  }, view, "interaction", {}, nil)
  return graphics
end

---@param graphics table fake graphics under test
---@return table fullscreen 256x192 fill rectangles in draw order
local function fullscreenRectangles(graphics)
  local found = {}
  for _, record in ipairs(graphics.rectangles) do
    if record.mode == "fill" and record.x == 0 and record.y == 0 and record.w == 256 and record.h == 192 then
      found[#found + 1] = record
    end
  end
  return found
end

function T.encounter_start_fills_main_buffers_from_the_background_fill_color()
  local source = stagedSource()
  local _, log = runOpening(true, 2)
  local palette = encounterPalette(log.opening[1])
  for index = 0, 111 do
    Assert.equal(palette.mainBg[index + 1], source.fill, "main background color " .. index .. " takes the fill")
  end
  for index = 192, 255 do
    Assert.equal(palette.mainBg[index + 1], source.fill, "main background color " .. index .. " takes the fill")
  end
  for index = 0, 222 do
    Assert.equal(palette.mainObj[index + 1], source.fill, "main object color " .. index .. " takes the fill")
  end
end

function T.encounter_start_preserves_unfilled_background_and_transparent_slot()
  local source = stagedSource()
  local _, log = runOpening(true, 2)
  local palette = encounterPalette(log.opening[1])
  for index = 112, 191 do
    Assert.equal(
      palette.mainBg[index + 1],
      source.mainBg[index + 1],
      "main background color " .. index .. " keeps its staged source color"
    )
  end
  Assert.equal(palette.mainObj[224], source.mainObj[224], "main object index 223 stays untouched by the fill")
end

function T.encounter_restore_returns_saved_background_and_wild_object_ranges()
  local source = stagedSource()
  local _, log = runOpening(true, 40)
  local flash28 = assert(log.flash[28], "the second blend starts on frame 28")
  Assert.equal(flash28.coefficient, 16, "the frame 28 fade holds blend coefficient 16")
  local blended = encounterPalette(log.opening[30])
  for index = 0, 111 do
    Assert.equal(
      blended.mainBg[index + 1],
      blendWord(source.mainBg[index + 1], source.fill, 12),
      "frame 30 main background color " .. index .. " blends the restored base at coefficient 12"
    )
  end
  for index = 0, 63 do
    Assert.equal(
      blended.mainObj[index + 1],
      blendWord(source.mainObj[index + 1], source.fill, 12),
      "frame 30 restored wild main object color " .. index .. " blends the restored base at coefficient 12"
    )
  end
  for _, frame in ipairs({ 36, 40 }) do
    local palette = encounterPalette(log.opening[frame])
    for index = 0, 111 do
      Assert.equal(
        palette.mainBg[index + 1],
        source.mainBg[index + 1],
        "frame " .. frame .. " main background color " .. index .. " matches the saved buffer"
      )
    end
    for index = 0, 63 do
      Assert.equal(
        palette.mainObj[index + 1],
        source.mainObj[index + 1],
        "frame " .. frame .. " restored wild main object color " .. index .. " matches the saved buffer"
      )
    end
  end
end

function T.encounter_restore_returns_trainer_object_range()
  local source = stagedSource()
  local _, log = runOpening(false, 40)
  local blended = encounterPalette(log.opening[30])
  for index = 0, 79 do
    Assert.equal(
      blended.mainObj[index + 1],
      blendWord(source.mainObj[index + 1], source.fill, 12),
      "frame 30 restored trainer main object color " .. index .. " blends the restored base at coefficient 12"
    )
  end
  for _, frame in ipairs({ 36, 40 }) do
    local palette = encounterPalette(log.opening[frame])
    for index = 0, 79 do
      Assert.equal(
        palette.mainObj[index + 1],
        source.mainObj[index + 1],
        "frame " .. frame .. " restored trainer main object color " .. index .. " matches the saved buffer"
      )
    end
  end
end

function T.encounter_restore_returns_ordinary_doubles_object_range()
  local source = stagedSource()
  local palette = BattleEncounterPalette.new({
    battleType = "ordinary-doubles",
    source = {
      mainBg = source.mainBg,
      mainObj = source.mainObj,
      subBg = source.subBg,
      subObj = source.subObj,
      fill = source.fill,
    },
  })
  palette:tick(1)
  Assert.equal(palette:snapshot().mainObj[1], source.fill, "doubles objects start under the background fill")
  palette:tick(30)
  local blended = palette:snapshot()
  for index = 0, 111 do
    Assert.equal(
      blended.mainBg[index + 1],
      blendWord(source.mainBg[index + 1], source.fill, 12),
      "frame 30 doubles main background color " .. index .. " blends the restored base at coefficient 12"
    )
    Assert.equal(
      blended.mainObj[index + 1],
      blendWord(source.mainObj[index + 1], source.fill, 12),
      "frame 30 doubles main object color " .. index .. " blends the restored base at coefficient 12"
    )
  end
  palette:tick(36)
  local snapshot = palette:snapshot()
  for index = 0, 111 do
    Assert.equal(
      snapshot.mainBg[index + 1],
      source.mainBg[index + 1],
      "frame 36 doubles main background color " .. index .. " matches the saved buffer"
    )
    Assert.equal(
      snapshot.mainObj[index + 1],
      source.mainObj[index + 1],
      "frame 36 doubles main object color " .. index .. " matches the saved buffer"
    )
  end
  Assert.equal(
    palette:colorAt("mainObj", 111),
    source.mainObj[112],
    "the doubles restore reaches object index 111 through its source bank"
  )
  palette:reset()
  Assert.equal(palette:snapshot().mainObj[1], source.fill, "reset restores the background fill after a canceled intro")
end

function T.encounter_main_fade_advances_two_blend_units_per_tick()
  local _, log = runOpening(true, 20)
  local expected = { 0, 2, 4, 6, 8, 10, 12, 14, 16 }
  for offset, coefficient in ipairs(expected) do
    local flash = assert(log.flash[9 + offset], "the main fade runs on frame " .. (9 + offset))
    Assert.equal(
      flash.coefficient,
      coefficient,
      "the frame " .. (9 + offset) .. " fade holds blend coefficient " .. coefficient
    )
  end
end

function T.encounter_main_fade_uses_integer_five_bit_blends()
  local source = stagedSource()
  local _, log = runOpening(true, 12)
  local palette = encounterPalette(log.opening[11])
  local target = source.fill
  for _, index in ipairs({ 0, 40, 88, 200 }) do
    local staged = source.mainBg[index + 1]
    Assert.equal(
      palette.mainBg[index + 1],
      blendWord(staged, target, 2),
      "main background color " .. index .. " blends with integer five-bit math at coefficient 2"
    )
  end
end

function T.encounter_lower_ramp_uses_five_bit_gray_steps()
  local _, log = runOpening(true, 11)
  local graphics = drawChildInteractionPane(log.lower[10])
  local washes = fullscreenRectangles(graphics)
  Assert.notNil(washes[1], "the first lower ramp frame paints the lower background plane")
  local expected = (grayWord(1) % 32) / 31
  Assert.near(washes[1].color[1], expected, 0.5 / 31, "the frame 10 lower gray matches five-bit step 1")
  Assert.near(washes[1].color[2], expected, 0.5 / 31, "the frame 10 lower gray is neutral")
  Assert.near(washes[1].color[3], expected, 0.5 / 31, "the frame 10 lower gray is neutral")
end

function T.encounter_main_fade_names_its_selected_bank_masks()
  local _, log = runOpening(true, 12)
  local flash = assert(log.flash[10], "the main fade runs on frame 10")
  Assert.equal(flash.mainBgMask, MAIN_BG_MASK, "the frame 10 main background fade selects banks 0xF3FF")
  Assert.equal(flash.mainObjMask, MAIN_OBJ_MASK, "the frame 10 main object fade selects banks 0x3FFF")
  Assert.isTrue(maskSelects(MAIN_BG_MASK, 9), "bank 9 stays selected under the background mask")
  Assert.isFalse(maskSelects(MAIN_BG_MASK, 10), "bank 10 stays excluded under the background mask")
  Assert.isFalse(maskSelects(MAIN_BG_MASK, 11), "bank 11 stays excluded under the background mask")
  Assert.isTrue(maskSelects(MAIN_BG_MASK, 12), "bank 12 stays selected under the background mask")
  Assert.isFalse(maskSelects(MAIN_OBJ_MASK, 14), "object bank 14 stays excluded under the object mask")
end

function T.encounter_late_fade_targets_only_background_banks_ten_and_eleven()
  local _, log = runOpening(true, 55)
  local opening = assert(log.opening[50], "the encounter still publishes presentation at frame 50")
  local late = assert(
    opening.encounterFlash or opening.encounterPalette,
    "the late 0x0C00 background bank operation exists at frame 50"
  )
  local mask = late.mainBgMask or late.lateBgMask
  Assert.equal(mask, LATE_BG_MASK, "the late background fade selects only banks 10 and 11")
  Assert.isFalse(maskSelects(LATE_BG_MASK, 9), "the late fade leaves bank 9 alone")
  Assert.isTrue(maskSelects(LATE_BG_MASK, 10), "the late fade selects bank 10")
  Assert.isTrue(maskSelects(LATE_BG_MASK, 11), "the late fade selects bank 11")
  Assert.isFalse(maskSelects(LATE_BG_MASK, 12), "the late fade leaves bank 12 alone")
end

function T.encounter_main_fade_does_not_wash_the_composed_scene()
  local graphics = drawDetailPane({ color = "white", coefficient = 8 })
  Assert.isTrue(#graphics.draws > 0, "the detail pane stages its scene art under the encounter fade")
  local washed = false
  for _, record in ipairs(fullscreenRectangles(graphics)) do
    if record.color[1] == record.color[2] and record.color[2] == record.color[3] and record.color[4] > 0 then
      washed = true
    end
  end
  Assert.isFalse(washed, "no fullscreen wash paints over the composed scene and particle planes")
end

function T.encounter_object_pixels_resolve_their_source_bank_per_pixel()
  local source = stagedSource()
  Assert.equal(source.mainObj[41], source.mainObj[89], "the fixture stages equal RGB in banks 2 and 5")
  local _, log = runOpening(true, 12)
  local palette = encounterPalette(log.opening[11])
  Assert.isTrue(
    palette.mainObj[41] ~= palette.mainObj[89],
    "a bank-2-only fade separates equal staged colors by source index, never by color"
  )
end

function T.encounter_lower_ramp_keeps_object_pixels_on_their_own_buffer()
  local source = stagedSource()
  local _, log = runOpening(true, 28)
  for _, frame in ipairs({ 10, 20, 27 }) do
    local palette = encounterPalette(log.opening[frame])
    for index = 0, 255 do
      Assert.equal(
        palette.subBg[index + 1],
        grayWord(math.min(16, frame - 9)),
        "lower background color " .. index .. " follows the gray ramp on frame " .. frame
      )
      Assert.equal(
        palette.subObj[index + 1],
        source.subObj[index + 1],
        "lower object color " .. index .. " keeps its own buffer on frame " .. frame
      )
    end
  end
end

function T.encounter_lower_reveal_fades_planes_without_a_uniform_wash()
  local _, log = runOpening(true, 30)
  local graphics = drawChildInteractionPane(log.lower[28])
  local washes = fullscreenRectangles(graphics)
  local uniformWhite = false
  for _, record in ipairs(washes) do
    if record.color[1] == 1 and record.color[2] == 1 and record.color[3] == 1 and record.color[4] > 0 then
      uniformWhite = true
    end
  end
  Assert.isFalse(uniformWhite, "the lower reveal fades background and object planes without one white wash")
end

return { tests = T }
