-- Authoritative validation for the source-independent battle input class: the
-- compiled move battle facts plus the trainer and encounter catalogs the
-- native import pipeline publishes. These validators check semantic
-- references and discriminated payload shapes only, never Nintendo bit
-- layouts; native-identity universes stay with the producer inventory and
-- the ROM conformance suites. Shared neutral shape checks live here so the
-- native producer schemas reuse them instead of cloning record validation.
-- Love-free and filesystem-free.

local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")

---@class BattleDataSchema
local BattleDataSchema = {}

local TYPE_KEYS = {
  normal = true,
  fighting = true,
  flying = true,
  poison = true,
  ground = true,
  rock = true,
  bug = true,
  ghost = true,
  steel = true,
  mystery = true,
  fire = true,
  water = true,
  grass = true,
  electric = true,
  psychic = true,
  ice = true,
  dragon = true,
  dark = true,
}

local CATEGORY_KEYS = { physical = true, special = true, status = true }

local function fail(code, message, context)
  Errors.raise(code, message, context or {})
end

local function checkRecord(record, allowed, context, code, field)
  if type(record) ~= "table" then
    fail(code, field .. " must be a record", context)
  end
  if allowed ~= nil then
    for key in pairs(record) do
      if allowed[key] == nil then
        fail(code, field .. " carries unknown field " .. tostring(key), context)
      end
    end
  end
end

local function checkInt(value, lower, upper, context, code, field)
  if type(value) ~= "number" or value % 1 ~= 0 or value < lower or (upper ~= nil and value > upper) then
    fail(code, field .. " must be an integer in " .. tostring(lower) .. ".." .. tostring(upper), context)
  end
end

local function checkNonEmptyString(value, context, code, field)
  if type(value) ~= "string" or value == "" then
    fail(code, field .. " must be a non-empty string", context)
  end
end

-- One semantic behavior reference: the bound behavior key plus its
-- serializable parameters. Parameter values stay scalar so staged payloads
-- remain plain data.
function BattleDataSchema.assertBehaviorRef(behavior, context, field)
  context = context or {}
  field = field or "behavior"
  checkRecord(behavior, { key = true, params = true }, context, "BATTLE_DATA_INVALID", field)
  checkNonEmptyString(behavior.key, context, "BATTLE_DATA_INVALID", field .. ".key")
  if type(behavior.params) ~= "table" then
    fail("BATTLE_DATA_INVALID", field .. ".params must be a record", context)
  end
  for name, value in pairs(behavior.params) do
    if type(name) ~= "string" or name == "" then
      fail("BATTLE_DATA_INVALID", field .. ".params carries an unnamed parameter", context)
    end
    if type(value) ~= "string" and type(value) ~= "number" and type(value) ~= "boolean" then
      fail("BATTLE_DATA_INVALID", field .. ".params." .. name .. " must be a scalar", context)
    end
  end
  return true
end

-- Shared source type-key membership: the lower-case type vocabulary is one
-- source fact, so producer schemas reuse this check instead of cloning the
-- key set. The value itself must name a key; callers that admit absent
-- values branch on nil before calling here.
function BattleDataSchema.assertTypeKey(typeKey, context, field)
  context = context or {}
  field = field or "type"
  if type(typeKey) ~= "string" or TYPE_KEYS[typeKey] == nil then
    fail("BATTLE_DATA_INVALID", field .. " must name a source type key", context)
  end
  return true
end

-- Named boolean execution flags: every flag name is a non-empty string and
-- every value is a boolean, so consumers never interpret absent flags.
local function checkFlags(flags, context, code, field)
  if type(flags) ~= "table" then
    fail(code, field .. " must be a record", context)
  end
  for name, value in pairs(flags) do
    if type(name) ~= "string" or name == "" then
      fail(code, field .. " carries an unnamed flag", context)
    end
    if type(value) ~= "boolean" then
      fail(code, field .. " flag " .. name .. " must be a boolean", context)
    end
  end
end

-- Shared execution-meaning record: a behavior reference plus a named target
-- and boolean flags. Both the battle-data facts and the native mon catalog
-- reuse this check instead of cloning record validation.
function BattleDataSchema.assertBattleRecord(battle, context, field)
  context = context or {}
  field = field or "battle"
  checkRecord(battle, { behavior = true, target = true, flags = true }, context, "BATTLE_DATA_INVALID", field)
  BattleDataSchema.assertBehaviorRef(battle.behavior, context, field .. " behavior")
  checkNonEmptyString(battle.target, context, "BATTLE_DATA_INVALID", field .. " target")
  checkFlags(battle.flags, context, "BATTLE_DATA_INVALID", field .. " flags")
  return true
end

