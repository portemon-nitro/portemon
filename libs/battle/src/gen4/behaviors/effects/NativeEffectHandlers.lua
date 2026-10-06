-- Native battle-local effect handlers for the HGSS session lifecycle.
-- This module is the single registration owner binding the native volatile
-- and field definitions to their executable timing-specific handlers. It
-- exists because the session dispatches residual, entry, and before-action
-- work through the shared finite dispatch, which resolves handlers per
-- definition key: without one cohesive table the executor would scatter
-- native HP math across move modules. Definitions stay owned by their
-- declaring modules; only the handler implementations live here. Nearest
-- analogue: `libs/battle/src/gen4/behaviors/NativePassives.lua`, which
-- groups the native ability/item handlers into one executable table. No new
-- effect class, dispatcher, timing, or mod-facing surface is added.
--
-- Handler contract: every handler receives its live instance and the
-- pass context, mutates `context.health` in place, persists countdowns
-- through `instance.state`, and returns its events. Facts the pass cannot
-- derive (maximum health, semantic types, position occupancy, combat
-- stats, entry sides, the session chart, entrant grounding) arrive
-- through the per-pass facts the executor builds, so handlers close over
-- them instead of reading battle state. The pass context carries what
-- only the invocation knows: the pending strike identity and power for
-- before-action gates, a major-condition writer for drowsy and toxic
-- arrivals, and a hazard clearer for poison absorption. Before-action
-- handlers that deny the action record the denial on `context.blockedBy`;
-- the executor reads that flag after the pass instead of inferring it
-- from event presence, and handlers stay silent once an earlier verdict
-- denied the action so one pass emits at most one gate verdict. Countdown ticks that
-- change nothing emit no event; removal of the expired instance belongs
-- to the session sweep after a completed pass. Source references:
-- src/battle/battle_command.c action-gate, switch-in, and end-of-turn
-- effect order and the overlay countdown semantics the definitions pin.
--
-- Event vocabulary, all deterministic in handler order:
--   tick   { key, combatant, amount }      positive damage dealt
--   healed { key, combatant, restored }    recovery applied
--   expire { key, combatant|side|position } countdown reached zero
-- Countdown ticks that change nothing emit no event; removal of the
-- expired instance belongs to the session sweep after a completed pass.

local Damage = require("libs.battle.src.gen4.Damage")
local FieldEffects = require("libs.battle.src.gen4.behaviors.effects.FieldEffects")
local VolatileEffects = require("libs.battle.src.gen4.behaviors.effects.VolatileEffects")
local BattleErrors = require("libs.battle.src.errors")
local TypeEffectiveness = require("libs.battle.src.gen4.TypeEffectiveness")

---@class NativeEffectHandlers
local NativeEffectHandlers = {}

---@class NativeTimingFacts
---@field maxHp table<integer, integer> battle maximum health per combatant
---@field types table<integer, string[]> semantic types per combatant
---@field occupants table<integer, integer> active combatant per position
---@field stats table<integer, table<string, integer>>? live level and battle stats per combatant
---@field sides table<integer, integer>? owning side per combatant
---@field entrant integer? combatant entering the field under an entry pass
---@field grounded boolean? true when spikes-family layers price the entrant
---@field chart table<string, unknown>? session chart view resolving effectiveness
---@field slept table<integer, boolean>? sleeping combatants under nightmare watch

---@type table<string, table<string, unknown>>? native definitions by key, captured once
local cachedDefinitions = nil

--- Captures the native volatile and field definitions through their
--- existing registration surface. The sink only records the definition
--- records; nothing is frozen, published, or mutated.
---@return table<string, table<string, unknown>> native definitions by key
local function nativeDefinitions()
  if cachedDefinitions ~= nil then
    return cachedDefinitions
  end
  local captured = {}
  local function captureNativeEffect(_, key, definition, _)
    assert(type(key) == "string" and key ~= "", "native definitions carry their key")
    assert(type(definition) == "table", "native definitions travel as records")
    captured[key] = definition
  end
  local sink = {
    registerEffect = captureNativeEffect,
  }
  VolatileEffects.register(sink, "native-effect-handlers")
  FieldEffects.register(sink, "native-effect-handlers")
  cachedDefinitions = captured
  return captured
end

--- Resolves one native definition for typed battle-local writes. Unknown
--- keys fail explicitly so callers never store an undeclared condition.
---@param key string definition identity under resolution
---@return table<string, unknown> the native definition record
function NativeEffectHandlers.definitionFor(key)
  assert(type(key) == "string" and key ~= "", "typed writes name their definition")
  local definition = nativeDefinitions()[key]
  if definition == nil then
    error(BattleErrors.missingBehavior("no native effect definition is declared for the key", { key = key }))
  end
  return definition
end

