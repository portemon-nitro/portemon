-- Stable roaming mon state and lifecycle. Roamers carry semantic identities:
-- encounter construction borrows the stored mon identity, hit points, and
-- status instead of regenerating them, while flee, capture, and defeat
-- commit through revision-checked deltas so stale outcomes never overwrite
-- newer state. Caught and defeated roamers never re-encounter. This owner
-- also carries the neutral encounter counters persisted alongside the
-- roamer records. Pure domain module: no love dependency.

local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")

---@class HgssRoamerState
---@field private _records table<string, unknown>[] ordered roamer records by insertion
---@field private _index table<string, integer> roamer key to record position
---@field private _species table<string, boolean> selected species reference set
---@field private _maps table<integer, boolean> selected map reference set
---@field private _steps integer
---@field private _repelSteps integer
---@field private _swarm boolean
---@field private _radio string
local HgssRoamerState = {}
HgssRoamerState.__index = HgssRoamerState

local LIFECYCLES = {
  inactive = true,
  roaming = true,
  caught = true,
  defeated = true,
}

---@param value unknown
---@return unknown
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

---@param refs unknown
---@param what string
---@return { species: table<string, boolean>, maps: table<integer, boolean> }
local function checkRefs(refs, what)
  if type(refs) ~= "table" or type(refs.species) ~= "table" or type(refs.maps) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", what .. " requires species and map reference sets", {})
  end
  assert(type(refs) == "table", "roamer state reads its reference sets")
  return refs
end

---@param record unknown
---@param refs { species: table<string, boolean>, maps: table<integer, boolean> }
---@return table<string, unknown>
local function checkRecord(record, refs)
  if type(record) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer records must be tables", {})
  end
  assert(type(record) == "table", "roamer state reads its records")
  if type(record.key) ~= "string" or record.key == "" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer records carry a non-empty key", {})
  end
  if record.stateVersion ~= EncounterSave.STATE_VERSION then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer " .. record.key .. " carries an incompatible state version", {
      roamer = record.key,
      stateVersion = record.stateVersion,
    })
  end
  local mon = record.mon
  if type(mon) ~= "table" or type(mon.species) ~= "string" or refs.species[mon.species] ~= true then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer " .. record.key .. " names an unknown species", {
      roamer = record.key,
      species = type(mon) == "table" and mon.species or mon,
    })
  end
  if refs.maps[record.location] ~= true then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer " .. record.key .. " names an unknown location", {
      roamer = record.key,
      location = record.location,
    })
  end
  if type(record.lifecycle) ~= "string" or LIFECYCLES[record.lifecycle] ~= true then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer " .. record.key .. " carries an unknown lifecycle", {
      roamer = record.key,
      lifecycle = record.lifecycle,
    })
  end
  if type(record.revision) ~= "number" or record.revision % 1 ~= 0 or record.revision < 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer " .. record.key .. " carries an invalid revision", {
      roamer = record.key,
      revision = record.revision,
    })
  end
  return record
end

