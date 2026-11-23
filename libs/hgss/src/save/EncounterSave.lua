-- Semantic encounter persistence: the versioned encounter bucket carrying
-- authoritative counters, the swarm context, the player's route history,
-- and the roamer records. Validation is strict and reference-based:
-- malformed buckets and missing selected species, maps, roamer slots or
-- roamer routes fail with the exact reference, while unrelated catalog
-- growth stays compatible and whole encounter tables never persist. The
-- current bucket also carries the source roamer metadata: a native slot and
-- its route index per record, and the two-entry player location history the
-- source roamer movement reads. A stored radio string is obsolete legacy: it
-- migrates to silence and new captures omit it, so playback authority can
-- never resume from a save. A bucket written before the native roamer
-- metadata migrates forward without drawing a random value and without
-- inventing a slot, a route, or a location for a player-authored roamer. A
-- missing bucket restores to the defined source initial state. Pure domain
-- module: no love dependency.

local Errors = require("libs.errors.src.Errors")

---@class EncounterSave
local EncounterSave = {}

EncounterSave.SCHEMA = "hgss-encounter-v2"
EncounterSave.STATE_VERSION = 2
EncounterSave.LEGACY_V1_SCHEMA = "hgss-encounter-v1"

local LIFECYCLES = {
  inactive = true,
  roaming = true,
  caught = true,
  defeated = true,
}

---@param message string
---@param context table<string, unknown>?
local function fail(message, context)
  Errors.raise("ENCOUNTER_SAVE_INVALID", message, context or {})
end

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

-- The source keeps a two-entry map history; the back entry is the map the
-- player left, which roamer movement excludes. An absent entry reads as no
-- known route.
---@return table<string, unknown>
local function emptyPlayerRoutes()
  return { current = false, previous = false }
end

---@return table<string, unknown> the defined source initial state
function EncounterSave.initial()
  return {
    schema = EncounterSave.SCHEMA,
    stateVersion = EncounterSave.STATE_VERSION,
    steps = 0,
    repelSteps = 0,
    swarm = false,
    radio = "none",
    playerRoutes = emptyPlayerRoutes(),
    roamers = {},
  }
end

---@param value unknown
---@param what string
local function checkCounter(value, what)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    fail("encounter " .. what .. " must be a non-negative integer", {})
  end
end

---@param value unknown
---@param what string
local function checkRouteHistoryEntry(value, what)
  if value == false then
    return
  end
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    fail("encounter player route " .. what .. " must be false or a map identity", { route = what })
  end
end

---@param routes unknown
local function checkPlayerRoutes(routes)
  if type(routes) ~= "table" then
    fail("encounter player routes must be a record", {})
  end
  assert(type(routes) == "table", "shape validation reads the player route history")
  for key in pairs(routes) do
    if key ~= "current" and key ~= "previous" then
      fail("encounter player routes carry only current and previous", { field = tostring(key) })
    end
  end
  if routes.current == nil or routes.previous == nil then
    fail("encounter player routes name both entries", {})
  end
  checkRouteHistoryEntry(routes.current, "current")
  checkRouteHistoryEntry(routes.previous, "previous")
end

-- A native roamer's persisted metadata: its source slot and its index into
-- the source's eligible route list. Any other shape is malformed; absent
-- metadata stays absent so player-authored roamers keep working.
---@param native unknown
---@param key string
local function checkNative(native, key)
  if native == nil then
    return
  end
  if type(native) ~= "table" then
    fail("encounter roamer " .. key .. " native metadata must be a record", { roamer = key })
  end
  assert(type(native) == "table", "shape validation reads native metadata")
  for field in pairs(native) do
    if field ~= "slot" and field ~= "routeIndex" then
      fail("encounter roamer " .. key .. " native metadata carries an unknown field", {
        roamer = key,
        field = tostring(field),
      })
    end
  end
  if type(native.slot) ~= "number" or native.slot % 1 ~= 0 or native.slot < 0 then
    fail("encounter roamer " .. key .. " native slot must be a source slot index", { roamer = key })
  end
  if type(native.routeIndex) ~= "number" or native.routeIndex % 1 ~= 0 or native.routeIndex < 0 then
    fail("encounter roamer " .. key .. " native route must be a source route index", { roamer = key })
  end
end

