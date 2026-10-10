-- Encounter opportunity and retained preparation owner. A field attempt is a
-- semantic operation, not a frame update: locomotion movements advance the
-- step counters and consult the random stream, while idle, forced, and
-- scripted movements never draw. Successful attempts stage selection and
-- generation in source order (opportunity, slot, level, then the wild
-- identity trace, with repel evaluated after level selection and lead
-- abilities applied at their source stages), and the prepared encounter is
-- retained until consumed once or restored without reroll. Rejected input
-- consumes no draws and no attempt identities. Wild capture metadata beyond
-- the map identity stays neutral unless the caller supplies a validated
-- origin record: without one generation records the lookup identity with
-- fixed neutral values. Pure domain module: no love dependency.

local EncounterSelection = require("libs.hgss.src.encounters.EncounterSelection")
local Errors = require("libs.errors.src.Errors")
local Stats = require("libs.mons.src.gen4.Stats")

---@class HgssEncounterService
---@field private _catalog HgssEncounterCatalog
---@field private _factory WildMonFactory
---@field private _roamers HgssRoamerState?
---@field private _game string?
---@field private _nextAttemptId integer
---@field private _revision integer
---@field private _steps integer
---@field private _pending table<string, unknown>?
---@field private _pendingAttemptId integer?
---@field private _protected boolean
---@field private _lastConsumed integer?
local HgssEncounterService = {}
HgssEncounterService.__index = HgssEncounterService

HgssEncounterService.RULESET = "hgss-wild"
HgssEncounterService.FORMAT = "wild-single"
HgssEncounterService.SNAPSHOT_SCHEMA = "hgss-encounter-service-v1"

-- Neutral wild capture metadata, recorded because the typed attempt context
-- carries no clock, ball, or native terrain source.
local WILD_BALL = "POKE_BALL"
local WILD_TERRAIN = 0
local WILD_DATE = { year = 2000, month = 1, day = 1 }

local CHECKING_MOVEMENTS = { step = true, fish = true }
local IDLE_MOVEMENTS = { still = true, menu = true }
local FORCED_MOVEMENTS = { forced = true, forced_movement = true }
local SCRIPTED_MOVEMENTS = { scripted = true, scripted_movement = true }

local LEAD_ABILITIES = { synchronize = true, intimidate = true }

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

---@param args { catalog: HgssEncounterCatalog, wildFactory: WildMonFactory, roamers?: HgssRoamerState, game?: string }
---@return HgssEncounterService
function HgssEncounterService.new(args)
  assert(type(args) == "table", "encounter service requires an argument record")
  assert(
    args.catalog ~= nil and type(args.catalog.tableFor) == "function",
    "encounter service requires an encounter catalog"
  )
  assert(
    args.wildFactory ~= nil
      and type(args.wildFactory.create) == "function"
      and type(args.wildFactory.createStatic) == "function",
    "encounter service requires a wild mon factory"
  )
  if args.roamers ~= nil then
    assert(type(args.roamers.prepareEncounter) == "function", "encounter service roamers must borrow identities")
  end
  if args.game ~= nil then
    assert(type(args.game) == "string", "encounter service game must be a string")
  end
  return setmetatable({
    _catalog = args.catalog,
    _factory = args.wildFactory,
    _roamers = args.roamers,
    _game = args.game,
    _nextAttemptId = 1,
    _revision = 0,
    _steps = 0,
    _pending = nil,
    _pendingAttemptId = nil,
    _protected = false,
    _lastConsumed = nil,
  }, HgssEncounterService)
end

---@param met unknown
local function checkMetRecord(met)
  if type(met) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter met context must be a record", {})
  end
  assert(type(met) == "table", "met checks read the met record")
  local location = met.location
  if type(location) ~= "number" or location % 1 ~= 0 or location < 0 or location > 0xFFFF then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter met location must be an integer in 0..65535", {})
  end
  local date = met.date
  if type(date) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter met context requires a date record", {})
  end
  assert(type(date) == "table", "met checks read the date record")
  if type(date.year) ~= "number" or date.year % 1 ~= 0 or date.year < 2000 or date.year > 2255 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter met date year must be an integer in 2000..2255", {})
  end
  if type(date.month) ~= "number" or date.month % 1 ~= 0 or date.month < 1 or date.month > 12 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter met date month must be an integer in 1..12", {})
  end
  if type(date.day) ~= "number" or date.day % 1 ~= 0 or date.day < 1 or date.day > 31 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter met date day must be an integer in 1..31", {})
  end
  local terrain = met.terrain
  if terrain ~= nil and (type(terrain) ~= "number" or terrain % 1 ~= 0 or terrain < 0 or terrain > 0xFF) then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter met terrain must be an integer in 0..255", {})
  end