-- Semantic move battle facts: native numbers keep their source values and
-- spelling (lower-case type key, basePp), execution meaning travels as a
-- behavior reference plus a named target and boolean flags.
function BattleDataSchema.assertMoveBattleFacts(facts, context)
  context = context or {}
  checkRecord(facts, {
    nativeId = true,
    name = true,
    description = true,
    effect = true,
    category = true,
    power = true,
    moveType = true,
    accuracy = true,
    basePp = true,
    effectChance = true,
    range = true,
    priority = true,
    behavior = true,
    target = true,
    flags = true,
  }, context, "BATTLE_DATA_INVALID", "move")
  checkInt(facts.nativeId, 1, nil, context, "BATTLE_DATA_INVALID", "move nativeId")
  checkNonEmptyString(facts.name, context, "BATTLE_DATA_INVALID", "move name")
  if type(facts.description) ~= "string" then
    fail("BATTLE_DATA_INVALID", "move description must be a string", context)
  end
  checkInt(facts.effect, 0, 65535, context, "BATTLE_DATA_INVALID", "move effect")
  if CATEGORY_KEYS[facts.category] == nil then
    fail("BATTLE_DATA_INVALID", "move carries an unknown category", context)
  end
  checkInt(facts.power, 0, 255, context, "BATTLE_DATA_INVALID", "move power")
  if TYPE_KEYS[facts.moveType] == nil then
    fail("BATTLE_DATA_INVALID", "move carries an unknown type", context)
  end
  checkInt(facts.accuracy, 0, 100, context, "BATTLE_DATA_INVALID", "move accuracy")
  checkInt(facts.basePp, 0, 40, context, "BATTLE_DATA_INVALID", "move basePp")
  checkInt(facts.effectChance, 0, 100, context, "BATTLE_DATA_INVALID", "move effectChance")
  checkInt(facts.range, 0, 65535, context, "BATTLE_DATA_INVALID", "move range")
  checkInt(facts.priority, -128, 127, context, "BATTLE_DATA_INVALID", "move priority")
  BattleDataSchema.assertBattleRecord({
    behavior = facts.behavior,
    target = facts.target,
    flags = facts.flags,
  }, context, "move battle")
  return true
end

-- Compiled battle data: one version plus every projected move keyed by its
-- semantic key. Totality (every usable native move resolves exactly once)
-- is the producer coverage step, not this shape check.
function BattleDataSchema.assertBattleData(compiled)
  local context = {}
  checkRecord(compiled, {
    schema = true,
    version = true,
    moves = true,
  }, context, "BATTLE_DATA_INVALID", "battle data")
  checkNonEmptyString(compiled.schema, context, "BATTLE_DATA_INVALID", "battle data schema")
  checkRecord(compiled.version, { id = true }, context, "BATTLE_DATA_INVALID", "battle data version")
  checkNonEmptyString(compiled.version.id, context, "BATTLE_DATA_INVALID", "battle data version id")
  checkRecord(compiled.moves, nil, context, "BATTLE_DATA_INVALID", "battle data moves")
  for key, facts in pairs(compiled.moves) do
    if type(key) ~= "string" or key == "" then
      fail("BATTLE_DATA_INVALID", "move keys must be non-empty strings", context)
    end
    BattleDataSchema.assertMoveBattleFacts(facts, { move = key })
  end
  return true
end

local function checkIdentityParams(params, context, field)
  if type(params) ~= "table" then
    fail("BATTLE_DATA_INVALID", field .. " must be a record", context)
  end
end

local function assertTemplate(template, context, field)
  checkRecord(template, {
    species = true,
    form = true,
    level = true,
    difficulty = true,
    heldItem = true,
    moves = true,
    identityPolicy = true,
    identityParams = true,
  }, context, "BATTLE_DATA_INVALID", field)
  checkNonEmptyString(template.species, context, "BATTLE_DATA_INVALID", field .. ".species")
  checkInt(template.form, 0, nil, context, "BATTLE_DATA_INVALID", field .. ".form")
  checkInt(template.level, 0, 255, context, "BATTLE_DATA_INVALID", field .. ".level")
  checkInt(template.difficulty, 0, 255, context, "BATTLE_DATA_INVALID", field .. ".difficulty")
  checkNonEmptyString(template.heldItem, context, "BATTLE_DATA_INVALID", field .. ".heldItem")
  if template.moves ~= nil then
    if not Validate.isArray(template.moves) then
      fail("BATTLE_DATA_INVALID", field .. ".moves must be an array", context)
    end
    for _, moveKey in ipairs(template.moves) do
      checkNonEmptyString(moveKey, context, "BATTLE_DATA_INVALID", field .. ".moves entry")
    end
  end
  checkNonEmptyString(template.identityPolicy, context, "BATTLE_DATA_INVALID", field .. ".identityPolicy")
  checkIdentityParams(template.identityParams, context, field .. ".identityParams")
