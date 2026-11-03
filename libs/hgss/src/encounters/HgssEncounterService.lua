-- Encounter opportunity and retained preparation owner. A field attempt is a
-- semantic operation, not a frame update: locomotion movements advance the
-- step counters and consult the random stream, while idle, forced, and
-- scripted movements never draw. Every committed ordinary step advances the
-- entry grace (steps that never reach an attempt arrive through noteStep);
-- the grace refuses land, water, and roaming step checks before any table
-- lookup or draw. Step table attempts on land and water then take the
-- native pair of opportunity rolls (the movement roll, then the table
-- rate); roaming steps stage the tile's own land-or-water rate through the
-- same roll order before borrowing the stored identity. Successful table
-- attempts stage selection and generation in source order (magnet-pull or
-- static slot coercion ahead of the slot roll, then the level roll on
-- every method but grass — land slots carry one fixed level read with
-- no roll — then the wild identity trace, with suppression evaluated
-- after level selection and lead abilities applied at their source
-- stages), while roamers borrow without selection, deterrence, or
-- generation draws. The prepared encounter is
-- retained until consumed once or restored without reroll. Consuming a
-- preparation ends the step-driven counting the native post-battle return
-- clears; map entries reset it through resetStepCounters. Rejected input
-- consumes no draws and no attempt identities. Wild capture metadata beyond
-- the map identity stays neutral unless the caller supplies a validated
-- origin record: without one generation records the lookup identity with
-- fixed neutral values. Pure domain module: no love dependency.

local EncounterSelection = require("libs.hgss.src.encounters.EncounterSelection")
local Errors = require("libs.errors.src.Errors")
local HgssEncounterRate = require("libs.hgss.src.encounters.HgssEncounterRate")
local Stats = require("libs.mons.src.gen4.Stats")

---@class HgssEncounterService
---@field private _catalog HgssEncounterCatalog
---@field private _factory WildMonFactory
---@field private _roamers HgssRoamerState?
---@field private _game string?
---@field private _typeOf fun(species: string, form: integer): string[]?
---@field private _nextAttemptId integer
---@field private _revision integer
---@field private _steps integer
---@field private _inhibitSteps integer
---@field private _reverseTurnSteps integer
---@field private _lastFacing string
---@field private _pending table<string, unknown>?
---@field private _pendingAttemptId integer?
---@field private _protected boolean
---@field private _lastConsumed integer?
local HgssEncounterService = {}
HgssEncounterService.__index = HgssEncounterService

HgssEncounterService.RULESET = "hgss-wild"
HgssEncounterService.FORMAT = "wild-single"
HgssEncounterService.SNAPSHOT_SCHEMA = "hgss-encounter-service-v2"

-- Every lead ability that shifts an encounter, shared with the field
-- adapter that maps live party abilities onto attempt facts.
HgssEncounterService.LEAD_ABILITIES = HgssEncounterRate.LEAD_ABILITIES

-- Neutral wild capture metadata, recorded because the typed attempt context
-- carries no clock, ball, or native terrain source.
local WILD_BALL = "POKE_BALL"
local WILD_TERRAIN = 0
local WILD_DATE = { year = 2000, month = 1, day = 1 }

local CHECKING_MOVEMENTS = { step = true, fish = true }
-- Field-move attempts (Rock Smash, Headbutt, Sweet Scent) consult their
-- tables like a checking movement but are not steps: no counter advances.
local FIELD_MOVE_MOVEMENTS = { field_move = true }
local IDLE_MOVEMENTS = { still = true, menu = true }
local FORCED_MOVEMENTS = { forced = true, forced_movement = true }
local SCRIPTED_MOVEMENTS = { scripted = true, scripted_movement = true }

local LEAD_ABILITIES = HgssEncounterService.LEAD_ABILITIES

-- The closed facing vocabulary behind the reverse-turn tracker. Absent
-- facts skip the tracker update.
local FACING = {
  north = true,
  south = true,
  east = true,
  west = true,
}

-- The closed locomotion vocabulary behind the native movement roll: the
-- avatar pace on a step attempt. Absent facts read as walking.
local LOCOMOTION = {
  walk = true,
  run = true,
  cycle = true,
  surf = true,
}