---@param facts NativeTimingFacts per-pass battle facts under the handlers
---@param combatant integer combatant identity under the tick
---@return integer battle maximum health for the combatant
local function maxHpOf(facts, combatant)
  local ceiling = facts.maxHp[combatant]
  if type(ceiling) ~= "number" or ceiling % 1 ~= 0 or ceiling < 1 then
    error(BattleErrors.invalidState("residual ticks read battle maximum health", { combatant = combatant }))
  end
  return ceiling --[[@as integer]]
end

---@param facts NativeTimingFacts per-pass battle facts under the handlers
---@param combatant integer combatant identity under the tick
---@return string[] semantic types for the combatant
local function typesOf(facts, combatant)
  local types = facts.types[combatant]
  if type(types) ~= "table" or #types == 0 then
    error(BattleErrors.invalidState("residual ticks read semantic type facts", { combatant = combatant }))
  end
  return types --[[@as string[] ]]
end

---@param health table<integer, integer> battle-local health under the pass
---@param combatant integer combatant identity under inspection
---@return integer current pass health for the combatant
local function healthOf(health, combatant)
  local hp = health[combatant]
  if type(hp) ~= "number" or hp % 1 ~= 0 then
    error(BattleErrors.invalidState("residual ticks read battle-local health", { combatant = combatant }))
  end
  return hp --[[@as integer]]
end

---@param instance table<string, unknown> live instance under the countdown
---@return integer remaining turns after this tick
local function countDown(instance)
  local state = instance.state --[[@as table<string, unknown>]]
  if type(state) ~= "table" then
    error(BattleErrors.invalidState("countdowns tick a state record", { key = instance.key }))
  end
  if
    type(state.turns) ~= "number" or state.turns --[[@as integer]]
      % 1 ~= 0
  then
    error(BattleErrors.invalidState("countdowns tick an integer turn counter", { key = instance.key }))
  end
  local remaining = state.turns --[[@as integer]] - 1
  state.turns = remaining
  return remaining
end

---@param instance table<string, unknown> live instance under expiry
---@return table<string, unknown> expiry event echoing the instance owner
local function expireEvent(instance)
  local scope = instance.scope --[[@as table<string, unknown>]]
  local event = { kind = "expire", key = instance.key }
  for _, field in ipairs({ "combatant", "side", "position" }) do
    if scope[field] ~= nil then
      event[field] = scope[field]
    end
  end
  return event
end

---@param facts NativeTimingFacts per-pass battle facts under the handlers
---@param health table<integer, integer> battle-local health under the pass
---@param combatant integer combatant identity receiving damage
---@param divisor integer maximum-health divisor for the tick
---@return integer damage dealt after application
local function dealFraction(facts, health, combatant, divisor)
  local damage = math.floor(maxHpOf(facts, combatant) / divisor)
  if damage < 1 then
    damage = 1
  end
  health[combatant] = healthOf(health, combatant) - damage
  return damage
end

---@param facts NativeTimingFacts per-pass battle facts under the handlers
---@param health table<integer, integer> battle-local health under the pass
---@param combatant integer combatant identity receiving recovery
---@param divisor integer maximum-health divisor for the recovery
---@return integer recovery applied after application
local function healFraction(facts, health, combatant, divisor)
  local ceiling = maxHpOf(facts, combatant)
  local missing = ceiling - healthOf(health, combatant)
  if missing < 1 then
    return 0
  end
  local restored = math.floor(ceiling / divisor)
  if restored < 1 then
    restored = 1
  end
  if restored > missing then
    restored = missing
  end
  health[combatant] = healthOf(health, combatant) + restored
  return restored
end

---@param types string[] semantic types under inspection
---@param immune table<string, boolean> types unaffected by the weather
---@return boolean true when the weather spares the combatant
local function weatherImmune(types, immune)
  for _, key in ipairs(types) do
    if immune[key] == true then
      return true
    end
  end
  return false
end

---@param health table<integer, integer> battle-local health under the pass
---@param combatant integer combatant identity under inspection
---@return boolean true when the combatant holds a live entry this pass
local function anchored(health, combatant)
  -- Dormant carry-policy instances outlive their entry while benched;
  -- they stay silent until re-anchored instead of ticking dead health.
  return type(health[combatant]) == "number" and health[combatant] --[[@as integer]] > 0
end

