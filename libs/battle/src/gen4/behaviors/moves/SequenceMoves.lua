-- Charging, locked, interrupted, and delayed move families: semi-invulnerable
-- charge strikes, recharge and rampage sequences, protection, focus and
-- priority interruption, forced-switch control, and delayed damage. Every
-- member binds its own handler; multi-turn setup collapses to one ordered
-- action through the shared frame, with progression markers recorded in
-- the volatile scope so leaving still discards them. Delayed damage keeps
-- the bound defender plus the attacker snapshot in the resumed frame, so
-- the hit lands even after the attacker leaves. Source references:
-- src/battle/battle_command.c and src/battle/overlay_12_0224E4FC.c.

local Accuracy = require("libs.battle.src.gen4.Accuracy")
local BattleErrors = require("libs.battle.src.errors")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local Critical = require("libs.battle.src.gen4.Critical")
local Damage = require("libs.battle.src.gen4.Damage")
local StatStages = require("libs.battle.src.gen4.StatStages")
local StagedTypeModifiers = require("libs.battle.src.gen4.behaviors.moves.StagedTypeModifiers")
local NativeEffectHandlers = require("libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers")
local SequenceMoveState = require("libs.battle.src.gen4.SequenceMoveState")

---@class SequenceMoves
local SequenceMoves = {}

SequenceMoves.MEMBERS = {
  "FLY",
  "DIG",
  "DIVE",
  "BOUNCE",
  "SHADOW_FORCE",
  "SKULL_BASH",
  "SKY_ATTACK",
  "RAZOR_WIND",
  "SOLAR_BEAM",
  "HYPER_BEAM",
  "GIGA_IMPACT",
  "FRENZY_PLANT",
  "BLAST_BURN",
  "HYDRO_CANNON",
  "ROAR_OF_TIME",
  "THRASH",
  "OUTRAGE",
  "PETAL_DANCE",
  "ROLLOUT",
  "ICE_BALL",
  "FURY_CUTTER",
  "UPROAR",
  "RAGE",
  "PROTECT",
  "DETECT",
  "ENDURE",
  "SUBSTITUTE",
  "MAGIC_COAT",
  "SNATCH",
  "FOCUS_PUNCH",
  "SUCKER_PUNCH",
  "FAKE_OUT",
  "PURSUIT",
  "U_TURN",
  "BATON_PASS",
  "WHIRLWIND",
  "ROAR",
  "FUTURE_SIGHT",
  "DOOM_DESIRE",
  "DESTINY_BOND",
  "GRUDGE",
  "STOCKPILE",
  "SPIT_UP",
  "SWALLOW",
  "CHARGE",
  "FOLLOW_ME",
  "HELPING_HAND",
}

-- Combat facts always arrive as real battle-owned projections in the
-- frame; without them the strike cannot resolve and fails explicitly.
---@param frame table<string, unknown> move frame under execution
---@return table<string, integer> staged combat inputs for the arithmetic owner
local function combatOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local facts = locals.combat
  if type(facts) ~= "table" then
    error(BattleErrors.missingBehavior("sequences read their real combat facts", { key = key, fact = "combat" }))
  end
  local combat = facts --[[@as table<string, unknown>]]
  for _, fact in ipairs({ "level", "attack", "defense", "rawAttack", "rawDefense" }) do
    local value = combat[fact]
    if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
      error(BattleErrors.missingBehavior("sequences read their real combat facts", { key = key, fact = fact }))
    end
  end
  for _, fact in ipairs({ "attackStage", "defenseStage" }) do
    local value = combat[fact]
    if type(value) ~= "number" or value % 1 ~= 0 or value < -6 or value > 6 then
      error(BattleErrors.missingBehavior("sequences read their real combat facts", { key = key, fact = fact }))
    end
  end
  return {
    level = combat.level --[[@as integer]],
    attack = combat.attack --[[@as integer]],
    defense = combat.defense --[[@as integer]],
    rawAttack = combat.rawAttack --[[@as integer]],
    rawDefense = combat.rawDefense --[[@as integer]],
    attackStage = combat.attackStage --[[@as integer]],
    defenseStage = combat.defenseStage --[[@as integer]],
  }
end

-- Strike-law facts the executor projects beside the staged pair. Charge
-- and ramp strikes read the live facts; delayed landings carry explicit
-- neutral facts so their typeless arithmetic never guesses.
---@param frame table<string, unknown> move frame under execution
---@return boolean whether the attacker carries burn
---@return boolean whether the attacker carries the resilient ability
---@return string active field weather identity
---@return boolean whether a live ability suppresses weather damage
---@return string striking move category
---@return string striking move type under weather law
---@return boolean whether the strike is the charging grass special case
local function strikeLawOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  for _, fact in ipairs({ "burned", "guts", "weather", "weatherSuppressed" }) do
    if locals[fact] == nil then
      error(BattleErrors.missingBehavior("sequences read their real combat facts", { key = key, fact = fact }))
    end
  end
  if type(locals.burned) ~= "boolean" or type(locals.guts) ~= "boolean" then
    error(BattleErrors.missingBehavior("sequences read their real combat facts", { key = key, fact = "burn" }))
  end
  if type(locals.weather) ~= "string" or locals.weather == "" or type(locals.weatherSuppressed) ~= "boolean" then
    error(BattleErrors.missingBehavior("sequences read their real combat facts", { key = key, fact = "weather" }))
  end
  local move = locals.move --[[@as table<string, unknown>]]
  if type(move) ~= "table" then
    error(BattleErrors.missingBehavior("sequences read their immutable move facts", { key = key, fact = "move" }))
  end
  local category = move.category
  if category ~= "physical" and category ~= "special" then
    error(BattleErrors.missingBehavior("sequences read their immutable move facts", { key = key, fact = "category" }))
  end
  local moveType = move.moveType
  if type(moveType) ~= "string" or moveType == "" then
    error(BattleErrors.missingBehavior("sequences read their immutable move facts", { key = key, fact = "moveType" }))
  end
  return locals.burned, --[[@as boolean]]
    locals.guts, --[[@as boolean]]
    locals.weather, --[[@as string]]
    locals.weatherSuppressed, --[[@as boolean]]
    category, --[[@as string]]
    moveType, --[[@as string]]
    record.executingMove == "SOLAR_BEAM"