end

local function assertNameReference(reference, context)
  checkRecord(reference, nil, context, "BATTLE_DATA_INVALID", "trainer nameReference")
  if reference.rival == true then
    if reference.trainerIndex ~= nil then
      fail("BATTLE_DATA_INVALID", "a rival indirection carries no bank index", context)
    end
  elseif type(reference.trainerIndex) ~= "number" or reference.trainerIndex % 1 ~= 0 then
    fail("BATTLE_DATA_INVALID", "a bank name reference carries its trainer index", context)
  end
end

--- Projected trainer record: one trainer class, its ordered party, its
--- named passes, and the compact ordered list of carried items with
--- zero to four real item keys in source order.
local function assertTrainerRecord(trainerIndex, record)
  local context = { trainer = trainerIndex }
  checkRecord(record, {
    trainerClass = true,
    nameReference = true,
    party = true,
    aiPasses = true,
    doubleBattle = true,
    items = true,
    prizeMoney = true,
    messageSelectors = true,
  }, context, "BATTLE_DATA_INVALID", "trainer " .. tostring(trainerIndex))
  checkInt(record.trainerClass, 0, nil, context, "BATTLE_DATA_INVALID", "trainer class")
  assertNameReference(record.nameReference, context)
  if not Validate.isArray(record.party) then
    fail("BATTLE_DATA_INVALID", "trainer party must be an array", context)
  end
  for slot, template in ipairs(record.party) do
    assertTemplate(template, context, "trainer party slot " .. slot)
  end
  if not Validate.isArray(record.aiPasses) then
    fail("BATTLE_DATA_INVALID", "trainer aiPasses must be an array", context)
  end
  for _, pass in ipairs(record.aiPasses) do
    checkNonEmptyString(pass, context, "BATTLE_DATA_INVALID", "trainer aiPass")
  end
  if type(record.doubleBattle) ~= "boolean" then
    fail("BATTLE_DATA_INVALID", "trainer doubleBattle must be a boolean", context)
  end
  -- Carried items compact at the semantic boundary: an ordered list
  -- of zero to four real item keys in source order. "NONE" is never
  -- a carried item here; working-slot padding lives in battle memory.
  if not Validate.isArray(record.items) or #record.items > 4 then
    fail("BATTLE_DATA_INVALID", "trainer items must carry at most four ordered items", context)
  end
  for _, itemKey in ipairs(record.items) do
    checkNonEmptyString(itemKey, context, "BATTLE_DATA_INVALID", "trainer item")
    if itemKey == "NONE" then
      fail("BATTLE_DATA_INVALID", "trainer items carry only real carried items", context)
    end
  end
  checkRecord(record.prizeMoney, nil, context, "BATTLE_DATA_INVALID", "trainer prizeMoney")
  checkRecord(record.messageSelectors, nil, context, "BATTLE_DATA_INVALID", "trainer messageSelectors")
end

-- Projected trainer catalog: one version plus every trainer record keyed by
-- its native trainer index with an ordered party of normalized templates.
function BattleDataSchema.assertTrainerCatalog(compiled)
  local context = {}
  checkRecord(compiled, {
    schema = true,
    version = true,
    trainers = true,
  }, context, "BATTLE_DATA_INVALID", "trainer catalog")
  checkNonEmptyString(compiled.schema, context, "BATTLE_DATA_INVALID", "trainer catalog schema")
  checkRecord(compiled.version, { id = true }, context, "BATTLE_DATA_INVALID", "trainer catalog version")
  checkNonEmptyString(compiled.version.id, context, "BATTLE_DATA_INVALID", "trainer catalog version id")
  checkRecord(compiled.trainers, nil, context, "BATTLE_DATA_INVALID", "trainer catalog trainers")
  for trainerIndex, record in pairs(compiled.trainers) do
    if type(trainerIndex) ~= "number" or trainerIndex % 1 ~= 0 then
      fail("BATTLE_DATA_INVALID", "trainer keys must be integer identities", context)
    end
    assertTrainerRecord(trainerIndex, record)
  end
  return true
end

local function assertEncounterSlot(slot, context, field)
  checkRecord(slot, {
    species = true,
    form = true,
    minLevel = true,
    maxLevel = true,
    weight = true,
  }, context, "BATTLE_DATA_INVALID", field)
  checkNonEmptyString(slot.species, context, "BATTLE_DATA_INVALID", field .. ".species")
  checkInt(slot.form, 0, nil, context, "BATTLE_DATA_INVALID", field .. ".form")
  checkInt(slot.minLevel, 0, 255, context, "BATTLE_DATA_INVALID", field .. ".minLevel")
  checkInt(slot.maxLevel, 0, 255, context, "BATTLE_DATA_INVALID", field .. ".maxLevel")
  if slot.minLevel > slot.maxLevel then
    fail("BATTLE_DATA_INVALID", field .. " carries an inverted level window", context)
  end
  checkInt(slot.weight, 0, nil, context, "BATTLE_DATA_INVALID", field .. ".weight")
