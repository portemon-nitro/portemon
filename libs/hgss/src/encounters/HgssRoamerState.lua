-- Stable roaming mon state and lifecycle. Roamers carry semantic identities:
-- encounter construction borrows the stored mon identity, hit points, and
-- status instead of regenerating them, while flee, capture, and defeat
-- commit through revision-checked deltas so stale outcomes never overwrite
-- newer state. Caught and defeated roamers never re-encounter, and the step
-- gate meets only a roaming slot standing on the player's map. This owner
-- also carries the neutral encounter counters persisted alongside the
-- roamer records, the two-entry player route history, and the source roamer
-- graph: the four created slots with their species, level and in-region
-- bounds, the eligible route list, and its adjacency table. Creating a slot
-- and every transition form (connection movement, ordinary-warp history,
-- explicit randomization) are pure updates over that graph drawing from the
-- one supplied world stream; a failed or rejected transition leaves every
-- record and the history untouched. Pure domain module: no love dependency.

local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")

---@class HgssRoamerState
---@field private _records table<string, unknown>[] ordered roamer records by insertion
---@field private _index table<string, integer> roamer key to record position
---@field private _species table<string, boolean> selected species reference set
---@field private _maps table<integer, boolean> selected map reference set
---@field private _native table<string, unknown>? the source roamer slot/route graph
---@field private _nativeSlots { key: string, slot: integer, species: string, level: integer, regionMin: integer, regionCount: integer }[]? the compiled source slots behind the graph in source order
---@field private _routeMaps integer[] route index to map identity
---@field private _steps integer
---@field private _repelSteps integer
---@field private _swarm boolean
---@field private _playerRoutes { current: integer|false, previous: integer|false }
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

-- The source roamer graph resolved into its two runtime faces: the four
-- created slots keyed by slot index, and the route index to map identity
-- table the location bag and the adjacency table both address. Map symbols
-- resolve through the world catalog's symbol index; an unknown route or an
-- unknown slot identity is corrupt generated data, never a guess.
---@param native unknown
---@param mapIdBySymbol table<string, integer>
---@return table<string, unknown>[], integer[]
local function resolveNative(native, mapIdBySymbol)
  if type(native) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer state requires the source roamer graph", {})
  end
  assert(type(native) == "table", "roamer state reads the source roamer graph")
  local routes = native.routes
  local adjacency = native.adjacency
  local slots = native.slots
  if type(routes) ~= "table" or type(adjacency) ~= "table" or type(slots) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "the source roamer graph names routes, adjacency and slots", {})
  end
  assert(type(routes) == "table" and type(adjacency) == "table" and type(slots) == "table", "graph shapes")
  local routeMaps = {}
  for index, symbol in ipairs(routes) do
    local mapId = mapIdBySymbol[symbol]
    if type(mapId) ~= "number" then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer route names an unknown map", { route = symbol })
    end
    assert(type(mapId) == "number", "roamer routes resolve to map identities")
    routeMaps[index] = mapId
  end
  -- The validated source array is the one ordering owner: entry n+1 is source
  -- slot n, so callers never restate the slot count or iterate a zero-based
  -- key table.
  local ordered = {}
  for index, fact in ipairs(slots) do
    if type(fact) ~= "table" or type(fact.slot) ~= "number" or fact.slot ~= index - 1 then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "the source roamer graph orders its slots by source index", {
        slot = type(fact) == "table" and fact.slot or nil,
      })
    end
    assert(type(fact) == "table", "roamer slots carry their source facts")
    ordered[index] = fact --[[@as table<string, unknown>]]
  end
  return ordered, routeMaps
end

