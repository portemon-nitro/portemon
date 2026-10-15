-- Broadcast-side projection of companion, field, and encounter facts for
-- the native radio programs: national-dex and key-item unlocks, the shared
-- daily outbreak identity, the field password variable, the heard flag,
-- and the scripted takeover state. Facts stay with their owners; this
-- module only projects them through the published boundaries. A missing
-- required fact is an attributed broadcast failure, never an invented
-- program answer.

local Errors = require("libs.errors.src.Errors")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

---@class RadioWorldContext
---@field private _state table<string, unknown>
---@field private _calendar table<string, unknown>
---@field private _events table<string, unknown>
---@field private _encounters table<string, unknown>
---@field private _dex table<string, unknown>
---@field private _bag table<string, unknown>
local RadioWorldContext = {}
RadioWorldContext.__index = RadioWorldContext

RadioWorldContext.ERROR = {
  FACT_UNAVAILABLE = "POKEGEAR_RADIO_FACT_UNAVAILABLE",
}

-- The shared password identity modulus: the broadcast voices the field
-- password-set variable modulo thirty, the same answer the field script
-- consults.
local PASSWORD_MODULO = 30

---@param fact string
local function failFact(fact)
  Errors.raise(RadioWorldContext.ERROR.FACT_UNAVAILABLE, "the radio broadcast needs " .. fact, { fact = fact })
end

---@param candidate unknown
---@param method string
---@return boolean
local function hasMethod(candidate, method)
  return type(candidate) == "table" and type(candidate[method]) == "function"
end

-- Projects the facts the broadcast programs read. Every dependency is
-- required: the companion state and its calendar, the field event store,
-- the validated encounter bucket, and the dex and bag readers.
---@param opts { state: table<string, unknown>, calendar: table<string, unknown>, eventState: table<string, unknown>, encounters: table<string, unknown>, dex: table<string, unknown>, bag: table<string, unknown> }
---@return RadioWorldContext
function RadioWorldContext.new(opts)
  assert(type(opts) == "table", "the broadcast projection needs its fact owners")
  if not hasMethod(opts.state, "readDailyIdentity") then
    failFact("the companion daily identity")
  end
  if type(opts.calendar) ~= "table" then
    failFact("the companion calendar")
  end
  if
    not hasMethod(opts.eventState, "getVar")
    or not hasMethod(opts.eventState, "setFlag")
    or not hasMethod(opts.eventState, "isFlagSet")
  then
    failFact("the field event store")
  end
  if type(opts.encounters) ~= "table" or type(opts.encounters.swarm) ~= "boolean" then
    failFact("the encounter swarm fact")
  end
  if not hasMethod(opts.dex, "hasNationalDex") then
    failFact("the national-dex fact")
  end
  if not hasMethod(opts.bag, "has") then
    failFact("the bag inventory fact")
  end
  return setmetatable({
    _state = opts.state,
    _calendar = opts.calendar,
    _events = opts.eventState,
    _encounters = opts.encounters,
    _dex = opts.dex,
    _bag = opts.bag,
  }, RadioWorldContext)
end

-- Records one civil sample at a broadcast start boundary so the shared
-- daily identity steps exactly when the field calendar says a day passed.
-- Mid-broadcast samples never arrive here: a half-printed show keeps the
-- identity it started with.
---@param sample table<string, integer>
---@return table<string, unknown>
function RadioWorldContext:observeCivilMoment(sample)
  local calendar = self._calendar
  assert(type(calendar) == "table", "the broadcast projection keeps its calendar")
  local observe = calendar.observeField
  assert(type(observe) == "function", "the companion calendar observes civil samples")
  return observe(calendar, sample)
end

-- The shared daily outbreak fact: the active flag stays with the encounter
-- owner while the seed is the one companion outbreak seed, never a
-- private broadcast reroll.
---@return { active: boolean, seed: integer }
function RadioWorldContext:dailySwarm()
  local encounters = self._encounters
  assert(type(encounters) == "table", "the broadcast projection keeps its encounter facts")
  local state = self._state
  assert(type(state) == "table", "the broadcast projection keeps its companion state")
  local read = state.readDailyIdentity
  assert(type(read) == "function", "the companion state reads its daily identity")
  local identity = read(state)
  assert(type(identity) == "table", "the daily identity reads as a record")
  assert(type(identity.outbreakSeed) == "number", "the shared outbreak seed stays numeric")
  return { active = encounters.swarm == true, seed = identity.outbreakSeed }
