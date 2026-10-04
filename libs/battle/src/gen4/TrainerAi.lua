-- Private native trainer decision policy for the Generation IV session.
-- Execution follows the pinned opponent model (pret/pokeheartgold
-- src/battle/trainer_ai.c ov10_0221BE20 for scratch initialization,
-- asm/overlay_10_trainer_ai.s ov10_0221BF44 for the singles selector,
-- ov10_0221C038 for the doubles selector, ov10_0221C278 with table
-- ov10_0222B0B4 for program dispatch over the program data at
-- ov10_02220AAC, ov10_022205BC for action order, ov10_022203A4 with the
-- opponent-controller replacement at ov12_02258800 for switching, and
-- ov10_022206B0 for trainer items): usable move slots open at the native
-- baseline with slot-ordered initialization draws whose stored
-- 100-(draw%16) thresholds later commands may read, enabled flag
-- programs run in ascending bit order, doubles evaluates candidate
-- targets through its own selector, the switch gate answers before the
-- item path, items scan ordered source slots, and persistent knowledge
-- plus slot order ride the native session record. Effectiveness resolves
-- through the passed session chart, damage previews reuse the shared
-- staged arithmetic with an explicit roll, and every random branch draws
-- from the caller-owned battle stream in a stable order. Per-evaluation
-- scratch is local and discarded; only the session record persists.

local BattleContext = require("libs.battle.src.BattleContext")
local BattleErrors = require("libs.battle.src.errors")
local BattleState = require("libs.battle.src.BattleState")
local CaptureContext = require("libs.battle.src.gen4.CaptureContext")
local Damage = require("libs.battle.src.gen4.Damage")
local Experience = require("libs.mons.src.gen4.Experience")
local ItemUse = require("libs.battle.src.gen4.ItemUse")
local Personality = require("libs.mons.src.gen4.Personality")
local StatStages = require("libs.battle.src.gen4.StatStages")
local Stats = require("libs.mons.src.gen4.Stats")
local Switching = require("libs.battle.src.gen4.Switching")
local TrainerAiProgram = require("libs.battle.src.gen4.TrainerAiProgram")
local TypeEffectiveness = require("libs.battle.src.gen4.TypeEffectiveness")

---@class TrainerAi
local TrainerAi = {}

-- Usable move slots open at the native baseline; spent and empty slots
-- stay excluded at zero for the struggle path.
TrainerAi.OPENING_SCORE = 100

-- Forward declarations: scoring can run from its pinned boundary before
-- the shared evaluation helpers below are defined.
local initThresholds
local scoreWithThresholds

-- Schema mark for the persisted native record.
TrainerAi.MEMORY_VERSION = 1

-- Native flag bits with program data, in dispatch order. The doubles bit
-- never appears here: doubles behavior derives from the live battle
-- format instead of a stored pass.
local SUPPORTED_BITS = {
  [0] = true,
  [1] = true,
  [2] = true,
  [3] = true,
  [5] = true,
  [6] = true,
  [9] = true,
}

-- Live battle formats that route attack evaluation through the doubles
-- selector. Singles spellings stay on the singles path.
local DOUBLE_FORMATS = {
  double = true,
  doubles = true,
}

-- Trapping abilities that hold the exchange at the switch gate.
local TRAPPING_ABILITIES = {
  SHADOW_TAG = true,
  ARENA_TRAP = true,
}

-- Battle-use volatile flags the item policy inspects.
local BATTLE_CURE_FLAGS = { "confusion", "infatuation" }

---@class TrainerAiMove
---@field key string executing move identity, empty for vacant slots
---@field moveType string semantic move type
---@field power integer compiled move power, zero for status moves
---@field category string physical, special, or status
---@field accuracy integer compiled hit chance
---@field effect integer compiled move effect identity gating routine draws
---@field usable boolean false for vacant and power-point-exhausted slots

---@class TrainerAiStats
---@field types string[] semantic combatant types in declared order
---@field level integer battle level
---@field attack integer stage-effective physical attack
---@field defense integer stage-effective physical defense
---@field specialAttack integer stage-effective special attack
---@field specialDefense integer stage-effective special defense

---@class TrainerAiAuthorities
---@field chart table<string, unknown> session chart resolving directed pairs
---@field moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@field speciesFacts table<string, table<integer, table<string, unknown>>> static species facts by species and form
---@field itemFacts table<string, table<string, unknown>> immutable item facts carried by the session

---@class TrainerAiCommandVm
---@field bit integer enabled native flag bit under execution
---@field scores table<integer, integer> native score points under adjustment
---@field thresholds table<integer, integer> stored 100-(draw%16) thresholds in slot order
---@field slots TrainerAiMove[] four native move slots in source order
---@field user TrainerAiStats acting stats and types under scoring
---@field foe TrainerAiStats opposing stats and types under scoring
---@field foeHp integer opposing health bounding the knockout check
---@field bestPower integer strongest usable damaging power bounding the faint check
---@field chart table<string, unknown> session chart resolving directed pairs
---@field stream table<string, unknown> caller-owned battle stream, never drawn by commands

