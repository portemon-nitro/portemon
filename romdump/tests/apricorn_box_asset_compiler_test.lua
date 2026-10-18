-- The Box producer follows the retail ROM and the source UI resources.

local Assert = require("tests.support.Assert")
local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")
local ApricornBoxAssetCompiler = require("romdump.src.digest.ui.ApricornBoxAssetCompiler")
local ApricornBoxCacheWriter = require("romdump.src.digest.ui.ApricornBoxCacheWriter")
local ApricornBoxSources = require("romdump.src.config.ApricornBoxSources")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}
local bundles = {}
local ROW_KEYS = {
  "RED_APRICORN",
  "YLW_APRICORN",
  "BLU_APRICORN",
  "GRN_APRICORN",
  "PNK_APRICORN",
  "WHT_APRICORN",
  "BLK_APRICORN",
}
local SOURCE_ROWS = {
  {
    key = "RED_APRICORN",
    label = 7,
    animation = 9,
    iconX = 27,
    iconY = 49,
    hitX = 26,
    hitY = 48,
    radius = 24,
    countX = 5,
    countY = 6,
  },
  {
    key = "YLW_APRICORN",
    label = 8,
    animation = 10,
    iconX = 75,
    iconY = 65,
    hitX = 74,
    hitY = 64,
    radius = 24,
    countX = 11,
    countY = 8,
  },
  {
    key = "BLU_APRICORN",
    label = 9,
    animation = 11,
    iconX = 27,
    iconY = 81,
    hitX = 26,
    hitY = 80,
    radius = 24,
    countX = 5,
    countY = 10,
  },
  {
    key = "GRN_APRICORN",
    label = 10,
    animation = 12,
    iconX = 75,
    iconY = 97,
    hitX = 74,
    hitY = 96,
    radius = 24,
    countX = 11,
    countY = 12,
  },
  {
    key = "PNK_APRICORN",
    label = 11,
    animation = 13,
    iconX = 27,
    iconY = 113,
    hitX = 26,
    hitY = 112,
    radius = 24,
    countX = 5,
    countY = 14,
  },
  {
    key = "WHT_APRICORN",
    label = 12,
    animation = 14,
    iconX = 75,
    iconY = 129,
    hitX = 74,
    hitY = 128,
    radius = 24,
    countX = 11,
    countY = 16,
  },
  {
    key = "BLK_APRICORN",
    label = 13,
    animation = 15,
    iconX = 27,
    iconY = 145,
    hitX = 26,
    hitY = 144,
    radius = 24,
    countX = 5,
    countY = 18,
  },
}
local SOURCE_CONTROL_BYTES = { 0, 2, 1, 0, 0, 4, 3, 0, 0, 6, 5, 0, 3, 4, 0, 11, 0, 0, 58, 0, 31, 0, 48, 0 }
local SOURCE_ACTION_LABELS = { 2, 3, 4, 5, 6 }

local function bundleFor(romFs, versionId)
  if bundles[versionId] == nil then
    bundles[versionId] = ApricornBoxAssetCompiler.compile(romFs)
  end
  return assert(bundles[versionId])
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, nested in pairs(value) do
    result[key] = copy(nested)
  end
  return result
end

local function invalidBeforeStagingAndPublication(bundle)
  local staging = { writes = 0, roots = 0 }
  local stageFs = {}
  function stageFs:write()
    staging.writes = staging.writes + 1
  end
  function stageFs:writeLua()
    staging.writes = staging.writes + 1
  end
  function stageFs:loadLua()
    return nil
  end
  function stageFs:exists()
    return false
  end
  local artifact = {
    stageFs = function()
      return stageFs
    end,
    addOwnedRoot = function()
      staging.roots = staging.roots + 1
    end,
  }
  local ok, err = pcall(ApricornBoxCacheWriter.stage, artifact, bundle)
  Assert.isFalse(ok, "the writer rejects invalid source provenance")
  Assert.equal(err.code, ApricornBoxCacheWriter.ERROR.BUNDLE_INVALID)
  Assert.equal(staging.roots, 0, "invalid bundles are rejected before artifact ownership changes")
  Assert.equal(staging.writes, 0, "invalid bundles are rejected before stage writes")

  local beginCount = 0
  local begin = ArtifactPublisher.begin
  ArtifactPublisher.begin = function()
    beginCount = beginCount + 1
    error("publication started before bundle validation")
  end
  local writeOk, writeErr = pcall(ApricornBoxCacheWriter.write, {}, bundle)
  ArtifactPublisher.begin = begin
  Assert.isFalse(writeOk, "the write path rejects invalid source provenance")
  Assert.equal(writeErr.code, ApricornBoxCacheWriter.ERROR.BUNDLE_INVALID)
  Assert.equal(beginCount, 0, "invalid bundles are rejected before publication begins")
end

