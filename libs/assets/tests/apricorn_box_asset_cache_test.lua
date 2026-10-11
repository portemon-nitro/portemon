-- Readiness follows the complete source-backed two-pane Box artifact.

local Assert = require("tests.support.Assert")
local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")

local T = {}

local ROM_SHA1 = string.rep("a", 40)
local DEPENDENCY_SHA1 = string.rep("b", 40)
local ROW_KEYS =
  { "RED_APRICORN", "BLU_APRICORN", "YLW_APRICORN", "GRN_APRICORN", "PNK_APRICORN", "WHT_APRICORN", "BLK_APRICORN" }
local ICON_POSITIONS = { { 27, 49 }, { 75, 65 }, { 27, 81 }, { 75, 97 }, { 27, 113 }, { 75, 129 }, { 27, 145 } }
local COUNT_WINDOWS = { { 5, 6 }, { 11, 8 }, { 5, 10 }, { 11, 12 }, { 5, 14 }, { 11, 16 }, { 5, 18 } }

local function cursorStates()
  local states = {}
  for _, sequenceId in ipairs({ 0, 3, 4, 5 }) do
    states[sequenceId] = {
      playMode = "forward",
      totalTicks = 1,
      frames = {
        {
          image = ApricornBoxAssetCache.assetDir() .. "/cursor-" .. sequenceId .. ".png",
          width = 12,
          height = 12,
          offsetX = 0,
          offsetY = 0,
          durationTicks = 1,
        },
      },
    }
  end
  return states
end

local function readyCache()
  local rows = {}
  local files = {}
  for index, key in ipairs(ROW_KEYS) do
    local framePath = ApricornBoxAssetCache.assetDir() .. "/icon-" .. index .. ".png"
    local position = ICON_POSITIONS[index]
    local window = COUNT_WINDOWS[index]
    rows[index] = {
      apricornKey = key,
      nameMessageId = index + 6,
      icon = {
        x = position[1],
        y = position[2],
        playMode = "forward_loop",
        frames = { { image = framePath, width = 16, height = 16, offsetX = 0, offsetY = 0, durationTicks = 1 } },
        totalTicks = 1,
      },
      quantity = {
        window = { x = window[1], y = window[2], width = 2, height = 2 },
        alignment = "center",
        textWidth = 16,
        textHeight = 16,
        color = 2,
      },
    }
    files[framePath] = true
  end
  local manifest = {
    schema = ApricornBoxAssetCache.SCHEMA,
    upper = {
      image = ApricornBoxAssetCache.assetDir() .. "/upper-background.png",
      width = 256,
      height = 192,
      offsetX = 0,
      offsetY = 0,
    },
    lower = {
      image = ApricornBoxAssetCache.assetDir() .. "/lower-background.png",
      width = 256,
      height = 192,
      offsetX = 0,
      offsetY = 0,
    },
    actionMenu = {
      image = ApricornBoxAssetCache.assetDir() .. "/action-menu-tiles.png",
      width = 216,
      height = 8,
      offsetX = 0,
      offsetY = 0,
      charOffset = 31,
    },
    selectionCursor = {
      image = ApricornBoxAssetCache.assetDir() .. "/selection-cursor.png",
      width = 12,
      height = 12,
      offsetX = 0,
      offsetY = 0,
      states = cursorStates(),
    },
    messageBankId = 27,
    actionMessageIds = { 2, 3, 4, 5, 6 },
    flowMessageIds = { selection = 37, quantity = 38, confirmation = 39 },
    modeMessages = { 25, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48 },
    rowHitboxes = {
      { x = 26, y = 48, radius = 24 },
      { x = 74, y = 64, radius = 24 },
      { x = 26, y = 80, radius = 24 },
      { x = 74, y = 96, radius = 24 },
      { x = 26, y = 112, radius = 24 },
      { x = 74, y = 128, radius = 24 },
      { x = 26, y = 144, radius = 24 },
    },
    selectedDetail = {
      window = { bg = 7, x = 2, y = 17, width = 28, height = 6, palette = 12, baseTile = 0x358 },
      messageWindowIndex = 4,
    },
    controls = {
      sourceTable = { 0, 2, 1, 0, 0, 4, 3, 0, 0, 6, 5, 0, 3, 4, 0, 11, 0, 0, 58, 0, 31, 0, 48, 0 },
      windowCount = 3,
      windowOriginTiles = { x = 14, y = 8 },
      windowWidthTiles = 22,
      selection = 0,
      quantityHitboxes = {
        { x = 104, y = 136, width = 16, height = 48 },
        { x = 128, y = 136, width = 16, height = 48 },
        { x = 88, y = 94, width = 16, height = 14 },
        { x = 128, y = 94, width = 16, height = 14 },
        { x = 88, y = 74, width = 16, height = 14 },
        { x = 128, y = 74, width = 16, height = 14 },
      },
      actions = {
        browse = { x = 22, y = 14, width = 8, windowCount = 3, messageIds = { 2, 3, 4 } },
        kurtSelect = { x = 17, y = 12, width = 8, windowCount = 2, messageIds = { 5, 6 } },
      },
    },
    rows = rows,
  }
  local provenance = {
    cacheFormat = ApricornBoxAssetCache.FORMAT,
    schema = ApricornBoxAssetCache.SCHEMA,
    versionRomSha1 = ROM_SHA1,
    dependencyHash = DEPENDENCY_SHA1,
    source = {
      backgrounds = { alias = "apricorn_box_ui", narcId = 220, path = "a/2/1/8" },
      resources = { alias = "apricorn_box_resdat", narcId = 175, path = "a/1/7/5" },
    },
    dependencies = { {} },
  }
  local marker = ApricornBoxAssetCache.marker(ROM_SHA1, DEPENDENCY_SHA1)
  local files = {
    [ApricornBoxAssetCache.markerPath()] = marker,
    [manifest.upper.image] = true,
    [manifest.lower.image] = true,
    [manifest.selectionCursor.image] = true,
    [manifest.actionMenu.image] = true,
  }
  for _, row in ipairs(rows) do
    files[row.icon.frames[1].image] = true
  end
  for _, sequence in pairs(manifest.selectionCursor.states) do
    for _, frame in ipairs(sequence.frames) do
      files[frame.image] = true
    end
  end
  local cacheFs = {
    read = function(_, path)
      return files[path]
    end,
    loadLua = function(_, path)
      if path == ApricornBoxAssetCache.manifestPath() then
        return manifest
      elseif path == ApricornBoxAssetCache.provenancePath() then
        return provenance
      end
      return nil
    end,
    exists = function(_, path, kind)
      return kind == "file" and files[path] ~= nil
    end,
  }
  return cacheFs, manifest, provenance, marker, files
end

function T.readiness_requires_the_exact_source_identity_and_both_native_panes()
  local cacheFs, _, provenance, marker = readyCache()
  Assert.isTrue(ApricornBoxAssetCache.isReady(cacheFs, marker))
  provenance.source.backgrounds.narcId = 244
  Assert.isFalse(ApricornBoxAssetCache.isReady(cacheFs, marker))
end

function T.readiness_rejects_unknown_manifest_fields_and_missing_images()
  local cacheFs, manifest, _, marker, files = readyCache()
  manifest.upper.placeholder = true
  Assert.isFalse(ApricornBoxAssetCache.isReady(cacheFs, marker))
  manifest.upper.placeholder = nil
  files[manifest.lower.image] = nil
  Assert.isFalse(ApricornBoxAssetCache.isReady(cacheFs, marker))
end

return { tests = T }
