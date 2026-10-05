-- ROM conformance for the normalized follower-interaction source catalog.

local Assert = require("tests.support.Assert")
local Cache = require("libs.assets.src.field.FollowerInteractionCache")
local Sources = require("romdump.src.config.FollowerInteractionSources")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local compiledByVersion = {}

local function activeRows(Compiler, bytes, rowCount)
  local rows = {}
  for row = 0, rowCount - 1 do
    local offset = row * Sources.RULE_SIZE
    local rule = Compiler.decodeRuleMember(bytes:sub(offset + 1, offset + Sources.RULE_SIZE))
    if rule.interactionId ~= 0 then
      rows[#rows + 1] = rule
    end
  end
  return rows
end

local function catalogFor(romFs, versionId)
  if compiledByVersion[versionId] == nil then
    local Compiler = require("romdump.src.digest.field.FollowerInteractionCompiler")
    local bundle = assert(Compiler.compile(romFs))
    compiledByVersion[versionId] = bundle.catalog
  end
  return compiledByVersion[versionId]
end

function T.source_catalog_compiles_with_retail_order_and_semantic_references(romFs, versionId)
  local catalog = catalogFor(romFs, versionId)
  Assert.isTrue(Cache.validateCatalog(catalog), "compiled interaction catalog must satisfy its strict schema")
  Assert.equal(catalog.version, versionId)

  local Compiler = require("romdump.src.digest.field.FollowerInteractionCompiler")
  local ruleArchive = assert(romFs:openNarc(Sources.ARCHIVES.rules))
  local commonBytes = assert(ruleArchive:readMember(0))
  local sectionFirstRows = activeRows(Compiler, commonBytes, 12)
  local sectionTailRows = {}
  for row = 12, Sources.COMMON_RULE_COUNT - 1 do
    local offset = row * Sources.RULE_SIZE
    local rule = Compiler.decodeRuleMember(commonBytes:sub(offset + 1, offset + Sources.RULE_SIZE))
    if rule.interactionId ~= 0 then
      sectionTailRows[#sectionTailRows + 1] = rule
    end
  end
  for sectionId = 0, 235 do
    local expected = {}
    for _, rule in ipairs(sectionFirstRows) do
      expected[#expected + 1] = rule
    end
    if sectionId > 0 then
      local sectionBytes = assert(ruleArchive:readMember(sectionId))
      for _, rule in ipairs(activeRows(Compiler, sectionBytes, Sources.SECTION_RULE_COUNT)) do
        expected[#expected + 1] = rule
      end
    end
    for _, rule in ipairs(sectionTailRows) do
      expected[#expected + 1] = rule
    end
    Assert.deepEqual(catalog.rulesByMapSection[sectionId], expected,
      "compiled rules preserve common source-row boundaries for section " .. sectionId)
  end

  local tailRowBytes
  for row = 12, Sources.COMMON_RULE_COUNT - 1 do
    local offset = row * Sources.RULE_SIZE
    local rowBytes = commonBytes:sub(offset + 1, offset + Sources.RULE_SIZE)
    if Compiler.decodeRuleMember(rowBytes).interactionId ~= 0 then
      tailRowBytes = rowBytes
      break
    end
  end
  assert(tailRowBytes, "source corpus includes an active common tail row")
  local syntheticCommonBytes = string.rep("\0", 12 * Sources.RULE_SIZE)
    .. commonBytes:sub(12 * Sources.RULE_SIZE + 1)
  local sectionBytes = assert(ruleArchive:readMember(1))
  local syntheticSectionBytes = tailRowBytes .. sectionBytes:sub(Sources.RULE_SIZE + 1)
  local syntheticRulesArchive = {
    memberCount = function() return ruleArchive:memberCount() end,
    readMember = function(_, memberId)
      if memberId == 0 then return syntheticCommonBytes end
      if memberId == 1 then return syntheticSectionBytes end
      return ruleArchive:readMember(memberId)
    end,
  }
  local syntheticRomFs = {
    openNarc = function(_, alias)
      if alias == Sources.ARCHIVES.rules then return syntheticRulesArchive end
      return romFs:openNarc(alias)
    end,
    version = function() return versionId end,
    metadata = function() return romFs:metadata() end,
  }
  local syntheticCatalog = assert(Compiler.compile(syntheticRomFs)).catalog
  local expectedSyntheticRows = activeRows(Compiler, syntheticSectionBytes, Sources.SECTION_RULE_COUNT)
  for row = 12, Sources.COMMON_RULE_COUNT - 1 do
    local offset = row * Sources.RULE_SIZE
    local rule = Compiler.decodeRuleMember(commonBytes:sub(offset + 1, offset + Sources.RULE_SIZE))
    if rule.interactionId ~= 0 then
      expectedSyntheticRows[#expectedSyntheticRows + 1] = rule
    end
  end
  Assert.deepEqual(syntheticCatalog.rulesByMapSection[1], expectedSyntheticRows,
    "inactive common prefix rows do not move tail rows ahead of section rows")

  local sectionCount = 0
  local exactMapIdRuleCount = 0
  for _, rules in pairs(catalog.rulesByMapSection) do
    sectionCount = sectionCount + 1
    for _, rule in ipairs(rules) do
      Assert.notNil(catalog.programs[rule.interactionId], "every active rule resolves to a program")
      Assert.isNil(rule.criteria.mapSectionId, "map-section selection is represented by the enclosing rules key")
      if rule.criteria.mapId ~= nil then
        exactMapIdRuleCount = exactMapIdRuleCount + 1
      end
    end
  end
  Assert.isTrue(sectionCount > 0, "the source corpus publishes map-section rules")
  Assert.isTrue(exactMapIdRuleCount > 0, "the source corpus includes exact map-ID criteria")

  local speciesClasses = catalog.speciesClassBySpeciesId
  Assert.isNil(catalog.mapClassByMapId)
  local classesArchive = assert(romFs:openNarc(Sources.ARCHIVES.speciesClasses))
  local classesBytes = assert(classesArchive:readMember(0))
  Assert.equal(#classesBytes, 496)
  for _, speciesId in ipairs({ 1, 60, 493 }) do
    Assert.equal(speciesClasses[speciesId], classesBytes:byte(speciesId))
  end
  Assert.isNil(speciesClasses[494])

  local packedRow = string.rep("\0", 9) .. string.char(0xB3) .. string.rep("\0", Sources.RULE_SIZE - 10)
  local packedCriteria = Compiler.decodeRuleMember(packedRow)
  Assert.isNil(packedCriteria.criteria.reservedReject)
  Assert.equal(packedCriteria.criteria.facingClass, 5)

  for motionId, motion in pairs(catalog.motions) do
    Assert.isTrue(type(motionId) == "number", "motion keys are semantic IDs")
    Assert.isTrue(#motion <= 10, "source motion terminators cap each sequence at ten records")
  end
  for selector = 1, 14 do
    local reaction = assert(catalog.reactions[selector], "every retail reaction selector resolves")
    Assert.equal(reaction.definition, "follower_reaction_" .. selector)
    Assert.equal(reaction.resourceKey, "data/generated/field/effects/follower_reaction_" .. selector .. ".lua")
  end
  for accessoryId = 0, 99 do
    local names = assert(catalog.fashionNames[accessoryId])
    Assert.isTrue(type(names.name) == "string" and names.name ~= "", "plain accessory name is decoded")
    Assert.isTrue(type(names.nameWithArticle) == "string" and names.nameWithArticle ~= "", "article name is decoded")
  end
end

function T.source_member_projects_exactly_to_species_entries(romFs, versionId)
  local catalog = catalogFor(romFs, versionId)
  Assert.isTrue(Cache.validateCatalog(catalog), "compiled interaction catalog must satisfy its strict schema")

  local classesArchive = assert(romFs:openNarc(Sources.ARCHIVES.speciesClasses))
  local classesBytes = assert(classesArchive:readMember(0))
  Assert.equal(#classesBytes, 496, "the raw source member keeps its 496-byte shape")

  local speciesClasses = assert(catalog.speciesClassBySpeciesId, "the catalog publishes species-owned classes")
  for _, speciesId in ipairs({ 1, 60, 493 }) do
    Assert.equal(speciesClasses[speciesId], classesBytes:byte(speciesId), "species entry " .. speciesId)
  end
  for speciesId = 1, 493 do
    Assert.notNil(speciesClasses[speciesId], "every native species keeps its class entry")
  end
  Assert.isNil(speciesClasses[494], "no class entry exists beyond the native species domain")
  Assert.isNil(catalog.mapClassByMapId, "the catalog carries no map-owned class table")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
