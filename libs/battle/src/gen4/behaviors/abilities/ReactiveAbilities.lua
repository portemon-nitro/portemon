-- Reactive ability families: before-action, status, hit, and turn
-- responses with native precedence preserved per handler. Contact
-- responders fire on contact hits, pressure charges once per distinct
-- targeting foe on both ordinary and called paths, and leaving handlers
-- clean the canonical condition on the way out while ordinary
-- replacement keeps it. Handlers stay silent when their trigger context
-- is absent, so inapplicable responses never look unimplemented.

local Status = require("libs.battle.src.gen4.Status")

local ReactiveAbilities = {}

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

local CONTACT_RESPONSE = {
  STATIC = true,
  EFFECT_SPORE = true,
  POISON_POINT = true,
  FLAME_BODY = true,
  ROUGH_SKIN = true,
  CUTE_CHARM = true,
}

local STATUS_PREVENTION = {
  LIMBER = "paralysis",
  IMMUNITY = "poison",
  INSOMNIA = "sleep",
  VITAL_SPIRIT = "sleep",
  MAGMA_ARMOR = "freeze",
  WATER_VEIL = "burn",
  OWN_TEMPO = "confusion",
  INNER_FOCUS = "flinch",
  OBLIVIOUS = "infatuation",
}

local RESIDUAL_HEAL = {
  POISON_HEAL = "poison",
  RAIN_DISH = "rain",
  ICE_BODY = "hail",
}

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> post-hit context under handling
---@return table<string, unknown>? contact announcement, or nil without contact
local function contactResponse(instance, context)
  if CONTACT_RESPONSE[instance.key] ~= true then
    return nil
  end
  if context.contact ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance) }
end

--- Charges one extra unit per distinct pressuring foe targeted by the
--- use, whether the move spreads across several targets or arrives
--- through a called path. Uses avoiding every pressuring foe, and the
--- holder's own use, charge nothing.
---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> pre-action context under handling
---@return table<string, unknown>? pressure announcement, or nil when unpressured
local function pressure(instance, context)
  local moveUse = context.moveUse
  if type(moveUse) ~= "table" then
    return nil
  end
  local use = moveUse --[[@as table<string, unknown>]]
  local targets = use.targets
  if type(targets) ~= "table" then
    return nil
  end
  local holder = holderOf(instance)
  if holder == nil or use.user == holder then
    return nil
  end
  for _, target in
    ipairs(targets --[[@as table<integer, integer>]])
  do
    if target == holder then
      return { kind = "trigger", key = instance.key, combatant = holder, extraPp = 1 }
    end
  end
  return nil
end

--- Cleans the canonical condition on the way out for holders of the
--- curing ability; holders without it announce nothing and keep their
--- condition through the same replacement.
---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> leaving context under handling
---@return table<string, unknown>? cure announcement, or nil when nothing is cured
local function naturalCure(instance, context)
  local mon = context.mon
  if type(mon) ~= "table" then
    return nil
  end
  local record = mon --[[@as table<string, unknown>]]
  if record.ability ~= instance.key then
    return nil
  end
  local condition = record.condition
  if type(condition) ~= "table" then
    return nil
  end
  local effects = (condition --[[@as table<string, unknown>]]).effects
  if type(effects) ~= "table" then
    return nil
  end
  local native = { sleep = true, poison = true, burn = true, freeze = true, paralysis = true, toxic = true }
  for _, effect in
    ipairs(effects --[[@as table<integer, table<string, unknown>>]])
  do
    if type(effect) == "table" and native[effect.key] == true then
      Status.cure(mon --[[@as table<string, unknown>]], effect.key --[[@as string]])
      return { kind = "trigger", key = instance.key, combatant = holderOf(instance) }
    end
  end
  return nil
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> status context under handling
---@return table<string, unknown>? prevention announcement, or nil when inapplicable
local function preventStatus(instance, context)
  local warded = STATUS_PREVENTION[instance.key]
  if warded == nil then
    return nil
  end
  if context.statusAttempt ~= warded then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), prevented = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> residual context under handling
---@return table<string, unknown>? recovery announcement, or nil when inapplicable
local function residualHeal(instance, context)
  local trigger = RESIDUAL_HEAL[instance.key]
  if trigger == nil then
    return nil
  end
  if trigger == "rain" or trigger == "hail" then
    if context.weather ~= trigger then
      return nil
    end
  elseif context.status ~= trigger then
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
  if type(hp) ~= "number" or type(maxHp) ~= "number" or hp <= 0 or hp >= maxHp then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holder }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> residual context under handling
