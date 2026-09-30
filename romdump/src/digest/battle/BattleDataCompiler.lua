-- Normalization of native move-table entries into source-independent battle
-- facts. Move entries follow include/move.h MoveTbl widths
-- (pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981): effect u16,
-- category/power/type/accuracy/pp/effectChance u8, range u16, priority s8,
-- then source-only bytes the semantic projection never leaks. Semantic keys
-- reuse MonSources; behavior bindings come from the BattleSources inventory,
-- so a move without a binding is an attributed import failure, never a
-- generic fallback. No LOVE objects or filesystem writes; callers publish
-- through the battle-data cache paths.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")
local MonSources = require("romdump.src.config.MonSources")
local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")

---@class BattleDataCompiler
local BattleDataCompiler = {}

BattleDataCompiler.MOVE_ENTRY_SIZE = 16

local SUPPORTED_VERSIONS = { heartgold = true, soulsilver = true }

---@param indexed table<integer, string>
---@return table<string, boolean>
local function keySet(indexed)
  local set = {}
  for _, key in pairs(indexed) do
    set[key] = true
  end
  return set
end

local CATEGORY_KEYS = keySet(MonSources.damageCategories)
local TYPE_KEYS = keySet(MonSources.typeKeys)

---@generic T
---@param value T?
---@param err unknown?
---@return T
local function must(value, err)
  if value == nil then
    error(err, 0)
  end
  return value
end

---@param inventory table<string, unknown>|nil
---@return table<string, unknown>
local function inventoryFor(inventory)
  if inventory == nil then
    return require("romdump.src.config.BattleSources")
  end
  return inventory
end

---@param bindings table<string, unknown>|nil
---@param key string
---@param nativeId integer
---@return table<string, unknown>|nil
local function lookupBinding(bindings, key, nativeId)
  if type(bindings) ~= "table" then
    return nil
  end
  local binding = bindings[key]
  if binding == nil then
    binding = bindings[nativeId]
  end
  if type(binding) ~= "table" then
    return nil
  end
  return binding --[[@as table<string, unknown>]]
end

-- Project one decoded entry into its semantic facts. Identity numbers,
-- source units, and the lower-case type key survive exactly; execution
-- meaning travels as the inventory behavior reference plus a named target
-- and boolean flags derived from the entry values. Category and moveType
-- arrive as semantic keys; the range keeps its native identity in the
-- target name so no unverified targeting semantics are invented here.
---@param moveId integer
---@param moveKey string
---@param decoded table<string, unknown>
---@param binding table<string, unknown>
---@return table<string, unknown>
function BattleDataCompiler.projectFacts(moveId, moveKey, decoded, binding)
  local behaviorKey = assert(binding.key, "move binding carries no behavior key")
  assert(type(behaviorKey) == "string" and behaviorKey ~= "", "move binding carries no behavior key")
  local sourceParams = assert(binding.params, "move binding carries no behavior parameters")
  assert(type(sourceParams) == "table", "move binding parameters must be a record")
  -- Detached copy: staged payloads must never alias the live inventory.
  local params = {}
  for name, value in pairs(sourceParams) do
    params[name] = value
  end
  local category = assert(decoded.category, "move facts carry no category")
  assert(CATEGORY_KEYS[category] == true, "move facts carry an unknown category")
  local moveType = assert(decoded.moveType, "move facts carry no type")
  assert(TYPE_KEYS[moveType] == true, "move facts carry an unknown type")
  local power = assert(decoded.power, "move facts carry no power")
  local accuracy = assert(decoded.accuracy, "move facts carry no accuracy")
  local range = assert(decoded.range, "move facts carry no range")
  return {
    nativeId = moveId,
    name = moveKey,
    description = "",
    effect = decoded.effect,
    category = category,
    power = power,
    moveType = moveType,
    accuracy = accuracy,
    basePp = decoded.basePp,
    effectChance = decoded.effectChance,
    range = range,
    priority = decoded.priority,
    behavior = { key = behaviorKey, params = params },
    target = "range_" .. range,
    flags = {
      dealsDamage = power > 0,
      checksAccuracy = accuracy > 0,
    },
  }
end