end

---@param context unknown
---@return table<string, unknown>
local function checkContext(context)
  if type(context) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter attempts require a context record", {})
  end
  assert(type(context) == "table", "attempts read their context record")
  if type(context.eventId) ~= "number" or context.eventId % 1 ~= 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter attempts require an integer event identity", {})
  end
  if type(context.mapId) ~= "number" or context.mapId % 1 ~= 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter attempts require an integer map identity", {})
  end
  if type(context.method) ~= "string" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter attempts require a method", {})
  end
  if type(context.movement) ~= "string" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter attempts require a movement", {})
  end
  if type(context.modifiers) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter attempts require a modifier record", {})
  end
  if type(context.environment) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter attempts require an environment record", {})
  end
  if context.met ~= nil then
    checkMetRecord(context.met)
  end
  return context
end

---@param modifiers table<string, unknown>
local function checkModifiers(modifiers)
  local repel = modifiers.repel or false
  if repel ~= false and repel ~= true then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter repel state must be a boolean", {})
  end
  if modifiers.repelSteps ~= nil then
    local steps = modifiers.repelSteps
    if type(steps) ~= "number" or steps % 1 ~= 0 or steps < 0 then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter repel steps must be a non-negative integer", {})
    end
  end
  if modifiers.swarm ~= nil and modifiers.swarm ~= false and modifiers.swarm ~= true then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter swarm state must be a boolean", {})
  end
  if modifiers.radio ~= nil and type(modifiers.radio) ~= "string" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter radio state must be a string", {})
  end
  if modifiers.rod ~= nil and type(modifiers.rod) ~= "string" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter rod state must be a string", {})
  end
  if modifiers.roamerKey ~= nil and type(modifiers.roamerKey) ~= "string" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter roamer state must be a string key", {})
  end
  local leadAbility = modifiers.leadAbility
  if leadAbility ~= nil and LEAD_ABILITIES[leadAbility] ~= true then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter lead ability " .. tostring(leadAbility) .. " is unknown", {
      leadAbility = leadAbility,
    })
  end
end

---@param lead unknown
---@return integer lead level
local function leadLevelOrRaise(lead)
  if type(lead) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "lead abilities and repel require the party lead", {})
  end
  assert(type(lead) == "table", "lead checks read the party lead")
  local met = lead.met
  if type(met) ~= "table" or type(met.level) ~= "number" or met.level % 1 ~= 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "the party lead carries no level", {})
  end
  assert(type(met) == "table" and type(met.level) == "number", "lead checks read the lead level")
  return met.level
end

---@param context table<string, unknown>
local function checkLeadRequirements(context)
  local modifiers = context.modifiers
  assert(type(modifiers) == "table", "lead checks read the modifier record")
  -- Establishing repel without a lead is rejected, but an already-counting
  -- repel outlives a missing lead: without a lead level nothing can be
  -- blocked, so the attempt simply proceeds.
  if modifiers.repel == true and modifiers.repelSteps == nil then
    leadLevelOrRaise(context.lead)
  end
  if modifiers.leadAbility ~= nil then
    leadLevelOrRaise(context.lead)
    if modifiers.leadAbility == "synchronize" then
      local leadNature = modifiers.leadNature
      if type(leadNature) ~= "number" or leadNature % 1 ~= 0 or leadNature < 0 or leadNature > Stats.MAX_NATURE then
        Errors.raise(
          "ENCOUNTER_INVALID_INPUT",
          "synchronize coercion requires a lead nature in 0.." .. Stats.MAX_NATURE,
          {}
        )
      end
    end
  end
end

---@param method string
---@return boolean
local function isTableMethod(method)
  return method == "grass" or method == "surf" or method == "fish" or method == "rock_smash"
end

---@param self HgssEncounterService
---@param context table<string, unknown>
---@return { steps: integer, repelSteps: integer }
function HgssEncounterService:_advanceCounters(context)
  local modifiers = context.modifiers
  assert(type(modifiers) == "table", "counters read the modifier record")
  local repelOut = modifiers.repelSteps or 0
  if CHECKING_MOVEMENTS[context.movement] == true then
    self._steps = self._steps + 1
    if modifiers.repel == true and type(repelOut) == "number" and repelOut > 0 then
      repelOut = repelOut - 1
    end
  end
  return { steps = self._steps, repelSteps = repelOut }
end

