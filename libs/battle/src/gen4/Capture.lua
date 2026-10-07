-- Exact native catch and shake arithmetic plus the single owned throw path.
-- Native anchor: BattleSystem_CalculateBallShakes (battle command flow):
-- the rate and the tenths-fixed ball multiplier stage first with
-- left-to-right integer floors, sleep and freeze double the odds while
-- burn, paralysis, and poison add half, full odds guarantee the catch, and
-- each of the four shake checks spends one labeled draw until the first
-- failure. The ball leaves at the throw before any shake is staged; illegal
-- throws fail before spend with zero draws spent. A landed throw returns
-- the existing target record unchanged and claims no placement: retention
-- stays with the later committer. Visible shakes cap at three staged
-- checks while the catch needs all four probability checks; apricorn rate
-- bonuses adjust the rate before the clamp, and the safari stage adjusts
-- the rate at the throw from battle-local format state.

local Errors = require("libs.errors.src.Errors")
local CaptureContext = require("libs.battle.src.gen4.CaptureContext")
local CaptureFormats = require("libs.battle.src.gen4.formats.CaptureFormats")

---@alias ParticipantId integer
---@alias CombatantId integer
---@alias PersistentMonSource table<string, unknown>

---@class CombatantRef
---@field combatant integer
---@field activation integer?

---@class CaptureAttempt
---@field actor ParticipantId
---@field inventoryId string?
---@field ball string
---@field target CombatantRef

---@class CaptureResult
---@field id integer
---@field target CombatantId
---@field source PersistentMonSource?
---@field ball string
---@field mon table<string, unknown>
---@field shakes integer
---@field context CaptureContext
---@field success boolean

---@class CaptureCalculation
---@field success boolean
---@field shakes integer
---@field reason string
---@field odds integer
---@field threshold integer?

local Capture = {}

Capture.CONSUMPTION_CHECKPOINT = "capture_throw"
Capture.SHAKE_LABEL = "capture:shake"
--- Visible shakes reported to presentation, capped below the probability law.
Capture.MAX_SHAKES = 3
--- Probability checks a non-guaranteed throw must pass to land the catch.
Capture.PROBABILITY_CHECKS = 4
Capture.GUARANTEED_ODDS = 255
Capture.DEFAULT_CATCH_RATE = 45

---@param code string refusal code under report
---@param message string human-readable reason under report
---@param context table<string, unknown>? structured blame under report
---@return Errors.Error typed failure carrying the refusal code
local function failure(code, message, context)
  return Errors.new(code, message, context or { code = code })
end

---@param types unknown candidate type list under inspection
---@param wanted string[] type keys staging the bonus
---@return boolean true when a listed type is present
local function hasAnyType(types, wanted)
  if type(types) ~= "table" then
    return false
  end
  for _, entry in
    ipairs(types --[[@as string[] ]])
  do
    for _, key in ipairs(wanted) do
      if entry == key then
        return true
      end
    end
  end
  return false
end

---@param level number target level under staging
---@return integer tenths-fixed nest multiplier from the staged level bands
local function nestMultiplier(level)
  local staged = math.floor((41 - level) / 10)
  if staged > 3 then
    staged = 3
  end
  if staged < 1 then
    staged = 1
  end
  return staged * 10
end

---@param attackerLevel number thrower level under staging
---@param targetLevel number target level under staging
---@return integer staged rate factor from the floored native tiers
local function levelRateFactor(attackerLevel, targetLevel)
  if attackerLevel <= targetLevel then
    return 1
  end
  if math.floor(attackerLevel / 2) <= targetLevel then
    return 2
  end
  if math.floor(attackerLevel / 4) <= targetLevel then
    return 4
  end
  return 8
end

---@param weight number target weight in hectograms under staging
---@param rate number current rate under staging
---@return integer additive heavy adjustment from the staged weight bands
local function heavyAdjustment(weight, rate)
  if weight >= 4096 then
    return 40
  end
  if weight >= 3072 then
    return 30
  end
  if weight >= 2048 then
    return 20
  end
  if rate < 1024 then
    return -20
  end
  return 0
end

