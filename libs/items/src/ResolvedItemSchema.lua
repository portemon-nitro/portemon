-- Validation for composed item catalog roots. The shape contract mirrors
-- the generated item asset catalog, with two deliberate policy differences:
-- native identities are optional (custom entries resolve semantically with
-- no numeric identity) and no full native-range coverage is required.
-- Declared native identities must still be unique integers in 0..536,
-- pocket definitions and display names keep their exact source contract,
-- and pocket-gated machine and berry identities apply unchanged. The strict
-- generated-asset validator is untouched: this schema never validates
-- ROM-produced roots.

local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")
local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")
local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")

---@class ResolvedItemSchema
local ResolvedItemSchema = {}

-- Pocket definitions are the schema-owned source contract, shared rather
-- than recopied so the two validators cannot drift apart.
ResolvedItemSchema.POCKETS = ItemAssetSchema.POCKETS
ResolvedItemSchema.MIN_NATIVE_ID = ItemAssetSchema.MIN_NATIVE_ID
ResolvedItemSchema.MAX_NATIVE_ID = ItemAssetSchema.MAX_NATIVE_ID
ResolvedItemSchema.MAX_MOVE_NATIVE_ID = ItemAssetSchema.MAX_MOVE_NATIVE_ID

local ITEM_FIELDS = {
  nativeId = true,
  price = true,
  name = true,
  nameIndefinite = true,
  namePlural = true,
  description = true,
  pocket = true,
  preventToss = true,
  selectable = true,
  isBall = true,
  friendshipBoost = true,
  tmhmMoveNativeId = true,
  berryNameSingular = true,
  berryNamePlural = true,
  icon = true,
  isHm = true,
  canHold = true,
  heldFormEffect = true,
  partyUse = true,
  heldBehavior = true,
  fling = true,
  naturalGift = true,
}

local function fail(message, context)
  Errors.raise("ITEM_RESOLVED_INVALID", message, context or {})
end

---@param record table<string, unknown>
---@param allowed table<string, boolean>
---@param context table<string, unknown>
local function checkKeys(record, allowed, context)
  for key in pairs(record) do
    if allowed[key] == nil then
      fail("unknown field " .. tostring(key), context)
    end
  end
end

---@param value unknown
---@param context table<string, unknown>
---@param field string
local function checkText(value, context, field)
  if type(value) ~= "string" or value == "" then
    fail(field .. " must be a non-empty string", context)
  end
end

---@param value unknown
---@param context table<string, unknown>
---@param field string
local function checkBoolean(value, context, field)
  if type(value) ~= "boolean" then
    fail(field .. " must be a boolean", context)
  end
end

---@param value unknown
---@param low integer
---@param high integer
---@param context table<string, unknown>
---@param field string
local function checkInteger(value, low, high, context, field)
  if type(value) ~= "number" or value % 1 ~= 0 or value < low or value > high then
    fail(field .. " must be an integer in " .. low .. ".." .. high, context)
  end
end

local EV_STATS = {
  hp = true,
  attack = true,
  defense = true,
  speed = true,
  specialAttack = true,
  specialDefense = true,
}

local DEFERRED_REASONS = {
  level_up = true,
  evolution = true,
  battle_only = true,
  mail = true,
  form_change = true,
}

---@param key string
---@param value table<string, unknown>
---@param context table<string, unknown>
local function assertFriendship(key, value, context)
  if value == nil then
    return
  end
  if type(value) ~= "table" then
    fail("item " .. key .. " partyUse friendship must be a record", context)
  end
  checkKeys(value, { lo = true, med = true, hi = true }, context)
  checkInteger(value.lo, -255, 255, context, "item " .. key .. " friendship lo")
  checkInteger(value.med, -255, 255, context, "item " .. key .. " friendship med")
  checkInteger(value.hi, -255, 255, context, "item " .. key .. " friendship hi")
end

---@param key string
---@param value integer
---@param context table<string, unknown>
local function assertMood(key, value, context)
  checkInteger(value, -127, 127, context, "item " .. key .. " partyUse mood")
end