end

-- Whether the striker carries the triple-damage critical ability. Absent
-- ability facts fail instead of defaulting.
---@param frame table<string, unknown> move frame under execution
---@return boolean true when the striker snipes critical hits
local function sniperOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local abilities = locals.abilities
  if type(abilities) ~= "table" then
    error(BattleErrors.missingBehavior("sequences read their battle abilities", {
      key = record.executingMove --[[@as string]],
    }))
  end
  return (abilities --[[@as table<string, unknown>]]).user == "SNIPER"
end

-- Strike power always arrives in the frame move facts; without it the
-- strike cannot resolve and fails explicitly.
---@param frame table<string, unknown> move frame under execution
---@return integer compiled strike power under the staged arithmetic
local function strikePowerOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local facts = locals.move
  if type(facts) ~= "table" then
    error(BattleErrors.missingBehavior("sequences read their immutable move facts", { key = key, fact = "move" }))
  end
  local power = (facts --[[@as table<string, unknown>]]).power
  if type(power) ~= "number" or power % 1 ~= 0 or power < 1 then
    error(BattleErrors.missingBehavior("sequences read their immutable move facts", { key = key, fact = "power" }))
  end
  local moveType = (facts --[[@as table<string, unknown>]]).moveType
  if
    (record.locals --[[@as table<string, unknown>]]).chargeBoost == true and moveType == "electric"
  then
    power = power * 2
  end
  return power --[[@as integer]]
end

-- Members resolving the immediate-strike reduction of their charge; the
-- strike power travels in the frame move facts, so this set carries only
-- the charge membership for the scheduling owner.
local CHARGE = {
  FLY = true,
  DIG = true,
  DIVE = true,
  BOUNCE = true,
  SHADOW_FORCE = true,
  SKULL_BASH = true,
  SKY_ATTACK = true,
  RAZOR_WIND = true,
  SOLAR_BEAM = true,
}

-- Members whose strike locks the user into a multi-action sequence; the
-- marker names the lock for the scheduling owner.
local LOCKED = {
  THRASH = true,
  OUTRAGE = true,
  PETAL_DANCE = true,
  UPROAR = true,
}

-- Members forcing recharge after the strike; the marker names the
-- recharge for the scheduling owner.
local RECHARGE = {
  HYPER_BEAM = true,
  GIGA_IMPACT = true,
  FRENZY_PLANT = true,
  BLAST_BURN = true,
  HYDRO_CANNON = true,
  ROAR_OF_TIME = true,
}

-- Switch modes emit move intents; the native session owns departure and arrival settlement.
local SWITCH_MODES = {
  U_TURN = "strike-and-leave",
  BATON_PASS = "pass-markers",
  WHIRLWIND = "force-foe-out",
  ROAR = "force-foe-out",
}

-- Delayed-attack members beside their scheduling bodies; the landing
-- power travels in the frame move facts, so this set carries only the
-- delay membership for the scheduling owner.
local DELAYED = {
  FUTURE_SIGHT = true,
  DOOM_DESIRE = true,
}

---@param stream unknown battle stream under the sequence
---@return BattleRng the stream once it proves its draw contract
local function checkStream(stream)
  assert(type(stream) == "table", "sequences draw from the battle stream")
  local candidate = stream --[[@as table<string, unknown>]]
  assert(type(candidate.nextU16) == "function", "sequences draw from the battle stream")
  assert(BattleRng.ALGORITHM == "gen4-lcrng", "sequences draw from the native battle stream")
  return stream --[[@as BattleRng]]
end

---@param frame table<string, unknown> move frame under execution
---@return table<string, unknown> semantic cause carried by writes and events
local function causeFor(frame)
  local actor = frame.actor --[[@as table<string, unknown>]]
  return {
    kind = "move",
    key = frame.executingMove,
    combatant = actor.combatant,
    activation = actor.activation,
  }
end

---@param frame table<string, unknown> move frame under execution
---@return integer user combatant owning the move
local function userOf(frame)
  local actor = frame.actor --[[@as table<string, unknown>]]
  assert(type(actor.combatant) == "number", "sequences read their user combatant")
  return actor.combatant --[[@as integer]]
end

---@param entry unknown target entry under resolution
---@return integer defender combatant receiving the sequence
local function targetOf(entry)
  assert(type(entry) == "table", "sequences read their target entries")
  local record = entry --[[@as table<string, unknown>]]
  assert(type(record.combatant) == "number", "sequences target combatants")
  return record.combatant --[[@as integer]]
end

---@param state unknown candidate typed state under the inert recording
---@return table<string, unknown> the versioned record
local function validateInert(state)
  if type(state) ~= "table" or state.version ~= 1 then
    error("inert markers carry their schema version")
  end
  return { version = 1 }
end

---@param ctx BattleContext mechanics context under execution
---@param combatant integer combatant receiving the volatile marker
---@param key string volatile identity under the marker
local function markVolatile(ctx, combatant, key)
  -- Unmigrated sequence markers record presence only: no dispatched
  -- timing collects them (leave is never dispatched by any session
  -- lifecycle), and leaving discards them with the rest of the
  -- activation-local instances. Their mechanics are not yet implemented
  -- and must never be mistaken for live behavior.
  local entry = ctx:entryOf(combatant)
  if entry.activation == nil then
    error("sequence markers scope to a live entry")
  end
  ctx:addBattleEffect(
    {
      key = key,
      stateVersion = 1,
      validateState = validateInert,
      timings = { { timing = "leave", handler = key, orderClass = "affliction" } },
      lifecycle = { stacking = "replace", transfer = "clear", persistent = false },
    },
    { kind = "active", combatant = combatant, activation = entry.activation },
    { kind = "move", combatant = combatant },
    { version = 1 }
  )
