-- Exact native preview arithmetic for the trainer interpreter:
-- matchup and damage staging plus the rank and comparison routines the
-- opcode handlers call (pret/pokeheartgold ov10_0221F084 matchup core,
-- ov10_0221F47C type arms, ov12_02251D28 type pipeline). Damage and type
-- estimates run in ordered native stages over a local numeric work
-- record; nothing here reuses the live combat damage owner, draws random
-- values outside the transcribed fixed-damage arms, or reaches into the
-- command owner or the program facade. Power-point comparison reuses the
-- single mon-domain maximum; the formula lives there, not here.

local BattleErrors = require("libs.battle.src.errors")
local Moves = require("libs.mons.src.gen4.Moves")
local Data = require("libs.battle.src.gen4.TrainerAiProgramData")
local Context = require("libs.battle.src.gen4.TrainerAiContext")

---@class TrainerAiPreview
local Preview = {}

-- Staged native preview cores for TrainerAiPreview. These two routines keep
-- the exact transcribed arithmetic of their predecessors, only organized
-- into ordered native stages. Each stage reads a local per-preview work
-- record with exactly named numeric fields; only the entry points touch
-- the evaluation state, and every failure still raises at its original
-- position with its original context.

---@class TrainerDamageWork local per-preview numeric record for the damage estimate
---@field movePower integer working move power
---@field moveType integer working move type
---@field category integer 0 physical, 1 special, 2 status
---@field abilityA integer attacker ability identity
---@field abilityT integer target ability identity
---@field monAtk integer working attacker attack
---@field monDef integer working target defense
---@field monSpa integer working attacker special attack
---@field monSpd integer working target special defense
---@field sAtk integer selected attacker attack stage
---@field sDef integer selected target defense stage
---@field sSpa integer selected attacker special attack stage
---@field sSpd integer selected target special defense stage
---@field effA integer attacker held effect, 0 when none
---@field effT integer target held effect, 0 when none
---@field hasEffT integer 1 while the target held effect resolved
---@field hasEffA integer 1 while the attacker held effect resolved
---@field modA integer attacker held modifier, 0 when absent
---@field hasModA integer 1 while the attacker held modifier resolved
---@field itemA integer attacker held item identity
---@field itemT integer target held item identity
---@field level integer attacker level
---@field hp integer attacker health
---@field maxHp integer attacker maximum health
---@field status integer attacker status word
---@field targetStatus integer target status word
---@field effect integer compiled move effect
---@field hasDetail integer 1 while the compiled move facts resolved
---@field genderA integer attacker gender, -1 when unstated
---@field genderT integer target gender, -1 when unstated
---@field partnerAbility integer acting-side partner ability, 0 when suppressed
---@field partnerHp integer acting-side partner health
---@field mold integer 1 while the attacker ignores defending abilities
---@field latiosA integer 1 while the attacker is its own soul-dew bearer
---@field clamperlA integer 1 while the attacker is its own deep-sea bearer
---@field pikachuA integer 1 while the attacker is its own light-ball bearer
---@field cuboneA integer 1 while the attacker is its own thick-club bearer
---@field latiosT integer 1 while the target is its own soul-dew bearer
---@field clamperlT integer 1 while the target is its own deep-sea bearer
---@field dittoT integer 1 while the target is its own metal-powder bearer
---@field airLock integer 1 while the field suppresses weather
---@field mudSport integer 1 while mud sport weakens electricity
---@field waterSport integer 1 while water sport weakens fire
---@field reflect integer 1 while reflect halves physical damage
---@field lightScreen integer 1 while light screen halves special damage
---@field weatherClass integer field weather class
---@field flowerAtk integer 1 while flower gift raises ally attack
---@field flowerDef integer 1 while flower gift raises ally special defense
---@field t1t integer target first type
---@field t2t integer target second type
---@field moveId integer numeric move identity
---@field isPunch integer 1 while the move is a punching move
---@field damage integer staged damage

---@class TrainerPipelineWork local per-preview numeric record for the type pipeline
---@field damage integer staged damage
---@field working integer normalized working move type
---@field abilityA integer attacker ability identity
---@field abilityT integer target ability identity
---@field t1a integer attacker first type
---@field t2a integer attacker second type
---@field grounded integer 1 while the target holds an iron-ball ground
---@field magnet integer 1 while magnet rise lifts the target
---@field roosted integer 1 while roost grounds the target
---@field gravity integer 1 while gravity grounds the target
---@field miracle integer 1 while miracle eye exposes psychics
---@field foresight integer 1 while foresight exposes ghosts
---@field compiledPower integer compiled move power, 0 when uncompiled
---@field apply1 integer 1 while the first pair shapes damage
---@field num1 integer first effectiveness numerator
---@field den1 integer first effectiveness denominator
---@field apply2 integer 1 while the second pair shapes damage
---@field num2 integer second effectiveness numerator
---@field den2 integer second effectiveness denominator
---@field effect integer compiled move effect, -1 when uncompiled
---@field power integer compiled move power for the wonder check
---@field charge integer charge-turn hit flag, 0 when absent
---@field hasCharge integer 1 while the charge-turn flag resolved
---@field itemA integer attacker held item identity
---@field effA integer attacker held effect, 0 when none
---@field hasEffA integer 1 while the attacker held effect resolved
---@field modA integer attacker held modifier, 0 when absent
---@field hasModA integer 1 while the attacker held modifier resolved
---@field immune integer 1 while an immunity flag forces zero
---@field super integer 1 while some pair is super-effective
---@field resisted integer 1 while some pair resists

-- Forward declarations for the remaining matchup helpers defined below.
local matchupRank
local moveTypeOf
local matchupValue
local effectiveMoveType
local hiddenPowerType
local armedPower
local matchupPreview
local knockoutGate
local moveDetailLoad
local protectClassLoad
local categoryDecide
local speciesHpGate
local speedRank
local partyMatchupGate
local stayCheck
local matchupCompareGate
local statCompareGate
local allyMatchupRank
local switchInGate
local encoreGate
local itemEffectLoad
local ppUseGate
-- Forward declaration for the staged damage preview below.
local previewDamageClass
-- Forward declaration for the fixed-damage arm core defined below.
local fixedPreview
-- Forward declaration for the pairwise speed comparator used below.
local comparePair
-- Forward declaration for the member preview core defined below.
local memberPreview
-- Effectiveness-class mapping shared by the damage preview commands: the
-- staged 40-base damage maps 120/240/30/15 back to their unstabbed
-- equivalents, immunity flags force zero, and anything else passes
-- through for the operand comparison.
---@param damage integer staged pipeline damage under classification
---@param immune boolean true while immunity flags force zero
---@return integer effectiveness class under comparison
local function damageClass(damage, immune)
  if immune then
    return 0
  end
  if damage == 120 then
    return 80
  elseif damage == 240 then
    return 160
  elseif damage == 30 then
    return 20
  elseif damage == 15 then
    return 10
  end
  return damage
end
-- Maximum effectiveness class over the attacker's moveset (handler
-- ov10_0221D260 for opcode 42): every slot move runs the 40-base
-- pipeline and the scratch register keeps the highest class.
---@param state TrainerAiProgramState command state under execution
local function maxDamageClass(state)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  state.scratch = 0
  for _, moveId in ipairs(Context.battlerMoveIds(state, atk)) do
    if moveId ~= 0 then
      local class = previewDamageClass(state, moveId)
      if class > state.scratch then
        state.scratch = class
      end
    end
  end
end
-- Effectiveness-class conditional jump (handler ov10_0221D314 for opcode
-- 43): the current move runs the 40-base pipeline and the jump fires
-- when its class matches the operand.
---@param state TrainerAiProgramState command state under execution
---@param expect integer effectiveness class under comparison
---@param jump integer relative word distance under the taken branch
---@return integer? jump target under the taken branch, nil to fall through
local function damageClassGate(state, expect, jump)
  local class = previewDamageClass(state, state.cur)
  if class == expect then
    return jump
  end
  return nil
end
---@param state TrainerAiProgramState command state under execution
---@return boolean true while the attacker's mold breaker suppresses the target
local function ignoredByMold(state)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local record = Context.battlerFacts(state, atk)
  return record.ability == 104
end
-- Staged damage estimate (the ov10_0221F084 damage core): power
-- normalization, the slowing-clock check, attacker and defender hold
-- adjustments, ability attack adjustments, partner auras, sports, pinch
-- abilities, wards, rivalry, punching gloves, weather, and the final
-- physical/special base-damage arms. Floor points, branch precedence,
-- and unsupported-fact failures match the transcribed estimate.
---@param work TrainerDamageWork per-preview numeric record under staging
local function stageNormalizePower(work)
  -- The estimate runs outside action execution, where the revenge power
  -- multiplier rests at its reset value.
  work.movePower = math.floor((work.movePower * 10) / 10)
  if work.abilityA == 96 then
    work.moveType = 0
  end
  if work.abilityA == 101 and work.moveId ~= 165 and work.movePower <= 60 then
    work.movePower = math.floor((work.movePower * 15) / 10)
  end
  if work.abilityA == 37 or work.abilityA == 74 then
    work.monAtk = work.monAtk * 2
  end
end

---@param work TrainerDamageWork per-preview numeric record under staging
local function stageSlowStart(work)
  if work.abilityA == 112 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its slow start", {}))
  end
end