---@param key string
---@param value table<string, unknown>
---@param context table<string, unknown>
local function assertMedicine(key, value, context)
  checkKeys(
    value,
    { kind = true, cures = true, restore = true, revive = true, friendship = true, mood = true },
    context
  )
  if type(value.cures) ~= "table" then
    fail("item " .. key .. " partyUse cures must be a record", context)
  end
  checkKeys(value.cures, { sleep = true, poison = true, burn = true, freeze = true, paralysis = true }, context)
  for _, cure in ipairs({ "sleep", "poison", "burn", "freeze", "paralysis" }) do
    checkBoolean(value.cures[cure], context, "item " .. key .. " cure " .. cure)
  end
  if value.restore ~= nil then
    if type(value.restore) ~= "table" then
      fail("item " .. key .. " partyUse restore must be a record", context)
    end
    checkKeys(value.restore, { kind = true, amount = true }, context)
    if
      value.restore.kind ~= "fixed"
      and value.restore.kind ~= "full"
      and value.restore.kind ~= "half"
      and value.restore.kind ~= "quarter"
    then
      fail("item " .. key .. " restore kind must be fixed, full, half or quarter", context)
    end
    if value.restore.kind == "fixed" then
      checkInteger(value.restore.amount, 1, 999, context, "item " .. key .. " restore amount")
    elseif value.restore.amount ~= nil then
      fail("item " .. key .. " non-fixed restore carries no amount", context)
    end
  end
  if value.revive ~= "none" and value.revive ~= "single" then
    fail("item " .. key .. " revive must be none or single", context)
  end
  assertFriendship(key, value.friendship, context)
  assertMood(key, value.mood, context)
end

---@param key string
---@param value table<string, unknown>
---@param context table<string, unknown>
local function assertPp(key, value, context)
  checkKeys(
    value,
    { kind = true, target = true, restore = true, boost = true, friendship = true, mood = true },
    context
  )
  if value.target ~= "one" and value.target ~= "all" then
    fail("item " .. key .. " power-point target must be one or all", context)
  end
  if value.restore ~= nil and value.boost ~= nil then
    fail("item " .. key .. " carries both restore and boost", context)
  end
  if value.restore ~= nil then
    if value.restore ~= "full" then
      checkInteger(value.restore, 1, 126, context, "item " .. key .. " restore")
    end
  elseif value.boost ~= nil then
    checkInteger(value.boost, 1, 3, context, "item " .. key .. " boost")
  else
    fail("item " .. key .. " carries no power-point operation", context)
  end
  assertFriendship(key, value.friendship, context)
  assertMood(key, value.mood, context)
end

---@param key string
---@param value table<string, unknown>
---@param context table<string, unknown>
local function assertEv(key, value, context)
  checkKeys(value, { kind = true, changes = true, friendship = true, mood = true }, context)
  if type(value.changes) ~= "table" or #value.changes == 0 then
    fail("item " .. key .. " partyUse changes must be a non-empty array", context)
  end
  for index, change in ipairs(value.changes) do
    if type(change) ~= "table" then
      fail("item " .. key .. " change " .. index .. " must be a record", context)
    end
    checkKeys(change, { stat = true, delta = true }, context)
    if EV_STATS[change.stat] ~= true then
      fail("item " .. key .. " change " .. index .. " names an unknown stat", context)
    end
    checkInteger(change.delta, -100, 100, context, "item " .. key .. " change " .. index .. " delta")
    if change.delta == 0 then
      fail("item " .. key .. " change " .. index .. " delta must not be zero", context)
    end
  end
  assertFriendship(key, value.friendship, context)
  assertMood(key, value.mood, context)
end

---@param key string
---@param value table<string, unknown>
---@param context table<string, unknown>
local function assertPartyUse(key, value, context)
  if type(value) ~= "table" then
    fail("item " .. key .. " partyUse must be a record", context)
  end
  if value.kind == "none" then
    checkKeys(value, { kind = true }, context)
  elseif value.kind == "medicine" then
    assertMedicine(key, value, context)
  elseif value.kind == "pp" then
    assertPp(key, value, context)
  elseif value.kind == "ev" then
    assertEv(key, value, context)
  elseif value.kind == "revive_all" then
    checkKeys(value, { kind = true }, context)
  elseif value.kind == "machine" then
    checkKeys(value, { kind = true }, context)
  elseif value.kind == "deferred" then
    checkKeys(value, { kind = true, reason = true }, context)
    if DEFERRED_REASONS[value.reason] ~= true then
      fail("item " .. key .. " deferral names an unknown reason", context)
    end
  else
    fail("item " .. key .. " partyUse kind must be a closed effect kind", context)
  end