--- Translates generated pass names to native flag bits in ascending
--- dispatch order. Malformed, unknown, and unsupported names fail closed
--- with structured missing behavior before any draw instead of answering
--- a fallback move. Repeated names collapse to one bit.
---@param aiPasses string[] generated pass names
---@return integer[] native flag bits in ascending order
function TrainerAi.parsePasses(aiPasses)
  assert(type(aiPasses) == "table", "trainer passes arrive as a name list")
  local seen = {}
  local bits = {}
  for index, pass in ipairs(aiPasses) do
    local digits = type(pass) == "string" and pass:match("^ai_pass_(%d+)$") or nil
    local bit = (type(digits) == "string" and tonumber(digits)) or nil
    if bit == nil or SUPPORTED_BITS[bit] ~= true then
      error(BattleErrors.missingBehavior("trainer passes name a supported native flag", {
        pass = tostring(pass),
        index = index,
      }))
    end
    assert(bit ~= nil, "supported pass bits stay numeric")
    if seen[bit] ~= true then
      seen[bit] = true
      bits[#bits + 1] = bit
    end
  end
  table.sort(bits)
  return bits
end

---@param chart table<string, unknown> session chart resolving directed pairs
---@param moveType string attacking type under evaluation
---@param defenderTypes string[] defending types in declared order
---@return integer numerator
---@return integer denominator combined multiplier for the directed pair set
local function combineMultiplier(chart, moveType, defenderTypes)
  local resolved = TypeEffectiveness.resolve(chart, moveType, defenderTypes, {})
  return resolved.numerator, resolved.denominator
end

---@param moveType string attacking type under evaluation
---@param userTypes string[] attacker types in declared order
---@return integer numerator
---@return integer denominator same-type attack bonus
local function stabPair(moveType, userTypes)
  if TypeEffectiveness.stab(moveType, userTypes) then
    return 3, 2
  end
  return 1, 1
end

---@param power integer compiled move power
---@param stabNumerator integer same-type attack bonus numerator
---@param stabDenominator integer same-type attack bonus denominator
---@param effectNumerator integer combined effectiveness numerator
---@param effectDenominator integer combined effectiveness denominator
---@return integer native score points for the matchup
local function matchupPoints(power, stabNumerator, stabDenominator, effectNumerator, effectDenominator)
  return math.floor((power * stabNumerator * effectNumerator) / (stabDenominator * effectDenominator))
end

---@param value unknown candidate battle stat under evaluation
---@param name string stat being read
---@return integer validated battle stat
local function checkStat(value, name)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its battle stats", { stat = name }))
  end
  return value
end

---@param types unknown candidate semantic types under evaluation
---@return string[] validated semantic types in declared order
local function checkTypes(types)
  if type(types) ~= "table" or #types == 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its semantic types", {}))
  end
  local out = {}
  for _, key in
    ipairs(types --[[@as string[] ]])
  do
    if type(key) ~= "string" or key == "" then
      error(BattleErrors.missingBehavior("trainer evaluation reads its semantic types", {}))
    end
    out[#out + 1] = key
  end
  return out
end

---@param stats unknown candidate battle stats under evaluation
---@return TrainerAiStats validated battle stats and types
local function checkFighterStats(stats)
  assert(type(stats) == "table", "evaluation reads explicit battle stats")
  local record = stats --[[@as table<string, unknown>]]
  return {
    types = checkTypes(record.types),
    level = checkStat(record.level, "level"),
    attack = checkStat(record.attack, "attack"),
    defense = checkStat(record.defense, "defense"),
    specialAttack = checkStat(record.specialAttack, "specialAttack"),
    specialDefense = checkStat(record.specialDefense, "specialDefense"),
  }
end

---@param move unknown candidate move under evaluation
---@return TrainerAiMove validated move facts for scoring
local function checkScoringMove(move)
  assert(type(move) == "table", "evaluation reads explicit move facts")
  local record = move --[[@as table<string, unknown>]]
  if type(record.key) ~= "string" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its move identity", {}))
  end
  if type(record.moveType) ~= "string" or record.moveType == "" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its move type", { key = record.key }))
  end
  if type(record.power) ~= "number" or record.power % 1 ~= 0 or record.power < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move power", { key = record.key }))
  end
  if type(record.category) ~= "string" or record.category == "" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its move category", { key = record.key }))
  end
  if type(record.accuracy) ~= "number" or record.accuracy % 1 ~= 0 or record.accuracy < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled accuracy", { key = record.key }))
  end
  if type(record.effect) ~= "number" or record.effect % 1 ~= 0 or record.effect < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move effect", { key = record.key }))
  end
  return {
    key = record.key --[[@as string]],
    moveType = record.moveType --[[@as string]],
    power = record.power --[[@as integer]],
    category = record.category --[[@as string]],
    accuracy = record.accuracy --[[@as integer]],
    effect = record.effect --[[@as integer]],
    usable = record.usable == true,
  }
end

-- Estimates one strike through the shared staged arithmetic with an
-- explicit maximum roll, so previews draw nothing from the decision
-- stream. Only damaging moves preview; callers skip status moves.
---@param chart table<string, unknown> session chart resolving directed pairs
---@param attacker TrainerAiStats attacker stats and types under evaluation
---@param move TrainerAiMove damaging move under evaluation
---@param defender TrainerAiStats defender stats and types under evaluation
---@param stream table<string, unknown> caller-owned battle stream, never drawn by previews
---@return integer estimated damage amount
local function previewDamage(chart, attacker, move, defender, stream)
  assert(move.power > 0, "damage previews evaluate damaging moves")
  local effectNumerator, effectDenominator = combineMultiplier(chart, move.moveType, defender.types)
  local stabNumerator, stabDenominator = stabPair(move.moveType, attacker.types)
  local attack = attacker.attack
  local defense = defender.defense
  if move.category == "special" then
    attack = attacker.specialAttack
    defense = defender.specialDefense
  end
  local result = Damage.calculate({
    level = attacker.level,
    power = move.power,
    attack = attack,
    defense = defense,
    stab = { numerator = stabNumerator, denominator = stabDenominator },
    effectiveness = { numerator = effectNumerator, denominator = effectDenominator },
    randomPercent = 100,
  }, stream)
  return result.amount
end

---@param move TrainerAiMove candidate move under the damaging check
---@return boolean true for usable moves with compiled power
local function isDamaging(move)
  return move.usable and move.power > 0
end

--- Executes one semantic program command for the addressed slot. This is
--- the interpreter dispatch behind the source jump table: every
--- supported opcode implements its exact branch and score adjustment,
--- and anything outside the transcribed set fails closed before any
--- fallback choice.
---@param vm TrainerAiCommandVm command state under execution
---@param slot integer one-based native move slot under execution
---@param command table<string, unknown> semantic command under execution
local function dispatchCommand(vm, slot, command)
  assert(type(command) == "table", "program commands stay records")
  local record = command --[[@as table<string, unknown>]]
  local move = vm.slots[slot]
  assert(move ~= nil, "program commands address their move slot")
  if record.op == "add_matchup" then
    local effectNumerator, effectDenominator = combineMultiplier(vm.chart, move.moveType, vm.foe.types)
    local stabNumerator, stabDenominator = stabPair(move.moveType, vm.user.types)
    vm.scores[slot] = vm.scores[slot]
      + matchupPoints(move.power, stabNumerator, stabDenominator, effectNumerator, effectDenominator)
  elseif record.op == "punish_immune" then
    assert(type(record.amount) == "number", "punishments carry their amount")
    local effectNumerator, _ = combineMultiplier(vm.chart, move.moveType, vm.foe.types)
    if effectNumerator == 0 then
      vm.scores[slot] = vm.scores[slot] - record.amount --[[@as integer]]
    end
  elseif record.op == "punish_weaker" then
    assert(type(record.amount) == "number", "punishments carry their amount")
    if isDamaging(move) and move.power < vm.bestPower then
      vm.scores[slot] = vm.scores[slot] - record.amount --[[@as integer]]
    end
  elseif record.op == "bonus_if_doubly_effective" then
    assert(type(record.amount) == "number", "bonuses carry their amount")
    if isDamaging(move) then
      local effectNumerator, effectDenominator = combineMultiplier(vm.chart, move.moveType, vm.foe.types)
      if effectNumerator == 4 * effectDenominator and vm.thresholds[slot] < TrainerAiProgram.CHANCE_MARK then
        vm.scores[slot] = vm.scores[slot] + record.amount --[[@as integer]]
      end
    end
  elseif record.op == "bonus_if_effective" then
    assert(type(record.amount) == "number", "bonuses carry their amount")
    if isDamaging(move) then
      local effectNumerator, effectDenominator = combineMultiplier(vm.chart, move.moveType, vm.foe.types)
      if effectNumerator >= 2 * effectDenominator then
        vm.scores[slot] = vm.scores[slot] + record.amount --[[@as integer]]
      end
    end
  elseif record.op == "punish_if_resisted" then
    assert(type(record.amount) == "number", "punishments carry their amount")
    if isDamaging(move) then
      local effectNumerator, effectDenominator = combineMultiplier(vm.chart, move.moveType, vm.foe.types)
      if effectNumerator > 0 and effectNumerator < effectDenominator then
        vm.scores[slot] = vm.scores[slot] - record.amount --[[@as integer]]
      end
    end
  elseif record.op == "prefer_stab" then
    assert(type(record.bonus) == "number", "preferences carry their bonus")
    assert(type(record.penalty) == "number", "preferences carry their penalty")
    if isDamaging(move) then
      if TypeEffectiveness.stab(move.moveType, vm.user.types) then
        vm.scores[slot] = vm.scores[slot] + record.bonus --[[@as integer]]
      else
        vm.scores[slot] = vm.scores[slot] - record.penalty --[[@as integer]]
      end
    end
  elseif record.op == "bonus_if_knockout" then
    assert(type(record.amount) == "number", "bonuses carry their amount")
    if isDamaging(move) and previewDamage(vm.chart, vm.user, move, vm.foe, vm.stream) >= vm.foeHp then
      vm.scores[slot] = vm.scores[slot] + record.amount --[[@as integer]]
    end
  elseif record.op == "bonus_if_baton_pass" then
    assert(type(record.amount) == "number", "bonuses carry their amount")
    if move.key == "BATON_PASS" then
      vm.scores[slot] = vm.scores[slot] + record.amount --[[@as integer]]
    end
  elseif record.op == "bonus_first_slot" then
    assert(type(record.amount) == "number", "bonuses carry their amount")
    for index, candidate in ipairs(vm.slots) do
      if candidate.usable then
        vm.scores[index] = vm.scores[index] + record.amount --[[@as integer]]
        break
      end
    end
  else
    error(BattleErrors.missingBehavior("trainer programs dispatch their transcribed commands", {
      bit = vm.bit,
      op = tostring(record.op),
    }))
  end
end

--- Executes one semantic program command for the addressed slot through
--- the production interpreter. Production scoring calls this per
--- slot; tests may invoke it with a synthetic command to prove unknown
--- opcodes fail closed before any fallback choice.
---@param vm TrainerAiCommandVm command state under execution
---@param slot integer one-based native move slot under execution
---@param command table<string, unknown> semantic command under execution
function TrainerAi.runCommand(vm, slot, command)
  assert(type(vm) == "table", "program commands execute against command state")
  assert(type(slot) == "number" and slot % 1 == 0 and slot >= 1 and slot <= 4, "commands address a move slot")
  dispatchCommand(vm, slot, command)
end

---@param bit integer enabled native flag bit under lookup
---@return table<string, table<integer, table<string, unknown>>> semantic program for the bit
local function programFor(bit)
  local program = TrainerAiProgram.PROGRAMS[bit]
  if type(program) ~= "table" then
    error(BattleErrors.missingBehavior("trainer scoring names a transcribed native flag", { flag = bit }))
  end
  return program --[[@as table<string, table<integer, table<string, unknown>>>]]
end

---@class TrainerAiScoredSlot
---@field slot integer zero-based native move slot
---@field key string executing move identity, empty for vacant slots
---@field score integer native score points after flag evaluation

--- Scores the four native move slots exactly as the source
--- initialization does: usable slots open at the native baseline,
--- unavailable slots stay excluded at zero, and the four initialization
--- draws occur in source slot order with their stored 100-(draw%16)
--- thresholds before enabled flag evaluation. Enabled flags dispatch in
--- ascending bit order with each program evaluating every usable slot;
--- score commands draw nothing, routine-draw sites draw per reached
--- slot, and selection draws separately below.
---@param chart table<string, unknown> session chart resolving directed pairs
---@param slots TrainerAiMove[] four native move slots in source order
---@param user TrainerAiStats acting stats and types under scoring
---@param foe TrainerAiStats opposing stats and types under scoring
---@param foeHp integer opposing health bounding the knockout check
---@param bits integer[] enabled native flag bits in ascending order
---@param firstTurn boolean true while the opening turn gates routine draws
---@param stream table<string, unknown> caller-owned battle stream for decision draws
---@return TrainerAiScoredSlot[] scored slots in source slot order
function TrainerAi.scoreSlots(chart, slots, user, foe, foeHp, bits, firstTurn, stream)
  assert(type(chart) == "table", "scoring resolves effectiveness through the session chart")
  assert(type(slots) == "table" and #slots == 4, "scoring covers the four native move slots")
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "scoring draws from the battle stream")
  assert(type(bits) == "table", "scoring dispatches the enabled flag bits")
  assert(type(firstTurn) == "boolean", "scoring names its opening turn for routine draws")
  assert(type(foeHp) == "number" and foeHp % 1 == 0 and foeHp >= 0, "scoring bounds its knockout check")
  for _, slot in ipairs(slots) do
    checkScoringMove(slot)
  end
  checkFighterStats(user)
  checkFighterStats(foe)
  local ordered = {}
  for _, bit in ipairs(bits) do
    assert(type(bit) == "number" and bit % 1 == 0, "enabled flag bits stay numeric")
    ordered[#ordered + 1] = bit
  end
  table.sort(ordered)
  for _, bit in ipairs(ordered) do
    programFor(bit --[[@as integer]])
  end
  local thresholds = initThresholds(stream)
  return scoreWithThresholds(chart, slots, user, foe, foeHp, ordered, thresholds, firstTurn, stream)
end

--- Selects the executing move from scored slots after the source singles
--- selector (ov10_0221BF44): the highest native points win, equal-top
--- ties break uniformly through exactly one selection draw, and a lone
--- leader still spends that draw so the downstream stream never shifts.
---@param scored TrainerAiScoredSlot[] scored slots in source slot order
---@param stream table<string, unknown> caller-owned battle stream for the selection draw
---@return integer zero-based native move slot answering the foe
function TrainerAi.selectMove(scored, stream)
  assert(type(scored) == "table" and #scored > 0, "move selection reads its scored slots")
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "move selection draws from the battle stream")
  local top = scored[1].score
  for index = 2, #scored do
    if scored[index].score > top then
      top = scored[index].score
    end
  end
  local tied = {}
  for _, entry in ipairs(scored) do
    assert(type(entry.score) == "number", "scored slots carry their native points")
    assert(type(entry.slot) == "number", "scored slots carry their native slot")
    if entry.score == top then
      tied[#tied + 1] = entry.slot
    end
  end
  assert(#tied > 0, "a top score always names at least one slot")
  local draw = stream:nextU16("selection_roll", { tied = #tied })
  return tied[(draw % #tied) + 1]
end

---@class TrainerAiTargetBid
---@field target integer live opposing position under evaluation
---@field slot integer zero-based native move slot answering that target
---@field score integer native score points behind the bid

--- Selects the doubles target and move from per-target bids after the
--- source doubles selector (ov10_0221C038): the highest bid wins and
--- equal-top bids break uniformly through exactly one selection draw.
---@param bids TrainerAiTargetBid[] evaluated target bids in position order
---@param stream table<string, unknown> caller-owned battle stream for the selection draw
---@return integer live opposing position answering the strike
---@return integer zero-based native move slot answering the strike
function TrainerAi.selectDoubles(bids, stream)
  assert(type(bids) == "table" and #bids > 0, "doubles selection reads its target bids")
  assert(
    type(stream) == "table" and type(stream.nextU16) == "function",
    "doubles selection draws from the battle stream"
  )
  local top = bids[1].score
  for index = 2, #bids do
    assert(type(bids[index].target) == "number", "target bids name their position")
    assert(type(bids[index].slot) == "number", "target bids name their move slot")
    assert(type(bids[index].score) == "number", "target bids carry their native points")
    if bids[index].score > top then
      top = bids[index].score
    end
  end
  local tied = {}
  for _, bid in ipairs(bids) do
    if bid.score == top then
      tied[#tied + 1] = bid
    end
  end
  assert(#tied > 0, "a top bid always names at least one target")
  local draw = stream:nextU16("doubles_selection", { tied = #tied })
  local winner = tied[(draw % #tied) + 1]
  return winner.target, winner.slot
end

--- Selects the opposing battler in source target order: with more than
--- one live opposing entry one draw chooses uniformly among them in
--- position order, while a lone foe is addressed with no draw.
---@param opponents integer[] live opposing combatants in position order
---@param stream table<string, unknown> caller-owned battle stream for the target draw
---@return integer chosen opposing combatant
function TrainerAi.selectTarget(opponents, stream)
  assert(type(opponents) == "table" and #opponents > 0, "target selection reads its opposing entries")
  assert(
    type(stream) == "table" and type(stream.nextU16) == "function",
    "target selection draws from the battle stream"
  )
  for _, combatant in ipairs(opponents) do
    assert(
      type(combatant) == "number" and combatant % 1 == 0 and combatant >= 1,
      "opposing entries name their combatant"
    )
  end
  if #opponents == 1 then
    return opponents[1]
  end
  local draw = stream:nextU16("target_foe", { opponents = #opponents })
  return opponents[(draw % #opponents) + 1]
end

---@param slots unknown candidate ordered item slots under validation
local function checkMemorySlots(slots)
  if type(slots) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("trainer memory carries its ordered item slots", {}))
  end
  local count = 0
  for index, item in
    ipairs(slots --[[@as table<integer, unknown>]])
  do
    count = count + 1
    assert(index == count, "trainer item slots stay ordered")
    if type(item) ~= "string" or item == "" then
      error(BattleErrors.incompatibleSnapshot("trainer item slots name their item", { slot = index }))
    end
  end
end

---@param known unknown candidate learned-move record under validation
local function checkKnownMoves(known)
  if type(known) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("trainer memory carries its learned moves", {}))
  end
  for foeId, moves in
    pairs(known --[[@as table<integer, unknown>]])
  do
    if type(foeId) ~= "number" or foeId % 1 ~= 0 or foeId < 1 then
      error(BattleErrors.incompatibleSnapshot("learned moves name their foe", {}))
    end
    if type(moves) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("learned moves carry their move set", { foe = foeId }))
    end
    for key, seen in
      pairs(moves --[[@as table<string, unknown>]])
    do
      if type(key) ~= "string" or key == "" or seen ~= true then
        error(BattleErrors.incompatibleSnapshot("learned moves name their move", { foe = foeId }))
      end
    end
  end
end

--- Validates a restored native trainer record. Snapshots missing the
--- record or carrying a foreign shape are incompatible: these are
--- transient pre-release snapshots with no migration path.
---@param memory unknown restored native trainer record under validation
---@return boolean true for a well-formed current record
function TrainerAi.validateMemory(memory)
  if type(memory) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("native snapshots carry their trainer record", {}))
  end
  local record = memory --[[@as table<string, unknown>]]
  if record.version ~= TrainerAi.MEMORY_VERSION then
    error(BattleErrors.incompatibleSnapshot("trainer records carry their current schema mark", {
      version = tostring(record.version),
    }))
  end
  if type(record.controllers) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("trainer records carry their controller memory", {}))
  end
  for controller, entry in
    pairs(record.controllers --[[@as table<string, unknown>]])
  do
    if type(controller) ~= "string" or controller == "" or type(entry) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("trainer memory names its controller", {}))
    end
    local owned = entry --[[@as table<string, unknown>]]
    checkMemorySlots(owned.slots)
    checkKnownMoves(owned.knownMoves)
    for key, value in pairs(owned) do
      if key ~= "slots" and key ~= "knownMoves" then
        error(BattleErrors.incompatibleSnapshot("trainer memory carries only its slots and knowledge", {
          field = tostring(key),
        }))
      end
      assert(value ~= nil, "trainer memory fields stay present")
    end
  end
  return true
end

---@param participant table<string, unknown> acting participant owning the roster and stock
---@param state table<string, unknown> live battle state under inspection
---@return string[] ordered trainer item identities for the controller
local function orderedItemSlots(participant, state)
  local context = participant.context
  if type(context) == "table" and type(context.trainerItems) == "table" then
    local slots = {}
    for index, item in
      ipairs(context.trainerItems --[[@as table<integer, unknown>]])
    do
      if type(item) ~= "string" or item == "" then
        error(BattleErrors.missingBehavior("trainer item slots name their item", { slot = index }))
      end
      slots[#slots + 1] = item --[[@as string]]
    end
    return slots
  end
  -- Without source-ordered slots the scan order is unrecoverable:
  -- quantity maps carry no order, so a stocked trainer without
  -- metadata fails closed instead of answering alphabetical stock.
  -- Trainers with no live stock need no order and stay empty.
  local inventoryId = participant.inventoryId
  if type(inventoryId) ~= "string" then
    return {}
  end
  local inventories = state.inventories
  if type(inventories) ~= "table" then
    return {}
  end
  local stock = inventories[inventoryId]
  if type(stock) ~= "table" or type(stock.quantities) ~= "table" then
    return {}
  end
  for key, units in
    pairs(stock.quantities --[[@as table<string, unknown>]])
  do
    if type(key) == "string" and key ~= "" and type(units) == "number" and units % 1 == 0 and units > 0 then
      error(BattleErrors.missingBehavior("trainer item order arrives as source-ordered slots", {
        controller = tostring(participant.controller),
      }))
    end
  end
  return {}
end

--- Creates the fresh native trainer record once per native session after
--- generic state construction. Slot order comes from the trainer item
--- context; learned opponent knowledge starts empty and is only ever
--- filled through battle observation, never seeded from records.
---@param state table<string, unknown> live battle state under initialization
---@return table<string, unknown> the initialized native trainer record
function TrainerAi.initializeMemory(state)
  assert(type(state) == "table", "trainer memory initializes from live battle state")
  assert(type(state.participantOrder) == "table", "trainer memory reads its participants")
  local memory = { version = TrainerAi.MEMORY_VERSION, controllers = {} }
  local owned = memory.controllers --[[@as table<string, table<string, unknown>>]]
  for _, participantId in
    ipairs(state.participantOrder --[[@as integer[] ]])
  do
    local participant = BattleState.participant(state, participantId --[[@as integer]])
    local controller = participant.controller
    if type(controller) == "string" and controller:sub(1, 8) == "trainer:" and owned[controller] == nil then
      owned[controller] = { slots = orderedItemSlots(participant, state), knownMoves = {} }
    end
  end
  state.trainerAi = memory
  return memory
end

---@param state table<string, unknown> live battle state under inspection
---@return table<string, table<string, unknown>>? native trainer memory, when present
local function liveMemory(state)
  local memory = state.trainerAi
  if type(memory) ~= "table" then
    return nil
  end
  return memory --[[@as table<string, table<string, unknown>>]]
end

---@param state table<string, unknown> live battle state under inspection
---@param controller string acting trainer controller under memory lookup
---@return table<string, unknown>? controller memory, when the session tracks it
local function controllerMemory(state, controller)
  local memory = liveMemory(state)
  if memory == nil then
    return nil
  end
  local controllers = memory.controllers
  if type(controllers) ~= "table" then
    return nil
  end
  local entry = (controllers --[[@as table<string, unknown>]])[controller]
  if type(entry) ~= "table" then
    return nil
  end
  return entry --[[@as table<string, unknown>]]
end

--- Records an executed strike in every opposing trainer memory. Learned
--- knowledge only ever grows through observation; a fresh entry clears
--- it again at the battler reset boundary.
---@param state table<string, unknown> live battle state under observation
---@param userId integer striking combatant under observation
---@param moveKey string executed move identity under observation
function TrainerAi.observeMove(state, userId, moveKey)
  assert(type(state) == "table", "move observation reads live battle state")
  if type(userId) ~= "number" or userId % 1 ~= 0 or userId < 1 then
    return
  end
  if type(moveKey) ~= "string" or moveKey == "" then
    return
  end
  local memory = liveMemory(state)
  if memory == nil then
    return
  end
  local user = BattleState.combatant(state, userId)
  local userSide = BattleState.participant(state, user.participant --[[@as integer]]).side
  for _, participantId in
    ipairs(state.participantOrder --[[@as integer[] ]])
  do
    local participant = BattleState.participant(state, participantId)
    if participant.side ~= userSide and type(participant.controller) == "string" then
      local entry = controllerMemory(state, participant.controller --[[@as string]])
      if entry ~= nil then
        local known = entry.knownMoves
        if type(known) == "table" then
          local byFoe = known --[[@as table<integer, unknown>]]
          local moves = byFoe[userId]
          if type(moves) ~= "table" then
            moves = {}
            byFoe[userId] = moves
          end
          local moveSet = moves --[[@as table<string, boolean>]]
          moveSet[moveKey] = true
        end
      end
    end
  end
end

--- Clears learned knowledge about an entering combatant in every trainer
--- memory. A new entry fights unknown again while ordered item slots
--- survive; this runs at the source-equivalent battler reset boundary.
---@param state table<string, unknown> live battle state under entry reset
---@param incomingId integer entering combatant under reset
function TrainerAi.noteArrival(state, incomingId)
  assert(type(state) == "table", "entry reset reads live battle state")
  if type(incomingId) ~= "number" or incomingId % 1 ~= 0 or incomingId < 1 then
    return
  end
  local memory = liveMemory(state)
  if memory == nil then
    return
  end
  local controllers = memory.controllers
  if type(controllers) ~= "table" then
    return
  end
  for _, entry in
    pairs(controllers --[[@as table<string, unknown>]])
  do
    if type(entry) == "table" then
      local known = (entry --[[@as table<string, unknown>]]).knownMoves
      if type(known) == "table" then
        local byFoe = known --[[@as table<integer, unknown>]]
        byFoe[incomingId] = nil
      end
    end
  end
end

---@param speciesFacts table<string, table<integer, table<string, unknown>>> static species facts by species and form
---@param mon table<string, unknown> battle mon record under fact sampling
---@return table<string, unknown> static species facts for the record
local function staticFacts(speciesFacts, mon)
  assert(type(speciesFacts) == "table", "evaluation reads the session species facts")
  local species = mon.species
  local form = mon.form
  if type(species) ~= "string" or species == "" or type(form) ~= "number" or form % 1 ~= 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its combat facts", { fact = "species" }))
  end
  local byForm = speciesFacts[species]
  local static = type(byForm) == "table" and byForm[form]
  if type(static) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its static species facts", { fact = species }))
  end
  return static --[[@as table<string, unknown>]]
end

---@param mon table<string, unknown> battle mon record under evaluation
---@param stages unknown battle-local stat stages for the entry
---@param speciesFacts table<string, table<integer, table<string, unknown>>> static species facts by species and form
---@return TrainerAiStats level and stage-effective battle stats for evaluation
local function estimateFighter(mon, stages, speciesFacts)
  if type(mon) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its combat facts", { fact = "mon" }))
  end
  local record = mon --[[@as table<string, unknown>]]
  local static = staticFacts(speciesFacts, record)
  if type(static.baseStats) ~= "table" or type(static.growthCurve) ~= "table" or type(static.types) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its static species facts", {
      fact = record.species,
    }))
  end
  local experience = record.experience
  local personality = record.personality
  if type(experience) ~= "number" or experience % 1 ~= 0 or experience < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its combat facts", { fact = "experience" }))
  end
  if type(personality) ~= "number" or personality % 1 ~= 0 or personality < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its combat facts", { fact = "personality" }))
  end
  if type(record.ivs) ~= "table" or type(record.evs) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its combat facts", { fact = "effort" }))
  end
  local level = Experience.level(static.growthCurve --[[@as integer[] ]], experience)
  local nature = Personality.nature(personality)
  local stats = Stats.calculate(
    static.baseStats --[[@as table<string, integer>]],
    record.ivs --[[@as table<string, integer>]],
    record.evs --[[@as table<string, integer>]],
    level,
    nature
  )
  if type(stages) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its battle-local stages", {}))
  end
  local staged = stages --[[@as table<string, integer>]]
  local combat = {
    level = level,
    types = {} --[[@as string[] ]],
    attack = 0,
    defense = 0,
    specialAttack = 0,
    specialDefense = 0,
  }
  for _, key in
    ipairs(static.types --[[@as string[] ]])
  do
    if type(key) ~= "string" or key == "" then
      error(BattleErrors.missingBehavior("trainer evaluation reads its semantic type facts", { fact = "types" }))
    end
    combat.types[#combat.types + 1] = key
  end
  for _, key in ipairs({ "attack", "defense", "specialAttack", "specialDefense" }) do
    local stage = staged[key] or 0
    if type(stage) ~= "number" or stage % 1 ~= 0 or stage < StatStages.MIN or stage > StatStages.MAX then
      error(BattleErrors.missingBehavior("trainer evaluation reads its battle-local stages", {}))
    end
    combat[key] = StatStages.effective(stats[key] --[[@as integer]], stage, key)
  end
  return combat
end

---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@param key unknown executing move identity under resolution
---@return table<string, unknown> immutable move facts for the identity
local function factsFor(moveFacts, key)
  if type(key) ~= "string" or key == "" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its move identity", {}))
  end
  local record = moveFacts[key]
  if type(record) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", { key = key }))
  end
  return record
end

---@param mon table<string, unknown> battle mon record under slot resolution
---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@return TrainerAiMove[] four native move slots in source order
local function resolveSlots(mon, moveFacts)
  local entries = mon.moves
  if type(entries) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its move entries", {}))
  end
  local slots = {}
  for index = 1, 4 do
    local entry = entries[index]
    if type(entry) ~= "table" then
      slots[index] = {
        key = "",
        moveType = "typeless",
        power = 0,
        category = "status",
        accuracy = 0,
        effect = 0,
        usable = false,
      }
    else
      local record = entry --[[@as table<string, unknown>]]
      local facts = factsFor(moveFacts, record.move)
      local power = facts.power
      local moveType = facts.moveType
      local category = facts.category
      local accuracy = facts.accuracy
      local effect = facts.effect
      if type(power) ~= "number" or power % 1 ~= 0 or power < 0 then
        error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move power", { key = record.move }))
      end
      if type(effect) ~= "number" or effect % 1 ~= 0 or effect < 0 then
        error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move effect", { key = record.move }))
      end
      if type(moveType) ~= "string" or moveType == "" then
        error(BattleErrors.missingBehavior("trainer evaluation reads its move type", { key = record.move }))
      end
      if type(category) ~= "string" or category == "" then
        error(BattleErrors.missingBehavior("trainer evaluation reads its move category", { key = record.move }))
      end
      if type(accuracy) ~= "number" or accuracy % 1 ~= 0 or accuracy < 0 then
        error(BattleErrors.missingBehavior("trainer evaluation reads its compiled accuracy", { key = record.move }))
      end
      local pp = record.pp
      slots[index] = {
        key = record.move,
        moveType = moveType,
        power = power,
        category = category,
        accuracy = accuracy,
        effect = effect --[[@as integer]],
        usable = type(pp) ~= "number" or pp > 0,
      }
    end
  end
  return slots
end

---@param state table<string, unknown> live battle state under inspection
---@param ownSide integer acting side under opponent resolution
---@return table<integer, table<string, unknown>> live opposing entries in position order
local function opposingEntries(state, ownSide)
  local opponents = {}
  for _, positionId in
    ipairs(state.positionOrder --[[@as integer[] ]])
  do
    local position = BattleState.position(state, positionId)
    local occupant = position.occupant
    if occupant ~= nil and position.side ~= ownSide then
      local combatant = BattleState.combatant(state, occupant --[[@as integer]])
      if combatant.active ~= nil then
        opponents[#opponents + 1] = { position = positionId, combatant = occupant }
      end
    end
  end
  return opponents
end

---@param state table<string, unknown> live battle state under inspection
---@param combatantId integer acting combatant under the trap check
---@return boolean true while binding effects hold the combatant down
local function isTrapped(state, combatantId)
  local combatant = BattleState.combatant(state, combatantId)
  local held = combatant.trap
  if type(held) == "table" and held.held == true then
    return true
  end
  local bag = state.effectBag
  if type(bag) == "table" and type(bag.capture) == "function" then
    local capture = bag.capture --[[@as fun(self: table<string, unknown>): table<integer, table<string, unknown>>]]
    for _, record in ipairs(capture(bag)) do
      local scope = record.scope
      if
        (record.key == "bind" or record.key == "trapped")
        and type(scope) == "table"
        and scope.combatant == combatantId
      then
        return true
      end
    end
  end
  return false
end

---@param mon unknown battle-local mon record under ability inspection
---@return string? battle ability key, when one is named
local function battleAbility(mon)
  if type(mon) ~= "table" then
    return nil
  end
  local ability = (mon --[[@as table<string, unknown>]]).ability
  if type(ability) ~= "string" or ability == "" or ability == "NONE" then
    return nil
  end
  return ability
end

---@param state table<string, unknown> live battle state under inspection
---@param combatant table<string, unknown> acting combatant under the trap check
---@param holderTypes string[] acting semantic types in declared order
---@param opponents table<integer, table<string, unknown>> live opposing entries in position order
---@return boolean true while abilities or effects hold the exchange
local function switchHeld(state, combatant, holderTypes, opponents)
  if
    isTrapped(state, combatant.id --[[@as integer]])
  then
    return true
  end
  for _, key in ipairs(holderTypes) do
    if key == "ghost" then
      return false
    end
  end
  for _, opposed in ipairs(opponents) do
    local foe = BattleState.combatant(state, opposed.combatant)
    local ability = battleAbility(foe.mon)
    if ability ~= nil and TRAPPING_ABILITIES[ability] == true then
      return true
    end
  end
  return false
end

---@param state table<string, unknown> live battle state under reserve inspection
---@param participant table<string, unknown> acting participant owning the roster
---@param exclude table<integer, boolean> combatants already answering this request
---@return integer[] living benched roster identities in roster order
local function livingReserves(state, participant, exclude)
  local reserves = {}
  for _, combatantId in
    ipairs(participant.roster --[[@as integer[] ]])
  do
    local combatant = BattleState.combatant(state, combatantId --[[@as integer]])
    if
      combatant.active == nil
      and combatant.hp --[[@as integer]]
        > 0
      and not exclude[combatantId]
    then
      reserves[#reserves + 1] = combatantId
    end
  end
  return reserves
end

---@class TrainerAiReserveFacts
---@field id integer benched combatant identity
---@field stats TrainerAiStats battle stats and types under evaluation
---@field slots TrainerAiMove[] reserve moves in slot order

---@class TrainerAiFoeFacts
---@field id integer opposing combatant identity
---@field position integer opposing position identity
---@field stats TrainerAiStats battle stats and types under evaluation
---@field hp integer opposing health bounding the knockout check

---@param slots TrainerAiMove[] candidate moves in slot order
---@return boolean true with at least one usable damaging move
local function hasDamaging(slots)
  for _, move in ipairs(slots) do
    if isDamaging(move) then
      return true
    end
  end
  return false
end

---@param slots TrainerAiMove[] candidate moves in slot order
---@return boolean true with at least one usable slot
local function hasUsable(slots)
  for _, move in ipairs(slots) do
    if move.usable then
      return true
    end
  end
  return false
end

---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@param key string learned move identity under resolution
---@return TrainerAiMove damaging-capable move facts for preview
local function previewMove(moveFacts, key)
  local facts = factsFor(moveFacts, key)
  local power = facts.power
  local moveType = facts.moveType
  local category = facts.category
  local accuracy = facts.accuracy
  if type(power) ~= "number" or power % 1 ~= 0 or power < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move power", { key = key }))
  end
  if type(moveType) ~= "string" or moveType == "" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its move type", { key = key }))
  end
  if type(category) ~= "string" or category == "" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its move category", { key = key }))
  end
  if type(accuracy) ~= "number" or accuracy % 1 ~= 0 or accuracy < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled accuracy", { key = key }))
  end
  return {
    key = key,
    moveType = moveType --[[@as string]],
    power = power --[[@as integer]],
    category = category --[[@as string]],
    accuracy = accuracy --[[@as integer]],
    usable = true,
  }
end

-- Selects the replacement after the source switch gate (ov10_022203A4)
-- with first-fit roster order from the opponent-controller selection
-- (ov12_02258800): a holder with no damaging answer leaves for the
-- first armed reserve, and a lethal learned threat leaves for the first
-- reserve that takes it better. Trapping holds every exchange and an
-- empty bench holds the field. Selection draws nothing.
---@param chart table<string, unknown> session chart resolving directed pairs
---@param holderSlots TrainerAiMove[] holder moves in slot order
---@param holder TrainerAiStats holder stats and types under evaluation
---@param holderHp integer holder health bounding the lethal check
---@param reserves TrainerAiReserveFacts[] living benched reserves in roster order
---@param foes TrainerAiFoeFacts[] live opposing entries in position order
---@param knownMoves table<integer, table<string, boolean>> learned foe moves by combatant
---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@param stream table<string, unknown> caller-owned battle stream, never drawn by selection
---@return integer? benched combatant answering the threat, nil when the holder stays
local function selectReplacement(chart, holderSlots, holder, holderHp, reserves, foes, knownMoves, moveFacts, stream)
  if #reserves == 0 then
    return nil
  end
  if not hasDamaging(holderSlots) then
    for _, reserve in ipairs(reserves) do
      if hasDamaging(reserve.slots) then
        return reserve.id
      end
    end
  end
  for _, foe in ipairs(foes) do
    local learned = knownMoves[foe.id]
    if type(learned) == "table" then
      local keys = {}
      for key in pairs(learned) do
        keys[#keys + 1] = key
      end
      table.sort(keys)
      for _, key in ipairs(keys) do
        local move = previewMove(moveFacts, key)
        if move.power > 0 and previewDamage(chart, foe.stats, move, holder, stream) >= holderHp then
          local holderNumerator, holderDenominator = combineMultiplier(chart, move.moveType, holder.types)
          for _, reserve in ipairs(reserves) do
            local reserveNumerator, reserveDenominator = combineMultiplier(chart, move.moveType, reserve.stats.types)
            if reserveNumerator * holderDenominator < holderNumerator * reserveDenominator then
              return reserve.id
            end
          end
        end
      end
    end
  end
  return nil
end

---@param mon unknown battle-local mon record under condition sampling
---@return table<string, boolean> persistent condition keys carried by the holder
local function holderConditions(mon)
  local present = {}
  if type(mon) ~= "table" then
    return present
  end
  local condition = (mon --[[@as table<string, unknown>]]).condition
  if type(condition) ~= "table" then
    return present
  end
  local effects = (condition --[[@as table<string, unknown>]]).effects
  if type(effects) ~= "table" then
    return present
  end
  for _, entry in
    ipairs(effects --[[@as table<integer, unknown>]])
  do
    if type(entry) == "table" then
      local key = (entry --[[@as table<string, unknown>]]).key
      if type(key) == "string" and key ~= "" then
        present[key] = true
      end
    end
  end
  return present
end

--- Spends the switch-gate coverage draws when a holder move is
--- super-effective against the opposing battler. The coverage helper
--- (ov10_0221FE8C) spends one draw on super-effective coverage, then the
--- stay helper (ov10_0221FD34) spends one draw per covered move until it
--- stays; both scan move identities, so power-point-exhausted slots still
--- count. Only the first opposing battler is checked, matching the
--- source single-target coverage scan in singles.
---@param chart table<string, unknown> session chart resolving directed pairs
---@param slots TrainerAiMove[] holder move slots in source order
---@param foeTypes string[] opposing battler types in declared order
---@param stream table<string, unknown> caller-owned battle stream for gate draws
local function coverStayDraws(chart, slots, foeTypes, stream)
  local covered = 0
  for _, move in ipairs(slots) do
    if move.key ~= "" then
      local numerator, denominator = combineMultiplier(chart, move.moveType, foeTypes)
      if numerator >= 2 * denominator then
        covered = covered + 1
      end
    end
  end
  if covered == 0 then
    return
  end
  stream:nextU16("switch_cover", { slots = covered })
  for _ = 1, covered do
    local roll = stream:nextU16("switch_stay", { slots = covered })
    if roll % 10 ~= 0 then
      break
    end
  end
end

---@param combatant table<string, unknown> live combatant under health sampling
---@return integer current health bounding the item check
---@return integer health ceiling bounding the item check
local function holderHealth(combatant)
  local hp = combatant.hp
  local ceiling = combatant.maxHp
  if type(ceiling) ~= "number" then
    ceiling = combatant.entryHp
  end
  if type(hp) ~= "number" or hp % 1 ~= 0 or hp < 0 then
    error(BattleErrors.missingBehavior("trainer decisions read their holder health", {}))
  end
  if type(ceiling) ~= "number" or ceiling % 1 ~= 0 or ceiling < 1 then
    error(BattleErrors.missingBehavior("trainer decisions read their holder health", {}))
  end
  return hp, --[[@as integer]]
    ceiling --[[@as integer]]
end

---@param restore unknown generated restoration record under amount resolution
---@param ceiling integer health ceiling bounding fractional kinds
---@param item string item identity under the error context
---@return integer heal amount bounding the overheal check
local function restoreAmount(restore, ceiling, item)
  if type(restore) ~= "table" then
    error(BattleErrors.missingBehavior("trainer items carry their restoration facts", { item = item }))
  end
  local record = restore --[[@as table<string, unknown>]]
  if record.kind == "fixed" then
    if
      type(record.amount) ~= "number" or record.amount --[[@as integer]]
        % 1 ~= 0
    then
      error(BattleErrors.missingBehavior("trainer items carry their restoration facts", { item = item }))
    end
    return record.amount --[[@as integer]]
  elseif record.kind == "full" then
    return ceiling
  elseif record.kind == "half" then
    return math.floor(ceiling / 2)
  elseif record.kind == "quarter" then
    return math.floor(ceiling / 4)
  end
  error(BattleErrors.missingBehavior("trainer items carry their restoration facts", { item = item }))
end

---@param stages unknown battle-local stat stages under headroom inspection
---@return table<string, integer> validated stages for the holder
local function holderStages(stages)
  if type(stages) ~= "table" then
    error(BattleErrors.missingBehavior("trainer decisions read their battle-local stages", {}))
  end
  local record = stages --[[@as table<string, unknown>]]
  local out = {}
  for _, stat in ipairs({ "attack", "defense", "specialAttack", "specialDefense", "speed", "accuracy" }) do
    local stage = record[stat] or 0
    if type(stage) ~= "number" or stage % 1 ~= 0 then
      error(BattleErrors.missingBehavior("trainer decisions read their battle-local stages", {}))
    end
    out[stat] = stage
  end
  return out
end

-- Reads whether a battle-use serving could change state through the same
-- live battle-local effects execution uses: stage headroom, focus, the
-- side screen, and volatile cures.
---@param entry table<string, unknown> generated fact entry for the serving
---@param holderId integer holder combatant under inspection
---@param stages table<string, integer> validated holder stages
---@param view table<string, unknown> declared battle state under inspection
---@return boolean true while at least one battle-use operation applies
local function battleUseApplies(entry, holderId, stages, view)
  local battleUse = entry.battleUse
  if type(battleUse) ~= "table" then
    error(BattleErrors.missingBehavior("trainer items carry their battle-use facts", {}))
  end
  local riders = battleUse --[[@as table<string, unknown>]]
  local context = BattleContext.wrap(view)
  local flags = riders.stages
  if type(flags) == "table" then
    local decoded = flags --[[@as table<string, unknown>]]
    for _, stat in ipairs({ "attack", "defense", "specialAttack", "specialDefense", "speed", "accuracy" }) do
      if
        type(decoded[stat]) == "number"
        and decoded[stat] --[[@as integer]]
          ~= 0
      then
        local current = stages[stat] or 0
        if current < StatStages.MAX then
          return true
        end
      end
    end
    if
      type(decoded.critical) == "number"
      and decoded.critical --[[@as integer]]
        ~= 0
    then
      if not context:hasBattleEffect(holderId, "focusenergy") then
        return true
      end
    end
  end
  if riders.guardSpec == true then
    local side = context:entryOf(holderId).side --[[@as integer]]
    if context:sideEffect(side, "mist") == nil then
      return true
    end
  end
  local cures = riders.cures
  if type(cures) == "table" then
    for _, flag in ipairs(BATTLE_CURE_FLAGS) do
      if
        (cures --[[@as table<string, unknown>]])[flag] == true and context:hasBattleEffect(holderId, flag)
      then
        return true
      end
    end
  end
  return false
end

-- Checks one trainer item slot against the source item conditions
-- (ov10_022206B0): healing serves below a quarter of health or past an
-- overhealing bound, status cures serve their matching ailment at any
-- health, and battle-use servings apply through live stages, focus,
-- screens, and volatiles. Selection never consumes: quantities move
-- only when the ordinary item action executes.
---@param item string trainer item identity under the policy check
---@param facts table<string, unknown> generated fact entry for the serving
---@param holderId integer holder combatant under the policy check
---@param hp integer holder health bounding the policy check
---@param ceiling integer holder health ceiling bounding the policy check
---@param conditions table<string, boolean> holder persistent conditions under the policy check
---@param stages table<string, integer> validated holder stages under the policy check
---@param view table<string, unknown> declared battle state under the policy check
---@return boolean true while the source policy considers the slot
local function itemPolicyApplies(item, facts, holderId, hp, ceiling, conditions, stages, view)
  local partyUse = facts.partyUse
  if partyUse == nil then
    return false
  end
  if type(partyUse) ~= "table" then
    error(BattleErrors.missingBehavior("trainer items carry their servable use facts", { item = item }))
  end
  local use = partyUse --[[@as table<string, unknown>]]
  if use.kind == "medicine" then
    if hp <= 0 then
      return false
    end
    if use.restore ~= nil then
      local amount = restoreAmount(use.restore, ceiling, item)
      if hp * 4 < ceiling or (ceiling - hp) > amount then
        return true
      end
    end
    if type(use.cures) == "table" then
      for flag, enabled in
        pairs(use.cures --[[@as table<string, unknown>]])
      do
        if enabled == true and conditions[flag] == true then
          return true
        end
      end
    end
    return false
  elseif use.kind == "deferred" then
    return battleUseApplies(facts, holderId, stages, view)
  end
  error(BattleErrors.missingBehavior("trainer items carry their servable use facts", { item = item }))
end

---@param state table<string, unknown> live battle state under inspection
---@param participant table<string, unknown> acting participant owning the inventory
---@return table<string, integer> live trainer stock quantities under inspection
local function trainerStock(state, participant)
  local inventoryId = participant.inventoryId
  if type(inventoryId) ~= "string" then
    error(BattleErrors.missingBehavior("trainer decisions read their session inventory", {}))
  end
  local inventories = state.inventories
  if type(inventories) ~= "table" then
    error(BattleErrors.missingBehavior("trainer decisions read their session inventory", {}))
  end
  local stock = inventories[inventoryId]
  if type(stock) ~= "table" or type(stock.quantities) ~= "table" then
    error(BattleErrors.missingBehavior("trainer decisions read their session inventory", {
      inventory = inventoryId,
    }))
  end
  return stock.quantities --[[@as table<string, integer>]]
end

-- Scans the ordered trainer item slots exactly as the source item
-- policy does (ov10_022206B0): consumed and empty slots never answer,
-- each slot is considered in order against the source conditions, and
-- the first source-selected item is asserted through the effectful
-- planning check before it answers. The planning check is final
-- executability only, never policy.
---@param state table<string, unknown> live battle state under inspection
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param participant table<string, unknown> acting participant owning slots and stock
---@param holderId integer holder combatant under the policy check
---@param taken table<string, integer> same-request servings already answering
---@param view table<string, unknown> declared battle state under planning
---@return string? selected trainer item identity, nil without a serving
local function selectItemSlot(state, authorities, participant, holderId, taken, view)
  local controller = participant.controller
  if type(controller) ~= "string" then
    return nil
  end
  local memory = controllerMemory(state, controller)
  if memory == nil then
    return nil
  end
  local slots = memory.slots
  if type(slots) ~= "table" then
    return nil
  end
  local inventoryId = participant.inventoryId
  if type(inventoryId) ~= "string" then
    return nil
  end
  local stock = trainerStock(state, participant)
  local combatant = BattleState.combatant(state, holderId)
  local hp, ceiling = holderHealth(combatant)
  local conditions = holderConditions(combatant.mon)
  local stages = holderStages(combatant.stages)
  for _, item in
    ipairs(slots --[[@as string[] ]])
  do
    if not CaptureContext.isBall(item) then
      local units = stock[item] or 0
      if (taken[item] or 0) < units then
        local facts = authorities.itemFacts[item]
        if type(facts) ~= "table" then
          error(BattleErrors.missingBehavior("trainer decisions read their compiled item facts", { item = item }))
        end
        if itemPolicyApplies(item, facts, holderId, hp, ceiling, conditions, stages, view) then
          local plan = ItemUse.plan({
            inventoryId = inventoryId,
            item = item,
            target = { kind = "combatant", combatant = holderId },
          }, view, authorities.itemFacts)
          if plan.failureReason == nil then
            taken[item] = (taken[item] or 0) + 1
            -- The source policy clears the selected source slot at
            -- selection (ov10_022206B0): drop the first surviving
            -- occurrence from persistent memory so later answers never
            -- reselect it, while the taken count keeps reserving against
            -- stock that only moves when the serving executes.
            for index, slotItem in
              ipairs(slots --[[@as string[] ]])
            do
              if slotItem == item then
                table.remove(slots, index)
                break
              end
            end
            return item
          end
        end
      end
    end
  end
  return nil
end

--- Spends one shared-stream draw per usable slot reaching a routine-draw
--- site of the enabled flag bit. Sites transcribe the source
--- random-conditional commands (ov10_0221C384 and its table siblings)
--- with their branch guards: numeric move-effect membership and, where
--- the source program gates on it, the opening turn and the knockout
--- preview. Score commands draw nothing, so evaluating sites after them
--- matches the source stream position.
---@param sites table<integer, table<string, unknown>> routine-draw sites in program order
---@param firstTurn boolean true while the opening turn gates sites open
---@param chart table<string, unknown> session chart resolving directed pairs
---@param checked TrainerAiMove[] validated move slots in source order
---@param attacker TrainerAiStats acting stats and types under scoring
---@param defender TrainerAiStats opposing stats and types under scoring
---@param foeHp integer opposing health bounding the knockout check
---@param bit integer enabled native flag bit under evaluation
---@param stream table<string, unknown> caller-owned battle stream for routine draws
local function runDrawSites(sites, firstTurn, chart, checked, attacker, defender, foeHp, bit, stream)
  for index, move in ipairs(checked) do
    if move.usable then
      for _, site in ipairs(sites) do
        local record = site --[[@as table<string, unknown>]]
        local effects = record.effects --[[@as table<integer, boolean>]]
        assert(type(effects) == "table", "routine-draw sites name their effect set")
        if effects[move.effect] == true then
          if record.turn0 ~= true or firstTurn then
            local gated = record.ko
            if gated == nil then
              stream:nextU16("program_chance", { flag = bit, slot = index - 1 })
            else
              local knockout = false
              if isDamaging(move) then
                knockout = previewDamage(chart, attacker, move, defender, stream) >= foeHp
              end
              if (gated == true) == knockout then
                stream:nextU16("program_chance", { flag = bit, slot = index - 1 })
              end
            end
          end
        end
      end
    end
  end
end

---@param chart table<string, unknown> session chart resolving directed pairs
---@param slots TrainerAiMove[] four native move slots in source order
---@param user TrainerAiStats acting stats and types under scoring
---@param foe TrainerAiStats opposing stats and types under scoring
---@param foeHp integer opposing health bounding the knockout check
---@param bits integer[] enabled native flag bits in ascending order
---@param thresholds table<integer, integer> stored initialization thresholds in slot order
---@param firstTurn boolean true while the opening turn gates routine draws
---@param stream table<string, unknown> caller-owned battle stream for decision draws
---@return TrainerAiScoredSlot[] scored slots in source slot order
function scoreWithThresholds(chart, slots, user, foe, foeHp, bits, thresholds, firstTurn, stream)
  assert(type(firstTurn) == "boolean", "scoring names its opening turn for routine draws")
  local checked = {}
  for _, slot in ipairs(slots) do
    checked[#checked + 1] = checkScoringMove(slot)
  end
  local attacker = checkFighterStats(user)
  local defender = checkFighterStats(foe)
  local bestPower = 0
  for _, move in ipairs(checked) do
    if isDamaging(move) and move.power > bestPower then
      bestPower = move.power
    end
  end
  local scores = {}
  for index, move in ipairs(checked) do
    if move.usable then
      scores[index] = TrainerAi.OPENING_SCORE
    else
      scores[index] = 0
    end
  end
  local vm = {
    bit = -1,
    scores = scores,
    thresholds = thresholds,
    slots = checked,
    user = attacker,
    foe = defender,
    foeHp = foeHp,
    bestPower = bestPower,
    chart = chart,
    stream = stream,
  }
  for _, bit in ipairs(bits) do
    local program = programFor(bit --[[@as integer]])
    vm.bit = bit
    local perSlot = program.perSlot --[[@as table<integer, table<string, unknown>>]]
    for _, command in ipairs(perSlot) do
      for index, move in ipairs(checked) do
        if move.usable then
          TrainerAi.runCommand(vm, index, command)
        end
      end
    end
    local perProgram = program.perProgram --[[@as table<integer, table<string, unknown>>]]
    for _, command in ipairs(perProgram) do
      TrainerAi.runCommand(vm, 1, command)
    end
    local sites = TrainerAiProgram.DRAW_SITES[
      bit --[[@as integer]]
    ]
    if type(sites) ~= "table" then
      error(BattleErrors.missingBehavior("trainer scoring names transcribed routine draws", { flag = bit }))
    end
    runDrawSites(
      sites --[[@as table<integer, table<string, unknown>>]],
      firstTurn,
      chart,
      checked,
      attacker,
      defender,
      foeHp,
      bit,
      stream
    )
  end
  local scored = {}
  for index, move in ipairs(checked) do
    scored[index] = { slot = index - 1, key = move.key, score = scores[index] }
  end
  return scored
end

---@param stream table<string, unknown> caller-owned battle stream for initialization draws
---@return table<integer, integer> stored 100-(draw%16) thresholds in slot order
function initThresholds(stream)
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "initialization draws stream")
  local thresholds = {}
  for index = 1, 4 do
    local draw = stream:nextU16("score_init_" .. (index - 1), { slot = index - 1 })
    thresholds[index] = 100 - (draw % 16)
  end
  return thresholds
end

---@class TrainerAiActorFacts
---@field combatant table<string, unknown> acting combatant under evaluation
---@field user TrainerAiStats acting stats and types under scoring
---@field slots TrainerAiMove[] acting move slots in source order

---@param authorities TrainerAiAuthorities session-owned read authorities
---@param combatant table<string, unknown> acting combatant under evaluation
---@return TrainerAiActorFacts evaluated actor facts for attack selection
local function actorFacts(authorities, combatant)
  return {
    combatant = combatant,
    user = estimateFighter(combatant.mon --[[@as table<string, unknown>]], combatant.stages, authorities.speciesFacts),
    slots = resolveSlots(combatant.mon --[[@as table<string, unknown>]], authorities.moveFacts),
  }
end

--- Reads whether the opening turn still gates routine draws. The source
--- total-turns counter is zero through the first turn's decisions
--- (ov10_0221C278 programs read it through ov10_0221CB64); the native
--- round counter starts at one and advances per completed turn, so round
--- one is the equivalent gate.
---@param state table<string, unknown> live battle state under inspection
---@return boolean firstTurn true while the opening turn gates routine draws
local function firstTurnOf(state)
  local round = state.round
  if type(round) ~= "number" or round % 1 ~= 0 or round < 1 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its battle round", {}))
  end
  return round == 1
end

---@param state table<string, unknown> live battle state under inspection
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param facts TrainerAiActorFacts acting facts under evaluation
---@param opponents table<integer, table<string, unknown>> live opposing entries in position order
---@param bits integer[] enabled native flag bits in ascending order
---@param stream table<string, unknown> caller-owned battle stream for decision draws
---@return table<string, unknown> attack choice in the shared decision shape
local function evaluateSingles(state, authorities, facts, opponents, bits, stream)
  local foeIds = {}
  for _, opposed in ipairs(opponents) do
    foeIds[#foeIds + 1] = opposed.combatant
  end
  local foeId = TrainerAi.selectTarget(foeIds, stream)
  local foePosition = 0
  for _, opposed in ipairs(opponents) do
    if opposed.combatant == foeId then
      foePosition = opposed.position
    end
  end
  assert(foePosition >= 1, "selected targets resolve to their position")
  local foe = BattleState.combatant(state, foeId)
  local foeStats = estimateFighter(foe.mon --[[@as table<string, unknown>]], foe.stages, authorities.speciesFacts)
  local foeHp = foe.hp
  if type(foeHp) ~= "number" or foeHp % 1 ~= 0 or foeHp < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its opposing health", {}))
  end
  local thresholds = initThresholds(stream)
  local scored = scoreWithThresholds(
    authorities.chart,
    facts.slots,
    facts.user,
    foeStats,
    foeHp,
    bits,
    thresholds,
    firstTurnOf(state),
    stream
  )
  local moveSlot = 0
  if hasUsable(facts.slots) then
    moveSlot = TrainerAi.selectMove(scored, stream)
  end
  return {
    kind = "attack",
    payload = { moveSlot = moveSlot, target = { kind = "position", position = foePosition } },
  }
end

-- Evaluates one doubles actor through the doubles selector
-- (ov10_0221C038): one initialization feeds every candidate target,
-- each target evaluates its own scores and winning move, and the
-- highest bid answers with ties broken through one selection draw.
-- Candidate targets enumerate live opposing positions in order; ally
-- support targeting stays unmodeled and such moves score against the
-- foe line instead.
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param facts TrainerAiActorFacts acting facts under evaluation
---@param opponents table<integer, table<string, unknown>> live opposing entries in position order
---@param state table<string, unknown> live battle state under inspection
---@param bits integer[] enabled native flag bits in ascending order
---@param stream table<string, unknown> caller-owned battle stream for decision draws
---@return table<string, unknown> attack choice in the shared decision shape
local function evaluateDoubles(authorities, facts, opponents, state, bits, stream)
  local firstTurn = firstTurnOf(state)
  local thresholds = initThresholds(stream)
  local bids = {}
  for _, opposed in ipairs(opponents) do
    local foe = BattleState.combatant(state, opposed.combatant)
    local foeStats = estimateFighter(foe.mon --[[@as table<string, unknown>]], foe.stages, authorities.speciesFacts)
    local foeHp = foe.hp
    if type(foeHp) ~= "number" or foeHp % 1 ~= 0 or foeHp < 0 then
      error(BattleErrors.missingBehavior("trainer evaluation reads its opposing health", {}))
    end
    local scored = scoreWithThresholds(
      authorities.chart,
      facts.slots,
      facts.user,
      foeStats,
      foeHp,
      bits,
      thresholds,
      firstTurn,
      stream
    )
    local moveSlot = 0
    local top = nil
    if hasUsable(facts.slots) then
      moveSlot = TrainerAi.selectMove(scored, stream)
      for _, entry in ipairs(scored) do
        if entry.slot == moveSlot then
          top = entry.score
        end
      end
    end
    assert(top ~= nil or not hasUsable(facts.slots), "winning bids carry their native points")
    bids[#bids + 1] = { target = opposed.position, slot = moveSlot, score = top or 0 }
  end
  local target, slot = TrainerAi.selectDoubles(bids, stream)
  return {
    kind = "attack",
    payload = { moveSlot = slot, target = { kind = "position", position = target } },
  }
end

--- Answers one actor of the trainer request from live session state and
--- facts, following the source action order (ov10_022205BC): the switch
--- gate answers first, then the ordered trainer item path, otherwise the
--- attack evaluation. Reads only; battle state, stock, and stream
--- ownership stay with the caller while same-request servings accumulate
--- in the caller-owned taken map.
---@param state table<string, unknown> live battle state under inspection
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param participant table<string, unknown> acting participant owning passes and stock
---@param actor table<string, unknown> addressed actor with its entry token
---@param opponents table<integer, table<string, unknown>> live opposing entries in position order
---@param claimed table<integer, boolean> reserves already answering this request
---@param taken table<string, integer> same-request servings already answering
---@param bits integer[] enabled native flag bits in ascending order
---@param doubles boolean true while the live format routes through doubles
---@param stream table<string, unknown> caller-owned battle stream for decision draws
---@return table<string, unknown> choice in the shared decision shape
local function answerActor(state, authorities, participant, actor, opponents, claimed, taken, bits, doubles, stream)
  local combatant = BattleState.combatant(state, actor.combatant --[[@as integer]])
  local active = combatant.active
  if type(active) ~= "table" or active.activation ~= actor.activation then
    error(BattleErrors.input("locked references die with their entry", { combatant = actor.combatant }))
  end
  local facts = actorFacts(authorities, combatant)
  local holderHp = combatant.hp
  if type(holderHp) ~= "number" or holderHp % 1 ~= 0 or holderHp < 0 then
    error(BattleErrors.missingBehavior("trainer decisions read their holder health", {}))
  end
  local userStats = facts.user
  if not switchHeld(state, combatant, userStats.types, opponents) then
    local reserveIds = livingReserves(state, participant, claimed)
    if #reserveIds > 0 then
      local reserves = {}
      for _, reserveId in ipairs(reserveIds) do
        local reserve = BattleState.combatant(state, reserveId)
        reserves[#reserves + 1] = {
          id = reserveId,
          stats = estimateFighter(
            reserve.mon --[[@as table<string, unknown>]],
            reserve.stages,
            authorities.speciesFacts
          ),
          slots = resolveSlots(reserve.mon --[[@as table<string, unknown>]], authorities.moveFacts),
        }
      end
      local foes = {}
      for _, opposed in ipairs(opponents) do
        local foe = BattleState.combatant(state, opposed.combatant)
        local foeHp = foe.hp
        if type(foeHp) ~= "number" or foeHp % 1 ~= 0 or foeHp < 0 then
          error(BattleErrors.missingBehavior("trainer evaluation reads its opposing health", {}))
        end
        foes[#foes + 1] = {
          id = opposed.combatant,
          position = opposed.position,
          stats = estimateFighter(foe.mon --[[@as table<string, unknown>]], foe.stages, authorities.speciesFacts),
          hp = foeHp,
        }
      end
      local memory = controllerMemory(state, participant.controller --[[@as string]])
      local known = {}
      if memory ~= nil and type(memory.knownMoves) == "table" then
        known = memory.knownMoves --[[@as table<integer, table<string, boolean>>]]
      end
      local exchange = selectReplacement(
        authorities.chart,
        facts.slots,
        userStats,
        holderHp --[[@as integer]],
        reserves,
        foes,
        known,
        authorities.moveFacts,
        stream
      )
      if exchange ~= nil then
        local verdict = Switching.eligible({
          reason = "voluntary",
          position = active.position,
          incoming = exchange,
          reserves = reserveIds,
          reserved = {},
          fainted = {},
          trap = nil,
        })
        if not verdict.ok then
          error(BattleErrors.invalidState("selected exchanges stay eligible", { reason = verdict.reason }))
        end
        claimed[exchange] = true
        return { actor = actor, kind = "switch", payload = { replacement = exchange } }
      end
      if #foes > 0 then
        coverStayDraws(authorities.chart, facts.slots, foes[1].stats.types, stream)
      end
    end
  end
  local serving = selectItemSlot(state, authorities, participant, actor.combatant --[[@as integer]], taken, state)
  if serving ~= nil then
    return {
      actor = actor,
      kind = "item",
      payload = { item = serving, target = { kind = "combatant", combatant = actor.combatant } },
    }
  end
  local attack
  if doubles then
    attack = evaluateDoubles(authorities, facts, opponents, state, bits, stream)
  else
    attack = evaluateSingles(state, authorities, facts, opponents, bits, stream)
  end
  attack.actor = actor
  return attack
end

--- Answers the trainer request from live session state and facts. The
--- caller owns request validation, the decision lease, and stream
--- ownership; this resolves opponents from battle topology and returns
--- one ordinary reply for every addressed actor in source order. The
--- taken map carries same-request servings across actors and answers;
--- it is caller-owned pending-reply state, never persisted knowledge.
---@param state table<string, unknown> live battle state under inspection
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param request table<string, unknown> open internal trainer request under verification
---@param stream table<string, unknown> caller-owned battle stream for decision draws
---@param taken table<string, integer> same-request servings already answering
---@return table<string, unknown> reply in the shared decision shape
function TrainerAi.answer(state, authorities, request, stream, taken)
  assert(type(state) == "table", "trainer decisions read live battle state")
  assert(type(authorities) == "table", "trainer decisions read their session authorities")
  assert(type(request) == "table", "trainer decisions answer a pending request")
  assert(
    type(stream) == "table" and type(stream.nextU16) == "function",
    "trainer decisions draw from the battle stream"
  )
  assert(type(taken) == "table", "trainer decisions track their same-request servings")
  assert(type(request.actors) == "table" and #request.actors > 0, "trainer decisions address at least one actor")
  local owner = authorities --[[@as table<string, unknown>]]
  if
    type(owner.chart) ~= "table"
    or type(owner.moveFacts) ~= "table"
    or type(owner.speciesFacts) ~= "table"
    or type(owner.itemFacts) ~= "table"
  then
    error(BattleErrors.missingBehavior("trainer decisions read their session authorities", {}))
  end
  local first = request.actors[1] --[[@as table<string, unknown>]]
  local firstCombatant = BattleState.combatant(state, first.combatant --[[@as integer]])
  local ownSide = BattleState.participant(state, firstCombatant.participant --[[@as integer]]).side --[[@as integer]]
  local opponents = opposingEntries(state, ownSide)
  if #opponents == 0 then
    error(BattleErrors.missingBehavior("trainer decisions read their opposing entry", {}))
  end
  local doubles = DOUBLE_FORMATS[
    state.format --[[@as string]]
  ] == true
  local claimed = {}
  local choices = {}
  for _, actor in
    ipairs(request.actors --[[@as table<integer, unknown>]])
  do
    local entry = actor --[[@as table<string, unknown>]]
    local combatant = BattleState.combatant(state, entry.combatant --[[@as integer]])
    local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
    local context = participant.context
    if type(context) ~= "table" or type(context.aiPasses) ~= "table" then
      error(BattleErrors.missingBehavior("trainer sides carry their generated pass facts", {
        controller = participant.controller,
      }))
    end
    local bits = TrainerAi.parsePasses(context.aiPasses --[[@as string[] ]])
    choices[#choices + 1] =
      answerActor(state, authorities, participant, entry, opponents, claimed, taken, bits, doubles, stream)
  end
  return {
    requestId = request.requestId,
    epoch = request.epoch,
    controller = request.controller,
    choices = choices,
  }
end

return TrainerAi