-- The closed live-music effect vocabulary the request modifiers carry.
-- Species replacement reads hoenn/sinnoh; the rate stage reads
-- march/lullaby; every other effect tunes neither slots nor rates.
local RADIO_EFFECTS = {
  none = true,
  march = true,
  lullaby = true,
  hoenn = true,
  sinnoh = true,
  unown = true,
  pokeflute = true,
}

-- Maps one live-music effect to the catalog radio identity: only regional
-- music replaces species; every other effect resolves silence.
---@param effect string
---@return string
local function catalogRadioForEffect(effect)
  if effect == "hoenn" or effect == "sinnoh" then
    return effect
  end
  return "none"
end

-- Maps one live-music effect to the rate-stage music fact: only march and
-- lullaby shift the staged rate; every other effect stages silence.
---@param effect string
---@return string
local function rateMusicForEffect(effect)
  if effect == "march" or effect == "lullaby" then
    return effect
  end
  return "none"
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

---@param args { catalog: HgssEncounterCatalog, wildFactory: WildMonFactory, roamers?: HgssRoamerState, game?: string, speciesTypes?: fun(species: string, form: integer): string[]? }
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
  -- The slot-type provider behind magnet-pull/static coercion. Absent
  -- slot types cannot narrow the ladder, so attempts without one skip
  -- the coercion draws and roll normally; production wires the live mon
  -- catalog.
  if args.speciesTypes ~= nil then
    assert(type(args.speciesTypes) == "function", "encounter service slot types arrive as a provider")
  end
  return setmetatable({
    _catalog = args.catalog,
    _factory = args.wildFactory,
    _roamers = args.roamers,
    _game = args.game,
    _typeOf = args.speciesTypes,
    _nextAttemptId = 1,
    _revision = 0,
    _steps = 0,
    _inhibitSteps = 0,
    _reverseTurnSteps = 0,
    -- The native turn tracker starts cleared, which reads as facing
    -- north against the direction vocabulary below.
    _lastFacing = "north",
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
  if type(modifiers.radio) == "string" and RADIO_EFFECTS[modifiers.radio] ~= true then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter radio effect " .. tostring(modifiers.radio) .. " is unknown", {
      radio = modifiers.radio,
    })
  end
  if modifiers.rod ~= nil and type(modifiers.rod) ~= "string" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter rod state must be a string", {})
  end
  -- The tile method behind a roaming step attempt: land or surf water,
  -- staging the tile's own table rate for the opportunity rolls. Only
  -- roamer attempts read it, and they must name it.
  if modifiers.tileMethod ~= nil and modifiers.tileMethod ~= "grass" and modifiers.tileMethod ~= "surf" then
    Errors.raise(
      "ENCOUNTER_INVALID_INPUT",
      "encounter tile method " .. tostring(modifiers.tileMethod) .. " is unknown",
      {
        tileMethod = modifiers.tileMethod,
      }
    )
  end
  if modifiers.locomotion ~= nil and LOCOMOTION[modifiers.locomotion] ~= true then
    Errors.raise(
      "ENCOUNTER_INVALID_INPUT",
      "encounter locomotion " .. tostring(modifiers.locomotion) .. " is unknown",
      {
        locomotion = modifiers.locomotion,
      }
    )
  end
  if modifiers.veryTallGrass ~= nil and type(modifiers.veryTallGrass) ~= "boolean" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter very-tall-grass state must be a boolean", {})
  end
  if modifiers.facing ~= nil and FACING[modifiers.facing] ~= true then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter facing " .. tostring(modifiers.facing) .. " is unknown", {
      facing = modifiers.facing,
    })
  end
  if modifiers.roamerKey ~= nil and type(modifiers.roamerKey) ~= "string" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter roamer state must be a string key", {})
  end
  if modifiers.sweetScent ~= nil and modifiers.sweetScent ~= true and modifiers.sweetScent ~= false then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter sweet scent state must be a boolean", {})
  end
  if
    modifiers.headbutt ~= nil and (type(modifiers.headbutt) ~= "table" or type(modifiers.headbutt.slots) ~= "table")
  then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter headbutt state must carry its slots", {})
  end
  local leadAbility = modifiers.leadAbility
  if leadAbility ~= nil and LEAD_ABILITIES[leadAbility] ~= true then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter lead ability " .. tostring(leadAbility) .. " is unknown", {
      leadAbility = leadAbility,
    })
  end
  -- The flute behind the rate stage: black halves, white boosts by half.
  -- Sweet-scented scripted checks never stage one; production facts stay
  -- absent until the flute item use owns them.
  if modifiers.flute ~= nil and modifiers.flute ~= "black" and modifiers.flute ~= "white" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter flute " .. tostring(modifiers.flute) .. " is unknown", {
      flute = modifiers.flute,
    })
  end
  -- Whether a follower walks behind the player for the fishing bite bonus.
  if modifiers.followActive ~= nil and modifiers.followActive ~= false and modifiers.followActive ~= true then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter follower state must be a boolean", {})
  end
  -- The lead gender behind cute-charm coercion. Only charming attempts
  -- read it; every other attempt leaves it absent.
  if modifiers.leadGender ~= nil and modifiers.leadGender ~= "male" and modifiers.leadGender ~= "female" then
    Errors.raise(
      "ENCOUNTER_INVALID_INPUT",
      "encounter lead gender " .. tostring(modifiers.leadGender) .. " is unknown",
      {
        leadGender = modifiers.leadGender,
      }
    )
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
    elseif modifiers.leadAbility == "cute_charm" then
      local leadGender = modifiers.leadGender
      if leadGender ~= "male" and leadGender ~= "female" then
        Errors.raise("ENCOUNTER_INVALID_INPUT", "cute charm coercion requires a lead gender", {
          leadGender = leadGender,
        })
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
  -- The field owns the repel counter and decrements it once per committed
  -- step; the service only advances its own step counter here and echoes
  -- the field-supplied repel value back.
  local repelOut = modifiers.repelSteps or 0
  if CHECKING_MOVEMENTS[context.movement] == true then
    self._steps = self._steps + 1
  end
  return { steps = self._steps, repelSteps = repelOut }