---@param args { records: table<string, unknown>[], species: table<string, boolean>, maps: table<integer, boolean>, steps?: integer, repelSteps?: integer, swarm?: boolean, radio?: string }
---@return HgssRoamerState
function HgssRoamerState.new(args)
  if type(args) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer state requires an argument record", {})
  end
  assert(type(args) == "table", "roamer state reads its construction record")
  local refs = checkRefs({ species = args.species, maps = args.maps }, "roamer state")
  if not Validate.isArray(args.records) then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer records must be an array", {})
  end
  assert(type(args.records) == "table", "roamer state reads its records")
  local records = {}
  local index = {}
  for _, record in ipairs(args.records) do
    local valid = checkRecord(record, refs)
    if index[valid.key] ~= nil then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer " .. valid.key .. " is registered twice", {
        roamer = valid.key,
      })
    end
    assert(type(valid.key) == "string", "roamer records carry their keys")
    index[valid.key] = #records + 1
    records[#records + 1] = copyValue(valid)
  end
  local steps = args.steps or 0
  if type(steps) ~= "number" or steps % 1 ~= 0 or steps < 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer step counters must be non-negative integers", {})
  end
  local repelSteps = args.repelSteps or 0
  if type(repelSteps) ~= "number" or repelSteps % 1 ~= 0 or repelSteps < 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer step counters must be non-negative integers", {})
  end
  local swarm = args.swarm or false
  if type(swarm) ~= "boolean" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer swarm state must be a boolean", {})
  end
  local radio = args.radio or "none"
  if type(radio) ~= "string" or radio == "" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer radio state must be a non-empty string", {})
  end
  return setmetatable({
    _records = records,
    _index = index,
    _species = refs.species,
    _maps = refs.maps,
    _steps = steps,
    _repelSteps = repelSteps,
    _swarm = swarm,
    _radio = radio,
  }, HgssRoamerState)
end

-- Restores roamer state from a persisted bucket, validating selected
-- references through the save owner.
---@param bucket table<string, unknown>
---@param refs { species: table<string, boolean>, maps: table<integer, boolean> }
---@return HgssRoamerState
function HgssRoamerState.restore(bucket, refs)
  local valid = EncounterSave.validate(bucket, refs)
  assert(type(valid) == "table", "restoration reads the validated bucket")
  local records = {}
  assert(type(valid.roamers) == "table", "the validated bucket carries its roamer map")
  for _, record in pairs(valid.roamers) do
    records[#records + 1] = record
  end
  table.sort(records, function(a, b)
    assert(type(a) == "table" and type(b) == "table", "the bucket carries roamer records")
    return a.key < b.key
  end)
  return HgssRoamerState.new({
    records = records,
    species = refs.species,
    maps = refs.maps,
    steps = valid.steps,
    repelSteps = valid.repelSteps,
    swarm = valid.swarm,
    radio = valid.radio,
  })
end

---@param key unknown
---@return table<string, unknown>
function HgssRoamerState:_recordOrRaise(key)
  local position = type(key) == "string" and self._index[key] or nil
  local record = position ~= nil and self._records[position] or nil
  if type(record) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "no roamer " .. tostring(key), { roamer = key })
  end
  assert(type(record) == "table", "the roamer index carries its records")
  return record
end

-- Borrows the stored identity for encounter construction: no new random
-- state, hit points, or status is generated here.
---@param key string
---@return table<string, unknown>
function HgssRoamerState:prepareEncounter(key)
  local record = self:_recordOrRaise(key)
  if record.lifecycle ~= "roaming" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer " .. tostring(key) .. " is not roaming", { roamer = key })
  end
  return copyValue(record)
end

---@param record table<string, unknown>
---@param details table<string, unknown>
local function applyBattleResult(record, details)
  local mon = record.mon
  assert(type(mon) == "table", "battle results commit through the stored mon")
  if details.hp ~= nil then
    if type(details.hp) ~= "number" or details.hp % 1 ~= 0 or details.hp < 0 then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer battle health must be a non-negative integer", {
        roamer = record.key,
        hp = details.hp,
      })
    end
    local condition = mon.condition
    if type(condition) ~= "table" then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer " .. tostring(record.key) .. " carries no battle condition", {
        roamer = record.key,
      })
    end
    assert(type(condition) == "table", "battle health commits through the stored condition")
    condition.currentHp = details.hp
  end
  if details.effects ~= nil then
    if not Validate.isArray(details.effects) then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer battle effects must be an array", { roamer = record.key })
    end
    local condition = mon.condition
    if type(condition) ~= "table" then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer " .. tostring(record.key) .. " carries no battle condition", {
        roamer = record.key,
      })
    end
    assert(type(condition) == "table", "battle effects commit through the stored condition")
    condition.effects = copyValue(details.effects)
  end
end

-- Commits a battle outcome through a revision-checked delta: flee updates
-- the location with the current battle health, capture and defeat close the
-- lifecycle. Stale revisions and terminal records never mutate.
---@param key string
---@param outcome string
---@param expectedRevision integer
---@param details table<string, unknown>
---@return table<string, unknown>
function HgssRoamerState:prepareResult(key, outcome, expectedRevision, details)
  local record = self:_recordOrRaise(key)
  if outcome ~= "fled" and outcome ~= "captured" and outcome ~= "defeated" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "unknown roamer outcome " .. tostring(outcome), {
      roamer = key,
      outcome = outcome,
    })
  end
  if type(expectedRevision) ~= "number" or record.revision ~= expectedRevision then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "stale roamer outcome for " .. tostring(key), {
      roamer = key,
      revision = expectedRevision,
    })
  end
  if record.lifecycle ~= "roaming" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer " .. tostring(key) .. " is not roaming", { roamer = key })
  end
  if type(details) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer outcomes require a details record", { roamer = key })
  end
  assert(type(details) == "table", "outcomes read their details record")
  if outcome == "fled" then
    local location = details.location
    if self._maps[location] ~= true then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer " .. tostring(key) .. " names an unknown location", {
        roamer = key,
        location = location,
      })
    end
    record.location = location
    applyBattleResult(record, details)
  elseif outcome == "captured" then
    record.lifecycle = "caught"
  else
    record.lifecycle = "defeated"
    applyBattleResult(record, details)
  end
  assert(type(record.revision) == "number", "outcomes advance the stored revision")
  record.revision = record.revision + 1
  return copyValue(record)
end

-- Captures the persistable encounter state: authoritative counters plus the
-- detached roamer records. Tables never persist.
---@return { steps: integer, repelSteps: integer, swarm: boolean, radio: string, roamers: table<string, table<string, unknown>> }
function HgssRoamerState:capture()
  local roamers = {}
  for _, record in ipairs(self._records) do
    assert(type(record) == "table" and type(record.key) == "string", "capture reads stored records")
    roamers[record.key] = copyValue(record)
  end
  return {
    steps = self._steps,
    repelSteps = self._repelSteps,
    swarm = self._swarm,
    radio = self._radio,
    roamers = roamers,
  }
end

return HgssRoamerState
