-- The Box producer resolves and compiles its exact pane and sprite sources.

local Assert = require("tests.support.Assert")
local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")
local ApricornBoxAssetCompiler = require("romdump.src.digest.ui.ApricornBoxAssetCompiler")
local ApricornBoxSources = require("romdump.src.config.ApricornBoxSources")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}
local bundles = {}

local function bundleFor(romFs, versionId)
  if bundles[versionId] == nil then
    bundles[versionId] = ApricornBoxAssetCompiler.compile(romFs)
  end
  return assert(bundles[versionId])
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

return RomSuite.fromFacts(T)