end

-- Tracks one facing observation for the reverse-turn boost: a step that
-- reverses direction (north against south, east against west) counts one
-- turn step, saturating like the native counter, and every observation
-- becomes the next comparison. Absent facings skip the update.
---@param facing string?
function HgssEncounterService:_updateTurnTracker(facing)
  if facing == nil then
    return
  end
  assert(type(facing) == "string", "the turn tracker reads the step facing")
  local last = self._lastFacing
  if
    (facing == "north" and last == "south")
    or (facing == "south" and last == "north")
    or (facing == "west" and last == "east")
    or (facing == "east" and last == "west")
  then
    if self._reverseTurnSteps < 0xFFFF then
      self._reverseTurnSteps = self._reverseTurnSteps + 1
    end
  end
  self._lastFacing = facing
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
---@param stream table<string, unknown>
---@param attemptId integer
---@return table<string, unknown>
function HgssEncounterService:_attemptRoamer(context, stream, attemptId)
  if self._roamers == nil then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer encounters require roamer state", {})
  end
  assert(self._roamers ~= nil, "roamer attempts borrow the stored identity")
  local modifiers = context.modifiers
  assert(type(modifiers) == "table", "roamer attempts read the modifier record")
  if type(modifiers.roamerKey) ~= "string" or modifiers.roamerKey == "" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer encounters require a roamer key", {})
  end
  local tileMethod = modifiers.tileMethod
  if tileMethod ~= "grass" and tileMethod ~= "surf" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "roamer encounters require a land or water tile method", {
      tileMethod = tileMethod,
    })
  end
  assert(tileMethod == "grass" or tileMethod == "surf", "roamer attempts stage their tile rate")
  -- The stored identity is borrowed before the rolls: borrowing draws
  -- nothing and selects nothing, so rejected roamer facts still consume
  -- no draws. Natively the roamer gate sits after the rolls, but its
  -- draws vanish with the explicit key, leaving the staged order
  -- (movement, opportunity, borrow) unobservable past the rolls.
  local record = self._roamers:prepareEncounter(modifiers.roamerKey)
  assert(type(record) == "table", "roamer attempts borrow the stored record")
  local missReason = self:_stageTileOpportunity(context, stream, tileMethod)
  if missReason ~= nil then
    return self:_miss(context, attemptId, missReason)
  end
  -- Deterrence never applies to roamers, and Sweet Scent never arms
  -- repel on the scripted path: only an armed repel against a lower
  -- roamer suppresses, with no suppression draw. The repel level is the
  -- first alive mon, falling back to the lead when no split is supplied.
  if modifiers.sweetScent ~= true then
    local repelSteps = modifiers.repelSteps
    if modifiers.repel == true and (repelSteps == nil or repelSteps > 0) then
      local mon = record.mon
      local met = type(mon) == "table" and mon.met or nil
      local roamerLevel = type(met) == "table" and met.level or nil
      if type(roamerLevel) ~= "number" or roamerLevel % 1 ~= 0 then
        Errors.raise("ENCOUNTER_INVALID_INPUT", "the borrowed roamer carries no level", {
          roamer = modifiers.roamerKey,
        })
      end
      assert(type(roamerLevel) == "number", "roamer repel reads the stored level")
      local repelLead = context.firstAlive or context.lead
      if repelLead ~= nil and roamerLevel < leadLevelOrRaise(repelLead) then
        return self:_miss(context, attemptId, "repel")
      end
    end
  end
  return self:_prepare(copyValue(record.mon), context, attemptId, "roamer")
