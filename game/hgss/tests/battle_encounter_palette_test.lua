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
    mainObj = {},
    mainObjPostFill = {},
    subBg = stagedBuffer(97),
    subObj = stagedBuffer(501),
    fill = FILL,
  }
  for index = 1, 224 do
    source.mainObj[index] = (409 + math.floor((index - 1) / 16) * 173 + (index - 1) * 7) % 32768
  end
  source.subBgOpaque = source.subBg
  source.subObjOpaque = source.subObj
  local initialSubBg = {}
  local initialSubObj = {}
  for index = 1, 255 do
    initialSubBg[index] = SUB_BG_CLEARED
    initialSubObj[index] = SUB_OBJ_CLEARED
  end
  initialSubBg[256] = source.subBg[256]
  initialSubObj[256] = source.subObj[256]
  source.initialDisplayed = { subBg = initialSubBg, subObj = initialSubObj }
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
      type(encounter[plane]) == "table" and #encounter[plane] == (plane == "mainObj" and 224 or 256),
      "the encounter palette carries its native source colors for " .. plane
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

function T.encounter_fade_keeps_the_filled_source_at_frame_ten()
  local source = stagedSource()
  source.mainBg[1] = 0
  source.mainObj[1] = 31 + 31 * 32 + 31 * 1024
  local palette = BattleEncounterPalette.new({
    battleType = "wild",
    source = source,
  })
  palette:tick(9)
  local frame9 = palette:snapshot()
  palette:tick(10)
  local frame10 = palette:snapshot()
  palette:tick(11)
  local frame11 = palette:snapshot()
  palette:tick(18)
  local frame18 = palette:snapshot()

  for _, plane in ipairs({ "mainBg", "mainObj" }) do
    Assert.equal(frame10[plane][1], frame9[plane][1], plane .. " keeps the setup fill at fade coefficient zero")
    Assert.equal(frame18[plane][1], source.fill, plane .. " reaches the native fade target at frame 18")
  end
  Assert.equal(
    frame11.mainBg[113],
    blendWord(source.mainBg[113], source.fill, 2),
    "frame 11 blends the post-fill opaque background from coefficient zero"
  )
  Assert.equal(
    frame11.mainObj[17],
    source.fill,
    "frame 11 keeps the post-fill opaque object at the scheduled fade origin"
  )
  Assert.equal(frame10.mainBg[161], frame9.mainBg[161], "unselected background bank 10 stays unchanged")
end

