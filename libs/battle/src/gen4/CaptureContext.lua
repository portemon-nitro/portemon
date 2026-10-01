-- Typed capture environment for thrown balls. Each native ball reads only
-- its own source facts at exact thresholds, so staging rejects unknown
-- balls and names the missing fact instead of guessing cave, day, or
-- gender behavior from presentation scenery. Native anchor:
-- BattleSystem_CalculateBallShakes (battle command flow): ball multipliers
-- stay tenths-fixed, apricorn bonuses adjust the rate, and the shake chain
-- floors two hardware square roots. The moon bonus covers the fourteen
-- native moon-stone species from the overlay table; scenery backdrops never
-- count as terrain.

local Errors = require("libs.errors.src.Errors")

---@class CaptureContext
---@field ball string staged ball key
---@field mode string staged capture mode naming the throw
---@field target table<string, unknown> staged target facts the ball reads
---@field env table<string, unknown> staged encounter facts the ball reads
local CaptureContext = {}

--- Balls the throw path recognizes, keyed by upper-snake item key. Plain
--- entries need no extra facts; conditional entries name exactly the facts
--- their source rule reads.
local KNOWN_BALLS = {
  POKE_BALL = true,
  GREAT_BALL = true,
  ULTRA_BALL = true,
  SAFARI_BALL = true,
  SPORT_BALL = true,
  MASTER_BALL = true,
  PARK_BALL = true,
  NET_BALL = true,
  DIVE_BALL = true,
  NEST_BALL = true,
  REPEAT_BALL = true,
  TIMER_BALL = true,
  DUSK_BALL = true,
  QUICK_BALL = true,
  FAST_BALL = true,
  LEVEL_BALL = true,
  LURE_BALL = true,
  HEAVY_BALL = true,
  LOVE_BALL = true,
  MOON_BALL = true,
  PREMIER_BALL = true,
  LUXURY_BALL = true,
  HEAL_BALL = true,
  FRIEND_BALL = true,
  CHERISH_BALL = true,
}

--- Balls that land without staging odds or spending draws.
local GUARANTEED_BALLS = {
  MASTER_BALL = true,
  PARK_BALL = true,
}

--- Native moon-stone line from the overlay species table: every member of
--- the Nidoran, Clefairy, Jigglypuff, and Skitty lines.
local MOON_LINE = {
  NIDORAN_F = true,
  NIDORINA = true,
  NIDOQUEEN = true,
  NIDORAN_M = true,
  NIDORINO = true,
  NIDOKING = true,
  CLEFFA = true,
  CLEFAIRY = true,
  CLEFABLE = true,
  IGGLYBUFF = true,
  JIGGLYPUFF = true,
  WIGGLYTUFF = true,
  SKITTY = true,
  DELCATTY = true,
}

--- Extra target facts each conditional ball reads, beyond the shared
--- catch-rate, health, and status facts.
local BALL_TARGET_FACTS = {
  NET_BALL = { "types" },
  NEST_BALL = { "level" },
  FAST_BALL = { "baseSpeed" },
  LEVEL_BALL = { "level" },
  HEAVY_BALL = { "weight" },
  LOVE_BALL = { "species", "gender" },
  MOON_BALL = { "species" },
}

--- Extra encounter facts each conditional ball reads. Presence matters, not
--- truthiness: an explicit false still stages.
local BALL_ENV_FACTS = {
  DIVE_BALL = { "method" },
  REPEAT_BALL = { "pokedexCaught" },
  TIMER_BALL = { "turns" },
  QUICK_BALL = { "turns" },
  DUSK_BALL = { "timeOfDay", "inCave" },
  LEVEL_BALL = { "attackerLevel" },
  LURE_BALL = { "fished" },
  LOVE_BALL = { "attackerSpecies", "attackerGender" },
}

---@param code string refusal code under report
---@param message string human-readable reason under report
---@param context table<string, unknown>? structured blame under report
---@return Errors.Error typed failure carrying the refusal code
local function failure(code, message, context)
  return Errors.new(code, message, context or { code = code })
end

--- Reports whether the throw path recognizes the ball key.
---@param ball unknown candidate ball key under inspection
---@return boolean true when the ball has a staged rule
function CaptureContext.isBall(ball)
  return type(ball) == "string" and KNOWN_BALLS[ball] == true
end

--- Reports whether the ball lands without staging odds or spending draws.
---@param ball unknown candidate ball key under inspection
---@return boolean true for throws that always land
function CaptureContext.isGuaranteed(ball)
  return type(ball) == "string" and GUARANTEED_BALLS[ball] == true
end

--- Reports whether the species belongs to the native moon-stone line.
---@param species unknown candidate species key under inspection
---@return boolean true for listed species, false for anything else
function CaptureContext.isMoonLine(species)
  return type(species) == "string" and MOON_LINE[species] == true
end

---@param facts table<string, unknown> candidate fact record under inspection
---@param field string required fact name under inspection
---@return boolean true when a numeric fact is present
local function hasNumber(facts, field)
  return type(facts[field]) == "number"
end