end

---@param key string
---@param value table<string, unknown>
---@param context table<string, unknown>
local function assertFling(key, value, context)
  if type(value) ~= "table" then
    fail("item " .. key .. " fling must be a record", context)
  end
  checkKeys(value, { effect = true, power = true }, context)
  checkInteger(value.effect, 0, 255, context, "item " .. key .. " fling effect")
  checkInteger(value.power, 0, 255, context, "item " .. key .. " fling power")
end

---@param key string
---@param value table<string, unknown>
---@param context table<string, unknown>
local function assertNaturalGift(key, value, context)
  if type(value) ~= "table" then
    fail("item " .. key .. " naturalGift must be a record", context)
  end
  checkKeys(value, { power = true, typeId = true, type = true }, context)
  checkInteger(value.power, 0, 255, context, "item " .. key .. " natural-gift power")
  checkInteger(value.typeId, 0, 31, context, "item " .. key .. " natural-gift typeId")
  if value.type ~= nil then
    BattleDataSchema.assertTypeKey(value.type, context, "item " .. key .. " natural-gift type")
  end
end

---@param key string
---@param record table<string, unknown>
---@param context table<string, unknown>
local function assertItem(key, record, context)
  if type(key) ~= "string" or key == "" then
    fail("item keys must be non-empty strings", context)
  end
  if type(record) ~= "table" then
    fail("item " .. key .. " must be a record", context)
  end
  checkKeys(record, ITEM_FIELDS, context)
  -- Custom entries carry no numeric identity; declared identities stay in
  -- the native range and unique across the catalog.
  if record.nativeId ~= nil then
    checkInteger(
      record.nativeId,
      ResolvedItemSchema.MIN_NATIVE_ID,
      ResolvedItemSchema.MAX_NATIVE_ID,
      context,
      "item " .. key .. " nativeId"
    )
  end
  checkText(record.name, context, "item " .. key .. " name")
  checkText(record.nameIndefinite, context, "item " .. key .. " nameIndefinite")
  checkText(record.namePlural, context, "item " .. key .. " namePlural")
  -- Source prices ride the native catalog; custom entries may omit the
  -- price, while declared prices stay in the source u16 domain.
  if record.price ~= nil then
    checkInteger(record.price, 0, 65535, context, "item " .. key .. " price")
  end
  if type(record.description) ~= "string" then
    fail("item " .. key .. " description must be a string", context)
  end
  if ResolvedItemSchema.POCKETS[record.pocket] == nil then
    fail("item " .. key .. " has an unknown pocket", context)
  end
  checkBoolean(record.preventToss, context, "item " .. key .. " preventToss")
  checkBoolean(record.selectable, context, "item " .. key .. " selectable")
  checkBoolean(record.isBall, context, "item " .. key .. " isBall")
  checkBoolean(record.friendshipBoost, context, "item " .. key .. " friendshipBoost")
  checkText(record.icon, context, "item " .. key .. " icon")
  checkBoolean(record.isHm, context, "item " .. key .. " isHm")
  checkBoolean(record.canHold, context, "item " .. key .. " canHold")
  if
    record.heldFormEffect ~= "none"
    and record.heldFormEffect ~= "arceus_plate"
    and record.heldFormEffect ~= "griseous_orb"
  then
    fail("item " .. key .. " heldFormEffect must be none, arceus_plate or griseous_orb", context)
  end
  assertPartyUse(key, record.partyUse, context)
  if record.heldBehavior ~= nil then
    BattleDataSchema.assertBehaviorRef(record.heldBehavior, context, "item " .. key .. " heldBehavior")
  end
  if record.fling ~= nil then
    assertFling(key, record.fling, context)
  end
  if record.naturalGift ~= nil then
    assertNaturalGift(key, record.naturalGift, context)
  end
  if record.pocket == "tmhm" then
    checkInteger(
      record.tmhmMoveNativeId,
      0,
      ResolvedItemSchema.MAX_MOVE_NATIVE_ID,
      context,
      "item " .. key .. " tmhmMoveNativeId"
    )
  elseif record.tmhmMoveNativeId ~= nil then
    fail("item " .. key .. " carries a move identity outside the TM/HM pocket", context)
  end
  if record.pocket == "berries" then
    checkText(record.berryNameSingular, context, "item " .. key .. " berryNameSingular")
    checkText(record.berryNamePlural, context, "item " .. key .. " berryNamePlural")
  else
    if record.berryNameSingular ~= nil or record.berryNamePlural ~= nil then
      fail("item " .. key .. " carries berry names outside the berry pocket", context)
    end
  end