end

local function validateStockpileState(state)
  if type(state) ~= "table" or state.version ~= 1 then
    error("Stockpile carries its state version")
  end
  local count = state.count
  local defense = state.defenseBoosts
  local specialDefense = state.specialDefenseBoosts
  if
    type(count) ~= "number"
    or count % 1 ~= 0
    or count < 1
    or count > 3
    or type(defense) ~= "number"
    or defense % 1 ~= 0
    or defense < 0
    or defense > count
    or type(specialDefense) ~= "number"
    or specialDefense % 1 ~= 0
    or specialDefense < 0
    or specialDefense > count
  then
    error("Stockpile counts and boosts stay within three uses")
  end
  for key in pairs(state) do
    if key ~= "version" and key ~= "count" and key ~= "defenseBoosts" and key ~= "specialDefenseBoosts" then
      error("Stockpile carries no additional state")
    end
  end
  return { version = 1, count = count, defenseBoosts = defense, specialDefenseBoosts = specialDefense }
end

local STOCKPILE = {
  key = "stockpile",
  stateVersion = 1,
  validateState = validateStockpileState,
  timings = { { timing = "leave", handler = "stockpile", orderClass = "affliction" } },
  lifecycle = { stacking = "replace", transfer = "clear", persistent = false },
}

---@param ctx BattleContext mechanics context under the Stockpile transition
---@param user integer user owning the stored count
---@return table<string, unknown>? stored Stockpile state
local function takeStockpile(ctx, user)
  local stored = nil
  local function takeState(state)
    stored = state
    return nil
  end
  local outcome = ctx:updateBattleEffect(user, STOCKPILE, takeState)
  if outcome == nil then
    return nil
  end
  return stored
end

local function validateProtectStreakState(state)
  if type(state) ~= "table" or state.version ~= 1 then
    error("protection streak carries its state version")
  end
  local turn, count = state.turn, state.count
  if
    type(turn) ~= "number"
    or turn % 1 ~= 0
    or turn < 0
    or type(count) ~= "number"
    or count % 1 ~= 0
    or count < 0
    or count > 3
  then
    error("protection streak carries a turn and at most three consecutive successes")
  end
  for key in pairs(state) do
    if key ~= "version" and key ~= "turn" and key ~= "count" then
      error("protection streak carries no additional state")
    end
  end
  return { version = 1, turn = turn, count = count }
end

local PROTECT_STREAK = {
  key = "protectstreak",
  stateVersion = 1,
  validateState = validateProtectStreakState,
  timings = { { timing = "leave", handler = "protectstreak", orderClass = "affliction" } },
  lifecycle = { stacking = "replace", transfer = "clear", persistent = false },
}

-- Substitute charges a quarter of user maximum health and raises the
-- live doll on the current activation: an existing doll or health that
-- cannot cover the cost refuses with no charge, and exact-cost health
-- fails. The cost keeps a minimum of one for positive maxima, matching
-- the native division. Source reference: BtlCmd_TrySubstitute in
-- src/battle/battle_command.c.
---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@return table<string, unknown> terminal execution step for the doll
local function stepSubstitute(ctx, frame)
  assert(type(ctx) == "table", "sequences step through the battle context")
  assert(type(frame) == "table", "sequences step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local user = userOf(record)
  local entry = ctx:entryOf(user)
  if entry.activation == nil then
    error("substitute scopes to a live entry")
  end
  local maxHp = entry.maxHp
  if type(maxHp) ~= "number" or maxHp % 1 ~= 0 or maxHp < 1 then
    error(BattleErrors.missingBehavior("substitute reads its battle maximum health", { key = key, fact = "maxHp" }))
  end
  local hp = entry.hp
  if type(hp) ~= "number" or hp % 1 ~= 0 or hp < 0 then
    error(BattleErrors.missingBehavior("substitute reads its battle health", { key = key, fact = "hp" }))
  end
  local cost = math.floor(maxHp --[[@as integer]] / 4)
  if cost < 1 then
    cost = 1
  end
  if
    ctx:hasBattleEffect(user, "substitute")
    or hp --[[@as integer]]
      <= cost
  then
    return { kind = "complete", result = "failed" }
  end
  ctx:damage(user, cost, causeFor(record))
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("substitute"),
    { kind = "active", combatant = user, activation = entry.activation },
    { kind = "move", combatant = user },
    { version = 1, hp = cost }
  )
  ctx:emit("move-used", causeFor(record), { user = userOf(record), targets = 1 })
  return { kind = "complete", result = "hit" }
end