---@param facts NativeTimingFacts per-pass battle facts under the handlers
---@param immune table<string, boolean> types unaffected by the weather
---@param key string weather identity under the damage
---@return fun(instance: table<string, unknown>, context: table<string, unknown>): table<string, unknown>[] handler damaging every exposed combatant in speed order
local function makeWeather(facts, immune, key)
  local function tickWeather(_, context)
    local health = context.health --[[@as table<integer, integer>]]
    local speeds = context.speeds --[[@as table<integer, integer>?]]
    local order = {}
    for combatant in pairs(health) do
      order[#order + 1] = combatant
    end
    table.sort(order, function(left, right)
      local leftSpeed = 0
      local rightSpeed = 0
      if type(speeds) == "table" then
        if type(speeds[left]) == "number" then
          leftSpeed = speeds[left]
        end
        if type(speeds[right]) == "number" then
          rightSpeed = speeds[right]
        end
      end
      if leftSpeed ~= rightSpeed then
        return leftSpeed > rightSpeed
      end
      return left < right
    end)
    local events = {}
    for _, combatant in ipairs(order) do
      if healthOf(health, combatant) > 0 and not weatherImmune(typesOf(facts, combatant), immune) then
        local damage = dealFraction(facts, health, combatant, 16)
        events[#events + 1] = { kind = "tick", key = key, combatant = combatant, amount = damage }
      end
    end
    return events
  end
  return tickWeather
end

-- Countdown-only families tick their timer and expire without health
-- effects; the session sweep removes the zeroed instance after its
-- final pass.
local function makeExpiry()
  local function tickExpiry(instance, _)
    if countDown(instance) > 0 then
      return nil
    end
    return expireEvent(instance)
  end
  return tickExpiry
end

---@param facts NativeTimingFacts per-pass battle facts under the handlers
local function checkBaseFacts(facts)
  assert(type(facts) == "table", "native handlers read their per-pass facts")
  assert(type(facts.maxHp) == "table", "native handlers read battle maximum health")
  assert(type(facts.types) == "table", "native handlers read semantic type facts")
  assert(type(facts.occupants) == "table", "native handlers read position occupancy")
end

---@param instance table<string, unknown> live instance under inspection
---@return integer combatant identity owning the instance scope
local function scopeCombatant(instance)
  local scope = instance.scope --[[@as table<string, unknown>]]
  if type(scope) ~= "table" or type(scope.combatant) ~= "number" then
    error(BattleErrors.invalidState("combatant-scoped handlers read their owner", { key = instance.key }))
  end
  return scope.combatant --[[@as integer]]
end

---@param instance table<string, unknown> live instance under inspection
---@return integer side identity owning the instance scope
local function scopeSide(instance)
  local scope = instance.scope --[[@as table<string, unknown>]]
  if type(scope) ~= "table" or type(scope.side) ~= "number" then
    error(BattleErrors.invalidState("side-scoped handlers read their owner", { key = instance.key }))
  end
  return scope.side --[[@as integer]]
end

---@param facts NativeTimingFacts per-pass battle facts under the handlers
---@param combatant integer combatant identity under inspection
---@return table<string, integer> live level and battle stats for the combatant
local function statsOf(facts, combatant)
  local stats = facts.stats --[[@as table<integer, table<string, integer>>?]]
  if type(stats) ~= "table" then
    error(BattleErrors.invalidState("action handlers read live battle stats", { combatant = combatant }))
  end
  local owned = stats[combatant]
  if type(owned) ~= "table" then
    error(BattleErrors.invalidState("action handlers read live battle stats", { combatant = combatant }))
  end
  for _, field in ipairs({ "level", "attack", "defense" }) do
    if
      type(owned[field]) ~= "number" or owned[field] --[[@as integer]]
        % 1 ~= 0
    then
      error(BattleErrors.invalidState("action handlers read live battle stats", { combatant = combatant }))
    end
  end
  return owned --[[@as table<string, integer>]]
end

---@param context table<string, unknown> pass context carrying the battle stream
---@return table<string, unknown> labeled battle stream for rolled ticks
local function checkBattleStream(context)
  local stream = context.stream --[[@as table<string, unknown>?]]
  if type(stream) ~= "table" or type(stream.nextU16) ~= "function" then
    error(BattleErrors.invalidState("rolled handlers draw from the battle stream", {}))
  end
  return stream --[[@as table<string, unknown>]]
end

-- Confusion strikes itself half the time as a 40-power typeless physical
-- hit of its own Attack against its own Defense. The 50% check draws one
-- labeled battle-stream draw before any damage roll, in source order.
local CONFUSION_POWER = 40
local CONFUSION_HIT_THRESHOLD = 32768

--- Builds the executable native handlers for one residual pass. Only keys
--- with reachable native setters are bound; a collected instance without
--- a handler fails loudly through the dispatch owner instead of ticking
--- silently.
---@param facts NativeTimingFacts per-pass battle facts under the handlers
---@return table<string, fun(instance: table<string, unknown>, context: table<string, unknown>): unknown> handlers by definition key
local function buildResidualHandlers(facts)
  checkBaseFacts(facts)
  local handlers = {}

  ---@param instance table<string, unknown> live leech-seed instance under the tick
  ---@param context table<string, unknown> residual pass context under mutation
  ---@return unknown tick event, or nil when the victim holds no live entry
  local function leechseed(instance, context)
    local health = context.health --[[@as table<integer, integer>]]
    local victim = instance
      .scope --[[@as table<string, unknown>]]
      .combatant --[[@as integer]]
    if not anchored(health, victim) then
      return nil
    end
    local damage = dealFraction(facts, health, victim, 8)
    local source = instance
      .source --[[@as table<string, unknown>]]
      .combatant
    if type(source) == "number" and type(health[source]) == "number" and health[source] > 0 then
      healFraction(facts, health, source --[[@as integer]], 8)
    end
    return { kind = "tick", key = "leechseed", combatant = victim, amount = damage }
  end
  handlers.leechseed = leechseed

  ---@param instance table<string, unknown> live curse instance under the tick
  ---@param context table<string, unknown> residual pass context under mutation
  ---@return unknown tick event, or nil when the victim holds no live entry
  local function curse(instance, context)
    local health = context.health --[[@as table<integer, integer>]]
    local victim = instance
      .scope --[[@as table<string, unknown>]]
      .combatant --[[@as integer]]
    if not anchored(health, victim) then
      return nil
    end
    local damage = dealFraction(facts, health, victim, 4)
    return { kind = "tick", key = "curse", combatant = victim, amount = damage }
  end
  handlers.curse = curse

  ---@param instance table<string, unknown> live aqua-ring instance under the tick
  ---@param context table<string, unknown> residual pass context under mutation
  ---@return unknown healing event, or nil when nothing is restored
  local function aquaring(instance, context)
    local health = context.health --[[@as table<integer, integer>]]
    local combatant = instance
      .scope --[[@as table<string, unknown>]]
      .combatant --[[@as integer]]
    if not anchored(health, combatant) then
      return nil
    end
    local restored = healFraction(facts, health, combatant, 16)
    if restored < 1 then
      return nil
    end
    return { kind = "healed", key = "aquaring", combatant = combatant, restored = restored }
  end
  handlers.aquaring = aquaring

  ---@param instance table<string, unknown> live perish-song instance under the countdown
  ---@param context table<string, unknown> residual pass context under mutation
  ---@return unknown expiry event, or nil when the countdown keeps running
  local function perishsong(instance, context)
    local health = context.health --[[@as table<integer, integer>]]
    local combatant = instance
      .scope --[[@as table<string, unknown>]]
      .combatant --[[@as integer]]
    if not anchored(health, combatant) then
      return nil
    end
    if countDown(instance) > 0 then
      return nil
    end
    health[combatant] = 0
    return expireEvent(instance)
  end
  handlers.perishsong = perishsong

  ---@param instance table<string, unknown> live wish instance under the countdown
  ---@param context table<string, unknown> residual pass context under mutation
  ---@return unknown expiry and healing events, or nil while the countdown keeps running
  local function wish(instance, context)
    local health = context.health --[[@as table<integer, integer>]]
    if countDown(instance) > 0 then
      return nil
    end
    local events = { expireEvent(instance) }
    local occupant = facts.occupants[
      instance
        .scope --[[@as table<string, unknown>]]
        .position --[[@as integer]]
    ]
    if type(occupant) == "number" and type(health[occupant]) == "number" and health[occupant] > 0 then
      local ceiling = maxHpOf(facts, occupant --[[@as integer]])
      local missing = ceiling - health[occupant]
      if missing > 0 then
        local restored = math.floor(ceiling / 2)
        if restored < 1 then
          restored = 1
        end
        if restored > missing then
          restored = missing
        end
        health[occupant] = health[occupant] + restored
        events[#events + 1] = { kind = "healed", key = "wish", combatant = occupant, restored = restored }
      end
    end
    return events
  end
  handlers.wish = wish

  handlers.sandstorm = makeWeather(facts, { rock = true, ground = true, steel = true }, "sandstorm")
  handlers.hail = makeWeather(facts, { ice = true }, "hail")

  -- Ingrain restores one sixteenth of maximum health like aqua ring.
  ---@param instance table<string, unknown> live ingrain instance under the tick
  ---@param context table<string, unknown> residual pass context under mutation
  ---@return unknown healing event, or nil when nothing is restored
  local function ingrain(instance, context)
    local health = context.health --[[@as table<integer, integer>]]
    local combatant = instance
      .scope --[[@as table<string, unknown>]]
      .combatant --[[@as integer]]
    if not anchored(health, combatant) then
      return nil
    end
    local restored = healFraction(facts, health, combatant, 16)
    if restored < 1 then
      return nil
    end
    return { kind = "healed", key = "ingrain", combatant = combatant, restored = restored }
  end
  handlers.ingrain = ingrain

  -- Nightmare drains one quarter of maximum health from sleeping
  -- victims; waking zeroes the countdown so the sweep drops it. Sleep
  -- facts arrive per pass beside the health map because the residual
  -- context carries no mon records.
  local slept = facts.slept
  if type(slept) ~= "table" then
    slept = {}
  end
  ---@param instance table<string, unknown> live nightmare instance under the tick
  ---@param context table<string, unknown> residual pass context under mutation
  ---@return unknown tick event, expiry event, or nil when the victim holds no live entry
  local function nightmare(instance, context)
    local health = context.health --[[@as table<integer, integer>]]
    local victim = instance
      .scope --[[@as table<string, unknown>]]
      .combatant --[[@as integer]]
    if not anchored(health, victim) then
      return nil
    end
    if
      (slept --[[@as table<integer, boolean>]])[victim] ~= true
    then
      instance
        .state --[[@as table<string, unknown>]]
        .turns = 0
      return expireEvent(instance)
    end
    local damage = math.floor(maxHpOf(facts, victim) / 4)
    health[victim] = healthOf(health, victim) - damage
    instance
      .state --[[@as table<string, unknown>]]
      .turns = 1
    return { kind = "tick", key = "nightmare", combatant = victim, amount = damage }
  end
  handlers.nightmare = nightmare

  -- Binding counts down first: bound turns drain one sixteenth of
  -- maximum health, and the zeroed countdown releases silently through
  -- the session sweep after its expiry event.
  ---@param instance table<string, unknown> live binding instance under the tick
  ---@param context table<string, unknown> residual pass context under mutation
  ---@return unknown tick event, expiry event, or nil when the victim holds no live entry
  local function bind(instance, context)
    local health = context.health --[[@as table<integer, integer>]]
    local victim = instance
      .scope --[[@as table<string, unknown>]]
      .combatant --[[@as integer]]
    if not anchored(health, victim) then
      return nil
    end
    if countDown(instance) <= 0 then
      return expireEvent(instance)
    end
    local damage = math.floor(maxHpOf(facts, victim) / 16)
    health[victim] = healthOf(health, victim) - damage
    return { kind = "tick", key = "bind", combatant = victim, amount = damage }
  end
  handlers.bind = bind

  -- Flinch marks expire silently: the native mark only ever gates the
  -- current turn, so the countdown drops it without an event.
  ---@param instance table<string, unknown> live flinch mark under the tick
  ---@return unknown silence; the countdown drops the mark
  local function flinch(instance, _)
    countDown(instance)
    return nil
  end
  handlers.flinch = flinch

  for _, key in ipairs({
    "raindance",
    "sunnyday",
    "reflect",
    "lightscreen",
    "safeguard",
    "mist",
    "gravity",
    "trickroom",
    "magnetrise",
    "tailwind",
    "luckychant",
  }) do
    handlers[key] = makeExpiry()
  end

  -- Future sight has no reachable native setter yet, so
  -- the countdown expires without its delayed strike; the expiry keeps
  -- the instance from lingering silently if one ever arrives.
  handlers.futuresight = makeExpiry()

  return handlers
end

-- Field and side conditions outlive every entry, so the entry pass only
-- affirms their presence: durations keep ticking at turn end and never
-- lose a turn to a switch-in.
---@return fun(instance: table<string, unknown>, context: table<string, unknown>): unknown handler affirming presence
local function affirmEntry()
  local function affirm(_, _)
    return nil
  end
  return affirm
end

--- Reads the standing hazard layer count from the side instance itself:
--- layers settle onto the side record when the hazard is laid, so the
--- entry pass prices its own instance without a second projected count.
---@param instance table<string, unknown> live hazard instance under the entry
---@return integer standing layers on the side
local function hazardLayers(instance)
  local state = instance.state --[[@as table<string, unknown>]]
  if
    type(state) ~= "table"
    or type(state.layers) ~= "number"
    or state.layers --[[@as integer]]
      % 1 ~= 0
    or state.layers --[[@as integer]]
      < 1
  then
    error(BattleErrors.invalidState("hazard handlers read their standing layer count", { key = instance.key }))
  end
  return state.layers --[[@as integer]]
end

--- Builds the executable native handlers for one entry pass. Hazards
--- strike only the entrant on their own side with source-derived
--- fractions; every other supported entry binding affirms presence.
---@param facts NativeTimingFacts per-pass battle facts under the handlers
---@return table<string, fun(instance: table<string, unknown>, context: table<string, unknown>): unknown> handlers by definition key
local function buildEntryHandlers(facts)
  checkBaseFacts(facts)
  assert(type(facts.sides) == "table", "entry handlers read the owning side per combatant")
  assert(type(facts.entrant) == "number", "entry handlers name their entrant")
  if type(facts.chart) ~= "table" then
    error(BattleErrors.invalidState("entry hazards read the session chart", {}))
  end
  local handlers = {}

  ---@param instance table<string, unknown> live hazard instance under the entry
  ---@param context table<string, unknown> entry pass context under mutation
  ---@return unknown tick event, or nil when the hazard spares the entrant
  local function stealthrock(instance, context)
    local entrant = facts.entrant --[[@as integer]]
    local sides = facts.sides --[[@as table<integer, integer>]]
    if sides[entrant] ~= scopeSide(instance) then
      return nil
    end
    local resolved =
      TypeEffectiveness.resolve(facts.chart --[[@as table<string, unknown>]], "rock", typesOf(facts, entrant), {})
    if resolved.immune then
      return nil
    end
    local health = context.health --[[@as table<integer, integer>]]
    local hp = healthOf(health, entrant)
    if hp <= 0 then
      return nil
    end
    local damage = math.floor(maxHpOf(facts, entrant) * resolved.numerator / (8 * resolved.denominator))
    if damage < 1 then
      damage = 1
    end
    health[entrant] = hp - damage
    return { kind = "tick", key = instance.key, combatant = entrant, amount = damage }
  end
  handlers.stealthrock = stealthrock

  -- Spikes price grounded arrivals by standing layers: one layer costs
  -- one eighth of battle maximum health, two cost one sixth, and three
  -- cost one fourth. Levitation (flying types, magnet rise) avoids the
  -- layers while gravity holds every arrival down. Source references:
  -- BtlCmd_CheckSpikes in src/battle/battle_command.c and the hazards
  -- check subscript in files/battledata/script/subscript.
  ---@param instance table<string, unknown> live spikes instance under the entry
  ---@param context table<string, unknown> entry pass context under mutation
  ---@return unknown hazard event, or nil when the layers spare the entrant
  local function spikes(instance, context)
    local entrant = facts.entrant --[[@as integer]]
    local sides = facts.sides --[[@as table<integer, integer>]]
    if sides[entrant] ~= scopeSide(instance) then
      return nil
    end
    if facts.grounded ~= true then
      return nil
    end
    local health = context.health --[[@as table<integer, integer>]]
    if healthOf(health, entrant) <= 0 then
      return nil
    end
    local layers = hazardLayers(instance)
    local divisor = 8
    if layers >= 3 then
      divisor = 4
    elseif layers >= 2 then
      divisor = 6
    end
    local damage = math.floor(maxHpOf(facts, entrant) / divisor)
    health[entrant] = healthOf(health, entrant) - damage
    if
      health[entrant] --[[@as integer]]
      < 0
    then
      health[entrant] = 0
    end
    return { kind = "hazard", key = "spikes", combatant = entrant, amount = damage }
  end
  handlers.spikes = spikes

  -- Toxic spikes poison grounded arrivals (badly at two layers) instead
  -- of dealing damage: a grounded poison arrival absorbs the layers
  -- through the hazard clearer, and steel arrivals shrug them off.
  -- Source references: BtlCmd_CheckToxicSpikes in
  -- src/battle/battle_command.c and the hazards check subscript in
  -- files/battledata/script/subscript.
  ---@param instance table<string, unknown> live toxic spikes instance under the arrival
  ---@param context table<string, unknown> entry pass context under mutation
  ---@return unknown hazard or absorb event, or nil when the layers spare the entrant
  local function toxicspikes(instance, context)
    local entrant = facts.entrant --[[@as integer]]
    local sides = facts.sides --[[@as table<integer, integer>]]
    if sides[entrant] ~= scopeSide(instance) then
      return nil
    end
    if facts.grounded ~= true then
      return nil
    end
    for _, defenderType in ipairs(typesOf(facts, entrant)) do
      if defenderType == "poison" then
        local clearHazard = context.clearHazard --[[@as fun(): boolean?]]
        assert(type(clearHazard) == "function", "poison arrivals absorb their toxic layers")
        clearHazard()
        return { kind = "absorb", key = "toxicspikes", combatant = entrant }
      end
      if defenderType == "steel" then
        return nil
      end
    end
    local health = context.health --[[@as table<integer, integer>]]
    if healthOf(health, entrant) <= 0 then
      return nil
    end
    local applyStatus = context.applyStatus --[[@as fun(combatant: integer, key: string, state: table<string, unknown>): boolean]]
    assert(type(applyStatus) == "function", "toxic layers write through the status owner")
    if hazardLayers(instance) >= 2 then
      applyStatus(entrant, "toxic", { counter = 0 })
    else
      applyStatus(entrant, "poison", {})
    end
    return { kind = "hazard", key = "toxicspikes", combatant = entrant }
  end
  handlers.toxicspikes = toxicspikes

  for _, key in ipairs({
    "reflect",
    "lightscreen",
    "safeguard",
    "mist",
    "raindance",
    "sunnyday",
    "sandstorm",
    "hail",
    "gravity",
    "trickroom",
  }) do
    handlers[key] = affirmEntry()
  end

  return handlers
end

--- Builds the executable native handlers for one before-action pass.
--- Flinch denies the action outright; confusion counts down when its
--- owner acts, snaps out at zero, and otherwise risks the self-hit;
--- infatuation gates on a fair draw; encore, disable, and taunt count
--- down around their selection constraints; torment preserves silently
--- for the selection owner; drowsiness counts down to sleep.
---@param facts NativeTimingFacts per-pass battle facts under the handlers
---@return table<string, fun(instance: table<string, unknown>, context: table<string, unknown>): unknown> handlers by definition key
local function buildBeforeActionHandlers(facts)
  checkBaseFacts(facts)
  local handlers = {}

  ---@param instance table<string, unknown> live flinch marker under the gate
  ---@param context table<string, unknown> before-action pass context under mutation
  ---@return unknown block event consuming the one-turn marker
  local function flinch(instance, context)
    local combatant = scopeCombatant(instance)
    local health = context.health --[[@as table<integer, integer>]]
    if not anchored(health, combatant) then
      return nil
    end
    countDown(instance)
    context.blockedBy = instance.key
    return { kind = "blocked", key = instance.key, combatant = combatant }
  end
  handlers.flinch = flinch

  ---@param instance table<string, unknown> live confusion instance under the gate
  ---@param context table<string, unknown> before-action pass context under mutation
  ---@return unknown emitted event records for the pass
  local function confusion(instance, context)
    if context.blockedBy ~= nil then
      return nil
    end
    local combatant = scopeCombatant(instance)
    local health = context.health --[[@as table<integer, integer>]]
    if not anchored(health, combatant) then
      return nil
    end
    if countDown(instance) <= 0 then
      return expireEvent(instance)
    end
    local stream = checkBattleStream(context)
    local cause = { kind = "confusion", combatant = combatant }
    local draw = stream.nextU16(stream, "confusion_hit", cause)
    if draw >= CONFUSION_HIT_THRESHOLD then
      return nil
    end
    local stats = statsOf(facts, combatant)
    -- Confusion self-hits stay outside the strike-law checkpoints:
    -- explicit neutral facts keep the canonical owner strict without
    -- changing the self-hit arithmetic.
    local result = Damage.calculate({
      level = stats.level,
      power = CONFUSION_POWER,
      attack = stats.attack,
      defense = stats.defense,
      rawAttack = stats.attack,
      rawDefense = stats.defense,
      attackStage = 0,
      defenseStage = 0,
      criticalMultiplier = 1,
      category = "physical",
      burned = false,
      guts = false,
      stab = { numerator = 1, denominator = 1 },
      effectiveness = { numerator = 1, denominator = 1 },
      effectivenessFactors = { { numerator = 1, denominator = 1 } },
      weather = "none",
      weatherSuppressed = false,
      moveType = "typeless",
      solarBeam = false,
    }, stream)
    health[combatant] = healthOf(health, combatant) - result.amount
    context.blockedBy = instance.key
    return { kind = "tick", key = instance.key, combatant = combatant, amount = result.amount }
  end
  handlers.confusion = confusion

  -- Infatuation immobilizes on a fair battle-stream draw and acts
  -- through otherwise; it carries no countdown. Source references: the
  -- move-fail state machine in src/battle/battle_controller_player.c
  -- and the infatuation subscript in files/battledata/script/subscript.
  ---@param instance table<string, unknown> live infatuation instance under the gate
  ---@param context table<string, unknown> before-action pass context under mutation
  ---@return unknown block event, or nil when the entry acts through
  local function infatuation(instance, context)
    if context.blockedBy ~= nil then
      return nil
    end
    local combatant = scopeCombatant(instance)
    local health = context.health --[[@as table<integer, integer>]]
    if not anchored(health, combatant) then
      return nil
    end
    local stream = checkBattleStream(context)
    local cause = { kind = "infatuation", combatant = combatant }
    if stream.nextU16(stream, "infatuation_gate", cause) % 2 == 0 then
      return nil
    end
    context.blockedBy = instance.key
    return { kind = "blocked", key = instance.key, combatant = combatant }
  end
  handlers.infatuation = infatuation

  -- Encore counts down and names its forced move while it runs; the
  -- zeroed countdown expires through the session sweep. Move selection
  -- restriction at pick time stays with the selection owner: this
  -- timing only records the redirect verdict. Source reference:
  -- BtlCmd_TryEncore in src/battle/battle_command.c.
  ---@param instance table<string, unknown> live encore instance under the gate
  ---@param context table<string, unknown> before-action pass context under mutation
  ---@return unknown redirect or expiry event
  local function encore(instance, context)
    if context.blockedBy ~= nil then
      return nil
    end
    local combatant = scopeCombatant(instance)
    local health = context.health --[[@as table<integer, integer>]]
    if not anchored(health, combatant) then
      return nil
    end
    if countDown(instance) <= 0 then
      return expireEvent(instance)
    end
    local state = instance.state --[[@as table<string, unknown>]]
    if type(state.move) ~= "string" or state.move == "" then
      error(BattleErrors.invalidState("encore names its forced move", { key = instance.key }))
    end
    return { kind = "redirected", key = instance.key, combatant = combatant, move = state.move }
  end
  handlers.encore = encore

  -- Disable counts down and refuses only its named move; the zeroed
  -- countdown expires silently through the session sweep. Source
  -- reference: BtlCmd_TryDisable in src/battle/battle_command.c.
  ---@param instance table<string, unknown> live disable instance under the gate
  ---@param context table<string, unknown> before-action pass context under mutation
  ---@return unknown block event, or nil when the entry acts through
  local function disable(instance, context)
    if context.blockedBy ~= nil then
      return nil
    end
    local combatant = scopeCombatant(instance)
    local health = context.health --[[@as table<integer, integer>]]
    if not anchored(health, combatant) then
      return nil
    end
    if countDown(instance) <= 0 then
      return nil
    end
    local state = instance.state --[[@as table<string, unknown>]]
    if context.move == state.move then
      context.blockedBy = instance.key
      return { kind = "blocked", key = instance.key, combatant = combatant }
    end
    return nil
  end
  handlers.disable = disable

  -- Taunt counts down and refuses powerless (status) pending strikes;
  -- damaging strikes pass through, and the zeroed countdown expires
  -- silently through the session sweep. Source reference: the taunt
  -- subscript in files/battledata/script/subscript.
  ---@param instance table<string, unknown> live taunt instance under the gate
  ---@param context table<string, unknown> before-action pass context under mutation
  ---@return unknown block event, or nil when the entry acts through
  local function taunt(instance, context)
    if context.blockedBy ~= nil then
      return nil
    end
    local combatant = scopeCombatant(instance)
    local health = context.health --[[@as table<integer, integer>]]
    if not anchored(health, combatant) then
      return nil
    end
    if countDown(instance) <= 0 then
      return nil
    end
    if context.power == 0 then
      context.blockedBy = instance.key
      return { kind = "blocked", key = instance.key, combatant = combatant }
    end
    return nil
  end
  handlers.taunt = taunt

  -- Torment restricts move selection, never actions: no per-action
  -- native check exists, so this timing preserves the mark silently for
  -- the selection owner. Source reference: the torment subscript in
  -- files/battledata/script/subscript.
  ---@param instance table<string, unknown> live torment instance under the gate
  ---@return unknown silence; restriction lives at selection
  local function torment(instance, _)
    if type(instance.state) ~= "table" then
      error(BattleErrors.invalidState("timing handlers keep typed state a record", { key = instance.key }))
    end
    return nil
  end
  handlers.torment = torment

  -- Drowsiness counts the victim actions down to sleep: the second
  -- counted action sleeps through the status owner while earlier ones
  -- act untouched. Source reference: the yawn subscript in
  -- files/battledata/script/subscript.
  ---@param instance table<string, unknown> live drowsiness instance under the gate
  ---@param context table<string, unknown> before-action pass context under mutation
  ---@return unknown sleep event, or nil while drowsy
  local function yawn(instance, context)
    if context.blockedBy ~= nil then
      return nil
    end
    local combatant = scopeCombatant(instance)
    local health = context.health --[[@as table<integer, integer>]]
    if not anchored(health, combatant) then
      return nil
    end
    if countDown(instance) > 0 then
      return nil
    end
    local applyStatus = context.applyStatus --[[@as fun(combatant: integer, key: string, state: table<string, unknown>): boolean]]
    assert(type(applyStatus) == "function", "drowsy sleep writes through the status owner")
    applyStatus(combatant, "sleep", { turns = 2 })
    return { kind = "slept", key = instance.key, combatant = combatant }
  end
  handlers.yawn = yawn

  return handlers
end

--- Builds the executable native handlers for one named finite timing.
--- Only keys with timing-valid native semantics are bound; a collected
--- instance without a handler fails loudly through the dispatch owner
--- instead of running another timing's semantics.
---@param facts NativeTimingFacts per-pass battle facts under the handlers
---@param timing string? finite timing under invocation, defaulting to the residual pass
---@return table<string, fun(instance: table<string, unknown>, context: table<string, unknown>): unknown> handlers by definition key
function NativeEffectHandlers.handlersFor(facts, timing)
  local selected = timing
  if selected == nil then
    selected = "residual"
  end
  assert(type(selected) == "string", "native handlers dispatch one named timing")
  if selected == "residual" then
    return buildResidualHandlers(facts)
  end
  if selected == "entry" then
    return buildEntryHandlers(facts)
  end
  if selected == "beforeAction" then
    return buildBeforeActionHandlers(facts)
  end
  error(BattleErrors.invalidState("native handlers dispatch only finite known timings", { timing = selected }))
end

return NativeEffectHandlers