---@param record unknown
---@param key string
local function checkRoamerRecord(record, key)
  if type(record) ~= "table" then
    fail("encounter roamer " .. key .. " must be a record", { roamer = key })
  end
  assert(type(record) == "table", "shape validation reads roamer records")
  if record.key ~= key then
    fail("encounter roamer key must match its record", { roamer = key })
  end
  if record.stateVersion ~= EncounterSave.STATE_VERSION then
    fail("encounter roamer " .. key .. " carries an incompatible state version", {
      roamer = key,
      stateVersion = record.stateVersion,
    })
  end
  if type(record.mon) ~= "table" or type(record.mon.species) ~= "string" then
    fail("encounter roamer " .. key .. " carries no species", { roamer = key })
  end
  if type(record.lifecycle) ~= "string" or LIFECYCLES[record.lifecycle] ~= true then
    fail("encounter roamer " .. key .. " carries an unknown lifecycle", {
      roamer = key,
      lifecycle = record.lifecycle,
    })
  end
  if type(record.revision) ~= "number" or record.revision % 1 ~= 0 or record.revision < 0 then
    fail("encounter roamer " .. key .. " carries an invalid revision", {
      roamer = key,
      revision = record.revision,
    })
  end
  checkNative(record.native, key)
end

---@param bucket unknown
---@return table<string, unknown> canonical detached shape without reference checks
local function checkShape(bucket)
  if type(bucket) ~= "table" then
    fail("encounter bucket must be a table", {})
  end
  assert(type(bucket) == "table", "shape validation reads the bucket record")
  if bucket.schema ~= EncounterSave.SCHEMA then
    fail("encounter schema must be " .. EncounterSave.SCHEMA, { schema = bucket.schema })
  end
  if bucket.stateVersion ~= EncounterSave.STATE_VERSION then
    fail("encounter state version must be " .. EncounterSave.STATE_VERSION, { stateVersion = bucket.stateVersion })
  end
  checkCounter(bucket.steps, "step counter")
  checkCounter(bucket.repelSteps, "repel counter")
  if type(bucket.swarm) ~= "boolean" then
    fail("encounter swarm state must be a boolean", {})
  end
  -- The radio key is obsolete: legacy buckets may still carry a music
  -- string, but only a string ever validates. New captures omit the key.
  if bucket.radio ~= nil and (type(bucket.radio) ~= "string" or bucket.radio == "") then
    fail("encounter radio state must be a non-empty string", {})
  end
  checkPlayerRoutes(bucket.playerRoutes)
  if type(bucket.roamers) ~= "table" then
    fail("encounter roamers must be a record", {})
  end
  assert(type(bucket.roamers) == "table", "shape validation reads the roamer map")
  for key, record in pairs(bucket.roamers) do
    if type(key) ~= "string" or key == "" then
      fail("encounter roamer keys must be non-empty strings", { roamer = key })
    end
    checkRoamerRecord(record, key)
  end
  return copyValue(bucket)
end

-- The predecessor bucket shape: the same counters and context without the
-- player route history, and records at the earlier state version. Only that
-- exact shape migrates; anything else is malformed, never repaired.
---@param bucket unknown
---@return table<string, unknown> canonical detached predecessor shape
local function checkLegacyShape(bucket)
  if type(bucket) ~= "table" then
    fail("encounter bucket must be a table", {})
  end
  assert(type(bucket) == "table", "legacy shape validation reads the bucket record")
  if bucket.schema ~= EncounterSave.LEGACY_V1_SCHEMA then
    fail("encounter legacy schema must be " .. EncounterSave.LEGACY_V1_SCHEMA, { schema = bucket.schema })
  end
  if bucket.playerRoutes ~= nil then
    fail("encounter legacy bucket cannot carry the player route history", {})
  end
  local roamers = bucket.roamers
  if type(roamers) ~= "table" then
    fail("encounter roamers must be a record", {})
  end
  assert(type(roamers) == "table", "legacy shape validation reads the roamer map")
  for key, record in pairs(roamers) do
    if type(key) ~= "string" or key == "" then
      fail("encounter roamer keys must be non-empty strings", { roamer = key })
    end
    if type(record) ~= "table" then
      fail("encounter roamer " .. key .. " must be a record", { roamer = key })
    end
    assert(type(record) == "table", "legacy shape validation reads roamer records")
    if record.native ~= nil then
      fail("encounter legacy roamer " .. key .. " cannot carry native metadata", { roamer = key })
    end
  end
  return copyValue(bucket)
end

-- Pure predecessor migration: the counters, context, roamer keys and every
-- stored record field are preserved exactly, the records move to the current
-- state version, and the player's route history starts empty because the
-- predecessor tracked none. No random value is drawn and no native slot,
-- route, or location is inferred from a species.
---@param bucket table<string, unknown> a legacy bucket
---@return table<string, unknown> the migrated bucket
function EncounterSave.migrateV1(bucket)
  local legacy = checkLegacyShape(bucket)
  local roamers = {}
  for key, record in
    pairs(legacy.roamers --[[@as table<string, table<string, unknown>>]])
  do
    local migrated = {}
    for field, value in pairs(record) do
      migrated[field] = value
    end
    migrated.stateVersion = EncounterSave.STATE_VERSION
    roamers[key] = migrated
  end
  local migrated = {
    schema = EncounterSave.SCHEMA,
    stateVersion = EncounterSave.STATE_VERSION,
    steps = legacy.steps,
    repelSteps = legacy.repelSteps,
    swarm = legacy.swarm,
    playerRoutes = emptyPlayerRoutes(),
    roamers = roamers,
  }
  if legacy.radio ~= nil then
    migrated.radio = legacy.radio
  end
  return migrated