---@param self HgssEncounterService
---@param context table<string, unknown>
---@param attemptId integer
---@return table<string, unknown>
function HgssEncounterService:_wildOptions(context, attemptId)
  assert(attemptId ~= nil, "wild options carry the attempt identity")
  local met = context.met
  if type(met) == "table" then
    local terrain = WILD_TERRAIN
    if met.terrain ~= nil then
      terrain = met.terrain
    end
    local date = assert(met.date, "validated met context carries its date")
    assert(type(date) == "table", "validated met context carries its date record")
    return {
      profile = context.playerProfile,
      ball = WILD_BALL,
      location = met.location,
      terrain = terrain,
      date = { year = date.year, month = date.month, day = date.day },
    }
  end
  return {
    profile = context.playerProfile,
    ball = WILD_BALL,
    location = context.mapId,
    terrain = WILD_TERRAIN,
    date = copyValue(WILD_DATE),
  }
end

---@param self HgssEncounterService
---@param context table<string, unknown>
---@param attemptId integer
---@param mon table<string, unknown>
---@param reason string
---@return table<string, unknown>
function HgssEncounterService:_prepare(mon, context, attemptId, reason)
  local modifiers = context.modifiers
  assert(type(modifiers) == "table", "preparation reads the modifier record")
  local environment = context.environment
  assert(type(environment) == "table", "preparation reads the environment record")
  local encounter = {
    id = attemptId,
    mons = { { mon = mon, source = nil } },
    ruleset = HgssEncounterService.RULESET,
    format = HgssEncounterService.FORMAT,
    environment = copyValue(environment),
    provenance = { method = context.method, mapId = context.mapId, attemptId = attemptId },
  }
  self._pending = encounter
  self._pendingAttemptId = attemptId
  return {
    kind = "prepared",
    attemptId = attemptId,
    stateRevision = self._revision,
    stateDelta = self:_advanceCounters(context),
    encounter = encounter,
    reason = reason,
  }
end

---@param self HgssEncounterService
---@param context table<string, unknown>
---@param attemptId integer
---@param reason string
---@return table<string, unknown>
function HgssEncounterService:_miss(context, attemptId, reason)
  return {
    kind = "none",
    attemptId = attemptId,
    stateRevision = self._revision,
    stateDelta = self:_advanceCounters(context),
    reason = reason,
  }
end

---@param self HgssEncounterService
---@param context table<string, unknown>
---@param stream table<string, unknown>
---@param attemptId integer
---@return table<string, unknown>
function HgssEncounterService:_attemptStatic(context, stream, attemptId)
  local modifiers = context.modifiers
  assert(type(modifiers) == "table", "static attempts read the modifier record")
  local scripted = modifiers.static
  if type(scripted) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "scripted encounters require a static record", {})
  end
  assert(type(scripted) == "table", "static attempts read the static record")
  local options = self:_wildOptions(context, attemptId)
  local mon = self._factory:createStatic(scripted.species, scripted.level, stream, options)
  local encounter = {
    id = attemptId,
    mons = { { mon = mon, source = nil } },
    ruleset = HgssEncounterService.RULESET,
    format = HgssEncounterService.FORMAT,
    environment = copyValue(context.environment),
    provenance = { method = context.method, mapId = context.mapId, attemptId = attemptId },
  }
  self._pending = encounter
  self._pendingAttemptId = attemptId
  local modifiersOut = context.modifiers
  assert(type(modifiersOut) == "table", "static attempts echo their counters")
  return {
    kind = "prepared",
    attemptId = attemptId,
    stateRevision = self._revision,
    stateDelta = { steps = self._steps, repelSteps = modifiersOut.repelSteps or 0 },
    encounter = encounter,
    reason = "static",
  }
end

---@param self HgssEncounterService
---@param context table<string, unknown>
---@param attemptId integer
---@return table<string, unknown>
function HgssEncounterService:_attemptRoamer(context, attemptId)
  if self._roamers == nil then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer encounters require roamer state", {})
  end
  assert(self._roamers ~= nil, "roamer attempts borrow the stored identity")
  local modifiers = context.modifiers
  assert(type(modifiers) == "table", "roamer attempts read the modifier record")
  if type(modifiers.roamerKey) ~= "string" or modifiers.roamerKey == "" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer encounters require a roamer key", {})
  end
  local record = self._roamers:prepareEncounter(modifiers.roamerKey)
  assert(type(record) == "table", "roamer attempts borrow the stored record")
  return self:_prepare(copyValue(record.mon), context, attemptId, "roamer")
end

