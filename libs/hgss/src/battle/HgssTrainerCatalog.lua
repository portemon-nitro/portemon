-- Immutable semantic trainer templates and selection programs. Templates
-- arrive as validated producer data: the trainer compiler projection of the
-- native trainer records (the four TRTYPE party variants, the
-- rival-name indirection, and AI flags projected per bit). The catalog resolves
-- current runtime content keys, preserves record and program order, and
-- hands out detached copies so consumers can never mutate published
-- templates. Malformed records fail at this owner before anything reads
-- them; unknown trainer keys simply miss.

local Errors = require("libs.errors.src.Errors")

---@class HgssTrainerCatalog
---@field private _trainers table<unknown, table<string, unknown>>
---@field private _programs table<unknown, table<string, unknown>>
---@field private _movementByType table<string, integer>
---@field private _movementTypeBySelector table<integer, string>
---@field private _fieldMessageBank integer
local HgssTrainerCatalog = {}
HgssTrainerCatalog.__index = HgssTrainerCatalog

---@param value unknown
---@return unknown detached copy that cannot reach live state
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local input = value --[[@as table<unknown, unknown>]]
  local out = {}
  for key, item in pairs(input) do
    out[key] = copyValue(item)
  end
  return out
end

---@param key unknown
---@param what string
local function assertKey(key, what)
  if type(key) == "string" then
    assert(key ~= "", what .. " keys are never empty")
  else
    assert(type(key) == "number" and key % 1 == 0, what .. " keys are strings or integers")
  end
end

---@param record unknown
---@param key unknown
local function assertTrainerRecord(record, key)
  assert(type(record) == "table", "trainer templates are records")
  local template = record --[[@as table<string, unknown>]]
  assert(template.trainerClass ~= nil, "trainer " .. tostring(key) .. " names its trainer class")
  assert(type(template.nameReference) == "table", "trainer " .. tostring(key) .. " carries its name reference")
  assert(type(template.party) == "table", "trainer " .. tostring(key) .. " carries its ordered party")
  local party = template.party --[[@as table<integer, unknown>]]
  for index, member in ipairs(party) do
    assert(type(member) == "table", "trainer " .. tostring(key) .. " member " .. index .. " is a record")
    local entry = member --[[@as table<string, unknown>]]
    assert(
      type(entry.species) == "string" and entry.species ~= "",
      "trainer " .. tostring(key) .. " member " .. index .. " names its species"
    )
    assert(
      type(entry.level) == "number" and entry.level % 1 == 0 and entry.level >= 1,
      "trainer " .. tostring(key) .. " member " .. index .. " carries a positive level"
    )
  end
end

---@param compiled table<string, unknown> validated producer data carrying trainers and optional programs
---@return HgssTrainerCatalog
function HgssTrainerCatalog.new(compiled)
  assert(type(compiled) == "table", "trainer templates load from validated producer data")
  if type(compiled.trainers) ~= "table" then
    Errors.raise("TRAINER_CATALOG_INVALID", "trainer catalogs carry their trainer records", {})
  end
  if compiled.programs ~= nil and type(compiled.programs) ~= "table" then
    Errors.raise("TRAINER_CATALOG_INVALID", "trainer programs arrive as a record when present", {})
  end
  local trainers = {}
  for key, record in pairs(compiled.trainers) do
    assertKey(key, "trainer")
    assertTrainerRecord(record, key)
    trainers[key] = copyValue(record)
  end
  local programs = {}
  for key, program in pairs(compiled.programs or {}) do
    assertKey(key, "program")
    assert(type(program) == "table", "selection programs are records")
    programs[key] = copyValue(program)
  end
  -- The producer's closed inverse of its source movement selectors is part of
  -- the generated catalog, not an optional extra: a trainer script comparing a
  -- live actor's movement reads it.
  local movementByType = compiled.nativeMovementByType
  if type(movementByType) ~= "table" then
    Errors.raise("TRAINER_CATALOG_INVALID", "trainer catalogs carry the native movement inverse", {})
  end
  local movements = {}
  local movementTypes = {}
  for semanticType, rawMovement in pairs(movementByType) do
    assert(type(semanticType) == "string" and semanticType ~= "", "movement profiles are named")
    assert(
      type(rawMovement) == "number" and rawMovement % 1 == 0 and rawMovement >= 0 and rawMovement <= 56,
      "native movement selectors stay in the source's 0..56 range"
    )
    assert(movementTypes[rawMovement] == nil, "every native movement selector names one profile")
    movements[semanticType] = rawMovement
    movementTypes[rawMovement] = semanticType
  end
  local bank = compiled.fieldMessageBank
  if type(bank) ~= "number" or bank % 1 ~= 0 or bank < 0 then
    Errors.raise("TRAINER_CATALOG_INVALID", "trainer catalogs name their field message bank", {})
  end
  return setmetatable({
    _trainers = trainers,
    _programs = programs,
    _movementByType = movements,
    _movementTypeBySelector = movementTypes,
    _fieldMessageBank = bank,
  }, HgssTrainerCatalog)
