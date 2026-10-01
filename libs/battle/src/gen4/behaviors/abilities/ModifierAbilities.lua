-- Modifier ability families: stat, damage, accuracy, and immunity
-- adjustments applied at typed arithmetic checkpoints. Handlers fire only
-- when their trigger context is present -- a matching move type, a
-- computed stat, an accuracy roll, or a flagged interaction -- and stay
-- silent otherwise, so an inapplicable checkpoint never looks like a
-- missing binding. Immunity suppression scoped to a single hit resolves
-- through the hit record, never through battle state.

local ModifierAbilities = {}

---@param instance table<string, unknown> dispatched effect instance under handling
---@return integer? holder combatant owning the instance
local function holderOf(instance)
  local scope = instance.scope
  if type(scope) ~= "table" then
    return nil
  end
  local combatant = (scope --[[@as table<string, unknown>]]).combatant
  if type(combatant) ~= "number" then
    return nil
  end
  return combatant
end

---@param context table<string, unknown> hit context under inspection
---@return boolean true when a breaking ability opens immunities for the hit
local function moldBroken(context)
  local hit = context.hit
  if type(hit) ~= "table" then
    return false
  end
  return (hit --[[@as table<string, unknown>]]).attackerAbility == "MOLD_BREAKER"
end

---@param context table<string, unknown> pre-hit context under inspection
---@return unknown move type from the checkpoint or its hit record
local function resolveMoveType(context)
  if context.moveType ~= nil then
    return context.moveType
  end
  local hit = context.hit
  if type(hit) ~= "table" then
    return nil
  end
  return (hit --[[@as table<string, unknown>]]).moveType
end

---@param context table<string, unknown> checkpoint context under inspection
---@param holder integer? holder combatant under inspection
---@return boolean true when the holder sits below a third of its maximum
local function pinched(context, holder)
  if holder == nil then
    return true
  end
  local health = context.health
  local limits = context.maxHealth
  if type(health) ~= "table" or type(limits) ~= "table" then
    return true
  end
  local hp = (health --[[@as table<integer, integer>]])[holder]
  local maxHp = (limits --[[@as table<integer, integer>]])[holder]
  if type(hp) ~= "number" or type(maxHp) ~= "number" then
    return true
  end
  return hp * 3 <= maxHp
end

local ABSORB_TYPE = {
  VOLT_ABSORB = "electric",
  WATER_ABSORB = "water",
  FLASH_FIRE = "fire",
  MOTOR_DRIVE = "electric",
  LIGHTNINGROD = "electric",
  STORM_DRAIN = "water",
}

local HALVED_TYPE = {
  THICK_FAT = { fire = true, ice = true },
  HEATPROOF = { fire = true },
}

local PINCH_TYPE = {
  OVERGROW = "grass",
  BLAZE = "fire",
  TORRENT = "water",
  SWARM = "bug",
}

local WEATHER_SPEED = {
  CHLOROPHYLL = "sun",
  SWIFT_SWIM = "rain",
}

local BOOST_STAT = {
  HUGE_POWER = { stats = { attack = true } },
  PURE_POWER = { stats = { attack = true } },
  GUTS = { stats = { attack = true }, needsStatus = true },
  MARVEL_SCALE = { stats = { defense = true }, needsStatus = true },
  QUICK_FEET = { stats = { speed = true }, needsStatus = true },
  PLUS = { stats = { specialAttack = true } },
  MINUS = { stats = { specialAttack = true } },
  HUSTLE = { stats = { attack = true }, split = "physical" },
  FLOWER_GIFT = { stats = { attack = true, specialDefense = true }, weather = "sun" },
}

local POWER_FLAG = {
  ADAPTABILITY = "stab",
  IRON_FIST = "punchMove",
  RECKLESS = "recoilMove",
  TINTED_LENS = "resisted",
  RIVALRY = "opponentGender",
  SERENE_GRACE = "secondary",
  SKILL_LINK = "multiHit",
  TECHNICIAN = "weakMove",
  STENCH = "damaging",
}

local ACCURACY_OUTCOME = {
  COMPOUNDEYES = "boosted",
  NO_GUARD = "certain",
  SUPER_LUCK = "critical",
}

local EVASION_WEATHER = {
  SAND_VEIL = "sand",
  SNOW_CLOAK = "hail",
}

local CRIT_GUARD = {
  BATTLE_ARMOR = true,
  SHELL_ARMOR = true,
}

--- Ground immunity: silent against other types and against hits opened
--- by a breaking ability.
---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> pre-hit context under handling
---@return table<string, unknown>? immunity announcement, or nil when inapplicable
local function levitate(instance, context)
  if resolveMoveType(context) ~= "ground" then
    return nil
  end
  if moldBroken(context) then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance) }
end