---@param work TrainerDamageWork per-preview numeric record under staging
local function stageHeldAttack(work)
  if work.itemA ~= 0 and work.hasEffA == 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its held item facts", { item = work.itemA }))
  end
  if work.effA == 0 then
    return
  end
  local boosted = Data.TYPE_BOOSTS[work.effA]
  if boosted ~= nil then
    if boosted == work.moveType then
      if work.hasModA == 0 then
        error(BattleErrors.missingBehavior("trainer evaluation reads its held modifier", { item = work.itemA }))
      end
      work.movePower = math.floor((work.movePower * (100 + work.modA)) / 100)
    end
  elseif work.effA == 55 then
    work.monAtk = math.floor((work.monAtk * 150) / 100)
  elseif work.effA == 125 then
    work.monSpa = math.floor((work.monSpa * 150) / 100)
  elseif work.effA == 60 then
    -- Soul Dew raises the special attack of its own Latios/Latias
    -- bearers. Evaluation battles never carry the frontier bit
    -- (battleType is 1 or 3), so the frontier exclusion never
    -- triggers and the rule applies unconditionally.
    if work.latiosA == 1 then
      work.monSpa = math.floor((work.monSpa * 150) / 100)
    end
  elseif work.effA == 61 then
    -- DeepSeaTooth doubles the special attack of its Clamperl bearer.
    if work.clamperlA == 1 then
      work.monSpa = work.monSpa * 2
    end
  elseif work.effA == 71 then
    -- Light Ball doubles the move power of its Pikachu bearer.
    if work.pikachuA == 1 then
      work.movePower = work.movePower * 2
    end
  elseif work.effA == 91 then
    -- Thick Club doubles the attack of its Cubone/Marowak bearers.
    if work.cuboneA == 1 then
      work.monAtk = work.monAtk * 2
    end
  elseif work.effA == 62 or work.effA == 90 then
    -- Defender-side items held by the attacker read no adjustment
    -- here; the defender arms below apply them from the defender
    -- record.
  elseif work.effA == 3 or work.effA == 4 or work.effA == 2 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its orb item", { item = work.itemA }))
  elseif work.effA == 94 or work.effA == 95 then
    if work.hasModA == 0 then
      error(BattleErrors.missingBehavior("trainer evaluation reads its held modifier", { item = work.itemA }))
    end
    if (work.effA == 94 and work.category == 0) or (work.effA == 95 and work.category == 1) then
      work.movePower = math.floor((work.movePower * (100 + work.modA)) / 100)
    end
  elseif work.effA == 13 then
    -- Health-restore berries never adjust staged damage: the source
    -- damage calculation reads no berry hold effects, so the preview
    -- leaves power untouched.
  elseif
    work.effA == 1
    or work.effA == 6
    or work.effA == 12
    or work.effA == 21
    or work.effA == 33
    or work.effA == 49
    or work.effA == 109
  then
    -- Exactly these seven effects read no adjustment in the damage
    -- estimate: neither the damage calculation nor the type pipeline
    -- branches on them, so the preview leaves power and stats
    -- untouched. Every other unmapped effect stays fail-closed below.
  else
    error(BattleErrors.missingBehavior("trainer evaluation reads its held item facts", { item = work.itemA }))
  end
end

---@param work TrainerDamageWork per-preview numeric record under staging
local function stageHeldDefense(work)
  if work.itemT ~= 0 and work.hasEffT == 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its held item facts", { item = work.itemT }))
  end
  if work.effT == 60 then
    -- Soul Dew raises the special defense of its own Latios/Latias
    -- targets; the frontier exclusion never triggers here either.
    if work.latiosT == 1 then
      work.monSpd = math.floor((work.monSpd * 150) / 100)
    end
  elseif work.effT == 62 then
    -- DeepSeaScale doubles the special defense of its Clamperl target.
    if work.clamperlT == 1 then
      work.monSpd = work.monSpd * 2
    end
  elseif work.effT == 90 then
    -- Metal Powder doubles the defense of its Ditto target.
    if work.dittoT == 1 then
      work.monDef = work.monDef * 2
    end
  end
end

---@param work TrainerDamageWork per-preview numeric record under staging
local function stageAbilityAttack(work)
  if work.abilityA == 55 then
    work.monAtk = math.floor((work.monAtk * 150) / 100)
  end
  if work.abilityA == 62 and work.status ~= 0 then
    work.monAtk = math.floor((work.monAtk * 150) / 100)
  end
  if work.abilityT == 63 and work.targetStatus ~= 0 then
    work.monDef = math.floor((work.monDef * 150) / 100)
  end
end

---@param work TrainerDamageWork per-preview numeric record under staging
local function stageAura(work)
  if work.abilityA == 57 or work.abilityA == 58 then
    if work.partnerHp > 0 then
      -- Each aura needs its living counterpart beside it: Plus reads
      -- Minus and Minus reads Plus. The partner read moves through the
      -- shared suppression model, so a suppressed partner carries no
      -- aura; the Mold Breaker arm cannot coincide with an aura holder
      -- here but keeps the read inside that model.
      local counterpart = 58
      if work.abilityA == 58 then
        counterpart = 57
      end
      if work.partnerAbility == counterpart and work.mold == 0 then
        work.monSpa = math.floor((work.monSpa * 150) / 100)
      end
    end
  end
end

---@param work TrainerDamageWork per-preview numeric record under staging
local function stageSports(work)
  if work.moveType == 13 and work.mudSport == 1 then
    work.movePower = math.floor(work.movePower / 2)
  end
  if work.moveType == 10 and work.waterSport == 1 then
    work.movePower = math.floor(work.movePower / 2)
  end
end

---@param work TrainerDamageWork per-preview numeric record under staging
local function stagePinch(work)
  if work.abilityA == 65 and work.moveType == 12 and work.hp <= math.floor(work.maxHp / 3) then
    work.movePower = math.floor((work.movePower * 150) / 100)
  end
  if work.abilityA == 66 and work.moveType == 10 and work.hp <= math.floor(work.maxHp / 3) then
    work.movePower = math.floor((work.movePower * 150) / 100)
  end
  if work.abilityA == 67 and work.moveType == 11 and work.hp <= math.floor(work.maxHp / 3) then
    work.movePower = math.floor((work.movePower * 150) / 100)
  end
  if work.abilityA == 68 and work.moveType == 6 and work.hp <= math.floor(work.maxHp / 3) then
    work.movePower = math.floor((work.movePower * 150) / 100)
  end
end

---@param work TrainerDamageWork per-preview numeric record under staging
local function stageWard(work)
  if work.abilityT == 85 and work.moveType == 10 then
    work.movePower = math.floor(work.movePower / 2)
  end
  if work.abilityT == 87 and work.moveType == 10 then
    work.movePower = math.floor((work.movePower * 125) / 100)
  end
  if work.abilityT == 47 and work.mold == 0 and (work.moveType == 10 or work.moveType == 15) then
    work.movePower = math.floor(work.movePower / 2)
  end
end

---@param work TrainerDamageWork per-preview numeric record under staging
local function stageRivalry(work)
  if work.abilityA == 79 then
    if work.genderA < 0 or work.genderT < 0 then
      error(BattleErrors.missingBehavior("trainer evaluation reads its battler gender", {}))
    end
    if work.genderA == work.genderT and work.genderA ~= 2 then
      work.movePower = math.floor((work.movePower * 125) / 100)
    elseif work.genderA ~= work.genderT and work.genderA ~= 2 and work.genderT ~= 2 then
      work.movePower = math.floor((work.movePower * 75) / 100)
    end
  end
end

---@param work TrainerDamageWork per-preview numeric record under staging
local function stageIronFist(work)
  if work.abilityA == 89 and work.isPunch == 1 then
    work.movePower = math.floor((work.movePower * 12) / 10)
  end
end

---@param work TrainerDamageWork per-preview numeric record under staging
local function stageWeather(work)
  if work.airLock ~= 1 then
    if work.weatherClass == 2 and work.abilityA == 94 then
      work.monSpa = math.floor((work.monSpa * 15) / 10)
    end
    if work.weatherClass == 4 and (work.t1t == 5 or work.t2t == 5) then
      work.monSpd = math.floor((work.monSpd * 15) / 10)
    end
    if work.weatherClass == 3 then
      if work.abilityA == 122 then
        work.monAtk = math.floor((work.monAtk * 15) / 10)
      end
      if work.abilityT ~= 104 and work.flowerAtk == 1 then
        work.monAtk = math.floor((work.monAtk * 15) / 10)
      end
      if work.abilityA ~= 104 and work.flowerDef == 1 then
        work.monSpd = math.floor((work.monSpd * 15) / 10)
      end
    end
  end
end

---@param work TrainerDamageWork per-preview numeric record under staging
local function stageBaseDamage(work)
  if work.hasDetail == 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", { move = work.moveId }))
  end
  local damage = 0
  if work.category == 0 then
    local attack = Context.stagedStat(work.monAtk, work.sAtk)
    damage = attack * work.movePower
    damage = damage * (math.floor((work.level * 2) / 5) + 2)
    damage = math.floor(damage / Context.stagedStat(work.monDef, work.sDef))
    damage = math.floor(damage / 50)
    if work.status % 32 >= 16 and work.abilityA ~= 62 then
      damage = math.floor(damage / 2)
    end
    if work.reflect == 1 and work.effect ~= 186 then
      damage = math.floor(damage / 2)
    end
  elseif work.category == 1 then
    local attack = Context.stagedStat(work.monSpa, work.sSpa)
    damage = attack * work.movePower
    damage = damage * (math.floor((work.level * 2) / 5) + 2)
    damage = math.floor(damage / Context.stagedStat(work.monSpd, work.sSpd))
    damage = math.floor(damage / 50)
    if work.lightScreen == 1 and work.effect ~= 186 then
      damage = math.floor(damage / 2)
    end
  else
    error(BattleErrors.missingBehavior("trainer damage previews evaluate damaging moves", { move = work.moveId }))
  end
  work.damage = damage
