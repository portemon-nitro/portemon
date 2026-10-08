-- Shared stateless native readers for the trainer interpreter
-- (pret/pokeheartgold asm/overlay_10_trainer_ai.s word, signed, battler,
-- score, and speed primitives). Every helper reads caller-provided words,
-- facts, or scores and owns no mutable session or cached facts. The
-- command and preview owners share these readers; nothing here reaches
-- back into the command owner or the program facade.

local BattleErrors = require("libs.battle.src.errors")
local Data = require("libs.battle.src.gen4.TrainerAiProgramData")

---@class TrainerAiContext
local Context = {}

---@class TrainerAiProgramState
---@field points integer[] four native move points in slot order
---@field thresholds integer[] four stored 100-(draw%16) thresholds in slot order
---@field slot integer zero-based native move slot under execution
---@field cur integer current numeric move identity under execution, 0 for none
---@field scratch integer word-sized scratch register under execution
---@field bit integer enabled native flag bit under execution
---@field facts table<string, unknown> source-visible battle facts under execution
---@field rng table<string, unknown> caller-owned battle stream for program draws

-- Forward declaration for the speed comparator defined below.
local compareSpeed
---@param words table<integer, integer> word stream under indexed read
---@param index integer absolute word index under read
---@return integer word value at the index
local function wordAt(words, index)
  local word = words[index - Data.BASE + 1]
  if type(word) ~= "number" then
    error(BattleErrors.missingBehavior("trainer programs address their transcribed words", { index = index }))
  end
  return word
end
---@param word integer unsigned 32-bit word under signed read
---@return integer signed interpretation of the word
local function signed(word)
  if word >= 2147483648 then
    return word - 4294967296
  end
  return word
end
---@param words table<integer, integer> word stream under indexed read
---@param pc integer absolute word index of the opcode under read
---@return integer opcode at the program counter
local function fetchOp(words, pc)
  local op = wordAt(words, pc)
  if op < 0 or op > 108 then
    error(BattleErrors.missingBehavior("trainer programs dispatch their transcribed commands", { op = op }))
  end
  return op
end
---@param state TrainerAiProgramState command state under the draw
---@return integer full-width battle-stream draw at this command site
local function drawNow(state)
  return state.rng:nextU16("program_chance", { flag = state.bit, slot = state.slot })
end
---@param state TrainerAiProgramState command state under resolution
---@param selector integer battler selector under resolution
---@return integer resolved battler identity 0..3
local function resolveBattler(state, selector)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local tgt = facts.tgt --[[@as integer]]
  if selector == 0 then
    return tgt
  elseif selector == 1 then
    return atk
  elseif selector == 2 then
    if tgt == 0 then
      return 2
    elseif tgt == 1 then
      return 3
    elseif tgt == 2 then
      return 0
    else
      return 1
    end
  elseif selector == 3 then
    if atk == 0 then
      return 2
    elseif atk == 1 then
      return 3
    elseif atk == 2 then
      return 0
    else
      return 1
    end
  end
  return tgt
end
---@param state TrainerAiProgramState command state under inspection
---@param battler integer battler identity under lookup
---@return table<string, unknown> battler facts, zeroed when the battler is absent
local function battlerFacts(state, battler)
  local facts = state.facts --[[@as table<string, unknown>]]
  local battlers = facts.battlers --[[@as table<integer, table<string, unknown>>]]
  local record = battlers[battler]
  if type(record) == "table" then
    return record
  end
  return {
    hp = 0,
    maxHp = 0,
    level = 0,
    t1 = 0,
    t2 = 0,
    ability = 0,
    item = 0,
    status = 0,
    status2 = 0,
    moveFlags = 0,
    atk = 0,
    def = 0,
    spa = 0,
    spd = 0,
    spe = 0,
    stages = { 6, 6, 6, 6, 6, 6, 6, 6 },
    moves = { 0, 0, 0, 0 },
    pp = { 0, 0, 0, 0 },
    gender = 0,
    weightHg = 0,
    friendship = 0,
    ivs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 },
    lastMove = 0,
    entryMoves = { 0, 0, 0, 0 },
    entryAbility = 0,
    speciesAbilities = { 0, 0 },
    suppressed = false,
    magnetRise = false,
    roosted = false,
    miracleEye = false,
    foresight = false,
    flingPower = 0,
    w88b1 = 0,
    w88neg = false,
    w94 = 0,
    enteredWithItem = false,
  }
end
---@param points integer[] move points under adjustment
---@param slot integer zero-based move slot under adjustment
---@param amount integer signed adjustment under application
local function addPoints(points, slot, amount)
  local wrapped = (points[slot + 1] + amount) % 256
  if wrapped >= 128 then
    wrapped = wrapped - 256
  end
  if wrapped < 0 then
    wrapped = 0
  end
  points[slot + 1] = wrapped
end
---@param value integer word value under signed comparison
---@return integer signed interpretation for ordered branches
local function asSigned(value)
  if value >= 2147483648 then
    return value - 4294967296
  end
  return value
end
-- Attacker moveset facts for damaging-move and known-move scans.
---@param state TrainerAiProgramState command state under execution
---@param battler integer battler identity under the scan
---@return table<integer, integer> numeric move identities in slot order
local function battlerMoveIds(state, battler)
  local record = battlerFacts(state, battler)
  local moves = record.moves --[[@as table<integer, integer>]]
  return { moves[1] or 0, moves[2] or 0, moves[3] or 0, moves[4] or 0 }