end

---@param items table<string, table<string, unknown>>
---@param context table<string, unknown>
local function collectNativeIds(items, context)
  local ids = {}
  for key, record in pairs(items) do
    local id = record.nativeId
    if id ~= nil then
      if ids[id] then
        fail("duplicate item native identity " .. tostring(id), context)
      end
      ids[id] = key
    end
  end
end

---@param pockets table<string, unknown>
---@param context table<string, unknown>
local function assertPockets(pockets, context)
  if type(pockets) ~= "table" then
    fail("pockets must be a record", context)
  end
  for key, definition in pairs(pockets) do
    local expected = ResolvedItemSchema.POCKETS[key]
    if expected == nil then
      fail("unknown pocket " .. tostring(key), context)
    end
    assert(expected ~= nil, "the pocket contract carries the validated entry")
    if type(definition) ~= "table" then
      fail("pocket " .. key .. " must be a record", context)
    end
    checkKeys(definition, { nativeId = true, capacity = true, maxQuantity = true, ordering = true }, context)
    if
      definition.nativeId ~= expected.nativeId
      or definition.capacity ~= expected.capacity
      or definition.maxQuantity ~= expected.maxQuantity
      or definition.ordering ~= expected.ordering
    then
      fail("pocket " .. key .. " does not match the source pocket contract", context)
    end
  end
  for key in pairs(ResolvedItemSchema.POCKETS) do
    if pockets[key] == nil then
      fail("pocket " .. key .. " is missing", context)
    end
  end
end

---@param pocketNames table<string, unknown>
---@param context table<string, unknown>
local function assertPocketNames(pocketNames, context)
  if type(pocketNames) ~= "table" then
    fail("pocketNames must be a record", context)
  end
  for key, name in pairs(pocketNames) do
    if ResolvedItemSchema.POCKETS[key] == nil then
      fail("unknown pocket name " .. tostring(key), context)
    end
    checkText(name, context, "pocket name " .. key)
  end
  for key in pairs(ResolvedItemSchema.POCKETS) do
    if pocketNames[key] == nil then
      fail("pocket name " .. key .. " is missing", context)
    end
  end
end

-- Full composed-catalog validation: shapes plus unique declared native
-- identities. Custom entries without a numeric identity validate like any
-- other entry; nothing is invented for them.
---@param catalog table<string, unknown>
---@return boolean true when the composed catalog is valid
function ResolvedItemSchema.assertCatalog(catalog)
  local context = {}
  if type(catalog) ~= "table" then
    fail("catalog must be a record", context)
  end
  checkKeys(catalog, {
    schema = true,
    version = true,
    items = true,
    pockets = true,
    pocketNames = true,
  }, context)
  if catalog.schema ~= "g4-item-catalog-v4" then
    fail("catalog schema must be g4-item-catalog-v4", context)
  end
  if type(catalog.version) ~= "table" then
    fail("catalog version must be a record", context)
  end
  checkKeys(catalog.version, { id = true, language = true }, context)
  checkText(catalog.version.id, context, "catalog version id")
  checkText(catalog.version.language, context, "catalog version language")
  if type(catalog.items) ~= "table" or Validate.isArray(catalog.items) then
    fail("items must be a keyed record", context)
  end
  for key, record in pairs(catalog.items) do
    assertItem(key, record, context)
  end
  collectNativeIds(catalog.items, context)
  assertPockets(catalog.pockets, context)
  assertPocketNames(catalog.pocketNames, context)
  return true
end

return ResolvedItemSchema