end

---@param bucket table<string, unknown>
---@param refs unknown
local function checkReferences(bucket, refs)
  if type(refs) ~= "table" or type(refs.species) ~= "table" or type(refs.maps) ~= "table" then
    fail("encounter validation requires species and map reference sets", {})
  end
  assert(type(refs) == "table", "reference validation reads the reference sets")
  local roamers = bucket.roamers
  assert(type(roamers) == "table", "reference validation reads the roamer map")
  for key, record in pairs(roamers) do
    assert(type(record) == "table" and type(key) == "string", "reference validation reads roamer records")
    local mon = record.mon
    assert(type(mon) == "table", "reference validation reads roamer mons")
    if refs.species[mon.species] ~= true then
      fail("encounter roamer " .. key .. " names a missing species", { roamer = key, species = mon.species })
    end
    if refs.maps[record.location] ~= true then
      fail("encounter roamer " .. key .. " names a missing location", { roamer = key, location = record.location })
    end
    local native = record.native
    if type(native) == "table" then
      local routes = refs.roamerRoutes
      if type(routes) ~= "table" then
        fail("encounter validation of native roamers requires the source route table", { roamer = key })
      end
      local routeMap = routes[
        (native --[[@as table<string, unknown>]]).routeIndex + 1
      ]
      if type(routeMap) ~= "number" then
        fail("encounter roamer " .. key .. " names a missing source route", {
          roamer = key,
          routeIndex = native.routeIndex,
        })
      end
      if record.location ~= routeMap then
        fail("encounter roamer " .. key .. " location disagrees with its source route", {
          roamer = key,
          location = record.location,
          routeIndex = native.routeIndex,
        })
      end
    end
  end
  local routes = bucket.playerRoutes
  assert(type(routes) == "table", "reference validation reads the player route history")
  for _, field in ipairs({ "current", "previous" }) do
    local value = routes[field]
    if value ~= false and refs.maps[value] ~= true then
      fail("encounter player route " .. field .. " names a missing map", { route = field, map = value })
    end
  end
end

-- Validates a bucket against the selected references, returning its
-- canonical detached record. A predecessor bucket migrates first. Unrelated
-- reference growth stays compatible; missing selected references fail naming
-- the reference. Legacy radio strings migrate to silence here: the obsolete
-- value carries no playback authority past this boundary.
---@param bucket unknown
---@param refs { species: table<string, boolean>, maps: table<integer, boolean>, roamerRoutes?: table<integer, integer> }
---@return table<string, unknown>
function EncounterSave.validate(bucket, refs)
  if
    type(bucket) == "table" and (bucket --[[@as table<string, unknown>]]).schema == EncounterSave.LEGACY_V1_SCHEMA
  then
    bucket = EncounterSave.migrateV1(bucket)
  end
  local shaped = checkShape(bucket)
  checkReferences(shaped, refs)
  shaped.radio = "none"
  return shaped
end

-- Captures a bucket from a state owner exposing the persistable encounter
-- fields. Only authoritative counters, context, the player route history and
-- roamer records persist; the obsolete radio key is never written.
---@param state table<string, unknown>
---@return table<string, unknown>
function EncounterSave.capture(state)
  if type(state) ~= "table" or type(state.capture) ~= "function" then
    fail("encounter capture needs a roamer state", {})
  end
  assert(type(state) == "table", "capture reads the state owner")
  local captureFn = state.capture
  assert(type(captureFn) == "function", "capture reads the state owner")
  local capture = captureFn(state)
  if type(capture) ~= "table" then
    fail("encounter capture carries no state", {})
  end
  assert(type(capture) == "table", "capture reads the persistable fields")
  return checkShape({
    schema = EncounterSave.SCHEMA,
    stateVersion = EncounterSave.STATE_VERSION,
    steps = capture.steps,
    repelSteps = capture.repelSteps,
    swarm = capture.swarm,
    playerRoutes = capture.playerRoutes,
    roamers = capture.roamers,
  })
end

-- Restores a bucket for loading: a missing bucket yields the defined source
-- initial state, a present bucket validates exactly (migrating a predecessor
-- first).
---@param bucket table<string, unknown>?
---@param refs { species: table<string, boolean>, maps: table<integer, boolean>, roamerRoutes?: table<integer, integer> }
---@return table<string, unknown>
function EncounterSave.restore(bucket, refs)
  if bucket == nil then
    return EncounterSave.initial()
  end
  return EncounterSave.validate(bucket, refs)
end

return EncounterSave