end

-- Staged damage estimate for one explicit move identity: the entry point
-- stages every fact the estimate reads into the numeric work record,
-- then runs the native stages in transcribed order.
---@param state TrainerAiProgramState command state under execution
---@param moveId integer numeric move identity under preview
---@param power integer compiled move power under evaluation
---@param moveType integer working move type under evaluation
---@param category integer 0 physical, 1 special, 2 status
---@return integer staged damage under the preview
local function calcPreview(state, moveId, power, moveType, category)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local tgt = facts.tgt --[[@as integer]]
  local attacker = Context.battlerFacts(state, atk)
  local target = Context.battlerFacts(state, tgt)
  local abilityA = attacker.ability --[[@as integer]]
  local abilityT = target.ability --[[@as integer]]
  local itemA = attacker.item --[[@as integer]]
  local itemT = target.item --[[@as integer]]
  local held = facts.heldEffects --[[@as table<integer, integer>]]
  local modA = facts.heldMods --[[@as table<integer, integer>]]
  local effA = 0
  local hasEffA = 1
  if itemA ~= 0 then
    local resolved = held[itemA]
    if resolved == nil then
      hasEffA = 0
    else
      effA = resolved
    end
  end
  local effT = 0
  local hasEffT = 1
  if itemT ~= 0 then
    local resolved = held[itemT]
    if resolved == nil then
      hasEffT = 0
    else
      effT = resolved
    end
  end
  local modValue = modA[itemA]
  local attackerSpecies = attacker.species --[[@as string?]]
  local targetSpecies = target.species --[[@as string?]]
  local partner = Context.partnerOf(atk)
  local presence = Context.battlerFacts(state, partner)
  local partnerAbility = presence.ability --[[@as integer]]
  if presence.suppressed == true then
    partnerAbility = 0
  end
  local mold = 0
  if ignoredByMold(state) then
    mold = 1
  end
  local atkStages = attacker.stages --[[@as table<integer, integer>]]
  local defStages = target.stages --[[@as table<integer, integer>]]
  local function doubled(stages)
    local out = {}
    for index = 1, 8 do
      local delta = stages[index] --[[@as integer]] - 6
      delta = delta * 2
      if delta < -6 then
        delta = -6
      end
      if delta > 6 then
        delta = 6
      end
      out[index] = delta + 6
    end
    return out
  end
  local pickedAtk = atkStages
  local pickedDef = defStages
  if abilityA == 86 then
    pickedAtk = doubled(atkStages)
  end
  if abilityT == 86 and mold == 0 then
    pickedDef = doubled(defStages)
  end
  local sAtk = pickedAtk[2]
  local sSpa = pickedAtk[5]
  local sDef = pickedDef[3]
  local sSpd = pickedDef[6]
  if abilityT == 109 and mold == 0 then
    sAtk = 6
    sSpa = 6
  end
  if abilityA == 109 then
    sDef = 6
    sSpd = 6
  end
  local genderA = attacker.gender
  local genderT = target.gender
  local byId = facts.moveById --[[@as table<integer, table<string, unknown>>]]
  local detail = byId[moveId]
  local effect = 0
  local hasDetail = 0
  if type(detail) == "table" then
    effect = detail.effect --[[@as integer]]
    hasDetail = 1
  end
  local isPunch = 0
  if Data.PUNCH_MOVES[moveId] == true then
    isPunch = 1
  end
  ---@type TrainerDamageWork
  local work = {
    movePower = power,
    moveType = moveType,
    category = category,
    abilityA = abilityA,
    abilityT = abilityT,
    monAtk = attacker.atk --[[@as integer]],
    monDef = target.def --[[@as integer]],
    monSpa = attacker.spa --[[@as integer]],
    monSpd = target.spd --[[@as integer]],
    sAtk = sAtk,
    sDef = sDef,
    sSpa = sSpa,
    sSpd = sSpd,
    effA = effA,
    effT = effT,
    hasEffT = hasEffT,
    hasEffA = hasEffA,
    modA = modValue or 0,
    hasModA = (modValue == nil) and 0 or 1,
    itemA = itemA,
    itemT = itemT,
    level = attacker.level --[[@as integer]],
    hp = attacker.hp --[[@as integer]],
    maxHp = attacker.maxHp --[[@as integer]],
    status = attacker.status --[[@as integer]],
    targetStatus = target.status --[[@as integer]],
    effect = effect,
    hasDetail = hasDetail,
    genderA = (type(genderA) == "number") and genderA or -1,
    genderT = (type(genderT) == "number") and genderT or -1,
    partnerAbility = partnerAbility,
    partnerHp = presence.hp --[[@as integer]],
    mold = mold,
    latiosA = (attackerSpecies == "LATIOS" or attackerSpecies == "LATIAS") and 1 or 0,
    clamperlA = (attackerSpecies == "CLAMPERL") and 1 or 0,
    pikachuA = (attackerSpecies == "PIKACHU") and 1 or 0,
    cuboneA = (attackerSpecies == "CUBONE" or attackerSpecies == "MAROWAK") and 1 or 0,
    latiosT = (targetSpecies == "LATIOS" or targetSpecies == "LATIAS") and 1 or 0,
    clamperlT = (targetSpecies == "CLAMPERL") and 1 or 0,
    dittoT = (targetSpecies == "DITTO") and 1 or 0,
    airLock = (facts.airLock == true) and 1 or 0,
    mudSport = (facts.mudSport == true) and 1 or 0,
    waterSport = (facts.waterSport == true) and 1 or 0,
    reflect = (facts.reflect == true) and 1 or 0,
    lightScreen = (facts.lightScreen == true) and 1 or 0,
    weatherClass = facts.weatherClass --[[@as integer]],
    flowerAtk = (facts.flowerGiftAtk == true) and 1 or 0,
    flowerDef = (facts.flowerGiftDef == true) and 1 or 0,
    t1t = target.t1 --[[@as integer]],
    t2t = target.t2 --[[@as integer]],
    moveId = moveId,
    isPunch = isPunch,
    damage = 0,
  }
  stageNormalizePower(work)
  stageSlowStart(work)
  stageHeldAttack(work)
  stageHeldDefense(work)
  stageAbilityAttack(work)
  stageAura(work)
  stageSports(work)
  stagePinch(work)
  stageWard(work)
  stageRivalry(work)
  stageIronFist(work)
  stageWeather(work)
  stageBaseDamage(work)
  return work.damage
end

-- Literal scale selection for the matchup previews (ov10_0221EF7C
-- core behind opcodes 32/99/105): the command operand selects the
-- stored slot threshold only for mode 1, and 100 otherwise.
---@param state TrainerAiProgramState command state under execution
---@param scaleMode integer literal scale operand under selection
---@param slot integer zero-based move slot under the preview
---@return integer 100 or the slot threshold under the final multiply
local function matchupScale(state, scaleMode, slot)
  if scaleMode == 1 then
    return state.thresholds[slot + 1]
  end
  return 100
end
-- Four-move staged preview for the battler named by the supplied facts:
-- every slot runs the matchup preview in source slot order against the
-- unchanged target using the literal scale rule above. No rank,
-- eligibility, or branch decision lives here.
---@param state TrainerAiProgramState command state under execution
---@param scaleMode integer literal scale operand under the previews
---@return integer[] staged matchup values for move slots 0..3 in order
local function matchupValues(state, scaleMode)
  local values = {}
  for slot = 0, 3 do
    values[slot + 1] = matchupValue(state, slot, matchupScale(state, scaleMode, slot))
  end
  return values
end
-- Current-move eligibility for the matchup ranks: moves outside the
-- evaluation class (excluded effects, power 0/1) never rank and leave
-- zero to their caller.
---@param state TrainerAiProgramState command state under execution
---@return boolean true while the current move enters the preview loop
local function matchupEligible(state)
  local facts = state.facts --[[@as table<string, unknown>]]
  local byId = facts.moveById --[[@as table<integer, table<string, unknown>>]]
  local record = byId[state.cur]
  if type(record) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", {
      move = state.cur,
    }))
  end
  local effect = record.effect --[[@as integer]]
  local power = record.power --[[@as integer]]
  if Data.INCLUDED_EFFECTS[effect] ~= true then
    if Data.EXCLUDED_EFFECTS[effect] == true or power <= 1 then
      return false
    end
  end
  return true
end
-- Effectiveness-class ranking into scratch (handler ov10_0221CD34 for
-- opcode 32): ineligible moves leave zero; otherwise every slot runs
-- the matchup preview under the literal scale operand and the current
-- slot leads-or-ties for 2, trails for 1.
---@param state TrainerAiProgramState command state under execution
---@param scaleMode integer literal scale operand under the previews
---@return integer effectiveness class 0/1/2 under the rank
function matchupRank(state, scaleMode)
  if not matchupEligible(state) then
    return 0
  end
  local ownValues = matchupValues(state, scaleMode)
  -- Rank demotion is strict. Ties keep the selected move at rank 2.
  local selected = ownValues[state.slot + 1]
  for _, value in ipairs(ownValues) do
    if value > selected then
      return 1
    end
  end
  return 2