end
---@param battler integer battler identity owning the lookup
---@return integer partner battler identity on the same side
local function partnerOf(battler)
  if battler == 0 then
    return 2
  elseif battler == 2 then
    return 0
  elseif battler == 1 then
    return 3
  elseif battler == 3 then
    return 1
  end
  error(BattleErrors.missingBehavior("trainer programs resolve their partner", { battler = battler }))
  return 0
end
-- Effective speed under the native staged formula: unstaged battle speed
-- scaled by the signed stage ratio with truncation, then weather
-- abilities, paralysis, and tailwind adjust exactly. Unburden doubles
-- only the emptied holder, while priority clocks, Slow Start, and
-- speed-relevant hold effects fail closed when present; other hold
-- effects leave speed untouched.
---@param state TrainerAiProgramState command state under execution
---@param battler integer battler identity under evaluation
---@return integer effective speed under the native formula
local function effectiveSpeed(state, battler)
  local record = battlerFacts(state, battler)
  local base = record.spe
  if type(base) ~= "number" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its battle speed", {}))
  end
  local stages = record.stages --[[@as table<integer, integer>]]
  local stage = (stages[4] or 6) - 6
  local numerator = 2
  local denominator = 2
  if stage >= 0 then
    numerator = 2 + stage
  else
    denominator = 2 - stage
  end
  local speed = math.floor((base * numerator) / denominator)
  local ability = record.ability --[[@as integer]]
  local facts = state.facts --[[@as table<string, unknown>]]
  local weather = facts.weatherClass --[[@as integer]]
  if ability == 33 or ability == 34 then
    if (ability == 33 and weather == 2) or (ability == 34 and weather == 3) then
      speed = speed * 2
    end
  end
  local status = record.status --[[@as integer]]
  if ability == 95 then
    if status % 256 ~= 0 then
      speed = math.floor((speed * 15) / 10)
    end
  elseif status % 128 >= 64 then
    speed = math.floor(speed / 4)
  end
  if ability == 112 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its speed clock", { ability = ability }))
  elseif ability == 84 then
    -- Unburden doubles speed only once the holder lost its item: the
    -- entry flag tells the holder arrived with one while the current
    -- item tells it is gone. Laden and never-laden holders preview
    -- untouched.
    if record.item == 0 and record.enteredWithItem == true then
      speed = speed * 2
    end
  end
  local item = record.item --[[@as integer]]
  if item ~= 0 then
    local held = facts.heldEffects --[[@as table<integer, integer>]]
    local effect = held[item]
    if effect == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its held item facts", { item = item }))
    end
    if Data.SPEED_HALVING[effect] == true then
      speed = math.floor(speed / 2)
    elseif effect == 115 then
      speed = math.floor((speed * 15) / 10)
    elseif effect == 102 or effect == 52 or effect == 45 or effect == 107 then
      error(BattleErrors.missingBehavior("trainer evaluation reads its priority clock", { item = item }))
    end
  end
  local sides = facts.sideWords --[[@as table<integer, integer>]]
  local side = battler % 2
  local word = sides[side] or 0
  if (math.floor(word / 256) % 4) ~= 0 then
    speed = speed * 2
  end
  return speed
end
-- Speed-order comparison (CheckSortSpeed with the operand flag, handler
-- ov10_0221CF04/CF48 core): 1 when the attacker is slower, 2 on a drawn
-- tie the attacker wins, 0 otherwise. Trick Room inverts the order;
-- priority clocks fail closed when present.
---@param state TrainerAiProgramState command state under execution
---@return integer comparison result under the operand test
function compareSpeed(state)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local tgt = facts.tgt --[[@as integer]]
  local first = effectiveSpeed(state, atk)
  local second = effectiveSpeed(state, tgt)
  local trick = facts.trickRoom --[[@as boolean]]
  if trick == nil then
    error(BattleErrors.missingBehavior("trainer evaluation reads its trick room", {}))
  end
  local slowFirst = first < second
  if trick then
    slowFirst = first > second
  end
  if slowFirst then
    return 1
  end
  if first == second then
    local roll = drawNow(state)
    if roll % 2 == 1 then
      return 2
    end
  end
  return 0
end
-- Staged battle stat under the native damage formula: unstaged stat
-- scaled by the signed stage ratio with truncation. Stages arrive in
-- native 0..12 centering.
---@param base integer unstaged battle stat under staging
---@param nativeStage integer native stage 0..12 under application
---@return integer staged stat under the native ratio
local function stagedStat(base, nativeStage)
  local stage = nativeStage - 6
  local numerator = 2
  local denominator = 2
  if stage >= 0 then
    numerator = 2 + stage
  else
    denominator = 2 - stage
  end
  return math.floor((base * numerator) / denominator)
end
Context.wordAt = wordAt
Context.signed = signed
Context.fetchOp = fetchOp
Context.drawNow = drawNow
Context.resolveBattler = resolveBattler
Context.battlerFacts = battlerFacts
Context.addPoints = addPoints
Context.asSigned = asSigned
Context.battlerMoveIds = battlerMoveIds
Context.partnerOf = partnerOf
Context.stagedStat = stagedStat
Context.effectiveSpeed = effectiveSpeed
Context.compareSpeed = compareSpeed

return Context