--- Hit-scoped immunity suppression: marks only hits the breaker itself
--- throws, so the following ordinary hit still meets the immunity.
---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> pre-hit context under handling
---@return table<string, unknown>? suppression marker, or nil when inapplicable
local function moldBreaker(instance, context)
  local hit = context.hit
  if type(hit) ~= "table" then
    return nil
  end
  if
    (hit --[[@as table<string, unknown>]]).attackerAbility ~= instance.key
  then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance) }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> pre-hit context under handling
---@return table<string, unknown>? absorption announcement, or nil when inapplicable
local function absorbMove(instance, context)
  if resolveMoveType(context) ~= ABSORB_TYPE[instance.key] then
    return nil
  end
  if moldBroken(context) then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), absorbed = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> residual context under handling
---@return table<string, unknown>? dry-skin response, or nil when inapplicable
local function drySkin(instance, context)
  if context.moveType == "water" then
    if moldBroken(context) then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), absorbed = true }
  end
  if context.moveType ~= nil then
    return nil
  end
  if context.weather == "rain" then
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), recovered = true }
  end
  if context.weather == "sun" then
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), harmed = true }
  end
  return nil
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> pre-hit context under handling
---@return table<string, unknown>? immunity announcement, or nil when inapplicable
local function wonderGuard(instance, context)
  local moveType = resolveMoveType(context)
  if moveType == nil or moveType == "unknown" then
    return nil
  end
  if context.superEffective == true then
    return nil
  end
  if moldBroken(context) then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance) }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> pre-hit context under handling
---@return table<string, unknown>? immunity announcement, or nil when inapplicable
local function soundproof(instance, context)
  if context.soundMove ~= true then
    return nil
  end
  if moldBroken(context) then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance) }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> pre-hit context under handling
---@return table<string, unknown>? bypass announcement, or nil when inapplicable
local function scrappy(instance, context)
  local moveType = resolveMoveType(context)
  if moveType ~= "normal" and moveType ~= "fighting" then
    return nil
  end
  if context.ghostTarget ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), bypass = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? reduction announcement, or nil when inapplicable
local function halveDamage(instance, context)
  local halved = HALVED_TYPE[instance.key]
  if type(halved) ~= "table" then
    return nil
  end
  if
    (halved --[[@as table<string, boolean>]])[context.moveType] ~= true
  then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), damage = "halved" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? reduction announcement, or nil when inapplicable
local function reduceSuperEffective(instance, context)
  if context.superEffective ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), damage = "reduced" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> stat checkpoint context under handling
---@return table<string, unknown>? boost announcement, or nil when inapplicable
local function boostStat(instance, context)
  local rule = BOOST_STAT[instance.key]
  if type(rule) ~= "table" then
    return nil
  end
  local shaped = rule --[[@as table<string, unknown>]]
  local stats = shaped.stats --[[@as table<string, boolean>]]
  if type(context.stat) ~= "string" or stats[context.stat] ~= true then
    return nil
  end
  if shaped.needsStatus == true and context.statused ~= true then
    return nil
  end
  if shaped.split ~= nil and context.split ~= shaped.split then
    return nil
  end
  if shaped.weather ~= nil and context.weather ~= shaped.weather then
    return nil
  end
  return {
    kind = "trigger",
    key = instance.key,
    combatant = holderOf(instance),
    stat = context.stat,
    stages = "boosted",
  }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? boost announcement, or nil when inapplicable
local function pinchPower(instance, context)
  if context.moveType ~= PINCH_TYPE[instance.key] then
    return nil
  end
  if not pinched(context, holderOf(instance)) then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), power = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> stat checkpoint context under handling
---@return table<string, unknown>? weather response, or nil when inapplicable
local function weatherSpeed(instance, context)
  if context.weather ~= WEATHER_SPEED[instance.key] then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), stat = "speed", stages = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> stat checkpoint context under handling
---@return table<string, unknown>? solar response, or nil when inapplicable
local function solarPower(instance, context)
  if context.weather ~= "sun" then
    return nil
  end
  if context.stat ~= "specialAttack" then
    return nil
  end
  return {
    kind = "trigger",
    key = instance.key,
    combatant = holderOf(instance),
    stat = "specialAttack",
    stages = "boosted",
  }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? boost announcement, or nil when inapplicable
local function powerOnFlag(instance, context)
  local flag = POWER_FLAG[instance.key]
  if flag == nil then
    return nil
  end
  if context[flag] == nil or context[flag] == false then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), power = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> accuracy context under handling
---@return table<string, unknown>? accuracy announcement, or nil when inapplicable
local function accuracyCheck(instance, context)
  local outcome = ACCURACY_OUTCOME[instance.key]
  if outcome == nil then
    return nil
  end
  if context.accuracyCheck ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), accuracy = outcome }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> accuracy context under handling