end
-- Type pipeline matching ov12_02251D28: STAB (doubled for Adaptability),
-- Levitate and Magnet Rise immunities, per-pair chart effectiveness with
-- grounded, roost, gravity, and miracle-eye gates, Wonder Guard
-- immunity, and Filter/Solid Rock damage adjustments. Returns staged
-- damage with immunity and super-effective classification. Tinted Lens
-- and Expert Belt adjust damage through mapped facts and fail closed
-- when their modifiers are absent.
---@param work TrainerPipelineWork per-preview numeric record under staging
local function stagePipelineStab(work)
  if work.t1a == work.working or work.t2a == work.working then
    if work.abilityA == 91 then
      work.damage = work.damage * 2
    else
      work.damage = math.floor((work.damage * 15) / 10)
    end
  end
end

---@param work TrainerPipelineWork per-preview numeric record under staging
---@return boolean true while a ground immunity forces zero
local function stagePipelineGround(work)
  if work.abilityT == 26 and work.working == 4 and work.grounded == 0 then
    return true
  end
  if work.magnet == 1 and work.working == 4 and work.grounded == 0 then
    return true
  end
  return false
end

---@param work TrainerPipelineWork per-preview numeric record under staging
---@return boolean true while a chart immunity forces zero
local function stagePipelineChart(work)
  for _, pair in ipairs({
    { apply = work.apply1, num = work.num1, den = work.den1 },
    { apply = work.apply2, num = work.num2, den = work.den2 },
  }) do
    if pair.apply == 1 then
      if pair.num == 0 then
        work.immune = 1
        return true
      elseif work.compiledPower ~= 0 then
        if pair.num >= 2 * pair.den then
          work.super = 1
          work.damage = math.floor((work.damage * pair.num) / pair.den)
        else
          if pair.num < pair.den then
            work.resisted = 1
          end
          work.damage = math.floor((work.damage * pair.num) / pair.den)
        end
      end
    end
  end
  return false
end

---@param work TrainerPipelineWork per-preview numeric record under staging
---@return boolean true while Wonder Guard forces zero
local function stagePipelineWonder(work)
  if work.abilityT == 25 then
    local charging = false
    if
      work.effect == 26
      or work.effect == 39
      or work.effect == 75
      or work.effect == 145
      or work.effect == 151
      or work.effect == 155
      or work.effect == 255
      or work.effect == 256
      or work.effect == 263
      or work.effect == 273
    then
      if work.hasCharge == 0 then
        error(BattleErrors.missingBehavior("trainer evaluation reads its charge hit", {}))
      end
      charging = work.charge == 1
    else
      charging = true
    end
    if charging and work.power ~= 0 and (work.super == 0 or work.resisted == 1) then
      work.immune = 1
      return true
    end
  end
  return false
end

---@param work TrainerPipelineWork per-preview numeric record under staging
local function stagePipelineFinal(work)
  if work.super == 1 and (work.abilityT == 111 or work.abilityT == 116) then
    work.damage = math.floor((work.damage * 3) / 4)
  end
  if work.super == 1 and work.abilityA == 110 then
    work.damage = work.damage * 2
  end
  if work.super == 1 then
    if work.itemA ~= 0 then
      if work.hasEffA == 0 then
        error(BattleErrors.missingBehavior("trainer evaluation reads its held item facts", { item = work.itemA }))
      end
      if work.effA == 96 then
        if work.hasModA == 0 then
          error(BattleErrors.missingBehavior("trainer evaluation reads its held modifier", { item = work.itemA }))
        end
        work.damage = math.floor((work.damage * (100 + work.modA)) / 100)
      end
    end
  end
end

---@param defense integer defending type under the gate
---@param grounded integer 1 while an iron ball grounds flying types
---@param roosted integer 1 while roost grounds the target
---@param gravity integer 1 while gravity grounds the target
---@param miracle integer 1 while miracle eye exposes psychic types
---@return boolean true while the pair shapes damage
local function pipelineGate(defense, grounded, roosted, gravity, miracle)
  if grounded == 1 and defense == 2 then
    return false
  end
  if roosted == 1 and defense == 2 then
    return false
  end
  if gravity == 1 and defense == 2 then
    return false
  end
  if miracle == 1 and defense == 17 then
    return false
  end
  return true
end

-- Staged type pipeline for one explicit move identity: the entry point
-- stages every fact the pipeline reads into the numeric work record,
-- including the ordered per-pair chart results, then runs the native
-- steps in transcribed order.
---@param state TrainerAiProgramState command state under execution
---@param moveId integer numeric move identity under evaluation
---@param moveType integer working move type under evaluation
---@param damage integer incoming staged damage under adjustment
---@return integer adjusted damage
---@return boolean immune true while an immunity flag forces zero
---@return boolean super true while some pair is super-effective
local function pipelinePreview(state, moveId, moveType, damage)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local tgt = facts.tgt --[[@as integer]]
  local attacker = Context.battlerFacts(state, atk)
  local target = Context.battlerFacts(state, tgt)
  local abilityA = attacker.ability --[[@as integer]]
  local abilityT = target.ability --[[@as integer]]
  if moveId == 165 then
    return damage, false, false
  end
  local working = moveType
  if abilityA == 96 then
    working = 0
  end
  local itemT = target.item --[[@as integer]]
  local held = facts.heldEffects --[[@as table<integer, integer>]]
  local grounded = 0
  if itemT ~= 0 then
    local effect = held[itemT]
    if effect == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its held item facts", { item = itemT }))
    end
    if effect == 106 then
      grounded = 1
    end
  end
  local roosted = (target.roosted == true) and 1 or 0
  local gravity = (facts.gravity == true) and 1 or 0
  local miracle = (target.miracleEye == true) and 1 or 0
  local foresight = (target.foresight == true or abilityA == 113) and 1 or 0
  local pair = facts.pairEffectiveness --[[@as fun(moveType: integer, defense: integer): (integer, integer)]]
  local flagById = facts.moveById --[[@as table<integer, table<string, unknown>>]]
  local flagDetail = flagById[moveId]
  local compiledPower = 0
  local wonderPower = 0
  local wonderEffect = -1
  if type(flagDetail) == "table" then
    compiledPower = flagDetail.power --[[@as integer]]
    wonderPower = flagDetail.power --[[@as integer]]
    wonderEffect = flagDetail.effect --[[@as integer]]
  end
  local apply = { 0, 0 }
  local nums = { 0, 0 }
  local dens = { 1, 1 }
  local seen = {}
  local staged = 0
  for _, defense in ipairs({ target.t1, target.t2 }) do
    if not seen[defense] then
      seen[defense] = true
      local ghostOk = foresight == 1 or working ~= 7 or defense ~= 7
      if ghostOk and pipelineGate(defense, grounded, roosted, gravity, miracle) then
        local numerator, denominator = pair(working, defense)
        staged = staged + 1
        apply[staged] = 1
        nums[staged] = numerator
        dens[staged] = denominator
      end
    end
  end
  local itemA = attacker.item --[[@as integer]]
  local effA = 0
  local hasEffA = 1
  if itemA ~= 0 then
    local effect = held[itemA]
    if effect == nil then
      hasEffA = 0
    else
      effA = effect
    end
  end
  local modA = facts.heldMods --[[@as table<integer, integer>]]
  local modValue = modA[itemA]
  local hit = facts.chargeHit
  ---@type TrainerPipelineWork
  local work = {
    damage = damage,
    working = working,
    abilityA = abilityA,
    abilityT = abilityT,
    t1a = attacker.t1 --[[@as integer]],
    t2a = attacker.t2 --[[@as integer]],
    grounded = grounded,
    magnet = (target.magnetRise == true) and 1 or 0,
    roosted = roosted,
    gravity = gravity,
    miracle = miracle,
    foresight = foresight,
    compiledPower = compiledPower,
    apply1 = apply[1],
    num1 = nums[1],
    den1 = dens[1],
    apply2 = apply[2],
    num2 = nums[2],
    den2 = dens[2],
    effect = wonderEffect,
    power = wonderPower,
    charge = (hit == true) and 1 or 0,
    hasCharge = (hit == nil) and 0 or 1,
    itemA = itemA,
    effA = effA,
    hasEffA = hasEffA,
    modA = modValue or 0,
    hasModA = (modValue == nil) and 0 or 1,
    immune = 0,
    super = 0,
    resisted = 0,
  }
  stagePipelineStab(work)
  if stagePipelineGround(work) then
    return 0, true, false
  end
  if stagePipelineChart(work) then
    return 0, true, false
  end
  if stagePipelineWonder(work) then
    return 0, true, false
  end
  stagePipelineFinal(work)
  return work.damage, false, work.super == 1
end

