-- Validates the generated Apricorn Box asset contract for consumers.

local Contract = require("libs.assets.src.DerivedAssetContract")
local Validate = require("libs.assets.src.Validate")

local ApricornBoxAssetCache = {}

ApricornBoxAssetCache.FORMAT = Contract.apricornBox.cacheFormat
ApricornBoxAssetCache.SCHEMA = Contract.apricornBox.schema

local DATA_DIR = "data/generated/apricorn-box"
local ASSET_DIR = "assets/generated/apricorn-box"
local ROW_KEYS = {
  RED_APRICORN = true,
  YLW_APRICORN = true,
  BLU_APRICORN = true,
  GRN_APRICORN = true,
  PNK_APRICORN = true,
  WHT_APRICORN = true,
  BLK_APRICORN = true,
}
local CURSOR_STATE_IDS = { 0, 3, 4, 5 }
local MANIFEST_FIELDS = {
  schema = true,
  upper = true,
  lower = true,
  actionMenu = true,
  messageBankId = true,
  actionMessageIds = true,
  flowMessageIds = true,
  modeMessages = true,
  controls = true,
  rows = true,
  rowHitboxes = true,
  selectedDetail = true,
  selectionCursor = true,
}
local IMAGE_FIELDS = { image = true, width = true, height = true, offsetX = true, offsetY = true }
local FRAME_FIELDS = {
  image = true,
  width = true,
  height = true,
  offsetX = true,
  offsetY = true,
  durationTicks = true,
}
local SEQUENCE_FIELDS = { frames = true, totalTicks = true, playMode = true }
local ROW_ICON_FIELDS = { x = true, y = true, playMode = true, frames = true, totalTicks = true }
local ROW_FIELDS = { apricornKey = true, nameMessageId = true, icon = true, quantity = true }
local QUANTITY_FIELDS = { window = true, alignment = true, textWidth = true, textHeight = true, color = true }
local TILE_RECT_FIELDS = { x = true, y = true, width = true, height = true }
local HITBOX_FIELDS = { x = true, y = true, radius = true }
local CONTROL_FIELDS = {
  sourceTable = true,
  windowCount = true,
  windowOriginTiles = true,
  windowWidthTiles = true,
  selection = true,
  quantityHitboxes = true,
  actions = true,
}
local ACTION_FIELDS = { x = true, y = true, width = true, windowCount = true, messageIds = true }
local DETAIL_FIELDS = { window = true, messageWindowIndex = true }
local DETAIL_WINDOW_FIELDS =
  { bg = true, x = true, y = true, width = true, height = true, palette = true, baseTile = true }
local CURSOR_FIELDS = { image = true, width = true, height = true, offsetX = true, offsetY = true, states = true }

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

local function hasOnlyFields(value, fields)
  if type(value) ~= "table" then
    return false
  end
  for key in pairs(value) do
    if not fields[key] then
      return false
    end
  end
  return true
end

local function validArray(value, length)
  return Validate.isArray(value) and #value == length
end

local function finite(value, minimum, maximum)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value >= minimum
    and value <= maximum
end

local function integer(value, minimum, maximum)
  return finite(value, minimum, maximum) and value % 1 == 0
end