---@param odds integer staged odds under shaking
---@return integer shake threshold staging zero odds as an instant breakout
local function shakeThreshold(odds)
  if odds <= 0 then
    return 0
  end
  local inner = math.floor(0xFF0000 / odds)
  local first = math.floor(math.sqrt(inner))
  local second = math.floor(math.sqrt(first))
  return math.floor(0xFFFF0 / second)
end

--- Native safari catch-rate stages 0..12 as numerator/denominator pairs:
--- bait lowers the stage toward 10/40 while rock raises it toward 40/10.
local SAFARI_CATCH_RATE_STAGES = {
  { 10, 40 },
  { 10, 35 },
  { 10, 30 },
  { 10, 25 },
  { 10, 20 },
  { 10, 15 },
  { 10, 10 },
  { 15, 10 },
  { 20, 10 },
  { 25, 10 },
  { 30, 10 },
  { 35, 10 },
  { 40, 10 },
}

---@param ball string staged ball key under staging
---@param target table<string, unknown> staged target facts under staging
---@param env table<string, unknown> staged encounter facts under staging
---@return number staged rate after the apricorn adjustments
---@return number staged tenths-fixed ball multiplier
local function stageRateAndMultiplier(ball, target, env)
  local rate = target.catchRate --[[@as number]]
  local multiplier = 10
  if ball == "SAFARI_BALL" and env.safariCatchRateStage ~= nil then
    local stage = env.safariCatchRateStage --[[@as integer]]
    assert(stage % 1 == 0 and stage >= 0 and stage <= 12, "safari throws carry a stage from 0 to 12")
    local pair = SAFARI_CATCH_RATE_STAGES[stage + 1]
    rate = math.floor((pair[1] * rate) / pair[2])
  end
  if
    ball == "FAST_BALL"
    and target.baseSpeed --[[@as number]]
      >= 100
  then
    rate = rate * 4
  elseif ball == "LURE_BALL" and env.fished == true then
    rate = rate * 3
  elseif ball == "MOON_BALL" and CaptureContext.isMoonLine(target.species) then
    rate = rate * 4
  elseif ball == "HEAVY_BALL" then
    rate = rate + heavyAdjustment(target.weight --[[@as number]], rate)
  elseif ball == "GREAT_BALL" or ball == "SAFARI_BALL" or ball == "SPORT_BALL" then
    multiplier = 15
  elseif ball == "ULTRA_BALL" then
    multiplier = 20
  elseif ball == "NET_BALL" and hasAnyType(target.types, { "water", "bug" }) then
    multiplier = 30
  elseif ball == "DIVE_BALL" and env.method == "surf" then
    multiplier = 35
  elseif ball == "NEST_BALL" then
    multiplier = nestMultiplier(target.level --[[@as number]])
  elseif ball == "REPEAT_BALL" and env.pokedexCaught == true then
    multiplier = 30
  elseif ball == "TIMER_BALL" then
    multiplier = math.min(40, env.turns --[[@as number]] + 10)
  elseif ball == "DUSK_BALL" and (env.timeOfDay == "night" or env.inCave == true) then
    multiplier = 35
  elseif
    ball == "QUICK_BALL"
    and env.turns --[[@as number]]
      < 1
  then
    multiplier = 40
  elseif ball == "LEVEL_BALL" then
    rate = rate * levelRateFactor(env.attackerLevel --[[@as number]], target.level --[[@as number]])
  elseif ball == "LOVE_BALL" and target.species == env.attackerSpecies and target.gender ~= env.attackerGender then
    rate = rate * 8
  end
  if rate > 0xFF then
    rate = 0xFF
  elseif rate < 0 then
    rate = 1
  end
  return rate, multiplier
end

---@param target table<string, unknown> staged target facts under staging
---@param rate number staged rate under staging
---@param multiplier number staged tenths-fixed multiplier under staging
---@return integer staged odds before the shake checks
local function stageOdds(target, rate, multiplier)
  local maxHp = target.maxHp --[[@as number]]
  local lostHp = maxHp * 3 - target.hp --[[@as number]] * 2
  local staged = math.floor((rate * multiplier) / 10)
  local odds = math.floor((staged * lostHp) / (maxHp * 3))
  if target.status == "asleep" or target.status == "frozen" then
    odds = odds * 2
  end
  if target.status == "burned" or target.status == "paralyzed" or target.status == "poisoned" then
    odds = math.floor((odds * 15) / 10)
  end
  return odds