-- Staged preview for one explicit move identity (the ov10_0221F084
-- switch at the heart of the matchup core): effects outside the
-- evaluation class read zero; other moves run the fixed-damage arms or
-- the staged preview, scaled by the caller-selected factor. The working
-- move type is the compiled type unless an override selects another, so
-- ordinary moves preview against their own type through the pipeline.
---@param state TrainerAiProgramState command state under execution
---@param moveId integer numeric move identity under preview
---@param scale integer 100 or the slot threshold under the final multiply
---@return integer staged matchup value under the preview
local function previewMove(state, moveId, scale)
  local facts = state.facts --[[@as table<string, unknown>]]
  local byId = facts.moveById --[[@as table<integer, table<string, unknown>>]]
  local detail = byId[moveId]
  if type(detail) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", {
      move = moveId,
    }))
  end
  local effect = detail.effect --[[@as integer]]
  local power = detail.power --[[@as integer]]
  if Data.INCLUDED_EFFECTS[effect] ~= true then
    if Data.EXCLUDED_EFFECTS[effect] == true or power <= 1 then
      return 0
    end
  end
  local fixed = fixedPreview(state, moveId)
  if fixed ~= nil then
    local damage, immune = pipelinePreview(state, moveId, fixed.type, fixed.damage)
    if immune then
      return 0
    end
    return damage * scale
  end
  local fly = detail --[[@as table<string, unknown>]]
  local workingPower = power
  local workingType = (function()
    local ids = Data.TYPE_IDS --[[@as table<string, integer>]]
    local numeric = ids[
      fly.moveType --[[@as string]]
    ]
    if numeric == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its move type", { move = moveId }))
    end
    return numeric
  end)()
  local category = 2
  if fly.category == "physical" then
    category = 0
  elseif fly.category == "special" then
    category = 1
  end
  local effective = effectiveMoveType(state, moveId)
  if effective == 0 then
    effective = workingType
  end
  local armed = armedPower(state, moveId, workingPower)
  local base = calcPreview(state, moveId, armed, effective, category)
  local damage, immune = pipelinePreview(state, moveId, effective, base)
  if immune then
    return 0
  end
  return damage * scale
end
-- Matchup value per move slot (handler ov10_0221EF7C core behind opcodes
-- 32/99/105): vacant slots read zero; other slots run the staged
-- preview above for the move held in that slot, scaled by the slot
-- factor (100, or the stored threshold for literal mode 1).
---@param state TrainerAiProgramState command state under execution
---@param slot integer zero-based move slot under preview
---@param scale integer 100 or the slot threshold under the final multiply
---@return integer matchup value under the rank
function matchupValue(state, slot, scale)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local record = Context.battlerFacts(state, atk)
  local moves = record.moves --[[@as table<integer, integer>]]
  local moveId = moves[slot + 1] or 0
  if moveId == 0 then
    return 0
  end
  return previewMove(state, moveId, scale)
end
-- Hidden Power type from attacker IV parity (handlers ov10_0221F536
-- and the ov10_0221F1E8 arm): combination scaled by 15/63 plus one,
-- bumped once more below 9.
---@param state TrainerAiProgramState command state under execution
---@return integer numeric Hidden Power type under evaluation
function hiddenPowerType(state)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local record = Context.battlerFacts(state, atk)
  local ivs = record.ivs --[[@as table<string, integer>]]
  local function parity(key)
    local value = ivs[key] --[[@as integer]]
    if value == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its individual values", {}))
    end
    return value % 2
  end
  local combo = parity("hp")
    + 2 * parity("attack")
    + 4 * parity("defense")
    + 8 * parity("speed")
    + 16 * parity("specialAttack")
    + 32 * parity("specialDefense")
  local kind = math.floor((combo * 15) / 63) + 1
  if kind < 9 then
    kind = kind + 1
  end
  return kind
end
-- Effective move type for damage previews (handler ov10_0221F47C):
-- Weather Ball follows the field weather, Hidden Power derives from
-- attacker IVs, Natural Gift and Judgment follow the held item, and
-- anything else keeps the compiled move type (0 selects it downstream).
---@param state TrainerAiProgramState command state under execution
---@param moveId integer numeric move identity under evaluation
---@return integer working move type override, 0 for the compiled type
function effectiveMoveType(state, moveId)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  if moveId == 311 then
    local weatherClass = facts.weatherClass --[[@as integer]]
    if facts.airLock == true then
      return 255
    end
    if weatherClass == 2 then
      return 11
    elseif weatherClass == 4 then
      return 5
    elseif weatherClass == 3 then
      return 10
    elseif weatherClass == 5 then
      return 15
    end
    return 255
  elseif moveId == 237 then
    return hiddenPowerType(state)
  elseif moveId == 363 then
    local record = Context.battlerFacts(state, atk)
    local item = record.item --[[@as integer]]
    if item == 0 then
      return 0
    end
    local gifts = facts.naturalGifts --[[@as table<integer, table<string, integer>>]]
    local gift = gifts[item]
    if gift == nil then
      return 0
    end
    return gift.typeId or 0
  elseif moveId == 449 then
    local record = Context.battlerFacts(state, atk)
    local item = record.item --[[@as integer]]
    if item == 0 then
      return 0
    end
    local held = facts.heldEffects --[[@as table<integer, integer>]]
    local effect = held[item]
    if effect == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its held item facts", { item = item }))
    end
    if effect >= 126 and effect <= 141 then
      local plate = Data.TYPE_BOOSTS[effect]
      if plate ~= nil then
        return plate
      end
    end
    return 0
  end
  return 0
end
-- Fixed-damage arms (handler ov10_0221F084 switch): Sonic Boom scores
-- 20, Dragon Rage 40, Seismic Toss and Night Shade the attacker level,
-- Psywave a level-scaled random draw, and Magnitude a tiered random
-- draw. Anything else returns nil for the staged path. Each arm spends
-- its draws exactly where the source does.
---@param state TrainerAiProgramState command state under execution
---@param moveId integer numeric move identity under evaluation
---@return { type: integer, damage: integer }? staged fixed damage with its compiled move type, nil for the staged path
function fixedPreview(state, moveId)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local record = Context.battlerFacts(state, atk)
  local damage = nil ---@type integer?
  if moveId == 49 then
    damage = 20
  elseif moveId == 82 then
    damage = 40
  elseif moveId == 69 or moveId == 101 then
    damage = record.level --[[@as integer]]
  elseif moveId == 149 then
    local level = record.level --[[@as integer]]
    local roll = Context.drawNow(state)
    damage = math.floor(((roll % 11) + 5) * level / 10)
  elseif moveId == 222 then
    local roll = Context.drawNow(state)
    local tier = roll % 100
    if tier < 5 then
      damage = 10
    elseif tier < 15 then
      damage = 30
    elseif tier < 35 then
      damage = 50
    elseif tier < 65 then
      damage = 70
    elseif tier < 85 then
      damage = 90
    elseif tier < 95 then
      damage = 110
    else
      damage = 150
    end
  end
  if damage == nil then
    return nil
  end
  return { type = moveTypeOf(state, moveId), damage = damage }
end
-- Power-override arms: Return and Frustration scale friendship,
-- Low Kick and Grass Knot consult the target weight ladder, Gyro Ball
-- the speed ratio capped at 150, Hidden Power its IV power, Natural Gift
-- the held berry power, and Judgment the compiled power.
-- Anything else keeps the compiled power.
---@param state TrainerAiProgramState command state under execution
---@param moveId integer numeric move identity under evaluation
---@param basePower integer compiled move power under override
---@return integer working move power under evaluation
function armedPower(state, moveId, basePower)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local tgt = facts.tgt --[[@as integer]]
  if moveId == 216 then
    local record = Context.battlerFacts(state, atk)
    local friendship = record.friendship
    if friendship == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its friendship", {}))
    end
    return math.floor((friendship * 10) / 25)
  elseif moveId == 218 then
    local record = Context.battlerFacts(state, atk)
    local friendship = record.friendship
    if friendship == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its friendship", {}))
    end
    return math.floor(((255 - friendship) * 10) / 25)
  elseif moveId == 67 or moveId == 447 then
    local record = Context.battlerFacts(state, tgt)
    local weight = record.weightHg
    if weight == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its weight", {}))
    end
    for _, class in ipairs(Data.WEIGHT_CLASSES) do
      if weight <= class.threshold then
        return class.power
      end
    end
    return Data.WEIGHT_FALLBACK_POWER
  elseif moveId == 360 then
    local user = Context.effectiveSpeed(state, atk)
    local foe = Context.effectiveSpeed(state, tgt)
    if user <= 0 then
      error(BattleErrors.missingBehavior("trainer evaluation reads its effective speed", {}))
    end
    local power = math.floor((foe * 25) / user) + 1
    if power > 150 then
      power = 150
    end
    return power
  elseif moveId == 237 then
    local record = Context.battlerFacts(state, atk)
    local ivs = record.ivs --[[@as table<string, integer>]]
    local function second(key)
      local value = ivs[key] --[[@as integer]]
      if value == nil then
        error(BattleErrors.missingBehavior("trainer evaluation reads its individual values", {}))
      end
      return math.floor(value / 2) % 2
    end
    local combo = second("hp")
      + 2 * second("attack")
      + 4 * second("defense")
      + 8 * second("speed")
      + 16 * second("specialAttack")
      + 32 * second("specialDefense")
    return 30 + math.floor((combo * 40) / 63)
  elseif moveId == 363 then
    -- Natural Gift stages the held berry power from the projected map.
    -- Without a held gift the estimate stages no power: the held-item
    -- arm leaves the working power cleared, so the preview reads zero
    -- instead of guessing.
    local record = Context.battlerFacts(state, atk)
    local item = record.item --[[@as integer]]
    if item == 0 then
      return 0
    end
    local gifts = facts.naturalGifts --[[@as table<integer, table<string, integer>>]]
    local gift = gifts[item]
    if gift == nil then
      return 0
    end
    return gift.power --[[@as integer]]
  elseif moveId == 449 then
    -- Judgment stages the compiled power at the plate type resolved by
    -- the effective-type arm above.
    return basePower
  end
  return basePower