local function validAssetPath(path, paths)
  local prefix = ASSET_DIR .. "/"
  if
    type(path) ~= "string"
    or path:sub(1, #prefix) ~= prefix
    or path:sub(-4) ~= ".png"
    or path:find("\\", 1, true)
    or path:find("//", 1, true)
  then
    return false
  end
  local relative = path:sub(#prefix + 1)
  if relative == "" then
    return false
  end
  for segment in relative:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      return false
    end
  end
  if paths[path] then
    return false
  end
  paths[path] = true
  return true
end

local function validImage(ref, width, height, path, paths)
  return hasOnlyFields(ref, IMAGE_FIELDS)
    and ref.image == path
    and validAssetPath(ref.image, paths)
    and integer(ref.width, width, width)
    and integer(ref.height, height, height)
    and finite(ref.offsetX, -256, 256)
    and finite(ref.offsetY, -256, 256)
end

local function validTileRect(rect)
  return hasOnlyFields(rect, TILE_RECT_FIELDS)
    and integer(rect.x, 0, 31)
    and integer(rect.y, 0, 23)
    and integer(rect.width, 1, 32)
    and integer(rect.height, 1, 24)
    and rect.x + rect.width <= 32
    and rect.y + rect.height <= 24
end

local function validPixelRect(rect)
  return hasOnlyFields(rect, TILE_RECT_FIELDS)
    and integer(rect.x, 0, 255)
    and integer(rect.y, 0, 191)
    and integer(rect.width, 1, 256)
    and integer(rect.height, 1, 192)
    and rect.x + rect.width <= 256
    and rect.y + rect.height <= 192
end

local function validFrame(frame, paths)
  return hasOnlyFields(frame, FRAME_FIELDS)
    and validAssetPath(frame.image, paths)
    and integer(frame.width, 1, 256)
    and integer(frame.height, 1, 192)
    and finite(frame.offsetX, -256, 256)
    and finite(frame.offsetY, -192, 192)
    and integer(frame.durationTicks, 1, 65535)
end

local function validSequence(sequence, fields, paths)
  if
    not hasOnlyFields(sequence, fields)
    or (sequence.playMode ~= "forward" and sequence.playMode ~= "forward_loop")
    or not integer(sequence.totalTicks, 1, 1000000)
    or not Validate.isArray(sequence.frames)
    or #sequence.frames == 0
  then
    return false
  end
  local totalTicks = 0
  for _, frame in ipairs(sequence.frames) do
    if not validFrame(frame, paths) then
      return false
    end
    totalTicks = totalTicks + frame.durationTicks
  end
  return totalTicks == sequence.totalTicks
end

local function validMessageIds(ids, length)
  if not validArray(ids, length) then
    return false
  end
  local seen = {}
  for _, messageId in ipairs(ids) do
    if not integer(messageId, 0, 65535) or seen[messageId] then
      return false
    end
    seen[messageId] = true
  end
  return true
end

local function validActions(actions, actionIds)
  if not hasOnlyFields(actions, { browse = true, kurtSelect = true }) then
    return false
  end
  for mode, count in pairs({ browse = 3, kurtSelect = 2 }) do
    local menu = actions[mode]
    if
      not hasOnlyFields(menu, ACTION_FIELDS)
      or not integer(menu.x, 0, 31)
      or not integer(menu.y, 0, 23)
      or not integer(menu.width, 1, 32)
      or not integer(menu.windowCount, count, count)
      or menu.x + menu.width + 2 > 32
      or menu.y + 1 + menu.windowCount * 3 > 24
      or not validMessageIds(menu.messageIds, count)
    then
      return false
    end
    for _, messageId in ipairs(menu.messageIds) do
      if not actionIds[messageId] then
        return false
      end
    end
  end
  return true
end

local function validManifest(manifest)
  if
    not hasOnlyFields(manifest, MANIFEST_FIELDS)
    or manifest.schema ~= ApricornBoxAssetCache.SCHEMA
    or manifest.messageBankId ~= 21
    or not validMessageIds(manifest.actionMessageIds, 5)
    or not hasOnlyFields(manifest.flowMessageIds, { selection = true, quantity = true, confirmation = true })
    or not hasOnlyFields(manifest.controls, CONTROL_FIELDS)
    or not validArray(manifest.modeMessages, 23)
    or not validArray(manifest.rows, 7)
    or not validArray(manifest.rowHitboxes, 7)
    or not hasOnlyFields(manifest.selectedDetail, DETAIL_FIELDS)
    or not integer(manifest.selectedDetail.messageWindowIndex, 0, 65535)
    or not hasOnlyFields(manifest.selectedDetail.window, DETAIL_WINDOW_FIELDS)
    or not integer(manifest.selectedDetail.window.bg, 0, 7)
    or not integer(manifest.selectedDetail.window.x, 0, 31)
    or not integer(manifest.selectedDetail.window.y, 0, 23)
    or not integer(manifest.selectedDetail.window.width, 1, 32)
    or not integer(manifest.selectedDetail.window.height, 1, 24)
    or manifest.selectedDetail.window.x + manifest.selectedDetail.window.width > 32
    or manifest.selectedDetail.window.y + manifest.selectedDetail.window.height > 24
    or not integer(manifest.selectedDetail.window.palette, 0, 15)
    or not integer(manifest.selectedDetail.window.baseTile, 0, 1023)
  then
    return false
  end

  local messages = {}
  for _, messageId in ipairs(manifest.actionMessageIds) do
    messages[messageId] = true
  end
  for _, messageId in ipairs(manifest.modeMessages) do
    if not integer(messageId, 0, 65535) then
      return false
    end
  end
  for _, phase in ipairs({ "selection", "quantity", "confirmation" }) do
    local messageId = manifest.flowMessageIds[phase]
    if not integer(messageId, 0, 65535) or messages[messageId] then
      return false
    end
    messages[messageId] = true
  end
  for key in pairs(manifest.flowMessageIds) do
    if key ~= "selection" and key ~= "quantity" and key ~= "confirmation" then
      return false
    end
  end

  local paths = {}
  if
    not validImage(manifest.upper, 256, 192, ASSET_DIR .. "/upper-background.png", paths)
    or not validImage(manifest.lower, 256, 192, ASSET_DIR .. "/lower-background.png", paths)
    or not hasOnlyFields(manifest.actionMenu, {
      image = true,
      width = true,
      height = true,
      offsetX = true,
      offsetY = true,
      charOffset = true,
    })
    or manifest.actionMenu.image ~= ASSET_DIR .. "/action-menu-tiles.png"
    or not validAssetPath(manifest.actionMenu.image, paths)
    or not integer(manifest.actionMenu.width, 216, 216)
    or not integer(manifest.actionMenu.height, 8, 8)
    or not finite(manifest.actionMenu.offsetX, -256, 256)
    or not finite(manifest.actionMenu.offsetY, -192, 192)
    or not integer(manifest.actionMenu.charOffset, 0, 65535)
  then
    return false
  end

  local cursor = manifest.selectionCursor
  if
    not hasOnlyFields(cursor, CURSOR_FIELDS)
    or cursor.image ~= ASSET_DIR .. "/selection-cursor.png"
    or not validAssetPath(cursor.image, paths)
    or not integer(cursor.width, 1, 256)
    or not integer(cursor.height, 1, 192)
    or not finite(cursor.offsetX, -256, 256)
    or not finite(cursor.offsetY, -192, 192)
    or not hasOnlyFields(cursor.states, { [0] = true, [3] = true, [4] = true, [5] = true })
  then
    return false
  end
  for _, stateId in ipairs(CURSOR_STATE_IDS) do
    if not validSequence(cursor.states[stateId], SEQUENCE_FIELDS, paths) then
      return false
    end
  end

  local controls = manifest.controls
  if
    not validArray(controls.sourceTable, 24)
    or not integer(controls.windowCount, 1, 24)
    or not hasOnlyFields(controls.windowOriginTiles, { x = true, y = true })
    or not integer(controls.windowOriginTiles.x, 0, 31)
    or not integer(controls.windowOriginTiles.y, 0, 23)
    or not integer(controls.windowWidthTiles, 1, 32)
    or not integer(controls.selection, 0, 65535)
    or not validArray(controls.quantityHitboxes, 6)
    or not validActions(controls.actions, messages)
  then
    return false
  end
  for _, value in ipairs(controls.sourceTable) do
    if not integer(value, 0, 255) then
      return false
    end
  end
  for _, bounds in ipairs(controls.quantityHitboxes) do
    if not validPixelRect(bounds) then
      return false
    end
  end

  local seenKeys = {}
  local seenNames = {}
  for _, row in ipairs(manifest.rows) do
    if
      not hasOnlyFields(row, ROW_FIELDS)
      or not ROW_KEYS[row.apricornKey]
      or seenKeys[row.apricornKey]
      or not integer(row.nameMessageId, 0, 65535)
      or seenNames[row.nameMessageId]
      or not hasOnlyFields(row.icon, ROW_ICON_FIELDS)
      or not integer(row.icon.x, 0, 255)
      or not integer(row.icon.y, 0, 191)
      or row.icon.playMode ~= "forward_loop"
      or not validSequence(row.icon, ROW_ICON_FIELDS, paths)
      or not hasOnlyFields(row.quantity, QUANTITY_FIELDS)
      or not validTileRect(row.quantity.window)
      or row.quantity.alignment ~= "center"
      or not integer(row.quantity.textWidth, 1, 256)
      or not integer(row.quantity.textHeight, 1, 192)
      or not integer(row.quantity.color, 0, 15)
    then
      return false
    end
    seenKeys[row.apricornKey] = true
    seenNames[row.nameMessageId] = true
    messages[row.nameMessageId] = true
  end
  for _, hitbox in ipairs(manifest.rowHitboxes) do
    if
      not hasOnlyFields(hitbox, HITBOX_FIELDS)
      or not integer(hitbox.x, 0, 255)
      or not integer(hitbox.y, 0, 191)
      or not integer(hitbox.radius, 1, 128)
      or hitbox.x - hitbox.radius < 0
      or hitbox.x + hitbox.radius > 256
      or hitbox.y - hitbox.radius < 0
      or hitbox.y + hitbox.radius > 192
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