---@param ctx BattleContext mechanics context under execution
---@param defender integer defender combatant receiving the live flinch
local function markFlinch(ctx, defender)
  -- Flinch resolves through its real native definition as a one-turn
  -- marker: the before-action pass consumes it on the block, and the
  -- turn-end pass silently clears markers inflicted after their owner
  -- already acted.
  local entry = ctx:entryOf(defender)
  if entry.activation == nil then
    error("flinch scopes to a live entry")
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("flinch"),
    { kind = "active", combatant = defender, activation = entry.activation },
    { kind = "move", combatant = defender },
    { version = 1, turns = 1 }
  )
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the strike
---@param override integer|nil ramped power under the source doubling rule; when absent the compiled base resolves
---@return integer damage dealt by the strike
local function strikeTarget(ctx, frame, defender, override)
  local record = frame --[[@as table<string, unknown>]]
  local combat = combatOf(record)
  local power = override
  if power == nil then
    power = strikePowerOf(record)
  end
  local stream = checkStream(record.stream)
  local resolution = Accuracy.resolve({
    target = { kind = "combatant" },
    cause = causeFor(record),
    protected = false,
    skipCheck = true,
  }, stream)
  assert(resolution.kind == "hit", "unrolled checks always connect")
  -- Charge, lock, and ramp strikes roll the base critical stage like any
  -- unstaged strike and read the live strike-law facts, so the charging
  -- grass strike halves off sun through the same canonical arithmetic.
  local burned, guts, weather, weatherSuppressed, category, moveType, solarBeam = strikeLawOf(record)
  local critical = Critical.resolve(0, stream, causeFor(record), sniperOf(record))
  local stab, effectiveness = StagedTypeModifiers.forStrike(record, defender)
  local result = Damage.calculate({
    level = combat.level,
    power = power,
    attack = combat.attack,
    defense = combat.defense,
    rawAttack = combat.rawAttack,
    rawDefense = combat.rawDefense,
    attackStage = combat.attackStage,
    defenseStage = combat.defenseStage,
    criticalMultiplier = critical.multiplier,
    category = category,
    burned = burned,
    guts = guts,
    stab = stab,
    effectiveness = { numerator = effectiveness.numerator, denominator = effectiveness.denominator },
    effectivenessFactors = effectiveness.factors,
    weather = weather,
    weatherSuppressed = weatherSuppressed,
    moveType = moveType,
    solarBeam = solarBeam,
  }, stream)
  local outcome = ctx:damage(defender, result.amount, causeFor(record))
  if outcome.after > 0 and outcome.before > outcome.after and category ~= "other" and defender ~= userOf(record) then
    local entry = ctx:entryOf(defender)
    assert(entry.stages ~= nil, "Rage reads the defender's live stages")
    if ctx:hasBattleEffect(defender, "rage") and entry.stages.attack < 6 then
      ctx:changeStage(defender, "attack", entry.stages.attack + 1, causeFor(record))
    end
  end
  ctx:emit("struck", causeFor(record), { target = defender, hitIndex = 1, damage = outcome.before - outcome.after })
  return outcome.before - outcome.after
end

local function stepRage(ctx, frame)
  assert(type(ctx) == "table", "sequences step through the battle context")
  assert(type(frame) == "table", "sequences step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local entry = ctx:entryOf(user)
  assert(entry.activation ~= nil, "Rage scopes to its live entry")
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  strikeTarget(ctx, record, defender)
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("rage"),
    { kind = "active", combatant = user, activation = entry.activation },
    causeFor(record),
    { version = 1 }
  )
  return { kind = "complete", result = "hit" }
end

---@param handler fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> shared family body under binding
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> distinct per-move binding over the shared body
local function bind(handler)
  local function stepBound(ctx, frame)
    return handler(ctx, frame)
  end
  return stepBound
end