---@return table<string, unknown>? evasion announcement, or nil when inapplicable
local function weatherEvasion(instance, context)
  if context.accuracyCheck ~= true then
    return nil
  end
  if context.weather ~= EVASION_WEATHER[instance.key] then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), evasion = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> accuracy context under handling
---@return table<string, unknown>? evasion announcement, or nil when inapplicable
local function tangledFeet(instance, context)
  if context.accuracyCheck ~= true then
    return nil
  end
  if context.confusedAttacker ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), evasion = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? guard announcement, or nil when inapplicable
local function critGuard(instance, context)
  if CRIT_GUARD[instance.key] ~= true then
    return nil
  end
  if context.critical ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), critical = "negated" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? endurance announcement, or nil when inapplicable
local function sturdy(instance, context)
  if context.lethal ~= true then
    return nil
  end
  local holder = holderOf(instance)
  local health = context.health
  local limits = context.maxHealth
  if type(health) ~= "table" or type(limits) ~= "table" then
    return nil
  end
  local hp = (health --[[@as table<integer, integer>]])[
    holder --[[@as integer]]
  ]
  local maxHp = (limits --[[@as table<integer, integer>]])[
    holder --[[@as integer]]
  ]
  if type(hp) ~= "number" or type(maxHp) ~= "number" or hp ~= maxHp then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holder, endured = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? boost announcement, or nil when inapplicable
local function sniper(instance, context)
  if context.critical ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), critical = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> stat checkpoint context under handling
---@return table<string, unknown>? prevention announcement, or nil when inapplicable
local function preventStatLoss(instance, context)
  if context.statDrop ~= true then
    return nil
  end
  if instance.key == "HYPER_CUTTER" and context.stat ~= nil and context.stat ~= "attack" then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), prevented = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> stat checkpoint context under handling
---@return table<string, unknown>? stage announcement, or nil when inapplicable
local function stageInteraction(instance, context)
  if context.statStage ~= true then
    return nil
  end
  if instance.key == "SIMPLE" then
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), stages = "doubled" }
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), stages = "ignored" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> move resolution context under handling
---@return table<string, unknown>? normalization announcement, or nil when inapplicable
local function normalize(instance, context)
  if context.moveType == nil then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), moveType = "normal" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? prevention announcement, or nil when inapplicable
local function magicGuard(instance, context)
  if context.indirectDamage ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), prevented = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? prevention announcement, or nil when inapplicable
local function rockHead(instance, context)
  if context.recoil ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), prevented = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> accuracy context under handling
---@return table<string, unknown>? prevention announcement, or nil when inapplicable
local function keenEye(instance, context)
  if context.accuracyDrop ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), prevented = true }
end

--- Binds the stat, damage, accuracy, and immunity handlers into the owner table.
---@param owned table<string, fun(instance: table<string, unknown>, context: table<string, unknown>): table<string, unknown>?> handler owner receiving the family bindings
function ModifierAbilities.register(owned)
  assert(type(owned) == "table", "modifier abilities register into their owner table")
  owned.LEVITATE = levitate
  owned.MOLD_BREAKER = moldBreaker
  owned.WONDER_GUARD = wonderGuard
  owned.SOUNDPROOF = soundproof
  owned.SCRAPPY = scrappy
  owned.DRY_SKIN = drySkin
  owned.NORMALIZE = normalize
  owned.MAGIC_GUARD = magicGuard
  owned.ROCK_HEAD = rockHead
  owned.KEEN_EYE = keenEye
  owned.STURDY = sturdy
  owned.SNIPER = sniper
  owned.TANGLED_FEET = tangledFeet
  owned.SOLAR_POWER = solarPower
  for key in pairs(ABSORB_TYPE) do
    owned[key] = absorbMove
  end
  for key in pairs(HALVED_TYPE) do
    owned[key] = halveDamage
  end
  for key in pairs(PINCH_TYPE) do
    owned[key] = pinchPower
  end
  for key in pairs(WEATHER_SPEED) do
    owned[key] = weatherSpeed
  end
  for key in pairs(BOOST_STAT) do
    owned[key] = boostStat
  end
  for key in pairs(POWER_FLAG) do
    owned[key] = powerOnFlag
  end
  for key in pairs(ACCURACY_OUTCOME) do
    owned[key] = accuracyCheck
  end
  for key in pairs(EVASION_WEATHER) do
    owned[key] = weatherEvasion
  end
  for key in pairs(CRIT_GUARD) do
    owned[key] = critGuard
  end
  owned.FILTER = reduceSuperEffective
  owned.SOLID_ROCK = reduceSuperEffective
  owned.CLEAR_BODY = preventStatLoss
  owned.WHITE_SMOKE = preventStatLoss
  owned.HYPER_CUTTER = preventStatLoss
  owned.SIMPLE = stageInteraction
  owned.UNAWARE = stageInteraction
end

return ModifierAbilities