---@param args { records: table<string, unknown>[], species: table<string, boolean>, maps: table<integer, boolean>, native: table<string, unknown>?, mapIdBySymbol: table<string, integer>?, steps?: integer, repelSteps?: integer, swarm?: boolean, playerRoutes?: table<string, unknown> }
---@return HgssRoamerState
function HgssRoamerState.new(args)
  if type(args) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer state requires an argument record", {})
  end
  assert(type(args) == "table", "roamer state reads its construction record")
  local refs = checkRefs({ species = args.species, maps = args.maps }, "roamer state")
  local nativeSlots, routeMaps = nil, nil
  if args.native ~= nil then
    local mapIdBySymbol = args.mapIdBySymbol
    if type(mapIdBySymbol) ~= "table" then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer state resolves its routes through the world catalog", {})
    end
    ---@cast mapIdBySymbol -nil
    nativeSlots, routeMaps = resolveNative(args.native, mapIdBySymbol)
  end
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
  local playerRoutes = { current = false, previous = false }
  if args.playerRoutes ~= nil then
    local value = args.playerRoutes
    if type(value) ~= "table" then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer player routes must be a record", {})
    end
    assert(type(value) == "table", "roamer state reads the player route history")
    playerRoutes = { current = value.current, previous = value.previous }
  end
  return setmetatable({
    _records = records,
    _index = index,
    _species = refs.species,
    _maps = refs.maps,
    _native = args.native,
    _nativeSlots = nativeSlots,
    _routeMaps = routeMaps,
    _steps = steps,
    _repelSteps = repelSteps,
    _swarm = swarm,
    _playerRoutes = playerRoutes,
  }, HgssRoamerState)
end

-- Restores roamer state from a persisted bucket, validating selected
-- references through the save owner. Native metadata is validated against
-- the same source route table the movement reads.
---@param bucket table<string, unknown>
---@param refs { species: table<string, boolean>, maps: table<integer, boolean>, mapIdBySymbol?: table<string, integer> }
---@param native table<string, unknown>?
---@return HgssRoamerState
function HgssRoamerState.restore(bucket, refs, native)
  local routeMaps = nil
  if native ~= nil then
    local mapIdBySymbol = refs.mapIdBySymbol
    if type(mapIdBySymbol) ~= "table" then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer restoration resolves its routes through the world catalog", {})
    end
    ---@cast mapIdBySymbol -nil
    local _, resolved = resolveNative(native, mapIdBySymbol)
    routeMaps = resolved
  end
  local valid = EncounterSave.validate(bucket, {
    species = refs.species,
    maps = refs.maps,
    roamerRoutes = routeMaps,
  })
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
    native = native,
    mapIdBySymbol = refs.mapIdBySymbol,
    playerRoutes = valid.playerRoutes,
    steps = valid.steps,
    repelSteps = valid.repelSteps,
    swarm = valid.swarm,
  })
end

-- Reads the outbreak-active fact for encounter preparation. The flag lives
-- with the encounter owner; radio music never resumes from saved state.
---@return boolean
function HgssRoamerState:isSwarmActive()
  return self._swarm == true
end

-- Reads the live repel counter for encounter preparation.
---@return integer remaining repel steps
function HgssRoamerState:repelSteps()
  return self._repelSteps
end

-- Decrements the repel counter for one committed step, matching the native
-- per-step update: a counter already at zero stays there. Returns true on
-- the step that wears the repel off, the native hook for the map script
-- the field owns.
---@return boolean wore off on this step
function HgssRoamerState:stepRepel()
  if self._repelSteps <= 0 then
    return false
  end
  self._repelSteps = self._repelSteps - 1
  return self._repelSteps == 0
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

---@param value unknown
---@return integer raw source draw
local function nextU16(value)
  if type(value) ~= "table" or type(value.nextRaw) ~= "function" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer transitions require the world random stream", {})
  end
  assert(type(value) == "table", "roamer transitions read the world random stream")
  local draw = value.nextRaw --[[@as fun(self: table<string, unknown>): integer]]
  local raw = draw(value)
  assert(type(raw) == "number", "the world random stream answers a raw value")
  return raw % 65536
end

