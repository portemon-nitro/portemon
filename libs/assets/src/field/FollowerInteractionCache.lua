-- Strict cache contract for source-independent following-Pokémon interactions.

local Contract = require("libs.assets.src.DerivedAssetContract")
local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")

local FollowerInteractionCache = {}
FollowerInteractionCache.FORMAT = Contract.followerInteractions.cacheFormat
FollowerInteractionCache.SCHEMA = Contract.followerInteractions.schema

local ROOT = "data/generated/field/follower-interactions"
local CATALOG = ROOT .. "/catalog.lua"
local MARKER = ROOT .. "/complete"

local function exactKeys(value, fields)
  if type(value) ~= "table" then
    return false
  end
  for key in pairs(value) do
    if not fields[key] then
      return false
    end
  end
  for key in pairs(fields) do
    if value[key] == nil then
      return false
    end
  end
  return true
end

local function integer(value, minimum, maximum)
  return Validate.isNonNegativeInteger(value) and value >= minimum and value <= maximum
end

local function onlyKnownKeys(value, fields)
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

local function validateSound(sound)
  if type(sound) ~= "table" then
    return false
  end
  if sound.kind == "effect" then
    return exactKeys(sound, { kind = true, id = true }) and integer(sound.id, 1, 2378)
  end
  return sound.kind == "cry"
    and exactKeys(sound, { kind = true, pattern = true })
    and (sound.pattern == 0 or sound.pattern == 11)
end

local CRITERIA = {
  heldItemClass = 31,
  hpClass = 0xFF,
  moodClass = 15,
  friendshipClass = 15,
  statusClass = 7,
  genderClass = 3,
  natureClass = 7,
  leafClass = 5,
  mapClass = 0xFF,
  specialSpriteClass = 3,
  nearbyObjectClass = 7,
  hiddenItemClass = 7,
  weatherClass = 7,
  timeClass = 7,
  facingClass = 7,
  typeClass = 31,
  pokeathlonClass = 7,
  levelClass = 3,
  encounterClass = 0xFF,
  mapId = 0xFFFF,
  metatileBehaviorId = 0xFFFF,
}

local function validateRule(rule)
  if
    not onlyKnownKeys(rule, {
      interactionId = true,
      percentage = true,
      requiredFlagId = true,
      criteria = true,
    })
  then
    return false
  end
  if not integer(rule.interactionId, 1, 1023) or not integer(rule.percentage, 0, 100) then
    return false
  end
  if rule.requiredFlagId ~= nil and not integer(rule.requiredFlagId, 1, 0xFFFF) then
    return false
  end
  if not onlyKnownKeys(rule.criteria, CRITERIA) then
    return false
  end
  for key, maximum in pairs(CRITERIA) do
    if key == "mapId" or key == "metatileBehaviorId" then
      if rule.criteria[key] ~= nil and not integer(rule.criteria[key], 0, maximum) then
        return false
      end
    elseif not integer(rule.criteria[key], 0, maximum) then
      return false
    end
  end
  return true
end

local function validateProgram(program)
  if
    not onlyKnownKeys(program, {
      steps = true,
      continuation = true,
      friendshipDelta = true,
      moodDelta = true,
      fashionAccessoryId = true,
      shinyLeafId = true,
    })
    or not Validate.isArray(program.steps)
    or #program.steps > 5
  then
    return false
  end
  for _, step in ipairs(program.steps) do
    if
      not onlyKnownKeys(step, {
        motionId = true,
        messageId = true,
        sound = true,
        reactionId = true,
        delayTicks = true,
      })
      or (step.motionId ~= nil and not integer(step.motionId, 1, 108))
      or (step.messageId ~= nil and not integer(step.messageId, 0, 0xFFFE))
      or (step.sound ~= nil and not validateSound(step.sound))
      or not integer(step.reactionId, 0, 14)
      or not integer(step.delayTicks, 0, 0xFF)
    then
      return false
    end
  end
  if program.continuation ~= nil then
    if
      not exactKeys(program.continuation, { choice0InteractionId = true, choice1InteractionId = true })
      or not integer(program.continuation.choice0InteractionId, 0, 1023)
      or not integer(program.continuation.choice1InteractionId, 0, 1023)
    then
      return false
    end
  end
  if not integer(program.friendshipDelta, -128, 127) or not integer(program.moodDelta, -128, 127) then
    -- Signed fields are checked separately because the shared integer helper
    -- is deliberately non-negative.
    if
      type(program.friendshipDelta) ~= "number"
      or program.friendshipDelta % 1 ~= 0
      or program.friendshipDelta < -128
      or program.friendshipDelta > 127
      or type(program.moodDelta) ~= "number"
      or program.moodDelta % 1 ~= 0
      or program.moodDelta < -128
      or program.moodDelta > 127
    then
      return false
    end
  end
  if program.fashionAccessoryId ~= nil and not integer(program.fashionAccessoryId, 0, 99) then
    return false
  end
  if program.shinyLeafId ~= nil and not integer(program.shinyLeafId, 1, 5) then
    return false
  end
  return true
end

local function validMotionDelta(value)
  if type(value) ~= "number" or value ~= value or value < -8 or value > 127 / 16 then
    return false
  end
  return value * 16 % 1 == 0
end

local function validateMotion(motion)
  if not Validate.isArray(motion) or #motion > 10 then
    return false
  end
  for _, record in ipairs(motion) do
    if
      not exactKeys(record, { x = true, y = true, z = true, facing = true, ticks = true, sound = true })
      or not integer(record.facing, 0, 4)
      or not validMotionDelta(record.x)
      or not validMotionDelta(record.y)
      or not validMotionDelta(record.z)
      or not integer(record.ticks, 0, 0xFF)
      or type(record.sound) ~= "boolean"
    then
      return false
    end
  end
  return true