end

-- Pure shared swarm lookup: one outbreak seed resolves to one swarm
-- identity through fixed table arithmetic. Both the broadcast projection
-- and the field encounter composition resolve through this function so the
-- announced outbreak and the actual encounters agree.
---@param seed integer
---@return { species: integer, landmark: integer }
function RadioWorldContext.swarmInfoFromSeed(seed)
  assert(type(seed) == "number" and seed % 1 == 0 and seed >= 0, "swarm lookups resolve an unsigned outbreak seed")
  return { species = (seed % 493) + 1, landmark = (math.floor(seed / 493) % 24) + 1 }
end

-- The broadcast password index: the field password-set variable modulo
-- thirty, the same identity the field script consults. Listening never
-- writes it.
---@return integer
function RadioWorldContext:buenaPassword()
  local events = self._events
  assert(type(events) == "table", "the broadcast projection keeps its event store")
  local getVar = events.getVar
  assert(type(getVar) == "function", "the event store reads variables")
  local variable = FieldScriptSymbols.variablesByName.VAR_BUENAS_PASSWORD_SET
  assert(type(variable) == "number", "the password variable carries its field identity")
  local password = getVar(events, variable) % PASSWORD_MODULO
  assert(password >= 0 and password < PASSWORD_MODULO, "the broadcast password stays a thirty-entry index")
  return password
end

-- Commits the heard flag once the password show advances past its
-- introduction. Merely tuning or reading the title never calls this path.
function RadioWorldContext:markBuenaHeard()
  local events = self._events
  assert(type(events) == "table", "the broadcast projection keeps its event store")
  local setFlag = events.setFlag
  assert(type(setFlag) == "function", "the event store writes flags")
  local flag = FieldScriptSymbols.flagsByName.FLAG_DAILY_HEARD_BUENAS_PASSWORD
  assert(type(flag) == "number", "the heard flag carries its field identity")
  setFlag(events, flag)
end

-- True once the password show committed its heard flag through this
-- projection.
---@return boolean
function RadioWorldContext:hasHeardBuena()
  local events = self._events
  assert(type(events) == "table", "the broadcast projection keeps its event store")
  local isFlagSet = events.isFlagSet
  assert(type(isFlagSet) == "function", "the event store reads flags")
  local flag = FieldScriptSymbols.flagsByName.FLAG_DAILY_HEARD_BUENAS_PASSWORD
  assert(type(flag) == "number", "the heard flag carries its field identity")
  return isFlagSet(events, flag) == true
end

-- True when the player profile owns the national dex behind the midweek
-- music gates.
---@return boolean
function RadioWorldContext:hasNationalDex()
  local dex = self._dex
  assert(type(dex) == "table", "the broadcast projection keeps its dex reader")
  local read = dex.hasNationalDex
  assert(type(read) == "function", "the dex reader answers the national-dex fact")
  return read(dex) == true
end

-- True when the bag owns at least the requested quantity of the semantic
-- item key, covering the card item behind the password reply and the
-- Sunday card selection.
---@param itemKey string
---@param quantity integer?
---@return boolean
function RadioWorldContext:hasItem(itemKey, quantity)
  assert(type(itemKey) == "string" and itemKey ~= "", "bag lookups name a semantic item key")
  local bag = self._bag
  assert(type(bag) == "table", "the broadcast projection keeps its bag reader")
  local read = bag.has
  assert(type(read) == "function", "the bag reader answers inventory facts")
  return read(bag, itemKey, quantity or 1) == true
end

-- True while the scripted takeover story state is active, selecting the
-- takeover broadcast variant. An unset flag reads clear: the ordinary
-- broadcast plays until the field sets the story fact.
---@return boolean
function RadioWorldContext:rocketTakeover()
  local events = self._events
  assert(type(events) == "table", "the broadcast projection keeps its event store")
  local isFlagSet = events.isFlagSet
  assert(type(isFlagSet) == "function", "the event store reads flags")
  local flag = FieldScriptSymbols.flagsByName.FLAG_ROCKET_TAKEOVER_ACTIVE
  assert(type(flag) == "number", "the takeover flag carries its field identity")
  return isFlagSet(events, flag) == true
end

return RadioWorldContext