-- Decode one 16-byte MoveTbl entry into normalized source values. Enum
-- identities stay numeric here; the compile step maps them to semantic keys
-- so one failed lookup names the offending move.
---@param moveId integer
---@param entry string
---@return table<string, integer>|nil, Errors.Error|nil
function BattleDataCompiler.decodeEntry(moveId, entry)
  if #entry ~= BattleDataCompiler.MOVE_ENTRY_SIZE then
    return nil,
      Errors.new(
        "BATTLE_MOVE_BAD_SIZE",
        "move " .. moveId .. " entry is " .. #entry .. " bytes, expected " .. BattleDataCompiler.MOVE_ENTRY_SIZE,
        { moveId = moveId, size = #entry, expected = BattleDataCompiler.MOVE_ENTRY_SIZE }
      )
  end
  local reader = BinaryReader.new(entry, "move " .. moveId)
  local moveType = reader:u8(4)
  if MonSources.typeKeys[moveType] == nil then
    return nil,
      Errors.new("BATTLE_MOVE_BAD_VALUE", "move " .. moveId .. " has an unknown type " .. moveType, {
        moveId = moveId,
        moveType = moveType,
      })
  end
  local category = reader:u8(2)
  if MonSources.damageCategories[category] == nil then
    return nil,
      Errors.new("BATTLE_MOVE_BAD_VALUE", "move " .. moveId .. " has an unknown category " .. category, {
        moveId = moveId,
        category = category,
      })
  end
  local priority = reader:u8(10)
  if priority >= 128 then
    priority = priority - 256
  end
  return {
    effect = reader:u16le(0),
    category = category,
    power = reader:u8(3),
    moveType = moveType,
    accuracy = reader:u8(5),
    basePp = reader:u8(6),
    effectChance = reader:u8(7),
    range = reader:u16le(8),
    priority = priority,
  }
end

-- Compile synthetic native input into semantic battle data. The input
-- carries one raw entry per move identity plus its supported game; the
-- inventory supplies the behavior bindings. Any malformed entry, unknown
-- reference, or unbound move fails before anything is published.
---@param nativeInput { versionId: string, moveEntries: table<integer, string> }
---@param opts { inventory: table<string, unknown>|nil }|nil
---@return table<string, unknown>|nil, Errors.Error|nil
function BattleDataCompiler.compile(nativeInput, opts)
  local inventory = inventoryFor(opts and opts.inventory)
  local versionId = nativeInput.versionId
  if SUPPORTED_VERSIONS[versionId] ~= true then
    return nil,
      Errors.new("BATTLE_VERSION_UNSUPPORTED", "battle data has no source contract for " .. tostring(versionId), {
        versionId = versionId,
      })
  end
  if type(nativeInput.moveEntries) ~= "table" then
    return nil, Errors.new("BATTLE_INPUT_INVALID", "battle data input carries no move entries", {})
  end
  local moves = {}
  local ok, result = pcall(function()
    for moveId, entry in pairs(nativeInput.moveEntries) do
      if type(moveId) ~= "number" or moveId % 1 ~= 0 then
        error(Errors.new("BATTLE_INPUT_INVALID", "move identities must be integers", { moveId = moveId }), 0)
      end
      local moveKey = MonSources.moveKeys[moveId]
      if moveKey == nil or moveId < 1 or moveId > MonSources.NUM_MOVES then
        error(
          Errors.new("BATTLE_MOVE_BAD_VALUE", "move " .. moveId .. " is not a usable native move", { moveId = moveId }),
          0
        )
      end
      if type(entry) ~= "string" then
        error(Errors.new("BATTLE_MOVE_BAD_SIZE", "move " .. moveId .. " entry is not bytes", { moveId = moveId }), 0)
      end
      local decoded = must(BattleDataCompiler.decodeEntry(moveId, entry))
      local binding = lookupBinding(inventory.moveBindings, moveKey, moveId)
      if binding == nil then
        error(
          Errors.new("BATTLE_MOVE_UNBOUND", "move " .. moveKey .. " has no behavior binding", { move = moveKey }),
          0
        )
      end
      moves[moveKey] = BattleDataCompiler.projectFacts(moveId, moveKey, {
        effect = decoded.effect,
        category = MonSources.damageCategories[decoded.category],
        power = decoded.power,
        moveType = MonSources.typeKeys[decoded.moveType],
        accuracy = decoded.accuracy,
        basePp = decoded.basePp,
        effectChance = decoded.effectChance,
        range = decoded.range,
        priority = decoded.priority,
      }, binding)
    end
    local compiled = {
      schema = BattleDataCache.BATTLE_DATA_SCHEMA,
      version = { id = versionId },
      moves = moves,
    }
    must(BattleDataSchema.assertBattleData(compiled))
    return compiled
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

-- Total inventory coverage: every usable native move, ability, held-item
-- effect, and encounter-dispatch command family has exactly one semantic
-- binding. Success returns true; any gap raises naming the absent identity.
-- Sentinels (NONE/Egg/Bad Egg) are not usable bindings and stay uncovered.
---@param inventory table<string, unknown>|nil
---@return boolean
function BattleDataCompiler.validateCoverage(inventory)
  local resolved = inventoryFor(inventory)
  local moveBindings = assert(resolved.moveBindings, "coverage requires the move bindings")
  for moveId = 1, MonSources.NUM_MOVES do
    local moveKey = assert(MonSources.moveKeys[moveId])
    if lookupBinding(moveBindings, moveKey, moveId) == nil then
      Errors.raise("BATTLE_COVERAGE_GAP", "native move " .. moveKey .. " has no behavior binding", {
        family = "moveBindings",
        identity = moveKey,
      })
    end
  end
  local abilityBindings = assert(resolved.abilityBindings, "coverage requires the ability bindings")
  for abilityId = 1, MonSources.NUM_ABILITIES do
    local abilityKey = assert(MonSources.abilityKeys[abilityId])
    if lookupBinding(abilityBindings, abilityKey, abilityId) == nil then
      Errors.raise("BATTLE_COVERAGE_GAP", "native ability " .. abilityKey .. " has no behavior binding", {
        family = "abilityBindings",
        identity = abilityKey,
      })
    end
  end
  local ItemSources = require("romdump.src.config.ItemSources")
  local heldItemBindings = assert(resolved.heldItemBindings, "coverage requires the held-item bindings")
  for nativeId = 0, 536 do
    local itemKey = assert(ItemSources.itemKeys[nativeId])
    if lookupBinding(heldItemBindings, itemKey, nativeId) == nil then
      Errors.raise("BATTLE_COVERAGE_GAP", "native item " .. itemKey .. " has no held behavior binding", {
        family = "heldItemBindings",
        identity = itemKey,
      })
    end
  end
  local commandBindings = assert(resolved.commandBindings, "coverage requires the command bindings")
  for _, family in ipairs({ "land", "surfing", "fishing", "rock_smash", "headbutt", "safari", "bug_contest" }) do
    local binding = commandBindings[family]
    if type(binding) ~= "table" or type(binding.key) ~= "string" or binding.key == "" then
      Errors.raise("BATTLE_COVERAGE_GAP", "encounter family " .. family .. " has no command binding", {
        family = "commandBindings",
        identity = family,
      })
    end
  end
  return true
end

-- Compile battle data from a supported dump. Common mon reads delegate to
-- the mon catalog compiler, so names, descriptions, and numeric facts stay
-- single-sourced; this step adds only the inventory behavior projection.
---@param romFs RomFs
---@param opts { versionId: string|nil, inventory: table<string, unknown>|nil }|nil
---@return table<string, unknown>|nil, Errors.Error|string|nil
function BattleDataCompiler.compileFromDump(romFs, opts)
  opts = opts or {}
  local versionId = opts.versionId or romFs:version()
  if SUPPORTED_VERSIONS[versionId] ~= true then
    return nil,
      Errors.new("BATTLE_VERSION_UNSUPPORTED", "battle data has no source contract for " .. tostring(versionId), {
        versionId = versionId,
      })
  end
  local inventory = inventoryFor(opts.inventory)
  local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
  local catalog, catalogErr = MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId })
  if catalog == nil then
    return nil, catalogErr
  end
  local moves = {}
  local ok, result = pcall(function()
    for moveKey, record in pairs(catalog.moves) do
      local moveId = record.nativeId
      if moveId ~= 0 then
        local binding = lookupBinding(inventory.moveBindings, moveKey, moveId)
        if binding == nil then
          error(
            Errors.new("BATTLE_MOVE_UNBOUND", "move " .. moveKey .. " has no behavior binding", { move = moveKey }),
            0
          )
        end
        local decoded = {
          effect = record.effect,
          category = record.category,
          power = record.power,
          moveType = record.moveType,
          accuracy = record.accuracy,
          basePp = record.basePp,
          effectChance = record.effectChance,
          range = record.range,
          priority = record.priority,
        }
        local facts = BattleDataCompiler.projectFacts(moveId, moveKey, decoded, binding)
        facts.name = record.name
        facts.description = record.description
        moves[moveKey] = facts
      end
    end
    local compiled = {
      schema = BattleDataCache.BATTLE_DATA_SCHEMA,
      version = { id = versionId },
      moves = moves,
    }
    must(BattleDataSchema.assertBattleData(compiled))
    return compiled
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

return BattleDataCompiler
