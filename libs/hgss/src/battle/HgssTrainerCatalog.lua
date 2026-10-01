-- Immutable semantic trainer templates and selection programs. Templates
-- arrive as validated producer data: the trainer compiler projection of the
-- native trainer records (pret/pokeheartgold include/trainer_data.h with
-- the four TRTYPE party variants, the rival-name indirection of
-- src/trainer_data.c, and AI flags projected per bit). The catalog resolves
-- current runtime content keys, preserves record and program order, and
-- hands out detached copies so consumers can never mutate published
-- templates. Malformed records fail at this owner before anything reads
-- them; unknown trainer keys simply miss.

local Errors = require("libs.errors.src.Errors")

---@class HgssTrainerCatalog
---@field private _trainers table<unknown, table<string, unknown>>
---@field private _programs table<unknown, table<string, unknown>>
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
  return setmetatable({ _trainers = trainers, _programs = programs }, HgssTrainerCatalog)
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

return HgssTrainerCatalog