end
-- Knockout preview for the current move (handlers ov10_0221D7CC/D8F8
-- core): the staged matchup estimate the knockout gates compare against
-- target health.
---@param state TrainerAiProgramState command state under execution
---@return integer staged matchup estimate under the knockout check
function matchupPreview(state)
  return matchupValue(state, state.slot, 100)
end
-- Damage-class preview with the 40-base pipeline (handlers ov10_0221D260
-- for opcode 42 across the moveset, ov10_0221D314 for opcode 43 on the
-- current move): staged damage classifies into the effectiveness
-- ladder with immunity forcing zero.
---@param state TrainerAiProgramState command state under execution
---@param moveId integer numeric move identity under preview
---@return integer effectiveness class under comparison
function previewDamageClass(state, moveId)
  local facts = state.facts --[[@as table<string, unknown>]]
  local byId = facts.moveById --[[@as table<integer, table<string, unknown>>]]
  local detail = byId[moveId]
  if type(detail) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", {
      move = moveId,
    }))
  end
  local workingType = (function()
    local ids = Data.TYPE_IDS --[[@as table<string, integer>]]
    local numeric = ids[
      detail.moveType --[[@as string]]
    ]
    if numeric == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its move type", { move = moveId }))
    end
    return numeric
  end)()
  local effective = effectiveMoveType(state, moveId)
  if effective == 0 then
    effective = workingType
  end
  local damage, immune = pipelinePreview(state, moveId, effective, 40)
  return damageClass(damage, immune)
end
-- Protect-class load (handler ov10_0221EBAC for opcode 74): a stored
-- protect move in 182/197/203 leaves scratch untouched, anything else
-- loads bits 11-12 of the battler word (zero across modeled battles).
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
function protectClassLoad(state, selector)
  local facts = state.facts --[[@as table<string, unknown>]]
  local battler = Context.resolveBattler(state, selector)
  local stored = facts.protectMove --[[@as table<integer, integer>]]
  local moveId = stored[battler] or 0
  if moveId ~= 182 and moveId ~= 197 and moveId ~= 203 then
    state.scratch = 0
  end
end
-- Physical/special category decider (handler ov10_0221D188 for opcode
-- 83): suppressed abilities clear the working value; selectors 0/2
-- resolve through the entry ability, trapping abilities, and species
-- base stats with the operand comparison; selectors 1/3 read the live
-- battler ability directly, storing 2 for absent battlers. The working
-- value stores 2/1/0 by zero/match/mismatch against the operand.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
---@param expect integer class under comparison
function categoryDecide(state, selector, expect)
  local facts = state.facts --[[@as table<string, unknown>]]
  local battler = Context.resolveBattler(state, selector)
  local battlers = facts.battlers --[[@as table<integer, table<string, unknown>>]]
  local record = Context.battlerFacts(state, battler)
  local working = nil ---@type integer?
  if record.suppressed == true then
    working = 0
  elseif selector == 1 or selector == 3 then
    if battlers[battler] == nil then
      working = 0
    else
      working = record.ability --[[@as integer]]
    end
  elseif selector == 0 or selector == 2 or battlers[battler] == nil then
    local entry = record.entryAbility
    if entry == nil then
      entry = record.ability --[[@as integer]]
    end
    if entry ~= 0 then
      working = entry
    else
      local ability = record.ability --[[@as integer]]
      if Data.TRAPPING_IDS[ability] == true then
        working = ability
      else
        local pair = record.speciesAbilities
        if type(pair) ~= "table" then
          error(BattleErrors.missingBehavior("trainer evaluation reads its species abilities", {}))
        end
        local first = pair[1] --[[@as integer]]
        local second = pair[2] --[[@as integer]]
        if first == 0 or second == 0 then
          if first ~= 0 then
            working = first
          else
            working = second
          end
        elseif first == expect or second == expect then
          working = 0
        else
          working = first
        end
      end
    end
  else
    error(BattleErrors.missingBehavior("trainer programs read outside modeled memory", {
      selector = selector,
    }))
  end
  assert(working ~= nil, "category decisions resolve their working value")
  if working == 0 then
    state.scratch = 2
  elseif working == expect then
    state.scratch = 1
  else
    state.scratch = 0
  end
end
-- Knockout gates (handlers ov10_0221D7CC for opcode 53, ov10_0221D8F8
-- for opcode 54): mode 1 compares the target health against the matchup
-- estimate for the current move; opcode 53 jumps when health exceeds the
-- estimate, opcode 54 when it does not. Other modes return at once.
---@param state TrainerAiProgramState command state under execution
---@param mode integer estimate selector under evaluation
---@param jump integer relative word distance under the taken branch
---@param kind integer 53/54 selecting the comparison
---@return integer? jump target under the taken branch, nil to fall through
function knockoutGate(state, mode, jump, kind)
  if mode ~= 1 then
    return nil
  end
  local facts = state.facts --[[@as table<string, unknown>]]
  local tgt = facts.tgt --[[@as integer]]
  local record = Context.battlerFacts(state, tgt)
  local estimate = matchupPreview(state)
  if kind == 53 then
    if
      record.hp --[[@as integer]]
      > estimate
    then
      return jump
    end
    return nil
  end
  if
    record.hp --[[@as integer]]
    <= estimate
  then
    return jump
  end
  return nil
end
-- Move-fact loads selected by scratch-held identity (handlers ov10_0221EB4C
-- for opcode 71 reading type, ov10_0221EB6C for opcode 72 reading power,
-- ov10_0221EB8C for opcode 73 reading effect): the scratch register
-- takes the compiled fact of the move identity it holds.
---@param state TrainerAiProgramState command state under execution
---@param kind integer 71/72/73 selecting the detail
function moveDetailLoad(state, kind)
  local facts = state.facts --[[@as table<string, unknown>]]
  local byId = facts.moveById --[[@as table<integer, table<string, unknown>>]]
  local record = byId[state.scratch]
  if type(record) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", {
      move = state.scratch,
    }))
  end
  if kind == 71 then
    local ids = Data.TYPE_IDS --[[@as table<string, integer>]]
    local numeric = ids[
      record.moveType --[[@as string]]
    ]
    if numeric == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its move type", {}))
    end
    state.scratch = numeric
  elseif kind == 72 then
    state.scratch = record.power --[[@as integer]]
  else
    state.scratch = record.effect --[[@as integer]]
  end
end
-- Species/max-health party jump (handler ov10_0221DF88 for opcode 88):
-- any party member outside the battler's own slot whose health differs
-- from its maximum jumps.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector owning the party under the scan
---@param jump integer relative word distance under the taken branch
---@return integer? jump target under the taken branch, nil to fall through
function speciesHpGate(state, selector, jump)
  local facts = state.facts --[[@as table<string, unknown>]]
  local battler = Context.resolveBattler(state, selector)
  local parties = facts.parties --[[@as table<integer, table<integer, table<string, unknown>>>]]
  local members = parties[battler]
  if type(members) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its party facts", { battler = battler }))
  end
  local own = facts.partyIndex --[[@as table<integer, integer>]]
  for index, member in ipairs(members) do
    local entry = member --[[@as table<string, unknown>]]
    if index ~= own[battler] then
      local hp = entry.hp --[[@as integer]]
      local maxHp = entry.maxHp --[[@as integer]]
      if hp ~= maxHp then
        return jump
      end
    end
  end
  return nil