end

--- Stages the validated context for a throw: resolves the target, the mode
--- policy, legality, resources, and the per-ball facts. Every refusal
--- below spends nothing.
---@param attempt CaptureAttempt throw under staging
---@param battle table<string, unknown> battle-owned execution state under staging
---@return CaptureContext staged context for calculation
---@return CapturePolicy effective mode policy for the throw
---@return integer target combatant identity for the throw
---@return table<string, unknown> target slot holding the mon
local function stageThrow(attempt, battle)
  local targetRef = attempt.target
  if type(targetRef) ~= "table" or type(targetRef.combatant) ~= "number" then
    error(failure("invalid_target", "throws name their target combatant", { code = "invalid_target" }))
  end
  local targetId = targetRef.combatant --[[@as integer]]
  local ball = attempt.ball
  if not CaptureContext.isBall(ball) then
    error(failure("unknown_ball", "the throw names no recognized ball", { code = "unknown_ball", ball = ball }))
  end
  local combatants = battle.combatants
  if type(combatants) ~= "table" then
    error(failure("invalid_target", "the target holds no combatant", { code = "invalid_target", target = targetId }))
  end
  local slot = (combatants --[[@as table<integer, unknown>]])[targetId]
  if type(slot) ~= "table" then
    error(failure("invalid_target", "the target holds no combatant", { code = "invalid_target", target = targetId }))
  end
  local combatant = slot --[[@as table<string, unknown>]]
  if targetRef.activation ~= nil and combatant.activation ~= nil and targetRef.activation ~= combatant.activation then
    error(
      failure(
        "invalid_target",
        "the entry token no longer holds the slot",
        { code = "invalid_target", target = targetId }
      )
    )
  end
  local mon = combatant.mon
  if
    type(mon) ~= "table" or type((mon --[[@as table<string, unknown>]]).species) ~= "string"
  then
    error(
      failure("invalid_target", "the target holds no catchable mon", { code = "invalid_target", target = targetId })
    )
  end
  if
    type(combatant.hp) ~= "number"
    or type(combatant.maxHp) ~= "number"
    or combatant.hp --[[@as number]]
      <= 0
  then
    error(
      failure("invalid_target", "fainted targets are not catchable", { code = "invalid_target", target = targetId })
    )
  end
  local mode = battle.mode
  if mode == nil then
    mode = "wild"
  end
  if type(mode) ~= "string" then
    error(failure("unknown_mode", "the capture mode is missing", { code = "unknown_mode" }))
  end
  local policy = CaptureFormats.policyFor(CaptureFormats.register(), mode --[[@as string]])
  if combatant.ownedByTrainer == true and not policy.trainerCapture then
    error(
      failure(
        "trainer_target",
        "trainer targets are refused without cost",
        { code = "trainer_target", target = targetId }
      )
    )
  end
  if policy.scripted then
    error(
      failure(
        "scripted_battle",
        "tutorial throws belong to the script",
        { code = "scripted_battle", mode = policy.mode }
      )
    )
  end
  if policy.allowedBalls ~= nil then
    local admitted = false
    for _, allowed in ipairs(policy.allowedBalls) do
      if allowed == ball then
        admitted = true
        break
      end
    end
    if not admitted then
      error(
        failure(
          "wrong_ball",
          "the mode admits only its own balls",
          { code = "wrong_ball", ball = ball, mode = policy.mode }
        )
      )
    end
  end
  local targetFacts = {
    catchRate = combatant.catchRate or (mon --[[@as table<string, unknown>]]).catchRate or Capture.DEFAULT_CATCH_RATE,
    maxHp = combatant.maxHp,
    hp = combatant.hp,
    status = combatant.status or (mon --[[@as table<string, unknown>]]).status or "healthy",
    species = (mon --[[@as table<string, unknown>]]).species,
    types = combatant.types or (mon --[[@as table<string, unknown>]]).types,
    level = combatant.level or (mon --[[@as table<string, unknown>]]).level,
    weight = combatant.weight or (mon --[[@as table<string, unknown>]]).weight,
    baseSpeed = combatant.baseSpeed or (mon --[[@as table<string, unknown>]]).baseSpeed,
    gender = combatant.gender or (mon --[[@as table<string, unknown>]]).gender,
  }
  local actorSlot = (combatants --[[@as table<integer, unknown>]])[attempt.actor]
  local actorMon = {} ---@type table<string, unknown>
  if type(actorSlot) == "table" then
    local holder = actorSlot --[[@as table<string, unknown>]]
    if type(holder.mon) == "table" then
      actorMon = holder.mon --[[@as table<string, unknown>]]
    end
  end
  local envFacts = {
    mode = policy.mode,
    turns = battle.turns or 0,
    pokedexCaught = battle.pokedexCaught or false,
    attackerLevel = (actorSlot --[[@as table<string, unknown>]] or {}).level or actorMon.level,
    attackerSpecies = actorMon.species,
    attackerGender = (actorSlot --[[@as table<string, unknown>]] or {}).gender or actorMon.gender,
    method = battle.method or "land",
    fished = battle.fished or false,
    timeOfDay = battle.timeOfDay or "day",
    inCave = battle.inCave or false,
    backdrop = battle.backdrop or "field",
  }
  if policy.mode == "safari" and ball == "SAFARI_BALL" then
    local formatState = battle.formatState
    if type(formatState) == "table" then
      envFacts.safariCatchRateStage = (formatState --[[@as table<string, unknown>]]).safariCatchRateStage
    end
  end
  local context = CaptureContext.forBall(ball, targetFacts, envFacts)
  if policy.counter ~= nil and policy.specialBall == ball then
    local counter = battle[policy.counter]
    local code = "no_special_balls"
    if policy.counter == "safariBalls" then
      code = "no_safari_balls"
    elseif policy.counter == "sportBalls" then
      code = "no_sport_balls"
    elseif policy.counter == "parkBalls" then
      code = "no_park_balls"
    end
    if type(counter) ~= "number" or counter < 1 then
      error(failure(code, "the special counter has no ball left", { code = code, mode = policy.mode }))
    end
  else
    local inventoryId = attempt.inventoryId or "party"
    local inventories = battle.inventories
    local quantities = nil
    if type(inventories) == "table" then
      local stock = (inventories --[[@as table<string, unknown>]])[inventoryId]
      if type(stock) == "table" then
        quantities = (stock --[[@as table<string, unknown>]]).quantities
      end
    end
    local units = 0
    if type(quantities) == "table" then
      units = (quantities --[[@as table<string, integer>]])[ball] or 0
    end
    if type(units) ~= "number" or units < 1 then
      error(failure("empty", "the shared stack has no ball left", { code = "empty", ball = ball }))
    end
  end
  return context, policy, targetId, combatant