-- field_roamer.c::getRandomActiveRoamerInCurrMap: the step encounter gate.
-- The source collects the active slots standing on the player's map, then
-- refuses the meeting on its own 1-in-2 draw and picks uniformly when
-- several slots stand there. A map with no standing roamer draws nothing.
---@param mapId integer the player's map identity
---@param rng { nextRaw: fun(self: table<string, unknown>): integer } world random stream
---@return string? the standing roamer's record key, nil when none is met
function HgssRoamerState:stepEncounterKey(mapId, rng)
  if type(mapId) ~= "number" or mapId % 1 ~= 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer encounters name the player's map", { mapId = mapId })
  end
  local standing = {}
  for _, record in ipairs(self._records) do
    assert(type(record) == "table", "the roamer index carries its records")
    if record.lifecycle == "roaming" and record.location == mapId then
      standing[#standing + 1] = record
    end
  end
  if #standing == 0 then
    return nil
  end
  -- LCRandRange(2) refuses on zero: the step consumes one draw whenever a
  -- roaming slot stands on the player's map.
  if nextU16(rng) % 2 == 0 then
    return nil
  end
  local chosen = standing[1]
  if #standing > 1 then
    chosen = assert(standing[nextU16(rng) % #standing + 1], "the standing pick stays in range")
  end
  assert(type(chosen) == "table", "the gate answers a standing record")
  return chosen.key --[[@as string]]
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

-- Captures the persistable encounter state: authoritative counters, the
-- player route history, and the detached roamer records. Tables never
-- persist.
---@return { steps: integer, repelSteps: integer, swarm: boolean, playerRoutes: table<string, unknown>, roamers: table<string, table<string, unknown>> }
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
    playerRoutes = { current = self._playerRoutes.current, previous = self._playerRoutes.previous },
    roamers = roamers,
  }
end

-- The source graph facts behind one created slot, for the caller that
-- materializes the roaming mon through the ordinary creation owner.
---@param slot integer source slot index
---@return { slot: integer, key: string, species: string, level: integer, regionMin: integer, regionCount: integer }
function HgssRoamerState:nativeSlot(slot)
  if type(slot) ~= "number" or slot % 1 ~= 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer creation names a source slot index", { slot = slot })
  end
  local slots = self._nativeSlots
  if type(slots) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer creation requires the source roamer graph", { slot = slot })
  end
  ---@cast slots -nil
  assert(type(slots) == "table", "roamer creation reads the source slots")
  local fact = slots[slot + 1]
  if type(fact) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "no source roamer slot " .. tostring(slot), { slot = slot })
  end
  assert(type(fact) == "table", "the source graph carries its slots")
  return {
    slot = slot,
    key = fact.key --[[@as string]],
    species = fact.species --[[@as string]],
    level = fact.level --[[@as integer]],
    regionMin = fact.regionMin --[[@as integer]],
    regionCount = fact.regionCount --[[@as integer]],
  }
end

---@param routeIndex integer source route index
---@return integer route map identity
function HgssRoamerState:_routeMap(routeIndex)
  local routes = self._routeMaps
  assert(type(routes) == "table", "roamer movement reads the source route table")
  local mapId = routes[routeIndex + 1]
  if type(mapId) ~= "number" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "no source roamer route " .. tostring(routeIndex), {
      routeIndex = routeIndex,
    })
  end
  assert(type(mapId) == "number", "the source route table carries map identities")
  return mapId
end

-- The source roamer location identity of one map: its own map id when the
-- map is one of the eligible routes, no location otherwise. The player
-- history records these identities, which is why a non-route map leaves no
-- exclusion behind.
---@param mapId integer|unknown
---@return integer|false the eligible route identity, or no location
function HgssRoamerState:routeLocationOf(mapId)
  local routes = self._routeMaps
  if type(routes) ~= "table" or type(mapId) ~= "number" then
    return false
  end
  for _, routeMap in ipairs(routes) do
    if routeMap == mapId then
      return mapId --[[@as integer]]
    end
  end
  return false
end

-- field_roamer.c::RoamerLocationSetRandom: one in-region draw per attempt,
-- rejecting the player's previous location and the roamer's current route.
---@param slot table<string, unknown> source slot facts
---@param current integer? current route index, nil when the slot is fresh
---@param rng { nextRaw: fun(self: table<string, unknown>): integer } world random stream
---@return integer the chosen route index
function HgssRoamerState:_chooseRandom(slot, current, rng)
  local regionMin = slot.regionMin --[[@as integer]]
  local regionCount = slot.regionCount --[[@as integer]]
  local previous = self._playerRoutes.previous
  local currentMap = current ~= nil and self:_routeMap(current) or nil
  while true do
    local candidate = nextU16(rng) % regionCount + regionMin
    local candidateMap = self:_routeMap(candidate)
    if candidateMap ~= previous and candidateMap ~= currentMap then
      return candidate
    end
  end