end

-- Stages one tile opportunity for a step or field-move table attempt: the
-- tile lookup and its rate, then the native pair of opportunity rolls
-- (the movement roll for rated step checks on land and water, then the
-- table rate). An empty tile rate misses before any draw or tracker
-- update; Sweet Scent skips the whole roll stage, matching the native
-- scripted check that draws encounters without rolling. Returns the miss
-- reason, or nil plus the selected ordered slots once the opportunity
-- passes.
---@param self HgssEncounterService
---@param context table<string, unknown>
---@param stream table<string, unknown>
---@param tileMethod string land or water method staging the rolls
---@return string? miss reason, nil when the tile opportunity passes
---@return table<string, unknown>? selected ordered slots on a pass
function HgssEncounterService:_stageTileOpportunity(context, stream, tileMethod)
  local modifiers = context.modifiers
  assert(type(modifiers) == "table", "tile attempts read the modifier record")
  local method = context.method
  assert(type(method) == "string", "tile attempts name the attempt method")
  local missReason = tileMethod == "fish" and "no_bite" or "no_opportunity"
  local radioEffect = modifiers.radio or "none"
  assert(type(radioEffect) == "string", "tile attempts read the music effect")
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "tile attempts consult the labeled stream")
  local resolved = self._catalog:tableFor(context.mapId, {
    timeOfDay = context.timeOfDay,
    swarm = modifiers.swarm == true,
    radio = catalogRadioForEffect(radioEffect),
    game = self._game,
    rod = modifiers.rod,
  })
  local selected = EncounterSelection.selectTable(resolved, tileMethod, {
    timeOfDay = context.timeOfDay,
    rod = modifiers.rod,
  })
  if selected.rate == 0 then
    return missReason, nil
  end
  -- Sweet Scent always draws an encounter on a table with a rate. The
  -- scripted path never stages a rate: it reads the tile rate raw.
  if modifiers.sweetScent == true then
    return nil, selected.slots
  end
  -- Ability, flute, held-item, and fishing-friendship adjustments apply
  -- in native order; egg leads arrive with no ability, so the ability
  -- stage needs no egg gate of its own. Only land and water stage the
  -- flute and held item: fishing and rock smash stage the ability alone,
  -- matching the native paths. The roll site caps the result.
  local environment = context.environment
  assert(type(environment) == "table", "tile attempts read the environment record")
  local lead = context.lead
  local repelSource = context.firstAlive or lead
  local heldItem = nil
  if type(lead) == "table" then
    heldItem = lead.heldItem
  end
  local friendship = nil
  if type(repelSource) == "table" then
    friendship = repelSource.friendship
  end
  local isFishing = tileMethod == "fish"
  local stagesFluteAndHeld = tileMethod == "grass" or tileMethod == "surf"
  local rate = math.min(
    HgssEncounterRate.tableRate({
      baseRate = selected.rate,
      isFishing = isFishing,
      leadAbility = modifiers.leadAbility,
      weather = environment.weather,
      flute = stagesFluteAndHeld and modifiers.flute or nil,
      heldItem = stagesFluteAndHeld and heldItem or nil,
      friendship = friendship,
      followActive = modifiers.followActive == true,
    }),
    HgssEncounterRate.MAX_RATE
  )
  local draw = stream.nextU16
  local cause = { kind = "encounter", method = method }
  local movement = context.movement
  assert(type(movement) == "string", "tile attempts read the attempt movement")
  -- Step attempts on land and water take the native movement roll before
  -- the table rate: the avatar pace, the very-tall-grass bonus, the
  -- reverse-turn boost, and the live music stage the first of the two
  -- opportunity rolls. Field-move attempts and the other table methods
  -- consult only their own single roll below.
  if movement == "step" and (tileMethod == "grass" or tileMethod == "surf") then
    self:_updateTurnTracker(modifiers.facing)
    local movementRate = HgssEncounterRate.movementRate({
      locomotion = modifiers.locomotion or "walk",
      veryTallGrass = modifiers.veryTallGrass == true,
      reverseTurnSteps = self._reverseTurnSteps,
      radio = rateMusicForEffect(radioEffect),
    })
    if not EncounterSelection.trigger(movementRate, draw(stream, "movement", cause) % 100) then
      return missReason, nil
    end
  end
  if not EncounterSelection.trigger(rate, draw(stream, "opportunity", cause) % 100) then
    return missReason, nil
  end
  return nil, selected.slots