---@return table<string, unknown>? turn announcement, or nil when inapplicable
local function turnResponse(instance, context)
  if instance.key == "SPEED_BOOST" then
    if context.turnEnd ~= true and context.residual ~= true then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), stat = "speed", stages = "boosted" }
  end
  if instance.key == "SHED_SKIN" then
    if context.status == nil then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), cured = context.status }
  end
  if instance.key == "HYDRATION" then
    if context.weather ~= "rain" or context.status == nil then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), cured = context.status }
  end
  if instance.key == "LEAF_GUARD" then
    if context.weather ~= "sun" then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), guarded = true }
  end
  if instance.key == "BAD_DREAMS" then
    if context.foeAsleep ~= true then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), harmed = true }
  end
  return nil
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> pre-action context under handling
---@return table<string, unknown>? action announcement, or nil when inapplicable
local function beforeAction(instance, context)
  if context.moveUse == nil and context.actionCheck ~= true then
    return nil
  end
  if instance.key == "STALL" then
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), order = "last" }
  end
  if instance.key == "TRUANT" then
    local state = instance.state
    if type(state) ~= "table" then
      return nil
    end
    local loafing = (state --[[@as table<string, boolean>]]).loafing == true
    (state --[[@as table<string, boolean>]]).loafing = not loafing
    if loafing then
      return { kind = "trigger", key = instance.key, combatant = holderOf(instance), loafing = true }
    end
    return nil
  end
  if instance.key == "SLOW_START" then
    local state = instance.state
    if type(state) ~= "table" then
      return nil
    end
    local spent = (state --[[@as table<string, integer>]]).actions
    if type(spent) ~= "number" then
      spent = 0
    end
    (state --[[@as table<string, integer>]]).actions = spent + 1
    if spent < 5 then
      return { kind = "trigger", key = instance.key, combatant = holderOf(instance), stat = "attack", stages = "halved" }
    end
    return nil
  end
  if instance.key == "DAMP" then
    if context.explosion ~= true then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), prevented = true }
  end
  if instance.key == "KLUTZ" then
    if context.heldItem == nil then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), suppressed = true }
  end
  if instance.key == "UNBURDEN" then
    if context.consumedOwnItem ~= true then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), stat = "speed", stages = "doubled" }
  end
  if instance.key == "GLUTTONY" then
    if context.berryCheck ~= true then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), earlyBerry = true }
  end
  if instance.key == "RUN_AWAY" then
    if context.flee ~= true then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), escape = "assured" }
  end
  return nil
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> post-hit context under handling
---@return table<string, unknown>? hit announcement, or nil when inapplicable
local function hitResponse(instance, context)
  if instance.key == "AFTERMATH" then
    if context.contactFaint ~= true then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), harmed = true }
  end
  if instance.key == "ANGER_POINT" then
    if context.criticalHit ~= true then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), stat = "attack", stages = "maxed" }
  end
  if instance.key == "STEADFAST" then
    if context.flinched ~= true then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), stat = "speed", stages = "boosted" }
  end
  if instance.key == "COLOR_CHANGE" then
    if context.moveType == nil then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), becomeType = context.moveType }
  end
  if instance.key == "SYNCHRONIZE" then
    if context.inflictedStatus == nil then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), reflected = context.inflictedStatus }
  end
  if instance.key == "LIQUID_OOZE" then
    if context.drain ~= true then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), backfire = true }
  end
  return nil
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> switch context under handling
---@return table<string, unknown>? trapping announcement, or nil when inapplicable
local function trapping(instance, context)
  if context.switchAttempt ~= true and context.flee ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), trapped = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> residual context under handling
---@return table<string, unknown>? sleep response, or nil when inapplicable
local function earlyBird(instance, context)
  if context.sleepCheck ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), turns = "halved" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> hit context under handling
---@return table<string, unknown>? dust announcement, or nil when inapplicable
local function shieldDust(instance, context)
  if context.secondary ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), blocked = true }
end

--- Abilities with no battle checkpoint effect stay bound and silent, so
--- coverage distinguishes their genuine absence of effect from an
--- unimplemented binding.
---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> pass context under handling
---@return nil always silent
local function noCheckpointEffect(instance, context)
  assert(type(instance) == "table", "reactive handlers read their instance")
  assert(type(context) == "table", "reactive handlers read their pass context")
  return nil
end

--- Binds the before-action, status, hit, and turn handlers into the owner table.
---@param owned table<string, fun(instance: table<string, unknown>, context: table<string, unknown>): table<string, unknown>?> handler owner receiving the family bindings
function ReactiveAbilities.register(owned)
  assert(type(owned) == "table", "reactive abilities register into their owner table")
  owned.STATIC = contactResponse
  owned.PRESSURE = pressure
  owned.NATURAL_CURE = naturalCure
  owned.SHIELD_DUST = shieldDust
  owned.EARLY_BIRD = earlyBird
  owned.AFTERMATH = hitResponse
  owned.ANGER_POINT = hitResponse
  owned.STEADFAST = hitResponse
  owned.COLOR_CHANGE = hitResponse
  owned.SYNCHRONIZE = hitResponse
  owned.LIQUID_OOZE = hitResponse
  owned.STALL = beforeAction
  owned.TRUANT = beforeAction
  owned.SLOW_START = beforeAction
  owned.DAMP = beforeAction
  owned.KLUTZ = beforeAction
  owned.UNBURDEN = beforeAction
  owned.GLUTTONY = beforeAction
  owned.RUN_AWAY = beforeAction
  owned.SPEED_BOOST = turnResponse
  owned.SHED_SKIN = turnResponse
  owned.HYDRATION = turnResponse
  owned.LEAF_GUARD = turnResponse
  owned.BAD_DREAMS = turnResponse
  owned.SHADOW_TAG = trapping
  owned.ARENA_TRAP = trapping
  owned.MAGNET_PULL = trapping
  owned.SUCTION_CUPS = trapping
  owned.STICKY_HOLD = trapping
  for key in pairs(CONTACT_RESPONSE) do
    if owned[key] == nil then
      owned[key] = contactResponse
    end
  end
  for key in pairs(STATUS_PREVENTION) do
    owned[key] = preventStatus
  end
  for key in pairs(RESIDUAL_HEAL) do
    owned[key] = residualHeal
  end
  owned.PICKUP = noCheckpointEffect
  owned.HONEY_GATHER = noCheckpointEffect
  owned.ILLUMINATE = noCheckpointEffect
end

return ReactiveAbilities