end

---@param record table<string, unknown>
---@param routeIndex integer
local function setRoute(record, routeIndex)
  local native = record.native
  assert(type(native) == "table", "native roamer records carry their metadata")
  native.routeIndex = routeIndex
end

-- field_roamer.c::Save_UpdateRoamersLocation: per active slot in source
-- index order one 1/16 chance to randomize inside the slot's region,
-- otherwise one adjacent route, never the player's previous location. A
-- single neighbour that is that location falls back to the random branch.
-- Terminal slots never move and draw nothing.
---@param rng { nextRaw: fun(self: table<string, unknown>): integer } world random stream
function HgssRoamerState:updateOnConnectionEntry(rng)
  local slots = assert(self._nativeSlots, "roamer movement requires the source roamer graph")
  ---@cast slots -nil
  assert(type(slots) == "table", "roamer movement reads the source slots")
  local previous = self._playerRoutes.previous
  local adjacency = assert(self._native, "roamer movement reads the adjacency table")
  local neighbours = adjacency.adjacency --[[@as table<integer, integer[]>]]
  assert(type(neighbours) == "table", "the source graph carries its adjacency table")
  for _, fact in ipairs(slots) do
    assert(type(fact) == "table", "the source graph carries its slots")
    local record = self._records[
      self._index[
        fact.key --[[@as string]]
      ] or 0
    ]
    if type(record) == "table" and record.lifecycle == "roaming" then
      assert(type(record) == "table", "roaming slots own their record")
      local native = record.native
      assert(type(native) == "table", "native roamer records carry their metadata")
      local current = native.routeIndex --[[@as integer]]
      local chosen
      if nextU16(rng) % 16 == 0 then
        chosen = self:_chooseRandom(fact, current, rng)
      else
        local options = neighbours[current + 1]
        assert(type(options) == "table" and #options > 0, "the source graph names the current route's neighbours")
        if #options == 1 then
          local only = options[1]
          assert(type(only) == "number", "adjacency names route indexes")
          if self:_routeMap(only) == previous then
            chosen = self:_chooseRandom(fact, current, rng)
          else
            chosen = only
          end
        else
          while true do
            local candidate = options[nextU16(rng) % #options + 1]
            assert(type(candidate) == "number", "adjacency names route indexes")
            if self:_routeMap(candidate) ~= previous then
              chosen = candidate
              break
            end
          end
        end
      end
      setRoute(record, chosen)
      record.location = self:_routeMap(chosen)
      record.revision = record.revision --[[@as integer]] + 1
    end
  end
end

-- field_roamer.c::Save_RandomizeRoamersLocation: every active slot picks a
-- fresh in-region route, excluding the player's previous location and its
-- own current route, one draw attempt at a time in source order.
---@param rng { nextRaw: fun(self: table<string, unknown>): integer } world random stream
function HgssRoamerState:randomizeLocations(rng)
  local slots = assert(self._nativeSlots, "roamer randomization requires the source roamer graph")
  ---@cast slots -nil
  assert(type(slots) == "table", "roamer randomization reads the source slots")
  for _, fact in ipairs(slots) do
    assert(type(fact) == "table", "the source graph carries its slots")
    local record = self._records[
      self._index[
        fact.key --[[@as string]]
      ] or 0
    ]
    if type(record) == "table" and record.lifecycle == "roaming" then
      assert(type(record) == "table", "roaming slots own their record")
      local native = record.native
      assert(type(native) == "table", "native roamer records carry their metadata")
      local chosen = self:_chooseRandom(fact, native.routeIndex --[[@as integer]], rng)
      setRoute(record, chosen)
      record.location = self:_routeMap(chosen)
      record.revision = record.revision --[[@as integer]] + 1
    end
  end
end

-- Records one transition's player location: the destination becomes the
-- current entry and the map the player left the previous one. Connections
-- and ordinary warps record the source's roamer location identity (no
-- location for a map outside the route graph); an explicit fly warp records
-- the raw destination and departure identities.
---@param kind string connection, ordinary or fly
---@param mapId integer destination map identity
---@param leftMapId integer map identity the player left
function HgssRoamerState:notePlayerLocation(kind, mapId, leftMapId)
  assert(kind == "connection" or kind == "ordinary" or kind == "fly", "roamer transitions name their form")
  assert(type(mapId) == "number" and type(leftMapId) == "number", "roamer transitions name both maps")
  local entered, left
  if kind == "fly" then
    entered = mapId
    left = leftMapId
  else
    entered = self:routeLocationOf(mapId)
    left = self:routeLocationOf(leftMapId)
  end
  self._playerRoutes.previous = left
  self._playerRoutes.current = entered
end

-- The captured player route history, for callers that only read it.
---@return { current: integer|false, previous: integer|false }
function HgssRoamerState:playerRoutes()
  return { current = self._playerRoutes.current, previous = self._playerRoutes.previous }
end

-- Source slot creation (field_roamer.c::Save_CreateRoamerByID): the created
-- mon's identity, battle health and route replace whatever the slot held. The
-- League ending recreates exactly the slots a previous battle defeated, so a
-- terminal defeated record is a legitimate creation target; a slot that is
-- still roaming or already captured is never recreated and is a caller error.
-- The owner admits the target before anything is materialized, and recreates
-- in the record's existing position with an advanced revision, so a stale
-- outcome of the defeated encounter can never overwrite the new one.
---@param slot integer source slot index
---@param materialize fun(fact: { species: string, level: integer }): table<string, unknown>|nil the ordinary creation owner
---@param rng { nextRaw: fun(self: table<string, unknown>): integer } world random stream
---@return table<string, unknown> the created record
function HgssRoamerState:createNativeSlot(slot, materialize, rng)
  local fact = self:nativeSlot(slot)
  if type(materialize) ~= "function" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer creation requires its creation owner", { slot = slot })
  end
  assert(type(materialize) == "function", "roamer creation materializes through the ordinary owner")
  local position = self._index[fact.key]
  local existing = position ~= nil and self._records[position] or nil
  if existing ~= nil and existing.lifecycle ~= "defeated" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer slot " .. tostring(slot) .. " is already created", {
      slot = slot,
      roamer = fact.key,
      lifecycle = existing.lifecycle,
    })
  end
  local mon = materialize({ species = fact.species, level = fact.level })
  if type(mon) ~= "table" or type(mon.species) ~= "string" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer creation requires a materialized mon", { slot = slot })
  end
  assert(type(mon) == "table", "roamer creation reads the created mon")
  if mon.species ~= fact.species then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer creation materialized the wrong species", {
      slot = slot,
      species = mon.species,
    })
  end
  local condition = mon.condition
  if type(condition) ~= "table" or type(condition.currentHp) ~= "number" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "a created roamer carries its battle condition", { slot = slot })
  end
  assert(type(condition) == "table", "roamer creation reads the created mon's condition")
  local chosen = self:_chooseRandom(fact, nil, rng)
  local record = {
    key = fact.key,
    stateVersion = EncounterSave.STATE_VERSION,
    mon = {},
    location = self:_routeMap(chosen),
    lifecycle = "roaming",
    revision = existing ~= nil and existing.revision --[[@as integer]] + 1 or 0,
    native = { slot = slot, routeIndex = chosen },
  }
  local stored = record.mon --[[@as table<string, unknown>]]
  for key, value in pairs(mon) do
    stored[key] = copyValue(value)
  end
  local storedCondition = stored.condition --[[@as table<string, unknown>]]
  storedCondition.currentHp = condition.currentHp
  if existing ~= nil then
    assert(type(position) == "number", "the roamer index carries its position")
    self._records[
      position --[[@as integer]]
    ] = record
  else
    local records = self._records
    records[#records + 1] = record
    self._index[fact.key] = #records
  end
  return copyValue(record)
end

return HgssRoamerState