end

local function assertSlotArray(slots, count, context, field)
  if not Validate.isArray(slots) or #slots ~= count then
    fail("BATTLE_DATA_INVALID", field .. " must carry exactly " .. count .. " ordered slots", context)
  end
  for index, slot in ipairs(slots) do
    assertEncounterSlot(slot, context, field .. " slot " .. index)
  end
end

local function assertReplacement(name, replacement, context)
  checkRecord(replacement, nil, context, "BATTLE_DATA_INVALID", "replacement " .. name)
  checkNonEmptyString(replacement.species, context, "BATTLE_DATA_INVALID", "replacement " .. name .. " species")
  checkInt(replacement.slot, 0, nil, context, "BATTLE_DATA_INVALID", "replacement " .. name .. " slot")
  checkNonEmptyString(replacement.game, context, "BATTLE_DATA_INVALID", "replacement " .. name .. " game")
end

local function assertEncounterTable(memberId, mapTable)
  local context = { member = memberId }
  checkRecord(mapTable, {
    rates = true,
    land = true,
    surf = true,
    rockSmash = true,
    oldRod = true,
    goodRod = true,
    superRod = true,
    replacements = true,
    special = true,
  }, context, "BATTLE_DATA_INVALID", "encounter table " .. tostring(memberId))
  checkRecord(mapTable.rates, {
    walking = true,
    surfing = true,
    rockSmash = true,
    oldRod = true,
    goodRod = true,
    superRod = true,
  }, context, "BATTLE_DATA_INVALID", "encounter rates")
  for _, method in ipairs({ "walking", "surfing", "rockSmash", "oldRod", "goodRod", "superRod" }) do
    checkInt(mapTable.rates[method], 0, 255, context, "BATTLE_DATA_INVALID", "encounter rate " .. method)
  end
  checkRecord(
    mapTable.land,
    { morning = true, day = true, night = true },
    context,
    "BATTLE_DATA_INVALID",
    "encounter land"
  )
  assertSlotArray(mapTable.land.morning, 12, context, "encounter morning")
  assertSlotArray(mapTable.land.day, 12, context, "encounter day")
  assertSlotArray(mapTable.land.night, 12, context, "encounter night")
  assertSlotArray(mapTable.surf, 5, context, "encounter surf")
  assertSlotArray(mapTable.rockSmash, 2, context, "encounter rockSmash")
  assertSlotArray(mapTable.oldRod, 5, context, "encounter oldRod")
  assertSlotArray(mapTable.goodRod, 5, context, "encounter goodRod")
  assertSlotArray(mapTable.superRod, 5, context, "encounter superRod")
  checkRecord(mapTable.replacements, nil, context, "BATTLE_DATA_INVALID", "encounter replacements")
  for name, replacement in pairs(mapTable.replacements) do
    assertReplacement(name, replacement, context)
  end
  if mapTable.special ~= nil then
    checkRecord(mapTable.special, nil, context, "BATTLE_DATA_INVALID", "encounter special")
    for name, record in pairs(mapTable.special) do
      checkRecord(record, nil, context, "BATTLE_DATA_INVALID", "special context " .. name)
      checkNonEmptyString(record.context, context, "BATTLE_DATA_INVALID", "special context " .. name .. " kind")
    end
  end
end

-- Projected encounter catalog: one version plus every map member table keyed
-- by its native member identity with ordered per-method slots.
function BattleDataSchema.assertEncounterCatalog(compiled)
  local context = {}
  checkRecord(compiled, {
    schema = true,
    version = true,
    tables = true,
  }, context, "BATTLE_DATA_INVALID", "encounter catalog")
  checkNonEmptyString(compiled.schema, context, "BATTLE_DATA_INVALID", "encounter catalog schema")
  checkRecord(compiled.version, { id = true }, context, "BATTLE_DATA_INVALID", "encounter catalog version")
  checkNonEmptyString(compiled.version.id, context, "BATTLE_DATA_INVALID", "encounter catalog version id")
  checkRecord(compiled.tables, nil, context, "BATTLE_DATA_INVALID", "encounter catalog tables")
  for memberId, mapTable in pairs(compiled.tables) do
    if type(memberId) ~= "number" or memberId % 1 ~= 0 then
      fail("BATTLE_DATA_INVALID", "encounter table keys must be integer identities", context)
    end
    assertEncounterTable(memberId, mapTable)
  end
  return true
end

return BattleDataSchema
