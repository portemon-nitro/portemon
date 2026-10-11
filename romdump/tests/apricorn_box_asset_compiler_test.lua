-- The Box producer resolves and compiles its exact pane and sprite sources.

local Assert = require("tests.support.Assert")
local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")
local ApricornBoxAssetCompiler = require("romdump.src.digest.ui.ApricornBoxAssetCompiler")
local ApricornBoxCacheWriter = require("romdump.src.digest.ui.ApricornBoxCacheWriter")
local ApricornBoxSources = require("romdump.src.config.ApricornBoxSources")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}
local bundles = {}

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
  Assert.isTrue(
    ApricornBoxAssetCache.isManifestValid(bundle.manifest),
    "compiled manifest passes the strict runtime contract"
  )
  Assert.equal(bundle.manifest.upper.width, 256)
  Assert.equal(bundle.manifest.upper.height, 192)
  Assert.equal(bundle.manifest.lower.width, 256)
  Assert.equal(bundle.manifest.lower.height, 192)
  Assert.equal(#bundle.manifest.rows, 7)
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
