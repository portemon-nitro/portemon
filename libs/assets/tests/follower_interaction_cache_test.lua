local Assert = require("tests.support.Assert")
local Contract = require("libs.assets.src.DerivedAssetContract")
local Cache = require("libs.assets.src.field.FollowerInteractionCache")

local T = {}

local function catalog()
  local rulesByMapSection = {}
  for sectionId = 0, 235 do
    rulesByMapSection[sectionId] = {}
  end
  rulesByMapSection[1] = {
    {
      interactionId = 1,
      percentage = 100,
      requiredFlagId = 800,
      criteria = {
        heldItemClass = 0,
        hpClass = 0,
        statusClass = 0,
        friendshipClass = 0,
        moodClass = 0,
        genderClass = 0,
        natureClass = 0,
        leafClass = 0,
        speciesClass = 0,
        specialSpriteClass = 0,
        nearbyObjectClass = 0,
        hiddenItemClass = 0,
        weatherClass = 0,
        timeClass = 0,
        facingClass = 0,
        reservedReject = 0,
        typeClass = 0,
        pokeathlonClass = 0,
        levelClass = 0,
        encounterClass = 0,
        mapId = 0x1233,
        metatileBehaviorId = 0,
      },
    },
  }
  local fashionNames = {}
  local reactions = {}
  local speciesClassBySpeciesId = {}
  for accessoryId = 0, 99 do
    fashionNames[accessoryId] = { name = "Accessory", nameWithArticle = "an Accessory" }
  end
  for selector = 1, 14 do
    reactions[selector] = {
      definition = "follower_reaction_" .. selector,
      resourceKey = "data/generated/field/effects/follower_reaction_" .. selector .. ".lua",
    }
  end
  for speciesId = 1, 496 do
    speciesClassBySpeciesId[speciesId] = 0
  end
  return {
    schema = Contract.followerInteractions.schema,
    version = "soulsilver",
    rulesByMapSection = rulesByMapSection,
    programs = {
      [1] = {
        steps = { { motionId = 1, messageId = 1, soundId = 0, reactionId = 1, delayTicks = 1 } },
        friendshipDelta = 0,
        moodDelta = 0,
        continuation = { choice0InteractionId = 2, choice1InteractionId = 3 },
      },
      [2] = { steps = {}, friendshipDelta = 0, moodDelta = 0 },
      [3] = { steps = {}, friendshipDelta = 0, moodDelta = 0 },
    },
    motions = {
      [1] = { { facing = 0, x = 0, y = 0, z = 0, ticks = 1, sound = false } },
    },
    reactions = reactions,
    speciesClassBySpeciesId = speciesClassBySpeciesId,
    locationNames = { [1] = "New Bark Town" },
    fashionNames = fashionNames,
  }
end

function T.validates_a_current_source_independent_catalog()
  local valid, err = Cache.validateCatalog(catalog())
  Assert.isTrue(valid, err and err.message)
end

function T.rejects_old_schema_and_unknown_catalog_fields()
  local stale = catalog()
  stale.schema = "g4-follower-interactions-v0"
  Assert.isFalse(Cache.validateCatalog(stale))
  local unknown = catalog()
  unknown.sourceArchive = 222
  Assert.isFalse(Cache.validateCatalog(unknown))
end

function T.rejects_missing_or_out_of_range_map_sections()
  local missing = catalog()
  missing.rulesByMapSection[235] = nil
  Assert.isFalse(Cache.validateCatalog(missing))

  local outOfRange = catalog()
  outOfRange.rulesByMapSection[236] = {}
  Assert.isFalse(Cache.validateCatalog(outOfRange))
end

function T.rejects_incomplete_rule_criteria_and_unknown_fashion_ids()
  local incomplete = catalog()
  incomplete.rulesByMapSection[1][1].criteria.encounterClass = nil
  Assert.isFalse(Cache.validateCatalog(incomplete))
  local invalidFashion = catalog()
  invalidFashion.fashionNames[100] = { name = "x", nameWithArticle = "x" }
  Assert.isFalse(Cache.validateCatalog(invalidFashion))
end

function T.keeps_exact_map_id_criteria_separate_from_section_rule_selection()
  local current = catalog()
  Assert.isTrue(Cache.validateCatalog(current))
  Assert.equal(current.rulesByMapSection[1][1].criteria.mapId, 0x1233)

  local oldCriterion = catalog()
  oldCriterion.rulesByMapSection[1][1].criteria.mapSectionId = 0x1233
  oldCriterion.rulesByMapSection[1][1].criteria.mapId = nil
  Assert.isFalse(Cache.validateCatalog(oldCriterion))
end

function T.rejects_unresolved_program_resources_and_old_nested_shapes()
  local unresolved = catalog()
  unresolved.programs[1].steps[1].motionId = 2
  Assert.isFalse(Cache.validateCatalog(unresolved))

  local oldMotion = catalog()
  oldMotion.motions[1] = { records = { { facing = 0, xOffset = 0, zOffset = 0, ticks = 1, soundId = 0 } } }
  Assert.isFalse(Cache.validateCatalog(oldMotion))

  local oldFashion = catalog()
  oldFashion.fashionNames[0] = { plainName = "Accessory", articleName = "an Accessory" }
  Assert.isFalse(Cache.validateCatalog(oldFashion))
end

function T.requires_all_retail_reaction_selectors()
  local incomplete = catalog()
  incomplete.reactions[14] = nil
  Assert.isFalse(Cache.validateCatalog(incomplete))
end

function T.validates_species_class_ids_reserved_reject_and_special_sprite_classes()
  local invalidSpecies = catalog()
  invalidSpecies.speciesClassBySpeciesId[0] = 0
  Assert.isFalse(Cache.validateCatalog(invalidSpecies))

  local missingSpecies = catalog()
  missingSpecies.speciesClassBySpeciesId[496] = nil
  Assert.isFalse(Cache.validateCatalog(missingSpecies))

  local missingReservedReject = catalog()
  missingReservedReject.rulesByMapSection[1][1].criteria.reservedReject = nil
  Assert.isFalse(Cache.validateCatalog(missingReservedReject))

  local invalidReservedReject = catalog()
  invalidReservedReject.rulesByMapSection[1][1].criteria.reservedReject = 32
  Assert.isFalse(Cache.validateCatalog(invalidReservedReject))

  local invalidSpecialSprite = catalog()
  invalidSpecialSprite.rulesByMapSection[1][1].criteria.specialSpriteClass = 4
  Assert.isFalse(Cache.validateCatalog(invalidSpecialSprite))

end

function T.rejects_reaction_definitions_or_resources_for_another_selector()
  local mismatchedDefinition = catalog()
  mismatchedDefinition.reactions[1].definition = "follower_reaction_2"
  Assert.isFalse(Cache.validateCatalog(mismatchedDefinition))

  local mismatchedResource = catalog()
  mismatchedResource.reactions[1].resourceKey = "data/generated/field/effects/follower_reaction_2.lua"
  Assert.isFalse(Cache.validateCatalog(mismatchedResource))
end

function T.held_item_is_the_only_item_class_criterion()
  local catalogWithoutInventedPredicate = catalog()
  Assert.isTrue(Cache.validateCatalog(catalogWithoutInventedPredicate))
  local catalogWithInventedPredicate = catalog()
  catalogWithInventedPredicate.rulesByMapSection[1][1].criteria.naturalGiftClass = 0
  Assert.isFalse(Cache.validateCatalog(catalogWithInventedPredicate))
end

return { tests = T }