---@param self HgssEncounterService
---@param context table<string, unknown>
---@param stream table<string, unknown>
---@param attemptId integer
---@return table<string, unknown>
function HgssEncounterService:_attemptTable(context, stream, attemptId)
  local modifiers = context.modifiers
  assert(type(modifiers) == "table", "table attempts read the modifier record")
  local method = context.method
  assert(type(method) == "string", "table attempts read the encounter method")
  local resolved = self._catalog:tableFor(context.mapId, {
    timeOfDay = context.timeOfDay,
    swarm = modifiers.swarm == true,
    radio = modifiers.radio or "none",
    game = self._game,
    rod = modifiers.rod,
  })
  local selected = EncounterSelection.selectTable(resolved, method, {
    timeOfDay = context.timeOfDay,
    rod = modifiers.rod,
  })
  local rate = selected.rate
  local leadAbility = modifiers.leadAbility
  if leadAbility == "intimidate" then
    rate = math.floor(rate / 2)
  end
  assert(type(stream.nextU16) == "function", "table attempts consult the labeled stream")
  local draw = stream.nextU16
  local cause = { kind = "encounter", method = method }
  if not EncounterSelection.trigger(rate, draw(stream, "opportunity", cause) % 100) then
    if method == "fish" then
      return self:_miss(context, attemptId, "no_bite")
    end
    return self:_miss(context, attemptId, "no_opportunity")
  end
  local slots = selected.slots
  local slot = slots[EncounterSelection.selectSlot(slots, draw(stream, "slot", cause) % 100)]
  assert(type(slot) == "table", "slot selection resolves its ordered slot")
  local level = EncounterSelection.selectLevel(slot, draw(stream, "level", cause))
  local repelSteps = modifiers.repelSteps
  if modifiers.repel == true and (repelSteps == nil or repelSteps > 0) and context.lead ~= nil then
    if level < leadLevelOrRaise(context.lead) then
      return self:_miss(context, attemptId, "repel")
    end
  end
  local options = self:_wildOptions(context, attemptId)
  if leadAbility == "synchronize" then
    options.leadAbility = "synchronize"
    options.leadNature = modifiers.leadNature
  end
  local mon = self._factory:create(slot.species, level, stream, options)
  return self:_prepare(mon, context, attemptId, "triggered")
end

-- Runs one semantic field attempt. Scripted encounters bypass movement
-- gating; locomotion consults the tables while idle, forced, and scripted
-- movements return without drawing.
---@param context table<string, unknown>
---@param stream table<string, unknown>
---@return table<string, unknown>
function HgssEncounterService:attempt(context, stream)
  local checked = checkContext(context)
  checkModifiers(checked.modifiers)
  local method = checked.method
  assert(type(method) == "string", "attempts dispatch on the encounter method")
  local movement = checked.movement
  assert(type(movement) == "string", "attempts dispatch on the movement")
  if type(stream) ~= "table" or type(stream.nextU16) ~= "function" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter attempts require a labeled draw stream", {})
  end
  if method == "static" then
    checkLeadRequirements(checked)
    if self._protected then
      Errors.raise("ENCOUNTER_PENDING", "an encounter is already prepared", { attemptId = self._pendingAttemptId })
    end
    local attemptId = self._nextAttemptId
    self._nextAttemptId = attemptId + 1
    self._revision = self._revision + 1
    return self:_attemptStatic(checked, stream, attemptId)
  end
  if CHECKING_MOVEMENTS[movement] ~= true then
    if
      IDLE_MOVEMENTS[movement] ~= true
      and FORCED_MOVEMENTS[movement] ~= true
      and SCRIPTED_MOVEMENTS[movement] ~= true
    then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "unknown encounter movement " .. tostring(movement), {
        movement = movement,
      })
    end
    checkLeadRequirements(checked)
    if self._protected then
      Errors.raise("ENCOUNTER_PENDING", "an encounter is already prepared", { attemptId = self._pendingAttemptId })
    end
    local attemptId = self._nextAttemptId
    self._nextAttemptId = attemptId + 1
    self._revision = self._revision + 1
    if IDLE_MOVEMENTS[movement] == true then
      return self:_miss(checked, attemptId, "idle")
    elseif FORCED_MOVEMENTS[movement] == true then
      return self:_miss(checked, attemptId, "forced_movement")
    else
      return self:_miss(checked, attemptId, "scripted_movement")
    end
  end
  if not isTableMethod(method) and method ~= "roamer" then
    if method == "headbutt" or method == "safari" or method == "bug_contest" or method == "unown" then
      Errors.raise("ENCOUNTER_MISSING_TABLE", "encounter method " .. method .. " has no provider slots", {
        method = method,
      })
    end
    Errors.raise("ENCOUNTER_INVALID_INPUT", "unknown encounter method " .. tostring(method), { method = method })
  end
  checkLeadRequirements(checked)
  if self._protected then
    Errors.raise("ENCOUNTER_PENDING", "an encounter is already prepared", { attemptId = self._pendingAttemptId })
  end
  local attemptId = self._nextAttemptId
  self._nextAttemptId = attemptId + 1
  self._revision = self._revision + 1
  if method == "roamer" then
    return self:_attemptRoamer(checked, attemptId)
  end
  return self:_attemptTable(checked, stream, attemptId)