end
-- Speed rank into scratch (handler ov10_0221E1CC for opcode 95):
-- battlers sort by effective speed with the native pairwise order and
-- the selector battler's zero-based rank stores. Tied pairs resolve
-- through the shared stream exactly as the sort does.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under the rank
---@return integer zero-based speed rank under the evaluation
function speedRank(state, selector)
  local facts = state.facts --[[@as table<string, unknown>]]
  local wanted = Context.resolveBattler(state, selector)
  local count = facts.battlerCount --[[@as integer]]
  if type(count) ~= "number" or count < 1 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its battler count", {}))
  end
  local order = {}
  for battler = 0, count - 1 do
    order[#order + 1] = battler
  end
  for i = 1, #order do
    for j = i + 1, #order do
      if comparePair(state, order[i], order[j]) then
        order[i], order[j] = order[j], order[i]
      end
    end
  end
  for rank, battler in ipairs(order) do
    if battler == wanted then
      state.scratch = rank - 1
      return rank - 1
    end
  end
  error(BattleErrors.missingBehavior("trainer programs rank their battlers", {}))
  return 0
end
-- Pairwise speed order (CheckSortSpeed with the operand flag set):
-- true orders the first battler after the second (slower, or tie lost
-- through the shared stream). Priority clocks fail closed; Trick Room
-- inverts the order with identical tie draws.
---@param state TrainerAiProgramState command state under execution
---@param first integer first battler identity under comparison
---@param second integer second battler identity under comparison
---@return boolean true when the first sorts after the second
function comparePair(state, first, second)
  local facts = state.facts --[[@as table<string, unknown>]]
  for _, battler in ipairs({ first, second }) do
    local record = Context.battlerFacts(state, battler)
    if record.ability == 100 then
      error(BattleErrors.missingBehavior("trainer evaluation reads its speed order", {}))
    end
    local item = record.item --[[@as integer]]
    if item ~= 0 then
      local held = facts.heldEffects --[[@as table<integer, integer>]]
      local effect = held[item]
      if effect == nil then
        error(BattleErrors.missingBehavior("trainer evaluation reads its held item facts", { item = item }))
      end
      if effect == 52 or effect == 45 or effect == 107 then
        error(BattleErrors.missingBehavior("trainer evaluation reads its priority clock", { item = item }))
      end
    end
  end
  local firstSpeed = Context.effectiveSpeed(state, first)
  local secondSpeed = Context.effectiveSpeed(state, second)
  local trick = facts.trickRoom --[[@as boolean]]
  if trick == nil then
    error(BattleErrors.missingBehavior("trainer evaluation reads its trick room", {}))
  end
  if trick then
    if firstSpeed > secondSpeed then
      return true
    elseif firstSpeed == secondSpeed then
      local roll = Context.drawNow(state)
      return roll % 2 == 1
    end
    return false
  end
  if firstSpeed < secondSpeed then
    return true
  elseif firstSpeed == secondSpeed then
    local roll = Context.drawNow(state)
    return roll % 2 == 1
  end
  return false
end
-- Party matchup jump (handler ov10_0221E2CC for opcode 97): the attacker
-- runs its four-slot staged preview at scale 100, then every conscious
-- non-egg party member outside the attacker's own slot runs the same
-- preview over its own moves, held item, ability, and individual values
-- against the shared live battlers; the first member strictly above the
-- attacker's best takes the jump. Member health, species, and moves
-- read exactly like the sibling party scans; the member's own stats never
-- enter the preview. The scale operand stays 0 on every transcribed path
-- and anything else fails closed.
---@param state TrainerAiProgramState command state under execution
---@param best integer staged scale selector under evaluation, 0 for 100
---@param jump integer relative word distance under the taken branch
---@return integer? jump target under the taken branch, nil to fall through
function partyMatchupGate(state, best, jump)
  if best ~= 0 then
    error(BattleErrors.missingBehavior("trainer programs scan their party matchups", {
      best = best,
      jump = jump,
    }))
  end
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local attackerBest = 0
  for slot = 0, 3 do
    local value = matchupValue(state, slot, 100)
    if value > attackerBest then
      attackerBest = value
    end
  end
  local parties = facts.parties --[[@as table<integer, table<integer, table<string, unknown>>>]]
  local members = parties[atk]
  if type(members) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its party facts", { battler = atk }))
  end
  local own = facts.partyIndex --[[@as table<integer, integer>]]
  local ownSlot = own[atk]
  local moveIdByKey = facts.moveIdByKey --[[@as table<string, integer>]]
  local abilityIds = Data.ABILITY_IDS --[[@as table<string, integer>]]
  local attacker = Context.battlerFacts(state, atk)
  for index, entry in ipairs(members) do
    if type(entry) == "table" and index - 1 ~= ownSlot then
      local member = entry --[[@as table<string, unknown>]]
      local hp = member.hp --[[@as integer]]
      if type(hp) ~= "number" or hp % 1 ~= 0 then
        error(BattleErrors.missingBehavior("trainer evaluation reads its party health", {}))
      end
      if hp ~= 0 then
        local species = member.species --[[@as string]]
        if type(species) == "string" and species ~= "" and species ~= "EGG" then
          local memberBest = memberPreview(state, member, attacker, moveIdByKey, abilityIds)
          if memberBest > attackerBest then
            return jump
          end
        end
      end
    end
  end
  return nil
end
-- Staged best over one party member's moves (ov10_0221E2CC member loop
-- through ov10_0221EF7C/ov10_0221F084): the member's four move identities
-- resolve through the shared move maps, then the member runs the staged
-- pipeline over the attacker's record with its own moves, ability, held
-- item, and individual values. Members without a usable move preview
-- zero; anything the preview needs but the member lacks fails closed
-- exactly where the shared pipeline reads it.
---@param state TrainerAiProgramState command state under execution
---@param member table<string, unknown> party member under preview
---@param attacker table<string, unknown> live attacker record sharing its battlers
---@param moveIdByKey table<string, integer> native move identities by move key
---@param abilityIds table<string, integer> native ability identities by ability key
---@return integer staged best over the member moves at scale 100
function memberPreview(state, member, attacker, moveIdByKey, abilityIds)
  local ids = { 0, 0, 0, 0 }
  local usable = false
  local moves = member.moves --[[@as table<integer, table<string, unknown>>]]
  if type(moves) == "table" then
    for slot = 1, 4 do
      local entry = moves[slot]
      if type(entry) == "table" then
        local key = (entry --[[@as table<string, unknown>]]).move --[[@as string]]
        if type(key) == "string" and key ~= "" then
          local id = moveIdByKey[key]
          if id == nil then
            error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", { key = key }))
          end
          ids[slot] = id
          if id ~= 0 then
            usable = true
          end
        end
      end
    end
  end
  if not usable then
    return 0
  end
  local abilityKey = member.ability --[[@as string]]
  local ability = 0
  if abilityKey ~= nil then
    if type(abilityKey) ~= "string" then
      error(BattleErrors.missingBehavior("trainer evaluation reads its ability identity", {}))
    end
    local id = abilityIds[abilityKey]
    if id == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its ability identity", {}))
    end
    ability = id
  end
  if member.heldKey ~= nil then
    error(BattleErrors.missingBehavior("trainer evaluation reads its held item facts", { item = member.heldKey }))
  end
  local record = {}
  for key, value in pairs(attacker) do
    record[key] = value
  end
  record.moves = ids
  record.ability = ability
  record.item = member.item or 0
  record.ivs = member.ivs
  -- The member preview substitutes the member's species alongside its
  -- moves, ability, item, and values; otherwise species-gated previews
  -- would read the attacker's species for the member's moves.
  record.species = member.species
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local battlers = {}
  for battler, listed in
    pairs(facts.battlers --[[@as table<integer, table<string, unknown>>]])
  do
    battlers[battler] = listed
  end
  battlers[atk] = record
  local previewFacts = {}
  for key, value in pairs(facts) do
    previewFacts[key] = value
  end
  previewFacts.battlers = battlers
  local memberState = { facts = previewFacts, rng = state.rng, bit = state.bit, slot = 0 }
  local memberBest = 0
  for slot = 0, 3 do
    memberState.slot = slot
    local value = matchupValue(memberState, slot, 100)
    if value > memberBest then
      memberBest = value
    end
  end
  return memberBest
end
-- Stay check through the super-effective scan (handler ov10_0221E460
-- for opcode 98 calling ov10_0221FD34 with a set flag): the attacker
-- jumps the operand distance when some usable move is super-effective.
-- The set flag decides draw-free; the cleared flag spends stay draws
-- and is owned by the switch gate layer.
---@param state TrainerAiProgramState command state under execution
---@param jump integer relative word distance under the taken branch
---@return integer? jump target under the taken branch, nil to fall through
function stayCheck(state, jump)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  for _, moveId in ipairs(Context.battlerMoveIds(state, atk)) do
    if moveId ~= 0 then
      local _, _, super = pipelinePreview(state, moveId, moveTypeOf(state, moveId), 0)
      if super then
        return jump
      end
    end
  end
  return nil
end
-- Working move type for pipeline checks: the compiled type with the
-- effective override applied.
---@param state TrainerAiProgramState command state under execution
---@param moveId integer numeric move identity under resolution
---@return integer working move type under evaluation
function moveTypeOf(state, moveId)
  local facts = state.facts --[[@as table<string, unknown>]]
  local byId = facts.moveById --[[@as table<integer, table<string, unknown>>]]
  local record = byId[moveId]
  if type(record) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", {
      move = moveId,
    }))
  end
  local ids = Data.TYPE_IDS --[[@as table<string, integer>]]
  local base = ids[
    record.moveType --[[@as string]]
  ]
  if base == nil then
    error(BattleErrors.missingBehavior("trainer evaluation reads its move type", { move = moveId }))
  end
  local override = effectiveMoveType(state, moveId)
  if override == 0 then
    return base
  end
  return override
end
-- Stat-compare jumps through the battler stat helper (handlers
-- ov10_0221E650/E6A4/E6F8 for opcodes 102/103/104): attacker and
-- selector stats compare as </>/== and skip the jump distance. The
-- stat selector spans hp/atk/def/speed/spatk/spdef.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under comparison
---@param stat integer stat selector 0..5 under comparison
---@param jump integer relative word distance under the taken branch
---@param kind integer 102/103/104 selecting the comparison
---@return integer? jump target under the taken branch, nil to fall through
function statCompareGate(state, selector, stat, jump, kind)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local first = Context.battlerFacts(state, atk)
  local second = Context.battlerFacts(state, Context.resolveBattler(state, selector))
  local keys = { "hp", "atk", "def", "spe", "spa", "spd" }
  local key = keys[stat + 1]
  if key == nil then
    error(BattleErrors.missingBehavior("trainer programs compare their battler stats", { stat = stat }))
  end
  local a = first[key] --[[@as integer]]
  local b = second[key] --[[@as integer]]
  local take = false
  if kind == 102 then
    take = a < b
  elseif kind == 103 then
    take = a > b
  else
    take = a == b
  end
  if take then
    return jump
  end
  return nil