end

local function validKeyedRecords(records, validateRecord, minimumKey, maximumKey)
  if type(records) ~= "table" then
    return false
  end
  for key, record in pairs(records) do
    if not integer(key, minimumKey, maximumKey) or not validateRecord(record) then
      return false
    end
  end
  return true
end

---@param catalog table<string, unknown>
---@return boolean, Errors.Error?
function FollowerInteractionCache.validateCatalog(catalog)
  local fields = {
    schema = true,
    version = true,
    rulesByMapSection = true,
    programs = true,
    motions = true,
    reactions = true,
    mapClassByMapId = true,
    locationNames = true,
    fashionNames = true,
  }
  local function invalid(reason)
    return false, Errors.new("FOLLOWER_INTERACTION_INVALID", "follower interaction catalog " .. reason, {})
  end
  if not exactKeys(catalog, fields) or catalog.schema ~= FollowerInteractionCache.SCHEMA then
    return invalid("has an unknown shape or schema")
  end
  if type(catalog.programs) ~= "table" then
    return invalid("has invalid programs")
  end
  if catalog.version ~= "heartgold" and catalog.version ~= "soulsilver" then
    return invalid("has an unsupported game version")
  end
  if type(catalog.rulesByMapSection) ~= "table" then
    return invalid("has invalid section rules")
  end
  for sectionId, rules in pairs(catalog.rulesByMapSection) do
    if not integer(sectionId, 0, 235) or not Validate.isArray(rules) then
      return invalid("has invalid section rule ordering")
    end
    for _, rule in ipairs(rules) do
      if not validateRule(rule) or catalog.programs[rule.interactionId] == nil then
        return invalid("has an invalid rule")
      end
    end
  end
  for sectionId = 0, 235 do
    if catalog.rulesByMapSection[sectionId] == nil then
      return invalid("is missing a map section rule list")
    end
  end
  if not validKeyedRecords(catalog.programs, validateProgram, 1, 1023) then
    return invalid("has invalid programs")
  end
  if not validKeyedRecords(catalog.motions, validateMotion, 1, 108) then
    return invalid("has invalid motions")
  end
  if
    not validKeyedRecords(catalog.reactions, function(value)
      return exactKeys(value, { definition = true, resourceKey = true })
        and type(value.definition) == "string"
        and value.definition ~= ""
        and type(value.resourceKey) == "string"
        and value.resourceKey ~= ""
    end, 1, 14)
  then
    return invalid("has invalid reactions")
  end
  for selector = 1, 14 do
    local reaction = catalog.reactions[selector]
    local definition = "follower_reaction_" .. selector
    if
      reaction == nil
      or reaction.definition ~= definition
      or reaction.resourceKey ~= FieldEffectAssetCache.definitionPath(definition)
    then
      return invalid("has an invalid reaction resource")
    end
  end
  for _, program in pairs(catalog.programs) do
    for _, step in ipairs(program.steps) do
      if
        (step.motionId ~= nil and catalog.motions[step.motionId] == nil)
        or (step.reactionId ~= 0 and catalog.reactions[step.reactionId] == nil)
      then
        return invalid("has an unresolved program reference")
      end
    end
    if program.continuation ~= nil then
      for _, interactionId in ipairs({
        program.continuation.choice0InteractionId,
        program.continuation.choice1InteractionId,
      }) do
        if interactionId ~= 0 and catalog.programs[interactionId] == nil then
          return invalid("has an unresolved continuation")
        end
      end
    end
  end
  if
    not validKeyedRecords(catalog.mapClassByMapId, function(class)
      return integer(class, 0, 0xFF)
    end, 1, 496)
  then
    return invalid("has invalid map classes")
  end
  for mapId = 1, 496 do
    if catalog.mapClassByMapId[mapId] == nil then
      return invalid("is missing a map class")
    end
  end
  if type(catalog.locationNames) ~= "table" then
    return invalid("has invalid location names")
  end
  for sectionId, name in pairs(catalog.locationNames) do
    if not integer(sectionId, 0, 0xFFFF) or type(name) ~= "string" or name == "" then
      return invalid("has an invalid location name")
    end
  end
  if type(catalog.fashionNames) ~= "table" then
    return invalid("has invalid Fashion names")
  end
  for accessoryId = 0, 99 do
    local name = catalog.fashionNames[accessoryId]
    if
      not exactKeys(name, { name = true, nameWithArticle = true })
      or type(name.name) ~= "string"
      or name.name == ""
      or type(name.nameWithArticle) ~= "string"
      or name.nameWithArticle == ""
    then
      return invalid("is missing Fashion names")
    end
  end
  for key in pairs(catalog.fashionNames) do
    if not integer(key, 0, 99) then
      return invalid("has an out-of-range Fashion name")
    end
  end
  return true
end

function FollowerInteractionCache.catalogPath()
  return CATALOG
end

function FollowerInteractionCache.markerPath()
  return MARKER
end

function FollowerInteractionCache.dir()
  return ROOT
end

function FollowerInteractionCache.marker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", FollowerInteractionCache.FORMAT, romSha1, dependencyHash)
end

function FollowerInteractionCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(MARKER) ~= expectedMarker then
    return false
  end
  local ok, catalog = pcall(cacheFs.loadLua, cacheFs, CATALOG)
  if not ok or type(catalog) ~= "table" then
    return false
  end
  return FollowerInteractionCache.validateCatalog(catalog)
end

return FollowerInteractionCache