end

-- Consumes a prepared encounter exactly once, transferring its ownership to
-- the caller without rerolling. Repeat consumption is rejected.
---@param attemptId integer
---@return table<string, unknown>
function HgssEncounterService:consume(attemptId)
  if self._pending ~= nil and self._pendingAttemptId == attemptId then
    local encounter = self._pending
    self._pending = nil
    self._pendingAttemptId = nil
    self._protected = false
    self._lastConsumed = attemptId
    assert(type(encounter) == "table", "consumption transfers the prepared encounter")
    return encounter
  end
  if self._lastConsumed ~= nil and self._lastConsumed == attemptId then
    Errors.raise("ENCOUNTER_ALREADY_CONSUMED", "encounter " .. tostring(attemptId) .. " was already consumed", {
      attemptId = attemptId,
    })
  end
  Errors.raise("ENCOUNTER_INVALID_INPUT", "no prepared encounter " .. tostring(attemptId), { attemptId = attemptId })
  error("unreachable consume", 0)
end

-- Captures the restorable service snapshot: attempt identity, revision,
-- step counters, and the pending encounter. The snapshot is plain data.
---@return table<string, unknown>
function HgssEncounterService:capture()
  return {
    schema = HgssEncounterService.SNAPSHOT_SCHEMA,
    nextAttemptId = self._nextAttemptId,
    revision = self._revision,
    steps = self._steps,
    pending = copyValue(self._pending),
    pendingAttemptId = self._pendingAttemptId,
  }
end

-- Restores a captured snapshot without rerolling, returning a poll view of
-- the pending encounter. Malformed snapshots fail without mutation.
---@param snapshot unknown
---@return { attemptId: integer, encounter: table<string, unknown>? }
function HgssEncounterService:restore(snapshot)
  if type(snapshot) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter restoration requires a snapshot record", {})
  end
  assert(type(snapshot) == "table", "restoration reads the snapshot record")
  for key in pairs(snapshot) do
    if
      key ~= "schema"
      and key ~= "nextAttemptId"
      and key ~= "revision"
      and key ~= "steps"
      and key ~= "pending"
      and key ~= "pendingAttemptId"
    then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter snapshot contains an unknown field", { field = key })
    end
  end
  if snapshot.schema ~= HgssEncounterService.SNAPSHOT_SCHEMA then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter snapshot carries an unknown schema", {})
  end
  if type(snapshot.nextAttemptId) ~= "number" or snapshot.nextAttemptId % 1 ~= 0 or snapshot.nextAttemptId < 1 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter snapshot carries an invalid attempt identity", {})
  end
  if type(snapshot.revision) ~= "number" or snapshot.revision % 1 ~= 0 or snapshot.revision < 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter snapshot carries an invalid revision", {})
  end
  if type(snapshot.steps) ~= "number" or snapshot.steps % 1 ~= 0 or snapshot.steps < 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter snapshot carries an invalid step counter", {})
  end
  if snapshot.pending ~= nil then
    if type(snapshot.pending) ~= "table" then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter snapshot carries an invalid pending encounter", {})
    end
    if type(snapshot.pendingAttemptId) ~= "number" then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter snapshot carries an invalid pending identity", {})
    end
  elseif snapshot.pendingAttemptId ~= nil then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter snapshot carries an invalid pending identity", {})
  end
  self._nextAttemptId = snapshot.nextAttemptId
  self._revision = snapshot.revision
  self._steps = snapshot.steps
  self._pending = copyValue(snapshot.pending)
  self._pendingAttemptId = snapshot.pendingAttemptId
  -- Adopted encounters are protected: unlike fresh staging, which a newer
  -- attempt supersedes, restored state must not be silently discarded, so
  -- new preparations wait until the adopted encounter is consumed.
  self._protected = snapshot.pending ~= nil
  if self._pending ~= nil then
    assert(type(self._pendingAttemptId) == "number", "restoration retains the pending identity")
    return { attemptId = self._pendingAttemptId, encounter = copyValue(self._pending) }
  end
  return { attemptId = 0, encounter = nil }
end

return HgssEncounterService