---@param facts table<string, unknown> candidate fact record under inspection
---@param field string required fact name under inspection
---@return boolean true when a text fact is present
local function hasText(facts, field)
  return type(facts[field]) == "string"
end

---@param facts table<string, unknown> candidate fact record under inspection
---@param field string required fact name under inspection
---@return boolean true when a yes-or-no fact is explicitly present
local function hasFlag(facts, field)
  return type(facts[field]) == "boolean"
end

---@param facts table<string, unknown> candidate fact record under inspection
---@param field string required fact name under inspection
---@return boolean true when a type list carries at least one type
local function hasTypes(facts, field)
  local types = facts[field]
  if type(types) ~= "table" then
    return false
  end
  return #types --[[@as string[] ]] >= 1
end

---@param facts table<string, unknown> candidate fact record under staging
---@param field string required fact name under staging
---@return string? missing fact name, nil when the fact stages
local function checkFact(facts, field)
  local present = false
  if field == "types" then
    present = hasTypes(facts, field)
  elseif field == "pokedexCaught" or field == "fished" or field == "inCave" then
    present = hasFlag(facts, field)
  elseif
    field == "status"
    or field == "species"
    or field == "gender"
    or field == "method"
    or field == "timeOfDay"
    or field == "attackerSpecies"
    or field == "attackerGender"
  then
    present = hasText(facts, field)
  else
    present = hasNumber(facts, field)
  end
  if not present then
    return field
  end
  return nil
end

---@param source table<string, unknown> staged facts under copy
---@return table<string, unknown> detached copy sharing no mutable state
local function copyFacts(source)
  local copied = {} ---@type table<string, unknown>
  for key, value in pairs(source) do
    if key == "types" and type(value) == "table" then
      local types = {} ---@type string[]
      for _, entry in
        ipairs(value --[[@as string[] ]])
      do
        types[#types + 1] = entry
      end
      copied[key] = types
    elseif type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
      copied[key] = value
    end
  end
  return copied
end

--- Stages exactly the facts the ball reads. Unknown balls fail before
--- anything is staged; conditional balls name their first missing fact.
---@param ball string ball key under staging
---@param target table<string, unknown>? target facts under staging
---@param env table<string, unknown>? encounter facts under staging
---@return CaptureContext detached context carrying the staged facts
function CaptureContext.forBall(ball, target, env)
  if not CaptureContext.isBall(ball) then
    error(failure("unknown_ball", "the throw names no recognized ball", { code = "unknown_ball", ball = ball }))
  end
  local targetFacts = target or {}
  if type(targetFacts) ~= "table" then
    error(failure("missing_fact", "the throw carries no target facts", { code = "missing_fact", ball = ball }))
  end
  local envFacts = env or {}
  if type(envFacts) ~= "table" then
    error(failure("missing_fact", "the throw carries no encounter facts", { code = "missing_fact", ball = ball }))
  end
  if not CaptureContext.isGuaranteed(ball) then
    for _, field in ipairs({ "catchRate", "maxHp", "hp", "status" }) do
      local missing = checkFact(targetFacts, field)
      if missing ~= nil then
        error(
          failure(
            "missing_fact",
            "the " .. ball .. " throw needs " .. missing,
            { code = "missing_fact", ball = ball, missing = missing }
          )
        )
      end
    end
  end
  for _, field in ipairs(BALL_TARGET_FACTS[ball] or {}) do
    local missing = checkFact(targetFacts, field)
    if missing ~= nil then
      error(
        failure(
          "missing_fact",
          "the " .. ball .. " throw needs " .. missing,
          { code = "missing_fact", ball = ball, missing = missing }
        )
      )
    end
  end
  for _, field in ipairs(BALL_ENV_FACTS[ball] or {}) do
    local missing = checkFact(envFacts, field)
    if missing ~= nil then
      error(
        failure(
          "missing_fact",
          "the " .. ball .. " throw needs " .. missing,
          { code = "missing_fact", ball = ball, missing = missing }
        )
      )
    end
  end
  local stagedEnv = copyFacts(envFacts)
  if type(stagedEnv.mode) ~= "string" then
    stagedEnv.mode = "wild"
  end
  return { ball = ball, mode = stagedEnv.mode, target = copyFacts(targetFacts), env = stagedEnv }
end

--- Validates a staged context at its owner. Built contexts validate
--- cleanly; anything else names its failure.
---@param context unknown candidate capture context under validation
---@return boolean true when the context carries a staged ball and facts
function CaptureContext.validate(context)
  if type(context) ~= "table" then
    error(failure("invalid_context", "the capture context is missing", { code = "invalid_context" }))
  end
  local staged = context --[[@as CaptureContext]]
  if not CaptureContext.isBall(staged.ball) then
    error(failure("invalid_context", "the capture context names no staged ball", { code = "invalid_context" }))
  end
  if type(staged.target) ~= "table" or type(staged.env) ~= "table" or type(staged.env.mode) ~= "string" then
    error(failure("invalid_context", "the capture context carries no staged facts", { code = "invalid_context" }))
  end
  return true
end

return CaptureContext