-- Charge moves spend a setup action and land after the scheduler forces
-- the same move on the following native turn.
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler charging then striking
local function makeChargeStrike()
  local function stepChargeStrike(ctx, frame)
    assert(type(ctx) == "table", "sequences step through the battle context")
    assert(type(frame) == "table", "sequences step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    local user = userOf(record)
    local move = record.executingMove --[[@as string]]
    local state = SequenceMoveState.read(ctx, user)
    if state == nil or state.chargeMove ~= move then
      local function beginCharge(current)
        current.chargeMove = move
        return current
      end
      SequenceMoveState.update(ctx, user, causeFor(record), beginCharge)
      ctx:emit("charged", causeFor(record), { target = user })
      ctx:emit("move-used", causeFor(record), { user = user, targets = #record.targets })
      return { kind = "complete", result = "hit" }
    end
    local function finishCharge(current)
      current.chargeMove = nil
      return current
    end
    SequenceMoveState.update(ctx, user, causeFor(record), finishCharge)
    local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
    strikeTarget(ctx, record, defender)
    return { kind = "complete", result = "hit" }
  end
  return stepChargeStrike
end

-- Recharge attacks leave a native one-action gate. Rampage attacks store
-- the remaining forced actions and fatigue confusion in sequence state.
---@param marker string lock identity recorded on the user
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler striking then locking
local function makeLockStrike(marker)
  local function stepLockStrike(ctx, frame)
    assert(type(ctx) == "table", "sequences step through the battle context")
    assert(type(frame) == "table", "sequences step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    local user = userOf(record)
    local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
    strikeTarget(ctx, record, defender)
    if marker == "RECHARGE" then
      local entry = ctx:entryOf(user)
      assert(entry.activation ~= nil, "recharge scopes to its live entry")
      ctx:addBattleEffect(
        NativeEffectHandlers.definitionFor("recharge"),
        { kind = "active", combatant = user, activation = entry.activation },
        causeFor(record),
        { version = 1, turns = 1 }
      )
    else
      local state = SequenceMoveState.read(ctx, user)
      local lock = state ~= nil and state.lock or nil
      if type(lock) == "table" and lock.move == marker then
        local remaining = lock.remaining --[[@as integer]]
        if remaining > 1 then
          local function continueLock(current)
            current.lock = { move = marker, remaining = remaining - 1 }
            return current
          end
          SequenceMoveState.update(ctx, user, causeFor(record), continueLock)
        else
          local function finishLock(current)
            current.lock = nil
            return current
          end
          SequenceMoveState.update(ctx, user, causeFor(record), finishLock)
          if marker ~= "UPROAR" then
            local turns = 2 + checkStream(record.stream):nextU16("rampage_confusion", causeFor(record)) % 4
            local entry = ctx:entryOf(user)
            assert(entry.activation ~= nil, "rampage confusion scopes to its live entry")
            ctx:addBattleEffect(
              NativeEffectHandlers.definitionFor("confusion"),
              { kind = "active", combatant = user, activation = entry.activation },
              causeFor(record),
              { version = 1, turns = turns }
            )
          end
        end
      else
        local turns = 2
        if marker == "UPROAR" then
          turns = 3
        else
          turns = 2 + checkStream(record.stream):nextU16("rampage_duration", causeFor(record)) % 2
        end
        local function beginLock(current)
          current.lock = { move = marker, remaining = turns - 1 }
          return current
        end
        SequenceMoveState.update(ctx, user, causeFor(record), beginLock)
        if marker == "UPROAR" then
          local entry = ctx:entryOf(user)
          assert(entry.activation ~= nil, "Uproar scopes to its live entry")
          ctx:addBattleEffect(
            NativeEffectHandlers.definitionFor("uproar"),
            { kind = "active", combatant = user, activation = entry.activation },
            causeFor(record),
            { version = 1, turns = turns }
          )
        end
      end
    end
    return { kind = "complete", result = "hit" }
  end
  return stepLockStrike
end

-- Rollout and Ice Ball force five consecutive strikes; Fury Cutter keeps
-- its multiplier only across consecutive native turns.
---@param cap integer maximum doublings under the source sequence rule
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler striking at the current rung
local function makeRampStrike(cap)
  local function stepRampStrike(ctx, frame)
    assert(type(ctx) == "table", "sequences step through the battle context")
    assert(type(frame) == "table", "sequences step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    local move = record.executingMove --[[@as string]]
    local state = SequenceMoveState.read(ctx, userOf(record))
    local duel = (record.locals --[[@as table<string, unknown>]]).duel
    if
      type(duel) ~= "table" or type((duel --[[@as table<string, unknown>]]).userTurn) ~= "number"
    then
      error(BattleErrors.missingBehavior("ramp strikes read their native turn", {
        key = move,
        fact = "userTurn",
      }))
    end
    local currentTurn = (duel --[[@as table<string, unknown>]]).userTurn --[[@as integer]]
    local prior = state ~= nil and state.ramp or nil
    local rung = 0
    if type(prior) == "table" and prior.move == move and prior.turn == currentTurn - 1 then
      rung = prior.count --[[@as integer]]
    end
    rung = math.min(rung + 1, cap + 1)
    local power = strikePowerOf(record)
    for _ = 2, rung do
      power = power * 2
    end
    local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
    strikeTarget(ctx, record, defender, power)
    local user = userOf(record)
    local locked = move == "ROLLOUT" or move == "ICE_BALL"
    local function advanceRamp(current)
      if locked and rung < cap + 1 then
        current.lock = { move = move, remaining = cap + 1 - rung }
      else
        current.lock = nil
      end
      if move == "FURY_CUTTER" then
        current.ramp = { move = move, count = rung, turn = currentTurn }
      elseif locked and rung < cap + 1 then
        current.ramp = { move = move, count = rung, turn = currentTurn }
      else
        current.ramp = nil
      end
      return current
    end
    SequenceMoveState.update(ctx, user, causeFor(record), advanceRamp)
    return { kind = "complete", result = "hit" }
  end
  return stepRampStrike
end

-- Protect, Detect, and Endure share the native consecutive-use check.
-- Their guard lives through the current turn and expires in residuals.
---@param guarded boolean true when the bracket shields the user this turn
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler recording the bracket
local function makeProtection(guarded)
  local function stepProtection(ctx, frame)
    assert(type(ctx) == "table", "sequences step through the battle context")
    assert(type(frame) == "table", "sequences step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    local locals = record.locals --[[@as table<string, unknown>]]
    local duel = locals.duel
    if type(duel) ~= "table" then
      error(BattleErrors.missingBehavior("protection reads its turn streak", {
        key = record.executingMove --[[@as string]],
        fact = "duel",
      }))
    end
    local currentTurn = (duel --[[@as table<string, unknown>]]).userTurn
    if type(currentTurn) ~= "number" or currentTurn % 1 ~= 0 or currentTurn < 0 then
      error(BattleErrors.missingBehavior("protection reads its native turn", {
        key = record.executingMove --[[@as string]],
        fact = "userTurn",
      }))
    end
    local user = userOf(record)
    local previous = nil
    local function readPrevious(state)
      previous = state
      return state
    end
    ctx:updateBattleEffect(user, PROTECT_STREAK, readPrevious)
    local streak = 0
    if type(previous) == "table" then
      local prior = previous --[[@as table<string, unknown>]]
      if prior.turn == currentTurn - 1 then
        streak = prior.count --[[@as integer]]
      end
    end
    local chances = { 65535, 32767, 16383, 8191 }
    local chance = chances[streak + 1]
    local roll = checkStream(record.stream):nextU16("protection_success", causeFor(record))
    local active = ctx:activeCombatants()
    local success = chance >= roll and #active > 1
    local nextStreak = success and math.min(streak + 1, 3) or 0
    local function writeStreak(_)
      return { version = 1, turn = currentTurn, count = nextStreak }
    end
    if ctx:updateBattleEffect(user, PROTECT_STREAK, writeStreak) == nil then
      local entry = ctx:entryOf(user)
      assert(entry.activation ~= nil, "protection streak scopes to its live entry")
      ctx:addBattleEffect(
        PROTECT_STREAK,
        { kind = "active", combatant = user, activation = entry.activation },
        causeFor(record),
        { version = 1, turn = currentTurn, count = nextStreak }
      )
    end
    if not success then
      return { kind = "complete", result = "failed" }
    end
    local effectKey = string.lower(record.executingMove --[[@as string]])
    local entry = ctx:entryOf(user)
    assert(entry.activation ~= nil, "protection scopes to its live entry")
    ctx:addBattleEffect(
      NativeEffectHandlers.definitionFor(effectKey),
      { kind = "active", combatant = user, activation = entry.activation },
      causeFor(record),
      { version = 1, turns = 1 }
    )
    if guarded then
      ctx:emit("protected", causeFor(record), { target = user })
    else
      ctx:emit("move-used", causeFor(record), { user = user, targets = 1 })
    end
    return { kind = "complete", result = "hit" }
  end
  return stepProtection
end

-- Focus Punch resolves its strike unless the frame records a hit taken
-- while focusing; without that record the focus holds.
local function stepFocusPunch(ctx, frame)
  assert(type(ctx) == "table", "sequences step through the battle context")
  assert(type(frame) == "table", "sequences step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  if locals.wasHit == true then
    return { kind = "complete", result = "failed" }
  end
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  strikeTarget(ctx, record, defender)
  return { kind = "complete", result = "hit" }
end

-- Sucker Punch checks the defender's selected move before committing its
-- strike, matching BtlCmd_TrySuckerPunch in src/battle/battle_command.c.
local function stepSuckerPunch(ctx, frame)
  assert(type(ctx) == "table", "sequences step through the battle context")
  assert(type(frame) == "table", "sequences step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local duel = locals.duel
  if type(duel) ~= "table" then
    error(BattleErrors.missingBehavior("Sucker Punch reads the target's selected move", {
      key = record.executingMove --[[@as string]],
      fact = "duel",
    }))
  end
  local foeSelectedDamage = (duel --[[@as table<string, unknown>]]).foeSelectedDamage
  if type(foeSelectedDamage) ~= "boolean" then
    error(BattleErrors.missingBehavior("Sucker Punch reads the target's selected move", {
      key = record.executingMove --[[@as string]],
      fact = "foeSelectedDamage",
    }))
  end
  if not foeSelectedDamage then
    return { kind = "complete", result = "failed" }
  end
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  strikeTarget(ctx, record, defender)
  return { kind = "complete", result = "hit" }
end

-- Fake Out strikes once and records the flinch on the sampled target.
local function stepFakeOut(ctx, frame)
  assert(type(ctx) == "table", "sequences step through the battle context")
  assert(type(frame) == "table", "sequences step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local duel = locals.duel
  if type(duel) ~= "table" then
    error(BattleErrors.missingBehavior("Fake Out reads whether the user is on its first turn", {
      key = record.executingMove --[[@as string]],
      fact = "duel",
    }))
  end
  local userFresh = (duel --[[@as table<string, unknown>]]).userFresh
  if type(userFresh) ~= "boolean" then
    error(BattleErrors.missingBehavior("Fake Out reads whether the user is on its first turn", {
      key = record.executingMove --[[@as string]],
      fact = "userFresh",
    }))
  end
  if not userFresh then
    return { kind = "complete", result = "failed" }
  end
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  strikeTarget(ctx, record, defender)
  local abilities = locals.abilities --[[@as table<string, unknown>]]
  if not ctx:hasBattleEffect(defender, "substitute") and abilities.foe ~= "INNER_FOCUS" then
    markFlinch(ctx, defender)
  end
  return { kind = "complete", result = "hit" }
end

-- Pursuit resolves before a selected switch and doubles against that
-- departing target, as in BtlCmd_CalcPursuitPower.
local function stepPursuit(ctx, frame)
  assert(type(ctx) == "table", "sequences step through the battle context")
  assert(type(frame) == "table", "sequences step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  local duel = (record.locals --[[@as table<string, unknown>]]).duel
  if
    type(duel) ~= "table" or type((duel --[[@as table<string, unknown>]]).foeSwitching) ~= "boolean"
  then
    error(BattleErrors.missingBehavior("Pursuit reads the target's switch choice", {
      key = record.executingMove --[[@as string]],
      fact = "foeSwitching",
    }))
  end
  local power = strikePowerOf(record)
  if
    (duel --[[@as table<string, unknown>]]).foeSwitching == true
  then
    power = power * 2
  end
  strikeTarget(ctx, record, defender, power)
  return { kind = "complete", result = "hit" }
end

-- Switch control emits its intent and completes; the native session owns the roster exchange.
---@param mode string switch-control mode under the intent
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler emitting the switch intent
local function makeSwitchIntent(mode)
  local function stepSwitchIntent(ctx, frame)
    assert(type(ctx) == "table", "sequences step through the battle context")
    assert(type(frame) == "table", "sequences step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    ctx:emit("switch-intent", causeFor(record), {
      target = targetOf((record.targets --[[@as table<integer, unknown>]])[1]),
      mode = mode,
    })
    return { kind = "complete", result = "hit" }
  end
  return stepSwitchIntent
end

-- Future Sight and Doom Desire snapshot their damage at launch, then
-- resolve from the position's residual slot after the native countdown.
---@param frame table<string, unknown> launch move frame
---@param defender integer target combatant occupying the bound slot
---@return integer launch-time damage after the native damage range
local function delayedDamage(frame, defender)
  local record = frame --[[@as table<string, unknown>]]
  local power = strikePowerOf(record)
  local combat = combatOf(record)
  local stream = checkStream(record.stream)
  local stab, effectiveness = StagedTypeModifiers.forDelayedImpact(record, defender)
  local move = (record.locals --[[@as table<string, unknown>]]).move --[[@as table<string, unknown>]]
  local category = move.category
  if category ~= "physical" and category ~= "special" then
    error(BattleErrors.missingBehavior("sequences read their immutable move facts", {
      key = record.executingMove --[[@as string]],
      fact = "category",
    }))
  end
  local result = Damage.calculate({
    level = combat.level,
    power = power,
    attack = combat.attack,
    defense = combat.defense,
    rawAttack = combat.rawAttack,
    rawDefense = combat.rawDefense,
    attackStage = combat.attackStage,
    defenseStage = combat.defenseStage,
    criticalMultiplier = 1,
    category = category --[[@as string]],
    burned = false,
    guts = false,
    stab = stab,
    effectiveness = { numerator = effectiveness.numerator, denominator = effectiveness.denominator },
    effectivenessFactors = effectiveness.factors,
    weather = "none",
    weatherSuppressed = false,
    moveType = "typeless",
    solarBeam = false,
  }, stream)
  return result.amount
end

---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler scheduling the delayed strike
local function makeDelayed()
  local function stepDelayed(ctx, frame)
    assert(type(ctx) == "table", "sequences step through the battle context")
    assert(type(frame) == "table", "sequences step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    local user = userOf(record)
    local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
    local targetEntry = ctx:entryOf(defender)
    assert(type(targetEntry.position) == "number", "delayed damage binds the target position")
    if
      ctx:hasPositionEffect(targetEntry.position --[[@as integer]], "futuresight")
    then
      return { kind = "complete", result = "failed" }
    end
    local sourceEntry = ctx:entryOf(user)
    assert(type(sourceEntry.activation) == "number", "delayed damage records the source activation")
    local duel = (record.locals --[[@as table<string, unknown>]]).duel
    if
      type(duel) ~= "table" or type((duel --[[@as table<string, unknown>]]).userTurn) ~= "number"
    then
      error(BattleErrors.missingBehavior("delayed attacks read their launch turn", {
        key = record.executingMove --[[@as string]],
        fact = "userTurn",
      }))
    end
    local launchTurn = (duel --[[@as table<string, unknown>]]).userTurn --[[@as integer]]
    local damage = delayedDamage(record, defender)
    ctx:addBattleEffect(NativeEffectHandlers.definitionFor("futuresight"), {
      kind = "position",
      position = targetEntry.position --[[@as integer]],
    }, {
      kind = "move",
      combatant = user,
      activation = sourceEntry.activation --[[@as integer]],
    }, {
      version = 1,
      turns = 3,
      damage = damage,
      move = record.executingMove,
      attacker = user,
      activation = sourceEntry.activation,
      turn = launchTurn,
    })
    ctx:emit("delayed", causeFor(record), { target = defender })
    return { kind = "complete", result = "hit" }
  end
  return stepDelayed
end

-- Destiny Bond and Grudge record their faint-reactive markers; the
-- reaction itself settles through the faint owner.
---@param marker string reactive identity recorded on the user
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler recording the reactive marker
local function makeReactive(marker)
  local function stepReactive(ctx, frame)
    assert(type(ctx) == "table", "sequences step through the battle context")
    assert(type(frame) == "table", "sequences step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    local user = userOf(record)
    local key = marker == "DESTINY_BOND" and "destinybond" or "grudge"
    if ctx:hasBattleEffect(user, key) then
      return { kind = "complete", result = "failed" }
    end
    local entry = ctx:entryOf(user)
    assert(entry.activation ~= nil, "reactive move effects scope to their live entry")
    ctx:addBattleEffect(
      NativeEffectHandlers.definitionFor(key),
      { kind = "active", combatant = user, activation = entry.activation },
      causeFor(record),
      { version = 1, turns = 1 }
    )
    ctx:emit("move-used", causeFor(record), {
      user = userOf(record),
      targets = #record.targets,
    })
    return { kind = "complete", result = "hit" }
  end
  return stepReactive
end

-- Stockpile stores its use count and the defense raises that actually
-- succeeded. Spit Up and Swallow consume those exact counters.
local function stepStockpile(ctx, frame)
  assert(type(ctx) == "table", "sequences step through the battle context")
  assert(type(frame) == "table", "sequences step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local entry = ctx:entryOf(user)
  assert(entry.activation ~= nil, "Stockpile scopes to its live entry")
  local updated = nil
  local function updateStockpile(state)
    if state.count >= 3 then
      return state
    end
    local count = state.count + 1
    local oldDefense = entry.stages.defense --[[@as integer]]
    local oldSpecialDefense = entry.stages.specialDefense --[[@as integer]]
    local defense = StatStages.change(oldDefense, 1)
    local specialDefense = StatStages.change(oldSpecialDefense, 1)
    local defenseBoosts = state.defenseBoosts
    local specialDefenseBoosts = state.specialDefenseBoosts
    if defense > oldDefense then
      ctx:changeStage(user, "defense", defense, causeFor(record))
      defenseBoosts = defenseBoosts + 1
    end
    if specialDefense > oldSpecialDefense then
      ctx:changeStage(user, "specialDefense", specialDefense, causeFor(record))
      specialDefenseBoosts = specialDefenseBoosts + 1
    end
    updated = { version = 1, count = count, defenseBoosts = defenseBoosts, specialDefenseBoosts = specialDefenseBoosts }
    return updated
  end
  local outcome = ctx:updateBattleEffect(user, STOCKPILE, updateStockpile)
  if outcome == nil then
    local oldDefense = entry.stages.defense --[[@as integer]]
    local oldSpecialDefense = entry.stages.specialDefense --[[@as integer]]
    local defense = StatStages.change(oldDefense, 1)
    local specialDefense = StatStages.change(oldSpecialDefense, 1)
    if defense > oldDefense then
      ctx:changeStage(user, "defense", defense, causeFor(record))
    end
    if specialDefense > oldSpecialDefense then
      ctx:changeStage(user, "specialDefense", specialDefense, causeFor(record))
    end
    updated = {
      version = 1,
      count = 1,
      defenseBoosts = defense > oldDefense and 1 or 0,
      specialDefenseBoosts = specialDefense > oldSpecialDefense and 1 or 0,
    }
    ctx:addBattleEffect(
      STOCKPILE,
      { kind = "active", combatant = user, activation = entry.activation },
      causeFor(record),
      updated
    )
  elseif updated == nil then
    return { kind = "complete", result = "failed" }
  end
  ctx:emit("move-used", causeFor(record), {
    user = user,
    targets = #record.targets,
  })
  return { kind = "complete", result = "hit" }
end

local function stepStockpileRelease(ctx, frame)
  assert(type(ctx) == "table", "sequences step through the battle context")
  assert(type(frame) == "table", "sequences step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local state = takeStockpile(ctx, user)
  if state == nil then
    return { kind = "complete", result = "failed" }
  end
  local stored = state --[[@as table<string, unknown>]]
  local entry = ctx:entryOf(user)
  local defense = math.max(-6, entry.stages.defense --[[@as integer]] - stored.defenseBoosts --[[@as integer]])
  local specialDefense =
    math.max(-6, entry.stages.specialDefense --[[@as integer]] - stored.specialDefenseBoosts --[[@as integer]])
  if defense ~= entry.stages.defense then
    ctx:changeStage(user, "defense", defense, causeFor(record))
  end
  if specialDefense ~= entry.stages.specialDefense then
    ctx:changeStage(user, "specialDefense", specialDefense, causeFor(record))
  end
  if record.executingMove == "SPIT_UP" then
    local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
    strikeTarget(ctx, record, defender, stored.count --[[@as integer]] * 100)
  else
    local amount = math.floor(
      entry.maxHp --[[@as integer]]
        / (
          2 ^ (
            4 - stored.count --[[@as integer]]
          )
        )
    )
    local healed = ctx:heal(user, amount, causeFor(record))
    if healed.after == healed.before then
      return { kind = "complete", result = "failed" }
    end
    ctx:emit("healed", causeFor(record), { target = user, restored = healed.after - healed.before, noBlink = true })
  end
  ctx:emit("move-used", causeFor(record), { user = user, targets = #record.targets })
  return { kind = "complete", result = "hit" }
end

-- Charge and Follow Me record their cooperation markers, and Helping
-- Hand records its own once its ally check passes; redirection and ally
-- boosting resolve through the targeting owner.
---@param marker string cooperation identity recorded on the user
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler recording the cooperation marker
local function makeCooperation(marker)
  local function stepCooperation(ctx, frame)
    assert(type(ctx) == "table", "sequences step through the battle context")
    assert(type(frame) == "table", "sequences step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    local user = userOf(record)
    if marker == "FOLLOW_ME" then
      local entry = ctx:entryOf(user)
      assert(entry.activation ~= nil, "Follow Me scopes to its live entry")
      ctx:addBattleEffect(
        NativeEffectHandlers.definitionFor("followme"),
        { kind = "active", combatant = user, activation = entry.activation },
        causeFor(record),
        { version = 1, turns = 1 }
      )
    elseif marker == "MAGIC_COAT" or marker == "SNATCH" then
      local entry = ctx:entryOf(user)
      assert(entry.activation ~= nil, "turn interference scopes to its live entry")
      local key = marker == "MAGIC_COAT" and "magiccoat" or "snatch"
      ctx:addBattleEffect(
        NativeEffectHandlers.definitionFor(key),
        { kind = "active", combatant = user, activation = entry.activation },
        causeFor(record),
        { version = 1, turns = 1 }
      )
    elseif marker == "CHARGE" then
      local entry = ctx:entryOf(user)
      assert(entry.activation ~= nil, "Charge scopes to its live entry")
      local oldSpecialDefense = entry.stages.specialDefense --[[@as integer]]
      local newSpecialDefense = StatStages.change(oldSpecialDefense, 1)
      if newSpecialDefense > oldSpecialDefense then
        ctx:changeStage(user, "specialDefense", newSpecialDefense, causeFor(record))
      end
      local function armElectricBoost(state)
        state.electricBoost = true
        return state
      end
      SequenceMoveState.update(ctx, user, causeFor(record), armElectricBoost)
    else
      markVolatile(ctx, user, marker)
    end
    ctx:emit("move-used", causeFor(record), {
      user = userOf(record),
      targets = #record.targets,
    })
    return { kind = "complete", result = "hit" }
  end
  return stepCooperation
end

-- Helping Hand boosts a live ally: with no partner standing the sampled
-- recipients collapse onto the user, so the move fails instead of boosting
-- its own user. Source reference: BtlCmd_TryHelpingHand in
-- src/battle/battle_command.c.
local helpingHandCooperation = makeCooperation("HELPING_HAND")

local function stepHelpingHand(ctx, frame)
  assert(type(ctx) == "table", "sequences step through the battle context")
  assert(type(frame) == "table", "sequences step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  for _, entry in
    ipairs(record.targets --[[@as table<integer, unknown>]])
  do
    if targetOf(entry) ~= user then
      return helpingHandCooperation(ctx, frame)
    end
  end
  return { kind = "complete", result = "failed" }
end

---@param key string sequence move identity under binding
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> distinct per-move handler for the registry
local function bodyFor(key)
  if DELAYED[key] == true then
    return bind(makeDelayed())
  end
  if key == "ROLLOUT" or key == "ICE_BALL" then
    return bind(makeRampStrike(4))
  end
  if key == "FURY_CUTTER" then
    return bind(makeRampStrike(4))
  end
  if key == "PROTECT" or key == "DETECT" then
    return bind(makeProtection(true))
  end
  if key == "SUBSTITUTE" then
    return bind(stepSubstitute)
  end
  if key == "ENDURE" then
    return bind(makeProtection(false))
  end
  if key == "MAGIC_COAT" or key == "SNATCH" then
    return bind(makeCooperation(key))
  end
  if key == "FOCUS_PUNCH" then
    return bind(stepFocusPunch)
  end
  if key == "SUCKER_PUNCH" then
    return bind(stepSuckerPunch)
  end
  if key == "FAKE_OUT" then
    return bind(stepFakeOut)
  end
  if key == "PURSUIT" then
    return bind(stepPursuit)
  end
  if key == "RAGE" then
    return bind(stepRage)
  end
  if SWITCH_MODES[key] ~= nil then
    return bind(makeSwitchIntent(SWITCH_MODES[key]))
  end
  if key == "DESTINY_BOND" or key == "GRUDGE" then
    return bind(makeReactive(key))
  end
  if key == "STOCKPILE" then
    return bind(stepStockpile)
  end
  if key == "SPIT_UP" or key == "SWALLOW" then
    return bind(stepStockpileRelease)
  end
  if key == "HELPING_HAND" then
    return bind(stepHelpingHand)
  end
  if key == "CHARGE" or key == "FOLLOW_ME" then
    return bind(makeCooperation(key))
  end
  if LOCKED[key] == true then
    return bind(makeLockStrike(key))
  end
  if RECHARGE[key] == true then
    return bind(makeLockStrike("RECHARGE"))
  end
  if CHARGE[key] == true then
    return bind(makeChargeStrike())
  end
  error(BattleErrors.missingBehavior("no sequence handler is bound for the source identity", { key = key }))
end

--- Binds the sequence family handlers into the owner table.
---@param owned table<string, fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown>> handler owner receiving the family bindings
function SequenceMoves.register(owned)
  assert(type(owned) == "table", "sequence moves register into their owner table")
  for _, key in ipairs(SequenceMoves.MEMBERS) do
    owned[key] = bodyFor(key)
  end
end

return SequenceMoves
