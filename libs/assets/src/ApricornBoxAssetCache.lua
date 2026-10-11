-- Validated paths and source contract for the HGSS Apricorn Box presentation.

local Contract = require("libs.assets.src.DerivedAssetContract")
local Validate = require("libs.assets.src.Validate")

local ApricornBoxAssetCache = {}

ApricornBoxAssetCache.FORMAT = Contract.apricornBox.cacheFormat
ApricornBoxAssetCache.SCHEMA = Contract.apricornBox.schema

local DATA_DIR = "data/generated/apricorn-box"
local ASSET_DIR = "assets/generated/apricorn-box"
local ROW_KEYS =
  { "RED_APRICORN", "BLU_APRICORN", "YLW_APRICORN", "GRN_APRICORN", "PNK_APRICORN", "WHT_APRICORN", "BLK_APRICORN" }
local ROW_NAME_MESSAGES = { 7, 8, 9, 10, 11, 12, 13 }
local ACTION_MESSAGE_IDS = { 2, 3, 4, 5, 6 }
local ROW_ICON_POSITIONS = {
  { 27, 49 },
  { 75, 65 },
  { 27, 81 },
  { 75, 97 },
  { 27, 113 },
  { 75, 129 },
  { 27, 145 },
}
local ROW_HITBOXES = {
  { 26, 48 },
  { 74, 64 },
  { 26, 80 },
  { 74, 96 },
  { 26, 112 },
  { 74, 128 },
  { 26, 144 },
}
local COUNT_WINDOWS = {
  { 5, 6 },
  { 11, 8 },
  { 5, 10 },
  { 11, 12 },
  { 5, 14 },
  { 11, 16 },
  { 5, 18 },
}
local CONTROL_BYTES = { 0, 2, 1, 0, 0, 4, 3, 0, 0, 6, 5, 0, 3, 4, 0, 11, 0, 0, 58, 0, 31, 0, 48, 0 }
local MODE_MESSAGES = { 25, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48 }
local FLOW_MESSAGE_IDS = { selection = 37, quantity = 38, confirmation = 39 }

function ApricornBoxAssetCache.dir()
  return DATA_DIR
end

function ApricornBoxAssetCache.assetDir()
  return ASSET_DIR
end

function ApricornBoxAssetCache.manifestPath()
  return DATA_DIR .. "/manifest.lua"
end

function ApricornBoxAssetCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end

function ApricornBoxAssetCache.markerPath()
  return DATA_DIR .. "/complete"
end

function ApricornBoxAssetCache.marker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", ApricornBoxAssetCache.FORMAT, romSha1, dependencyHash)
end

local function validImage(ref, width, height, path)
  return type(ref) == "table"
    and ref.image == path
    and ref.width == width
    and ref.height == height
    and ref.offsetX == 0
    and ref.offsetY == 0
end