end

--- Validates a throw without spending anything: illegal targets, scripted
--- battles, and missing resources fail here with zero draws, stock, or
--- state changed.
---@param attempt CaptureAttempt throw under validation
---@param view table<string, unknown> battle-owned execution state under validation
---@return boolean true when the throw may execute
function Capture.validate(attempt, view)
  assert(type(attempt) == "table", "throws validate an attempt record")
  assert(type(view) == "table", "throws validate against battle state")
  stageThrow(attempt, view)
  return true
end

--- Calculates exact odds and shakes from a staged context. Guaranteed
--- throws report full shakes with no threshold and spend no draws; other
--- throws spend one labeled shake draw per check until the first failure.
--- The catch needs four checks while visible shakes cap at three: passes
--- one through three shake visibly and the fourth decides silently.
---@param attempt CaptureAttempt throw under calculation
---@param context CaptureContext staged context carrying the facts each ball reads
---@param stream table<string, unknown> labeled native draw stream under calculation
---@return CaptureCalculation staged odds, shakes, and threshold
function Capture.calculate(attempt, context, stream)
  assert(type(attempt) == "table", "throws calculate from an attempt record")
  assert(type(stream) == "table", "shake checks spend labeled draws")
  CaptureContext.validate(context)
  local staged = context --[[@as CaptureContext]]
  local ball = staged.ball
  local target = staged.target --[[@as table<string, unknown>]]
  local env = staged.env --[[@as table<string, unknown>]]
  if CaptureContext.isGuaranteed(ball) then
    return { success = true, shakes = Capture.MAX_SHAKES, reason = "guaranteed", odds = Capture.GUARANTEED_ODDS }
  end
  local rate, multiplier = stageRateAndMultiplier(ball, target, env)
  local odds = stageOdds(target, rate, multiplier)
  if odds >= Capture.GUARANTEED_ODDS then
    return { success = true, shakes = Capture.MAX_SHAKES, reason = "guaranteed", odds = odds }
  end
  local threshold = shakeThreshold(odds)
  local cause = { ball = ball, odds = odds, threshold = threshold }
  local visibleShakes = 0
  for check = 1, Capture.PROBABILITY_CHECKS do
    local draw = (stream --[[@as BattleRng]]):nextU16(Capture.SHAKE_LABEL, cause)
    if draw >= threshold then
      return { success = false, shakes = visibleShakes, reason = "broke_free", odds = odds, threshold = threshold }
    end
    if check <= Capture.MAX_SHAKES then
      visibleShakes = visibleShakes + 1
    end
  end
  return { success = true, shakes = visibleShakes, reason = "caught", odds = odds, threshold = threshold }