function T.compiler_emits_source_panes_rows_and_the_action_menu_atlas(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  Assert.equal(bundle.manifest.upper.width, 256)
  Assert.equal(bundle.manifest.upper.height, 192)
  Assert.equal(bundle.manifest.lower.width, 256)
  Assert.equal(bundle.manifest.lower.height, 192)
  Assert.equal(#bundle.manifest.rows, 7)
  Assert.equal(bundle.manifest.messageBankId, 21)
  Assert.deepEqual(ApricornBoxSources.itemKeys, ROW_KEYS, "the producer preserves the native row order")
  Assert.deepEqual(
    ApricornBoxSources.messages.actionLabels,
    SOURCE_ACTION_LABELS,
    "the producer pins source action labels"
  )
  Assert.deepEqual(
    bundle.manifest.actionMessageIds,
    SOURCE_ACTION_LABELS,
    "the manifest retains source action label IDs"
  )
  Assert.deepEqual(
    bundle.manifest.controls.sourceTable,
    SOURCE_CONTROL_BYTES,
    "the emitted touchscreen list controls retain the source byte sequence"
  )
  for rowIndex, row in ipairs(bundle.manifest.rows) do
    local source = SOURCE_ROWS[rowIndex]
    Assert.equal(row.apricornKey, source.key, "the source row retains its native inventory identity")
    Assert.equal(row.nameMessageId, source.label, "the native row uses its matching source label")
    Assert.equal(ApricornBoxSources.geometry.rowIcons[rowIndex].animation, source.animation)
    Assert.equal(row.icon.x, source.iconX, "the sprite origin retains its overlay position")
    Assert.equal(row.icon.y, source.iconY, "the sprite origin retains its overlay position")
    local hitbox = bundle.manifest.rowHitboxes[rowIndex]
    Assert.equal(hitbox.x, source.hitX, "the touch row retains its source center")
    Assert.equal(hitbox.y, source.hitY, "the touch row retains its source center")
    Assert.equal(hitbox.radius, source.radius, "the touch row retains its source radius")
    local countWindow = row.quantity.window
    Assert.equal(countWindow.x, source.countX, "the count window retains its source position")
    Assert.equal(countWindow.y, source.countY, "the count window retains its source position")
    Assert.equal(countWindow.width, 2)
    Assert.equal(countWindow.height, 2)
  end
  Assert.deepEqual(ApricornBoxSources.geometry.touchMenu.actions.browse, {
    x = 22,
    y = 14,
    width = 8,
    windowCount = 3,
    messageIds = { 2, 3, 4 },
  }, "the source action labels retain their native menu placement")
  Assert.deepEqual(ApricornBoxSources.geometry.touchMenu.actions.kurtSelect, {
    x = 17,
    y = 12,
    width = 8,
    windowCount = 2,
    messageIds = { 5, 6 },
  }, "the Kurt action labels retain their native menu placement")
  Assert.deepEqual(bundle.manifest.controls.actions, ApricornBoxSources.geometry.touchMenu.actions)
  local dependencyNames = {}
  for _, dependency in ipairs(bundle.provenance.dependencies) do
    dependencyNames[dependency.name] = true
  end
  for _, source in ipairs(SOURCE_ROWS) do
    Assert.isTrue(
      dependencyNames["overlay59:row-animation:" .. source.animation],
      "the source row uses its matching sprite sequence"
    )
  end
  for _, sequenceId in ipairs({ 0, 3, 4, 5 }) do
    Assert.isTrue(#bundle.manifest.selectionCursor.states[sequenceId].frames > 0, "source cursor state compiles")
  end
  Assert.equal(bundle.manifest.actionMenu.width, 216)
  Assert.equal(bundle.manifest.actionMenu.height, 8)
  Assert.equal(bundle.manifest.actionMenu.charOffset, 31)
  for _, path in ipairs(ApricornBoxAssetCache.referencedPaths(bundle.manifest)) do
    Assert.isTrue(type(bundle.assets[path]) == "string", "compiled output contains referenced asset " .. path)
  end
  Assert.equal(bundle.provenance.source.actionMenu.alias, ApricornBoxSources.actionMenuArchive.alias)
  Assert.equal(bundle.provenance.source.actionMenu.narcId, ApricornBoxSources.actionMenuArchive.narcId)
  Assert.equal(bundle.provenance.source.actionMenu.path, ApricornBoxSources.actionMenuArchive.path)
end

function T.source_member_dependencies_are_narrow_and_ordered(romFs, versionId)
  local dependencies = bundleFor(romFs, versionId).provenance.dependencies
  local names = {}
  for _, dependency in ipairs(dependencies) do
    names[dependency.name] = true
  end
  for _, memberId in ipairs({ 0, 1, 2, 3, 4, 5, 7, 8, 9, 10 }) do
    Assert.isTrue(names["apricorn_box_ui:member:" .. memberId], "only audited NARC 220 members are source inputs")
  end
  for _, memberId in ipairs({ 16, 17, 18, 19, 76 }) do
    Assert.isTrue(
      names["apricorn_box_resdat:member:" .. memberId],
      "overlay resource member " .. memberId .. " is hashed"
    )
  end
  for _, memberId in ipairs({ 0, 1 }) do
    Assert.isTrue(names["sbox_gra:member:" .. memberId], "the native list-menu NCLR/NCGR pair is hashed")
  end
  for _, sequenceId in ipairs({ 3, 4, 5 }) do
    Assert.isTrue(
      names["apricorn_box_resdat:selection-cursor:header:76:animation:" .. sequenceId],
      "visible cursor transition sequence " .. sequenceId .. " is hashed"
    )
  end
  Assert.isNil(names["apricorn_box_ui:member:6"], "the unused screen member is excluded")
  Assert.equal(ApricornBoxSources.backgroundArchive.narcId, 220)
  Assert.equal(ApricornBoxSources.resdatArchive.narcId, 175)
  Assert.equal(ApricornBoxSources.actionMenuArchive.narcId, 165)
end

function T.cache_writer_rejects_invalid_action_menu_source_identity_before_writing(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local mutations = {
    function(source)
      source.alias = "wrong_alias"
    end,
    function(source)
      source.alias = nil
    end,
    function(source)
      source.narcId = source.narcId + 1
    end,
    function(source)
      source.narcId = nil
    end,
    function(source)
      source.path = "a/1/6/4"
    end,
    function(source)
      source.path = nil
    end,
  }
  for _, mutate in ipairs(mutations) do
    local corrupted = copy(bundle)
    mutate(corrupted.provenance.source.actionMenu)
    invalidBeforeStagingAndPublication(corrupted)
  end
end

return RomSuite.fromFacts(T)
