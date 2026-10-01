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

-- Reference combat inputs matching the damage family triple, used only
-- when the frame carries no explicit combat facts.
local REFERENCE_LEVEL = 10
local REFERENCE_ATTACK = 50
local REFERENCE_DEFENSE = 50

-- Curated strike powers for the immediate-strike reduction of charging,
-- recharge, rampage, and interruption members.
local STRIKE_POWER = {
  FLY = 70,
  DIG = 80,
  DIVE = 80,
  BOUNCE = 85,
  SHADOW_FORCE = 120,
  SKULL_BASH = 100,
  SKY_ATTACK = 140,
  RAZOR_WIND = 80,
  SOLAR_BEAM = 120,
  HYPER_BEAM = 150,
  GIGA_IMPACT = 150,
  FRENZY_PLANT = 150,
  BLAST_BURN = 150,
  HYDRO_CANNON = 150,
  ROAR_OF_TIME = 150,
  THRASH = 90,
  OUTRAGE = 120,
  PETAL_DANCE = 90,
  UPROAR = 90,
  RAGE = 20,
  FOCUS_PUNCH = 150,
  FAKE_OUT = 40,
  PURSUIT = 40,
}

-- Members whose strike locks the user into a multi-action sequence; the
-- marker names the lock for the scheduling owner.
local LOCKED = {
  THRASH = true,
  OUTRAGE = true,
  PETAL_DANCE = true,
  UPROAR = true,
  RAGE = true,
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

-- Forced-switch control modes emitted as switch intents; settlement
-- itself stays with the switching owner.
local SWITCH_MODES = {
  U_TURN = "strike-and-leave",
  BATON_PASS = "pass-markers",
  WHIRLWIND = "force-foe-out",
  ROAR = "force-foe-out",
}

-- Delayed-attack powers beside their scheduling bodies.
local DELAYED_POWER = {
  FUTURE_SIGHT = 80,
  DOOM_DESIRE = 140,
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
  return { key = frame.executingMove }
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

---@param frame table<string, unknown> move frame under execution
---@return table<string, integer> staged combat inputs for the arithmetic owner
local function combatOf(frame)
  local locals = frame.locals --[[@as table<string, unknown>]]
  local facts = locals.combat
  local level, attack, defense = REFERENCE_LEVEL, REFERENCE_ATTACK, REFERENCE_DEFENSE
  if type(facts) == "table" then
    local record = facts --[[@as table<string, unknown>]]
    if type(record.level) == "number" then
      level = record.level --[[@as integer]]
    end
    if type(record.attack) == "number" then
      attack = record.attack --[[@as integer]]
    end
    if type(record.defense) == "number" then
      defense = record.defense --[[@as integer]]
    end
  end
  return { level = level, attack = attack, defense = defense }
end

---@param ctx BattleContext mechanics context under execution
---@param combatant integer combatant receiving the volatile marker
---@param key string volatile identity under the marker
local function markVolatile(ctx, combatant, key)
  ctx:addEffect(combatant, { key = key, scope = "volatile" })
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the strike
---@param power integer curated move power under the staged arithmetic
---@return integer damage dealt by the strike
local function strikeTarget(ctx, frame, defender, power)
  local record = frame --[[@as table<string, unknown>]]
  local combat = combatOf(record)
  local stream = checkStream(record.stream)
  local resolution = Accuracy.resolve({
    target = { kind = "combatant" },
    cause = causeFor(record),
    protected = false,
    skipCheck = true,
  }, stream)
  assert(resolution.kind == "hit", "unrolled checks always connect")
  local critical = Critical.resolve(0, stream, causeFor(record))
  local result = Damage.calculate({
    level = combat.level,
    power = power,
    attack = combat.attack,
    defense = combat.defense,
    stab = { numerator = 1, denominator = 1 },
    effectiveness = { numerator = 1, denominator = 1 },
    critical = critical.critical,
  }, stream)
  local outcome = ctx:damage(defender, result.amount, causeFor(record))
  ctx:emit("struck", causeFor(record), { target = defender, hitIndex = 1, damage = outcome.before - outcome.after })
  return outcome.before - outcome.after
end

---@param handler fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> shared family body under binding
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> distinct per-move binding over the shared body
local function bind(handler)
  local function stepBound(ctx, frame)
    return handler(ctx, frame)
  end
  return stepBound
end

-- Charging strikes land their immediate-strike reduction after recording
-- the charge; the two-turn shape belongs to the scheduling owner, so the
-- single action resolves the strike it can observe.
---@param power integer curated strike power under the charge
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler charging then striking
local function makeChargeStrike(power)
  local function stepChargeStrike(ctx, frame)
    assert(type(ctx) == "table", "sequences step through the battle context")
    assert(type(frame) == "table", "sequences step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    ctx:emit("charged", causeFor(record), { target = userOf(record) })
    local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
    strikeTarget(ctx, record, defender, power)
    return { kind = "complete", result = "hit" }
  end
  return stepChargeStrike
end

-- Recharge and rampage strikes land then record their lock for the
-- scheduling owner.
---@param power integer curated strike power under the lock
---@param marker string lock identity recorded on the user
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler striking then locking
local function makeLockStrike(power, marker)
  local function stepLockStrike(ctx, frame)
    assert(type(ctx) == "table", "sequences step through the battle context")
    assert(type(frame) == "table", "sequences step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
    strikeTarget(ctx, record, defender, power)
    markVolatile(ctx, userOf(record), marker)
    return { kind = "complete", result = "hit" }
  end
  return stepLockStrike
end

-- Rollout-class strikes double their base while the sequence continues;
-- the ramp counter lives in the frame locals, so one observed action
-- resolves its current rung and records the next.
---@param base integer ramp base power under the sequence
---@param cap integer maximum doublings under the sequence
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler striking at the current rung
local function makeRampStrike(base, cap)
  local function stepRampStrike(ctx, frame)
    assert(type(ctx) == "table", "sequences step through the battle context")
    assert(type(frame) == "table", "sequences step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    local locals = record.locals --[[@as table<string, unknown>]]
    local rung = 0
    if type(locals.ramp) == "number" then
      rung = locals.ramp --[[@as integer]]
    end
    if rung > cap then
      rung = cap
    end
    local power = base
    for _ = 1, rung do
      power = power * 2
    end
    locals.ramp = rung + 1
    local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
    strikeTarget(ctx, record, defender, power)
    return { kind = "complete", result = "hit" }
  end
  return stepRampStrike
end

-- Protection records its bracket; consecutive-use failure odds need the
-- previous-action record, so the first observed use always holds. Endure
-- and Substitute record their own markers without claiming protection.
---@param guarded boolean true when the bracket shields the user this turn
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler recording the bracket
local function makeProtection(guarded)
  local function stepProtection(ctx, frame)
    assert(type(ctx) == "table", "sequences step through the battle context")
    assert(type(frame) == "table", "sequences step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    markVolatile(ctx, userOf(record), record.executingMove --[[@as string]])
    if guarded then
      ctx:emit("protected", causeFor(record), { target = userOf(record) })
    else
      ctx:emit("move-used", causeFor(record), { targets = 1 })
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
  strikeTarget(ctx, record, defender, STRIKE_POWER.FOCUS_PUNCH)
  return { kind = "complete", result = "hit" }
end

-- Sucker Punch needs the defender damaging intent, which the frame
-- protocol does not thread; without it the punch fails instead of
-- guessing the defender plan.
local function stepSuckerPunch(ctx, frame)
  assert(type(ctx) == "table", "sequences step through the battle context")
  assert(type(frame) == "table", "sequences step from their move frame")
  return { kind = "complete", result = "failed" }
end

-- Fake Out strikes once and records the flinch on the sampled target.
local function stepFakeOut(ctx, frame)
  assert(type(ctx) == "table", "sequences step through the battle context")
  assert(type(frame) == "table", "sequences step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  strikeTarget(ctx, record, defender, STRIKE_POWER.FAKE_OUT)
  markVolatile(ctx, defender, "FLINCH")
  return { kind = "complete", result = "hit" }
end

-- Pursuit strikes at its observed power; the switch-chase doubling needs
-- the defender departure record, so the base strike resolves here.
local function stepPursuit(ctx, frame)
  assert(type(ctx) == "table", "sequences step through the battle context")
  assert(type(frame) == "table", "sequences step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  strikeTarget(ctx, record, defender, STRIKE_POWER.PURSUIT)
  return { kind = "complete", result = "hit" }
end

-- Forced-switch control emits its switch intent for the switching owner
-- and completes; no roster is moved by the move layer.
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

-- Delayed attacks schedule on the first step and land on the resume. The
-- resumed frame binds the defender slot plus the attacker snapshot, so
-- the hit resolves even after the attacker leaves.
---@param power integer delayed strike power under the landing
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler scheduling then landing the delay
local function makeDelayed(power)
  local function stepDelayed(ctx, frame)
    assert(type(ctx) == "table", "sequences step through the battle context")
    assert(type(frame) == "table", "sequences step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    local locals = record.locals --[[@as table<string, unknown>]]
    if locals.phase == "impact" then
      local defender = locals.defender --[[@as integer]]
      assert(type(defender) == "number", "delayed damage binds its defender slot")
      local combat = combatOf(record)
      local stream = checkStream(record.stream)
      local result = Damage.calculate({
        level = combat.level,
        power = power,
        attack = combat.attack,
        defense = combat.defense,
        stab = { numerator = 1, denominator = 1 },
        effectiveness = { numerator = 1, denominator = 1 },
      }, stream)
      local outcome = ctx:damage(defender, result.amount, causeFor(record))
      ctx:emit("struck", causeFor(record), {
        target = defender,
        hitIndex = 1,
        damage = outcome.before - outcome.after,
      })
      return { kind = "complete", result = "hit" }
    end
    ctx:emit("delayed", causeFor(record), {
      target = targetOf((record.targets --[[@as table<integer, unknown>]])[1]),
    })
    local resumed = {}
    for key, value in pairs(record) do
      resumed[key] = value
    end
    local nextLocals = {}
    for key, value in pairs(locals) do
      nextLocals[key] = value
    end
    nextLocals.phase = "impact"
    nextLocals.defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
    nextLocals.attacker = (record.actor --[[@as table<string, unknown>]]).combatant
    resumed.locals = nextLocals
    return { kind = "push", frame = resumed }
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
    markVolatile(ctx, userOf(record), marker)
    ctx:emit("move-used", causeFor(record), {
      targets = #record.targets,
    })
    return { kind = "complete", result = "hit" }
  end
  return stepReactive
end

-- Stockpile records its accumulating marker; Spit Up and Swallow need the
-- accumulated stacks the frame protocol does not thread, so without them
-- they fail instead of striking blindly.
local function stepStockpile(ctx, frame)
  assert(type(ctx) == "table", "sequences step through the battle context")
  assert(type(frame) == "table", "sequences step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  markVolatile(ctx, userOf(record), "STOCKPILE")
  ctx:emit("move-used", causeFor(record), {
    targets = #record.targets,
  })
  return { kind = "complete", result = "hit" }
end

local function stepStockpileRelease(ctx, frame)
  assert(type(ctx) == "table", "sequences step through the battle context")
  assert(type(frame) == "table", "sequences step from their move frame")
  return { kind = "complete", result = "failed" }
end

-- Charge, Follow Me, and Helping Hand record their cooperation markers;
-- redirection and ally boosting resolve through the targeting owner.
---@param marker string cooperation identity recorded on the user
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler recording the cooperation marker
local function makeCooperation(marker)
  local function stepCooperation(ctx, frame)
    assert(type(ctx) == "table", "sequences step through the battle context")
    assert(type(frame) == "table", "sequences step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    markVolatile(ctx, userOf(record), marker)
    ctx:emit("move-used", causeFor(record), {
      targets = #record.targets,
    })
    return { kind = "complete", result = "hit" }
  end
  return stepCooperation
end

---@param key string sequence move identity under binding
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> distinct per-move handler for the registry
local function bodyFor(key)
  if DELAYED_POWER[key] ~= nil then
    return bind(makeDelayed(DELAYED_POWER[key]))
  end
  if key == "ROLLOUT" or key == "ICE_BALL" then
    return bind(makeRampStrike(30, 4))
  end
  if key == "FURY_CUTTER" then
    return bind(makeRampStrike(10, 4))
  end
  if key == "PROTECT" or key == "DETECT" then
    return bind(makeProtection(true))
  end
  if key == "ENDURE" or key == "SUBSTITUTE" then
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
  if key == "CHARGE" or key == "FOLLOW_ME" or key == "HELPING_HAND" then
    return bind(makeCooperation(key))
  end
  if LOCKED[key] == true then
    return bind(makeLockStrike(STRIKE_POWER[key], key))
  end
  if RECHARGE[key] == true then
    return bind(makeLockStrike(STRIKE_POWER[key], "RECHARGE"))
  end
  if STRIKE_POWER[key] ~= nil then
    return bind(makeChargeStrike(STRIKE_POWER[key]))
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