function T.encounter_object_palette_uses_native_buffer_size_and_each_color()
  local source = stagedSource()
  local objectColors = {}
  for index = 1, 224 do
    objectColors[index] = (index * 911) % 32768
  end
  source.mainObj = objectColors
  local palette = BattleEncounterPalette.new({ battleType = "wild", source = source })
  palette:tick(11)
  local faded = palette:snapshot().mainObj
  Assert.equal(#faded, 224, "the native object buffer has fourteen banks")
  Assert.equal(faded[34], source.fill, "object entry 33 starts from its native setup fill")
  Assert.equal(faded[38], source.fill, "object entry 37 starts from its native setup fill")
  Assert.equal(
    faded[224],
    blendWord(objectColors[224], source.fill, 2),
    "the unfilled final object entry blends its own color"
  )
  palette:tick(30)
  local restored = palette:snapshot().mainObj
  Assert.equal(
    restored[34],
    blendWord(objectColors[34], source.fill, 12),
    "restored object entry 33 blends its own color"
  )
  Assert.equal(
    restored[38],
    blendWord(objectColors[38], source.fill, 12),
    "restored object entry 37 blends its own color"
  )
  Assert.isFalse(
    pcall(function()
      palette:colorAt("mainObj", 224)
    end),
    "object index 224 is outside the native buffer"
  )
  local outOfRangeObjectColors = {}
  for index = 1, 224 do
    outOfRangeObjectColors[index] = objectColors[index]
  end
  outOfRangeObjectColors[225] = objectColors[224]
  local outOfRangeSource = {
    mainBg = source.mainBg,
    mainObj = outOfRangeObjectColors,
    mainObjPostFill = {},
    subBgOpaque = source.subBgOpaque,
    subObjOpaque = source.subObjOpaque,
    initialDisplayed = source.initialDisplayed,
    fill = source.fill,
  }
  Assert.isFalse(
    pcall(function()
      BattleEncounterPalette.new({ battleType = "wild", source = outOfRangeSource })
    end),
    "an object source slot beyond the native 224-slot range is rejected"
  )

  for battleType, restoreCount in pairs({
    wild = 64,
    trainer = 80,
    ["ordinary-doubles"] = 112,
    ["special-doubles"] = 80,
  }) do
    local restored = BattleEncounterPalette.new({ battleType = battleType, source = source })
    restored:tick(30)
    Assert.equal(
      restored:snapshot().mainObj[restoreCount],
      blendWord(objectColors[restoreCount], source.fill, 12),
      battleType .. " restores its native object span"
    )
  end
end

function T.main_object_palette_preserves_undefined_source_slots()
  local source = stagedSource()
  local sparseObject = {
    [1] = source.mainObj[1],
    [33] = source.mainObj[33],
    [224] = source.mainObj[224],
  }
  source.mainObj = sparseObject
  local palette = BattleEncounterPalette.new({ battleType = "wild", source = source })

  local initial = palette:snapshot().mainObj
  Assert.equal(initial[1], source.fill, "defined MAIN_OBJ slot 0 starts under the setup fill")
  Assert.equal(initial[33], source.fill, "defined MAIN_OBJ slot 32 starts under the setup fill")
  Assert.equal(initial[224], sparseObject[224], "defined MAIN_OBJ slot 223 is outside the setup fill")
  for _, index in ipairs({ 16, 63, 128 }) do
    Assert.isTrue(initial[index + 1] == nil, "undefined MAIN_OBJ slot " .. index .. " remains absent")
  end

  palette:tick(11)
  local opening = palette:snapshot().mainObj
  Assert.equal(opening[224], blendWord(sparseObject[224], source.fill, 2), "slot 223 fades from its own source")
  palette:tick(30)
  local restoring = palette:snapshot().mainObj
  Assert.equal(
    restoring[33],
    blendWord(sparseObject[33], source.fill, 12),
    "wild restore blends defined slot 32 from its saved source"
  )
  Assert.equal(
    restoring[224],
    blendWord(sparseObject[224], source.fill, 12),
    "slot 223 outside the wild restore span keeps its own source"
  )
  for _, index in ipairs({ 16, 63, 128 }) do
    Assert.isTrue(restoring[index + 1] == nil, "undefined MAIN_OBJ slot " .. index .. " remains absent after restore")
  end

  local ok, err = pcall(function()
    palette:colorAt("mainObj", 16)
  end)
  Assert.isFalse(ok, "sampling an undefined MAIN_OBJ slot fails")
  Assert.isTrue(
    string.find(tostring(err), "mainObj", 1, true) ~= nil and string.find(tostring(err), "16", 1, true) ~= nil,
    "undefined MAIN_OBJ failure identifies its plane and zero-based index"
  )

  palette:reset()
  local reset = palette:snapshot().mainObj
  Assert.equal(reset[1], source.fill, "reset restores the defined MAIN_OBJ fill state")
  Assert.equal(reset[224], sparseObject[224], "reset restores the defined unfilled MAIN_OBJ slot")
  Assert.isTrue(reset[17] == nil, "reset preserves undefined MAIN_OBJ slots")
end

function T.main_object_post_fill_palette_survives_opening_and_trainer_restore()
  local source = stagedSource()
  local trainerColor = 19 + 23 * 32 + 29 * 1024
  source.mainObj[81] = nil
  source.mainObjPostFill = { [81] = trainerColor }
  local palette = BattleEncounterPalette.new({ battleType = "trainer", source = source })

  palette:tick(10)
  Assert.equal(
    palette:snapshot().mainObj[81],
    trainerColor,
    "post-fill trainer palette overrides the setup fill at frame 10"
  )
  palette:tick(11)
  Assert.equal(
    palette:snapshot().mainObj[81],
    blendWord(trainerColor, source.fill, 2),
    "post-fill trainer palette participates in the opening fade"
  )
  palette:tick(36)
  Assert.equal(
    palette:snapshot().mainObj[81],
    trainerColor,
    "post-fill trainer palette at physical slot 80 survives the 80-word trainer backup restore"
  )

  local missingSource = stagedSource()
  missingSource.mainObjPostFill = nil
  Assert.isFalse(
    pcall(function()
      BattleEncounterPalette.new({ battleType = "trainer", source = missingSource })
    end),
    "the source must provide an explicit post-fill object palette table"
  )

  local collidingSource = stagedSource()
  collidingSource.mainObjPostFill = { [1] = trainerColor }
  Assert.isFalse(
    pcall(function()
      BattleEncounterPalette.new({ battleType = "trainer", source = collidingSource })
    end),
    "a post-fill palette slot cannot overlap a pre-fill source slot"
  )

  local restoredSource = stagedSource()
  restoredSource.mainObj[80] = nil
  restoredSource.mainObjPostFill = { [80] = trainerColor }
  Assert.isFalse(
    pcall(function()
      BattleEncounterPalette.new({ battleType = "trainer", source = restoredSource })
    end),
    "a post-fill palette slot cannot lie inside the native trainer restore span"
  )

  local outOfRangeSource = stagedSource()
  outOfRangeSource.mainObjPostFill = { [225] = trainerColor }
  Assert.isFalse(
    pcall(function()
      BattleEncounterPalette.new({ battleType = "trainer", source = outOfRangeSource })
    end),
    "a post-fill palette slot cannot exceed the native 224-slot range"
  )
end

function T.lower_palette_keeps_opaque_and_displayed_sources_separate()
  local source = stagedSource()
  local opaqueBg = stagedBuffer(801)
  local opaqueObj = stagedBuffer(1201)
  local displayedBg = stagedBuffer(1801)
  local displayedObj = stagedBuffer(2201)
  source.subBgOpaque = opaqueBg
  source.subObjOpaque = opaqueObj
  source.initialDisplayed = {
    subBg = displayedBg,
    subObj = displayedObj,
  }
  opaqueBg[256] = 9 + 4 * 32 + 17 * 1024
  opaqueObj[256] = 5 + 19 * 32 + 11 * 1024
  displayedBg[256] = 1 + 2 * 32 + 3 * 1024
  displayedObj[256] = 7 + 8 * 32 + 9 * 1024
  local palette = BattleEncounterPalette.new({ battleType = "wild", source = source })

  for _, frame in ipairs({ 1, 10, 25, 27 }) do
    palette:tick(frame)
    local snapshot = palette:snapshot()
    if frame >= 10 then
      Assert.equal(
        snapshot.subBg[1],
        grayWord(math.min(16, frame - 9)),
        "lower background follows the native gray ramp at frame " .. frame
      )
    else
      Assert.equal(snapshot.subBg[1], displayedBg[1], "initial lower background uses its displayed source")
    end
    Assert.equal(
      snapshot.subBg[256],
      frame < 10 and displayedBg[256] or snapshot.subBg[1],
      "lower background index 255 follows its displayed stage without an end-exclusive fill"
    )
    Assert.equal(snapshot.subObj[256], displayedObj[256], "lower object keeps its displayed source before restore")
  end

  palette:tick(28)
  Assert.equal(palette:snapshot().subBg[256], source.fill, "frame 28 fades opaque lower background from target")
  Assert.equal(palette:snapshot().subObj[256], source.fill, "frame 28 fades opaque lower objects from target")
  palette:tick(30)
  Assert.equal(
    palette:snapshot().subBg[256],
    blendWord(opaqueBg[256], source.fill, 12),
    "frame 30 reveals lower background from its own opaque source"
  )
  Assert.equal(
    palette:snapshot().subObj[256],
    blendWord(opaqueObj[256], source.fill, 12),
    "frame 30 reveals lower objects from their own opaque source"
  )
  Assert.equal(palette:snapshot().subBg[256], palette:colorAt("subBg", 255), "index 255 is sampled without overflow")
end

function T.sub_object_palette_preserves_undefined_source_slots()
  local source = stagedSource()
  local sparseOpaque = {}
  local sparseDisplayed = {}
  for _, index in ipairs({ 0, 17, 255 }) do
    sparseOpaque[index + 1] = source.subObjOpaque[index + 1]
    sparseDisplayed[index + 1] = source.initialDisplayed.subObj[index + 1]
  end
  source.subObjOpaque = sparseOpaque
  source.initialDisplayed.subObj = sparseDisplayed

  local palette = BattleEncounterPalette.new({ battleType = "wild", source = source })
  for _, frame in ipairs({ 0, 1, 28, 30 }) do
    if frame > 0 then
      palette:tick(frame)
    end
    local snapshot = palette:snapshot()
    Assert.equal(#snapshot.mainBg, 256, "main background remains a dense native palette")
    Assert.equal(#snapshot.mainObj, 224, "main object remains a dense native palette")
    Assert.equal(#snapshot.subBg, 256, "lower background remains a dense native palette")
    for _, index in ipairs({ 0, 17, 255 }) do
      Assert.isTrue(snapshot.subObj[index + 1] ~= nil, "defined lower object slot " .. index .. " remains present")
      local expected = sparseDisplayed[index + 1]
      if frame >= 28 then
        expected = blendWord(sparseOpaque[index + 1], source.fill, 16 - 2 * (frame - 28))
      end
      Assert.equal(snapshot.subObj[index + 1], expected, "defined lower object slot " .. index .. " follows its source")
    end
    for _, index in ipairs({ 1, 16, 254 }) do
      Assert.isTrue(snapshot.subObj[index + 1] == nil, "undefined lower object slot " .. index .. " remains absent")
    end
  end

  local ok, err = pcall(function()
    palette:colorAt("subObj", 16)
  end)
  Assert.isFalse(ok, "sampling an undefined lower object slot fails")
  Assert.isTrue(
    string.find(tostring(err), "subObj", 1, true) ~= nil and string.find(tostring(err), "16", 1, true) ~= nil,
    "undefined slot failure identifies its plane and zero-based index"
  )
end

function T.encounter_start_preserves_unfilled_background_and_transparent_slot()
  local source = stagedSource()
  local _, log = runOpening(true, 2)
  local palette = encounterPalette(log.opening[1])
  for index = 112, 159 do
    Assert.equal(
      palette.mainBg[index + 1],
      source.mainBg[index + 1],
      "main background color " .. index .. " keeps its staged source color"
    )
  end
  for index = 160, 191 do
    Assert.equal(
      palette.mainBg[index + 1],
      0,
      "main background color " .. index .. " keeps its displayed transparent clear"
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
      mainObjPostFill = source.mainObjPostFill,
      subBgOpaque = source.subBgOpaque,
      subObjOpaque = source.subObjOpaque,
      initialDisplayed = source.initialDisplayed,
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
  for _, index in ipairs({ 112, 120, 144, 152 }) do
    local staged = source.mainBg[index + 1]
    Assert.equal(
      palette.mainBg[index + 1],
      blendWord(staged, target, 2),
      "main background color " .. index .. " blends with integer five-bit math at coefficient 2"
    )
  end
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
  source.mainObj[41] = 101
  source.mainObj[42] = 1001
  local palette = BattleEncounterPalette.new({ battleType = "wild", source = source })
  palette:tick(30)
  local displayed = palette:snapshot()
  Assert.isTrue(
    displayed.mainObj[41] ~= displayed.mainObj[42],
    "two restored object entries keep their own RGB555 source words within one bank"
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
        source.initialDisplayed.subObj[index + 1],
        "lower object color " .. index .. " keeps its displayed setup value on frame " .. frame
      )
    end
  end
end

-- The late lower reveal runs on the same palette engine as the main
-- restore: two blend units per tick toward the staged fade color, so a
-- cave (black-fade) battle reveals from black, never from white.
function T.encounter_lower_reveal_matches_engine_rate_and_fade_color()
  local source = stagedSource()
  local palette = BattleEncounterPalette.new({
    battleType = "wild",
    source = {
      mainBg = source.mainBg,
      mainObj = source.mainObj,
      mainObjPostFill = source.mainObjPostFill,
      subBgOpaque = source.subBgOpaque,
      subObjOpaque = source.subObjOpaque,
      initialDisplayed = source.initialDisplayed,
      fill = 0,
    },
  })
  palette:tick(30)
  local blended = palette:snapshot()
  for _, index in ipairs({ 0, 40, 88, 200 }) do
    Assert.equal(
      blended.subBg[index + 1],
      blendWord(source.subBg[index + 1], 0, 12),
      "frame 30 lower background color " .. index .. " blends toward black at coefficient 12"
    )
    Assert.equal(
      blended.subObj[index + 1],
      blendWord(source.subObj[index + 1], 0, 12),
      "frame 30 lower object color " .. index .. " blends toward black at coefficient 12"
    )
  end
  palette:tick(36)
  local settled = palette:snapshot()
  for _, index in ipairs({ 0, 40, 88, 200 }) do
    Assert.equal(
      settled.subBg[index + 1],
      source.subBg[index + 1],
      "frame 36 lower background color " .. index .. " matches its staged buffer"
    )
    Assert.equal(
      settled.subObj[index + 1],
      source.subObj[index + 1],
      "frame 36 lower object color " .. index .. " matches its staged buffer"
    )
  end
end

-- The frame-50 late operation darkens only main background banks 10 and
-- 11 toward black on the same two-units-per-tick engine, leaving every
-- other bank and plane on its restored base.
function T.encounter_late_fade_darkens_only_background_banks_ten_and_eleven()
  local source = stagedSource()
  local palette = BattleEncounterPalette.new({
    battleType = "wild",
    source = {
      mainBg = source.mainBg,
      mainObj = source.mainObj,
      mainObjPostFill = source.mainObjPostFill,
      subBgOpaque = source.subBgOpaque,
      subObjOpaque = source.subObjOpaque,
      initialDisplayed = source.initialDisplayed,
      fill = source.fill,
    },
  })
  palette:tick(50)
  palette:beginLateFade()
  local armed = palette:snapshot()
  for _, index in ipairs({ 160, 175, 191 }) do
    Assert.equal(armed.mainBg[index + 1], 0, "frame 50 late background color " .. index .. " starts fully black")
  end
  Assert.equal(armed.mainBg[121], source.mainBg[121], "frame 50 bank 7 stays on its restored base under the late fade")
  Assert.equal(armed.mainBg[193], source.fill, "frame 50 bank 12 keeps its fill under the late fade")
  Assert.equal(
    armed.mainObj[41],
    source.mainObj[41],
    "frame 50 object colors stay on their restored base under the late fade"
  )
  palette:tick(54)
  local blended = palette:snapshot()
  for _, index in ipairs({ 160, 175, 191 }) do
    Assert.equal(
      blended.mainBg[index + 1],
      blendWord(source.mainBg[index + 1], 0, 8),
      "frame 54 late background color " .. index .. " blends toward black at coefficient 8"
    )
  end
  palette:tick(58)
  local settled = palette:snapshot()
  for _, index in ipairs({ 160, 175, 191 }) do
    Assert.equal(
      settled.mainBg[index + 1],
      source.mainBg[index + 1],
      "frame 58 late background color " .. index .. " returns to its staged buffer"
    )
  end
  palette:reset()
  palette:tick(60)
  Assert.equal(palette:snapshot().mainBg[161], 0, "reset clears the armed late fade")
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