end

-- Resolves a magnet-pull/static coerced slot, or nil when the attempt
-- rolls normally. A matching lead draws the native 50% gate first: a
-- failed gate and an empty or total type match both fall through to the
-- normal slot roll (the gate draw stays consumed), while a passed gate
-- with a narrowing match draws the uniform pick over the ordered
-- matching indices. Without a type provider the gate cannot evaluate
-- and the attempt rolls normally with no coercion draws.
---@param slots table<string, unknown>[] ordered slots
---@param leadAbility string?
---@param stream table<string, unknown>
---@param cause table<string, unknown>
---@return integer? 1-based coerced slot index, or nil for a normal roll
function HgssEncounterService:_coercedSlot(slots, leadAbility, stream, cause)
  local target = nil
  if leadAbility == "magnet_pull" then
    target = "steel"
  elseif leadAbility == "static" then
    target = "electric"
  end
  if target == nil or self._typeOf == nil then
    return nil
  end
  assert(type(stream.nextU16) == "function", "coercion consults the labeled stream")
  local draw = stream.nextU16
  if draw(stream, "slot_coerce", cause) % 2 ~= 0 then
    return nil
  end
  local matches = EncounterSelection.matchingTypeSlots(slots, target, self._typeOf)
  if matches == nil then
    return nil
  end
  return matches[draw(stream, "slot_coerce_pick", cause) % #matches + 1]
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
  local missReason, slots = self:_stageTileOpportunity(context, stream, method)
  if missReason ~= nil then
    return self:_miss(context, attemptId, missReason)
  end
  assert(type(slots) == "table", "table attempts read their selected slots")
  assert(type(stream.nextU16) == "function", "table attempts consult the labeled stream")
  local draw = stream.nextU16
  local cause = { kind = "encounter", method = method }
  local leadAbility = modifiers.leadAbility
  -- Magnet pull and static coerce the slot before the normal roll, on
  -- every table path including sweet scent; a refused gate or a
  -- non-narrowing match falls through to the roll below.
  local slotIndex = self:_coercedSlot(slots, leadAbility, stream, cause)
  if slotIndex == nil then
    slotIndex = EncounterSelection.selectSlot(slots, draw(stream, "slot", cause) % 100)
  end
  local slot = slots[slotIndex]
  assert(type(slot) == "table", "slot selection resolves its ordered slot")
  -- Hustle, vital spirit, and pressure influence the level: on land
  -- they reselect the highest-level same-species slot half the time,
  -- while windowed methods roll the level first and pin the maximum on
  -- a failed check.
  local hustle = (leadAbility == "hustle" or leadAbility == "vital_spirit" or leadAbility == "pressure")
    and context.lead ~= nil
  -- Land tables carry a single fixed level per slot, read with no roll;
  -- the other methods roll inside the selected slot's window, pinned to
  -- the maximum when the slot-level check fails it.
  local level
  if method == "grass" then
    if hustle and draw(stream, "slot_level", cause) % 2 ~= 0 then
      slotIndex = EncounterSelection.highestSameSpeciesSlot(slots, slotIndex)
      slot = slots[slotIndex]
      assert(type(slot) == "table", "slot reselection resolves its ordered slot")
    end
    level = EncounterSelection.selectLandLevel(slot)
  else
    local windowRoll = draw(stream, "level", cause)
    if hustle and draw(stream, "slot_level", cause) % 2 ~= 0 then
      -- The pinned maximum reads like a fixed land level: no second roll.
      level = EncounterSelection.selectLandLevel(slot)
    else
      level = EncounterSelection.selectLevel(slot, windowRoll)
    end
  end
  -- Sweet Scent ignores both deterrence and repel: the native scripted
  -- check never arms either suppression flag. Repel arms only on the
  -- step path: fishing, rock smash, and field moves never arm it, so
  -- their facts read inert. The repel level is the first alive mon,
  -- falling back to the lead when no split is supplied.
  if modifiers.sweetScent ~= true then
    if (leadAbility == "intimidate" or leadAbility == "keen_eye") and context.lead ~= nil then
      local leadLevel = leadLevelOrRaise(context.lead)
      if leadLevel > 5 and level <= leadLevel - 5 then
        if draw(stream, "suppress", cause) % 2 == 0 then
          return self:_miss(context, attemptId, "suppressed")
        end
      end
    end
    local movement = context.movement
    assert(type(movement) == "string", "table attempts read the attempt movement")
    if movement == "step" and (method == "grass" or method == "surf") then
      local repelSteps = modifiers.repelSteps
      if modifiers.repel == true and (repelSteps == nil or repelSteps > 0) then
        local repelLead = context.firstAlive or context.lead
        if repelLead ~= nil and level < leadLevelOrRaise(repelLead) then
          return self:_miss(context, attemptId, "repel")
        end
      end
    end
  end
  local options = self:_wildOptions(context, attemptId)
  if leadAbility == "synchronize" then
    options.leadAbility = "synchronize"
    options.leadNature = modifiers.leadNature
  elseif leadAbility == "compoundeyes" then
    options.leadAbility = "compoundeyes"
  elseif leadAbility == "cute_charm" then
    options.leadAbility = "cute_charm"
    options.leadGender = modifiers.leadGender
  end
  local mon = self._factory:create(slot.species, level, stream, options)
  return self:_prepare(mon, context, attemptId, "triggered")
end

-- Headbutt draws from the struck tree's supplied slots with no opportunity
-- roll: the magnet-pull/static coercion or the slot roll, then the level
-- roll, then deterrence, then the wild identity. Repel never arms off the
-- step path.
---@param self HgssEncounterService
---@param context table<string, unknown>
---@param stream table<string, unknown>
---@param attemptId integer
---@return table<string, unknown>
function HgssEncounterService:_attemptHeadbutt(context, stream, attemptId)
  local modifiers = context.modifiers
  assert(type(modifiers) == "table", "headbutt attempts read the modifier record")
  local headbutt = modifiers.headbutt
  assert(type(headbutt) == "table", "headbutt attempts read their slots")
  local slots = headbutt.slots
  local draw = stream.nextU16
  local cause = { kind = "encounter", method = "headbutt" }
  local leadAbility = modifiers.leadAbility
  local slotIndex = self:_coercedSlot(slots, leadAbility, stream, cause)
  if slotIndex == nil then
    slotIndex = EncounterSelection.selectSlot(slots, draw(stream, "slot", cause) % 100)
  end
  local slot = slots[slotIndex]
  local windowRoll = draw(stream, "level", cause)
  -- Hustle, vital spirit, and pressure pin the rolled level to the
  -- slot maximum half the time, matching the native level roll.
  local level
  if
    (leadAbility == "hustle" or leadAbility == "vital_spirit" or leadAbility == "pressure")
    and context.lead ~= nil
    and draw(stream, "slot_level", cause) % 2 ~= 0
  then
    level = EncounterSelection.selectLandLevel(slot)
  else
    level = EncounterSelection.selectLevel(slot, windowRoll)
  end
  if (leadAbility == "intimidate" or leadAbility == "keen_eye") and context.lead ~= nil then
    local leadLevel = leadLevelOrRaise(context.lead)
    if leadLevel > 5 and level <= leadLevel - 5 then
      if draw(stream, "suppress", cause) % 2 == 0 then
        return self:_miss(context, attemptId, "suppressed")
      end
    end
  end
  local mon = self._factory:create(slot.species, level, stream, self:_wildOptions(context, attemptId))
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
  if CHECKING_MOVEMENTS[movement] ~= true and FIELD_MOVE_MOVEMENTS[movement] ~= true then
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
  if method == "headbutt" and checked.modifiers.headbutt ~= nil then
    checkLeadRequirements(checked)
    if self._protected then
      Errors.raise("ENCOUNTER_PENDING", "an encounter is already prepared", { attemptId = self._pendingAttemptId })
    end
    local attemptId = self._nextAttemptId
    self._nextAttemptId = attemptId + 1
    self._revision = self._revision + 1
    return self:_attemptHeadbutt(checked, stream, attemptId)
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
  -- Every committed ordinary step advances the entry grace, matching the
  -- native per-step counter: steps that never reach an attempt arrive
  -- through noteStep instead, so each step counts exactly once.
  if movement == "step" then
    if self._inhibitSteps < 0xFFFF then
      self._inhibitSteps = self._inhibitSteps + 1
    end
  end
  local attemptId = self._nextAttemptId
  self._nextAttemptId = attemptId + 1
  self._revision = self._revision + 1
  -- The entry grace refuses land, water, and roaming step checks before
  -- any table lookup or draw, matching the native early refusal.
  if
    movement == "step"
    and (method == "grass" or method == "surf" or method == "roamer")
    and self._inhibitSteps <= 3
  then
    return self:_miss(checked, attemptId, "grace")
  end
  if method == "roamer" then
    return self:_attemptRoamer(checked, stream, attemptId)
  end
  return self:_attemptTable(checked, stream, attemptId)
end

-- Advances the step-driven encounter counters for one committed ordinary
-- step that never reaches an attempt: the entry grace counts every
-- completed step while only encounter tiles test it. Never draws, never
-- prepares, never fails; steps that attempt arrive through attempt
-- instead, so each step counts exactly once.
function HgssEncounterService:noteStep()
  if self._inhibitSteps < 0xFFFF then
    self._inhibitSteps = self._inhibitSteps + 1
  end
end

-- Resets the step-driven encounter counters for a map entry or warp: the
-- native field system clears both counters whenever a warp completes. The
-- turn tracker's last facing persists across entries, matching the native
-- tracker that no reset site clears.
function HgssEncounterService:resetStepCounters()
  self._inhibitSteps = 0
  self._reverseTurnSteps = 0
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
    -- A launched encounter ends the step-driven counting the native
    -- post-battle return clears: with the field frozen until then, no
    -- attempt can observe the difference.
    self._inhibitSteps = 0
    self._reverseTurnSteps = 0
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
    inhibitSteps = self._inhibitSteps,
    reverseTurnSteps = self._reverseTurnSteps,
    lastFacing = self._lastFacing,
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
      and key ~= "inhibitSteps"
      and key ~= "reverseTurnSteps"
      and key ~= "lastFacing"
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
  if type(snapshot.inhibitSteps) ~= "number" or snapshot.inhibitSteps % 1 ~= 0 or snapshot.inhibitSteps < 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter snapshot carries an invalid inhibit counter", {})
  end
  if
    type(snapshot.reverseTurnSteps) ~= "number"
    or snapshot.reverseTurnSteps % 1 ~= 0
    or snapshot.reverseTurnSteps < 0
  then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter snapshot carries an invalid reverse-turn counter", {})
  end
  if
    snapshot.lastFacing ~= "north"
    and snapshot.lastFacing ~= "south"
    and snapshot.lastFacing ~= "east"
    and snapshot.lastFacing ~= "west"
  then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter snapshot carries an unknown facing", {})
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
  self._inhibitSteps = snapshot.inhibitSteps
  self._reverseTurnSteps = snapshot.reverseTurnSteps
  self._lastFacing = snapshot.lastFacing
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
