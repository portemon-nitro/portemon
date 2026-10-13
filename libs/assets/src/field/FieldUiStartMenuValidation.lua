-- Validation for the generated field-UI Start Menu manifest section.
local Checks = require("libs.assets.src.field.FieldUiManifestChecks")

local reject = Checks.reject
local checkInteger = Checks.checkInteger
local checkRect = Checks.checkRect
local checkAtlasRect = Checks.checkAtlasRect
local demandCount = Checks.demandCount
local checkSpriteVisual = Checks.checkSpriteVisual
local VALID_ICON_ARTS = { sprite = true, text = true, poke_icon = true }
local VALID_ICON_LABEL_KINDS = { static = true, player_name = true }
local ICON_STATES = { "normal", "selected" }
local NAV_DIRECTIONS = { "up", "down", "left", "right" }
local RGB_CHANNELS = { "r", "g", "b" }
local CURSOR_PLAY_MODES = { forward = true, forward_loop = true, reverse = true, reverse_loop = true }

local function checkStartMenuCursor(cursor, atlases, asset)
  if type(cursor) ~= "table" or type(cursor.frames) ~= "table" or #cursor.frames < 1 then
    reject("startMenu.cursor must carry at least one frame", {})
  end
  if CURSOR_PLAY_MODES[cursor.playMode] ~= true then
    reject("startMenu.cursor playMode is invalid", {})
  end
  checkInteger(cursor.loopStartFrameIdx, 0, #cursor.frames - 1, "startMenu.cursor loop start is outside its frames", {})
  local cycleDuration = 0
  for _, frameEntry in ipairs(cursor.frames) do
    checkAtlasRect(frameEntry, atlases, asset.START_MENU_CURSOR, "start menu cursor frame")
    checkInteger(frameEntry.duration, 0, nil, "cursor frame duration must be a non-negative integer", {})
    cycleDuration = cycleDuration + frameEntry.duration
    local offset = frameEntry.offset
    if type(offset) ~= "table" then
      reject("start menu cursor frame offset must be a record", {})
    end
    checkInteger(offset.x, nil, nil, "start menu cursor frame x offset must be an integer", {})
    checkInteger(offset.y, nil, nil, "start menu cursor frame y offset must be an integer", {})
  end
  if cycleDuration == 0 then
    reject("start menu cursor animation must advance", {})
  end
  if cursor.playMode == "forward_loop" or cursor.playMode == "reverse_loop" then
    local loopDuration = 0
    if cursor.playMode == "forward_loop" then
      for index = cursor.loopStartFrameIdx + 1, #cursor.frames do
        loopDuration = loopDuration + cursor.frames[index].duration
      end
    else
      for index = 1, cursor.loopStartFrameIdx + 1 do
        loopDuration = loopDuration + cursor.frames[index].duration
      end
    end
    if loopDuration == 0 then
      reject("start menu cursor loop must advance", {})
    end
  end
end

local function checkStartMenuIconRow(row, index, atlases)
  if type(row) ~= "table" then
    reject("startMenu.iconTable row " .. index .. " must be a table", {})
  end
  if VALID_ICON_ARTS[row.art] ~= true then
    reject("startMenu.iconTable row " .. index .. " art is invalid", {})
  end
  if row.art == "sprite" then
    for _, key in ipairs(ICON_STATES) do
      local visual = type(row.visual) == "table" and row.visual[key] or nil
      checkSpriteVisual(visual, atlases, "start menu icon row " .. index .. " " .. key .. " visual")
    end
  end
  checkInteger(row.label, 0, nil, "startMenu.iconTable row " .. index .. " label must be a label-bank id", {})
  if VALID_ICON_LABEL_KINDS[row.labelKind] ~= true then
    reject("startMenu.iconTable row " .. index .. " labelKind is invalid", {})
  end
  if row.variants ~= nil then
    if type(row.variants) ~= "table" then
      reject("startMenu.iconTable row " .. index .. " variants must be a table", {})
    end
    demandCount(row.variants, 1, "startMenu.iconTable row " .. index .. " carries only the female variant", {})
    if type(row.variants.female) ~= "table" then
      reject("startMenu.iconTable row " .. index .. " carries only the female variant", {})
    end
    for _, key in ipairs(ICON_STATES) do
      checkSpriteVisual(
        row.variants.female[key],
        atlases,
        "start menu icon row " .. index .. " female " .. key .. " visual"
      )
    end
  end
end

local function checkStartMenuIconTable(iconTable, atlases)
  if type(iconTable) ~= "table" then
    reject("startMenu.iconTable must be a table", {})
  end
  demandCount(iconTable, 13, "startMenu.iconTable must carry all thirteen retail rows", {})
  for index = 1, 13 do
    checkStartMenuIconRow(iconTable[index], index, atlases)
  end
end

local function checkStartMenuIconPalette(palette, pokeIcons, atlases)
  if type(palette) ~= "table" or type(palette.asset) ~= "string" or atlases[palette.asset] == nil then
    reject("startMenu.iconPalette must reference an indexed asset", {})
  end
  if
    type(palette.banks) ~= "number"
    or palette.banks % 1 ~= 0
    or palette.banks < 1
    or type(palette.selectionBank) ~= "number"
    or palette.selectionBank % 1 ~= 0
    or palette.selectionBank < 1
    or palette.selectionBank > palette.banks
  then
    reject("startMenu.iconPalette banks are invalid", {})
  end
  if pokeIcons ~= nil then
    if type(pokeIcons) ~= "table" or type(pokeIcons.asset) ~= "string" or atlases[pokeIcons.asset] == nil then
      reject("startMenu.pokeIcons must reference an indexed asset", {})
    end
  end
end

local function checkStartMenuContexts(contexts, iconTable)
  if type(contexts) ~= "table" then
    reject("startMenu.contexts must be a table", {})
  end
  demandCount(contexts, 7, "startMenu.contexts must carry all seven retail rows", {})
  for index = 1, 7 do
    local row = contexts[index]
    if type(row) ~= "table" then
      reject("startMenu.contexts row " .. index .. " must be a table", {})
    end
    demandCount(row, 7, "startMenu.contexts row " .. index .. " must map one icon per sprite slot", {})
    for slot = 1, 7 do
      local icon = row[slot]
      if icon ~= false then
        if type(icon) ~= "number" or icon % 1 ~= 0 or icon < 0 or icon > 12 or iconTable[icon + 1] == nil then
          reject("startMenu.contexts row " .. index .. " entry " .. slot .. " is invalid", {})
        end
      end
    end
  end
end

local function checkStartMenuActionIcons(actionIcons, iconTable)
  if type(actionIcons) ~= "table" then
    reject("startMenu.actionIcons must be a table", {})
  end
  for actionId, icon in pairs(actionIcons) do
    if type(actionId) ~= "string" then
      reject("startMenu.actionIcons keys must be action ids", {})
    end
    local row = type(icon) == "number" and iconTable[icon + 1] or nil
    if row == nil or row.art ~= "sprite" then
      reject("startMenu.actionIcons " .. actionId .. " must map to a sprite icon row", {})
    end
  end
end

-- The normal interactive selector: exactly the seven source positions 0..6,
-- each carrying its action anchor, label window, touch hit rectangle, and
-- four ordered three-candidate navigation lists, plus the cancel/header hit
-- rectangle. Anchors are integral canonical points; label and hit rectangles
-- stay inside the canonical 256x192 surface; every candidate names a normal
-- position.

local function checkStartMenuInteractivePosition(record, position)
  if type(record) ~= "table" then
    reject("startMenu.interactive position " .. position .. " must be a table", {})
  end
  if
    type(record.anchor) ~= "table"
    or type(record.anchor.x) ~= "number"
    or record.anchor.x % 1 ~= 0
    or type(record.anchor.y) ~= "number"
    or record.anchor.y % 1 ~= 0
  then
    reject("startMenu.interactive position " .. position .. " anchor must be an integral point", {})
  end
  local labelWhat = "start menu position " .. position .. " label window"
  checkRect(record.labelWindow, labelWhat, 256, 192, labelWhat .. " must stay inside the 256x192 surface", {
    what = labelWhat,
  })
  local hitWhat = "start menu position " .. position .. " hit rectangle"
  checkRect(record.hitRect, hitWhat, 256, 192, hitWhat .. " must stay inside the 256x192 surface", {
    what = hitWhat,
  })
  if type(record.navigation) ~= "table" then
    reject("startMenu.interactive position " .. position .. " navigation must be a table", {})
  end
  demandCount(
    record.navigation,
    4,
    "startMenu.interactive position " .. position .. " carries four navigation directions",
    {}
  )
  for _, direction in ipairs(NAV_DIRECTIONS) do
    local candidates = record.navigation[direction]
    if type(candidates) ~= "table" or #candidates ~= 3 then
      reject("startMenu.interactive position " .. position .. " " .. direction .. " must list three candidates", {})
    end
    for _, candidate in ipairs(candidates) do
      checkInteger(
        candidate,
        0,
        6,
        "startMenu.interactive position "
          .. position
          .. " "
          .. direction
          .. " candidates must name normal positions 0..6",
        {}
      )
    end
  end
end

local function checkStartMenuInteractive(interactive)
  if type(interactive) ~= "table" then
    reject("startMenu.interactive must be a table", {})
  end
  checkRect(
    interactive.cancelHitRect,
    "start menu cancel hit rectangle",
    256,
    192,
    "start menu cancel hit rectangle must stay inside the 256x192 surface",
    {
      what = "start menu cancel hit rectangle",
    }
  )
  if type(interactive.positions) ~= "table" then
    reject("startMenu.interactive.positions must be a table", {})
  end
  demandCount(interactive.positions, 7, "startMenu.interactive must carry exactly the seven normal positions", {})
  for position = 0, 6 do
    checkStartMenuInteractivePosition(interactive.positions[position], position)
  end
end

-- The Running Shoes toggle: its touch rectangle inside the canonical
-- surface plus the button body and lock indicator, each an integral canonical
-- anchor with an off and an on sprite visual in the shared icon atlas.

local function checkStartMenuRunningShoes(shoes, atlases)
  if type(shoes) ~= "table" then
    reject("startMenu.runningShoes must be a table", {})
  end
  checkRect(
    shoes.hitRect,
    "start menu Running Shoes hit rectangle",
    256,
    192,
    "start menu Running Shoes hit rectangle must stay inside the 256x192 surface",
    { what = "start menu Running Shoes hit rectangle" }
  )
  for _, part in ipairs({ "button", "indicator" }) do
    local record = shoes[part]
    if type(record) ~= "table" then
      reject("startMenu.runningShoes." .. part .. " must be a table", {})
    end
    local anchor = record.anchor
    if
      type(anchor) ~= "table"
      or type(anchor.x) ~= "number"
      or anchor.x % 1 ~= 0
      or type(anchor.y) ~= "number"
      or anchor.y % 1 ~= 0
    then
      reject("startMenu.runningShoes." .. part .. " anchor must be an integral point", {})
    end
    for _, state in ipairs({ "off", "on" }) do
      checkSpriteVisual(record[state], atlases, "start menu Running Shoes " .. part .. " " .. state .. " visual")
    end
  end
end

local function checkStartMenuChrome(chrome, atlases)
  if type(chrome) ~= "table" or type(chrome.main) ~= "table" or type(chrome.sub) ~= "table" then
    reject("startMenu.chrome must carry its main and sub sets", {})
  end
  for _, key in ipairs({ "main", "sub" }) do
    local set = chrome[key]
    if type(set.asset) ~= "string" or atlases[set.asset] == nil then
      reject("startMenu.chrome." .. key .. " must reference an indexed asset", {})
    end
  end
  checkInteger(chrome.main.transparentAboveY, 1, nil, "startMenu.chrome.main must name its transparency boundary", {})
end

-- The Start Menu label palette is a required generated record: the source
-- label-window roles as byte RGB with compositing alpha. Ink stays opaque
-- while the background stays transparent, so glyph background-class pixels
-- reveal the already-rendered chrome instead of repainting it.

local function checkLabelRole(labelPalette, role, expectedAlpha)
  local color = labelPalette[role]
  if type(color) ~= "table" then
    reject("startMenu.labelPalette." .. role .. " must be a table", {})
  end
  for _, component in ipairs(RGB_CHANNELS) do
    checkInteger(
      color[component],
      0,
      255,
      "startMenu.labelPalette." .. role .. "." .. component .. " must be an integral byte 0..255",
      {}
    )
  end
  if color.a ~= expectedAlpha then
    reject("startMenu.labelPalette." .. role .. " alpha must be " .. expectedAlpha .. " for label compositing", {})
  end
end

local function checkStartMenuLabelPalette(labelPalette)
  if type(labelPalette) ~= "table" then
    reject("startMenu.labelPalette must be a table", {})
  end
  demandCount(labelPalette, 3, "startMenu.labelPalette must carry exactly foreground, shadow, and background", {})
  if labelPalette.foreground == nil or labelPalette.shadow == nil or labelPalette.background == nil then
    reject("startMenu.labelPalette must carry exactly foreground, shadow, and background", {})
  end
  checkLabelRole(labelPalette, "foreground", 1)
  checkLabelRole(labelPalette, "shadow", 1)
  checkLabelRole(labelPalette, "background", 0)
end

local function checkStartMenu(s, atlases, asset)
  checkAtlasRect(s.background, atlases, asset.START_MENU_BACKGROUND, "start menu background")
  checkStartMenuCursor(s.cursor, atlases, asset)
  checkStartMenuIconTable(s.iconTable, atlases)
  checkStartMenuIconPalette(s.iconPalette, s.pokeIcons, atlases)
  checkStartMenuContexts(s.contexts, s.iconTable)
  checkStartMenuActionIcons(s.actionIcons, s.iconTable)
  checkStartMenuInteractive(s.interactive)
  checkStartMenuRunningShoes(s.runningShoes, atlases)
  checkStartMenuChrome(s.chrome, atlases)
  checkStartMenuLabelPalette(s.labelPalette)
end

local M = {}
function M.validate(section, atlases, asset, _)
  checkStartMenu(section, atlases, asset)
end
return M