end

---@param spent table<string, unknown> battle-owned execution state spending the throw
---@param policy CapturePolicy effective mode policy paying for the throw
---@param attempt CaptureAttempt throw paying for its ball
local function spendThrow(spent, policy, attempt)
  local ball = attempt.ball --[[@as string]]
  if policy.counter ~= nil and policy.specialBall == ball then
    local counter = policy.counter --[[@as string]]
    spent[counter] = spent[counter] --[[@as number]] - 1
    return
  end
  local inventoryId = attempt.inventoryId or "party"
  local inventories = spent.inventories --[[@as table<string, unknown>]]
  local stock = (inventories --[[@as table<string, unknown>]])[inventoryId] --[[@as table<string, unknown>]]
  local quantities = stock.quantities --[[@as table<string, integer>]]
  quantities[ball] = quantities[ball] - 1
  assert(type(spent.ledger) == "table", "throws record their consumption")
  local ledger = spent.ledger --[[@as table<integer, table<string, unknown>>]]
  ledger[#ledger + 1] = {
    inventoryId = inventoryId,
    item = ball,
    delta = -1,
    checkpoint = Capture.CONSUMPTION_CHECKPOINT,
  }
end

--- Executes a throw through the single owned path: validate, spend the
--- ball at the throw, stage the shake checks, and return the caught mon
--- with ordered throw, shake, and outcome events. Success carries the
--- existing target record bit-for-bit and never claims placement.
---@param attempt CaptureAttempt throw under execution
---@param battle table<string, unknown> battle-owned execution state being thrown in
---@param stream table<string, unknown> labeled native draw stream under execution
---@return table<string, unknown> execution outcome carrying the result and its events
function Capture.execute(attempt, battle, stream)
  assert(type(attempt) == "table", "throws execute an attempt record")
  assert(type(battle) == "table", "throws execute against battle state")
  assert(type(stream) == "table", "shake checks spend labeled draws")
  local context, policy, targetId, combatant = stageThrow(attempt, battle)
  spendThrow(battle, policy, attempt)
  local calculation = Capture.calculate(attempt, context, stream)
  local ball = attempt.ball --[[@as string]]
  local mon = combatant.mon --[[@as table<string, unknown>]]
  local sequence = battle.captureSeq --[[@as integer?]] or 0
  sequence = sequence + 1
  battle.captureSeq = sequence
  local result = {
    id = sequence,
    target = targetId,
    source = mon.origin,
    ball = ball,
    mon = mon,
    shakes = calculation.shakes,
    context = context,
    success = calculation.success,
  }
  local events = {} ---@type table<integer, table<string, unknown>>
  events[#events + 1] = { kind = "throw", ball = ball, target = targetId }
  for index = 1, calculation.shakes do
    events[#events + 1] = { kind = "shake", index = index }
  end
  if calculation.success then
    events[#events + 1] = { kind = "caught", shakes = calculation.shakes }
  else
    events[#events + 1] = { kind = "broke_free", shakes = calculation.shakes }
  end
  return { result = result, events = events }
end

return Capture