local function validManifest(manifest)
  if
    type(manifest) ~= "table"
    or manifest.schema ~= ApricornBoxAssetCache.SCHEMA
    or manifest.messageBankId ~= 27
    or manifest.messageMemberId ~= 21
    or type(manifest.actionMessageIds) ~= "table"
    or #manifest.actionMessageIds ~= 5
    or type(manifest.flowMessageIds) ~= "table"
    or type(manifest.flowMessageIds.selection) ~= "number"
    or type(manifest.flowMessageIds.quantity) ~= "number"
    or type(manifest.flowMessageIds.confirmation) ~= "number"
    or type(manifest.modeMessages) ~= "table"
    or #manifest.modeMessages ~= 23
    or type(manifest.controls) ~= "table"
    or not validImage(manifest.actionMenu, 216, 8, ASSET_DIR .. "/action-menu-tiles.png")
    or manifest.actionMenu.charOffset ~= 31
    or type(manifest.controls.sourceTable) ~= "table"
    or #manifest.controls.sourceTable ~= 24
    or manifest.controls.windowCount ~= 3
    or type(manifest.controls.windowOriginTiles) ~= "table"
    or manifest.controls.windowOriginTiles.x ~= 14
    or manifest.controls.windowOriginTiles.y ~= 8
    or manifest.controls.windowWidthTiles ~= 22
    or manifest.controls.selection ~= 0
    or type(manifest.controls.actions) ~= "table"
    or type(manifest.controls.quantityHitboxes) ~= "table"
    or #manifest.controls.quantityHitboxes ~= 6
    or type(manifest.rows) ~= "table"
    or #manifest.rows ~= 7
    or type(manifest.rowHitboxes) ~= "table"
    or #manifest.rowHitboxes ~= 7
    or type(manifest.selectedDetail) ~= "table"
    or manifest.selectedDetail.messageWindowIndex ~= 4
    or type(manifest.selectedDetail.window) ~= "table"
    or type(manifest.selectionCursor) ~= "table"
    or type(manifest.selectionCursor.states) ~= "table"
    or type(manifest.selectionCursor.width) ~= "number"
    or manifest.selectionCursor.width < 1
    or type(manifest.selectionCursor.height) ~= "number"
    or manifest.selectionCursor.height < 1
    or type(manifest.selectionCursor.offsetX) ~= "number"
    or type(manifest.selectionCursor.offsetY) ~= "number"
    or manifest.selectionCursor.image ~= ASSET_DIR .. "/selection-cursor.png"
  then
    return false
  end
  for key in pairs(manifest) do
    if
      key ~= "schema"
      and key ~= "upper"
      and key ~= "lower"
      and key ~= "actionMenu"
      and key ~= "messageBankId"
      and key ~= "messageMemberId"
      and key ~= "actionMessageIds"
      and key ~= "flowMessageIds"
      and key ~= "modeMessages"
      and key ~= "controls"
      and key ~= "rows"
      and key ~= "rowHitboxes"
      and key ~= "selectedDetail"
      and key ~= "selectionCursor"
    then
      return false
    end
  end
  for key in pairs(manifest.actionMenu) do
    if
      key ~= "image"
      and key ~= "width"
      and key ~= "height"
      and key ~= "offsetX"
      and key ~= "offsetY"
      and key ~= "charOffset"
    then
      return false
    end
  end
  for index, value in ipairs(ACTION_MESSAGE_IDS) do
    if manifest.actionMessageIds[index] ~= value then
      return false
    end
  end
  for key, value in pairs(FLOW_MESSAGE_IDS) do
    if manifest.flowMessageIds[key] ~= value then
      return false
    end
  end
  local actions = manifest.controls.actions
  for key, expected in pairs({
    browse = { x = 22, y = 14, width = 8, windowCount = 3, labels = { 2, 3, 4 } },
    kurtSelect = { x = 17, y = 12, width = 8, windowCount = 2, labels = { 5, 6 } },
  }) do
    local menu = actions[key]
    if
      type(menu) ~= "table"
      or menu.x ~= expected.x
      or menu.y ~= expected.y
      or menu.width ~= expected.width
      or menu.windowCount ~= expected.windowCount
      or type(menu.messageIds) ~= "table"
      or #menu.messageIds ~= #expected.labels
    then
      return false
    end
    for index, messageId in ipairs(expected.labels) do
      if menu.messageIds[index] ~= messageId then
        return false
      end
    end
    for field in pairs(menu) do
      if field ~= "x" and field ~= "y" and field ~= "width" and field ~= "windowCount" and field ~= "messageIds" then
        return false
      end
    end
  end
  for key in pairs(actions) do
    if key ~= "browse" and key ~= "kurtSelect" then
      return false
    end
  end
  for key, value in pairs(manifest.flowMessageIds) do
    if key ~= "selection" and key ~= "quantity" and key ~= "confirmation" then
      return false
    end
    if value ~= FLOW_MESSAGE_IDS[key] then
      return false
    end
  end
  for key in pairs(manifest.selectionCursor) do
    if
      key ~= "image"
      and key ~= "width"
      and key ~= "height"
      and key ~= "offsetX"
      and key ~= "offsetY"
      and key ~= "states"
    then
      return false
    end
  end
  for _, sequenceId in ipairs({ 0, 3, 4, 5 }) do
    local sequence = manifest.selectionCursor.states[sequenceId]
    if
      type(sequence) ~= "table"
      or type(sequence.frames) ~= "table"
      or #sequence.frames == 0
      or type(sequence.totalTicks) ~= "number"
      or sequence.totalTicks < 1
      or (sequence.playMode ~= "forward" and sequence.playMode ~= "forward_loop")
    then
      return false
    end
    for _, frame in ipairs(sequence.frames) do
      if
        type(frame) ~= "table"
        or type(frame.image) ~= "string"
        or type(frame.width) ~= "number"
        or frame.width < 1
        or type(frame.height) ~= "number"
        or frame.height < 1
        or type(frame.offsetX) ~= "number"
        or type(frame.offsetY) ~= "number"
        or type(frame.durationTicks) ~= "number"
        or frame.durationTicks < 1
      then
        return false
      end
    end
  end
  for sequenceId in pairs(manifest.selectionCursor.states) do
    if sequenceId ~= 0 and sequenceId ~= 3 and sequenceId ~= 4 and sequenceId ~= 5 then
      return false
    end
  end
  for index, value in ipairs(CONTROL_BYTES) do
    if manifest.controls.sourceTable[index] ~= value then
      return false
    end
  end
  for key in pairs(manifest.controls) do
    if
      key ~= "sourceTable"
      and key ~= "windowCount"
      and key ~= "windowOriginTiles"
      and key ~= "windowWidthTiles"
      and key ~= "selection"
      and key ~= "quantityHitboxes"
      and key ~= "actions"
    then
      return false
    end
  end
  local quantityBounds = {
    { 104, 136, 16, 48 },
    { 128, 136, 16, 48 },
    { 88, 94, 16, 14 },
    { 128, 94, 16, 14 },
    { 88, 74, 16, 14 },
    { 128, 74, 16, 14 },
  }
  for index, expected in ipairs(quantityBounds) do
    local bounds = manifest.controls.quantityHitboxes[index]
    if
      type(bounds) ~= "table"
      or bounds.x ~= expected[1]
      or bounds.y ~= expected[2]
      or bounds.width ~= expected[3]
      or bounds.height ~= expected[4]
    then
      return false
    end
    for key in pairs(bounds) do
      if key ~= "x" and key ~= "y" and key ~= "width" and key ~= "height" then
        return false
      end
    end
  end
  for index, value in ipairs(MODE_MESSAGES) do
    if manifest.modeMessages[index] ~= value then
      return false
    end
  end
  for _, pane in ipairs({ "upper", "lower" }) do
    if not validImage(manifest[pane], 256, 192, ASSET_DIR .. "/" .. pane .. "-background.png") then
      return false
    end
    for key in pairs(manifest[pane]) do
      if key ~= "image" and key ~= "width" and key ~= "height" and key ~= "offsetX" and key ~= "offsetY" then
        return false
      end
    end
  end
  for index, row in ipairs(manifest.rows) do
    local icon = type(row) == "table" and row.icon
    local quantity = type(row) == "table" and row.quantity
    local position = ROW_ICON_POSITIONS[index]
    local window = COUNT_WINDOWS[index]
    if
      row.apricornKey ~= ROW_KEYS[index]
      or row.nameMessageId ~= ROW_NAME_MESSAGES[index]
      or type(icon) ~= "table"
      or icon.x ~= position[1]
      or icon.y ~= position[2]
      or icon.playMode ~= "forward_loop"
      or type(icon.frames) ~= "table"
      or #icon.frames == 0
      or type(icon.totalTicks) ~= "number"
      or icon.totalTicks < 1
      or type(quantity) ~= "table"
      or type(quantity.window) ~= "table"
      or quantity.window.x ~= window[1]
      or quantity.window.y ~= window[2]
      or quantity.window.width ~= 2
      or quantity.window.height ~= 2
      or quantity.alignment ~= "center"
      or quantity.textWidth ~= 16
      or quantity.textHeight ~= 16
      or quantity.color ~= 2
    then
      return false
    end
    for key in pairs(row) do
      if key ~= "apricornKey" and key ~= "nameMessageId" and key ~= "icon" and key ~= "quantity" then
        return false
      end
    end
    local totalTicks = 0
    for _, frame in ipairs(icon.frames) do
      if
        type(frame) ~= "table"
        or type(frame.image) ~= "string"
        or frame.image:sub(1, #ASSET_DIR + 1) ~= ASSET_DIR .. "/"
        or frame.image:find("..", 1, true)
        or type(frame.width) ~= "number"
        or frame.width < 1
        or type(frame.height) ~= "number"
        or frame.height < 1
        or type(frame.offsetX) ~= "number"
        or type(frame.offsetY) ~= "number"
        or type(frame.durationTicks) ~= "number"
        or frame.durationTicks < 1
      then
        return false
      end
      for key in pairs(frame) do
        if
          key ~= "image"
          and key ~= "width"
          and key ~= "height"
          and key ~= "offsetX"
          and key ~= "offsetY"
          and key ~= "durationTicks"
        then
          return false
        end
      end
      totalTicks = totalTicks + frame.durationTicks
    end
    if totalTicks ~= icon.totalTicks then
      return false
    end
  end
  for index, hitbox in ipairs(manifest.rowHitboxes) do
    local center = ROW_HITBOXES[index]
    if type(hitbox) ~= "table" or hitbox.x ~= center[1] or hitbox.y ~= center[2] or hitbox.radius ~= 24 then
      return false
    end
    for key in pairs(hitbox) do
      if key ~= "x" and key ~= "y" and key ~= "radius" then
        return false
      end
    end
  end
  local detail = manifest.selectedDetail.window
  if
    detail.bg ~= 7
    or detail.x ~= 2
    or detail.y ~= 17
    or detail.width ~= 28
    or detail.height ~= 6
    or detail.palette ~= 12
    or detail.baseTile ~= 0x358
  then
    return false
  end
  for key in pairs(detail) do
    if
      key ~= "bg"
      and key ~= "x"
      and key ~= "y"
      and key ~= "width"
      and key ~= "height"
      and key ~= "palette"
      and key ~= "baseTile"
    then
      return false
    end
  end
  return true
end

function ApricornBoxAssetCache.isManifestValid(manifest)
  return validManifest(manifest)
end

---@param manifest table<string, unknown>
---@return string[]
function ApricornBoxAssetCache.referencedPaths(manifest)
  assert(validManifest(manifest), "Apricorn Box manifest is valid before paths are collected")
  local paths = {
    manifest.upper.image,
    manifest.lower.image,
    manifest.actionMenu.image,
    manifest.selectionCursor.image,
  }
  for _, sequence in pairs(manifest.selectionCursor.states) do
    for _, frame in ipairs(sequence.frames) do
      paths[#paths + 1] = frame.image
    end
  end
  for _, row in ipairs(manifest.rows) do
    for _, frame in ipairs(row.icon.frames) do
      paths[#paths + 1] = frame.image
    end
  end
  table.sort(paths)
  return paths
end

---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function ApricornBoxAssetCache.isReady(cacheFs, expectedMarker)
  if type(expectedMarker) ~= "string" or cacheFs:read(ApricornBoxAssetCache.markerPath()) ~= expectedMarker then
    return false
  end
  local manifest = cacheFs:loadLua(ApricornBoxAssetCache.manifestPath())
  if not validManifest(manifest) then
    return false
  end
  local provenance = cacheFs:loadLua(ApricornBoxAssetCache.provenancePath())
  if
    type(provenance) ~= "table"
    or provenance.cacheFormat ~= ApricornBoxAssetCache.FORMAT
    or provenance.schema ~= ApricornBoxAssetCache.SCHEMA
    or not Validate.isSha1Key(provenance.versionRomSha1)
    or not Validate.isSha1Key(provenance.dependencyHash)
    or ApricornBoxAssetCache.marker(provenance.versionRomSha1, provenance.dependencyHash) ~= expectedMarker
    or type(provenance.dependencies) ~= "table"
    or #provenance.dependencies == 0
  then
    return false
  end
  local source = provenance.source
  if type(source) ~= "table" then
    return false
  end
  local backgrounds = source.backgrounds
  local resources = source.resources
  if
    type(backgrounds) ~= "table"
    or backgrounds.alias ~= "apricorn_box_ui"
    or backgrounds.narcId ~= 220
    or backgrounds.path ~= "a/2/1/8"
    or type(resources) ~= "table"
    or resources.alias ~= "apricorn_box_resdat"
    or resources.narcId ~= 175
    or resources.path ~= "a/1/7/5"
  then
    return false
  end
  ---@cast manifest table<string, unknown>
  ---@cast provenance table<string, unknown>
  for key in pairs(provenance) do
    if
      key ~= "cacheFormat"
      and key ~= "schema"
      and key ~= "versionRomSha1"
      and key ~= "dependencyHash"
      and key ~= "source"
      and key ~= "dependencies"
    then
      return false
    end
  end
  for _, path in ipairs(ApricornBoxAssetCache.referencedPaths(manifest)) do
    if not cacheFs:exists(path, "file") then
      return false
    end
  end
  return true
end

---@param cacheFs CacheFs
---@return table<string, unknown>
function ApricornBoxAssetCache.loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(ApricornBoxAssetCache.manifestPath())
  assert(validManifest(manifest), "Apricorn Box presentation manifest is unavailable or invalid")
  ---@cast manifest table<string, unknown>
  return manifest
end

return ApricornBoxAssetCache