end

---@param catalog HgssTrainerCatalog
---@param key string|integer
---@return table<string, unknown>|nil detached trainer template, nil when unknown
function HgssTrainerCatalog.trainer(catalog, key)
  assert(catalog ~= nil and type(catalog._trainers) == "table", "trainer reads run on catalogs")
  local template = catalog._trainers[key]
  if template == nil then
    return nil
  end
  return copyValue(template) --[[@as table<string, unknown>]]
end

---@param catalog HgssTrainerCatalog
---@param key string|integer
---@return table<string, unknown>|nil detached selection program, nil when unknown
function HgssTrainerCatalog.program(catalog, key)
  assert(catalog ~= nil and type(catalog._programs) == "table", "program reads run on catalogs")
  local program = catalog._programs[key]
  if program == nil then
    return nil
  end
  return copyValue(program) --[[@as table<string, unknown>]]
end

-- Whether the trainer's own source record marks it as a double-battle trainer
-- (TRATTR_DOUBLEBTL). An unknown trainer is no double trainer.
---@param catalog HgssTrainerCatalog
---@param key string|integer
---@return boolean
function HgssTrainerCatalog.isDouble(catalog, key)
  assert(catalog ~= nil and type(catalog._trainers) == "table", "double reads run on catalogs")
  local template = catalog._trainers[key]
  return type(template) == "table" and template.doubleBattle == true
end

-- The trainer's eyes-meet sequence for one native region, or nil when the
-- generated record carries none for it.
---@param catalog HgssTrainerCatalog
---@param key string|integer
---@param region string
---@return string? canonical audio sequence reference
function HgssTrainerCatalog.encounterMusic(catalog, key, region)
  assert(catalog ~= nil and type(catalog._trainers) == "table", "music reads run on catalogs")
  assert(type(region) == "string" and region ~= "", "encounter music names its native region")
  local template = catalog._trainers[key]
  if type(template) ~= "table" or type(template.encounterMusic) ~= "table" then
    return nil
  end
  local sequence = (template.encounterMusic --[[@as table<string, unknown>]])[region]
  return type(sequence) == "string" and sequence ~= "" and sequence or nil
end

-- The source field message one trainer/message-kind pair selects, as a message
-- location inside the catalog's own trainer message bank, or nil when the
-- source carries no such pair.
---@param catalog HgssTrainerCatalog
---@param key string|integer
---@param kind integer source TRMSG_* kind
---@return { bank: integer, id: integer }? message location
function HgssTrainerCatalog.fieldMessage(catalog, key, kind)
  assert(catalog ~= nil and type(catalog._trainers) == "table", "field message reads run on catalogs")
  local template = catalog._trainers[key]
  if type(template) ~= "table" or type(template.fieldMessages) ~= "table" then
    return nil
  end
  local index = (template.fieldMessages --[[@as table<integer, unknown>]])[kind]
  if type(index) ~= "number" or index % 1 ~= 0 then
    return nil
  end
  return { bank = catalog._fieldMessageBank, id = index }
end

-- The native movement selector a semantic movement profile names, or nil for
-- a profile the source table does not carry.
---@param catalog HgssTrainerCatalog
---@param semanticType string
---@return integer?
function HgssTrainerCatalog.nativeMovement(catalog, semanticType)
  assert(catalog ~= nil and type(catalog._movementByType) == "table", "movement reads run on catalogs")
  return catalog._movementByType[semanticType]
end

-- The semantic movement profile one native selector names, or nil for a
-- selector the source table does not carry.
---@param catalog HgssTrainerCatalog
---@param selector integer
---@return string?
function HgssTrainerCatalog.movementType(catalog, selector)
  assert(catalog ~= nil and type(catalog._movementByType) == "table", "movement reads run on catalogs")
  local bySelector = catalog._movementTypeBySelector
  return bySelector[selector]
end

return HgssTrainerCatalog