end
-- Ally-aware matchup rank (handler ov10_0221E848 for opcode 105):
-- the acting battler previews its four moves against the unchanged
-- target first; a stronger own move demotes at once without previewing
-- the partner. Otherwise the acting partner previews its own four
-- moves against the same target, and any partner value strictly
-- greater than the original acting selected value demotes. Only a lead
-- on both answers 2. Ineligible moves keep the ordinary rank's zero.
-- The partner evaluation reuses the same preview through a
-- function-local facts view, so shared facts and live battler records
-- stay untouched.
---@param state TrainerAiProgramState command state under execution
---@param scaleMode integer literal scale operand under the previews
---@return integer effectiveness class 0/1/2 under the rank
function allyMatchupRank(state, scaleMode)
  if not matchupEligible(state) then
    return 0
  end
  local facts = state.facts --[[@as table<string, unknown>]]
  local ownValues = matchupValues(state, scaleMode)
  -- Rank demotion is strict. Ties keep the selected move at rank 2.
  local selected = ownValues[state.slot + 1]
  for _, value in ipairs(ownValues) do
    if value > selected then
      return 1
    end
  end
  -- The partner pass changes only attacker identity.
  local partnerFacts = {}
  for key, value in pairs(facts) do
    partnerFacts[key] = value
  end
  partnerFacts.atk = Context.partnerOf(facts.atk --[[@as integer]])
  -- partnerFacts.tgt remains facts.tgt
  local probe = {
    facts = partnerFacts,
    rng = state.rng,
    bit = state.bit,
    slot = state.slot,
    thresholds = state.thresholds,
    points = state.points,
    cur = state.cur,
    scratch = state.scratch,
  }
  for _, value in ipairs(matchupValues(probe, scaleMode)) do
    if value > selected then
      return 1
    end
  end
  return 2
end
-- Switch-in flag jumps (handlers ov10_0221E9A4 for opcode 106,
-- ov10_0221E9F4 for opcode 107): the battler bit in the switch-in word
-- jumps when set (106) or clear (107). Absent battlers never switched
-- in and read clear; present battlers read the modeled entry bit, which
-- marks battlers with no live mon available and reads clear otherwise.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
---@param jump integer relative word distance under the taken branch
---@param set boolean true jumps when the bit is set
---@return integer? jump target under the taken branch, nil to fall through
function switchInGate(state, selector, jump, set)
  local facts = state.facts --[[@as table<string, unknown>]]
  local battler = Context.resolveBattler(state, selector)
  local live = facts.liveBattlers --[[@as table<integer, boolean>]]
  if live[battler] ~= true then
    if set then
      return nil
    end
    return jump
  end
  local entered = facts.switchIn --[[@as table<integer, boolean>?]]
  local bit = type(entered) == "table" and entered[battler] == true
  if bit == set then
    return jump
  end
  return nil
end
-- Matchup-compare jump (handler ov10_0221E498 for opcode 99): the
-- attacker's best four-slot staged preview at the operand scale races
-- the resolved battler's previous-move preview at the executing slot
-- scale, and the jump takes only when the previous move reads strictly
-- greater. An absent previous move previews zero. The previous-move
-- preview reuses the shared staged core with function-local facts that
-- name the resolved battler as the attacker, so shared facts stay
-- untouched.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector owning the previous move
---@param scaleMode integer threshold scale selector under the previews
---@param jump integer relative word distance under the taken branch
---@return integer? jump target under the taken branch, nil to fall through
function matchupCompareGate(state, selector, scaleMode, jump)
  local best = 0
  for _, value in ipairs(matchupValues(state, scaleMode)) do
    if value > best then
      best = value
    end
  end
  local facts = state.facts --[[@as table<string, unknown>]]
  local previousBattler = Context.resolveBattler(state, selector)
  local lasts = facts.lastMove --[[@as table<integer, integer>]]
  local previousMove = lasts[previousBattler] or 0
  local previousValue = 0
  if previousMove ~= 0 then
    local scale = matchupScale(state, scaleMode, state.slot)
    local previewFacts = {}
    for key, value in pairs(facts) do
      previewFacts[key] = value
    end
    previewFacts.atk = previousBattler
    local preview = {
      facts = previewFacts,
      rng = state.rng,
      bit = state.bit,
      slot = state.slot,
      thresholds = state.thresholds,
      points = state.points,
      cur = state.cur,
      scratch = state.scratch,
    }
    previousValue = previewMove(preview, previousMove, scale)
  end
  if previousValue > best then
    return jump
  end
  return nil
end
-- Encore-slot jumps (handler ov10_0221DCEC for opcode 59): battlers 0
-- and 1 test the low and high encore-index bits respectively; other
-- battlers return at once. The encore slot arrives 0-based with
-- absence reading zero.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
---@param jump integer relative word distance under the taken branch
---@return integer? jump target under the taken branch, nil to fall through
function encoreGate(state, selector, jump)
  local battler = Context.resolveBattler(state, selector)
  if battler ~= 0 and battler ~= 1 then
    return nil
  end
  local facts = state.facts --[[@as table<string, unknown>]]
  local slots = facts.encoreSlot --[[@as table<integer, integer>]]
  local slot = slots[battler] or 0
  local hit = false
  if battler == 0 then
    hit = (slot % 8) ~= 0
  else
    hit = (math.floor(slot / 8) % 8) ~= 0
  end
  if hit then
    return jump
  end
  return nil
end
-- Foreign held-effect load (handler ov10_0221DE24 for opcode 65): when
-- the resolved battler is not the attacker, scratch takes the hold
-- effect of its held item; the attacker leaves scratch untouched.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
function itemEffectLoad(state, selector)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local battler = Context.resolveBattler(state, selector)
  if battler == atk then
    return
  end
  local record = Context.battlerFacts(state, battler)
  local item = record.item --[[@as integer]]
  if item == 0 then
    state.scratch = 0
    return
  end
  local held = facts.heldEffects --[[@as table<integer, integer>]]
  local effect = held[item]
  if effect == nil then
    error(BattleErrors.missingBehavior("trainer evaluation reads its held item facts", { item = item }))
  end
  state.scratch = effect
end
-- Power-point use jumps (handler ov10_0221E018 for opcode 89): any party
-- member outside the battler's own slot with current power points below
-- the slot maximum jumps. Maxima derive from base power points and ups.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
---@param jump integer relative word distance under the taken branch
---@return integer? jump target under the taken branch, nil to fall through
function ppUseGate(state, selector, jump)
  local facts = state.facts --[[@as table<string, unknown>]]
  local battler = Context.resolveBattler(state, selector)
  local parties = facts.parties --[[@as table<integer, table<integer, table<string, unknown>>>]]
  local members = parties[battler]
  if type(members) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its party facts", { battler = battler }))
  end
  local own = facts.partyIndex --[[@as table<integer, integer>]]
  local byId = facts.moveById --[[@as table<integer, table<string, unknown>>]]
  for index, member in ipairs(members) do
    local entry = member --[[@as table<string, unknown>]]
    if index ~= own[battler] then
      local moves = entry.moves --[[@as table<integer, table<string, unknown>>]]
      if type(moves) ~= "table" then
        error(BattleErrors.missingBehavior("trainer evaluation reads its party moves", {}))
      end
      for _, slot in ipairs(moves) do
        local detail = slot --[[@as table<string, unknown>]]
        local key = detail.move --[[@as string]]
        local ids = facts.moveIdByKey --[[@as table<string, integer>]]
        local id = ids[key]
        if id == nil then
          error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", {}))
        end
        local record = byId[id]
        if type(record) ~= "table" then
          error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", { move = id }))
        end
        local base = record.basePp
        if type(base) ~= "number" then
          error(BattleErrors.missingBehavior("trainer evaluation reads its base power points", { move = id }))
        end
        local ups = detail.ppUps --[[@as integer]]
        if ups == nil then
          ups = 0
        end
        if ups > 3 then
          ups = 3
        end
        local maxPp = Moves.maxPp(base, ups)
        if
          detail.pp --[[@as integer]]
          ~= maxPp
        then
          return jump
        end
      end
    end
  end
  return nil
end
Preview.calcPreview = calcPreview
Preview.pipelinePreview = pipelinePreview
Preview.previewMove = previewMove
Preview.matchupValue = matchupValue
Preview.matchupValues = matchupValues
Preview.matchupRank = matchupRank
Preview.maxDamageClass = maxDamageClass
Preview.damageClassGate = damageClassGate
Preview.knockoutGate = knockoutGate
Preview.moveDetailLoad = moveDetailLoad
Preview.protectClassLoad = protectClassLoad
Preview.categoryDecide = categoryDecide
Preview.speciesHpGate = speciesHpGate
Preview.speedRank = speedRank
Preview.partyMatchupGate = partyMatchupGate
Preview.stayCheck = stayCheck
Preview.matchupCompareGate = matchupCompareGate
Preview.statCompareGate = statCompareGate
Preview.allyMatchupRank = allyMatchupRank
Preview.switchInGate = switchInGate
Preview.encoreGate = encoreGate
Preview.itemEffectLoad = itemEffectLoad
Preview.ppUseGate = ppUseGate

return Preview
